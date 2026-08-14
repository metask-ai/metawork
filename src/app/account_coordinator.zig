const std = @import("std");
const builtin = @import("builtin");
const agent = @import("metawork_agent");
const account_contract = @import("metawork_account_contract");
const account_api = @import("metawork_account");
const workbench_api = @import("metawork_workbench");

const ExecutionReplacement = enum { none, startup, default, identity };

pub const Coordinator = struct {
    runtime: *account_api.Runtime,
    workbench: *workbench_api.Workbench,
    main_thread_id: std.Thread.Id,

    pub fn init(
        runtime: *account_api.Runtime,
        workbench: *workbench_api.Workbench,
        main_thread_id: std.Thread.Id,
    ) Coordinator {
        return .{
            .runtime = runtime,
            .workbench = workbench,
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
        const current = self.runtime.view();
        const replacement: ExecutionReplacement = switch (command) {
            // Account model selection changes only the default for future
            // Tasks. Credential/provider execution generations stay intact.
            .select_model => .none,
            .begin_login => if (current.state == .authenticated) .identity else .none,
            .logout => .identity,
            else => .none,
        };
        return switch (self.runtime.prepareCommand(command)) {
            .prepared => |prepared| self.commitPrepared(prepared, replacement),
            .rejected => |error_code| .rejected(error_code),
            .ignored_stale => unreachable,
        };
    }

    pub fn start(
        self: *Coordinator,
        services: account_api.PlatformServices,
    ) void {
        self.assertMainThread();
        const result = self.commitPrepared(
            self.runtime.prepareStart(services),
            .startup,
        );
        std.debug.assert(result.accepted);
    }

    pub fn startAutomation(self: *Coordinator) void {
        self.assertMainThread();
        const result = self.commitPrepared(
            self.runtime.prepareAutomationStart(),
            .startup,
        );
        std.debug.assert(result.accepted);
    }

    pub fn startUnavailable(self: *Coordinator) void {
        self.assertMainThread();
        const result = self.commitPrepared(
            self.runtime.prepareStartUnavailable(),
            .startup,
        );
        std.debug.assert(result.accepted);
    }

    pub fn onTimer(self: *Coordinator, timer_id: u64) bool {
        self.assertMainThread();
        const prepared_result = self.runtime.prepareTimer(timer_id) orelse
            return false;
        switch (prepared_result) {
            .prepared => |prepared| {
                const result = self.commitPrepared(prepared, .none);
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
                    const committed = self.commitPrepared(prepared, .none);
                    std.debug.assert(committed.accepted);
                },
                .rejected, .ignored_stale => {},
            }
        }
    }

    fn commitPrepared(
        self: *Coordinator,
        prepared_value: account_api.Prepared,
        replacement: ExecutionReplacement,
    ) account_contract.AccountCommandResult {
        var prepared = prepared_value;
        defer prepared.deinit();

        var started_replacement = false;
        switch (replacement) {
            .none => {},
            // A cold process has no live Account-owned identity or credential
            // to replace. Restored Task history must not be mistaken for an
            // in-process identity switch, but installation still needs the
            // Workbench's default-execution transaction boundary.
            .startup, .default => {
                if (self.workbench.executionReplacementPending())
                    return .rejected(.operation_in_progress);
                self.workbench.beginDefaultExecutionReplacement() catch |err|
                    return .rejected(replacementErrorCode(err));
                started_replacement = true;
            },
            .identity => {
                if (self.workbench.executionReplacementPending())
                    return .rejected(.operation_in_progress);
                self.workbench.beginExecutionReplacement() catch |err|
                    return .rejected(replacementErrorCode(err));
                started_replacement = true;
            },
        }
        const effect_admitted = self.runtime.admitEffect(&prepared);
        if (!effect_admitted) {
            if (started_replacement) {
                self.endActiveReplacementNoFail();
                return .rejected(.local_resource_exhausted);
            }
            if (!self.workbench.executionReplacementPending())
                return .rejected(.local_resource_exhausted);
        }

        const fact = self.runtime.preparedFact(&prepared);
        const identity_boundary = prepared.identityReplacementBoundary();
        self.workbench.commitAccountFactNoFail(fact);
        if (prepared.takeExecution()) |execution_value| {
            var execution = execution_value;
            if (!self.workbench.executionReplacementPending()) {
                self.workbench.beginDefaultExecutionReplacement() catch
                    unreachable;
            }
            self.workbench.installExecutionNoFail(&execution);
        } else if (prepared.clearsDefaultExecution()) {
            if (!self.workbench.executionReplacementPending()) {
                self.workbench.beginDefaultExecutionReplacement() catch
                    unreachable;
            }
            self.workbench.clearExecutionNoFail();
        }
        self.runtime.commit(&prepared);

        // A continuation effect can fail admission only after its preceding
        // external step has completed. Commit that observed step first, then
        // terminate the still-active transaction from the resulting state.
        if (!effect_admitted)
            return self.commitPrepared(
                self.runtime.prepareActiveAttemptFailure(
                    .local_resource_exhausted,
                ),
                .none,
            );

        const refresh_after_commit = self.runtime.takeRefreshAfterCommit(&prepared);
        const follow_up = self.runtime.takeFollowUpCommand(&prepared);
        self.runtime.dispatchCommitted(&prepared);
        if (self.workbench.identityReplacementPending()) {
            if (identity_boundary != .none)
                self.endActiveReplacementNoFail();
        } else if (self.workbench.defaultExecutionReplacementPending() and
            prepared.operationComplete())
        {
            self.endActiveReplacementNoFail();
        }
        self.workbench.finishAccountCommitNoFail();

        if (refresh_after_commit) {
            const refreshed = self.commitPrepared(
                self.runtime.prepareRestoredRefresh(),
                .none,
            );
            std.debug.assert(refreshed.accepted);
        }
        if (follow_up) |command| self.submitFollowUp(command);
        return .acceptedAttempt(prepared.attemptId());
    }

    fn endActiveReplacementNoFail(self: *Coordinator) void {
        self.workbench.endExecutionReplacementNoFail();
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
                    .none,
                );
                std.debug.assert(recovered.accepted);
            },
            else => {},
        }
    }

    pub fn shutdown(self: *Coordinator) void {
        self.assertMainThread();
        const result = self.commitPrepared(
            self.runtime.prepareShutdown(),
            .none,
        );
        std.debug.assert(result.accepted);
    }

    fn assertMainThread(self: *const Coordinator) void {
        std.debug.assert(std.Thread.getCurrentId() == self.main_thread_id);
    }
};

fn replacementErrorCode(err: anyerror) account_contract.ErrorCode {
    return switch (err) {
        error.TaskRunning => .execution_in_use,
        error.TaskSessionInUse => .session_in_use,
        error.ExecutionInUse => .operation_in_progress,
        else => .local_resource_exhausted,
    };
}

test "Application maps identity replacement blockers precisely" {
    try std.testing.expectEqual(
        account_contract.ErrorCode.execution_in_use,
        replacementErrorCode(error.TaskRunning),
    );
    try std.testing.expectEqual(
        account_contract.ErrorCode.session_in_use,
        replacementErrorCode(error.TaskSessionInUse),
    );
    try std.testing.expectEqual(
        account_contract.ErrorCode.operation_in_progress,
        replacementErrorCode(error.ExecutionInUse),
    );
}

test "Application coordinator commits Account Runtime facts into Workbench" {
    const TestWake = struct {
        fn notify(_: *anyopaque) void {}
    };
    var wake_context: u8 = 0;
    var account_runtime = try account_api.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        std.Thread.getCurrentId(),
        if (builtin.os.tag == .windows)
            "C:\\metawork-account-coordinator-test"
        else
            "/tmp/metawork-account-coordinator-test",
        .{ .context = &wake_context, .notify_fn = TestWake.notify },
    );
    defer account_runtime.deinit();

    var agent_runtime: agent.Runtime = undefined;
    var workbench = try workbench_api.Workbench.init(
        std.testing.allocator,
        std.testing.io,
        &agent_runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 1,
            .max_tasks = 1,
            .max_runs_per_task = 1,
            .max_tools_per_run = 1,
        },
        .{},
    );
    defer workbench.deinit();
    var coordinator = Coordinator.init(
        &account_runtime,
        &workbench,
        std.Thread.getCurrentId(),
    );

    var execution = try account_contract.OwnedExecutionConfig.initOwned(
        std.testing.allocator,
        .anthropic,
        try std.testing.allocator.dupe(u8, "model-1"),
        try std.testing.allocator.dupe(
            u8,
            account_contract.metask_anthropic_messages_url,
        ),
        1,
        try std.testing.allocator.dupe(u8, "secret-key"),
    );
    defer execution.deinit();
    const restored = coordinator.commitPrepared(
        try account_api.TestSupport.prepareReadyRestore(&account_runtime, &execution),
        .startup,
    );
    try std.testing.expect(restored.accepted);
    try std.testing.expectEqual(
        account_contract.AccountState.authenticated,
        account_runtime.view().state,
    );
    try std.testing.expectEqual(
        account_contract.CatalogState.ready,
        account_runtime.view().catalog_state,
    );
    try std.testing.expectEqual(
        account_contract.AccountState.authenticated,
        workbench.accountView().state,
    );
    try std.testing.expect(workbench.accountView().can_create_task);

    const login = coordinator.commandSink().submit(.begin_login);
    try std.testing.expect(login.accepted);
    try std.testing.expect(workbench.executionReplacementPending());
    try std.testing.expect(!workbench.accountView().can_create_task);
    coordinator.drain();
    try std.testing.expectEqual(
        account_contract.AccountState.authenticated,
        account_runtime.view().state,
    );
    try std.testing.expect(!workbench.executionReplacementPending());
    try std.testing.expect(workbench.accountView().can_create_task);

    const cancelled_login = coordinator.commandSink().submit(.begin_login);
    try std.testing.expect(cancelled_login.accepted);
    try std.testing.expect(workbench.executionReplacementPending());
    const cancelled = coordinator.commandSink().submit(.cancel_operation);
    try std.testing.expect(cancelled.accepted);
    try std.testing.expect(!workbench.executionReplacementPending());
    try std.testing.expect(workbench.accountView().can_create_task);
    coordinator.drain();
    try std.testing.expectEqual(
        account_contract.AccountState.authenticated,
        account_runtime.view().state,
    );

    const logout = coordinator.commandSink().submit(.logout);
    try std.testing.expect(logout.accepted);
    try std.testing.expectEqual(
        account_contract.AccountState.authenticated,
        account_runtime.view().state,
    );
    try std.testing.expectEqual(
        account_contract.CatalogState.unavailable,
        account_runtime.view().catalog_state,
    );
    try std.testing.expectEqual(
        account_contract.CatalogState.unavailable,
        workbench.accountView().catalog_state,
    );
    try std.testing.expect(!account_runtime.view().can_cancel);

    coordinator.shutdown();
    try std.testing.expectEqual(
        account_contract.AccountState.signed_out,
        account_runtime.view().state,
    );
    try std.testing.expectEqual(
        account_contract.AccountState.signed_out,
        workbench.accountView().state,
    );
    try std.testing.expectEqual(
        account_contract.CatalogState.unavailable,
        workbench.accountView().catalog_state,
    );
    try std.testing.expectEqual(@as(usize, 0), workbench.accountView().api_keys.len);
    try std.testing.expectEqual(@as(usize, 0), workbench.accountView().models.len);
    try std.testing.expect(!workbench.accountView().can_create_task);
}

test "Application coordinator balances Workbench gate when Account effect admission fails" {
    const TestWake = struct {
        fn notify(_: *anyopaque) void {}
    };
    var wake_context: u8 = 0;
    var account_runtime = try account_api.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        std.Thread.getCurrentId(),
        if (builtin.os.tag == .windows)
            "C:\\metawork-account-admission-test"
        else
            "/tmp/metawork-account-admission-test",
        .{ .context = &wake_context, .notify_fn = TestWake.notify },
    );
    defer account_runtime.deinit();

    var agent_runtime: agent.Runtime = undefined;
    var workbench = try workbench_api.Workbench.init(
        std.testing.allocator,
        std.testing.io,
        &agent_runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 1,
            .max_tasks = 1,
            .max_runs_per_task = 1,
            .max_tools_per_run = 1,
        },
        .{},
    );
    defer workbench.deinit();
    var coordinator = Coordinator.init(
        &account_runtime,
        &workbench,
        std.Thread.getCurrentId(),
    );

    var execution = try account_contract.OwnedExecutionConfig.initOwned(
        std.testing.allocator,
        .anthropic,
        try std.testing.allocator.dupe(u8, "model-1"),
        try std.testing.allocator.dupe(
            u8,
            account_contract.metask_anthropic_messages_url,
        ),
        1,
        try std.testing.allocator.dupe(u8, "secret-key"),
    );
    defer execution.deinit();
    const restored = coordinator.commitPrepared(
        try account_api.TestSupport.prepareReadyRestore(&account_runtime, &execution),
        .startup,
    );
    try std.testing.expect(restored.accepted);
    const revision = workbench.currentRevision();

    account_api.TestSupport.occupyEffectQueue(&account_runtime);
    const rejected = coordinator.commandSink().submit(.logout);
    try std.testing.expect(!rejected.accepted);
    try std.testing.expectEqual(
        account_contract.ErrorCode.local_resource_exhausted,
        rejected.error_code,
    );
    try std.testing.expectEqual(
        account_contract.AccountState.authenticated,
        account_runtime.view().state,
    );
    try std.testing.expect(workbench.accountView().can_create_task);
    try std.testing.expectEqual(revision, workbench.currentRevision());
    try std.testing.expect(!workbench.executionReplacementPending());

    account_api.TestSupport.clearEffectQueue(&account_runtime);
    const login = coordinator.commandSink().submit(.begin_login);
    try std.testing.expect(login.accepted);
    try std.testing.expect(workbench.executionReplacementPending());
    account_api.TestSupport.discardMailbox(&account_runtime);
    account_api.TestSupport.occupyEffectQueue(&account_runtime);
    const continuation = coordinator.commitPrepared(
        account_api.TestSupport.prepareTokensPersisted(&account_runtime),
        .none,
    );
    try std.testing.expect(continuation.accepted);
    try std.testing.expectEqual(
        account_contract.AccountState.signed_out,
        account_runtime.view().state,
    );
    try std.testing.expectEqual(
        account_contract.ErrorCode.local_resource_exhausted,
        account_runtime.view().error_code,
    );
    try std.testing.expect(!workbench.executionReplacementPending());
    try std.testing.expect(!workbench.accountView().can_create_task);
    account_api.TestSupport.clearEffectQueue(&account_runtime);
    coordinator.shutdown();
}
