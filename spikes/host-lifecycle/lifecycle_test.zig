const std = @import("std");
const lifecycle = @import("host_lifecycle");
const sdk = @import("metacodes_agentcore");
const wire = sdk.types;

const Plan = enum {
    immediate,
    controlled,
    ui_wait,
    callback_failed,
    controlled_callback_failed,
    event_callback,
    malformed_event_callback,
    malformed_ui_callback,
    suspended_result,
    backgrounded_result,
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

    if (plan == .event_callback or plan == .malformed_event_callback) {
        const callback = session.callbacks.on_event orelse {
            diagnostic(out_error);
            return wire.STATUS_CALLBACK_FAILED;
        };
        var event_buffer = "{\"text_chunk\":\"typed event\"}".*;
        const event_json: []const u8 = if (plan == .event_callback) &event_buffer else "{}";
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
            .suspended_result => wire.STOP_SUSPENDED,
            .backgrounded_result => wire.STOP_BACKGROUNDED,
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

fn openSession(host: *lifecycle.Host) !*lifecycle.Session {
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

fn createHost(limits: lifecycle.Limits) !*lifecycle.Host {
    return lifecycle.Host.init(std.testing.io, std.testing.allocator, &fake_api, limits);
}

fn closeOnThread(session: *lifecycle.Session) void {
    session.close(.session_close) catch unreachable;
}

fn cancelOnThread(session: *lifecycle.Session, run_id: u64) void {
    session.requestCancel(run_id, .user_cancel) catch unreachable;
}

fn failPipelineOnThread(session: *lifecycle.Session) void {
    session.recordCause(.event_pipeline_failure);
}

fn shutdownOnThread(host: *lifecycle.Host) void {
    host.shutdown() catch unreachable;
}

test "Host creates and destroys Runtime and idle Session" {
    fake_core.reset();
    const host = try lifecycle.Host.init(std.testing.io, std.testing.allocator, &fake_api, .{
        .worker_count = 1,
        .queue_capacity = 2,
        .max_sessions = 2,
    });
    defer host.deinit();
    const session = try openSession(host);
    try std.testing.expect(fake_core.credential_seen);
    try std.testing.expect(fake_core.zero_host_tools_seen);
    try std.testing.expect(fake_core.builtin_allowlist_seen);
    try std.testing.expectEqual(lifecycle.SessionState.idle, session.snapshot().state);
    try session.close(.session_close);
    try session.close(.session_close);
    try host.shutdown();
    try host.shutdown();
    try std.testing.expectEqual(@as(usize, 1), fake_core.runtime_created);
    try std.testing.expectEqual(@as(usize, 1), fake_core.runtime_destroyed);
    try std.testing.expectEqual(@as(usize, 1), fake_core.session_destroyed);
}

test "Workspace requires an absolute temporary or explicit trusted root" {
    fake_core.reset();
    const host = try lifecycle.Host.init(std.testing.io, std.testing.allocator, &fake_api, .{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
    });
    defer {
        host.shutdown() catch unreachable;
        host.deinit();
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
        host.shutdown() catch unreachable;
        host.deinit();
    }
    const running = try openSession(host);
    const queued = try openSession(host);
    const rejected = try openSession(host);

    const running_id = try running.submit("hold worker");
    try running.waitForState(.running);
    _ = try queued.submit("stay queued");
    try std.testing.expectError(error.SessionNotIdle, queued.submit("second in-flight"));
    try std.testing.expectError(error.QueueFull, rejected.submit("overflow"));
    try std.testing.expectEqual(lifecycle.SessionState.idle, rejected.snapshot().state);

    try queued.close(.session_close);
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
    try running.close(.session_close);
    try rejected.close(.session_close);
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
        host.shutdown() catch unreachable;
        host.deinit();
    }
    const session = try openSession(host);
    try std.testing.expectError(error.PromptTooLarge, session.submit("12345"));
    try std.testing.expectEqual(lifecycle.SessionState.idle, session.snapshot().state);
    try session.close(.session_close);
}

test "closing an active Run aborts, joins, and preserves the first HostCause" {
    fake_core.reset();
    fake_core.setNextPlan(.controlled_callback_failed);
    const host = try createHost(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
    defer {
        host.shutdown() catch unreachable;
        host.deinit();
    }
    const session = try openSession(host);
    const run_id = try session.submit("race cancel with callback failure");
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
    try session.close(.session_close);
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
        host.shutdown() catch unreachable;
        host.deinit();
    }
    const session = try openSession(host);
    const run_id = try session.submit("emit malformed event");
    try session.waitRun(run_id);
    const snapshot = session.snapshot();
    try std.testing.expectEqual(@as(?u32, wire.STATUS_CALLBACK_FAILED), snapshot.last_status);
    try std.testing.expectEqual(
        @as(?lifecycle.HostCause, .event_pipeline_failure),
        snapshot.cause,
    );
    try std.testing.expect(host.takeEvent() == null);
    try session.close(.session_close);
    fake_core.lock();
    const releases = fake_core.buffer_releases;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), releases);
}

test "typed Core events are deep-copied into a bounded routed sink" {
    fake_core.reset();
    fake_core.setNextPlan(.event_callback);
    const host = try createHost(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
        .event_capacity = 2,
    });
    defer {
        host.shutdown() catch unreachable;
        host.deinit();
    }
    const session = try openSession(host);
    const first_run = try session.submit("emit typed event");
    try session.waitRun(first_run);
    const first_snapshot = session.snapshot();
    try std.testing.expectEqual(@as(?u32, wire.STATUS_OK), first_snapshot.last_status);
    try std.testing.expectEqual(@as(?u32, wire.STOP_END_TURN), first_snapshot.last_stop_reason_code);
    try std.testing.expectEqual(@as(?lifecycle.RunOutcome, .completed), first_snapshot.last_outcome);

    const second_run = try session.submit("preserve FIFO order");
    try session.waitRun(second_run);
    const second_snapshot = session.snapshot();
    try std.testing.expectEqual(@as(?lifecycle.RunOutcome, .completed), second_snapshot.last_outcome);

    var envelope = host.takeEvent().?;
    defer envelope.deinit();
    try std.testing.expect(envelope.session_id != 0);
    try std.testing.expectEqual(first_run, envelope.run_id);
    try std.testing.expectEqualStrings("typed event", envelope.event.value.text_chunk);
    var second = host.takeEvent().?;
    try std.testing.expectEqual(second_run, second.run_id);
    second.deinit();
    try session.close(.session_close);
}

test "bounded event sink overflow returns callback fatal and preserves HostCause" {
    fake_core.reset();
    fake_core.setNextPlan(.event_callback);
    const host = try createHost(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
        .event_capacity = 1,
    });
    defer {
        host.shutdown() catch unreachable;
        host.deinit();
    }
    const session = try openSession(host);
    const first_run = try session.submit("retain first event");
    try session.waitRun(first_run);
    const second_run = try session.submit("overflow sink");
    try session.waitRun(second_run);
    const snapshot = session.snapshot();
    try std.testing.expectEqual(@as(?u32, wire.STATUS_CALLBACK_FAILED), snapshot.last_status);
    try std.testing.expectEqual(@as(?lifecycle.HostCause, .queue_capacity_failure), snapshot.cause);
    try std.testing.expectEqual(@as(?lifecycle.RunOutcome, .failed), snapshot.last_outcome);
    var retained = host.takeEvent().?;
    retained.deinit();
    try session.close(.session_close);
}

test "UI request validates identity and close wakes a suspended callback" {
    fake_core.reset();
    fake_core.setNextPlan(.ui_wait);
    const host = try createHost(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 3 });
    defer {
        host.shutdown() catch unreachable;
        host.deinit();
    }
    const answered = try openSession(host);
    const run_id = try answered.submit("request UI");
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
        answered.respondUi(run_id, request_id, .{ .custom = "{}" }),
    );
    try answered.respondUi(run_id, request_id, response);
    try std.testing.expectError(error.StaleUiResponse, answered.respondUi(run_id, request_id, response));
    fake_core.releaseControlled();
    try answered.waitRun(run_id);
    try answered.close(.session_close);

    fake_core.setNextPlan(.ui_wait);
    const closing = try openSession(host);
    _ = try closing.submit("close while UI waits");
    try closing.waitForState(.waiting_ui);
    try closing.close(.session_close);
    const snapshot = closing.snapshot();
    try std.testing.expectEqual(lifecycle.SessionState.closed, snapshot.state);
    try std.testing.expectEqual(@as(?lifecycle.HostCause, .session_close), snapshot.cause);

    fake_core.setNextPlan(.ui_wait);
    const cancelled = try openSession(host);
    const cancelled_run = try cancelled.submit("cancel while UI waits");
    try cancelled.waitForState(.waiting_ui);
    try cancelled.requestCancel(cancelled_run, .user_cancel);
    try cancelled.waitRun(cancelled_run);
    try std.testing.expectEqual(
        @as(?lifecycle.HostCause, .user_cancel),
        cancelled.snapshot().cause,
    );
    try cancelled.close(.session_close);
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
        host.shutdown() catch unreachable;
        host.deinit();
    }
    const timed_out = try openSession(host);
    const timeout_run = try timed_out.submit("let UI expire");
    try timed_out.waitForState(.waiting_ui);
    try timed_out.waitForState(.running);
    try std.testing.expect(timed_out.pendingUiRequest() == null);
    fake_core.releaseControlled();
    try timed_out.waitRun(timeout_run);
    try std.testing.expectEqual(
        @as(?lifecycle.RunOutcome, .completed),
        timed_out.snapshot().last_outcome,
    );
    try timed_out.close(.session_close);

    fake_core.setNextPlan(.malformed_ui_callback);
    const malformed = try openSession(host);
    const malformed_run = try malformed.submit("malformed UI request");
    try malformed.waitRun(malformed_run);
    const malformed_snapshot = malformed.snapshot();
    try std.testing.expectEqual(@as(?u32, wire.STATUS_CALLBACK_FAILED), malformed_snapshot.last_status);
    try std.testing.expectEqual(@as(?lifecycle.HostCause, .ui_pipeline_failure), malformed_snapshot.cause);
    try std.testing.expectEqual(@as(?lifecycle.RunOutcome, .failed), malformed_snapshot.last_outcome);
    try malformed.close(.session_close);
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
        host.shutdown() catch unreachable;
        host.deinit();
    }
    const session = try openSession(host);
    const run_id = try session.submit("bound response");
    try session.waitForState(.waiting_ui);
    const request_id = session.pendingUiRequest().?;
    try std.testing.expectError(
        error.InvalidUiResponse,
        session.respondUi(run_id, request_id, .{ .permission = .allow_once }),
    );
    try std.testing.expectEqual(request_id, session.pendingUiRequest().?);
    try session.requestCancel(run_id, .user_cancel);
    try session.waitRun(run_id);
    try std.testing.expectEqual(
        @as(?lifecycle.RunOutcome, .cancelled),
        session.snapshot().last_outcome,
    );
    try session.close(.session_close);
}

test "status is validated before RunResult and unsupported stop reasons fail dependency contract" {
    fake_core.reset();
    const host = try createHost(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 5 });
    defer {
        host.shutdown() catch unreachable;
        host.deinit();
    }

    const cases = [_]struct {
        plan: Plan,
        expected_status: u32,
        expected_stop: ?u32,
    }{
        .{ .plan = .suspended_result, .expected_status = wire.STATUS_OK, .expected_stop = wire.STOP_SUSPENDED },
        .{ .plan = .backgrounded_result, .expected_status = wire.STATUS_OK, .expected_stop = wire.STOP_BACKGROUNDED },
        .{ .plan = .unknown_stop_result, .expected_status = wire.STATUS_OK, .expected_stop = 42 },
        .{ .plan = .invalid_result_layout, .expected_status = wire.STATUS_OK, .expected_stop = null },
        .{ .plan = .unknown_status, .expected_status = 42, .expected_stop = null },
    };
    for (cases) |case| {
        fake_core.setNextPlan(case.plan);
        const session = try openSession(host);
        const run_id = try session.submit("validate result boundary");
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
        try session.close(.session_close);
    }
}

test "concurrent close waits for callback quiescence and destroys once" {
    fake_core.reset();
    const host = try createHost(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
    defer {
        host.shutdown() catch unreachable;
        host.deinit();
    }
    const session = try openSession(host);
    try std.testing.expect(session.retainCallback());
    const first = try std.Thread.spawn(.{}, closeOnThread, .{session});
    try session.waitForState(.closing);
    const second = try std.Thread.spawn(.{}, closeOnThread, .{session});

    fake_core.lock();
    const destroys_while_retained = fake_core.session_destroyed;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 0), destroys_while_retained);
    session.releaseCallback();
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
    defer host.deinit();
    const active = try openSession(host);
    const queued = try openSession(host);
    _ = try openSession(host);
    _ = try active.submit("active");
    try active.waitForState(.running);
    _ = try queued.submit("queued");

    try host.shutdown();
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
        host.shutdown() catch unreachable;
        host.deinit();
    }
    const session = try openSession(host);
    var diagnostic_buffer = wire.OwnedBytesV1{ .ptr = null, .len = 0 };
    try std.testing.expectEqual(
        wire.STATUS_BUSY,
        runtimeDestroy(host.runtime, &diagnostic_buffer),
    );
    bufferRelease(&diagnostic_buffer);
    try session.close(.session_close);
    try host.shutdown();

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
        host.shutdown() catch unreachable;
        host.deinit();
    }
    const session = try openSession(host);
    fake_core.failNextSessionDestroy();
    try std.testing.expectError(error.SessionDestroyFailed, session.close(.session_close));
    try std.testing.expectEqual(lifecycle.SessionState.closing, session.snapshot().state);
    try session.close(.session_close);

    fake_core.failNextRuntimeDestroy();
    try std.testing.expectError(error.RuntimeDestroyFailed, host.shutdown());
    try host.shutdown();
    fake_core.lock();
    const releases = fake_core.buffer_releases;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 2), releases);
}

test "Core Session creation failure releases diagnostics and leaves capacity reusable" {
    fake_core.reset();
    const host = try createHost(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
    defer {
        host.shutdown() catch unreachable;
        host.deinit();
    }
    fake_core.failNextSessionCreate();
    try std.testing.expectError(error.CoreCallFailed, openSession(host));
    const session = try openSession(host);
    try session.close(.session_close);
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
        host.shutdown() catch unreachable;
        host.deinit();
    }
    const first = try openSession(host);
    try std.testing.expectError(error.SessionNotClosed, host.releaseClosedSession(first));
    try first.close(.session_close);
    try std.testing.expectError(error.SessionCapacity, openSession(host));
    try host.releaseClosedSession(first);

    const second = try openSession(host);
    try second.close(.session_close);
}

test "abort stale and too-late statuses remain observable without losing diagnostics" {
    fake_core.reset();
    fake_core.setNextPlan(.controlled);
    const host = try createHost(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
    defer {
        host.shutdown() catch unreachable;
        host.deinit();
    }
    const session = try openSession(host);

    const first = try session.submit("too late");
    try session.waitForState(.running);
    try std.testing.expectError(error.NoSuchRun, session.requestCancel(first + 1, .user_cancel));
    fake_core.forceNextAbortStatus(wire.STATUS_TOO_LATE);
    try session.requestCancel(first, .user_cancel);
    try session.requestCancel(first, .user_cancel);
    fake_core.releaseControlled();
    try session.waitRun(first);
    try std.testing.expectEqual(@as(?u32, wire.STATUS_TOO_LATE), session.snapshot().last_abort_status);

    fake_core.rearmControlled();
    const second = try session.submit("stale");
    try session.waitForState(.running);
    fake_core.forceNextAbortStatus(wire.STATUS_STALE_RUN);
    try session.requestCancel(second, .user_cancel);
    try session.requestCancel(second, .user_cancel);
    fake_core.releaseControlled();
    try session.waitRun(second);
    try std.testing.expectEqual(@as(?u32, wire.STATUS_STALE_RUN), session.snapshot().last_abort_status);

    fake_core.rearmControlled();
    const third = try session.submit("timeout");
    try session.waitForState(.running);
    try session.requestCancel(third, .timeout);
    try session.waitRun(third);
    const timeout_snapshot = session.snapshot();
    try std.testing.expectEqual(@as(?u32, wire.STATUS_OK), timeout_snapshot.last_abort_status);
    try std.testing.expectEqual(@as(?lifecycle.HostCause, .timeout), timeout_snapshot.cause);
    try session.close(.session_close);

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
    try std.testing.expect(session.retainCallback());
    const first = try std.Thread.spawn(.{}, shutdownOnThread, .{host});
    try session.waitForState(.closing);
    try std.testing.expectError(error.HostShuttingDown, not_yet_closed.submit("too late"));
    const second = try std.Thread.spawn(.{}, shutdownOnThread, .{host});
    std.Thread.yield() catch {};
    session.releaseCallback();
    first.join();
    second.join();
    host.deinit();

    fake_core.lock();
    const runtime_destroyed = fake_core.runtime_destroyed;
    const session_destroyed = fake_core.session_destroyed;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 2), session_destroyed);
    try std.testing.expectEqual(@as(usize, 1), runtime_destroyed);
}

test "Host initialization OOM destroys the already-created Runtime" {
    fake_core.reset();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 3 });
    try std.testing.expectError(error.OutOfMemory, lifecycle.Host.init(
        std.testing.io,
        failing.allocator(),
        &fake_api,
        .{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 },
    ));
    try std.testing.expect(failing.has_induced_failure);
    fake_core.lock();
    const runtime_created = fake_core.runtime_created;
    const runtime_destroyed = fake_core.runtime_destroyed;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), runtime_created);
    try std.testing.expectEqual(@as(usize, 1), runtime_destroyed);
}

test "Session creation OOM leaves Host reusable and credential Host-only" {
    fake_core.reset();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const host = try lifecycle.Host.init(
        std.testing.io,
        failing.allocator(),
        &fake_api,
        .{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 },
    );
    defer {
        host.shutdown() catch unreachable;
        host.deinit();
    }
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, openSession(host));
    try std.testing.expect(failing.has_induced_failure);
    failing.fail_index = std.math.maxInt(usize);
    const session = try openSession(host);
    const snapshot = session.snapshot();
    try std.testing.expectEqualStrings("/tmp/metawork-gate2", snapshot.workspace_root);
    try std.testing.expect(fake_core.credential_seen);
    try session.close(.session_close);
}
