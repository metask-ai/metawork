//! Product Account runtime owner.
const std = @import("std");
const builtin = @import("builtin");
const contract = @import("metawork_account_contract");
const execution_contract = @import("metawork_product_execution_contract");
const state_impl = @import("account_state");
const metask_client = @import("metask_client");
const credential_store = @import("account_credential_store");
const ports_impl = @import("account_ports");
const loopback_impl = @import("account_loopback");
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
        execution_persistence_unknown: u64,
        default_model_persistence_unknown: u64,

        fn deinit(self: *MailboxResult) void {
            switch (self.*) {
                .login => |*entry| entry.result.deinit(),
                .refresh => |*entry| entry.rotation.deinit(),
                .completion => |*completion| completion.deinit(),
                .execution_persistence_unknown,
                .default_model_persistence_unknown,
                => {},
            }
        }

        fn attemptId(self: *const MailboxResult) u64 {
            return switch (self.*) {
                .login => |entry| entry.attempt_id,
                .refresh => |entry| entry.attempt_id,
                .completion => |completion| completion.attempt_id,
                .execution_persistence_unknown,
                .default_model_persistence_unknown,
                => |attempt_id| attempt_id,
            };
        }
    };

    allocator: std.mem.Allocator,
    io: std.Io,
    wake: WakeSink,
    transport: metask_client.Transport,
    loopback_endpoint: loopback_impl.Endpoint,
    queue: EffectQueue = .{},
    catalog: catalog_impl.CatalogSession,
    mailbox_mutex: std.Io.Mutex = .init,
    mailbox: ?MailboxResult = null,
    login_attempt: login_attempt.LoginAttempt = .{},
    login_active: bool = false,
    network_attempt: network_attempt.NetworkAttempt = .{},
    mailbox_collision: bool = false,

    fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        transport: metask_client.Transport,
        loopback_endpoint: loopback_impl.Endpoint,
        wake: WakeSink,
    ) Effects {
        return .{
            .allocator = allocator,
            .io = io,
            .transport = transport,
            .loopback_endpoint = loopback_endpoint,
            .wake = wake,
            .catalog = .init(allocator),
        };
    }

    fn clientTransport(self: *Effects) metask_client.Transport {
        return self.transport;
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
    ) void {
        self.lockMailbox();
        if (self.mailbox != null) {
            self.mailbox_collision = true;
            self.unlockMailbox();
            return;
        }
        self.mailbox = .{ .execution_persistence_unknown = attempt_id };
        self.unlockMailbox();
        self.notify();
    }

    fn publishDefaultModelPersistenceUnknown(
        self: *Effects,
        attempt_id: u64,
    ) void {
        self.lockMailbox();
        if (self.mailbox != null) {
            self.mailbox_collision = true;
            self.unlockMailbox();
            return;
        }
        self.mailbox = .{ .default_model_persistence_unknown = attempt_id };
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
        authorization_url: ports_impl.AuthorizationUrl,
        now_unix_seconds: i64,
    ) void {
        std.debug.assert(!self.login_active);
        self.login_attempt.start(
            self.allocator,
            self.io,
            self.loopback_endpoint,
            attempt_id,
            self.transport,
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
        authorization_url.open(
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

    fn startRefresh(
        self: *Effects,
        attempt_id: u64,
        credentials: *const credentials_impl.CredentialOwner,
        now_unix_seconds: i64,
    ) void {
        self.network_attempt.startRefresh(
            self.allocator,
            self.io,
            attempt_id,
            self.clientTransport(),
            credentials,
            self.networkSink(),
            now_unix_seconds,
        ) catch self.publishCompletion(.{
            .attempt_id = attempt_id,
            .payload = .{ .failed = .fromCode(.local_resource_exhausted) },
        });
    }

    fn startLoadIdentity(
        self: *Effects,
        attempt_id: u64,
        credentials: *const credentials_impl.CredentialOwner,
    ) void {
        self.network_attempt.startLoadIdentity(
            self.allocator,
            self.io,
            attempt_id,
            self.clientTransport(),
            credentials,
            self.networkSink(),
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
    }

    fn deinit(self: *Effects) void {
        self.cancelJoinAndDiscard();
        std.debug.assert(self.queue.entry == null);
        self.catalog.deinit();
        self.* = undefined;
    }

    fn clearCatalog(self: *Effects) void {
        self.catalog.reset();
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
    schedule_refresh_after_commit: bool = false,
    retry_refresh_after_commit: bool = false,

    pub fn factKind(self: *const Prepared) contract.AccountFactKind {
        return self.transition.factKind();
    }

    pub fn takeExecution(
        self: *Prepared,
    ) ?execution_contract.OwnedConfig {
        return self.transition.takeExecution();
    }

    pub fn attemptId(self: *const Prepared) ?u64 {
        return self.transition.attempt_id;
    }

    pub fn replacementIntent(self: *const Prepared) state_impl.ReplacementIntent {
        return self.transition.replacementIntent();
    }

    pub fn executionIntent(self: *const Prepared) state_impl.ExecutionIntent {
        return self.transition.executionIntent();
    }

    pub fn preferenceIntent(self: *const Prepared) state_impl.PreferenceIntent {
        return self.transition.preferenceIntent();
    }

    pub fn deinit(self: *Prepared) void {
        self.transition.deinit();
        self.follow_up = null;
        self.automatic_selection = .none;
        self.refresh_after_commit = false;
        self.schedule_refresh_after_commit = false;
        self.retry_refresh_after_commit = false;
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
    committed_public_catalog: catalog_impl.PublicCatalog = .{},
    candidate_public_catalog: catalog_impl.PublicCatalog = .{},
    candidate_catalog_attempt_id: ?u64 = null,
    view_catalog_slot: enum { committed, candidate } = .committed,
    platform: ?ports_impl.Platform = null,
    credentials: credentials_impl.CredentialOwner = .{},
    saved_preference: ?credential_store.Preference = null,
    pending_default_preference: ?struct {
        attempt_id: u64,
        value: credential_store.Preference,
    } = null,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        main_thread_id: std.Thread.Id,
        account_path: []const u8,
        transport: metask_client.Transport,
        loopback_endpoint: loopback_impl.Endpoint,
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
            .effects = .init(
                allocator,
                io,
                transport,
                loopback_endpoint,
                wake,
            ),
        };
        @memcpy(runtime.account_path_storage[0..account_path.len], account_path);
        return runtime;
    }

    pub fn deinit(self: *Runtime) void {
        self.assertMainThread();
        std.debug.assert(self.platform == null);
        self.effects.deinit();
        self.credentials.deinit();
        self.saved_preference = null;
        self.pending_default_preference = null;
        self.committed_public_catalog.clear();
        self.candidate_public_catalog.clear();
        self.candidate_catalog_attempt_id = null;
        self.* = undefined;
    }

    pub fn prepareStart(
        self: *Runtime,
        platform: ports_impl.Platform,
    ) Prepared {
        self.assertMainThread();
        std.debug.assert(self.platform == null);
        self.platform = platform;
        return self.prepareRestore();
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
        return self.preparedSignedOutRestoreFailure(
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
            .begin_login => {
                if (account_view.state == .signed_out and
                    self.credentials.refreshAvailable())
                    return wrapPrepareResult(
                        self.account.prepareRestoredTokenRefresh(),
                    );
            },
            else => {},
        }
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
            .activate_metask => |activation| {
                if (activation.expected_catalog_generation !=
                    account_view.catalog_generation or
                    activation.expected_execution_generation !=
                        account_view.metask_execution_generation or
                    account_view.state != .authenticated or
                    account_view.catalog_state != .ready)
                    return .{ .rejected = .generation_mismatch };
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
                const platform = self.platform orelse return result;
                platform.timer.start(
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
        return preparedFromState(self.account.prepareRestoredTokenRefresh());
    }

    pub fn prepareContinuationFailure(
        self: *Runtime,
        error_code: contract.ErrorCode,
    ) Prepared {
        self.assertMainThread();
        return preparedFromState(self.account.prepareIdleFailure(error_code));
    }

    pub fn prepareActiveAttemptFailure(
        self: *Runtime,
        error_code: contract.ErrorCode,
    ) Prepared {
        self.assertMainThread();
        const attempt_id = self.account.activeAttempt() orelse
            @panic("Account effect admission failed without an active attempt");
        var completion: state_impl.WorkerCompletion = .{
            .attempt_id = attempt_id,
            .payload = .{ .failed = .fromCode(error_code) },
        };
        return preparedFromState(self.account.prepareCompletion(&completion));
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
                    .authorized => |*tokens| self.prepareAuthorizedLogin(
                        entry.attempt_id,
                        tokens,
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
            .execution_persistence_unknown => wrapPrepareResult(
                self.account.prepareExecutionPersistenceUnknown(),
            ),
            .default_model_persistence_unknown => |attempt_id| self.prepareDefaultModelPersistenceUnknown(attempt_id),
        };
    }

    pub fn view(self: *Runtime) contract.AccountView {
        self.assertMainThread();
        var result = self.account.view();
        self.decorateView(&result);
        contract.validateView(result) catch
            @panic("Account Runtime produced an invalid canonical AccountView");
        return result;
    }

    pub fn preparedFact(
        self: *Runtime,
        prepared: *const Prepared,
    ) contract.AccountFact {
        self.assertMainThread();
        var fact: contract.AccountFact = .{
            .kind = prepared.factKind(),
            .view = prepared.transition.view(),
        };
        if (fact.view.state == .authenticated and
            fact.view.catalog_state != .unavailable)
        {
            const catalog = switch (prepared.transition.catalogIntent()) {
                .candidate, .promote_candidate => &self.candidate_public_catalog,
                .committed, .discard_candidate, .clear_all => &self.committed_public_catalog,
            };
            catalog.decorate(&fact.view);
        }
        contract.validateView(fact.view) catch
            @panic("Account Runtime prepared an invalid canonical AccountView");
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
        switch (prepared.transition.catalogIntent()) {
            .committed => self.view_catalog_slot = .committed,
            .candidate => self.view_catalog_slot = .candidate,
            .promote_candidate => {
                std.debug.assert(
                    self.candidate_catalog_attempt_id == prepared.attemptId(),
                );
                self.committed_public_catalog.replaceFromPublic(
                    &self.candidate_public_catalog,
                );
                self.candidate_public_catalog.clear();
                self.candidate_catalog_attempt_id = null;
                self.view_catalog_slot = .committed;
            },
            .discard_candidate => {
                self.candidate_public_catalog.clear();
                self.candidate_catalog_attempt_id = null;
                self.view_catalog_slot = .committed;
            },
            .clear_all => {
                self.committed_public_catalog.clear();
                self.candidate_public_catalog.clear();
                self.candidate_catalog_attempt_id = null;
                self.view_catalog_slot = .committed;
            },
        }
        switch (prepared.preferenceIntent()) {
            .unchanged => {},
            .commit_pending => {
                const pending = self.pending_default_preference orelse
                    @panic("Account preference commit has no pending value");
                std.debug.assert(prepared.attemptId() == pending.attempt_id);
                self.saved_preference = pending.value;
            },
            .clear => self.saved_preference = null,
        }
        if (self.pending_default_preference) |pending| {
            if (prepared.attemptId() == pending.attempt_id)
                self.pending_default_preference = null;
        }
        prepared.transition.commit(&self.account);
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
        if (prepared.schedule_refresh_after_commit)
            self.scheduleRefresh();
        if (prepared.retry_refresh_after_commit) {
            if (self.platform) |platform|
                platform.timer.start(
                    refresh_timer_id,
                    refresh_retry_ns,
                    false,
                ) catch {};
        }
        if (self.effects.queue.take()) |entry|
            self.dispatchEffect(entry);
        switch (prepared.transition.catalogIntent()) {
            .committed, .candidate => {},
            .promote_candidate, .discard_candidate, .clear_all => self.effects.clearCatalog(),
        }
    }

    pub fn cancelRefreshTimer(self: *Runtime) void {
        self.assertMainThread();
        const platform = self.platform orelse return;
        platform.timer.cancel(refresh_timer_id) catch {};
    }

    fn prepareWorkerCompletion(
        self: *Runtime,
        completion: *state_impl.WorkerCompletion,
        collision: bool,
    ) PrepareResult {
        const catalog_attempt = self.account.catalogAttemptActive();
        const refresh_attempt = self.account.refreshInFlight();
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
        // A models-load failure parks the transaction in choosing with the
        // key list kept (state prepareFailure); the session holding those
        // keys' secrets must survive with it, or every re-pick dispatches a
        // model load that cannot resolve its key. Only a torn-down catalog
        // attempt resets the session.
        if (catalog_attempt and completion.payload == .failed and
            !self.account.catalogModelsLoadInFlight())
            self.effects.catalog.reset();

        if (completion.payload == .failed and
            completion.payload.failed.error_code == .metask_unauthorized and
            self.account.credentialValidationInFlight())
            completion.payload.failed.error_code =
                self.deleteInvalidCredential();

        const loaded_identity: ?state_impl.AccountIdentity = switch (completion.payload) {
            .identity_loaded => |identity| identity,
            else => null,
        };
        const retry_refresh = refresh_attempt and
            completion.payload == .failed and
            completion.payload.failed.error_code != .metask_unauthorized and
            completion.payload.failed.error_code != .credential_store_delete_failed and
            self.account.currentIdentity() != null;
        if (loaded_identity) |identity| {
            if (self.platform) |platform|
                self.discardForeignPreference(platform, identity.accountId());
        }

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
                .api_keys_loaded, .models_loaded => {
                    self.candidate_public_catalog.replaceFromSession(
                        &self.effects.catalog,
                    );
                    self.candidate_catalog_attempt_id = completion.attempt_id;
                },
                else => {},
            }
        }
        return switch (self.account.prepareCompletion(completion)) {
            .transition => |transition| .{ .prepared = .{
                .transition = transition,
                .automatic_selection = automatic_selection,
                .follow_up = if (loaded_identity != null)
                    .refresh_catalog
                else
                    null,
                .schedule_refresh_after_commit = loaded_identity != null,
                .retry_refresh_after_commit = retry_refresh,
            } },
            .rejected => |error_code| .{ .rejected = error_code },
            .ignored_stale => .ignored_stale,
        };
    }

    fn deleteInvalidCredential(self: *Runtime) contract.ErrorCode {
        const result: contract.ErrorCode = if (self.platform) |platform| blk: {
            credential_store.commitSignedOut(platform.credentials) catch |err|
                break :blk accountStoreError(err);
            break :blk .metask_unauthorized;
        } else .credential_store_delete_failed;
        self.credentials.clear();
        self.saved_preference = null;
        self.cancelRefreshTimer();
        self.effects.clearCatalog();
        self.candidate_public_catalog.clear();
        self.candidate_catalog_attempt_id = null;
        return result;
    }

    fn prepareAuthorizedLogin(
        self: *Runtime,
        attempt_id: u64,
        tokens: *metask_client.AuthorizationResult,
    ) PrepareResult {
        const platform = self.platform orelse return self.prepareFailure(
            attempt_id,
            .credential_store_write_failed,
        );
        credential_store.commitRefresh(
            platform.credentials,
            &tokens.refresh_token,
        ) catch |err| return self.prepareFailure(
            attempt_id,
            accountStoreError(err),
        );
        self.credentials.replace(tokens);
        var completion: state_impl.WorkerCompletion = .{
            .attempt_id = attempt_id,
            .payload = .tokens_persisted,
        };
        defer completion.deinit();
        return switch (self.account.prepareCompletion(&completion)) {
            .transition => |transition| .{ .prepared = .{
                .transition = transition,
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
        const identity = self.account.currentIdentity();
        const belongs_to_current_account = if (identity) |current|
            rotation.belongsToAccount(current.accountId())
        else
            true;
        const platform = self.platform orelse return self.prepareFailure(
            attempt_id,
            .credential_store_write_failed,
        );
        credential_store.commitRefresh(
            platform.credentials,
            &rotation.persistenceInput().refresh_token,
        ) catch |err| return self.prepareFailure(
            attempt_id,
            accountStoreError(err),
        );
        self.credentials.replaceRotation(rotation);
        if (!belongs_to_current_account) {
            const error_code = self.deleteInvalidCredential();
            return self.prepareFailure(attempt_id, error_code);
        }
        var completion: state_impl.WorkerCompletion = .{
            .attempt_id = attempt_id,
            .payload = .tokens_persisted,
        };
        defer completion.deinit();
        return switch (self.account.prepareCompletion(&completion)) {
            .transition => |transition| .{ .prepared = .{
                .transition = transition,
                .schedule_refresh_after_commit = identity != null,
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
                const platform = self.platform orelse {
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
                self.effects.startLogin(
                    attempt_id,
                    platform.authorization_url,
                    now,
                );
            },
            .cancel_attempt => |attempt_id| self.effects.cancelAttemptAndDiscard(
                attempt_id,
            ),
            .delete_credential => self.persistSignedOut(
                entry.attempt_id orelse
                    @panic("logout effect has no attempt"),
            ),
            .persist_default_model => self.persistDefaultModel(
                entry.attempt_id orelse
                    @panic("default-model persistence effect has no attempt"),
                argument orelse unreachable,
            ),
            .shutdown => {
                self.cancelRefreshTimer();
                self.effects.cancelJoinAndDiscard();
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
                );
            },
            .load_identity => {
                const attempt_id = entry.attempt_id orelse
                    @panic("identity effect has no attempt");
                if (!self.credentials.available()) {
                    self.effects.publishCompletion(.{
                        .attempt_id = attempt_id,
                        .payload = .{ .failed = .fromCode(
                            .credential_store_read_failed,
                        ) },
                    });
                    return;
                }
                self.effects.startLoadIdentity(
                    attempt_id,
                    &self.credentials,
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
        const platform = self.platform orelse {
            self.effects.publishCompletion(.{
                .attempt_id = attempt_id,
                .payload = .{ .failed = .fromCode(
                    .credential_store_write_failed,
                ) },
            });
            return;
        };
        credential_store.commitSignedOut(platform.credentials) catch |err| {
            self.effects.publishCompletion(.{
                .attempt_id = attempt_id,
                .payload = .{ .failed = .fromCode(
                    accountStoreError(err),
                ) },
            });
            return;
        };
        self.saved_preference = null;
        self.credentials.clear();
        self.cancelRefreshTimer();
        self.effects.clearCatalog();
        self.candidate_public_catalog.clear();
        self.candidate_catalog_attempt_id = null;
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
        const restored_generation = self.savedExecutionGenerationFor(
            identity.accountId(),
            self.effects.catalog.selectedApiKeyId(),
            model,
            account_view.execution_generation,
        );
        const execution_generation = restored_generation orelse
            generateExecutionGeneration(
                self.io,
                account_view.execution_generation,
            ) catch {
            self.effects.publishCompletion(.{
                .attempt_id = attempt_id,
                .payload = .{ .failed = .fromCode(
                    .local_resource_exhausted,
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
        if (restored_generation == null) {
            const platform = self.platform orelse {
                self.effects.publishCompletion(.{
                    .attempt_id = attempt_id,
                    .payload = .{ .failed = .fromCode(
                        .credential_store_write_failed,
                    ) },
                });
                return;
            };
            self.saved_preference = credential_store.commitPreference(
                platform.credentials,
                identity.accountId(),
                self.effects.catalog.selectedApiKeyId(),
                model,
                execution_generation,
            ) catch |err| {
                if (err == error.PersistenceOutcomeUnknown) {
                    self.committed_public_catalog.clear();
                    self.candidate_public_catalog.clear();
                    self.candidate_catalog_attempt_id = null;
                    self.effects.publishPersistenceUnknown(
                        attempt_id,
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
        }
        self.effects.publishCompletion(.{
            .attempt_id = attempt_id,
            .payload = .{ .execution_ready = execution.take() },
        });
    }

    fn persistDefaultModel(
        self: *Runtime,
        attempt_id: u64,
        model: []const u8,
    ) void {
        const identity = self.account.currentIdentity() orelse {
            self.effects.publishCompletion(.{
                .attempt_id = attempt_id,
                .payload = .{ .failed = .fromCode(
                    .dependency_contract_invalid,
                ) },
            });
            return;
        };
        const platform = self.platform orelse {
            self.effects.publishCompletion(.{
                .attempt_id = attempt_id,
                .payload = .{ .failed = .fromCode(
                    .credential_store_write_failed,
                ) },
            });
            return;
        };
        const account_view = self.account.view();
        const preference = credential_store.commitPreference(
            platform.credentials,
            identity.accountId(),
            account_view.selected_api_key_id,
            model,
            account_view.execution_generation,
        ) catch |err| {
            if (err == error.PersistenceOutcomeUnknown) {
                self.effects.publishDefaultModelPersistenceUnknown(attempt_id);
                return;
            }
            self.effects.publishCompletion(.{
                .attempt_id = attempt_id,
                .payload = .{ .failed = .fromCode(accountStoreError(err)) },
            });
            return;
        };
        self.pending_default_preference = .{
            .attempt_id = attempt_id,
            .value = preference,
        };
        self.effects.publishCompletion(.{
            .attempt_id = attempt_id,
            .payload = .default_model_persisted,
        });
    }

    fn prepareDefaultModelPersistenceUnknown(
        self: *Runtime,
        attempt_id: u64,
    ) PrepareResult {
        if (self.account.activeAttempt() != attempt_id)
            return .ignored_stale;
        const account_view = self.account.view();
        const platform = self.platform orelse
            return wrapPrepareResult(
                self.account.prepareDefaultModelPersistenceInvalid(),
            );
        const observed = platform.credentials.loadPreference() catch
            return wrapPrepareResult(
                self.account.prepareDefaultModelPersistenceInvalid(),
            );
        const preference = observed orelse
            return wrapPrepareResult(
                self.account.prepareDefaultModelPersistenceInvalid(),
            );
        const same_tuple = std.mem.eql(
            u8,
            preference.ownerAccountId(),
            account_view.account_id,
        ) and std.mem.eql(
            u8,
            preference.apiKeyId(),
            account_view.selected_api_key_id,
        ) and preference.execution_generation == account_view.execution_generation;
        if (!same_tuple)
            return wrapPrepareResult(
                self.account.prepareDefaultModelPersistenceInvalid(),
            );
        if (std.mem.eql(u8, preference.modelId(), account_view.candidate_model)) {
            self.pending_default_preference = .{
                .attempt_id = attempt_id,
                .value = preference,
            };
            var completion: state_impl.WorkerCompletion = .{
                .attempt_id = attempt_id,
                .payload = .default_model_persisted,
            };
            return wrapPrepareResult(self.account.prepareCompletion(&completion));
        }
        if (std.mem.eql(u8, preference.modelId(), account_view.selected_model))
            return self.prepareFailure(
                attempt_id,
                .credential_store_write_failed,
            );
        return wrapPrepareResult(
            self.account.prepareDefaultModelPersistenceInvalid(),
        );
    }

    fn automaticApiSelection(
        self: *Runtime,
        catalog: *const catalog_impl.CatalogSession,
        account_view: contract.AccountView,
    ) ?[]const u8 {
        if (account_view.execution_generation != 0) {
            if (account_view.candidate_api_key_id.len != 0) return null;
            if (catalog.hasApiKey(account_view.selected_api_key_id))
                return account_view.selected_api_key_id;
            return null;
        }
        if (self.savedPreferenceFor(account_view.account_id)) |saved| {
            const id = saved.apiKeyId();
            if (catalog.hasApiKey(id)) return id;
        }
        return catalog.firstApiKeyId();
    }

    fn automaticModelSelection(
        self: *const Runtime,
        catalog: *const catalog_impl.CatalogSession,
        account_view: contract.AccountView,
    ) ?[]const u8 {
        if (account_view.candidate_model.len != 0) return null;
        if (catalog.hasModel(account_view.selected_model))
            return account_view.selected_model;
        if (self.savedPreferenceFor(account_view.account_id)) |saved| {
            const id = saved.modelId();
            if (std.mem.eql(
                u8,
                catalog.selectedApiKeyId(),
                saved.apiKeyId(),
            ) and catalog.hasModel(id)) return id;
        }
        return catalog.firstModelId();
    }

    fn scheduleRefresh(self: *Runtime) void {
        const platform = self.platform orelse return;
        const expires_at = self.credentials.expiresAt() orelse {
            platform.timer.cancel(refresh_timer_id) catch {};
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
        platform.timer.start(
            refresh_timer_id,
            @max(interval_ns, 1),
            false,
        ) catch {};
    }

    fn savedPreferenceFor(
        self: *const Runtime,
        account_id: []const u8,
    ) ?*const credential_store.Preference {
        const saved = if (self.saved_preference) |*value| value else return null;
        if (!std.mem.eql(u8, saved.ownerAccountId(), account_id)) return null;
        return saved;
    }

    fn savedExecutionGenerationFor(
        self: *const Runtime,
        account_id: []const u8,
        api_key_id: []const u8,
        model_id: []const u8,
        current_execution_generation: u64,
    ) ?u64 {
        if (current_execution_generation != 0) return null;
        const saved = self.savedPreferenceFor(account_id) orelse return null;
        if (!std.mem.eql(u8, saved.apiKeyId(), api_key_id) or
            !std.mem.eql(u8, saved.modelId(), model_id)) return null;
        return saved.execution_generation;
    }

    fn discardForeignPreference(
        self: *Runtime,
        platform: ports_impl.Platform,
        account_id: []const u8,
    ) void {
        const saved = self.saved_preference orelse return;
        if (std.mem.eql(u8, saved.ownerAccountId(), account_id)) return;
        self.saved_preference = null;
        credential_store.clearPreference(platform.credentials) catch {};
    }

    fn decorateView(
        self: *Runtime,
        account_view: *contract.AccountView,
    ) void {
        if (account_view.state != .authenticated or
            account_view.catalog_state == .unavailable)
            return;
        const catalog = switch (self.view_catalog_slot) {
            .committed => &self.committed_public_catalog,
            .candidate => &self.candidate_public_catalog,
        };
        catalog.decorate(account_view);
    }

    fn assertMainThread(self: *const Runtime) void {
        std.debug.assert(std.Thread.getCurrentId() == self.main_thread_id);
    }

    fn prepareRestore(self: *Runtime) Prepared {
        var restored = credential_store.restore(
            self.allocator,
            self.platform.?.credentials,
        ) catch |err| {
            self.credentials.clear();
            self.saved_preference = null;
            return self.preparedSignedOutRestoreFailure(
                accountRestoreError(err),
            );
        };
        defer restored.deinit();
        return switch (restored) {
            .signed_out => blk: {
                self.credentials.clear();
                self.saved_preference = null;
                var value: state_impl.RestoreResult = .{
                    .signed_out = .{},
                };
                break :blk preparedFromState(
                    self.account.prepareRestore(&value),
                );
            },
            .account => |*account| blk: {
                self.saved_preference = account.preference;
                self.credentials.installRefreshToken(
                    &account.refresh_token,
                );
                var value: state_impl.RestoreResult = .{
                    .refresh_only = {},
                };
                var prepared = preparedFromState(
                    self.account.prepareRestore(&value),
                );
                prepared.refresh_after_commit = true;
                break :blk prepared;
            },
        };
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

fn generateExecutionGeneration(
    io: std.Io,
    current_generation: u64,
) !u64 {
    while (true) {
        var bytes: [@sizeOf(u64)]u8 = undefined;
        try std.Io.randomSecure(io, &bytes);
        const generation = std.mem.readInt(u64, &bytes, .big);
        if (generation != 0 and generation != current_generation)
            return generation;
    }
}

pub const TestSupport = if (builtin.is_test) struct {
    var loopback_context: u8 = 0;

    pub fn loopbackEndpoint() loopback_impl.Endpoint {
        return .{
            .context = &loopback_context,
            .open_fn = testLoopbackOpen,
            .wait_fn = testLoopbackWait,
            .cancel_fn = testLoopbackCancel,
            .close_fn = testLoopbackClose,
        };
    }

    fn testLoopbackOpen(_: *anyopaque) loopback_impl.ServerError!u16 {
        return 49152;
    }

    fn testLoopbackWait(
        _: *anyopaque,
        _: loopback_impl.RequestSink,
        _: std.Io.Clock.Timestamp,
    ) loopback_impl.ServerError!void {
        return error.Cancelled;
    }

    fn testLoopbackCancel(_: *anyopaque) void {}
    fn testLoopbackClose(_: *anyopaque) void {}

    pub fn prepareReadyRestore(
        runtime: *Runtime,
        execution: *execution_contract.OwnedConfig,
    ) !Prepared {
        const input = execution.input();
        runtime.committed_public_catalog.replaceRestoredSelection(
            "key-1",
            input.target.protocol,
            input.target.model,
        );
        return .{ .transition = try state_impl.TestSupport.prepareReady(
            &runtime.account,
            try .init("account-1", "Metask User"),
            "key-1",
            execution,
        ) };
    }

    pub fn overrideTransport(
        runtime: *Runtime,
        transport: metask_client.Transport,
    ) void {
        runtime.effects.transport = transport;
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

    pub fn discardMailbox(runtime: *Runtime) void {
        var mailbox = runtime.effects.takeMailbox() orelse return;
        mailbox.deinit();
    }

    pub fn prepareTokensPersisted(runtime: *Runtime) Prepared {
        var completion: state_impl.WorkerCompletion = .{
            .attempt_id = runtime.account.activeAttempt() orelse
                @panic("test Account has no active login"),
            .payload = .tokens_persisted,
        };
        return preparedFromState(runtime.account.prepareCompletion(&completion));
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
    ready: execution_contract.OwnedConfig,
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
        return .{ .rejected = .metask_unauthorized };
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

var testing_transport_context: u8 = 0;

fn testingTransport() metask_client.Transport {
    return .{
        .context = &testing_transport_context,
        .perform_fn = testingPerform,
    };
}

const TestPlatform = struct {
    const PreferenceCommitMode = enum {
        normal,
        unknown_after_write,
        unknown_without_write,
    };

    refresh_token: ?[]const u8 = null,
    preference: ?credential_store.Preference = null,
    preference_commit_mode: PreferenceCommitMode = .normal,

    fn platform(self: *TestPlatform) ports_impl.Platform {
        return .{
            .credentials = .{
                .context = self,
                .set_refresh_token_fn = setRefresh,
                .get_refresh_token_fn = getRefresh,
                .delete_refresh_token_fn = deleteRefresh,
                .load_preference_fn = loadPreference,
                .commit_preference_fn = commitPreference,
                .delete_preference_fn = deletePreference,
            },
            .authorization_url = .{
                .context = self,
                .open_fn = openAuthorizationUrl,
            },
            .timer = .{
                .context = self,
                .start_fn = startTimer,
                .cancel_fn = cancelTimer,
            },
        };
    }

    fn setRefresh(context: *anyopaque, value: []const u8) credential_store.StoreError!void {
        const self: *TestPlatform = @ptrCast(@alignCast(context));
        self.refresh_token = value;
    }

    fn getRefresh(
        context: *anyopaque,
        output: []u8,
    ) credential_store.StoreError!?[]const u8 {
        const self: *TestPlatform = @ptrCast(@alignCast(context));
        const value = self.refresh_token orelse return null;
        if (value.len > output.len) return error.ReadFailed;
        @memcpy(output[0..value.len], value);
        return output[0..value.len];
    }

    fn deleteRefresh(context: *anyopaque) credential_store.StoreError!void {
        const self: *TestPlatform = @ptrCast(@alignCast(context));
        self.refresh_token = null;
    }

    fn loadPreference(context: *anyopaque) credential_store.StoreError!?credential_store.Preference {
        const self: *TestPlatform = @ptrCast(@alignCast(context));
        return self.preference;
    }

    fn commitPreference(
        context: *anyopaque,
        value: credential_store.Preference,
    ) credential_store.StoreError!void {
        const self: *TestPlatform = @ptrCast(@alignCast(context));
        if (self.preference_commit_mode == .unknown_without_write) {
            self.preference_commit_mode = .normal;
            return error.PersistenceOutcomeUnknown;
        }
        self.preference = value;
        if (self.preference_commit_mode == .unknown_after_write) {
            self.preference_commit_mode = .normal;
            return error.PersistenceOutcomeUnknown;
        }
    }

    fn deletePreference(context: *anyopaque) credential_store.StoreError!void {
        const self: *TestPlatform = @ptrCast(@alignCast(context));
        self.preference = null;
    }

    fn openAuthorizationUrl(_: *anyopaque, _: []const u8) !void {}
    fn startTimer(_: *anyopaque, _: u64, _: u64, _: bool) !void {}
    fn cancelTimer(_: *anyopaque, _: u64) !void {}
};

fn testingPerform(
    _: *anyopaque,
    _: metask_client.Request,
    _: []u8,
) metask_client.TransportError!metask_client.Response {
    return error.NetworkFailed;
}

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
        testingTransport(),
        TestSupport.loopbackEndpoint(),
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
            .protocol = .anthropic_messages,
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
            .protocol = .openai_chat_completions,
        },
        "other-secret",
    );
    const ready_view: contract.AccountView = .{
        .state = .authenticated,
        .catalog_state = .loading,
        .selected_api_key_id = "key-current",
        .selected_model = "model-current",
        .execution_generation = 1,
    };
    try std.testing.expectEqualStrings(
        "key-current",
        runtime.automaticApiSelection(&catalog, ready_view).?,
    );
    var first_login_view = ready_view;
    first_login_view.selected_api_key_id = "";
    first_login_view.selected_model = "";
    first_login_view.execution_generation = 0;
    // First login without a saved preference defaults to the catalog's
    // first key; the user adjusts in settings afterwards.
    try std.testing.expectEqualStrings(
        "key-current",
        runtime.automaticApiSelection(&catalog, first_login_view).?,
    );
    // Model selection also defaults to the first entry when neither the
    // committed selection nor a saved preference survives in the catalog.
    var first_model_view = first_login_view;
    first_model_view.selected_model = "model-missing";
    try std.testing.expectEqualStrings(
        "model-current",
        runtime.automaticModelSelection(&catalog, first_model_view).?,
    );
    runtime.saved_preference = try .init(
        "account-1",
        "key-current",
        "model-current",
        0x1020_3040_5060_7080,
    );
    try std.testing.expectEqual(
        @as(?u64, 0x1020_3040_5060_7080),
        runtime.savedExecutionGenerationFor(
            "account-1",
            "key-current",
            "model-current",
            0,
        ),
    );
    try std.testing.expect(runtime.savedExecutionGenerationFor(
        "account-2",
        "key-current",
        "model-current",
        0,
    ) == null);
    try std.testing.expect(runtime.savedExecutionGenerationFor(
        "account-1",
        "key-current",
        "model-other",
        0,
    ) == null);
    try std.testing.expect(runtime.savedExecutionGenerationFor(
        "account-1",
        "key-current",
        "model-current",
        1,
    ) == null);

    var loading_models_view = ready_view;
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

fn installExecutionPreparationForTest(runtime: *Runtime) !void {
    state_impl.TestSupport.installInitialExecutionPreparation(
        &runtime.account,
        "key-1",
        "model-1",
    );
    try catalog_impl.TestSupport.replaceOwnedSelection(
        &runtime.effects.catalog,
        "account-1",
        .{
            .id = "key-1",
            .name = "Primary",
            .suffix = "1234",
            .protocol = .anthropic_messages,
        },
        "secret-key",
        &.{.{ .id = "model-1", .display_name = "Model 1" }},
    );
}

test "Account Runtime restores an exact persisted execution nonce" {
    var wake_context: u8 = 0;
    var runtime = try initRuntimeForTest(&wake_context);
    defer runtime.deinit();
    runtime.saved_preference = try .init(
        "account-1",
        "key-1",
        "model-1",
        0x1020_3040_5060_7080,
    );
    try installExecutionPreparationForTest(&runtime);

    runtime.prepareAndPersistExecution(1, "model-1");
    var mailbox = runtime.effects.takeMailbox() orelse
        return error.TestUnexpectedResult;
    defer mailbox.deinit();
    switch (mailbox) {
        .completion => |completion| switch (completion.payload) {
            .execution_ready => |execution| try std.testing.expectEqual(
                @as(u64, 0x1020_3040_5060_7080),
                execution.input().execution_generation,
            ),
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
}

test "Account Runtime persists a nonzero nonce for a new execution" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var account_path_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const account_path_len = try tmp.dir.realPath(
        std.testing.io,
        &account_path_storage,
    );
    var wake_context: u8 = 0;
    var runtime = try Runtime.init(
        std.testing.allocator,
        std.testing.io,
        std.Thread.getCurrentId(),
        account_path_storage[0..account_path_len],
        testingTransport(),
        TestSupport.loopbackEndpoint(),
        .{ .context = &wake_context, .notify_fn = testingWake },
    );
    defer runtime.deinit();
    defer runtime.platform = null;
    var fake: TestPlatform = .{};
    var startup = runtime.prepareStart(fake.platform());
    defer startup.deinit();
    try installExecutionPreparationForTest(&runtime);

    runtime.prepareAndPersistExecution(1, "model-1");
    var mailbox = runtime.effects.takeMailbox() orelse
        return error.TestUnexpectedResult;
    defer mailbox.deinit();
    const generation = switch (mailbox) {
        .completion => |completion| switch (completion.payload) {
            .execution_ready => |execution| execution.input().execution_generation,
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(generation != 0);
    try std.testing.expectEqual(
        generation,
        runtime.saved_preference.?.execution_generation,
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
    try catalog_impl.TestSupport.replaceOwnedSelection(
        &runtime.effects.catalog,
        "account-1",
        .{
            .id = "key-1",
            .name = "Primary",
            .suffix = "1234",
            .protocol = .anthropic_messages,
        },
        "secret-key",
        &.{.{ .id = "model-1", .display_name = "Model 1" }},
    );
    catalog_impl.TestSupport.replacePublic(
        &runtime.candidate_public_catalog,
        &.{.{
            .id = "key-1",
            .name = "Primary",
            .suffix = "1234",
            .protocol = .anthropic_messages,
        }},
        &.{.{ .id = "model-1", .display_name = "Model 1" }},
    );
    runtime.candidate_catalog_attempt_id = 1;

    var execution = try execution_contract.OwnedConfig.initOwned(
        std.testing.allocator,
        .metask,
        .anthropic_messages,
        try std.testing.allocator.dupe(u8, "model-1"),
        try std.testing.allocator.dupe(
            u8,
            contract.metask_anthropic_messages_url,
        ),
        1,
        try std.testing.allocator.dupe(u8, "secret-key"),
        "fixture-provider",
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
    try std.testing.expect(runtime.effects.catalog.firstApiKeyId() != null);
    runtime.dispatchCommitted(&prepared);

    const committed_view = runtime.view();
    try contract.validateView(committed_view);
    try std.testing.expectEqualStrings(
        "key-1",
        committed_view.selected_api_key_id,
    );
    try std.testing.expectEqualStrings("model-1", committed_view.selected_model);
    try std.testing.expectEqual(@as(usize, 1), committed_view.api_keys.len);
    try std.testing.expectEqual(@as(usize, 1), committed_view.models.len);
    try std.testing.expect(runtime.effects.catalog.firstApiKeyId() == null);
    try std.testing.expectEqualStrings(
        "",
        runtime.effects.catalog.ownerAccountId(),
    );
}

test "Account Runtime catalog cancel discards candidate identity and secrets" {
    var wake_context: u8 = 0;
    var runtime = try initRuntimeForTest(&wake_context);
    defer runtime.deinit();
    try commitReadyRestoreForTest(&runtime);

    var refresh = switch (runtime.prepareCommand(.refresh_catalog)) {
        .prepared => |value| value,
        else => return error.TestUnexpectedResult,
    };
    defer refresh.deinit();
    _ = refresh.transition.takeEffect();
    runtime.commit(&refresh);

    try catalog_impl.TestSupport.replaceOwnedSelection(
        &runtime.effects.catalog,
        "account-1",
        .{
            .id = "key-1",
            .name = "Primary",
            .suffix = "1234",
            .protocol = .anthropic_messages,
        },
        "secret-key",
        &.{.{ .id = "model-1", .display_name = "Model 1" }},
    );
    runtime.candidate_public_catalog.replaceRestoredSelection(
        "key-1",
        .anthropic_messages,
        "model-1",
    );
    runtime.candidate_catalog_attempt_id = refresh.attemptId();

    var cancel = switch (runtime.prepareCommand(.cancel_operation)) {
        .prepared => |value| value,
        else => return error.TestUnexpectedResult,
    };
    defer cancel.deinit();
    try std.testing.expect(runtime.admitEffect(&cancel));
    try std.testing.expectEqual(
        state_impl.CatalogIntent.discard_candidate,
        cancel.transition.catalogIntent(),
    );
    runtime.commit(&cancel);
    try std.testing.expect(runtime.candidate_catalog_attempt_id == null);
    try std.testing.expect(runtime.effects.catalog.firstApiKeyId() != null);
    runtime.dispatchCommitted(&cancel);

    try std.testing.expect(!runtime.candidate_public_catalog.hasApiKey("key-1"));
    try std.testing.expect(runtime.effects.catalog.firstApiKeyId() == null);
    try contract.validateView(runtime.view());
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
        testingTransport(),
        TestSupport.loopbackEndpoint(),
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
            .protocol = .anthropic_messages,
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
    var execution = try execution_contract.OwnedConfig.initOwned(
        std.testing.allocator,
        .metask,
        .anthropic_messages,
        try std.testing.allocator.dupe(u8, "model-1"),
        try std.testing.allocator.dupe(
            u8,
            contract.metask_anthropic_messages_url,
        ),
        1,
        try std.testing.allocator.dupe(u8, "secret-key"),
        "fixture-provider",
    );
    var prepared = try TestSupport.prepareReadyRestore(runtime, &execution);
    execution.deinit();
    defer prepared.deinit();
    try std.testing.expect(runtime.admitEffect(&prepared));
    if (prepared.takeExecution()) |execution_value| {
        var committed_execution = execution_value;
        committed_execution.deinit();
    }
    runtime.commit(&prepared);
    runtime.dispatchCommitted(&prepared);
}

fn beginDefaultModelChangeForTest(
    runtime: *Runtime,
    model_id: []const u8,
) !void {
    const account_view = runtime.view();
    var prepared = switch (runtime.prepareCommand(.{
        .select_model = .{
            .selection_id = model_id,
            .expected_catalog_generation = account_view.catalog_generation,
            .expected_execution_generation = account_view.execution_generation,
        },
    })) {
        .prepared => |value| value,
        else => return error.TestUnexpectedResult,
    };
    defer prepared.deinit();
    try std.testing.expect(runtime.admitEffect(&prepared));
    runtime.commit(&prepared);
    runtime.dispatchCommitted(&prepared);
}

fn prepareDefaultModelTest(
    runtime: *Runtime,
    platform: *TestPlatform,
) !void {
    runtime.platform = platform.platform();
    try commitReadyRestoreForTest(runtime);
    catalog_impl.TestSupport.replacePublic(
        &runtime.committed_public_catalog,
        &.{.{
            .id = "key-1",
            .name = "Primary",
            .suffix = "1234",
            .protocol = .anthropic_messages,
        }},
        &.{
            .{ .id = "model-1", .display_name = "Model 1" },
            .{ .id = "model-2", .display_name = "Model 2" },
            .{ .id = "model-third", .display_name = "Third" },
        },
    );
    platform.preference = try .init(
        "account-1",
        "key-1",
        "model-1",
        1,
    );
    runtime.saved_preference = platform.preference;
}

test "default-model outcome unknown commits the re-observed candidate" {
    var wake_context: u8 = 0;
    var runtime = try initRuntimeForTest(&wake_context);
    defer runtime.deinit();
    defer runtime.platform = null;
    var platform: TestPlatform = .{};
    try prepareDefaultModelTest(&runtime, &platform);
    platform.preference_commit_mode = .unknown_after_write;

    try beginDefaultModelChangeForTest(&runtime, "model-2");
    var prepared = switch (runtime.prepareNextCompletion().?) {
        .prepared => |value| value,
        else => return error.TestUnexpectedResult,
    };
    defer prepared.deinit();
    try std.testing.expectEqual(
        contract.AccountFactKind.default_changed,
        prepared.factKind(),
    );
    runtime.commit(&prepared);
    try std.testing.expectEqualStrings("model-2", runtime.view().selected_model);
    try std.testing.expectEqual(@as(u64, 1), runtime.view().execution_generation);
    try std.testing.expectEqualStrings(
        "model-2",
        runtime.saved_preference.?.modelId(),
    );
}

test "default-model outcome unknown rolls back when disk kept the old value" {
    var wake_context: u8 = 0;
    var runtime = try initRuntimeForTest(&wake_context);
    defer runtime.deinit();
    defer runtime.platform = null;
    var platform: TestPlatform = .{};
    try prepareDefaultModelTest(&runtime, &platform);
    platform.preference_commit_mode = .unknown_without_write;

    try beginDefaultModelChangeForTest(&runtime, "model-2");
    var prepared = switch (runtime.prepareNextCompletion().?) {
        .prepared => |value| value,
        else => return error.TestUnexpectedResult,
    };
    defer prepared.deinit();
    runtime.commit(&prepared);
    const account_view = runtime.view();
    try std.testing.expectEqualStrings("model-1", account_view.selected_model);
    try std.testing.expectEqual(
        contract.ErrorCode.credential_store_write_failed,
        account_view.error_code,
    );
    try std.testing.expect(account_view.can_create_task);
}

test "default-model outcome unknown revokes execution on a third disk state" {
    var wake_context: u8 = 0;
    var runtime = try initRuntimeForTest(&wake_context);
    defer runtime.deinit();
    defer runtime.platform = null;
    var platform: TestPlatform = .{};
    try prepareDefaultModelTest(&runtime, &platform);
    platform.preference_commit_mode = .unknown_without_write;

    try beginDefaultModelChangeForTest(&runtime, "model-2");
    platform.preference = try .init(
        "account-1",
        "key-1",
        "model-third",
        1,
    );
    var prepared = switch (runtime.prepareNextCompletion().?) {
        .prepared => |value| value,
        else => return error.TestUnexpectedResult,
    };
    defer prepared.deinit();
    try std.testing.expectEqual(
        state_impl.ExecutionIntent.unchanged,
        prepared.executionIntent(),
    );
    try std.testing.expectEqual(
        state_impl.PreferenceIntent.clear,
        prepared.preferenceIntent(),
    );
    runtime.commit(&prepared);
    const account_view = runtime.view();
    try std.testing.expectEqualStrings("model-1", account_view.selected_model);
    try std.testing.expectEqual(
        contract.ErrorCode.recovery_state_invalid,
        account_view.error_code,
    );
    try std.testing.expect(!account_view.can_create_task);
    try std.testing.expect(runtime.saved_preference == null);
    try std.testing.expect(runtime.savedExecutionGenerationFor(
        "account-1",
        "key-1",
        "model-1",
        0,
    ) == null);
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
        testingTransport(),
        TestSupport.loopbackEndpoint(),
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
        contract.AccountState.signed_out,
        runtime.view().state,
    );
}

test "Account Runtime retries a retained credential before opening OAuth" {
    var wake_context: u8 = 0;
    var runtime = try initRuntimeForTest(&wake_context);
    defer runtime.deinit();
    commitAutomationRestoreForTest(&runtime);
    try runtime.credentials.installStored(
        std.testing.allocator,
        "access",
        "refresh",
        10,
        "account-1",
    );

    var prepared = switch (runtime.prepareCommand(.begin_login)) {
        .prepared => |value| value,
        else => return error.TestUnexpectedResult,
    };
    defer prepared.deinit();
    try std.testing.expect(runtime.admitEffect(&prepared));
    const entry = runtime.effects.queue.take() orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(entry.effect == .refresh_token);
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
        contract.AccountState.signed_out,
        runtime.view().state,
    );
    runtime.commit(&prepared);
    try std.testing.expectEqual(
        contract.AccountState.signed_out,
        runtime.view().state,
    );
    try std.testing.expect(runtime.effects.queue.entry != null);
    runtime.dispatchCommitted(&prepared);
    try std.testing.expect(runtime.effects.queue.entry == null);
}

test "Account Runtime shutdown clears a ready public view" {
    var wake_context: u8 = 0;
    var runtime = try initRuntimeForTest(&wake_context);
    defer runtime.deinit();
    try commitReadyRestoreForTest(&runtime);
    try std.testing.expectEqual(
        contract.CatalogState.ready,
        runtime.view().catalog_state,
    );

    var prepared = runtime.prepareShutdown();
    defer prepared.deinit();
    try std.testing.expect(runtime.admitEffect(&prepared));
    runtime.commit(&prepared);
    runtime.dispatchCommitted(&prepared);
    const view = runtime.view();
    try std.testing.expectEqual(
        contract.AccountState.signed_out,
        view.state,
    );
    try std.testing.expectEqual(contract.CatalogState.unavailable, view.catalog_state);
    try std.testing.expectEqual(@as(usize, 0), view.api_keys.len);
    try std.testing.expectEqual(@as(usize, 0), view.models.len);
    try std.testing.expect(!view.can_create_task);
}
