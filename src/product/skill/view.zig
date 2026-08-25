//! Pure Product Skill catalog and management snapshot derivation.
//! This module borrows Skill state plus callback-scoped text and Workspace
//! catalog facts; it owns no sensitive material, job, executor, or external effect.

const std = @import("std");
const catalog = @import("product_skill_catalog");
const management = @import("product_skill_management");
const policy = @import("product_skill_policy");
const state = @import("product_skill_state");

pub const Error = error{SnapshotTooLarge};

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

pub const ManagementInput = struct {
    state: *const state.State,
    workspaces: WorkspaceCatalogs,
    text: TextProjection,
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

pub fn writeManagementProjection(
    writer: *std.Io.Writer,
    input: ManagementInput,
) Error!void {
    writer.print("{{\"availability\":\"{s}\",\"enablementAvailability\":\"{s}\",\"assets\":[", .{
        @tagName(input.state.management_health),
        @tagName(input.state.enablement_health),
    }) catch return error.SnapshotTooLarge;
    const inventory = input.state.inventoryConst();
    var count: usize = 0;
    for (inventory.items()) |asset| {
        if (count != 0) writer.writeByte(',') catch return error.SnapshotTooLarge;
        count += 1;
        try writeManagedAsset(writer, input, asset);
    }
    if (input.state.catalog.slot.snapshotConst()) |snapshot| {
        for (snapshot.skills) |skill| {
            if (policy.inventoryHasInvocationInScope(
                inventory,
                .personal,
                skill.invocation_name,
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
            if (policy.inventoryHasInvocationInScope(
                inventory,
                scoped.scope,
                skill.invocation_name,
            )) continue;
            if (count != 0) writer.writeByte(',') catch
                return error.SnapshotTooLarge;
            count += 1;
            try writeExternalAsset(writer, input, skill, scoped.scope);
        }
    }
    writer.writeAll("]}") catch return error.SnapshotTooLarge;
}

fn writeManagedAsset(
    writer: *std.Io.Writer,
    input: ManagementInput,
    asset: management.Asset,
) Error!void {
    const id_hex = std.fmt.bytesToHex(asset.install_id, .lower);
    const skill = findCatalogSkill(input, asset.scope, asset.target_entry);
    writer.writeAll("{\"installId\":") catch return error.SnapshotTooLarge;
    jsonValue(writer, &id_hex) catch return error.SnapshotTooLarge;
    writer.print(",\"sourceKind\":\"{s}\",\"scope\":", .{
        @tagName(asset.source_kind),
    }) catch return error.SnapshotTooLarge;
    try writeScope(writer, asset.scope);
    writer.print(",\"managementState\":\"{s}\",\"skillId\":", .{
        @tagName(asset.state),
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
            asset.recovery == null,
        asset.state == .pending_verification,
        asset.scope,
        asset.target_entry,
    );
}

fn writeExternalAsset(
    writer: *std.Io.Writer,
    input: ManagementInput,
    skill: catalog.SkillProjection,
    scope: management.Scope,
) Error!void {
    writer.writeAll("{\"installId\":null,\"sourceKind\":\"external\",\"scope\":") catch
        return error.SnapshotTooLarge;
    try writeScope(writer, scope);
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
        scope,
        skill.invocation_name,
    );
}

fn writeAssetTail(
    writer: *std.Io.Writer,
    input: ManagementInput,
    argument_names: []const []const u8,
    max_values: u32,
    manageable: bool,
    pending: bool,
    scope: management.Scope,
    invocation_name: []const u8,
) Error!void {
    const snapshot = catalogForScope(input, scope);
    const runtime_skill = if (snapshot) |value|
        findSkill(value, invocation_name)
    else
        null;
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
    const enablement_available = input.state.enablement_health == .ready and
        snapshot != null;
    const selection_revision = if (enablement_available)
        snapshot.?.selection_revision
    else
        null;
    const can_set_enabled = enablement_available and
        runtime_skill != null and selection_revision != null;
    writer.print("],\"maxValues\":{d},\"canExport\":{},\"canReimport\":{},\"canUninstall\":{},\"canRetry\":{},\"enabled\":", .{
        max_values,
        manageable,
        manageable,
        manageable or pending,
        pending,
    }) catch return error.SnapshotTooLarge;
    if (runtime_skill) |skill| {
        if (enablement_available)
            writer.print("{}", .{skill.enabled}) catch return error.SnapshotTooLarge
        else
            writer.writeAll("null") catch return error.SnapshotTooLarge;
    } else writer.writeAll("null") catch return error.SnapshotTooLarge;
    writer.writeAll(",\"enablementState\":") catch return error.SnapshotTooLarge;
    if (runtime_skill) |skill| {
        if (enablement_available) switch (scope) {
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
            const issue_name = issue.skill_policy_key orelse continue;
            if (!std.mem.eql(u8, issue_name, invocation_name)) continue;
            if (issue_count != 0) writer.writeByte(',') catch
                return error.SnapshotTooLarge;
            issue_count += 1;
            jsonValue(writer, @tagName(issue.code)) catch
                return error.SnapshotTooLarge;
        }
    }
    writer.writeAll("]}") catch return error.SnapshotTooLarge;
}

fn catalogForScope(
    input: ManagementInput,
    scope: management.Scope,
) ?*const catalog.Snapshot {
    return switch (scope) {
        .personal => input.state.catalog.slot.snapshotConst(),
        .project => {
            for (0..input.workspaces.slot_count) |index| {
                const scoped = input.workspaces.get(index) orelse continue;
                if (scoped.scope.eql(scope)) return scoped.snapshot;
            }
            return null;
        },
    };
}

fn findCatalogSkill(
    input: ManagementInput,
    scope: management.Scope,
    invocation_name: []const u8,
) ?catalog.SkillProjection {
    const snapshot = catalogForScope(input, scope) orelse return null;
    return findSkill(snapshot, invocation_name);
}

fn findSkill(
    snapshot: *const catalog.Snapshot,
    invocation_name: []const u8,
) ?catalog.SkillProjection {
    for (snapshot.skills) |skill|
        if (std.mem.eql(u8, skill.invocation_name, invocation_name)) return skill;
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

fn writeScope(writer: *std.Io.Writer, scope: management.Scope) Error!void {
    switch (scope) {
        .personal => writer.writeAll(
            "{\"kind\":\"personal\",\"workspaceId\":null,\"workspaceEpoch\":null}",
        ) catch return error.SnapshotTooLarge,
        .project => |project| writer.print(
            "{{\"kind\":\"project\",\"workspaceId\":\"{d}\",\"workspaceEpoch\":\"{d}\"}}",
            .{ project.workspace_id, project.workspace_epoch },
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
