//! Workbench-owned Product MCP policy and state-transition kernel.
//! This module derives decisions from Product MCP configuration/state and may
//! prepare owned Agent allowlists, but owns no Workbench, worker, timer, or effect.

const std = @import("std");
const lifecycle = @import("metawork_agent");
const mcp_configuration = @import("product_mcp_configuration");
const mcp_state = @import("product_mcp_state");

pub fn validAuthorizationTransition(
    from: mcp_state.McpAuthorizationPhase,
    to: mcp_state.McpAuthorizationPhase,
) bool {
    if (to == .cancelling) return from != .cancelling;
    return switch (from) {
        .discovering => to == .awaiting_consent,
        .awaiting_consent => to == .registering or to == .awaiting_browser,
        .registering => to == .awaiting_browser,
        .awaiting_browser => to == .exchanging,
        .exchanging, .cancelling => false,
    };
}

pub fn serverMutationBusy(
    mcp: *const mcp_state.McpProductState,
    server_id: []const u8,
) bool {
    if (mcp.connection_test) |test_state|
        if (test_state.state == .testing and
            std.mem.eql(u8, test_state.serverId(), server_id)) return true;
    const operation = mcp.authorization_operation orelse return false;
    return std.mem.eql(u8, operation.server_id, server_id);
}

pub fn authorizationAt(
    mcp: *const mcp_state.McpProductState,
    server_id: []const u8,
    phases: []const mcp_state.McpAuthorizationPhase,
) bool {
    const operation = mcp.authorization_operation orelse return false;
    if (!std.mem.eql(u8, operation.server_id, server_id)) return false;
    for (phases) |phase| if (operation.phase == phase) return true;
    return false;
}

fn pendingReauthorizationIndex(
    mcp: *const mcp_state.McpProductState,
    server_id: []const u8,
) ?usize {
    for (mcp.pending_reauthorizations.items, 0..) |pending, index|
        if (std.mem.eql(u8, pending.server_id, server_id)) return index;
    return null;
}

pub fn pendingReauthorizationScopes(
    mcp: *const mcp_state.McpProductState,
    server_id: []const u8,
    consent_epoch: u64,
) []const []const u8 {
    const index = pendingReauthorizationIndex(mcp, server_id) orelse
        return &.{};
    const pending = mcp.pending_reauthorizations.items[index];
    return if (pending.consent_epoch == consent_epoch) pending.scopes else &.{};
}

pub fn scopeSetAddsRequirement(
    approved: []const []const u8,
    challenge: []const []const u8,
) bool {
    for (challenge) |required| {
        var found = false;
        for (approved) |scope| if (std.mem.eql(u8, required, scope)) {
            found = true;
            break;
        };
        if (!found) return true;
    }
    return false;
}

pub fn preparePendingReauthorization(
    allocator: std.mem.Allocator,
    mcp: *mcp_state.McpProductState,
    server_id: []const u8,
    consent_epoch: u64,
    scopes: []const []const u8,
    max_scopes: usize,
) (std.mem.Allocator.Error || error{McpOauthScopeCapacity})!?mcp_state.McpPendingReauthorization {
    const existing_index = pendingReauthorizationIndex(mcp, server_id);
    const existing_scopes = if (existing_index) |index|
        if (mcp.pending_reauthorizations.items[index].consent_epoch == consent_epoch)
            mcp.pending_reauthorizations.items[index].scopes
        else
            &.{}
    else
        &.{};
    if (existing_index != null and
        mcp.pending_reauthorizations.items[existing_index.?].consent_epoch == consent_epoch and
        !scopeSetAddsRequirement(existing_scopes, scopes))
        return null;
    if (existing_index == null)
        try mcp.pending_reauthorizations.ensureUnusedCapacity(allocator, 1);
    return try mcp_state.McpPendingReauthorization.init(
        allocator,
        server_id,
        consent_epoch,
        existing_scopes,
        scopes,
        max_scopes,
    );
}

pub fn installPendingReauthorization(
    mcp: *mcp_state.McpProductState,
    replacement: *mcp_state.McpPendingReauthorization,
) void {
    if (pendingReauthorizationIndex(mcp, replacement.server_id)) |index| {
        mcp.pending_reauthorizations.items[index].deinit();
        mcp.pending_reauthorizations.items[index] = replacement.*;
    } else {
        mcp.pending_reauthorizations.appendAssumeCapacity(replacement.*);
    }
    replacement.* = undefined;
}

fn reconcilePendingReauthorizations(
    mcp: *mcp_state.McpProductState,
    target: mcp_configuration.RegistryWire,
) void {
    var index: usize = 0;
    while (index < mcp.pending_reauthorizations.items.len) {
        const pending = mcp.pending_reauthorizations.items[index];
        const keep = if (mcp_state.findMcpServer(target.servers, pending.server_id)) |server|
            if (server.auth.oauth) |oauth|
                std.mem.eql(u8, oauth.status, "reauth_required") and
                    if (oauth.consent) |consent|
                        consent.epoch == pending.consent_epoch
                    else
                        false
            else
                false
        else
            false;
        if (keep) {
            index += 1;
            continue;
        }
        var removed = mcp.pending_reauthorizations.swapRemove(index);
        removed.deinit();
    }
}

fn serverAdmittedByDesiredState(server: mcp_configuration.ServerWire) bool {
    if (!server.enabled or server.connection_approval == null) return false;
    if (std.mem.eql(u8, server.auth.kind, "oauth")) {
        const oauth = server.auth.oauth orelse return false;
        return std.mem.eql(u8, oauth.status, "ready") and oauth.grant != null;
    }
    return true;
}

pub fn serverToolsForAdmission(
    registry: mcp_configuration.RegistryWire,
    server: mcp_configuration.ServerWire,
) []const []const u8 {
    return mcp_configuration.admissionTools(registry, server);
}

pub fn buildOauthRefreshBinding(
    allocator: std.mem.Allocator,
    registry: mcp_configuration.RegistryWire,
) std.mem.Allocator.Error!mcp_state.McpOauthRefreshBinding {
    const operation = registry.oauth_operation.?;
    const server = mcp_state.findMcpServer(registry.servers, operation.server_id).?;
    const oauth = server.auth.oauth.?;
    const consent = oauth.consent.?;
    const grant = oauth.grant.?;
    const registration = oauth.registration;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const owned = arena.allocator();
    const scopes = try owned.alloc([]const u8, consent.scopes.len);
    for (consent.scopes, scopes) |scope, *owned_scope|
        owned_scope.* = try owned.dupe(u8, scope);
    return .{
        .arena = arena,
        .operation_id = try owned.dupe(u8, operation.id),
        .server_id = try owned.dupe(u8, operation.server_id),
        .endpoint = try owned.dupe(u8, server.transport.url.?),
        .resource = try owned.dupe(u8, consent.resource),
        .issuer = try owned.dupe(u8, consent.issuer),
        .scopes = scopes,
        .client_id = try owned.dupe(u8, registration.client_id.?),
        .token_endpoint_auth_method = try owned.dupe(
            u8,
            registration.token_endpoint_auth_method.?,
        ),
        .client_secret_ref = if (registration.client_secret_ref) |locator|
            try owned.dupe(u8, locator)
        else
            null,
        .refresh_token_ref = try owned.dupe(u8, grant.refresh_token_ref.?),
        .consent_epoch = operation.consent_epoch,
        .token_revision = operation.token_revision.?,
    };
}

fn refreshToolsForServer(
    desired: ?mcp_configuration.RegistryWire,
    applied: mcp_configuration.ServerWire,
) []const []const u8 {
    const registry = desired orelse return &.{};
    const server = mcp_state.findMcpServer(registry.servers, applied.id) orelse return &.{};
    if (!std.mem.eql(u8, &mcp_configuration.runtimeDescriptorFingerprint(server), &mcp_configuration.runtimeDescriptorFingerprint(applied))) return &.{};
    return serverToolsForAdmission(registry, server);
}

pub fn buildRefreshAllowlists(
    allocator: std.mem.Allocator,
    mcp: *const mcp_state.McpProductState,
    desired: ?mcp_configuration.RegistryWire,
) std.mem.Allocator.Error![]const lifecycle.McpServerAllowlist {
    const startup = if (mcp.preparation.registry) |registry|
        registry.value
    else
        return allocator.alloc(lifecycle.McpServerAllowlist, 0);
    var count: usize = 0;
    for (mcp.preparation.server_states) |server_state| {
        if (server_state == .eligible) count += 1;
    }
    const allowlists = try allocator.alloc(lifecycle.McpServerAllowlist, count);
    var write: usize = 0;
    for (startup.servers, mcp.preparation.server_states) |server, server_state| {
        if (server_state != .eligible) continue;
        const tools = refreshToolsForServer(desired, server);
        const owned_tools = try allocator.alloc([]const u8, tools.len);
        for (tools, owned_tools) |tool, *owned|
            owned.* = try allocator.dupe(u8, tool);
        allowlists[write] = .{
            .id = try allocator.dupe(u8, server.id),
            .tools = owned_tools,
        };
        write += 1;
    }
    return allowlists;
}

pub fn expectedGenerationMatches(
    management: *const mcp_configuration.ManagementPort,
    expected_generation: u64,
) bool {
    const inspection = management.inspect();
    if (inspection.health == .outcome_unknown) return true;
    if (inspection.desired_generation) |generation|
        return expected_generation == generation;
    if (inspection.health == .ready) return expected_generation == 0;
    return true;
}

pub fn replaceAdmission(
    mcp: *mcp_state.McpProductState,
    replacement: mcp_state.McpAdmissionAuthority,
) void {
    mcp.admission.deinit();
    mcp.admission = replacement;
}

pub fn installCommittedDesiredState(
    mcp: *mcp_state.McpProductState,
    management: *const mcp_configuration.ManagementPort,
    admission: mcp_state.McpAdmissionAuthority,
) void {
    reconcilePendingReauthorizations(
        mcp,
        management.desiredRegistry() orelse unreachable,
    );
    replaceAdmission(mcp, admission);
}

pub fn blockAdmission(
    mcp: *mcp_state.McpProductState,
    reason: mcp_state.McpAdmissionBlockReason,
) void {
    replaceAdmission(mcp, .{ .blocked = reason });
}

pub fn blockAdmissionForCurrentState(mcp: *mcp_state.McpProductState) void {
    const inspection = if (mcp.management) |*management| management.inspect() else null;
    if (inspection) |value| {
        if (value.health == .outcome_unknown) {
            blockAdmission(mcp, .persistence_outcome_unknown);
            return;
        }
        if (value.health != .ready) {
            blockAdmission(mcp, .management_recovery_required);
            return;
        }
    }
    const alignment = if (inspection) |value|
        value.runtime_alignment
    else
        mcp_configuration.RuntimeAlignment.unknown;
    blockAdmission(mcp, switch (alignment) {
        .current => .activation_unavailable,
        .restart_required => .pending_restart,
        .unknown => .alignment_unknown,
    });
}

pub fn authorizationOperation(
    mcp: ?*const mcp_state.McpProductState,
) ?mcp_state.McpAuthorizationOperationView {
    const current = mcp orelse return null;
    const operation = current.authorization_operation orelse return null;
    return .{
        .phase = operation.phase,
        .server_id = operation.server_id,
        .operation_id = operation.operation_id,
    };
}

pub fn serverOperationBusy(
    mcp: *const mcp_state.McpProductState,
    server_id: []const u8,
) bool {
    if (serverMutationBusy(mcp, server_id)) return true;
    const management = if (mcp.management) |*value| value else return false;
    const registry = management.desiredRegistry() orelse return false;
    const operation = registry.oauth_operation orelse return false;
    return std.mem.eql(u8, operation.server_id, server_id);
}

pub fn nextOauthExpiry(
    mcp: *const mcp_state.McpProductState,
) ?mcp_state.McpOauthExpiry {
    const management = if (mcp.management) |*value| value else return null;
    if (management.inspect().health != .ready) return null;
    const registry = management.desiredRegistry() orelse return null;
    if (registry.oauth_operation != null) return null;
    var earliest: ?mcp_state.McpOauthExpiry = null;
    for (registry.servers) |server| {
        if (mcp.authorization_operation) |operation|
            if (std.mem.eql(u8, operation.server_id, server.id)) continue;
        if (!serverAdmittedByDesiredState(server)) continue;
        const oauth = server.auth.oauth orelse continue;
        const grant = oauth.grant orelse continue;
        if (grant.refresh_token_ref == null) continue;
        const expires_at = grant.expires_at_unix_ms orelse continue;
        const eligible_at = management.oauth_schedule.eligibleAt(server.id, expires_at);
        if (earliest == null or eligible_at < earliest.?.expires_at_unix_ms)
            earliest = .{
                .server_id = server.id,
                .expires_at_unix_ms = eligible_at,
            };
    }
    return earliest;
}

pub fn selectionForNewTask(
    mcp: ?*const mcp_state.McpProductState,
) ?*const lifecycle.McpSelection {
    const current = mcp orelse return null;
    if (!current.admissionFresh()) return null;
    return switch (current.admission) {
        .ready => |ready| ready.selection,
        .blocked => null,
    };
}

pub fn recoveryGeneration(
    mcp: ?*const mcp_state.McpProductState,
    _: bool,
) ?u64 {
    const current = mcp orelse return null;
    if (!current.admissionFresh())
        return null;
    return switch (current.admission) {
        .ready => |ready| ready.catalog_generation,
        .blocked => null,
    };
}

test "Product MCP authorization phases only advance along the approved graph" {
    try std.testing.expect(validAuthorizationTransition(.discovering, .awaiting_consent));
    try std.testing.expect(validAuthorizationTransition(.awaiting_consent, .registering));
    try std.testing.expect(validAuthorizationTransition(.awaiting_consent, .awaiting_browser));
    try std.testing.expect(validAuthorizationTransition(.registering, .awaiting_browser));
    try std.testing.expect(validAuthorizationTransition(.awaiting_browser, .exchanging));
    try std.testing.expect(validAuthorizationTransition(.exchanging, .cancelling));
    try std.testing.expect(!validAuthorizationTransition(.discovering, .exchanging));
    try std.testing.expect(!validAuthorizationTransition(.cancelling, .cancelling));
}

test "Product MCP scope policy detects only new requirements" {
    const approved = [_][]const u8{ "files.read", "files.write" };
    try std.testing.expect(!scopeSetAddsRequirement(&approved, &.{"files.read"}));
    try std.testing.expect(!scopeSetAddsRequirement(&approved, &.{ "files.write", "files.read" }));
    try std.testing.expect(scopeSetAddsRequirement(&approved, &.{"files.delete"}));
}

test "blocked MCP Admission gives an ordinary new Task null authority" {
    var preparation = try mcp_configuration.prepare(
        std.testing.allocator,
        null,
        true,
        false,
        .{},
        .{
            .max_servers = 1,
            .max_tools_per_server = 1,
            .max_namespace_bytes = 1,
            .max_credential_locators = 1,
            .max_runtime_secrets_per_server = 1,
            .max_runtime_secret_bytes_per_server = 1,
        },
    );
    var state: mcp_state.McpProductState = .{
        .preparation = preparation.take(),
        .activation = null,
        .activation_failed = false,
        .management = null,
        .admission = .{ .blocked = .refreshing },
        .host_capabilities = .{},
        .committed = true,
    };
    defer state.deinit();

    try std.testing.expectEqual(
        @as(?*const lifecycle.McpSelection, null),
        selectionForNewTask(&state),
    );
}

test "browser authorization excludes only its server from OAuth refresh selection" {
    const registration: mcp_configuration.OauthRegistrationWire = .{
        .kind = "pre_registered",
        .issuer = "https://auth.example.test",
        .client_id = "client",
        .token_endpoint_auth_method = "none",
        .client_credential_revision = 1,
        .client_secret_ref = null,
    };
    const consent: mcp_configuration.OauthConsentWire = .{
        .epoch = 1,
        .fingerprint = "consent",
        .issuer = "https://auth.example.test",
        .resource = "https://mcp.example.test",
        .scopes = &.{"read"},
        .redirect_uri = "http://127.0.0.1/callback",
        .client_credential_revision = 1,
    };
    var servers = [_]mcp_configuration.ServerWire{
        .{
            .id = "authorizing",
            .namespace = "authorizing",
            .display_name = "Authorizing",
            .enabled = true,
            .negotiation = "automatic",
            .timeout_ms = 1000,
            .transport = .{ .kind = "streamable_http", .url = "https://mcp.example.test/a" },
            .auth = .{ .kind = "oauth", .oauth = .{
                .status = "ready",
                .registration = registration,
                .consent = consent,
                .grant = .{
                    .consent_epoch = 1,
                    .token_revision = 1,
                    .access_token_ref = "a/access",
                    .refresh_token_ref = "a/refresh",
                    .expires_at_unix_ms = 100,
                },
            } },
            .connection_approval = .{ .fingerprint = "approved-a" },
            .tools = &.{"read"},
        },
        .{
            .id = "refreshable",
            .namespace = "refreshable",
            .display_name = "Refreshable",
            .enabled = true,
            .negotiation = "automatic",
            .timeout_ms = 1000,
            .transport = .{ .kind = "streamable_http", .url = "https://mcp.example.test/b" },
            .auth = .{ .kind = "oauth", .oauth = .{
                .status = "ready",
                .registration = registration,
                .consent = consent,
                .grant = .{
                    .consent_epoch = 1,
                    .token_revision = 1,
                    .access_token_ref = "b/access",
                    .refresh_token_ref = "b/refresh",
                    .expires_at_unix_ms = 200,
                },
            } },
            .connection_approval = .{ .fingerprint = "approved-b" },
            .tools = &.{"read"},
        },
    };
    const registry: mcp_configuration.RegistryWire = .{
        .schema_version = mcp_configuration.schema_version,
        .generation = 1,
        .oauth_operation = null,
        .servers = &servers,
    };
    var management = try mcp_configuration.ManagementPort.init(
        std.testing.allocator,
        registry,
        .{
            .persistence = .{ .available = true },
            .credentials = .{ .available = true },
            .limits = .{
                .max_servers = 2,
                .max_tools_per_server = 2,
                .max_namespace_bytes = 32,
                .max_credential_locators = 8,
                .max_runtime_secrets_per_server = 4,
                .max_runtime_secret_bytes_per_server = 1024,
            },
        },
    );
    var management_owned = true;
    defer if (management_owned) management.deinit();
    var preparation = try mcp_configuration.prepare(
        std.testing.allocator,
        null,
        true,
        false,
        .{},
        management.limits,
    );
    var state: mcp_state.McpProductState = .{
        .preparation = preparation.take(),
        .activation = null,
        .activation_failed = false,
        .management = management,
        .admission = .{ .ready = .{ .selection = null, .catalog_generation = null } },
        .authorization_operation = .{
            .phase = .awaiting_browser,
            .server_id = try std.testing.allocator.dupe(u8, "authorizing"),
            .operation_id = try std.testing.allocator.dupe(u8, "browser-1"),
        },
        .host_capabilities = .{},
        .committed = true,
    };
    management_owned = false;
    defer state.deinit();

    const expiry = nextOauthExpiry(&state).?;
    try std.testing.expectEqualStrings("refreshable", expiry.server_id);
    try std.testing.expectEqual(@as(u64, 200), expiry.expires_at_unix_ms);
}

test "OAuth operation remains excluded from every rebuilt Admission target" {
    var oauth_server: mcp_configuration.ServerWire = .{
        .id = "oauth",
        .namespace = "oauth",
        .display_name = "OAuth",
        .enabled = true,
        .negotiation = "automatic",
        .timeout_ms = 1000,
        .transport = .{
            .kind = "streamable_http",
            .url = "https://mcp.example.test/mcp",
        },
        .auth = .{ .kind = "oauth", .oauth = .{
            .status = "ready",
            .registration = .{
                .kind = "pre_registered",
                .issuer = "https://auth.example.test",
                .client_id = "client",
                .token_endpoint_auth_method = "none",
                .client_credential_revision = 1,
                .client_secret_ref = null,
            },
            .consent = null,
            .grant = .{
                .consent_epoch = 3,
                .token_revision = 8,
                .access_token_ref = "oauth/access-8",
                .refresh_token_ref = "oauth/refresh-8",
                .expires_at_unix_ms = 1000,
            },
        } },
        .connection_approval = .{ .fingerprint = "approved" },
        .tools = &.{ "read", "write" },
    };
    const other: mcp_configuration.ServerWire = .{
        .id = "other",
        .namespace = "other",
        .display_name = "Other",
        .enabled = true,
        .negotiation = "automatic",
        .timeout_ms = 1000,
        .transport = .{ .kind = "stdio", .command = "tool" },
        .auth = .{ .kind = "none", .oauth = null },
        .connection_approval = .{ .fingerprint = "approved" },
        .tools = &.{"other.read"},
    };
    var servers = [_]mcp_configuration.ServerWire{ oauth_server, other };
    var registry: mcp_configuration.RegistryWire = .{
        .schema_version = 2,
        .generation = 7,
        .oauth_operation = .{
            .id = "refresh-1",
            .kind = "refresh",
            .server_id = "oauth",
            .connection_fingerprint = "approved",
            .consent_fingerprint = "consent",
            .consent_epoch = 3,
            .token_revision = 8,
        },
        .servers = &servers,
    };
    try std.testing.expectEqual(
        @as(usize, 0),
        serverToolsForAdmission(registry, oauth_server).len,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        refreshToolsForServer(registry, oauth_server).len,
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        serverToolsForAdmission(registry, other).len,
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        refreshToolsForServer(registry, other).len,
    );
    registry.oauth_operation = null;
    try std.testing.expectEqual(
        @as(usize, 2),
        serverToolsForAdmission(registry, oauth_server).len,
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        refreshToolsForServer(registry, oauth_server).len,
    );
    var oauth = oauth_server.auth.oauth.?;
    oauth.status = "reauth_required";
    oauth.grant = null;
    oauth_server.auth.oauth = oauth;
    try std.testing.expectEqual(
        @as(usize, 0),
        serverToolsForAdmission(registry, oauth_server).len,
    );
}
