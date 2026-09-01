const std = @import("std");
const builtin = @import("builtin");
const agent = if (builtin.is_test) @import("metawork_agent") else struct {};
const account_contract = @import("metawork_account_contract");
const execution_contract = if (builtin.is_test)
    @import("metawork_product_execution_contract")
else
    struct {};
const account_api = @import("metawork_account");
const account_store = @import("account_credential_store");
const control_ports = @import("metawork_product_control_ports");
const test_control = if (builtin.is_test) @import("lifecycle_fixture").product_control else struct {};

const ExecutionReplacement = enum { none, startup, default, identity };

pub const Coordinator = struct {
    runtime: *account_api.Runtime,
    control: control_ports.AccountExecutionHandoff,
    main_thread_id: std.Thread.Id,
    metask_activation_attempt_id: ?u64 = null,

    pub fn init(
        runtime: *account_api.Runtime,
        control: control_ports.AccountExecutionHandoff,
        main_thread_id: std.Thread.Id,
    ) Coordinator {
        return .{
            .runtime = runtime,
            .control = control,
            .main_thread_id = main_thread_id,
        };
    }

    pub fn commandSink(self: *Coordinator) account_contract.AccountCommandSink {
        return .{ .context = self, .submit_fn = submitCommand };
    }

    fn submitCommand(
        context: *anyopaque,
        command: account_contract.AccountCommand,
    ) account_contract.AccountCommandResult {
        const self: *Coordinator = @ptrCast(@alignCast(context));
        self.assertMainThread();
        if (command == .activate_metask and
            !self.control.metaskActivationAvailable())
            return .rejected(.invalid_state);
        return switch (self.runtime.prepareCommand(command)) {
            .prepared => |prepared| result: {
                const result = self.commitPrepared(prepared, .none);
                if (command == .activate_metask and result.accepted)
                    self.metask_activation_attempt_id = result.attempt_id;
                break :result result;
            },
            .rejected => |error_code| .rejected(error_code),
            .ignored_stale => unreachable,
        };
    }

    pub fn start(
        self: *Coordinator,
        platform: account_api.PlatformPorts,
    ) void {
        self.assertMainThread();
        const result = self.commitPrepared(
            self.runtime.prepareStart(platform),
            .none,
        );
        std.debug.assert(result.accepted);
    }

    pub fn startAutomation(self: *Coordinator) void {
        self.assertMainThread();
        const result = self.commitPrepared(
            self.runtime.prepareAutomationStart(),
            .startup,
        );
        std.debug.assert(result.accepted);
    }

    pub fn startUnavailable(self: *Coordinator) void {
        self.assertMainThread();
        const result = self.commitPrepared(
            self.runtime.prepareStartUnavailable(),
            .startup,
        );
        std.debug.assert(result.accepted);
    }

    pub fn onTimer(self: *Coordinator, timer_id: u64) bool {
        self.assertMainThread();
        const prepared_result = self.runtime.prepareTimer(timer_id) orelse
            return false;
        switch (prepared_result) {
            .prepared => |prepared| {
                const result = self.commitPrepared(prepared, .none);
                std.debug.assert(result.accepted);
            },
            .rejected, .ignored_stale => {},
        }
        return true;
    }

    pub fn drain(self: *Coordinator) void {
        self.assertMainThread();
        while (self.runtime.prepareNextCompletion()) |result| {
            switch (result) {
                .prepared => |prepared| {
                    const committed = self.commitPrepared(prepared, .none);
                    std.debug.assert(committed.accepted);
                },
                .rejected, .ignored_stale => {},
            }
        }
    }

    fn commitPrepared(
        self: *Coordinator,
        prepared_value: account_api.Prepared,
        replacement: ExecutionReplacement,
    ) account_contract.AccountCommandResult {
        var prepared = prepared_value;
        defer prepared.deinit();

        var started_replacement = false;
        const prepared_replacement: ExecutionReplacement = switch (prepared.replacementIntent()) {
            .none, .finish => .none,
            .begin_default => .default,
            .begin_identity => .identity,
        };
        switch (if (replacement == .none) prepared_replacement else replacement) {
            .none => {},
            // A cold process has no live Account-owned identity or credential
            // to replace. Restored Task history must not be mistaken for an
            // in-process identity switch, but installation still needs the
            // Workbench's default-execution transaction boundary.
            .startup, .default => {
                if (self.control.executionReplacementPending())
                    return .rejected(.operation_in_progress);
                self.control.beginDefaultExecutionReplacement() catch |err|
                    return .rejected(replacementErrorCode(err));
                started_replacement = true;
            },
            .identity => {
                if (self.control.executionReplacementPending())
                    return .rejected(.operation_in_progress);
                self.control.beginExecutionReplacement() catch |err|
                    return .rejected(replacementErrorCode(err));
                started_replacement = true;
            },
        }
        const effect_admitted = self.runtime.admitEffect(&prepared);
        if (!effect_admitted) {
            if (started_replacement) {
                self.endActiveReplacementNoFail();
                return .rejected(.local_resource_exhausted);
            }
            if (!self.control.executionReplacementPending())
                return .rejected(.local_resource_exhausted);
        }

        const fact = self.runtime.preparedFact(&prepared);
        const prepared_attempt_id = prepared.attemptId();
        const activates_metask = prepared_attempt_id != null and
            prepared_attempt_id == self.metask_activation_attempt_id;
        self.control.commitAccountFactNoFail(fact);
        if (prepared.takeExecution()) |execution_value| {
            var execution = execution_value;
            if (!self.control.acceptMetaskExecutionCandidate(activates_metask)) {
                execution.deinit();
            } else {
                if (!self.control.executionReplacementPending()) {
                    self.control.beginDefaultExecutionReplacement() catch
                        unreachable;
                }
                if (self.control.prepareExecutionInstall(execution.input())) |_| {
                    self.control.installExecutionNoFail(&execution);
                } else |_| {
                    execution.deinit();
                }
            }
        } else if (prepared.executionIntent() == .clear) {
            if (self.control.acceptMetaskExecutionCandidate(false)) {
                if (!self.control.executionReplacementPending()) {
                    self.control.beginDefaultExecutionReplacement() catch
                        unreachable;
                }
                if (self.control.prepareExecutionClear()) |_| {
                    self.control.clearExecutionNoFail();
                } else |_| {}
            }
        }
        self.runtime.commit(&prepared);

        // A continuation effect can fail admission only after its preceding
        // external step has completed. Commit that observed step first, then
        // terminate the still-active transaction from the resulting state.
        if (!effect_admitted)
            return self.commitPrepared(
                self.runtime.prepareActiveAttemptFailure(
                    .local_resource_exhausted,
                ),
                .none,
            );

        const refresh_after_commit = self.runtime.takeRefreshAfterCommit(&prepared);
        const follow_up = self.runtime.takeFollowUpCommand(&prepared);
        self.runtime.dispatchCommitted(&prepared);
        if (activates_metask and prepared.replacementIntent() == .finish)
            self.metask_activation_attempt_id = null;
        if ((prepared.replacementIntent() == .finish or
            replacement == .startup) and
            self.control.executionReplacementPending())
            self.endActiveReplacementNoFail();
        self.control.finishAccountCommitNoFail();

        if (refresh_after_commit) {
            const refreshed = self.commitPrepared(
                self.runtime.prepareRestoredRefresh(),
                .none,
            );
            std.debug.assert(refreshed.accepted);
        }
        if (follow_up) |command| self.submitFollowUp(command);
        return .acceptedAttempt(prepared.attemptId());
    }

    fn endActiveReplacementNoFail(self: *Coordinator) void {
        self.control.endExecutionReplacementNoFail();
    }

    fn submitFollowUp(
        self: *Coordinator,
        command: account_contract.AccountCommand,
    ) void {
        const result = submitCommand(self, command);
        if (result.accepted) return;
        switch (command) {
            .refresh_catalog => {
                const recovered = self.commitPrepared(
                    self.runtime.prepareContinuationFailure(result.error_code),
                    .none,
                );
                std.debug.assert(recovered.accepted);
            },
            else => {},
        }
    }

    pub fn shutdown(self: *Coordinator) void {
        self.assertMainThread();
        const result = self.commitPrepared(
            self.runtime.prepareShutdown(),
            .none,
        );
        std.debug.assert(result.accepted);
    }

    fn assertMainThread(self: *const Coordinator) void {
        std.debug.assert(std.Thread.getCurrentId() == self.main_thread_id);
    }
};

fn replacementErrorCode(err: anyerror) account_contract.ErrorCode {
    return switch (err) {
        error.TaskRunning => .execution_in_use,
        error.TaskSessionInUse => .session_in_use,
        error.ExecutionInUse => .operation_in_progress,
        else => .local_resource_exhausted,
    };
}

var testing_transport_context: u8 = 0;

fn testingTransport() account_api.Transport {
    return .{
        .context = &testing_transport_context,
        .perform_fn = testingPerform,
    };
}

fn testingPerform(
    _: *anyopaque,
    _: account_api.TransportRequest,
    _: []u8,
) account_api.TransportError!account_api.TransportResponse {
    return error.NetworkFailed;
}

test "Application maps identity replacement blockers precisely" {
    try std.testing.expectEqual(
        account_contract.ErrorCode.execution_in_use,
        replacementErrorCode(error.TaskRunning),
    );
    try std.testing.expectEqual(
        account_contract.ErrorCode.session_in_use,
        replacementErrorCode(error.TaskSessionInUse),
    );
    try std.testing.expectEqual(
        account_contract.ErrorCode.operation_in_progress,
        replacementErrorCode(error.ExecutionInUse),
    );
}

test "Application coordinator commits Account Runtime facts into Workbench" {
    const TestWake = struct {
        fn notify(_: *anyopaque) void {}
    };
    var wake_context: u8 = 0;
    var account_runtime = try account_api.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        std.Thread.getCurrentId(),
        if (builtin.os.tag == .windows)
            "C:\\metawork-account-coordinator-test"
        else
            "/tmp/metawork-account-coordinator-test",
        testingTransport(),
        account_api.TestSupport.loopbackEndpoint(),
        .{ .context = &wake_context, .notify_fn = TestWake.notify },
    );
    defer account_runtime.deinit();

    var agent_runtime: agent.Runtime = undefined;
    var workbench = try test_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        &agent_runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 1,
            .max_tasks = 1,
            .max_runs_per_task = 1,
            .max_tools_per_run = 1,
        },
        .{},
    );
    defer workbench.deinit();
    var coordinator = Coordinator.init(
        &account_runtime,
        workbench.accountExecutionHandoff(),
        std.Thread.getCurrentId(),
    );

    var execution = try execution_contract.OwnedConfig.initOwned(
        std.testing.allocator,
        .metask,
        .anthropic_messages,
        try std.testing.allocator.dupe(u8, "model-1"),
        try std.testing.allocator.dupe(
            u8,
            account_contract.metask_anthropic_messages_url,
        ),
        1,
        try std.testing.allocator.dupe(u8, "secret-key"),
        "fixture-provider",
    );
    defer execution.deinit();
    const restored = coordinator.commitPrepared(
        try account_api.TestSupport.prepareReadyRestore(&account_runtime, &execution),
        .startup,
    );
    try std.testing.expect(restored.accepted);
    try std.testing.expectEqual(
        account_contract.AccountState.authenticated,
        account_runtime.view().state,
    );
    try std.testing.expectEqual(
        account_contract.CatalogState.ready,
        account_runtime.view().catalog_state,
    );
    try std.testing.expectEqual(
        account_contract.AccountState.authenticated,
        workbench.accountView().state,
    );
    try std.testing.expect(workbench.accountView().can_create_task);

    const login = coordinator.commandSink().submit(.begin_login);
    try std.testing.expect(login.accepted);
    try std.testing.expect(workbench.executionReplacementPending());
    try std.testing.expect(!workbench.accountView().can_create_task);
    coordinator.drain();
    try std.testing.expectEqual(
        account_contract.AccountState.authenticated,
        account_runtime.view().state,
    );
    try std.testing.expect(!workbench.executionReplacementPending());
    try std.testing.expect(workbench.accountView().can_create_task);

    const cancelled_login = coordinator.commandSink().submit(.begin_login);
    try std.testing.expect(cancelled_login.accepted);
    try std.testing.expect(workbench.executionReplacementPending());
    const cancelled = coordinator.commandSink().submit(.cancel_operation);
    try std.testing.expect(cancelled.accepted);
    try std.testing.expect(!workbench.executionReplacementPending());
    try std.testing.expect(workbench.accountView().can_create_task);
    coordinator.drain();
    try std.testing.expectEqual(
        account_contract.AccountState.authenticated,
        account_runtime.view().state,
    );

    const logout = coordinator.commandSink().submit(.logout);
    try std.testing.expect(logout.accepted);
    try std.testing.expectEqual(
        account_contract.AccountState.authenticated,
        account_runtime.view().state,
    );
    try std.testing.expectEqual(
        account_contract.CatalogState.unavailable,
        account_runtime.view().catalog_state,
    );
    try std.testing.expectEqual(
        account_contract.CatalogState.unavailable,
        workbench.accountView().catalog_state,
    );
    try std.testing.expect(!account_runtime.view().can_cancel);

    coordinator.shutdown();
    try std.testing.expectEqual(
        account_contract.AccountState.signed_out,
        account_runtime.view().state,
    );
    try std.testing.expectEqual(
        account_contract.AccountState.signed_out,
        workbench.accountView().state,
    );
    try std.testing.expectEqual(
        account_contract.CatalogState.unavailable,
        workbench.accountView().catalog_state,
    );
    try std.testing.expectEqual(@as(usize, 0), workbench.accountView().api_keys.len);
    try std.testing.expectEqual(@as(usize, 0), workbench.accountView().models.len);
    try std.testing.expect(!workbench.accountView().can_create_task);
}

test "Application coordinator balances Workbench gate when Account effect admission fails" {
    const TestWake = struct {
        fn notify(_: *anyopaque) void {}
    };
    var wake_context: u8 = 0;
    var account_runtime = try account_api.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        std.Thread.getCurrentId(),
        if (builtin.os.tag == .windows)
            "C:\\metawork-account-admission-test"
        else
            "/tmp/metawork-account-admission-test",
        testingTransport(),
        account_api.TestSupport.loopbackEndpoint(),
        .{ .context = &wake_context, .notify_fn = TestWake.notify },
    );
    defer account_runtime.deinit();

    var agent_runtime: agent.Runtime = undefined;
    var workbench = try test_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        &agent_runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 1,
            .max_tasks = 1,
            .max_runs_per_task = 1,
            .max_tools_per_run = 1,
        },
        .{},
    );
    defer workbench.deinit();
    var coordinator = Coordinator.init(
        &account_runtime,
        workbench.accountExecutionHandoff(),
        std.Thread.getCurrentId(),
    );

    var execution = try execution_contract.OwnedConfig.initOwned(
        std.testing.allocator,
        .metask,
        .anthropic_messages,
        try std.testing.allocator.dupe(u8, "model-1"),
        try std.testing.allocator.dupe(
            u8,
            account_contract.metask_anthropic_messages_url,
        ),
        1,
        try std.testing.allocator.dupe(u8, "secret-key"),
        "fixture-provider",
    );
    defer execution.deinit();
    const restored = coordinator.commitPrepared(
        try account_api.TestSupport.prepareReadyRestore(&account_runtime, &execution),
        .startup,
    );
    try std.testing.expect(restored.accepted);
    const revision = workbench.currentRevision();

    account_api.TestSupport.occupyEffectQueue(&account_runtime);
    const rejected = coordinator.commandSink().submit(.logout);
    try std.testing.expect(!rejected.accepted);
    try std.testing.expectEqual(
        account_contract.ErrorCode.local_resource_exhausted,
        rejected.error_code,
    );
    try std.testing.expectEqual(
        account_contract.AccountState.authenticated,
        account_runtime.view().state,
    );
    try std.testing.expect(workbench.accountView().can_create_task);
    try std.testing.expectEqual(revision, workbench.currentRevision());
    try std.testing.expect(!workbench.executionReplacementPending());

    account_api.TestSupport.clearEffectQueue(&account_runtime);
    const login = coordinator.commandSink().submit(.begin_login);
    try std.testing.expect(login.accepted);
    try std.testing.expect(workbench.executionReplacementPending());
    account_api.TestSupport.discardMailbox(&account_runtime);
    account_api.TestSupport.occupyEffectQueue(&account_runtime);
    const continuation = coordinator.commitPrepared(
        account_api.TestSupport.prepareTokensPersisted(&account_runtime),
        .none,
    );
    try std.testing.expect(continuation.accepted);
    try std.testing.expectEqual(
        account_contract.AccountState.signed_out,
        account_runtime.view().state,
    );
    try std.testing.expectEqual(
        account_contract.ErrorCode.local_resource_exhausted,
        account_runtime.view().error_code,
    );
    try std.testing.expect(!workbench.executionReplacementPending());
    try std.testing.expect(!workbench.accountView().can_create_task);
    account_api.TestSupport.clearEffectQueue(&account_runtime);
    coordinator.shutdown();
}

// Headless reproduction rig for the full post-login catalog continuation:
// restore with a stored refresh token -> token refresh -> identity -> API Key
// catalog -> automatic first-key selection -> model catalog -> automatic
// first-model selection -> execution persistence, then a manual key switch.
// Every network step answers through the production single-flight worker via
// a scripted Metask transport; only the OS keychain and timers are faked.
const FakePlatform = struct {
    secret: [256]u8 = undefined,
    secret_len: usize = 0,
    stored: bool = false,
    preference: ?account_store.Preference = null,

    fn seed(self: *FakePlatform, refresh_token: []const u8) void {
        @memcpy(self.secret[0..refresh_token.len], refresh_token);
        self.secret_len = refresh_token.len;
        self.stored = true;
    }

    fn ports(self: *FakePlatform) account_api.PlatformPorts {
        return .{
            .credentials = .{
                .context = self,
                .set_refresh_token_fn = setCredential,
                .get_refresh_token_fn = getCredential,
                .delete_refresh_token_fn = deleteCredential,
                .load_preference_fn = loadPreference,
                .commit_preference_fn = commitPreference,
                .delete_preference_fn = deletePreference,
            },
            .authorization_url = .{
                .context = self,
                .open_fn = openExternalUrl,
            },
            .timer = .{
                .context = self,
                .start_fn = startTimer,
                .cancel_fn = cancelTimer,
            },
        };
    }

    fn setCredential(
        context: *anyopaque,
        secret: []const u8,
    ) account_store.StoreError!void {
        const self: *FakePlatform = @ptrCast(@alignCast(context));
        if (secret.len > self.secret.len) return error.WriteFailed;
        @memcpy(self.secret[0..secret.len], secret);
        self.secret_len = secret.len;
        self.stored = true;
    }

    fn getCredential(
        context: *anyopaque,
        buffer: []u8,
    ) account_store.StoreError!?[]const u8 {
        const self: *FakePlatform = @ptrCast(@alignCast(context));
        if (!self.stored) return null;
        if (self.secret_len > buffer.len) return error.ReadFailed;
        @memcpy(buffer[0..self.secret_len], self.secret[0..self.secret_len]);
        return buffer[0..self.secret_len];
    }

    fn deleteCredential(context: *anyopaque) account_store.StoreError!void {
        const self: *FakePlatform = @ptrCast(@alignCast(context));
        self.stored = false;
    }

    fn loadPreference(context: *anyopaque) account_store.StoreError!?account_store.Preference {
        const self: *FakePlatform = @ptrCast(@alignCast(context));
        return self.preference;
    }

    fn commitPreference(
        context: *anyopaque,
        value: account_store.Preference,
    ) account_store.StoreError!void {
        const self: *FakePlatform = @ptrCast(@alignCast(context));
        self.preference = value;
    }

    fn deletePreference(context: *anyopaque) account_store.StoreError!void {
        const self: *FakePlatform = @ptrCast(@alignCast(context));
        self.preference = null;
    }

    fn startTimer(
        _: *anyopaque,
        _: u64,
        _: u64,
        _: bool,
    ) anyerror!void {}

    fn cancelTimer(_: *anyopaque, _: u64) anyerror!void {}

    fn openExternalUrl(_: *anyopaque, _: []const u8) anyerror!void {}
};

const FakeMetask = struct {
    requests: std.atomic.Value(usize) = .init(0),
    /// When set, model requests whose bearer ends with this suffix answer
    /// with a server failure — the broken-backend deviation observed on the
    /// user's first (auto-selected) API Key.
    fail_models_bearer_suffix: ?[]const u8 = null,

    const keys_body =
        \\{"code":0,"message":"success","data":{"items":[
        \\{"id":1,"key":"sk-fake-key-0001","name":"First Key","group_id":10,
        \\"status":"active","group":{"id":10,"platform":"anthropic","status":"active"}},
        \\{"id":2,"key":"sk-fake-key-0002","name":"GPT Key","group_id":20,
        \\"status":"active","group":{"id":20,"platform":"openai","status":"active"}}
        \\],"total":2,"page":1,"page_size":100,"pages":1}}
    ;
    const models_body =
        \\{"object":"list","data":[
        \\{"id":"claude-sonnet-4-5","object":"model","type":"model","display_name":"Sonnet"},
        \\{"id":"claude-opus-4-6","object":"model","type":"model","display_name":"Opus"}
        \\],"has_more":false}
    ;
    const gpt_models_body =
        \\{"object":"list","data":[
        \\{"id":"gpt-5.1","object":"model","type":"model","display_name":"GPT-5.1"},
        \\{"id":"gpt-5.6-sol","object":"model","type":"model","display_name":"GPT-5.6 SOL"}
        \\],"has_more":false}
    ;
    const token_body =
        \\{"access_token":"access-2","refresh_token":"refresh-2","token_type":"Bearer","expires_in":3600,"scope":"metawork:use","account_id":"1"}
    ;
    const user_body =
        \\{"code":0,"message":"success","data":{"id":1,"email":"user@example.com","username":"Meta User","role":"user"}}
    ;

    fn transport(self: *FakeMetask) account_api.Transport {
        return .{ .context = self, .perform_fn = perform };
    }

    fn perform(
        context: *anyopaque,
        request: account_api.TransportRequest,
        response_buffer: []u8,
    ) account_api.TransportError!account_api.TransportResponse {
        const self: *FakeMetask = @ptrCast(@alignCast(context));
        _ = self.requests.fetchAdd(1, .acq_rel);
        if (request.kind == .models) {
            if (self.fail_models_bearer_suffix) |suffix| {
                const bearer = request.bearer orelse "";
                if (std.mem.endsWith(u8, bearer, suffix)) {
                    const failure = "{\"error\":\"quota\"}";
                    @memcpy(response_buffer[0..failure.len], failure);
                    return .{
                        .status = 500,
                        .body = response_buffer[0..failure.len],
                    };
                }
            }
        }
        const body: []const u8 = switch (request.kind) {
            .refresh_token => token_body,
            .current_user => user_body,
            .keys => keys_body,
            .models => if (std.mem.endsWith(
                u8,
                request.bearer orelse "",
                "0002",
            )) gpt_models_body else models_body,
            .exchange_code => return error.ProtocolFailed,
        };
        if (body.len > response_buffer.len) return error.ResponseTooLarge;
        @memcpy(response_buffer[0..body.len], body);
        return .{ .status = 200, .body = response_buffer[0..body.len] };
    }
};

fn pumpUntilReady(
    coordinator: *Coordinator,
    account_runtime: *account_api.Runtime,
    _: []const u8,
) account_contract.AccountView {
    var iterations: usize = 0;
    while (iterations < 600) : (iterations += 1) {
        coordinator.drain();
        const view = account_runtime.view();
        if (view.state == .authenticated and view.catalog_state == .ready)
            return view;
        if (view.state == .authenticated and view.catalog_state == .failed)
            return view;
        // A stable parked choice: drain returned with no in-flight attempt,
        // so nothing will advance without a user command.
        if (view.state == .authenticated and
            view.catalog_state == .choosing and
            iterations > 20)
            return view;
        std.Io.Timeout.sleep(.{ .duration = .{
            .raw = std.Io.Duration.fromMilliseconds(5),
            .clock = .awake,
        } }, std.testing.io) catch {};
    }
    return account_runtime.view();
}

test "restored login drives automatic key and model defaults end to end" {
    const TestWake = struct {
        fn notify(_: *anyopaque) void {}
    };
    var wake_context: u8 = 0;
    const account_dir = if (builtin.os.tag == .windows)
        "C:\\metawork-account-autoselect-test"
    else
        "/tmp/metawork-account-autoselect-test";
    std.Io.Dir.cwd().deleteTree(std.testing.io, account_dir) catch {};

    var account_runtime = try account_api.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        std.Thread.getCurrentId(),
        account_dir,
        testingTransport(),
        account_api.TestSupport.loopbackEndpoint(),
        .{ .context = &wake_context, .notify_fn = TestWake.notify },
    );
    defer account_runtime.deinit();

    var fake_metask: FakeMetask = .{};
    account_api.TestSupport.overrideTransport(
        &account_runtime,
        fake_metask.transport(),
    );

    var agent_runtime: agent.Runtime = undefined;
    var workbench = try test_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        &agent_runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 1,
            .max_tasks = 1,
            .max_runs_per_task = 1,
            .max_tools_per_run = 1,
        },
        .{},
    );
    defer workbench.deinit();
    var coordinator = Coordinator.init(
        &account_runtime,
        workbench.accountExecutionHandoff(),
        std.Thread.getCurrentId(),
    );

    var fake_platform: FakePlatform = .{};
    fake_platform.seed("stored-refresh-token");
    coordinator.start(fake_platform.ports());

    // Phase 1: the automatic continuation must land the first key and the
    // first model without any user action.
    const settled = pumpUntilReady(&coordinator, &account_runtime, "auto");
    try std.testing.expectEqual(
        account_contract.AccountState.authenticated,
        settled.state,
    );
    try std.testing.expectEqual(
        account_contract.CatalogState.ready,
        settled.catalog_state,
    );
    try std.testing.expectEqualStrings("1", settled.selected_api_key_id);
    try std.testing.expectEqualStrings(
        "claude-sonnet-4-5",
        settled.selected_model,
    );
    try std.testing.expect(settled.can_create_task);

    // Phase 2: a manual key switch from the settled state must complete the
    // same continuation for the second key.
    const manual = coordinator.commandSink().submit(.{ .select_api_key = .{
        .selection_id = "2",
        .expected_catalog_generation = settled.catalog_generation,
        .expected_execution_generation = settled.execution_generation,
    } });
    try std.testing.expect(manual.accepted);
    const switched = pumpUntilReady(&coordinator, &account_runtime, "manual");
    try std.testing.expectEqual(
        account_contract.CatalogState.ready,
        switched.catalog_state,
    );
    try std.testing.expectEqualStrings("2", switched.selected_api_key_id);
    try std.testing.expectEqualStrings("gpt-5.1", switched.selected_model);
    try std.testing.expect(switched.can_create_task);

    // Phase 3: changing only the default model on the committed GPT API is a
    // preference transaction. It must retain the committed catalog and the
    // credential generation, and the new default must be durable.
    const switched_generation = switched.execution_generation;
    const select_gpt_model = coordinator.commandSink().submit(.{
        .select_model = .{
            .selection_id = "gpt-5.6-sol",
            .expected_catalog_generation = switched.catalog_generation,
            .expected_execution_generation = switched.execution_generation,
        },
    });
    try std.testing.expect(select_gpt_model.accepted);
    const model_changed = pumpUntilReady(
        &coordinator,
        &account_runtime,
        "model-only",
    );
    try account_contract.validateView(model_changed);
    try std.testing.expectEqualStrings("2", model_changed.selected_api_key_id);
    try std.testing.expectEqualStrings("gpt-5.6-sol", model_changed.selected_model);
    try std.testing.expectEqual(switched_generation, model_changed.execution_generation);
    try std.testing.expectEqual(@as(usize, 2), model_changed.api_keys.len);
    try std.testing.expectEqual(@as(usize, 2), model_changed.models.len);
    try std.testing.expectEqualStrings(
        "gpt-5.6-sol",
        fake_platform.preference.?.modelId(),
    );
    try std.testing.expectEqual(
        switched_generation,
        fake_platform.preference.?.execution_generation,
    );

    coordinator.shutdown();
}

test "relaunch with persisted selection restores the saved execution" {
    const TestWake = struct {
        fn notify(_: *anyopaque) void {}
    };
    var wake_context: u8 = 0;
    const account_dir = if (builtin.os.tag == .windows)
        "C:\\metawork-account-relaunch-test"
    else
        "/tmp/metawork-account-relaunch-test";
    std.Io.Dir.cwd().deleteTree(std.testing.io, account_dir) catch {};

    var fake_metask: FakeMetask = .{};
    var fake_platform: FakePlatform = .{};
    fake_platform.seed("stored-refresh-token");
    var persisted_generation: u64 = 0;

    // First boot: land the automatic defaults and persist the preference.
    {
        var account_runtime = try account_api.Runtime.init(
            std.testing.allocator,
            std.testing.io,
            std.Thread.getCurrentId(),
            account_dir,
            testingTransport(),
            account_api.TestSupport.loopbackEndpoint(),
            .{ .context = &wake_context, .notify_fn = TestWake.notify },
        );
        defer account_runtime.deinit();
        account_api.TestSupport.overrideTransport(
            &account_runtime,
            fake_metask.transport(),
        );
        var agent_runtime: agent.Runtime = undefined;
        var workbench = try test_control.Runtime.init(
            std.testing.allocator,
            std.testing.io,
            &agent_runtime,
            .{
                .worker_count = 1,
                .queue_capacity = 1,
                .max_tasks = 1,
                .max_runs_per_task = 1,
                .max_tools_per_run = 1,
            },
            .{},
        );
        defer workbench.deinit();
        var coordinator = Coordinator.init(
            &account_runtime,
            workbench.accountExecutionHandoff(),
            std.Thread.getCurrentId(),
        );
        coordinator.start(fake_platform.ports());
        const settled = pumpUntilReady(&coordinator, &account_runtime, "boot1");
        try std.testing.expectEqual(
            account_contract.CatalogState.ready,
            settled.catalog_state,
        );
        try std.testing.expectEqualStrings("1", settled.selected_api_key_id);
        coordinator.shutdown();
    }

    // Second boot over the same store: the persisted selection must restore
    // and the continuation must settle without any user action.
    {
        var account_runtime = try account_api.Runtime.init(
            std.testing.allocator,
            std.testing.io,
            std.Thread.getCurrentId(),
            account_dir,
            testingTransport(),
            account_api.TestSupport.loopbackEndpoint(),
            .{ .context = &wake_context, .notify_fn = TestWake.notify },
        );
        defer account_runtime.deinit();
        account_api.TestSupport.overrideTransport(
            &account_runtime,
            fake_metask.transport(),
        );
        var agent_runtime: agent.Runtime = undefined;
        var workbench = try test_control.Runtime.init(
            std.testing.allocator,
            std.testing.io,
            &agent_runtime,
            .{
                .worker_count = 1,
                .queue_capacity = 1,
                .max_tasks = 1,
                .max_runs_per_task = 1,
                .max_tools_per_run = 1,
            },
            .{},
        );
        defer workbench.deinit();
        var coordinator = Coordinator.init(
            &account_runtime,
            workbench.accountExecutionHandoff(),
            std.Thread.getCurrentId(),
        );
        coordinator.start(fake_platform.ports());
        const settled = pumpUntilReady(&coordinator, &account_runtime, "boot2");
        try std.testing.expectEqual(
            account_contract.AccountState.authenticated,
            settled.state,
        );
        try std.testing.expectEqual(
            account_contract.CatalogState.ready,
            settled.catalog_state,
        );
        try std.testing.expectEqualStrings("1", settled.selected_api_key_id);
        try std.testing.expect(settled.can_create_task);

        // The user's exact gesture: pick a key in settings right after the
        // relaunch settles.
        const manual = coordinator.commandSink().submit(.{
            .select_api_key = .{
                .selection_id = "2",
                .expected_catalog_generation = settled.catalog_generation,
                .expected_execution_generation = settled.execution_generation,
            },
        });
        try std.testing.expect(manual.accepted);
        const switched = pumpUntilReady(&coordinator, &account_runtime, "boot2-manual");
        try std.testing.expectEqual(
            account_contract.CatalogState.ready,
            switched.catalog_state,
        );
        try std.testing.expectEqualStrings("2", switched.selected_api_key_id);
        const model_change = coordinator.commandSink().submit(.{
            .select_model = .{
                .selection_id = "gpt-5.6-sol",
                .expected_catalog_generation = switched.catalog_generation,
                .expected_execution_generation = switched.execution_generation,
            },
        });
        try std.testing.expect(model_change.accepted);
        const changed = pumpUntilReady(&coordinator, &account_runtime, "boot2-model");
        try std.testing.expectEqualStrings("gpt-5.6-sol", changed.selected_model);
        try std.testing.expectEqual(
            switched.execution_generation,
            changed.execution_generation,
        );
        persisted_generation = changed.execution_generation;
        coordinator.shutdown();
    }

    // Third boot proves that a model-only preference transaction survives a
    // process boundary without minting a replacement credential generation.
    {
        var account_runtime = try account_api.Runtime.init(
            std.testing.allocator,
            std.testing.io,
            std.Thread.getCurrentId(),
            account_dir,
            testingTransport(),
            account_api.TestSupport.loopbackEndpoint(),
            .{ .context = &wake_context, .notify_fn = TestWake.notify },
        );
        defer account_runtime.deinit();
        account_api.TestSupport.overrideTransport(
            &account_runtime,
            fake_metask.transport(),
        );
        var agent_runtime: agent.Runtime = undefined;
        var workbench = try test_control.Runtime.init(
            std.testing.allocator,
            std.testing.io,
            &agent_runtime,
            .{
                .worker_count = 1,
                .queue_capacity = 1,
                .max_tasks = 1,
                .max_runs_per_task = 1,
                .max_tools_per_run = 1,
            },
            .{},
        );
        defer workbench.deinit();
        var coordinator = Coordinator.init(
            &account_runtime,
            workbench.accountExecutionHandoff(),
            std.Thread.getCurrentId(),
        );
        coordinator.start(fake_platform.ports());
        const restored = pumpUntilReady(&coordinator, &account_runtime, "boot3");
        try std.testing.expectEqualStrings("2", restored.selected_api_key_id);
        try std.testing.expectEqualStrings("gpt-5.6-sol", restored.selected_model);
        try std.testing.expectEqual(persisted_generation, restored.execution_generation);
        coordinator.shutdown();
    }
}

test "broken first key parks the catalog and a manual switch recovers" {
    const TestWake = struct {
        fn notify(_: *anyopaque) void {}
    };
    var wake_context: u8 = 0;
    const account_dir = if (builtin.os.tag == .windows)
        "C:\\metawork-account-brokenkey-test"
    else
        "/tmp/metawork-account-brokenkey-test";
    std.Io.Dir.cwd().deleteTree(std.testing.io, account_dir) catch {};

    var fake_metask: FakeMetask = .{
        .fail_models_bearer_suffix = "0001",
    };
    var fake_platform: FakePlatform = .{};
    fake_platform.seed("stored-refresh-token");

    var account_runtime = try account_api.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        std.Thread.getCurrentId(),
        account_dir,
        testingTransport(),
        account_api.TestSupport.loopbackEndpoint(),
        .{ .context = &wake_context, .notify_fn = TestWake.notify },
    );
    defer account_runtime.deinit();
    account_api.TestSupport.overrideTransport(
        &account_runtime,
        fake_metask.transport(),
    );
    var agent_runtime: agent.Runtime = undefined;
    var workbench = try test_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        &agent_runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 1,
            .max_tasks = 1,
            .max_runs_per_task = 1,
            .max_tools_per_run = 1,
        },
        .{},
    );
    defer workbench.deinit();
    var coordinator = Coordinator.init(
        &account_runtime,
        workbench.accountExecutionHandoff(),
        std.Thread.getCurrentId(),
    );
    coordinator.start(fake_platform.ports());

    // The automatic continuation picks key 1 whose model catalog fails.
    const parked = pumpUntilReady(&coordinator, &account_runtime, "broken");
    try std.testing.expectEqual(
        account_contract.AccountState.authenticated,
        parked.state,
    );
    try std.testing.expectEqualStrings("models HTTP 500", parked.safe_diagnostic);

    // The user's gesture: choose the second (healthy) key manually.
    const manual = coordinator.commandSink().submit(.{ .select_api_key = .{
        .selection_id = "2",
        .expected_catalog_generation = parked.catalog_generation,
        .expected_execution_generation = parked.execution_generation,
    } });
    try std.testing.expect(manual.accepted);
    const recovered = pumpUntilReady(&coordinator, &account_runtime, "recover");
    try std.testing.expectEqual(
        account_contract.CatalogState.ready,
        recovered.catalog_state,
    );
    try std.testing.expectEqualStrings("2", recovered.selected_api_key_id);
    try std.testing.expect(recovered.can_create_task);

    coordinator.shutdown();
}
