//! Live local-asset use cases inside the Product Skill aggregate.
//! Owns package I/O, management mutations, recovery, and catalog reconciliation.
//! The aggregate Runtime retains catalog scheduling and the public owner boundary.

const std = @import("std");
const builtin = @import("builtin");
const catalog = @import("product_skill_catalog");
const management = @import("product_skill_management");
const package = @import("product_skill_package");
const policy = @import("product_skill_policy");
const state = @import("product_skill_state");

pub const Error = package.Error || management.Error || error{
    PersistenceFailed,
    InvalidAsset,
    AssetNotFound,
    TargetUnavailable,
    DestinationUnavailable,
    TargetAlreadyExists,
    WriteFailed,
    RecoveryUnavailable,
    InvalidPreparation,
    InvalidConfirmation,
    PreparationExhausted,
    SourceChanged,
    TargetChanged,
    TaskBusy,
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    state: *state.State,
};

pub fn previewDirectory(
    context: Context,
    absolute_path: []const u8,
) Error!package.Preview {
    const source = try openDirectorySource(context, absolute_path);
    defer source.close(context.io);
    var preview = try package.previewDirectory(context.io, context.allocator, source, .{});
    errdefer preview.deinit();
    const canonical = source.realPathFileAlloc(context.io, ".", context.allocator) catch return error.SourceUnavailable;
    defer context.allocator.free(canonical);
    preview.source_root = try context.allocator.dupe(u8, canonical);
    return preview;
}

fn openDirectorySource(context: Context, absolute_path: []const u8) Error!std.Io.Dir {
    if (!std.fs.path.isAbsolute(absolute_path) or
        !std.unicode.utf8ValidateSlice(absolute_path))
        return error.InvalidAsset;
    const selected = std.Io.Dir.openDirAbsolute(
        context.io,
        absolute_path,
        .{ .follow_symlinks = false, .iterate = true },
    ) catch return error.SourceUnavailable;
    defer selected.close(context.io);
    return package.openDirectorySource(context.io, context.allocator, selected, .{});
}

pub fn previewArchive(
    context: Context,
    absolute_path: []const u8,
) Error!package.Preview {
    if (!std.fs.path.isAbsolute(absolute_path) or
        !std.unicode.utf8ValidateSlice(absolute_path) or
        !hasArchiveExtension(absolute_path))
        return error.InvalidAsset;
    var archive = std.Io.Dir.openFileAbsolute(
        context.io,
        absolute_path,
        .{ .follow_symlinks = false },
    ) catch return error.SourceUnavailable;
    defer archive.close(context.io);
    if (builtin.os.tag == .windows) archive.flags.nonblocking = true;
    const inspection = try package.inspectArchive(
        context.io,
        context.allocator,
        archive,
        .{},
    );
    const staging = try openStagingRoot(context);
    defer staging.close(context.io);
    var random: [16]u8 = undefined;
    std.Io.randomSecure(context.io, &random) catch return error.PersistenceFailed;
    const hex = std.fmt.bytesToHex(random, .lower);
    var scratch_name: [47]u8 = undefined;
    @memcpy(scratch_name[0..15], ".skill-preview-");
    @memcpy(scratch_name[15..], &hex);
    staging.createDir(context.io, &scratch_name, privateDirectoryPermissions()) catch
        return error.PersistenceFailed;
    defer staging.deleteTree(context.io, &scratch_name) catch {};
    const scratch = staging.openDir(context.io, &scratch_name, .{
        .follow_symlinks = false,
        .iterate = true,
    }) catch return error.PersistenceFailed;
    defer scratch.close(context.io);
    try package.extractArchive(context.io, archive, scratch);
    const source = if (inspection.wrapperName()) |wrapper|
        scratch.openDir(context.io, wrapper, .{
            .follow_symlinks = false,
            .iterate = true,
        }) catch return error.InvalidAsset
    else
        scratch;
    defer if (inspection.wrapperName() != null) source.close(context.io);
    var preview = try package.previewDirectory(context.io, context.allocator, source, .{});
    errdefer preview.deinit();
    preview.source_root = try context.allocator.dupe(u8, inspection.wrapperName() orelse "");
    return preview;
}

/// Observe a target without creating .agents/skills or changing inventory.
pub fn inspectImportTarget(context: Context, canonical_base: []const u8, scope: management.Scope, invocation: []const u8, reimport_id: ?management.InstallId) Error!state.ImportExpectation {
    const asset = context.state.inventoryConst().findTarget(scope, invocation);
    if (reimport_id) |id| {
        if (asset == null or !std.mem.eql(u8, &id, &asset.?.install_id)) return error.TargetChanged;
    }
    if (asset) |current| if (current.state != .ready or current.recovery != null) return error.TaskBusy;
    const base = std.Io.Dir.openDirAbsolute(context.io, canonical_base, .{ .follow_symlinks = false }) catch return error.RootUnavailable;
    defer base.close(context.io);
    const base_stat = base.stat(context.io) catch return error.RootUnavailable;
    var absent: state.ImportExpectation = .{ .effect = .create, .base_inode = base_stat.inode };
    const agents = base.openDir(context.io, ".agents", .{ .follow_symlinks = false }) catch |err| return if (err == error.FileNotFound and asset == null) absent else error.TargetUnavailable;
    defer agents.close(context.io);
    const skills = agents.openDir(context.io, "skills", .{ .follow_symlinks = false }) catch |err| return if (err == error.FileNotFound and asset == null) absent else error.TargetUnavailable;
    defer skills.close(context.io);
    const root_stat = skills.stat(context.io) catch return error.TargetUnavailable;
    absent.root_inode = root_stat.inode;
    const target = skills.openDir(context.io, invocation, .{ .follow_symlinks = false, .iterate = true }) catch |err| return if (err == error.FileNotFound and asset == null) absent else error.TargetUnavailable;
    defer target.close(context.io);
    var manifest = try package.inspectResourceTree(context.io, context.allocator, target, .{});
    defer manifest.deinit();
    return .{
        .effect = if (asset != null) .update else .replace_directory,
        .install_id = if (asset) |current| current.install_id else null,
        .record_hash = if (asset) |current| current.content_hash else null,
        .content_hash = manifest.content_hash,
        .base_inode = base_stat.inode,
        .root_inode = root_stat.inode,
        .target_inode = (target.stat(context.io) catch return error.TargetUnavailable).inode,
    };
}

pub fn readDefinition(
    context: Context,
    scope: management.Scope,
    install_id: management.InstallId,
    canonical_base: []const u8,
) Error!package.Preview {
    const current = context.state.inventoryConst().findConst(install_id) orelse
        return error.AssetNotFound;
    if (current.recovery != null) return error.InvalidAsset;
    var root = try openManagedRoot(context, scope, canonical_base);
    defer root.deinit();
    const source = root.dir.openDir(
        context.io,
        current.target_entry,
        .{ .follow_symlinks = false, .iterate = true },
    ) catch return error.TargetUnavailable;
    defer source.close(context.io);
    return package.previewDirectory(context.io, context.allocator, source, .{});
}

pub fn exportPackage(
    context: Context,
    scope: management.Scope,
    install_id: management.InstallId,
    canonical_base: []const u8,
    absolute_destination: []const u8,
) Error!state.ExportResult {
    if (!std.fs.path.isAbsolute(absolute_destination) or
        !std.unicode.utf8ValidateSlice(absolute_destination))
        return error.InvalidAsset;
    const current = context.state.inventoryConst().findConst(install_id) orelse
        return error.AssetNotFound;
    if (current.state != .ready or current.recovery != null)
        return error.InvalidAsset;
    var root = try openManagedRoot(context, scope, canonical_base);
    defer root.deinit();
    const source = root.dir.openDir(
        context.io,
        current.target_entry,
        .{ .follow_symlinks = false, .iterate = true },
    ) catch return error.TargetUnavailable;
    defer source.close(context.io);
    var manifest = try package.inspectDirectory(
        context.io,
        context.allocator,
        source,
        .{},
    );
    defer manifest.deinit();
    const destination = std.Io.Dir.openDirAbsolute(
        context.io,
        absolute_destination,
        .{ .follow_symlinks = false },
    ) catch return error.DestinationUnavailable;
    defer destination.close(context.io);
    var result: state.ExportResult = .{
        .file_name = undefined,
        .file_name_len = current.target_entry.len + ".skill".len,
    };
    @memcpy(result.file_name[0..current.target_entry.len], current.target_entry);
    @memcpy(result.file_name[current.target_entry.len..result.file_name_len], ".skill");
    const output = destination.createFile(context.io, result.fileName(), .{
        .exclusive = true,
        .permissions = privateFilePermissions(),
        .resolve_beneath = true,
    }) catch |err| return switch (err) {
        error.PathAlreadyExists => error.TargetAlreadyExists,
        else => error.DestinationUnavailable,
    };
    var output_open = true;
    var output_exists = true;
    defer {
        if (output_open) output.close(context.io);
        if (output_exists) destination.deleteFile(context.io, result.fileName()) catch {};
    }
    try package.exportArchive(context.io, source, output, &manifest);
    output.sync(context.io) catch return error.WriteFailed;
    output.close(context.io);
    output_open = false;
    output_exists = false;
    return result;
}

pub fn installDirectory(
    context: Context,
    canonical_base: []const u8,
    absolute_path: []const u8,
    input: state.InstallInput,
    now_unix_seconds: ?u64,
) Error!state.MutationResult {
    if (input.source_kind != .local_directory) return error.InvalidAsset;
    const source = try openDirectorySource(context, absolute_path);
    defer source.close(context.io);
    return installSource(context, canonical_base, source, input, now_unix_seconds);
}

pub fn installArchive(
    context: Context,
    canonical_base: []const u8,
    absolute_path: []const u8,
    input: state.InstallInput,
    now_unix_seconds: ?u64,
) Error!state.MutationResult {
    if (input.source_kind != .local_package or
        !std.fs.path.isAbsolute(absolute_path) or
        !std.unicode.utf8ValidateSlice(absolute_path) or
        !hasArchiveExtension(absolute_path))
        return error.InvalidAsset;
    var archive = std.Io.Dir.openFileAbsolute(context.io, absolute_path, .{
        .follow_symlinks = false,
    }) catch return error.InvalidAsset;
    defer archive.close(context.io);
    if (builtin.os.tag == .windows) archive.flags.nonblocking = true;
    const inspection = try package.inspectArchive(
        context.io,
        context.allocator,
        archive,
        .{},
    );
    const staging = try openStagingRoot(context);
    defer staging.close(context.io);
    var random: [16]u8 = undefined;
    std.Io.randomSecure(context.io, &random) catch return error.PersistenceFailed;
    const hex = std.fmt.bytesToHex(random, .lower);
    var scratch_name: [46]u8 = undefined;
    @memcpy(scratch_name[0..14], ".skill-import-");
    @memcpy(scratch_name[14..], &hex);
    staging.createDir(context.io, &scratch_name, privateDirectoryPermissions()) catch
        return error.PersistenceFailed;
    defer staging.deleteTree(context.io, &scratch_name) catch {};
    const scratch = staging.openDir(context.io, &scratch_name, .{
        .follow_symlinks = false,
        .iterate = true,
    }) catch return error.PersistenceFailed;
    defer scratch.close(context.io);
    try package.extractArchive(context.io, archive, scratch);
    const source = if (inspection.wrapperName()) |wrapper|
        scratch.openDir(context.io, wrapper, .{
            .follow_symlinks = false,
            .iterate = true,
        }) catch return error.InvalidAsset
    else
        scratch;
    defer if (inspection.wrapperName() != null) source.close(context.io);
    return installSource(context, canonical_base, source, input, now_unix_seconds);
}

pub fn reimportDirectory(
    context: Context,
    scope: management.Scope,
    canonical_base: []const u8,
    install_id: management.InstallId,
    absolute_path: []const u8,
    expected_invocation_name: []const u8,
    expected_content_hash: management.ContentHash,
) Error!state.MutationResult {
    const source = try openDirectorySource(context, absolute_path);
    defer source.close(context.io);
    return reimportSource(
        context,
        scope,
        canonical_base,
        install_id,
        source,
        expected_invocation_name,
        expected_content_hash,
    );
}

pub fn reimportArchive(
    context: Context,
    scope: management.Scope,
    canonical_base: []const u8,
    install_id: management.InstallId,
    absolute_path: []const u8,
    expected_invocation_name: []const u8,
    expected_content_hash: management.ContentHash,
) Error!state.MutationResult {
    if (!std.fs.path.isAbsolute(absolute_path) or
        !std.unicode.utf8ValidateSlice(absolute_path) or
        !hasArchiveExtension(absolute_path))
        return error.InvalidAsset;
    var archive = std.Io.Dir.openFileAbsolute(context.io, absolute_path, .{
        .follow_symlinks = false,
    }) catch return error.InvalidAsset;
    defer archive.close(context.io);
    if (builtin.os.tag == .windows) archive.flags.nonblocking = true;
    const inspection = try package.inspectArchive(
        context.io,
        context.allocator,
        archive,
        .{},
    );
    const staging = try openStagingRoot(context);
    defer staging.close(context.io);
    var random: [16]u8 = undefined;
    std.Io.randomSecure(context.io, &random) catch return error.PersistenceFailed;
    const hex = std.fmt.bytesToHex(random, .lower);
    var scratch_name: [48]u8 = undefined;
    @memcpy(scratch_name[0..16], ".skill-reimport-");
    @memcpy(scratch_name[16..], &hex);
    staging.createDir(context.io, &scratch_name, privateDirectoryPermissions()) catch
        return error.PersistenceFailed;
    defer staging.deleteTree(context.io, &scratch_name) catch {};
    const scratch = staging.openDir(context.io, &scratch_name, .{
        .follow_symlinks = false,
        .iterate = true,
    }) catch return error.PersistenceFailed;
    defer scratch.close(context.io);
    try package.extractArchive(context.io, archive, scratch);
    const source = if (inspection.wrapperName()) |wrapper|
        scratch.openDir(context.io, wrapper, .{
            .follow_symlinks = false,
            .iterate = true,
        }) catch return error.InvalidAsset
    else
        scratch;
    defer if (inspection.wrapperName() != null) source.close(context.io);
    return reimportSource(
        context,
        scope,
        canonical_base,
        install_id,
        source,
        expected_invocation_name,
        expected_content_hash,
    );
}

pub fn uninstall(
    context: Context,
    scope: management.Scope,
    canonical_base: []const u8,
    install_id: management.InstallId,
    now_unix_seconds: ?u64,
) Error!state.MutationResult {
    const current = context.state.inventoryConst().findConst(install_id) orelse
        return error.AssetNotFound;
    const target_entry = try context.allocator.dupe(u8, current.target_entry);
    defer context.allocator.free(target_entry);
    const pending_operation = if (current.state == .pending_verification and
        current.recovery != null) current.recovery.?.operation else null;
    var root = try openManagedRoot(context, scope, canonical_base);
    defer root.deinit();
    const transactions = if (context.state.transactions) |*value| value else return error.PersistenceFailed;
    if (pending_operation) |operation| switch (operation) {
        .install => {
            transactions.rollbackReconciliation(&root, install_id) catch |err| {
                recoverAfterFileFailure(context, &root, install_id, now_unix_seconds, err);
                return err;
            };
            return .{ .install_id = install_id, .verification_pending = false };
        },
        .uninstall => {
            const now = validTimestamp(now_unix_seconds) orelse
                return error.PersistenceFailed;
            transactions.commitReconciliation(&root, install_id, null, now) catch |err| {
                recoverAfterFileFailure(context, &root, install_id, now_unix_seconds, err);
                return err;
            };
            return .{ .install_id = install_id, .verification_pending = false };
        },
        .replace => transactions.rollbackReconciliation(&root, install_id) catch |err| {
            recoverAfterFileFailure(context, &root, install_id, now_unix_seconds, err);
            return err;
        },
    };
    transactions.uninstall(&root, install_id) catch |err| {
        recoverAfterFileFailure(context, &root, install_id, now_unix_seconds, err);
        return err;
    };
    transactions.markReconciliationUnavailable(install_id) catch |err| {
        notePersistenceFailure(context, err);
        return err;
    };
    setReconciliation(context, install_id, scope, target_entry, .uninstall);
    return .{ .install_id = install_id, .verification_pending = true };
}

pub fn retryVerification(
    context: Context,
    scope: management.Scope,
    install_id: management.InstallId,
    canonical_base: []const u8,
    now_unix_seconds: ?u64,
) Error!state.MutationResult {
    const before = context.state.inventoryConst().findConst(install_id) orelse
        return error.AssetNotFound;
    if (before.recovery == null) return error.InvalidAsset;
    if (before.requiresRecovery()) {
        var root = try openManagedRoot(context, scope, canonical_base);
        defer root.deinit();
        try recoverOne(context, &root, install_id, now_unix_seconds);
    }
    // Recovery may remove the asset or replace/free its recovery payload.
    const current = context.state.inventoryConst().findConst(install_id) orelse
        return .{ .install_id = install_id, .verification_pending = false };
    if (current.recovery == null)
        return .{ .install_id = install_id, .verification_pending = false };
    if (current.state != .pending_verification) return error.RecoveryUnavailable;
    setReconciliation(
        context,
        install_id,
        scope,
        current.target_entry,
        current.recovery.?.operation,
    );
    return .{ .install_id = install_id, .verification_pending = true };
}

pub fn recoverNoFail(
    context: Context,
    scope: management.Scope,
    canonical_base: []const u8,
    now_unix_seconds: ?u64,
) void {
    if (context.state.management_health != .ready or
        context.state.transactions == null) return;
    var pending: std.ArrayList(management.InstallId) = .empty;
    defer pending.deinit(context.allocator);
    for (context.state.inventoryConst().items()) |asset| {
        if (asset.owner.owns(scope) and asset.recovery != null)
            pending.append(context.allocator, asset.install_id) catch {
                return;
            };
    }
    if (pending.items.len == 0) return;
    var root = openManagedRoot(context, scope, canonical_base) catch return;
    defer root.deinit();
    for (pending.items) |install_id|
        recoverOne(context, &root, install_id, now_unix_seconds) catch return;
}

/// One bounded attempt using the existing durable phase machine. A root or
/// clock failure says nothing about the trustworthiness of the inventory.
fn recoverOne(
    context: Context,
    root: *management.CanonicalRoot,
    install_id: management.InstallId,
    now_unix_seconds: ?u64,
) Error!void {
    if (context.state.management_health != .ready) return error.PersistenceFailed;
    const transactions = if (context.state.transactions) |*value| value else return error.PersistenceFailed;
    const asset = transactions.inventory.findConst(install_id) orelse return;
    const recovery = asset.recovery orelse return;
    const now = validTimestamp(now_unix_seconds) orelse blk: {
        if (recovery.phase == .reconciled and recovery.operation != .uninstall)
            return error.RecoveryUnavailable;
        // These phases do not consume a timestamp.
        break :blk 0;
    };
    transactions.recover(root, install_id, now) catch |err| {
        notePersistenceFailure(context, err);
        return err;
    };
}

fn recoverAfterFileFailure(
    context: Context,
    root: *management.CanonicalRoot,
    install_id: management.InstallId,
    now_unix_seconds: ?u64,
    err: anyerror,
) void {
    notePersistenceFailure(context, err);
    if (err == error.FileTransactionFailed)
        recoverOne(context, root, install_id, now_unix_seconds) catch {};
}

pub fn reconcileNoFail(
    context: Context,
    scope: management.Scope,
    canonical_base: []const u8,
    snapshot: ?*const catalog.Snapshot,
    now_unix_seconds: ?u64,
) void {
    const reconciliation = context.state.reconciliation orelse return;
    if (!reconciliation.scope.eql(scope)) return;
    context.state.reconciliation = null;
    const current = snapshot orelse return;
    const purpose: policy.QueryPurpose = if (scope == .personal) .management else .workspace;
    var found = false;
    for (current.skills) |skill| {
        if (policy.matchManagedContribution(purpose, .workspace_default, reconciliation.invocationName(), skill) == .matched) {
            found = true;
            break;
        }
    }
    var has_matching_issue = false;
    for (current.issues) |issue| {
        if (policy.issueMatchesManaged(purpose, .workspace_default, reconciliation.invocationName(), issue)) {
            has_matching_issue = true;
            break;
        }
    }
    var root = openManagedRoot(context, scope, canonical_base) catch return;
    defer root.deinit();
    const transactions = if (context.state.transactions) |*value| value else return;
    const asset = transactions.inventory.findConst(reconciliation.install_id) orelse return;
    const recovery = asset.recovery orelse return;
    if (context.state.management_health != .ready or recovery.phase != .reconciliation_pending or
        !asset.owner.owns(scope) or recovery.operation != reconciliation.operation or
        !std.mem.eql(u8, asset.target_entry, reconciliation.invocationName())) return;
    const accepted = if (reconciliation.operation == .uninstall) absent: {
        if (found) return;
        _ = root.dir.statFile(context.io, asset.target_entry, .{ .follow_symlinks = false }) catch |err| {
            if (err == error.FileNotFound) break :absent true;
            return;
        };
        return;
    } else published: {
        // Core content revision is not a package hash. Reobserve the exact
        // managed candidate with the existing package owner before accepting
        // or rolling back any files.
        const expected_hash = recovery.candidate_hash orelse return;
        const target = root.dir.openDir(context.io, asset.target_entry, .{ .follow_symlinks = false, .iterate = true }) catch return;
        defer target.close(context.io);
        var manifest = package.inspectDirectory(context.io, context.allocator, target, .{}) catch return;
        defer manifest.deinit();
        if (!std.mem.eql(u8, &expected_hash, &manifest.content_hash)) return;
        if (!found and !has_matching_issue) return;
        break :published found and !has_matching_issue;
    };
    if (accepted) {
        const now = validTimestamp(now_unix_seconds) orelse return;
        transactions.commitReconciliation(
            &root,
            reconciliation.install_id,
            null,
            now,
        ) catch |err| notePersistenceFailure(context, err);
    } else {
        transactions.rollbackReconciliation(
            &root,
            reconciliation.install_id,
        ) catch |err| notePersistenceFailure(context, err);
    }
}

fn installSource(
    context: Context,
    canonical_base: []const u8,
    source: std.Io.Dir,
    input: state.InstallInput,
    now_unix_seconds: ?u64,
) Error!state.MutationResult {
    var preview = try package.previewDirectory(context.io, context.allocator, source, .{});
    defer preview.deinit();
    if (!std.mem.eql(u8, preview.invocation_name, input.expected_invocation_name) or
        !std.mem.eql(u8, &preview.content_hash, &input.expected_content_hash))
        return error.InvalidAsset;
    var manifest = try package.inspectDirectory(context.io, context.allocator, source, .{});
    defer manifest.deinit();
    if (!std.mem.eql(u8, &manifest.content_hash, &input.expected_content_hash))
        return error.InvalidAsset;
    var prepared = try prepareManagedSource(context, source, &manifest);
    defer prepared.deinit(context.io);
    var root = try openManagedRoot(context, input.scope, canonical_base);
    defer root.deinit();
    const now = validTimestamp(now_unix_seconds) orelse return error.PersistenceFailed;
    const install_id = management.generateInstallId(context.io) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.PersistenceFailed,
    };
    const transactions = if (context.state.transactions) |*value| value else return error.PersistenceFailed;
    const published = transactions.publish(&root, prepared.dir, &prepared.manifest, .{
        .asset = .{
            .install_id = install_id,
            .source_kind = input.source_kind,
            .scope = input.scope,
            .target_entry = preview.invocation_name,
            .content_hash = prepared.manifest.content_hash,
            .installed_at_unix_seconds = now,
        },
        .allow_replace = input.allow_replace,
    }) catch |err| {
        recoverAfterFileFailure(context, &root, install_id, now_unix_seconds, err);
        return err;
    };
    transactions.markReconciliationUnavailable(install_id) catch |err| {
        notePersistenceFailure(context, err);
        return err;
    };
    setReconciliation(
        context,
        install_id,
        input.scope,
        preview.invocation_name,
        if (published.replaced_existing) .replace else .install,
    );
    return .{ .install_id = install_id, .verification_pending = true };
}

fn reimportSource(
    context: Context,
    scope: management.Scope,
    canonical_base: []const u8,
    install_id: management.InstallId,
    source: std.Io.Dir,
    expected_invocation_name: []const u8,
    expected_content_hash: management.ContentHash,
) Error!state.MutationResult {
    const current = context.state.inventoryConst().findConst(install_id) orelse
        return error.AssetNotFound;
    const target_entry = try context.allocator.dupe(u8, current.target_entry);
    defer context.allocator.free(target_entry);
    var preview = try package.previewDirectory(context.io, context.allocator, source, .{});
    defer preview.deinit();
    if (!std.mem.eql(u8, preview.invocation_name, expected_invocation_name) or
        !std.mem.eql(u8, preview.invocation_name, target_entry) or
        !std.mem.eql(u8, &preview.content_hash, &expected_content_hash))
        return error.InvalidAsset;
    var manifest = try package.inspectDirectory(context.io, context.allocator, source, .{});
    defer manifest.deinit();
    if (!std.mem.eql(u8, &manifest.content_hash, &expected_content_hash))
        return error.InvalidAsset;
    var prepared = try prepareManagedSource(context, source, &manifest);
    defer prepared.deinit(context.io);
    var root = try openManagedRoot(context, scope, canonical_base);
    defer root.deinit();
    const transactions = if (context.state.transactions) |*value| value else return error.PersistenceFailed;
    transactions.reimport(&root, install_id, prepared.dir, &prepared.manifest) catch |err| {
        recoverAfterFileFailure(context, &root, install_id, null, err);
        return err;
    };
    transactions.markReconciliationUnavailable(install_id) catch |err| {
        notePersistenceFailure(context, err);
        return err;
    };
    setReconciliation(context, install_id, scope, target_entry, .replace);
    return .{ .install_id = install_id, .verification_pending = true };
}

/// A private, verified snapshot, never a second discoverable Skill source.
const ManagedSource = struct {
    staging: std.Io.Dir,
    name: [47]u8,
    dir: std.Io.Dir,
    manifest: package.Manifest,

    fn deinit(self: *ManagedSource, io: std.Io) void {
        self.manifest.deinit();
        self.dir.close(io);
        self.staging.deleteTree(io, &self.name) catch {};
        self.staging.close(io);
    }
};

fn prepareManagedSource(context: Context, source: std.Io.Dir, manifest: *const package.Manifest) Error!ManagedSource {
    const staging = try openStagingRoot(context);
    errdefer staging.close(context.io);
    var random: [16]u8 = undefined;
    std.Io.randomSecure(context.io, &random) catch return error.PersistenceFailed;
    const hex = std.fmt.bytesToHex(random, .lower);
    var name: [47]u8 = undefined;
    @memcpy(name[0..15], ".skill-managed-");
    @memcpy(name[15..], &hex);
    staging.createDir(context.io, &name, privateDirectoryPermissions()) catch return error.PersistenceFailed;
    errdefer staging.deleteTree(context.io, &name) catch {};
    const candidate = staging.openDir(context.io, &name, .{ .follow_symlinks = false, .iterate = true }) catch return error.PersistenceFailed;
    errdefer candidate.close(context.io);
    try package.stageDirectory(context.io, source, candidate, manifest);
    var copied = try package.previewDirectory(context.io, context.allocator, candidate, .{});
    defer copied.deinit();
    if (!std.mem.eql(u8, &copied.content_hash, &manifest.content_hash)) return error.InvalidAsset;
    const definition = try package.managedDefinition(context.allocator, copied.definition);
    defer context.allocator.free(definition);
    candidate.writeFile(context.io, .{ .sub_path = "SKILL.md", .data = definition }) catch return error.WriteFailed;
    return .{
        .staging = staging,
        .name = name,
        .dir = candidate,
        .manifest = try package.inspectDirectory(context.io, context.allocator, candidate, .{}),
    };
}

fn openStagingRoot(context: Context) Error!std.Io.Dir {
    const path = context.state.staging_root orelse return error.PersistenceFailed;
    return std.Io.Dir.openDirAbsolute(context.io, path, .{
        .follow_symlinks = false,
    }) catch error.PersistenceFailed;
}

fn openManagedRoot(
    context: Context,
    scope: management.Scope,
    canonical_base: []const u8,
) Error!management.CanonicalRoot {
    const root_path = try std.fs.path.join(
        context.allocator,
        &.{ canonical_base, ".agents", "skills" },
    );
    defer context.allocator.free(root_path);
    return management.CanonicalRoot.open(
        context.io,
        context.allocator,
        scope,
        root_path,
    );
}

fn setReconciliation(
    context: Context,
    install_id: management.InstallId,
    scope: management.Scope,
    invocation_name: []const u8,
    operation: management.Operation,
) void {
    std.debug.assert(invocation_name.len <= management.max_target_entry_bytes);
    var reconciliation: state.Reconciliation = .{
        .install_id = install_id,
        .scope = scope,
        .invocation_name = undefined,
        .invocation_name_len = invocation_name.len,
        .operation = operation,
    };
    @memcpy(reconciliation.invocation_name[0..invocation_name.len], invocation_name);
    context.state.reconciliation = reconciliation;
}

fn notePersistenceFailure(context: Context, err: anyerror) void {
    switch (err) {
        error.PersistenceFailed,
        error.PersistenceOutcomeUnknown,
        => context.state.management_health =
            policy.managementHealthAfterPersistenceFailure(err),
        else => {},
    }
}

fn hasArchiveExtension(path: []const u8) bool {
    const extension = std.fs.path.extension(path);
    return std.ascii.eqlIgnoreCase(extension, ".skill") or
        std.ascii.eqlIgnoreCase(extension, ".zip");
}

fn privateDirectoryPermissions() std.Io.File.Permissions {
    return if (builtin.os.tag == .windows) .default_dir else .fromMode(0o700);
}

fn privateFilePermissions() std.Io.File.Permissions {
    return if (builtin.os.tag == .windows) .default_file else .fromMode(0o600);
}

fn validTimestamp(value: ?u64) ?u64 {
    const timestamp = value orelse return null;
    return if (timestamp == 0) null else timestamp;
}
