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

pub const Source = struct {
    canonical_root: []const u8,
    scope: SourceScope,
    source_instance_id: []const u8,
    priority: i32 = 0,
};

pub const QueryTarget = union(enum) {
    /// A home-only management query. Personal additions share the default
    /// source's SDK scope; its lease can never bind a Session.
    management,
    workspace: struct {
        canonical_root: []const u8,
        epoch: []const u8,
    },
};

pub const Query = struct {
    canonical_user_home: []const u8,
    target: QueryTarget,
    additional_sources: []const Source = &.{},
    /// Applied to both canonical .agents roots; Core still resolves scope first.
    default_source_priority: i32 = 0,
    /// Borrowed through query completion. A successful acquisition retains one
    /// reference until its final Core catalog release, including Session and
    /// same-process restore captures. Never encoded into Core or checkpoints.
    source_lifetime: ?SourceLifetime = null,

    pub fn workspaceRoot(self: Query) []const u8 {
        return switch (self.target) {
            .management => self.canonical_user_home,
            .workspace => |workspace| workspace.canonical_root,
        };
    }

    pub fn workspaceEpoch(self: Query) []const u8 {
        return switch (self.target) {
            .management => "",
            .workspace => |workspace| workspace.epoch,
        };
    }
};

/// Pins the immutable files behind a catalog (for example an Office version).
/// Callbacks must be thread-safe, nonblocking reference accounting only: no
/// filesystem effects, allocation, Product mutation, or Agent re-entry.
pub const SourceLifetime = struct {
    context: *anyopaque,
    retain_fn: *const fn (*anyopaque) bool,
    release_fn: *const fn (*anyopaque) void,

    pub fn retain(self: SourceLifetime) error{CatalogResourceLimit}!void {
        if (!self.retain_fn(self.context)) return error.CatalogResourceLimit;
    }

    pub fn release(self: SourceLifetime) void {
        self.release_fn(self.context);
    }
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
    references: std.atomic.Value(usize) = .init(1),
    allocator: std.mem.Allocator,
    api: sdk.Api,
    owner: *anyopaque,
    raw: *wire.SkillCatalogHandle,
    target: std.meta.Tag(QueryTarget),
    workspace_root: []u8,
    canonical_user_home: []u8,
    workspace_epoch: []u8,
    source_lifetime: ?SourceLifetime,
};

pub fn query(
    allocator: std.mem.Allocator,
    api: sdk.Api,
    runtime: *wire.RuntimeHandle,
    owner: *anyopaque,
    input: Query,
) (Error || std.mem.Allocator.Error)!Acquisition {
    try validateQuery(input);

    const sources = try allocator.alloc(wire.SkillSourceV1, input.additional_sources.len);
    defer allocator.free(sources);
    for (input.additional_sources, sources) |source, *encoded| {
        encoded.* = std.mem.zeroes(wire.SkillSourceV1);
        encoded.struct_size = @sizeOf(wire.SkillSourceV1);
        // Core registers the shared root/home default as WORKSPACE. Management
        // has only personal inputs, which must compete in that same scope.
        encoded.scope_code = if (input.target == .management) wire.SKILL_SOURCE_WORKSPACE else switch (source.scope) {
            .user => wire.SKILL_SOURCE_USER,
            .workspace => wire.SKILL_SOURCE_WORKSPACE,
        };
        encoded.root = sdk.bytesView(source.canonical_root);
        encoded.source_instance_id = sdk.bytesView(source.source_instance_id);
        encoded.priority = source.priority;
    }

    var query_input = std.mem.zeroes(wire.SkillCatalogQueryV1);
    query_input.struct_size = @sizeOf(wire.SkillCatalogQueryV1);
    query_input.workspace_root = sdk.bytesView(input.workspaceRoot());
    query_input.workspace_home = sdk.bytesView(input.canonical_user_home);
    query_input.workspace_epoch = sdk.bytesView(input.workspaceEpoch());
    query_input.additional_sources = if (sources.len == 0) null else sources.ptr;
    query_input.additional_source_count = @intCast(sources.len);
    query_input.default_user_source_priority = input.default_source_priority;
    query_input.default_workspace_source_priority = input.default_source_priority;

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

pub fn retain(lease: *Lease) Error!void {
    const owned = leaseStorage(lease);
    var count = owned.references.load(.monotonic);
    while (count != std.math.maxInt(usize)) {
        std.debug.assert(count != 0);
        count = owned.references.cmpxchgWeak(count, count + 1, .monotonic, .monotonic) orelse return;
    }
    return error.CatalogResourceLimit;
}

/// True transfers the final reference to the Runtime release transaction.
/// Non-final releases do not call Core or acquire the Runtime mutex.
pub fn releaseReference(lease: *Lease) bool {
    const previous = leaseStorage(lease).references.fetchSub(1, .acq_rel);
    std.debug.assert(previous != 0);
    return previous == 1;
}

pub fn release(lease: *Lease) Error!void {
    const owned = leaseStorage(lease);
    var diagnostic = emptyOwnedBytes();
    const status_code = owned.api.skill().releaseCatalog()(
        owned.raw,
        &diagnostic,
    );
    releaseOwned(owned.api, &diagnostic);
    if (owned.source_lifetime) |lifetime| lifetime.release();
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

pub fn matchesSession(
    lease: *const Lease,
    workspace_root: []const u8,
    canonical_user_home: []const u8,
    workspace_epoch: []const u8,
) bool {
    const owned = leaseStorageConst(lease);
    return owned.target == .workspace and
        std.mem.eql(u8, owned.workspace_root, workspace_root) and
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
) (std.mem.Allocator.Error || error{CatalogResourceLimit})!*Lease {
    const owned = try allocator.create(LeaseStorage);
    errdefer allocator.destroy(owned);
    const workspace_root = try allocator.dupe(u8, input.workspaceRoot());
    errdefer allocator.free(workspace_root);
    const canonical_user_home = try allocator.dupe(
        u8,
        input.canonical_user_home,
    );
    errdefer allocator.free(canonical_user_home);
    const workspace_epoch = try allocator.dupe(u8, input.workspaceEpoch());
    errdefer allocator.free(workspace_epoch);
    if (input.source_lifetime) |lifetime| try lifetime.retain();
    owned.* = .{
        .allocator = allocator,
        .api = api,
        .owner = owner,
        .raw = raw,
        .target = std.meta.activeTag(input.target),
        .workspace_root = workspace_root,
        .canonical_user_home = canonical_user_home,
        .workspace_epoch = workspace_epoch,
        .source_lifetime = input.source_lifetime,
    };
    return @ptrCast(owned);
}

/// Validate the bounded input before any filesystem traversal or wire allocation.
pub fn validateQuery(input: Query) Error!void {
    if (input.additional_sources.len > wire.MAX_SKILL_SOURCES_V1)
        return error.CatalogResourceLimit;
    var remaining: u64 = wire.MAX_SESSION_METADATA_BYTES_V1;
    try chargeText(&remaining, input.canonical_user_home, true);
    try chargeText(&remaining, input.workspaceRoot(), true);
    try chargeText(&remaining, input.workspaceEpoch(), false);
    if (!std.fs.path.isAbsolute(input.canonical_user_home) or
        !std.fs.path.isAbsolute(input.workspaceRoot())) return error.InvalidCatalogQuery;
    for (input.additional_sources) |source| {
        try chargeText(&remaining, source.canonical_root, true);
        try chargeText(&remaining, source.source_instance_id, true);
        if (!std.fs.path.isAbsolute(source.canonical_root)) return error.InvalidCatalogQuery;
        if (input.target == .management and source.scope != .user)
            return error.InvalidCatalogQuery;
    }
}

fn chargeText(remaining: *u64, value: []const u8, nonempty: bool) Error!void {
    if (value.len > remaining.*) return error.CatalogResourceLimit;
    remaining.* -= value.len;
    if ((nonempty and value.len == 0) or
        std.mem.indexOfScalar(u8, value, 0) != null or
        !std.unicode.utf8ValidateSlice(value)) return error.InvalidCatalogQuery;
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
    const root = if (@import("builtin").os.tag == .windows) "C:\\metawork" else "/home/metawork";
    try validateQuery(.{ .canonical_user_home = root, .target = .management });
    try std.testing.expectError(error.InvalidCatalogQuery, validateQuery(.{
        .canonical_user_home = root,
        .target = .{ .workspace = .{ .canonical_root = "", .epoch = "" } },
    }));
}
