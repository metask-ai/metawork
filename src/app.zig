const std = @import("std");
const builtin = @import("builtin");
const runner = @import("runner");
const native_sdk = @import("native_sdk");
const bridge_api = @import("metawork_bridge");
const automation_api = @import("metawork_automation");
const agent = @import("metawork_agent");
const workbench_api = @import("metawork_workbench");
const account_contract = @import("metawork_account_contract");
const account_api = @import("metawork_account");
const product_identity = @import("metawork_product_identity");
const window_chrome = @import("window_chrome.zig");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const frontend_url_env = "NATIVE_SDK_FRONTEND_URL";
const frontend_dist = "frontend/dist";
const frontend_entry = "index.html";
const pending_ui_json_capacity = 256 * 1024;
const terminal_diagnostic_capacity = 512;
const agent_event_retry_interval: std.Io.Duration = .fromMilliseconds(5);
const agent_event_notification_timeout: std.Io.Duration = .fromMilliseconds(50);
const host_worker_count = 4;
const workbench_snapshot_capacity = bridge_api.snapshot_max_bytes;
const account_refresh_timer_id: u64 = 0x4d57_4143_4354_5246;
const scheduled_task_timer_id: u64 = 0x4d57_5343_4844_544b;
const account_refresh_skew_seconds: i64 = 60;
const account_refresh_retry_ns: u64 = 30 * std.time.ns_per_s;
const FrontendMode = bridge_api.policy.Mode;
const main_window_id: native_sdk.platform.WindowId = 1;
const tray_open_id: native_sdk.platform.TrayItemId = 1;
const tray_quit_id: native_sdk.platform.TrayItemId = 2;
const tray_items = [_]native_sdk.platform.TrayMenuItem{
    .{ .id = tray_open_id, .label = "Open MetaWork", .command = "metawork.tray.open" },
    .{ .separator = true },
    .{ .id = tray_quit_id, .label = "Quit MetaWork", .command = "metawork.tray.quit" },
};
const windows_data_directory_name = "MetaWork";

fn platformDataDirectoryName(os_tag: @TypeOf(builtin.os.tag)) []const u8 {
    return if (os_tag == .macos)
        product_identity.macos_data_directory_name
    else
        windows_data_directory_name;
}

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

const AccountWakeSink = struct {
    context: *anyopaque,
    notify_fn: *const fn (context: *anyopaque) void,

    fn notify(self: AccountWakeSink) void {
        self.notify_fn(self.context);
    }
};

const AccountEffects = struct {
    const MailboxResult = union(enum) {
        login: struct {
            attempt_id: u64,
            result: account_api.LoginAttempt.WorkerResult,
        },
        refresh: struct {
            attempt_id: u64,
            rotation: account_api.CredentialRotation,
        },
        completion: account_api.WorkerCompletion,

        fn deinit(self: *MailboxResult) void {
            switch (self.*) {
                .login => |*entry| entry.result.deinit(),
                .refresh => |*entry| entry.rotation.deinit(),
                .completion => |*completion| completion.deinit(),
            }
        }

        fn attemptId(self: *const MailboxResult) u64 {
            return switch (self.*) {
                .login => |entry| entry.attempt_id,
                .refresh => |entry| entry.attempt_id,
                .completion => |completion| completion.attempt_id,
            };
        }
    };

    allocator: std.mem.Allocator,
    io: std.Io,
    wake: AccountWakeSink,
    transport: account_api.MetaskClient.StdHttpTransport,
    queue: AccountEffectQueue = .{},
    catalog: account_api.Catalog.CatalogSession,
    public_catalog: account_api.Catalog.PublicCatalog = .{},
    mailbox_mutex: std.Io.Mutex = .init,
    mailbox: ?MailboxResult = null,
    login_attempt: account_api.LoginAttempt.LoginAttempt = .{},
    login_active: bool = false,
    network_attempt: account_api.NetworkAttempt.NetworkAttempt = .{},
    mailbox_collision: bool = false,

    fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        wake: AccountWakeSink,
    ) AccountEffects {
        return .{
            .allocator = allocator,
            .io = io,
            .wake = wake,
            .transport = .{ .allocator = allocator, .io = io },
            .catalog = .init(allocator),
        };
    }

    fn sink(self: *AccountEffects) account_api.EffectSink {
        return self.queue.sink();
    }

    fn clientTransport(
        self: *AccountEffects,
    ) account_api.MetaskClient.Transport {
        return self.transport.transport();
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
            self.mailbox_collision = true;
            self.unlockMailbox();
            return false;
        }
        self.mailbox = .{ .login = .{
            .attempt_id = attempt_id,
            .result = result.take(),
        } };
        self.unlockMailbox();
        self.notify();
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
            self.mailbox_collision = true;
            self.unlockMailbox();
            return;
        }
        self.mailbox = .{ .completion = completion };
        self.unlockMailbox();
        self.notify();
    }

    fn networkSink(
        self: *AccountEffects,
    ) account_api.NetworkAttempt.ResultSink {
        return .{ .context = self, .publish_fn = publishNetworkResult };
    }

    fn publishNetworkResult(
        context: *anyopaque,
        attempt_id: u64,
        result: *account_api.NetworkAttempt.Result,
    ) bool {
        const self: *AccountEffects = @ptrCast(@alignCast(context));
        self.lockMailbox();
        if (self.mailbox != null) {
            self.mailbox_collision = true;
            self.unlockMailbox();
            return false;
        }
        self.mailbox = switch (result.take()) {
            .refresh => |rotation| .{ .refresh = .{
                .attempt_id = attempt_id,
                .rotation = rotation,
            } },
            .completion => |completion| .{ .completion = completion },
            .consumed => {
                self.unlockMailbox();
                return false;
            },
        };
        self.unlockMailbox();
        self.notify();
        return true;
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
        platform: *account_api.Platform.NativeBackend,
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
            self.failLoginAttempt(
                attempt_id,
                .oauth_browser_open_failed,
            );
        };
    }

    fn failLoginAttempt(
        self: *AccountEffects,
        attempt_id: u64,
        error_code: account_contract.ErrorCode,
    ) void {
        if (self.login_active) {
            self.login_attempt.cancel();
            self.joinLogin();
        }
        self.replaceWithFailure(attempt_id, error_code);
    }

    fn reopenLogin(
        self: *AccountEffects,
        attempt_id: u64,
        platform: *account_api.Platform.NativeBackend,
    ) void {
        if (!self.login_active or
            !self.login_attempt.matches(attempt_id))
        {
            self.failLoginAttempt(
                attempt_id,
                .dependency_contract_invalid,
            );
            return;
        }
        platform.openAuthorizationUrl(
            self.login_attempt.authorizationUrl(),
        ) catch {
            self.failLoginAttempt(
                attempt_id,
                .oauth_browser_open_failed,
            );
        };
    }

    fn startRefresh(
        self: *AccountEffects,
        attempt_id: u64,
        credentials: *const account_api.CredentialOwner,
        now_unix_seconds: i64,
        expected_identity: ?account_api.AccountIdentity,
    ) void {
        self.network_attempt.startRefresh(
            self.allocator,
            self.io,
            attempt_id,
            self.clientTransport(),
            credentials,
            expected_identity,
            self.networkSink(),
            now_unix_seconds,
        ) catch {
            self.publishCompletion(.{
                .attempt_id = attempt_id,
                .payload = .{ .failed = .fromCode(
                    .local_resource_exhausted,
                ) },
            });
        };
    }

    fn startLoadApiKeys(
        self: *AccountEffects,
        attempt_id: u64,
        credentials: *const account_api.CredentialOwner,
        identity: account_api.AccountIdentity,
    ) void {
        self.network_attempt.startLoadApiKeys(
            self.allocator,
            self.io,
            attempt_id,
            self.clientTransport(),
            credentials,
            identity,
            &self.catalog,
            self.networkSink(),
        ) catch {
            self.publishCompletion(.{
                .attempt_id = attempt_id,
                .payload = .{ .failed = .fromCode(
                    .local_resource_exhausted,
                ) },
            });
        };
    }

    fn startLoadModels(
        self: *AccountEffects,
        attempt_id: u64,
        api_key_id: []const u8,
    ) void {
        self.network_attempt.startLoadModels(
            self.allocator,
            self.io,
            attempt_id,
            self.clientTransport(),
            &self.catalog,
            api_key_id,
            self.networkSink(),
        ) catch {
            self.publishCompletion(.{
                .attempt_id = attempt_id,
                .payload = .{ .failed = .fromCode(
                    .local_resource_exhausted,
                ) },
            });
        };
    }

    fn cancelAttemptAndDiscard(
        self: *AccountEffects,
        attempt_id: u64,
    ) void {
        if (!self.login_active or
            self.login_attempt.attempt_id != attempt_id)
        {
            if (self.network_attempt.matches(attempt_id)) {
                self.network_attempt.cancel();
                self.network_attempt.join();
                self.network_attempt.deinit();
            }
        } else {
            self.login_attempt.cancel();
            self.joinLogin();
        }
        if (self.takeMailbox()) |value| {
            var stale = value;
            if (stale.attemptId() != attempt_id)
                @panic("Account cancel discarded another attempt");
            stale.deinit();
        }
        _ = self.takeCollision();
        // A private catalog is always attempt-scoped. After its network worker
        // has already completed, `NetworkAttempt` no longer identifies the
        // catalog attempt, but cancellation must still secure-zero the staged
        // API credential and models.
        self.catalog.reset();
    }

    fn joinLogin(self: *AccountEffects) void {
        if (!self.login_active) return;
        self.login_attempt.join();
        self.login_attempt.deinit();
        self.login_active = false;
    }

    fn joinNetwork(self: *AccountEffects, attempt_id: u64) void {
        if (!self.network_attempt.matches(attempt_id)) return;
        self.network_attempt.join();
        self.network_attempt.deinit();
    }

    fn cancelJoinAndDiscard(self: *AccountEffects) void {
        if (self.login_active) {
            self.login_attempt.cancel();
            self.joinLogin();
        }
        if (self.network_attempt.started) {
            self.network_attempt.cancel();
            self.network_attempt.join();
            self.network_attempt.deinit();
        }
        if (self.takeMailbox()) |value| {
            var discarded = value;
            discarded.deinit();
        }
        _ = self.takeCollision();
        self.catalog.reset();
        self.public_catalog.clear();
    }

    fn deinit(self: *AccountEffects) void {
        self.cancelJoinAndDiscard();
        std.debug.assert(self.queue.entry == null);
        self.catalog.deinit();
        self.* = undefined;
    }

    fn clearCatalog(self: *AccountEffects) void {
        self.catalog.reset();
        self.public_catalog.clear();
    }

    fn notify(self: *AccountEffects) void {
        self.wake.notify();
    }

    fn takeCollision(self: *AccountEffects) bool {
        self.lockMailbox();
        defer self.unlockMailbox();
        const collision = self.mailbox_collision;
        self.mailbox_collision = false;
        return collision;
    }

    fn lockMailbox(self: *AccountEffects) void {
        self.mailbox_mutex.lockUncancelable(self.io);
    }

    fn unlockMailbox(self: *AccountEffects) void {
        self.mailbox_mutex.unlock(self.io);
    }
};

const ExecutionReplacement = enum { none, default, identity };

fn accountSelectionCommand(
    selection_id: []const u8,
    view: account_contract.AccountView,
) account_contract.AccountSelectionCommand {
    return .{
        .selection_id = selection_id,
        .expected_catalog_generation = view.catalog_generation,
        .expected_execution_generation = view.execution_generation,
    };
}

const AccountCoordinator = struct {
    account: account_api.Account = .initRestoring(),
    workbench: *workbench_api.Workbench,
    public_catalog: *account_api.Catalog.PublicCatalog,
    candidate_public_catalog: account_api.Catalog.PublicCatalog = .{},
    effects: account_api.EffectSink,
    effect_commit_hook: AccountEffectCommitHook,
    main_thread_id: std.Thread.Id,

    fn init(
        workbench: *workbench_api.Workbench,
        public_catalog: *account_api.Catalog.PublicCatalog,
        effects: account_api.EffectSink,
        effect_commit_hook: AccountEffectCommitHook,
        main_thread_id: std.Thread.Id,
    ) AccountCoordinator {
        return .{
            .workbench = workbench,
            .public_catalog = public_catalog,
            .effects = effects,
            .effect_commit_hook = effect_commit_hook,
            .main_thread_id = main_thread_id,
        };
    }

    fn commandSink(self: *AccountCoordinator) account_contract.AccountCommandSink {
        return .{ .context = self, .submit_fn = submitCommand };
    }

    fn decorateAccountView(
        self: *AccountCoordinator,
        view: *account_contract.AccountView,
    ) void {
        const catalog = switch (view.operation) {
            .selecting_key,
            .loading_models,
            .selecting_model,
            .persisting,
            => &self.candidate_public_catalog,
            else => self.public_catalog,
        };
        catalog.decorate(view);
    }

    fn submitCommand(
        context: *anyopaque,
        command: account_contract.AccountCommand,
    ) account_contract.AccountCommandResult {
        const self: *AccountCoordinator = @ptrCast(@alignCast(context));
        self.assertMainThread();
        var view = self.account.view();
        self.decorateAccountView(&view);
        switch (command) {
            .select_api_key => |selection| {
                if (selection.expected_catalog_generation != view.catalog_generation or
                    selection.expected_execution_generation != view.execution_generation)
                    return .rejected(.generation_mismatch);
                const member = for (view.api_keys) |candidate| {
                    if (std.mem.eql(u8, candidate.id, selection.selection_id)) break true;
                } else false;
                if (!member) return .rejected(.invalid_command);
            },
            .select_model => |selection| {
                if (selection.expected_catalog_generation != view.catalog_generation or
                    selection.expected_execution_generation != view.execution_generation)
                    return .rejected(.generation_mismatch);
                const member = for (view.models) |candidate| {
                    if (std.mem.eql(u8, candidate.id, selection.selection_id)) break true;
                } else false;
                if (!member) return .rejected(.invalid_command);
            },
            else => {},
        }
        const replacement: ExecutionReplacement = switch (command) {
            .select_model => .default,
            .reauthenticate, .logout => .identity,
            else => .none,
        };
        const prepared = self.account.prepareCommand(command);
        return switch (prepared) {
            .transition => |value| result: {
                switch (replacement) {
                    .none => {},
                    .default => self.workbench.beginDefaultExecutionReplacement() catch {
                        var rejected = value;
                        rejected.deinit();
                        break :result .rejected(.execution_in_use);
                    },
                    .identity => self.workbench.beginExecutionReplacement() catch {
                        var rejected = value;
                        rejected.deinit();
                        break :result .rejected(.execution_in_use);
                    },
                }
                const fact = value.fact();
                const promotes_refreshed_catalog =
                    fact.kind == .catalog_changed and
                    fact.view.operation == .none and
                    fact.view.execution_state == .ready;
                if (promotes_refreshed_catalog)
                    self.public_catalog.replaceFromPublic(
                        &self.candidate_public_catalog,
                    );
                const committed = self.commitTransition(value);
                if (committed.accepted and promotes_refreshed_catalog)
                    self.candidate_public_catalog.clear();
                break :result committed;
            },
            .rejected => |error_code| .rejected(error_code),
            .ignored_stale => unreachable,
        };
    }

    fn restore(
        self: *AccountCoordinator,
        restore_result: *account_api.RestoreResult,
    ) account_contract.ErrorCode {
        self.assertMainThread();
        self.candidate_public_catalog.clear();
        self.workbench.beginExecutionReplacement() catch {
            restore_result.deinit();
            return .execution_in_use;
        };
        switch (restore_result.*) {
            .execution_ready => |*ready| {
                const input = ready.execution.input();
                self.public_catalog.replaceRestoredSelection(
                    ready.apiKeyId(),
                    input.target.provider_kind,
                    input.target.model,
                );
            },
            .signed_out, .account_only => self.public_catalog.clear(),
        }
        const prepared = self.account.prepareRestore(restore_result);
        return switch (prepared) {
            .transition => |value| if (self.commitTransition(value).accepted)
                .none
            else
                .local_resource_exhausted,
            .rejected => |error_code| result: {
                self.public_catalog.clear();
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
            .transition => |value| result: {
                const commits_candidate = value.execution != null;
                if (commits_candidate)
                    self.public_catalog.replaceFromPublic(
                        &self.candidate_public_catalog,
                    );
                const committed = self.commitTransition(value).accepted;
                if (committed and commits_candidate)
                    self.candidate_public_catalog.clear();
                break :result committed;
            },
            .rejected => false,
            .ignored_stale => false,
        };
    }

    fn publishCandidateCatalogNoFail(
        self: *AccountCoordinator,
        catalog: *const account_api.Catalog.CatalogSession,
    ) void {
        self.candidate_public_catalog.replaceFromSession(catalog);
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

    fn restoreSignedOutFailure(
        self: *AccountCoordinator,
        failure: account_api.WorkerFailure,
    ) void {
        self.assertMainThread();
        const prepared = self.account.prepareSignedOutRestoreFailure(failure);
        switch (prepared) {
            .transition => |value| {
                const committed = self.commitTransition(value);
                std.debug.assert(committed.accepted);
            },
            .rejected, .ignored_stale => @panic(
                "recoverable Account restore failure was published outside restoring",
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

    fn executionPersistenceUnknown(self: *AccountCoordinator) void {
        self.assertMainThread();
        std.debug.assert(self.workbench.executionReplacementPending());
        const prepared = self.account.prepareExecutionPersistenceUnknown();
        switch (prepared) {
            .transition => |value| {
                const committed = self.commitTransition(value);
                std.debug.assert(committed.accepted);
            },
            .rejected, .ignored_stale => @panic(
                "execution persistence outcome lost its active attempt",
            ),
        }
    }

    fn refreshToken(self: *AccountCoordinator) bool {
        self.assertMainThread();
        const prepared = self.account.prepareTokenRefresh();
        return switch (prepared) {
            .transition => |value| self.commitTransition(value).accepted,
            .rejected, .ignored_stale => false,
        };
    }

    fn startCatalogContinuation(self: *AccountCoordinator) void {
        self.assertMainThread();
        const result = submitCommand(self, .refresh_catalog);
        if (result.accepted) return;
        const prepared = self.account.prepareIdleFailure(result.error_code);
        switch (prepared) {
            .transition => |value| {
                const committed = self.commitTransition(value);
                std.debug.assert(committed.accepted);
            },
            .rejected, .ignored_stale => @panic(
                "Account catalog continuation failed without a recoverable state",
            ),
        }
    }

    fn restoredRefreshAdmissionFailure(
        self: *AccountCoordinator,
        error_code: account_contract.ErrorCode,
    ) void {
        self.assertMainThread();
        const prepared = self.account.prepareRestoredRefreshAdmissionFailure(
            error_code,
        );
        switch (prepared) {
            .transition => |value| {
                const committed = self.commitTransition(value);
                std.debug.assert(committed.accepted);
            },
            .rejected, .ignored_stale => @panic(
                "restored refresh admission failure lost its account-only state",
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

        var fact = prepared.fact();
        if (fact.view.session_state == .signed_out or
            fact.view.session_state == .shutting_down)
        {
            self.public_catalog.clear();
            self.candidate_public_catalog.clear();
        }
        if (self.workbench.executionReplacementPending() and
            fact.view.operation == .none and
            fact.view.execution_state == .none)
        {
            self.public_catalog.clear();
            self.candidate_public_catalog.clear();
        }
        self.decorateAccountView(&fact.view);
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
        if (fact.kind == .operation_failed)
            self.candidate_public_catalog.clear();
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
    frontend_asset_root: []const u8,
    main_thread_id: std.Thread.Id,
    automation: automation_api.Runtime = .{},
    dispatcher: ?*bridge_api.Dispatcher = null,
    agent_runtime: ?*agent.Runtime = null,
    workbench: ?*workbench_api.Workbench = null,
    agent_shutdown: bool = false,
    agent_event_wake_pending: std.atomic.Value(bool) = .init(false),
    native_runtime: ?*native_sdk.Runtime = null,
    platform_services: ?native_sdk.platform.PlatformServices = null,
    tray_installed: bool = false,
    account_coordinator: ?*AccountCoordinator = null,
    account_effects: ?*AccountEffects = null,
    account_platform: ?account_api.Platform.NativeBackend = null,
    account_credentials: account_api.CredentialOwner = .{},
    windows_public_state: ?account_api.WindowsStore.PublicState = null,
    catalog_after_refresh: bool = false,
    account_dir_storage: [4096]u8 = undefined,
    account_dir_len: usize = 0,

    fn app(self: *@This()) native_sdk.App {
        return .{
            .context = self,
            .name = "metawork",
            .source = native_sdk.frontend.productionSource(.{
                .dist = self.frontend_asset_root,
                .entry = frontend_entry,
            }),
            .source_fn = source,
            .start_fn = start,
            .event_fn = event,
            .stop_fn = stop,
        };
    }

    fn source(context: *anyopaque) anyerror!native_sdk.WebViewSource {
        const self: *@This() = @ptrCast(@alignCast(context));
        return native_sdk.frontend.sourceFromEnv(self.env_map, .{
            .dist = self.frontend_asset_root,
            .entry = frontend_entry,
        });
    }

    fn start(context: *anyopaque, native_runtime: *native_sdk.Runtime) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.native_runtime = native_runtime;
        self.platform_services = native_runtime.options.platform.services;
        try self.installScheduleHost();
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
        if (self.tray_installed) {
            if (self.platform_services) |services| services.removeTray() catch {};
            self.tray_installed = false;
        }
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
        self.account_platform = account_api.Platform.NativeBackend.init(
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
        if (builtin.os.tag == .windows) {
            self.restoreWindowsAccount(coordinator);
        } else {
            self.restoreMacosAccount(coordinator);
        }
    }

    fn restoreWindowsAccount(
        self: *@This(),
        coordinator: *AccountCoordinator,
    ) void {
        var restored = account_api.WindowsStore.restore(
            std.heap.c_allocator,
            self.account_platform.?.backend(),
        ) catch |err| {
            self.account_credentials.clear();
            self.windows_public_state = null;
            coordinator.restoreSignedOutFailure(.fromCode(
                accountRestoreError(err),
            ));
            return;
        };
        defer restored.deinit();
        switch (restored) {
            .signed_out => {
                self.account_credentials.clear();
                self.windows_public_state = null;
                var signed_out: account_api.RestoreResult = .{
                    .signed_out = .{},
                };
                std.debug.assert(coordinator.restore(&signed_out) == .none);
            },
            .account => |*account| {
                const identity = account.public_state.identity() catch {
                    self.account_credentials.clear();
                    self.windows_public_state = null;
                    var signed_out: account_api.RestoreResult = .{
                        .signed_out = .{},
                    };
                    std.debug.assert(coordinator.restore(&signed_out) == .none);
                    return;
                };
                self.windows_public_state = account.public_state;
                self.account_credentials.installRefreshToken(
                    &account.refresh_token,
                );
                var state_restore: account_api.RestoreResult = .{
                    .account_only = .{ .identity = identity },
                };
                std.debug.assert(coordinator.restore(&state_restore) == .none);
                self.catalog_after_refresh = true;
                if (!coordinator.refreshToken()) {
                    self.catalog_after_refresh = false;
                    coordinator.restoredRefreshAdmissionFailure(
                        .local_resource_exhausted,
                    );
                }
            },
        }
    }

    fn restoreMacosAccount(
        self: *@This(),
        coordinator: *AccountCoordinator,
    ) void {
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
                coordinator.startCatalogContinuation();
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
        self.scheduleAccountRefresh();
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

    fn scheduleAccountRefresh(self: *@This()) void {
        const services = self.platform_services orelse return;
        const expires_at = self.account_credentials.expiresAt() orelse {
            services.cancelTimer(account_refresh_timer_id) catch {};
            return;
        };
        const now = wallUnixSeconds(self.io) orelse return;
        const refresh_at = expires_at -|
            account_refresh_skew_seconds;
        if (refresh_at <= now) {
            if (self.account_coordinator) |coordinator|
                if (coordinator.refreshToken()) return;
            services.startTimer(
                account_refresh_timer_id,
                account_refresh_retry_ns,
                false,
            ) catch {};
            return;
        }
        const seconds: u64 = @intCast(refresh_at - now);
        const interval_ns = std.math.mul(
            u64,
            seconds,
            std.time.ns_per_s,
        ) catch std.math.maxInt(u64);
        services.startTimer(
            account_refresh_timer_id,
            @max(interval_ns, 1),
            false,
        ) catch {};
    }

    fn onAccountRefreshTimer(self: *@This()) void {
        const coordinator = self.account_coordinator orelse return;
        if (coordinator.refreshToken()) return;
        if (!self.account_credentials.available()) return;
        if (self.platform_services) |services|
            services.startTimer(
                account_refresh_timer_id,
                account_refresh_retry_ns,
                false,
            ) catch {};
    }

    fn cancelAccountRefreshTimer(self: *@This()) void {
        if (self.platform_services) |services|
            services.cancelTimer(account_refresh_timer_id) catch {};
    }

    fn deinitAccountPlatform(self: *@This()) void {
        self.cancelAccountRefreshTimer();
        self.account_credentials.deinit();
        self.windows_public_state = null;
        self.catalog_after_refresh = false;
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
        const effect_argument = entry.effect.argument();
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
            .reopen_oauth => {
                const attempt_id = entry.attempt_id orelse
                    @panic("OAuth reopen effect has no attempt");
                const platform = if (self.account_platform) |*value|
                    value
                else {
                    effects.failLoginAttempt(
                        attempt_id,
                        .credential_store_read_failed,
                    );
                    return;
                };
                effects.reopenLogin(attempt_id, platform);
            },
            .cancel_attempt => |attempt_id| effects.cancelAttemptAndDiscard(attempt_id),
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
                const cleanup_pending = if (builtin.os.tag == .windows) blk: {
                    account_api.WindowsStore.commitSignedOut(
                        platform.backend(),
                    ) catch |err| {
                        effects.publishCompletion(.{
                            .attempt_id = attempt_id,
                            .payload = .{ .failed = .fromCode(
                                accountStoreError(err),
                            ) },
                        });
                        return;
                    };
                    self.windows_public_state = null;
                    break :blk false;
                } else account_api.CredentialStore.commitSignedOut(
                    platform.backend(),
                    coordinator.account.executionHighWatermark(),
                ) catch |err| {
                    if (err == error.PersistenceOutcomeUnknown) {
                        self.account_credentials.clear();
                        self.account_credentials.setCleanupPending(true);
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
                self.cancelAccountRefreshTimer();
                effects.clearCatalog();
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
            .refresh_token => {
                const attempt_id = entry.attempt_id orelse
                    @panic("token refresh effect has no attempt");
                if (!self.account_credentials.refreshAvailable()) {
                    effects.publishCompletion(.{
                        .attempt_id = attempt_id,
                        .payload = .{ .failed = .fromCode(
                            .credential_store_read_failed,
                        ) },
                    });
                    return;
                }
                const now_unix_seconds = wallUnixSeconds(self.io) orelse {
                    effects.publishCompletion(.{
                        .attempt_id = attempt_id,
                        .payload = .{ .failed = .fromCode(
                            .dependency_contract_invalid,
                        ) },
                    });
                    return;
                };
                effects.startRefresh(
                    attempt_id,
                    &self.account_credentials,
                    now_unix_seconds,
                    if (self.catalog_after_refresh)
                        coordinator.account.currentIdentity()
                    else
                        null,
                );
            },
            .load_api_keys => {
                const attempt_id = entry.attempt_id orelse
                    @panic("API Key effect has no attempt");
                if (!self.account_credentials.available()) {
                    effects.publishCompletion(.{
                        .attempt_id = attempt_id,
                        .payload = .{ .failed = .fromCode(
                            .credential_store_read_failed,
                        ) },
                    });
                    return;
                }
                const identity = coordinator.account.currentIdentity() orelse {
                    effects.publishCompletion(.{
                        .attempt_id = attempt_id,
                        .payload = .{ .failed = .fromCode(
                            .dependency_contract_invalid,
                        ) },
                    });
                    return;
                };
                effects.startLoadApiKeys(
                    attempt_id,
                    &self.account_credentials,
                    identity,
                );
            },
            .load_models => {
                const attempt_id = entry.attempt_id orelse
                    @panic("model catalog effect has no attempt");
                effects.startLoadModels(
                    attempt_id,
                    effect_argument orelse
                        @panic("model catalog effect has no API Key"),
                );
            },
            .prepare_execution => {
                const attempt_id = entry.attempt_id orelse
                    @panic("execution persistence effect has no attempt");
                self.prepareAndPersistExecution(
                    attempt_id,
                    effect_argument orelse
                        @panic("execution effect has no model"),
                );
            },
        }
    }

    fn prepareAndPersistExecution(
        self: *@This(),
        attempt_id: u64,
        model: []const u8,
    ) void {
        const effects = self.account_effects orelse
            @panic("Account effects are not composed");
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
        const identity = coordinator.account.currentIdentity() orelse {
            self.completeAccountFailure(
                attempt_id,
                .dependency_contract_invalid,
            );
            return;
        };
        const account_view = coordinator.account.view();
        defer effects.catalog.reset();
        const execution_generation = std.math.add(
            u64,
            coordinator.account.executionHighWatermark(),
            1,
        ) catch {
            self.completeAccountFailure(
                attempt_id,
                .generation_mismatch,
            );
            return;
        };
        var execution = switch (prepareCatalogExecution(
            &effects.catalog,
            &identity,
            account_view.model_catalog_api_key_id,
            model,
            execution_generation,
        )) {
            .ready => |owned| owned,
            .rejected => |error_code| {
                self.completeAccountFailure(attempt_id, error_code);
                return;
            },
        };
        defer execution.deinit();
        if (builtin.os.tag == .windows) {
            self.windows_public_state = account_api.WindowsStore.commitSelection(
                platform.backend(),
                identity,
                effects.catalog.selectedApiKeyId(),
                model,
            ) catch |err| {
                self.completeAccountFailure(
                    attempt_id,
                    accountStoreError(err),
                );
                return;
            };
        } else {
            var credential_generation: account_api.CredentialStore.Generation = undefined;
            std.Io.randomSecure(self.io, &credential_generation) catch {
                self.completeAccountFailure(
                    attempt_id,
                    .local_resource_exhausted,
                );
                return;
            };
            const committed = account_api.CredentialStore.commitExecutionReady(
                platform.backend(),
                credential_generation,
                identity.accountId(),
                identity.profileId(),
                effects.catalog.selectedApiKeyId(),
                &execution,
            ) catch |err| {
                if (err == error.PersistenceOutcomeUnknown) {
                    effects.public_catalog.clear();
                    coordinator.executionPersistenceUnknown();
                    return;
                }
                self.completeAccountFailure(
                    attempt_id,
                    accountStoreError(err),
                );
                return;
            };
            self.account_credentials.setCleanupPending(
                self.account_credentials.cleanupPending() or
                    committed.retired_cleanup_pending,
            );
        }
        effects.publishCompletion(.{
            .attempt_id = attempt_id,
            .payload = .{ .execution_ready = execution.take() },
        });
        if (builtin.os.tag != .windows) self.retryAccountCleanup();
    }

    fn commitRefreshedTokens(
        self: *@This(),
        attempt_id: u64,
        rotation: *account_api.CredentialRotation,
    ) void {
        const coordinator = self.account_coordinator orelse
            @panic("Account coordinator is not composed");
        const continue_catalog = self.catalog_after_refresh;
        self.catalog_after_refresh = false;
        const identity = coordinator.account.currentIdentity() orelse {
            self.completeAccountFailure(
                attempt_id,
                .dependency_contract_invalid,
            );
            return;
        };
        if (continue_catalog) {
            const refreshed_identity = rotation.refreshedIdentity() orelse {
                self.completeAccountFailure(
                    attempt_id,
                    .dependency_contract_invalid,
                );
                return;
            };
            if (!std.mem.eql(
                u8,
                refreshed_identity.accountId(),
                identity.accountId(),
            ) or !std.mem.eql(
                u8,
                refreshed_identity.profileId(),
                identity.profileId(),
            )) {
                self.completeAccountFailure(
                    attempt_id,
                    .account_mismatch,
                );
                return;
            }
        }
        if (rotation.accountId().len > 0 and
            !std.mem.eql(
                u8,
                rotation.accountId(),
                identity.accountId(),
            ))
        {
            self.completeAccountFailure(
                attempt_id,
                .account_mismatch,
            );
            return;
        }
        const platform = if (self.account_platform) |*value|
            value
        else {
            self.completeAccountFailure(
                attempt_id,
                .credential_store_write_failed,
            );
            return;
        };
        var cleanup_pending = false;
        if (builtin.os.tag == .windows) {
            account_api.WindowsStore.commitRefresh(
                platform.backend(),
                &rotation.persistenceInput().refresh_token,
            ) catch |err| {
                self.completeAccountFailure(
                    attempt_id,
                    accountStoreError(err),
                );
                return;
            };
        } else {
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
                rotation.persistenceInput(),
                &identity,
                coordinator.account.executionHighWatermark(),
            ) catch |err| {
                self.completeAccountFailure(
                    attempt_id,
                    accountStoreError(err),
                );
                return;
            };
            cleanup_pending = committed.retired_cleanup_pending;
        }
        self.account_credentials.replaceRotation(rotation);
        self.account_credentials.setCleanupPending(
            self.account_credentials.cleanupPending() or
                cleanup_pending,
        );
        var completion: account_api.WorkerCompletion = .{
            .attempt_id = attempt_id,
            .payload = .token_refreshed,
        };
        defer completion.deinit();
        if (!coordinator.complete(&completion))
            @panic("persisted Account refresh could not commit");
        if (builtin.os.tag != .windows) self.retryAccountCleanup();
        self.scheduleAccountRefresh();
        if (continue_catalog) {
            coordinator.startCatalogContinuation();
        }
    }

    fn drainAccountEffects(self: *@This()) void {
        const effects = self.account_effects orelse return;
        const coordinator = self.account_coordinator orelse return;
        while (effects.takeMailbox()) |mailbox_value| {
            var mailbox = mailbox_value;
            defer mailbox.deinit();
            const mailbox_collision = effects.takeCollision();
            switch (mailbox) {
                .login => |*entry| {
                    effects.joinLogin();
                    if (coordinator.account.activeAttempt() !=
                        entry.attempt_id)
                        continue;
                    if (mailbox_collision) {
                        var completion: account_api.WorkerCompletion = .{
                            .attempt_id = entry.attempt_id,
                            .payload = .{ .failed = .fromCode(
                                .dependency_contract_invalid,
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
                .refresh => |*entry| {
                    effects.joinNetwork(entry.attempt_id);
                    if (coordinator.account.activeAttempt() !=
                        entry.attempt_id)
                        continue;
                    if (mailbox_collision) {
                        self.completeAccountFailure(
                            entry.attempt_id,
                            .dependency_contract_invalid,
                        );
                        continue;
                    }
                    self.commitRefreshedTokens(
                        entry.attempt_id,
                        &entry.rotation,
                    );
                },
                .completion => |*completion| {
                    const account_operation =
                        coordinator.account.view().operation;
                    if (self.catalog_after_refresh and
                        account_operation == .token_exchange and
                        completion.payload == .failed)
                        self.catalog_after_refresh = false;
                    const catalog_attempt =
                        account_operation == .loading_keys or
                        account_operation == .loading_models;
                    effects.joinNetwork(completion.attempt_id);
                    if (mailbox_collision and
                        coordinator.account.activeAttempt() ==
                            completion.attempt_id)
                    {
                        completion.deinit();
                        completion.* = .{
                            .attempt_id = completion.attempt_id,
                            .payload = .{ .failed = .fromCode(
                                .dependency_contract_invalid,
                            ) },
                        };
                    }
                    if (catalog_attempt and completion.payload == .failed)
                        effects.catalog.reset();
                    const account_view = coordinator.account.view();
                    const automatic_selection: union(enum) {
                        none,
                        api_key: []const u8,
                        model: []const u8,
                    } = switch (completion.payload) {
                        .api_keys_loaded => if (self.automaticApiSelection(
                            &effects.catalog,
                            account_view,
                        )) |id| .{ .api_key = id } else .none,
                        .models_loaded => if (self.automaticModelSelection(
                            &effects.catalog,
                            account_view,
                        )) |id| .{ .model = id } else .none,
                        else => .none,
                    };
                    if (coordinator.account.activeAttempt() ==
                        completion.attempt_id)
                    {
                        switch (completion.payload) {
                            .api_keys_loaded, .models_loaded => coordinator.publishCandidateCatalogNoFail(
                                &effects.catalog,
                            ),
                            else => {},
                        }
                    }
                    if (coordinator.complete(completion)) {
                        switch (automatic_selection) {
                            .none => {},
                            .api_key => |id| _ = AccountCoordinator.submitCommand(
                                coordinator,
                                .{ .select_api_key = accountSelectionCommand(
                                    id,
                                    coordinator.account.view(),
                                ) },
                            ),
                            .model => |id| _ = AccountCoordinator.submitCommand(
                                coordinator,
                                .{ .select_model = accountSelectionCommand(
                                    id,
                                    coordinator.account.view(),
                                ) },
                            ),
                        }
                    }
                },
            }
        }
    }

    fn automaticApiSelection(
        self: *const @This(),
        catalog: *const account_api.Catalog.CatalogSession,
        view: account_contract.AccountView,
    ) ?[]const u8 {
        if (view.execution_state == .ready) {
            if (view.candidate_api_key_id.len != 0) return null;
            if (catalog.hasApiKey(view.selected_api_key_id))
                return view.selected_api_key_id;
            return null;
        }
        if (view.execution_state != .none) return null;
        if (builtin.os.tag == .windows) if (self.windows_public_state) |*saved| {
            const id = saved.apiKeyId();
            if (id.len > 0 and catalog.hasApiKey(id)) return id;
        };
        return catalog.uniqueApiKeyId();
    }

    fn automaticModelSelection(
        self: *const @This(),
        catalog: *const account_api.Catalog.CatalogSession,
        view: account_contract.AccountView,
    ) ?[]const u8 {
        if (view.execution_state == .ready) {
            if (view.candidate_model.len != 0 or
                !std.mem.eql(
                    u8,
                    catalog.selectedApiKeyId(),
                    view.selected_api_key_id,
                ))
                return null;
            if (catalog.hasModel(view.selected_model))
                return view.selected_model;
            return null;
        }
        if (view.execution_state != .none) return null;
        if (builtin.os.tag == .windows) if (self.windows_public_state) |*saved| {
            const id = saved.modelId();
            if (id.len > 0 and
                std.mem.eql(
                    u8,
                    catalog.selectedApiKeyId(),
                    saved.apiKeyId(),
                ) and catalog.hasModel(id)) return id;
        };
        return catalog.uniqueModelId();
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
        var cleanup_pending = false;
        if (builtin.os.tag == .windows) {
            self.windows_public_state = account_api.WindowsStore.commitAuthenticated(
                platform.backend(),
                &login.tokens.refresh_token,
                login.identity,
            ) catch |err| {
                self.completeAccountFailure(
                    attempt_id,
                    accountStoreError(err),
                );
                return;
            };
        } else {
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
            cleanup_pending = committed.retired_cleanup_pending;
        }
        self.account_credentials.replace(&login.tokens);
        self.account_credentials.setCleanupPending(cleanup_pending);
        var completion: account_api.WorkerCompletion = .{
            .attempt_id = attempt_id,
            .payload = .{ .authenticated = login.identity },
        };
        defer completion.deinit();
        if (!coordinator.complete(&completion))
            @panic("persisted Account login could not commit");
        coordinator.startCatalogContinuation();
        if (builtin.os.tag != .windows) self.retryAccountCleanup();
        self.scheduleAccountRefresh();
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
        if (builtin.os.tag == .windows) return;
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
                if (self.dispatcher) |dispatcher| if (dispatcher.connectedWindow() != null) {
                    try dispatcher.emitWorkbenchChanged();
                };
            },
            .timer => |timer| {
                if (timer.id == account_refresh_timer_id) {
                    self.onAccountRefreshTimer();
                    return;
                }
                if (timer.id == scheduled_task_timer_id) {
                    if (self.workbench) |workbench| {
                        workbench.onScheduledTaskTimer();
                        if (self.dispatcher) |dispatcher|
                            try dispatcher.emitWorkbenchChanged();
                    }
                    return;
                }
                if (self.dispatcher != null and
                    self.dispatcher.?.onTimer(timer.id))
                {
                    try self.dispatcher.?.emitWorkbenchChanged();
                }
            },
            .command => |command| if (command.source == .tray) switch (command.tray_item_id) {
                tray_open_id => self.showMainWindow(),
                tray_quit_id => self.requestExplicitQuit(),
                else => {},
            },
            else => {},
        }
    }

    fn installScheduleHost(self: *@This()) anyerror!void {
        const services = self.platform_services orelse
            return error.RuntimeUnavailable;
        try services.createTray(.{
            .tooltip = "MetaWork",
            .items = &tray_items,
        });
        self.tray_installed = true;
        if (self.workbench) |workbench|
            workbench.setScheduleBackgroundAvailableNoFail(true);
    }

    fn showMainWindow(self: *@This()) void {
        const services = self.platform_services orelse return;
        services.showWindow(main_window_id) catch return;
        services.focusWindow(main_window_id) catch {};
    }

    fn requestExplicitQuit(self: *@This()) void {
        const services = self.platform_services orelse return;
        if (self.workbench) |workbench| if (workbench.hasEnabledScheduledTasks()) {
            const result = services.showMessageDialog(.{
                .style = .warning,
                .title = "Quit MetaWork?",
                .message = "Scheduled tasks will pause while MetaWork is not running.",
                .informative_text = "Closing the main window keeps them running. Use Quit only when you want to stop the background host.",
                .primary_button = "Keep Running",
                .secondary_button = "Quit MetaWork",
            }) catch return;
            if (result != .secondary) return;
        };
        services.quitApp() catch {};
    }

    fn notifyScheduledTask(
        context: ?*anyopaque,
        notification: workbench_api.ScheduleNotification,
    ) bool {
        const self: *@This() = @ptrCast(@alignCast(context orelse return false));
        const services = self.platform_services orelse return false;
        const body = switch (notification.kind) {
            .completed => "Scheduled task completed",
            .failed => "Scheduled task failed",
            .skipped => "A run was skipped because the previous run is still active",
            .needs_attention => "Scheduled task needs attention",
        };
        services.showNotification(.{
            .title = "MetaWork",
            .subtitle = notification.title,
            .body = body,
        }) catch return false;
        return true;
    }

    fn bridge(self: *@This(), mode: FrontendMode) native_sdk.BridgeDispatcher {
        return (self.dispatcher orelse @panic("Bridge Dispatcher is not composed")).register(
            self.automation.productPolicy(bridge_api.policy.product(mode)),
        );
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

    fn notifyAccountEffects(context: *anyopaque) void {
        if (!notifyMainLoop(context))
            @panic("Account completion lost its required main-loop wake");
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
            .begin_window_drag_fn = platformBeginWindowDrag,
            .window_control_fn = platformWindowControl,
            .window_state_fn = platformWindowState,
            .now_fn = platformNow,
            .on_main_thread_fn = platformOnMainThread,
        };
    }

    fn dispatcherAutomationAuthority(self: *@This()) bridge_api.DispatcherAutomationAuthority {
        return .{
            .context = self,
            .active_fn = automationActive,
            .workspace_root_fn = automationWorkspaceRoot,
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
        if (self.automation.active() and std.mem.eql(u8, name, bridge_api.product_event_name)) {
            std.debug.print("metawork.product_delivery.emit event={s} main_thread={}\n", .{
                name,
                std.Thread.getCurrentId() == self.main_thread_id,
            });
        }
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

    fn scheduledTaskNow(context: ?*anyopaque) ?u64 {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        const now = wallUnixSeconds(self.io) orelse return null;
        return @intCast(now);
    }

    fn armScheduledTaskTimer(
        context: ?*anyopaque,
        due_unix_seconds: u64,
    ) bool {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        const now = scheduledTaskNow(context) orelse return false;
        const delay_seconds = if (due_unix_seconds > now)
            due_unix_seconds - now
        else
            1;
        const delay_ns = std.math.mul(
            u64,
            delay_seconds,
            std.time.ns_per_s,
        ) catch return false;
        (self.platform_services orelse return false).startTimer(
            scheduled_task_timer_id,
            delay_ns,
            false,
        ) catch return false;
        return true;
    }

    fn cancelScheduledTaskTimer(context: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        if (self.platform_services) |services|
            services.cancelTimer(scheduled_task_timer_id) catch {};
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

    fn platformBeginWindowDrag(
        context: ?*anyopaque,
        window_id: native_sdk.platform.WindowId,
        clicks: u8,
    ) anyerror!bridge_api.WindowChromeState {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        const state = try window_chrome.beginDrag(
            self.platform_services orelse return error.RuntimeUnavailable,
            window_id,
            clicks,
        );
        return .{ .maximized = state.maximized };
    }

    fn platformWindowControl(
        context: ?*anyopaque,
        window_id: native_sdk.platform.WindowId,
        action: bridge_api.WindowControl,
    ) anyerror!bridge_api.WindowChromeState {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        const state = try window_chrome.control(
            self.platform_services orelse return error.RuntimeUnavailable,
            window_id,
            switch (action) {
                .minimize => .minimize,
                .toggle_maximize => .toggle_maximize,
                .show_system_menu => .show_system_menu,
                .close => .close,
            },
        );
        return .{ .maximized = state.maximized };
    }

    fn platformWindowState(
        context: ?*anyopaque,
        window_id: native_sdk.platform.WindowId,
    ) anyerror!bridge_api.WindowChromeState {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        const state = try window_chrome.state(
            self.platform_services orelse return error.RuntimeUnavailable,
            window_id,
        );
        return .{ .maximized = state.maximized };
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

    fn automationWorkspaceRoot(context: ?*anyopaque) ?[]const u8 {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        return self.automation.workspaceRoot();
    }
};

const CatalogExecutionPreparation = union(enum) {
    ready: account_contract.OwnedExecutionConfig,
    rejected: account_contract.ErrorCode,
};

fn prepareCatalogExecution(
    catalog: *account_api.Catalog.CatalogSession,
    identity: *const account_api.AccountIdentity,
    model_catalog_api_key_id: []const u8,
    model: []const u8,
    execution_generation: u64,
) CatalogExecutionPreparation {
    if (!std.mem.eql(u8, catalog.ownerAccountId(), identity.accountId()) or
        !std.mem.eql(u8, catalog.ownerProfileId(), identity.profileId()))
        return .{ .rejected = .account_mismatch };
    if (!catalog.ownsExecutionSelection(
        identity.accountId(),
        identity.profileId(),
        model_catalog_api_key_id,
        model,
    )) return .{ .rejected = .dependency_contract_invalid };
    return .{ .ready = catalog.prepareExecution(
        model,
        execution_generation,
    ) catch |err| return .{
        .rejected = account_api.Catalog.errorCode(err),
    } };
}

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

fn commitScheduledTaskStore(
    context: ?*anyopaque,
    bytes: []const u8,
) workbench_api.SchedulePersistenceCommit {
    const store: *workbench_api.ScheduledTaskFileStore = @ptrCast(
        @alignCast(context orelse return .failed),
    );
    store.commit(bytes) catch |err| return switch (err) {
        error.PersistenceOutcomeUnknown => .outcome_unknown,
        else => .failed,
    };
    return .committed;
}

fn commitTaskStore(
    context: ?*anyopaque,
    bytes: []const u8,
) workbench_api.TaskPersistenceCommit {
    const store: *workbench_api.TaskFileStore = @ptrCast(
        @alignCast(context orelse return .failed),
    );
    store.commit(bytes) catch |err| return switch (err) {
        error.PersistenceOutcomeUnknown => .outcome_unknown,
        else => .failed,
    };
    return .committed;
}

fn frontendMode(env_map: *std.process.Environ.Map) FrontendMode {
    return if (env_map.get(frontend_url_env) != null) .development else .release;
}

fn resolveFrontendAssetRoot(io: std.Io, allocator: std.mem.Allocator) ![]u8 {
    const executable_dir = try std.process.executableDirPathAlloc(io, allocator);
    defer allocator.free(executable_dir);

    const candidates = [_][]const []const u8{
        &.{ executable_dir, "frontend", "dist" },
        &.{ executable_dir, "..", "resources", "frontend", "dist" },
        &.{ executable_dir, "..", "Resources", "frontend", "dist" },
        &.{ executable_dir, "..", "..", "frontend", "dist" },
    };
    for (candidates) |segments| {
        const candidate = try std.fs.path.resolve(allocator, segments);
        if (frontendEntryExists(io, allocator, candidate)) return candidate;
        allocator.free(candidate);
    }
    return error.FrontendAssetsNotFound;
}

fn frontendEntryExists(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
) bool {
    const entry_path = std.fs.path.join(allocator, &.{ root, frontend_entry }) catch return false;
    defer allocator.free(entry_path);
    var file = std.Io.Dir.cwd().openFile(io, entry_path, .{}) catch return false;
    file.close(io);
    return true;
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

fn resolveCanonicalUserHome(
    io: std.Io,
    allocator: std.mem.Allocator,
    env_map: *std.process.Environ.Map,
) ?[]u8 {
    const configured = switch (builtin.os.tag) {
        .windows => env_map.get("USERPROFILE"),
        else => env_map.get("HOME"),
    } orelse return null;
    return resolveCanonicalDirectory(io, allocator, configured);
}

fn resolveCanonicalDirectory(
    io: std.Io,
    allocator: std.mem.Allocator,
    configured: []const u8,
) ?[]u8 {
    if (configured.len == 0 or !std.fs.path.isAbsolute(configured) or
        !std.unicode.utf8ValidateSlice(configured))
        return null;
    const canonical = std.Io.Dir.realPathFileAbsoluteAlloc(
        io,
        configured,
        allocator,
    ) catch return null;
    const stat = std.Io.Dir.cwd().statFile(io, canonical, .{}) catch {
        allocator.free(canonical);
        return null;
    };
    if (stat.kind != .directory) {
        allocator.free(canonical);
        return null;
    }
    return canonical;
}

pub fn run(init: std.process.Init) !void {
    const frontend_asset_root = if (init.environ_map.get(frontend_url_env) == null)
        try resolveFrontendAssetRoot(init.io, std.heap.c_allocator)
    else
        try std.heap.c_allocator.dupe(u8, frontend_dist);
    defer std.heap.c_allocator.free(frontend_asset_root);

    var app = App{
        .env_map = init.environ_map,
        .io = init.io,
        .frontend_asset_root = frontend_asset_root,
        .main_thread_id = std.Thread.getCurrentId(),
        .automation = automation_api.Runtime.init(init.environ_map),
    };
    defer app.automation.deinit();
    var data_dir_storage: [4096]u8 = undefined;
    const data_dir = try native_sdk.app_dirs.resolveOne(
        .{ .name = platformDataDirectoryName(builtin.os.tag) },
        native_sdk.app_dirs.currentPlatform(),
        native_sdk.debug.envFromMap(init.environ_map),
        .data,
        &data_dir_storage,
    );
    var managed_workspace_dir_storage: [4096]u8 = undefined;
    const managed_workspace_dir = native_sdk.app_dirs.join(
        native_sdk.app_dirs.currentPlatform(),
        &managed_workspace_dir_storage,
        &.{ data_dir, "workspaces" },
    ) catch null;
    var managed_workspace_root: ?workbench_api.ManagedWorkspaceRoot =
        if (managed_workspace_dir) |directory|
            workbench_api.ManagedWorkspaceRoot.open(
                init.io,
                std.heap.c_allocator,
                directory,
            ) catch null
        else
            null;
    defer if (managed_workspace_root) |*root| root.deinit();
    const account_dir = try native_sdk.app_dirs.join(
        native_sdk.app_dirs.currentPlatform(),
        &app.account_dir_storage,
        &.{ data_dir, "account" },
    );
    app.account_dir_len = account_dir.len;
    var scheduled_task_dir_storage: [4096]u8 = undefined;
    const scheduled_task_dir = try native_sdk.app_dirs.join(
        native_sdk.app_dirs.currentPlatform(),
        &scheduled_task_dir_storage,
        &.{ data_dir, "workbench" },
    );
    var skill_staging_dir_storage: [4096]u8 = undefined;
    const skill_staging_dir = try native_sdk.app_dirs.join(
        native_sdk.app_dirs.currentPlatform(),
        &skill_staging_dir_storage,
        &.{ scheduled_task_dir, "skill-staging" },
    );
    var task_file_store: ?workbench_api.TaskFileStore =
        workbench_api.TaskFileStore.init(
            init.io,
            scheduled_task_dir,
        ) catch null;
    defer if (task_file_store) |*store| store.deinit();
    var task_restore_failed = task_file_store == null;
    const task_restored_bytes = if (task_file_store) |*store|
        store.loadAlloc(std.heap.c_allocator) catch restore: {
            task_restore_failed = true;
            break :restore null;
        }
    else
        null;
    defer if (task_restored_bytes) |bytes|
        std.heap.c_allocator.free(bytes);
    var scheduled_task_file_store: ?workbench_api.ScheduledTaskFileStore =
        workbench_api.ScheduledTaskFileStore.init(
            init.io,
            scheduled_task_dir,
        ) catch null;
    defer if (scheduled_task_file_store) |*store| store.deinit();
    var scheduled_task_restore_failed = scheduled_task_file_store == null;
    const scheduled_task_restored_bytes = if (scheduled_task_file_store) |*store|
        store.loadAlloc(std.heap.c_allocator) catch restore: {
            scheduled_task_restore_failed = true;
            break :restore null;
        }
    else
        null;
    defer if (scheduled_task_restored_bytes) |bytes|
        std.heap.c_allocator.free(bytes);
    var skill_management_file_store: ?workbench_api.SkillManagementFileStore =
        workbench_api.SkillManagementFileStore.init(
            init.io,
            scheduled_task_dir,
        ) catch null;
    defer if (skill_management_file_store) |*store| store.deinit();
    var skill_management_restore_failed = skill_management_file_store == null;
    const skill_management_restored_bytes = if (skill_management_file_store) |*store|
        store.loadAlloc(std.heap.c_allocator) catch restore: {
            skill_management_restore_failed = true;
            break :restore null;
        }
    else
        null;
    defer if (skill_management_restored_bytes) |bytes|
        std.heap.c_allocator.free(bytes);
    const canonical_user_home = if (app.automation.canonicalUserHome()) |home|
        resolveCanonicalDirectory(init.io, std.heap.c_allocator, home)
    else
        resolveCanonicalUserHome(
            init.io,
            std.heap.c_allocator,
            init.environ_map,
        );
    defer if (canonical_user_home) |home|
        std.heap.c_allocator.free(home);

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
        .{
            .change_notifier = .{
                .context = &app,
                .wake = App.notifyMainLoop,
            },
            .directories = .{
                .canonical_user_home = canonical_user_home,
                .managed_workspace_root = if (managed_workspace_root) |*root|
                    root
                else
                    null,
            },
            .schedule_timer = .{
                .context = &app,
                .enabled = true,
                .now_unix_seconds = App.scheduledTaskNow,
                .arm = App.armScheduledTaskTimer,
                .cancel = App.cancelScheduledTaskTimer,
            },
            .schedule_persistence = .{
                .context = if (scheduled_task_file_store) |*store|
                    store
                else
                    null,
                .enabled = scheduled_task_file_store != null and
                    !scheduled_task_restore_failed,
                .restored_bytes = scheduled_task_restored_bytes,
                .restore_failed = scheduled_task_restore_failed,
                .commit_fn = commitScheduledTaskStore,
            },
            .task_persistence = .{
                .context = if (task_file_store) |*store| store else null,
                .enabled = task_file_store != null and !task_restore_failed,
                .restored_bytes = task_restored_bytes,
                .restore_failed = task_restore_failed,
                .commit_fn = commitTaskStore,
            },
            .schedule_notifier = .{
                .context = &app,
                .enabled = true,
                .notify_fn = App.notifyScheduledTask,
            },
            .skill_management = .{
                .file_store = if (skill_management_file_store) |*store|
                    store
                else
                    null,
                .staging_root = skill_staging_dir,
                .restored_bytes = skill_management_restored_bytes,
                .restore_failed = skill_management_restore_failed,
            },
        },
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
        &account_effects.public_catalog,
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
        app.dispatcherAutomationAuthority(),
        main_window_id,
    );
    defer dispatcher.deinit();
    app.dispatcher = &dispatcher;
    const mode = frontendMode(init.environ_map);

    try runner.runWithOptions(app.app(), .{
        .app_name = "MetaWork",
        .window_title = "MetaWork",
        .bundle_id = product_identity.bundle_id,
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

test "product identity does not unify macOS and Windows Account storage" {
    try std.testing.expectEqualStrings(
        "com.metask.metawork.dev",
        product_identity.bundle_id,
    );
    try std.testing.expectEqualStrings(
        product_identity.macos_data_directory_name,
        platformDataDirectoryName(.macos),
    );
    try std.testing.expectEqualStrings(
        windows_data_directory_name,
        platformDataDirectoryName(.windows),
    );
}

test "ready catalog synchronization reuses validated committed selections" {
    var catalog = account_api.Catalog.CatalogSession.init(std.testing.allocator);
    defer catalog.deinit();
    try account_api.Catalog.TestSupport.replaceOwnedSelection(
        &catalog,
        "account-1",
        "profile-1",
        .{
            .id = "key-current",
            .name = "Current",
            .suffix = "1234",
            .provider_kind = .anthropic,
        },
        "secret",
        &.{
            .{ .id = "model-current", .display_name = "Current model" },
            .{ .id = "model-other", .display_name = "Other model" },
        },
    );
    try account_api.Catalog.TestSupport.appendOwnedApiKey(
        &catalog,
        .{
            .id = "key-other",
            .name = "Other",
            .suffix = "5678",
            .provider_kind = .openai,
        },
        "other-secret",
    );
    var app: App = undefined;
    app.windows_public_state = null;
    const ready_view: account_contract.AccountView = .{
        .session_state = .authenticated,
        .execution_state = .ready,
        .operation = .loading_keys,
        .readiness = .ready,
        .primary_action = .none,
        .selected_api_key_id = "key-current",
        .selected_model = "model-current",
    };
    try std.testing.expectEqualStrings(
        "key-current",
        app.automaticApiSelection(&catalog, ready_view).?,
    );
    var first_login_view = ready_view;
    first_login_view.execution_state = .none;
    first_login_view.selected_api_key_id = "";
    first_login_view.selected_model = "";
    try std.testing.expect(
        app.automaticApiSelection(&catalog, first_login_view) == null,
    );

    var loading_models_view = ready_view;
    loading_models_view.operation = .loading_models;
    loading_models_view.candidate_api_key_id = "key-current";
    try std.testing.expectEqualStrings(
        "model-current",
        app.automaticModelSelection(&catalog, loading_models_view).?,
    );

    loading_models_view.candidate_model = "model-other";
    try std.testing.expect(
        app.automaticModelSelection(&catalog, loading_models_view) == null,
    );
}

test "Account coordinator commits login and transactional reconfiguration gates" {
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
    var public_catalog: account_api.Catalog.PublicCatalog = .{};
    var coordinator = AccountCoordinator.init(
        &workbench,
        &public_catalog,
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

    coordinator.startCatalogContinuation();
    const catalog_effect = effects.take().?;
    try std.testing.expect(catalog_effect.effect == .load_api_keys);
    var keys_loaded: account_api.WorkerCompletion = .{
        .attempt_id = catalog_effect.attempt_id.?,
        .payload = .api_keys_loaded,
    };
    defer keys_loaded.deinit();
    account_api.Catalog.TestSupport.replacePublic(
        &coordinator.candidate_public_catalog,
        &.{.{ .id = "key-1", .name = "Primary", .suffix = "1234", .provider_kind = .anthropic }},
        &.{},
    );
    try std.testing.expect(coordinator.complete(&keys_loaded));
    var stale_key = accountSelectionCommand("key-1", workbench.accountView());
    stale_key.expected_catalog_generation -= 1;
    const stale_key_result = coordinator.commandSink().submit(.{
        .select_api_key = stale_key,
    });
    try std.testing.expect(!stale_key_result.accepted);
    try std.testing.expectEqual(
        account_contract.ErrorCode.generation_mismatch,
        stale_key_result.error_code,
    );
    var stale_execution = accountSelectionCommand("key-1", workbench.accountView());
    stale_execution.expected_execution_generation += 1;
    const stale_execution_result = coordinator.commandSink().submit(.{
        .select_api_key = stale_execution,
    });
    try std.testing.expect(!stale_execution_result.accepted);
    try std.testing.expectEqual(
        account_contract.ErrorCode.generation_mismatch,
        stale_execution_result.error_code,
    );
    const unknown_key = coordinator.commandSink().submit(.{
        .select_api_key = accountSelectionCommand(
            "unknown-key",
            workbench.accountView(),
        ),
    });
    try std.testing.expect(!unknown_key.accepted);
    try std.testing.expectEqual(
        account_contract.ErrorCode.invalid_command,
        unknown_key.error_code,
    );
    const key = coordinator.commandSink().submit(.{
        .select_api_key = accountSelectionCommand(
            "key-1",
            workbench.accountView(),
        ),
    });
    try std.testing.expect(key.accepted);
    try std.testing.expectEqualStrings(
        "key-1",
        effects.take().?.effect.argument().?,
    );
    var models_loaded: account_api.WorkerCompletion = .{
        .attempt_id = catalog_effect.attempt_id.?,
        .payload = .models_loaded,
    };
    defer models_loaded.deinit();
    account_api.Catalog.TestSupport.replacePublic(
        &coordinator.candidate_public_catalog,
        &.{.{ .id = "key-1", .name = "Primary", .suffix = "1234", .provider_kind = .anthropic }},
        &.{.{ .id = "model-1", .display_name = "Model One" }},
    );
    const hidden_model = coordinator.commandSink().submit(.{
        .select_model = accountSelectionCommand(
            "model-1",
            workbench.accountView(),
        ),
    });
    try std.testing.expect(!hidden_model.accepted);
    try std.testing.expectEqual(
        account_contract.ErrorCode.invalid_command,
        hidden_model.error_code,
    );
    try std.testing.expect(coordinator.complete(&models_loaded));
    const model = coordinator.commandSink().submit(.{
        .select_model = accountSelectionCommand(
            "model-1",
            workbench.accountView(),
        ),
    });
    try std.testing.expect(model.accepted);
    try std.testing.expect(workbench.executionReplacementPending());
    try std.testing.expectEqualStrings(
        "model-1",
        effects.take().?.effect.argument().?,
    );
    try std.testing.expectEqual(
        account_contract.OperationKind.persisting,
        workbench.accountView().operation,
    );
    try std.testing.expect(!workbench.accountView().can_cancel);

    const invalid_while_persisting = coordinator.commandSink().submit(.{
        .select_model = accountSelectionCommand(
            "model-1",
            workbench.accountView(),
        ),
    });
    try std.testing.expect(!invalid_while_persisting.accepted);
    try std.testing.expectEqual(
        account_contract.ErrorCode.invalid_state,
        invalid_while_persisting.error_code,
    );
    try std.testing.expect(workbench.executionReplacementPending());

    // Persistence has committed before execution_ready reaches the main
    // thread. A cancel in that window must not roll memory back behind disk.
    const cancel_after_persistence = coordinator.commandSink().submit(
        .cancel_operation,
    );
    try std.testing.expect(!cancel_after_persistence.accepted);
    try std.testing.expectEqual(
        account_contract.ErrorCode.invalid_state,
        cancel_after_persistence.error_code,
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

    const refresh = coordinator.commandSink().submit(.refresh_catalog);
    try std.testing.expect(refresh.accepted);
    try std.testing.expect(effects.take().?.effect == .load_api_keys);
    account_api.Catalog.TestSupport.replacePublic(
        &coordinator.candidate_public_catalog,
        &.{
            .{ .id = "key-1", .name = "Primary", .suffix = "1234", .provider_kind = .anthropic },
            .{ .id = "key-2", .name = "Secondary", .suffix = "5678", .provider_kind = .openai },
        },
        &.{},
    );
    var refreshed_keys: account_api.WorkerCompletion = .{
        .attempt_id = refresh.attempt_id.?,
        .payload = .api_keys_loaded,
    };
    defer refreshed_keys.deinit();
    try std.testing.expect(coordinator.complete(&refreshed_keys));
    try std.testing.expectEqual(
        account_contract.OperationKind.selecting_key,
        workbench.accountView().operation,
    );
    const keep_key = coordinator.commandSink().submit(.{
        .select_api_key = accountSelectionCommand(
            "key-1",
            workbench.accountView(),
        ),
    });
    try std.testing.expect(keep_key.accepted);
    try std.testing.expectEqualStrings(
        "key-1",
        effects.take().?.effect.argument().?,
    );
    account_api.Catalog.TestSupport.replacePublic(
        &coordinator.candidate_public_catalog,
        &.{
            .{ .id = "key-1", .name = "Primary", .suffix = "1234", .provider_kind = .anthropic },
            .{ .id = "key-2", .name = "Secondary", .suffix = "5678", .provider_kind = .openai },
        },
        &.{
            .{ .id = "model-1", .display_name = "Model One" },
            .{ .id = "model-2", .display_name = "Model Two" },
        },
    );
    var refreshed_models: account_api.WorkerCompletion = .{
        .attempt_id = refresh.attempt_id.?,
        .payload = .models_loaded,
    };
    defer refreshed_models.deinit();
    try std.testing.expect(coordinator.complete(&refreshed_models));
    try std.testing.expectEqual(
        account_contract.OperationKind.selecting_model,
        workbench.accountView().operation,
    );
    const keep_model = coordinator.commandSink().submit(.{
        .select_model = accountSelectionCommand(
            "model-1",
            workbench.accountView(),
        ),
    });
    try std.testing.expect(keep_model.accepted);
    try std.testing.expect(effects.take() == null);
    try std.testing.expect(!workbench.executionReplacementPending());
    try std.testing.expectEqual(
        account_contract.OperationKind.none,
        workbench.accountView().operation,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        workbench.accountView().execution_generation,
    );
    try std.testing.expectEqual(@as(usize, 2), workbench.accountView().api_keys.len);
    try std.testing.expectEqual(@as(usize, 2), workbench.accountView().models.len);

    effects.entry = .{ .attempt_id = 99, .effect = .begin_oauth };
    const exhausted_switch = coordinator.commandSink().submit(.{
        .select_model = accountSelectionCommand(
            "model-2",
            workbench.accountView(),
        ),
    });
    try std.testing.expect(!exhausted_switch.accepted);
    try std.testing.expectEqual(
        account_contract.ErrorCode.local_resource_exhausted,
        exhausted_switch.error_code,
    );
    try std.testing.expect(!workbench.executionReplacementPending());
    try std.testing.expectEqual(
        account_contract.OperationKind.none,
        coordinator.account.view().operation,
    );
    _ = effects.take().?;

    try workbench.beginDefaultExecutionReplacement();
    const blocked_switch = coordinator.commandSink().submit(.{
        .select_model = accountSelectionCommand(
            "model-2",
            workbench.accountView(),
        ),
    });
    try std.testing.expect(!blocked_switch.accepted);
    try std.testing.expectEqual(
        account_contract.ErrorCode.execution_in_use,
        blocked_switch.error_code,
    );
    try std.testing.expectEqual(
        account_contract.OperationKind.none,
        coordinator.account.view().operation,
    );
    workbench.endExecutionReplacementNoFail();

    const failed_switch = coordinator.commandSink().submit(.{
        .select_model = accountSelectionCommand(
            "model-2",
            workbench.accountView(),
        ),
    });
    try std.testing.expect(failed_switch.accepted);
    try std.testing.expect(workbench.executionReplacementPending());
    try std.testing.expect(effects.take().?.effect == .load_api_keys);
    account_api.Catalog.TestSupport.replacePublic(
        &coordinator.candidate_public_catalog,
        &.{.{ .id = "key-1", .name = "Primary", .suffix = "1234", .provider_kind = .anthropic }},
        &.{},
    );
    var failed_keys: account_api.WorkerCompletion = .{
        .attempt_id = failed_switch.attempt_id.?,
        .payload = .api_keys_loaded,
    };
    defer failed_keys.deinit();
    try std.testing.expect(coordinator.complete(&failed_keys));
    const failed_models_effect = effects.take().?;
    try std.testing.expectEqualStrings(
        "key-1",
        failed_models_effect.effect.argument().?,
    );
    account_api.Catalog.TestSupport.replacePublic(
        &coordinator.candidate_public_catalog,
        &.{.{ .id = "key-1", .name = "Primary", .suffix = "1234", .provider_kind = .anthropic }},
        &.{.{ .id = "model-2", .display_name = "Failed model" }},
    );
    var failed_models: account_api.WorkerCompletion = .{
        .attempt_id = failed_switch.attempt_id.?,
        .payload = .models_loaded,
    };
    defer failed_models.deinit();
    try std.testing.expect(coordinator.complete(&failed_models));
    try std.testing.expectEqualStrings(
        "model-2",
        effects.take().?.effect.argument().?,
    );
    var persistence_failed: account_api.WorkerCompletion = .{
        .attempt_id = failed_switch.attempt_id.?,
        .payload = .{ .failed = .fromCode(
            .credential_store_write_failed,
        ) },
    };
    defer persistence_failed.deinit();
    try std.testing.expect(coordinator.complete(&persistence_failed));
    try std.testing.expect(!workbench.executionReplacementPending());
    try std.testing.expectEqualStrings(
        "model-1",
        workbench.accountView().selected_model,
    );
    try std.testing.expectEqualStrings(
        "model-1",
        workbench.accountView().models[0].id,
    );

    const cancelled_api = coordinator.commandSink().submit(.{
        .select_api_key = accountSelectionCommand(
            "key-2",
            workbench.accountView(),
        ),
    });
    try std.testing.expect(cancelled_api.accepted);
    try std.testing.expect(effects.take().?.effect == .load_api_keys);
    account_api.Catalog.TestSupport.replacePublic(
        &coordinator.candidate_public_catalog,
        &.{.{ .id = "key-2", .name = "Cancelled", .suffix = "9999", .provider_kind = .anthropic }},
        &.{},
    );
    var cancelled_keys: account_api.WorkerCompletion = .{
        .attempt_id = cancelled_api.attempt_id.?,
        .payload = .api_keys_loaded,
    };
    defer cancelled_keys.deinit();
    try std.testing.expect(coordinator.complete(&cancelled_keys));
    _ = effects.take().?;
    account_api.Catalog.TestSupport.replacePublic(
        &coordinator.candidate_public_catalog,
        &.{.{ .id = "key-2", .name = "Cancelled", .suffix = "9999", .provider_kind = .anthropic }},
        &.{.{ .id = "model-1", .display_name = "Same model id" }},
    );
    var cancelled_models: account_api.WorkerCompletion = .{
        .attempt_id = cancelled_api.attempt_id.?,
        .payload = .models_loaded,
    };
    defer cancelled_models.deinit();
    try std.testing.expect(coordinator.complete(&cancelled_models));
    const cancelled = coordinator.commandSink().submit(.cancel_operation);
    try std.testing.expect(cancelled.accepted);
    const cancel_effect = effects.take().?.effect;
    try std.testing.expectEqual(
        cancelled_api.attempt_id.?,
        cancel_effect.cancel_attempt,
    );
    try std.testing.expectEqualStrings(
        "key-1",
        workbench.accountView().selected_api_key_id,
    );
    try std.testing.expectEqualStrings(
        "model-1",
        workbench.accountView().models[0].id,
    );

    const api_switch = coordinator.commandSink().submit(.{
        .select_api_key = accountSelectionCommand(
            "key-2",
            workbench.accountView(),
        ),
    });
    try std.testing.expect(api_switch.accepted);
    try std.testing.expect(effects.take().?.effect == .load_api_keys);
    account_api.Catalog.TestSupport.replacePublic(
        &coordinator.candidate_public_catalog,
        &.{.{ .id = "key-2", .name = "Secondary", .suffix = "5678", .provider_kind = .anthropic }},
        &.{},
    );
    var switched_keys: account_api.WorkerCompletion = .{
        .attempt_id = api_switch.attempt_id.?,
        .payload = .api_keys_loaded,
    };
    defer switched_keys.deinit();
    try std.testing.expect(coordinator.complete(&switched_keys));
    try std.testing.expectEqualStrings(
        "key-2",
        effects.take().?.effect.argument().?,
    );
    account_api.Catalog.TestSupport.replacePublic(
        &coordinator.candidate_public_catalog,
        &.{.{ .id = "key-2", .name = "Secondary", .suffix = "5678", .provider_kind = .anthropic }},
        &.{.{ .id = "model-1", .display_name = "Model One" }},
    );
    var switched_models: account_api.WorkerCompletion = .{
        .attempt_id = api_switch.attempt_id.?,
        .payload = .models_loaded,
    };
    defer switched_models.deinit();
    try std.testing.expect(coordinator.complete(&switched_models));
    const switched_model = coordinator.commandSink().submit(.{
        .select_model = accountSelectionCommand(
            "model-1",
            workbench.accountView(),
        ),
    });
    try std.testing.expect(switched_model.accepted);
    try std.testing.expectEqualStrings(
        "model-1",
        effects.take().?.effect.argument().?,
    );
    var replacement = try account_contract.OwnedExecutionConfig.initOwned(
        std.testing.allocator,
        .anthropic,
        try std.testing.allocator.dupe(u8, "model-1"),
        try std.testing.allocator.dupe(
            u8,
            account_contract.metask_anthropic_messages_url,
        ),
        2,
        try std.testing.allocator.dupe(u8, "secret-key-2"),
    );
    var replacement_ready: account_api.WorkerCompletion = .{
        .attempt_id = switched_model.attempt_id.?,
        .payload = .{ .execution_ready = replacement.take() },
    };
    defer replacement_ready.deinit();
    replacement.deinit();
    try std.testing.expect(coordinator.complete(&replacement_ready));
    try std.testing.expectEqualStrings(
        "key-2",
        workbench.accountView().selected_api_key_id,
    );
    try std.testing.expectEqualStrings(
        "key-2",
        workbench.accountView().model_catalog_api_key_id,
    );

    try std.testing.expect(coordinator.refreshToken());
    try std.testing.expect(effects.take().?.effect == .refresh_token);
    var refresh_failed: account_api.WorkerCompletion = .{
        .attempt_id = coordinator.account.activeAttempt().?,
        .payload = .{ .failed = .fromCode(.token_refresh_failed) },
    };
    defer refresh_failed.deinit();
    try std.testing.expect(coordinator.complete(&refresh_failed));
    try std.testing.expectEqual(
        account_contract.AccountSessionState.reauth_required,
        workbench.accountView().session_state,
    );
    const reauthenticate = coordinator.commandSink().submit(.reauthenticate);
    try std.testing.expect(reauthenticate.accepted);
    try std.testing.expect(workbench.executionReplacementPending());
    try std.testing.expect(effects.take().?.effect == .begin_oauth);
    var reauthenticated: account_api.WorkerCompletion = .{
        .attempt_id = reauthenticate.attempt_id.?,
        .payload = .{ .authenticated = try .init(
            "account-2",
            "profile-2",
            "Other User",
        ) },
    };
    defer reauthenticated.deinit();
    try std.testing.expect(coordinator.complete(&reauthenticated));
    try std.testing.expect(!workbench.executionReplacementPending());
    try std.testing.expectEqual(
        account_contract.AccountSessionState.authenticated,
        workbench.accountView().session_state,
    );
    try std.testing.expectEqual(
        account_contract.ExecutionState.none,
        workbench.accountView().execution_state,
    );
    try std.testing.expectEqualStrings(
        "account-2",
        workbench.accountView().account_id,
    );
    try std.testing.expectEqualStrings(
        "profile-2",
        workbench.accountView().profile_id,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        workbench.accountView().api_keys.len,
    );

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
    var public_catalog: account_api.Catalog.PublicCatalog = .{};
    var coordinator = AccountCoordinator.init(
        &workbench,
        &public_catalog,
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
    var public_catalog: account_api.Catalog.PublicCatalog = .{};
    var coordinator = AccountCoordinator.init(
        &workbench,
        &public_catalog,
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

test "Account mailbox transfers ownership, wakes, and reports collision" {
    const Wake = struct {
        count: usize = 0,

        fn notify(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.count += 1;
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

    effects.publishCompletion(.{
        .attempt_id = 8,
        .payload = .{ .failed = .fromCode(.token_refresh_failed) },
    });
    try std.testing.expectEqual(@as(usize, 2), wake.count);
    effects.publishCompletion(.{
        .attempt_id = 8,
        .payload = .{ .failed = .fromCode(.metask_service_unavailable) },
    });
    try std.testing.expect(effects.takeCollision());
    var queued = effects.takeMailbox() orelse
        return error.TestUnexpectedResult;
    defer queued.deinit();
    try std.testing.expectEqual(
        account_contract.ErrorCode.token_refresh_failed,
        queued.completion.payload.failed.error_code,
    );
}

test "cross-API same-model selection is rejected before persistence" {
    var candidate = account_api.Catalog.CatalogSession.init(
        std.testing.allocator,
    );
    defer candidate.deinit();
    try account_api.Catalog.TestSupport.replaceOwnedSelection(
        &candidate,
        "account-1",
        "profile-1",
        .{
            .id = "key-b",
            .name = "Secondary",
            .suffix = "5678",
            .provider_kind = .anthropic,
        },
        "secret-key-b",
        &.{.{
            .id = "same-model",
            .display_name = "Same model id",
        }},
    );
    const identity = try account_api.AccountIdentity.init(
        "account-1",
        "profile-1",
        "Metask User",
    );

    switch (prepareCatalogExecution(
        &candidate,
        &identity,
        "key-a",
        "same-model",
        2,
    )) {
        .rejected => |error_code| try std.testing.expectEqual(
            account_contract.ErrorCode.dependency_contract_invalid,
            error_code,
        ),
        .ready => |unexpected_value| {
            var unexpected = unexpected_value;
            unexpected.deinit();
            return error.TestUnexpectedResult;
        },
    }

    // Rejection must leave the private candidate intact. A matching Host
    // owner can still consume the same selection afterwards.
    try std.testing.expect(candidate.ownsExecutionSelection(
        "account-1",
        "profile-1",
        "key-b",
        "same-model",
    ));
    var execution = switch (prepareCatalogExecution(
        &candidate,
        &identity,
        "key-b",
        "same-model",
        2,
    )) {
        .ready => |owned| owned,
        .rejected => return error.TestUnexpectedResult,
    };
    defer execution.deinit();
    try std.testing.expectEqualStrings(
        "secret-key-b",
        execution.input().api_key,
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
    var public_catalog: account_api.Catalog.PublicCatalog = .{};
    var coordinator = AccountCoordinator.init(
        &workbench,
        &public_catalog,
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

test "Account coordinator shutdown publishes a valid terminal view from ready" {
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
    var public_catalog: account_api.Catalog.PublicCatalog = .{};
    var coordinator = AccountCoordinator.init(
        &workbench,
        &public_catalog,
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
    try std.testing.expect(workbench.accountView().can_create_task);

    coordinator.shutdown();

    const shutdown_effect = queue.take().?;
    try std.testing.expect(shutdown_effect.effect == .shutdown);
    const view = workbench.accountView();
    try std.testing.expectEqual(
        account_contract.AccountSessionState.shutting_down,
        view.session_state,
    );
    try std.testing.expectEqual(
        account_contract.ExecutionState.none,
        view.execution_state,
    );
    try std.testing.expectEqual(@as(usize, 0), view.api_keys.len);
    try std.testing.expectEqual(@as(usize, 0), view.models.len);
    try std.testing.expect(!view.can_create_task);
}
