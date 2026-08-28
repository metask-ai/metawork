//! Agent-private ownership for AgentCore Skill catalog handles.
//! Only MetaWork-owned projection values and an opaque lease token leave this
//! boundary; Session operations may borrow the token synchronously.

const std = @import("std");
const sdk = @import("metask_agentcore");
const wire = sdk.types;

pub const Health = enum {
    healthy,
    degraded,
};

pub const IssueCode = enum {
    invalid_definition,
    source_conflict,
    invalid_resource,
    invalid_invocation_name,
};

pub const IssueKind = enum { invalid, unavailable, conflict };

pub const ResourceReason = enum {
    file_too_large,
    skill_too_large,
    too_many_files,
    too_many_entries,
    directory_too_deep,
    path_too_long,
    unsupported_entry,
    resource_unavailable,
    resource_changed,
};

pub const SourceScope = enum { user, workspace };

pub const Issue = struct {
    kind: IssueKind,
    code: IssueCode,
    reason: ?ResourceReason,
    skill_policy_key: ?[]const u8,
    provider_id: []const u8,
    source_scope: SourceScope,
    source_instance_id: []const u8,
};

pub const Skill = struct {
    skill_id: []const u8,
    skill_policy_key: []const u8,
    invocation_name: []const u8,
    provider_id: []const u8,
    source_scope: SourceScope,
    source_instance_id: []const u8,
    contribution_id: []const u8,
    content_revision: []const u8,
    display_name: []const u8,
    description: []const u8,
    argument_names: []const []const u8,
    max_values: u32,
};

/// Linear, allocator-owned consumer-neutral copy of one catalog descriptor.
/// It contains no AgentCore handle, raw JSON, source path, scope id, or policy.
pub const Projection = struct {
    revision: []const u8,
    health: Health,
    skills: []const Skill,
    issues: []const Issue,
    storage: *anyopaque,

    pub fn deinit(self: *Projection) void {
        const owned: *ProjectionStorage = @ptrCast(@alignCast(self.storage));
        const allocator = owned.allocator;
        owned.arena.deinit();
        allocator.destroy(owned);
        self.* = undefined;
    }
};

/// The concrete handle and binding identity remain private to `agent/`.
pub const Lease = opaque {};

pub const Acquisition = struct {
    lease: *Lease,
    projection: Projection,

    pub fn deinitProjection(self: *Acquisition) void {
        self.projection.deinit();
    }
};

pub const Query = struct {
    workspace_root: []const u8,
    canonical_user_home: []const u8,
    workspace_epoch: []const u8,
};

pub const Error = error{
    InvalidCatalogQuery,
    InvalidCatalogDescriptor,
    DuplicateCatalogIdentity,
    SkillCatalogInvalid,
    SkillCatalogIncomplete,
    CatalogResourceLimit,
    CatalogReleaseFailed,
    CoreCallFailed,
};

const ProjectionStorage = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
};

const LeaseStorage = struct {
    allocator: std.mem.Allocator,
    api: sdk.Api,
    owner: *anyopaque,
    raw: *wire.SkillCatalogHandle,
    workspace_root: []u8,
    canonical_user_home: []u8,
    workspace_epoch: []u8,
};

pub fn query(
    allocator: std.mem.Allocator,
    api: sdk.Api,
    runtime: *wire.RuntimeHandle,
    owner: *anyopaque,
    input: Query,
) (Error || std.mem.Allocator.Error)!Acquisition {
    if (!validQuery(input)) return error.InvalidCatalogQuery;

    var query_input = std.mem.zeroes(wire.SkillCatalogQueryV1);
    query_input.struct_size = @sizeOf(wire.SkillCatalogQueryV1);
    query_input.workspace_root = sdk.bytesView(input.workspace_root);
    query_input.workspace_home = sdk.bytesView(input.canonical_user_home);
    query_input.workspace_epoch = sdk.bytesView(input.workspace_epoch);

    var raw: ?*wire.SkillCatalogHandle = null;
    var descriptor = emptyOwnedBytes();
    var diagnostic = emptyOwnedBytes();
    const status_code = api.skill().resolveCatalog()(
        runtime,
        &query_input,
        &raw,
        &descriptor,
        &diagnostic,
    );
    defer releaseOwned(api, &descriptor);
    defer releaseOwned(api, &diagnostic);

    const status = sdk.Status.fromCode(status_code) catch {
        if (raw) |handle| discardRaw(api, handle);
        return error.CoreCallFailed;
    };
    if (status != .ok) {
        if (raw) |handle| discardRaw(api, handle);
        return catalogStatusError(status);
    }
    const raw_catalog = raw orelse return error.CoreCallFailed;
    var raw_owned = true;
    errdefer if (raw_owned) discardRaw(api, raw_catalog);

    const encoded = sdk.borrowedBytes(.{
        .ptr = descriptor.ptr,
        .len = descriptor.len,
    }) catch return error.InvalidCatalogDescriptor;
    var parsed = sdk.decodeSkillCatalog(allocator, encoded) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ResourceLimit => return error.CatalogResourceLimit,
        error.MalformedJson,
        error.UnknownTag,
        error.InvalidPayload,
        => return error.InvalidCatalogDescriptor,
    };
    releaseOwned(api, &descriptor);
    defer parsed.deinit();

    var projection = try copyProjection(allocator, parsed.value);
    errdefer projection.deinit();
    const lease = try createLease(
        allocator,
        api,
        owner,
        raw_catalog,
        input,
    );
    raw_owned = false;
    return .{ .lease = lease, .projection = projection };
}

pub fn release(lease: *Lease) Error!void {
    const owned = leaseStorage(lease);
    var diagnostic = emptyOwnedBytes();
    const status_code = owned.api.skill().releaseCatalog()(
        owned.raw,
        &diagnostic,
    );
    releaseOwned(owned.api, &diagnostic);
    const allocator = owned.allocator;
    allocator.free(owned.workspace_root);
    allocator.free(owned.canonical_user_home);
    allocator.free(owned.workspace_epoch);
    allocator.destroy(owned);
    const status = sdk.Status.fromCode(status_code) catch
        return error.CatalogReleaseFailed;
    if (status != .ok) return error.CatalogReleaseFailed;
}

pub fn belongsTo(lease: *const Lease, owner: *const anyopaque) bool {
    return leaseStorageConst(lease).owner == owner;
}

pub fn matches(
    lease: *const Lease,
    workspace_root: []const u8,
    canonical_user_home: []const u8,
    workspace_epoch: []const u8,
) bool {
    const owned = leaseStorageConst(lease);
    return std.mem.eql(u8, owned.workspace_root, workspace_root) and
        std.mem.eql(u8, owned.canonical_user_home, canonical_user_home) and
        std.mem.eql(u8, owned.workspace_epoch, workspace_epoch);
}

pub fn rawHandle(lease: *Lease) *wire.SkillCatalogHandle {
    return leaseStorage(lease).raw;
}

fn copyProjection(
    allocator: std.mem.Allocator,
    catalog: sdk.SkillCatalog,
) (Error || std.mem.Allocator.Error)!Projection {
    const storage = try allocator.create(ProjectionStorage);
    errdefer allocator.destroy(storage);
    storage.* = .{
        .allocator = allocator,
        .arena = std.heap.ArenaAllocator.init(allocator),
    };
    errdefer storage.arena.deinit();
    const arena = storage.arena.allocator();

    var skill_ids = std.StringHashMap(void).init(arena);
    var skill_policy_keys = std.StringHashMap(void).init(arena);
    var invocation_names = std.StringHashMap(void).init(arena);
    const skills = try arena.alloc(Skill, catalog.skills.len);
    for (catalog.skills, skills) |source, *target| {
        const id_result = try skill_ids.getOrPut(source.skill_id);
        if (id_result.found_existing) return error.DuplicateCatalogIdentity;
        const policy_result = try skill_policy_keys.getOrPut(source.skill_policy_key);
        if (policy_result.found_existing) return error.DuplicateCatalogIdentity;
        const name_result = try invocation_names.getOrPut(source.invocation_name);
        if (name_result.found_existing) return error.DuplicateCatalogIdentity;
        const argument_names = try arena.alloc(
            []const u8,
            source.argument_schema.names.len,
        );
        for (source.argument_schema.names, argument_names) |name, *copy|
            copy.* = try arena.dupe(u8, name);
        target.* = .{
            .skill_id = try arena.dupe(u8, source.skill_id),
            .skill_policy_key = try arena.dupe(u8, source.skill_policy_key),
            .invocation_name = try arena.dupe(u8, source.invocation_name),
            .provider_id = try arena.dupe(u8, source.source.provider_id),
            .source_scope = switch (source.source.source_scope) {
                .user => .user,
                .workspace => .workspace,
            },
            .source_instance_id = try arena.dupe(u8, source.source.source_instance_id),
            .contribution_id = try arena.dupe(u8, source.source.contribution_id),
            .content_revision = try arena.dupe(u8, source.content_revision),
            .display_name = try arena.dupe(u8, source.display_name),
            .description = try arena.dupe(u8, source.description),
            .argument_names = argument_names,
            .max_values = source.argument_schema.max_values,
        };
    }

    const issues = try arena.alloc(Issue, catalog.issues.len);
    for (catalog.issues, issues) |source, *target| {
        target.* = .{
            .kind = switch (source.kind) {
                .invalid => .invalid,
                .unavailable => .unavailable,
                .conflict => .conflict,
            },
            .code = switch (source.code) {
                .invalid_definition => .invalid_definition,
                .source_conflict => .source_conflict,
                .invalid_resource => .invalid_resource,
                .invalid_invocation_name => .invalid_invocation_name,
            },
            .reason = if (source.reason) |reason| switch (reason) {
                .file_too_large => .file_too_large,
                .skill_too_large => .skill_too_large,
                .too_many_files => .too_many_files,
                .too_many_entries => .too_many_entries,
                .directory_too_deep => .directory_too_deep,
                .path_too_long => .path_too_long,
                .unsupported_entry => .unsupported_entry,
                .resource_unavailable => .resource_unavailable,
                .resource_changed => .resource_changed,
            } else null,
            .skill_policy_key = if (source.skill_policy_key) |key|
                try arena.dupe(u8, key)
            else
                null,
            .provider_id = try arena.dupe(u8, source.provider_id),
            .source_scope = switch (source.source_scope) {
                .user => .user,
                .workspace => .workspace,
            },
            .source_instance_id = try arena.dupe(u8, source.source_instance_id),
        };
    }

    return .{
        .revision = try arena.dupe(u8, catalog.catalog_revision),
        .health = switch (catalog.health) {
            .healthy => .healthy,
            .degraded => .degraded,
        },
        .skills = skills,
        .issues = issues,
        .storage = storage,
    };
}

fn createLease(
    allocator: std.mem.Allocator,
    api: sdk.Api,
    owner: *anyopaque,
    raw: *wire.SkillCatalogHandle,
    input: Query,
) std.mem.Allocator.Error!*Lease {
    const owned = try allocator.create(LeaseStorage);
    errdefer allocator.destroy(owned);
    const workspace_root = try allocator.dupe(u8, input.workspace_root);
    errdefer allocator.free(workspace_root);
    const canonical_user_home = try allocator.dupe(
        u8,
        input.canonical_user_home,
    );
    errdefer allocator.free(canonical_user_home);
    const workspace_epoch = try allocator.dupe(u8, input.workspace_epoch);
    errdefer allocator.free(workspace_epoch);
    owned.* = .{
        .allocator = allocator,
        .api = api,
        .owner = owner,
        .raw = raw,
        .workspace_root = workspace_root,
        .canonical_user_home = canonical_user_home,
        .workspace_epoch = workspace_epoch,
    };
    return @ptrCast(owned);
}

fn validQuery(input: Query) bool {
    return input.workspace_root.len != 0 and
        input.canonical_user_home.len != 0 and
        std.unicode.utf8ValidateSlice(input.workspace_root) and
        std.unicode.utf8ValidateSlice(input.canonical_user_home) and
        std.unicode.utf8ValidateSlice(input.workspace_epoch);
}

fn catalogStatusError(status: sdk.Status) Error {
    return switch (status) {
        .invalid_argument => error.InvalidCatalogQuery,
        .resource_limit => error.CatalogResourceLimit,
        .skill_catalog_invalid => error.SkillCatalogInvalid,
        .skill_catalog_incomplete => error.SkillCatalogIncomplete,
        else => error.CoreCallFailed,
    };
}

fn discardRaw(api: sdk.Api, raw: *wire.SkillCatalogHandle) void {
    var diagnostic = emptyOwnedBytes();
    _ = api.skill().releaseCatalog()(raw, &diagnostic);
    releaseOwned(api, &diagnostic);
}

fn leaseStorage(lease: *Lease) *LeaseStorage {
    return @ptrCast(@alignCast(lease));
}

fn leaseStorageConst(lease: *const Lease) *const LeaseStorage {
    return @ptrCast(@alignCast(lease));
}

fn emptyOwnedBytes() wire.OwnedBytesV1 {
    return .{ .ptr = null, .len = 0 };
}

fn releaseOwned(api: sdk.Api, buffer: *wire.OwnedBytesV1) void {
    if (buffer.ptr != null or buffer.len != 0) api.bufferRelease()(buffer);
}

test "session-independent catalog queries may omit an external epoch" {
    try std.testing.expect(validQuery(.{
        .workspace_root = "/home/metawork",
        .canonical_user_home = "/home/metawork",
        .workspace_epoch = "",
    }));
    try std.testing.expect(!validQuery(.{
        .workspace_root = "",
        .canonical_user_home = "/home/metawork",
        .workspace_epoch = "",
    }));
}
