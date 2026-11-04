//! Narrow adapter from the Renderer Bridge MCP management port to the
//! Application-owned management coordinator. It translates only typed
//! outcomes and secret slot identities; no platform authority crosses it.

const bridge_api = @import("metawork_bridge");
const mcp_contract = @import("metawork_product_mcp").contract;
const mcp_management_coordinator = @import("mcp_management_coordinator.zig");

pub fn host(coordinator: *mcp_management_coordinator.Coordinator) bridge_api.McpManagementHost {
    return .{
        .context = coordinator,
        .test_fn = testConnection,
        .begin_approval_fn = beginApproval,
        .cancel_approval_fn = cancelApproval,
        .map_approval_fn = mapApproval,
        .capture_fn = captureSecret,
        .authorize_fn = authorizeOauth,
        .cancel_fn = cancelAuthorization,
        .apply_fn = applyConfiguration,
    };
}

fn applyConfiguration(
    context: *anyopaque,
    intent: mcp_contract.RuntimeApplyIntent,
) anyerror!bridge_api.McpConfigurationApplyStartOutcome {
    const coordinator: *mcp_management_coordinator.Coordinator = @ptrCast(@alignCast(context));
    return switch (try coordinator.applyConfiguration(intent)) {
        .started => .started,
        .busy => .busy,
        .rejected => .rejected,
        .unavailable => .unavailable,
    };
}

fn testConnection(
    context: *anyopaque,
    expected_generation: u64,
    server_id: []const u8,
) anyerror!bridge_api.McpConnectionTestStartOutcome {
    const coordinator: *mcp_management_coordinator.Coordinator = @ptrCast(@alignCast(context));
    return switch (try coordinator.testConnection(expected_generation, server_id)) {
        inline else => |result| @field(
            bridge_api.McpConnectionTestStartOutcome,
            @tagName(result),
        ),
    };
}

fn outcome(value: mcp_management_coordinator.Outcome) bridge_api.McpHostOutcome {
    return switch (value) {
        inline else => |result| @field(bridge_api.McpHostOutcome, @tagName(result)),
    };
}

fn beginApproval(context: *anyopaque, operation: u64, expected: u64, server: []const u8, completion: *const bridge_api.McpApproval.Completion) !bridge_api.McpApproval.Start {
    const coordinator: *mcp_management_coordinator.Coordinator = @ptrCast(@alignCast(context));
    return coordinator.beginApproval(operation, expected, server, completion);
}
fn cancelApproval(context: *anyopaque, handle: u64) void {
    const coordinator: *mcp_management_coordinator.Coordinator = @ptrCast(@alignCast(context));
    coordinator.cancelApproval(handle);
}
fn mapApproval(_: *anyopaque, value: @import("metawork_product_mcp").contract.ManagementOutcome) bridge_api.McpHostOutcome {
    return outcome(mcp_management_coordinator.mapManagementOutcome(value));
}

fn captureSecret(
    context: *anyopaque,
    expected_generation: u64,
    server_id: []const u8,
    slot: bridge_api.McpSecretSlot,
    secret: []const u8,
) anyerror!bridge_api.McpHostOutcome {
    const coordinator: *mcp_management_coordinator.Coordinator = @ptrCast(@alignCast(context));
    const target: mcp_management_coordinator.SecretSlot = switch (slot) {
        .stdio_environment => |name| .{ .stdio_environment = name },
        .http_header => |name| .{ .http_header = name },
        .oauth_client_secret => .oauth_client_secret,
    };
    return outcome(try coordinator.captureSecret(expected_generation, server_id, target, secret));
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
