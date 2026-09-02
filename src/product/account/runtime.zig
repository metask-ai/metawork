//! Product Account runtime owner.
//!
//! This runtime owns only company identity authorization, OAuth credential
//! rotation, restore, cancellation, and shutdown. Provider catalogs, model
//! selection, source resolution, and their persistence belong to Models.
const std = @import("std");
const builtin = @import("builtin");
const contract = @import("metawork_account_contract");
const state_impl = @import("account_state");
const metask_client = @import("metask_client");
const credential_store = @import("account_credential_store");
const ports_impl = @import("account_ports");
const loopback_impl = @import("account_loopback");
const login_attempt = @import("account_login_attempt");
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
    wake: WakeSink,
    transport: metask_client.Transport,
    loopback_endpoint: loopback_impl.Endpoint,
    queue: EffectQueue = .{},
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
        };
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
        self.wake.notify();
        return true;
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
        self.wake.notify();
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
        self.wake.notify();
    }

    fn takeMailbox(self: *Effects) ?MailboxResult {
        self.lockMailbox();
        defer self.unlockMailbox();
        const result = self.mailbox;
        self.mailbox = null;
        return result;
    }

    fn takeCollision(self: *Effects) bool {
        self.lockMailbox();
        defer self.unlockMailbox();
        const collision = self.mailbox_collision;
        self.mailbox_collision = false;
        return collision;
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
        if (self.takeMailbox()) |value| {
            var stale = value;
            stale.deinit();
        }
        self.publishCompletion(.{
            .attempt_id = attempt_id,
            .payload = .{ .failed = .fromCode(error_code) },
        });
    }

    fn startRefresh(
        self: *Effects,
        attempt_id: u64,
        credential_owner: *const credentials_impl.CredentialOwner,
        now_unix_seconds: i64,
    ) void {
        self.network_attempt.startRefresh(
            self.allocator,
            self.io,
            attempt_id,
            self.transport,
            credential_owner,
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
        credential_owner: *const credentials_impl.CredentialOwner,
    ) void {
        self.network_attempt.startLoadIdentity(
            self.allocator,
            self.io,
            attempt_id,
            self.transport,
            credential_owner,
            self.networkSink(),
        ) catch self.publishCompletion(.{
            .attempt_id = attempt_id,
            .payload = .{ .failed = .fromCode(.local_resource_exhausted) },
        });
    }

    fn cancelAttemptAndDiscard(self: *Effects, attempt_id: u64) void {
        if (self.login_active and self.login_attempt.matches(attempt_id)) {
            self.login_attempt.cancel();
            self.joinLogin();
        } else if (self.network_attempt.matches(attempt_id)) {
            self.network_attempt.cancel();
            self.network_attempt.join();
            self.network_attempt.deinit();
        }
        if (self.takeMailbox()) |value| {
            var discarded = value;
            if (discarded.attemptId() != attempt_id)
                @panic("Account cancel discarded another attempt");
            discarded.deinit();
        }
        _ = self.takeCollision();
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
    }

    fn deinit(self: *Effects) void {
        self.cancelJoinAndDiscard();
        std.debug.assert(self.queue.entry == null);
        self.* = undefined;
    }

    fn lockMailbox(self: *Effects) void {
        self.mailbox_mutex.lockUncancelable(self.io);
    }

    fn unlockMailbox(self: *Effects) void {
        self.mailbox_mutex.unlock(self.io);
    }
};

pub const Prepared = struct {
    transition: state_impl.PreparedTransition,
    refresh_after_commit: bool = false,
    schedule_refresh_after_commit: bool = false,
    retry_refresh_after_commit: bool = false,

    pub fn factKind(self: *const Prepared) contract.AccountFactKind {
        return self.transition.factKind();
    }

    pub fn attemptId(self: *const Prepared) ?u64 {
        return self.transition.attempt_id;
    }

    pub fn finishesAttempt(self: *const Prepared) bool {
        return self.transition.finishesAttempt();
    }

    pub fn deinit(self: *Prepared) void {
        self.transition.deinit();
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

pub const InitError = error{AccountDirectoryUnavailable};

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    main_thread_id: std.Thread.Id,
    account: state_impl.Account = .initRestoring(),
    effects: Effects,
    platform: ?ports_impl.Platform = null,
    credentials: credentials_impl.CredentialOwner = .{},
    authorization_generation: u64 = 0,

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
        return .{
            .allocator = allocator,
            .io = io,
            .main_thread_id = main_thread_id,
            .effects = .init(allocator, io, transport, loopback_endpoint, wake),
        };
    }

    pub fn deinit(self: *Runtime) void {
        self.assertMainThread();
        std.debug.assert(self.platform == null);
        self.effects.deinit();
        self.credentials.deinit();
        self.* = undefined;
    }

    pub fn prepareStart(self: *Runtime, platform: ports_impl.Platform) Prepared {
        self.assertMainThread();
        std.debug.assert(self.platform == null);
        self.platform = platform;
        return self.prepareRestore();
    }

    pub fn prepareAutomationStart(self: *Runtime) Prepared {
        self.assertMainThread();
        var restored: state_impl.RestoreResult = .{ .signed_out = {} };
        return preparedFromState(self.account.prepareRestore(&restored));
    }

    pub fn prepareStartUnavailable(self: *Runtime) Prepared {
        self.assertMainThread();
        return self.preparedSignedOutRestoreFailure(.credential_store_read_failed);
    }

    pub fn prepareCommand(
        self: *Runtime,
        command: contract.AccountCommand,
    ) PrepareResult {
        self.assertMainThread();
        if (command == .begin_login and
            self.account.view().state == .signed_out and
            self.credentials.refreshAvailable())
            return wrapPrepareResult(self.account.prepareRestoredTokenRefresh());
        return wrapPrepareResult(self.account.prepareCommand(command));
    }

    pub fn prepareTokenRefresh(self: *Runtime) PrepareResult {
        self.assertMainThread();
        return wrapPrepareResult(self.account.prepareTokenRefresh());
    }

    pub fn prepareTimer(self: *Runtime, timer_id: u64) ?PrepareResult {
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

    pub fn preparedContinuesActiveAttempt(
        self: *const Runtime,
        prepared: *const Prepared,
    ) bool {
        const attempt_id = prepared.attemptId() orelse return false;
        return self.account.activeAttempt() == attempt_id;
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
                    break :result self.prepareFailure(entry.attempt_id, .account_operation_failed);
                break :result switch (entry.result) {
                    .authorized => |*tokens| self.prepareAuthorizedLogin(entry.attempt_id, tokens),
                    .failed => |failure| self.prepareFailureValue(entry.attempt_id, failure),
                    .consumed => @panic("Account login mailbox contains consumed result"),
                };
            },
            .refresh => |*entry| result: {
                self.effects.joinNetwork(entry.attempt_id);
                if (self.account.activeAttempt() != entry.attempt_id)
                    break :result .ignored_stale;
                if (collision)
                    break :result self.prepareFailure(entry.attempt_id, .account_operation_failed);
                break :result self.prepareRefreshedTokens(entry.attempt_id, &entry.rotation);
            },
            .completion => |*completion| self.prepareWorkerCompletion(completion, collision),
        };
    }

    pub fn view(self: *Runtime) contract.AccountView {
        self.assertMainThread();
        const result = self.account.view();
        contract.validateView(result) catch
            @panic("Account Runtime produced an invalid canonical AccountView");
        return result;
    }

    pub fn authorizationLease(self: *Runtime) ?contract.OwnedAuthorizationLease {
        self.assertMainThread();
        const identity = self.account.currentIdentity() orelse return null;
        if (self.authorization_generation == 0) return null;
        return self.credentials.authorizationLease(
            self.allocator,
            identity.accountId(),
            self.authorization_generation,
        ) catch null;
    }

    pub fn acceptsAuthorizationGeneration(self: *const Runtime, generation: u64) bool {
        self.assertMainThread();
        return generation != 0 and generation == self.authorization_generation and
            self.account.currentIdentity() != null and self.credentials.available();
    }

    pub fn preparedFact(
        self: *Runtime,
        prepared: *const Prepared,
    ) contract.AccountFact {
        self.assertMainThread();
        const fact: contract.AccountFact = .{
            .kind = prepared.factKind(),
            .view = prepared.transition.view(),
        };
        contract.validateFact(fact) catch
            @panic("Account Runtime prepared an invalid canonical AccountFact");
        return fact;
    }

    pub fn admitEffect(self: *Runtime, prepared: *Prepared) bool {
        self.assertMainThread();
        if (prepared.transition.takeEffect()) |effect|
            return self.effects.queue.sink().submit(prepared.transition.attempt_id, effect);
        return true;
    }

    pub fn commit(self: *Runtime, prepared: *Prepared) void {
        self.assertMainThread();
        prepared.transition.commit(&self.account);
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
        if (prepared.schedule_refresh_after_commit) self.scheduleRefresh();
        if (prepared.retry_refresh_after_commit) {
            if (self.platform) |platform|
                platform.timer.start(
                    refresh_timer_id,
                    refresh_retry_ns,
                    false,
                ) catch {};
        }
        if (self.effects.queue.take()) |entry| self.dispatchEffect(entry);
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
        const refresh_attempt = self.account.refreshInFlight();
        self.effects.joinNetwork(completion.attempt_id);
        if (collision and self.account.activeAttempt() == completion.attempt_id) {
            completion.deinit();
            completion.* = .{
                .attempt_id = completion.attempt_id,
                .payload = .{ .failed = .fromCode(.account_operation_failed) },
            };
        }
        if (completion.payload == .failed and
            completion.payload.failed.error_code == .metask_unauthorized and
            self.account.credentialValidationInFlight())
            completion.payload.failed.error_code = self.deleteInvalidCredential();

        const loaded_identity = completion.payload == .identity_loaded;
        const retry_refresh = refresh_attempt and
            completion.payload == .failed and
            completion.payload.failed.error_code != .metask_unauthorized and
            completion.payload.failed.error_code != .credential_store_delete_failed and
            self.account.currentIdentity() != null;
        return switch (self.account.prepareCompletion(completion)) {
            .transition => |transition| .{ .prepared = .{
                .transition = transition,
                .schedule_refresh_after_commit = loaded_identity and
                    transition.view().state == .authenticated,
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
        self.clearCredentials();
        self.cancelRefreshTimer();
        return result;
    }

    fn prepareAuthorizedLogin(
        self: *Runtime,
        attempt_id: u64,
        tokens: *metask_client.AuthorizationResult,
    ) PrepareResult {
        const platform = self.platform orelse
            return self.prepareFailure(attempt_id, .credential_store_write_failed);
        credential_store.commitRefresh(platform.credentials, &tokens.refresh_token) catch |err|
            return self.prepareFailure(attempt_id, accountStoreError(err));
        self.credentials.replace(tokens);
        self.bumpAuthorizationGeneration();
        var completion: state_impl.WorkerCompletion = .{
            .attempt_id = attempt_id,
            .payload = .tokens_persisted,
        };
        defer completion.deinit();
        return wrapPrepareResult(self.account.prepareCompletion(&completion));
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
        const platform = self.platform orelse
            return self.prepareFailure(attempt_id, .credential_store_write_failed);
        credential_store.commitRefresh(
            platform.credentials,
            &rotation.persistenceInput().refresh_token,
        ) catch |err| return self.prepareFailure(attempt_id, accountStoreError(err));
        self.credentials.replaceRotation(rotation);
        self.bumpAuthorizationGeneration();
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
        return self.prepareFailureValue(attempt_id, .fromCode(error_code));
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
        switch (entry.effect) {
            .begin_oauth => {
                const attempt_id = entry.attempt_id orelse
                    @panic("OAuth effect has no attempt");
                const platform = self.platform orelse {
                    self.publishFailure(attempt_id, .credential_store_read_failed);
                    return;
                };
                const now = wallUnixSeconds(self.io) orelse {
                    self.publishFailure(attempt_id, .account_operation_failed);
                    return;
                };
                self.effects.startLogin(attempt_id, platform.authorization_url, now);
            },
            .refresh_token => {
                const attempt_id = entry.attempt_id orelse
                    @panic("token refresh effect has no attempt");
                if (!self.credentials.refreshAvailable()) {
                    self.publishFailure(attempt_id, .credential_store_read_failed);
                    return;
                }
                const now = wallUnixSeconds(self.io) orelse {
                    self.publishFailure(attempt_id, .account_operation_failed);
                    return;
                };
                self.effects.startRefresh(attempt_id, &self.credentials, now);
            },
            .load_identity => {
                const attempt_id = entry.attempt_id orelse
                    @panic("identity effect has no attempt");
                if (!self.credentials.available()) {
                    self.publishFailure(attempt_id, .credential_store_read_failed);
                    return;
                }
                self.effects.startLoadIdentity(attempt_id, &self.credentials);
            },
            .cancel_attempt => |attempt_id| self.effects.cancelAttemptAndDiscard(attempt_id),
            .delete_credential => self.persistSignedOut(entry.attempt_id orelse
                @panic("logout effect has no attempt")),
            .shutdown => {
                self.cancelRefreshTimer();
                self.effects.cancelJoinAndDiscard();
                self.platform = null;
            },
        }
    }

    fn publishFailure(self: *Runtime, attempt_id: u64, error_code: contract.ErrorCode) void {
        self.effects.publishCompletion(.{
            .attempt_id = attempt_id,
            .payload = .{ .failed = .fromCode(error_code) },
        });
    }

    fn persistSignedOut(self: *Runtime, attempt_id: u64) void {
        const platform = self.platform orelse {
            self.publishFailure(attempt_id, .credential_store_write_failed);
            return;
        };
        credential_store.commitSignedOut(platform.credentials) catch |err| {
            self.publishFailure(attempt_id, accountStoreError(err));
            return;
        };
        self.clearCredentials();
        self.cancelRefreshTimer();
        self.effects.publishCompletion(.{
            .attempt_id = attempt_id,
            .payload = .logged_out,
        });
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
        platform.timer.start(refresh_timer_id, @max(interval_ns, 1), false) catch {};
    }

    fn clearCredentials(self: *Runtime) void {
        self.credentials.clear();
        self.bumpAuthorizationGeneration();
    }

    fn bumpAuthorizationGeneration(self: *Runtime) void {
        self.authorization_generation +%= 1;
        if (self.authorization_generation == 0) self.authorization_generation = 1;
    }

    fn prepareRestore(self: *Runtime) Prepared {
        var restored = credential_store.restore(
            self.allocator,
            self.platform.?.credentials,
        ) catch |err| {
            self.clearCredentials();
            return self.preparedSignedOutRestoreFailure(accountRestoreError(err));
        };
        defer restored.deinit();
        return switch (restored) {
            .signed_out => blk: {
                self.clearCredentials();
                var value: state_impl.RestoreResult = .{ .signed_out = {} };
                break :blk preparedFromState(self.account.prepareRestore(&value));
            },
            .account => |*account| blk: {
                self.credentials.installRefreshToken(&account.refresh_token);
                var value: state_impl.RestoreResult = .{ .refresh_only = {} };
                var prepared = preparedFromState(self.account.prepareRestore(&value));
                prepared.refresh_after_commit = true;
                break :blk prepared;
            },
        };
    }

    fn preparedSignedOutRestoreFailure(
        self: *Runtime,
        error_code: contract.ErrorCode,
    ) Prepared {
        return preparedFromState(self.account.prepareSignedOutRestoreFailure(.fromCode(error_code)));
    }

    fn assertMainThread(self: *const Runtime) void {
        std.debug.assert(std.Thread.getCurrentId() == self.main_thread_id);
    }
};

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

    pub fn prepareAuthenticated(
        runtime: *Runtime,
        account_id: []const u8,
        display_name: []const u8,
        access_token: []const u8,
        refresh_token: []const u8,
        expires_at: i64,
    ) !Prepared {
        try runtime.credentials.installStored(
            runtime.allocator,
            access_token,
            refresh_token,
            expires_at,
            account_id,
        );
        runtime.bumpAuthorizationGeneration();
        return .{ .transition = try state_impl.TestSupport.prepareAuthenticated(
            &runtime.account,
            try state_impl.AccountIdentity.init(account_id, display_name),
        ) };
    }

    pub fn prepareLoggedOutAfterExternalCommit(runtime: *Runtime) Prepared {
        var begin = switch (runtime.prepareCommand(.logout)) {
            .prepared => |prepared| prepared,
            else => @panic("test Account cannot begin logout"),
        };
        defer begin.deinit();
        _ = begin.transition.takeEffect() orelse
            @panic("test logout has no persistence effect");
        runtime.commit(&begin);
        runtime.clearCredentials();
        var completion: state_impl.WorkerCompletion = .{
            .attempt_id = runtime.account.activeAttempt() orelse
                @panic("test logout has no active attempt"),
            .payload = .logged_out,
        };
        return preparedFromState(runtime.account.prepareCompletion(&completion));
    }

    pub fn occupyEffectQueue(runtime: *Runtime) void {
        std.debug.assert(runtime.effects.queue.entry == null);
        runtime.effects.queue.entry = .{ .attempt_id = 99, .effect = .begin_oauth };
    }

    pub fn clearEffectQueue(runtime: *Runtime) void {
        _ = runtime.effects.queue.take();
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
} else struct {};

fn wrapPrepareResult(result: state_impl.PrepareResult) PrepareResult {
    return switch (result) {
        .transition => |transition| .{ .prepared = .{ .transition = transition } },
        .rejected => |error_code| .{ .rejected = error_code },
        .ignored_stale => .ignored_stale,
    };
}

fn preparedFromState(result: state_impl.PrepareResult) Prepared {
    return switch (result) {
        .transition => |transition| .{ .transition = transition },
        .rejected, .ignored_stale => @panic("Account runtime lost its required transition"),
    };
}

fn accountRestoreError(err: anyerror) contract.ErrorCode {
    return switch (err) {
        error.ReadFailed => .credential_store_read_failed,
        error.DeleteFailed => .credential_store_delete_failed,
        error.WriteFailed => .account_operation_failed,
        else => .recovery_state_invalid,
    };
}

fn accountStoreError(err: anyerror) contract.ErrorCode {
    return switch (err) {
        error.ReadFailed => .credential_store_read_failed,
        error.WriteFailed => .credential_store_write_failed,
        error.DeleteFailed => .credential_store_delete_failed,
        else => .account_operation_failed,
    };
}

fn loginStartError(err: login_attempt.StartError) contract.ErrorCode {
    return switch (err) {
        error.BindFailed => .oauth_bind_failed,
        error.AuthorizationUrlFailed, error.RandomFailed => .oauth_callback_rejected,
        error.ThreadSpawnFailed, error.AlreadyStarted, error.InvalidAttempt => .local_resource_exhausted,
    };
}

fn wallUnixSeconds(io: std.Io) ?i64 {
    const nanoseconds = std.Io.Timestamp.now(io, .real).nanoseconds;
    if (nanoseconds < 0) return null;
    const seconds = @divFloor(nanoseconds, std.time.ns_per_s);
    if (seconds > std.math.maxInt(i64)) return null;
    return @intCast(seconds);
}
