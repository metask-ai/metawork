//! Workbench-held Product MCP runtime state and freshness authority.
//! This module owns product state, not Workbench executor workers.

const std = @import("std");
const lifecycle = @import("metawork_agent");
const mcp_configuration = @import("product_mcp_configuration");

pub const McpHostCapabilities = struct {
    connection_approval: bool = false,
    secret_capture: bool = false,
    oauth: bool = false,
};

/// Successful Workbench initialization consumes `preparation` and
/// `activation`; failure consumes neither. App clears its optional activation
/// owner only after init returns successfully.
pub const McpStartupConfiguration = struct {
    preparation: ?*mcp_configuration.Preparation = null,
    activation: ?*lifecycle.McpActivation = null,
    activation_failed: bool = false,
    management: ?mcp_configuration.ManagementConfiguration = null,
    host_capabilities: McpHostCapabilities = .{},
};

pub const McpAdmissionBlockReason = enum {
    pending_restart,
    alignment_unknown,
    refreshing,
    activation_unavailable,
    persistence_outcome_unknown,
    management_recovery_required,
    shutting_down,
};

pub const McpAdmissionReady = struct {
    selection: ?*lifecycle.McpSelection,
    catalog_generation: ?u64,
};

pub const McpAdmissionAuthority = union(enum) {
    ready: McpAdmissionReady,
    blocked: McpAdmissionBlockReason,

    pub fn deinit(self: *McpAdmissionAuthority) void {
        switch (self.*) {
            .ready => |ready| if (ready.selection) |selection| selection.deinit(),
            .blocked => {},
        }
        self.* = undefined;
    }
};

pub const RecoveryMcpAuthority = struct {
    selection: ?*lifecycle.McpSelection,
    catalog_generation: ?u64,

    pub fn deinit(self: *RecoveryMcpAuthority) void {
        if (self.selection) |selection| selection.deinit();
        self.* = undefined;
    }
};

pub const McpOauthRefreshBinding = struct {
    pub const RuntimeBinding = enum { absent, matching_descriptor, retained_descriptor };

    arena: std.heap.ArenaAllocator,
    operation_id: []const u8,
    server_id: []const u8,
    endpoint: []const u8,
    private_endpoint: ?mcp_configuration.SensitiveEndpointWire = null,
    resource: []const u8,
    private_resource: ?mcp_configuration.SensitiveEndpointWire = null,
    issuer: []const u8,
    scopes: []const []const u8,
    client_id: []const u8,
    token_endpoint_auth_method: []const u8,
    client_secret_ref: ?[]const u8,
    refresh_token_ref: []const u8,
    consent_epoch: u64,
    token_revision: u64,

    /// Product proof at operation begin; apply shares the durable marker boundary.
    runtime_binding: RuntimeBinding,

    pub fn deinit(self: *McpOauthRefreshBinding) void {
        if (self.private_endpoint != null) std.crypto.secureZero(u8, @constCast(self.endpoint));
        if (self.private_resource != null) std.crypto.secureZero(u8, @constCast(self.resource));
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const McpOauthRefreshBeginOutcome = union(enum) {
    started: McpOauthRefreshBinding,
    rejected,
    persistence_outcome_unknown,
};

pub const McpOauthAuthorizationPlan = struct {
    attempt_id: u64,
    server_id: []const u8,
    issuer: []const u8,
    resource: []const u8,
    private_resource_identity: ?[]const u8 = null,
    scopes: []const []const u8,
    redirect_uri: []const u8,
};

pub const McpOauthAuthorizationBinding = struct {
    attempt_id: u64,
    server_id: []const u8,
    issuer: []const u8,
    resource: []const u8,
    private_resource: ?mcp_configuration.SensitiveEndpointWire = null,
    scopes: []const []const u8,
    redirect_uri: []const u8,
    client_id: []const u8,
};

pub const McpOauthAuthorizationOutcome = union(enum) {
    ready: McpOauthAuthorizationBinding,
    rejected,
    persistence_outcome_unknown,
};

pub const McpOauthOperationHandle = struct {
    id: []const u8,
    server_id: []const u8,
};

pub const McpOauthCodeExchangeBinding = struct {
    operation: McpOauthOperationHandle,
    issuer: []const u8,
    client_id: []const u8,
    token_endpoint_auth_method: []const u8,
    client_secret_ref: ?[]const u8,
    resource: []const u8,
    private_resource: ?mcp_configuration.SensitiveEndpointWire = null,
    redirect_uri: []const u8,
};

pub const McpOauthOperationBeginOutcome = union(enum) {
    started: McpOauthOperationHandle,
    rejected,
    persistence_outcome_unknown,
};

pub const McpOauthCodeExchangeBeginOutcome = union(enum) {
    started: McpOauthCodeExchangeBinding,
    rejected,
    persistence_outcome_unknown,
};

pub const McpOauthExpiry = struct {
    server_id: []const u8,
    expires_at_unix_ms: u64,
    refresh: bool = true,
    runtime_loaded: bool = true,
    consent_epoch: u64 = 0,
    token_revision: u64 = 0,
    source_fingerprint: [32]u8 = @splat(0),
};

pub const McpRuntimeAuthorizationFailure = struct {
    server_id: []const u8,
    source_fingerprint: [32]u8,
    reason: enum { challenge, http_rejection, expired_grant },
    consent_epoch: u64,
    token_revision: u64,
    challenge_scopes: []const []const u8,
    challenge_scopes_complete: bool,
};

pub const McpRuntimeAuthorizationFailureOutcome = enum {
    applied,
    stale,
    pending,
    rejected,
    persistence_outcome_unknown,
};

pub const McpAuthorizationPhase = enum {
    discovering,
    awaiting_consent,
    registering,
    awaiting_browser,
    exchanging,
    cancelling,
};

pub const McpConnectionTestOutcome = enum {
    connected,
    failed,
};

pub const McpConfigurationApplyState = enum {
    idle,
    applying,
    failed,
};

pub const McpConnectionTest = struct {
    server_id_storage: [64]u8 = undefined,
    server_id_len: usize = 0,
    state: enum { testing, connected, failed },
    tool_count: u32 = 0,
    issue_count: u32 = 0,

    pub fn init(server_id: []const u8) ?McpConnectionTest {
        if (server_id.len == 0 or server_id.len > 64) return null;
        var result: McpConnectionTest = .{ .state = .testing };
        @memcpy(result.server_id_storage[0..server_id.len], server_id);
        result.server_id_len = server_id.len;
        return result;
    }

    pub fn serverId(self: *const McpConnectionTest) []const u8 {
        return self.server_id_storage[0..self.server_id_len];
    }
};

pub const McpAuthorizationOperationView = struct {
    phase: McpAuthorizationPhase,
    server_id: []const u8,
    operation_id: []const u8,
};

pub const McpAuthorizationStart = struct {
    arena: std.heap.ArenaAllocator,
    operation_id: []const u8,
    server_id: []const u8,
    endpoint: []const u8,
    private_endpoint: ?mcp_configuration.SensitiveEndpointWire = null,
    registration_kind: []const u8,
    client_id: ?[]const u8,
    token_endpoint_auth_method: ?[]const u8,
    additional_scopes: []const []const u8,

    pub fn deinit(self: *McpAuthorizationStart) void {
        if (self.private_endpoint != null) std.crypto.secureZero(u8, @constCast(self.endpoint));
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const McpSecretCaptureTarget = union(enum) {
    stdio_environment: []const u8,
    http_header: []const u8,
    oauth_client_secret,
};

pub const McpAuthorizationOperation = struct {
    phase: McpAuthorizationPhase,
    server_id: []u8,
    operation_id: []u8,

    pub fn deinit(self: *McpAuthorizationOperation, allocator: std.mem.Allocator) void {
        allocator.free(self.server_id);
        allocator.free(self.operation_id);
        self.* = undefined;
    }
};

pub fn ownMcpScopeUnion(
    allocator: std.mem.Allocator,
    first: []const []const u8,
    second: []const []const u8,
    max_scopes: usize,
) (std.mem.Allocator.Error || error{McpOauthScopeCapacity})![]const []const u8 {
    const scopes = try allocator.alloc([]const u8, max_scopes);
    var count: usize = 0;
    for (first) |scope| {
        if (count == max_scopes) return error.McpOauthScopeCapacity;
        scopes[count] = try allocator.dupe(u8, scope);
        count += 1;
    }
    for (second) |scope| {
        var duplicate = false;
        for (scopes[0..count]) |current| if (std.mem.eql(u8, current, scope)) {
            duplicate = true;
            break;
        };
        if (duplicate) continue;
        if (count == max_scopes) return error.McpOauthScopeCapacity;
        scopes[count] = try allocator.dupe(u8, scope);
        count += 1;
    }
    std.mem.sort([]const u8, scopes[0..count], {}, struct {
        fn lessThan(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.order(u8, left, right) == .lt;
        }
    }.lessThan);
    return scopes[0..count];
}

pub const McpPendingReauthorization = struct {
    arena: std.heap.ArenaAllocator,
    server_id: []const u8,
    consent_epoch: u64,
    scopes: []const []const u8,

    pub fn init(
        allocator: std.mem.Allocator,
        server_id: []const u8,
        consent_epoch: u64,
        existing: []const []const u8,
        incoming: []const []const u8,
        max_scopes: usize,
    ) (std.mem.Allocator.Error || error{McpOauthScopeCapacity})!McpPendingReauthorization {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const owned = arena.allocator();
        const scopes = try ownMcpScopeUnion(
            owned,
            existing,
            incoming,
            max_scopes,
        );
        return .{
            .arena = arena,
            .server_id = try owned.dupe(u8, server_id),
            .consent_epoch = consent_epoch,
            .scopes = scopes,
        };
    }

    pub fn deinit(self: *McpPendingReauthorization) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// A prebuilt Application-owned HTTP snapshot replacement. `commit_fn` must
/// be allocation-free and is invoked exactly after the registry result is
/// known durable but before restored Admission is installed.
pub const McpOauthRuntimeCommit = struct {
    context: *anyopaque,
    commit_fn: *const fn (*anyopaque) void,

    pub fn commit(self: McpOauthRuntimeCommit) void {
        self.commit_fn(self.context);
    }
};

/// Process-lifetime Task cap. It owns names and provenance, never credentials.
pub const McpTaskReference = struct {
    pub const Tool = struct {
        server_id: []const u8,
        name: []const u8,
        fingerprint: [32]u8,
        allowed: bool = true,
    };
    arena: std.heap.ArenaAllocator,
    task_id: u64,
    tools: []Tool,

    pub fn init(allocator: std.mem.Allocator, task_id: u64, selection: *const lifecycle.McpSelection, servers: []const mcp_configuration.ServerWire) (std.mem.Allocator.Error || error{InvalidMcpSelection})!McpTaskReference {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const owned = arena.allocator();
        const tools = try owned.alloc(Tool, selection.selectedTools().len);
        for (selection.selectedTools(), tools) |selected, *tool| {
            const applied = findMcpServer(servers, selected.server_id) orelse return error.InvalidMcpSelection;
            tool.* = .{ .server_id = try owned.dupe(u8, selected.server_id), .name = try owned.dupe(u8, selected.name), .fingerprint = mcp_configuration.runtimeDescriptorFingerprint(applied) };
        }
        return .{ .arena = arena, .task_id = task_id, .tools = tools };
    }

    pub fn deinit(self: *McpTaskReference) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn reconcile(self: *McpTaskReference, desired: mcp_configuration.RegistryWire) void {
        for (self.tools) |*tool| {
            // A deletion preserves the last explicitly committed ceiling.
            const server = findMcpServer(desired.servers, tool.server_id) orelse continue;
            tool.allowed = for (server.tools) |name| {
                if (std.mem.eql(u8, name, tool.name)) break true;
            } else false;
            if (std.mem.eql(u8, &tool.fingerprint, &mcp_configuration.runtimeDescriptorFingerprint(server)) and !mcp_configuration.serverRuntimeAuthorizationReady(server)) tool.allowed = false;
        }
    }
};

pub const McpProductState = struct {
    preparation: mcp_configuration.Preparation,
    activation: ?*lifecycle.McpActivation,
    activation_failed: bool,
    management: ?mcp_configuration.ManagementPort,
    admission: McpAdmissionAuthority,
    refresh_request_generation: u64 = 0,
    refresh_pending: bool = false,
    refresh_deadline_ms: ?u64 = null,
    expiry_deadline_ms: ?u64 = null,
    catalog_observed_at_ms: ?u64 = null,
    refresh_not_before_ms: ?u64 = null,
    refresh_failures: u8 = 0,
    refresh_paused: bool = false,
    refresh_visible: bool = false,
    refresh_schedule_failed: bool = false,
    connection_test: ?McpConnectionTest = null,
    process_observations: std.ArrayList(mcp_configuration.ProcessObservation) = .empty,
    configuration_apply_state: McpConfigurationApplyState = .idle,
    apply_target: ?mcp_configuration.RuntimeApplyTarget = null,
    runtime_uncertain: bool = false,
    task_references: std.ArrayList(McpTaskReference) = .empty,
    authorization_operation: ?McpAuthorizationOperation = null,
    pending_reauthorizations: std.ArrayList(McpPendingReauthorization) = .empty,
    host_capabilities: McpHostCapabilities,
    committed: bool = false,

    /// Read-only freshness observation. Queries never enqueue work; an expired
    /// admission cannot be projected as ready even if a timer or wake is lost.
    pub fn admissionFresh(self: *const McpProductState) bool {
        if (!self.committed or self.admission != .ready) return false;
        const activation = self.activation orelse return self.admission.ready.catalog_generation == null;
        if (activation.state() == .unavailable) return false;
        const selection = self.admission.ready.selection orelse return true;
        if (selection.selectedTools().len == 0) return true;
        const age_ms = activation.catalogAgeMs() orelse return false;
        for (selection.selectedTools()) |tool| {
            const binding = for (activation.serverHealth()) |server| {
                if (std.mem.eql(u8, server.id, tool.server_id)) break server.binding_identity;
            } else return false;
            const fresh = for (activation.catalogServers()) |server| {
                if (std.mem.eql(u8, &server.binding_identity, &binding))
                    break server.fresh and age_ms < server.ttl_remaining_ms;
            } else false;
            if (!fresh) return false;
        }
        return true;
    }

    pub fn deinit(self: *McpProductState) void {
        for (self.process_observations.items) |value| self.preparation.allocator.free(value.server_id);
        self.process_observations.deinit(self.preparation.allocator);
        for (self.task_references.items) |*reference| reference.deinit();
        self.task_references.deinit(self.preparation.allocator);
        if (self.authorization_operation) |*operation|
            operation.deinit(self.preparation.allocator);
        for (self.pending_reauthorizations.items) |*pending| pending.deinit();
        self.pending_reauthorizations.deinit(self.preparation.allocator);
        self.admission.deinit();
        if (self.activation) |activation| activation.deinit();
        if (self.management) |*management| management.deinit();
        self.preparation.deinit();
        self.* = undefined;
    }
};

pub fn initialMcpAdmission(
    activation: ?*lifecycle.McpActivation,
    activation_failed: bool,
    management: ?*const mcp_configuration.ManagementPort,
) McpAdmissionAuthority {
    if (management) |port| {
        const inspection = port.inspect();
        if (inspection.health == .outcome_unknown) {
            discardActivationSelection(activation);
            return .{ .blocked = .persistence_outcome_unknown };
        }
        if (inspection.health != .ready) {
            discardActivationSelection(activation);
            return .{ .blocked = .management_recovery_required };
        }
        switch (inspection.runtime_alignment) {
            .restart_required => {
                discardActivationSelection(activation);
                return .{ .blocked = .pending_restart };
            },
            .unknown => {
                discardActivationSelection(activation);
                return .{ .blocked = .alignment_unknown };
            },
            .current => {},
        }
    }
    if (activation_failed) {
        discardActivationSelection(activation);
        return .{ .blocked = .activation_unavailable };
    }
    if (activation) |value| return .{ .ready = .{
        .selection = value.takeSelection(),
        .catalog_generation = value.catalogGeneration(),
    } };
    return .{ .ready = .{
        .selection = null,
        .catalog_generation = null,
    } };
}

fn discardActivationSelection(activation: ?*lifecycle.McpActivation) void {
    if (activation) |value|
        if (value.takeSelection()) |selection| selection.deinit();
}

pub fn findMcpServer(
    servers: []const mcp_configuration.ServerWire,
    id: []const u8,
) ?mcp_configuration.ServerWire {
    for (servers) |server|
        if (std.mem.eql(u8, server.id, id)) return server;
    return null;
}

/// One-shot monotonic timer used only to refresh AgentCore MCP authority
/// before its earliest advertised catalog TTL expires.
pub const McpRefreshTimer = struct {
    context: ?*anyopaque = null,
    enabled: bool = false,
    now_monotonic_ms: *const fn (?*anyopaque) ?u64 = noMcpRefreshClock,
    arm_at: *const fn (?*anyopaque, u64) bool = noMcpRefreshArm,
    cancel: *const fn (?*anyopaque) void = noMcpRefreshCancel,

    pub fn now(self: McpRefreshTimer) ?u64 {
        if (!self.enabled) return null;
        return self.now_monotonic_ms(self.context);
    }

    pub fn armAt(self: McpRefreshTimer, deadline_ms: u64) bool {
        return self.enabled and self.arm_at(self.context, deadline_ms);
    }

    pub fn cancelCurrent(self: McpRefreshTimer) void {
        if (self.enabled) self.cancel(self.context);
    }
};

fn noMcpRefreshClock(_: ?*anyopaque) ?u64 {
    return null;
}

fn noMcpRefreshArm(_: ?*anyopaque, _: u64) bool {
    return false;
}

fn noMcpRefreshCancel(_: ?*anyopaque) void {}

pub fn mcpRefreshDelayMs(servers: []const lifecycle.McpCatalogServer) ?u64 {
    var earliest_ttl_ms: ?u64 = null;
    for (servers) |server| {
        if (!server.fresh or server.ttl_remaining_ms == 0)
            continue;
        earliest_ttl_ms = if (earliest_ttl_ms) |current|
            @min(current, server.ttl_remaining_ms)
        else
            server.ttl_remaining_ms;
    }
    const ttl_ms = earliest_ttl_ms orelse return null;
    const lead_ms = @min(ttl_ms / 4, 5_000);
    return ttl_ms - lead_ms;
}

pub fn mcpRefreshDeadlineMs(
    servers: []const lifecycle.McpCatalogServer,
    observed_at_ms: ?u64,
) ?u64 {
    const observed = observed_at_ms orelse return null;
    const delay = mcpRefreshDelayMs(servers) orelse return null;
    return std.math.add(u64, observed, delay) catch null;
}

test "MCP refresh timer uses earliest safe fresh catalog TTL" {
    const servers = [_]lifecycle.McpCatalogServer{
        .{
            .binding_identity = [_]u8{1} ** 32,
            .namespace = "slow",
            .fresh = true,
            .ttl_remaining_ms = 60_000,
            .tool_offset = 0,
            .tool_count = 1,
        },
        .{
            .binding_identity = [_]u8{2} ** 32,
            .namespace = "fast",
            .fresh = true,
            .ttl_remaining_ms = 40_000,
            .tool_offset = 1,
            .tool_count = 1,
        },
        .{
            .binding_identity = [_]u8{3} ** 32,
            .namespace = "short",
            .fresh = true,
            .ttl_remaining_ms = 30_000,
            .tool_offset = 2,
            .tool_count = 1,
        },
        .{
            .binding_identity = [_]u8{4} ** 32,
            .namespace = "stale",
            .fresh = false,
            .ttl_remaining_ms = 1,
            .tool_offset = 3,
            .tool_count = 0,
        },
    };
    try std.testing.expectEqual(@as(?u64, 25_000), mcpRefreshDelayMs(&servers));
    try std.testing.expectEqual(
        @as(?u64, 125_000),
        mcpRefreshDeadlineMs(&servers, 100_000),
    );
    try std.testing.expectEqual(
        @as(?u64, 25_000),
        mcpRefreshDelayMs(&.{ servers[2], servers[3] }),
    );
}

test "MCP refresh deadlines retain short TTL and reject missing clocks or overflow" {
    var server: lifecycle.McpCatalogServer = .{
        .binding_identity = @splat(1),
        .namespace = "short",
        .fresh = true,
        .ttl_remaining_ms = 1,
        .tool_offset = 0,
        .tool_count = 1,
    };
    try std.testing.expectEqual(@as(?u64, 1), mcpRefreshDelayMs(&.{server}));
    try std.testing.expectEqual(@as(?u64, 101), mcpRefreshDeadlineMs(&.{server}, 100));
    try std.testing.expectEqual(@as(?u64, null), mcpRefreshDeadlineMs(&.{server}, null));
    try std.testing.expectEqual(@as(?u64, null), mcpRefreshDeadlineMs(&.{server}, std.math.maxInt(u64)));
    server.ttl_remaining_ms = 0;
    try std.testing.expectEqual(@as(?u64, null), mcpRefreshDelayMs(&.{server}));
}
