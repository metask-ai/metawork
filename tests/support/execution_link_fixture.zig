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
//!   * `--hold-runs` -- in the first process only (floor zero), the first
//!     Session's Run reports that it is executing tools and then waits until
//!     it is aborted.
//!   * `--text-events` -- the first Session's Run streams a text event.
//!   * `--slow-events` -- the execution half waits before sending each event,
//!     so a terminal that did not wait for its events would overtake them.
//!   * `--checkpoint-bytes=<n>` -- the fake Core exports `n` patterned bytes.
//!   * `--large-messages` -- request and response limits of 4 MiB.
//!   * `--hang-shutdown` -- the Runtime's shutdown never returns, so only the
//!     exit deadline can end the process.
//!   * `--session-id-floor=<n>` -- as the application passes it.
//!   * `--no-runtime` -- the Agent Runtime cannot be created, so the process
//!     ends right after agreeing on identity, every time it is started.
//!   * `--exercise-mcp` -- before applying an MCP configuration, drive each
//!     member's transport the way AgentCore drives a connector: open, an
//!     exchange whose answer is echoed back, one carrying a secret, one its
//!     caller withdraws, a notification, close. What this half saw is
//!     reported in further exchanges, so the UI half can check both sides.

const std = @import("std");

const execution_mode = @import("app_execution_mode");
const execution_server = @import("app_execution_server");
const agent_link = @import("metawork_agent_link");
const lifecycle_fixture = @import("lifecycle_fixture");

const agent = lifecycle_fixture.lifecycle;

pub const ignore_eof_flag = "--ignore-eof";
pub const with_runtime_flag = "--with-runtime";
pub const hold_runs_flag = "--hold-runs";
pub const text_events_flag = "--text-events";
pub const slow_events_flag = "--slow-events";
pub const checkpoint_bytes_flag = "--checkpoint-bytes=";
pub const large_messages_flag = "--large-messages";
pub const hang_shutdown_flag = "--hang-shutdown";
pub const session_floor_flag = "--session-id-floor=";
pub const exercise_mcp_flag = "--exercise-mcp";
pub const no_runtime_flag = "--no-runtime";

const Flags = struct {
    ignore_eof: bool = false,
    with_runtime: bool = false,
    hold_runs: bool = false,
    text_events: bool = false,
    slow_events: bool = false,
    checkpoint_bytes: ?usize = null,
    large_messages: bool = false,
    hang_shutdown: bool = false,
    exercise_mcp: bool = false,
    no_runtime: bool = false,
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
        if (std.mem.eql(u8, argument, text_events_flag)) flags.text_events = true;
        if (std.mem.eql(u8, argument, slow_events_flag)) flags.slow_events = true;
        if (std.mem.eql(u8, argument, large_messages_flag)) flags.large_messages = true;
        if (std.mem.eql(u8, argument, hang_shutdown_flag)) flags.hang_shutdown = true;
        if (std.mem.eql(u8, argument, exercise_mcp_flag)) flags.exercise_mcp = true;
        if (std.mem.eql(u8, argument, no_runtime_flag)) flags.no_runtime = true;
        if (std.mem.startsWith(u8, argument, checkpoint_bytes_flag))
            flags.checkpoint_bytes = std.fmt.parseInt(usize, argument[checkpoint_bytes_flag.len..], 10) catch null;
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

pub const large_message_limits: agent_link.MessageLimits = .{
    .event = 1 << 20,
    .request = 4 << 20,
    .response = 4 << 20,
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
        if (self.flags.no_runtime) return null;
        if (self.flags.hold_runs and self.flags.session_id_floor == 0)
            lifecycle_fixture.fake_core.setNextPlan(.controlled_executing_tools);
        if (self.flags.text_events) {
            // Two events per Run: the `run_state` the input gate reports
            // when the Run starts, then the text.
            lifecycle_fixture.fake_core.setNextPlan(.event_callback);
            lifecycle_fixture.fake_core.input_enabled = true;
        }
        // Generation zero names no checkpoint to Product; the in-process tests
        // set one the same way.
        lifecycle_fixture.fake_core.setCheckpointGeneration(1);
        if (self.flags.checkpoint_bytes) |count| {
            const bytes = std.heap.c_allocator.alloc(u8, count) catch return null;
            for (bytes, 0..) |*byte, index| byte.* = @truncate(index % 251);
            lifecycle_fixture.fake_core.checkpoint_payload = bytes;
        }
        const runtime = lifecycle_fixture.createTestRuntime(.{
            .max_sessions = 8,
            .event_ready_notifier = notifier,
            .session_id_floor = self.flags.session_id_floor,
        }) catch return null;
        self.runtime = runtime;
        var runtime_port = runtime.runtimePort();
        if (self.flags.exercise_mcp) {
            exercising_vtable = runtime_port.vtable.*;
            exercising_vtable.apply_mcp_configuration = applyExercised;
            runtime_port.vtable = &exercising_vtable;
        }
        return .{ .port = runtime_port, .context = self, .shutdown_fn = shutdown };
    }

    var exercising_vtable: agent.RuntimePort.VTable = undefined;

    fn applyExercised(context: ?*anyopaque, input: *agent.McpRuntimeInput) (agent.Error || std.mem.Allocator.Error)!agent.McpConfigurationApplyOutcome {
        const runtime: *agent.Runtime = @ptrCast(@alignCast(context.?));
        for (input.members()) |member| exercise(member.transport());
        return runtime.applyMcpConfiguration(input);
    }

    fn exercise(transport: agent.McpTransport) void {
        const allocator = std.heap.c_allocator;
        const connection = switch (transport.open_fn(transport.context, .actual, .modern_2026_07_28, 1_000)) {
            .connection => |value| value,
            .failure => return,
        };
        defer transport.close_fn(connection);
        var echo_storage: [256]u8 = undefined;
        const echo = switch (transport.request_fn(connection, allocator, "first", 1_000, .{})) {
            .response => |response| echo: {
                defer if (response.body.len != 0) allocator.free(response.body);
                break :echo std.fmt.bufPrint(&echo_storage, "echo:{d}:{s}", .{ response.http_status, response.body }) catch "echo:overflow";
            },
            .failure => |failure| std.fmt.bufPrint(&echo_storage, "echo:failed:{s}", .{@tagName(failure)}) catch "echo:overflow",
        };
        report(transport, connection, echo);
        // The UI half scans for the secrets it configured; this half never
        // had them.
        reportOutcome(transport, connection, "secret", transport.request_fn(connection, allocator, "leak hunter2", 1_000, .{}));
        // Withdrawn by its caller from the start; the transport there sees it
        // and gives up.
        const withdrawn: agent.McpCancellation = .{ .is_cancelled_fn = always };
        reportOutcome(transport, connection, "withdrawn", (transport.tool_request_fn orelse transport.request_fn)(connection, allocator, "withdrawn", 60_000, withdrawn));
        _ = transport.notify_fn(connection, "notified", 1_000, .{});
    }

    fn always(_: ?*const anyopaque) bool {
        return true;
    }

    fn reportOutcome(transport: agent.McpTransport, connection: *anyopaque, label: []const u8, outcome: agent.McpExchangeOutcome) void {
        var storage: [128]u8 = undefined;
        const text = switch (outcome) {
            .response => |response| text: {
                if (response.body.len != 0) std.heap.c_allocator.free(response.body);
                break :text std.fmt.bufPrint(&storage, "{s}:answered", .{label}) catch return;
            },
            .failure => |failure| std.fmt.bufPrint(&storage, "{s}:{s}", .{ label, @tagName(failure) }) catch return,
        };
        report(transport, connection, text);
    }

    fn report(transport: agent.McpTransport, connection: *anyopaque, text: []const u8) void {
        switch (transport.request_fn(connection, std.heap.c_allocator, text, 1_000, .{})) {
            .response => |response| if (response.body.len != 0) std.heap.c_allocator.free(response.body),
            .failure => {},
        }
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
    const server_options: execution_server.Options = .{
        .factory = fake.factory(),
        .event_delay_ms = if (flags.slow_events) 200 else 0,
    };

    const exit = execution_mode.run(init.io, std.heap.c_allocator, .{
        .identity = .{
            .version = version,
            .core_manifest_sha256 = digest,
            .core_abi_revision = 28,
        },
        .message_limits = if (flags.large_messages) large_message_limits else message_limits,
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
