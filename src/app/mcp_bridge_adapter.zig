//! Narrow adapter from the Renderer Bridge MCP management port to the
//! Application-owned management coordinator. It translates only typed
//! outcomes and secret slot identities; no platform authority crosses it.

const bridge_api = @import("metawork_bridge");
const mcp_management_coordinator = @import("mcp_management_coordinator.zig");

pub fn host(coordinator: *mcp_management_coordinator.Coordinator) bridge_api.McpManagementHost {
    return .{
        .context = coordinator,
        .approve_fn = approveConnection,
        .capture_fn = captureSecret,
        .authorize_fn = authorizeOauth,
        .cancel_fn = cancelAuthorization,
    };
}

fn outcome(value: mcp_management_coordinator.Outcome) bridge_api.McpHostOutcome {
    return switch (value) {
        inline else => |result| @field(bridge_api.McpHostOutcome, @tagName(result)),
    };
}

fn approveConnection(
    context: *anyopaque,
    expected_generation: u64,
    server_id: []const u8,
) anyerror!bridge_api.McpHostOutcome {
    const coordinator: *mcp_management_coordinator.Coordinator = @ptrCast(@alignCast(context));
    return outcome(try coordinator.approveConnection(expected_generation, server_id));
}

fn captureSecret(
    context: *anyopaque,
    expected_generation: u64,
    server_id: []const u8,
    slot: bridge_api.McpSecretSlot,
) anyerror!bridge_api.McpHostOutcome {
    const coordinator: *mcp_management_coordinator.Coordinator = @ptrCast(@alignCast(context));
    const target: mcp_management_coordinator.SecretSlot = switch (slot) {
        .stdio_environment => |name| .{ .stdio_environment = name },
        .http_header => |name| .{ .http_header = name },
        .oauth_client_secret => .oauth_client_secret,
    };
    return outcome(try coordinator.captureSecret(expected_generation, server_id, target));
}

fn authorizeOauth(
    context: *anyopaque,
    expected_generation: u64,
    server_id: []const u8,
) anyerror!bridge_api.McpAuthorizationStartOutcome {
    const coordinator: *mcp_management_coordinator.Coordinator = @ptrCast(@alignCast(context));
    return switch (try coordinator.authorizeOauth(expected_generation, server_id)) {
        .started => |operation_id| .{ .started = operation_id },
        .rejected => .rejected,
        .stale_generation => .stale_generation,
        .capability_unavailable => .capability_unavailable,
    };
}

fn cancelAuthorization(
    context: *anyopaque,
    operation_id: []const u8,
) bridge_api.McpHostOutcome {
    const coordinator: *mcp_management_coordinator.Coordinator = @ptrCast(@alignCast(context));
    return outcome(coordinator.cancelAuthorization(operation_id));
}
