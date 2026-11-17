//! The execution link: the contract between the UI half and the execution half
//! of a split MetaWork process.
//!
//! This module is the wire, and only the wire. It frames bytes, numbers the
//! port's methods and errors, exchanges build identity, and moves messages
//! across a pipe with a bound. It holds no Agent state, no Product state and
//! no AgentCore path: it imports `agent_contract`, which carries no route to
//! the ABI entry point, so a UI binary that links this module still links no
//! AgentCore archive.
//!
//! What it deliberately does not contain: the vtables that forward port calls
//! over it, the Runtime that answers them, and the closure that runs when one
//! half finds the other gone. Those arrive with the steps that move the
//! Runtime; the link exists first because every one of them needs it.
//!
//! Nothing here descends from the latency spike. The spike measured a pipe;
//! the architecture says in as many words that a spike is not a product
//! protocol, and its framing is not reused.

const std = @import("std");

pub const frame = @import("link/frame.zig");
pub const handshake = @import("link/handshake.zig");
pub const error_code = @import("link/error_code.zig");
pub const method = @import("link/method.zig");
pub const payload = @import("link/payload.zig");
pub const crossings = @import("link/crossings.zig");
pub const handles = @import("link/handles.zig");
pub const shapes = @import("link/shapes.zig");
pub const channel = @import("link/channel.zig");

pub const revision = handshake.revision;
pub const Role = handshake.Role;
pub const Identity = handshake.Identity;
pub const Kind = frame.Kind;
pub const LinkError = error_code.LinkError;

/// Message-size policy for one link, assembled by the composition root from
/// the owners of each number. The defaults are the widest shape the wire will
/// ever legitimately carry; a real composition narrows them to the Host's own
/// product caps, which are smaller.
pub const MessageLimits = channel.MessageLimits;
pub const QueueLimits = channel.Limits;

/// Why a link refused to come up or stopped running. Each value ends the link;
/// none of them is a reason to retry on different terms.
pub const Failure = union(enum) {
    /// The peer's first bytes were not this protocol.
    not_a_link,
    /// This protocol, but a record this build cannot read.
    malformed_identity,
    /// A readable identity that does not match this build.
    refused: handshake.Refusal,
    /// The peer went away before stating its identity.
    peer_closed_during_handshake,
    /// Reading or writing the pipe failed.
    transport_failed,
    /// The peer broke the frame protocol after the handshake.
    violation: channel.Violation,
};

/// Sends this side's identity, reads the peer's, and compares all four fields.
/// Returns the peer's record only when the link may run.
pub fn exchangeIdentity(
    io: std.Io,
    out: std.Io.File,
    reader: *std.Io.Reader,
    role: Role,
    identity: Identity,
) (handshake.EncodeError || error{Refused})!handshake.Record {
    var sent: [handshake.record_bytes]u8 = undefined;
    try handshake.encode(&sent, role, identity);
    var header: [frame.header_bytes]u8 = undefined;
    (frame.Header{
        .kind = .hello,
        .final = true,
        .correlation = 0,
        .payload_len = handshake.record_bytes,
    }).encode(&header);
    out.writeStreamingAll(io, &header) catch return error.Refused;
    out.writeStreamingAll(io, &sent) catch return error.Refused;

    var received_header: [frame.header_bytes]u8 = undefined;
    reader.readSliceAll(&received_header) catch return error.Refused;
    const decoded = frame.decode(&received_header) catch return error.Refused;
    if (decoded.kind != .hello or decoded.payload_len != handshake.record_bytes)
        return error.Refused;
    var received: [handshake.record_bytes]u8 = undefined;
    reader.readSliceAll(&received) catch return error.Refused;
    const record = handshake.decode(&received) catch return error.Refused;
    if (handshake.accept(&record, role.peer(), identity) != null) return error.Refused;
    return record;
}

/// The same exchange, reporting why it failed. The caller that has somewhere
/// to put a diagnostic uses this one.
pub fn exchangeIdentityDetailed(
    io: std.Io,
    out: std.Io.File,
    reader: *std.Io.Reader,
    role: Role,
    identity: Identity,
) error{VersionTooLong}!union(enum) { accepted: handshake.Record, failure: Failure } {
    var sent: [handshake.record_bytes]u8 = undefined;
    handshake.encode(&sent, role, identity) catch |err| return err;
    var header: [frame.header_bytes]u8 = undefined;
    (frame.Header{
        .kind = .hello,
        .final = true,
        .correlation = 0,
        .payload_len = handshake.record_bytes,
    }).encode(&header);
    out.writeStreamingAll(io, &header) catch return .{ .failure = .transport_failed };
    out.writeStreamingAll(io, &sent) catch return .{ .failure = .transport_failed };

    var received_header: [frame.header_bytes]u8 = undefined;
    reader.readSliceAll(&received_header) catch |err| return .{
        .failure = if (err == error.EndOfStream)
            .peer_closed_during_handshake
        else
            .transport_failed,
    };
    const decoded = frame.decode(&received_header) catch return .{ .failure = .not_a_link };
    if (decoded.kind != .hello or decoded.payload_len != handshake.record_bytes)
        return .{ .failure = .not_a_link };
    var received: [handshake.record_bytes]u8 = undefined;
    reader.readSliceAll(&received) catch |err| return .{
        .failure = if (err == error.EndOfStream)
            .peer_closed_during_handshake
        else
            .transport_failed,
    };
    const record = handshake.decode(&received) catch |err| return .{
        .failure = switch (err) {
            error.NotALink => .not_a_link,
            error.Malformed => .malformed_identity,
        },
    };
    if (handshake.accept(&record, role.peer(), identity)) |refusal|
        return .{ .failure = .{ .refused = refusal } };
    return .{ .accepted = record };
}

/// Writes both registries, method lines first. The cross-process port review
/// reads this instead of a table maintained by hand, which is why it is part
/// of the module rather than a document.
pub fn writeRegistry(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print("link revision {d}\n", .{revision});
    try writer.writeAll("methods\n");
    try method.writeTable(writer);
    try writer.writeAll("errors\n");
    try error_code.writeTable(writer);
}

test {
    _ = frame;
    _ = handshake;
    _ = error_code;
    _ = method;
    _ = payload;
    _ = crossings;
    _ = handles;
    _ = shapes;
    _ = channel;
}

test "the two halves of one build accept each other" {
    const io = std.testing.io;
    const identity: Identity = .{
        .version = "0.2.14",
        .core_manifest_sha256 = @splat(0x11),
        .core_abi_revision = 28,
    };
    // The exec side's bytes, read by the UI side.
    var sent: [handshake.record_bytes]u8 = undefined;
    try handshake.encode(&sent, .exec, identity);
    var framed: [frame.header_bytes + handshake.record_bytes]u8 = undefined;
    (frame.Header{
        .kind = .hello,
        .final = true,
        .correlation = 0,
        .payload_len = handshake.record_bytes,
    }).encode(framed[0..frame.header_bytes]);
    @memcpy(framed[frame.header_bytes..], &sent);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const sink = try tmp.dir.createFile(io, "out", .{ .truncate = true });
    defer sink.close(io);

    var reader = std.Io.Reader.fixed(&framed);
    const outcome = try exchangeIdentityDetailed(io, sink, &reader, .ui, identity);
    try std.testing.expectEqual(Role.exec, outcome.accepted.role);
}

test "a peer from another build is refused with the field that differs" {
    const io = std.testing.io;
    const identity: Identity = .{
        .version = "0.2.14",
        .core_manifest_sha256 = @splat(0x11),
        .core_abi_revision = 28,
    };
    var stale = identity;
    stale.version = "0.2.13";
    var sent: [handshake.record_bytes]u8 = undefined;
    try handshake.encode(&sent, .exec, stale);
    var framed: [frame.header_bytes + handshake.record_bytes]u8 = undefined;
    (frame.Header{
        .kind = .hello,
        .final = true,
        .correlation = 0,
        .payload_len = handshake.record_bytes,
    }).encode(framed[0..frame.header_bytes]);
    @memcpy(framed[frame.header_bytes..], &sent);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const sink = try tmp.dir.createFile(io, "out", .{ .truncate = true });
    defer sink.close(io);

    var reader = std.Io.Reader.fixed(&framed);
    const outcome = try exchangeIdentityDetailed(io, sink, &reader, .ui, identity);
    try std.testing.expectEqual(Failure{ .refused = .product_version }, outcome.failure);
}

test "a peer that says nothing is not mistaken for a mismatch" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const sink = try tmp.dir.createFile(io, "out", .{ .truncate = true });
    defer sink.close(io);
    var reader = std.Io.Reader.fixed(&.{});
    const outcome = try exchangeIdentityDetailed(io, sink, &reader, .ui, .{
        .version = "0.2.14",
        .core_manifest_sha256 = @splat(0),
        .core_abi_revision = 28,
    });
    try std.testing.expectEqual(Failure.peer_closed_during_handshake, outcome.failure);
}

test "the registry prints every method and every error" {
    var storage: [16 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try writeRegistry(&writer);
    const text = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "session.export_checkpoint call") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "run.execute call") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, " SessionPoisoned\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, " OutOfMemory\n") != null);
}
