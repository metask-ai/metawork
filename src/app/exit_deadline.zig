//! The bound on everything a half does after its link ends.
//!
//! Once the link is gone this process has no caller. Nothing it still holds
//! is owed to anybody, nothing it could still write would be read, and the
//! only thing left that anyone can observe is whether it exits -- the UI half
//! waits out a grace period for exactly that and kills the process when the
//! grace runs out, which is the only form of this a user ever sees.
//!
//! So the bound goes here, once, around the whole of the exit rather than
//! around each wait inside it. A deadline per wait point bounds only the
//! waits somebody thought of, and the wait that hung this half the first time
//! a real caller died on it was four frames below the join it would have been
//! added to: AgentCore's own `Session.close`, waiting out a reference count
//! that a dead caller had moved. The next one nobody has found yet would not
//! have been covered either.
//!
//! Cleanup is therefore best effort *inside* the deadline. If it finishes,
//! the process exits by returning and this thread goes with it, which is the
//! ordinary case and the one worth keeping quick; if it does not, this exits
//! anyway, with the code the link's end already decided.
//!
//! This is the one place outside `main` that ends the process, and the reason
//! is the reason it has to exist: a process that cannot be sure its cleanup
//! returns cannot exit by returning.

const std = @import("std");

/// How long cleanup gets after the link ends, by default.
///
/// Well inside the UI half's `stop_grace_ms`, because the two bounds are for
/// different things and the inner one has to win: this one is the process
/// deciding to go, and the grace period is the UI giving up on it. A process
/// that exits on this deadline is still a `.exited` to the half that stopped
/// it, which is what keeps a slow cleanup out of the kill path.
pub const default_ms: u64 = 2_000;

/// Ends this process `after` milliseconds from now, whatever else is running.
///
/// An `after` of zero arms nothing. That is what a test asking for the
/// unbounded behaviour back passes, and it is the only way to tell that the
/// deadline is what ended the process rather than cleanup having finished.
///
/// A thread that cannot be spawned is a warning and not a refusal: this is a
/// backstop, and a half that would not serve a link because its backstop
/// could not be armed turns the backstop into the outage it exists for.
pub fn arm(io: std.Io, after: u64, code: u8) void {
    if (after == 0) return;
    const thread = std.Thread.spawn(.{}, main, .{ io, after, code }) catch |failure| {
        std.log.warn("exit deadline unavailable: {s}", .{@errorName(failure)});
        return;
    };
    // Nobody joins it: either it ends the process or the process ends first,
    // and both of those are the end of it.
    thread.detach();
}

fn main(io: std.Io, after: u64, code: u8) void {
    // An event nobody sets, which is how `Host.stop` waits out its own grace
    // period: a sleep with no busy loop.
    var never: std.Io.Event = .unset;
    never.waitTimeout(io, .{ .duration = .{
        .raw = .fromMilliseconds(@intCast(after)),
        .clock = .awake,
    } }) catch {};
    std.log.warn(
        "exiting on the deadline with cleanup unfinished after the link ended",
        .{},
    );
    std.process.exit(code);
}
