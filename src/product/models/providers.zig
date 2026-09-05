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
    metask_api_key_id: []u8 = &.{},
    metask_model_id: []u8 = &.{},
    metask_protocol: ?contract.Protocol = null,
    metask_source_generation: u64 = 0,
    metask_selection_revision: u64 = 0,
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
        self.freeSelectionText(&self.metask_api_key_id);
        self.freeSelectionText(&self.metask_model_id);
        self.freeSelectionText(&self.default_source_id);
        self.freeSelectionText(&self.default_model_id);
        self.* = undefined;
    }

    pub fn clone(self: *const Registry) (std.mem.Allocator.Error || Error)!Registry {
        var result = Registry.init(self.allocator);
        errdefer result.deinit();
        result.metask_protocol = self.metask_protocol;
        result.metask_source_generation = self.metask_source_generation;
        result.metask_selection_revision = self.metask_selection_revision;
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
        if (self.metask_api_key_id.len != 0)
            result.metask_api_key_id = try self.allocator.dupe(u8, self.metask_api_key_id);
        if (self.metask_model_id.len != 0)
            result.metask_model_id = try self.allocator.dupe(u8, self.metask_model_id);
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
        for (self.providers.items) |provider|
            if (std.mem.eql(u8, provider.normalized_base_url, input.spec.normalized_base_url) and
                provider.protocol == input.spec.protocol)
                return error.InvalidProvider;

        if (input.provider_id.len == 0 or
            input.provider_id.len > contract.Limits.instance_id_bytes or
            !std.mem.eql(u8, input.provider_id, input.credential_slot.id) or
            self.findIndex(input.provider_id) != null)
            return error.InvalidProvider;
        var provider: OwnedProvider = .{
            .id = try self.allocator.dupe(u8, input.provider_id),
            .display_name = try self.allocator.dupe(u8, input.spec.display_name),
            .normalized_base_url = try self.allocator.dupe(u8, input.spec.normalized_base_url),
            .protocol = input.spec.protocol,
            .state = .configuring,
            .provider_revision = provider_revision,
            .source_generation = source_generation,
            .catalog_generation = catalog_generation,
        };
        errdefer provider.deinit(self.allocator);
        try self.providers.append(self.allocator, provider);
    }

    pub fn remove(
        self: *Registry,
        selection: contract.CustomProviderSelectionCommand,
        next_selection_revision: ?u64,
    ) (std.mem.Allocator.Error || Error)!void {
        const index = self.findIndex(selection.source_id) orelse
            return error.ProviderNotFound;
        const provider = &self.providers.items[index];
        if (provider.provider_revision != selection.expected_provider_revision)
            return error.GenerationMismatch;
        if (self.pending_credential_deletions.items.len >=
            max_pending_credential_deletions)
            return error.Capacity;
        const clears_default = std.mem.eql(
            u8,
            self.default_source_id,
            selection.source_id,
        );
        if (clears_default) {
            const revision = next_selection_revision orelse
                return error.InvalidProvider;
            if (revision == 0 or revision == self.selection_revision)
                return error.InvalidProvider;
        } else if (next_selection_revision != null) {
            return error.InvalidProvider;
        }
        const cleanup_id = try self.allocator.dupe(u8, provider.id);
        errdefer self.allocator.free(cleanup_id);
        try self.pending_credential_deletions.append(self.allocator, cleanup_id);
        provider.deinit(self.allocator);
        _ = self.providers.orderedRemove(index);
        if (clears_default) {
            self.clearDefaultSelection();
            self.selection_revision = next_selection_revision.?;
        }
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
        next_selection_revision: ?u64,
    ) (std.mem.Allocator.Error || Error)!void {
        contract.validateCustomProviderSpec(input.spec) catch
            return error.InvalidProvider;
        const provider = try self.selected(input.selection);
        const binding_changed = provider.protocol != input.spec.protocol or
            !std.mem.eql(u8, provider.normalized_base_url, input.spec.normalized_base_url);
        for (self.providers.items) |candidate|
            if (!std.mem.eql(u8, candidate.id, provider.id) and
                candidate.protocol == input.spec.protocol and
                std.mem.eql(
                    u8,
                    candidate.normalized_base_url,
                    input.spec.normalized_base_url,
                ))
                return error.InvalidProvider;
        if (next_provider_revision == 0 or
            next_provider_revision == provider.provider_revision or
            (binding_changed and (next_source_generation == null or
                next_source_generation.? == 0 or
                next_source_generation.? == provider.source_generation)) or
            (!binding_changed and next_source_generation != null))
            return error.InvalidProvider;
        const clears_default = binding_changed and
            std.mem.eql(u8, self.default_source_id, provider.id);
        if (clears_default) {
            const revision = next_selection_revision orelse
                return error.InvalidProvider;
            if (revision == 0 or revision == self.selection_revision)
                return error.InvalidProvider;
        } else if (next_selection_revision != null) {
            return error.InvalidProvider;
        }
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
            if (clears_default) {
                self.clearDefaultSelection();
                self.selection_revision = next_selection_revision.?;
            }
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
        next_selection_revision: ?u64,
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
        const default_changed = identity_changed and
            std.mem.eql(u8, self.default_source_id, provider.id) and
            std.mem.eql(u8, self.default_model_id, command.selection.model_id);
        if (default_changed) {
            const revision = next_selection_revision orelse return error.InvalidProvider;
            if (revision == 0 or revision == self.selection_revision)
                return error.InvalidProvider;
        } else if (next_selection_revision != null) {
            return error.InvalidProvider;
        }
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
        if (default_changed) {
            self.clearDefaultSelection();
            self.selection_revision = next_selection_revision.?;
        }
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
        next_selection_revision: ?u64,
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
        const default_changed = std.mem.eql(u8, self.default_source_id, provider.id) and
            std.mem.eql(u8, self.default_model_id, command.selection.model_id);
        if (default_changed) {
            const revision = next_selection_revision orelse return error.InvalidProvider;
            if (revision == 0 or revision == self.selection_revision)
                return error.InvalidProvider;
        } else if (next_selection_revision != null) {
            return error.InvalidProvider;
        }
        if (default_changed) {
            self.clearDefaultSelection();
            self.selection_revision = next_selection_revision.?;
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

    pub const MetaskIntent = struct {
        principal_ref: []const u8,
        api_key_id: []const u8,
        model_id: []const u8,
        protocol: ?contract.Protocol,
        source_generation: u64,
        selection_revision: u64,
    };

    pub fn metaskIntent(self: *const Registry) ?MetaskIntent {
        if (self.metask_principal_ref.len == 0) return null;
        return .{
            .principal_ref = self.metask_principal_ref,
            .api_key_id = self.metask_api_key_id,
            .model_id = self.metask_model_id,
            .protocol = self.metask_protocol,
            .source_generation = self.metask_source_generation,
            .selection_revision = self.metask_selection_revision,
        };
    }

    pub fn configureMetask(
        self: *Registry,
        principal_ref: []const u8,
        api_key_id: []const u8,
        model_id: []const u8,
        protocol: ?contract.Protocol,
        source_generation: u64,
        selection_revision: u64,
        next_default_selection_revision: ?u64,
    ) (std.mem.Allocator.Error || Error)!void {
        const same_selection = std.mem.eql(u8, principal_ref, self.metask_principal_ref) and
            std.mem.eql(u8, api_key_id, self.metask_api_key_id) and
            std.mem.eql(u8, model_id, self.metask_model_id);
        const updates_default = self.metaskChangeUpdatesDefault(api_key_id, model_id);
        if (principal_ref.len == 0 or principal_ref.len > contract.Limits.principal_ref_bytes or
            api_key_id.len == 0 or api_key_id.len > contract.Limits.api_key_id_bytes or
            model_id.len == 0 or model_id.len > contract.Limits.model_id_bytes or
            ((protocol == null) != (source_generation == 0)) or selection_revision == 0 or
            (!same_selection and selection_revision == self.metask_selection_revision))
            return error.InvalidData;
        if (updates_default) {
            const revision = next_default_selection_revision orelse return error.InvalidData;
            if (revision == 0 or revision == self.selection_revision)
                return error.InvalidData;
        } else if (next_default_selection_revision != null) {
            return error.InvalidData;
        }
        const principal = try self.allocator.dupe(u8, principal_ref);
        errdefer self.allocator.free(principal);
        const api_key = try self.allocator.dupe(u8, api_key_id);
        errdefer self.allocator.free(api_key);
        const model = try self.allocator.dupe(u8, model_id);
        errdefer self.allocator.free(model);
        var default_source: []u8 = &.{};
        if (updates_default)
            default_source = try metaskSourceIdAlloc(self.allocator, api_key_id);
        errdefer if (default_source.len != 0) self.allocator.free(default_source);
        var default_model: []u8 = &.{};
        if (updates_default)
            default_model = try self.allocator.dupe(u8, model_id);
        errdefer if (default_model.len != 0) self.allocator.free(default_model);
        self.freeSelectionText(&self.metask_principal_ref);
        self.freeSelectionText(&self.metask_api_key_id);
        self.freeSelectionText(&self.metask_model_id);
        self.metask_principal_ref = principal;
        self.metask_api_key_id = api_key;
        self.metask_model_id = model;
        self.metask_protocol = protocol;
        self.metask_source_generation = source_generation;
        self.metask_selection_revision = selection_revision;
        if (updates_default) {
            self.clearDefaultSelection();
            self.default_source_id = default_source;
            self.default_model_id = default_model;
            self.selection_revision = next_default_selection_revision.?;
        }
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

    fn validDurableSelection(
        self: *const Registry,
        source_id: []const u8,
        model_id: []const u8,
    ) bool {
        if (self.metaskIntent()) |intent| {
            var source_storage: ["metask:".len + contract.Limits.api_key_id_bytes]u8 = undefined;
            const metask_source = std.fmt.bufPrint(
                &source_storage,
                "metask:{s}",
                .{intent.api_key_id},
            ) catch return false;
            if (std.mem.eql(u8, metask_source, source_id))
                return std.mem.eql(u8, intent.model_id, model_id);
        }
        const index = self.findIndex(source_id) orelse return false;
        return providerHasReadyModel(&self.providers.items[index], model_id);
    }

    fn defaultTracksMetaskIntent(self: *const Registry) bool {
        const intent = self.metaskIntent() orelse return false;
        var source_storage: ["metask:".len + contract.Limits.api_key_id_bytes]u8 = undefined;
        const source_id = std.fmt.bufPrint(
            &source_storage,
            "metask:{s}",
            .{intent.api_key_id},
        ) catch return false;
        return std.mem.eql(u8, self.default_source_id, source_id) and
            std.mem.eql(u8, self.default_model_id, intent.model_id);
    }

    pub fn metaskChangeUpdatesDefault(
        self: *const Registry,
        api_key_id: []const u8,
        model_id: []const u8,
    ) bool {
        return self.defaultTracksMetaskIntent() and
            (!std.mem.eql(u8, api_key_id, self.metask_api_key_id) or
                !std.mem.eql(u8, model_id, self.metask_model_id));
    }

    pub fn selectMetaskDefault(
        self: *Registry,
        selection_revision: u64,
    ) (std.mem.Allocator.Error || Error)!void {
        const intent = self.metaskIntent() orelse return error.InvalidData;
        if (selection_revision == 0 or selection_revision == self.selection_revision)
            return error.InvalidData;
        const source_id = try metaskSourceIdAlloc(self.allocator, intent.api_key_id);
        errdefer self.allocator.free(source_id);
        const model_id = try self.allocator.dupe(u8, intent.model_id);
        self.clearDefaultSelection();
        self.default_source_id = source_id;
        self.default_model_id = model_id;
        self.selection_revision = selection_revision;
    }

    pub fn selectDefault(
        self: *Registry,
        selection: contract.CustomProviderSelectionCommand,
        model_id: []const u8,
        selection_revision: u64,
    ) (std.mem.Allocator.Error || Error)!void {
        if (selection_revision == 0 or selection_revision == self.selection_revision)
            return error.InvalidProvider;
        const provider = try self.selected(selection);
        if (provider.state != .ready or provider.credential_status != .ready or
            !provider.enabled)
            return error.InvalidProvider;
        for (provider.models.items) |model| {
            if (!std.mem.eql(u8, model.id, model_id)) continue;
            if (!modelReady(provider, model)) return error.InvalidProvider;
            const default_source_id = try self.allocator.dupe(u8, provider.id);
            errdefer self.allocator.free(default_source_id);
            const default_model_id = try self.allocator.dupe(u8, model_id);
            self.freeSelectionText(&self.default_source_id);
            self.freeSelectionText(&self.default_model_id);
            self.default_source_id = default_source_id;
            self.default_model_id = default_model_id;
            self.selection_revision = selection_revision;
            return;
        }
        return error.ModelNotFound;
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
        next_selection_revision: ?u64,
    ) Error!void {
        const provider = try self.selected(selection);
        const clears_default = std.mem.eql(u8, self.default_source_id, provider.id);
        if (clears_default) {
            const revision = next_selection_revision orelse return error.InvalidProvider;
            if (revision == 0 or revision == self.selection_revision)
                return error.InvalidProvider;
        } else if (next_selection_revision != null) {
            return error.InvalidProvider;
        }

        provider.credential_status = .missing;
        provider.state = .configuring;
        for (provider.models.items) |*model| {
            model.test_status = .untested;
            model.ready_source_generation = 0;
        }
        if (clears_default) {
            self.clearDefaultSelection();
            self.selection_revision = next_selection_revision.?;
        }
    }

    pub const DefaultBinding = struct {
        provider_id: []const u8,
        model_id: []const u8,
        protocol: contract.Protocol,
        normalized_base_url: []const u8,
        provider_revision: u64,
        source_generation: u64,
    };

    pub fn desiredDefaultBinding(self: *const Registry) ?DefaultBinding {
        if (self.default_source_id.len == 0 or self.default_model_id.len == 0 or
            self.selection_revision == 0)
            return null;
        const index = self.findIndex(self.default_source_id) orelse return null;
        const provider = self.providers.items[index];
        var model_matches: usize = 0;
        var model_ready = false;
        for (provider.models.items) |model| {
            if (std.mem.eql(u8, model.id, self.default_model_id)) {
                model_matches += 1;
                model_ready = modelReady(&provider, model);
            }
        }
        if (model_matches != 1 or !model_ready) return null;
        return .{
            .provider_id = provider.id,
            .model_id = self.default_model_id,
            .protocol = provider.protocol,
            .normalized_base_url = provider.normalized_base_url,
            .provider_revision = provider.provider_revision,
            .source_generation = provider.source_generation,
        };
    }

    pub fn defaultBinding(self: *const Registry) ?DefaultBinding {
        const desired = self.desiredDefaultBinding() orelse return null;
        const index = self.findIndex(desired.provider_id) orelse return null;
        const provider = self.providers.items[index];
        if (provider.state != .ready or
            provider.credential_status != .ready or !provider.enabled)
            return null;
        return desired;
    }

    pub fn probeBinding(
        self: *const Registry,
        command: contract.CustomModelTestCommand,
    ) Error!DefaultBinding {
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

pub fn metaskSourceIdAlloc(
    allocator: std.mem.Allocator,
    api_key_id: []const u8,
) std.mem.Allocator.Error![]u8 {
    return std.fmt.allocPrint(allocator, "metask:{s}", .{api_key_id});
}

fn cloneProvider(
    allocator: std.mem.Allocator,
    source: OwnedProvider,
) (std.mem.Allocator.Error || Error)!OwnedProvider {
    var result: OwnedProvider = .{
        .id = try allocator.dupe(u8, source.id),
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

const MetaskIntentWire = struct {
    principal_ref: []const u8,
    api_key_id: []const u8,
    model_id: []const u8,
    protocol: ?contract.Protocol = null,
    source_generation: u64 = 0,
    selection_revision: u64,
};

const ModelRefWire = struct {
    source_id: []const u8,
    model_id: []const u8,
};

const CanonicalModelWire = struct {
    id: []const u8,
    display_name: []const u8,
    metadata: contract.ModelMetadata,
    metadata_provenance: contract.ModelMetadataProvenance,
    test_status: contract.CustomModelTestStatus,
    ready_source_generation: u64,
};

const CanonicalProviderWire = struct {
    id: []const u8,
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
    metask: ?MetaskIntentWire,
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
                .metadata = model.metadata,
                .metadata_provenance = model.metadata_provenance,
                .test_status = model.test_status,
                .ready_source_generation = model.ready_source_generation,
            };
        provider_storage[provider_index] = .{
            .id = provider.id,
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
    const metask: ?MetaskIntentWire = if (registry.metaskIntent()) |intent| .{
        .principal_ref = intent.principal_ref,
        .api_key_id = intent.api_key_id,
        .model_id = intent.model_id,
        .protocol = intent.protocol,
        .source_generation = intent.source_generation,
        .selection_revision = intent.selection_revision,
    } else null;
    const default_selection: ?ModelRefWire = if (registry.defaultSelection()) |selection| .{
        .source_id = selection.source_id,
        .model_id = selection.model_id,
    } else null;
    const wire: CanonicalWire = .{
        .schema = 1,
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
    if (wire.schema != 1 or
        wire.custom_providers.len > contract.Limits.custom_provider_entries or
        wire.pending_credential_deletions.len > max_pending_credential_deletions)
        return error.InvalidData;
    var result = Registry.init(allocator);
    errdefer result.deinit();
    result.selection_revision = wire.selection_revision;
    if (wire.metask) |metask| {
        if ((metask.protocol == null) != (metask.source_generation == 0))
            return error.InvalidData;
        try result.configureMetask(
            metask.principal_ref,
            metask.api_key_id,
            metask.model_id,
            metask.protocol,
            metask.source_generation,
            metask.selection_revision,
            null,
        );
    }
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
                .metadata = model_wire.metadata,
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
        if (!result.validDurableSelection(selection.source_id, selection.model_id))
            return error.InvalidData;
        result.default_source_id = try allocator.dupe(u8, selection.source_id);
        result.default_model_id = try allocator.dupe(u8, selection.model_id);
    }
    for (result.views()) |view|
        contract.validateCustomProviderView(view) catch return error.InvalidData;
    return result;
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

test "registry persists a provider before its first model is configured" {
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
    }, 6, 7, null);
    const emptied = restored.views()[0];
    try std.testing.expectEqual(@as(usize, 0), emptied.models.len);
    try contract.validateCustomProviderView(emptied);
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
    try std.testing.expectError(error.GenerationMismatch, registry.selectDefault(.{
        .source_id = "slot-1",
        .expected_provider_revision = 2,
    }, "gemini-2.5-flash", 1));
    try std.testing.expectError(error.ModelNotFound, registry.selectDefault(.{
        .source_id = "slot-1",
        .expected_provider_revision = 1,
    }, "missing", 1));
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
    }, 2, null, null);
    const view = registry.views()[0];
    try std.testing.expectEqualStrings("OpenAI Team", view.display_name);
    try std.testing.expectEqual(@as(u64, 2), view.provider_revision);
    try std.testing.expect(view.credential_status == .ready);
}

test "registry validates default revisions before update and remove commit" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try testCreate(&registry, .{
        .provider_id = "slot-transaction",
        .spec = .{
            .display_name = "OpenAI",
            .protocol = .openai_chat_completions,
            .normalized_base_url = "https://api.openai.com/v1/chat/completions",
        },
        .credential_slot = .{ .id = "slot-transaction" },
        .model = .{ .id = "gpt-5" },
    });
    const selection: contract.CustomProviderSelectionCommand = .{
        .source_id = "slot-transaction",
        .expected_provider_revision = 1,
    };
    const probe: contract.CustomModelTestCommand = .{
        .model = .{ .source_id = "slot-transaction", .model_id = "gpt-5" },
        .expected_provider_revision = 1,
        .expected_source_generation = 2,
        .expected_catalog_generation = 3,
    };
    try registry.markTesting(probe);
    try registry.completeTest(probe, true);
    try registry.selectDefault(selection, "gpt-5", 7);
    const before = try encodeAlloc(std.testing.allocator, &registry);
    defer std.testing.allocator.free(before);

    try std.testing.expectError(error.InvalidProvider, registry.update(.{
        .selection = selection,
        .spec = .{
            .display_name = "OpenAI renamed",
            .protocol = .openai_chat_completions,
            .normalized_base_url = "https://api.openai.com/v1/chat/completions",
        },
    }, 4, null, 8));
    const after_display = try encodeAlloc(std.testing.allocator, &registry);
    defer std.testing.allocator.free(after_display);
    try std.testing.expectEqualStrings(before, after_display);

    try std.testing.expectError(error.InvalidProvider, registry.update(.{
        .selection = selection,
        .spec = .{
            .display_name = "OpenAI Responses",
            .protocol = .openai_responses,
            .normalized_base_url = "https://api.openai.com/v1/responses",
        },
    }, 4, 5, null));
    const after_binding = try encodeAlloc(std.testing.allocator, &registry);
    defer std.testing.allocator.free(after_binding);
    try std.testing.expectEqualStrings(before, after_binding);

    try std.testing.expectError(error.InvalidProvider, registry.remove(selection, null));
    const after_remove = try encodeAlloc(std.testing.allocator, &registry);
    defer std.testing.allocator.free(after_remove);
    try std.testing.expectEqualStrings(before, after_remove);
    try std.testing.expectEqual(@as(usize, 1), registry.views().len);
    try std.testing.expectEqual(@as(usize, 0), registry.credentialDeletions().len);
    try std.testing.expect(registry.defaultSelection() != null);
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
    try registry.selectDefault(.{
        .source_id = "slot-retest",
        .expected_provider_revision = 1,
    }, "gpt-5", 7);
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
    }, 4, null, null);

    const settled = registry.views()[0];
    try std.testing.expectEqual(contract.CustomProviderState.ready, settled.state);
    try std.testing.expectEqual(contract.CustomModelTestStatus.failed, settled.models[0].test_status);
    try std.testing.expect(settled.models[0].ready);
    try std.testing.expect(registry.defaultBinding() != null);
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
    }, 5, 6, 8);
    const rebound = registry.views()[0];
    try std.testing.expectEqual(contract.CustomProviderState.configuring, rebound.state);
    try std.testing.expectEqual(contract.CustomModelTestStatus.untested, rebound.models[0].test_status);
    try std.testing.expect(!rebound.models[0].ready);
    try std.testing.expectEqual(@as(u64, 6), rebound.source_generation);
    try std.testing.expect(registry.defaultSelection() == null);
    try std.testing.expectEqual(@as(u64, 8), registry.selection_revision);
}

test "registry keeps a tracked Metask default coherent with intent changes" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.configureMetask(
        "principal-1",
        "api-1",
        "model-1",
        .anthropic_messages,
        3,
        5,
        null,
    );
    try registry.selectMetaskDefault(7);

    try std.testing.expectError(
        error.InvalidData,
        registry.configureMetask(
            "principal-1",
            "api-1",
            "model-2",
            .anthropic_messages,
            3,
            6,
            null,
        ),
    );
    try std.testing.expectEqualStrings("model-1", registry.metaskIntent().?.model_id);
    try std.testing.expectEqualStrings("model-1", registry.defaultSelection().?.model_id);

    try registry.configureMetask(
        "principal-1",
        "api-1",
        "model-2",
        .anthropic_messages,
        3,
        6,
        8,
    );
    try std.testing.expectEqualStrings("model-2", registry.metaskIntent().?.model_id);
    try std.testing.expectEqualStrings("metask:api-1", registry.defaultSelection().?.source_id);
    try std.testing.expectEqualStrings("model-2", registry.defaultSelection().?.model_id);
    try std.testing.expectEqual(@as(u64, 8), registry.selection_revision);

    try registry.configureMetask(
        "principal-1",
        "api-2",
        "model-2",
        .openai_responses,
        9,
        10,
        11,
    );
    try std.testing.expectEqualStrings("api-2", registry.metaskIntent().?.api_key_id);
    try std.testing.expectEqualStrings("metask:api-2", registry.defaultSelection().?.source_id);
    try std.testing.expectEqualStrings("model-2", registry.defaultSelection().?.model_id);
    try std.testing.expectEqual(@as(u64, 11), registry.selection_revision);

    const encoded = try encodeAlloc(std.testing.allocator, &registry);
    defer std.testing.allocator.free(encoded);
    var restored = try decode(std.testing.allocator, encoded);
    defer restored.deinit();
    try std.testing.expectEqualStrings("api-2", restored.metaskIntent().?.api_key_id);
    try std.testing.expectEqualStrings("model-2", restored.metaskIntent().?.model_id);
    try std.testing.expectEqualStrings("metask:api-2", restored.defaultSelection().?.source_id);
    try std.testing.expectEqualStrings("model-2", restored.defaultSelection().?.model_id);
    try std.testing.expectEqual(@as(u64, 11), restored.selection_revision);
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
    try registry.selectDefault(selection, "gpt-5", 7);

    try std.testing.expectError(
        error.InvalidProvider,
        registry.markCredentialMissing(selection, null),
    );
    try std.testing.expectEqual(
        contract.CustomProviderCredentialStatus.ready,
        registry.views()[0].credential_status,
    );
    try std.testing.expect(registry.defaultSelection() != null);

    try registry.markCredentialMissing(selection, 8);

    const view = registry.views()[0];
    try std.testing.expectEqual(contract.CustomProviderCredentialStatus.missing, view.credential_status);
    try std.testing.expectEqual(contract.CustomProviderState.configuring, view.state);
    try std.testing.expectEqual(contract.CustomModelTestStatus.untested, view.models[0].test_status);
    try std.testing.expect(registry.defaultSelection() == null);
    try std.testing.expect(registry.defaultBinding() == null);
    try std.testing.expectEqual(@as(u64, 8), registry.selection_revision);

    const encoded = try encodeAlloc(std.testing.allocator, &registry);
    defer std.testing.allocator.free(encoded);
    var restored = try decode(std.testing.allocator, encoded);
    defer restored.deinit();
    try std.testing.expect(restored.defaultSelection() == null);
    try std.testing.expectEqual(@as(u64, 8), restored.selection_revision);
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
    try registry.selectDefault(.{
        .source_id = "custom-provider-0123456789abcdef0123456789abcdef",
        .expected_provider_revision = 1,
    }, "gemini-2.5-flash", 9);

    const encoded = try encodeAlloc(std.testing.allocator, &registry);
    defer std.testing.allocator.free(encoded);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "api-key") == null);
    var restored = try decode(std.testing.allocator, encoded);
    defer restored.deinit();
    const binding = restored.defaultBinding() orelse
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
    try std.testing.expect(restored.defaultBinding() != null);
    try std.testing.expect(restored.reconcileInterruptedTests());
    const failed_retest = restored.views()[0];
    try std.testing.expectEqual(contract.CustomProviderState.ready, failed_retest.state);
    try std.testing.expectEqual(contract.CustomModelTestStatus.failed, failed_retest.models[0].test_status);
    try std.testing.expect(restored.defaultBinding() != null);
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
    try registry.selectDefault(.{
        .source_id = "slot-multi",
        .expected_provider_revision = 1,
    }, "model-a", 10);
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
    }, 6, 7, null);
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
    }, 11, 12, 13);
    try std.testing.expect(registry.defaultSelection() == null);
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
