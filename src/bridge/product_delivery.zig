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
pub const snapshot_chunk_bytes = @min(snapshot_impl.chunk_bytes, @import("metawork_product_control").projection_step_bytes);

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

pub const SnapshotStart = struct { read_id: u64, bytes: usize, scratch_bytes: usize = 0 };
pub const SnapshotPreparer = struct {
    context: ?*anyopaque = null,
    prepare_fn: *const fn (?*anyopaque, u64, []u8) anyerror!SnapshotStart,
};
pub const SnapshotCancellation = struct {
    context: *anyopaque,
    cancel_fn: *const fn (*anyopaque, u64) void,
};
pub const SnapshotWriter = struct {
    cancellation: ?SnapshotCancellation = null,
    context: ?*anyopaque = null,
    write_fn: *const fn (?*anyopaque, []u8) anyerror!SnapshotStart,
    fn write(self: SnapshotWriter, output: []u8) !SnapshotStart {
        return self.write_fn(self.context, output);
    }
};
pub const SnapshotMaterializer = struct {
    context: ?*anyopaque = null,
    write_fn: *const fn (?*anyopaque, u64, []u8, usize, usize) anyerror!void,
};

pub const Delivery = struct {
    generation: u64 = 0,
    window_id: ?WindowId = null,
    revision: revision_impl.State = .{},
    snapshot: snapshot_impl.State = .{},
    snapshot_security_epoch: u64 = 0,
    snapshot_product_read_id: u64 = 0,
    emitted_security_epoch: u64 = 0,
    snapshot_cancellation: ?SnapshotCancellation = null,

    pub fn init() Delivery {
        return .{ .snapshot = .initOwned() };
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
        self.emitted_security_epoch = 0;
        self.invalidateSnapshot();
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
        self.emitted_security_epoch = 0;
        self.invalidateSnapshot();
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
        security_epoch: u64,
        now_ns: u64,
        transport: Transport,
    ) (Error || std.fmt.BufPrintError)!RevisionResult {
        const window_id = self.window_id orelse return error.NoConnection;
        if (security_epoch == 0) return error.StaleSnapshot;
        if (security_epoch != self.snapshot_security_epoch) {
            self.invalidateSnapshot();
        }
        if (!self.revision.needsDelivery(revision) and self.emitted_security_epoch == security_epoch) return .unchanged;
        var detail_storage: [160]u8 = undefined;
        const detail = try std.fmt.bufPrint(
            &detail_storage,
            "{{\"generation\":\"{d}\",\"revision\":\"{d}\",\"securityEpoch\":\"{d}\"}}",
            .{ self.generation, revision, security_epoch },
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
        self.emitted_security_epoch = security_epoch;
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
        self.invalidateSnapshot();
        try self.snapshot.acquire();
        self.snapshot_cancellation = writer.cancellation;
        errdefer {
            self.snapshot.invalidateUnreported();
            self.invalidateSnapshot();
        }
        const prepared = try writer.write(self.snapshot.storage);
        self.snapshot_product_read_id = prepared.read_id;
        if (prepared.read_id == 0 or @max(prepared.bytes, prepared.scratch_bytes) > self.snapshot.storage.len)
            return error.InvalidStorage;
        try self.snapshot.publish(prepared.bytes, generation, window_id, snapshot_chunk_bytes);
        self.snapshot.dirty_len = prepared.scratch_bytes;
        self.snapshot_product_read_id = prepared.read_id;
        self.snapshot_security_epoch = security_epoch;
        return .{ .id = self.snapshot.id, .bytes = self.snapshot.len };
    }

    pub fn prepareSnapshot(self: *Delivery, window_id: WindowId, security_epoch: u64, snapshot_id: u64, preparer: SnapshotPreparer) !SnapshotDescriptor {
        const generation = try self.requireWindow(window_id);
        if (security_epoch == 0 or security_epoch != self.snapshot_security_epoch) {
            self.invalidateSnapshot();
            return error.StaleSnapshot;
        }
        if (snapshot_id == 0 or snapshot_id != self.snapshot.id or generation != self.snapshot.generation or window_id != self.snapshot.window_id) return error.StaleSnapshot;
        if (self.snapshot.len != 0) return .{ .id = snapshot_id, .bytes = self.snapshot.len };
        errdefer {
            self.snapshot.invalidateUnreported();
            self.invalidateSnapshot();
        }
        const prepared = try preparer.prepare_fn(preparer.context, self.snapshot_product_read_id, self.snapshot.storage);
        if (prepared.read_id != self.snapshot_product_read_id or @max(prepared.bytes, prepared.scratch_bytes) > self.snapshot.storage.len) return error.InvalidStorage;
        self.snapshot.dirty_len = @max(self.snapshot.dirty_len, prepared.scratch_bytes);
        self.snapshot.len = prepared.bytes;
        return .{ .id = snapshot_id, .bytes = prepared.bytes };
    }

    pub fn snapshotChunk(
        self: *Delivery,
        window_id: WindowId,
        security_epoch: u64,
        snapshot_id: u64,
        offset: usize,
        materializer: SnapshotMaterializer,
    ) ![]const u8 {
        const generation = try self.requireWindow(window_id);
        if (security_epoch == 0 or security_epoch != self.snapshot_security_epoch) {
            self.invalidateSnapshot();
            return error.StaleSnapshot;
        }
        const chunk = try self.snapshot.chunk(snapshot_id, generation, window_id, offset);
        materializer.write_fn(materializer.context, self.snapshot_product_read_id, self.snapshot.storage, offset, chunk.len) catch |err| {
            self.invalidateSnapshot();
            return err;
        };
        return chunk;
    }

    fn invalidateSnapshot(self: *Delivery) void {
        const read_id = self.snapshot_product_read_id;
        const cancellation = self.snapshot_cancellation;
        self.snapshot_cancellation = null;
        self.snapshot.invalidate();
        self.snapshot_security_epoch = 0;
        self.snapshot_product_read_id = 0;
        if (read_id != 0) if (cancellation) |owner| owner.cancel_fn(owner.context, read_id);
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

fn preencodedTestRange(_: ?*anyopaque, _: u64, _: []u8, _: usize, _: usize) !void {}

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

        fn write(_: ?*anyopaque, output: []u8) anyerror!SnapshotStart {
            @memcpy(output[0..2], "{}");
            return .{ .read_id = 1, .bytes = 2 };
        }
    };
    var harness = Harness{};
    const transport = Transport{
        .context = &harness,
        .emit_fn = Harness.emit,
        .start_timer_fn = Harness.startTimer,
        .cancel_timer_fn = Harness.cancelTimer,
    };
    var delivery = Delivery.init();
    defer delivery.deinitOwnedBuffers();
    const generation = try delivery.connect(7, transport);
    try std.testing.expectEqual(@as(u64, 1), generation);
    try std.testing.expectEqual(RevisionResult.retry_scheduled, try delivery.deliverRevision(4, 1, 1, transport));
    try std.testing.expect(delivery.onTimer(retry_timer_id));
    try std.testing.expectEqual(RevisionResult.delivered, try delivery.deliverRevision(5, 1, 2, transport));
    const snapshot = try delivery.publishSnapshot(7, 1, .{ .write_fn = Harness.write });
    try std.testing.expectEqualStrings("{}", try delivery.snapshotChunk(7, 1, snapshot.id, 0, .{ .write_fn = preencodedTestRange }));
    try delivery.disconnect(generation, 7, transport);
    try std.testing.expectError(error.NoConnection, delivery.snapshotChunk(7, 1, snapshot.id, 0, .{ .write_fn = preencodedTestRange }));
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
    var delivery = Delivery.init();
    defer delivery.deinitOwnedBuffers();
    _ = try delivery.connect(3, transport);

    try std.testing.expectEqual(
        RevisionResult.retry_scheduled,
        try delivery.deliverRevision(1, 1, 1, transport),
    );
    try std.testing.expectEqual(
        RevisionResult.retry_scheduled,
        try delivery.deliverRevision(1, 1, 2, transport),
    );
    try std.testing.expectError(
        error.RevisionRetryExhausted,
        delivery.deliverRevision(1, 1, 3, transport),
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

        fn write(_: ?*anyopaque, output: []u8) anyerror!SnapshotStart {
            @memcpy(output[0..2], "{}");
            return .{ .read_id = 1, .bytes = 2 };
        }
    };
    const transport = Transport{
        .emit_fn = Harness.emit,
        .start_timer_fn = Harness.startTimer,
        .cancel_timer_fn = Harness.cancelTimer,
    };
    var delivery = Delivery.init();
    defer delivery.deinitOwnedBuffers();
    const first_generation = try delivery.connect(9, transport);
    const snapshot = try delivery.publishSnapshot(9, 1, .{ .write_fn = Harness.write });
    const second_generation = try delivery.connect(9, transport);

    try std.testing.expectEqual(first_generation + 1, second_generation);
    try std.testing.expectError(
        error.StaleSnapshot,
        delivery.snapshotChunk(9, 1, snapshot.id, 0, .{ .write_fn = preencodedTestRange }),
    );
    delivery.breakConnection(transport);
}

test "Product view security change revokes and clears an in-flight snapshot" {
    const Writer = struct {
        fn write(_: ?*anyopaque, output: []u8) anyerror!SnapshotStart {
            @memcpy(output[0..4], "data");
            return .{ .read_id = 1, .bytes = 4 };
        }
    };
    var storage: [16]u8 = undefined;
    var delivery = Delivery{ .generation = 1, .window_id = 9, .snapshot = .{ .storage = &storage } };
    const before = try delivery.publishSnapshot(9, 7, .{ .write_fn = Writer.write });
    try std.testing.expectEqualStrings("data", try delivery.snapshotChunk(9, 7, before.id, 0, .{ .write_fn = preencodedTestRange }));
    try std.testing.expectError(error.StaleSnapshot, delivery.snapshotChunk(9, 8, before.id, 0, .{ .write_fn = preencodedTestRange }));
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, storage[0..4]);
    try std.testing.expectError(error.StaleSnapshot, delivery.snapshotChunk(9, 7, before.id, 0, .{ .write_fn = preencodedTestRange }));
    const after = try delivery.publishSnapshot(9, 8, .{ .write_fn = Writer.write });
    try std.testing.expect(after.id != before.id);
    try std.testing.expectEqualStrings("data", try delivery.snapshotChunk(9, 8, after.id, 0, .{ .write_fn = preencodedTestRange }));
    try std.testing.expectError(error.StaleSnapshot, delivery.publishSnapshot(9, 0, .{ .write_fn = Writer.write }));
}

test "Product view security notification revokes a descriptor before Renderer requests another snapshot" {
    const Harness = struct {
        detail: [160]u8 = undefined,
        len: usize = 0,
        fn emit(context: ?*anyopaque, _: WindowId, _: []const u8, detail: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            @memcpy(self.detail[0..detail.len], detail);
            self.len = detail.len;
        }
        fn timer(_: ?*anyopaque, _: u64, _: u64, _: bool) !void {}
        fn cancel(_: ?*anyopaque, _: u64) !void {}
        fn write(_: ?*anyopaque, output: []u8) !SnapshotStart {
            @memcpy(output[0..6], "old-ui");
            return .{ .read_id = 1, .bytes = 6 };
        }
    };
    var harness: Harness = .{};
    const transport: Transport = .{ .context = &harness, .emit_fn = Harness.emit, .start_timer_fn = Harness.timer, .cancel_timer_fn = Harness.cancel };
    var delivery = Delivery.init();
    defer delivery.deinitOwnedBuffers();
    _ = try delivery.connect(7, transport);
    defer delivery.breakConnection(transport);
    _ = try delivery.deliverRevision(1, 1, 0, transport);
    const descriptor = try delivery.publishSnapshot(7, 1, .{ .write_fn = Harness.write });
    try std.testing.expectEqual(RevisionResult.delivered, try delivery.deliverRevision(1, 2, 1, transport));
    try std.testing.expectEqualStrings("{\"generation\":\"1\",\"revision\":\"1\",\"securityEpoch\":\"2\"}", harness.detail[0..harness.len]);
    try std.testing.expectEqual(@as(usize, 0), delivery.snapshot.len);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 6), delivery.snapshot.storage[0..6]);
    try std.testing.expectError(error.StaleSnapshot, delivery.snapshotChunk(7, 1, descriptor.id, 0, .{ .write_fn = preencodedTestRange }));
    try std.testing.expectEqual(RevisionResult.unchanged, try delivery.deliverRevision(1, 2, 2, transport));
    try std.testing.expectError(error.StaleSnapshot, delivery.deliverRevision(1, 0, 3, transport));
}

test "Product view failed replacement clears all partial transport bytes and revokes the old descriptor" {
    const Host = struct {
        fn emit(_: ?*anyopaque, _: u64, _: []const u8, _: []const u8) !void {}
        fn timer(_: ?*anyopaque, _: u64, _: u64, _: bool) !void {}
        fn cancel(_: ?*anyopaque, _: u64) !void {}
        fn good(_: ?*anyopaque, output: []u8) !SnapshotStart {
            @memset(output[0..12], 's');
            return .{ .read_id = 1, .bytes = 12 };
        }
        fn bad(_: ?*anyopaque, output: []u8) !SnapshotStart {
            @memset(output[0..3], 'x');
            return error.InjectedCaptureFailure;
        }
    };
    var bytes: [32]u8 = @splat(0);
    var delivery: Delivery = .{ .snapshot = .{ .storage = &bytes } };
    const transport: Transport = .{ .emit_fn = Host.emit, .start_timer_fn = Host.timer, .cancel_timer_fn = Host.cancel };
    _ = try delivery.connect(1, transport);
    const first = try delivery.publishSnapshot(1, 1, .{ .write_fn = Host.good });
    try std.testing.expectError(error.InjectedCaptureFailure, delivery.publishSnapshot(1, 1, .{ .write_fn = Host.bad }));
    for (bytes) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    try std.testing.expectError(error.StaleSnapshot, delivery.snapshotChunk(1, 1, first.id, 0, .{ .write_fn = preencodedTestRange }));
    _ = try delivery.publishSnapshot(1, 1, .{ .write_fn = Host.good });
    delivery.breakConnection(transport);
    for (bytes) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    _ = try delivery.connect(1, transport);
    _ = try delivery.publishSnapshot(1, 1, .{ .write_fn = Host.good });
    _ = try delivery.connect(1, transport);
    for (bytes) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

test "Product view pending preparation binds identity and clears its scratch on revocation" {
    const Host = struct {
        calls: usize = 0,
        fn emit(_: ?*anyopaque, _: u64, _: []const u8, _: []const u8) !void {}
        fn timer(_: ?*anyopaque, _: u64, _: u64, _: bool) !void {}
        fn cancel(_: ?*anyopaque, _: u64) !void {}
        fn begin(_: ?*anyopaque, output: []u8) !SnapshotStart {
            @memset(output[0..12], 'x');
            return .{ .read_id = 42, .bytes = 0, .scratch_bytes = 12 };
        }
        fn prepare(context: ?*anyopaque, read_id: u64, output: []u8) !SnapshotStart {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            try std.testing.expectEqual(@as(u64, 42), read_id);
            self.calls += 1;
            @memset(output[0..18], 'y');
            return .{ .read_id = 42, .bytes = if (self.calls == 2) 18 else 0, .scratch_bytes = 18 };
        }
    };
    var host: Host = .{};
    var bytes: [32]u8 = @splat(0);
    var delivery: Delivery = .{ .snapshot = .{ .storage = &bytes } };
    const transport: Transport = .{ .emit_fn = Host.emit, .start_timer_fn = Host.timer, .cancel_timer_fn = Host.cancel };
    const preparer: SnapshotPreparer = .{ .context = &host, .prepare_fn = Host.prepare };
    _ = try delivery.connect(7, transport);
    const pending = try delivery.publishSnapshot(7, 1, .{ .write_fn = Host.begin });
    try std.testing.expectEqual(@as(usize, 0), pending.bytes);
    try std.testing.expectError(error.StaleSnapshot, delivery.snapshotChunk(7, 1, pending.id, 0, .{ .write_fn = preencodedTestRange }));
    try std.testing.expectError(error.EventWindowMismatch, delivery.prepareSnapshot(8, 1, pending.id, preparer));
    try std.testing.expectError(error.StaleSnapshot, delivery.prepareSnapshot(7, 1, pending.id + 1, preparer));
    try std.testing.expectEqual(@as(usize, 0), host.calls);
    _ = try delivery.prepareSnapshot(7, 1, pending.id, preparer);
    try std.testing.expectEqual(@as(usize, 18), delivery.snapshot.dirty_len);
    try std.testing.expectError(error.StaleSnapshot, delivery.prepareSnapshot(7, 2, pending.id, preparer));
    for (bytes) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    const next = try delivery.publishSnapshot(7, 2, .{ .write_fn = Host.begin });
    const ready = try delivery.prepareSnapshot(7, 2, next.id, preparer);
    try std.testing.expectEqual(@as(usize, 18), ready.bytes);
    delivery.breakConnection(transport);
    for (bytes) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    _ = try delivery.connect(7, transport);
    try std.testing.expectError(error.StaleSnapshot, delivery.prepareSnapshot(7, 2, next.id, preparer));
    delivery.breakConnection(transport);
}

test "snapshot revocation cancels the corresponding Product plan exactly once" {
    const Host = struct {
        id: u64 = 0,
        cancelled: usize = 0,
        bytes: usize = 2,
        fn write(context: ?*anyopaque, output: []u8) !SnapshotStart {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.id += 1;
            @memcpy(output[0..2], "{}");
            return .{ .read_id = self.id, .bytes = self.bytes };
        }
        fn cancel(context: *anyopaque, id: u64) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            std.debug.assert(id == self.id);
            self.cancelled += 1;
        }
        fn emit(_: ?*anyopaque, _: WindowId, _: []const u8, _: []const u8) !void {}
        fn timer(_: ?*anyopaque, _: u64, _: u64, _: bool) !void {}
        fn cancelTimer(_: ?*anyopaque, _: u64) !void {}
    };
    var host: Host = .{};
    var delivery = Delivery.init();
    defer delivery.deinitOwnedBuffers();
    const transport: Transport = .{ .emit_fn = Host.emit, .start_timer_fn = Host.timer, .cancel_timer_fn = Host.cancelTimer };
    _ = try delivery.connect(7, transport);
    const writer: SnapshotWriter = .{ .context = &host, .write_fn = Host.write, .cancellation = .{ .context = &host, .cancel_fn = Host.cancel } };
    _ = try delivery.publishSnapshot(7, 1, writer);
    _ = try delivery.publishSnapshot(7, 1, writer);
    try std.testing.expectEqual(@as(usize, 1), host.cancelled);
    _ = try delivery.deliverRevision(2, 2, 1, transport);
    try std.testing.expectEqual(@as(usize, 2), host.cancelled);
    host.bytes = 0;
    _ = try delivery.publishSnapshot(7, 2, writer);
    delivery.breakConnection(transport);
    try std.testing.expectEqual(@as(usize, 3), host.cancelled);
    delivery.breakConnection(transport);
    try std.testing.expectEqual(@as(usize, 3), host.cancelled);
    _ = try delivery.connect(7, transport);
    host.bytes = delivery.snapshot.storage.len + 1;
    try std.testing.expectError(error.InvalidStorage, delivery.publishSnapshot(7, 2, writer));
    try std.testing.expectEqual(@as(usize, 4), host.cancelled);
    delivery.breakConnection(transport);
}

test "Product view failed write gives owned transport storage back instead of clearing its capacity" {
    const Host = struct {
        fn emit(_: ?*anyopaque, _: WindowId, _: []const u8, _: []const u8) !void {}
        fn timer(_: ?*anyopaque, _: u64, _: u64, _: bool) !void {}
        fn cancel(_: ?*anyopaque, _: u64) !void {}
        // A failure reports no extent, so it may have written anywhere.
        fn fail(_: ?*anyopaque, output: []u8) !SnapshotStart {
            output[0] = 'x';
            output[output.len - 1] = 'x';
            return error.InjectedCaptureFailure;
        }
        fn begin(_: ?*anyopaque, output: []u8) !SnapshotStart {
            // Storage mapped after a failure carries none of its bytes.
            try std.testing.expectEqual(@as(u8, 0), output[0]);
            try std.testing.expectEqual(@as(u8, 0), output[output.len - 1]);
            @memset(output[0..12], 'x');
            return .{ .read_id = 42, .bytes = 0, .scratch_bytes = 12 };
        }
        fn failPreparation(_: ?*anyopaque, _: u64, output: []u8) !SnapshotStart {
            output[output.len - 1] = 'y';
            return error.InjectedPreparationFailure;
        }
    };
    const transport: Transport = .{ .emit_fn = Host.emit, .start_timer_fn = Host.timer, .cancel_timer_fn = Host.cancel };
    const preparer: SnapshotPreparer = .{ .prepare_fn = Host.failPreparation };
    var delivery = Delivery.init();
    defer delivery.deinitOwnedBuffers();
    _ = try delivery.connect(7, transport);
    defer delivery.breakConnection(transport);
    try std.testing.expectEqual(@as(usize, 0), delivery.snapshot.storage.len);

    try std.testing.expectError(error.InjectedCaptureFailure, delivery.publishSnapshot(7, 1, .{ .write_fn = Host.fail }));
    try std.testing.expectEqual(@as(usize, 0), delivery.snapshot.storage.len);

    const pending = try delivery.publishSnapshot(7, 1, .{ .write_fn = Host.begin });
    try std.testing.expectEqual(snapshot_max_bytes, delivery.snapshot.storage.len);
    try std.testing.expectError(error.InjectedPreparationFailure, delivery.prepareSnapshot(7, 1, pending.id, preparer));
    try std.testing.expectEqual(@as(usize, 0), delivery.snapshot.storage.len);
    try std.testing.expectError(error.StaleSnapshot, delivery.prepareSnapshot(7, 1, pending.id, preparer));

    _ = try delivery.publishSnapshot(7, 1, .{ .write_fn = Host.begin });
}

test "Product view read is bound to the storage it began in, so the next snapshot may use other storage" {
    const control = @import("metawork_product_control");
    const Read = struct {
        fn emit(_: ?*anyopaque, _: WindowId, _: []const u8, _: []const u8) !void {}
        fn timer(_: ?*anyopaque, _: u64, _: u64, _: bool) !void {}
        fn cancel(_: ?*anyopaque, _: u64) !void {}
        fn begin(context: ?*anyopaque, output: []u8) !SnapshotStart {
            const runtime: *control.Runtime = @ptrCast(@alignCast(context.?));
            const read = try runtime.writeSnapshot(output, .{});
            return .{ .read_id = read.id, .bytes = read.bytes, .scratch_bytes = read.scratch_bytes };
        }
        fn prepare(context: ?*anyopaque, id: u64, output: []u8) !SnapshotStart {
            const runtime: *control.Runtime = @ptrCast(@alignCast(context.?));
            const read = try runtime.continueSnapshot(id, output);
            return .{ .read_id = read.id, .bytes = read.bytes, .scratch_bytes = read.scratch_bytes };
        }
        fn range(context: ?*anyopaque, id: u64, output: []u8, offset: usize, length: usize) !void {
            const runtime: *control.Runtime = @ptrCast(@alignCast(context.?));
            try runtime.writeSnapshotRange(id, output, offset, length);
        }
        fn ready(delivery: *Delivery, runtime: *control.Runtime) !SnapshotDescriptor {
            const epoch = runtime.projectionSecurityEpoch();
            var view = try delivery.publishSnapshot(7, epoch, .{ .context = runtime, .write_fn = begin });
            while (view.bytes == 0) view = try delivery.prepareSnapshot(7, epoch, view.id, .{ .context = runtime, .prepare_fn = prepare });
            return view;
        }
        fn complete(delivery: *Delivery, runtime: *control.Runtime) ![]const u8 {
            const view = try ready(delivery, runtime);
            var offset: usize = 0;
            while (offset < view.bytes) : (offset += snapshot_chunk_bytes)
                _ = try delivery.snapshotChunk(7, runtime.projectionSecurityEpoch(), view.id, offset, .{ .context = runtime, .write_fn = range });
            return delivery.snapshot.storage[0..view.bytes];
        }
    };
    const runtime = try std.testing.allocator.create(control.Runtime);
    defer std.testing.allocator.destroy(runtime);
    try control.TestSupport.maximumFixture(runtime);
    defer runtime.deinit();
    const blocks = try std.testing.allocator.alloc(u8, 2 * 1024 * 1024);
    defer std.testing.allocator.free(blocks);
    const first = blocks[0 .. blocks.len / 2];
    const second = blocks[blocks.len / 2 ..];
    const transport: Transport = .{ .emit_fn = Read.emit, .start_timer_fn = Read.timer, .cancel_timer_fn = Read.cancel };

    var delivery: Delivery = .{ .snapshot = .{ .storage = first } };
    _ = try delivery.connect(7, transport);
    const original = try std.testing.allocator.dupe(u8, try Read.complete(&delivery, runtime));
    defer std.testing.allocator.free(original);
    try std.testing.expect(original.len > snapshot_chunk_bytes);

    // Between snapshots the transport bytes may move: the next read binds anew.
    delivery.breakConnection(transport);
    delivery.snapshot.storage = second;
    _ = try delivery.connect(7, transport);
    try std.testing.expectEqualStrings(original, try Read.complete(&delivery, runtime));

    // Within one read they may not: Product refuses the read it began elsewhere.
    const view = try Read.ready(&delivery, runtime);
    delivery.snapshot.storage = first;
    try std.testing.expectError(error.StaleSnapshot, delivery.snapshotChunk(7, runtime.projectionSecurityEpoch(), view.id, 0, .{ .context = runtime, .write_fn = Read.range }));
    delivery.breakConnection(transport);
}
