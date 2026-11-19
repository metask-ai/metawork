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

pub const Host = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    child: std.process.Child,
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
        self.child.kill(self.io);
        self.to_child.close(self.io);
        self.from_child.close(self.io);
        self.allocator.free(self.read_buffer);
        self.read_buffer = &.{};
        self.stopped = true;
    }

    fn reaperMain(self: *Host) void {
        self.term = self.child.wait(self.io) catch null;
        self.reaped.set(self.io);
    }

    /// Whoever else is reading this link, given the one window in which it
    /// can be wound down safely.
    ///
    /// A reader thread on `from_child` ends when the child's output closes,
    /// and the child's output closes because its input did. So the window is
    /// after `to_child` is closed and before `from_child` is: the read is
    /// about to end on its own, and the handle it is blocked on is still
    /// open. Closing that handle under a pending read is the race this
    /// exists to remove.
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
        _ = self.outbound.trySubmit(.goodbye, 0, &.{}) catch {};
        self.outbound.stop();
        self.to_child.close(self.io);
        if (quiesce) |settle| settle.settle_fn(settle.context);

        const graceful = if (self.reaper == null) false else blk: {
            self.reaped.waitTimeout(self.io, .{ .duration = .{
                .raw = .fromMilliseconds(@intCast(stop_grace_ms)),
                .clock = .awake,
            } }) catch break :blk false;
            break :blk true;
        };
        if (!graceful) self.child.kill(self.io);
        if (self.reaper) |thread| thread.join();
        self.reaper = null;
        self.from_child.close(self.io);
        if (!graceful) return .killed;
        const term = self.term orelse return .gone;
        return switch (term) {
            .exited => |code| .{ .exited = code },
            else => .killed,
        };
    }

    pub fn deinit(self: *Host) void {
        if (!self.stopped) _ = self.stop(null);
        self.allocator.free(self.read_buffer);
        self.* = undefined;
    }
};

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
