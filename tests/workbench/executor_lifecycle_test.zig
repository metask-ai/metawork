const fixture = @import("lifecycle_fixture");
const std = fixture.std;
const lifecycle = fixture.lifecycle;
const workbench_api = fixture.workbench_api;
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
const workbenchConfiguration = fixture.workbenchConfiguration;
const workbenchTaskInput = fixture.workbenchTaskInput;
const waitWorkbenchSnapshot = fixture.waitWorkbenchSnapshot;
const installWorkbenchExecution = fixture.installWorkbenchExecution;

const ShutdownContext = struct {
    workbench: *workbench_api.Workbench,

    fn run(self: *@This()) void {
        self.workbench.shutdownExecutor();
    }
};

const TaskPersistenceProbe = struct {
    result: workbench_api.TaskPersistenceCommit = .committed,
    storage: ?[]u8 = null,
    len: usize = 0,
    commits: usize = 0,

    fn commit(context: ?*anyopaque, bytes: []const u8) workbench_api.TaskPersistenceCommit {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.commits += 1;
        if (self.result == .committed) if (self.storage) |storage| {
            if (bytes.len > storage.len) return .failed;
            @memcpy(storage[0..bytes.len], bytes);
            self.len = bytes.len;
        };
        return self.result;
    }

    fn capability(self: *@This()) workbench_api.TaskPersistence {
        return .{
            .context = self,
            .enabled = true,
            .commit_fn = commit,
        };
    }

    fn capabilityRestored(
        self: *@This(),
        restored_bytes: []const u8,
    ) workbench_api.TaskPersistence {
        var result = self.capability();
        result.restored_bytes = restored_bytes;
        return result;
    }
};

fn expectFakeSessionModel(index: usize, expected: []const u8) !void {
    const session = &fake_core.sessions[index];
    session.lock();
    defer session.unlock();
    try std.testing.expectEqualStrings(expected, session.model[0..session.model_len]);
}

fn installTwoModelCatalog(workbench: *workbench_api.Workbench) void {
    const api_keys = [_]account_contract.ApiKeyView{.{
        .id = "key-1",
        .name = "Fixture API",
        .suffix = "ture",
        .provider_kind = .anthropic,
    }};
    const models = [_]account_contract.ModelView{
        .{ .id = "fixture-model", .display_name = "Fixture model" },
        .{ .id = "fixture-model-2", .display_name = "Fixture model 2" },
    };
    workbench.commitAccountFactNoFail(.{
        .kind = .catalog_changed,
        .view = .{
            .state = .authenticated,
            .catalog_state = .ready,
            .account_id = "account-1",
            .display_name = "Fixture User",
            .api_keys = &api_keys,
            .models = &models,
            .selected_api_key_id = "key-1",
            .selected_model = "fixture-model",
            .model_catalog_api_key_id = "key-1",
            .can_create_task = true,
            .catalog_generation = 2,
            .metask_execution_generation = 1,
            .execution_generation = 1,
        },
    });
    workbench.finishAccountCommitNoFail();
}

fn waitCatalogReady(
    workbench: *workbench_api.Workbench,
    workspace_id: u64,
) !workbench_api.CatalogProjection {
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
    workbench: *workbench_api.Workbench,
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

fn waitSetTaskArchived(workbench: *workbench_api.Workbench, task_id: u64) !void {
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

fn waitTaskDeleted(workbench: *workbench_api.Workbench, task_id: u64) !void {
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
    workbench: *workbench_api.Workbench,
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
    workbench: *workbench_api.Workbench,
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

test "Workbench Task admission consumes the fixed MetaWork Agent tool surface" {
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
    var workbench = try workbench_api.Workbench.init(
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
        workbenchConfiguration(),
    );
    defer workbench.deinit();
    try installWorkbenchExecution(&workbench);
    _ = try workbench.createTask(workbenchTaskInput());

    try std.testing.expect(fake_core.builtin_allowlist_seen);
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
        product_task.persistence.max_store_bytes,
    );
    defer std.testing.allocator.free(persistence_storage);
    var persistence = TaskPersistenceProbe{ .storage = persistence_storage };
    var configuration = workbenchConfiguration();
    configuration.task_persistence = persistence.capability();
    configuration.checkpoint_store = .{ .file_store = &checkpoint_store };
    var workbench = try workbench_api.Workbench.init(
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
    try installWorkbenchExecution(&workbench);
    const task_id = try workbench.createTask(workbenchTaskInput());
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
    var restart_configuration = workbenchConfiguration();
    restart_configuration.task_persistence = persistence.capabilityRestored(restart_history);
    restart_configuration.checkpoint_store = .{ .file_store = &checkpoint_store };
    var restored = try workbench_api.Workbench.init(
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
    var missing_configuration = workbenchConfiguration();
    missing_configuration.task_persistence = persistence.capabilityRestored(restart_history);
    missing_configuration.checkpoint_store = .{ .file_store = &checkpoint_store };
    var missing_restored = try workbench_api.Workbench.init(
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

test "restart restores a Task attachment and continues the same Conversation" {
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
    var skill_enablement_store = try workbench_api.SkillEnablementFileStore.init(
        std.testing.io,
        skill_enablement_root_storage[0..skill_enablement_root_len],
    );
    defer skill_enablement_store.deinit();
    const persistence_storage = try std.testing.allocator.alloc(
        u8,
        product_task.persistence.max_store_bytes,
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
    var first_configuration = workbenchConfiguration();
    first_configuration.directories.canonical_user_home = home;
    first_configuration.task_persistence = persistence.capability();
    first_configuration.checkpoint_store = .{ .file_store = &checkpoint_store };
    first_configuration.skill_enablement = .{ .file_store = &skill_enablement_store };
    var first = try workbench_api.Workbench.init(
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
    try installWorkbenchExecution(&first);
    const workspace_id = try first.openWorkspace(workbenchTaskInput());
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
        catalog.revision,
        catalog.selection_revision,
    );
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
    var second_configuration = workbenchConfiguration();
    second_configuration.directories.canonical_user_home = home;
    second_configuration.task_persistence = persistence.capabilityRestored(restart_history);
    second_configuration.checkpoint_store = .{ .file_store = &checkpoint_store };
    second_configuration.skill_enablement = .{
        .file_store = &skill_enablement_store,
        .restored_bytes = restored_enablement,
    };
    var restored = try workbench_api.Workbench.init(
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
    try installWorkbenchExecution(&restored);
    // A persisted manual Workspace deliberately restarts without authority.
    // Reopening it models the user's explicit reauthorization action.
    try std.testing.expectEqual(
        workspace_id,
        try restored.openWorkspace(workbenchTaskInput()),
    );
    _ = try waitCatalogReady(&restored, workspace_id);
    try waitTaskSnapshot(
        &restored,
        "\"id\":\"1\"",
        "\"continuationRecoveryAvailable\":true",
    );
    fake_core.setCatalogPlan(.query_failure);
    _ = try restored.restoreTaskConversation(
        task_id,
        try restored.taskBindingEpoch(task_id),
    );
    try waitTaskSnapshot(
        &restored,
        "\"id\":\"1\"",
        "\"continuationUnavailableReason\":\"session_recovery_failed\"",
    );
    fake_core.setCatalogPlan(.healthy);
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
        "\"continuationAvailable\":true",
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
        "\"id\":\"2\"",
        "\"phase\":\"completed\"",
    );
    fake_core.lock();
    const restore_calls = fake_core.checkpoint_restores;
    const run_calls = fake_core.run_calls;
    const credential_seen = fake_core.credential_seen;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 2), restore_calls);
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

    var third_configuration = workbenchConfiguration();
    third_configuration.directories.canonical_user_home = home;
    third_configuration.task_persistence = persistence.capabilityRestored(restart_history);
    third_configuration.checkpoint_store = .{ .file_store = &checkpoint_store };
    third_configuration.skill_enablement = .{
        .file_store = &skill_enablement_store,
        .restored_bytes = restored_enablement,
    };
    var shutdown_restore = try workbench_api.Workbench.init(
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
    defer shutdown_restore.deinit();
    try installWorkbenchExecution(&shutdown_restore);
    try std.testing.expectEqual(
        workspace_id,
        try shutdown_restore.openWorkspace(workbenchTaskInput()),
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
    const restore_job = shutdown_restore.tasks[0].?.runtime.restore_job.?;
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
        if (restore_job.cancellation.load(.acquire)) break;
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
        product_task.persistence.max_store_bytes,
    );
    defer std.testing.allocator.free(persistence_storage);
    var persistence = TaskPersistenceProbe{ .storage = persistence_storage };
    var configuration = workbenchConfiguration();
    configuration.task_persistence = persistence.capability();
    configuration.checkpoint_store = .{ .file_store = &checkpoint_store };
    var workbench = try workbench_api.Workbench.init(
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
    try installWorkbenchExecution(&workbench);
    const task_id = try workbench.createTask(workbenchTaskInput());
    _ = try workbench.runTask(task_id, .{ .text = "cancel checkpoint export" });
    fake_core.waitCheckpointExportEntered();
    try waitWorkbenchSnapshot(&workbench, "\"lastRunOutcome\":\"completed\"");
    try workbench.setTaskArchived(task_id, true);
    try workbench.deleteTask(task_id);
    try waitWorkbenchSnapshot(&workbench, "\"deletionStatus\":\"deleting\"");
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
        product_task.persistence.max_store_bytes,
    );
    defer std.testing.allocator.free(persistence_storage);
    var persistence = TaskPersistenceProbe{ .storage = persistence_storage };
    var configuration = workbenchConfiguration();
    configuration.task_persistence = persistence.capability();
    configuration.checkpoint_store = .{ .file_store = &checkpoint_store };
    var workbench = try workbench_api.Workbench.init(
        std.testing.allocator,
        std.testing.io,
        runtime,
        .{ .worker_count = 1, .queue_capacity = 1, .max_tasks = 1, .max_runs_per_task = 1, .max_tools_per_run = 1 },
        configuration,
    );
    var initialized = true;
    defer if (initialized) workbench.deinit();
    try installWorkbenchExecution(&workbench);
    const task_id = try workbench.createTask(workbenchTaskInput());
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
    const durable_terminal = persistence_storage[0..persistence.len];
    try std.testing.expect(std.mem.indexOf(u8, durable_terminal, "\"phase\":\"completed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, durable_terminal, "\"checkpoint\":null") != null);

    workbench.deinit();
    initialized = false;
    persistence.result = .committed;
    var restart_configuration = workbenchConfiguration();
    restart_configuration.task_persistence = persistence.capabilityRestored(durable_terminal);
    restart_configuration.checkpoint_store = .{ .file_store = &checkpoint_store };
    var restored = try workbench_api.Workbench.init(
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

test "unknown descriptor commit freezes checkpoint transaction until shutdown" {
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
        product_task.persistence.max_store_bytes,
    );
    defer std.testing.allocator.free(persistence_storage);
    var persistence = TaskPersistenceProbe{ .storage = persistence_storage };
    var configuration = workbenchConfiguration();
    configuration.task_persistence = persistence.capability();
    configuration.checkpoint_store = .{ .file_store = &checkpoint_store };
    var workbench = try workbench_api.Workbench.init(
        std.testing.allocator,
        std.testing.io,
        runtime,
        .{ .worker_count = 1, .queue_capacity = 1, .max_tasks = 1, .max_runs_per_task = 1, .max_tools_per_run = 1 },
        configuration,
    );
    var initialized = true;
    defer if (initialized) workbench.deinit();
    try installWorkbenchExecution(&workbench);
    const task_id = try workbench.createTask(workbenchTaskInput());
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
    var transaction_frozen = false;
    for (0..10_000) |_| {
        checkpoint_store.verify(identity) catch {
            std.Thread.yield() catch {};
            continue;
        };
        const snapshot_json = try workbench.writeSnapshot(&snapshot);
        if (std.mem.indexOf(u8, snapshot_json, "\"taskHistoryPersistenceHealth\":\"outcome_unknown\"") != null) {
            transaction_frozen = true;
            break;
        }
        std.Thread.yield() catch {};
    }
    try std.testing.expect(transaction_frozen);
    try checkpoint_store.verify(identity);
    try std.testing.expectError(error.TaskPersistenceOutcomeUnknown, workbench.deleteTask(task_id));
    try std.testing.expectError(
        error.TaskPersistenceOutcomeUnknown,
        workbench.setTaskArchived(task_id, true),
    );
    const frozen_revision = workbench.currentRevision();
    for (0..3) |_| {
        _ = try workbench.writeSnapshot(&snapshot);
        try std.testing.expectEqual(frozen_revision, workbench.currentRevision());
    }

    workbench.deinit();
    initialized = false;
    try checkpoint_store.verify(identity);
}

test "untrusted Task history never opens checkpoint orphan cleanup" {
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
    var configuration = workbenchConfiguration();
    configuration.task_persistence = persistence.capabilityRestored("{");
    configuration.checkpoint_store = .{ .file_store = &checkpoint_store };
    var workbench = try workbench_api.Workbench.init(
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
    var configuration = workbenchConfiguration();
    configuration.checkpoint_store = .{ .open_failed = true };
    var workbench = try workbench_api.Workbench.init(
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
    try installWorkbenchExecution(&workbench);
    const task_id = try workbench.createTask(workbenchTaskInput());
    _ = try workbench.runTask(task_id, .{ .text = "checkpoint store unavailable" });
    try waitWorkbenchSnapshot(&workbench, "\"lastRunOutcome\":\"completed\"");
    try std.testing.expectEqual(@as(usize, 1), fake_core.session_created);
    try std.testing.expectEqual(@as(usize, 0), fake_core.checkpoint_exports);
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
    ) workbench_api.SchedulePersistenceCommit {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        std.debug.assert(bytes.len != 0);
        self.commits += 1;
        return .committed;
    }

    fn timer(self: *@This()) workbench_api.ScheduleTimer {
        return .{
            .context = self,
            .enabled = true,
            .now_unix_seconds = nowUnixSeconds,
            .arm = arm,
            .cancel = cancel,
        };
    }

    fn persistence(self: *@This()) workbench_api.SchedulePersistence {
        return .{
            .context = self,
            .enabled = true,
            .commit_fn = commit,
        };
    }
};

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

test "Workbench pins an async catalog and admits typed Skill through the existing executor" {
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
    var skill_enablement_store = try workbench_api.SkillEnablementFileStore.init(
        std.testing.io,
        home,
    );
    defer skill_enablement_store.deinit();
    var workbench = try workbench_api.Workbench.init(
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
        },
    );
    defer workbench.deinit();
    try installWorkbenchExecution(&workbench);

    const workspace_id = try workbench.openWorkspace(workbenchTaskInput());
    const catalog = try waitCatalogReady(&workbench, workspace_id);
    try std.testing.expectEqual(workbench_api.CatalogAvailability.degraded, catalog.availability);
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
        catalog.revision,
        catalog.selection_revision,
    );
    const task_catalog = try workbench.taskCatalog(task_id);
    try std.testing.expectEqualStrings(catalog.revision, task_catalog.revision);
    _ = try workbench.runTask(task_id, .{ .skill = .{
        .skill_id = fixture.fixture_skill_id,
        .catalog_revision = catalog.revision,
        .selection_revision = catalog.selection_revision.?,
        .argument_values = &.{ "src/main.zig", "correctness" },
    } });
    try waitWorkbenchSnapshot(
        &workbench,
        "\"lastRunOutcome\":\"completed\"",
    );
    try waitWorkbenchSnapshot(
        &workbench,
        "\"skillCatalog\":{\"availability\":\"degraded\"",
    );
    try waitWorkbenchSnapshot(
        &workbench,
        "\"input\":{\"kind\":\"skill\"",
    );
    try waitWorkbenchSnapshot(&workbench, "\"title\":\"Review\"");
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
    var skill_enablement_store = try workbench_api.SkillEnablementFileStore.init(
        std.testing.io,
        home,
    );
    defer skill_enablement_store.deinit();
    var workbench = try workbench_api.Workbench.init(
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
        },
    );
    defer workbench.deinit();
    try installWorkbenchExecution(&workbench);

    const workspace_id = try workbench.openWorkspace(workbenchTaskInput());
    const before = try waitCatalogReady(&workbench, workspace_id);
    fake_core.setCatalogPlan(.controlled);
    defer fake_core.releaseCatalogQuery();
    const workspace_epoch = try workbench.workspaceEpoch(workspace_id);
    try workbench.refreshWorkspaceCatalog(workspace_id, workspace_epoch);
    fake_core.waitCatalogQueryEntered();
    const refresh_revision = workbench.currentRevision();
    const refreshing = try workbench.workspaceCatalog(workspace_id);
    try std.testing.expectEqual(workbench_api.CatalogAvailability.ready, refreshing.availability);
    try std.testing.expectEqualStrings(before.revision, refreshing.revision);
    try std.testing.expectEqual(before.selection_revision, refreshing.selection_revision);

    fake_core.setCatalogPlan(.query_incomplete);
    fake_core.releaseCatalogQuery();
    for (0..10_000) |_| {
        if (workbench.currentRevision() > refresh_revision) break;
        std.testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
    } else return error.TestUnexpectedResult;

    const after = try workbench.workspaceCatalog(workspace_id);
    try std.testing.expectEqual(workbench_api.CatalogAvailability.ready, after.availability);
    try std.testing.expectEqualStrings(before.revision, after.revision);
    try std.testing.expectEqual(before.selection_revision, after.selection_revision);
    try std.testing.expectEqual(before.skills.len, after.skills.len);
    try std.testing.expectEqualStrings(before.skills[0].skill_id, after.skills[0].skill_id);
}

test "Manual Task persistence failure rolls back Workspace recent order" {
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
    var configuration = workbenchConfiguration();
    configuration.task_persistence = persistence.capability();
    var workbench = try workbench_api.Workbench.init(
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
    try installWorkbenchExecution(&workbench);
    const workspace_id = try workbench.openWorkspace(workbenchTaskInput());
    var projection_storage: [1]workbench_api.WorkspaceProjection = undefined;
    const before = try workbench.copyWorkspaceProjections(&projection_storage);
    const recent_order = before[0].recent_order;
    const epoch = before[0].epoch;

    persistence.result = .failed;
    try std.testing.expectError(
        error.TaskPersistenceFailed,
        workbench.createTaskForWorkspace(
            .{ .manual = .{
                .workspace_id = workspace_id,
                .expected_epoch = epoch,
            } },
            1,
            null,
            null,
        ),
    );
    const after = try workbench.copyWorkspaceProjections(&projection_storage);
    try std.testing.expectEqual(recent_order, after[0].recent_order);
    var snapshot_storage: [128 * 1024]u8 = undefined;
    const snapshot = try workbench.writeSnapshot(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"tasks\":[]") != null);
}

test "Idle Task model persistence failure restores Session and detaches on unknown outcome" {
    fake_core.reset();
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 2,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const persistence_storage = try std.testing.allocator.alloc(
        u8,
        product_task.persistence.max_store_bytes,
    );
    defer std.testing.allocator.free(persistence_storage);
    var persistence = TaskPersistenceProbe{ .storage = persistence_storage };
    {
        var configuration = workbenchConfiguration();
        configuration.task_persistence = persistence.capability();
        var workbench = try workbench_api.Workbench.init(
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
        try installWorkbenchExecution(&workbench);
        installTwoModelCatalog(&workbench);
        const task_id = try workbench.createTask(workbenchTaskInput());
        const before = try workbench.taskExecutionIdentity(task_id);
        const projection_before = workbench.projectionBytesForTest();
        try expectFakeSessionModel(0, "fixture-model");
        persistence.result = .failed;
        try std.testing.expectError(
            error.TaskPersistenceFailed,
            workbench.selectTaskModel(task_id, before.model, 2, "fixture-model-2"),
        );
        const after = try workbench.taskExecutionIdentity(task_id);
        try std.testing.expectEqualStrings("fixture-model", after.model);
        try expectFakeSessionModel(0, "fixture-model");
        try std.testing.expectEqual(projection_before, workbench.projectionBytesForTest());
    }

    persistence.result = .committed;
    {
        var configuration = workbenchConfiguration();
        configuration.task_persistence = persistence.capability();
        var workbench = try workbench_api.Workbench.init(
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
        try installWorkbenchExecution(&workbench);
        installTwoModelCatalog(&workbench);
        const task_id = try workbench.createTask(workbenchTaskInput());
        const before = try workbench.taskExecutionIdentity(task_id);
        const projection_before = workbench.projectionBytesForTest();
        persistence.result = .outcome_unknown;
        try std.testing.expectError(
            error.TaskPersistenceOutcomeUnknown,
            workbench.selectTaskModel(task_id, before.model, 2, "fixture-model-2"),
        );
        const after = try workbench.taskExecutionIdentity(task_id);
        try std.testing.expectEqualStrings("fixture-model", after.model);
        try std.testing.expectEqual(projection_before, workbench.projectionBytesForTest());
        var snapshot_storage: [128 * 1024]u8 = undefined;
        const snapshot = try workbench.writeSnapshot(&snapshot_storage);
        const task_start = std.mem.indexOf(u8, snapshot, "\"id\":\"1\"") orelse
            return error.TestUnexpectedResult;
        try std.testing.expect(
            std.mem.indexOf(
                u8,
                snapshot[task_start..],
                "\"unavailableReason\":\"runtime_detached\"",
            ) != null,
        );
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
    var automatic_root = try workbench_api.AutomaticWorkspaceRoot.open(
        std.testing.io,
        std.testing.allocator,
        root_storage[0..root_len],
    );
    defer automatic_root.deinit();
    var workbench = try workbench_api.Workbench.init(
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
            .directories = .{ .automatic_workspace_root = &automatic_root },
            .completion_factory = .{ .create_fn = fixture.createCompletion },
        },
    );
    defer workbench.deinit();
    try installWorkbenchExecution(&workbench);

    _ = try workbench.openWorkspace(workbenchTaskInput());
    var user_projection_storage: [3]workbench_api.WorkspaceProjection = undefined;
    const before = try workbench.copyWorkspaceProjections(&user_projection_storage);
    const manual_recent_order = before[0].recent_order;

    const first_task = try workbench.createTaskForWorkspace(
        .automatic,
        1,
        null,
        null,
    );
    const first_workspace = try workbench.taskWorkspaceId(first_task);
    try std.testing.expectEqual(
        workbench_api.WorkspaceKind.automatic,
        try workbench.workspaceKind(first_workspace),
    );
    try std.testing.expectEqual(
        workbench_api.CatalogAvailability.uninitialized,
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
            null,
            null,
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
        null,
        null,
    );
    const second_workspace = try workbench.taskWorkspaceId(second_task);
    try std.testing.expect(first_workspace != second_workspace);
    try std.testing.expectEqual(@as(usize, 2), try directoryEntryCount(tmp.dir));

    try workbench.renameTask(second_task, "Preset title");
    _ = try workbench.runTask(second_task, .{ .text = "must not replace preset" });
    try waitWorkbenchSnapshot(&workbench, "\"lastRunOutcome\":\"completed\"");
    var preset_title_snapshot: [128 * 1024]u8 = undefined;
    const preset_title_snapshot_bytes = try workbench.writeSnapshot(&preset_title_snapshot);
    try std.testing.expect(
        std.mem.indexOf(u8, preset_title_snapshot_bytes, "\"title\":\"Preset title\"") != null,
    );

    fake_core.setCompletionTitle("Generated task title");
    fake_core.setSessionPlan(.controlled);
    _ = try workbench.runTask(first_task, .{ .text = "automatic text run" });
    try waitWorkbenchSnapshot(&workbench, "\"currentRunPhase\":\"running\"");
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
    try waitWorkbenchSnapshot(&workbench, "\"lastRunOutcome\":\"completed\"");
    try waitWorkbenchSnapshot(&workbench, "\"title\":\"Generated task title\"");
    var title_snapshot: [128 * 1024]u8 = undefined;
    const title_snapshot_bytes = try workbench.writeSnapshot(&title_snapshot);
    try std.testing.expect(
        std.mem.indexOf(u8, title_snapshot_bytes, "\"title\":\"Generated task title\"") != null,
    );
    fake_core.lock();
    const completion_requests = fake_core.completion_requests;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), completion_requests);
    try waitSetTaskArchived(&workbench, first_task);
    try workbench.deleteTask(first_task);
    try waitTaskDeleted(&workbench, first_task);
    try std.testing.expectError(
        error.UnknownWorkspace,
        workbench.workspaceEpoch(first_workspace),
    );
    try std.testing.expectEqual(@as(usize, 2), try directoryEntryCount(tmp.dir));
    try std.testing.expectEqual(
        workbench_api.WorkspaceKind.automatic,
        try workbench.workspaceKind(second_workspace),
    );
    try std.testing.expectEqual(
        workbench_api.CatalogAvailability.uninitialized,
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
    var automatic_root = try workbench_api.AutomaticWorkspaceRoot.open(
        std.testing.io,
        std.testing.allocator,
        root_storage[0..root_len],
    );
    defer automatic_root.deinit();
    var workbench = try workbench_api.Workbench.init(
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
        .{ .directories = .{ .automatic_workspace_root = &automatic_root } },
    );
    defer workbench.deinit();
    try installWorkbenchExecution(&workbench);
    _ = try workbench.createTask(workbenchTaskInput());
    const revision = workbench.currentRevision();

    try std.testing.expectError(
        error.TaskCapacity,
        workbench.createTaskForWorkspace(.automatic, 1, null, null),
    );
    try std.testing.expectEqual(revision, workbench.currentRevision());
    try std.testing.expectEqual(@as(usize, 0), try directoryEntryCount(tmp.dir));
}

test "Text schedule default creates a fresh automatic Workspace per occurrence" {
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
    var automatic_root = try workbench_api.AutomaticWorkspaceRoot.open(
        std.testing.io,
        std.testing.allocator,
        root_storage[0..root_len],
    );
    defer automatic_root.deinit();
    var schedule_support: TestScheduleSupport = .{};
    var workbench = try workbench_api.Workbench.init(
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
            .directories = .{ .automatic_workspace_root = &automatic_root },
            .schedule_timer = schedule_support.timer(),
            .schedule_persistence = schedule_support.persistence(),
        },
    );
    defer workbench.deinit();
    try installWorkbenchExecution(&workbench);

    const default_schedule = try workbench.createScheduledTask(.{
        .title = "Independent brief",
        .expected_execution_generation = 1,
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
            .expected_execution_generation = 1,
            .input = "",
            .recurrence = .{ .once = .{ .at_unix_seconds = 2_000 } },
        }),
    );
    try std.testing.expectEqual(commits_before_rejection, schedule_support.commits);

    const first_task = try workbench.runScheduledTaskNow(default_schedule, 1);
    const first_workspace = try workbench.taskWorkspaceId(first_task);
    try std.testing.expectEqual(
        workbench_api.WorkspaceKind.automatic,
        try workbench.workspaceKind(first_workspace),
    );
    try waitWorkbenchSnapshot(&workbench, "\"taskOutcome\":\"completed\"");

    const second_task = try workbench.runScheduledTaskNow(default_schedule, 1);
    const second_workspace = try workbench.taskWorkspaceId(second_task);
    try std.testing.expect(first_task != second_task);
    try std.testing.expect(first_workspace != second_workspace);
    try std.testing.expectEqual(
        workbench_api.WorkspaceKind.automatic,
        try workbench.workspaceKind(second_workspace),
    );
    var projection_storage: [2]workbench_api.WorkspaceProjection = undefined;
    const projections = try workbench.copyWorkspaceProjections(
        &projection_storage,
    );
    try std.testing.expectEqual(@as(usize, 2), projections.len);
    for (projections) |workspace| {
        try std.testing.expectEqual(
            workbench_api.WorkspaceKind.automatic,
            workspace.kind,
        );
        try std.testing.expectEqual(@as(u64, 0), workspace.recent_order);
    }

    try std.testing.expectEqual(@as(usize, 2), try directoryEntryCount(tmp.dir));
    var snapshot_storage: [128 * 1024]u8 = undefined;
    const snapshot = try workbench.writeSnapshot(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"target\"") == null);
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
    var automatic_root = try workbench_api.AutomaticWorkspaceRoot.open(
        std.testing.io,
        std.testing.allocator,
        root_storage[0..root_len],
    );
    defer automatic_root.deinit();
    var schedule_support: TestScheduleSupport = .{};
    var workbench = try workbench_api.Workbench.init(
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
            .directories = .{ .automatic_workspace_root = &automatic_root },
            .schedule_timer = schedule_support.timer(),
            .schedule_persistence = schedule_support.persistence(),
        },
    );
    defer workbench.deinit();
    try installWorkbenchExecution(&workbench);

    const schedule_id = try workbench.createScheduledTask(.{
        .title = "Queued brief",
        .expected_execution_generation = 1,
        .input = "Summarize current work",
        .recurrence = .{ .once = .{ .at_unix_seconds = 2_000 } },
    });
    fake_core.setNextPlan(.controlled);
    defer fake_core.releaseControlled();
    const running_task = try workbench.createTaskForWorkspace(.automatic, 1, null, null);
    const queued_task = try workbench.createTaskForWorkspace(.automatic, 1, null, null);
    _ = try workbench.runTask(running_task, .{ .text = "hold worker" });
    try waitWorkbenchSnapshot(
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
    var skill_enablement_store = try workbench_api.SkillEnablementFileStore.init(
        std.testing.io,
        home,
    );
    defer skill_enablement_store.deinit();
    var workbench = try workbench_api.Workbench.init(
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
        },
    );
    defer workbench.deinit();
    defer fake_core.releaseCatalogQuery();
    try installWorkbenchExecution(&workbench);

    for (0..10_000) |_| {
        const personal = workbench.skillCatalog();
        if (personal.availability == .ready or personal.availability == .degraded)
            break;
        std.testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
    } else return error.TestUnexpectedResult;
    fake_core.setCatalogPlan(.controlled);

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
    try std.testing.expectEqual(@as(usize, 3), catalog_queries);
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
    var skill_enablement_store = try workbench_api.SkillEnablementFileStore.init(
        std.testing.io,
        home,
    );
    defer skill_enablement_store.deinit();
    var workbench = try workbench_api.Workbench.init(
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
        },
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
            catalog.selection_revision,
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
        catalog.selection_revision,
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
    try waitWorkbenchSnapshot(
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
    var skill_enablement_store = try workbench_api.SkillEnablementFileStore.init(
        std.testing.io,
        home,
    );
    defer skill_enablement_store.deinit();
    var workbench = try workbench_api.Workbench.init(
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
        },
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
        null,
    );
    _ = try workbench.runTask(task_id, .{ .text = "hold refresh" });
    try waitWorkbenchSnapshot(
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

test "Task deletion retries an off-thread Session release failure" {
    fake_core.reset();
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 2, .max_sessions = 2 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var workbench = try workbench_api.Workbench.init(std.testing.allocator, std.testing.io, runtime, .{
        .max_tasks = 2,
        .max_runs_per_task = 2,
        .max_tools_per_run = 2,
    }, workbenchConfiguration());
    defer workbench.deinit();
    try installWorkbenchExecution(&workbench);

    const task_id = try workbench.createTask(workbenchTaskInput());
    try workbench.setTaskArchived(task_id, true);
    fake_core.failNextSessionDestroy();
    try workbench.deleteTask(task_id);
    try waitWorkbenchSnapshot(&workbench, "\"deletionStatus\":\"failed\"");

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
        product_task.persistence.max_store_bytes,
    );
    defer std.testing.allocator.free(persistence_storage);
    var persistence = TaskPersistenceProbe{ .storage = persistence_storage };
    var configuration = workbenchConfiguration();
    configuration.task_persistence = persistence.capability();
    var workbench = try workbench_api.Workbench.init(
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
    try installWorkbenchExecution(&workbench);

    const task_id = try workbench.createTask(workbenchTaskInput());
    try workbench.setTaskArchived(task_id, true);
    persistence.result = .failed;
    try workbench.deleteTask(task_id);
    try waitWorkbenchSnapshot(&workbench, "\"deletionStatus\":\"failed\"");
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
    var workbench = try workbench_api.Workbench.init(std.testing.allocator, std.testing.io, runtime, .{
        .max_tasks = 1,
        .max_runs_per_task = 1,
        .max_tools_per_run = 1,
    }, workbenchConfiguration());
    defer workbench.deinit();
    try installWorkbenchExecution(&workbench);

    const task_id = try workbench.createTask(workbenchTaskInput());
    const run_id = try workbench.runTask(task_id, .{ .text = "finish before deletion" });
    try workbench.cancel(task_id, run_id);
    try waitWorkbenchSnapshot(&workbench, "\"lastRunOutcome\":\"cancelled\"");
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
    var workbench = try workbench_api.Workbench.init(std.testing.allocator, std.testing.io, runtime, .{
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
    const workspace_id = try workbench.taskWorkspaceId(task_id);
    _ = try workbench.runTask(
        task_id,
        .{ .text = "stop when the workspace is removed" },
    );
    try waitWorkbenchSnapshot(&workbench, "\"currentRunPhase\":\"running\"");

    try workbench.removeWorkspace(workspace_id);
    try waitWorkbenchSnapshot(&workbench, "\"lastRunOutcome\":\"interrupted\"");
    try waitWorkbenchSnapshot(&workbench, "\"lifecycle\":\"open\"");

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
    var workbench = try workbench_api.Workbench.init(std.testing.allocator, std.testing.io, runtime, .{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_workspaces = 1,
        .max_tasks = 1,
        .max_runs_per_task = 1,
        .max_tools_per_run = 1,
    }, workbenchConfiguration());
    defer workbench.deinit();
    try installWorkbenchExecution(&workbench);

    const task_id = try workbench.createTask(workbenchTaskInput());
    const workspace_id = try workbench.taskWorkspaceId(task_id);
    fake_core.failNextSessionDestroy();
    try workbench.removeWorkspace(workspace_id);
    try waitWorkbenchSnapshot(
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
    var workbench = try workbench_api.Workbench.init(std.testing.allocator, std.testing.io, runtime, .{
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
    try waitWorkbenchSnapshot(&workbench, "\"lastRunOutcome\":\"completed\"");
    const revision = workbench.currentRevision();
    try workbench.cancel(task_id, run_id);
    try std.testing.expectEqual(revision, workbench.currentRevision());
    try waitWorkbenchSnapshot(&workbench, "\"lastRunOutcome\":\"completed\"");
}

test "Workbench manual compact uses the active operation lane and appends history" {
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
    var workbench = try workbench_api.Workbench.init(
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
        workbenchConfiguration(),
    );
    defer workbench.deinit();
    try installWorkbenchExecution(&workbench);

    const task_id = try workbench.createTask(workbenchTaskInput());
    try std.testing.expectError(
        error.NoSuchRun,
        workbench.compactTaskAtBinding(task_id, 1),
    );
    _ = try workbench.runTask(task_id, .{ .text = "establish conversation" });
    try waitWorkbenchSnapshot(&workbench, "\"lastRunOutcome\":\"completed\"");

    _ = try workbench.compactTaskAtBinding(task_id, 1);
    try waitWorkbenchSnapshot(&workbench, "\"phase\":\"compacted\"");
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

test "Workbench compact cancellation and Task deletion wait for the Agent terminal result" {
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
    var workbench = try workbench_api.Workbench.init(
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
        workbenchConfiguration(),
    );
    defer workbench.deinit();
    try installWorkbenchExecution(&workbench);

    const task_id = try workbench.createTask(workbenchTaskInput());
    _ = try workbench.runTask(task_id, .{ .text = "establish conversation" });
    try waitWorkbenchSnapshot(&workbench, "\"lastRunOutcome\":\"completed\"");
    fake_core.setSessionPlan(.controlled);
    fake_core.rearmControlled();
    const operation_id = try workbench.compactTaskAtBinding(task_id, 1);
    try waitWorkbenchSnapshot(&workbench, "\"phase\":\"compacting\"");
    try std.testing.expectError(
        error.TaskBusy,
        workbench.runTask(task_id, .{ .text = "must wait" }),
    );
    try workbench.cancelCompact(task_id, operation_id);
    try waitWorkbenchSnapshot(&workbench, "\"phase\":\"aborted\"");
    try waitWorkbenchSnapshot(&workbench, "\"activeOperation\":null");

    try workbench.setTaskArchived(task_id, true);
    try workbench.deleteTask(task_id);
    try waitTaskDeleted(&workbench, task_id);
    fake_core.lock();
    const abort_calls = fake_core.compact_abort_calls;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), abort_calls);
}

test "Workbench terminal compact result wins a too-late cancellation race" {
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
    var workbench = try workbench_api.Workbench.init(
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
        workbenchConfiguration(),
    );
    defer workbench.deinit();
    try installWorkbenchExecution(&workbench);

    const task_id = try workbench.createTask(workbenchTaskInput());
    _ = try workbench.runTask(task_id, .{ .text = "establish conversation" });
    try waitWorkbenchSnapshot(&workbench, "\"lastRunOutcome\":\"completed\"");
    fake_core.setSessionPlan(.controlled);
    fake_core.rearmControlled();
    fake_core.forceNextCompactAbortStatus(wire.STATUS_TOO_LATE);
    const operation_id = try workbench.compactTaskAtBinding(task_id, 1);
    try waitWorkbenchSnapshot(&workbench, "\"phase\":\"compacting\"");
    try workbench.cancelCompact(task_id, operation_id);
    try waitWorkbenchSnapshot(&workbench, "\"phase\":\"stopping\"");
    fake_core.releaseControlled();
    try waitWorkbenchSnapshot(&workbench, "\"phase\":\"compacted\"");
    try waitWorkbenchSnapshot(&workbench, "\"activeOperation\":null");
    try std.testing.expectError(
        error.NoSuchCompact,
        workbench.cancelCompact(task_id, operation_id),
    );
}

test "Workbench cancels a queued compact without entering AgentCore" {
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
    var workbench = try workbench_api.Workbench.init(
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
        workbenchConfiguration(),
    );
    defer workbench.deinit();
    try installWorkbenchExecution(&workbench);

    const blocking_task_id = try workbench.createTask(workbenchTaskInput());
    const compact_task_id = try workbench.createTask(workbenchTaskInput());
    try workbench.renameTask(blocking_task_id, "blocking target");
    try workbench.renameTask(compact_task_id, "compact target");
    _ = try workbench.runTask(blocking_task_id, .{ .text = "first conversation" });
    try waitTaskSnapshot(
        &workbench,
        "\"title\":\"blocking target\"",
        "\"lastRunOutcome\":\"completed\"",
    );
    _ = try workbench.runTask(compact_task_id, .{ .text = "second conversation" });
    try waitTaskSnapshot(
        &workbench,
        "\"title\":\"compact target\"",
        "\"lastRunOutcome\":\"completed\"",
    );

    fake_core.setSessionPlan(.controlled);
    fake_core.rearmControlled();
    const blocking_run_id = try workbench.runTask(
        blocking_task_id,
        .{ .text = "occupy the only worker" },
    );
    try waitWorkbenchSnapshot(&workbench, "\"currentRunPhase\":\"running\"");
    const operation_id = try workbench.compactTaskAtBinding(compact_task_id, 1);
    try waitWorkbenchSnapshot(&workbench, "\"phase\":\"queued\"");
    try workbench.cancelCompact(compact_task_id, operation_id);
    try waitWorkbenchSnapshot(&workbench, "\"phase\":\"aborted\"");
    fake_core.lock();
    const compact_calls = fake_core.compact_calls;
    const compact_abort_calls = fake_core.compact_abort_calls;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 0), compact_calls);
    try std.testing.expectEqual(@as(usize, 0), compact_abort_calls);

    try workbench.cancel(blocking_task_id, blocking_run_id);
    try waitWorkbenchSnapshot(&workbench, "\"lastRunOutcome\":\"cancelled\"");
}

test "Workbench shutdown terminates a waiting UI Run before joining workers" {
    fake_core.reset();
    fake_core.setNextPlan(.ui_wait);
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var workbench = try workbench_api.Workbench.init(std.testing.allocator, std.testing.io, runtime, .{
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
    try waitWorkbenchSnapshot(&workbench, "\"currentRunPhase\":\"waiting_ui\"");
    workbench.shutdownExecutor();
    try waitWorkbenchSnapshot(&workbench, "\"lastRunOutcome\":\"interrupted\"");
    try waitWorkbenchSnapshot(&workbench, "\"continuationAvailable\":false");
}

test "Workbench shutdown rejects new Task admission without creating product state" {
    fake_core.reset();
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var workbench = try workbench_api.Workbench.init(std.testing.allocator, std.testing.io, runtime, .{
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

test "late event from a finalized Run is dropped and newer active work continues" {
    fake_core.reset();
    fake_core.setNextPlan(.controlled);
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var workbench = try workbench_api.Workbench.init(std.testing.allocator, std.testing.io, runtime, .{
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
    try waitWorkbenchSnapshot(&workbench, "\"currentRunPhase\":\"running\"");
    fake_core.releaseControlled();
    try waitWorkbenchSnapshot(&workbench, "\"lastRunOutcome\":\"completed\"");

    fake_core.rearmControlled();
    _ = try workbench.runTask(task_id, .{ .text = "new active work" });
    try waitWorkbenchSnapshot(&workbench, "\"currentRunPhase\":\"running\"");

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
    try std.testing.expectEqual(@as(u64, 1), workbench.late_terminal_event_count);

    var snapshot_storage: [128 * 1024]u8 = undefined;
    const open_snapshot = try workbench.writeSnapshot(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(u8, open_snapshot, "\"lifecycle\":\"open\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, open_snapshot, "\"currentRunPhase\":\"running\"") != null);
    fake_core.releaseControlled();
    try waitWorkbenchSnapshot(&workbench, "\"lastRunOutcome\":\"completed\"");
}
