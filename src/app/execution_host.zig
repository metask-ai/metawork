//! The UI half's view of the execution process: start it, agree on identity,
//! and get rid of it again.
//!
//! The child is this same executable, started with `mode_flag`. One binary
//! means the two halves cannot hold different ABI constants, a different
//! AgentCore manifest digest or a different frame protocol by construction,
//! and it leaves the installer and the macOS signature untouched. The identity
//! exchange is still mandatory, because the two skews that happen in practice
//! -- an upgrade that leaves the previous execution process running, and two
//! installs sharing one data directory -- produce a peer built from different
//! sources even though the file on disk is one binary.
//!
//! The link is a pair of anonymous pipes the child inherits. It is deliberately
//! not a socket and not a named pipe: credentials cross this channel, and an
//! inherited pipe has no name for anything else on the machine to connect to.
//! `stderr` is left alone so the child's crash text and logs still go where
//! they go today.
//!
//! What this module does not do: forward port calls. The vtables that do that,
//! and the Runtime that answers them, arrive with the step that moves the
//! Runtime. This is the process and the handshake, which everything else needs
//! first.

const builtin = @import("builtin");
const std = @import("std");

const agent_link = @import("metawork_agent_link");

pub const mode_flag = "--execution-host";

/// How long a graceful stop waits before the child is killed. Closing our
/// write end gives the child end-of-stream, which is its own exit signal, so
/// this bound is only reached by a child that is already wedged.
pub const stop_grace_ms: u64 = 5_000;

/// Serializes `std.process.spawn` on Windows the way the MCP stdio transport
/// does, because the inherited-handle window is process-wide. Two spawns at
/// once can leak each other's temporary child-side handles, which is the open
/// Windows handle-isolation gap the validation spec already records.
var windows_spawn_mutex: std.Io.Mutex = .init;

pub const StartFailure = union(enum) {
    /// The executable's own path could not be resolved, so there is nothing to
    /// start. Never guessed from `argv[0]`.
    executable_unknown,
    spawn_failed,
    /// The pipes were not created, which only happens if the spawn options and
    /// this code disagree.
    link_unavailable,
    /// The child answered, and its identity is not ours. The link is refused;
    /// nothing is negotiated.
    refused: agent_link.Failure,
    resource_unavailable,
};

pub const Stopped = union(enum) {
    /// The child exited on its own after end-of-stream, with this status.
    exited: u8,
    /// It did not exit within the grace period and was killed.
    killed,
    /// It had already gone when the stop ran.
    gone,
};

/// What ends the child, held apart from the `Child` the reaper owns.
///
/// On Windows a duplicate of the process handle, because a handle value is
/// only a name: the reaper's `wait` closes the child's copy, and a closed
/// value can name a different process by the time somebody uses it. A
/// duplicate is an independent reference, and while it is open the process
/// object -- and therefore the identity -- cannot be reused.
///
/// Elsewhere the pid, which is the only name there is. A pid is reusable once
/// the child has been reaped, so the one remaining window is a reap that lands
/// between the grace period expiring and the signal going out; closing it
/// would need a pidfd, which is Linux-only, and reaching it would need the
/// system to allocate the whole pid space between two adjacent instructions.
const Termination = switch (builtin.os.tag) {
    .windows => std.os.windows.HANDLE,
    else => std.posix.pid_t,
};

/// `DuplicateHandle`, which `std.os.windows` does not wrap.
extern "kernel32" fn DuplicateHandle(
    source_process: std.os.windows.HANDLE,
    source: std.os.windows.HANDLE,
    target_process: std.os.windows.HANDLE,
    target: *std.os.windows.HANDLE,
    desired_access: std.os.windows.DWORD,
    inherit: std.os.windows.BOOL,
    options: std.os.windows.DWORD,
) callconv(.winapi) std.os.windows.BOOL;

fn takeTermination(child: *const std.process.Child) ?Termination {
    const id = child.id orelse return null;
    if (builtin.os.tag != .windows) return id;
    var duplicate: std.os.windows.HANDLE = undefined;
    if (DuplicateHandle(
        std.os.windows.GetCurrentProcess(),
        id,
        std.os.windows.GetCurrentProcess(),
        &duplicate,
        0,
        .FALSE,
        std.os.windows.DUPLICATE_SAME_ACCESS,
    ) == .FALSE) return null;
    return duplicate;
}

fn releaseTermination(value: Termination) void {
    if (builtin.os.tag == .windows) std.os.windows.CloseHandle(value);
}

pub const Host = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    child: std.process.Child,
    /// Taken at spawn and released on the way out, so it outlives every
    /// reap. `termination_released` is what makes releasing it idempotent:
    /// a refused start ends in `abandon` and never sees a `deinit`, while an
    /// ordinary life ends in `deinit`, and neither knows about the other.
    termination: Termination,
    termination_released: bool = false,
    /// Our write end of the child's stdin.
    to_child: std.Io.File,
    /// Our read end of the child's stdout.
    from_child: std.Io.File,
    read_buffer: []u8,
    reader: std.Io.File.Reader,
    peer: agent_link.handshake.Record,
    outbound: agent_link.channel.Outbound,
    reaper: ?std.Thread = null,
    reaped: std.Io.Event = .unset,
    term: ?std.process.Child.Term = null,
    stopped: bool = false,
    /// The write end is already closed, and was closed without a goodbye.
    /// Only `TestSupport.abandonLink` sets it; `stop` reads it so that the
    /// close is not attempted twice on one handle.
    link_abandoned: bool = false,

    pub const StartError = std.mem.Allocator.Error;

    /// What to start. Production always starts this same executable, so the
    /// two halves cannot disagree about anything compiled in. A test needs a
    /// stand-in, because the application executable carries the Renderer
    /// bundle and a fixture does not.
    pub const Spawn = union(enum) {
        self,
        explicit: []const []const u8,
    };

    /// Starts the execution process and completes the identity exchange.
    /// Returns a failure rather than a half-built host: a refused identity is
    /// a final answer for this attempt.
    pub fn start(
        self: *Host,
        io: std.Io,
        allocator: std.mem.Allocator,
        identity: agent_link.Identity,
        queue_limits: agent_link.QueueLimits,
        spawn: Spawn,
    ) StartError!?StartFailure {
        var path_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
        var self_argv: [2][]const u8 = undefined;
        const argv: []const []const u8 = switch (spawn) {
            .self => blk: {
                const path_len = std.process.executablePath(io, &path_storage) catch
                    return .executable_unknown;
                self_argv = .{ path_storage[0..path_len], mode_flag };
                break :blk &self_argv;
            },
            .explicit => |values| values,
        };

        if (builtin.os.tag == .windows) windows_spawn_mutex.lockUncancelable(io);
        var child = std.process.spawn(io, .{
            .argv = argv,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .inherit,
            .create_no_window = true,
        }) catch {
            if (builtin.os.tag == .windows) windows_spawn_mutex.unlock(io);
            return .spawn_failed;
        };
        if (builtin.os.tag == .windows) windows_spawn_mutex.unlock(io);
        errdefer child.kill(io);

        // Before anything else can fail, because every failure below has to
        // be able to end this child, and `abandon` is what does it.
        //
        // A start that cannot arm this is refused rather than served: a host
        // whose stop cannot guarantee the child is gone would hand the caller
        // a link it cannot wind up, and on Windows the only way to fail here
        // is to be out of handles.
        const termination = takeTermination(&child) orelse return .resource_unavailable;
        errdefer releaseTermination(termination);

        const to_child = child.stdin orelse return .link_unavailable;
        const from_child = child.stdout orelse return .link_unavailable;
        child.stdin = null;
        child.stdout = null;

        const read_buffer = try allocator.alloc(u8, 64 * 1024);
        // A returned failure is not an error return, so `errdefer` would not
        // fire for it. Every failure below therefore releases through
        // `abandon`: a refused start must leave no running child, no open pipe
        // and nothing allocated, because the caller will try again.
        errdefer allocator.free(read_buffer);

        self.* = .{
            .io = io,
            .allocator = allocator,
            .child = child,
            .termination = termination,
            .to_child = to_child,
            .from_child = from_child,
            .read_buffer = read_buffer,
            .reader = undefined,
            .peer = undefined,
            .outbound = undefined,
        };
        self.reader = self.from_child.readerStreaming(io, self.read_buffer);

        const outcome = agent_link.exchangeIdentityDetailed(
            io,
            self.to_child,
            &self.reader.interface,
            .ui,
            identity,
        ) catch {
            self.abandon();
            return .{ .refused = .malformed_identity };
        };
        switch (outcome) {
            .failure => |failure| {
                self.abandon();
                return .{ .refused = failure };
            },
            .accepted => |record| self.peer = record,
        }

        self.outbound.start(io, allocator, self.to_child, queue_limits) catch {
            self.abandon();
            return .resource_unavailable;
        };
        self.reaper = std.Thread.spawn(.{}, reaperMain, .{self}) catch {
            self.outbound.stop();
            self.abandon();
            return .resource_unavailable;
        };
        return null;
    }

    /// Releases everything a failed start took: the child is killed and
    /// reaped, both pipe ends close, and the read buffer goes back. The host
    /// is left unusable on purpose, so a caller that ignores the failure
    /// trips an assertion rather than driving a dead link.
    fn abandon(self: *Host) void {
        // `Child.kill` is the whole of it here, and only here: this runs
        // before the reaper exists, so this thread is the single owner of the
        // child's corpse and its handles, which is exactly what that call
        // assumes. Once a reaper is running, `terminate` is the only way to
        // end the child -- see what that function says about why.
        //
        // Asserted rather than left to the reading. The other `Child.kill` is
        // the `errdefer` in `start`, which can only fire before the reaper is
        // assigned, and the only `wait` is the reaper's own.
        std.debug.assert(self.reaper == null);
        self.child.kill(self.io);
        self.releaseTerminationOnce();
        self.to_child.close(self.io);
        self.from_child.close(self.io);
        self.allocator.free(self.read_buffer);
        self.read_buffer = &.{};
        self.stopped = true;
    }

    /// Asks the operating system to end the child, and does nothing else.
    ///
    /// Not `std.process.Child.kill`, which terminates and then waits for the
    /// corpse and then closes the handles. All three of those belong to the
    /// reaper, and the reaper is inside `wait` whenever this is called:
    ///
    ///   * Two threads waiting on one child means one of them is told the
    ///     child is not theirs -- `ECHILD`, which `std.Io.Threaded` reports
    ///     through `errnoBug` and which panics outright in a Debug build.
    ///   * Two cleanups means one thread closes a handle the other is still
    ///     waiting on, and then clears fields the other is reading.
    ///   * The Windows kill path waits with no timeout, so a child that did
    ///     not die would hang the very stop the kill exists to bound.
    ///   * On POSIX the signal it sends is `SIGTERM`, which a wedged child may
    ///     be handling or ignoring -- and a wedged child is the only reason
    ///     this is ever reached.
    ///
    /// So one owner for the corpse and the handles, which is the reaper, and
    /// one job here: the signal. `reaperMain` collects what this ends, and
    /// `stop` joins it afterwards, which is what makes the child's death
    /// observable rather than assumed.
    fn terminate(self: *Host) void {
        switch (builtin.os.tag) {
            .windows => _ = std.os.windows.ntdll.NtTerminateProcess(
                self.termination,
                @enumFromInt(@as(u32, 1)),
            ),
            // `SIGKILL`, not `SIGTERM`: this is the path for a child that is
            // not responding to anything it could choose to ignore.
            else => std.posix.kill(self.termination, .KILL) catch {},
        }
    }

    fn reaperMain(self: *Host) void {
        self.term = self.child.wait(self.io) catch null;
        self.reaped.set(self.io);
    }

    /// Whoever else is reading this link, given the one window in which it
    /// can be wound down safely.
    ///
    /// Whoever else is reading this link, given the one window in which it
    /// can be wound down safely.
    ///
    /// That window is after the child has been reaped and before
    /// `from_child` is closed, and the ordering is the whole point. A reader
    /// thread on `from_child` ends when the child's output closes, which
    /// happens when the child exits -- so joining it *before* the grace wait
    /// would wait for a child that the kill below exists to deal with. A
    /// child wedged in a Run is precisely the case the kill is for, and
    /// joining first made it the one case that hung instead.
    ///
    /// After the reap the read has ended or is about to, and the handle it
    /// was blocked on is still open: closing that handle under a pending read
    /// is the other race, and doing this between the two removes both.
    pub const Quiesce = struct {
        context: ?*anyopaque,
        settle_fn: *const fn (?*anyopaque) void,
    };

    /// Stops accepting, lets the child see end-of-stream, and waits out the
    /// grace period before killing it. Killing is the bound, not the plan: a
    /// forced exit is what the design reserves for a wedged child.
    pub fn stop(self: *Host, quiesce: ?Quiesce) Stopped {
        if (self.stopped) return .gone;
        self.stopped = true;
        // Best effort: a child that has already gone makes this fail, and that
        // is not a reason to skip the reap below.
        //
        // An abandoned link has had all three of these done to it already,
        // minus the goodbye it deliberately never sent. Repeating the close
        // would be a second close of one handle; what is left for this to do
        // is the reap.
        if (!self.link_abandoned) {
            _ = self.outbound.trySubmit(.goodbye, 0, &.{}) catch {};
            self.outbound.stop();
            self.to_child.close(self.io);
        }

        const graceful = if (self.reaper == null) false else blk: {
            self.reaped.waitTimeout(self.io, .{ .duration = .{
                .raw = .fromMilliseconds(@intCast(stop_grace_ms)),
                .clock = .awake,
            } }) catch break :blk false;
            break :blk true;
        };
        // The signal only. The join below is what waits for the child to
        // actually be gone, because the reaper is the one holding the wait.
        if (!graceful) self.terminate();
        if (self.reaper) |thread| thread.join();
        self.reaper = null;
        if (quiesce) |settle| settle.settle_fn(settle.context);
        self.from_child.close(self.io);
        if (!graceful) return .killed;
        const term = self.term orelse return .gone;
        return switch (term) {
            .exited => |code| .{ .exited = code },
            else => .killed,
        };
    }

    fn releaseTerminationOnce(self: *Host) void {
        if (self.termination_released) return;
        self.termination_released = true;
        releaseTermination(self.termination);
    }

    pub fn deinit(self: *Host) void {
        if (!self.stopped) _ = self.stop(null);
        // After the stop, which is after the reaper has been joined: the
        // reference has to stay valid for as long as anything could still
        // need to end this child.
        self.releaseTerminationOnce();
        self.allocator.free(self.read_buffer);
        self.* = undefined;
    }
};

/// Ending a link the way a dead UI ends it.
///
/// Not in a release build: nothing in the product closes a link without a
/// goodbye on purpose, and a stop that skipped its own goodbye would be a
/// child killed for no reason.
pub const TestSupport = if (builtin.is_test) struct {
    /// Closes the write end with no goodbye and leaves the child running.
    ///
    /// That is the state this half's isolation exists for, and the only way
    /// to reach it from a test: the execution process sees end-of-stream
    /// with no warning, while still holding every Session, Run and reference
    /// the link gave it, and nobody is left to take any of them back. What
    /// the test then asks is whether it exits on its own.
    pub fn abandonLink(host: *Host) void {
        if (host.link_abandoned) return;
        host.link_abandoned = true;
        host.outbound.stop();
        host.to_child.close(host.io);
    }

    /// Ends the execution process where it stands.
    ///
    /// The failure this whole half exists for, and a different one from
    /// `abandonLink`: there the child lives on and decides to go, while here
    /// it is simply gone. Everything the caller is holding -- Sessions, Runs,
    /// a worker waiting inside `execute` -- was valid a moment ago and names
    /// nothing now, and the caller finds out by reading end-of-stream.
    pub fn killChild(host: *Host) void {
        host.terminate();
    }
} else struct {};

/// Whether this process was started as the execution half. Read from the real
/// argument vector: the mode is never inferred from an environment variable,
/// so a stray environment cannot turn a user's launch into a headless process.
pub fn requested(args: std.process.Args, gpa: std.mem.Allocator) bool {
    var iterator = std.process.Args.Iterator.initAllocator(args, gpa) catch return false;
    defer iterator.deinit();
    _ = iterator.next(); // argv[0]
    while (iterator.next()) |argument| {
        if (std.mem.eql(u8, argument, mode_flag)) return true;
    }
    return false;
}

test "the mode flag is the only thing that selects the execution half" {
    try std.testing.expectEqualStrings("--execution-host", mode_flag);
}

test "a graceful stop is bounded rather than open-ended" {
    // The bound exists so a wedged child cannot hold the UI's exit. It is a
    // product choice with no frequency data behind it, which is why it is one
    // named constant rather than a number spread through the code.
    try std.testing.expect(stop_grace_ms > 0);
    try std.testing.expect(stop_grace_ms <= 30_000);
}
