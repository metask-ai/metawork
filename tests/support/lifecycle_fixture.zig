pub const std = @import("std");
pub const lifecycle = @import("metawork_agent");
pub const workbench_api = @import("metawork_workbench");
pub const account_contract = @import("metawork_account_contract");
pub const event_pump = @import("event_pump");
pub const workbench_executor = @import("workbench_executor");
pub const sdk = @import("metask_agentcore");
pub const wire = sdk.types;

pub fn pumpEnvelope(session_id: u64, run_id: u64, json: []const u8) !event_pump.OwnedCoreEvent {
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

pub fn textChunk(event: sdk.DecodedCoreEvent) ![]const u8 {
    return switch (event) {
        .known => |known| switch (known) {
            .text_chunk => |text| text,
            else => error.UnexpectedEvent,
        },
        .unknown => error.UnexpectedEvent,
    };
}

pub const PumpEnqueueContext = struct {
    pump: *event_pump.EventPump,
    envelope: event_pump.OwnedCoreEvent,
    timeout: std.Io.Duration,
    succeeded: bool = false,
    failure: ?event_pump.Error = null,
};

pub fn enqueuePumpOnThread(context: *PumpEnqueueContext) void {
    context.pump.enqueueWithDeadline(context.envelope, context.timeout) catch |err| {
        context.failure = err;
        return;
    };
    context.succeeded = true;
}

pub const Plan = enum {
    immediate,
    controlled,
    ui_wait,
    callback_failed,
    controlled_callback_failed,
    event_callback,
    unknown_event_callback,
    malformed_event_callback,
    wrong_event_session_handle,
    wrong_event_run_id,
    same_run_session_id_mismatch,
    concurrent_session_id_mismatch,
    cross_run_session_id_mismatch,
    ui_callback_outlives_run,
    malformed_ui_callback,
    resource_limit,
    unknown_stop_result,
    invalid_result_layout,
    unknown_status,
};

pub const FakeRuntime = struct {};

pub const CallbackSignal = struct {
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    armed: bool = false,
    entered: bool = false,
    finished: bool = false,

    pub fn notify(context: ?*anyopaque) lifecycle.EventReadyNotification {
        const self: *CallbackSignal = @ptrCast(@alignCast(context orelse
            return .unavailable));
        self.mutex.lockUncancelable(std.testing.io);
        if (!self.armed) {
            self.mutex.unlock(std.testing.io);
            return .already_pending;
        }
        self.entered = true;
        self.condition.broadcast(std.testing.io);
        self.mutex.unlock(std.testing.io);
        return .scheduled;
    }

    pub fn arm(self: *CallbackSignal) void {
        self.mutex.lockUncancelable(std.testing.io);
        self.armed = true;
        self.entered = false;
        self.finished = false;
        self.mutex.unlock(std.testing.io);
    }

    pub fn waitUntilEntered(self: *CallbackSignal) void {
        self.mutex.lockUncancelable(std.testing.io);
        defer self.mutex.unlock(std.testing.io);
        while (!self.entered)
            self.condition.waitUncancelable(std.testing.io, &self.mutex);
    }

    pub fn markFinished(self: *CallbackSignal) void {
        self.mutex.lockUncancelable(std.testing.io);
        self.finished = true;
        self.condition.broadcast(std.testing.io);
        self.mutex.unlock(std.testing.io);
    }

    pub fn waitUntilFinished(self: *CallbackSignal) void {
        self.mutex.lockUncancelable(std.testing.io);
        defer self.mutex.unlock(std.testing.io);
        while (!self.finished)
            self.condition.waitUncancelable(std.testing.io, &self.mutex);
    }
};

pub const FakeSession = struct {
    in_use: bool = false,
    running: bool = false,
    destroyed: bool = false,
    plan: Plan = .immediate,
    callbacks: wire.SessionCallbacksV1 = std.mem.zeroes(wire.SessionCallbacksV1),
    session_id: [wire.MAX_SESSION_ID_BYTES_V1]u8 = [_]u8{0} ** wire.MAX_SESSION_ID_BYTES_V1,
    session_id_len: usize = 0,
    run_id: u64 = 0,
    abort_requested: bool = false,
    allow_finish: bool = false,
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,

    pub fn lock(self: *FakeSession) void {
        self.mutex.lockUncancelable(std.testing.io);
    }

    pub fn unlock(self: *FakeSession) void {
        self.mutex.unlock(std.testing.io);
    }

    pub fn wait(self: *FakeSession) void {
        self.condition.waitUncancelable(std.testing.io, &self.mutex);
    }

    pub fn broadcast(self: *FakeSession) void {
        self.condition.broadcast(std.testing.io);
    }
};

pub const FakeCore = struct {
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
    ui_answered_callbacks: usize = 0,
    ui_fatal_callbacks: usize = 0,
    callback_signal: ?*CallbackSignal = null,

    pub fn lock(self: *FakeCore) void {
        self.mutex.lockUncancelable(std.testing.io);
    }

    pub fn unlock(self: *FakeCore) void {
        self.mutex.unlock(std.testing.io);
    }

    pub fn reset(self: *FakeCore) void {
        self.* = .{};
    }

    pub fn setNextPlan(self: *FakeCore, plan: Plan) void {
        self.lock();
        self.next_plan = plan;
        self.unlock();
    }

    pub fn releaseControlled(self: *FakeCore) void {
        for (&self.sessions) |*session| {
            session.lock();
            session.allow_finish = true;
            session.broadcast();
            session.unlock();
        }
    }

    pub fn rearmControlled(self: *FakeCore) void {
        for (&self.sessions) |*session| {
            session.lock();
            session.allow_finish = false;
            session.abort_requested = false;
            session.unlock();
        }
    }

    pub fn failNextSessionDestroy(self: *FakeCore) void {
        self.lock();
        self.session_destroy_failures += 1;
        self.unlock();
    }

    pub fn failNextRuntimeDestroy(self: *FakeCore) void {
        self.lock();
        self.runtime_destroy_failures += 1;
        self.unlock();
    }

    pub fn failNextSessionCreate(self: *FakeCore) void {
        self.lock();
        self.session_create_failures += 1;
        self.unlock();
    }

    pub fn forceNextAbortStatus(self: *FakeCore, status: u32) void {
        self.lock();
        self.forced_abort_status = status;
        self.unlock();
    }

    pub fn setCallbackSignal(self: *FakeCore, signal: ?*CallbackSignal) void {
        self.lock();
        self.callback_signal = signal;
        self.unlock();
    }

    pub fn invokeRunningIdentityMismatch(self: *FakeCore) ?u32 {
        for (&self.sessions) |*session| {
            session.lock();
            if (!session.in_use or !session.running) {
                session.unlock();
                continue;
            }
            const callback = session.callbacks.on_event orelse {
                session.unlock();
                return null;
            };
            const callback_context = session.callbacks.ctx;
            const run_id = session.run_id;
            session.unlock();

            var run = std.mem.zeroes(wire.RunContextV1);
            run.struct_size = @sizeOf(wire.RunContextV1);
            run.session = @ptrCast(session);
            run.run_id = run_id;
            run.session_id = sdk.bytesView("mismatched-ui-session");
            return callback(
                callback_context,
                &run,
                sdk.bytesView("{\"text_chunk\":\"must fail\"}"),
            );
        }
        return null;
    }
};

pub var fake_core = FakeCore{};
pub var diagnostic_byte: u8 = 0xA5;

pub fn diagnostic(out: ?*wire.OwnedBytesV1) void {
    if (out) |value| value.* = .{ .ptr = @ptrCast(&diagnostic_byte), .len = 1 };
}

pub fn runtimeCreate(
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

pub fn runtimeDestroy(
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

pub fn sessionCreate(
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
            var session_id = [_]u8{0} ** wire.MAX_SESSION_ID_BYTES_V1;
            const id = std.fmt.bufPrint(
                &session_id,
                "fake-session-{d}",
                .{fake_core.session_created + 1},
            ) catch {
                diagnostic(out_error);
                return wire.STATUS_OUT_OF_MEMORY;
            };
            session.* = .{
                .in_use = true,
                .plan = fake_core.next_plan,
                .callbacks = callbacks.?.*,
                .session_id = session_id,
                .session_id_len = id.len,
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

pub fn runtimeQuerySkillCatalog(
    _: ?*wire.RuntimeHandle,
    _: ?*const wire.SkillCatalogQueryV1,
    _: ?*?*wire.SkillCatalogHandle,
    _: ?*wire.OwnedBytesV1,
    out_error: ?*wire.OwnedBytesV1,
) callconv(.c) u32 {
    if (out_error) |out| out.* = .{ .ptr = null, .len = 0 };
    diagnostic(out_error);
    return wire.STATUS_SKILL_CATALOG_INVALID;
}

pub fn skillCatalogRelease(
    _: ?*wire.SkillCatalogHandle,
    out_error: ?*wire.OwnedBytesV1,
) callconv(.c) u32 {
    if (out_error) |out| out.* = .{ .ptr = null, .len = 0 };
    return wire.STATUS_OK;
}

pub fn sessionDestroy(
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

pub fn sessionRefreshSkillCatalog(
    _: ?*wire.SessionHandle,
    _: ?*wire.SkillCatalogHandle,
    out_error: ?*wire.OwnedBytesV1,
) callconv(.c) u32 {
    if (out_error) |out| out.* = .{ .ptr = null, .len = 0 };
    diagnostic(out_error);
    return wire.STATUS_SKILL_CATALOG_INVALID;
}

pub fn sessionRunInput(
    handle: ?*wire.SessionHandle,
    run_id: u64,
    input: ?*const wire.RunInputV1,
    _: ?*const wire.RunOptionsV1,
    out_result: ?*wire.RunResultV1,
    out_error: ?*wire.OwnedBytesV1,
) callconv(.c) u32 {
    if (out_error) |out| out.* = .{ .ptr = null, .len = 0 };
    const typed_input = input orelse {
        diagnostic(out_error);
        return wire.STATUS_INVALID_ARGUMENT;
    };
    if (typed_input.struct_size != @sizeOf(wire.RunInputV1) or
        typed_input.kind_code != wire.RUN_INPUT_TEXT)
    {
        diagnostic(out_error);
        return wire.STATUS_INVALID_ARGUMENT;
    }
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

    if (plan == .ui_callback_outlives_run) {
        fake_core.lock();
        const signal = fake_core.callback_signal;
        fake_core.unlock();
        const active_signal = signal orelse {
            diagnostic(out_error);
            return wire.STATUS_CALLBACK_FAILED;
        };
        active_signal.arm();
        const callback_thread = std.Thread.spawn(
            .{},
            invokeDetachedUiCallback,
            .{session},
        ) catch {
            diagnostic(out_error);
            return wire.STATUS_OUT_OF_MEMORY;
        };
        callback_thread.detach();
        active_signal.waitUntilEntered();
    }

    if (plan == .event_callback or plan == .unknown_event_callback or
        plan == .malformed_event_callback or plan == .wrong_event_session_handle or
        plan == .wrong_event_run_id or plan == .same_run_session_id_mismatch or
        plan == .concurrent_session_id_mismatch or plan == .cross_run_session_id_mismatch)
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
            else => &event_buffer,
        };
        var run = std.mem.zeroes(wire.RunContextV1);
        run.struct_size = @sizeOf(wire.RunContextV1);
        run.session = if (plan == .wrong_event_session_handle)
            @ptrCast(&fake_core.runtime)
        else
            handle;
        run.run_id = if (plan == .wrong_event_run_id) run_id + 1 else run_id;
        run.session_id = sdk.bytesView(session.session_id[0..session.session_id_len]);
        if (plan == .cross_run_session_id_mismatch and run_id > 1)
            run.session_id = sdk.bytesView("changed-cross-run-id");

        var callback_status: u32 = wire.EVENT_CONTINUE;
        if (plan == .concurrent_session_id_mismatch) {
            callback_status = invokeConcurrentIdentityCallbacks(
                callback,
                session.callbacks.ctx,
                &run,
                event_json,
            ) catch wire.EVENT_FATAL;
        } else {
            callback_status = callback(session.callbacks.ctx, &run, sdk.bytesView(event_json));
            if (callback_status == wire.EVENT_CONTINUE and plan == .same_run_session_id_mismatch) {
                run.session_id = sdk.bytesView("changed-same-run-id");
                callback_status = callback(session.callbacks.ctx, &run, sdk.bytesView(event_json));
            }
        }
        @memset(&event_buffer, 'x');
        if (callback_status != wire.EVENT_CONTINUE) {
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
            &wire.RunContextV1{
                .struct_size = @sizeOf(wire.RunContextV1),
                .reserved0 = 0,
                .session = handle,
                .run_id = run_id,
                .session_id = sdk.bytesView(session.session_id[0..session.session_id_len]),
                .reserved = [_]u64{0} ** 2,
            },
            sdk.bytesView(request_json),
            &response,
        );
        fake_core.lock();
        if (callback_status == wire.UI_ANSWERED)
            fake_core.ui_answered_callbacks += 1;
        if (callback_status == wire.UI_FATAL)
            fake_core.ui_fatal_callbacks += 1;
        fake_core.unlock();
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

pub fn sessionAbort(
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

pub fn bufferRelease(out: ?*wire.OwnedBytesV1) callconv(.c) void {
    if (out) |value| value.* = .{ .ptr = null, .len = 0 };
    fake_core.lock();
    fake_core.buffer_releases += 1;
    fake_core.unlock();
}

pub const fake_api = wire.ApiV1{
    .struct_size = @sizeOf(wire.ApiV1),
    .abi_version = wire.ABI_VERSION_V1,
    .abi_revision = wire.ABI_REVISION,
    .reserved0 = 0,
    .capabilities = wire.REQUIRED_CAPABILITIES_V1,
    .runtime_create = runtimeCreate,
    .runtime_destroy = runtimeDestroy,
    .runtime_query_skill_catalog = runtimeQuerySkillCatalog,
    .skill_catalog_release = skillCatalogRelease,
    .session_create = sessionCreate,
    .session_destroy = sessionDestroy,
    .session_refresh_skill_catalog = sessionRefreshSkillCatalog,
    .session_run_input = sessionRunInput,
    .session_abort = sessionAbort,
    .buffer_release = bufferRelease,
    .reserved = [_]u64{0} ** 4,
};

fn invokeDetachedUiCallback(session: *FakeSession) void {
    session.lock();
    const callback = session.callbacks.on_ui_request orelse {
        session.unlock();
        return;
    };
    const callback_context = session.callbacks.ctx;
    const run_id = session.run_id;
    var session_id = [_]u8{0} ** wire.MAX_SESSION_ID_BYTES_V1;
    const session_id_len = session.session_id_len;
    @memcpy(session_id[0..session_id_len], session.session_id[0..session_id_len]);
    session.unlock();

    var run = std.mem.zeroes(wire.RunContextV1);
    run.struct_size = @sizeOf(wire.RunContextV1);
    run.session = @ptrCast(session);
    run.run_id = run_id;
    run.session_id = sdk.bytesView(session_id[0..session_id_len]);
    var response = wire.OwnedBytesV1{ .ptr = null, .len = 0 };
    const callback_status = callback(
        callback_context,
        &run,
        sdk.bytesView("{\"permission\":{\"tool\":\"Bash\",\"args\":\"{}\"}}"),
        &response,
    );
    fake_core.lock();
    if (callback_status == wire.UI_ANSWERED)
        fake_core.ui_answered_callbacks += 1;
    if (callback_status == wire.UI_FATAL)
        fake_core.ui_fatal_callbacks += 1;
    fake_core.unlock();
    if (callback_status == wire.UI_ANSWERED) {
        const release = session.callbacks.release_response orelse return;
        release(callback_context, &response);
    }
    fake_core.lock();
    const signal = fake_core.callback_signal;
    fake_core.unlock();
    if (signal) |active_signal| active_signal.markFinished();
}

const ConcurrentEventInvocation = struct {
    callback: wire.OnEventFnV1,
    callback_context: ?*anyopaque,
    run: wire.RunContextV1,
    event_json: wire.BytesViewV1,
    ready: *std.Io.Semaphore,
    start: *std.Io.Semaphore,
    result: u32 = wire.EVENT_FATAL,

    fn invoke(self: *ConcurrentEventInvocation) void {
        self.ready.post(std.testing.io);
        self.start.waitUncancelable(std.testing.io);
        self.result = self.callback(
            self.callback_context,
            &self.run,
            self.event_json,
        );
    }
};

fn invokeConcurrentIdentityCallbacks(
    callback: wire.OnEventFnV1,
    callback_context: ?*anyopaque,
    run: *const wire.RunContextV1,
    event_json: []const u8,
) !u32 {
    var ready: std.Io.Semaphore = .{};
    var start: std.Io.Semaphore = .{};
    var first = ConcurrentEventInvocation{
        .callback = callback,
        .callback_context = callback_context,
        .run = run.*,
        .event_json = sdk.bytesView(event_json),
        .ready = &ready,
        .start = &start,
    };
    var second = first;
    second.run.session_id = sdk.bytesView("concurrent-other-id");
    const first_thread = try std.Thread.spawn(.{}, ConcurrentEventInvocation.invoke, .{&first});
    const second_thread = std.Thread.spawn(
        .{},
        ConcurrentEventInvocation.invoke,
        .{&second},
    ) catch |err| {
        start.post(std.testing.io);
        first_thread.join();
        return err;
    };
    ready.waitUncancelable(std.testing.io);
    ready.waitUncancelable(std.testing.io);
    start.post(std.testing.io);
    start.post(std.testing.io);
    first_thread.join();
    second_thread.join();
    return if (first.result == wire.EVENT_CONTINUE and second.result == wire.EVENT_CONTINUE)
        wire.EVENT_CONTINUE
    else
        wire.EVENT_FATAL;
}

pub fn openSession(runtime: *lifecycle.Runtime) !*lifecycle.Session {
    const workspace_root = if (std.fs.path.sep == '\\') "C:\\tmp\\metawork-gate2" else "/tmp/metawork-gate2";
    const temporary_root = if (std.fs.path.sep == '\\') "C:\\tmp" else "/tmp";
    return runtime.createSession(.{
        .provider = .anthropic,
        .permission_mode = .default,
        .shell_policy = .disabled,
        .credential = "fixture-secret",
        .model = "fixture-model",
        .workspace = .{
            .canonical_root = workspace_root,
            .trust = .{ .temporary = temporary_root },
        },
    });
}

pub const TestCompositionLimits = struct {
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
    event_ready_notifier: ?lifecycle.EventReadyNotifier = null,
    event_ready_retry_interval: ?std.Io.Duration = null,
    event_ready_timeout: ?std.Io.Duration = null,

    pub fn hostLimits(self: @This()) lifecycle.Limits {
        var limits = lifecycle.Limits{ .max_sessions = self.max_sessions };
        if (self.max_prompt_bytes) |value| limits.max_prompt_bytes = value;
        if (self.event_capacity) |value| limits.event_capacity = value;
        if (self.per_session_event_capacity) |value| limits.per_session_event_capacity = value;
        if (self.control_reserved_capacity) |value| limits.control_reserved_capacity = value;
        if (self.per_session_control_reserved_capacity) |value|
            limits.per_session_control_reserved_capacity = value;
        if (self.max_ui_response_bytes) |value| limits.max_ui_response_bytes = value;
        limits.event_ready_notifier = self.event_ready_notifier;
        if (self.event_ready_retry_interval) |value| limits.event_ready_retry_interval = value;
        if (self.event_ready_timeout) |value| limits.event_ready_timeout = value;
        if (self.ui_request_timeout) |value| {
            limits.ui_request_timeout = value;
        } else if (std.fs.path.sep == '\\') {
            // Windows ThreadedIo retains canceled sleep futures until their
            // deadline. Keep native cross-platform tests bounded; the explicit
            // deadline test supplies its own shorter value.
            limits.ui_request_timeout = .fromSeconds(5);
        }
        return limits;
    }
};

pub fn unavailableEventConsumer(_: ?*anyopaque) lifecycle.EventReadyNotification {
    return .unavailable;
}

pub const TestCompositionEntry = struct {
    runtime: *lifecycle.Runtime,
    executor: *workbench_executor.Executor,
    executor_shutdown: std.atomic.Value(enum(u8) { open, running, complete }) = .init(.open),
    terminal_mutex: std.Io.Mutex = .init,
    terminal_condition: std.Io.Condition = .init,
    terminal_results: [64]?StoredTerminalResult = @splat(null),
};

pub const StoredTerminalResult = struct {
    session_id: u64,
    run_id: u64,
    result: lifecycle.TerminalResult,
};

pub var test_compositions: [32]?TestCompositionEntry = @splat(null);

pub fn registerTestComposition(runtime: *lifecycle.Runtime, executor: *workbench_executor.Executor) !void {
    for (&test_compositions) |*entry| {
        if (entry.* == null) {
            entry.* = .{ .runtime = runtime, .executor = executor };
            return;
        }
    }
    return error.TestCompositionCapacity;
}

pub fn testCompositionEntry(runtime: *lifecycle.Runtime) *TestCompositionEntry {
    for (&test_compositions) |*entry| {
        const value = &(entry.* orelse continue);
        if (value.runtime == runtime) return value;
    }
    unreachable;
}

pub fn testExecutor(runtime: *lifecycle.Runtime) *workbench_executor.Executor {
    return testCompositionEntry(runtime).executor;
}

pub fn unregisterTestComposition(runtime: *lifecycle.Runtime) *workbench_executor.Executor {
    for (&test_compositions) |*entry| {
        const value = entry.* orelse continue;
        if (value.runtime == runtime) {
            const stored_entry = &entry.*.?;
            for (&stored_entry.terminal_results) |*result| {
                if (result.*) |*stored| stored.result.deinit();
                result.* = null;
            }
            entry.* = null;
            return value.executor;
        }
    }
    unreachable;
}

pub fn executeTestRun(context: *anyopaque) void {
    const session: *lifecycle.Session = @ptrCast(@alignCast(context));
    const snapshot = session.snapshot();
    var run = session.beginRun(snapshot.active_run_id) catch return;
    const result = run.execute();
    run.deinit();
    storeTestTerminal(session, snapshot.active_run_id, result);
}

pub fn cancelTestRunForShutdown(context: *anyopaque) void {
    const session: *lifecycle.Session = @ptrCast(@alignCast(context));
    const run_id = session.snapshot().active_run_id;
    session.cancelPreparedRun(run_id) catch {};
}

pub fn submitSession(session: *lifecycle.Session, prompt: []const u8) !u64 {
    const run_id = try session.prepareRun(prompt);
    testExecutor(session.agent_runtime).enqueue(.{
        .context = session,
        .execute_fn = executeTestRun,
        .cancel_fn = cancelTestRunForShutdown,
    }) catch |err| {
        session.cancelPreparedRun(run_id) catch {};
        return err;
    };
    return run_id;
}

pub fn cancelSession(
    session: *lifecycle.Session,
    run_id: u64,
    interruption: lifecycle.ExternalInterruption,
) !void {
    if (testExecutor(session.agent_runtime).cancel(session))
        return session.cancelPreparedRun(run_id);
    return session.requestTermination(run_id, .{ .interrupted = interruption });
}

pub fn closeSession(session: *lifecycle.Session, interruption: lifecycle.ExternalInterruption) !void {
    const snapshot = session.snapshot();
    if (snapshot.state == .queued and testExecutor(session.agent_runtime).cancel(session))
        try session.cancelPreparedRun(snapshot.active_run_id);
    return session.close(interruption);
}

pub fn storeTestTerminal(
    session: *lifecycle.Session,
    run_id: u64,
    result: lifecycle.TerminalResult,
) void {
    const entry = testCompositionEntry(session.agent_runtime);
    entry.terminal_mutex.lockUncancelable(std.testing.io);
    defer entry.terminal_mutex.unlock(std.testing.io);
    for (&entry.terminal_results) |*slot| {
        if (slot.* == null) {
            slot.* = .{ .session_id = session.id, .run_id = run_id, .result = result };
            entry.terminal_condition.broadcast(std.testing.io);
            return;
        }
    }
    std.debug.panic("test TerminalResult capacity exhausted", .{});
}

pub fn takeTestTerminal(session: *lifecycle.Session, run_id: u64) lifecycle.TerminalResult {
    const entry = testCompositionEntry(session.agent_runtime);
    entry.terminal_mutex.lockUncancelable(std.testing.io);
    defer entry.terminal_mutex.unlock(std.testing.io);
    while (true) {
        for (&entry.terminal_results) |*slot| {
            const stored = slot.* orelse continue;
            if (stored.session_id != session.id or stored.run_id != run_id) continue;
            slot.* = null;
            return stored.result;
        }
        entry.terminal_condition.waitUncancelable(std.testing.io, &entry.terminal_mutex);
    }
}

pub fn shutdownTestComposition(runtime: *lifecycle.Runtime) !void {
    const entry = testCompositionEntry(runtime);
    if (entry.executor_shutdown.cmpxchgStrong(.open, .running, .acq_rel, .acquire) == null) {
        var runtime_error: ?lifecycle.Error = null;
        runtime.shutdown() catch |err| {
            runtime_error = err;
        };
        entry.executor.shutdown();
        entry.executor_shutdown.store(.complete, .release);
        if (runtime_error) |err| return err;
    } else {
        while (entry.executor_shutdown.load(.acquire) != .complete)
            std.Thread.yield() catch {};
    }
    return runtime.shutdown();
}

pub fn deinitTestComposition(runtime: *lifecycle.Runtime) void {
    const executor = unregisterTestComposition(runtime);
    executor.deinit();
    runtime.deinit();
}

pub fn createTestComposition(limits: TestCompositionLimits) !*lifecycle.Runtime {
    const executor = try workbench_executor.Executor.create(
        std.testing.io,
        std.testing.allocator,
        .{ .worker_count = limits.worker_count, .queue_capacity = limits.queue_capacity },
    );
    var executor_registered = false;
    errdefer if (!executor_registered) executor.deinit();
    const runtime = try createTestRuntime(limits.hostLimits());
    errdefer {
        runtime.shutdown() catch {};
        runtime.deinit();
    }
    try registerTestComposition(runtime, executor);
    executor_registered = true;
    return runtime;
}

pub fn createTestRuntime(limits: lifecycle.Limits) !*lifecycle.Runtime {
    return lifecycle.Runtime.initWithApi(
        std.testing.io,
        std.testing.allocator,
        &fake_api,
        limits,
    );
}

pub fn workbenchConfiguration() workbench_api.Configuration {
    return .{};
}

pub fn installWorkbenchExecution(
    workbench: *workbench_api.Workbench,
) !void {
    var execution = try account_contract.OwnedExecutionConfig.initOwned(
        std.testing.allocator,
        .anthropic,
        try std.testing.allocator.dupe(u8, "fixture-model"),
        try std.testing.allocator.dupe(
            u8,
            account_contract.metask_anthropic_messages_url,
        ),
        1,
        try std.testing.allocator.dupe(u8, "fixture-secret"),
    );
    errdefer execution.deinit();
    const api_keys = [_]account_contract.ApiKeyView{.{
        .id = "key-1",
        .name = "Fixture API",
        .suffix = "ture",
        .provider_kind = .anthropic,
    }};
    const models = [_]account_contract.ModelView{.{
        .id = "fixture-model",
        .display_name = "Fixture model",
    }};
    try workbench.beginExecutionReplacement();
    workbench.commitAccountFactNoFail(.{
        .kind = .execution_changed,
        .view = .{
            .session_state = .authenticated,
            .execution_state = .ready,
            .operation = .none,
            .readiness = .ready,
            .primary_action = .none,
            .account_id = "account-1",
            .profile_id = "profile-1",
            .display_name = "Fixture User",
            .api_keys = &api_keys,
            .models = &models,
            .selected_api_key_id = "key-1",
            .selected_model = "fixture-model",
            .model_catalog_api_key_id = "key-1",
            .can_create_task = true,
            .catalog_generation = 1,
            .execution_generation = 1,
        },
    });
    workbench.installExecutionNoFail(&execution);
    workbench.endExecutionReplacementNoFail();
    workbench.finishAccountCommitNoFail();
}

pub fn workbenchTaskInput() workbench_api.TaskCreateInput {
    const workspace_root = if (std.fs.path.sep == '\\') "C:\\tmp" else "/tmp";
    const temporary_root = if (std.fs.path.sep == '\\') "C:\\tmp" else "/tmp";
    return .{
        .workspace_root = workspace_root,
        .trust = .{ .temporary = temporary_root },
    };
}

pub fn waitWorkbenchSnapshot(
    runtime: *lifecycle.Runtime,
    workbench: *workbench_api.Workbench,
    needle: []const u8,
) !void {
    var output: [128 * 1024]u8 = undefined;
    for (0..10_000) |_| {
        while (runtime.takeEvent()) |value| {
            var envelope = value;
            defer envelope.deinit();
            try workbench.applyEvent(&envelope);
        }
        workbench.markTerminalRunsBeforeEventDrain();
        while (runtime.takeEvent()) |value| {
            var envelope = value;
            defer envelope.deinit();
            try workbench.applyEvent(&envelope);
        }
        workbench.finalizeMarkedTerminalRunsAfterEventDrain();
        const snapshot = try workbench.writeSnapshot(&output);
        if (std.mem.indexOf(u8, snapshot, needle) != null) return;
        std.Thread.yield() catch {};
    }
    return error.TestUnexpectedResult;
}

pub fn closeOnThread(session: *lifecycle.Session) void {
    closeSession(session, .session_close) catch unreachable;
}

pub fn cancelOnThread(session: *lifecycle.Session, run_id: u64) void {
    cancelSession(session, run_id, .user_cancel) catch unreachable;
}

pub fn failPipelineOnThread(session: *lifecycle.Session) void {
    session.recordTerminationSignal(.{ .event_pump_failure = .consumer_rejected });
}

pub fn shutdownOnThread(runtime: *lifecycle.Runtime) void {
    shutdownTestComposition(runtime) catch unreachable;
}
