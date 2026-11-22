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
//!   * `--exercise-effects` -- when a Run prepared with file delivery, image
//!     or video effects is cancelled, use each the way the tools do first,
//!     and report what came back in a last request on the video transport,
//!     so the UI half can check both sides.
//!   * `--no-runtime` -- the Agent Runtime cannot be created, so the process
//!     ends right after agreeing on identity, every time it is started.
//!   * `--data-root=<path>` -- as the application passes it: fault capture
//!     is installed with the execution role, and executing Runs leave
//!     breadcrumbs, the way the application's execution half does it.
//!   * `--crash-in-run` -- a Run traps while it executes, on the worker
//!     thread executing it.
//!   * `--spawn-grandchild=<path>` -- once the link is served, start this
//!     fixture again with `--linger`, its standard handles inherited the way
//!     a tool process's are, and write its process id to `path`.
//!   * `--linger` -- do nothing for a minute and exit: the grandchild.
//!   * `--hang-before-hello=<ms>` -- wait this long before agreeing on
//!     identity, as a process stuck in its startup does.
//!   * `--stop-reading` -- agree on identity, then never read the link
//!     again and never leave: a wedged child whose pipe fills up.
//!   * `--hang-mcp-replay` -- in every process after the first (floor not
//!     zero), applying an MCP configuration never returns: the replay a new
//!     process is given hangs, while the process keeps answering pings.
//!   * `--exercise-mcp` -- before applying an MCP configuration, drive each
//!     member's transport the way AgentCore drives a connector: open, an
//!     exchange whose answer is echoed back, one carrying a secret, one its
//!     caller withdraws, a notification, close. What this half saw is
//!     reported in further exchanges, so the UI half can check both sides.

const std = @import("std");

const execution_mode = @import("app_execution_mode");
const execution_server = @import("app_execution_server");
const fault = @import("app_fault");
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
pub const exercise_effects_flag = "--exercise-effects";
pub const data_root_flag = "--data-root=";
pub const crash_in_run_flag = "--crash-in-run";
pub const spawn_grandchild_flag = "--spawn-grandchild=";
pub const linger_flag = "--linger";
pub const hang_before_hello_flag = "--hang-before-hello=";
pub const stop_reading_flag = "--stop-reading";
pub const hang_mcp_replay_flag = "--hang-mcp-replay";

/// The fault record identity this fixture installs with. The version is the
/// link's own, so a test can tell this process's record from any other.
pub const fault_artifact_kind: fault.ArtifactKind = .development;
pub const fault_core_abi_revision: u16 = 28;

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
    exercise_effects: bool = false,
    crash_in_run: bool = false,
    data_root: ?[]u8 = null,
    grandchild_pid_path: ?[]u8 = null,
    linger: bool = false,
    hang_before_hello_ms: u64 = 0,
    stop_reading: bool = false,
    hang_mcp_replay: bool = false,
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
        if (std.mem.eql(u8, argument, exercise_effects_flag)) flags.exercise_effects = true;
        if (std.mem.eql(u8, argument, crash_in_run_flag)) flags.crash_in_run = true;
        if (std.mem.eql(u8, argument, linger_flag)) flags.linger = true;
        if (std.mem.eql(u8, argument, stop_reading_flag)) flags.stop_reading = true;
        if (std.mem.eql(u8, argument, hang_mcp_replay_flag)) flags.hang_mcp_replay = true;
        if (std.mem.startsWith(u8, argument, spawn_grandchild_flag))
            flags.grandchild_pid_path = init.gpa.dupe(u8, argument[spawn_grandchild_flag.len..]) catch null;
        if (std.mem.startsWith(u8, argument, hang_before_hello_flag))
            flags.hang_before_hello_ms = std.fmt.parseInt(u64, argument[hang_before_hello_flag.len..], 10) catch 0;
        if (std.mem.startsWith(u8, argument, data_root_flag))
            flags.data_root = init.gpa.dupe(u8, argument[data_root_flag.len..]) catch null;
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
    io: std.Io,
    runtime: ?*agent.Runtime = null,

    fn factory(self: *FakeRuntime) execution_server.Factory {
        return .{ .context = self, .create_fn = create };
    }

    fn create(context: ?*anyopaque, notifier: agent.EventReadyNotifier) ?execution_server.Runtime {
        const self: *FakeRuntime = @ptrCast(@alignCast(context.?));
        if (self.flags.no_runtime) return null;
        if (self.flags.grandchild_pid_path) |path| spawnGrandchild(self.io, path) catch |err|
            std.log.warn("fixture grandchild not started: {s}", .{@errorName(err)});
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
        const hang_mcp_apply = self.flags.hang_mcp_replay and self.flags.session_id_floor != 0;
        if (self.flags.exercise_mcp or self.flags.exercise_effects or self.flags.crash_in_run or hang_mcp_apply) {
            exercising_vtable = runtime_port.vtable.*;
            if (self.flags.exercise_mcp) exercising_vtable.apply_mcp_configuration = applyExercised;
            if (hang_mcp_apply) exercising_vtable.apply_mcp_configuration = applyHanging;
            if (self.flags.exercise_effects or self.flags.crash_in_run) exercising_vtable.create_session_route = createExercised;
            exercise_effects = self.flags.exercise_effects;
            crash_in_run = self.flags.crash_in_run;
            runtime_port.vtable = &exercising_vtable;
        }
        return .{ .port = runtime_port, .context = self, .shutdown_fn = shutdown };
    }

    var exercising_vtable: agent.RuntimePort.VTable = undefined;
    var exercising_session_vtable: agent.SessionPort.VTable = undefined;
    var original_prepare: @FieldType(agent.SessionPort.VTable, "prepare_run_with_tools") = undefined;
    var original_cancel: @FieldType(agent.SessionPort.VTable, "cancel_prepared_run") = undefined;
    var original_begin: @FieldType(agent.SessionPort.VTable, "begin_run_outcome") = undefined;
    var exercise_effects: bool = false;
    var crash_in_run: bool = false;
    const RunVTable = @typeInfo(@FieldType(RunPort, "vtable")).pointer.child;
    const RunTerminal = @typeInfo(@typeInfo(@FieldType(RunVTable, "execute")).pointer.child).@"fn".return_type.?;
    const crashing_run_vtable: RunVTable = .{ .execute = executeCrashing };

    const BeginFn = @FieldType(agent.SessionPort.VTable, "begin_run_outcome");
    const BeginOutcome = @typeInfo(@typeInfo(BeginFn).pointer.child).@"fn".return_type.?;
    const RunPort = @FieldType(BeginOutcome, "run");
    /// The effects of the Run last prepared, used when it is cancelled: by
    /// then both halves know the Run, as they do whenever a tool runs.
    var stashed_image: ?agent.ImageGenerationRunInput = null;
    var stashed_delivery: ?agent.FileDeliveryInput = null;
    var stashed_video: ?agent.VideoGenerationRunInput = null;

    const CreateFn = @FieldType(agent.RuntimePort.VTable, "create_session_route");
    const CreateResult = @typeInfo(@typeInfo(CreateFn).pointer.child).@"fn".return_type.?;

    fn createExercised(context: ?*anyopaque, options: agent.SessionOpenOptions) CreateResult {
        const runtime: *agent.Runtime = @ptrCast(@alignCast(context.?));
        var route = try runtime.runtimePort().createSessionRoute(options);
        exercising_session_vtable = route.session.vtable.*;
        if (exercise_effects) {
            original_prepare = exercising_session_vtable.prepare_run_with_tools;
            original_cancel = exercising_session_vtable.cancel_prepared_run;
            exercising_session_vtable.prepare_run_with_tools = prepareExercised;
            exercising_session_vtable.cancel_prepared_run = cancelExercised;
        }
        if (crash_in_run) {
            original_begin = exercising_session_vtable.begin_run_outcome;
            exercising_session_vtable.begin_run_outcome = beginCrashing;
        }
        route.session.vtable = &exercising_session_vtable;
        return route;
    }

    fn beginCrashing(context: ?*anyopaque, run_id: u64) BeginOutcome {
        var outcome = original_begin(context, run_id);
        switch (outcome) {
            .run => |*run| run.vtable = &crashing_run_vtable,
            else => {},
        }
        return outcome;
    }

    fn executeCrashing(context: ?*anyopaque, run_id: u64, generation: u64) RunTerminal {
        _ = context;
        _ = run_id;
        _ = generation;
        @trap();
    }

    fn prepareExercised(
        context: ?*anyopaque,
        input: agent.RunInput,
        image: ?agent.ImageGenerationRunInput,
        delivery: ?agent.FileDeliveryInput,
        mcp: ?agent.McpInstallationInput,
        video: ?agent.VideoGenerationRunInput,
    ) (agent.Error || std.mem.Allocator.Error)!u64 {
        stashed_image = image;
        stashed_delivery = delivery;
        stashed_video = video;
        return original_prepare(context, input, image, delivery, mcp, video);
    }

    fn cancelExercised(context: ?*anyopaque, run_id: u64) agent.Error!void {
        var summary_storage: [1024]u8 = undefined;
        var summary = std.Io.Writer.fixed(&summary_storage);
        exerciseEffects(&summary, stashed_image, stashed_delivery, stashed_video) catch {};
        if (stashed_video) |value| reportOver(value.transport, summary.buffered());
        return original_cancel(context, run_id);
    }

    fn exerciseEffects(
        summary: *std.Io.Writer,
        image: ?agent.ImageGenerationRunInput,
        delivery: ?agent.FileDeliveryInput,
        video: ?agent.VideoGenerationRunInput,
    ) !void {
        var never: std.atomic.Value(bool) = .init(false);
        if (delivery) |value| switch (value.inspect_fn(value.context, "out/report.txt", &never)) {
            .verified => |verified| try summary.print("inspect=verified:{d};", .{verified.size_bytes}),
            .failed => |failure| try summary.print("inspect={s};", .{@tagName(failure)}),
        };
        if (image) |value| {
            var credential: [64]u8 = undefined;
            const count = value.binding.credential_reader.?.read_fn(value.binding.credential_reader.?.context, &credential) orelse 0;
            try summary.print("image_credential={s};", .{credential[0..count]});
            var cancellation: agent.ImageGenerationCancellation = .{};
            var body: [64]u8 = undefined;
            const response = value.transport.perform(.{
                .url = "http://127.0.0.1:1/v1/images/generations",
                .headers = &.{.{ .name = "Authorization", .value = "Bearer image", .sensitive = true }},
                .body = "{\"prompt\":\"x\"}",
                .connect_timeout_ms = 1000,
                .source = "fixture-source",
            }, &cancellation, &body) catch |err| {
                try summary.print("image_http={s};", .{@errorName(err)});
                return;
            };
            try summary.print("image_http={d}:{s};", .{ response.status, response.body });
            switch (value.binding.output.commit_fn(value.binding.output.context, "PNGBYTES", .png, &cancellation)) {
                .saved => |receipt| try summary.print("image_saved={s};", .{receipt.path[0..receipt.path_len]}),
                .failed => |failure| try summary.print("image_failed={s};", .{@tagName(failure.code)}),
            }
        }
        if (video) |value| {
            var credential: [64]u8 = undefined;
            const count = value.credential.read_fn(value.credential.context, &credential) orelse 0;
            try summary.print("video_credential={s};", .{credential[0..count]});
            const Receiver = struct {
                got: [64]u8 = undefined,
                len: usize = 0,
                fn receive(receiver_context: *anyopaque, content_type: ?[]const u8, length: ?u64, reader: *std.Io.Reader) void {
                    const self: *@This() = @ptrCast(@alignCast(receiver_context));
                    _ = content_type;
                    _ = length;
                    self.len = reader.readSliceShort(&self.got) catch 0;
                }
            };
            var receiver: Receiver = .{};
            var cancellation: agent.ImageGenerationCancellation = .{};
            var body: [16]u8 = undefined;
            _ = value.transport.perform(.{
                .url = "http://127.0.0.1:1/v1/videos/1/content",
                .headers = &.{},
                .body = "",
                .method = .get,
                .stream = .{ .context = &receiver, .receive_fn = Receiver.receive },
                .connect_timeout_ms = 1000,
                .source = "fixture-source",
            }, &cancellation, &body) catch |err| {
                try summary.print("video_stream={s};", .{@errorName(err)});
                return;
            };
            try summary.print("video_stream={s};", .{receiver.got[0..receiver.len]});
            var reader = std.Io.Reader.fixed(receiver.got[0..receiver.len]);
            switch (value.output.commit_fn(value.output.context, &reader, receiver.len, &cancellation)) {
                .saved => |receipt| try summary.print("video_saved={s}:{d};", .{ receipt.path[0..receipt.path_len], receipt.size_bytes }),
                .failed => |failure| try summary.print("video_failed={s};", .{@tagName(failure)}),
            }
        }
    }

    /// Hands what this half saw to the UI half as one more request.
    fn reportOver(transport: agent.CompletionTransport, text: []const u8) void {
        var cancellation: agent.ImageGenerationCancellation = .{};
        var body: [16]u8 = undefined;
        _ = transport.perform(.{
            .url = "http://127.0.0.1:1/report",
            .headers = &.{},
            .body = text,
            .connect_timeout_ms = 1000,
            .source = "fixture-report",
        }, &cancellation, &body) catch {};
    }

    fn applyExercised(context: ?*anyopaque, input: *agent.McpRuntimeInput) (agent.Error || std.mem.Allocator.Error)!agent.McpConfigurationApplyOutcome {
        const runtime: *agent.Runtime = @ptrCast(@alignCast(context.?));
        for (input.members()) |member| exercise(member.transport());
        return runtime.applyMcpConfiguration(input);
    }

    /// An apply that never returns. The process stays up and its reader keeps
    /// answering pings; only the end of the link ends it.
    fn applyHanging(_: ?*anyopaque, _: *agent.McpRuntimeInput) (agent.Error || std.mem.Allocator.Error)!agent.McpConfigurationApplyOutcome {
        var never: std.Io.Event = .unset;
        never.waitUncancelable(lifecycle_fixture.fixtureIo());
        unreachable;
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

/// Serves the link by never reading it again: whatever the UI half writes
/// stays in the pipe until it is full.
const StopReading = struct {
    fn serve(_: ?*anyopaque, link: execution_mode.Link) execution_mode.Exit {
        while (true) std.Io.sleep(link.io, .fromSeconds(60), .awake) catch {};
    }
};

extern "kernel32" fn GetProcessId(process: std.os.windows.HANDLE) callconv(.winapi) std.os.windows.DWORD;

/// A process started the way a tool process is, standard handles inherited,
/// which outlives this one.
fn spawnGrandchild(io: std.Io, pid_path: []const u8) !void {
    var path_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try std.process.executablePath(io, &path_storage);
    const child = try std.process.spawn(io, .{
        .argv = &.{ path_storage[0..length], linger_flag },
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
        .create_no_window = true,
    });
    const pid: u32 = switch (@import("builtin").os.tag) {
        .windows => GetProcessId(child.id.?),
        else => @intCast(child.id.?),
    };
    var text: [16]u8 = undefined;
    const file = try std.Io.Dir.createFileAbsolute(io, pid_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, try std.fmt.bufPrint(&text, "{d}", .{pid}));
}

pub fn main(init: std.process.Init) !void {
    const flags = readFlags(init);
    if (flags.linger) {
        std.Io.sleep(init.io, .fromSeconds(60), .awake) catch {};
        std.process.exit(0);
    }
    if (flags.hang_before_hello_ms != 0)
        std.Io.sleep(init.io, .fromMilliseconds(@intCast(flags.hang_before_hello_ms)), .awake) catch {};
    const version = init.environ_map.get("METAWORK_EXEC_LINK_VERSION") orelse "fixture-0";
    const digest_text = init.environ_map.get("METAWORK_EXEC_LINK_DIGEST") orelse "11";
    var digest: [32]u8 = @splat(0);
    @memset(&digest, digest_text[0]);

    if (flags.data_root) |data_root| fault.install(init.io, .{
        .role = .execution,
        .data_root = data_root,
        .identity = .{
            .version = version,
            .artifact_kind = fault_artifact_kind,
            .core_manifest_sha256 = digest,
            .core_abi_revision = fault_core_abi_revision,
        },
    }) catch |failure| std.log.warn("fixture fault capture unavailable: {s}", .{@errorName(failure)});

    lifecycle_fixture.use(std.heap.c_allocator, init.io);
    var fake: FakeRuntime = .{ .flags = flags, .io = init.io };
    const server_options: execution_server.Options = .{
        .factory = fake.factory(),
        .event_delay_ms = if (flags.slow_events) 200 else 0,
        .run_breadcrumbs = if (fault.isInstalled()) .{ .begin_fn = fault.beginRun, .finish_fn = fault.finishRun } else null,
    };

    const exit = execution_mode.run(init.io, std.heap.c_allocator, .{
        .identity = .{
            .version = version,
            .core_manifest_sha256 = digest,
            .core_abi_revision = 28,
        },
        .message_limits = if (flags.large_messages) large_message_limits else message_limits,
        .queue_limits = .{},
        .server = if (flags.stop_reading)
            .{ .context = null, .serve_fn = StopReading.serve }
        else if (flags.with_runtime)
            execution_server.server(&server_options)
        else
            null,
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
