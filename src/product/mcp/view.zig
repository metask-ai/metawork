//! Pure Workbench-owned Product MCP snapshot derivation.
//! This module borrows Product MCP state and a callback-scoped text projector;
//! it owns no state, credential material, worker, or external effect.

const std = @import("std");
const mcp_configuration = @import("product_mcp_configuration");
const mcp_state = @import("product_mcp_state");
const policy = @import("product_mcp_policy");

pub const Error = error{SnapshotTooLarge};

const McpAvailability = enum { unavailable, ready, degraded };
const McpApplyStatus = enum { current, pending, waiting_auth, applying, rejected, failed, unknown };
const McpRuntimeStatus = enum {
    not_loaded,
    ready,
    disabled,
    needs_authentication,
    @"unreachable",
    invalid_catalog,
};

/// A callback-scoped borrow of Workbench's global sensitive-text projection.
/// The callbacks neither transfer the Workbench nor expose credential bytes.
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

pub const Input = struct {
    state: ?*const mcp_state.McpProductState,
    refresh_job_active: bool,
    text: TextProjection,
};

fn mcpRuntimeServerStatus(
    mcp: *const mcp_state.McpProductState,
    server_id: []const u8,
    preparation: mcp_configuration.ServerPreparationState,
) McpRuntimeStatus {
    return switch (preparation) {
        .disabled => .disabled,
        .unapproved, .needs_authentication, .reauth_required => .needs_authentication,
        .invalid_catalog => .invalid_catalog,
        .eligible => status: {
            if (mcp.activation_failed) break :status .not_loaded;
            const activation = mcp.activation orelse break :status .not_loaded;
            for (activation.serverHealth()) |health| {
                if (!std.mem.eql(u8, health.id, server_id)) continue;
                break :status switch (health.state) {
                    .ready => fresh: {
                        const age = activation.catalogAgeMs() orelse break :fresh .not_loaded;
                        for (activation.catalogServers()) |server|
                            if (std.mem.eql(u8, &server.binding_identity, &health.binding_identity))
                                break :fresh if (server.fresh and age < server.ttl_remaining_ms) .ready else .not_loaded;
                        break :fresh .not_loaded;
                    },
                    .degraded => .invalid_catalog,
                    .unavailable => .@"unreachable",
                };
            }
            break :status .not_loaded;
        },
    };
}

fn mcpAvailability(mcp: ?*const mcp_state.McpProductState) McpAvailability {
    const current = mcp orelse return .unavailable;
    if (!current.committed or current.runtime_uncertain) return .unavailable;
    if (current.preparation.state == .unavailable or current.activation_failed) return .unavailable;
    const management = if (current.management) |*value| value else return .unavailable;
    if (management.inspect().health != .ready) return .unavailable;
    const registry = management.desiredRegistry();
    var missing = false;
    var observed = false;
    var unhealthy = false;
    if (registry) |desired| for (desired.servers) |server| {
        switch (mcpDesiredServerRuntimeStatus(current, server)) {
            .not_loaded => missing = true,
            .ready => observed = true,
            .disabled => {},
            else => unhealthy = true,
        }
    };
    if (missing and !observed and !unhealthy) return .unavailable;
    if (missing or unhealthy or current.configuration_apply_state == .failed or applyFailureCount(current) > 0) return .degraded;
    return .ready;
}

fn mcpDesiredServerRuntimeStatus(
    mcp: *const mcp_state.McpProductState,
    desired: mcp_configuration.ServerWire,
) McpRuntimeStatus {
    if (!desired.enabled) return .disabled;
    if (mcp.runtime_uncertain) return .not_loaded;
    const startup = mcp.preparation.registry orelse return .not_loaded;
    for (startup.value.servers, mcp.preparation.server_states) |server, state|
        if (sameRuntimeDescriptor(server, desired))
            return mcpRuntimeServerStatus(mcp, desired.id, state);
    return .not_loaded;
}

fn actualEntry(mcp: *const mcp_state.McpProductState, id: []const u8) ?@typeInfo(@FieldType(mcp_configuration.RuntimeManifest, "entries")).pointer.child {
    const management = if (mcp.management) |*value| value else return null;
    const manifest = if (management.runtime_manifest) |*value| value else return null;
    for (manifest.entries) |entry| if (std.mem.eql(u8, entry.id, id)) return entry;
    return null;
}

fn taskReferenceCount(mcp: *const mcp_state.McpProductState, id: []const u8) usize {
    if (mcp.runtime_uncertain) return 0;
    const entry = actualEntry(mcp, id) orelse return 0;
    return if (entry.state == .loaded) entry.task_references else 0;
}

fn serverApplyStatus(mcp: *const mcp_state.McpProductState, server: mcp_configuration.ServerWire) McpApplyStatus {
    if (mcp.runtime_uncertain) return .unknown;
    if (mcp.apply_target) |target| if (std.mem.eql(u8, target.id(), server.id)) return .applying;
    const management = if (mcp.management) |*value| value else return .unknown;
    if (management.runtime_manifest == null) return .unknown;
    const target = management.runtime_manifest.?.targetFor(server.id, management.desiredRegistry(), management.limits) orelse return .current;
    if (management.convergence.handled(target)) for (management.convergence.results.items) |result| {
        if (!std.mem.eql(u8, result.target.id(), server.id) or !std.mem.eql(u8, &result.target.fingerprint, &target.fingerprint)) continue;
        return switch (result.outcome) {
            .pending => .applying,
            .waiting_auth => .waiting_auth,
            .rejected => .rejected,
            .failed, .capacity => .failed,
        };
    };
    return .pending;
}

fn serverCapacityBlocked(mcp: *const mcp_state.McpProductState, server: mcp_configuration.ServerWire) bool {
    if (serverApplyStatus(mcp, server) != .failed) return false;
    const management = if (mcp.management) |*value| value else return false;
    for (management.convergence.results.items) |result| {
        if (std.mem.eql(u8, result.target.id(), server.id)) return result.outcome == .capacity;
    }
    return false;
}

fn retainedMemberCount(mcp: *const mcp_state.McpProductState) usize {
    if (mcp.runtime_uncertain) return 0;
    const management = if (mcp.management) |*value| value else return 0;
    const desired = management.desiredRegistry() orelse return 0;
    const manifest = if (management.runtime_manifest) |*value| value else return 0;
    var count: usize = 0;
    for (manifest.entries) |entry| {
        if (entry.state != .loaded or entry.task_references == 0) continue;
        var enabled = false;
        for (desired.servers) |server| if (std.mem.eql(u8, entry.id, server.id)) {
            enabled = server.enabled;
            break;
        };
        if (!enabled) count += 1;
    }
    return count;
}

fn applyFailureCount(mcp: *const mcp_state.McpProductState) usize {
    if (mcp.runtime_uncertain) return 0;
    const management = if (mcp.management) |*value| value else return 0;
    const manifest = if (management.runtime_manifest) |*value| value else return 0;
    return manifest.failureCount(management.desiredRegistry(), management.limits, &management.convergence);
}

fn sameRuntimeDescriptor(loaded: mcp_configuration.ServerWire, desired: mcp_configuration.ServerWire) bool {
    return std.mem.eql(u8, loaded.id, desired.id) and
        std.mem.eql(u8, &mcp_configuration.runtimeDescriptorFingerprint(loaded), &mcp_configuration.runtimeDescriptorFingerprint(desired));
}

fn mcpToolSelectedForNewTask(
    mcp: *const mcp_state.McpProductState,
    server_id: []const u8,
    tool_name: []const u8,
) bool {
    if (!mcp.admissionFresh()) return false;
    const ready = switch (mcp.admission) {
        .ready => |value| value,
        .blocked => return false,
    };
    const selection = ready.selection orelse return false;
    for (selection.selectedTools()) |tool|
        if (std.mem.eql(u8, tool.server_id, server_id) and
            std.mem.eql(u8, tool.name, tool_name)) return true;
    return false;
}

fn mcpServerHasNewTaskAccess(
    mcp: *const mcp_state.McpProductState,
    server_id: []const u8,
) bool {
    if (!mcp.admissionFresh()) return false;
    const ready = switch (mcp.admission) {
        .ready => |value| value,
        .blocked => return false,
    };
    const selection = ready.selection orelse return false;
    for (selection.selectedTools()) |tool|
        if (std.mem.eql(u8, tool.server_id, server_id)) return true;
    return false;
}

fn mcpNewTaskAccess(
    mcp: *const mcp_state.McpProductState,
    server_id: []const u8,
) []const u8 {
    if (mcp.admission == .ready and !mcp.admissionFresh()) return "unavailable";
    return switch (mcp.admission) {
        .ready => if (mcpServerHasNewTaskAccess(mcp, server_id))
            "available"
        else
            "not_allowed",
        .blocked => |reason| switch (reason) {
            .pending_restart => "restart_required",
            else => "unavailable",
        },
    };
}

fn desiredAllowsTool(server: mcp_configuration.ServerWire, name: []const u8) bool {
    for (server.tools) |tool| if (std.mem.eql(u8, tool, name)) return true;
    return false;
}

fn mcpToolAlreadyPublished(tools: []const []const u8, index: usize) bool {
    for (tools[0..index]) |previous|
        if (std.mem.eql(u8, previous, tools[index])) return true;
    return false;
}

fn activationServerIndex(
    mcp: *const mcp_state.McpProductState,
    desired: mcp_configuration.ServerWire,
) ?usize {
    if (mcp.runtime_uncertain) return null;
    if (mcpDesiredServerRuntimeStatus(mcp, desired) == .not_loaded) return null;
    const startup = mcp.preparation.registry orelse return null;
    const matching = for (startup.value.servers) |server| {
        if (sameRuntimeDescriptor(server, desired)) break true;
    } else false;
    if (!matching) return null;
    const activation = mcp.activation orelse return null;
    for (activation.serverHealth(), 0..) |server, index|
        if (std.mem.eql(u8, server.id, desired.id)) return index;
    return null;
}

fn mcpConnectionContainsSensitiveText(
    text: TextProjection,
    server: mcp_configuration.ServerWire,
) bool {
    if (server.transport.command) |command|
        if (text.containsSensitive(command)) return true;
    for (server.transport.arguments) |argument|
        if (argument.literal) |literal|
            if (text.containsSensitive(literal)) return true;
    if (server.transport.cwd) |cwd|
        if (text.containsSensitive(cwd)) return true;
    for (server.transport.environment) |slot|
        if (text.containsSensitive(slot.name)) return true;
    if (server.transport.url) |url|
        if (text.containsSensitive(url)) return true;
    for (server.transport.headers) |slot|
        if (text.containsSensitive(slot.name)) return true;
    if (server.auth.oauth) |oauth|
        if (oauth.registration.client_id) |client_id|
            if (text.containsSensitive(client_id)) return true;
    return false;
}

fn mcpProjectionRedacted(
    text: TextProjection,
    mcp: *const mcp_state.McpProductState,
    registry: ?mcp_configuration.RegistryWire,
) bool {
    const desired = registry orelse return false;
    for (desired.servers) |server| {
        if (!mcp_configuration.publishableProductText(server.display_name) or
            text.containsSensitive(server.id) or
            text.containsSensitive(server.namespace) or
            text.containsSensitive(server.display_name)) return true;
        if (mcpConnectionContainsSensitiveText(text, server)) return true;
        for (server.tools) |tool|
            if (!mcp_configuration.publishableProductText(tool) or
                text.containsSensitive(tool)) return true;
        const activation_index = activationServerIndex(mcp, server);
        if (mcp.activation) |activation| if (activation_index) |index| {
            const bound = activation.serverHealth()[index];
            for (activation.catalogTools()) |tool|
                if (std.mem.eql(u8, &tool.binding_identity, &bound.binding_identity) and
                    (!mcp_configuration.publishableProductText(tool.name) or
                        text.containsSensitive(tool.name))) return true;
        };
    }
    return false;
}

fn processDiagnostic(mcp: *const mcp_state.McpProductState, server: mcp_configuration.ServerWire) ?[]const u8 {
    for (mcp.process_observations.items) |value| {
        if (!std.mem.eql(u8, value.server_id, server.id) or !std.mem.eql(u8, &value.source, &mcp_configuration.runtimeDescriptorFingerprint(server))) continue;
        return switch (value.fact) {
            .pending => null,
            .spawned => "The process started but did not complete the MCP handshake. Check its arguments and dependencies.",
            .executable_missing => "The executable was not found. Check the command, installation and search path.",
            .access_denied => "Permission to start the executable was denied. Check file and directory access.",
            .invalid_executable => "The executable format is invalid for this platform. Check the selected program.",
            .spawn_failed => "The process could not be started. Check the program and working directory.",
            .host_resource_unavailable => "Host resources for the process are unavailable. Free resources and retry the connection.",
            .stdio_closed => "The process started, then its STDIO closed. Check its arguments and dependencies.",
        };
    }
    return null;
}

fn mcpSecretSlotReady(
    management: *const mcp_configuration.ManagementPort,
    slot: mcp_configuration.SecretSlotWire,
) bool {
    const locator = slot.credential_ref orelse return false;
    return management.credentialPresence(locator) == .present;
}

fn mcpStaticSecretsReady(
    management: *const mcp_configuration.ManagementPort,
    server: mcp_configuration.ServerWire,
) bool {
    const slots = if (std.mem.eql(u8, server.transport.kind, "stdio"))
        server.transport.environment
    else
        server.transport.headers;
    if (slots.len == 0) return false;
    for (slots) |slot| if (!mcpSecretSlotReady(management, slot)) return false;
    return true;
}

fn mcpAuthorizationInProgress(
    mcp: *const mcp_state.McpProductState,
    server_id: []const u8,
) bool {
    const operation = mcp.authorization_operation orelse return false;
    if (!std.mem.eql(u8, operation.server_id, server_id)) return false;
    return switch (operation.phase) {
        .discovering,
        .awaiting_consent,
        .registering,
        .awaiting_browser,
        .exchanging,
        .cancelling,
        => true,
    };
}

fn mcpAuthorizationStatus(
    mcp: *const mcp_state.McpProductState,
    management: *const mcp_configuration.ManagementPort,
    server: mcp_configuration.ServerWire,
) []const u8 {
    if (std.mem.eql(u8, server.auth.kind, "none")) return "not_required";
    if (std.mem.eql(u8, server.auth.kind, "static")) {
        if (mcpStaticSecretsReady(management, server)) return "ready";
        return if (mcp.host_capabilities.secret_capture)
            "missing_static_secret"
        else
            "capability_unavailable";
    }
    if (mcpAuthorizationInProgress(mcp, server.id)) return "authorizing";
    if (management.desiredRegistry()) |registry| if (registry.oauth_operation) |operation|
        if (std.mem.eql(u8, operation.kind, "refresh") and std.mem.eql(u8, operation.server_id, server.id)) return "refreshing";
    const oauth = server.auth.oauth orelse return "capability_unavailable";
    if (std.mem.eql(u8, oauth.status, "ready") and oauth.grant != null)
        return "ready";
    if (std.mem.eql(u8, oauth.status, "reauth_required"))
        return "reauth_required";
    if (std.mem.eql(u8, oauth.registration.kind, "pre_registered")) {
        const method = oauth.registration.token_endpoint_auth_method orelse
            return "capability_unavailable";
        if (!std.mem.eql(u8, method, "none")) {
            const locator = oauth.registration.client_secret_ref orelse
                return if (mcp.host_capabilities.secret_capture)
                    "missing_oauth_client_secret"
                else
                    "capability_unavailable";
            if (management.credentialPresence(locator) != .present)
                return if (mcp.host_capabilities.secret_capture)
                    "missing_oauth_client_secret"
                else
                    "capability_unavailable";
        }
    }
    if (!mcp.host_capabilities.oauth) return "capability_unavailable";
    if (std.mem.eql(u8, oauth.status, "client_registration_required"))
        return "client_registration_required";
    return "consent_required";
}

fn writeMcpSecretSlots(
    writer: *std.Io.Writer,
    text: TextProjection,
    management: *const mcp_configuration.ManagementPort,
    slots: []const mcp_configuration.SecretSlotWire,
) Error!void {
    writer.writeByte('[') catch return error.SnapshotTooLarge;
    for (slots, 0..) |slot, index| {
        if (index != 0) writer.writeByte(',') catch return error.SnapshotTooLarge;
        writer.writeAll("{\"name\":") catch return error.SnapshotTooLarge;
        try text.writeJson(writer, slot.name);
        writer.print(",\"status\":\"{s}\"}}", .{
            if (mcpSecretSlotReady(management, slot)) "set" else "missing",
        }) catch return error.SnapshotTooLarge;
    }
    writer.writeByte(']') catch return error.SnapshotTooLarge;
}

fn writeMcpConnection(
    writer: *std.Io.Writer,
    text: TextProjection,
    management: *const mcp_configuration.ManagementPort,
    server: mcp_configuration.ServerWire,
    connection_safe: bool,
    projected_auth_mode: []const u8,
) Error!void {
    if (!connection_safe) {
        writer.writeAll("null") catch return error.SnapshotTooLarge;
        return;
    }
    if (!std.mem.eql(u8, server.transport.kind, "streamable_http")) {
        writer.writeAll("{\"kind\":\"stdio\",\"command\":") catch
            return error.SnapshotTooLarge;
        try text.writeJson(writer, server.transport.command orelse "");
        writer.writeAll(",\"arguments\":[") catch return error.SnapshotTooLarge;
        for (server.transport.arguments, 0..) |argument, index| {
            if (index != 0) writer.writeByte(',') catch return error.SnapshotTooLarge;
            try text.writeJson(writer, argument.literal orelse "");
        }
        writer.writeAll("],\"cwd\":") catch return error.SnapshotTooLarge;
        if (server.transport.cwd) |cwd|
            try text.writeJson(writer, cwd)
        else
            writer.writeAll("null") catch return error.SnapshotTooLarge;
        writer.writeAll(",\"environment\":") catch return error.SnapshotTooLarge;
        try writeMcpSecretSlots(
            writer,
            text,
            management,
            server.transport.environment,
        );
        writer.writeByte('}') catch return error.SnapshotTooLarge;
        return;
    }
    writer.writeAll("{\"kind\":\"streamable_http\",\"endpoint\":") catch
        return error.SnapshotTooLarge;
    try text.writeJson(writer, server.transport.url orelse "");
    writer.writeAll(",\"headers\":") catch return error.SnapshotTooLarge;
    try writeMcpSecretSlots(writer, text, management, server.transport.headers);
    const oauth = if (std.mem.eql(u8, projected_auth_mode, "oauth"))
        server.auth.oauth
    else
        null;
    writer.print(",\"registrationKind\":\"{s}\",\"clientId\":", .{
        if (oauth) |value| if (std.mem.eql(u8, value.registration.kind, "dynamic_registration"))
            "automatic"
        else
            "pre_registered" else "none",
    }) catch return error.SnapshotTooLarge;
    if (oauth) |value| {
        if (std.mem.eql(u8, value.registration.kind, "pre_registered"))
            try text.writeJson(writer, value.registration.client_id orelse "")
        else
            writer.writeAll("null") catch return error.SnapshotTooLarge;
    } else writer.writeAll("null") catch return error.SnapshotTooLarge;
    writer.writeAll(",\"tokenEndpointAuthMethod\":") catch
        return error.SnapshotTooLarge;
    if (oauth) |value| if (value.registration.token_endpoint_auth_method) |method|
        try text.writeJson(writer, method)
    else
        writer.writeAll("null") catch return error.SnapshotTooLarge else writer.writeAll("null") catch return error.SnapshotTooLarge;
    writer.print(",\"clientSecretStatus\":\"{s}\"}}", .{
        if (oauth) |value| if (value.registration.token_endpoint_auth_method) |method|
            if (std.mem.eql(u8, method, "none"))
                "not_required"
            else if (value.registration.client_secret_ref) |locator|
                if (management.credentialPresence(locator) == .present) "set" else "missing"
            else
                "missing"
        else
            "not_required" else "not_required",
    }) catch return error.SnapshotTooLarge;
}

fn writeMcpAuthorizationOperation(
    writer: *std.Io.Writer,
    mcp: *const mcp_state.McpProductState,
    registry: ?mcp_configuration.RegistryWire,
) Error!void {
    if (mcp.authorization_operation) |operation| {
        writer.print("{{\"kind\":\"{s}\",\"serverId\":", .{@tagName(operation.phase)}) catch
            return error.SnapshotTooLarge;
        std.json.Stringify.value(operation.server_id, .{}, writer) catch
            return error.SnapshotTooLarge;
        writer.writeAll(",\"operationId\":") catch return error.SnapshotTooLarge;
        std.json.Stringify.value(operation.operation_id, .{}, writer) catch
            return error.SnapshotTooLarge;
        writer.writeByte('}') catch return error.SnapshotTooLarge;
        return;
    }
    if (registry) |desired| if (desired.oauth_operation) |operation| {
        const phase = if (std.mem.eql(u8, operation.kind, "refresh"))
            "refreshing"
        else if (std.mem.eql(u8, operation.kind, "dynamic_registration"))
            "registering"
        else
            "exchanging";
        writer.print("{{\"kind\":\"{s}\",\"serverId\":", .{phase}) catch
            return error.SnapshotTooLarge;
        std.json.Stringify.value(operation.server_id, .{}, writer) catch
            return error.SnapshotTooLarge;
        writer.writeAll(",\"operationId\":") catch return error.SnapshotTooLarge;
        std.json.Stringify.value(operation.id, .{}, writer) catch
            return error.SnapshotTooLarge;
        writer.writeByte('}') catch return error.SnapshotTooLarge;
        return;
    };
    writer.writeAll("{\"kind\":\"idle\"}") catch return error.SnapshotTooLarge;
}

fn writeMcpTool(
    writer: *std.Io.Writer,
    text: TextProjection,
    mcp: *const mcp_state.McpProductState,
    server: mcp_configuration.ServerWire,
    name: []const u8,
    discovered: bool,
) Error!void {
    writer.writeAll("{\"name\":") catch return error.SnapshotTooLarge;
    try text.writeJson(writer, name);
    writer.print(",\"discovered\":{},\"desiredAllowed\":{},\"availableToNewTasks\":{}}}", .{
        discovered,
        desiredAllowsTool(server, name),
        mcpToolSelectedForNewTask(mcp, server.id, name),
    }) catch return error.SnapshotTooLarge;
}

pub fn writeProjection(
    writer: *std.Io.Writer,
    input: Input,
) Error!void {
    const mcp = input.state orelse {
        writer.writeAll(unavailable_projection) catch
            return error.SnapshotTooLarge;
        return;
    };
    const management = if (mcp.management) |*value| value else {
        writer.writeAll(unavailable_projection) catch
            return error.SnapshotTooLarge;
        return;
    };
    const inspection = management.inspect();
    const trusted = inspection.health != .outcome_unknown and
        (inspection.desired_generation != null or inspection.health == .ready);
    const registry = if (trusted) management.desiredRegistry() else null;
    const projection_redacted = mcpProjectionRedacted(input.text, mcp, registry);
    writer.print("{{\"availability\":\"{s}\",\"managementHealth\":\"{s}\",\"operation\":\"{s}\",\"configurationApply\":\"{s}\",\"authorizationOperation\":", .{
        @tagName(mcpAvailability(mcp)),
        @tagName(inspection.health),
        if (trusted and !mcp.refresh_schedule_failed and (input.refresh_job_active or mcp.refresh_pending) and (mcp.refresh_visible or !mcp.admissionFresh())) "refreshing" else "idle",
        if (trusted) @tagName(mcp.configuration_apply_state) else "idle",
    }) catch return error.SnapshotTooLarge;
    if (trusted)
        try writeMcpAuthorizationOperation(writer, mcp, registry)
    else
        writer.writeAll("{\"kind\":\"idle\"}") catch return error.SnapshotTooLarge;
    writer.writeAll(",\"desiredGeneration\":") catch return error.SnapshotTooLarge;
    if (trusted) writer.print("\"{d}\"", .{inspection.desired_generation orelse 0}) catch
        return error.SnapshotTooLarge else writer.writeAll("null") catch return error.SnapshotTooLarge;
    writer.print(",\"runtimeAlignment\":\"{s}\",\"redacted\":{},\"servers\":[", .{
        if (trusted and !mcp.runtime_uncertain) @tagName(inspection.runtime_alignment) else "unknown",
        projection_redacted,
    }) catch return error.SnapshotTooLarge;
    const servers = if (registry) |value| value.servers else &.{};
    for (servers, 0..) |server, index| {
        if (index != 0) writer.writeByte(',') catch return error.SnapshotTooLarge;
        const status = mcpDesiredServerRuntimeStatus(mcp, server);
        const problem = mcp_configuration.serverProblem(server, management.limits);
        const connection_safe = !mcpConnectionContainsSensitiveText(input.text, server) and
            (problem == null or problem.? == .invalid_connection_approval);
        const projected_auth_mode = if (connection_safe and
            (std.mem.eql(u8, server.auth.kind, "none") or
                std.mem.eql(u8, server.auth.kind, "static") or
                (std.mem.eql(u8, server.auth.kind, "oauth") and
                    std.mem.eql(u8, server.transport.kind, "streamable_http"))))
            server.auth.kind
        else
            "none";
        writer.writeAll("{\"id\":") catch return error.SnapshotTooLarge;
        try input.text.writeJson(writer, server.id);
        writer.writeAll(",\"displayName\":") catch return error.SnapshotTooLarge;
        try input.text.writeJson(
            writer,
            if (mcp_configuration.publishableProductText(server.display_name))
                server.display_name
            else
                server.id,
        );
        writer.writeAll(",\"namespace\":") catch return error.SnapshotTooLarge;
        try input.text.writeJson(writer, server.namespace);
        writer.print(",\"transport\":\"{s}\",\"authMode\":\"{s}\",\"negotiation\":\"{s}\",\"timeoutMs\":{d},\"connection\":", .{
            if (std.mem.eql(u8, server.transport.kind, "streamable_http"))
                "streamable_http"
            else
                "stdio",
            projected_auth_mode,
            if (connection_safe) server.negotiation else "automatic",
            if (connection_safe) server.timeout_ms else 1,
        }) catch return error.SnapshotTooLarge;
        try writeMcpConnection(
            writer,
            input.text,
            management,
            server,
            connection_safe,
            projected_auth_mode,
        );
        writer.print(",\"approvalStatus\":\"{s}\",\"authorizationStatus\":\"{s}\",\"canAuthorize\":{},\"desiredEnabled\":{},\"runtimeStatus\":\"{s}\",\"newTaskAccess\":\"{s}\",\"safeDiagnostic\":", .{
            if (!connection_safe or server.connection_approval == null)
                "unapproved"
            else
                "approved",
            if (connection_safe)
                mcpAuthorizationStatus(mcp, management, server)
            else
                "not_required",
            connection_safe and policy.canAuthorizeServer(mcp, input.refresh_job_active, server),
            server.enabled,
            @tagName(status),
            mcpNewTaskAccess(mcp, server.id),
        }) catch return error.SnapshotTooLarge;
        try input.text.writeJson(writer, if (mcp.runtime_uncertain)
            "Runtime configuration outcome is unknown. Restart the application."
        else if (serverApplyStatus(mcp, server) == .waiting_auth)
            "Authorization recovery is pending. The connection will retry automatically."
        else if (serverCapacityBlocked(mcp, server))
            "MCP connection capacity is full. Close unused tasks, then retry the connection."
        else if (status != .ready and status != .disabled and status != .needs_authentication and processDiagnostic(mcp, server) != null)
            processDiagnostic(mcp, server).?
        else if (mcp.refresh_schedule_failed)
            "Automatic refresh could not be scheduled. Select Refresh to retry."
        else if (mcp.refresh_paused)
            "Tool catalog refresh paused after repeated failures. Select Refresh to retry."
        else if (mcp.admission == .ready and !mcp.admissionFresh())
            "Tool catalog expired"
        else switch (status) {
            .not_loaded => if (serverApplyStatus(mcp, server) == .failed or serverApplyStatus(mcp, server) == .rejected)
                "Configuration changes were not applied. Retry the connection."
            else if (mcp.activation_failed)
                "Tool catalog is unavailable. Select Refresh to retry."
            else
                "No current tool catalog observation",
            .ready, .disabled => "",
            .needs_authentication => "Credential is unavailable",
            .@"unreachable" => "Server is unavailable",
            .invalid_catalog => "Configuration or catalog is invalid",
        });
        const connection_test = if (mcp.connection_test) |test_state|
            if (std.mem.eql(u8, test_state.serverId(), server.id)) test_state else null
        else
            null;
        if (connection_test) |test_state|
            writer.print(",\"connectionTest\":{{\"status\":\"{s}\",\"toolCount\":{d},\"issueCount\":{d}}}", .{
                @tagName(test_state.state),
                test_state.tool_count,
                test_state.issue_count,
            }) catch return error.SnapshotTooLarge
        else
            writer.writeAll(",\"connectionTest\":{\"status\":\"untested\",\"toolCount\":0,\"issueCount\":0}") catch
                return error.SnapshotTooLarge;
        writer.writeAll(",\"tools\":[") catch return error.SnapshotTooLarge;
        var tool_count: usize = 0;
        const activation_index = activationServerIndex(mcp, server);
        for (server.tools, 0..) |tool, desired_index| {
            if (!mcp_configuration.publishableProductText(tool) or
                mcpToolAlreadyPublished(server.tools, desired_index)) continue;
            if (tool_count != 0) writer.writeByte(',') catch return error.SnapshotTooLarge;
            tool_count += 1;
            var discovered = false;
            if (mcp.activation) |activation| if (activation_index) |activation_index_value| {
                const bound = activation.serverHealth()[activation_index_value];
                for (activation.catalogTools()) |catalog_tool|
                    if (std.mem.eql(u8, &catalog_tool.binding_identity, &bound.binding_identity) and
                        std.mem.eql(u8, catalog_tool.name, tool))
                    {
                        discovered = true;
                        break;
                    };
            };
            try writeMcpTool(writer, input.text, mcp, server, tool, discovered);
        }
        if (mcp.activation) |activation| if (activation_index) |activation_index_value| {
            const bound = activation.serverHealth()[activation_index_value];
            for (activation.catalogTools()) |tool| {
                if (!std.mem.eql(u8, &tool.binding_identity, &bound.binding_identity) or
                    !mcp_configuration.publishableProductText(tool.name) or
                    desiredAllowsTool(server, tool.name)) continue;
                if (tool_count != 0) writer.writeByte(',') catch return error.SnapshotTooLarge;
                tool_count += 1;
                try writeMcpTool(writer, input.text, mcp, server, tool.name, true);
            }
        };
        writer.print("],\"taskReferenceCount\":{d},\"applyStatus\":\"{s}\"}}", .{ taskReferenceCount(mcp, server.id), @tagName(serverApplyStatus(mcp, server)) }) catch return error.SnapshotTooLarge;
    }
    writer.print("],\"retainedMemberCount\":{d},\"applyFailureCount\":{d},\"runtimeUncertain\":{},\"runtimeTimeoutLimitMs\":{d}}}", .{ if (trusted) retainedMemberCount(mcp) else 0, if (trusted) applyFailureCount(mcp) else 0, trusted and mcp.runtime_uncertain, mcp_configuration.max_management_timeout_ms }) catch return error.SnapshotTooLarge;
}

const unavailable_projection =
    "{\"availability\":\"unavailable\",\"managementHealth\":\"unavailable\",\"operation\":\"idle\",\"configurationApply\":\"idle\",\"authorizationOperation\":{\"kind\":\"idle\"},\"desiredGeneration\":null,\"runtimeAlignment\":\"unknown\",\"redacted\":false,\"servers\":[],\"retainedMemberCount\":0,\"applyFailureCount\":0,\"runtimeUncertain\":false,\"runtimeTimeoutLimitMs\":" ++ std.fmt.comptimePrint("{d}", .{mcp_configuration.max_management_timeout_ms}) ++ "}";

test "Product MCP View preserves the unavailable snapshot bytes" {
    const Text = struct {
        fn contains(_: *const anyopaque, _: []const u8) bool {
            @panic("unavailable projection must not inspect text");
        }

        fn write(_: *const anyopaque, _: *std.Io.Writer, _: []const u8) Error!void {
            @panic("unavailable projection must not write projected text");
        }
    };

    var context: u8 = 0;
    var storage: [unavailable_projection.len]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try writeProjection(&writer, .{
        .state = null,
        .refresh_job_active = false,
        .text = .{
            .context = &context,
            .contains_sensitive_fn = Text.contains,
            .write_json_fn = Text.write,
        },
    });
    try std.testing.expectEqualStrings(unavailable_projection, writer.buffered());
}

test "untrusted Desired hides live operation fields without losing recovery state" {
    const Text = struct {
        fn contains(_: *const anyopaque, _: []const u8) bool {
            return false;
        }
        fn write(_: *const anyopaque, writer: *std.Io.Writer, value: []const u8) Error!void {
            std.json.Stringify.value(value, .{}, writer) catch return error.SnapshotTooLarge;
        }
    };
    const allocator = std.testing.allocator;
    const expected = try std.json.parseFromSlice(std.json.Value, allocator, @embedFile("testdata/untrusted-view.json"), .{});
    defer expected.deinit();
    var context: u8 = 0;
    for ([_]mcp_configuration.StoreHealth{ .outcome_unknown, .recovery_required }) |health| {
        const management = try mcp_configuration.ManagementPort.init(allocator, null, .{
            .persistence = .{ .available = true },
            .credentials = .{ .available = true },
            .initial_health = health,
            .limits = .{ .max_servers = 1, .max_tools_per_server = 1, .max_namespace_bytes = 128, .max_credential_locators = 4, .max_runtime_secrets_per_server = 4, .max_runtime_secret_bytes_per_server = 4096 },
        });
        var state: mcp_state.McpProductState = .{
            .preparation = .{ .allocator = allocator, .state = .empty },
            .activation = null,
            .activation_failed = true,
            .management = management,
            .admission = .{ .blocked = .persistence_outcome_unknown },
            .host_capabilities = .{},
            .configuration_apply_state = .applying,
            .refresh_pending = true,
            .refresh_visible = true,
            .authorization_operation = .{ .phase = .discovering, .server_id = try allocator.dupe(u8, "recovery-server"), .operation_id = try allocator.dupe(u8, "recovery-operation") },
        };
        defer state.deinit();
        var buffer: [2048]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        try writeProjection(&writer, .{ .state = &state, .refresh_job_active = true, .text = .{ .context = &context, .contains_sensitive_fn = Text.contains, .write_json_fn = Text.write } });
        const key = if (health == .outcome_unknown) "outcome_unknown" else "missing_desired";
        const bytes = try std.json.Stringify.valueAlloc(allocator, expected.value.object.get(key).?, .{});
        defer allocator.free(bytes);
        try std.testing.expectEqualStrings(bytes, writer.buffered());
        try std.testing.expect(state.refresh_pending);
        try std.testing.expectEqual(.applying, state.configuration_apply_state);
        try std.testing.expectEqualStrings("recovery-operation", state.authorization_operation.?.operation_id);
    }
}

test "Product MCP View filters duplicate desired tools" {
    const tools = [_][]const u8{ "read", "write", "read" };
    try std.testing.expect(!mcpToolAlreadyPublished(&tools, 0));
    try std.testing.expect(!mcpToolAlreadyPublished(&tools, 1));
    try std.testing.expect(mcpToolAlreadyPublished(&tools, 2));
}

test "Product MCP View requires an official server observation before reporting unreachable" {
    var current: mcp_state.McpProductState = .{
        .preparation = .{ .allocator = std.testing.allocator, .state = .empty },
        .activation = null,
        .activation_failed = false,
        .management = null,
        .admission = .{ .blocked = .activation_unavailable },
        .host_capabilities = .{},
        .committed = true,
    };
    try std.testing.expectEqual(.not_loaded, mcpRuntimeServerStatus(&current, "server", .eligible));
    current.activation_failed = true;
    try std.testing.expectEqual(.not_loaded, mcpRuntimeServerStatus(&current, "server", .eligible));
    try std.testing.expectEqual(.unavailable, mcpAvailability(&current));
    try std.testing.expectEqual(.needs_authentication, mcpRuntimeServerStatus(&current, "server", .unapproved));
}

test "Product MCP View binds observations to connection provenance but not display name or allowlist" {
    const original: mcp_configuration.ServerWire = .{
        .id = "server",
        .namespace = "namespace",
        .display_name = "Original",
        .enabled = true,
        .negotiation = "automatic",
        .timeout_ms = 1000,
        .transport = .{ .kind = "streamable_http", .url = "https://first.example.test/mcp" },
        .auth = .{ .kind = "none", .oauth = null },
        .connection_approval = null,
        .tools = &.{"echo"},
    };
    var changed = original;
    changed.display_name = "Renamed";
    changed.tools = &.{ "echo", "extra" };
    try std.testing.expect(sameRuntimeDescriptor(original, changed));
    changed.transport.url = "https://second.example.test/mcp";
    try std.testing.expect(!sameRuntimeDescriptor(original, changed));
    changed = original;
    changed.namespace = "different";
    try std.testing.expect(!sameRuntimeDescriptor(original, changed));
    changed = original;
    var first_arguments = [_]mcp_configuration.ValueSourceWire{.{ .literal = "first" }};
    var second_arguments = [_]mcp_configuration.ValueSourceWire{.{ .literal = "second" }};
    changed.transport = .{ .kind = "stdio", .command = "/bin/original", .arguments = &first_arguments };
    const stdio = changed;
    changed.transport.arguments = &second_arguments;
    try std.testing.expect(!sameRuntimeDescriptor(stdio, changed));
    changed = stdio;
    changed.transport.command = "/bin/replaced";
    try std.testing.expect(!sameRuntimeDescriptor(stdio, changed));
    changed = stdio;
    changed.transport.cwd = "/different";
    try std.testing.expect(!sameRuntimeDescriptor(stdio, changed));
}
