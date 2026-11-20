//! Stands in for the execution half of a split process.
//!
//! The real execution half is the application executable started with its mode
//! flag, and that executable carries the Renderer bundle. A test must not need
//! the bundle to check that the process starts, agrees on identity and stops,
//! so this fixture runs the same `execution_mode.run` the application forks
//! into, over the same inherited pipes.
//!
//! `METAWORK_EXEC_LINK_VERSION` overrides the version this half states, which
//! is how the test produces the skew that actually happens in the field: a
//! peer built from different sources.
//!
//! Flags:
//!
//!   * `--ignore-eof` -- a child that does not leave when its link ends, the
//!     wedged child a stop's grace period exists for.
//!   * `--with-runtime` -- serve the link with `execution_server` and an
//!     Agent Runtime over the lifecycle fixture's fake Core, which is what the
//!     application does with the real one.
//!   * `--hold-runs` -- every Session's Runs report that they are executing
//!     tools and then wait until they are aborted.
//!   * `--hang-shutdown` -- the Runtime's shutdown never returns, so only the
//!     exit deadline can end the process.
//!   * `--session-id-floor=<n>` -- as the application passes it.

const std = @import("std");

const execution_mode = @import("app_execution_mode");
const execution_server = @import("app_execution_server");
const agent_link = @import("metawork_agent_link");
const lifecycle_fixture = @import("lifecycle_fixture");

const agent = lifecycle_fixture.lifecycle;

pub const ignore_eof_flag = "--ignore-eof";
pub const with_runtime_flag = "--with-runtime";
pub const hold_runs_flag = "--hold-runs";
pub const hang_shutdown_flag = "--hang-shutdown";
pub const session_floor_flag = "--session-id-floor=";

const Flags = struct {
    ignore_eof: bool = false,
    with_runtime: bool = false,
    hold_runs: bool = false,
    hang_shutdown: bool = false,
    session_id_floor: u64 = 0,
};

fn readFlags(init: std.process.Init) Flags {
    var flags: Flags = .{};
    var iterator = std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa) catch return flags;
    defer iterator.deinit();
    _ = iterator.next();
    while (iterator.next()) |argument| {
        if (std.mem.eql(u8, argument, ignore_eof_flag)) flags.ignore_eof = true;
        if (std.mem.eql(u8, argument, with_runtime_flag)) flags.with_runtime = true;
        if (std.mem.eql(u8, argument, hold_runs_flag)) flags.hold_runs = true;
        if (std.mem.eql(u8, argument, hang_shutdown_flag)) flags.hang_shutdown = true;
        if (std.mem.startsWith(u8, argument, session_floor_flag))
            flags.session_id_floor = std.fmt.parseInt(u64, argument[session_floor_flag.len..], 10) catch 0;
    }
    return flags;
}

pub const message_limits: agent_link.MessageLimits = .{
    .event = 1 << 20,
    .request = 1 << 20,
    .response = 1 << 20,
    .ui_request = 1 << 16,
    .ui_response = 1 << 16,
};

/// The fake Core's Runtime, made the way the application makes the real one.
const FakeRuntime = struct {
    flags: Flags,
    runtime: ?*agent.Runtime = null,

    fn factory(self: *FakeRuntime) execution_server.Factory {
        return .{ .context = self, .create_fn = create };
    }

    fn create(context: ?*anyopaque, notifier: agent.EventReadyNotifier) ?execution_server.Runtime {
        const self: *FakeRuntime = @ptrCast(@alignCast(context.?));
        if (self.flags.hold_runs) lifecycle_fixture.fake_core.setNextPlan(.controlled_executing_tools);
        const runtime = lifecycle_fixture.createTestRuntime(.{
            .max_sessions = 8,
            .event_ready_notifier = notifier,
            .session_id_floor = self.flags.session_id_floor,
        }) catch return null;
        self.runtime = runtime;
        return .{ .port = runtime.runtimePort(), .context = self, .shutdown_fn = shutdown };
    }

    fn shutdown(context: ?*anyopaque) void {
        const self: *FakeRuntime = @ptrCast(@alignCast(context.?));
        if (self.flags.hang_shutdown) {
            var never: std.Io.Event = .unset;
            never.waitUncancelable(lifecycle_fixture.fixtureIo());
        }
        self.runtime.?.shutdown() catch {};
    }
};

pub fn main(init: std.process.Init) !void {
    const flags = readFlags(init);
    const version = init.environ_map.get("METAWORK_EXEC_LINK_VERSION") orelse "fixture-0";
    const digest_text = init.environ_map.get("METAWORK_EXEC_LINK_DIGEST") orelse "11";
    var digest: [32]u8 = @splat(0);
    @memset(&digest, digest_text[0]);

    lifecycle_fixture.use(std.heap.c_allocator, init.io);
    var fake: FakeRuntime = .{ .flags = flags };
    const server_options: execution_server.Options = .{ .factory = fake.factory() };

    const exit = execution_mode.run(init.io, std.heap.c_allocator, .{
        .identity = .{
            .version = version,
            .core_manifest_sha256 = digest,
            .core_abi_revision = 28,
        },
        .message_limits = message_limits,
        .queue_limits = .{},
        .server = if (flags.with_runtime) execution_server.server(&server_options) else null,
    });
    if (flags.ignore_eof) while (true) {
        std.Io.sleep(init.io, .fromSeconds(1), .awake) catch {};
    };
    if (flags.with_runtime) execution_server.hardExit(@intFromEnum(exit));
    std.process.exit(@intFromEnum(exit));
}

comptime {
    // The fixture must not drift from the entry it stands in for.
    std.debug.assert(@TypeOf(execution_mode.run) == fn (
        std.Io,
        std.mem.Allocator,
        execution_mode.Options,
    ) execution_mode.Exit);
    std.debug.assert(agent_link.revision > 0);
}
