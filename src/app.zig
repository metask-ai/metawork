const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");
const bridge_api = @import("metawork_bridge");
const automation_api = @import("metawork_automation");
const agent = @import("metawork_agent");
const workbench_api = @import("metawork_workbench");
const account_contract = @import("metawork_account_contract");
const account_api = @import("metawork_account");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const frontend_url_env = "NATIVE_SDK_FRONTEND_URL";
const pending_ui_json_capacity = 256 * 1024;
const terminal_diagnostic_capacity = 512;
const agent_event_retry_interval: std.Io.Duration = .fromMilliseconds(5);
const agent_event_notification_timeout: std.Io.Duration = .fromMilliseconds(50);
const host_worker_count = 4;
const workbench_snapshot_capacity = bridge_api.snapshot_max_bytes;
const FrontendMode = bridge_api.policy.Mode;

const AccountEffectQueue = struct {
    entry: ?Entry = null,

    const Entry = struct {
        attempt_id: ?u64,
        effect: account_api.Effect,
    };

    fn sink(self: *AccountEffectQueue) account_api.EffectSink {
        return .{ .context = self, .submit_fn = submit };
    }

    fn submit(
        context: *anyopaque,
        attempt_id: ?u64,
        effect: account_api.Effect,
    ) bool {
        const self: *AccountEffectQueue = @ptrCast(@alignCast(context));
        if (self.entry != null) return false;
        self.entry = .{ .attempt_id = attempt_id, .effect = effect };
        return true;
    }

    fn take(self: *AccountEffectQueue) ?Entry {
        const entry = self.entry;
        self.entry = null;
        return entry;
    }
};

const AccountEffectCommitHook = struct {
    context: ?*anyopaque = null,
    dispatch_fn: *const fn (?*anyopaque) void = noDispatch,

    fn dispatch(self: AccountEffectCommitHook) void {
        self.dispatch_fn(self.context);
    }

    fn noDispatch(_: ?*anyopaque) void {}
};

const AccountEffects = struct {
    const MailboxResult = union(enum) {
        login: struct {
            attempt_id: u64,
            result: account_api.LoginAttempt.WorkerResult,
        },
        completion: account_api.WorkerCompletion,

        fn deinit(self: *MailboxResult) void {
            switch (self.*) {
                .login => |*entry| entry.result.deinit(),
                .completion => |*completion| completion.deinit(),
            }
        }
    };

    allocator: std.mem.Allocator,
    io: std.Io,
    wake: account_api.WakeSink,
    transport: account_api.MetaskClient.StdHttpTransport,
    queue: AccountEffectQueue = .{},
    mailbox_mutex: std.Io.Mutex = .init,
    mailbox: ?MailboxResult = null,
    login_attempt: account_api.LoginAttempt.LoginAttempt = .{},
    login_active: bool = false,
    fatal_wake_failure: bool = false,

    fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        wake: account_api.WakeSink,
    ) AccountEffects {
        return .{
            .allocator = allocator,
            .io = io,
            .wake = wake,
            .transport = .{ .allocator = allocator, .io = io },
        };
    }

    fn sink(self: *AccountEffects) account_api.EffectSink {
        return self.queue.sink();
    }

    fn loginSink(
        self: *AccountEffects,
    ) account_api.LoginAttempt.ResultSink {
        return .{ .context = self, .publish_fn = publishLoginResult };
    }

    fn publishLoginResult(
        context: *anyopaque,
        attempt_id: u64,
        result: *account_api.LoginAttempt.WorkerResult,
    ) bool {
        const self: *AccountEffects = @ptrCast(@alignCast(context));
        self.lockMailbox();
        if (self.mailbox != null) {
            self.unlockMailbox();
            return false;
        }
        self.mailbox = .{ .login = .{
            .attempt_id = attempt_id,
            .result = result.take(),
        } };
        self.unlockMailbox();
        self.notifyOrLatchFatal();
        return true;
    }

    fn publishCompletion(
        self: *AccountEffects,
        completion_value: account_api.WorkerCompletion,
    ) void {
        var completion = completion_value;
        self.lockMailbox();
        if (self.mailbox != null) {
            completion.deinit();
            self.fatal_wake_failure = true;
            self.unlockMailbox();
            return;
        }
        self.mailbox = .{ .completion = completion };
        self.unlockMailbox();
        self.notifyOrLatchFatal();
    }

    fn replaceWithFailure(
        self: *AccountEffects,
        attempt_id: u64,
        error_code: account_contract.ErrorCode,
    ) void {
        if (self.takeMailbox()) |value| {
            var stale = value;
            stale.deinit();
        }
        self.publishCompletion(.{
            .attempt_id = attempt_id,
            .payload = .{ .failed = .fromCode(error_code) },
        });
    }

    fn takeMailbox(self: *AccountEffects) ?MailboxResult {
        self.lockMailbox();
        defer self.unlockMailbox();
        const result = self.mailbox;
        self.mailbox = null;
        return result;
    }

    fn startLogin(
        self: *AccountEffects,
        attempt_id: u64,
        platform: *account_api.Platform.MacosBackend,
        now_unix_seconds: i64,
    ) void {
        std.debug.assert(!self.login_active);
        self.login_attempt.start(
            self.allocator,
            self.io,
            attempt_id,
            self.transport.transport(),
            self.loginSink(),
            now_unix_seconds,
        ) catch |err| {
            self.publishCompletion(.{
                .attempt_id = attempt_id,
                .payload = .{ .failed = .fromCode(
                    loginStartError(err),
                ) },
            });
            return;
        };
        self.login_active = true;
        platform.openAuthorizationUrl(
            self.login_attempt.authorizationUrl(),
        ) catch {
            self.login_attempt.cancel();
            self.login_attempt.join();
            self.login_attempt.deinit();
            self.login_active = false;
            self.replaceWithFailure(
                attempt_id,
                .oauth_browser_open_failed,
            );
        };
    }

    fn cancelLogin(self: *AccountEffects, attempt_id: u64) void {
        if (!self.login_active or
            self.login_attempt.attempt_id != attempt_id)
            return;
        self.login_attempt.cancel();
    }

    fn joinLogin(self: *AccountEffects) void {
        if (!self.login_active) return;
        self.login_attempt.join();
        self.login_attempt.deinit();
        self.login_active = false;
    }

    fn cancelJoinAndDiscard(self: *AccountEffects) void {
        if (self.login_active) {
            self.login_attempt.cancel();
            self.joinLogin();
        }
        if (self.takeMailbox()) |value| {
            var discarded = value;
            discarded.deinit();
        }
    }

    fn deinit(self: *AccountEffects) void {
        self.cancelJoinAndDiscard();
        std.debug.assert(self.queue.entry == null);
        self.* = undefined;
    }

    fn notifyOrLatchFatal(self: *AccountEffects) void {
        if (self.wake.notify()) return;
        self.lockMailbox();
        self.fatal_wake_failure = true;
        self.unlockMailbox();
    }

    fn takeFatal(self: *AccountEffects) bool {
        self.lockMailbox();
        defer self.unlockMailbox();
        const fatal = self.fatal_wake_failure;
        self.fatal_wake_failure = false;
        return fatal;
    }

    fn lockMailbox(self: *AccountEffects) void {
        self.mailbox_mutex.lockUncancelable(self.io);
    }

    fn unlockMailbox(self: *AccountEffects) void {
        self.mailbox_mutex.unlock(self.io);
    }
};

const AccountCoordinator = struct {
    account: account_api.Account = .initRestoring(),
    workbench: *workbench_api.Workbench,
    effects: account_api.EffectSink,
    effect_commit_hook: AccountEffectCommitHook,
    main_thread_id: std.Thread.Id,

    fn init(
        workbench: *workbench_api.Workbench,
        effects: account_api.EffectSink,
        effect_commit_hook: AccountEffectCommitHook,
        main_thread_id: std.Thread.Id,
    ) AccountCoordinator {
        return .{
            .workbench = workbench,
            .effects = effects,
            .effect_commit_hook = effect_commit_hook,
            .main_thread_id = main_thread_id,
        };
    }

    fn commandSink(self: *AccountCoordinator) account_contract.AccountCommandSink {
        return .{ .context = self, .submit_fn = submitCommand };
    }

    fn submitCommand(
        context: *anyopaque,
        command: account_contract.AccountCommand,
    ) account_contract.AccountCommandResult {
        const self: *AccountCoordinator = @ptrCast(@alignCast(context));
        self.assertMainThread();
        const needs_replacement = switch (command) {
            .select_model, .logout => true,
            else => false,
        };
        if (needs_replacement) {
            self.workbench.beginExecutionReplacement() catch
                return .rejected(.execution_in_use);
        }
        const prepared = self.account.prepareCommand(command);
        return switch (prepared) {
            .transition => |value| self.commitTransition(value),
            .rejected => |error_code| result: {
                if (needs_replacement)
                    self.workbench.endExecutionReplacementNoFail();
                break :result .rejected(error_code);
            },
            .ignored_stale => unreachable,
        };
    }

    fn restore(
        self: *AccountCoordinator,
        restore_result: *account_api.RestoreResult,
    ) account_contract.ErrorCode {
        self.assertMainThread();
        self.workbench.beginExecutionReplacement() catch {
            restore_result.deinit();
            return .execution_in_use;
        };
        const prepared = self.account.prepareRestore(restore_result);
        return switch (prepared) {
            .transition => |value| if (self.commitTransition(value).accepted)
                .none
            else
                .local_resource_exhausted,
            .rejected => |error_code| result: {
                self.workbench.endExecutionReplacementNoFail();
                break :result error_code;
            },
            .ignored_stale => unreachable,
        };
    }

    fn complete(
        self: *AccountCoordinator,
        completion: *account_api.WorkerCompletion,
    ) bool {
        self.assertMainThread();
        const prepared = self.account.prepareCompletion(completion);
        return switch (prepared) {
            .transition => |value| self.commitTransition(value).accepted,
            .rejected => false,
            .ignored_stale => false,
        };
    }

    fn restoreFailure(
        self: *AccountCoordinator,
        failure: account_api.WorkerFailure,
    ) void {
        self.assertMainThread();
        const prepared = self.account.prepareRestoreFailure(failure);
        switch (prepared) {
            .transition => |value| {
                const committed = self.commitTransition(value);
                std.debug.assert(committed.accepted);
            },
            .rejected, .ignored_stale => @panic(
                "Account restore failure was published outside restoring",
            ),
        }
    }

    fn logoutPersistenceUnknown(self: *AccountCoordinator) void {
        self.assertMainThread();
        std.debug.assert(self.workbench.executionReplacementPending());
        const prepared = self.account.prepareLogoutPersistenceUnknown();
        switch (prepared) {
            .transition => |value| {
                const committed = self.commitTransition(value);
                std.debug.assert(committed.accepted);
            },
            .rejected, .ignored_stale => @panic(
                "logout persistence outcome lost its active attempt",
            ),
        }
    }

    fn commitTransition(
        self: *AccountCoordinator,
        prepared_value: account_api.PreparedTransition,
    ) account_contract.AccountCommandResult {
        var prepared = prepared_value;
        defer prepared.deinit();
        if (prepared.takeEffect()) |effect| {
            if (!self.effects.submit(prepared.attempt_id, effect)) {
                if (self.workbench.executionReplacementPending())
                    self.workbench.endExecutionReplacementNoFail();
                return .rejected(.local_resource_exhausted);
            }
        }

        const fact = prepared.fact();
        self.workbench.commitAccountFactNoFail(fact);
        if (prepared.takeExecution()) |execution_value| {
            var execution = execution_value;
            self.workbench.installExecutionNoFail(&execution);
        } else if (self.workbench.executionReplacementPending() and
            fact.view.operation == .none and
            fact.view.execution_state == .none)
        {
            self.workbench.clearExecutionNoFail();
        }
        prepared.commit(&self.account);
        if (self.workbench.executionReplacementPending() and
            fact.view.operation == .none)
        {
            self.workbench.endExecutionReplacementNoFail();
        }
        self.workbench.finishAccountCommitNoFail();
        self.effect_commit_hook.dispatch();
        return .acceptedAttempt(prepared.attempt_id);
    }

    fn shutdown(self: *AccountCoordinator) void {
        self.assertMainThread();
        const prepared = self.account.prepareShutdown();
        const result = self.commitTransition(prepared);
        std.debug.assert(result.accepted);
    }

    fn assertMainThread(self: *const AccountCoordinator) void {
        std.debug.assert(std.Thread.getCurrentId() == self.main_thread_id);
    }
};

const App = struct {
    env_map: *std.process.Environ.Map,
    io: std.Io,
    main_thread_id: std.Thread.Id,
    automation: automation_api.Runtime = .{},
    dispatcher: ?*bridge_api.Dispatcher = null,
    agent_runtime: ?*agent.Runtime = null,
    workbench: ?*workbench_api.Workbench = null,
    agent_shutdown: bool = false,
    agent_event_wake_pending: std.atomic.Value(bool) = .init(false),
    native_runtime: ?*native_sdk.Runtime = null,
    platform_services: ?native_sdk.platform.PlatformServices = null,
    account_coordinator: ?*AccountCoordinator = null,
    account_effects: ?*AccountEffects = null,
    account_platform: ?account_api.Platform.MacosBackend = null,
    account_credentials: account_api.CredentialOwner = .{},
    account_dir_storage: [4096]u8 = undefined,
    account_dir_len: usize = 0,

    fn app(self: *@This()) native_sdk.App {
        return .{
            .context = self,
            .name = "metawork",
            .source = native_sdk.frontend.productionSource(.{ .dist = "frontend/dist" }),
            .source_fn = source,
            .start_fn = start,
            .event_fn = event,
            .stop_fn = stop,
        };
    }

    fn source(context: *anyopaque) anyerror!native_sdk.WebViewSource {
        const self: *@This() = @ptrCast(@alignCast(context));
        return native_sdk.frontend.sourceFromEnv(self.env_map, .{
            .dist = "frontend/dist",
            .entry = "index.html",
        });
    }

    fn start(context: *anyopaque, native_runtime: *native_sdk.Runtime) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.native_runtime = native_runtime;
        self.platform_services = native_runtime.options.platform.services;
        self.automation.start(native_runtime);
        if (self.automation.active()) {
            self.startAutomationAccount(
                self.automation.executionFixture(),
            );
        } else {
            self.restoreAccount();
        }
    }

    fn stop(context: *anyopaque, native_runtime: *native_sdk.Runtime) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (self.dispatcher) |dispatcher| dispatcher.stopIngress();
        self.automation.stop();
        if (self.account_coordinator) |coordinator| {
            coordinator.shutdown();
            self.drainAccountEffects();
        }
        if (self.workbench) |workbench| workbench.shutdownExecutor();
        if (self.agent_runtime) |agent_runtime| {
            try agent_runtime.shutdown();
            self.agent_shutdown = true;
        }
        self.drainAgentEvents();
        if (self.workbench) |workbench| workbench.syncLifecycle();
        if (self.dispatcher) |dispatcher| {
            dispatcher.breakConnection();
            dispatcher.assertQuiescent();
            dispatcher.detachWorkbench();
        }
        self.deinitAccountPlatform();
        self.workbench = null;
        self.platform_services = null;
        if (self.native_runtime == native_runtime) self.native_runtime = null;
    }

    fn restoreAccount(self: *@This()) void {
        const coordinator = self.account_coordinator orelse
            @panic("Account coordinator is not composed");
        const services = self.platform_services orelse {
            coordinator.restoreFailure(.fromCode(
                .credential_store_read_failed,
            ));
            return;
        };
        self.account_platform = account_api.Platform.MacosBackend.init(
            services,
            self.io,
            self.main_thread_id,
            self.account_dir_storage[0..self.account_dir_len],
        ) catch |err| {
            coordinator.restoreFailure(.fromCode(
                accountRestoreError(err),
            ));
            return;
        };
        var restored = account_api.CredentialStore.restore(
            std.heap.c_allocator,
            self.account_platform.?.backend(),
        ) catch |err| {
            coordinator.restoreFailure(.fromCode(
                accountRestoreError(err),
            ));
            return;
        };
        switch (restored) {
            .signed_out => |signed_out| {
                self.account_credentials.setCleanupPending(
                    signed_out.cleanup_pending,
                );
                self.account_credentials.clear();
                var state_restore: account_api.RestoreResult = .{
                    .signed_out = .{
                        .execution_high_watermark = signed_out.execution_high_watermark,
                    },
                };
                std.debug.assert(coordinator.restore(&state_restore) == .none);
            },
            .account_only => |*account_only| {
                self.account_credentials.setCleanupPending(
                    account_only.cleanup_pending,
                );
                self.account_credentials.replace(&account_only.tokens);
                var state_restore: account_api.RestoreResult = .{
                    .account_only = .{
                        .identity = account_only.identity,
                        .execution_high_watermark = account_only.execution_high_watermark,
                    },
                };
                account_only.deinit();
                std.debug.assert(coordinator.restore(&state_restore) == .none);
            },
            .execution_ready => |*execution_ready| {
                self.account_credentials.setCleanupPending(
                    execution_ready.cleanup_pending,
                );
                self.account_credentials.replace(
                    &execution_ready.tokens,
                );
                const ready = account_api.RestoreReady.init(
                    execution_ready.identity,
                    execution_ready.apiKeyId(),
                    &execution_ready.execution,
                ) catch {
                    execution_ready.deinit();
                    coordinator.restoreFailure(.fromCode(
                        .recovery_state_invalid,
                    ));
                    return;
                };
                execution_ready.deinit();
                var state_restore: account_api.RestoreResult = .{
                    .execution_ready = ready,
                };
                std.debug.assert(coordinator.restore(&state_restore) == .none);
            },
        }
        self.retryAccountCleanup();
    }

    fn startAutomationAccount(
        self: *@This(),
        fixture: ?automation_api.ExecutionFixture,
    ) void {
        std.debug.assert(automation_api.enabled);
        const coordinator = self.account_coordinator orelse
            @panic("Account coordinator is not composed");
        var signed_out: account_api.RestoreResult = .{
            .signed_out = .{},
        };
        if (coordinator.restore(&signed_out) != .none)
            @panic("automation Account restore failed");
        if (fixture) |execution| {
            const workbench = self.workbench orelse
                @panic("Workbench is not composed");
            workbench.installAutomationExecution(.{
                .provider = execution.provider,
                .credential = execution.credential,
                .model = execution.model,
                .base_url = execution.base_url,
            }) catch @panic("automation execution fixture is invalid");
        }
    }

    fn deinitAccountPlatform(self: *@This()) void {
        self.account_credentials.deinit();
        if (self.account_platform) |*platform| platform.deinit();
        self.account_platform = null;
    }

    fn accountEffectCommitted(context: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(context orelse
            @panic("Account effect committed without App")));
        self.dispatchCommittedAccountEffect();
    }

    fn dispatchCommittedAccountEffect(self: *@This()) void {
        const effects = self.account_effects orelse
            @panic("Account effects are not composed");
        const coordinator = self.account_coordinator orelse
            @panic("Account coordinator is not composed");
        const entry = effects.queue.take() orelse return;
        switch (entry.effect) {
            .begin_oauth => {
                const attempt_id = entry.attempt_id orelse
                    @panic("OAuth effect has no attempt");
                const platform = if (self.account_platform) |*value|
                    value
                else {
                    effects.publishCompletion(.{
                        .attempt_id = attempt_id,
                        .payload = .{ .failed = .fromCode(
                            .credential_store_read_failed,
                        ) },
                    });
                    return;
                };
                const now_unix_seconds = wallUnixSeconds(self.io) orelse {
                    effects.publishCompletion(.{
                        .attempt_id = attempt_id,
                        .payload = .{ .failed = .fromCode(
                            .dependency_contract_invalid,
                        ) },
                    });
                    return;
                };
                effects.startLogin(
                    attempt_id,
                    platform,
                    now_unix_seconds,
                );
            },
            .cancel_attempt => |attempt_id| effects.cancelLogin(attempt_id),
            .persist_signed_out_tombstone => {
                const attempt_id = entry.attempt_id orelse
                    @panic("logout effect has no attempt");
                const platform = if (self.account_platform) |*value|
                    value
                else {
                    effects.publishCompletion(.{
                        .attempt_id = attempt_id,
                        .payload = .{ .failed = .fromCode(
                            .credential_store_write_failed,
                        ) },
                    });
                    return;
                };
                const cleanup_pending =
                    account_api.CredentialStore.commitSignedOut(
                        platform.backend(),
                        coordinator.account.executionHighWatermark(),
                    ) catch |err| {
                        if (err == error.PersistenceOutcomeUnknown) {
                            self.account_credentials.clear();
                            self.account_credentials.setCleanupPending(
                                true,
                            );
                            coordinator.logoutPersistenceUnknown();
                            self.retryAccountCleanup();
                            return;
                        }
                        effects.publishCompletion(.{
                            .attempt_id = attempt_id,
                            .payload = .{ .failed = .fromCode(
                                accountStoreError(err),
                            ) },
                        });
                        return;
                    };
                self.account_credentials.clear();
                self.account_credentials.setCleanupPending(
                    cleanup_pending,
                );
                effects.publishCompletion(.{
                    .attempt_id = attempt_id,
                    .payload = .logged_out,
                });
            },
            .delete_retired_credentials => self.retryAccountCleanup(),
            .shutdown => {
                effects.cancelJoinAndDiscard();
            },
            .refresh_token,
            .load_api_keys,
            .load_models,
            .prepare_execution,
            => {
                const attempt_id = entry.attempt_id orelse
                    @panic("Account worker effect has no attempt");
                effects.publishCompletion(.{
                    .attempt_id = attempt_id,
                    .payload = .{ .failed = .fromCode(
                        .dependency_contract_invalid,
                    ) },
                });
            },
        }
    }

    fn drainAccountEffects(self: *@This()) void {
        const effects = self.account_effects orelse return;
        const coordinator = self.account_coordinator orelse return;
        while (effects.takeMailbox()) |mailbox_value| {
            var mailbox = mailbox_value;
            defer mailbox.deinit();
            const fatal_wake = effects.takeFatal();
            switch (mailbox) {
                .login => |*entry| {
                    effects.joinLogin();
                    if (coordinator.account.activeAttempt() !=
                        entry.attempt_id)
                        continue;
                    if (fatal_wake) {
                        var completion: account_api.WorkerCompletion = .{
                            .attempt_id = entry.attempt_id,
                            .payload = .{ .failed = .fromCode(
                                .main_loop_wake_failed,
                            ) },
                        };
                        defer completion.deinit();
                        _ = coordinator.complete(&completion);
                        continue;
                    }
                    switch (entry.result) {
                        .authenticated => |*login| {
                            self.commitAuthenticatedLogin(
                                entry.attempt_id,
                                login,
                            );
                        },
                        .failed => |failure| {
                            var completion: account_api.WorkerCompletion = .{
                                .attempt_id = entry.attempt_id,
                                .payload = .{ .failed = failure },
                            };
                            defer completion.deinit();
                            _ = coordinator.complete(&completion);
                        },
                        .consumed => @panic(
                            "Account login mailbox contains consumed result",
                        ),
                    }
                },
                .completion => |*completion| {
                    if (fatal_wake and
                        coordinator.account.activeAttempt() ==
                            completion.attempt_id)
                    {
                        completion.deinit();
                        completion.* = .{
                            .attempt_id = completion.attempt_id,
                            .payload = .{ .failed = .fromCode(
                                .main_loop_wake_failed,
                            ) },
                        };
                    }
                    _ = coordinator.complete(completion);
                },
            }
        }
    }

    fn commitAuthenticatedLogin(
        self: *@This(),
        attempt_id: u64,
        login: *account_api.MetaskClient.LoginResult,
    ) void {
        const coordinator = self.account_coordinator orelse
            @panic("Account coordinator is not composed");
        const platform = if (self.account_platform) |*value|
            value
        else {
            self.completeAccountFailure(
                attempt_id,
                .credential_store_write_failed,
            );
            return;
        };
        var generation: account_api.CredentialStore.Generation = undefined;
        std.Io.randomSecure(self.io, &generation) catch {
            self.completeAccountFailure(
                attempt_id,
                .local_resource_exhausted,
            );
            return;
        };
        const committed = account_api.CredentialStore.commitAccountOnly(
            platform.backend(),
            generation,
            &login.tokens,
            &login.identity,
            coordinator.account.executionHighWatermark(),
        ) catch |err| {
            self.completeAccountFailure(
                attempt_id,
                accountStoreError(err),
            );
            return;
        };
        self.account_credentials.replace(&login.tokens);
        self.account_credentials.setCleanupPending(
            committed.retired_cleanup_pending,
        );
        var completion: account_api.WorkerCompletion = .{
            .attempt_id = attempt_id,
            .payload = .{ .authenticated = login.identity },
        };
        defer completion.deinit();
        if (!coordinator.complete(&completion))
            @panic("persisted Account login could not commit");
        self.retryAccountCleanup();
    }

    fn completeAccountFailure(
        self: *@This(),
        attempt_id: u64,
        error_code: account_contract.ErrorCode,
    ) void {
        const coordinator = self.account_coordinator orelse
            @panic("Account coordinator is not composed");
        var completion: account_api.WorkerCompletion = .{
            .attempt_id = attempt_id,
            .payload = .{ .failed = .fromCode(error_code) },
        };
        defer completion.deinit();
        _ = coordinator.complete(&completion);
    }

    fn retryAccountCleanup(self: *@This()) void {
        if (!self.account_credentials.cleanupPending()) return;
        const platform = if (self.account_platform) |*value|
            value
        else
            return;
        self.account_credentials.setCleanupPending(
            account_api.CredentialStore.cleanupRetiredCredentials(
                platform.backend(),
            ) catch true,
        );
    }

    fn event(
        context: *anyopaque,
        native_runtime: *native_sdk.Runtime,
        value: native_sdk.Event,
    ) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        _ = native_runtime;
        switch (value) {
            .effects_wake => {
                self.drainAccountEffects();
                self.drainAgentEvents();
                if (self.dispatcher) |dispatcher| if (dispatcher.connectedWindow()) |window_id| {
                    try self.automation.onEffectsWake(window_id);
                    try dispatcher.emitWorkbenchChanged();
                };
            },
            .timer => |timer| if (self.automation.onTimer(
                timer.id,
                native_sdk.monotonicNanoseconds(),
            )) {
                return;
            } else if (self.dispatcher != null and self.dispatcher.?.onTimer(timer.id)) {
                try self.dispatcher.?.emitWorkbenchChanged();
            },
            else => {},
        }
    }

    fn bridge(self: *@This(), mode: FrontendMode) native_sdk.BridgeDispatcher {
        var automation_handlers: [automation_api.handler_count]native_sdk.bridge.Handler = undefined;
        self.automation.fillHandlers(&automation_handlers);
        return (self.dispatcher orelse @panic("Bridge Dispatcher is not composed")).register(
            self.automation.productPolicy(bridge_api.policy.product(mode)),
            &automation_handlers,
        ) catch @panic("Bridge handler registry capacity is invalid");
    }

    fn drainAgentEvents(self: *@This()) void {
        const agent_runtime = self.agent_runtime orelse return;
        self.agent_event_wake_pending.store(false, .release);
        self.drainAgentEventPass(agent_runtime);
        const workbench = self.workbench orelse return;
        // Terminal publication happens after the synchronous AgentCore Run
        // returns, so its acquire observes all callback event enqueues. Drain
        // once more after that observation before exposing product terminal
        // state and the final assistant suffix; otherwise a queued callback
        // could lose the race to lifecycle publication or a snapshot.
        workbench.markTerminalRunsBeforeEventDrain();
        self.drainAgentEventPass(agent_runtime);
        workbench.finalizeMarkedTerminalRunsAfterEventDrain();
    }

    fn drainAgentEventPass(
        self: *@This(),
        agent_runtime: *agent.Runtime,
    ) void {
        while (agent_runtime.takeEvent()) |value| {
            var envelope = value;
            defer envelope.deinit();
            if (self.workbench) |workbench| workbench.applyEvent(&envelope) catch {
                workbench.recordEventProjectionFailure(
                    envelope.session_id,
                    envelope.run_id,
                );
                agent_runtime.requestRunTermination(
                    envelope.session_id,
                    envelope.run_id,
                    .{ .event_pump_failure = .consumer_rejected },
                ) catch {};
            };
        }
    }

    fn notifyMainLoop(context: ?*anyopaque) bool {
        const self: *@This() = @ptrCast(@alignCast(context orelse return false));
        const services = self.platform_services orelse return false;
        services.wake() catch return false;
        return true;
    }

    fn notifyAccountEffects(context: *anyopaque) bool {
        return notifyMainLoop(context);
    }

    fn notifyAgentEventConsumer(context: ?*anyopaque) agent.EventReadyNotification {
        const self: *@This() = @ptrCast(@alignCast(context orelse return .unavailable));
        if (self.agent_event_wake_pending.swap(true, .acq_rel)) return .already_pending;
        if (notifyMainLoop(context)) return .scheduled;
        self.agent_event_wake_pending.store(false, .release);
        return .unavailable;
    }

    fn dispatcherPlatform(self: *@This()) bridge_api.DispatcherPlatform {
        return .{
            .context = self,
            .wake_fn = platformWake,
            .emit_fn = platformEmit,
            .start_timer_fn = platformStartTimer,
            .cancel_timer_fn = platformCancelTimer,
            .show_open_dialog_fn = platformShowOpenDialog,
            .show_message_dialog_fn = platformShowMessageDialog,
            .now_fn = platformNow,
            .on_main_thread_fn = platformOnMainThread,
        };
    }

    fn dispatcherAutomation(self: *@This()) bridge_api.DispatcherAutomationHooks {
        return .{
            .context = self,
            .active_fn = automationActive,
            .before_connect_fn = automationBeforeConnect,
            .connect_fn = automationConnect,
            .detach_fn = automationDetach,
        };
    }

    fn platformWake(context: ?*anyopaque) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        try (self.platform_services orelse return error.RuntimeUnavailable).wake();
    }

    fn platformEmit(
        context: ?*anyopaque,
        window_id: native_sdk.platform.WindowId,
        name: []const u8,
        detail: []const u8,
    ) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        try (self.native_runtime orelse return error.RuntimeUnavailable).emitWindowEvent(
            window_id,
            name,
            detail,
        );
    }

    fn platformStartTimer(
        context: ?*anyopaque,
        timer_id: u64,
        interval_ns: u64,
        repeats: bool,
    ) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        try (self.platform_services orelse return error.RuntimeUnavailable).startTimer(
            timer_id,
            interval_ns,
            repeats,
        );
    }

    fn platformCancelTimer(context: ?*anyopaque, timer_id: u64) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        try (self.platform_services orelse return error.RuntimeUnavailable).cancelTimer(timer_id);
    }

    fn platformShowOpenDialog(
        context: ?*anyopaque,
        options: native_sdk.platform.OpenDialogOptions,
        output: []u8,
    ) anyerror!native_sdk.platform.OpenDialogResult {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        return (self.platform_services orelse return error.RuntimeUnavailable).showOpenDialog(
            options,
            output,
        );
    }

    fn platformShowMessageDialog(
        context: ?*anyopaque,
        options: native_sdk.platform.MessageDialogOptions,
    ) anyerror!native_sdk.platform.MessageDialogResult {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        return (self.platform_services orelse return error.RuntimeUnavailable).showMessageDialog(
            options,
        );
    }

    fn platformNow(_: ?*anyopaque) u64 {
        return native_sdk.monotonicNanoseconds();
    }

    fn platformOnMainThread(context: ?*anyopaque) bool {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        return std.Thread.getCurrentId() == self.main_thread_id;
    }

    fn automationActive(context: ?*anyopaque) bool {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        return self.automation.active();
    }

    fn automationBeforeConnect(context: ?*anyopaque, now_ns: u64) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        try self.automation.beforeConnect(now_ns);
    }

    fn automationConnect(context: ?*anyopaque, generation: u64) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        try self.automation.connectAt(generation);
    }

    fn automationDetach(context: ?*anyopaque, generation: u64, now_ns: u64) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        try self.automation.detach(generation, now_ns);
    }

    fn breakProductConnectionForAutomation(context: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(context orelse return));
        if (self.dispatcher) |dispatcher| dispatcher.breakConnection();
    }
};

fn accountRestoreError(err: anyerror) account_contract.ErrorCode {
    return switch (err) {
        error.ReadFailed,
        error.AccountDirectoryUnavailable,
        => .credential_store_read_failed,
        error.DeleteFailed => .credential_store_delete_failed,
        error.ManifestCorrupt,
        error.InvalidData,
        error.VerificationFailed,
        error.PersistenceOutcomeUnknown,
        => .recovery_state_invalid,
        error.WrongThread,
        error.WriteFailed,
        => .dependency_contract_invalid,
        else => .recovery_state_invalid,
    };
}

fn accountStoreError(err: anyerror) account_contract.ErrorCode {
    return switch (err) {
        error.ReadFailed => .credential_store_read_failed,
        error.WriteFailed,
        error.PersistenceOutcomeUnknown,
        => .credential_store_write_failed,
        error.DeleteFailed => .credential_store_delete_failed,
        error.ManifestCorrupt,
        error.InvalidData,
        error.VerificationFailed,
        => .recovery_state_invalid,
        else => .dependency_contract_invalid,
    };
}

fn loginStartError(
    err: account_api.LoginAttempt.StartError,
) account_contract.ErrorCode {
    return switch (err) {
        error.BindFailed => .oauth_bind_failed,
        error.ThreadSpawnFailed => .local_resource_exhausted,
        error.AuthorizationUrlFailed,
        error.RandomFailed,
        error.InvalidAttempt,
        error.AlreadyStarted,
        => .dependency_contract_invalid,
    };
}

fn wallUnixSeconds(io: std.Io) ?i64 {
    const nanoseconds = std.Io.Timestamp.now(io, .real).nanoseconds;
    if (nanoseconds < 0) return null;
    const seconds = @divFloor(nanoseconds, std.time.ns_per_s);
    if (seconds > std.math.maxInt(i64)) return null;
    return @intCast(seconds);
}

fn frontendMode(env_map: *std.process.Environ.Map) FrontendMode {
    return if (env_map.get(frontend_url_env) != null) .development else .release;
}

fn createAgentRuntime(io: std.Io, notifier: agent.EventReadyNotifier) !*agent.Runtime {
    return agent.Runtime.init(io, std.heap.c_allocator, .{
        .max_sessions = 8,
        .max_ui_request_bytes = pending_ui_json_capacity,
        .max_terminal_diagnostic_bytes = terminal_diagnostic_capacity,
        .event_ready_notifier = notifier,
        .event_ready_retry_interval = agent_event_retry_interval,
        .event_ready_timeout = agent_event_notification_timeout,
    });
}

pub fn run(init: std.process.Init) !void {
    var app = App{
        .env_map = init.environ_map,
        .io = init.io,
        .main_thread_id = std.Thread.getCurrentId(),
        .automation = try automation_api.Runtime.init(
            std.heap.c_allocator,
            init.environ_map,
            std.Thread.getCurrentId(),
        ),
    };
    defer app.automation.deinit();
    var data_dir_storage: [4096]u8 = undefined;
    const data_dir = try native_sdk.app_dirs.resolveOne(
        .{ .name = "MetaWork" },
        native_sdk.app_dirs.currentPlatform(),
        native_sdk.debug.envFromMap(init.environ_map),
        .data,
        &data_dir_storage,
    );
    const account_dir = try native_sdk.app_dirs.join(
        native_sdk.app_dirs.currentPlatform(),
        &app.account_dir_storage,
        &.{ data_dir, "account" },
    );
    app.account_dir_len = account_dir.len;

    const agent_runtime = try createAgentRuntime(init.io, .{
        .context = &app,
        .notify_fn = App.notifyAgentEventConsumer,
    });
    app.agent_runtime = agent_runtime;
    var workbench_initialized = false;
    var workbench: workbench_api.Workbench = undefined;
    defer {
        if (workbench_initialized) workbench.shutdownExecutor();
        if (!app.agent_shutdown) agent_runtime.shutdown() catch {};
        if (workbench_initialized) workbench.deinit();
        agent_runtime.deinit();
    }

    workbench = try workbench_api.Workbench.init(
        std.heap.c_allocator,
        agent_runtime,
        .{
            .worker_count = host_worker_count,
            .queue_capacity = 8,
            .max_pending_ui_json_bytes = pending_ui_json_capacity,
            .max_pending_ui_requests = host_worker_count,
            .max_terminal_diagnostic_bytes = terminal_diagnostic_capacity,
            .max_snapshot_bytes = workbench_snapshot_capacity,
        },
        .{ .change_notifier = .{
            .context = &app,
            .wake = App.notifyMainLoop,
        } },
    );
    workbench_initialized = true;
    app.workbench = &workbench;
    var account_effects = AccountEffects.init(
        std.heap.c_allocator,
        init.io,
        .{
            .context = &app,
            .notify_fn = App.notifyAccountEffects,
        },
    );
    app.account_effects = &account_effects;
    var account_coordinator = AccountCoordinator.init(
        &workbench,
        account_effects.sink(),
        .{
            .context = &app,
            .dispatch_fn = App.accountEffectCommitted,
        },
        app.main_thread_id,
    );
    app.account_coordinator = &account_coordinator;
    defer {
        app.deinitAccountPlatform();
        app.account_coordinator = null;
        account_effects.deinit();
        app.account_effects = null;
    }

    var dispatcher = try bridge_api.Dispatcher.init(
        std.heap.c_allocator,
        &workbench,
        account_coordinator.commandSink(),
        app.dispatcherPlatform(),
        app.dispatcherAutomation(),
    );
    defer dispatcher.deinit();
    app.dispatcher = &dispatcher;
    app.automation.bind(dispatcher.callbackGate(), dispatcher.productDelivery(), .{
        .context = &app,
        .break_product_connection_fn = App.breakProductConnectionForAutomation,
    });
    const mode = frontendMode(init.environ_map);

    try runner.runWithOptions(app.app(), .{
        .app_name = "MetaWork",
        .window_title = "MetaWork",
        .bundle_id = "dev.metawork.desktop",
        .bridge = app.bridge(mode),
        .builtin_bridge = app.automation.builtinPolicy(bridge_api.policy.builtin(mode)),
        .js_window_api = true,
        .security = .{
            .permissions = &bridge_api.policy.window_permissions,
            .navigation = .{
                .allowed_origins = app.automation.allowedOrigins(bridge_api.policy.origins(mode)),
            },
        },
    }, init);
}

test "App remains a composition root with explicit platform limits" {
    try std.testing.expectEqual(@as(usize, 1024 * 1024), native_sdk.bridge.max_message_bytes);
    try std.testing.expectEqual(@as(usize, 8192), native_sdk.platform.max_window_event_detail_bytes);
    try std.testing.expectEqual(@as(usize, 1), bridge_api.policy.origins(.release).len);
}

test "Account coordinator commits login and execution as separate gates" {
    var runtime: agent.Runtime = undefined;
    runtime.io = std.testing.io;
    var workbench = try workbench_api.Workbench.init(
        std.testing.allocator,
        &runtime,
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
    var effects: AccountEffectQueue = .{};
    var coordinator = AccountCoordinator.init(
        &workbench,
        effects.sink(),
        .{},
        std.Thread.getCurrentId(),
    );
    var restore_result: account_api.RestoreResult = .{
        .signed_out = .{ .execution_high_watermark = 0 },
    };
    try std.testing.expectEqual(
        account_contract.ErrorCode.none,
        coordinator.restore(&restore_result),
    );
    try std.testing.expectEqual(
        account_contract.AccountSessionState.signed_out,
        workbench.accountView().session_state,
    );

    const login = coordinator.commandSink().submit(.begin_login);
    try std.testing.expect(login.accepted);
    try std.testing.expect(effects.take().?.effect == .begin_oauth);
    var authenticated: account_api.WorkerCompletion = .{
        .attempt_id = login.attempt_id.?,
        .payload = .{ .authenticated = try .init(
            "account-1",
            "profile-1",
            "Metask User",
        ) },
    };
    defer authenticated.deinit();
    try std.testing.expect(coordinator.complete(&authenticated));
    try std.testing.expectEqual(
        account_contract.AccountSessionState.authenticated,
        workbench.accountView().session_state,
    );
    try std.testing.expectEqual(
        account_contract.ExecutionState.none,
        workbench.accountView().execution_state,
    );
    try std.testing.expect(!workbench.accountView().can_create_task);

    const catalog = coordinator.commandSink().submit(.refresh_catalog);
    try std.testing.expect(catalog.accepted);
    try std.testing.expect(effects.take().?.effect == .load_api_keys);
    var keys_loaded: account_api.WorkerCompletion = .{
        .attempt_id = catalog.attempt_id.?,
        .payload = .api_keys_loaded,
    };
    defer keys_loaded.deinit();
    try std.testing.expect(coordinator.complete(&keys_loaded));
    const key = coordinator.commandSink().submit(.{
        .select_api_key = "key-1",
    });
    try std.testing.expect(key.accepted);
    try std.testing.expectEqualStrings(
        "key-1",
        effects.take().?.effect.argument().?,
    );
    var models_loaded: account_api.WorkerCompletion = .{
        .attempt_id = catalog.attempt_id.?,
        .payload = .models_loaded,
    };
    defer models_loaded.deinit();
    try std.testing.expect(coordinator.complete(&models_loaded));
    const model = coordinator.commandSink().submit(.{
        .select_model = "model-1",
    });
    try std.testing.expect(model.accepted);
    try std.testing.expect(workbench.executionReplacementPending());
    try std.testing.expectEqualStrings(
        "model-1",
        effects.take().?.effect.argument().?,
    );

    var execution = try account_contract.OwnedExecutionConfig.initOwned(
        std.testing.allocator,
        .anthropic,
        try std.testing.allocator.dupe(u8, "model-1"),
        try std.testing.allocator.dupe(
            u8,
            account_contract.metask_anthropic_messages_url,
        ),
        1,
        try std.testing.allocator.dupe(u8, "secret-key"),
    );
    var ready: account_api.WorkerCompletion = .{
        .attempt_id = model.attempt_id.?,
        .payload = .{ .execution_ready = execution.take() },
    };
    defer ready.deinit();
    execution.deinit();
    try std.testing.expect(coordinator.complete(&ready));
    try std.testing.expect(!workbench.executionReplacementPending());
    try std.testing.expect(workbench.accountView().can_create_task);

    const logout = coordinator.commandSink().submit(.logout);
    try std.testing.expect(logout.accepted);
    try std.testing.expect(workbench.executionReplacementPending());
    try std.testing.expect(
        effects.take().?.effect == .persist_signed_out_tombstone,
    );
    var logged_out: account_api.WorkerCompletion = .{
        .attempt_id = logout.attempt_id.?,
        .payload = .logged_out,
    };
    defer logged_out.deinit();
    try std.testing.expect(coordinator.complete(&logged_out));
    try std.testing.expect(!workbench.executionReplacementPending());
    try std.testing.expectEqual(
        account_contract.AccountSessionState.signed_out,
        workbench.accountView().session_state,
    );
    try std.testing.expect(!workbench.accountView().can_create_task);
}

test "Account effect admission failure preserves both committed owners" {
    var runtime: agent.Runtime = undefined;
    runtime.io = std.testing.io;
    var workbench = try workbench_api.Workbench.init(
        std.testing.allocator,
        &runtime,
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
    var effects: AccountEffectQueue = .{
        .entry = .{ .attempt_id = 99, .effect = .begin_oauth },
    };
    var coordinator = AccountCoordinator.init(
        &workbench,
        effects.sink(),
        .{},
        std.Thread.getCurrentId(),
    );
    var restore_result: account_api.RestoreResult = .{
        .signed_out = .{},
    };
    try std.testing.expectEqual(
        account_contract.ErrorCode.none,
        coordinator.restore(&restore_result),
    );
    const revision = workbench.currentRevision();
    const rejected = coordinator.commandSink().submit(.begin_login);
    try std.testing.expect(!rejected.accepted);
    try std.testing.expectEqual(
        account_contract.ErrorCode.local_resource_exhausted,
        rejected.error_code,
    );
    try std.testing.expectEqual(
        account_contract.AccountSessionState.signed_out,
        coordinator.account.view().session_state,
    );
    try std.testing.expectEqual(
        account_contract.AccountSessionState.signed_out,
        workbench.accountView().session_state,
    );
    try std.testing.expectEqual(revision, workbench.currentRevision());
}

test "Account committed effects are dispatched only after state commit" {
    const Hook = struct {
        queue: *AccountEffectQueue,
        coordinator: ?*AccountCoordinator = null,
        dispatch_count: usize = 0,

        fn dispatch(context: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            const entry = self.queue.take() orelse return;
            std.debug.assert(
                self.coordinator.?.account.view().session_state ==
                    .authorizing,
            );
            std.debug.assert(entry.effect == .begin_oauth);
            self.dispatch_count += 1;
        }
    };

    var runtime: agent.Runtime = undefined;
    runtime.io = std.testing.io;
    var workbench = try workbench_api.Workbench.init(
        std.testing.allocator,
        &runtime,
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
    var queue: AccountEffectQueue = .{};
    var hook = Hook{ .queue = &queue };
    var coordinator = AccountCoordinator.init(
        &workbench,
        queue.sink(),
        .{ .context = &hook, .dispatch_fn = Hook.dispatch },
        std.Thread.getCurrentId(),
    );
    hook.coordinator = &coordinator;
    var restore_result: account_api.RestoreResult = .{
        .signed_out = .{},
    };
    try std.testing.expectEqual(
        account_contract.ErrorCode.none,
        coordinator.restore(&restore_result),
    );
    try std.testing.expectEqual(@as(usize, 0), hook.dispatch_count);

    const login = coordinator.commandSink().submit(.begin_login);
    try std.testing.expect(login.accepted);
    try std.testing.expectEqual(@as(usize, 1), hook.dispatch_count);
    try std.testing.expectEqual(
        account_contract.AccountSessionState.authorizing,
        coordinator.account.view().session_state,
    );
    try std.testing.expect(queue.entry == null);
}

test "Account login mailbox transfers ownership and latches wake failure" {
    const Wake = struct {
        available: bool = true,
        count: usize = 0,

        fn notify(context: *anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.count += 1;
            return self.available;
        }
    };

    var wake: Wake = .{};
    var effects = AccountEffects.init(
        std.testing.allocator,
        std.testing.io,
        .{ .context = &wake, .notify_fn = Wake.notify },
    );
    defer effects.deinit();
    var result: account_api.LoginAttempt.WorkerResult = .{
        .failed = .fromCode(.oauth_callback_rejected),
    };
    try std.testing.expect(AccountEffects.publishLoginResult(
        &effects,
        7,
        &result,
    ));
    try std.testing.expect(result == .consumed);
    try std.testing.expectEqual(@as(usize, 1), wake.count);
    var mailbox = effects.takeMailbox() orelse
        return error.TestUnexpectedResult;
    defer mailbox.deinit();
    try std.testing.expectEqual(@as(u64, 7), mailbox.login.attempt_id);
    try std.testing.expect(
        mailbox.login.result.failed.error_code ==
            .oauth_callback_rejected,
    );

    wake.available = false;
    effects.publishCompletion(.{
        .attempt_id = 8,
        .payload = .{ .failed = .fromCode(.token_refresh_failed) },
    });
    try std.testing.expect(effects.takeFatal());
    var failed_wake = effects.takeMailbox() orelse
        return error.TestUnexpectedResult;
    defer failed_wake.deinit();
    try std.testing.expectEqual(
        account_contract.ErrorCode.token_refresh_failed,
        failed_wake.completion.payload.failed.error_code,
    );
}

test "unknown logout persistence clears Workbench execution fail closed" {
    var runtime: agent.Runtime = undefined;
    runtime.io = std.testing.io;
    var workbench = try workbench_api.Workbench.init(
        std.testing.allocator,
        &runtime,
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
    var queue: AccountEffectQueue = .{};
    var coordinator = AccountCoordinator.init(
        &workbench,
        queue.sink(),
        .{},
        std.Thread.getCurrentId(),
    );
    var execution = try account_contract.OwnedExecutionConfig.initOwned(
        std.testing.allocator,
        .anthropic,
        try std.testing.allocator.dupe(u8, "model-1"),
        try std.testing.allocator.dupe(
            u8,
            account_contract.metask_anthropic_messages_url,
        ),
        1,
        try std.testing.allocator.dupe(u8, "secret-key"),
    );
    var restore_result: account_api.RestoreResult = .{
        .execution_ready = try .init(
            try .init("account-1", "profile-1", "Metask User"),
            "key-1",
            &execution,
        ),
    };
    execution.deinit();
    try std.testing.expectEqual(
        account_contract.ErrorCode.none,
        coordinator.restore(&restore_result),
    );
    const logout = coordinator.commandSink().submit(.logout);
    try std.testing.expect(logout.accepted);
    try std.testing.expect(
        queue.take().?.effect == .persist_signed_out_tombstone,
    );

    coordinator.logoutPersistenceUnknown();
    const view = workbench.accountView();
    try std.testing.expectEqual(
        account_contract.AccountSessionState.shutting_down,
        view.session_state,
    );
    try std.testing.expectEqual(
        account_contract.ExecutionState.none,
        view.execution_state,
    );
    try std.testing.expect(!view.can_create_task);
    try std.testing.expect(!workbench.executionReplacementPending());
}
