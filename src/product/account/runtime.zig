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
        if (command == .retry_refresh) return self.prepareRetryRefresh();
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
        return wrapPrepareResult(self.account.prepareTokenRefresh());
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

    pub fn authorizationLease(
        self: *Runtime,
    ) std.mem.Allocator.Error!?contract.OwnedAuthorizationLease {
        self.assertMainThread();
        const identity = self.availableAuthorizationIdentity() orelse return null;
        return self.credentials.authorizationLease(
            self.allocator,
            identity.accountId(),
            self.authorization_generation,
        ) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => unreachable,
        };
    }

    pub fn acceptsAuthorizationGeneration(self: *Runtime, generation: u64) bool {
        self.assertMainThread();
        return generation != 0 and generation == self.authorization_generation and
            self.availableAuthorizationIdentity() != null;
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

    pub fn dispatchCommitted(self: *Runtime, prepared: *Prepared) ?Prepared {
        self.assertMainThread();
        std.debug.assert(!(prepared.schedule_refresh_after_commit and
            prepared.retry_refresh_after_commit));
        const follow_up = if (prepared.schedule_refresh_after_commit)
            self.scheduleRefresh()
        else if (prepared.retry_refresh_after_commit)
            self.scheduleRefreshRetry()
        else
            null;
        if (self.effects.queue.take()) |entry| self.dispatchEffect(entry);
        return follow_up;
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
        const login_failed_with_identity = self.account.currentIdentity() != null and
            !refresh_attempt and completion.payload == .failed;
        const retry_refresh = refresh_attempt and
            completion.payload == .failed and
            completion.payload.failed.error_code != .metask_unauthorized and
            completion.payload.failed.error_code != .credential_store_delete_failed and
            self.account.currentIdentity() != null;
        return switch (self.account.prepareCompletion(completion)) {
            .transition => |transition| .{ .prepared = .{
                .transition = transition,
                .schedule_refresh_after_commit = transition.view().state == .authenticated and
                    (loaded_identity or login_failed_with_identity),
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
                const now = platform.wall_clock.nowUnixSeconds() orelse {
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
                const platform = self.platform orelse {
                    self.publishFailure(attempt_id, .credential_store_read_failed);
                    return;
                };
                const now = platform.wall_clock.nowUnixSeconds() orelse {
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

    fn scheduleRefresh(self: *Runtime) ?Prepared {
        const platform = self.platform orelse
            return self.prepareRefreshScheduleFailure();
        const expires_at = self.credentials.expiresAt() orelse {
            platform.timer.cancel(refresh_timer_id) catch
                return self.prepareRefreshScheduleFailure();
            return null;
        };
        const now = platform.wall_clock.nowUnixSeconds() orelse
            return self.prepareRefreshScheduleFailure();
        const refresh_at = expires_at -| refresh_skew_seconds;
        if (refresh_at <= now)
            return preparedFromState(self.account.prepareTokenRefresh());
        const interval_ns = std.math.mul(
            u64,
            @intCast(refresh_at - now),
            std.time.ns_per_s,
        ) catch std.math.maxInt(u64);
        platform.timer.start(refresh_timer_id, @max(interval_ns, 1), false) catch
            return self.prepareRefreshScheduleFailure();
        return null;
    }

    fn scheduleRefreshRetry(self: *Runtime) ?Prepared {
        const platform = self.platform orelse
            return self.prepareRefreshScheduleFailure();
        platform.timer.start(
            refresh_timer_id,
            refresh_retry_ns,
            false,
        ) catch return self.prepareRefreshScheduleFailure();
        return null;
    }

    fn prepareRetryRefresh(self: *Runtime) PrepareResult {
        if (self.account.view().state != .authenticated or
            self.account.activeAttempt() != null or
            !self.credentials.available())
            return .{ .rejected = .invalid_state };
        const platform = self.platform orelse
            return .{ .prepared = self.prepareRefreshScheduleFailure() };
        const expires_at = self.credentials.expiresAt() orelse
            return .{ .prepared = self.prepareRefreshScheduleFailure() };
        const now = platform.wall_clock.nowUnixSeconds() orelse
            return .{ .prepared = self.prepareRefreshScheduleFailure() };
        if (expires_at -| refresh_skew_seconds <= now)
            return wrapPrepareResult(self.account.prepareTokenRefresh());
        return switch (self.account.prepareRetryRefresh()) {
            .transition => |transition| .{ .prepared = .{
                .transition = transition,
                .schedule_refresh_after_commit = true,
            } },
            .rejected => |error_code| .{ .rejected = error_code },
            .ignored_stale => .ignored_stale,
        };
    }

    fn prepareRefreshScheduleFailure(self: *Runtime) Prepared {
        return preparedFromState(
            self.account.prepareIdleFailure(.refresh_schedule_failed),
        );
    }

    fn availableAuthorizationIdentity(self: *Runtime) ?state_impl.AccountIdentity {
        if (self.account.view().state != .authenticated or
            self.authorization_generation == 0 or
            !self.credentials.available())
            return null;
        const platform = self.platform orelse return null;
        const expires_at = self.credentials.expiresAt() orelse return null;
        const now = platform.wall_clock.nowUnixSeconds() orelse return null;
        if (expires_at <= now) return null;
        const identity = self.account.currentIdentity() orelse return null;
        if (!self.credentials.belongsToPrincipal(identity.accountId())) return null;
        return identity;
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
    const credential_capacity = 4096;

    pub const Platform = struct {
        now_unix_seconds: ?i64 = 100,
        refresh_token: [credential_capacity]u8 = undefined,
        refresh_token_len: ?usize = null,
        credential_read_fails: bool = false,
        credential_write_fails: bool = false,
        credential_delete_fails: bool = false,
        authorization_open_fails: bool = false,
        timer_start_fails: bool = false,
        timer_cancel_fails: bool = false,
        authorization_open_count: usize = 0,
        timer_start_count: usize = 0,
        timer_cancel_count: usize = 0,
        last_timer_id: ?u64 = null,
        last_timer_interval_ns: u64 = 0,

        pub fn ports(self: *Platform) ports_impl.Platform {
            return .{
                .credentials = .{
                    .context = self,
                    .set_refresh_token_fn = setRefreshToken,
                    .get_refresh_token_fn = getRefreshToken,
                    .delete_refresh_token_fn = deleteRefreshToken,
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
                .wall_clock = .{
                    .context = self,
                    .now_unix_seconds_fn = nowUnixSeconds,
                },
            };
        }

        pub fn setStoredRefreshToken(self: *Platform, value: []const u8) !void {
            if (value.len == 0 or value.len > self.refresh_token.len)
                return error.InvalidTestCredential;
            @memcpy(self.refresh_token[0..value.len], value);
            self.refresh_token_len = value.len;
        }

        fn setRefreshToken(
            context: *anyopaque,
            value: []const u8,
        ) credential_store.StoreError!void {
            const self: *Platform = @ptrCast(@alignCast(context));
            if (self.credential_write_fails or value.len > self.refresh_token.len)
                return error.WriteFailed;
            @memcpy(self.refresh_token[0..value.len], value);
            self.refresh_token_len = value.len;
        }

        fn getRefreshToken(
            context: *anyopaque,
            output: []u8,
        ) credential_store.StoreError!?[]const u8 {
            const self: *Platform = @ptrCast(@alignCast(context));
            if (self.credential_read_fails) return error.ReadFailed;
            const len = self.refresh_token_len orelse return null;
            if (len > output.len) return error.ReadFailed;
            @memcpy(output[0..len], self.refresh_token[0..len]);
            return output[0..len];
        }

        fn deleteRefreshToken(context: *anyopaque) credential_store.StoreError!void {
            const self: *Platform = @ptrCast(@alignCast(context));
            if (self.credential_delete_fails) return error.DeleteFailed;
            if (self.refresh_token_len) |len|
                std.crypto.secureZero(u8, self.refresh_token[0..len]);
            self.refresh_token_len = null;
        }

        fn openAuthorizationUrl(context: *anyopaque, _: []const u8) !void {
            const self: *Platform = @ptrCast(@alignCast(context));
            self.authorization_open_count += 1;
            if (self.authorization_open_fails) return error.OpenFailed;
        }

        fn startTimer(
            context: *anyopaque,
            timer_id: u64,
            interval_ns: u64,
            repeats: bool,
        ) !void {
            const self: *Platform = @ptrCast(@alignCast(context));
            std.debug.assert(!repeats);
            self.timer_start_count += 1;
            self.last_timer_id = timer_id;
            self.last_timer_interval_ns = interval_ns;
            if (self.timer_start_fails) return error.TimerStartFailed;
        }

        fn cancelTimer(context: *anyopaque, timer_id: u64) !void {
            const self: *Platform = @ptrCast(@alignCast(context));
            self.timer_cancel_count += 1;
            self.last_timer_id = timer_id;
            if (self.timer_cancel_fails) return error.TimerCancelFailed;
        }

        fn nowUnixSeconds(context: *anyopaque) ?i64 {
            const self: *Platform = @ptrCast(@alignCast(context));
            return self.now_unix_seconds;
        }
    };

    pub const Loopback = struct {
        open_fails: bool = false,
        wait_failure: enum { cancelled, deadline_exceeded } = .cancelled,
        open_count: usize = 0,
        wait_count: usize = 0,
        cancel_count: usize = 0,
        close_count: usize = 0,

        pub fn endpoint(self: *Loopback) loopback_impl.Endpoint {
            return .{
                .context = self,
                .open_fn = open,
                .wait_fn = wait,
                .cancel_fn = cancel,
                .close_fn = close,
            };
        }

        fn open(context: *anyopaque) loopback_impl.ServerError!u16 {
            const self: *Loopback = @ptrCast(@alignCast(context));
            self.open_count += 1;
            if (self.open_fails) return error.BindFailed;
            return 49152;
        }

        fn wait(
            context: *anyopaque,
            _: loopback_impl.RequestSink,
            _: std.Io.Clock.Timestamp,
        ) loopback_impl.ServerError!void {
            const self: *Loopback = @ptrCast(@alignCast(context));
            self.wait_count += 1;
            return switch (self.wait_failure) {
                .cancelled => error.Cancelled,
                .deadline_exceeded => error.DeadlineExceeded,
            };
        }

        fn cancel(context: *anyopaque) void {
            const self: *Loopback = @ptrCast(@alignCast(context));
            self.cancel_count += 1;
        }

        fn close(context: *anyopaque) void {
            const self: *Loopback = @ptrCast(@alignCast(context));
            self.close_count += 1;
        }
    };

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

    pub fn prepareAuthenticatedWithCredentialPrincipal(
        runtime: *Runtime,
        identity_account_id: []const u8,
        credential_account_id: []const u8,
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
            credential_account_id,
        );
        runtime.bumpAuthorizationGeneration();
        return .{ .transition = try state_impl.TestSupport.prepareAuthenticated(
            &runtime.account,
            try state_impl.AccountIdentity.init(identity_account_id, display_name),
        ) };
    }

    pub fn prepareAuthenticatedAndSchedule(
        runtime: *Runtime,
        account_id: []const u8,
        display_name: []const u8,
        access_token: []const u8,
        refresh_token: []const u8,
        expires_at: i64,
    ) !Prepared {
        var prepared = try prepareAuthenticated(
            runtime,
            account_id,
            display_name,
            access_token,
            refresh_token,
            expires_at,
        );
        prepared.schedule_refresh_after_commit = true;
        return prepared;
    }

    pub fn attachPlatform(runtime: *Runtime, platform: *Platform) void {
        std.debug.assert(runtime.platform == null);
        runtime.platform = platform.ports();
    }

    pub fn detachPlatform(runtime: *Runtime) void {
        runtime.platform = null;
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

    pub fn commitBeginLoginWithoutDispatch(runtime: *Runtime) u64 {
        var begin = switch (runtime.prepareCommand(.begin_login)) {
            .prepared => |prepared| prepared,
            else => @panic("test Account cannot begin login"),
        };
        defer begin.deinit();
        _ = begin.transition.takeEffect() orelse
            @panic("test login has no OAuth effect");
        runtime.commit(&begin);
        return runtime.account.activeAttempt() orelse
            @panic("test login has no active attempt");
    }

    pub fn prepareTokensPersisted(runtime: *Runtime) Prepared {
        var completion: state_impl.WorkerCompletion = .{
            .attempt_id = runtime.account.activeAttempt() orelse
                @panic("test Account has no active attempt"),
            .payload = .tokens_persisted,
        };
        return preparedFromState(runtime.account.prepareCompletion(&completion));
    }

    pub fn prepareTokenRefreshWithoutEffect(runtime: *Runtime) Prepared {
        var prepared = switch (runtime.prepareTokenRefresh()) {
            .prepared => |value| value,
            else => @panic("test Account cannot begin token refresh"),
        };
        _ = prepared.transition.takeEffect() orelse
            @panic("test token refresh has no effect");
        return prepared;
    }

    pub fn prepareRefreshRetrySchedule(runtime: *Runtime) Prepared {
        var prepared = preparedFromState(
            runtime.account.prepareIdleFailure(.token_refresh_failed),
        );
        prepared.retry_refresh_after_commit = true;
        return prepared;
    }

    pub fn publishFailure(
        runtime: *Runtime,
        attempt_id: u64,
        error_code: contract.ErrorCode,
    ) void {
        runtime.publishFailure(attempt_id, error_code);
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

const RuntimeTestTransport = struct {
    calls: usize = 0,

    fn port(self: *RuntimeTestTransport) metask_client.Transport {
        return .{ .context = self, .perform_fn = perform };
    }

    fn perform(
        context: *anyopaque,
        _: metask_client.Request,
        _: []u8,
    ) metask_client.TransportError!metask_client.Response {
        const self: *RuntimeTestTransport = @ptrCast(@alignCast(context));
        self.calls += 1;
        return error.NetworkFailed;
    }
};

fn runtimeTestWake(_: *anyopaque) void {}

fn initRuntimeForUnitTest(transport: *RuntimeTestTransport) !Runtime {
    return Runtime.init(
        std.testing.allocator,
        std.testing.io,
        std.Thread.getCurrentId(),
        if (builtin.os.tag == .windows)
            "C:\\metawork-account-runtime-test"
        else
            "/tmp/metawork-account-runtime-test",
        transport.port(),
        TestSupport.loopbackEndpoint(),
        .{ .context = transport, .notify_fn = runtimeTestWake },
    );
}

test "authorization lease requires authenticated matching unexpired credentials" {
    var transport: RuntimeTestTransport = .{};
    var runtime = try initRuntimeForUnitTest(&transport);
    var platform: TestSupport.Platform = .{ .now_unix_seconds = 100 };
    TestSupport.attachPlatform(&runtime, &platform);
    defer {
        TestSupport.detachPlatform(&runtime);
        runtime.deinit();
    }
    var authenticated = try TestSupport.prepareAuthenticated(
        &runtime,
        "account-1",
        "Metask User",
        "access-token",
        "refresh-token",
        101,
    );
    defer authenticated.deinit();
    runtime.commit(&authenticated);

    var lease = (try runtime.authorizationLease()).?;
    const generation = lease.authorization_generation;
    lease.deinit();
    try std.testing.expect(runtime.acceptsAuthorizationGeneration(generation));

    platform.now_unix_seconds = 101;
    try std.testing.expect((try runtime.authorizationLease()) == null);
    try std.testing.expect(!runtime.acceptsAuthorizationGeneration(generation));
}

test "authorization lease rejects authorizing and mismatched principals" {
    var transport: RuntimeTestTransport = .{};
    var runtime = try initRuntimeForUnitTest(&transport);
    var platform: TestSupport.Platform = .{ .now_unix_seconds = 100 };
    TestSupport.attachPlatform(&runtime, &platform);
    defer {
        TestSupport.detachPlatform(&runtime);
        runtime.deinit();
    }
    var authenticated = try TestSupport.prepareAuthenticated(
        &runtime,
        "account-1",
        "Metask User",
        "access-token",
        "refresh-token",
        200,
    );
    defer authenticated.deinit();
    runtime.commit(&authenticated);
    _ = TestSupport.commitBeginLoginWithoutDispatch(&runtime);
    try std.testing.expect((try runtime.authorizationLease()) == null);

    var mismatched_transport: RuntimeTestTransport = .{};
    var mismatched = try initRuntimeForUnitTest(&mismatched_transport);
    var mismatched_platform: TestSupport.Platform = .{ .now_unix_seconds = 100 };
    TestSupport.attachPlatform(&mismatched, &mismatched_platform);
    defer {
        TestSupport.detachPlatform(&mismatched);
        mismatched.deinit();
    }
    var mismatched_authenticated = try TestSupport.prepareAuthenticatedWithCredentialPrincipal(
        &mismatched,
        "account-1",
        "account-2",
        "Metask User",
        "access-token",
        "refresh-token",
        200,
    );
    defer mismatched_authenticated.deinit();
    mismatched.commit(&mismatched_authenticated);
    try std.testing.expect((try mismatched.authorizationLease()) == null);
}

test "healthy refresh window preserves authorization generation" {
    var transport: RuntimeTestTransport = .{};
    var runtime = try initRuntimeForUnitTest(&transport);
    var platform: TestSupport.Platform = .{ .now_unix_seconds = 100 };
    TestSupport.attachPlatform(&runtime, &platform);
    defer {
        TestSupport.detachPlatform(&runtime);
        runtime.deinit();
    }
    var authenticated = try TestSupport.prepareAuthenticated(
        &runtime,
        "account-1",
        "Metask User",
        "access-token",
        "refresh-token",
        150,
    );
    defer authenticated.deinit();
    runtime.commit(&authenticated);
    var before = (try runtime.authorizationLease()).?;
    const generation = before.authorization_generation;
    before.deinit();

    var refreshing = TestSupport.prepareTokenRefreshWithoutEffect(&runtime);
    defer refreshing.deinit();
    runtime.commit(&refreshing);

    var during = (try runtime.authorizationLease()).?;
    defer during.deinit();
    try std.testing.expectEqual(generation, during.authorization_generation);
    try std.testing.expect(runtime.acceptsAuthorizationGeneration(generation));
}

test "retry refresh schedules fresh credentials and refreshes inside skew" {
    var transport: RuntimeTestTransport = .{};
    var runtime = try initRuntimeForUnitTest(&transport);
    var platform: TestSupport.Platform = .{ .now_unix_seconds = 100 };
    TestSupport.attachPlatform(&runtime, &platform);
    defer {
        TestSupport.detachPlatform(&runtime);
        runtime.deinit();
    }
    var authenticated = try TestSupport.prepareAuthenticated(
        &runtime,
        "account-1",
        "Metask User",
        "access-token",
        "refresh-token",
        200,
    );
    defer authenticated.deinit();
    runtime.commit(&authenticated);

    var scheduled = switch (runtime.prepareCommand(.retry_refresh)) {
        .prepared => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(scheduled.attemptId() == null);
    try std.testing.expect(scheduled.schedule_refresh_after_commit);
    scheduled.deinit();

    platform.now_unix_seconds = 150;
    var refresh = switch (runtime.prepareCommand(.retry_refresh)) {
        .prepared => |value| value,
        else => return error.TestUnexpectedResult,
    };
    defer refresh.deinit();
    try std.testing.expect(refresh.attemptId() != null);
    try std.testing.expect(refresh.transition.takeEffect().? == .refresh_token);
}
