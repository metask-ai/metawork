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
    stopping: bool = false,

    pub fn init(
        runtime: *account_api.Runtime,
        control: control_ports.AccountCommitSink,
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
        if (command == .refresh_summary) {
            const refreshed = self.runtime.refreshSummary();
            if (refreshed.changed) self.commitSummaryNoFail();
            return refreshed.result;
        }
        if (command == .open_recharge)
            return self.runtime.openRechargePage();
        return switch (self.runtime.prepareCommand(command)) {
            .prepared => |prepared| self.commitPrepared(prepared),
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
        // A message that began to wait is a reason to try now.
        if (self.credential_renewal) |renewal| switch (self.runtime.authorization().use()) {
            .wait => |epoch| if (renewal.waits(epoch)) self.runtime.expedite(),
            .ready, .stop => {},
        };
        var committed = false;
        while (self.runtime.prepareDue()) |prepared| {
            if (!self.commitPrepared(prepared).accepted) break;
            committed = true;
        }
        return committed;
    }

    pub fn drain(self: *Coordinator) void {
        self.assertMainThread();
        if (self.stopping) return;
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
        var credential = (self.runtime.credential() catch {
            self.delivered_generation = generation;
            renewal.renew(generation, null);
            return;
        }) orelse return;
        defer credential.deinit();
        std.debug.assert(credential.authorization_generation == generation);
        self.delivered_generation = generation;
        renewal.renew(generation, credential.access_token);
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

        const fact = self.runtime.preparedFact(&prepared);
        const attempt_id = prepared.attemptId();
        const attempt_terminal = prepared.finishesAttempt();
        const attempt_disposition = self.runtime.attemptDisposition(&prepared);

        const effect_admitted = self.runtime.admitEffect(&prepared);
        if (!effect_admitted and attempt_disposition != .continues)
            return .rejected(.local_resource_exhausted);

        // Account commits its own state first; every later step is no-fail and
        // cannot re-enter or roll back that transaction. Product learns the
        // fact and its credential before anyone uses it, running executions
        // take the credential before the catalog follows, and scheduled work
        // rearms only once all of them agree.
        self.runtime.commit(&prepared);
        self.control.commitNoFail(.{
            .fact = fact,
            .attempt_id = attempt_id,
            .attempt_terminal = attempt_terminal,
        });
        self.deliverCredential();
        if (self.follower) |follower| follower.follow(self.runtime.authorization());
        self.control.settleNoFail();
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
    }

    fn commitSummaryNoFail(self: *Coordinator) void {
        self.control.commitNoFail(.{
            .fact = self.runtime.summaryFact(),
            .attempt_id = null,
            .attempt_terminal = false,
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
    kind: account_contract.AccountFactKind,
    state: account_contract.AccountState,
    attempt_id: ?u64,
    attempt_terminal: bool,
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
        std.debug.assert(self.unsettled);
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

        self.records[self.count] = .{
            .kind = value.fact.kind,
            .state = value.fact.view.state,
            .attempt_id = value.attempt_id,
            .attempt_terminal = value.attempt_terminal,
        };
        self.count += 1;
        std.debug.assert(!self.unsettled);
        self.unsettled = true;
        if (self.steps) |steps| steps.add(.commit);
    }
};

const CommitSteps = struct {
    const Step = enum { commit, renew, renew_failed, follow, settle };
    items: [16]Step = undefined,
    count: usize = 0,

    fn add(self: *CommitSteps, step: Step) void {
        self.items[self.count] = step;
        self.count += 1;
    }

    fn take(self: *CommitSteps) []const Step {
        defer self.count = 0;
        return self.items[0..self.count];
    }

    fn renewal(self: *CommitSteps) control_ports.MetaskCredentialRenewal {
        return .{ .context = self, .renew_fn = renew, .needs_fn = needs, .waits_fn = waits };
    }

    fn renew(context: *anyopaque, generation: u64, credential: ?[]const u8) void {
        const self: *CommitSteps = @ptrCast(@alignCast(context));
        std.debug.assert(generation != 0);
        self.add(if (credential == null) .renew_failed else .renew);
    }

    fn needs(_: *anyopaque, _: u64) bool {
        return false;
    }

    fn waits(_: *anyopaque, _: u64) bool {
        return false;
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
    try std.testing.expectEqual(account_contract.SummaryAvailability.unavailable, ready.summary.wallet.availability);
    try std.testing.expectEqual(account_contract.SummaryAvailability.unavailable, ready.summary.usage.availability);
    try std.testing.expectEqual(@as(usize, 1), transport.request_count);
    try std.testing.expectEqual(@as(usize, 1), transport.history_request_count);
    try std.testing.expectEqual(account_contract.SummaryAvailability.ready, ready.summary.history.availability);
    try std.testing.expectEqualStrings("60", ready.summary.history.days[0].total_tokens);

    transport.fail_history = true;
    const refresh = coordinator.commandSink().submit(.refresh_summary);
    try std.testing.expect(refresh.accepted);
    const duplicate = coordinator.commandSink().submit(.refresh_summary);
    try std.testing.expect(!duplicate.accepted);
    try std.testing.expectEqual(account_contract.ErrorCode.operation_in_progress, duplicate.error_code);
    account_api.TestSupport.joinSummary(&runtime);
    coordinator.drain();
    const history_stale = runtime.view();
    try std.testing.expectEqual(account_contract.SummaryAvailability.stale, history_stale.summary.history.availability);
    try std.testing.expectEqual(account_contract.ErrorCode.metask_service_unavailable, history_stale.summary.history.error_code);
    try std.testing.expectEqualStrings("60", history_stale.summary.history.days[0].total_tokens);
}

test "Account summary stays across renewals and is fetched again behind them" {
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

    // Expiry and the renewal of the same account leave it as it is.
    platform.now_unix_seconds = start + 200;
    try std.testing.expect(coordinator.tick());
    try expectHistory(&runtime, .ready, 1, &transport);
    transport.bearer = "access-odd";
    account_api.TestSupport.joinNetwork(&runtime);
    coordinator.drain();
    try std.testing.expectEqual(account_contract.SummaryOperation.refreshing, runtime.view().summary.operation);
    try std.testing.expectEqual(account_contract.SummaryAvailability.ready, runtime.view().summary.history.availability);
    account_api.TestSupport.joinSummary(&runtime);
    coordinator.drain();
    try expectHistory(&runtime, .ready, 2, &transport);

    // Failing to read it again only marks what is shown.
    transport.fail_history = true;
    transport.bearer = "access-even";
    platform.now_unix_seconds = start + 4000;
    try std.testing.expect(coordinator.tick());
    account_api.TestSupport.joinNetwork(&runtime);
    coordinator.drain();
    account_api.TestSupport.joinSummary(&runtime);
    coordinator.drain();
    try expectHistory(&runtime, .stale, 3, &transport);

    sink.count = 0;
    // A renewal during a request does not repeat it; its end does, once.
    transport.fail_history = false;
    transport.held = true;
    try std.testing.expect(coordinator.commandSink().submit(.refresh_summary).accepted);
    try transport.started.wait(std.testing.io);
    platform.now_unix_seconds = start + 8000;
    try std.testing.expect(coordinator.tick());
    account_api.TestSupport.joinNetwork(&runtime);
    coordinator.drain();
    try expectHistory(&runtime, .stale, 4, &transport);
    transport.held = false;
    transport.bearer = "access-odd";
    transport.release.set(std.testing.io);
    account_api.TestSupport.joinSummary(&runtime);
    coordinator.drain();
    account_api.TestSupport.joinSummary(&runtime);
    coordinator.drain();
    try expectHistory(&runtime, .ready, 5, &transport);
    try std.testing.expect(runtime.summary_job == null);

    // Another account's sign-in takes it away.
    _ = coordinator.commitPrepared(account_api.TestSupport.prepareBeginLoginWithoutEffect(&runtime));
    try std.testing.expectEqual(account_contract.SummaryAvailability.unavailable, runtime.summary.view().history.availability);
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
    try std.testing.expectEqual(account_contract.SummaryAvailability.unavailable, summary.usage.availability);
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
    try std.testing.expectEqual(account_contract.AccountFactKind.restored, sink.records[0].kind);
    try std.testing.expectEqual(account_contract.AccountState.authenticated, sink.records[0].state);
    try std.testing.expectEqual(@as(?u64, null), sink.records[0].attempt_id);
    try std.testing.expect(!sink.records[0].attempt_terminal);
}

test "Account coordinator publishes explicit terminal attempt metadata" {
    var runtime = try initRuntimeForTest();
    defer runtime.deinit();
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

    const result = coordinator.commitPrepared(
        account_api.TestSupport.prepareLoggedOutAfterExternalCommit(&runtime),
    );

    try std.testing.expect(result.accepted);
    try std.testing.expectEqual(@as(usize, 2), sink.count);
    try std.testing.expectEqual(account_contract.AccountFactKind.signed_out, sink.records[1].kind);
    try std.testing.expectEqual(account_contract.AccountState.signed_out, sink.records[1].state);
    try std.testing.expect(sink.records[1].attempt_id != null);
    try std.testing.expect(sink.records[1].attempt_terminal);
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
    try std.testing.expect(!sink.records[0].attempt_terminal);
    try std.testing.expect(sink.records[1].attempt_terminal);
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

test "Account cancel admission collision rejects without committing or panicking" {
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
    defer account_api.TestSupport.clearEffectQueue(&runtime);

    const result = coordinator.commandSink().submit(.cancel_operation);

    try std.testing.expect(!result.accepted);
    try std.testing.expectEqual(
        account_contract.ErrorCode.local_resource_exhausted,
        result.error_code,
    );
    try std.testing.expectEqual(account_contract.AccountState.authorizing, runtime.view().state);
    try std.testing.expect(runtime.view().can_cancel);
    try std.testing.expectEqual(@as(usize, 0), sink.count);
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
    try std.testing.expectEqual(@as(usize, 1), sink.count);
    try std.testing.expect(sink.records[0].attempt_terminal);
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
    try std.testing.expect(sink.records[0].attempt_terminal);
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
    try std.testing.expect(sink.records[0].attempt_terminal);
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
    try std.testing.expect(sink.records[0].attempt_terminal);
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
    account_api.TestSupport.publishFailure(&runtime, runtime.account.activeAttempt().?, .account_operation_failed);
    try std.testing.expectEqual(.recovering, std.meta.activeTag(runtime.authorization()));
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

    // Without memory for the copy, running executions end; none may go on
    // with a credential Account already replaced.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    runtime.authorization_generation += 1;
    const allocator = runtime.allocator;
    runtime.allocator = failing.allocator();
    defer runtime.allocator = allocator;
    coordinator.deliverCredential();
    try std.testing.expectEqualSlices(CommitSteps.Step, &.{.renew_failed}, steps.take());
    coordinator.deliverCredential();
    try std.testing.expectEqual(@as(usize, 0), steps.take().len);
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
        var refresh = switch (runtime.prepareTokenRefresh()) {
            .prepared => |p| p,
            else => return error.TestUnexpectedResult,
        };
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
        try std.testing.expect(sink.records[0].attempt_terminal);
        try std.testing.expectEqual(account_contract.AccountState.signed_out, runtime.view().state);
        try std.testing.expect(coordinator.commandSink().submit(.begin_login).error_code == .invalid_state);
        try std.testing.expect(runtime.platform == null);
        try std.testing.expect(runtime.summary_job == null);
        try std.testing.expect(!runtime.credentials.refreshAvailable());
    }
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
    var refresh = switch (runtime.prepareTokenRefresh()) {
        .prepared => |p| p,
        else => return error.TestUnexpectedResult,
    };
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
