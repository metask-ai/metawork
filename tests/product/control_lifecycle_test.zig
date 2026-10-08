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
        fake_core.reset();
        fake_core.setNextPlan(.ui_wait);
        const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
        errdefer {
            shutdownTestComposition(runtime) catch unreachable;
            deinitTestComposition(runtime);
        }
        const self = try std.testing.allocator.create(@This());
        errdefer std.testing.allocator.destroy(self);
        self.* = .{
            .runtime = runtime,
            .control = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, .{ .worker_count = 1, .queue_capacity = 1, .max_tasks = 1, .max_runs_per_task = 2, .max_tools_per_run = 1 }, productControlConfiguration()),
            .task_id = 0,
        };
        errdefer self.control.deinit();
        try installControlExecution(&self.control);
        var input = productControlTaskInput();
        input.approval_mode = .manual;
        self.task_id = try self.control.createTask(input);
        _ = try self.control.runTask(self.task_id, .{ .text = "Perform the bounded operation without disclosing fixture-secret" });
        try waitControlSnapshot(&self.control, "\"currentRunPhase\":\"waiting_ui\"");
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

test "approval modes remember the global choice while restoring original session facts" {
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
    try std.testing.expectEqual(.manual, control.defaultApprovalMode());
    var input = productControlTaskInput();
    input.approval_mode = .auto_review;
    const reviewed = try control.createTask(input);
    try std.testing.expectEqual(.auto_review, try control.taskApprovalMode(reviewed));
    try std.testing.expectEqual(.approval_required, try control.taskPermissionProfile(reviewed));
    const inherited = try control.createTask(productControlTaskInput());
    try std.testing.expectEqual(.auto_review, try control.taskApprovalMode(inherited));
    input.approval_mode = .full_access;
    const full = try control.createTask(input);
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
        const task_id = try control.createTask(input);
        const run_id = try control.runTask(task_id, .{ .text = "Inspect two local operations" });
        try waitControlSnapshot(&control, "\"pendingUi\":{\"requestId\":\"1\"");
        try control.respondUi(task_id, run_id, 1, .{ .permission = .allow_once });
        try waitControlSnapshot(&control, "\"pendingUi\":{\"requestId\":\"2\"");
        var snapshot: [64 * 1024]u8 = undefined;
        const json = try control.writeSnapshot(&snapshot);
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
        const task_id = try control.createTask(input);
        const run_id = try control.runTask(task_id, .{ .text = "Perform the bounded operation" });
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
    const task_id = try control.createTask(input);
    const run_id = try control.runTask(task_id, .{ .text = "Perform the bounded operation" });
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
        const task_id = try control.createTask(input);
        _ = try control.runTask(task_id, .{ .text = "Perform the bounded operation without disclosing fixture-secret" });
        try transport.awaitEntered(&control);
        try waitControlSnapshot(&control, "\"permissionReviewState\":\"reviewing\"");
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
            try std.testing.expectEqual(@as(usize, 0), control.task_runtime.find(task_id).?.durable.ui_history_count);
            for (0..5) |_| control.syncLifecycle();
        }
        try std.testing.expectEqual(@as(usize, 1), transport.calls.load(.acquire));
        try std.testing.expect(!transport.invalid.load(.acquire));
    }
}

test "Control permission reviewer scrubs decoded arguments and leaves opaque MCP requests manual" {
    for (0..2) |case| {
        fake_core.reset();
        fake_core.permission_arguments_json = "{\"api_key\":\"fixture\\u002dsecret\",\"nested\":[\"fixture-secret\"]}";
        fake_core.permission_tool_namespace = if (case == 0) "builtin" else "mcp";
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
        const task_id = try control.createTask(input);
        _ = try control.runTask(task_id, .{ .text = "Inspect the local operation" });
        if (case == 0) {
            try transport.awaitEntered(&control);
            try std.testing.expect(!transport.invalid.load(.acquire));
            transport.released.store(true, .release);
            try waitControlSnapshot(&control, "\"answeredBy\":\"reviewer\"");
        } else {
            try waitControlSnapshot(&control, "\"permissionReviewState\":\"needs_user\"");
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
        const task_id = try control.createTask(input);
        _ = try control.runTask(task_id, .{ .text = "Perform the bounded operation" });
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
        const task_id = try control.createTask(input);
        _ = try control.runTask(task_id, .{ .text = "Perform the bounded operation" });
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
        id.* = try control.createTask(input);
        _ = try control.runTask(id.*, .{ .text = "Perform the bounded operation" });
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
    _ = try control.runTask(ids[0], .{ .text = "A new bounded operation" });
    for (0..1000) |_| {
        control.syncLifecycle();
        if (first.runtime.permission_review.phase == .needs_user) break;
        std.Io.sleep(std.testing.io, .fromMilliseconds(2), .awake) catch return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(.needs_user, first.runtime.permission_review.phase);
    try std.testing.expectEqual(.needs_user, control.task_runtime.find(ids[8]).?.runtime.permission_review.phase);
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
    try std.testing.expect(runtime.finishPermissionReview(preparation.identity));
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
    for ([_]product_task.PermissionReviewOutcome{ .{ .failure = .timeout }, reviewSuggestion(.needs_user, "Evidence is missing.") }) |outcome| {
        const scenario = try ReviewScenario.init();
        defer scenario.deinit();
        var preparation = try scenario.prepare();
        defer preparation.deinit();
        var commit = ReviewCommit{};
        try std.testing.expect(!try scenario.control.task_runtime.acceptPermissionReview(preparation.identity, outcome, commit.effects(scenario)));
        try std.testing.expectEqual(@as(usize, 0), commit.calls);
        try std.testing.expect((try scenario.control.task_runtime.preparePermissionReview(scenario.task_id, scenario.text())) == null);
        const task = scenario.control.task_runtime.find(scenario.task_id).?;
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
            try std.testing.expect(scenario.control.task_runtime.finishPermissionReview(preparation.identity));
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
    result: product_task.history.Commit = .committed,
    store_on_outcome_unknown: bool = false,
    storage: ?[]u8 = null,
    len: usize = 0,
    commits: usize = 0,

    fn commit(context: ?*anyopaque, bytes: []const u8) product_task.history.Commit {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.commits += 1;
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
            .recover_fn = commit,
        };
    }

    fn capabilityRestored(
        self: *@This(),
        restored_bytes: []const u8,
    ) product_task.history.Capability {
        var result = self.capability();
        result.restored_bytes = restored_bytes;
        return result;
    }
};

// Observe both effect boundaries: a null projection alone cannot prove that
// an unauthorized root was never inspected or handed to AgentCore.
const WorkspaceSkillQueryProbe = struct {
    catalog: product_skill.ports.Catalog = undefined,
    root_checks: std.atomic.Value(usize) = .init(0),
    queries: std.atomic.Value(usize) = .init(0),

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
        if (input.target == .workspace) _ = self.queries.fetchAdd(1, .release);
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

fn expectWorkspaceSkillProjection(workbench: *product_control.Runtime, id: u64, present: bool) !void {
    var storage: [256 * 1024]u8 = undefined;
    const bytes = try workbench.writeSnapshot(&storage);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
    defer parsed.deinit();
    for (parsed.value.object.get("workspaces").?.array.items) |workspace| {
        if (try std.fmt.parseInt(u64, workspace.object.get("id").?.string, 10) != id) continue;
        try std.testing.expectEqual(present, workspace.object.get("skillSourceDiscovery").? != .null);
        const automatic = std.mem.eql(u8, "automatic", workspace.object.get("kind").?.string);
        if (automatic or !present) {
            const catalog = workspace.object.get("skillCatalog").?;
            try std.testing.expectEqualStrings(if (automatic) "uninitialized" else "unavailable", catalog.object.get("availability").?.string);
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

test "Skill source authorization excludes restored Manual roots until explicit reauthorization" {
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
        try std.testing.expectError(error.WorkspaceUnavailable, restored.refreshWorkspaceCatalog(workspace_id, try restored.workspaceEpoch(workspace_id)));
        const changed = if (recover_sources)
            restored.recoverSkillSourceSettings(.reread, restored.skill.sourceSettings().recovery_token.?)
        else
            restored.setSkillSourceEnabled(.claude, true, 1);
        try std.testing.expect(changed.applied);
        try expectWorkspaceSkillProjection(&restored, workspace_id, false);
        try settleWorkspaceSkillQueries(&restored, workspace_id);
        try probe.expectQueries(0);
        try std.testing.expectEqual(workspace_id, try restored.openWorkspace(input));
        try settleWorkspaceSkillQueries(&restored, workspace_id);
        try probe.expectQueries(1);
        try expectWorkspaceSkillProjection(&restored, workspace_id, true);
    }
}

test "Skill source authorization keeps new and restored Automatic snapshots catalog-free" {
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
                .skill_sources = .{ .file_store = &store, .restored = if (recover_sources) .read_failed else .{ .loaded = .{ .ready = .{} } } },
            });
            defer workbench.deinit();
            probe.attach(&workbench);
            try installControlExecution(&workbench);
            if (!restore_workspace) {
                task_id = try workbench.createTaskForWorkspace(.automatic, 1, workbench.newTaskAdmissionView().active_selection_revision, null, null, null, .{ .interactive = null });
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
            try probe.expectQueries(0);
            try std.testing.expectError(error.WorkspaceUnavailable, workbench.refreshWorkspaceCatalog(workspace_id, try workbench.workspaceEpoch(workspace_id)));
        }
    }
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
        const task_id = try workbench.createTaskInWorkspace(workspace_id, epoch, 1, workbench.newTaskAdmissionView().active_selection_revision, null, null, null, .{ .interactive = null });
        if (immediate_failure) {
            // Close admission succeeds, but Session close must not start until
            // the exporting checkpoint has settled and released its lease.
            fake_core.controlNextCheckpointExport();
            _ = try workbench.runTask(task_id, .{ .text = "hold checkpoint during removal" });
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
        try probe.expectQueries(2);
        try expectWorkspaceSkillProjection(&workbench, workspace_id, true);
        // The restored grant remains usable, rather than only displaying ready.
        try workbench.refreshWorkspaceCatalog(workspace_id, try workbench.workspaceEpoch(workspace_id));
        try settleWorkspaceSkillQueries(&workbench, workspace_id);
        try probe.expectQueries(3);
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
        .{ .id = "fixture-model", .display_name = "Fixture model" },
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
    expected_model: []const u8,
    expected_execution_generation: u64,
    target_model: []const u8,
) product_control.TaskModelSelectionInput {
    const models = workbench.modelsView();
    return .{
        .expected_model = expected_model,
        .expected_execution_generation = expected_execution_generation,
        .target = .{
            .source_id = models.metask_selection.?.source_id,
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
            .source_id = models.metask_selection.?.source_id,
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
    const admission = workbench.newTaskAdmissionView();
    var stale = newTaskModelSelectionInput(&workbench, "fixture-model-2");
    stale.expected_catalog_generation += 1;
    try std.testing.expectError(
        error.ModelSelectionChanged,
        workbench.createTaskInWorkspace(
            workspace_id,
            workspace_epoch,
            admission.active_generation,
            admission.active_selection_revision,
            stale,
            null,
            null,
            .{ .interactive = null },
        ),
    );
    var stale_source = newTaskModelSelectionInput(&workbench, "fixture-model-2");
    stale_source.expected_source_generation += 1;
    try std.testing.expectError(
        error.ModelSelectionChanged,
        workbench.createTaskInWorkspace(
            workspace_id,
            workspace_epoch,
            admission.active_generation,
            admission.active_selection_revision,
            stale_source,
            null,
            null,
            .{ .interactive = null },
        ),
    );
    try std.testing.expectError(
        error.ModelSelectionChanged,
        workbench.createTaskInWorkspace(
            workspace_id,
            workspace_epoch,
            admission.active_generation,
            admission.active_selection_revision,
            newTaskModelSelectionInput(&workbench, "missing-model"),
            null,
            null,
            .{ .interactive = null },
        ),
    );

    const task_id = try workbench.createTaskInWorkspace(
        workspace_id,
        workspace_epoch,
        admission.active_generation,
        admission.active_selection_revision,
        newTaskModelSelectionInput(&workbench, "fixture-model-2"),
        null,
        null,
        .{ .interactive = null },
    );
    const identity = try workbench.taskExecutionIdentity(task_id);
    try std.testing.expectEqualStrings("fixture-model-2", identity.model);
    try expectFakeSessionModel(0, "fixture-model-2");
    try std.testing.expectEqualStrings(
        "fixture-model",
        workbench.modelsView().default_selection.?.model_id,
    );
    try std.testing.expectEqualStrings(
        "fixture-model",
        workbench.newTaskAdmissionView().active_model_ref.?.model_id,
    );
}

fn waitCatalogReady(
    workbench: *product_control.Runtime,
    workspace_id: u64,
) !product_control.CatalogProjection {
    for (0..10_000) |_| {
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
        const snapshot = try workbench.writeSnapshot(&output);
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
        _ = try workbench.writeSnapshot(&output);
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
        _ = try workbench.writeSnapshot(&output);
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
    _ = try workbench.createTask(productControlTaskInput());

    try std.testing.expect(fake_core.builtin_allowlist_seen);
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

    const default_task = try workbench.createTask(productControlTaskInput());
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
    const explicit_full_access = try workbench.createTask(full_access_input);
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
    const inherited_full_access = try workbench.createTask(productControlTaskInput());
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
    const explicit_task = try workbench.createTask(explicit_input);
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
    const degraded_task = try workbench.createTask(rejected_input);
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
        error.TaskCapacity,
        workbench.createTask(capacity_rejected_input),
    );
    try std.testing.expectEqual(
        product_control.PermissionProfile.full_access,
        workbench.defaultPermissionProfile(),
    );
}

test "full-access successor clones exact Manual Task execution without conversation authority" {
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
            .max_workspaces = 2,
            .max_runs_per_task = 2,
            .max_tools_per_run = 1,
        },
        configuration,
    );
    defer workbench.deinit();
    try installControlExecution(&workbench);

    const workspace_id = try workbench.openWorkspace(productControlTaskInput());
    const admission = workbench.newTaskAdmissionView();
    const source_task_id = try workbench.createTaskInWorkspace(
        workspace_id,
        try workbench.workspaceEpoch(workspace_id),
        admission.active_generation,
        admission.active_selection_revision,
        null,
        null,
        null,
        .{ .interactive = .manual },
    );
    const source_binding_epoch = try workbench.taskBindingEpoch(source_task_id);
    const source_execution = try workbench.taskExecutionIdentity(source_task_id);

    try std.testing.expectError(
        error.BindingEpochMismatch,
        workbench.createFullAccessSuccessor(source_task_id, source_binding_epoch + 1),
    );

    // A successor consumes the source Task's owned copy, not the mutable global
    // default. Replacing the default must not silently substitute generation 2.
    try installControlExecutionGeneration(&workbench, 2);
    const successor_task_id = try workbench.createFullAccessSuccessor(
        source_task_id,
        source_binding_epoch,
    );
    try std.testing.expect(successor_task_id != source_task_id);
    try std.testing.expectEqual(
        workspace_id,
        try workbench.taskWorkspaceId(successor_task_id),
    );
    try std.testing.expectEqual(
        product_control.PermissionProfile.approval_required,
        try workbench.taskPermissionProfile(source_task_id),
    );
    try std.testing.expectEqual(
        product_control.PermissionProfile.full_access,
        try workbench.taskPermissionProfile(successor_task_id),
    );
    try std.testing.expectEqual(
        product_control.PermissionInteraction.interactive,
        try workbench.taskPermissionInteraction(successor_task_id),
    );
    try std.testing.expectEqual(
        product_control.PermissionProfile.full_access,
        workbench.defaultPermissionProfile(),
    );
    const successor_execution = try workbench.taskExecutionIdentity(successor_task_id);
    try std.testing.expectEqual(source_execution.generation, successor_execution.generation);
    try std.testing.expectEqual(source_execution.protocol, successor_execution.protocol);
    try std.testing.expectEqualStrings(source_execution.model, successor_execution.model);
    try std.testing.expectError(
        error.UnsupportedPermissionProfile,
        workbench.createFullAccessSuccessor(
            successor_task_id,
            try workbench.taskBindingEpoch(successor_task_id),
        ),
    );

    fake_core.lock();
    const successor_mode = fake_core.last_permission_mode_code;
    const successor_shell = fake_core.last_shell_policy_code;
    fake_core.unlock();
    try std.testing.expectEqual(@as(?u32, wire.PERMISSION_FULL_ACCESS), successor_mode);
    try std.testing.expectEqual(@as(?u32, wire.SHELL_UNRESTRICTED), successor_shell);
}

test "full-access successor preserves admitted tasks when history commit fails or is unknown" {
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
    const history = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(history);
    var persistence: TaskPersistenceProbe = .{
        .storage = history,
        .store_on_outcome_unknown = true,
    };
    var configuration = productControlConfiguration();
    configuration.task_persistence = persistence.capability();
    const limits: product_control.Limits = .{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_tasks = 4,
        .max_workspaces = 2,
        .max_runs_per_task = 2,
        .max_tools_per_run = 1,
    };
    var workbench = try product_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        runtime,
        limits,
        configuration,
    );
    defer workbench.deinit();
    try installControlExecution(&workbench);
    const workspace_id = try workbench.openWorkspace(productControlTaskInput());
    const admission = workbench.newTaskAdmissionView();
    const source_id = try workbench.createTaskInWorkspace(
        workspace_id,
        try workbench.workspaceEpoch(workspace_id),
        admission.active_generation,
        admission.active_selection_revision,
        null,
        null,
        null,
        .{ .interactive = .manual },
    );
    const epoch = try workbench.taskBindingEpoch(source_id);

    persistence.result = .failed;
    const first_id = try workbench.createFullAccessSuccessor(source_id, epoch);
    try std.testing.expect(workbench.task_persistence_health == .write_failed);
    try std.testing.expectEqual(.full_access, try workbench.taskPermissionProfile(first_id));
    try std.testing.expectEqual(.full_access, workbench.defaultPermissionProfile());
    try std.testing.expectEqual(.approval_required, try workbench.taskPermissionProfile(source_id));

    persistence.result = .outcome_unknown;
    const second_id = try workbench.createFullAccessSuccessor(source_id, epoch);
    try std.testing.expect(first_id != second_id);
    try std.testing.expect(workbench.task_persistence_health == .outcome_unknown);
    try std.testing.expectEqual(.full_access, try workbench.taskPermissionProfile(first_id));
    try std.testing.expectEqual(.full_access, try workbench.taskPermissionProfile(second_id));
    try std.testing.expectEqual(.full_access, workbench.defaultPermissionProfile());

    // An unknown result can already have installed the complete projection.
    // Restore those exact bytes, without a clean-shutdown save masking rollback.
    var restart_configuration = productControlConfiguration();
    restart_configuration.task_persistence = persistence.capabilityRestored(history[0..persistence.len]);
    var restored = try product_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        runtime,
        limits,
        restart_configuration,
    );
    defer restored.deinit();
    try std.testing.expectEqual(.full_access, restored.defaultPermissionProfile());
    try std.testing.expectEqual(.full_access, try restored.taskPermissionProfile(first_id));
    try std.testing.expectEqual(.full_access, try restored.taskPermissionProfile(second_id));
    try std.testing.expectEqual(.approval_required, try restored.taskPermissionProfile(source_id));
}

test "full-access successor rejects active and Automatic Workspace sources" {
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
    var workbench = try product_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 1,
            .max_tasks = 3,
            .max_workspaces = 2,
            .max_runs_per_task = 1,
            .max_tools_per_run = 1,
        },
        .{
            .directories = .{ .testing_automatic_workspace_root = &automatic_root },
            .skill_sources = .{ .restored = .{ .loaded = .{ .ready = .{} } } },
        },
    );
    defer workbench.deinit();
    try installControlExecution(&workbench);
    const admission = workbench.newTaskAdmissionView();

    const manual_workspace_id = try workbench.openWorkspace(productControlTaskInput());
    const manual_task_id = try workbench.createTaskInWorkspace(
        manual_workspace_id,
        try workbench.workspaceEpoch(manual_workspace_id),
        admission.active_generation,
        admission.active_selection_revision,
        null,
        null,
        null,
        .{ .interactive = .manual },
    );
    _ = try workbench.runTask(manual_task_id, .{ .text = "remain active" });
    try std.testing.expectError(
        error.TaskBusy,
        workbench.createFullAccessSuccessor(
            manual_task_id,
            try workbench.taskBindingEpoch(manual_task_id),
        ),
    );

    const automatic_task_id = try workbench.createTaskForWorkspace(
        .automatic,
        admission.active_generation,
        admission.active_selection_revision,
        null,
        null,
        null,
        .{ .interactive = .manual },
    );
    try std.testing.expectError(
        error.AutomaticWorkspaceUnsupported,
        workbench.createFullAccessSuccessor(
            automatic_task_id,
            try workbench.taskBindingEpoch(automatic_task_id),
        ),
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
    const task_id = try workbench.createTask(productControlTaskInput());
    _ = try workbench.runTask(task_id, .{ .text = "persist checkpoint" });
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
    _ = try workbench.runTask(task_id, .{ .text = "checkpoint after compact" });
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
    const task_id = try first.createTaskInWorkspace(
        workspace_id,
        try first.workspaceEpoch(workspace_id),
        1,
        first.newTaskAdmissionView().active_selection_revision,
        null,
        catalog.revision,
        catalog.selection_revision,
        .{ .interactive = .full_access },
    );
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
    _ = try first.runTask(task_id, .{ .text = "remember restart nonce" });
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
    fake_core.armControlledRestore();
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
    var execution_replacement_pending = false;
    defer if (execution_replacement_pending)
        restored.endExecutionReplacementNoFail();
    try restored.beginExecutionReplacement();
    execution_replacement_pending = true;
    fake_core.releaseControlledRestore();
    try waitTaskSnapshot(
        &restored,
        "\"id\":\"1\"",
        "\"activeOperation\":null",
    );
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
    restored.endExecutionReplacementNoFail();
    execution_replacement_pending = false;
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
    try std.testing.expectEqual(@as(usize, 10), fake_core.last_restored_allowed_tool_count);

    _ = try restored.runTask(task_id, .{ .text = "continue after restart" });
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
    const shutdown_snapshot = try shutdown_restore.writeSnapshot(
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

    fake_core.armControlledRestore();
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
    const invalidation_snapshot = try workspace_invalidation.writeSnapshot(
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
    const task_id = try first.createTaskForWorkspace(
        .automatic,
        1,
        first.newTaskAdmissionView().active_selection_revision,
        null,
        null,
        null,
        .{ .interactive = null },
    );
    _ = try first.runTask(task_id, .{ .text = "automatic first run" });
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
    try std.testing.expectEqual(@as(u64, 2), try continued.taskBindingEpoch(task_id));
    try std.testing.expectEqual(
        product_control.CatalogAvailability.uninitialized,
        (try continued.taskCatalog(task_id)).availability,
    );
    _ = try continued.runTask(task_id, .{ .text = "automatic second run" });
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
    const task_id = try workbench.createTask(productControlTaskInput());
    _ = try workbench.runTask(task_id, .{ .text = "cancel checkpoint export" });
    fake_core.waitCheckpointExportEntered();
    // Product terminal publication must not wait for the same executor job's
    // controlled checkpoint export to be released.
    try waitControlSnapshot(&workbench, "\"terminal\":{\"outcome\":\"completed\"");
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
    const task_id = try workbench.createTask(productControlTaskInput());
    _ = try workbench.runTask(task_id, .{ .text = "descriptor commit fails" });
    fake_core.waitCheckpointExportEntered();
    try workbench.drainAgentEvents();
    var snapshot: [128 * 1024]u8 = undefined;
    _ = try workbench.writeSnapshot(&snapshot);
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
        _ = try workbench.writeSnapshot(&snapshot);
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
    const restored_json = try restored.writeSnapshot(&restored_snapshot);
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
    const task_id = try workbench.createTask(productControlTaskInput());
    _ = try workbench.runTask(task_id, .{ .text = "descriptor outcome is unknown" });
    fake_core.waitCheckpointExportEntered();
    try workbench.drainAgentEvents();
    var snapshot: [128 * 1024]u8 = undefined;
    _ = try workbench.writeSnapshot(&snapshot);
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
        const snapshot_json = try workbench.writeSnapshot(&snapshot);
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
    const continuation_id = try workbench.runTask(task_id, .{
        .text = "continue after unknown descriptor",
    });
    try std.testing.expectEqual(@as(u64, 2), continuation_id);
    try waitSetTaskArchived(&workbench, task_id);
    try workbench.setTaskArchived(task_id, false);
    const compact_id = try workbench.compactTaskAtBinding(task_id, 1);
    try std.testing.expectEqual(@as(u64, 1), compact_id);
    try waitTaskSnapshot(
        &workbench,
        "\"operationId\":\"1\"",
        "\"phase\":\"compacted\"",
    );
    const healed_snapshot = try workbench.writeSnapshot(&snapshot);
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
    const task_id = try first.createTask(productControlTaskInput());
    _ = try first.runTask(task_id, .{ .text = "prepare recovery queue failure" });
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
    const blocker_one = try restored.createTask(productControlTaskInput());
    const blocker_two = try restored.createTask(productControlTaskInput());
    try restored.renameTask(blocker_one, "restore blocker one");
    try restored.renameTask(blocker_two, "restore blocker two");
    fake_core.setSessionPlan(.controlled);
    fake_core.rearmControlled();
    var blockers_released = false;
    defer if (!blockers_released) fake_core.releaseControlled();
    _ = try restored.runTask(blocker_one, .{ .text = "occupy recovery worker" });
    try waitTaskSnapshot(
        &restored,
        "\"title\":\"restore blocker one\"",
        "\"currentRunPhase\":\"running\"",
    );
    _ = try restored.runTask(blocker_two, .{ .text = "fill recovery queue" });

    const revision_before_rejection = restored.currentRevision();
    try std.testing.expectError(
        error.QueueFull,
        restored.restoreTaskConversation(
            task_id,
            try restored.taskBindingEpoch(task_id),
        ),
    );
    try std.testing.expectEqual(revision_before_rejection, restored.currentRevision());
    const recovered_task = &restored.task_runtime.tasks[0].?;
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
    const task_id = try first.createTask(productControlTaskInput());
    _ = try first.runTask(task_id, .{ .text = "persist terminal boundary" });
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
    const snapshot = try restarted.writeSnapshot(&snapshot_storage);
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
    const snapshot = try workbench.writeSnapshot(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(
        u8,
        snapshot,
        "\"taskHistoryPersistenceHealth\":\"corrupt\"",
    ) != null);
    try checkpoint_store.verify(identity);
    try installControlExecution(&workbench);
    const task_id = try workbench.createTask(productControlTaskInput());
    _ = try workbench.runTask(task_id, .{ .text = "Continue without saved history" });
    try waitControlSnapshot(&workbench, "\"terminal\":{\"outcome\":\"completed\"");
    const continued = try workbench.writeSnapshot(&snapshot_storage);
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
    const task_id = try workbench.createTask(productControlTaskInput());
    _ = try workbench.runTask(task_id, .{ .text = "checkpoint store unavailable" });
    try waitControlSnapshot(&workbench, "\"terminal\":{\"outcome\":\"completed\"");
    try std.testing.expectEqual(@as(usize, 1), fake_core.session_created);
    try std.testing.expectEqual(@as(usize, 0), fake_core.checkpoint_exports);
}

fn waitCatalogUnavailable(
    workbench: *product_control.Runtime,
    workspace_id: u64,
) !void {
    for (0..10_000) |_| {
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
        return .committed;
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

test "retired Schedule data leaves Account ready and New Task admission unavailable" {
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
    var schedule_support: TestScheduleSupport = .{};
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

    try product_control.TestSupport.prepareMetaskDefault(&workbench, 1);
    try workbench.beginExecutionReplacement();
    var execution = try models_contract.OwnedConfig.initOwned(
        std.testing.allocator,
        .metask,
        .anthropic_messages,
        try std.testing.allocator.dupe(u8, "fixture-model"),
        try std.testing.allocator.dupe(
            u8,
            models_contract.metask_anthropic_messages_url,
        ),
        1,
        try std.testing.allocator.dupe(u8, "fixture-secret"),
        "",
    );
    var execution_owned = true;
    defer if (execution_owned) execution.deinit();
    try std.testing.expectError(
        error.ScheduledTaskPersistenceUnavailable,
        workbench.prepareExecutionInstall(execution.input()),
    );
    workbench.endExecutionReplacementNoFail();
    workbench.finishAccountCommitNoFail();

    try account_contract.validateView(workbench.accountView());
    const admission = workbench.newTaskAdmissionView();
    try std.testing.expect(admission.state == .unavailable);
    try std.testing.expect(admission.active_model_ref == null);
    try std.testing.expect(!admission.available);

    var snapshot_storage: [128 * 1024]u8 = undefined;
    const snapshot = try workbench.writeSnapshot(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(
        u8,
        snapshot,
        "\"scheduledTaskPersistenceHealth\":\"corrupt\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        snapshot,
        "\"newTaskAdmission\":{\"available\":false,\"reason\":\"none\",\"activeModelRef\":null,\"activeGeneration\":\"0\",\"activeSelectionRevision\":\"0\",\"state\":\"unavailable\"}",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        snapshot,
        "\"scheduledTaskRecoveryAvailable\":true",
    ) != null);

    try std.testing.expectEqual(
        product_control.PersistenceRecoveryOutcome.recovered,
        workbench.recoverScheduledTaskStore(workbench.currentRevision()),
    );
    try std.testing.expectEqual(@as(usize, 1), schedule_support.recoveries);
    const recovered_snapshot = try workbench.writeSnapshot(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(
        u8,
        recovered_snapshot,
        "\"scheduledTaskPersistenceHealth\":\"ready\",\"scheduledTaskRecoveryAvailable\":false",
    ) != null);
    try workbench.beginExecutionReplacement();
    try workbench.prepareExecutionInstall(execution.input());
    workbench.installExecutionNoFail(&execution);
    workbench.execution_state.recordDefaultAuthorityNoFail(
        workbench.custom_providers.defaultAuthority().?,
    );
    execution_owned = false;
    workbench.endExecutionReplacementNoFail();
    workbench.finishAccountCommitNoFail();
    try std.testing.expect(workbench.newTaskAdmissionView().available);
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
    try installControlExecution(&workbench);

    const schedule_id = try workbench.createScheduledTask(.{
        .title = "Permission boundary",
        .binding = scheduledBinding(&workbench),
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
    const snapshot = try workbench.writeSnapshot(&snapshot_storage);
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
        .binding = scheduledBinding(&workbench),
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
    const snapshot = try workbench.writeSnapshot(&snapshot_storage);
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
        .binding = scheduledBinding(&workbench),
        .permission_profile = .approval_required,
        .input = "Run only after durable admission",
        .recurrence = .{ .once = .{ .at_unix_seconds = 2_000 } },
    });
    try std.testing.expectError(
        error.TaskPersistenceFailed,
        workbench.runScheduledTaskNow(schedule_id, 1),
    );

    var snapshot_storage: [128 * 1024]u8 = undefined;
    const rejected = try workbench.writeSnapshot(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(
        u8,
        rejected,
        "\"health\":\"needs_attention\",\"failureReason\":\"task_start_failed\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, rejected, "\"tasks\":[]") != null);

    const task_id = try workbench.createTaskForWorkspace(
        .automatic,
        1,
        workbench.newTaskAdmissionView().active_selection_revision,
        null,
        null,
        null,
        .{ .interactive = null },
    );
    _ = try workbench.runTask(task_id, .{ .text = "Continue interactively" });
    try waitControlSnapshot(&workbench, "\"terminal\":{\"outcome\":\"completed\"");
    const continued = try workbench.writeSnapshot(&snapshot_storage);
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
        .binding = scheduledBinding(&workbench),
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
    const unknown_snapshot = try workbench.writeSnapshot(&snapshot_storage);
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
    const restarted_snapshot = try restarted.writeSnapshot(&snapshot_storage);
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

    const task_id = try workbench.createTaskForWorkspace(
        .automatic,
        1,
        workbench.newTaskAdmissionView().active_selection_revision,
        null,
        null,
        null,
        .{ .interactive = null },
    );
    _ = try workbench.runTask(task_id, .{ .text = "Remain accepted" });
    try waitControlSnapshot(&workbench, "\"terminal\":{\"outcome\":\"completed\"");

    fake_core.lock();
    const run_calls = fake_core.run_calls;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), run_calls);
    var snapshot_storage: [128 * 1024]u8 = undefined;
    const snapshot = try workbench.writeSnapshot(&snapshot_storage);
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
        .{ .directories = .{ .testing_automatic_workspace_root = &automatic_root } },
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
    const task_id = try workbench.createTaskForWorkspace(
        .automatic,
        1,
        workbench.newTaskAdmissionView().active_selection_revision,
        null,
        null,
        null,
        .{ .interactive = null },
    );
    _ = try workbench.runTask(task_id, .{ .multimodal = .{
        .text = "Compare these",
        .attachment_ids = &ids,
        .acceptance = .{ .context = &acceptance, .accept_fn = Acceptance.accept },
    } });
    try std.testing.expectEqual(@as(usize, 1), acceptance.count);
    try std.testing.expect(!workbench.releaseAttachment(ids[0]));
    try std.testing.expect(!workbench.releaseAttachment(ids[1]));
    try waitControlSnapshot(&workbench, "\"terminal\":{\"outcome\":\"completed\"");

    var snapshot_storage: [128 * 1024]u8 = undefined;
    const snapshot = try workbench.writeSnapshot(&snapshot_storage);
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
    const pure_run_id = try workbench.runTask(task_id, .{ .multimodal = .{
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
    const pure_snapshot = try workbench.writeSnapshot(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(
        u8,
        pure_snapshot,
        "\"input\":{\"kind\":\"multimodal\",\"text\":null,\"attachments\":[{\"kind\":\"image\",\"format\":\"jpeg\",\"displayName\":\"photo.jpg\",\"sizeBytes\":\"7\",\"redacted\":false}],\"redacted\":false}",
    ) != null);

    const text_files = [_]product_control.AttachmentCandidate{.{
        .display_name = "notes.md",
        .bytes = "untrusted reference text",
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
    const text_run_id = try workbench.runTask(task_id, .{ .multimodal = .{
        .text = "Summarize this file",
        .attachment_ids = &retry_ids,
    } });
    const text_terminal = try std.fmt.bufPrint(
        &terminal_needle,
        "\"id\":\"{d}\",\"conversationCoverage\":\"included\",\"phase\":\"completed\"",
        .{text_run_id},
    );
    try waitControlSnapshot(&workbench, text_terminal);
    const text_snapshot = try workbench.writeSnapshot(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text_snapshot,
        "\"input\":{\"kind\":\"multimodal\",\"text\":\"Summarize this file\",\"attachments\":[{\"kind\":\"file\",\"displayName\":\"notes.md\",\"sizeBytes\":\"24\",\"redacted\":false}],\"redacted\":false}",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, text_snapshot, "untrusted reference text") == null);
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

test "Product Control pins an async catalog and admits typed Skill through the existing executor" {
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
    const task_id = try workbench.createTaskInWorkspace(
        workspace_id,
        try workbench.workspaceEpoch(workspace_id),
        1,
        workbench.newTaskAdmissionView().active_selection_revision,
        null,
        catalog.revision,
        catalog.selection_revision,
        .{ .interactive = null },
    );
    const task_catalog = try workbench.taskCatalog(task_id);
    try std.testing.expectEqualStrings(catalog.revision, task_catalog.revision);
    _ = try workbench.runTask(task_id, .{ .skill = .{
        .skill_id = fixture.fixture_skill_id,
        .catalog_revision = catalog.revision,
        .selection_revision = catalog.selection_revision.?,
        .argument_values = &.{ "src/main.zig", "correctness" },
    } });
    try waitControlSnapshot(
        &workbench,
        "\"terminal\":{\"outcome\":\"completed\"",
    );
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
    const skill_title_snapshot_bytes = try workbench.writeSnapshot(&skill_title_snapshot);
    try std.testing.expect(
        std.mem.indexOf(u8, skill_title_snapshot_bytes, "\"title\":\"Review\"") != null,
    );
    fake_core.lock();
    const skill_seen = fake_core.skill_run_seen;
    const input_matches = fake_core.skill_input_matches;
    fake_core.unlock();
    try std.testing.expect(skill_seen);
    try std.testing.expect(input_matches);
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
    const task_id = try workbench.createTaskForWorkspace(
        .{ .manual = .{
            .workspace_id = workspace_id,
            .expected_epoch = epoch,
        } },
        1,
        workbench.newTaskAdmissionView().active_selection_revision,
        null,
        null,
        null,
        .{ .interactive = null },
    );
    const after = try workbench.copyWorkspaceProjections(&projection_storage);
    try std.testing.expect(after[0].recent_order > recent_order);
    var snapshot_storage: [128 * 1024]u8 = undefined;
    const snapshot = try workbench.writeSnapshot(&snapshot_storage);
    var task_id_storage: [32]u8 = undefined;
    const task_id_json = try std.fmt.bufPrint(&task_id_storage, "\"id\":\"{d}\"", .{task_id});
    try std.testing.expect(std.mem.indexOf(u8, snapshot, task_id_json) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        snapshot,
        "\"taskHistoryPersistenceHealth\":\"write_failed\"",
    ) != null);
}

test "Idle Task model persistence failure keeps the selected model and Session usable" {
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
        const task_id = try workbench.createTask(productControlTaskInput());
        const before = try workbench.taskExecutionIdentity(task_id);
        const projection_before = workbench.projectionBytesForTest();
        try expectFakeSessionModel(0, "fixture-model");
        persistence.result = .failed;
        try workbench.selectTaskModel(
            task_id,
            taskModelSelectionInput(
                &workbench,
                before.model,
                before.generation,
                "fixture-model-2",
            ),
        );
        const after = try workbench.taskExecutionIdentity(task_id);
        try std.testing.expectEqualStrings("fixture-model-2", after.model);
        try expectFakeSessionModel(0, "fixture-model-2");
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
        const task_id = try workbench.createTask(productControlTaskInput());
        const before = try workbench.taskExecutionIdentity(task_id);
        const projection_before = workbench.projectionBytesForTest();
        persistence.result = .outcome_unknown;
        try workbench.selectTaskModel(
            task_id,
            taskModelSelectionInput(
                &workbench,
                before.model,
                before.generation,
                "fixture-model-2",
            ),
        );
        const after = try workbench.taskExecutionIdentity(task_id);
        try std.testing.expectEqualStrings("fixture-model-2", after.model);
        try expectFakeSessionModel(0, "fixture-model-2");
        try std.testing.expect(workbench.projectionBytesForTest() >= projection_before);
    }
}

test "automatic Workspace admission is Task-owned and Text-only" {
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

    const first_task = try workbench.createTaskForWorkspace(
        .automatic,
        1,
        workbench.newTaskAdmissionView().active_selection_revision,
        null,
        null,
        null,
        .{ .interactive = null },
    );
    const first_workspace = try workbench.taskWorkspaceId(first_task);
    try std.testing.expectEqual(
        product_control.WorkspaceKind.automatic,
        try workbench.workspaceKind(first_workspace),
    );
    try std.testing.expectEqual(
        product_control.CatalogAvailability.uninitialized,
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
    const automatic_snapshot = try workbench.writeSnapshot(
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
        workbench.createTaskInWorkspace(
            first_workspace,
            try workbench.workspaceEpoch(first_workspace),
            1,
            workbench.newTaskAdmissionView().active_selection_revision,
            null,
            null,
            null,
            .{ .interactive = null },
        ),
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

    const second_task = try workbench.createTaskForWorkspace(
        .automatic,
        1,
        workbench.newTaskAdmissionView().active_selection_revision,
        null,
        null,
        null,
        .{ .interactive = null },
    );
    const second_workspace = try workbench.taskWorkspaceId(second_task);
    try std.testing.expect(first_workspace != second_workspace);
    try std.testing.expectEqual(@as(usize, 2), try directoryEntryCount(tmp.dir));

    try workbench.renameTask(second_task, "Preset title");
    _ = try workbench.runTask(second_task, .{ .text = "must not replace preset" });
    try waitControlSnapshot(&workbench, "\"terminal\":{\"outcome\":\"completed\"");
    var preset_title_snapshot: [128 * 1024]u8 = undefined;
    const preset_title_snapshot_bytes = try workbench.writeSnapshot(&preset_title_snapshot);
    try std.testing.expect(
        std.mem.indexOf(u8, preset_title_snapshot_bytes, "\"title\":\"Preset title\"") != null,
    );

    fake_core.setCompletionTitle("Generated task title");
    fake_core.controlNextCompletion();
    var completion_released = false;
    defer if (!completion_released) fake_core.releaseCompletion();
    fake_core.setSessionPlan(.controlled);
    _ = try workbench.runTask(first_task, .{ .text = "automatic text run" });
    try waitControlSnapshot(&workbench, "\"currentRunPhase\":\"running\"");
    var provisional_title_snapshot: [128 * 1024]u8 = undefined;
    const provisional_title_snapshot_bytes = try workbench.writeSnapshot(
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
    const deleting_snapshot = try workbench.writeSnapshot(&deleting_snapshot_storage);
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
        product_control.CatalogAvailability.uninitialized,
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
    _ = try workbench.createTask(productControlTaskInput());
    const revision = workbench.currentRevision();

    try std.testing.expectError(
        error.TaskCapacity,
        workbench.createTaskForWorkspace(
            .automatic,
            1,
            workbench.newTaskAdmissionView().active_selection_revision,
            null,
            null,
            null,
            .{ .interactive = null },
        ),
    );
    try std.testing.expectEqual(revision, workbench.currentRevision());
    try std.testing.expectEqual(@as(usize, 0), try directoryEntryCount(tmp.dir));
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
        .binding = scheduledBinding(&workbench),
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
            .binding = scheduledBinding(&workbench),
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
        .binding = scheduledBinding(&workbench),
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
    const updated_snapshot = try workbench.writeSnapshot(&updated_snapshot_storage);
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
    const snapshot = try workbench.writeSnapshot(&snapshot_storage);
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
        .binding = scheduledBinding(&workbench),
        .permission_profile = .approval_required,
        .input = "Summarize current work",
        .recurrence = .{ .once = .{ .at_unix_seconds = 2_000 } },
    });
    fake_core.setNextPlan(.controlled);
    defer fake_core.releaseControlled();
    const running_task = try workbench.createTaskForWorkspace(
        .automatic,
        1,
        workbench.newTaskAdmissionView().active_selection_revision,
        null,
        null,
        null,
        .{ .interactive = null },
    );
    const queued_task = try workbench.createTaskForWorkspace(
        .automatic,
        1,
        workbench.newTaskAdmissionView().active_selection_revision,
        null,
        null,
        null,
        .{ .interactive = null },
    );
    _ = try workbench.runTask(running_task, .{ .text = "hold worker" });
    try waitControlSnapshot(
        &workbench,
        "\"currentRunPhase\":\"running\"",
    );
    _ = try workbench.runTask(queued_task, .{ .text = "fill queue" });

    try std.testing.expectError(
        error.QueueFull,
        workbench.runScheduledTaskNow(schedule_id, 1),
    );
    try std.testing.expectEqual(@as(usize, 3), try directoryEntryCount(tmp.dir));
    var snapshot_storage: [128 * 1024]u8 = undefined;
    const snapshot = try workbench.writeSnapshot(&snapshot_storage);
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
        workbench.createTaskInWorkspace(
            workspace_id,
            try workbench.workspaceEpoch(workspace_id),
            1,
            workbench.newTaskAdmissionView().active_selection_revision,
            null,
            "stale-revision",
            catalog.selection_revision,
            .{ .interactive = null },
        ),
    );
    fake_core.lock();
    const sessions_before = fake_core.session_created;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 0), sessions_before);

    fake_core.setNextPlan(.stale_catalog);
    const task_id = try workbench.createTaskInWorkspace(
        workspace_id,
        try workbench.workspaceEpoch(workspace_id),
        1,
        workbench.newTaskAdmissionView().active_selection_revision,
        null,
        catalog.revision,
        catalog.selection_revision,
        .{ .interactive = null },
    );
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

    _ = try workbench.runTask(task_id, .{ .skill = .{
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
    try std.testing.expectEqual(@as(usize, 2), catalog_releases);
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
    const task_id = try workbench.createTaskInWorkspace(
        workspace_id,
        try workbench.workspaceEpoch(workspace_id),
        1,
        workbench.newTaskAdmissionView().active_selection_revision,
        null,
        null,
        null,
        .{ .interactive = null },
    );
    _ = try workbench.runTask(task_id, .{ .text = "hold refresh" });
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

    const task_id = try workbench.createTask(productControlTaskInput());
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

test "asynchronous Task deletion commit failure retains a retryable archived record" {
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

    const task_id = try workbench.createTask(productControlTaskInput());
    try workbench.setTaskArchived(task_id, true);
    persistence.result = .failed;
    try workbench.deleteTask(task_id);
    try waitControlSnapshot(&workbench, "\"deletionStatus\":\"failed\"");
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

    const task_id = try workbench.createTask(productControlTaskInput());
    const run_id = try workbench.runTask(task_id, .{ .text = "finish before deletion" });
    try workbench.cancel(task_id, run_id);
    try waitControlSnapshot(&workbench, "\"terminal\":{\"outcome\":\"cancelled\"");
    try workbench.setTaskArchived(task_id, true);
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

    const task_id = try workbench.createTask(productControlTaskInput());
    const workspace_id = try workbench.taskWorkspaceId(task_id);
    _ = try workbench.runTask(
        task_id,
        .{ .text = "stop when the workspace is removed" },
    );
    try waitControlSnapshot(&workbench, "\"currentRunPhase\":\"running\"");

    try workbench.removeWorkspace(workspace_id);
    try waitControlSnapshot(&workbench, "\"terminal\":{\"outcome\":\"interrupted\"");
    try waitControlSnapshot(&workbench, "\"lifecycle\":\"open\"");

    var snapshot_storage: [128 * 1024]u8 = undefined;
    const snapshot = try workbench.writeSnapshot(&snapshot_storage);
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

    const task_id = try workbench.createTask(productControlTaskInput());
    const workspace_id = try workbench.taskWorkspaceId(task_id);
    fake_core.failNextSessionDestroy();
    try workbench.removeWorkspace(workspace_id);
    try waitControlSnapshot(
        &workbench,
        "\"lastRemovalFailure\":\"task_close_failed\"",
    );

    var snapshot_storage: [128 * 1024]u8 = undefined;
    const snapshot = try workbench.writeSnapshot(&snapshot_storage);
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

    const task_id = try workbench.createTask(productControlTaskInput());
    const run_id = try workbench.runTask(
        task_id,
        .{ .text = "finish before cancel arrives" },
    );
    try waitControlSnapshot(&workbench, "\"terminal\":{\"outcome\":\"completed\"");
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

    const task_id = try workbench.createTask(productControlTaskInput());
    try std.testing.expectError(
        error.NoSuchRun,
        workbench.compactTaskAtBinding(task_id, 1),
    );
    _ = try workbench.runTask(task_id, .{ .text = "establish conversation" });
    try waitControlSnapshot(&workbench, "\"terminal\":{\"outcome\":\"completed\"");

    _ = try workbench.compactTaskAtBinding(task_id, 1);
    try waitControlSnapshot(&workbench, "\"phase\":\"compacted\"");
    _ = try workbench.compactTaskAtBinding(task_id, 1);
    try waitTaskSnapshot(
        &workbench,
        "\"operationId\":\"2\"",
        "\"phase\":\"compacted\"",
    );
    try std.testing.expectError(
        error.CompactCapacity,
        workbench.compactTaskAtBinding(task_id, 1),
    );

    var storage: [128 * 1024]u8 = undefined;
    const snapshot = try workbench.writeSnapshot(&storage);
    try std.testing.expect(std.mem.indexOf(
        u8,
        snapshot,
        "\"activeOperation\":null",
    ) != null);
    try std.testing.expectEqual(
        @as(usize, 2),
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

    const compact_task = try workbench.createTask(productControlTaskInput());
    const blocking_task = try workbench.createTask(productControlTaskInput());
    const queued_task = try workbench.createTask(productControlTaskInput());
    _ = try workbench.runTask(compact_task, .{ .text = "establish conversation" });
    try waitControlSnapshot(&workbench, "\"terminal\":{\"outcome\":\"completed\"");

    fake_core.setSessionPlan(.controlled);
    fake_core.rearmControlled();
    defer fake_core.releaseControlled();
    _ = try workbench.runTask(blocking_task, .{ .text = "hold worker" });
    try waitControlSnapshot(&workbench, "\"currentRunPhase\":\"running\"");
    _ = try workbench.runTask(queued_task, .{ .text = "fill queue" });

    const operation_id = try workbench.compactTaskAtBinding(compact_task, 1);
    try std.testing.expectEqual(@as(u64, 1), operation_id);
    var snapshot_storage: [128 * 1024]u8 = undefined;
    const snapshot = try workbench.writeSnapshot(&snapshot_storage);
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

    const task_id = try workbench.createTask(productControlTaskInput());
    _ = try workbench.runTask(task_id, .{ .text = "establish conversation" });
    try waitControlSnapshot(&workbench, "\"terminal\":{\"outcome\":\"completed\"");
    fake_core.setSessionPlan(.controlled);
    fake_core.rearmControlled();
    const operation_id = try workbench.compactTaskAtBinding(task_id, 1);
    try waitControlSnapshot(&workbench, "\"phase\":\"compacting\"");
    try std.testing.expectError(
        error.TaskBusy,
        workbench.runTask(task_id, .{ .text = "must wait" }),
    );
    try workbench.cancelCompact(task_id, operation_id);
    try waitControlSnapshot(&workbench, "\"phase\":\"aborted\"");
    try waitControlSnapshot(&workbench, "\"activeOperation\":null");

    try workbench.setTaskArchived(task_id, true);
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

    const task_id = try workbench.createTask(productControlTaskInput());
    _ = try workbench.runTask(task_id, .{ .text = "establish conversation" });
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

test "Product Control cancels a queued compact without entering AgentCore" {
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
        productControlConfiguration(),
    );
    defer workbench.deinit();
    try installControlExecution(&workbench);

    const blocking_task_id = try workbench.createTask(productControlTaskInput());
    const compact_task_id = try workbench.createTask(productControlTaskInput());
    try workbench.renameTask(blocking_task_id, "blocking target");
    try workbench.renameTask(compact_task_id, "compact target");
    _ = try workbench.runTask(blocking_task_id, .{ .text = "first conversation" });
    try waitTaskSnapshot(
        &workbench,
        "\"title\":\"blocking target\"",
        "\"terminal\":{\"outcome\":\"completed\"",
    );
    _ = try workbench.runTask(compact_task_id, .{ .text = "second conversation" });
    try waitTaskSnapshot(
        &workbench,
        "\"title\":\"compact target\"",
        "\"terminal\":{\"outcome\":\"completed\"",
    );

    fake_core.setSessionPlan(.controlled);
    fake_core.rearmControlled();
    const blocking_run_id = try workbench.runTask(
        blocking_task_id,
        .{ .text = "occupy the only worker" },
    );
    try waitControlSnapshot(&workbench, "\"currentRunPhase\":\"running\"");
    const operation_id = try workbench.compactTaskAtBinding(compact_task_id, 1);
    try waitControlSnapshot(&workbench, "\"phase\":\"queued\"");
    try workbench.cancelCompact(compact_task_id, operation_id);
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

    const task_id = try workbench.createTask(productControlTaskInput());
    _ = try workbench.runTask(task_id, .{ .text = "wait for shutdown" });
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
    const task_id = try first.createTask(productControlTaskInput());
    try std.testing.expectEqual(
        @as(u64, 1),
        try first.runTask(task_id, .{ .text = "checkpoint before shutdown" }),
    );
    try waitCheckpointRecord(&first, &persistence);

    fake_core.setCheckpointGeneration(2);
    fake_core.setSessionPlan(.controlled);
    fake_core.rearmControlled();
    try std.testing.expectEqual(
        @as(u64, 2),
        try first.runTask(task_id, .{ .text = "interrupt this Run during shutdown" }),
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
        try restored.runTask(task_id, .{ .text = "continue after restart" }),
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
    const task_id = try first.createTask(productControlTaskInput());
    fake_core.setSessionPlan(.ui_wait);
    fake_core.rearmControlled();
    try std.testing.expectEqual(
        @as(u64, 1),
        try first.runTask(task_id, .{ .text = "resolve permission before checkpoint" }),
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
        try first.runTask(task_id, .{ .text = "killed before terminal" }),
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
        try restored.runTask(task_id, .{ .text = "request permission after checkpoint restore" }),
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
    const task_id = try first.createTask(productControlTaskInput());
    fake_core.setSessionPlan(.ui_wait);
    fake_core.rearmControlled();
    try std.testing.expectEqual(
        @as(u64, 1),
        try first.runTask(task_id, .{ .text = "resolve permission before first checkpoint" }),
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
    fake_core.lock();
    const restore_calls = fake_core.checkpoint_restores;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 0), restore_calls);
    fake_core.setSessionPlan(.ui_wait);
    fake_core.rearmControlled();
    try std.testing.expectEqual(
        @as(u64, 2),
        try restored.runTask(task_id, .{ .text = "request permission after fresh attach" }),
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

    const task_id = try workbench.createTask(productControlTaskInput());
    try std.testing.expectEqual(
        @as(u64, 1),
        try workbench.runTask(task_id, .{ .text = "poison this Session" }),
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
        try workbench.runTask(task_id, .{ .text = "continue the same Task" }),
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
    const continuation_task = try first.createTask(productControlTaskInput());
    try first.renameTask(continuation_task, "continuation target");
    try std.testing.expectEqual(
        @as(u64, 1),
        try first.runTask(continuation_task, .{ .text = "durable checkpoint" }),
    );
    try waitCheckpointRecord(&first, &persistence);

    const blocker_task = try first.createTask(productControlTaskInput());
    try first.renameTask(blocker_task, "executor blocker");
    fake_core.setSessionPlan(.controlled);
    fake_core.rearmControlled();
    _ = try first.runTask(blocker_task, .{ .text = "occupy executor" });
    try waitTaskSnapshot(
        &first,
        "\"title\":\"executor blocker\"",
        "\"currentRunPhase\":\"running\"",
    );
    try std.testing.expectEqual(
        @as(u64, 2),
        try first.runTask(continuation_task, .{ .text = "never entered AgentCore" }),
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
        try restored.runTask(
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
        workbench.createTask(productControlTaskInput()),
    );
    try std.testing.expectEqual(@as(u64, 0), workbench.currentRevision());

    var snapshot_storage: [8192]u8 = undefined;
    const snapshot = try workbench.writeSnapshot(&snapshot_storage);
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

    const task_id = try workbench.createTask(productControlTaskInput());
    const first_run_id = try workbench.runTask(
        task_id,
        .{ .text = "finish first" },
    );
    try waitControlSnapshot(&workbench, "\"currentRunPhase\":\"running\"");
    fake_core.releaseControlled();
    try waitControlSnapshot(&workbench, "\"terminal\":{\"outcome\":\"completed\"");

    fake_core.rearmControlled();
    _ = try workbench.runTask(task_id, .{ .text = "new active work" });
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
    const open_snapshot = try workbench.writeSnapshot(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(u8, open_snapshot, "\"lifecycle\":\"open\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, open_snapshot, "\"currentRunPhase\":\"running\"") != null);
    fake_core.releaseControlled();
    try waitControlSnapshot(&workbench, "\"terminal\":{\"outcome\":\"completed\"");
}
