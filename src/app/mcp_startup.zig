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
    var empty_storage: [256]u8 = undefined;
    const empty_registry = mcp_configuration.encode(&empty_storage, .{
        .schema_version = mcp_configuration.schema_version,
        .generation = 1,
        .oauth_operation = null,
        .servers = &.{},
    }, configuration_limits) catch unreachable;
    _ = configuration_store.resumeQuarantine(std.heap.c_allocator, empty_registry) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return quarantineFailure(err),
    };
    var diagnostic: mcp_configuration.RecoveryDiagnostic = if (configuration_store.hasQuarantine() catch
        return unavailable(.read_failed, .recovery_required, .read_failed))
        .quarantined_credentials_retained
    else
        .none;
    var restored_bytes = configuration_store.loadAlloc(std.heap.c_allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return unavailable(.read_failed, .recovery_required, .read_failed),
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
    if (registry_corrupt) {
        if (source_schema_version) |version| {
            if (version != 1 and version != mcp_configuration.schema_version)
                return unavailable(.corrupt, .recovery_required, .unrecognized_format);
        }
        configuration_store.quarantine(std.heap.c_allocator, .registry, empty_registry) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return quarantineFailure(err),
        };
        try replaceRestoredBytes(&restored_bytes, empty_registry);
        restored_registry = try mcp_configuration.decode(std.heap.c_allocator, restored_bytes.?, configuration_limits);
        source_schema_version = mcp_configuration.schema_version;
        diagnostic = .quarantined_credentials_retained;
    }
    const credential_store = if (credential_store_optional) |value| value else return error.RuntimeUnavailable;
    var recovery_failed = false;
    var management_health: mcp_configuration.StoreHealth = .ready;
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
            diagnostic = .journal_recovery_failed;
        },
        error.TransactionCorrupt, error.TransactionGenerationMismatch, error.TransactionRegistryMismatch => {
            const isolated = quarantineJournal(configuration_store, empty_registry) catch |quarantine_err| switch (quarantine_err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return quarantineFailure(quarantine_err),
            };
            if (isolated) {
                diagnostic = .quarantined_credentials_retained;
            } else {
                recovery_failed = true;
                management_health = .recovery_required;
                diagnostic = .unrecognized_format;
            }
        },
        else => {
            recovery_failed = true;
            management_health = .recovery_required;
            diagnostic = .journal_recovery_failed;
        },
    };
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
    var preparation = try mcp_configuration.prepare(
        std.heap.c_allocator,
        restored_bytes,
        true,
        recovery_failed,
        credential_store.resolver(),
        configuration_limits,
    );
    preparation.recovery_diagnostic = diagnostic;
    return .{
        .preparation = preparation,
        .management_health = managementHealthAfterPreparation(
            preparation.state,
            management_health,
        ),
    };
}

fn quarantineJournal(store: *mcp_configuration.FileStore, empty_registry: []const u8) !bool {
    const bytes = (try store.loadTransactionAlloc(std.heap.c_allocator)) orelse return false;
    defer std.heap.c_allocator.free(bytes);
    const version = mcp_configuration.registrySourceSchemaVersion(std.heap.c_allocator, bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };
    if (version) |value| if (value != mcp_configuration.transaction_schema_version) return false;
    try store.quarantine(std.heap.c_allocator, .journal, empty_registry);
    return true;
}

fn unavailable(reason: mcp_configuration.UnavailableReason, health: mcp_configuration.StoreHealth, diagnostic: mcp_configuration.RecoveryDiagnostic) Preparation {
    return .{
        .preparation = .{ .allocator = std.heap.c_allocator, .state = .{ .unavailable = reason }, .recovery_diagnostic = diagnostic },
        .management_health = health,
    };
}

fn quarantineFailure(err: mcp_configuration.FileStoreError) Preparation {
    return unavailable(if (err == error.ReadFailed) .read_failed else .corrupt, if (err == error.PersistenceOutcomeUnknown) .outcome_unknown else .recovery_required, if (err == error.PersistenceOutcomeUnknown) .quarantine_outcome_unknown else .quarantine_failed);
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

test "MCP startup classifies registry and journal together without deleting quarantined credentials" {
    const Probe = struct {
        var deletions: usize = 0;
        fn remove(_: ?*anyopaque, _: native_sdk.platform.CredentialKey) anyerror!void {
            deletions += 1;
            return error.UnexpectedDeletion;
        }
    };
    const current = "{\"schema_version\":2, \"generation\":4, \"oauth_operation\":null, \"servers\":[]}";
    const journal = "{\"schema_version\":1,\"base_generation\":0,\"target_generation\":1,\"candidate_locators\":[\"orphan\"],\"retired_locators\":[]}";
    const Case = struct {
        registry: ?[]const u8,
        transaction: []const u8,
        generation: ?u64,
        ready: bool = true,
        isolated: bool = true,
        diagnostic: mcp_configuration.RecoveryDiagnostic = .quarantined_credentials_retained,
    };
    for ([_]Case{
        .{ .registry = "{broken\r\n", .transaction = journal, .generation = 1 },
        .{ .registry = "", .transaction = journal, .generation = 1 },
        .{ .registry = current, .transaction = "{broken-journal\r\n", .generation = 4 },
        .{ .registry = current, .transaction = journal, .generation = 4 },
        .{ .registry = null, .transaction = "{\"schema_version\":1,\"base_generation\":5,\"target_generation\":6,\"candidate_locators\":[\"orphan\"],\"retired_locators\":[]}", .generation = null },
        .{ .registry = "{\"schema_version\":3,\"generation\":4,\"servers\":[]}", .transaction = journal, .generation = null, .ready = false, .isolated = false, .diagnostic = .unrecognized_format },
        .{ .registry = current, .transaction = "{\"schema_version\":2}", .generation = null, .ready = false, .isolated = false, .diagnostic = .unrecognized_format },
    }) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const lock = try tmp.dir.createFile(std.testing.io, "fixture.lock", .{ .read = true, .truncate = false });
        defer lock.close(std.testing.io);
        var store: mcp_configuration.FileStore = .{ .io = std.testing.io, .dir = tmp.dir, .lock_file = lock, .quarantine_move = mcp_platform.quarantineMove() };
        if (case.registry) |bytes| {
            if (bytes.len == 0) {
                const file = try tmp.dir.createFile(std.testing.io, mcp_configuration.file_name, .{});
                file.close(std.testing.io);
            } else try store.commit(bytes);
        }
        try store.commitTransaction(case.transaction);
        const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
        defer harness.destroy(std.testing.allocator);
        var credentials: mcp_platform.CredentialStore = .{ .io = std.testing.io, .runtime = &harness.runtime, .main_thread_id = std.Thread.getCurrentId() };
        const effects = credentials.effects();
        try std.testing.expect(effects.create_fn(effects.context, "orphan", "preserved-secret-fixture"));
        Probe.deletions = 0;
        harness.runtime.options.platform.services.delete_credential_fn = Probe.remove;
        for (0..2) |_| {
            var restored = try prepare(&store, &credentials);
            defer restored.preparation.deinit();
            try std.testing.expectEqual(case.diagnostic, restored.preparation.recovery_diagnostic);
            try std.testing.expectEqual(case.generation, restored.preparation.generation());
            try std.testing.expectEqual(if (case.ready) mcp_configuration.StoreHealth.ready else .recovery_required, restored.management_health);
            try std.testing.expectEqual(!case.ready, restored.preparation.state == .unavailable);
            try std.testing.expectEqual(@as(usize, 0), Probe.deletions);
            try std.testing.expectEqual(case.isolated, try store.hasQuarantine());
        }
        if (case.registry) |original| {
            if (std.mem.eql(u8, original, current) or !case.isolated) {
                const bytes = (try store.loadAlloc(std.testing.allocator)).?;
                defer std.testing.allocator.free(bytes);
                try std.testing.expectEqualStrings(original, bytes);
            }
        }
        const remaining = try store.loadTransactionAlloc(std.testing.allocator);
        defer if (remaining) |bytes| std.testing.allocator.free(bytes);
        if (case.isolated) try std.testing.expect(remaining == null) else try std.testing.expectEqualStrings(case.transaction, remaining.?);
        const secret = credentials.resolveSecret(std.testing.allocator, "orphan");
        try std.testing.expect(secret == .value);
        defer {
            std.crypto.secureZero(u8, secret.value);
            std.testing.allocator.free(secret.value);
        }
        try std.testing.expectEqualStrings("preserved-secret-fixture", secret.value);
    }
}

test "MCP startup does not turn read failure into empty configuration" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const lock = try tmp.dir.createFile(std.testing.io, "fixture.lock", .{ .read = true, .truncate = false });
    defer lock.close(std.testing.io);
    try tmp.dir.createDir(std.testing.io, mcp_configuration.file_name, .default_dir);
    var store: mcp_configuration.FileStore = .{ .io = std.testing.io, .dir = tmp.dir, .lock_file = lock, .quarantine_move = mcp_platform.quarantineMove() };
    var restored = try prepare(&store, null);
    defer restored.preparation.deinit();
    try std.testing.expectEqual(mcp_configuration.PreparationState{ .unavailable = .read_failed }, restored.preparation.state);
    try std.testing.expectEqual(mcp_configuration.RecoveryDiagnostic.read_failed, restored.preparation.recovery_diagnostic);
    try std.testing.expectEqual(mcp_configuration.StoreHealth.recovery_required, restored.management_health);
    try std.testing.expect(!(try store.hasQuarantine()));
}

test "MCP startup keeps the supported schema one migration policy" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const lock = try tmp.dir.createFile(std.testing.io, "fixture.lock", .{ .read = true, .truncate = false });
    defer lock.close(std.testing.io);
    var store: mcp_configuration.FileStore = .{ .io = std.testing.io, .dir = tmp.dir, .lock_file = lock, .quarantine_move = mcp_platform.quarantineMove() };
    try store.commit("{\"schema_version\":1,\"generation\":7,\"servers\":[]}");
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    var credentials: mcp_platform.CredentialStore = .{ .io = std.testing.io, .runtime = &harness.runtime, .main_thread_id = std.Thread.getCurrentId() };
    var restored = try prepare(&store, &credentials);
    defer restored.preparation.deinit();
    try std.testing.expectEqual(@as(?u64, 7), restored.preparation.generation());
    try std.testing.expectEqual(mcp_configuration.StoreHealth.ready, restored.management_health);
    try std.testing.expectEqual(mcp_configuration.RecoveryDiagnostic.none, restored.preparation.recovery_diagnostic);
    const bytes = (try store.loadAlloc(std.testing.allocator)).?;
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqual(mcp_configuration.schema_version, try mcp_configuration.registrySourceSchemaVersion(std.testing.allocator, bytes));
    try std.testing.expect(!(try store.hasQuarantine()));
}

test "MCP startup keeps quarantine write failure and unknown outcome unavailable until restart recovery" {
    const Probe = struct {
        var base: std.Io = undefined;
        var unknown: bool = false;
        var fail_sync: bool = false;
        fn move(io: std.Io, old: std.Io.Dir, new: std.Io.Dir, request: mcp_configuration.QuarantineMove.Request) mcp_configuration.FileStoreError!void {
            if (request == .journal and !unknown) return error.WriteFailed;
            try mcp_platform.quarantineMove().move(io, old, new, request);
            if (request == .journal) fail_sync = true;
        }
        fn sync(raw: ?*anyopaque, file: std.Io.File) std.Io.File.SyncError!void {
            if (fail_sync) {
                fail_sync = false;
                return error.InputOutput;
            }
            return base.vtable.fileSync(raw, file);
        }
    };
    for ([_]bool{ false, true }) |unknown| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const lock = try tmp.dir.createFile(std.testing.io, "fixture.lock", .{ .read = true, .truncate = false });
        defer lock.close(std.testing.io);
        var store: mcp_configuration.FileStore = .{ .io = std.testing.io, .dir = tmp.dir, .lock_file = lock, .quarantine_move = mcp_platform.quarantineMove() };
        try store.commit("broken registry");
        try store.commitTransaction("broken journal");
        const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
        defer harness.destroy(std.testing.allocator);
        var credentials: mcp_platform.CredentialStore = .{ .io = std.testing.io, .runtime = &harness.runtime, .main_thread_id = std.Thread.getCurrentId() };
        Probe.base = std.testing.io;
        Probe.unknown = unknown;
        Probe.fail_sync = false;
        var vtable = std.testing.io.vtable.*;
        store.quarantine_move = .{ .move_fn = Probe.move };
        vtable.fileSync = Probe.sync;
        store.io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
        var failed = try prepare(&store, &credentials);
        defer failed.preparation.deinit();
        try std.testing.expect(failed.preparation.state == .unavailable);
        try std.testing.expectEqual(if (unknown) mcp_configuration.StoreHealth.outcome_unknown else .recovery_required, failed.management_health);
        try std.testing.expectEqual(if (unknown) mcp_configuration.RecoveryDiagnostic.quarantine_outcome_unknown else .quarantine_failed, failed.preparation.recovery_diagnostic);
        store.io = std.testing.io;
        store.quarantine_move = mcp_platform.quarantineMove();
        var recovered = try prepare(&store, &credentials);
        defer recovered.preparation.deinit();
        try std.testing.expectEqual(mcp_configuration.StoreHealth.ready, recovered.management_health);
        try std.testing.expectEqual(@as(?u64, 1), recovered.preparation.generation());
        try std.testing.expectEqual(mcp_configuration.RecoveryDiagnostic.quarantined_credentials_retained, recovered.preparation.recovery_diagnostic);
    }
}
