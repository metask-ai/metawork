const std = @import("std");
const builtin = @import("builtin");
const contract = @import("metawork_account_contract");
const state_impl = @import("account_state");
const metask_client = @import("metask_client");
const credential_store = @import("account_credential_store");
const windows_store = @import("account_windows_store");
const platform_impl = @import("account_platform");
const login_attempt = @import("account_login_attempt");
const catalog_impl = @import("account_catalog");
const credentials_impl = @import("account_credentials_runtime");
const network_attempt = @import("account_network_attempt");

const refresh_timer_id: u64 = 0x4d57_4143_4354_5246;
const refresh_skew_seconds: i64 = 60;
const refresh_retry_ns: u64 = 30 * std.time.ns_per_s;
const account_path_capacity = 4096;

pub const WakeSink = struct {
    context: *anyopaque,
    notify_fn: *const fn (context: *anyopaque) void,

    fn notify(self: WakeSink) void {
        self.notify_fn(self.context);
    }
};

const EffectQueue = struct {
    entry: ?Entry = null,

    const Entry = struct {
        attempt_id: ?u64,
        effect: state_impl.Effect,
    };

    fn sink(self: *EffectQueue) state_impl.EffectSink {
        return .{ .context = self, .submit_fn = submit };
    }

    fn submit(
        context: *anyopaque,
        attempt_id: ?u64,
        effect: state_impl.Effect,
    ) bool {
        const self: *EffectQueue = @ptrCast(@alignCast(context));
        if (self.entry != null) return false;
        self.entry = .{ .attempt_id = attempt_id, .effect = effect };
        return true;
    }

    fn take(self: *EffectQueue) ?Entry {
        const entry = self.entry;
        self.entry = null;
        return entry;
    }
};

const Effects = struct {
    const MailboxResult = union(enum) {
        login: struct {
            attempt_id: u64,
            result: login_attempt.WorkerResult,
        },
        refresh: struct {
            attempt_id: u64,
            rotation: credentials_impl.CredentialRotation,
        },
        completion: state_impl.WorkerCompletion,
        logout_persistence_unknown: u64,
        execution_persistence_unknown: u64,

        fn deinit(self: *MailboxResult) void {
            switch (self.*) {
                .login => |*entry| entry.result.deinit(),
                .refresh => |*entry| entry.rotation.deinit(),
                .completion => |*completion| completion.deinit(),
                .logout_persistence_unknown,
                .execution_persistence_unknown,
                => {},
            }
        }

        fn attemptId(self: *const MailboxResult) u64 {
            return switch (self.*) {
                .login => |entry| entry.attempt_id,
                .refresh => |entry| entry.attempt_id,
                .completion => |completion| completion.attempt_id,
                .logout_persistence_unknown,
                .execution_persistence_unknown,
                => |attempt_id| attempt_id,
            };
        }
    };

    allocator: std.mem.Allocator,
    io: std.Io,
    wake: WakeSink,
    transport: metask_client.StdHttpTransport,
    queue: EffectQueue = .{},
    catalog: catalog_impl.CatalogSession,
    public_catalog: catalog_impl.PublicCatalog = .{},
    mailbox_mutex: std.Io.Mutex = .init,
    mailbox: ?MailboxResult = null,
    login_attempt: login_attempt.LoginAttempt = .{},
    login_active: bool = false,
    network_attempt: network_attempt.NetworkAttempt = .{},
    mailbox_collision: bool = false,

    fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        wake: WakeSink,
    ) Effects {
        return .{
            .allocator = allocator,
            .io = io,
            .wake = wake,
            .transport = .{ .allocator = allocator, .io = io },
            .catalog = .init(allocator),
        };
    }

    fn clientTransport(self: *Effects) metask_client.Transport {
        return self.transport.transport();
    }

    fn loginSink(self: *Effects) login_attempt.ResultSink {
        return .{ .context = self, .publish_fn = publishLoginResult };
    }

    fn publishLoginResult(
        context: *anyopaque,
        attempt_id: u64,
        result: *login_attempt.WorkerResult,
    ) bool {
        const self: *Effects = @ptrCast(@alignCast(context));
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
        self: *Effects,
        completion_value: state_impl.WorkerCompletion,
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

    fn publishPersistenceUnknown(
        self: *Effects,
        attempt_id: u64,
        kind: enum { logout, execution },
    ) void {
        self.lockMailbox();
        if (self.mailbox != null) {
            self.mailbox_collision = true;
            self.unlockMailbox();
            return;
        }
        self.mailbox = switch (kind) {
            .logout => .{ .logout_persistence_unknown = attempt_id },
            .execution => .{ .execution_persistence_unknown = attempt_id },
        };
        self.unlockMailbox();
        self.notify();
    }

    fn networkSink(self: *Effects) network_attempt.ResultSink {
        return .{ .context = self, .publish_fn = publishNetworkResult };
    }

    fn publishNetworkResult(
        context: *anyopaque,
        attempt_id: u64,
        result: *network_attempt.Result,
    ) bool {
        const self: *Effects = @ptrCast(@alignCast(context));
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
        self: *Effects,
        attempt_id: u64,
        error_code: contract.ErrorCode,
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

    fn takeMailbox(self: *Effects) ?MailboxResult {
        self.lockMailbox();
        defer self.unlockMailbox();
        const result = self.mailbox;
        self.mailbox = null;
        return result;
    }

    fn startLogin(
        self: *Effects,
        attempt_id: u64,
        platform: *platform_impl.NativeBackend,
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
                .payload = .{ .failed = .fromCode(loginStartError(err)) },
            });
            return;
        };
        self.login_active = true;
        platform.openAuthorizationUrl(
            self.login_attempt.authorizationUrl(),
        ) catch self.failLoginAttempt(
            attempt_id,
            .oauth_browser_open_failed,
        );
    }

    fn failLoginAttempt(
        self: *Effects,
        attempt_id: u64,
        error_code: contract.ErrorCode,
    ) void {
        if (self.login_active) {
            self.login_attempt.cancel();
            self.joinLogin();
        }
        self.replaceWithFailure(attempt_id, error_code);
    }

    fn reopenLogin(
        self: *Effects,
        attempt_id: u64,
        platform: *platform_impl.NativeBackend,
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
        ) catch self.failLoginAttempt(
            attempt_id,
            .oauth_browser_open_failed,
        );
    }

    fn startRefresh(
        self: *Effects,
        attempt_id: u64,
        credentials: *const credentials_impl.CredentialOwner,
        now_unix_seconds: i64,
        expected_identity: ?state_impl.AccountIdentity,
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
        ) catch self.publishCompletion(.{
            .attempt_id = attempt_id,
            .payload = .{ .failed = .fromCode(.local_resource_exhausted) },
        });
    }

    fn startLoadApiKeys(
        self: *Effects,
        attempt_id: u64,
        credentials: *const credentials_impl.CredentialOwner,
        identity: state_impl.AccountIdentity,
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
        ) catch self.publishCompletion(.{
            .attempt_id = attempt_id,
            .payload = .{ .failed = .fromCode(.local_resource_exhausted) },
        });
    }

    fn startLoadModels(
        self: *Effects,
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
        ) catch self.publishCompletion(.{
            .attempt_id = attempt_id,
            .payload = .{ .failed = .fromCode(.local_resource_exhausted) },
        });
    }

    fn cancelAttemptAndDiscard(self: *Effects, attempt_id: u64) void {
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
            var discarded = value;
            if (discarded.attemptId() != attempt_id)
                @panic("Account cancel discarded another attempt");
            discarded.deinit();
        }
        _ = self.takeCollision();
        self.catalog.reset();
    }

    fn joinLogin(self: *Effects) void {
        if (!self.login_active) return;
        self.login_attempt.join();
        self.login_attempt.deinit();
        self.login_active = false;
    }

    fn joinNetwork(self: *Effects, attempt_id: u64) void {
        if (!self.network_attempt.matches(attempt_id)) return;
        self.network_attempt.join();
        self.network_attempt.deinit();
    }

    fn cancelJoinAndDiscard(self: *Effects) void {
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

    fn deinit(self: *Effects) void {
        self.cancelJoinAndDiscard();
        std.debug.assert(self.queue.entry == null);
        self.catalog.deinit();
        self.* = undefined;
    }

    fn clearCatalog(self: *Effects) void {
        self.catalog.reset();
        self.public_catalog.clear();
    }

    fn notify(self: *Effects) void {
        self.wake.notify();
    }

    fn takeCollision(self: *Effects) bool {
        self.lockMailbox();
        defer self.unlockMailbox();
        const collision = self.mailbox_collision;
        self.mailbox_collision = false;
        return collision;
    }

    fn lockMailbox(self: *Effects) void {
        self.mailbox_mutex.lockUncancelable(self.io);
    }

    fn unlockMailbox(self: *Effects) void {
        self.mailbox_mutex.unlock(self.io);
    }
};

const AutomaticSelection = union(enum) {
    none,
    api_key: []const u8,
    model: []const u8,
};

pub const Prepared = struct {
    transition: state_impl.PreparedTransition,
    follow_up: ?contract.AccountCommand = null,
    automatic_selection: AutomaticSelection = .none,
    refresh_after_commit: bool = false,
    cleanup_after_commit: bool = false,
    schedule_refresh_after_commit: bool = false,

    pub fn fact(self: *const Prepared) contract.AccountFact {
        return self.transition.fact();
    }

    pub fn takeExecution(
        self: *Prepared,
    ) ?contract.OwnedExecutionConfig {
        return self.transition.takeExecution();
    }

    pub fn attemptId(self: *const Prepared) ?u64 {
        return self.transition.attempt_id;
    }

    pub fn deinit(self: *Prepared) void {
        self.transition.deinit();
        self.follow_up = null;
        self.automatic_selection = .none;
        self.refresh_after_commit = false;
        self.cleanup_after_commit = false;
        self.schedule_refresh_after_commit = false;
    }
};

pub const PrepareResult = union(enum) {
    prepared: Prepared,
    rejected: contract.ErrorCode,
    ignored_stale,
};

pub const InitError = error{
    AccountDirectoryUnavailable,
};

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    main_thread_id: std.Thread.Id,
    account_path_storage: [account_path_capacity]u8 = undefined,
    account_path_len: usize,
    account: state_impl.Account = .initRestoring(),
    effects: Effects,
    candidate_public_catalog: catalog_impl.PublicCatalog = .{},
    platform: ?platform_impl.NativeBackend = null,
    credentials: credentials_impl.CredentialOwner = .{},
    windows_public_state: ?windows_store.PublicState = null,
    catalog_after_refresh: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        main_thread_id: std.Thread.Id,
        account_path: []const u8,
        wake: WakeSink,
    ) InitError!Runtime {
        if (!std.fs.path.isAbsolute(account_path) or
            account_path.len == 0 or
            account_path.len > account_path_capacity)
            return error.AccountDirectoryUnavailable;
        var runtime: Runtime = .{
            .allocator = allocator,
            .io = io,
            .main_thread_id = main_thread_id,
            .account_path_len = account_path.len,
            .effects = .init(allocator, io, wake),
        };
        @memcpy(runtime.account_path_storage[0..account_path.len], account_path);
        return runtime;
    }

    pub fn deinit(self: *Runtime) void {
        self.assertMainThread();
        std.debug.assert(self.platform == null);
        self.effects.deinit();
        self.credentials.deinit();
        self.windows_public_state = null;
        self.catalog_after_refresh = false;
        self.candidate_public_catalog.clear();
        self.* = undefined;
    }

    pub fn prepareStart(
        self: *Runtime,
        services: platform_impl.Services,
    ) Prepared {
        self.assertMainThread();
        std.debug.assert(self.platform == null);
        self.platform = platform_impl.NativeBackend.init(
            services,
            self.io,
            self.main_thread_id,
            self.account_path_storage[0..self.account_path_len],
        ) catch |err| return self.preparedRestoreFailure(
            accountRestoreError(err),
        );
        return if (builtin.os.tag == .windows)
            self.prepareWindowsRestore()
        else
            self.prepareMacosRestore();
    }

    pub fn prepareAutomationStart(self: *Runtime) Prepared {
        self.assertMainThread();
        var restored: state_impl.RestoreResult = .{
            .signed_out = .{},
        };
        return preparedFromState(self.account.prepareRestore(&restored));
    }

    pub fn prepareStartUnavailable(self: *Runtime) Prepared {
        self.assertMainThread();
        return self.preparedRestoreFailure(
            .credential_store_read_failed,
        );
    }

    pub fn prepareCommand(
        self: *Runtime,
        command: contract.AccountCommand,
    ) PrepareResult {
        self.assertMainThread();
        const account_view = self.view();
        switch (command) {
            .select_api_key => |selection| {
                if (selection.expected_catalog_generation !=
                    account_view.catalog_generation or
                    selection.expected_execution_generation !=
                        account_view.execution_generation)
                    return .{ .rejected = .generation_mismatch };
                const member = for (account_view.api_keys) |candidate| {
                    if (std.mem.eql(
                        u8,
                        candidate.id,
                        selection.selection_id,
                    )) break true;
                } else false;
                if (!member) return .{ .rejected = .invalid_command };
            },
            .select_model => |selection| {
                if (selection.expected_catalog_generation !=
                    account_view.catalog_generation or
                    selection.expected_execution_generation !=
                        account_view.execution_generation)
                    return .{ .rejected = .generation_mismatch };
                const member = for (account_view.models) |candidate| {
                    if (std.mem.eql(
                        u8,
                        candidate.id,
                        selection.selection_id,
                    )) break true;
                } else false;
                if (!member) return .{ .rejected = .invalid_command };
            },
            else => {},
        }
        return wrapPrepareResult(self.account.prepareCommand(command));
    }

    pub fn prepareTokenRefresh(self: *Runtime) PrepareResult {
        self.assertMainThread();
        return wrapPrepareResult(self.account.prepareTokenRefresh());
    }

    pub fn prepareTimer(
        self: *Runtime,
        timer_id: u64,
    ) ?PrepareResult {
        self.assertMainThread();
        if (timer_id != refresh_timer_id) return null;
        const result = wrapPrepareResult(self.account.prepareTokenRefresh());
        switch (result) {
            .prepared => {},
            .rejected, .ignored_stale => if (self.credentials.available()) {
                const platform = if (self.platform) |*value| value else return result;
                platform_impl.startTimer(
                    platform,
                    refresh_timer_id,
                    refresh_retry_ns,
                    false,
                ) catch {};
            },
        }
        return result;
    }

    pub fn prepareRestoredRefresh(self: *Runtime) Prepared {
        self.assertMainThread();
        return switch (self.account.prepareTokenRefresh()) {
            .transition => |transition| .{ .transition = transition },
            .rejected => |error_code| preparedFromState(
                self.account.prepareRestoredRefreshAdmissionFailure(
                    error_code,
                ),
            ),
            .ignored_stale => unreachable,
        };
    }

    pub fn prepareContinuationFailure(
        self: *Runtime,
        error_code: contract.ErrorCode,
    ) Prepared {
        self.assertMainThread();
        return preparedFromState(self.account.prepareIdleFailure(error_code));
    }

    pub fn prepareShutdown(self: *Runtime) Prepared {
        self.assertMainThread();
        return .{ .transition = self.account.prepareShutdown() };
    }

    pub fn prepareNextCompletion(self: *Runtime) ?PrepareResult {
        self.assertMainThread();
        const mailbox_value = self.effects.takeMailbox() orelse return null;
        var mailbox = mailbox_value;
        defer mailbox.deinit();
        const collision = self.effects.takeCollision();
        return switch (mailbox) {
            .login => |*entry| result: {
                self.effects.joinLogin();
                if (self.account.activeAttempt() != entry.attempt_id)
                    break :result .ignored_stale;
                if (collision)
                    break :result self.prepareFailure(
                        entry.attempt_id,
                        .dependency_contract_invalid,
                    );
                break :result switch (entry.result) {
                    .authenticated => |*login| self.prepareAuthenticatedLogin(
                        entry.attempt_id,
                        login,
                    ),
                    .failed => |failure| self.prepareFailureValue(
                        entry.attempt_id,
                        failure,
                    ),
                    .consumed => @panic(
                        "Account login mailbox contains consumed result",
                    ),
                };
            },
            .refresh => |*entry| result: {
                self.effects.joinNetwork(entry.attempt_id);
                if (self.account.activeAttempt() != entry.attempt_id)
                    break :result .ignored_stale;
                if (collision)
                    break :result self.prepareFailure(
                        entry.attempt_id,
                        .dependency_contract_invalid,
                    );
                break :result self.prepareRefreshedTokens(
                    entry.attempt_id,
                    &entry.rotation,
                );
            },
            .completion => |*completion| self.prepareWorkerCompletion(
                completion,
                collision,
            ),
            .logout_persistence_unknown => wrapPrepareResult(
                self.account.prepareLogoutPersistenceUnknown(),
            ),
            .execution_persistence_unknown => wrapPrepareResult(
                self.account.prepareExecutionPersistenceUnknown(),
            ),
        };
    }

    pub fn view(self: *Runtime) contract.AccountView {
        self.assertMainThread();
        var result = self.account.view();
        self.decorateView(&result);
        return result;
    }

    pub fn preparedFact(
        self: *Runtime,
        prepared: *const Prepared,
    ) contract.AccountFact {
        self.assertMainThread();
        var fact = prepared.fact();
        if (fact.view.session_state == .signed_out or
            fact.view.session_state == .shutting_down or
            (fact.view.operation == .none and
                fact.view.execution_state == .none))
            return fact;
        const catalog = if (completesCatalogTransaction(fact))
            &self.candidate_public_catalog
        else
            self.catalogForOperation(fact.view.operation);
        catalog.decorate(&fact.view);
        return fact;
    }

    pub fn admitEffect(
        self: *Runtime,
        prepared: *Prepared,
    ) bool {
        self.assertMainThread();
        if (prepared.transition.takeEffect()) |effect|
            return self.effects.queue.sink().submit(
                prepared.transition.attempt_id,
                effect,
            );
        return true;
    }

    pub fn commit(self: *Runtime, prepared: *Prepared) void {
        self.assertMainThread();
        const fact = prepared.transition.fact();
        if (completesCatalogTransaction(fact)) {
            self.effects.public_catalog.replaceFromPublic(
                &self.candidate_public_catalog,
            );
            self.candidate_public_catalog.clear();
        }
        if (fact.view.session_state == .signed_out or
            fact.view.session_state == .shutting_down or
            (fact.view.operation == .none and
                fact.view.execution_state == .none))
        {
            self.effects.public_catalog.clear();
            self.candidate_public_catalog.clear();
        }
        prepared.transition.commit(&self.account);
        if (fact.kind == .operation_failed)
            self.candidate_public_catalog.clear();
    }

    pub fn takeFollowUpCommand(
        self: *Runtime,
        prepared: *Prepared,
    ) ?contract.AccountCommand {
        self.assertMainThread();
        if (prepared.follow_up) |command| {
            prepared.follow_up = null;
            return command;
        }
        const selection = prepared.automatic_selection;
        prepared.automatic_selection = .none;
        const account_view = self.view();
        return switch (selection) {
            .none => null,
            .api_key => |id| .{ .select_api_key = accountSelectionCommand(
                id,
                account_view,
            ) },
            .model => |id| .{ .select_model = accountSelectionCommand(
                id,
                account_view,
            ) },
        };
    }

    pub fn takeRefreshAfterCommit(
        self: *Runtime,
        prepared: *Prepared,
    ) bool {
        self.assertMainThread();
        const result = prepared.refresh_after_commit;
        prepared.refresh_after_commit = false;
        return result;
    }

    pub fn dispatchCommitted(self: *Runtime, prepared: *Prepared) void {
        self.assertMainThread();
        if (prepared.cleanup_after_commit) self.retryCleanup();
        if (prepared.schedule_refresh_after_commit)
            self.scheduleRefresh();
        const entry = self.effects.queue.take() orelse return;
        self.dispatchEffect(entry);
    }

    pub fn cancelRefreshTimer(self: *Runtime) void {
        self.assertMainThread();
        const platform = if (self.platform) |*value| value else return;
        platform_impl.cancelTimer(platform, refresh_timer_id) catch {};
    }

    fn prepareWorkerCompletion(
        self: *Runtime,
        completion: *state_impl.WorkerCompletion,
        collision: bool,
    ) PrepareResult {
        const operation = self.account.view().operation;
        if (self.catalog_after_refresh and
            operation == .token_exchange and
            completion.payload == .failed)
            self.catalog_after_refresh = false;
        const catalog_attempt = operation == .loading_keys or
            operation == .loading_models;
        self.effects.joinNetwork(completion.attempt_id);
        if (collision and
            self.account.activeAttempt() == completion.attempt_id)
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
            self.effects.catalog.reset();

        const current_view = self.account.view();
        const automatic_selection: AutomaticSelection = switch (completion.payload) {
            .api_keys_loaded => if (self.automaticApiSelection(
                &self.effects.catalog,
                current_view,
            )) |id| .{ .api_key = id } else .none,
            .models_loaded => if (self.automaticModelSelection(
                &self.effects.catalog,
                current_view,
            )) |id| .{ .model = id } else .none,
            else => .none,
        };
        if (self.account.activeAttempt() == completion.attempt_id) {
            switch (completion.payload) {
                .api_keys_loaded, .models_loaded => self.candidate_public_catalog.replaceFromSession(
                    &self.effects.catalog,
                ),
                else => {},
            }
        }
        return switch (self.account.prepareCompletion(completion)) {
            .transition => |transition| .{ .prepared = .{
                .transition = transition,
                .automatic_selection = automatic_selection,
            } },
            .rejected => |error_code| .{ .rejected = error_code },
            .ignored_stale => .ignored_stale,
        };
    }

    fn prepareAuthenticatedLogin(
        self: *Runtime,
        attempt_id: u64,
        login: *metask_client.LoginResult,
    ) PrepareResult {
        const platform = if (self.platform) |*value| value else return self.prepareFailure(
            attempt_id,
            .credential_store_write_failed,
        );
        const identity = login.identity;
        var cleanup_pending = false;
        if (builtin.os.tag == .windows) {
            self.windows_public_state = windows_store.commitAuthenticated(
                platform.backend(),
                &login.tokens.refresh_token,
                identity,
            ) catch |err| return self.prepareFailure(
                attempt_id,
                accountStoreError(err),
            );
        } else {
            var generation: credential_store.Generation = undefined;
            std.Io.randomSecure(self.io, &generation) catch
                return self.prepareFailure(
                    attempt_id,
                    .local_resource_exhausted,
                );
            const committed = credential_store.commitAccountOnly(
                platform.backend(),
                generation,
                &login.tokens,
                &identity,
                self.account.executionHighWatermark(),
            ) catch |err| return self.prepareFailure(
                attempt_id,
                accountStoreError(err),
            );
            cleanup_pending = committed.retired_cleanup_pending;
        }
        self.credentials.replace(&login.tokens);
        self.credentials.setCleanupPending(cleanup_pending);
        var completion: state_impl.WorkerCompletion = .{
            .attempt_id = attempt_id,
            .payload = .{ .authenticated = identity },
        };
        defer completion.deinit();
        return switch (self.account.prepareCompletion(&completion)) {
            .transition => |transition| .{ .prepared = .{
                .transition = transition,
                .follow_up = .refresh_catalog,
                .cleanup_after_commit = builtin.os.tag != .windows,
                .schedule_refresh_after_commit = true,
            } },
            .rejected => |error_code| .{ .rejected = error_code },
            .ignored_stale => .ignored_stale,
        };
    }

    fn prepareRefreshedTokens(
        self: *Runtime,
        attempt_id: u64,
        rotation: *credentials_impl.CredentialRotation,
    ) PrepareResult {
        const continue_catalog = self.catalog_after_refresh;
        self.catalog_after_refresh = false;
        const identity = self.account.currentIdentity() orelse
            return self.prepareFailure(
                attempt_id,
                .dependency_contract_invalid,
            );
        var refreshed_identity: ?state_impl.AccountIdentity = null;
        if (continue_catalog) {
            const discovered_identity = rotation.refreshedIdentity() orelse
                return self.prepareFailure(
                    attempt_id,
                    .dependency_contract_invalid,
                );
            if (!std.mem.eql(
                u8,
                discovered_identity.accountId(),
                identity.accountId(),
            )) return self.prepareFailure(
                attempt_id,
                .account_mismatch,
            );
            refreshed_identity = discovered_identity;
        }
        if (!std.mem.eql(
            u8,
            rotation.accountId(),
            identity.accountId(),
        )) return self.prepareFailure(
            attempt_id,
            .account_mismatch,
        );
        const platform = if (self.platform) |*value| value else return self.prepareFailure(
            attempt_id,
            .credential_store_write_failed,
        );
        var cleanup_pending = false;
        if (builtin.os.tag == .windows) {
            if (refreshed_identity) |refreshed| {
                const previous_public = self.windows_public_state orelse
                    return self.prepareFailure(
                        attempt_id,
                        .recovery_state_invalid,
                    );
                self.windows_public_state = windows_store.commitSelection(
                    platform.backend(),
                    refreshed,
                    previous_public.apiKeyId(),
                    previous_public.modelId(),
                ) catch |err| return self.prepareFailure(
                    attempt_id,
                    accountStoreError(err),
                );
            }
            windows_store.commitRefresh(
                platform.backend(),
                &rotation.persistenceInput().refresh_token,
            ) catch |err| return self.prepareFailure(
                attempt_id,
                accountStoreError(err),
            );
        } else {
            var generation: credential_store.Generation = undefined;
            std.Io.randomSecure(self.io, &generation) catch
                return self.prepareFailure(
                    attempt_id,
                    .local_resource_exhausted,
                );
            const committed = credential_store.commitAccountOnly(
                platform.backend(),
                generation,
                rotation.persistenceInput(),
                &identity,
                self.account.executionHighWatermark(),
            ) catch |err| return self.prepareFailure(
                attempt_id,
                accountStoreError(err),
            );
            cleanup_pending = committed.retired_cleanup_pending;
        }
        self.credentials.replaceRotation(rotation);
        self.credentials.setCleanupPending(
            self.credentials.cleanupPending() or cleanup_pending,
        );
        var completion: state_impl.WorkerCompletion = .{
            .attempt_id = attempt_id,
            .payload = .{ .token_refreshed = refreshed_identity },
        };
        defer completion.deinit();
        return switch (self.account.prepareCompletion(&completion)) {
            .transition => |transition| .{ .prepared = .{
                .transition = transition,
                .follow_up = if (continue_catalog)
                    .refresh_catalog
                else
                    null,
                .cleanup_after_commit = builtin.os.tag != .windows,
                .schedule_refresh_after_commit = true,
            } },
            .rejected => |error_code| .{ .rejected = error_code },
            .ignored_stale => .ignored_stale,
        };
    }

    fn prepareFailure(
        self: *Runtime,
        attempt_id: u64,
        error_code: contract.ErrorCode,
    ) PrepareResult {
        return self.prepareFailureValue(
            attempt_id,
            .fromCode(error_code),
        );
    }

    fn prepareFailureValue(
        self: *Runtime,
        attempt_id: u64,
        failure: state_impl.WorkerFailure,
    ) PrepareResult {
        var completion: state_impl.WorkerCompletion = .{
            .attempt_id = attempt_id,
            .payload = .{ .failed = failure },
        };
        defer completion.deinit();
        return wrapPrepareResult(self.account.prepareCompletion(&completion));
    }

    fn dispatchEffect(self: *Runtime, entry: EffectQueue.Entry) void {
        const argument = entry.effect.argument();
        switch (entry.effect) {
            .begin_oauth => {
                const attempt_id = entry.attempt_id orelse
                    @panic("OAuth effect has no attempt");
                const platform = if (self.platform) |*value| value else {
                    self.effects.publishCompletion(.{
                        .attempt_id = attempt_id,
                        .payload = .{ .failed = .fromCode(
                            .credential_store_read_failed,
                        ) },
                    });
                    return;
                };
                const now = wallUnixSeconds(self.io) orelse {
                    self.effects.publishCompletion(.{
                        .attempt_id = attempt_id,
                        .payload = .{ .failed = .fromCode(
                            .dependency_contract_invalid,
                        ) },
                    });
                    return;
                };
                self.effects.startLogin(attempt_id, platform, now);
            },
            .reopen_oauth => {
                const attempt_id = entry.attempt_id orelse
                    @panic("OAuth reopen effect has no attempt");
                const platform = if (self.platform) |*value| value else {
                    self.effects.failLoginAttempt(
                        attempt_id,
                        .credential_store_read_failed,
                    );
                    return;
                };
                self.effects.reopenLogin(attempt_id, platform);
            },
            .cancel_attempt => |attempt_id| self.effects.cancelAttemptAndDiscard(
                attempt_id,
            ),
            .persist_signed_out_tombstone => self.persistSignedOut(
                entry.attempt_id orelse
                    @panic("logout effect has no attempt"),
            ),
            .delete_retired_credentials => self.retryCleanup(),
            .shutdown => {
                self.cancelRefreshTimer();
                self.effects.cancelJoinAndDiscard();
                if (self.platform) |*platform| platform.deinit();
                self.platform = null;
            },
            .refresh_token => {
                const attempt_id = entry.attempt_id orelse
                    @panic("token refresh effect has no attempt");
                if (!self.credentials.refreshAvailable()) {
                    self.effects.publishCompletion(.{
                        .attempt_id = attempt_id,
                        .payload = .{ .failed = .fromCode(
                            .credential_store_read_failed,
                        ) },
                    });
                    return;
                }
                const now = wallUnixSeconds(self.io) orelse {
                    self.effects.publishCompletion(.{
                        .attempt_id = attempt_id,
                        .payload = .{ .failed = .fromCode(
                            .dependency_contract_invalid,
                        ) },
                    });
                    return;
                };
                self.effects.startRefresh(
                    attempt_id,
                    &self.credentials,
                    now,
                    if (self.catalog_after_refresh)
                        self.account.currentIdentity()
                    else
                        null,
                );
            },
            .load_api_keys => {
                const attempt_id = entry.attempt_id orelse
                    @panic("API Key effect has no attempt");
                if (!self.credentials.available()) {
                    self.effects.publishCompletion(.{
                        .attempt_id = attempt_id,
                        .payload = .{ .failed = .fromCode(
                            .credential_store_read_failed,
                        ) },
                    });
                    return;
                }
                const identity = self.account.currentIdentity() orelse {
                    self.effects.publishCompletion(.{
                        .attempt_id = attempt_id,
                        .payload = .{ .failed = .fromCode(
                            .dependency_contract_invalid,
                        ) },
                    });
                    return;
                };
                self.effects.startLoadApiKeys(
                    attempt_id,
                    &self.credentials,
                    identity,
                );
            },
            .load_models => self.effects.startLoadModels(
                entry.attempt_id orelse
                    @panic("model catalog effect has no attempt"),
                argument orelse
                    @panic("model catalog effect has no API Key"),
            ),
            .prepare_execution => self.prepareAndPersistExecution(
                entry.attempt_id orelse
                    @panic("execution persistence effect has no attempt"),
                argument orelse
                    @panic("execution effect has no model"),
            ),
        }
    }

    fn persistSignedOut(self: *Runtime, attempt_id: u64) void {
        const platform = if (self.platform) |*value| value else {
            self.effects.publishCompletion(.{
                .attempt_id = attempt_id,
                .payload = .{ .failed = .fromCode(
                    .credential_store_write_failed,
                ) },
            });
            return;
        };
        const cleanup_pending = if (builtin.os.tag == .windows) blk: {
            windows_store.commitSignedOut(platform.backend()) catch |err| {
                self.effects.publishCompletion(.{
                    .attempt_id = attempt_id,
                    .payload = .{ .failed = .fromCode(
                        accountStoreError(err),
                    ) },
                });
                return;
            };
            self.windows_public_state = null;
            break :blk false;
        } else credential_store.commitSignedOut(
            platform.backend(),
            self.account.executionHighWatermark(),
        ) catch |err| {
            if (err == error.PersistenceOutcomeUnknown) {
                self.credentials.clear();
                self.credentials.setCleanupPending(true);
                self.effects.publishPersistenceUnknown(
                    attempt_id,
                    .logout,
                );
                self.retryCleanup();
                return;
            }
            self.effects.publishCompletion(.{
                .attempt_id = attempt_id,
                .payload = .{ .failed = .fromCode(
                    accountStoreError(err),
                ) },
            });
            return;
        };
        self.credentials.clear();
        self.cancelRefreshTimer();
        self.effects.clearCatalog();
        self.candidate_public_catalog.clear();
        self.credentials.setCleanupPending(cleanup_pending);
        self.effects.publishCompletion(.{
            .attempt_id = attempt_id,
            .payload = .logged_out,
        });
    }

    fn prepareAndPersistExecution(
        self: *Runtime,
        attempt_id: u64,
        model: []const u8,
    ) void {
        const platform = if (self.platform) |*value| value else {
            self.effects.publishCompletion(.{
                .attempt_id = attempt_id,
                .payload = .{ .failed = .fromCode(
                    .credential_store_write_failed,
                ) },
            });
            return;
        };
        const identity = self.account.currentIdentity() orelse {
            self.effects.publishCompletion(.{
                .attempt_id = attempt_id,
                .payload = .{ .failed = .fromCode(
                    .dependency_contract_invalid,
                ) },
            });
            return;
        };
        const account_view = self.account.view();
        defer self.effects.catalog.reset();
        const execution_generation = std.math.add(
            u64,
            self.account.executionHighWatermark(),
            1,
        ) catch {
            self.effects.publishCompletion(.{
                .attempt_id = attempt_id,
                .payload = .{ .failed = .fromCode(
                    .generation_mismatch,
                ) },
            });
            return;
        };
        var execution = switch (prepareCatalogExecution(
            &self.effects.catalog,
            &identity,
            account_view.model_catalog_api_key_id,
            model,
            execution_generation,
        )) {
            .ready => |owned| owned,
            .rejected => |error_code| {
                self.effects.publishCompletion(.{
                    .attempt_id = attempt_id,
                    .payload = .{ .failed = .fromCode(error_code) },
                });
                return;
            },
        };
        defer execution.deinit();
        if (builtin.os.tag == .windows) {
            self.windows_public_state = windows_store.commitSelection(
                platform.backend(),
                identity,
                self.effects.catalog.selectedApiKeyId(),
                model,
            ) catch |err| {
                self.effects.publishCompletion(.{
                    .attempt_id = attempt_id,
                    .payload = .{ .failed = .fromCode(
                        accountStoreError(err),
                    ) },
                });
                return;
            };
        } else {
            var generation: credential_store.Generation = undefined;
            std.Io.randomSecure(self.io, &generation) catch {
                self.effects.publishCompletion(.{
                    .attempt_id = attempt_id,
                    .payload = .{ .failed = .fromCode(
                        .local_resource_exhausted,
                    ) },
                });
                return;
            };
            const committed = credential_store.commitExecutionReady(
                platform.backend(),
                generation,
                identity.accountId(),
                self.effects.catalog.selectedApiKeyId(),
                &execution,
            ) catch |err| {
                if (err == error.PersistenceOutcomeUnknown) {
                    self.effects.public_catalog.clear();
                    self.candidate_public_catalog.clear();
                    self.effects.publishPersistenceUnknown(
                        attempt_id,
                        .execution,
                    );
                    return;
                }
                self.effects.publishCompletion(.{
                    .attempt_id = attempt_id,
                    .payload = .{ .failed = .fromCode(
                        accountStoreError(err),
                    ) },
                });
                return;
            };
            self.credentials.setCleanupPending(
                self.credentials.cleanupPending() or
                    committed.retired_cleanup_pending,
            );
        }
        self.effects.publishCompletion(.{
            .attempt_id = attempt_id,
            .payload = .{ .execution_ready = execution.take() },
        });
        if (builtin.os.tag != .windows) self.retryCleanup();
    }

    fn automaticApiSelection(
        self: *Runtime,
        catalog: *const catalog_impl.CatalogSession,
        account_view: contract.AccountView,
    ) ?[]const u8 {
        if (account_view.execution_state == .ready) {
            if (account_view.candidate_api_key_id.len != 0) return null;
            if (catalog.hasApiKey(account_view.selected_api_key_id))
                return account_view.selected_api_key_id;
            return null;
        }
        if (account_view.execution_state != .none) return null;
        if (builtin.os.tag == .windows) if (self.windows_public_state) |*saved| {
            const id = saved.apiKeyId();
            if (id.len > 0 and catalog.hasApiKey(id)) return id;
        };
        return catalog.uniqueApiKeyId();
    }

    fn automaticModelSelection(
        self: *const Runtime,
        catalog: *const catalog_impl.CatalogSession,
        account_view: contract.AccountView,
    ) ?[]const u8 {
        if (account_view.execution_state == .ready) {
            if (account_view.candidate_model.len != 0 or
                !std.mem.eql(
                    u8,
                    catalog.selectedApiKeyId(),
                    account_view.selected_api_key_id,
                )) return null;
            if (catalog.hasModel(account_view.selected_model))
                return account_view.selected_model;
            return null;
        }
        if (account_view.execution_state != .none) return null;
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

    fn scheduleRefresh(self: *Runtime) void {
        const platform = if (self.platform) |*value| value else return;
        const expires_at = self.credentials.expiresAt() orelse {
            platform_impl.cancelTimer(platform, refresh_timer_id) catch {};
            return;
        };
        const now = wallUnixSeconds(self.io) orelse return;
        const refresh_at = expires_at -| refresh_skew_seconds;
        const interval_ns = if (refresh_at <= now)
            refresh_retry_ns
        else
            std.math.mul(
                u64,
                @intCast(refresh_at - now),
                std.time.ns_per_s,
            ) catch std.math.maxInt(u64);
        platform_impl.startTimer(
            platform,
            refresh_timer_id,
            @max(interval_ns, 1),
            false,
        ) catch {};
    }

    fn retryCleanup(self: *Runtime) void {
        if (builtin.os.tag == .windows) return;
        if (!self.credentials.cleanupPending()) return;
        const platform = if (self.platform) |*value| value else return;
        self.credentials.setCleanupPending(
            credential_store.cleanupRetiredCredentials(
                platform.backend(),
            ) catch true,
        );
    }

    fn decorateView(
        self: *Runtime,
        account_view: *contract.AccountView,
    ) void {
        self.catalogForOperation(account_view.operation).decorate(account_view);
    }

    fn catalogForOperation(
        self: *Runtime,
        operation: contract.OperationKind,
    ) *catalog_impl.PublicCatalog {
        return switch (operation) {
            .selecting_key,
            .loading_models,
            .selecting_model,
            .persisting,
            => &self.candidate_public_catalog,
            else => &self.effects.public_catalog,
        };
    }

    fn assertMainThread(self: *const Runtime) void {
        std.debug.assert(std.Thread.getCurrentId() == self.main_thread_id);
    }

    fn prepareWindowsRestore(self: *Runtime) Prepared {
        var restored = windows_store.restore(
            self.allocator,
            self.platform.?.backend(),
        ) catch |err| {
            self.credentials.clear();
            self.windows_public_state = null;
            return self.preparedSignedOutRestoreFailure(
                accountRestoreError(err),
            );
        };
        defer restored.deinit();
        return switch (restored) {
            .signed_out => blk: {
                self.credentials.clear();
                self.windows_public_state = null;
                var value: state_impl.RestoreResult = .{
                    .signed_out = .{},
                };
                break :blk preparedFromState(
                    self.account.prepareRestore(&value),
                );
            },
            .account => |*account| blk: {
                const identity = account.public_state.identity() catch {
                    self.credentials.clear();
                    self.windows_public_state = null;
                    var value: state_impl.RestoreResult = .{
                        .signed_out = .{},
                    };
                    break :blk preparedFromState(
                        self.account.prepareRestore(&value),
                    );
                };
                self.windows_public_state = account.public_state;
                self.credentials.installRefreshToken(
                    &account.refresh_token,
                );
                var value: state_impl.RestoreResult = .{
                    .account_only = .{ .identity = identity },
                };
                var prepared = preparedFromState(
                    self.account.prepareRestore(&value),
                );
                prepared.refresh_after_commit = true;
                self.catalog_after_refresh = true;
                break :blk prepared;
            },
        };
    }

    fn prepareMacosRestore(self: *Runtime) Prepared {
        var restored = credential_store.restore(
            self.allocator,
            self.platform.?.backend(),
        ) catch |err| return self.preparedRestoreFailure(
            accountRestoreError(err),
        );
        var prepared: Prepared = switch (restored) {
            .signed_out => |signed_out| blk: {
                self.credentials.setCleanupPending(
                    signed_out.cleanup_pending,
                );
                self.credentials.clear();
                var value: state_impl.RestoreResult = .{
                    .signed_out = .{
                        .execution_high_watermark = signed_out.execution_high_watermark,
                    },
                };
                break :blk preparedFromState(
                    self.account.prepareRestore(&value),
                );
            },
            .account_only => |*account_only| blk: {
                self.credentials.setCleanupPending(
                    account_only.cleanup_pending,
                );
                self.credentials.replace(&account_only.tokens);
                var value: state_impl.RestoreResult = .{
                    .account_only = .{
                        .identity = account_only.identity,
                        .execution_high_watermark = account_only.execution_high_watermark,
                    },
                };
                account_only.deinit();
                var result = preparedFromState(
                    self.account.prepareRestore(&value),
                );
                result.follow_up = .refresh_catalog;
                break :blk result;
            },
            .execution_ready => |*execution_ready| blk: {
                self.credentials.setCleanupPending(
                    execution_ready.cleanup_pending,
                );
                self.credentials.replace(&execution_ready.tokens);
                const ready = state_impl.RestoreReady.init(
                    execution_ready.identity,
                    execution_ready.apiKeyId(),
                    &execution_ready.execution,
                ) catch {
                    execution_ready.deinit();
                    break :blk self.preparedRestoreFailure(
                        .recovery_state_invalid,
                    );
                };
                execution_ready.deinit();
                self.effects.public_catalog.replaceRestoredSelection(
                    ready.apiKeyId(),
                    ready.execution.input().target.provider_kind,
                    ready.execution.input().target.model,
                );
                var value: state_impl.RestoreResult = .{
                    .execution_ready = ready,
                };
                break :blk preparedFromState(
                    self.account.prepareRestore(&value),
                );
            },
        };
        prepared.cleanup_after_commit = true;
        prepared.schedule_refresh_after_commit = true;
        return prepared;
    }

    fn preparedRestoreFailure(
        self: *Runtime,
        error_code: contract.ErrorCode,
    ) Prepared {
        return preparedFromState(self.account.prepareRestoreFailure(
            .fromCode(error_code),
        ));
    }

    fn preparedSignedOutRestoreFailure(
        self: *Runtime,
        error_code: contract.ErrorCode,
    ) Prepared {
        return preparedFromState(
            self.account.prepareSignedOutRestoreFailure(
                .fromCode(error_code),
            ),
        );
    }
};

fn completesCatalogTransaction(fact: contract.AccountFact) bool {
    if (fact.view.operation != .none or
        fact.view.execution_state != .ready)
        return false;
    return fact.kind == .catalog_changed or fact.kind == .execution_changed;
}

pub const TestSupport = if (builtin.is_test) struct {
    pub fn prepareReadyRestore(
        runtime: *Runtime,
        execution: *contract.OwnedExecutionConfig,
    ) !Prepared {
        const ready = try state_impl.RestoreReady.init(
            try .init("account-1", "Metask User"),
            "key-1",
            execution,
        );
        runtime.effects.public_catalog.replaceRestoredSelection(
            ready.apiKeyId(),
            ready.execution.input().target.provider_kind,
            ready.execution.input().target.model,
        );
        var restored: state_impl.RestoreResult = .{
            .execution_ready = ready,
        };
        return preparedFromState(runtime.account.prepareRestore(&restored));
    }

    pub fn occupyEffectQueue(runtime: *Runtime) void {
        std.debug.assert(runtime.effects.queue.entry == null);
        runtime.effects.queue.entry = .{
            .attempt_id = 99,
            .effect = .begin_oauth,
        };
    }

    pub fn clearEffectQueue(runtime: *Runtime) void {
        _ = runtime.effects.queue.take();
    }
} else struct {};

fn wrapPrepareResult(result: state_impl.PrepareResult) PrepareResult {
    return switch (result) {
        .transition => |transition| .{ .prepared = .{
            .transition = transition,
        } },
        .rejected => |error_code| .{ .rejected = error_code },
        .ignored_stale => .ignored_stale,
    };
}

fn preparedFromState(result: state_impl.PrepareResult) Prepared {
    return switch (result) {
        .transition => |transition| .{ .transition = transition },
        .rejected, .ignored_stale => @panic(
            "Account runtime lost its restore transition",
        ),
    };
}

fn accountSelectionCommand(
    selection_id: []const u8,
    view: contract.AccountView,
) contract.AccountSelectionCommand {
    return .{
        .selection_id = selection_id,
        .expected_catalog_generation = view.catalog_generation,
        .expected_execution_generation = view.execution_generation,
    };
}

const CatalogExecutionPreparation = union(enum) {
    ready: contract.OwnedExecutionConfig,
    rejected: contract.ErrorCode,
};

fn prepareCatalogExecution(
    catalog: *catalog_impl.CatalogSession,
    identity: *const state_impl.AccountIdentity,
    model_catalog_api_key_id: []const u8,
    model: []const u8,
    execution_generation: u64,
) CatalogExecutionPreparation {
    if (!std.mem.eql(u8, catalog.ownerAccountId(), identity.accountId()))
        return .{ .rejected = .account_mismatch };
    if (!catalog.ownsExecutionSelection(
        identity.accountId(),
        model_catalog_api_key_id,
        model,
    )) return .{ .rejected = .dependency_contract_invalid };
    return .{ .ready = catalog.prepareExecution(
        model,
        execution_generation,
    ) catch |err| return .{
        .rejected = catalog_impl.errorCode(err),
    } };
}

fn accountRestoreError(err: anyerror) contract.ErrorCode {
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

fn accountStoreError(err: anyerror) contract.ErrorCode {
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

fn loginStartError(err: login_attempt.StartError) contract.ErrorCode {
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

fn testingWake(_: *anyopaque) void {}

test "Account Runtime owns automatic catalog selection policy" {
    var wake_context: u8 = 0;
    var runtime = try Runtime.init(
        std.testing.allocator,
        std.testing.io,
        std.Thread.getCurrentId(),
        if (builtin.os.tag == .windows)
            "C:\\metawork-account-runtime-test"
        else
            "/tmp/metawork-account-runtime-test",
        .{ .context = &wake_context, .notify_fn = testingWake },
    );
    defer runtime.deinit();

    var catalog = catalog_impl.CatalogSession.init(std.testing.allocator);
    defer catalog.deinit();
    try catalog_impl.TestSupport.replaceOwnedSelection(
        &catalog,
        "account-1",
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
    try catalog_impl.TestSupport.appendOwnedApiKey(
        &catalog,
        .{
            .id = "key-other",
            .name = "Other",
            .suffix = "5678",
            .provider_kind = .openai,
        },
        "other-secret",
    );
    const ready_view: contract.AccountView = .{
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
        runtime.automaticApiSelection(&catalog, ready_view).?,
    );
    var first_login_view = ready_view;
    first_login_view.execution_state = .none;
    first_login_view.selected_api_key_id = "";
    first_login_view.selected_model = "";
    try std.testing.expect(
        runtime.automaticApiSelection(&catalog, first_login_view) == null,
    );

    var loading_models_view = ready_view;
    loading_models_view.operation = .loading_models;
    loading_models_view.candidate_api_key_id = "key-current";
    try std.testing.expectEqualStrings(
        "model-current",
        runtime.automaticModelSelection(&catalog, loading_models_view).?,
    );
    loading_models_view.candidate_model = "model-other";
    try std.testing.expect(
        runtime.automaticModelSelection(&catalog, loading_models_view) == null,
    );
}

test "Account Runtime publishes the candidate catalog with first execution" {
    var wake_context: u8 = 0;
    var runtime = try initRuntimeForTest(&wake_context);
    defer runtime.deinit();

    state_impl.TestSupport.installInitialExecutionPreparation(
        &runtime.account,
        "key-1",
        "model-1",
    );
    catalog_impl.TestSupport.replacePublic(
        &runtime.candidate_public_catalog,
        &.{.{
            .id = "key-1",
            .name = "Primary",
            .suffix = "1234",
            .provider_kind = .anthropic,
        }},
        &.{.{ .id = "model-1", .display_name = "Model 1" }},
    );

    var execution = try contract.OwnedExecutionConfig.initOwned(
        std.testing.allocator,
        .anthropic,
        try std.testing.allocator.dupe(u8, "model-1"),
        try std.testing.allocator.dupe(
            u8,
            contract.metask_anthropic_messages_url,
        ),
        1,
        try std.testing.allocator.dupe(u8, "secret-key"),
    );
    var completion: state_impl.WorkerCompletion = .{
        .attempt_id = 1,
        .payload = .{ .execution_ready = execution.take() },
    };
    defer completion.deinit();
    var prepared = preparedFromState(
        runtime.account.prepareCompletion(&completion),
    );
    defer prepared.deinit();

    const fact = runtime.preparedFact(&prepared);
    try contract.validateView(fact.view);
    try std.testing.expectEqual(@as(usize, 1), fact.view.api_keys.len);
    try std.testing.expectEqual(@as(usize, 1), fact.view.models.len);
    if (prepared.takeExecution()) |execution_value| {
        var committed_execution = execution_value;
        committed_execution.deinit();
    }
    runtime.commit(&prepared);

    const committed_view = runtime.view();
    try contract.validateView(committed_view);
    try std.testing.expectEqualStrings(
        "key-1",
        committed_view.selected_api_key_id,
    );
    try std.testing.expectEqualStrings("model-1", committed_view.selected_model);
    try std.testing.expectEqual(@as(usize, 1), committed_view.api_keys.len);
    try std.testing.expectEqual(@as(usize, 1), committed_view.models.len);
}

test "Account Runtime mailbox transfers ownership and reports collision" {
    const TestWake = struct {
        count: usize = 0,

        fn notify(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.count += 1;
        }
    };

    var wake: TestWake = .{};
    var effects = Effects.init(
        std.testing.allocator,
        std.testing.io,
        .{ .context = &wake, .notify_fn = TestWake.notify },
    );
    defer effects.deinit();
    var result: login_attempt.WorkerResult = .{
        .failed = .fromCode(.oauth_callback_rejected),
    };
    try std.testing.expect(Effects.publishLoginResult(&effects, 7, &result));
    try std.testing.expect(result == .consumed);
    try std.testing.expectEqual(@as(usize, 1), wake.count);
    var mailbox = effects.takeMailbox() orelse
        return error.TestUnexpectedResult;
    defer mailbox.deinit();
    try std.testing.expectEqual(@as(u64, 7), mailbox.login.attempt_id);
    try std.testing.expectEqual(
        contract.ErrorCode.oauth_callback_rejected,
        mailbox.login.result.failed.error_code,
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
        contract.ErrorCode.token_refresh_failed,
        queued.completion.payload.failed.error_code,
    );
}

test "Account Runtime rejects cross-API model selection before persistence" {
    var candidate = catalog_impl.CatalogSession.init(std.testing.allocator);
    defer candidate.deinit();
    try catalog_impl.TestSupport.replaceOwnedSelection(
        &candidate,
        "account-1",
        .{
            .id = "key-b",
            .name = "Secondary",
            .suffix = "5678",
            .provider_kind = .anthropic,
        },
        "secret-key-b",
        &.{.{ .id = "same-model", .display_name = "Same model id" }},
    );
    const identity = try state_impl.AccountIdentity.init(
        "account-1",
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
            contract.ErrorCode.dependency_contract_invalid,
            error_code,
        ),
        .ready => |unexpected_value| {
            var unexpected = unexpected_value;
            unexpected.deinit();
            return error.TestUnexpectedResult;
        },
    }

    try std.testing.expect(candidate.ownsExecutionSelection(
        "account-1",
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
    try std.testing.expectEqualStrings("secret-key-b", execution.input().api_key);
}

fn commitAutomationRestoreForTest(runtime: *Runtime) void {
    var prepared = runtime.prepareAutomationStart();
    defer prepared.deinit();
    std.debug.assert(runtime.admitEffect(&prepared));
    runtime.commit(&prepared);
    runtime.dispatchCommitted(&prepared);
}

fn commitReadyRestoreForTest(runtime: *Runtime) !void {
    var execution = try contract.OwnedExecutionConfig.initOwned(
        std.testing.allocator,
        .anthropic,
        try std.testing.allocator.dupe(u8, "model-1"),
        try std.testing.allocator.dupe(
            u8,
            contract.metask_anthropic_messages_url,
        ),
        1,
        try std.testing.allocator.dupe(u8, "secret-key"),
    );
    var restored: state_impl.RestoreResult = .{
        .execution_ready = try .init(
            try .init("account-1", "Metask User"),
            "key-1",
            &execution,
        ),
    };
    execution.deinit();
    var prepared = preparedFromState(runtime.account.prepareRestore(&restored));
    defer prepared.deinit();
    try std.testing.expect(runtime.admitEffect(&prepared));
    if (prepared.takeExecution()) |execution_value| {
        var committed_execution = execution_value;
        committed_execution.deinit();
    }
    runtime.commit(&prepared);
    runtime.dispatchCommitted(&prepared);
}

fn initRuntimeForTest(wake_context: *u8) !Runtime {
    return Runtime.init(
        std.testing.allocator,
        std.testing.io,
        std.Thread.getCurrentId(),
        if (builtin.os.tag == .windows)
            "C:\\metawork-account-runtime-test"
        else
            "/tmp/metawork-account-runtime-test",
        .{ .context = wake_context, .notify_fn = testingWake },
    );
}

test "Account Runtime rejects effect admission without committing state" {
    var wake_context: u8 = 0;
    var runtime = try initRuntimeForTest(&wake_context);
    defer runtime.deinit();
    commitAutomationRestoreForTest(&runtime);
    runtime.effects.queue.entry = .{
        .attempt_id = 99,
        .effect = .begin_oauth,
    };
    defer _ = runtime.effects.queue.take();

    var prepared = switch (runtime.prepareCommand(.begin_login)) {
        .prepared => |value| value,
        else => return error.TestUnexpectedResult,
    };
    defer prepared.deinit();
    try std.testing.expect(!runtime.admitEffect(&prepared));
    try std.testing.expectEqual(
        contract.AccountSessionState.signed_out,
        runtime.view().session_state,
    );
}

test "Account Runtime dispatches an admitted effect only after state commit" {
    var wake_context: u8 = 0;
    var runtime = try initRuntimeForTest(&wake_context);
    defer runtime.deinit();
    commitAutomationRestoreForTest(&runtime);

    var prepared = runtime.prepareShutdown();
    defer prepared.deinit();
    try std.testing.expect(runtime.admitEffect(&prepared));
    try std.testing.expect(runtime.effects.queue.entry != null);
    try std.testing.expectEqual(
        contract.AccountSessionState.signed_out,
        runtime.view().session_state,
    );
    runtime.commit(&prepared);
    try std.testing.expectEqual(
        contract.AccountSessionState.shutting_down,
        runtime.view().session_state,
    );
    try std.testing.expect(runtime.effects.queue.entry != null);
    runtime.dispatchCommitted(&prepared);
    try std.testing.expect(runtime.effects.queue.entry == null);
}

test "Account Runtime fails closed when logout persistence is unknown" {
    var wake_context: u8 = 0;
    var runtime = try initRuntimeForTest(&wake_context);
    defer runtime.deinit();
    try commitReadyRestoreForTest(&runtime);

    var logout = switch (runtime.prepareCommand(.logout)) {
        .prepared => |value| value,
        else => return error.TestUnexpectedResult,
    };
    defer logout.deinit();
    try std.testing.expect(runtime.admitEffect(&logout));
    runtime.commit(&logout);
    const entry = runtime.effects.queue.take() orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(entry.effect == .persist_signed_out_tombstone);
    runtime.effects.publishPersistenceUnknown(entry.attempt_id.?, .logout);

    var failed = switch (runtime.prepareNextCompletion().?) {
        .prepared => |value| value,
        else => return error.TestUnexpectedResult,
    };
    defer failed.deinit();
    try std.testing.expect(runtime.admitEffect(&failed));
    runtime.commit(&failed);
    runtime.dispatchCommitted(&failed);
    try std.testing.expectEqual(
        contract.AccountSessionState.shutting_down,
        runtime.view().session_state,
    );
    try std.testing.expectEqual(
        contract.ExecutionState.none,
        runtime.view().execution_state,
    );
}

test "Account Runtime shutdown clears a ready public view" {
    var wake_context: u8 = 0;
    var runtime = try initRuntimeForTest(&wake_context);
    defer runtime.deinit();
    try commitReadyRestoreForTest(&runtime);
    try std.testing.expectEqual(
        contract.ExecutionState.ready,
        runtime.view().execution_state,
    );

    var prepared = runtime.prepareShutdown();
    defer prepared.deinit();
    try std.testing.expect(runtime.admitEffect(&prepared));
    runtime.commit(&prepared);
    runtime.dispatchCommitted(&prepared);
    const view = runtime.view();
    try std.testing.expectEqual(
        contract.AccountSessionState.shutting_down,
        view.session_state,
    );
    try std.testing.expectEqual(contract.ExecutionState.none, view.execution_state);
    try std.testing.expectEqual(@as(usize, 0), view.api_keys.len);
    try std.testing.expectEqual(@as(usize, 0), view.models.len);
    try std.testing.expect(!view.can_create_task);
}
