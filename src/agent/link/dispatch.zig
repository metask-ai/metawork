//! The execution half's answer to one request, and the lifetime rule the
//! effects it performs are held to.
//!
//! Four of the parameters the link still owes are effects this half performs
//! rather than values it receives: the two checkpoint ones, and the image and
//! video bindings. `adapters.zig` records that, and says the obligation they
//! carry has to be checked here rather than promised there. This is that
//! check.
//!
//! The obligation is narrow and it is the worst failure available in this
//! change. A capability is a context pointer and a function pointer. The
//! context has to be built for one call, because what it stands for -- a
//! destination, a reader, a credential source -- is a fact about that call.
//! If anything keeps the pointer after the call returns, it is pointing at
//! memory this half has reused: a cross-process use-after-free that reads as
//! plausible data, which is the failure class this whole change exists to
//! remove rather than relocate.
//!
//! Nothing can stop a callee from storing a pointer it was handed. What can
//! be arranged is that storing one is useless. So a per-call context is a
//! `Frame`, every use of it goes through `borrow`, and the dispatcher retires
//! the frame when the call returns. A retained frame then answers "no" --
//! each capability's own fail-closed value -- instead of reading whatever
//! occupies that stack slot by then. That is a property with a test that
//! fails if it breaks, which is what this had to be instead of a comment.

const std = @import("std");
const contract = @import("agent_contract");
const adapters = @import("adapters.zig");
const envelope = @import("envelope.zig");
const handle_table = @import("handle_table.zig");
const method = @import("method.zig");
const payload = @import("payload.zig");
const wire_types = @import("wire_types.zig");

const checkpoint = @import("agent_checkpoint");
const port = contract.port;

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

pub const DecodeError = envelope.DecodeError || payload.DecodeError;

/// What a request named, once its method and receiver are known.
pub const Request = struct {
    entry: method.Entry,
    receiver: handle_table.Id,
    arguments: []const u8,
};

/// Reads a request far enough to know what it is for, and refuses anything
/// this build does not register.
pub fn classify(bytes: []const u8) DecodeError!Request {
    const decoded = try envelope.decodeRequest(bytes);
    return .{
        .entry = decoded.entry,
        .receiver = decoded.receiver,
        .arguments = decoded.arguments,
    };
}

/// The receiver a request named, resolved to the object the method is called
/// on. Separate from `classify` because resolving is where a stale id becomes
/// a refusal, and that is worth being able to test on its own.
pub fn resolveReceiver(
    bindings: adapters.Bindings,
    request: Request,
) adapters.ResolveError!?Receiver {
    const kind = envelope.receiverOf(request.entry.owner) orelse return null;
    return switch (kind) {
        .session => .{
            .session = (bindings.sessions.resolve(request.receiver) orelse
                return error.UnknownHandle).*,
        },
        .run => .{
            .run = bindings.runs.resolve(request.receiver) orelse
                return error.UnknownHandle,
        },
    };
}

pub const Receiver = union(enum) {
    session: port.SessionPort,
    run: *adapters.BegunRun,
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

test "a request is classified by the registry, and an unregistered one is refused" {
    const entry = try method.find(method.codeOf(.runtime, "has_pending_events"));
    var bytes: [envelope.header_bytes]u8 = undefined;
    envelope.encodeRequestHeader(&bytes, entry, .none);

    const classified = try classify(&bytes);
    try testing.expectEqualStrings("has_pending_events", classified.entry.name);
    try testing.expect(!classified.receiver.valid());
    try testing.expectEqual(@as(usize, 0), classified.arguments.len);

    var unknown: [envelope.header_bytes]u8 = undefined;
    std.mem.writeInt(u16, &unknown, 0x7777, .little);
    try testing.expectError(error.UnknownMethod, classify(&unknown));
}

test "a receiver is resolved through its table, and a stale id is refused" {
    var sessions = try handle_table.Table(port.SessionPort).init(testing.allocator, 1);
    defer sessions.deinit();
    var runs = try handle_table.Table(adapters.BegunRun).init(testing.allocator, 1);
    defer runs.deinit();
    var leases = try handle_table.Table(@import("agent_catalog").Lease).init(testing.allocator, 1);
    defer leases.deinit();
    var skill_restore = try handle_table.Table(port.SkillRestoreInputs).init(testing.allocator, 1);
    defer skill_restore.deinit();
    var session_restore = try handle_table.Table(port.SessionRestoreInputs).init(testing.allocator, 1);
    defer session_restore.deinit();
    var selections = try handle_table.Table(@import("agent_mcp_catalog").Selection).init(testing.allocator, 1);
    defer selections.deinit();
    const bindings: adapters.Bindings = .{
        .allocator = testing.allocator,
        .sessions = &sessions,
        .runs = &runs,
        .leases = &leases,
        .skill_restore = &skill_restore,
        .session_restore = &session_restore,
        .selections = &selections,
    };

    var held: port.SessionPort = .{ .context = null, .vtable = undefined };
    const id = try sessions.insert(&held);
    const entry = try method.find(method.codeOf(.session, "set_model"));

    var bytes: [envelope.header_bytes + envelope.receiver_bytes]u8 = undefined;
    envelope.encodeRequestHeader(&bytes, entry, id);
    const request = try classify(&bytes);
    const receiver = try resolveReceiver(bindings, request);
    try testing.expect(receiver.? == .session);

    // A runtime method names no receiver, and resolving one answers nothing
    // rather than reaching into a table.
    const runtime_entry = try method.find(method.codeOf(.runtime, "has_pending_events"));
    var runtime_bytes: [envelope.header_bytes]u8 = undefined;
    envelope.encodeRequestHeader(&runtime_bytes, runtime_entry, .none);
    try testing.expect(try resolveReceiver(bindings, try classify(&runtime_bytes)) == null);

    _ = sessions.take(id);
    try testing.expectError(error.UnknownHandle, resolveReceiver(bindings, request));
}

test "every registered method's receiver resolves through a table this half has" {
    // The pairing is a property of the owner, so it is checked over the whole
    // registry rather than per call site: a method whose receiver had no table
    // would fail at its first request instead of here.
    inline for (method.entries) |entry| {
        const kind = envelope.receiverOf(entry.owner);
        switch (entry.owner) {
            .runtime => try testing.expect(kind == null),
            .session => try testing.expectEqual(envelope.Receiver.session, kind.?),
            .run, .run_control => try testing.expectEqual(envelope.Receiver.run, kind.?),
        }
    }
    _ = wire_types;
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
