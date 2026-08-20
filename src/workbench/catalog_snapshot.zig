//! Workbench-owned immutable Skill catalog snapshot.

const std = @import("std");
const lifecycle = @import("metawork_agent");

pub const CatalogAvailability = enum { uninitialized, loading, ready, degraded, unavailable };

pub const SkillProjection = struct {
    skill_id: []const u8,
    skill_policy_key: []const u8,
    invocation_name: []const u8,
    provider_id: []const u8,
    source_scope: lifecycle.CatalogSourceScope,
    source_instance_id: []const u8,
    contribution_id: []const u8,
    content_revision: []const u8,
    display_name: []const u8,
    description: []const u8,
    argument_names: []const []const u8,
    max_values: u32,
    enabled: bool = true,
};

pub const CatalogIssueProjection = struct {
    kind: lifecycle.CatalogIssueKind,
    code: lifecycle.CatalogIssueCode,
    reason: ?lifecycle.CatalogResourceReason,
    skill_policy_key: ?[]const u8,
    provider_id: []const u8,
    source_scope: lifecycle.CatalogSourceScope,
    source_instance_id: []const u8,
};

pub const CatalogProjection = struct {
    availability: CatalogAvailability,
    redacted: bool = false,
    revision: []const u8 = "",
    selection_revision: ?u64 = null,
    skills: []const SkillProjection = &.{},
    issues: []const CatalogIssueProjection = &.{},
};

pub const Limits = struct {
    max_catalog_skills: usize,
    max_catalog_issues: usize,
    max_skill_arguments: usize,
    max_catalog_projection_bytes: usize,
};

pub const Error = std.mem.Allocator.Error || error{ProjectionCapacity};

pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    revision: []const u8,
    health: lifecycle.CatalogHealth,
    skills: []SkillProjection,
    issues: []const CatalogIssueProjection,
    projected_bytes: usize,
    redacted: bool = false,
    selection_revision: ?u64 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        source: lifecycle.CatalogProjection,
        limits: Limits,
        available_projection_bytes: usize,
    ) Error!Snapshot {
        if (source.skills.len > limits.max_catalog_skills or
            source.issues.len > limits.max_catalog_issues)
            return error.ProjectionCapacity;
        var projected_bytes = source.revision.len;
        for (source.skills) |skill| {
            if (skill.argument_names.len > limits.max_skill_arguments)
                return error.ProjectionCapacity;
            inline for (.{
                skill.skill_id,
                skill.skill_policy_key,
                skill.invocation_name,
                skill.provider_id,
                skill.source_instance_id,
                skill.contribution_id,
                skill.content_revision,
                skill.display_name,
                skill.description,
            }) |field| {
                projected_bytes = try addCatalogProjectionBytes(
                    projected_bytes,
                    field.len,
                    limits,
                    available_projection_bytes,
                );
            }
            for (skill.argument_names) |name|
                projected_bytes = try addCatalogProjectionBytes(
                    projected_bytes,
                    name.len,
                    limits,
                    available_projection_bytes,
                );
        }
        for (source.issues) |issue| {
            inline for (.{ issue.provider_id, issue.source_instance_id }) |identity|
                projected_bytes = try addCatalogProjectionBytes(
                    projected_bytes,
                    identity.len,
                    limits,
                    available_projection_bytes,
                );
            if (issue.skill_policy_key) |key|
                projected_bytes = try addCatalogProjectionBytes(
                    projected_bytes,
                    key.len,
                    limits,
                    available_projection_bytes,
                );
        }
        if (projected_bytes > limits.max_catalog_projection_bytes or
            projected_bytes > available_projection_bytes)
            return error.ProjectionCapacity;

        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const owned = arena.allocator();
        const skills = try owned.alloc(SkillProjection, source.skills.len);
        for (source.skills, skills) |skill, *target| {
            const argument_names = try owned.alloc(
                []const u8,
                skill.argument_names.len,
            );
            for (skill.argument_names, argument_names) |name, *target_name|
                target_name.* = try owned.dupe(u8, name);
            target.* = .{
                .skill_id = try owned.dupe(u8, skill.skill_id),
                .skill_policy_key = try owned.dupe(u8, skill.skill_policy_key),
                .invocation_name = try owned.dupe(u8, skill.invocation_name),
                .provider_id = try owned.dupe(u8, skill.provider_id),
                .source_scope = skill.source_scope,
                .source_instance_id = try owned.dupe(u8, skill.source_instance_id),
                .contribution_id = try owned.dupe(u8, skill.contribution_id),
                .content_revision = try owned.dupe(u8, skill.content_revision),
                .display_name = try owned.dupe(u8, skill.display_name),
                .description = try owned.dupe(u8, skill.description),
                .argument_names = argument_names,
                .max_values = skill.max_values,
                .enabled = true,
            };
        }
        const issues = try owned.alloc(
            CatalogIssueProjection,
            source.issues.len,
        );
        for (source.issues, issues) |issue, *target| target.* = .{
            .kind = issue.kind,
            .code = issue.code,
            .reason = issue.reason,
            .skill_policy_key = if (issue.skill_policy_key) |key|
                try owned.dupe(u8, key)
            else
                null,
            .provider_id = try owned.dupe(u8, issue.provider_id),
            .source_scope = issue.source_scope,
            .source_instance_id = try owned.dupe(u8, issue.source_instance_id),
        };
        return .{
            .arena = arena,
            .revision = try owned.dupe(u8, source.revision),
            .health = source.health,
            .skills = skills,
            .issues = issues,
            .projected_bytes = projected_bytes,
        };
    }

    pub fn clone(
        self: *const Snapshot,
        allocator: std.mem.Allocator,
        limits: Limits,
        available_projection_bytes: usize,
    ) Error!Snapshot {
        if (self.projected_bytes > limits.max_catalog_projection_bytes or
            self.projected_bytes > available_projection_bytes)
            return error.ProjectionCapacity;
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const owned = arena.allocator();
        const skills = try owned.alloc(SkillProjection, self.skills.len);
        for (self.skills, skills) |skill, *target| {
            const argument_names = try owned.alloc(
                []const u8,
                skill.argument_names.len,
            );
            for (skill.argument_names, argument_names) |name, *target_name|
                target_name.* = try owned.dupe(u8, name);
            target.* = .{
                .skill_id = try owned.dupe(u8, skill.skill_id),
                .skill_policy_key = try owned.dupe(u8, skill.skill_policy_key),
                .invocation_name = try owned.dupe(u8, skill.invocation_name),
                .provider_id = try owned.dupe(u8, skill.provider_id),
                .source_scope = skill.source_scope,
                .source_instance_id = try owned.dupe(u8, skill.source_instance_id),
                .contribution_id = try owned.dupe(u8, skill.contribution_id),
                .content_revision = try owned.dupe(u8, skill.content_revision),
                .display_name = try owned.dupe(u8, skill.display_name),
                .description = try owned.dupe(u8, skill.description),
                .argument_names = argument_names,
                .max_values = skill.max_values,
                .enabled = skill.enabled,
            };
        }
        const issues = try owned.alloc(CatalogIssueProjection, self.issues.len);
        for (self.issues, issues) |issue, *target| target.* = .{
            .kind = issue.kind,
            .code = issue.code,
            .reason = issue.reason,
            .skill_policy_key = if (issue.skill_policy_key) |key|
                try owned.dupe(u8, key)
            else
                null,
            .provider_id = try owned.dupe(u8, issue.provider_id),
            .source_scope = issue.source_scope,
            .source_instance_id = try owned.dupe(u8, issue.source_instance_id),
        };
        return .{
            .arena = arena,
            .revision = try owned.dupe(u8, self.revision),
            .health = self.health,
            .skills = skills,
            .issues = issues,
            .projected_bytes = self.projected_bytes,
            .redacted = self.redacted,
            .selection_revision = self.selection_revision,
        };
    }

    pub fn view(self: *const Snapshot) CatalogProjection {
        return .{
            .availability = switch (self.health) {
                .healthy => .ready,
                .degraded => .degraded,
            },
            .redacted = self.redacted,
            .revision = self.revision,
            .selection_revision = self.selection_revision,
            .skills = self.skills,
            .issues = self.issues,
        };
    }

    pub fn findSkill(
        self: *const Snapshot,
        skill_id: []const u8,
    ) ?*const SkillProjection {
        for (self.skills) |*skill|
            if (std.mem.eql(u8, skill.skill_id, skill_id)) return skill;
        return null;
    }

    pub fn findSkillByPolicyKey(
        self: *const Snapshot,
        skill_policy_key: []const u8,
    ) ?*const SkillProjection {
        for (self.skills) |*skill|
            if (std.mem.eql(u8, skill.skill_policy_key, skill_policy_key)) return skill;
        return null;
    }

    pub fn applyEnablement(
        self: *Snapshot,
        selection_revision: u64,
        disabled_skill_policy_keys: anytype,
    ) void {
        std.debug.assert(selection_revision != 0);
        self.selection_revision = selection_revision;
        for (self.skills) |*skill| {
            skill.enabled = true;
            for (disabled_skill_policy_keys) |disabled| {
                if (std.mem.eql(u8, skill.skill_policy_key, disabled)) {
                    skill.enabled = false;
                    break;
                }
            }
        }
    }

    pub fn identityContainsCredential(
        self: *const Snapshot,
        credential: []const u8,
    ) bool {
        if (credential.len == 0) return false;
        if (std.mem.indexOf(u8, self.revision, credential) != null) return true;
        for (self.skills) |skill|
            if (std.mem.indexOf(u8, skill.skill_id, credential) != null or
                std.mem.indexOf(u8, skill.skill_policy_key, credential) != null or
                std.mem.indexOf(u8, skill.invocation_name, credential) != null or
                std.mem.indexOf(u8, skill.provider_id, credential) != null or
                std.mem.indexOf(u8, skill.source_instance_id, credential) != null)
                return true;
        return false;
    }

    pub fn redactPresentationNoFail(
        self: *Snapshot,
        credential: []const u8,
    ) void {
        var redacted = false;
        for (self.skills) |*skill| {
            redacted = redactFixedWidthNoFail(
                @constCast(skill.display_name),
                credential,
            ) or redacted;
            redacted = redactFixedWidthNoFail(
                @constCast(skill.description),
                credential,
            ) or redacted;
            for (skill.argument_names) |name| {
                redacted = redactFixedWidthNoFail(
                    @constCast(name),
                    credential,
                ) or redacted;
            }
        }
        for (self.issues) |*issue| {
            if (issue.skill_policy_key) |name| {
                redacted = redactFixedWidthNoFail(
                    @constCast(name),
                    credential,
                ) or redacted;
            }
        }
        self.redacted = self.redacted or redacted;
    }

    pub fn deinit(self: *Snapshot) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

fn addCatalogProjectionBytes(
    current: usize,
    added: usize,
    limits: Limits,
    available_projection_bytes: usize,
) error{ProjectionCapacity}!usize {
    const total = std.math.add(usize, current, added) catch
        return error.ProjectionCapacity;
    if (total > limits.max_catalog_projection_bytes or
        total > available_projection_bytes)
        return error.ProjectionCapacity;
    return total;
}

fn redactFixedWidthNoFail(storage: []u8, credential: []const u8) bool {
    if (credential.len == 0 or storage.len < credential.len) return false;
    var cursor: usize = 0;
    var redacted = false;
    while (cursor <= storage.len - credential.len) {
        const relative = std.mem.indexOf(u8, storage[cursor..], credential) orelse break;
        const match_start = cursor + relative;
        const bounds = utf8RedactionBounds(storage, match_start, credential.len);
        @memset(storage[bounds.start..bounds.end], '*');
        cursor = bounds.end;
        redacted = true;
    }
    return redacted;
}

const RedactionBounds = struct { start: usize, end: usize };

fn utf8RedactionBounds(value: []const u8, match_start: usize, match_len: usize) RedactionBounds {
    var bounds_start = match_start;
    while (bounds_start > 0 and value[bounds_start] & 0xc0 == 0x80) bounds_start -= 1;
    var bounds_end = @min(value.len, match_start + match_len);
    while (bounds_end < value.len and value[bounds_end] & 0xc0 == 0x80) bounds_end += 1;
    return .{ .start = bounds_start, .end = bounds_end };
}
