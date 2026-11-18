//! The caller's half of a call: send the request, wait, read the answer back
//! into the port's own types.
//!
//! This is the fourth direction. The execution half rebuilds arguments it was
//! sent (`adapters.parameterAdapter`) and encodes what the method returned
//! (`adapters.resultAdapter`); this side encodes the arguments it is called
//! with and reads the answer back. The four are not symmetric, which is why
//! each is counted on its own.
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
const shapes = @import("shapes.zig");
const wire_types = @import("wire_types.zig");

const port = contract.port;
const surface = contract.surface;
const control = contract.control;

/// The caller's half of one link.
pub const Client = struct {
    /// Owns what comes back, per the rule above.
    allocator: std.mem.Allocator,
    outbound: *channel.Outbound,
    pending: *pending.Table,
    /// The slots this half names boxed handles by.
    boxes: *handle_repr.Boxes,
};

/// What a port value's `context` points at on this side: the link, and the id
/// the execution half named the object by.
///
/// This is the whole of the `in_context` representation. The pointer is a real
/// pointer to this record, so every check on it means what it says, and the
/// contract did not have to grow a field.
pub const Binding = struct {
    client: *Client,
    id: handle_table.Id,

    pub fn of(context: ?*anyopaque) *Binding {
        return @ptrCast(@alignCast(context.?));
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
pub fn call(
    comptime owner: method.Owner,
    comptime name: []const u8,
    client: *Client,
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
            const outcome = envelope.decodeResponse(bytes) catch return error.Unreadable;
            return switch (outcome) {
                .failure => |err| .{ .failed = err },
                .value => |value| blk: {
                    const Wired = comptime wire_types.Response(Signature(owner, name));
                    if (comptime Wired == void) {
                        if (value.len != 0) return error.Unreadable;
                        break :blk .{ .returned = {} };
                    }
                    const decoded = payload.decodeExact(Wired, client.allocator, value) catch
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

test "a binding is a real pointer to this side's own record" {
    var client: Client = undefined;
    var binding: Binding = .{ .client = &client, .id = .{ .slot = 4, .generation = 1 } };
    const port_value: port.SessionPort = .{ .context = &binding, .vtable = undefined };

    // The whole of the `in_context` representation: the context is ours, so
    // the id rides there and the pointer is a pointer.
    try testing.expectEqual(
        @as(u32, 4),
        Binding.of(port_value.context).id.slot,
    );
    try testing.expectEqual(
        handle_repr.Representation.in_context,
        handle_repr.representationOf(port.SessionPort).?,
    );
}
