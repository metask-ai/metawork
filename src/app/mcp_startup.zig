const std = @import("std");
const native_sdk = @import("native_sdk");
const agent = @import("metawork_agent");
const mcp_configuration = @import("metawork_product_mcp").contract;
const mcp_platform = @import("metawork_mcp_platform");

const runtime_limits: agent.McpRuntimeLimits = .{};

pub const configuration_limits: mcp_configuration.Limits = .{
    .max_servers = 64,
    .max_tools_per_server = 1024,
    .max_namespace_bytes = 24,
    .max_credential_locators = 4096,
    .max_credential_secret_bytes = native_sdk.platform.max_credential_secret_bytes,
    .max_runtime_secrets_per_server = runtime_limits.max_secrets,
    .max_runtime_secret_bytes_per_server = runtime_limits.max_secret_bytes,
};

pub const Preparation = struct {
    preparation: mcp_configuration.Preparation,
    management_health: mcp_configuration.StoreHealth,
};

/// Builds the exact in-memory proof for the canonical Runtime created without
/// MCP descriptors. Desired registry state is restored separately and may
/// immediately make this manifest report `restart_required` until the normal
/// declarative configuration-apply transaction completes.
pub fn emptyRuntimeManifest(
    allocator: std.mem.Allocator,
) std.mem.Allocator.Error!mcp_configuration.RuntimeManifest {
    var preparation = try mcp_configuration.prepare(
        allocator,
        null,
        true,
        false,
        .{},
        configuration_limits,
    );
    defer preparation.deinit();
    return (try mcp_configuration.RuntimeManifest.candidate(
        allocator,
        &preparation,
    )).?;
}

pub fn prepare(
    store: ?*mcp_configuration.FileStore,
    credential_store_optional: ?*mcp_platform.CredentialStore,
) !Preparation {
    const configuration_store = store orelse
        return .{
            .preparation = try mcp_configuration.prepare(
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
            .preparation = try mcp_configuration.prepare(
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
    var restored_registry: ?std.json.Parsed(mcp_configuration.RegistryWire) = if (restored_bytes) |bytes| registry: {
        source_schema_version = mcp_configuration.registrySourceSchemaVersion(
            std.heap.c_allocator,
            bytes,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                registry_corrupt = true;
                break :registry null;
            },
        };
        const decoded = mcp_configuration.decode(
            std.heap.c_allocator,
            bytes,
            configuration_limits,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                registry_corrupt = true;
                break :registry null;
            },
        };
        break :registry decoded;
    } else null;
    defer if (restored_registry) |*registry| registry.deinit();
    const credential_store = if (credential_store_optional) |value| value else return error.RuntimeUnavailable;
    var recovery_failed = registry_corrupt;
    var management_health: mcp_configuration.StoreHealth =
        if (registry_corrupt) .recovery_required else .ready;
    if (!registry_corrupt) {
        _ = configuration_store.recoverPendingCredentialTransaction(
            std.heap.c_allocator,
            if (restored_registry) |registry| registry.value else null,
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
        var migrated = mcp_configuration.decode(
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
            mcp_configuration.max_store_bytes,
        );
        defer std.heap.c_allocator.free(buffer);
        const migrated_bytes = mcp_configuration.encode(
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
        var current = mcp_configuration.decode(
            std.heap.c_allocator,
            restored_bytes.?,
            configuration_limits,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => unreachable,
        };
        defer current.deinit();
        if (current.value.oauth_operation != null) {
            var plan = try mcp_configuration.planOauthOperationRecovery(
                std.heap.c_allocator,
                current.value,
                configuration_limits,
            );
            defer plan.deinit();
            var coordinator: mcp_configuration.TransactionCoordinator = .{};
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
                        mcp_configuration.max_store_bytes,
                    );
                    defer std.heap.c_allocator.free(buffer);
                    const recovered_bytes = mcp_configuration.encode(
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
    const preparation = try mcp_configuration.prepare(
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
    state: mcp_configuration.PreparationState,
    recovery_health: mcp_configuration.StoreHealth,
) mcp_configuration.StoreHealth {
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
        mcp_configuration.StoreHealth.recovery_required,
        managementHealthAfterPreparation(
            .{ .unavailable = .credential_store_unavailable },
            .ready,
        ),
    );
    try std.testing.expectEqual(
        mcp_configuration.StoreHealth.outcome_unknown,
        managementHealthAfterPreparation(
            .{ .unavailable = .read_failed },
            .outcome_unknown,
        ),
    );

    var manifest = try emptyRuntimeManifest(std.testing.allocator);
    defer manifest.deinit();
    try std.testing.expectEqual(@as(usize, 0), manifest.entries.len);
}
