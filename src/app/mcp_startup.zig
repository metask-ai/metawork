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
    var restored_bytes = configuration_store.loadAlloc(std.heap.c_allocator) catch |err| switch (err) {
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
    var source_schema_version: ?u8 = null;
    const generation: u64 = if (restored_bytes) |bytes| generation: {
        source_schema_version = workbench_api.mcpRegistrySourceSchemaVersion(
            std.heap.c_allocator,
            bytes,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                registry_corrupt = true;
                break :generation 0;
            },
        };
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
    if (!recovery_failed and restored_bytes != null and source_schema_version == 1) {
        var migrated = workbench_api.decodeMcpRegistry(
            std.heap.c_allocator,
            restored_bytes.?,
            configuration_limits,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => unreachable,
        };
        defer migrated.deinit();
        const buffer = try std.heap.c_allocator.alloc(
            u8,
            workbench_api.mcp_registry_max_bytes,
        );
        defer std.heap.c_allocator.free(buffer);
        const migrated_bytes = workbench_api.encodeMcpRegistry(
            buffer,
            migrated.value,
            configuration_limits,
        ) catch unreachable;
        configuration_store.commit(migrated_bytes) catch |err| {
            management_health = if (err == error.PersistenceOutcomeUnknown)
                .outcome_unknown
            else
                .recovery_required;
        };
        try replaceRestoredBytes(&restored_bytes, migrated_bytes);
    }
    if (!recovery_failed and restored_bytes != null) {
        var current = workbench_api.decodeMcpRegistry(
            std.heap.c_allocator,
            restored_bytes.?,
            configuration_limits,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => unreachable,
        };
        defer current.deinit();
        if (current.value.oauth_operation != null) {
            var plan = try workbench_api.planMcpOauthOperationRecovery(
                std.heap.c_allocator,
                current.value,
                configuration_limits,
            );
            defer plan.deinit();
            var coordinator: workbench_api.McpTransactionCoordinator = .{};
            const commit = try coordinator.commit(
                std.heap.c_allocator,
                configuration_store.mutationPersistence(),
                credential_store.effects(),
                &plan,
                &.{},
                configuration_limits,
            );
            switch (commit) {
                .saved, .saved_recovery_required => {
                    const buffer = try std.heap.c_allocator.alloc(
                        u8,
                        workbench_api.mcp_registry_max_bytes,
                    );
                    defer std.heap.c_allocator.free(buffer);
                    const recovered_bytes = workbench_api.encodeMcpRegistry(
                        buffer,
                        try plan.targetRegistry(),
                        configuration_limits,
                    ) catch unreachable;
                    try replaceRestoredBytes(&restored_bytes, recovered_bytes);
                    if (commit == .saved_recovery_required)
                        management_health = coordinator.health;
                },
                .registry_outcome_unknown => {
                    recovery_failed = true;
                    management_health = .outcome_unknown;
                },
                .not_saved, .not_saved_recovery_required, .blocked => {
                    management_health = if (coordinator.health == .outcome_unknown)
                        .outcome_unknown
                    else
                        .recovery_required;
                },
            }
        }
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

fn replaceRestoredBytes(slot: *?[]u8, bytes: []const u8) std.mem.Allocator.Error!void {
    const replacement = try std.heap.c_allocator.dupe(u8, bytes);
    if (slot.*) |previous| std.heap.c_allocator.free(previous);
    slot.* = replacement;
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
