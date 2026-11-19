//! Stands in for the execution half of a split process.
//!
//! The real execution half is the application executable started with its mode
//! flag, and that executable carries the Renderer bundle. A test must not need
//! the bundle to check that the process starts, agrees on identity and stops,
//! so this fixture composes the same `execution_half.run` the application
//! forks into, over the same inherited pipes.
//!
//! `METAWORK_EXEC_LINK_VERSION` overrides the version this half states, which
//! is how the test produces the skew that actually happens in the field: a
//! peer built from different sources. `METAWORK_EXEC_LINK_FAULT_ROOT` gives it
//! a data root to record a process-level fault under; the application resolves
//! that root from the environment instead, which is a fact about the
//! installation rather than something this half should go looking for.
//!
//! `--with-runtime` composes an Agent Runtime over the AgentCore the
//! executable links, which is what lets a test drive a real port call across
//! a real process. It is an argument rather than an environment variable so
//! one test can ask for it and another can refuse it: the identity tests want
//! a half that composes nothing, and they must not pay for a Runtime to find
//! out that the peer is not this build.
//!
//! The AgentCore is the real one rather than a stand-in. The lifecycle
//! fixture's stand-in is written against `std.testing`, which does not compile
//! into an executable, and the archive is statically linked here anyway -- so
//! the real one is both available and the more faithful half.

const std = @import("std");

const agent = @import("metawork_agent");
const execution_half = @import("app_execution_half");
const agent_link = @import("metawork_agent_link");

pub const runtime_flag = "--with-runtime";

/// Stays alive after the link ends, which is the one condition the UI half's
/// kill exists for: a child that has been told to stop and does not stop. The
/// real shape of it is a worker inside `run.execute`, which returns only when
/// its Run reaches a terminal; this reproduces the *observable* part of that
/// without needing a Run, so the stop path can be driven at all.
pub const wedge_flag = "--wedge-on-stop";

/// Longer than the UI half's grace period by enough that a stop which waited
/// for this child would be a hang rather than a slow test.
const wedge_ms: u64 = 120_000;

const Composer = struct {
    io: std.Io,
    allocator: std.mem.Allocator,

    fn factory(self: *Composer) execution_half.RuntimeFactory {
        return .{ .context = self, .create_fn = create, .destroy_fn = destroy };
    }

    fn create(context: ?*anyopaque, notifier: agent.EventReadyNotifier) ?*agent.Runtime {
        const self: *Composer = @ptrCast(@alignCast(context.?));
        return agent.Runtime.init(
            self.io,
            self.allocator,
            .{ .max_sessions = 2, .event_ready_notifier = notifier },
        ) catch null;
    }

    fn destroy(_: ?*anyopaque, runtime: *agent.Runtime) void {
        runtime.shutdown() catch {};
        runtime.deinit();
    }
};

fn requested(args: std.process.Args, gpa: std.mem.Allocator, flag: []const u8) bool {
    var iterator = std.process.Args.Iterator.initAllocator(args, gpa) catch return false;
    defer iterator.deinit();
    _ = iterator.next(); // argv[0]
    while (iterator.next()) |argument| {
        if (std.mem.eql(u8, argument, flag)) return true;
    }
    return false;
}

pub fn main(init: std.process.Init) !void {
    const version = init.environ_map.get("METAWORK_EXEC_LINK_VERSION") orelse "fixture-0";
    const digest_text = init.environ_map.get("METAWORK_EXEC_LINK_DIGEST") orelse "11";
    var digest: [32]u8 = @splat(0);
    @memset(&digest, digest_text[0]);

    var composer: Composer = .{ .io = init.io, .allocator = init.gpa };
    const exit = execution_half.run(init.io, init.gpa, .{
        .identity = .{
            .version = version,
            .core_manifest_sha256 = digest,
            .core_abi_revision = 28,
        },
        .message_limits = .{
            .event = 1 << 20,
            .request = 1 << 20,
            .response = 1 << 20,
            .ui_request = 1 << 16,
            .ui_response = 1 << 16,
        },
        .queue_limits = .{},
        .fault = if (init.environ_map.get("METAWORK_EXEC_LINK_FAULT_ROOT")) |root| .{
            .identity = .{
                .version = version,
                .artifact_kind = .development,
                .core_manifest_sha256 = digest,
                .core_abi_revision = 28,
            },
            .data_root = root,
        } else null,
        .runtime = if (requested(init.minimal.args, init.gpa, runtime_flag))
            composer.factory()
        else
            null,
        .tables = .{ .sessions = 2, .runs = 2 },
    });
    if (requested(init.minimal.args, init.gpa, wedge_flag)) {
        // The same wait `Host.stop` uses for its own grace period, for the
        // same reason: an event nobody sets is a sleep with no busy loop.
        var never: std.Io.Event = .unset;
        never.waitTimeout(init.io, .{ .duration = .{
            .raw = .fromMilliseconds(wedge_ms),
            .clock = .awake,
        } }) catch {};
    }
    std.process.exit(@intFromEnum(exit));
}

comptime {
    // The fixture must not drift from the entry it stands in for.
    std.debug.assert(@TypeOf(execution_half.run) == fn (
        std.Io,
        std.mem.Allocator,
        execution_half.Options,
    ) execution_half.Exit);
    std.debug.assert(agent_link.revision > 0);
}
