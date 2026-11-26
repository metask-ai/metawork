const std = @import("std");
const builtin = @import("builtin");
const account_contract = @import("metawork_account_contract");
const account_api = @import("metawork_account");
const control_ports = @import("metawork_product_control_ports");

/// The Application owner whose effects follow the Account authorization each
/// commit leaves. It learns the fact; it never asks Account for it.
pub const AuthorizationFollower = struct {
    context: *anyopaque,
    follow_fn: *const fn (*anyopaque, account_contract.Authorization) void,

    fn follow(self: AuthorizationFollower, authorization: account_contract.Authorization) void {
        self.follow_fn(self.context, authorization);
    }
};

/// The authorization as last published. Its epochs change only with a commit,
/// which publishes anyway.
const Published = struct {
    state: std.meta.Tag(account_contract.Authorization),
    generation: u64,

    fn of(authorization: account_contract.Authorization) Published {
        return .{
            .state = authorization,
            .generation = switch (authorization) {
                .available => |value| value.generation,
                .checking, .signed_out, .recovering => 0,
            },
        };
    }
};

/// Application binder for Account: terminal commits, the authorization query,
/// and the only way out for the current credential.
pub const Coordinator = struct {
    runtime: *account_api.Runtime,
    control: control_ports.AccountCommitSink,
    main_thread_id: std.Thread.Id,
    follower: ?AuthorizationFollower = null,
    credential_renewal: ?control_ports.MetaskCredentialRenewal = null,
    /// The credential generation running executions already received.
    delivered_generation: u64 = 0,
    published: ?Published = null,
    stopping: bool = false,
    /// One Metask 401 waiting for the main thread, from any thread: its
    /// generation shifted left once, low bit set for the token kind. 0 is none.
    unauthorized: std.atomic.Value(u64) = .init(0),
    io: std.Io,
    /// Once Account has closed, a report only folds: the platform's wake is
    /// gone and the Runtime may be. A reporter holds the lock while it wakes.
    report_lock: std.Io.Mutex = .init,
    closed: bool = false,

    pub fn init(
        runtime: *account_api.Runtime,
        control: control_ports.AccountCommitSink,
        main_thread_id: std.Thread.Id,
    ) Coordinator {
        return .{
            .runtime = runtime,
            .control = control,
            .main_thread_id = main_thread_id,
            .io = runtime.io,
        };
    }

    pub fn commandSink(self: *Coordinator) account_contract.AccountCommandSink {
        return .{ .context = self, .submit_fn = submitCommand };
    }

    pub fn setFollower(self: *Coordinator, follower: ?AuthorizationFollower) void {
        self.assertMainThread();
        self.follower = follower;
    }

    pub fn setCredentialRenewal(self: *Coordinator, renewal: control_ports.MetaskCredentialRenewal) void {
        self.assertMainThread();
        self.credential_renewal = renewal;
    }

    pub fn authorizationQuery(self: *Coordinator) account_contract.AuthorizationQuery {
        return .{ .context = self, .status_fn = currentAuthorization };
    }

    pub fn credentialSource(self: *Coordinator) account_contract.CredentialSource {
        return .{ .context = self, .take_fn = takeCredential };
    }

    fn currentAuthorization(context: *anyopaque) account_contract.Authorization {
        const self: *Coordinator = @ptrCast(@alignCast(context));
        self.assertMainThread();
        return self.runtime.authorization();
    }

    fn takeCredential(context: *anyopaque) std.mem.Allocator.Error!?account_contract.OwnedAuthorizationLease {
        const self: *Coordinator = @ptrCast(@alignCast(context));
        self.assertMainThread();
        return self.runtime.credential();
    }

    fn submitCommand(
        context: *anyopaque,
        command: account_contract.AccountCommand,
    ) account_contract.AccountCommandResult {
        const self: *Coordinator = @ptrCast(@alignCast(context));
        self.assertMainThread();
        if (self.stopping) return .rejected(.invalid_state);
        if (command == .open_recharge)
            return self.runtime.openRechargePage();
        const previous = self.runtime.attemptBefore();
        if (command == .refresh_summary) {
            const receipt = self.runtime.beginAttempt(command);
            const refreshed = self.runtime.refreshSummary();
            if (!refreshed.result.accepted) self.runtime.restoreAttempt(previous);
            if (refreshed.changed) self.commitSummaryNoFail();
            return if (refreshed.result.accepted) .acceptedAttempt(receipt) else refreshed.result;
        }
        return switch (self.runtime.prepareCommand(command)) {
            .prepared => |prepared| blk: {
                // Opened before the commit, so a command that settles at once
                // settles in it.
                const receipt = self.runtime.beginAttempt(command);
                const result = self.commitPrepared(prepared);
                if (!result.accepted) {
                    self.runtime.restoreAttempt(previous);
                    break :blk result;
                }
                break :blk .acceptedAttempt(receipt);
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
        const result = self.commitPrepared(self.runtime.prepareStart(platform));
        std.debug.assert(result.accepted);
    }

    pub fn startAutomation(self: *Coordinator) void {
        self.assertMainThread();
        const result = self.commitPrepared(self.runtime.prepareAutomationStart());
        std.debug.assert(result.accepted);
    }

    pub fn startUnavailable(self: *Coordinator) void {
        self.assertMainThread();
        const result = self.commitPrepared(self.runtime.prepareStartUnavailable());
        std.debug.assert(result.accepted);
    }

    pub fn ownsTimer(_: *const Coordinator, timer_id: u64) bool {
        return account_api.Runtime.ownsTimer(timer_id);
    }

    /// The window came to the front.
    pub fn activate(self: *Coordinator) void {
        self.assertMainThread();
        if (self.stopping) return;
        self.runtime.expedite();
        _ = self.tick();
    }

    /// Commits what the clocks ask now; true when anything was. Cheap enough
    /// for every event, so no single timer decides whether a renewal happens.
    pub fn tick(self: *Coordinator) bool {
        self.assertMainThread();
        if (self.stopping) return false;
        // A 401 is handed over here, never in its reporter's call.
        const pending = self.unauthorized.swap(0, .acq_rel);
        if (pending != 0) self.runtime.reportUnauthorized(pending >> 1, if (pending & 1 == 1) .token else .other);
        // A message that began to wait, or a Run whose token ended, is a
        // reason to try now.
        if (self.credential_renewal) |renewal| switch (self.runtime.authorization()) {
            .checking => |epoch| if (renewal.waits(epoch)) self.runtime.expedite(),
            .recovering => |epoch| if (renewal.waits(epoch) or renewal.holds()) self.runtime.expedite(),
            .available, .signed_out => {},
        };
        var committed = false;
        while (self.runtime.prepareDue()) |prepared| {
            if (!self.commitPrepared(prepared).accepted) break;
            committed = true;
        }
        // Product rewrites what only masking hid before the token leaves.
        while (self.runtime.expiredGrant()) |grant| {
            if (self.credential_renewal) |renewal| renewal.retire(grant.accessToken().?);
            self.runtime.forgetGrant(grant);
        }
        // A token that expired, or a clock that reads again, is no commit. A
        // token installed while no clock could judge it may be usable only now.
        const current: Published = .of(self.runtime.authorization());
        if (self.published) |published| if (!std.meta.eql(published, current)) {
            self.publish();
            committed = true;
        };
        return committed;
    }

    pub fn drain(self: *Coordinator) void {
        self.assertMainThread();
        if (self.stopping) return;
        // Workers given up on are joined once they have finished.
        self.runtime.reapAbandoned();
        while (self.runtime.prepareNextCompletion()) |result| {
            switch (result) {
                .prepared => |prepared| {
                    const committed = self.commitPrepared(prepared);
                    std.debug.assert(committed.accepted);
                },
                .rejected, .ignored_stale => {},
            }
        }
        _ = self.tick();
        if (self.runtime.drainSummary()) {
            _ = self.runtime.reconcileSummary();
            self.commitSummaryNoFail();
        }
        self.renewDeferredCredential();
    }

    /// Hands a new credential to executions already admitted. Account alone
    /// decides it; a catalog failure cannot roll this handoff back.
    fn deliverCredential(self: *Coordinator) void {
        const renewal = self.credential_renewal orelse return;
        const generation = self.readyGeneration() orelse return;
        if (generation == self.delivered_generation) return;
        self.renew(renewal, generation);
    }

    /// A Task busy compacting or checkpointing takes the current credential
    /// on the first turn after it settles.
    fn renewDeferredCredential(self: *Coordinator) void {
        const renewal = self.credential_renewal orelse return;
        const generation = self.readyGeneration() orelse return;
        if (renewal.needs(generation)) self.renew(renewal, generation);
    }

    fn renew(self: *Coordinator, renewal: control_ports.MetaskCredentialRenewal, generation: u64) void {
        self.delivered_generation = generation;
        renewal.renew(generation, self.runtime.accessToken().?);
    }

    /// Where every Metask consumer reports a 401 on the Account token.
    pub fn unauthorizedReport(self: *Coordinator) account_contract.UnauthorizedReport {
        return .{ .context = self, .report_fn = reportUnauthorized };
    }

    /// Any thread. Reports fold into one: the newest generation, and the
    /// token kind if a report of that generation said it. One for an older
    /// token says nothing.
    fn reportUnauthorized(context: *anyopaque, generation: u64, kind: account_contract.Unauthorized) void {
        const self: *Coordinator = @ptrCast(@alignCast(context));
        if (generation == 0 or generation > std.math.maxInt(u64) >> 1) return;
        const token: u64 = @intFromBool(kind == .token);
        var current = self.unauthorized.load(.acquire);
        while (true) {
            const held = current >> 1;
            if (generation < held) return;
            const next = if (generation == held) current | token else (generation << 1) | token;
            current = self.unauthorized.cmpxchgWeak(current, next, .acq_rel, .acquire) orelse break;
        }
        self.report_lock.lockUncancelable(self.io);
        defer self.report_lock.unlock(self.io);
        if (!self.closed) self.runtime.wakeFromAnyThread();
    }

    fn readyGeneration(self: *Coordinator) ?u64 {
        return switch (self.runtime.authorization().use()) {
            .ready => |generation| generation,
            .wait, .stop => null,
        };
    }

    fn commitPrepared(
        self: *Coordinator,
        prepared_value: account_api.Prepared,
    ) account_contract.AccountCommandResult {
        var prepared = prepared_value;
        defer prepared.deinit();

        const attempt_id = prepared.attemptId();
        const attempt_disposition = self.runtime.attemptDisposition(&prepared);

        const effect_admitted = self.runtime.admitEffect(&prepared);
        if (!effect_admitted and attempt_disposition != .continues)
            return .rejected(.local_resource_exhausted);

        // Account commits its own state first; every later step is no-fail and
        // cannot re-enter or roll back that transaction. Product learns the
        // fact and inspects the tokens before anyone uses the new one.
        self.runtime.commit(&prepared);
        self.control.commitNoFail(.{
            // As committed: what waits to reach Metask and the person's
            // attempt are settled only in the commit.
            .fact = .{ .view = self.runtime.view() },
            .token_changed = prepared.token_changed,
            .logged_out = prepared.logged_out,
        });
        self.publish();
        if (!self.stopping and self.runtime.reconcileSummary())
            self.commitSummaryNoFail();

        // A continuation effect can fail admission only after its preceding
        // external step has completed. Commit that observed step first, then
        // close the still-active Account attempt with its own typed failure.
        if (!effect_admitted)
            return self.commitPrepared(
                self.runtime.prepareActiveAttemptFailure(
                    .local_resource_exhausted,
                ),
            );

        const refresh_after_commit = self.runtime.takeRefreshAfterCommit(&prepared);
        self.runtime.dispatchCommitted();
        if (refresh_after_commit) {
            const refreshed = self.commitPrepared(
                self.runtime.prepareRestoredRefresh(),
            );
            std.debug.assert(refreshed.accepted);
        }
        return .acceptedAttempt(attempt_id);
    }

    /// Running executions take a new token before the catalog follows, and
    /// scheduled work rearms only once all of them agree. Nothing is handed
    /// over twice for one generation.
    fn publish(self: *Coordinator) void {
        self.deliverCredential();
        if (self.follower) |follower| follower.follow(self.runtime.authorization());
        self.published = .of(self.runtime.authorization());
        self.control.settleNoFail();
    }

    pub fn beginShutdown(self: *Coordinator) void {
        self.assertMainThread();
        if (self.stopping) return;
        self.stopping = true;
        self.follower = null;
        self.credential_renewal = null;
        self.runtime.stopAdmission();
    }

    pub fn shutdown(self: *Coordinator) void {
        self.assertMainThread();
        self.beginShutdown();
        var result = self.commitPrepared(self.runtime.prepareShutdown());
        if (!result.accepted and result.error_code == .local_resource_exhausted) {
            self.runtime.discardQueuedEffectForShutdown();
            result = self.commitPrepared(self.runtime.prepareShutdown());
        }
        std.debug.assert(result.accepted);
        self.report_lock.lockUncancelable(self.io);
        self.closed = true;
        self.report_lock.unlock(self.io);
    }

    fn commitSummaryNoFail(self: *Coordinator) void {
        self.control.commitNoFail(.{
            .fact = self.runtime.summaryFact(),
        });
        self.control.settleNoFail();
    }

    fn assertMainThread(self: *const Coordinator) void {
        std.debug.assert(std.Thread.getCurrentId() == self.main_thread_id);
    }
};

pub const TestSupport = if (builtin.is_test) struct {
    /// Commits what a test prepared, through every production step.
    pub fn commit(coordinator: *Coordinator, prepared: account_api.Prepared) account_contract.AccountCommandResult {
        return coordinator.commitPrepared(prepared);
    }
} else struct {};

const RecordedCommit = struct {
    state: account_contract.AccountState,
};

const RecordingSink = struct {
    runtime: *account_api.Runtime,
    records: [16]RecordedCommit = undefined,
    count: usize = 0,
    unsettled: bool = false,
    steps: ?*CommitSteps = null,

    fn port(self: *RecordingSink) control_ports.AccountCommitSink {
        return .{
            .context = self,
            .commit_fn = commit,
            .settle_fn = settle,
        };
    }

    fn settle(context: *anyopaque) void {
        const self: *RecordingSink = @ptrCast(@alignCast(context));
        self.unsettled = false;
        if (self.steps) |steps| steps.add(.settle);
    }

    fn commit(context: *anyopaque, value: control_ports.AccountCommit) void {
        const self: *RecordingSink = @ptrCast(@alignCast(context));
        std.debug.assert(self.count < self.records.len);

        // This assertion binds the required cross-owner ordering: the sink
        // cannot observe the fact before Account has committed it.
        const committed_view = self.runtime.view();
        std.debug.assert(committed_view.state == value.fact.view.state);
        std.debug.assert(std.mem.eql(
            u8,
            committed_view.account_id,
            value.fact.view.account_id,
        ));

        self.records[self.count] = .{ .state = value.fact.view.state };
        self.count += 1;
        std.debug.assert(!self.unsettled);
        self.unsettled = true;
        if (self.steps) |steps| steps.add(.commit);
    }
};

const CommitSteps = struct {
    const Step = enum { commit, renew, follow, settle, retire };
    items: [16]Step = undefined,
    count: usize = 0,
    /// A Run holds a Metask credential.
    holding: bool = false,

    fn add(self: *CommitSteps, step: Step) void {
        self.items[self.count] = step;
        self.count += 1;
    }

    fn take(self: *CommitSteps) []const Step {
        defer self.count = 0;
        return self.items[0..self.count];
    }

    fn renewal(self: *CommitSteps) control_ports.MetaskCredentialRenewal {
        return .{ .context = self, .renew_fn = renew, .needs_fn = needs, .waits_fn = waits, .holds_fn = holds, .retire_fn = retire };
    }

    fn renew(context: *anyopaque, generation: u64, credential: []const u8) void {
        const self: *CommitSteps = @ptrCast(@alignCast(context));
        std.debug.assert(generation != 0 and credential.len != 0);
        self.add(.renew);
    }

    fn retire(context: *anyopaque, credential: []const u8) void {
        const self: *CommitSteps = @ptrCast(@alignCast(context));
        std.debug.assert(std.mem.eql(u8, credential, "access-token"));
        self.add(.retire);
    }

    fn needs(_: *anyopaque, _: u64) bool {
        return false;
    }

    fn waits(_: *anyopaque, _: u64) bool {
        return false;
    }

    fn holds(context: *anyopaque) bool {
        const self: *CommitSteps = @ptrCast(@alignCast(context));
        return self.holding;
    }

    fn follower(self: *CommitSteps) AuthorizationFollower {
        return .{ .context = self, .follow_fn = follow };
    }

    fn follow(context: *anyopaque, _: account_contract.Authorization) void {
        const self: *CommitSteps = @ptrCast(@alignCast(context));
        self.add(.follow);
    }
};

const RecordingFollower = struct {
    calls: usize = 0,
    last: std.meta.Tag(account_contract.Authorization) = .signed_out,

    fn port(self: *RecordingFollower) AuthorizationFollower {
        return .{ .context = self, .follow_fn = follow };
    }

    fn follow(context: *anyopaque, authorization: account_contract.Authorization) void {
        const self: *RecordingFollower = @ptrCast(@alignCast(context));
        self.calls += 1;
        self.last = authorization;
    }
};

var testing_transport_context: u8 = 0;
var testing_wake_context: u8 = 0;

fn testingTransport() account_api.Transport {
    return .{
        .context = &testing_transport_context,
        .perform_fn = testingPerform,
        .retire_fn = account_api.retireNothing,
    };
}

fn testingPerform(
    _: *anyopaque,
    _: account_api.TransportRequest,
    _: []u8,
) account_api.TransportError!account_api.TransportResponse {
    return error.NetworkFailed;
}

fn testingWake(_: *anyopaque) void {}

fn initRuntimeForTest() !account_api.Runtime {
    return account_api.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        std.Thread.getCurrentId(),
        testingTransport(),
        account_api.TestSupport.loopbackEndpoint(),
        .{ .context = &testing_wake_context, .notify_fn = testingWake },
    );
}

const SummaryTransport = struct {
    fail_history: bool = false,
    request_count: usize = 0,
    history_request_count: usize = 0,
    /// Keeps a history request underway.
    held: bool = false,
    started: std.Io.Event = .unset,
    release: std.Io.Event = .unset,
    renewals: usize = 0,
    bearer: []const u8 = "access-token",

    fn port(self: *SummaryTransport) account_api.Transport {
        return .{ .context = self, .perform_fn = perform, .retire_fn = account_api.retireNothing };
    }

    fn perform(
        context: *anyopaque,
        request: account_api.TransportRequest,
        output: []u8,
    ) account_api.TransportError!account_api.TransportResponse {
        const self: *SummaryTransport = @ptrCast(@alignCast(context));
        if (request.kind == .refresh_token) {
            self.renewals += 1;
            const body = if (self.renewals % 2 == 1)
                "{\"access_token\":\"access-odd\",\"refresh_token\":\"refresh-odd\",\"token_type\":\"Bearer\",\"expires_in\":3600}"
            else
                "{\"access_token\":\"access-even\",\"refresh_token\":\"refresh-even\",\"token_type\":\"Bearer\",\"expires_in\":3600}";
            @memcpy(output[0..body.len], body);
            return .{ .status = 200, .body = output[0..body.len] };
        }
        if (!std.mem.eql(u8, request.bearer orelse "", self.bearer))
            return error.ProtocolFailed;
        self.request_count += 1;
        const body = switch (request.kind) {
            .usage_stats => {
                self.history_request_count += 1;
                if (self.held) {
                    self.started.set(std.testing.io);
                    self.release.wait(std.testing.io) catch return error.NetworkFailed;
                }
                if (self.fail_history) {
                    const failure = "{}";
                    @memcpy(output[0..failure.len], failure);
                    return .{ .status = 503, .body = output[0..failure.len] };
                }
                const range = request.usage_stats_range orelse
                    return error.ProtocolFailed;
                const rendered = std.fmt.bufPrint(
                    output,
                    "{{\"object\":\"usage_stats\",\"scope\":\"user\",\"granularity\":\"day\",\"timezone\":\"Asia/Shanghai\",\"since\":\"{s}\",\"before\":\"{s}\",\"totals\":{{\"requests\":1,\"input_tokens\":10,\"output_tokens\":20,\"cache_creation_tokens\":0,\"cache_read_tokens\":30,\"total_tokens\":60,\"cost_mu\":1250}},\"data\":[{{\"bucket\":\"2026-09-15\",\"bucket_start\":\"2026-09-14T16:00:00Z\",\"requests\":1,\"input_tokens\":10,\"output_tokens\":20,\"cache_creation_tokens\":0,\"cache_read_tokens\":30,\"total_tokens\":60,\"cost_mu\":1250}}]}}",
                    .{ range.since, range.before },
                ) catch return error.ResponseTooLarge;
                return .{ .status = 200, .body = rendered };
            },
            else => return error.ProtocolFailed,
        };
        if (body.len > output.len) return error.ResponseTooLarge;
        @memcpy(output[0..body.len], body);
        return .{ .status = 200, .body = output[0..body.len] };
    }
};

fn initRuntimeForSummaryTest(transport: *SummaryTransport) account_api.Runtime {
    return account_api.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        std.Thread.getCurrentId(),
        transport.port(),
        account_api.TestSupport.loopbackEndpoint(),
        .{ .context = &testing_wake_context, .notify_fn = testingWake },
    );
}

test "Account summary auto-sync requests usage stats directly and preserves stale history" {
    var transport: SummaryTransport = .{};
    var runtime = initRuntimeForSummaryTest(&transport);
    var platform: account_api.TestSupport.Platform = .{ .now_unix_seconds = 1_789_440_000 };
    account_api.TestSupport.attachPlatform(&runtime, &platform);
    defer {
        account_api.TestSupport.detachPlatform(&runtime);
        runtime.deinit();
    }
    var sink: RecordingSink = .{ .runtime = &runtime };
    var coordinator = Coordinator.init(&runtime, sink.port(), std.Thread.getCurrentId());
    _ = coordinator.commitPrepared(try account_api.TestSupport.prepareAuthenticated(
        &runtime,
        "42",
        "Meta User",
        "access-token",
        "refresh-token",
        1_789_441_000,
    ));
    try std.testing.expectEqual(account_contract.SummaryOperation.refreshing, runtime.view().summary.operation);
    account_api.TestSupport.joinSummary(&runtime);
    coordinator.drain();
    const ready = runtime.view();
    try std.testing.expectEqual(account_contract.UsageEligibility.enabled, ready.summary.usage_eligibility);
    try std.testing.expectEqual(@as(usize, 1), transport.request_count);
    try std.testing.expectEqual(@as(usize, 1), transport.history_request_count);
    try std.testing.expectEqual(account_contract.SummaryAvailability.ready, ready.summary.history.availability);
    try std.testing.expectEqualStrings("60", ready.summary.history.days[0].total_tokens);

    transport.fail_history = true;
    const refresh = coordinator.commandSink().submit(.refresh_summary);
    try std.testing.expect(refresh.accepted);
    // The person's refresh is an attempt under its receipt; one refused
    // leaves it in place.
    try expectAttempt(&runtime, refresh.attempt_id.?, .refresh_summary, null, .none);
    const duplicate = coordinator.commandSink().submit(.refresh_summary);
    try std.testing.expect(!duplicate.accepted);
    try std.testing.expectEqual(account_contract.ErrorCode.operation_in_progress, duplicate.error_code);
    try expectAttempt(&runtime, refresh.attempt_id.?, .refresh_summary, null, .none);
    account_api.TestSupport.joinSummary(&runtime);
    coordinator.drain();
    try expectAttempt(&runtime, refresh.attempt_id.?, .refresh_summary, .failed, .metask_service_unavailable);
    const history_stale = runtime.view();
    try std.testing.expectEqual(account_contract.SummaryAvailability.stale, history_stale.summary.history.availability);
    try std.testing.expectEqual(account_contract.ErrorCode.metask_service_unavailable, history_stale.summary.history.error_code);
    try std.testing.expectEqualStrings("60", history_stale.summary.history.days[0].total_tokens);
}

test "Account summary stays across renewals and is fetched again only when asked" {
    var transport: SummaryTransport = .{};
    var runtime = initRuntimeForSummaryTest(&transport);
    const start: i64 = 1_789_440_000;
    var platform: account_api.TestSupport.Platform = .{ .now_unix_seconds = start };
    try platform.setStoredRefreshToken("refresh-token");
    account_api.TestSupport.attachPlatform(&runtime, &platform);
    defer {
        account_api.TestSupport.detachPlatform(&runtime);
        runtime.deinit();
    }
    var sink: RecordingSink = .{ .runtime = &runtime };
    var coordinator = Coordinator.init(&runtime, sink.port(), std.Thread.getCurrentId());
    _ = coordinator.commitPrepared(try account_api.TestSupport.prepareAuthenticatedAndSchedule(&runtime, "42", "Meta User", "access-token", "refresh-token", start + 200));
    account_api.TestSupport.joinSummary(&runtime);
    coordinator.drain();
    try expectHistory(&runtime, .ready, 1, &transport);

    // Expiry and the renewal of the same account leave it as it is: it is
    // not fetched again.
    platform.now_unix_seconds = start + 200;
    try std.testing.expect(coordinator.tick());
    transport.bearer = "access-odd";
    account_api.TestSupport.joinNetwork(&runtime);
    coordinator.drain();
    try std.testing.expect(runtime.summary_job == null);
    try expectHistory(&runtime, .ready, 1, &transport);

    // The person asks for it; failing to read it only marks what is shown.
    transport.fail_history = true;
    try std.testing.expect(coordinator.commandSink().submit(.refresh_summary).accepted);
    account_api.TestSupport.joinSummary(&runtime);
    coordinator.drain();
    try expectHistory(&runtime, .stale, 2, &transport);

    sink.count = 0;
    // A renewal during a request does not repeat it.
    transport.fail_history = false;
    transport.held = true;
    try std.testing.expect(coordinator.commandSink().submit(.refresh_summary).accepted);
    try transport.started.wait(std.testing.io);
    platform.now_unix_seconds = start + 4000;
    try std.testing.expect(coordinator.tick());
    account_api.TestSupport.joinNetwork(&runtime);
    coordinator.drain();
    try expectHistory(&runtime, .stale, 3, &transport);
    transport.held = false;
    transport.bearer = "access-even";
    transport.release.set(std.testing.io);
    account_api.TestSupport.joinSummary(&runtime);
    coordinator.drain();
    try expectHistory(&runtime, .ready, 3, &transport);
    try std.testing.expect(runtime.summary_job == null);

    // Signing out, as changing accounts begins, takes it away, and does not
    // wait for a request of it still underway.
    transport.started = .unset;
    transport.release = .unset;
    transport.held = true;
    try std.testing.expect(coordinator.commandSink().submit(.refresh_summary).accepted);
    try transport.started.wait(std.testing.io);
    try std.testing.expect(coordinator.commandSink().submit(.logout).accepted);
    try std.testing.expectEqual(account_contract.SummaryAvailability.unavailable, runtime.summary.view().history.availability);
    try std.testing.expect(runtime.summary_job == null and runtime.retired_summaries != null);
    transport.release.set(std.testing.io);
    for (0..5000) |_| {
        coordinator.drain();
        if (runtime.retired_summaries == null) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    } else return error.CancelledSummaryNeverJoined;
}

fn expectAttempt(
    runtime: *account_api.Runtime,
    id: u64,
    action: account_contract.AccountCommand,
    outcome: ?account_contract.AccountAttempt.Outcome,
    error_code: account_contract.ErrorCode,
) !void {
    const attempt = runtime.view().attempt orelse return error.TestExpectedAttempt;
    try std.testing.expectEqual(id, attempt.id);
    try std.testing.expectEqual(action, attempt.action);
    try std.testing.expectEqual(outcome, attempt.outcome);
    try std.testing.expectEqual(error_code, attempt.error_code);
}

fn expectHistory(runtime: *account_api.Runtime, availability: account_contract.SummaryAvailability, requests: usize, transport: *const SummaryTransport) !void {
    const history = runtime.view().summary.history;
    try std.testing.expectEqual(availability, history.availability);
    try std.testing.expectEqualStrings("60", history.days[0].total_tokens);
    try std.testing.expectEqual(requests, transport.history_request_count);
}

test "Account summary does not depend on a legacy account mode" {
    var transport: SummaryTransport = .{};
    var runtime = initRuntimeForSummaryTest(&transport);
    var platform: account_api.TestSupport.Platform = .{ .now_unix_seconds = 1_789_440_000 };
    account_api.TestSupport.attachPlatform(&runtime, &platform);
    defer {
        account_api.TestSupport.detachPlatform(&runtime);
        runtime.deinit();
    }
    var sink: RecordingSink = .{ .runtime = &runtime };
    var coordinator = Coordinator.init(&runtime, sink.port(), std.Thread.getCurrentId());
    _ = coordinator.commitPrepared(try account_api.TestSupport.prepareAuthenticated(
        &runtime,
        "42",
        "Meta User",
        "access-token",
        "refresh-token",
        1_789_441_000,
    ));
    account_api.TestSupport.joinSummary(&runtime);
    coordinator.drain();
    const summary = runtime.view().summary;
    try std.testing.expectEqual(@as(usize, 1), transport.request_count);
    try std.testing.expectEqual(@as(usize, 1), transport.history_request_count);
    try std.testing.expectEqual(account_contract.UsageEligibility.enabled, summary.usage_eligibility);
    try std.testing.expectEqual(account_contract.SummaryAvailability.ready, summary.history.availability);
}

test "Account coordinator commits identity before notifying Product" {
    var runtime = try initRuntimeForTest();
    defer runtime.deinit();
    var sink: RecordingSink = .{ .runtime = &runtime };
    var coordinator = Coordinator.init(
        &runtime,
        sink.port(),
        std.Thread.getCurrentId(),
    );
    const result = coordinator.commitPrepared(
        try account_api.TestSupport.prepareAuthenticated(
            &runtime,
            "account-1",
            "Metask User",
            "access-token",
            "refresh-token",
            100,
        ),
    );

    try std.testing.expect(result.accepted);
    try std.testing.expectEqual(@as(usize, 1), sink.count);
    try std.testing.expectEqual(account_contract.AccountState.authenticated, sink.records[0].state);
}

test "Account logout reaches Product as one commit" {
    var runtime = try initRuntimeForTest();
    var platform: account_api.TestSupport.Platform = .{ .now_unix_seconds = 100 };
    account_api.TestSupport.attachPlatform(&runtime, &platform);
    defer {
        account_api.TestSupport.detachPlatform(&runtime);
        runtime.deinit();
    }
    var sink: RecordingSink = .{ .runtime = &runtime };
    var coordinator = Coordinator.init(
        &runtime,
        sink.port(),
        std.Thread.getCurrentId(),
    );
    _ = coordinator.commitPrepared(
        try account_api.TestSupport.prepareAuthenticated(
            &runtime,
            "account-1",
            "Metask User",
            "access-token",
            "refresh-token",
            100,
        ),
    );

    const result = coordinator.commandSink().submit(.logout);

    try std.testing.expect(result.accepted);
    const logout = sink.records[sink.count - 1];
    try std.testing.expectEqual(account_contract.AccountState.signed_out, logout.state);
    try std.testing.expectEqual(account_contract.AccountState.signed_out, runtime.view().state);
    // Receipts count from one, and a logout ends in its own commit.
    try std.testing.expectEqual(@as(?u64, 1), result.attempt_id);
    try expectAttempt(&runtime, 1, .logout, .succeeded, .none);
}

test "Account test platform exposes deterministic clock timer and credential faults" {
    var platform: account_api.TestSupport.Platform = .{};
    const ports = platform.ports();

    try platform.setStoredRefreshToken("retained-refresh");
    var output: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "retained-refresh",
        (try ports.credentials.getRefreshToken(&output)).?,
    );
    try std.testing.expectEqual(@as(?i64, 100), ports.wall_clock.nowUnixSeconds());

    try ports.timer.start(7, 123, true);
    try std.testing.expectEqual(@as(usize, 1), platform.timer_start_count);
    try std.testing.expectEqual(@as(?u64, 7), platform.last_timer_id);
    try std.testing.expectEqual(@as(u64, 123), platform.last_timer_interval_ns);

    platform.timer_start_fails = true;
    try std.testing.expectError(
        error.TimerStartFailed,
        ports.timer.start(8, 456, true),
    );
    platform.credential_read_fails = true;
    try std.testing.expectError(
        error.ReadFailed,
        ports.credentials.getRefreshToken(&output),
    );
    platform.now_unix_seconds = null;
    try std.testing.expect(ports.wall_clock.nowUnixSeconds() == null);
}

test "Account coordinator rejects an initial effect collision without committing" {
    var runtime = try initRuntimeForTest();
    defer runtime.deinit();
    var sink: RecordingSink = .{ .runtime = &runtime };
    var coordinator = Coordinator.init(
        &runtime,
        sink.port(),
        std.Thread.getCurrentId(),
    );
    coordinator.startAutomation();
    sink.count = 0;

    account_api.TestSupport.occupyEffectQueue(&runtime);
    defer account_api.TestSupport.clearEffectQueue(&runtime);
    const result = coordinator.commandSink().submit(.begin_login);

    try std.testing.expect(!result.accepted);
    try std.testing.expectEqual(
        account_contract.ErrorCode.local_resource_exhausted,
        result.error_code,
    );
    try std.testing.expectEqual(account_contract.AccountState.signed_out, runtime.view().state);
    try std.testing.expectEqual(@as(usize, 0), sink.count);
}

test "Account coordinator closes a continuation effect collision with one terminal fact" {
    var runtime = try initRuntimeForTest();
    defer runtime.deinit();
    var sink: RecordingSink = .{ .runtime = &runtime };
    var coordinator = Coordinator.init(
        &runtime,
        sink.port(),
        std.Thread.getCurrentId(),
    );
    coordinator.startAutomation();
    sink.count = 0;
    _ = account_api.TestSupport.commitBeginLoginWithoutDispatch(&runtime);
    account_api.TestSupport.occupyEffectQueue(&runtime);
    var exchange_backing: [1024]u8 = undefined;
    @memset(&exchange_backing, 0xaa);
    var exchange_fixed = std.heap.FixedBufferAllocator.init(&exchange_backing);
    var exchange_input = try account_api.TestSupport.exchangeInput(
        exchange_fixed.allocator(),
        "authorization-code",
    );
    defer exchange_input.deinit();

    const result = coordinator.commitPrepared(
        account_api.TestSupport.prepareLoginExchange(&runtime, &exchange_input),
    );

    try std.testing.expect(result.accepted);
    try std.testing.expectEqual(@as(usize, 2), sink.count);
    try std.testing.expectEqual(account_contract.AccountState.signed_out, runtime.view().state);
    try std.testing.expectEqual(
        account_contract.ErrorCode.local_resource_exhausted,
        runtime.view().error_code,
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        &exchange_backing,
        "authorization-code",
    ) == null);
}

test "Account cancel discards a late callback exchange secret" {
    var runtime = try initRuntimeForTest();
    defer runtime.deinit();
    var sink: RecordingSink = .{ .runtime = &runtime };
    var coordinator = Coordinator.init(
        &runtime,
        sink.port(),
        std.Thread.getCurrentId(),
    );
    coordinator.startAutomation();
    sink.count = 0;
    const attempt_id = account_api.TestSupport.commitBeginLoginWithoutDispatch(&runtime);
    var backing: [1024]u8 = undefined;
    @memset(&backing, 0xaa);
    var fixed = std.heap.FixedBufferAllocator.init(&backing);
    var exchange_input = try account_api.TestSupport.exchangeInput(
        fixed.allocator(),
        "late-authorization-code",
    );
    account_api.TestSupport.publishLoginExchange(
        &runtime,
        attempt_id,
        &exchange_input,
    );

    const result = coordinator.commandSink().submit(.cancel_operation);

    try std.testing.expect(result.accepted);
    try expectAttempt(&runtime, result.attempt_id.?, .cancel_operation, .cancelled, .user_cancelled);
    try std.testing.expectEqual(@as(usize, 1), sink.count);
    try std.testing.expect(std.mem.indexOf(
        u8,
        &backing,
        "late-authorization-code",
    ) == null);
}

test "Account shutdown discards an uncommitted effect and closes the active attempt" {
    var runtime = try initRuntimeForTest();
    defer runtime.deinit();
    var sink: RecordingSink = .{ .runtime = &runtime };
    var coordinator = Coordinator.init(
        &runtime,
        sink.port(),
        std.Thread.getCurrentId(),
    );
    coordinator.startAutomation();
    sink.count = 0;
    _ = account_api.TestSupport.commitBeginLoginWithoutDispatch(&runtime);
    account_api.TestSupport.occupyEffectQueue(&runtime);

    coordinator.shutdown();

    try std.testing.expectEqual(@as(usize, 1), sink.count);
    try std.testing.expectEqual(account_contract.AccountState.signed_out, runtime.view().state);
}

test "Account mailbox collision becomes one typed terminal failure" {
    var runtime = try initRuntimeForTest();
    defer runtime.deinit();
    var sink: RecordingSink = .{ .runtime = &runtime };
    var coordinator = Coordinator.init(
        &runtime,
        sink.port(),
        std.Thread.getCurrentId(),
    );
    coordinator.startAutomation();
    sink.count = 0;
    const attempt_id = account_api.TestSupport.commitBeginLoginWithoutDispatch(&runtime);
    var backing: [1024]u8 = undefined;
    @memset(&backing, 0xaa);
    var fixed = std.heap.FixedBufferAllocator.init(&backing);
    var exchange_input = try account_api.TestSupport.exchangeInput(
        fixed.allocator(),
        "collided-authorization-code",
    );
    account_api.TestSupport.publishLoginExchange(
        &runtime,
        attempt_id,
        &exchange_input,
    );
    account_api.TestSupport.publishFailure(&runtime, attempt_id, .deadline_exceeded);

    coordinator.drain();

    try std.testing.expectEqual(@as(usize, 1), sink.count);
    try std.testing.expectEqual(account_contract.AccountState.signed_out, runtime.view().state);
    try std.testing.expectEqual(
        account_contract.ErrorCode.account_operation_failed,
        runtime.view().error_code,
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        &backing,
        "collided-authorization-code",
    ) == null);
}

test "Account stale callback is ignored and its exchange secret is cleared" {
    var runtime = try initRuntimeForTest();
    defer runtime.deinit();
    var sink: RecordingSink = .{ .runtime = &runtime };
    var coordinator = Coordinator.init(
        &runtime,
        sink.port(),
        std.Thread.getCurrentId(),
    );
    coordinator.startAutomation();
    sink.count = 0;
    const attempt_id = account_api.TestSupport.commitBeginLoginWithoutDispatch(&runtime);
    var backing: [1024]u8 = undefined;
    @memset(&backing, 0xaa);
    var fixed = std.heap.FixedBufferAllocator.init(&backing);
    var exchange_input = try account_api.TestSupport.exchangeInput(
        fixed.allocator(),
        "stale-authorization-code",
    );
    account_api.TestSupport.publishLoginExchange(
        &runtime,
        attempt_id + 1,
        &exchange_input,
    );

    coordinator.drain();

    try std.testing.expectEqual(@as(usize, 0), sink.count);
    try std.testing.expectEqual(account_contract.AccountState.authorizing, runtime.view().state);
    try std.testing.expect(std.mem.indexOf(
        u8,
        &backing,
        "stale-authorization-code",
    ) == null);
    coordinator.shutdown();
}

test "Account shutdown publishes one terminal fact for an active attempt" {
    var runtime = try initRuntimeForTest();
    defer runtime.deinit();
    var sink: RecordingSink = .{ .runtime = &runtime };
    var coordinator = Coordinator.init(
        &runtime,
        sink.port(),
        std.Thread.getCurrentId(),
    );
    coordinator.startAutomation();
    sink.count = 0;
    _ = account_api.TestSupport.commitBeginLoginWithoutDispatch(&runtime);

    coordinator.shutdown();

    try std.testing.expectEqual(@as(usize, 1), sink.count);
    try std.testing.expectEqual(account_contract.AccountState.signed_out, runtime.view().state);
}

test "Account refresh scheduling failure is visible and explicitly retryable" {
    var runtime = try initRuntimeForTest();
    var platform: account_api.TestSupport.Platform = .{
        .now_unix_seconds = 100,
        .timer_start_fails = true,
    };
    account_api.TestSupport.attachPlatform(&runtime, &platform);
    defer {
        account_api.TestSupport.detachPlatform(&runtime);
        runtime.deinit();
    }
    var sink: RecordingSink = .{ .runtime = &runtime };
    var coordinator = Coordinator.init(
        &runtime,
        sink.port(),
        std.Thread.getCurrentId(),
    );

    const authenticated = coordinator.commitPrepared(
        try account_api.TestSupport.prepareAuthenticatedAndSchedule(
            &runtime,
            "account-1",
            "Metask User",
            "access-token",
            "refresh-token",
            200,
        ),
    );

    try std.testing.expect(authenticated.accepted);
    // Identity, then automatic summary start.
    try std.testing.expectEqual(@as(usize, 2), sink.count);
    // However many turns find the beat not running, it is reported once.
    try std.testing.expect(coordinator.tick());
    try std.testing.expect(!coordinator.tick());
    try std.testing.expectEqual(@as(usize, 3), sink.count);
    try std.testing.expectEqual(
        account_contract.ErrorCode.refresh_schedule_failed,
        runtime.view().error_code,
    );
    var lease = (try runtime.credential()).?;
    lease.deinit();

    platform.timer_start_fails = false;
    sink.count = 0;
    const retried = coordinator.commandSink().submit(.retry_refresh);

    try std.testing.expect(retried.accepted);
    try expectAttempt(&runtime, retried.attempt_id.?, .retry_refresh, .succeeded, .none);
    try std.testing.expectEqual(@as(usize, 1), sink.count);
    try std.testing.expectEqual(account_contract.ErrorCode.none, runtime.view().error_code);
    try std.testing.expectEqual(@as(u64, 30 * std.time.ns_per_s), platform.last_timer_interval_ns);
    try std.testing.expect(!coordinator.tick());
}

test "Account explicit refresh schedule retry reports a beat that still cannot start" {
    var runtime = try initRuntimeForTest();
    var platform: account_api.TestSupport.Platform = .{
        .now_unix_seconds = 100,
        .timer_start_fails = true,
    };
    account_api.TestSupport.attachPlatform(&runtime, &platform);
    defer {
        account_api.TestSupport.detachPlatform(&runtime);
        runtime.deinit();
    }
    var sink: RecordingSink = .{ .runtime = &runtime };
    var coordinator = Coordinator.init(
        &runtime,
        sink.port(),
        std.Thread.getCurrentId(),
    );

    _ = coordinator.commitPrepared(
        try account_api.TestSupport.prepareAuthenticatedAndSchedule(
            &runtime,
            "account-1",
            "Metask User",
            "access-token",
            "refresh-token",
            200,
        ),
    );
    try std.testing.expect(coordinator.tick());
    sink.count = 0;
    const retried = coordinator.commandSink().submit(.retry_refresh);
    try std.testing.expect(retried.accepted);
    try expectAttempt(&runtime, retried.attempt_id.?, .retry_refresh, .failed, .refresh_schedule_failed);
    try std.testing.expectEqual(@as(usize, 1), sink.count);
    try std.testing.expectEqual(
        account_contract.ErrorCode.refresh_schedule_failed,
        runtime.view().error_code,
    );
}

test "Account follower keeps the authorization of a token still valid or expiring during refresh" {
    var runtime = try initRuntimeForTest();
    var platform: account_api.TestSupport.Platform = .{ .now_unix_seconds = 100 };
    account_api.TestSupport.attachPlatform(&runtime, &platform);
    defer {
        account_api.TestSupport.detachPlatform(&runtime);
        runtime.deinit();
    }
    var sink: RecordingSink = .{ .runtime = &runtime };
    var coordinator = Coordinator.init(&runtime, sink.port(), std.Thread.getCurrentId());
    _ = coordinator.commitPrepared(
        try account_api.TestSupport.prepareAuthenticated(&runtime, "account-1", "Metask User", "access-token", "refresh-token", 150),
    );
    var follower: RecordingFollower = .{};
    coordinator.setFollower(follower.port());

    const refreshed = coordinator.commitPrepared(
        account_api.TestSupport.prepareTokenRefreshWithoutEffect(&runtime),
    );

    try std.testing.expect(refreshed.accepted);
    try std.testing.expectEqual(@as(usize, 1), follower.calls);
    try std.testing.expectEqual(.available, follower.last);
    // The expiry itself is no commit; the next one reports a recovery, never
    // the loss of the account.
    platform.now_unix_seconds = 150;
    account_api.TestSupport.publishUnsentRefreshFailure(&runtime, .account_operation_failed);
    coordinator.drain();
    try std.testing.expectEqual(@as(usize, 2), follower.calls);
    try std.testing.expectEqual(.recovering, follower.last);
}

test "Account publishes an authorization that only time changed" {
    var transport: ClosingRefreshTransport = .{};
    var runtime = account_api.Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId(), transport.port(), account_api.TestSupport.loopbackEndpoint(), .{ .context = &testing_wake_context, .notify_fn = testingWake });
    var platform: account_api.TestSupport.Platform = .{ .now_unix_seconds = 100, .boot_seconds = 100 };
    account_api.TestSupport.attachPlatform(&runtime, &platform);
    defer {
        account_api.TestSupport.detachPlatform(&runtime);
        runtime.deinit();
    }
    var steps: CommitSteps = .{};
    var sink: RecordingSink = .{ .runtime = &runtime, .steps = &steps };
    var coordinator = Coordinator.init(&runtime, sink.port(), std.Thread.getCurrentId());
    coordinator.setFollower(steps.follower());
    coordinator.setCredentialRenewal(steps.renewal());
    _ = coordinator.commitPrepared(
        try account_api.TestSupport.prepareAuthenticated(&runtime, "account-1", "Metask User", "access-token", "refresh-token", 150),
    );
    account_api.TestSupport.joinSummary(&runtime);
    coordinator.drain();
    _ = steps.take();
    // Expired, then no wall clock, then the wall clock set back: it ended
    // once, and nothing after that is a change.
    for ([_]?i64{ 149, 150, null, 100 }) |now| {
        platform.now_unix_seconds = now;
        const changed = now != null and now.? == 150;
        try std.testing.expectEqual(changed, coordinator.tick());
        try std.testing.expectEqualSlices(CommitSteps.Step, if (changed) &.{ .follow, .settle } else &.{}, steps.take());
        try std.testing.expect(!coordinator.tick());
    }
    // What a wait counts is no change of its own.
    try std.testing.expectEqual(Published.of(.{ .recovering = 1 }), Published.of(.{ .recovering = 2 }));

    // A renewed token is handed over once it is installed.
    _ = coordinator.commitPrepared(account_api.TestSupport.prepareTokenRefresh(&runtime));
    account_api.TestSupport.joinNetwork(&runtime);
    coordinator.drain();
    try std.testing.expectEqualStrings("new-access", runtime.accessToken().?);
    try std.testing.expect(std.mem.indexOfScalar(CommitSteps.Step, steps.take(), .renew) != null);
    try std.testing.expect(!coordinator.tick());
}

test "Account tries at once for a Run that holds an ended token" {
    for ([_]bool{ false, true }) |holding| {
        var runtime = try initRuntimeForTest();
        var platform: account_api.TestSupport.Platform = .{ .now_unix_seconds = 100 };
        account_api.TestSupport.attachPlatform(&runtime, &platform);
        defer {
            account_api.TestSupport.detachPlatform(&runtime);
            runtime.deinit();
        }
        var steps: CommitSteps = .{ .holding = holding };
        var sink: RecordingSink = .{ .runtime = &runtime, .steps = &steps };
        var coordinator = Coordinator.init(&runtime, sink.port(), std.Thread.getCurrentId());
        coordinator.setCredentialRenewal(steps.renewal());
        _ = coordinator.commitPrepared(
            try account_api.TestSupport.prepareAuthenticated(&runtime, "account-1", "Metask User", "access-token", "refresh-token", 150),
        );
        // A failure is waited out, the last attempt ended at 145.
        runtime.renew_at = .{ .wall = null, .boot = 1000 };
        runtime.retrying = true;
        runtime.confirm_ended_boot = 145;
        platform.now_unix_seconds = 149;
        _ = coordinator.tick();
        try std.testing.expectEqual(@as(i64, 1000), runtime.renew_at.?.boot);
        platform.now_unix_seconds = 150;
        _ = coordinator.tick();
        try std.testing.expectEqual(@as(i64, if (holding) 175 else 1000), runtime.renew_at.?.boot);
        try std.testing.expect(runtime.account.activeAttempt() == null);
    }
}

test "Account folds 401 reports into one and takes it on its next turn" {
    var runtime = try initRuntimeForTest();
    var platform: account_api.TestSupport.Platform = .{ .now_unix_seconds = 100 };
    account_api.TestSupport.attachPlatform(&runtime, &platform);
    defer {
        account_api.TestSupport.detachPlatform(&runtime);
        runtime.deinit();
    }
    var sink: RecordingSink = .{ .runtime = &runtime };
    var coordinator = Coordinator.init(&runtime, sink.port(), std.Thread.getCurrentId());
    _ = coordinator.commitPrepared(
        try account_api.TestSupport.prepareAuthenticated(&runtime, "account-1", "Metask User", "access-token", "refresh-token", 200),
    );
    const generation = runtime.credentials.current.?.generation;
    const report = coordinator.unauthorizedReport();
    const Reporter = struct {
        fn run(port: account_contract.UnauthorizedReport, value: u64) void {
            port.report(value, .token);
        }
    };
    report.report(generation, .other);
    const thread = try std.Thread.spawn(.{}, Reporter.run, .{ report, generation });
    thread.join();
    // Nothing is decided in a reporter's call.
    try std.testing.expect(runtime.unauthorized == null);
    _ = coordinator.tick();
    try std.testing.expectEqual(generation, runtime.unauthorized.?.generation);
    try std.testing.expectEqual(account_contract.Unauthorized.token, runtime.unauthorized.?.kind);
    try std.testing.expectEqual(@as(u64, 0), coordinator.unauthorized.load(.acquire));

    // A token complaint belongs to its generation: a newer report starts
    // over, an older one changes nothing.
    report.report(generation, .token);
    report.report(generation + 1, .other);
    try std.testing.expectEqual((generation + 1) << 1, coordinator.unauthorized.load(.acquire));
    report.report(generation, .token);
    try std.testing.expectEqual((generation + 1) << 1, coordinator.unauthorized.load(.acquire));
    _ = coordinator.unauthorized.swap(0, .acq_rel);
    runtime.unauthorized = .{ .generation = generation - 1, .kind = .token };
    runtime.reportUnauthorized(generation, .other);
    try std.testing.expectEqual(account_contract.Unauthorized.other, runtime.unauthorized.?.kind);
}

test "a 401 reported after Account closed wakes nobody and folds only" {
    const Wakes = struct {
        var count: std.atomic.Value(usize) = .init(0);
        fn notify(_: *anyopaque) void {
            _ = count.fetchAdd(1, .acq_rel);
        }
    };
    var runtime = account_api.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        std.Thread.getCurrentId(),
        testingTransport(),
        account_api.TestSupport.loopbackEndpoint(),
        .{ .context = &testing_wake_context, .notify_fn = Wakes.notify },
    );
    var platform: account_api.TestSupport.Platform = .{ .now_unix_seconds = 100 };
    account_api.TestSupport.attachPlatform(&runtime, &platform);
    defer {
        account_api.TestSupport.detachPlatform(&runtime);
        runtime.deinit();
    }
    var sink: RecordingSink = .{ .runtime = &runtime };
    var coordinator = Coordinator.init(&runtime, sink.port(), std.Thread.getCurrentId());
    _ = coordinator.commitPrepared(
        try account_api.TestSupport.prepareAuthenticated(&runtime, "account-1", "Metask User", "access-token", "refresh-token", 200),
    );
    // Nothing is left running: the Runtime itself would stop waking.
    account_api.TestSupport.joinSummary(&runtime);
    coordinator.drain();
    const report = coordinator.unauthorizedReport();
    report.report(3, .other);
    try std.testing.expect(Wakes.count.load(.acquire) != 0);
    coordinator.shutdown();
    try std.testing.expect(!runtime.effects.detached);
    const before = Wakes.count.load(.acquire);
    report.report(4, .token);
    try std.testing.expectEqual(before, Wakes.count.load(.acquire));
    try std.testing.expectEqual((4 << 1) | 1, coordinator.unauthorized.load(.acquire));
}

test "Account commit installs, renews, follows and settles in that order" {
    var runtime = try initRuntimeForTest();
    var platform: account_api.TestSupport.Platform = .{ .now_unix_seconds = 100 };
    account_api.TestSupport.attachPlatform(&runtime, &platform);
    defer {
        account_api.TestSupport.detachPlatform(&runtime);
        runtime.deinit();
    }
    var steps: CommitSteps = .{};
    var sink: RecordingSink = .{ .runtime = &runtime, .steps = &steps };
    var coordinator = Coordinator.init(&runtime, sink.port(), std.Thread.getCurrentId());
    coordinator.setFollower(steps.follower());
    coordinator.setCredentialRenewal(steps.renewal());
    _ = coordinator.commitPrepared(
        try account_api.TestSupport.prepareAuthenticated(&runtime, "account-1", "Metask User", "access-token", "refresh-token", 200),
    );
    try std.testing.expectEqualSlices(CommitSteps.Step, &.{ .commit, .renew, .follow, .settle }, steps.take()[0..4]);
    // The same credential is not delivered twice.
    _ = coordinator.commandSink().submit(.begin_login);
    _ = coordinator.commandSink().submit(.cancel_operation);
    try std.testing.expect(std.mem.indexOfScalar(CommitSteps.Step, steps.take(), .renew) == null);

    // A token that ended is retired once nothing can accept it, which no wall
    // clock decides, and is not inspected any more after that.
    _ = coordinator.commandSink().submit(.logout);
    _ = steps.take();
    platform.boot_seconds = 259;
    platform.now_unix_seconds = 100_000;
    try std.testing.expect(!coordinator.tick());
    try std.testing.expectEqual(@as(usize, 0), steps.take().len);
    platform.boot_seconds = 260;
    try std.testing.expect(!coordinator.tick());
    try std.testing.expectEqualSlices(CommitSteps.Step, &.{.retire}, steps.take());
    try std.testing.expect(runtime.credentials.retired == null);
}

const ClosingRefreshTransport = struct {
    gated: bool = false,
    started: std.Io.Event = .unset,
    release: std.Io.Event = .unset,
    calls: usize = 0,
    observed_cancel: bool = false,

    fn port(self: *@This()) account_api.Transport {
        return .{ .context = self, .perform_fn = perform, .retire_fn = account_api.retireNothing };
    }
    fn perform(context: *anyopaque, request: account_api.TransportRequest, output: []u8) account_api.TransportError!account_api.TransportResponse {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.calls += 1;
        if (request.kind != .refresh_token) return error.ProtocolFailed;
        if (self.gated) {
            self.started.set(std.testing.io);
            self.release.wait(std.testing.io) catch return error.NetworkFailed;
        }
        self.observed_cancel = request.control.?.cancellation.isCancelled();
        if (self.observed_cancel) return error.Cancelled;
        const body = "{\"access_token\":\"new-access\",\"refresh_token\":\"new-refresh\",\"token_type\":\"Bearer\",\"expires_in\":3600}";
        @memcpy(output[0..body.len], body);
        return .{ .status = 200, .body = output[0..body.len] };
    }
    fn releaseOnTimerStop(context: *anyopaque, _: u64) !void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.release.set(std.testing.io);
    }
};

test "Account shutdown saves mailbox or in-flight rotation once before detaching ports" {
    for ([_]bool{ false, true }) |in_flight| {
        var transport: ClosingRefreshTransport = .{ .gated = in_flight };
        var runtime = account_api.Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId(), transport.port(), account_api.TestSupport.loopbackEndpoint(), .{ .context = &testing_wake_context, .notify_fn = testingWake });
        defer runtime.deinit();
        var platform: account_api.TestSupport.Platform = .{};
        try platform.setStoredRefreshToken("old-refresh");
        account_api.TestSupport.attachPlatform(&runtime, &platform);
        if (in_flight) runtime.platform.?.timer = .{ .context = &transport, .start_fn = ClosingTimer.start, .cancel_fn = ClosingRefreshTransport.releaseOnTimerStop };
        var auth = try account_api.TestSupport.prepareAuthenticatedAndSchedule(&runtime, "account-1", "Metask", "old-access", "old-refresh", 200);
        defer auth.deinit();
        runtime.commit(&auth);
        var sink: RecordingSink = .{ .runtime = &runtime };
        var coordinator = Coordinator.init(&runtime, sink.port(), std.Thread.getCurrentId());
        try std.testing.expect(!coordinator.tick());
        // A direct refresh does not schedule unrelated summary or catalog work.
        var refresh = account_api.TestSupport.prepareTokenRefresh(&runtime);
        defer refresh.deinit();
        try std.testing.expect(runtime.admitEffect(&refresh));
        runtime.commit(&refresh);
        runtime.dispatchCommitted();
        if (in_flight) try transport.started.wait(std.testing.io) else account_api.TestSupport.joinNetwork(&runtime);
        var follower: RecordingFollower = .{};
        coordinator.setFollower(follower.port());
        coordinator.shutdown();
        coordinator.drain();
        try std.testing.expectEqualStrings("new-refresh", platform.refresh_token[0..platform.refresh_token_len.?]);
        try std.testing.expectEqual(@as(usize, 1), platform.credential_write_count);
        try std.testing.expect(platform.refresh_marker == null);
        try std.testing.expectEqual(@as(usize, 1), transport.calls);
        try std.testing.expect(!transport.observed_cancel);
        try std.testing.expectEqual(@as(usize, 0), follower.calls);
        try std.testing.expectEqual(@as(usize, if (in_flight) 0 else 1), platform.timer_start_count);
        try std.testing.expectEqual(@as(usize, 1), sink.count);
        try std.testing.expectEqual(account_contract.AccountState.signed_out, runtime.view().state);
        try std.testing.expect(coordinator.commandSink().submit(.begin_login).error_code == .invalid_state);
        try std.testing.expect(runtime.platform == null);
        try std.testing.expect(runtime.summary_job == null);
        try std.testing.expect(runtime.credentials.current == null);
    }
}

test "Account shutdown leaves a renewal that answers no cancel and returns within its close wait" {
    const Stuck = struct {
        started: std.Io.Event = .unset,
        release: std.Io.Event = .unset,

        fn port(self: *@This()) account_api.Transport {
            return .{ .context = self, .perform_fn = perform, .retire_fn = account_api.retireNothing };
        }
        fn perform(context: *anyopaque, request: account_api.TransportRequest, _: []u8) account_api.TransportError!account_api.TransportResponse {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (request.kind != .refresh_token) return error.ProtocolFailed;
            // Like DNS: no cancel reaches it.
            self.started.set(std.testing.io);
            self.release.waitUncancelable(std.testing.io);
            return error.NetworkFailed;
        }
    };
    var transport: Stuck = .{};
    var runtime = account_api.Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId(), transport.port(), account_api.TestSupport.loopbackEndpoint(), .{ .context = &testing_wake_context, .notify_fn = testingWake });
    var platform: account_api.TestSupport.Platform = .{};
    try platform.setStoredRefreshToken("old-refresh");
    account_api.TestSupport.attachPlatform(&runtime, &platform);
    defer {
        transport.release.set(std.testing.io);
        runtime.deinit();
    }
    var auth = try account_api.TestSupport.prepareAuthenticated(&runtime, "account-1", "Metask", "old-access", "old-refresh", 200);
    defer auth.deinit();
    runtime.commit(&auth);
    var sink: RecordingSink = .{ .runtime = &runtime };
    var coordinator = Coordinator.init(&runtime, sink.port(), std.Thread.getCurrentId());
    var refresh = account_api.TestSupport.prepareTokenRefresh(&runtime);
    defer refresh.deinit();
    try std.testing.expect(runtime.admitEffect(&refresh));
    runtime.commit(&refresh);
    runtime.dispatchCommitted();
    try transport.started.wait(std.testing.io);
    runtime.close_wait = .fromMilliseconds(50);
    const begun: std.Io.Clock.Timestamp = .now(std.testing.io, .awake);
    coordinator.shutdown();
    const waited_ns = std.Io.Clock.Timestamp.now(std.testing.io, .awake).raw.nanoseconds - begun.raw.nanoseconds;
    try std.testing.expect(waited_ns < 2 * std.time.ns_per_s);
    try std.testing.expect(runtime.detached() and runtime.platform == null);
    // Left running, the renewal keeps its marker.
    try std.testing.expect(platform.refresh_marker != null);
}

const ClosingTimer = struct {
    fn start(_: *anyopaque, _: u64, _: u64, _: bool) !void {}
};

test "Account shutdown failed rotation save preserves durable block without a second write" {
    var transport: ClosingRefreshTransport = .{};
    var runtime = account_api.Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId(), transport.port(), account_api.TestSupport.loopbackEndpoint(), .{ .context = &testing_wake_context, .notify_fn = testingWake });
    defer runtime.deinit();
    var platform: account_api.TestSupport.Platform = .{ .credential_write_fails = true };
    try platform.setStoredRefreshToken("old-refresh");
    account_api.TestSupport.attachPlatform(&runtime, &platform);
    var auth = try account_api.TestSupport.prepareAuthenticated(&runtime, "account-1", "Metask", "old-access", "old-refresh", 200);
    defer auth.deinit();
    runtime.commit(&auth);
    var sink: RecordingSink = .{ .runtime = &runtime };
    var coordinator = Coordinator.init(&runtime, sink.port(), std.Thread.getCurrentId());
    var refresh = account_api.TestSupport.prepareTokenRefresh(&runtime);
    defer refresh.deinit();
    try std.testing.expect(runtime.admitEffect(&refresh));
    runtime.commit(&refresh);
    runtime.dispatchCommitted();
    coordinator.shutdown();
    try std.testing.expectEqual(@as(usize, 1), platform.credential_write_count);
    try std.testing.expectEqualStrings("old-refresh", platform.refresh_token[0..platform.refresh_token_len.?]);
    try std.testing.expect(platform.refresh_marker != null);
    try std.testing.expectEqual(@as(usize, 1), sink.count);
}
