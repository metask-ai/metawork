//! Effect-free Product Skill health, enablement, and catalog policy.
//! This module owns no composition state, external effect, job, executor,
//! thread, revision, or publication.

const std = @import("std");
const agent = @import("metawork_agent");
const catalog = @import("product_skill_catalog");
const enablement = @import("product_skill_enablement");
const management = @import("product_skill_management");
const state = @import("product_skill_state");

pub const EnablementPersistenceFailure = struct {
    health: state.EnablementHealth,
    invalidate_authorities: bool,
};

pub fn managementHealthAfterPersistenceFailure(
    err: anyerror,
) state.ManagementHealth {
    return if (err == error.PersistenceOutcomeUnknown)
        .outcome_unknown
    else
        .write_failed;
}

pub fn enablementPersistenceFailure(
    err: anyerror,
) EnablementPersistenceFailure {
    return if (err == error.PersistenceOutcomeUnknown)
        .{ .health = .outcome_unknown, .invalidate_authorities = true }
    else
        .{ .health = .write_failed, .invalidate_authorities = false };
}

pub fn inventoryHasInvocationInScope(
    inventory: *const management.Inventory,
    scope: management.Scope,
    invocation_name: []const u8,
) bool {
    for (inventory.items()) |asset|
        if (asset.scope.eql(scope) and
            std.mem.eql(u8, asset.target_entry, invocation_name)) return true;
    return false;
}

pub fn compileCatalogSnapshot(
    allocator: std.mem.Allocator,
    source: agent.CatalogProjection,
    store: *const enablement.Store,
    enablement_health: state.EnablementHealth,
    scope: management.Scope,
    limits: catalog.Limits,
    available_projection_bytes: usize,
) (catalog.Error || error{PersistenceFailed})!catalog.Snapshot {
    if (enablement_health != .ready) return error.PersistenceFailed;
    var disabled_skill_policy_keys: std.ArrayList([]const u8) = .empty;
    defer disabled_skill_policy_keys.deinit(allocator);
    for (source.skills) |skill|
        if (!skillEnabled(store, scope, skill.skill_policy_key))
            try disabled_skill_policy_keys.append(
                allocator,
                skill.skill_policy_key,
            );
    return catalog.Snapshot.init(
        allocator,
        source,
        selectionRevision(store, scope),
        disabled_skill_policy_keys.items,
        limits,
        available_projection_bytes,
    ) catch |err| switch (err) {
        error.InvalidSelectionRevision => unreachable,
        else => |other| return other,
    };
}

pub fn recompileCatalogSnapshot(
    allocator: std.mem.Allocator,
    snapshot: *const catalog.Snapshot,
    store: *const enablement.Store,
    scope: management.Scope,
    limits: catalog.Limits,
    available_projection_bytes: usize,
) catalog.Error!catalog.Snapshot {
    var disabled_skill_policy_keys: std.ArrayList([]const u8) = .empty;
    defer disabled_skill_policy_keys.deinit(allocator);
    for (snapshot.skills) |skill|
        if (!skillEnabled(store, scope, skill.skill_policy_key))
            try disabled_skill_policy_keys.append(
                allocator,
                skill.skill_policy_key,
            );
    return snapshot.recompile(
        allocator,
        selectionRevision(store, scope),
        disabled_skill_policy_keys.items,
        limits,
        available_projection_bytes,
    ) catch |err| switch (err) {
        error.InvalidSelectionRevision => unreachable,
        else => |other| return other,
    };
}

fn selectionRevision(
    store: *const enablement.Store,
    scope: management.Scope,
) u64 {
    return switch (scope) {
        .personal => store.userRevision(),
        .project => |project| store.revision(.{
            .workspace_id = project.workspace_id,
            .workspace_epoch = project.workspace_epoch,
        }),
    };
}

fn skillEnabled(
    store: *const enablement.Store,
    scope: management.Scope,
    skill_policy_key: []const u8,
) bool {
    return switch (scope) {
        .personal => store.isUserEnabled(skill_policy_key),
        .project => |project| store.isEnabled(.{
            .workspace_id = project.workspace_id,
            .workspace_epoch = project.workspace_epoch,
        }, skill_policy_key),
    };
}

test "persistence uncertainty invalidates Skill authorities" {
    try std.testing.expectEqual(
        state.ManagementHealth.outcome_unknown,
        managementHealthAfterPersistenceFailure(error.PersistenceOutcomeUnknown),
    );
    try std.testing.expectEqual(
        state.ManagementHealth.write_failed,
        managementHealthAfterPersistenceFailure(error.WriteFailed),
    );
    try std.testing.expectEqualDeep(
        EnablementPersistenceFailure{
            .health = .outcome_unknown,
            .invalidate_authorities = true,
        },
        enablementPersistenceFailure(error.PersistenceOutcomeUnknown),
    );
    try std.testing.expectEqualDeep(
        EnablementPersistenceFailure{
            .health = .write_failed,
            .invalidate_authorities = false,
        },
        enablementPersistenceFailure(error.WriteFailed),
    );
}

test "catalog compilation applies user and Workspace enablement policy" {
    const allocator = std.testing.allocator;
    var store = try enablement.Store.init(allocator, .{
        .max_workspaces = 2,
        .max_policy_keys = 4,
        .max_policy_key_bytes = 64,
    });
    defer store.deinit();
    const identity: enablement.WorkspaceIdentity = .{
        .workspace_id = 7,
        .workspace_epoch = 3,
    };
    _ = try store.applyUser(.{
        .skill_policy_key = "review",
        .enabled = false,
        .expected_revision = 1,
    });
    _ = try store.applyWorkspace(.{
        .identity = identity,
        .skill_policy_key = "review",
        .state = .enabled,
        .expected_revision = 2,
    });
    const skills = [_]agent.CatalogSkill{.{
        .skill_id = "review-id",
        .skill_policy_key = "review",
        .invocation_name = "review",
        .provider_id = "agents.directory",
        .source_scope = .workspace,
        .source_instance_id = "agents.workspace.default",
        .contribution_id = "review",
        .content_revision = "review-v1",
        .display_name = "Review",
        .description = "Review changes",
        .argument_names = &.{},
        .max_values = 0,
    }};
    const source: agent.CatalogProjection = .{
        .revision = "catalog-1",
        .health = .healthy,
        .skills = &skills,
        .issues = &.{},
        .storage = undefined,
    };
    const limits: catalog.Limits = .{
        .max_catalog_skills = 2,
        .max_catalog_issues = 2,
        .max_skill_arguments = 2,
        .max_catalog_projection_bytes = 4096,
    };
    try std.testing.expectError(
        error.PersistenceFailed,
        compileCatalogSnapshot(
            allocator,
            source,
            &store,
            .outcome_unknown,
            .personal,
            limits,
            limits.max_catalog_projection_bytes,
        ),
    );
    var personal = try compileCatalogSnapshot(
        allocator,
        source,
        &store,
        .ready,
        .personal,
        limits,
        limits.max_catalog_projection_bytes,
    );
    defer personal.deinit();
    var project = try compileCatalogSnapshot(
        allocator,
        source,
        &store,
        .ready,
        .{ .project = .{
            .workspace_id = identity.workspace_id,
            .workspace_epoch = identity.workspace_epoch,
        } },
        limits,
        limits.max_catalog_projection_bytes,
    );
    defer project.deinit();

    try std.testing.expectEqual(@as(u64, 2), personal.selection_revision);
    try std.testing.expect(!personal.skills[0].enabled);
    try std.testing.expectEqual(@as(u64, 3), project.selection_revision);
    try std.testing.expect(project.skills[0].enabled);
}
