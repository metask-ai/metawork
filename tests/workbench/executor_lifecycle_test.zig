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
const workbenchConfiguration = fixture.workbenchConfiguration;
const workbenchTaskInput = fixture.workbenchTaskInput;
const waitWorkbenchSnapshot = fixture.waitWorkbenchSnapshot;
const installWorkbenchExecution = fixture.installWorkbenchExecution;

fn waitCatalogReady(
    workbench: *workbench_api.Workbench,
    workspace_id: u64,
) !workbench_api.CatalogProjection {
    for (0..10_000) |_| {
        const projection = try workbench.workspaceCatalog(workspace_id);
        switch (projection.availability) {
            .ready, .degraded => return projection,
            .unavailable => return error.TestUnexpectedResult,
            .uninitialized, .loading => std.Thread.yield() catch {},
        }
    }
    return error.TestUnexpectedResult;
}

fn waitCatalogUnavailable(
    workbench: *workbench_api.Workbench,
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

test "Workbench pins an async catalog and admits typed Skill through the existing executor" {
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
    var workbench = try workbench_api.Workbench.init(
        std.testing.allocator,
        runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 2,
            .max_workspaces = 1,
            .max_tasks = 1,
            .max_runs_per_task = 1,
            .max_tools_per_run = 1,
        },
        .{ .directories = .{ .canonical_user_home = home } },
    );
    defer workbench.deinit();
    try installWorkbenchExecution(&workbench);

    const workspace_id = try workbench.openWorkspace(workbenchTaskInput());
    const catalog = try waitCatalogReady(&workbench, workspace_id);
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
        catalog.revision,
    );
    const task_catalog = try workbench.taskCatalog(task_id);
    try std.testing.expectEqualStrings(catalog.revision, task_catalog.revision);
    _ = try workbench.runTask(task_id, .{ .skill = .{
        .skill_id = fixture.fixture_skill_id,
        .catalog_revision = catalog.revision,
        .argument_values = &.{ "src/main.zig", "correctness" },
    } });
    try waitWorkbenchSnapshot(
        runtime,
        &workbench,
        "\"lastRunOutcome\":\"completed\"",
    );
    try waitWorkbenchSnapshot(
        runtime,
        &workbench,
        "\"skillCatalog\":{\"availability\":\"ready\"",
    );
    try waitWorkbenchSnapshot(
        runtime,
        &workbench,
        "\"input\":{\"kind\":\"skill\"",
    );
    fake_core.lock();
    const skill_seen = fake_core.skill_run_seen;
    const input_matches = fake_core.skill_input_matches;
    fake_core.unlock();
    try std.testing.expect(skill_seen);
    try std.testing.expect(input_matches);
}

test "Workspace reauthorization reschedules the latest catalog query" {
    fake_core.reset();
    fake_core.setCatalogPlan(.controlled);
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
    var workbench = try workbench_api.Workbench.init(
        std.testing.allocator,
        runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 2,
            .max_workspaces = 1,
            .max_tasks = 1,
            .max_runs_per_task = 1,
            .max_tools_per_run = 1,
        },
        .{ .directories = .{ .canonical_user_home = home } },
    );
    defer workbench.deinit();
    defer fake_core.releaseCatalogQuery();
    try installWorkbenchExecution(&workbench);

    const workspace_id = try workbench.openWorkspace(workbenchTaskInput());
    fake_core.waitCatalogQueryEntered();
    try workbench.removeWorkspace(workspace_id);
    const reauthorized_id = try workbench.openWorkspace(workbenchTaskInput());
    try std.testing.expectEqual(workspace_id, reauthorized_id);
    try std.testing.expectEqual(
        workbench_api.CatalogAvailability.loading,
        (try workbench.workspaceCatalog(workspace_id)).availability,
    );

    fake_core.setCatalogPlan(.healthy);
    fake_core.releaseCatalogQuery();
    _ = try waitCatalogReady(&workbench, workspace_id);
    fake_core.lock();
    const catalog_queries = fake_core.catalog_queries;
    const catalog_releases = fake_core.catalog_releases;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 2), catalog_queries);
    try std.testing.expectEqual(@as(usize, 1), catalog_releases);
}

test "Workbench rejects stale Skill identity before Session or Run mutation and releases catalog on shutdown" {
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
    var workbench = try workbench_api.Workbench.init(
        std.testing.allocator,
        runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 2,
            .max_workspaces = 1,
            .max_tasks = 1,
            .max_runs_per_task = 1,
            .max_tools_per_run = 1,
        },
        .{ .directories = .{ .canonical_user_home = home } },
    );
    defer workbench.deinit();
    try installWorkbenchExecution(&workbench);

    const workspace_id = try workbench.openWorkspace(workbenchTaskInput());
    const catalog = try waitCatalogReady(&workbench, workspace_id);
    try std.testing.expectError(
        error.StaleCatalog,
        workbench.createTaskInWorkspace(
            workspace_id,
            try workbench.workspaceEpoch(workspace_id),
            1,
            "stale-revision",
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
        catalog.revision,
    );
    try std.testing.expectError(
        error.StaleCatalog,
        workbench.runTask(task_id, .{ .skill = .{
            .skill_id = fixture.fixture_skill_id,
            .catalog_revision = "stale-revision",
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
        .argument_values = &.{},
    } });
    try waitWorkbenchSnapshot(
        runtime,
        &workbench,
        "\"cause\":\"stale_catalog\"",
    );

    workbench.shutdownExecutor();
    try runtime.shutdown();
    fake_core.lock();
    const catalog_releases = fake_core.catalog_releases;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), catalog_releases);
}

test "Workbench refreshes a Task only from the committed Workspace catalog while idle" {
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
    var workbench = try workbench_api.Workbench.init(
        std.testing.allocator,
        runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 2,
            .max_workspaces = 1,
            .max_tasks = 1,
            .max_runs_per_task = 1,
            .max_tools_per_run = 1,
        },
        .{ .directories = .{ .canonical_user_home = home } },
    );
    defer workbench.deinit();
    try installWorkbenchExecution(&workbench);

    const workspace_id = try workbench.openWorkspace(workbenchTaskInput());
    try waitCatalogUnavailable(&workbench, workspace_id);
    fake_core.setNextPlan(.controlled);
    const task_id = try workbench.createTaskInWorkspace(
        workspace_id,
        try workbench.workspaceEpoch(workspace_id),
        1,
        null,
    );
    _ = try workbench.runTask(task_id, .{ .text = "hold refresh" });
    try waitWorkbenchSnapshot(
        runtime,
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
    try waitWorkbenchSnapshot(
        runtime,
        &workbench,
        "\"lastRunOutcome\":\"completed\"",
    );

    fake_core.setCatalogPlan(.healthy);
    const workspace_epoch = try workbench.workspaceEpoch(workspace_id);
    try workbench.refreshWorkspaceCatalog(workspace_id, workspace_epoch);
    _ = try waitCatalogReady(&workbench, workspace_id);
    try workbench.refreshTaskCatalog(
        task_id,
        try workbench.taskBindingEpoch(task_id),
    );
    fake_core.lock();
    const refreshes = fake_core.catalog_refreshes;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), refreshes);
}

test "Workbench closes off-thread and exposes retryable close failure" {
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
    }, workbenchConfiguration());
    defer workbench.deinit();
    try installWorkbenchExecution(&workbench);

    const task_id = try workbench.createTask(workbenchTaskInput());
    fake_core.failNextSessionDestroy();
    try workbench.closeTask(task_id);
    try waitWorkbenchSnapshot(runtime, &workbench, "\"closeFailed\":true");

    try workbench.closeTask(task_id);
    try waitWorkbenchSnapshot(runtime, &workbench, "\"lifecycle\":\"closed\"");
    fake_core.lock();
    const destroyed = fake_core.session_destroyed;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), destroyed);
}

test "Workbench close cancels a queued Run without blocking the caller" {
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
    }, workbenchConfiguration());
    defer workbench.deinit();
    try installWorkbenchExecution(&workbench);

    const task_id = try workbench.createTask(workbenchTaskInput());
    _ = try workbench.runTask(task_id, .{ .text = "close this run" });
    try workbench.closeTask(task_id);
    try waitWorkbenchSnapshot(runtime, &workbench, "\"lifecycle\":\"closed\"");
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
    var workbench = try workbench_api.Workbench.init(std.testing.allocator, runtime, .{
        .worker_count = 1,
        .queue_capacity = 2,
        .max_workspaces = 1,
        .max_tasks = 1,
        .max_runs_per_task = 1,
        .max_tools_per_run = 1,
    }, workbenchConfiguration());
    defer workbench.deinit();
    try installWorkbenchExecution(&workbench);

    const task_id = try workbench.createTask(workbenchTaskInput());
    const workspace_id = workbench.selectedWorkspaceId();
    _ = try workbench.runTask(
        task_id,
        .{ .text = "stop when the workspace is removed" },
    );
    try waitWorkbenchSnapshot(runtime, &workbench, "\"currentRunPhase\":\"running\"");

    try workbench.removeWorkspace(workspace_id);
    try waitWorkbenchSnapshot(runtime, &workbench, "\"lastRunOutcome\":\"interrupted\"");
    try waitWorkbenchSnapshot(runtime, &workbench, "\"lifecycle\":\"closed\"");

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
    var workbench = try workbench_api.Workbench.init(std.testing.allocator, runtime, .{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_workspaces = 1,
        .max_tasks = 1,
        .max_runs_per_task = 1,
        .max_tools_per_run = 1,
    }, workbenchConfiguration());
    defer workbench.deinit();
    try installWorkbenchExecution(&workbench);

    _ = try workbench.createTask(workbenchTaskInput());
    const workspace_id = workbench.selectedWorkspaceId();
    fake_core.failNextSessionDestroy();
    try workbench.removeWorkspace(workspace_id);
    try waitWorkbenchSnapshot(
        runtime,
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
    }, workbenchConfiguration());
    defer workbench.deinit();
    try installWorkbenchExecution(&workbench);

    const task_id = try workbench.createTask(workbenchTaskInput());
    const run_id = try workbench.runTask(
        task_id,
        .{ .text = "finish before cancel arrives" },
    );
    try waitWorkbenchSnapshot(runtime, &workbench, "\"lastRunOutcome\":\"completed\"");
    const revision = workbench.currentRevision();
    try workbench.cancel(task_id, run_id);
    try std.testing.expectEqual(revision, workbench.currentRevision());
    try waitWorkbenchSnapshot(runtime, &workbench, "\"lastRunOutcome\":\"completed\"");

    try workbench.closeTask(task_id);
    try waitWorkbenchSnapshot(runtime, &workbench, "\"lifecycle\":\"closed\"");
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
    }, workbenchConfiguration());
    defer workbench.deinit();
    try installWorkbenchExecution(&workbench);

    const task_id = try workbench.createTask(workbenchTaskInput());
    _ = try workbench.runTask(task_id, .{ .text = "wait for shutdown" });
    try waitWorkbenchSnapshot(runtime, &workbench, "\"currentRunPhase\":\"waiting_ui\"");
    workbench.shutdownExecutor();
    try waitWorkbenchSnapshot(runtime, &workbench, "\"lastRunOutcome\":\"interrupted\"");
    try waitWorkbenchSnapshot(runtime, &workbench, "\"continuationAvailable\":false");
}

test "Workbench shutdown rejects new Task admission without creating product state" {
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
    }, workbenchConfiguration());
    defer workbench.deinit();

    workbench.shutdownExecutor();
    try std.testing.expectError(
        error.ExecutorShuttingDown,
        workbench.createTask(workbenchTaskInput()),
    );
    try std.testing.expectEqual(@as(u64, 0), workbench.currentRevision());

    var snapshot_storage: [4096]u8 = undefined;
    const snapshot = try workbench.writeSnapshot(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"tasks\":[]") != null);
}

test "late event from a finalized Run closes a Task with newer active work" {
    fake_core.reset();
    fake_core.setNextPlan(.controlled);
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var workbench = try workbench_api.Workbench.init(std.testing.allocator, runtime, .{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_tasks = 1,
        .max_runs_per_task = 2,
        .max_tools_per_run = 1,
    }, workbenchConfiguration());
    defer workbench.deinit();
    try installWorkbenchExecution(&workbench);

    const task_id = try workbench.createTask(workbenchTaskInput());
    const first_run_id = try workbench.runTask(
        task_id,
        .{ .text = "finish first" },
    );
    try waitWorkbenchSnapshot(runtime, &workbench, "\"currentRunPhase\":\"running\"");
    fake_core.releaseControlled();
    try waitWorkbenchSnapshot(runtime, &workbench, "\"lastRunOutcome\":\"completed\"");

    fake_core.rearmControlled();
    _ = try workbench.runTask(task_id, .{ .text = "new active work" });
    try waitWorkbenchSnapshot(runtime, &workbench, "\"currentRunPhase\":\"running\"");

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
    try std.testing.expectError(
        error.EventAfterTerminalDrain,
        workbench.applyEvent(&late_event),
    );

    var snapshot_storage: [128 * 1024]u8 = undefined;
    const closing_snapshot = try workbench.writeSnapshot(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(u8, closing_snapshot, "\"lifecycle\":\"closing\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, closing_snapshot, "\"continuationAvailable\":false") != null);
    try waitWorkbenchSnapshot(runtime, &workbench, "\"lifecycle\":\"closed\"");
}
