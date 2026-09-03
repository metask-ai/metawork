const std = @import("std");
const builtin = @import("builtin");
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
        const continues_active_attempt =
            self.runtime.preparedContinuesActiveAttempt(&prepared);

        const effect_admitted = self.runtime.admitEffect(&prepared);
        if (!effect_admitted and !continues_active_attempt)
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
        self.runtime.dispatchCommitted(&prepared);
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
        const result = self.commitPrepared(self.runtime.prepareShutdown());
        std.debug.assert(result.accepted);
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
    records: [4]RecordedCommit = undefined,
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

fn initRuntimeForTest(path: []const u8) !account_api.Runtime {
    return account_api.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        std.Thread.getCurrentId(),
        path,
        testingTransport(),
        account_api.TestSupport.loopbackEndpoint(),
        .{ .context = &testing_wake_context, .notify_fn = testingWake },
    );
}

test "Account coordinator commits identity before notifying Product" {
    var runtime = try initRuntimeForTest(if (builtin.os.tag == .windows)
        "C:\\metawork-account-coordinator-order-test"
    else
        "/tmp/metawork-account-coordinator-order-test");
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
    var runtime = try initRuntimeForTest(if (builtin.os.tag == .windows)
        "C:\\metawork-account-coordinator-attempt-test"
    else
        "/tmp/metawork-account-coordinator-attempt-test");
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
    var runtime = try initRuntimeForTest(if (builtin.os.tag == .windows)
        "C:\\metawork-account-coordinator-initial-admission-test"
    else
        "/tmp/metawork-account-coordinator-initial-admission-test");
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
    var runtime = try initRuntimeForTest(if (builtin.os.tag == .windows)
        "C:\\metawork-account-coordinator-continuation-admission-test"
    else
        "/tmp/metawork-account-coordinator-continuation-admission-test");
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

    const result = coordinator.commitPrepared(
        account_api.TestSupport.prepareTokensPersisted(&runtime),
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
}

test "Account mailbox collision becomes one typed terminal failure" {
    var runtime = try initRuntimeForTest(if (builtin.os.tag == .windows)
        "C:\\metawork-account-mailbox-collision-test"
    else
        "/tmp/metawork-account-mailbox-collision-test");
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
    account_api.TestSupport.publishFailure(&runtime, attempt_id, .oauth_callback_rejected);
    account_api.TestSupport.publishFailure(&runtime, attempt_id, .deadline_exceeded);

    coordinator.drain();

    try std.testing.expectEqual(@as(usize, 1), sink.count);
    try std.testing.expect(sink.records[0].attempt_terminal);
    try std.testing.expectEqual(account_contract.AccountState.signed_out, runtime.view().state);
    try std.testing.expectEqual(
        account_contract.ErrorCode.account_operation_failed,
        runtime.view().error_code,
    );
}

test "Account shutdown publishes one terminal fact for an active attempt" {
    var runtime = try initRuntimeForTest(if (builtin.os.tag == .windows)
        "C:\\metawork-account-shutdown-terminal-test"
    else
        "/tmp/metawork-account-shutdown-terminal-test");
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
