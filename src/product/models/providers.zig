//! Product Models-owned registry for user-managed model services.
//!
//! This module stores only public provider metadata. The platform credential
//! account is derived from the public provider identity; neither credential
//! bytes nor a separate platform locator enter this registry or its views.

const std = @import("std");
const builtin = @import("builtin");
const contract = @import("metawork_product_models_contract");

pub const max_store_bytes: usize = 64 * 1024;
pub const store_file_name = "models.json";
pub const max_pending_credential_deletions: usize =
    contract.Limits.custom_provider_entries * 4;

pub const Error = error{
    Capacity,
    InvalidProvider,
    ProviderNotFound,
    GenerationMismatch,
    ModelNotFound,
    InvalidData,
};

pub const FileStoreError = error{
    OpenFailed,
    ReadFailed,
    WriteFailed,
    PersistenceOutcomeUnknown,
};

const OwnedModel = struct {
    id: []u8,
    display_name: []u8,
    metadata: contract.ModelMetadata = .{},
    metadata_provenance: contract.ModelMetadataProvenance = .unknown,
    test_status: contract.CustomModelTestStatus = .untested,
    ready_source_generation: u64 = 0,

    fn deinit(self: *OwnedModel, allocator: std.mem.Allocator) void {
        allocator.free(self.display_name);
        allocator.free(self.id);
        self.* = undefined;
    }
};

const OwnedProvider = struct {
    id: []u8,
    builtin_provider_id: ?contract.BuiltinProviderId = null,
    display_name: []u8,
    normalized_base_url: []u8,
    protocol: contract.Protocol,
    state: contract.CustomProviderState = .configuring,
    credential_status: contract.CustomProviderCredentialStatus = .ready,
    enabled: bool = true,
    provider_revision: u64,
    source_generation: u64,
    catalog_generation: u64,
    models: std.ArrayList(OwnedModel) = .empty,

    fn deinit(self: *OwnedProvider, allocator: std.mem.Allocator) void {
        for (self.models.items) |*model| model.deinit(allocator);
        self.models.deinit(allocator);
        allocator.free(self.normalized_base_url);
        allocator.free(self.display_name);
        allocator.free(self.id);
        self.* = undefined;
    }

    fn view(self: *const OwnedProvider) contract.CustomProviderView {
        var models: []const contract.CustomProviderModelView = &.{};
        if (self.models.items.len != 0) {
            // OwnedModel has the same public fields but a different ownership
            // type, so a caller must use Registry.viewStorage below.
            models = &.{};
        }
        return .{
            .id = self.id,
            .builtin_provider_id = self.builtin_provider_id,
            .display_name = self.display_name,
            .protocol = self.protocol,
            .normalized_base_url = self.normalized_base_url,
            .state = self.state,
            .credential_status = self.credential_status,
            .enabled = self.enabled,
            .models = models,
            .provider_revision = self.provider_revision,
            .source_generation = self.source_generation,
            .catalog_generation = self.catalog_generation,
        };
    }
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    providers: std.ArrayList(OwnedProvider) = .empty,
    pending_credential_deletions: std.ArrayList([]u8) = .empty,
    metask_principal_ref: []u8 = &.{},
    metask_source_generation: u64 = 0,
    default_source_id: []u8 = &.{},
    default_model_id: []u8 = &.{},
    selection_revision: u64 = 0,
    view_storage: std.ArrayList(contract.CustomProviderView) = .empty,
    model_view_storage: std.ArrayList(contract.CustomProviderModelView) = .empty,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Registry) void {
        for (self.providers.items) |*provider|
            provider.deinit(self.allocator);
        self.providers.deinit(self.allocator);
        for (self.pending_credential_deletions.items) |provider_id|
            self.allocator.free(provider_id);
        self.pending_credential_deletions.deinit(self.allocator);
        self.view_storage.deinit(self.allocator);
        self.model_view_storage.deinit(self.allocator);
        self.freeSelectionText(&self.metask_principal_ref);
        self.freeSelectionText(&self.default_source_id);
        self.freeSelectionText(&self.default_model_id);
        self.* = undefined;
    }

    pub fn clone(self: *const Registry) (std.mem.Allocator.Error || Error)!Registry {
        var result = Registry.init(self.allocator);
        errdefer result.deinit();
        result.metask_source_generation = self.metask_source_generation;
        result.selection_revision = self.selection_revision;
        try result.pending_credential_deletions.ensureTotalCapacity(
            self.allocator,
            self.pending_credential_deletions.items.len,
        );
        for (self.pending_credential_deletions.items) |provider_id| {
            const owned = try self.allocator.dupe(u8, provider_id);
            errdefer self.allocator.free(owned);
            try result.pending_credential_deletions.append(
                self.allocator,
                owned,
            );
        }
        if (self.metask_principal_ref.len != 0)
            result.metask_principal_ref = try self.allocator.dupe(u8, self.metask_principal_ref);
        if (self.default_source_id.len != 0)
            result.default_source_id = try self.allocator.dupe(u8, self.default_source_id);
        if (self.default_model_id.len != 0)
            result.default_model_id = try self.allocator.dupe(u8, self.default_model_id);
        try result.providers.ensureTotalCapacity(
            self.allocator,
            self.providers.items.len,
        );
        for (self.providers.items) |provider|
            try result.providers.append(
                self.allocator,
                try cloneProvider(self.allocator, provider),
            );
        return result;
    }

    pub fn replace(self: *Registry, replacement: *Registry) void {
        const old = self.*;
        self.* = replacement.*;
        replacement.* = old;
    }

    fn freeSelectionText(self: *Registry, value: *[]u8) void {
        if (value.len != 0) self.allocator.free(value.*);
        value.* = &.{};
    }

    pub fn views(self: *Registry) []const contract.CustomProviderView {
        self.rebuildViews();
        return self.view_storage.items;
    }

    pub fn create(
        self: *Registry,
        input: contract.CustomProviderCreateCommand,
        provider_revision: u64,
        source_generation: u64,
        catalog_generation: u64,
    ) (std.mem.Allocator.Error || Error)!void {
        if (self.providers.items.len >= contract.Limits.custom_provider_entries)
            return error.Capacity;
        contract.validateCustomProviderSpec(input.spec) catch
            return error.InvalidProvider;
        if (input.credential_slot.id.len == 0 or
            provider_revision == 0 or source_generation == 0 or
            catalog_generation == 0)
            return error.InvalidProvider;
        if (input.provider_id.len == 0 or
            input.provider_id.len > contract.Limits.instance_id_bytes or
            !std.mem.eql(u8, input.provider_id, input.credential_slot.id) or
            self.findIndex(input.provider_id) != null)
            return error.InvalidProvider;
        var provider: OwnedProvider = .{
            .id = try self.allocator.dupe(u8, input.provider_id),
            .builtin_provider_id = input.spec.builtin_provider_id,
            .display_name = try self.allocator.dupe(u8, input.spec.display_name),
            .normalized_base_url = try self.allocator.dupe(u8, input.spec.normalized_base_url),
            .protocol = input.spec.protocol,
            .state = .configuring,
            .provider_revision = provider_revision,
            .source_generation = source_generation,
            .catalog_generation = catalog_generation,
        };
        errdefer provider.deinit(self.allocator);
        if (input.spec.initial_model) |model| {
            try provider.models.ensureUnusedCapacity(self.allocator, 1);
            const owned: OwnedModel = make: {
                const id = try self.allocator.dupe(u8, model.id);
                errdefer self.allocator.free(id);
                const display_name = try self.allocator.dupe(u8, model.display_name);
                break :make .{ .id = id, .display_name = display_name, .metadata = model.metadata, .metadata_provenance = .user_declared };
            };
            provider.models.appendAssumeCapacity(owned);
        }
        try self.providers.append(self.allocator, provider);
    }

    pub fn remove(
        self: *Registry,
        selection: contract.CustomProviderSelectionCommand,
    ) (std.mem.Allocator.Error || Error)!void {
        const index = self.findIndex(selection.source_id) orelse
            return error.ProviderNotFound;
        const provider = &self.providers.items[index];
        if (provider.provider_revision != selection.expected_provider_revision)
            return error.GenerationMismatch;
        if (self.pending_credential_deletions.items.len >=
            max_pending_credential_deletions)
            return error.Capacity;

        const cleanup_id = try self.allocator.dupe(u8, provider.id);
        errdefer self.allocator.free(cleanup_id);
        try self.pending_credential_deletions.append(self.allocator, cleanup_id);
        provider.deinit(self.allocator);
        _ = self.providers.orderedRemove(index);
    }

    /// Persists an intent to delete a not-yet-committed credential. Creation
    /// writes this recovery fact before touching the platform credential
    /// store, then removes it atomically with the new provider metadata.
    pub fn reserveCredentialDeletion(
        self: *Registry,
        provider_id: []const u8,
    ) (std.mem.Allocator.Error || Error)!void {
        if (provider_id.len == 0 or
            provider_id.len > contract.Limits.instance_id_bytes or
            self.findIndex(provider_id) != null or
            self.pending_credential_deletions.items.len >=
                max_pending_credential_deletions)
            return error.InvalidProvider;
        for (self.pending_credential_deletions.items) |candidate|
            if (std.mem.eql(u8, candidate, provider_id))
                return error.InvalidProvider;
        const owned = try self.allocator.dupe(u8, provider_id);
        errdefer self.allocator.free(owned);
        try self.pending_credential_deletions.append(self.allocator, owned);
    }

    /// Builds the current-format empty registry used by the explicit Models
    /// recovery command. Every credential slot still represented by the
    /// healthy in-memory registry is carried as a pending deletion so the
    /// runtime can scrub Host-owned secrets after the canonical commit.
    pub fn resetCandidate(self: *const Registry) (std.mem.Allocator.Error || Error)!Registry {
        var result = Registry.init(self.allocator);
        errdefer result.deinit();
        for (self.pending_credential_deletions.items) |provider_id| {
            try result.reserveCredentialDeletion(provider_id);
        }
        for (self.providers.items) |provider| {
            var duplicate = false;
            for (result.pending_credential_deletions.items) |pending|
                if (std.mem.eql(u8, pending, provider.id)) {
                    duplicate = true;
                    break;
                };
            if (!duplicate) try result.reserveCredentialDeletion(provider.id);
        }
        return result;
    }

    pub fn credentialDeletions(self: *const Registry) []const []const u8 {
        return self.pending_credential_deletions.items;
    }

    pub fn completeCredentialDeletion(
        self: *Registry,
        provider_id: []const u8,
    ) Error!void {
        var index: ?usize = null;
        for (self.pending_credential_deletions.items, 0..) |candidate, candidate_index| {
            if (std.mem.eql(u8, candidate, provider_id)) {
                index = candidate_index;
                break;
            }
        }
        const removed = self.pending_credential_deletions.orderedRemove(
            index orelse return error.InvalidProvider,
        );
        self.allocator.free(removed);
    }

    pub fn update(
        self: *Registry,
        input: contract.CustomProviderUpdateCommand,
        next_provider_revision: u64,
        next_source_generation: ?u64,
    ) (std.mem.Allocator.Error || Error)!void {
        contract.validateCustomProviderSpec(input.spec) catch
            return error.InvalidProvider;
        const provider = try self.selected(input.selection);
        const binding_changed = provider.protocol != input.spec.protocol or
            !std.mem.eql(u8, provider.normalized_base_url, input.spec.normalized_base_url);
        if (next_provider_revision == 0 or
            next_provider_revision == provider.provider_revision or
            (binding_changed and (next_source_generation == null or
                next_source_generation.? == 0 or
                next_source_generation.? == provider.source_generation)) or
            (!binding_changed and next_source_generation != null))
            return error.InvalidProvider;

        const display_name = try self.allocator.dupe(u8, input.spec.display_name);
        errdefer self.allocator.free(display_name);
        const base_url = try self.allocator.dupe(u8, input.spec.normalized_base_url);
        errdefer self.allocator.free(base_url);
        self.allocator.free(provider.display_name);
        self.allocator.free(provider.normalized_base_url);
        provider.display_name = display_name;
        provider.normalized_base_url = base_url;
        provider.protocol = input.spec.protocol;
        provider.provider_revision = next_provider_revision;
        if (binding_changed) {
            provider.state = .configuring;
            for (provider.models.items) |*model| {
                model.test_status = .untested;
                model.ready_source_generation = 0;
            }
            provider.source_generation = next_source_generation.?;
        } else {
            _ = settleTesting(provider);
        }
    }

    /// Restores a Host-written credential only after the durable registry has
    /// first revoked the prior authority with markCredentialMissing.
    pub fn restoreCredential(
        self: *Registry,
        selection: contract.CustomProviderSelectionCommand,
        next_provider_revision: u64,
        next_source_generation: u64,
    ) Error!void {
        const provider = try self.selected(selection);
        if (provider.credential_status != .missing or
            next_provider_revision == 0 or
            next_provider_revision == provider.provider_revision or
            next_source_generation == 0 or
            next_source_generation == provider.source_generation)
            return error.InvalidProvider;
        provider.credential_status = .ready;
        provider.state = .configuring;
        provider.provider_revision = next_provider_revision;
        provider.source_generation = next_source_generation;
    }

    pub fn addCustomModel(
        self: *Registry,
        command: contract.CustomModelAddCommand,
        next_provider_revision: u64,
        next_catalog_generation: u64,
    ) (std.mem.Allocator.Error || Error)!void {
        const provider = try self.selectedCatalog(
            command.source_id,
            command.expected_provider_revision,
            command.expected_catalog_generation,
        );
        if (provider.models.items.len >= contract.Limits.custom_provider_model_entries)
            return error.Capacity;
        if (next_provider_revision == 0 or
            next_provider_revision == provider.provider_revision or
            next_catalog_generation == 0 or
            next_catalog_generation == provider.catalog_generation)
            return error.InvalidProvider;
        contract.validateCustomModelInput(command.model) catch
            return error.InvalidProvider;
        if (providerHasModel(provider, command.model.id))
            return error.InvalidProvider;
        var model: OwnedModel = .{
            .id = try self.allocator.dupe(u8, command.model.id),
            .display_name = try self.allocator.dupe(u8, command.model.display_name),
            .metadata = command.model.metadata,
            .metadata_provenance = .user_declared,
        };
        errdefer model.deinit(self.allocator);
        try provider.models.append(self.allocator, model);
        provider.provider_revision = next_provider_revision;
        provider.catalog_generation = next_catalog_generation;
        _ = settleTesting(provider);
    }

    pub fn replaceCustomModel(
        self: *Registry,
        command: contract.CustomModelReplaceCommand,
        next_provider_revision: u64,
        next_catalog_generation: u64,
    ) (std.mem.Allocator.Error || Error)!void {
        const provider = try self.selectedCatalog(
            command.selection.source_id,
            command.expected_provider_revision,
            command.expected_catalog_generation,
        );
        if (next_provider_revision == 0 or
            next_provider_revision == provider.provider_revision or
            next_catalog_generation == 0 or
            next_catalog_generation == provider.catalog_generation)
            return error.InvalidProvider;
        contract.validateCustomModelInput(command.replacement) catch
            return error.InvalidProvider;
        var model_index: ?usize = null;
        for (provider.models.items, 0..) |model, index| {
            if (std.mem.eql(u8, model.id, command.selection.model_id))
                model_index = index;
            if (std.mem.eql(u8, model.id, command.replacement.id) and
                !std.mem.eql(u8, model.id, command.selection.model_id))
                return error.InvalidProvider;
        }
        const index = model_index orelse return error.ModelNotFound;
        const identity_changed = !std.mem.eql(
            u8,
            command.selection.model_id,
            command.replacement.id,
        );

        var replacement: OwnedModel = .{
            .id = try self.allocator.dupe(u8, command.replacement.id),
            .display_name = try self.allocator.dupe(u8, command.replacement.display_name),
            .metadata = command.replacement.metadata,
            .metadata_provenance = .user_declared,
            .test_status = if (identity_changed)
                .untested
            else
                provider.models.items[index].test_status,
            .ready_source_generation = if (identity_changed)
                0
            else
                provider.models.items[index].ready_source_generation,
        };
        errdefer replacement.deinit(self.allocator);

        provider.models.items[index].deinit(self.allocator);
        provider.models.items[index] = replacement;
        provider.provider_revision = next_provider_revision;
        provider.catalog_generation = next_catalog_generation;
        _ = settleTesting(provider);
    }

    pub fn removeCustomModel(
        self: *Registry,
        command: contract.CustomModelRemoveCommand,
        next_provider_revision: u64,
        next_catalog_generation: u64,
    ) (std.mem.Allocator.Error || Error)!void {
        const provider = try self.selectedCatalog(
            command.selection.source_id,
            command.expected_provider_revision,
            command.expected_catalog_generation,
        );
        if (next_provider_revision == 0 or
            next_provider_revision == provider.provider_revision or
            next_catalog_generation == 0 or
            next_catalog_generation == provider.catalog_generation)
            return error.InvalidProvider;
        var model_index: ?usize = null;
        for (provider.models.items, 0..) |model, index| {
            if (std.mem.eql(u8, model.id, command.selection.model_id)) {
                model_index = index;
            }
        }
        const index = model_index orelse return error.ModelNotFound;

        if (provider.models.items.len == 1) {
            try self.remove(.{
                .source_id = provider.id,
                .expected_provider_revision = provider.provider_revision,
            });
            return;
        }

        provider.models.items[index].deinit(self.allocator);
        _ = provider.models.orderedRemove(index);
        provider.provider_revision = next_provider_revision;
        provider.catalog_generation = next_catalog_generation;
        _ = settleTesting(provider);
    }

    /// A provider test has no durable worker. A persisted `testing` value
    /// therefore means the process stopped before publishing its terminal
    /// result. Recovery makes that interruption explicit while preserving a
    /// previously verified generation's readiness.
    pub fn reconcileInterruptedTests(self: *Registry) bool {
        var changed = false;
        for (self.providers.items) |*provider| {
            if (settleTesting(provider)) changed = true;
        }
        return changed;
    }

    pub const MetaskSource = struct { principal_ref: []const u8, source_generation: u64 };
    pub fn metaskSource(self: *const Registry) ?MetaskSource {
        if (self.metask_principal_ref.len == 0) return null;
        return .{ .principal_ref = self.metask_principal_ref, .source_generation = self.metask_source_generation };
    }
    pub fn configureMetaskSource(self: *Registry, principal_ref: []const u8, source_generation: u64) (std.mem.Allocator.Error || Error)!void {
        if (principal_ref.len == 0 or principal_ref.len > contract.Limits.principal_ref_bytes or source_generation == 0) return error.InvalidData;
        const principal = try self.allocator.dupe(u8, principal_ref);
        self.freeSelectionText(&self.metask_principal_ref);
        self.metask_principal_ref = principal;
        self.metask_source_generation = source_generation;
    }

    pub fn defaultSelection(self: *const Registry) ?contract.ModelRef {
        if (self.default_source_id.len == 0) return null;
        return .{
            .source_id = self.default_source_id,
            .model_id = self.default_model_id,
        };
    }

    pub fn sourceGenerationForProvider(self: *const Registry, provider_id: []const u8) ?u64 {
        const index = self.findIndex(provider_id) orelse return null;
        return self.providers.items[index].source_generation;
    }

    /// Called only with a confirmed consumer selection. Catalog membership is
    /// execution authority; remembering an identity does not grant authority.
    pub fn rememberPreference(self: *Registry, target: contract.ModelRef, revision: u64) (std.mem.Allocator.Error || Error)!void {
        if (target.source_id.len == 0 or target.source_id.len > contract.Limits.provider_id_bytes or target.model_id.len == 0 or target.model_id.len > contract.Limits.model_id_bytes or revision == 0 or revision == self.selection_revision) return error.InvalidData;
        const source = try self.allocator.dupe(u8, target.source_id);
        errdefer self.allocator.free(source);
        const model = try self.allocator.dupe(u8, target.model_id);
        self.clearDefaultSelection();
        self.default_source_id = source;
        self.default_model_id = model;
        self.selection_revision = revision;
    }

    pub fn clearDefault(self: *Registry, selection_revision: u64) bool {
        if (self.default_source_id.len == 0 or selection_revision == 0 or
            selection_revision == self.selection_revision)
            return false;
        self.clearDefaultSelection();
        self.selection_revision = selection_revision;
        return true;
    }

    fn clearDefaultSelection(self: *Registry) void {
        self.freeSelectionText(&self.default_source_id);
        self.freeSelectionText(&self.default_model_id);
    }

    /// Reconciles a credential that the platform store no longer contains.
    /// The public registry must stop advertising the generation as runnable,
    /// and a previously installed durable default must not survive restart.
    pub fn markCredentialMissing(
        self: *Registry,
        selection: contract.CustomProviderSelectionCommand,
    ) Error!void {
        const provider = try self.selected(selection);

        provider.credential_status = .missing;
        provider.state = .configuring;
        for (provider.models.items) |*model| {
            model.test_status = .untested;
            model.ready_source_generation = 0;
        }
    }

    pub fn imageCapabilities(self: *const Registry, provider_id: []const u8, output: *[contract.max_model_image_capabilities]contract.ModelImageCapability) []const contract.ModelImageCapability {
        const provider = self.providers.items[self.findIndex(provider_id).?];
        var count: usize = 0;
        for (provider.models.items) |model| {
            if (!modelReady(&provider, model)) continue;
            const supported = model.metadata.capabilities.image_input orelse continue;
            output[count] = .{ .model = model.id, .supported = supported };
            count += 1;
        }
        return output[0..count];
    }

    pub const ModelBinding = struct {
        provider_id: []const u8,
        model_id: []const u8,
        protocol: contract.Protocol,
        normalized_base_url: []const u8,
        provider_revision: u64,
        source_generation: u64,
    };

    pub fn probeBinding(
        self: *const Registry,
        command: contract.CustomModelTestCommand,
    ) Error!ModelBinding {
        const index = self.findIndex(command.model.source_id) orelse
            return error.ProviderNotFound;
        const provider = self.providers.items[index];
        if (provider.provider_revision != command.expected_provider_revision or
            provider.source_generation != command.expected_source_generation or
            provider.catalog_generation != command.expected_catalog_generation)
            return error.GenerationMismatch;
        if (provider.credential_status != .ready or !provider.enabled)
            return error.InvalidProvider;
        var matches: usize = 0;
        for (provider.models.items) |model| {
            if (std.mem.eql(u8, model.id, command.model.model_id)) matches += 1;
        }
        if (matches != 1) return error.ModelNotFound;
        return .{
            .provider_id = provider.id,
            .model_id = command.model.model_id,
            .protocol = provider.protocol,
            .normalized_base_url = provider.normalized_base_url,
            .provider_revision = provider.provider_revision,
            .source_generation = provider.source_generation,
        };
    }

    pub fn markTesting(
        self: *Registry,
        command: contract.CustomModelTestCommand,
    ) (std.mem.Allocator.Error || Error)!void {
        const provider = try self.selectedExact(
            command.model.source_id,
            command.expected_provider_revision,
            command.expected_source_generation,
            command.expected_catalog_generation,
        );
        for (provider.models.items) |*model|
            if (std.mem.eql(u8, model.id, command.model.model_id)) {
                if (provider.credential_status != .ready or !provider.enabled)
                    return error.InvalidProvider;
                if (model.test_status == .testing)
                    return error.InvalidProvider;
                model.test_status = .testing;
                return;
            };
        return error.ModelNotFound;
    }

    pub fn completeTest(
        self: *Registry,
        command: contract.CustomModelTestCommand,
        succeeded: bool,
    ) Error!void {
        const provider = try self.selectedExact(
            command.model.source_id,
            command.expected_provider_revision,
            command.expected_source_generation,
            command.expected_catalog_generation,
        );
        for (provider.models.items) |*model|
            if (std.mem.eql(u8, model.id, command.model.model_id)) {
                if (model.test_status != .testing) return error.InvalidProvider;
                model.test_status = if (succeeded) .connected else .failed;
                if (succeeded)
                    model.ready_source_generation = provider.source_generation;
                refreshProviderState(provider);
                return;
            };
        return error.ModelNotFound;
    }

    fn selected(
        self: *Registry,
        selection: contract.CustomProviderSelectionCommand,
    ) Error!*OwnedProvider {
        const index = self.findIndex(selection.source_id) orelse
            return error.ProviderNotFound;
        const provider = &self.providers.items[index];
        if (provider.provider_revision != selection.expected_provider_revision)
            return error.GenerationMismatch;
        return provider;
    }

    fn selectedExact(
        self: *Registry,
        source_id: []const u8,
        expected_provider_revision: u64,
        expected_source_generation: u64,
        expected_catalog_generation: u64,
    ) Error!*OwnedProvider {
        const index = self.findIndex(source_id) orelse return error.ProviderNotFound;
        const provider = &self.providers.items[index];
        if (provider.provider_revision != expected_provider_revision or
            provider.source_generation != expected_source_generation or
            provider.catalog_generation != expected_catalog_generation)
            return error.GenerationMismatch;
        return provider;
    }

    fn selectedCatalog(
        self: *Registry,
        source_id: []const u8,
        expected_provider_revision: u64,
        expected_catalog_generation: u64,
    ) Error!*OwnedProvider {
        const index = self.findIndex(source_id) orelse return error.ProviderNotFound;
        const provider = &self.providers.items[index];
        if (provider.provider_revision != expected_provider_revision or
            provider.catalog_generation != expected_catalog_generation)
            return error.GenerationMismatch;
        return provider;
    }

    fn findIndex(self: *const Registry, id: []const u8) ?usize {
        for (self.providers.items, 0..) |provider, index|
            if (std.mem.eql(u8, provider.id, id)) return index;
        return null;
    }

    fn rebuildViews(self: *Registry) void {
        self.view_storage.clearRetainingCapacity();
        self.model_view_storage.clearRetainingCapacity();
        var model_count: usize = 0;
        for (self.providers.items) |provider| model_count += provider.models.items.len;
        self.view_storage.ensureTotalCapacity(self.allocator, self.providers.items.len) catch
            @panic("custom provider view capacity exhausted");
        self.model_view_storage.ensureTotalCapacity(self.allocator, model_count) catch
            @panic("custom provider view capacity exhausted");
        for (self.providers.items) |*provider| {
            const model_start = self.model_view_storage.items.len;
            for (provider.models.items) |model|
                self.model_view_storage.append(self.allocator, .{
                    .id = model.id,
                    .display_name = model.display_name,
                    .metadata = model.metadata,
                    .metadata_provenance = model.metadata_provenance,
                    .test_status = model.test_status,
                    .ready = modelReady(provider, model),
                }) catch @panic("custom provider view capacity exhausted");
            const model_end = self.model_view_storage.items.len;
            self.view_storage.append(self.allocator, .{
                .id = provider.id,
                .builtin_provider_id = provider.builtin_provider_id,
                .display_name = provider.display_name,
                .protocol = provider.protocol,
                .normalized_base_url = provider.normalized_base_url,
                .state = provider.state,
                .credential_status = provider.credential_status,
                .enabled = provider.enabled,
                .models = self.model_view_storage.items[model_start..model_end],
                .provider_revision = provider.provider_revision,
                .source_generation = provider.source_generation,
                .catalog_generation = provider.catalog_generation,
            }) catch @panic("custom provider view capacity exhausted");
        }
    }
};

fn cloneProvider(
    allocator: std.mem.Allocator,
    source: OwnedProvider,
) (std.mem.Allocator.Error || Error)!OwnedProvider {
    var result: OwnedProvider = .{
        .id = try allocator.dupe(u8, source.id),
        .builtin_provider_id = source.builtin_provider_id,
        .display_name = try allocator.dupe(u8, source.display_name),
        .normalized_base_url = try allocator.dupe(u8, source.normalized_base_url),
        .protocol = source.protocol,
        .state = source.state,
        .credential_status = source.credential_status,
        .enabled = source.enabled,
        .provider_revision = source.provider_revision,
        .source_generation = source.source_generation,
        .catalog_generation = source.catalog_generation,
    };
    errdefer result.deinit(allocator);
    try result.models.ensureTotalCapacity(allocator, source.models.items.len);
    for (source.models.items) |model| {
        var cloned: OwnedModel = .{
            .id = try allocator.dupe(u8, model.id),
            .display_name = try allocator.dupe(u8, model.display_name),
            .metadata = model.metadata,
            .metadata_provenance = model.metadata_provenance,
            .test_status = model.test_status,
            .ready_source_generation = model.ready_source_generation,
        };
        errdefer cloned.deinit(allocator);
        try result.models.append(allocator, cloned);
    }
    return result;
}

const MetaskSourceWire = struct { principal_ref: []const u8, source_generation: u64 };

const ModelRefWire = struct {
    source_id: []const u8,
    model_id: []const u8,
};

const CanonicalModelMetadata = struct {
    value: contract.ModelMetadata,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !CanonicalModelMetadata {
        const Stored = struct {
            max_input_tokens: ?u64 = null,
            max_output_tokens: ?u64 = null,
            capabilities: contract.ModelCapabilities = .{},
            // Retired persisted field: discard it without granting any authority.
            limits: std.json.Value = .null,
        };
        const stored = try std.json.innerParse(Stored, allocator, source, options);
        return .{ .value = .{
            .max_input_tokens = stored.max_input_tokens,
            .max_output_tokens = stored.max_output_tokens,
            .capabilities = stored.capabilities,
        } };
    }

    pub fn jsonStringify(self: CanonicalModelMetadata, writer: anytype) !void {
        try writer.write(self.value);
    }
};

const CanonicalModelWire = struct {
    id: []const u8,
    display_name: []const u8,
    metadata: CanonicalModelMetadata,
    metadata_provenance: contract.ModelMetadataProvenance,
    test_status: contract.CustomModelTestStatus,
    ready_source_generation: u64,
};

const CanonicalProviderWire = struct {
    id: []const u8,
    builtin_provider_id: ?contract.BuiltinProviderId = null,
    display_name: []const u8,
    normalized_base_url: []const u8,
    protocol: contract.Protocol,
    state: contract.CustomProviderState,
    credential_status: contract.CustomProviderCredentialStatus,
    enabled: bool,
    provider_revision: u64,
    source_generation: u64,
    catalog_generation: u64,
    models: []const CanonicalModelWire,
};

const CanonicalWire = struct {
    schema: u32,
    metask: ?MetaskSourceWire,
    default_selection: ?ModelRefWire,
    selection_revision: u64,
    pending_credential_deletions: []const []const u8,
    custom_providers: []const CanonicalProviderWire,
};

pub fn encodeAlloc(
    allocator: std.mem.Allocator,
    registry: *const Registry,
) (std.mem.Allocator.Error || Error)![]u8 {
    var provider_storage: [contract.Limits.custom_provider_entries]CanonicalProviderWire = undefined;
    var model_storage: [contract.Limits.custom_provider_entries][contract.Limits.custom_provider_model_entries]CanonicalModelWire = undefined;
    for (registry.providers.items, 0..) |provider, provider_index| {
        if (provider.models.items.len > contract.Limits.custom_provider_model_entries)
            return error.InvalidData;
        for (provider.models.items, 0..) |model, model_index|
            model_storage[provider_index][model_index] = .{
                .id = model.id,
                .display_name = model.display_name,
                .metadata = .{ .value = model.metadata },
                .metadata_provenance = model.metadata_provenance,
                .test_status = model.test_status,
                .ready_source_generation = model.ready_source_generation,
            };
        provider_storage[provider_index] = .{
            .id = provider.id,
            .builtin_provider_id = provider.builtin_provider_id,
            .display_name = provider.display_name,
            .normalized_base_url = provider.normalized_base_url,
            .protocol = provider.protocol,
            .state = provider.state,
            .credential_status = provider.credential_status,
            .enabled = provider.enabled,
            .provider_revision = provider.provider_revision,
            .source_generation = provider.source_generation,
            .catalog_generation = provider.catalog_generation,
            .models = model_storage[provider_index][0..provider.models.items.len],
        };
    }
    const metask: ?MetaskSourceWire = if (registry.metaskSource()) |source| .{ .principal_ref = source.principal_ref, .source_generation = source.source_generation } else null;
    const default_selection: ?ModelRefWire = if (registry.defaultSelection()) |selection| .{
        .source_id = selection.source_id,
        .model_id = selection.model_id,
    } else null;
    const wire: CanonicalWire = .{
        .schema = 3,
        .metask = metask,
        .default_selection = default_selection,
        .selection_revision = registry.selection_revision,
        .pending_credential_deletions = registry.pending_credential_deletions.items,
        .custom_providers = provider_storage[0..registry.providers.items.len],
    };
    const bytes = try std.json.Stringify.valueAlloc(allocator, wire, .{});
    if (bytes.len == 0 or bytes.len > max_store_bytes) {
        allocator.free(bytes);
        return error.InvalidData;
    }
    return bytes;
}

pub fn decode(
    allocator: std.mem.Allocator,
    input: []const u8,
) (std.mem.Allocator.Error || Error)!Registry {
    if (input.len == 0 or input.len > max_store_bytes) return error.InvalidData;
    var parsed = std.json.parseFromSlice(
        CanonicalWire,
        allocator,
        input,
        .{ .ignore_unknown_fields = false },
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidData,
    };
    defer parsed.deinit();
    const wire = parsed.value;
    if (wire.schema != 3 or
        wire.custom_providers.len > contract.Limits.custom_provider_entries or
        wire.pending_credential_deletions.len > max_pending_credential_deletions)
        return error.InvalidData;
    var result = Registry.init(allocator);
    errdefer result.deinit();
    result.selection_revision = wire.selection_revision;
    if (wire.metask) |metask| try result.configureMetaskSource(metask.principal_ref, metask.source_generation);
    for (wire.pending_credential_deletions, 0..) |provider_id, index| {
        if (provider_id.len == 0 or
            provider_id.len > contract.Limits.instance_id_bytes)
            return error.InvalidData;
        for (wire.pending_credential_deletions[0..index]) |prior|
            if (std.mem.eql(u8, prior, provider_id)) return error.InvalidData;
        const owned = try allocator.dupe(u8, provider_id);
        errdefer allocator.free(owned);
        try result.pending_credential_deletions.append(allocator, owned);
    }
    for (wire.custom_providers) |provider_wire| {
        if (provider_wire.id.len == 0 or
            provider_wire.id.len > contract.Limits.instance_id_bytes or
            provider_wire.provider_revision == 0 or
            provider_wire.source_generation == 0 or
            provider_wire.catalog_generation == 0 or
            provider_wire.models.len > contract.Limits.custom_provider_model_entries)
            return error.InvalidData;
        contract.validateCustomProviderSpec(.{
            .display_name = provider_wire.display_name,
            .protocol = provider_wire.protocol,
            .normalized_base_url = provider_wire.normalized_base_url,
        }) catch return error.InvalidData;
        if (result.findIndex(provider_wire.id) != null) return error.InvalidData;
        for (result.pending_credential_deletions.items) |provider_id|
            if (std.mem.eql(u8, provider_id, provider_wire.id))
                return error.InvalidData;
        var provider: OwnedProvider = .{
            .id = try allocator.dupe(u8, provider_wire.id),
            .builtin_provider_id = provider_wire.builtin_provider_id,
            .display_name = try allocator.dupe(u8, provider_wire.display_name),
            .normalized_base_url = try allocator.dupe(u8, provider_wire.normalized_base_url),
            .protocol = provider_wire.protocol,
            .state = provider_wire.state,
            .credential_status = provider_wire.credential_status,
            .enabled = provider_wire.enabled,
            .provider_revision = provider_wire.provider_revision,
            .source_generation = provider_wire.source_generation,
            .catalog_generation = provider_wire.catalog_generation,
        };
        errdefer provider.deinit(allocator);
        for (provider_wire.models) |model_wire| {
            if (model_wire.id.len == 0 or
                model_wire.id.len > contract.Limits.model_id_bytes or
                model_wire.display_name.len > contract.Limits.model_display_name_bytes)
                return error.InvalidData;
            for (provider.models.items) |model|
                if (std.mem.eql(u8, model.id, model_wire.id)) return error.InvalidData;
            const ready_source_generation = model_wire.ready_source_generation;
            if (ready_source_generation != 0 and
                ready_source_generation != provider_wire.source_generation)
                return error.InvalidData;
            try provider.models.append(allocator, .{
                .id = try allocator.dupe(u8, model_wire.id),
                .display_name = try allocator.dupe(u8, model_wire.display_name),
                .metadata = model_wire.metadata.value,
                .metadata_provenance = model_wire.metadata_provenance,
                .test_status = model_wire.test_status,
                .ready_source_generation = ready_source_generation,
            });
        }
        try result.providers.append(allocator, provider);
    }
    if (wire.default_selection) |selection| {
        if (selection.source_id.len == 0 or selection.model_id.len == 0 or
            wire.selection_revision == 0)
            return error.InvalidData;
        if (selection.source_id.len > contract.Limits.provider_id_bytes or selection.model_id.len > contract.Limits.model_id_bytes) return error.InvalidData;
        result.default_source_id = try allocator.dupe(u8, selection.source_id);
        result.default_model_id = try allocator.dupe(u8, selection.model_id);
    }
    for (result.views()) |view|
        contract.validateCustomProviderView(view) catch return error.InvalidData;
    return result;
}

/// Recognize only retired envelope versions. Current-format corruption keeps
/// the ordinary recovery path; no retired records are replayed into live state.
pub fn isRetiredCanonical(allocator: std.mem.Allocator, bytes: []const u8) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const schema = parsed.value.object.get("schema") orelse return false;
    return schema == .integer and (schema.integer == 1 or schema.integer == 2);
}

/// Retired metadata contributes cleanup obligations only. No provider, model,
/// preference or source authority is installed in the replacement registry.
pub fn collectRetiredCredentialDeletions(registry: *Registry, bytes: []const u8) !void {
    if (bytes.len == 0 or bytes.len > max_store_bytes) return error.InvalidData;
    const parsed = try std.json.parseFromSlice(std.json.Value, registry.allocator, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidData;
    const schema = parsed.value.object.get("schema") orelse return error.InvalidData;
    if (schema != .integer or (schema.integer != 1 and schema.integer != 2)) return error.InvalidData;
    const pending = parsed.value.object.get("pending_credential_deletions") orelse return error.InvalidData;
    const providers = parsed.value.object.get("custom_providers") orelse return error.InvalidData;
    if (pending != .array or providers != .array) return error.InvalidData;
    for (pending.array.items) |id| try reserveRetiredCredentialDeletion(registry, id);
    for (providers.array.items) |provider| {
        if (provider != .object) return error.InvalidData;
        try reserveRetiredCredentialDeletion(registry, provider.object.get("id") orelse return error.InvalidData);
    }
}

fn reserveRetiredCredentialDeletion(registry: *Registry, value: std.json.Value) !void {
    if (value != .string or value.string.len == 0 or value.string.len > contract.Limits.instance_id_bytes or
        !std.unicode.utf8ValidateSlice(value.string)) return error.InvalidData;
    for (value.string) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidData;
    for (registry.credentialDeletions()) |existing| if (std.mem.eql(u8, existing, value.string)) return;
    try registry.reserveCredentialDeletion(value.string);
}

test "retired cleanup validates and deduplicates only credential slot identities" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try collectRetiredCredentialDeletions(&registry, "{\"schema\":2,\"pending_credential_deletions\":[\"pending\",\"pending\"],\"custom_providers\":[{\"id\":\"pending\"},{\"id\":\"provider\",\"model\":\"must-not-restore\"}]}");
    try std.testing.expectEqual(@as(usize, 2), registry.credentialDeletions().len);
    try std.testing.expectEqual(@as(usize, 0), registry.views().len);
    try std.testing.expect(registry.defaultSelection() == null);
    for ([_][]const u8{
        "{\"schema\":3,\"pending_credential_deletions\":[],\"custom_providers\":[]}",
        "{\"schema\":2,\"pending_credential_deletions\":[],\"custom_providers\":[{\"id\":\"\"}]}",
        "{\"schema\":2,\"pending_credential_deletions\":[\"bad\\nid\"],\"custom_providers\":[]}",
        "{\"schema\":2,\"pending_credential_deletions\":[],\"custom_providers\":[{\"id\":7}]}",
    }) |bytes| {
        var invalid = Registry.init(std.testing.allocator);
        defer invalid.deinit();
        try std.testing.expectError(error.InvalidData, collectRetiredCredentialDeletions(&invalid, bytes));
    }
}

test "canonical decode preserves allocation exhaustion" {
    var storage: [0]u8 = .{};
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    try std.testing.expectError(
        error.OutOfMemory,
        decode(
            fixed.allocator(),
            "{\"schema\":1,\"metask\":null,\"default_selection\":null,\"selection_revision\":0,\"pending_credential_deletions\":[],\"custom_providers\":[]}",
        ),
    );
}

test "retired Models schemas are rejected and current empty schema round trips" {
    for ([_]u32{ 1, 2 }) |version| {
        const legacy = try std.fmt.allocPrint(std.testing.allocator, "{{\"schema\":{d},\"metask\":null,\"default_selection\":null,\"selection_revision\":0,\"pending_credential_deletions\":[],\"custom_providers\":[]}}", .{version});
        defer std.testing.allocator.free(legacy);
        try std.testing.expect(isRetiredCanonical(std.testing.allocator, legacy));
        try std.testing.expectError(error.InvalidData, decode(std.testing.allocator, legacy));
    }
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    const bytes = try encodeAlloc(std.testing.allocator, &registry);
    defer std.testing.allocator.free(bytes);
    var restored = try decode(std.testing.allocator, bytes);
    defer restored.deinit();
    try std.testing.expect(restored.defaultSelection() == null);
}

test "retired provider-local and image fields are rejected by the current schema" {
    for ([_][]const u8{ "metask_image", "metask_model_id", "metask_selection_revision" }) |field| {
        const bytes = try std.fmt.allocPrint(std.testing.allocator, "{{\"schema\":3,\"metask\":null,\"default_selection\":null,\"selection_revision\":0,\"pending_credential_deletions\":[],\"custom_providers\":[],\"{s}\":null}}", .{field});
        defer std.testing.allocator.free(bytes);
        try std.testing.expectError(error.InvalidData, decode(std.testing.allocator, bytes));
    }
}

fn providerHasModel(provider: *const OwnedProvider, model_id: []const u8) bool {
    var matches: usize = 0;
    for (provider.models.items) |model| {
        if (std.mem.eql(u8, model.id, model_id)) matches += 1;
    }
    return matches == 1;
}

fn providerHasReadyModel(provider: *const OwnedProvider, model_id: []const u8) bool {
    for (provider.models.items) |model|
        if (std.mem.eql(u8, model.id, model_id))
            return modelReady(provider, model);
    return false;
}

fn modelReady(provider: *const OwnedProvider, model: OwnedModel) bool {
    return model.ready_source_generation != 0 and
        model.ready_source_generation == provider.source_generation;
}

fn refreshProviderState(provider: *OwnedProvider) void {
    if (!provider.enabled) {
        provider.state = .disabled;
        return;
    }
    if (provider.credential_status != .ready) {
        provider.state = .configuring;
        return;
    }
    for (provider.models.items) |model| {
        if (modelReady(provider, model)) {
            provider.state = .ready;
            return;
        }
    }
    provider.state = .configuring;
}

fn settleTesting(provider: *OwnedProvider) bool {
    // A revision or catalog generation advance invalidates every outstanding
    // completion token for this provider. Publish a terminal probe state in
    // the same transaction while retaining any already-proven source readiness.
    var changed = false;
    for (provider.models.items) |*model| {
        if (model.test_status != .testing) continue;
        model.test_status = .failed;
        changed = true;
    }
    refreshProviderState(provider);
    return changed;
}

pub const FileStore = struct {
    io: std.Io,
    dir: std.Io.Dir,

    pub fn init(io: std.Io, absolute_directory: []const u8) FileStoreError!FileStore {
        if (!std.fs.path.isAbsolute(absolute_directory)) return error.OpenFailed;
        const dir = std.Io.Dir.cwd().createDirPathOpen(io, absolute_directory, .{
            .open_options = .{ .follow_symlinks = false },
            .permissions = directoryPermissions(),
        }) catch return error.OpenFailed;
        return .{ .io = io, .dir = dir };
    }

    pub fn deinit(self: *FileStore) void {
        self.dir.close(self.io);
        self.* = undefined;
    }

    pub fn loadAlloc(
        self: *FileStore,
        allocator: std.mem.Allocator,
    ) (FileStoreError || std.mem.Allocator.Error)!?[]u8 {
        var file = self.dir.openFile(self.io, store_file_name, .{
            .follow_symlinks = false,
            .resolve_beneath = true,
        }) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return error.ReadFailed,
        };
        if (builtin.os.tag == .windows) file.flags.nonblocking = true;
        defer file.close(self.io);
        const length = file.length(self.io) catch return error.ReadFailed;
        if (length == 0 or length > max_store_bytes) return error.ReadFailed;
        const bytes = try allocator.alloc(u8, @intCast(length));
        errdefer allocator.free(bytes);
        const read = file.readPositionalAll(self.io, bytes, 0) catch
            return error.ReadFailed;
        if (read != bytes.len) return error.ReadFailed;
        return bytes;
    }

    /// Preserve the exact retired canonical before the normal atomic empty
    /// replacement. Failure leaves the original canonical available to retry.
    pub fn quarantine(self: *FileStore, bytes: []const u8) FileStoreError!void {
        var random: [16]u8 = undefined;
        std.Io.randomSecure(self.io, &random) catch return error.WriteFailed;
        const hex = std.fmt.bytesToHex(random, .lower);
        var storage: [80]u8 = undefined;
        const name = std.fmt.bufPrint(&storage, ".models.{s}.quarantine", .{hex}) catch return error.WriteFailed;
        const file = self.dir.createFile(self.io, name, .{ .exclusive = true, .permissions = privateFilePermissions(), .resolve_beneath = true }) catch return error.WriteFailed;
        defer file.close(self.io);
        file.writeStreamingAll(self.io, bytes) catch return error.WriteFailed;
        file.sync(self.io) catch return error.WriteFailed;
        if (builtin.os.tag != .windows) {
            const directory: std.Io.File = .{ .handle = self.dir.handle, .flags = .{ .nonblocking = false } };
            directory.sync(self.io) catch return error.WriteFailed;
        }
    }

    pub fn commit(self: *FileStore, bytes: []const u8) FileStoreError!void {
        if (bytes.len == 0 or bytes.len > max_store_bytes) return error.WriteFailed;
        var random: [8]u8 = undefined;
        std.Io.randomSecure(self.io, &random) catch return error.WriteFailed;
        const random_hex = std.fmt.bytesToHex(random, .lower);
        var temp_storage: [64]u8 = undefined;
        var name_writer = std.Io.Writer.fixed(&temp_storage);
        name_writer.print(".models.{s}.tmp", .{random_hex}) catch
            return error.WriteFailed;
        const temp_name = name_writer.buffered();
        const file = self.dir.createFile(self.io, temp_name, .{
            .exclusive = true,
            .permissions = privateFilePermissions(),
            .resolve_beneath = true,
        }) catch return error.WriteFailed;
        var file_open = true;
        var temp_exists = true;
        defer {
            if (file_open) file.close(self.io);
            if (temp_exists) self.dir.deleteFile(self.io, temp_name) catch {};
        }
        file.writeStreamingAll(self.io, bytes) catch return error.WriteFailed;
        file.sync(self.io) catch return error.WriteFailed;
        file.close(self.io);
        file_open = false;
        self.dir.rename(temp_name, self.dir, store_file_name, self.io) catch
            return error.WriteFailed;
        temp_exists = false;
        if (!self.syncCommit()) return error.PersistenceOutcomeUnknown;
    }

    fn syncCommit(self: *FileStore) bool {
        if (builtin.os.tag == .windows) {
            const file = self.dir.openFile(self.io, store_file_name, .{
                .mode = .read_write,
                .follow_symlinks = false,
                .resolve_beneath = true,
            }) catch return false;
            defer file.close(self.io);
            file.sync(self.io) catch return false;
            return true;
        }
        const directory_file: std.Io.File = .{
            .handle = self.dir.handle,
            .flags = .{ .nonblocking = false },
        };
        directory_file.sync(self.io) catch return false;
        return true;
    }
};

fn directoryPermissions() std.Io.File.Permissions {
    return if (builtin.os.tag == .windows)
        .default_dir
    else
        .fromMode(0o700);
}

fn privateFilePermissions() std.Io.File.Permissions {
    return if (builtin.os.tag == .windows)
        .default_file
    else
        .fromMode(0o600);
}

test "registry creates and selects a native custom provider" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try testCreate(&registry, .{
        .provider_id = "slot-1",
        .spec = .{
            .display_name = "OpenAI",
            .protocol = .openai_chat_completions,
            .normalized_base_url = "https://api.openai.com/v1/chat/completions",
        },
        .credential_slot = .{ .id = "slot-1" },
        .model = .{ .id = "gpt-5" },
    });
    const values = registry.views();
    try std.testing.expectEqual(@as(usize, 1), values.len);
    try std.testing.expectEqualStrings("slot-1", values[0].id);
    try contract.validateCustomProviderView(values[0]);
}

test "model configurations with the same endpoint and vendor remain independent across persistence" {
    for ([_]?contract.BuiltinProviderId{ null, .deepseek }) |vendor| {
        var registry = Registry.init(std.testing.allocator);
        defer registry.deinit();
        for ([_][]const u8{ "model-config-one", "model-config-two" }) |id| {
            try testCreate(&registry, .{
                .provider_id = id,
                .spec = .{
                    .builtin_provider_id = vendor,
                    .display_name = "Model configuration",
                    .protocol = .openai_chat_completions,
                    .normalized_base_url = "https://api.deepseek.com/chat/completions",
                },
                .credential_slot = .{ .id = id },
                .model = .{ .id = "deepseek-flash" },
            });
        }
        const encoded = try encodeAlloc(std.testing.allocator, &registry);
        defer std.testing.allocator.free(encoded);
        var restored = try decode(std.testing.allocator, encoded);
        defer restored.deinit();
        try std.testing.expectEqual(@as(usize, 2), restored.views().len);
        try restored.removeCustomModel(.{
            .selection = .{ .source_id = "model-config-one", .model_id = "deepseek-flash" },
            .expected_provider_revision = 1,
            .expected_catalog_generation = 3,
        }, 4, 5);
        try std.testing.expectEqual(@as(usize, 1), restored.views().len);
        try std.testing.expectEqualStrings("model-config-two", restored.views()[0].id);
        try std.testing.expectEqualStrings("deepseek-flash", restored.views()[0].models[0].id);
        try std.testing.expectEqualStrings("model-config-one", restored.credentialDeletions()[0]);
    }
}

test "registry removes the connection and queues credential cleanup when its last model is deleted" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.create(.{
        .provider_id = "slot-empty",
        .spec = .{
            .display_name = "Empty provider",
            .protocol = .openai_responses,
            .normalized_base_url = "https://api.openai.com/v1/responses",
        },
        .credential_slot = .{ .id = "slot-empty" },
    }, 1, 2, 3);
    const created = registry.views()[0];
    try std.testing.expectEqual(@as(usize, 0), created.models.len);
    try contract.validateCustomProviderView(created);

    const encoded = try encodeAlloc(std.testing.allocator, &registry);
    defer std.testing.allocator.free(encoded);
    var restored = try decode(std.testing.allocator, encoded);
    defer restored.deinit();
    try std.testing.expectEqual(@as(usize, 0), restored.views()[0].models.len);

    try restored.addCustomModel(.{
        .source_id = "slot-empty",
        .expected_provider_revision = 1,
        .expected_catalog_generation = 3,
        .model = .{ .id = "gpt-5" },
    }, 4, 5);
    const configured = restored.views()[0];
    try std.testing.expectEqual(@as(usize, 1), configured.models.len);
    try contract.validateCustomProviderView(configured);

    try restored.removeCustomModel(.{
        .selection = .{ .source_id = "slot-empty", .model_id = "gpt-5" },
        .expected_provider_revision = 4,
        .expected_catalog_generation = 5,
    }, 6, 7);
    try std.testing.expectEqual(@as(usize, 0), restored.views().len);
    try std.testing.expectEqual(@as(usize, 1), restored.credentialDeletions().len);
    try std.testing.expectEqualStrings("slot-empty", restored.credentialDeletions()[0]);
}

test "schema 1 rejects removed provider selection and test fields" {
    const retired =
        \\{"schema":1,"metask":null,"default_selection":null,"selection_revision":0,"pending_credential_deletions":[],"custom_providers":[{"id":"slot-1","display_name":"OpenAI","normalized_base_url":"https://api.openai.com/v1/chat/completions","protocol":"openai_chat_completions","state":"configuring","test_status":"untested","credential_status":"ready","enabled":true,"provider_revision":1,"source_generation":2,"catalog_generation":3,"models":[],"selected_model":""}]}
    ;
    try std.testing.expectError(
        error.InvalidData,
        decode(std.testing.allocator, retired),
    );
}

test "registry codec restores every admitted protocol" {
    const cases = [_]struct {
        provider_id: []const u8,
        protocol: contract.Protocol,
        endpoint: []const u8,
        model_id: []const u8,
    }{
        .{
            .provider_id = "responses-provider",
            .protocol = .openai_responses,
            .endpoint = "https://api.openai.com/v1/responses",
            .model_id = "gpt-5",
        },
        .{
            .provider_id = "anthropic-provider",
            .protocol = .anthropic_messages,
            .endpoint = "https://api.anthropic.com/v1/messages",
            .model_id = "claude-sonnet-4-5",
        },
        .{
            .provider_id = "chat-completions-provider",
            .protocol = .openai_chat_completions,
            .endpoint = "https://api.openai.com/v1/chat/completions",
            .model_id = "gpt-4.1",
        },
        .{
            .provider_id = "gemini-provider",
            .protocol = .gemini_native,
            .endpoint = "https://generativelanguage.googleapis.com",
            .model_id = "gemini-2.5-flash",
        },
    };
    for (cases) |case| {
        var registry = Registry.init(std.testing.allocator);
        defer registry.deinit();
        try testCreate(&registry, .{
            .provider_id = case.provider_id,
            .spec = .{
                .display_name = case.provider_id,
                .protocol = case.protocol,
                .normalized_base_url = case.endpoint,
            },
            .credential_slot = .{ .id = case.provider_id },
            .model = .{ .id = case.model_id },
        });
        const encoded = try encodeAlloc(std.testing.allocator, &registry);
        defer std.testing.allocator.free(encoded);
        var restored = try decode(std.testing.allocator, encoded);
        defer restored.deinit();
        try std.testing.expectEqual(@as(usize, 1), restored.views().len);
        try std.testing.expectEqual(case.protocol, restored.views()[0].protocol);
        try std.testing.expectEqualStrings(case.endpoint, restored.views()[0].normalized_base_url);
    }
}

test "registry rejects stale generation and unknown models" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try testCreate(&registry, .{
        .provider_id = "slot-1",
        .spec = .{
            .display_name = "Gemini",
            .protocol = .gemini_native,
            .normalized_base_url = "https://generativelanguage.googleapis.com",
        },
        .credential_slot = .{ .id = "slot-1" },
        .model = .{ .id = "gemini-2.5-flash" },
    });
    const probe: contract.CustomModelTestCommand = .{
        .model = .{ .source_id = "slot-1", .model_id = "gemini-2.5-flash" },
        .expected_provider_revision = 1,
        .expected_source_generation = 2,
        .expected_catalog_generation = 3,
    };
    try registry.markTesting(probe);
    try registry.completeTest(probe, true);
    var stale = probe;
    stale.expected_provider_revision += 1;
    try std.testing.expectError(error.GenerationMismatch, registry.probeBinding(stale));
    stale = probe;
    stale.model.model_id = "missing";
    try std.testing.expectError(error.ModelNotFound, registry.probeBinding(stale));
}

test "registry updates public metadata without exposing credential bytes" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try testCreate(&registry, .{
        .provider_id = "slot-opaque",
        .spec = .{
            .display_name = "OpenAI",
            .protocol = .openai_chat_completions,
            .normalized_base_url = "https://api.openai.com/v1/chat/completions",
        },
        .credential_slot = .{ .id = "slot-opaque" },
        .model = .{ .id = "gpt-5" },
    });
    try registry.update(.{
        .selection = .{
            .source_id = "slot-opaque",
            .expected_provider_revision = 1,
        },
        .spec = .{
            .display_name = "OpenAI Team",
            .protocol = .openai_chat_completions,
            .normalized_base_url = "https://api.openai.com/v1/chat/completions",
        },
    }, 2, null);
    const view = registry.views()[0];
    try std.testing.expectEqualStrings("OpenAI Team", view.display_name);
    try std.testing.expectEqual(@as(u64, 2), view.provider_revision);
    try std.testing.expect(view.credential_status == .ready);
}

test "provider deletion preserves a remembered identity across canonical round trip" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try testCreate(&registry, .{ .provider_id = "slot", .spec = .{ .display_name = "OpenAI", .protocol = .openai_responses, .normalized_base_url = "https://api.openai.com/v1/responses" }, .credential_slot = .{ .id = "slot" }, .model = .{ .id = "gpt-5" } });
    try registry.rememberPreference(.{ .source_id = "slot", .model_id = "gpt-5" }, 7);
    try registry.remove(.{ .source_id = "slot", .expected_provider_revision = 1 });
    try std.testing.expectEqualStrings("gpt-5", registry.defaultSelection().?.model_id);
    try std.testing.expectEqual(@as(u64, 7), registry.selection_revision);
    const bytes = try encodeAlloc(std.testing.allocator, &registry);
    defer std.testing.allocator.free(bytes);
    var restored = try decode(std.testing.allocator, bytes);
    defer restored.deinit();
    try std.testing.expectEqual(@as(usize, 0), restored.views().len);
    try std.testing.expectEqualStrings("slot", restored.defaultSelection().?.source_id);
}

test "display-only provider updates settle stale probes without revoking readiness" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try testCreate(&registry, .{
        .provider_id = "slot-retest",
        .spec = .{
            .display_name = "OpenAI",
            .protocol = .openai_responses,
            .normalized_base_url = "https://api.openai.com/v1/responses",
        },
        .credential_slot = .{ .id = "slot-retest" },
        .model = .{ .id = "gpt-5" },
    });
    const probe: contract.CustomModelTestCommand = .{
        .model = .{ .source_id = "slot-retest", .model_id = "gpt-5" },
        .expected_provider_revision = 1,
        .expected_source_generation = 2,
        .expected_catalog_generation = 3,
    };
    try registry.markTesting(probe);
    try registry.completeTest(probe, true);
    try registry.rememberPreference(.{ .source_id = "slot-retest", .model_id = "gpt-5" }, 7);
    try registry.markTesting(probe);

    try registry.update(.{
        .selection = .{
            .source_id = "slot-retest",
            .expected_provider_revision = 1,
        },
        .spec = .{
            .display_name = "OpenAI renamed",
            .protocol = .openai_responses,
            .normalized_base_url = "https://api.openai.com/v1/responses",
        },
    }, 4, null);

    const settled = registry.views()[0];
    try std.testing.expectEqual(contract.CustomProviderState.ready, settled.state);
    try std.testing.expectEqual(contract.CustomModelTestStatus.failed, settled.models[0].test_status);
    try std.testing.expect(settled.models[0].ready);
    try std.testing.expect(testReadyBinding(&registry) != null);
    try std.testing.expectError(error.GenerationMismatch, registry.completeTest(probe, true));
    try registry.markTesting(.{
        .model = probe.model,
        .expected_provider_revision = 4,
        .expected_source_generation = 2,
        .expected_catalog_generation = 3,
    });

    try registry.update(.{
        .selection = .{
            .source_id = "slot-retest",
            .expected_provider_revision = 4,
        },
        .spec = .{
            .display_name = "OpenAI Chat",
            .protocol = .openai_chat_completions,
            .normalized_base_url = "https://api.openai.com/v1/chat/completions",
        },
    }, 5, 6);
    const rebound = registry.views()[0];
    try std.testing.expectEqual(contract.CustomProviderState.configuring, rebound.state);
    try std.testing.expectEqual(contract.CustomModelTestStatus.untested, rebound.models[0].test_status);
    try std.testing.expect(!rebound.models[0].ready);
    try std.testing.expectEqual(@as(u64, 6), rebound.source_generation);
    try std.testing.expect(registry.defaultSelection() != null);
    try std.testing.expectEqual(@as(u64, 7), registry.selection_revision);
}

test "Metask source authority never changes remembered consumer identity" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.configureMetaskSource("principal-1", 3);
    try std.testing.expect(registry.defaultSelection() == null);
    try registry.rememberPreference(.{ .source_id = "metask", .model_id = "model-2" }, 7);
    try registry.configureMetaskSource("principal-2", 9);
    try std.testing.expectEqualStrings("model-2", registry.defaultSelection().?.model_id);
    try std.testing.expectEqual(@as(u64, 7), registry.selection_revision);
    const bytes = try encodeAlloc(std.testing.allocator, &registry);
    defer std.testing.allocator.free(bytes);
    var restored = try decode(std.testing.allocator, bytes);
    defer restored.deinit();
    try std.testing.expectEqualStrings("principal-2", restored.metaskSource().?.principal_ref);
    try std.testing.expectEqualStrings("model-2", restored.defaultSelection().?.model_id);
}

test "registry fails closed when a durable credential disappears" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try testCreate(&registry, .{
        .provider_id = "slot-missing",
        .spec = .{
            .display_name = "OpenAI",
            .protocol = .openai_chat_completions,
            .normalized_base_url = "https://api.openai.com/v1/chat/completions",
        },
        .credential_slot = .{ .id = "slot-missing" },
        .model = .{ .id = "gpt-5" },
    });
    const selection: contract.CustomProviderSelectionCommand = .{
        .source_id = "slot-missing",
        .expected_provider_revision = 1,
    };
    const probe: contract.CustomModelTestCommand = .{
        .model = .{ .source_id = "slot-missing", .model_id = "gpt-5" },
        .expected_provider_revision = 1,
        .expected_source_generation = 2,
        .expected_catalog_generation = 3,
    };
    try registry.markTesting(probe);
    try registry.completeTest(probe, true);
    try registry.rememberPreference(.{ .source_id = selection.source_id, .model_id = "gpt-5" }, 7);

    try registry.markCredentialMissing(selection);

    const view = registry.views()[0];
    try std.testing.expectEqual(contract.CustomProviderCredentialStatus.missing, view.credential_status);
    try std.testing.expectEqual(contract.CustomProviderState.configuring, view.state);
    try std.testing.expectEqual(contract.CustomModelTestStatus.untested, view.models[0].test_status);
    try std.testing.expect(registry.defaultSelection() != null);
    try std.testing.expect(testReadyBinding(&registry) == null);
    try std.testing.expectEqual(@as(u64, 7), registry.selection_revision);

    const encoded = try encodeAlloc(std.testing.allocator, &registry);
    defer std.testing.allocator.free(encoded);
    var restored = try decode(std.testing.allocator, encoded);
    defer restored.deinit();
    try std.testing.expect(restored.defaultSelection() != null);
    try std.testing.expectEqual(@as(u64, 7), restored.selection_revision);
    const restored_view = restored.views()[0];
    try std.testing.expectEqual(
        contract.CustomProviderCredentialStatus.missing,
        restored_view.credential_status,
    );
    try std.testing.expectEqual(contract.CustomProviderState.configuring, restored_view.state);
}

test "registry codec restores opaque slots and the durable default binding" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try testCreate(&registry, .{
        .provider_id = "custom-provider-0123456789abcdef0123456789abcdef",
        .spec = .{
            .display_name = "Gemini",
            .protocol = .gemini_native,
            .normalized_base_url = "https://generativelanguage.googleapis.com",
        },
        .credential_slot = .{ .id = "custom-provider-0123456789abcdef0123456789abcdef" },
        .model = .{
            .id = "gemini-2.5-flash",
            .display_name = "Gemini 2.5 Flash",
        },
    });
    const probe: contract.CustomModelTestCommand = .{
        .model = .{
            .source_id = "custom-provider-0123456789abcdef0123456789abcdef",
            .model_id = "gemini-2.5-flash",
        },
        .expected_provider_revision = 1,
        .expected_source_generation = 2,
        .expected_catalog_generation = 3,
    };
    try registry.markTesting(probe);
    try registry.completeTest(probe, true);
    try registry.rememberPreference(.{ .source_id = "custom-provider-0123456789abcdef0123456789abcdef", .model_id = "gemini-2.5-flash" }, 9);

    const encoded = try encodeAlloc(std.testing.allocator, &registry);
    defer std.testing.allocator.free(encoded);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "api-key") == null);
    var restored = try decode(std.testing.allocator, encoded);
    defer restored.deinit();
    const binding = testReadyBinding(&restored) orelse
        return error.TestExpectedEqual;
    try std.testing.expectEqualStrings(
        "custom-provider-0123456789abcdef0123456789abcdef",
        binding.provider_id,
    );
    try std.testing.expectEqualStrings("gemini-2.5-flash", binding.model_id);
    try std.testing.expectEqual(@as(u64, 2), binding.source_generation);
    try restored.markTesting(.{
        .model = .{ .source_id = binding.provider_id, .model_id = binding.model_id },
        .expected_provider_revision = binding.provider_revision,
        .expected_source_generation = binding.source_generation,
        .expected_catalog_generation = restored.views()[0].catalog_generation,
    });
    try std.testing.expectEqual(
        contract.CustomModelTestStatus.testing,
        restored.views()[0].models[0].test_status,
    );
    try std.testing.expect(testReadyBinding(&restored) != null);
    try std.testing.expect(restored.reconcileInterruptedTests());
    const failed_retest = restored.views()[0];
    try std.testing.expectEqual(contract.CustomProviderState.ready, failed_retest.state);
    try std.testing.expectEqual(contract.CustomModelTestStatus.failed, failed_retest.models[0].test_status);
    try std.testing.expect(testReadyBinding(&restored) != null);
}

test "custom models use source-qualified atomic CRUD and exact probe tokens" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try testCreate(&registry, .{
        .provider_id = "slot-multi",
        .spec = .{
            .display_name = "Team models",
            .protocol = .openai_responses,
            .normalized_base_url = "https://api.openai.com/v1/responses",
        },
        .credential_slot = .{ .id = "slot-multi" },
        .model = .{ .id = "model-a" },
    });
    const model_a_probe: contract.CustomModelTestCommand = .{
        .model = .{ .source_id = "slot-multi", .model_id = "model-a" },
        .expected_provider_revision = 1,
        .expected_source_generation = 2,
        .expected_catalog_generation = 3,
    };
    try registry.markTesting(model_a_probe);
    try registry.completeTest(model_a_probe, true);
    try registry.rememberPreference(.{ .source_id = "slot-multi", .model_id = "model-a" }, 10);
    try registry.markTesting(model_a_probe);

    try registry.addCustomModel(.{
        .source_id = "slot-multi",
        .expected_provider_revision = 1,
        .expected_catalog_generation = 3,
        .model = .{
            .id = "model-b",
            .display_name = "Model B",
            .metadata = .{ .max_input_tokens = 128_000 },
        },
    }, 4, 5);
    var view = registry.views()[0];
    try std.testing.expectEqual(@as(usize, 2), view.models.len);
    try std.testing.expectEqual(@as(u64, 2), view.source_generation);
    try std.testing.expectEqual(@as(u64, 4), view.provider_revision);
    try std.testing.expectEqual(@as(u64, 5), view.catalog_generation);
    try std.testing.expectEqual(contract.ModelMetadataProvenance.user_declared, view.models[1].metadata_provenance);
    try std.testing.expectEqual(@as(?u64, 128_000), view.models[1].metadata.max_input_tokens);
    try std.testing.expect(!view.models[1].ready);
    try std.testing.expectEqual(contract.CustomModelTestStatus.failed, view.models[0].test_status);
    try std.testing.expect(view.models[0].ready);
    try std.testing.expectEqual(contract.CustomProviderState.ready, view.state);
    try std.testing.expectError(error.GenerationMismatch, registry.completeTest(model_a_probe, true));
    const model_a_after_add: contract.CustomModelTestCommand = .{
        .model = model_a_probe.model,
        .expected_provider_revision = 4,
        .expected_source_generation = 2,
        .expected_catalog_generation = 5,
    };
    try registry.markTesting(model_a_after_add);

    try registry.replaceCustomModel(.{
        .selection = .{ .source_id = "slot-multi", .model_id = "model-b" },
        .expected_provider_revision = 4,
        .expected_catalog_generation = 5,
        .replacement = .{
            .id = "model-b",
            .display_name = "Model B updated",
            .metadata = .{ .max_output_tokens = 32_000 },
        },
    }, 6, 7);
    view = registry.views()[0];
    try std.testing.expectEqual(contract.CustomModelTestStatus.failed, view.models[0].test_status);
    try std.testing.expect(view.models[0].ready);
    try std.testing.expectEqual(contract.CustomProviderState.ready, view.state);
    try std.testing.expectError(
        error.GenerationMismatch,
        registry.completeTest(model_a_after_add, true),
    );
    const model_a_after_replace: contract.CustomModelTestCommand = .{
        .model = model_a_probe.model,
        .expected_provider_revision = 6,
        .expected_source_generation = 2,
        .expected_catalog_generation = 7,
    };
    try registry.markTesting(model_a_after_replace);
    try registry.addCustomModel(.{
        .source_id = "slot-multi",
        .expected_provider_revision = 6,
        .expected_catalog_generation = 7,
        .model = .{ .id = "model-c" },
    }, 8, 9);
    view = registry.views()[0];
    try std.testing.expectEqual(contract.CustomModelTestStatus.failed, view.models[0].test_status);
    try std.testing.expect(view.models[0].ready);
    try std.testing.expectEqual(contract.CustomProviderState.ready, view.state);
    try std.testing.expectError(
        error.GenerationMismatch,
        registry.completeTest(model_a_after_replace, true),
    );

    const model_b_probe: contract.CustomModelTestCommand = .{
        .model = .{ .source_id = "slot-multi", .model_id = "model-b" },
        .expected_provider_revision = 8,
        .expected_source_generation = 2,
        .expected_catalog_generation = 9,
    };
    const model_c_probe: contract.CustomModelTestCommand = .{
        .model = .{ .source_id = "slot-multi", .model_id = "model-c" },
        .expected_provider_revision = 8,
        .expected_source_generation = 2,
        .expected_catalog_generation = 9,
    };
    try registry.markTesting(model_b_probe);
    try registry.markTesting(model_c_probe);

    try registry.removeCustomModel(.{
        .selection = .{ .source_id = "slot-multi", .model_id = "model-a" },
        .expected_provider_revision = 8,
        .expected_catalog_generation = 9,
    }, 11, 12);
    try std.testing.expect(registry.defaultSelection() != null);
    view = registry.views()[0];
    try std.testing.expectEqual(@as(usize, 2), view.models.len);
    try std.testing.expectEqual(@as(u64, 2), view.source_generation);
    try std.testing.expectEqual(contract.CustomModelTestStatus.failed, view.models[0].test_status);
    try std.testing.expectEqual(contract.CustomModelTestStatus.failed, view.models[1].test_status);
    try std.testing.expectError(error.GenerationMismatch, registry.completeTest(model_b_probe, true));
    try std.testing.expectError(error.GenerationMismatch, registry.completeTest(model_c_probe, true));
    try registry.markTesting(.{
        .model = model_b_probe.model,
        .expected_provider_revision = 11,
        .expected_source_generation = 2,
        .expected_catalog_generation = 12,
    });
}

test "custom provider file store atomically restores registry bytes" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const absolute = try temp.dir.realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(absolute);
    var file_store = try FileStore.init(std.testing.io, absolute);
    defer file_store.deinit();
    const canonical = "{\"schema\":1,\"metask\":null,\"default_selection\":null,\"selection_revision\":0,\"pending_credential_deletions\":[],\"custom_providers\":[]}";
    try file_store.commit(canonical);
    const restored = (try file_store.loadAlloc(std.testing.allocator)) orelse
        return error.TestExpectedEqual;
    defer std.testing.allocator.free(restored);
    try std.testing.expectEqualStrings(
        canonical,
        restored,
    );
}

const TestCustomProviderCreate = struct {
    provider_id: []const u8,
    spec: contract.CustomProviderSpec,
    credential_slot: contract.CustomProviderCredentialSlot,
    model: contract.CustomModelInput,
};

/// Builds an already-configured fixture through the public two-command
/// Provider-create/model-add workflow. Seed revisions are deliberately outside
/// the ordinary test baseline so the configured fixture retains the historical
/// 1/2/3 revision values expected by behavior-specific tests below.
fn testCreate(registry: *Registry, input: TestCustomProviderCreate) !void {
    const seed_provider_revision = std.math.maxInt(u64);
    const seed_catalog_generation = std.math.maxInt(u64) - 1;
    try registry.create(.{
        .provider_id = input.provider_id,
        .spec = input.spec,
        .credential_slot = input.credential_slot,
    }, seed_provider_revision, 2, seed_catalog_generation);
    try registry.addCustomModel(.{
        .source_id = input.provider_id,
        .expected_provider_revision = seed_provider_revision,
        .expected_catalog_generation = seed_catalog_generation,
        .model = input.model,
    }, 1, 3);
}

test "complete model declarations and tokens survive registry persistence" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    const metadata: contract.ModelMetadata = .{
        .max_input_tokens = 1000000,
        .max_output_tokens = 131072,
        .capabilities = .{ .text_input = true, .image_input = true, .pdf_input = true, .audio_input = false, .video_input = true, .output = .{ .text = true, .image = false, .audio = false, .video = false, .embedding = false } },
    };
    try testCreate(&registry, .{
        .provider_id = "metadata-provider",
        .spec = .{ .display_name = "Provider", .protocol = .openai_responses, .normalized_base_url = "https://example.com/v1/responses" },
        .credential_slot = .{ .id = "metadata-provider" },
        .model = .{ .id = "m", .metadata = metadata },
    });
    const encoded = try encodeAlloc(std.testing.allocator, &registry);
    defer std.testing.allocator.free(encoded);
    var restored = try decode(std.testing.allocator, encoded);
    defer restored.deinit();
    registry.deinit();
    registry = Registry.init(std.testing.allocator);
    try std.testing.expectEqualDeep(metadata, restored.views()[0].models[0].metadata);
    const again = try encodeAlloc(std.testing.allocator, &restored);
    defer std.testing.allocator.free(again);
    try std.testing.expectEqualStrings(encoded, again);
    const with_retired_limits = try std.mem.replaceOwned(u8, std.testing.allocator, encoded, "\"metadata\":{", "\"metadata\":{\"limits\":{\"max_input_tokens\":999,\"image\":{\"formats\":[\"old\"]}},");
    defer std.testing.allocator.free(with_retired_limits);
    var retired = try decode(std.testing.allocator, with_retired_limits);
    defer retired.deinit();
    try std.testing.expectEqualDeep(metadata, retired.views()[0].models[0].metadata);
    const cleaned = try encodeAlloc(std.testing.allocator, &retired);
    defer std.testing.allocator.free(cleaned);
    try std.testing.expectEqualStrings(encoded, cleaned);
    const with_unknown = try std.mem.replaceOwned(u8, std.testing.allocator, encoded, "\"metadata\":{", "\"metadata\":{\"unexpected\":true,");
    defer std.testing.allocator.free(with_unknown);
    try std.testing.expectError(error.InvalidData, decode(std.testing.allocator, with_unknown));
}

test "image declarations do not admit a Custom model before readiness proof" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try testCreate(&registry, .{
        .provider_id = "vision-provider",
        .spec = .{ .display_name = "Vision", .protocol = .anthropic_messages, .normalized_base_url = "https://example.com/v1/messages" },
        .credential_slot = .{ .id = "vision-provider" },
        .model = .{ .id = "vision-model", .metadata = .{ .capabilities = .{ .image_input = true } } },
    });
    var output: [contract.max_model_image_capabilities]contract.ModelImageCapability = undefined;
    try std.testing.expectEqual(@as(usize, 0), registry.imageCapabilities("vision-provider", &output).len);
    const command: contract.CustomModelTestCommand = .{ .model = .{ .source_id = "vision-provider", .model_id = "vision-model" }, .expected_provider_revision = 1, .expected_source_generation = 2, .expected_catalog_generation = 3 };
    try registry.markTesting(command);
    try registry.completeTest(command, false);
    try std.testing.expectEqual(@as(usize, 0), registry.imageCapabilities("vision-provider", &output).len);
    try registry.markTesting(command);
    try registry.completeTest(command, true);
    const declarations = registry.imageCapabilities("vision-provider", &output);
    try std.testing.expectEqual(@as(usize, 1), declarations.len);
    try std.testing.expectEqualStrings("vision-model", declarations[0].model);
    try std.testing.expect(declarations[0].supported);
}

fn testReadyBinding(registry: *Registry) ?Registry.ModelBinding {
    const target = registry.defaultSelection() orelse return null;
    for (registry.views()) |provider| if (std.mem.eql(u8, provider.id, target.source_id)) {
        for (provider.models) |model| if (std.mem.eql(u8, model.id, target.model_id) and model.ready)
            return registry.probeBinding(.{ .model = target, .expected_provider_revision = provider.provider_revision, .expected_source_generation = provider.source_generation, .expected_catalog_generation = provider.catalog_generation }) catch null;
    };
    return null;
}
