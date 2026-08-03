const std = @import("std");
const builtin = @import("builtin");
const skill_package = @import("workbench_skill_package");

pub const schema_version: u8 = 1;
pub const file_name = "skill-management.json";
pub const max_store_bytes: usize = 512 * 1024;
pub const install_id_bytes: usize = 16;
pub const hash_bytes: usize = std.crypto.hash.sha2.Sha256.digest_length;
pub const max_target_entry_bytes: usize = 128;

pub const Limits = struct {
    max_assets: usize = 256,
};

pub const Error = std.mem.Allocator.Error || error{
    InvalidAsset,
    DuplicateInstallId,
    DuplicateTarget,
    AssetNotFound,
    TransactionAlreadyActive,
    TransactionMissing,
    InvalidTransaction,
    StoreEmpty,
    StoreTooLarge,
    StoreCorrupt,
    StoreEncodeFailed,
    RootUnavailable,
    TargetUnavailable,
    TargetAlreadyExists,
    CandidateUnavailable,
    FileTransactionFailed,
    PersistenceFailed,
    PersistenceOutcomeUnknown,
};

pub const FileStoreError = std.mem.Allocator.Error || error{
    DirectoryUnavailable,
    ReadFailed,
    WriteFailed,
    PersistenceOutcomeUnknown,
};

pub const InstallId = [install_id_bytes]u8;
pub const ContentHash = [hash_bytes]u8;

pub const SourceKind = enum {
    local_package,
    local_directory,
    external,
};

pub const Scope = union(enum) {
    personal,
    project: Project,

    pub const Project = struct {
        workspace_id: u64,
        workspace_epoch: u64,
    };

    pub fn eql(left: Scope, right: Scope) bool {
        return switch (left) {
            .personal => right == .personal,
            .project => |project| switch (right) {
                .personal => false,
                .project => |other| project.workspace_id == other.workspace_id and
                    project.workspace_epoch == other.workspace_epoch,
            },
        };
    }
};

pub const ManagementState = enum {
    ready,
    pending_verification,
    externally_managed,
};

pub const Operation = enum {
    install,
    replace,
    uninstall,
};

pub const TransactionPhase = enum {
    prepared,
    backup_renamed,
    candidate_published,
    reconciliation_pending,
    reconciled,
    rollback_pending,
};

pub const Recovery = struct {
    operation: Operation,
    phase: TransactionPhase,
    remove_asset_on_rollback: bool,
    candidate_hash: ?ContentHash,
    candidate_entry: ?[]u8,
    backup_entry: ?[]u8,

    fn deinit(self: *Recovery, allocator: std.mem.Allocator) void {
        if (self.candidate_entry) |value| allocator.free(value);
        if (self.backup_entry) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const Asset = struct {
    install_id: InstallId,
    source_kind: SourceKind,
    scope: Scope,
    target_entry: []u8,
    content_hash: ContentHash,
    installed_at_unix_seconds: u64,
    reimported_at_unix_seconds: ?u64,
    state: ManagementState,
    recovery: ?Recovery,

    fn deinit(self: *Asset, allocator: std.mem.Allocator) void {
        allocator.free(self.target_entry);
        if (self.recovery) |*recovery| recovery.deinit(allocator);
        self.* = undefined;
    }
};

pub const AssetInput = struct {
    install_id: InstallId,
    source_kind: SourceKind,
    scope: Scope,
    target_entry: []const u8,
    content_hash: ContentHash,
    installed_at_unix_seconds: u64,
    reimported_at_unix_seconds: ?u64 = null,
    state: ManagementState = .ready,
};

pub const RecoveryInput = struct {
    operation: Operation,
    phase: TransactionPhase = .prepared,
    remove_asset_on_rollback: bool = false,
    candidate_hash: ?ContentHash = null,
    candidate_entry: ?[]const u8 = null,
    backup_entry: ?[]const u8 = null,
};

pub const Inventory = struct {
    allocator: std.mem.Allocator,
    limits: Limits,
    assets: std.ArrayList(Asset) = .empty,

    pub fn init(allocator: std.mem.Allocator, limits: Limits) Inventory {
        return .{ .allocator = allocator, .limits = limits };
    }

    pub fn deinit(self: *Inventory) void {
        for (self.assets.items) |*asset| asset.deinit(self.allocator);
        self.assets.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn items(self: *const Inventory) []const Asset {
        return self.assets.items;
    }

    pub fn find(self: *Inventory, install_id: InstallId) ?*Asset {
        for (self.assets.items) |*asset| {
            if (std.mem.eql(u8, &asset.install_id, &install_id)) return asset;
        }
        return null;
    }

    pub fn findConst(self: *const Inventory, install_id: InstallId) ?*const Asset {
        for (self.assets.items) |*asset| {
            if (std.mem.eql(u8, &asset.install_id, &install_id)) return asset;
        }
        return null;
    }

    pub fn add(self: *Inventory, input: AssetInput) Error!*Asset {
        if (self.assets.items.len == self.limits.max_assets or !validAssetInput(input))
            return error.InvalidAsset;
        if (self.find(input.install_id) != null) return error.DuplicateInstallId;
        for (self.assets.items) |asset| {
            if (asset.scope.eql(input.scope) and
                targetEntryEqual(asset.target_entry, input.target_entry))
                return error.DuplicateTarget;
        }
        try self.assets.append(self.allocator, .{
            .install_id = input.install_id,
            .source_kind = input.source_kind,
            .scope = input.scope,
            .target_entry = try self.allocator.dupe(u8, input.target_entry),
            .content_hash = input.content_hash,
            .installed_at_unix_seconds = input.installed_at_unix_seconds,
            .reimported_at_unix_seconds = input.reimported_at_unix_seconds,
            .state = input.state,
            .recovery = null,
        });
        return &self.assets.items[self.assets.items.len - 1];
    }

    pub fn remove(self: *Inventory, install_id: InstallId) Error!void {
        for (self.assets.items, 0..) |*asset, index| {
            if (!std.mem.eql(u8, &asset.install_id, &install_id)) continue;
            asset.deinit(self.allocator);
            _ = self.assets.orderedRemove(index);
            return;
        }
        return error.AssetNotFound;
    }

    pub fn beginTransaction(
        self: *Inventory,
        install_id: InstallId,
        input: RecoveryInput,
    ) Error!void {
        const asset = self.find(install_id) orelse return error.AssetNotFound;
        if (asset.recovery != null) return error.TransactionAlreadyActive;
        if (!validRecovery(asset, input)) return error.InvalidTransaction;
        const candidate_entry = if (input.candidate_entry) |value|
            try self.allocator.dupe(u8, value)
        else
            null;
        errdefer if (candidate_entry) |value| self.allocator.free(value);
        const backup_entry = if (input.backup_entry) |value|
            try self.allocator.dupe(u8, value)
        else
            null;
        asset.recovery = .{
            .operation = input.operation,
            .phase = input.phase,
            .remove_asset_on_rollback = input.remove_asset_on_rollback,
            .candidate_hash = input.candidate_hash,
            .candidate_entry = candidate_entry,
            .backup_entry = backup_entry,
        };
    }

    pub fn advanceTransaction(
        self: *Inventory,
        install_id: InstallId,
        next: TransactionPhase,
    ) Error!void {
        const asset = self.find(install_id) orelse return error.AssetNotFound;
        const recovery = if (asset.recovery) |*value| value else return error.TransactionMissing;
        const valid = switch (recovery.operation) {
            .install => (recovery.phase == .prepared and next == .candidate_published) or
                (recovery.phase == .candidate_published and next == .reconciliation_pending) or
                ((recovery.phase == .candidate_published or
                    recovery.phase == .reconciliation_pending) and next == .reconciled),
            .replace => (recovery.phase == .prepared and next == .backup_renamed) or
                (recovery.phase == .backup_renamed and next == .candidate_published) or
                (recovery.phase == .candidate_published and next == .reconciliation_pending) or
                ((recovery.phase == .candidate_published or
                    recovery.phase == .reconciliation_pending) and next == .reconciled),
            .uninstall => (recovery.phase == .prepared and next == .backup_renamed) or
                (recovery.phase == .backup_renamed and next == .reconciliation_pending) or
                ((recovery.phase == .backup_renamed or
                    recovery.phase == .reconciliation_pending) and next == .reconciled),
        };
        if (!valid)
            return error.InvalidTransaction;
        recovery.phase = next;
    }

    pub fn markPendingVerification(
        self: *Inventory,
        install_id: InstallId,
    ) Error!void {
        const asset = self.find(install_id) orelse return error.AssetNotFound;
        const recovery = if (asset.recovery) |*value| value else return error.TransactionMissing;
        const published = recovery.phase == .candidate_published or
            (recovery.operation == .uninstall and recovery.phase == .backup_renamed) or
            recovery.phase == .reconciliation_pending;
        if (!published)
            return error.InvalidTransaction;
        recovery.phase = .reconciliation_pending;
        asset.state = .pending_verification;
    }

    pub fn markRollbackPending(self: *Inventory, install_id: InstallId) Error!void {
        const asset = self.find(install_id) orelse return error.AssetNotFound;
        const recovery = if (asset.recovery) |*value| value else return error.TransactionMissing;
        if (recovery.phase == .prepared or recovery.phase == .reconciled)
            return error.InvalidTransaction;
        recovery.phase = .rollback_pending;
        if (asset.state == .pending_verification) asset.state = .ready;
    }

    pub fn finishTransaction(
        self: *Inventory,
        install_id: InstallId,
        new_hash: ?ContentHash,
        completed_at_unix_seconds: u64,
    ) Error!void {
        const asset = self.find(install_id) orelse return error.AssetNotFound;
        const recovery = if (asset.recovery) |*value| value else return error.TransactionMissing;
        if (completed_at_unix_seconds == 0 or
            recovery.phase != .reconciled)
            return error.InvalidTransaction;
        if (recovery.operation == .uninstall) return error.InvalidTransaction;
        if (new_hash) |hash| {
            asset.content_hash = hash;
            asset.reimported_at_unix_seconds = completed_at_unix_seconds;
        }
        recovery.deinit(self.allocator);
        asset.recovery = null;
        asset.state = .ready;
    }

    pub fn finishUninstall(self: *Inventory, install_id: InstallId) Error!void {
        const asset = self.find(install_id) orelse return error.AssetNotFound;
        const recovery = asset.recovery orelse return error.TransactionMissing;
        if (recovery.operation != .uninstall or
            recovery.phase != .reconciled)
            return error.InvalidTransaction;
        try self.remove(install_id);
    }

    pub fn clearTransaction(self: *Inventory, install_id: InstallId) Error!void {
        const asset = self.find(install_id) orelse return error.AssetNotFound;
        const recovery = if (asset.recovery) |*value| value else return error.TransactionMissing;
        recovery.deinit(self.allocator);
        asset.recovery = null;
        if (asset.state == .pending_verification) asset.state = .ready;
    }
};

pub const CanonicalRoot = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    canonical_path: [:0]u8,
    scope: Scope,

    pub fn open(
        io: std.Io,
        allocator: std.mem.Allocator,
        scope: Scope,
        absolute_path: []const u8,
    ) Error!CanonicalRoot {
        if (!std.fs.path.isAbsolute(absolute_path) or
            !std.unicode.utf8ValidateSlice(absolute_path))
            return error.RootUnavailable;
        const dir = std.Io.Dir.cwd().createDirPathOpen(io, absolute_path, .{
            .open_options = .{ .follow_symlinks = false },
            .permissions = directoryPermissions(),
        }) catch return error.RootUnavailable;
        errdefer dir.close(io);
        var canonical_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const canonical_len = dir.realPath(io, &canonical_storage) catch
            return error.RootUnavailable;
        const canonical = canonical_storage[0..canonical_len];
        if (!std.fs.path.isAbsolute(canonical) or
            !std.unicode.utf8ValidateSlice(canonical))
            return error.RootUnavailable;
        return .{
            .allocator = allocator,
            .io = io,
            .dir = dir,
            .canonical_path = try allocator.dupeZ(u8, canonical),
            .scope = scope,
        };
    }

    pub fn deinit(self: *CanonicalRoot) void {
        self.dir.close(self.io);
        self.allocator.free(self.canonical_path);
        self.* = undefined;
    }

    pub fn path(self: *const CanonicalRoot) []const u8 {
        return self.canonical_path;
    }
};

const TransactionNames = struct {
    candidate: [49]u8,
    backup: [46]u8,

    fn candidateSlice(self: *const TransactionNames) []const u8 {
        return &self.candidate;
    }

    fn backupSlice(self: *const TransactionNames) []const u8 {
        return &self.backup;
    }
};

fn transactionNames(install_id: InstallId) TransactionNames {
    const hex = std.fmt.bytesToHex(install_id, .lower);
    var result: TransactionNames = undefined;
    @memcpy(result.candidate[0..17], ".skill-candidate-");
    @memcpy(result.candidate[17..], &hex);
    @memcpy(result.backup[0..14], ".skill-backup-");
    @memcpy(result.backup[14..], &hex);
    return result;
}

fn scopeMatchesRoot(scope: Scope, root: *const CanonicalRoot) bool {
    return scope.eql(root.scope);
}

fn directDirectoryExists(root: *const CanonicalRoot, entry: []const u8) !bool {
    if (!validTargetEntry(entry) and !validTransactionEntry(entry))
        return error.InvalidAsset;
    const stat = root.dir.statFile(root.io, entry, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    if (stat.kind != .directory) return error.UnsupportedEntry;
    return true;
}

fn ensureTransactionEntryAbsent(root: *const CanonicalRoot, entry: []const u8) Error!void {
    if (directDirectoryExists(root, entry) catch |err| switch (err) {
        error.FileNotFound => false,
        else => return error.FileTransactionFailed,
    }) return error.FileTransactionFailed;
}

pub const PublishInput = struct {
    asset: AssetInput,
    allow_replace: bool = false,
};

pub const PublishResult = struct {
    install_id: InstallId,
    replaced_existing: bool,
};

/// Owns the filesystem half of Skill management. AgentCore reconciliation is
/// intentionally a separate completion step because catalog query runs on the
/// Workbench executor. Every rename phase is durably recorded first or
/// immediately after the corresponding atomic filesystem transition.
pub const Transactions = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    inventory: Inventory,
    persistence: *FileStore,

    pub fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
        inventory: Inventory,
        persistence: *FileStore,
    ) Transactions {
        return .{
            .io = io,
            .allocator = allocator,
            .inventory = inventory,
            .persistence = persistence,
        };
    }

    pub fn deinit(self: *Transactions) void {
        self.inventory.deinit();
        self.* = undefined;
    }

    pub fn publish(
        self: *Transactions,
        root: *CanonicalRoot,
        staged_source: std.Io.Dir,
        manifest: *const skill_package.Manifest,
        input: PublishInput,
    ) Error!PublishResult {
        if (!scopeMatchesRoot(input.asset.scope, root)) return error.RootUnavailable;
        const target_exists = directDirectoryExists(root, input.asset.target_entry) catch
            return error.TargetUnavailable;
        if (target_exists and !input.allow_replace) return error.TargetAlreadyExists;
        const asset = try self.inventory.add(input.asset);
        var asset_registered = true;
        errdefer if (asset_registered) self.inventory.remove(input.asset.install_id) catch {};
        const names = transactionNames(input.asset.install_id);
        const operation: Operation = if (target_exists) .replace else .install;
        try self.inventory.beginTransaction(asset.install_id, .{
            .operation = operation,
            .remove_asset_on_rollback = true,
            .candidate_hash = input.asset.content_hash,
            .candidate_entry = names.candidateSlice(),
            .backup_entry = if (target_exists) names.backupSlice() else null,
        });
        try ensureTransactionEntryAbsent(root, names.candidateSlice());
        try ensureTransactionEntryAbsent(root, names.backupSlice());
        root.dir.createDir(root.io, names.candidateSlice(), directoryPermissions()) catch
            return error.CandidateUnavailable;
        var cleanup_candidate = true;
        errdefer if (cleanup_candidate)
            root.dir.deleteTree(root.io, names.candidateSlice()) catch {};
        const candidate = root.dir.openDir(root.io, names.candidateSlice(), .{
            .follow_symlinks = false,
        }) catch return error.CandidateUnavailable;
        defer candidate.close(root.io);
        skill_package.stageDirectory(root.io, staged_source, candidate, manifest) catch
            return error.CandidateUnavailable;
        var staged_manifest = skill_package.inspectDirectory(
            root.io,
            self.allocator,
            candidate,
            .{},
        ) catch return error.CandidateUnavailable;
        defer staged_manifest.deinit();
        if (!std.mem.eql(
            u8,
            &staged_manifest.content_hash,
            &manifest.content_hash,
        )) return error.CandidateUnavailable;
        try self.persist();
        asset_registered = false;
        cleanup_candidate = false;
        if (target_exists) {
            root.dir.rename(
                input.asset.target_entry,
                root.dir,
                names.backupSlice(),
                root.io,
            ) catch return error.FileTransactionFailed;
            try self.inventory.advanceTransaction(asset.install_id, .backup_renamed);
            self.persist() catch return error.PersistenceOutcomeUnknown;
        }
        root.dir.rename(
            names.candidateSlice(),
            root.dir,
            input.asset.target_entry,
            root.io,
        ) catch return error.FileTransactionFailed;
        try self.inventory.advanceTransaction(asset.install_id, .candidate_published);
        self.persist() catch return error.PersistenceOutcomeUnknown;
        return .{
            .install_id = asset.install_id,
            .replaced_existing = target_exists,
        };
    }

    pub fn reimport(
        self: *Transactions,
        root: *CanonicalRoot,
        install_id: InstallId,
        staged_source: std.Io.Dir,
        manifest: *const skill_package.Manifest,
    ) Error!void {
        const asset = self.inventory.find(install_id) orelse return error.AssetNotFound;
        if (asset.state != .ready or asset.recovery != null or
            !scopeMatchesRoot(asset.scope, root))
            return error.InvalidAsset;
        if (!(directDirectoryExists(root, asset.target_entry) catch false))
            return error.TargetUnavailable;
        const names = transactionNames(install_id);
        try ensureTransactionEntryAbsent(root, names.candidateSlice());
        try ensureTransactionEntryAbsent(root, names.backupSlice());
        try self.inventory.beginTransaction(install_id, .{
            .operation = .replace,
            .candidate_hash = manifest.content_hash,
            .candidate_entry = names.candidateSlice(),
            .backup_entry = names.backupSlice(),
        });
        root.dir.createDir(root.io, names.candidateSlice(), directoryPermissions()) catch
            return error.CandidateUnavailable;
        var cleanup_candidate = true;
        errdefer if (cleanup_candidate)
            root.dir.deleteTree(root.io, names.candidateSlice()) catch {};
        const candidate = root.dir.openDir(root.io, names.candidateSlice(), .{
            .follow_symlinks = false,
        }) catch return error.CandidateUnavailable;
        defer candidate.close(root.io);
        skill_package.stageDirectory(root.io, staged_source, candidate, manifest) catch
            return error.CandidateUnavailable;
        var staged_manifest = skill_package.inspectDirectory(
            root.io,
            self.allocator,
            candidate,
            .{},
        ) catch return error.CandidateUnavailable;
        defer staged_manifest.deinit();
        if (!std.mem.eql(
            u8,
            &staged_manifest.content_hash,
            &manifest.content_hash,
        )) return error.CandidateUnavailable;
        try self.persist();
        cleanup_candidate = false;
        root.dir.rename(asset.target_entry, root.dir, names.backupSlice(), root.io) catch
            return error.FileTransactionFailed;
        try self.inventory.advanceTransaction(install_id, .backup_renamed);
        self.persist() catch return error.PersistenceOutcomeUnknown;
        root.dir.rename(names.candidateSlice(), root.dir, asset.target_entry, root.io) catch
            return error.FileTransactionFailed;
        try self.inventory.advanceTransaction(install_id, .candidate_published);
        self.persist() catch return error.PersistenceOutcomeUnknown;
    }

    pub fn uninstall(
        self: *Transactions,
        root: *CanonicalRoot,
        install_id: InstallId,
    ) Error!void {
        const asset = self.inventory.find(install_id) orelse return error.AssetNotFound;
        if (asset.state != .ready or asset.recovery != null or
            !scopeMatchesRoot(asset.scope, root))
            return error.InvalidAsset;
        if (!(directDirectoryExists(root, asset.target_entry) catch false))
            return error.TargetUnavailable;
        const names = transactionNames(install_id);
        try ensureTransactionEntryAbsent(root, names.backupSlice());
        try self.inventory.beginTransaction(install_id, .{
            .operation = .uninstall,
            .backup_entry = names.backupSlice(),
        });
        try self.persist();
        root.dir.rename(asset.target_entry, root.dir, names.backupSlice(), root.io) catch
            return error.FileTransactionFailed;
        try self.inventory.advanceTransaction(install_id, .backup_renamed);
        self.persist() catch return error.PersistenceOutcomeUnknown;
    }

    pub fn markReconciliationUnavailable(
        self: *Transactions,
        install_id: InstallId,
    ) Error!void {
        try self.inventory.markPendingVerification(install_id);
        try self.persist();
    }

    pub fn commitReconciliation(
        self: *Transactions,
        root: *CanonicalRoot,
        install_id: InstallId,
        new_hash: ?ContentHash,
        completed_at_unix_seconds: u64,
    ) Error!void {
        const asset = self.inventory.find(install_id) orelse return error.AssetNotFound;
        if (!scopeMatchesRoot(asset.scope, root)) return error.RootUnavailable;
        const recovery = asset.recovery orelse return error.TransactionMissing;
        if (recovery.phase != .reconciled) {
            try self.inventory.advanceTransaction(install_id, .reconciled);
            try self.persist();
        }
        if (recovery.operation == .uninstall) {
            const backup = recovery.backup_entry orelse return error.InvalidTransaction;
            root.dir.deleteTree(root.io, backup) catch return error.FileTransactionFailed;
            try self.inventory.finishUninstall(install_id);
        } else {
            if (recovery.backup_entry) |backup|
                root.dir.deleteTree(root.io, backup) catch return error.FileTransactionFailed;
            try self.inventory.finishTransaction(
                install_id,
                new_hash orelse recovery.candidate_hash,
                completed_at_unix_seconds,
            );
        }
        try self.persist();
    }

    pub fn rollbackReconciliation(
        self: *Transactions,
        root: *CanonicalRoot,
        install_id: InstallId,
    ) Error!void {
        const asset = self.inventory.find(install_id) orelse return error.AssetNotFound;
        if (!scopeMatchesRoot(asset.scope, root)) return error.RootUnavailable;
        const recovery = asset.recovery orelse return error.TransactionMissing;
        if (recovery.phase != .rollback_pending) {
            try self.inventory.markRollbackPending(install_id);
            try self.persist();
        }
        if (recovery.candidate_entry) |candidate|
            root.dir.deleteTree(root.io, candidate) catch
                return error.FileTransactionFailed;
        switch (recovery.operation) {
            .install => {
                root.dir.deleteTree(root.io, asset.target_entry) catch
                    return error.FileTransactionFailed;
                try self.inventory.remove(install_id);
            },
            .replace => {
                const backup = recovery.backup_entry orelse return error.InvalidTransaction;
                const backup_exists = directDirectoryExists(root, backup) catch
                    return error.FileTransactionFailed;
                const target_exists = directDirectoryExists(root, asset.target_entry) catch
                    return error.FileTransactionFailed;
                if (backup_exists) {
                    if (target_exists) root.dir.deleteTree(root.io, asset.target_entry) catch
                        return error.FileTransactionFailed;
                    root.dir.rename(backup, root.dir, asset.target_entry, root.io) catch
                        return error.FileTransactionFailed;
                } else if (!target_exists) return error.FileTransactionFailed;
                if (recovery.remove_asset_on_rollback)
                    try self.inventory.remove(install_id)
                else
                    try self.inventory.clearTransaction(install_id);
            },
            .uninstall => {
                const backup = recovery.backup_entry orelse return error.InvalidTransaction;
                const backup_exists = directDirectoryExists(root, backup) catch
                    return error.FileTransactionFailed;
                const target_exists = directDirectoryExists(root, asset.target_entry) catch
                    return error.FileTransactionFailed;
                if (backup_exists) {
                    if (target_exists) return error.FileTransactionFailed;
                    root.dir.rename(backup, root.dir, asset.target_entry, root.io) catch
                        return error.FileTransactionFailed;
                } else if (!target_exists) return error.FileTransactionFailed;
                try self.inventory.clearTransaction(install_id);
            },
        }
        try self.persist();
    }

    /// Reconciles a durable phase after process restart without guessing a
    /// catalog result. Published mutations become pending verification;
    /// pre-publish replacements roll back to the last complete directory.
    pub fn recover(
        self: *Transactions,
        root: *CanonicalRoot,
        install_id: InstallId,
        now_unix_seconds: u64,
    ) Error!void {
        const asset = self.inventory.find(install_id) orelse return error.AssetNotFound;
        if (!scopeMatchesRoot(asset.scope, root)) return error.RootUnavailable;
        const recovery = asset.recovery orelse return;
        switch (recovery.phase) {
            .prepared => {
                if (recovery.candidate_entry) |candidate|
                    root.dir.deleteTree(root.io, candidate) catch
                        return error.FileTransactionFailed;
                if (recovery.operation == .install or recovery.remove_asset_on_rollback)
                    try self.inventory.remove(install_id)
                else
                    try self.inventory.clearTransaction(install_id);
                try self.persist();
            },
            .backup_renamed => if (recovery.operation == .uninstall)
                try self.markReconciliationUnavailable(install_id)
            else
                try self.rollbackReconciliation(root, install_id),
            .candidate_published => try self.markReconciliationUnavailable(install_id),
            .reconciliation_pending => {},
            .reconciled => try self.commitReconciliation(
                root,
                install_id,
                recovery.candidate_hash,
                now_unix_seconds,
            ),
            .rollback_pending => try self.rollbackReconciliation(root, install_id),
        }
    }

    fn persist(self: *Transactions) Error!void {
        const output = try self.allocator.alloc(u8, max_store_bytes);
        defer self.allocator.free(output);
        const bytes = try encode(output, &self.inventory);
        self.persistence.commit(bytes) catch |err| return switch (err) {
            error.PersistenceOutcomeUnknown => error.PersistenceOutcomeUnknown,
            else => error.PersistenceFailed,
        };
    }
};

pub fn generateInstallId(io: std.Io) FileStoreError!InstallId {
    var result: InstallId = undefined;
    std.Io.randomSecure(io, &result) catch return error.WriteFailed;
    return result;
}

pub const FileStore = struct {
    io: std.Io,
    dir: std.Io.Dir,

    pub fn init(io: std.Io, absolute_directory: []const u8) FileStoreError!FileStore {
        if (!std.fs.path.isAbsolute(absolute_directory)) return error.DirectoryUnavailable;
        const dir = std.Io.Dir.cwd().createDirPathOpen(io, absolute_directory, .{
            .open_options = .{ .follow_symlinks = false },
            .permissions = directoryPermissions(),
        }) catch return error.DirectoryUnavailable;
        return .{ .io = io, .dir = dir };
    }

    pub fn deinit(self: *FileStore) void {
        self.dir.close(self.io);
        self.* = undefined;
    }

    pub fn loadAlloc(self: *FileStore, allocator: std.mem.Allocator) FileStoreError!?[]u8 {
        var file = self.dir.openFile(self.io, file_name, .{
            .follow_symlinks = false,
            .resolve_beneath = true,
        }) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return error.ReadFailed,
        };
        if (builtin.os.tag == .windows) file.flags.nonblocking = true;
        defer file.close(self.io);
        const length = file.length(self.io) catch return error.ReadFailed;
        if (length == 0 or length > max_store_bytes) return error.ReadFailed;
        const bytes = try allocator.alloc(u8, @intCast(length));
        errdefer allocator.free(bytes);
        const read = file.readPositionalAll(self.io, bytes, 0) catch return error.ReadFailed;
        if (read != length) return error.ReadFailed;
        return bytes;
    }

    pub fn commit(self: *FileStore, bytes: []const u8) FileStoreError!void {
        if (bytes.len == 0 or bytes.len > max_store_bytes) return error.WriteFailed;
        var random: [8]u8 = undefined;
        std.Io.randomSecure(self.io, &random) catch return error.WriteFailed;
        const random_hex = std.fmt.bytesToHex(random, .lower);
        var temp_name_storage: [64]u8 = undefined;
        var name_writer = std.Io.Writer.fixed(&temp_name_storage);
        name_writer.print(".skill-management.{s}.tmp", .{random_hex}) catch
            return error.WriteFailed;
        const temp_name = name_writer.buffered();
        const file = self.dir.createFile(self.io, temp_name, .{
            .exclusive = true,
            .permissions = privateFilePermissions(),
            .resolve_beneath = true,
        }) catch return error.WriteFailed;
        var file_open = true;
        var temp_exists = true;
        defer {
            if (file_open) file.close(self.io);
            if (temp_exists) self.dir.deleteFile(self.io, temp_name) catch {};
        }
        file.writeStreamingAll(self.io, bytes) catch return error.WriteFailed;
        file.sync(self.io) catch return error.WriteFailed;
        file.close(self.io);
        file_open = false;
        self.dir.rename(temp_name, self.dir, file_name, self.io) catch
            return error.WriteFailed;
        temp_exists = false;
        if (!self.syncCommit()) return error.PersistenceOutcomeUnknown;
    }

    fn syncCommit(self: *FileStore) bool {
        if (builtin.os.tag == .windows) {
            const file = self.dir.openFile(self.io, file_name, .{
                .mode = .read_write,
                .allow_directory = false,
                .follow_symlinks = false,
                .resolve_beneath = true,
            }) catch return false;
            defer file.close(self.io);
            file.sync(self.io) catch return false;
            return true;
        }
        const directory_file: std.Io.File = .{
            .handle = self.dir.handle,
            .flags = .{ .nonblocking = false },
        };
        directory_file.sync(self.io) catch return false;
        return true;
    }
};

const StoreWire = struct {
    schema_version: u8,
    assets: []AssetWire,
};

const AssetWire = struct {
    install_id: []const u8,
    source_kind: []const u8,
    scope: ScopeWire,
    target_entry: []const u8,
    content_hash: []const u8,
    installed_at_unix_seconds: u64,
    reimported_at_unix_seconds: ?u64,
    state: []const u8,
    recovery: ?RecoveryWire,
};

const ScopeWire = struct {
    kind: []const u8,
    workspace_id: ?u64,
    workspace_epoch: ?u64,
};

const RecoveryWire = struct {
    operation: []const u8,
    phase: []const u8,
    remove_asset_on_rollback: bool,
    candidate_hash: ?[]const u8,
    candidate_entry: ?[]const u8,
    backup_entry: ?[]const u8,
};

pub fn encode(output: []u8, inventory: *const Inventory) Error![]const u8 {
    if (output.len == 0) return error.StoreEncodeFailed;
    var writer = std.Io.Writer.fixed(output);
    writer.print("{{\"schema_version\":{d},\"assets\":[", .{schema_version}) catch
        return error.StoreEncodeFailed;
    for (inventory.assets.items, 0..) |asset, index| {
        if (index != 0) writer.writeByte(',') catch return error.StoreEncodeFailed;
        encodeAsset(&writer, asset) catch return error.StoreEncodeFailed;
    }
    writer.writeAll("]}") catch return error.StoreEncodeFailed;
    const bytes = writer.buffered();
    if (bytes.len > max_store_bytes) return error.StoreTooLarge;
    return bytes;
}

pub fn decode(
    allocator: std.mem.Allocator,
    input: []const u8,
    limits: Limits,
) Error!Inventory {
    if (input.len == 0) return error.StoreEmpty;
    if (input.len > max_store_bytes) return error.StoreTooLarge;
    var parsed = std.json.parseFromSlice(StoreWire, allocator, input, .{
        .ignore_unknown_fields = false,
    }) catch return error.StoreCorrupt;
    defer parsed.deinit();
    if (parsed.value.schema_version != schema_version or
        parsed.value.assets.len > limits.max_assets)
        return error.StoreCorrupt;
    var inventory = Inventory.init(allocator, limits);
    errdefer inventory.deinit();
    for (parsed.value.assets) |wire| {
        const install_id = parseHex(InstallId, wire.install_id) orelse
            return error.StoreCorrupt;
        const content_hash = parseHex(ContentHash, wire.content_hash) orelse
            return error.StoreCorrupt;
        const source_kind = std.meta.stringToEnum(SourceKind, wire.source_kind) orelse
            return error.StoreCorrupt;
        const state = std.meta.stringToEnum(ManagementState, wire.state) orelse
            return error.StoreCorrupt;
        const scope = parseScope(wire.scope) orelse return error.StoreCorrupt;
        const decoded_state: ManagementState = if (state == .pending_verification)
            .ready
        else
            state;
        const asset = inventory.add(.{
            .install_id = install_id,
            .source_kind = source_kind,
            .scope = scope,
            .target_entry = wire.target_entry,
            .content_hash = content_hash,
            .installed_at_unix_seconds = wire.installed_at_unix_seconds,
            .reimported_at_unix_seconds = wire.reimported_at_unix_seconds,
            .state = decoded_state,
        }) catch return error.StoreCorrupt;
        if (wire.recovery) |recovery| {
            const operation = std.meta.stringToEnum(Operation, recovery.operation) orelse
                return error.StoreCorrupt;
            const phase = std.meta.stringToEnum(TransactionPhase, recovery.phase) orelse
                return error.StoreCorrupt;
            const candidate_hash = if (recovery.candidate_hash) |value|
                parseHex(ContentHash, value) orelse return error.StoreCorrupt
            else
                null;
            inventory.beginTransaction(asset.install_id, .{
                .operation = operation,
                .phase = phase,
                .remove_asset_on_rollback = recovery.remove_asset_on_rollback,
                .candidate_hash = candidate_hash,
                .candidate_entry = recovery.candidate_entry,
                .backup_entry = recovery.backup_entry,
            }) catch return error.StoreCorrupt;
            if (state == .pending_verification) {
                if (phase != .reconciliation_pending) return error.StoreCorrupt;
                asset.state = .pending_verification;
            }
        } else if (state == .pending_verification) {
            return error.StoreCorrupt;
        }
    }
    return inventory;
}

fn encodeAsset(writer: *std.Io.Writer, asset: Asset) !void {
    const id_hex = std.fmt.bytesToHex(asset.install_id, .lower);
    const hash_hex = std.fmt.bytesToHex(asset.content_hash, .lower);
    try writer.writeAll("{\"install_id\":");
    try jsonString(writer, &id_hex);
    try writer.writeAll(",\"source_kind\":");
    try jsonString(writer, @tagName(asset.source_kind));
    try writer.writeAll(",\"scope\":");
    switch (asset.scope) {
        .personal => try writer.writeAll("{\"kind\":\"personal\",\"workspace_id\":null,\"workspace_epoch\":null}"),
        .project => |project| try writer.print(
            "{{\"kind\":\"project\",\"workspace_id\":{d},\"workspace_epoch\":{d}}}",
            .{ project.workspace_id, project.workspace_epoch },
        ),
    }
    try writer.writeAll(",\"target_entry\":");
    try jsonString(writer, asset.target_entry);
    try writer.writeAll(",\"content_hash\":");
    try jsonString(writer, &hash_hex);
    try writer.print(",\"installed_at_unix_seconds\":{d},\"reimported_at_unix_seconds\":", .{asset.installed_at_unix_seconds});
    if (asset.reimported_at_unix_seconds) |value|
        try writer.print("{d}", .{value})
    else
        try writer.writeAll("null");
    try writer.writeAll(",\"state\":");
    try jsonString(writer, @tagName(asset.state));
    try writer.writeAll(",\"recovery\":");
    if (asset.recovery) |recovery| {
        try writer.writeAll("{\"operation\":");
        try jsonString(writer, @tagName(recovery.operation));
        try writer.writeAll(",\"phase\":");
        try jsonString(writer, @tagName(recovery.phase));
        try writer.print(",\"remove_asset_on_rollback\":{}", .{recovery.remove_asset_on_rollback});
        try writer.writeAll(",\"candidate_hash\":");
        if (recovery.candidate_hash) |hash| {
            const candidate_hex = std.fmt.bytesToHex(hash, .lower);
            try jsonString(writer, &candidate_hex);
        } else try writer.writeAll("null");
        try writer.writeAll(",\"candidate_entry\":");
        try encodeOptionalString(writer, recovery.candidate_entry);
        try writer.writeAll(",\"backup_entry\":");
        try encodeOptionalString(writer, recovery.backup_entry);
        try writer.writeByte('}');
    } else {
        try writer.writeAll("null");
    }
    try writer.writeByte('}');
}

fn validAssetInput(input: AssetInput) bool {
    if (allZero(&input.install_id) or input.installed_at_unix_seconds == 0 or
        (input.reimported_at_unix_seconds != null and
            input.reimported_at_unix_seconds.? < input.installed_at_unix_seconds) or
        input.state == .pending_verification or
        (input.state == .externally_managed and input.source_kind != .external))
        return false;
    if (!validTargetEntry(input.target_entry)) return false;
    return switch (input.scope) {
        .personal => true,
        .project => |project| project.workspace_id != 0 and project.workspace_epoch != 0,
    };
}

fn validRecovery(asset: *const Asset, input: RecoveryInput) bool {
    if (asset.state == .externally_managed) return false;
    if (input.candidate_entry) |entry| if (!validTransactionEntry(entry)) return false;
    if (input.backup_entry) |entry| if (!validTransactionEntry(entry)) return false;
    if (input.candidate_entry != null and input.backup_entry != null and
        targetEntryEqual(input.candidate_entry.?, input.backup_entry.?))
        return false;
    return switch (input.operation) {
        .install => input.candidate_entry != null and input.backup_entry == null and
            input.phase != .backup_renamed,
        .replace => input.candidate_entry != null and input.backup_entry != null,
        .uninstall => input.candidate_entry == null and input.backup_entry != null and
            input.phase != .candidate_published and !input.remove_asset_on_rollback,
    };
}

fn validTargetEntry(value: []const u8) bool {
    if (value.len == 0 or value.len > max_target_entry_bytes or
        std.mem.findScalar(u8, value, '/') != null or
        std.mem.findScalar(u8, value, '\\') != null)
        return false;
    skill_package.validateRelativePath(value, .{}) catch return false;
    return true;
}

fn validTransactionEntry(value: []const u8) bool {
    return validTargetEntry(value) and value[0] == '.';
}

fn targetEntryEqual(left: []const u8, right: []const u8) bool {
    return if (builtin.os.tag == .windows)
        std.ascii.eqlIgnoreCase(left, right)
    else
        std.mem.eql(u8, left, right);
}

fn parseScope(wire: ScopeWire) ?Scope {
    if (std.mem.eql(u8, wire.kind, "personal")) {
        if (wire.workspace_id != null or wire.workspace_epoch != null) return null;
        return .personal;
    }
    if (std.mem.eql(u8, wire.kind, "project")) {
        const workspace_id = wire.workspace_id orelse return null;
        const workspace_epoch = wire.workspace_epoch orelse return null;
        if (workspace_id == 0 or workspace_epoch == 0) return null;
        return .{ .project = .{
            .workspace_id = workspace_id,
            .workspace_epoch = workspace_epoch,
        } };
    }
    return null;
}

fn parseHex(comptime T: type, value: []const u8) ?T {
    var result: T = undefined;
    if (value.len != result.len * 2) return null;
    _ = std.fmt.hexToBytes(&result, value) catch return null;
    return result;
}

fn allZero(value: []const u8) bool {
    for (value) |byte| if (byte != 0) return false;
    return true;
}

fn encodeOptionalString(writer: *std.Io.Writer, value: ?[]const u8) !void {
    if (value) |text| return jsonString(writer, text);
    try writer.writeAll("null");
}

fn jsonString(writer: *std.Io.Writer, value: []const u8) !void {
    try std.json.Stringify.value(value, .{}, writer);
}

fn directoryPermissions() std.Io.File.Permissions {
    return if (builtin.os.tag == .windows) .default_dir else .fromMode(0o700);
}

fn privateFilePermissions() std.Io.File.Permissions {
    return if (builtin.os.tag == .windows) .default_file else .fromMode(0o600);
}

fn repeatedByte(comptime length: usize, byte: u8) [length]u8 {
    return [_]u8{byte} ** length;
}

test "inventory keeps install identity separate from target and runtime identity" {
    var inventory = Inventory.init(std.testing.allocator, .{ .max_assets = 4 });
    defer inventory.deinit();
    const id = repeatedByte(install_id_bytes, 0x11);
    const asset = try inventory.add(.{
        .install_id = id,
        .source_kind = .local_package,
        .scope = .personal,
        .target_entry = "review-skill",
        .content_hash = repeatedByte(hash_bytes, 0x22),
        .installed_at_unix_seconds = 100,
    });
    try std.testing.expectEqualStrings("review-skill", asset.target_entry);
    try std.testing.expectError(error.DuplicateInstallId, inventory.add(.{
        .install_id = id,
        .source_kind = .local_directory,
        .scope = .personal,
        .target_entry = "another-skill",
        .content_hash = repeatedByte(hash_bytes, 0x33),
        .installed_at_unix_seconds = 101,
    }));
    try std.testing.expectError(error.DuplicateTarget, inventory.add(.{
        .install_id = repeatedByte(install_id_bytes, 0x44),
        .source_kind = .local_directory,
        .scope = .personal,
        .target_entry = "review-skill",
        .content_hash = repeatedByte(hash_bytes, 0x55),
        .installed_at_unix_seconds = 101,
    }));
}

test "inventory persists pending reconciliation recovery without secrets" {
    var inventory = Inventory.init(std.testing.allocator, .{ .max_assets = 4 });
    defer inventory.deinit();
    const id = repeatedByte(install_id_bytes, 0x10);
    _ = try inventory.add(.{
        .install_id = id,
        .source_kind = .local_directory,
        .scope = .{ .project = .{ .workspace_id = 7, .workspace_epoch = 3 } },
        .target_entry = "design-review",
        .content_hash = repeatedByte(hash_bytes, 0x20),
        .installed_at_unix_seconds = 100,
    });
    try inventory.beginTransaction(id, .{
        .operation = .replace,
        .candidate_entry = ".design-review.candidate-a",
        .backup_entry = ".design-review.backup-a",
    });
    try inventory.advanceTransaction(id, .backup_renamed);
    try inventory.advanceTransaction(id, .candidate_published);
    try inventory.markPendingVerification(id);
    var output: [max_store_bytes]u8 = undefined;
    const bytes = try encode(&output, &inventory);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "secret") == null);
    var restored = try decode(std.testing.allocator, bytes, .{ .max_assets = 4 });
    defer restored.deinit();
    const asset = restored.find(id).?;
    try std.testing.expectEqual(ManagementState.pending_verification, asset.state);
    try std.testing.expectEqual(TransactionPhase.reconciliation_pending, asset.recovery.?.phase);
    try std.testing.expectEqualStrings(".design-review.backup-a", asset.recovery.?.backup_entry.?);
}

test "inventory decoder rejects unknown fields and invalid direct entries" {
    try std.testing.expectError(error.StoreCorrupt, decode(
        std.testing.allocator,
        "{\"schema_version\":2,\"assets\":[]}",
        .{},
    ));
    try std.testing.expectError(error.StoreCorrupt, decode(
        std.testing.allocator,
        "{\"schema_version\":1,\"assets\":[],\"extra\":true}",
        .{},
    ));
    const invalid =
        "{\"schema_version\":1,\"assets\":[{" ++
        "\"install_id\":\"11111111111111111111111111111111\"," ++
        "\"source_kind\":\"external\"," ++
        "\"scope\":{\"kind\":\"personal\",\"workspace_id\":null,\"workspace_epoch\":null}," ++
        "\"target_entry\":\"../escape\"," ++
        "\"content_hash\":\"2222222222222222222222222222222222222222222222222222222222222222\"," ++
        "\"installed_at_unix_seconds\":1,\"reimported_at_unix_seconds\":null," ++
        "\"state\":\"ready\",\"recovery\":null}]}";
    try std.testing.expectError(error.StoreCorrupt, decode(std.testing.allocator, invalid, .{}));
}

test "skill inventory file store atomically replaces bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store: FileStore = .{ .io = std.testing.io, .dir = tmp.dir };
    try store.commit("{\"schema_version\":1,\"assets\":[]}");
    const restored = (try store.loadAlloc(std.testing.allocator)).?;
    defer std.testing.allocator.free(restored);
    try std.testing.expectEqualStrings("{\"schema_version\":1,\"assets\":[]}", restored);
}

test "publish and reconciliation commit install one bounded Skill directory" {
    var source = std.testing.tmpDir(.{ .iterate = true });
    defer source.cleanup();
    try source.dir.writeFile(std.testing.io, .{
        .sub_path = "SKILL.md",
        .data = "---\nname: demo\ndescription: Demo\n---\n",
    });
    var manifest = try skill_package.inspectDirectory(
        std.testing.io,
        std.testing.allocator,
        source.dir,
        .{},
    );
    defer manifest.deinit();
    var target = std.testing.tmpDir(.{});
    defer target.cleanup();
    var target_path_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const target_path_len = try target.dir.realPath(std.testing.io, &target_path_storage);
    var root = try CanonicalRoot.open(
        std.testing.io,
        std.testing.allocator,
        .personal,
        target_path_storage[0..target_path_len],
    );
    defer root.deinit();
    var persistence_dir = std.testing.tmpDir(.{});
    defer persistence_dir.cleanup();
    var persistence: FileStore = .{ .io = std.testing.io, .dir = persistence_dir.dir };
    var transactions = Transactions.init(
        std.testing.io,
        std.testing.allocator,
        Inventory.init(std.testing.allocator, .{}),
        &persistence,
    );
    defer transactions.deinit();
    const id = repeatedByte(install_id_bytes, 0x31);
    const published = try transactions.publish(&root, source.dir, &manifest, .{
        .asset = .{
            .install_id = id,
            .source_kind = .local_directory,
            .scope = .personal,
            .target_entry = "demo",
            .content_hash = manifest.content_hash,
            .installed_at_unix_seconds = 100,
        },
    });
    try std.testing.expect(!published.replaced_existing);
    try std.testing.expectEqual(TransactionPhase.candidate_published, transactions.inventory.find(id).?.recovery.?.phase);
    try expectFileContents(root.dir, "demo/SKILL.md", "---\nname: demo\ndescription: Demo\n---\n");
    try transactions.commitReconciliation(&root, id, null, 101);
    try std.testing.expect(transactions.inventory.find(id).?.recovery == null);
    try std.testing.expectEqual(ManagementState.ready, transactions.inventory.find(id).?.state);
}

test "candidate rejection restores an existing external directory" {
    var source = std.testing.tmpDir(.{ .iterate = true });
    defer source.cleanup();
    try source.dir.writeFile(std.testing.io, .{ .sub_path = "SKILL.md", .data = "new" });
    var manifest = try skill_package.inspectDirectory(
        std.testing.io,
        std.testing.allocator,
        source.dir,
        .{},
    );
    defer manifest.deinit();
    var target = std.testing.tmpDir(.{});
    defer target.cleanup();
    try target.dir.createDir(std.testing.io, "demo", .default_dir);
    try target.dir.writeFile(std.testing.io, .{ .sub_path = "demo/SKILL.md", .data = "old" });
    var target_path_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const target_path_len = try target.dir.realPath(std.testing.io, &target_path_storage);
    var root = try CanonicalRoot.open(
        std.testing.io,
        std.testing.allocator,
        .personal,
        target_path_storage[0..target_path_len],
    );
    defer root.deinit();
    var persistence_dir = std.testing.tmpDir(.{});
    defer persistence_dir.cleanup();
    var persistence: FileStore = .{ .io = std.testing.io, .dir = persistence_dir.dir };
    var transactions = Transactions.init(
        std.testing.io,
        std.testing.allocator,
        Inventory.init(std.testing.allocator, .{}),
        &persistence,
    );
    defer transactions.deinit();
    const id = repeatedByte(install_id_bytes, 0x41);
    const published = try transactions.publish(&root, source.dir, &manifest, .{
        .asset = .{
            .install_id = id,
            .source_kind = .local_package,
            .scope = .personal,
            .target_entry = "demo",
            .content_hash = manifest.content_hash,
            .installed_at_unix_seconds = 100,
        },
        .allow_replace = true,
    });
    try std.testing.expect(published.replaced_existing);
    try expectFileContents(root.dir, "demo/SKILL.md", "new");
    try transactions.rollbackReconciliation(&root, id);
    try std.testing.expect(transactions.inventory.find(id) == null);
    try expectFileContents(root.dir, "demo/SKILL.md", "old");
}

fn expectFileContents(dir: std.Io.Dir, path: []const u8, expected: []const u8) !void {
    const file = try dir.openFile(std.testing.io, path, .{
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    });
    defer file.close(std.testing.io);
    var storage: [512]u8 = undefined;
    const read = try file.readPositionalAll(std.testing.io, storage[0..expected.len], 0);
    try std.testing.expectEqual(expected.len, read);
    try std.testing.expectEqualStrings(expected, storage[0..read]);
}
