//! Product Models runtime owned by Product Control.

const std = @import("std");
const builtin = @import("builtin");
const contract = @import("metawork_product_models_contract");
const ports = @import("product_models_ports");
const registry_impl = @import("product_models_providers");
const metask_provider = @import("product_models_metask");
const builtin_providers = @import("product_models_builtin_providers");

pub const StartError = error{
    CustomProvidersDirectoryUnavailable,
    ModelsStateUnavailable,
};
pub const DefaultBinding = registry_impl.Registry.DefaultBinding;

pub const TestSupport = if (builtin.is_test) struct {
    pub fn refreshMetaskCatalog(
        runtime: *Runtime,
        principal_ref: []const u8,
        models: []const contract.ModelView,
    ) !contract.ModelsError {
        const preparation = switch (runtime.prepareMetaskCatalogRefresh(principal_ref, 17)) {
            .ready => |value| value,
            .rejected => return error.TestUnexpectedResult,
        };
        var session = metask_provider.CatalogSession.init(runtime.allocator);
        defer session.deinit();
        try metask_provider.TestSupport.replaceOwnedCatalog(
            &session,
            principal_ref,
            "refreshed-secret",
            models,
        );
        var completion = metask_provider.OwnedCatalogCompletion.init(&session);
        var port = completion.ownedPort();
        return runtime.completeMetaskCatalogRefresh(
            preparation.attempt_id,
            preparation.authorization_generation,
            &port,
        );
    }

    pub fn refreshMetaskCatalogResponse(
        runtime: *Runtime,
        principal_ref: []const u8,
        response_body: []const u8,
    ) !contract.ModelsError {
        const preparation = switch (runtime.prepareMetaskCatalogRefresh(principal_ref, 17)) {
            .ready => |value| value,
            .rejected => return error.TestUnexpectedResult,
        };
        var session = metask_provider.CatalogSession.init(runtime.allocator);
        defer session.deinit();
        try metask_provider.TestSupport.loadCatalogResponse(&session, principal_ref, "refreshed-secret", response_body);
        var completion = metask_provider.OwnedCatalogCompletion.init(&session);
        var port = completion.ownedPort();
        return runtime.completeMetaskCatalogRefresh(preparation.attempt_id, preparation.authorization_generation, &port);
    }

    pub fn installMetaskDefault(
        runtime: *Runtime,
        principal_ref: []const u8,
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
        try metask_provider.TestSupport.replaceOwnedCatalog(
            &runtime.metask_catalog,
            principal_ref,
            secret,
            models,
        );
        if (!runtime.metask_catalog.hasModel(selected_model))
            return error.InvalidTestModel;
        const configure_updates_default = runtime.registry.metaskChangeUpdatesDefault(selected_model);
        try runtime.registry.configureMetask(
            principal_ref,
            selected_model,
            .anthropic_messages,
            source_generation,
            metask_selection_revision,
            if (configure_updates_default) default_selection_revision else null,
        );
        if (!configure_updates_default)
            try runtime.registry.selectMetaskDefault(default_selection_revision);
        runtime.metask_catalog_state = .ready;
        runtime.metask_catalog_generation = catalog_generation;
        runtime.metask_catalog_authorization_generation = 17;
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

const CanonicalCommitOutcome = enum {
    committed,
    not_committed,
    unresolved,
};

/// Commits one complete canonical image. A post-rename durability failure is
/// resolved only by reading the canonical file back and comparing exact bytes;
/// callers retain ownership of the policy decision for each outcome.
fn commitCanonical(
    allocator: std.mem.Allocator,
    store: anytype,
    bytes: []const u8,
) CanonicalCommitOutcome {
    store.commit(bytes) catch |err| {
        if (err != error.PersistenceOutcomeUnknown) return .not_committed;
        const loaded = store.loadAlloc(allocator) catch return .unresolved;
        const actual = loaded orelse return .unresolved;
        defer allocator.free(actual);
        return if (std.mem.eql(u8, actual, bytes)) .committed else .unresolved;
    };
    return .committed;
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
    metask_catalog_authorization_generation: u64 = 0,
    metask_error: contract.ModelsError = .none,
    metask_safe_diagnostic: FixedText(contract.Limits.safe_diagnostic_bytes) = .{},
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
            return error.CustomProvidersDirectoryUnavailable;
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

    pub fn views(self: *Runtime) []const contract.CustomProviderView {
        self.assertMainThread();
        return self.registry.views();
    }

    pub fn view(self: *Runtime) contract.ModelsView {
        self.assertMainThread();
        const intent = self.registry.metaskIntent();
        var metask_selection: ?contract.ModelRef = null;
        if (intent) |value| {
            metask_selection = .{
                .source_id = contract.metask_source_id,
                .model_id = value.model_id,
            };
        }
        self.provider_views[0] = .{
            .id = contract.metask_source_id,
            .display_name = "Metask",
            .recommended = true,
            .catalog_state = self.metask_catalog_state,
            .principal_ref = if (intent) |value| value.principal_ref else "",
            .models = if (self.metask_public_catalog) |public_catalog|
                public_catalog.modelViews()
            else
                &.{},
            .catalog_generation = self.metask_catalog_generation,
            .source_generation = if (intent) |value| value.source_generation else 0,
            .error_code = self.metask_error,
            .safe_diagnostic = self.metask_safe_diagnostic.view(),
        };
        return .{
            .availability = if (self.store_healthy) .ready else .unavailable,
            .persistence_health = if (self.store_healthy)
                .ready
            else if (self.store != null)
                .recovery_required
            else
                .unavailable,
            .providers = self.provider_views[0..],
            .metask_selection = metask_selection,
            .metask_selection_revision = if (intent) |value| value.selection_revision else 0,
            .default_selection = self.registry.defaultSelection(),
            .selection_revision = self.registry.selection_revision,
            .operation = if (self.catalog_attempt == null) .idle else .refreshing_catalog,
            .error_code = if (!self.store_healthy) .persistence_unavailable else self.metask_error,
            .builtin_provider_presets = builtin_providers.views(),
            .custom_providers = self.registry.views(),
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
        );
    }

    /// Resolve the preferred model or the first eligible catalog entry using
    /// the current authorization lease. No user selection is persisted.
    pub fn prepareImageCandidate(self: *Runtime, input: contract.ImagePreparationInput) contract.ImagePreparation {
        self.assertMainThread();
        if (!self.store_healthy) return .{ .rejected = .persistence_unavailable };
        if (self.catalog_attempt != null or self.metask_catalog_state != .ready or self.metask_catalog_generation == 0)
            return .{ .rejected = .catalog_unavailable };
        if (!std.mem.eql(u8, self.metask_catalog.ownerAccountId(), input.principal_ref) or
            input.authorization_generation == 0 or
            input.authorization_generation != self.metask_catalog_authorization_generation or
            input.bearer.len == 0 or input.bearer.len > contract.Limits.credential_bytes)
            return .{ .rejected = .authorization_unavailable };
        const model = if (self.metask_catalog.hasImageModel(contract.metask_default_image_model))
            contract.metask_default_image_model
        else
            self.metask_catalog.firstImageModelId() orelse return .{ .rejected = .model_not_found };
        return .{ .ready = contract.OwnedImageCandidate.copy(
            self.allocator,
            model,
            input.bearer,
            self.metask_catalog_generation,
        ) catch |err| return .{ .rejected = if (err == error.OutOfMemory) .local_resource_exhausted else .invalid_provider } };
    }

    fn beginMetaskCatalogRefresh(
        self: *Runtime,
        principal_ref: []const u8,
        authorization_generation: u64,
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
        return .{ .ready = .{
            .attempt_id = attempt_id,
            .principal_ref = self.catalog_attempt.?.principal_ref.view(),
            .authorization_generation = authorization_generation,
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
        const attempt = self.catalog_attempt orelse return .catalog_invalid;
        if (attempt.id != attempt_id or
            attempt.authorization_generation != authorization_generation)
            return .catalog_invalid;
        self.catalog_attempt = null;
        if (!std.mem.eql(u8, attempt.principal_ref.view(), session.ownerAccountId())) {
            self.metask_catalog_state = .needs_authentication;
            self.metask_error = .authorization_unavailable;
            return self.metask_error;
        }
        const public_catalog = self.metask_public_catalog orelse {
            self.metask_catalog_state = .unavailable;
            self.metask_error = .persistence_unavailable;
            return self.metask_error;
        };
        const catalog_generation = self.freshGeneration(self.metask_catalog_generation) catch {
            self.metask_catalog_state = .failed;
            self.metask_error = .local_resource_exhausted;
            return self.metask_error;
        };
        // Selection belongs to Models, not the network worker. Preserve an
        // existing intent even when the authoritative catalog excludes it.
        const current_intent = self.registry.metaskIntent();
        const restored_model_id = if (current_intent) |intent|
            if (std.mem.eql(u8, intent.principal_ref, attempt.principal_ref.view()))
                intent.model_id
            else
                session.firstModelId()
        else
            session.firstModelId();
        const protocol = if (restored_model_id) |model_id| session.modelProtocol(model_id) else null;
        const keeps_authority = if (current_intent) |intent|
            std.mem.eql(u8, intent.principal_ref, attempt.principal_ref.view()) and
                intent.protocol == protocol and intent.source_generation != 0
        else
            false;
        if (!keeps_authority) if (protocol) |selected_protocol| {
            const selected_model_id = restored_model_id.?;
            var candidate = self.registry.clone() catch {
                self.metask_catalog_state = .failed;
                self.metask_error = .local_resource_exhausted;
                return self.metask_error;
            };
            defer candidate.deinit();
            const current = candidate.metaskIntent();
            const same_selection = if (current) |value|
                std.mem.eql(u8, value.principal_ref, attempt.principal_ref.view()) and
                    std.mem.eql(u8, value.model_id, selected_model_id)
            else
                false;
            const source_generation = self.freshGeneration(if (current) |value| value.source_generation else 0) catch {
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
            const updates_default = candidate.metaskChangeUpdatesDefault(selected_model_id);
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
                selected_model_id,
                selected_protocol,
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
        };
        self.metask_catalog.deinit();
        self.metask_catalog = session.take();
        public_catalog.replaceFromSession(&self.metask_catalog);
        self.metask_catalog_generation = catalog_generation;
        self.metask_catalog_authorization_generation = authorization_generation;
        self.metask_catalog_state = .ready;
        self.metask_error = if (public_catalog.model_count == 0) .no_models else .none;
        self.metask_safe_diagnostic.len = 0;
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
        const protocol = self.metask_catalog.modelProtocol(command.selection.model_id) orelse
            return .rejected(.model_not_found);
        if (!std.mem.eql(u8, command.selection.source_id, contract.metask_source_id) or
            !self.metask_catalog.hasModel(command.selection.model_id))
            return .rejected(.model_not_found);
        const principal_ref = self.metask_catalog.ownerAccountId();
        if (principal_ref.len == 0) return .rejected(.invalid_provider);
        if (current) |value| {
            if (std.mem.eql(u8, value.principal_ref, principal_ref) and
                std.mem.eql(u8, value.model_id, command.selection.model_id) and
                value.protocol == protocol and value.source_generation != 0)
                return .acceptedResult();
        }

        var candidate = self.registry.clone() catch
            return .rejected(.local_resource_exhausted);
        defer candidate.deinit();
        const same_authority = if (current) |value|
            std.mem.eql(u8, value.principal_ref, principal_ref) and
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
        const updates_default = candidate.metaskChangeUpdatesDefault(command.selection.model_id);
        const default_selection_revision = if (updates_default)
            self.freshGeneration(candidate.selection_revision) catch
                return .rejected(.local_resource_exhausted)
        else
            null;
        candidate.configureMetask(
            principal_ref,
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
            return .rejected(.invalid_provider);
        if (command.expected_selection_revision != self.registry.selection_revision or
            command.expected_source_generation != intent.source_generation or
            command.expected_catalog_generation != self.metask_catalog_generation or
            self.metask_catalog_state != .ready or
            !std.mem.eql(u8, command.selection.source_id, contract.metask_source_id) or
            !std.mem.eql(u8, command.selection.model_id, intent.model_id) or
            !self.metask_catalog.ownsSourceSelection(
                intent.principal_ref,
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
            return .rejected(.invalid_provider);
        if (std.mem.eql(u8, command.selection.source_id, contract.metask_source_id))
            return self.selectMetaskDefault(command);
        if (!self.store_healthy) return .rejected(.persistence_unavailable);
        if (command.expected_selection_revision != self.registry.selection_revision)
            return .rejected(.generation_mismatch);
        const provider = for (self.registry.views()) |value| {
            if (std.mem.eql(u8, value.id, command.selection.source_id))
                break value;
        } else return .rejected(.invalid_provider);
        if (provider.source_generation != command.expected_source_generation or
            provider.catalog_generation != command.expected_catalog_generation)
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
            .source_id = provider.id,
            .expected_provider_revision = provider.provider_revision,
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
            if (std.mem.eql(u8, selection.source_id, contract.metask_source_id)) {
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
            .source = .custom_provider,
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
                        intent.model_id,
                    ) and self.metask_catalog.modelProtocol(intent.model_id) == intent.protocol;
            },
            .custom_provider => self.credential_vault != null and
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
            self.metask_catalog.modelProtocol(model_id) != protocol or
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
        return std.mem.eql(u8, target.source_id, contract.metask_source_id) and
            self.metaskModelAvailable(
                expected_catalog_generation,
                protocol,
                target.model_id,
            );
    }

    /// Validates one source-qualified model against the exact current source
    /// and catalog generations. This does not change the global default.
    pub fn sourceModelAvailable(
        self: *Runtime,
        target: contract.ModelRef,
        expected_source_generation: u64,
        expected_catalog_generation: u64,
        protocol: contract.Protocol,
    ) bool {
        return self.sourceModelProtocol(target, expected_source_generation, expected_catalog_generation) == protocol;
    }

    /// Resolves the protocol declared by an exact ready source/catalog member.
    /// Consumer selection is independent of the Models global default.
    pub fn sourceModelProtocol(
        self: *Runtime,
        target: contract.ModelRef,
        expected_source_generation: u64,
        expected_catalog_generation: u64,
    ) ?contract.Protocol {
        self.assertMainThread();
        if (!self.store_healthy or expected_source_generation == 0 or expected_catalog_generation == 0)
            return null;
        if (std.mem.eql(u8, target.source_id, contract.metask_source_id)) {
            const protocol = self.metask_catalog.modelProtocol(target.model_id) orelse return null;
            return if (self.metaskSourceModelAvailable(
                target,
                expected_source_generation,
                expected_catalog_generation,
                protocol,
            )) protocol else null;
        }
        for (self.registry.views()) |provider| {
            if (!std.mem.eql(u8, provider.id, target.source_id)) continue;
            if (provider.state != .ready or
                provider.credential_status != .ready or
                !provider.enabled or
                provider.source_generation != expected_source_generation or
                provider.catalog_generation != expected_catalog_generation)
                return null;
            for (provider.models) |model|
                if (model.ready and std.mem.eql(u8, model.id, target.model_id))
                    return provider.protocol;
            return null;
        }
        return null;
    }

    pub fn submitCommand(self: *Runtime, command: contract.CustomProviderCommand) contract.CommandResult {
        self.assertMainThread();
        contract.validateCustomProviderCommand(command) catch
            return .rejected(.invalid_provider);
        if (!self.store_healthy) return .rejected(.persistence_unavailable);
        var candidate = self.registry.clone() catch |err| return .rejected(mapRegistryError(err));
        defer candidate.deinit();
        switch (command) {
            .create => |value| {
                if (value.spec.builtin_provider_id != null)
                    return .rejected(.invalid_provider);
                const provider_revision = self.freshGeneration(0) catch
                    return .rejected(.local_resource_exhausted);
                const source_generation = self.freshGeneration(provider_revision) catch
                    return .rejected(.local_resource_exhausted);
                const catalog_generation = self.freshGeneration(source_generation) catch
                    return .rejected(.local_resource_exhausted);
                candidate.create(value, provider_revision, source_generation, catalog_generation) catch |err|
                    return .rejected(mapRegistryError(err));
            },
            .update => |value| {
                const current = findProviderView(candidate.views(), value.selection.source_id) orelse
                    return .rejected(.provider_not_found);
                if (current.builtin_provider_id != null or
                    value.spec.builtin_provider_id != null)
                    return .rejected(.invalid_provider);
                const authority_changed = current.protocol != value.spec.protocol or
                    !std.mem.eql(u8, current.normalized_base_url, value.spec.normalized_base_url);
                const provider_revision = self.freshGeneration(current.provider_revision) catch
                    return .rejected(.local_resource_exhausted);
                const source_generation = if (authority_changed)
                    self.freshGeneration(candidate.sourceGenerationForProvider(current.id) orelse
                        return .rejected(.provider_not_found)) catch
                        return .rejected(.local_resource_exhausted)
                else
                    null;
                const selection_revision = if (authority_changed and isDefaultProvider(&candidate, current.id))
                    self.freshGeneration(candidate.selection_revision) catch
                        return .rejected(.local_resource_exhausted)
                else
                    null;
                candidate.update(value, provider_revision, source_generation, selection_revision) catch |err|
                    return .rejected(mapRegistryError(err));
            },
            .remove => |value| {
                const selection_revision = if (isDefaultProvider(&candidate, value.source_id))
                    self.freshGeneration(candidate.selection_revision) catch
                        return .rejected(.local_resource_exhausted)
                else
                    null;
                candidate.remove(value, selection_revision) catch |err|
                    return .rejected(mapRegistryError(err));
            },
            .test_model => |value| candidate.markTesting(value) catch |err|
                return .rejected(mapRegistryError(err)),
            .add_custom_model => |value| {
                const current = findProviderView(candidate.views(), value.source_id) orelse
                    return .rejected(.provider_not_found);
                const provider_revision = self.freshGeneration(current.provider_revision) catch
                    return .rejected(.local_resource_exhausted);
                const catalog_generation = self.freshGeneration(current.catalog_generation) catch
                    return .rejected(.local_resource_exhausted);
                candidate.addCustomModel(value, provider_revision, catalog_generation) catch |err|
                    return .rejected(mapRegistryError(err));
            },
            .replace_custom_model => |value| {
                const current = findProviderView(candidate.views(), value.selection.source_id) orelse
                    return .rejected(.provider_not_found);
                const provider_revision = self.freshGeneration(current.provider_revision) catch
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
                    provider_revision,
                    catalog_generation,
                    selection_revision,
                ) catch |err| return .rejected(mapRegistryError(err));
            },
            .remove_custom_model => |value| {
                const current = findProviderView(candidate.views(), value.selection.source_id) orelse
                    return .rejected(.provider_not_found);
                const provider_revision = self.freshGeneration(current.provider_revision) catch
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
                    provider_revision,
                    catalog_generation,
                    selection_revision,
                ) catch |err| return .rejected(mapRegistryError(err));
            },
        }
        return self.commitCandidate(&candidate, true);
    }

    pub fn completeTest(
        self: *Runtime,
        command: contract.CustomModelTestCommand,
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

    /// Recovers the Models canonical store without destroying a valid current
    /// schema. Missing or strictly invalid canonical bytes are replaced with
    /// the current empty schema after the caller explicitly requests reset.
    pub fn resetStore(self: *Runtime) contract.CommandResult {
        self.assertMainThread();
        if (self.store == null or self.store_healthy)
            return .rejected(.persistence_unavailable);
        if (self.catalog_attempt != null)
            return .rejected(.operation_in_progress);
        const store = if (self.store) |*value| value else return .rejected(.persistence_unavailable);
        const bytes_optional = store.loadAlloc(self.allocator) catch
            return .rejected(.persistence_unavailable);
        if (bytes_optional) |bytes| {
            defer self.allocator.free(bytes);
            var restored = registry_impl.decode(self.allocator, bytes) catch |err| switch (err) {
                error.OutOfMemory => return .rejected(.local_resource_exhausted),
                else => return self.installEmptyRecovery(store),
            };
            defer restored.deinit();
            if (restored.reconcileInterruptedTests()) {
                const reconciled = registry_impl.encodeAlloc(self.allocator, &restored) catch |err|
                    return .rejected(mapRegistryError(err));
                defer self.allocator.free(reconciled);
                if (commitCanonical(self.allocator, store, reconciled) != .committed)
                    return .rejected(.persistence_unavailable);
            }
            self.registry.replace(&restored);
            self.store_healthy = true;
            self.clearMetaskRuntime(.needs_authentication, .none);
            self.drainCredentialCleanup();
            return .acceptedResult();
        }
        return self.installEmptyRecovery(store);
    }

    fn installEmptyRecovery(
        self: *Runtime,
        store: *registry_impl.FileStore,
    ) contract.CommandResult {
        var candidate = self.registry.resetCandidate() catch |err|
            return .rejected(mapRegistryError(err));
        defer candidate.deinit();
        const encoded = registry_impl.encodeAlloc(self.allocator, &candidate) catch |err|
            return .rejected(mapRegistryError(err));
        defer self.allocator.free(encoded);
        if (commitCanonical(self.allocator, store, encoded) != .committed)
            return .rejected(.persistence_unavailable);
        self.registry.replace(&candidate);
        self.store_healthy = true;
        self.clearMetaskRuntime(.needs_authentication, .none);
        self.drainCredentialCleanup();
        return .acceptedResult();
    }

    pub fn createWithCredential(
        self: *Runtime,
        secret: []const u8,
        spec: contract.CustomProviderSpec,
    ) contract.CommandResult {
        if (spec.builtin_provider_id != null)
            return .rejected(.invalid_provider);
        return self.createWithResolvedCredential(secret, spec);
    }

    pub fn createBuiltinWithCredential(
        self: *Runtime,
        secret: []const u8,
        provider_id: contract.BuiltinProviderId,
        base_url: []const u8,
    ) contract.CommandResult {
        for (self.registry.views()) |provider|
            if (provider.builtin_provider_id == provider_id)
                return .rejected(.invalid_provider);
        const definition = builtin_providers.find(provider_id);
        const endpoint = contract.completionEndpointFromBaseUrlAlloc(
            self.allocator,
            definition.protocol,
            base_url,
        ) catch return .rejected(.invalid_provider);
        defer self.allocator.free(endpoint);
        return self.createWithResolvedCredential(
            secret,
            definition.spec(endpoint),
        );
    }

    pub fn updateBuiltinBaseUrl(
        self: *Runtime,
        selection: contract.CustomProviderSelectionCommand,
        base_url: []const u8,
    ) contract.CommandResult {
        self.assertMainThread();
        if (!self.store_healthy) return .rejected(.persistence_unavailable);
        var candidate = self.registry.clone() catch |err|
            return .rejected(mapRegistryError(err));
        defer candidate.deinit();
        const current = findProviderView(candidate.views(), selection.source_id) orelse
            return .rejected(.provider_not_found);
        if (current.provider_revision != selection.expected_provider_revision)
            return .rejected(.generation_mismatch);
        const builtin_provider_id = current.builtin_provider_id orelse
            return .rejected(.invalid_provider);
        const definition = builtin_providers.find(builtin_provider_id);
        const endpoint = contract.completionEndpointFromBaseUrlAlloc(
            self.allocator,
            definition.protocol,
            base_url,
        ) catch return .rejected(.invalid_provider);
        defer self.allocator.free(endpoint);
        if (std.mem.eql(u8, current.normalized_base_url, endpoint))
            return .acceptedResult();
        const provider_revision = self.freshGeneration(current.provider_revision) catch
            return .rejected(.local_resource_exhausted);
        const source_generation = self.freshGeneration(
            candidate.sourceGenerationForProvider(current.id) orelse
                return .rejected(.provider_not_found),
        ) catch return .rejected(.local_resource_exhausted);
        const selection_revision = if (isDefaultProvider(&candidate, current.id))
            self.freshGeneration(candidate.selection_revision) catch
                return .rejected(.local_resource_exhausted)
        else
            null;
        candidate.update(.{
            .selection = selection,
            .spec = definition.spec(endpoint),
        }, provider_revision, source_generation, selection_revision) catch |err|
            return .rejected(mapRegistryError(err));
        return self.commitCandidate(&candidate, true);
    }

    fn createWithResolvedCredential(
        self: *Runtime,
        secret: []const u8,
        spec: contract.CustomProviderSpec,
    ) contract.CommandResult {
        self.assertMainThread();
        if (!self.store_healthy) return .rejected(.persistence_unavailable);
        contract.validateCustomProviderSpec(spec) catch return .rejected(.invalid_provider);
        if (secret.len == 0 or secret.len > contract.Limits.credential_bytes)
            return .rejected(.invalid_provider);
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
        const provider_revision = self.freshGeneration(0) catch {
            self.drainCredentialCleanup();
            return .rejected(.local_resource_exhausted);
        };
        const source_generation = self.freshGeneration(provider_revision) catch {
            self.drainCredentialCleanup();
            return .rejected(.local_resource_exhausted);
        };
        const catalog_generation = self.freshGeneration(source_generation) catch {
            self.drainCredentialCleanup();
            return .rejected(.local_resource_exhausted);
        };
        committed.create(.{
            .provider_id = slot_id,
            .spec = spec,
            .credential_slot = .{ .id = slot_id },
        }, provider_revision, source_generation, catalog_generation) catch |err| {
            self.drainCredentialCleanup();
            return .rejected(mapRegistryError(err));
        };
        committed.completeCredentialDeletion(slot_id) catch {
            self.drainCredentialCleanup();
            return .rejected(.invalid_provider);
        };
        const result = self.commitCandidate(&committed, true);
        if (!result.accepted and self.store_healthy) self.drainCredentialCleanup();
        return result;
    }

    /// Replaces a credential using a fail-closed two-commit transaction:
    /// first revoke durable readiness, then write the Host secret, and only
    /// then publish a fresh source authority. A partial failure therefore
    /// leaves a repairable non-runnable provider, never stale readiness.
    pub fn replaceCredential(
        self: *Runtime,
        secret: []const u8,
        selection: contract.CustomProviderSelectionCommand,
    ) contract.CommandResult {
        self.assertMainThread();
        if (!self.store_healthy) return .rejected(.persistence_unavailable);
        if (secret.len == 0 or secret.len > contract.Limits.credential_bytes)
            return .rejected(.invalid_provider);
        const vault = self.credential_vault orelse return .rejected(.capture_unavailable);

        var revoked = self.registry.clone() catch
            return .rejected(.local_resource_exhausted);
        defer revoked.deinit();
        const clears_default = isDefaultProvider(&revoked, selection.source_id);
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

        const current = findProviderView(self.registry.views(), selection.source_id) orelse
            return .rejected(.provider_not_found);
        var restored = self.registry.clone() catch
            return .rejected(.local_resource_exhausted);
        defer restored.deinit();
        const provider_revision = self.freshGeneration(current.provider_revision) catch
            return .rejected(.local_resource_exhausted);
        const source_generation = self.freshGeneration(current.source_generation) catch
            return .rejected(.local_resource_exhausted);
        restored.restoreCredential(selection, provider_revision, source_generation) catch |err|
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
        self.metask_catalog_authorization_generation = 0;
        self.metask_catalog_state = state;
        self.metask_error = error_code;
        self.metask_safe_diagnostic.len = 0;
    }

    pub fn resolveProbeCandidate(
        self: *Runtime,
        command: contract.CustomModelTestCommand,
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
        if (!self.store_healthy) return null;
        const selection = self.registry.defaultSelection() orelse return null;
        if (self.registry.metaskIntent()) |intent| {
            if (std.mem.eql(u8, selection.source_id, contract.metask_source_id)) {
                if (!std.mem.eql(u8, selection.model_id, intent.model_id) or
                    intent.protocol == null or intent.source_generation == 0 or
                    self.metask_catalog_state != .ready or
                    !self.metask_catalog.ownsSourceSelection(
                        intent.principal_ref,
                        intent.model_id,
                    ) or self.metask_catalog.modelProtocol(intent.model_id) != intent.protocol)
                    return null;
                return self.resolveModel(
                    selection,
                    intent.source_generation,
                    self.metask_catalog_generation,
                );
            }
        }

        const binding = self.registry.defaultBinding() orelse return null;
        const provider = findProviderView(self.registry.views(), binding.provider_id) orelse return null;
        return self.resolveModel(selection, binding.source_generation, provider.catalog_generation);
    }

    /// Produces a complete owned execution candidate for an explicit model.
    /// A stale/unavailable target never falls back to the global selection.
    pub fn resolveModel(
        self: *Runtime,
        target: contract.ModelRef,
        expected_source_generation: u64,
        expected_catalog_generation: u64,
    ) !?contract.OwnedSourceCandidate {
        const protocol = self.sourceModelProtocol(target, expected_source_generation, expected_catalog_generation) orelse return null;
        if (std.mem.eql(u8, target.source_id, contract.metask_source_id)) {
            return self.metask_catalog.prepareSourceCandidate(target.model_id, expected_source_generation) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.InvalidProvider,
            };
        }
        const provider = findProviderView(self.registry.views(), target.source_id) orelse return null;
        const binding: DefaultBinding = .{
            .provider_id = provider.id,
            .model_id = target.model_id,
            .protocol = protocol,
            .normalized_base_url = provider.normalized_base_url,
            .provider_revision = provider.provider_revision,
            .source_generation = provider.source_generation,
        };
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
        const secret = (try vault.get(binding.provider_id, &secret_storage)) orelse
            return error.CredentialNotFound;
        var declarations: [contract.max_model_image_capabilities]contract.ModelImageCapability = undefined;
        var owned_capabilities = try contract.OwnedImageCapabilities.copy(self.allocator, self.registry.imageCapabilities(binding.provider_id, &declarations));
        errdefer owned_capabilities.deinit();
        var model_id: ?[]u8 = try self.allocator.dupe(u8, binding.model_id);
        errdefer if (model_id) |bytes| self.allocator.free(bytes);
        var normalized_base_url: ?[]u8 = try self.allocator.dupe(u8, binding.normalized_base_url);
        errdefer if (normalized_base_url) |bytes| self.allocator.free(bytes);
        const credential = try self.allocator.dupe(u8, secret);
        const transferred_model = model_id.?;
        const transferred_url = normalized_base_url.?;
        model_id = null;
        normalized_base_url = null;
        var result = try contract.OwnedSourceCandidate.initOwned(
            self.allocator,
            .custom_provider,
            binding.protocol,
            transferred_model,
            transferred_url,
            binding.source_generation,
            credential,
            binding.provider_id,
        );
        result.image_capabilities = owned_capabilities.take();
        return result;
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
        switch (commitCanonical(self.allocator, store, encoded)) {
            .committed => {},
            .not_committed => return .rejected(.persistence_unavailable),
            .unresolved => {
                self.store_healthy = false;
                return .rejected(.persistence_unavailable);
            },
        }
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
            self.initializeEmptyStore();
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
            if (commitCanonical(self.allocator, &self.store.?, reconciled) != .committed) {
                self.store_healthy = false;
            }
        }
        self.registry.replace(restored);
        restored.deinit();
        self.drainCredentialCleanup();
    }

    fn initializeEmptyStore(self: *Runtime) void {
        var empty = registry_impl.Registry.init(self.allocator);
        defer empty.deinit();
        const encoded = registry_impl.encodeAlloc(self.allocator, &empty) catch {
            self.store_healthy = false;
            return;
        };
        defer self.allocator.free(encoded);
        if (commitCanonical(self.allocator, &self.store.?, encoded) != .committed) {
            self.store_healthy = false;
            return;
        }
        self.registry.replace(&empty);
    }

    fn markCredentialMissing(self: *Runtime, binding: registry_impl.Registry.DefaultBinding) void {
        var candidate = self.registry.clone() catch {
            self.store_healthy = false;
            return;
        };
        defer candidate.deinit();
        const selection_revision = if (isDefaultProvider(&candidate, binding.provider_id))
            self.freshGeneration(candidate.selection_revision) catch {
                self.store_healthy = false;
                return;
            }
        else
            null;
        candidate.markCredentialMissing(.{
            .source_id = binding.provider_id,
            .expected_provider_revision = binding.provider_revision,
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
        var snapshot: std.ArrayList([]u8) = .empty;
        defer {
            for (snapshot.items) |provider_id| self.allocator.free(provider_id);
            snapshot.deinit(self.allocator);
        }
        snapshot.ensureTotalCapacity(
            self.allocator,
            self.registry.credentialDeletions().len,
        ) catch return;
        for (self.registry.credentialDeletions()) |provider_id| {
            const owned = self.allocator.dupe(u8, provider_id) catch return;
            snapshot.appendAssumeCapacity(owned);
        }
        for (snapshot.items) |provider_id| {
            vault.delete(provider_id) catch continue;
            var candidate = self.registry.clone() catch continue;
            defer candidate.deinit();
            candidate.completeCredentialDeletion(provider_id) catch continue;
            const result = self.commitCandidate(&candidate, false);
            if (!result.accepted and !self.store_healthy) return;
        }
    }

    fn assertMainThread(self: *const Runtime) void {
        std.debug.assert(std.Thread.getCurrentId() == self.main_thread_id);
    }
};

fn mapRegistryError(err: anyerror) contract.ManagementError {
    return switch (err) {
        error.ProviderNotFound => .provider_not_found,
        error.GenerationMismatch => .generation_mismatch,
        error.ModelNotFound => .model_not_found,
        error.Capacity => .capacity,
        error.OutOfMemory => .local_resource_exhausted,
        else => .invalid_provider,
    };
}

fn mapModelsError(error_code: contract.ModelsError) contract.ManagementError {
    return switch (error_code) {
        .none => unreachable,
        .authorization_unavailable => .authorization_unavailable,
        .persistence_unavailable => .persistence_unavailable,
        .operation_in_progress => .operation_in_progress,
        .local_resource_exhausted => .local_resource_exhausted,
        .catalog_unavailable,
        .catalog_invalid,
        .catalog_too_large,
        .no_models,
        => .catalog_unavailable,
    };
}

fn findProviderView(
    views: []const contract.CustomProviderView,
    provider_id: []const u8,
) ?contract.CustomProviderView {
    for (views) |view|
        if (std.mem.eql(u8, view.id, provider_id)) return view;
    return null;
}

fn isDefaultProvider(registry: *const registry_impl.Registry, provider_id: []const u8) bool {
    const selection = registry.defaultSelection() orelse return false;
    return std.mem.eql(u8, selection.source_id, provider_id);
}

fn isDefaultModel(registry: *const registry_impl.Registry, model: contract.ModelRef) bool {
    const selection = registry.defaultSelection() orelse return false;
    return std.mem.eql(u8, selection.source_id, model.source_id) and
        std.mem.eql(u8, selection.model_id, model.model_id);
}

const CanonicalCommitTestStore = struct {
    const Mode = enum {
        committed,
        write_failed,
        unknown_match,
        unknown_different,
        unknown_missing,
        unknown_read_failed,
    };

    mode: Mode,
    target: []const u8 = &.{},
    read_count: usize = 0,

    fn commit(self: *@This(), bytes: []const u8) registry_impl.FileStoreError!void {
        self.target = bytes;
        return switch (self.mode) {
            .committed => {},
            .write_failed => error.WriteFailed,
            .unknown_match,
            .unknown_different,
            .unknown_missing,
            .unknown_read_failed,
            => error.PersistenceOutcomeUnknown,
        };
    }

    fn loadAlloc(
        self: *@This(),
        allocator: std.mem.Allocator,
    ) (registry_impl.FileStoreError || std.mem.Allocator.Error)!?[]u8 {
        self.read_count += 1;
        return switch (self.mode) {
            .unknown_match => try allocator.dupe(u8, self.target),
            .unknown_different => try allocator.dupe(u8, "different-canonical"),
            .unknown_missing => null,
            .unknown_read_failed => error.ReadFailed,
            .committed, .write_failed => unreachable,
        };
    }
};

test "canonical commit resolves only an exact outcome-unknown readback" {
    const cases = [_]struct {
        mode: CanonicalCommitTestStore.Mode,
        expected: CanonicalCommitOutcome,
        expected_reads: usize,
    }{
        .{ .mode = .committed, .expected = .committed, .expected_reads = 0 },
        .{ .mode = .write_failed, .expected = .not_committed, .expected_reads = 0 },
        .{ .mode = .unknown_match, .expected = .committed, .expected_reads = 1 },
        .{ .mode = .unknown_different, .expected = .unresolved, .expected_reads = 1 },
        .{ .mode = .unknown_missing, .expected = .unresolved, .expected_reads = 1 },
        .{ .mode = .unknown_read_failed, .expected = .unresolved, .expected_reads = 1 },
    };
    for (cases) |case| {
        var store: CanonicalCommitTestStore = .{ .mode = case.mode };
        try std.testing.expectEqual(
            case.expected,
            commitCanonical(std.testing.allocator, &store, "candidate-canonical"),
        );
        try std.testing.expectEqual(case.expected_reads, store.read_count);
    }
}

const TestVault = struct {
    const slot = "custom-provider-00000000000000000000000000000001";

    secret: [contract.Limits.credential_bytes]u8 = undefined,
    secret_len: usize = 0,
    present: bool = false,
    fail_store: bool = false,
    expected_secret_ptr: ?[*]const u8 = null,
    observed_direct_borrow: bool = false,

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
        self.observed_direct_borrow = if (self.expected_secret_ptr) |expected|
            secret.ptr == expected
        else
            false;
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

const CleanupTestVault = struct {
    fail_id: []const u8 = &.{},
    calls: [8][contract.Limits.instance_id_bytes]u8 = undefined,
    call_lengths: [8]usize = @splat(0),
    call_count: usize = 0,

    fn port(self: *@This()) ports.CredentialVault {
        return .{
            .context = self,
            .generate_slot_fn = generate,
            .store_fn = store,
            .get_fn = get,
            .delete_fn = delete,
        };
    }

    fn generate(_: *anyopaque, _: *[ports.credential_slot_bytes]u8) anyerror!void {
        return error.Unavailable;
    }

    fn store(_: *anyopaque, _: []const u8, _: []const u8) anyerror!void {
        return error.Unavailable;
    }

    fn get(_: *anyopaque, _: []const u8, _: []u8) anyerror!?[]const u8 {
        return null;
    }

    fn delete(context: *anyopaque, provider_id: []const u8) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        const index = self.call_count;
        if (index >= self.calls.len or provider_id.len > self.calls[index].len)
            return error.Unavailable;
        @memcpy(self.calls[index][0..provider_id.len], provider_id);
        self.call_lengths[index] = provider_id.len;
        self.call_count += 1;
        if (std.mem.eql(u8, provider_id, self.fail_id)) return error.DeleteFailed;
    }

    fn call(self: *const @This(), index: usize) []const u8 {
        return self.calls[index][0..self.call_lengths[index]];
    }
};

test "credential cleanup skips failed tombstones and completes later IDs" {
    const cleanup_a = "custom-provider-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const cleanup_b = "custom-provider-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const cleanup_c = "custom-provider-cccccccccccccccccccccccccccccccc";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var directory_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory_len = try tmp.dir.realPath(std.testing.io, &directory_storage);
    var vault: CleanupTestVault = .{ .fail_id = cleanup_a };
    var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
    try runtime.start(directory_storage[0..directory_len], vault.port());
    defer {
        runtime.stop();
        runtime.deinit();
    }

    var candidate = try runtime.registry.clone();
    defer candidate.deinit();
    try candidate.reserveCredentialDeletion(cleanup_a);
    try candidate.reserveCredentialDeletion(cleanup_b);
    try candidate.reserveCredentialDeletion(cleanup_c);
    try std.testing.expect(runtime.commitCandidate(&candidate, false).accepted);

    runtime.drainCredentialCleanup();
    try std.testing.expectEqual(@as(usize, 3), vault.call_count);
    try std.testing.expectEqualStrings(cleanup_a, vault.call(0));
    try std.testing.expectEqualStrings(cleanup_b, vault.call(1));
    try std.testing.expectEqualStrings(cleanup_c, vault.call(2));
    try std.testing.expectEqual(@as(usize, 1), runtime.registry.credentialDeletions().len);
    try std.testing.expectEqualStrings(cleanup_a, runtime.registry.credentialDeletions()[0]);

    vault.fail_id = &.{};
    runtime.drainCredentialCleanup();
    try std.testing.expectEqual(@as(usize, 4), vault.call_count);
    try std.testing.expectEqualStrings(cleanup_a, vault.call(3));
    try std.testing.expectEqual(@as(usize, 0), runtime.registry.credentialDeletions().len);
}

fn createTestProviderWithModel(
    runtime: *Runtime,
    secret: []const u8,
    spec: contract.CustomProviderSpec,
    model: contract.CustomModelInput,
) !void {
    try std.testing.expect(runtime.createWithCredential(secret, spec).accepted);
    const providers = runtime.views();
    const provider = providers[providers.len - 1];
    try std.testing.expect(runtime.submitCommand(.{ .add_custom_model = .{
        .source_id = provider.id,
        .expected_provider_revision = provider.provider_revision,
        .expected_catalog_generation = provider.catalog_generation,
        .model = model,
    } }).accepted);
}

test "Models Runtime durably creates a Provider before its first model" {
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
        try std.testing.expect(runtime.createWithCredential("provider-secret", .{
            .display_name = "Provider without models",
            .protocol = .anthropic_messages,
            .normalized_base_url = "https://api.anthropic.com/v1/messages",
        }).accepted);
        const provider = runtime.views()[0];
        try std.testing.expectEqual(contract.CustomProviderState.configuring, provider.state);
        try std.testing.expectEqual(@as(usize, 0), provider.models.len);
        try std.testing.expect(vault.present);
        try std.testing.expect(runtime.defaultAuthority() == null);
        try std.testing.expect((try runtime.resolveDefault()) == null);
    }

    {
        var restored = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
        try restored.start(directory, vault.port());
        defer {
            restored.stop();
            restored.deinit();
        }
        const providers = restored.views();
        try std.testing.expectEqual(@as(usize, 1), providers.len);
        try std.testing.expectEqual(@as(usize, 0), providers[0].models.len);
        try std.testing.expect(restored.defaultAuthority() == null);
    }
}

test "built-in Provider recipe creates a fixed provider and reuses model management" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var directory_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory_len = try tmp.dir.realPath(std.testing.io, &directory_storage);
    var vault: TestVault = .{};
    var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
    try runtime.start(directory_storage[0..directory_len], vault.port());
    defer {
        runtime.stop();
        runtime.deinit();
    }

    try std.testing.expect(runtime.createBuiltinWithCredential(
        "official-secret",
        .deepseek,
        builtin_providers.find(.deepseek).default_base_url,
    ).accepted);
    try std.testing.expectEqual(
        contract.BuiltinProviderId.deepseek,
        runtime.views()[0].builtin_provider_id.?,
    );
    try std.testing.expect(!runtime.createBuiltinWithCredential(
        "second-secret",
        .deepseek,
        builtin_providers.find(.deepseek).default_base_url,
    ).accepted);

    const provider = runtime.views()[0];
    try std.testing.expectEqualStrings(
        "https://api.deepseek.com/chat/completions",
        provider.normalized_base_url,
    );
    try std.testing.expect(runtime.submitCommand(.{ .add_custom_model = .{
        .source_id = provider.id,
        .expected_provider_revision = provider.provider_revision,
        .expected_catalog_generation = provider.catalog_generation,
        .model = .{ .id = "deepseek-chat", .display_name = "DeepSeek Chat" },
    } }).accepted);
    const before_update = runtime.views()[0];
    const before_source_generation = before_update.source_generation;
    try std.testing.expect(runtime.updateBuiltinBaseUrl(.{
        .source_id = TestVault.slot,
        .expected_provider_revision = before_update.provider_revision,
    }, "https://gateway.example.com/deepseek/v1/").accepted);
    const updated = runtime.views()[0];
    try std.testing.expectEqualStrings(
        "https://gateway.example.com/deepseek/v1/chat/completions",
        updated.normalized_base_url,
    );
    try std.testing.expectEqualStrings("DeepSeek", updated.display_name);
    try std.testing.expectEqual(contract.Protocol.openai_chat_completions, updated.protocol);
    try std.testing.expect(updated.source_generation != before_source_generation);
    try std.testing.expectEqual(@as(usize, 1), updated.models.len);
    try std.testing.expectEqual(contract.CustomModelTestStatus.untested, updated.models[0].test_status);
}

test "Models Runtime owns durable custom providers and source resolution" {
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
        try createTestProviderWithModel(
            &runtime,
            "provider-secret",
            .{
                .display_name = "OpenAI",
                .protocol = .openai_responses,
                .normalized_base_url = "https://api.openai.com/v1/responses",
            },
            .{ .id = "gpt-5", .display_name = "GPT-5" },
        );
        const view = runtime.views()[0];
        try std.testing.expectEqualStrings(TestVault.slot, view.id);
        const selection: contract.CustomProviderSelectionCommand = .{
            // Registry views are borrowed until the next committed mutation.
            // Commands arrive with independently owned request bytes in
            // production, so keep this test selection independently stable.
            .source_id = TestVault.slot,
            .expected_provider_revision = view.provider_revision,
        };
        try std.testing.expect(runtime.submitCommand(.{ .test_model = .{
            .model = .{ .source_id = selection.source_id, .model_id = "gpt-5" },
            .expected_provider_revision = selection.expected_provider_revision,
            .expected_source_generation = view.source_generation,
            .expected_catalog_generation = view.catalog_generation,
        } }).accepted);
        try std.testing.expect(runtime.completeTest(.{
            .model = .{ .source_id = selection.source_id, .model_id = "gpt-5" },
            .expected_provider_revision = selection.expected_provider_revision,
            .expected_source_generation = view.source_generation,
            .expected_catalog_generation = view.catalog_generation,
        }, true).accepted);
        const provider = runtime.views()[0];
        try std.testing.expect(runtime.sourceModelAvailable(
            .{ .source_id = selection.source_id, .model_id = "gpt-5" },
            provider.source_generation,
            provider.catalog_generation,
            .openai_responses,
        ));
        try std.testing.expect(!runtime.sourceModelAvailable(
            .{ .source_id = selection.source_id, .model_id = "missing-model" },
            provider.source_generation,
            provider.catalog_generation,
            .openai_responses,
        ));
        try std.testing.expect(!runtime.sourceModelAvailable(
            .{ .source_id = selection.source_id, .model_id = "gpt-5" },
            provider.source_generation + 1,
            provider.catalog_generation,
            .openai_responses,
        ));
        try std.testing.expect(!runtime.sourceModelAvailable(
            .{ .source_id = selection.source_id, .model_id = "gpt-5" },
            provider.source_generation,
            provider.catalog_generation,
            .anthropic_messages,
        ));
        try std.testing.expect(runtime.selectDefault(.{
            .selection = .{ .source_id = selection.source_id, .model_id = "gpt-5" },
            .expected_selection_revision = runtime.view().selection_revision,
            .expected_source_generation = provider.source_generation,
            .expected_catalog_generation = provider.catalog_generation,
        }).accepted);
        const authority = runtime.defaultAuthority() orelse
            return error.TestUnexpectedResult;
        try std.testing.expectEqual(contract.Source.custom_provider, authority.source);
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
            try std.testing.expectEqualStrings("custom_provider:" ++ TestVault.slot, candidate.input().target.provider_id);
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
            contract.CustomProviderCredentialStatus.missing,
            missing.credential_status,
        );
        try std.testing.expectEqual(contract.CustomProviderState.configuring, missing.state);
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
            contract.CustomProviderCredentialStatus.missing,
            missing.credential_status,
        );
        try std.testing.expectEqual(contract.CustomProviderState.configuring, missing.state);
    }
}

test "Models explicit resolution preserves the global default across sources" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(std.testing.io, &path);
    var vault: TestVault = .{};
    var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
    try runtime.start(path[0..length], vault.port());
    defer {
        runtime.stop();
        runtime.deinit();
    }
    try std.testing.expectEqual(contract.ModelsError.none, try TestSupport.refreshMetaskCatalog(&runtime, "principal", &.{.{ .id = "default-model", .display_name = "Default" }}));
    const initial = runtime.view();
    try std.testing.expect(runtime.selectDefault(.{
        .selection = .{ .source_id = "metask", .model_id = "default-model" },
        .expected_selection_revision = initial.selection_revision,
        .expected_source_generation = initial.providers[0].source_generation,
        .expected_catalog_generation = initial.providers[0].catalog_generation,
    }).accepted);
    const default_revision = runtime.view().selection_revision;
    try createTestProviderWithModel(&runtime, "custom-secret", .{
        .display_name = "Other connection",
        .protocol = .openai_responses,
        .normalized_base_url = "https://other.example.com/v1/responses",
    }, .{ .id = "other-model" });
    const target: contract.ModelRef = .{ .source_id = TestVault.slot, .model_id = "other-model" };
    const configuring = runtime.views()[0];
    try std.testing.expect((try runtime.resolveModel(target, configuring.source_generation, configuring.catalog_generation)) == null);
    const probe: contract.CustomModelTestCommand = .{
        .model = target,
        .expected_provider_revision = configuring.provider_revision,
        .expected_source_generation = configuring.source_generation,
        .expected_catalog_generation = configuring.catalog_generation,
    };
    try std.testing.expect(runtime.submitCommand(.{ .test_model = probe }).accepted);
    try std.testing.expect(runtime.completeTest(probe, true).accepted);
    const ready = runtime.views()[0];
    try std.testing.expect((try runtime.resolveModel(target, ready.source_generation +% 1, ready.catalog_generation)) == null);
    try std.testing.expect((try runtime.resolveModel(target, ready.source_generation, ready.catalog_generation +% 1)) == null);
    try std.testing.expect((try runtime.resolveModel(.{ .source_id = TestVault.slot, .model_id = "missing" }, ready.source_generation, ready.catalog_generation)) == null);
    var candidate = (try runtime.resolveModel(target, ready.source_generation, ready.catalog_generation)).?;
    defer candidate.deinit();
    try std.testing.expectEqual(contract.Protocol.openai_responses, candidate.input().target.protocol);
    try std.testing.expectEqualStrings("https://other.example.com/v1/responses", candidate.input().target.base_url);
    try std.testing.expectEqualStrings("custom_provider:" ++ TestVault.slot, candidate.input().target.provider_id);
    try std.testing.expectEqualStrings("custom-secret", candidate.input().api_key);
    try std.testing.expectEqual(default_revision, runtime.view().selection_revision);
    try std.testing.expectEqualStrings("metask", runtime.view().default_selection.?.source_id);
    try std.testing.expectEqualStrings("default-model", runtime.view().default_selection.?.model_id);

    // Losing this connection's credential revokes only its new resolutions.
    // An unrelated default and an already owned execution remain intact.
    try TestVault.delete(&vault, TestVault.slot);
    try std.testing.expect((try runtime.resolveModel(target, ready.source_generation, ready.catalog_generation)) == null);
    try std.testing.expectEqual(contract.CustomProviderCredentialStatus.missing, runtime.views()[0].credential_status);
    try std.testing.expectEqual(default_revision, runtime.view().selection_revision);
    try std.testing.expectEqualStrings("metask", runtime.view().default_selection.?.source_id);
    try std.testing.expectEqualStrings("custom-secret", candidate.input().api_key);
}

test "Models explicit resolution uses the target Metask protocol and rejects stale catalogs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(std.testing.io, &path);
    var vault: TestVault = .{};
    var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
    try runtime.start(path[0..length], vault.port());
    defer {
        runtime.stop();
        runtime.deinit();
    }
    const response =
        \\{"object":"list","has_more":false,"data":[{"id":"default-model","object":"model","type":"model","capabilities":{"endpoints":{"messages":{"supported":true}}}},{"id":"other-model","object":"model","type":"model","capabilities":{"endpoints":{"responses":{"supported":true}}}}]}
    ;
    try std.testing.expectEqual(contract.ModelsError.none, try TestSupport.refreshMetaskCatalogResponse(&runtime, "principal", response));
    const initial = runtime.view();
    try std.testing.expect(runtime.selectDefault(.{
        .selection = .{ .source_id = "metask", .model_id = "default-model" },
        .expected_selection_revision = initial.selection_revision,
        .expected_source_generation = initial.providers[0].source_generation,
        .expected_catalog_generation = initial.providers[0].catalog_generation,
    }).accepted);
    const view = runtime.view();
    const source_generation = view.providers[0].source_generation;
    const catalog_generation = view.providers[0].catalog_generation;
    const selection_revision = view.selection_revision;
    const target: contract.ModelRef = .{ .source_id = "metask", .model_id = "other-model" };
    var candidate = (try runtime.resolveModel(target, source_generation, catalog_generation)).?;
    defer candidate.deinit();
    try std.testing.expectEqual(contract.Protocol.openai_responses, candidate.input().target.protocol);
    try std.testing.expectEqualStrings(contract.metaskEndpoint(.openai_responses).?, candidate.input().target.base_url);
    try std.testing.expectEqualStrings("refreshed-secret", candidate.input().api_key);
    try std.testing.expectEqual(source_generation, candidate.input().source_generation);
    try std.testing.expectEqual(selection_revision, runtime.view().selection_revision);
    try std.testing.expectEqualStrings("default-model", runtime.view().default_selection.?.model_id);
    try std.testing.expectEqual(contract.Protocol.anthropic_messages, runtime.defaultAuthority().?.protocol);
    try std.testing.expect((try runtime.resolveModel(target, source_generation +% 1, catalog_generation)) == null);
    try std.testing.expect((try runtime.resolveModel(target, source_generation, catalog_generation +% 1)) == null);
    try std.testing.expect((try runtime.resolveModel(target, 0, catalog_generation)) == null);

    try std.testing.expectEqual(contract.ModelsError.none, try TestSupport.refreshMetaskCatalog(&runtime, "principal", &.{}));
    try std.testing.expect((try runtime.resolveModel(target, source_generation, catalog_generation)) == null);
    try std.testing.expectEqualStrings("other-model", candidate.input().target.model);
    try std.testing.expectEqualStrings("refreshed-secret", candidate.input().api_key);
    runtime.store_healthy = false;
    try std.testing.expect((try runtime.resolveModel(target, source_generation, catalog_generation)) == null);
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
    const old_secret = "old-secret";
    vault.expected_secret_ptr = old_secret.ptr;
    try createTestProviderWithModel(
        &runtime,
        old_secret,
        .{
            .display_name = "Provider",
            .protocol = .openai_responses,
            .normalized_base_url = "https://api.example.com/v1/responses",
        },
        .{ .id = "model-1", .display_name = "Model 1" },
    );
    try std.testing.expect(vault.observed_direct_borrow);
    try std.testing.expectEqualStrings(old_secret, vault.secret[0..vault.secret_len]);
    const created_canonical = (try runtime.store.?.loadAlloc(std.testing.allocator)) orelse
        return error.TestExpectedEqual;
    defer std.testing.allocator.free(created_canonical);
    try std.testing.expect(std.mem.indexOf(u8, created_canonical, old_secret) == null);
    const initial = runtime.views()[0];
    const selection: contract.CustomProviderSelectionCommand = .{
        .source_id = TestVault.slot,
        .expected_provider_revision = initial.provider_revision,
    };
    try std.testing.expect(runtime.submitCommand(.{ .test_model = .{
        .model = .{ .source_id = TestVault.slot, .model_id = "model-1" },
        .expected_provider_revision = initial.provider_revision,
        .expected_source_generation = initial.source_generation,
        .expected_catalog_generation = initial.catalog_generation,
    } }).accepted);
    try std.testing.expect(runtime.completeTest(.{
        .model = .{ .source_id = TestVault.slot, .model_id = "model-1" },
        .expected_provider_revision = initial.provider_revision,
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
    const new_secret = "new-secret";
    vault.expected_secret_ptr = new_secret.ptr;
    vault.observed_direct_borrow = false;
    const failed = runtime.replaceCredential(new_secret, selection);
    try std.testing.expect(!failed.accepted);
    try std.testing.expect(vault.observed_direct_borrow);
    try std.testing.expectEqual(contract.ManagementError.credential_write_failed, failed.error_code.?);
    try std.testing.expectEqualStrings(old_secret, vault.secret[0..vault.secret_len]);
    const failed_canonical = (try runtime.store.?.loadAlloc(std.testing.allocator)) orelse
        return error.TestExpectedEqual;
    defer std.testing.allocator.free(failed_canonical);
    try std.testing.expect(std.mem.indexOf(u8, failed_canonical, new_secret) == null);
    try std.testing.expect(runtime.view().default_selection == null);
    const revoked = runtime.views()[0];
    try std.testing.expectEqual(contract.CustomProviderCredentialStatus.missing, revoked.credential_status);
    try std.testing.expectEqual(contract.CustomProviderState.configuring, revoked.state);
    try std.testing.expect(!revoked.models[0].ready);

    vault.fail_store = false;
    vault.observed_direct_borrow = false;
    try std.testing.expect(runtime.replaceCredential(new_secret, .{
        .source_id = TestVault.slot,
        .expected_provider_revision = revoked.provider_revision,
    }).accepted);
    try std.testing.expect(vault.observed_direct_borrow);
    const restored = runtime.views()[0];
    try std.testing.expectEqual(contract.CustomProviderCredentialStatus.ready, restored.credential_status);
    try std.testing.expectEqual(contract.CustomProviderState.configuring, restored.state);
    try std.testing.expect(restored.provider_revision != initial.provider_revision);
    try std.testing.expect(restored.source_generation != initial.source_generation);
    try std.testing.expectEqualStrings(new_secret, vault.secret[0..vault.secret_len]);
    const replaced_canonical = (try runtime.store.?.loadAlloc(std.testing.allocator)) orelse
        return error.TestExpectedEqual;
    defer std.testing.allocator.free(replaced_canonical);
    try std.testing.expect(std.mem.indexOf(u8, replaced_canonical, new_secret) == null);
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
    try metask_provider.TestSupport.replaceOwnedCatalog(
        &catalog,
        "principal-1",
        "model-secret",
        &.{.{ .id = "model-1", .display_name = "Model One" }},
    );
    var completion = metask_provider.OwnedCatalogCompletion.init(&catalog);
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
    try std.testing.expectEqualStrings("model-1", first.metask_selection.?.model_id);
    try std.testing.expect(first.providers[0].source_generation != 0);
    try std.testing.expect(first.metask_selection_revision != 0);
    try std.testing.expect(first.default_selection == null);
    const first_source_generation = first.providers[0].source_generation;
    const first_selection_revision = first.metask_selection_revision;
    const first_catalog_generation = first.providers[0].catalog_generation;

    const refreshed = switch (runtime.prepareMetaskCatalogRefresh("principal-1", 6)) {
        .ready => |value| value,
        .rejected => return error.TestUnexpectedResult,
    };
    var same_catalog = metask_provider.CatalogSession.init(std.testing.allocator);
    try metask_provider.TestSupport.replaceOwnedCatalog(
        &same_catalog,
        "principal-1",
        "rotated-model-secret",
        &.{.{ .id = "model-1", .display_name = "Model One" }},
    );
    var refreshed_completion = metask_provider.OwnedCatalogCompletion.init(&same_catalog);
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
            .source_id = "metask",
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
        "metask",
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
    try std.testing.expectEqual(
        contract.Protocol.anthropic_messages,
        second_candidate.input().target.protocol,
    );
    try std.testing.expectEqualStrings(
        contract.metask_anthropic_messages_url,
        second_candidate.input().target.base_url,
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
        try metask_provider.TestSupport.replaceOwnedCatalog(
            &initial_catalog,
            "principal-1",
            "initial-secret",
            &.{.{ .id = "model-1", .display_name = "Model One" }},
        );
        var initial_completion = metask_provider.OwnedCatalogCompletion.init(&initial_catalog);
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
            .selection = .{ .source_id = "metask", .model_id = "model-1" },
            .expected_selection_revision = initial_view.selection_revision,
            .expected_source_generation = initial_view.providers[0].source_generation,
            .expected_catalog_generation = initial_view.providers[0].catalog_generation,
        }).accepted);
        const previous_selection_revision = runtime.view().selection_revision;

        const refresh = switch (runtime.prepareMetaskCatalogRefresh("principal-1", 6)) {
            .ready => |value| value,
            .rejected => return error.TestUnexpectedResult,
        };
        var replacement_catalog = metask_provider.CatalogSession.init(std.testing.allocator);
        defer replacement_catalog.deinit();
        try metask_provider.TestSupport.replaceOwnedCatalog(
            &replacement_catalog,
            "principal-1",
            "replacement-secret",
            &.{.{ .id = "model-2", .display_name = "Model Two" }},
        );
        var replacement_completion = metask_provider.OwnedCatalogCompletion.init(&replacement_catalog);
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
        try std.testing.expectEqualStrings("metask", drifted.metask_selection.?.source_id);
        try std.testing.expectEqualStrings("model-1", drifted.metask_selection.?.model_id);
        try std.testing.expectEqualStrings("metask", drifted.default_selection.?.source_id);
        try std.testing.expectEqualStrings("model-1", drifted.default_selection.?.model_id);
        try std.testing.expectEqual(previous_selection_revision, drifted.selection_revision);
        try std.testing.expectEqual(contract.CatalogState.ready, drifted.providers[0].catalog_state);
        try std.testing.expectEqualStrings("model-2", drifted.providers[0].models[0].id);
        try std.testing.expect(!runtime.defaultResolvable());
        try std.testing.expect((try runtime.resolveDefault()) == null);
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
        try std.testing.expectEqual(
            contract.CatalogState.needs_authentication,
            restored.providers[0].catalog_state,
        );
        try std.testing.expectEqual(@as(usize, 0), restored.providers[0].models.len);
        try std.testing.expectEqualStrings("metask", restored.metask_selection.?.source_id);
        try std.testing.expectEqualStrings("model-1", restored.metask_selection.?.model_id);
        try std.testing.expectEqualStrings("metask", restored.default_selection.?.source_id);
        try std.testing.expectEqualStrings("model-1", restored.default_selection.?.model_id);
        try std.testing.expectEqual(committed_selection_revision, restored.selection_revision);
    }
}

test "Models bootstrap initializes canonical store and ignores retired files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var directory_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory_len = try tmp.dir.realPath(std.testing.io, &directory_storage);
    const directory = directory_storage[0..directory_len];
    try writeTestFile(
        &tmp.dir,
        "preferences.json",
        "{\"selection_owner_account_id\":\"retired\"}",
    );
    try writeTestFile(&tmp.dir, "custom-providers.json", "not-json");

    var vault: TestVault = .{};
    var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
    try runtime.start(directory, vault.port());
    defer {
        runtime.stop();
        runtime.deinit();
    }

    try std.testing.expect(runtime.store_healthy);
    const view = runtime.view();
    try std.testing.expect(view.metask_selection == null);
    try std.testing.expect(view.default_selection == null);
    try std.testing.expectEqual(@as(usize, 0), view.custom_providers.len);
    const bytes = (try runtime.store.?.loadAlloc(std.testing.allocator)) orelse
        return error.TestExpectedEqual;
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings(
        "{\"schema\":2,\"metask\":null,\"default_selection\":null,\"selection_revision\":0,\"pending_credential_deletions\":[],\"custom_providers\":[]}",
        bytes,
    );
}

test "Models bootstrap rejects damaged canonical shapes" {
    const inputs = [_][]const u8{
        "{\"schema\":1,\"metask\":null,\"default_selection\":null,\"selection_revision\":0,\"pending_credential_deletions\":[]}",
        "{\"schema\":1,\"metask\":null,\"default_selection\":null,\"selection_revision\":0,\"pending_credential_deletions\":[],\"custom_providers\":[],\"unknown\":true}",
        "not-json",
    };
    for (inputs) |input| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var directory_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const directory_len = try tmp.dir.realPath(std.testing.io, &directory_storage);
        try writeTestFile(&tmp.dir, registry_impl.store_file_name, input);

        var vault: TestVault = .{};
        var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
        try runtime.start(directory_storage[0..directory_len], vault.port());
        defer {
            runtime.stop();
            runtime.deinit();
        }

        try std.testing.expect(!runtime.store_healthy);
        try std.testing.expectEqual(contract.CatalogState.unavailable, runtime.view().availability);
        try std.testing.expectEqual(
            contract.PersistenceHealth.recovery_required,
            runtime.view().persistence_health,
        );
        const bytes = (try runtime.store.?.loadAlloc(std.testing.allocator)) orelse
            return error.TestExpectedEqual;
        defer std.testing.allocator.free(bytes);
        try std.testing.expectEqualStrings(input, bytes);
    }
}

test "Models reset replaces damaged canonical bytes with current empty schema" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var directory_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory_len = try tmp.dir.realPath(std.testing.io, &directory_storage);
    try writeTestFile(
        &tmp.dir,
        registry_impl.store_file_name,
        "{\"schema\":1,\"metask\":null,\"default_selection\":null,\"selection_revision\":0,\"pending_credential_deletions\":[]}",
    );

    var vault: TestVault = .{};
    var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
    try runtime.start(directory_storage[0..directory_len], vault.port());
    defer {
        runtime.stop();
        runtime.deinit();
    }
    try std.testing.expect(!runtime.store_healthy);
    try std.testing.expectEqual(
        contract.PersistenceHealth.recovery_required,
        runtime.view().persistence_health,
    );
    try std.testing.expect(runtime.resetStore().accepted);
    try std.testing.expect(runtime.store_healthy);
    try std.testing.expectEqual(contract.PersistenceHealth.ready, runtime.view().persistence_health);
    try std.testing.expectEqual(@as(usize, 0), runtime.views().len);
    try std.testing.expect(runtime.view().metask_selection == null);
    try std.testing.expect(runtime.view().default_selection == null);
    const bytes = (try runtime.store.?.loadAlloc(std.testing.allocator)) orelse
        return error.TestExpectedEqual;
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings(
        "{\"schema\":2,\"metask\":null,\"default_selection\":null,\"selection_revision\":0,\"pending_credential_deletions\":[],\"custom_providers\":[]}",
        bytes,
    );
}

test "Models reset rejects healthy store and non-destructively recovers a valid canonical" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var directory_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory_len = try tmp.dir.realPath(std.testing.io, &directory_storage);
    var vault: TestVault = .{};
    var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
    try runtime.start(directory_storage[0..directory_len], vault.port());
    defer {
        runtime.stop();
        runtime.deinit();
    }
    try createTestProviderWithModel(
        &runtime,
        "reset-secret",
        .{
            .display_name = "Reset me",
            .protocol = .openai_responses,
            .normalized_base_url = "https://api.openai.com/v1/responses",
        },
        .{ .id = "gpt-5", .display_name = "GPT-5" },
    );
    try std.testing.expect(vault.present);
    try std.testing.expectEqual(
        contract.ManagementError.persistence_unavailable,
        runtime.resetStore().error_code.?,
    );
    try std.testing.expect(vault.present);
    try std.testing.expectEqual(@as(usize, 1), runtime.views().len);

    const canonical_before = (try runtime.store.?.loadAlloc(std.testing.allocator)) orelse
        return error.TestExpectedEqual;
    defer std.testing.allocator.free(canonical_before);

    // A prior uncertain result must not authorize destroying a canonical that
    // strict readback now proves valid.
    runtime.store_healthy = false;
    try std.testing.expectEqual(
        contract.PersistenceHealth.recovery_required,
        runtime.view().persistence_health,
    );
    try std.testing.expect(runtime.resetStore().accepted);
    try std.testing.expect(vault.present);
    try std.testing.expectEqual(@as(usize, 1), runtime.views().len);
    try std.testing.expect(runtime.view().default_selection == null);
    try std.testing.expectEqual(@as(usize, 0), runtime.registry.credentialDeletions().len);
    const canonical_after = (try runtime.store.?.loadAlloc(std.testing.allocator)) orelse
        return error.TestExpectedEqual;
    defer std.testing.allocator.free(canonical_after);
    try std.testing.expectEqualStrings(canonical_before, canonical_after);
}

test "Models reset durably reconciles interrupted tests in a valid canonical" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var directory_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory_len = try tmp.dir.realPath(std.testing.io, &directory_storage);
    var vault: TestVault = .{};
    var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
    try runtime.start(directory_storage[0..directory_len], vault.port());
    defer {
        runtime.stop();
        runtime.deinit();
    }
    try createTestProviderWithModel(
        &runtime,
        "reset-secret",
        .{
            .display_name = "Interrupted",
            .protocol = .openai_responses,
            .normalized_base_url = "https://api.openai.com/v1/responses",
        },
        .{ .id = "gpt-5", .display_name = "GPT-5" },
    );
    const provider = runtime.views()[0];
    try std.testing.expect(runtime.submitCommand(.{ .test_model = .{
        .model = .{ .source_id = provider.id, .model_id = "gpt-5" },
        .expected_provider_revision = provider.provider_revision,
        .expected_source_generation = provider.source_generation,
        .expected_catalog_generation = provider.catalog_generation,
    } }).accepted);
    try std.testing.expectEqual(
        contract.CustomModelTestStatus.testing,
        runtime.views()[0].models[0].test_status,
    );

    runtime.store_healthy = false;
    try std.testing.expect(runtime.resetStore().accepted);
    try std.testing.expect(runtime.store_healthy);
    try std.testing.expectEqual(
        contract.CustomModelTestStatus.failed,
        runtime.views()[0].models[0].test_status,
    );

    const bytes = (try runtime.store.?.loadAlloc(std.testing.allocator)) orelse
        return error.TestExpectedEqual;
    defer std.testing.allocator.free(bytes);
    var restored = try registry_impl.decode(std.testing.allocator, bytes);
    defer restored.deinit();
    try std.testing.expect(!restored.reconcileInterruptedTests());
}

test "Models reset rejects unavailable persistence capability" {
    var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
    runtime.startUnavailable();
    defer runtime.deinit();

    try std.testing.expectEqual(
        contract.PersistenceHealth.unavailable,
        runtime.view().persistence_health,
    );
    try std.testing.expectEqual(
        contract.ManagementError.persistence_unavailable,
        runtime.resetStore().error_code.?,
    );
}

fn writeTestFile(dir: *std.Io.Dir, name: []const u8, bytes: []const u8) !void {
    const file = try dir.createFile(std.testing.io, name, .{ .exclusive = true });
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, bytes);
    try file.sync(std.testing.io);
}

test "successful empty Metask catalog preserves intent but removes all resolvable members" {
    var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
    defer runtime.deinit();
    try TestSupport.installMetaskDefault(
        &runtime,
        "principal-1",
        "old-secret",
        &.{.{ .id = "model-1", .display_name = "Model One" }},
        "model-1",
        1,
        2,
        3,
        4,
    );
    try std.testing.expectEqual(contract.ModelsError.none, try TestSupport.refreshMetaskCatalog(&runtime, "principal-1", &.{}));
    const view = runtime.view();
    try std.testing.expectEqual(contract.CatalogState.ready, view.providers[0].catalog_state);
    try std.testing.expectEqual(contract.ModelsError.no_models, view.providers[0].error_code);
    try std.testing.expectEqual(@as(usize, 0), view.providers[0].models.len);
    try std.testing.expect(view.providers[0].catalog_generation != 4);
    try std.testing.expectEqual(@as(u64, 1), view.providers[0].source_generation);
    try std.testing.expectEqual(@as(u64, 2), view.metask_selection_revision);
    try std.testing.expectEqual(@as(u64, 3), view.selection_revision);
    try std.testing.expectEqualStrings("model-1", view.metask_selection.?.model_id);
    try std.testing.expectEqualStrings("model-1", view.default_selection.?.model_id);
    try std.testing.expect(!runtime.defaultResolvable());
    try std.testing.expect((try runtime.resolveDefault()) == null);
    try std.testing.expect(!runtime.configureMetaskSelection(.{
        .selection = .{ .source_id = "metask", .model_id = "model-1" },
        .expected_metask_selection_revision = view.metask_selection_revision,
        .expected_catalog_generation = view.providers[0].catalog_generation,
    }).accepted);
}

test "fixed image model resolves without user configuration alongside a Custom dialogue default" {
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
    try createTestProviderWithModel(&runtime, "custom-secret", .{
        .display_name = "Custom",
        .protocol = .openai_responses,
        .normalized_base_url = "https://example.com/v1/responses",
    }, .{ .id = "chat" });
    const provider = runtime.views()[0];
    const probe: contract.CustomModelTestCommand = .{
        .model = .{ .source_id = TestVault.slot, .model_id = "chat" },
        .expected_provider_revision = provider.provider_revision,
        .expected_source_generation = provider.source_generation,
        .expected_catalog_generation = provider.catalog_generation,
    };
    try std.testing.expect(runtime.submitCommand(.{ .test_model = probe }).accepted);
    try std.testing.expect(runtime.completeTest(probe, true).accepted);
    try std.testing.expect(runtime.selectDefault(.{
        .selection = probe.model,
        .expected_selection_revision = 0,
        .expected_source_generation = probe.expected_source_generation,
        .expected_catalog_generation = probe.expected_catalog_generation,
    }).accepted);
    const dialogue_revision = runtime.view().selection_revision;
    const catalog = test_image_catalog;
    try std.testing.expectEqual(contract.ModelsError.none, try TestSupport.refreshMetaskCatalogResponse(&runtime, "principal-a", catalog));
    try std.testing.expectEqual(contract.ModelsError.no_models, runtime.view().providers[0].error_code);
    try std.testing.expectEqual(@as(usize, 0), runtime.view().providers[0].models.len);
    var lease = "fresh-lease".*;
    const input: contract.ImagePreparationInput = .{ .principal_ref = "principal-a", .authorization_generation = 17, .bearer = &lease };
    var candidate = runtime.prepareImageCandidate(input).ready;
    defer candidate.deinit();
    @memset(&lease, 0);
    try std.testing.expectEqualStrings("fresh-lease", candidate.input().bearer);
    try std.testing.expectEqualStrings("gemini-3.1-flash-image-preview", candidate.input().selection.model_id);
    try std.testing.expectEqualStrings(contract.metask_images_generations_url, candidate.input().endpoint);
    const bytes = (try runtime.store.?.loadAlloc(std.testing.allocator)).?;
    defer std.testing.allocator.free(bytes);
    for ([_][]const u8{ "fresh-lease", "refreshed-secret", "custom-secret", "metask_image" }) |secret|
        try std.testing.expect(std.mem.indexOf(u8, bytes, secret) == null);
    runtime.setMetaskAuthorizationUnavailable();
    try std.testing.expectEqual(contract.ManagementError.catalog_unavailable, runtime.prepareImageCandidate(input).rejected);
    try std.testing.expectEqualStrings("fresh-lease", candidate.input().bearer);
    var dialogue = (try runtime.resolveDefault()).?;
    defer dialogue.deinit();
    try std.testing.expectEqualStrings("chat", dialogue.input().target.model);
    try std.testing.expectEqualStrings("custom-secret", dialogue.input().api_key);
    try std.testing.expectEqual(dialogue_revision, runtime.view().selection_revision);
    runtime.stop();
    try runtime.start(directory, vault.port());
    try std.testing.expectEqual(contract.ModelsError.none, try TestSupport.refreshMetaskCatalogResponse(&runtime, "principal-b", catalog));
    var current = input;
    current.bearer = "new-account-lease";
    try std.testing.expectEqual(contract.ManagementError.authorization_unavailable, runtime.prepareImageCandidate(current).rejected);
    current.principal_ref = "principal-b";
    var restarted = runtime.prepareImageCandidate(current).ready;
    defer restarted.deinit();
    try std.testing.expectEqualStrings(contract.metask_default_image_model, restarted.input().selection.model_id);
    try std.testing.expectEqual(dialogue_revision, runtime.view().selection_revision);
}

const test_image_catalog = "{\"object\":\"list\",\"has_more\":false,\"data\":[{\"id\":\"" ++ contract.metask_default_image_model ++ "\",\"object\":\"model\",\"type\":\"model\",\"capabilities\":{\"endpoints\":{\"images_generations\":{\"supported\":true}}}}]}";

test "image preparation requires current lease and falls back only before sending" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path);
    var vault: TestVault = .{};
    var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
    try runtime.start(path[0..len], vault.port());
    defer {
        runtime.stop();
        runtime.deinit();
    }
    const input: contract.ImagePreparationInput = .{ .principal_ref = "principal", .authorization_generation = 17, .bearer = "fresh-secret" };
    try std.testing.expectEqual(contract.ManagementError.catalog_unavailable, runtime.prepareImageCandidate(input).rejected);
    try std.testing.expectEqual(contract.ModelsError.none, try TestSupport.refreshMetaskCatalogResponse(&runtime, "principal", test_image_catalog));
    for (0..4) |case| {
        var wrong = input;
        switch (case) {
            0 => wrong.principal_ref = "other",
            1 => wrong.authorization_generation = 0,
            2 => wrong.authorization_generation = 18,
            3 => wrong.bearer = "",
            else => unreachable,
        }
        try std.testing.expectEqual(contract.ManagementError.authorization_unavailable, runtime.prepareImageCandidate(wrong).rejected);
    }
    const preparation = runtime.prepareMetaskCatalogRefresh("principal", 18).ready;
    try std.testing.expectEqual(contract.ManagementError.catalog_unavailable, runtime.prepareImageCandidate(input).rejected);
    var session = metask_provider.CatalogSession.init(std.testing.allocator);
    defer session.deinit();
    try metask_provider.TestSupport.loadCatalogResponse(&session, "principal", "catalog-secret", test_image_catalog);
    var completion = metask_provider.OwnedCatalogCompletion.init(&session);
    var port = completion.ownedPort();
    try std.testing.expectEqual(contract.ModelsError.none, runtime.completeMetaskCatalogRefresh(preparation.attempt_id, 18, &port));
    try std.testing.expectEqual(contract.ManagementError.authorization_unavailable, runtime.prepareImageCandidate(input).rejected);
    var refreshed = input;
    refreshed.authorization_generation = 18;
    var candidate = runtime.prepareImageCandidate(refreshed).ready;
    defer candidate.deinit();
    try std.testing.expectEqualStrings("fresh-secret", candidate.input().bearer);
    const unsupported = "{\"object\":\"list\",\"has_more\":false,\"data\":[{\"id\":\"" ++ contract.metask_default_image_model ++ "\",\"object\":\"model\",\"type\":\"model\",\"capabilities\":{\"endpoints\":{\"images_generations\":{\"supported\":false}}}}]}";
    const absent = "{\"object\":\"list\",\"has_more\":false,\"data\":[{\"id\":\"other-image\",\"object\":\"model\",\"type\":\"model\",\"capabilities\":{\"endpoints\":{\"images_generations\":{\"supported\":true}}}}]}";
    for ([_][]const u8{ unsupported, "{\"object\":\"list\",\"has_more\":false,\"data\":[]}" }) |body| {
        try std.testing.expectEqual(contract.ModelsError.none, try TestSupport.refreshMetaskCatalogResponse(&runtime, "principal", body));
        try std.testing.expectEqual(contract.ManagementError.model_not_found, runtime.prepareImageCandidate(input).rejected);
    }
    try std.testing.expectEqual(contract.ModelsError.none, try TestSupport.refreshMetaskCatalogResponse(&runtime, "principal", absent));
    var fallback = runtime.prepareImageCandidate(input).ready;
    defer fallback.deinit();
    try std.testing.expectEqualStrings("other-image", fallback.input().selection.model_id);
    try std.testing.expectEqualStrings("fresh-secret", candidate.input().bearer);
    try std.testing.expectEqualStrings(contract.metask_default_image_model, candidate.input().selection.model_id);
}

test "first empty Metask catalog has no inferred selection" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(std.testing.io, &path);
    var vault: TestVault = .{};
    var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
    try runtime.start(path[0..length], vault.port());
    defer {
        runtime.stop();
        runtime.deinit();
    }
    try std.testing.expectEqual(contract.ModelsError.none, try TestSupport.refreshMetaskCatalog(&runtime, "principal-1", &.{}));
    const view = runtime.view();
    try std.testing.expectEqual(contract.CatalogState.ready, view.providers[0].catalog_state);
    try std.testing.expectEqual(contract.ModelsError.no_models, view.providers[0].error_code);
    try std.testing.expect(view.providers[0].catalog_generation != 0);
    try std.testing.expect(view.metask_selection == null);
    try std.testing.expect(view.default_selection == null);
    try std.testing.expect(!runtime.defaultResolvable());
    // A later populated catalog is still the first selection initialization.
    try std.testing.expectEqual(contract.ModelsError.none, try TestSupport.refreshMetaskCatalog(&runtime, "principal-1", &.{.{ .id = "model-2", .display_name = "Model Two" }}));
    try std.testing.expectEqualStrings("model-2", runtime.view().metask_selection.?.model_id);
    try std.testing.expect(runtime.view().default_selection == null);
}

test "stale Metask completion leaves the current catalog attempt intact" {
    var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
    defer runtime.deinit();
    try TestSupport.installMetaskDefault(
        &runtime,
        "principal-1",
        "old-secret",
        &.{.{ .id = "model-1", .display_name = "Model One" }},
        "model-1",
        1,
        2,
        3,
        4,
    );
    const preparation = switch (runtime.prepareMetaskCatalogRefresh("principal-1", 17)) {
        .ready => |value| value,
        .rejected => return error.TestUnexpectedResult,
    };
    var session = metask_provider.CatalogSession.init(std.testing.allocator);
    try metask_provider.TestSupport.replaceOwnedCatalog(&session, "principal-1", "stale-secret", &.{});
    var completion = metask_provider.OwnedCatalogCompletion.init(&session);
    var port = completion.ownedPort();
    try std.testing.expectEqual(contract.ModelsError.catalog_invalid, runtime.completeMetaskCatalogRefresh(preparation.attempt_id, 16, &port));
    try std.testing.expectEqual(preparation.attempt_id, runtime.catalog_attempt.?.id);
    try std.testing.expectEqual(contract.CatalogState.loading, runtime.view().providers[0].catalog_state);
    try std.testing.expectEqual(@as(u64, 4), runtime.view().providers[0].catalog_generation);
}

test "declared protocol refresh changes default authority and preserves old owned candidates" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(std.testing.io, &path);
    var vault: TestVault = .{};
    var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
    try runtime.start(path[0..length], vault.port());
    defer {
        runtime.stop();
        runtime.deinit();
    }
    const initial =
        \\{"object":"list","has_more":false,"data":[{"id":"model-1","object":"model","type":"model","capabilities":{"endpoints":{"messages":{"supported":true}}}}]}
    ;
    try std.testing.expectEqual(contract.ModelsError.none, try TestSupport.refreshMetaskCatalogResponse(&runtime, "principal-1", initial));
    const initial_view = runtime.view();
    try std.testing.expect(runtime.selectMetaskDefault(.{
        .selection = .{ .source_id = "metask", .model_id = "model-1" },
        .expected_selection_revision = initial_view.selection_revision,
        .expected_source_generation = initial_view.providers[0].source_generation,
        .expected_catalog_generation = initial_view.providers[0].catalog_generation,
    }).accepted);
    const old_source = runtime.defaultAuthority().?.source_generation;
    const old_selection = runtime.view().selection_revision;
    const old_local_selection = runtime.view().metask_selection_revision;
    var old_owned = (try runtime.resolveDefault()).?;
    defer old_owned.deinit();

    const replacement =
        \\{"object":"list","has_more":false,"data":[{"id":"model-1","object":"model","type":"model","capabilities":{"endpoints":{"messages":{"supported":false,"status":"unknown"},"chat_completions":{"supported":true}}}},{"id":"model-2","object":"model","type":"model","capabilities":{"endpoints":{"responses":{"supported":true},"chat_completions":{"supported":true}}}}]}
    ;
    try std.testing.expectEqual(contract.ModelsError.none, try TestSupport.refreshMetaskCatalogResponse(&runtime, "principal-1", replacement));
    const current = runtime.view();
    try std.testing.expectEqualStrings("model-1", current.default_selection.?.model_id);
    try std.testing.expectEqual(old_local_selection, current.metask_selection_revision);
    try std.testing.expectEqual(old_selection, current.selection_revision);
    try std.testing.expect(current.providers[0].source_generation != old_source);
    try std.testing.expectEqual(contract.Protocol.openai_chat_completions, runtime.defaultAuthority().?.protocol);
    try std.testing.expect(!runtime.metaskSourceModelAvailable(.{ .source_id = "metask", .model_id = "model-1" }, old_source, current.providers[0].catalog_generation, .anthropic_messages));
    try std.testing.expect(runtime.metaskSourceModelAvailable(.{ .source_id = "metask", .model_id = "model-1" }, current.providers[0].source_generation, current.providers[0].catalog_generation, .openai_chat_completions));
    try std.testing.expect(!runtime.metaskModelAvailable(null, .openai_chat_completions, "model-2"));
    try std.testing.expect(runtime.metaskModelAvailable(null, .openai_responses, "model-2"));
    var new_owned = (try runtime.resolveDefault()).?;
    defer new_owned.deinit();
    try std.testing.expectEqual(contract.Protocol.openai_chat_completions, new_owned.input().target.protocol);
    try std.testing.expectEqualStrings(contract.metaskEndpoint(.openai_chat_completions).?, new_owned.input().target.base_url);
    try std.testing.expectEqual(contract.Protocol.anthropic_messages, old_owned.input().target.protocol);
    try std.testing.expectEqualStrings(contract.metaskEndpoint(.anthropic_messages).?, old_owned.input().target.base_url);

    try std.testing.expect(runtime.configureMetaskSelection(.{
        .selection = .{ .source_id = "metask", .model_id = "model-2" },
        .expected_metask_selection_revision = current.metask_selection_revision,
        .expected_catalog_generation = current.providers[0].catalog_generation,
    }).accepted);
    try std.testing.expectEqual(contract.Protocol.openai_responses, runtime.defaultAuthority().?.protocol);
    try std.testing.expectEqualStrings("model-2", runtime.view().default_selection.?.model_id);
}

test "image model policy prefers the default and then the first declared generation endpoint" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    var vault: TestVault = .{};
    var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
    try runtime.start(path, vault.port());
    defer {
        runtime.stop();
        runtime.deinit();
    }
    const entries = "{\"id\":\"text\",\"object\":\"model\",\"type\":\"model\",\"capabilities\":{\"endpoints\":{\"messages\":{\"supported\":true}}}}," ++
        "{\"id\":\"video\",\"object\":\"model\",\"type\":\"model\",\"capabilities\":{\"endpoints\":{\"videos\":{\"supported\":true}}}}," ++
        "{\"id\":\"guessed-image\",\"object\":\"model\",\"type\":\"model\",\"capabilities\":{\"output\":{\"image\":{\"supported\":true}}}}," ++
        "{\"id\":\"first-image\",\"object\":\"model\",\"type\":\"model\",\"capabilities\":{\"endpoints\":{\"images_generations\":{\"supported\":true}}}}," ++
        "{\"id\":\"second-image\",\"object\":\"model\",\"type\":\"model\",\"capabilities\":{\"endpoints\":{\"images_generations\":{\"supported\":true}}}}";
    const fallback_catalog = "{\"object\":\"list\",\"has_more\":false,\"data\":[" ++ entries ++ "]}";
    const preferred_catalog = "{\"object\":\"list\",\"has_more\":false,\"data\":[" ++ entries ++ "," ++
        "{\"id\":\"" ++ contract.metask_default_image_model ++ "\",\"object\":\"model\",\"type\":\"model\",\"capabilities\":{\"endpoints\":{\"images_generations\":{\"supported\":true}}}}]}";
    const input: contract.ImagePreparationInput = .{ .principal_ref = "principal", .authorization_generation = 17, .bearer = "fresh-lease" };
    try std.testing.expectEqual(contract.ModelsError.none, try TestSupport.refreshMetaskCatalogResponse(&runtime, "principal", preferred_catalog));
    var preferred = runtime.prepareImageCandidate(input).ready;
    defer preferred.deinit();
    try std.testing.expectEqualStrings(contract.metask_default_image_model, preferred.input().selection.model_id);
    try std.testing.expectEqual(@as(usize, 1), runtime.view().providers[0].models.len);
    try std.testing.expectEqualStrings("text", runtime.view().providers[0].models[0].id);
    try std.testing.expectEqual(contract.ModelsError.none, try TestSupport.refreshMetaskCatalogResponse(&runtime, "principal", fallback_catalog));
    var fallback = runtime.prepareImageCandidate(input).ready;
    defer fallback.deinit();
    try std.testing.expectEqualStrings("first-image", fallback.input().selection.model_id);
    try std.testing.expectEqualStrings(contract.metask_default_image_model, preferred.input().selection.model_id);
}
