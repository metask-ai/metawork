const std = @import("std");
const account_contract = @import("metawork_account_contract");
const account_api = @import("metawork_account");
const control_ports = @import("metawork_product_control_ports");

pub const CommitObserver = struct {
    context: *anyopaque,
    notify_fn: *const fn (*anyopaque) void,

    fn notify(self: CommitObserver) void {
        self.notify_fn(self.context);
    }
};

pub const Coordinator = struct {
    runtime: *account_api.Runtime,
    control: control_ports.AccountCommitSink,
    main_thread_id: std.Thread.Id,
    commit_observer: ?CommitObserver = null,

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

    pub fn setCommitObserver(self: *Coordinator, observer: ?CommitObserver) void {
        self.assertMainThread();
        self.commit_observer = observer;
    }

    fn submitCommand(
        context: *anyopaque,
        command: account_contract.AccountCommand,
    ) account_contract.AccountCommandResult {
        const self: *Coordinator = @ptrCast(@alignCast(context));
        self.assertMainThread();
        if (command == .refresh_summary) {
            const refreshed = self.runtime.refreshSummary();
            if (refreshed.changed) self.commitSummaryNoFail();
            return refreshed.result;
        }
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

    pub fn onTimer(self: *Coordinator, timer_id: u64) bool {
        self.assertMainThread();
        const prepared_result = self.runtime.prepareTimer(timer_id) orelse
            return false;
        switch (prepared_result) {
            .prepared => |prepared| {
                const result = self.commitPrepared(prepared);
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
                    const committed = self.commitPrepared(prepared);
                    std.debug.assert(committed.accepted);
                },
                .rejected, .ignored_stale => {},
            }
        }
        if (self.runtime.drainSummary()) self.commitSummaryNoFail();
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

        // Account commits its own state first. The Product callback is no-fail,
        // so no Product result can re-enter or roll back the Account transaction.
        self.runtime.commit(&prepared);
        self.control.commitNoFail(.{
            .fact = fact,
            .attempt_id = attempt_id,
            .attempt_terminal = attempt_terminal,
        });
        if (self.commit_observer) |observer| observer.notify();
        if (self.runtime.reconcileSummaryAuthorization())
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
        const dispatch_follow_up = self.runtime.dispatchCommitted(&prepared);
        if (dispatch_follow_up) |follow_up| {
            const followed = self.commitPrepared(follow_up);
            std.debug.assert(followed.accepted);
        }
        if (refresh_after_commit) {
            const refreshed = self.commitPrepared(
                self.runtime.prepareRestoredRefresh(),
            );
            std.debug.assert(refreshed.accepted);
        }
        return .acceptedAttempt(attempt_id);
    }

    pub fn shutdown(self: *Coordinator) void {
        self.assertMainThread();
        _ = self.runtime.shutdownSummary();
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
    }

    fn assertMainThread(self: *const Coordinator) void {
        std.debug.assert(std.Thread.getCurrentId() == self.main_thread_id);
    }
};

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

    fn port(self: *RecordingSink) control_ports.AccountCommitSink {
        return .{
            .context = self,
            .commit_fn = commit,
        };
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
    }
};

const AuthorizationObserver = struct {
    runtime: *account_api.Runtime,
    expected_generation: u64,
    calls: usize = 0,
    unavailable: bool = false,

    fn port(self: *AuthorizationObserver) CommitObserver {
        return .{ .context = self, .notify_fn = notify };
    }

    fn notify(context: *anyopaque) void {
        const self: *AuthorizationObserver = @ptrCast(@alignCast(context));
        self.calls += 1;
        var lease = (self.runtime.authorizationLease() catch {
            self.unavailable = true;
            return;
        }) orelse {
            self.unavailable = true;
            return;
        };
        defer lease.deinit();
        if (lease.authorization_generation != self.expected_generation)
            self.unavailable = true;
    }
};

var testing_transport_context: u8 = 0;
var testing_wake_context: u8 = 0;

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
    run_mode: enum { standard, simple } = .standard,
    fail_wallet: bool = false,
    fail_usage: bool = false,
    fail_history: bool = false,
    request_count: usize = 0,
    usage_request_count: usize = 0,
    history_request_count: usize = 0,

    fn port(self: *SummaryTransport) account_api.Transport {
        return .{ .context = self, .perform_fn = perform };
    }

    fn perform(
        context: *anyopaque,
        request: account_api.TransportRequest,
        output: []u8,
    ) account_api.TransportError!account_api.TransportResponse {
        const self: *SummaryTransport = @ptrCast(@alignCast(context));
        if (!std.mem.eql(u8, request.bearer orelse "", "access-token"))
            return error.ProtocolFailed;
        self.request_count += 1;
        const body = switch (request.kind) {
            .current_user => blk: {
                if (self.fail_wallet) {
                    const failure = "{}";
                    @memcpy(output[0..failure.len], failure);
                    return .{ .status = 401, .body = output[0..failure.len] };
                }
                break :blk switch (self.run_mode) {
                    .standard =>
                    \\{"code":0,"data":{"id":42,"username":"Meta User","balance":100.25,"run_mode":"standard","email":"not-projected@example.com"}}
                    ,
                    .simple =>
                    \\{"code":0,"data":{"id":42,"username":"Meta User","balance":100.25,"run_mode":"simple"}}
                    ,
                };
            },
            .usage_dashboard => blk: {
                self.usage_request_count += 1;
                if (self.fail_usage) {
                    const failure = "{}";
                    @memcpy(output[0..failure.len], failure);
                    return .{ .status = 503, .body = output[0..failure.len] };
                }
                break :blk
                \\{"code":0,"data":{"total_tokens":120400000,"total_actual_cost":23420.1178,"today_input_tokens":344800,"today_output_tokens":496100,"today_cache_creation_tokens":0,"today_cache_read_tokens":1490000,"today_tokens":2340900,"today_actual_cost":149.739}}
                ;
            },
            .usage_history => {
                self.history_request_count += 1;
                if (self.fail_history) {
                    const failure = "{}";
                    @memcpy(output[0..failure.len], failure);
                    return .{ .status = 503, .body = output[0..failure.len] };
                }
                const range = request.usage_history_range orelse
                    return error.ProtocolFailed;
                const rendered = std.fmt.bufPrint(
                    output,
                    "{{\"code\":0,\"data\":{{\"trend\":[{{\"date\":\"{s}\",\"requests\":1,\"input_tokens\":10,\"output_tokens\":20,\"cache_creation_tokens\":0,\"cache_read_tokens\":30,\"total_tokens\":60,\"cost\":2,\"actual_cost\":1.25}}],\"start_date\":\"{s}\",\"end_date\":\"{s}\",\"granularity\":\"day\"}}}}",
                    .{ range.end_date, range.start_date, range.end_date },
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

test "Account summary auto-sync is single-flight and preserves partial stale data" {
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
    try std.testing.expectEqual(account_contract.SummaryAvailability.ready, ready.summary.wallet.availability);
    try std.testing.expectEqual(account_contract.SummaryAvailability.ready, ready.summary.usage.availability);
    try std.testing.expectEqual(@as(usize, 1), transport.history_request_count);
    try std.testing.expectEqual(account_contract.SummaryAvailability.ready, ready.summary.history.availability);
    try std.testing.expectEqualStrings("100.25", ready.summary.wallet.balance_u);
    try std.testing.expectEqualStrings("2340900", ready.summary.usage.today.?.total_tokens);
    try std.testing.expectEqualStrings("60", ready.summary.history.days[0].total_tokens);
    try std.testing.expect(std.mem.indexOf(u8, ready.summary.wallet.balance_u, "access-token") == null);

    transport.fail_usage = true;
    const refresh = coordinator.commandSink().submit(.refresh_summary);
    try std.testing.expect(refresh.accepted);
    const duplicate = coordinator.commandSink().submit(.refresh_summary);
    try std.testing.expect(!duplicate.accepted);
    try std.testing.expectEqual(account_contract.ErrorCode.operation_in_progress, duplicate.error_code);
    account_api.TestSupport.joinSummary(&runtime);
    coordinator.drain();
    const partial = runtime.view();
    try std.testing.expectEqual(account_contract.SummaryAvailability.ready, partial.summary.wallet.availability);
    try std.testing.expectEqual(account_contract.SummaryAvailability.stale, partial.summary.usage.availability);
    try std.testing.expectEqual(account_contract.SummaryAvailability.ready, partial.summary.history.availability);
    try std.testing.expectEqual(account_contract.ErrorCode.metask_service_unavailable, partial.summary.usage.error_code);
    try std.testing.expectEqualStrings("120400000", partial.summary.usage.total.?.total_tokens);

    transport.fail_usage = false;
    transport.fail_history = true;
    try std.testing.expect(coordinator.commandSink().submit(.refresh_summary).accepted);
    account_api.TestSupport.joinSummary(&runtime);
    coordinator.drain();
    const history_stale = runtime.view();
    try std.testing.expectEqual(account_contract.SummaryAvailability.ready, history_stale.summary.usage.availability);
    try std.testing.expectEqual(account_contract.SummaryAvailability.stale, history_stale.summary.history.availability);
    try std.testing.expectEqual(account_contract.ErrorCode.metask_service_unavailable, history_stale.summary.history.error_code);
    try std.testing.expectEqualStrings("60", history_stale.summary.history.days[0].total_tokens);

    transport.fail_history = false;
    transport.fail_wallet = true;
    try std.testing.expect(coordinator.commandSink().submit(.refresh_summary).accepted);
    account_api.TestSupport.joinSummary(&runtime);
    coordinator.drain();
    const unauthorized = runtime.view();
    try std.testing.expectEqual(account_contract.AccountState.authenticated, unauthorized.state);
    try std.testing.expectEqual(account_contract.SummaryAvailability.stale, unauthorized.summary.wallet.availability);
    try std.testing.expectEqual(account_contract.ErrorCode.metask_unauthorized, unauthorized.summary.wallet.error_code);
}

test "Account summary skips usage endpoint in simple mode" {
    var transport: SummaryTransport = .{ .run_mode = .simple };
    var runtime = initRuntimeForSummaryTest(&transport);
    var platform: account_api.TestSupport.Platform = .{ .now_unix_seconds = 100 };
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
        200,
    ));
    account_api.TestSupport.joinSummary(&runtime);
    coordinator.drain();
    const summary = runtime.view().summary;
    try std.testing.expectEqual(@as(usize, 1), transport.request_count);
    try std.testing.expectEqual(@as(usize, 0), transport.usage_request_count);
    try std.testing.expectEqual(@as(usize, 0), transport.history_request_count);
    try std.testing.expectEqual(account_contract.UsageEligibility.disabled, summary.usage_eligibility);
    try std.testing.expectEqual(account_contract.SummaryAvailability.unavailable, summary.usage.availability);
    try std.testing.expectEqual(account_contract.SummaryAvailability.unavailable, summary.history.availability);
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

    try ports.timer.start(7, 123, false);
    try std.testing.expectEqual(@as(usize, 1), platform.timer_start_count);
    try std.testing.expectEqual(@as(?u64, 7), platform.last_timer_id);
    try std.testing.expectEqual(@as(u64, 123), platform.last_timer_interval_ns);

    platform.timer_start_fails = true;
    try std.testing.expectError(
        error.TimerStartFailed,
        ports.timer.start(8, 456, false),
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
    // Identity, automatic summary start, then refresh-schedule failure.
    try std.testing.expectEqual(@as(usize, 3), sink.count);
    try std.testing.expectEqual(
        account_contract.ErrorCode.refresh_schedule_failed,
        runtime.view().error_code,
    );
    var lease = (try runtime.authorizationLease()).?;
    lease.deinit();

    platform.timer_start_fails = false;
    sink.count = 0;
    const retried = coordinator.commandSink().submit(.retry_refresh);

    try std.testing.expect(retried.accepted);
    try std.testing.expectEqual(@as(usize, 1), sink.count);
    try std.testing.expectEqual(account_contract.ErrorCode.none, runtime.view().error_code);
    try std.testing.expectEqual(@as(usize, 2), platform.timer_start_count);
    try std.testing.expectEqual(@as(u64, 40 * std.time.ns_per_s), platform.last_timer_interval_ns);
}

test "Account clock and refresh retry arm failures publish refresh schedule failure" {
    var runtime = try initRuntimeForTest();
    var platform: account_api.TestSupport.Platform = .{
        .now_unix_seconds = null,
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
    try std.testing.expectEqual(
        account_contract.ErrorCode.refresh_schedule_failed,
        runtime.view().error_code,
    );

    platform.now_unix_seconds = 100;
    platform.timer_start_fails = true;
    sink.count = 0;
    _ = coordinator.commitPrepared(
        account_api.TestSupport.prepareRefreshRetrySchedule(&runtime),
    );
    // The newly available clock also admits the generation-bound summary job.
    try std.testing.expectEqual(@as(usize, 3), sink.count);
    try std.testing.expectEqual(
        account_contract.ErrorCode.refresh_schedule_failed,
        runtime.view().error_code,
    );
}

test "Account observer retains a healthy in-flight authorization during refresh" {
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
            150,
        ),
    );
    var lease = (try runtime.authorizationLease()).?;
    const generation = lease.authorization_generation;
    lease.deinit();
    var observer: AuthorizationObserver = .{
        .runtime = &runtime,
        .expected_generation = generation,
    };
    coordinator.setCommitObserver(observer.port());

    const refreshed = coordinator.commitPrepared(
        account_api.TestSupport.prepareTokenRefreshWithoutEffect(&runtime),
    );

    try std.testing.expect(refreshed.accepted);
    try std.testing.expectEqual(@as(usize, 1), observer.calls);
    try std.testing.expect(!observer.unavailable);
}
