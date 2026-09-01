//! Product Control-owned Model Connection runtime.

const std = @import("std");
const contract = @import("metawork_product_execution_contract");
const ports = @import("product_execution_ports");
const registry_impl = @import("product_execution_model_connections");

pub const StartError = error{ExecutionDirectoryUnavailable};
pub const DefaultBinding = registry_impl.Registry.DefaultBinding;

pub const Preparation = contract.Preparation;

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    main_thread_id: std.Thread.Id,
    registry: registry_impl.Registry,
    store: ?registry_impl.FileStore = null,
    store_healthy: bool = false,
    credential_vault: ?ports.CredentialVault = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, main_thread_id: std.Thread.Id) Runtime {
        return .{
            .allocator = allocator,
            .io = io,
            .main_thread_id = main_thread_id,
            .registry = registry_impl.Registry.init(allocator),
        };
    }

    pub fn deinit(self: *Runtime) void {
        self.assertMainThread();
        std.debug.assert(self.credential_vault == null);
        if (self.store) |*store| store.deinit();
        self.registry.deinit();
        self.* = undefined;
    }

    pub fn start(self: *Runtime, absolute_directory: []const u8, vault: ports.CredentialVault) StartError!void {
        self.assertMainThread();
        std.debug.assert(self.store == null and self.credential_vault == null);
        if (absolute_directory.len == 0 or !std.fs.path.isAbsolute(absolute_directory))
            return error.ExecutionDirectoryUnavailable;
        self.credential_vault = vault;
        self.restore(absolute_directory);
    }

    pub fn startUnavailable(self: *Runtime) void {
        self.assertMainThread();
        std.debug.assert(self.store == null and self.credential_vault == null);
    }

    pub fn stop(self: *Runtime) void {
        self.assertMainThread();
        if (self.store) |*store| store.deinit();
        self.store = null;
        self.store_healthy = false;
        self.credential_vault = null;
    }

    pub fn views(self: *Runtime) []const contract.ModelConnectionView {
        self.assertMainThread();
        return self.registry.views();
    }

    pub fn defaultBinding(self: *const Runtime) ?DefaultBinding {
        self.assertMainThread();
        return self.registry.defaultBinding();
    }

    pub fn submitCommand(self: *Runtime, command: contract.ModelConnectionCommand) contract.CommandResult {
        return self.submitCommandWithExecutionGeneration(command, null);
    }

    pub fn submitCommandWithExecutionGeneration(
        self: *Runtime,
        command: contract.ModelConnectionCommand,
        execution_generation: ?u64,
    ) contract.CommandResult {
        self.assertMainThread();
        contract.validateModelConnectionCommand(command) catch
            return .rejected(.invalid_connection);
        if (!self.store_healthy) return .rejected(.persistence_unavailable);
        var candidate = self.registry.clone() catch |err| return .rejected(mapRegistryError(err));
        defer candidate.deinit();
        switch (command) {
            .create => |value| candidate.create(value) catch |err| return .rejected(mapRegistryError(err)),
            .update => |value| candidate.update(value) catch |err| return .rejected(mapRegistryError(err)),
            .remove => |value| candidate.remove(value) catch |err| return .rejected(mapRegistryError(err)),
            .test_connection => |value| candidate.markTesting(value.selection, value.model_id) catch |err|
                return .rejected(mapRegistryError(err)),
            .select_default => |value| candidate.selectDefault(
                value.selection,
                value.model_id,
                execution_generation orelse return .rejected(.invalid_connection),
            ) catch |err| return .rejected(mapRegistryError(err)),
        }
        return self.commitCandidate(&candidate, true);
    }

    pub fn completeTest(
        self: *Runtime,
        command: contract.ModelConnectionTestCommand,
        succeeded: bool,
    ) contract.CommandResult {
        self.assertMainThread();
        if (!self.store_healthy) return .rejected(.persistence_unavailable);
        var candidate = self.registry.clone() catch |err| return .rejected(mapRegistryError(err));
        defer candidate.deinit();
        candidate.completeTest(command.selection, command.model_id, succeeded) catch |err|
            return .rejected(mapRegistryError(err));
        return self.commitCandidate(&candidate, true);
    }

    pub fn clearDefault(self: *Runtime) contract.CommandResult {
        self.assertMainThread();
        if (!self.store_healthy) return .rejected(.persistence_unavailable);
        var candidate = self.registry.clone() catch |err| return .rejected(mapRegistryError(err));
        defer candidate.deinit();
        if (!candidate.clearDefault()) return .acceptedResult();
        return self.commitCandidate(&candidate, true);
    }

    pub fn createWithCredential(
        self: *Runtime,
        secret: []const u8,
        spec: contract.ModelConnectionSpec,
        model_id: []const u8,
        model_display_name: []const u8,
    ) contract.CommandResult {
        self.assertMainThread();
        if (!self.store_healthy) return .rejected(.persistence_unavailable);
        contract.validateModelConnectionSpec(spec) catch return .rejected(.invalid_connection);
        if (model_id.len == 0 or model_id.len > contract.Limits.model_id_bytes or
            model_display_name.len > contract.Limits.model_display_name_bytes or
            secret.len == 0 or secret.len > contract.Limits.credential_bytes or
            !std.unicode.utf8ValidateSlice(model_id) or
            !std.unicode.utf8ValidateSlice(model_display_name))
            return .rejected(.invalid_connection);
        const vault = self.credential_vault orelse return .rejected(.capture_unavailable);
        var slot_storage: [ports.credential_slot_bytes]u8 = undefined;
        const slot_id = vault.generateSlot(&slot_storage) catch
            return .rejected(.credential_write_failed);

        var reserved = self.registry.clone() catch |err| return .rejected(mapRegistryError(err));
        defer reserved.deinit();
        reserved.reserveCredentialDeletion(slot_id) catch |err| return .rejected(mapRegistryError(err));
        const reserve_result = self.commitCandidate(&reserved, false);
        if (!reserve_result.accepted) return reserve_result;

        vault.store(slot_id, secret) catch {
            self.drainCredentialCleanup();
            return .rejected(.credential_write_failed);
        };
        var committed = self.registry.clone() catch |err| {
            self.drainCredentialCleanup();
            return .rejected(mapRegistryError(err));
        };
        defer committed.deinit();
        committed.create(.{
            .connection_id = slot_id,
            .spec = spec,
            .credential_slot = .{ .id = slot_id },
            .model_id = model_id,
            .model_display_name = model_display_name,
        }) catch |err| {
            self.drainCredentialCleanup();
            return .rejected(mapRegistryError(err));
        };
        committed.completeCredentialDeletion(slot_id) catch {
            self.drainCredentialCleanup();
            return .rejected(.invalid_connection);
        };
        const result = self.commitCandidate(&committed, true);
        if (!result.accepted and self.store_healthy) self.drainCredentialCleanup();
        return result;
    }

    pub fn nextGeneration(self: *Runtime, current_generation: u64) !u64 {
        self.assertMainThread();
        while (true) {
            var bytes: [@sizeOf(u64)]u8 = undefined;
            try std.Io.randomSecure(self.io, &bytes);
            const generation = std.mem.readInt(u64, &bytes, .big);
            if (generation != 0 and generation != current_generation) return generation;
        }
    }

    pub fn prepareExecution(
        self: *Runtime,
        selection: contract.ModelConnectionSelectionCommand,
        model_id: []const u8,
        execution_generation: u64,
    ) Preparation {
        return .{ .ready = self.resolveExecution(selection, model_id, execution_generation) catch |err|
            return .{ .rejected = mapResolutionError(err) } };
    }

    pub fn resolveProbeExecution(
        self: *Runtime,
        selection: contract.ModelConnectionSelectionCommand,
        model_id: []const u8,
        execution_generation: u64,
    ) !contract.OwnedConfig {
        self.assertMainThread();
        return self.resolveBinding(try self.registry.probeBinding(selection, model_id, execution_generation));
    }

    pub fn resolveDefaultExecution(self: *Runtime) !?contract.OwnedConfig {
        self.assertMainThread();
        const binding = self.registry.defaultBinding() orelse return null;
        return self.resolveBinding(binding) catch |err| {
            if (err == error.CredentialNotFound) {
                self.markCredentialMissing(binding);
                return null;
            }
            return err;
        };
    }

    fn resolveExecution(
        self: *Runtime,
        selection: contract.ModelConnectionSelectionCommand,
        model_id: []const u8,
        execution_generation: u64,
    ) !contract.OwnedConfig {
        return self.resolveBinding(try self.registry.executionBinding(selection, model_id, execution_generation));
    }

    fn resolveBinding(self: *Runtime, binding: registry_impl.Registry.DefaultBinding) !contract.OwnedConfig {
        const vault = self.credential_vault orelse return error.CredentialStoreUnavailable;
        var secret_storage: [contract.Limits.credential_bytes]u8 = undefined;
        defer std.crypto.secureZero(u8, &secret_storage);
        const secret = (try vault.get(binding.connection_id, &secret_storage)) orelse
            return error.CredentialNotFound;
        return contract.OwnedConfig.initOwned(
            self.allocator,
            .model_connection,
            binding.protocol,
            try self.allocator.dupe(u8, binding.model_id),
            try self.allocator.dupe(u8, binding.normalized_base_url),
            binding.execution_generation,
            try self.allocator.dupe(u8, secret),
            binding.connection_id,
        );
    }

    fn commitCandidate(
        self: *Runtime,
        candidate: *registry_impl.Registry,
        drain_cleanup: bool,
    ) contract.CommandResult {
        const encoded = registry_impl.encodeAlloc(self.allocator, candidate) catch |err|
            return .rejected(mapRegistryError(err));
        defer self.allocator.free(encoded);
        const store = if (self.store) |*value| value else return .rejected(.persistence_unavailable);
        store.commit(encoded) catch |err| {
            if (err == error.PersistenceOutcomeUnknown) self.store_healthy = false;
            return .rejected(.persistence_unavailable);
        };
        self.registry.replace(candidate);
        if (drain_cleanup) self.drainCredentialCleanup();
        return .acceptedResult();
    }

    fn restore(self: *Runtime, absolute_directory: []const u8) void {
        self.store = registry_impl.FileStore.init(self.io, absolute_directory) catch return;
        self.store_healthy = true;
        const bytes_optional = self.store.?.loadAlloc(self.allocator) catch {
            self.store_healthy = false;
            return;
        };
        const bytes = bytes_optional orelse return;
        defer self.allocator.free(bytes);
        var restored = registry_impl.decode(self.allocator, bytes) catch {
            self.store_healthy = false;
            return;
        };
        if (restored.reconcileInterruptedTests()) {
            const reconciled = registry_impl.encodeAlloc(self.allocator, &restored) catch {
                self.store_healthy = false;
                self.registry.replace(&restored);
                restored.deinit();
                return;
            };
            defer self.allocator.free(reconciled);
            self.store.?.commit(reconciled) catch {
                self.store_healthy = false;
            };
        }
        self.registry.replace(&restored);
        restored.deinit();
        self.drainCredentialCleanup();
    }

    fn markCredentialMissing(self: *Runtime, binding: registry_impl.Registry.DefaultBinding) void {
        self.registry.markCredentialMissing(.{
            .connection_id = binding.connection_id,
            .expected_connection_generation = binding.connection_generation,
        }) catch return;
        const encoded = registry_impl.encodeAlloc(self.allocator, &self.registry) catch {
            self.store_healthy = false;
            return;
        };
        defer self.allocator.free(encoded);
        const store = if (self.store) |*value| value else {
            self.store_healthy = false;
            return;
        };
        store.commit(encoded) catch {
            self.store_healthy = false;
        };
    }

    fn drainCredentialCleanup(self: *Runtime) void {
        if (!self.store_healthy) return;
        const vault = self.credential_vault orelse return;
        while (self.registry.nextCredentialDeletion()) |connection_id| {
            vault.delete(connection_id) catch return;
            var candidate = self.registry.clone() catch return;
            defer candidate.deinit();
            candidate.completeCredentialDeletion(connection_id) catch return;
            const result = self.commitCandidate(&candidate, false);
            if (!result.accepted) return;
        }
    }

    fn assertMainThread(self: *const Runtime) void {
        std.debug.assert(std.Thread.getCurrentId() == self.main_thread_id);
    }
};

fn mapRegistryError(err: anyerror) contract.ManagementError {
    return switch (err) {
        error.ConnectionNotFound => .connection_not_found,
        error.GenerationMismatch => .generation_mismatch,
        error.ModelNotFound => .model_not_found,
        error.Capacity => .capacity,
        error.OutOfMemory => .local_resource_exhausted,
        else => .invalid_connection,
    };
}

fn mapResolutionError(err: anyerror) contract.ManagementError {
    return switch (err) {
        error.ConnectionNotFound => .connection_not_found,
        error.GenerationMismatch => .generation_mismatch,
        error.ModelNotFound => .model_not_found,
        error.OutOfMemory => .local_resource_exhausted,
        error.CredentialStoreUnavailable, error.CredentialNotFound => .capture_unavailable,
        else => .capture_unavailable,
    };
}

const TestVault = struct {
    const slot = "model-connection-00000000000000000000000000000001";

    secret: [contract.Limits.credential_bytes]u8 = undefined,
    secret_len: usize = 0,
    present: bool = false,

    fn port(self: *TestVault) ports.CredentialVault {
        return .{
            .context = self,
            .generate_slot_fn = generate,
            .store_fn = store,
            .get_fn = get,
            .delete_fn = delete,
        };
    }

    fn generate(_: *anyopaque, output: *[ports.credential_slot_bytes]u8) anyerror!void {
        @memcpy(output, slot);
    }

    fn store(context: *anyopaque, _: []const u8, secret: []const u8) anyerror!void {
        const self: *TestVault = @ptrCast(@alignCast(context));
        if (secret.len > self.secret.len) return error.WriteFailed;
        @memcpy(self.secret[0..secret.len], secret);
        self.secret_len = secret.len;
        self.present = true;
    }

    fn get(context: *anyopaque, _: []const u8, output: []u8) anyerror!?[]const u8 {
        const self: *TestVault = @ptrCast(@alignCast(context));
        if (!self.present) return null;
        if (self.secret_len > output.len) return error.ReadFailed;
        @memcpy(output[0..self.secret_len], self.secret[0..self.secret_len]);
        return output[0..self.secret_len];
    }

    fn delete(context: *anyopaque, _: []const u8) anyerror!void {
        const self: *TestVault = @ptrCast(@alignCast(context));
        std.crypto.secureZero(u8, self.secret[0..self.secret_len]);
        self.secret_len = 0;
        self.present = false;
    }
};

test "Execution Runtime owns durable model connections and credential resolution" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var directory_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory_len = try tmp.dir.realPath(std.testing.io, &directory_storage);
    const directory = directory_storage[0..directory_len];
    var vault: TestVault = .{};

    {
        var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
        try runtime.start(directory, vault.port());
        defer {
            runtime.stop();
            runtime.deinit();
        }
        try std.testing.expect(runtime.createWithCredential(
            "provider-secret",
            .{
                .display_name = "OpenAI",
                .protocol = .openai_responses,
                .normalized_base_url = "https://api.openai.com/v1/responses",
            },
            "gpt-5",
            "GPT-5",
        ).accepted);
        const view = runtime.views()[0];
        try std.testing.expectEqualStrings(TestVault.slot, view.id);
        const selection: contract.ModelConnectionSelectionCommand = .{
            // Registry views are borrowed until the next committed mutation.
            // Commands arrive with independently owned request bytes in
            // production, so keep this test selection independently stable.
            .connection_id = TestVault.slot,
            .expected_connection_generation = view.connection_generation,
        };
        try std.testing.expect(runtime.submitCommand(.{ .test_connection = .{
            .selection = selection,
            .model_id = "gpt-5",
        } }).accepted);
        try std.testing.expect(runtime.completeTest(.{
            .selection = selection,
            .model_id = "gpt-5",
        }, true).accepted);
        try std.testing.expect(runtime.submitCommandWithExecutionGeneration(.{
            .select_default = .{
                .selection = selection,
                .model_id = "gpt-5",
            },
        }, 17).accepted);
        var execution = (try runtime.resolveDefaultExecution()) orelse
            return error.TestUnexpectedResult;
        defer execution.deinit();
        try std.testing.expectEqualStrings("provider-secret", execution.input().api_key);
        try std.testing.expectEqual(contract.Protocol.openai_responses, execution.input().target.protocol);
        try std.testing.expectEqual(@as(u64, 17), execution.input().execution_generation);
    }

    {
        var restored = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
        try restored.start(directory, vault.port());
        defer {
            restored.stop();
            restored.deinit();
        }
        try std.testing.expectEqual(@as(usize, 1), restored.views().len);
        var execution = (try restored.resolveDefaultExecution()) orelse
            return error.TestUnexpectedResult;
        defer execution.deinit();
        try std.testing.expectEqualStrings("provider-secret", execution.input().api_key);
        try std.testing.expectEqualStrings("model_connection:" ++ TestVault.slot, execution.input().target.provider_id);
    }
}
