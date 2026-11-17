//! What a request and a response payload carry besides their arguments.
//!
//! The frame header says kind, correlation and length; it deliberately says
//! nothing about which method a request is for, because the header is the
//! transport and the method is the contract. So a request payload opens with
//! the method's registered number, and a response payload opens with the
//! registered error number -- zero meaning the call succeeded.
//!
//! Both are decoded strictly. A method number this build does not register, or
//! an error number it does not register, is a protocol violation rather than
//! something to approximate: the peer is our own binary, so an unknown number
//! means the link is talking to something else.

const std = @import("std");
const error_code = @import("error_code.zig");
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
};

pub const header_bytes: usize = 2;

pub fn encodeRequestHeader(output: *[header_bytes]u8, code: u16) void {
    std.mem.writeInt(u16, output, code, .little);
}

/// The method a request is for, and the bytes after it.
pub fn decodeRequest(bytes: []const u8) DecodeError!struct {
    entry: method.Entry,
    arguments: []const u8,
} {
    if (bytes.len < header_bytes) return error.Truncated;
    const code = std.mem.readInt(u16, bytes[0..header_bytes], .little);
    const entry = method.find(code) catch return error.UnknownMethod;
    return .{ .entry = entry, .arguments = bytes[header_bytes..] };
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

test "a request names its method and hands back the rest" {
    var storage: [header_bytes + 3]u8 = undefined;
    const code = method.codeOf(.session, "set_model");
    encodeRequestHeader(storage[0..header_bytes], code);
    @memcpy(storage[header_bytes..], "abc");
    const decoded = try decodeRequest(&storage);
    try testing.expectEqual(code, decoded.entry.code);
    try testing.expectEqualStrings("set_model", decoded.entry.name);
    try testing.expectEqualStrings("abc", decoded.arguments);
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
    var request: [header_bytes]u8 = undefined;
    encodeRequestHeader(&request, 0x0999);
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
