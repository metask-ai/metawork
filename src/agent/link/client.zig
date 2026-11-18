//! The caller's half of a call: send the request, wait, read the answer back
//! into the port's own types.
//!
//! This is the fourth direction. The execution half rebuilds arguments it was
//! sent (`adapters.parameterAdapter`) and encodes what the method returned
//! (`adapters.resultAdapter`); this side encodes the arguments it is called
//! with and reads the answer back (`inbound.zig`). The four are not
//! symmetric, which is why each is counted on its own.
//!
//! ## Who owns what comes back
//!
//! One rule, and it is the port's own: whatever the port type says the caller
//! owns, this half owns a copy of, allocated from its own allocator and freed
//! by that type's existing `deinit`. `control.TerminalResult` is the one that
//! settles it -- its `deinit` frees `diagnostic_storage` through its own
//! `allocator` field, so this half allocates and Product frees exactly as it
//! does in process. Nothing about ownership changes shape, and no contract
//! moves.
//!
//! Where the port type borrows, the response bytes are borrowed for the
//! length of the call and nothing is allocated.
//!
//! ## What a gone link answers
//!
//! `unreachability.zig` says every port answer can say the link is gone, and
//! each stub answers with what that file names: the declared value for a type
//! that declares one, and `DependencyUnreachable` for an error union -- added
//! because no existing member means it and reusing one would assert something
//! false.

const std = @import("std");
const contract = @import("agent_contract");
const channel = @import("channel.zig");
const envelope = @import("envelope.zig");
const error_code = @import("error_code.zig");
const handle_repr = @import("handle_repr.zig");
const handle_table = @import("handle_table.zig");
const method = @import("method.zig");
const payload = @import("payload.zig");
const pending = @import("pending.zig");
const wire_types = @import("wire_types.zig");

const port = contract.port;

/// The boxes this half names far objects by, typed to this half.
pub const Boxes = handle_repr.Boxes(Client);

/// One box: the whole of both handle representations. A `boxed` handle's
/// pointer is this record's address; an `in_context` handle's port value
/// carries that address in its own `context`.
pub const Box = Boxes.Slot;

/// The vtables this half installs in the port values it hands out.
///
/// Held as data rather than reached by import, because the stubs are what
/// fill them and the stubs are what reads the answers back: a direct import
/// either way round would be a cycle. Passing them in also means a test can
/// bind a vtable of its own without the stub module in the way.
pub const Vtables = struct {
    session: *const port.SessionPort.VTable,
    run: *const port.RunPort.VTable,
    run_control: *const port.RunControl.VTable,
    runtime: *const port.RuntimePort.VTable,
};

/// The caller's half of one link.
pub const Client = struct {
    /// Owns what comes back, per the rule above.
    allocator: std.mem.Allocator,
    outbound: *channel.Outbound,
    pending: *pending.Table,
    boxes: Boxes,
    vtables: Vtables,

    /// Two-phase, because the boxes carry the way back to the link they
    /// belong to and that is this value's own address.
    pub fn init(
        self: *Client,
        allocator: std.mem.Allocator,
        outbound: *channel.Outbound,
        slots: *pending.Table,
        vtables: Vtables,
        box_count: usize,
    ) std.mem.Allocator.Error!void {
        self.* = .{
            .allocator = allocator,
            .outbound = outbound,
            .pending = slots,
            .boxes = undefined,
            .vtables = vtables,
        };
        self.boxes = try Boxes.init(allocator, box_count, self);
    }

    pub fn deinit(self: *Client) void {
        self.boxes.deinit();
    }

    /// The link a port value belongs to, from the context it carries.
    ///
    /// The cast is on trust, and it is worth being exact about what that does
    /// and does not mean. A stub reached through an `in_context` port value
    /// receives nothing but the context pointer: there is no second field to
    /// anchor on, so a pointer this half never issued cannot be detected
    /// here. That is not a gap the link introduces -- in process the same
    /// context is an implementation pointer and a wrong one is already
    /// undefined behaviour, so Product handing back a value it was not given
    /// is the same bug with the same consequence either way.
    ///
    /// What the box *does* buy is the case that is not a Product bug: a
    /// handle released and then used again. The box is still a box, so the
    /// read is a read of live memory, and its id has been cleared -- so the
    /// next step refuses it. One allocation per handle would have made that a
    /// use-after-free instead.
    pub fn linkFrom(context: ?*anyopaque) *Client {
        const box: *Box = @ptrCast(@alignCast(context.?));
        return box.link;
    }

    /// The id a port value's context names, checked against this half's own
    /// table rather than read straight out of the box.
    pub fn receiverFrom(context: ?*anyopaque) Boxes.Error!handle_table.Id {
        const box: *Box = @ptrCast(@alignCast(context.?));
        return box.link.boxes.borrow(box);
    }
};

/// Why a call did not produce an answer. Never returned to Product as such:
/// each stub turns it into what its own return type can say.
pub const Failure = error{
    /// Nothing is there, or nothing will be.
    Unreachable,
    /// There is someone, but not room right now.
    Busy,
    /// An answer arrived that this build does not encode, which means the
    /// peer is not this build.
    Unreadable,
};

pub const CallError = Failure || std.mem.Allocator.Error;

/// Sends one request and reads the answer.
///
/// The three failures stay apart for the same reason they do on the reverse
/// path: "nobody is there" and "not right now" are different facts, and a
/// diagnostic that merged them would name the wrong cause.
///
/// The answer is decoded against a copy of the response bytes taken into
/// `arena`, not against the transport's own buffer. `payload.decode` borrows
/// `[]const u8` from the bytes it reads and allocates every other slice in
/// the allocator it is given, so decoding in place would hand back a value
/// pointing into a buffer this function frees on the way out -- a value that
/// reads correctly for as long as nothing else has used that memory, which is
/// the failure mode this whole change exists to remove. One copy per call
/// buys a lifetime that is simply the arena's.
pub fn call(
    comptime owner: method.Owner,
    comptime name: []const u8,
    client: *Client,
    arena: std.mem.Allocator,
    receiver: handle_table.Id,
    arguments: Arguments(owner, name),
) CallError!Answer(owner, name) {
    const entry = comptime method.find(method.codeOf(owner, name)) catch unreachable;
    const header = comptime envelope.requestHeaderBytes(owner);

    const framed = try client.allocator.alloc(
        u8,
        header + payload.encodedSize(@TypeOf(arguments), arguments),
    );
    defer client.allocator.free(framed);
    envelope.encodeRequestHeader(framed[0..header], entry, receiver);
    _ = payload.encode(@TypeOf(arguments), arguments, framed[header..]);

    const correlation = client.pending.open() catch return error.Busy;
    switch (try client.outbound.trySubmit(.request, correlation, framed)) {
        .queued => {},
        // Nothing was sent, so nothing is owed: the slot goes back now rather
        // than being held for an answer that cannot come.
        .busy => {
            client.pending.discardUnsent(correlation);
            return error.Busy;
        },
        .closed => {
            client.pending.discardUnsent(correlation);
            return error.Unreachable;
        },
    }

    switch (client.pending.claim(correlation)) {
        .link_closed => return error.Unreachable,
        .response => |bytes| {
            defer client.pending.allocator.free(bytes);
            const held = try arena.dupe(u8, bytes);
            const outcome = envelope.decodeResponse(held) catch return error.Unreadable;
            return switch (outcome) {
                .failure => |err| .{ .failed = err },
                .value => |value| blk: {
                    const Wired = comptime wire_types.Response(Signature(owner, name));
                    if (comptime Wired == void) {
                        if (value.len != 0) return error.Unreadable;
                        break :blk .{ .returned = {} };
                    }
                    const decoded = payload.decodeExact(Wired, arena, value) catch
                        return error.Unreadable;
                    break :blk .{ .returned = decoded };
                },
            };
        },
    }
}

pub fn Signature(comptime owner: method.Owner, comptime name: []const u8) type {
    return @typeInfo(@FieldType(owner.VTable(), name)).pointer.child;
}

pub fn Arguments(comptime owner: method.Owner, comptime name: []const u8) type {
    return wire_types.Request(Signature(owner, name));
}

/// What one call came back with: the method's own failure, or its wire value.
///
/// The method's failure is not this layer's failure, which is the same split
/// the dispatcher keeps on the other side: a `surface.Error` is an answer.
pub fn Answer(comptime owner: method.Owner, comptime name: []const u8) type {
    const Wired = wire_types.Response(Signature(owner, name));
    return union(enum) {
        returned: Wired,
        failed: error_code.LinkError,
    };
}

const testing = std.testing;

test "a request carries its method, its receiver and its arguments" {
    // Built here rather than driven, because what is under test is the bytes
    // a stub puts on the wire: a dispatcher reading them back is the other
    // side's test.
    const entry = try method.find(method.codeOf(.session, "set_model"));
    const header = envelope.requestHeaderBytes(.session);
    const arguments: Arguments(.session, "set_model") = .{"a-model"};

    const framed = try testing.allocator.alloc(
        u8,
        header + payload.encodedSize(@TypeOf(arguments), arguments),
    );
    defer testing.allocator.free(framed);
    envelope.encodeRequestHeader(framed[0..header], entry, .{ .slot = 2, .generation = 3 });
    _ = payload.encode(@TypeOf(arguments), arguments, framed[header..]);

    const decoded = try envelope.decodeRequest(framed);
    try testing.expectEqualStrings("set_model", decoded.entry.name);
    try testing.expectEqual(@as(u32, 2), decoded.receiver.slot);
    const read = try payload.decodeExact(
        Arguments(.session, "set_model"),
        testing.allocator,
        decoded.arguments,
    );
    try testing.expectEqualStrings("a-model", read[0]);
}

test "the method's failure and the call's failure are different things" {
    // A `surface.Error` is an answer: the far side was reached and said no.
    // The three in `Failure` are about not having been answered at all, and
    // no stub may report one as the other.
    const Session = Answer(.session, "set_model");
    try testing.expectEqual(void, @FieldType(Session, "returned"));
    try testing.expectEqual(error_code.LinkError, @FieldType(Session, "failed"));

    // And they stay apart by construction: no member of `Failure` is a
    // member of the contract's set, so a stub cannot hand one to Product by
    // accident -- it has to translate, which is where the decision belongs.
    inline for (@typeInfo(Failure).error_set.?) |member| {
        for (error_code.entries) |entry| {
            try testing.expect(!std.mem.eql(u8, entry.name, member.name));
        }
    }
}

test "a gone link has an answer in the contract's own set" {
    // `unreachability.zig` deferred which error names it; this is the answer,
    // and it is numbered like any other so a diagnostic can name it.
    const numbered = error_code.encode(error.DependencyUnreachable);
    try testing.expect(numbered != envelope.ok);
    try testing.expectEqual(
        @as(anyerror, error.DependencyUnreachable),
        error_code.decode(numbered).?,
    );
}

/// A client with no channel: enough to own boxes and be found through one.
fn boxedClient(count: usize) !*Client {
    const self = try testing.allocator.create(Client);
    try self.init(
        testing.allocator,
        undefined,
        undefined,
        .{
            .session = undefined,
            .run = undefined,
            .run_control = undefined,
            .runtime = undefined,
        },
        count,
    );
    return self;
}

fn releaseClient(self: *Client) void {
    self.deinit();
    testing.allocator.destroy(self);
}

test "a port value's context is a box, and the box is the way back to the link" {
    const client = try boxedClient(2);
    defer releaseClient(client);

    const box = try client.boxes.open(.{ .slot = 4, .generation = 1 });
    const session: port.SessionPort = .{ .context = box, .vtable = client.vtables.session };

    // The pointer is a real pointer to a record of ours, so every check on it
    // means what it says -- and the id rides there rather than in the
    // contract, which did not have to grow a field.
    try testing.expectEqual(client, Client.linkFrom(session.context));
    try testing.expectEqual(@as(u32, 4), (try Client.receiverFrom(session.context)).slot);
    try testing.expectEqual(
        handle_repr.Representation.in_context,
        handle_repr.representationOf(port.SessionPort).?,
    );
}

test "a released handle used again is refused, not read" {
    const client = try boxedClient(1);
    defer releaseClient(client);

    const box = try client.boxes.open(.{ .slot = 7, .generation = 3 });
    const session: port.SessionPort = .{ .context = box, .vtable = client.vtables.session };

    const Releasing = struct {
        fn ok(_: void, _: handle_table.Id) anyerror!void {}
    };
    try client.boxes.releaseThrough(box, anyerror!void, {}, Releasing.ok);

    // This is what the box buys over one allocation per handle: the read is
    // still a read of live memory, so the refusal is a refusal rather than a
    // use-after-free.
    try testing.expectEqual(client, Client.linkFrom(session.context));
    try testing.expectError(error.UnknownBox, Client.receiverFrom(session.context));
}
