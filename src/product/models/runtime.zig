//! Product Models runtime owned by Product Control.

const std = @import("std");
const builtin = @import("builtin");
const contract = @import("metawork_product_models_contract");
const ports = @import("product_models_ports");
const registry_impl = @import("product_models_connections");
const metask_provider = @import("product_models_metask");

pub const StartError = error{
    ModelConnectionsDirectoryUnavailable,
    ModelsStateUnavailable,
};
pub const DefaultBinding = registry_impl.Registry.DefaultBinding;

pub const TestSupport = if (builtin.is_test) struct {
    pub fn installMetaskDefault(
        runtime: *Runtime,
        principal_ref: []const u8,
        api_key: contract.ApiKeyView,
        secret: []const u8,
        models: []const contract.ModelView,
        selected_model: []const u8,
        source_generation: u64,
        metask_selection_revision: u64,
        default_selection_revision: u64,
        catalog_generation: u64,
    ) !void {
        runtime.assertMainThread();
        runtime.metask_catalog.deinit();
        runtime.metask_catalog = metask_provider.CatalogSession.init(runtime.allocator);
        try metask_provider.TestSupport.replaceOwnedSelection(
            &runtime.metask_catalog,
            principal_ref,
            api_key,
            secret,
            models,
        );
        if (!runtime.metask_catalog.hasModel(selected_model))
            return error.InvalidTestModel;
        const configure_updates_default = runtime.registry.metaskChangeUpdatesDefault(
            api_key.id,
            selected_model,
        );
        try runtime.registry.configureMetask(
            principal_ref,
            api_key.id,
            selected_model,
            api_key.protocol,
            source_generation,
            metask_selection_revision,
            if (configure_updates_default) default_selection_revision else null,
        );
        if (!configure_updates_default)
            try runtime.registry.selectMetaskDefault(default_selection_revision);
        runtime.metask_catalog_state = .ready;
        runtime.metask_catalog_generation = catalog_generation;
        runtime.metask_error = .none;
        runtime.store_healthy = true;
        if (runtime.metask_public_catalog == null) {
            const public_catalog = try runtime.allocator.create(metask_provider.PublicCatalog);
            public_catalog.* = .{};
            runtime.metask_public_catalog = public_catalog;
        }
        runtime.metask_public_catalog.?.replaceFromSession(&runtime.metask_catalog);
    }
} else struct {};

fn FixedText(comptime capacity: usize) type {
    return struct {
        bytes: [capacity]u8 = undefined,
        len: usize = 0,

        fn set(self: *@This(), value: []const u8) bool {
            if (value.len > capacity or !std.unicode.utf8ValidateSlice(value))
                return false;
            if (value.len != 0) @memcpy(self.bytes[0..value.len], value);
            self.len = value.len;
            return true;
        }

        fn view(self: *const @This()) []const u8 {
            return self.bytes[0..self.len];
        }
    };
}

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    main_thread_id: std.Thread.Id,
    registry: registry_impl.Registry,
    store: ?registry_impl.FileStore = null,
    store_healthy: bool = false,
    credential_vault: ?ports.CredentialVault = null,
    metask_catalog: metask_provider.CatalogSession,
    metask_public_catalog: ?*metask_provider.PublicCatalog = null,
    metask_catalog_state: contract.CatalogState = .needs_authentication,
    metask_catalog_generation: u64 = 0,
    metask_error: contract.ModelsError = .none,
    metask_safe_diagnostic: FixedText(contract.Limits.safe_diagnostic_bytes) = .{},
    metask_source_id: FixedText("metask:".len + contract.Limits.api_key_id_bytes) = .{},
    provider_views: [1]contract.ProviderView = undefined,
    catalog_attempt: ?struct {
        id: u64,
        principal_ref: FixedText(contract.Limits.principal_ref_bytes),
        authorization_generation: u64,
    } = null,
    next_catalog_attempt_id: u64 = 1,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, main_thread_id: std.Thread.Id) Runtime {
        return .{
            .allocator = allocator,
            .io = io,
            .main_thread_id = main_thread_id,
            .registry = registry_impl.Registry.init(allocator),
            .metask_catalog = metask_provider.CatalogSession.init(allocator),
        };
    }

    pub fn deinit(self: *Runtime) void {
        self.assertMainThread();
        std.debug.assert(self.credential_vault == null);
        if (self.metask_public_catalog) |public_catalog|
            self.allocator.destroy(public_catalog);
        if (self.store) |*store| store.deinit();
        self.metask_catalog.deinit();
        self.registry.deinit();
        self.* = undefined;
    }

    pub fn start(self: *Runtime, absolute_directory: []const u8, vault: ports.CredentialVault) StartError!void {
        self.assertMainThread();
        std.debug.assert(self.store == null and self.credential_vault == null);
        if (absolute_directory.len == 0 or !std.fs.path.isAbsolute(absolute_directory))
            return error.ModelConnectionsDirectoryUnavailable;
        const public_catalog = self.allocator.create(metask_provider.PublicCatalog) catch
            return error.ModelsStateUnavailable;
        public_catalog.* = .{};
        self.metask_public_catalog = public_catalog;
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
        self.clearMetaskRuntime(.needs_authentication, .authorization_unavailable);
        if (self.metask_public_catalog) |public_catalog| {
            self.allocator.destroy(public_catalog);
            self.metask_public_catalog = null;
        }
    }

    pub fn views(self: *Runtime) []const contract.ModelConnectionView {
        self.assertMainThread();
        return self.registry.views();
    }

    pub fn view(self: *Runtime) contract.ModelsView {
        self.assertMainThread();
        const intent = self.registry.metaskIntent();
        var metask_selection: ?contract.ModelRef = null;
        if (intent) |value| {
            const source_id = std.fmt.bufPrint(
                &self.metask_source_id.bytes,
                "metask:{s}",
                .{value.api_key_id},
            ) catch "";
            self.metask_source_id.len = source_id.len;
            if (source_id.len != 0) metask_selection = .{
                .source_id = self.metask_source_id.view(),
                .model_id = value.model_id,
            };
        } else {
            self.metask_source_id.len = 0;
        }
        self.provider_views[0] = .{
            .id = contract.metask_source_id,
            .display_name = "Metask",
            .recommended = true,
            .catalog_state = self.metask_catalog_state,
            .principal_ref = if (intent) |value| value.principal_ref else "",
            .api_keys = if (self.metask_public_catalog) |public_catalog|
                public_catalog.apiKeyViews()
            else
                &.{},
            .models = if (self.metask_public_catalog) |public_catalog|
                public_catalog.modelViews()
            else
                &.{},
            .selected_api_key_id = if (intent) |value| value.api_key_id else "",
            .catalog_generation = self.metask_catalog_generation,
            .source_generation = if (intent) |value| value.source_generation else 0,
            .error_code = self.metask_error,
            .safe_diagnostic = self.metask_safe_diagnostic.view(),
        };
        return .{
            .availability = if (self.store_healthy) .ready else .unavailable,
            .persistence_health = if (self.store_healthy) .ready else .unavailable,
            .providers = self.provider_views[0..],
            .metask_selection = metask_selection,
            .metask_selection_revision = if (intent) |value| value.selection_revision else 0,
            .default_selection = self.registry.defaultSelection(),
            .selection_revision = self.registry.selection_revision,
            .operation = if (self.catalog_attempt == null) .idle else .refreshing_catalog,
            .error_code = if (!self.store_healthy) .persistence_unavailable else self.metask_error,
            .model_connections = self.registry.views(),
        };
    }

    pub fn prepareMetaskCatalogRefresh(
        self: *Runtime,
        principal_ref: []const u8,
        authorization_generation: u64,
    ) contract.CatalogRefreshPrepareResult {
        self.assertMainThread();
        return self.beginMetaskCatalogRefresh(
            principal_ref,
            authorization_generation,
            "",
        );
    }

    pub fn prepareMetaskApiKeySelection(
        self: *Runtime,
        principal_ref: []const u8,
        authorization_generation: u64,
        command: contract.SelectMetaskApiKeyCommand,
    ) contract.CatalogSelectionPrepareResult {
        self.assertMainThread();
        if (!self.store_healthy) return .{ .rejected = .persistence_unavailable };
        if (self.catalog_attempt != null) return .{ .rejected = .operation_in_progress };
        if (self.metask_catalog_state != .ready or
            self.metask_catalog_generation == 0 or
            command.expected_catalog_generation != self.metask_catalog_generation)
            return .{ .rejected = .generation_mismatch };
        const intent = self.registry.metaskIntent() orelse
            return .{ .rejected = .invalid_connection };
        if (command.expected_metask_selection_revision != intent.selection_revision or
            !std.mem.eql(u8, principal_ref, intent.principal_ref))
            return .{ .rejected = .generation_mismatch };
        if (!std.mem.startsWith(u8, command.source_id, "metask:") or
            command.source_id.len == "metask:".len)
            return .{ .rejected = .invalid_connection };
        const api_key_id = command.source_id["metask:".len..];
        if (api_key_id.len > contract.Limits.api_key_id_bytes or
            self.metask_public_catalog == null or
            !self.metask_public_catalog.?.hasApiKey(api_key_id))
            return .{ .rejected = .invalid_connection };
        return switch (self.beginMetaskCatalogRefresh(
            principal_ref,
            authorization_generation,
            api_key_id,
        )) {
            .ready => |value| .{ .ready = value },
            .rejected => |error_code| .{ .rejected = mapModelsError(error_code) },
        };
    }

    fn beginMetaskCatalogRefresh(
        self: *Runtime,
        principal_ref: []const u8,
        authorization_generation: u64,
        required_api_key_id: []const u8,
    ) contract.CatalogRefreshPrepareResult {
        if (!self.store_healthy) return .{ .rejected = .persistence_unavailable };
        if (self.catalog_attempt != null) return .{ .rejected = .operation_in_progress };
        if (principal_ref.len == 0 or
            principal_ref.len > contract.Limits.principal_ref_bytes or
            authorization_generation == 0 or
            !std.unicode.utf8ValidateSlice(principal_ref))
            return .{ .rejected = .authorization_unavailable };
        var principal: FixedText(contract.Limits.principal_ref_bytes) = .{};
        if (!principal.set(principal_ref))
            return .{ .rejected = .authorization_unavailable };
        const attempt_id = self.next_catalog_attempt_id;
        self.next_catalog_attempt_id +%= 1;
        if (self.next_catalog_attempt_id == 0) self.next_catalog_attempt_id = 1;
        self.catalog_attempt = .{
            .id = attempt_id,
            .principal_ref = principal,
            .authorization_generation = authorization_generation,
        };
        self.metask_catalog_state = .loading;
        self.metask_error = .none;
        self.metask_safe_diagnostic.len = 0;
        const intent = self.registry.metaskIntent();
        const same_principal = if (intent) |value|
            std.mem.eql(u8, value.principal_ref, principal_ref)
        else
            false;
        return .{ .ready = .{
            .attempt_id = attempt_id,
            .principal_ref = self.catalog_attempt.?.principal_ref.view(),
            .authorization_generation = authorization_generation,
            .preferred_api_key_id = if (same_principal) intent.?.api_key_id else "",
            .preferred_model_id = if (same_principal and
                (required_api_key_id.len == 0 or std.mem.eql(
                    u8,
                    required_api_key_id,
                    intent.?.api_key_id,
                ))) intent.?.model_id else "",
            .required_api_key_id = required_api_key_id,
        } };
    }

    pub fn completeMetaskCatalogRefresh(
        self: *Runtime,
        attempt_id: u64,
        authorization_generation: u64,
        completion_port: *ports.OwnedCatalogCompletion,
    ) contract.ModelsError {
        self.assertMainThread();
        const completion = metask_provider.fromOwnedPort(completion_port) orelse {
            completion_port.deinit();
            self.catalog_attempt = null;
            self.metask_catalog_state = .failed;
            self.metask_error = .catalog_invalid;
            return .catalog_invalid;
        };
        defer completion_port.deinit();
        const session = &completion.session;
        const selected_model_id = completion.selected_model_id;
        const attempt = self.catalog_attempt orelse return .catalog_invalid;
        self.catalog_attempt = null;
        if (attempt.id != attempt_id or
            attempt.authorization_generation != authorization_generation or
            !std.mem.eql(u8, attempt.principal_ref.view(), session.ownerAccountId()))
        {
            self.metask_catalog_state = .needs_authentication;
            self.metask_error = .authorization_unavailable;
            return self.metask_error;
        }
        const api_key_id = session.selectedApiKeyId();
        const protocol = session.selectedProtocol() orelse {
            self.metask_catalog_state = .failed;
            self.metask_error = .catalog_invalid;
            return self.metask_error;
        };
        if (api_key_id.len == 0 or !session.hasModel(selected_model_id)) {
            self.metask_catalog_state = .failed;
            self.metask_error = .catalog_invalid;
            return self.metask_error;
        }

        var candidate = self.registry.clone() catch {
            self.metask_catalog_state = .failed;
            self.metask_error = .local_resource_exhausted;
            return self.metask_error;
        };
        defer candidate.deinit();
        const current = candidate.metaskIntent();
        const same_selection = if (current) |value|
            std.mem.eql(u8, value.principal_ref, attempt.principal_ref.view()) and
                std.mem.eql(u8, value.api_key_id, api_key_id) and
                std.mem.eql(u8, value.model_id, selected_model_id)
        else
            false;
        const same_authority = if (current) |value|
            std.mem.eql(u8, value.principal_ref, attempt.principal_ref.view()) and
                std.mem.eql(u8, value.api_key_id, api_key_id) and
                value.protocol == protocol and value.source_generation != 0
        else
            false;
        const source_generation = if (same_authority)
            current.?.source_generation
        else
            self.freshGeneration(if (current) |value| value.source_generation else 0) catch {
                self.metask_catalog_state = .failed;
                self.metask_error = .local_resource_exhausted;
                return self.metask_error;
            };
        const selection_revision = if (same_selection and current.?.selection_revision != 0)
            current.?.selection_revision
        else
            self.freshGeneration(if (current) |value| value.selection_revision else 0) catch {
                self.metask_catalog_state = .failed;
                self.metask_error = .local_resource_exhausted;
                return self.metask_error;
            };
        // Finish all fallible generation allocation before committing durable
        // intent. A catalog refresh must not persist a new selection and then
        // fail to install the matching in-memory catalog generation.
        const catalog_generation = self.freshGeneration(self.metask_catalog_generation) catch {
            self.metask_catalog_state = .failed;
            self.metask_error = .local_resource_exhausted;
            return self.metask_error;
        };
        const updates_default = candidate.metaskChangeUpdatesDefault(api_key_id, selected_model_id);
        const default_selection_revision = if (updates_default)
            self.freshGeneration(candidate.selection_revision) catch {
                self.metask_catalog_state = .failed;
                self.metask_error = .local_resource_exhausted;
                return self.metask_error;
            }
        else
            null;
        candidate.configureMetask(
            attempt.principal_ref.view(),
            api_key_id,
            selected_model_id,
            protocol,
            source_generation,
            selection_revision,
            default_selection_revision,
        ) catch {
            self.metask_catalog_state = .failed;
            self.metask_error = .catalog_invalid;
            return self.metask_error;
        };
        const committed = self.commitCandidate(&candidate, true);
        if (!committed.accepted) {
            self.metask_catalog_state = .failed;
            self.metask_error = .persistence_unavailable;
            return self.metask_error;
        }
        self.metask_catalog.deinit();
        self.metask_catalog = session.take();
        const public_catalog = self.metask_public_catalog orelse {
            self.metask_catalog.deinit();
            self.metask_catalog = metask_provider.CatalogSession.init(self.allocator);
            self.metask_catalog_state = .unavailable;
            self.metask_error = .persistence_unavailable;
            return self.metask_error;
        };
        public_catalog.replaceFromSession(&self.metask_catalog);
        self.metask_catalog_generation = catalog_generation;
        self.metask_catalog_state = .ready;
        self.metask_error = .none;
        return .none;
    }

    pub fn failMetaskCatalogRefresh(
        self: *Runtime,
        attempt_id: u64,
        authorization_generation: u64,
        error_code: contract.ModelsError,
        safe_diagnostic: []const u8,
    ) void {
        self.assertMainThread();
        const attempt = self.catalog_attempt orelse return;
        if (attempt.id != attempt_id or
            attempt.authorization_generation != authorization_generation)
            return;
        self.catalog_attempt = null;
        self.metask_catalog_state = if (error_code == .authorization_unavailable)
            .needs_authentication
        else
            .failed;
        self.metask_error = if (error_code == .none) .catalog_invalid else error_code;
        if (!self.metask_safe_diagnostic.set(safe_diagnostic))
            self.metask_safe_diagnostic.len = 0;
    }

    pub fn setMetaskAuthorizationUnavailable(self: *Runtime) void {
        self.assertMainThread();
        self.clearMetaskRuntime(.needs_authentication, .authorization_unavailable);
    }

    pub fn configureMetaskSelection(
        self: *Runtime,
        command: contract.ConfigureMetaskSelectionCommand,
    ) contract.CommandResult {
        self.assertMainThread();
        if (!self.store_healthy) return .rejected(.persistence_unavailable);
        if (self.catalog_attempt != null) return .rejected(.operation_in_progress);
        if (self.metask_catalog_state != .ready or
            self.metask_catalog_generation == 0 or
            command.expected_catalog_generation != self.metask_catalog_generation)
            return .rejected(.generation_mismatch);
        const current = self.registry.metaskIntent();
        const current_revision = if (current) |value| value.selection_revision else 0;
        if (command.expected_metask_selection_revision != current_revision)
            return .rejected(.generation_mismatch);
        const api_key_id = self.metask_catalog.selectedApiKeyId();
        const protocol = self.metask_catalog.selectedProtocol() orelse
            return .rejected(.invalid_connection);
        if (!metaskSourceMatches(command.selection.source_id, api_key_id) or
            !self.metask_catalog.hasModel(command.selection.model_id))
            return .rejected(.model_not_found);
        const principal_ref = self.metask_catalog.ownerAccountId();
        if (principal_ref.len == 0) return .rejected(.invalid_connection);
        if (current) |value| {
            if (std.mem.eql(u8, value.principal_ref, principal_ref) and
                std.mem.eql(u8, value.api_key_id, api_key_id) and
                std.mem.eql(u8, value.model_id, command.selection.model_id) and
                value.protocol == protocol and value.source_generation != 0)
                return .acceptedResult();
        }

        var candidate = self.registry.clone() catch
            return .rejected(.local_resource_exhausted);
        defer candidate.deinit();
        const same_authority = if (current) |value|
            std.mem.eql(u8, value.principal_ref, principal_ref) and
                std.mem.eql(u8, value.api_key_id, api_key_id) and
                value.protocol == protocol and value.source_generation != 0
        else
            false;
        const source_generation = if (same_authority)
            current.?.source_generation
        else
            self.freshGeneration(if (current) |value| value.source_generation else 0) catch
                return .rejected(.local_resource_exhausted);
        const metask_selection_revision = self.freshGeneration(current_revision) catch
            return .rejected(.local_resource_exhausted);
        const updates_default = candidate.metaskChangeUpdatesDefault(
            api_key_id,
            command.selection.model_id,
        );
        const default_selection_revision = if (updates_default)
            self.freshGeneration(candidate.selection_revision) catch
                return .rejected(.local_resource_exhausted)
        else
            null;
        candidate.configureMetask(
            principal_ref,
            api_key_id,
            command.selection.model_id,
            protocol,
            source_generation,
            metask_selection_revision,
            default_selection_revision,
        ) catch |err| return .rejected(mapRegistryError(err));
        return self.commitCandidate(&candidate, true);
    }

    pub fn selectMetaskDefault(
        self: *Runtime,
        command: contract.SelectDefaultCommand,
    ) contract.CommandResult {
        self.assertMainThread();
        if (!self.store_healthy) return .rejected(.persistence_unavailable);
        if (self.catalog_attempt != null) return .rejected(.operation_in_progress);
        const intent = self.registry.metaskIntent() orelse
            return .rejected(.invalid_connection);
        if (command.expected_selection_revision != self.registry.selection_revision or
            command.expected_source_generation != intent.source_generation or
            command.expected_catalog_generation != self.metask_catalog_generation or
            self.metask_catalog_state != .ready or
            !metaskSourceMatches(command.selection.source_id, intent.api_key_id) or
            !std.mem.eql(u8, command.selection.model_id, intent.model_id) or
            !self.metask_catalog.ownsSourceSelection(
                intent.principal_ref,
                intent.api_key_id,
                intent.model_id,
            ))
            return .rejected(.generation_mismatch);
        if (self.registry.defaultSelection()) |current| {
            if (std.mem.eql(u8, current.source_id, command.selection.source_id) and
                std.mem.eql(u8, current.model_id, command.selection.model_id))
                return .acceptedResult();
        }
        var candidate = self.registry.clone() catch
            return .rejected(.local_resource_exhausted);
        defer candidate.deinit();
        const selection_revision = self.freshGeneration(candidate.selection_revision) catch
            return .rejected(.local_resource_exhausted);
        candidate.selectMetaskDefault(selection_revision) catch |err|
            return .rejected(mapRegistryError(err));
        return self.commitCandidate(&candidate, true);
    }

    /// Selects the global default by source-qualified model identity. Models
    /// validates every supplied generation against its current projection;
    /// callers never translate this command into provider-local mutations.
    pub fn selectDefault(
        self: *Runtime,
        command: contract.SelectDefaultCommand,
    ) contract.CommandResult {
        self.assertMainThread();
        if (command.selection.source_id.len == 0 or
            command.selection.source_id.len > contract.Limits.provider_id_bytes or
            command.selection.model_id.len == 0 or
            command.selection.model_id.len > contract.Limits.model_id_bytes or
            command.expected_source_generation == 0 or
            command.expected_catalog_generation == 0)
            return .rejected(.invalid_connection);
        if (std.mem.startsWith(u8, command.selection.source_id, "metask:"))
            return self.selectMetaskDefault(command);
        if (!self.store_healthy) return .rejected(.persistence_unavailable);
        if (command.expected_selection_revision != self.registry.selection_revision)
            return .rejected(.generation_mismatch);
        const connection = for (self.registry.views()) |value| {
            if (std.mem.eql(u8, value.id, command.selection.source_id))
                break value;
        } else return .rejected(.invalid_connection);
        if (connection.source_generation != command.expected_source_generation or
            connection.catalog_generation != command.expected_catalog_generation)
            return .rejected(.generation_mismatch);
        if (self.registry.defaultSelection()) |current| {
            if (std.mem.eql(u8, current.source_id, command.selection.source_id) and
                std.mem.eql(u8, current.model_id, command.selection.model_id))
                return .acceptedResult();
        }
        var candidate = self.registry.clone() catch
            return .rejected(.local_resource_exhausted);
        defer candidate.deinit();
        const selection_revision = self.freshGeneration(candidate.selection_revision) catch
            return .rejected(.local_resource_exhausted);
        candidate.selectDefault(.{
            .source_id = connection.id,
            .expected_connection_revision = connection.connection_revision,
        }, command.selection.model_id, selection_revision) catch |err|
            return .rejected(mapRegistryError(err));
        return self.commitCandidate(&candidate, true);
    }

    pub fn defaultBinding(self: *const Runtime) ?DefaultBinding {
        self.assertMainThread();
        return self.registry.defaultBinding();
    }

    pub fn defaultAuthority(self: *const Runtime) ?contract.DefaultSelectionAuthority {
        self.assertMainThread();
        const selection = self.registry.defaultSelection() orelse return null;
        if (self.registry.metaskIntent()) |intent| {
            var source_storage: ["metask:".len + contract.Limits.api_key_id_bytes]u8 = undefined;
            const source_id = std.fmt.bufPrint(
                &source_storage,
                "metask:{s}",
                .{intent.api_key_id},
            ) catch return null;
            if (std.mem.eql(u8, selection.source_id, source_id)) {
                const protocol = intent.protocol orelse return null;
                if (intent.source_generation == 0 or self.registry.selection_revision == 0)
                    return null;
                return .{
                    .selection = selection,
                    .source = .metask,
                    .source_generation = intent.source_generation,
                    .selection_revision = self.registry.selection_revision,
                    .protocol = protocol,
                };
            }
        }
        const binding = self.registry.desiredDefaultBinding() orelse return null;
        if (binding.source_generation == 0 or self.registry.selection_revision == 0)
            return null;
        return .{
            .selection = selection,
            .source = .model_connection,
            .source_generation = binding.source_generation,
            .selection_revision = self.registry.selection_revision,
            .protocol = binding.protocol,
        };
    }

    pub fn defaultResolvable(self: *const Runtime) bool {
        self.assertMainThread();
        if (!self.store_healthy) return false;
        const authority = self.defaultAuthority() orelse return false;
        return switch (authority.source) {
            .metask => blk: {
                const intent = self.registry.metaskIntent() orelse break :blk false;
                break :blk self.metask_catalog_state == .ready and
                    self.metask_catalog.ownsSourceSelection(
                        intent.principal_ref,
                        intent.api_key_id,
                        intent.model_id,
                    ) and self.metask_catalog.selectedProtocol() == intent.protocol;
            },
            .model_connection => self.credential_vault != null and
                self.registry.defaultBinding() != null,
        };
    }

    pub fn metaskModelAvailable(
        self: *const Runtime,
        expected_catalog_generation: ?u64,
        protocol: contract.Protocol,
        model_id: []const u8,
    ) bool {
        self.assertMainThread();
        if (self.metask_catalog_state != .ready or
            self.metask_catalog.selectedProtocol() != protocol or
            !self.metask_catalog.hasModel(model_id))
            return false;
        if (expected_catalog_generation) |expected|
            return expected != 0 and expected == self.metask_catalog_generation;
        return true;
    }

    /// Validates one source-qualified member of the current Metask catalog.
    /// This is provider state only; callers decide what consumer operation the
    /// validated model may be used for.
    pub fn metaskSourceModelAvailable(
        self: *const Runtime,
        target: contract.ModelRef,
        expected_source_generation: u64,
        expected_catalog_generation: u64,
        protocol: contract.Protocol,
    ) bool {
        self.assertMainThread();
        const intent = self.registry.metaskIntent() orelse return false;
        if (intent.source_generation == 0 or
            intent.source_generation != expected_source_generation)
            return false;
        var source_storage: ["metask:".len + contract.Limits.api_key_id_bytes]u8 = undefined;
        const source_id = std.fmt.bufPrint(
            &source_storage,
            "metask:{s}",
            .{intent.api_key_id},
        ) catch return false;
        return std.mem.eql(u8, target.source_id, source_id) and
            self.metaskModelAvailable(
                expected_catalog_generation,
                protocol,
                target.model_id,
            );
    }

    pub fn submitCommand(self: *Runtime, command: contract.ModelConnectionCommand) contract.CommandResult {
        self.assertMainThread();
        contract.validateModelConnectionCommand(command) catch
            return .rejected(.invalid_connection);
        if (!self.store_healthy) return .rejected(.persistence_unavailable);
        var candidate = self.registry.clone() catch |err| return .rejected(mapRegistryError(err));
        defer candidate.deinit();
        switch (command) {
            .create => |value| {
                const connection_revision = self.freshGeneration(0) catch
                    return .rejected(.local_resource_exhausted);
                const source_generation = self.freshGeneration(connection_revision) catch
                    return .rejected(.local_resource_exhausted);
                const catalog_generation = self.freshGeneration(source_generation) catch
                    return .rejected(.local_resource_exhausted);
                candidate.create(value, connection_revision, source_generation, catalog_generation) catch |err|
                    return .rejected(mapRegistryError(err));
            },
            .update => |value| {
                const current = findConnectionView(candidate.views(), value.selection.source_id) orelse
                    return .rejected(.connection_not_found);
                const authority_changed = current.protocol != value.spec.protocol or
                    !std.mem.eql(u8, current.normalized_base_url, value.spec.normalized_base_url);
                const connection_revision = self.freshGeneration(current.connection_revision) catch
                    return .rejected(.local_resource_exhausted);
                const source_generation = if (authority_changed)
                    self.freshGeneration(candidate.sourceGenerationForConnection(current.id) orelse
                        return .rejected(.connection_not_found)) catch
                        return .rejected(.local_resource_exhausted)
                else
                    null;
                const selection_revision = if (authority_changed and isDefaultConnection(&candidate, current.id))
                    self.freshGeneration(candidate.selection_revision) catch
                        return .rejected(.local_resource_exhausted)
                else
                    null;
                candidate.update(value, connection_revision, source_generation, selection_revision) catch |err|
                    return .rejected(mapRegistryError(err));
            },
            .remove => |value| {
                const selection_revision = if (isDefaultConnection(&candidate, value.source_id))
                    self.freshGeneration(candidate.selection_revision) catch
                        return .rejected(.local_resource_exhausted)
                else
                    null;
                candidate.remove(value, selection_revision) catch |err|
                    return .rejected(mapRegistryError(err));
            },
            .test_connection => |value| candidate.markTesting(value) catch |err|
                return .rejected(mapRegistryError(err)),
            .add_custom_model => |value| {
                const current = findConnectionView(candidate.views(), value.source_id) orelse
                    return .rejected(.connection_not_found);
                const connection_revision = self.freshGeneration(current.connection_revision) catch
                    return .rejected(.local_resource_exhausted);
                const catalog_generation = self.freshGeneration(current.catalog_generation) catch
                    return .rejected(.local_resource_exhausted);
                candidate.addCustomModel(value, connection_revision, catalog_generation) catch |err|
                    return .rejected(mapRegistryError(err));
            },
            .replace_custom_model => |value| {
                const current = findConnectionView(candidate.views(), value.selection.source_id) orelse
                    return .rejected(.connection_not_found);
                const connection_revision = self.freshGeneration(current.connection_revision) catch
                    return .rejected(.local_resource_exhausted);
                const catalog_generation = self.freshGeneration(current.catalog_generation) catch
                    return .rejected(.local_resource_exhausted);
                const selection_revision = if (!std.mem.eql(
                    u8,
                    value.selection.model_id,
                    value.replacement.id,
                ) and isDefaultModel(&candidate, value.selection))
                    self.freshGeneration(candidate.selection_revision) catch
                        return .rejected(.local_resource_exhausted)
                else
                    null;
                candidate.replaceCustomModel(
                    value,
                    connection_revision,
                    catalog_generation,
                    selection_revision,
                ) catch |err| return .rejected(mapRegistryError(err));
            },
            .remove_custom_model => |value| {
                const current = findConnectionView(candidate.views(), value.selection.source_id) orelse
                    return .rejected(.connection_not_found);
                const connection_revision = self.freshGeneration(current.connection_revision) catch
                    return .rejected(.local_resource_exhausted);
                const catalog_generation = self.freshGeneration(current.catalog_generation) catch
                    return .rejected(.local_resource_exhausted);
                const selection_revision = if (isDefaultModel(&candidate, value.selection))
                    self.freshGeneration(candidate.selection_revision) catch
                        return .rejected(.local_resource_exhausted)
                else
                    null;
                candidate.removeCustomModel(
                    value,
                    connection_revision,
                    catalog_generation,
                    selection_revision,
                ) catch |err| return .rejected(mapRegistryError(err));
            },
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
        candidate.completeTest(command, succeeded) catch |err|
            return .rejected(mapRegistryError(err));
        return self.commitCandidate(&candidate, true);
    }

    pub fn clearDefault(self: *Runtime) contract.CommandResult {
        self.assertMainThread();
        if (!self.store_healthy) return .rejected(.persistence_unavailable);
        var candidate = self.registry.clone() catch |err| return .rejected(mapRegistryError(err));
        defer candidate.deinit();
        if (candidate.defaultSelection() == null) return .acceptedResult();
        const selection_revision = self.freshGeneration(candidate.selection_revision) catch
            return .rejected(.local_resource_exhausted);
        if (!candidate.clearDefault(selection_revision)) return .acceptedResult();
        return self.commitCandidate(&candidate, true);
    }

    pub fn createWithCredential(
        self: *Runtime,
        secret: []const u8,
        spec: contract.ModelConnectionSpec,
        model: contract.CustomModelInput,
    ) contract.CommandResult {
        self.assertMainThread();
        if (!self.store_healthy) return .rejected(.persistence_unavailable);
        contract.validateModelConnectionSpec(spec) catch return .rejected(.invalid_connection);
        contract.validateCustomModelInput(model) catch
            return .rejected(.invalid_connection);
        if (secret.len == 0 or secret.len > contract.Limits.credential_bytes)
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
        const connection_revision = self.freshGeneration(0) catch {
            self.drainCredentialCleanup();
            return .rejected(.local_resource_exhausted);
        };
        const source_generation = self.freshGeneration(connection_revision) catch {
            self.drainCredentialCleanup();
            return .rejected(.local_resource_exhausted);
        };
        const catalog_generation = self.freshGeneration(source_generation) catch {
            self.drainCredentialCleanup();
            return .rejected(.local_resource_exhausted);
        };
        committed.create(.{
            .connection_id = slot_id,
            .spec = spec,
            .credential_slot = .{ .id = slot_id },
            .model = model,
        }, connection_revision, source_generation, catalog_generation) catch |err| {
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

    /// Replaces a credential using a fail-closed two-commit transaction:
    /// first revoke durable readiness, then write the Host secret, and only
    /// then publish a fresh source authority. A partial failure therefore
    /// leaves a repairable non-runnable connection, never stale readiness.
    pub fn replaceCredential(
        self: *Runtime,
        secret: []const u8,
        selection: contract.ModelConnectionSelectionCommand,
    ) contract.CommandResult {
        self.assertMainThread();
        if (!self.store_healthy) return .rejected(.persistence_unavailable);
        if (secret.len == 0 or secret.len > contract.Limits.credential_bytes)
            return .rejected(.invalid_connection);
        const vault = self.credential_vault orelse return .rejected(.capture_unavailable);

        var revoked = self.registry.clone() catch
            return .rejected(.local_resource_exhausted);
        defer revoked.deinit();
        const clears_default = isDefaultConnection(&revoked, selection.source_id);
        const selection_revision = if (clears_default)
            self.freshGeneration(revoked.selection_revision) catch
                return .rejected(.local_resource_exhausted)
        else
            null;
        revoked.markCredentialMissing(selection, selection_revision) catch |err|
            return .rejected(mapRegistryError(err));
        const revoke_result = self.commitCandidate(&revoked, false);
        if (!revoke_result.accepted) return revoke_result;

        vault.store(selection.source_id, secret) catch
            return .rejected(.credential_write_failed);

        const current = findConnectionView(self.registry.views(), selection.source_id) orelse
            return .rejected(.connection_not_found);
        var restored = self.registry.clone() catch
            return .rejected(.local_resource_exhausted);
        defer restored.deinit();
        const connection_revision = self.freshGeneration(current.connection_revision) catch
            return .rejected(.local_resource_exhausted);
        const source_generation = self.freshGeneration(current.source_generation) catch
            return .rejected(.local_resource_exhausted);
        restored.restoreCredential(selection, connection_revision, source_generation) catch |err|
            return .rejected(mapRegistryError(err));
        return self.commitCandidate(&restored, true);
    }

    pub fn nextGeneration(self: *Runtime, current_generation: u64) !u64 {
        return self.freshGeneration(current_generation);
    }

    fn freshGeneration(self: *Runtime, current_generation: u64) !u64 {
        self.assertMainThread();
        while (true) {
            var bytes: [@sizeOf(u64)]u8 = undefined;
            try std.Io.randomSecure(self.io, &bytes);
            const generation = std.mem.readInt(u64, &bytes, .big);
            if (generation != 0 and generation != current_generation) return generation;
        }
    }

    fn clearMetaskRuntime(
        self: *Runtime,
        state: contract.CatalogState,
        error_code: contract.ModelsError,
    ) void {
        self.catalog_attempt = null;
        self.metask_catalog.deinit();
        self.metask_catalog = metask_provider.CatalogSession.init(self.allocator);
        if (self.metask_public_catalog) |public_catalog| public_catalog.clear();
        self.metask_catalog_generation = 0;
        self.metask_catalog_state = state;
        self.metask_error = error_code;
        self.metask_safe_diagnostic.len = 0;
    }

    pub fn resolveProbeCandidate(
        self: *Runtime,
        command: contract.ModelConnectionTestCommand,
    ) !contract.OwnedSourceCandidate {
        self.assertMainThread();
        return self.resolveBindingCandidate(
            try self.registry.probeBinding(command),
        );
    }

    /// Resolves the current durable Models default without assigning a
    /// Product binding generation. Product Control owns that installation
    /// identity and may accept, replace, or destroy this candidate.
    pub fn resolveDefault(self: *Runtime) !?contract.OwnedSourceCandidate {
        self.assertMainThread();
        const selection = self.registry.defaultSelection() orelse return null;
        if (self.registry.metaskIntent()) |intent| {
            var source_storage: ["metask:".len + contract.Limits.api_key_id_bytes]u8 = undefined;
            const source_id = std.fmt.bufPrint(
                &source_storage,
                "metask:{s}",
                .{intent.api_key_id},
            ) catch return error.InvalidConnection;
            if (std.mem.eql(u8, selection.source_id, source_id)) {
                if (!std.mem.eql(u8, selection.model_id, intent.model_id) or
                    intent.protocol == null or intent.source_generation == 0 or
                    self.metask_catalog_state != .ready or
                    !self.metask_catalog.ownsSourceSelection(
                        intent.principal_ref,
                        intent.api_key_id,
                        intent.model_id,
                    ) or self.metask_catalog.selectedProtocol() != intent.protocol)
                    return null;
                return self.metask_catalog.prepareSourceCandidate(
                    intent.model_id,
                    intent.source_generation,
                ) catch |err| return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => error.InvalidConnection,
                };
            }
        }

        const binding = self.registry.defaultBinding() orelse return null;
        return self.resolveBindingCandidate(binding) catch |err| {
            if (err == error.CredentialNotFound) {
                self.markCredentialMissing(binding);
                return null;
            }
            return err;
        };
    }

    fn resolveBindingCandidate(
        self: *Runtime,
        binding: registry_impl.Registry.DefaultBinding,
    ) !contract.OwnedSourceCandidate {
        const vault = self.credential_vault orelse return error.CredentialStoreUnavailable;
        var secret_storage: [contract.Limits.credential_bytes]u8 = undefined;
        defer std.crypto.secureZero(u8, &secret_storage);
        const secret = (try vault.get(binding.connection_id, &secret_storage)) orelse
            return error.CredentialNotFound;
        const model_id = try self.allocator.dupe(u8, binding.model_id);
        errdefer self.allocator.free(model_id);
        const normalized_base_url = try self.allocator.dupe(u8, binding.normalized_base_url);
        errdefer self.allocator.free(normalized_base_url);
        const credential = try self.allocator.dupe(u8, secret);
        errdefer {
            std.crypto.secureZero(u8, credential);
            self.allocator.free(credential);
        }
        return contract.OwnedSourceCandidate.initOwned(
            self.allocator,
            .model_connection,
            binding.protocol,
            model_id,
            normalized_base_url,
            binding.source_generation,
            credential,
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
        const bytes = bytes_optional orelse {
            self.migrateLegacyStores();
            return;
        };
        defer self.allocator.free(bytes);
        var restored = registry_impl.decode(self.allocator, bytes) catch {
            self.store_healthy = false;
            return;
        };
        self.installRestored(&restored);
    }

    fn installRestored(self: *Runtime, restored: *registry_impl.Registry) void {
        if (restored.reconcileInterruptedTests()) {
            const reconciled = registry_impl.encodeAlloc(self.allocator, restored) catch {
                self.store_healthy = false;
                self.registry.replace(restored);
                restored.deinit();
                return;
            };
            defer self.allocator.free(reconciled);
            if (!self.commitVerified(reconciled)) {
                self.store_healthy = false;
            }
        }
        self.registry.replace(restored);
        restored.deinit();
        self.drainCredentialCleanup();
    }

    fn migrateLegacyStores(self: *Runtime) void {
        var candidate = registry_impl.Registry.init(self.allocator);
        defer candidate.deinit();
        const store = if (self.store) |*value| value else {
            self.store_healthy = false;
            return;
        };

        var connection_sector_valid = false;
        const connection_bytes = store.loadNamedAlloc(
            self.allocator,
            registry_impl.legacy_connection_store_file_name,
            registry_impl.max_store_bytes,
        ) catch blk: {
            candidate.connections_recovery_required = true;
            break :blk null;
        };
        if (connection_bytes) |bytes| {
            defer self.allocator.free(bytes);
            var legacy: ?registry_impl.Registry = legacy_decode: {
                const decoded = registry_impl.decodeLegacy(self.allocator, bytes) catch {
                    candidate.connections_recovery_required = true;
                    break :legacy_decode null;
                };
                break :legacy_decode decoded;
            };
            if (legacy) |*decoded| {
                candidate.replace(decoded);
                decoded.deinit();
                connection_sector_valid = true;
            }
        }

        var prior_generation: u64 = 0;
        for (0..candidate.connectionCount()) |index| {
            const source_generation = self.freshGeneration(prior_generation) catch {
                self.store_healthy = false;
                return;
            };
            const catalog_generation = self.freshGeneration(source_generation) catch {
                self.store_healthy = false;
                return;
            };
            candidate.reseedLegacyConnection(index, source_generation, catalog_generation) catch {
                self.store_healthy = false;
                return;
            };
            prior_generation = catalog_generation;
        }

        var preference_sector_valid = false;
        const preference_bytes = store.loadNamedAlloc(
            self.allocator,
            registry_impl.legacy_preference_store_file_name,
            registry_impl.legacy_preference_bytes,
        ) catch blk: {
            candidate.preference_recovery_required = true;
            break :blk null;
        };
        if (preference_bytes) |bytes| {
            defer self.allocator.free(bytes);
            var preference: ?registry_impl.LegacyPreference = preference_decode: {
                const decoded = registry_impl.decodeLegacyPreference(self.allocator, bytes) catch {
                    candidate.preference_recovery_required = true;
                    break :preference_decode null;
                };
                break :preference_decode decoded;
            };
            if (preference) |*value| {
                defer value.deinit();
                const metask_selection_revision = self.freshGeneration(prior_generation) catch {
                    self.store_healthy = false;
                    return;
                };
                candidate.configureMetask(
                    value.principal_ref,
                    value.api_key_id,
                    value.model_id,
                    null,
                    0,
                    metask_selection_revision,
                    null,
                ) catch {
                    self.store_healthy = false;
                    return;
                };
                prior_generation = metask_selection_revision;
                preference_sector_valid = true;
            }
        }

        if (candidate.defaultSelection() != null) {
            const revision = self.freshGeneration(prior_generation) catch {
                self.store_healthy = false;
                return;
            };
            candidate.activateMigratedDefault(revision) catch {
                self.store_healthy = false;
                return;
            };
        } else if (preference_sector_valid and !candidate.connections_recovery_required) {
            const revision = self.freshGeneration(prior_generation) catch {
                self.store_healthy = false;
                return;
            };
            candidate.selectMetaskDefault(revision) catch {
                self.store_healthy = false;
                return;
            };
        } else if (candidate.preference_recovery_required or
            candidate.connections_recovery_required)
        {
            candidate.default_migration_required = true;
            candidate.selection_revision = self.freshGeneration(prior_generation) catch {
                self.store_healthy = false;
                return;
            };
        }

        const encoded = registry_impl.encodeAlloc(self.allocator, &candidate) catch {
            self.store_healthy = false;
            return;
        };
        defer self.allocator.free(encoded);
        if (!self.commitVerified(encoded)) {
            self.store_healthy = false;
            return;
        }
        self.registry.replace(&candidate);
        if (connection_sector_valid) store.archiveLegacy(
            registry_impl.legacy_connection_store_file_name,
            registry_impl.legacy_connection_store_file_name ++ ".migrated",
        );
        if (preference_sector_valid) store.archiveLegacy(
            registry_impl.legacy_preference_store_file_name,
            registry_impl.legacy_preference_store_file_name ++ ".migrated",
        );
        self.drainCredentialCleanup();
    }

    fn commitVerified(self: *Runtime, bytes: []const u8) bool {
        const store = if (self.store) |*value| value else return false;
        store.commit(bytes) catch |err| {
            if (err != error.PersistenceOutcomeUnknown) return false;
            const loaded = store.loadAlloc(self.allocator) catch return false;
            const actual = loaded orelse return false;
            defer self.allocator.free(actual);
            return std.mem.eql(u8, actual, bytes);
        };
        return true;
    }

    fn markCredentialMissing(self: *Runtime, binding: registry_impl.Registry.DefaultBinding) void {
        var candidate = self.registry.clone() catch {
            self.store_healthy = false;
            return;
        };
        defer candidate.deinit();
        const selection_revision = self.freshGeneration(candidate.selection_revision) catch {
            self.store_healthy = false;
            return;
        };
        candidate.markCredentialMissing(.{
            .source_id = binding.connection_id,
            .expected_connection_revision = binding.connection_revision,
        }, selection_revision) catch {
            self.store_healthy = false;
            return;
        };
        if (!self.commitCandidate(&candidate, false).accepted) {
            self.store_healthy = false;
        }
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

fn mapModelsError(error_code: contract.ModelsError) contract.ManagementError {
    return switch (error_code) {
        .none => unreachable,
        .authorization_unavailable => .authorization_unavailable,
        .persistence_unavailable, .migration_required => .persistence_unavailable,
        .operation_in_progress => .operation_in_progress,
        .local_resource_exhausted => .local_resource_exhausted,
        .catalog_unavailable,
        .catalog_invalid,
        .catalog_too_large,
        .no_api_keys,
        .no_models,
        => .catalog_unavailable,
    };
}

fn findConnectionView(
    views: []const contract.ModelConnectionView,
    connection_id: []const u8,
) ?contract.ModelConnectionView {
    for (views) |view|
        if (std.mem.eql(u8, view.id, connection_id)) return view;
    return null;
}

fn isDefaultConnection(registry: *const registry_impl.Registry, connection_id: []const u8) bool {
    const selection = registry.defaultSelection() orelse return false;
    return std.mem.eql(u8, selection.source_id, connection_id);
}

fn isDefaultModel(registry: *const registry_impl.Registry, model: contract.ModelRef) bool {
    const selection = registry.defaultSelection() orelse return false;
    return std.mem.eql(u8, selection.source_id, model.source_id) and
        std.mem.eql(u8, selection.model_id, model.model_id);
}

fn metaskSourceMatches(source_id: []const u8, api_key_id: []const u8) bool {
    var storage: ["metask:".len + contract.Limits.api_key_id_bytes]u8 = undefined;
    const expected = std.fmt.bufPrint(
        &storage,
        "metask:{s}",
        .{api_key_id},
    ) catch return false;
    return std.mem.eql(u8, source_id, expected);
}

const TestVault = struct {
    const slot = "model-connection-00000000000000000000000000000001";

    secret: [contract.Limits.credential_bytes]u8 = undefined,
    secret_len: usize = 0,
    present: bool = false,
    fail_store: bool = false,

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
        if (self.fail_store) return error.WriteFailed;
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

test "Models Runtime owns durable model connections and source resolution" {
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
            .{ .id = "gpt-5", .display_name = "GPT-5" },
        ).accepted);
        const view = runtime.views()[0];
        try std.testing.expectEqualStrings(TestVault.slot, view.id);
        const selection: contract.ModelConnectionSelectionCommand = .{
            // Registry views are borrowed until the next committed mutation.
            // Commands arrive with independently owned request bytes in
            // production, so keep this test selection independently stable.
            .source_id = TestVault.slot,
            .expected_connection_revision = view.connection_revision,
        };
        try std.testing.expect(runtime.submitCommand(.{ .test_connection = .{
            .model = .{ .source_id = selection.source_id, .model_id = "gpt-5" },
            .expected_connection_revision = selection.expected_connection_revision,
            .expected_source_generation = view.source_generation,
            .expected_catalog_generation = view.catalog_generation,
        } }).accepted);
        try std.testing.expect(runtime.completeTest(.{
            .model = .{ .source_id = selection.source_id, .model_id = "gpt-5" },
            .expected_connection_revision = selection.expected_connection_revision,
            .expected_source_generation = view.source_generation,
            .expected_catalog_generation = view.catalog_generation,
        }, true).accepted);
        const connection = runtime.views()[0];
        try std.testing.expect(runtime.selectDefault(.{
            .selection = .{ .source_id = selection.source_id, .model_id = "gpt-5" },
            .expected_selection_revision = runtime.view().selection_revision,
            .expected_source_generation = connection.source_generation,
            .expected_catalog_generation = connection.catalog_generation,
        }).accepted);
        const authority = runtime.defaultAuthority() orelse
            return error.TestUnexpectedResult;
        try std.testing.expectEqual(contract.Source.model_connection, authority.source);
        try std.testing.expectEqualStrings(TestVault.slot, authority.selection.source_id);
        try std.testing.expectEqualStrings("gpt-5", authority.selection.model_id);
        try std.testing.expect(authority.source_generation != 0);
        try std.testing.expect(authority.selection_revision != 0);
        var candidate = (try runtime.resolveDefault()) orelse
            return error.TestUnexpectedResult;
        defer candidate.deinit();
        try std.testing.expectEqualStrings("provider-secret", candidate.input().api_key);
        try std.testing.expectEqual(contract.Protocol.openai_responses, candidate.input().target.protocol);
        try std.testing.expectEqual(authority.source_generation, candidate.input().source_generation);
    }

    {
        var restored = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
        try restored.start(directory, vault.port());
        defer {
            restored.stop();
            restored.deinit();
        }
        try std.testing.expectEqual(@as(usize, 1), restored.views().len);
        {
            var candidate = (try restored.resolveDefault()) orelse
                return error.TestUnexpectedResult;
            defer candidate.deinit();
            try std.testing.expectEqualStrings("provider-secret", candidate.input().api_key);
            try std.testing.expectEqualStrings("model_connection:" ++ TestVault.slot, candidate.input().target.provider_id);
        }

        const previous_selection_revision = restored.view().selection_revision;
        try TestVault.delete(&vault, TestVault.slot);
        try std.testing.expect((try restored.resolveDefault()) == null);
        try std.testing.expect(restored.store_healthy);
        try std.testing.expect(restored.defaultAuthority() == null);
        try std.testing.expect(restored.view().default_selection == null);
        try std.testing.expect(restored.view().selection_revision != previous_selection_revision);
        const missing = restored.views()[0];
        try std.testing.expectEqual(
            contract.ModelConnectionCredentialStatus.missing,
            missing.credential_status,
        );
        try std.testing.expectEqual(contract.ModelConnectionState.configuring, missing.state);
    }

    {
        var restarted = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
        try restarted.start(directory, vault.port());
        defer {
            restarted.stop();
            restarted.deinit();
        }
        try std.testing.expect(restarted.store_healthy);
        try std.testing.expectEqual(@as(usize, 1), restarted.views().len);
        try std.testing.expect(restarted.defaultAuthority() == null);
        try std.testing.expect(restarted.view().default_selection == null);
        const missing = restarted.views()[0];
        try std.testing.expectEqual(
            contract.ModelConnectionCredentialStatus.missing,
            missing.credential_status,
        );
        try std.testing.expectEqual(contract.ModelConnectionState.configuring, missing.state);
    }
}

test "credential replacement revokes readiness before writing and restores fresh authority" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var directory_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory_len = try tmp.dir.realPath(std.testing.io, &directory_storage);
    const directory = directory_storage[0..directory_len];
    var vault: TestVault = .{};

    var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
    try runtime.start(directory, vault.port());
    defer {
        runtime.stop();
        runtime.deinit();
    }
    try std.testing.expect(runtime.createWithCredential(
        "old-secret",
        .{
            .display_name = "Provider",
            .protocol = .openai_responses,
            .normalized_base_url = "https://api.example.com/v1/responses",
        },
        .{ .id = "model-1", .display_name = "Model 1" },
    ).accepted);
    const initial = runtime.views()[0];
    const selection: contract.ModelConnectionSelectionCommand = .{
        .source_id = TestVault.slot,
        .expected_connection_revision = initial.connection_revision,
    };
    try std.testing.expect(runtime.submitCommand(.{ .test_connection = .{
        .model = .{ .source_id = TestVault.slot, .model_id = "model-1" },
        .expected_connection_revision = initial.connection_revision,
        .expected_source_generation = initial.source_generation,
        .expected_catalog_generation = initial.catalog_generation,
    } }).accepted);
    try std.testing.expect(runtime.completeTest(.{
        .model = .{ .source_id = TestVault.slot, .model_id = "model-1" },
        .expected_connection_revision = initial.connection_revision,
        .expected_source_generation = initial.source_generation,
        .expected_catalog_generation = initial.catalog_generation,
    }, true).accepted);
    const ready = runtime.views()[0];
    try std.testing.expect(runtime.selectDefault(.{
        .selection = .{ .source_id = TestVault.slot, .model_id = "model-1" },
        .expected_selection_revision = runtime.view().selection_revision,
        .expected_source_generation = ready.source_generation,
        .expected_catalog_generation = ready.catalog_generation,
    }).accepted);

    vault.fail_store = true;
    const failed = runtime.replaceCredential("new-secret", selection);
    try std.testing.expect(!failed.accepted);
    try std.testing.expectEqual(contract.ManagementError.credential_write_failed, failed.error_code.?);
    try std.testing.expect(runtime.view().default_selection == null);
    const revoked = runtime.views()[0];
    try std.testing.expectEqual(contract.ModelConnectionCredentialStatus.missing, revoked.credential_status);
    try std.testing.expectEqual(contract.ModelConnectionState.configuring, revoked.state);
    try std.testing.expect(!revoked.models[0].ready);

    vault.fail_store = false;
    try std.testing.expect(runtime.replaceCredential("new-secret", .{
        .source_id = TestVault.slot,
        .expected_connection_revision = revoked.connection_revision,
    }).accepted);
    const restored = runtime.views()[0];
    try std.testing.expectEqual(contract.ModelConnectionCredentialStatus.ready, restored.credential_status);
    try std.testing.expectEqual(contract.ModelConnectionState.configuring, restored.state);
    try std.testing.expect(restored.connection_revision != initial.connection_revision);
    try std.testing.expect(restored.source_generation != initial.source_generation);
    try std.testing.expectEqualStrings("new-secret", vault.secret[0..vault.secret_len]);
}

test "Models owns Metask catalog authority without changing global default" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var directory_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory_len = try tmp.dir.realPath(std.testing.io, &directory_storage);
    const directory = directory_storage[0..directory_len];
    var vault: TestVault = .{};
    var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
    try runtime.start(directory, vault.port());
    defer {
        runtime.stop();
        runtime.deinit();
    }

    const prepared = switch (runtime.prepareMetaskCatalogRefresh("principal-1", 5)) {
        .ready => |value| value,
        .rejected => return error.TestUnexpectedResult,
    };
    var catalog = metask_provider.CatalogSession.init(std.testing.allocator);
    try metask_provider.TestSupport.replaceOwnedSelection(
        &catalog,
        "principal-1",
        .{
            .id = "api-1",
            .name = "Primary",
            .suffix = "1234",
            .protocol = .anthropic_messages,
        },
        "model-secret",
        &.{.{ .id = "model-1", .display_name = "Model One" }},
    );
    try metask_provider.TestSupport.appendOwnedApiKey(
        &catalog,
        .{
            .id = "api-2",
            .name = "Secondary",
            .suffix = "5678",
            .protocol = .openai_responses,
        },
        "secondary-secret",
    );
    var completion = try metask_provider.OwnedCatalogCompletion.init(
        std.testing.allocator,
        &catalog,
        "model-1",
    );
    var completion_port = completion.ownedPort();
    try std.testing.expectEqual(
        contract.ModelsError.none,
        runtime.completeMetaskCatalogRefresh(
            prepared.attempt_id,
            prepared.authorization_generation,
            &completion_port,
        ),
    );

    const first = runtime.view();
    try std.testing.expectEqual(contract.CatalogState.ready, first.providers[0].catalog_state);
    try std.testing.expectEqualStrings("principal-1", first.providers[0].principal_ref);
    try std.testing.expectEqualStrings("api-1", first.providers[0].selected_api_key_id);
    try std.testing.expectEqualStrings("model-1", first.metask_selection.?.model_id);
    try std.testing.expect(first.providers[0].source_generation != 0);
    try std.testing.expect(first.metask_selection_revision != 0);
    try std.testing.expect(first.default_selection == null);
    const first_source_generation = first.providers[0].source_generation;
    const first_selection_revision = first.metask_selection_revision;
    const first_catalog_generation = first.providers[0].catalog_generation;

    try std.testing.expect(runtime.prepareMetaskApiKeySelection(
        "principal-1",
        6,
        .{
            .source_id = "metask:api-2",
            .expected_metask_selection_revision = first_selection_revision +% 1,
            .expected_catalog_generation = first_catalog_generation,
        },
    ) == .rejected);
    const key_switch = switch (runtime.prepareMetaskApiKeySelection(
        "principal-1",
        6,
        .{
            .source_id = "metask:api-2",
            .expected_metask_selection_revision = first_selection_revision,
            .expected_catalog_generation = first_catalog_generation,
        },
    )) {
        .ready => |value| value,
        .rejected => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("api-2", key_switch.required_api_key_id);
    try std.testing.expectEqualStrings("", key_switch.preferred_model_id);
    runtime.failMetaskCatalogRefresh(
        key_switch.attempt_id,
        key_switch.authorization_generation,
        .catalog_invalid,
        "",
    );

    const refreshed = switch (runtime.prepareMetaskCatalogRefresh("principal-1", 6)) {
        .ready => |value| value,
        .rejected => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("api-1", refreshed.preferred_api_key_id);
    try std.testing.expectEqualStrings("model-1", refreshed.preferred_model_id);
    var same_catalog = metask_provider.CatalogSession.init(std.testing.allocator);
    try metask_provider.TestSupport.replaceOwnedSelection(
        &same_catalog,
        "principal-1",
        .{
            .id = "api-1",
            .name = "Primary",
            .suffix = "1234",
            .protocol = .anthropic_messages,
        },
        "rotated-model-secret",
        &.{.{ .id = "model-1", .display_name = "Model One" }},
    );
    var refreshed_completion = try metask_provider.OwnedCatalogCompletion.init(
        std.testing.allocator,
        &same_catalog,
        "model-1",
    );
    var refreshed_completion_port = refreshed_completion.ownedPort();
    try std.testing.expectEqual(
        contract.ModelsError.none,
        runtime.completeMetaskCatalogRefresh(
            refreshed.attempt_id,
            refreshed.authorization_generation,
            &refreshed_completion_port,
        ),
    );
    const second = runtime.view();
    try std.testing.expectEqual(first_source_generation, second.providers[0].source_generation);
    try std.testing.expectEqual(first_selection_revision, second.metask_selection_revision);
    try std.testing.expect(first_catalog_generation != second.providers[0].catalog_generation);

    try std.testing.expect(runtime.selectMetaskDefault(.{
        .selection = .{
            .source_id = "metask:api-1",
            .model_id = "model-1",
        },
        .expected_selection_revision = second.selection_revision,
        .expected_source_generation = second.providers[0].source_generation,
        .expected_catalog_generation = second.providers[0].catalog_generation,
    }).accepted);
    const default_authority = runtime.defaultAuthority() orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(contract.Source.metask, default_authority.source);
    try std.testing.expectEqualStrings(
        "metask:api-1",
        default_authority.selection.source_id,
    );
    try std.testing.expectEqualStrings("model-1", default_authority.selection.model_id);
    try std.testing.expectEqual(first_source_generation, default_authority.source_generation);
    var first_candidate = (try runtime.resolveDefault()) orelse
        return error.TestUnexpectedResult;
    defer first_candidate.deinit();
    var second_candidate = (try runtime.resolveDefault()) orelse
        return error.TestUnexpectedResult;
    defer second_candidate.deinit();
    try std.testing.expectEqualStrings(
        "rotated-model-secret",
        first_candidate.input().api_key,
    );
    try std.testing.expectEqualStrings(
        "rotated-model-secret",
        second_candidate.input().api_key,
    );
    try std.testing.expectEqual(
        first_source_generation,
        second_candidate.input().source_generation,
    );

    runtime.setMetaskAuthorizationUnavailable();
    const unavailable = runtime.view();
    try std.testing.expectEqual(
        contract.CatalogState.needs_authentication,
        unavailable.providers[0].catalog_state,
    );
    try std.testing.expectEqual(@as(usize, 0), unavailable.providers[0].models.len);
    try std.testing.expectEqualStrings("model-1", unavailable.metask_selection.?.model_id);
    try std.testing.expect(!runtime.defaultResolvable());
    try std.testing.expect((try runtime.resolveDefault()) == null);
}

test "Metask catalog drift keeps a tracked global default durable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var directory_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory_len = try tmp.dir.realPath(std.testing.io, &directory_storage);
    const directory = directory_storage[0..directory_len];
    var vault: TestVault = .{};
    var committed_selection_revision: u64 = 0;

    {
        var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
        try runtime.start(directory, vault.port());
        defer {
            runtime.stop();
            runtime.deinit();
        }

        const initial = switch (runtime.prepareMetaskCatalogRefresh("principal-1", 5)) {
            .ready => |value| value,
            .rejected => return error.TestUnexpectedResult,
        };
        var initial_catalog = metask_provider.CatalogSession.init(std.testing.allocator);
        defer initial_catalog.deinit();
        try metask_provider.TestSupport.replaceOwnedSelection(
            &initial_catalog,
            "principal-1",
            .{
                .id = "api-1",
                .name = "Primary",
                .suffix = "1111",
                .protocol = .anthropic_messages,
            },
            "initial-secret",
            &.{.{ .id = "model-1", .display_name = "Model One" }},
        );
        var initial_completion = try metask_provider.OwnedCatalogCompletion.init(
            std.testing.allocator,
            &initial_catalog,
            "model-1",
        );
        var initial_completion_port = initial_completion.ownedPort();
        try std.testing.expectEqual(
            contract.ModelsError.none,
            runtime.completeMetaskCatalogRefresh(
                initial.attempt_id,
                initial.authorization_generation,
                &initial_completion_port,
            ),
        );
        const initial_view = runtime.view();
        try std.testing.expect(runtime.selectMetaskDefault(.{
            .selection = .{ .source_id = "metask:api-1", .model_id = "model-1" },
            .expected_selection_revision = initial_view.selection_revision,
            .expected_source_generation = initial_view.providers[0].source_generation,
            .expected_catalog_generation = initial_view.providers[0].catalog_generation,
        }).accepted);
        const previous_selection_revision = runtime.view().selection_revision;

        const refresh = switch (runtime.prepareMetaskCatalogRefresh("principal-1", 6)) {
            .ready => |value| value,
            .rejected => return error.TestUnexpectedResult,
        };
        try std.testing.expectEqualStrings("api-1", refresh.preferred_api_key_id);
        try std.testing.expectEqualStrings("model-1", refresh.preferred_model_id);
        var replacement_catalog = metask_provider.CatalogSession.init(std.testing.allocator);
        defer replacement_catalog.deinit();
        try metask_provider.TestSupport.replaceOwnedSelection(
            &replacement_catalog,
            "principal-1",
            .{
                .id = "api-2",
                .name = "Replacement",
                .suffix = "2222",
                .protocol = .openai_responses,
            },
            "replacement-secret",
            &.{.{ .id = "model-2", .display_name = "Model Two" }},
        );
        var replacement_completion = try metask_provider.OwnedCatalogCompletion.init(
            std.testing.allocator,
            &replacement_catalog,
            "model-2",
        );
        var replacement_completion_port = replacement_completion.ownedPort();
        try std.testing.expectEqual(
            contract.ModelsError.none,
            runtime.completeMetaskCatalogRefresh(
                refresh.attempt_id,
                refresh.authorization_generation,
                &replacement_completion_port,
            ),
        );

        const drifted = runtime.view();
        try std.testing.expect(runtime.store_healthy);
        try std.testing.expectEqualStrings("api-2", drifted.providers[0].selected_api_key_id);
        try std.testing.expectEqualStrings("metask:api-2", drifted.metask_selection.?.source_id);
        try std.testing.expectEqualStrings("model-2", drifted.metask_selection.?.model_id);
        try std.testing.expectEqualStrings("metask:api-2", drifted.default_selection.?.source_id);
        try std.testing.expectEqualStrings("model-2", drifted.default_selection.?.model_id);
        try std.testing.expect(drifted.selection_revision != previous_selection_revision);
        committed_selection_revision = drifted.selection_revision;
    }

    {
        var restarted = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
        try restarted.start(directory, vault.port());
        defer {
            restarted.stop();
            restarted.deinit();
        }
        try std.testing.expect(restarted.store_healthy);
        const restored = restarted.view();
        try std.testing.expectEqualStrings("metask:api-2", restored.metask_selection.?.source_id);
        try std.testing.expectEqualStrings("model-2", restored.metask_selection.?.model_id);
        try std.testing.expectEqualStrings("metask:api-2", restored.default_selection.?.source_id);
        try std.testing.expectEqualStrings("model-2", restored.default_selection.?.model_id);
        try std.testing.expectEqual(committed_selection_revision, restored.selection_revision);
    }
}

test "Models bootstrap migrates both legacy stores with custom default precedence" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var directory_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory_len = try tmp.dir.realPath(std.testing.io, &directory_storage);
    const directory = directory_storage[0..directory_len];

    var legacy = registry_impl.Registry.init(std.testing.allocator);
    defer legacy.deinit();
    try legacy.create(.{
        .connection_id = "legacy-slot",
        .spec = .{
            .display_name = "Legacy",
            .protocol = .openai_responses,
            .normalized_base_url = "https://api.openai.com/v1/responses",
        },
        .credential_slot = .{ .id = "legacy-slot" },
        .model = .{ .id = "gpt-5" },
    }, 7, 8, 9);
    const legacy_selection: contract.ModelConnectionSelectionCommand = .{
        .source_id = "legacy-slot",
        .expected_connection_revision = 7,
    };
    const legacy_probe: contract.ModelConnectionTestCommand = .{
        .model = .{ .source_id = "legacy-slot", .model_id = "gpt-5" },
        .expected_connection_revision = 7,
        .expected_source_generation = 8,
        .expected_catalog_generation = 9,
    };
    try legacy.markTesting(legacy_probe);
    try legacy.completeTest(legacy_probe, true);
    try legacy.selectDefault(legacy_selection, "gpt-5", 11);
    const connection_bytes = try registry_impl.encodeLegacyAlloc(std.testing.allocator, &legacy);
    defer std.testing.allocator.free(connection_bytes);
    try writeTestFile(&tmp.dir, registry_impl.legacy_connection_store_file_name, connection_bytes);
    try writeTestFile(
        &tmp.dir,
        registry_impl.legacy_preference_store_file_name,
        "{\"selection_owner_account_id\":\"principal-1\",\"api_key_id\":\"api-1\",\"model_id\":\"metask-model\",\"metask_source_generation\":13}",
    );

    var vault: TestVault = .{};
    var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
    try runtime.start(directory, vault.port());
    defer {
        runtime.stop();
        runtime.deinit();
    }
    try std.testing.expect(runtime.store_healthy);
    const default_selection = runtime.registry.defaultSelection() orelse
        return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("legacy-slot", default_selection.source_id);
    try std.testing.expectEqualStrings("gpt-5", default_selection.model_id);
    const metask = runtime.registry.metaskIntent() orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("principal-1", metask.principal_ref);
    try std.testing.expectEqualStrings("api-1", metask.api_key_id);
    try std.testing.expect(metask.protocol == null);
    try std.testing.expectEqual(@as(u64, 0), metask.source_generation);
    try std.testing.expect(runtime.registry.sourceGenerationForConnection("legacy-slot").? != 7);
    try std.testing.expect(!runtime.registry.preference_recovery_required);
    try std.testing.expect(!runtime.registry.connections_recovery_required);
    try std.testing.expect(!runtime.registry.default_migration_required);
}

test "Models bootstrap isolates damaged connection sector from valid Metask intent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var directory_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory_len = try tmp.dir.realPath(std.testing.io, &directory_storage);
    const directory = directory_storage[0..directory_len];
    try writeTestFile(
        &tmp.dir,
        registry_impl.legacy_connection_store_file_name,
        "not-json",
    );
    try writeTestFile(
        &tmp.dir,
        registry_impl.legacy_preference_store_file_name,
        "{\"selection_owner_account_id\":\"principal-1\",\"api_key_id\":\"api-1\",\"model_id\":\"metask-model\",\"metask_source_generation\":13}",
    );

    var vault: TestVault = .{};
    var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
    try runtime.start(directory, vault.port());
    defer {
        runtime.stop();
        runtime.deinit();
    }
    try std.testing.expect(runtime.store_healthy);
    try std.testing.expect(runtime.registry.metaskIntent() != null);
    try std.testing.expect(runtime.registry.defaultSelection() == null);
    try std.testing.expect(runtime.registry.connections_recovery_required);
    try std.testing.expect(!runtime.registry.preference_recovery_required);
    try std.testing.expect(runtime.registry.default_migration_required);
    try std.testing.expect(runtime.registry.selection_revision != 0);
}

test "Models bootstrap preserves proven custom default when preference sector is damaged" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var directory_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory_len = try tmp.dir.realPath(std.testing.io, &directory_storage);
    const directory = directory_storage[0..directory_len];

    var legacy = registry_impl.Registry.init(std.testing.allocator);
    defer legacy.deinit();
    try legacy.create(.{
        .connection_id = "legacy-slot",
        .spec = .{
            .display_name = "Legacy",
            .protocol = .openai_responses,
            .normalized_base_url = "https://api.openai.com/v1/responses",
        },
        .credential_slot = .{ .id = "legacy-slot" },
        .model = .{ .id = "gpt-5" },
    }, 7, 8, 9);
    const legacy_selection: contract.ModelConnectionSelectionCommand = .{
        .source_id = "legacy-slot",
        .expected_connection_revision = 7,
    };
    const legacy_probe: contract.ModelConnectionTestCommand = .{
        .model = .{ .source_id = "legacy-slot", .model_id = "gpt-5" },
        .expected_connection_revision = 7,
        .expected_source_generation = 8,
        .expected_catalog_generation = 9,
    };
    try legacy.markTesting(legacy_probe);
    try legacy.completeTest(legacy_probe, true);
    try legacy.selectDefault(legacy_selection, "gpt-5", 11);
    const connection_bytes = try registry_impl.encodeLegacyAlloc(std.testing.allocator, &legacy);
    defer std.testing.allocator.free(connection_bytes);
    try writeTestFile(&tmp.dir, registry_impl.legacy_connection_store_file_name, connection_bytes);
    try writeTestFile(&tmp.dir, registry_impl.legacy_preference_store_file_name, "not-json");

    var vault: TestVault = .{};
    var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
    try runtime.start(directory, vault.port());
    defer {
        runtime.stop();
        runtime.deinit();
    }
    try std.testing.expect(runtime.store_healthy);
    try std.testing.expect(runtime.registry.defaultSelection() != null);
    try std.testing.expect(runtime.registry.preference_recovery_required);
    try std.testing.expect(!runtime.registry.connections_recovery_required);
    try std.testing.expect(!runtime.registry.default_migration_required);
}

fn writeTestFile(dir: *std.Io.Dir, name: []const u8, bytes: []const u8) !void {
    const file = try dir.createFile(std.testing.io, name, .{ .exclusive = true });
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, bytes);
    try file.sync(std.testing.io);
}
