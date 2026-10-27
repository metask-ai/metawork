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

fn digestBytes(bytes: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest;
}

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
    pending_publication: ?[32]u8 = null,
    incompatible: bool = false,
    restore_failed: bool = true,
    credentials: *[128]Credential,
    credential_capacity_failed: bool = false,
    publish_sync_fault: bool = false,
    security_epoch: u64 = 1,
    requires_reopen: bool = false,
    legacy_import_failed: bool = false,
    recovery_fault: enum { none, after_close, after_quarantine } = .none,

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
        self.requires_reopen = true;
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
        self.legacy_import_failed = false;
        errdefer self.restore_failed = true;
        if (!try self.exists(file_name)) {
            if (try self.hasSqlRecoveryEvidence()) return error.RecoveryPending;
            const original = self.legacy.loadAlloc(allocator) catch |err| {
                self.legacy_import_failed = true;
                return err;
            };
            defer if (original) |bytes| allocator.free(bytes);
            if (original) |bytes| {
                var recovered = wire.decodeRecovering(allocator, bytes, self.limits) catch |err| {
                    self.legacy_import_failed = true;
                    return err;
                };
                defer recovered.deinit();
                try self.publish(recovered.value, recovered.preserved, false, digestBytes(bytes));
            } else {
                try self.publish(.{ .next_workspace_id = 1, .next_workspace_recent_order = 1, .next_task_id = 1, .next_task_recent_order = 1, .workspaces = &.{}, .tasks = &.{} }, .{}, false, digestBytes("empty history"));
            }
        }
        if (self.database == null) try self.open();
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const loaded = try product.loadHistory(arena.allocator(), self.database.?.capability(), self.limits);
        try self.repository.?.seed(loaded.value, loaded.preserved);
        if (self.database.?.capability().maintain(.confirm) != .ok) return error.ReadFailed;
        try self.syncPublished();
        const bytes = try wire.encodeAlloc(allocator, loaded.value, loaded.preserved, self.limits);
        self.restore_failed = false;
        self.requires_reopen = false;
        return bytes;
    }

    fn syncPublished(self: *Store) !void {
        if (self.publish_sync_fault) return error.SyncFailed;
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

    fn hasSqlRecoveryEvidence(self: *Store) !bool {
        if (try self.exists(file_name ++ "-wal") or try self.exists(file_name ++ "-shm")) return true;
        var directory = try self.legacy.dir.openDir(self.io, ".", .{ .iterate = true, .follow_symlinks = false });
        defer directory.close(self.io);
        var iterator = directory.iterate();
        while (try iterator.next(self.io)) |entry| {
            if (!std.mem.startsWith(u8, entry.name, ".workbench-history.recovery.")) continue;
            if (std.mem.endsWith(u8, entry.name, ".tmp") or std.mem.endsWith(u8, entry.name, ".workbench-history.sqlite.bak") or
                std.mem.endsWith(u8, entry.name, ".workbench-history.sqlite-wal.bak") or std.mem.endsWith(u8, entry.name, ".workbench-history.sqlite-shm.bak") or
                std.mem.endsWith(u8, entry.name, ".workbench-history.store.bak")) return true;
        }
        return false;
    }

    /// A closed, checkpointed private candidate is the only publication input.
    fn publish(self: *Store, state: wire.StateWire, preserved: wire.PreservedFrames, recovering: bool, digest: [32]u8) !void {
        if (self.incompatible or self.pending != null) return error.WriteBlocked;
        const retire_legacy = recovering and self.legacy_import_failed and !try self.exists(file_name);
        if (!recovering) try self.removeImport();
        const directory = std.fs.path.dirname(self.path).?;
        var nonce: [8]u8 = undefined;
        try std.Io.randomSecure(self.io, &nonce);
        const stage_name = if (recovering)
            try std.fmt.allocPrint(self.allocator, ".workbench-history.recovery.{s}.tmp", .{std.fmt.bytesToHex(nonce, .lower)})
        else
            import_name;
        defer if (recovering) self.allocator.free(stage_name);
        const temporary = try std.fs.path.join(self.allocator, &.{ directory, stage_name });
        defer self.allocator.free(temporary);
        const private_file = try self.legacy.dir.createFile(self.io, stage_name, .{
            .exclusive = true,
            .permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(0o600),
            .resolve_beneath = true,
        });
        private_file.close(self.io);
        errdefer if (!recovering) self.removeImport() catch {};
        const candidate = try storage.sqlite.Database.create(self.io, self.allocator, .{ .file = temporary }, product.history_migrations);
        var candidate_open = true;
        defer if (candidate_open) candidate.destroy() catch unreachable;
        var repository = product.HistoryRepository.init(self.allocator, candidate.capability(), self.limits);
        defer repository.deinit();
        var prepared = try repository.prepare(state, preserved, digest);
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
            if (builtin.is_test and self.recovery_fault == .after_close) return error.RecoveryInterrupted;
            var random: [8]u8 = undefined;
            try std.Io.randomSecure(self.io, &random);
            const hex = std.fmt.bytesToHex(random, .lower);
            // Each existing component is retained; a partial move is still
            // recovery evidence, never interpreted as an empty first launch.
            for ([_][]const u8{ file_name, file_name ++ "-wal", file_name ++ "-shm", wire.file_name }) |name| {
                if (std.mem.eql(u8, name, wire.file_name) and !retire_legacy) continue;
                const quarantine = try std.fmt.allocPrint(self.allocator, ".workbench-history.recovery.{s}.{s}.bak", .{ hex, name });
                defer self.allocator.free(quarantine);
                self.legacy.dir.rename(name, self.legacy.dir, quarantine, self.io) catch |err| switch (err) {
                    error.FileNotFound => {},
                    else => return err,
                };
            }
            if (builtin.is_test and self.recovery_fault == .after_quarantine) return error.RecoveryInterrupted;
        }
        if (try self.exists(file_name)) return error.PublishConflict;
        try self.legacy.dir.rename(stage_name, self.legacy.dir, file_name, self.io);
        self.pending_publication = digest;
        self.syncPublished() catch return error.PublishOutcomeUnknown;
        if (self.repository) |*old| old.deinit();
        self.repository = null;
        self.open() catch return error.PublishOutcomeUnknown;
        self.repository.?.seed(state, preserved) catch return error.PublishOutcomeUnknown;
        self.pending_publication = null;
        self.restore_failed = false;
        self.requires_reopen = false;
        self.legacy_import_failed = false;
    }

    pub fn commit(self: *Store, bytes: []const u8, confirmed: bool) wire.Commit {
        return self.commitGeneration(bytes, self.security_epoch, confirmed);
    }

    pub fn commitGeneration(self: *Store, bytes: []const u8, epoch: u64, confirmed: bool) wire.Commit {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.security_epoch == 0 or epoch != self.security_epoch) return .failed;
        return self.commitLocked(bytes, confirmed);
    }

    fn commitLocked(self: *Store, bytes: []const u8, confirmed: bool) wire.Commit {
        if (self.pending_publication != null) return .outcome_unknown;
        if (self.incompatible or self.restore_failed) return .failed;
        if (self.pending != null and self.resolvePending() == .outcome_unknown) return .outcome_unknown;
        if ((self.database == null or self.requires_reopen) and !self.refreshConfirmed()) return .failed;
        if (self.credential_capacity_failed) return .failed;
        for (self.credentials) |slot| if (slot.length != 0 and std.mem.indexOf(u8, bytes, slot.bytes[0..slot.length]) != null) return .failed;
        var candidate = wire.decodeRecovering(self.allocator, bytes, self.limits) catch return .failed;
        defer candidate.deinit();
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        var prepared = self.repository.?.prepare(candidate.value, candidate.preserved, digest) catch return .failed;
        const outcome = self.repository.?.commit(&prepared);
        if (outcome == .outcome_unknown or (outcome == .committed and !self.sanitizePending())) {
            self.pending = prepared;
            return if (confirmed) self.resolveLocked(bytes) else .outcome_unknown;
        }
        prepared.deinit();
        if (outcome != .committed) self.requires_reopen = true;
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
        return self.resolvePending();
    }

    fn resolvePending(self: *Store) wire.Commit {
        const pending = if (self.pending) |*value| value else return .outcome_unknown;
        // A successful business commit may be waiting only for security
        // maintenance. Its authority is known; never replay its mutations.
        if (pending.next_index == null) {
            if (self.requires_reopen and !self.refreshConfirmed()) return .outcome_unknown;
            if (!self.sanitizePending()) return .outcome_unknown;
            pending.deinit();
            self.pending = null;
            return .committed;
        }
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
        if (self.incompatible) return .failed;
        if (self.pending_publication != null) {
            if (!self.resolvePublication()) return .outcome_unknown;
            return self.commitLocked(bytes, true);
        }
        if (self.pending != null) {
            if (self.resolvePending() == .outcome_unknown) return .outcome_unknown;
            return self.commitLocked(bytes, true);
        }
        var candidate = wire.decodeRecovering(self.allocator, bytes, self.limits) catch return .failed;
        defer candidate.deinit();
        self.publish(candidate.value, candidate.preserved, true, digestBytes(bytes)) catch |err| return if (err == error.PublishOutcomeUnknown) .outcome_unknown else .failed;
        return .committed;
    }

    fn resolvePublication(self: *Store) bool {
        const expected = self.pending_publication orelse return false;
        self.close();
        self.open() catch return false;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const loaded = product.loadHistory(arena.allocator(), self.database.?.capability(), self.limits) catch return false;
        self.repository.?.seed(loaded.value, loaded.preserved) catch return false;
        if (!std.mem.eql(u8, &expected, &self.repository.?.witness.digest)) return false;
        if (self.database.?.capability().maintain(.confirm) != .ok) return false;
        self.syncPublished() catch return false;
        self.pending_publication = null;
        self.restore_failed = false;
        self.requires_reopen = false;
        return true;
    }

    pub fn credential(self: *Store, value: []const u8, retained: bool) void {
        if (value.len == 0) return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.registerCredential(value, retained);
        if (!self.incompatible and self.pending == null and self.database != null) _ = self.sanitizePending();
    }

    pub fn syncCredentials(self: *Store, values: []const []const u8, complete: bool) wire.CredentialStatus {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.credential_capacity_failed = !complete;
        if (!complete) return .{ .epoch = self.security_epoch, .ready = false };
        for (self.credentials) |*slot| {
            if (slot.length == 0) continue;
            slot.retained = for (values) |value| {
                if (std.mem.eql(u8, value, slot.bytes[0..slot.length])) break true;
            } else false;
            if (!slot.retained and !slot.pending) self.clearCredential(slot);
        }
        for (values) |value| if (value.len != 0) self.registerCredential(value, true);
        return .{ .epoch = self.security_epoch, .ready = !self.incompatible and self.pending == null and self.database != null and self.sanitizePending() };
    }

    fn registerCredential(self: *Store, value: []const u8, retained: bool) void {
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
            if (self.security_epoch != 0) self.security_epoch = std.math.add(u64, self.security_epoch, 1) catch 0;
            // Only first discovery performs disk maintenance. Repeated bearer
            // acquisition/release above is constant bounded in-memory work.
            return;
        }
        self.credential_capacity_failed = true;
    }

    fn clearCredential(_: *Store, slot: *Credential) void {
        std.crypto.secureZero(u8, &slot.bytes);
        slot.* = .{};
    }

    fn sanitizePending(self: *Store) bool {
        if (self.incompatible or self.credential_capacity_failed or self.security_epoch == 0) return false;
        if (self.requires_reopen and !self.refreshConfirmed()) return false;
        for (self.credentials) |*slot| {
            if (!slot.pending) continue;
            const value = slot.bytes[0..slot.length];
            self.repository.?.sanitize(value) catch {
                self.requires_reopen = true;
                return false;
            };
            self.sanitizeLegacy(value) catch return false;
            slot.pending = false;
            if (!slot.retained) self.clearCredential(slot);
        }
        return true;
    }

    fn refreshConfirmed(self: *Store) bool {
        if (!(self.exists(file_name) catch return false)) return false;
        self.close();
        self.open() catch return false;
        if (self.database.?.capability().maintain(.confirm) != .ok) return false;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const loaded = product.loadHistory(arena.allocator(), self.database.?.capability(), self.limits) catch return false;
        self.repository.?.seed(loaded.value, loaded.preserved) catch return false;
        self.requires_reopen = false;
        return true;
    }

    fn sanitizeLegacy(self: *Store, credential_value: []const u8) !void {
        if (!try self.exists(wire.file_name)) return;
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
    try std.testing.expect(store.refreshConfirmed());
    state.tasks[1].title = "unrelated change";
    store.database.?.test_hooks.lose_ack_after_commit = true;
    bytes = try wire.encodeAlloc(arena.allocator(), state, .{}, store.limits);
    try std.testing.expectEqual(wire.Commit.committed, store.commit(bytes, true));
    const loaded = try product.loadHistory(arena.allocator(), store.database.?.capability(), store.limits);
    try std.testing.expectEqualStrings("pending change", loaded.value.tasks[0].title);
    try std.testing.expectEqualStrings("unrelated change", loaded.value.tasks[1].title);
    try std.testing.expect(store.pending == null);
}

test "SQLite history delete then slot reuse preserves Task and Workspace order on restart" {
    const a = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(directory);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    var state = try testHistory(aa, 3, 1, "message");
    const workspaces = try aa.alloc(wire.WorkspaceWire, 3);
    for (workspaces, 0..) |*workspace, i| {
        workspace.* = state.workspaces[0];
        workspace.id = i + 1;
        workspace.canonical_root = try std.fmt.allocPrint(aa, "C:/workspace-{d}", .{i});
        state.tasks[i].workspace_id = workspace.id;
        state.tasks[i].workspace_root = workspace.canonical_root;
    }
    state.workspaces = workspaces;
    state.next_workspace_id = 4;
    {
        var store = try Store.init(std.testing.io, a, directory);
        defer store.deinit();
        if (try store.loadAlloc(a)) |bytes| a.free(bytes);
        try std.testing.expectEqual(wire.Commit.committed, store.commit(try wire.encodeAlloc(aa, state, .{}, store.limits), true));
        const original_tasks = state.tasks;
        state.tasks = try aa.dupe(wire.TaskWire, &.{ original_tasks[0], original_tasks[2] });
        state.workspaces = try aa.dupe(wire.WorkspaceWire, &.{ workspaces[0], workspaces[2] });
        try std.testing.expectEqual(wire.Commit.committed, store.commit(try wire.encodeAlloc(aa, state, .{}, store.limits), true));
        var inserted_task = original_tasks[1];
        inserted_task.id = 4;
        inserted_task.recent_order = 4;
        inserted_task.workspace_id = 4;
        var inserted_workspace = workspaces[1];
        inserted_workspace.id = 4;
        state.tasks = try aa.dupe(wire.TaskWire, &.{ original_tasks[0], inserted_task, original_tasks[2] });
        state.workspaces = try aa.dupe(wire.WorkspaceWire, &.{ workspaces[0], inserted_workspace, workspaces[2] });
        state.next_task_id = 5;
        state.next_task_recent_order = 5;
        state.next_workspace_id = 5;
        try std.testing.expectEqual(wire.Commit.committed, store.commit(try wire.encodeAlloc(aa, state, .{}, store.limits), true));
        state.tasks[2].title = "subsequent save";
        try std.testing.expectEqual(wire.Commit.committed, store.commit(try wire.encodeAlloc(aa, state, .{}, store.limits), true));
    }
    var store = try Store.init(std.testing.io, a, directory);
    defer store.deinit();
    const bytes = (try store.loadAlloc(a)).?;
    defer a.free(bytes);
    var loaded = try wire.decodeRecovering(a, bytes, store.limits);
    defer loaded.deinit();
    for ([_]u64{ 1, 4, 3 }, 0..) |id, i| {
        try std.testing.expectEqual(id, loaded.value.tasks[i].id);
        try std.testing.expectEqual(id, loaded.value.workspaces[i].id);
    }
    try std.testing.expectEqualStrings("subsequent save", loaded.value.tasks[2].title);
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
    try std.testing.expectEqual(wire.Commit.failed, store.commitGeneration(bytes, 1, true));
}

test "SQLite history 100 Tasks and 256 Runs exceed old store size and survive restart" {
    const a = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(directory);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const body = "history capacity " ** 2;
    try std.testing.expect(100 * 256 * 2 * body.len > 1536 * 1024);
    var state = try testHistory(arena.allocator(), 100, 256, body);
    {
        var store = try Store.init(std.testing.io, a, directory);
        defer store.deinit();
        if (try store.loadAlloc(a)) |bytes| a.free(bytes);
        var prepared = try store.repository.?.prepare(state, .{}, @splat(1));
        defer prepared.deinit();
        try std.testing.expectEqual(storage.sql.MutationOutcome.committed, store.repository.?.commit(&prepared));
        try std.testing.expectEqual(@as(usize, 25_702), prepared.changed_rows);
        // Exercise the real Application commit entry with a frozen candidate
        // larger than the entire former 16MiB canonical store limit.
        state.tasks[0].completion_seen_run_id = 256;
        const bytes = try wire.encodeAlloc(a, state, .{}, store.limits);
        defer a.free(bytes);
        try std.testing.expect(bytes.len > wire.max_store_bytes);
        try std.testing.expectEqual(wire.Commit.committed, store.commit(bytes, true));
        try std.testing.expectEqual(storage.sql.QueryOutcome.ok, store.database.?.capability().maintain(.purge));
    }
    {
        var store = try Store.init(std.testing.io, a, directory);
        defer store.deinit();
        const bytes = (try store.loadAlloc(a)).?;
        defer a.free(bytes);
        var recovered = try wire.decodeRecovering(a, bytes, store.limits);
        defer recovered.deinit();
        try std.testing.expectEqual(@as(usize, 100), recovered.value.tasks.len);
        for (recovered.value.tasks) |task| try std.testing.expectEqual(@as(usize, 256), task.runs.len);
        try std.testing.expectEqual(@as(?u64, 256), recovered.value.tasks[0].completion_seen_run_id);
        try std.testing.expect(!recovered.degraded);
    }
}

test "SQLite history newer schema cannot be replaced through recovery" {
    const a = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(directory);
    const path = try std.fs.path.join(a, &.{ directory, file_name });
    defer a.free(path);
    {
        var store = try Store.init(std.testing.io, a, directory);
        defer store.deinit();
        if (try store.loadAlloc(a)) |bytes| a.free(bytes);
    }
    const newer = product.history_migrations[0..1].* ++ [_]storage.sql.Migration{.{ .version = 2, .name = "future_history", .sql = "CREATE TABLE future_history(value INTEGER NOT NULL) STRICT;" }};
    const database = try storage.sqlite.Database.create(std.testing.io, a, .{ .file = path }, &newer);
    try database.destroy();
    var store = try Store.init(std.testing.io, a, directory);
    defer store.deinit();
    try std.testing.expectError(error.VersionUnknown, store.loadAlloc(a));
    try std.testing.expect(store.incompatible);
    try std.testing.expectEqual(wire.Commit.failed, store.recover("not a candidate"));
    const reopened = try storage.sqlite.Database.create(std.testing.io, a, .{ .file = path }, &newer);
    try reopened.destroy();
}

test "SQLite history recovery publication unknown is confirmed before a newer candidate" {
    const a = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(directory);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const state = try testHistory(arena.allocator(), 1, 1, "message");
    var store = try Store.init(std.testing.io, a, directory);
    defer store.deinit();
    if (try store.loadAlloc(a)) |bytes| a.free(bytes);
    var bytes = try wire.encodeAlloc(arena.allocator(), state, .{}, store.limits);
    store.publish_sync_fault = true;
    try std.testing.expectEqual(wire.Commit.outcome_unknown, store.recover(bytes));
    try std.testing.expect(store.pending_publication != null);
    state.tasks[0].title = "newer in-memory change";
    bytes = try wire.encodeAlloc(arena.allocator(), state, .{}, store.limits);
    store.publish_sync_fault = false;
    try std.testing.expectEqual(wire.Commit.committed, store.recover(bytes));
    try std.testing.expect(store.pending_publication == null);
    const loaded = try product.loadHistory(arena.allocator(), store.database.?.capability(), store.limits);
    try std.testing.expectEqualStrings("newer in-memory change", loaded.value.tasks[0].title);
}

test "SQLite history preserves opaque records while saving unrelated Task changes" {
    const a = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(directory);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var state = try testHistory(arena.allocator(), 1, 1, "message");
    state.next_task_id = 301;
    state.next_task_recent_order = 301;
    const retained: wire.PreservedFrames = .{ .retained = &.{.{ .kind = .task, .id = 300, .order = 300, .payload = "{\"future\":true}" }} };
    var store = try Store.init(std.testing.io, a, directory);
    defer store.deinit();
    if (try store.loadAlloc(a)) |bytes| a.free(bytes);
    const original = try wire.encodeAlloc(arena.allocator(), state, retained, store.limits);
    try std.testing.expectEqual(wire.Commit.committed, store.commit(original, true));
    state.tasks[0].title = "updated";
    const changed = try wire.encodeAlloc(arena.allocator(), state, retained, store.limits);
    try std.testing.expectEqual(wire.Commit.committed, store.commit(changed, true));
    const loaded = try product.loadHistory(arena.allocator(), store.database.?.capability(), store.limits);
    try std.testing.expectEqualStrings("updated", loaded.value.tasks[0].title);
    try std.testing.expectEqualStrings(retained.retained[0].payload, loaded.preserved.retained[0].payload);
}

test "SQLite history credential rotation releases retired owned copies" {
    const a = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(directory);
    var store = try Store.init(std.testing.io, a, directory);
    defer store.deinit();
    if (try store.loadAlloc(a)) |bytes| a.free(bytes);
    for (0..140) |generation| {
        var buffer: [64]u8 = undefined;
        const value = try std.fmt.bufPrint(&buffer, "rotating-owned-credential-{d}", .{generation});
        try std.testing.expect(store.syncCredentials(&.{value}, true).ready);
        var retained: usize = 0;
        for (store.credentials) |slot| if (slot.length != 0) {
            retained += 1;
        };
        try std.testing.expectEqual(@as(usize, 1), retained);
    }
    try std.testing.expect(store.syncCredentials(&.{}, true).ready);
    for (store.credentials) |slot| try std.testing.expectEqual(@as(usize, 0), slot.length);
}

test "SQLite history partial quarantine prevents reimport and preserves the old WAL" {
    const a = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(directory);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const state = try testHistory(arena.allocator(), 1, 1, "memory facts");
    var store = try Store.init(std.testing.io, a, directory);
    defer store.deinit();
    const bytes = try wire.encodeAlloc(arena.allocator(), state, .{}, store.limits);
    try store.legacy.commit(bytes);
    const evidence = ".workbench-history.recovery.interrupted.workbench-history.sqlite.bak";
    try store.legacy.dir.writeFile(std.testing.io, .{ .sub_path = evidence, .data = "old database evidence" });
    try store.legacy.dir.writeFile(std.testing.io, .{ .sub_path = file_name ++ "-wal", .data = "old WAL evidence" });
    try std.testing.expectError(error.RecoveryPending, store.loadAlloc(a));
    try std.testing.expect(!try store.exists(file_name));
    try std.testing.expectEqual(wire.Commit.committed, store.recover(bytes));
    try std.testing.expect(try store.exists(evidence));
    const loaded = try product.loadHistory(arena.allocator(), store.database.?.capability(), store.limits);
    try std.testing.expectEqualStrings("memory facts", loaded.value.tasks[0].runs[0].assistant);
}

test "SQLite history reopens a poisoned maintenance connection before retry" {
    const a = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(directory);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const state = try testHistory(arena.allocator(), 1, 1, "late-known-value");
    var store = try Store.init(std.testing.io, a, directory);
    defer store.deinit();
    if (try store.loadAlloc(a)) |bytes| a.free(bytes);
    var bytes = try wire.encodeAlloc(arena.allocator(), state, .{}, store.limits);
    try std.testing.expectEqual(wire.Commit.committed, store.commit(bytes, true));
    store.database.?.test_hooks.fail_maintenance_sync = true;
    try std.testing.expect(!store.syncCredentials(&.{"late-known-value"}, true).ready);
    try std.testing.expect(store.requires_reopen);
    state.tasks[0].runs[0].assistant = "***";
    state.tasks[0].runs[0].input.text = "***";
    bytes = try wire.encodeAlloc(arena.allocator(), state, .{}, store.limits);
    try std.testing.expectEqual(wire.Commit.committed, store.commit(bytes, true));
    try std.testing.expect(!store.requires_reopen);
}

test "SQLite recovery failures never reuse a closed connection or retire a valid legacy store" {
    const a = std.testing.allocator;
    for (0..2) |fault| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", a);
        defer a.free(directory);
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const aa = arena.allocator();
        var state = try testHistory(aa, 1, 1, "legacy facts");
        var store = try Store.init(std.testing.io, a, directory);
        defer store.deinit();
        const original = try wire.encodeAlloc(aa, state, .{}, store.limits);
        try store.legacy.commit(original);
        if (try store.loadAlloc(a)) |bytes| a.free(bytes);
        state.tasks[0].title = "after failed recovery";
        const bytes = try wire.encodeAlloc(aa, state, .{}, store.limits);
        store.recovery_fault = if (fault == 0) .after_close else .after_quarantine;
        try std.testing.expectEqual(wire.Commit.failed, store.recover(bytes));
        try std.testing.expect(store.database == null);
        const retained = (try store.legacy.loadAlloc(a)).?;
        defer a.free(retained);
        try std.testing.expectEqualSlices(u8, original, retained);
        // An intact canonical can be reopened. A partly quarantined one must
        // stay blocked until explicit recovery, never initialize an empty DB.
        try std.testing.expectEqual(if (fault == 0) wire.Commit.committed else wire.Commit.failed, store.commit(bytes, true));
        store.recovery_fault = .none;
        try std.testing.expectEqual(wire.Commit.committed, store.recover(bytes));
        const loaded = try product.loadHistory(aa, store.database.?.capability(), store.limits);
        try std.testing.expectEqualStrings("after failed recovery", loaded.value.tasks[0].title);
        const still_retained = (try store.legacy.loadAlloc(a)).?;
        defer a.free(still_retained);
        try std.testing.expectEqualSlices(u8, original, still_retained);
    }
}

test "SQLite explicit recovery retires only the failed legacy import source" {
    const a = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(directory);
    var store = try Store.init(std.testing.io, a, directory);
    defer store.deinit();
    try store.legacy.dir.writeFile(std.testing.io, .{ .sub_path = wire.file_name, .data = "not a history file" });
    _ = store.loadAlloc(a) catch null;
    try std.testing.expect(store.legacy_import_failed);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const state = try testHistory(arena.allocator(), 0, 0, "");
    const bytes = try wire.encodeAlloc(arena.allocator(), state, .{}, store.limits);
    try std.testing.expectEqual(wire.Commit.committed, store.recover(bytes));
    try std.testing.expect(!try store.exists(wire.file_name));
    try std.testing.expect(try store.hasSqlRecoveryEvidence());
}
