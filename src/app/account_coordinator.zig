const std = @import("std");
const builtin = @import("builtin");
const account_contract = @import("metawork_account_contract");
const account_api = @import("metawork_account");
const control_ports = @import("metawork_product_control_ports");
const models_contract = if (builtin.is_test)
    @import("metawork_product_models_contract")
else
    struct {};

pub const Coordinator = struct {
    runtime: *account_api.Runtime,
    control: control_ports.AccountCommitSink,
    main_thread_id: std.Thread.Id,

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

        // Account commits its own state first. The Product callback is no-fail
        // and synchronously takes the optional candidate, so no Product result
        // can re-enter or roll back the Account transaction.
        self.runtime.commit(&prepared);
        self.control.commitNoFail(.{
            .fact = fact,
            .attempt_id = attempt_id,
            .attempt_terminal = attempt_terminal,
            .candidate = prepared.sourceCandidateTransfer(),
        });

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
        const follow_up = self.runtime.takeFollowUpCommand(&prepared);
        self.runtime.dispatchCommitted(&prepared);
        if (refresh_after_commit) {
            const refreshed = self.commitPrepared(
                self.runtime.prepareRestoredRefresh(),
            );
            std.debug.assert(refreshed.accepted);
        }
        if (follow_up) |command| self.submitFollowUp(command);
        return .acceptedAttempt(attempt_id);
    }

    fn submitFollowUp(
        self: *Coordinator,
        command: account_contract.AccountCommand,
    ) void {
        const result = submitCommand(self, command);
        if (result.accepted) return;
        switch (command) {
            .refresh_catalog => {
                const recovered = self.commitPrepared(
                    self.runtime.prepareContinuationFailure(result.error_code),
                );
                std.debug.assert(recovered.accepted);
            },
            else => {},
        }
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
    candidate_source_generation: ?u64,
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
        std.debug.assert(committed_view.catalog_state == value.fact.view.catalog_state);
        std.debug.assert(std.mem.eql(
            u8,
            committed_view.account_id,
            value.fact.view.account_id,
        ));

        var candidate_source_generation: ?u64 = null;
        if (value.candidate) |transfer| {
            var candidate = transfer.take();
            defer candidate.deinit();
            candidate_source_generation = candidate.input().source_generation;
        }
        self.records[self.count] = .{
            .kind = value.fact.kind,
            .state = value.fact.view.state,
            .attempt_id = value.attempt_id,
            .attempt_terminal = value.attempt_terminal,
            .candidate_source_generation = candidate_source_generation,
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

fn testSourceCandidate(
    source_generation: u64,
) !models_contract.OwnedSourceCandidate {
    return models_contract.OwnedSourceCandidate.initOwned(
        std.testing.allocator,
        .metask,
        .anthropic_messages,
        try std.testing.allocator.dupe(u8, "model-1"),
        try std.testing.allocator.dupe(
            u8,
            account_contract.metask_anthropic_messages_url,
        ),
        source_generation,
        try std.testing.allocator.dupe(u8, "secret-key"),
        "key-1",
    );
}

test "Account coordinator commits before transferring one source candidate" {
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
    var candidate = try testSourceCandidate(41);
    defer candidate.deinit();

    const result = coordinator.commitPrepared(
        try account_api.TestSupport.prepareReadyRestore(&runtime, &candidate),
    );

    try std.testing.expect(result.accepted);
    try std.testing.expectEqual(@as(usize, 1), sink.count);
    try std.testing.expectEqual(account_contract.AccountFactKind.restored, sink.records[0].kind);
    try std.testing.expectEqual(account_contract.AccountState.authenticated, sink.records[0].state);
    try std.testing.expectEqual(@as(?u64, null), sink.records[0].attempt_id);
    try std.testing.expect(!sink.records[0].attempt_terminal);
    try std.testing.expectEqual(@as(?u64, 41), sink.records[0].candidate_source_generation);
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
    var candidate = try testSourceCandidate(51);
    defer candidate.deinit();
    _ = coordinator.commitPrepared(
        try account_api.TestSupport.prepareReadyRestore(&runtime, &candidate),
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
    try std.testing.expectEqual(@as(?u64, null), sink.records[1].candidate_source_generation);
}
