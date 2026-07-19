const fixture = @import("lifecycle_fixture");
const std = fixture.std;
const lifecycle = fixture.lifecycle;
const workbench_api = fixture.workbench_api;
const fake_core = &fixture.fake_core;
const openSession = fixture.openSession;
const submitSession = fixture.submitSession;
const closeSession = fixture.closeSession;
const shutdownTestComposition = fixture.shutdownTestComposition;
const deinitTestComposition = fixture.deinitTestComposition;
const createTestComposition = fixture.createTestComposition;
const workbenchSessionOptions = fixture.workbenchSessionOptions;
const waitWorkbenchSnapshot = fixture.waitWorkbenchSnapshot;

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

test "Gate 6 Workbench closes off-thread and exposes retryable close failure" {
    fake_core.reset();
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 2, .max_sessions = 2 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var workbench = try workbench_api.Workbench.init(std.testing.allocator, runtime, .{
        .max_tasks = 2,
        .max_runs_per_task = 2,
        .max_tools_per_run = 2,
    });
    defer workbench.deinit();

    const task_id = try workbench.createTask(workbenchSessionOptions());
    fake_core.failNextSessionDestroy();
    try workbench.closeTask(task_id);
    try waitWorkbenchSnapshot(&workbench, "\"closeFailed\":true");

    try workbench.closeTask(task_id);
    try waitWorkbenchSnapshot(&workbench, "\"lifecycle\":\"closed\"");
    fake_core.lock();
    const destroyed = fake_core.session_destroyed;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), destroyed);
}

test "Gate 6 Workbench close cancels a queued Run without blocking the caller" {
    fake_core.reset();
    fake_core.setNextPlan(.controlled);
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 2, .max_sessions = 1 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var workbench = try workbench_api.Workbench.init(std.testing.allocator, runtime, .{
        .max_tasks = 1,
        .max_runs_per_task = 1,
        .max_tools_per_run = 1,
    });
    defer workbench.deinit();

    const task_id = try workbench.createTask(workbenchSessionOptions());
    _ = try workbench.runTask(task_id, "close this run");
    try workbench.closeTask(task_id);
    try waitWorkbenchSnapshot(&workbench, "\"lifecycle\":\"closed\"");
    fake_core.lock();
    const abort_calls = fake_core.abort_calls;
    const destroyed = fake_core.session_destroyed;
    fake_core.unlock();
    try std.testing.expect(abort_calls <= 1);
    try std.testing.expectEqual(@as(usize, 1), destroyed);
}

test "Workbench cancel of a completed Run is an idempotent no-op" {
    fake_core.reset();
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var workbench = try workbench_api.Workbench.init(std.testing.allocator, runtime, .{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_tasks = 1,
        .max_runs_per_task = 1,
        .max_tools_per_run = 1,
    });
    defer workbench.deinit();

    const task_id = try workbench.createTask(workbenchSessionOptions());
    const run_id = try workbench.runTask(task_id, "finish before cancel arrives");
    try waitWorkbenchSnapshot(&workbench, "\"lastRunOutcome\":\"completed\"");
    const revision = workbench.currentRevision();
    try workbench.cancel(task_id, run_id);
    try std.testing.expectEqual(revision, workbench.currentRevision());
    try waitWorkbenchSnapshot(&workbench, "\"lastRunOutcome\":\"completed\"");

    try workbench.closeTask(task_id);
    try waitWorkbenchSnapshot(&workbench, "\"lifecycle\":\"closed\"");
}

test "Workbench shutdown terminates a waiting UI Run before joining workers" {
    fake_core.reset();
    fake_core.setNextPlan(.ui_wait);
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var workbench = try workbench_api.Workbench.init(std.testing.allocator, runtime, .{
        .worker_count = 1,
        .queue_capacity = 2,
        .max_tasks = 1,
        .max_runs_per_task = 1,
        .max_tools_per_run = 1,
    });
    defer workbench.deinit();

    const task_id = try workbench.createTask(workbenchSessionOptions());
    _ = try workbench.runTask(task_id, "wait for shutdown");
    try waitWorkbenchSnapshot(&workbench, "\"currentRunPhase\":\"waiting_ui\"");
    workbench.shutdownExecutor();
    try waitWorkbenchSnapshot(&workbench, "\"lastRunOutcome\":\"interrupted\"");
}
