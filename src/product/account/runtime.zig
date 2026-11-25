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
const summary_impl = @import("account_summary");

/// One repeating timer while a renewal is ahead. It only wakes Account; the
/// clocks decide what is due, and every event-loop turn asks them too.
const beat_timer_id: u64 = 0x4d57_4143_4354_5246;
const beat_interval_ns: u64 = 30 * std.time.ns_per_s;
/// A beat one whole interval late still renews a minute before expiry.
const renewal_lead_seconds: i64 = 90;
/// Keeps a token with a very short lifetime from renewing back to back.
const renewal_min_age_seconds: i64 = 30;
const renewal_retry_seconds: i64 = 30;
/// A stored login is confirmed again and again, ever less often, until it is
/// confirmed or disproved, or someone signs in instead.
const confirm_delays_seconds = [_]i64{ 30, 60, 120, 300 };

/// A moment on both clocks. Whichever reaches it first decides: the wall
/// clock can be set back, and only it survives a restart of the machine.
const Moment = struct {
    wall: ?i64,
    boot: i64,

    fn reached(self: Moment, platform: ports_impl.Platform) bool {
        if (self.boot <= platform.boot_clock.nowSeconds()) return true;
        const at = self.wall orelse return false;
        return at <= (platform.wall_clock.nowUnixSeconds() orelse return false);
    }
};

const SummaryJob = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    transport: metask_client.Transport,
    wake: WakeSink,
    attempt_id: u64,
    synced_at_unix_ms: summary_impl.Decimal,
    history_range: ?summary_impl.HistoryRange,
    lease: contract.OwnedAuthorizationLease,
    lease_active: bool = true,
    cancellation: metask_client.Cancellation,
    completion: ?summary_impl.Completion = null,
    finished: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        transport: metask_client.Transport,
        wake: WakeSink,
        attempt_id: u64,
        synced_at_unix_ms: summary_impl.Decimal,
        history_range: ?summary_impl.HistoryRange,
        lease: *contract.OwnedAuthorizationLease,
    ) std.mem.Allocator.Error!*SummaryJob {
        const self = try allocator.create(SummaryJob);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .transport = transport,
            .wake = wake,
            .attempt_id = attempt_id,
            .synced_at_unix_ms = synced_at_unix_ms,
            .history_range = history_range,
            .lease = lease.take(),
            .cancellation = metask_client.Cancellation.init(io),
        };
        return self;
    }

    fn start(self: *SummaryJob) std.Thread.SpawnError!void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn run(self: *SummaryJob) void {
        defer {
            self.lease.deinit();
            self.lease_active = false;
            self.finished.store(true, .release);
            self.wake.notify();
        }
        var completion: summary_impl.Completion = .{
            .attempt_id = self.attempt_id,
            .principal_ref_len = self.lease.principal_ref.len,
            .synced_at_unix_ms = self.synced_at_unix_ms,
            .history = .not_requested,
        };
        @memcpy(
            completion.principal_ref[0..self.lease.principal_ref.len],
            self.lease.principal_ref,
        );
        const deadline = std.Io.Clock.Timestamp.fromNow(self.io, .{
            .raw = .fromSeconds(30),
            .clock = .boot,
        });
        const control: metask_client.RequestControl = .{
            .cancellation = &self.cancellation,
            .deadline = deadline,
        };
        completion.history = if (self.history_range) |range|
            if (metask_client.fetchUsageHistory(
                self.transport,
                self.lease.access_token,
                self.lease.principal_ref,
                range,
                control,
            )) |history|
                .{ .succeeded = history }
            else |err|
                .{ .failed = metask_client.errorCode(err) }
        else
            .{ .failed = .account_operation_failed };
        self.completion = completion;
    }

    fn cancel(self: *SummaryJob) void {
        self.cancellation.cancel();
    }

    fn join(self: *SummaryJob) void {
        const thread = self.thread orelse return;
        thread.join();
        self.thread = null;
    }

    fn deinit(self: *SummaryJob) void {
        std.debug.assert(self.thread == null);
        if (self.lease_active) self.lease.deinit();
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }
};

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
        login_exchange: ?login_attempt.CallbackExchangeInput = null,

        fn deinit(self: *Entry) void {
            if (self.login_exchange) |*input| input.deinit();
            self.login_exchange = null;
        }
    };

    fn submit(
        self: *EffectQueue,
        attempt_id: ?u64,
        effect: state_impl.Effect,
        login_exchange: *?login_attempt.CallbackExchangeInput,
    ) bool {
        std.debug.assert((effect == .exchange_login) == (login_exchange.* != null));
        if (self.entry != null) return false;
        self.entry = .{
            .attempt_id = attempt_id,
            .effect = effect,
            .login_exchange = if (login_exchange.*) |*input| input.take() else null,
        };
        login_exchange.* = null;
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
        login_callback: struct {
            attempt_id: u64,
            result: login_attempt.WorkerResult,
        },
        login_exchange: struct {
            attempt_id: u64,
            tokens: metask_client.AuthorizationResult,
        },
        refresh: struct {
            attempt_id: u64,
            rotation: credentials_impl.CredentialRotation,
        },
        completion: state_impl.WorkerCompletion,

        fn deinit(self: *MailboxResult) void {
            switch (self.*) {
                .login_callback => |*entry| entry.result.deinit(),
                .login_exchange => |*entry| entry.tokens.deinit(),
                .refresh => |*entry| entry.rotation.deinit(),
                .completion => |*completion| completion.deinit(),
            }
        }

        fn attemptId(self: *const MailboxResult) u64 {
            return switch (self.*) {
                .login_callback => |entry| entry.attempt_id,
                .login_exchange => |entry| entry.attempt_id,
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
        self.mailbox = .{ .login_callback = .{
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
            .login => |tokens| .{ .login_exchange = .{
                .attempt_id = attempt_id,
                .tokens = tokens,
            } },
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
    ) void {
        std.debug.assert(!self.login_active);
        self.login_attempt.start(
            self.allocator,
            self.io,
            self.loopback_endpoint,
            attempt_id,
            self.loginSink(),
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

    fn startLoginExchange(
        self: *Effects,
        attempt_id: u64,
        input: *login_attempt.CallbackExchangeInput,
        now_unix_seconds: i64,
    ) void {
        self.network_attempt.startLoginExchange(
            self.allocator,
            self.io,
            attempt_id,
            self.transport,
            input,
            self.networkSink(),
            now_unix_seconds,
        ) catch self.publishCompletion(.{
            .attempt_id = attempt_id,
            .payload = .{ .failed = .fromCode(.local_resource_exhausted) },
        });
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
            .payload = .{ .failed = .{ .error_code = .local_resource_exhausted, .refresh_not_consumed = true } },
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
    login_exchange: ?login_attempt.CallbackExchangeInput = null,
    refresh_after_commit: bool = false,
    /// What the commit makes of the next renewal.
    renewal: enum { keep, token, retry } = .keep,

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
        if (self.login_exchange) |*input| input.deinit();
        self.login_exchange = null;
        self.transition.deinit();
        self.refresh_after_commit = false;
    }
};

pub const AttemptDisposition = enum {
    starts,
    continues,
    finishes,
    no_attempt,
};

pub const PrepareResult = union(enum) {
    prepared: Prepared,
    rejected: contract.ErrorCode,
    ignored_stale,
};

pub const SummaryRefreshResult = struct {
    result: contract.AccountCommandResult,
    changed: bool,
};

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    main_thread_id: std.Thread.Id,
    account: state_impl.Account = .initRestoring(),
    effects: Effects,
    platform: ?ports_impl.Platform = null,
    credentials: credentials_impl.CredentialOwner = .{},
    authorization_generation: u64 = 0,
    summary: summary_impl.State = .{},
    summary_job: ?*SummaryJob = null,
    /// The credential generation the summary was last fetched with.
    summary_generation: u64 = 0,
    refresh_blocked: bool = false,
    /// The clocks when the current token request was issued.
    token_requested: struct { wall: i64, boot: i64 } = .{ .wall = 0, .boot = 0 },
    /// When the installed access token is over and when it is renewed. Set and
    /// cleared with the token.
    token_times: ?struct { expires: Moment, renews: Moment } = null,
    /// When the next renewal is due. Null keeps every automatic one off.
    renew_at: ?Moment = null,
    beat_running: bool = false,
    confirm_failures: usize = 0,
    confirm_ended_boot: i64 = 0,
    /// Advances each time a refresh attempt finishes, whatever its outcome.
    renewal_epoch: u64 = 0,
    stopping: bool = false,
    request_binding: ?struct { attempt_id: u64, generation: u64, digest: [32]u8 } = null,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        main_thread_id: std.Thread.Id,
        transport: metask_client.Transport,
        loopback_endpoint: loopback_impl.Endpoint,
        wake: WakeSink,
    ) Runtime {
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
        self.cancelSummaryJob();
        self.effects.deinit();
        self.credentials.deinit();
        if (self.request_binding) |*binding| std.crypto.secureZero(u8, &binding.digest);
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
        if (self.stopping) return .{ .rejected = .invalid_state };
        if (command == .retry_refresh) return self.prepareRetryRefresh();
        if (command == .refresh_summary) return .{ .rejected = .invalid_state };
        return wrapPrepareResult(self.account.prepareCommand(command));
    }

    pub fn prepareTokenRefresh(self: *Runtime) PrepareResult {
        self.assertMainThread();
        if (self.stopping or self.refresh_blocked) return .{ .rejected = .invalid_state };
        return wrapPrepareResult(self.account.prepareTokenRefresh());
    }

    pub fn ownsTimer(timer_id: u64) bool {
        return timer_id == beat_timer_id;
    }

    /// What the clocks ask of Account now. Every wake may call it: it commits
    /// nothing itself, and answers null until something is due.
    pub fn prepareDue(self: *Runtime) ?Prepared {
        self.assertMainThread();
        const renew_at = self.renew_at orelse return null;
        const platform = self.platform orelse return null;
        if (self.stopping) return null;
        const beating = self.keepBeat(platform);
        if (self.account.activeAttempt() != null) return null;
        // Its own failure is on display already, and unlike a renewal it is
        // waited for even while no clock reads.
        if (self.account.confirming())
            return if (renew_at.reached(platform)) preparedFromState(self.prepareConfirmation(platform)) else null;
        std.debug.assert(self.account.view().state == .authenticated);
        const reported = self.account.view().error_code == .refresh_schedule_failed;
        // A blocked session keeps its own failure, which no retry can answer.
        if (!beating and !reported and !self.refresh_blocked)
            return preparedFromState(self.account.prepareRefreshScheduleFailure());
        if (beating and reported) return preparedFromState(self.account.prepareRetryRefresh());
        // Without a wall clock no request can be dated, so none is made.
        if (!renew_at.reached(platform) or platform.wall_clock.nowUnixSeconds() == null) return null;
        if (!self.refresh_blocked) return preparedFromState(self.account.prepareTokenRefresh());
        // This session can never be renewed; it ends as a restart ends it.
        self.clearCredentials();
        return preparedFromState(self.account.prepareSessionLost(.fromCode(.token_refresh_failed)));
    }

    /// Someone is there for the result: the next confirmation comes as early
    /// as a first failure would allow, and backs off from there again.
    pub fn expedite(self: *Runtime) void {
        self.assertMainThread();
        if (!self.account.confirming()) return;
        const renew_at = if (self.renew_at) |*value| value else return;
        self.confirm_failures = 0;
        renew_at.boot = @min(renew_at.boot, self.confirm_ended_boot +| confirm_delays_seconds[0]);
    }

    fn prepareConfirmation(self: *Runtime, platform: ports_impl.Platform) state_impl.PrepareResult {
        // An exchanged token is not exchanged again for an identity alone.
        if (self.token_times) |times| if (!times.renews.reached(platform))
            return self.account.prepareRestoredIdentity();
        return self.account.prepareRestoredTokenRefresh();
    }

    /// Starts the beat unless it runs. The event loop also asks what is due,
    /// so a beat that cannot start delays a renewal without stopping it.
    fn keepBeat(self: *Runtime, platform: ports_impl.Platform) bool {
        if (!self.beat_running) {
            platform.timer.start(beat_timer_id, beat_interval_ns, true) catch return false;
            self.beat_running = true;
        }
        return true;
    }

    /// No renewal is ahead. The only place that stops the beat.
    fn clearRenewal(self: *Runtime) void {
        self.renew_at = null;
        if (!self.beat_running) return;
        self.beat_running = false;
        const platform = self.platform orelse return;
        platform.timer.cancel(beat_timer_id) catch {};
    }

    pub fn prepareRestoredRefresh(self: *Runtime) Prepared {
        self.assertMainThread();
        return preparedFromState(self.account.prepareRestoredTokenRefresh());
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

    pub fn attemptDisposition(
        self: *const Runtime,
        prepared: *const Prepared,
    ) AttemptDisposition {
        const current = self.account.activeAttempt();
        const next = prepared.transition.nextAttemptId();
        const prepared_attempt = prepared.attemptId();
        return if (current == null and next == null)
            .no_attempt
        else if (current == null and next != null and prepared_attempt == next)
            .starts
        else if (current != null and next == current and prepared_attempt == current)
            .continues
        else if (current != null and next == null and prepared_attempt == current)
            .finishes
        else
            unreachable;
    }

    pub fn discardQueuedEffectForShutdown(self: *Runtime) void {
        self.assertMainThread();
        if (self.effects.queue.take()) |entry_value| {
            var entry = entry_value;
            entry.deinit();
        }
    }

    pub fn stopAdmission(self: *Runtime) void {
        self.assertMainThread();
        if (self.stopping) return;
        self.stopping = true;
        self.clearRenewal();
        _ = self.clearSummary();
    }

    pub fn prepareShutdown(self: *Runtime) Prepared {
        self.assertMainThread();
        self.stopAdmission();
        self.discardQueuedEffectForShutdown();
        // Refresh keeps its original network deadline. Join before taking the
        // mailbox so a complete rotation is saved once while ports are alive.
        if (self.effects.network_attempt.started and self.effects.network_attempt.kind == .refresh) {
            self.effects.network_attempt.join();
            if (self.prepareNextCompletion()) |result| switch (result) {
                .prepared => |value| {
                    var observed = value;
                    // Persistence is already settled; never admit Userinfo or
                    // commit a second identity/terminal fact while closing.
                    observed.deinit();
                },
                .rejected, .ignored_stale => {},
            };
        }
        return .{ .transition = self.account.prepareShutdown() };
    }

    pub fn prepareNextCompletion(self: *Runtime) ?PrepareResult {
        self.assertMainThread();
        const mailbox_value = self.effects.takeMailbox() orelse return null;
        var mailbox = mailbox_value;
        defer mailbox.deinit();
        const collision = self.effects.takeCollision();
        return switch (mailbox) {
            .login_callback => |*entry| result: {
                self.effects.joinLogin();
                if (self.account.activeAttempt() != entry.attempt_id)
                    break :result .ignored_stale;
                if (collision)
                    break :result self.prepareFailure(entry.attempt_id, .account_operation_failed);
                break :result switch (entry.result) {
                    .exchange => |*input| self.prepareLoginExchange(entry.attempt_id, input),
                    .failed => |failure| self.prepareFailureValue(entry.attempt_id, failure),
                    .consumed => @panic("Account login mailbox contains consumed result"),
                };
            },
            .login_exchange => |*entry| result: {
                self.effects.joinNetwork(entry.attempt_id);
                if (self.account.activeAttempt() != entry.attempt_id)
                    break :result .ignored_stale;
                if (collision)
                    break :result self.prepareFailure(entry.attempt_id, .account_operation_failed);
                break :result self.prepareAuthorizedLogin(entry.attempt_id, &entry.tokens);
            },
            .refresh => |*entry| result: {
                self.effects.joinNetwork(entry.attempt_id);
                if (!self.matchesRequestBinding(entry.attempt_id))
                    break :result .ignored_stale;
                if (collision)
                    break :result self.prepareRenewalFailure(entry.attempt_id, .account_operation_failed);
                break :result self.prepareRefreshedTokens(entry.attempt_id, &entry.rotation);
            },
            .completion => |*completion| self.prepareWorkerCompletion(completion, collision),
        };
    }

    pub fn view(self: *Runtime) contract.AccountView {
        self.assertMainThread();
        var result = self.account.view();
        if (result.state == .authenticated) result.summary = self.summary.view();
        contract.validateView(result) catch
            @panic("Account Runtime produced an invalid canonical AccountView");
        return result;
    }

    pub fn summaryFact(self: *Runtime) contract.AccountFact {
        self.assertMainThread();
        return .{ .kind = .summary_changed, .view = self.view() };
    }

    pub fn refreshSummary(self: *Runtime) SummaryRefreshResult {
        self.assertMainThread();
        if (self.stopping) return .{ .result = .rejected(.invalid_state), .changed = false };
        if (self.summary_job != null)
            return .{ .result = .rejected(.operation_in_progress), .changed = false };
        var lease = (self.credential() catch
            return .{ .result = .rejected(.local_resource_exhausted), .changed = false }) orelse
            return .{ .result = .rejected(.invalid_state), .changed = false };
        defer lease.deinit();
        return self.startSummaryJob(&lease);
    }

    pub fn openRechargePage(self: *Runtime) contract.AccountCommandResult {
        self.assertMainThread();
        if (self.account.view().state != .authenticated)
            return .rejected(.invalid_state);
        const platform = self.platform orelse
            return .rejected(.metask_platform_unsupported);
        platform.recharge_page.open() catch
            return .rejected(.account_operation_failed);
        return .acceptedAttempt(null);
    }

    /// The summary belongs to the account. Each credential it was not yet
    /// fetched with fetches it again behind what is shown; true when changed.
    pub fn reconcileSummary(self: *Runtime) bool {
        self.assertMainThread();
        if (self.stopping) return false;
        const current = switch (self.authorization()) {
            .checking, .signed_out, .authorizing => return self.clearSummary(),
            // Still the same account; its next credential fetches again.
            .recovering, .stalled => return false,
            .available => |value| value,
        };
        if (self.summary.belongsTo(current.account_id)) {
            if (self.summary_job != null or current.generation == self.summary_generation) return false;
        } else _ = self.clearSummary();
        var lease = (self.credential() catch return false) orelse return false;
        defer lease.deinit();
        return self.startSummaryJob(&lease).changed;
    }

    /// True when a job ended. A credential that came meanwhile is reconciled
    /// after it.
    pub fn drainSummary(self: *Runtime) bool {
        self.assertMainThread();
        const job = self.summary_job orelse return false;
        if (!job.finished.load(.acquire)) return false;
        job.join();
        if (job.completion) |*completion|
            _ = self.summary.complete(completion)
        else
            _ = self.summary.fail(job.attempt_id, .account_operation_failed);
        self.summary_job = null;
        job.deinit();
        return true;
    }

    fn clearSummary(self: *Runtime) bool {
        self.cancelSummaryJob();
        self.summary_generation = 0;
        return self.summary.clear();
    }

    pub fn accessTokenProjection(self: *Runtime) contract.AccessTokenProjection {
        self.assertMainThread();
        return .{ .context = self, .generation_fn = projectionGeneration, .visit_fn = visitProjectionToken };
    }

    fn projectionGeneration(context: *anyopaque) u64 {
        const self: *Runtime = @ptrCast(@alignCast(context));
        self.assertMainThread();
        return self.authorization_generation;
    }

    fn visitProjectionToken(context: *anyopaque, visitor_context: *anyopaque, visitor: *const fn (*anyopaque, []const u8) std.mem.Allocator.Error!void) std.mem.Allocator.Error!void {
        const self: *Runtime = @ptrCast(@alignCast(context));
        self.assertMainThread();
        if (self.credentials.tokens) |*tokens| try visitor(visitor_context, tokens.access_token.view());
    }

    /// The current credential, taken whole: account, access token and
    /// generation. Null when nothing may use one now.
    pub fn credential(
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

    /// Admission and every Task blocker read this one fact, without effect.
    pub fn authorization(self: *Runtime) contract.Authorization {
        self.assertMainThread();
        switch (self.account.view().state) {
            .checking => return .{ .checking = self.renewal_epoch },
            .signed_out => return .signed_out,
            .authorizing => return .authorizing,
            .authenticated => {},
        }
        // A logout drops the credential one turn before it commits.
        if (!self.credentials.available()) return .signed_out;
        const account_id = self.account.accountId();
        if (self.availableAuthorizationIdentity() != null)
            return .{ .available = .{ .account_id = account_id, .generation = self.authorization_generation } };
        const clock_reads = if (self.platform) |platform|
            platform.wall_clock.nowUnixSeconds() != null
        else
            false;
        if (!clock_reads and !self.account.refreshInFlight())
            return .{ .stalled = .{ .account_id = account_id } };
        return .{ .recovering = .{ .account_id = account_id, .epoch = self.renewal_epoch } };
    }

    pub fn preparedFact(
        self: *Runtime,
        prepared: *const Prepared,
    ) contract.AccountFact {
        self.assertMainThread();
        var next_view = prepared.transition.view();
        if (next_view.state == .authenticated) next_view.summary = self.summary.view();
        const fact: contract.AccountFact = .{
            .kind = prepared.factKind(),
            .view = next_view,
        };
        contract.validateFact(fact) catch
            @panic("Account Runtime prepared an invalid canonical AccountFact");
        return fact;
    }

    fn startSummaryJob(
        self: *Runtime,
        lease: *contract.OwnedAuthorizationLease,
    ) SummaryRefreshResult {
        const platform = self.platform orelse return .{
            .result = .rejected(.invalid_state),
            .changed = false,
        };
        const now_seconds = platform.wall_clock.nowUnixSeconds() orelse
            return .{ .result = .rejected(.account_operation_failed), .changed = false };
        if (now_seconds < 0) return .{
            .result = .rejected(.account_operation_failed),
            .changed = false,
        };
        const now_ms = std.math.mul(i64, now_seconds, 1000) catch
            return .{ .result = .rejected(.account_operation_failed), .changed = false };
        const synced_at = summary_impl.Decimal.fromInteger(now_ms, false) catch
            return .{ .result = .rejected(.account_operation_failed), .changed = false };
        const history_range = summary_impl.HistoryRange.fromUnixSeconds(now_seconds) catch null;
        // The job takes the lease.
        const generation = lease.authorization_generation;
        const preparation = self.summary.begin(lease.principal_ref) catch return .{ .result = .rejected(.operation_in_progress), .changed = false };
        const job = SummaryJob.create(
            self.allocator,
            self.io,
            self.effects.transport,
            self.effects.wake,
            preparation.attempt_id,
            synced_at,
            history_range,
            lease,
        ) catch {
            _ = self.summary.fail(preparation.attempt_id, .local_resource_exhausted);
            return .{ .result = .rejected(.local_resource_exhausted), .changed = true };
        };
        job.start() catch {
            job.deinit();
            _ = self.summary.fail(preparation.attempt_id, .local_resource_exhausted);
            return .{ .result = .rejected(.local_resource_exhausted), .changed = true };
        };
        self.summary_job = job;
        self.summary_generation = generation;
        return .{
            .result = .acceptedAttempt(preparation.attempt_id),
            .changed = true,
        };
    }

    fn cancelSummaryJob(self: *Runtime) void {
        const job = self.summary_job orelse return;
        job.cancel();
        job.join();
        self.summary_job = null;
        job.deinit();
    }

    pub fn admitEffect(self: *Runtime, prepared: *Prepared) bool {
        self.assertMainThread();
        if (prepared.transition.takeEffect()) |effect|
            return self.effects.queue.submit(
                prepared.transition.attempt_id,
                effect,
                &prepared.login_exchange,
            );
        return true;
    }

    pub fn commit(self: *Runtime, prepared: *Prepared) void {
        self.assertMainThread();
        const terminal = prepared.finishesAttempt();
        const renewal_finished = terminal and self.account.refreshInFlight();
        prepared.transition.commit(&self.account);
        if (terminal) {
            if (self.request_binding) |*binding| std.crypto.secureZero(u8, &binding.digest);
            self.request_binding = null;
        }
        if (renewal_finished) self.renewal_epoch +%= 1;
        switch (prepared.renewal) {
            .keep => {},
            .token => if (self.token_times) |times| {
                self.renew_at = times.renews;
            },
            .retry => if (self.platform) |platform| {
                const now = platform.boot_clock.nowSeconds();
                var delay = renewal_retry_seconds;
                if (self.account.confirming()) {
                    delay = confirm_delays_seconds[@min(self.confirm_failures, confirm_delays_seconds.len - 1)];
                    self.confirm_failures += 1;
                    self.confirm_ended_boot = now;
                }
                self.renew_at = .{ .wall = null, .boot = now +| delay };
            },
        }
        if (!self.account.unconfirmed()) self.confirm_failures = 0;
        if (!self.account.renewable()) self.clearRenewal();
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

    pub fn dispatchCommitted(self: *Runtime) void {
        self.assertMainThread();
        if (self.effects.queue.take()) |entry_value| {
            var entry = entry_value;
            defer entry.deinit();
            self.dispatchEffect(&entry);
        }
    }

    fn prepareWorkerCompletion(
        self: *Runtime,
        completion: *state_impl.WorkerCompletion,
        collision: bool,
    ) PrepareResult {
        const refresh_attempt = self.account.refreshInFlight();
        self.effects.joinNetwork(completion.attempt_id);
        if (self.account.activeAttempt() != completion.attempt_id) return .ignored_stale;
        if (self.account.activeRequestUsesCredential() and self.request_binding != null and
            !self.matchesRequestBinding(completion.attempt_id)) return .ignored_stale;
        if (collision and self.account.activeAttempt() == completion.attempt_id) {
            completion.deinit();
            completion.* = .{
                .attempt_id = completion.attempt_id,
                .payload = .{ .failed = .fromCode(.account_operation_failed) },
            };
        }
        if (completion.payload == .failed and refresh_attempt and
            self.refresh_blocked and completion.payload.failed.refresh_not_consumed)
        {
            if (self.platform) |platform| {
                platform.credentials.clearRefreshMarker() catch {
                    completion.payload.failed.error_code = .credential_store_delete_failed;
                };
                // The delete outcome, not the displayed failure, grants permission.
                if (completion.payload.failed.error_code != .credential_store_delete_failed)
                    self.refresh_blocked = false;
            }
        }
        if (completion.payload == .failed and
            completion.payload.failed.error_code == .metask_unauthorized and
            self.account.activeRequestUsesCredential() and self.matchesRequestBinding(completion.attempt_id))
            completion.payload.failed.error_code = self.deleteInvalidCredential();

        if (completion.payload == .identity_loaded and
            self.matchesRequestBinding(completion.attempt_id))
        {
            const identity = completion.payload.identity_loaded;
            self.credentials.bindPrincipal(identity.accountId()) catch {
                const error_code = self.deleteInvalidCredential();
                completion.payload = .{ .failed = .fromCode(error_code) };
            };
        }
        // Only a refresh proven unsent, whose marker is gone, can be sent
        // again. An explicit request or client rejection was not consumed,
        // but sending it again cannot succeed.
        const retry_unsent_refresh = refresh_attempt and !self.refresh_blocked and
            completion.payload == .failed and completion.payload.failed.refresh_not_consumed and
            completion.payload.failed.error_code != .token_refresh_failed;
        // The token of a stored login is exchanged and kept; an identity that
        // cannot be reached now says nothing about it.
        const retry_identity = self.account.confirmingIdentity() and
            completion.payload == .failed and identityUnreachable(completion.payload.failed.error_code);
        if (completion.payload == .failed and refresh_attempt) {
            if (retry_unsent_refresh or retry_identity)
                completion.payload.failed.retryable = true
            else
                self.loseRenewal(&completion.payload.failed);
        }
        const loaded_identity = completion.payload == .identity_loaded;
        return switch (self.account.prepareCompletion(completion)) {
            .transition => |transition| .{ .prepared = .{
                .transition = transition,
                .renewal = if (loaded_identity and transition.view().state == .authenticated)
                    .token
                else if (retry_unsent_refresh or retry_identity)
                    .retry
                else
                    .keep,
            } },
            .rejected => |error_code| .{ .rejected = error_code },
            .ignored_stale => .ignored_stale,
        };
    }

    /// A verified session's refresh ended in a way it cannot safely send
    /// again. Sign out now, exactly as a restore from the same store would:
    /// the durable token and blocking marker stay as they are, and the
    /// in-memory credential goes, so this process never sends it again.
    fn loseRenewal(self: *Runtime, failure: *state_impl.WorkerFailure) void {
        if (self.account.currentIdentity() == null) return;
        switch (failure.error_code) {
            .metask_unauthorized, .credential_store_delete_failed => failure.retryable = false,
            else => failure.* = .renewalLost(failure.error_code),
        }
        if (self.credentials.available()) self.clearCredentials();
    }

    fn prepareRenewalFailure(
        self: *Runtime,
        attempt_id: u64,
        error_code: contract.ErrorCode,
    ) PrepareResult {
        var failure: state_impl.WorkerFailure = .fromCode(error_code);
        self.loseRenewal(&failure);
        return self.prepareFailureValue(attempt_id, failure);
    }

    fn deleteInvalidCredential(self: *Runtime) contract.ErrorCode {
        const was_blocked = self.refresh_blocked;
        self.refresh_blocked = true;
        const result: contract.ErrorCode = if (self.platform) |platform| blk: {
            if (!was_blocked) if (self.credentials.refreshToken()) |token| {
                platform.credentials.beginRefresh(token) catch |err| break :blk accountStoreError(err);
            };
            credential_store.commitSignedOut(platform.credentials) catch |err|
                break :blk accountStoreError(err);
            self.refresh_blocked = false;
            break :blk .metask_unauthorized;
        } else .credential_store_delete_failed;
        self.clearCredentials();
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
        self.noteTokenInstalled(platform);
        self.refresh_blocked = false;
        platform.credentials.clearRefreshMarker() catch {};
        self.bumpAuthorizationGeneration();
        var completion: state_impl.WorkerCompletion = .{
            .attempt_id = attempt_id,
            .payload = .tokens_persisted,
        };
        defer completion.deinit();
        return wrapPrepareResult(self.account.prepareCompletion(&completion));
    }

    fn prepareLoginExchange(
        self: *Runtime,
        attempt_id: u64,
        input: *login_attempt.CallbackExchangeInput,
    ) PrepareResult {
        return switch (self.account.prepareLoginExchange(attempt_id)) {
            .transition => |transition| .{ .prepared = .{
                .transition = transition,
                .login_exchange = input.take(),
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
        if (identity) |current|
            rotation.bindAccountId(current.accountId()) catch
                return self.prepareRenewalFailure(attempt_id, .metask_protocol_invalid);
        const platform = self.platform orelse
            return self.prepareRenewalFailure(attempt_id, .credential_store_write_failed);
        credential_store.commitRefresh(
            platform.credentials,
            &rotation.persistenceInput().refresh_token,
        ) catch |err| return self.prepareRenewalFailure(attempt_id, accountStoreError(err));
        self.credentials.replaceRotation(rotation);
        self.noteTokenInstalled(platform);
        self.refresh_blocked = false;
        platform.credentials.clearRefreshMarker() catch {};
        self.bumpAuthorizationGeneration();
        var completion: state_impl.WorkerCompletion = .{
            .attempt_id = attempt_id,
            .payload = .tokens_persisted,
        };
        defer completion.deinit();
        return switch (self.account.prepareCompletion(&completion)) {
            .transition => |transition| .{ .prepared = .{
                .transition = transition,
                .renewal = if (identity != null) .token else .keep,
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

    fn dispatchEffect(self: *Runtime, entry: *EffectQueue.Entry) void {
        switch (entry.effect) {
            .begin_oauth => {
                const attempt_id = entry.attempt_id orelse
                    @panic("OAuth effect has no attempt");
                const platform = self.platform orelse {
                    self.publishFailure(attempt_id, .credential_store_read_failed);
                    return;
                };
                self.effects.startLogin(attempt_id, platform.authorization_url);
            },
            .exchange_login => {
                const attempt_id = entry.attempt_id orelse
                    @panic("login exchange effect has no attempt");
                const platform = self.platform orelse {
                    self.publishFailure(attempt_id, .credential_store_read_failed);
                    return;
                };
                const now = platform.wall_clock.nowUnixSeconds() orelse {
                    self.publishFailure(attempt_id, .account_operation_failed);
                    return;
                };
                const input = if (entry.login_exchange) |*value| value else {
                    self.publishFailure(attempt_id, .account_operation_failed);
                    return;
                };
                self.token_requested = .{ .wall = now, .boot = platform.boot_clock.nowSeconds() };
                self.effects.startLoginExchange(attempt_id, input, now);
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
                    self.publishUnsentRefreshFailure(attempt_id, .account_operation_failed);
                    return;
                };
                if (self.refresh_blocked) {
                    self.publishFailure(attempt_id, .token_refresh_failed);
                    return;
                }
                // No marker means no HTTP: this failure is safely retryable.
                platform.credentials.beginRefresh(self.credentials.refreshToken().?) catch |err| {
                    self.publishUnsentRefreshFailure(attempt_id, accountStoreError(err));
                    return;
                };
                self.captureRequestBinding(attempt_id);
                self.token_requested = .{ .wall = now, .boot = platform.boot_clock.nowSeconds() };
                self.refresh_blocked = true;
                self.effects.startRefresh(attempt_id, &self.credentials, now);
            },
            .load_identity => {
                const attempt_id = entry.attempt_id orelse
                    @panic("identity effect has no attempt");
                if (!self.credentials.available()) {
                    self.publishFailure(attempt_id, .credential_store_read_failed);
                    return;
                }
                self.captureRequestBinding(attempt_id);
                self.effects.startLoadIdentity(attempt_id, &self.credentials);
            },
            .cancel_attempt => |attempt_id| self.effects.cancelAttemptAndDiscard(attempt_id),
            .delete_credential => self.persistSignedOut(entry.attempt_id orelse
                @panic("logout effect has no attempt")),
            .shutdown => {
                self.effects.cancelJoinAndDiscard();
                self.clearCredentials();
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

    /// A refresh that failed locally before writing its marker, so before
    /// any HTTP: the retained refresh token is untouched.
    fn publishUnsentRefreshFailure(self: *Runtime, attempt_id: u64, error_code: contract.ErrorCode) void {
        self.effects.publishCompletion(.{
            .attempt_id = attempt_id,
            .payload = .{ .failed = .{ .error_code = error_code, .refresh_not_consumed = true } },
        });
    }

    fn persistSignedOut(self: *Runtime, attempt_id: u64) void {
        const platform = self.platform orelse {
            self.publishFailure(attempt_id, .credential_store_write_failed);
            return;
        };
        if (!self.refresh_blocked) if (self.credentials.refreshToken()) |token| {
            platform.credentials.beginRefresh(token) catch |err| {
                self.publishFailure(attempt_id, accountStoreError(err));
                return;
            };
        };
        self.refresh_blocked = true;
        credential_store.commitSignedOut(platform.credentials) catch |err| {
            self.publishFailure(attempt_id, accountStoreError(err));
            return;
        };
        self.refresh_blocked = false;
        self.clearCredentials();
        self.effects.publishCompletion(.{
            .attempt_id = attempt_id,
            .payload = .logged_out,
        });
    }

    fn noteTokenInstalled(self: *Runtime, platform: ports_impl.Platform) void {
        const expires_at = self.credentials.expiresAt().?;
        const requested = self.token_requested;
        const boot_expires_at = requested.boot +| (expires_at -| requested.wall);
        const wall_now = platform.wall_clock.nowUnixSeconds() orelse requested.wall;
        const boot_now = platform.boot_clock.nowSeconds();
        self.token_times = .{
            .expires = .{ .wall = expires_at, .boot = boot_expires_at },
            .renews = .{
                .wall = @max(expires_at -| renewal_lead_seconds, wall_now +| renewal_min_age_seconds),
                .boot = @max(boot_expires_at -| renewal_lead_seconds, boot_now +| renewal_min_age_seconds),
            },
        };
    }

    /// Renews now when the token is due for it. Otherwise only the beat can
    /// have failed, and it is started again.
    fn prepareRetryRefresh(self: *Runtime) PrepareResult {
        if (self.account.confirming()) {
            if (!self.account.view().can_retry) return .{ .rejected = .invalid_state };
            const platform = self.platform orelse return .{ .rejected = .invalid_state };
            self.confirm_failures = 0;
            return wrapPrepareResult(self.prepareConfirmation(platform));
        }
        if (self.refresh_blocked or self.account.view().state != .authenticated or
            self.account.activeAttempt() != null or
            !self.credentials.available())
            return .{ .rejected = .invalid_state };
        const platform = self.platform orelse return .{ .rejected = .invalid_state };
        const times = self.token_times orelse return .{ .rejected = .invalid_state };
        if (times.renews.reached(platform))
            return wrapPrepareResult(self.account.prepareTokenRefresh());
        return wrapPrepareResult(if (self.keepBeat(platform))
            self.account.prepareRetryRefresh()
        else
            self.account.prepareRefreshScheduleFailure());
    }

    fn availableAuthorizationIdentity(self: *Runtime) ?state_impl.AccountIdentity {
        if (self.account.view().state != .authenticated or
            self.authorization_generation == 0 or
            !self.credentials.available())
            return null;
        const platform = self.platform orelse return null;
        const times = self.token_times orelse return null;
        if (platform.wall_clock.nowUnixSeconds() == null or times.expires.reached(platform)) return null;
        const identity = self.account.currentIdentity() orelse return null;
        if (!self.credentials.belongsToPrincipal(identity.accountId())) return null;
        return identity;
    }

    fn captureRequestBinding(self: *Runtime, attempt_id: u64) void {
        const token = self.credentials.refreshToken() orelse return;
        if (self.request_binding) |*binding| std.crypto.secureZero(u8, &binding.digest);
        self.request_binding = .{
            .attempt_id = attempt_id,
            .generation = self.authorization_generation,
            .digest = credential_store.refreshBinding(token.view()),
        };
    }

    fn matchesRequestBinding(self: *Runtime, attempt_id: u64) bool {
        if (self.account.activeAttempt() != attempt_id) return false;
        const binding = self.request_binding orelse return false;
        if (binding.attempt_id != attempt_id or binding.generation != self.authorization_generation) return false;
        const token = self.credentials.refreshToken() orelse return false;
        var digest = credential_store.refreshBinding(token.view());
        defer std.crypto.secureZero(u8, &digest);
        return std.crypto.timing_safe.eql([32]u8, digest, binding.digest);
    }

    fn clearCredentials(self: *Runtime) void {
        // The only place Account drops credentials: logout, sign-out after a
        // rejected refresh, and shutdown. Pooled connections for the principal
        // end with them.
        if (self.credentials.principal()) |principal| self.effects.transport.retire(principal);
        self.credentials.clear();
        self.token_times = null;
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
            .blocked => blk: {
                self.refresh_blocked = true;
                self.clearCredentials();
                break :blk self.preparedSignedOutRestoreFailure(.token_refresh_failed);
            },
            .signed_out => blk: {
                self.refresh_blocked = false;
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
        refresh_marker: ?[credential_store.marker_bytes]u8 = null,
        marker_write_fails: bool = false,
        marker_delete_fails: bool = false,
        marker_read_fails: bool = false,
        credential_read_fails: bool = false,
        credential_write_fails: bool = false,
        credential_write_count: usize = 0,
        credential_delete_fails: bool = false,
        authorization_open_fails: bool = false,
        recharge_open_fails: bool = false,
        timer_start_fails: bool = false,
        timer_cancel_fails: bool = false,
        authorization_open_count: usize = 0,
        recharge_open_count: usize = 0,
        timer_start_count: usize = 0,
        timer_cancel_count: usize = 0,
        last_timer_id: ?u64 = null,
        last_timer_interval_ns: u64 = 0,
        /// The boot clock follows the wall clock until a test parts them.
        boot_seconds: ?i64 = null,

        pub fn ports(self: *Platform) ports_impl.Platform {
            return .{
                .credentials = .{
                    .context = self,
                    .set_refresh_token_fn = setRefreshToken,
                    .get_refresh_token_fn = getRefreshToken,
                    .delete_refresh_token_fn = deleteRefreshToken,
                    .set_refresh_marker_fn = setRefreshMarker,
                    .get_refresh_marker_fn = getRefreshMarker,
                    .delete_refresh_marker_fn = deleteRefreshMarker,
                },
                .authorization_url = .{
                    .context = self,
                    .open_fn = openAuthorizationUrl,
                },
                .recharge_page = .{
                    .context = self,
                    .open_fn = openRechargePage,
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
                .boot_clock = .{
                    .context = self,
                    .now_seconds_fn = nowBootSeconds,
                },
            };
        }

        pub fn setStoredRefreshToken(self: *Platform, value: []const u8) !void {
            if (value.len == 0 or value.len > self.refresh_token.len)
                return error.InvalidTestCredential;
            @memcpy(self.refresh_token[0..value.len], value);
            self.refresh_token_len = value.len;
        }

        fn setRefreshMarker(context: *anyopaque, value: []const u8) credential_store.StoreError!void {
            const self: *Platform = @ptrCast(@alignCast(context));
            if (self.marker_write_fails) return error.WriteFailed;
            self.refresh_marker = value[0..credential_store.marker_bytes].*;
        }
        fn getRefreshMarker(context: *anyopaque, output: []u8) credential_store.StoreError!?[]const u8 {
            const self: *Platform = @ptrCast(@alignCast(context));
            if (self.marker_read_fails) return error.ReadFailed;
            const marker = self.refresh_marker orelse return null;
            @memcpy(output[0..marker.len], &marker);
            return output[0..marker.len];
        }
        fn deleteRefreshMarker(context: *anyopaque) credential_store.StoreError!void {
            const self: *Platform = @ptrCast(@alignCast(context));
            if (self.marker_delete_fails) return error.DeleteFailed;
            self.refresh_marker = null;
        }

        fn setRefreshToken(
            context: *anyopaque,
            value: []const u8,
        ) credential_store.StoreError!void {
            const self: *Platform = @ptrCast(@alignCast(context));
            self.credential_write_count += 1;
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

        fn openRechargePage(context: *anyopaque, url: []const u8) !void {
            const self: *Platform = @ptrCast(@alignCast(context));
            if (!std.mem.eql(u8, url, contract.recharge_page_url))
                return error.InvalidUrl;
            self.recharge_open_count += 1;
            if (self.recharge_open_fails) return error.OpenFailed;
        }

        fn startTimer(
            context: *anyopaque,
            timer_id: u64,
            interval_ns: u64,
            repeats: bool,
        ) !void {
            const self: *Platform = @ptrCast(@alignCast(context));
            std.debug.assert(repeats);
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

        fn nowBootSeconds(context: *anyopaque) i64 {
            const self: *Platform = @ptrCast(@alignCast(context));
            return self.boot_seconds orelse self.now_unix_seconds orelse 0;
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
            return login_attempt.TestSupport.callback_port;
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

    /// Installs a token requested now, as a completed token request does.
    fn installToken(runtime: *Runtime, account_id: []const u8, access_token: []const u8, refresh_token: []const u8, expires_at: i64) !void {
        try runtime.credentials.installStored(runtime.allocator, access_token, refresh_token, expires_at, account_id);
        if (runtime.platform) |platform| {
            const boot = platform.boot_clock.nowSeconds();
            runtime.token_requested = .{ .wall = platform.wall_clock.nowUnixSeconds() orelse 0, .boot = boot };
            runtime.noteTokenInstalled(platform);
        }
        runtime.bumpAuthorizationGeneration();
    }

    pub fn prepareAuthenticated(
        runtime: *Runtime,
        account_id: []const u8,
        display_name: []const u8,
        access_token: []const u8,
        refresh_token: []const u8,
        expires_at: i64,
    ) !Prepared {
        try installToken(runtime, account_id, access_token, refresh_token, expires_at);
        return .{ .transition = try state_impl.TestSupport.prepareAuthenticated(
            &runtime.account,
            try state_impl.AccountIdentity.init(
                account_id,
                display_name,
                "u***@example.com",
                "",
                5,
            ),
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
        try installToken(runtime, credential_account_id, access_token, refresh_token, expires_at);
        return .{ .transition = try state_impl.TestSupport.prepareAuthenticated(
            &runtime.account,
            try state_impl.AccountIdentity.init(
                identity_account_id,
                display_name,
                "u***@example.com",
                "",
                5,
            ),
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
        prepared.renewal = .token;
        return prepared;
    }

    pub fn attachPlatform(runtime: *Runtime, platform: *Platform) void {
        std.debug.assert(runtime.platform == null);
        runtime.platform = platform.ports();
    }

    pub fn detachPlatform(runtime: *Runtime) void {
        runtime.platform = null;
    }

    pub fn joinSummary(runtime: *Runtime) void {
        const job = runtime.summary_job orelse
            @panic("test Account has no summary job");
        job.join();
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

    pub fn prepareBeginLoginWithoutEffect(runtime: *Runtime) Prepared {
        var begin = switch (runtime.prepareCommand(.begin_login)) {
            .prepared => |prepared| prepared,
            else => @panic("test Account cannot begin login"),
        };
        _ = begin.transition.takeEffect() orelse
            @panic("test login has no OAuth effect");
        return begin;
    }

    pub fn commitBeginLoginWithoutDispatch(runtime: *Runtime) u64 {
        var begin = prepareBeginLoginWithoutEffect(runtime);
        defer begin.deinit();
        runtime.commit(&begin);
        return runtime.account.activeAttempt() orelse
            @panic("test login has no active attempt");
    }

    pub fn prepareLoginExchange(
        runtime: *Runtime,
        input: *login_attempt.CallbackExchangeInput,
    ) Prepared {
        const attempt_id = runtime.account.activeAttempt() orelse
            @panic("test Account has no active login attempt");
        return switch (runtime.prepareLoginExchange(attempt_id, input)) {
            .prepared => |prepared| prepared,
            else => @panic("test Account cannot continue to login exchange"),
        };
    }

    pub fn exchangeInput(
        allocator: std.mem.Allocator,
        code_value: []const u8,
    ) !login_attempt.CallbackExchangeInput {
        return login_attempt.TestSupport.exchangeInput(
            allocator,
            std.testing.io,
            code_value,
            .{ .raw = .fromSeconds(5 * 60), .clock = .boot },
        );
    }

    pub fn prepareTokenRefreshWithoutEffect(runtime: *Runtime) Prepared {
        var prepared = switch (runtime.prepareTokenRefresh()) {
            .prepared => |value| value,
            else => @panic("test Account cannot begin token refresh"),
        };
        _ = prepared.transition.takeEffect() orelse
            @panic("test token refresh has no effect");
        runtime.captureRequestBinding(prepared.attemptId().?);
        return prepared;
    }

    pub fn publishFailure(
        runtime: *Runtime,
        attempt_id: u64,
        error_code: contract.ErrorCode,
    ) void {
        if (runtime.account.activeAttempt() == attempt_id and runtime.account.activeRequestUsesCredential() and runtime.request_binding == null)
            runtime.captureRequestBinding(attempt_id);
        runtime.publishFailure(attempt_id, error_code);
    }

    /// A refresh that ended before any HTTP, as the Runtime publishes it.
    pub fn publishUnsentRefreshFailure(runtime: *Runtime, error_code: contract.ErrorCode) void {
        runtime.publishUnsentRefreshFailure(runtime.account.activeAttempt().?, error_code);
    }

    pub fn publishLoginExchange(
        runtime: *Runtime,
        attempt_id: u64,
        input: *login_attempt.CallbackExchangeInput,
    ) void {
        var result: login_attempt.WorkerResult = .{ .exchange = input.take() };
        runtime.effects.loginSink().publish(attempt_id, &result);
    }

    pub fn joinNetwork(runtime: *Runtime) void {
        runtime.effects.network_attempt.join();
    }

    pub fn occupyEffectQueue(runtime: *Runtime) void {
        std.debug.assert(runtime.effects.queue.entry == null);
        runtime.effects.queue.entry = .{ .attempt_id = 99, .effect = .begin_oauth };
    }

    pub fn clearEffectQueue(runtime: *Runtime) void {
        if (runtime.effects.queue.take()) |entry_value| {
            var entry = entry_value;
            entry.deinit();
        }
    }

    fn testLoopbackOpen(_: *anyopaque) loopback_impl.ServerError!u16 {
        return login_attempt.TestSupport.callback_port;
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

/// Network, deadline, rate limit, server failure, or no thread to ask with.
fn identityUnreachable(error_code: contract.ErrorCode) bool {
    return switch (error_code) {
        .metask_service_unavailable, .deadline_exceeded, .metask_rate_limited, .local_resource_exhausted => true,
        else => false,
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
    failure: metask_client.TransportError = error.NetworkFailed,
    retired: [32]u8 = undefined,
    retired_len: ?usize = null,
    retire_count: usize = 0,

    fn port(self: *RuntimeTestTransport) metask_client.Transport {
        return .{ .context = self, .perform_fn = perform, .retire_fn = retire };
    }

    fn retire(context: *anyopaque, principal: []const u8) void {
        const self: *RuntimeTestTransport = @ptrCast(@alignCast(context));
        self.retire_count += 1;
        @memcpy(self.retired[0..principal.len], principal);
        self.retired_len = principal.len;
    }

    fn perform(
        context: *anyopaque,
        _: metask_client.Request,
        _: []u8,
    ) metask_client.TransportError!metask_client.Response {
        const self: *RuntimeTestTransport = @ptrCast(@alignCast(context));
        self.calls += 1;
        return self.failure;
    }
};

fn runtimeTestWake(_: *anyopaque) void {}

fn initRuntimeForUnitTest(transport: *RuntimeTestTransport) !Runtime {
    return Runtime.init(
        std.testing.allocator,
        std.testing.io,
        std.Thread.getCurrentId(),
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

    var lease = (try runtime.credential()).?;
    defer lease.deinit();
    const generation = lease.authorization_generation;
    try std.testing.expectEqual(generation, runtime.authorization().use().ready);

    // Run preparation must call the lease capability at admission. Neither
    // cached authenticated state nor a matching generation proves the clock
    // still permits a new consumer, and no notification is needed to expire it.
    platform.now_unix_seconds = null;
    try std.testing.expect((try runtime.credential()) == null);
    try std.testing.expect(runtime.authorization() == .stalled);
    platform.now_unix_seconds = 101;
    try std.testing.expect((try runtime.credential()) == null);
    try std.testing.expect(runtime.authorization() == .recovering);
    try std.testing.expectEqual(contract.AccountState.authenticated, runtime.view().state);
    try std.testing.expectEqual(generation, runtime.authorization_generation);
    // Already handed-off owned credentials retain their independent lifetime.
    try std.testing.expectEqualStrings("access-token", lease.access_token);
}

test "clearing credentials retires the principal's pooled connections once" {
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
    try std.testing.expectEqual(@as(usize, 0), transport.retire_count);
    runtime.clearCredentials();
    try std.testing.expectEqual(@as(usize, 1), transport.retire_count);
    try std.testing.expectEqualStrings("account-1", transport.retired[0..transport.retired_len.?]);
    // Nothing left to retire once the credentials are gone.
    runtime.clearCredentials();
    try std.testing.expectEqual(@as(usize, 1), transport.retire_count);
}

test "incomplete profile identity still issues an authorization lease" {
    var transport: RuntimeTestTransport = .{};
    var runtime = try initRuntimeForUnitTest(&transport);
    var platform: TestSupport.Platform = .{ .now_unix_seconds = 100 };
    TestSupport.attachPlatform(&runtime, &platform);
    defer {
        TestSupport.detachPlatform(&runtime);
        runtime.deinit();
    }
    try TestSupport.installToken(&runtime, "account-1", "access-token", "refresh-token", 200);
    var authenticated: Prepared = .{
        .transition = try state_impl.TestSupport.prepareAuthenticated(
            &runtime.account,
            try state_impl.AccountIdentity.init("account-1", "", "", "", null),
        ),
    };
    defer authenticated.deinit();
    runtime.commit(&authenticated);

    var lease = (try runtime.credential()).?;
    defer lease.deinit();
    try std.testing.expectEqualStrings("account-1", lease.principal_ref);
    try std.testing.expectEqualStrings("access-token", lease.access_token);
    try std.testing.expectEqual(lease.authorization_generation, runtime.authorization().use().ready);
}

test "recharge page opens only for an authenticated Account" {
    var transport: RuntimeTestTransport = .{};
    var runtime = try initRuntimeForUnitTest(&transport);
    var platform: TestSupport.Platform = .{ .now_unix_seconds = 100 };
    TestSupport.attachPlatform(&runtime, &platform);
    defer {
        TestSupport.detachPlatform(&runtime);
        runtime.deinit();
    }

    try std.testing.expectEqual(
        contract.ErrorCode.invalid_state,
        runtime.openRechargePage().error_code,
    );

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

    try std.testing.expect(runtime.openRechargePage().accepted);
    try std.testing.expectEqual(@as(usize, 1), platform.recharge_open_count);

    platform.recharge_open_fails = true;
    const failed = runtime.openRechargePage();
    try std.testing.expect(!failed.accepted);
    try std.testing.expectEqual(
        contract.ErrorCode.account_operation_failed,
        failed.error_code,
    );
    try std.testing.expectEqual(@as(usize, 2), platform.recharge_open_count);
}

test "prepared attempt disposition distinguishes all four transition classes" {
    var transport: RuntimeTestTransport = .{};
    var runtime = try initRuntimeForUnitTest(&transport);
    defer runtime.deinit();

    var no_attempt = runtime.prepareAutomationStart();
    defer no_attempt.deinit();
    try std.testing.expectEqual(
        AttemptDisposition.no_attempt,
        runtime.attemptDisposition(&no_attempt),
    );
    runtime.commit(&no_attempt);

    var starts = switch (runtime.prepareCommand(.begin_login)) {
        .prepared => |prepared| prepared,
        else => return error.TestUnexpectedResult,
    };
    defer starts.deinit();
    try std.testing.expectEqual(
        AttemptDisposition.starts,
        runtime.attemptDisposition(&starts),
    );
    _ = starts.transition.takeEffect();
    runtime.commit(&starts);

    var finishes = switch (runtime.prepareCommand(.cancel_operation)) {
        .prepared => |prepared| prepared,
        else => return error.TestUnexpectedResult,
    };
    defer finishes.deinit();
    try std.testing.expectEqual(
        AttemptDisposition.finishes,
        runtime.attemptDisposition(&finishes),
    );

    var input = try login_attempt.TestSupport.exchangeInput(
        std.testing.allocator,
        std.testing.io,
        "authorization-code",
        .{ .raw = .fromSeconds(5 * 60), .clock = .boot },
    );
    defer input.deinit();
    var continues = switch (runtime.prepareLoginExchange(
        runtime.account.activeAttempt().?,
        &input,
    )) {
        .prepared => |prepared| prepared,
        else => return error.TestUnexpectedResult,
    };
    defer continues.deinit();
    try std.testing.expectEqual(
        AttemptDisposition.continues,
        runtime.attemptDisposition(&continues),
    );
}

test "cold restore alone consumes a retained refresh credential" {
    var transport: RuntimeTestTransport = .{};
    var runtime = try initRuntimeForUnitTest(&transport);
    var platform: TestSupport.Platform = .{};
    try platform.setStoredRefreshToken("retained-refresh-token");
    defer {
        TestSupport.detachPlatform(&runtime);
        runtime.deinit();
    }

    var restored = runtime.prepareStart(platform.ports());
    defer restored.deinit();
    try std.testing.expectEqual(contract.AccountState.checking, restored.transition.view().state);
    try std.testing.expect(runtime.takeRefreshAfterCommit(&restored));
    runtime.commit(&restored);

    var refresh = runtime.prepareRestoredRefresh();
    defer refresh.deinit();
    try std.testing.expectEqual(
        AttemptDisposition.starts,
        runtime.attemptDisposition(&refresh),
    );
    try std.testing.expect(refresh.transition.takeEffect().? == .refresh_token);
}

test "explicit login starts new OAuth even when a retained refresh remains" {
    var transport: RuntimeTestTransport = .{};
    var runtime = try initRuntimeForUnitTest(&transport);
    defer runtime.deinit();
    var signed_out = runtime.prepareAutomationStart();
    defer signed_out.deinit();
    runtime.commit(&signed_out);
    try runtime.credentials.installStored(
        std.testing.allocator,
        "stale-access",
        "retained-refresh",
        200,
        "account-1",
    );

    var login = switch (runtime.prepareCommand(.begin_login)) {
        .prepared => |prepared| prepared,
        else => return error.TestUnexpectedResult,
    };
    defer login.deinit();
    try std.testing.expectEqual(contract.AccountState.authorizing, login.transition.view().state);
    try std.testing.expect(login.transition.takeEffect().? == .begin_oauth);
}

test "unauthorized login code exchange preserves the retained credential" {
    var transport: RuntimeTestTransport = .{};
    var runtime = try initRuntimeForUnitTest(&transport);
    var platform: TestSupport.Platform = .{ .now_unix_seconds = 100 };
    try platform.setStoredRefreshToken("retained-refresh");
    TestSupport.attachPlatform(&runtime, &platform);
    defer {
        TestSupport.detachPlatform(&runtime);
        runtime.deinit();
    }
    var authenticated = try TestSupport.prepareAuthenticated(
        &runtime,
        "account-1",
        "Metask User",
        "old-access",
        "retained-refresh",
        200,
    );
    defer authenticated.deinit();
    runtime.commit(&authenticated);
    var previous_lease = (try runtime.credential()).?;
    const previous_generation = previous_lease.authorization_generation;
    previous_lease.deinit();

    _ = TestSupport.commitBeginLoginWithoutDispatch(&runtime);
    var input = try TestSupport.exchangeInput(std.testing.allocator, "authorization-code");
    defer input.deinit();
    var exchange = TestSupport.prepareLoginExchange(&runtime, &input);
    defer exchange.deinit();
    _ = exchange.transition.takeEffect() orelse
        return error.TestUnexpectedResult;
    runtime.commit(&exchange);

    TestSupport.publishFailure(
        &runtime,
        runtime.account.activeAttempt().?,
        .metask_unauthorized,
    );
    var failed = switch (runtime.prepareNextCompletion().?) {
        .prepared => |prepared| prepared,
        else => return error.TestUnexpectedResult,
    };
    defer failed.deinit();
    try std.testing.expectEqualStrings(
        "retained-refresh",
        platform.refresh_token[0..platform.refresh_token_len.?],
    );
    runtime.commit(&failed);
    try std.testing.expectEqual(contract.AccountState.authenticated, runtime.view().state);
    var retained_lease = (try runtime.credential()).?;
    defer retained_lease.deinit();
    try std.testing.expectEqual(previous_generation, retained_lease.authorization_generation);
}

test "unauthorized login identity validation deletes the newly committed credential" {
    var transport: RuntimeTestTransport = .{};
    var runtime = try initRuntimeForUnitTest(&transport);
    var platform: TestSupport.Platform = .{ .now_unix_seconds = 100 };
    try platform.setStoredRefreshToken("retained-refresh");
    TestSupport.attachPlatform(&runtime, &platform);
    defer {
        TestSupport.detachPlatform(&runtime);
        runtime.deinit();
    }
    var authenticated = try TestSupport.prepareAuthenticated(
        &runtime,
        "account-1",
        "Metask User",
        "old-access",
        "retained-refresh",
        200,
    );
    defer authenticated.deinit();
    runtime.commit(&authenticated);

    _ = TestSupport.commitBeginLoginWithoutDispatch(&runtime);
    var input = try TestSupport.exchangeInput(std.testing.allocator, "authorization-code");
    defer input.deinit();
    var exchange = TestSupport.prepareLoginExchange(&runtime, &input);
    defer exchange.deinit();
    _ = exchange.transition.takeEffect() orelse
        return error.TestUnexpectedResult;
    runtime.commit(&exchange);

    var tokens = try metask_client.AuthorizationResult.fromStored(
        std.testing.allocator,
        "new-access",
        "new-refresh",
        200,
        "account-2",
    );
    defer tokens.deinit();
    var loading_identity = switch (runtime.prepareAuthorizedLogin(
        runtime.account.activeAttempt().?,
        &tokens,
    )) {
        .prepared => |prepared| prepared,
        else => return error.TestUnexpectedResult,
    };
    defer loading_identity.deinit();
    try std.testing.expectEqualStrings(
        "new-refresh",
        platform.refresh_token[0..platform.refresh_token_len.?],
    );
    _ = loading_identity.transition.takeEffect() orelse
        return error.TestUnexpectedResult;
    runtime.commit(&loading_identity);

    TestSupport.publishFailure(
        &runtime,
        runtime.account.activeAttempt().?,
        .metask_unauthorized,
    );
    var signed_out = switch (runtime.prepareNextCompletion().?) {
        .prepared => |prepared| prepared,
        else => return error.TestUnexpectedResult,
    };
    defer signed_out.deinit();
    try std.testing.expectEqual(@as(?usize, null), platform.refresh_token_len);
    runtime.commit(&signed_out);
    try std.testing.expectEqual(contract.AccountState.signed_out, runtime.view().state);
    try std.testing.expect((try runtime.credential()) == null);
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
    try std.testing.expect((try runtime.credential()) == null);

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
    try std.testing.expect((try mismatched.credential()) == null);
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
    var before = (try runtime.credential()).?;
    const generation = before.authorization_generation;
    before.deinit();

    var refreshing = TestSupport.prepareTokenRefreshWithoutEffect(&runtime);
    defer refreshing.deinit();
    runtime.commit(&refreshing);

    var during = (try runtime.credential()).?;
    defer during.deinit();
    try std.testing.expectEqual(generation, during.authorization_generation);
}

test "unauthorized refresh deletes the retained credential before signing out" {
    var transport: RuntimeTestTransport = .{};
    var runtime = try initRuntimeForUnitTest(&transport);
    var platform: TestSupport.Platform = .{ .now_unix_seconds = 100 };
    try platform.setStoredRefreshToken("refresh-token");
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
    var refreshing = TestSupport.prepareTokenRefreshWithoutEffect(&runtime);
    defer refreshing.deinit();
    runtime.commit(&refreshing);

    TestSupport.publishFailure(
        &runtime,
        runtime.account.activeAttempt().?,
        .metask_unauthorized,
    );
    var signed_out = switch (runtime.prepareNextCompletion().?) {
        .prepared => |prepared| prepared,
        else => return error.TestUnexpectedResult,
    };
    defer signed_out.deinit();
    try std.testing.expectEqual(@as(?usize, null), platform.refresh_token_len);
    runtime.commit(&signed_out);
    try std.testing.expectEqual(contract.AccountState.signed_out, runtime.view().state);
    try std.testing.expectEqual(contract.ErrorCode.metask_unauthorized, runtime.view().error_code);
    try std.testing.expect((try runtime.credential()) == null);
}

test "retry refresh restarts the beat and renews a token that is due" {
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
    try std.testing.expectEqual(@as(usize, 1), platform.timer_start_count);
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

test "cold restore request error preserves the retained refresh credential" {
    const RequestErrorTransport = struct {
        fn perform(_: *anyopaque, request: metask_client.Request, output: []u8) metask_client.TransportError!metask_client.Response {
            if (request.kind != .refresh_token or !std.mem.eql(
                u8,
                request.body,
                "grant_type=refresh_token&client_id=metawork&refresh_token=retained-refresh",
            )) return error.ProtocolFailed;
            const body = "{\"error\":\"invalid_request\",\"error_description\":\"client_id required\"}";
            @memcpy(output[0..body.len], body);
            return .{ .status = 400, .body = output[0..body.len] };
        }
    };
    var context: u8 = 0;
    var runtime = Runtime.init(
        std.testing.allocator,
        std.testing.io,
        std.Thread.getCurrentId(),
        .{ .context = &context, .perform_fn = RequestErrorTransport.perform, .retire_fn = metask_client.retireNothing },
        TestSupport.loopbackEndpoint(),
        .{ .context = &context, .notify_fn = runtimeTestWake },
    );
    var platform: TestSupport.Platform = .{};
    try platform.setStoredRefreshToken("retained-refresh");
    defer {
        TestSupport.detachPlatform(&runtime);
        runtime.deinit();
    }
    var restored = runtime.prepareStart(platform.ports());
    defer restored.deinit();
    try std.testing.expect(runtime.takeRefreshAfterCommit(&restored));
    runtime.commit(&restored);
    var refresh = runtime.prepareRestoredRefresh();
    defer refresh.deinit();
    try std.testing.expect(runtime.admitEffect(&refresh));
    runtime.commit(&refresh);
    runtime.dispatchCommitted();
    runtime.effects.network_attempt.join();
    var failed = switch (runtime.prepareNextCompletion().?) {
        .prepared => |prepared| prepared,
        else => return error.TestUnexpectedResult,
    };
    defer failed.deinit();
    runtime.commit(&failed);
    try std.testing.expectEqual(contract.AccountState.signed_out, runtime.view().state);
    try std.testing.expectEqual(contract.ErrorCode.token_refresh_failed, runtime.view().error_code);
    try std.testing.expectEqualStrings("retained-refresh", platform.refresh_token[0..platform.refresh_token_len.?]);
}

fn beginTestRefresh(runtime: *Runtime, platform: *TestSupport.Platform) !void {
    TestSupport.attachPlatform(runtime, platform);
    var authenticated = try TestSupport.prepareAuthenticatedAndSchedule(runtime, "account-1", "Metask", "access-token", "refresh-token", 200);
    defer authenticated.deinit();
    runtime.commit(&authenticated);
    var refresh = switch (runtime.prepareTokenRefresh()) {
        .prepared => |prepared| prepared,
        else => return error.TestUnexpectedResult,
    };
    defer refresh.deinit();
    try std.testing.expect(runtime.admitEffect(&refresh));
    runtime.commit(&refresh);
    runtime.dispatchCommitted();
}

/// Commits the renewal the clocks find due and sends it.
fn startDueRenewal(runtime: *Runtime) !void {
    var refresh = runtime.prepareDue() orelse return error.TestUnexpectedResult;
    defer refresh.deinit();
    try std.testing.expect(refresh.attemptId() != null);
    try std.testing.expect(runtime.admitEffect(&refresh));
    runtime.commit(&refresh);
    runtime.dispatchCommitted();
}

fn finishTestRefresh(runtime: *Runtime) !void {
    runtime.effects.network_attempt.join();
    var failed = switch (runtime.prepareNextCompletion().?) {
        .prepared => |prepared| prepared,
        else => return error.TestUnexpectedResult,
    };
    defer failed.deinit();
    runtime.commit(&failed);
    runtime.dispatchCommitted();
}

test "marker write failure sends no refresh HTTP and remains safely retryable" {
    var transport: RuntimeTestTransport = .{};
    var runtime = try initRuntimeForUnitTest(&transport);
    var platform: TestSupport.Platform = .{ .marker_write_fails = true };
    defer {
        TestSupport.detachPlatform(&runtime);
        runtime.deinit();
    }
    try beginTestRefresh(&runtime, &platform);
    runtime.effects.network_attempt.join();
    var failed = switch (runtime.prepareNextCompletion().?) {
        .prepared => |prepared| prepared,
        else => return error.TestUnexpectedResult,
    };
    defer failed.deinit();
    runtime.commit(&failed);
    runtime.dispatchCommitted();
    try std.testing.expectEqual(@as(usize, 0), transport.calls);
    try std.testing.expect(!runtime.refresh_blocked);
    try std.testing.expect(platform.refresh_marker == null);
    try std.testing.expectEqual(contract.AccountState.authenticated, runtime.view().state);
    try std.testing.expectEqual(contract.ErrorCode.credential_store_write_failed, runtime.view().error_code);
    // Nothing was sent, so the session keeps its identity and retries.
    try std.testing.expect(runtime.prepareDue() == null);
    platform.now_unix_seconds = 129;
    try std.testing.expect(runtime.prepareDue() == null);
    platform.now_unix_seconds = 130;
    try startDueRenewal(&runtime);
    try std.testing.expect(runtime.credentials.available());
}

test "a refresh that cannot read the clock keeps the verified session" {
    var transport: RuntimeTestTransport = .{};
    var runtime = try initRuntimeForUnitTest(&transport);
    var platform: TestSupport.Platform = .{};
    defer {
        TestSupport.detachPlatform(&runtime);
        runtime.deinit();
    }
    TestSupport.attachPlatform(&runtime, &platform);
    var authenticated = try TestSupport.prepareAuthenticated(&runtime, "account-1", "Metask", "access-token", "refresh-token", 200);
    defer authenticated.deinit();
    runtime.commit(&authenticated);
    var refresh = switch (runtime.prepareTokenRefresh()) {
        .prepared => |prepared| prepared,
        else => return error.TestUnexpectedResult,
    };
    defer refresh.deinit();
    try std.testing.expect(runtime.admitEffect(&refresh));
    runtime.commit(&refresh);
    platform.now_unix_seconds = null;
    runtime.dispatchCommitted();
    var failed = switch (runtime.prepareNextCompletion().?) {
        .prepared => |prepared| prepared,
        else => return error.TestUnexpectedResult,
    };
    defer failed.deinit();
    runtime.commit(&failed);
    try std.testing.expectEqual(@as(usize, 0), transport.calls);
    try std.testing.expectEqual(contract.AccountState.authenticated, runtime.view().state);
    try std.testing.expectEqual(contract.ErrorCode.account_operation_failed, runtime.view().error_code);
    try std.testing.expect(platform.refresh_marker == null);
    // Without a clock nothing retries and nothing waits for it; a retry is
    // due once the clock reads again.
    platform.boot_seconds = 1000;
    try std.testing.expect(runtime.prepareDue() == null);
    try std.testing.expect(runtime.authorization() == .stalled);
    platform.now_unix_seconds = 100;
    try startDueRenewal(&runtime);
}

test "unknown transport result blocks timer retry cancelled reauthentication and restart" {
    for ([_]metask_client.TransportError{ error.NetworkFailed, error.Cancelled, error.DeadlineExceeded }) |failure| {
        var transport: RuntimeTestTransport = .{ .failure = failure };
        var runtime = try initRuntimeForUnitTest(&transport);
        var platform: TestSupport.Platform = .{};
        try platform.setStoredRefreshToken("refresh-token");
        defer {
            TestSupport.detachPlatform(&runtime);
            runtime.deinit();
        }
        try beginTestRefresh(&runtime, &platform);
        try finishTestRefresh(&runtime);
        try std.testing.expectEqual(@as(usize, 1), transport.calls);
        try std.testing.expect(runtime.refresh_blocked);
        // The verified session ends now, as a restart would end it.
        try std.testing.expectEqual(contract.AccountState.signed_out, runtime.view().state);
        try std.testing.expectEqual(contract.ErrorCode.token_refresh_failed, runtime.view().error_code);
        try std.testing.expect(!runtime.credentials.available());
        try std.testing.expect(platform.refresh_marker != null);
        try std.testing.expect(runtime.prepareCommand(.retry_refresh) == .rejected);
        // Nothing renews a signed-out Account, however late it is.
        for ([_]i64{ 150, 200, 4000 }) |now| {
            platform.now_unix_seconds = now;
            try std.testing.expect(runtime.prepareDue() == null);
            try std.testing.expect(runtime.authorization() == .signed_out);
        }
        try std.testing.expectEqual(@as(usize, 0), platform.timer_start_count);
        _ = TestSupport.commitBeginLoginWithoutDispatch(&runtime);
        var cancel = switch (runtime.prepareCommand(.cancel_operation)) {
            .prepared => |p| p,
            else => return error.TestUnexpectedResult,
        };
        defer cancel.deinit();
        _ = cancel.transition.takeEffect();
        runtime.commit(&cancel);
        try std.testing.expect(runtime.prepareCommand(.retry_refresh) == .rejected);
        var restarted = try initRuntimeForUnitTest(&transport);
        defer {
            TestSupport.detachPlatform(&restarted);
            restarted.deinit();
        }
        var restored = restarted.prepareStart(platform.ports());
        defer restored.deinit();
        restarted.commit(&restored);
        try std.testing.expect(!restarted.takeRefreshAfterCommit(&restored));
        try std.testing.expectEqual(contract.AccountState.signed_out, restarted.view().state);
        try std.testing.expectEqual(contract.ErrorCode.token_refresh_failed, restarted.view().error_code);
        try std.testing.expectEqual(@as(usize, 1), transport.calls);
    }
}

const ResponseTestTransport = struct {
    status: u16,
    body: []const u8,
    calls: usize = 0,

    fn port(self: *@This()) metask_client.Transport {
        return .{ .context = self, .perform_fn = perform, .retire_fn = metask_client.retireNothing };
    }

    fn perform(context: *anyopaque, request: metask_client.Request, output: []u8) metask_client.TransportError!metask_client.Response {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (request.kind != .refresh_token) return error.ProtocolFailed;
        self.calls += 1;
        @memcpy(output[0..self.body.len], self.body);
        return .{ .status = self.status, .body = output[0..self.body.len] };
    }
};

test "a refresh answered without a rotation signs out exactly as restore would" {
    const Case = struct { status: u16, body: []const u8, cause: []const u8, blocks: bool };
    for ([_]Case{
        .{ .status = 429, .body = "{}", .cause = "metask_rate_limited", .blocks = true },
        .{ .status = 500, .body = "{}", .cause = "metask_service_unavailable", .blocks = true },
        .{ .status = 503, .body = "{\"error\":\"server_error\"}", .cause = "metask_service_unavailable", .blocks = true },
        .{ .status = 404, .body = "{}", .cause = "metask_protocol_invalid", .blocks = true },
        .{ .status = 200, .body = "{\"access_token\":", .cause = "metask_protocol_invalid", .blocks = true },
        .{ .status = 400, .body = "{\"error\":\"invalid_request\"}", .cause = "", .blocks = false },
        .{ .status = 400, .body = "{\"error\":\"invalid_scope\"}", .cause = "", .blocks = false },
        .{ .status = 401, .body = "{\"error\":\"invalid_client\"}", .cause = "", .blocks = false },
    }) |case| {
        var transport: ResponseTestTransport = .{ .status = case.status, .body = case.body };
        var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId(), transport.port(), TestSupport.loopbackEndpoint(), .{ .context = &transport, .notify_fn = runtimeTestWake });
        var platform: TestSupport.Platform = .{};
        try platform.setStoredRefreshToken("refresh-token");
        defer {
            TestSupport.detachPlatform(&runtime);
            runtime.deinit();
        }
        try beginTestRefresh(&runtime, &platform);
        try finishTestRefresh(&runtime);
        try std.testing.expectEqual(@as(usize, 1), transport.calls);
        try std.testing.expectEqual(contract.AccountState.signed_out, runtime.view().state);
        try std.testing.expectEqual(contract.ErrorCode.token_refresh_failed, runtime.view().error_code);
        try std.testing.expectEqualStrings(case.cause, runtime.view().safe_diagnostic);
        try std.testing.expect(!runtime.credentials.available());
        try std.testing.expect(runtime.authorization() == .signed_out);
        platform.now_unix_seconds = 4000;
        try std.testing.expect(runtime.prepareDue() == null);
        try std.testing.expectEqualStrings("refresh-token", platform.refresh_token[0..platform.refresh_token_len.?]);
        try std.testing.expectEqual(case.blocks, platform.refresh_marker != null);

        // A restart from the same store reaches the same public state.
        var restarted = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId(), transport.port(), TestSupport.loopbackEndpoint(), .{ .context = &transport, .notify_fn = runtimeTestWake });
        defer {
            TestSupport.detachPlatform(&restarted);
            restarted.deinit();
        }
        var restored = restarted.prepareStart(platform.ports());
        defer restored.deinit();
        const restores = restarted.takeRefreshAfterCommit(&restored);
        restarted.commit(&restored);
        try std.testing.expectEqual(!case.blocks, restores);
        if (restores) {
            var restore_refresh = restarted.prepareRestoredRefresh();
            defer restore_refresh.deinit();
            try std.testing.expect(restarted.admitEffect(&restore_refresh));
            restarted.commit(&restore_refresh);
            restarted.dispatchCommitted();
            try finishTestRefresh(&restarted);
        }
        try std.testing.expectEqual(contract.AccountState.signed_out, restarted.view().state);
        try std.testing.expectEqual(contract.ErrorCode.token_refresh_failed, restarted.view().error_code);
        try std.testing.expectEqual(@as(usize, if (case.blocks) 1 else 2), transport.calls);
    }
}

test "every Account state answers one authorization" {
    const Use = contract.Authorization.Use;
    var transport: RotationTestTransport = .{};
    var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId(), transport.port(), TestSupport.loopbackEndpoint(), .{ .context = &transport, .notify_fn = runtimeTestWake });
    var platform: TestSupport.Platform = .{ .now_unix_seconds = 100 };
    try platform.setStoredRefreshToken("refresh-token");
    defer {
        TestSupport.detachPlatform(&runtime);
        runtime.deinit();
    }
    // Confirming a stored login: not started, restored, refreshing.
    try std.testing.expectEqual(Use{ .wait = 0 }, runtime.authorization().use());
    var start = runtime.prepareStart(platform.ports());
    defer start.deinit();
    runtime.commit(&start);
    try std.testing.expectEqual(Use{ .wait = 0 }, runtime.authorization().use());
    var restore = runtime.prepareRestoredRefresh();
    defer restore.deinit();
    try std.testing.expect(runtime.admitEffect(&restore));
    runtime.commit(&restore);
    TestSupport.clearEffectQueue(&runtime);
    try std.testing.expectEqual(@as(u64, 0), runtime.authorization().checking);

    var verified_transport: RuntimeTestTransport = .{};
    var verified = try initRuntimeForUnitTest(&verified_transport);
    var verified_platform: TestSupport.Platform = .{ .now_unix_seconds = 100 };
    TestSupport.attachPlatform(&verified, &verified_platform);
    defer {
        TestSupport.detachPlatform(&verified);
        verified.deinit();
    }
    var authenticated = try TestSupport.prepareAuthenticated(&verified, "account-1", "Metask", "access-token", "refresh-token", 200);
    defer authenticated.deinit();
    verified.commit(&authenticated);
    const generation = verified.authorization_generation;
    try std.testing.expectEqualStrings("account-1", verified.authorization().available.account_id);
    try std.testing.expectEqual(Use{ .ready = generation }, verified.authorization().use());
    // The identity is borrowed from committed state, not from a copy.
    try std.testing.expectEqual(verified.account.accountId().ptr, verified.authorization().available.account_id.ptr);
    // Without a wall clock nothing says whether the token still holds, so
    // nothing waits for it.
    verified_platform.now_unix_seconds = null;
    try std.testing.expect(verified.authorization() == .stalled);
    try std.testing.expectEqual(Use{ .stop = .no_connection }, verified.authorization().use());
    // An expired token recovers; an attempt underway always has an outcome.
    verified_platform.now_unix_seconds = 200;
    try std.testing.expectEqual(Use{ .wait = 0 }, verified.authorization().use());
    try std.testing.expectEqualStrings("account-1", verified.authorization().recovering.account_id);
    var refresh = TestSupport.prepareTokenRefreshWithoutEffect(&verified);
    defer refresh.deinit();
    verified.commit(&refresh);
    verified_platform.now_unix_seconds = null;
    try std.testing.expect(verified.authorization() == .recovering);
    verified_platform.now_unix_seconds = 100;
    try std.testing.expectEqual(Use{ .ready = generation }, verified.authorization().use());
    TestSupport.publishUnsentRefreshFailure(&verified, .account_operation_failed);
    var unsent = switch (verified.prepareNextCompletion().?) {
        .prepared => |prepared| prepared,
        else => return error.TestUnexpectedResult,
    };
    defer unsent.deinit();
    verified.commit(&unsent);
    verified_platform.now_unix_seconds = 200;
    try std.testing.expectEqual(Use{ .wait = 1 }, verified.authorization().use());

    // A login from the verified session needs the person to finish it.
    verified_platform.now_unix_seconds = 100;
    _ = TestSupport.commitBeginLoginWithoutDispatch(&verified);
    try std.testing.expect(verified.authorization() == .authorizing);
    try std.testing.expectEqual(Use{ .stop = .sign_in }, verified.authorization().use());
    var cancel = switch (verified.prepareCommand(.cancel_operation)) {
        .prepared => |prepared| prepared,
        else => return error.TestUnexpectedResult,
    };
    defer cancel.deinit();
    _ = cancel.transition.takeEffect();
    verified.commit(&cancel);
    try std.testing.expectEqual(Use{ .ready = generation }, verified.authorization().use());

    // Logging out keeps `authenticated` until the deletion is committed, but
    // its credential is already gone.
    var logout = switch (verified.prepareCommand(.logout)) {
        .prepared => |prepared| prepared,
        else => return error.TestUnexpectedResult,
    };
    defer logout.deinit();
    try std.testing.expect(verified.admitEffect(&logout));
    verified.commit(&logout);
    try std.testing.expectEqual(Use{ .ready = generation }, verified.authorization().use());
    verified.dispatchCommitted();
    try std.testing.expectEqual(contract.AccountState.authenticated, verified.view().state);
    try std.testing.expectEqual(Use{ .stop = .sign_in }, verified.authorization().use());
    var logged_out = switch (verified.prepareNextCompletion().?) {
        .prepared => |prepared| prepared,
        else => return error.TestUnexpectedResult,
    };
    defer logged_out.deinit();
    verified.commit(&logged_out);
    try std.testing.expect(verified.authorization() == .signed_out);

    for ([_]enum { automation, unavailable, shutdown }{ .automation, .unavailable, .shutdown }) |ending| {
        var other_transport: RuntimeTestTransport = .{};
        var other = try initRuntimeForUnitTest(&other_transport);
        defer other.deinit();
        var prepared = switch (ending) {
            .automation => other.prepareAutomationStart(),
            .unavailable => other.prepareStartUnavailable(),
            .shutdown => other.prepareShutdown(),
        };
        defer prepared.deinit();
        _ = prepared.transition.takeEffect();
        other.commit(&prepared);
        try std.testing.expect(other.authorization() == .signed_out);
    }
}

test "the beat starts a due renewal and no query does" {
    var transport: RotationTestTransport = .{};
    var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId(), transport.port(), TestSupport.loopbackEndpoint(), .{ .context = &transport, .notify_fn = runtimeTestWake });
    var platform: TestSupport.Platform = .{ .now_unix_seconds = 100 };
    try platform.setStoredRefreshToken("refresh-token");
    defer {
        TestSupport.detachPlatform(&runtime);
        runtime.deinit();
    }
    TestSupport.attachPlatform(&runtime, &platform);
    // A token that lives ten seconds is not renewed before it is thirty old.
    var authenticated = try TestSupport.prepareAuthenticatedAndSchedule(&runtime, "account-1", "Metask", "access-token", "refresh-token", 110);
    defer authenticated.deinit();
    runtime.commit(&authenticated);
    try std.testing.expect(runtime.prepareDue() == null);
    try std.testing.expectEqual(@as(usize, 1), platform.timer_start_count);
    try std.testing.expectEqual(beat_interval_ns, platform.last_timer_interval_ns);
    const generation = runtime.authorization_generation;
    platform.now_unix_seconds = 129;
    try std.testing.expect(runtime.prepareDue() == null);
    // However late the beat, a query only reads.
    platform.now_unix_seconds = 230;
    for (0..3) |_| try std.testing.expectEqual(contract.Authorization.Use{ .wait = 0 }, runtime.authorization().use());
    try std.testing.expect(runtime.account.activeAttempt() == null);
    try std.testing.expectEqual(@as(usize, 1), platform.timer_start_count);

    try startDueRenewal(&runtime);
    // An attempt underway is the recovery; nothing starts beside it.
    try std.testing.expect(runtime.prepareDue() == null);
    try finishTestRefresh(&runtime);
    try std.testing.expectEqual(contract.Authorization.Use{ .ready = runtime.authorization_generation }, runtime.authorization().use());
    try std.testing.expect(runtime.authorization_generation != generation);
    try std.testing.expectEqual(@as(u64, 1), runtime.renewal_epoch);
    try std.testing.expectEqual(@as(usize, 1), transport.calls);
    // The new token is due a minute and a half before its own expiry.
    platform.now_unix_seconds = 3739;
    try std.testing.expect(runtime.prepareDue() == null);
    platform.now_unix_seconds = 3740;
    try startDueRenewal(&runtime);
    try finishTestRefresh(&runtime);
    try std.testing.expectEqual(@as(usize, 1), platform.timer_start_count);
}

test "a renewal missed during a login starts when the login ends" {
    const Ending = enum { cancelled, callback_failed, deadline };
    for ([_]Ending{ .cancelled, .callback_failed, .deadline }) |ending| {
        var transport: RuntimeTestTransport = .{};
        var runtime = try initRuntimeForUnitTest(&transport);
        var platform: TestSupport.Platform = .{ .now_unix_seconds = 100 };
        TestSupport.attachPlatform(&runtime, &platform);
        defer {
            TestSupport.detachPlatform(&runtime);
            runtime.deinit();
        }
        var authenticated = try TestSupport.prepareAuthenticatedAndSchedule(&runtime, "account-1", "Metask", "access-token", "refresh-token", 200);
        defer authenticated.deinit();
        runtime.commit(&authenticated);

        const login = TestSupport.commitBeginLoginWithoutDispatch(&runtime);
        platform.now_unix_seconds = 140;
        try std.testing.expect(runtime.prepareDue() == null);
        try std.testing.expect(runtime.authorization() == .authorizing);
        switch (ending) {
            .cancelled => {
                var cancel = switch (runtime.prepareCommand(.cancel_operation)) {
                    .prepared => |prepared| prepared,
                    else => return error.TestUnexpectedResult,
                };
                defer cancel.deinit();
                _ = cancel.transition.takeEffect();
                runtime.commit(&cancel);
            },
            .callback_failed, .deadline => {
                var result: login_attempt.WorkerResult = .{ .failed = .fromCode(if (ending == .deadline)
                    .deadline_exceeded
                else
                    .oauth_callback_rejected) };
                runtime.effects.loginSink().publish(login, &result);
                var failed = switch (runtime.prepareNextCompletion().?) {
                    .prepared => |prepared| prepared,
                    else => return error.TestUnexpectedResult,
                };
                defer failed.deinit();
                runtime.commit(&failed);
                runtime.dispatchCommitted();
            },
        }
        try std.testing.expectEqual(contract.AccountState.authenticated, runtime.view().state);
        try std.testing.expect(runtime.authorization() == .available);
        var refresh = runtime.prepareDue() orelse return error.TestUnexpectedResult;
        defer refresh.deinit();
        try std.testing.expect(refresh.transition.takeEffect().? == .refresh_token);
    }
}

test "a login that replaced the token leaves no renewal of the old one" {
    var transport: RotationTestTransport = .{ .identity_failure = true };
    var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId(), transport.port(), TestSupport.loopbackEndpoint(), .{ .context = &transport, .notify_fn = runtimeTestWake });
    var platform: TestSupport.Platform = .{ .now_unix_seconds = 100 };
    TestSupport.attachPlatform(&runtime, &platform);
    defer {
        TestSupport.detachPlatform(&runtime);
        runtime.deinit();
    }
    var authenticated = try TestSupport.prepareAuthenticatedAndSchedule(&runtime, "account-1", "Metask", "access-token", "refresh-token", 200);
    defer authenticated.deinit();
    runtime.commit(&authenticated);
    try std.testing.expect(runtime.prepareDue() == null);
    _ = TestSupport.commitBeginLoginWithoutDispatch(&runtime);
    try std.testing.expect(runtime.renew_at != null);
    var input = try TestSupport.exchangeInput(std.testing.allocator, "authorization-code");
    defer input.deinit();
    var exchange = TestSupport.prepareLoginExchange(&runtime, &input);
    defer exchange.deinit();
    try std.testing.expect(runtime.admitEffect(&exchange));
    runtime.commit(&exchange);
    runtime.dispatchCommitted();
    runtime.effects.network_attempt.join();
    var replaced = switch (runtime.prepareNextCompletion().?) {
        .prepared => |prepared| prepared,
        else => return error.TestUnexpectedResult,
    };
    defer replaced.deinit();
    try std.testing.expect(runtime.admitEffect(&replaced));
    runtime.commit(&replaced);
    try std.testing.expect(runtime.renew_at == null);
    try std.testing.expectEqual(@as(usize, 1), platform.timer_cancel_count);
    runtime.dispatchCommitted();
    // Its identity could not be confirmed, so no session is left to renew.
    try finishTestRefresh(&runtime);
    try std.testing.expectEqual(contract.AccountState.signed_out, runtime.view().state);
    platform.now_unix_seconds = 4000;
    try std.testing.expect(runtime.prepareDue() == null);
}

test "either clock ends a token and starts its renewal" {
    const Clocks = struct { wall: i64, boot: i64 };
    // The wall clock set back, then set forward.
    for ([_]Clocks{ .{ .wall = 100, .boot = 600 }, .{ .wall = 1100, .boot = 500 } }) |clocks| {
        var transport: RuntimeTestTransport = .{};
        var runtime = try initRuntimeForUnitTest(&transport);
        var platform: TestSupport.Platform = .{ .now_unix_seconds = 1000, .boot_seconds = 500 };
        TestSupport.attachPlatform(&runtime, &platform);
        defer {
            TestSupport.detachPlatform(&runtime);
            runtime.deinit();
        }
        var authenticated = try TestSupport.prepareAuthenticatedAndSchedule(&runtime, "account-1", "Metask", "access-token", "refresh-token", 1100);
        defer authenticated.deinit();
        runtime.commit(&authenticated);
        try std.testing.expect(runtime.prepareDue() == null);
        platform.now_unix_seconds = clocks.wall;
        platform.boot_seconds = clocks.boot;
        try std.testing.expect((try runtime.credential()) == null);
        try std.testing.expect(runtime.authorization() == .recovering);
        var refresh = runtime.prepareDue() orelse return error.TestUnexpectedResult;
        defer refresh.deinit();
        try std.testing.expect(refresh.transition.takeEffect().? == .refresh_token);
    }
}

test "a session whose logout kept its credential ends at its renewal" {
    var transport: RuntimeTestTransport = .{};
    var runtime = try initRuntimeForUnitTest(&transport);
    var platform: TestSupport.Platform = .{ .now_unix_seconds = 100, .credential_delete_fails = true };
    try platform.setStoredRefreshToken("refresh-token");
    TestSupport.attachPlatform(&runtime, &platform);
    defer {
        TestSupport.detachPlatform(&runtime);
        runtime.deinit();
    }
    var authenticated = try TestSupport.prepareAuthenticatedAndSchedule(&runtime, "account-1", "Metask", "access-token", "refresh-token", 200);
    defer authenticated.deinit();
    runtime.commit(&authenticated);
    var logout = switch (runtime.prepareCommand(.logout)) {
        .prepared => |prepared| prepared,
        else => return error.TestUnexpectedResult,
    };
    defer logout.deinit();
    try std.testing.expect(runtime.admitEffect(&logout));
    runtime.commit(&logout);
    runtime.dispatchCommitted();
    try finishTestRefresh(&runtime);
    try std.testing.expectEqual(contract.AccountState.authenticated, runtime.view().state);
    try std.testing.expect(runtime.refresh_blocked);
    // Its token still works, but nothing may renew it.
    try std.testing.expect(runtime.authorization() == .available);
    try std.testing.expect(runtime.prepareCommand(.retry_refresh) == .rejected);
    platform.now_unix_seconds = 129;
    try std.testing.expect(runtime.prepareDue() == null);
    platform.now_unix_seconds = 130;
    var ended = runtime.prepareDue() orelse return error.TestUnexpectedResult;
    defer ended.deinit();
    runtime.commit(&ended);
    try std.testing.expectEqual(contract.AccountState.signed_out, runtime.view().state);
    try std.testing.expectEqual(contract.ErrorCode.token_refresh_failed, runtime.view().error_code);
    try std.testing.expect(!runtime.credentials.available());
    try std.testing.expect(runtime.prepareDue() == null);
    try std.testing.expectEqual(@as(usize, 0), transport.calls);
}

const RotationTestTransport = struct {
    identity_failure: bool = false,
    unsent_failures_remaining: usize = 0,
    calls: usize = 0,
    fn port(self: *@This()) metask_client.Transport {
        return .{ .context = self, .perform_fn = perform, .retire_fn = metask_client.retireNothing };
    }
    fn perform(context: *anyopaque, request: metask_client.Request, output: []u8) metask_client.TransportError!metask_client.Response {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.calls += 1;
        if (request.kind == .refresh_token and self.unsent_failures_remaining != 0) {
            self.unsent_failures_remaining -= 1;
            return error.NetworkNotSent;
        }
        const body = if (request.kind == .refresh_token or request.kind == .exchange_code)
            "{\"access_token\":\"new-access\",\"refresh_token\":\"new-refresh\",\"token_type\":\"Bearer\",\"expires_in\":3600}"
        else if (request.kind == .userinfo and self.identity_failure)
            "{\"error\":\"invalid_token\"}"
        else
            return error.ProtocolFailed;
        @memcpy(output[0..body.len], body);
        return .{ .status = if (request.kind == .userinfo) 401 else 200, .body = output[0..body.len] };
    }
};

const ConfirmTransport = struct {
    refresh: enum { unsent, lost, answered } = .unsent,
    identity: enum { unavailable, revoked, answered } = .answered,
    refreshes: usize = 0,
    identities: usize = 0,

    fn runtimeFor(self: *@This()) Runtime {
        return Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId(), .{ .context = self, .perform_fn = perform, .retire_fn = metask_client.retireNothing }, TestSupport.loopbackEndpoint(), .{ .context = self, .notify_fn = runtimeTestWake });
    }

    fn perform(context: *anyopaque, request: metask_client.Request, output: []u8) metask_client.TransportError!metask_client.Response {
        const self: *@This() = @ptrCast(@alignCast(context));
        const body = switch (request.kind) {
            .refresh_token, .exchange_code => blk: {
                self.refreshes += 1;
                switch (self.refresh) {
                    .unsent => return error.NetworkNotSent,
                    .lost => return error.NetworkFailed,
                    .answered => {},
                }
                // A rotation always brings another refresh token.
                break :blk if (self.refreshes % 2 == 1)
                    "{\"access_token\":\"new-access\",\"refresh_token\":\"new-refresh\",\"token_type\":\"Bearer\",\"expires_in\":3600}"
                else
                    "{\"access_token\":\"next-access\",\"refresh_token\":\"next-refresh\",\"token_type\":\"Bearer\",\"expires_in\":3600}";
            },
            .userinfo => blk: {
                self.identities += 1;
                break :blk switch (self.identity) {
                    .unavailable => return .{ .status = 503, .body = "" },
                    .revoked => "{\"error\":\"authorization_revoked\"}",
                    .answered => "{\"sub\":\"account-1\",\"name\":\"Metask\",\"client_id\":\"metawork\",\"authorization_id\":\"authorization-1\"}",
                };
            },
            else => return error.ProtocolFailed,
        };
        @memcpy(output[0..body.len], body);
        return .{ .status = if (request.kind == .userinfo and self.identity == .revoked) 401 else 200, .body = output[0..body.len] };
    }
};

/// Starts over a stored login and lets its first confirmation end.
fn startStoredLogin(runtime: *Runtime, platform: *TestSupport.Platform) !void {
    try platform.setStoredRefreshToken("refresh-token");
    var start = runtime.prepareStart(platform.ports());
    defer start.deinit();
    try std.testing.expect(runtime.takeRefreshAfterCommit(&start));
    runtime.commit(&start);
    var refresh = runtime.prepareRestoredRefresh();
    defer refresh.deinit();
    try std.testing.expect(runtime.admitEffect(&refresh));
    runtime.commit(&refresh);
    runtime.dispatchCommitted();
    try settleAttempt(runtime);
}

fn settleAttempt(runtime: *Runtime) !void {
    while (runtime.account.activeAttempt() != null) {
        runtime.effects.network_attempt.join();
        var next = switch (runtime.prepareNextCompletion().?) {
            .prepared => |prepared| prepared,
            else => return error.TestUnexpectedResult,
        };
        defer next.deinit();
        try std.testing.expect(runtime.admitEffect(&next));
        runtime.commit(&next);
        runtime.dispatchCommitted();
    }
}

fn expectUnconfirmed(runtime: *Runtime, error_code: contract.ErrorCode) !void {
    try std.testing.expectEqual(contract.AccountState.checking, runtime.view().state);
    try std.testing.expectEqual(error_code, runtime.view().error_code);
    try std.testing.expect(runtime.view().can_retry);
    try std.testing.expect(runtime.authorization() == .checking);
}

test "a stored login that cannot be reached is confirmed ever less often" {
    var transport: ConfirmTransport = .{};
    var runtime = transport.runtimeFor();
    var platform: TestSupport.Platform = .{ .now_unix_seconds = 100 };
    defer {
        TestSupport.detachPlatform(&runtime);
        runtime.deinit();
    }
    try startStoredLogin(&runtime, &platform);
    var now: i64 = 100;
    for ([_]i64{ 30, 60, 120, 300, 300 }, 1..) |delay, failures| {
        try expectUnconfirmed(&runtime, .metask_service_unavailable);
        try std.testing.expectEqual(contract.Authorization.Use{ .wait = failures }, runtime.authorization().use());
        try std.testing.expect(!runtime.refresh_blocked and platform.refresh_marker == null);
        now += delay;
        platform.now_unix_seconds = now - 1;
        try std.testing.expect(runtime.prepareDue() == null);
        platform.now_unix_seconds = now;
        try startDueRenewal(&runtime);
        try std.testing.expectEqual(contract.ErrorCode.metask_service_unavailable, runtime.view().error_code);
        try std.testing.expect(!runtime.view().can_retry);
        try settleAttempt(&runtime);
    }
    try std.testing.expectEqual(@as(usize, 6), transport.refreshes);
    // Someone is there for it: at once when the last attempt is thirty
    // seconds old, and patient from the start again.
    platform.now_unix_seconds = now + 29;
    runtime.expedite();
    try std.testing.expect(runtime.prepareDue() == null);
    platform.now_unix_seconds = now + 30;
    try startDueRenewal(&runtime);
    try settleAttempt(&runtime);
    platform.now_unix_seconds = now + 60;
    transport.refresh = .answered;
    try startDueRenewal(&runtime);
    try settleAttempt(&runtime);
    try std.testing.expectEqual(contract.AccountState.authenticated, runtime.view().state);
    try std.testing.expectEqual(contract.ErrorCode.none, runtime.view().error_code);
    try std.testing.expect(runtime.authorization() == .available);
    try std.testing.expectEqual(@as(usize, 1), platform.credential_write_count);
    try std.testing.expectEqual(@as(usize, 0), runtime.confirm_failures);
}

test "a stored login whose confirmation was sent and lost is signed out for good" {
    var transport: ConfirmTransport = .{};
    var runtime = transport.runtimeFor();
    var platform: TestSupport.Platform = .{ .now_unix_seconds = 100 };
    defer {
        TestSupport.detachPlatform(&runtime);
        runtime.deinit();
    }
    try startStoredLogin(&runtime, &platform);
    try expectUnconfirmed(&runtime, .metask_service_unavailable);
    transport.refresh = .lost;
    platform.now_unix_seconds = 130;
    try startDueRenewal(&runtime);
    try settleAttempt(&runtime);
    try std.testing.expectEqual(contract.AccountState.signed_out, runtime.view().state);
    try std.testing.expect(runtime.refresh_blocked and platform.refresh_marker != null);
    runtime.expedite();
    for ([_]i64{ 160, 1000, 100_000 }) |now| {
        platform.now_unix_seconds = now;
        try std.testing.expect(runtime.prepareDue() == null);
    }
    try std.testing.expectEqual(@as(usize, 2), transport.refreshes);
}

test "an exchanged token is kept while its identity cannot be reached" {
    for ([_]bool{ true, false }) |valid| {
        var transport: ConfirmTransport = .{ .refresh = .answered, .identity = .unavailable };
        var runtime = transport.runtimeFor();
        var platform: TestSupport.Platform = .{ .now_unix_seconds = 100 };
        defer {
            TestSupport.detachPlatform(&runtime);
            runtime.deinit();
        }
        try startStoredLogin(&runtime, &platform);
        try expectUnconfirmed(&runtime, .metask_service_unavailable);
        try std.testing.expectEqualStrings("new-refresh", platform.refresh_token[0..platform.refresh_token_len.?]);
        transport.identity = if (valid) .answered else .revoked;
        platform.now_unix_seconds = 130;
        try startDueRenewal(&runtime);
        try settleAttempt(&runtime);
        try std.testing.expectEqual(@as(usize, 1), transport.refreshes);
        try std.testing.expectEqual(@as(usize, 2), transport.identities);
        if (valid) {
            try std.testing.expect(runtime.authorization() == .available);
        } else {
            try std.testing.expectEqual(contract.AccountState.signed_out, runtime.view().state);
            try std.testing.expectEqual(contract.ErrorCode.metask_unauthorized, runtime.view().error_code);
            try std.testing.expect(platform.refresh_token_len == null);
        }
    }
    // Once the exchanged token itself is due, it is exchanged before it is used.
    var transport: ConfirmTransport = .{ .refresh = .answered, .identity = .unavailable };
    var runtime = transport.runtimeFor();
    var platform: TestSupport.Platform = .{ .now_unix_seconds = 100 };
    defer {
        TestSupport.detachPlatform(&runtime);
        runtime.deinit();
    }
    try startStoredLogin(&runtime, &platform);
    platform.now_unix_seconds = 3610;
    try startDueRenewal(&runtime);
    try settleAttempt(&runtime);
    try std.testing.expectEqual(@as(usize, 2), transport.refreshes);
    try expectUnconfirmed(&runtime, .metask_service_unavailable);
}

test "a login that cannot be confirmed can be retried or replaced and is kept otherwise" {
    const Ending = enum { cancelled, callback_failed, exchange_failed, identity_failed };
    for ([_]Ending{ .cancelled, .callback_failed, .exchange_failed, .identity_failed }) |ending| {
        var transport: ConfirmTransport = .{};
        var runtime = transport.runtimeFor();
        var platform: TestSupport.Platform = .{ .now_unix_seconds = 100 };
        defer {
            TestSupport.detachPlatform(&runtime);
            runtime.deinit();
        }
        // Nothing to retry or replace before it was ever tried.
        try std.testing.expect(runtime.prepareCommand(.retry_refresh) == .rejected);
        try std.testing.expect(runtime.prepareCommand(.begin_login) == .rejected);
        try startStoredLogin(&runtime, &platform);
        platform.now_unix_seconds = 130;
        try startDueRenewal(&runtime);
        try std.testing.expect(runtime.prepareCommand(.retry_refresh) == .rejected);
        try std.testing.expect(runtime.prepareCommand(.begin_login) == .rejected);
        try settleAttempt(&runtime);
        try std.testing.expectEqual(@as(i64, 190), runtime.renew_at.?.boot);
        // At once, and patient from the start again.
        var retry = switch (runtime.prepareCommand(.retry_refresh)) {
            .prepared => |prepared| prepared,
            else => return error.TestUnexpectedResult,
        };
        defer retry.deinit();
        try std.testing.expect(runtime.admitEffect(&retry));
        runtime.commit(&retry);
        runtime.dispatchCommitted();
        try settleAttempt(&runtime);
        try std.testing.expectEqual(@as(usize, 3), transport.refreshes);
        try std.testing.expectEqual(@as(i64, 160), runtime.renew_at.?.boot);

        const login = TestSupport.commitBeginLoginWithoutDispatch(&runtime);
        try std.testing.expect(runtime.authorization() == .authorizing);
        platform.now_unix_seconds = 200;
        try std.testing.expect(runtime.prepareDue() == null);
        switch (ending) {
            .cancelled => {
                var cancel = switch (runtime.prepareCommand(.cancel_operation)) {
                    .prepared => |prepared| prepared,
                    else => return error.TestUnexpectedResult,
                };
                defer cancel.deinit();
                _ = cancel.transition.takeEffect();
                runtime.commit(&cancel);
                try expectUnconfirmed(&runtime, .user_cancelled);
            },
            .callback_failed => {
                var result: login_attempt.WorkerResult = .{ .failed = .fromCode(.oauth_callback_rejected) };
                runtime.effects.loginSink().publish(login, &result);
                var failed = switch (runtime.prepareNextCompletion().?) {
                    .prepared => |prepared| prepared,
                    else => return error.TestUnexpectedResult,
                };
                defer failed.deinit();
                runtime.commit(&failed);
                try expectUnconfirmed(&runtime, .oauth_callback_rejected);
            },
            .exchange_failed, .identity_failed => {
                if (ending == .identity_failed) transport.refresh = .answered;
                transport.identity = .unavailable;
                var input = try TestSupport.exchangeInput(std.testing.allocator, "authorization-code");
                defer input.deinit();
                var exchange = TestSupport.prepareLoginExchange(&runtime, &input);
                defer exchange.deinit();
                try std.testing.expect(runtime.admitEffect(&exchange));
                runtime.commit(&exchange);
                runtime.dispatchCommitted();
                try settleAttempt(&runtime);
                if (ending == .exchange_failed) try expectUnconfirmed(&runtime, .metask_service_unavailable);
            },
        }
        if (ending == .identity_failed) {
            // The new token replaced the stored one, so nothing is kept.
            try std.testing.expectEqual(contract.AccountState.signed_out, runtime.view().state);
            try std.testing.expect(runtime.prepareDue() == null);
            continue;
        }
        try std.testing.expectEqual(@as(i64, 160), runtime.renew_at.?.boot);
        const refreshes = transport.refreshes;
        try startDueRenewal(&runtime);
        try settleAttempt(&runtime);
        try std.testing.expectEqual(refreshes + 1, transport.refreshes);
    }
}

test "failed replacement save retains matching marker and forbids another attempt" {
    var transport: RotationTestTransport = .{};
    var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId(), transport.port(), TestSupport.loopbackEndpoint(), .{ .context = &transport, .notify_fn = runtimeTestWake });
    var platform: TestSupport.Platform = .{ .credential_write_fails = true };
    try platform.setStoredRefreshToken("refresh-token");
    defer {
        TestSupport.detachPlatform(&runtime);
        runtime.deinit();
    }
    try beginTestRefresh(&runtime, &platform);
    try finishTestRefresh(&runtime);
    try std.testing.expect(runtime.refresh_blocked);
    try std.testing.expectEqual(contract.AccountState.signed_out, runtime.view().state);
    try std.testing.expectEqual(contract.ErrorCode.token_refresh_failed, runtime.view().error_code);
    try std.testing.expectEqualStrings("credential_store_write_failed", runtime.view().safe_diagnostic);
    try std.testing.expect(!runtime.credentials.available());
    try std.testing.expectEqualStrings("refresh-token", platform.refresh_token[0..platform.refresh_token_len.?]);
    try std.testing.expect(runtime.prepareCommand(.retry_refresh) == .rejected);
    var restored = try credential_store.restore(std.testing.allocator, platform.ports().credentials);
    defer restored.deinit();
    try std.testing.expect(restored == .blocked);
    try std.testing.expectEqual(@as(usize, 1), transport.calls);
}

test "stale unauthorized cannot erase a replacement credential" {
    var transport: RuntimeTestTransport = .{};
    var runtime = try initRuntimeForUnitTest(&transport);
    var platform: TestSupport.Platform = .{};
    TestSupport.attachPlatform(&runtime, &platform);
    defer {
        TestSupport.detachPlatform(&runtime);
        runtime.deinit();
    }
    var auth = try TestSupport.prepareAuthenticated(&runtime, "account-1", "Metask", "access-token", "refresh-token", 200);
    defer auth.deinit();
    runtime.commit(&auth);
    var refresh = TestSupport.prepareTokenRefreshWithoutEffect(&runtime);
    defer refresh.deinit();
    runtime.commit(&refresh);
    const active = runtime.account.activeAttempt().?;
    try platform.setStoredRefreshToken("new-refresh");
    try runtime.credentials.installStored(runtime.allocator, "new-access", "new-refresh", 300, "account-1");
    runtime.bumpAuthorizationGeneration();
    var stale: state_impl.WorkerCompletion = .{ .attempt_id = active, .payload = .{ .failed = .fromCode(.metask_unauthorized) } };
    try std.testing.expect(runtime.prepareWorkerCompletion(&stale, false) == .ignored_stale);
    stale.attempt_id = active + 1;
    try std.testing.expect(runtime.prepareWorkerCompletion(&stale, false) == .ignored_stale);
    try std.testing.expectEqualStrings("new-refresh", platform.refresh_token[0..platform.refresh_token_len.?]);
}

test "userinfo invalid token preserves the newly committed restore credential" {
    var transport: RotationTestTransport = .{ .identity_failure = true };
    var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId(), transport.port(), TestSupport.loopbackEndpoint(), .{ .context = &transport, .notify_fn = runtimeTestWake });
    var platform: TestSupport.Platform = .{};
    try platform.setStoredRefreshToken("refresh-token");
    defer {
        TestSupport.detachPlatform(&runtime);
        runtime.deinit();
    }
    var start = runtime.prepareStart(platform.ports());
    defer start.deinit();
    runtime.commit(&start);
    var refresh = runtime.prepareRestoredRefresh();
    defer refresh.deinit();
    try std.testing.expect(runtime.admitEffect(&refresh));
    runtime.commit(&refresh);
    runtime.dispatchCommitted();
    runtime.effects.network_attempt.join();
    var identity = switch (runtime.prepareNextCompletion().?) {
        .prepared => |p| p,
        else => return error.TestUnexpectedResult,
    };
    defer identity.deinit();
    try std.testing.expect(runtime.admitEffect(&identity));
    runtime.commit(&identity);
    runtime.dispatchCommitted();
    try finishTestRefresh(&runtime);
    try std.testing.expectEqualStrings("new-refresh", platform.refresh_token[0..platform.refresh_token_len.?]);
    try std.testing.expectEqual(contract.AccountState.signed_out, runtime.view().state);
    try std.testing.expect(platform.refresh_marker == null);
    try std.testing.expectEqual(@as(usize, 2), transport.calls);
}

test "explicit nonconsumption restores permission only after marker deletion" {
    const RequestFailure = struct {
        fn perform(_: *anyopaque, _: metask_client.Request, output: []u8) metask_client.TransportError!metask_client.Response {
            const body = "{\"error\":\"invalid_client\"}";
            @memcpy(output[0..body.len], body);
            return .{ .status = 401, .body = output[0..body.len] };
        }
    };
    for ([_]bool{ false, true }) |delete_fails| {
        var context: u8 = 0;
        var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId(), .{ .context = &context, .perform_fn = RequestFailure.perform, .retire_fn = metask_client.retireNothing }, TestSupport.loopbackEndpoint(), .{ .context = &context, .notify_fn = runtimeTestWake });
        var platform: TestSupport.Platform = .{ .marker_delete_fails = delete_fails };
        try platform.setStoredRefreshToken("refresh-token");
        defer {
            TestSupport.detachPlatform(&runtime);
            runtime.deinit();
        }
        try beginTestRefresh(&runtime, &platform);
        try finishTestRefresh(&runtime);
        try std.testing.expectEqualStrings("refresh-token", platform.refresh_token[0..platform.refresh_token_len.?]);
        try std.testing.expectEqual(delete_fails, runtime.refresh_blocked);
        try std.testing.expectEqual(delete_fails, platform.refresh_marker != null);
        try std.testing.expect(runtime.renew_at == null);
        try std.testing.expectEqual(@as(usize, 0), platform.credential_write_count);
    }
}

test "committed replacement remains available after marker cleanup failure" {
    var transport: RotationTestTransport = .{};
    var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId(), transport.port(), TestSupport.loopbackEndpoint(), .{ .context = &transport, .notify_fn = runtimeTestWake });
    var platform: TestSupport.Platform = .{ .marker_delete_fails = true };
    try platform.setStoredRefreshToken("refresh-token");
    defer {
        TestSupport.detachPlatform(&runtime);
        runtime.deinit();
    }
    try beginTestRefresh(&runtime, &platform);
    runtime.effects.network_attempt.join();
    var completed = switch (runtime.prepareNextCompletion().?) {
        .prepared => |p| p,
        else => return error.TestUnexpectedResult,
    };
    defer completed.deinit();
    runtime.commit(&completed);
    try std.testing.expect(!runtime.refresh_blocked);
    try std.testing.expectEqual(@as(usize, 1), platform.credential_write_count);
    var lease = (try runtime.credential()).?;
    defer lease.deinit();
    try std.testing.expectEqualStrings("new-access", lease.access_token);
    var restored = try credential_store.restore(std.testing.allocator, platform.ports().credentials);
    defer restored.deinit();
    try std.testing.expectEqualStrings("new-refresh", restored.account.refresh_token.view());
}

test "shutdown does not retry a rotation that already failed storage" {
    var transport: RotationTestTransport = .{};
    var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId(), transport.port(), TestSupport.loopbackEndpoint(), .{ .context = &transport, .notify_fn = runtimeTestWake });
    var platform: TestSupport.Platform = .{ .credential_write_fails = true };
    try platform.setStoredRefreshToken("refresh-token");
    defer runtime.deinit();
    try beginTestRefresh(&runtime, &platform);
    try finishTestRefresh(&runtime);
    try std.testing.expectEqual(@as(usize, 1), platform.credential_write_count);
    var stopped = runtime.prepareShutdown();
    defer stopped.deinit();
    try std.testing.expect(runtime.admitEffect(&stopped));
    runtime.commit(&stopped);
    runtime.dispatchCommitted();
    try std.testing.expectEqual(@as(usize, 1), platform.credential_write_count);
    try std.testing.expect(platform.refresh_marker != null);
    try std.testing.expectEqual(@as(usize, 1), transport.calls);
}

test "refresh not sent clears blocking marker and permits retry and cold restore" {
    for ([_]metask_client.TransportError{ error.NetworkNotSent, error.CancelledNotSent, error.DeadlineExceededNotSent }) |failure| {
        for ([_]bool{ false, true }) |marker_delete_fails| {
            var transport: RuntimeTestTransport = .{ .failure = failure };
            var runtime = try initRuntimeForUnitTest(&transport);
            var platform: TestSupport.Platform = .{ .marker_delete_fails = marker_delete_fails };
            try platform.setStoredRefreshToken("refresh-token");
            defer {
                TestSupport.detachPlatform(&runtime);
                runtime.deinit();
            }
            try beginTestRefresh(&runtime, &platform);
            try finishTestRefresh(&runtime);
            try std.testing.expectEqual(@as(usize, 1), transport.calls);
            try std.testing.expectEqual(marker_delete_fails, runtime.renew_at == null);
            try std.testing.expectEqual(marker_delete_fails, runtime.refresh_blocked);
            try std.testing.expectEqual(marker_delete_fails, platform.refresh_marker != null);
            try std.testing.expectEqualStrings("refresh-token", platform.refresh_token[0..platform.refresh_token_len.?]);
            if (marker_delete_fails) {
                try std.testing.expectEqual(contract.ErrorCode.credential_store_delete_failed, runtime.view().error_code);
                try std.testing.expect(runtime.prepareCommand(.retry_refresh) == .rejected);
            } else {
                try std.testing.expectEqual(contract.AccountState.authenticated, runtime.view().state);
                try std.testing.expectEqual(metask_client.errorCode(switch (failure) {
                    error.NetworkNotSent => error.ServiceUnavailable,
                    error.CancelledNotSent => error.Cancelled,
                    error.DeadlineExceededNotSent => error.DeadlineExceeded,
                    else => unreachable,
                }), runtime.view().error_code);
                var retry = switch (runtime.prepareCommand(.retry_refresh)) {
                    .prepared => |value| value,
                    else => return error.TestUnexpectedResult,
                };
                defer retry.deinit();
                platform.now_unix_seconds = 130;
                var due = runtime.prepareDue() orelse return error.TestUnexpectedResult;
                defer due.deinit();
                try std.testing.expect(due.transition.takeEffect().? == .refresh_token);
            }
            var restarted = try initRuntimeForUnitTest(&transport);
            defer {
                TestSupport.detachPlatform(&restarted);
                restarted.deinit();
            }
            var restored = restarted.prepareStart(platform.ports());
            defer restored.deinit();
            restarted.commit(&restored);
            try std.testing.expectEqual(!marker_delete_fails, restarted.takeRefreshAfterCommit(&restored));
            try std.testing.expectEqual(@as(usize, 1), transport.calls);
        }
    }
}

test "unsent refresh retries on the beat and recovers after access expiry" {
    var transport: RotationTestTransport = .{ .unsent_failures_remaining = 2 };
    var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId(), transport.port(), TestSupport.loopbackEndpoint(), .{ .context = &transport, .notify_fn = runtimeTestWake });
    var platform: TestSupport.Platform = .{ .now_unix_seconds = 140 };
    try platform.setStoredRefreshToken("refresh-token");
    defer {
        TestSupport.detachPlatform(&runtime);
        runtime.deinit();
    }
    try beginTestRefresh(&runtime, &platform);
    try finishTestRefresh(&runtime);

    for ([_]i64{ 170, 200 }) |now| {
        platform.now_unix_seconds = now;
        if (now == 200) {
            try std.testing.expect((try runtime.credential()) == null);
            try std.testing.expectEqual(contract.Authorization.Use{ .wait = 2 }, runtime.authorization().use());
        }
        platform.now_unix_seconds = now - 1;
        try std.testing.expect(runtime.prepareDue() == null);
        platform.now_unix_seconds = now;
        try startDueRenewal(&runtime);
        try finishTestRefresh(&runtime);
        if (now == 170) try std.testing.expect(!runtime.refresh_blocked);
    }
    try std.testing.expectEqual(@as(usize, 3), transport.calls);
    try std.testing.expectEqual(@as(usize, 1), platform.timer_start_count);
    try std.testing.expectEqual(@as(usize, 1), platform.credential_write_count);
    try std.testing.expectEqualStrings("new-refresh", platform.refresh_token[0..platform.refresh_token_len.?]);
    try std.testing.expect(platform.refresh_marker == null);
    try std.testing.expectEqual(contract.AccountState.authenticated, runtime.view().state);
    try std.testing.expectEqual(contract.ErrorCode.none, runtime.view().error_code);
    var lease = (try runtime.credential()).?;
    defer lease.deinit();
    try std.testing.expectEqualStrings("new-access", lease.access_token);
    try std.testing.expectEqual(@as(usize, 0), platform.authorization_open_count);
}

test "a beat that cannot start is reported once and delays nothing due" {
    var transport: RuntimeTestTransport = .{};
    var runtime = try initRuntimeForUnitTest(&transport);
    var platform: TestSupport.Platform = .{ .timer_start_fails = true };
    try platform.setStoredRefreshToken("refresh-token");
    TestSupport.attachPlatform(&runtime, &platform);
    defer {
        TestSupport.detachPlatform(&runtime);
        runtime.deinit();
    }
    var authenticated = try TestSupport.prepareAuthenticatedAndSchedule(&runtime, "account-1", "Metask", "access-token", "refresh-token", 200);
    defer authenticated.deinit();
    runtime.commit(&authenticated);
    var failed = runtime.prepareDue() orelse return error.TestUnexpectedResult;
    defer failed.deinit();
    runtime.commit(&failed);
    try std.testing.expectEqual(contract.AccountState.authenticated, runtime.view().state);
    try std.testing.expectEqual(contract.ErrorCode.refresh_schedule_failed, runtime.view().error_code);
    for (0..3) |_| try std.testing.expect(runtime.prepareDue() == null);
    // Any event-loop turn still finds the renewal due, and it is waited for.
    platform.now_unix_seconds = 200;
    try std.testing.expectEqual(contract.Authorization.Use{ .wait = 0 }, runtime.authorization().use());
    var refresh = runtime.prepareDue() orelse return error.TestUnexpectedResult;
    try std.testing.expect(refresh.transition.takeEffect().? == .refresh_token);
    refresh.deinit();
    // The first beat that starts takes the report back.
    platform.now_unix_seconds = 100;
    platform.timer_start_fails = false;
    var started = runtime.prepareDue() orelse return error.TestUnexpectedResult;
    defer started.deinit();
    runtime.commit(&started);
    try std.testing.expectEqual(contract.ErrorCode.none, runtime.view().error_code);
    try std.testing.expect(runtime.prepareDue() == null);
}

test "stopping suppresses a prepared unsent refresh retry" {
    var transport: RuntimeTestTransport = .{ .failure = error.NetworkNotSent };
    var runtime = try initRuntimeForUnitTest(&transport);
    var platform: TestSupport.Platform = .{};
    defer {
        TestSupport.detachPlatform(&runtime);
        runtime.deinit();
    }
    try beginTestRefresh(&runtime, &platform);
    runtime.effects.network_attempt.join();
    var failed = switch (runtime.prepareNextCompletion().?) {
        .prepared => |prepared| prepared,
        else => return error.TestUnexpectedResult,
    };
    defer failed.deinit();
    runtime.commit(&failed);
    runtime.stopAdmission();
    platform.now_unix_seconds = 4000;
    try std.testing.expect(runtime.prepareDue() == null);
    try std.testing.expectEqual(@as(usize, 0), platform.timer_start_count);
}

test "projection inspection follows Account access token ownership without exporting refresh tokens" {
    const Inspection = struct {
        seen: usize = 0,
        fn visit(context: *anyopaque, token: []const u8) std.mem.Allocator.Error!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            std.debug.assert(std.mem.eql(u8, "access-token", token));
            self.seen += 1;
        }
    };
    var transport: RuntimeTestTransport = .{};
    var runtime = try initRuntimeForUnitTest(&transport);
    var platform: TestSupport.Platform = .{ .now_unix_seconds = 100 };
    TestSupport.attachPlatform(&runtime, &platform);
    defer {
        TestSupport.detachPlatform(&runtime);
        runtime.deinit();
    }
    const source = runtime.accessTokenProjection();
    var inspection: Inspection = .{};
    try source.visit(&inspection, Inspection.visit);
    try std.testing.expectEqual(@as(usize, 0), inspection.seen);
    var authenticated = try TestSupport.prepareAuthenticated(&runtime, "account-1", "User", "access-token", "refresh-token", 200);
    defer authenticated.deinit();
    runtime.commit(&authenticated);
    const generation = source.generation();
    try source.visit(&inspection, Inspection.visit);
    try std.testing.expectEqual(@as(usize, 1), inspection.seen);
    runtime.clearCredentials();
    try std.testing.expect(source.generation() != generation);
    try source.visit(&inspection, Inspection.visit);
    try std.testing.expectEqual(@as(usize, 1), inspection.seen);
}
