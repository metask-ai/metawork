//! Pure Product Skill catalog and management snapshot derivation.
//! This module borrows Skill state plus callback-scoped text and Workspace
//! catalog facts; it owns no sensitive material, job, executor, or external effect.

const std = @import("std");
const catalog = @import("product_skill_catalog");
const management = @import("product_skill_management");
const policy = @import("product_skill_policy");
const state = @import("product_skill_state");
const sources = @import("product_skill_sources");

pub const Error = error{SnapshotTooLarge};

fn testRetryAvailable(_: *const anyopaque, _: management.InstallId) bool {
    return true;
}

fn testOwnerResolve(_: *const anyopaque, owner: management.Owner) ?management.Scope {
    return switch (owner) {
        .personal => .personal,
        .project => |id| .{ .project = .{ .workspace_id = id, .workspace_epoch = std.math.maxInt(u64) } },
    };
}

/// Serializer-owned byte bounds for Product's global snapshot admission.
/// Text, variable arrays and fixed structure are charged independently.
pub const SnapshotStructureBounds = struct {
    asset: usize = 640,
    import_operation: usize = 768 + management.max_target_entry_bytes * 6,
    catalog_skill: usize = 216,
    argument: usize = 3, // Two JSON quotes and at most one comma.
    // Unmatched inventory entries are emitted twice and have no catalog text
    // allocation. Control must reserve these bytes even without any winner.
    managed_target_text: usize = 2 * management.max_target_entry_bytes * 6,
};

pub const TextProjection = struct {
    context: *const anyopaque,
    contains_sensitive_fn: *const fn (*const anyopaque, []const u8) bool,
    write_json_fn: *const fn (*const anyopaque, *std.Io.Writer, []const u8) Error!void,

    fn containsSensitive(self: TextProjection, value: []const u8) bool {
        return self.contains_sensitive_fn(self.context, value);
    }

    fn writeJson(
        self: TextProjection,
        writer: *std.Io.Writer,
        value: []const u8,
    ) Error!void {
        return self.write_json_fn(self.context, writer, value);
    }
};

pub const ScopedCatalog = struct {
    scope: management.Scope,
    snapshot: *const catalog.Snapshot,
};

/// Callback-scoped Workspace catalog iteration. The callback returns only
/// Product Skill scope and immutable snapshot facts, never Workspace state.
pub const WorkspaceCatalogs = struct {
    context: *const anyopaque,
    slot_count: usize,
    get_fn: *const fn (*const anyopaque, usize) ?ScopedCatalog,

    fn get(self: WorkspaceCatalogs, index: usize) ?ScopedCatalog {
        std.debug.assert(index < self.slot_count);
        return self.get_fn(self.context, index);
    }
};

pub const RetryAvailability = struct {
    context: *const anyopaque,
    available_fn: *const fn (*const anyopaque, management.InstallId) bool,
    import_blocker_fn: ?*const fn (*const anyopaque, management.Scope) ?state.ImportReason = null,
};

/// Maps an asset's stored ownership scope to the current authority scope of
/// the registered Workspace that owns it; null means no live owner.
pub const OwnerResolver = struct {
    context: *const anyopaque,
    resolve_fn: *const fn (*const anyopaque, management.Owner) ?management.Scope,

    fn resolve(self: OwnerResolver, owner: management.Owner) ?management.Scope {
        return self.resolve_fn(self.context, owner);
    }
};

pub const ManagementInput = struct {
    state: *const state.State,
    workspaces: WorkspaceCatalogs,
    text: TextProjection,
    personal_source_discovery: ?state.SourceDiscoveryView,
    retry: RetryAvailability,
    owner: OwnerResolver,
    import_blocker: ?state.ImportReason = null,
    import_prepared: bool = false,
};

pub fn catalogProjection(
    availability: catalog.CatalogAvailability,
    snapshot: ?*const catalog.Snapshot,
) catalog.CatalogProjection {
    return switch (availability) {
        .ready, .degraded => if (snapshot) |value|
            value.view()
        else
            .{ .availability = .unavailable },
        .uninitialized, .loading, .unavailable => .{
            .availability = availability,
        },
    };
}

pub fn writeCatalogProjection(
    writer: *std.Io.Writer,
    text: TextProjection,
    projection: catalog.CatalogProjection,
) Error!void {
    const available = projection.availability == .ready or
        projection.availability == .degraded;
    std.debug.assert(available == (projection.selection_revision != null));
    writer.print("{{\"availability\":\"{s}\",\"redacted\":{},\"revision\":", .{
        @tagName(projection.availability),
        projection.redacted or catalogContainsSensitive(text, projection),
    }) catch return error.SnapshotTooLarge;
    switch (projection.availability) {
        .ready, .degraded => try text.writeJson(writer, projection.revision),
        .uninitialized, .loading, .unavailable => writer.writeAll("null") catch
            return error.SnapshotTooLarge,
    }
    writer.writeAll(",\"selectionRevision\":") catch
        return error.SnapshotTooLarge;
    switch (projection.availability) {
        .ready, .degraded => writer.print(
            "\"{d}\"",
            .{projection.selection_revision.?},
        ) catch return error.SnapshotTooLarge,
        .uninitialized, .loading, .unavailable => writer.writeAll("null") catch
            return error.SnapshotTooLarge,
    }
    writer.writeAll(",\"skills\":[") catch return error.SnapshotTooLarge;
    for (projection.skills, 0..) |skill, index| {
        if (index != 0) writer.writeByte(',') catch return error.SnapshotTooLarge;
        writer.writeAll("{\"skillId\":") catch return error.SnapshotTooLarge;
        try text.writeJson(writer, skill.skill_id);
        writer.writeAll(",\"skillPolicyKey\":") catch return error.SnapshotTooLarge;
        try text.writeJson(writer, skill.skill_policy_key);
        writer.writeAll(",\"invocationName\":") catch
            return error.SnapshotTooLarge;
        try text.writeJson(writer, skill.invocation_name);
        writer.writeAll(",\"displayName\":") catch return error.SnapshotTooLarge;
        try text.writeJson(writer, skill.display_name);
        writer.writeAll(",\"description\":") catch return error.SnapshotTooLarge;
        try text.writeJson(writer, skill.description);
        writer.writeAll(",\"argumentNames\":[") catch
            return error.SnapshotTooLarge;
        for (skill.argument_names, 0..) |name, argument_index| {
            if (argument_index != 0) writer.writeByte(',') catch
                return error.SnapshotTooLarge;
            try text.writeJson(writer, name);
        }
        writer.print("],\"maxValues\":{d},\"enabled\":{}}}", .{
            skill.max_values,
            skill.enabled,
        }) catch return error.SnapshotTooLarge;
    }
    writer.writeAll("],\"issues\":[") catch return error.SnapshotTooLarge;
    for (projection.issues, 0..) |issue, index| {
        if (index != 0) writer.writeByte(',') catch return error.SnapshotTooLarge;
        writer.print("{{\"code\":\"{s}\",\"invocationName\":", .{
            @tagName(issue.code),
        }) catch return error.SnapshotTooLarge;
        if (issue.skill_policy_key) |name|
            try text.writeJson(writer, name)
        else
            writer.writeAll("null") catch return error.SnapshotTooLarge;
        writer.writeByte('}') catch return error.SnapshotTooLarge;
    }
    writer.writeAll("]}") catch return error.SnapshotTooLarge;
}

fn writeImportOperation(writer: *std.Io.Writer, input: ManagementInput) Error!void {
    const operation = input.state.import_operation orelse {
        writer.writeAll("null") catch return error.SnapshotTooLarge;
        return;
    };
    writer.print("{{\"id\":\"{d}\",\"preparationRevision\":\"{d}\",\"effect\":\"{s}\",\"phase\":\"{s}\",\"scope\":", .{ operation.id, operation.revision, @tagName(operation.effect), @tagName(operation.phase) }) catch return error.SnapshotTooLarge;
    switch (operation.scope) {
        .personal => writer.writeAll("{\"kind\":\"personal\",\"workspaceId\":null,\"workspaceEpoch\":null}") catch return error.SnapshotTooLarge,
        .project => |project| writer.print("{{\"kind\":\"project\",\"workspaceId\":\"{d}\",\"workspaceEpoch\":\"{d}\"}}", .{ project.workspace_id, project.workspace_epoch }) catch return error.SnapshotTooLarge,
    }
    writer.writeAll(",\"installId\":") catch return error.SnapshotTooLarge;
    if (operation.install_id) |id| {
        const hex = std.fmt.bytesToHex(id, .lower);
        writer.print("\"{s}\"", .{&hex}) catch return error.SnapshotTooLarge;
    } else writer.writeAll("null") catch return error.SnapshotTooLarge;
    writer.writeAll(",\"invocationName\":") catch return error.SnapshotTooLarge;
    try input.text.writeJson(writer, operation.invocationName());
    writer.writeAll(",\"reason\":") catch return error.SnapshotTooLarge;
    if (operation.reason) |reason| writer.print("\"{s}\"", .{@tagName(reason)}) catch return error.SnapshotTooLarge else writer.writeAll("null") catch return error.SnapshotTooLarge;
    writer.print(",\"canConfirm\":{},\"canDiscard\":{},\"blocker\":", .{ input.import_prepared and input.import_blocker == null, input.import_prepared }) catch return error.SnapshotTooLarge;
    if (input.import_blocker) |reason| writer.print("\"{s}\"", .{@tagName(reason)}) catch return error.SnapshotTooLarge else writer.writeAll("null") catch return error.SnapshotTooLarge;
    writer.writeByte('}') catch return error.SnapshotTooLarge;
}

pub fn writeManagementProjection(
    writer: *std.Io.Writer,
    input: ManagementInput,
) Error!void {
    writer.print("{{\"availability\":\"{s}\",\"enablementAvailability\":\"{s}\"", .{
        @tagName(input.state.management_health),
        @tagName(input.state.enablement_health),
    }) catch return error.SnapshotTooLarge;

    writer.writeAll(",\"importOperation\":") catch return error.SnapshotTooLarge;
    try writeImportOperation(writer, input);
    writer.writeAll(",\"personalSourceDiscovery\":") catch return error.SnapshotTooLarge;
    try writeSourceDiscovery(writer, .management, input.personal_source_discovery);
    writer.writeAll(",\"assets\":[") catch return error.SnapshotTooLarge;
    const inventory = input.state.inventoryConst();
    var count: usize = 0;
    for (inventory.items()) |asset| {
        if (count != 0) writer.writeByte(',') catch return error.SnapshotTooLarge;
        count += 1;
        try writeManagedAsset(writer, input, asset);
    }
    if (input.state.catalog.slot.snapshotConst()) |snapshot| {
        for (snapshot.skills) |skill| {
            if (policy.inventoryHasContributionInScope(
                inventory,
                .personal,
                .management,
                .workspace_default,
                skill,
            )) continue;
            if (count != 0) writer.writeByte(',') catch
                return error.SnapshotTooLarge;
            count += 1;
            try writeExternalAsset(writer, input, skill, .personal);
        }
    }
    for (0..input.workspaces.slot_count) |index| {
        const scoped = input.workspaces.get(index) orelse continue;
        for (scoped.snapshot.skills) |skill| {
            if (policy.inventoryHasContributionInScope(
                inventory,
                scoped.scope,
                .workspace,
                .workspace_default,
                skill,
            )) continue;
            if (count != 0) writer.writeByte(',') catch
                return error.SnapshotTooLarge;
            count += 1;
            try writeExternalAsset(writer, input, skill, scoped.scope);
        }
    }
    writer.writeAll("]}") catch return error.SnapshotTooLarge;
}

pub fn writeSourceDiscovery(writer: *std.Io.Writer, purpose: policy.QueryPurpose, discovery: ?state.SourceDiscoveryView) Error!void {
    const value = discovery orelse {
        writer.writeAll("null") catch return error.SnapshotTooLarge;
        return;
    };
    if (value.checks == null and !value.checking) {
        writer.writeAll("null") catch return error.SnapshotTooLarge;
        return;
    }
    writer.writeByte('[') catch return error.SnapshotTooLarge;
    try writeRootCheck(writer, "agents.user.default", if (value.checks) |checks| checks.default_user else null);
    if (purpose == .workspace) {
        writer.writeByte(',') catch return error.SnapshotTooLarge;
        try writeRootCheck(writer, "agents.workspace.default", if (value.checks) |checks| checks.default_workspace else null);
    }
    writer.writeByte(']') catch return error.SnapshotTooLarge;
}

fn writeRootCheck(writer: *std.Io.Writer, id: []const u8, check: ?sources.RootCheck) Error!void {
    const label: []const u8 = if (check) |value| switch (value) {
        .disabled => "disabled",
        .missing => "missing",
        .checked => "checked",
        .blocked => "error",
    } else "checking";
    writer.print("{{\"sourceId\":\"{s}\",\"state\":\"{s}\",\"reason\":", .{ id, label }) catch return error.SnapshotTooLarge;
    if (check != null and check.? == .blocked) writer.print("\"{s}\"", .{@tagName(check.?.blocked)}) catch return error.SnapshotTooLarge else writer.writeAll("null") catch return error.SnapshotTooLarge;
    writer.writeByte('}') catch return error.SnapshotTooLarge;
}

fn writeOrigin(writer: *std.Io.Writer, owner: management.Owner, skill: ?catalog.SkillProjection) Error!void {
    writer.writeAll(",\"origin\":") catch return error.SnapshotTooLarge;
    const proven = if (skill) |value| policy.origin(if (owner == .personal) .management else .workspace, value) else null;
    if (proven) |value| writer.print("{{\"ecosystem\":\"{s}\",\"scope\":\"{s}\"}}", .{ @tagName(value.ecosystem), @tagName(value.scope) }) catch return error.SnapshotTooLarge else writer.writeAll("null") catch return error.SnapshotTooLarge;
}

/// File management needs a registered owner; a record whose Workspace id is
/// not currently registered only reads as provenance.
fn manageableOwner(input: ManagementInput, asset: *const management.Asset) bool {
    return input.owner.resolve(asset.owner) != null;
}

fn writeManagedAsset(
    writer: *std.Io.Writer,
    input: ManagementInput,
    asset: management.Asset,
) Error!void {
    const id_hex = std.fmt.bytesToHex(asset.install_id, .lower);
    const skill = findCatalogSkill(input, asset.owner, asset.target_entry);
    writer.writeAll("{\"installId\":") catch return error.SnapshotTooLarge;
    jsonValue(writer, &id_hex) catch return error.SnapshotTooLarge;
    writer.print(",\"sourceKind\":\"{s}\",\"scope\":", .{
        @tagName(asset.source_kind),
    }) catch return error.SnapshotTooLarge;
    try writeScope(writer, asset.owner);
    try writeOrigin(writer, asset.owner, skill);
    writer.print(",\"managementState\":\"{s}\",\"skillId\":", .{
        if (asset.requiresRecovery()) "recovery_required" else @tagName(asset.state),
    }) catch return error.SnapshotTooLarge;
    if (skill) |value|
        try input.text.writeJson(writer, value.skill_id)
    else
        writer.writeAll("null") catch return error.SnapshotTooLarge;
    writer.writeAll(",\"invocationName\":") catch return error.SnapshotTooLarge;
    try input.text.writeJson(
        writer,
        if (skill) |value| value.invocation_name else asset.target_entry,
    );
    writer.writeAll(",\"displayName\":") catch return error.SnapshotTooLarge;
    try input.text.writeJson(
        writer,
        if (skill) |value| value.display_name else asset.target_entry,
    );
    writer.writeAll(",\"description\":") catch return error.SnapshotTooLarge;
    try input.text.writeJson(
        writer,
        if (skill) |value| value.description else "",
    );
    try writeAssetTail(
        writer,
        input,
        if (skill) |value| value.argument_names else &.{},
        if (skill) |value| value.max_values else 0,
        asset.state != .externally_managed and asset.state == .ready and
            asset.recovery == null and manageableOwner(input, &asset),
        asset.state == .pending_verification and !asset.requiresRecovery(),
        asset.recovery != null and input.state.management_health == .ready and
            input.retry.available_fn(input.retry.context, asset.install_id),
        asset.owner,
        asset.target_entry,
        skill,
    );
}

fn writeExternalAsset(
    writer: *std.Io.Writer,
    input: ManagementInput,
    skill: catalog.SkillProjection,
    scope: management.Scope,
) Error!void {
    const owner = management.Owner.fromScope(scope);
    const purpose: policy.QueryPurpose = if (owner == .personal) .management else .workspace;
    writer.print("{{\"installId\":null,\"sourceKind\":\"{s}\",\"scope\":", .{
        if (policy.isBuiltin(purpose, skill)) "builtin" else "external",
    }) catch return error.SnapshotTooLarge;
    try writeScope(writer, owner);
    try writeOrigin(writer, owner, skill);
    writer.writeAll(",\"managementState\":\"externally_managed\",\"skillId\":") catch
        return error.SnapshotTooLarge;
    try input.text.writeJson(writer, skill.skill_id);
    writer.writeAll(",\"invocationName\":") catch return error.SnapshotTooLarge;
    try input.text.writeJson(writer, skill.invocation_name);
    writer.writeAll(",\"displayName\":") catch return error.SnapshotTooLarge;
    try input.text.writeJson(writer, skill.display_name);
    writer.writeAll(",\"description\":") catch return error.SnapshotTooLarge;
    try input.text.writeJson(writer, skill.description);
    try writeAssetTail(
        writer,
        input,
        skill.argument_names,
        skill.max_values,
        false,
        false,
        false,
        owner,
        skill.invocation_name,
        skill,
    );
}

fn writeAssetTail(
    writer: *std.Io.Writer,
    input: ManagementInput,
    argument_names: []const []const u8,
    max_values: u32,
    manageable: bool,
    pending: bool,
    can_retry: bool,
    owner: management.Owner,
    invocation_name: []const u8,
    runtime_skill: ?catalog.SkillProjection,
) Error!void {
    const resolved = resolveScope(input, owner);
    const snapshot = resolved.snapshot;
    writer.writeAll(",\"skillPolicyKey\":") catch return error.SnapshotTooLarge;
    if (runtime_skill) |skill|
        try input.text.writeJson(writer, skill.skill_policy_key)
    else
        writer.writeAll("null") catch return error.SnapshotTooLarge;
    writer.writeAll(",\"argumentNames\":[") catch return error.SnapshotTooLarge;
    for (argument_names, 0..) |name, index| {
        if (index != 0) writer.writeByte(',') catch return error.SnapshotTooLarge;
        try input.text.writeJson(writer, name);
    }
    const enablement_available = policy.enablementTrusted(input.state.enablement_health) and
        snapshot != null;
    const selection_revision = if (enablement_available and runtime_skill != null)
        snapshot.?.selection_revision
    else
        null;
    const can_set_enabled = enablement_available and
        runtime_skill != null and selection_revision != null;
    writer.print("],\"maxValues\":{d},\"canExport\":{},\"canReimport\":{},\"canUninstall\":{},\"canRetry\":{},\"enabled\":", .{
        max_values,
        manageable and input.state.management_health == .ready,
        manageable and input.state.management_health == .ready,
        (manageable or pending) and input.state.management_health == .ready,
        can_retry,
    }) catch return error.SnapshotTooLarge;
    if (runtime_skill) |skill| {
        if (enablement_available)
            writer.print("{}", .{skill.enabled}) catch return error.SnapshotTooLarge
        else
            writer.writeAll("null") catch return error.SnapshotTooLarge;
    } else writer.writeAll("null") catch return error.SnapshotTooLarge;
    writer.writeAll(",\"enablementState\":") catch return error.SnapshotTooLarge;
    if (runtime_skill) |skill| {
        if (enablement_available) switch (resolved.current.?) {
            .personal => jsonValue(
                writer,
                if (skill.enabled) "enabled" else "disabled",
            ) catch return error.SnapshotTooLarge,
            .project => |project| jsonValue(
                writer,
                @tagName(input.state.enablement_store.workspaceOverride(.{
                    .workspace_id = project.workspace_id,
                    .workspace_epoch = project.workspace_epoch,
                }, skill.skill_policy_key)),
            ) catch return error.SnapshotTooLarge,
        } else writer.writeAll("null") catch return error.SnapshotTooLarge;
    } else writer.writeAll("null") catch return error.SnapshotTooLarge;
    writer.print(",\"canSetEnabled\":{},\"selectionRevision\":", .{can_set_enabled}) catch
        return error.SnapshotTooLarge;
    if (selection_revision) |revision|
        writer.print("\"{d}\"", .{revision}) catch return error.SnapshotTooLarge
    else
        writer.writeAll("null") catch return error.SnapshotTooLarge;
    writer.writeAll(",\"issueCodes\":[") catch return error.SnapshotTooLarge;
    if (snapshot) |value| {
        var issue_count: usize = 0;
        for (value.issues) |issue| {
            if (runtime_skill) |skill| {
                const issue_name = issue.skill_policy_key orelse continue;
                if (!std.mem.eql(u8, issue_name, invocation_name) or
                    !std.mem.eql(u8, issue.provider_id, skill.provider_id) or
                    !std.mem.eql(u8, issue.source_instance_id, skill.source_instance_id) or
                    issue.source_scope != skill.source_scope) continue;
            } else if (!policy.issueMatchesManaged(if (owner == .personal) .management else .workspace, .workspace_default, invocation_name, issue)) continue;
            if (issue_count != 0) writer.writeByte(',') catch
                return error.SnapshotTooLarge;
            issue_count += 1;
            jsonValue(writer, @tagName(issue.code)) catch
                return error.SnapshotTooLarge;
        }
    }
    writer.writeAll("]}") catch return error.SnapshotTooLarge;
}

const ResolvedScope = struct {
    /// The owning Workspace's current authority scope when it has a current
    /// catalog; null otherwise.
    current: ?management.Scope,
    snapshot: ?*const catalog.Snapshot,
};

/// Ownership follows the Workspace id; the current catalog belongs to the
/// Workspace's current epoch.
fn resolveScope(input: ManagementInput, owner: management.Owner) ResolvedScope {
    return switch (owner) {
        .personal => .{ .current = .personal, .snapshot = input.state.catalog.slot.snapshotConst() },
        .project => {
            for (0..input.workspaces.slot_count) |index| {
                const scoped = input.workspaces.get(index) orelse continue;
                if (owner.owns(scoped.scope)) return .{ .current = scoped.scope, .snapshot = scoped.snapshot };
            }
            return .{ .current = null, .snapshot = null };
        },
    };
}

fn findCatalogSkill(
    input: ManagementInput,
    owner: management.Owner,
    invocation_name: []const u8,
) ?catalog.SkillProjection {
    const snapshot = resolveScope(input, owner).snapshot orelse return null;
    for (snapshot.skills) |skill|
        if (policy.matchManagedContribution(if (owner == .personal) .management else .workspace, .workspace_default, invocation_name, skill) == .matched) return skill;
    return null;
}

fn catalogContainsSensitive(
    text: TextProjection,
    projection: catalog.CatalogProjection,
) bool {
    if (text.containsSensitive(projection.revision)) return true;
    for (projection.skills) |skill| {
        inline for (.{
            skill.skill_id,
            skill.skill_policy_key,
            skill.invocation_name,
            skill.display_name,
            skill.description,
        }) |field| if (text.containsSensitive(field)) return true;
        for (skill.argument_names) |name|
            if (text.containsSensitive(name)) return true;
    }
    for (projection.issues) |issue|
        if (issue.skill_policy_key) |name|
            if (text.containsSensitive(name)) return true;
    return false;
}

fn writeScope(writer: *std.Io.Writer, owner: management.Owner) Error!void {
    switch (owner) {
        .personal => writer.writeAll(
            "{\"kind\":\"personal\",\"workspaceId\":null}",
        ) catch return error.SnapshotTooLarge,
        .project => |id| writer.print(
            "{{\"kind\":\"project\",\"workspaceId\":\"{d}\"}}",
            .{id},
        ) catch return error.SnapshotTooLarge,
    }
}

fn jsonValue(writer: *std.Io.Writer, value: anytype) !void {
    try std.json.Stringify.value(value, .{}, writer);
}

test "catalog projection redacts sensitive text through the injected projector" {
    const Fixture = struct {
        fn contains(_: *const anyopaque, value: []const u8) bool {
            return std.mem.indexOf(u8, value, "SECRET") != null;
        }

        fn write(
            _: *const anyopaque,
            writer: *std.Io.Writer,
            value: []const u8,
        ) Error!void {
            const redacted = std.mem.indexOf(u8, value, "SECRET") != null;
            jsonValue(writer, if (redacted) "[redacted]" else value) catch
                return error.SnapshotTooLarge;
        }
    };
    const skills = [_]catalog.SkillProjection{.{
        .skill_id = "review",
        .skill_policy_key = "review",
        .invocation_name = "review",
        .provider_id = "agents.directory",
        .source_scope = .workspace,
        .source_instance_id = "agents.workspace.default",
        .contribution_id = "review",
        .content_revision = "review-v1",
        .display_name = "Review",
        .description = "Review SECRET usage",
        .argument_names = &.{},
        .max_values = 0,
    }};
    var storage: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try writeCatalogProjection(&writer, .{
        .context = undefined,
        .contains_sensitive_fn = Fixture.contains,
        .write_json_fn = Fixture.write,
    }, .{
        .availability = .ready,
        .revision = "catalog-1",
        .selection_revision = 1,
        .skills = &skills,
    });
    try std.testing.expect(std.mem.indexOf(
        u8,
        writer.buffered(),
        "\"redacted\":true",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "SECRET") == null);
}

test "snapshot structure bounds cover maximum identities arguments issues and unmatched targets" {
    const Fixture = struct {
        const maximum = std.math.maxInt(u64);
        const scope: management.Scope = .{ .project = .{ .workspace_id = maximum, .workspace_epoch = maximum } };
        fn contains(_: *const anyopaque, _: []const u8) bool {
            return false;
        }
        fn write(_: *const anyopaque, writer: *std.Io.Writer, value: []const u8) Error!void {
            jsonValue(writer, value) catch return error.SnapshotTooLarge;
        }
        fn get(context: *const anyopaque, _: usize) ?ScopedCatalog {
            const snapshot: *const catalog.Snapshot = @ptrCast(@alignCast(context));
            return .{ .scope = scope, .snapshot = snapshot };
        }
        fn stripText(value: *std.json.Value, fields: []const []const u8) void {
            for (fields) |field| {
                const text = value.object.getPtr(field).?;
                if (text.* == .string) text.* = .{ .string = "" };
            }
            for (value.object.getPtr("argumentNames").?.array.items) |*argument|
                argument.* = .{ .string = "" };
        }
    };
    const bounds: SnapshotStructureBounds = .{};
    var product_state = try state.State.init(std.testing.io, std.testing.allocator, .{}, .{
        .max_assets = 2,
        .max_workspaces = 1,
        .max_policy_keys = 2,
        .max_policy_key_bytes = 128,
    });
    defer product_state.inventory.?.deinit();
    defer product_state.enablement_store.deinit();
    product_state.enablement_health = .ready;
    const inventory = &product_state.inventory.?;
    const id: management.InstallId = @splat(1);
    _ = try inventory.add(.{ .install_id = id, .source_kind = .local_directory, .scope = Fixture.scope, .target_entry = "review", .content_hash = @splat('a'), .installed_at_unix_seconds = 1 });
    try inventory.beginTransaction(id, .{ .operation = .install, .phase = .candidate_published, .candidate_hash = @splat('a'), .candidate_entry = ".candidate" });
    try inventory.markPendingVerification(id);
    const target: [management.max_target_entry_bytes]u8 = @splat(1);
    _ = try inventory.add(.{ .install_id = @splat(2), .source_kind = .local_directory, .scope = Fixture.scope, .target_entry = &target, .content_hash = @splat('a'), .installed_at_unix_seconds = 1 });
    const arguments: [64][]const u8 = @splat("\x01");
    var skills = [_]catalog.SkillProjection{.{
        .skill_id = "review-id",
        .skill_policy_key = "review",
        .invocation_name = "review",
        .provider_id = "agents.directory",
        .source_scope = .workspace,
        .source_instance_id = "agents.workspace.default",
        .contribution_id = "review",
        .content_revision = "revision",
        .display_name = "\x01",
        .description = "\x01",
        .argument_names = &arguments,
        .max_values = std.math.maxInt(u32),
        .enabled = false,
    }};
    var issues: [128]catalog.CatalogIssueProjection = @splat(.{
        .kind = .invalid,
        .code = .invalid_invocation_name,
        .reason = null,
        .skill_policy_key = "review",
        .provider_id = "agents.directory",
        .source_scope = .workspace,
        .source_instance_id = "agents.workspace.default",
    });
    var snapshot: catalog.Snapshot = .{ .arena = .init(std.testing.allocator), .revision = "catalog", .health = .degraded, .skills = &skills, .issues = &issues, .projected_bytes = 0, .selection_revision = Fixture.maximum };
    defer snapshot.deinit();
    const text: TextProjection = .{ .context = undefined, .contains_sensitive_fn = Fixture.contains, .write_json_fn = Fixture.write };
    const input: ManagementInput = .{
        .state = &product_state,
        .retry = .{ .context = undefined, .available_fn = testRetryAvailable },
        .owner = .{ .context = undefined, .resolve_fn = testOwnerResolve },
        .text = text,
        .personal_source_discovery = null,
        .workspaces = .{ .context = &snapshot, .slot_count = 1, .get_fn = Fixture.get },
    };
    // Include both a matched pending install and an unassociated same-name
    // winner. The latter adds a row; it must not replace or relabel the install.
    for ([_][]const u8{ "agents.workspace.default", "compat.claude.workspace" }, 0..) |source_id, index| {
        skills[0].source_instance_id = source_id;
        for (&issues) |*issue| issue.source_instance_id = source_id;
        var buffer: [16 * 1024]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        try writeManagementProjection(&writer, input);
        try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\\u0001") != null);
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, writer.buffered(), .{});
        defer parsed.deinit();
        const assets = parsed.value.object.getPtr("assets").?.array.items;
        try std.testing.expectEqual(index + 2, assets.len);
        for (assets) |*asset| {
            const argument_count = asset.object.get("argumentNames").?.array.items.len;
            const issue_count = asset.object.get("issueCodes").?.array.items.len;
            if (asset.object.get("skillId").? == .null) {
                writer = std.Io.Writer.fixed(&buffer);
                try jsonValue(&writer, asset.*);
                try std.testing.expect(writer.buffered().len + 1 <= bounds.asset + bounds.managed_target_text + issue_count * 32);
            }
            Fixture.stripText(asset, &.{ "skillId", "skillPolicyKey", "invocationName", "displayName", "description" });
            writer = std.Io.Writer.fixed(&buffer);
            try jsonValue(&writer, asset.*);
            try std.testing.expect(writer.buffered().len + 1 <= bounds.asset + argument_count * bounds.argument + issue_count * 32);
        }
        writer = std.Io.Writer.fixed(&buffer);
        try writeCatalogProjection(&writer, text, snapshot.view());
        var catalog_json = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, writer.buffered(), .{});
        defer catalog_json.deinit();
        const skill = &catalog_json.value.object.getPtr("skills").?.array.items[0];
        Fixture.stripText(skill, &.{ "skillId", "skillPolicyKey", "invocationName", "displayName", "description" });
        writer = std.Io.Writer.fixed(&buffer);
        try jsonValue(&writer, skill.*);
        try std.testing.expect(writer.buffered().len + 1 <= bounds.catalog_skill + arguments.len * bounds.argument);
    }
}

test "same-name external winner is not suppressed or attached to a managed asset" {
    const Fixture = struct {
        fn contains(_: *const anyopaque, _: []const u8) bool {
            return false;
        }
        fn write(_: *const anyopaque, writer: *std.Io.Writer, value: []const u8) Error!void {
            jsonValue(writer, value) catch return error.SnapshotTooLarge;
        }
        fn workspace(_: *const anyopaque, _: usize) ?ScopedCatalog {
            return null;
        }
    };
    var product_state = try state.State.init(std.testing.io, std.testing.allocator, .{}, .{
        .max_assets = 2,
        .max_workspaces = 1,
        .max_policy_keys = 2,
        .max_policy_key_bytes = 64,
    });
    // No acquired lease is installed by this pure view fixture.
    defer product_state.inventory.?.deinit();
    defer product_state.enablement_store.deinit();
    product_state.enablement_health = .ready;
    _ = try product_state.inventory.?.add(.{
        .install_id = @splat(7),
        .source_kind = .local_directory,
        .scope = .personal,
        .target_entry = "review",
        .content_hash = @splat('a'),
        .installed_at_unix_seconds = 1,
    });
    var skills = [_]catalog.SkillProjection{.{
        .skill_id = "external-review",
        .skill_policy_key = "review",
        .invocation_name = "review",
        .provider_id = "agents.directory",
        .source_scope = .workspace,
        .source_instance_id = "compat.claude.user",
        .contribution_id = "external-contribution",
        .content_revision = "opaque",
        .display_name = "External review",
        .description = "External description",
        .argument_names = &.{"external-argument"},
        .max_values = 1,
    }};
    product_state.catalog.slot = .{ .committed = .{
        .lease = .fixture(),
        .snapshot = .{ .arena = .init(std.testing.allocator), .revision = "catalog", .health = .healthy, .skills = &skills, .issues = &.{}, .projected_bytes = 0, .selection_revision = 1 },
    } };
    defer product_state.catalog.slot.committed.snapshot.deinit();
    const input: ManagementInput = .{
        .state = &product_state,
        .retry = .{ .context = undefined, .available_fn = testRetryAvailable },
        .owner = .{ .context = undefined, .resolve_fn = testOwnerResolve },
        .personal_source_discovery = null,
        .text = .{ .context = undefined, .contains_sensitive_fn = Fixture.contains, .write_json_fn = Fixture.write },
        .workspaces = .{ .context = undefined, .slot_count = 0, .get_fn = Fixture.workspace },
    };
    var buffer: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeManagementProjection(&writer, input);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, writer.buffered(), .{});
    defer parsed.deinit();
    const assets = parsed.value.object.get("assets").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), assets.len);
    const managed = assets[0].object;
    try std.testing.expect(managed.get("skillId").? == .null);
    try std.testing.expect(managed.get("skillPolicyKey").? == .null);
    try std.testing.expect(!managed.get("canSetEnabled").?.bool);
    try std.testing.expectEqualStrings("", managed.get("description").?.string);
    try std.testing.expectEqual(@as(usize, 0), managed.get("argumentNames").?.array.items.len);
    const external = assets[1].object;
    try std.testing.expect(external.get("installId").? == .null);
    try std.testing.expectEqualStrings("external-review", external.get("skillId").?.string);
    try std.testing.expect(external.get("canSetEnabled").?.bool);
    try std.testing.expect(!external.get("canExport").?.bool and !external.get("canReimport").?.bool and !external.get("canUninstall").?.bool);
    skills[0].enabled = false;
    product_state.catalog.slot.committed.snapshot.selection_revision = try product_state.enablement_store.applyUser(.{
        .skill_policy_key = "review",
        .enabled = false,
        .expected_revision = 1,
    });
    for ([_]state.EnablementHealth{ .write_failed, .outcome_unknown }) |health| {
        product_state.enablement_health = health;
        writer = std.Io.Writer.fixed(&buffer);
        try writeManagementProjection(&writer, input);
        var failed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, writer.buffered(), .{});
        defer failed.deinit();
        const failed_external = failed.value.object.get("assets").?.array.items[1].object;
        try std.testing.expectEqual(health == .write_failed, failed_external.get("canSetEnabled").?.bool);
        if (health == .write_failed) {
            try std.testing.expect(!failed_external.get("enabled").?.bool);
            try std.testing.expectEqualStrings("disabled", failed_external.get("enablementState").?.string);
        } else try std.testing.expect(failed_external.get("enabled").? == .null);
    }
    product_state.enablement_health = .ready;
    skills[0].source_instance_id = "agents.workspace.default";
    writer = std.Io.Writer.fixed(&buffer);
    try writeManagementProjection(&writer, input);
    var linked = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, writer.buffered(), .{});
    defer linked.deinit();
    try std.testing.expectEqual(@as(usize, 1), linked.value.object.get("assets").?.array.items.len);
    try product_state.inventory.?.beginTransaction(@splat(7), .{ .operation = .install, .phase = .candidate_published, .candidate_hash = @splat('a'), .candidate_entry = ".candidate" });
    try product_state.inventory.?.markPendingVerification(@splat(7));
    try product_state.inventory.?.advanceTransaction(@splat(7), .reconciled);
    for ([_]state.ManagementHealth{ .ready, .write_failed, .outcome_unknown }) |health| {
        product_state.management_health = health;
        writer = std.Io.Writer.fixed(&buffer);
        try writeManagementProjection(&writer, input);
        var recovery_projection = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, writer.buffered(), .{});
        defer recovery_projection.deinit();
        const recovering = recovery_projection.value.object.get("assets").?.array.items[0].object;
        try std.testing.expectEqualStrings("recovery_required", recovering.get("managementState").?.string);
        try std.testing.expectEqual(health == .ready, recovering.get("canRetry").?.bool);
        try std.testing.expect(!recovering.get("canExport").?.bool and !recovering.get("canReimport").?.bool and !recovering.get("canUninstall").?.bool);
    }
}
