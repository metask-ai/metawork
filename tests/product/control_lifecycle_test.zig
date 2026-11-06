const fixture = @import("lifecycle_fixture");
const std = fixture.std;
const lifecycle = fixture.lifecycle;
const product_control = fixture.product_control;
const models_contract = fixture.models_contract;
const product_skill = fixture.product_skill;
const product_task = fixture.product_task;
const account_contract = fixture.account_contract;
const wire = fixture.wire;
const fake_core = &fixture.fake_core;
const openSession = fixture.openSession;
const submitSession = fixture.submitSession;
const closeSession = fixture.closeSession;
const shutdownTestComposition = fixture.shutdownTestComposition;
const deinitTestComposition = fixture.deinitTestComposition;
const createTestComposition = fixture.createTestComposition;
const productControlConfiguration = fixture.productControlConfiguration;
const productControlTaskInput = fixture.productControlTaskInput;
const waitControlSnapshot = fixture.waitProductControlSnapshot;
const installControlExecution = fixture.installProductControlExecution;
const installControlExecutionGeneration = fixture.installProductControlExecutionGeneration;
const task_state = product_task.testing.state_module;
const task_execution = product_task.testing.execution_module;

test "Agent drain shares one event budget across both terminal observations" {
    fake_core.reset();
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var control = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, .{
        .max_events_per_drain = 2,
        .max_event_drain_ns = std.math.maxInt(u64),
    }, productControlConfiguration());
    defer control.deinit();
    // Valid decoded events for an absent Task still exercise the complete
    // drain/catch path. No execution or producer can change these counts.
    for (0..5) |_| try runtime.events.enqueue(try fixture.pumpEnvelope(
        1,
        1,
        "{\"text_chunk\":\"queued\"}",
    ));
    try std.testing.expectError(error.UnknownTask, control.drainAgentEvents());
    try std.testing.expectEqual(@as(usize, 3), runtime.pendingEventCount(1));
    try std.testing.expectError(error.UnknownTask, control.drainAgentEvents());
    try std.testing.expectEqual(@as(usize, 1), runtime.pendingEventCount(1));
    try std.testing.expectError(error.UnknownTask, control.drainAgentEvents());
    try std.testing.expect(!runtime.hasPendingEvents());
}

test "only confirmed interactive Task choices remember a preference without replacing execution" {
    fake_core.reset();
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 2, .max_sessions = 2 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var workbench = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, .{ .worker_count = 1, .queue_capacity = 2, .max_tasks = 2, .max_workspaces = 1 }, productControlConfiguration());
    defer workbench.deinit();
    var vault: TaskModelsVault = .{};
    try workbench.startCustomProviders(root, vault.port());
    defer workbench.stopCustomProviders();
    try installControlExecution(&workbench);
    installTwoModelCatalog(&workbench);
    product_control.TestSupport.clearModelPreference(&workbench);
    var input = productControlTaskInput();
    input.workspace_root = root;
    input.trust = .explicitly_trusted;
    const workspace = try workbench.openWorkspace(input);
    const epoch = try workbench.workspaceEpoch(workspace);
    const first = try workbench.createTaskInWorkspace(workspace, epoch, newTaskModelSelectionInput(&workbench, "fixture-model"), null, null, .{ .interactive = .manual });
    try std.testing.expectEqualStrings("fixture-model", workbench.modelsView().default_selection.?.model_id);
    const second = try workbench.createTaskInWorkspace(workspace, epoch, newTaskModelSelectionInput(&workbench, "fixture-model-2"), null, null, .{ .noninteractive = .approval_required });
    try std.testing.expectEqualStrings("fixture-model", workbench.modelsView().default_selection.?.model_id);
    const source = workbench.modelsView().providers[0].source_generation;
    const catalog = workbench.modelsView().providers[0].catalog_generation;
    const security = workbench.projectionSecurityEpoch();
    const execution = workbench.executionGeneration();
    _ = try workbench.selectTaskModel(first, taskModelSelectionInput(&workbench, 1, "fixture-model-2"));
    try std.testing.expectEqualStrings("fixture-model-2", workbench.modelsView().default_selection.?.model_id);
    try std.testing.expectEqualStrings("fixture-model", workbench.task_runtime.find(first).?.runtime.executionConst().?.model);
    try std.testing.expectEqualStrings("fixture-model-2", workbench.task_runtime.find(second).?.runtime.executionConst().?.model);
    try std.testing.expectEqual(source, workbench.modelsView().providers[0].source_generation);
    try std.testing.expectEqual(catalog, workbench.modelsView().providers[0].catalog_generation);
    try std.testing.expectEqual(security, workbench.projectionSecurityEpoch());
    try std.testing.expectEqual(execution, workbench.executionGeneration());
    // A pending refresh cannot veto memory of the already confirmed choice.
    _ = workbench.prepareMetaskCatalogRefresh("account-1", 17);
    try std.testing.expect(workbench.custom_providers.rememberPreference(.{ .source_id = "metask", .model_id = "fixture-model" }).accepted);
    try std.testing.expectEqualStrings("fixture-model", workbench.modelsView().default_selection.?.model_id);
}

test "ordinary Task creation does not retry MCP errors on null Selection or generic Core failure" {
    for ([_]struct { status: u32, failure: anyerror }{
        .{ .status = wire.STATUS_MCP_NOT_REFRESHED, .failure = error.McpNotRefreshed },
        .{ .status = wire.STATUS_INVALID_MCP_SELECTION, .failure = error.InvalidMcpSelection },
        .{ .status = wire.STATUS_CORE_ERROR, .failure = error.CoreCallFailed },
    }) |case| {
        fake_core.reset();
        const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
        defer {
            shutdownTestComposition(runtime) catch unreachable;
            deinitTestComposition(runtime);
        }
        var control = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, .{
            .worker_count = 1,
            .queue_capacity = 1,
            .max_tasks = 1,
            .max_workspaces = 1,
        }, productControlConfiguration());
        defer control.deinit();
        try installControlExecution(&control);
        fake_core.forced_session_create_status = case.status;
        try std.testing.expectError(case.failure, control.createTask(productControlTaskInput(), try product_control.TestSupport.fixtureModelSelection(&control)));
        try std.testing.expectEqual(@as(usize, 0), fake_core.session_created);
        const task = try control.createTask(productControlTaskInput(), try product_control.TestSupport.fixtureModelSelection(&control));
        try std.testing.expectEqual(@as(u64, 1), task);
        try std.testing.expectEqual(@as(usize, 1), fake_core.session_created);
    }
}

test "recording gaps continue execution while later protocol or Host failures remain fatal" {
    const Failure = enum { none, protocol, receipt, allocation };
    inline for (std.meta.tags(Failure)) |failure| {
        const scenario = try ReviewScenario.initForInput(.controlled);
        defer scenario.deinit();
        defer fake_core.releaseControlled();
        const control = &scenario.control;
        const task = control.task_runtime.find(scenario.task_id).?;
        const run = task_state.findRun(task.durable.runs, task.runtime.active_run_id).?;
        const route = task.runtime.routeId();
        for (0..run.tools.len + 2) |index| {
            var storage: [256]u8 = undefined;
            const encoded = try std.fmt.bufPrint(&storage, "{{\"tool_start\":{{\"id\":\"retained-{d}\",\"name\":\"Read\",\"input\":\"file\"}}}}", .{index});
            try scenario.runtime.events.enqueue(try fixture.pumpEnvelope(route, run.id, encoded));
            try control.drainAgentEvents();
        }
        try std.testing.expectEqual(.consumer_rejected, run.event_projection_failure.?);
        try std.testing.expect(!run.event_pipeline_failed);
        try std.testing.expect(run.first_event_rejection == null);
        try std.testing.expect(task_state.productTerminalFacts(run) == null);
        switch (failure) {
            .none => {},
            .protocol => {
                try scenario.runtime.events.enqueue(try fixture.pumpEnvelope(route, run.id, "{\"output_segment_end\":{\"index\":999,\"turn\":999,\"group\":999,\"disposition\":\"final\",\"bytes\":1}}"));
                try std.testing.expectError(error.InvalidOutputSegment, control.drainAgentEvents());
                try std.testing.expectEqual(error.InvalidOutputSegment, run.first_event_rejection.?.failure);
            },
            .receipt => {
                var envelope = try fixture.pumpEnvelope(route, run.id, "{\"tool_progress\":{\"id\":\"retained-0\",\"text\":\"not a delivery\"}}");
                envelope.delivered_file = std.mem.zeroes(lifecycle.FileDeliveryReceipt);
                try scenario.runtime.events.enqueue(envelope);
                try std.testing.expectError(error.InvalidDeliveryReceipt, control.drainAgentEvents());
                try std.testing.expectEqual(error.InvalidDeliveryReceipt, run.first_event_rejection.?.failure);
            },
            .allocation => {
                try scenario.runtime.events.enqueue(try fixture.pumpEnvelope(route, run.id, "{\"tool_progress\":{\"id\":\"retained-0\",\"text\":\"new progress text\"}}"));
                var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
                const allocator = control.allocator;
                control.allocator = failing.allocator();
                defer control.allocator = allocator;
                try std.testing.expectError(error.OutOfMemory, control.drainAgentEvents());
                try std.testing.expectEqual(error.OutOfMemory, run.first_event_rejection.?.failure);
            },
        }
        fake_core.releaseControlled();
        try settleInputScenario(scenario);
        const terminal = task_state.productTerminalFacts(run).?;
        switch (failure) {
            .none => try std.testing.expectEqual(.completed, terminal.outcome),
            .protocol => {
                try std.testing.expectEqual(.dependency_contract_failure, terminal.outcome);
                try std.testing.expectEqual(.dependency_contract_failure, run.event_projection_failure.?);
                try std.testing.expect(!task_state.recordEventProjectionFailure(run));
            },
            .receipt, .allocation => {
                try std.testing.expect(run.event_pipeline_failed);
                try std.testing.expectEqual(.failed, terminal.outcome);
                try std.testing.expectEqual(.event_pipeline_failure, terminal.cause.?);
            },
        }
    }
}

test "history capacity executes more than sixteen Runs through worker retirement" {
    const scenario = try ReviewScenario.initForInput(.controlled);
    defer scenario.deinit();
    defer fake_core.releaseControlled();
    fake_core.releaseControlled();
    try settleInputScenario(scenario);
    const task = scenario.control.task_runtime.find(scenario.task_id).?;
    for (0..20) |_| {
        fake_core.rearmControlled();
        fake_core.setNextPlan(.controlled);
        _ = try runPreparedTask(&scenario.control, scenario.task_id, .{ .text = "continue the same history" });
        try waitControlSnapshot(&scenario.control, "\"inputReady\":true");
        fake_core.releaseControlled();
        try settleInputScenario(scenario);
        try std.testing.expectEqual(task, scenario.control.task_runtime.find(scenario.task_id).?);
    }
    var count: usize = 0;
    for (task.durable.runs) |entry| if (entry) |run| {
        count += 1;
        try std.testing.expect(run.execution == null);
        try std.testing.expect(run.terminal_publication.load(.acquire) == .published);
    };
    try std.testing.expectEqual(@as(usize, 21), count);
}

test "history capacity creates one hundred Tasks with one live Session" {
    for ([_]bool{ false, true }) |automatic| {
        fake_core.reset();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        defer std.testing.allocator.free(home);
        var checkpoints = try product_task.checkpoint_store.FileStore.init(std.testing.io, home);
        defer checkpoints.deinit();
        var automatic_root = try product_control.AutomaticWorkspaceRoot.open(std.testing.io, std.testing.allocator, home);
        defer automatic_root.deinit();
        var history: TaskPersistenceProbe = .{};
        var configuration = productControlConfiguration();
        configuration.directories.canonical_user_home = home;
        configuration.directories.testing_automatic_workspace_root = if (automatic) &automatic_root else null;
        configuration.task_persistence = history.capability();
        configuration.checkpoint_store = .{ .file_store = &checkpoints };
        const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
        defer {
            shutdownTestComposition(runtime) catch unreachable;
            deinitTestComposition(runtime);
        }
        var control = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, .{ .worker_count = 1, .queue_capacity = 1, .max_tasks = 1, .max_workspaces = 1, .max_runs_per_task = 1 }, configuration);
        defer control.deinit();
        try installControlExecution(&control);
        var input = productControlTaskInput();
        input.workspace_root = home;
        input.trust = .explicitly_trusted;
        input.approval_mode = .manual;
        for (0..100) |_| {
            for (0..5000) |_| {
                const created = if (automatic)
                    control.createTaskForWorkspace(.automatic, try product_control.TestSupport.fixtureModelSelection(&control), null, null, .{ .interactive = .manual })
                else
                    control.createTask(input, try product_control.TestSupport.fixtureModelSelection(&control));
                if (created) |id| {
                    try waitInitialTaskCatalog(&control, id);
                    break;
                } else |err| switch (err) {
                    error.SessionReleasing => {
                        control.syncLifecycle();
                        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
                    },
                    else => return err,
                }
            } else return error.TestUnexpectedResult;
        }
        try std.testing.expectEqual(@as(usize, 100), control.task_runtime.taskCount());
        var attached: usize = 0;
        for (control.task_runtime.tasks) |entry| if (entry) |task| {
            if (task.runtime.hasAttachedSession()) attached += 1;
        };
        try std.testing.expectEqual(@as(usize, 1), attached);
    }
}

fn scheduledBinding(
    workbench: *product_control.Runtime,
) product_control.ScheduledTaskBindingInput {
    return product_control.TestSupport.scheduledBinding(workbench);
}

const ShutdownContext = struct {
    workbench: *product_control.Runtime,

    fn run(self: *@This()) void {
        self.workbench.shutdownExecutor();
    }
};

const ReviewScenario = struct {
    runtime: *lifecycle.Runtime,
    control: product_control.Runtime,
    task_id: u64,

    fn init() !*@This() {
        return initWithConfiguration(productControlConfiguration());
    }

    fn initWithConfiguration(configuration: product_control.Configuration) !*@This() {
        return initWithRunCapacity(configuration, 2);
    }

    fn initWithRunCapacity(configuration: product_control.Configuration, max_runs: usize) !*@This() {
        return initConfigured(configuration, max_runs, .ui_wait, false);
    }

    fn initForInput(plan: fixture.Plan) !*@This() {
        return initConfigured(productControlConfiguration(), 2, plan, true);
    }

    fn initConfigured(configuration: product_control.Configuration, max_runs: usize, plan: fixture.Plan, input_enabled: bool) !*@This() {
        fake_core.reset();
        fake_core.input_enabled = input_enabled;
        fake_core.setNextPlan(plan);
        const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
        errdefer {
            shutdownTestComposition(runtime) catch unreachable;
            deinitTestComposition(runtime);
        }
        const self = try std.testing.allocator.create(@This());
        errdefer std.testing.allocator.destroy(self);
        self.* = .{
            .runtime = runtime,
            .control = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, .{ .worker_count = 1, .queue_capacity = 1, .max_tasks = 1, .max_runs_per_task = max_runs, .max_tools_per_run = 1 }, configuration),
            .task_id = 0,
        };
        errdefer self.control.deinit();
        try installControlExecution(&self.control);
        var input = productControlTaskInput();
        input.approval_mode = .manual;
        self.task_id = try self.control.createTask(input, try product_control.TestSupport.fixtureModelSelection(&self.control));
        // Task catalog readiness does not prove Workspace discovery has
        // vacated the one-slot executor queue. Finish both setup operations
        // before this fixture starts the Run whose approval it exercises.
        try waitInitialTaskCatalog(&self.control, self.task_id);
        try settleWorkspaceSkillQueries(&self.control, try self.control.taskWorkspaceId(self.task_id));
        _ = try runPreparedTask(&self.control, self.task_id, .{ .text = "Perform the bounded operation without disclosing fixture-secret" });
        try waitControlSnapshot(&self.control, if (plan == .ui_wait) "\"currentRunPhase\":\"waiting_ui\"" else "\"inputReady\":true");
        return self;
    }

    fn text(self: *@This()) product_task.TextProjection {
        return product_control.TestSupport.taskPermissionReviewText(&self.control);
    }

    fn prepare(self: *@This()) !product_task.PreparedPermissionReview {
        _ = try self.control.task_runtime.testSetPermissionReviewDelegation(self.task_id, true);
        return (try self.control.task_runtime.preparePermissionReview(self.task_id, self.text())).?;
    }

    fn deinit(self: *@This()) void {
        self.control.deinit();
        shutdownTestComposition(self.runtime) catch unreachable;
        deinitTestComposition(self.runtime);
        std.testing.allocator.destroy(self);
    }
};

test "approval modes start with automatic review and restore the global choice with original session facts" {
    fake_core.reset();
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 4 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const history = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(history);
    var persistence = TaskPersistenceProbe{ .storage = history };
    var configuration = productControlConfiguration();
    configuration.task_persistence = persistence.capability();
    const limits: product_control.Limits = .{ .worker_count = 1, .queue_capacity = 1, .max_tasks = 3, .max_workspaces = 1 };
    var control = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, limits, configuration);
    defer control.deinit();
    try installControlExecution(&control);
    try std.testing.expectEqual(.auto_review, control.defaultApprovalMode());
    var snapshot_buffer: [128 * 1024]u8 = undefined;
    const snapshot = try control.writeAggregateFixture(&snapshot_buffer);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, snapshot, .{});
    defer parsed.deinit();
    const permissions = parsed.value.object.get("permissions").?.object;
    try std.testing.expectEqualStrings("auto_review", permissions.get("defaultMode").?.string);
    try std.testing.expectEqualStrings("approval_required", permissions.get("defaultProfile").?.string);
    var input = productControlTaskInput();
    const reviewed = try control.createTask(input, try product_control.TestSupport.fixtureModelSelection(&control));
    try std.testing.expectEqual(.auto_review, try control.taskApprovalMode(reviewed));
    try std.testing.expectEqual(.approval_required, try control.taskPermissionProfile(reviewed));
    const inherited = try control.createTask(productControlTaskInput(), try product_control.TestSupport.fixtureModelSelection(&control));
    try std.testing.expectEqual(.auto_review, try control.taskApprovalMode(inherited));
    input.approval_mode = .full_access;
    const full = try control.createTask(input, try product_control.TestSupport.fixtureModelSelection(&control));
    try std.testing.expectEqual(.full_access, control.defaultApprovalMode());
    try std.testing.expectEqual(.auto_review, try control.taskApprovalMode(reviewed));
    var restart = productControlConfiguration();
    restart.task_persistence = persistence.capabilityRestored(history[0..persistence.len]);
    var restored = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, limits, restart);
    defer restored.deinit();
    try std.testing.expectEqual(.full_access, restored.defaultApprovalMode());
    try std.testing.expectEqual(.auto_review, try restored.taskApprovalMode(reviewed));
    try std.testing.expectEqual(.auto_review, try restored.taskApprovalMode(inherited));
    try std.testing.expectEqual(.full_access, try restored.taskApprovalMode(full));
}

test "approval modes restore each saved choice instead of applying the fresh-install default" {
    for ([_]product_control.ApprovalMode{ .manual, .auto_review, .full_access }) |mode| {
        fake_core.reset();
        const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
        defer {
            shutdownTestComposition(runtime) catch unreachable;
            deinitTestComposition(runtime);
        }
        const history = try std.testing.allocator.alloc(u8, 1024 * 1024);
        defer std.testing.allocator.free(history);
        var persistence = TaskPersistenceProbe{ .storage = history };
        var configuration = productControlConfiguration();
        configuration.task_persistence = persistence.capability();
        const limits: product_control.Limits = .{ .worker_count = 1, .queue_capacity = 1, .max_tasks = 1, .max_workspaces = 1 };
        var control = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, limits, configuration);
        defer control.deinit();
        try installControlExecution(&control);
        var input = productControlTaskInput();
        input.approval_mode = mode;
        const task_id = try control.createTask(input, try product_control.TestSupport.fixtureModelSelection(&control));
        try std.testing.expectEqual(mode, control.defaultApprovalMode());
        var restart = productControlConfiguration();
        restart.task_persistence = persistence.capabilityRestored(history[0..persistence.len]);
        var restored = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, limits, restart);
        defer restored.deinit();
        try std.testing.expectEqual(mode, restored.defaultApprovalMode());
        try std.testing.expectEqual(mode, try restored.taskApprovalMode(task_id));
        try std.testing.expectEqual(mode.profile(), restored.defaultPermissionProfile());
    }
}

const ReviewCommit = struct {
    calls: usize = 0,
    outcome: product_task.DurableCommit = .committed,

    fn commit(context: *anyopaque) product_task.DurableCommit {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.calls += 1;
        return self.outcome;
    }

    fn effects(self: *@This(), scenario: *ReviewScenario) product_task.PermissionReviewEffects {
        return .{ .context = self, .commit_fn = commit, .text = scenario.text() };
    }
};

const ReviewerTransport = struct {
    released: std.atomic.Value(bool) = .init(false),
    entered: std.atomic.Value(bool) = .init(false),
    exited: std.atomic.Value(bool) = .init(false),
    calls: std.atomic.Value(usize) = .init(0),
    invalid: std.atomic.Value(bool) = .init(false),
    hold_cancel_cleanup: bool = false,
    result: []const u8 = "{\"decision\":\"allow_once\",\"reason\":\"Matches the user request\"}",

    fn create(context: ?*anyopaque, allocator: std.mem.Allocator, binding: lifecycle.ModelBinding) anyerror!*lifecycle.Completion {
        return lifecycle.Completion.init(allocator, .{ .context = context, .perform_fn = perform }, binding);
    }

    fn perform(context: ?*anyopaque, request: lifecycle.CompletionHttpRequest, cancellation: *const lifecycle.CompletionCancellation, buffer: []u8) lifecycle.CompletionTransportError!lifecycle.CompletionTransportResponse {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        const is_review = std.mem.indexOf(u8, request.body, "allow_once") != null;
        if (is_review) {
            _ = self.calls.fetchAdd(1, .acq_rel);
            if (std.mem.indexOf(u8, request.body, "fixture-secret") != null or
                std.mem.indexOf(u8, request.body, "unrelated-secret") != null or
                std.mem.indexOf(u8, request.body, "\\\"tools\\\"") != null)
                self.invalid.store(true, .release);
            self.entered.store(true, .release);
            defer self.exited.store(true, .release);
            while (!self.released.load(.acquire)) {
                if (cancellation.isRequested() and !self.hold_cancel_cleanup) return error.Cancelled;
                std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch return error.Cancelled;
            }
            if (cancellation.isRequested()) return error.Cancelled;
        }
        var writer = std.Io.Writer.fixed(buffer);
        std.json.Stringify.value(.{
            .type = "message",
            .content = .{.{ .type = "text", .text = if (is_review) self.result else "Task title" }},
            .stop_reason = "end_turn",
            .usage = .{ .input_tokens = 1, .output_tokens = 1 },
        }, .{}, &writer) catch return error.ResponseTooLarge;
        return .{ .status = 200, .body = writer.buffered() };
    }

    fn awaitEntered(self: *@This(), control: *product_control.Runtime) !void {
        for (0..1000) |_| {
            control.syncLifecycle();
            if (self.entered.load(.acquire)) return;
            std.Io.sleep(std.testing.io, .fromMilliseconds(2), .awake) catch return error.TestUnexpectedResult;
        }
        return error.TestUnexpectedResult;
    }
};

fn waitReviewerJobDone(control: *product_control.Runtime) !void {
    // Deliberately do not synchronize Control: the finished result is still
    // queued when the manual command enters the Host.
    for (0..1000) |_| {
        for (control.permission_jobs) |entry| if (entry) |job| {
            if (job.done.load(.acquire)) return;
        };
        std.Io.sleep(std.testing.io, .fromMilliseconds(2), .awake) catch return error.TestUnexpectedResult;
    }
    return error.TestUnexpectedResult;
}

test "Control permission reviewer keeps repeated manual and full-access requests idle" {
    for ([_]product_control.ApprovalMode{ .manual, .full_access }) |mode| {
        fake_core.reset();
        fake_core.setNextPlan(.ui_wait_repeated);
        const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
        defer {
            shutdownTestComposition(runtime) catch unreachable;
            deinitTestComposition(runtime);
        }
        var transport: ReviewerTransport = .{};
        var configuration = productControlConfiguration();
        configuration.completion_factory = .{ .context = &transport, .create_fn = ReviewerTransport.create };
        var control = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, .{ .worker_count = 1, .queue_capacity = 1, .max_tasks = 1, .max_runs_per_task = 1, .max_tools_per_run = 1 }, configuration);
        defer control.deinit();
        try installControlExecution(&control);
        var input = productControlTaskInput();
        input.approval_mode = mode;
        const task_id = try control.createTask(input, try product_control.TestSupport.fixtureModelSelection(&control));
        const run_id = try runPreparedTask(&control, task_id, .{ .text = "Inspect two local operations" });
        try waitControlSnapshot(&control, "\"pendingUi\":{\"requestId\":\"1\"");
        try control.respondUi(task_id, run_id, 1, .{ .permission = .allow_once });
        try waitControlSnapshot(&control, "\"pendingUi\":{\"requestId\":\"2\"");
        var snapshot: [64 * 1024]u8 = undefined;
        const json = try control.writeAggregateFixture(&snapshot);
        try std.testing.expect(std.mem.indexOf(u8, json, "\"permissionReviewState\":\"idle\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, json, "\"permissionReviewState\":\"needs_user\"") == null);
        try std.testing.expectEqual(@as(usize, 0), transport.calls.load(.acquire));
        try control.respondUi(task_id, run_id, 2, .{ .permission = .deny_once });
        fake_core.releaseControlled();
        try waitControlSnapshot(&control, "\"terminal\":{\"outcome\":\"completed\"");
        const task = control.task_runtime.find(task_id).?;
        try std.testing.expectEqual(@as(usize, 2), task.durable.ui_history_count);
        try std.testing.expectEqual(.user, task.durable.ui_history[0].?.answered_by.?);
        try std.testing.expectEqual(.user, task.durable.ui_history[1].?.answered_by.?);
    }
}

test "Control permission reviewer cannot preempt a valid manual command with a queued result" {
    for ([_]bool{ false, true }) |automatic_first| {
        fake_core.reset();
        fake_core.setNextPlan(.ui_wait);
        const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
        defer {
            shutdownTestComposition(runtime) catch unreachable;
            deinitTestComposition(runtime);
        }
        var transport: ReviewerTransport = .{};
        var persistence: TaskPersistenceProbe = .{};
        var configuration = productControlConfiguration();
        configuration.task_persistence = persistence.capability();
        configuration.completion_factory = .{ .context = &transport, .create_fn = ReviewerTransport.create };
        var control = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, .{ .worker_count = 1, .queue_capacity = 1, .max_tasks = 1, .max_runs_per_task = 1, .max_tools_per_run = 1 }, configuration);
        defer control.deinit();
        defer transport.released.store(true, .release);
        try installControlExecution(&control);
        var input = productControlTaskInput();
        input.approval_mode = .auto_review;
        const task_id = try control.createTask(input, try product_control.TestSupport.fixtureModelSelection(&control));
        const run_id = try runPreparedTask(&control, task_id, .{ .text = "Perform the bounded operation" });
        try transport.awaitEntered(&control);
        const request_id = control.task_runtime.find(task_id).?.runtime.pending_ui_request_id;
        transport.released.store(true, .release);
        try waitReviewerJobDone(&control);
        if (automatic_first) {
            control.syncLifecycle();
            if (control.respondUi(task_id, run_id, request_id, .{ .permission = .deny_once })) |_| {
                return error.TestUnexpectedResult;
            } else |err| {
                try std.testing.expect(err == error.NoPendingUiRequest or err == error.StaleUiResponse);
            }
        } else {
            try control.respondUi(task_id, run_id, request_id, .{ .permission = .deny_once });
            control.syncLifecycle();
        }
        const task = control.task_runtime.find(task_id).?;
        try std.testing.expectEqual(@as(usize, 1), task.durable.ui_history_count);
        try std.testing.expectEqual(if (automatic_first) @as(@TypeOf(task.durable.ui_history[0].?.answered_by.?), .reviewer) else .user, task.durable.ui_history[0].?.answered_by.?);
        try std.testing.expectEqual(if (automatic_first) @as(@TypeOf(task.durable.ui_history[0].?.state), .allowed_once) else .denied, task.durable.ui_history[0].?.state);
        try std.testing.expectEqual(@as(usize, 1), transport.calls.load(.acquire));
    }
}

test "Control permission reviewer survives stale identities and unavailable manual choices" {
    fake_core.reset();
    fake_core.permission_session_choices = false;
    fake_core.setNextPlan(.ui_wait);
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var transport: ReviewerTransport = .{};
    var persistence: TaskPersistenceProbe = .{};
    var configuration = productControlConfiguration();
    configuration.task_persistence = persistence.capability();
    configuration.completion_factory = .{ .context = &transport, .create_fn = ReviewerTransport.create };
    var control = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, .{ .worker_count = 1, .queue_capacity = 1, .max_tasks = 1, .max_runs_per_task = 1, .max_tools_per_run = 1 }, configuration);
    defer control.deinit();
    defer transport.released.store(true, .release);
    try installControlExecution(&control);
    var input = productControlTaskInput();
    input.approval_mode = .auto_review;
    const task_id = try control.createTask(input, try product_control.TestSupport.fixtureModelSelection(&control));
    const run_id = try runPreparedTask(&control, task_id, .{ .text = "Perform the bounded operation" });
    try transport.awaitEntered(&control);
    const task = control.task_runtime.find(task_id).?;
    const identity = task.runtime.permission_review.identity.?;
    try std.testing.expectError(error.UnknownTask, control.respondUi(task_id + 1, run_id, identity.request_id, .{ .permission = .deny_once }));
    try std.testing.expectError(error.NoSuchRun, control.respondUi(task_id, run_id + 1, identity.request_id, .{ .permission = .deny_once }));
    try std.testing.expectError(error.StaleUiResponse, control.respondUi(task_id, run_id, identity.request_id + 1, .{ .permission = .deny_once }));
    try std.testing.expectError(error.InvalidUiResponse, control.respondUi(task_id, run_id, identity.request_id, .{ .permission = .allow_session }));
    try std.testing.expect(task.runtime.permission_review.matches(identity));
    try std.testing.expectEqual(@as(usize, 0), task.durable.ui_history_count);
    transport.released.store(true, .release);
    try waitReviewerJobDone(&control);
    try std.testing.expectError(error.StaleUiResponse, control.respondUi(task_id, run_id, identity.request_id + 1, .{ .permission = .deny_once }));
    try std.testing.expect(task.runtime.permission_review.matches(identity));
    control.syncLifecycle();
    try std.testing.expectEqual(@as(usize, 1), task.durable.ui_history_count);
    try std.testing.expectEqual(.reviewer, task.durable.ui_history[0].?.answered_by.?);
}

test "Control permission reviewer preserves cancelled timeout facts without accepting cancelled votes" {
    for ([_]bool{ false, true }) |timeout| {
        var transport: ReviewerTransport = .{};
        var configuration = productControlConfiguration();
        configuration.completion_factory = .{ .context = &transport, .create_fn = ReviewerTransport.create };
        const scenario = try ReviewScenario.initWithConfiguration(configuration);
        defer scenario.deinit();
        _ = try scenario.control.task_runtime.testSetPermissionReviewDelegation(scenario.task_id, true);
        try transport.awaitEntered(&scenario.control);
        transport.released.store(true, .release);
        try waitReviewerJobDone(&scenario.control);
        for (scenario.control.permission_jobs) |entry| if (entry) |job| {
            job.cancellation.request();
            if (timeout) job.outcome = .{ .failure = .timeout };
        };
        scenario.control.syncLifecycle();
        const task = scenario.control.task_runtime.find(scenario.task_id).?;
        try std.testing.expectEqual(@as(usize, 0), task.durable.ui_history_count);
        const cause = task.runtime.permission_review.cause;
        try std.testing.expectEqual(@as(@TypeOf(cause), if (timeout) .timeout else .state_changed), cause);
        var buffer: [64 * 1024]u8 = undefined;
        const snapshot = try scenario.control.writeAggregateFixture(&buffer);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, if (timeout) "\"cause\":\"timeout\"" else "\"cause\":\"state_changed\"") != null);
    }
}

test "Control permission reviewer commits once-only decisions and projects audit" {
    for ([_][]const u8{
        "{\"decision\":\"allow_once\",\"reason\":\"Matches the user request\"}",
        "{\"decision\":\"deny\",\"reason\":\"Outside the user request\"}",
        "{\"decision\":\"needs_user\",\"reason\":\"Insufficient evidence\"}",
        "{\"decision\":0,\"reason\":\"invalid\"}",
    }, 0..) |result, index| {
        fake_core.reset();
        fake_core.setNextPlan(.ui_wait);
        const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
        defer {
            shutdownTestComposition(runtime) catch unreachable;
            deinitTestComposition(runtime);
        }
        var transport: ReviewerTransport = .{ .result = result };
        var persistence: TaskPersistenceProbe = .{};
        var configuration = productControlConfiguration();
        configuration.task_persistence = persistence.capability();
        configuration.completion_factory = .{ .context = &transport, .create_fn = ReviewerTransport.create };
        var control = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, .{ .worker_count = 1, .queue_capacity = 1, .max_tasks = 1, .max_runs_per_task = 2, .max_tools_per_run = 1 }, configuration);
        defer control.deinit();
        try installControlExecution(&control);
        var input = productControlTaskInput();
        input.approval_mode = .auto_review;
        const task_id = try control.createTask(input, try product_control.TestSupport.fixtureModelSelection(&control));
        _ = try runPreparedTask(&control, task_id, .{ .text = "Perform the bounded operation without disclosing fixture-secret" });
        try transport.awaitEntered(&control);
        try waitControlSnapshot(&control, "\"permissionReviewState\":\"reviewing\"");
        const reviewing_signals = control.task_runtime.workspaceSignals(control.task_runtime.find(task_id).?.durable.workspace_id);
        try std.testing.expectEqual(@as(u32, 1), reviewing_signals.running);
        try std.testing.expectEqual(@as(u32, 0), reviewing_signals.attention);
        const before = persistence.commits;
        transport.released.store(true, .release);
        if (index < 2) {
            try waitControlSnapshot(&control, "\"answeredBy\":\"reviewer\"");
            const task = control.task_runtime.find(task_id).?;
            try std.testing.expectEqual(@as(usize, 1), task.durable.ui_history_count);
            try std.testing.expectEqualStrings(if (index == 0) "allowed_once" else "denied", @tagName(task.durable.ui_history[0].?.state));
            try std.testing.expect(persistence.commits > before);
        } else {
            try waitControlSnapshot(&control, "\"permissionReviewState\":\"needs_user\"");
            const manual_signals = control.task_runtime.workspaceSignals(control.task_runtime.find(task_id).?.durable.workspace_id);
            const cause = control.task_runtime.find(task_id).?.runtime.permission_review.cause;
            try std.testing.expectEqual(@as(@TypeOf(cause), if (index == 2) .reviewer_concern else .invalid_response), cause);
            try std.testing.expectEqual(@as(u32, 0), manual_signals.running);
            try std.testing.expectEqual(@as(u32, 1), manual_signals.attention);
            try std.testing.expectEqual(@as(usize, 0), control.task_runtime.find(task_id).?.durable.ui_history_count);
            for (0..5) |_| control.syncLifecycle();
        }
        try std.testing.expectEqual(@as(usize, 1), transport.calls.load(.acquire));
        try std.testing.expect(!transport.invalid.load(.acquire));
    }
}

test "Control permission reviewer scrubs decoded arguments and leaves MCP and Host requests manual" {
    for (0..3) |case| {
        fake_core.reset();
        fake_core.permission_arguments_json = "{\"api_key\":\"fixture\\u002dsecret\",\"nested\":[\"fixture-secret\"]}";
        fake_core.permission_tool_namespace = switch (case) {
            0 => "builtin",
            1 => "mcp",
            else => "host",
        };
        if (case == 2) {
            fake_core.permission_tool_name = "GenerateImage";
            fake_core.permission_session_choices = false;
        }
        fake_core.setNextPlan(.ui_wait);
        const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
        defer {
            shutdownTestComposition(runtime) catch unreachable;
            deinitTestComposition(runtime);
        }
        var transport: ReviewerTransport = .{};
        var persistence: TaskPersistenceProbe = .{};
        var configuration = productControlConfiguration();
        configuration.task_persistence = persistence.capability();
        configuration.completion_factory = .{ .context = &transport, .create_fn = ReviewerTransport.create };
        var control = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, .{ .worker_count = 1, .queue_capacity = 1, .max_tasks = 1, .max_runs_per_task = 1, .max_tools_per_run = 1 }, configuration);
        defer control.deinit();
        try installControlExecution(&control);
        var input = productControlTaskInput();
        input.approval_mode = .auto_review;
        const task_id = try control.createTask(input, try product_control.TestSupport.fixtureModelSelection(&control));
        _ = try runPreparedTask(&control, task_id, .{ .text = "Inspect the local operation" });
        if (case == 0) {
            try transport.awaitEntered(&control);
            try std.testing.expect(!transport.invalid.load(.acquire));
            transport.released.store(true, .release);
            try waitControlSnapshot(&control, "\"answeredBy\":\"reviewer\"");
        } else {
            try waitControlSnapshot(&control, "\"permissionReviewState\":\"needs_user\"");
            try std.testing.expectEqual(.unsupported_tool, control.task_runtime.find(task_id).?.runtime.permission_review.cause);
            try std.testing.expectEqual(@as(usize, 0), transport.calls.load(.acquire));
            try std.testing.expectEqual(@as(usize, 0), control.task_runtime.find(task_id).?.durable.ui_history_count);
        }
    }
}

test "Control permission reviewer cancellation survives manual response delete and shutdown" {
    for (0..3) |case| {
        fake_core.reset();
        fake_core.setNextPlan(.ui_wait);
        const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
        defer {
            shutdownTestComposition(runtime) catch unreachable;
            deinitTestComposition(runtime);
        }
        var transport: ReviewerTransport = .{};
        transport.hold_cancel_cleanup = case == 1;
        var configuration = productControlConfiguration();
        configuration.completion_factory = .{ .context = &transport, .create_fn = ReviewerTransport.create };
        var control = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, .{ .worker_count = 1, .queue_capacity = 1, .max_tasks = 1, .max_runs_per_task = 1, .max_tools_per_run = 1 }, configuration);
        defer control.deinit();
        defer transport.released.store(true, .release);
        try installControlExecution(&control);
        var input = productControlTaskInput();
        input.approval_mode = .auto_review;
        const task_id = try control.createTask(input, try product_control.TestSupport.fixtureModelSelection(&control));
        _ = try runPreparedTask(&control, task_id, .{ .text = "Perform the bounded operation" });
        try transport.awaitEntered(&control);
        switch (case) {
            0 => {
                const task = control.task_runtime.find(task_id).?;
                try control.respondUi(task_id, task.runtime.active_run_id, task.runtime.pending_ui_request_id, .{ .permission = .deny_once });
                control.syncLifecycle();
            },
            1 => {
                try control.cancel(task_id, control.task_runtime.find(task_id).?.runtime.active_run_id);
                try waitSetTaskArchived(&control, task_id);
                try control.deleteTask(task_id);
                try waitTaskDeleted(&control, task_id);
                try std.testing.expect(!transport.exited.load(.acquire));
                transport.released.store(true, .release);
            },
            2 => control.shutdownExecutor(),
            else => unreachable,
        }
        for (0..1000) |_| {
            control.syncLifecycle();
            if (transport.exited.load(.acquire)) break;
            std.Io.sleep(std.testing.io, .fromMilliseconds(2), .awake) catch break;
        }
        try std.testing.expect(transport.exited.load(.acquire));
        try std.testing.expectEqual(@as(usize, 1), transport.calls.load(.acquire));
    }
}

test "Control permission reviewer requires confirmed persistence and never retries the request" {
    for ([_]product_task.history.Commit{ .failed, .outcome_unknown }) |failure| {
        fake_core.reset();
        fake_core.setNextPlan(.ui_wait);
        const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
        defer {
            shutdownTestComposition(runtime) catch unreachable;
            deinitTestComposition(runtime);
        }
        var transport: ReviewerTransport = .{};
        var persistence: TaskPersistenceProbe = .{};
        var configuration = productControlConfiguration();
        configuration.task_persistence = persistence.capability();
        configuration.completion_factory = .{ .context = &transport, .create_fn = ReviewerTransport.create };
        var control = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, .{ .worker_count = 1, .queue_capacity = 1, .max_tasks = 1, .max_runs_per_task = 1, .max_tools_per_run = 1 }, configuration);
        defer control.deinit();
        try installControlExecution(&control);
        var input = productControlTaskInput();
        input.approval_mode = .auto_review;
        const task_id = try control.createTask(input, try product_control.TestSupport.fixtureModelSelection(&control));
        _ = try runPreparedTask(&control, task_id, .{ .text = "Perform the bounded operation" });
        try transport.awaitEntered(&control);
        persistence.result = failure;
        transport.released.store(true, .release);
        try waitControlSnapshot(&control, "\"permissionReviewState\":\"needs_user\"");
        const task = control.task_runtime.find(task_id).?;
        try std.testing.expectEqual(@as(usize, 0), task.durable.ui_history_count);
        for (0..10) |_| control.syncLifecycle();
        try std.testing.expectEqual(@as(usize, 1), transport.calls.load(.acquire));
        try control.respondUi(task_id, task.runtime.active_run_id, task.runtime.pending_ui_request_id, .{ .permission = .deny_once });
        try std.testing.expectEqual(.user, task.durable.ui_history[0].?.answered_by.?);
    }
}

test "Control permission reviewer capacity includes cancelled workers until they are reaped" {
    fake_core.reset();
    const runtime = try createTestComposition(.{ .worker_count = 9, .queue_capacity = 9, .max_sessions = 9 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var transport: ReviewerTransport = .{ .hold_cancel_cleanup = true };
    var configuration = productControlConfiguration();
    configuration.completion_factory = .{ .context = &transport, .create_fn = ReviewerTransport.create };
    var control = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, .{ .worker_count = 9, .queue_capacity = 9, .max_tasks = 9, .max_runs_per_task = 2, .max_tools_per_run = 1 }, configuration);
    defer control.deinit();
    defer transport.released.store(true, .release);
    try installControlExecution(&control);
    var ids: [9]u64 = undefined;
    for (&ids, 0..) |*id, index| {
        fake_core.setNextPlan(.ui_wait);
        var input = productControlTaskInput();
        input.approval_mode = .auto_review;
        id.* = try control.createTask(input, try product_control.TestSupport.fixtureModelSelection(&control));
        _ = try runPreparedTask(&control, id.*, .{ .text = "Perform the bounded operation" });
        for (0..1000) |_| {
            control.syncLifecycle();
            const task = control.task_runtime.find(id.*).?;
            if (if (index < 8) task.runtime.permission_review.phase == .reviewing else task.runtime.permission_review.phase == .needs_user) break;
            std.Io.sleep(std.testing.io, .fromMilliseconds(2), .awake) catch return error.TestUnexpectedResult;
        }
    }
    const first = control.task_runtime.find(ids[0]).?;
    try control.cancel(ids[0], first.runtime.active_run_id);
    try waitSetTaskArchived(&control, ids[0]);
    try control.setTaskArchived(ids[0], false);
    fake_core.setNextPlan(.ui_wait);
    _ = try runPreparedTask(&control, ids[0], .{ .text = "A new bounded operation" });
    for (0..1000) |_| {
        control.syncLifecycle();
        if (first.runtime.permission_review.phase == .needs_user) break;
        std.Io.sleep(std.testing.io, .fromMilliseconds(2), .awake) catch return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(.needs_user, first.runtime.permission_review.phase);
    try std.testing.expectEqual(.needs_user, control.task_runtime.find(ids[8]).?.runtime.permission_review.phase);
    try std.testing.expectEqual(.capacity, control.task_runtime.find(ids[8]).?.runtime.permission_review.cause);
    try std.testing.expect(transport.calls.load(.acquire) <= 8);
    try std.testing.expect(!transport.exited.load(.acquire));
}

fn reviewSuggestion(decision: enum { allow_once, needs_user, deny }, reason: []const u8) product_task.PermissionReviewOutcome {
    var outcome: product_task.PermissionReviewOutcome = .{ .suggestion = .{
        .decision = switch (decision) {
            .allow_once => .allow_once,
            .needs_user => .needs_user,
            .deny => .deny,
        },
        .reason = .{ .len = reason.len },
        .usage = .{},
    } };
    @memcpy(outcome.suggestion.reason.bytes[0..reason.len], reason);
    return outcome;
}

fn reviewPreparationAllocationFailure(allocator: std.mem.Allocator, scenario: *ReviewScenario) !void {
    const runtime = &scenario.control.task_runtime;
    _ = try runtime.testSetPermissionReviewDelegation(scenario.task_id, false);
    _ = try runtime.testSetPermissionReviewDelegation(scenario.task_id, true);
    const previous = runtime.allocator;
    runtime.allocator = allocator;
    defer runtime.allocator = previous;
    var preparation = (runtime.preparePermissionReview(scenario.task_id, scenario.text()) catch |err| {
        const task = runtime.find(scenario.task_id).?;
        try std.testing.expectEqual(.needs_user, task.runtime.permission_review.phase);
        try std.testing.expect((try runtime.preparePermissionReview(scenario.task_id, scenario.text())) == null);
        try std.testing.expectEqual(@as(usize, 0), task.durable.ui_history_count);
        return err;
    }).?;
    defer preparation.deinit();
    try std.testing.expect(runtime.finishPermissionReview(preparation.identity, .{}));
}

fn manualResponseAllocationFailure(allocator: std.mem.Allocator, scenario: *ReviewScenario) !void {
    const runtime = &scenario.control.task_runtime;
    _ = try runtime.testSetPermissionReviewDelegation(scenario.task_id, false);
    var review = try scenario.prepare();
    defer review.deinit();
    const task = runtime.find(scenario.task_id).?;
    const previous_allocator = runtime.allocator;
    runtime.allocator = allocator;
    defer runtime.allocator = previous_allocator;
    var response = runtime.respondUi(scenario.task_id, review.identity.run_id, review.identity.request_id, .{ .permission = .deny_once }) catch |err| {
        try std.testing.expect(task.runtime.permission_review.matches(review.identity));
        try std.testing.expectEqual(@as(usize, 0), task.durable.ui_history_count);
        return err;
    };
    // Do not deliver in the allocation harness; every iteration uses the same
    // still-pending request with a newly prepared review identity.
    response.rollback();
}

test "Task permission review survives every allocation failure before manual acceptance" {
    const scenario = try ReviewScenario.init();
    defer scenario.deinit();
    try std.testing.checkAllAllocationFailures(std.testing.allocator, manualResponseAllocationFailure, .{scenario});
}

test "Task permission review preparation cleans up every allocation failure without expiring the request" {
    const scenario = try ReviewScenario.init();
    defer scenario.deinit();
    const task = scenario.control.task_runtime.find(scenario.task_id).?;
    const request_id = task.runtime.pending_ui_request_id;
    const leases = task.runtime.worker_leases.liveCount();
    const projected_bytes = scenario.control.projection_bytes;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, reviewPreparationAllocationFailure, .{scenario});
    try std.testing.expectEqual(leases, task.runtime.worker_leases.liveCount());
    try std.testing.expectEqual(projected_bytes, scenario.control.projection_bytes);
    try std.testing.expectEqual(request_id, task.runtime.pending_ui_request_id);
    try scenario.control.respondUi(scenario.task_id, task.runtime.active_run_id, request_id, .{ .permission = .deny_once });
}

test "Task permission review prepares detached owned data using the Run model and no worker lease" {
    const scenario = try ReviewScenario.init();
    defer scenario.deinit();
    const task = scenario.control.task_runtime.find(scenario.task_id).?;
    const lease_count = task.runtime.worker_leases.liveCount();
    const projection_bytes = scenario.control.projection_bytes;
    var preparation = try scenario.prepare();
    defer preparation.deinit();
    try std.testing.expectEqual(lease_count, task.runtime.worker_leases.liveCount());
    try std.testing.expectEqual(projection_bytes, scenario.control.projection_bytes);
    try std.testing.expect(std.mem.indexOf(u8, preparation.input.user_intent, "fixture-secret") == null);
    try std.testing.expectEqualStrings(task.durable.runs[0].?.execution_model, preparation.execution.model);
    try std.testing.expectEqualStrings("fixture-secret", preparation.execution.secret);
    try std.testing.expectEqual(task.durable.id, preparation.identity.task_id);
    try std.testing.expect(try scenario.control.task_runtime.testSetPermissionReviewDelegation(scenario.task_id, false));
    try std.testing.expect(std.mem.indexOf(u8, preparation.input.user_intent, "bounded operation") != null);
    var commit = ReviewCommit{};
    try std.testing.expect(!try scenario.control.task_runtime.acceptPermissionReview(preparation.identity, reviewSuggestion(.allow_once, "ok"), commit.effects(scenario)));
    try std.testing.expectEqual(@as(usize, 0), commit.calls);
}

test "Task permission review carries earlier user authorization into a continuation without Tool output" {
    const scenario = try ReviewScenario.init();
    defer scenario.deinit();
    const task = scenario.control.task_runtime.find(scenario.task_id).?;
    const previous_id = task.runtime.active_run_id;
    try scenario.control.respondUi(scenario.task_id, previous_id, task.runtime.pending_ui_request_id, .{ .permission = .allow_once });
    fake_core.releaseControlled();
    try waitControlSnapshot(&scenario.control, "\"terminal\":{\"outcome\":\"completed\"");
    fake_core.setNextPlan(.ui_wait);
    _ = try runPreparedTask(&scenario.control, scenario.task_id, .{ .text = "Start installing" });
    try waitControlSnapshot(&scenario.control, "\"currentRunPhase\":\"waiting_ui\"");
    var prepared = try scenario.prepare();
    defer prepared.deinit();
    try std.testing.expectEqualStrings("Start installing", prepared.input.user_intent);
    try std.testing.expect(std.mem.indexOf(u8, prepared.input.user_history_json, "bounded operation") != null);
    try std.testing.expect(std.mem.indexOf(u8, prepared.input.user_history_json, "fixture-secret") == null);
    try std.testing.expectEqual(@as(usize, 0), prepared.input.omitted_user_messages);
    try std.testing.expectEqual(@as(usize, 1), task.durable.ui_history_count);
}

test "Task permission review submits only once decisions and sanitizes reviewer attribution" {
    for ([_]bool{ false, true }) |denied| {
        const scenario = try ReviewScenario.init();
        defer scenario.deinit();
        var preparation = try scenario.prepare();
        defer preparation.deinit();
        var commit = ReviewCommit{};
        try std.testing.expect(try scenario.control.task_runtime.acceptPermissionReview(preparation.identity, reviewSuggestion(if (denied) .deny else .allow_once, "bounded fixture-secret operation"), commit.effects(scenario)));
        try std.testing.expectEqual(@as(usize, 1), commit.calls);
        const task = scenario.control.task_runtime.find(scenario.task_id).?;
        const record = &task.durable.ui_history[0].?;
        try std.testing.expectEqual(.reviewer, record.answered_by.?);
        try std.testing.expectEqual(@as(product_task.testing.state_module.UiRecordState, if (denied) .denied else .allowed_once), record.state);
        try std.testing.expectEqualStrings("bounded *** operation", record.reviewReason().?);
        try std.testing.expect(record.redacted);
        try std.testing.expect(!try scenario.control.task_runtime.acceptPermissionReview(preparation.identity, reviewSuggestion(.allow_once, "late"), commit.effects(scenario)));
        try std.testing.expectEqual(@as(usize, 1), commit.calls);
    }
}

test "Task permission review failures and needs-user retain the original manual wait without retry" {
    const Case = struct {
        outcome: product_task.PermissionReviewOutcome,
        cause: product_task.testing.attachment_module.PermissionReviewState.Cause,
    };
    for ([_]Case{
        .{ .outcome = .{ .failure = .timeout }, .cause = .timeout },
        .{ .outcome = .{ .failure = .{ .completion = .malformed_response } }, .cause = .invalid_response },
        .{ .outcome = .{ .failure = .{ .completion = .unsupported_response } }, .cause = .invalid_response },
        .{ .outcome = .{ .failure = .{ .completion = .{ .provider_rejected = .{ .status = 503, .category = .provider_failure } } } }, .cause = .call_failed },
        .{ .outcome = reviewSuggestion(.needs_user, "Evidence fixture-secret is missing."), .cause = .reviewer_concern },
    }) |case| {
        const outcome = case.outcome;
        const scenario = try ReviewScenario.init();
        defer scenario.deinit();
        var preparation = try scenario.prepare();
        defer preparation.deinit();
        var commit = ReviewCommit{};
        try std.testing.expect(!try scenario.control.task_runtime.acceptPermissionReview(preparation.identity, outcome, commit.effects(scenario)));
        try std.testing.expectEqual(@as(usize, 0), commit.calls);
        try std.testing.expect((try scenario.control.task_runtime.preparePermissionReview(scenario.task_id, scenario.text())) == null);
        const task = scenario.control.task_runtime.find(scenario.task_id).?;
        const review = &task.runtime.permission_review;
        try std.testing.expectEqual(case.cause, review.cause);
        try std.testing.expectEqualStrings(if (outcome == .failure) "" else "Evidence *** is missing.", review.reason[0..review.reason_len]);
        try std.testing.expect(!scenario.control.task_runtime.finishPermissionReview(preparation.identity, .{ .cause = .unavailable }));
        try std.testing.expectEqual(case.cause, review.cause);
        try std.testing.expectEqual(@as(usize, 0), task.durable.ui_history_count);
        try std.testing.expectEqual(preparation.identity.request_id, task.runtime.pending_ui_request_id);
        try scenario.control.respondUi(scenario.task_id, preparation.identity.run_id, preparation.identity.request_id, .{ .permission = .allow_once });
        try std.testing.expectEqual(.user, task.durable.ui_history[0].?.answered_by.?);
    }
}

test "Task permission review rejects persistence failure before delivering and preserves manual authority" {
    for ([_]product_task.DurableCommit{ .failed, .outcome_unknown }) |failure| {
        const scenario = try ReviewScenario.init();
        defer scenario.deinit();
        var preparation = try scenario.prepare();
        defer preparation.deinit();
        var commit = ReviewCommit{ .outcome = failure };
        try std.testing.expect(!try scenario.control.task_runtime.acceptPermissionReview(preparation.identity, reviewSuggestion(.allow_once, "ok"), commit.effects(scenario)));
        const task = scenario.control.task_runtime.find(scenario.task_id).?;
        try std.testing.expectEqual(@as(usize, 0), task.durable.ui_history_count);
        try std.testing.expectEqual(preparation.identity.request_id, task.runtime.pending_ui_request_id);
        try std.testing.expect((try scenario.control.task_runtime.preparePermissionReview(scenario.task_id, scenario.text())) == null);
        try scenario.control.respondUi(scenario.task_id, preparation.identity.run_id, preparation.identity.request_id, .{ .permission = .deny_once });
        try std.testing.expectEqual(.user, task.durable.ui_history[0].?.answered_by.?);
    }
}

test "Task permission review preserves the first Host-accepted decision" {
    for ([_]bool{ false, true }) |automatic_first| {
        const scenario = try ReviewScenario.init();
        defer scenario.deinit();
        var preparation = try scenario.prepare();
        defer preparation.deinit();
        var commit = ReviewCommit{};
        if (automatic_first) {
            try std.testing.expect(try scenario.control.task_runtime.acceptPermissionReview(preparation.identity, reviewSuggestion(.allow_once, "ok"), commit.effects(scenario)));
            if (scenario.control.respondUi(scenario.task_id, preparation.identity.run_id, preparation.identity.request_id, .{ .permission = .deny_once })) |_| {
                return error.TestUnexpectedResult;
            } else |err| {
                try std.testing.expect(err == error.NoPendingUiRequest or err == error.StaleUiResponse);
            }
        } else {
            try scenario.control.respondUi(scenario.task_id, preparation.identity.run_id, preparation.identity.request_id, .{ .permission = .deny_session });
            try std.testing.expect(!try scenario.control.task_runtime.acceptPermissionReview(preparation.identity, reviewSuggestion(.allow_once, "late"), commit.effects(scenario)));
        }
        const task = scenario.control.task_runtime.find(scenario.task_id).?;
        try std.testing.expectEqual(@as(usize, 1), task.durable.ui_history_count);
        try std.testing.expectEqual(if (automatic_first) @as(usize, 1) else 0, commit.calls);
        try std.testing.expectEqual(@as(@TypeOf(task.durable.ui_history[0].?.answered_by.?), if (automatic_first) .reviewer else .user), task.durable.ui_history[0].?.answered_by.?);
    }
}

test "Task permission review redelegation never reuses an earlier result" {
    const scenario = try ReviewScenario.init();
    defer scenario.deinit();
    var previous = try scenario.prepare();
    defer previous.deinit();
    _ = try scenario.control.task_runtime.testSetPermissionReviewDelegation(scenario.task_id, false);
    var current = try scenario.prepare();
    defer current.deinit();
    try std.testing.expect(current.identity.delegation_generation > previous.identity.delegation_generation);
    var commit = ReviewCommit{};
    try std.testing.expect(!try scenario.control.task_runtime.acceptPermissionReview(previous.identity, reviewSuggestion(.allow_once, "old"), commit.effects(scenario)));
    try std.testing.expect(try scenario.control.task_runtime.acceptPermissionReview(current.identity, reviewSuggestion(.allow_once, "new"), commit.effects(scenario)));
    try std.testing.expectEqual(@as(usize, 1), commit.calls);
}

test "Task permission review rejects every mismatched identity field without disturbing the live review" {
    const scenario = try ReviewScenario.init();
    defer scenario.deinit();
    var preparation = try scenario.prepare();
    defer preparation.deinit();
    var commit = ReviewCommit{};
    inline for (std.meta.fields(product_task.PermissionReviewIdentity)) |field| {
        var stale = preparation.identity;
        @field(stale, field.name) += 1;
        try std.testing.expect(!try scenario.control.task_runtime.acceptPermissionReview(stale, reviewSuggestion(.allow_once, "stale"), commit.effects(scenario)));
    }
    try std.testing.expectEqual(@as(usize, 0), commit.calls);
    try std.testing.expect(try scenario.control.task_runtime.acceptPermissionReview(preparation.identity, reviewSuggestion(.allow_once, "current"), commit.effects(scenario)));
}

test "Task permission review capacity rejection and invalid reasons leave a manual wait" {
    for ([_]?[]const u8{ null, "", " ", "bad\nreason", "\xff" }) |reason| {
        const scenario = try ReviewScenario.init();
        defer scenario.deinit();
        var preparation = try scenario.prepare();
        defer preparation.deinit();
        var commit = ReviewCommit{};
        if (reason) |value| {
            try std.testing.expect(!try scenario.control.task_runtime.acceptPermissionReview(preparation.identity, reviewSuggestion(.allow_once, value), commit.effects(scenario)));
        } else {
            try std.testing.expect(scenario.control.task_runtime.finishPermissionReview(preparation.identity, .{}));
        }
        try std.testing.expect((try scenario.control.task_runtime.preparePermissionReview(scenario.task_id, scenario.text())) == null);
        try std.testing.expectEqual(@as(usize, 0), commit.calls);
        try scenario.control.respondUi(scenario.task_id, preparation.identity.run_id, preparation.identity.request_id, .{ .permission = .deny_once });
    }
}

test "Task permission review prepared data survives cancellation deletion and shutdown" {
    for ([_]enum { cancel, delete, shutdown }{ .cancel, .delete, .shutdown }) |operation| {
        const scenario = try ReviewScenario.init();
        defer scenario.deinit();
        var preparation = try scenario.prepare();
        defer preparation.deinit();
        switch (operation) {
            .cancel => try scenario.control.cancel(scenario.task_id, preparation.identity.run_id),
            .delete => {
                try scenario.control.cancel(scenario.task_id, preparation.identity.run_id);
                try waitSetTaskArchived(&scenario.control, scenario.task_id);
                try scenario.control.deleteTask(scenario.task_id);
                try waitTaskDeleted(&scenario.control, scenario.task_id);
            },
            .shutdown => scenario.control.shutdownExecutor(),
        }
        try std.testing.expectEqualStrings("fixture-secret", preparation.execution.secret);
        try std.testing.expect(std.mem.indexOf(u8, preparation.input.user_intent, "bounded operation") != null);
        var commit = ReviewCommit{};
        try std.testing.expect(!try scenario.control.task_runtime.acceptPermissionReview(preparation.identity, reviewSuggestion(.allow_once, "late"), commit.effects(scenario)));
        try std.testing.expectEqual(@as(usize, 0), commit.calls);
    }
}

const BindingCloseContext = struct {
    binding: *product_task.testing.SessionBinding,
    finished: std.atomic.Value(bool) = .init(false),

    fn run(self: *@This()) void {
        _ = self.binding.closeOutcome(.session_close);
        self.finished.store(true, .release);
    }
};

fn taskSessionOpenOptions() lifecycle.SessionOpenOptions {
    const workspace_root = if (std.fs.path.sep == '\\')
        "C:\\tmp\\metawork-task-session-gateway"
    else
        "/tmp/metawork-task-session-gateway";
    const temporary_root = if (std.fs.path.sep == '\\') "C:\\tmp" else "/tmp";
    return .{
        .model_binding = .{
            .target = .{
                .provider_id = "fixture-provider",
                .protocol = .anthropic_messages,
                .base_url = "",
                .model = "fixture-model",
            },
            .credential = "fixture-secret",
        },
        .permission_mode = .default,
        .shell_policy = .disabled,
        .workspace = .{
            .canonical_root = workspace_root,
            .trust = .{ .temporary = temporary_root },
        },
    };
}

test "Task Session Binding close waits for Access quiescence and returns its Runtime slot" {
    fake_core.reset();
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }

    var binding = try product_task.testing.SessionBinding.open(
        runtime,
        taskSessionOpenOptions(),
    );
    var access = try binding.acquireAccess();
    var access_live = true;
    defer if (access_live) access.deinit();

    var context = BindingCloseContext{ .binding = &binding };
    const close_thread = try std.Thread.spawn(.{}, BindingCloseContext.run, .{&context});
    var close_thread_live = true;
    defer if (close_thread_live) {
        if (access_live) {
            access.deinit();
            access_live = false;
        }
        close_thread.join();
    };

    for (0..10_000) |_| {
        if (binding.acquireAccess()) |probe_value| {
            var probe = probe_value;
            probe.deinit();
            std.testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
            continue;
        } else |err| {
            try std.testing.expectEqual(error.SessionClosing, err);
            break;
        }
    } else return error.TestUnexpectedResult;
    try std.testing.expect(!context.finished.load(.acquire));

    access.deinit();
    access_live = false;
    close_thread.join();
    close_thread_live = false;
    try std.testing.expect(context.finished.load(.acquire));
    try std.testing.expectEqual(
        product_task.testing.SessionBindingState.closed,
        binding.state(),
    );
    try binding.releaseClosed();

    var replacement = try product_task.testing.SessionBinding.open(
        runtime,
        taskSessionOpenOptions(),
    );
    switch (replacement.closeOutcome(.session_close)) {
        .closed => {},
        .failure => return error.TestUnexpectedResult,
    }
    try replacement.releaseClosed();
}

test "Task Session Binding is terminal after Runtime shutdown relinquish" {
    fake_core.reset();
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
    });
    var shutdown_complete = false;
    defer {
        if (!shutdown_complete) shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }

    var binding = try product_task.testing.SessionBinding.open(
        runtime,
        taskSessionOpenOptions(),
    );
    try shutdownTestComposition(runtime);
    shutdown_complete = true;
    binding.relinquishAfterRuntimeShutdown();

    try std.testing.expectEqual(
        product_task.testing.SessionBindingState.relinquished,
        binding.state(),
    );
    try std.testing.expectEqual(@as(u64, 0), binding.routeId());
    try std.testing.expectError(error.RuntimeShuttingDown, binding.acquireAccess());
}

const TaskPersistenceProbe = struct {
    fixture_restore: ?[]const u8 = null,
    result: product_task.history.Commit = .committed,
    store_on_outcome_unknown: bool = false,
    storage: ?[]u8 = null,
    len: usize = 0,
    commits: usize = 0,
    main_thread: ?std.Thread.Id = null,
    main_commits: usize = 0,

    fn resolve(context: ?*anyopaque, token: product_task.history.CommitToken) product_task.history.Commit {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        if (!std.mem.eql(u8, &token, &(@as(product_task.history.CommitToken, @splat(23))))) return .outcome_unknown;
        if (self.result == .outcome_unknown) return .outcome_unknown;
        return if (self.store_on_outcome_unknown) .committed else .failed;
    }

    fn commit(context: ?*anyopaque, input: *product_task.history.Candidate) product_task.history.Commit {
        input.token = @splat(23);
        const bytes = product_task.history.encodeAlloc(std.testing.allocator, input.value, input.preserved, product_control.persistenceLimits(.{}, 16)) catch return .failed;
        defer std.testing.allocator.free(bytes);
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.commits += 1;
        if (self.main_thread) |thread| if (std.Thread.getCurrentId() == thread) {
            self.main_commits += 1;
        };
        if (self.result == .committed or
            (self.result == .outcome_unknown and self.store_on_outcome_unknown)) if (self.storage) |storage|
        {
            if (bytes.len > storage.len) return .failed;
            @memcpy(storage[0..bytes.len], bytes);
            self.len = bytes.len;
        };
        return self.result;
    }

    fn capability(self: *@This()) product_task.history.Capability {
        return .{
            .context = self,
            .enabled = true,
            .commit_fn = commit,
            .confirmed_commit_fn = commit,
            .resolve_commit_fn = resolve,
            .recover_fn = commit,
        };
    }

    fn restoreFixture(context: ?*anyopaque) anyerror!?product_task.history.RecoveredState {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        const bytes = self.fixture_restore orelse return null;
        return try product_task.history.decodeRecovering(std.testing.allocator, bytes, product_control.persistenceLimits(.{}, 16));
    }
    fn capabilityRestored(
        self: *@This(),
        restored_bytes: []const u8,
    ) product_task.history.Capability {
        var result = self.capability();
        self.fixture_restore = restored_bytes;
        result.restore_fn = restoreFixture;
        return result;
    }
};

/// Captures each actual writer call, including the candidate before lifecycle
/// reconciliation. A later successful save cannot hide an earlier rejection.
const CoverageCommitProbe = struct {
    const Observation = struct {
        phase: []const u8,
        coverage: task_state.ConversationCoverage,
        healthy: bool,
        bytes_match: bool,
    };
    control: ?*product_control.Runtime = null,
    task_id: u64 = 0,
    record_id: u64 = 0,
    compact: bool = false,
    observations: [16]Observation = undefined,
    count: usize = 0,

    fn capability(self: *@This()) product_task.history.Capability {
        return .{ .context = self, .enabled = true, .commit_fn = commit };
    }

    fn watch(self: *@This(), control: *product_control.Runtime, task_id: u64, record_id: u64, compact: bool) void {
        self.control = control;
        self.task_id = task_id;
        self.record_id = record_id;
        self.compact = compact;
        self.count = 0;
    }

    fn commit(context: ?*anyopaque, input: *product_task.history.Candidate) product_task.history.Commit {
        input.token = @splat(23);
        const bytes = product_task.history.encodeAlloc(std.testing.allocator, input.value, input.preserved, product_control.persistenceLimits(.{}, 16)) catch return .failed;
        defer std.testing.allocator.free(bytes);
        const self: *@This() = @ptrCast(@alignCast(context.?));
        if (self.record_id == 0) return .committed;
        if (self.count == self.observations.len) return .failed;
        const control = self.control.?;
        const task = control.task_runtime.find(self.task_id).?;
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const projected = product_task.history.projectTask(arena.allocator(), task, null) catch return .failed;
        const json = std.json.Stringify.valueAlloc(arena.allocator(), projected, .{}) catch return .failed;
        const phase, const coverage = if (self.compact) facts: {
            const compact = task_state.findCompact(task.durable.compacts, self.record_id).?;
            break :facts .{ @tagName(task_state.compactProjectionFacts(compact).phase), compact.coverage };
        } else facts: {
            const run = task_state.findRun(task.durable.runs, self.record_id).?;
            break :facts .{ @tagName(task_state.runPhase(run)), run.coverage };
        };
        self.observations[self.count] = .{
            .phase = phase,
            .coverage = coverage,
            .healthy = control.task_persistence_health == .ready,
            .bytes_match = std.mem.indexOf(u8, bytes, json) != null and
                std.mem.indexOf(u8, bytes, "exclude_on_product_terminal") == null,
        };
        self.count += 1;
        return .committed;
    }

    fn expect(self: *const @This(), index: usize, phase: []const u8, coverage: task_state.ConversationCoverage) !void {
        try std.testing.expect(index < self.count);
        const observation = self.observations[index];
        try std.testing.expectEqualStrings(phase, observation.phase);
        try std.testing.expectEqual(coverage, observation.coverage);
        for (self.observations[0..self.count]) |value| {
            try std.testing.expect(value.healthy);
            try std.testing.expect(value.bytes_match);
        }
    }
};

/// Uses the existing Product worker notifier after publication, rather than a
/// Core return or automatic-title Completion as a terminal barrier.
const TerminalPublicationGate = struct {
    target: union(enum) { none, run: *task_state.RunRecord, compact: *task_state.CompactRecord } = .none,
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    entered: std.atomic.Value(bool) = .init(false),
    released: bool = false,

    fn wake(context: ?*anyopaque) bool {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.mutex.lockUncancelable(std.testing.io);
        defer self.mutex.unlock(std.testing.io);
        const published = switch (self.target) {
            .none => false,
            .run => |run| run.terminal_publication.load(.acquire) == .published,
            .compact => |compact| compact.terminal_publication.load(.acquire) == .published,
        };
        // Compact also notifies before execution; that wake must pass through.
        if (!published or self.entered.load(.acquire)) return true;
        self.entered.store(true, .release);
        while (!self.released) self.condition.waitUncancelable(std.testing.io, &self.mutex);
        return true;
    }

    fn arm(self: *@This(), target: @FieldType(@This(), "target")) void {
        self.mutex.lockUncancelable(std.testing.io);
        defer self.mutex.unlock(std.testing.io);
        self.target = target;
    }

    fn wait(self: *@This()) !void {
        for (0..2_500) |_| {
            if (self.entered.load(.acquire)) return;
            try std.Io.sleep(std.testing.io, .fromMilliseconds(2), .awake);
        }
        return error.TestUnexpectedResult;
    }

    fn release(self: *@This()) void {
        self.mutex.lockUncancelable(std.testing.io);
        defer self.mutex.unlock(std.testing.io);
        self.target = .none;
        self.released = true;
        self.condition.broadcast(std.testing.io);
    }
};

// Observe both effect boundaries: a null projection alone cannot prove that
// an unauthorized root was never inspected or handed to AgentCore.
const WorkspaceSkillQueryProbe = struct {
    catalog: product_skill.ports.Catalog = undefined,
    root_checks: std.atomic.Value(usize) = .init(0),
    queries: std.atomic.Value(usize) = .init(0),
    hold_queries: std.atomic.Value(bool) = .init(false),

    fn attach(self: *@This(), workbench: *product_control.Runtime) void {
        self.catalog = workbench.skill.ports.catalog;
        workbench.skill.ports.catalog = .{ .context = self, .query_fn = query, .release_fn = release };
        workbench.skill.ports.source_roots = .{ .context = self, .discover_fn = discover };
    }

    fn discover(context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, home: []const u8, workspace: ?[]const u8, selection: product_skill.sources.Selection) anyerror!product_skill.sources.Discovery {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        if (workspace != null) _ = self.root_checks.fetchAdd(1, .release);
        return product_skill.sources.discover(io, allocator, home, workspace, selection);
    }

    fn query(context: *anyopaque, input: lifecycle.CatalogQuery) anyerror!lifecycle.CatalogAcquisition {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (input.target == .workspace) {
            _ = self.queries.fetchAdd(1, .release);
            while (self.hold_queries.load(.acquire))
                try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        }
        return self.catalog.query(input);
    }

    fn release(context: *anyopaque, lease: *lifecycle.CatalogLease) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.catalog.release(lease);
    }

    fn expectQueries(self: *const @This(), count: usize) !void {
        try std.testing.expectEqual(count, self.root_checks.load(.acquire));
        try std.testing.expectEqual(count, self.queries.load(.acquire));
    }
};

fn settleWorkspaceSkillQueries(workbench: *product_control.Runtime, id: u64) !void {
    for (0..5_000) |_| {
        workbench.syncLifecycle();
        const discovery = workbench.skill.workspaceSourceDiscovery(id, try workbench.workspaceEpoch(id));
        if (!workbench.skill.hasWorkspaceJob(id) and workbench.skill.personal_job == null and
            (discovery == null or !discovery.?.checking)) return;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    return error.TestUnexpectedResult;
}

fn waitInitialTaskCatalog(workbench: *product_control.Runtime, task_id: u64) !void {
    for (0..5000) |_| {
        try workbench.drainAgentEvents();
        if ((try workbench.taskCatalog(task_id)).availability != .loading) return;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    return error.TestUnexpectedResult;
}

fn expectWorkspaceSkillProjection(workbench: *product_control.Runtime, id: u64, present: bool) !void {
    var storage: [256 * 1024]u8 = undefined;
    const bytes = try workbench.writeAggregateFixture(&storage);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
    defer parsed.deinit();
    for (parsed.value.object.get("workspaces").?.array.items) |workspace| {
        if (try std.fmt.parseInt(u64, workspace.object.get("id").?.string, 10) != id) continue;
        try std.testing.expectEqual(present, workspace.object.get("skillSourceDiscovery").? != .null);
        const automatic = std.mem.eql(u8, "automatic", workspace.object.get("kind").?.string);
        if (!automatic and !present) {
            const catalog = workspace.object.get("skillCatalog").?;
            try std.testing.expectEqualStrings("unavailable", catalog.object.get("availability").?.string);
            try std.testing.expect(!catalog.object.get("redacted").?.bool);
            try std.testing.expect(catalog.object.get("revision").? == .null);
            try std.testing.expect(catalog.object.get("selectionRevision").? == .null);
            try std.testing.expectEqual(@as(usize, 0), catalog.object.get("skills").?.array.items.len);
            try std.testing.expectEqual(@as(usize, 0), catalog.object.get("issues").?.array.items.len);
        }
        if (automatic) {
            try std.testing.expect(!present);
            try std.testing.expectEqualStrings("0", workspace.object.get("recentOrder").?.string);
            try std.testing.expectEqualStrings("available", workspace.object.get("authorization").?.string);
            try std.testing.expect(workspace.object.get("lastRemovalFailure").? == .null);
        }
        return;
    }
    return error.TestUnexpectedResult;
}

test "Saved Workspace selection restores usable Manual roots without a picker" {
    fake_core.reset();
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 2, .max_sessions = 1 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);
    var store: product_skill.sources.FileStore = .{ .io = std.testing.io, .dir = tmp.dir };
    try store.commit(.{});
    const history = try std.testing.allocator.alloc(u8, product_task.history.max_store_bytes);
    defer std.testing.allocator.free(history);
    var persistence: TaskPersistenceProbe = .{ .storage = history };
    const input: product_control.TaskCreateInput = .{ .workspace_root = home, .trust = .explicitly_trusted };
    const limits: product_control.Limits = .{ .worker_count = 1, .queue_capacity = 2, .max_workspaces = 1, .max_tasks = 1, .max_runs_per_task = 1, .max_tools_per_run = 1 };
    var workspace_id: u64 = undefined;
    {
        var original = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, limits, .{
            .directories = .{ .canonical_user_home = home },
            .task_persistence = persistence.capability(),
            .skill_sources = .{ .file_store = &store, .restored = .{ .loaded = .{ .ready = .{} } } },
        });
        defer original.deinit();
        try installControlExecution(&original);
        workspace_id = try original.openWorkspace(input);
    }
    const restored_bytes = try std.testing.allocator.dupe(u8, history[0..persistence.len]);
    defer std.testing.allocator.free(restored_bytes);
    for ([_]bool{ false, true }) |recover_sources| {
        try store.commit(.{});
        var probe: WorkspaceSkillQueryProbe = .{};
        var restored = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, limits, .{
            .directories = .{ .canonical_user_home = home },
            .task_persistence = persistence.capabilityRestored(restored_bytes),
            .skill_sources = .{ .file_store = &store, .restored = if (recover_sources) .read_failed else .{ .loaded = .{ .ready = .{} } } },
        });
        defer restored.deinit();
        probe.attach(&restored);
        try installControlExecution(&restored);
        const authority = try restored.workspace.taskCreateAuthority(workspace_id, try restored.workspaceEpoch(workspace_id), false);
        try std.testing.expectEqualStrings(home, authority.canonical_root);
        const changed = if (recover_sources)
            restored.recoverSkillSourceSettings(.reread, restored.skill.sourceSettings().recovery_token.?)
        else
            restored.setSkillSourceEnabled(.claude, true, 1);
        try std.testing.expect(changed.applied);
        try settleWorkspaceSkillQueries(&restored, workspace_id);
        try std.testing.expect(probe.root_checks.load(.acquire) > 0);
        try std.testing.expect(probe.queries.load(.acquire) > 0);
        try expectWorkspaceSkillProjection(&restored, workspace_id, true);
        const task_id = try restored.createTaskInWorkspace(workspace_id, authority.epoch, try product_control.TestSupport.fixtureModelSelection(&restored), null, null, .{ .interactive = .manual });
        try std.testing.expectEqual(workspace_id, try restored.taskWorkspaceId(task_id));
    }
}

test "Saved Workspace selection rejects missing and non-directory roots after restart" {
    fake_core.reset();
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "saved", .default_dir);
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, "saved", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const history = try std.testing.allocator.alloc(u8, product_task.history.max_store_bytes);
    defer std.testing.allocator.free(history);
    var persistence: TaskPersistenceProbe = .{ .storage = history };
    const limits: product_control.Limits = .{ .worker_count = 1, .queue_capacity = 1, .max_workspaces = 1, .max_tasks = 1, .max_runs_per_task = 1, .max_tools_per_run = 1 };
    var workspace_id: u64 = undefined;
    {
        var original = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, limits, .{ .task_persistence = persistence.capability() });
        defer original.deinit();
        workspace_id = try original.openWorkspace(.{ .workspace_root = root, .trust = .explicitly_trusted });
    }
    const saved = try std.testing.allocator.dupe(u8, history[0..persistence.len]);
    defer std.testing.allocator.free(saved);
    try tmp.dir.deleteDir(std.testing.io, "saved");
    for ([_]bool{ false, true }) |as_file| {
        if (as_file) {
            var file = try tmp.dir.createFile(std.testing.io, "saved", .{});
            file.close(std.testing.io);
        }
        var restored = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, limits, .{ .task_persistence = persistence.capabilityRestored(saved) });
        defer restored.deinit();
        try std.testing.expectError(error.WorkspaceUnavailable, restored.workspace.taskCreateAuthority(workspace_id, try restored.workspaceEpoch(workspace_id), false));
        try expectWorkspaceSkillProjection(&restored, workspace_id, false);
    }
}

test "Automatic catalog uses personal discovery after creation and waits for Session recovery" {
    fake_core.reset();
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 2, .max_sessions = 1 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);
    var store: product_skill.sources.FileStore = .{ .io = std.testing.io, .dir = tmp.dir };
    const history = try std.testing.allocator.alloc(u8, product_task.history.max_store_bytes);
    defer std.testing.allocator.free(history);
    var persistence: TaskPersistenceProbe = .{ .storage = history };
    for ([_]bool{ false, true }) |recover_sources| {
        var restored_bytes: ?[]u8 = null;
        defer if (restored_bytes) |bytes| std.testing.allocator.free(bytes);
        var task_id: u64 = undefined;
        for ([_]bool{ false, true }) |restore_workspace| {
            var automatic_root = try product_control.AutomaticWorkspaceRoot.open(std.testing.io, std.testing.allocator, home);
            defer automatic_root.deinit();
            try store.commit(.{});
            var enablement_store = try product_skill.enablement.FileStore.init(std.testing.io, home);
            defer enablement_store.deinit();
            var probe: WorkspaceSkillQueryProbe = .{};
            var workbench = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, .{
                .worker_count = 1,
                .queue_capacity = 2,
                .max_workspaces = 1,
                .max_tasks = 1,
                .max_runs_per_task = 1,
                .max_tools_per_run = 1,
            }, .{
                .directories = .{ .canonical_user_home = home, .testing_automatic_workspace_root = if (restore_workspace) null else &automatic_root },
                .task_persistence = if (restore_workspace) persistence.capabilityRestored(restored_bytes.?) else persistence.capability(),
                .skill_enablement = .{ .file_store = &enablement_store },
                .skill_sources = .{ .file_store = &store, .restored = if (recover_sources) .read_failed else .{ .loaded = .{ .ready = .{} } } },
            });
            defer workbench.deinit();
            probe.attach(&workbench);
            defer probe.hold_queries.store(false, .release);
            if (!restore_workspace and !recover_sources) probe.hold_queries.store(true, .release);
            try installControlExecution(&workbench);
            if (!restore_workspace) {
                task_id = try workbench.createTaskForWorkspace(.automatic, try product_control.TestSupport.fixtureModelSelection(&workbench), null, null, .{ .interactive = null });
                if (!recover_sources) {
                    for (0..5000) |_| {
                        if (probe.queries.load(.acquire) > 0) break;
                        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
                    }
                    try std.testing.expect(probe.queries.load(.acquire) > 0);
                    try std.testing.expectEqual(product_control.CatalogAvailability.loading, (try workbench.taskCatalog(task_id)).availability);
                    try std.testing.expectError(error.CatalogLoading, workbench.runTask(task_id, .{ .text = "wait before first Run" }));
                    probe.hold_queries.store(false, .release);
                    try waitInitialTaskCatalog(&workbench, task_id);
                }
                restored_bytes = try std.testing.allocator.dupe(u8, history[0..persistence.len]);
            }
            const workspace_id = try workbench.taskWorkspaceId(task_id);
            try expectWorkspaceSkillProjection(&workbench, workspace_id, false);
            const changed = if (recover_sources)
                workbench.recoverSkillSourceSettings(.reread, workbench.skill.sourceSettings().recovery_token.?)
            else
                workbench.setSkillSourceEnabled(.codex, true, 1);
            try std.testing.expect(changed.applied);
            try expectWorkspaceSkillProjection(&workbench, workspace_id, false);
            try settleWorkspaceSkillQueries(&workbench, workspace_id);
            try expectWorkspaceSkillProjection(&workbench, workspace_id, false);
            try std.testing.expectEqual(@as(usize, 0), probe.root_checks.load(.acquire));
            if (restore_workspace) {
                try std.testing.expectEqual(@as(usize, 0), probe.queries.load(.acquire));
            } else {
                try std.testing.expect(probe.queries.load(.acquire) > 0);
                try workbench.refreshTaskCatalog(task_id, try workbench.taskBindingEpoch(task_id));
                const pinned = try workbench.taskCatalog(task_id);
                try std.testing.expect(pinned.availability == .ready or pinned.availability == .degraded);
                // The fixture winner is workspace-local data and must not be granted.
                try std.testing.expectEqual(@as(usize, 1), pinned.skills.len);
                try std.testing.expect(!pinned.skills[0].enabled);
            }
            if (restore_workspace)
                try std.testing.expectError(error.WorkspaceUnavailable, workbench.refreshWorkspaceCatalog(workspace_id, try workbench.workspaceEpoch(workspace_id)))
            else {
                try workbench.refreshWorkspaceCatalog(workspace_id, try workbench.workspaceEpoch(workspace_id));
                try settleWorkspaceSkillQueries(&workbench, workspace_id);
            }
        }
    }
}

test "Automatic deletion retains Workspace authority until the catalog worker drains" {
    fake_core.reset();
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 2, .max_sessions = 1 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);
    var automatic_root = try product_control.AutomaticWorkspaceRoot.open(std.testing.io, std.testing.allocator, home);
    defer automatic_root.deinit();
    var enablement_store = try product_skill.enablement.FileStore.init(std.testing.io, home);
    defer enablement_store.deinit();
    var workbench = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, .{
        .worker_count = 1,
        .queue_capacity = 2,
        .max_workspaces = 1,
        .max_tasks = 1,
        .max_runs_per_task = 1,
        .max_tools_per_run = 1,
    }, .{
        .directories = .{ .canonical_user_home = home, .testing_automatic_workspace_root = &automatic_root },
        .skill_enablement = .{ .file_store = &enablement_store },
        .skill_sources = .{ .restored = .{ .loaded = .{ .ready = .{} } } },
    });
    defer workbench.deinit();
    var probe: WorkspaceSkillQueryProbe = .{};
    probe.attach(&workbench);
    probe.hold_queries.store(true, .release);
    defer probe.hold_queries.store(false, .release);
    try installControlExecution(&workbench);
    const id = try workbench.createTaskForWorkspace(.automatic, try product_control.TestSupport.fixtureModelSelection(&workbench), null, null, .{ .interactive = .full_access });
    for (0..5000) |_| {
        if (probe.queries.load(.acquire) > 0) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expect(probe.queries.load(.acquire) > 0);
    const workspace_id = try workbench.taskWorkspaceId(id);
    const root = try std.testing.allocator.dupe(u8, workbench.workspace.facts(workspace_id).?.canonical_root);
    defer std.testing.allocator.free(root);
    try workbench.setTaskArchived(id, true);
    try workbench.deleteTask(id);
    try std.testing.expectEqual(workspace_id, try workbench.taskWorkspaceId(id));
    var retained = try std.Io.Dir.openDirAbsolute(std.testing.io, root, .{});
    retained.close(std.testing.io);
    probe.hold_queries.store(false, .release);
    for (0..5000) |_| {
        workbench.syncLifecycle();
        if (workbench.task_runtime.taskWorkspaceId(id) == null) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expect(workbench.task_runtime.taskWorkspaceId(id) == null);
    try std.testing.expect(!workbench.skill.hasWorkspaceJob(workspace_id));
    try std.testing.expect(workbench.workspace.facts(workspace_id) == null);
    // Product deletion retires records; the actual Automatic work directory is retained.
    var preserved = try std.Io.Dir.openDirAbsolute(std.testing.io, root, .{});
    preserved.close(std.testing.io);
}

test "Skill source authorization returns after close failures and checkpoint interleaving" {
    fake_core.reset();
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);
    var store: product_skill.sources.FileStore = .{ .io = std.testing.io, .dir = tmp.dir };
    for ([_]bool{ true, false }) |immediate_failure| {
        try store.commit(.{});
        var checkpoint_store = try product_task.checkpoint_store.FileStore.init(std.testing.io, home);
        defer checkpoint_store.deinit();
        var persistence: TaskPersistenceProbe = .{};
        var probe: WorkspaceSkillQueryProbe = .{};
        var workbench = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, .{
            .worker_count = 1,
            .queue_capacity = 1,
            .max_workspaces = 1,
            .max_tasks = 1,
            .max_runs_per_task = 1,
            .max_tools_per_run = 1,
        }, .{
            .directories = .{ .canonical_user_home = home },
            .task_persistence = persistence.capability(),
            .checkpoint_store = .{ .file_store = &checkpoint_store },
            .skill_sources = .{ .file_store = &store, .restored = .{ .loaded = .{ .ready = .{} } } },
        });
        defer {
            fake_core.releaseCheckpointExport();
            workbench.deinit();
        }
        probe.attach(&workbench);
        try installControlExecution(&workbench);
        const workspace_id = try workbench.openWorkspace(.{ .workspace_root = home, .trust = .explicitly_trusted });
        try settleWorkspaceSkillQueries(&workbench, workspace_id);
        try probe.expectQueries(1);
        const epoch = try workbench.workspaceEpoch(workspace_id);
        const task_id = try workbench.createTaskInWorkspace(workspace_id, epoch, try product_control.TestSupport.fixtureModelSelection(&workbench), null, null, .{ .interactive = null });
        if (immediate_failure) {
            // Close admission succeeds, but Session close must not start until
            // the exporting checkpoint has settled and released its lease.
            fake_core.controlNextCheckpointExport();
            _ = try runPreparedTask(&workbench, task_id, .{ .text = "hold checkpoint during removal" });
            fake_core.waitCheckpointExportEntered();
            try waitControlSnapshot(&workbench, "\"terminal\":{\"outcome\":\"completed\"");
            fake_core.failNextSessionDestroy();
            try workbench.removeWorkspaceAtEpoch(workspace_id, epoch);
            fake_core.releaseCheckpointExport();
        } else {
            fake_core.failNextSessionDestroy();
            try workbench.removeWorkspaceAtEpoch(workspace_id, epoch);
        }
        try waitControlSnapshot(&workbench, "\"lastRemovalFailure\":\"task_close_failed\"");
        if (immediate_failure) try std.testing.expectEqual(
            product_task.testing.state_module.ConversationCoverage.covered,
            workbench.task_runtime.tasks[0].?.durable.runs[0].?.coverage,
        );
        try settleWorkspaceSkillQueries(&workbench, workspace_id);
        try probe.expectQueries(if (immediate_failure) 3 else 2);
        try expectWorkspaceSkillProjection(&workbench, workspace_id, true);
        // The restored grant remains usable, rather than only displaying ready.
        try workbench.refreshWorkspaceCatalog(workspace_id, try workbench.workspaceEpoch(workspace_id));
        try settleWorkspaceSkillQueries(&workbench, workspace_id);
        try probe.expectQueries(if (immediate_failure) 4 else 3);
    }
}

fn expectFakeSessionModel(index: usize, expected: []const u8) !void {
    const session = &fake_core.sessions[index];
    session.lock();
    defer session.unlock();
    try std.testing.expectEqualStrings(expected, session.model[0..session.model_len]);
}

fn installTwoModelCatalog(workbench: *product_control.Runtime) void {
    const models = [_]models_contract.ModelView{
        .{ .id = "fixture-model", .display_name = "Fixture model", .metadata = .{ .capabilities = .{ .image_input = false } } },
        .{ .id = "fixture-model-2", .display_name = "Fixture model 2" },
    };
    product_control.TestSupport.replaceMetaskCatalog(
        workbench,
        &models,
        "fixture-model",
    ) catch unreachable;
}

fn taskModelSelectionInput(
    workbench: *product_control.Runtime,
    expected_revision: u64,
    target_model: []const u8,
) product_control.TaskModelSelectionInput {
    const models = workbench.modelsView();
    return .{
        .expected_selection_revision = expected_revision,
        .target = .{
            .source_id = models_contract.metask_source_id,
            .model_id = target_model,
        },
        .expected_source_generation = models.providers[0].source_generation,
        .expected_catalog_generation = models.providers[0].catalog_generation,
    };
}

fn newTaskModelSelectionInput(
    workbench: *product_control.Runtime,
    target_model: []const u8,
) product_control.NewTaskModelSelectionInput {
    const models = workbench.modelsView();
    return .{
        .target = .{
            .source_id = models_contract.metask_source_id,
            .model_id = target_model,
        },
        .expected_source_generation = models.providers[0].source_generation,
        .expected_catalog_generation = models.providers[0].catalog_generation,
    };
}

test "new Task model selection binds only the created Task and rejects stale authority" {
    fake_core.reset();
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var workbench = try product_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 1,
            .max_workspaces = 1,
            .max_tasks = 1,
            .max_runs_per_task = 1,
            .max_tools_per_run = 1,
        },
        productControlConfiguration(),
    );
    defer workbench.deinit();
    try installControlExecution(&workbench);
    installTwoModelCatalog(&workbench);
    const workspace_id = try workbench.openWorkspace(productControlTaskInput());
    const workspace_epoch = try workbench.workspaceEpoch(workspace_id);
    var stale = newTaskModelSelectionInput(&workbench, "fixture-model-2");
    stale.expected_catalog_generation += 1;
    try std.testing.expectError(
        error.ModelSelectionChanged,
        workbench.createTaskInWorkspace(workspace_id, workspace_epoch, stale, null, null, .{ .interactive = null }),
    );
    var stale_source = newTaskModelSelectionInput(&workbench, "fixture-model-2");
    stale_source.expected_source_generation += 1;
    try std.testing.expectError(
        error.ModelSelectionChanged,
        workbench.createTaskInWorkspace(workspace_id, workspace_epoch, stale_source, null, null, .{ .interactive = null }),
    );
    try std.testing.expectError(
        error.ModelSelectionChanged,
        workbench.createTaskInWorkspace(workspace_id, workspace_epoch, newTaskModelSelectionInput(&workbench, "missing-model"), null, null, .{ .interactive = null }),
    );

    const task_id = try workbench.createTaskInWorkspace(workspace_id, workspace_epoch, newTaskModelSelectionInput(&workbench, "fixture-model-2"), null, null, .{ .interactive = null });
    const identity = try workbench.taskExecutionIdentity(task_id);
    try std.testing.expectEqualStrings("fixture-model-2", identity.model);
    const intent = workbench.task_runtime.findConst(task_id).?.durable.model_intent.?;
    try std.testing.expectEqualStrings("metask", intent.source_id);
    try std.testing.expectEqualStrings("fixture-model-2", intent.model_id);
    try std.testing.expectEqual(@as(u64, 1), intent.revision);
    try expectFakeSessionModel(0, "fixture-model-2");
    try std.testing.expectEqualStrings(
        "fixture-model",
        workbench.modelsView().default_selection.?.model_id,
    );
    const run_id = try runPreparedTask(&workbench, task_id, .{ .text = "Use the model selected before the first send" });
    try waitControlSnapshot(&workbench, "\"phase\":\"completed\"");
    const task = workbench.task_runtime.findConst(task_id).?;
    try std.testing.expectEqual(run_id, task.durable.runs[0].?.id);
    try std.testing.expectEqualStrings("fixture-model-2", task.durable.runs[0].?.execution_model);
    try std.testing.expectEqual(intent.revision, task.runtime.executionConst().?.model_intent_revision);
}

test "new Task model selection is independent of default execution admission" {
    fake_core.reset();
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var workbench = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, .{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_workspaces = 1,
        .max_tasks = 1,
        .max_runs_per_task = 1,
        .max_tools_per_run = 1,
    }, productControlConfiguration());
    defer workbench.deinit();
    try installControlExecution(&workbench);
    installTwoModelCatalog(&workbench);
    const workspace_id = try workbench.openWorkspace(productControlTaskInput());
    const epoch = try workbench.workspaceEpoch(workspace_id);
    const selection = newTaskModelSelectionInput(&workbench, "fixture-model-2");
    product_control.TestSupport.clearModelPreference(&workbench);
    try std.testing.expect(workbench.newTaskAdmissionView().available);
    const task_id = try workbench.createTaskInWorkspace(workspace_id, epoch, selection, null, null, .{ .interactive = null });
    const identity = try workbench.taskExecutionIdentity(task_id);
    try std.testing.expectEqualStrings("fixture-model-2", identity.model);
    try std.testing.expect(identity.generation != 0);
    try expectFakeSessionModel(0, "fixture-model-2");
    try std.testing.expect(workbench.modelsView().default_selection == null);
    try std.testing.expectEqual(models_contract.ModelsError.preference_not_saved, workbench.modelsView().error_code);
    const execution = workbench.task_runtime.findConst(task_id).?.runtime.executionConst().?;
    try std.testing.expectEqual(models_contract.Protocol.anthropic_messages, execution.protocol);
    try std.testing.expectEqualStrings(models_contract.metask_anthropic_messages_url, execution.base_url);
    const intent = workbench.task_runtime.findConst(task_id).?.durable.model_intent.?;
    try std.testing.expectEqualStrings("metask", intent.source_id);
    try std.testing.expectEqualStrings("fixture-model-2", intent.model_id);
}

const TaskModelsVault = struct {
    const slot = "custom-provider-" ++ "0" ** 32;
    secret: [models_contract.Limits.credential_bytes]u8 = undefined,
    len: usize = 0,
    fn generate(_: *anyopaque, output: *[fixture.models_ports.credential_slot_bytes]u8) anyerror!void {
        @memcpy(output, slot);
    }
    fn store(ctx: *anyopaque, _: []const u8, value: []const u8) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        @memcpy(self.secret[0..value.len], value);
        self.len = value.len;
    }
    fn get(ctx: *anyopaque, _: []const u8, output: []u8) anyerror!?[]const u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (self.len == 0) return null;
        @memcpy(output[0..self.len], self.secret[0..self.len]);
        return output[0..self.len];
    }
    fn delete(ctx: *anyopaque, _: []const u8) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        std.crypto.secureZero(u8, self.secret[0..self.len]);
        self.len = 0;
    }
    fn port(self: *@This()) fixture.models_ports.CredentialVault {
        return .{ .context = self, .generate_slot_fn = generate, .store_fn = store, .get_fn = get, .delete_fn = delete };
    }
};

test "new Task model selection uses the full custom connection with or without a default" {
    fake_core.reset();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const Vault = TaskModelsVault;
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 2 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var workbench = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, .{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_workspaces = 1,
        .max_tasks = 2,
        .max_runs_per_task = 1,
        .max_tools_per_run = 1,
    }, productControlConfiguration());
    defer workbench.deinit();
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(std.testing.io, &path);
    var vault: Vault = .{};
    defer Vault.delete(&vault, Vault.slot) catch unreachable;
    try workbench.startCustomProviders(path[0..length], vault.port());
    defer workbench.stopCustomProviders();
    try installControlExecution(&workbench);
    try std.testing.expect(workbench.createCustomProviderWithCredential("other-secret", .{
        .display_name = "Other",
        .protocol = .openai_responses,
        .normalized_base_url = "https://other.example.com/v1/responses",
    }).accepted);
    const created = workbench.modelsView().custom_providers[0];
    try std.testing.expect(workbench.submitCustomProviderCommand(.{ .add_custom_model = .{
        .source_id = Vault.slot,
        .expected_provider_revision = created.provider_revision,
        .expected_catalog_generation = created.catalog_generation,
        .model = .{ .id = "other-model" },
    } }).accepted);
    const configured = workbench.modelsView().custom_providers[0];
    const probe_command: models_contract.CustomModelTestCommand = .{
        .model = .{ .source_id = Vault.slot, .model_id = "other-model" },
        .expected_provider_revision = configured.provider_revision,
        .expected_source_generation = configured.source_generation,
        .expected_catalog_generation = configured.catalog_generation,
    };
    var probe = switch (workbench.beginCustomProviderProbe(probe_command)) {
        .ready => |value| value,
        .rejected => return error.TestUnexpectedResult,
    };
    probe.deinit();
    try std.testing.expect(workbench.completeCustomModelTest(probe_command, true).accepted);
    const ready = workbench.modelsView().custom_providers[0];
    const selection: product_control.NewTaskModelSelectionInput = .{ .target = probe_command.model, .expected_source_generation = ready.source_generation, .expected_catalog_generation = ready.catalog_generation };
    const workspace_id = try workbench.openWorkspace(productControlTaskInput());
    const epoch = try workbench.workspaceEpoch(workspace_id);
    for ([_]bool{ true, false }) |has_default| {
        if (!has_default) {
            try std.testing.expect(workbench.clearCustomProviderDefault().accepted);
            try std.testing.expect(workbench.modelsView().default_selection == null);
            try std.testing.expect(workbench.newTaskAdmissionView().available);
        }
        const task_id = try workbench.createTaskInWorkspace(workspace_id, epoch, selection, null, null, .{ .interactive = null });
        const task = workbench.task_runtime.findConst(task_id).?;
        const execution = task.runtime.executionConst().?;
        try std.testing.expectEqualStrings("custom_provider:" ++ Vault.slot, execution.provider_id);
        try std.testing.expectEqual(models_contract.Protocol.openai_responses, execution.protocol);
        try std.testing.expectEqualStrings("https://other.example.com/v1/responses", execution.base_url);
        try std.testing.expectEqualStrings("other-secret", execution.input().api_key);
        try std.testing.expectEqualStrings(Vault.slot, task.durable.model_intent.?.source_id);
        try std.testing.expectEqualStrings("other-model", task.durable.execution_model);
        try std.testing.expectEqual(@as(?u32, wire.PROVIDER_OPENAI), fake_core.last_created_provider_kind_code);
        try std.testing.expectEqual(@as(?u32, wire.OPENAI_PROTOCOL_RESPONSES), fake_core.last_created_protocol_kind_code);
        try std.testing.expectEqualStrings(TaskModelsVault.slot, workbench.modelsView().default_selection.?.source_id);
    }
}

fn configureTaskRebindTarget(workbench: *product_control.Runtime) !models_contract.CustomModelTestCommand {
    if (workbench.modelsView().custom_providers.len == 0) {
        try std.testing.expect(workbench.createCustomProviderWithCredential("other-secret", .{
            .display_name = "Other",
            .protocol = .openai_responses,
            .normalized_base_url = "https://other.example.com/v1/responses",
        }).accepted);
        const created = workbench.modelsView().custom_providers[0];
        try std.testing.expect(workbench.submitCustomProviderCommand(.{ .add_custom_model = .{
            .source_id = TaskModelsVault.slot,
            .expected_provider_revision = created.provider_revision,
            .expected_catalog_generation = created.catalog_generation,
            .model = .{ .id = "other-model" },
        } }).accepted);
    }
    const configured = workbench.modelsView().custom_providers[0];
    const probe: models_contract.CustomModelTestCommand = .{
        .model = .{ .source_id = TaskModelsVault.slot, .model_id = "other-model" },
        .expected_provider_revision = configured.provider_revision,
        .expected_source_generation = configured.source_generation,
        .expected_catalog_generation = configured.catalog_generation,
    };
    var preparation = switch (workbench.beginCustomProviderProbe(probe)) {
        .ready => |value| value,
        .rejected => return error.TestUnexpectedResult,
    };
    preparation.deinit();
    try std.testing.expect(workbench.completeCustomModelTest(probe, true).accepted);
    return probe;
}

/// Adds another ready model to the rebind target connection created above.
fn configureTaskRebindModel(workbench: *product_control.Runtime, model_id: []const u8) !models_contract.CustomModelTestCommand {
    const current = workbench.modelsView().custom_providers[0];
    const present = for (current.models) |model| {
        if (std.mem.eql(u8, model.id, model_id)) break true;
    } else false;
    if (!present) try std.testing.expect(workbench.submitCustomProviderCommand(.{ .add_custom_model = .{
        .source_id = TaskModelsVault.slot,
        .expected_provider_revision = current.provider_revision,
        .expected_catalog_generation = current.catalog_generation,
        .model = .{ .id = model_id },
    } }).accepted);
    const configured = workbench.modelsView().custom_providers[0];
    const probe: models_contract.CustomModelTestCommand = .{
        .model = .{ .source_id = TaskModelsVault.slot, .model_id = model_id },
        .expected_provider_revision = configured.provider_revision,
        .expected_source_generation = configured.source_generation,
        .expected_catalog_generation = configured.catalog_generation,
    };
    var preparation = switch (workbench.beginCustomProviderProbe(probe)) {
        .ready => |value| value,
        .rejected => return error.TestUnexpectedResult,
    };
    preparation.deinit();
    try std.testing.expect(workbench.completeCustomModelTest(probe, true).accepted);
    return probe;
}

test "Task source settings stay pinned until an explicit same-model selection installs new authority" {
    for ([_]bool{ false, true }) |replace_credential| {
        fake_core.reset();
        fake_core.setCheckpointGeneration(1);
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        defer std.testing.allocator.free(home);
        var checkpoints = try product_task.checkpoint_store.FileStore.init(std.testing.io, home);
        defer checkpoints.deinit();
        const bytes = try std.testing.allocator.alloc(u8, product_task.history.max_store_bytes);
        defer std.testing.allocator.free(bytes);
        var history = TaskPersistenceProbe{ .storage = bytes };
        var configuration = productControlConfiguration();
        configuration.directories.canonical_user_home = home;
        configuration.task_persistence = history.capability();
        configuration.checkpoint_store = .{ .file_store = &checkpoints };
        const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 2, .max_sessions = 1 });
        defer {
            shutdownTestComposition(runtime) catch unreachable;
            deinitTestComposition(runtime);
        }
        var workbench = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, .{
            .worker_count = 1,
            .queue_capacity = 2,
            .max_workspaces = 1,
            .max_tasks = 1,
            .max_runs_per_task = 3,
            .max_tools_per_run = 1,
        }, configuration);
        defer workbench.deinit();
        defer fake_core.releaseControlled();
        var vault: TaskModelsVault = .{};
        defer TaskModelsVault.delete(&vault, TaskModelsVault.slot) catch unreachable;
        try workbench.startCustomProviders(home, vault.port());
        defer workbench.stopCustomProviders();
        try installControlExecution(&workbench);
        installTwoModelCatalog(&workbench);
        const initial = try configureTaskRebindTarget(&workbench);
        var workspace_input = productControlTaskInput();
        workspace_input.workspace_root = home;
        workspace_input.trust = .explicitly_trusted;
        const workspace = try workbench.openWorkspace(workspace_input);
        fake_core.setNextPlan(.controlled);
        const task_id = try workbench.createTaskInWorkspace(workspace, try workbench.workspaceEpoch(workspace), .{
            .target = initial.model,
            .expected_source_generation = initial.expected_source_generation,
            .expected_catalog_generation = initial.expected_catalog_generation,
        }, null, null, .{ .interactive = .manual });
        const task = workbench.task_runtime.find(task_id).?;
        const installed_source_generation = task.runtime.executionConst().?.source_generation;
        const old_execution_generation = task.durable.execution_generation;
        const old_revision = task.durable.model_intent.?.revision;
        const old_epoch = task.durable.binding_epoch;
        const first_run = try runPreparedTask(&workbench, task_id, .{ .text = "stay on the already installed source" });
        try waitControlSnapshot(&workbench, "\"currentRunPhase\":\"running\"");
        const current = workbench.modelsView().custom_providers[0];
        if (replace_credential) {
            try std.testing.expect(workbench.replaceCustomProviderCredential("replacement-secret", .{ .source_id = TaskModelsVault.slot, .expected_provider_revision = current.provider_revision }).accepted);
        } else {
            try std.testing.expect(workbench.submitCustomProviderCommand(.{ .update = .{
                .selection = .{ .source_id = TaskModelsVault.slot, .expected_provider_revision = current.provider_revision },
                .spec = .{ .display_name = "Updated connection", .protocol = .gemini_native, .normalized_base_url = "https://updated.example.com" },
            } }).accepted);
        }
        const changed = workbench.modelsView().custom_providers[0];
        try std.testing.expect(changed.source_generation != installed_source_generation);
        try std.testing.expectError(error.StaleCatalog, workbench.selectTaskModel(task_id, .{
            .expected_selection_revision = old_revision,
            .target = initial.model,
            .expected_source_generation = changed.source_generation,
            .expected_catalog_generation = changed.catalog_generation,
        }));
        try std.testing.expectEqual(old_revision, task.durable.model_intent.?.revision);
        try std.testing.expectEqual(old_execution_generation, task.durable.execution_generation);
        try std.testing.expectEqualStrings("other-secret", task.runtime.executionConst().?.secret);
        try std.testing.expectEqualStrings("https://other.example.com/v1/responses", task.runtime.executionConst().?.base_url);
        try std.testing.expectEqual(models_contract.Protocol.openai_responses, task.runtime.executionConst().?.protocol);
        // Resolving the same public model under the new source authority and
        // explicitly selecting it is a new Task intent, even during a Run.
        const validated = try configureTaskRebindTarget(&workbench);
        const revision = try workbench.selectTaskModel(task_id, .{
            .expected_selection_revision = old_revision,
            .target = validated.model,
            .expected_source_generation = validated.expected_source_generation,
            .expected_catalog_generation = validated.expected_catalog_generation,
        });
        try std.testing.expectEqual(old_revision + 1, revision);
        try std.testing.expectEqual(first_run, task.runtime.active_operation.run);
        try std.testing.expectEqual(old_execution_generation, task.durable.runs[0].?.execution_generation);
        try std.testing.expectEqual(models_contract.Protocol.openai_responses, task.durable.runs[0].?.execution_protocol);
        try std.testing.expectEqual(installed_source_generation, task.runtime.executionConst().?.source_generation);
        fake_core.releaseControlled();
        try waitCheckpointRecord(&workbench, &history);
        for (0..2000) |_| {
            workbench.syncLifecycle();
            if (task.runtime.active_operation == .none and !task.runtime.worker_leases.hasLive()) break;
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        }
        fake_core.setRestoredLogicalId(task.durable.checkpoint.?.session.logical_session_id);
        fake_core.setRestoredModel("other-model");
        fake_core.lock();
        fake_core.restore_last_run_id = first_run;
        fake_core.unlock();
        try std.testing.expectError(error.RestoreBusy, workbench.runTask(task_id, .{ .text = "apply the explicitly selected new authority" }));
        try std.testing.expect(task.durable.runs[1] == null);
        for (0..5000) |_| {
            try workbench.drainAgentEvents();
            workbench.syncLifecycle();
            if (task.runtime.restore_job == null and !task.runtime.worker_leases.hasLive()) break;
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        }
        if (task.runtime.last_restore_failure) |failure| std.debug.print("source reselect failed: {s}\n", .{@tagName(failure)});
        try std.testing.expect(task.runtime.last_restore_failure == null);
        const execution = task.runtime.executionConst().?;
        try std.testing.expectEqual(validated.expected_source_generation, execution.source_generation);
        try std.testing.expectEqual(revision, execution.model_intent_revision);
        try std.testing.expectEqualStrings(if (replace_credential) "replacement-secret" else "other-secret", execution.secret);
        try std.testing.expectEqualStrings(if (replace_credential) "https://other.example.com/v1/responses" else "https://updated.example.com", execution.base_url);
        try std.testing.expectEqual(if (replace_credential) models_contract.Protocol.openai_responses else models_contract.Protocol.gemini_native, execution.protocol);
        try std.testing.expectEqual(old_epoch + 1, task.durable.binding_epoch);
        try std.testing.expectEqualStrings("other-model", task.durable.execution_model);
        try std.testing.expectEqualStrings(TaskModelsVault.slot, workbench.modelsView().default_selection.?.source_id);
        try std.testing.expectEqual(@as(u64, 2), try runPreparedTask(&workbench, task_id, .{ .text = "apply the explicitly selected new authority" }));
        try std.testing.expectEqual(execution.protocol, task.durable.runs[1].?.execution_protocol);
    }
}

test "Task model rebind confirms a full target connection and restores the original once on failure" {
    const Failure = enum { none, restore, set_model, target_export, stale_intent, baseline_export, baseline_history, original_close, original_close_start, target_queue, candidate_close, candidate_close_start, rollback, rollback_queue, baseline_unknown_old, baseline_unknown_new, baseline_unknown_shutdown, shutdown };
    const Blocker = struct {
        entered: std.atomic.Value(bool) = .init(false),
        released: std.atomic.Value(bool) = .init(false),
        fn execute(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.entered.store(true, .release);
            while (!self.released.load(.acquire))
                std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch {};
        }
        fn noop(_: *anyopaque) void {}
    };
    for (std.enums.values(Failure)) |failure| {
        const unknown = failure == .baseline_unknown_old or failure == .baseline_unknown_new or failure == .baseline_unknown_shutdown;
        const reject_target = failure != .none and failure != .baseline_unknown_new;
        fake_core.reset();
        fake_core.setCheckpointGeneration(1);
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        defer std.testing.allocator.free(home);
        var checkpoint_store = try product_task.checkpoint_store.FileStore.init(std.testing.io, home);
        defer checkpoint_store.deinit();
        const storage = try std.testing.allocator.alloc(u8, product_task.history.max_store_bytes);
        defer std.testing.allocator.free(storage);
        var persistence = TaskPersistenceProbe{ .storage = storage };
        var wake_loop: fixture.LifecycleWakeLoop = .{};
        var configuration = productControlConfiguration();
        configuration.change_notifier = .{ .context = &wake_loop, .wake = fixture.LifecycleWakeLoop.wake };
        configuration.directories.canonical_user_home = home;
        configuration.task_persistence = persistence.capability();
        if (unknown) configuration.task_persistence.resolve_commit_fn = struct {
            fn resolve(context: ?*anyopaque, token: product_task.history.CommitToken) product_task.history.Commit {
                std.debug.assert(std.mem.eql(u8, &token, &(@as(product_task.history.CommitToken, @splat(23)))));
                const probe: *TaskPersistenceProbe = @ptrCast(@alignCast(context.?));
                if (probe.result == .outcome_unknown) return .outcome_unknown;
                return if (probe.store_on_outcome_unknown) .committed else .failed;
            }
        }.resolve;
        configuration.checkpoint_store = .{ .file_store = &checkpoint_store };
        const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 2, .max_sessions = 1, .event_ready_notifier = .{ .context = &wake_loop, .notify_fn = fixture.LifecycleWakeLoop.agentWake } });
        defer {
            shutdownTestComposition(runtime) catch unreachable;
            deinitTestComposition(runtime);
        }
        var workbench = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, .{
            .worker_count = 1,
            .queue_capacity = 2,
            .max_workspaces = 1,
            .max_tasks = 1,
            .max_runs_per_task = 3,
            .max_tools_per_run = 1,
        }, configuration);
        defer workbench.deinit();
        var blocker: Blocker = .{};
        defer blocker.released.store(true, .release);
        var close_blocker: Blocker = .{};
        defer {
            close_blocker.released.store(true, .release);
            fake_core.lock();
            fake_core.session_destroy_probe = null;
            fake_core.unlock();
        }
        defer fake_core.releaseControlled();
        defer fake_core.releaseControlledRestore();
        var vault: TaskModelsVault = .{};
        defer TaskModelsVault.delete(&vault, TaskModelsVault.slot) catch unreachable;
        try workbench.startCustomProviders(home, vault.port());
        defer workbench.stopCustomProviders();
        try installControlExecution(&workbench);
        installTwoModelCatalog(&workbench);
        const probe = try configureTaskRebindTarget(&workbench);
        const ready = workbench.modelsView().custom_providers[0];
        var input = productControlTaskInput();
        input.workspace_root = home;
        input.trust = .explicitly_trusted;
        input.approval_mode = .manual;
        const id = try workbench.createTask(input, try product_control.TestSupport.fixtureModelSelection(&workbench));
        const task = workbench.task_runtime.find(id).?;
        const old_epoch = task.durable.binding_epoch;
        const old_generation = task.durable.execution_generation;
        _ = try runPreparedTask(&workbench, id, .{ .text = "keep this original context" });
        var revision: u64 = undefined;

        try waitCheckpointRecord(&workbench, &persistence);
        for (0..2000) |_| {
            try wake_loop.drain(&workbench);
            if (!task.runtime.worker_leases.hasLive() and task.runtime.active_operation == .none) break;
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        }
        {
            try std.testing.expect(!task.runtime.worker_leases.hasLive());
            fake_core.setRestoredLogicalId(task.durable.checkpoint.?.session.logical_session_id);
            fake_core.lock();
            fake_core.restore_last_run_id = 1;
            fake_core.unlock();
            revision = try workbench.selectTaskModel(id, .{
                .expected_selection_revision = task.durable.model_intent.?.revision,
                .target = probe.model,
                .expected_source_generation = ready.source_generation,
                .expected_catalog_generation = ready.catalog_generation,
            });
            switch (failure) {
                .none => {},
                .restore => fake_core.forceNextCheckpointRestoreStatus(wire.STATUS_CHECKPOINT_CORRUPT),
                .set_model => {
                    fake_core.lock();
                    fake_core.forced_set_model_status = wire.STATUS_CORE_ERROR;
                    fake_core.unlock();
                },
                .target_export, .stale_intent => fake_core.armControlledRestore(),
                .shutdown => fake_core.armControlledRestoreAfterCreate(),
                .baseline_export => fake_core.forceNextCheckpointExportStatus(wire.STATUS_RESOURCE_LIMIT),
                .baseline_history => persistence.result = .failed,
                .baseline_unknown_old, .baseline_unknown_new, .baseline_unknown_shutdown => {
                    fake_core.setCheckpointGeneration(2);
                    fake_core.lock();
                    fake_core.checkpoint_payload = "distinct-baseline-witness";
                    fake_core.unlock();
                    persistence.store_on_outcome_unknown = failure != .baseline_unknown_old;
                    persistence.result = .outcome_unknown;
                },
                .original_close => fake_core.forceNextSessionDestroyStatus(wire.STATUS_CORE_ERROR),
                .original_close_start => workbench.task_runtime.test_rebind_close_start_failure = error.SystemResources,
                .target_queue => {
                    fake_core.lock();
                    fake_core.session_destroy_probe = .{ .context = &close_blocker, .observe_fn = Blocker.execute };
                    fake_core.unlock();
                },
                .candidate_close, .candidate_close_start => {
                    fake_core.lock();
                    fake_core.forced_set_model_status = wire.STATUS_CORE_ERROR;
                    fake_core.unlock();
                    fake_core.armControlledRestore();
                },
                .rollback, .rollback_queue => {
                    fake_core.forceNextCheckpointRestoreStatus(wire.STATUS_CHECKPOINT_CORRUPT);
                    fake_core.armControlledRestore();
                },
            }
            const attempt = try workbench.restoreTaskConversation(id, old_epoch);
            try std.testing.expect(attempt != 0);
            try std.testing.expectEqual(.restore, std.meta.activeTag(task.runtime.active_operation));
        }
        if (failure == .target_queue) {
            for (0..5000) |_| {
                try wake_loop.drain(&workbench);
                if (close_blocker.entered.load(.acquire)) break;
                try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
            } else return error.CloseDidNotStart;
            try workbench.executor.enqueue(.{ .identity = &blocker, .context = &blocker, .execute_fn = Blocker.execute, .cancel_fn = Blocker.noop });
            for (0..5000) |_| {
                if (blocker.entered.load(.acquire)) break;
                try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
            } else return error.BlockerDidNotStart;
            try workbench.executor.enqueue(.{ .identity = &configuration, .context = &blocker, .execute_fn = Blocker.noop, .cancel_fn = Blocker.noop });
            try workbench.executor.enqueue(.{ .identity = &persistence, .context = &blocker, .execute_fn = Blocker.noop, .cancel_fn = Blocker.noop });
            close_blocker.released.store(true, .release);
            for (0..5000) |_| {
                if (task.runtime.close_completion.load(.acquire) != .running and wake_loop.pending.load(.acquire) != 0) break;
                try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
            } else return error.CloseDidNotFinish;
            // The close wake must consume both immediate enqueue failures:
            // target restore and the one permitted original restore attempt.
            try wake_loop.drain(&workbench);
            try std.testing.expect(task.runtime.restore_job == null);
            try std.testing.expect(!task.runtime.worker_leases.hasLive());
            try std.testing.expectEqual(.none, task.runtime.active_operation);
            try std.testing.expectEqual(.runtime_busy, task.runtime.last_restore_failure.?);
        }
        var rejected_unknown_blob: ?product_task.checkpoint_store.Identity = null;
        if (unknown) {
            const original_blob = task.durable.checkpoint.?.blob;
            for (0..5000) |_| {
                try wake_loop.drain(&workbench);
                if (task.runtime.restore_job.?.binding_commit == .outcome_unknown) break;
                try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
            } else return error.TestUnexpectedResult;
            const baseline_blob = task.runtime.restore_job.?.rebind.?.baseline.?.blob;
            if (failure == .baseline_unknown_old) rejected_unknown_blob = baseline_blob;
            try std.testing.expect(!std.meta.eql(original_blob, baseline_blob));
            for (0..10) |_| try wake_loop.drain(&workbench);
            try checkpoint_store.verify(original_blob);
            try checkpoint_store.verify(baseline_blob);
            try std.testing.expectEqual(old_epoch, task.durable.binding_epoch);
            try std.testing.expect(task.runtime.hasAttachedSession());
            fake_core.lock();
            const before_readback_restores = fake_core.checkpoint_restores;
            const before_readback_destroyed = fake_core.session_destroyed;
            fake_core.unlock();
            try std.testing.expectEqual(@as(usize, 0), before_readback_restores);
            try std.testing.expectEqual(@as(usize, 0), before_readback_destroyed);
            if (failure == .baseline_unknown_shutdown) {
                workbench.shutdownExecutor();
                try std.testing.expect(task.runtime.restore_job == null);
                try std.testing.expect(!task.runtime.worker_leases.hasLive());
                try std.testing.expectEqual(old_epoch, task.durable.binding_epoch);
                try std.testing.expectEqual(.outcome_unknown, workbench.task_persistence_health);
                try checkpoint_store.verify(original_blob);
                try checkpoint_store.verify(baseline_blob);
                continue;
            }
            // Only a readback of the exact candidate may settle the result.
            persistence.result = .committed;
            try std.testing.expectEqual(.outcome_unknown, workbench.recoverTaskHistory(workbench.currentRevision()));
        }
        if (failure == .target_export or failure == .stale_intent or failure == .candidate_close or failure == .candidate_close_start or failure == .rollback or failure == .rollback_queue or failure == .shutdown) {
            for (0..5000) |_| {
                try wake_loop.drain(&workbench);
                fake_core.lock();
                const entered = fake_core.restore_entered;
                fake_core.unlock();
                if (entered) break;
                try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
            } else return error.TestUnexpectedResult;
            // Baseline export is already confirmed and the original route
            // released. Refuse only the target's new checkpoint export.
            if (failure == .shutdown) {
                const Release = struct {
                    cancellation: *const std.atomic.Value(bool),
                    observed: bool = false,
                    fn run(self: *@This()) void {
                        for (0..5000) |_| {
                            if (self.cancellation.load(.acquire)) {
                                self.observed = true;
                                break;
                            }
                            std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch {};
                        }
                        fake_core.releaseControlledRestore();
                    }
                };
                var context = Release{ .cancellation = &task.runtime.restore_job.?.cancellation };
                const thread = try std.Thread.spawn(.{}, Release.run, .{&context});
                // Composition and Models stay on Main. The helper only releases
                // the synthetic Core barrier after observing cancellation.
                workbench.shutdownExecutor();
                thread.join();
                try std.testing.expect(context.observed);
                try std.testing.expect(task.runtime.restore_job == null);
                try std.testing.expect(!task.runtime.worker_leases.hasLive());
                try std.testing.expectEqual(old_epoch, task.durable.binding_epoch);
                try std.testing.expectEqual(old_generation, task.durable.execution_generation);
                try std.testing.expect(task.durable.runs[1] == null);
                try checkpoint_store.verify(task.durable.checkpoint.?.blob);
                fake_core.lock();
                const shutdown_restores = fake_core.checkpoint_restores;
                const shutdown_runs = fake_core.run_calls;
                fake_core.unlock();
                try std.testing.expectEqual(@as(usize, 1), shutdown_restores);
                try std.testing.expectEqual(@as(usize, 1), shutdown_runs);
                continue;
            }
            switch (failure) {
                .target_export => fake_core.forceNextCheckpointExportStatus(wire.STATUS_RESOURCE_LIMIT),
                .stale_intent => revision = try workbench.selectTaskModel(id, .{
                    .expected_selection_revision = revision,
                    .target = probe.model,
                    .expected_source_generation = ready.source_generation,
                    .expected_catalog_generation = ready.catalog_generation,
                }),
                .candidate_close => fake_core.forceNextSessionDestroyStatus(wire.STATUS_CORE_ERROR),
                .candidate_close_start => workbench.task_runtime.test_rebind_close_start_failure = error.SystemResources,
                .rollback => fake_core.forceNextCheckpointRestoreStatus(wire.STATUS_CORE_ERROR),
                .rollback_queue => {
                    try workbench.executor.enqueue(.{ .identity = &blocker, .context = &blocker, .execute_fn = Blocker.execute, .cancel_fn = Blocker.noop });
                    try workbench.executor.enqueue(.{ .identity = &persistence, .context = &blocker, .execute_fn = Blocker.noop, .cancel_fn = Blocker.noop });
                },
                else => unreachable,
            }
            fake_core.releaseControlledRestore();
            if (failure == .rollback_queue) {
                // The target worker finishes and the blocker takes its slot.
                // Fill the freed queue slot before consuming the target result,
                // so the original-configuration enqueue fails synchronously.
                for (0..5000) |_| {
                    if (blocker.entered.load(.acquire)) break;
                    try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
                } else return error.BlockerDidNotStart;
                try workbench.executor.enqueue(.{ .identity = &configuration, .context = &blocker, .execute_fn = Blocker.noop, .cancel_fn = Blocker.noop });
                // The target has completed and the fallback cannot enqueue.
                // One actual wake must settle both results; later queued wakes
                // must not conceal a falsely reported finished transition.
                try std.testing.expect(wake_loop.pending.load(.acquire) != 0);
                try wake_loop.drain(&workbench);
                try std.testing.expect(task.runtime.restore_job == null);
                try std.testing.expect(!task.runtime.worker_leases.hasLive());
            }
        }
        for (0..5000) |_| {
            try wake_loop.drain(&workbench);
            if (task.runtime.restore_job == null) break;
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        }
        if (task.runtime.restore_job) |job| std.debug.print("rebind phase={s} state={s} commit={s} outcome={s}\n", .{ @tagName(job.rebind.?.phase), @tagName(job.state.load(.acquire)), @tagName(job.binding_commit), @tagName(job.outcome) });
        try std.testing.expect(task.runtime.restore_job == null);
        if (rejected_unknown_blob) |blob| {
            for (0..5000) |_| {
                try wake_loop.drain(&workbench);
                checkpoint_store.verify(blob) catch |err| {
                    try std.testing.expectEqual(error.BlobMissing, err);
                    break;
                };
                try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
            } else return error.TestUnexpectedResult;
        }
        if (failure == .baseline_export or failure == .baseline_history or failure == .baseline_unknown_old or failure == .original_close or failure == .original_close_start or failure == .target_queue or failure == .candidate_close or failure == .candidate_close_start or failure == .rollback or failure == .rollback_queue) {
            try std.testing.expectEqual(old_epoch, task.durable.binding_epoch);
            try std.testing.expectEqual(old_generation, task.durable.execution_generation);
            try std.testing.expectEqualStrings("fixture-model", task.durable.execution_model);
            try std.testing.expect(task.durable.runs[1] == null);
            try std.testing.expect(task.runtime.last_restore_failure != null);
            try std.testing.expect(!task.runtime.worker_leases.hasLive());
            try checkpoint_store.verify(task.durable.checkpoint.?.blob);
            fake_core.lock();
            const restores = fake_core.checkpoint_restores;
            const runs = fake_core.run_calls;
            fake_core.unlock();
            try std.testing.expectEqual(@as(usize, if (failure == .rollback) 2 else if (failure == .candidate_close or failure == .candidate_close_start or failure == .rollback_queue) 1 else 0), restores);
            try std.testing.expectEqual(@as(usize, 1), runs);
            if (failure == .original_close or failure == .candidate_close or failure == .candidate_close_start) {
                try std.testing.expect(task.runtime.close_failed);
            } else if (failure == .rollback or failure == .rollback_queue or failure == .target_queue) {
                try std.testing.expect(!task.runtime.hasAttachedSession());
            } else {
                try std.testing.expect(task.runtime.hasAttachedSession());
                try std.testing.expectEqualStrings("fixture-secret", task.runtime.executionConst().?.secret);
            }
            // Settling again cannot restart a failed switch or replay input.
            for (0..10) |_| try wake_loop.drain(&workbench);
            fake_core.lock();
            const settled_restores = fake_core.checkpoint_restores;
            fake_core.unlock();
            try std.testing.expectEqual(restores, settled_restores);
            persistence.result = .committed;
            continue;
        }
        try std.testing.expect(task.runtime.hasAttachedSession());
        try std.testing.expect(!task.runtime.worker_leases.hasLive());
        try std.testing.expectEqualStrings("fixture-model", task.durable.runs[0].?.execution_model);
        try std.testing.expectEqualStrings("other-model", task.durable.model_intent.?.model_id);
        try std.testing.expectEqual(revision, task.durable.model_intent.?.revision);
        try std.testing.expectEqualStrings(TaskModelsVault.slot, workbench.modelsView().default_selection.?.source_id);
        const execution = task.runtime.executionConst().?;
        if (!reject_target and task.durable.binding_epoch == old_epoch) std.debug.print("unexpected rollback: failure={s} model={s} exports={d} restores={d}\n", .{
            if (task.runtime.last_restore_failure) |reason| @tagName(reason) else "none", task.durable.execution_model, fake_core.checkpoint_exports, fake_core.checkpoint_restores,
        });
        try std.testing.expectEqual(old_epoch + @as(u64, if (reject_target) 0 else 1), task.durable.binding_epoch);
        try std.testing.expectEqual(task.durable.binding_epoch, task.durable.checkpoint.?.anchor.binding_epoch);
        try std.testing.expectEqualStrings(if (reject_target) "fixture-model" else "other-model", task.durable.execution_model);
        try std.testing.expectEqualStrings(task.durable.execution_model, task.durable.checkpoint.?.session.model);
        try std.testing.expectEqual(if (reject_target) models_contract.Protocol.anthropic_messages else models_contract.Protocol.openai_responses, execution.protocol);
        try std.testing.expectEqualStrings(if (reject_target) "fixture-secret" else "other-secret", execution.secret);
        try std.testing.expectEqualStrings(if (reject_target) models_contract.metask_anthropic_messages_url else "https://other.example.com/v1/responses", execution.base_url);
        fake_core.lock();
        const run_calls = fake_core.run_calls;
        const restore_calls = fake_core.checkpoint_restores;
        const destroyed = fake_core.session_destroyed;
        fake_core.unlock();
        try std.testing.expectEqual(@as(usize, 1), run_calls);
        try std.testing.expectEqual(@as(usize, if (reject_target) 2 else 1), restore_calls);
        try std.testing.expectEqual(@as(usize, if (failure == .set_model or failure == .target_export or failure == .stale_intent) 2 else 1), destroyed);
        if (reject_target) {
            try std.testing.expectEqual(old_generation, task.durable.execution_generation);
            try std.testing.expect(execution.model_intent_revision != revision);
            try std.testing.expect(task.runtime.last_restore_failure != null);
        } else {
            try std.testing.expect(task.durable.execution_generation != old_generation);
            try std.testing.expectEqual(revision, execution.model_intent_revision);
            try std.testing.expect(task.runtime.last_restore_failure == null);
            try std.testing.expectEqualStrings("custom_provider:" ++ TaskModelsVault.slot, execution.provider_id);
            {
                const next_run = try runPreparedTask(&workbench, id, .{ .text = "continue on the selected connection" });
                try std.testing.expectEqual(@as(u64, 2), next_run);
            }
            for (0..2000) |_| {
                try wake_loop.drain(&workbench);
                if (task.durable.runs[1]) |*run| if (task_state.productTerminalFacts(run) != null and run.event_stream_finalized) break;
                try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
            }
            try std.testing.expectEqualStrings("other-model", task.durable.runs[1].?.execution_model);
        }
    }
}

test "Task model rebind candidate close releases an earlier shared writer waiter in the same wake" {
    const Barrier = struct {
        persistence: TaskPersistenceProbe,
        hold_writer: std.atomic.Value(bool) = .init(false),
        writer_entered: std.atomic.Value(bool) = .init(false),
        writer_released: std.atomic.Value(bool) = .init(false),
        hold_close: std.atomic.Value(bool) = .init(false),
        close_entered: std.atomic.Value(bool) = .init(false),
        close_released: std.atomic.Value(bool) = .init(false),

        fn save(context: ?*anyopaque, input: *product_task.history.Candidate) product_task.history.Commit {
            input.token = @splat(23);
            const bytes = product_task.history.encodeAlloc(std.testing.allocator, input.value, input.preserved, product_control.persistenceLimits(.{}, 16)) catch return .failed;
            defer std.testing.allocator.free(bytes);
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (self.hold_writer.swap(false, .acq_rel)) {
                self.writer_entered.store(true, .release);
                while (!self.writer_released.load(.acquire))
                    std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch {};
            }
            return TaskPersistenceProbe.commit(&self.persistence, input);
        }

        fn close(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (!self.hold_close.load(.acquire)) return;
            self.close_entered.store(true, .release);
            while (!self.close_released.load(.acquire))
                std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch {};
        }
    };
    fake_core.reset();
    fake_core.setCheckpointGeneration(1);
    var wake_loop: fixture.LifecycleWakeLoop = .{};
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 2, .max_sessions = 2, .event_ready_notifier = .{ .context = &wake_loop, .notify_fn = fixture.LifecycleWakeLoop.agentWake } });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);
    var checkpoints = try product_task.checkpoint_store.FileStore.init(std.testing.io, home);
    defer checkpoints.deinit();
    const bytes = try std.testing.allocator.alloc(u8, product_task.history.max_store_bytes);
    defer std.testing.allocator.free(bytes);
    var barrier = Barrier{ .persistence = .{ .storage = bytes } };
    var configuration = productControlConfiguration();
    configuration.change_notifier = .{ .context = &wake_loop, .wake = fixture.LifecycleWakeLoop.wake };
    configuration.directories.canonical_user_home = home;
    configuration.task_persistence = .{ .context = &barrier, .enabled = true, .commit_fn = Barrier.save, .confirmed_commit_fn = Barrier.save };
    configuration.checkpoint_store = .{ .file_store = &checkpoints };
    var workbench = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, .{ .worker_count = 1, .queue_capacity = 2, .max_workspaces = 1, .max_tasks = 2, .max_runs_per_task = 2 }, configuration);
    defer workbench.deinit();
    defer {
        barrier.writer_released.store(true, .release);
        barrier.close_released.store(true, .release);
        fake_core.releaseControlledRestore();
        fake_core.lock();
        fake_core.session_destroy_probe = null;
        fake_core.unlock();
    }
    var vault: TaskModelsVault = .{};
    defer TaskModelsVault.delete(&vault, TaskModelsVault.slot) catch unreachable;
    try workbench.startCustomProviders(home, vault.port());
    defer workbench.stopCustomProviders();
    try installControlExecution(&workbench);
    installTwoModelCatalog(&workbench);
    const target = try configureTaskRebindTarget(&workbench);
    const ready = workbench.modelsView().custom_providers[0];
    var input = productControlTaskInput();
    input.workspace_root = home;
    input.trust = .explicitly_trusted;
    input.approval_mode = .manual;
    const waiter_id = try workbench.createTask(input, try product_control.TestSupport.fixtureModelSelection(&workbench));
    const waiter = workbench.task_runtime.find(waiter_id).?;
    try std.testing.expect(try product_control.TestSupport.retryTaskSessionClose(&workbench, waiter_id));
    for (0..5000) |_| {
        try wake_loop.drain(&workbench);
        if (waiter.runtime.attachment == .detached and waiter.runtime.close_thread == null) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    } else return error.WaiterDidNotDetach;
    const id = try workbench.createTask(input, try product_control.TestSupport.fixtureModelSelection(&workbench));
    const task = workbench.task_runtime.find(id).?;
    _ = try runPreparedTask(&workbench, id, .{ .text = "Preserve this context while changing connection." });
    try waitCheckpointRecord(&workbench, &barrier.persistence);
    for (0..5000) |_| {
        try wake_loop.drain(&workbench);
        if (task.runtime.active_operation == .none and !task.runtime.worker_leases.hasLive()) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    } else return error.BaselineDidNotSettle;
    fake_core.setRestoredLogicalId(task.durable.checkpoint.?.session.logical_session_id);
    fake_core.setRestoreHistory(1, 0);
    _ = try workbench.selectTaskModel(id, .{
        .expected_selection_revision = task.durable.model_intent.?.revision,
        .target = target.model,
        .expected_source_generation = ready.source_generation,
        .expected_catalog_generation = ready.catalog_generation,
    });
    fake_core.armControlledRestore();
    _ = try workbench.restoreTaskConversation(id, task.durable.binding_epoch);
    for (0..5000) |_| {
        try wake_loop.drain(&workbench);
        fake_core.lock();
        const entered = fake_core.restore_entered;
        fake_core.unlock();
        if (entered) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    } else return error.TargetRestoreDidNotStart;
    barrier.hold_writer.store(true, .release);
    fake_core.releaseControlledRestore();
    for (0..5000) |_| {
        try wake_loop.drain(&workbench);
        if (barrier.writer_entered.load(.acquire)) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    } else return error.TargetWriterDidNotStart;
    try std.testing.expectEqual(.pending, task.runtime.restore_job.?.binding_commit);
    _ = try workbench.restoreTaskConversation(waiter_id, waiter.durable.binding_epoch);
    for (0..5000) |_| {
        try wake_loop.drain(&workbench);
        if (waiter.runtime.restore_job.?.completionReady() and wake_loop.pending.load(.acquire) == 0) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    } else return error.WaiterDidNotComplete;
    try std.testing.expectEqual(.not_started, waiter.runtime.restore_job.?.binding_commit);
    // Cancellation during the confirmed write must adopt durable truth and
    // reject the Session. Its failed close is the final barrier release.
    try workbench.stopTask(id);
    barrier.hold_close.store(true, .release);
    fake_core.lock();
    fake_core.session_destroy_probe = .{ .context = &barrier, .observe_fn = Barrier.close };
    fake_core.unlock();
    fake_core.failNextSessionDestroy();
    barrier.writer_released.store(true, .release);
    for (0..5000) |_| {
        try wake_loop.drain(&workbench);
        if (barrier.close_entered.load(.acquire) and wake_loop.pending.load(.acquire) == 0) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    } else return error.CandidateCloseDidNotStart;
    try std.testing.expectEqual(.closing_candidate, task.runtime.restore_job.?.rebind.?.phase);
    try std.testing.expectEqual(.committed, task.runtime.restore_job.?.binding_commit);
    barrier.close_released.store(true, .release);
    for (0..5000) |_| {
        if (task.runtime.close_completion.load(.acquire) != .running and wake_loop.pending.load(.acquire) != 0) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    } else return error.CandidateCloseDidNotFinish;
    try wake_loop.drain(&workbench);
    try std.testing.expect(task.runtime.restore_job == null);
    try std.testing.expectEqual(.none, task.runtime.active_operation);
    try std.testing.expect(!task.runtime.worker_leases.hasLive());
    try std.testing.expect(task.runtime.close_failed);
    try std.testing.expectEqual(.session_poisoned, task.runtime.liveConst().?.health);
    try std.testing.expectEqual(@as(usize, 0), task.runtime.executionConst().?.secret.len);
    try std.testing.expectEqual(@as(u64, 2), task.durable.binding_epoch);
    if (waiter.runtime.restore_job) |job|
        try std.testing.expect(job.binding_commit != .not_started);
    for (0..5000) |_| {
        try wake_loop.drain(&workbench);
        if (waiter.runtime.restore_job == null and !waiter.runtime.worker_leases.hasLive()) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    } else return error.WaiterDidNotSettle;
    try std.testing.expect(waiter.runtime.hasAttachedSession());
    try std.testing.expectEqual(.none, waiter.runtime.active_operation);
    fake_core.lock();
    const runs = fake_core.run_calls;
    const restores = fake_core.checkpoint_restores;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), runs);
    try std.testing.expectEqual(@as(usize, 1), restores);
}

test "Task model rebind shutdown settles completed and running close workers without later wakes" {
    const CloseBarrier = struct {
        stop_at: usize,
        calls: std.atomic.Value(usize) = .init(0),
        entered: std.atomic.Value(bool) = .init(false),
        join_entered: std.atomic.Value(bool) = .init(false),
        released: std.atomic.Value(bool) = .init(false),

        fn observeJoin(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.join_entered.store(true, .release);
        }

        fn observe(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.calls.fetchAdd(1, .acq_rel) + 1 != self.stop_at) return;
            self.entered.store(true, .release);
            while (!self.released.load(.acquire))
                std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch {};
        }
    };
    const ShutdownRelease = struct {
        barrier: *CloseBarrier,
        cancellation: *const std.atomic.Value(bool),
        observed: bool = false,

        fn run(self: *@This()) void {
            for (0..5000) |_| {
                if (self.barrier.join_entered.load(.acquire)) {
                    self.observed = self.cancellation.load(.acquire);
                    break;
                }
                std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch {};
            }
            self.barrier.released.store(true, .release);
        }
    };
    for ([_]bool{ false, true }) |candidate| for ([_]bool{ false, true }) |completed| {
        fake_core.reset();
        fake_core.setCheckpointGeneration(1);
        var wake_loop: fixture.LifecycleWakeLoop = .{};
        const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 2, .max_sessions = 1, .event_ready_notifier = .{ .context = &wake_loop, .notify_fn = fixture.LifecycleWakeLoop.agentWake } });
        defer {
            shutdownTestComposition(runtime) catch unreachable;
            deinitTestComposition(runtime);
        }
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        defer std.testing.allocator.free(home);
        var checkpoints = try product_task.checkpoint_store.FileStore.init(std.testing.io, home);
        defer checkpoints.deinit();
        const bytes = try std.testing.allocator.alloc(u8, product_task.history.max_store_bytes);
        defer std.testing.allocator.free(bytes);
        var persistence = TaskPersistenceProbe{ .storage = bytes };
        var configuration = productControlConfiguration();
        configuration.change_notifier = .{ .context = &wake_loop, .wake = fixture.LifecycleWakeLoop.wake };
        configuration.directories.canonical_user_home = home;
        configuration.task_persistence = persistence.capability();
        configuration.checkpoint_store = .{ .file_store = &checkpoints };
        var workbench = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, .{ .worker_count = 1, .queue_capacity = 2, .max_workspaces = 1, .max_tasks = 1, .max_runs_per_task = 3 }, configuration);
        defer workbench.deinit();
        var barrier = CloseBarrier{ .stop_at = if (candidate) 2 else 1 };
        workbench.task_runtime.test_rebind_close_join_observer = .{ .context = &barrier, .observe_fn = CloseBarrier.observeJoin };
        defer {
            barrier.released.store(true, .release);
            fake_core.lock();
            fake_core.session_destroy_probe = null;
            fake_core.unlock();
        }
        var vault: TaskModelsVault = .{};
        defer TaskModelsVault.delete(&vault, TaskModelsVault.slot) catch unreachable;
        try workbench.startCustomProviders(home, vault.port());
        defer workbench.stopCustomProviders();
        try installControlExecution(&workbench);
        installTwoModelCatalog(&workbench);
        const target = try configureTaskRebindTarget(&workbench);
        const ready = workbench.modelsView().custom_providers[0];
        var input = productControlTaskInput();
        input.workspace_root = home;
        input.trust = .explicitly_trusted;
        input.approval_mode = .manual;
        const id = try workbench.createTask(input, try product_control.TestSupport.fixtureModelSelection(&workbench));
        const task = workbench.task_runtime.find(id).?;
        const epoch = task.durable.binding_epoch;
        _ = try runPreparedTask(&workbench, id, .{ .text = "Keep this original context." });
        try waitCheckpointRecord(&workbench, &persistence);
        for (0..5000) |_| {
            try wake_loop.drain(&workbench);
            if (task.runtime.active_operation == .none and !task.runtime.worker_leases.hasLive()) break;
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        } else return error.BaselineDidNotSettle;
        fake_core.setRestoredLogicalId(task.durable.checkpoint.?.session.logical_session_id);
        fake_core.setRestoreHistory(1, 0);
        _ = try workbench.selectTaskModel(id, .{
            .expected_selection_revision = task.durable.model_intent.?.revision,
            .target = target.model,
            .expected_source_generation = ready.source_generation,
            .expected_catalog_generation = ready.catalog_generation,
        });
        fake_core.lock();
        fake_core.session_destroy_probe = .{ .context = &barrier, .observe_fn = CloseBarrier.observe };
        if (candidate) fake_core.forced_set_model_status = wire.STATUS_CORE_ERROR;
        fake_core.unlock();
        _ = try workbench.restoreTaskConversation(id, epoch);
        for (0..5000) |_| {
            try wake_loop.drain(&workbench);
            if (barrier.entered.load(.acquire)) break;
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        } else return error.CloseDidNotStart;
        try std.testing.expectEqual(@as(@TypeOf(task.runtime.restore_job.?.rebind.?.phase), if (candidate) .closing_candidate else .closing_original), task.runtime.restore_job.?.rebind.?.phase);
        try std.testing.expectEqual(@as(usize, 1), task.runtime.worker_leases.liveCount());
        try std.testing.expectEqual(.running, task.runtime.close_completion.load(.acquire));
        if (completed) {
            barrier.released.store(true, .release);
            // Observe completion without consuming its queued wake.
            for (0..5000) |_| {
                if (task.runtime.close_completion.load(.acquire) != .running) break;
                try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
            } else return error.CloseDidNotFinish;
            workbench.shutdownExecutor();
        } else {
            var release = ShutdownRelease{ .barrier = &barrier, .cancellation = &task.runtime.restore_job.?.cancellation };
            const thread = try std.Thread.spawn(.{}, ShutdownRelease.run, .{&release});
            workbench.shutdownExecutor();
            thread.join();
            try std.testing.expect(release.observed);
        }
        // No event-loop turn follows shutdownExecutor before these assertions.
        try std.testing.expect(task.runtime.restore_job == null);
        try std.testing.expectEqual(.none, task.runtime.active_operation);
        try std.testing.expect(!task.runtime.worker_leases.hasLive());
        try std.testing.expect(task.runtime.close_thread == null);
        try std.testing.expectEqual(epoch, task.durable.binding_epoch);
        try std.testing.expect(task.durable.runs[1] == null);
        fake_core.lock();
        const restores = fake_core.checkpoint_restores;
        const runs = fake_core.run_calls;
        const destroyed = fake_core.session_destroyed;
        fake_core.unlock();
        try std.testing.expectEqual(@as(usize, if (candidate) 1 else 0), restores);
        try std.testing.expectEqual(@as(usize, 1), runs);
        try std.testing.expectEqual(@as(usize, if (candidate) 2 else 1), destroyed);
    };
}

test "detached Task restores its committed target across restart without a global default" {
    for ([_]bool{ false, true }) |has_history| for ([_]bool{ false, true }) |target_available| {
        fake_core.reset();
        fake_core.setCheckpointGeneration(1);
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        defer std.testing.allocator.free(home);
        var store = try product_task.checkpoint_store.FileStore.init(std.testing.io, home);
        defer store.deinit();
        const storage = try std.testing.allocator.alloc(u8, product_task.history.max_store_bytes);
        defer std.testing.allocator.free(storage);
        var persistence = TaskPersistenceProbe{ .storage = storage };
        var configuration = productControlConfiguration();
        configuration.directories.canonical_user_home = home;
        configuration.task_persistence = persistence.capability();
        configuration.checkpoint_store = .{ .file_store = &store };
        const limits: product_control.Limits = .{ .worker_count = 1, .queue_capacity = 2, .max_workspaces = 1, .max_tasks = 1, .max_runs_per_task = 3, .max_tools_per_run = 1 };
        const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 2, .max_sessions = 1 });
        defer {
            shutdownTestComposition(runtime) catch unreachable;
            deinitTestComposition(runtime);
        }
        var vault: TaskModelsVault = .{};
        defer TaskModelsVault.delete(&vault, TaskModelsVault.slot) catch unreachable;
        var first = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, limits, configuration);
        var first_live = true;
        defer if (first_live) {
            first.stopCustomProviders();
            first.deinit();
        };
        try first.startCustomProviders(home, vault.port());
        try installControlExecution(&first);
        installTwoModelCatalog(&first);
        const probe = try configureTaskRebindTarget(&first);
        const ready = first.modelsView().custom_providers[0];
        var input = productControlTaskInput();
        input.workspace_root = home;
        input.trust = .explicitly_trusted;
        input.approval_mode = .manual;
        const id = try first.createTask(input, try product_control.TestSupport.fixtureModelSelection(&first));
        if (has_history) {
            _ = try runPreparedTask(&first, id, .{ .text = "original context survives a different protocol" });
            try waitCheckpointRecord(&first, &persistence);
        }
        const task = first.task_runtime.findConst(id).?;
        const old_epoch = task.durable.binding_epoch;
        const workspace_id = task.durable.workspace_id;
        const selected_revision = try first.selectTaskModel(id, .{
            .target = probe.model,
            .expected_selection_revision = task.durable.model_intent.?.revision,
            .expected_source_generation = ready.source_generation,
            .expected_catalog_generation = ready.catalog_generation,
        });
        if (has_history) {
            fake_core.setRestoredLogicalId(task.durable.checkpoint.?.session.logical_session_id);
            fake_core.lock();
            fake_core.restore_last_run_id = 1;
            fake_core.unlock();
        }
        const history = try std.testing.allocator.dupe(u8, storage[0..persistence.len]);
        defer std.testing.allocator.free(history);
        first.shutdownExecutor();
        first.stopCustomProviders();
        first.deinit();
        first_live = false;
        configuration.task_persistence = persistence.capabilityRestored(history);
        var restored = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, limits, configuration);
        defer restored.deinit();
        try restored.startCustomProviders(home, vault.port());
        defer restored.stopCustomProviders();
        _ = try configureTaskRebindTarget(&restored);
        try std.testing.expect(restored.clearCustomProviderDefault().accepted);
        try std.testing.expect(restored.modelsView().default_selection == null);
        try std.testing.expect(restored.newTaskAdmissionView().available);
        try std.testing.expectEqual(workspace_id, try restored.openWorkspace(input));
        const recovered = restored.task_runtime.findConst(id).?;
        try std.testing.expectEqual(selected_revision, recovered.durable.model_intent.?.revision);
        try std.testing.expectEqual(.detached, std.meta.activeTag(recovered.runtime.attachment));
        if (!target_available) {
            const current = restored.modelsView().custom_providers[0];
            try std.testing.expect(restored.submitCustomProviderCommand(.{ .remove_custom_model = .{
                .selection = probe.model,
                .expected_provider_revision = current.provider_revision,
                .expected_catalog_generation = current.catalog_generation,
            } }).accepted);
            try std.testing.expectError(error.ExecutionUnavailable, restored.restoreTaskConversation(id, old_epoch));
            try std.testing.expectEqual(old_epoch, recovered.durable.binding_epoch);
            try std.testing.expectEqual(.detached, std.meta.activeTag(recovered.runtime.attachment));
            try std.testing.expectEqualStrings("other-model", recovered.durable.model_intent.?.model_id);
            continue;
        }
        _ = try restored.restoreTaskConversation(id, old_epoch);
        for (0..5000) |_| {
            try restored.drainAgentEvents();
            restored.syncLifecycle();
            if (recovered.runtime.restore_job == null and !recovered.runtime.worker_leases.hasLive()) break;
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        }
        if (recovered.runtime.last_restore_failure) |failure| std.debug.print("detached target failed: {s}\n", .{@tagName(failure)});
        try std.testing.expect(recovered.runtime.hasAttachedSession());
        try std.testing.expectEqual(old_epoch + 1, recovered.durable.binding_epoch);
        try std.testing.expectEqualStrings("other-model", recovered.durable.execution_model);
        if (has_history) {
            try std.testing.expectEqualStrings("other-model", recovered.durable.checkpoint.?.session.model);
        } else try std.testing.expect(recovered.durable.checkpoint == null);
        const execution = recovered.runtime.executionConst().?;
        try std.testing.expectEqual(selected_revision, execution.model_intent_revision);
        try std.testing.expectEqualStrings("other-secret", execution.secret);
        try std.testing.expectEqualStrings("https://other.example.com/v1/responses", execution.base_url);
        try std.testing.expectEqual(models_contract.Protocol.openai_responses, execution.protocol);
        if (has_history) try std.testing.expectEqual(models_contract.Protocol.anthropic_messages, recovered.durable.runs[0].?.execution_protocol);
        const run_id = try runPreparedTask(&restored, id, .{ .text = "continue using my selected target" });
        try std.testing.expectEqual(@as(u64, if (has_history) 2 else 1), run_id);
        try std.testing.expect(restored.modelsView().default_selection == null);
    };
}

test "rebind approval checkpoint survives a crash after the next same-connection model Run is admitted" {
    fake_core.reset();
    fake_core.setCheckpointGeneration(1);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);
    var store = try product_task.checkpoint_store.FileStore.init(std.testing.io, home);
    defer store.deinit();
    const storage = try std.testing.allocator.alloc(u8, product_task.history.max_store_bytes);
    defer std.testing.allocator.free(storage);
    var persistence = TaskPersistenceProbe{ .storage = storage };
    var configuration = productControlConfiguration();
    configuration.directories.canonical_user_home = home;
    configuration.task_persistence = persistence.capability();
    configuration.checkpoint_store = .{ .file_store = &store };
    const limits: product_control.Limits = .{ .worker_count = 1, .queue_capacity = 2, .max_workspaces = 1, .max_tasks = 1, .max_runs_per_task = 3, .max_tools_per_run = 1 };
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 2, .max_sessions = 1 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var vault: TaskModelsVault = .{};
    defer TaskModelsVault.delete(&vault, TaskModelsVault.slot) catch unreachable;
    var first = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, limits, configuration);
    var first_live = true;
    defer if (first_live) {
        fake_core.releaseControlled();
        first.stopCustomProviders();
        first.deinit();
    };
    try first.startCustomProviders(home, vault.port());
    try installControlExecution(&first);
    installTwoModelCatalog(&first);
    const target = try configureTaskRebindTarget(&first);
    const next = try configureTaskRebindModel(&first, "next-model");
    var input = productControlTaskInput();
    input.workspace_root = home;
    input.trust = .explicitly_trusted;
    input.approval_mode = .manual;
    const id = try first.createTask(input, try product_control.TestSupport.fixtureModelSelection(&first));
    const task = first.task_runtime.find(id).?;
    const workspace_id = task.durable.workspace_id;
    _ = try runPreparedTask(&first, id, .{ .text = "original context survives the crash" });
    try waitCheckpointRecord(&first, &persistence);
    for (0..2000) |_| {
        first.syncLifecycle();
        if (!task.runtime.worker_leases.hasLive() and task.runtime.active_operation == .none) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }

    // Switching connection exports an approval-anchored target checkpoint.
    var ready = first.modelsView().custom_providers[0];
    _ = try first.selectTaskModel(id, .{
        .expected_selection_revision = task.durable.model_intent.?.revision,
        .target = target.model,
        .expected_source_generation = ready.source_generation,
        .expected_catalog_generation = ready.catalog_generation,
    });
    fake_core.setRestoredLogicalId(task.durable.checkpoint.?.session.logical_session_id);
    fake_core.lock();
    fake_core.restore_last_run_id = 1;
    fake_core.unlock();
    const old_epoch = task.durable.binding_epoch;
    _ = try first.restoreTaskConversation(id, old_epoch);
    for (0..5000) |_| {
        try first.drainAgentEvents();
        first.syncLifecycle();
        if (task.runtime.restore_job == null and !task.runtime.worker_leases.hasLive()) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    if (task.runtime.last_restore_failure) |failure| std.debug.print("rebind failed: {s}\n", .{@tagName(failure)});
    try std.testing.expect(task.runtime.hasAttachedSession());
    try std.testing.expectEqual(old_epoch + 1, task.durable.binding_epoch);
    try std.testing.expectEqualStrings("other-model", task.durable.execution_model);
    try std.testing.expect(task.durable.checkpoint.?.anchor.terminal == .approval);
    try std.testing.expectEqualStrings("other-model", task.durable.checkpoint.?.session.model);

    // A same-connection selection is installed by Run admission, which
    // persists the new Task model before that Run can export a checkpoint.
    ready = first.modelsView().custom_providers[0];
    _ = try first.selectTaskModel(id, .{
        .expected_selection_revision = task.durable.model_intent.?.revision,
        .target = next.model,
        .expected_source_generation = ready.source_generation,
        .expected_catalog_generation = ready.catalog_generation,
    });
    fake_core.setSessionPlan(.controlled);
    fake_core.rearmControlled();
    try std.testing.expectEqual(@as(u64, 2), try runPreparedTask(&first, id, .{ .text = "interrupted by a crash" }));
    try waitControlSnapshot(&first, "\"currentRunPhase\":\"running\"");
    try std.testing.expectEqualStrings("next-model", task.durable.execution_model);
    try std.testing.expect(task.durable.checkpoint.?.anchor.terminal == .approval);
    try std.testing.expectEqualStrings("other-model", task.durable.checkpoint.?.session.model);
    // Restart from the admission commit, as after a crash during the Run.
    const history = try std.testing.allocator.dupe(u8, storage[0..persistence.len]);
    defer std.testing.allocator.free(history);
    try std.testing.expect(std.mem.indexOf(u8, history, "\"kind\":\"approval\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, history, "interrupted by a crash") != null);
    fake_core.releaseControlled();
    first.shutdownExecutor();
    first.stopCustomProviders();
    first.deinit();
    first_live = false;

    configuration.task_persistence = persistence.capabilityRestored(history);
    var restored = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, limits, configuration);
    defer restored.deinit();
    try std.testing.expect(restored.task_persistence_health != .degraded);
    try std.testing.expect(restored.task_runtime.findConst(id) != null);
    try restored.startCustomProviders(home, vault.port());
    defer restored.stopCustomProviders();
    _ = try configureTaskRebindTarget(&restored);
    _ = try configureTaskRebindModel(&restored, "next-model");
    try std.testing.expectEqual(workspace_id, try restored.openWorkspace(input));
    const recovered = restored.task_runtime.findConst(id) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(.detached, std.meta.activeTag(recovered.runtime.attachment));
    try std.testing.expectEqualStrings("next-model", recovered.durable.execution_model);
    const checkpoint = recovered.durable.checkpoint.?;
    try std.testing.expect(checkpoint.anchor.terminal == .approval);
    try std.testing.expectEqualStrings("other-model", checkpoint.session.model);
    try std.testing.expectEqual(task_state.ConversationCoverage.excluded, recovered.durable.runs[1].?.coverage);

    // Core restores the recorded model before Product installs the Task model.
    fake_core.setRestoredLogicalId(checkpoint.session.logical_session_id);
    fake_core.setRestoredModel("other-model");
    fake_core.lock();
    fake_core.restore_last_run_id = 1;
    fake_core.unlock();
    _ = try restored.restoreTaskConversation(id, recovered.durable.binding_epoch);
    for (0..5000) |_| {
        try restored.drainAgentEvents();
        restored.syncLifecycle();
        if (recovered.runtime.restore_job == null and !recovered.runtime.worker_leases.hasLive()) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    if (recovered.runtime.last_restore_failure) |failure| std.debug.print("crash recovery failed: {s}\n", .{@tagName(failure)});
    try std.testing.expect(recovered.runtime.hasAttachedSession());
    try std.testing.expectEqualStrings("next-model", recovered.durable.execution_model);
    try std.testing.expectEqualStrings("next-model", recovered.durable.checkpoint.?.session.model);
    try std.testing.expectEqualStrings("next-model", recovered.runtime.executionConst().?.model);
    try std.testing.expectEqual(@as(u64, 3), try runPreparedTask(&restored, id, .{ .text = "continue after the crash" }));
}

const runPreparedTask = fixture.runPreparedTask;

fn waitCatalogReady(
    workbench: *product_control.Runtime,
    workspace_id: u64,
) !product_control.CatalogProjection {
    for (0..10_000) |_| {
        try workbench.drainAgentEvents();
        const projection = try workbench.workspaceCatalog(workspace_id);
        switch (projection.availability) {
            .ready, .degraded => return projection,
            .unavailable => return error.TestUnexpectedResult,
            .uninitialized, .loading => std.testing.io.sleep(
                .fromMilliseconds(1),
                .awake,
            ) catch {},
        }
    }
    return error.TestUnexpectedResult;
}

fn waitTaskSnapshot(
    workbench: *product_control.Runtime,
    task_marker: []const u8,
    needle: []const u8,
) !void {
    var output: [128 * 1024]u8 = undefined;
    for (0..10_000) |_| {
        try workbench.drainAgentEvents();
        const snapshot = try workbench.writeAggregateFixture(&output);
        if (std.mem.indexOf(u8, snapshot, task_marker)) |start| {
            if (std.mem.indexOf(u8, snapshot[start..], needle) != null) return;
        }
        std.testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    return error.TestUnexpectedResult;
}

fn waitSetTaskArchived(workbench: *product_control.Runtime, task_id: u64) !void {
    for (0..10_000) |_| {
        workbench.setTaskArchived(task_id, true) catch |err| switch (err) {
            error.TaskBusy => {
                try workbench.drainAgentEvents();
                std.testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
                continue;
            },
            else => return err,
        };
        return;
    }
    return error.TestUnexpectedResult;
}

fn waitTaskDeleted(workbench: *product_control.Runtime, task_id: u64) !void {
    for (0..10_000) |_| {
        try workbench.drainAgentEvents();
        _ = workbench.taskBindingEpoch(task_id) catch |err| switch (err) {
            error.UnknownTask => return,
            else => return err,
        };
        std.testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    return error.TestUnexpectedResult;
}

fn waitCheckpointRecord(
    workbench: *product_control.Runtime,
    persistence: *TaskPersistenceProbe,
) !void {
    var output: [128 * 1024]u8 = undefined;
    for (0..10_000) |_| {
        try workbench.drainAgentEvents();
        _ = try workbench.writeAggregateFixture(&output);
        if (persistence.len != 0 and
            std.mem.indexOf(u8, persistence.storage.?[0..persistence.len], "\"checkpoint_anchor\":\"available\"") != null)
            return;
        std.testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    return error.TestUnexpectedResult;
}

fn waitHistoryNeedle(
    workbench: *product_control.Runtime,
    persistence: *TaskPersistenceProbe,
    needle: []const u8,
) !void {
    var output: [128 * 1024]u8 = undefined;
    for (0..10_000) |_| {
        try workbench.drainAgentEvents();
        _ = try workbench.writeAggregateFixture(&output);
        if (persistence.len != 0 and
            std.mem.indexOf(u8, persistence.storage.?[0..persistence.len], needle) != null)
            return;
        std.testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    return error.TestUnexpectedResult;
}

test "Product Control Task admission consumes the fixed MetaWork Agent tool surface" {
    fake_core.reset();
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var workbench = try product_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 1,
            .max_tasks = 1,
            .max_workspaces = 1,
            .max_runs_per_task = 1,
            .max_tools_per_run = 1,
        },
        productControlConfiguration(),
    );
    defer workbench.deinit();
    try installControlExecution(&workbench);
    _ = try workbench.createTask(productControlTaskInput(), try product_control.TestSupport.fixtureModelSelection(&workbench));

    try std.testing.expect(fake_core.product_allowlist_seen);
}

test "Task permission profile is immutable and successful interactive create remembers it" {
    fake_core.reset();
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 5,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var task_persistence: TaskPersistenceProbe = .{};
    var configuration = productControlConfiguration();
    configuration.task_persistence = task_persistence.capability();
    var workbench = try product_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 1,
            .max_tasks = 5,
            .max_workspaces = 1,
            .max_runs_per_task = 1,
            .max_tools_per_run = 1,
        },
        configuration,
    );
    defer workbench.deinit();
    try installControlExecution(&workbench);

    const default_task = try workbench.createTask(productControlTaskInput(), try product_control.TestSupport.fixtureModelSelection(&workbench));
    try std.testing.expectEqual(
        product_control.PermissionProfile.approval_required,
        try workbench.taskPermissionProfile(default_task),
    );
    try std.testing.expectEqual(
        product_control.PermissionInteraction.interactive,
        try workbench.taskPermissionInteraction(default_task),
    );
    fake_core.lock();
    const default_mode = fake_core.last_permission_mode_code;
    const default_shell = fake_core.last_shell_policy_code;
    fake_core.unlock();
    try std.testing.expectEqual(@as(?u32, wire.PERMISSION_ACCEPT_EDITS), default_mode);
    try std.testing.expectEqual(@as(?u32, wire.SHELL_UNRESTRICTED), default_shell);

    var full_access_input = productControlTaskInput();
    full_access_input.approval_mode = .full_access;
    const explicit_full_access = try workbench.createTask(full_access_input, try product_control.TestSupport.fixtureModelSelection(&workbench));
    try std.testing.expectEqual(
        product_control.PermissionProfile.full_access,
        try workbench.taskPermissionProfile(explicit_full_access),
    );
    try std.testing.expectEqual(
        product_control.PermissionProfile.approval_required,
        try workbench.taskPermissionProfile(default_task),
    );
    try std.testing.expectEqual(
        product_control.PermissionProfile.full_access,
        workbench.defaultPermissionProfile(),
    );
    const inherited_full_access = try workbench.createTask(productControlTaskInput(), try product_control.TestSupport.fixtureModelSelection(&workbench));
    try std.testing.expectEqual(
        product_control.PermissionProfile.full_access,
        try workbench.taskPermissionProfile(inherited_full_access),
    );
    fake_core.lock();
    const full_access_mode = fake_core.last_permission_mode_code;
    const full_access_shell = fake_core.last_shell_policy_code;
    fake_core.unlock();
    try std.testing.expectEqual(@as(?u32, wire.PERMISSION_FULL_ACCESS), full_access_mode);
    try std.testing.expectEqual(@as(?u32, wire.SHELL_UNRESTRICTED), full_access_shell);

    var explicit_input = productControlTaskInput();
    explicit_input.approval_mode = .manual;
    const explicit_task = try workbench.createTask(explicit_input, try product_control.TestSupport.fixtureModelSelection(&workbench));
    try std.testing.expectEqual(
        product_control.PermissionProfile.approval_required,
        try workbench.taskPermissionProfile(explicit_task),
    );
    try std.testing.expectEqual(
        product_control.PermissionProfile.approval_required,
        workbench.defaultPermissionProfile(),
    );
    fake_core.lock();
    const explicit_mode = fake_core.last_permission_mode_code;
    const explicit_shell = fake_core.last_shell_policy_code;
    fake_core.unlock();
    try std.testing.expectEqual(@as(?u32, wire.PERMISSION_ACCEPT_EDITS), explicit_mode);
    try std.testing.expectEqual(@as(?u32, wire.SHELL_UNRESTRICTED), explicit_shell);

    var rejected_input = productControlTaskInput();
    rejected_input.approval_mode = .full_access;
    task_persistence.result = .failed;
    const degraded_task = try workbench.createTask(rejected_input, try product_control.TestSupport.fixtureModelSelection(&workbench));
    try std.testing.expectEqual(
        product_control.PermissionProfile.full_access,
        try workbench.taskPermissionProfile(degraded_task),
    );
    try std.testing.expectEqual(
        product_control.PermissionProfile.full_access,
        workbench.defaultPermissionProfile(),
    );

    var capacity_rejected_input = productControlTaskInput();
    capacity_rejected_input.approval_mode = .manual;
    try std.testing.expectError(
        error.SessionCapacity,
        workbench.createTask(capacity_rejected_input, try product_control.TestSupport.fixtureModelSelection(&workbench)),
    );
    try std.testing.expectEqual(
        product_control.PermissionProfile.full_access,
        workbench.defaultPermissionProfile(),
    );
}

test "Run checkpoint commits immutable blob before durable descriptor" {
    fake_core.reset();
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_storage);
    var checkpoint_store = try product_task.checkpoint_store.FileStore.init(
        std.testing.io,
        root_storage[0..root_len],
    );
    defer checkpoint_store.deinit();
    const persistence_storage = try std.testing.allocator.alloc(
        u8,
        product_task.history.max_store_bytes,
    );
    defer std.testing.allocator.free(persistence_storage);
    var persistence = TaskPersistenceProbe{ .storage = persistence_storage };
    var configuration = productControlConfiguration();
    configuration.task_persistence = persistence.capability();
    configuration.checkpoint_store = .{ .file_store = &checkpoint_store };
    var workbench = try product_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 1,
            .max_tasks = 1,
            .max_runs_per_task = 2,
            .max_tools_per_run = 1,
        },
        configuration,
    );
    var workbench_initialized = true;
    defer if (workbench_initialized) workbench.deinit();
    try installControlExecution(&workbench);
    const task_id = try workbench.createTask(productControlTaskInput(), try product_control.TestSupport.fixtureModelSelection(&workbench));
    _ = try runPreparedTask(&workbench, task_id, .{ .text = "persist checkpoint" });
    try waitCheckpointRecord(&workbench, &persistence);

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("fixture-checkpoint", &digest, .{});
    const identity: product_task.checkpoint_store.Identity = .{
        .task_id = task_id,
        .generation = 0,
        .digest = digest,
        .byte_size = "fixture-checkpoint".len,
    };
    try checkpoint_store.verify(identity);
    const history = persistence_storage[0..persistence.len];
    try std.testing.expect(std.mem.indexOf(u8, history, "\"generation\":0") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        history,
        "\"logical_session_id\":\"000000000000000000000001\"",
    ) != null);

    fake_core.setCheckpointGeneration(1);
    _ = try workbench.compactTaskAtBinding(
        task_id,
        try workbench.taskBindingEpoch(task_id),
    );
    try waitHistoryNeedle(
        &workbench,
        &persistence,
        "\"terminal\":{\"kind\":\"compact\",\"id\":1}",
    );
    const compact_identity: product_task.checkpoint_store.Identity = .{
        .task_id = task_id,
        .generation = 1,
        .digest = digest,
        .byte_size = "fixture-checkpoint".len,
    };
    try checkpoint_store.verify(compact_identity);
    try std.testing.expectError(error.BlobMissing, checkpoint_store.verify(identity));

    fake_core.setCheckpointGeneration(2);
    _ = try runPreparedTask(&workbench, task_id, .{ .text = "checkpoint after compact" });
    try waitHistoryNeedle(
        &workbench,
        &persistence,
        "\"terminal\":{\"kind\":\"run\",\"id\":2}",
    );
    const post_compact_run_identity: product_task.checkpoint_store.Identity = .{
        .task_id = task_id,
        .generation = 2,
        .digest = digest,
        .byte_size = "fixture-checkpoint".len,
    };
    try checkpoint_store.verify(post_compact_run_identity);
    try std.testing.expectError(error.BlobMissing, checkpoint_store.verify(compact_identity));
    const post_compact_history = persistence_storage[0..persistence.len];
    try std.testing.expect(std.mem.indexOf(
        u8,
        post_compact_history,
        "\"coverage\":\"pending\"",
    ) == null);
    try std.testing.expectEqual(
        @as(usize, 3),
        std.mem.count(u8, post_compact_history, "\"coverage\":\"covered\""),
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        post_compact_history,
        "\"last_run_id\":2,\"last_compact_id\":1",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        post_compact_history,
        "\"terminal\":{\"kind\":\"run\",\"id\":2}",
    ) != null);

    workbench.deinit();
    workbench_initialized = false;
    const restart_history = try std.testing.allocator.dupe(
        u8,
        persistence_storage[0..persistence.len],
    );
    defer std.testing.allocator.free(restart_history);
    const digest_hex = std.fmt.bytesToHex(digest, .lower);
    var blob_path_storage: [160]u8 = undefined;
    const blob_path = try std.fmt.bufPrint(
        &blob_path_storage,
        "{d}/2-{s}.ckpt",
        .{ task_id, digest_hex },
    );
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = blob_path,
        .data = "corrupt-checkpoint",
    });
    var restart_configuration = productControlConfiguration();
    restart_configuration.task_persistence = persistence.capabilityRestored(restart_history);
    restart_configuration.checkpoint_store = .{ .file_store = &checkpoint_store };
    var restored = try product_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 1,
            .max_tasks = 1,
            .max_runs_per_task = 2,
            .max_tools_per_run = 1,
        },
        restart_configuration,
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        persistence_storage[0..persistence.len],
        "\"checkpoint\":null,\"checkpoint_anchor\":\"blob_mismatch\"",
    ) != null);
    try std.testing.expectError(error.BlobMissing, checkpoint_store.verify(post_compact_run_identity));
    restored.deinit();

    {
        var replacement_writer = try checkpoint_store.begin(task_id, 1024);
        defer replacement_writer.deinit();
        try replacement_writer.write("fixture-checkpoint");
        _ = try replacement_writer.commit(2, digest, "fixture-checkpoint".len);
    }
    checkpoint_store.delete(post_compact_run_identity);
    var missing_configuration = productControlConfiguration();
    missing_configuration.task_persistence = persistence.capabilityRestored(restart_history);
    missing_configuration.checkpoint_store = .{ .file_store = &checkpoint_store };
    var missing_restored = try product_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 1,
            .max_tasks = 1,
            .max_runs_per_task = 2,
            .max_tools_per_run = 1,
        },
        missing_configuration,
    );
    defer missing_restored.deinit();
    try std.testing.expect(std.mem.indexOf(
        u8,
        persistence_storage[0..persistence.len],
        "\"checkpoint\":null,\"checkpoint_anchor\":\"blob_missing\"",
    ) != null);
    fake_core.lock();
    const session_count = fake_core.session_created;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), session_count);
}

test "restart recovery revalidates live authority and continues the same Conversation" {
    fake_core.reset();
    fake_core.setCheckpointGeneration(1);
    const home = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(home);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_storage);
    var checkpoint_store = try product_task.checkpoint_store.FileStore.init(
        std.testing.io,
        root_storage[0..root_len],
    );
    defer checkpoint_store.deinit();
    var skill_enablement_tmp = std.testing.tmpDir(.{});
    defer skill_enablement_tmp.cleanup();
    var skill_enablement_root_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const skill_enablement_root_len = try skill_enablement_tmp.dir.realPath(
        std.testing.io,
        &skill_enablement_root_storage,
    );
    var skill_enablement_store = try product_skill.enablement.FileStore.init(
        std.testing.io,
        skill_enablement_root_storage[0..skill_enablement_root_len],
    );
    defer skill_enablement_store.deinit();
    const persistence_storage = try std.testing.allocator.alloc(
        u8,
        product_task.history.max_store_bytes,
    );
    defer std.testing.allocator.free(persistence_storage);
    var persistence = TaskPersistenceProbe{ .storage = persistence_storage };

    var runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 2,
        .max_sessions = 1,
    });
    var runtime_live = true;
    defer if (runtime_live) {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    };
    var first_configuration = productControlConfiguration();
    first_configuration.directories.canonical_user_home = home;
    first_configuration.task_persistence = persistence.capability();
    first_configuration.checkpoint_store = .{ .file_store = &checkpoint_store };
    first_configuration.skill_enablement = .{ .file_store = &skill_enablement_store };
    var first = try product_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 2,
            .max_workspaces = 1,
            .max_tasks = 1,
            .max_runs_per_task = 3,
            .max_tools_per_run = 1,
        },
        first_configuration,
    );
    var first_workbench_live = true;
    defer if (first_workbench_live) first.deinit();
    try installControlExecutionGeneration(&first, 1);
    const workspace_id = try first.openWorkspace(productControlTaskInput());
    var catalog = try waitCatalogReady(&first, workspace_id);
    _ = try first.setSkillEnabled(.{
        .scope = .{ .project = .{
            .workspace_id = workspace_id,
            .expected_workspace_epoch = try first.workspaceEpoch(workspace_id),
        } },
        .skill_policy_key = "review",
        .state = .disabled,
        .expected_catalog_revision = catalog.revision,
        .expected_selection_revision = catalog.selection_revision.?,
    });
    catalog = try first.workspaceCatalog(workspace_id);
    const task_id = try first.createTaskInWorkspace(workspace_id, try first.workspaceEpoch(workspace_id), try product_control.TestSupport.fixtureModelSelection(&first), catalog.revision, catalog.selection_revision, .{ .interactive = .full_access });
    try std.testing.expectEqual(
        product_control.PermissionProfile.full_access,
        try first.taskPermissionProfile(task_id),
    );
    fake_core.lock();
    const fresh_permission_mode = fake_core.last_permission_mode_code;
    const fresh_shell_policy = fake_core.last_shell_policy_code;
    fake_core.unlock();
    try std.testing.expectEqual(@as(?u32, wire.PERMISSION_FULL_ACCESS), fresh_permission_mode);
    try std.testing.expectEqual(@as(?u32, wire.SHELL_UNRESTRICTED), fresh_shell_policy);
    _ = try runPreparedTask(&first, task_id, .{ .text = "remember restart nonce" });
    try waitCheckpointRecord(&first, &persistence);
    const restart_history = try std.testing.allocator.dupe(
        u8,
        persistence_storage[0..persistence.len],
    );
    defer std.testing.allocator.free(restart_history);
    first.shutdownExecutor();
    first.deinit();
    first_workbench_live = false;
    try shutdownTestComposition(runtime);
    deinitTestComposition(runtime);
    runtime_live = false;
    fake_core.lock();
    fake_core.session_created = 0;
    fake_core.checkpoint_restores = 0;
    fake_core.run_calls = 0;
    fake_core.credential_seen = false;
    fake_core.restore_last_run_id = 1;
    fake_core.restore_last_compact_id = 0;
    fake_core.unlock();
    const restored_enablement = (try skill_enablement_store.loadAlloc(
        std.testing.allocator,
    )) orelse return error.TestExpectedEqual;
    defer std.testing.allocator.free(restored_enablement);
    runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 2,
        .max_sessions = 1,
    });
    runtime_live = true;
    var second_configuration = productControlConfiguration();
    second_configuration.directories.canonical_user_home = home;
    second_configuration.task_persistence = persistence.capabilityRestored(restart_history);
    second_configuration.checkpoint_store = .{ .file_store = &checkpoint_store };
    second_configuration.skill_enablement = .{
        .file_store = &skill_enablement_store,
        .restored_bytes = restored_enablement,
    };
    var restored = try product_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 2,
            .max_workspaces = 1,
            .max_tasks = 1,
            .max_runs_per_task = 3,
            .max_tools_per_run = 1,
        },
        second_configuration,
    );
    var restored_live = true;
    defer if (restored_live) restored.deinit();
    try installControlExecutionGeneration(&restored, 2);
    // A persisted manual Workspace deliberately restarts without authority.
    // Reopening it models the user's explicit reauthorization action.
    try std.testing.expectEqual(
        workspace_id,
        try restored.openWorkspace(productControlTaskInput()),
    );
    _ = try waitCatalogReady(&restored, workspace_id);
    try waitTaskSnapshot(
        &restored,
        "\"id\":\"1\"",
        "\"continuationRecoveryAvailable\":true",
    );
    fake_core.forceNextCheckpointRestoreStatus(wire.STATUS_CHECKPOINT_CORRUPT);
    _ = try restored.restoreTaskConversation(
        task_id,
        try restored.taskBindingEpoch(task_id),
    );
    try waitTaskSnapshot(
        &restored,
        "\"id\":\"1\"",
        "\"continuationUnavailableReason\":\"session_recovery_failed\"",
    );
    fake_core.armControlledRestoreAfterCreate();
    defer fake_core.releaseControlledRestore();
    fake_core.lock();
    const restores_before_execution_replacement = fake_core.checkpoint_restores;
    const sessions_destroyed_before_execution_replacement = fake_core.session_destroyed;
    fake_core.unlock();
    _ = try restored.restoreTaskConversation(
        task_id,
        try restored.taskBindingEpoch(task_id),
    );
    fake_core.waitUntilRestoreEntered();
    installTwoModelCatalog(&restored);
    fake_core.releaseControlledRestore();
    try waitTaskSnapshot(
        &restored,
        "\"id\":\"1\"",
        "\"activeOperation\":null",
    );
    // Rejected publication hands a real candidate to the ordinary close
    // worker. Restore completion alone does not prove that worker finished.
    try waitTaskSnapshot(&restored, "\"id\":\"1\"", "\"unavailableReason\":\"runtime_detached\"");
    fake_core.lock();
    const restores_after_execution_replacement = fake_core.checkpoint_restores;
    const sessions_destroyed_after_execution_replacement = fake_core.session_destroyed;
    // FakeCore synthesizes the restored logical Session identity from this
    // counter. The stale candidate consumed and released identity 1; reset the
    // fixture generator so the next independent attempt still models the same
    // checkpoint-owned logical identity.
    fake_core.session_created = 0;
    fake_core.unlock();
    try std.testing.expectEqual(
        restores_before_execution_replacement + 1,
        restores_after_execution_replacement,
    );
    try std.testing.expectEqual(
        sessions_destroyed_before_execution_replacement + 1,
        sessions_destroyed_after_execution_replacement,
    );
    try waitTaskSnapshot(
        &restored,
        "\"id\":\"1\"",
        "\"continuationRecoveryAvailable\":true",
    );

    fake_core.lock();
    const catalog_queries_before_restore = fake_core.catalog_queries;
    fake_core.unlock();
    fake_core.forceNextCheckpointRestoreDegraded();
    fake_core.armControlledRestore();
    _ = try restored.restoreTaskConversation(
        task_id,
        try restored.taskBindingEpoch(task_id),
    );
    fake_core.waitUntilRestoreEntered();
    try std.testing.expectError(
        error.RecoveryUnavailable,
        restored.restoreTaskConversation(
            task_id,
            try restored.taskBindingEpoch(task_id),
        ),
    );
    fake_core.releaseControlledRestore();
    try waitTaskSnapshot(
        &restored,
        "\"id\":\"1\"",
        "\"activeOperation\":null",
    );
    try std.testing.expectEqual(@as(u64, 2), try restored.taskBindingEpoch(task_id));
    try std.testing.expectEqual(@as(u64, 2), restored.task_runtime.find(task_id).?.durable.checkpoint.?.anchor.binding_epoch);
    try std.testing.expectEqual(
        product_control.PermissionProfile.full_access,
        try restored.taskPermissionProfile(task_id),
    );
    fake_core.lock();
    const restored_permission_mode = fake_core.last_permission_mode_code;
    const restored_shell_policy = fake_core.last_shell_policy_code;
    fake_core.unlock();
    try std.testing.expectEqual(@as(?u32, wire.PERMISSION_FULL_ACCESS), restored_permission_mode);
    try std.testing.expectEqual(@as(?u32, wire.SHELL_UNRESTRICTED), restored_shell_policy);
    try waitTaskSnapshot(
        &restored,
        "\"id\":\"1\"",
        "\"restorePermission\":{\"restoredRules\":\"0\",\"invalidatedRules\":\"1\"}",
    );
    const restore_report = restored.task_runtime.tasks[0].?.runtime.last_restore_report.?;
    try std.testing.expectEqual(@as(@TypeOf(restore_report.health), .degraded), restore_report.health);
    try std.testing.expectEqual(@as(u32, 1), restore_report.invalidated_skill_authority);
    try std.testing.expectEqual(@as(u32, 1), restore_report.invalidated_permission_rules);
    try std.testing.expectEqual(@as(u32, 1), restore_report.invalidated_mcp_bindings);
    const unbound_catalog = try restored.taskCatalog(task_id);
    try std.testing.expectEqual(
        product_control.CatalogAvailability.uninitialized,
        unbound_catalog.availability,
    );
    fake_core.lock();
    const catalog_queries_after_restore = fake_core.catalog_queries;
    fake_core.unlock();
    try std.testing.expectEqual(catalog_queries_before_restore, catalog_queries_after_restore);
    try restored.refreshTaskCatalog(
        task_id,
        try restored.taskBindingEpoch(task_id),
    );
    const restored_catalog = try restored.taskCatalog(task_id);
    try std.testing.expectEqual(@as(?u64, 2), restored_catalog.selection_revision);
    try std.testing.expect(!restored_catalog.skills[0].enabled);
    try std.testing.expectError(
        error.SkillUnavailable,
        restored.runTask(task_id, .{ .skill = .{
            .skill_id = fixture.fixture_skill_id,
            .catalog_revision = restored_catalog.revision,
            .selection_revision = restored_catalog.selection_revision.?,
            .argument_values = &.{},
        } }),
    );
    try std.testing.expectEqual(@as(usize, 13), fake_core.last_restored_allowed_tool_count);

    _ = try runPreparedTask(&restored, task_id, .{ .text = "continue after restart" });
    try waitTaskSnapshot(
        &restored,
        "\"id\":\"2\",\"conversationCoverage\":\"included\",\"phase\":\"completed\"",
        "\"outcome\":\"completed\"",
    );
    fake_core.lock();
    const restore_calls = fake_core.checkpoint_restores;
    const run_calls = fake_core.run_calls;
    const credential_seen = fake_core.credential_seen;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 3), restore_calls);
    try std.testing.expectEqual(@as(usize, 1), run_calls);
    try std.testing.expect(credential_seen);

    restored.shutdownExecutor();
    restored.deinit();
    restored_live = false;
    try shutdownTestComposition(runtime);
    deinitTestComposition(runtime);
    runtime_live = false;

    runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 2,
        .max_sessions = 1,
    });
    runtime_live = true;

    var third_configuration = productControlConfiguration();
    third_configuration.directories.canonical_user_home = home;
    third_configuration.task_persistence = persistence.capabilityRestored(restart_history);
    third_configuration.checkpoint_store = .{ .file_store = &checkpoint_store };
    third_configuration.skill_enablement = .{
        .file_store = &skill_enablement_store,
        .restored_bytes = restored_enablement,
    };
    var shutdown_restore = try product_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 2,
            .max_workspaces = 1,
            .max_tasks = 1,
            .max_runs_per_task = 3,
            .max_tools_per_run = 1,
        },
        third_configuration,
    );
    var shutdown_restore_live = true;
    defer if (shutdown_restore_live) shutdown_restore.deinit();
    try installControlExecutionGeneration(&shutdown_restore, 2);
    try std.testing.expectEqual(
        workspace_id,
        try shutdown_restore.openWorkspace(productControlTaskInput()),
    );
    _ = try waitCatalogReady(&shutdown_restore, workspace_id);
    try waitTaskSnapshot(
        &shutdown_restore,
        "\"id\":\"1\"",
        "\"continuationRecoveryAvailable\":true",
    );

    fake_core.armControlledRestore();
    _ = try shutdown_restore.restoreTaskConversation(
        task_id,
        try shutdown_restore.taskBindingEpoch(task_id),
    );
    fake_core.waitUntilRestoreEntered();
    var shutdown_context = ShutdownContext{ .workbench = &shutdown_restore };
    const shutdown_thread = try std.Thread.spawn(
        .{},
        ShutdownContext.run,
        .{&shutdown_context},
    );
    var shutdown_joined = false;
    defer if (!shutdown_joined) {
        fake_core.releaseControlledRestore();
        shutdown_thread.join();
    };
    for (0..10_000) |_| {
        if (shutdown_restore.testRestoreCancellationRequested(task_id)) break;
        std.testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
    } else return error.TestUnexpectedResult;
    fake_core.releaseControlledRestore();
    shutdown_thread.join();
    shutdown_joined = true;
    var shutdown_snapshot_storage: [128 * 1024]u8 = undefined;
    const shutdown_snapshot = try shutdown_restore.writeAggregateFixture(
        &shutdown_snapshot_storage,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, shutdown_snapshot, "\"kind\":\"restore\"") == null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            shutdown_snapshot,
            "\"continuationRecoveryAvailable\":false",
        ) != null,
    );

    shutdown_restore.deinit();
    shutdown_restore_live = false;
    try shutdownTestComposition(runtime);
    deinitTestComposition(runtime);
    runtime_live = false;

    runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 2,
        .max_sessions = 1,
    });
    runtime_live = true;
    var invalidation_configuration = productControlConfiguration();
    invalidation_configuration.directories.canonical_user_home = home;
    invalidation_configuration.task_persistence =
        persistence.capabilityRestored(restart_history);
    invalidation_configuration.checkpoint_store = .{ .file_store = &checkpoint_store };
    invalidation_configuration.skill_enablement = .{
        .file_store = &skill_enablement_store,
        .restored_bytes = restored_enablement,
    };
    var workspace_invalidation = try product_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 2,
            .max_workspaces = 1,
            .max_tasks = 1,
            .max_runs_per_task = 3,
            .max_tools_per_run = 1,
        },
        invalidation_configuration,
    );
    defer workspace_invalidation.deinit();
    try installControlExecutionGeneration(&workspace_invalidation, 2);
    try std.testing.expectEqual(
        workspace_id,
        try workspace_invalidation.openWorkspace(productControlTaskInput()),
    );
    _ = try waitCatalogReady(&workspace_invalidation, workspace_id);
    try waitTaskSnapshot(
        &workspace_invalidation,
        "\"id\":\"1\"",
        "\"continuationRecoveryAvailable\":true",
    );

    fake_core.armControlledRestoreAfterCreate();
    fake_core.lock();
    const restores_before_workspace_removal = fake_core.checkpoint_restores;
    const sessions_destroyed_before_workspace_removal = fake_core.session_destroyed;
    fake_core.unlock();
    _ = try workspace_invalidation.restoreTaskConversation(
        task_id,
        try workspace_invalidation.taskBindingEpoch(task_id),
    );
    fake_core.waitUntilRestoreEntered();
    try workspace_invalidation.removeWorkspace(workspace_id);
    fake_core.releaseControlledRestore();
    try waitTaskSnapshot(
        &workspace_invalidation,
        "\"id\":\"1\"",
        "\"activeOperation\":null",
    );
    try waitControlSnapshot(&workspace_invalidation, "\"workspaces\":[]");
    var invalidation_snapshot_storage: [128 * 1024]u8 = undefined;
    const invalidation_snapshot = try workspace_invalidation.writeAggregateFixture(
        &invalidation_snapshot_storage,
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        invalidation_snapshot,
        "\"continuationAvailable\":true",
    ) == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        invalidation_snapshot,
        "\"continuationRecoveryAvailable\":false",
    ) != null);
    fake_core.lock();
    const restores_after_workspace_removal = fake_core.checkpoint_restores;
    const sessions_destroyed_after_workspace_removal = fake_core.session_destroyed;
    fake_core.unlock();
    try std.testing.expectEqual(
        restores_before_workspace_removal + 1,
        restores_after_workspace_removal,
    );
    try std.testing.expectEqual(
        sessions_destroyed_before_workspace_removal + 1,
        sessions_destroyed_after_workspace_removal,
    );
}

test "automatic Task binding adoption survives another restart and admits a second Text Run" {
    fake_core.reset();
    fake_core.setCheckpointGeneration(1);
    const home = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(home);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_storage);
    var automatic_root = try product_control.AutomaticWorkspaceRoot.open(
        std.testing.io,
        std.testing.allocator,
        root_storage[0..root_len],
    );
    defer automatic_root.deinit();
    var checkpoint_tmp = std.testing.tmpDir(.{});
    defer checkpoint_tmp.cleanup();
    var checkpoint_root_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const checkpoint_root_len = try checkpoint_tmp.dir.realPath(
        std.testing.io,
        &checkpoint_root_storage,
    );
    var checkpoint_store = try product_task.checkpoint_store.FileStore.init(
        std.testing.io,
        checkpoint_root_storage[0..checkpoint_root_len],
    );
    defer checkpoint_store.deinit();
    const persistence_storage = try std.testing.allocator.alloc(
        u8,
        product_task.history.max_store_bytes,
    );
    defer std.testing.allocator.free(persistence_storage);
    var persistence = TaskPersistenceProbe{ .storage = persistence_storage };

    var runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 2,
        .max_sessions = 1,
    });
    var runtime_live = true;
    defer if (runtime_live) {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    };
    var first_configuration = productControlConfiguration();
    first_configuration.directories.canonical_user_home = home;
    first_configuration.directories.testing_automatic_workspace_root = &automatic_root;
    first_configuration.task_persistence = persistence.capability();
    first_configuration.checkpoint_store = .{ .file_store = &checkpoint_store };
    var first = try product_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 2,
            .max_workspaces = 1,
            .max_tasks = 1,
            .max_runs_per_task = 2,
            .max_tools_per_run = 1,
        },
        first_configuration,
    );
    var first_live = true;
    defer if (first_live) first.deinit();
    try installControlExecutionGeneration(&first, 1);
    const task_id = try first.createTaskForWorkspace(.automatic, try product_control.TestSupport.fixtureModelSelection(&first), null, null, .{ .interactive = null });
    try waitInitialTaskCatalog(&first, task_id);
    _ = try runPreparedTask(&first, task_id, .{ .text = "automatic first run" });
    try waitCheckpointRecord(&first, &persistence);
    const restart_history = try std.testing.allocator.dupe(
        u8,
        persistence_storage[0..persistence.len],
    );
    defer std.testing.allocator.free(restart_history);
    first.shutdownExecutor();
    first.deinit();
    first_live = false;
    try shutdownTestComposition(runtime);
    deinitTestComposition(runtime);
    runtime_live = false;

    fake_core.lock();
    fake_core.session_created = 0;
    fake_core.checkpoint_restores = 0;
    fake_core.run_calls = 0;
    fake_core.restore_last_run_id = 1;
    fake_core.restore_last_compact_id = 0;
    fake_core.unlock();
    runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 2,
        .max_sessions = 1,
    });
    runtime_live = true;
    var restored_automatic_root = try product_control.AutomaticWorkspaceRoot.open(
        std.testing.io,
        std.testing.allocator,
        root_storage[0..root_len],
    );
    defer restored_automatic_root.deinit();
    var second_configuration = productControlConfiguration();
    second_configuration.directories.canonical_user_home = home;
    second_configuration.directories.testing_automatic_workspace_root = &restored_automatic_root;
    second_configuration.task_persistence = persistence.capabilityRestored(restart_history);
    second_configuration.checkpoint_store = .{ .file_store = &checkpoint_store };
    var restored = try product_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 2,
            .max_workspaces = 1,
            .max_tasks = 1,
            .max_runs_per_task = 2,
            .max_tools_per_run = 1,
        },
        second_configuration,
    );
    var restored_live = true;
    defer if (restored_live) restored.deinit();
    try installControlExecutionGeneration(&restored, 2);
    try waitTaskSnapshot(
        &restored,
        "\"id\":\"1\"",
        "\"continuationRecoveryAvailable\":true",
    );
    _ = try restored.restoreTaskConversation(
        task_id,
        try restored.taskBindingEpoch(task_id),
    );
    try waitTaskSnapshot(
        &restored,
        "\"id\":\"1\"",
        "\"continuationAvailable\":true",
    );
    try std.testing.expectEqual(@as(u64, 2), try restored.taskBindingEpoch(task_id));
    const adopted_history = try std.testing.allocator.dupe(
        u8,
        persistence_storage[0..persistence.len],
    );
    defer std.testing.allocator.free(adopted_history);
    restored.shutdownExecutor();
    restored.deinit();
    restored_live = false;
    try shutdownTestComposition(runtime);
    deinitTestComposition(runtime);
    runtime_live = false;

    fake_core.lock();
    fake_core.session_created = 0;
    fake_core.checkpoint_restores = 0;
    fake_core.run_calls = 0;
    fake_core.restore_last_run_id = 1;
    fake_core.restore_last_compact_id = 0;
    fake_core.unlock();
    runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 2,
        .max_sessions = 1,
    });
    runtime_live = true;
    var continued_automatic_root = try product_control.AutomaticWorkspaceRoot.open(
        std.testing.io,
        std.testing.allocator,
        root_storage[0..root_len],
    );
    defer continued_automatic_root.deinit();
    var third_configuration = productControlConfiguration();
    third_configuration.directories.canonical_user_home = home;
    third_configuration.directories.testing_automatic_workspace_root = &continued_automatic_root;
    third_configuration.task_persistence = persistence.capabilityRestored(adopted_history);
    third_configuration.checkpoint_store = .{ .file_store = &checkpoint_store };
    var continued = try product_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 2,
            .max_workspaces = 1,
            .max_tasks = 1,
            .max_runs_per_task = 2,
            .max_tools_per_run = 1,
        },
        third_configuration,
    );
    var continued_live = true;
    defer if (continued_live) continued.deinit();
    try installControlExecutionGeneration(&continued, 2);
    try waitTaskSnapshot(
        &continued,
        "\"id\":\"1\"",
        "\"continuationRecoveryAvailable\":true",
    );
    _ = try continued.restoreTaskConversation(
        task_id,
        try continued.taskBindingEpoch(task_id),
    );
    try waitTaskSnapshot(
        &continued,
        "\"id\":\"1\"",
        "\"continuationAvailable\":true",
    );
    try std.testing.expectEqual(@as(u64, 3), try continued.taskBindingEpoch(task_id));
    try waitInitialTaskCatalog(&continued, task_id);
    try std.testing.expectEqual(
        product_control.CatalogAvailability.unavailable,
        (try continued.taskCatalog(task_id)).availability,
    );
    _ = try runPreparedTask(&continued, task_id, .{ .text = "automatic second run" });
    try waitTaskSnapshot(
        &continued,
        "\"id\":\"2\",\"conversationCoverage\":\"included\",\"phase\":\"completed\"",
        "\"outcome\":\"completed\"",
    );
    fake_core.lock();
    const restores = fake_core.checkpoint_restores;
    const runs = fake_core.run_calls;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), restores);
    try std.testing.expectEqual(@as(usize, 1), runs);

    continued.shutdownExecutor();
    continued.deinit();
    continued_live = false;
    try shutdownTestComposition(runtime);
    deinitTestComposition(runtime);
    runtime_live = false;
}

test "accepted Task deletion advances after checkpoint quiescence without a second command" {
    fake_core.reset();
    fake_core.controlNextCheckpointExport();
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_storage);
    var checkpoint_store = try product_task.checkpoint_store.FileStore.init(
        std.testing.io,
        root_storage[0..root_len],
    );
    defer checkpoint_store.deinit();
    const persistence_storage = try std.testing.allocator.alloc(
        u8,
        product_task.history.max_store_bytes,
    );
    defer std.testing.allocator.free(persistence_storage);
    var persistence = TaskPersistenceProbe{ .storage = persistence_storage };
    var configuration = productControlConfiguration();
    configuration.task_persistence = persistence.capability();
    configuration.checkpoint_store = .{ .file_store = &checkpoint_store };
    var workbench = try product_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 1,
            .max_tasks = 1,
            .max_runs_per_task = 2,
            .max_tools_per_run = 1,
        },
        configuration,
    );
    defer workbench.deinit();
    try installControlExecution(&workbench);
    const task_id = try workbench.createTask(productControlTaskInput(), try product_control.TestSupport.fixtureModelSelection(&workbench));
    _ = try runPreparedTask(&workbench, task_id, .{ .text = "cancel checkpoint export" });
    fake_core.waitCheckpointExportEntered();
    // Product terminal publication must not wait for the same executor job's
    // controlled checkpoint export to be released.
    try waitControlSnapshot(&workbench, "\"terminal\":{\"outcome\":\"completed\"");
    const exporting_run = &workbench.task_runtime.find(task_id).?.durable.runs[0].?;
    try std.testing.expect(exporting_run.execution != null);
    try workbench.setTaskArchived(task_id, true);
    try workbench.deleteTask(task_id);
    try waitControlSnapshot(&workbench, "\"deletionStatus\":\"deleting\"");
    fake_core.releaseCheckpointExport();
    try waitTaskDeleted(&workbench, task_id);
}

test "definite descriptor failure preserves terminal history and leaves a recoverable orphan" {
    fake_core.reset();
    fake_core.controlNextCheckpointExport();
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_storage);
    var checkpoint_store = try product_task.checkpoint_store.FileStore.init(
        std.testing.io,
        root_storage[0..root_len],
    );
    defer checkpoint_store.deinit();
    const persistence_storage = try std.testing.allocator.alloc(
        u8,
        product_task.history.max_store_bytes,
    );
    defer std.testing.allocator.free(persistence_storage);
    var persistence = TaskPersistenceProbe{ .storage = persistence_storage };
    var configuration = productControlConfiguration();
    configuration.task_persistence = persistence.capability();
    configuration.checkpoint_store = .{ .file_store = &checkpoint_store };
    var workbench = try product_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        runtime,
        .{ .worker_count = 1, .queue_capacity = 1, .max_tasks = 1, .max_runs_per_task = 1, .max_tools_per_run = 1 },
        configuration,
    );
    var initialized = true;
    defer if (initialized) workbench.deinit();
    try installControlExecution(&workbench);
    const task_id = try workbench.createTask(productControlTaskInput(), try product_control.TestSupport.fixtureModelSelection(&workbench));
    _ = try runPreparedTask(&workbench, task_id, .{ .text = "descriptor commit fails" });
    fake_core.waitCheckpointExportEntered();
    try workbench.drainAgentEvents();
    var snapshot: [128 * 1024]u8 = undefined;
    _ = try workbench.writeAggregateFixture(&snapshot);
    const terminal_commits = persistence.commits;
    persistence.result = .failed;
    fake_core.releaseCheckpointExport();
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("fixture-checkpoint", &digest, .{});
    const identity: product_task.checkpoint_store.Identity = .{
        .task_id = task_id,
        .generation = 0,
        .digest = digest,
        .byte_size = "fixture-checkpoint".len,
    };
    var blob_ready = false;
    for (0..10_000) |_| {
        checkpoint_store.verify(identity) catch {
            std.Thread.yield() catch {};
            continue;
        };
        blob_ready = true;
        break;
    }
    try std.testing.expect(blob_ready);
    for (0..10_000) |_| {
        try workbench.drainAgentEvents();
        _ = try workbench.writeAggregateFixture(&snapshot);
        if (persistence.commits > terminal_commits) break;
        std.Thread.yield() catch {};
    }
    try std.testing.expect(persistence.commits > terminal_commits);
    try checkpoint_store.verify(identity);
    try std.testing.expectEqual(
        product_task.testing.state_module.ConversationCoverage.pending,
        workbench.task_runtime.tasks[0].?.durable.runs[0].?.coverage,
    );
    const durable_terminal = persistence_storage[0..persistence.len];
    try std.testing.expect(std.mem.indexOf(u8, durable_terminal, "\"phase\":\"completed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, durable_terminal, "\"checkpoint\":null") != null);

    workbench.deinit();
    initialized = false;
    persistence.result = .committed;
    var restart_configuration = productControlConfiguration();
    restart_configuration.task_persistence = persistence.capabilityRestored(durable_terminal);
    restart_configuration.checkpoint_store = .{ .file_store = &checkpoint_store };
    var restored = try product_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        runtime,
        .{ .worker_count = 1, .queue_capacity = 1, .max_tasks = 1, .max_runs_per_task = 1, .max_tools_per_run = 1 },
        restart_configuration,
    );
    defer restored.deinit();
    try std.testing.expectEqual(
        product_task.checkpoint_store.Health.ready,
        restored.checkpointStoreHealth(),
    );
    var restored_snapshot: [128 * 1024]u8 = undefined;
    const restored_json = try restored.writeAggregateFixture(&restored_snapshot);
    try std.testing.expect(std.mem.indexOf(
        u8,
        restored_json,
        "\"taskHistoryPersistenceHealth\":\"ready\"",
    ) != null);
    try std.testing.expectError(error.BlobMissing, checkpoint_store.verify(identity));
}

test "unknown descriptor commit remains retryable without freezing Product Task" {
    fake_core.reset();
    fake_core.controlNextCheckpointExport();
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_storage);
    var checkpoint_store = try product_task.checkpoint_store.FileStore.init(
        std.testing.io,
        root_storage[0..root_len],
    );
    defer checkpoint_store.deinit();
    const persistence_storage = try std.testing.allocator.alloc(
        u8,
        product_task.history.max_store_bytes,
    );
    defer std.testing.allocator.free(persistence_storage);
    var persistence = TaskPersistenceProbe{ .storage = persistence_storage };
    var configuration = productControlConfiguration();
    configuration.task_persistence = persistence.capability();
    configuration.checkpoint_store = .{ .file_store = &checkpoint_store };
    var workbench = try product_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        runtime,
        .{ .worker_count = 1, .queue_capacity = 1, .max_tasks = 1, .max_runs_per_task = 2, .max_compacts_per_task = 1, .max_tools_per_run = 1 },
        configuration,
    );
    var initialized = true;
    defer if (initialized) workbench.deinit();
    try installControlExecution(&workbench);
    const task_id = try workbench.createTask(productControlTaskInput(), try product_control.TestSupport.fixtureModelSelection(&workbench));
    _ = try runPreparedTask(&workbench, task_id, .{ .text = "descriptor outcome is unknown" });
    fake_core.waitCheckpointExportEntered();
    try workbench.drainAgentEvents();
    var snapshot: [128 * 1024]u8 = undefined;
    _ = try workbench.writeAggregateFixture(&snapshot);
    persistence.result = .outcome_unknown;
    fake_core.releaseCheckpointExport();

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("fixture-checkpoint", &digest, .{});
    const identity: product_task.checkpoint_store.Identity = .{
        .task_id = task_id,
        .generation = 0,
        .digest = digest,
        .byte_size = "fixture-checkpoint".len,
    };
    var outcome_observed = false;
    for (0..10_000) |_| {
        checkpoint_store.verify(identity) catch {
            std.Thread.yield() catch {};
            continue;
        };
        try workbench.drainAgentEvents();
        const snapshot_json = try workbench.writeAggregateFixture(&snapshot);
        if (std.mem.indexOf(u8, snapshot_json, "\"taskHistoryPersistenceHealth\":\"outcome_unknown\"") != null) {
            outcome_observed = true;
            break;
        }
        std.Thread.yield() catch {};
    }
    try std.testing.expect(outcome_observed);
    try checkpoint_store.verify(identity);
    try std.testing.expectEqual(
        product_task.testing.state_module.ConversationCoverage.pending,
        workbench.task_runtime.tasks[0].?.durable.runs[0].?.coverage,
    );
    try workbench.setTaskArchived(task_id, true);
    try workbench.setTaskArchived(task_id, false);
    try workbench.renameTask(task_id, "Still usable");
    persistence.result = .committed;
    try workbench.renameTask(task_id, "Saved after retry");
    fake_core.setCheckpointGeneration(1);
    const continuation_id = try runPreparedTask(&workbench, task_id, .{
        .text = "continue after unknown descriptor",
    });
    try std.testing.expectEqual(@as(u64, 2), continuation_id);
    try waitSetTaskArchived(&workbench, task_id);
    try workbench.setTaskArchived(task_id, false);
    // Terminal publication precedes the checkpoint worker releasing its
    // lease. Wait for that independently observable completion before asking
    // compact to mutate the same Session.
    for (0..10_000) |_| {
        try workbench.drainAgentEvents();
        if (!workbench.task_runtime.find(task_id).?.runtime.worker_leases.hasLive()) break;
        std.Thread.yield() catch {};
    }
    try std.testing.expect(!workbench.task_runtime.find(task_id).?.runtime.worker_leases.hasLive());
    const compact_id = try workbench.compactTaskAtBinding(task_id, 1);
    try std.testing.expectEqual(@as(u64, 1), compact_id);
    try waitTaskSnapshot(
        &workbench,
        "\"operationId\":\"1\"",
        "\"phase\":\"compacted\"",
    );
    const healed_snapshot = try workbench.writeAggregateFixture(&snapshot);
    try std.testing.expect(std.mem.indexOf(
        u8,
        healed_snapshot,
        "\"taskHistoryPersistenceHealth\":\"ready\"",
    ) != null);

    try workbench.setTaskArchived(task_id, true);
    try workbench.deleteTask(task_id);
    try waitControlSnapshot(&workbench, "\"tasks\":[]");

    workbench.deinit();
    initialized = false;
    try std.testing.expectError(error.BlobMissing, checkpoint_store.verify(identity));
}

test "recovery enqueue failure releases the job lease and remains retryable" {
    fake_core.reset();
    fake_core.setCheckpointGeneration(1);
    const home = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(home);
    var checkpoint_tmp = std.testing.tmpDir(.{});
    defer checkpoint_tmp.cleanup();
    var checkpoint_root_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const checkpoint_root_len = try checkpoint_tmp.dir.realPath(
        std.testing.io,
        &checkpoint_root_storage,
    );
    var checkpoint_store = try product_task.checkpoint_store.FileStore.init(
        std.testing.io,
        checkpoint_root_storage[0..checkpoint_root_len],
    );
    defer checkpoint_store.deinit();
    const persistence_storage = try std.testing.allocator.alloc(
        u8,
        product_task.history.max_store_bytes,
    );
    defer std.testing.allocator.free(persistence_storage);
    var persistence = TaskPersistenceProbe{ .storage = persistence_storage };

    var runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
    });
    var runtime_live = true;
    defer if (runtime_live) {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    };
    var first_configuration = productControlConfiguration();
    first_configuration.directories.canonical_user_home = home;
    first_configuration.task_persistence = persistence.capability();
    first_configuration.checkpoint_store = .{ .file_store = &checkpoint_store };
    var first = try product_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 1,
            .max_workspaces = 1,
            .max_tasks = 1,
            .max_runs_per_task = 1,
            .max_tools_per_run = 1,
        },
        first_configuration,
    );
    var first_live = true;
    defer if (first_live) first.deinit();
    try installControlExecution(&first);
    const task_id = try first.createTask(productControlTaskInput(), try product_control.TestSupport.fixtureModelSelection(&first));
    _ = try runPreparedTask(&first, task_id, .{ .text = "prepare recovery queue failure" });
    try waitCheckpointRecord(&first, &persistence);
    const restart_history = try std.testing.allocator.dupe(
        u8,
        persistence_storage[0..persistence.len],
    );
    defer std.testing.allocator.free(restart_history);
    first.shutdownExecutor();
    first.deinit();
    first_live = false;
    try shutdownTestComposition(runtime);
    deinitTestComposition(runtime);
    runtime_live = false;

    fake_core.lock();
    fake_core.session_created = 0;
    fake_core.checkpoint_restores = 0;
    fake_core.restore_last_run_id = 1;
    fake_core.restore_last_compact_id = 0;
    fake_core.unlock();
    runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 3,
    });
    runtime_live = true;
    var restart_configuration = productControlConfiguration();
    restart_configuration.directories.canonical_user_home = home;
    restart_configuration.task_persistence = persistence.capabilityRestored(restart_history);
    restart_configuration.checkpoint_store = .{ .file_store = &checkpoint_store };
    var restored = try product_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 1,
            .max_workspaces = 1,
            .max_tasks = 3,
            .max_runs_per_task = 1,
            .max_tools_per_run = 1,
        },
        restart_configuration,
    );
    defer restored.deinit();
    try installControlExecution(&restored);
    const workspace_id = try restored.openWorkspace(productControlTaskInput());
    const blocker_one = try restored.createTask(productControlTaskInput(), try product_control.TestSupport.fixtureModelSelection(&restored));
    const blocker_two = try restored.createTask(productControlTaskInput(), try product_control.TestSupport.fixtureModelSelection(&restored));
    try restored.renameTask(blocker_one, "restore blocker one");
    try restored.renameTask(blocker_two, "restore blocker two");
    // Begin the second command's catalog preparation while the worker is free.
    try std.testing.expectError(error.CatalogLoading, restored.runTask(blocker_two, .{ .text = "fill recovery queue" }));
    try settleWorkspaceSkillQueries(&restored, workspace_id);
    fake_core.setSessionPlan(.controlled);
    fake_core.rearmControlled();
    var blockers_released = false;
    defer if (!blockers_released) fake_core.releaseControlled();
    _ = try runPreparedTask(&restored, blocker_one, .{ .text = "occupy recovery worker" });
    try waitTaskSnapshot(
        &restored,
        "\"title\":\"restore blocker one\"",
        "\"currentRunPhase\":\"running\"",
    );
    _ = try runPreparedTask(&restored, blocker_two, .{ .text = "fill recovery queue" });

    const revision_before_rejection = restored.currentRevision();
    try std.testing.expectError(
        error.QueueFull,
        restored.restoreTaskConversation(
            task_id,
            try restored.taskBindingEpoch(task_id),
        ),
    );
    try std.testing.expectEqual(revision_before_rejection, restored.currentRevision());
    const recovered_task = restored.task_runtime.tasks[0].?;
    try std.testing.expectEqual(task_id, recovered_task.durable.id);
    try std.testing.expect(recovered_task.runtime.active_operation == .none);
    try std.testing.expect(recovered_task.runtime.restore_job == null);
    try std.testing.expectEqual(
        @as(usize, 0),
        recovered_task.runtime.worker_leases.liveCount(),
    );

    fake_core.releaseControlled();
    blockers_released = true;
    try waitTaskSnapshot(
        &restored,
        "\"title\":\"restore blocker two\"",
        "\"terminal\":{\"outcome\":\"completed\"",
    );
    try std.testing.expectEqual(
        workspace_id,
        try restored.taskWorkspaceId(task_id),
    );
    _ = try restored.restoreTaskConversation(
        task_id,
        try restored.taskBindingEpoch(task_id),
    );
    try waitTaskSnapshot(
        &restored,
        "\"id\":\"1\"",
        "\"continuationAvailable\":true",
    );
}

test "terminal drain candidate restarts without a stale active operation" {
    fake_core.reset();
    const home = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(home);
    const persistence_storage = try std.testing.allocator.alloc(
        u8,
        product_task.history.max_store_bytes,
    );
    defer std.testing.allocator.free(persistence_storage);
    var persistence = TaskPersistenceProbe{ .storage = persistence_storage };
    var runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
    });
    var runtime_live = true;
    defer if (runtime_live) {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    };
    var configuration = productControlConfiguration();
    configuration.directories.canonical_user_home = home;
    configuration.task_persistence = persistence.capability();
    var first = try product_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 1,
            .max_workspaces = 1,
            .max_tasks = 1,
            .max_runs_per_task = 2,
            .max_tools_per_run = 1,
        },
        configuration,
    );
    var first_live = true;
    defer if (first_live) first.deinit();
    try installControlExecution(&first);
    const task_id = try first.createTask(productControlTaskInput(), try product_control.TestSupport.fixtureModelSelection(&first));
    _ = try runPreparedTask(&first, task_id, .{ .text = "persist terminal boundary" });
    const run = &first.task_runtime.tasks[0].?.durable.runs[0].?;
    for (0..10_000) |_| {
        if (product_task.testing.state_module.terminalPayload(run) != null) break;
        std.Thread.yield() catch {};
    } else return error.TestUnexpectedResult;
    try std.testing.expect(!run.event_stream_finalized);
    try first.drainAgentEvents();
    try std.testing.expect(run.event_stream_finalized);
    try std.testing.expect(first.task_runtime.tasks[0].?.runtime.active_operation == .none);
    try std.testing.expect(std.mem.indexOf(
        u8,
        persistence_storage[0..persistence.len],
        "\"phase\":\"completed\"",
    ) != null);
    const terminal_history = try std.testing.allocator.dupe(
        u8,
        persistence_storage[0..persistence.len],
    );
    defer std.testing.allocator.free(terminal_history);

    first.shutdownExecutor();
    first.deinit();
    first_live = false;
    try shutdownTestComposition(runtime);
    deinitTestComposition(runtime);
    runtime_live = false;
    runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
    });
    runtime_live = true;
    var restart_configuration = productControlConfiguration();
    restart_configuration.directories.canonical_user_home = home;
    restart_configuration.task_persistence = persistence.capabilityRestored(terminal_history);
    var restarted = try product_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 1,
            .max_workspaces = 1,
            .max_tasks = 1,
            .max_runs_per_task = 2,
            .max_tools_per_run = 1,
        },
        restart_configuration,
    );
    defer restarted.deinit();
    var snapshot_storage: [128 * 1024]u8 = undefined;
    const snapshot = try restarted.writeAggregateFixture(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"tasks\":[]") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"phase\":\"completed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"activeOperation\":null") != null);
}

test "untrusted Task history preserves checkpoint orphans without blocking a new interactive Task" {
    fake_core.reset();
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_storage);
    var checkpoint_store = try product_task.checkpoint_store.FileStore.init(
        std.testing.io,
        root_storage[0..root_len],
    );
    defer checkpoint_store.deinit();
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("untrusted-history-orphan", &digest, .{});
    const identity = block: {
        var writer = try checkpoint_store.begin(91, 1024);
        defer writer.deinit();
        try writer.write("untrusted-history-orphan");
        break :block try writer.commit(
            7,
            digest,
            "untrusted-history-orphan".len,
        );
    };
    var persistence = TaskPersistenceProbe{};
    var configuration = productControlConfiguration();
    configuration.task_persistence = persistence.capabilityRestored("{");
    configuration.checkpoint_store = .{ .file_store = &checkpoint_store };
    var workbench = try product_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 1,
            .max_tasks = 1,
            .max_runs_per_task = 1,
            .max_tools_per_run = 1,
        },
        configuration,
    );
    defer workbench.deinit();
    var snapshot_storage: [128 * 1024]u8 = undefined;
    const snapshot = try workbench.writeAggregateFixture(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(
        u8,
        snapshot,
        "\"taskHistoryPersistenceHealth\":\"corrupt\"",
    ) != null);
    try checkpoint_store.verify(identity);
    try installControlExecution(&workbench);
    const task_id = try workbench.createTask(productControlTaskInput(), try product_control.TestSupport.fixtureModelSelection(&workbench));
    _ = try runPreparedTask(&workbench, task_id, .{ .text = "Continue without saved history" });
    try waitControlSnapshot(&workbench, "\"terminal\":{\"outcome\":\"completed\"");
    const continued = try workbench.writeAggregateFixture(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(
        u8,
        continued,
        "\"taskHistoryPersistenceHealth\":\"corrupt\"",
    ) != null);
    try checkpoint_store.verify(identity);
}

test "unavailable checkpoint store does not close Task admission" {
    fake_core.reset();
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var configuration = productControlConfiguration();
    configuration.checkpoint_store = .{ .open_failed = true };
    var workbench = try product_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 1,
            .max_tasks = 1,
            .max_runs_per_task = 1,
            .max_tools_per_run = 1,
        },
        configuration,
    );
    defer workbench.deinit();
    try std.testing.expectEqual(
        product_task.checkpoint_store.Health.unavailable,
        workbench.checkpointStoreHealth(),
    );
    try installControlExecution(&workbench);
    const task_id = try workbench.createTask(productControlTaskInput(), try product_control.TestSupport.fixtureModelSelection(&workbench));
    _ = try runPreparedTask(&workbench, task_id, .{ .text = "checkpoint store unavailable" });
    try waitControlSnapshot(&workbench, "\"terminal\":{\"outcome\":\"completed\"");
    try std.testing.expectEqual(@as(usize, 1), fake_core.session_created);
    try std.testing.expectEqual(@as(usize, 0), fake_core.checkpoint_exports);
}

fn waitCatalogUnavailable(
    workbench: *product_control.Runtime,
    workspace_id: u64,
) !void {
    for (0..10_000) |_| {
        try workbench.drainAgentEvents();
        const projection = try workbench.workspaceCatalog(workspace_id);
        switch (projection.availability) {
            .unavailable => return,
            .uninitialized, .loading => std.Thread.yield() catch {},
            .ready, .degraded => return error.TestUnexpectedResult,
        }
    }
    return error.TestUnexpectedResult;
}

fn directoryEntryCount(dir: std.Io.Dir) !usize {
    const iterable = try dir.openDir(
        std.testing.io,
        ".",
        .{ .iterate = true, .follow_symlinks = false },
    );
    defer iterable.close(std.testing.io);
    var iterator = iterable.iterate();
    var count: usize = 0;
    while (try iterator.next(std.testing.io) != null) count += 1;
    return count;
}

const TestScheduleSupport = struct {
    now: u64 = 1_000,
    commit_result: product_control.SchedulePersistenceCommit = .committed,
    commits: usize = 0,
    recoveries: usize = 0,
    notification_kind: ?product_control.ScheduleNotificationKind = null,
    notification_task_id: u64 = 0,

    fn nowUnixSeconds(context: ?*anyopaque) ?u64 {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        return self.now;
    }

    fn arm(_: ?*anyopaque, _: u64) bool {
        return true;
    }

    fn cancel(_: ?*anyopaque) void {}

    fn commit(
        context: ?*anyopaque,
        bytes: []const u8,
    ) product_control.SchedulePersistenceCommit {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        std.debug.assert(bytes.len != 0);
        self.commits += 1;
        return self.commit_result;
    }

    fn recover(
        context: ?*anyopaque,
        bytes: []const u8,
    ) product_control.SchedulePersistenceCommit {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.recoveries += 1;
        return commit(context, bytes);
    }

    fn timer(self: *@This()) product_control.ScheduleTimer {
        return .{
            .context = self,
            .enabled = true,
            .now_unix_seconds = nowUnixSeconds,
            .arm = arm,
            .cancel = cancel,
        };
    }

    fn persistence(self: *@This()) product_control.SchedulePersistence {
        return .{
            .context = self,
            .enabled = true,
            .commit_fn = commit,
            .recover_fn = recover,
        };
    }

    fn persistenceRestored(
        self: *@This(),
        restored_bytes: []const u8,
    ) product_control.SchedulePersistence {
        var result = self.persistence();
        result.restored_bytes = restored_bytes;
        return result;
    }

    fn notify(
        context: ?*anyopaque,
        notification: product_control.ScheduleNotification,
    ) bool {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.notification_kind = notification.kind;
        self.notification_task_id = notification.task_id;
        return true;
    }

    fn notifier(self: *@This()) product_control.ScheduleNotifier {
        return .{
            .context = self,
            .enabled = true,
            .notify_fn = notify,
        };
    }
};

test "retired Schedule data starts empty without locking interactive Task creation" {
    for ([_]product_control.SchedulePersistenceCommit{ .committed, .failed, .outcome_unknown }) |recovery| {
        fake_core.reset();
        const runtime = try createTestComposition(.{
            .worker_count = 1,
            .queue_capacity = 1,
            .max_sessions = 1,
        });
        defer {
            shutdownTestComposition(runtime) catch unreachable;
            deinitTestComposition(runtime);
        }
        var schedule_support: TestScheduleSupport = .{ .commit_result = recovery };
        const retired_schedule =
            "{\"schema_version\":1,\"next_id\":2,\"items\":[{\"id\":1,\"epoch\":1,\"title\":\"retired provider\",\"execution_generation\":1,\"execution_provider\":\"openai\",\"execution_model\":\"gpt-test\",\"permission_profile\":\"approval_required\",\"input\":{\"kind\":\"text\",\"text\":\"inspect\"},\"recurrence\":{\"kind\":\"once\",\"at_unix_seconds\":2},\"enabled\":true,\"health\":\"ready\",\"failure_reason\":null,\"next_run_at_unix_seconds\":2,\"occurrences\":[]}]}";
        var configuration = productControlConfiguration();
        configuration.schedule_persistence = schedule_support.persistenceRestored(retired_schedule);
        var workbench = try product_control.Runtime.init(
            std.testing.allocator,
            std.testing.io,
            runtime,
            .{
                .worker_count = 1,
                .queue_capacity = 1,
                .max_tasks = 1,
                .max_scheduled_tasks = 1,
                .max_runs_per_task = 1,
                .max_tools_per_run = 1,
            },
            configuration,
        );
        defer workbench.deinit();

        try installControlExecution(&workbench);
        try account_contract.validateView(workbench.accountView());
        try std.testing.expect(workbench.newTaskAdmissionView().available);
        try std.testing.expectEqual(switch (recovery) {
            .committed => product_control.SchedulePersistenceHealth.ready,
            .failed => .write_failed,
            .outcome_unknown => .outcome_unknown,
        }, workbench.schedule.persistenceHealth());
        try std.testing.expectEqual(@as(usize, 1), schedule_support.recoveries);
        const commits_before = schedule_support.commits;
        const task_id = try workbench.createTask(productControlTaskInput(), try product_control.TestSupport.fixtureModelSelection(&workbench));
        try std.testing.expect(task_id != 0);
        try std.testing.expectEqual(commits_before, schedule_support.commits);
        for (workbench.schedule.store.items) |item| try std.testing.expect(item == null);
    }
}

test "scheduled noninteractive permission request automatically stops the Product Run" {
    fake_core.reset();
    fake_core.setNextPlan(.ui_wait);
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_storage);
    var automatic_root = try product_control.AutomaticWorkspaceRoot.open(
        std.testing.io,
        std.testing.allocator,
        root_storage[0..root_len],
    );
    defer automatic_root.deinit();
    var schedule_support: TestScheduleSupport = .{};
    var task_persistence: TaskPersistenceProbe = .{};
    var workbench = try product_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 1,
            .max_workspaces = 1,
            .max_tasks = 1,
            .max_scheduled_tasks = 1,
            .max_runs_per_task = 1,
            .max_tools_per_run = 1,
        },
        .{
            .directories = .{ .testing_automatic_workspace_root = &automatic_root },
            .schedule_timer = schedule_support.timer(),
            .schedule_persistence = schedule_support.persistence(),
            .schedule_notifier = schedule_support.notifier(),
            .task_persistence = task_persistence.capability(),
        },
    );
    defer workbench.deinit();
    var image: ImageAdmissionProbe = .{};
    workbench.setImageRunPreparation(.{ .context = &image, .prepare_fn = ImageAdmissionProbe.prepare });
    defer workbench.setImageRunPreparation(null);
    try installControlExecution(&workbench);

    const schedule_id = try workbench.createScheduledTask(.{
        .title = "Permission boundary",
        .model_selection = try product_control.TestSupport.fixtureModelSelection(&workbench),
        .permission_profile = .approval_required,
        .input = "Perform an operation requiring permission",
        .recurrence = .{ .once = .{ .at_unix_seconds = 2_000 } },
    });
    const task_id = try workbench.runScheduledTaskNow(schedule_id, 1);
    try std.testing.expectEqual(
        product_control.PermissionProfile.approval_required,
        workbench.defaultPermissionProfile(),
    );

    for (0..10_000) |_| {
        fake_core.lock();
        const callback_seen = fake_core.ui_unavailable_callbacks == 1;
        fake_core.unlock();
        if (callback_seen) break;
        std.Thread.yield() catch {};
    } else return error.TestUnexpectedResult;
    // This is the production wake consumer. The first abort must not depend
    // on writeSnapshot/currentRevision or on a connected Renderer.
    try workbench.drainAgentEvents();
    fake_core.lock();
    const abort_calls_after_drain = fake_core.abort_calls;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), abort_calls_after_drain);

    try waitControlSnapshot(&workbench, "\"terminal\":{\"outcome\":\"stopped\"");
    var snapshot_storage: [128 * 1024]u8 = undefined;
    const snapshot = try workbench.writeAggregateFixture(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(
        u8,
        snapshot,
        "\"terminal\":{\"outcome\":\"stopped\",\"cause\":\"permission_required\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        snapshot,
        "\"health\":\"needs_attention\",\"failureReason\":\"permission_required\"",
    ) != null);
    try std.testing.expectEqual(
        @as(?product_control.ScheduleNotificationKind, .needs_attention),
        schedule_support.notification_kind,
    );
    try std.testing.expectEqual(task_id, schedule_support.notification_task_id);
    for (0..5000) |_| {
        try workbench.drainAgentEvents();
        if (image.released == 1) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    const task = workbench.task_runtime.find(task_id).?;
    try std.testing.expectEqual(@as(usize, 1), image.calls);
    try std.testing.expectEqual(@as(usize, 1), image.released);
    try std.testing.expectEqual(task.durable.workspace_id, image.workspace_id);
    try std.testing.expectEqual(task.durable.workspace_epoch, image.workspace_epoch);
    try std.testing.expect(task.durable.runs[0].?.image_execution == null);
}

test "scheduled admission rejects an unconfigured Task persistence capability" {
    fake_core.reset();
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_storage);
    var automatic_root = try product_control.AutomaticWorkspaceRoot.open(
        std.testing.io,
        std.testing.allocator,
        root_storage[0..root_len],
    );
    defer automatic_root.deinit();
    var schedule_support: TestScheduleSupport = .{};
    var workbench = try product_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 1,
            .max_workspaces = 1,
            .max_tasks = 1,
            .max_scheduled_tasks = 1,
            .max_runs_per_task = 1,
            .max_tools_per_run = 1,
        },
        .{
            .directories = .{ .testing_automatic_workspace_root = &automatic_root },
            .schedule_timer = schedule_support.timer(),
            .schedule_persistence = schedule_support.persistence(),
        },
    );
    defer workbench.deinit();
    try installControlExecution(&workbench);

    const schedule_id = try workbench.createScheduledTask(.{
        .title = "Required durability",
        .model_selection = try product_control.TestSupport.fixtureModelSelection(&workbench),
        .permission_profile = .approval_required,
        .input = "Do not run without durable Task history",
        .recurrence = .{ .once = .{ .at_unix_seconds = 2_000 } },
    });
    try std.testing.expectError(
        error.TaskPersistenceFailed,
        workbench.runScheduledTaskNow(schedule_id, 1),
    );

    fake_core.lock();
    const run_calls = fake_core.run_calls;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 0), run_calls);
    try std.testing.expectEqual(@as(usize, 0), try directoryEntryCount(tmp.dir));
    var snapshot_storage: [128 * 1024]u8 = undefined;
    const snapshot = try workbench.writeAggregateFixture(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(
        u8,
        snapshot,
        "\"health\":\"needs_attention\",\"failureReason\":\"task_start_failed\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"tasks\":[]") != null);
}

test "scheduled durable admission failure does not block an interactive Product Task" {
    fake_core.reset();
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 2,
        .max_sessions = 2,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_storage);
    var automatic_root = try product_control.AutomaticWorkspaceRoot.open(
        std.testing.io,
        std.testing.allocator,
        root_storage[0..root_len],
    );
    defer automatic_root.deinit();
    var schedule_support: TestScheduleSupport = .{};
    var task_persistence: TaskPersistenceProbe = .{ .result = .failed };
    var workbench = try product_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 2,
            .max_workspaces = 1,
            .max_tasks = 2,
            .max_scheduled_tasks = 1,
            .max_runs_per_task = 1,
            .max_tools_per_run = 1,
        },
        .{
            .directories = .{ .testing_automatic_workspace_root = &automatic_root },
            .schedule_timer = schedule_support.timer(),
            .schedule_persistence = schedule_support.persistence(),
            .schedule_notifier = schedule_support.notifier(),
            .task_persistence = task_persistence.capability(),
        },
    );
    defer workbench.deinit();
    try installControlExecution(&workbench);

    const schedule_id = try workbench.createScheduledTask(.{
        .title = "Durable automatic run",
        .model_selection = try product_control.TestSupport.fixtureModelSelection(&workbench),
        .permission_profile = .approval_required,
        .input = "Run only after durable admission",
        .recurrence = .{ .once = .{ .at_unix_seconds = 2_000 } },
    });
    try std.testing.expectError(
        error.TaskPersistenceFailed,
        workbench.runScheduledTaskNow(schedule_id, 1),
    );

    var snapshot_storage: [128 * 1024]u8 = undefined;
    const rejected = try workbench.writeAggregateFixture(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(
        u8,
        rejected,
        "\"health\":\"needs_attention\",\"failureReason\":\"task_start_failed\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, rejected, "\"tasks\":[]") != null);

    const task_id = try workbench.createTaskForWorkspace(.automatic, try product_control.TestSupport.fixtureModelSelection(&workbench), null, null, .{ .interactive = null });
    _ = try runPreparedTask(&workbench, task_id, .{ .text = "Continue interactively" });
    try waitControlSnapshot(&workbench, "\"terminal\":{\"outcome\":\"completed\"");
    const continued = try workbench.writeAggregateFixture(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(
        u8,
        continued,
        "\"taskHistoryPersistenceHealth\":\"write_failed\"",
    ) != null);
}

fn expectScheduledAdmissionOutcomeUnknownRecovery(store_candidate: bool) !void {
    fake_core.reset();
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_storage);
    var automatic_root = try product_control.AutomaticWorkspaceRoot.open(
        std.testing.io,
        std.testing.allocator,
        root_storage[0..root_len],
    );
    defer automatic_root.deinit();
    var schedule_support: TestScheduleSupport = .{};
    const persisted_storage = try std.testing.allocator.alloc(
        u8,
        product_task.history.max_store_bytes,
    );
    defer std.testing.allocator.free(persisted_storage);
    var task_persistence: TaskPersistenceProbe = .{
        .result = .outcome_unknown,
        .store_on_outcome_unknown = store_candidate,
        .storage = persisted_storage,
    };
    var workbench = try product_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 1,
            .max_workspaces = 1,
            .max_tasks = 1,
            .max_scheduled_tasks = 1,
            .max_runs_per_task = 1,
            .max_tools_per_run = 1,
        },
        .{
            .directories = .{ .testing_automatic_workspace_root = &automatic_root },
            .schedule_timer = schedule_support.timer(),
            .schedule_persistence = schedule_support.persistence(),
            .task_persistence = task_persistence.capability(),
        },
    );
    var workbench_live = true;
    defer if (workbench_live) workbench.deinit();
    try installControlExecution(&workbench);

    const schedule_id = try workbench.createScheduledTask(.{
        .title = "Unknown durable admission",
        .model_selection = try product_control.TestSupport.fixtureModelSelection(&workbench),
        .permission_profile = .approval_required,
        .input = "Do not enqueue an uncertain admission",
        .recurrence = .{ .once = .{ .at_unix_seconds = 2_000 } },
    });
    try std.testing.expectError(
        error.TaskPersistenceOutcomeUnknown,
        workbench.runScheduledTaskNow(schedule_id, 1),
    );

    fake_core.lock();
    const run_calls = fake_core.run_calls;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 0), run_calls);
    try std.testing.expectEqual(@as(usize, 1), try directoryEntryCount(tmp.dir));
    var snapshot_storage: [128 * 1024]u8 = undefined;
    const unknown_snapshot = try workbench.writeAggregateFixture(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(
        u8,
        unknown_snapshot,
        "\"taskHistoryPersistenceHealth\":\"outcome_unknown\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, unknown_snapshot, "\"tasks\":[]") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        unknown_snapshot,
        "\"result\":\"rejected\",\"taskId\":null,\"reason\":\"task_start_failed\"",
    ) != null);
    if (store_candidate) {
        try std.testing.expect(task_persistence.len > 0);
        try std.testing.expect(std.mem.indexOf(
            u8,
            persisted_storage[0..task_persistence.len],
            "Unknown durable admission",
        ) != null);
    } else {
        try std.testing.expectEqual(@as(usize, 0), task_persistence.len);
    }
    const landed_history = if (store_candidate)
        try std.testing.allocator.dupe(
            u8,
            persisted_storage[0..task_persistence.len],
        )
    else
        null;
    defer if (landed_history) |bytes| std.testing.allocator.free(bytes);

    workbench.deinit();
    workbench_live = false;

    task_persistence.result = .committed;
    var restored_automatic_root = try product_control.AutomaticWorkspaceRoot.open(
        std.testing.io,
        std.testing.allocator,
        root_storage[0..root_len],
    );
    defer restored_automatic_root.deinit();
    var restart_configuration = productControlConfiguration();
    restart_configuration.directories.testing_automatic_workspace_root = &restored_automatic_root;
    restart_configuration.task_persistence = if (store_candidate)
        task_persistence.capabilityRestored(landed_history.?)
    else
        task_persistence.capability();
    var restarted = try product_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 1,
            .max_workspaces = 1,
            .max_tasks = 1,
            .max_scheduled_tasks = 1,
            .max_runs_per_task = 1,
            .max_tools_per_run = 1,
        },
        restart_configuration,
    );
    defer restarted.deinit();
    const restarted_snapshot = try restarted.writeAggregateFixture(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(
        u8,
        restarted_snapshot,
        "\"taskHistoryPersistenceHealth\":\"ready\"",
    ) != null);
    if (store_candidate) {
        try std.testing.expect(std.mem.indexOf(
            u8,
            restarted_snapshot,
            "Unknown durable admission",
        ) != null);
        try std.testing.expect(std.mem.indexOf(u8, restarted_snapshot, "\"tasks\":[]") == null);
    } else {
        try std.testing.expect(std.mem.indexOf(u8, restarted_snapshot, "\"tasks\":[]") != null);
    }
    try std.testing.expectEqual(@as(usize, 1), try directoryEntryCount(tmp.dir));
}

test "scheduled admission outcome unknown preserves its root across landed and not-landed restarts" {
    try expectScheduledAdmissionOutcomeUnknownRecovery(false);
    try expectScheduledAdmissionOutcomeUnknownRecovery(true);
}

test "interactive Product Task remains accepted when history commit outcome is unknown" {
    fake_core.reset();
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 2,
        .max_sessions = 1,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_storage);
    var automatic_root = try product_control.AutomaticWorkspaceRoot.open(
        std.testing.io,
        std.testing.allocator,
        root_storage[0..root_len],
    );
    defer automatic_root.deinit();
    var task_persistence: TaskPersistenceProbe = .{ .result = .outcome_unknown };
    var workbench = try product_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 2,
            .max_workspaces = 1,
            .max_tasks = 1,
            .max_runs_per_task = 1,
            .max_tools_per_run = 1,
        },
        .{
            .directories = .{ .testing_automatic_workspace_root = &automatic_root },
            .task_persistence = task_persistence.capability(),
        },
    );
    defer workbench.deinit();
    try installControlExecution(&workbench);

    const task_id = try workbench.createTaskForWorkspace(.automatic, try product_control.TestSupport.fixtureModelSelection(&workbench), null, null, .{ .interactive = null });
    _ = try runPreparedTask(&workbench, task_id, .{ .text = "Remain accepted" });
    try waitControlSnapshot(&workbench, "\"terminal\":{\"outcome\":\"completed\"");

    fake_core.lock();
    const run_calls = fake_core.run_calls;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), run_calls);
    var snapshot_storage: [128 * 1024]u8 = undefined;
    const snapshot = try workbench.writeAggregateFixture(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(
        u8,
        snapshot,
        "\"taskHistoryPersistenceHealth\":\"outcome_unknown\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"tasks\":[]") == null);
}

test "Product multimodal admission consumes staging and publishes metadata-only history" {
    fake_core.reset();
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 2,
        .max_sessions = 1,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_storage);
    var automatic_root = try product_control.AutomaticWorkspaceRoot.open(
        std.testing.io,
        std.testing.allocator,
        root_storage[0..root_len],
    );
    defer automatic_root.deinit();
    var attachment_store = try product_control.AttachmentFileStore.init(std.testing.io, std.testing.allocator, root_storage[0..root_len]);
    defer attachment_store.deinit();
    var workbench = try product_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 2,
            .max_workspaces = 1,
            .max_tasks = 1,
            .max_runs_per_task = 3,
            .max_tools_per_run = 1,
        },
        .{ .attachment_store = &attachment_store, .attachment_images = .{ .prepare_fn = fixture.prepareTestAttachmentImage }, .directories = .{ .testing_automatic_workspace_root = &automatic_root } },
    );
    defer workbench.deinit();
    try installControlExecution(&workbench);

    const candidates = [_]product_control.AttachmentCandidate{
        .{ .display_name = "diagram.png", .bytes = "\x89PNG\r\n\x1a\nbody" },
        .{ .display_name = "brief.webp", .bytes = "RIFFxxxxWEBPbody" },
    };
    var descriptor_storage: [2]product_control.AttachmentDescriptor = undefined;
    const descriptors = try workbench.stageAttachments(&candidates, &descriptor_storage);
    const ids = [_]u64{ descriptors[0].id, descriptors[1].id };
    const Acceptance = struct {
        count: usize = 0,
        fn accept(context: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.count += 1;
        }
    };
    var acceptance = Acceptance{};
    const task_id = try workbench.createTaskForWorkspace(.automatic, try product_control.TestSupport.fixtureModelSelection(&workbench), null, null, .{ .interactive = null });
    _ = try runPreparedTask(&workbench, task_id, .{ .multimodal = .{
        .text = "Compare these",
        .attachment_ids = &ids,
        .acceptance = .{ .context = &acceptance, .accept_fn = Acceptance.accept },
    } });
    try std.testing.expectEqual(@as(usize, 1), acceptance.count);
    try std.testing.expect(!workbench.releaseAttachment(ids[0]));
    try std.testing.expect(!workbench.releaseAttachment(ids[1]));
    try waitControlSnapshot(&workbench, "\"terminal\":{\"outcome\":\"completed\"");

    var snapshot_storage: [128 * 1024]u8 = undefined;
    const snapshot = try workbench.writeAggregateFixture(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(
        u8,
        snapshot,
        "\"input\":{\"kind\":\"multimodal\",\"text\":\"Compare these\",\"attachments\":[{\"kind\":\"image\",\"format\":\"png\",\"displayName\":\"diagram.png\",\"sizeBytes\":\"12\",\"redacted\":false},{\"kind\":\"image\",\"format\":\"webp\",\"displayName\":\"brief.webp\",\"sizeBytes\":\"16\",\"redacted\":false}],\"redacted\":false}",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "attachmentTokens") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "PNG\\r\\n") == null);

    const pure_media = [_]product_control.AttachmentCandidate{.{
        .display_name = "photo.jpg",
        .bytes = "\xff\xd8\xffbody",
    }};
    var pure_descriptor_storage: [1]product_control.AttachmentDescriptor = undefined;
    const pure_descriptors = try workbench.stageAttachments(
        &pure_media,
        &pure_descriptor_storage,
    );
    const pure_ids = [_]u64{pure_descriptors[0].id};
    const pure_run_id = try runPreparedTask(&workbench, task_id, .{ .multimodal = .{
        .text = "",
        .attachment_ids = &pure_ids,
    } });
    var terminal_needle: [96]u8 = undefined;
    const terminal = try std.fmt.bufPrint(
        &terminal_needle,
        "\"id\":\"{d}\",\"conversationCoverage\":\"included\",\"phase\":\"completed\"",
        .{pure_run_id},
    );
    try waitControlSnapshot(&workbench, terminal);
    const pure_snapshot = try workbench.writeAggregateFixture(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(
        u8,
        pure_snapshot,
        "\"input\":{\"kind\":\"multimodal\",\"text\":null,\"attachments\":[{\"kind\":\"image\",\"format\":\"jpeg\",\"displayName\":\"photo.jpg\",\"sizeBytes\":\"7\",\"redacted\":false}],\"redacted\":false}",
    ) != null);

    const text_files = [_]product_control.AttachmentCandidate{.{
        .display_name = "report.docx",
        .bytes = "PK\x03\x04\x00\xffbinary",
    }};
    var text_descriptor_storage: [1]product_control.AttachmentDescriptor = undefined;
    const text_descriptors = try workbench.stageAttachments(
        &text_files,
        &text_descriptor_storage,
    );
    const text_ids = [_]u64{text_descriptors[0].id};
    try std.testing.expectError(error.MissingInstruction, workbench.runTask(task_id, .{
        .multimodal = .{ .text = " \r\n", .attachment_ids = &text_ids },
    }));
    try std.testing.expect(workbench.releaseAttachment(text_ids[0]));

    const retry_descriptors = try workbench.stageAttachments(
        &text_files,
        &text_descriptor_storage,
    );
    const retry_ids = [_]u64{retry_descriptors[0].id};
    const text_run_id = try runPreparedTask(&workbench, task_id, .{ .multimodal = .{
        .text = "Summarize this file",
        .attachment_ids = &retry_ids,
    } });
    const text_terminal = try std.fmt.bufPrint(
        &terminal_needle,
        "\"id\":\"{d}\",\"conversationCoverage\":\"included\",\"phase\":\"completed\"",
        .{text_run_id},
    );
    try waitControlSnapshot(&workbench, text_terminal);
    const text_snapshot = try workbench.writeAggregateFixture(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text_snapshot,
        "\"input\":{\"kind\":\"multimodal\",\"text\":\"Summarize this file\",\"attachments\":[{\"kind\":\"file\",\"displayName\":\"report.docx\",\"sizeBytes\":\"12\",\"redacted\":false}],\"redacted\":false}",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, text_snapshot, "PK\x03\x04\x00\xffbinary") == null);
    try std.testing.expect(!workbench.releaseAttachment(retry_ids[0]));
}

test "bounded executor rejects overflow and close cancels a queued Run" {
    fake_core.reset();
    fake_core.setNextPlan(.controlled);
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 3 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const running = try openSession(runtime);
    const queued = try openSession(runtime);
    const rejected = try openSession(runtime);

    const running_id = try submitSession(running, "hold worker");
    try running.waitForState(.running);
    while (true) {
        fake_core.lock();
        const entered_agent = fake_core.run_calls == 1;
        fake_core.unlock();
        if (entered_agent) break;
        std.Thread.yield() catch {};
    }
    _ = try submitSession(queued, "stay queued");
    try std.testing.expectError(error.SessionNotIdle, submitSession(queued, "second in-flight"));
    try std.testing.expectError(error.QueueFull, submitSession(rejected, "overflow"));
    try std.testing.expectEqual(lifecycle.SessionState.idle, rejected.snapshot().state);

    try closeSession(queued, .session_close);
    const queued_snapshot = queued.snapshot();
    try std.testing.expectEqual(lifecycle.SessionState.closed, queued_snapshot.state);
    fake_core.lock();
    const calls_before_release = fake_core.run_calls;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), calls_before_release);

    fake_core.releaseControlled();
    try running.waitRun(running_id);
    try closeSession(running, .session_close);
    try closeSession(rejected, .session_close);
}

test "new accepted input does not inherit an abandoned direct Run preparation" {
    fake_core.reset();
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 2, .max_sessions = 1 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);
    var enablement_store = try product_skill.enablement.FileStore.init(std.testing.io, home);
    defer enablement_store.deinit();
    var configuration = productControlConfiguration();
    configuration.directories.canonical_user_home = home;
    configuration.skill_enablement = .{ .file_store = &enablement_store };
    var workbench = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, .{
        .worker_count = 1,
        .queue_capacity = 2,
        .max_workspaces = 1,
        .max_tasks = 1,
        .max_runs_per_task = 1,
    }, configuration);
    defer workbench.deinit();
    try installControlExecution(&workbench);
    const workspace_id = try workbench.openWorkspace(productControlTaskInput());
    _ = try waitCatalogReady(&workbench, workspace_id);
    const task_id = try workbench.createTaskInWorkspace(workspace_id, try workbench.workspaceEpoch(workspace_id), try product_control.TestSupport.fixtureModelSelection(&workbench), null, null, .{ .interactive = null });
    var probe: WorkspaceSkillQueryProbe = .{};
    probe.attach(&workbench);
    defer probe.hold_queries.store(false, .release);

    // A synchronous caller can leave after catalog_loading without retrying.
    try std.testing.expectError(error.CatalogLoading, workbench.runTask(task_id, .{ .text = "abandoned request" }));
    try settleWorkspaceSkillQueries(&workbench, workspace_id);
    try probe.expectQueries(1);
    try std.testing.expect(workbench.task_runtime.find(task_id).?.skill_preparation != null);

    // The later message is a separate intent, possibly after files changed.
    // Hold its fresh query to prove admission cannot use the earlier result.
    probe.hold_queries.store(true, .release);
    const result = try workbench.sendInput("independent-message", task_id, .{ .text = "new request" });
    try std.testing.expectEqual(.accepted, result.outcome);
    const task = workbench.task_runtime.find(task_id).?;
    try std.testing.expect(task.durable.runs[0] == null);
    try std.testing.expectEqual(.waiting, task.input_submissions.items[0].state);
    probe.hold_queries.store(false, .release);
    try waitControlSnapshot(&workbench, "\"terminal\":{\"outcome\":\"completed\"");
    try settleWorkspaceSkillQueries(&workbench, workspace_id);
    try probe.expectQueries(2);
    try std.testing.expectEqual(@as(usize, 1), fake_core.run_calls);
}

test "Skill input is accepted once while fresh preparation waits and failed freshness withdraws grants" {
    fake_core.reset();
    fake_core.setCatalogPlan(.degraded);
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 2,
        .max_sessions = 1,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const home = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(home);
    var skill_enablement_store = try product_skill.enablement.FileStore.init(
        std.testing.io,
        home,
    );
    defer skill_enablement_store.deinit();
    var workbench = try product_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 2,
            .max_workspaces = 1,
            .max_tasks = 1,
            .max_runs_per_task = 3,
            .max_tools_per_run = 1,
        },
        .{
            .directories = .{ .canonical_user_home = home },
            .skill_enablement = .{ .file_store = &skill_enablement_store },
            .skill_sources = .{ .restored = .{ .loaded = .{ .ready = .{} } } },
        },
    );
    defer workbench.deinit();
    try installControlExecution(&workbench);

    const workspace_id = try workbench.openWorkspace(productControlTaskInput());
    const catalog = try waitCatalogReady(&workbench, workspace_id);
    try std.testing.expectEqual(product_control.CatalogAvailability.degraded, catalog.availability);
    try std.testing.expectEqual(@as(usize, 1), catalog.issues.len);
    try std.testing.expectEqualStrings(
        fixture.fixture_catalog_revision,
        catalog.revision,
    );
    try std.testing.expectEqualStrings(
        "review",
        catalog.skills[0].invocation_name,
    );
    const task_id = try workbench.createTaskInWorkspace(workspace_id, try workbench.workspaceEpoch(workspace_id), try product_control.TestSupport.fixtureModelSelection(&workbench), catalog.revision, catalog.selection_revision, .{ .interactive = null });
    const task_catalog = try workbench.taskCatalog(task_id);
    try std.testing.expectEqualStrings(catalog.revision, task_catalog.revision);
    var probe: WorkspaceSkillQueryProbe = .{};
    probe.attach(&workbench);
    probe.hold_queries.store(true, .release);
    defer probe.hold_queries.store(false, .release);
    const accepted = try workbench.sendInput("fresh-skill", task_id, .{ .skill = .{
        .skill_id = fixture.fixture_skill_id,
        .catalog_revision = catalog.revision,
        .selection_revision = catalog.selection_revision.?,
        .argument_values = &.{ "src/main.zig", "correctness" },
    } });
    try std.testing.expectEqual(.accepted, accepted.outcome);
    const task = workbench.task_runtime.find(task_id).?;
    try std.testing.expectEqual(@as(usize, 1), task.input_submissions.items.len);
    try std.testing.expectEqual(.waiting, task.input_submissions.items[0].state);
    try std.testing.expectEqual(@as(usize, 0), fake_core.run_calls);
    probe.hold_queries.store(false, .release);
    try waitControlSnapshot(&workbench, "\"terminal\":{\"outcome\":\"completed\"");
    try waitControlSnapshot(
        &workbench,
        "\"skillCatalog\":{\"availability\":\"degraded\"",
    );
    try waitControlSnapshot(
        &workbench,
        "\"input\":{\"kind\":\"skill\"",
    );
    try waitControlSnapshot(&workbench, "\"title\":\"Review\"");
    var skill_title_snapshot: [128 * 1024]u8 = undefined;
    const skill_title_snapshot_bytes = try workbench.writeAggregateFixture(&skill_title_snapshot);
    try std.testing.expect(
        std.mem.indexOf(u8, skill_title_snapshot_bytes, "\"title\":\"Review\"") != null,
    );
    fake_core.lock();
    const skill_seen = fake_core.skill_run_seen;
    const input_matches = fake_core.skill_input_matches;
    fake_core.unlock();
    try std.testing.expect(skill_seen);
    try std.testing.expect(input_matches);
    // The query failure retains a useful chooser view, but grants no execution.
    try settleWorkspaceSkillQueries(&workbench, workspace_id);
    try probe.expectQueries(1);
    try std.testing.expectEqual(@as(usize, 0), fake_core.catalog_refreshes);
    fake_core.setCatalogPlan(.query_failure);
    const visible = try workbench.workspaceCatalog(workspace_id);
    const failed = try workbench.sendInput("unavailable-skill", task_id, .{ .skill = .{
        .skill_id = fixture.fixture_skill_id,
        .catalog_revision = visible.revision,
        .selection_revision = visible.selection_revision.?,
        .argument_values = &.{},
    } });
    try std.testing.expectEqual(.accepted, failed.outcome);
    for (0..5000) |_| {
        try workbench.drainAgentEvents();
        if (task.input_submissions.items.len != 0 and task.input_submissions.items[0].state == .failed) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    } else return error.TestUnexpectedResult;
    try std.testing.expectEqual(.catalog_unavailable, task.input_submissions.items[0].reason.?);
    var access = try task.runtime.acquireAccess();
    var restore_inputs = try access.captureRestoreInputs();
    access.deinit();
    defer restore_inputs.deinit() catch unreachable;
    try std.testing.expectEqual(@as(usize, 0), restore_inputs.skill.?.borrow().policy.granted_skill_ids.len);
    const withdrawn_refreshes = fake_core.catalog_refreshes;
    try std.testing.expectEqual(@as(usize, 1), withdrawn_refreshes);
    const ordinary = try workbench.sendInput("text-without-skills", task_id, .{ .text = "Continue without Skill grants" });
    try std.testing.expectEqual(.accepted, ordinary.outcome);
    for (0..5000) |_| {
        try workbench.drainAgentEvents();
        if (task.durable.runs[1] != null and product_task.testing.state_module.productTerminalFacts(&task.durable.runs[1].?) != null) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    } else return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), fake_core.run_calls);
    // A second failed query still permits text, without rebinding an already
    // empty policy (or adding a second opportunity for Core mutation failure).
    try std.testing.expectEqual(withdrawn_refreshes, fake_core.catalog_refreshes);
}

test "Workspace incomplete catalog refresh preserves the committed last-good authority" {
    fake_core.reset();
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 2,
        .max_sessions = 1,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const home = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(home);
    var skill_enablement_store = try product_skill.enablement.FileStore.init(
        std.testing.io,
        home,
    );
    defer skill_enablement_store.deinit();
    var workbench = try product_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 2,
            .max_workspaces = 1,
            .max_tasks = 1,
            .max_runs_per_task = 1,
            .max_tools_per_run = 1,
        },
        .{
            .directories = .{ .canonical_user_home = home },
            .skill_enablement = .{ .file_store = &skill_enablement_store },
            .skill_sources = .{ .restored = .{ .loaded = .{ .ready = .{} } } },
        },
    );
    defer workbench.deinit();
    try installControlExecution(&workbench);

    const workspace_id = try workbench.openWorkspace(productControlTaskInput());
    const before = try waitCatalogReady(&workbench, workspace_id);
    fake_core.setCatalogPlan(.controlled);
    defer fake_core.releaseCatalogQuery();
    const workspace_epoch = try workbench.workspaceEpoch(workspace_id);
    try workbench.refreshWorkspaceCatalog(workspace_id, workspace_epoch);
    fake_core.waitCatalogQueryEntered();
    const refresh_revision = workbench.currentRevision();
    const refreshing = try workbench.workspaceCatalog(workspace_id);
    try std.testing.expectEqual(product_control.CatalogAvailability.ready, refreshing.availability);
    try std.testing.expectEqualStrings(before.revision, refreshing.revision);
    try std.testing.expectEqual(before.selection_revision, refreshing.selection_revision);

    fake_core.setCatalogPlan(.query_incomplete);
    fake_core.releaseCatalogQuery();
    for (0..10_000) |_| {
        try workbench.drainAgentEvents();
        if (workbench.currentRevision() > refresh_revision) break;
        std.testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
    } else return error.TestUnexpectedResult;

    const after = try workbench.workspaceCatalog(workspace_id);
    try std.testing.expectEqual(product_control.CatalogAvailability.ready, after.availability);
    try std.testing.expectEqualStrings(before.revision, after.revision);
    try std.testing.expectEqual(before.selection_revision, after.selection_revision);
    try std.testing.expectEqual(before.skills.len, after.skills.len);
    try std.testing.expectEqualStrings(before.skills[0].skill_id, after.skills[0].skill_id);
}

test "Manual Task persistence failure keeps Product Task usable in memory" {
    fake_core.reset();
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var persistence: TaskPersistenceProbe = .{};
    var configuration = productControlConfiguration();
    configuration.task_persistence = persistence.capability();
    var workbench = try product_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 1,
            .max_workspaces = 1,
            .max_tasks = 1,
            .max_runs_per_task = 1,
            .max_tools_per_run = 1,
        },
        configuration,
    );
    defer workbench.deinit();
    try installControlExecution(&workbench);
    const workspace_id = try workbench.openWorkspace(productControlTaskInput());
    var projection_storage: [1]product_control.WorkspaceProjection = undefined;
    const before = try workbench.copyWorkspaceProjections(&projection_storage);
    const recent_order = before[0].recent_order;
    const epoch = before[0].epoch;

    persistence.result = .failed;
    const task_id = try workbench.createTaskForWorkspace(.{ .manual = .{
        .workspace_id = workspace_id,
        .expected_epoch = epoch,
    } }, try product_control.TestSupport.fixtureModelSelection(&workbench), null, null, .{ .interactive = null });
    const after = try workbench.copyWorkspaceProjections(&projection_storage);
    try std.testing.expect(after[0].recent_order > recent_order);
    var snapshot_storage: [128 * 1024]u8 = undefined;
    const snapshot = try workbench.writeAggregateFixture(&snapshot_storage);
    var task_id_storage: [32]u8 = undefined;
    const task_id_json = try std.fmt.bufPrint(&task_id_storage, "\"id\":\"{d}\"", .{task_id});
    try std.testing.expect(std.mem.indexOf(u8, snapshot, task_id_json) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        snapshot,
        "\"taskHistoryPersistenceHealth\":\"write_failed\"",
    ) != null);
}

test "Task model selection during a Run persists intent for the next explicit admission" {
    fake_core.reset();
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 2, .max_sessions = 1 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var workbench = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, .{
        .worker_count = 1,
        .queue_capacity = 2,
        .max_workspaces = 1,
        .max_tasks = 1,
        .max_runs_per_task = 3,
        .max_tools_per_run = 1,
    }, productControlConfiguration());
    defer workbench.deinit();
    try installControlExecution(&workbench);
    installTwoModelCatalog(&workbench);
    const id = try workbench.createTask(productControlTaskInput(), try product_control.TestSupport.fixtureModelSelection(&workbench));
    const task = workbench.task_runtime.find(id).?;
    const epoch = task.durable.binding_epoch;
    const profile = task.durable.permission_profile;
    fake_core.setSessionPlan(.controlled);
    var released = false;
    defer if (!released) fake_core.releaseControlled();
    const first = try runPreparedTask(&workbench, id, .{ .text = "first frozen model" });
    try std.testing.expect(first != 0);
    try waitControlSnapshot(&workbench, "\"currentRunPhase\":\"running\"");
    try std.testing.expectEqual(@as(u64, 2), try workbench.selectTaskModel(id, taskModelSelectionInput(&workbench, 1, "fixture-model-2")));
    try std.testing.expectError(error.TaskModelMismatch, workbench.selectTaskModel(id, taskModelSelectionInput(&workbench, 1, "fixture-model")));
    try expectFakeSessionModel(0, "fixture-model");
    try std.testing.expectEqualStrings("fixture-model", task.durable.runs[0].?.execution_model);
    fake_core.releaseControlled();
    released = true;
    for (0..5000) |_| {
        try workbench.drainAgentEvents();
        workbench.syncLifecycle();
        if (task.runtime.active_operation == .none and !task.runtime.worker_leases.hasLive()) break;
        std.testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    _ = try workbench.runTaskAtBinding(id, epoch, .{ .text = "explicit latest intent" });
    var completed = false;
    for (0..10_000) |_| {
        try workbench.drainAgentEvents();
        workbench.syncLifecycle();
        if (task.durable.runs[1]) |*run| if (task_state.terminalPayload(run) != null) {
            completed = true;
            break;
        };
        std.testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expect(completed);
    try std.testing.expectEqualStrings("fixture-model", task.durable.runs[0].?.execution_model);
    try std.testing.expectEqualStrings("fixture-model-2", task.durable.runs[1].?.execution_model);
    try std.testing.expectEqualStrings("fixture-model-2", (try workbench.task_runtime.testExecutionInput(id)).target.model);
    try expectFakeSessionModel(0, "fixture-model-2");
    try std.testing.expectEqual(epoch, task.durable.binding_epoch);
    try std.testing.expectEqual(profile, task.durable.permission_profile);
    _ = try product_control.TestSupport.retryTaskSessionClose(&workbench, id);
    var detached = false;
    for (0..10_000) |_| {
        try workbench.drainAgentEvents();
        workbench.syncLifecycle();
        if (task.runtime.attachment == .detached) {
            detached = true;
            break;
        }
        std.testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expect(detached);
    try std.testing.expectEqual(@as(u64, 3), try workbench.selectTaskModel(id, taskModelSelectionInput(&workbench, 2, "fixture-model")));
    try std.testing.expectEqualStrings("fixture-model-2", task.durable.execution_model);
    try std.testing.expectEqualStrings("fixture-model", task.durable.model_intent.?.model_id);
    try std.testing.expect(task.runtime.attachment == .detached);
}

test "Task model selection save failure preserves installed execution and unknown blocks new admission" {
    fake_core.reset();
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const persistence_storage = try std.testing.allocator.alloc(
        u8,
        product_task.history.max_store_bytes,
    );
    defer std.testing.allocator.free(persistence_storage);
    var persistence = TaskPersistenceProbe{ .storage = persistence_storage };
    {
        var configuration = productControlConfiguration();
        configuration.task_persistence = persistence.capability();
        var workbench = try product_control.Runtime.init(
            std.testing.allocator,
            std.testing.io,
            runtime,
            .{
                .worker_count = 1,
                .queue_capacity = 1,
                .max_workspaces = 1,
                .max_tasks = 2,
                .max_runs_per_task = 1,
                .max_tools_per_run = 1,
            },
            configuration,
        );
        defer workbench.deinit();
        try installControlExecution(&workbench);
        installTwoModelCatalog(&workbench);
        const task_id = try workbench.createTask(productControlTaskInput(), try product_control.TestSupport.fixtureModelSelection(&workbench));
        const projection_before = workbench.projectionBytesForTest();
        try expectFakeSessionModel(0, "fixture-model");
        persistence.result = .failed;
        try std.testing.expectError(error.TaskPersistenceFailed, workbench.selectTaskModel(
            task_id,
            taskModelSelectionInput(&workbench, 1, "fixture-model-2"),
        ));
        const after = try workbench.taskExecutionIdentity(task_id);
        try std.testing.expectEqualStrings("fixture-model", after.model);
        try expectFakeSessionModel(0, "fixture-model");
        try std.testing.expectEqualStrings("fixture-model", workbench.task_runtime.findConst(task_id).?.durable.model_intent.?.model_id);
        try std.testing.expect(workbench.projectionBytesForTest() >= projection_before);
    }

    persistence.result = .committed;
    {
        var configuration = productControlConfiguration();
        configuration.task_persistence = persistence.capability();
        var workbench = try product_control.Runtime.init(
            std.testing.allocator,
            std.testing.io,
            runtime,
            .{
                .worker_count = 1,
                .queue_capacity = 1,
                .max_workspaces = 1,
                .max_tasks = 2,
                .max_runs_per_task = 1,
                .max_tools_per_run = 1,
            },
            configuration,
        );
        defer workbench.deinit();
        try installControlExecution(&workbench);
        installTwoModelCatalog(&workbench);
        const task_id = try workbench.createTask(productControlTaskInput(), try product_control.TestSupport.fixtureModelSelection(&workbench));
        const projection_before = workbench.projectionBytesForTest();
        persistence.result = .outcome_unknown;
        try std.testing.expectError(error.TaskPersistenceOutcomeUnknown, workbench.selectTaskModel(
            task_id,
            taskModelSelectionInput(&workbench, 1, "fixture-model-2"),
        ));
        const after = try workbench.taskExecutionIdentity(task_id);
        try std.testing.expectEqualStrings("fixture-model", after.model);
        try expectFakeSessionModel(0, "fixture-model");
        try std.testing.expectEqualStrings("fixture-model-2", workbench.task_runtime.findConst(task_id).?.durable.model_intent.?.model_id);
        try std.testing.expect(workbench.projectionBytesForTest() >= projection_before);
        try std.testing.expectError(error.TaskPersistenceOutcomeUnknown, workbench.runTask(task_id, .{ .text = "must wait for canonical history" }));
    }
}

test "automatic Workspace admission is Task-owned with explicit Skill unavailability" {
    fake_core.reset();
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 2,
        .max_sessions = 2,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_storage);
    var automatic_root = try product_control.AutomaticWorkspaceRoot.open(
        std.testing.io,
        std.testing.allocator,
        root_storage[0..root_len],
    );
    defer automatic_root.deinit();
    var checkpoint_tmp = std.testing.tmpDir(.{});
    defer checkpoint_tmp.cleanup();
    var checkpoint_root_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const checkpoint_root_len = try checkpoint_tmp.dir.realPath(
        std.testing.io,
        &checkpoint_root_storage,
    );
    var checkpoint_store = try product_task.checkpoint_store.FileStore.init(
        std.testing.io,
        checkpoint_root_storage[0..checkpoint_root_len],
    );
    defer checkpoint_store.deinit();
    const persistence_storage = try std.testing.allocator.alloc(
        u8,
        product_task.history.max_store_bytes,
    );
    defer std.testing.allocator.free(persistence_storage);
    var persistence = TaskPersistenceProbe{ .storage = persistence_storage };
    var workbench = try product_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 2,
            .max_workspaces = 1,
            .max_tasks = 2,
            .max_runs_per_task = 2,
            .max_tools_per_run = 1,
        },
        .{
            .directories = .{ .testing_automatic_workspace_root = &automatic_root },
            .completion_factory = .{ .create_fn = fixture.createCompletion },
            .task_persistence = persistence.capability(),
            .checkpoint_store = .{ .file_store = &checkpoint_store },
        },
    );
    defer workbench.deinit();
    try installControlExecution(&workbench);

    _ = try workbench.openWorkspace(productControlTaskInput());
    var user_projection_storage: [3]product_control.WorkspaceProjection = undefined;
    const before = try workbench.copyWorkspaceProjections(&user_projection_storage);
    const manual_recent_order = before[0].recent_order;

    const first_task = try workbench.createTaskForWorkspace(.automatic, try product_control.TestSupport.fixtureModelSelection(&workbench), null, null, .{ .interactive = null });
    const first_workspace = try workbench.taskWorkspaceId(first_task);
    try std.testing.expectEqual(
        product_control.WorkspaceKind.automatic,
        try workbench.workspaceKind(first_workspace),
    );
    try std.testing.expectEqual(
        product_control.CatalogAvailability.unavailable,
        (try workbench.taskCatalog(first_task)).availability,
    );
    const after_first = try workbench.copyWorkspaceProjections(&user_projection_storage);
    try std.testing.expectEqual(@as(usize, 2), after_first.len);
    const projected_manual = for (after_first) |workspace| {
        if (workspace.kind == .manual) break workspace;
    } else return error.TestUnexpectedResult;
    const projected_automatic = for (after_first) |workspace| {
        if (workspace.kind == .automatic) break workspace;
    } else return error.TestUnexpectedResult;
    try std.testing.expectEqual(manual_recent_order, projected_manual.recent_order);
    try std.testing.expectEqual(first_workspace, projected_automatic.id);
    var automatic_snapshot_storage: [128 * 1024]u8 = undefined;
    const automatic_snapshot = try workbench.writeAggregateFixture(
        &automatic_snapshot_storage,
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        automatic_snapshot,
        "\"automaticWorkspaces\":true",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        automatic_snapshot,
        "\"kind\":\"automatic\"",
    ) != null);
    try std.testing.expectEqual(@as(usize, 1), try directoryEntryCount(tmp.dir));
    try std.testing.expectError(
        error.WorkspaceUnavailable,
        workbench.createTaskInWorkspace(first_workspace, try workbench.workspaceEpoch(first_workspace), try product_control.TestSupport.fixtureModelSelection(&workbench), null, null, .{ .interactive = null }),
    );
    try std.testing.expectError(
        error.CatalogUnavailable,
        workbench.runTask(first_task, .{ .skill = .{
            .skill_id = fixture.fixture_skill_id,
            .catalog_revision = fixture.fixture_catalog_revision,
            .selection_revision = 1,
            .argument_values = &.{},
        } }),
    );

    const second_task = try workbench.createTaskForWorkspace(.automatic, try product_control.TestSupport.fixtureModelSelection(&workbench), null, null, .{ .interactive = null });
    const second_workspace = try workbench.taskWorkspaceId(second_task);
    try std.testing.expect(first_workspace != second_workspace);
    try std.testing.expectEqual(@as(usize, 2), try directoryEntryCount(tmp.dir));

    try workbench.renameTask(second_task, "Preset title");
    _ = try runPreparedTask(&workbench, second_task, .{ .text = "must not replace preset" });
    try waitControlSnapshot(&workbench, "\"terminal\":{\"outcome\":\"completed\"");
    var preset_title_snapshot: [128 * 1024]u8 = undefined;
    const preset_title_snapshot_bytes = try workbench.writeAggregateFixture(&preset_title_snapshot);
    try std.testing.expect(
        std.mem.indexOf(u8, preset_title_snapshot_bytes, "\"title\":\"Preset title\"") != null,
    );

    fake_core.setCompletionTitle("Generated task title");
    fake_core.controlNextCompletion();
    var completion_released = false;
    defer if (!completion_released) fake_core.releaseCompletion();
    fake_core.setSessionPlan(.controlled);
    _ = try runPreparedTask(&workbench, first_task, .{ .text = "automatic text run" });
    try waitControlSnapshot(&workbench, "\"currentRunPhase\":\"running\"");
    var provisional_title_snapshot: [128 * 1024]u8 = undefined;
    const provisional_title_snapshot_bytes = try workbench.writeAggregateFixture(
        &provisional_title_snapshot,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            provisional_title_snapshot_bytes,
            "\"title\":\"automatic text run\"",
        ) != null,
    );
    fake_core.releaseControlled();
    fake_core.waitCompletionEntered();
    try waitControlSnapshot(&workbench, "\"terminal\":{\"outcome\":\"completed\"");
    try waitHistoryNeedle(
        &workbench,
        &persistence,
        "\"checkpoint_anchor\":\"available\"",
    );
    fake_core.lock();
    const completion_requests = fake_core.completion_requests;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), completion_requests);
    try waitSetTaskArchived(&workbench, first_task);
    try workbench.deleteTask(first_task);
    var deleting_snapshot_storage: [128 * 1024]u8 = undefined;
    const deleting_snapshot = try workbench.writeAggregateFixture(&deleting_snapshot_storage);
    try std.testing.expect(std.mem.indexOf(
        u8,
        deleting_snapshot,
        "\"deletionStatus\":\"deleting\"",
    ) != null);
    try std.testing.expectEqual(first_workspace, try workbench.taskWorkspaceId(first_task));
    fake_core.releaseCompletion();
    completion_released = true;
    try waitTaskDeleted(&workbench, first_task);
    try std.testing.expectError(
        error.UnknownWorkspace,
        workbench.workspaceEpoch(first_workspace),
    );
    try std.testing.expectEqual(@as(usize, 2), try directoryEntryCount(tmp.dir));
    try std.testing.expectEqual(
        product_control.WorkspaceKind.automatic,
        try workbench.workspaceKind(second_workspace),
    );
    try std.testing.expectEqual(
        product_control.CatalogAvailability.unavailable,
        (try workbench.taskCatalog(second_task)).availability,
    );
}

test "automatic Workspace creation rolls back record and empty directory on Session failure" {
    fake_core.reset();
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 2,
        .max_sessions = 1,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_storage);
    var automatic_root = try product_control.AutomaticWorkspaceRoot.open(
        std.testing.io,
        std.testing.allocator,
        root_storage[0..root_len],
    );
    defer automatic_root.deinit();
    var workbench = try product_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 2,
            .max_workspaces = 1,
            .max_tasks = 2,
            .max_runs_per_task = 1,
            .max_tools_per_run = 1,
        },
        .{ .directories = .{ .testing_automatic_workspace_root = &automatic_root } },
    );
    defer workbench.deinit();
    try installControlExecution(&workbench);
    _ = try workbench.createTask(productControlTaskInput(), try product_control.TestSupport.fixtureModelSelection(&workbench));
    const revision = workbench.currentRevision();

    try std.testing.expectError(
        error.SessionCapacity,
        workbench.createTaskForWorkspace(.automatic, try product_control.TestSupport.fixtureModelSelection(&workbench), null, null, .{ .interactive = null }),
    );
    try std.testing.expectEqual(revision, workbench.currentRevision());
    try std.testing.expectEqual(@as(usize, 0), try directoryEntryCount(tmp.dir));
}

test "custom schedule creates updates and launches manual and timed Tasks through source authority" {
    fake_core.reset();
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 2, .max_sessions = 2 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_storage);
    var automatic_root = try product_control.AutomaticWorkspaceRoot.open(std.testing.io, std.testing.allocator, root_storage[0..root_len]);
    defer automatic_root.deinit();
    var schedule: TestScheduleSupport = .{};
    var history: TaskPersistenceProbe = .{};
    var workbench = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, .{
        .worker_count = 1,
        .queue_capacity = 2,
        .max_workspaces = 1,
        .max_tasks = 2,
        .max_scheduled_tasks = 1,
        .max_runs_per_task = 1,
        .max_tools_per_run = 1,
    }, .{
        .directories = .{ .testing_automatic_workspace_root = &automatic_root },
        .schedule_timer = schedule.timer(),
        .schedule_persistence = schedule.persistence(),
        .task_persistence = history.capability(),
    });
    defer workbench.deinit();
    var vault: TaskModelsVault = .{};
    defer TaskModelsVault.delete(&vault, TaskModelsVault.slot) catch unreachable;
    try workbench.startCustomProviders(root_storage[0..root_len], vault.port());
    defer workbench.stopCustomProviders();
    const probe = try configureTaskRebindTarget(&workbench);
    try std.testing.expect(workbench.custom_providers.rememberPreference(probe.model).accepted);
    workbench.setScheduleBackgroundAvailableNoFail(true);
    const id = try workbench.createScheduledTask(.{
        .title = "Custom schedule",
        .model_selection = try product_control.TestSupport.fixtureModelSelection(&workbench),
        .permission_profile = .approval_required,
        .input = "Review work",
        .recurrence = .{ .once = .{ .at_unix_seconds = 2_000 } },
    });
    try workbench.updateScheduledTask(id, 1, .{
        .title = "Updated custom schedule",
        .model_selection = try product_control.TestSupport.fixtureModelSelection(&workbench),
        .permission_profile = .approval_required,
        .input = "Review work",
        .recurrence = .{ .interval = .{ .start_at_unix_seconds = 2_000, .every_seconds = 300 } },
    });
    const first = try workbench.runScheduledTaskNow(id, 2);
    try waitControlSnapshot(&workbench, "\"taskOutcome\":\"completed\"");
    schedule.now = 2_000;
    workbench.onScheduledTaskTimer();
    const occurrence = workbench.schedule.store.find(id).?.last_occurrence.?;
    try std.testing.expectEqual(@as(u64, 2_000), occurrence.planned_at_unix_seconds);
    try std.testing.expectEqual(@as(u64, 2), occurrence.task_id);
    try std.testing.expect(first != occurrence.task_id);
    for ([_]u64{ first, occurrence.task_id }) |task_id| {
        const execution = workbench.task_runtime.findConst(task_id).?.runtime.executionConst().?;
        try std.testing.expectEqualStrings("custom_provider:" ++ TaskModelsVault.slot, execution.provider_id);
        try std.testing.expectEqualStrings("other-model", execution.model);
        try std.testing.expectEqual(models_contract.Protocol.openai_responses, execution.protocol);
    }
}

test "Text schedule updates preserve historical Task profiles and create fresh automatic Workspaces" {
    fake_core.reset();
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 2,
        .max_sessions = 2,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "automatic-a", .default_dir);
    try tmp.dir.createDir(std.testing.io, "automatic-b", .default_dir);
    try tmp.dir.createDir(std.testing.io, "configuration", .default_dir);
    var root_a_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var root_b_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var configuration_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_a_len = try tmp.dir.realPathFile(
        std.testing.io,
        "automatic-a",
        &root_a_storage,
    );
    const root_b_len = try tmp.dir.realPathFile(
        std.testing.io,
        "automatic-b",
        &root_b_storage,
    );
    const configuration_len = try tmp.dir.realPathFile(
        std.testing.io,
        "configuration",
        &configuration_storage,
    );
    var automatic_configuration = try product_control.AutomaticWorkspaceRootConfigurationFileStore.init(
        std.testing.io,
        configuration_storage[0..configuration_len],
    );
    defer automatic_configuration.deinit();
    var schedule_support: TestScheduleSupport = .{};
    var task_persistence: TaskPersistenceProbe = .{};
    var workbench = try product_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 2,
            .max_workspaces = 1,
            .max_tasks = 2,
            .max_scheduled_tasks = 1,
            .max_runs_per_task = 1,
            .max_tools_per_run = 1,
        },
        .{
            .directories = .{
                .automatic_workspace_system_root = root_a_storage[0..root_a_len],
                .automatic_workspace_configuration_store = &automatic_configuration,
            },
            .schedule_timer = schedule_support.timer(),
            .schedule_persistence = schedule_support.persistence(),
            .task_persistence = task_persistence.capability(),
        },
    );
    defer workbench.deinit();
    try installControlExecution(&workbench);

    const default_schedule = try workbench.createScheduledTask(.{
        .title = "Independent brief",
        .model_selection = try product_control.TestSupport.fixtureModelSelection(&workbench),
        .permission_profile = .full_access,
        .input = "Summarize current work",
        .recurrence = .{ .interval = .{
            .start_at_unix_seconds = 2_000,
            .every_seconds = 3_600,
        } },
    });
    const commits_before_rejection = schedule_support.commits;
    try std.testing.expectError(
        error.InvalidScheduledTaskInput,
        workbench.createScheduledTask(.{
            .title = "Empty schedule input",
            .model_selection = try product_control.TestSupport.fixtureModelSelection(&workbench),
            .permission_profile = .approval_required,
            .input = "",
            .recurrence = .{ .once = .{ .at_unix_seconds = 2_000 } },
        }),
    );
    try std.testing.expectEqual(commits_before_rejection, schedule_support.commits);

    const first_task = try workbench.runScheduledTaskNow(default_schedule, 1);
    const first_workspace = try workbench.taskWorkspaceId(first_task);
    try std.testing.expectEqual(
        product_control.WorkspaceKind.automatic,
        try workbench.workspaceKind(first_workspace),
    );
    try waitControlSnapshot(&workbench, "\"taskOutcome\":\"completed\"");
    try std.testing.expectEqual(
        product_control.PermissionProfile.full_access,
        try workbench.taskPermissionProfile(first_task),
    );
    const root_generation = workbench.automaticWorkspaceRootConfiguration().generation;
    try workbench.chooseAutomaticWorkspaceRoot(
        root_generation,
        root_b_storage[0..root_b_len],
    );

    try workbench.updateScheduledTask(default_schedule, 1, .{
        .title = "Independent brief",
        .model_selection = try product_control.TestSupport.fixtureModelSelection(&workbench),
        .permission_profile = .approval_required,
        .input = "Summarize current work",
        .recurrence = .{ .interval = .{
            .start_at_unix_seconds = 2_000,
            .every_seconds = 3_600,
        } },
    });
    try std.testing.expectEqual(
        @as(u64, 2),
        try workbench.scheduledTaskEpoch(default_schedule),
    );
    var updated_snapshot_storage: [128 * 1024]u8 = undefined;
    const updated_snapshot = try workbench.writeAggregateFixture(&updated_snapshot_storage);
    const schedules_offset = std.mem.indexOf(
        u8,
        updated_snapshot,
        "\"scheduledTasks\":[",
    ) orelse return error.TestUnexpectedResult;
    const tasks_relative_offset = std.mem.indexOf(
        u8,
        updated_snapshot[schedules_offset..],
        "],\"tasks\":[",
    ) orelse return error.TestUnexpectedResult;
    const tasks_offset = schedules_offset + tasks_relative_offset;
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            updated_snapshot[schedules_offset..tasks_offset],
            "\"permissionProfile\":\"approval_required\"",
        ) != null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            updated_snapshot[tasks_offset..],
            "\"permissionProfile\":\"full_access\"",
        ) != null,
    );

    const second_task = try workbench.runScheduledTaskNow(default_schedule, 2);
    const second_workspace = try workbench.taskWorkspaceId(second_task);
    try std.testing.expect(first_task != second_task);
    try std.testing.expect(first_workspace != second_workspace);
    try std.testing.expectEqual(
        product_control.PermissionProfile.full_access,
        try workbench.taskPermissionProfile(first_task),
    );
    try std.testing.expectEqual(
        product_control.PermissionProfile.approval_required,
        try workbench.taskPermissionProfile(second_task),
    );
    try std.testing.expectEqual(
        product_control.WorkspaceKind.automatic,
        try workbench.workspaceKind(second_workspace),
    );
    var projection_storage: [2]product_control.WorkspaceProjection = undefined;
    const projections = try workbench.copyWorkspaceProjections(
        &projection_storage,
    );
    try std.testing.expectEqual(@as(usize, 2), projections.len);
    for (projections) |workspace| {
        try std.testing.expectEqual(
            product_control.WorkspaceKind.automatic,
            workspace.kind,
        );
        try std.testing.expectEqual(@as(u64, 0), workspace.recent_order);
        if (workspace.id == first_workspace) {
            try std.testing.expect(std.mem.startsWith(
                u8,
                workspace.canonical_root,
                root_a_storage[0..root_a_len],
            ));
        } else if (workspace.id == second_workspace) {
            try std.testing.expect(std.mem.startsWith(
                u8,
                workspace.canonical_root,
                root_b_storage[0..root_b_len],
            ));
        } else return error.TestUnexpectedResult;
    }

    const root_a = try tmp.dir.openDir(std.testing.io, "automatic-a", .{ .iterate = true });
    defer root_a.close(std.testing.io);
    const root_b = try tmp.dir.openDir(std.testing.io, "automatic-b", .{ .iterate = true });
    defer root_b.close(std.testing.io);
    try std.testing.expectEqual(@as(usize, 1), try directoryEntryCount(root_a));
    try std.testing.expectEqual(@as(usize, 1), try directoryEntryCount(root_b));
    var snapshot_storage: [128 * 1024]u8 = undefined;
    const snapshot = try workbench.writeAggregateFixture(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"target\"") == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        snapshot,
        "\"permissionProfile\":\"full_access\",\"permissionInteraction\":\"noninteractive\"",
    ) != null);
}

test "schedule rejection retains the automatic Task created before a full Run queue" {
    fake_core.reset();
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 3,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_storage);
    var automatic_root = try product_control.AutomaticWorkspaceRoot.open(
        std.testing.io,
        std.testing.allocator,
        root_storage[0..root_len],
    );
    defer automatic_root.deinit();
    var schedule_support: TestScheduleSupport = .{};
    var task_persistence: TaskPersistenceProbe = .{};
    var workbench = try product_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 1,
            .max_tasks = 3,
            .max_scheduled_tasks = 1,
            .max_runs_per_task = 1,
            .max_tools_per_run = 1,
        },
        .{
            .directories = .{ .testing_automatic_workspace_root = &automatic_root },
            .schedule_timer = schedule_support.timer(),
            .schedule_persistence = schedule_support.persistence(),
            .task_persistence = task_persistence.capability(),
        },
    );
    defer workbench.deinit();
    try installControlExecution(&workbench);

    const schedule_id = try workbench.createScheduledTask(.{
        .title = "Queued brief",
        .model_selection = try product_control.TestSupport.fixtureModelSelection(&workbench),
        .permission_profile = .approval_required,
        .input = "Summarize current work",
        .recurrence = .{ .once = .{ .at_unix_seconds = 2_000 } },
    });
    fake_core.setNextPlan(.controlled);
    defer fake_core.releaseControlled();
    const running_task = try workbench.createTaskForWorkspace(.automatic, try product_control.TestSupport.fixtureModelSelection(&workbench), null, null, .{ .interactive = null });
    const queued_task = try workbench.createTaskForWorkspace(.automatic, try product_control.TestSupport.fixtureModelSelection(&workbench), null, null, .{ .interactive = null });
    _ = try runPreparedTask(&workbench, running_task, .{ .text = "hold worker" });
    try waitControlSnapshot(
        &workbench,
        "\"currentRunPhase\":\"running\"",
    );
    _ = try runPreparedTask(&workbench, queued_task, .{ .text = "fill queue" });

    try std.testing.expectError(
        error.QueueFull,
        workbench.runScheduledTaskNow(schedule_id, 1),
    );
    try std.testing.expectEqual(@as(usize, 3), try directoryEntryCount(tmp.dir));
    var snapshot_storage: [128 * 1024]u8 = undefined;
    const snapshot = try workbench.writeAggregateFixture(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(
        u8,
        snapshot,
        "\"result\":\"rejected\",\"taskId\":\"3\",\"reason\":\"capacity_reached\"",
    ) != null);
}

test "Workspace reauthorization reschedules the latest catalog query" {
    fake_core.reset();
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 2,
        .max_sessions = 1,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const home = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(home);
    var skill_enablement_store = try product_skill.enablement.FileStore.init(
        std.testing.io,
        home,
    );
    defer skill_enablement_store.deinit();
    var workbench = try product_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 2,
            .max_workspaces = 1,
            .max_tasks = 1,
            .max_runs_per_task = 1,
            .max_tools_per_run = 1,
        },
        .{
            .directories = .{ .canonical_user_home = home },
            .skill_enablement = .{ .file_store = &skill_enablement_store },
            .skill_sources = .{ .restored = .{ .loaded = .{ .ready = .{} } } },
        },
    );
    defer workbench.deinit();
    defer fake_core.releaseCatalogQuery();
    try installControlExecution(&workbench);

    for (0..10_000) |_| {
        try workbench.drainAgentEvents();
        const personal = workbench.skillCatalog();
        if (personal.availability == .ready or personal.availability == .degraded)
            break;
        std.testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
    } else return error.TestUnexpectedResult;
    fake_core.setCatalogPlan(.controlled);

    const workspace_id = try workbench.openWorkspace(productControlTaskInput());
    fake_core.waitCatalogQueryEntered();
    try workbench.removeWorkspace(workspace_id);
    const reauthorized_id = try workbench.openWorkspace(productControlTaskInput());
    try std.testing.expectEqual(workspace_id, reauthorized_id);
    try std.testing.expectEqual(
        product_control.CatalogAvailability.loading,
        (try workbench.workspaceCatalog(workspace_id)).availability,
    );

    fake_core.setCatalogPlan(.healthy);
    fake_core.releaseCatalogQuery();
    _ = try waitCatalogReady(&workbench, workspace_id);
    fake_core.lock();
    const catalog_queries = fake_core.catalog_queries;
    const catalog_releases = fake_core.catalog_releases;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 3), catalog_queries);
    try std.testing.expectEqual(@as(usize, 1), catalog_releases);
}

test "Product Control rejects stale Skill identity before Session or Run mutation and releases catalog on shutdown" {
    fake_core.reset();
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 2,
        .max_sessions = 1,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const home = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(home);
    var skill_enablement_store = try product_skill.enablement.FileStore.init(
        std.testing.io,
        home,
    );
    defer skill_enablement_store.deinit();
    var workbench = try product_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 2,
            .max_workspaces = 1,
            .max_tasks = 1,
            .max_runs_per_task = 1,
            .max_tools_per_run = 1,
        },
        .{
            .directories = .{ .canonical_user_home = home },
            .skill_enablement = .{ .file_store = &skill_enablement_store },
            .skill_sources = .{ .restored = .{ .loaded = .{ .ready = .{} } } },
        },
    );
    defer workbench.deinit();
    try installControlExecution(&workbench);

    const workspace_id = try workbench.openWorkspace(productControlTaskInput());
    const catalog = try waitCatalogReady(&workbench, workspace_id);
    try std.testing.expectError(
        error.StaleCatalog,
        workbench.createTaskInWorkspace(workspace_id, try workbench.workspaceEpoch(workspace_id), try product_control.TestSupport.fixtureModelSelection(&workbench), "stale-revision", catalog.selection_revision, .{ .interactive = null }),
    );
    fake_core.lock();
    const sessions_before = fake_core.session_created;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 0), sessions_before);

    fake_core.setNextPlan(.stale_catalog);
    const task_id = try workbench.createTaskInWorkspace(workspace_id, try workbench.workspaceEpoch(workspace_id), try product_control.TestSupport.fixtureModelSelection(&workbench), catalog.revision, catalog.selection_revision, .{ .interactive = null });
    try std.testing.expectError(
        error.StaleCatalog,
        workbench.runTask(task_id, .{ .skill = .{
            .skill_id = fixture.fixture_skill_id,
            .catalog_revision = "stale-revision",
            .selection_revision = catalog.selection_revision.?,
            .argument_values = &.{},
        } }),
    );
    fake_core.lock();
    const runs_before = fake_core.run_calls;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 0), runs_before);

    _ = try runPreparedTask(&workbench, task_id, .{ .skill = .{
        .skill_id = fixture.fixture_skill_id,
        .catalog_revision = catalog.revision,
        .selection_revision = catalog.selection_revision.?,
        .argument_values = &.{},
    } });
    try waitControlSnapshot(
        &workbench,
        "\"cause\":\"stale_catalog\"",
    );

    workbench.shutdownExecutor();
    try runtime.shutdown();
    fake_core.lock();
    const catalog_releases = fake_core.catalog_releases;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 3), catalog_releases);
    try std.testing.expectEqual(fake_core.catalog_queries, catalog_releases);
}

test "Product Control refreshes an idle Task from committed policy after an enablement write failure" {
    fake_core.reset();
    fake_core.setCatalogPlan(.query_failure);
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 2,
        .max_sessions = 1,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const home = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(home);
    var skill_enablement_store = try product_skill.enablement.FileStore.init(
        std.testing.io,
        home,
    );
    defer skill_enablement_store.deinit();
    var workbench = try product_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 2,
            .max_workspaces = 1,
            .max_tasks = 1,
            .max_runs_per_task = 1,
            .max_tools_per_run = 1,
        },
        .{
            .directories = .{ .canonical_user_home = home },
            .skill_enablement = .{ .file_store = &skill_enablement_store },
            .skill_sources = .{ .restored = .{ .loaded = .{ .ready = .{} } } },
        },
    );
    defer workbench.deinit();
    try installControlExecution(&workbench);

    const workspace_id = try workbench.openWorkspace(productControlTaskInput());
    try waitCatalogUnavailable(&workbench, workspace_id);
    fake_core.setNextPlan(.controlled);
    const task_id = try workbench.createTaskInWorkspace(workspace_id, try workbench.workspaceEpoch(workspace_id), try product_control.TestSupport.fixtureModelSelection(&workbench), null, null, .{ .interactive = null });
    _ = try runPreparedTask(&workbench, task_id, .{ .text = "hold refresh" });
    try waitControlSnapshot(
        &workbench,
        "\"currentRunPhase\":\"running\"",
    );
    try std.testing.expectError(
        error.TaskBusy,
        workbench.refreshTaskCatalog(
            task_id,
            try workbench.taskBindingEpoch(task_id),
        ),
    );
    fake_core.releaseControlled();
    try waitControlSnapshot(
        &workbench,
        "\"terminal\":{\"outcome\":\"completed\"",
    );

    fake_core.setCatalogPlan(.healthy);
    const workspace_epoch = try workbench.workspaceEpoch(workspace_id);
    try workbench.refreshWorkspaceCatalog(workspace_id, workspace_epoch);
    _ = try waitCatalogReady(&workbench, workspace_id);
    var persistence_dir = std.testing.tmpDir(.{});
    defer persistence_dir.cleanup();
    var blocked_dir = std.testing.tmpDir(.{});
    defer blocked_dir.cleanup();
    try blocked_dir.dir.createDir(std.testing.io, product_skill.enablement.file_name, .default_dir);
    // Keep all new persistence effects in test-owned directories. The store
    // capability is borrowed only inside this scope and restored before close.
    const original_dir = skill_enablement_store.dir;
    defer skill_enablement_store.dir = original_dir;
    skill_enablement_store.dir = persistence_dir.dir;
    const selection = try workbench.setSkillEnabled(.{
        .scope = .{ .project = .{ .workspace_id = workspace_id, .expected_workspace_epoch = workspace_epoch } },
        .skill_policy_key = "review",
        .state = .disabled,
        .expected_catalog_revision = fixture.fixture_catalog_revision,
        .expected_selection_revision = 1,
    });
    const enable: product_control.SkillEnablementMutation = .{
        .scope = .{ .project = .{ .workspace_id = workspace_id, .expected_workspace_epoch = workspace_epoch } },
        .skill_policy_key = "review",
        .state = .enabled,
        .expected_catalog_revision = fixture.fixture_catalog_revision,
        .expected_selection_revision = selection,
    };
    skill_enablement_store.dir = blocked_dir.dir;
    try std.testing.expectError(error.WriteFailed, workbench.setSkillEnabled(enable));
    skill_enablement_store.dir = persistence_dir.dir;
    try workbench.refreshWorkspaceCatalog(workspace_id, workspace_epoch);
    const refreshed = try waitCatalogReady(&workbench, workspace_id);
    try std.testing.expectEqual(selection, refreshed.selection_revision.?);
    try std.testing.expect(!refreshed.skills[0].enabled);
    try workbench.refreshTaskCatalog(
        task_id,
        try workbench.taskBindingEpoch(task_id),
    );
    try std.testing.expect(!(try workbench.taskCatalog(task_id)).skills[0].enabled);
    try std.testing.expectEqual(selection + 1, try workbench.setSkillEnabled(enable));
    try std.testing.expect(!(try workbench.taskCatalog(task_id)).skills[0].enabled);
    fake_core.lock();
    const refreshes = fake_core.catalog_refreshes;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), refreshes);
}

test "Task deletion waits for a requested Session close before its worker starts" {
    fake_core.reset();
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var workbench = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, .{
        .max_tasks = 1,
        .max_runs_per_task = 1,
        .max_tools_per_run = 1,
    }, productControlConfiguration());
    defer workbench.deinit();
    try installControlExecution(&workbench);
    const task_id = try workbench.createTask(productControlTaskInput(), try product_control.TestSupport.fixtureModelSelection(&workbench));
    try workbench.setTaskArchived(task_id, true);
    const task = workbench.task_runtime.find(task_id).?;
    var lease = try task.runtime.worker_leases.acquire();
    defer if (lease.isActive()) lease.deinit();

    try workbench.deleteTask(task_id);
    try std.testing.expect(task.runtime.close_requested);
    try std.testing.expect(task.runtime.hasAttachedSession());
    try std.testing.expect(task.runtime.close_thread == null);
    workbench.syncLifecycle();
    workbench.syncLifecycle();
    try std.testing.expectEqual(.deleting, task.deletion);
    try std.testing.expect(task.runtime.close_requested);
    try std.testing.expect(task.runtime.close_thread == null);

    lease.deinit();
    try waitTaskDeleted(&workbench, task_id);
    fake_core.lock();
    const destroyed = fake_core.session_destroyed;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), destroyed);
}

test "Task deletion retries an off-thread Session release failure" {
    fake_core.reset();
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 2, .max_sessions = 2 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var workbench = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, .{
        .max_tasks = 2,
        .max_runs_per_task = 2,
        .max_tools_per_run = 2,
    }, productControlConfiguration());
    defer workbench.deinit();
    try installControlExecution(&workbench);

    const task_id = try workbench.createTask(productControlTaskInput(), try product_control.TestSupport.fixtureModelSelection(&workbench));
    try workbench.setTaskArchived(task_id, true);
    fake_core.failNextSessionDestroy();
    try workbench.deleteTask(task_id);
    try waitControlSnapshot(&workbench, "\"deletionStatus\":\"failed\"");

    try workbench.deleteTask(task_id);
    try waitTaskDeleted(&workbench, task_id);
    fake_core.lock();
    const destroyed = fake_core.session_destroyed;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), destroyed);
}

test "asynchronous Task deletion commit failure retains an unarchived record" {
    fake_core.reset();
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const persistence_storage = try std.testing.allocator.alloc(
        u8,
        product_task.history.max_store_bytes,
    );
    defer std.testing.allocator.free(persistence_storage);
    var persistence = TaskPersistenceProbe{ .storage = persistence_storage };
    var configuration = productControlConfiguration();
    configuration.task_persistence = persistence.capability();
    var workbench = try product_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 1,
            .max_tasks = 1,
            .max_runs_per_task = 1,
            .max_tools_per_run = 1,
        },
        configuration,
    );
    defer workbench.deinit();
    try installControlExecution(&workbench);

    const task_id = try workbench.createTask(productControlTaskInput(), try product_control.TestSupport.fixtureModelSelection(&workbench));
    persistence.result = .failed;
    try workbench.deleteTask(task_id);
    try waitControlSnapshot(&workbench, "\"deletionStatus\":\"failed\"");
    try std.testing.expect(!workbench.task_runtime.find(task_id).?.durable.archived);
    try std.testing.expectEqual(
        @as(u64, 1),
        try workbench.taskBindingEpoch(task_id),
    );
}

test "Task deletion releases an idle Session without blocking the caller" {
    fake_core.reset();
    fake_core.setNextPlan(.controlled);
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 2, .max_sessions = 1 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var workbench = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, .{
        .max_tasks = 1,
        .max_runs_per_task = 1,
        .max_tools_per_run = 1,
    }, productControlConfiguration());
    defer workbench.deinit();
    try installControlExecution(&workbench);

    const task_id = try workbench.createTask(productControlTaskInput(), try product_control.TestSupport.fixtureModelSelection(&workbench));
    const run_id = try runPreparedTask(&workbench, task_id, .{ .text = "finish before deletion" });
    fake_core.waitRunEntered();
    _ = run_id;
    try workbench.deleteTask(task_id);
    try waitTaskDeleted(&workbench, task_id);
    fake_core.lock();
    const abort_calls = fake_core.abort_calls;
    const destroyed = fake_core.session_destroyed;
    fake_core.unlock();
    try std.testing.expect(abort_calls <= 1);
    try std.testing.expectEqual(@as(usize, 1), destroyed);
}

test "Workspace removal interrupts live Runs without deleting Task history" {
    fake_core.reset();
    fake_core.setNextPlan(.controlled);
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 2, .max_sessions = 1 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var workbench = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, .{
        .worker_count = 1,
        .queue_capacity = 2,
        .max_workspaces = 1,
        .max_tasks = 1,
        .max_runs_per_task = 1,
        .max_tools_per_run = 1,
    }, productControlConfiguration());
    defer workbench.deinit();
    try installControlExecution(&workbench);

    const task_id = try workbench.createTask(productControlTaskInput(), try product_control.TestSupport.fixtureModelSelection(&workbench));
    const workspace_id = try workbench.taskWorkspaceId(task_id);
    _ = try runPreparedTask(
        &workbench,
        task_id,
        .{ .text = "stop when the workspace is removed" },
    );
    try waitControlSnapshot(&workbench, "\"currentRunPhase\":\"running\"");

    try workbench.removeWorkspace(workspace_id);
    try waitControlSnapshot(&workbench, "\"terminal\":{\"outcome\":\"interrupted\"");
    try waitControlSnapshot(&workbench, "\"lifecycle\":\"open\"");

    var snapshot_storage: [128 * 1024]u8 = undefined;
    const snapshot = try workbench.writeAggregateFixture(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"tasks\":[{") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"workspaceRoot\":") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"workspaces\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"workspaceId\":") != null);
}

test "Workspace removal failure remains a retryable Workspace fact" {
    fake_core.reset();
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var workbench = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, .{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_workspaces = 1,
        .max_tasks = 1,
        .max_runs_per_task = 1,
        .max_tools_per_run = 1,
    }, productControlConfiguration());
    defer workbench.deinit();
    try installControlExecution(&workbench);

    const task_id = try workbench.createTask(productControlTaskInput(), try product_control.TestSupport.fixtureModelSelection(&workbench));
    const workspace_id = try workbench.taskWorkspaceId(task_id);
    fake_core.failNextSessionDestroy();
    try workbench.removeWorkspace(workspace_id);
    try waitControlSnapshot(
        &workbench,
        "\"lastRemovalFailure\":\"task_close_failed\"",
    );

    var snapshot_storage: [128 * 1024]u8 = undefined;
    const snapshot = try workbench.writeAggregateFixture(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(
        u8,
        snapshot,
        "\"authorization\":\"available\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"workspaces\":[{") != null);
}

test "Product Control cancel of a completed Run is an idempotent no-op" {
    fake_core.reset();
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var workbench = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, .{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_tasks = 1,
        .max_runs_per_task = 1,
        .max_tools_per_run = 1,
    }, productControlConfiguration());
    defer workbench.deinit();
    try installControlExecution(&workbench);

    const task_id = try workbench.createTask(productControlTaskInput(), try product_control.TestSupport.fixtureModelSelection(&workbench));
    const run_id = try runPreparedTask(
        &workbench,
        task_id,
        .{ .text = "finish before cancel arrives" },
    );
    try waitControlSnapshot(&workbench, "\"terminal\":{\"outcome\":\"completed\"");
    // Terminal publication precedes automatic-title completion and lease release.
    // Observe quiescence before attributing any revision change to cancellation.
    const task = workbench.task_runtime.find(task_id).?;
    for (0..5000) |_| {
        try workbench.drainAgentEvents();
        if (!task.runtime.worker_leases.hasLive() and
            (task.durable.runs[0].?.execution == null or task.durable.runs[0].?.execution.?.automatic_title.state.load(.acquire) == .settled)) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    } else return error.RunDidNotSettle;
    const revision = workbench.currentRevision();
    try workbench.cancel(task_id, run_id);
    try std.testing.expectEqual(revision, workbench.currentRevision());
    try waitControlSnapshot(&workbench, "\"terminal\":{\"outcome\":\"completed\"");
}

test "Product Control manual compact uses the active operation lane and appends history" {
    fake_core.reset();
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 2,
        .max_sessions = 1,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var workbench = try product_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 2,
            .max_tasks = 1,
            .max_runs_per_task = 1,
            .max_compacts_per_task = 2,
            .max_tools_per_run = 1,
        },
        productControlConfiguration(),
    );
    defer workbench.deinit();
    try installControlExecution(&workbench);

    const task_id = try workbench.createTask(productControlTaskInput(), try product_control.TestSupport.fixtureModelSelection(&workbench));
    try std.testing.expectError(
        error.NoSuchRun,
        workbench.compactTaskAtBinding(task_id, 1),
    );
    _ = try runPreparedTask(&workbench, task_id, .{ .text = "establish conversation" });
    try waitControlSnapshot(&workbench, "\"terminal\":{\"outcome\":\"completed\"");

    _ = try workbench.compactTaskAtBinding(task_id, 1);
    try waitControlSnapshot(&workbench, "\"phase\":\"compacted\"");
    _ = try workbench.compactTaskAtBinding(task_id, 1);
    try waitTaskSnapshot(
        &workbench,
        "\"operationId\":\"2\"",
        "\"phase\":\"compacted\"",
    );
    _ = try workbench.compactTaskAtBinding(task_id, 1);
    try waitTaskSnapshot(&workbench, "\"operationId\":\"3\"", "\"phase\":\"compacted\"");

    var storage: [128 * 1024]u8 = undefined;
    const snapshot = try workbench.writeAggregateFixture(&storage);
    try std.testing.expect(std.mem.indexOf(
        u8,
        snapshot,
        "\"activeOperation\":null",
    ) != null);
    try std.testing.expectEqual(
        @as(usize, 3),
        std.mem.count(u8, snapshot, "\"afterRunId\":\"1\""),
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        snapshot,
        "\"beforeContextTokens\":\"100\",\"afterContextTokens\":\"40\"",
    ) != null);
}

test "compact queue rejection persists a legal terminal record and returns its operation id" {
    fake_core.reset();
    const persistence_storage = try std.testing.allocator.alloc(
        u8,
        product_task.history.max_store_bytes,
    );
    defer std.testing.allocator.free(persistence_storage);
    var persistence = TaskPersistenceProbe{ .storage = persistence_storage };
    var configuration = productControlConfiguration();
    configuration.task_persistence = persistence.capability();
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 3,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var workbench = try product_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 1,
            .max_tasks = 3,
            .max_runs_per_task = 1,
            .max_compacts_per_task = 1,
            .max_tools_per_run = 1,
        },
        configuration,
    );
    defer workbench.deinit();
    try installControlExecution(&workbench);

    const compact_task = try workbench.createTask(productControlTaskInput(), try product_control.TestSupport.fixtureModelSelection(&workbench));
    const blocking_task = try workbench.createTask(productControlTaskInput(), try product_control.TestSupport.fixtureModelSelection(&workbench));
    const queued_task = try workbench.createTask(productControlTaskInput(), try product_control.TestSupport.fixtureModelSelection(&workbench));
    _ = try runPreparedTask(&workbench, compact_task, .{ .text = "establish conversation" });
    try waitControlSnapshot(&workbench, "\"terminal\":{\"outcome\":\"completed\"");

    fake_core.setSessionPlan(.controlled);
    fake_core.rearmControlled();
    defer fake_core.releaseControlled();
    _ = try runPreparedTask(&workbench, blocking_task, .{ .text = "hold worker" });
    try waitControlSnapshot(&workbench, "\"currentRunPhase\":\"running\"");
    _ = try runPreparedTask(&workbench, queued_task, .{ .text = "fill queue" });

    const operation_id = try workbench.compactTaskAtBinding(compact_task, 1);
    try std.testing.expectEqual(@as(u64, 1), operation_id);
    var snapshot_storage: [128 * 1024]u8 = undefined;
    const snapshot = try workbench.writeAggregateFixture(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(
        u8,
        snapshot,
        "\"operationId\":\"1\",\"afterRunId\":\"1\",\"conversationCoverage\":\"excluded\",\"phase\":\"failed\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        snapshot,
        "\"cause\":\"resource_limit\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        snapshot,
        "\"activeOperation\":null",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        snapshot,
        "\"taskHistoryPersistenceHealth\":\"ready\"",
    ) != null);
    try std.testing.expect(persistence.len != 0);
}

test "Product Control compact cancellation and Task deletion wait for the Agent terminal result" {
    fake_core.reset();
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 2,
        .max_sessions = 1,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var workbench = try product_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 2,
            .max_tasks = 1,
            .max_runs_per_task = 1,
            .max_compacts_per_task = 2,
            .max_tools_per_run = 1,
        },
        productControlConfiguration(),
    );
    defer workbench.deinit();
    try installControlExecution(&workbench);

    const task_id = try workbench.createTask(productControlTaskInput(), try product_control.TestSupport.fixtureModelSelection(&workbench));
    _ = try runPreparedTask(&workbench, task_id, .{ .text = "establish conversation" });
    try waitControlSnapshot(&workbench, "\"terminal\":{\"outcome\":\"completed\"");
    fake_core.setSessionPlan(.controlled);
    fake_core.rearmControlled();
    const operation_id = try workbench.compactTaskAtBinding(task_id, 1);
    try waitControlSnapshot(&workbench, "\"phase\":\"compacting\"");
    try std.testing.expectError(
        error.TaskBusy,
        workbench.runTask(task_id, .{ .text = "must wait" }),
    );
    _ = operation_id;
    try workbench.deleteTask(task_id);
    try waitTaskDeleted(&workbench, task_id);
    fake_core.lock();
    const abort_calls = fake_core.compact_abort_calls;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), abort_calls);
}

test "Product Control terminal compact result wins a too-late cancellation race" {
    fake_core.reset();
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 2,
        .max_sessions = 1,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var workbench = try product_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 2,
            .max_tasks = 1,
            .max_runs_per_task = 1,
            .max_compacts_per_task = 1,
            .max_tools_per_run = 1,
        },
        productControlConfiguration(),
    );
    defer workbench.deinit();
    try installControlExecution(&workbench);

    const task_id = try workbench.createTask(productControlTaskInput(), try product_control.TestSupport.fixtureModelSelection(&workbench));
    _ = try runPreparedTask(&workbench, task_id, .{ .text = "establish conversation" });
    try waitControlSnapshot(&workbench, "\"terminal\":{\"outcome\":\"completed\"");
    fake_core.setSessionPlan(.controlled);
    fake_core.rearmControlled();
    fake_core.forceNextCompactAbortStatus(wire.STATUS_TOO_LATE);
    const operation_id = try workbench.compactTaskAtBinding(task_id, 1);
    try waitControlSnapshot(&workbench, "\"phase\":\"compacting\"");
    try workbench.cancelCompact(task_id, operation_id);
    try waitControlSnapshot(&workbench, "\"phase\":\"stopping\"");
    fake_core.releaseControlled();
    try waitControlSnapshot(&workbench, "\"phase\":\"compacted\"");
    try waitControlSnapshot(&workbench, "\"activeOperation\":null");
    try std.testing.expectError(
        error.NoSuchCompact,
        workbench.cancelCompact(task_id, operation_id),
    );
}

test "Product Control coverage saves queued Run cancellation before and after the event drain" {
    fake_core.reset();
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 2, .max_sessions = 2 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var persistence: CoverageCommitProbe = .{};
    var configuration = productControlConfiguration();
    configuration.task_persistence = persistence.capability();
    var workbench = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, .{
        .worker_count = 1,
        .queue_capacity = 2,
        .max_tasks = 2,
        .max_runs_per_task = 2,
        .max_tools_per_run = 1,
    }, configuration);
    defer workbench.deinit();
    defer persistence.record_id = 0;
    defer fake_core.releaseControlled();
    try installControlExecution(&workbench);
    const blocker_id = try workbench.createTask(productControlTaskInput(), try product_control.TestSupport.fixtureModelSelection(&workbench));
    const target_id = try workbench.createTask(productControlTaskInput(), try product_control.TestSupport.fixtureModelSelection(&workbench));
    try workbench.renameTask(target_id, "queued cancellation target");
    fake_core.setSessionPlan(.controlled);
    _ = try runPreparedTask(&workbench, blocker_id, .{ .text = "occupy the worker" });
    try waitControlSnapshot(&workbench, "\"currentRunPhase\":\"running\"");
    const run_id = try runPreparedTask(&workbench, target_id, .{ .text = "cancel while queued" });
    const task = workbench.task_runtime.find(target_id).?;
    const run = task_state.findRun(task.durable.runs, run_id).?;
    persistence.watch(&workbench, target_id, run_id, false);
    try workbench.cancel(target_id, run_id);
    try persistence.expect(0, "running", .pending);
    try std.testing.expect(run.terminal_observed);
    try std.testing.expect(!run.event_stream_finalized);
    try std.testing.expect(task_state.terminalPayload(run).?.exclude_on_product_terminal);
    try std.testing.expect(workbench.task_persistence_health == .ready);
    const commits_after_cancel = persistence.count;
    try workbench.cancel(target_id, run_id);
    try std.testing.expectEqual(commits_after_cancel, persistence.count);
    try workbench.drainAgentEvents();
    try std.testing.expect(persistence.count > commits_after_cancel);
    try persistence.expect(persistence.count - 1, "cancelled", .excluded);
    try std.testing.expect(run.event_stream_finalized);
    const commits_after_drain = persistence.count;
    try workbench.drainAgentEvents();
    try std.testing.expectEqual(commits_after_drain, persistence.count);
}

test "Product Control coverage saves queued compact cancellation without entering AgentCore" {
    fake_core.reset();
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 2,
        .max_sessions = 2,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var persistence: CoverageCommitProbe = .{};
    var configuration = productControlConfiguration();
    configuration.task_persistence = persistence.capability();
    var workbench = try product_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 2,
            .max_tasks = 2,
            .max_runs_per_task = 2,
            .max_compacts_per_task = 1,
            .max_tools_per_run = 1,
        },
        configuration,
    );
    defer workbench.deinit();
    defer persistence.record_id = 0;
    try installControlExecution(&workbench);

    const blocking_task_id = try workbench.createTask(productControlTaskInput(), try product_control.TestSupport.fixtureModelSelection(&workbench));
    const compact_task_id = try workbench.createTask(productControlTaskInput(), try product_control.TestSupport.fixtureModelSelection(&workbench));
    try workbench.renameTask(blocking_task_id, "blocking target");
    try workbench.renameTask(compact_task_id, "compact target");
    _ = try runPreparedTask(&workbench, blocking_task_id, .{ .text = "first conversation" });
    try waitTaskSnapshot(
        &workbench,
        "\"title\":\"blocking target\"",
        "\"terminal\":{\"outcome\":\"completed\"",
    );
    _ = try runPreparedTask(&workbench, compact_task_id, .{ .text = "second conversation" });
    try waitTaskSnapshot(
        &workbench,
        "\"title\":\"compact target\"",
        "\"terminal\":{\"outcome\":\"completed\"",
    );

    fake_core.setSessionPlan(.controlled);
    fake_core.rearmControlled();
    const blocking_run_id = try runPreparedTask(
        &workbench,
        blocking_task_id,
        .{ .text = "occupy the only worker" },
    );
    try waitControlSnapshot(&workbench, "\"currentRunPhase\":\"running\"");
    const operation_id = try workbench.compactTaskAtBinding(compact_task_id, 1);
    try waitControlSnapshot(&workbench, "\"phase\":\"queued\"");
    persistence.watch(&workbench, compact_task_id, operation_id, true);
    try workbench.cancelCompact(compact_task_id, operation_id);
    try persistence.expect(0, "stopping", .pending);
    try std.testing.expect(persistence.count >= 2);
    try persistence.expect(persistence.count - 1, "aborted", .excluded);
    try std.testing.expect(workbench.task_persistence_health == .ready);
    try waitControlSnapshot(&workbench, "\"phase\":\"aborted\"");
    fake_core.lock();
    const compact_calls = fake_core.compact_calls;
    const compact_abort_calls = fake_core.compact_abort_calls;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 0), compact_calls);
    try std.testing.expectEqual(@as(usize, 0), compact_abort_calls);

    try workbench.cancel(blocking_task_id, blocking_run_id);
    try waitControlSnapshot(&workbench, "\"terminal\":{\"outcome\":\"cancelled\"");
}

fn expectWorkerFailureCoverage(compact_operation: bool) !void {
    fake_core.reset();
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 2, .max_sessions = 2 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var persistence: CoverageCommitProbe = .{};
    var gate: TerminalPublicationGate = .{};
    var configuration = productControlConfiguration();
    configuration.task_persistence = persistence.capability();
    configuration.change_notifier = .{ .context = &gate, .wake = TerminalPublicationGate.wake };
    var workbench = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, .{
        .worker_count = 1,
        .queue_capacity = 2,
        .max_tasks = 2,
        .max_runs_per_task = 2,
        .max_compacts_per_task = 1,
        .max_tools_per_run = 1,
    }, configuration);
    defer workbench.deinit();
    defer persistence.record_id = 0;
    defer gate.release();
    defer fake_core.releaseControlled();
    try installControlExecution(&workbench);
    const blocker_id = try workbench.createTask(productControlTaskInput(), try product_control.TestSupport.fixtureModelSelection(&workbench));
    const target_id = try workbench.createTask(productControlTaskInput(), try product_control.TestSupport.fixtureModelSelection(&workbench));
    try workbench.renameTask(target_id, "worker failure target");
    if (compact_operation) {
        _ = try runPreparedTask(&workbench, target_id, .{ .text = "establish Conversation" });
        try waitControlSnapshot(&workbench, "\"terminal\":{\"outcome\":\"completed\"");
    }
    fake_core.setSessionPlan(.controlled);
    fake_core.rearmControlled();
    _ = try runPreparedTask(&workbench, blocker_id, .{ .text = "occupy the worker" });
    try waitControlSnapshot(&workbench, "\"currentRunPhase\":\"running\"");
    const operation_id = if (compact_operation)
        try workbench.compactTaskAtBinding(target_id, 1)
    else
        try runPreparedTask(&workbench, target_id, .{ .text = "fail the worker handoff" });
    const task = workbench.task_runtime.find(target_id).?;
    // Invalidate the Agent reservation before Executor claims the job. This
    // exercises the actual beginRunOutcome failure / executePreparedCompact
    // error branches, rather than a failed Core terminal result.
    var access = try task.runtime.acquireAccess();
    if (compact_operation) {
        try access.cancelPreparedCompact(operation_id);
        gate.arm(.{ .compact = task_state.findCompact(task.durable.compacts, operation_id).? });
    } else {
        try access.cancelPreparedRun(operation_id);
        gate.arm(.{ .run = task_state.findRun(task.durable.runs, operation_id).? });
    }
    access.deinit();
    fake_core.lock();
    const run_calls_before = fake_core.run_calls;
    const compact_calls_before = fake_core.compact_calls;
    fake_core.unlock();
    fake_core.releaseControlled();
    try gate.wait();

    if (compact_operation) {
        const compact = task_state.findCompact(task.durable.compacts, operation_id).?;
        const terminal = task_state.compactTerminalPayload(compact).?;
        try std.testing.expect(terminal.exclude_on_product_terminal);
        try std.testing.expectEqual(task_state.CompactCause.dependency_contract_failure, terminal.cause.?);
        try std.testing.expect(!compact.terminal_observed);
        try std.testing.expect(!task_execution.commitCompactProductTerminal(
            .{ .project_fn = task_execution.projectSanitized },
            compact,
            .compacted,
            null,
            .reusable,
            .{},
            0,
            0,
            "",
            false,
            false,
        ));
        try std.testing.expect(terminal.exclude_on_product_terminal);
    } else {
        const run = task_state.findRun(task.durable.runs, operation_id).?;
        const terminal = task_state.terminalPayload(run).?;
        try std.testing.expect(terminal.exclude_on_product_terminal);
        try std.testing.expectEqual(task_state.RunOutcome.dependency_contract_failure, terminal.outcome);
        try std.testing.expect(!run.event_stream_finalized);
        try std.testing.expect(!task_execution.commitRunTerminal(
            .{ .project_fn = task_execution.projectSanitized },
            run,
            .completed,
            .completed,
            null,
            .reusable,
            "",
            false,
            false,
            null,
            false,
        ));
        try std.testing.expect(terminal.exclude_on_product_terminal);
    }
    persistence.watch(&workbench, target_id, operation_id, compact_operation);
    // Deliberately save before any lifecycle reconciliation. Production
    // publication and the real writer gate are both exercised here.
    try product_control.TestSupport.commitTaskHistory(&workbench);
    try persistence.expect(0, if (compact_operation) "compacting" else "running", .pending);
    try workbench.drainAgentEvents();
    try std.testing.expect(persistence.count >= 2);
    try persistence.expect(persistence.count - 1, "failed", .excluded);
    try std.testing.expect(workbench.task_persistence_health == .ready);
    fake_core.lock();
    const run_calls_after = fake_core.run_calls;
    const compact_calls_after = fake_core.compact_calls;
    fake_core.unlock();
    try std.testing.expectEqual(run_calls_before, run_calls_after);
    try std.testing.expectEqual(compact_calls_before, compact_calls_after);
}

test "Product Control coverage saves a worker begin failure before its terminal event drain" {
    try expectWorkerFailureCoverage(false);
}

test "Product Control coverage saves a worker compact call error before terminal observation" {
    try expectWorkerFailureCoverage(true);
}

test "Product Control shutdown terminates a waiting UI Run before joining workers" {
    fake_core.reset();
    fake_core.setNextPlan(.ui_wait);
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var workbench = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, .{
        .worker_count = 1,
        .queue_capacity = 2,
        .max_tasks = 1,
        .max_runs_per_task = 1,
        .max_tools_per_run = 1,
    }, productControlConfiguration());
    defer workbench.deinit();
    try installControlExecution(&workbench);

    const task_id = try workbench.createTask(productControlTaskInput(), try product_control.TestSupport.fixtureModelSelection(&workbench));
    _ = try runPreparedTask(&workbench, task_id, .{ .text = "wait for shutdown" });
    try waitControlSnapshot(&workbench, "\"currentRunPhase\":\"waiting_ui\"");
    workbench.shutdownExecutor();
    try waitControlSnapshot(&workbench, "\"terminal\":{\"outcome\":\"interrupted\"");
    try waitControlSnapshot(&workbench, "\"continuationAvailable\":false");
}

test "graceful shutdown checkpoints an interrupted Run and restart continues with the next id" {
    fake_core.reset();
    fake_core.setCheckpointGeneration(1);
    const home = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(home);
    var checkpoint_tmp = std.testing.tmpDir(.{});
    defer checkpoint_tmp.cleanup();
    var checkpoint_root_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const checkpoint_root_len = try checkpoint_tmp.dir.realPath(
        std.testing.io,
        &checkpoint_root_storage,
    );
    var checkpoint_store = try product_task.checkpoint_store.FileStore.init(
        std.testing.io,
        checkpoint_root_storage[0..checkpoint_root_len],
    );
    defer checkpoint_store.deinit();
    const persistence_storage = try std.testing.allocator.alloc(
        u8,
        product_task.history.max_store_bytes,
    );
    defer std.testing.allocator.free(persistence_storage);
    var persistence = TaskPersistenceProbe{ .storage = persistence_storage };

    var runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 2,
        .max_sessions = 1,
    });
    var runtime_live = true;
    defer if (runtime_live) {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    };
    var first_configuration = productControlConfiguration();
    first_configuration.directories.canonical_user_home = home;
    first_configuration.task_persistence = persistence.capability();
    first_configuration.checkpoint_store = .{ .file_store = &checkpoint_store };
    var first = try product_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 2,
            .max_tasks = 1,
            .max_runs_per_task = 3,
            .max_tools_per_run = 1,
        },
        first_configuration,
    );
    var first_live = true;
    defer if (first_live) first.deinit();
    try installControlExecution(&first);
    const task_id = try first.createTask(productControlTaskInput(), try product_control.TestSupport.fixtureModelSelection(&first));
    try std.testing.expectEqual(
        @as(u64, 1),
        try runPreparedTask(&first, task_id, .{ .text = "checkpoint before shutdown" }),
    );
    try waitCheckpointRecord(&first, &persistence);

    fake_core.setCheckpointGeneration(2);
    fake_core.setSessionPlan(.controlled);
    fake_core.rearmControlled();
    try std.testing.expectEqual(
        @as(u64, 2),
        try runPreparedTask(&first, task_id, .{ .text = "interrupt this Run during shutdown" }),
    );
    try waitControlSnapshot(&first, "\"currentRunPhase\":\"running\"");
    first.shutdownExecutor();
    const shutdown_history = persistence_storage[0..persistence.len];
    try std.testing.expect(std.mem.indexOf(
        u8,
        shutdown_history,
        "\"last_run_id\":2,\"last_compact_id\":0",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        shutdown_history,
        "\"id\":2,\"coverage\":\"covered\"",
    ) != null);
    const restart_history = try std.testing.allocator.dupe(u8, shutdown_history);
    defer std.testing.allocator.free(restart_history);
    first.deinit();
    first_live = false;
    try shutdownTestComposition(runtime);
    deinitTestComposition(runtime);
    runtime_live = false;

    fake_core.reset();
    fake_core.setRestoreHistory(2, 0);
    fake_core.setCheckpointGeneration(2);
    runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 2,
        .max_sessions = 1,
    });
    runtime_live = true;
    var restored_configuration = productControlConfiguration();
    restored_configuration.directories.canonical_user_home = home;
    restored_configuration.task_persistence = persistence.capabilityRestored(restart_history);
    restored_configuration.checkpoint_store = .{ .file_store = &checkpoint_store };
    var restored = try product_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 2,
            .max_tasks = 1,
            .max_runs_per_task = 3,
            .max_tools_per_run = 1,
        },
        restored_configuration,
    );
    defer restored.deinit();
    try installControlExecution(&restored);
    _ = try restored.openWorkspace(productControlTaskInput());
    try waitTaskSnapshot(
        &restored,
        "\"id\":\"1\"",
        "\"continuationRecoveryAvailable\":true",
    );
    _ = try restored.restoreTaskConversation(
        task_id,
        try restored.taskBindingEpoch(task_id),
    );
    try waitTaskSnapshot(
        &restored,
        "\"id\":\"1\"",
        "\"continuationAvailable\":true",
    );
    fake_core.setCheckpointGeneration(3);
    try std.testing.expectEqual(
        @as(u64, 3),
        try runPreparedTask(&restored, task_id, .{ .text = "continue after restart" }),
    );
    try waitTaskSnapshot(
        &restored,
        "\"id\":\"3\",\"conversationCoverage\":\"included\",\"phase\":\"completed\"",
        "\"outcome\":\"completed\"",
    );
}

test "checkpoint restore preserves Product Run and UI request allocation floors" {
    fake_core.reset();
    fake_core.setCheckpointGeneration(1);
    const home = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(home);
    var checkpoint_tmp = std.testing.tmpDir(.{});
    defer checkpoint_tmp.cleanup();
    var checkpoint_root_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const checkpoint_root_len = try checkpoint_tmp.dir.realPath(
        std.testing.io,
        &checkpoint_root_storage,
    );
    var checkpoint_store = try product_task.checkpoint_store.FileStore.init(
        std.testing.io,
        checkpoint_root_storage[0..checkpoint_root_len],
    );
    defer checkpoint_store.deinit();
    const persistence_storage = try std.testing.allocator.alloc(
        u8,
        product_task.history.max_store_bytes,
    );
    defer std.testing.allocator.free(persistence_storage);
    var persistence = TaskPersistenceProbe{ .storage = persistence_storage };

    var runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 2,
        .max_sessions = 1,
    });
    var runtime_live = true;
    defer if (runtime_live) {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    };
    var first_configuration = productControlConfiguration();
    first_configuration.directories.canonical_user_home = home;
    first_configuration.task_persistence = persistence.capability();
    first_configuration.checkpoint_store = .{ .file_store = &checkpoint_store };
    var first = try product_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 2,
            .max_tasks = 1,
            .max_runs_per_task = 3,
            .max_tools_per_run = 1,
        },
        first_configuration,
    );
    var first_live = true;
    defer if (first_live) first.deinit();
    try installControlExecution(&first);
    const task_id = try first.createTask(productControlTaskInput(), try product_control.TestSupport.fixtureModelSelection(&first));
    fake_core.setSessionPlan(.ui_wait);
    fake_core.rearmControlled();
    try std.testing.expectEqual(
        @as(u64, 1),
        try runPreparedTask(&first, task_id, .{ .text = "resolve permission before checkpoint" }),
    );
    try waitTaskSnapshot(
        &first,
        "\"currentRunPhase\":\"waiting_ui\"",
        "\"pendingUi\":{\"requestId\":\"1\",\"runId\":\"1\"",
    );
    try first.respondUi(task_id, 1, 1, .{ .permission = .allow_once });
    try waitTaskSnapshot(
        &first,
        "\"currentRunPhase\":\"running\"",
        "\"uiHistory\":[{\"requestId\":\"1\",\"runId\":\"1\"",
    );
    fake_core.releaseControlled();
    try waitCheckpointRecord(&first, &persistence);

    fake_core.setSessionPlan(.controlled);
    fake_core.rearmControlled();
    try std.testing.expectEqual(
        @as(u64, 2),
        try runPreparedTask(&first, task_id, .{ .text = "killed before terminal" }),
    );
    try waitControlSnapshot(&first, "\"currentRunPhase\":\"running\"");
    const killed_history = try std.testing.allocator.dupe(
        u8,
        persistence_storage[0..persistence.len],
    );
    defer std.testing.allocator.free(killed_history);
    try std.testing.expect(std.mem.indexOf(
        u8,
        killed_history,
        "\"id\":2,\"coverage\":\"pending\"",
    ) != null);

    // Cleanup must retain checkpoint 1; the copied bytes above are the exact
    // crash image used by the second Product Runtime.
    fake_core.forceNextCheckpointExportStatus(wire.STATUS_RESOURCE_LIMIT);
    first.shutdownExecutor();
    first.deinit();
    first_live = false;
    try shutdownTestComposition(runtime);
    deinitTestComposition(runtime);
    runtime_live = false;

    fake_core.reset();
    fake_core.setRestoreHistory(1, 0);
    fake_core.setCheckpointGeneration(1);
    runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 2,
        .max_sessions = 1,
    });
    runtime_live = true;
    var restored_configuration = productControlConfiguration();
    restored_configuration.directories.canonical_user_home = home;
    restored_configuration.task_persistence = persistence.capabilityRestored(killed_history);
    restored_configuration.checkpoint_store = .{ .file_store = &checkpoint_store };
    var restored = try product_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 2,
            .max_tasks = 1,
            .max_runs_per_task = 3,
            .max_tools_per_run = 1,
        },
        restored_configuration,
    );
    defer restored.deinit();
    try installControlExecution(&restored);
    _ = try restored.openWorkspace(productControlTaskInput());
    try waitTaskSnapshot(
        &restored,
        "\"id\":\"1\"",
        "\"continuationRecoveryAvailable\":true",
    );
    try waitTaskSnapshot(
        &restored,
        "\"id\":\"1\"",
        "\"id\":\"2\",\"conversationCoverage\":\"excluded\",\"phase\":\"interrupted\"",
    );
    _ = try restored.restoreTaskConversation(
        task_id,
        try restored.taskBindingEpoch(task_id),
    );
    try waitTaskSnapshot(
        &restored,
        "\"id\":\"1\"",
        "\"continuationAvailable\":true",
    );
    fake_core.setSessionPlan(.ui_wait);
    fake_core.rearmControlled();
    fake_core.setCheckpointGeneration(2);
    try std.testing.expectEqual(
        @as(u64, 3),
        try runPreparedTask(&restored, task_id, .{ .text = "request permission after checkpoint restore" }),
    );
    try waitTaskSnapshot(
        &restored,
        "\"pendingUi\":{\"requestId\":\"2\",\"runId\":\"3\"",
        "\"uiHistory\":[{\"requestId\":\"1\",\"runId\":\"1\"",
    );
    try restored.respondUi(task_id, 3, 2, .{ .permission = .allow_once });
    fake_core.releaseControlled();
    try waitTaskSnapshot(
        &restored,
        "\"id\":\"3\",\"conversationCoverage\":\"included\",\"phase\":\"completed\"",
        "\"outcome\":\"completed\"",
    );
}

test "fresh attach preserves Product Run and UI request allocation floors" {
    fake_core.reset();
    const home = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(home);
    const persistence_storage = try std.testing.allocator.alloc(
        u8,
        product_task.history.max_store_bytes,
    );
    defer std.testing.allocator.free(persistence_storage);
    var persistence = TaskPersistenceProbe{ .storage = persistence_storage };

    var runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 2,
        .max_sessions = 1,
    });
    var runtime_live = true;
    defer if (runtime_live) {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    };
    var first_configuration = productControlConfiguration();
    first_configuration.directories.canonical_user_home = home;
    first_configuration.task_persistence = persistence.capability();
    var first = try product_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 2,
            .max_tasks = 1,
            .max_runs_per_task = 2,
            .max_tools_per_run = 1,
        },
        first_configuration,
    );
    var first_live = true;
    defer if (first_live) first.deinit();
    try installControlExecution(&first);
    const task_id = try first.createTask(productControlTaskInput(), try product_control.TestSupport.fixtureModelSelection(&first));
    fake_core.setSessionPlan(.ui_wait);
    fake_core.rearmControlled();
    try std.testing.expectEqual(
        @as(u64, 1),
        try runPreparedTask(&first, task_id, .{ .text = "resolve permission before first checkpoint" }),
    );
    try waitTaskSnapshot(
        &first,
        "\"currentRunPhase\":\"waiting_ui\"",
        "\"pendingUi\":{\"requestId\":\"1\",\"runId\":\"1\"",
    );
    try first.respondUi(task_id, 1, 1, .{ .permission = .allow_once });
    try waitTaskSnapshot(
        &first,
        "\"currentRunPhase\":\"running\"",
        "\"uiHistory\":[{\"requestId\":\"1\",\"runId\":\"1\"",
    );
    const killed_history = try std.testing.allocator.dupe(
        u8,
        persistence_storage[0..persistence.len],
    );
    defer std.testing.allocator.free(killed_history);
    try std.testing.expect(std.mem.indexOf(
        u8,
        killed_history,
        "\"id\":1,\"coverage\":\"pending\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        killed_history,
        "\"ui_history\":[{\"request_id\":1,\"run_id\":1",
    ) != null);
    first.shutdownExecutor();
    first.deinit();
    first_live = false;
    try shutdownTestComposition(runtime);
    deinitTestComposition(runtime);
    runtime_live = false;

    fake_core.reset();
    runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 2,
        .max_sessions = 1,
    });
    runtime_live = true;
    var restored_configuration = productControlConfiguration();
    restored_configuration.directories.canonical_user_home = home;
    restored_configuration.task_persistence = persistence.capabilityRestored(killed_history);
    var restored = try product_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 2,
            .max_tasks = 1,
            .max_runs_per_task = 2,
            .max_tools_per_run = 1,
        },
        restored_configuration,
    );
    defer restored.deinit();
    try installControlExecutionGeneration(&restored, 2);
    _ = try restored.openWorkspace(productControlTaskInput());
    try waitTaskSnapshot(
        &restored,
        "\"id\":\"1\"",
        "\"continuationRecoveryAvailable\":true",
    );
    _ = try restored.restoreTaskConversation(
        task_id,
        try restored.taskBindingEpoch(task_id),
    );
    try waitTaskSnapshot(
        &restored,
        "\"id\":\"1\"",
        "\"continuationAvailable\":true",
    );
    const attached = restored.task_runtime.find(task_id).?;
    try std.testing.expectEqual(@as(u64, 2), attached.durable.binding_epoch);
    try std.testing.expectEqual(@as(u64, 3), attached.durable.execution_generation);
    try std.testing.expect(attached.durable.checkpoint == null);
    // The attachment is published only after the new binding is canonical.
    var canonical = try product_task.history.decode(std.testing.allocator, persistence_storage[0..persistence.len], .{
        .max_workspaces = 1,
        .max_tasks = 1,
        .max_runs_per_task = 2,
        .max_compacts_per_task = 8,
        .max_tools_per_run = 8,
        .max_commentary_segments_per_run = 64,
        .max_file_refs_per_tool = 8,
        .max_ui_history_per_task = 8,
        .max_workspace_bytes = 4096,
        .max_task_title_bytes = 512,
        .max_user_message_bytes = 4096,
        .max_assistant_message_bytes = 4096,
        .max_tool_field_bytes = 4096,
        .max_file_ref_field_bytes = 4096,
        .max_execution_model_bytes = 512,
        .max_terminal_diagnostic_bytes = 512,
    });
    defer canonical.deinit();
    const binding = canonical.value.tasks[0].binding;
    try std.testing.expectEqual(@as(u64, 2), binding.epoch);
    try std.testing.expectEqual(@as(u64, 3), binding.execution_generation);
    fake_core.lock();
    const restore_calls = fake_core.checkpoint_restores;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 0), restore_calls);
    fake_core.setSessionPlan(.ui_wait);
    fake_core.rearmControlled();
    try std.testing.expectEqual(
        @as(u64, 2),
        try runPreparedTask(&restored, task_id, .{ .text = "request permission after fresh attach" }),
    );
    try waitTaskSnapshot(
        &restored,
        "\"pendingUi\":{\"requestId\":\"2\",\"runId\":\"2\"",
        "\"uiHistory\":[{\"requestId\":\"1\",\"runId\":\"1\"",
    );
    try restored.respondUi(task_id, 2, 2, .{ .permission = .allow_once });
    fake_core.releaseControlled();
    try waitTaskSnapshot(
        &restored,
        "\"id\":\"2\",\"conversationCoverage\":\"included\",\"phase\":\"completed\"",
        "\"outcome\":\"completed\"",
    );
}

test "poisoned Session closes and the same Task continues with a fresh Conversation" {
    fake_core.reset();
    fake_core.setNextPlan(.invalid_result_layout);
    const home = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(home);
    const persistence_storage = try std.testing.allocator.alloc(
        u8,
        product_task.history.max_store_bytes,
    );
    defer std.testing.allocator.free(persistence_storage);
    var persistence = TaskPersistenceProbe{ .storage = persistence_storage };
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 2,
        .max_sessions = 1,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var configuration = productControlConfiguration();
    configuration.directories.canonical_user_home = home;
    configuration.task_persistence = persistence.capability();
    var workbench = try product_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 2,
            .max_tasks = 1,
            .max_runs_per_task = 2,
            .max_tools_per_run = 1,
        },
        configuration,
    );
    defer workbench.deinit();
    try installControlExecution(&workbench);

    const task_id = try workbench.createTask(productControlTaskInput(), try product_control.TestSupport.fixtureModelSelection(&workbench));
    try std.testing.expectEqual(
        @as(u64, 1),
        try runPreparedTask(&workbench, task_id, .{ .text = "poison this Session" }),
    );
    try waitTaskSnapshot(
        &workbench,
        "\"id\":\"1\"",
        "\"conversationCoverage\":\"excluded\",\"phase\":\"failed\"",
    );
    try waitTaskSnapshot(
        &workbench,
        "\"id\":\"1\"",
        "\"continuationRecoveryAvailable\":true",
    );
    fake_core.lock();
    const destroyed_after_poison = fake_core.session_destroyed;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), destroyed_after_poison);

    _ = try workbench.restoreTaskConversation(
        task_id,
        try workbench.taskBindingEpoch(task_id),
    );
    try waitTaskSnapshot(
        &workbench,
        "\"id\":\"1\"",
        "\"continuationAvailable\":true",
    );
    try std.testing.expectEqual(
        @as(u64, 2),
        try runPreparedTask(&workbench, task_id, .{ .text = "continue the same Task" }),
    );
    try waitTaskSnapshot(
        &workbench,
        "\"id\":\"2\",\"conversationCoverage\":\"included\",\"phase\":\"completed\"",
        "\"outcome\":\"completed\"",
    );
}

test "queued pre-Core shutdown tail stays visible but does not invalidate its checkpoint" {
    fake_core.reset();
    fake_core.setCheckpointGeneration(1);
    const home = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(home);
    var checkpoint_tmp = std.testing.tmpDir(.{});
    defer checkpoint_tmp.cleanup();
    var checkpoint_root_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const checkpoint_root_len = try checkpoint_tmp.dir.realPath(
        std.testing.io,
        &checkpoint_root_storage,
    );
    var checkpoint_store = try product_task.checkpoint_store.FileStore.init(
        std.testing.io,
        checkpoint_root_storage[0..checkpoint_root_len],
    );
    defer checkpoint_store.deinit();
    const persistence_storage = try std.testing.allocator.alloc(
        u8,
        product_task.history.max_store_bytes,
    );
    defer std.testing.allocator.free(persistence_storage);
    var persistence = TaskPersistenceProbe{ .storage = persistence_storage };

    var runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 2,
        .max_sessions = 2,
    });
    var runtime_live = true;
    defer if (runtime_live) {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    };
    var first_configuration = productControlConfiguration();
    first_configuration.directories.canonical_user_home = home;
    first_configuration.task_persistence = persistence.capability();
    first_configuration.checkpoint_store = .{ .file_store = &checkpoint_store };
    var first = try product_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 2,
            .max_tasks = 2,
            .max_runs_per_task = 3,
            .max_tools_per_run = 1,
        },
        first_configuration,
    );
    var first_live = true;
    defer if (first_live) first.deinit();
    try installControlExecution(&first);
    const continuation_task = try first.createTask(productControlTaskInput(), try product_control.TestSupport.fixtureModelSelection(&first));
    try first.renameTask(continuation_task, "continuation target");
    try std.testing.expectEqual(
        @as(u64, 1),
        try runPreparedTask(&first, continuation_task, .{ .text = "durable checkpoint" }),
    );
    try waitCheckpointRecord(&first, &persistence);

    const blocker_task = try first.createTask(productControlTaskInput(), try product_control.TestSupport.fixtureModelSelection(&first));
    try first.renameTask(blocker_task, "executor blocker");
    // A Run can occupy the executor queue only after its Skill query completes.
    try std.testing.expectError(error.CatalogLoading, first.runTask(continuation_task, .{ .text = "never entered AgentCore" }));
    try settleWorkspaceSkillQueries(&first, try first.taskWorkspaceId(continuation_task));
    fake_core.setSessionPlan(.controlled);
    fake_core.rearmControlled();
    _ = try runPreparedTask(&first, blocker_task, .{ .text = "occupy executor" });
    try waitTaskSnapshot(
        &first,
        "\"title\":\"executor blocker\"",
        "\"currentRunPhase\":\"running\"",
    );
    try std.testing.expectEqual(
        @as(u64, 2),
        try runPreparedTask(&first, continuation_task, .{ .text = "never entered AgentCore" }),
    );
    try waitTaskSnapshot(
        &first,
        "\"title\":\"continuation target\"",
        "\"currentRunPhase\":\"queued\"",
    );
    first.shutdownExecutor();
    fake_core.lock();
    const run_calls_before_restart = fake_core.run_calls;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 2), run_calls_before_restart);
    const shutdown_history = persistence_storage[0..persistence.len];
    try std.testing.expect(std.mem.indexOf(
        u8,
        shutdown_history,
        "\"id\":2,\"coverage\":\"excluded\"",
    ) != null);
    const restart_history = try std.testing.allocator.dupe(u8, shutdown_history);
    defer std.testing.allocator.free(restart_history);
    first.deinit();
    first_live = false;
    try shutdownTestComposition(runtime);
    deinitTestComposition(runtime);
    runtime_live = false;

    fake_core.reset();
    fake_core.setRestoreHistory(1, 0);
    fake_core.setCheckpointGeneration(1);
    runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 2,
        .max_sessions = 2,
    });
    runtime_live = true;
    var restored_configuration = productControlConfiguration();
    restored_configuration.directories.canonical_user_home = home;
    restored_configuration.task_persistence = persistence.capabilityRestored(restart_history);
    restored_configuration.checkpoint_store = .{ .file_store = &checkpoint_store };
    var restored = try product_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 2,
            .max_tasks = 2,
            .max_runs_per_task = 3,
            .max_tools_per_run = 1,
        },
        restored_configuration,
    );
    defer restored.deinit();
    try installControlExecution(&restored);
    _ = try restored.openWorkspace(productControlTaskInput());
    try waitTaskSnapshot(
        &restored,
        "\"title\":\"continuation target\"",
        "\"continuationRecoveryAvailable\":true",
    );
    _ = try restored.restoreTaskConversation(
        continuation_task,
        try restored.taskBindingEpoch(continuation_task),
    );
    try waitTaskSnapshot(
        &restored,
        "\"title\":\"continuation target\"",
        "\"continuationAvailable\":true",
    );
    fake_core.setCheckpointGeneration(2);
    try std.testing.expectEqual(
        @as(u64, 3),
        try runPreparedTask(
            &restored,
            continuation_task,
            .{ .text = "continue after queued tail" },
        ),
    );
    try waitTaskSnapshot(
        &restored,
        "\"title\":\"continuation target\"",
        "\"id\":\"3\",\"conversationCoverage\":\"included\",\"phase\":\"completed\"",
    );
}

test "Product Control shutdown rejects new Task admission without creating product state" {
    fake_core.reset();
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var workbench = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, .{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_tasks = 1,
        .max_runs_per_task = 1,
        .max_tools_per_run = 1,
    }, productControlConfiguration());
    defer workbench.deinit();

    workbench.shutdownExecutor();
    try std.testing.expectError(
        error.ExecutorShuttingDown,
        workbench.createTask(productControlTaskInput(), try product_control.TestSupport.fixtureModelSelection(&workbench)),
    );
    try std.testing.expectEqual(@as(u64, 0), workbench.currentRevision());

    var snapshot_storage: [8192]u8 = undefined;
    const snapshot = try workbench.writeAggregateFixture(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"tasks\":[]") != null);
}

test "late event from a finalized Run is dropped and newer active work continues" {
    fake_core.reset();
    fake_core.setNextPlan(.controlled);
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var workbench = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, .{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_tasks = 1,
        .max_runs_per_task = 2,
        .max_tools_per_run = 1,
    }, productControlConfiguration());
    defer workbench.deinit();
    try installControlExecution(&workbench);

    const task_id = try workbench.createTask(productControlTaskInput(), try product_control.TestSupport.fixtureModelSelection(&workbench));
    const first_run_id = try runPreparedTask(
        &workbench,
        task_id,
        .{ .text = "finish first" },
    );
    try waitControlSnapshot(&workbench, "\"currentRunPhase\":\"running\"");
    fake_core.releaseControlled();
    try waitControlSnapshot(&workbench, "\"terminal\":{\"outcome\":\"completed\"");

    fake_core.rearmControlled();
    _ = try runPreparedTask(&workbench, task_id, .{ .text = "new active work" });
    try waitControlSnapshot(&workbench, "\"currentRunPhase\":\"running\"");

    const encoded = "{\"text_chunk\":\"late\"}";
    var late_event = lifecycle.OwnedCoreEvent{
        .session_id = task_id,
        .run_id = first_run_id,
        .encoded_bytes = encoded.len,
        .json = try std.testing.allocator.dupe(u8, encoded),
        .event = try lifecycle.decodeCoreEvent(std.testing.allocator, encoded),
        .allocator = std.testing.allocator,
    };
    defer late_event.deinit();
    try workbench.applyEvent(&late_event);
    try std.testing.expectEqual(@as(u64, 1), workbench.testLateTerminalEventCount());

    var snapshot_storage: [128 * 1024]u8 = undefined;
    const open_snapshot = try workbench.writeAggregateFixture(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(u8, open_snapshot, "\"lifecycle\":\"open\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, open_snapshot, "\"currentRunPhase\":\"running\"") != null);
    fake_core.releaseControlled();
    try waitControlSnapshot(&workbench, "\"terminal\":{\"outcome\":\"completed\"");
}

test "expanded text and file limits reach AgentCore intact and reject overflow before consumption" {
    fake_core.reset();
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 2,
        .max_sessions = 1,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_storage);
    var automatic_root = try product_control.AutomaticWorkspaceRoot.open(
        std.testing.io,
        std.testing.allocator,
        root_storage[0..root_len],
    );
    defer automatic_root.deinit();
    var attachment_store = try product_control.AttachmentFileStore.init(std.testing.io, std.testing.allocator, root_storage[0..root_len]);
    defer attachment_store.deinit();
    var workbench = try product_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 2,
            .max_workspaces = 1,
            .max_tasks = 1,
            .max_runs_per_task = 2,
            .max_tools_per_run = 1,
        },
        .{ .attachment_store = &attachment_store, .attachment_images = .{ .prepare_fn = fixture.prepareTestAttachmentImage }, .directories = .{ .testing_automatic_workspace_root = &automatic_root } },
    );
    defer workbench.deinit();
    try installControlExecution(&workbench);

    const limits = product_control.Limits{};
    const text = try std.testing.allocator.alloc(u8, limits.max_user_message_bytes + 1);
    defer std.testing.allocator.free(text);
    @memset(text, 'x');
    const file = try std.testing.allocator.alloc(u8, limits.max_attachment_file_bytes + 1);
    defer std.testing.allocator.free(file);
    @memset(file, 'f');
    var descriptors: [8]product_control.AttachmentDescriptor = undefined;
    try std.testing.expectError(error.FileTooLarge, workbench.stageAttachments(
        &.{.{ .display_name = "build.log", .bytes = file }},
        &descriptors,
    ));
    const candidates = [_]product_control.AttachmentCandidate{
        .{ .display_name = "build.log", .bytes = file[0 .. file.len - 1] },
    } ** 8;
    const staged = try workbench.stageAttachments(&candidates, &descriptors);
    var ids: [8]u64 = undefined;
    for (staged, &ids) |descriptor, *id| {
        try std.testing.expect(descriptor.kind == .file);
        try std.testing.expectEqual(limits.max_attachment_file_bytes, descriptor.size_bytes);
        id.* = descriptor.id;
    }
    const task_id = try workbench.createTaskForWorkspace(.automatic, try product_control.TestSupport.fixtureModelSelection(&workbench), null, null, .{ .interactive = null });
    try std.testing.expectError(error.ProjectionCapacity, workbench.runTask(task_id, .{ .text = text }));
    try std.testing.expectError(error.ProjectionCapacity, workbench.runTask(task_id, .{
        .multimodal = .{ .text = text, .attachment_ids = &ids },
    }));
    // The Core receives bounded references, never the 800 MB of file bodies.
    fake_core.expected_multimodal_parts = null;
    fake_core.expected_multimodal_text = text[0 .. text.len - 1];
    const run_id = try runPreparedTask(&workbench, task_id, .{ .multimodal = .{
        .text = text[0 .. text.len - 1],
        .attachment_ids = &ids,
    } });
    var needle: [192]u8 = undefined;
    try waitControlSnapshot(&workbench, try std.fmt.bufPrint(
        &needle,
        "\"id\":\"{d}\",\"conversationCoverage\":\"included\",\"phase\":\"completed\"",
        .{run_id},
    ));
    try std.testing.expect(fake_core.multimodal_text_matches);
    try std.testing.expectEqual(@as(usize, 9), fake_core.multimodal_part_count);
    try std.testing.expectEqual(@as(usize, 8), fake_core.multimodal_reference_count);
    try std.testing.expect(fake_core.multimodal_prompt_bytes < limits.max_user_message_bytes + 8 * 8192);
    for (ids) |id| try std.testing.expect(!workbench.releaseAttachment(id));
}

test "approval mutation workers retain the same Session and historical Run permission facts" {
    for ([_]bool{ true, false }) |answer_before_full| {
        fake_core.reset();
        fake_core.setNextPlan(.ui_wait);
        const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 2, .max_sessions = 1 });
        defer {
            shutdownTestComposition(runtime) catch unreachable;
            deinitTestComposition(runtime);
        }
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        defer std.testing.allocator.free(home);
        var checkpoint_store = try product_task.checkpoint_store.FileStore.init(std.testing.io, home);
        defer checkpoint_store.deinit();
        const bytes = try std.testing.allocator.alloc(u8, 1024 * 1024);
        defer std.testing.allocator.free(bytes);
        var history = TaskPersistenceProbe{ .storage = bytes, .main_thread = std.Thread.getCurrentId() };
        var configuration = productControlConfiguration();
        configuration.directories.canonical_user_home = home;
        configuration.task_persistence = history.capability();
        configuration.checkpoint_store = .{ .file_store = &checkpoint_store };
        var control = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, .{ .worker_count = 1, .queue_capacity = 2, .max_workspaces = 1, .max_tasks = 1 }, configuration);
        defer control.deinit();
        try installControlExecution(&control);
        var input = productControlTaskInput();
        input.workspace_root = home;
        input.trust = .explicitly_trusted;
        input.approval_mode = .manual;
        const task_id = try control.createTask(input, try product_control.TestSupport.fixtureModelSelection(&control));
        const task = control.task_runtime.find(task_id).?;
        const epoch = task.durable.binding_epoch;
        const route = task.runtime.routeId();
        var original = try task.runtime.acquireAccess();
        const session_pointer = original.session;
        original.deinit();
        var expected_generation: u64 = 1;
        for ([_]product_control.ApprovalMode{ .full_access, .manual, .auto_review, .manual }) |target| {
            const prior_revision = task.durable.approval_revision;
            const prior_profile = task.durable.permission_profile;
            const ack = try control.setApprovalMode(task_id, target, epoch, prior_revision);
            try std.testing.expectEqual(prior_revision + 1, ack);
            try std.testing.expectEqual(prior_profile, task.durable.permission_profile);
            for (0..2000) |_| {
                control.syncLifecycle();
                if (task.approval_change == null) break;
                try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
            }
            try std.testing.expect(task.approval_change == null);
            try std.testing.expectEqual(.completed, task.approval_result.?.outcome);
            try std.testing.expectEqual(target, try control.taskApprovalMode(task_id));
            try std.testing.expectEqual(ack, task.durable.approval_revision);
            try std.testing.expectEqual(epoch, task.durable.binding_epoch);
            try std.testing.expectEqual(route, task.runtime.routeId());
            try std.testing.expectEqual(@as(u64, 0), task.durable.next_run_generation);
            var access = try task.runtime.acquireAccess();
            defer access.deinit();
            try std.testing.expectEqual(session_pointer, access.session);
            const mode: lifecycle.PermissionMode = if (target == .full_access) .full_access else .accept_edits;
            if (prior_profile != target.profile()) expected_generation += 1;
            const observed = try access.updatePermissionMode(mode, mode);
            try std.testing.expect(!observed.changed);
            try std.testing.expectEqual(expected_generation, observed.policy_generation);
            const checkpoint = task.durable.checkpoint orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(@as(u64, 0), checkpoint.session.last_run_id);
            var cancel: std.atomic.Value(bool) = .init(false);
            var verified = try checkpoint_store.openVerified(checkpoint.blob, &cancel);
            verified.deinit();
            var canonical = try product_task.history.decode(std.testing.allocator, bytes[0..history.len], .{
                .max_workspaces = 1,
                .max_tasks = 1,
                .max_runs_per_task = 8,
                .max_compacts_per_task = 8,
                .max_tools_per_run = 8,
                .max_file_changes_per_run = 8,
                .max_commentary_segments_per_run = 64,
                .max_file_refs_per_tool = 8,
                .max_ui_history_per_task = 8,
                .max_workspace_bytes = 4096,
                .max_task_title_bytes = 512,
                .max_user_message_bytes = 4096,
                .max_assistant_message_bytes = 4096,
                .max_tool_field_bytes = 4096,
                .max_file_ref_field_bytes = 4096,
                .max_execution_model_bytes = 512,
                .max_terminal_diagnostic_bytes = 512,
            });
            defer canonical.deinit();
            try std.testing.expectEqual(ack, canonical.value.tasks[0].approval_revision);
            try std.testing.expectEqualStrings(@tagName(target.profile()), canonical.value.tasks[0].permission_profile);
            try std.testing.expectEqual(target == .auto_review, canonical.value.tasks[0].permission_review_delegated);
        }
        // A permission request after two Core mutations carries generation three.
        // Its audit keeps the creating Run profile when the Task later changes.
        const manual_run = try runPreparedTask(&control, task_id, .{ .text = "ask at the current policy generation" });
        try waitControlSnapshot(&control, "\"currentRunPhase\":\"waiting_ui\"");
        const request_id = task.runtime.pending_ui_request_id;
        {
            var access = try task.runtime.acquireAccess();
            defer access.deinit();
            var pending = try access.copyPendingUiRequest(std.testing.allocator);
            defer pending.deinit();
            var parsed = try lifecycle.decodePermissionRequest(std.testing.allocator, pending.json);
            defer parsed.deinit();
            try std.testing.expectEqual(expected_generation, parsed.value().policy_generation);
        }
        if (answer_before_full) {
            try control.respondUi(task_id, manual_run, request_id, .{ .permission = .deny_once });
            try std.testing.expectEqual(.user, task.durable.ui_history[0].?.answered_by.?);
            // The summary arrives asynchronously via Core's provenance event; wait
            // for Product to consume that event before inspecting the durable audit.
            for (0..2000) |_| {
                try control.drainAgentEvents();
                if (task.durable.ui_history[0].?.permission != null) break;
                try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
            }
            try std.testing.expect(task.durable.ui_history[0].?.permission != null);
            try std.testing.expectEqual(expected_generation, task.durable.ui_history[0].?.permission.?.policy_generation);
        }
        // Crossing the Core mode boundary cancels this controlled Run and waits for
        // actual quiescence; it must not replay or create a replacement Session.
        const main_commits_before_switch = history.main_commits;
        const full_revision = try control.setApprovalMode(task_id, .full_access, epoch, task.durable.approval_revision);
        try std.testing.expectEqual(main_commits_before_switch, history.main_commits);
        for (0..2000) |_| {
            try control.drainAgentEvents();
            if (task.approval_change == null) break;
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        }
        try std.testing.expect(task.approval_change == null);
        try std.testing.expectEqual(.completed, task.approval_result.?.outcome);
        try std.testing.expectEqual(full_revision, task.durable.approval_revision);
        try std.testing.expectEqual(main_commits_before_switch, history.main_commits);
        try std.testing.expectEqual(.full_access, task.durable.permission_profile);
        try std.testing.expectEqual(.approval_required, task.durable.runs[0].?.permission_profile);
        try std.testing.expectEqual(.cancelled, task_state.runPhase(&task.durable.runs[0].?));
        try std.testing.expectEqual(route, task.runtime.routeId());
        fake_core.lock();
        const response_valid = fake_core.permission_response_valid;
        const creates = fake_core.session_created;
        fake_core.unlock();
        try std.testing.expectEqual(answer_before_full, response_valid);
        try std.testing.expectEqual(@as(usize, 1), task.durable.ui_history_count);
        if (!answer_before_full) {
            try std.testing.expectEqual(.cancelled, task.durable.ui_history[0].?.state);
            try std.testing.expect(task.durable.ui_history[0].?.answered_by == null);
        }
        try std.testing.expectEqual(@as(usize, 1), creates);
        fake_core.rearmControlled();
        for (&fake_core.sessions) |*session| {
            session.lock();
            if (session.in_use and !session.destroyed) session.plan = .immediate;
            session.unlock();
        }
        const full_run = try runPreparedTask(&control, task_id, .{ .text = "execute under the committed full access mode" });
        // currentRunPhase projects active Runs only; completion is a durable
        // terminal fact on the creating Run, not an active snapshot phase.
        for (0..2000) |_| {
            try control.drainAgentEvents();
            if (task_state.runPhase(&task.durable.runs[1].?) == .completed) break;
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        }
        try std.testing.expectEqual(.completed, task_state.runPhase(&task.durable.runs[1].?));
        try std.testing.expect(full_run != manual_run);
        try std.testing.expectEqual(.full_access, task.durable.runs[1].?.permission_profile);
        try std.testing.expectEqual(.approval_required, task.durable.runs[0].?.permission_profile);
        try std.testing.expectEqual(@as(usize, 1), task.durable.ui_history_count);
        var restart_configuration = configuration;
        restart_configuration.task_persistence = history.capabilityRestored(bytes[0..history.len]);
        var restarted = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, .{ .worker_count = 1, .queue_capacity = 2, .max_workspaces = 1, .max_tasks = 1 }, restart_configuration);
        defer restarted.deinit();
        const saved = restarted.task_runtime.find(task_id).?;
        try std.testing.expectEqual(.full_access, try restarted.taskApprovalMode(task_id));
        try std.testing.expectEqual(full_revision, saved.durable.approval_revision);
        try std.testing.expectEqual(.approval_required, saved.durable.runs[0].?.permission_profile);
        try std.testing.expectEqual(.full_access, saved.durable.runs[1].?.permission_profile);
        if (answer_before_full) {
            try std.testing.expectEqual(.user, saved.durable.ui_history[0].?.answered_by.?);
            try std.testing.expectEqual(expected_generation, saved.durable.ui_history[0].?.permission.?.policy_generation);
        } else {
            try std.testing.expectEqual(.cancelled, saved.durable.ui_history[0].?.state);
            try std.testing.expect(saved.durable.ui_history[0].?.answered_by == null);
        }
        fake_core.lock();
        const runs = fake_core.run_calls;
        const mutations = fake_core.permission_mode_updates;
        const unavailable = fake_core.ui_unavailable_callbacks;
        fake_core.unlock();
        try std.testing.expectEqual(@as(usize, 2), runs);
        try std.testing.expectEqual(@as(usize, if (answer_before_full) 0 else 1), unavailable);
        // Three real mutations plus the four no-op observations above. Neither
        // Host delegation change invokes the official Core mutation function.
        try std.testing.expectEqual(@as(usize, 7), mutations);
    }
}

test "approval Core refusal and export failure keep the old mode or restore its baseline" {
    const SyncFault = struct {
        var remaining: std.atomic.Value(u32) = .init(0);
        fn fileSync(context: ?*anyopaque, file: std.Io.File) std.Io.File.SyncError!void {
            const count = remaining.load(.acquire);
            if (count != 0 and remaining.fetchSub(1, .acq_rel) == 1) return error.InputOutput;
            return std.testing.io.vtable.fileSync(context, file);
        }
    };
    const Case = struct {
        mode_status: ?u32 = null,
        close_fails: bool = false,
        artifact_unknown: bool = false,
        restore_required: bool = true,
        reason: product_task.ApprovalFailureReason = .checkpoint_failed,
    };
    for ([_]Case{
        .{},
        .{ .close_fails = true },
        .{ .mode_status = wire.STATUS_BUSY, .restore_required = false, .reason = .busy },
        .{ .mode_status = wire.STATUS_CHECKPOINT_BUDGET_REQUIRED, .restore_required = false, .reason = .budget_required },
        .{ .mode_status = wire.STATUS_RESOURCE_LIMIT, .restore_required = false, .reason = .mode_update_failed },
        .{ .mode_status = wire.STATUS_CORE_ERROR, .reason = .mode_update_failed },
        .{ .artifact_unknown = true, .reason = .recovery_failed },
    }) |case| {
        fake_core.reset();
        // Official Core starts exported checkpoint generations at one.
        fake_core.setCheckpointGeneration(1);
        const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 2, .max_sessions = 1 });
        defer {
            shutdownTestComposition(runtime) catch unreachable;
            deinitTestComposition(runtime);
        }
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        defer std.testing.allocator.free(home);
        SyncFault.remaining.store(0, .release);
        defer SyncFault.remaining.store(0, .release);
        var store_vtable = std.testing.io.vtable.*;
        store_vtable.fileSync = SyncFault.fileSync;
        const store_io: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &store_vtable };
        var checkpoint_store = try product_task.checkpoint_store.FileStore.init(store_io, home);
        defer checkpoint_store.deinit();
        const bytes = try std.testing.allocator.alloc(u8, 1024 * 1024);
        defer std.testing.allocator.free(bytes);
        var history = TaskPersistenceProbe{ .storage = bytes };
        var configuration = productControlConfiguration();
        configuration.directories.canonical_user_home = home;
        configuration.task_persistence = history.capability();
        configuration.checkpoint_store = .{ .file_store = &checkpoint_store };
        var control = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, .{ .worker_count = 1, .queue_capacity = 2, .max_workspaces = 1, .max_tasks = 1 }, configuration);
        defer control.deinit();
        try installControlExecution(&control);
        var input = productControlTaskInput();
        input.workspace_root = home;
        input.trust = .explicitly_trusted;
        input.approval_mode = .manual;
        const task_id = try control.createTask(input, try product_control.TestSupport.fixtureModelSelection(&control));
        const task = control.task_runtime.find(task_id).?;
        const epoch = task.durable.binding_epoch;
        const route = task.runtime.routeId();
        _ = try control.setApprovalMode(task_id, .full_access, epoch, 1);
        try std.testing.expectEqual(.baseline_export, task.approval_change.?.phase);
        const baseline = pending: {
            for (control.task_runtime.approval_jobs) |entry| if (entry) |slot| {
                if (slot.task_id == task_id) break :pending slot.job;
            };
            return error.TestUnexpectedResult;
        };
        for (0..2000) |_| {
            if (baseline.completionReady()) break;
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        }
        try std.testing.expect(baseline.completionReady());
        try std.testing.expect(baseline.outcome == .checkpoint);
        // Baseline export is finished; configure only the following mutation
        // or export before its job starts. No in-flight fixture field changes.
        fake_core.lock();
        if (case.restore_required) fake_core.session_created = 0;
        fake_core.unlock();
        if (case.mode_status) |status| {
            for (&fake_core.sessions) |*session| {
                session.lock();
                if (session.in_use and !session.destroyed) {
                    session.forced_permission_mode_status = status;
                    session.permission_session_granted = true;
                }
                session.unlock();
            }
        } else if (case.artifact_unknown) {
            fake_core.lock();
            fake_core.checkpoint_payload = "unconfirmed-mode-artifact";
            fake_core.unlock();
            // Temp file sync succeeds; only the final, post-rename durability
            // sync fails. POSIX also syncs the parent in begin(). Every other
            // I/O operation keeps the actual filesystem implementation.
            SyncFault.remaining.store(if (@import("builtin").os.tag == .windows) 2 else 3, .release);
        } else fake_core.forceNextCheckpointExportStatus(wire.STATUS_RESOURCE_LIMIT);
        if (case.close_fails) fake_core.forceNextSessionDestroyStatus(wire.STATUS_CORE_ERROR);
        for (0..5000) |_| {
            control.syncLifecycle();
            if (task.approval_change == null) break;
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        }
        try std.testing.expect(task.approval_change == null);
        try std.testing.expectEqual(.failed, task.approval_result.?.outcome);
        try std.testing.expectEqual(@as(@TypeOf(task.runtime.last_restore_failure), null), task.runtime.last_restore_failure);
        if (case.close_fails) {
            try std.testing.expectEqual(.recovery_failed, task.approval_result.?.reason.?);
            try std.testing.expect(task.runtime.close_failed);
            try std.testing.expect(task.runtime.last_restore_report == null);
            for (0..10) |_| control.syncLifecycle();
            try std.testing.expectError(error.TaskClosing, control.runTask(task_id, .{ .text = "uncommitted mode cannot execute" }));
            try std.testing.expectEqual(.manual, try control.taskApprovalMode(task_id));
            try std.testing.expectEqual(@as(u64, 1), task.durable.approval_revision);
            try std.testing.expectEqual(epoch, task.durable.binding_epoch);
            try std.testing.expectEqual(@as(u64, 1), task.durable.checkpoint.?.anchor.terminal.approval);
            fake_core.lock();
            const restores = fake_core.checkpoint_restores;
            fake_core.unlock();
            try std.testing.expectEqual(@as(usize, 0), restores);
            continue;
        }
        try std.testing.expectEqual(case.reason, task.approval_result.?.reason.?);
        try std.testing.expectEqual(.manual, try control.taskApprovalMode(task_id));
        try std.testing.expectEqual(@as(u64, 1), task.durable.approval_revision);
        try std.testing.expectEqual(epoch + @as(u64, if (case.restore_required and !case.artifact_unknown) 1 else 0), task.durable.binding_epoch);
        try std.testing.expectEqual(case.restore_required, route != task.runtime.routeId());
        try std.testing.expectEqual(case.restore_required and !case.artifact_unknown, task.runtime.last_restore_report != null);
        try std.testing.expect(!task.runtime.worker_leases.hasLive());
        for (0..10) |_| control.syncLifecycle();
        fake_core.lock();
        const updates_before_observation = fake_core.permission_mode_updates;
        const runs = fake_core.run_calls;
        fake_core.unlock();
        try std.testing.expectEqual(@as(usize, 1), updates_before_observation);
        try std.testing.expectEqual(@as(usize, 0), runs);
        if (!case.restore_required) {
            for (&fake_core.sessions) |*session| {
                session.lock();
                const active = session.in_use and !session.destroyed;
                const granted = session.permission_session_granted;
                session.unlock();
                if (active) try std.testing.expect(granted);
            }
        }
        const checkpoint = task.durable.checkpoint orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(u64, 1), checkpoint.anchor.terminal.approval);
        if (case.artifact_unknown) {
            try std.testing.expectEqual(@as(u32, 0), SyncFault.remaining.load(.acquire));
            try std.testing.expectEqual(.outcome_unknown, control.checkpointStoreHealth());
            var cancelled: std.atomic.Value(bool) = .init(false);
            var old_source = try checkpoint_store.openVerified(checkpoint.blob, &cancelled);
            old_source.deinit();
            const payload = "unconfirmed-mode-artifact";
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(payload, &digest, .{});
            const uncertain: product_task.checkpoint_store.Identity = .{
                .task_id = task_id,
                .generation = 1,
                .digest = digest,
                .byte_size = payload.len,
            };
            var candidate_source = try checkpoint_store.openVerified(uncertain, &cancelled);
            candidate_source.deinit();
            try std.testing.expectError(error.ApprovalUnavailable, control.setApprovalMode(task_id, .full_access, epoch, 1));
            for (0..10) |_| control.syncLifecycle();
            try std.testing.expectEqual(.outcome_unknown, control.checkpointStoreHealth());
            // A readable file alone cannot turn an unknown durability result
            // into a committed mode, or trigger cleanup of either recovery point.
            var retained_source = try checkpoint_store.openVerified(uncertain, &cancelled);
            retained_source.deinit();
            // The existing recovery Gate requires a ready checkpoint store.
            // Unknown durability keeps that Gate closed; do not weaken it just
            // because its old recovery point is presently readable.
            try std.testing.expect(!task.runtime.hasAttachedSession());
            try std.testing.expectEqual(.none, task.runtime.active_operation);
            try std.testing.expectError(error.TaskClosing, control.runTask(task_id, .{ .text = "unknown checkpoint store cannot execute" }));
            try std.testing.expectError(error.RecoveryUnavailable, control.restoreTaskConversation(task_id, epoch));
            fake_core.lock();
            const restores = fake_core.checkpoint_restores;
            const creates = fake_core.session_created;
            const destroys = fake_core.session_destroyed;
            const runs_after = fake_core.run_calls;
            const updates_after = fake_core.permission_mode_updates;
            fake_core.unlock();
            try std.testing.expectEqual(@as(usize, 0), restores);
            try std.testing.expectEqual(@as(usize, 0), creates);
            try std.testing.expectEqual(@as(usize, 1), destroys);
            try std.testing.expectEqual(@as(usize, 0), runs_after);
            try std.testing.expectEqual(@as(usize, 1), updates_after);
            continue;
        }
        var access = try task.runtime.acquireAccess();
        defer access.deinit();
        const observed = try access.updatePermissionMode(.accept_edits, .accept_edits);
        try std.testing.expect(!observed.changed);
        try std.testing.expectEqual(@as(u64, 1), observed.policy_generation);
        fake_core.lock();
        const restores = fake_core.checkpoint_restores;
        fake_core.unlock();
        try std.testing.expectEqual(@as(usize, if (case.restore_required) 1 else 0), restores);
    }
}

test "approval fresh recovery stays queued and one failure never starts an implicit retry" {
    const Blocker = struct {
        entered: std.atomic.Value(bool) = .init(false),
        released: std.atomic.Value(bool) = .init(false),
        fn execute(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.entered.store(true, .release);
            while (!self.released.load(.acquire)) std.Thread.yield() catch {};
        }
        fn cancel(_: *anyopaque) void {}
    };
    fake_core.reset();
    fake_core.setNextPlan(.invalid_result_layout);
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 2, .max_sessions = 1 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);
    var checkpoint_store = try product_task.checkpoint_store.FileStore.init(std.testing.io, home);
    defer checkpoint_store.deinit();
    const bytes = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(bytes);
    var history = TaskPersistenceProbe{ .storage = bytes };
    var configuration = productControlConfiguration();
    configuration.directories.canonical_user_home = home;
    configuration.task_persistence = history.capability();
    configuration.checkpoint_store = .{ .file_store = &checkpoint_store };
    var control = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, .{ .worker_count = 1, .queue_capacity = 2, .max_tasks = 1, .max_runs_per_task = 2, .max_tools_per_run = 1 }, configuration);
    defer control.deinit();
    try installControlExecution(&control);
    var input = productControlTaskInput();
    input.workspace_root = home;
    input.trust = .explicitly_trusted;
    input.approval_mode = .manual;
    const task_id = try control.createTask(input, try product_control.TestSupport.fixtureModelSelection(&control));
    try waitInitialTaskCatalog(&control, task_id);
    _ = try runPreparedTask(&control, task_id, .{ .text = "fail without covering Conversation history" });
    try waitTaskSnapshot(&control, "\"id\":\"1\"", "\"continuationRecoveryAvailable\":true");
    const task = control.task_runtime.find(task_id).?;
    try std.testing.expect(task.durable.checkpoint == null);
    try std.testing.expectEqual(.excluded, task.durable.runs[0].?.coverage);
    const epoch = task.durable.binding_epoch;
    const attempts_before = control.task_runtime.next_restore_attempt_id;
    var blocker = Blocker{};
    defer blocker.released.store(true, .release);
    try control.executor.enqueue(.{ .identity = &blocker, .context = &blocker, .execute_fn = Blocker.execute, .cancel_fn = Blocker.cancel });
    for (0..2000) |_| {
        if (blocker.entered.load(.acquire)) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expect(blocker.entered.load(.acquire));
    _ = try control.setApprovalMode(task_id, .auto_review, epoch, 1);
    try std.testing.expectEqual(.restore, std.meta.activeTag(task.runtime.active_operation));
    const queued = task.runtime.restore_job orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(.queued, queued.state.load(.acquire));
    fake_core.lock();
    const created_while_queued = fake_core.session_created;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), created_while_queued);
    try std.testing.expect(control.executor.cancel(queued));
    control.syncLifecycle();
    try std.testing.expect(task.approval_change == null);
    try std.testing.expectEqual(.failed, task.approval_result.?.outcome);
    try std.testing.expectEqual(.recovery_failed, task.approval_result.?.reason.?);
    try std.testing.expectEqual(attempts_before + 1, control.task_runtime.next_restore_attempt_id);
    for (0..10) |_| control.syncLifecycle();
    try std.testing.expectEqual(attempts_before + 1, control.task_runtime.next_restore_attempt_id);
    try std.testing.expect(!task.runtime.worker_leases.hasLive());
    try std.testing.expectEqual(.manual, try control.taskApprovalMode(task_id));
    blocker.released.store(true, .release);

    // A distinct explicit request may try again. A real create failure is
    // terminal for this request, even though the next create would succeed.
    fake_core.failNextSessionCreate();
    _ = try control.setApprovalMode(task_id, .auto_review, epoch, 1);
    for (0..2000) |_| {
        control.syncLifecycle();
        if (task.approval_change == null) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expect(task.approval_change == null);
    try std.testing.expectEqual(.failed, task.approval_result.?.outcome);
    try std.testing.expectEqual(.restore_rejected, task.runtime.last_restore_failure.?);
    for (0..10) |_| control.syncLifecycle();
    try std.testing.expectEqual(attempts_before + 2, control.task_runtime.next_restore_attempt_id);
    try std.testing.expect(!task.runtime.hasAttachedSession());
    try std.testing.expectEqual(@as(u64, 1), task.durable.approval_revision);

    fake_core.setNextPlan(.immediate);
    _ = try control.setApprovalMode(task_id, .auto_review, epoch, 1);
    for (0..2000) |_| {
        control.syncLifecycle();
        if (task.approval_change == null) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expect(task.approval_change == null);
    try std.testing.expectEqual(.completed, task.approval_result.?.outcome);
    try std.testing.expectEqual(.auto_review, try control.taskApprovalMode(task_id));
    try std.testing.expectEqual(@as(u64, 2), task.durable.approval_revision);
    try std.testing.expectEqual(epoch + 1, task.durable.binding_epoch);
    try std.testing.expectEqual(@as(u64, 1), task.durable.next_run_generation);
    try std.testing.expectEqual(.excluded, task.durable.runs[0].?.coverage);
    try std.testing.expect(task.runtime.last_restore_report == null);
    try std.testing.expect(task.runtime.last_restore_permission == null);
    try std.testing.expect(!task.runtime.worker_leases.hasLive());
    fake_core.lock();
    const created = fake_core.session_created;
    const restored = fake_core.checkpoint_restores;
    const runs = fake_core.run_calls;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 2), created);
    try std.testing.expectEqual(@as(usize, 0), restored);
    try std.testing.expectEqual(@as(usize, 1), runs);
}

test "recovery binding confirmation retains candidates and never writes on the main thread" {
    const Commit = product_task.DurableCommit;
    const Blocker = struct {
        entered: std.atomic.Value(bool) = .init(false),
        released: std.atomic.Value(bool) = .init(false),
        fn execute(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.entered.store(true, .release);
            while (!self.released.load(.acquire)) std.Thread.yield() catch {};
        }
        fn cancel(_: *anyopaque) void {}
    };
    const Harness = struct {
        fixture_restore: ?[]const u8 = null,
        storage: []u8,
        candidate: []u8,
        main_thread: std.Thread.Id,
        len: usize = 0,
        candidate_len: usize = 0,
        main_commits: usize = 0,
        worker_commits: usize = 0,
        resolutions: usize = 0,
        recoveries: usize = 0,
        result: Commit,
        resolved: Commit,
        entered: std.atomic.Value(bool) = .init(false),
        released: std.atomic.Value(bool) = .init(false),
        close_entered: std.atomic.Value(bool) = .init(false),
        close_released: std.atomic.Value(bool) = .init(false),
        main_closes: std.atomic.Value(usize) = .init(0),
        close_calls: std.atomic.Value(usize) = .init(0),
        hold_close: bool = false,
        fn observeClose(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            _ = self.close_calls.fetchAdd(1, .acq_rel);
            if (std.Thread.getCurrentId() == self.main_thread) {
                _ = self.main_closes.fetchAdd(1, .acq_rel);
                return;
            }
            self.close_entered.store(true, .release);
            while (self.hold_close and !self.close_released.load(.acquire)) std.Thread.yield() catch {};
        }
        fn save(context: ?*anyopaque, input: *product_task.history.Candidate) Commit {
            input.token = @splat(23);
            const bytes = product_task.history.encodeAlloc(std.testing.allocator, input.value, input.preserved, product_control.persistenceLimits(.{}, 16)) catch return .failed;
            defer std.testing.allocator.free(bytes);
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (std.Thread.getCurrentId() == self.main_thread) {
                self.main_commits += 1;
            } else {
                self.worker_commits += 1;
                if (self.worker_commits == 1) {
                    @memcpy(self.candidate[0..bytes.len], bytes);
                    self.candidate_len = bytes.len;
                    self.entered.store(true, .release);
                    while (!self.released.load(.acquire)) std.Thread.yield() catch {};
                    if (self.result == .failed or (self.result == .outcome_unknown and self.resolved == .failed)) return self.result;
                    @memcpy(self.storage[0..bytes.len], bytes);
                    self.len = bytes.len;
                    return self.result;
                }
            }
            @memcpy(self.storage[0..bytes.len], bytes);
            self.len = bytes.len;
            return .committed;
        }
        fn resolve(context: ?*anyopaque, token: product_task.history.CommitToken) Commit {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            std.debug.assert(std.mem.eql(u8, &token, &(@as(product_task.history.CommitToken, @splat(23)))));
            const bytes = self.candidate[0..self.candidate_len];
            std.debug.assert(std.Thread.getCurrentId() != self.main_thread);
            std.debug.assert(std.mem.eql(u8, bytes, self.candidate[0..self.candidate_len]));
            self.resolutions += 1;
            if (self.resolutions == 1) return .outcome_unknown;
            std.debug.assert((self.resolved == .committed) == std.mem.eql(u8, bytes, self.storage[0..self.len]));
            return self.resolved;
        }
        fn recover(context: ?*anyopaque, _: *product_task.history.Candidate) Commit {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.recoveries += 1;
            return .failed;
        }
        fn restoreFixture(context: ?*anyopaque) anyerror!?product_task.history.RecoveredState {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            const bytes = self.fixture_restore orelse return null;
            return try product_task.history.decodeRecovering(std.testing.allocator, bytes, product_control.persistenceLimits(.{}, 16));
        }
        fn capability(self: *@This(), restored: ?[]const u8) product_task.history.Capability {
            self.fixture_restore = restored;
            return .{ .context = self, .enabled = true, .restore_fn = restoreFixture, .commit_fn = save, .confirmed_commit_fn = save, .resolve_commit_fn = resolve, .recover_fn = recover };
        }
        fn wake(_: ?*anyopaque) bool {
            return true;
        }
    };
    const HeldExecutor = struct {
        context: ?*anyopaque = null,
        cancel_fn: ?*const fn (*anyopaque) void = null,
        fn enqueue(context: *anyopaque, _: *anyopaque, job: *anyopaque, _: *const fn (*anyopaque) void, cancellation: *const fn (*anyopaque) void) error{ ExecutorShuttingDown, QueueFull }!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.context = job;
            self.cancel_fn = cancellation;
        }
        fn cancel(context: *anyopaque, _: *anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.cancel_fn.?(self.context.?);
            self.context = null;
            return true;
        }
    };
    const cases = [_]struct { result: Commit, resolved: Commit = .committed, stale: bool = false, shutdown: bool = false, hold_close: bool = false, close_failure: bool = false, cancel_binding: bool = false, reject_model: bool = false, cancel_candidate: bool = false, single_wake: bool = false, writer_waiter: bool = false }{
        .{ .result = .committed, .single_wake = true },
        .{ .result = .committed, .writer_waiter = true },
        .{ .result = .failed, .writer_waiter = true },
        .{ .result = .committed, .reject_model = true },
        .{ .result = .committed, .cancel_candidate = true },
        .{ .result = .committed, .cancel_binding = true },
        .{ .result = .committed, .stale = true, .hold_close = true },
        .{ .result = .committed, .stale = true, .hold_close = true, .close_failure = true },
        .{ .result = .failed },
        .{ .result = .outcome_unknown },
        .{ .result = .outcome_unknown, .resolved = .failed },
        .{ .result = .committed, .shutdown = true },
        .{ .result = .outcome_unknown, .shutdown = true },
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);
    const storage = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(storage);
    const candidate_bytes = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(candidate_bytes);
    for (cases) |case| {
        fake_core.reset();
        var wake_loop: fixture.LifecycleWakeLoop = .{};
        const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 2, .max_sessions = if (case.writer_waiter) 2 else 1, .event_ready_notifier = .{ .context = &wake_loop, .notify_fn = fixture.LifecycleWakeLoop.agentWake } });
        defer {
            shutdownTestComposition(runtime) catch unreachable;
            deinitTestComposition(runtime);
        }
        var history = Harness{ .storage = storage, .candidate = candidate_bytes, .main_thread = std.Thread.getCurrentId(), .result = case.result, .resolved = case.resolved, .hold_close = case.hold_close };
        var checkpoint_store = try product_task.checkpoint_store.FileStore.init(std.testing.io, home);
        defer checkpoint_store.deinit();
        var configuration = productControlConfiguration();
        configuration.change_notifier = .{ .context = &wake_loop, .wake = fixture.LifecycleWakeLoop.wake };
        configuration.directories.canonical_user_home = home;
        configuration.task_persistence = history.capability(null);
        configuration.checkpoint_store = .{ .file_store = &checkpoint_store };
        const limits: product_control.Limits = .{ .worker_count = 1, .queue_capacity = 2, .max_tasks = if (case.writer_waiter) 2 else 1, .max_workspaces = 1 };
        var input = productControlTaskInput();
        input.workspace_root = home;
        input.trust = .explicitly_trusted;
        input.approval_mode = .manual;
        var task_id: u64 = undefined;
        var waiter_id: ?u64 = null;
        {
            var seed = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, limits, configuration);
            defer seed.deinit();
            try installControlExecution(&seed);
            if (case.writer_waiter) waiter_id = try seed.createTask(input, try product_control.TestSupport.fixtureModelSelection(&seed));
            task_id = try seed.createTask(input, try product_control.TestSupport.fixtureModelSelection(&seed));
        }
        const old_frame = try std.testing.allocator.dupe(u8, storage[0..history.len]);
        defer std.testing.allocator.free(old_frame);
        configuration.task_persistence = history.capability(old_frame);
        var control = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, limits, configuration);
        defer control.deinit();
        defer history.released.store(true, .release);
        defer {
            fake_core.lock();
            fake_core.session_destroy_probe = null;
            fake_core.unlock();
        }
        defer history.close_released.store(true, .release);
        try installControlExecutionGeneration(&control, 2);
        const restored_workspace = try control.openWorkspace(input);
        // This scenario owns a one-slot executor. Finish unrelated catalog
        // preparation before testing recovery's controlled history writer.
        try settleWorkspaceSkillQueries(&control, restored_workspace);
        const task = control.task_runtime.find(task_id).?;
        const original_execution_generation = task.durable.execution_generation;
        const main_commits = history.main_commits;
        fake_core.lock();
        fake_core.session_destroy_probe = .{ .context = &history, .observe_fn = Harness.observeClose };
        if (case.reject_model) fake_core.forced_set_model_status = wire.STATUS_CORE_ERROR;
        fake_core.unlock();
        if (case.reject_model or case.cancel_candidate) fake_core.failNextSessionDestroy();
        const attempt_id = if (case.close_failure) approval: {
            _ = try control.setApprovalMode(task_id, .auto_review, 1, 1);
            break :approval task.runtime.restore_job.?.attempt.attempt_id;
        } else try control.restoreTaskConversation(task_id, 1);
        const target_execution_generation = task.runtime.restore_job.?.attempt.target_execution_generation;
        try std.testing.expect(target_execution_generation > original_execution_generation);
        if (case.reject_model or case.cancel_candidate) {
            const restore = task.runtime.restore_job.?;
            for (0..2000) |_| {
                if (restore.completionReady()) break;
                try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
            }
            try std.testing.expect(restore.completionReady());
            if (case.reject_model) {
                try std.testing.expectEqual(.restore_rejected, restore.outcome.candidate.rejection.?);
            } else {
                try std.testing.expect(restore.outcome.candidate.rejection == null);
                // Cancellation after worker completion still forbids publication.
                restore.requestCancellation();
            }
            try std.testing.expectEqual(.owned, restore.outcome.candidate.binding.state());
            // The restore worker returns its owner without attempting destroy.
            try std.testing.expectEqual(@as(usize, 0), history.close_calls.load(.acquire));
            for (0..2000) |_| {
                control.syncLifecycle();
                if (task.runtime.close_failed) break;
                try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
            }
            try std.testing.expect(task.runtime.restore_job == null);
            try std.testing.expect(task.runtime.close_failed);
            try std.testing.expect(task.runtime.discarding_restore);
            try std.testing.expectEqual(.session_poisoned, task.runtime.liveConst().?.health);
            try std.testing.expectEqual(@as(usize, 0), task.runtime.executionConst().?.secret.len);
            try std.testing.expectEqual(.candidate_cleanup_failed, task.runtime.last_restore_failure.?);
            try std.testing.expectEqual(@as(u64, 1), task.durable.binding_epoch);
            try std.testing.expectEqual(original_execution_generation, task.durable.execution_generation);
            try std.testing.expect(!task.runtime.worker_leases.hasLive());
            try std.testing.expectError(error.TaskClosing, control.runTask(task_id, .{ .text = "rejected model cannot run" }));
            for (0..10) |_| control.syncLifecycle();
            try std.testing.expectEqual(@as(usize, 1), history.close_calls.load(.acquire));
            try std.testing.expectEqual(@as(usize, 0), history.main_closes.load(.acquire));
            try std.testing.expectEqual(@as(usize, 0), history.worker_commits);
            try std.testing.expectEqual(main_commits, history.main_commits);
            try std.testing.expect(try product_control.TestSupport.retryTaskSessionClose(&control, task_id));
            for (0..2000) |_| {
                control.syncLifecycle();
                if (task.runtime.attachment == .detached and task.runtime.close_thread == null) break;
                try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
            }
            try std.testing.expectEqual(.detached, std.meta.activeTag(task.runtime.attachment));
            try std.testing.expectEqual(@as(usize, 2), history.close_calls.load(.acquire));
            fake_core.lock();
            const runs = fake_core.run_calls;
            const destroyed = fake_core.session_destroyed;
            fake_core.unlock();
            try std.testing.expectEqual(@as(usize, 0), runs);
            try std.testing.expectEqual(@as(usize, 2), destroyed); // seed plus rejected candidate
            continue;
        }
        if (case.cancel_binding) {
            const restore = task.runtime.restore_job.?;
            for (0..2000) |_| {
                if (restore.completionReady()) break;
                try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
            }
            try std.testing.expect(restore.completionReady());
            try std.testing.expectEqual(.candidate, std.meta.activeTag(restore.outcome));
            var blocker = Blocker{};
            defer blocker.released.store(true, .release);
            try control.approval_executor.enqueue(.{ .identity = &blocker, .context = &blocker, .execute_fn = Blocker.execute, .cancel_fn = Blocker.cancel });
            for (0..2000) |_| {
                if (blocker.entered.load(.acquire)) break;
                try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
            }
            try std.testing.expect(blocker.entered.load(.acquire));
            control.syncLifecycle();
            const writer = queued: {
                for (control.task_runtime.approval_jobs) |entry| if (entry) |slot| if (slot.restore_attempt_id == attempt_id) break :queued slot.job;
                return error.TestUnexpectedResult;
            };
            try std.testing.expectEqual(.queued, writer.state.load(.acquire));
            try std.testing.expect(control.approval_executor.cancel(writer));
            try std.testing.expectEqual(.cancelled, writer.outcome.failure.reason);
            for (0..2000) |_| {
                control.syncLifecycle();
                if (task.runtime.restore_job == null and task.runtime.close_thread == null and !task.runtime.hasClosingSession()) break;
                try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
            }
            try std.testing.expect(task.runtime.restore_job == null);
            try std.testing.expect(task.runtime.attachment == .detached);
            try std.testing.expect(!task.runtime.worker_leases.hasLive());
            try std.testing.expectEqual(.cancelled, task.runtime.last_restore_failure.?);
            try std.testing.expectEqual(.ready, control.task_persistence_health);
            try std.testing.expectEqual(@as(u64, 1), task.durable.binding_epoch);
            try std.testing.expectEqual(original_execution_generation, task.durable.execution_generation);
            for (0..10) |_| control.syncLifecycle();
            try std.testing.expectEqual(@as(usize, 0), history.worker_commits);
            try std.testing.expectEqual(main_commits, history.main_commits);
            try std.testing.expectEqual(@as(usize, 0), history.main_closes.load(.acquire));
            try std.testing.expectEqual(@as(usize, 1), history.close_calls.load(.acquire));
            continue;
        }
        for (0..2000) |_| {
            control.syncLifecycle();
            if (history.entered.load(.acquire)) break;
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        }
        try std.testing.expect(history.entered.load(.acquire));
        const restore = task.runtime.restore_job orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(attempt_id, restore.attempt.attempt_id);
        try std.testing.expectEqual(.pending, restore.binding_commit);
        try std.testing.expectEqual(.candidate, std.meta.activeTag(restore.outcome));
        try std.testing.expect(task.runtime.attachment == .detached);
        try std.testing.expectEqual(@as(u64, 1), task.durable.binding_epoch);
        try std.testing.expectEqual(original_execution_generation, task.durable.execution_generation);
        try std.testing.expect(task.runtime.worker_leases.hasLive());
        try std.testing.expect(control.task_runtime.approvalHistoryBlocked());
        if (waiter_id) |id| {
            // The earlier Task waits on the later Task's shared writer. When
            // that writer finishes, its one wake must also release the waiter.
            _ = try control.restoreTaskConversation(id, 1);
            const waiter = control.task_runtime.find(id).?;
            for (0..2000) |_| {
                if (waiter.runtime.restore_job.?.completionReady()) break;
                try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
            } else return error.WaiterDidNotComplete;
            for (0..2000) |_| {
                if (wake_loop.pending.load(.acquire) == 0) break;
                try wake_loop.drain(&control);
            } else return error.WakesDidNotSettle;
            try std.testing.expectEqual(.not_started, waiter.runtime.restore_job.?.binding_commit);
            history.released.store(true, .release);
            for (0..2000) |_| {
                if (wake_loop.pending.load(.acquire) != 0) break;
                try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
            } else return error.WriterDidNotNotify;
            try wake_loop.drain(&control);
            try std.testing.expect(task.runtime.restore_job == null);
            try std.testing.expect(!task.runtime.worker_leases.hasLive());
            if (waiter.runtime.restore_job) |waiting|
                try std.testing.expect(waiting.binding_commit != .not_started);
            for (0..2000) |_| {
                try wake_loop.drain(&control);
                if (waiter.runtime.restore_job == null and waiter.runtime.close_thread == null) break;
                try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
            } else return error.WaiterDidNotSettle;
            try std.testing.expect(!waiter.runtime.worker_leases.hasLive());
            try std.testing.expectEqual(.none, waiter.runtime.active_operation);
            try std.testing.expectEqual(@as(u64, if (case.result == .committed) 2 else 1), waiter.durable.binding_epoch);
            continue;
        }
        if (!case.shutdown) try control.renameTask(task_id, "changed during binding confirmation");
        if (case.stale) try installControlExecutionGeneration(&control, 3);
        try std.testing.expectEqual(main_commits, history.main_commits);
        if (case.close_failure) fake_core.failNextSessionDestroy();
        history.released.store(true, .release);
        if (case.single_wake) {
            const writer = pending: {
                for (control.task_runtime.approval_jobs) |entry| if (entry) |slot|
                    if (slot.restore_attempt_id == attempt_id) break :pending slot.job;
                return error.TestUnexpectedResult;
            };
            for (0..2000) |_| {
                if (writer.completionReady()) break;
                try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
            }
            try std.testing.expect(writer.completionReady());
            // Application consumes the writer's one completion wake. No
            // Renderer read or extra lifecycle poll may be needed to install.
            try control.drainAgentEvents();
            try std.testing.expect(task.runtime.restore_job == null);
            try std.testing.expect(task.runtime.hasAttachedSession());
            try std.testing.expectEqual(@as(u64, 2), task.durable.binding_epoch);
            try std.testing.expectEqual(.none, task.runtime.active_operation);
        }
        if (case.hold_close) {
            for (0..2000) |_| {
                control.syncLifecycle();
                if (history.close_entered.load(.acquire)) break;
                try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
            }
            try std.testing.expect(history.close_entered.load(.acquire));
            try std.testing.expectEqual(@as(usize, 0), history.main_closes.load(.acquire));
            try std.testing.expect(task.runtime.close_thread != null);
            try std.testing.expect(task.runtime.hasClosingSession());
            try std.testing.expect(task.runtime.discarding_restore);
            try std.testing.expectEqual(@as(usize, 0), task.runtime.live().?.execution.secret.len);
            try std.testing.expect(task.runtime.restore_job == null);
            try std.testing.expect(!task.runtime.worker_leases.hasLive());
            try std.testing.expectEqual(@as(u64, 2), task.durable.binding_epoch);
            try std.testing.expectError(error.TaskClosing, control.runTask(task_id, .{ .text = "a rejected candidate cannot run" }));
            history.close_released.store(true, .release);
        }
        if (case.shutdown) {
            const history_job = pending: {
                for (control.task_runtime.approval_jobs) |entry| if (entry) |slot|
                    if (slot.restore_attempt_id == attempt_id) break :pending slot.job;
                return error.TestUnexpectedResult;
            };
            for (0..2000) |_| {
                if (history_job.completionReady()) break;
                try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
            }
            try std.testing.expect(history_job.completionReady());
            // Skip normal publication; shutdown must consume a completed writer.
            control.shutdownExecutor();
            for (0..2000) |_| {
                control.syncLifecycle();
                if (task.runtime.close_thread == null) break;
                try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
            }
            try std.testing.expect(task.runtime.restore_job == null);
            try std.testing.expect(!task.runtime.worker_leases.hasLive());
            try std.testing.expect(task.runtime.attachment == .detached);
            try std.testing.expectEqual(@as(u64, if (case.result == .committed) 2 else 1), task.durable.binding_epoch);
            if (case.result == .outcome_unknown) {
                try std.testing.expectEqual(.outcome_unknown, control.task_persistence_health);
                try std.testing.expectEqual(main_commits, history.main_commits);
                try std.testing.expectEqual(@as(usize, 1), history.worker_commits);
                try std.testing.expectEqual(@as(usize, 0), history.resolutions);
            }
            continue;
        }
        if (case.result == .outcome_unknown) {
            for (0..2000) |_| {
                control.syncLifecycle();
                if (restore.binding_commit == .outcome_unknown) break;
                try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
            }
            try std.testing.expectEqual(.outcome_unknown, restore.binding_commit);
            const retained = restore.unknown_history orelse return error.TestUnexpectedResult;
            for (0..10) |_| control.syncLifecycle();
            try std.testing.expectEqual(@as(usize, 1), history.worker_commits);
            try std.testing.expectEqual(@as(usize, 0), history.resolutions);
            var held = HeldExecutor{};
            const copy = retained;
            try control.task_runtime.queueRecoveryHistory(task_id, .{ .resolution = copy }, history.capability(null), .{ .context = &held, .enqueue_fn = HeldExecutor.enqueue, .cancel_fn = HeldExecutor.cancel }, .{ .notify_fn = Harness.wake });
            try std.testing.expect(HeldExecutor.cancel(&held, held.context.?));
            control.syncLifecycle();
            try std.testing.expectEqualSlices(u8, &retained, &restore.unknown_history.?);
            try std.testing.expectEqual(.outcome_unknown, restore.binding_commit);
            for (0..2) |resolution| {
                try std.testing.expectEqual(.outcome_unknown, control.recoverTaskHistory(control.currentRevision()));
                for (0..2000) |_| {
                    control.syncLifecycle();
                    if (history.resolutions == resolution + 1 and !control.task_runtime.approvalHistoryWorkerActive()) break;
                    try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
                }
                try std.testing.expectEqual(resolution + 1, history.resolutions);
                if (resolution == 0) try std.testing.expectEqualSlices(u8, &retained, &restore.unknown_history.?);
            }
        }
        for (0..2000) |_| {
            control.syncLifecycle();
            if (task.runtime.restore_job == null and task.runtime.close_thread == null and (!task.runtime.hasClosingSession() or task.runtime.close_failed) and !control.task_runtime.approvalHistoryBlocked()) break;
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        }
        try std.testing.expect(task.runtime.restore_job == null);
        try std.testing.expect(!task.runtime.worker_leases.hasLive());
        const committed = case.result == .committed or (case.result == .outcome_unknown and case.resolved == .committed);
        try std.testing.expectEqual(@as(u64, if (committed) 2 else 1), task.durable.binding_epoch);
        try std.testing.expectEqual(if (committed) target_execution_generation else original_execution_generation, task.durable.execution_generation);
        if (case.close_failure) {
            try std.testing.expect(task.runtime.close_failed);
            try std.testing.expect(task.runtime.discarding_restore);
            try std.testing.expectEqual(.session_poisoned, task.runtime.liveConst().?.health);
            try std.testing.expectEqual(@as(usize, 0), task.runtime.executionConst().?.secret.len);
            try std.testing.expectEqual(.candidate_cleanup_failed, task.runtime.last_restore_failure.?);
            try std.testing.expect(task.approval_change == null);
            try std.testing.expectEqual(.failed, task.approval_result.?.outcome);
            try std.testing.expectEqual(.recovery_failed, task.approval_result.?.reason.?);
            try std.testing.expectEqual(.manual, try control.taskApprovalMode(task_id));
            try std.testing.expectEqual(@as(u64, 1), task.durable.approval_revision);
            try std.testing.expectError(error.TaskClosing, control.runTask(task_id, .{ .text = "a close failure cannot install a rejected candidate" }));
        } else try std.testing.expectEqual(committed and !case.stale, task.runtime.hasAttachedSession());
        try std.testing.expectEqual(@as(usize, 0), history.main_closes.load(.acquire));
        if (!committed) try std.testing.expectEqual(.binding_persistence_failed, task.runtime.last_restore_failure.?);
        try std.testing.expectEqual(main_commits, history.main_commits);
        try std.testing.expectEqual(@as(usize, 0), history.recoveries);
        for (0..10) |_| control.syncLifecycle();
        if (case.close_failure) try std.testing.expectEqual(@as(usize, 1), history.close_calls.load(.acquire));
        const commits_after = history.worker_commits;
        try std.testing.expectEqual(@as(usize, if (case.result == .failed) 1 else 2), commits_after);
        fake_core.lock();
        const created = fake_core.session_created;
        const runs = fake_core.run_calls;
        fake_core.unlock();
        try std.testing.expectEqual(@as(usize, 2), created);
        try std.testing.expectEqual(@as(usize, 0), runs);
        // Read canonical facts through the normal startup codec, not string
        // matching. A stale Session must not roll back its confirmed binding.
        configuration.task_persistence = history.capability(storage[0..history.len]);
        var restarted = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, limits, configuration);
        defer restarted.deinit();
        const durable = restarted.task_runtime.find(task_id).?;
        try std.testing.expectEqual(task.durable.binding_epoch, durable.durable.binding_epoch);
        try std.testing.expectEqual(task.durable.execution_generation, durable.durable.execution_generation);
        if (case.result != .failed) try std.testing.expectEqualStrings("changed during binding confirmation", durable.durable.title);
        if (case.close_failure) {
            // The ordinary Host close action can retry; polling cannot.
            try std.testing.expect(try product_control.TestSupport.retryTaskSessionClose(&control, task_id));
            for (0..2000) |_| {
                control.syncLifecycle();
                if (!task.runtime.hasClosingSession() and task.runtime.close_thread == null) break;
                try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
            }
            try std.testing.expect(task.runtime.attachment == .detached);
            try std.testing.expect(!task.runtime.discarding_restore);
            try std.testing.expectEqual(@as(usize, 2), history.close_calls.load(.acquire));
            try std.testing.expectEqual(@as(usize, 0), history.main_closes.load(.acquire));
        }
    }
}

test "approval delegation can change while the only Run worker waits for permission" {
    for ([_]bool{ false, true }) |completed_before_manual| {
        fake_core.reset();
        fake_core.setNextPlan(.ui_wait);
        const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 2, .max_sessions = 1 });
        defer {
            shutdownTestComposition(runtime) catch unreachable;
            deinitTestComposition(runtime);
        }
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        defer std.testing.allocator.free(home);
        const bytes = try std.testing.allocator.alloc(u8, 1024 * 1024);
        defer std.testing.allocator.free(bytes);
        var history = TaskPersistenceProbe{ .storage = bytes };
        var transport = ReviewerTransport{ .hold_cancel_cleanup = true };
        var configuration = productControlConfiguration();
        configuration.directories.canonical_user_home = home;
        configuration.task_persistence = history.capability();
        configuration.completion_factory = .{ .context = &transport, .create_fn = ReviewerTransport.create };
        var control = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, .{ .worker_count = 1, .queue_capacity = 2, .max_tasks = 1, .max_workspaces = 1 }, configuration);
        defer control.deinit();
        defer transport.released.store(true, .release);
        try installControlExecution(&control);
        var input = productControlTaskInput();
        input.workspace_root = home;
        input.trust = .explicitly_trusted;
        input.approval_mode = .manual;
        const task_id = try control.createTask(input, try product_control.TestSupport.fixtureModelSelection(&control));
        const task = control.task_runtime.find(task_id).?;
        const route = task.runtime.routeId();
        const run_id = try runPreparedTask(&control, task_id, .{ .text = "review this pending operation explicitly" });
        try waitControlSnapshot(&control, "\"currentRunPhase\":\"waiting_ui\"");
        const request_id = task.runtime.pending_ui_request_id;
        try std.testing.expect(request_id != 0);
        try std.testing.expectEqual(@as(u64, 2), try control.setApprovalMode(task_id, .auto_review, 1, 1));
        for (0..2000) |_| {
            control.syncLifecycle();
            if (task.approval_change == null) break;
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        }
        try std.testing.expect(task.approval_change == null);
        try std.testing.expectEqual(.auto_review, try control.taskApprovalMode(task_id));
        try transport.awaitEntered(&control);
        const old_review = task.runtime.permission_review.identity.?;
        if (completed_before_manual) {
            transport.released.store(true, .release);
            try waitReviewerJobDone(&control);
            try std.testing.expect(transport.exited.load(.acquire));
        }
        // Switching back must invalidate the result immediately. A transport
        // deliberately holding cancellation cleanup cannot make this call join.
        try std.testing.expectEqual(@as(u64, 3), try control.setApprovalMode(task_id, .manual, 1, 2));
        try std.testing.expect(!task.runtime.permission_review.matches(old_review));
        try std.testing.expectEqual(.needs_user, task.permissionReviewPhase());
        try std.testing.expectEqual(completed_before_manual, transport.exited.load(.acquire));
        for (0..2000) |_| {
            control.syncLifecycle();
            if (task.approval_change == null) break;
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        }
        try std.testing.expect(task.approval_change == null);
        try std.testing.expectEqual(.manual, try control.taskApprovalMode(task_id));
        try std.testing.expectEqual(route, task.runtime.routeId());
        try std.testing.expectEqual(run_id, task.runtime.active_operation.run);
        try std.testing.expectEqual(request_id, task.runtime.pending_ui_request_id);
        try std.testing.expectEqual(@as(usize, 0), task.durable.ui_history_count);
        transport.released.store(true, .release);
        if (!completed_before_manual) try waitReviewerJobDone(&control);
        control.syncLifecycle();
        try std.testing.expectEqual(@as(usize, 0), task.durable.ui_history_count);
        try std.testing.expectEqual(request_id, task.runtime.pending_ui_request_id);
        try std.testing.expectEqual(@as(usize, 1), transport.calls.load(.acquire));
        try control.respondUi(task_id, run_id, request_id, .{ .permission = .deny_once });
        try std.testing.expectEqual(.user, task.durable.ui_history[0].?.answered_by.?);
        fake_core.lock();
        const creates = fake_core.session_created;
        const mutations = fake_core.permission_mode_updates;
        fake_core.unlock();
        try std.testing.expectEqual(@as(usize, 1), creates);
        try std.testing.expectEqual(@as(usize, 0), mutations);
    }
}
test "approval metadata outcomes retain both checkpoints until canonical readback decides" {
    const Commit = product_task.history.Commit;
    const Harness = struct {
        fixture_restore: ?[]const u8 = null,
        storage: []u8,
        candidate: []u8,
        main_thread: std.Thread.Id,
        result: Commit,
        candidate_is_canonical: bool,
        fault_baseline: bool,
        injected: bool = false,
        len: usize = 0,
        candidate_len: usize = 0,
        main_writes: usize = 0,
        mode_writes: usize = 0,
        resolutions: usize = 0,
        recoveries: usize = 0,

        fn commit(context: ?*anyopaque, input: *product_task.history.Candidate) Commit {
            input.token = @splat(23);
            const bytes = product_task.history.encodeAlloc(std.testing.allocator, input.value, input.preserved, product_control.persistenceLimits(.{}, 16)) catch return .failed;
            defer std.testing.allocator.free(bytes);
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (std.Thread.getCurrentId() == self.main_thread) self.main_writes += 1;
            var parsed = product_task.history.decode(std.testing.allocator, bytes, .{
                .max_workspaces = 1,
                .max_tasks = 1,
                .max_runs_per_task = 8,
                .max_compacts_per_task = 8,
                .max_tools_per_run = 8,
                .max_commentary_segments_per_run = 64,
                .max_file_refs_per_tool = 8,
                .max_ui_history_per_task = 8,
                .max_workspace_bytes = 4096,
                .max_task_title_bytes = 512,
                .max_user_message_bytes = 4096,
                .max_assistant_message_bytes = 4096,
                .max_tool_field_bytes = 4096,
                .max_file_ref_field_bytes = 4096,
                .max_execution_model_bytes = 512,
                .max_terminal_diagnostic_bytes = 512,
            }) catch return .failed;
            defer parsed.deinit();
            const tasks = parsed.value.tasks;
            const full = tasks.len != 0 and std.mem.eql(u8, tasks[0].permission_profile, "full_access");
            const baseline = self.fault_baseline and tasks.len != 0 and tasks[0].checkpoint != null;
            if (full or baseline) {
                self.mode_writes += 1;
                if (bytes.len > self.candidate.len) return .failed;
                @memcpy(self.candidate[0..bytes.len], bytes);
                self.candidate_len = bytes.len;
                if (self.result != .committed and !self.injected) {
                    self.injected = true;
                    if (self.candidate_is_canonical) {
                        if (bytes.len > self.storage.len) return .failed;
                        @memcpy(self.storage[0..bytes.len], bytes);
                        self.len = bytes.len;
                    }
                    return self.result;
                }
            }
            if (bytes.len > self.storage.len) return .failed;
            @memcpy(self.storage[0..bytes.len], bytes);
            self.len = bytes.len;
            return .committed;
        }

        fn resolve(context: ?*anyopaque, token: product_task.history.CommitToken) Commit {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            std.debug.assert(std.Thread.getCurrentId() != self.main_thread);
            std.debug.assert(std.mem.eql(u8, &token, &(@as(product_task.history.CommitToken, @splat(23)))));
            const expected = self.candidate[0..self.candidate_len];
            self.resolutions += 1;
            if (self.resolutions == 1) return .outcome_unknown;
            return if (std.mem.eql(u8, self.storage[0..self.len], expected)) .committed else .failed;
        }

        fn recover(context: ?*anyopaque, _: *product_task.history.Candidate) Commit {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.recoveries += 1;
            return .failed;
        }

        fn restoreFixture(context: ?*anyopaque) anyerror!?product_task.history.RecoveredState {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            const bytes = self.fixture_restore orelse return null;
            return try product_task.history.decodeRecovering(std.testing.allocator, bytes, product_control.persistenceLimits(.{}, 16));
        }
        fn capability(self: *@This(), restored: ?[]const u8) product_task.history.Capability {
            self.fixture_restore = restored;
            return .{ .context = self, .enabled = true, .restore_fn = restoreFixture, .commit_fn = commit, .confirmed_commit_fn = commit, .resolve_commit_fn = resolve, .recover_fn = recover };
        }
    };
    const Case = struct { result: Commit, candidate_is_canonical: bool, fault_baseline: bool = false };
    for ([_]Case{
        .{ .result = .failed, .candidate_is_canonical = false },
        .{ .result = .outcome_unknown, .candidate_is_canonical = false },
        .{ .result = .outcome_unknown, .candidate_is_canonical = true },
        .{ .result = .failed, .candidate_is_canonical = false, .fault_baseline = true },
        .{ .result = .outcome_unknown, .candidate_is_canonical = false, .fault_baseline = true },
        .{ .result = .outcome_unknown, .candidate_is_canonical = true, .fault_baseline = true },
    }) |case| {
        fake_core.reset();
        fake_core.setCheckpointGeneration(1);
        const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 2, .max_sessions = 1 });
        defer {
            shutdownTestComposition(runtime) catch unreachable;
            deinitTestComposition(runtime);
        }
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        defer std.testing.allocator.free(home);
        var store = try product_task.checkpoint_store.FileStore.init(std.testing.io, home);
        defer store.deinit();
        const storage = try std.testing.allocator.alloc(u8, 1024 * 1024);
        defer std.testing.allocator.free(storage);
        const candidate = try std.testing.allocator.alloc(u8, 1024 * 1024);
        defer std.testing.allocator.free(candidate);
        var history = Harness{ .storage = storage, .candidate = candidate, .main_thread = std.Thread.getCurrentId(), .result = case.result, .candidate_is_canonical = case.candidate_is_canonical, .fault_baseline = case.fault_baseline };
        var configuration = productControlConfiguration();
        configuration.directories.canonical_user_home = home;
        configuration.task_persistence = history.capability(null);
        configuration.checkpoint_store = .{ .file_store = &store };
        const limits: product_control.Limits = .{ .worker_count = 1, .queue_capacity = 2, .max_workspaces = 1, .max_tasks = 1 };
        var control = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, limits, configuration);
        defer control.deinit();
        try installControlExecution(&control);
        var input = productControlTaskInput();
        input.workspace_root = home;
        input.trust = .explicitly_trusted;
        input.approval_mode = .manual;
        const task_id = try control.createTask(input, try product_control.TestSupport.fixtureModelSelection(&control));
        const task = control.task_runtime.find(task_id).?;
        const route = task.runtime.routeId();
        const main_writes = history.main_writes;
        _ = try control.setApprovalMode(task_id, .full_access, 1, 1);
        try std.testing.expectEqual(.baseline_export, task.approval_change.?.phase);
        const baseline_job = pending: {
            for (control.task_runtime.approval_jobs) |entry| if (entry) |slot| if (slot.task_id == task_id) break :pending slot.job;
            return error.TestUnexpectedResult;
        };
        for (0..2000) |_| {
            if (baseline_job.completionReady()) break;
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        }
        try std.testing.expect(baseline_job.completionReady());
        try std.testing.expect(baseline_job.outcome == .checkpoint);
        const baseline = baseline_job.outcome.checkpoint.blob;
        // The fake exporter uses explicit fixture payload/generation and its
        // restore derives the logical ID from the creation counter. Configure
        // these before the next job starts; official Core reads them from blob.
        fake_core.lock();
        fake_core.checkpoint_payload = "mode-candidate-checkpoint";
        if (!case.candidate_is_canonical) fake_core.session_created = 0;
        fake_core.unlock();
        if (case.fault_baseline) {
            for (0..5000) |_| {
                control.syncLifecycle();
                if (task.approval_change == null or task.approval_change.?.phase == .outcome_unknown) break;
                try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
            }
            // Core cannot change until canonical metadata confirms the old
            // recovery point. Unknown readback is an explicit, read-only step.
            try std.testing.expectEqual(.manual, try control.taskApprovalMode(task_id));
            try std.testing.expectEqual(@as(u64, 1), task.durable.approval_revision);
            try std.testing.expect(task.durable.checkpoint == null);
            try std.testing.expectEqual(route, task.runtime.routeId());
            fake_core.lock();
            const premature_updates = fake_core.permission_mode_updates;
            const premature_restores = fake_core.checkpoint_restores;
            fake_core.unlock();
            try std.testing.expectEqual(@as(usize, 0), premature_updates);
            try std.testing.expectEqual(@as(usize, 0), premature_restores);
            if (case.result == .outcome_unknown) {
                try std.testing.expectEqual(.outcome_unknown, task.approval_change.?.phase);
                const retained = task.approval_change.?.unknown_history.?.token;
                var cancelled: std.atomic.Value(bool) = .init(false);
                var source = try store.openVerified(baseline, &cancelled);
                source.deinit();
                try std.testing.expectError(error.TaskBusy, control.runTask(task_id, .{ .text = "unconfirmed baseline cannot execute" }));
                for (0..10) |_| control.syncLifecycle();
                try std.testing.expectEqual(@as(usize, 1), history.mode_writes);
                try std.testing.expectEqual(@as(usize, 0), history.resolutions);
                try std.testing.expectEqual(.outcome_unknown, control.recoverTaskHistory(control.currentRevision()));
                for (0..2000) |_| {
                    control.syncLifecycle();
                    if (!control.task_runtime.approvalJobFor(task_id)) break;
                    try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
                }
                try std.testing.expectEqual(@as(usize, 1), history.resolutions);
                try std.testing.expectEqualSlices(u8, &retained, &task.approval_change.?.unknown_history.?.token);
                try std.testing.expectEqual(.outcome_unknown, task.approval_change.?.phase);
                fake_core.lock();
                const still_no_updates = fake_core.permission_mode_updates;
                fake_core.unlock();
                try std.testing.expectEqual(@as(usize, 0), still_no_updates);
                try std.testing.expectEqual(.outcome_unknown, control.recoverTaskHistory(control.currentRevision()));
                for (0..5000) |_| {
                    control.syncLifecycle();
                    if (task.approval_change == null) break;
                    try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
                }
                try std.testing.expectEqual(@as(usize, 2), history.resolutions);
            }
            try std.testing.expect(task.approval_change == null);
            try std.testing.expectEqual(@as(@TypeOf(task.approval_result.?.outcome), if (case.candidate_is_canonical) .completed else .failed), task.approval_result.?.outcome);
            if (!case.candidate_is_canonical) try std.testing.expectEqual(.persistence_failed, task.approval_result.?.reason.?);
            try std.testing.expectEqual(@as(product_control.ApprovalMode, if (case.candidate_is_canonical) .full_access else .manual), try control.taskApprovalMode(task_id));
            try std.testing.expectEqual(@as(u64, if (case.candidate_is_canonical) 2 else 1), task.durable.approval_revision);
            try std.testing.expectEqual(@as(u64, if (!case.fault_baseline and !case.candidate_is_canonical) 2 else 1), task.durable.binding_epoch);
            try std.testing.expectEqual(route, task.runtime.routeId());
            try std.testing.expect(!task.runtime.worker_leases.hasLive());
            try std.testing.expectEqual(@as(usize, if (case.candidate_is_canonical) 2 else 1), history.mode_writes);
            try std.testing.expectEqual(@as(usize, 0), history.recoveries);
            try std.testing.expectEqual(main_writes, history.main_writes);
            for (0..2000) |_| {
                control.syncLifecycle();
                if (!control.task_runtime.approval_cleanup_leases.hasLive()) break;
                try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
            }
            try std.testing.expect(!control.task_runtime.approval_cleanup_leases.hasLive());
            if (!case.candidate_is_canonical) {
                var cancelled: std.atomic.Value(bool) = .init(false);
                try std.testing.expectError(error.BlobMissing, store.openVerified(baseline, &cancelled));
                try std.testing.expect(task.durable.checkpoint == null);
            } else try std.testing.expectEqual(@as(u64, 2), task.durable.checkpoint.?.anchor.terminal.approval);
            for (0..10) |_| control.syncLifecycle();
            fake_core.lock();
            const updates = fake_core.permission_mode_updates;
            const restores = fake_core.checkpoint_restores;
            const runs = fake_core.run_calls;
            fake_core.unlock();
            try std.testing.expectEqual(@as(usize, if (case.candidate_is_canonical) 1 else 0), updates);
            try std.testing.expectEqual(@as(usize, 0), restores);
            try std.testing.expectEqual(@as(usize, 0), runs);
            continue;
        }
        for (0..5000) |_| {
            control.syncLifecycle();
            if (task.approval_change == null or task.approval_change.?.phase == .outcome_unknown) break;
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        }
        if (case.result == .outcome_unknown) {
            try std.testing.expect(task.approval_change != null);
            try std.testing.expectEqual(.outcome_unknown, task.approval_change.?.phase);
            const retained = task.approval_change.?.unknown_history.?.token;
            const pending_blob = task.approval_change.?.candidate.?.blob;
            try std.testing.expect(!std.meta.eql(baseline, pending_blob));
            try std.testing.expectEqual(.manual, try control.taskApprovalMode(task_id));
            try std.testing.expectEqual(@as(u64, 1), task.durable.approval_revision);
            try std.testing.expectEqual(baseline, task.durable.checkpoint.?.blob);
            var cancelled: std.atomic.Value(bool) = .init(false);
            var old_source = try store.openVerified(baseline, &cancelled);
            old_source.deinit();
            var new_source = try store.openVerified(pending_blob, &cancelled);
            new_source.deinit();
            try std.testing.expectError(error.TaskBusy, control.runTask(task_id, .{ .text = "unknown mode cannot execute" }));
            const writes = history.mode_writes;
            for (0..10) |_| control.syncLifecycle();
            try std.testing.expectEqual(writes, history.mode_writes);
            try std.testing.expectEqual(@as(usize, 0), history.resolutions);
            fake_core.lock();
            const premature_restores = fake_core.checkpoint_restores;
            fake_core.unlock();
            try std.testing.expectEqual(@as(usize, 0), premature_restores);
            {
                var access = try task.runtime.acquireAccess();
                defer access.deinit();
                const actual = try access.updatePermissionMode(.full_access, .full_access);
                try std.testing.expect(!actual.changed);
                try std.testing.expectEqual(@as(u64, 2), actual.policy_generation);
            }
            // Restart reads canonical disk facts while the old process still
            // keeps both recovery points. It must not invent the old memory mode.
            {
                // Observe a frozen canonical snapshot through an independent
                // store. A second Host writer cannot share the live unknown
                // transaction's capability or alter its retained witness.
                const restart_storage = try std.testing.allocator.alloc(u8, 1024 * 1024);
                defer std.testing.allocator.free(restart_storage);
                var restart_history = TaskPersistenceProbe{ .storage = restart_storage };
                var restarted_configuration = configuration;
                restarted_configuration.task_persistence = restart_history.capabilityRestored(storage[0..history.len]);
                var restarted = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, limits, restarted_configuration);
                defer restarted.deinit();
                try std.testing.expectEqual(@as(product_control.ApprovalMode, if (case.candidate_is_canonical) .full_access else .manual), try restarted.taskApprovalMode(task_id));
                const saved = restarted.task_runtime.find(task_id).?;
                try std.testing.expectEqual(@as(u64, if (case.candidate_is_canonical) 2 else 1), saved.durable.approval_revision);
                try std.testing.expect(!saved.runtime.hasAttachedSession());
            }
            try std.testing.expectEqual(.outcome_unknown, control.recoverTaskHistory(control.currentRevision()));
            for (0..2000) |_| {
                control.syncLifecycle();
                if (!control.task_runtime.approvalJobFor(task_id)) break;
                try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
            }
            try std.testing.expectEqual(@as(usize, 1), history.resolutions);
            try std.testing.expectEqualSlices(u8, &retained, &task.approval_change.?.unknown_history.?.token);
            try std.testing.expectEqual(.outcome_unknown, task.approval_change.?.phase);
            try std.testing.expectEqual(writes, history.mode_writes);
            try std.testing.expectEqual(.outcome_unknown, control.recoverTaskHistory(control.currentRevision()));
            for (0..5000) |_| {
                control.syncLifecycle();
                if (task.approval_change == null) break;
                try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
            }
            try std.testing.expectEqual(@as(usize, 2), history.resolutions);
        }
        try std.testing.expect(task.approval_change == null);
        try std.testing.expectEqual(@as(@TypeOf(task.approval_result.?.outcome), if (case.candidate_is_canonical) .completed else .failed), task.approval_result.?.outcome);
        try std.testing.expectEqual(@as(product_control.ApprovalMode, if (case.candidate_is_canonical) .full_access else .manual), try control.taskApprovalMode(task_id));
        try std.testing.expectEqual(@as(u64, if (case.candidate_is_canonical) 2 else 1), task.durable.approval_revision);
        try std.testing.expectEqual(@as(u64, if (!case.fault_baseline and !case.candidate_is_canonical) 2 else 1), task.durable.binding_epoch);
        try std.testing.expect(task.runtime.hasAttachedSession());
        try std.testing.expectEqual(case.candidate_is_canonical, route == task.runtime.routeId());
        try std.testing.expect(!task.runtime.worker_leases.hasLive());
        try std.testing.expectEqual(@as(usize, 1), history.mode_writes);
        try std.testing.expectEqual(@as(usize, 0), history.recoveries);
        try std.testing.expectEqual(main_writes, history.main_writes);
        for (0..2000) |_| {
            control.syncLifecycle();
            if (!control.task_runtime.approval_cleanup_leases.hasLive()) break;
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        }
        try std.testing.expect(!control.task_runtime.approval_cleanup_leases.hasLive());
        if (!case.candidate_is_canonical) {
            // A definitively rejected candidate has no canonical reference.
            // Its immutable file needs the same retirement owner as an old
            // checkpoint after a successful mode commit.
            var rejected = try product_task.history.decode(std.testing.allocator, candidate[0..history.candidate_len], .{
                .max_workspaces = 1,
                .max_tasks = 1,
                .max_runs_per_task = 8,
                .max_compacts_per_task = 8,
                .max_tools_per_run = 8,
                .max_commentary_segments_per_run = 64,
                .max_file_refs_per_tool = 8,
                .max_ui_history_per_task = 8,
                .max_workspace_bytes = 4096,
                .max_task_title_bytes = 512,
                .max_user_message_bytes = 4096,
                .max_assistant_message_bytes = 4096,
                .max_tool_field_bytes = 4096,
                .max_file_ref_field_bytes = 4096,
                .max_execution_model_bytes = 512,
                .max_terminal_diagnostic_bytes = 512,
            });
            defer rejected.deinit();
            const blob = rejected.value.tasks[0].checkpoint.?.blob;
            var digest: [32]u8 = undefined;
            _ = try std.fmt.hexToBytes(&digest, blob.digest);
            const identity: product_task.checkpoint_store.Identity = .{ .task_id = task_id, .generation = blob.generation, .digest = digest, .byte_size = blob.byte_size };
            var cancelled: std.atomic.Value(bool) = .init(false);
            try std.testing.expectError(error.BlobMissing, store.openVerified(identity, &cancelled));
            var old_source = try store.openVerified(baseline, &cancelled);
            old_source.deinit();
        }
        fake_core.lock();
        const restores = fake_core.checkpoint_restores;
        const runs = fake_core.run_calls;
        const updates = fake_core.permission_mode_updates;
        fake_core.unlock();
        try std.testing.expectEqual(@as(usize, if (case.candidate_is_canonical) 0 else 1), restores);
        try std.testing.expectEqual(@as(usize, 0), runs);
        // Only the original mutation and the unknown-state no-op observation:
        // rollback must restore the old baseline, never reverse-mutate grants.
        try std.testing.expectEqual(@as(usize, if (case.result == .outcome_unknown) 2 else 1), updates);
        var access = try task.runtime.acquireAccess();
        defer access.deinit();
        const mode: lifecycle.PermissionMode = if (case.candidate_is_canonical) .full_access else .accept_edits;
        const actual = try access.updatePermissionMode(mode, mode);
        try std.testing.expect(!actual.changed);
        try std.testing.expectEqual(@as(u64, if (case.candidate_is_canonical) 2 else 1), actual.policy_generation);
    }
}

fn settleInputScenario(scenario: *ReviewScenario) !void {
    for (0..5000) |_| {
        try scenario.control.drainAgentEvents();
        const task = scenario.control.task_runtime.find(scenario.task_id).?;
        // Retiring the source worker can precede event/checkpoint finalization.
        // A continuation or accepted waiting message is still work while idle.
        if (!task.runtime.worker_leases.hasLive() and task.runtime.active_operation == .none and
            scenario.control.task_runtime.inputContinuation(scenario.task_id) == null and
            scenario.control.task_runtime.inputAction(scenario.task_id) == .none) return;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    return error.TestUnexpectedResult;
}

test "active input continues exactly once after normal completion and never repeats adopted input" {
    for ([_]bool{ false, true }) |gap| {
        for ([_]bool{ false, true }) |adopt| {
            const scenario = try ReviewScenario.initForInput(.controlled);
            defer scenario.deinit();
            fake_core.adopt_input_before_receipt = adopt;
            fake_core.expected_run_text = "new constraint fixture-secret";
            const task = scenario.control.task_runtime.find(scenario.task_id).?;
            const id = task.runtime.active_run_id;
            const epoch = task.durable.binding_epoch;
            const response = try scenario.control.testSendInput("input-1", scenario.task_id, epoch, .{ .run = id }, .{ .text = "new constraint fixture-secret" });
            try std.testing.expectEqual(.submitted, response.outcome);
            try std.testing.expectEqual(@as(?u64, id), response.run_id);
            try std.testing.expectEqual(@as(?u32, 1), response.sequence);
            try std.testing.expectEqualStrings("new constraint fixture-secret", task.durable.runs[0].?.additional_inputs[0].?.raw_text.?);
            try std.testing.expectEqual(@as(usize, "new constraint fixture-secret".len), scenario.control.task_runtime.pending_input_bytes);
            try std.testing.expect(std.mem.indexOf(u8, task.durable.runs[0].?.additional_inputs[0].?.text, "fixture-secret") == null);
            if (gap) _ = task_state.recordEventProjectionFailure(&task.durable.runs[0].?);
            fake_core.releaseControlled();
            try settleInputScenario(scenario);
            const history = &task.durable.runs[0].?.additional_inputs[0].?;
            try std.testing.expect(history.raw_text == null);
            try std.testing.expectEqual(@as(usize, 0), scenario.control.task_runtime.pending_input_bytes);
            try std.testing.expectEqual(@as(u32, 0), history.after_output_count);
            try std.testing.expectEqual(if (adopt) task_state.AdditionalInputState.adopted else .transferred, history.state);
            try std.testing.expectEqual(adopt, history.order != null);
            try std.testing.expectEqual(if (adopt) @as(?u64, null) else task.durable.runs[1].?.id, history.transferred_to_run_id);
            if (!adopt) try std.testing.expect(fake_core.run_text_matches);
            const late = try scenario.control.testSendInput("input-late", scenario.task_id, epoch, .{ .run = id }, .{ .text = "do not launch again" });
            try std.testing.expectEqual(.rejected, late.outcome);
            for (0..5) |_| scenario.control.syncLifecycle();
            try std.testing.expectEqual(@as(usize, if (adopt) 1 else 2), fake_core.run_calls);
        }
    }
}

test "active input accepted during review prevents automatic allow but not manual response" {
    const scenario = try ReviewScenario.initForInput(.ui_wait);
    defer scenario.deinit();
    var review = try scenario.prepare();
    defer review.deinit();
    const task = scenario.control.task_runtime.find(scenario.task_id).?;
    const result = try scenario.control.testSendInput("review-interjection", scenario.task_id, task.durable.binding_epoch, .{ .run = task.runtime.active_run_id }, .{ .text = "do not delete that directory" });
    try std.testing.expectEqual(.submitted, result.outcome);
    var commit: ReviewCommit = .{};
    try std.testing.expect(!try scenario.control.task_runtime.acceptPermissionReview(review.identity, reviewSuggestion(.allow_once, "bounded operation"), commit.effects(scenario)));
    try std.testing.expectEqual(@as(usize, 0), commit.calls);
    try std.testing.expectEqual(.needs_user, task.permissionReviewPhase());
    _ = try scenario.control.respondUi(scenario.task_id, task.runtime.active_run_id, review.identity.request_id, .{ .permission = .deny_once });
    fake_core.releaseControlled();
    // Observe the successor's permission request before cancelling it: this
    // fake Core does not suppress a new callback after a pre-callback abort.
    for (0..5000) |_| {
        try scenario.control.drainAgentEvents();
        if (task.durable.runs[1]) |next| {
            if (task.runtime.pending_ui_request_id != 0) {
                try scenario.control.cancel(scenario.task_id, next.id);
                break;
            }
        }
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    try settleInputScenario(scenario);
    try std.testing.expectEqual(.transferred, task.durable.runs[0].?.additional_inputs[0].?.state);
    try std.testing.expectEqual(@as(usize, 2), fake_core.run_calls);
}

test "active input before review preparation stays manual and automatic deny remains valid" {
    for ([_]bool{ false, true }) |review_started| {
        const scenario = try ReviewScenario.initForInput(.ui_wait);
        defer scenario.deinit();
        const task = scenario.control.task_runtime.find(scenario.task_id).?;
        var prepared: ?product_task.PreparedPermissionReview = if (review_started) try scenario.prepare() else null;
        defer if (prepared) |*value| value.deinit();
        _ = try scenario.control.testSendInput("constraint", scenario.task_id, task.durable.binding_epoch, .{ .run = task.runtime.active_run_id }, .{ .text = "do not delete" });
        if (prepared) |review| {
            var commit: ReviewCommit = .{};
            try std.testing.expect(try scenario.control.task_runtime.acceptPermissionReview(review.identity, reviewSuggestion(.deny, "forbidden operation"), commit.effects(scenario)));
            try std.testing.expectEqual(@as(usize, 1), commit.calls);
        } else {
            _ = try scenario.control.task_runtime.testSetPermissionReviewDelegation(scenario.task_id, true);
            try std.testing.expect(try scenario.control.task_runtime.preparePermissionReview(scenario.task_id, scenario.text()) == null);
            try std.testing.expectEqual(.needs_user, task.permissionReviewPhase());
            try std.testing.expect(try scenario.control.task_runtime.preparePermissionReview(scenario.task_id, scenario.text()) == null);
        }
    }
}

test "active input adopted before the next permission request enters its complete review intent" {
    const scenario = try ReviewScenario.initForInput(.ui_wait_repeated);
    defer scenario.deinit();
    const task = scenario.control.task_runtime.find(scenario.task_id).?;
    var access = try task.runtime.acquireAccess();
    defer access.deinit();
    var first: ?u64 = null;
    for (0..5000) |_| {
        if (access.pendingUiObservation()) |pending| {
            first = pending.request_id;
            break;
        }
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expect(first != null);
    fake_core.adopt_input_before_receipt = true;
    _ = try scenario.control.testSendInput("adopted-constraint", scenario.task_id, task.durable.binding_epoch, .{ .run = task.runtime.active_run_id }, .{ .text = "Preserve the exact directory constraint" });
    _ = try scenario.control.respondUi(scenario.task_id, task.runtime.active_run_id, first.?, .{ .permission = .deny_once });
    for (0..5000) |_| {
        if (access.pendingUiObservation()) |pending| if (pending.request_id != first.?) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    const pending = access.pendingUiObservation().?;
    try std.testing.expect(pending.request_id != first.?);
    try std.testing.expectEqual(@as(u32, 1), pending.input_adopted_count);
    var review = try scenario.prepare();
    defer review.deinit();
    try std.testing.expect(std.mem.indexOf(u8, review.input.user_intent, "Perform the bounded operation") != null);
    try std.testing.expect(std.mem.indexOf(u8, review.input.user_intent, "Preserve the exact directory constraint") != null);
}

test "active input persisted before adoption restores as unknown without execution" {
    const bytes = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(bytes);
    var history = TaskPersistenceProbe{ .storage = bytes };
    var configuration = productControlConfiguration();
    configuration.task_persistence = history.capability();
    const scenario = try ReviewScenario.initConfigured(configuration, 2, .controlled, true);
    defer scenario.deinit();
    const task = scenario.control.task_runtime.find(scenario.task_id).?;
    _ = try scenario.control.testSendInput("persist-pending", scenario.task_id, task.durable.binding_epoch, .{ .run = task.runtime.active_run_id }, .{ .text = "Keep this constraint in history only" });
    _ = try scenario.control.testSendInput("persist-pending-second", scenario.task_id, task.durable.binding_epoch, .{ .run = task.runtime.active_run_id }, .{ .text = "Second independent constraint" });
    const saved = try std.testing.allocator.dupe(u8, bytes[0..history.len]);
    defer std.testing.allocator.free(saved);
    var restart = productControlConfiguration();
    restart.task_persistence = history.capabilityRestored(saved);
    var restored = try product_control.Runtime.init(std.testing.allocator, std.testing.io, scenario.runtime, .{ .worker_count = 1, .queue_capacity = 1, .max_tasks = 1, .max_runs_per_task = 2, .max_tools_per_run = 1 }, restart);
    defer restored.deinit();
    const recovered = restored.task_runtime.find(scenario.task_id).?;
    try std.testing.expectEqual(.unknown, recovered.durable.runs[0].?.additional_inputs[0].?.state);
    try std.testing.expectEqualStrings("Keep this constraint in history only", recovered.durable.runs[0].?.additional_inputs[0].?.text);
    try std.testing.expectEqualStrings("persist-pending", recovered.durable.runs[0].?.additional_inputs[0].?.operationId());
    try std.testing.expectEqual(@as(u32, 0), recovered.durable.runs[0].?.additional_inputs[0].?.after_output_count);
    const second = recovered.durable.runs[0].?.additional_inputs[1] orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(.unknown, second.state);
    try std.testing.expectEqualStrings("persist-pending-second", second.operationId());
    try std.testing.expectEqualStrings("Second independent constraint", second.text);
    try std.testing.expect(recovered.runtime.active_operation == .none);
    try std.testing.expect(!recovered.runtime.hasAttachedSession());
    restored.syncLifecycle();
    try std.testing.expectEqual(@as(usize, 1), fake_core.run_calls);
}

test "active input terminal counts do not invent an adoption anchor or certainty" {
    for ([_]bool{ false, true }) |invalid_terminal| {
        const scenario = try ReviewScenario.initForInput(.controlled);
        defer scenario.deinit();
        fake_core.adopt_input_before_receipt = !invalid_terminal;
        fake_core.omit_input_adopted_event = true;
        if (invalid_terminal) fake_core.forced_input_run_status = std.math.maxInt(u32);
        const task = scenario.control.task_runtime.find(scenario.task_id).?;
        _ = try scenario.control.testSendInput("no-event", scenario.task_id, task.durable.binding_epoch, .{ .run = task.runtime.active_run_id }, .{ .text = "Do not infer a false position" });
        fake_core.releaseControlled();
        try settleInputScenario(scenario);
        const message = task.durable.runs[0].?.additional_inputs[0].?;
        try std.testing.expectEqual(if (invalid_terminal) task_state.AdditionalInputState.unknown else .adopted, message.state);
        try std.testing.expect(message.order == null and message.adopted_turn == null);
        try std.testing.expectEqual(@as(usize, 1), fake_core.run_calls);
        try std.testing.expect(task.runtime.active_operation == .none);
    }
}

test "active input merges the unadopted suffix in order and preserves submitted anchors" {
    const scenario = try ReviewScenario.initForInput(.controlled);
    defer scenario.deinit();
    const task = scenario.control.task_runtime.find(scenario.task_id).?;
    const source = &task.durable.runs[0].?;
    fake_core.adopt_input_before_receipt = true;
    _ = try scenario.control.testSendInput("adopt-first", scenario.task_id, task.durable.binding_epoch, .{ .run = source.id }, .{ .text = "already handled" });
    fake_core.adopt_input_before_receipt = false;
    _ = try scenario.control.testSendInput("next-one", scenario.task_id, task.durable.binding_epoch, .{ .run = source.id }, .{ .text = "first fixture-secret" });
    _ = try scenario.control.testSendInput("next-two", scenario.task_id, task.durable.binding_epoch, .{ .run = source.id }, .{ .text = "second" });
    fake_core.expected_run_text = "first fixture-secret\n\nsecond";
    fake_core.releaseControlled();
    try settleInputScenario(scenario);
    try std.testing.expect(fake_core.run_text_matches);
    try std.testing.expectEqual(.adopted, source.additional_inputs[0].?.state);
    for (source.additional_inputs[1..3]) |entry| {
        try std.testing.expectEqual(.transferred, entry.?.state);
        try std.testing.expectEqual(@as(?u64, task.durable.runs[1].?.id), entry.?.transferred_to_run_id);
        try std.testing.expectEqual(@as(u32, 0), entry.?.after_output_count);
        try std.testing.expect(entry.?.raw_text == null);
    }
    try std.testing.expectEqual(@as(usize, 2), fake_core.run_calls);
    try std.testing.expectEqual(@as(usize, 0), scenario.control.task_runtime.pending_input_bytes);
}

test "active input terminal reservation rejects competing sends and a late Stop cancels it" {
    const scenario = try ReviewScenario.initForInput(.controlled);
    defer scenario.deinit();
    const task = scenario.control.task_runtime.find(scenario.task_id).?;
    const source = &task.durable.runs[0].?;
    _ = try scenario.control.testSendInput("late", scenario.task_id, task.durable.binding_epoch, .{ .run = source.id }, .{ .text = "follow up" });
    var lease = try task.runtime.worker_leases.acquire();
    defer if (lease.isActive()) lease.deinit();
    fake_core.releaseControlled();
    for (0..5000) |_| {
        try scenario.control.drainAgentEvents();
        if (source.input_continuation_pending) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expect(source.input_continuation_pending);
    try std.testing.expect(task.runtime.active_operation == .none);
    try std.testing.expectError(error.TaskBusy, scenario.control.runTask(scenario.task_id, .{ .text = "new draft" }));
    try scenario.control.cancel(scenario.task_id, source.id);
    try std.testing.expect(source.input_continuation_cancelled);
    try std.testing.expect(!task.runtime.cancel_requested);
    try std.testing.expectEqual(.continuation_cancelled, source.input_continuation_failure.?);
    lease.deinit();
    try settleInputScenario(scenario);
    try std.testing.expectEqual(.unadopted, source.additional_inputs[0].?.state);
    try std.testing.expectEqual(@as(usize, 0), scenario.control.task_runtime.pending_input_bytes);
    try std.testing.expectEqual(@as(usize, 1), fake_core.run_calls);
}

test "active input Stop before terminal never continues and releases the payload" {
    const scenario = try ReviewScenario.initForInput(.controlled);
    defer scenario.deinit();
    const task = scenario.control.task_runtime.find(scenario.task_id).?;
    const source = &task.durable.runs[0].?;
    _ = try scenario.control.testSendInput("stop", scenario.task_id, task.durable.binding_epoch, .{ .run = source.id }, .{ .text = "do not repeat" });
    try scenario.control.cancel(scenario.task_id, source.id);
    fake_core.releaseControlled();
    try settleInputScenario(scenario);
    try std.testing.expectEqual(.unadopted, source.additional_inputs[0].?.state);
    try std.testing.expect(source.additional_inputs[0].?.raw_text == null);
    try std.testing.expectEqual(@as(usize, 1), fake_core.run_calls);
}

test "active input continuation grows history and oversized input failure is final" {
    for ([_]bool{ false, true }) |too_large| {
        const scenario = try ReviewScenario.initConfigured(productControlConfiguration(), if (too_large) 2 else 1, .controlled, true);
        defer scenario.deinit();
        const task = scenario.control.task_runtime.find(scenario.task_id).?;
        const source_id = task.durable.runs[0].?.id;
        const source = &task.durable.runs[0].?;
        _ = try scenario.control.testSendInput("one", scenario.task_id, task.durable.binding_epoch, .{ .run = source.id }, .{ .text = "12345" });
        _ = try scenario.control.testSendInput("two", scenario.task_id, task.durable.binding_epoch, .{ .run = source.id }, .{ .text = "67890" });
        if (too_large) scenario.control.limits.max_user_message_bytes = 11;
        fake_core.releaseControlled();
        try settleInputScenario(scenario);
        const settled_source = task_state.findRun(task.durable.runs, source_id).?;
        try std.testing.expect(settled_source.input_continuation_attempted);
        if (too_large) try std.testing.expectEqual(task_state.SendInputReason.combined_input_too_large, settled_source.input_continuation_failure.?) else try std.testing.expect(settled_source.input_continuation_failure == null);
        for (settled_source.additional_inputs[0..2]) |entry| {
            try std.testing.expectEqual(if (too_large) task_state.AdditionalInputState.unadopted else .transferred, entry.?.state);
            try std.testing.expect((entry.?.transferred_to_run_id == null) == too_large and entry.?.raw_text == null);
        }
        scenario.control.limits.max_user_message_bytes = 256 * 1024;
        for (0..5) |_| scenario.control.syncLifecycle();
        try std.testing.expectEqual(@as(usize, if (too_large) 1 else 2), fake_core.run_calls);
    }
}

test "active input Schedule confirmation precedes transfer and failed confirmation never revives" {
    for ([_]bool{ false, true }) |fail_confirmation| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path_len = try tmp.dir.realPath(std.testing.io, &path_buffer);
        var root = try product_control.AutomaticWorkspaceRoot.open(std.testing.io, std.testing.allocator, path_buffer[0..path_len]);
        defer root.deinit();
        var schedule: TestScheduleSupport = .{};
        var configuration = productControlConfiguration();
        configuration.directories.testing_automatic_workspace_root = &root;
        configuration.schedule_timer = schedule.timer();
        configuration.schedule_persistence = schedule.persistence();
        const scenario = try ReviewScenario.initConfigured(configuration, 2, .controlled, true);
        defer scenario.deinit();
        const task = scenario.control.task_runtime.find(scenario.task_id).?;
        const source = &task.durable.runs[0].?;
        const schedule_id = try scenario.control.createScheduledTask(.{
            .title = "source occurrence",
            .model_selection = try product_control.TestSupport.fixtureModelSelection(&scenario.control),
            .permission_profile = .approval_required,
            .input = "source input",
            .recurrence = .{ .once = .{ .at_unix_seconds = 2000 } },
        });
        // Model the durable submitted occurrence pointing at this live Task.
        const store = &scenario.control.schedule.store;
        const item = store.find(schedule_id).?;
        try store.claim(item, 1000, 1000, .manual);
        try store.finalizeClaimSubmitted(item, 1000, .manual, scenario.task_id);
        _ = try scenario.control.testSendInput("schedule-late", scenario.task_id, task.durable.binding_epoch, .{ .run = source.id }, .{ .text = "next input" });
        if (fail_confirmation) schedule.commit_result = .failed;
        fake_core.releaseControlled();
        try settleInputScenario(scenario);
        const message = source.additional_inputs[0].?;
        if (fail_confirmation) {
            try std.testing.expectEqual(.unadopted, message.state);
            try std.testing.expectEqual(.schedule_failed, source.input_continuation_failure.?);
            try std.testing.expectEqual(@as(usize, 1), fake_core.run_calls);
            schedule.commit_result = .committed;
            _ = scenario.control.recoverScheduledTaskStore(scenario.control.currentRevision());
            for (0..5) |_| scenario.control.syncLifecycle();
            try std.testing.expectEqual(@as(usize, 1), fake_core.run_calls);
        } else {
            try std.testing.expectEqual(.transferred, message.state);
            try std.testing.expectEqual(@as(usize, 2), fake_core.run_calls);
            try std.testing.expect(!scenario.control.schedule.hasPendingSubmittedOccurrence(scenario.task_id));
            const recorded = store.find(schedule_id).?.last_occurrence.?;
            try std.testing.expectEqual(.completed, recorded.task_outcome.?);
        }
        try std.testing.expectEqual(@as(usize, 0), scenario.control.task_runtime.pending_input_bytes);
    }
}

test "active input terminal reservation obeys accepted archive approval and workspace cancellation" {
    const Action = enum { archive_task, approval, workspace };
    for (std.enums.values(Action)) |action| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        defer std.testing.allocator.free(home);
        var history: TaskPersistenceProbe = .{};
        var configuration = productControlConfiguration();
        configuration.directories.canonical_user_home = home;
        configuration.task_persistence = history.capability();
        const scenario = try ReviewScenario.initConfigured(configuration, 2, .controlled, true);
        defer scenario.deinit();
        const task = scenario.control.task_runtime.find(scenario.task_id).?;
        const source = &task.durable.runs[0].?;
        _ = try scenario.control.testSendInput("cancel-intent", scenario.task_id, task.durable.binding_epoch, .{ .run = source.id }, .{ .text = "follow up" });
        var lease = try task.runtime.worker_leases.acquire();
        defer if (lease.isActive()) lease.deinit();
        fake_core.releaseControlled();
        for (0..5000) |_| {
            try scenario.control.drainAgentEvents();
            if (source.input_continuation_pending) break;
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        }
        try std.testing.expect(source.input_continuation_pending);
        switch (action) {
            .archive_task => try scenario.control.setTaskArchived(scenario.task_id, true),
            .approval => _ = try scenario.control.setApprovalMode(scenario.task_id, .auto_review, task.durable.binding_epoch, task.durable.approval_revision),
            .workspace => try scenario.control.removeWorkspace(task.durable.workspace_id),
        }
        try std.testing.expect(source.input_continuation_cancelled);
        try std.testing.expect(!source.input_continuation_pending);
        try std.testing.expectEqual(@as(usize, 0), scenario.control.task_runtime.pending_input_bytes);
        lease.deinit();
        try settleInputScenario(scenario);
        try std.testing.expectEqual(@as(usize, 1), fake_core.run_calls);
    }
}

test "active input approval cancellation applies only to existing messages and rejected sends cannot reopen it" {
    const Next = enum { none, rejected, accepted, accepted_then_stop };
    for (std.enums.values(Next)) |next| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        defer std.testing.allocator.free(home);
        var history: TaskPersistenceProbe = .{};
        var configuration = productControlConfiguration();
        configuration.directories.canonical_user_home = home;
        configuration.task_persistence = history.capability();
        const scenario = try ReviewScenario.initConfigured(configuration, 2, .controlled, true);
        defer scenario.deinit();
        const task = scenario.control.task_runtime.find(scenario.task_id).?;
        const source = &task.durable.runs[0].?;
        const epoch = task.durable.binding_epoch;
        _ = try scenario.control.testSendInput("before-mode-change", scenario.task_id, epoch, .{ .run = source.id }, .{ .text = "old cancelled message" });
        _ = try scenario.control.setApprovalMode(scenario.task_id, .auto_review, epoch, task.durable.approval_revision);
        for (0..5000) |_| {
            scenario.control.syncLifecycle();
            if (task.approval_change == null) break;
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        }
        try std.testing.expect(task.approval_change == null);
        try std.testing.expectEqual(.auto_review, try scenario.control.taskApprovalMode(scenario.task_id));
        try std.testing.expect(source.input_continuation_cancelled);
        try std.testing.expect(source.additional_inputs[0].?.raw_text == null);
        try std.testing.expectEqual(.continuation_cancelled, source.additional_inputs[0].?.continuation_cancel_reason.?);

        if (next == .rejected) {
            fake_core.forced_input_status = wire.STATUS_TOO_LATE;
            const response = try scenario.control.testSendInput("rejected-after-change", scenario.task_id, epoch, .{ .run = source.id }, .{ .text = "rejected message" });
            try std.testing.expectEqual(.rejected, response.outcome);
            try std.testing.expect(source.input_continuation_cancelled);
            fake_core.forced_input_status = null;
        } else if (next == .accepted or next == .accepted_then_stop) {
            for ([_][]const u8{ "new first message", "new second message" }, 0..) |text, i| {
                const response = try scenario.control.testSendInput(if (i == 0) "new-1" else "new-2", scenario.task_id, epoch, .{ .run = source.id }, .{ .text = text });
                try std.testing.expectEqual(.submitted, response.outcome);
            }
            try std.testing.expect(!source.input_continuation_cancelled);
            try std.testing.expect(source.input_continuation_failure == null);
            fake_core.expected_run_text = "new first message\n\nnew second message";
            if (next == .accepted_then_stop) try scenario.control.cancel(scenario.task_id, source.id);
        }
        fake_core.releaseControlled();
        try settleInputScenario(scenario);
        try std.testing.expectEqual(@as(usize, if (next == .accepted) 2 else 1), fake_core.run_calls);
        try std.testing.expectEqual(.unadopted, source.additional_inputs[0].?.state);
        try std.testing.expect(source.additional_inputs[0].?.transferred_to_run_id == null);
        try std.testing.expectEqual(@as(usize, 0), scenario.control.task_runtime.pending_input_bytes);
        if (next == .accepted) {
            try std.testing.expect(fake_core.run_text_matches);
            for (source.additional_inputs[1..3]) |entry| {
                try std.testing.expectEqual(.transferred, entry.?.state);
                try std.testing.expectEqual(@as(?u64, task.durable.runs[1].?.id), entry.?.transferred_to_run_id);
            }
        }
        var snapshot_storage: [512 * 1024]u8 = undefined;
        const snapshot = try scenario.control.writeAggregateFixture(&snapshot_storage);
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, snapshot, .{});
        defer parsed.deinit();
        const inputs = parsed.value.object.get("tasks").?.array.items[0].object.get("runs").?.array.items[0].object.get("additionalInputs").?.array.items;
        try std.testing.expectEqualStrings("continuation_cancelled", inputs[0].object.get("continuationReason").?.string);
    }
}

test "active input accepted target remains transferred when Executor enqueue fails" {
    const scenario = try ReviewScenario.initForInput(.controlled);
    defer scenario.deinit();
    const task = scenario.control.task_runtime.find(scenario.task_id).?;
    const source = &task.durable.runs[0].?;
    _ = try scenario.control.testSendInput("enqueue", scenario.task_id, task.durable.binding_epoch, .{ .run = source.id }, .{ .text = "real failed target" });
    var lease = try task.runtime.worker_leases.acquire();
    defer if (lease.isActive()) lease.deinit();
    fake_core.releaseControlled();
    for (0..5000) |_| {
        try scenario.control.drainAgentEvents();
        if (source.input_continuation_pending) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expect(source.input_continuation_pending);
    scenario.control.executor.shutdown();
    lease.deinit();
    try settleInputScenario(scenario);
    const target = &task.durable.runs[1].?;
    try std.testing.expect(task_state.productTerminalFacts(target) != null);
    try std.testing.expectEqual(.transferred, source.additional_inputs[0].?.state);
    try std.testing.expectEqual(@as(?u64, target.id), source.additional_inputs[0].?.transferred_to_run_id);
    try std.testing.expect(source.input_continuation_failure == null);
    try scenario.control.cancel(scenario.task_id, source.id);
    for (0..5) |_| scenario.control.syncLifecycle();
    try std.testing.expectEqual(.transferred, source.additional_inputs[0].?.state);
    try std.testing.expectEqual(@as(usize, 0), scenario.control.task_runtime.pending_input_bytes);
    try std.testing.expectEqual(@as(usize, 1), fake_core.run_calls);
}

test "active input ordinary continuation ignores unrelated Schedule persistence failure" {
    const scenario = try ReviewScenario.initForInput(.controlled);
    defer scenario.deinit();
    const task = scenario.control.task_runtime.find(scenario.task_id).?;
    _ = try scenario.control.testSendInput("unrelated-schedule", scenario.task_id, task.durable.binding_epoch, .{ .run = task.runtime.active_run_id }, .{ .text = "continue ordinary input" });
    scenario.control.schedule.persistence_health = .write_failed;
    fake_core.releaseControlled();
    try settleInputScenario(scenario);
    try std.testing.expectEqual(.transferred, task.durable.runs[0].?.additional_inputs[0].?.state);
    try std.testing.expectEqual(@as(usize, 2), fake_core.run_calls);
}

test "active input checkpoint export failure ends continuation without retry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);
    var store = try product_task.checkpoint_store.FileStore.init(std.testing.io, home);
    defer store.deinit();
    var history: TaskPersistenceProbe = .{};
    var configuration = productControlConfiguration();
    configuration.task_persistence = history.capability();
    configuration.checkpoint_store = .{ .file_store = &store };
    const scenario = try ReviewScenario.initConfigured(configuration, 2, .controlled, true);
    defer scenario.deinit();
    const task = scenario.control.task_runtime.find(scenario.task_id).?;
    const source = &task.durable.runs[0].?;
    _ = try scenario.control.testSendInput("checkpoint-failure", scenario.task_id, task.durable.binding_epoch, .{ .run = source.id }, .{ .text = "do not lose the boundary" });
    fake_core.forceNextCheckpointExportStatus(wire.STATUS_RESOURCE_LIMIT);
    fake_core.releaseControlled();
    try settleInputScenario(scenario);
    try std.testing.expectEqual(.unadopted, source.additional_inputs[0].?.state);
    try std.testing.expectEqual(.checkpoint_failed, source.input_continuation_failure.?);
    try std.testing.expect(source.additional_inputs[0].?.raw_text == null);
    for (0..5) |_| scenario.control.syncLifecycle();
    try std.testing.expectEqual(@as(usize, 1), fake_core.run_calls);
    try std.testing.expectEqual(@as(usize, 0), scenario.control.task_runtime.pending_input_bytes);
}

test "Product view scopes exclude history from navigation and bound selected Run pages" {
    const scenario = try ReviewScenario.initConfigured(productControlConfiguration(), 2, .controlled, true);
    defer scenario.deinit();
    fake_core.releaseControlled();
    try waitControlSnapshot(&scenario.control, "\"terminal\":{\"outcome\":\"completed\"");
    _ = try runPreparedTask(&scenario.control, scenario.task_id, .{ .text = "second-page-only-input" });
    try waitTaskSnapshot(&scenario.control, "\"id\":\"2\",\"conversationCoverage\"", "\"phase\":\"completed\"");
    var storage: [512 * 1024]u8 = undefined;
    const index_bytes = try scenario.control.writeViewFixture(&storage, .{});
    var index = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, index_bytes, .{});
    defer index.deinit();
    try std.testing.expect(index.value.object.get("taskPage").? == .null);
    const summary = index.value.object.get("taskIndex").?.array.items[0].object;
    try std.testing.expect(!summary.contains("runs"));
    try std.testing.expect(!summary.contains("skillCatalog"));
    try std.testing.expect(std.mem.indexOf(u8, index_bytes, "second-page-only-input") == null);
    const page_bytes = try scenario.control.writeViewFixture(&storage, .{ .task_id = scenario.task_id, .run_limit = 1 });
    var page = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, page_bytes, .{});
    defer page.deinit();
    const task_page = page.value.object.get("taskPage").?.object;
    try std.testing.expectEqualStrings("2", task_page.get("nextBeforeRunId").?.string);
    const runs = task_page.get("task").?.object.get("runs").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), runs.len);
    try std.testing.expectEqualStrings("2", runs[0].object.get("id").?.string);
    const older_bytes = try scenario.control.writeViewFixture(&storage, .{ .task_id = scenario.task_id, .before_run_id = 2, .run_limit = 1 });
    var older = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, older_bytes, .{});
    defer older.deinit();
    const older_page = older.value.object.get("historyPage").?.object;
    try std.testing.expectEqualStrings("2", older.value.object.get("taskPage").?.object.get("task").?.object.get("runs").?.array.items[0].object.get("id").?.string);
    try std.testing.expect(older_page.get("nextBeforeRunId").? == .null);
    try std.testing.expectEqualStrings("1", older_page.get("runs").?.array.items[0].object.get("id").?.string);
    try std.testing.expectError(error.InvalidViewRequest, scenario.control.writeViewFixture(&storage, .{ .task_id = scenario.task_id, .before_run_id = 999 }));
}

test "ProductDelivery reads do not advance worker lifecycle" {
    const Read = enum { revision, snapshot, view, workspace_catalog, personal_catalog, task_catalog, workspace_epoch, workspace_kind, task_workspace, permission_profile, permission_interaction, binding_epoch, mcp_authority, workspace_projections, schedule_epoch };
    inline for (std.meta.tags(Read)) |read| {
        var history: TaskPersistenceProbe = .{};
        var configuration = productControlConfiguration();
        configuration.task_persistence = history.capability();
        const scenario = try ReviewScenario.initConfigured(configuration, 2, .controlled, true);
        defer scenario.deinit();
        const control = &scenario.control;
        const task = control.task_runtime.find(scenario.task_id).?;
        const run = &task.durable.runs[0].?;
        fake_core.releaseControlled();
        for (0..5000) |_| {
            if (run.terminal_publication.load(.acquire) == .published) break;
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        }
        try std.testing.expectEqual(.published, run.terminal_publication.load(.acquire));
        const before_revision = control.revision;
        const before_phase = task_state.runPhase(run);
        const before_commits = history.commits;
        var snapshot: [512 * 1024]u8 = undefined;
        var workspaces: [1]product_control.WorkspaceProjection = undefined;
        switch (read) {
            .revision => _ = control.currentRevision(),
            .snapshot => _ = try control.writeAggregateFixture(&snapshot),
            .view => _ = try control.writeViewFixture(&snapshot, .{ .task_id = task.durable.id, .search = true, .search_query = "bounded" }),
            .workspace_catalog => _ = try control.workspaceCatalog(task.durable.workspace_id),
            .personal_catalog => _ = control.skillCatalog(),
            .task_catalog => _ = try control.taskCatalog(task.durable.id),
            .workspace_epoch => _ = try control.workspaceEpoch(task.durable.workspace_id),
            .workspace_kind => _ = try control.workspaceKind(task.durable.workspace_id),
            .task_workspace => _ = try control.taskWorkspaceId(task.durable.id),
            .permission_profile => _ = try control.taskPermissionProfile(task.durable.id),
            .permission_interaction => _ = try control.taskPermissionInteraction(task.durable.id),
            .binding_epoch => _ = try control.taskBindingEpoch(task.durable.id),
            .mcp_authority => _ = try control.taskMcpAuthority(task.durable.id),
            .workspace_projections => _ = try control.copyWorkspaceProjections(&workspaces),
            .schedule_epoch => _ = control.scheduledTaskEpoch(0) catch 0,
        }
        try std.testing.expectEqual(before_revision, control.revision);
        try std.testing.expectEqual(before_phase, task_state.runPhase(run));
        try std.testing.expectEqual(before_commits, history.commits);
        if (read == .view) try std.testing.expect(control.encoded_views.get(.{ .kind = .searchIndex, .limit = 1, .search_query = "bounded" }) != null);
        // Worker completion advances without a Renderer once Application
        // consumes its wake through the explicit Product event boundary.
        try control.drainAgentEvents();
        try std.testing.expect(run.event_stream_finalized);
        try std.testing.expectEqual(.completed, task_state.runPhase(run));
        if (read == .view) {
            try std.testing.expect(control.encoded_views.get(.{ .kind = .searchIndex, .limit = 1, .search_query = "bounded" }) == null);
            const finalized = try control.writeViewFixture(&snapshot, .{ .task_id = task.durable.id, .search = true, .search_query = "bounded" });
            var decoded = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, finalized, .{});
            defer decoded.deinit();
            const hits = decoded.value.object.get("searchIndex").?.object.get("results").?.array.items;
            try std.testing.expect(hits.len > 0);
            try std.testing.expect(for (hits) |hit| {
                if (std.mem.eql(u8, hit.object.get("kind").?.string, "instruction")) break true;
            } else false);
        }
    }
}

test "Task message acceptance synchronously submits ready text without duplicating owned input" {
    const scenario = try ReviewScenario.initForInput(.controlled);
    defer scenario.deinit();
    fake_core.adopt_input_before_receipt = true;
    const task = scenario.control.task_runtime.find(scenario.task_id).?;
    const run_id = task.runtime.active_run_id;
    const accepted = try scenario.control.sendInput("accepted-ready", scenario.task_id, .{ .text = "new constraint fixture-secret" });
    try std.testing.expectEqual(.accepted, accepted.outcome);
    try std.testing.expect(accepted.reason == null);
    try std.testing.expectEqual(@as(usize, 0), task.input_submissions.items.len);
    const record = &task.durable.runs[0].?.additional_inputs[0].?;
    try std.testing.expectEqualStrings("accepted-ready", record.submission.?.operationId());
    try std.testing.expectEqualStrings("new constraint fixture-secret", record.raw_text.?);
    try std.testing.expectEqual(@as(usize, record.raw_text.?.len), scenario.control.task_runtime.pending_input_bytes);
    try std.testing.expect(std.mem.indexOf(u8, record.text, "fixture-secret") == null);
    try std.testing.expectEqual(@as(u64, run_id), task.runtime.active_run_id);
    var output: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    try scenario.control.writeSendInputResult(&writer, accepted);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\"outcome\":\"accepted\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "runId") == null);
    fake_core.releaseControlled();
    try settleInputScenario(scenario);
    try std.testing.expectEqual(@as(usize, 0), scenario.control.task_runtime.pending_input_bytes);
    try std.testing.expectEqual(@as(usize, 1), fake_core.run_calls);
}

test "Task message acceptance during title cleanup remains stoppable and preserves input after stop" {
    var configuration = productControlConfiguration();
    configuration.completion_factory = .{ .create_fn = fixture.createCompletion };
    const storage = try std.testing.allocator.alloc(u8, product_task.history.max_store_bytes);
    defer std.testing.allocator.free(storage);
    var history: TaskPersistenceProbe = .{ .storage = storage };
    configuration.task_persistence = history.capability();
    const scenario = try ReviewScenario.initConfigured(configuration, 2, .controlled, true);
    defer scenario.deinit();
    fake_core.setCompletionTitle("Generated task title");
    fake_core.controlNextCompletion();
    var title_released = false;
    defer if (!title_released) fake_core.releaseCompletion();
    fake_core.releaseControlled();
    var title_entered = false;
    for (0..5000) |_| {
        fake_core.lock();
        title_entered = fake_core.completion_entered;
        fake_core.unlock();
        if (title_entered) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expect(title_entered);
    try waitControlSnapshot(&scenario.control, "\"terminal\":{\"outcome\":\"completed\"");
    const task = scenario.control.task_runtime.find(scenario.task_id).?;
    try std.testing.expect(task.runtime.active_operation == .none);
    try std.testing.expect(task.runtime.worker_leases.hasLive());
    try std.testing.expect(task.durable.runs[0].?.execution != null);
    var result = try scenario.control.sendInput("during-title", scenario.task_id, .{ .text = "cancel this pending message" });
    try std.testing.expectEqual(.accepted, result.outcome);
    try std.testing.expectEqual(@as(usize, 1), task.input_submissions.items.len);
    try std.testing.expectEqual(.waiting, task.input_submissions.items[0].state);
    try std.testing.expectEqual(@as(usize, 1), fake_core.run_calls);
    try waitHistoryNeedle(&scenario.control, &history, "during-title");
    {
        const saved_bytes = try std.testing.allocator.dupe(u8, storage[0..history.len]);
        defer std.testing.allocator.free(saved_bytes);
        var restored_configuration = configuration;
        restored_configuration.task_persistence = history.capabilityRestored(saved_bytes);
        var restored = try product_control.Runtime.init(std.testing.allocator, std.testing.io, scenario.runtime, .{ .worker_count = 1, .queue_capacity = 1, .max_tasks = 1, .max_runs_per_task = 2, .max_tools_per_run = 1 }, restored_configuration);
        defer restored.deinit();
        const saved_task = restored.task_runtime.find(scenario.task_id).?;
        try std.testing.expectEqual(@as(usize, 1), saved_task.input_submissions.items.len);
        const record = saved_task.input_submissions.items[0];
        try std.testing.expectEqual(.interrupted, record.state);
        try std.testing.expect(record.payload == null and record.reason == null);
        try std.testing.expectEqualStrings("during-title", record.submission.operationId());
    }
    try scenario.control.stopTask(scenario.task_id);
    try std.testing.expectEqual(.cancelled, task.input_submissions.items[0].state);
    try std.testing.expect(task.input_submissions.items[0].payload == null);
    try waitHistoryNeedle(&scenario.control, &history, "\"state\":\"cancelled\"");
    try std.testing.expect(std.mem.indexOf(u8, storage[0..history.len], "continuation_cancelled") == null);
    result = try scenario.control.sendInput("after-stop", scenario.task_id, .{ .text = "preserve this new intent" });
    try std.testing.expectEqual(.accepted, result.outcome);
    try std.testing.expectEqual(.waiting, task.input_submissions.items[1].state);
    fake_core.expected_run_text = "preserve this new intent";
    fake_core.releaseCompletion();
    title_released = true;
    try settleInputScenario(scenario);
    for (0..5000) |_| {
        try scenario.control.drainAgentEvents();
        if (task.durable.runs[0].?.execution == null and task.durable.runs[1].?.execution == null) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    } else return error.RunExecutionNotReclaimed;
    try std.testing.expectEqual(@as(usize, 2), fake_core.run_calls);
    try std.testing.expect(fake_core.run_text_matches);
    try std.testing.expectEqualStrings("after-stop", task.durable.runs[1].?.submission.?.operationId());
    try std.testing.expectEqual(@as(usize, 1), task.input_submissions.items.len);
    try std.testing.expectEqual(.cancelled, task.input_submissions.items[0].state);
}

test "Task message acceptance after active stop survives the stopped terminal" {
    const scenario = try ReviewScenario.initForInput(.controlled);
    defer scenario.deinit();
    const task = scenario.control.task_runtime.find(scenario.task_id).?;
    // The first message is synchronously submitted. Stop cancels its
    // continuation, while the subsequent accepted message is a new intent.
    const first = try scenario.control.sendInput("before-active-stop", scenario.task_id, .{ .text = "old intent" });
    try std.testing.expectEqual(.accepted, first.outcome);
    try scenario.control.stopTask(scenario.task_id);
    const after = try scenario.control.sendInput("after-active-stop", scenario.task_id, .{ .text = "new intent after stop" });
    try std.testing.expectEqual(.accepted, after.outcome);
    fake_core.expected_run_text = "new intent after stop";
    fake_core.releaseControlled();
    try settleInputScenario(scenario);
    try std.testing.expectEqual(@as(usize, 2), fake_core.run_calls);
    try std.testing.expect(fake_core.run_text_matches);
    try std.testing.expectEqualStrings("after-active-stop", task.durable.runs[1].?.submission.?.operationId());
    try std.testing.expectEqual(@as(usize, 0), scenario.control.task_runtime.pending_input_bytes);
}

const ImageAdmissionProbe = struct {
    calls: usize = 0,
    released: usize = 0,
    available: bool = true,
    model: []const u8 = "image-a",
    secret: []const u8 = "run-image-secret-a",
    workspace_id: u64 = 0,
    workspace_epoch: u64 = 0,

    fn prepare(context: *anyopaque, authority: fixture.product_workspace.TaskAuthority) ?product_task.OwnedImageExecution {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.calls += 1;
        self.workspace_id = authority.id;
        self.workspace_epoch = authority.epoch;
        if (!self.available) return null;
        return .{
            .candidate = models_contract.OwnedImageCandidate.copy(std.testing.allocator, self.model, self.secret, 7) catch unreachable,
            .transport = .{ .perform_fn = imageHttp },
            .output = .{ .context = self, .commit_fn = output },
            .output_owner = self,
            .release_output_fn = release,
        };
    }
    fn release(context: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.released += 1;
    }
    fn imageHttp(_: ?*anyopaque, _: lifecycle.CompletionHttpRequest, _: *const lifecycle.CompletionCancellation, _: []u8) lifecycle.CompletionTransportError!lifecycle.CompletionTransportResponse {
        @panic("this Product lifecycle scenario must not execute image effects");
    }
    fn output(_: *anyopaque, _: []const u8, _: lifecycle.ImageGenerationFormat, _: *const lifecycle.ImageGenerationCancellation) lifecycle.ImageGenerationOutputResult {
        @panic("this Product lifecycle scenario must not execute image effects");
    }
};

test "image permission review carries Host cost facts without trusting a same-named tool" {
    const cases = .{
        .{ "host", "GenerateImage", true },
        .{ "builtin", "GenerateImage", false },
        .{ "mcp", "GenerateImage", false },
        .{ "host", "OtherTool", false },
    };
    inline for (cases) |case| {
        fake_core.reset();
        fake_core.setNextPlan(.ui_wait);
        fake_core.permission_tool_namespace = case[0];
        fake_core.permission_tool_name = case[1];
        fake_core.permission_session_choices = false;
        fake_core.permission_arguments_json = "{\"prompt\":\"draw run-image-secret-a\"}";
        const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
        defer {
            shutdownTestComposition(runtime) catch unreachable;
            deinitTestComposition(runtime);
        }
        var control = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, .{ .worker_count = 1, .queue_capacity = 1, .max_tasks = 1, .max_runs_per_task = 1, .max_tools_per_run = 1 }, productControlConfiguration());
        defer control.deinit();
        try installControlExecution(&control);
        var image: ImageAdmissionProbe = .{};
        control.setImageRunPreparation(.{ .context = &image, .prepare_fn = ImageAdmissionProbe.prepare });
        var input = productControlTaskInput();
        input.approval_mode = .manual;
        const task_id = try control.createTask(input, try product_control.TestSupport.fixtureModelSelection(&control));
        _ = try runPreparedTask(&control, task_id, .{ .text = "Draw without exposing run-image-secret-a or fixture-secret" });
        try waitControlSnapshot(&control, "\"currentRunPhase\":\"waiting_ui\"");
        _ = try control.task_runtime.testSetPermissionReviewDelegation(task_id, true);
        var prepared = (try control.task_runtime.preparePermissionReview(task_id, product_control.TestSupport.taskPermissionReviewText(&control))).?;
        defer prepared.deinit();
        try std.testing.expectEqualStrings(case[1], prepared.input.request.tool_name);
        try std.testing.expectEqual(case[2], std.mem.indexOf(u8, prepared.input.host.constraints, "may be charged") != null);
        try std.testing.expectEqual(case[2], std.mem.indexOf(u8, prepared.input.host.constraints, "do not automatically retry") != null);
        try std.testing.expect(std.mem.indexOf(u8, prepared.input.host.constraints, "Never create Session grants") != null);
        try std.testing.expect(std.mem.indexOf(u8, prepared.input.request.arguments_json, image.secret) == null);
        try std.testing.expect(std.mem.indexOf(u8, prepared.input.user_intent, image.secret) == null);
        try std.testing.expect(std.mem.indexOf(u8, prepared.input.user_intent, "fixture-secret") == null);
        try std.testing.expectEqual(@as(usize, 1), image.calls);
    }
}

test "image Run admission freezes per-Run input and retains scrub ownership through terminal event drain" {
    const scenario = try ReviewScenario.initConfigured(productControlConfiguration(), 4, .controlled, true);
    defer scenario.deinit();
    fake_core.releaseControlled();
    try settleInputScenario(scenario);
    var image: ImageAdmissionProbe = .{};
    scenario.control.setImageRunPreparation(.{ .context = &image, .prepare_fn = ImageAdmissionProbe.prepare });
    defer scenario.control.setImageRunPreparation(null);
    fake_core.rearmControlled();
    const id = try runPreparedTask(&scenario.control, scenario.task_id, .{ .text = "use run-image-secret-a safely" });
    try waitControlSnapshot(&scenario.control, "\"inputReady\":true");
    const task = scenario.control.task_runtime.find(scenario.task_id).?;
    const run = &task.durable.runs[1].?;
    try std.testing.expectEqual(@as(usize, 1), image.calls);
    try std.testing.expectEqual(task.durable.workspace_id, image.workspace_id);
    try std.testing.expectEqual(task.durable.workspace_epoch, image.workspace_epoch);
    try std.testing.expectEqualStrings("use *** safely", run.input.text.value);
    try std.testing.expect(run.input.text.redacted);
    try std.testing.expectEqualStrings("image-a", run.image_execution.?.input().binding.model);
    image.secret = "run-image-secret-b";
    image.model = "image-b";
    image.available = false;
    try std.testing.expectEqualStrings("run-image-secret-a", run.image_execution.?.input().binding.credential);
    try std.testing.expect(scenario.control.task_runtime.containsExecutionCredential("run-image-secret-a"));
    try std.testing.expectEqual(@as(usize, "run-image-secret-a".len), scenario.control.task_runtime.matchedExecutionCredentialPrefix("run-image-secret-a suffix"));
    try std.testing.expect(scenario.control.task_runtime.executionCredentialMayContinue("run-image-"));
    fake_core.releaseControlled();
    // Do not drain Agent events: worker completion alone must not erase the
    // credential needed to sanitize canonical events still in the pump.
    for (0..5000) |_| {
        scenario.control.syncLifecycle();
        if (!task.runtime.worker_leases.hasLive()) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expect(!task.runtime.worker_leases.hasLive());
    try std.testing.expectEqual(@as(usize, 0), image.released);
    try std.testing.expect(run.image_execution != null);
    var event = try fixture.pumpEnvelope(scenario.task_id, id, "{\"text_chunk\":\"run-image-secret-a\"}");
    defer event.deinit();
    try scenario.control.applyEvent(&event);
    for ([_][]const u8{ run.assistant.list.items, run.output_segment.list.items, run.output_continued.list.items }) |bytes|
        try std.testing.expect(std.mem.indexOf(u8, bytes, "run-image-secret-a") == null);
    try settleInputScenario(scenario);
    try std.testing.expect(run.image_execution == null);
    try std.testing.expectEqual(@as(usize, 1), image.released);
    try std.testing.expect(!scenario.control.task_runtime.containsExecutionCredential("run-image-secret-a"));
    var snapshot: [128 * 1024]u8 = undefined;
    const encoded = try scenario.control.writeAggregateFixture(&snapshot);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "run-image-secret-a") == null);
    fake_core.rearmControlled();
    _ = try runPreparedTask(&scenario.control, scenario.task_id, .{ .text = "text remains available" });
    try waitControlSnapshot(&scenario.control, "\"inputReady\":true");
    try std.testing.expectEqual(@as(usize, 2), image.calls);
    try std.testing.expect(task.durable.runs[2].?.image_execution == null);
    fake_core.releaseControlled();
    try settleInputScenario(scenario);
    try std.testing.expectEqual(@as(usize, 1), image.released);
    try std.testing.expect(fake_core.image_tool_seen);
}

test "image Run follow-up resolves the next configuration and admission rollback releases its owner" {
    const scenario = try ReviewScenario.initConfigured(productControlConfiguration(), 4, .controlled, true);
    defer scenario.deinit();
    fake_core.releaseControlled();
    try settleInputScenario(scenario);
    var image: ImageAdmissionProbe = .{};
    scenario.control.setImageRunPreparation(.{ .context = &image, .prepare_fn = ImageAdmissionProbe.prepare });
    defer scenario.control.setImageRunPreparation(null);
    try std.testing.expectError(error.InvalidRunInput, scenario.control.runTask(scenario.task_id, .{ .text = "\xff" }));
    try std.testing.expectEqual(@as(usize, 1), image.calls);
    try std.testing.expectEqual(@as(usize, 1), image.released);
    const task = scenario.control.task_runtime.find(scenario.task_id).?;
    try std.testing.expect(task.durable.runs[1] == null);
    fake_core.rearmControlled();
    _ = try runPreparedTask(&scenario.control, scenario.task_id, .{ .text = "source for follow-up" });
    try waitControlSnapshot(&scenario.control, "\"inputReady\":true");
    const sent = try scenario.control.sendInput("image-follow-up", scenario.task_id, .{ .text = "new instruction run-image-secret-a" });
    try std.testing.expectEqual(.accepted, sent.outcome);
    try std.testing.expect(std.mem.indexOf(u8, task.durable.runs[1].?.additional_inputs[0].?.text, "run-image-secret-a") == null);
    image.available = false;
    fake_core.releaseControlled();
    try settleInputScenario(scenario);
    try std.testing.expectEqual(@as(usize, 3), image.calls);
    try std.testing.expectEqual(@as(usize, 2), image.released);
    try std.testing.expect(task.durable.runs[1].?.image_execution == null);
    try std.testing.expect(task.durable.runs[2].?.image_execution == null);
    try std.testing.expectEqual(@as(?u64, task.durable.runs[2].?.id), task.durable.runs[1].?.additional_inputs[0].?.transferred_to_run_id);
    try std.testing.expect(fake_core.image_tool_seen);
}

test "image Run duplicate bearer ownership does not revoke the Renderer on admission completion or rejection" {
    for ([_]bool{ false, true }) |account_owned| {
        const scenario = try ReviewScenario.initConfigured(productControlConfiguration(), 4, .controlled, true);
        defer scenario.deinit();
        fake_core.releaseControlled();
        try settleInputScenario(scenario);
        const Account = struct {
            fn generation(_: *anyopaque) u64 {
                return 1;
            }
            fn visit(_: *anyopaque, context: *anyopaque, callback: *const fn (*anyopaque, []const u8) std.mem.Allocator.Error!void) std.mem.Allocator.Error!void {
                try callback(context, "account-image-token");
            }
        };
        var image: ImageAdmissionProbe = .{ .secret = if (account_owned) "account-image-token" else "fixture-secret" };
        if (account_owned) scenario.control.setAccountProjectionCredentials(.{ .context = &image, .generation_fn = Account.generation, .visit_fn = Account.visit });
        scenario.control.setImageRunPreparation(.{ .context = &image, .prepare_fn = ImageAdmissionProbe.prepare });
        defer scenario.control.setImageRunPreparation(null);
        const epoch = scenario.control.projectionSecurityEpoch();
        for (0..2) |index| {
            fake_core.rearmControlled();
            _ = try runPreparedTask(&scenario.control, scenario.task_id, .{ .text = "ordinary message with image capability" });
            try waitControlSnapshot(&scenario.control, "\"inputReady\":true");
            try std.testing.expectEqual(epoch, scenario.control.projectionSecurityEpoch());
            fake_core.releaseControlled();
            try settleInputScenario(scenario);
            // Product terminal may precede the last worker lease (for example the
            // automatic title). Observe the actual image-owner release boundary.
            for (0..5000) |_| {
                try scenario.control.drainAgentEvents();
                if (image.released == index + 1) break;
                try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
            }
            try std.testing.expectEqual(index + 1, image.released);
            try std.testing.expectEqual(epoch, scenario.control.projectionSecurityEpoch());
        }
        try std.testing.expectEqual(@as(usize, 2), image.released);
        try std.testing.expectError(error.InvalidRunInput, scenario.control.runTask(scenario.task_id, .{ .text = "\xff" }));
        try std.testing.expectEqual(epoch, scenario.control.projectionSecurityEpoch());
        image.secret = "new-image-bearer";
        try std.testing.expectError(error.InvalidRunInput, scenario.control.runTask(scenario.task_id, .{ .text = "\xff" }));
        try std.testing.expectEqual(epoch + 1, scenario.control.projectionSecurityEpoch());
    }
}

test "built-in source replacement keeps canonical Task catalog pinned until explicit idle refresh" {
    const Source = struct {
        references: std.atomic.Value(usize) = .init(1),
        fn retain(context: *anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            _ = self.references.fetchAdd(1, .monotonic);
            return true;
        }
        fn release(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            std.debug.assert(self.references.fetchSub(1, .acq_rel) > 1);
        }
        fn lifetime(self: *@This()) lifecycle.CatalogSourceLifetime {
            return .{ .context = self, .retain_fn = retain, .release_fn = release };
        }
    };
    fake_core.reset();
    var first: Source = .{};
    var second: Source = .{};
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const home = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);
    try temporary.dir.createDirPath(std.testing.io, "office-a");
    try temporary.dir.createDirPath(std.testing.io, "office-b");
    const root_a = try temporary.dir.realPathFileAlloc(std.testing.io, "office-a", std.testing.allocator);
    defer std.testing.allocator.free(root_a);
    const root_b = try temporary.dir.realPathFileAlloc(std.testing.io, "office-b", std.testing.allocator);
    defer std.testing.allocator.free(root_b);
    var enablement_store = try product_skill.enablement.FileStore.init(std.testing.io, home);
    defer enablement_store.deinit();
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 2, .max_sessions = 1 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var workbench = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, .{
        .worker_count = 1,
        .queue_capacity = 2,
        .max_workspaces = 1,
        .max_tasks = 1,
        .max_runs_per_task = 1,
        .max_tools_per_run = 1,
    }, .{
        .directories = .{ .canonical_user_home = home },
        .skill_enablement = .{ .file_store = &enablement_store },
        .skill_sources = .{ .restored = .{ .loaded = .{ .ready = .{} } } },
    });
    defer workbench.deinit();
    try installControlExecution(&workbench);
    try std.testing.expect(try workbench.replaceBuiltinSkillSource(.{ .root = root_a, .lifetime = first.lifetime() }));
    var input = productControlTaskInput();
    input.workspace_root = home;
    input.trust = .explicitly_trusted;
    const workspace = try workbench.openWorkspace(input);
    const catalog = try waitCatalogReady(&workbench, workspace);
    const task = try workbench.createTaskInWorkspace(workspace, try workbench.workspaceEpoch(workspace), try product_control.TestSupport.fixtureModelSelection(&workbench), catalog.revision, catalog.selection_revision, .{ .interactive = null });
    try settleWorkspaceSkillQueries(&workbench, workspace);
    try std.testing.expect(try workbench.replaceBuiltinSkillSource(.{ .root = root_b, .lifetime = second.lifetime() }));
    try settleWorkspaceSkillQueries(&workbench, workspace);
    // Both scope catalogs have switched. The original Session alone still
    // retains its original Core catalog and therefore the first source lifetime.
    try std.testing.expect(first.references.load(.acquire) > 1);
    try std.testing.expect(second.references.load(.acquire) > 1);
    try workbench.refreshTaskCatalog(task, try workbench.taskBindingEpoch(task));
    try std.testing.expectEqual(@as(usize, 1), first.references.load(.acquire));
    try std.testing.expect(second.references.load(.acquire) > 1);
    try std.testing.expectEqual(@as(usize, 1), (try workbench.taskCatalog(task)).skills.len);
}

const DeliveryAdmissionProbe = struct {
    calls: usize = 0,
    released: usize = 0,
    workspace_id: u64 = 0,
    workspace_epoch: u64 = 0,
    fn prepare(context: *anyopaque, authority: fixture.product_workspace.TaskAuthority) ?product_task.OwnedFileDelivery {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.calls += 1;
        self.workspace_id = authority.id;
        self.workspace_epoch = authority.epoch;
        return .{ .input = .{ .context = self, .inspect_fn = inspect }, .release_fn = release };
    }
    fn inspect(_: *anyopaque, _: []const u8, _: *const std.atomic.Value(bool)) lifecycle.FileDeliveryInspection {
        @panic("this admission lifecycle case must not read files");
    }
    fn release(context: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.released += 1;
    }
};

test "file delivery Run authority survives preparation changes until worker and event drain quiesce" {
    const scenario = try ReviewScenario.initConfigured(productControlConfiguration(), 4, .controlled, true);
    defer scenario.deinit();
    fake_core.releaseControlled();
    try settleInputScenario(scenario);
    var probe: DeliveryAdmissionProbe = .{};
    scenario.control.setFileDeliveryPreparation(.{ .context = &probe, .prepare_fn = DeliveryAdmissionProbe.prepare });
    defer scenario.control.setFileDeliveryPreparation(null);
    fake_core.rearmControlled();
    _ = try runPreparedTask(&scenario.control, scenario.task_id, .{ .text = "explicit file delivery" });
    try waitControlSnapshot(&scenario.control, "\"inputReady\":true");
    const task = scenario.control.task_runtime.find(scenario.task_id).?;
    const run = &task.durable.runs[1].?;
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(task.durable.workspace_id, probe.workspace_id);
    try std.testing.expectEqual(task.durable.workspace_epoch, probe.workspace_epoch);
    scenario.control.setFileDeliveryPreparation(null);
    try std.testing.expectEqual(@as(*anyopaque, &probe), run.file_delivery.?.input.context);
    fake_core.releaseControlled();
    for (0..5000) |_| {
        scenario.control.syncLifecycle();
        if (!task.runtime.worker_leases.hasLive()) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expect(!task.runtime.worker_leases.hasLive());
    try std.testing.expectEqual(@as(usize, 0), probe.released);
    try std.testing.expect(run.file_delivery != null);
    try settleInputScenario(scenario);
    try std.testing.expect(run.file_delivery == null);
    try std.testing.expectEqual(@as(usize, 1), probe.released);
}

test "MCP apply barrier never releases an unrelated idle Session as capacity recovery" {
    fake_core.reset();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);
    var checkpoints = try product_task.checkpoint_store.FileStore.init(std.testing.io, home);
    defer checkpoints.deinit();
    var history: TaskPersistenceProbe = .{};
    var configuration = productControlConfiguration();
    configuration.directories.canonical_user_home = home;
    configuration.task_persistence = history.capability();
    configuration.checkpoint_store = .{ .file_store = &checkpoints };
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 2, .max_sessions = 1 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var control = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, .{
        .worker_count = 1,
        .queue_capacity = 2,
        .max_tasks = 2,
        .max_workspaces = 1,
    }, configuration);
    defer control.deinit();
    try installControlExecution(&control);
    var input = productControlTaskInput();
    input.workspace_root = home;
    input.trust = .explicitly_trusted;
    const waiter_id = try control.createTask(input, try product_control.TestSupport.fixtureModelSelection(&control));
    const waiter = control.task_runtime.find(waiter_id).?;
    try std.testing.expect(try product_control.TestSupport.retryTaskSessionClose(&control, waiter_id));
    for (0..5000) |_| {
        control.syncLifecycle();
        if (waiter.runtime.attachment == .detached and waiter.runtime.close_thread == null) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    } else return error.TestUnexpectedResult;
    const other_id = try control.createTask(input, try product_control.TestSupport.fixtureModelSelection(&control));
    const other = control.task_runtime.find(other_id).?;
    const destroyed = fake_core.session_destroyed;
    runtime.mcp_operation.phase = .apply;
    defer {
        runtime.mcp_operation.phase = .idle;
    }
    try std.testing.expectError(error.RecoveryUnavailable, control.restoreTaskConversation(waiter_id, waiter.durable.binding_epoch));
    try std.testing.expect(other.runtime.hasAttachedSession());
    try std.testing.expect(other.runtime.close_thread == null);
    try std.testing.expect(!other.runtime.close_requested);
    try std.testing.expectEqual(destroyed, fake_core.session_destroyed);
}

test "Session pressure never cancels busy work or automatically retries a failed close" {
    fake_core.reset();
    fake_core.setCheckpointGeneration(1);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);
    var checkpoints = try product_task.checkpoint_store.FileStore.init(std.testing.io, home);
    defer checkpoints.deinit();
    const storage = try std.testing.allocator.alloc(u8, product_task.history.max_store_bytes);
    defer std.testing.allocator.free(storage);
    var history = TaskPersistenceProbe{ .storage = storage };
    var configuration = productControlConfiguration();
    configuration.directories.canonical_user_home = home;
    configuration.task_persistence = history.capability();
    configuration.checkpoint_store = .{ .file_store = &checkpoints };
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 2, .max_sessions = 1 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var control = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, .{ .worker_count = 1, .queue_capacity = 2, .max_tasks = 3, .max_workspaces = 1, .max_runs_per_task = 2 }, configuration);
    defer control.deinit();
    defer fake_core.releaseControlled();
    try installControlExecution(&control);
    var input = productControlTaskInput();
    input.workspace_root = home;
    input.trust = .explicitly_trusted;
    input.approval_mode = .manual;
    fake_core.setNextPlan(.controlled);
    const id = try control.createTask(input, try product_control.TestSupport.fixtureModelSelection(&control));
    try waitInitialTaskCatalog(&control, id);
    const run_id = try runPreparedTask(&control, id, .{ .text = "Keep this accepted work running." });
    try waitControlSnapshot(&control, "\"currentRunPhase\":\"running\"");
    const task = control.task_runtime.find(id).?;
    try std.testing.expectError(error.SessionCapacity, control.createTask(input, try product_control.TestSupport.fixtureModelSelection(&control)));
    try std.testing.expect(task.runtime.hasAttachedSession());
    try std.testing.expect(!task.runtime.cancel_requested);
    try std.testing.expectEqual(run_id, task.runtime.active_operation.run);
    fake_core.releaseControlled();
    try waitCheckpointRecord(&control, &history);
    for (0..5000) |_| {
        control.syncLifecycle();
        if (task.durable.runs[0].?.execution == null) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    } else return error.TestUnexpectedResult;
    // Terminal work still cannot be released while an artifact or continuation owns it.
    task.durable.runs[0].?.pending_file_change_artifacts = 1;
    try std.testing.expectError(error.SessionCapacity, control.createTask(input, try product_control.TestSupport.fixtureModelSelection(&control)));
    try std.testing.expect(task.runtime.hasAttachedSession());
    task.durable.runs[0].?.pending_file_change_artifacts = 0;
    task.durable.runs[0].?.input_continuation_pending = true;
    try std.testing.expect(control.task_runtime.idleReleaseRouteId(null) == null);
    task.durable.runs[0].?.input_continuation_pending = false;
    fake_core.forceNextSessionDestroyStatus(wire.STATUS_CORE_ERROR);
    try std.testing.expectError(error.SessionReleasing, control.createTask(input, try product_control.TestSupport.fixtureModelSelection(&control)));
    for (0..5000) |_| {
        control.syncLifecycle();
        if (task.runtime.close_failed) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    } else return error.TestUnexpectedResult;
    try std.testing.expect(task.runtime.hasClosingSession());
    try std.testing.expect(task.runtime.parked_capabilities != null);
    try std.testing.expectEqual(id, control.sessionReleaseFailureTaskId().?);
    const destroyed = fake_core.session_destroyed;
    for (0..8) |_| {
        try std.testing.expectError(error.SessionReleaseFailed, control.createTask(input, try product_control.TestSupport.fixtureModelSelection(&control)));
        control.syncLifecycle();
    }
    try std.testing.expectEqual(destroyed, fake_core.session_destroyed);
    try std.testing.expect(task.runtime.close_thread == null);
    try std.testing.expect(try product_control.TestSupport.retryTaskSessionClose(&control, id));
    for (0..5000) |_| {
        control.syncLifecycle();
        if (task.runtime.attachment == .detached) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    } else return error.TestUnexpectedResult;
    fake_core.setNextPlan(.controlled);
    const second = try control.createTask(input, try product_control.TestSupport.fixtureModelSelection(&control));
    try waitInitialTaskCatalog(&control, second);
    _ = try runPreparedTask(&control, second, .{ .text = "Occupy the only live Session." });
    try waitControlSnapshot(&control, "\"currentRunPhase\":\"running\"");
    try std.testing.expectEqual(.accepted, (try control.sendInput("busy-capacity", id, .{ .text = "Keep the unavailable draft." })).outcome);
    try std.testing.expectEqual(.session_capacity, task.input_submissions.items[0].reason.?);
    try std.testing.expect(task.input_submissions.items[0].blocking_task_id == null);
    fake_core.releaseControlled();
    const other = control.task_runtime.find(second).?;
    for (0..5000) |_| {
        try control.drainAgentEvents();
        control.syncLifecycle();
        if (other.durable.runs[0].?.execution == null) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    } else return error.TestUnexpectedResult;
    fake_core.forceNextSessionDestroyStatus(wire.STATUS_CORE_ERROR);
    try std.testing.expectEqual(.accepted, (try control.sendInput("start-release", id, .{ .text = "Try releasing capacity." })).outcome);
    try std.testing.expectEqual(.session_releasing, task.input_submissions.items[1].reason.?);
    for (0..5000) |_| {
        control.syncLifecycle();
        if (other.runtime.close_failed) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    } else return error.TestUnexpectedResult;
    try std.testing.expectEqual(.accepted, (try control.sendInput("failed-release", id, .{ .text = "Keep the blocked draft." })).outcome);
    const failed = task.input_submissions.items[2];
    try std.testing.expectEqual(.failed, failed.state);
    try std.testing.expectEqual(.session_close_failed, failed.reason.?);
    try std.testing.expectEqual(second, failed.blocking_task_id.?);
    try std.testing.expect(failed.payload == null);
    try std.testing.expectEqual(run_id, task.durable.runs[0].?.id);
    try std.testing.expect(task.durable.runs[1] == null);
}

test "waiting ordinary attachment messages exhaust stock before payload and Stop restores it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buffer);
    var store = try product_control.AttachmentFileStore.init(std.testing.io, std.testing.allocator, path_buffer[0..path_len]);
    defer store.deinit();
    var configuration = productControlConfiguration();
    configuration.attachment_store = &store;
    // A real Product Task and Core permission wait keep multimodal messages
    // waiting without inventing a second queue or altering execution admission.
    const scenario = try ReviewScenario.initWithConfiguration(configuration);
    defer scenario.deinit();
    const task = scenario.control.task_runtime.find(scenario.task_id).?;
    const count = product_control.attachment_record_capacity / 2;
    for (0..count) |index| {
        var descriptors: [2]product_control.AttachmentDescriptor = undefined;
        const ready = try scenario.control.stageAttachments(&.{ .{ .display_name = "a.pdf", .bytes = "x" }, .{ .display_name = "b.pdf", .bytes = "y" } }, &descriptors);
        const ids = [_]u64{ ready[0].id, ready[1].id };
        var operation: [64]u8 = undefined;
        const operation_id = try std.fmt.bufPrint(&operation, "queued-files-{d}", .{index});
        const result = try scenario.control.sendInput(operation_id, scenario.task_id, .{ .multimodal = .{ .text = "Inspect later", .attachment_ids = &ids } });
        try std.testing.expectEqual(.accepted, result.outcome);
        try std.testing.expectEqual(.waiting, task.input_submissions.items[index].state);
    }
    try std.testing.expectEqual(count, task.input_submissions.items.len);
    try std.testing.expect(scenario.control.task_runtime.pending_input_bytes < lifecycle.max_submitted_input_bytes);
    try std.testing.expectEqual(product_control.attachment_record_capacity, scenario.control.attachments.used_bytes);
    var output: [1]product_control.AttachmentDescriptor = undefined;
    try std.testing.expectError(error.StagingCapacity, scenario.control.stageAttachments(&.{.{ .display_name = "draft.txt", .bytes = "z" }}, &output));
    try scenario.control.stopTask(scenario.task_id);
    try std.testing.expectEqual(@as(usize, 0), scenario.control.task_runtime.pending_input_bytes);
    try std.testing.expectEqual(@as(usize, 0), scenario.control.attachments.used_bytes);
    for (task.input_submissions.items) |record| try std.testing.expectEqual(.cancelled, record.state);
    const ready = try scenario.control.stageAttachments(&.{.{ .display_name = "draft.txt", .bytes = "z" }}, &output);
    try std.testing.expect(try scenario.control.releaseAttachmentChecked(ready[0].id));
}
