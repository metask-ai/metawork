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
    if (!std.fs.path.isAbsolute(absolute_path) or
        !std.unicode.utf8ValidateSlice(absolute_path))
        return error.InvalidAsset;
    const source = std.Io.Dir.openDirAbsolute(
        context.io,
        absolute_path,
        .{ .follow_symlinks = false, .iterate = true },
    ) catch return error.InvalidAsset;
    defer source.close(context.io);
    return package.previewDirectory(context.io, context.allocator, source, .{});
}

pub fn previewArchive(
    context: Context,
    absolute_path: []const u8,
) Error!package.Preview {
    if (!std.fs.path.isAbsolute(absolute_path) or
        !std.unicode.utf8ValidateSlice(absolute_path) or
        !hasArchiveExtension(absolute_path))
        return error.InvalidAsset;
    const archive = std.Io.Dir.openFileAbsolute(
        context.io,
        absolute_path,
        .{ .follow_symlinks = false },
    ) catch return error.InvalidAsset;
    defer archive.close(context.io);
    const inspection = package.inspectArchive(
        context.io,
        context.allocator,
        archive,
        .{},
    ) catch return error.InvalidAsset;
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
    }) catch return error.PersistenceFailed;
    defer scratch.close(context.io);
    package.extractArchive(context.io, archive, scratch) catch return error.InvalidAsset;
    const source = if (inspection.wrapperName()) |wrapper|
        scratch.openDir(context.io, wrapper, .{
            .follow_symlinks = false,
        }) catch return error.InvalidAsset
    else
        scratch;
    defer if (inspection.wrapperName() != null) source.close(context.io);
    return package.previewDirectory(context.io, context.allocator, source, .{}) catch
        return error.InvalidAsset;
}

pub fn readDefinition(
    context: Context,
    install_id: management.InstallId,
    root: *const management.CanonicalRoot,
) Error!package.Preview {
    const current = context.state.inventoryConst().findConst(install_id) orelse
        return error.AssetNotFound;
    if (current.recovery != null or !current.scope.eql(root.scope))
        return error.InvalidAsset;
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
    install_id: management.InstallId,
    root: *const management.CanonicalRoot,
    absolute_destination: []const u8,
) Error!state.ExportResult {
    if (!std.fs.path.isAbsolute(absolute_destination) or
        !std.unicode.utf8ValidateSlice(absolute_destination))
        return error.InvalidAsset;
    const current = context.state.inventoryConst().findConst(install_id) orelse
        return error.AssetNotFound;
    if (current.state != .ready or current.recovery != null or
        !current.scope.eql(root.scope))
        return error.InvalidAsset;
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
    package.exportArchive(context.io, source, output, &manifest) catch
        return error.WriteFailed;
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
    if (input.source_kind != .local_directory or
        !std.fs.path.isAbsolute(absolute_path) or
        !std.unicode.utf8ValidateSlice(absolute_path))
        return error.InvalidAsset;
    const source = std.Io.Dir.openDirAbsolute(context.io, absolute_path, .{
        .follow_symlinks = false,
        .iterate = true,
    }) catch return error.InvalidAsset;
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
    const archive = std.Io.Dir.openFileAbsolute(context.io, absolute_path, .{
        .follow_symlinks = false,
    }) catch return error.InvalidAsset;
    defer archive.close(context.io);
    const inspection = package.inspectArchive(
        context.io,
        context.allocator,
        archive,
        .{},
    ) catch return error.InvalidAsset;
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
    }) catch return error.PersistenceFailed;
    defer scratch.close(context.io);
    package.extractArchive(context.io, archive, scratch) catch return error.InvalidAsset;
    const source = if (inspection.wrapperName()) |wrapper|
        scratch.openDir(context.io, wrapper, .{
            .follow_symlinks = false,
        }) catch return error.InvalidAsset
    else
        scratch;
    defer if (inspection.wrapperName() != null) source.close(context.io);
    return installSource(context, canonical_base, source, input, now_unix_seconds);
}

pub fn reimportDirectory(
    context: Context,
    canonical_base: []const u8,
    install_id: management.InstallId,
    absolute_path: []const u8,
    expected_invocation_name: []const u8,
    expected_content_hash: management.ContentHash,
) Error!state.MutationResult {
    if (!std.fs.path.isAbsolute(absolute_path) or
        !std.unicode.utf8ValidateSlice(absolute_path))
        return error.InvalidAsset;
    const source = std.Io.Dir.openDirAbsolute(context.io, absolute_path, .{
        .follow_symlinks = false,
        .iterate = true,
    }) catch return error.InvalidAsset;
    defer source.close(context.io);
    return reimportSource(
        context,
        canonical_base,
        install_id,
        source,
        expected_invocation_name,
        expected_content_hash,
    );
}

pub fn reimportArchive(
    context: Context,
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
    const archive = std.Io.Dir.openFileAbsolute(context.io, absolute_path, .{
        .follow_symlinks = false,
    }) catch return error.InvalidAsset;
    defer archive.close(context.io);
    const inspection = package.inspectArchive(
        context.io,
        context.allocator,
        archive,
        .{},
    ) catch return error.InvalidAsset;
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
    }) catch return error.PersistenceFailed;
    defer scratch.close(context.io);
    package.extractArchive(context.io, archive, scratch) catch return error.InvalidAsset;
    const source = if (inspection.wrapperName()) |wrapper|
        scratch.openDir(context.io, wrapper, .{
            .follow_symlinks = false,
        }) catch return error.InvalidAsset
    else
        scratch;
    defer if (inspection.wrapperName() != null) source.close(context.io);
    return reimportSource(
        context,
        canonical_base,
        install_id,
        source,
        expected_invocation_name,
        expected_content_hash,
    );
}

pub fn uninstall(
    context: Context,
    canonical_base: []const u8,
    install_id: management.InstallId,
    now_unix_seconds: ?u64,
) Error!state.MutationResult {
    const current = context.state.inventoryConst().findConst(install_id) orelse
        return error.AssetNotFound;
    const scope = current.scope;
    const target_entry = try context.allocator.dupe(u8, current.target_entry);
    defer context.allocator.free(target_entry);
    const pending_operation = if (current.state == .pending_verification and
        current.recovery != null) current.recovery.?.operation else null;
    var root = try openManagedRoot(context, scope, canonical_base);
    defer root.deinit();
    const transactions = if (context.state.transactions) |*value| value else return error.PersistenceFailed;
    if (pending_operation) |operation| switch (operation) {
        .install => {
            try transactions.rollbackReconciliation(&root, install_id);
            return .{ .install_id = install_id, .verification_pending = false };
        },
        .uninstall => {
            const now = validTimestamp(now_unix_seconds) orelse
                return error.PersistenceFailed;
            try transactions.commitReconciliation(&root, install_id, null, now);
            return .{ .install_id = install_id, .verification_pending = false };
        },
        .replace => try transactions.rollbackReconciliation(&root, install_id),
    };
    try transactions.uninstall(&root, install_id);
    transactions.markReconciliationUnavailable(install_id) catch |err| {
        notePersistenceFailure(context, err);
        return err;
    };
    setReconciliation(context, install_id, scope, target_entry, .uninstall);
    return .{ .install_id = install_id, .verification_pending = true };
}

pub fn retryVerification(
    context: Context,
    install_id: management.InstallId,
) Error!state.MutationResult {
    const current = context.state.inventoryConst().findConst(install_id) orelse
        return error.AssetNotFound;
    if (current.state != .pending_verification or current.recovery == null)
        return error.InvalidAsset;
    setReconciliation(
        context,
        install_id,
        current.scope,
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
        if (asset.scope.eql(scope) and asset.recovery != null)
            pending.append(context.allocator, asset.install_id) catch {
                context.state.management_health = .write_failed;
                return;
            };
    }
    if (pending.items.len == 0) return;
    var root = openManagedRoot(context, scope, canonical_base) catch {
        context.state.management_health = .read_failed;
        return;
    };
    defer root.deinit();
    const now = validTimestamp(now_unix_seconds) orelse {
        context.state.management_health = .read_failed;
        return;
    };
    const transactions = &context.state.transactions.?;
    for (pending.items) |install_id|
        transactions.recover(&root, install_id, now) catch |err| {
            notePersistenceFailure(context, err);
            return;
        };
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
    var found = false;
    for (current.skills) |skill| {
        if (std.mem.eql(u8, skill.invocation_name, reconciliation.invocationName())) {
            found = true;
            break;
        }
    }
    var has_matching_issue = false;
    for (current.issues) |issue| {
        const issue_name = issue.skill_policy_key orelse continue;
        if (std.mem.eql(u8, issue_name, reconciliation.invocationName())) {
            has_matching_issue = true;
            break;
        }
    }
    const accepted = !has_matching_issue and switch (reconciliation.operation) {
        .install, .replace => found,
        .uninstall => !found,
    };
    var root = openManagedRoot(context, scope, canonical_base) catch return;
    defer root.deinit();
    const transactions = if (context.state.transactions) |*value| value else return;
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
    var root = try openManagedRoot(context, input.scope, canonical_base);
    defer root.deinit();
    const now = validTimestamp(now_unix_seconds) orelse return error.PersistenceFailed;
    const install_id = management.generateInstallId(context.io) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.PersistenceFailed,
    };
    const transactions = if (context.state.transactions) |*value| value else return error.PersistenceFailed;
    const published = try transactions.publish(&root, source, &manifest, .{
        .asset = .{
            .install_id = install_id,
            .source_kind = input.source_kind,
            .scope = input.scope,
            .target_entry = preview.invocation_name,
            .content_hash = manifest.content_hash,
            .installed_at_unix_seconds = now,
        },
        .allow_replace = input.allow_replace,
    });
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
    canonical_base: []const u8,
    install_id: management.InstallId,
    source: std.Io.Dir,
    expected_invocation_name: []const u8,
    expected_content_hash: management.ContentHash,
) Error!state.MutationResult {
    const current = context.state.inventoryConst().findConst(install_id) orelse
        return error.AssetNotFound;
    const scope = current.scope;
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
    var root = try openManagedRoot(context, scope, canonical_base);
    defer root.deinit();
    const transactions = if (context.state.transactions) |*value| value else return error.PersistenceFailed;
    try transactions.reimport(&root, install_id, source, &manifest);
    transactions.markReconciliationUnavailable(install_id) catch |err| {
        notePersistenceFailure(context, err);
        return err;
    };
    setReconciliation(context, install_id, scope, target_entry, .replace);
    return .{ .install_id = install_id, .verification_pending = true };
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
    context.state.management_health = policy.managementHealthAfterPersistenceFailure(err);
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
