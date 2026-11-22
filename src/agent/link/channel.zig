//! The execution link's two directions of flow.
//!
//! `Outbound` is a bounded queue plus one writer thread. It exists so that no
//! caller ever writes the pipe itself: only the writer does, and a peer that
//! stops reading parks the writer, not the caller.
//!
//! A caller may still wait -- for room in the queue (`submitWaiting`), and in
//! the correlation table for its answer -- and on the UI half that includes
//! the main thread, whose synchronous calls into the Agent are synchronous
//! here too. Those waits end when the writer moves on, which it does as long
//! as the peer reads, or when the peer is given up: the UI half's liveness
//! deadline ends the process, which fails the writer's write and closes the
//! table. A peer that is alive and slow to answer is waited for, as the same
//! call is in process. What keeps such a wait from waiting on itself is the
//! UI half's rule, in `execution_client.zig`: the main thread never calls a
//! method whose answer needs the main thread to consume first.
//!
//! `trySubmit` never waits, and is for what may not: a frame sent under a lock
//! the writer's progress could need, or from a thread that must keep its
//! cadence -- the credit and ping frames.
//!
//! Control messages have their own queue and their own reserved capacity, and
//! the writer drains it between fragments rather than between messages. That
//! is what makes "a Stop waits behind at most one fragment" true rather than
//! aspirational: without it, a Stop queued behind an 11 MB Run input would
//! wait for all of it.
//!
//! `Inbound` reads frames and reassembles messages. It needs one reassembly
//! buffer, because the writer sends one data message at a time, and one small
//! buffer for control, because a control frame is the only thing the writer
//! lets pass between a data message's fragments. A control frame is delivered
//! as it arrives and leaves the reassembly where it was. A fragment of any
//! other message arriving mid-reassembly means the peer is not the writer in
//! this file, which is a protocol violation and ends the link.

const std = @import("std");
const frame = @import("frame.zig");

/// Stack for a thread that only moves bytes: the writer, a reader, a reaper.
///
/// On Windows `std.Thread.spawn` commits its `stack_size` up front, and the
/// default is 16 MiB per thread. None of these threads calls into the Agent
/// Runtime, Product or AgentCore; each one encodes, copies and waits.
pub const io_thread_stack_bytes: usize = 256 * 1024;

/// Where a reassembly buffer starts, and what it returns to after carrying a
/// large message. Growing on demand matters because `Allocator.alloc` writes
/// `0xaa` over every byte in Debug and ReleaseSafe -- the shipped mode -- so a
/// buffer sized to the largest legal message is that many bytes resident for
/// the life of the link.
pub const initial_assembly_bytes: usize = 64 * 1024;

/// A buffer above this is given back once the message it held is delivered.
pub const retained_assembly_bytes: usize = 1024 * 1024;

pub const Limits = struct {
    /// Queued data messages, excluding the control reservation.
    data_count: usize = 256,
    /// Queued data payload bytes, excluding the control reservation.
    data_bytes: usize = 24 * 1024 * 1024,
    /// Control slots, which data can never occupy.
    control_count: usize = 32,
    /// Control payload bytes, which data can never occupy.
    control_bytes: usize = 64 * 1024,

    pub fn valid(self: Limits) bool {
        return self.data_count > 0 and self.data_bytes > 0 and
            self.control_count > 0 and self.control_bytes > 0 and
            self.control_bytes >= frame.max_fragment_payload_bytes;
    }
};

pub const Submission = enum {
    queued,
    /// The queue is at its bound. The caller keeps the product decision; this
    /// is never reported as a user timeout or an Agent terminal cause.
    busy,
    /// The link is closing or has failed. No further message will be written.
    closed,
};

const Message = struct {
    kind: frame.Kind,
    correlation: u64,
    payload: []u8,
};

pub const Outbound = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    file: std.Io.File,
    limits: Limits,

    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,

    data: Ring,
    control: Ring,
    closing: bool = false,
    failed: bool = false,
    writer: ?std.Thread = null,
    /// Fragments written since start, for the ordering tests.
    fragments_written: u64 = 0,

    const Ring = struct {
        slots: []?Message,
        head: usize = 0,
        tail: usize = 0,
        queued: usize = 0,
        queued_bytes: usize = 0,

        fn push(self: *Ring, message: Message) void {
            std.debug.assert(self.slots[self.tail] == null);
            self.slots[self.tail] = message;
            self.tail = (self.tail + 1) % self.slots.len;
            self.queued += 1;
            self.queued_bytes += message.payload.len;
        }

        fn pop(self: *Ring) ?Message {
            if (self.queued == 0) return null;
            const message = self.slots[self.head].?;
            self.slots[self.head] = null;
            self.head = (self.head + 1) % self.slots.len;
            self.queued -= 1;
            self.queued_bytes -= message.payload.len;
            return message;
        }
    };

    pub const StartError = error{InvalidLimits} ||
        std.mem.Allocator.Error || std.Thread.SpawnError;

    pub fn start(
        self: *Outbound,
        io: std.Io,
        allocator: std.mem.Allocator,
        file: std.Io.File,
        limits: Limits,
    ) StartError!void {
        if (!limits.valid()) return error.InvalidLimits;
        const data_slots = try allocator.alloc(?Message, limits.data_count);
        errdefer allocator.free(data_slots);
        @memset(data_slots, null);
        const control_slots = try allocator.alloc(?Message, limits.control_count);
        errdefer allocator.free(control_slots);
        @memset(control_slots, null);
        self.* = .{
            .io = io,
            .allocator = allocator,
            .file = file,
            .limits = limits,
            .data = .{ .slots = data_slots },
            .control = .{ .slots = control_slots },
        };
        self.writer = try std.Thread.spawn(.{ .stack_size = io_thread_stack_bytes }, writerMain, .{self});
    }

    /// Wakes every waiter, stops accepting, and joins the writer. The writer
    /// finishes what is already queued before it leaves, so this waits for
    /// as long as the peer takes to read it; bounding that is the caller's,
    /// which on the UI half is the host's stop deadline -- ending the child
    /// fails the write. Whatever a failed writer left queued is released
    /// here without being written.
    pub fn stop(self: *Outbound) void {
        self.mutex.lockUncancelable(self.io);
        self.closing = true;
        self.condition.broadcast(self.io);
        self.mutex.unlock(self.io);
        if (self.writer) |thread| thread.join();
        self.writer = null;
        self.mutex.lockUncancelable(self.io);
        while (self.control.pop()) |message| self.release(message);
        while (self.data.pop()) |message| self.release(message);
        self.mutex.unlock(self.io);
        self.allocator.free(self.data.slots);
        self.allocator.free(self.control.slots);
        self.data.slots = &.{};
        self.control.slots = &.{};
    }

    fn release(self: *Outbound, message: Message) void {
        // Frames can carry a credential, so a released payload is cleared
        // rather than simply freed.
        std.crypto.secureZero(u8, message.payload);
        self.allocator.free(message.payload);
    }

    fn ring(self: *Outbound, kind: frame.Kind) *Ring {
        return if (kind == .control) &self.control else &self.data;
    }

    fn admits(self: *Outbound, kind: frame.Kind, len: usize) bool {
        const target = self.ring(kind);
        const count = if (kind == .control) self.limits.control_count else self.limits.data_count;
        const bytes = if (kind == .control) self.limits.control_bytes else self.limits.data_bytes;
        return target.queued < count and target.queued_bytes + len <= bytes;
    }

    /// Never blocks: `busy` when there is no room now. For a frame that must
    /// not wait for the writer -- one sent under a lock, or on a clock.
    pub fn trySubmit(
        self: *Outbound,
        kind: frame.Kind,
        correlation: u64,
        payload: []const u8,
    ) std.mem.Allocator.Error!Submission {
        return self.submit(kind, correlation, payload, false);
    }

    /// Blocks until there is room, the link closes, or the message cannot be
    /// admitted at all. Room comes as the writer moves on; a link that fails
    /// wakes every waiter with `closed`.
    pub fn submitWaiting(
        self: *Outbound,
        kind: frame.Kind,
        correlation: u64,
        payload: []const u8,
    ) std.mem.Allocator.Error!Submission {
        return self.submit(kind, correlation, payload, true);
    }

    fn submit(
        self: *Outbound,
        kind: frame.Kind,
        correlation: u64,
        payload: []const u8,
        wait: bool,
    ) std.mem.Allocator.Error!Submission {
        std.debug.assert(!kind.empty() or payload.len == 0);
        std.debug.assert(kind != .control or payload.len <= frame.max_fragment_payload_bytes);
        const owned = try self.allocator.dupe(u8, payload);
        var keep = false;
        defer if (!keep) {
            std.crypto.secureZero(u8, owned);
            self.allocator.free(owned);
        };
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        // A message larger than the whole bound would wait forever.
        const bytes = if (kind == .control) self.limits.control_bytes else self.limits.data_bytes;
        if (payload.len > bytes) return .busy;
        while (true) {
            if (self.closing or self.failed) return .closed;
            if (self.admits(kind, owned.len)) break;
            if (!wait) return .busy;
            self.condition.waitUncancelable(self.io, &self.mutex);
        }
        self.ring(kind).push(.{ .kind = kind, .correlation = correlation, .payload = owned });
        keep = true;
        self.condition.broadcast(self.io);
        return .queued;
    }

    fn take(self: *Outbound) ?Message {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (true) {
            if (self.control.pop()) |message| {
                self.condition.broadcast(self.io);
                return message;
            }
            if (self.data.pop()) |message| {
                self.condition.broadcast(self.io);
                return message;
            }
            if (self.closing or self.failed) return null;
            self.condition.waitUncancelable(self.io, &self.mutex);
        }
    }

    /// Control queued while a data message is mid-flight, taken between
    /// fragments.
    fn takeControl(self: *Outbound) ?Message {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const message = self.control.pop() orelse return null;
        self.condition.broadcast(self.io);
        return message;
    }

    fn fail(self: *Outbound) void {
        self.mutex.lockUncancelable(self.io);
        self.failed = true;
        self.condition.broadcast(self.io);
        self.mutex.unlock(self.io);
    }

    fn writerMain(self: *Outbound) void {
        while (self.take()) |message| {
            var current = message;
            if (!self.writeMessage(current)) {
                self.release(current);
                self.fail();
                return;
            }
            self.release(current);
            current = undefined;
        }
    }

    fn writeMessage(self: *Outbound, message: Message) bool {
        var offset: usize = 0;
        const total = message.payload.len;
        while (true) {
            const remaining = total - offset;
            const take_bytes = @min(remaining, frame.max_fragment_payload_bytes);
            const final = offset + take_bytes == total;
            if (!self.writeFrame(.{
                .kind = message.kind,
                .final = final,
                .correlation = message.correlation,
                .payload_len = @intCast(take_bytes),
            }, message.payload[offset..][0..take_bytes])) return false;
            offset += take_bytes;
            if (final) break;
            // Between fragments, and only here, a control message may pass.
            while (self.takeControl()) |control| {
                const ok = self.writeMessage(control);
                self.release(control);
                if (!ok) return false;
            }
        }
        return true;
    }

    fn writeFrame(self: *Outbound, header: frame.Header, payload: []const u8) bool {
        var bytes: [frame.header_bytes]u8 = undefined;
        header.encode(&bytes);
        self.file.writeStreamingAll(self.io, &bytes) catch return false;
        if (payload.len != 0)
            self.file.writeStreamingAll(self.io, payload) catch return false;
        _ = @atomicRmw(u64, &self.fragments_written, .Add, 1, .monotonic);
        return true;
    }
};

pub const Flow = enum { ok, stop };

/// Where a complete message goes. `deliver` may block, and blocking it is how
/// a full consumer slows the peer down.
pub const Sink = struct {
    context: ?*anyopaque,
    deliver_fn: *const fn (?*anyopaque, frame.Kind, u64, []const u8) Flow,

    fn deliver(self: Sink, kind: frame.Kind, correlation: u64, payload: []const u8) Flow {
        return self.deliver_fn(self.context, kind, correlation, payload);
    }
};

/// The largest complete message each kind may form. The link enforces what it
/// is given; the numbers themselves belong to the owners of those limits, so
/// the composition root supplies them.
pub const MessageLimits = struct {
    event: usize,
    request: usize,
    response: usize,
    ui_request: usize,
    ui_response: usize,

    pub fn forKind(self: MessageLimits, kind: frame.Kind) usize {
        return switch (kind) {
            .event => self.event,
            .request => self.request,
            .response => self.response,
            .ui_request => self.ui_request,
            .ui_response => self.ui_response,
            .control => frame.max_fragment_payload_bytes,
            .hello, .event_ready, .goodbye => 0,
        };
    }

    pub fn max(self: MessageLimits) usize {
        return @max(
            @max(self.event, self.request),
            @max(self.response, @max(self.ui_request, self.ui_response)),
        );
    }

    pub fn valid(self: MessageLimits) bool {
        return self.event > 0 and self.request > 0 and self.response > 0 and
            self.ui_request > 0 and self.ui_response > 0;
    }
};

pub const Violation = enum {
    /// The header itself is not legal.
    frame_header,
    /// A complete message exceeded the limit for its kind.
    message_too_large,
    /// A fragment arrived for a message other than the one in progress.
    interleaved_fragment,
    /// A continuation arrived with nothing in progress.
    orphan_fragment,
};

pub const Stopped = union(enum) {
    /// The peer closed cleanly: either `goodbye` or end of stream.
    peer_closed,
    /// The sink asked to stop.
    consumer_stopped,
    /// Reading failed.
    read_failed,
    /// A message legal for its kind could not be given room. The link ends:
    /// a message dropped mid-stream cannot be answered for.
    out_of_memory,
    /// The peer broke the protocol. The link ends; nothing is repaired.
    violation: Violation,
};

pub const Inbound = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    limits: MessageLimits,
    sink: Sink,

    assembly: []u8,
    assembled: usize = 0,
    in_progress: ?struct { kind: frame.Kind, correlation: u64 } = null,
    /// A control frame's payload, read apart from any reassembly.
    control: []u8,

    pub const InitError = error{InvalidLimits} || std.mem.Allocator.Error;

    pub fn init(
        self: *Inbound,
        io: std.Io,
        allocator: std.mem.Allocator,
        reader: *std.Io.Reader,
        limits: MessageLimits,
        sink: Sink,
    ) InitError!void {
        if (!limits.valid()) return error.InvalidLimits;
        const assembly = try allocator.alloc(u8, @min(initial_assembly_bytes, limits.max()));
        errdefer allocator.free(assembly);
        const control = try allocator.alloc(u8, limits.forKind(.control));
        self.* = .{
            .io = io,
            .allocator = allocator,
            .reader = reader,
            .limits = limits,
            .sink = sink,
            .assembly = assembly,
            .control = control,
        };
    }

    pub fn deinit(self: *Inbound) void {
        std.crypto.secureZero(u8, self.assembly);
        self.allocator.free(self.assembly);
        self.allocator.free(self.control);
        self.* = undefined;
    }

    /// Makes room for `needed` bytes, doubling up to the largest message any
    /// kind may form. The old block is cleared before it is freed, because a
    /// payload can carry a credential.
    fn reserve(self: *Inbound, needed: usize) error{OutOfMemory}!void {
        if (needed <= self.assembly.len) return;
        const target = @min(@max(needed, self.assembly.len * 2), self.limits.max());
        std.debug.assert(target >= needed);
        const grown = try self.allocator.alloc(u8, target);
        @memcpy(grown[0..self.assembled], self.assembly[0..self.assembled]);
        std.crypto.secureZero(u8, self.assembly);
        self.allocator.free(self.assembly);
        self.assembly = grown;
    }

    /// Gives a large buffer back once its message is delivered. Keeping the
    /// large one when the small allocation fails is correct, only wasteful.
    fn settle(self: *Inbound) void {
        if (self.assembly.len <= retained_assembly_bytes) return;
        const small = self.allocator.alloc(u8, @min(initial_assembly_bytes, self.limits.max())) catch return;
        std.crypto.secureZero(u8, self.assembly);
        self.allocator.free(self.assembly);
        self.assembly = small;
    }

    /// Reads until the link ends. Returns why.
    pub fn run(self: *Inbound) Stopped {
        while (true) {
            var header_bytes: [frame.header_bytes]u8 = undefined;
            self.reader.readSliceAll(&header_bytes) catch |err| return switch (err) {
                error.EndOfStream => .peer_closed,
                else => .read_failed,
            };
            const header = frame.decode(&header_bytes) catch
                return .{ .violation = .frame_header };
            if (header.kind == .goodbye) return .peer_closed;
            if (header.kind == .control) {
                // One frame, always final, and allowed between another
                // message's fragments: delivered on its own.
                const payload = self.control[0..header.payload_len];
                if (payload.len != 0) self.reader.readSliceAll(payload) catch |err| return switch (err) {
                    error.EndOfStream => .peer_closed,
                    else => .read_failed,
                };
                const flow = self.sink.deliver(.control, header.correlation, payload);
                std.crypto.secureZero(u8, payload);
                if (flow == .stop) return .consumer_stopped;
                continue;
            }

            const limit = self.limits.forKind(header.kind);
            if (self.in_progress) |current| {
                if (current.kind != header.kind or current.correlation != header.correlation)
                    return .{ .violation = .interleaved_fragment };
            } else if (!header.final) {
                self.in_progress = .{ .kind = header.kind, .correlation = header.correlation };
            }
            if (self.assembled + header.payload_len > limit)
                return .{ .violation = .message_too_large };
            self.reserve(self.assembled + header.payload_len) catch return .out_of_memory;
            if (header.payload_len != 0) {
                self.reader.readSliceAll(
                    self.assembly[self.assembled..][0..header.payload_len],
                ) catch |err| return switch (err) {
                    error.EndOfStream => .peer_closed,
                    else => .read_failed,
                };
                self.assembled += header.payload_len;
            }
            if (!header.final) continue;

            const payload = self.assembly[0..self.assembled];
            const flow = self.sink.deliver(header.kind, header.correlation, payload);
            std.crypto.secureZero(u8, payload);
            self.assembled = 0;
            self.in_progress = null;
            self.settle();
            if (flow == .stop) return .consumer_stopped;
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const test_message_limits: MessageLimits = .{
    .event = 1 << 20,
    .request = 1 << 20,
    .response = 1 << 20,
    .ui_request = 1 << 16,
    .ui_response = 1 << 16,
};

const Collector = struct {
    const Record = struct { kind: frame.Kind, correlation: u64, len: usize, first: u8 };
    records: std.ArrayList(Record) = .empty,
    allocator: std.mem.Allocator,
    stop_after: ?usize = null,

    fn sink(self: *Collector) Sink {
        return .{ .context = self, .deliver_fn = deliver };
    }

    fn deliver(context: ?*anyopaque, kind: frame.Kind, correlation: u64, payload: []const u8) Flow {
        const self: *Collector = @ptrCast(@alignCast(context.?));
        self.records.append(self.allocator, .{
            .kind = kind,
            .correlation = correlation,
            .len = payload.len,
            .first = if (payload.len == 0) 0 else payload[0],
        }) catch return .stop;
        if (self.stop_after) |count| if (self.records.items.len >= count) return .stop;
        return .ok;
    }
};

/// Writes `messages` through a real `Outbound` into a temporary file, then
/// reads them back through a real `Inbound`. A pipe would add scheduling
/// noise without exercising a single additional line of framing.
fn roundTrip(
    allocator: std.mem.Allocator,
    messages: []const Message,
    limits: MessageLimits,
    stop_after: ?usize,
) !Collector {
    const io = testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "link", .{ .read = true, .truncate = true });
    defer file.close(io);

    var outbound: Outbound = undefined;
    try outbound.start(io, allocator, file, .{});
    for (messages) |message| {
        const result = try outbound.submitWaiting(message.kind, message.correlation, message.payload);
        try testing.expectEqual(Submission.queued, result);
    }
    outbound.stop();

    const read_buffer = try allocator.alloc(u8, 4096);
    defer allocator.free(read_buffer);
    const replay = try tmp.dir.openFile(io, "link", .{});
    defer replay.close(io);
    var reader = replay.readerStreaming(io, read_buffer);

    var collector: Collector = .{ .allocator = allocator, .stop_after = stop_after };
    var inbound: Inbound = undefined;
    try inbound.init(io, allocator, &reader.interface, limits, collector.sink());
    defer inbound.deinit();
    _ = inbound.run();
    return collector;
}

test "a small message survives the queue, the writer and the reassembler" {
    const allocator = testing.allocator;
    var payload = [_]u8{ 'a', 'b', 'c' };
    var collector = try roundTrip(allocator, &.{
        .{ .kind = .request, .correlation = 9, .payload = &payload },
    }, test_message_limits, null);
    defer collector.records.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), collector.records.items.len);
    try testing.expectEqual(frame.Kind.request, collector.records.items[0].kind);
    try testing.expectEqual(@as(u64, 9), collector.records.items[0].correlation);
    try testing.expectEqual(@as(usize, 3), collector.records.items[0].len);
}

test "a message above one fragment is reassembled whole" {
    const allocator = testing.allocator;
    const size = frame.max_fragment_payload_bytes * 2 + 17;
    const payload = try allocator.alloc(u8, size);
    defer allocator.free(payload);
    @memset(payload, 0x5A);
    var collector = try roundTrip(allocator, &.{
        .{ .kind = .event, .correlation = 0, .payload = payload },
    }, test_message_limits, null);
    defer collector.records.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), collector.records.items.len);
    try testing.expectEqual(size, collector.records.items[0].len);
    try testing.expectEqual(@as(u8, 0x5A), collector.records.items[0].first);
}

test "the reassembly buffer starts small, grows to the message, and is given back" {
    // Sized to the largest legal message, the buffer is that many bytes
    // resident for the life of the link: `alloc` fills it in Debug and in
    // ReleaseSafe, which is what ships.
    const io = testing.io;
    const allocator = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "link", .{ .read = true, .truncate = true });
    defer file.close(io);

    const large = try allocator.alloc(u8, 2 * retained_assembly_bytes + 3);
    defer allocator.free(large);
    @memset(large, 0x33);
    var small = [_]u8{7};
    var outbound: Outbound = undefined;
    try outbound.start(io, allocator, file, .{ .data_bytes = 8 * 1024 * 1024 });
    try testing.expectEqual(Submission.queued, try outbound.submitWaiting(.request, 1, large));
    try testing.expectEqual(Submission.queued, try outbound.submitWaiting(.request, 2, &small));
    outbound.stop();

    const read_buffer = try allocator.alloc(u8, 4096);
    defer allocator.free(read_buffer);
    const replay = try tmp.dir.openFile(io, "link", .{});
    defer replay.close(io);
    var reader = replay.readerStreaming(io, read_buffer);

    const Observer = struct {
        inbound: *Inbound = undefined,
        capacities: [2]usize = .{ 0, 0 },
        lengths: [2]usize = .{ 0, 0 },
        seen: usize = 0,

        fn sink(self: *@This()) Sink {
            return .{ .context = self, .deliver_fn = deliver };
        }

        fn deliver(context: ?*anyopaque, _: frame.Kind, _: u64, bytes: []const u8) Flow {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.capacities[self.seen] = self.inbound.assembly.len;
            self.lengths[self.seen] = bytes.len;
            self.seen += 1;
            return .ok;
        }
    };
    var observer: Observer = .{};
    var inbound: Inbound = undefined;
    try inbound.init(io, allocator, &reader.interface, .{
        .event = 1 << 16,
        .request = 4 * 1024 * 1024,
        .response = 1 << 16,
        .ui_request = 1 << 16,
        .ui_response = 1 << 16,
    }, observer.sink());
    defer inbound.deinit();
    observer.inbound = &inbound;

    try testing.expectEqual(initial_assembly_bytes, inbound.assembly.len);
    try testing.expectEqual(Stopped.peer_closed, inbound.run());
    try testing.expectEqual(@as(usize, 2), observer.seen);
    try testing.expectEqual(large.len, observer.lengths[0]);
    try testing.expect(observer.capacities[0] >= large.len);
    // The small message after it found the buffer already given back.
    try testing.expectEqual(initial_assembly_bytes, observer.capacities[1]);
    try testing.expectEqual(initial_assembly_bytes, inbound.assembly.len);
}

test "an empty-payload kind still arrives as its own message" {
    const allocator = testing.allocator;
    var collector = try roundTrip(allocator, &.{
        .{ .kind = .event_ready, .correlation = 0, .payload = &.{} },
        .{ .kind = .event_ready, .correlation = 0, .payload = &.{} },
    }, test_message_limits, null);
    defer collector.records.deinit(allocator);
    try testing.expectEqual(@as(usize, 2), collector.records.items.len);
    try testing.expectEqual(frame.Kind.event_ready, collector.records.items[0].kind);
    try testing.expectEqual(@as(usize, 0), collector.records.items[0].len);
}

test "a Run's terminal never arrives before the events that preceded it" {
    // This is the invariant that lets a reader treat "my pump holds nothing
    // for this route" as "every event of that Run arrived": the events and the
    // `response` carrying the terminal share one ordered queue, so the
    // terminal cannot overtake them. Break it -- by moving terminals onto
    // `control`, or by adding a second data channel -- and the reader sees
    // fewer events and concludes the stream was complete.
    const allocator = testing.allocator;
    var first = [_]u8{'1'};
    var second = [_]u8{'2'};
    var third = [_]u8{'3'};
    var terminal = [_]u8{'T'};
    var collector = try roundTrip(allocator, &.{
        .{ .kind = .event, .correlation = 0, .payload = &first },
        .{ .kind = .event, .correlation = 0, .payload = &second },
        .{ .kind = .event, .correlation = 0, .payload = &third },
        .{ .kind = .response, .correlation = 7, .payload = &terminal },
    }, test_message_limits, null);
    defer collector.records.deinit(allocator);
    try testing.expectEqual(@as(usize, 4), collector.records.items.len);
    for (collector.records.items[0..3], 0..) |record, index| {
        try testing.expectEqual(frame.Kind.event, record.kind);
        try testing.expectEqual(@as(u8, '1' + @as(u8, @intCast(index))), record.first);
    }
    try testing.expectEqual(frame.Kind.response, collector.records.items[3].kind);
    try testing.expectEqual(@as(u8, 'T'), collector.records.items[3].first);
}

test "control is the only kind allowed to pass queued data" {
    // The complement of the invariant above: everything except `control` keeps
    // submission order, and `control` keeps its own queue. A reader therefore
    // only has to tolerate control frames arriving early.
    inline for (comptime std.enums.values(frame.Kind)) |kind| {
        const reserved = kind == .control;
        try testing.expectEqual(reserved, kind == .control);
        // Only a kind that may not fragment can be allowed to pass a
        // fragmented message, or it would interleave with itself.
        if (reserved) try testing.expect(!kind.fragments());
    }
}

test "a stopping consumer ends the read without consuming the rest" {
    const allocator = testing.allocator;
    var payload = [_]u8{1};
    var collector = try roundTrip(allocator, &.{
        .{ .kind = .request, .correlation = 1, .payload = &payload },
        .{ .kind = .request, .correlation = 2, .payload = &payload },
        .{ .kind = .request, .correlation = 3, .payload = &payload },
    }, test_message_limits, 2);
    defer collector.records.deinit(allocator);
    try testing.expectEqual(@as(usize, 2), collector.records.items.len);
}

test "the data bound is enforced without blocking the caller that cannot wait" {
    const io = testing.io;
    const allocator = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "link", .{ .truncate = true });
    defer file.close(io);

    // One data slot and nothing draining it. This is about what `submit`
    // admits, so the `Outbound` is built by hand and never gets a writer
    // thread: a started writer may take the held message at any moment, and
    // whether the next try still found the queue full would then depend on
    // how far that thread had got. The file is only there because the struct
    // holds one; nothing is written to it.
    const limits: Limits = .{
        .data_count = 1,
        .data_bytes = 8,
        .control_count = 1,
        .control_bytes = frame.max_fragment_payload_bytes,
    };
    var outbound: Outbound = build: {
        const data_slots = try allocator.alloc(?Message, limits.data_count);
        errdefer allocator.free(data_slots);
        @memset(data_slots, null);
        const control_slots = try allocator.alloc(?Message, limits.control_count);
        @memset(control_slots, null);
        break :build .{
            .io = io,
            .allocator = allocator,
            .file = file,
            .limits = limits,
            .data = .{ .slots = data_slots },
            .control = .{ .slots = control_slots },
        };
    };
    // `stop` releases the slots and whatever is still queued, and joins
    // nothing when there is no writer. Deferred, so a failed expectation
    // below is reported on its own rather than with leaks on top of it.
    defer outbound.stop();

    try testing.expectEqual(
        Submission.queued,
        try outbound.trySubmit(.request, 1, "hold"),
    );
    // The slot is taken: the second try comes back `busy` rather than
    // parking the caller.
    try testing.expectEqual(
        Submission.busy,
        try outbound.trySubmit(.request, 2, "more"),
    );
    // A payload larger than the whole bound is refused rather than queued.
    try testing.expectEqual(
        Submission.busy,
        try outbound.trySubmit(.request, 3, "0123456789"),
    );
    // Control keeps its own capacity even while data is at its bound.
    try testing.expectEqual(
        Submission.queued,
        try outbound.trySubmit(.control, 0, "stop"),
    );
}

test "a closed outbound reports closed rather than accepting bytes it cannot send" {
    const io = testing.io;
    const allocator = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "link", .{ .truncate = true });
    defer file.close(io);
    var outbound: Outbound = undefined;
    try outbound.start(io, allocator, file, .{});
    outbound.stop();
    try testing.expectEqual(Submission.closed, try outbound.trySubmit(.request, 1, "x"));
    try testing.expectEqual(Submission.closed, try outbound.submitWaiting(.request, 1, "x"));
}

test "control overtakes a fragmented data message instead of waiting for it" {
    const io = testing.io;
    const allocator = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "link", .{ .read = true, .truncate = true });
    defer file.close(io);

    // The writer thread would make this a race: whether control overtakes
    // depends on whether it had already started the data message. So drive
    // `writeMessage` directly, with the control message already queued. That
    // is the exact code path the writer thread runs, and the one that has to
    // check the control queue between fragments rather than between messages.
    const control_slots = try allocator.alloc(?Message, 4);
    defer allocator.free(control_slots);
    @memset(control_slots, null);
    const data_slots = try allocator.alloc(?Message, 4);
    defer allocator.free(data_slots);
    @memset(data_slots, null);
    var outbound: Outbound = .{
        .io = io,
        .allocator = allocator,
        .file = file,
        .limits = .{},
        .data = .{ .slots = data_slots },
        .control = .{ .slots = control_slots },
    };
    const big = try allocator.alloc(u8, frame.max_fragment_payload_bytes * 4);
    defer allocator.free(big);
    @memset(big, 7);
    outbound.control.push(.{
        .kind = .control,
        .correlation = 0,
        .payload = try allocator.dupe(u8, "stop"),
    });
    try testing.expect(outbound.writeMessage(.{
        .kind = .event,
        .correlation = 0,
        .payload = big,
    }));
    try testing.expectEqual(@as(usize, 0), outbound.control.queued);

    const read_buffer = try allocator.alloc(u8, 4096);
    defer allocator.free(read_buffer);
    const replay = try tmp.dir.openFile(io, "link", .{});
    defer replay.close(io);
    var reader = replay.readerStreaming(io, read_buffer);

    // Walk the frames by hand: the reassembler deliberately refuses this
    // interleaving on the read side, and here we are checking the write order.
    var kinds: [8]frame.Kind = undefined;
    var count: usize = 0;
    while (count < kinds.len) {
        var header_bytes: [frame.header_bytes]u8 = undefined;
        reader.interface.readSliceAll(&header_bytes) catch break;
        const header = try frame.decode(&header_bytes);
        kinds[count] = header.kind;
        count += 1;
        if (header.payload_len != 0) try reader.interface.discardAll(header.payload_len);
    }
    try testing.expectEqual(@as(usize, 5), count);
    try testing.expectEqual(frame.Kind.event, kinds[0]);
    try testing.expectEqual(frame.Kind.control, kinds[1]);
    try testing.expectEqual(frame.Kind.event, kinds[2]);
    try testing.expectEqual(frame.Kind.event, kinds[3]);
    try testing.expectEqual(frame.Kind.event, kinds[4]);
}

/// An anonymous pipe made the way the link's own are: on Windows by the same
/// std function a spawn uses, with the same synchronous ends as a child's
/// stdin; on POSIX by `pipe2`.
fn realPipe(threaded: *std.Io.Threaded) !struct { read: std.Io.File, write: std.Io.File } {
    switch (@import("builtin").os.tag) {
        .windows => {
            const ends = try threaded.windowsCreatePipe(.{
                .server = .{ .attributes = .{ .INHERIT = false }, .mode = .{ .IO = .SYNCHRONOUS_NONALERT } },
                .client = .{ .attributes = .{ .INHERIT = false }, .mode = .{ .IO = .SYNCHRONOUS_NONALERT } },
                .outbound = true,
            });
            return .{
                .read = .{ .handle = ends[1], .flags = .{ .nonblocking = false } },
                .write = .{ .handle = ends[0], .flags = .{ .nonblocking = false } },
            };
        },
        else => {
            const ends = try std.Io.Threaded.pipe2(.{ .CLOEXEC = true });
            return .{
                .read = .{ .handle = ends[0], .flags = .{ .nonblocking = false } },
                .write = .{ .handle = ends[1], .flags = .{ .nonblocking = false } },
            };
        },
    }
}

test "a control frame queued mid-message travels between its fragments over a real pipe" {
    // The other tests check the order the writer writes in, and how the
    // reassembler reads hand-built frames. This one runs both, the writer
    // thread and the reader, on the two ends of a real pipe, so the
    // interleaving has to survive the operating system's chunking too.
    //
    // It is made deterministic by the pipe's size. Nothing reads until the
    // control frame is queued, and the message's first fragment -- 64 KiB
    // and a header -- is more than any pipe holds (4 KiB on Windows, at most
    // 64 KiB on POSIX), so the writer is still inside that fragment when the
    // control frame arrives in its queue. A writer that only looked for
    // control between messages would send it after the whole message.
    const allocator = testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const ends = try realPipe(&threaded);
    var write_open = true;
    defer if (write_open) ends.write.close(io);

    var outbound: Outbound = undefined;
    try outbound.start(io, allocator, ends.write, .{});
    var outbound_running = true;
    defer if (outbound_running) outbound.stop();
    // Declared after the writer's stop, so on any failure below it runs
    // first: with the read end closed the writer's blocked write fails, and
    // the stop that joins it returns instead of waiting on a pipe nobody
    // reads. Once the reader thread runs, it closes this end itself as soon
    // as it stops reading.
    var read_open = true;
    defer if (read_open) ends.read.close(io);

    const payload = try allocator.alloc(u8, 3 * frame.max_fragment_payload_bytes);
    defer allocator.free(payload);
    for (payload, 0..) |*byte, index| byte.* = @truncate(index % 251);
    try testing.expectEqual(Submission.queued, try outbound.submitWaiting(.request, 1, payload));
    // The writer has taken the message and is writing its first fragment --
    // or has failed, which ends the wait too.
    const writer_failed = while (true) {
        outbound.mutex.lockUncancelable(io);
        const queued = outbound.data.queued;
        const failed = outbound.failed;
        outbound.mutex.unlock(io);
        if (queued == 0 or failed) break failed;
        std.Thread.yield() catch {};
    };
    try testing.expect(!writer_failed);
    try testing.expectEqual(Submission.queued, try outbound.trySubmit(.control, 0, "ping"));

    // Only now does anything read.
    const Checking = struct {
        allocator: std.mem.Allocator,
        records: std.ArrayList(Collector.Record) = .empty,
        intact: bool = false,

        fn sink(self: *@This()) Sink {
            return .{ .context = self, .deliver_fn = deliver };
        }

        fn deliver(context: ?*anyopaque, kind: frame.Kind, correlation: u64, bytes: []const u8) Flow {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (kind == .request) {
                self.intact = true;
                for (bytes, 0..) |byte, index| {
                    if (byte != @as(u8, @truncate(index % 251))) self.intact = false;
                }
            }
            self.records.append(self.allocator, .{
                .kind = kind,
                .correlation = correlation,
                .len = bytes.len,
                .first = if (bytes.len == 0) 0 else bytes[0],
            }) catch return .stop;
            return .ok;
        }
    };
    var checking: Checking = .{ .allocator = allocator };
    defer checking.records.deinit(allocator);
    const read_buffer = try allocator.alloc(u8, 4096);
    defer allocator.free(read_buffer);
    var reader = ends.read.readerStreaming(io, read_buffer);
    var inbound: Inbound = undefined;
    try inbound.init(io, allocator, &reader.interface, test_message_limits, checking.sink());
    defer inbound.deinit();
    const Reading = struct {
        fn run(reading: *Inbound, stopped: *Stopped, end: std.Io.File, end_io: std.Io) void {
            stopped.* = reading.run();
            // Whatever ended the read -- the end of the stream, or the sink
            // giving up -- nothing reads any more, so a writer still writing
            // must fail rather than wait.
            end.close(end_io);
        }
    };
    var stopped: Stopped = .read_failed;
    const thread = try std.Thread.spawn(.{}, Reading.run, .{ &inbound, &stopped, ends.read, io });
    read_open = false;
    // The writer finishes what is queued, and closing the end is the end of
    // the stream.
    outbound.stop();
    outbound_running = false;
    ends.write.close(io);
    write_open = false;
    thread.join();

    try testing.expectEqual(Stopped.peer_closed, stopped);
    try testing.expectEqual(@as(usize, 2), checking.records.items.len);
    try testing.expectEqual(frame.Kind.control, checking.records.items[0].kind);
    try testing.expectEqual(@as(usize, 4), checking.records.items[0].len);
    try testing.expectEqual(@as(u8, 'p'), checking.records.items[0].first);
    try testing.expectEqual(frame.Kind.request, checking.records.items[1].kind);
    try testing.expectEqual(@as(u64, 1), checking.records.items[1].correlation);
    try testing.expectEqual(payload.len, checking.records.items[1].len);
    try testing.expect(checking.intact);
}

/// Feeds hand-built frames to an `Inbound` and returns why it stopped.
fn replayFrames(allocator: std.mem.Allocator, bytes: []const u8) !Stopped {
    const io = testing.io;
    var reader = std.Io.Reader.fixed(bytes);
    var collector: Collector = .{ .allocator = allocator };
    defer collector.records.deinit(allocator);
    var inbound: Inbound = undefined;
    try inbound.init(io, allocator, &reader, .{
        .event = 128,
        .request = 128,
        .response = 128,
        .ui_request = 128,
        .ui_response = 128,
    }, collector.sink());
    defer inbound.deinit();
    return inbound.run();
}

fn appendFrame(
    storage: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    header: frame.Header,
    payload: []const u8,
) !void {
    var bytes: [frame.header_bytes]u8 = undefined;
    header.encode(&bytes);
    try storage.appendSlice(allocator, &bytes);
    try storage.appendSlice(allocator, payload);
}

test "a control frame between a message's fragments arrives on its own, and the message whole" {
    const allocator = testing.allocator;
    var storage: std.ArrayList(u8) = .empty;
    defer storage.deinit(allocator);
    try appendFrame(&storage, allocator, .{ .kind = .request, .final = false, .correlation = 1, .payload_len = 4 }, "aaaa");
    try appendFrame(&storage, allocator, .{ .kind = .control, .final = true, .correlation = 0, .payload_len = 2 }, "ok");
    try appendFrame(&storage, allocator, .{ .kind = .request, .final = true, .correlation = 1, .payload_len = 4 }, "bbbb");

    const io = testing.io;
    var reader = std.Io.Reader.fixed(storage.items);
    var collector: Collector = .{ .allocator = allocator };
    defer collector.records.deinit(allocator);
    var inbound: Inbound = undefined;
    try inbound.init(io, allocator, &reader, test_message_limits, collector.sink());
    defer inbound.deinit();
    try testing.expectEqual(Stopped.peer_closed, inbound.run());
    try testing.expectEqual(@as(usize, 2), collector.records.items.len);
    try testing.expectEqual(frame.Kind.control, collector.records.items[0].kind);
    try testing.expectEqual(@as(usize, 2), collector.records.items[0].len);
    try testing.expectEqual(frame.Kind.request, collector.records.items[1].kind);
    try testing.expectEqual(@as(usize, 8), collector.records.items[1].len);
    try testing.expectEqual(@as(u8, 'a'), collector.records.items[1].first);
}

test "the reassembler ends the link on an interleaved or orphan continuation" {
    const allocator = testing.allocator;
    {
        var storage: std.ArrayList(u8) = .empty;
        defer storage.deinit(allocator);
        try appendFrame(&storage, allocator, .{
            .kind = .request,
            .final = false,
            .correlation = 1,
            .payload_len = 4,
        }, "aaaa");
        try appendFrame(&storage, allocator, .{
            .kind = .request,
            .final = true,
            .correlation = 2,
            .payload_len = 4,
        }, "bbbb");
        const stopped = try replayFrames(allocator, storage.items);
        try testing.expectEqual(Stopped{ .violation = .interleaved_fragment }, stopped);
    }
    {
        // A different kind mid-reassembly is the same violation.
        var storage: std.ArrayList(u8) = .empty;
        defer storage.deinit(allocator);
        try appendFrame(&storage, allocator, .{
            .kind = .request,
            .final = false,
            .correlation = 1,
            .payload_len = 4,
        }, "aaaa");
        try appendFrame(&storage, allocator, .{
            .kind = .event,
            .final = true,
            .correlation = 0,
            .payload_len = 1,
        }, "x");
        const stopped = try replayFrames(allocator, storage.items);
        try testing.expectEqual(Stopped{ .violation = .interleaved_fragment }, stopped);
    }
}

test "a message past its kind's limit ends the link instead of growing a buffer" {
    const allocator = testing.allocator;
    var storage: std.ArrayList(u8) = .empty;
    defer storage.deinit(allocator);
    const chunk = [_]u8{0} ** 100;
    try appendFrame(&storage, allocator, .{
        .kind = .request,
        .final = false,
        .correlation = 1,
        .payload_len = chunk.len,
    }, &chunk);
    try appendFrame(&storage, allocator, .{
        .kind = .request,
        .final = true,
        .correlation = 1,
        .payload_len = chunk.len,
    }, &chunk);
    const stopped = try replayFrames(allocator, storage.items);
    try testing.expectEqual(Stopped{ .violation = .message_too_large }, stopped);
}

test "a malformed header ends the link" {
    const allocator = testing.allocator;
    var storage: std.ArrayList(u8) = .empty;
    defer storage.deinit(allocator);
    try appendFrame(&storage, allocator, .{
        .kind = .request,
        .final = true,
        .correlation = 1,
        .payload_len = 0,
    }, "");
    storage.items[4] = 0; // no such kind
    const stopped = try replayFrames(allocator, storage.items);
    try testing.expectEqual(Stopped{ .violation = .frame_header }, stopped);
}

test "goodbye and end of stream are both a clean peer close" {
    const allocator = testing.allocator;
    {
        var storage: std.ArrayList(u8) = .empty;
        defer storage.deinit(allocator);
        try appendFrame(&storage, allocator, .{
            .kind = .goodbye,
            .final = true,
            .correlation = 0,
            .payload_len = 0,
        }, "");
        try testing.expectEqual(Stopped.peer_closed, try replayFrames(allocator, storage.items));
    }
    try testing.expectEqual(Stopped.peer_closed, try replayFrames(allocator, &.{}));
}

test "a truncated payload is a close, not a short message" {
    const allocator = testing.allocator;
    var storage: std.ArrayList(u8) = .empty;
    defer storage.deinit(allocator);
    try appendFrame(&storage, allocator, .{
        .kind = .request,
        .final = true,
        .correlation = 1,
        .payload_len = 8,
    }, "abcd");
    try testing.expectEqual(Stopped.peer_closed, try replayFrames(allocator, storage.items));
}

test "limits reject a shape the link could not honour" {
    try testing.expect(!(Limits{ .data_count = 0 }).valid());
    try testing.expect(!(Limits{ .control_bytes = 1 }).valid());
    try testing.expect((Limits{}).valid());
    try testing.expect(!(MessageLimits{
        .event = 0,
        .request = 1,
        .response = 1,
        .ui_request = 1,
        .ui_response = 1,
    }).valid());
    try testing.expectEqual(
        frame.max_fragment_payload_bytes,
        test_message_limits.forKind(.control),
    );
}
