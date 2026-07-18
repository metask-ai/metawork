const std = @import("std");
const lifecycle = @import("metawork_agent");
const host_workbench = @import("metawork_workbench");
const event_pump = @import("event_pump");
const bridge_delivery = @import("bridge_delivery");
const workbench_executor = @import("workbench_executor");
const sdk = @import("metacodes_agentcore");
const wire = sdk.types;

fn pumpEnvelope(session_id: u64, run_id: u64, json: []const u8) !event_pump.EventEnvelope {
    const owned_json = try std.testing.allocator.dupe(u8, json);
    errdefer std.testing.allocator.free(owned_json);
    return .{
        .session_id = session_id,
        .run_id = run_id,
        .encoded_bytes = json.len,
        .json = owned_json,
        .event = try sdk.decodeCoreEvent(std.testing.allocator, json),
        .allocator = std.testing.allocator,
    };
}

fn textChunk(event: sdk.DecodedCoreEvent) ![]const u8 {
    return switch (event) {
        .known => |known| switch (known) {
            .text_chunk => |text| text,
            else => error.UnexpectedEvent,
        },
        .unknown => error.UnexpectedEvent,
    };
}

const PumpEnqueueContext = struct {
    pump: *event_pump.EventPump,
    envelope: event_pump.EventEnvelope,
    timeout: std.Io.Duration,
    succeeded: bool = false,
    failure: ?event_pump.Error = null,
};

fn enqueuePumpOnThread(context: *PumpEnqueueContext) void {
    context.pump.enqueueWithDeadline(context.envelope, context.timeout) catch |err| {
        context.failure = err;
        return;
    };
    context.succeeded = true;
}

fn ingestPumpEvent(delivery: *bridge_delivery.Delivery, pump: *event_pump.EventPump) !void {
    var envelope = pump.takeFair().?;
    const input = bridge_delivery.InputEvent{
        .session_id = envelope.session_id,
        .run_id = envelope.run_id,
        .json = envelope.json,
        .allocator = envelope.allocator,
    };
    envelope.event.deinit();
    envelope = undefined;
    delivery.ingest(input) catch |err| {
        var owned = input;
        owned.deinit();
        return err;
    };
}

fn deliveryInput(
    allocator: std.mem.Allocator,
    session_id: u64,
    run_id: u64,
    json: []const u8,
) !bridge_delivery.InputEvent {
    return .{
        .session_id = session_id,
        .run_id = run_id,
        .json = try allocator.dupe(u8, json),
        .allocator = allocator,
    };
}

const Plan = enum {
    immediate,
    controlled,
    ui_wait,
    callback_failed,
    controlled_callback_failed,
    event_callback,
    unknown_event_callback,
    malformed_event_callback,
    malformed_ui_callback,
    resource_limit,
    unknown_stop_result,
    invalid_result_layout,
    unknown_status,
};

const FakeRuntime = struct {};

const FakeSession = struct {
    in_use: bool = false,
    running: bool = false,
    destroyed: bool = false,
    plan: Plan = .immediate,
    callbacks: wire.SessionCallbacksV1 = std.mem.zeroes(wire.SessionCallbacksV1),
    run_id: u64 = 0,
    abort_requested: bool = false,
    allow_finish: bool = false,
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,

    fn lock(self: *FakeSession) void {
        self.mutex.lockUncancelable(std.testing.io);
    }

    fn unlock(self: *FakeSession) void {
        self.mutex.unlock(std.testing.io);
    }

    fn wait(self: *FakeSession) void {
        self.condition.waitUncancelable(std.testing.io, &self.mutex);
    }

    fn broadcast(self: *FakeSession) void {
        self.condition.broadcast(std.testing.io);
    }
};

const FakeCore = struct {
    mutex: std.Io.Mutex = .init,
    runtime: FakeRuntime = .{},
    sessions: [16]FakeSession = [_]FakeSession{.{}} ** 16,
    next_plan: Plan = .immediate,
    runtime_created: usize = 0,
    runtime_destroyed: usize = 0,
    runtime_destroy_busy_attempts: usize = 0,
    session_created: usize = 0,
    session_destroyed: usize = 0,
    run_calls: usize = 0,
    abort_calls: usize = 0,
    last_abort_reason: ?u32 = null,
    buffer_releases: usize = 0,
    credential_seen: bool = false,
    zero_host_tools_seen: bool = false,
    builtin_allowlist_seen: bool = false,
    session_destroy_failures: usize = 0,
    runtime_destroy_failures: usize = 0,
    session_create_failures: usize = 0,
    forced_abort_status: ?u32 = null,

    fn lock(self: *FakeCore) void {
        self.mutex.lockUncancelable(std.testing.io);
    }

    fn unlock(self: *FakeCore) void {
        self.mutex.unlock(std.testing.io);
    }

    fn reset(self: *FakeCore) void {
        self.* = .{};
    }

    fn setNextPlan(self: *FakeCore, plan: Plan) void {
        self.lock();
        self.next_plan = plan;
        self.unlock();
    }

    fn releaseControlled(self: *FakeCore) void {
        for (&self.sessions) |*session| {
            session.lock();
            session.allow_finish = true;
            session.broadcast();
            session.unlock();
        }
    }

    fn rearmControlled(self: *FakeCore) void {
        for (&self.sessions) |*session| {
            session.lock();
            session.allow_finish = false;
            session.abort_requested = false;
            session.unlock();
        }
    }

    fn failNextSessionDestroy(self: *FakeCore) void {
        self.lock();
        self.session_destroy_failures += 1;
        self.unlock();
    }

    fn failNextRuntimeDestroy(self: *FakeCore) void {
        self.lock();
        self.runtime_destroy_failures += 1;
        self.unlock();
    }

    fn failNextSessionCreate(self: *FakeCore) void {
        self.lock();
        self.session_create_failures += 1;
        self.unlock();
    }

    fn forceNextAbortStatus(self: *FakeCore, status: u32) void {
        self.lock();
        self.forced_abort_status = status;
        self.unlock();
    }
};

var fake_core = FakeCore{};
var diagnostic_byte: u8 = 0xA5;

fn diagnostic(out: ?*wire.OwnedBytesV1) void {
    if (out) |value| value.* = .{ .ptr = @ptrCast(&diagnostic_byte), .len = 1 };
}

fn runtimeCreate(
    config: ?*const wire.RuntimeConfigV1,
    out_runtime: ?*?*wire.RuntimeHandle,
    out_error: ?*wire.OwnedBytesV1,
) callconv(.c) u32 {
    if (out_error) |out| out.* = .{ .ptr = null, .len = 0 };
    if (config == null or out_runtime == null) {
        diagnostic(out_error);
        return wire.STATUS_INVALID_ARGUMENT;
    }
    fake_core.lock();
    defer fake_core.unlock();
    fake_core.runtime_created += 1;
    fake_core.zero_host_tools_seen = config.?.host_tools == null and
        config.?.host_tool_count == 0 and
        config.?.builtin_tools != null and
        config.?.builtin_tool_count == 4;
    out_runtime.?.* = @ptrCast(&fake_core.runtime);
    return wire.STATUS_OK;
}

fn runtimeDestroy(
    _: ?*wire.RuntimeHandle,
    out_error: ?*wire.OwnedBytesV1,
) callconv(.c) u32 {
    if (out_error) |out| out.* = .{ .ptr = null, .len = 0 };
    fake_core.lock();
    defer fake_core.unlock();
    if (fake_core.runtime_destroy_failures > 0) {
        fake_core.runtime_destroy_failures -= 1;
        diagnostic(out_error);
        return wire.STATUS_BUSY;
    }
    for (&fake_core.sessions) |*session| {
        session.lock();
        const live = session.in_use and !session.destroyed;
        session.unlock();
        if (live) {
            fake_core.runtime_destroy_busy_attempts += 1;
            diagnostic(out_error);
            return wire.STATUS_BUSY;
        }
    }
    fake_core.runtime_destroyed += 1;
    return wire.STATUS_OK;
}

fn sessionCreate(
    _: ?*wire.RuntimeHandle,
    config: ?*const wire.SessionConfigV1,
    callbacks: ?*const wire.SessionCallbacksV1,
    out_session: ?*?*wire.SessionHandle,
    out_error: ?*wire.OwnedBytesV1,
) callconv(.c) u32 {
    if (out_error) |out| out.* = .{ .ptr = null, .len = 0 };
    if (config == null or callbacks == null or out_session == null) {
        diagnostic(out_error);
        return wire.STATUS_INVALID_ARGUMENT;
    }
    const key = sdk.borrowedBytes(config.?.api_key) catch {
        diagnostic(out_error);
        return wire.STATUS_INVALID_ARGUMENT;
    };
    fake_core.lock();
    defer fake_core.unlock();
    if (fake_core.session_create_failures > 0) {
        fake_core.session_create_failures -= 1;
        diagnostic(out_error);
        return wire.STATUS_CORE_ERROR;
    }
    for (&fake_core.sessions) |*session| {
        if (!session.in_use) {
            session.* = .{
                .in_use = true,
                .plan = fake_core.next_plan,
                .callbacks = callbacks.?.*,
            };
            fake_core.next_plan = .immediate;
            fake_core.session_created += 1;
            fake_core.credential_seen = std.mem.eql(u8, key, "fixture-secret");
            fake_core.builtin_allowlist_seen = config.?.allowed_tools != null and
                config.?.allowed_tool_count == 4;
            out_session.?.* = @ptrCast(session);
            return wire.STATUS_OK;
        }
    }
    diagnostic(out_error);
    return wire.STATUS_OUT_OF_MEMORY;
}

fn sessionDestroy(
    handle: ?*wire.SessionHandle,
    out_error: ?*wire.OwnedBytesV1,
) callconv(.c) u32 {
    if (out_error) |out| out.* = .{ .ptr = null, .len = 0 };
    const session: *FakeSession = @ptrCast(@alignCast(handle orelse {
        diagnostic(out_error);
        return wire.STATUS_INVALID_ARGUMENT;
    }));
    session.lock();
    if (session.running) {
        session.unlock();
        diagnostic(out_error);
        return wire.STATUS_BUSY;
    }
    session.unlock();
    fake_core.lock();
    if (fake_core.session_destroy_failures > 0) {
        fake_core.session_destroy_failures -= 1;
        fake_core.unlock();
        diagnostic(out_error);
        return wire.STATUS_BUSY;
    }
    fake_core.unlock();
    session.lock();
    session.destroyed = true;
    session.unlock();
    fake_core.lock();
    fake_core.session_destroyed += 1;
    fake_core.unlock();
    return wire.STATUS_OK;
}

fn sessionRun(
    handle: ?*wire.SessionHandle,
    run_id: u64,
    _: wire.BytesViewV1,
    _: ?*const wire.RunOptionsV1,
    out_result: ?*wire.RunResultV1,
    out_error: ?*wire.OwnedBytesV1,
) callconv(.c) u32 {
    if (out_error) |out| out.* = .{ .ptr = null, .len = 0 };
    const session: *FakeSession = @ptrCast(@alignCast(handle orelse {
        diagnostic(out_error);
        return wire.STATUS_INVALID_ARGUMENT;
    }));
    fake_core.lock();
    fake_core.run_calls += 1;
    fake_core.unlock();
    session.lock();
    session.running = true;
    session.run_id = run_id;
    const plan = session.plan;
    session.broadcast();
    session.unlock();

    if (plan == .event_callback or plan == .unknown_event_callback or
        plan == .malformed_event_callback)
    {
        const callback = session.callbacks.on_event orelse {
            diagnostic(out_error);
            return wire.STATUS_CALLBACK_FAILED;
        };
        var event_buffer = "{\"text_chunk\":\"typed event\"}".*;
        const event_json: []const u8 = switch (plan) {
            .event_callback => &event_buffer,
            .unknown_event_callback => "{\"future_observation\":{\"answer\":42}}",
            .malformed_event_callback => "{}",
            else => unreachable,
        };
        const callback_status = callback(session.callbacks.ctx, handle, run_id, sdk.bytesView(event_json));
        @memset(&event_buffer, 'x');
        if (callback_status != wire.CALLBACK_CONTINUE) {
            session.lock();
            session.running = false;
            session.broadcast();
            session.unlock();
            diagnostic(out_error);
            return wire.STATUS_CALLBACK_FAILED;
        }
    }

    if (plan == .ui_wait or plan == .malformed_ui_callback) {
        var response = wire.OwnedBytesV1{ .ptr = null, .len = 0 };
        const callback = session.callbacks.on_ui_request orelse {
            diagnostic(out_error);
            return wire.STATUS_CALLBACK_FAILED;
        };
        const request_json = if (plan == .ui_wait)
            "{\"permission\":{\"tool\":\"Bash\",\"args\":\"{}\"}}"
        else
            "{}";
        const callback_status = callback(
            session.callbacks.ctx,
            handle,
            sdk.bytesView(request_json),
            &response,
        );
        if (callback_status == wire.UI_ANSWERED) {
            const release = session.callbacks.release_response orelse {
                diagnostic(out_error);
                return wire.STATUS_CALLBACK_FAILED;
            };
            release(session.callbacks.ctx, &response);
            if (response.ptr != null or response.len != 0) {
                diagnostic(out_error);
                return wire.STATUS_CALLBACK_FAILED;
            }
        } else if (callback_status == wire.UI_FATAL) {
            session.lock();
            session.running = false;
            session.broadcast();
            session.unlock();
            diagnostic(out_error);
            return wire.STATUS_CALLBACK_FAILED;
        }
    }

    session.lock();
    while ((plan == .controlled or plan == .controlled_callback_failed or plan == .ui_wait) and
        !session.allow_finish and !session.abort_requested)
        session.wait();
    const aborted = session.abort_requested;
    session.running = false;
    session.broadcast();
    session.unlock();

    if (plan == .callback_failed or plan == .controlled_callback_failed) {
        diagnostic(out_error);
        return wire.STATUS_CALLBACK_FAILED;
    }
    if (plan == .resource_limit) {
        diagnostic(out_error);
        return wire.STATUS_RESOURCE_LIMIT;
    }
    if (plan == .unknown_status) {
        if (out_result) |result| {
            result.* = std.mem.zeroes(wire.RunResultV1);
            result.struct_size = @sizeOf(wire.RunResultV1);
            result.stop_reason_code = wire.STOP_END_TURN;
        }
        diagnostic(out_error);
        return 42;
    }
    if (out_result) |result| {
        result.* = std.mem.zeroes(wire.RunResultV1);
        result.struct_size = if (plan == .invalid_result_layout) 0 else @sizeOf(wire.RunResultV1);
        result.stop_reason_code = if (aborted)
            wire.STOP_ABORTED
        else switch (plan) {
            .unknown_stop_result => 42,
            else => wire.STOP_END_TURN,
        };
    }
    return wire.STATUS_OK;
}

fn sessionAbort(
    handle: ?*wire.SessionHandle,
    run_id: u64,
    reason: u32,
    out_error: ?*wire.OwnedBytesV1,
) callconv(.c) u32 {
    if (out_error) |out| out.* = .{ .ptr = null, .len = 0 };
    const session: *FakeSession = @ptrCast(@alignCast(handle orelse {
        diagnostic(out_error);
        return wire.STATUS_INVALID_ARGUMENT;
    }));
    fake_core.lock();
    fake_core.abort_calls += 1;
    fake_core.last_abort_reason = reason;
    const forced_status = fake_core.forced_abort_status;
    fake_core.forced_abort_status = null;
    fake_core.unlock();
    if (forced_status) |status| {
        diagnostic(out_error);
        return status;
    }
    session.lock();
    defer session.unlock();
    if (!session.running) {
        diagnostic(out_error);
        return wire.STATUS_TOO_LATE;
    }
    if (session.run_id != run_id) {
        diagnostic(out_error);
        return wire.STATUS_STALE_RUN;
    }
    session.abort_requested = true;
    session.broadcast();
    return wire.STATUS_OK;
}

fn bufferRelease(out: ?*wire.OwnedBytesV1) callconv(.c) void {
    if (out) |value| value.* = .{ .ptr = null, .len = 0 };
    fake_core.lock();
    fake_core.buffer_releases += 1;
    fake_core.unlock();
}

const fake_api = wire.ApiV1{
    .struct_size = @sizeOf(wire.ApiV1),
    .abi_version = wire.ABI_VERSION_V1,
    .capabilities = wire.REQUIRED_CAPABILITIES_V1,
    .runtime_create = runtimeCreate,
    .runtime_destroy = runtimeDestroy,
    .session_create = sessionCreate,
    .session_destroy = sessionDestroy,
    .session_run = sessionRun,
    .session_abort = sessionAbort,
    .buffer_release = bufferRelease,
    .reserved = [_]u64{0} ** 4,
};

fn openSession(host: *lifecycle.Runtime) !*lifecycle.Session {
    return host.createSession(.{
        .provider_kind_code = wire.PROVIDER_ANTHROPIC,
        .permission_mode_code = wire.PERMISSION_DEFAULT,
        .shell_policy_code = wire.SHELL_DISABLED,
        .credential = "fixture-secret",
        .model = "fixture-model",
        .workspace = .{
            .canonical_root = "/tmp/metawork-gate2",
            .trust = .{ .temporary = "/tmp" },
        },
    });
}

const TestHostLimits = struct {
    worker_count: usize,
    queue_capacity: usize,
    max_sessions: usize,
    max_prompt_bytes: ?usize = null,
    event_capacity: ?usize = null,
    per_session_event_capacity: ?usize = null,
    control_reserved_capacity: ?usize = null,
    per_session_control_reserved_capacity: ?usize = null,
    max_ui_response_bytes: ?usize = null,
    ui_request_timeout: ?std.Io.Duration = null,

    fn hostLimits(self: @This()) lifecycle.Limits {
        var limits = lifecycle.Limits{ .max_sessions = self.max_sessions };
        if (self.max_prompt_bytes) |value| limits.max_prompt_bytes = value;
        if (self.event_capacity) |value| limits.event_capacity = value;
        if (self.per_session_event_capacity) |value| limits.per_session_event_capacity = value;
        if (self.control_reserved_capacity) |value| limits.control_reserved_capacity = value;
        if (self.per_session_control_reserved_capacity) |value|
            limits.per_session_control_reserved_capacity = value;
        if (self.max_ui_response_bytes) |value| limits.max_ui_response_bytes = value;
        if (self.ui_request_timeout) |value| limits.ui_request_timeout = value;
        return limits;
    }
};

const TestHostEntry = struct {
    runtime: *lifecycle.Runtime,
    executor: *workbench_executor.Executor,
    executor_shutdown: std.atomic.Value(enum(u8) { open, running, complete }) = .init(.open),
};

var test_host_entries: [32]?TestHostEntry = @splat(null);

fn registerTestHost(runtime: *lifecycle.Runtime, executor: *workbench_executor.Executor) !void {
    for (&test_host_entries) |*entry| {
        if (entry.* == null) {
            entry.* = .{ .runtime = runtime, .executor = executor };
            return;
        }
    }
    return error.TestHostCapacity;
}

fn testHostEntry(runtime: *lifecycle.Runtime) *TestHostEntry {
    for (&test_host_entries) |*entry| {
        const value = &(entry.* orelse continue);
        if (value.runtime == runtime) return value;
    }
    unreachable;
}

fn testExecutor(runtime: *lifecycle.Runtime) *workbench_executor.Executor {
    return testHostEntry(runtime).executor;
}

fn unregisterTestHost(runtime: *lifecycle.Runtime) *workbench_executor.Executor {
    for (&test_host_entries) |*entry| {
        const value = entry.* orelse continue;
        if (value.runtime == runtime) {
            entry.* = null;
            return value.executor;
        }
    }
    unreachable;
}

fn executeTestRun(context: *anyopaque) void {
    const session: *lifecycle.Session = @ptrCast(@alignCast(context));
    session.executePreparedRun();
}

fn cancelTestRunForShutdown(context: *anyopaque) void {
    const session: *lifecycle.Session = @ptrCast(@alignCast(context));
    const run_id = session.snapshot().active_run_id;
    session.cancelPreparedRun(run_id, .host_shutdown) catch {};
}

fn submitSession(session: *lifecycle.Session, prompt: []const u8) !u64 {
    const run_id = try session.prepareRun(prompt);
    testExecutor(session.agent_runtime).enqueue(.{
        .context = session,
        .execute_fn = executeTestRun,
        .cancel_fn = cancelTestRunForShutdown,
    }) catch |err| {
        const cause: lifecycle.HostCause = switch (err) {
            error.QueueFull => .queue_capacity_failure,
            error.HostShuttingDown => .host_shutdown,
        };
        session.cancelPreparedRun(run_id, cause) catch {};
        return err;
    };
    return run_id;
}

fn cancelSession(session: *lifecycle.Session, run_id: u64, cause: lifecycle.HostCause) !void {
    if (testExecutor(session.agent_runtime).cancel(session))
        return session.cancelPreparedRun(run_id, cause);
    return session.requestCancel(run_id, cause);
}

fn closeSession(session: *lifecycle.Session, cause: lifecycle.HostCause) !void {
    const snapshot = session.snapshot();
    if (snapshot.state == .queued and testExecutor(session.agent_runtime).cancel(session))
        try session.cancelPreparedRun(snapshot.active_run_id, cause);
    return session.close(cause);
}

fn shutdownHost(runtime: *lifecycle.Runtime) !void {
    const entry = testHostEntry(runtime);
    if (entry.executor_shutdown.cmpxchgStrong(.open, .running, .acq_rel, .acquire) == null) {
        entry.executor.shutdown();
        entry.executor_shutdown.store(.complete, .release);
    } else {
        while (entry.executor_shutdown.load(.acquire) != .complete)
            std.Thread.yield() catch {};
    }
    return runtime.shutdown();
}

fn deinitHost(runtime: *lifecycle.Runtime) void {
    const executor = unregisterTestHost(runtime);
    executor.deinit();
    runtime.deinit();
}

fn createHost(limits: TestHostLimits) !*lifecycle.Runtime {
    const executor = try workbench_executor.Executor.create(
        std.testing.io,
        std.testing.allocator,
        .{ .worker_count = limits.worker_count, .queue_capacity = limits.queue_capacity },
    );
    var executor_registered = false;
    errdefer if (!executor_registered) executor.deinit();
    const runtime = try lifecycle.Runtime.init(
        std.testing.io,
        std.testing.allocator,
        &fake_api,
        limits.hostLimits(),
    );
    errdefer {
        runtime.shutdown() catch {};
        runtime.deinit();
    }
    try registerTestHost(runtime, executor);
    executor_registered = true;
    return runtime;
}

fn workbenchSessionOptions() lifecycle.SessionOpenOptions {
    return .{
        .provider_kind_code = wire.PROVIDER_ANTHROPIC,
        .permission_mode_code = wire.PERMISSION_DEFAULT,
        .shell_policy_code = wire.SHELL_DISABLED,
        .credential = "fixture-secret",
        .model = "fixture-model",
        .workspace = .{
            .canonical_root = "/tmp/metawork-gate6",
            .trust = .{ .temporary = "/tmp" },
        },
    };
}

fn waitWorkbenchSnapshot(
    workbench: *host_workbench.Workbench,
    needle: []const u8,
) !void {
    var output: [128 * 1024]u8 = undefined;
    for (0..10_000) |_| {
        const snapshot = try workbench.writeSnapshot(&output);
        if (std.mem.indexOf(u8, snapshot, needle) != null) return;
        std.Thread.yield() catch {};
    }
    return error.TestUnexpectedResult;
}

fn closeOnThread(session: *lifecycle.Session) void {
    closeSession(session, .session_close) catch unreachable;
}

fn cancelOnThread(session: *lifecycle.Session, run_id: u64) void {
    cancelSession(session, run_id, .user_cancel) catch unreachable;
}

fn failPipelineOnThread(session: *lifecycle.Session) void {
    session.recordCause(.event_pipeline_failure);
}

fn shutdownOnThread(host: *lifecycle.Runtime) void {
    shutdownHost(host) catch unreachable;
}

test "Host creates and destroys Runtime and idle Session" {
    fake_core.reset();
    const host = try createHost(.{
        .worker_count = 1,
        .queue_capacity = 2,
        .max_sessions = 2,
    });
    defer deinitHost(host);
    const session = try openSession(host);
    try std.testing.expect(fake_core.credential_seen);
    try std.testing.expect(fake_core.zero_host_tools_seen);
    try std.testing.expect(fake_core.builtin_allowlist_seen);
    try std.testing.expectEqual(lifecycle.SessionState.idle, session.snapshot().state);
    try closeSession(session, .session_close);
    try closeSession(session, .session_close);
    try shutdownHost(host);
    try shutdownHost(host);
    try std.testing.expectEqual(@as(usize, 1), fake_core.runtime_created);
    try std.testing.expectEqual(@as(usize, 1), fake_core.runtime_destroyed);
    try std.testing.expectEqual(@as(usize, 1), fake_core.session_destroyed);
}

test "Workspace requires an absolute temporary or explicit trusted root" {
    fake_core.reset();
    const host = try createHost(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
    });
    defer {
        shutdownHost(host) catch unreachable;
        deinitHost(host);
    }
    try std.testing.expectError(error.InvalidWorkspace, host.createSession(.{
        .provider_kind_code = wire.PROVIDER_ANTHROPIC,
        .permission_mode_code = wire.PERMISSION_DEFAULT,
        .shell_policy_code = wire.SHELL_DISABLED,
        .credential = "fixture-secret",
        .model = "fixture-model",
        .workspace = .{ .canonical_root = "relative", .trust = .explicitly_trusted },
    }));
    try std.testing.expectError(error.WorkspaceNotTrusted, host.createSession(.{
        .provider_kind_code = wire.PROVIDER_ANTHROPIC,
        .permission_mode_code = wire.PERMISSION_DEFAULT,
        .shell_policy_code = wire.SHELL_DISABLED,
        .credential = "fixture-secret",
        .model = "fixture-model",
        .workspace = .{
            .canonical_root = "/var/not-temp",
            .trust = .{ .temporary = "/tmp" },
        },
    }));
    try std.testing.expectError(error.InvalidWorkspace, host.createSession(.{
        .provider_kind_code = wire.PROVIDER_ANTHROPIC,
        .permission_mode_code = wire.PERMISSION_DEFAULT,
        .shell_policy_code = wire.SHELL_DISABLED,
        .credential = "fixture-secret",
        .model = "fixture-model",
        .workspace = .{
            .canonical_root = "/tmp/../etc",
            .trust = .{ .temporary = "/tmp" },
        },
    }));
}

test "bounded executor rejects overflow and close cancels a queued Run" {
    fake_core.reset();
    fake_core.setNextPlan(.controlled);
    const host = try createHost(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 3 });
    defer {
        shutdownHost(host) catch unreachable;
        deinitHost(host);
    }
    const running = try openSession(host);
    const queued = try openSession(host);
    const rejected = try openSession(host);

    const running_id = try submitSession(running, "hold worker");
    try running.waitForState(.running);
    _ = try submitSession(queued, "stay queued");
    try std.testing.expectError(error.SessionNotIdle, submitSession(queued, "second in-flight"));
    try std.testing.expectError(error.QueueFull, submitSession(rejected, "overflow"));
    try std.testing.expectEqual(lifecycle.SessionState.idle, rejected.snapshot().state);

    try closeSession(queued, .session_close);
    const queued_snapshot = queued.snapshot();
    try std.testing.expectEqual(
        @as(?lifecycle.HostCause, .session_close),
        queued_snapshot.cause,
    );
    try std.testing.expectEqual(
        @as(?lifecycle.RunOutcome, .interrupted),
        queued_snapshot.last_outcome,
    );
    fake_core.lock();
    const calls_before_release = fake_core.run_calls;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), calls_before_release);

    fake_core.releaseControlled();
    try running.waitRun(running_id);
    try closeSession(running, .session_close);
    try closeSession(rejected, .session_close);
}

test "queued prompt memory is bounded before allocation" {
    fake_core.reset();
    const host = try createHost(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
        .max_prompt_bytes = 4,
    });
    defer {
        shutdownHost(host) catch unreachable;
        deinitHost(host);
    }
    const session = try openSession(host);
    try std.testing.expectError(error.PromptTooLarge, submitSession(session, "12345"));
    try std.testing.expectEqual(lifecycle.SessionState.idle, session.snapshot().state);
    try closeSession(session, .session_close);
}

test "pre-admission resource limit leaves the Session reusable" {
    fake_core.reset();
    fake_core.setNextPlan(.resource_limit);
    const host = try createHost(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
    defer {
        shutdownHost(host) catch unreachable;
        deinitHost(host);
    }
    const session = try openSession(host);
    const first_run = try submitSession(session, "exceed a Core resource limit");
    try session.waitRun(first_run);
    const first = session.snapshot();
    try std.testing.expectEqual(@as(?u32, wire.STATUS_RESOURCE_LIMIT), first.last_status);
    try std.testing.expectEqual(@as(?lifecycle.RunOutcome, .failed), first.last_outcome);
    try std.testing.expectEqual(lifecycle.SessionState.idle, first.state);

    const second_run = try submitSession(session, "the Session remains admitted");
    try session.waitRun(second_run);
    try std.testing.expectEqual(lifecycle.SessionState.idle, session.snapshot().state);
    try closeSession(session, .session_close);
}

test "closing an active Run aborts, joins, and preserves the first HostCause" {
    fake_core.reset();
    fake_core.setNextPlan(.controlled_callback_failed);
    const host = try createHost(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
    defer {
        shutdownHost(host) catch unreachable;
        deinitHost(host);
    }
    const session = try openSession(host);
    const run_id = try submitSession(session, "race cancel with callback failure");
    try session.waitForState(.running);

    const cancel_thread = try std.Thread.spawn(.{}, cancelOnThread, .{ session, run_id });
    const failure_thread = try std.Thread.spawn(.{}, failPipelineOnThread, .{session});
    cancel_thread.join();
    failure_thread.join();
    try session.waitRun(run_id);

    const before = session.snapshot();
    try std.testing.expect(before.cause == .user_cancel or before.cause == .event_pipeline_failure);
    try std.testing.expectEqual(@as(?u32, wire.STATUS_CALLBACK_FAILED), before.last_status);
    session.recordCause(.timeout);
    try std.testing.expectEqual(before.cause, session.snapshot().cause);
    try closeSession(session, .session_close);
    fake_core.lock();
    const abort_calls = fake_core.abort_calls;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), abort_calls);
}

test "malformed Core events fail the Run instead of entering the bounded sink" {
    fake_core.reset();
    fake_core.setNextPlan(.malformed_event_callback);
    const host = try createHost(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
    defer {
        shutdownHost(host) catch unreachable;
        deinitHost(host);
    }
    const session = try openSession(host);
    const run_id = try submitSession(session, "emit malformed event");
    try session.waitRun(run_id);
    const snapshot = session.snapshot();
    try std.testing.expectEqual(@as(?u32, wire.STATUS_CALLBACK_FAILED), snapshot.last_status);
    try std.testing.expectEqual(
        @as(?lifecycle.HostCause, .event_pipeline_failure),
        snapshot.cause,
    );
    try std.testing.expectEqual(lifecycle.SessionState.poisoned, snapshot.state);
    try std.testing.expectError(error.SessionPoisoned, submitSession(session, "must not continue"));
    try std.testing.expect(host.takeEvent() == null);
    try closeSession(session, .session_close);
    fake_core.lock();
    const releases = fake_core.buffer_releases;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), releases);
}

test "valid unknown observations are ignored without consuming pump capacity" {
    fake_core.reset();
    fake_core.setNextPlan(.unknown_event_callback);
    const host = try createHost(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
        .event_capacity = 1,
        .per_session_event_capacity = 1,
        .control_reserved_capacity = 0,
        .per_session_control_reserved_capacity = 0,
    });
    defer {
        shutdownHost(host) catch unreachable;
        deinitHost(host);
    }
    const session = try openSession(host);
    const run_id = try submitSession(session, "emit a future observation");
    try session.waitRun(run_id);
    const snapshot = session.snapshot();
    try std.testing.expectEqual(@as(?u32, wire.STATUS_OK), snapshot.last_status);
    try std.testing.expectEqual(@as(?lifecycle.RunOutcome, .completed), snapshot.last_outcome);
    try std.testing.expectEqual(lifecycle.SessionState.idle, snapshot.state);
    try std.testing.expect(host.takeEvent() == null);
    try closeSession(session, .session_close);
}

test "typed Core events are deep-copied into a bounded routed sink" {
    fake_core.reset();
    fake_core.setNextPlan(.event_callback);
    const host = try createHost(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
        .event_capacity = 2,
        .per_session_event_capacity = 2,
        .control_reserved_capacity = 0,
        .per_session_control_reserved_capacity = 0,
    });
    defer {
        shutdownHost(host) catch unreachable;
        deinitHost(host);
    }
    const session = try openSession(host);
    const first_run = try submitSession(session, "emit typed event");
    try session.waitRun(first_run);
    const first_snapshot = session.snapshot();
    try std.testing.expectEqual(@as(?u32, wire.STATUS_OK), first_snapshot.last_status);
    try std.testing.expectEqual(@as(?u32, wire.STOP_END_TURN), first_snapshot.last_stop_reason_code);
    try std.testing.expectEqual(@as(?lifecycle.RunOutcome, .completed), first_snapshot.last_outcome);

    const second_run = try submitSession(session, "preserve FIFO order");
    try session.waitRun(second_run);
    const second_snapshot = session.snapshot();
    try std.testing.expectEqual(@as(?lifecycle.RunOutcome, .completed), second_snapshot.last_outcome);

    var envelope = host.takeEvent().?;
    defer envelope.deinit();
    try std.testing.expect(envelope.session_id != 0);
    try std.testing.expectEqual(first_run, envelope.run_id);
    try std.testing.expectEqualStrings("{\"text_chunk\":\"typed event\"}", envelope.json);
    try std.testing.expectEqualStrings("typed event", try textChunk(envelope.event.value));
    var second = host.takeEvent().?;
    try std.testing.expectEqual(second_run, second.run_id);
    second.deinit();
    try closeSession(session, .session_close);
}

test "bounded event sink overflow returns callback fatal and preserves HostCause" {
    fake_core.reset();
    fake_core.setNextPlan(.event_callback);
    const host = try createHost(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
        .event_capacity = 1,
        .per_session_event_capacity = 1,
        .control_reserved_capacity = 0,
        .per_session_control_reserved_capacity = 0,
    });
    defer {
        shutdownHost(host) catch unreachable;
        deinitHost(host);
    }
    const session = try openSession(host);
    const first_run = try submitSession(session, "retain first event");
    try session.waitRun(first_run);
    const second_run = try submitSession(session, "overflow sink");
    try session.waitRun(second_run);
    const snapshot = session.snapshot();
    try std.testing.expectEqual(@as(?u32, wire.STATUS_CALLBACK_FAILED), snapshot.last_status);
    try std.testing.expectEqual(@as(?lifecycle.HostCause, .queue_capacity_failure), snapshot.cause);
    try std.testing.expectEqual(@as(?lifecycle.RunOutcome, .failed), snapshot.last_outcome);
    var retained = host.takeEvent().?;
    retained.deinit();
    try closeSession(session, .session_close);
}

test "UI request validates identity and close wakes a suspended callback" {
    fake_core.reset();
    fake_core.setNextPlan(.ui_wait);
    const host = try createHost(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 3 });
    defer {
        shutdownHost(host) catch unreachable;
        deinitHost(host);
    }
    const answered = try openSession(host);
    const run_id = try submitSession(answered, "request UI");
    try answered.waitForState(.waiting_ui);
    const request_id = answered.pendingUiRequest().?;
    var pending = try answered.copyPendingUiRequest(std.testing.allocator);
    defer pending.deinit();
    try std.testing.expectEqual(run_id, pending.run_id);
    try std.testing.expectEqual(request_id, pending.request_id);
    var decoded = try sdk.decodeUiRequest(std.testing.allocator, pending.json);
    defer decoded.deinit();
    try std.testing.expectEqual(std.meta.Tag(sdk.UiRequest).permission, std.meta.activeTag(decoded.value));
    const response = sdk.UiResponse{ .permission = .allow_once };
    try std.testing.expectError(error.StaleUiResponse, answered.respondUi(run_id + 1, request_id, response));
    try std.testing.expectError(error.StaleUiResponse, answered.respondUi(run_id, request_id + 1, response));
    try std.testing.expectError(
        error.InvalidUiResponse,
        answered.respondUi(run_id, request_id, .{ .answers = &.{"Yes"} }),
    );
    try answered.respondUi(run_id, request_id, response);
    try std.testing.expectError(error.StaleUiResponse, answered.respondUi(run_id, request_id, response));
    fake_core.releaseControlled();
    try answered.waitRun(run_id);
    try closeSession(answered, .session_close);

    fake_core.setNextPlan(.ui_wait);
    const closing = try openSession(host);
    _ = try submitSession(closing, "close while UI waits");
    try closing.waitForState(.waiting_ui);
    try closeSession(closing, .session_close);
    const snapshot = closing.snapshot();
    try std.testing.expectEqual(lifecycle.SessionState.closed, snapshot.state);
    try std.testing.expectEqual(@as(?lifecycle.HostCause, .session_close), snapshot.cause);

    fake_core.setNextPlan(.ui_wait);
    const cancelled = try openSession(host);
    const cancelled_run = try submitSession(cancelled, "cancel while UI waits");
    try cancelled.waitForState(.waiting_ui);
    try cancelSession(cancelled, cancelled_run, .user_cancel);
    try cancelled.waitRun(cancelled_run);
    try std.testing.expectEqual(
        @as(?lifecycle.HostCause, .user_cancel),
        cancelled.snapshot().cause,
    );
    try closeSession(cancelled, .session_close);
}

test "UI deadline returns unavailable and malformed UI fails the Run" {
    fake_core.reset();
    fake_core.setNextPlan(.ui_wait);
    const host = try createHost(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 2,
        .ui_request_timeout = .fromMilliseconds(20),
    });
    defer {
        shutdownHost(host) catch unreachable;
        deinitHost(host);
    }
    const timed_out = try openSession(host);
    const timeout_run = try submitSession(timed_out, "let UI expire");
    try timed_out.waitForState(.waiting_ui);
    try timed_out.waitForState(.running);
    try std.testing.expect(timed_out.pendingUiRequest() == null);
    fake_core.releaseControlled();
    try timed_out.waitRun(timeout_run);
    try std.testing.expectEqual(
        @as(?lifecycle.RunOutcome, .completed),
        timed_out.snapshot().last_outcome,
    );
    try closeSession(timed_out, .session_close);

    fake_core.setNextPlan(.malformed_ui_callback);
    const malformed = try openSession(host);
    const malformed_run = try submitSession(malformed, "malformed UI request");
    try malformed.waitRun(malformed_run);
    const malformed_snapshot = malformed.snapshot();
    try std.testing.expectEqual(@as(?u32, wire.STATUS_CALLBACK_FAILED), malformed_snapshot.last_status);
    try std.testing.expectEqual(@as(?lifecycle.HostCause, .ui_pipeline_failure), malformed_snapshot.cause);
    try std.testing.expectEqual(@as(?lifecycle.RunOutcome, .failed), malformed_snapshot.last_outcome);
    try closeSession(malformed, .session_close);
}

test "Gate 6 all executor workers waiting on UI remain controllable" {
    fake_core.reset();
    const host = try createHost(.{ .worker_count = 4, .queue_capacity = 4, .max_sessions = 4 });
    defer {
        shutdownHost(host) catch unreachable;
        deinitHost(host);
    }
    var sessions: [4]*lifecycle.Session = undefined;
    var run_ids: [4]u64 = undefined;
    for (&sessions, 0..) |*session, index| {
        fake_core.setNextPlan(.ui_wait);
        session.* = try openSession(host);
        run_ids[index] = try submitSession(session.*, "occupy executor with synchronous UI");
    }
    for (sessions) |session| try session.waitForState(.waiting_ui);

    const first_request = sessions[0].pendingUiRequest().?;
    try sessions[0].respondUi(run_ids[0], first_request, .{ .permission = .allow_once });
    try cancelSession(sessions[1], run_ids[1], .user_cancel);
    try closeSession(sessions[2], .session_close);
    fake_core.releaseControlled();
    try sessions[0].waitRun(run_ids[0]);
    try sessions[1].waitRun(run_ids[1]);
    try closeSession(sessions[0], .session_close);
    try closeSession(sessions[1], .session_close);

    try shutdownHost(host);
    fake_core.lock();
    const destroyed = fake_core.session_destroyed;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 4), destroyed);
}

test "UI response encoding is bounded before ownership transfer" {
    fake_core.reset();
    fake_core.setNextPlan(.ui_wait);
    const host = try createHost(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
        .max_ui_response_bytes = 8,
    });
    defer {
        shutdownHost(host) catch unreachable;
        deinitHost(host);
    }
    const session = try openSession(host);
    const run_id = try submitSession(session, "bound response");
    try session.waitForState(.waiting_ui);
    const request_id = session.pendingUiRequest().?;
    try std.testing.expectError(
        error.InvalidUiResponse,
        session.respondUi(run_id, request_id, .{ .permission = .allow_once }),
    );
    try std.testing.expectEqual(request_id, session.pendingUiRequest().?);
    try cancelSession(session, run_id, .user_cancel);
    try session.waitRun(run_id);
    try std.testing.expectEqual(
        @as(?lifecycle.RunOutcome, .cancelled),
        session.snapshot().last_outcome,
    );
    try closeSession(session, .session_close);
}

test "status is validated before RunResult and invalid results poison the Session" {
    fake_core.reset();
    const host = try createHost(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 3 });
    defer {
        shutdownHost(host) catch unreachable;
        deinitHost(host);
    }

    const cases = [_]struct {
        plan: Plan,
        expected_status: u32,
        expected_stop: ?u32,
    }{
        .{ .plan = .unknown_stop_result, .expected_status = wire.STATUS_OK, .expected_stop = 42 },
        .{ .plan = .invalid_result_layout, .expected_status = wire.STATUS_OK, .expected_stop = null },
        .{ .plan = .unknown_status, .expected_status = 42, .expected_stop = null },
    };
    for (cases) |case| {
        fake_core.setNextPlan(case.plan);
        const session = try openSession(host);
        const run_id = try submitSession(session, "validate result boundary");
        try session.waitRun(run_id);
        const snapshot = session.snapshot();
        try std.testing.expectEqual(@as(?u32, case.expected_status), snapshot.last_status);
        try std.testing.expectEqual(case.expected_stop, snapshot.last_stop_reason_code);
        try std.testing.expectEqual(
            @as(?lifecycle.HostCause, .dependency_contract_failure),
            snapshot.cause,
        );
        try std.testing.expectEqual(
            @as(?lifecycle.RunOutcome, .dependency_contract_failure),
            snapshot.last_outcome,
        );
        try std.testing.expectEqual(lifecycle.SessionState.poisoned, snapshot.state);
        try std.testing.expectError(error.SessionPoisoned, submitSession(session, "must not continue"));
        try closeSession(session, .session_close);
    }
}

test "concurrent close waits for callback quiescence and destroys once" {
    fake_core.reset();
    const host = try createHost(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
    defer {
        shutdownHost(host) catch unreachable;
        deinitHost(host);
    }
    const session = try openSession(host);
    try std.testing.expect(session.retainReference());
    const first = try std.Thread.spawn(.{}, closeOnThread, .{session});
    try session.waitForState(.closing);
    const second = try std.Thread.spawn(.{}, closeOnThread, .{session});

    fake_core.lock();
    const destroys_while_retained = fake_core.session_destroyed;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 0), destroys_while_retained);
    session.releaseReference();
    first.join();
    second.join();
    fake_core.lock();
    const final_destroy_count = fake_core.session_destroyed;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), final_destroy_count);
}

test "Host shutdown closes active queued and idle Sessions before Runtime" {
    fake_core.reset();
    fake_core.setNextPlan(.controlled);
    const host = try createHost(.{ .worker_count = 1, .queue_capacity = 2, .max_sessions = 3 });
    defer deinitHost(host);
    const active = try openSession(host);
    const queued = try openSession(host);
    _ = try openSession(host);
    _ = try submitSession(active, "active");
    try active.waitForState(.running);
    _ = try submitSession(queued, "queued");

    try shutdownHost(host);
    fake_core.lock();
    const session_destroyed = fake_core.session_destroyed;
    const runtime_destroyed = fake_core.runtime_destroyed;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 3), session_destroyed);
    try std.testing.expectEqual(@as(usize, 1), runtime_destroyed);
}

test "Runtime destroy while a Session is live returns busy without consuming ownership" {
    fake_core.reset();
    const host = try createHost(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
    defer {
        shutdownHost(host) catch unreachable;
        deinitHost(host);
    }
    const session = try openSession(host);
    var diagnostic_buffer = wire.OwnedBytesV1{ .ptr = null, .len = 0 };
    try std.testing.expectEqual(
        wire.STATUS_BUSY,
        runtimeDestroy(host.runtime, &diagnostic_buffer),
    );
    bufferRelease(&diagnostic_buffer);
    try closeSession(session, .session_close);
    try shutdownHost(host);

    fake_core.lock();
    const busy_attempts = fake_core.runtime_destroy_busy_attempts;
    const runtime_destroyed = fake_core.runtime_destroyed;
    const releases = fake_core.buffer_releases;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), busy_attempts);
    try std.testing.expectEqual(@as(usize, 1), runtime_destroyed);
    try std.testing.expectEqual(@as(usize, 1), releases);
}

test "transient Session and Runtime destroy failures are explicit and retryable" {
    fake_core.reset();
    const host = try createHost(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
    defer {
        shutdownHost(host) catch unreachable;
        deinitHost(host);
    }
    const session = try openSession(host);
    fake_core.failNextSessionDestroy();
    try std.testing.expectError(error.SessionDestroyFailed, closeSession(session, .session_close));
    try std.testing.expectEqual(lifecycle.SessionState.closing, session.snapshot().state);
    try closeSession(session, .session_close);

    fake_core.failNextRuntimeDestroy();
    try std.testing.expectError(error.RuntimeDestroyFailed, shutdownHost(host));
    try shutdownHost(host);
    fake_core.lock();
    const releases = fake_core.buffer_releases;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 2), releases);
}

test "Gate 6 Workbench closes off-thread and exposes retryable close failure" {
    fake_core.reset();
    const host = try createHost(.{ .worker_count = 1, .queue_capacity = 2, .max_sessions = 2 });
    defer {
        shutdownHost(host) catch unreachable;
        deinitHost(host);
    }
    var workbench = try host_workbench.Workbench.init(std.testing.allocator, host, .{
        .max_sessions = 2,
        .max_runs_per_session = 2,
        .max_tools_per_run = 2,
    });
    defer workbench.deinit();

    const session_id = try workbench.createSession(workbenchSessionOptions());
    fake_core.failNextSessionDestroy();
    try workbench.closeSession(session_id);
    try waitWorkbenchSnapshot(&workbench, "\"closeFailed\":true");

    try workbench.closeSession(session_id);
    try waitWorkbenchSnapshot(&workbench, "\"lifecycle\":\"closed\"");
    fake_core.lock();
    const destroyed = fake_core.session_destroyed;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), destroyed);
}

test "Gate 6 Workbench close cancels a queued Run without blocking the caller" {
    fake_core.reset();
    fake_core.setNextPlan(.controlled);
    const host = try createHost(.{ .worker_count = 1, .queue_capacity = 2, .max_sessions = 1 });
    defer {
        shutdownHost(host) catch unreachable;
        deinitHost(host);
    }
    var workbench = try host_workbench.Workbench.init(std.testing.allocator, host, .{
        .max_sessions = 1,
        .max_runs_per_session = 1,
        .max_tools_per_run = 1,
    });
    defer workbench.deinit();

    const session_id = try workbench.createSession(workbenchSessionOptions());
    _ = try workbench.submit(session_id, "close this run");
    try workbench.closeSession(session_id);
    try waitWorkbenchSnapshot(&workbench, "\"lifecycle\":\"closed\"");
    fake_core.lock();
    const abort_calls = fake_core.abort_calls;
    const destroyed = fake_core.session_destroyed;
    fake_core.unlock();
    try std.testing.expect(abort_calls <= 1);
    try std.testing.expectEqual(@as(usize, 1), destroyed);
}

test "Core Session creation failure releases diagnostics and leaves capacity reusable" {
    fake_core.reset();
    const host = try createHost(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
    defer {
        shutdownHost(host) catch unreachable;
        deinitHost(host);
    }
    fake_core.failNextSessionCreate();
    try std.testing.expectError(error.CoreCallFailed, openSession(host));
    const session = try openSession(host);
    try closeSession(session, .session_close);
    fake_core.lock();
    const releases = fake_core.buffer_releases;
    const creates = fake_core.session_created;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), creates);
    try std.testing.expectEqual(@as(usize, 1), releases);
}

test "closed Session storage is reused only after explicit Host release" {
    fake_core.reset();
    const host = try createHost(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
    defer {
        shutdownHost(host) catch unreachable;
        deinitHost(host);
    }
    const first = try openSession(host);
    try std.testing.expectError(error.SessionNotClosed, host.releaseClosedSession(first));
    try closeSession(first, .session_close);
    try std.testing.expectError(error.SessionCapacity, openSession(host));
    try host.releaseClosedSession(first);

    const second = try openSession(host);
    try closeSession(second, .session_close);
}

test "abort stale and too-late statuses remain observable without losing diagnostics" {
    fake_core.reset();
    fake_core.setNextPlan(.controlled);
    const host = try createHost(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
    defer {
        shutdownHost(host) catch unreachable;
        deinitHost(host);
    }
    const session = try openSession(host);

    const first = try submitSession(session, "too late");
    try session.waitForState(.running);
    try std.testing.expectError(error.NoSuchRun, cancelSession(session, first + 1, .user_cancel));
    fake_core.forceNextAbortStatus(wire.STATUS_TOO_LATE);
    try cancelSession(session, first, .user_cancel);
    try cancelSession(session, first, .user_cancel);
    fake_core.releaseControlled();
    try session.waitRun(first);
    try std.testing.expectEqual(@as(?u32, wire.STATUS_TOO_LATE), session.snapshot().last_abort_status);

    fake_core.rearmControlled();
    const second = try submitSession(session, "stale");
    try session.waitForState(.running);
    fake_core.forceNextAbortStatus(wire.STATUS_STALE_RUN);
    try cancelSession(session, second, .user_cancel);
    try cancelSession(session, second, .user_cancel);
    fake_core.releaseControlled();
    try session.waitRun(second);
    try std.testing.expectEqual(@as(?u32, wire.STATUS_STALE_RUN), session.snapshot().last_abort_status);

    fake_core.rearmControlled();
    const third = try submitSession(session, "timeout");
    try session.waitForState(.running);
    try cancelSession(session, third, .timeout);
    try session.waitRun(third);
    const timeout_snapshot = session.snapshot();
    try std.testing.expectEqual(@as(?u32, wire.STATUS_OK), timeout_snapshot.last_abort_status);
    try std.testing.expectEqual(@as(?lifecycle.HostCause, .timeout), timeout_snapshot.cause);
    try closeSession(session, .session_close);

    fake_core.lock();
    const releases = fake_core.buffer_releases;
    const abort_calls = fake_core.abort_calls;
    const last_abort_reason = fake_core.last_abort_reason;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 2), releases);
    try std.testing.expectEqual(@as(usize, 3), abort_calls);
    try std.testing.expectEqual(@as(?u32, wire.ABORT_TIMEOUT), last_abort_reason);
}

test "concurrent Host shutdown serializes executor and Runtime destruction" {
    fake_core.reset();
    const host = try createHost(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 2 });
    const session = try openSession(host);
    const not_yet_closed = try openSession(host);
    try std.testing.expect(session.retainReference());
    const first = try std.Thread.spawn(.{}, shutdownOnThread, .{host});
    try session.waitForState(.closing);
    try std.testing.expectError(error.HostShuttingDown, submitSession(not_yet_closed, "too late"));
    const second = try std.Thread.spawn(.{}, shutdownOnThread, .{host});
    std.Thread.yield() catch {};
    session.releaseReference();
    first.join();
    second.join();
    deinitHost(host);

    fake_core.lock();
    const runtime_destroyed = fake_core.runtime_destroyed;
    const session_destroyed = fake_core.session_destroyed;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 2), session_destroyed);
    try std.testing.expectEqual(@as(usize, 1), runtime_destroyed);
}

test "Host initialization OOM fails before acquiring the Runtime" {
    fake_core.reset();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 3 });
    try std.testing.expectError(error.OutOfMemory, lifecycle.Runtime.init(
        std.testing.io,
        failing.allocator(),
        &fake_api,
        .{ .max_sessions = 1 },
    ));
    try std.testing.expect(failing.has_induced_failure);
    fake_core.lock();
    const runtime_created = fake_core.runtime_created;
    const runtime_destroyed = fake_core.runtime_destroyed;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 0), runtime_created);
    try std.testing.expectEqual(@as(usize, 0), runtime_destroyed);
}

test "Session creation OOM leaves Host reusable and credential Host-only" {
    fake_core.reset();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const executor = try workbench_executor.Executor.create(
        std.testing.io,
        std.testing.allocator,
        .{ .worker_count = 1, .queue_capacity = 1 },
    );
    var executor_registered = false;
    errdefer if (!executor_registered) executor.deinit();
    const host = try lifecycle.Runtime.init(
        std.testing.io,
        failing.allocator(),
        &fake_api,
        .{ .max_sessions = 1 },
    );
    try registerTestHost(host, executor);
    executor_registered = true;
    defer {
        shutdownHost(host) catch unreachable;
        deinitHost(host);
    }
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, openSession(host));
    try std.testing.expect(failing.has_induced_failure);
    failing.fail_index = std.math.maxInt(usize);
    const session = try openSession(host);
    const snapshot = session.snapshot();
    try std.testing.expectEqualStrings("/tmp/metawork-gate2", snapshot.workspace_root);
    try std.testing.expect(fake_core.credential_seen);
    try closeSession(session, .session_close);
}

test "Gate 5 event pump preserves per-Session order with round-robin fairness" {
    var pump = try event_pump.EventPump.init(std.testing.io, std.testing.allocator, .{
        .global_count = 8,
        .global_bytes = 4096,
        .global_control_reserved_count = 2,
        .global_control_reserved_bytes = 512,
        .per_session_count = 4,
        .per_session_bytes = 2048,
        .per_session_control_reserved_count = 1,
        .per_session_control_reserved_bytes = 256,
        .session_slots = 2,
    });
    defer pump.deinit();

    try pump.enqueue(try pumpEnvelope(1, 1, "{\"text_chunk\":\"one\"}"));
    try pump.enqueue(try pumpEnvelope(1, 1, "{\"text_chunk\":\"two\"}"));
    try pump.enqueue(try pumpEnvelope(2, 1, "{\"text_chunk\":\"other\"}"));

    var first = pump.takeFair().?;
    defer first.deinit();
    var second = pump.takeFair().?;
    defer second.deinit();
    var third = pump.takeFair().?;
    defer third.deinit();
    try std.testing.expectEqual(@as(u64, 1), first.session_id);
    try std.testing.expectEqualStrings("one", try textChunk(first.event.value));
    try std.testing.expectEqual(@as(u64, 2), second.session_id);
    try std.testing.expectEqualStrings("other", try textChunk(second.event.value));
    try std.testing.expectEqual(@as(u64, 1), third.session_id);
    try std.testing.expectEqualStrings("two", try textChunk(third.event.value));
    try std.testing.expectEqual(@as(usize, 0), pump.stats().count);
}

test "Gate 5 data cannot consume reserved control capacity" {
    var pump = try event_pump.EventPump.init(std.testing.io, std.testing.allocator, .{
        .global_count = 4,
        .global_bytes = 1024,
        .global_control_reserved_count = 1,
        .global_control_reserved_bytes = 128,
        .per_session_count = 4,
        .per_session_bytes = 1024,
        .per_session_control_reserved_count = 1,
        .per_session_control_reserved_bytes = 128,
        .session_slots = 1,
    });
    defer pump.deinit();

    try pump.enqueue(try pumpEnvelope(1, 1, "{\"text_chunk\":\"a\"}"));
    try pump.enqueue(try pumpEnvelope(1, 1, "{\"text_chunk\":\"b\"}"));
    try pump.enqueue(try pumpEnvelope(1, 1, "{\"text_chunk\":\"c\"}"));
    var rejected = try pumpEnvelope(1, 1, "{\"text_chunk\":\"d\"}");
    try std.testing.expectError(error.GlobalCapacity, pump.enqueue(rejected));
    rejected.deinit();
    try pump.enqueue(try pumpEnvelope(1, 1, "{\"stream_done\":{}}"));
    const stats = pump.stats();
    try std.testing.expectEqual(@as(usize, 4), stats.count);
    try std.testing.expectEqual(@as(usize, 3), stats.data_count);
}

test "Gate 5 queues reject zero sentinel identities" {
    var pump = try event_pump.EventPump.init(std.testing.io, std.testing.allocator, .{
        .global_count = 2,
        .global_bytes = 512,
        .global_control_reserved_count = 0,
        .global_control_reserved_bytes = 0,
        .per_session_count = 2,
        .per_session_bytes = 512,
        .per_session_control_reserved_count = 0,
        .per_session_control_reserved_bytes = 0,
        .session_slots = 1,
    });
    defer pump.deinit();
    var invalid_pump = try pumpEnvelope(0, 1, "{\"text_chunk\":\"invalid\"}");
    try std.testing.expectError(error.InvalidIdentity, pump.enqueue(invalid_pump));
    invalid_pump.deinit();

    var delivery = try bridge_delivery.Delivery.init(std.testing.allocator, .{
        .inline_event_bytes = 64,
        .batch_count = 1,
        .batch_bytes = 256,
        .batch_sessions = 1,
        .batch_per_session = 1,
        .retention_count = 1,
        .retention_bytes = 128,
        .retention_ns = 100,
        .object_count = 1,
        .object_bytes = 64,
        .per_session_object_count = 1,
        .per_session_object_bytes = 64,
        .max_object_bytes = 64,
        .route_slots = 1,
    });
    defer delivery.deinit();
    var invalid_delivery = try deliveryInput(std.testing.allocator, 1, 0, "{}");
    try std.testing.expectError(error.InvalidIdentity, delivery.ingest(invalid_delivery));
    invalid_delivery.deinit();
}

test "Gate 5 delivery rejects configurations that cannot fit an inline envelope" {
    try std.testing.expectError(
        error.InvalidLimits,
        bridge_delivery.Delivery.init(std.testing.allocator, .{
            .inline_event_bytes = 97,
            .batch_count = 1,
            .batch_bytes = 256,
            .batch_sessions = 1,
            .batch_per_session = 1,
            .retention_count = 1,
            .retention_bytes = 256,
            .retention_ns = 100,
            .object_count = 1,
            .object_bytes = 128,
            .per_session_object_count = 1,
            .per_session_object_bytes = 128,
            .max_object_bytes = 128,
            .route_slots = 1,
        }),
    );
}

test "Gate 5 delivery batches inline events and generation-bound object references" {
    var pump = try event_pump.EventPump.init(std.testing.io, std.testing.allocator, .{
        .global_count = 8,
        .global_bytes = 4096,
        .global_control_reserved_count = 2,
        .global_control_reserved_bytes = 512,
        .per_session_count = 8,
        .per_session_bytes = 4096,
        .per_session_control_reserved_count = 2,
        .per_session_control_reserved_bytes = 512,
        .session_slots = 1,
    });
    defer pump.deinit();
    var delivery = try bridge_delivery.Delivery.init(std.testing.allocator, .{
        .inline_event_bytes = 64,
        .batch_count = 4,
        .batch_bytes = 512,
        .batch_sessions = 1,
        .batch_per_session = 4,
        .retention_count = 8,
        .retention_bytes = 4096,
        .retention_ns = 100,
        .object_count = 2,
        .object_bytes = 2048,
        .per_session_object_count = 2,
        .per_session_object_bytes = 2048,
        .max_object_bytes = 1024,
        .route_slots = 1,
    });
    defer delivery.deinit();

    try pump.enqueue(try pumpEnvelope(1, 7, "{\"text_chunk\":\"small\"}"));
    const large =
        "{\"text_chunk\":\"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\"}";
    try pump.enqueue(try pumpEnvelope(1, 7, large));
    try ingestPumpEvent(&delivery, &pump);
    try ingestPumpEvent(&delivery, &pump);
    const first_generation = try delivery.connect();
    var first_batch = (try delivery.buildBatch(first_generation)).?;
    defer first_batch.deinit();
    try std.testing.expectEqual(@as(usize, 2), first_batch.item_count);
    try std.testing.expect(std.mem.indexOf(u8, first_batch.json, "\"generation\":\"1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_batch.json, "\"event\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_batch.json, "\"object\":{\"id\":\"1\"") != null);
    var fetch_buffer: [2048]u8 = undefined;
    try std.testing.expectError(
        error.UnknownObject,
        delivery.fetchObject(first_generation, 1, 7, 1, &fetch_buffer),
    );
    var uncommitted_retry = (try delivery.buildBatch(first_generation)).?;
    defer uncommitted_retry.deinit();
    try std.testing.expectEqual(@as(usize, 2), uncommitted_retry.item_count);
    try delivery.commitBatch(&first_batch);

    const fetched = try delivery.fetchObject(first_generation, 1, 7, 1, &fetch_buffer);
    try std.testing.expect(std.mem.indexOf(u8, fetched, large) != null);
    try delivery.acknowledge(first_generation, 1, 7, 1);
    try delivery.acknowledge(first_generation, 1, 7, 1);
    try std.testing.expectEqual(@as(usize, 1), delivery.stats().retained_count);
    try std.testing.expectError(
        error.OutOfOrderAcknowledgement,
        delivery.acknowledge(first_generation, 1, 7, 3),
    );
    try delivery.detach(first_generation, 10);
    const second_generation = try delivery.connect();
    try std.testing.expectError(
        error.StaleConnection,
        delivery.fetchObject(first_generation, 1, 7, 1, &fetch_buffer),
    );
    var replay = (try delivery.buildBatch(second_generation)).?;
    defer replay.deinit();
    try std.testing.expectEqual(@as(usize, 1), replay.item_count);
    try delivery.commitBatch(&replay);
    try std.testing.expect(delivery.firstExpired(100) == null);
    try delivery.detach(second_generation, 100);
    try std.testing.expect(delivery.firstExpired(199) == null);
    const expired = delivery.firstExpired(200).?;
    try std.testing.expectEqual(@as(u64, 1), expired.session_id);
    try std.testing.expectEqual(@as(u64, 7), expired.run_id);
    const third_generation = try delivery.connect();
    var final_replay = (try delivery.buildBatch(third_generation)).?;
    defer final_replay.deinit();
    try delivery.commitBatch(&final_replay);
    delivery.cleanupRun(1, 7);
    try std.testing.expectError(
        error.UnknownObject,
        delivery.fetchObject(third_generation, 1, 7, 1, &fetch_buffer),
    );
}

test "Gate 5 delivery enforces retention and object budgets and releases on acknowledgement" {
    var delivery = try bridge_delivery.Delivery.init(std.testing.allocator, .{
        .inline_event_bytes = 16,
        .batch_count = 2,
        .batch_bytes = 256,
        .batch_sessions = 1,
        .batch_per_session = 2,
        .retention_count = 2,
        .retention_bytes = 256,
        .retention_ns = 100,
        .object_count = 1,
        .object_bytes = 128,
        .per_session_object_count = 1,
        .per_session_object_bytes = 128,
        .max_object_bytes = 128,
        .route_slots = 1,
    });
    defer delivery.deinit();

    const object_json = "{\"payload\":\"xxxxxxxxxxxxxxxx\"}";
    try delivery.ingest(try deliveryInput(std.testing.allocator, 1, 1, object_json));
    var rejected_object = try deliveryInput(std.testing.allocator, 1, 1, object_json);
    try std.testing.expectError(error.ObjectCapacity, delivery.ingest(rejected_object));
    rejected_object.deinit();
    try delivery.ingest(try deliveryInput(std.testing.allocator, 1, 1, "{}"));
    var rejected_retention = try deliveryInput(std.testing.allocator, 1, 1, "{}");
    try std.testing.expectError(error.RetentionCapacity, delivery.ingest(rejected_retention));
    rejected_retention.deinit();

    const generation = try delivery.connect();
    var batch = (try delivery.buildBatch(generation)).?;
    defer batch.deinit();
    try delivery.commitBatch(&batch);
    try delivery.acknowledge(generation, 1, 1, 1);
    const after_object_ack = delivery.stats();
    try std.testing.expectEqual(@as(usize, 1), after_object_ack.retained_count);
    try std.testing.expectEqual(@as(usize, 0), after_object_ack.object_count);
    try std.testing.expectEqual(@as(usize, 0), after_object_ack.object_bytes);
    try delivery.acknowledge(generation, 1, 1, 2);
    try std.testing.expectEqual(@as(usize, 0), delivery.stats().retained_count);
}

test "Gate 5 delivery batch is byte bounded and fair across Sessions" {
    var delivery = try bridge_delivery.Delivery.init(std.testing.allocator, .{
        .inline_event_bytes = 64,
        .batch_count = 4,
        .batch_bytes = 512,
        .batch_sessions = 2,
        .batch_per_session = 2,
        .retention_count = 8,
        .retention_bytes = 4096,
        .retention_ns = 100,
        .object_count = 2,
        .object_bytes = 512,
        .per_session_object_count = 1,
        .per_session_object_bytes = 256,
        .max_object_bytes = 256,
        .route_slots = 3,
    });
    defer delivery.deinit();
    for (0..3) |_| try delivery.ingest(try deliveryInput(std.testing.allocator, 1, 1, "{}"));
    for (0..2) |_| try delivery.ingest(try deliveryInput(std.testing.allocator, 2, 1, "{}"));
    try delivery.ingest(try deliveryInput(std.testing.allocator, 3, 1, "{}"));

    const generation = try delivery.connect();
    var first = (try delivery.buildBatch(generation)).?;
    defer first.deinit();
    try std.testing.expectEqual(@as(usize, 4), first.item_count);
    try std.testing.expect(first.json.len <= 512);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, first.json, "\"sessionId\":\"1\""));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, first.json, "\"sessionId\":\"2\""));
    try delivery.commitBatch(&first);
    var second = (try delivery.buildBatch(generation)).?;
    defer second.deinit();
    try std.testing.expectEqual(@as(usize, 2), second.item_count);
    try std.testing.expect(std.mem.indexOf(u8, second.json, "\"sessionId\":\"3\"") != null);
    try delivery.commitBatch(&second);
}

test "Gate 5 delivery OOM does not mark an event sent" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var delivery = try bridge_delivery.Delivery.init(failing.allocator(), .{
        .inline_event_bytes = 64,
        .batch_count = 1,
        .batch_bytes = 256,
        .batch_sessions = 1,
        .batch_per_session = 1,
        .retention_count = 1,
        .retention_bytes = 128,
        .retention_ns = 100,
        .object_count = 1,
        .object_bytes = 64,
        .per_session_object_count = 1,
        .per_session_object_bytes = 64,
        .max_object_bytes = 64,
        .route_slots = 1,
    });
    defer delivery.deinit();
    try delivery.ingest(try deliveryInput(std.testing.allocator, 1, 1, "{}"));
    const generation = try delivery.connect();
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, delivery.buildBatch(generation));
    try std.testing.expect(failing.has_induced_failure);
    failing.fail_index = std.math.maxInt(usize);
    var retry = (try delivery.buildBatch(generation)).?;
    defer retry.deinit();
    try std.testing.expectEqual(@as(usize, 1), retry.item_count);
}

test "Gate 5 delivery rejects a batch built by another owner" {
    const limits = bridge_delivery.Limits{
        .inline_event_bytes = 64,
        .batch_count = 1,
        .batch_bytes = 256,
        .batch_sessions = 1,
        .batch_per_session = 1,
        .retention_count = 1,
        .retention_bytes = 128,
        .retention_ns = 100,
        .object_count = 1,
        .object_bytes = 64,
        .per_session_object_count = 1,
        .per_session_object_bytes = 64,
        .max_object_bytes = 64,
        .route_slots = 1,
    };
    var first = try bridge_delivery.Delivery.init(std.testing.allocator, limits);
    defer first.deinit();
    var second = try bridge_delivery.Delivery.init(std.testing.allocator, limits);
    defer second.deinit();
    try first.ingest(try deliveryInput(std.testing.allocator, 1, 1, "{}"));
    const generation = try first.connect();
    _ = try second.connect();
    var batch = (try first.buildBatch(generation)).?;
    defer batch.deinit();
    try std.testing.expectError(error.ForeignBatch, second.commitBatch(&batch));
    try first.commitBatch(&batch);
}

test "Gate 5 text chunks remain byte lossless through the event pump" {
    var pump = try event_pump.EventPump.init(std.testing.io, std.testing.allocator, .{
        .global_count = 4,
        .global_bytes = 1024,
        .global_control_reserved_count = 1,
        .global_control_reserved_bytes = 128,
        .per_session_count = 4,
        .per_session_bytes = 1024,
        .per_session_control_reserved_count = 1,
        .per_session_control_reserved_bytes = 128,
        .session_slots = 1,
    });
    defer pump.deinit();
    try pump.enqueue(try pumpEnvelope(1, 1, "{\"text_chunk\":\"hello \"}"));
    try pump.enqueue(try pumpEnvelope(1, 1, "{\"text_chunk\":\"世界\"}"));
    try pump.enqueue(try pumpEnvelope(1, 1, "{\"text_chunk\":\"!\"}"));
    var storage: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    while (pump.takeFair()) |value| {
        var event = value;
        try writer.writeAll(try textChunk(event.event.value));
        event.deinit();
    }
    try std.testing.expectEqualStrings("hello 世界!", writer.buffered());
}

test "Gate 5 enqueue waits for a slow consumer and fails at the hard deadline" {
    var pump = try event_pump.EventPump.init(std.testing.io, std.testing.allocator, .{
        .global_count = 1,
        .global_bytes = 1024,
        .global_control_reserved_count = 0,
        .global_control_reserved_bytes = 0,
        .per_session_count = 1,
        .per_session_bytes = 1024,
        .per_session_control_reserved_count = 0,
        .per_session_control_reserved_bytes = 0,
        .session_slots = 1,
    });
    defer pump.deinit();
    try pump.enqueue(try pumpEnvelope(1, 1, "{\"text_chunk\":\"first\"}"));
    var context = PumpEnqueueContext{
        .pump = &pump,
        .envelope = try pumpEnvelope(1, 1, "{\"text_chunk\":\"second\"}"),
        .timeout = .fromSeconds(1),
    };
    const thread = try std.Thread.spawn(.{}, enqueuePumpOnThread, .{&context});
    try std.testing.io.sleep(.fromMilliseconds(20), .awake);
    var first = pump.takeFair().?;
    first.deinit();
    thread.join();
    try std.testing.expect(context.succeeded);
    try std.testing.expect(context.failure == null);
    var second = pump.takeFair().?;
    second.deinit();

    try pump.enqueue(try pumpEnvelope(1, 1, "{\"text_chunk\":\"third\"}"));
    var timed_out = try pumpEnvelope(1, 1, "{\"text_chunk\":\"fourth\"}");
    try std.testing.expectError(
        error.DeadlineExceeded,
        pump.enqueueWithDeadline(timed_out, .fromMilliseconds(5)),
    );
    timed_out.deinit();
    var third = pump.takeFair().?;
    third.deinit();
}

test "post-callback canonical pipeline failure aborts the routed Run as failed" {
    fake_core.reset();
    fake_core.setNextPlan(.controlled);
    const host = try createHost(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
    defer {
        shutdownHost(host) catch unreachable;
        deinitHost(host);
    }
    const session = try openSession(host);
    const run_id = try submitSession(session, "fail after callback returned");
    try session.waitForState(.running);
    const session_id = session.snapshot().session_id;
    try host.failRun(session_id, run_id, .event_pipeline_failure);
    try session.waitRun(run_id);
    const snapshot = session.snapshot();
    try std.testing.expectEqual(
        @as(?lifecycle.HostCause, .event_pipeline_failure),
        snapshot.cause,
    );
    try std.testing.expectEqual(@as(?lifecycle.RunOutcome, .failed), snapshot.last_outcome);
    try std.testing.expectEqual(@as(?u32, wire.STATUS_OK), snapshot.last_abort_status);
    try closeSession(session, .session_close);
}
