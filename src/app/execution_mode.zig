//! The execution half's entry point.
//!
//! This runs instead of the application, not inside it. It is reached before
//! the Native SDK runner is entered and before any window exists, which is the
//! whole reason the fork sits at the top of `app.run`: a process that gets as
//! far as `runWithOptions` has a WebView, and the execution half must never
//! have one.
//!
//! What it owns is the transport and nothing else: state its identity, accept
//! the peer's, then serve frames until the UI closes the pipe. What *answers*
//! those frames is the caller's -- `execution_half.zig` composes it -- because
//! answering needs an Agent Runtime and this file must stay importable by a
//! fixture that has none.
//!
//! It composes no Product owner, opens no database, reads no Workspace and
//! creates no window. Everything it will own arrives explicitly.

const std = @import("std");

const agent_link = @import("metawork_agent_link");
const exit_deadline = @import("exit_deadline.zig");

/// `exit_deadline.default_ms`, re-stated here because this is the module
/// that owns the file: a caller composing these options -- the half above,
/// or a fixture standing in for it -- cannot import a file that belongs to
/// this module, and should not have to name the number itself.
pub const exit_deadline_default_ms = exit_deadline.default_ms;

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
    /// The link ended, and the teardown after it did not finish inside
    /// `exit_deadline` -- so the process went without finishing it.
    ///
    /// Its own code and not the link's, because they are different facts and
    /// only one of them is a defect. A half that cannot finish tidying up is
    /// holding something nobody will ever take back, and the reason the
    /// deadline exists at all is that such a thing is otherwise invisible:
    /// reported as a normal end, the next leak of the kind that caused this
    /// one would show up in the field as "exits two seconds late" and nothing
    /// else. It is not a crash code either -- the process did decide to go.
    cleanup_deadline = 14,
};

/// Who answers the frames this file reads.
///
/// Two calls rather than one sink, because a sink that answers has to know
/// the queue it answers on, and that queue only exists once the identity
/// exchange has succeeded. `end` is called after the read loop returns and
/// before the queue stops, which is the only point at which "no further
/// request will arrive" and "a response can still be written" are both true.
pub const Answering = struct {
    context: ?*anyopaque,
    begin_fn: *const fn (?*anyopaque, std.Io, *agent_link.channel.Outbound) ?agent_link.channel.Sink,
    end_fn: *const fn (?*anyopaque) void,
};

pub const Options = struct {
    identity: agent_link.Identity,
    message_limits: agent_link.MessageLimits,
    queue_limits: agent_link.QueueLimits = .{},
    read_buffer_bytes: usize = 64 * 1024,
    /// `null` drops every request and counts what it dropped. That is what a
    /// caller with no Runtime composed can honestly do, and the identity
    /// tests are exactly that caller.
    answering: ?Answering = null,
    /// How long everything after the link ends gets, in milliseconds.
    ///
    /// The bound is on the exit as a whole rather than on any wait inside it,
    /// for the reason `exit_deadline` is written to hold: the waits that hang
    /// a teardown are the ones nobody listed. Zero disarms it, which is only
    /// ever what a test asking to see the unbounded behaviour passes.
    exit_deadline_ms: u64 = exit_deadline.default_ms,
};

/// Arms the deadline on everything that happens after this, and reports the
/// exit it was given.
///
/// Every return from `run` goes through here, not just the one after the read
/// loop. The caller composes what answers the link *before* entering this --
/// `execution_half` has an Agent Runtime built by then -- so a refused
/// identity returns into a teardown that destroys a Runtime, as unbounded as
/// any other. The only returns with nothing behind them are the two before
/// the read buffer exists, and arming for those costs a thread that the
/// process outlives by microseconds.
fn armed(io: std.Io, options: Options, exit: Exit) Exit {
    exit_deadline.arm(
        io,
        options.exit_deadline_ms,
        @intFromEnum(Exit.cleanup_deadline),
    );
    return exit;
}

/// Serves the link until it ends, and returns the exit code to use.
pub fn run(
    io: std.Io,
    allocator: std.mem.Allocator,
    options: Options,
) Exit {
    const input = std.Io.File.stdin();
    const output = std.Io.File.stdout();

    const read_buffer = allocator.alloc(u8, options.read_buffer_bytes) catch
        return armed(io, options, .resource_unavailable);
    defer allocator.free(read_buffer);
    var reader = input.readerStreaming(io, read_buffer);

    const outcome = agent_link.exchangeIdentityDetailed(
        io,
        output,
        &reader.interface,
        .exec,
        options.identity,
    ) catch return armed(io, options, .identity_refused);
    switch (outcome) {
        .failure => |failure| return armed(io, options, switch (failure) {
            .transport_failed => .transport_failed,
            else => .identity_refused,
        }),
        .accepted => {},
    }

    var outbound: agent_link.channel.Outbound = undefined;
    outbound.start(io, allocator, output, options.queue_limits) catch
        return armed(io, options, .resource_unavailable);
    defer outbound.stop();

    var discard: Discard = .{};
    const sink = if (options.answering) |answering|
        answering.begin_fn(answering.context, io, &outbound) orelse
            return armed(io, options, .resource_unavailable)
    else
        discard.sink();
    defer if (options.answering) |answering| answering.end_fn(answering.context);

    var inbound: agent_link.channel.Inbound = undefined;
    inbound.init(
        io,
        allocator,
        &reader.interface,
        options.message_limits,
        sink,
    ) catch return armed(io, options, .resource_unavailable);
    defer inbound.deinit();

    // The link is over. Every `defer` below it, and the caller's own teardown
    // after this returns, is this process tidying up after a caller that is
    // not listening -- including the join in `end_fn`, which waits for a
    // worker inside `execute` that only its own Run can release. One bound
    // over all of it, armed here because this is the first line that knows
    // the link has ended and the last one before the waiting starts.
    return armed(io, options, switch (inbound.run()) {
        .peer_closed, .consumer_stopped => .link_closed,
        .read_failed => .transport_failed,
        .violation => .protocol_violation,
    });
}

/// For a caller that composed nothing to answer with. Dropping a message is
/// not something a later step may inherit silently, so this counts what it
/// dropped rather than looking like a working link.
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
    };
    for (values, 0..) |value, index| {
        try std.testing.expect(@intFromEnum(value) != 0);
        for (values[index + 1 ..]) |other|
            try std.testing.expect(@intFromEnum(value) != @intFromEnum(other));
    }
}
