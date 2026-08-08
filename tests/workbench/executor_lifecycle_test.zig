const fixture = @import("lifecycle_fixture");
const std = fixture.std;
const lifecycle = fixture.lifecycle;
const workbench_api = fixture.workbench_api;
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
        std.Thread.yield() catch {};
    }
    return error.TestUnexpectedResult;
}

fn waitCheckpointDescriptor(
    workbench: *workbench_api.Workbench,
    persistence: *TaskPersistenceProbe,
) !void {
    var output: [128 * 1024]u8 = undefined;
    for (0..10_000) |_| {
        try workbench.drainAgentEvents();
        _ = try workbench.writeSnapshot(&output);
        if (persistence.len != 0 and
            std.mem.indexOf(u8, persistence.storage.?[0..persistence.len], "\"checkpoint_health\":\"available\"") != null)
            return;
        std.Thread.yield() catch {};
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
        std.Thread.yield() catch {};
    }
    return error.TestUnexpectedResult;
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
    var checkpoint_store = try workbench_api.CheckpointFileStore.init(
        std.testing.io,
        root_storage[0..root_len],
    );
    defer checkpoint_store.deinit();
    const persistence_storage = try std.testing.allocator.alloc(
        u8,
        workbench_api.task_store_max_bytes,
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
            .max_runs_per_task = 1,
            .max_tools_per_run = 1,
        },
        configuration,
    );
    var workbench_initialized = true;
    defer if (workbench_initialized) workbench.deinit();
    try installWorkbenchExecution(&workbench);
    const task_id = try workbench.createTask(workbenchTaskInput());
    _ = try workbench.runTask(task_id, .{ .text = "persist checkpoint" });
    try waitCheckpointDescriptor(&workbench, &persistence);

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("fixture-checkpoint", &digest, .{});
    const identity: workbench_api.CheckpointBlobIdentity = .{
        .task_id = task_id,
        .generation = 0,
        .digest = digest,
        .byte_size = "fixture-checkpoint".len,
    };
    try checkpoint_store.verify(identity);
    const history = persistence_storage[0..persistence.len];
    try std.testing.expect(std.mem.indexOf(u8, history, "\"generation\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, history, "\"session_id\":\"000000000000000000000001\"") != null);

    fake_core.setCheckpointGeneration(1);
    _ = try workbench.compactTaskAtBinding(
        task_id,
        try workbench.taskBindingEpoch(task_id),
    );
    try waitHistoryNeedle(&workbench, &persistence, "\"terminal_kind\":\"compact\"");
    const compact_identity: workbench_api.CheckpointBlobIdentity = .{
        .task_id = task_id,
        .generation = 1,
        .digest = digest,
        .byte_size = "fixture-checkpoint".len,
    };
    try checkpoint_store.verify(compact_identity);
    try std.testing.expectError(error.BlobMissing, checkpoint_store.verify(identity));

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
        "{d}/1-{s}.ckpt",
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
            .max_runs_per_task = 1,
            .max_tools_per_run = 1,
        },
        restart_configuration,
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        persistence_storage[0..persistence.len],
        "\"checkpoint\":null,\"checkpoint_health\":\"blob_mismatch\"",
    ) != null);
    try std.testing.expectError(error.BlobMissing, checkpoint_store.verify(compact_identity));
    restored.deinit();

    {
        var replacement_writer = try checkpoint_store.begin(task_id, 1024);
        defer replacement_writer.deinit();
        try replacement_writer.write("fixture-checkpoint");
        _ = try replacement_writer.commit(1, digest, "fixture-checkpoint".len);
    }
    checkpoint_store.delete(compact_identity);
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
            .max_runs_per_task = 1,
            .max_tools_per_run = 1,
        },
        missing_configuration,
    );
    defer missing_restored.deinit();
    try std.testing.expect(std.mem.indexOf(
        u8,
        persistence_storage[0..persistence.len],
        "\"checkpoint\":null,\"checkpoint_health\":\"blob_missing\"",
    ) != null);
    fake_core.lock();
    const session_count = fake_core.session_created;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), session_count);
}

test "Task deletion is busy during checkpoint export and candidate publication" {
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
    var checkpoint_store = try workbench_api.CheckpointFileStore.init(
        std.testing.io,
        root_storage[0..root_len],
    );
    defer checkpoint_store.deinit();
    const persistence_storage = try std.testing.allocator.alloc(
        u8,
        workbench_api.task_store_max_bytes,
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
    try std.testing.expectError(error.TaskBusy, workbench.deleteTask(task_id));
    fake_core.releaseCheckpointExport();
    try waitHistoryNeedle(&workbench, &persistence, "\"checkpoint_health\":\"cancelled\"");

    fake_core.setCheckpointGeneration(1);
    _ = try workbench.runTask(task_id, .{ .text = "publish checkpoint candidate" });
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("fixture-checkpoint", &digest, .{});
    const identity: workbench_api.CheckpointBlobIdentity = .{
        .task_id = task_id,
        .generation = 1,
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
    try std.testing.expectError(error.TaskBusy, workbench.deleteTask(task_id));
    try waitCheckpointDescriptor(&workbench, &persistence);
    try workbench.closeTask(task_id);
    try waitWorkbenchSnapshot(&workbench, "\"lifecycle\":\"closed\"");
    try workbench.deleteTask(task_id);
    try std.testing.expectError(error.BlobMissing, checkpoint_store.verify(identity));
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
    var checkpoint_store = try workbench_api.CheckpointFileStore.init(
        std.testing.io,
        root_storage[0..root_len],
    );
    defer checkpoint_store.deinit();
    const persistence_storage = try std.testing.allocator.alloc(
        u8,
        workbench_api.task_store_max_bytes,
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
    const identity: workbench_api.CheckpointBlobIdentity = .{
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
        workbench_api.CheckpointStoreHealth.ready,
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
    var checkpoint_store = try workbench_api.CheckpointFileStore.init(
        std.testing.io,
        root_storage[0..root_len],
    );
    defer checkpoint_store.deinit();
    const persistence_storage = try std.testing.allocator.alloc(
        u8,
        workbench_api.task_store_max_bytes,
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
    const identity: workbench_api.CheckpointBlobIdentity = .{
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
    try std.testing.expectError(error.TaskBusy, workbench.deleteTask(task_id));
    try std.testing.expectError(
        error.TaskPersistenceOutcomeUnknown,
        workbench.setTaskArchived(task_id, true),
    );

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
    var checkpoint_store = try workbench_api.CheckpointFileStore.init(
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
    configuration.checkpoint_store = .{ .restore_failed = true };
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
        workbench_api.CheckpointStoreHealth.unavailable,
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
        &workbench,
        "\"lastRunOutcome\":\"completed\"",
    );
    try waitWorkbenchSnapshot(
        &workbench,
        "\"skillCatalog\":{\"availability\":\"ready\"",
    );
    try waitWorkbenchSnapshot(
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
        ),
    );
    const after = try workbench.copyWorkspaceProjections(&projection_storage);
    try std.testing.expectEqual(recent_order, after[0].recent_order);
    var snapshot_storage: [128 * 1024]u8 = undefined;
    const snapshot = try workbench.writeSnapshot(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"tasks\":[]") != null);
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
        .{ .directories = .{ .automatic_workspace_root = &automatic_root } },
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
        ),
    );
    try std.testing.expectError(
        error.CatalogUnavailable,
        workbench.runTask(first_task, .{ .skill = .{
            .skill_id = fixture.fixture_skill_id,
            .catalog_revision = fixture.fixture_catalog_revision,
            .argument_values = &.{},
        } }),
    );

    const second_task = try workbench.createTaskForWorkspace(
        .automatic,
        1,
        null,
    );
    const second_workspace = try workbench.taskWorkspaceId(second_task);
    try std.testing.expect(first_workspace != second_workspace);
    try std.testing.expectEqual(@as(usize, 2), try directoryEntryCount(tmp.dir));

    _ = try workbench.runTask(first_task, .{ .text = "automatic text run" });
    try waitWorkbenchSnapshot(&workbench, "\"lastRunOutcome\":\"completed\"");
    try workbench.closeTask(first_task);
    try waitWorkbenchSnapshot(&workbench, "\"lifecycle\":\"closed\"");
    try workbench.deleteTask(first_task);
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
        workbench.createTaskForWorkspace(.automatic, 1, null),
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
    const running_task = try workbench.createTaskForWorkspace(.automatic, 1, null);
    const queued_task = try workbench.createTaskForWorkspace(.automatic, 1, null);
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

test "Workbench closes off-thread and exposes retryable close failure" {
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

test "Workbench close cancels a queued Run without blocking the caller" {
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
    _ = try workbench.runTask(task_id, .{ .text = "close this run" });
    try workbench.closeTask(task_id);
    try waitWorkbenchSnapshot(&workbench, "\"lifecycle\":\"closed\"");
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
    try waitWorkbenchSnapshot(&workbench, "\"lifecycle\":\"closed\"");

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

    try workbench.closeTask(task_id);
    try waitWorkbenchSnapshot(&workbench, "\"lifecycle\":\"closed\"");
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
    try waitWorkbenchSnapshot(&workbench, "\"operationId\":\"2\"");
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

    try workbench.closeTask(task_id);
    try waitWorkbenchSnapshot(&workbench, "\"lifecycle\":\"closed\"");
}

test "Workbench compact cancellation and close wait for the Agent terminal result" {
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

    fake_core.rearmControlled();
    _ = try workbench.compactTaskAtBinding(task_id, 1);
    try waitWorkbenchSnapshot(&workbench, "\"phase\":\"compacting\"");
    try workbench.closeTask(task_id);
    try waitWorkbenchSnapshot(&workbench, "\"lifecycle\":\"closed\"");
    fake_core.lock();
    const abort_calls = fake_core.compact_abort_calls;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 2), abort_calls);
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

    try workbench.closeTask(task_id);
    try waitWorkbenchSnapshot(&workbench, "\"lifecycle\":\"closed\"");
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
    try workbench.closeTask(blocking_task_id);
    try workbench.closeTask(compact_task_id);
    try waitTaskSnapshot(
        &workbench,
        "\"title\":\"blocking target\"",
        "\"lifecycle\":\"closed\"",
    );
    try waitTaskSnapshot(
        &workbench,
        "\"title\":\"compact target\"",
        "\"lifecycle\":\"closed\"",
    );
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

test "late event from a finalized Run closes a Task with newer active work" {
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
    try std.testing.expectError(
        error.EventAfterTerminalDrain,
        workbench.applyEvent(&late_event),
    );

    var snapshot_storage: [128 * 1024]u8 = undefined;
    const closing_snapshot = try workbench.writeSnapshot(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(u8, closing_snapshot, "\"lifecycle\":\"closing\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, closing_snapshot, "\"continuationAvailable\":false") != null);
    try waitWorkbenchSnapshot(&workbench, "\"lifecycle\":\"closed\"");
}
