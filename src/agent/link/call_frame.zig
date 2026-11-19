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
const checkpoint_restore = @import("agent_checkpoint_restore");

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
    var table = try Promised.Table.init(testing.io, testing.allocator, 1);
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
    var table = try Promised.Table.init(testing.io, testing.allocator, 1);
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

const testing = std.testing;

test "a frame answers while its call is running and refuses afterwards" {
    var sink_state: Recorder = .{ .buffer = &sink_scratch };
    var backing = ExportSink.Backing.init(.{
        .inner = sink_state.sink(),
        .destination = .{ .task_id = 7, .hard_bytes = 64 },
    });
    const sink = ExportSink.sink(&backing);

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
    var sink_state: Recorder = .{ .buffer = &sink_scratch };
    var backing = ExportSink.Backing.init(.{
        .inner = sink_state.sink(),
        .destination = .{ .task_id = 1, .hard_bytes = 8 },
    });
    try testing.expect(backing.live());
    backing.retire();

    // A frame whose marker was cleared to zero rather than set to the retired
    // word would still have to be refused, and is.
    backing.marker = 0;
    try testing.expect(backing.borrow() == null);

    // Only the exact live word admits a borrow, so a reused allocation has to
    // reproduce it to be mistaken for a live frame.
    backing.marker = ExportSink.Backing.live_marker;
    try testing.expect(backing.borrow() != null);
}

test "a frame is retired on the failing path too, which is the path that matters" {
    const Work = struct {
        fn succeed(_: void, frame: *ExportSink.Backing) anyerror!u64 {
            const sink = ExportSink.sink(frame);
            if (sink.write_fn(sink.context, "ok") != .ok) return error.Unexpected;
            return frame.borrow().?.written;
        }

        fn fail(_: void, frame: *ExportSink.Backing) anyerror!u64 {
            const sink = ExportSink.sink(frame);
            _ = sink.write_fn(sink.context, "partial");
            // An early return, which is what a dispatcher does on a bad
            // argument or an unknown handle.
            return error.Unexpected;
        }
    };

    var sink_state: Recorder = .{ .buffer = &sink_scratch };
    const destination: BlobDestination = .{ .task_id = 4, .hard_bytes = 64 };

    var good = ExportSink.Backing.init(.{ .inner = sink_state.sink(), .destination = destination });
    const written = try overFrame(ExportSink, anyerror!u64, &good, {}, Work.succeed);
    try testing.expectEqual(@as(u64, 2), written);
    try testing.expect(!good.live());

    var bad = ExportSink.Backing.init(.{ .inner = sink_state.sink(), .destination = destination });
    const sink = ExportSink.sink(&bad);
    try testing.expectError(
        error.Unexpected,
        overFrame(ExportSink, anyerror!u64, &bad, {}, Work.fail),
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

// ---------------------------------------------------------------------------
// Checkpoint blob bytes
// ---------------------------------------------------------------------------

/// How this half carries checkpoint blob bytes.
///
/// `architecture.md` section 5 settles which half: the blob and the record
/// pointing at it are separate carriers, the record's commit authority is
/// Product's, and the execution half performing an export does not thereby
/// gain persistence authority. So the bytes are this half's to write and
/// read, the record stays the caller's to commit, and what crosses is the
/// descriptor and the outcome.
///
/// Supplied by the composition root, because the link holds no store. It
/// hands out the shapes the port already speaks -- a `checkpoint.Sink` and a
/// `checkpoint_restore.Source` -- so nothing here reshapes bytes, and takes
/// them back when the call that used one has returned.
/// Which blob to open, and the bound on it.
///
/// Not a wire shape, and it used to be one. Every field of it is either on
/// the Session the call was made on or in the call's own `limits`, so the
/// descriptor is composed here rather than sent -- and the field that *was*
/// sent, `generation`, had to come out: it is assigned by the export, so a
/// caller filling it in was asserting something it could not know.
///
/// `shapes.CheckpointSourceDescriptor` is still a wire shape, and the
/// asymmetry is real: a restore names a blob that already exists, by facts
/// only the caller has (which generation, which digest, how many bytes),
/// while an export names one that does not exist yet.
pub const BlobDestination = struct {
    task_id: u64,
    hard_bytes: u64,
};

/// What the export produced, handed to the store so it can finish the blob.
///
/// Both byte counts are here on purpose. `exported.total_bytes` is what the
/// Session says it wrote; `observed_bytes` is what actually passed through
/// this call's wrapper. The store is the only party that also knows what
/// reached its own storage, so it is the one that can tell all three apart --
/// and a record pointing at bytes nobody wrote is the failure this
/// comparison exists to stop. Product's `Writer.commit` makes the same
/// comparison on its side, for the same reason.
pub const BlobCommit = struct {
    destination: BlobDestination,
    exported: checkpoint.Export,
    observed_bytes: u64,
};

/// Why a blob could not be finished.
pub const CommitError = error{
    /// The bytes could not be made durable, or could not be named: a rename,
    /// a sync, a name longer than `checkpoint.StagedBlob` allows. Nothing is
    /// kept.
    CommitFailed,
    /// What the export said it produced and what arrived disagree. Nothing is
    /// kept. Not an I/O fault, and worth telling apart from one: an I/O
    /// fault is the machine, this is the contract.
    ExportMismatch,
};

pub const BlobStore = struct {
    context: ?*anyopaque,
    /// A sink for the blob this destination names, or `null` when one cannot
    /// be opened. The export path has an answer for that already.
    open_sink_fn: *const fn (?*anyopaque, BlobDestination) ?checkpoint.Sink,
    /// A source for the blob this descriptor names, or `null` when it is not
    /// there -- which the restore path also already answers.
    open_source_fn: *const fn (?*anyopaque, shapes.CheckpointSourceDescriptor) ?Source,
    /// Finishes the blob the sink was writing and says what the store calls
    /// it.
    ///
    /// Fallible, and that is the whole of why it exists. A `void` close on a
    /// defer could not report a commit failure, could not tell the success
    /// path from the failure path -- it ran on both -- and could not name the
    /// blob, so the name was being invented by the half that did *not* write
    /// the bytes. One naming rule in two places is a rule that will disagree
    /// in one of them.
    commit_sink_fn: *const fn (
        ?*anyopaque,
        checkpoint.Sink,
        BlobCommit,
    ) CommitError!checkpoint.StagedBlob,
    /// Gives the sink back and keeps nothing. For every path that is not a
    /// committed export: a refusal from the Session, a failure in between, a
    /// commit that itself failed.
    abandon_sink_fn: *const fn (?*anyopaque, checkpoint.Sink) void,
    close_source_fn: *const fn (?*anyopaque, Source) void,

    pub const Source = checkpoint_restore.Source;

    /// A store with nothing in it, for a composition that has no blobs yet
    /// and for tests that drive other things. Opening always refuses, which
    /// is the fail-closed answer rather than a store that silently accepts
    /// bytes nobody will find again.
    pub const empty: BlobStore = .{
        .context = null,
        .open_sink_fn = struct {
            fn call(_: ?*anyopaque, _: BlobDestination) ?checkpoint.Sink {
                return null;
            }
        }.call,
        .open_source_fn = struct {
            fn call(_: ?*anyopaque, _: shapes.CheckpointSourceDescriptor) ?Source {
                return null;
            }
        }.call,
        // Unreachable through `empty`, because nothing opens. Refusing rather
        // than returning a name keeps that true if something ever does: a
        // store with nowhere to put bytes must not hand back a name for
        // them.
        .commit_sink_fn = struct {
            fn call(
                _: ?*anyopaque,
                _: checkpoint.Sink,
                _: BlobCommit,
            ) CommitError!checkpoint.StagedBlob {
                return error.CommitFailed;
            }
        }.call,
        .abandon_sink_fn = struct {
            fn call(_: ?*anyopaque, _: checkpoint.Sink) void {}
        }.call,
        .close_source_fn = struct {
            fn call(_: ?*anyopaque, _: Source) void {}
        }.call,
    };
};

/// The sink a method is called with, over the store's own sink.
///
/// The indirection is not ceremony. The store's sink belongs to the
/// composition root; the one handed to the method belongs to this call, and
/// wrapping it is what makes "nothing kept it past the call" a property this
/// side can check: the frame is retired when the call returns, so a sink the
/// callee stored answers `contract_failed` instead of writing into a blob
/// this half has already closed.
pub const ExportSink = struct {
    /// Where the bytes really go.
    inner: checkpoint.Sink,
    destination: BlobDestination,
    written: u64 = 0,

    pub const Backing = Frame(ExportSink);

    pub fn sink(backing: *Backing) checkpoint.Sink {
        return .{ .context = backing.context(), .write_fn = write };
    }

    fn write(context: ?*anyopaque, bytes: []const u8) checkpoint.SinkWriteResult {
        const backing = Backing.fromContext(context) orelse return .contract_failed;
        const self = backing.borrow() orelse return .contract_failed;
        if (bytes.len == 0) return .contract_failed;
        // The bound crossed as a number and is enforced where the bytes are.
        const hard = self.destination.hard_bytes;
        if (self.written > hard - @min(hard, bytes.len)) return .contract_failed;
        const result = self.inner.write_fn(self.inner.context, bytes);
        if (result != .ok) return result;
        self.written += bytes.len;
        return .ok;
    }
};

/// The source a restore is called with, over the store's own source. Same
/// reason as `ExportSink`.
pub const RestoreSource = struct {
    inner: BlobStore.Source,
    read: u64 = 0,

    pub const Backing = Frame(RestoreSource);

    pub fn source(backing: *Backing) BlobStore.Source {
        return .{ .context = backing.context(), .read_fn = readBytes };
    }

    fn readBytes(
        context: ?*anyopaque,
        destination: []u8,
    ) checkpoint_restore.SourceReadResult {
        const backing = Backing.fromContext(context) orelse return .contract_failed;
        const self = backing.borrow() orelse return .contract_failed;
        const result = self.inner.read_fn(self.inner.context, destination);
        switch (result) {
            .bytes => |count| self.read += count,
            else => {},
        }
        return result;
    }
};

test "an export sink writes through to the store and stops at the bound" {
    var recorded: [64]u8 = undefined;
    var sink_state: Recorder = .{ .buffer = &recorded };
    var backing = ExportSink.Backing.init(.{
        .inner = sink_state.sink(),
        .destination = .{ .task_id = 1, .hard_bytes = 8 },
    });
    const handed = ExportSink.sink(&backing);

    try testing.expectEqual(checkpoint.SinkWriteResult.ok, handed.write_fn(handed.context, "abcd"));
    try testing.expectEqual(@as(usize, 4), sink_state.written);
    // One byte past the bound is a contract failure, and it never reaches the
    // store: the bound is enforced before the write-through.
    try testing.expectEqual(
        checkpoint.SinkWriteResult.contract_failed,
        handed.write_fn(handed.context, "efghi"),
    );
    try testing.expectEqual(@as(usize, 4), sink_state.written);

    // The call returns. A sink the callee kept writes nowhere.
    backing.retire();
    try testing.expectEqual(
        checkpoint.SinkWriteResult.contract_failed,
        handed.write_fn(handed.context, "x"),
    );
    try testing.expectEqual(@as(usize, 4), sink_state.written);
}

test "a store refusal is an answer the export path already has" {
    // `empty` refuses to open, which is the fail-closed answer: a store that
    // accepted bytes nobody could find again would report a successful export
    // of a blob that is not there.
    const store = BlobStore.empty;
    try testing.expect(store.open_sink_fn(store.context, .{
        .task_id = 1,
        .hard_bytes = 16,
    }) == null);
    try testing.expect(store.open_source_fn(store.context, .{
        .task_id = 1,
        .generation = 1,
        .digest = @splat(0),
        .byte_size = 16,
    }) == null);
}

const Recorder = struct {
    buffer: []u8,
    written: usize = 0,

    fn sink(self: *Recorder) checkpoint.Sink {
        return .{ .context = self, .write_fn = write };
    }

    fn write(context: ?*anyopaque, bytes: []const u8) checkpoint.SinkWriteResult {
        const self: *Recorder = @ptrCast(@alignCast(context.?));
        if (self.written + bytes.len > self.buffer.len) return .io_failed;
        @memcpy(self.buffer[self.written..][0..bytes.len], bytes);
        self.written += bytes.len;
        return .ok;
    }
};

var sink_scratch: [256]u8 = undefined;
