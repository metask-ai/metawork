//! Application owns files and the concrete connection. Product owns the schema,
//! row reconciliation and witness; the old store is only an import source/lock.
const std = @import("std");
const builtin = @import("builtin");
const storage = @import("storage");
const product = @import("metawork_product_control");
const wire = @import("metawork_product_task").history;
pub const file_name = "workbench-history.sqlite";
const import_name = ".workbench-history.import.sqlite";
const Credential = struct {
    bytes: [4096]u8 = @splat(0),
    length: usize = 0,
    retained: bool = false,
    pending: bool = false,
};

pub const Store = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    legacy: wire.FileStore,
    path: []u8,
    limits: wire.Limits,
    mutex: std.Io.Mutex = .init,
    database: ?*storage.sqlite.Database = null,
    repository: ?product.HistoryRepository = null,
    pending: ?product.PreparedHistoryCommit = null,
    incompatible: bool = false,
    restore_failed: bool = false,
    credentials: *[128]Credential,
    credential_capacity_failed: bool = false,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, directory: []const u8) !Store {
        var legacy = try wire.FileStore.init(io, directory);
        errdefer legacy.deinit();
        const path = try std.fs.path.join(allocator, &.{ directory, file_name });
        errdefer allocator.free(path);
        const credentials = try allocator.create([128]Credential);
        credentials.* = @splat(.{});
        return .{ .io = io, .allocator = allocator, .legacy = legacy, .path = path, .limits = product.persistenceLimits(.{}, (product.Limits{}).max_workspaces), .credentials = credentials };
    }

    pub fn deinit(self: *Store) void {
        if (self.pending) |*pending| pending.deinit();
        if (self.repository) |*repository| repository.deinit();
        self.close();
        self.legacy.deinit();
        self.allocator.free(self.path);
        std.crypto.secureZero(u8, std.mem.asBytes(self.credentials));
        self.allocator.destroy(self.credentials);
        self.* = undefined;
    }

    fn close(self: *Store) void {
        if (self.database) |database| database.destroy() catch unreachable;
        self.database = null;
    }

    fn open(self: *Store) !void {
        const database = storage.sqlite.Database.create(self.io, self.allocator, .{ .file = self.path }, product.history_migrations) catch |err| {
            if (err == error.VersionUnknown) self.incompatible = true;
            return err;
        };
        self.database = database;
        if (self.repository) |*repository| {
            repository.database = database.capability();
        } else self.repository = .init(self.allocator, database.capability(), self.limits);
    }

    fn exists(self: *Store, name: []const u8) !bool {
        const file = self.legacy.dir.openFile(self.io, name, .{ .follow_symlinks = false, .resolve_beneath = true }) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        file.close(self.io);
        return true;
    }

    /// Called before Product ingress. A published SQL file always wins; never
    /// silently fall back to legacy history after an SQL failure.
    pub fn loadAlloc(self: *Store, allocator: std.mem.Allocator) !?[]u8 {
        self.restore_failed = true;
        if (!try self.exists(file_name)) {
            const original = try self.legacy.loadAlloc(allocator);
            defer if (original) |bytes| allocator.free(bytes);
            if (original) |bytes| {
                var recovered = try wire.decodeRecovering(allocator, bytes, self.limits);
                defer recovered.deinit();
                try self.publish(recovered.value, recovered.preserved, false);
            } else {
                try self.publish(.{ .next_workspace_id = 1, .next_workspace_recent_order = 1, .next_task_id = 1, .next_task_recent_order = 1, .workspaces = &.{}, .tasks = &.{} }, .{}, false);
            }
        }
        if (self.database == null) try self.open();
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const loaded = try product.loadHistory(arena.allocator(), self.database.?.capability(), self.limits);
        try self.repository.?.seed(loaded.value, loaded.preserved);
        const bytes = try wire.encodeAlloc(allocator, loaded.value, loaded.preserved, self.limits);
        self.restore_failed = false;
        return bytes;
    }

    fn syncPublished(self: *Store) !void {
        if (builtin.os.tag == .windows) {
            const file = try self.legacy.dir.openFile(self.io, file_name, .{ .mode = .read_write, .follow_symlinks = false, .resolve_beneath = true });
            defer file.close(self.io);
            try file.sync(self.io);
        } else {
            const file: std.Io.File = .{ .handle = self.legacy.dir.handle, .flags = .{ .nonblocking = false } };
            try file.sync(self.io);
        }
    }

    fn removeImport(self: *Store) !void {
        for ([_][]const u8{ import_name, import_name ++ "-wal", import_name ++ "-shm" }) |name| self.legacy.dir.deleteFile(self.io, name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }

    /// A closed, checkpointed private candidate is the only publication input.
    fn publish(self: *Store, state: wire.StateWire, preserved: wire.PreservedFrames, recovering: bool) !void {
        if (self.incompatible or self.pending != null) return error.WriteBlocked;
        try self.removeImport();
        const directory = std.fs.path.dirname(self.path).?;
        const temporary = try std.fs.path.join(self.allocator, &.{ directory, import_name });
        defer self.allocator.free(temporary);
        const candidate = try storage.sqlite.Database.create(self.io, self.allocator, .{ .file = temporary }, product.history_migrations);
        var candidate_open = true;
        defer if (candidate_open) candidate.destroy() catch unreachable;
        var repository = product.HistoryRepository.init(self.allocator, candidate.capability(), self.limits);
        defer repository.deinit();
        var prepared = try repository.prepare(state, preserved, @splat(0));
        defer prepared.deinit();
        if (repository.commit(&prepared) != .committed) return error.WriteFailed;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        _ = try product.loadHistory(arena.allocator(), candidate.capability(), self.limits);
        if (candidate.capability().maintain(.purge) != .ok) return error.WriteFailed;
        try candidate.destroy();
        candidate_open = false;
        if (recovering) {
            self.close();
            var random: [8]u8 = undefined;
            try std.Io.randomSecure(self.io, &random);
            const hex = std.fmt.bytesToHex(random, .lower);
            // Each existing component is retained; a partial move is still
            // recovery evidence, never interpreted as an empty first launch.
            for ([_][]const u8{ file_name, file_name ++ "-wal", file_name ++ "-shm", wire.file_name }) |name| {
                const quarantine = try std.fmt.allocPrint(self.allocator, ".workbench-history.recovery.{s}.{s}.bak", .{ hex, name });
                defer self.allocator.free(quarantine);
                self.legacy.dir.rename(name, self.legacy.dir, quarantine, self.io) catch |err| switch (err) {
                    error.FileNotFound => {},
                    else => return err,
                };
            }
        }
        if (try self.exists(file_name)) return error.PublishConflict;
        try self.legacy.dir.rename(import_name, self.legacy.dir, file_name, self.io);
        try self.syncPublished();
        if (self.repository) |*old| old.deinit();
        self.repository = null;
        try self.open();
        try self.repository.?.seed(state, preserved);
        self.restore_failed = false;
    }

    pub fn commit(self: *Store, bytes: []const u8, confirmed: bool) wire.Commit {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.incompatible or self.restore_failed or self.pending != null) return .failed;
        if (self.credential_capacity_failed) return .failed;
        for (self.credentials) |slot| if (slot.length != 0 and std.mem.indexOf(u8, bytes, slot.bytes[0..slot.length]) != null) return .failed;
        var candidate = wire.decodeRecovering(self.allocator, bytes, self.limits) catch return .failed;
        defer candidate.deinit();
        if (candidate.degraded) return .failed;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        var prepared = self.repository.?.prepare(candidate.value, candidate.preserved, digest) catch return .failed;
        const outcome = self.repository.?.commit(&prepared);
        if (outcome == .outcome_unknown or (outcome == .committed and !self.sanitizePending())) {
            self.pending = prepared;
            return if (confirmed) self.resolveLocked(bytes) else .outcome_unknown;
        }
        prepared.deinit();
        return if (outcome == .committed) .committed else .failed;
    }

    pub fn resolve(self: *Store, bytes: []const u8) wire.Commit {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.resolveLocked(bytes);
    }

    fn resolveLocked(self: *Store, bytes: []const u8) wire.Commit {
        const pending = if (self.pending) |*value| value else return .outcome_unknown;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        if (!std.mem.eql(u8, &digest, &pending.next.digest)) return .outcome_unknown;
        self.close();
        self.open() catch return .outcome_unknown;
        const result = self.repository.?.resolve(pending);
        if (result == .committed and !self.sanitizePending()) return .outcome_unknown;
        if (result != .outcome_unknown) {
            pending.deinit();
            self.pending = null;
        }
        return result;
    }

    pub fn recover(self: *Store, bytes: []const u8) wire.Commit {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.incompatible or self.pending != null) return .failed;
        var candidate = wire.decodeRecovering(self.allocator, bytes, self.limits) catch return .failed;
        defer candidate.deinit();
        self.publish(candidate.value, candidate.preserved, true) catch return .failed;
        return .committed;
    }

    pub fn credential(self: *Store, value: []const u8, retained: bool) void {
        if (value.len == 0) return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.credentials) |*slot| {
            if (slot.length != value.len or !std.mem.eql(u8, slot.bytes[0..slot.length], value)) continue;
            slot.retained = retained;
            if (!slot.pending and !retained) self.clearCredential(slot);
            return;
        }
        if (value.len > 4096) {
            self.credential_capacity_failed = true;
            return;
        }
        for (self.credentials) |*slot| {
            if (slot.length != 0) continue;
            @memcpy(slot.bytes[0..value.len], value);
            slot.length = value.len;
            slot.retained = retained;
            slot.pending = true;
            // Only first discovery performs disk maintenance. Repeated bearer
            // acquisition/release above is constant bounded in-memory work.
            if (!self.incompatible and self.pending == null and self.database != null) _ = self.sanitizePending();
            return;
        }
        self.credential_capacity_failed = true;
    }

    fn clearCredential(_: *Store, slot: *Credential) void {
        std.crypto.secureZero(u8, &slot.bytes);
        slot.* = .{};
    }

    fn sanitizePending(self: *Store) bool {
        if (self.incompatible or self.credential_capacity_failed) return false;
        for (self.credentials) |*slot| {
            if (!slot.pending) continue;
            const value = slot.bytes[0..slot.length];
            self.repository.?.sanitize(value) catch return false;
            self.sanitizeLegacy(value) catch return false;
            slot.pending = false;
            if (!slot.retained) self.clearCredential(slot);
        }
        return true;
    }

    fn sanitizeLegacy(self: *Store, credential_value: []const u8) !void {
        const original = try self.legacy.loadAlloc(self.allocator);
        defer if (original) |bytes| self.allocator.free(bytes);
        const bytes = original orelse return;
        if (std.mem.indexOf(u8, bytes, credential_value) == null) return;
        var recovered = try wire.decodeRecovering(self.allocator, bytes, self.limits);
        defer recovered.deinit();
        const a = recovered.arena.allocator();
        const state = try product.redactHistory(a, recovered.value, credential_value);
        const preserved = try product.redactHistory(a, recovered.preserved, credential_value);
        const output = try a.alloc(u8, wire.max_store_bytes);
        const cleaned = try wire.encodePreserving(output, state, preserved, self.limits);
        // Security maintenance of the retired import source, never a second
        // business writer. Ordinary commits exclusively target SQLite.
        try self.legacy.commit(cleaned);
    }
};

test "SQLite history Application roundtrip and legacy import" {
    const a = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(directory);
    const limits = product.persistenceLimits(.{}, 16);
    var state = wire.StateWire{ .next_workspace_id = 1, .next_workspace_recent_order = 1, .next_task_id = 1, .next_task_recent_order = 1, .workspaces = &.{}, .tasks = &.{} };
    const output = try a.alloc(u8, wire.max_store_bytes);
    defer a.free(output);
    const original = try wire.encode(output, state, limits);
    {
        var legacy = try wire.FileStore.init(std.testing.io, directory);
        defer legacy.deinit();
        try legacy.commit(original);
    }
    {
        var store = try Store.init(std.testing.io, a, directory);
        defer store.deinit();
        const loaded = (try store.loadAlloc(a)).?;
        defer a.free(loaded);
        try std.testing.expectEqualStrings(original, loaded);
        state.default_approval_mode = "full_access";
        state.default_permission_profile = "full_access";
        const changed = try wire.encode(output, state, limits);
        try std.testing.expectEqual(wire.Commit.committed, store.commit(changed, true));
        const legacy = (try store.legacy.loadAlloc(a)).?;
        defer a.free(legacy);
        try std.testing.expect(!std.mem.eql(u8, changed, legacy));
    }
    {
        var store = try Store.init(std.testing.io, a, directory);
        defer store.deinit();
        const loaded = (try store.loadAlloc(a)).?;
        defer a.free(loaded);
        var restored = try wire.decode(a, loaded, limits);
        defer restored.deinit();
        try std.testing.expectEqualStrings("full_access", restored.value.default_approval_mode.?);
    }
}

fn testHistory(a: std.mem.Allocator, task_count: usize, run_count: usize, body: []const u8) !wire.StateWire {
    const workspaces = try a.alloc(wire.WorkspaceWire, 1);
    workspaces[0] = .{ .id = 1, .epoch = 1, .kind = "manual", .canonical_root = if (builtin.os.tag == .windows) "C:/history" else "/history", .display_name = "history", .visible = true, .recent_order = 1 };
    const tasks = try a.alloc(wire.TaskWire, task_count);
    for (tasks, 0..) |*task, ti| {
        const runs = try a.alloc(wire.RunWire, run_count);
        for (runs, 0..) |*run, ri| run.* = .{
            .id = ri + 1,
            .generation = ri + 1,
            .coverage = "excluded",
            .execution_generation = 1,
            .execution_protocol = "openai_responses",
            .execution_model = "model",
            .permission_profile = "approval_required",
            .permission_interaction = "interactive",
            .input = .{ .kind = "text", .text = body, .skill_id = null, .catalog_revision = null, .invocation_name = null, .display_name = null, .argument_values = null, .redacted = false },
            .assistant = body,
            .assistant_redacted = false,
            .commentary_ends = &.{},
            .assistant_output_kind = "final",
            .assistant_output_start = 0,
            .phase = "completed",
            .outcome = "completed",
            .cause = null,
            .usage = .{ .input_tokens = 0, .output_tokens = 0, .cache_read_input_tokens = 0, .cache_creation_input_tokens = 0 },
            .tools = &.{},
            .diagnostic = "",
            .diagnostic_truncated = false,
            .diagnostic_redacted = false,
            .event_projection_failure = null,
            .next_activity_order = 1,
        };
        task.* = .{
            .id = ti + 1,
            .recent_order = ti + 1,
            .workspace_id = 1,
            .workspace_epoch = 1,
            .workspace_root = workspaces[0].canonical_root,
            .title = "history",
            .title_redacted = false,
            .archived = false,
            .permission_profile = "approval_required",
            .permission_interaction = "interactive",
            .binding = .{ .epoch = 1, .execution_generation = 1, .protocol = "openai_responses", .model = "model" },
            .next_run_generation = run_count + 1,
            .active_operation = null,
            .runs = runs,
            .compacts = &.{},
            .ui_history = &.{},
        };
    }
    return .{ .next_workspace_id = 2, .next_workspace_recent_order = 2, .next_task_id = task_count + 1, .next_task_recent_order = task_count + 1, .workspaces = workspaces, .tasks = tasks };
}

test "SQLite history confirms unknown without replay and backfills failed unrelated changes" {
    const a = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(directory);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var state = try testHistory(arena.allocator(), 2, 1, "message");
    var store = try Store.init(std.testing.io, a, directory);
    defer store.deinit();
    if (try store.loadAlloc(a)) |bytes| a.free(bytes);
    var bytes = try wire.encodeAlloc(arena.allocator(), state, .{}, store.limits);
    try std.testing.expectEqual(wire.Commit.committed, store.commit(bytes, true));
    state.tasks[0].title = "pending change";
    store.database.?.test_hooks.fail_before_commit = true;
    bytes = try wire.encodeAlloc(arena.allocator(), state, .{}, store.limits);
    try std.testing.expectEqual(wire.Commit.failed, store.commit(bytes, true));
    store.database.?.test_hooks.fail_before_commit = false;
    state.tasks[1].title = "unrelated change";
    store.database.?.test_hooks.lose_ack_after_commit = true;
    bytes = try wire.encodeAlloc(arena.allocator(), state, .{}, store.limits);
    try std.testing.expectEqual(wire.Commit.committed, store.commit(bytes, true));
    const loaded = try product.loadHistory(arena.allocator(), store.database.?.capability(), store.limits);
    try std.testing.expectEqualStrings("pending change", loaded.value.tasks[0].title);
    try std.testing.expectEqualStrings("unrelated change", loaded.value.tasks[1].title);
    try std.testing.expect(store.pending == null);
}

test "SQLite history newly learned credential is removed and repeated borrows do not rewrite" {
    const a = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(directory);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const state = try testHistory(arena.allocator(), 1, 1, "newly-discovered-value");
    var store = try Store.init(std.testing.io, a, directory);
    defer store.deinit();
    if (try store.loadAlloc(a)) |bytes| a.free(bytes);
    const bytes = try wire.encodeAlloc(arena.allocator(), state, .{}, store.limits);
    try std.testing.expectEqual(wire.Commit.committed, store.commit(bytes, true));
    store.credential("newly-discovered-value", true);
    const generation = store.repository.?.witness.generation;
    for (0..64) |_| {
        store.credential("newly-discovered-value", true);
        store.credential("newly-discovered-value", true);
    }
    try std.testing.expectEqual(generation, store.repository.?.witness.generation);
    const loaded = try product.loadHistory(arena.allocator(), store.database.?.capability(), store.limits);
    try std.testing.expect(std.mem.indexOf(u8, loaded.value.tasks[0].runs[0].assistant, "newly-discovered-value") == null);
    const file = try store.legacy.dir.openFile(std.testing.io, file_name, .{});
    defer file.close(std.testing.io);
    const raw = try a.alloc(u8, @intCast(try file.length(std.testing.io)));
    defer a.free(raw);
    _ = try file.readPositionalAll(std.testing.io, raw, 0);
    try std.testing.expect(std.mem.indexOf(u8, raw, "newly-discovered-value") == null);
    try std.testing.expectEqual(wire.Commit.failed, store.commit(bytes, true));
    store.credential("newly-discovered-value", false);
    for (store.credentials) |slot| try std.testing.expectEqual(@as(usize, 0), slot.length);
}
