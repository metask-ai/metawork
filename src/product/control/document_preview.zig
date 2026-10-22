//! Physical document resource scheduling only. Runtime admission owns source,
//! Task/connection/security authority and credential publication decisions.
const std = @import("std");
const executor_impl = @import("product_control_executor");
pub const contract = @import("product_document_preview_contract");
pub const max_resources = 2;
pub const Notifier = struct { context: ?*anyopaque, wake_fn: *const fn (?*anyopaque) bool };
pub const Operation = union(enum) { prepare, read: contract.Request, cleanup };

const Session = struct {
    allocator: std.mem.Allocator,
    id: u64,
    effect: contract.Owned,
    notifier: Notifier,
    operation: Operation = .prepare,
    cancelled: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    in_flight: bool = false,
    taken: bool = false,
    prepared: bool = false,
    closing: bool = false,
    poisoned: bool = false,
    cleanup_attempted: bool = false,
    failure: ?anyerror = null,
    result: ?contract.Read = null,

    fn execute(context: *anyopaque) void {
        const self: *Session = @ptrCast(@alignCast(context));
        self.work() catch |failure| {
            self.failure = failure;
        };
        self.publish();
    }
    fn work(self: *Session) !void {
        if (self.operation != .cleanup and self.cancelled.load(.acquire)) return error.Cancelled;
        switch (self.operation) {
            .prepare => try self.effect.prepare_fn(self.effect.context),
            .read => |request| self.result = try self.effect.read_fn(self.effect.context, request),
            .cleanup => {
                self.cleanup_attempted = true;
                try self.effect.cleanup_fn(self.effect.context);
            },
        }
    }
    fn cancelQueued(context: *anyopaque) void {
        const self: *Session = @ptrCast(@alignCast(context));
        self.failure = error.Cancelled;
        self.publish();
    }
    fn publish(self: *Session) void {
        // After this release-store main can free the session. Keep no borrowed
        // session pointer across the wake callback, including on queued cancel.
        const notifier = self.notifier;
        self.done.store(true, .release);
        _ = notifier.wake_fn(notifier.context);
    }
    fn clearResult(self: *Session) void {
        if (self.result) |*value| value.deinit();
        self.result = null;
    }
};

/// Callback-scoped completion. It grants no content publication authority.
/// finish must run exactly once before another operation on the same id.
pub const Taken = struct {
    session: *Session,
    id: u64,
    operation: Operation,
    failure: ?anyerror,
    read: ?*const contract.Read,
};

pub const Lane = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    main_thread: std.Thread.Id,
    notifier: Notifier,
    executor: ?*executor_impl.Executor = null,
    sessions: [max_resources]?*Session = @splat(null),
    stopping: bool = false,

    fn main(self: *const Lane) void {
        std.debug.assert(std.Thread.getCurrentId() == self.main_thread);
    }
    fn find(self: *const Lane, id: u64) ?*Session {
        for (self.sessions) |slot| if (slot) |session| {
            if (session.id == id) return session;
        };
        return null;
    }
    /// Consumes effect only on success. A resource slot remains reserved until
    /// successful worker cleanup, not merely cancellation or UI handle removal.
    pub fn open(self: *Lane, id: u64, effect: contract.Owned) !void {
        self.main();
        if (self.stopping) return error.ExecutorShuttingDown;
        if (id == 0 or self.find(id) != null) return error.InvalidPreviewIdentity;
        const slot = for (&self.sessions) |*entry| {
            if (entry.* == null) break entry;
        } else return error.PreviewCapacity;
        if (self.executor == null) self.executor = try executor_impl.Executor.create(self.io, self.allocator, .{ .worker_count = 1, .queue_capacity = max_resources });
        const session = try self.allocator.create(Session);
        errdefer self.allocator.destroy(session);
        session.* = .{ .allocator = self.allocator, .id = id, .effect = effect, .notifier = self.notifier };
        try self.enqueue(session, .prepare);
        slot.* = session;
    }
    fn enqueue(self: *Lane, session: *Session, operation: Operation) !void {
        std.debug.assert(!session.in_flight and !session.taken and session.result == null);
        session.operation = operation;
        session.failure = null;
        session.cleanup_attempted = false;
        session.done.store(false, .release);
        try self.executor.?.enqueue(.{ .identity = session, .context = session, .execute_fn = Session.execute, .cancel_fn = Session.cancelQueued });
        session.in_flight = true;
    }
    pub fn read(self: *Lane, id: u64, request: contract.Request) !void {
        self.main();
        const session = self.find(id) orelse return error.MissingPreview;
        if (self.stopping or session.closing or session.poisoned) return error.RestrictedPreview;
        if (session.in_flight or session.taken) return error.PreviewBusy;
        if (!session.prepared) return error.InvalidPreviewState;
        try self.enqueue(session, .{ .read = request });
    }
    /// Borrowed material is never available while a worker may mutate it.
    pub fn material(self: *Lane, id: u64) !contract.Material {
        self.main();
        const session = self.find(id) orelse return error.MissingPreview;
        if (self.stopping or session.closing or session.poisoned) return error.RestrictedPreview;
        if (!session.prepared or session.in_flight or session.taken) return error.PreviewBusy;
        return session.effect.material_fn(session.effect.context);
    }
    pub fn close(self: *Lane, id: u64) bool {
        self.main();
        const session = self.find(id) orelse return true;
        session.closing = true;
        session.cancelled.store(true, .release);
        session.effect.cancel_fn(session.effect.context);
        if (session.in_flight and session.operation != .cleanup) _ = self.executor.?.cancel(session);
        if (!session.in_flight and !session.taken and !session.poisoned)
            self.enqueue(session, .cleanup) catch {}; // retry from take; slot stays owned
        return false;
    }
    pub fn take(self: *Lane) ?Taken {
        self.main();
        for (self.sessions) |slot| if (slot) |session| {
            if (session.closing and !session.in_flight and !session.taken and !session.poisoned)
                self.enqueue(session, .cleanup) catch {};
            if (!session.in_flight or session.taken or !session.done.load(.acquire)) continue;
            session.taken = true;
            return .{ .session = session, .id = session.id, .operation = session.operation, .failure = if (session.closing and session.operation != .cleanup) error.Cancelled else session.failure, .read = if (!session.closing and session.failure == null) if (session.result) |*value| value else null else null };
        };
        return null;
    }
    pub fn finish(self: *Lane, taken: Taken) void {
        self.main();
        const session = self.find(taken.id) orelse unreachable;
        std.debug.assert(session == taken.session and session.in_flight and session.taken and session.done.load(.acquire));
        session.clearResult();
        session.in_flight = false;
        session.taken = false;
        if (session.operation == .cleanup) {
            if (session.failure == null) {
                self.release(session);
                return;
            }
            // No automatic retry after physical cleanup uncertainty.
            session.poisoned = true;
            return;
        }
        if (session.failure != null) session.closing = true;
        if (session.operation == .prepare and session.failure == null) session.prepared = true;
        if (session.closing) _ = self.close(session.id);
    }
    fn release(self: *Lane, session: *Session) void {
        for (&self.sessions) |*slot| if (slot.* == session) {
            session.effect.release_fn(session.effect.context);
            session.allocator.destroy(session);
            slot.* = null;
            return;
        };
        unreachable;
    }
    pub fn hasResources(self: *const Lane) bool {
        for (self.sessions) |slot| if (slot != null) return true;
        return false;
    }
    pub fn needsRestart(self: *const Lane) bool {
        for (self.sessions) |slot| if (slot) |session| {
            if (session.poisoned) return true;
        };
        return false;
    }
    pub fn stopAdmission(self: *Lane) void {
        self.main();
        self.stopping = true;
        for (self.sessions) |slot| if (slot) |session| {
            _ = self.close(session.id);
        };
    }
    /// Shutdown invalidates borrowed completions, joins execution, then runs a
    /// final serialized cleanup on a worker. Failed cleanup retains its slot.
    pub fn shutdown(self: *Lane) !void {
        self.main();
        self.stopAdmission();
        if (self.executor) |executor| executor.shutdown();
        for (self.sessions) |slot| if (slot) |session| {
            session.clearResult();
            session.in_flight = false;
            session.taken = false;
            if (session.cleanup_attempted) {
                if (session.failure == null) {
                    self.release(session);
                } else {
                    session.poisoned = true;
                }
            }
        };
        var remaining = false;
        for (self.sessions) |slot| if (slot) |session| {
            if (!session.poisoned) {
                remaining = true;
                break;
            }
        };
        if (remaining) {
            const cleanup = try std.Thread.spawn(.{}, shutdownClean, .{self});
            cleanup.join();
            for (self.sessions) |slot| if (slot) |session| {
                if (session.poisoned) continue;
                if (session.failure == null) self.release(session) else {
                    session.poisoned = true;
                }
            };
        }
        if (self.hasResources()) return error.PreviewResourcesOutstanding;
    }
    fn shutdownClean(self: *Lane) void {
        for (self.sessions) |slot| if (slot) |session| {
            if (session.poisoned) continue;
            session.failure = null;
            session.effect.cleanup_fn(session.effect.context) catch |failure| {
                session.failure = failure;
            };
        };
    }
    pub fn deinit(self: *Lane) !void {
        try self.shutdown();
        if (self.executor) |executor| executor.deinit();
        self.* = undefined;
    }
};

const Fixture = struct {
    main_thread: std.Thread.Id,
    io: std.Io = std.testing.io,
    entered: std.Io.Event = .unset,
    gate: std.Io.Event = .unset,
    block: bool = false,
    cleanup_fails: bool = false,
    read_fails: bool = false,
    cancel_gate: ?*std.Io.Event = null,
    prepares: std.atomic.Value(u32) = .init(0),
    cleanups: u32 = 0,
    releases: u32 = 0,
    cancelled: std.atomic.Value(bool) = .init(false),
    fn get(context: *anyopaque) *Fixture {
        return @ptrCast(@alignCast(context));
    }
    fn effect(self: *Fixture) contract.Owned {
        return .{ .context = self, .prepare_fn = prepare, .material_fn = material, .read_fn = read, .cancel_fn = cancel, .cleanup_fn = cleanup, .release_fn = release };
    }
    fn prepare(context: *anyopaque) !void {
        const self = get(context);
        std.debug.assert(std.Thread.getCurrentId() != self.main_thread);
        _ = self.prepares.fetchAdd(1, .acq_rel);
        self.entered.set(self.io);
        if (self.block) try self.gate.waitTimeout(self.io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
    }
    const manifest: contract.Manifest = .{ .schema = 1, .format = .docx, .sourceText = .{ .file = "source-text.txt", .bytes = 1, .sha256 = "1" ** 64 }, .textScope = "fixture", .omissions = &.{}, .kind = .pages };
    fn material(context: *anyopaque) !contract.Material {
        const self = get(context);
        std.debug.assert(std.Thread.getCurrentId() == self.main_thread and self.cleanups == 0);
        return .{ .manifest = &manifest, .grid = null, .source_text = "body" };
    }
    fn read(context: *anyopaque, _: contract.Request) !contract.Read {
        const self = get(context);
        std.debug.assert(std.Thread.getCurrentId() != self.main_thread and self.cleanups == 0);
        if (self.read_fails) return error.OutputChanged;
        return .{ .allocator = std.testing.allocator, .value = .{ .page = try std.testing.allocator.dupe(u8, "page") } };
    }
    fn cancel(context: *anyopaque) void {
        const self = get(context);
        self.cancelled.store(true, .release);
        if (self.cancel_gate) |gate| gate.set(self.io);
    }
    fn cleanup(context: *anyopaque) !void {
        const self = get(context);
        std.debug.assert(std.Thread.getCurrentId() != self.main_thread);
        self.cleanups += 1;
        if (self.cleanup_fails) return error.PreviewRestartRequired;
    }
    fn release(context: *anyopaque) void {
        const self = get(context);
        std.debug.assert(std.Thread.getCurrentId() == self.main_thread and self.cleanups == 1);
        self.releases += 1;
    }
    fn wake(_: ?*anyopaque) bool {
        return true;
    }
    fn lane() Lane {
        return .{ .io = std.testing.io, .allocator = std.testing.allocator, .main_thread = std.Thread.getCurrentId(), .notifier = .{ .context = null, .wake_fn = wake } };
    }
    fn next(lane_value: *Lane) !Taken {
        const start: std.Io.Timestamp = .now(std.testing.io, .awake);
        while (start.durationTo(.now(std.testing.io, .awake)).toMilliseconds() < 5000) {
            if (lane_value.take()) |taken| return taken;
            try std.Io.Timeout.sleep(.{ .duration = .{ .raw = .fromMilliseconds(1), .clock = .awake } }, std.testing.io);
        }
        return error.TestTimeout;
    }
};

test "document lane retains physical slots through queued and running cancellation" {
    var first: Fixture = .{ .main_thread = std.Thread.getCurrentId(), .block = true };
    var second: Fixture = .{
        .main_thread = std.Thread.getCurrentId(),
    };
    var third: Fixture = .{
        .main_thread = std.Thread.getCurrentId(),
    };
    var lane = Fixture.lane();
    // Ensure the deliberately blocked fixture can always stop on test failure.
    defer lane.deinit() catch unreachable;
    defer first.gate.set(std.testing.io);
    try lane.open(1, first.effect());
    try first.entered.waitTimeout(std.testing.io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
    try lane.open(2, second.effect());
    try std.testing.expectEqual(0, second.prepares.load(.acquire)); // one worker
    try std.testing.expectError(error.PreviewCapacity, lane.open(3, third.effect()));
    try std.testing.expect(!lane.close(2));
    const queued = try Fixture.next(&lane);
    try std.testing.expectEqual(2, queued.id);
    try std.testing.expectEqual(error.Cancelled, queued.failure.?);
    lane.finish(queued);
    try std.testing.expect(!lane.close(1));
    try std.testing.expectError(error.PreviewCapacity, lane.open(3, third.effect()));
    try std.testing.expectEqual(0, first.releases);
    try std.testing.expectEqual(0, second.releases);
    first.gate.set(std.testing.io);
    while (lane.hasResources()) lane.finish(try Fixture.next(&lane));
    try std.testing.expectEqual(1, first.releases);
    try std.testing.expectEqual(1, second.releases);
    try std.testing.expectEqual(0, third.prepares.load(.acquire));
    try std.testing.expectEqual(0, third.releases); // failed admission did not consume
}

test "document material is borrowed only between serialized operations and read failure closes" {
    var fixture: Fixture = .{
        .main_thread = std.Thread.getCurrentId(),
    };
    var lane = Fixture.lane();
    defer lane.deinit() catch unreachable;
    try lane.open(7, fixture.effect());
    try std.testing.expectError(error.PreviewBusy, lane.material(7));
    const prepared = try Fixture.next(&lane);
    try std.testing.expect(prepared.failure == null);
    lane.finish(prepared);
    try std.testing.expectEqualStrings("body", (try lane.material(7)).source_text);
    try lane.read(7, .{ .page = 0 });
    try std.testing.expectError(error.PreviewBusy, lane.read(7, .{ .page = 0 }));
    const page = try Fixture.next(&lane);
    try std.testing.expectEqualStrings("page", page.read.?.value.page);
    lane.finish(page);
    fixture.read_fails = true;
    try lane.read(7, .{ .page = 0 });
    const failed = try Fixture.next(&lane);
    try std.testing.expectEqual(error.OutputChanged, failed.failure.?);
    lane.finish(failed);
    try std.testing.expectError(error.RestrictedPreview, lane.material(7));
    lane.finish(try Fixture.next(&lane));
    try std.testing.expectEqual(1, fixture.prepares.load(.acquire));
    try std.testing.expectEqual(1, fixture.releases);
    try std.testing.expect(!lane.hasResources());
}

test "document shutdown joins then cleans idle resources on worker and releases on main" {
    var fixture: Fixture = .{
        .main_thread = std.Thread.getCurrentId(),
    };
    var lane = Fixture.lane();
    defer lane.deinit() catch unreachable;
    try lane.open(1, fixture.effect());
    lane.finish(try Fixture.next(&lane));
    try lane.shutdown();
    try std.testing.expectEqual(1, fixture.cleanups);
    try std.testing.expectEqual(1, fixture.releases);
    try std.testing.expectError(error.ExecutorShuttingDown, lane.open(2, fixture.effect()));
}

test "uncertain cleanup retains resource and is never retried or released" {
    // The failed resource deliberately survives to process exit. An arena lets
    // this synthetic fixture emulate that lifetime without a test heap leak.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fixture: Fixture = .{ .main_thread = std.Thread.getCurrentId(), .cleanup_fails = true };
    var lane = Fixture.lane();
    lane.allocator = arena.allocator();
    try lane.open(1, fixture.effect());
    lane.finish(try Fixture.next(&lane));
    _ = lane.close(1);
    const failed = try Fixture.next(&lane);
    try std.testing.expectEqual(error.PreviewRestartRequired, failed.failure.?);
    lane.finish(failed);
    try std.testing.expect(lane.needsRestart() and lane.hasResources());
    _ = lane.close(1);
    try std.testing.expect(lane.take() == null);
    try std.testing.expectError(error.PreviewResourcesOutstanding, lane.deinit());
    try std.testing.expectEqual(1, fixture.cleanups);
    try std.testing.expectEqual(0, fixture.releases);
    // Only the already joined synthetic executor is destructed; there is no
    // production force-release or poisoned-slot recovery operation.
    lane.executor.?.deinit();
}

test "shutdown cancels queued work before joining active work and final cleanup" {
    var first: Fixture = .{ .main_thread = std.Thread.getCurrentId(), .block = true };
    // Only cancellation of the queued resource lets the active fixture exit.
    // This makes the shutdown order observable without a timing assumption.
    var second: Fixture = .{ .main_thread = std.Thread.getCurrentId(), .cancel_gate = &first.gate };
    var lane = Fixture.lane();
    defer lane.deinit() catch unreachable;
    defer first.gate.set(std.testing.io);
    try lane.open(1, first.effect());
    try first.entered.waitTimeout(std.testing.io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
    try lane.open(2, second.effect());
    try lane.shutdown();
    try std.testing.expectEqual(1, first.prepares.load(.acquire));
    try std.testing.expectEqual(0, second.prepares.load(.acquire));
    try std.testing.expectEqual(1, first.cleanups);
    try std.testing.expectEqual(1, second.cleanups);
    try std.testing.expectEqual(1, first.releases);
    try std.testing.expectEqual(1, second.releases);
}
