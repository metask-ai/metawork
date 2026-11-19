//! The execution link's frame header and its fragmentation rules.
//!
//! One fixed 16-byte little-endian header, then the fragment payload. Nothing
//! here is a product decision: the header names the kind, says whether the
//! message continues, and carries the call identity. Message-size policy lives
//! in `link.Limits`, which the composition root supplies.
//!
//! Every decode rule fails closed. A reserved field that is not zero, a kind
//! that is not registered, a fragmented `control`, a correlation on a frame
//! that may not carry one -- each is a protocol violation and ends the link
//! rather than being repaired. The peer is our own binary, so a violation is a
//! bug or a foreign process, and both are worse than a dropped link.

const std = @import("std");

pub const header_bytes: usize = 16;

/// The largest payload one frame may carry. A logical message above this is
/// sent as several frames; a `control` frame never is, which is what bounds
/// how long a Stop can wait behind someone else's bytes.
pub const max_fragment_payload_bytes: usize = 64 * 1024;

pub const Kind = enum(u8) {
    /// Identity exchange. Both sides send one; both compare all four fields.
    hello = 1,
    /// A Core event's own JSON bytes, exec to UI.
    event = 2,
    /// The event-ready wake bit, exec to UI. No payload.
    event_ready = 3,
    /// A port call, UI to exec.
    request = 4,
    /// A port call's outcome, exec to UI.
    response = 5,
    /// A parked UI request, exec to UI.
    ui_request = 6,
    /// Its answer, UI to exec.
    ui_response = 7,
    /// Stop, termination and link control. Never fragmented.
    control = 8,
    /// The sender has nothing further to send. No payload.
    goodbye = 9,
    /// Bytes a call is still producing, exec to UI, on that call's own
    /// correlation.
    ///
    /// For a result that is a byte stream rather than a value: a checkpoint
    /// export writes through a sink the caller handed in, and over the link
    /// the caller's sink is in the other process. Each frame is one write,
    /// carried on the correlation of the call that produced it, and the
    /// call's response is what says the stream is complete and what it should
    /// have contained.
    ///
    /// Not fragmented, because a chunk is not a message with a length of its
    /// own: it is as much as one write had, bounded by what a frame can hold.
    /// Several of them on one correlation are a sequence, not fragments of
    /// one thing, which is why `final` is set on each.
    chunk = 10,

    /// Whether a message of this kind may span several frames.
    pub fn fragments(self: Kind) bool {
        return switch (self) {
            .event, .request, .response, .ui_request, .ui_response => true,
            .hello, .event_ready, .control, .goodbye, .chunk => false,
        };
    }

    /// Whether a frame of this kind carries a call identity.
    pub fn correlates(self: Kind) Correlation {
        return switch (self) {
            .request, .response, .ui_request, .ui_response, .chunk => .required,
            .control => .optional,
            .hello, .event, .event_ready, .goodbye => .forbidden,
        };
    }

    /// Whether a frame of this kind must have an empty payload.
    pub fn empty(self: Kind) bool {
        return switch (self) {
            .event_ready, .goodbye => true,
            .hello, .event, .request, .response, .ui_request, .ui_response, .control, .chunk => false,
        };
    }
};

pub const Correlation = enum { required, optional, forbidden };

pub const flag_final: u8 = 1 << 0;

pub const Header = struct {
    kind: Kind,
    /// Set on the last (or only) frame of a logical message.
    final: bool,
    correlation: u64,
    payload_len: u32,

    pub fn encode(self: Header, output: *[header_bytes]u8) void {
        std.debug.assert(self.payload_len <= max_fragment_payload_bytes);
        std.debug.assert(self.final or self.kind.fragments());
        std.mem.writeInt(u32, output[0..4], self.payload_len, .little);
        output[4] = @intFromEnum(self.kind);
        output[5] = if (self.final) flag_final else 0;
        std.mem.writeInt(u16, output[6..8], 0, .little);
        std.mem.writeInt(u64, output[8..16], self.correlation, .little);
    }
};

pub const DecodeError = error{
    /// A byte pattern no registered kind claims.
    UnknownKind,
    /// A reserved field carried data, a flag combination is not legal for the
    /// kind, or a payload-free kind carried bytes.
    Malformed,
    /// Above `max_fragment_payload_bytes`.
    FragmentTooLarge,
};

pub fn decode(bytes: *const [header_bytes]u8) DecodeError!Header {
    const payload_len = std.mem.readInt(u32, bytes[0..4], .little);
    const kind = std.enums.fromInt(Kind, bytes[4]) orelse return error.UnknownKind;
    const flags = bytes[5];
    if (flags & ~flag_final != 0) return error.Malformed;
    if (std.mem.readInt(u16, bytes[6..8], .little) != 0) return error.Malformed;
    const correlation = std.mem.readInt(u64, bytes[8..16], .little);
    if (payload_len > max_fragment_payload_bytes) return error.FragmentTooLarge;
    const final = flags & flag_final != 0;
    if (!final and !kind.fragments()) return error.Malformed;
    if (kind.empty() and payload_len != 0) return error.Malformed;
    switch (kind.correlates()) {
        .required => if (correlation == 0) return error.Malformed,
        .forbidden => if (correlation != 0) return error.Malformed,
        .optional => {},
    }
    return .{
        .kind = kind,
        .final = final,
        .correlation = correlation,
        .payload_len = payload_len,
    };
}

/// How many frames a logical message of `len` bytes becomes. A zero-length
/// message is still one frame, because the kind itself is the information.
pub fn fragmentCount(len: usize) usize {
    if (len == 0) return 1;
    return (len + max_fragment_payload_bytes - 1) / max_fragment_payload_bytes;
}

test "a header round-trips every kind" {
    for (std.enums.values(Kind)) |kind| {
        const header: Header = .{
            .kind = kind,
            .final = true,
            .correlation = switch (kind.correlates()) {
                .required, .optional => 7,
                .forbidden => 0,
            },
            .payload_len = if (kind.empty()) 0 else 3,
        };
        var bytes: [header_bytes]u8 = undefined;
        header.encode(&bytes);
        const decoded = try decode(&bytes);
        try std.testing.expectEqual(kind, decoded.kind);
        try std.testing.expectEqual(header.final, decoded.final);
        try std.testing.expectEqual(header.correlation, decoded.correlation);
        try std.testing.expectEqual(header.payload_len, decoded.payload_len);
    }
}

test "the decoder refuses what the encoder cannot produce" {
    var bytes: [header_bytes]u8 = undefined;
    const base: Header = .{ .kind = .request, .final = true, .correlation = 1, .payload_len = 1 };

    base.encode(&bytes);
    bytes[4] = 0;
    try std.testing.expectError(error.UnknownKind, decode(&bytes));
    base.encode(&bytes);
    bytes[4] = 200;
    try std.testing.expectError(error.UnknownKind, decode(&bytes));

    // A reserved field that carries data is a different protocol, not a
    // forward-compatible one.
    base.encode(&bytes);
    std.mem.writeInt(u16, bytes[6..8], 1, .little);
    try std.testing.expectError(error.Malformed, decode(&bytes));

    base.encode(&bytes);
    bytes[5] |= 0b10;
    try std.testing.expectError(error.Malformed, decode(&bytes));

    base.encode(&bytes);
    std.mem.writeInt(u32, bytes[0..4], @intCast(max_fragment_payload_bytes + 1), .little);
    try std.testing.expectError(error.FragmentTooLarge, decode(&bytes));

    // Control must never be split: that is what bounds how long a Stop waits.
    base.encode(&bytes);
    bytes[4] = @intFromEnum(Kind.control);
    bytes[5] = 0;
    try std.testing.expectError(error.Malformed, decode(&bytes));

    // A payload-free kind with bytes, and a correlation where none may be.
    base.encode(&bytes);
    bytes[4] = @intFromEnum(Kind.event_ready);
    std.mem.writeInt(u64, bytes[8..16], 0, .little);
    try std.testing.expectError(error.Malformed, decode(&bytes));
    base.encode(&bytes);
    bytes[4] = @intFromEnum(Kind.event);
    try std.testing.expectError(error.Malformed, decode(&bytes));

    base.encode(&bytes);
    std.mem.writeInt(u64, bytes[8..16], 0, .little);
    try std.testing.expectError(error.Malformed, decode(&bytes));
}

test "fragment arithmetic covers the empty and the exact-multiple message" {
    try std.testing.expectEqual(@as(usize, 1), fragmentCount(0));
    try std.testing.expectEqual(@as(usize, 1), fragmentCount(1));
    try std.testing.expectEqual(@as(usize, 1), fragmentCount(max_fragment_payload_bytes));
    try std.testing.expectEqual(@as(usize, 2), fragmentCount(max_fragment_payload_bytes + 1));
    try std.testing.expectEqual(@as(usize, 2), fragmentCount(max_fragment_payload_bytes * 2));
    try std.testing.expectEqual(@as(usize, 3), fragmentCount(max_fragment_payload_bytes * 2 + 1));
}
