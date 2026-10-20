//! Bridge-owned Renderer connection, revision, and snapshot delivery state.
//! It owns transport bytes and policy-neutral retry facts, never Workbench
//! product truth or any automation-specific transport.

const std = @import("std");
const revision_impl = @import("revision_delivery.zig");
const snapshot_impl = @import("snapshot_delivery.zig");

pub const WindowId = snapshot_impl.WindowId;

pub const retry_timer_id = revision_impl.retry_timer_id;
pub const event_name = revision_impl.event_name;
pub const snapshot_max_bytes = snapshot_impl.max_bytes;
pub const snapshot_chunk_bytes = snapshot_impl.chunk_bytes;

pub const ConnectionError = error{
    NoConnection,
    StaleConnection,
    EventWindowMismatch,
};

pub const Error = snapshot_impl.Error || ConnectionError || error{
    ConnectionExhausted,
    RevisionRetryExhausted,
    RevisionRetryUnavailable,
};

pub const RevisionResult = enum { unchanged, delivered, retry_scheduled };

pub const SnapshotDescriptor = struct {
    id: u64,
    bytes: usize,
};

pub const Transport = struct {
    context: ?*anyopaque = null,
    emit_fn: *const fn (?*anyopaque, WindowId, []const u8, []const u8) anyerror!void,
    start_timer_fn: *const fn (?*anyopaque, u64, u64, bool) anyerror!void,
    cancel_timer_fn: *const fn (?*anyopaque, u64) anyerror!void,

    fn emit(self: Transport, window_id: WindowId, detail: []const u8) !void {
        return self.emit_fn(self.context, window_id, event_name, detail);
    }

    fn startRetryTimer(self: Transport) !void {
        return self.start_timer_fn(
            self.context,
            retry_timer_id,
            revision_impl.retry_interval_ns,
            false,
        );
    }

    fn cancelRetryTimer(self: Transport) void {
        self.cancel_timer_fn(self.context, retry_timer_id) catch {};
    }
};

pub const SnapshotWriter = struct {
    context: ?*anyopaque = null,
    write_fn: *const fn (?*anyopaque, []u8) anyerror![]const u8,

    fn write(self: SnapshotWriter, output: []u8) ![]const u8 {
        return self.write_fn(self.context, output);
    }
};

pub const Delivery = struct {
    generation: u64 = 0,
    window_id: ?WindowId = null,
    revision: revision_impl.State = .{},
    snapshot: snapshot_impl.State = .{},
    snapshot_security_epoch: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!Delivery {
        return .{ .snapshot = try snapshot_impl.State.initOwned(allocator) };
    }

    pub fn deinitOwnedBuffers(self: *Delivery) void {
        std.debug.assert(self.window_id == null);
        self.snapshot.deinitOwnedBuffers();
        self.* = undefined;
    }

    pub fn connect(
        self: *Delivery,
        window_id: WindowId,
        transport: Transport,
    ) Error!u64 {
        if (window_id == 0) return error.EventWindowMismatch;
        if (self.generation == std.math.maxInt(u64)) return error.ConnectionExhausted;
        if (self.revision.timer_armed) transport.cancelRetryTimer();
        self.generation += 1;
        self.window_id = window_id;
        self.revision.resetConnection();
        self.snapshot.invalidate();
        return self.generation;
    }

    pub fn disconnect(
        self: *Delivery,
        generation: u64,
        window_id: WindowId,
        transport: Transport,
    ) ConnectionError!void {
        _ = try self.requireConnection(generation, window_id);
        self.breakConnection(transport);
    }

    pub fn breakConnection(self: *Delivery, transport: Transport) void {
        if (self.revision.timer_armed) transport.cancelRetryTimer();
        self.window_id = null;
        self.revision.resetConnection();
        self.snapshot.invalidate();
    }

    pub fn connectedGeneration(self: *const Delivery) ?u64 {
        return if (self.window_id == null) null else self.generation;
    }

    pub fn connectedWindow(self: *const Delivery) ?WindowId {
        return self.window_id;
    }

    pub fn requireWindow(self: *const Delivery, window_id: WindowId) ConnectionError!u64 {
        return self.requireConnection(self.generation, window_id);
    }

    pub fn validateConnection(
        self: *const Delivery,
        generation: u64,
        window_id: WindowId,
    ) ConnectionError!void {
        _ = try self.requireConnection(generation, window_id);
    }

    pub fn onTimer(self: *Delivery, timer_id: u64) bool {
        if (timer_id != retry_timer_id or !self.revision.timer_armed) return false;
        self.revision.timerFired();
        return true;
    }

    pub fn deliverRevision(
        self: *Delivery,
        revision: u64,
        now_ns: u64,
        transport: Transport,
    ) (Error || std.fmt.BufPrintError)!RevisionResult {
        const window_id = self.window_id orelse return error.NoConnection;
        if (!self.revision.needsDelivery(revision)) return .unchanged;
        var detail_storage: [96]u8 = undefined;
        const detail = try std.fmt.bufPrint(
            &detail_storage,
            "{{\"revision\":\"{d}\"}}",
            .{revision},
        );
        transport.emit(window_id, detail) catch {
            const timer_was_armed = self.revision.timer_armed;
            if (self.revision.fail(now_ns) == .exhausted)
                return error.RevisionRetryExhausted;
            if (!timer_was_armed) {
                transport.startRetryTimer() catch return error.RevisionRetryUnavailable;
                self.revision.timerScheduled();
            }
            return .retry_scheduled;
        };
        if (self.revision.timer_armed) transport.cancelRetryTimer();
        self.revision.commit(revision);
        return .delivered;
    }

    pub fn publishSnapshot(
        self: *Delivery,
        window_id: WindowId,
        security_epoch: u64,
        writer: SnapshotWriter,
    ) !SnapshotDescriptor {
        const generation = try self.requireWindow(window_id);
        if (security_epoch == 0) return error.StaleSnapshot;
        if (self.snapshot_security_epoch != security_epoch)
            std.crypto.secureZero(u8, self.snapshot.storage[0..self.snapshot.len]);
        self.snapshot.invalidate();
        self.snapshot_security_epoch = 0;
        const encoded = try writer.write(self.snapshot.storage);
        if (encoded.len == 0 or encoded.ptr != self.snapshot.storage.ptr or
            encoded.len > self.snapshot.storage.len)
            return error.InvalidStorage;
        try self.snapshot.publish(encoded.len, generation, window_id);
        self.snapshot_security_epoch = security_epoch;
        return .{ .id = self.snapshot.id, .bytes = self.snapshot.len };
    }

    pub fn snapshotChunk(
        self: *Delivery,
        window_id: WindowId,
        security_epoch: u64,
        snapshot_id: u64,
        offset: usize,
    ) (ConnectionError || snapshot_impl.Error)![]const u8 {
        const generation = try self.requireWindow(window_id);
        if (security_epoch == 0 or security_epoch != self.snapshot_security_epoch) {
            std.crypto.secureZero(u8, self.snapshot.storage[0..self.snapshot.len]);
            self.snapshot.invalidate();
            self.snapshot_security_epoch = 0;
            return error.StaleSnapshot;
        }
        return self.snapshot.chunk(snapshot_id, generation, window_id, offset);
    }

    fn requireConnection(
        self: *const Delivery,
        generation: u64,
        window_id: WindowId,
    ) ConnectionError!u64 {
        const connected_window = self.window_id orelse return error.NoConnection;
        if (generation == 0 or generation != self.generation) return error.StaleConnection;
        if (window_id == 0 or window_id != connected_window) return error.EventWindowMismatch;
        return generation;
    }
};

test "product delivery owns connection retry and snapshot identity" {
    const Harness = struct {
        emit_failures: usize = 1,
        timer_starts: usize = 0,
        timer_cancels: usize = 0,

        fn emit(context: ?*anyopaque, _: WindowId, _: []const u8, _: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (self.emit_failures != 0) {
                self.emit_failures -= 1;
                return error.InjectedEmitFailure;
            }
        }

        fn startTimer(context: ?*anyopaque, _: u64, _: u64, _: bool) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.timer_starts += 1;
        }

        fn cancelTimer(context: ?*anyopaque, _: u64) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.timer_cancels += 1;
        }

        fn write(_: ?*anyopaque, output: []u8) anyerror![]const u8 {
            @memcpy(output[0..2], "{}");
            return output[0..2];
        }
    };
    var harness = Harness{};
    const transport = Transport{
        .context = &harness,
        .emit_fn = Harness.emit,
        .start_timer_fn = Harness.startTimer,
        .cancel_timer_fn = Harness.cancelTimer,
    };
    var delivery = try Delivery.init(std.testing.allocator);
    defer delivery.deinitOwnedBuffers();
    const generation = try delivery.connect(7, transport);
    try std.testing.expectEqual(@as(u64, 1), generation);
    try std.testing.expectEqual(RevisionResult.retry_scheduled, try delivery.deliverRevision(4, 1, transport));
    try std.testing.expect(delivery.onTimer(retry_timer_id));
    try std.testing.expectEqual(RevisionResult.delivered, try delivery.deliverRevision(5, 2, transport));
    const snapshot = try delivery.publishSnapshot(7, 1, .{ .write_fn = Harness.write });
    try std.testing.expectEqualStrings("{}", try delivery.snapshotChunk(7, 1, snapshot.id, 0));
    try delivery.disconnect(generation, 7, transport);
    try std.testing.expectError(error.NoConnection, delivery.snapshotChunk(7, 1, snapshot.id, 0));
}

test "product revision retry exhausts a bounded transport budget" {
    const Harness = struct {
        timer_starts: usize = 0,

        fn emit(_: ?*anyopaque, _: WindowId, _: []const u8, _: []const u8) anyerror!void {
            return error.InjectedEmitFailure;
        }

        fn startTimer(context: ?*anyopaque, _: u64, _: u64, _: bool) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.timer_starts += 1;
        }

        fn cancelTimer(_: ?*anyopaque, _: u64) anyerror!void {}
    };
    var harness = Harness{};
    const transport = Transport{
        .context = &harness,
        .emit_fn = Harness.emit,
        .start_timer_fn = Harness.startTimer,
        .cancel_timer_fn = Harness.cancelTimer,
    };
    var delivery = try Delivery.init(std.testing.allocator);
    defer delivery.deinitOwnedBuffers();
    _ = try delivery.connect(3, transport);

    try std.testing.expectEqual(
        RevisionResult.retry_scheduled,
        try delivery.deliverRevision(1, 1, transport),
    );
    try std.testing.expectEqual(
        RevisionResult.retry_scheduled,
        try delivery.deliverRevision(1, 2, transport),
    );
    try std.testing.expectError(
        error.RevisionRetryExhausted,
        delivery.deliverRevision(1, 3, transport),
    );
    try std.testing.expectEqual(@as(usize, 1), harness.timer_starts);
    try std.testing.expect(delivery.revision.timer_armed);
    delivery.breakConnection(transport);
}

test "Renderer reconnect invalidates snapshots from the previous generation" {
    const Harness = struct {
        fn emit(_: ?*anyopaque, _: WindowId, _: []const u8, _: []const u8) anyerror!void {}
        fn startTimer(_: ?*anyopaque, _: u64, _: u64, _: bool) anyerror!void {}
        fn cancelTimer(_: ?*anyopaque, _: u64) anyerror!void {}

        fn write(_: ?*anyopaque, output: []u8) anyerror![]const u8 {
            @memcpy(output[0..2], "{}");
            return output[0..2];
        }
    };
    const transport = Transport{
        .emit_fn = Harness.emit,
        .start_timer_fn = Harness.startTimer,
        .cancel_timer_fn = Harness.cancelTimer,
    };
    var delivery = try Delivery.init(std.testing.allocator);
    defer delivery.deinitOwnedBuffers();
    const first_generation = try delivery.connect(9, transport);
    const snapshot = try delivery.publishSnapshot(9, 1, .{ .write_fn = Harness.write });
    const second_generation = try delivery.connect(9, transport);

    try std.testing.expectEqual(first_generation + 1, second_generation);
    try std.testing.expectError(
        error.StaleSnapshot,
        delivery.snapshotChunk(9, 1, snapshot.id, 0),
    );
    delivery.breakConnection(transport);
}

test "Product view security change revokes and clears an in-flight snapshot" {
    const Writer = struct {
        fn write(_: ?*anyopaque, output: []u8) anyerror![]const u8 {
            @memcpy(output[0..4], "data");
            return output[0..4];
        }
    };
    var storage: [16]u8 = undefined;
    var delivery = Delivery{ .generation = 1, .window_id = 9, .snapshot = .{ .storage = &storage } };
    const before = try delivery.publishSnapshot(9, 7, .{ .write_fn = Writer.write });
    try std.testing.expectEqualStrings("data", try delivery.snapshotChunk(9, 7, before.id, 0));
    try std.testing.expectError(error.StaleSnapshot, delivery.snapshotChunk(9, 8, before.id, 0));
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, storage[0..4]);
    try std.testing.expectError(error.StaleSnapshot, delivery.snapshotChunk(9, 7, before.id, 0));
    const after = try delivery.publishSnapshot(9, 8, .{ .write_fn = Writer.write });
    try std.testing.expect(after.id != before.id);
    try std.testing.expectEqualStrings("data", try delivery.snapshotChunk(9, 8, after.id, 0));
    try std.testing.expectError(error.StaleSnapshot, delivery.publishSnapshot(9, 0, .{ .write_fn = Writer.write }));
}
