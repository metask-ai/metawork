//! The execution half's entry point.
//!
//! This runs instead of the application, not inside it. It is reached before
//! the Native SDK runner is entered and before any window exists, which is the
//! whole reason the fork sits at the top of `app.run`: a process that gets as
//! far as `runWithOptions` has a WebView, and the execution half must never
//! have one.
//!
//! It states its identity, accepts the peer's, and then hands the link to the
//! `Server` its composition root passed. Without one it serves frames by
//! dropping them until the UI closes the pipe, answers `goodbye`, and exits.
//!
//! It composes no Product owner, opens no database, reads no Workspace and
//! creates no window. Everything it will own arrives explicitly.

const std = @import("std");

const agent_link = @import("metawork_agent_link");

/// Exit codes. They are read by a human looking at a stopped child, and by the
/// UI half's reaper, so they stay small and stable.
pub const Exit = enum(u8) {
    /// The UI closed the link; this is the normal end.
    link_closed = 0,
    /// The peer's identity is not ours. Nothing was negotiated.
    identity_refused = 10,
    /// The peer broke the frame protocol.
    protocol_violation = 11,
    /// The pipes were not usable.
    transport_failed = 12,
    /// A resource this process needs at startup was unavailable.
    resource_unavailable = 13,
    /// The link ended, and tidying up did not finish within its deadline.
    exit_deadline = 14,
};

/// What serves the link once identity is agreed, if anything does.
///
/// Absent, this process answers the handshake and drops every frame, which
/// is all a build without an execution half composed can honestly do. The
/// composition root decides whether one exists; this module never reaches
/// for it, so a build that does not pass one does not contain one.
pub const Server = struct {
    context: ?*anyopaque,
    serve_fn: *const fn (?*anyopaque, Link) Exit,
};

/// The agreed link, handed to the server.
pub const Link = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    output: std.Io.File,
    message_limits: agent_link.MessageLimits,
    queue_limits: agent_link.QueueLimits,
};

pub const Options = struct {
    identity: agent_link.Identity,
    message_limits: agent_link.MessageLimits,
    queue_limits: agent_link.QueueLimits = .{},
    read_buffer_bytes: usize = 64 * 1024,
    server: ?Server = null,
};

/// Serves the link until it ends, and returns the exit code to use.
pub fn run(
    io: std.Io,
    allocator: std.mem.Allocator,
    options: Options,
) Exit {
    const input = std.Io.File.stdin();
    const output = std.Io.File.stdout();

    const read_buffer = allocator.alloc(u8, options.read_buffer_bytes) catch
        return .resource_unavailable;
    defer allocator.free(read_buffer);
    var reader = input.readerStreaming(io, read_buffer);

    const outcome = agent_link.exchangeIdentityDetailed(
        io,
        output,
        &reader.interface,
        .exec,
        options.identity,
    ) catch return .identity_refused;
    switch (outcome) {
        .failure => |failure| return switch (failure) {
            .transport_failed => .transport_failed,
            else => .identity_refused,
        },
        .accepted => {},
    }

    if (options.server) |server| return server.serve_fn(server.context, .{
        .io = io,
        .allocator = allocator,
        .reader = &reader.interface,
        .output = output,
        .message_limits = options.message_limits,
        .queue_limits = options.queue_limits,
    });

    var outbound: agent_link.channel.Outbound = undefined;
    outbound.start(io, allocator, output, options.queue_limits) catch
        return .resource_unavailable;
    defer outbound.stop();

    var discard: Discard = .{};
    var inbound: agent_link.channel.Inbound = undefined;
    inbound.init(
        io,
        allocator,
        &reader.interface,
        options.message_limits,
        discard.sink(),
    ) catch return .resource_unavailable;
    defer inbound.deinit();

    return switch (inbound.run()) {
        .peer_closed, .consumer_stopped => .link_closed,
        .read_failed => .transport_failed,
        .out_of_memory => .resource_unavailable,
        .violation => .protocol_violation,
    };
}

/// Until the Runtime moves here there is nothing to answer a request with.
/// Dropping a message is not something a later step may inherit, so this
/// counts what it dropped and the step that moves the Runtime replaces it
/// rather than extending it.
const Discard = struct {
    delivered: u64 = 0,

    fn sink(self: *Discard) agent_link.channel.Sink {
        return .{ .context = self, .deliver_fn = deliver };
    }

    fn deliver(
        context: ?*anyopaque,
        kind: agent_link.Kind,
        correlation: u64,
        payload: []const u8,
    ) agent_link.channel.Flow {
        const self: *Discard = @ptrCast(@alignCast(context.?));
        _ = kind;
        _ = correlation;
        _ = payload;
        self.delivered += 1;
        return .ok;
    }
};

test "the normal end of the link is exit zero" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(Exit.link_closed));
}

test "every other outcome is distinguishable from the normal end" {
    const values = [_]Exit{
        .identity_refused,
        .protocol_violation,
        .transport_failed,
        .resource_unavailable,
        .exit_deadline,
    };
    for (values, 0..) |value, index| {
        try std.testing.expect(@intFromEnum(value) != 0);
        for (values[index + 1 ..]) |other|
            try std.testing.expect(@intFromEnum(value) != @intFromEnum(other));
    }
}
