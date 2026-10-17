//! Agent-private consumption of the official AgentCore MCP catalog and
//! selection ABI. This module decodes only through the bundle SDK, then copies
//! the minimum consumer-neutral authority facts. Fingerprints, schema bodies,
//! permission bindings, raw JSON, and issue detail never leave this boundary.

const std = @import("std");
const sdk = @import("metask_agentcore");
const wire = sdk.types;
const mcp_runtime = @import("agent_mcp_runtime");

pub const ExpectedServer = mcp_runtime.ExpectedServer;

pub const Server = struct {
    binding_identity: [32]u8,
    namespace: []const u8,
    fresh: bool,
    ttl_remaining_ms: u64,
    tool_offset: u32,
    tool_count: u32,
};

pub const Tool = struct {
    binding_identity: [32]u8,
    name: []const u8,
};

pub const Issue = struct {
    binding_identity: [32]u8,
    tool_name: ?[]const u8,
};

/// Opaque linear owner for one reduced catalog projection. Public accessors
/// expose only the second-copy view; authority checks and selection creation
/// use private canonical storage that callers cannot replace.
pub const Projection = opaque {
    pub fn deinit(self: *Projection) void {
        const owned = projectionStorage(self);
        const allocator = owned.allocator;
        owned.arena.deinit();
        allocator.destroy(owned);
    }

    pub fn catalogGeneration(self: *const Projection) u64 {
        return projectionStorageConst(self).generation;
    }

    pub fn servers(self: *const Projection) []const Server {
        return projectionStorageConst(self).published_servers;
    }

    pub fn tools(self: *const Projection) []const Tool {
        return projectionStorageConst(self).published_tools;
    }

    pub fn issues(self: *const Projection) []const Issue {
        return projectionStorageConst(self).published_issues;
    }
};

pub const Selector = struct {
    binding_identity: [32]u8,
    tool_name: []const u8,
};

pub const ServerAllowlist = struct {
    id: []const u8,
    tools: []const []const u8,
};

/// Opaque linear Host-owned selection bound to the Runtime and catalog
/// generation that validated it. Callers cannot rewrite authority-bearing
/// generation or selector storage. The ABI descriptor borrows it
/// synchronously.
pub const Selection = opaque {
    pub fn deinit(self: *Selection) void {
        const owned = selectionStorage(self);
        const allocator = owned.allocator;
        owned.arena.deinit();
        allocator.destroy(owned);
    }

    /// Safe projected facts for the exact selectors encoded by this authority.
    /// The names are owned by the Selection and never expose schema or ABI data.
    pub fn selectedTools(self: *const Selection) []const ActivationTool {
        return selectionStorageConst(self).published_tools;
    }
};

/// Process-only original selection and connection provenance. It is not a
/// live Selection and cannot be passed to Core or have its generation edited.
pub const RestoreSelection = opaque {
    pub fn deinit(self: *RestoreSelection) void {
        const storage = restoreStorage(self);
        const allocator = storage.allocator;
        storage.arena.deinit();
        allocator.destroy(storage);
    }

    pub fn clone(self: *const RestoreSelection, allocator: std.mem.Allocator) std.mem.Allocator.Error!*RestoreSelection {
        const source = restoreStorageConst(self);
        const storage = try newRestoreStorage(allocator, source.owner_id, source.tools.len);
        errdefer @as(*RestoreSelection, @ptrCast(storage)).deinit();
        for (source.tools, storage.tools) |tool, *target| target.* = try copyRestoreTool(storage.arena.allocator(), tool);
        return @ptrCast(storage);
    }
};

pub const ActivationState = enum {
    ready,
    degraded,
    unavailable,
};

pub const ActivationServerState = enum {
    ready,
    degraded,
    unavailable,
};

/// Consumer-neutral, bounded health facts derived from the official catalog and
/// the supplied allowlist. No raw issue detail, schema, fingerprint, endpoint,
/// command, or credential crosses this boundary.
pub const ActivationServer = struct {
    id: []const u8,
    binding_identity: [32]u8,
    state: ActivationServerState,
    configured_tool_count: u32,
    selected_tool_count: u32,
    issue_count: u32,
};

/// Safe, authority-derived tool fact for the exact selector set committed by
/// an Activation. Registry allowlists and catalog contents are not recomputed
/// outside Agent from parallel inputs.
pub const ActivationTool = struct {
    server_id: []const u8,
    name: []const u8,
};

/// One atomically constructed MCP authority generation. The object owns both
/// the reduced catalog and its optional complete selection.
pub const Activation = opaque {
    pub fn deinit(self: *Activation) void {
        const owned = activationStorage(self);
        if (owned.selection) |selection| selection.deinit();
        owned.projection.deinit();
        const allocator = owned.allocator;
        owned.arena.deinit();
        allocator.destroy(owned);
    }

    pub fn registryGeneration(self: *const Activation) u64 {
        return activationStorageConst(self).registry_generation;
    }

    pub fn catalogGeneration(self: *const Activation) u64 {
        return activationStorageConst(self).projection.catalogGeneration();
    }

    pub fn state(self: *const Activation) ActivationState {
        return activationStorageConst(self).state;
    }

    pub fn serverHealth(self: *const Activation) []const ActivationServer {
        return activationStorageConst(self).published_servers;
    }

    pub fn selectedTools(self: *const Activation) []const ActivationTool {
        return activationStorageConst(self).published_tools;
    }

    pub fn catalogServers(self: *const Activation) []const Server {
        return activationStorageConst(self).projection.servers();
    }

    pub fn catalogTools(self: *const Activation) []const Tool {
        return activationStorageConst(self).projection.tools();
    }

    pub fn catalogIssues(self: *const Activation) []const Issue {
        return activationStorageConst(self).projection.issues();
    }

    pub fn takeSelection(self: *Activation) ?*Selection {
        const storage = activationStorage(self);
        const selection = storage.selection;
        storage.selection = null;
        return selection;
    }
};

pub const Error = error{
    RefreshFailed,
    DescribeFailed,
    InvalidCatalogDescriptor,
    CatalogResourceLimit,
    CatalogGenerationMismatch,
    CatalogBindingMismatch,
    DuplicateCatalogIdentity,
    InvalidSelection,
    StaleSelection,
    RestoreSourceChanged,
};

const ProjectionStorage = struct {
    allocator: std.mem.Allocator,
    owner_id: u64,
    generation: u64,
    servers: []const Server,
    tools: []const Tool,
    issues: []const Issue,
    published_servers: []const Server,
    published_tools: []const Tool,
    published_issues: []const Issue,
    arena: std.heap.ArenaAllocator,
};

const SelectionStorage = struct {
    allocator: std.mem.Allocator,
    owner_id: u64,
    generation: u64,
    arena: std.heap.ArenaAllocator,
    raw_selectors: []wire.McpSelectorV1,
    published_tools: []const ActivationTool,
};

const RestoreTool = struct {
    binding_identity: [32]u8,
    configuration_fingerprint: [32]u8,
    server_id: []const u8,
    namespace: []const u8,
    name: []const u8,
};

const RestoreStorage = struct {
    allocator: std.mem.Allocator,
    owner_id: u64,
    arena: std.heap.ArenaAllocator,
    tools: []RestoreTool,
};

fn restoreStorage(value: *RestoreSelection) *RestoreStorage {
    return @ptrCast(@alignCast(value));
}

fn restoreStorageConst(value: *const RestoreSelection) *const RestoreStorage {
    return @ptrCast(@alignCast(value));
}

fn newRestoreStorage(allocator: std.mem.Allocator, owner_id: u64, count: usize) std.mem.Allocator.Error!*RestoreStorage {
    const storage = try allocator.create(RestoreStorage);
    errdefer allocator.destroy(storage);
    storage.* = .{ .allocator = allocator, .owner_id = owner_id, .arena = std.heap.ArenaAllocator.init(allocator), .tools = &.{} };
    errdefer storage.arena.deinit();
    storage.tools = try storage.arena.allocator().alloc(RestoreTool, count);
    return storage;
}

fn copyRestoreTool(allocator: std.mem.Allocator, tool: RestoreTool) std.mem.Allocator.Error!RestoreTool {
    return .{
        .binding_identity = tool.binding_identity,
        .configuration_fingerprint = tool.configuration_fingerprint,
        .server_id = try allocator.dupe(u8, tool.server_id),
        .namespace = try allocator.dupe(u8, tool.namespace),
        .name = try allocator.dupe(u8, tool.name),
    };
}

pub fn captureRestoreSelection(allocator: std.mem.Allocator, owner_id: u64, selection: *const Selection, servers: []const ExpectedServer) (Error || std.mem.Allocator.Error)!*RestoreSelection {
    const original = selectionStorageConst(selection);
    if (original.owner_id != owner_id) return error.CatalogBindingMismatch;
    const storage = try newRestoreStorage(allocator, owner_id, original.raw_selectors.len);
    errdefer @as(*RestoreSelection, @ptrCast(storage)).deinit();
    for (original.raw_selectors, storage.tools) |selector, *target| {
        const server = expectedServer(servers, selector.server_binding_identity) orelse return error.RestoreSourceChanged;
        if (std.mem.allEqual(u8, &server.configuration_fingerprint, 0)) return error.RestoreSourceChanged;
        target.* = try copyRestoreTool(storage.arena.allocator(), .{
            .binding_identity = selector.server_binding_identity,
            .configuration_fingerprint = server.configuration_fingerprint,
            .server_id = server.id,
            .namespace = server.namespace,
            .name = sdk.borrowedBytes(selector.tool_name) catch return error.InvalidSelection,
        });
    }
    return @ptrCast(storage);
}

/// Revalidates the original sources, then intersects their exact selectors
/// with today's validated catalog and allowlists. Core owns schema/permission
/// compatibility against the checkpoint; this never adds a newly allowed tool.
pub fn restoreSelectionForActivation(allocator: std.mem.Allocator, owner_id: u64, original: *const RestoreSelection, activation: *const Activation, servers: []const ExpectedServer) (Error || std.mem.Allocator.Error)!*Selection {
    const saved = restoreStorageConst(original);
    const current = activationStorageConst(activation);
    if (saved.owner_id != owner_id or !projectionBelongsTo(current.projection, owner_id)) return error.CatalogBindingMismatch;
    const projection = projectionStorageConst(current.projection);
    var selectors: std.ArrayList(Selector) = .empty;
    defer selectors.deinit(allocator);
    var published: std.ArrayList(ActivationTool) = .empty;
    defer published.deinit(allocator);
    for (saved.tools) |tool| {
        const server = expectedServer(servers, tool.binding_identity) orelse return error.RestoreSourceChanged;
        if (!std.mem.eql(u8, server.id, tool.server_id) or !std.mem.eql(u8, server.namespace, tool.namespace) or
            !std.mem.eql(u8, &server.configuration_fingerprint, &tool.configuration_fingerprint)) return error.RestoreSourceChanged;
        const observed = projectionServer(projection.servers, tool.binding_identity) orelse continue;
        if (!observed.fresh or !projectionContainsTool(projection.tools, tool.binding_identity, tool.name)) continue;
        const allowed = for (server.allowed_tools) |name| {
            if (std.mem.eql(u8, name, tool.name)) break true;
        } else false;
        if (!allowed) continue;
        try selectors.append(allocator, .{ .binding_identity = tool.binding_identity, .tool_name = tool.name });
        try published.append(allocator, .{ .server_id = tool.server_id, .name = tool.name });
    }
    const selection = try createSelection(allocator, owner_id, current.projection, selectors.items);
    errdefer selection.deinit();
    try publishSelectionTools(selection, published.items);
    return selection;
}

const ActivationStorage = struct {
    allocator: std.mem.Allocator,
    registry_generation: u64,
    state: ActivationState,
    projection: *Projection,
    selection: ?*Selection,
    published_servers: []const ActivationServer,
    published_tools: []const ActivationTool,
    arena: std.heap.ArenaAllocator,
};

pub fn refresh(
    allocator: std.mem.Allocator,
    api: sdk.Api,
    runtime: *wire.RuntimeHandle,
    owner_id: u64,
    expected_servers: []const ExpectedServer,
) (Error || std.mem.Allocator.Error)!*Projection {
    if (expected_servers.len > wire.MAX_MCP_SERVERS_V1)
        return error.CatalogBindingMismatch;

    var generation: u64 = 0;
    var diagnostic = emptyOwnedBytes();
    const refresh_code = api.mcp().refresh()(
        runtime,
        &generation,
        &diagnostic,
    );
    defer releaseOwned(api, &diagnostic);
    const refresh_status = sdk.Status.fromCode(refresh_code) catch
        return error.RefreshFailed;
    if (refresh_status != .ok) return error.RefreshFailed;

    var descriptor = emptyOwnedBytes();
    var describe_diagnostic = emptyOwnedBytes();
    const describe_code = api.mcp().describe()(
        runtime,
        &descriptor,
        &describe_diagnostic,
    );
    defer releaseOwned(api, &descriptor);
    defer releaseOwned(api, &describe_diagnostic);
    const describe_status = sdk.Status.fromCode(describe_code) catch
        return error.DescribeFailed;
    if (describe_status != .ok) return error.DescribeFailed;

    const encoded = sdk.borrowedBytes(.{
        .ptr = descriptor.ptr,
        .len = descriptor.len,
    }) catch return error.InvalidCatalogDescriptor;
    var parsed = sdk.decodeMcpCatalog(allocator, encoded) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ResourceLimit => return error.CatalogResourceLimit,
        error.MalformedJson,
        error.UnknownTag,
        error.InvalidPayload,
        => return error.InvalidCatalogDescriptor,
    };
    releaseOwned(api, &descriptor);
    defer parsed.deinit();
    if (generation != parsed.value.catalog_generation)
        return error.CatalogGenerationMismatch;
    return copyProjection(
        allocator,
        owner_id,
        parsed.value,
        expected_servers,
    );
}

pub fn createSelection(
    allocator: std.mem.Allocator,
    owner_id: u64,
    projection: *const Projection,
    requested: []const Selector,
) (Error || std.mem.Allocator.Error)!*Selection {
    const projection_storage = projectionStorageConst(projection);
    if (projection_storage.owner_id != owner_id)
        return error.CatalogBindingMismatch;
    if (requested.len > wire.MAX_MCP_TOOLS_V1)
        return error.InvalidSelection;

    const storage = try allocator.create(SelectionStorage);
    errdefer allocator.destroy(storage);
    storage.* = .{
        .allocator = allocator,
        .owner_id = owner_id,
        .generation = projection_storage.generation,
        .arena = std.heap.ArenaAllocator.init(allocator),
        .raw_selectors = &.{},
        .published_tools = &.{},
    };
    errdefer storage.arena.deinit();
    const arena = storage.arena.allocator();
    const raw_selectors = try arena.alloc(wire.McpSelectorV1, requested.len);
    storage.raw_selectors = raw_selectors;
    for (requested, raw_selectors, 0..) |source, *raw, index| {
        const server = projectionServer(
            projection_storage.servers,
            source.binding_identity,
        ) orelse
            return error.InvalidSelection;
        if (!server.fresh or
            !projectionContainsTool(
                projection_storage.tools,
                source.binding_identity,
                source.tool_name,
            )) return error.InvalidSelection;
        for (requested[0..index]) |previous| if (std.mem.eql(
            u8,
            &previous.binding_identity,
            &source.binding_identity,
        ) and std.mem.eql(u8, previous.tool_name, source.tool_name))
            return error.InvalidSelection;
        const name = try arena.dupe(u8, source.tool_name);
        raw.* = .{
            .struct_size = @sizeOf(wire.McpSelectorV1),
            .reserved0 = 0,
            .server_binding_identity = source.binding_identity,
            .tool_name = sdk.bytesView(name),
            .reserved = [_]u64{0} ** 3,
        };
    }
    return @ptrCast(storage);
}

/// Builds a complete selection candidate for the current Desired Registry
/// allowlists using only this Activation's validated catalog facts. Missing,
/// stale, or issue-bearing tools remain unselected; unknown/duplicate server
/// policies fail closed.
pub fn createSelectionForActivation(
    allocator: std.mem.Allocator,
    owner_id: u64,
    activation: *const Activation,
    allowlists: []const ServerAllowlist,
) (Error || std.mem.Allocator.Error)!?*Selection {
    const storage = activationStorageConst(activation);
    if (!projectionBelongsTo(storage.projection, owner_id) or
        allowlists.len != storage.published_servers.len)
        return error.CatalogBindingMismatch;

    var selectors: std.ArrayList(Selector) = .empty;
    defer selectors.deinit(allocator);
    var selected_tools: std.ArrayList(ActivationTool) = .empty;
    defer selected_tools.deinit(allocator);
    const projection = projectionStorageConst(storage.projection);
    for (storage.published_servers) |server| {
        var policy: ?ServerAllowlist = null;
        for (allowlists, 0..) |candidate, index| {
            if (!std.mem.eql(u8, candidate.id, server.id)) continue;
            for (allowlists[0..index]) |previous|
                if (std.mem.eql(u8, previous.id, candidate.id))
                    return error.InvalidSelection;
            policy = candidate;
            break;
        }
        const selected_policy = policy orelse return error.InvalidSelection;
        const catalog_server = projectionServer(
            projection.servers,
            server.binding_identity,
        ) orelse continue;
        if (!catalog_server.fresh) continue;
        var server_issue = false;
        for (projection.issues) |issue|
            if (std.mem.eql(u8, &issue.binding_identity, &server.binding_identity) and
                issue.tool_name == null)
            {
                server_issue = true;
                break;
            };
        if (server_issue) continue;
        for (selected_policy.tools) |tool| {
            if (projectionHasToolIssue(
                projection.issues,
                server.binding_identity,
                tool,
            ) or !projectionContainsTool(
                projection.tools,
                server.binding_identity,
                tool,
            )) continue;
            try selectors.append(allocator, .{
                .binding_identity = server.binding_identity,
                .tool_name = tool,
            });
            try selected_tools.append(allocator, .{
                .server_id = server.id,
                .name = tool,
            });
        }
    }
    if (selectors.items.len == 0) return null;
    const selection = try createSelection(
        allocator,
        owner_id,
        storage.projection,
        selectors.items,
    );
    errdefer selection.deinit();
    try publishSelectionTools(selection, selected_tools.items);
    return selection;
}

/// Consumes `projection` on success. Failure leaves it owned by the caller.
pub fn createActivation(
    allocator: std.mem.Allocator,
    registry_generation: u64,
    owner_id: u64,
    projection: *Projection,
    expected_servers: []const ExpectedServer,
) (Error || std.mem.Allocator.Error)!*Activation {
    if (registry_generation == 0 or
        !projectionBelongsTo(projection, owner_id) or
        expected_servers.len > wire.MAX_MCP_SERVERS_V1)
        return error.CatalogBindingMismatch;

    const storage = try allocator.create(ActivationStorage);
    errdefer allocator.destroy(storage);
    storage.* = .{
        .allocator = allocator,
        .registry_generation = registry_generation,
        .state = .unavailable,
        .projection = projection,
        .selection = null,
        .published_servers = &.{},
        .published_tools = &.{},
        .arena = std.heap.ArenaAllocator.init(allocator),
    };
    errdefer if (storage.selection) |selection| selection.deinit();
    errdefer storage.arena.deinit();
    const arena = storage.arena.allocator();
    const health = try arena.alloc(ActivationServer, expected_servers.len);
    var selectors: std.ArrayList(Selector) = .empty;
    defer selectors.deinit(allocator);
    var selected_tools: std.ArrayList(ActivationTool) = .empty;
    defer selected_tools.deinit(allocator);
    const canonical = projectionStorageConst(projection);
    var available_count: usize = 0;
    var degraded = false;

    for (expected_servers, health) |expected, *target| {
        const catalog_server = projectionServer(
            canonical.servers,
            expected.binding_identity,
        );
        var issue_count: usize = 0;
        var server_issue = false;
        for (canonical.issues) |issue| {
            if (std.mem.eql(
                u8,
                &issue.binding_identity,
                &expected.binding_identity,
            )) {
                issue_count += 1;
                if (issue.tool_name == null) server_issue = true;
            }
        }
        var selected_count: usize = 0;
        var missing_count: usize = 0;
        if (catalog_server) |server| {
            if (server.fresh) {
                for (expected.allowed_tools) |tool| {
                    if (!server_issue and !projectionHasToolIssue(
                        canonical.issues,
                        expected.binding_identity,
                        tool,
                    ) and projectionContainsTool(
                        canonical.tools,
                        expected.binding_identity,
                        tool,
                    )) {
                        try selectors.append(allocator, .{
                            .binding_identity = expected.binding_identity,
                            .tool_name = tool,
                        });
                        try selected_tools.append(allocator, .{
                            .server_id = expected.id,
                            .name = tool,
                        });
                        selected_count += 1;
                    } else {
                        missing_count += 1;
                    }
                }
            }
        }
        const state: ActivationServerState = if (catalog_server == null or
            !catalog_server.?.fresh)
            .unavailable
        else if (issue_count != 0 or missing_count != 0)
            .degraded
        else
            .ready;
        if (state != .unavailable) available_count += 1;
        if (state != .ready) degraded = true;
        target.* = .{
            .id = try arena.dupe(u8, expected.id),
            .binding_identity = expected.binding_identity,
            .state = state,
            .configured_tool_count = std.math.cast(u32, expected.allowed_tools.len) orelse
                return error.InvalidSelection,
            .selected_tool_count = std.math.cast(u32, selected_count) orelse
                return error.InvalidSelection,
            .issue_count = std.math.cast(u32, issue_count) orelse
                return error.InvalidCatalogDescriptor,
        };
    }

    storage.state = if (available_count == 0)
        .unavailable
    else if (degraded)
        .degraded
    else
        .ready;
    if (storage.state != .unavailable) {
        storage.selection = try createSelection(
            allocator,
            owner_id,
            projection,
            selectors.items,
        );
        try publishSelectionTools(storage.selection.?, selected_tools.items);
    }
    storage.published_servers = health;
    const published_tools = try arena.alloc(ActivationTool, selected_tools.items.len);
    for (selected_tools.items, published_tools) |source, *target| target.* = .{
        .server_id = try arena.dupe(u8, source.server_id),
        .name = try arena.dupe(u8, source.name),
    };
    storage.published_tools = published_tools;
    return @ptrCast(storage);
}

fn publishSelectionTools(
    selection: *Selection,
    tools: []const ActivationTool,
) std.mem.Allocator.Error!void {
    const storage = selectionStorage(selection);
    std.debug.assert(storage.published_tools.len == 0);
    const arena = storage.arena.allocator();
    const published = try arena.alloc(ActivationTool, tools.len);
    for (tools, published) |source, *target| target.* = .{
        .server_id = try arena.dupe(u8, source.server_id),
        .name = try arena.dupe(u8, source.name),
    };
    storage.published_tools = published;
}

fn testRestoreActivation(allocator: std.mem.Allocator, owner_id: u64, generation: u64, names: []const []const u8, servers: []const ExpectedServer) !*Activation {
    var temporary = std.heap.ArenaAllocator.init(allocator);
    defer temporary.deinit();
    var identity_text: [64]u8 = undefined;
    const identity = encodeIdentity(servers[0].binding_identity, &identity_text);
    const tools = try temporary.allocator().alloc(sdk.protocol.McpCatalogTool, names.len);
    for (names, tools) |name, *tool| tool.* = .{
        .server_binding_identity = identity,
        .canonical_name = name,
        .schema_fingerprint = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        .permission_binding = "fixture-binding",
    };
    const projection = try copyProjection(allocator, owner_id, .{
        .schema = "agentcore.mcp-catalog/v1",
        .catalog_generation = generation,
        .catalog_fingerprint = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
        .servers = &.{.{
            .server_binding_identity = identity,
            .namespace = servers[0].namespace,
            .negotiated_protocol = "2026-07-28",
            .server_fingerprint = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            .cache_scope = "private",
            .fresh = true,
            .ttl_remaining_ms = 1000,
            .tool_offset = 0,
            .tool_count = @intCast(names.len),
        }},
        .tools = tools,
        .issues = &.{},
    }, servers);
    errdefer projection.deinit();
    return createActivation(allocator, 1, owner_id, projection, servers);
}

test "MCP restore revalidates original sources and intersects selectors across catalog generations" {
    const servers = [_]ExpectedServer{.{ .id = "files", .binding_identity = @splat(1), .namespace = "files", .allowed_tools = &.{ "read", "write", "new" }, .configuration_fingerprint = @splat(7) }};
    const old = try testRestoreActivation(std.testing.allocator, 11, 2, &.{ "read", "write" }, &servers);
    defer old.deinit();
    const selected = try createSelection(std.testing.allocator, 11, activationStorageConst(old).projection, &.{.{ .binding_identity = @splat(1), .tool_name = "read" }});
    const saved = try captureRestoreSelection(std.testing.allocator, 11, selected, &servers);
    defer saved.deinit();
    selected.deinit();
    const clone = try saved.clone(std.testing.allocator);
    defer clone.deinit();
    const current = try testRestoreActivation(std.testing.allocator, 11, 9, &.{ "read", "write", "new" }, &servers);
    defer current.deinit();
    const restored = try restoreSelectionForActivation(std.testing.allocator, 11, clone, current, &servers);
    defer restored.deinit();
    try std.testing.expectEqual(@as(u64, 9), selectionGeneration(restored));
    try std.testing.expectEqual(@as(usize, 1), restored.selectedTools().len);
    try std.testing.expectEqualStrings("read", restored.selectedTools()[0].name);
    try std.testing.expectEqual(@as(u64, 2), projectionGeneration(activationStorageConst(old).projection));
    try std.testing.expectError(error.CatalogBindingMismatch, restoreSelectionForActivation(std.testing.allocator, 12, saved, current, &servers));
    var changed = servers;
    changed[0].configuration_fingerprint = @splat(8);
    try std.testing.expectError(error.RestoreSourceChanged, restoreSelectionForActivation(std.testing.allocator, 11, saved, current, &changed));
    try std.testing.expectError(error.RestoreSourceChanged, restoreSelectionForActivation(std.testing.allocator, 11, saved, current, &.{}));
    changed = servers;
    changed[0].allowed_tools = &.{"write"};
    const narrowed = try restoreSelectionForActivation(std.testing.allocator, 11, saved, current, &changed);
    defer narrowed.deinit();
    try std.testing.expectEqual(@as(usize, 0), narrowed.selectedTools().len);
    const missing = try testRestoreActivation(std.testing.allocator, 11, 10, &.{"write"}, &servers);
    defer missing.deinit();
    const degraded = try restoreSelectionForActivation(std.testing.allocator, 11, saved, missing, &servers);
    defer degraded.deinit();
    try std.testing.expectEqual(@as(usize, 0), degraded.selectedTools().len);
}

test "MCP restore capture clone and revalidation are allocation failure atomic" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            const servers = [_]ExpectedServer{.{ .id = "files", .binding_identity = @splat(1), .namespace = "files", .allowed_tools = &.{"read"}, .configuration_fingerprint = @splat(7) }};
            const activation = try testRestoreActivation(allocator, 11, 2, &.{"read"}, &servers);
            defer activation.deinit();
            const selected = activation.takeSelection().?;
            defer selected.deinit();
            const saved = try captureRestoreSelection(allocator, 11, selected, &servers);
            defer saved.deinit();
            const clone = try saved.clone(allocator);
            defer clone.deinit();
            const restored = try restoreSelectionForActivation(allocator, 11, clone, activation, &servers);
            defer restored.deinit();
            try std.testing.expectEqual(@as(usize, 1), restored.selectedTools().len);
        }
    }.run, .{});
}

pub fn belongsTo(selection: *const Selection, owner_id: u64) bool {
    return selectionStorageConst(selection).owner_id == owner_id;
}

pub fn projectionGeneration(projection: *const Projection) u64 {
    return projectionStorageConst(projection).generation;
}

pub fn projectionBelongsTo(
    projection: *const Projection,
    owner_id: u64,
) bool {
    return projectionStorageConst(projection).owner_id == owner_id;
}

pub fn selectionGeneration(selection: *const Selection) u64 {
    return selectionStorageConst(selection).generation;
}

/// Encodes one complete Session authority replacement. A null MetaWork
/// selection means an empty authority view, but the returned ABI descriptor
/// itself is always present so it is valid for `session_update_mcp`.
pub fn rawSelectionReplacement(selection: ?*const Selection) wire.McpSelectionV1 {
    const raw_selectors = if (selection) |value|
        selectionStorageConst(value).raw_selectors
    else
        &.{};
    return .{
        .struct_size = @sizeOf(wire.McpSelectionV1),
        .reserved0 = 0,
        .selectors = if (raw_selectors.len == 0)
            null
        else
            raw_selectors.ptr,
        .selector_count = raw_selectors.len,
        .reserved = [_]u64{0} ** 4,
    };
}

fn copyProjection(
    allocator: std.mem.Allocator,
    owner_id: u64,
    catalog: sdk.McpCatalog,
    expected_servers: []const ExpectedServer,
) (Error || std.mem.Allocator.Error)!*Projection {
    const storage = try allocator.create(ProjectionStorage);
    errdefer allocator.destroy(storage);
    storage.* = .{
        .allocator = allocator,
        .owner_id = owner_id,
        .generation = catalog.catalog_generation,
        .servers = &.{},
        .tools = &.{},
        .issues = &.{},
        .published_servers = &.{},
        .published_tools = &.{},
        .published_issues = &.{},
        .arena = std.heap.ArenaAllocator.init(allocator),
    };
    errdefer storage.arena.deinit();
    const arena = storage.arena.allocator();

    const servers = try arena.alloc(Server, catalog.servers.len);
    for (catalog.servers, servers, 0..) |source, *target, index| {
        const identity = decodeIdentity(source.server_binding_identity) orelse
            return error.InvalidCatalogDescriptor;
        const expected = expectedServer(expected_servers, identity) orelse
            return error.CatalogBindingMismatch;
        if (!std.mem.eql(u8, expected.namespace, source.namespace))
            return error.CatalogBindingMismatch;
        for (servers[0..index]) |previous| if (std.mem.eql(
            u8,
            &previous.binding_identity,
            &identity,
        ) or std.mem.eql(u8, previous.namespace, source.namespace))
            return error.DuplicateCatalogIdentity;
        target.* = .{
            .binding_identity = identity,
            .namespace = try arena.dupe(u8, source.namespace),
            .fresh = source.fresh,
            .ttl_remaining_ms = source.ttl_remaining_ms,
            .tool_offset = source.tool_offset,
            .tool_count = source.tool_count,
        };
    }

    const tools = try arena.alloc(Tool, catalog.tools.len);
    for (catalog.tools, tools, 0..) |source, *target, index| {
        const identity = decodeIdentity(source.server_binding_identity) orelse
            return error.InvalidCatalogDescriptor;
        if (expectedServer(expected_servers, identity) == null)
            return error.CatalogBindingMismatch;
        for (tools[0..index]) |previous| if (std.mem.eql(
            u8,
            &previous.binding_identity,
            &identity,
        ) and std.mem.eql(u8, previous.name, source.canonical_name))
            return error.DuplicateCatalogIdentity;
        target.* = .{
            .binding_identity = identity,
            .name = try arena.dupe(u8, source.canonical_name),
        };
    }

    const issues = try arena.alloc(Issue, catalog.issues.len);
    for (catalog.issues, issues) |source, *target| {
        const identity = decodeIdentity(source.server_binding_identity) orelse
            return error.InvalidCatalogDescriptor;
        if (expectedServer(expected_servers, identity) == null)
            return error.CatalogBindingMismatch;
        target.* = .{
            .binding_identity = identity,
            .tool_name = if (source.tool_name) |name|
                try arena.dupe(u8, name)
            else
                null,
        };
    }
    storage.servers = servers;
    storage.tools = tools;
    storage.issues = issues;

    // The public projection is deliberately a second copy. Callers may
    // inspect it, but selection and integrity checks always read the private
    // canonical arrays above. Sharing either structs or string bytes would
    // let a caller rewrite the value against which it is later validated.
    const published_servers = try arena.alloc(Server, servers.len);
    for (servers, published_servers) |source, *target| {
        target.* = source;
        target.namespace = try arena.dupe(u8, source.namespace);
    }
    const published_tools = try arena.alloc(Tool, tools.len);
    for (tools, published_tools) |source, *target| {
        target.* = source;
        target.name = try arena.dupe(u8, source.name);
    }
    const published_issues = try arena.alloc(Issue, issues.len);
    for (issues, published_issues) |source, *target| {
        target.* = source;
        target.tool_name = if (source.tool_name) |name|
            try arena.dupe(u8, name)
        else
            null;
    }
    storage.published_servers = published_servers;
    storage.published_tools = published_tools;
    storage.published_issues = published_issues;
    return @ptrCast(storage);
}

fn projectionServer(
    servers: []const Server,
    identity: [32]u8,
) ?Server {
    for (servers) |server| if (std.mem.eql(
        u8,
        &server.binding_identity,
        &identity,
    )) return server;
    return null;
}

fn projectionContainsTool(
    tools: []const Tool,
    identity: [32]u8,
    name: []const u8,
) bool {
    for (tools) |tool| if (std.mem.eql(
        u8,
        &tool.binding_identity,
        &identity,
    ) and std.mem.eql(u8, tool.name, name)) return true;
    return false;
}

fn projectionHasToolIssue(
    issues: []const Issue,
    identity: [32]u8,
    name: []const u8,
) bool {
    for (issues) |issue| if (std.mem.eql(
        u8,
        &issue.binding_identity,
        &identity,
    ) and issue.tool_name != null and
        std.mem.eql(u8, issue.tool_name.?, name)) return true;
    return false;
}

fn expectedServer(
    expected: []const ExpectedServer,
    identity: [32]u8,
) ?ExpectedServer {
    for (expected) |server| if (std.mem.eql(
        u8,
        &server.binding_identity,
        &identity,
    )) return server;
    return null;
}

fn decodeIdentity(encoded: []const u8) ?[32]u8 {
    if (encoded.len != 64) return null;
    var result: [32]u8 = undefined;
    for (0..result.len) |index| {
        const high = hexNibble(encoded[index * 2]) orelse return null;
        const low = hexNibble(encoded[index * 2 + 1]) orelse return null;
        result[index] = high << 4 | low;
    }
    return result;
}

fn hexNibble(value: u8) ?u8 {
    return switch (value) {
        '0'...'9' => value - '0',
        'a'...'f' => value - 'a' + 10,
        else => null,
    };
}

fn projectionStorage(projection: *Projection) *ProjectionStorage {
    return @ptrCast(@alignCast(projection));
}

fn projectionStorageConst(projection: *const Projection) *const ProjectionStorage {
    return @ptrCast(@alignCast(projection));
}

fn selectionStorage(selection: *Selection) *SelectionStorage {
    return @ptrCast(@alignCast(selection));
}

fn selectionStorageConst(selection: *const Selection) *const SelectionStorage {
    return @ptrCast(@alignCast(selection));
}

fn activationStorage(activation: *Activation) *ActivationStorage {
    return @ptrCast(@alignCast(activation));
}

fn activationStorageConst(activation: *const Activation) *const ActivationStorage {
    return @ptrCast(@alignCast(activation));
}

fn emptyOwnedBytes() wire.OwnedBytesV1 {
    return .{ .ptr = null, .len = 0 };
}

fn releaseOwned(api: sdk.Api, buffer: *wire.OwnedBytesV1) void {
    if (buffer.ptr != null or buffer.len != 0) api.bufferRelease()(buffer);
}

fn encodeIdentity(identity: [32]u8, output: *[64]u8) []const u8 {
    const hex = "0123456789abcdef";
    for (identity, 0..) |byte, index| {
        output[index * 2] = hex[byte >> 4];
        output[index * 2 + 1] = hex[byte & 0x0f];
    }
    return output;
}

test "projection drops fingerprints schema bindings and issue detail" {
    const identity: [32]u8 = @splat(0x2a);
    var identity_storage: [64]u8 = undefined;
    const encoded_identity = encodeIdentity(identity, &identity_storage);
    const servers = [_]sdk.protocol.McpCatalogServer{.{
        .server_binding_identity = encoded_identity,
        .namespace = "github",
        .negotiated_protocol = "2026-07-28",
        .server_fingerprint = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .cache_scope = "private",
        .fresh = true,
        .ttl_remaining_ms = 1000,
        .tool_offset = 0,
        .tool_count = 1,
    }};
    const tools = [_]sdk.protocol.McpCatalogTool{.{
        .server_binding_identity = encoded_identity,
        .canonical_name = "search",
        .schema_fingerprint = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        .permission_binding = "mcp:github/search",
    }};
    const issues = [_]sdk.protocol.McpCatalogIssue{.{
        .issue_id = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
        .server_binding_identity = encoded_identity,
        .tool_name = "search",
        .kind = "unavailable",
        .detail = "raw detail must not be copied",
    }};
    const owner_id: u64 = 41;
    const projection = try copyProjection(
        std.testing.allocator,
        owner_id,
        .{
            .schema = "agentcore.mcp-catalog/v1",
            .catalog_generation = 7,
            .catalog_fingerprint = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
            .servers = &servers,
            .tools = &tools,
            .issues = &issues,
        },
        &.{.{
            .id = "github",
            .binding_identity = identity,
            .namespace = "github",
            .allowed_tools = &.{"search"},
        }},
    );
    defer projection.deinit();
    try std.testing.expectEqual(@as(u64, 7), projection.catalogGeneration());
    try std.testing.expectEqualStrings("github", projection.servers()[0].namespace);
    try std.testing.expectEqualStrings("search", projection.tools()[0].name);
    try std.testing.expectEqualStrings("search", projection.issues()[0].tool_name.?);
    try std.testing.expect(projectionBelongsTo(projection, owner_id));
    @constCast(projection.servers())[0].fresh = false;
    @constCast(projection.tools()[0].name)[0] = 'S';

    const selection = try createSelection(
        std.testing.allocator,
        owner_id,
        projection,
        &.{.{ .binding_identity = identity, .tool_name = "search" }},
    );
    defer selection.deinit();
    const raw = rawSelectionReplacement(selection);
    try std.testing.expectEqual(@as(u64, 1), raw.selector_count);
    try std.testing.expectEqualDeep(identity, raw.selectors.?[0].server_binding_identity);

    const empty = rawSelectionReplacement(null);
    try std.testing.expectEqual(@as(u32, @sizeOf(wire.McpSelectionV1)), empty.struct_size);
    try std.testing.expectEqual(@as(u64, 0), empty.selector_count);
    try std.testing.expectEqual(@as(?[*]const wire.McpSelectorV1, null), empty.selectors);
}

test "selection rejects stale authority and duplicate selectors" {
    const identity: [32]u8 = @splat(1);
    const owner_id: u64 = 41;
    const other_owner_id: u64 = 42;
    const storage = try std.testing.allocator.create(ProjectionStorage);
    storage.* = .{
        .allocator = std.testing.allocator,
        .owner_id = owner_id,
        .generation = 1,
        .servers = &.{},
        .tools = &.{},
        .issues = &.{},
        .published_servers = &.{},
        .published_tools = &.{},
        .published_issues = &.{},
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
    };
    const arena = storage.arena.allocator();
    const servers = try arena.dupe(Server, &.{.{
        .binding_identity = identity,
        .namespace = "github",
        .fresh = true,
        .ttl_remaining_ms = 1,
        .tool_offset = 0,
        .tool_count = 1,
    }});
    const tools = try arena.dupe(Tool, &.{.{
        .binding_identity = identity,
        .name = "search",
    }});
    storage.servers = servers;
    storage.tools = tools;
    storage.published_servers = servers;
    storage.published_tools = tools;
    const projection: *Projection = @ptrCast(storage);
    defer projection.deinit();
    try std.testing.expectError(
        error.CatalogBindingMismatch,
        createSelection(
            std.testing.allocator,
            other_owner_id,
            projection,
            &.{},
        ),
    );
    try std.testing.expectError(
        error.InvalidSelection,
        createSelection(
            std.testing.allocator,
            owner_id,
            projection,
            &.{
                .{ .binding_identity = identity, .tool_name = "search" },
                .{ .binding_identity = identity, .tool_name = "search" },
            },
        ),
    );
}

test "activation atomically intersects allowlists and publishes bounded health" {
    const first_identity: [32]u8 = @splat(1);
    const second_identity: [32]u8 = @splat(2);
    var encoded_storage: [64]u8 = undefined;
    const encoded_identity = encodeIdentity(first_identity, &encoded_storage);
    const catalog_servers = [_]sdk.protocol.McpCatalogServer{.{
        .server_binding_identity = encoded_identity,
        .namespace = "search",
        .negotiated_protocol = "2026-07-28",
        .server_fingerprint = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .cache_scope = "private",
        .fresh = true,
        .ttl_remaining_ms = 1000,
        .tool_offset = 0,
        .tool_count = 1,
    }};
    const catalog_tools = [_]sdk.protocol.McpCatalogTool{.{
        .server_binding_identity = encoded_identity,
        .canonical_name = "search",
        .schema_fingerprint = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        .permission_binding = "mcp:search/search",
    }};
    const expected = [_]ExpectedServer{
        .{
            .id = "search",
            .binding_identity = first_identity,
            .namespace = "search",
            .allowed_tools = &.{ "search", "missing" },
        },
        .{
            .id = "offline",
            .binding_identity = second_identity,
            .namespace = "offline",
            .allowed_tools = &.{"read"},
        },
    };
    const owner_id: u64 = 9;
    const projection = try copyProjection(
        std.testing.allocator,
        owner_id,
        .{
            .schema = "agentcore.mcp-catalog/v1",
            .catalog_generation = 4,
            .catalog_fingerprint = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
            .servers = &catalog_servers,
            .tools = &catalog_tools,
            .issues = &.{},
        },
        &expected,
    );
    const activation = try createActivation(
        std.testing.allocator,
        7,
        owner_id,
        projection,
        &expected,
    );
    defer activation.deinit();
    try std.testing.expectEqual(ActivationState.degraded, activation.state());
    try std.testing.expectEqual(@as(u64, 7), activation.registryGeneration());
    try std.testing.expectEqual(@as(usize, 2), activation.serverHealth().len);
    try std.testing.expectEqual(ActivationServerState.degraded, activation.serverHealth()[0].state);
    try std.testing.expectEqual(@as(u32, 1), activation.serverHealth()[0].selected_tool_count);
    try std.testing.expectEqual(ActivationServerState.unavailable, activation.serverHealth()[1].state);
    try std.testing.expectEqual(@as(usize, 1), activation.selectedTools().len);
    try std.testing.expectEqualStrings("search", activation.selectedTools()[0].server_id);
    try std.testing.expectEqualStrings("search", activation.selectedTools()[0].name);
    const raw = rawSelectionReplacement(activationStorageConst(activation).selection);
    try std.testing.expectEqual(@as(u64, 1), raw.selector_count);
    const startup_selection = activation.takeSelection().?;
    startup_selection.deinit();
    try std.testing.expect(activationStorageConst(activation).selection == null);
    try std.testing.expect((try createSelectionForActivation(
        std.testing.allocator,
        owner_id,
        activation,
        &.{
            .{ .id = "search", .tools = &.{} },
            .{ .id = "offline", .tools = &.{} },
        },
    )) == null);
    const replacement = (try createSelectionForActivation(
        std.testing.allocator,
        owner_id,
        activation,
        &.{
            .{ .id = "search", .tools = &.{"search"} },
            .{ .id = "offline", .tools = &.{"read"} },
        },
    )).?;
    defer replacement.deinit();
    try std.testing.expectEqual(
        @as(u64, 1),
        rawSelectionReplacement(replacement).selector_count,
    );
    try std.testing.expectEqual(@as(usize, 1), replacement.selectedTools().len);
    try std.testing.expectEqualStrings(
        "search",
        replacement.selectedTools()[0].server_id,
    );
    try std.testing.expectEqualStrings(
        "search",
        replacement.selectedTools()[0].name,
    );
}
