const std = @import("std");
const native_sdk = @import("native_sdk");
const agent = @import("metawork_agent");
const workbench_api = @import("metawork_workbench");
const mcp_platform = @import("metawork_mcp_platform");

const runtime_limits: agent.McpRuntimeLimits = .{};

pub const configuration_limits: workbench_api.McpConfigurationLimits = .{
    .max_servers = 64,
    .max_tools_per_server = 1024,
    .max_namespace_bytes = 24,
    .max_credential_locators = 4096,
    .max_credential_secret_bytes = native_sdk.platform.max_credential_secret_bytes,
    .max_runtime_secrets_per_server = runtime_limits.max_secrets,
    .max_runtime_secret_bytes_per_server = runtime_limits.max_secret_bytes,
};

pub const Preparation = struct {
    preparation: workbench_api.McpPreparedConfiguration,
    management_health: workbench_api.McpStoreHealth,
};

pub fn prepare(
    store: ?*workbench_api.McpConfigurationFileStore,
    credential_store_optional: ?*mcp_platform.CredentialStore,
) !Preparation {
    const configuration_store = store orelse
        return .{
            .preparation = try workbench_api.prepareMcpConfiguration(
                std.heap.c_allocator,
                null,
                false,
                false,
                .{},
                configuration_limits,
            ),
            .management_health = .recovery_required,
        };
    const restored_bytes = configuration_store.loadAlloc(std.heap.c_allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{
            .preparation = try workbench_api.prepareMcpConfiguration(
                std.heap.c_allocator,
                null,
                true,
                true,
                .{},
                configuration_limits,
            ),
            .management_health = .recovery_required,
        },
    };
    defer if (restored_bytes) |bytes| std.heap.c_allocator.free(bytes);
    var registry_corrupt = false;
    const generation: u64 = if (restored_bytes) |bytes| generation: {
        var decoded = workbench_api.decodeMcpRegistry(
            std.heap.c_allocator,
            bytes,
            configuration_limits,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                registry_corrupt = true;
                break :generation 0;
            },
        };
        defer decoded.deinit();
        break :generation decoded.value.generation;
    } else 0;
    const credential_store = if (credential_store_optional) |value| value else return error.RuntimeUnavailable;
    var recovery_failed = registry_corrupt;
    var management_health: workbench_api.McpStoreHealth =
        if (registry_corrupt) .recovery_required else .ready;
    if (!registry_corrupt) {
        _ = configuration_store.recoverPendingCredentialTransaction(
            std.heap.c_allocator,
            generation,
            credential_store.cleanup(),
            configuration_limits,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.PersistenceOutcomeUnknown => {
                recovery_failed = true;
                management_health = .outcome_unknown;
            },
            else => {
                recovery_failed = true;
                management_health = .recovery_required;
            },
        };
    }
    const preparation = try workbench_api.prepareMcpConfiguration(
        std.heap.c_allocator,
        restored_bytes,
        true,
        recovery_failed,
        credential_store.resolver(),
        configuration_limits,
    );
    return .{
        .preparation = preparation,
        .management_health = managementHealthAfterPreparation(
            preparation.state,
            management_health,
        ),
    };
}

fn managementHealthAfterPreparation(
    state: workbench_api.McpPreparationState,
    recovery_health: workbench_api.McpStoreHealth,
) workbench_api.McpStoreHealth {
    return switch (state) {
        .empty, .available => recovery_health,
        .unavailable => if (recovery_health == .outcome_unknown)
            .outcome_unknown
        else
            .recovery_required,
    };
}

test "MCP startup keeps registry limits within AgentCore authority bounds" {
    try std.testing.expectEqual(@as(usize, 64), configuration_limits.max_servers);
    try std.testing.expectEqual(@as(usize, 1024), configuration_limits.max_tools_per_server);
    try std.testing.expectEqual(@as(usize, 24), configuration_limits.max_namespace_bytes);
    try std.testing.expectEqual(
        workbench_api.McpStoreHealth.recovery_required,
        managementHealthAfterPreparation(
            .{ .unavailable = .credential_store_unavailable },
            .ready,
        ),
    );
    try std.testing.expectEqual(
        workbench_api.McpStoreHealth.outcome_unknown,
        managementHealthAfterPreparation(
            .{ .unavailable = .read_failed },
            .outcome_unknown,
        ),
    );
}
