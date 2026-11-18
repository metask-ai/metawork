//! What one call owns: the backing object of a capability it builds, and the
//! slot it promised before making a call that cannot be taken back.
//!
//! A capability is a context pointer and a function pointer, and some of the
//! contexts the execution half builds stand for a fact about one call: a
//! destination, a reader. If anything keeps the pointer after the call
//! returns, it points at memory this half has reused -- a cross-process
//! use-after-free that reads as plausible data, which is the failure class
//! this whole change exists to remove rather than relocate.
//!
//! Nothing can stop a callee from storing a pointer it was handed. What can
//! be arranged is that storing one is useless, and that is what this file
//! arranges.
//!
//! It is deliberately *not* for every capability. A Run-scoped one -- the
//! tools `prepare_run_with_tools` hands over, which the Session keeps and
//! uses while the Run executes -- would be destroyed by retiring it when
//! that call returns: the Session would hold a capability that answers only
//! its failure value, and the tool would be permanently unavailable with
//! nothing crashing. Those live in `run_tools.zig`; `adapters.Disposition`
//! records which kind each parameter is.

const std = @import("std");
const handle_table = @import("handle_table.zig");
const shapes = @import("shapes.zig");
const checkpoint = @import("agent_checkpoint");

/// A capability's backing object, valid for exactly one call.
///
/// `borrow` is the only way in, so a pointer kept past `retire` is a refusal
/// rather than a read. The marker is checked rather than the memory being
/// merely overwritten: a zeroed struct can still look like a valid one, and
/// "looks valid" is the thing being prevented.
pub fn Frame(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Deliberately not a bool. A freed-and-reused frame is far more
        /// likely to hold a plausible bool than this exact word.
        const live_marker: u64 = 0x4c49_5645_4652_414d;
        const retired_marker: u64 = 0xdead_f00d_dead_f00d;

        marker: u64 = live_marker,
        value: T,

        pub fn init(value: T) Self {
            return .{ .value = value };
        }

        /// The context pointer a capability carries. Opaque on purpose: the
        /// only thing the far side can do with it is hand it back.
        pub fn context(self: *Self) ?*anyopaque {
            return @ptrCast(self);
        }

        /// The backing object, or `null` once the call it belonged to has
        /// returned.
        pub fn borrow(self: *Self) ?*T {
            if (self.marker != live_marker) return null;
            return &self.value;
        }

        /// Recovers the frame from a capability's context, without yet
        /// claiming it is live.
        pub fn fromContext(value: ?*anyopaque) ?*Self {
            const pointer = value orelse return null;
            return @ptrCast(@alignCast(pointer));
        }

        /// Called by the dispatcher when the call returns, whatever the
        /// outcome. After this the frame answers nothing.
        pub fn retire(self: *Self) void {
            self.marker = retired_marker;
            self.value = undefined;
        }

        pub fn live(self: *const Self) bool {
            return self.marker == live_marker;
        }
    };
}

/// Runs one call over a per-call capability and retires the frame on the way
/// out, whatever happened.
///
/// A `defer`, not a line at the end of the successful path. That distinction
/// is the whole mechanism: an early return that skipped the retire would
/// leave the frame live, a pointer the far side kept would keep working, and
/// every test would still pass -- the mechanism gone with no symptom. Failure
/// paths are the common case here, because a dispatcher refuses malformed
/// arguments, unknown handles and capacity before it ever reaches the call.
///
/// `body` receives the frame rather than the capability, because which
/// capability to build from it is the caller's business; what this function
/// owns is the lifetime.
pub fn overFrame(
    comptime T: type,
    comptime Result: type,
    frame: *Frame(T),
    context: anytype,
    comptime body: fn (@TypeOf(context), *Frame(T)) Result,
) Result {
    defer frame.retire();
    return body(context, frame);
}

/// Performs a call whose success cannot be undone, over a slot reserved
/// before it runs.
///
/// The reservation is a parameter of `body`, so "begin it, then find it a
/// name" is not an order to remember avoiding: it cannot be written. That
/// matters because some of these calls have no undo at all. A begun Run is a
/// linear value whose own contract says it must execute and deinitialize
/// exactly once, and `RunPort.deinit` asserts it executed -- so a Run begun
/// and then not namable is neither deliverable nor droppable, and the
/// assertion would fire later, somewhere unrelated.
///
/// The promise is given back on every path out that did not fill it, on a
/// `defer`, for the same reason the frame is retired on one: the failing
/// paths are the common ones, and an early return that skipped it would hold
/// a slot for a caller that can never fill it -- a leak that shows up only as
/// capacity refusals much later.
///
/// Whether it was filled is asked of the table rather than tracked here, so
/// there is one answer to that question.
pub fn overReservation(
    comptime T: type,
    comptime Result: type,
    table: *handle_table.Table(T),
    context: anytype,
    comptime body: fn (@TypeOf(context), handle_table.Table(T).Reservation) Result,
) handle_table.InsertError!Result {
    const promised = try table.reserve();
    defer if (table.stillReserved(promised)) {
        std.debug.assert(table.releaseReservation(promised));
    };
    return body(context, promised);
}

const Promised = struct {
    const Table = handle_table.Table(u32);

    fn fills(table: *Table, promise: Table.Reservation) anyerror!handle_table.Id {
        // Stands in for the irreversible call succeeding: the thing now
        // exists, and the name it was promised is the name it gets.
        return table.fill(promise, &held) orelse error.Unexpected;
    }

    fn refuses(_: *Table, _: Table.Reservation) anyerror!handle_table.Id {
        // The irreversible call refused, so nothing exists to name and the
        // early return must not keep the slot.
        return error.Unexpected;
    }

    var held: u32 = 42;
};

test "a promise is given back when the call it was made for does not happen" {
    var table = try Promised.Table.init(testing.allocator, 1);
    defer table.deinit();

    // One slot, so a promise that was not given back would make the next
    // attempt fail -- which is exactly how this leak presents in production.
    // Two unwraps, and they are two different failures: the outer one is the
    // table refusing to promise, the inner one is the call refusing to
    // happen. Collapsing them would name the wrong cause.
    try testing.expectError(
        error.Unexpected,
        try overReservation(u32, anyerror!handle_table.Id, &table, &table, Promised.refuses),
    );
    try testing.expectEqual(@as(usize, 0), table.liveCount());

    const id = try (try overReservation(
        u32,
        anyerror!handle_table.Id,
        &table,
        &table,
        Promised.fills,
    ));
    try testing.expectEqual(@as(u32, 42), table.resolve(id).?.*);
    try testing.expectEqual(@as(usize, 1), table.liveCount());
    _ = table.take(id);
}

test "capacity is refused before the call that cannot be undone, not after" {
    var table = try Promised.Table.init(testing.allocator, 1);
    defer table.deinit();
    const held = try table.reserve();

    // The table is full, so `overReservation` refuses without ever reaching
    // `body`. That is the whole reordering: the Run is not begun, so there is
    // nothing undeliverable to hold.
    try testing.expectError(
        error.HandleCapacity,
        overReservation(u32, anyerror!handle_table.Id, &table, &table, Promised.fills),
    );
    try testing.expect(table.stillReserved(held));
    try testing.expect(table.releaseReservation(held));
}

/// A checkpoint destination the execution half writes to, as a capability
/// built over one call's frame.
///
/// The sink is the first of the four and it is the shape the rest follow:
/// nothing about the destination crosses except the descriptor, the bytes
/// never leave this half, and the writer lives in a frame the dispatcher
/// retires.
pub const CheckpointWriter = struct {
    destination: envelope_destination,
    written: u64 = 0,

    const envelope_destination = @import("shapes.zig").CheckpointDestination;
    pub const Backing = Frame(CheckpointWriter);

    /// `ok` while the write is admitted, and the contract's own refusal
    /// otherwise. A retained frame lands on `contract_failed`, because a
    /// write after the call is exactly a contract failure and the vocabulary
    /// already says so.
    pub fn sink(backing: *Backing) checkpoint.Sink {
        return .{ .context = backing.context(), .write_fn = write };
    }

    fn write(context: ?*anyopaque, bytes: []const u8) checkpoint.SinkWriteResult {
        const backing = Backing.fromContext(context) orelse return .contract_failed;
        const writer = backing.borrow() orelse return .contract_failed;
        if (bytes.len == 0) return .contract_failed;
        const hard = writer.destination.hard_bytes;
        if (writer.written > hard - @min(hard, bytes.len)) return .contract_failed;
        writer.written += bytes.len;
        return .ok;
    }
};

const testing = std.testing;

test "a frame answers while its call is running and refuses afterwards" {
    var backing = CheckpointWriter.Backing.init(.{
        .destination = .{ .task_id = 7, .generation = 3, .hard_bytes = 64 },
    });
    const sink = CheckpointWriter.sink(&backing);

    try testing.expectEqual(checkpoint.SinkWriteResult.ok, sink.write_fn(sink.context, "hello"));
    try testing.expectEqual(@as(u64, 5), backing.borrow().?.written);

    // The call returns. Everything the far side may still be holding is the
    // same pointer it had a moment ago.
    backing.retire();
    try testing.expect(!backing.live());
    try testing.expect(backing.borrow() == null);

    // And this is the property: a write through the retained capability is
    // refused, not performed against whatever now occupies that memory.
    try testing.expectEqual(
        checkpoint.SinkWriteResult.contract_failed,
        sink.write_fn(sink.context, "after"),
    );
}

test "a retired frame is not merely zeroed, because zero can look valid" {
    var backing = CheckpointWriter.Backing.init(.{
        .destination = .{ .task_id = 1, .generation = 1, .hard_bytes = 8 },
    });
    try testing.expect(backing.live());
    backing.retire();

    // A frame whose marker was cleared to zero rather than set to the retired
    // word would still have to be refused, and is.
    backing.marker = 0;
    try testing.expect(backing.borrow() == null);

    // Only the exact live word admits a borrow, so a reused allocation has to
    // reproduce it to be mistaken for a live frame.
    backing.marker = CheckpointWriter.Backing.live_marker;
    try testing.expect(backing.borrow() != null);
}

test "a frame is retired on the failing path too, which is the path that matters" {
    const Work = struct {
        fn succeed(_: void, frame: *CheckpointWriter.Backing) anyerror!u64 {
            const sink = CheckpointWriter.sink(frame);
            if (sink.write_fn(sink.context, "ok") != .ok) return error.Unexpected;
            return frame.borrow().?.written;
        }

        fn fail(_: void, frame: *CheckpointWriter.Backing) anyerror!u64 {
            const sink = CheckpointWriter.sink(frame);
            _ = sink.write_fn(sink.context, "partial");
            // An early return, which is what a dispatcher does on a bad
            // argument or an unknown handle.
            return error.Unexpected;
        }
    };

    const destination: @import("shapes.zig").CheckpointDestination =
        .{ .task_id = 4, .generation = 2, .hard_bytes = 64 };

    var good = CheckpointWriter.Backing.init(.{ .destination = destination });
    const written = try overFrame(CheckpointWriter, anyerror!u64, &good, {}, Work.succeed);
    try testing.expectEqual(@as(u64, 2), written);
    try testing.expect(!good.live());

    var bad = CheckpointWriter.Backing.init(.{ .destination = destination });
    const sink = CheckpointWriter.sink(&bad);
    try testing.expectError(
        error.Unexpected,
        overFrame(CheckpointWriter, anyerror!u64, &bad, {}, Work.fail),
    );
    // The point: the call left through an error and the frame is still
    // retired, so the capability the far side may have kept is dead either
    // way.
    try testing.expect(!bad.live());
    try testing.expectEqual(
        checkpoint.SinkWriteResult.contract_failed,
        sink.write_fn(sink.context, "after"),
    );
}

test "the sink keeps the bound the descriptor carried" {
    var backing = CheckpointWriter.Backing.init(.{
        .destination = .{ .task_id = 2, .generation = 9, .hard_bytes = 4 },
    });
    const sink = CheckpointWriter.sink(&backing);
    try testing.expectEqual(checkpoint.SinkWriteResult.ok, sink.write_fn(sink.context, "abcd"));
    // One byte past `hard_bytes` is a contract failure, not a truncation: the
    // bound crossed as a number and is enforced where the bytes are.
    try testing.expectEqual(
        checkpoint.SinkWriteResult.contract_failed,
        sink.write_fn(sink.context, "e"),
    );
    // An empty write is a contract failure too, as it is in process.
    try testing.expectEqual(
        checkpoint.SinkWriteResult.contract_failed,
        sink.write_fn(sink.context, ""),
    );
    backing.retire();
}
