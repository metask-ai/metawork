//! What a request and a response payload carry besides their arguments.
//!
//! The frame header says kind, correlation and length; it deliberately says
//! nothing about which method a request is for, because the header is the
//! transport and the method is the contract. So a request payload opens with
//! the method's registered number, and a response payload opens with the
//! registered error number -- zero meaning the call succeeded.
//!
//! A request also names the object it is for, when its owner has more than
//! one. `wire_types.Request` derives a method's arguments from its parameters
//! *after* the context pointer, because in process the context is the
//! receiver and a pointer cannot cross. There is exactly one Runtime, so a
//! `runtime` method needs nothing; a Session, a Run and a Run's control
//! handle all exist many at a time, so those requests carry the receiver's
//! handle id between the method number and the arguments. Which it is follows
//! from the method number, so there is nothing to disambiguate and no way for
//! the two sides to disagree about whether a receiver is present.
//!
//! Both are decoded strictly. A method number this build does not register, or
//! an error number it does not register, is a protocol violation rather than
//! something to approximate: the peer is our own binary, so an unknown number
//! means the link is talking to something else.

const std = @import("std");
const error_code = @import("error_code.zig");
const handle_table = @import("handle_table.zig");
const method = @import("method.zig");
const payload = @import("payload.zig");

/// Zero is not a registered error number, so it is free to mean "no error".
pub const ok: u16 = 0;

comptime {
    // The error registry must never assign zero, or a successful response
    // would be indistinguishable from one carrying that error.
    for (error_code.entries) |entry| {
        if (entry.code == ok) @compileError(
            "the error registry assigned " ++ entry.name ++ " the number a response uses for " ++
                "success; pick another, or success and failure become the same byte pattern",
        );
    }
    std.debug.assert(error_code.out_of_memory_code != ok);
}

pub const DecodeError = error{
    /// The payload ended before its header.
    Truncated,
    /// A method number this build does not register.
    UnknownMethod,
    /// An error number this build does not register.
    UnknownError,
    /// A method whose owner has many instances arrived naming none.
    MissingReceiver,
};

pub const header_bytes: usize = 2;

/// Bytes a receiver id occupies when the method has one.
pub const receiver_bytes: usize = @sizeOf(u64);

/// Which table the receiver of a method belongs to, or `null` for the one
/// Runtime there is.
///
/// A property of the owner rather than of the method, and exhaustive, so an
/// owner added later cannot default into "needs no receiver" -- which would
/// send every one of its calls to whatever object the far side had last.
pub fn receiverOf(owner: method.Owner) ?Receiver {
    return switch (owner) {
        .runtime => null,
        .session => .session,
        // A Run and its control handle are named by the same id: in process
        // both are reached through the Session's control block, and the Run's
        // own identity travels as ordinary arguments.
        .run, .run_control => .run,
    };
}

pub const Receiver = enum { session, run };

pub fn requestHeaderBytes(owner: method.Owner) usize {
    return header_bytes + if (receiverOf(owner) == null) 0 else receiver_bytes;
}

pub fn encodeRequestHeader(output: []u8, entry: method.Entry, receiver: handle_table.Id) void {
    std.debug.assert(output.len == requestHeaderBytes(entry.owner));
    std.mem.writeInt(u16, output[0..header_bytes], entry.code, .little);
    if (receiverOf(entry.owner) == null) {
        std.debug.assert(!receiver.valid());
        return;
    }
    std.debug.assert(receiver.valid());
    std.mem.writeInt(u64, output[header_bytes..][0..receiver_bytes], receiver.bits(), .little);
}

/// The method a request is for, the object it is for, and the bytes after
/// both.
pub fn decodeRequest(bytes: []const u8) DecodeError!struct {
    entry: method.Entry,
    /// `handle_table.Id.none` for a method whose owner has one instance.
    receiver: handle_table.Id,
    arguments: []const u8,
} {
    if (bytes.len < header_bytes) return error.Truncated;
    const code = std.mem.readInt(u16, bytes[0..header_bytes], .little);
    const entry = method.find(code) catch return error.UnknownMethod;
    if (receiverOf(entry.owner) == null)
        return .{ .entry = entry, .receiver = .none, .arguments = bytes[header_bytes..] };
    if (bytes.len < header_bytes + receiver_bytes) return error.Truncated;
    const id = handle_table.Id.fromBits(
        std.mem.readInt(u64, bytes[header_bytes..][0..receiver_bytes], .little),
    );
    // A zero id is invalid by construction, so a request that names no
    // receiver where one is required is a protocol violation rather than a
    // call on whatever the table happens to hold.
    if (!id.valid()) return error.MissingReceiver;
    return .{
        .entry = entry,
        .receiver = id,
        .arguments = bytes[header_bytes + receiver_bytes ..],
    };
}

pub fn encodeResponseHeader(output: *[header_bytes]u8, code: u16) void {
    std.mem.writeInt(u16, output, code, .little);
}

/// A response is either a value or an error, never both. The caller that asked
/// for a method with no payload still gets an empty `value`.
pub const Outcome = union(enum) {
    value: []const u8,
    failure: error_code.LinkError,
};

pub fn decodeResponse(bytes: []const u8) DecodeError!Outcome {
    if (bytes.len < header_bytes) return error.Truncated;
    const code = std.mem.readInt(u16, bytes[0..header_bytes], .little);
    if (code == ok) return .{ .value = bytes[header_bytes..] };
    // A failure carries no value: a response that claimed both would leave
    // the caller to decide which to believe.
    if (bytes.len != header_bytes) return error.UnknownError;
    return .{ .failure = error_code.decode(code) orelse return error.UnknownError };
}

const testing = std.testing;

test "a request names its method, its receiver, and hands back the rest" {
    const entry = try method.find(method.codeOf(.session, "set_model"));
    const header = requestHeaderBytes(entry.owner);
    try testing.expectEqual(header_bytes + receiver_bytes, header);

    var storage: [header_bytes + receiver_bytes + 3]u8 = undefined;
    const receiver: handle_table.Id = .{ .slot = 4, .generation = 7 };
    encodeRequestHeader(storage[0..header], entry, receiver);
    @memcpy(storage[header..], "abc");

    const decoded = try decodeRequest(&storage);
    try testing.expectEqual(entry.code, decoded.entry.code);
    try testing.expectEqualStrings("set_model", decoded.entry.name);
    try testing.expectEqual(receiver.bits(), decoded.receiver.bits());
    try testing.expectEqualStrings("abc", decoded.arguments);
}

test "the one Runtime needs no receiver, and the many-instance owners refuse a missing one" {
    const runtime_entry = try method.find(method.codeOf(.runtime, "has_pending_events"));
    try testing.expect(receiverOf(runtime_entry.owner) == null);
    try testing.expectEqual(header_bytes, requestHeaderBytes(runtime_entry.owner));

    var runtime_request: [header_bytes]u8 = undefined;
    encodeRequestHeader(&runtime_request, runtime_entry, .none);
    const runtime_decoded = try decodeRequest(&runtime_request);
    try testing.expect(!runtime_decoded.receiver.valid());
    try testing.expectEqual(@as(usize, 0), runtime_decoded.arguments.len);

    // A Session method whose receiver is all zeroes names nothing, and is
    // refused rather than answered against whatever a table holds.
    const session_entry = try method.find(method.codeOf(.session, "set_model"));
    var zeroed: [header_bytes + receiver_bytes]u8 = @splat(0);
    std.mem.writeInt(u16, zeroed[0..header_bytes], session_entry.code, .little);
    try testing.expectError(error.MissingReceiver, decodeRequest(&zeroed));

    // And one that stops before its receiver is truncated, not receiverless.
    try testing.expectError(error.Truncated, decodeRequest(zeroed[0 .. header_bytes + 1]));
}

test "a Run and its control handle are named by the same receiver" {
    // They are one object in process -- the Session's control block -- so two
    // ids would be two names for it, and the second could go stale alone.
    try testing.expectEqual(Receiver.run, receiverOf(.run).?);
    try testing.expectEqual(Receiver.run, receiverOf(.run_control).?);
    try testing.expectEqual(Receiver.session, receiverOf(.session).?);
}

test "a response is a value or an error, and never both" {
    var storage: [header_bytes + 2]u8 = undefined;
    encodeResponseHeader(storage[0..header_bytes], ok);
    @memcpy(storage[header_bytes..], "hi");
    switch (try decodeResponse(&storage)) {
        .value => |bytes| try testing.expectEqualStrings("hi", bytes),
        .failure => return error.ExpectedValue,
    }

    var failed: [header_bytes]u8 = undefined;
    encodeResponseHeader(&failed, error_code.encode(error.SessionPoisoned));
    switch (try decodeResponse(&failed)) {
        .value => return error.ExpectedFailure,
        .failure => |err| try testing.expectEqual(@as(anyerror, error.SessionPoisoned), err),
    }

    // An error with a payload is refused rather than half-believed.
    var both: [header_bytes + 1]u8 = undefined;
    encodeResponseHeader(both[0..header_bytes], error_code.encode(error.QueueFull));
    both[header_bytes] = 1;
    try testing.expectError(error.UnknownError, decodeResponse(&both));
}

test "an unregistered number is refused in both directions" {
    // Written by hand: there is no entry to encode from, which is the point.
    var request: [header_bytes]u8 = undefined;
    std.mem.writeInt(u16, &request, 0x0999, .little);
    try testing.expectError(error.UnknownMethod, decodeRequest(&request));

    var response: [header_bytes]u8 = undefined;
    encodeResponseHeader(&response, std.math.maxInt(u16));
    try testing.expectError(error.UnknownError, decodeResponse(&response));

    try testing.expectError(error.Truncated, decodeRequest(&.{1}));
    try testing.expectError(error.Truncated, decodeResponse(&.{}));
}

test "success is a number the error registry can never assign" {
    // The comptime block above enforces it; this records why it matters.
    try testing.expect(error_code.decode(ok) == null);
    _ = payload;
}
