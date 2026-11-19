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
//! `--fake-core` builds that Runtime over the lifecycle fixture's AgentCore
//! stand-in instead of the real archive, which is what lets a Run cross the
//! process at all: the real AgentCore refuses synthetic Session options, and a
//! test cannot supply real ones. The stand-in used to be impossible to link
//! here -- it reached for `std.testing` directly -- and is now parameterised
//! on an allocator and an `Io`, which is one fake used in two places rather
//! than a second one written for this side.
//!
//! Without the flag the Runtime is the real archive. Both are worth having:
//! the real one is what shows a refusal coming back as the method's own error,
//! and the stand-in is what shows a Run.

const std = @import("std");

const agent = @import("metawork_agent");
const execution_half = @import("app_execution_half");
const agent_link = @import("metawork_agent_link");
const fake = @import("lifecycle_fixture");

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

pub const fake_core_flag = "--fake-core";

/// Serves events only through the flush that precedes every response, which
/// is what *orders* them against the terminal that follows. With the drain
/// thread also running it wins the race in practice, so the ordering rule is
/// not observable; without it, an event that arrives at all arrived because
/// of the flush.
pub const no_drain_flag = "--no-event-drain";

/// Holds every Run until something stops it, with one pool thread.
///
/// Both halves of what makes the thread split observable. The Run is held, so
/// a `.worker` request is genuinely outstanding; and the pool has exactly one
/// thread, so under a single shared pool that one request would occupy all of
/// it and the Stop meant to end it could never be answered. With the split,
/// the blocking request is on a thread of its own and the pool is free.
pub const hold_runs_flag = "--hold-runs";

const Composer = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    fake_core: bool,
    hold_runs: bool,

    fn factory(self: *Composer) execution_half.RuntimeFactory {
        return .{ .context = self, .create_fn = create, .destroy_fn = destroy };
    }

    fn create(context: ?*anyopaque, notifier: agent.EventReadyNotifier) ?*agent.Runtime {
        const self: *Composer = @ptrCast(@alignCast(context.?));
        const limits: agent.Limits = .{ .max_sessions = 2, .event_ready_notifier = notifier };
        if (!self.fake_core)
            return agent.Runtime.init(self.io, self.allocator, limits) catch null;

        // The stand-in's own allocations and waits, before anything reaches
        // it. A test build gets these from `std.testing`; this one has to say.
        fake.use(self.allocator, self.io);
        // One event before the terminal, which is what makes the ordering
        // rule observable from the other side: a terminal that arrived first
        // would read as a complete conversation with nothing in it.
        fake.fake_core.setNextPlan(if (self.hold_runs) .controlled else .event_callback);
        // A held Run has to *say* it started, or the other half cannot tell
        // "the request is outstanding" from "the far side is inside it" --
        // and only the second one is the condition a Stop has to survive.
        // This makes the fake emit a `run_state` the moment the Run begins.
        if (self.hold_runs) fake.fake_core.input_enabled = true;
        return agent.Runtime.initWithApi(
            self.io,
            self.allocator,
            &fake.fake_api,
            limits,
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

    var composer: Composer = .{
        .io = init.io,
        .allocator = init.gpa,
        .fake_core = requested(init.minimal.args, init.gpa, fake_core_flag),
        .hold_runs = requested(init.minimal.args, init.gpa, hold_runs_flag),
    };
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
        .drain_events = !requested(init.minimal.args, init.gpa, no_drain_flag),
        .workers = if (requested(init.minimal.args, init.gpa, hold_runs_flag)) 1 else 4,
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
