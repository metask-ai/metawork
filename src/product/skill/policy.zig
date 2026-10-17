//! Effect-free Product Skill health, enablement, and catalog policy.
//! This module owns no composition state, external effect, job, executor,
//! thread, revision, or publication.

const std = @import("std");
const agent = @import("metawork_agent");
const catalog = @import("product_skill_catalog");
const enablement = @import("product_skill_enablement");
const management = @import("product_skill_management");
const state = @import("product_skill_state");
const sources = @import("product_skill_sources");

pub const ContributionMatch = enum { matched, different, unproven };
pub const QueryPurpose = enum { management, workspace };
pub const Origin = struct { ecosystem: sources.Ecosystem, scope: enum { personal, project } };

/// Product origin is interpreted in the query's purpose. Raw Core provenance
/// is retained and never promoted into a filesystem management capability.
pub fn origin(purpose: QueryPurpose, skill: catalog.SkillProjection) ?Origin {
    if (!std.mem.eql(u8, skill.provider_id, "agents.directory") or skill.contribution_id.len == 0) return null;
    return sourceOrigin(purpose, skill.source_instance_id, skill.source_scope);
}

fn sourceOrigin(purpose: QueryPurpose, id: []const u8, scope: agent.CatalogSourceScope) ?Origin {
    for ([_]ManagedSource{ .user_default, .workspace_default }) |known| {
        if (!std.mem.eql(u8, id, known.id())) continue;
        if (scope != known.scope() or (purpose == .management and known == .user_default)) return null;
        return .{ .ecosystem = .agents, .scope = if (purpose == .management or scope == .user) .personal else .project };
    }
    const compatibility = sources.definition(sources.findId(id) orelse return null);
    if (purpose == .management) {
        if (compatibility.scope != .user or scope != .workspace) return null;
    } else if (scope != compatibility.scope) return null;
    return .{ .ecosystem = compatibility.ecosystem, .scope = if (compatibility.scope == .user) .personal else .project };
}

/// The query owner supplies the known default source for its exact managed
/// root, after establishing filesystem authority. This is not a file grant.
/// In particular, management uses workspace_default;
/// do not infer this choice from the page's Personal/Project label.
pub const ManagedSource = enum {
    user_default,
    workspace_default,

    fn scope(self: ManagedSource) agent.CatalogSourceScope {
        return if (self == .user_default) .user else .workspace;
    }

    fn id(self: ManagedSource) []const u8 {
        return if (self == .user_default) "agents.user.default" else "agents.workspace.default";
    }
};

/// Correlates one validated Core winner with an already-authorized managed
/// entry. Never uses display name, package hash, or a locally computed Core ID.
pub fn matchManagedContribution(
    purpose: QueryPurpose,
    expected_source: ManagedSource,
    target_entry: []const u8,
    skill: catalog.SkillProjection,
) ContributionMatch {
    if (target_entry.len == 0) return .unproven;
    if (!std.mem.eql(u8, skill.invocation_name, target_entry)) return .different;
    if (!std.mem.eql(u8, skill.provider_id, "agents.directory") or skill.contribution_id.len == 0)
        return .unproven;
    if (origin(purpose, skill) == null) return .unproven;
    if (std.mem.eql(u8, skill.source_instance_id, expected_source.id()))
        return if (skill.source_scope == expected_source.scope()) .matched else .unproven;
    return .different;
}

pub fn issueMatchesManaged(purpose: QueryPurpose, expected_source: ManagedSource, entry: []const u8, issue: catalog.CatalogIssueProjection) bool {
    const name = issue.skill_policy_key orelse return false;
    return std.mem.eql(u8, name, entry) and std.mem.eql(u8, issue.provider_id, "agents.directory") and
        std.mem.eql(u8, issue.source_instance_id, expected_source.id()) and issue.source_scope == expected_source.scope() and
        sourceOrigin(purpose, issue.source_instance_id, issue.source_scope) != null;
}

pub const EnablementPersistenceFailure = struct {
    health: state.EnablementHealth,
    invalidate_authorities: bool,
};

/// Enablement installs a candidate only after commit. A definite write failure
/// therefore leaves the previous policy authoritative, unlike outcome unknown.
pub fn enablementTrusted(health: state.EnablementHealth) bool {
    return switch (health) {
        .ready, .write_failed => true,
        .unavailable, .read_failed, .corrupt, .outcome_unknown => false,
    };
}

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

pub fn inventoryHasContributionInScope(
    inventory: *const management.Inventory,
    scope: management.Scope,
    purpose: QueryPurpose,
    expected_source: ManagedSource,
    skill: catalog.SkillProjection,
) bool {
    for (inventory.items()) |asset|
        if (asset.owner.owns(scope) and
            matchManagedContribution(purpose, expected_source, asset.target_entry, skill) == .matched) return true;
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
    if (!enablementTrusted(enablement_health)) return error.PersistenceFailed;
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

test "managed contribution correlation requires known provenance rather than invocation alone" {
    var skill: catalog.SkillProjection = .{
        .skill_id = "opaque-skill-id",
        .skill_policy_key = "review",
        .invocation_name = "review",
        .provider_id = "agents.directory",
        .source_scope = .workspace,
        .source_instance_id = "agents.workspace.default",
        .contribution_id = "opaque-contribution-id",
        .content_revision = "not-a-package-hash",
        .display_name = "Not the invocation name",
        .description = "",
        .argument_names = &.{},
        .max_values = 0,
    };
    try std.testing.expectEqual(ContributionMatch.matched, matchManagedContribution(.workspace, .workspace_default, "review", skill));
    try std.testing.expectEqual(ContributionMatch.different, matchManagedContribution(.workspace, .user_default, "review", skill));
    try std.testing.expectEqual(ContributionMatch.different, matchManagedContribution(.workspace, .workspace_default, "other", skill));
    try std.testing.expectEqual(Origin{ .ecosystem = .agents, .scope = .personal }, origin(.management, skill).?);
    try std.testing.expectEqual(Origin{ .ecosystem = .agents, .scope = .project }, origin(.workspace, skill).?);
    skill.source_instance_id = "agents.user.default";
    skill.source_scope = .user;
    try std.testing.expectEqual(ContributionMatch.matched, matchManagedContribution(.workspace, .user_default, "review", skill));
    try std.testing.expectEqual(ContributionMatch.different, matchManagedContribution(.workspace, .workspace_default, "review", skill));
    for (sources.definitions) |source| {
        skill.source_instance_id = source.source_instance_id;
        skill.source_scope = source.scope;
        try std.testing.expectEqual(ContributionMatch.different, matchManagedContribution(.workspace, .user_default, "review", skill));
        try std.testing.expectEqual(ContributionMatch.different, matchManagedContribution(.workspace, .workspace_default, "review", skill));
        skill.source_scope = .workspace;
        if (source.scope == .user) {
            try std.testing.expectEqual(Origin{ .ecosystem = source.ecosystem, .scope = .personal }, origin(.management, skill).?);
            try std.testing.expectEqual(ContributionMatch.different, matchManagedContribution(.management, .workspace_default, "review", skill));
        } else try std.testing.expect(origin(.management, skill) == null);
    }
    skill.source_instance_id = "unrecognized.source";
    try std.testing.expectEqual(ContributionMatch.unproven, matchManagedContribution(.workspace, .workspace_default, "review", skill));
    skill.source_instance_id = "agents.workspace.default";
    skill.source_scope = .user;
    try std.testing.expectEqual(ContributionMatch.unproven, matchManagedContribution(.workspace, .workspace_default, "review", skill));
    skill.source_scope = .workspace;
    skill.provider_id = "unrecognized.provider";
    try std.testing.expectEqual(ContributionMatch.unproven, matchManagedContribution(.workspace, .workspace_default, "review", skill));
    skill.provider_id = "agents.directory";
    skill.contribution_id = "";
    try std.testing.expectEqual(ContributionMatch.unproven, matchManagedContribution(.workspace, .workspace_default, "review", skill));
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

    var after_write_failure = try compileCatalogSnapshot(
        allocator,
        source,
        &store,
        .write_failed,
        .personal,
        limits,
        limits.max_catalog_projection_bytes,
    );
    defer after_write_failure.deinit();
    try std.testing.expectEqual(personal.selection_revision, after_write_failure.selection_revision);
    try std.testing.expect(!after_write_failure.skills[0].enabled);
}

/// Core keeps winner/conflict ownership. Never select a hidden alternative
/// when the resolved winner came from workspace data.
pub fn restrictToPersonalSources(snapshot: *catalog.Snapshot) void {
    for (snapshot.skills) |*skill| {
        skill.enabled = skill.enabled and restoreSourceAllowed(skill.*, .{ .values = @splat(true) }, true);
    }
}

/// A pinned winner keeps its original concrete ID and content. Current source
/// switches can withdraw that authority; a newly resolved winner cannot add it.
pub fn restoreSourceAllowed(skill: catalog.SkillProjection, selection: sources.Selection, personal_only: bool) bool {
    if (!std.mem.eql(u8, skill.provider_id, "agents.directory")) return false;
    if (personal_only and skill.source_scope != .user) return false;
    if (sources.findId(skill.source_instance_id)) |id| {
        const definition = sources.definition(id);
        return definition.scope == skill.source_scope and selection.enabled(id);
    }
    if (std.mem.eql(u8, skill.source_instance_id, "agents.user.default") or
        std.mem.eql(u8, skill.source_instance_id, sources.builtin_source_instance_id)) return skill.source_scope == .user;
    return std.mem.eql(u8, skill.source_instance_id, "agents.workspace.default") and skill.source_scope == .workspace;
}

test "Automatic policy grants only eligible resolved personal winners" {
    const template: catalog.SkillProjection = .{
        .skill_id = "id",
        .skill_policy_key = "docx",
        .invocation_name = "docx",
        .provider_id = "agents.directory",
        .source_scope = .user,
        .source_instance_id = sources.builtin_source_instance_id,
        .contribution_id = "contribution",
        .content_revision = "revision",
        .display_name = "Word",
        .description = "",
        .argument_names = &.{},
        .max_values = 64,
    };
    var skills = [_]catalog.SkillProjection{template} ** 6;
    skills[1].source_scope = .workspace;
    skills[1].source_instance_id = "agents.workspace.default";
    skills[2].enabled = false;
    skills[3].source_instance_id = "unknown.user";
    skills[4].provider_id = "unknown.provider";
    skills[5].source_instance_id = sources.definition(.codex_user).source_instance_id;
    var snapshot: catalog.Snapshot = .{
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
        .revision = "revision",
        .health = .healthy,
        .skills = &skills,
        .issues = &.{},
        .projected_bytes = 0,
        .selection_revision = 1,
    };
    defer snapshot.arena.deinit();
    restrictToPersonalSources(&snapshot);
    try std.testing.expect(skills[0].enabled);
    for (skills[1..5]) |skill| try std.testing.expect(!skill.enabled);
    try std.testing.expect(skills[5].enabled);
    try std.testing.expectEqualStrings("agents.workspace.default", skills[1].source_instance_id);
}
