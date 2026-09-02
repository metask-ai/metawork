//! Product Models-owned registry for user-managed model services.
//!
//! This module stores only public connection metadata. The platform credential
//! account is derived from the public connection identity; neither credential
//! bytes nor a separate platform locator enter this registry or its views.

const std = @import("std");
const builtin = @import("builtin");
const contract = @import("metawork_product_models_contract");

pub const max_store_bytes: usize = 64 * 1024;
pub const store_file_name = "models.json";
pub const legacy_connection_store_file_name = "model-connections.json";
pub const legacy_preference_store_file_name = "preferences.json";
pub const max_pending_credential_deletions: usize =
    contract.Limits.model_connection_entries * 4;

pub const Error = error{
    Capacity,
    InvalidConnection,
    ConnectionNotFound,
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

    fn deinit(self: *OwnedModel, allocator: std.mem.Allocator) void {
        allocator.free(self.display_name);
        allocator.free(self.id);
        self.* = undefined;
    }
};

const OwnedConnection = struct {
    id: []u8,
    display_name: []u8,
    normalized_base_url: []u8,
    protocol: contract.Protocol,
    state: contract.ModelConnectionState = .configuring,
    test_status: contract.ModelConnectionTestStatus = .untested,
    credential_status: contract.ModelConnectionCredentialStatus = .ready,
    enabled: bool = true,
    connection_revision: u64,
    source_generation: u64,
    catalog_generation: u64,
    models: std.ArrayList(OwnedModel) = .empty,
    selected_model: []u8 = &.{},

    fn deinit(self: *OwnedConnection, allocator: std.mem.Allocator) void {
        for (self.models.items) |*model| model.deinit(allocator);
        self.models.deinit(allocator);
        if (self.selected_model.len != 0) allocator.free(self.selected_model);
        allocator.free(self.normalized_base_url);
        allocator.free(self.display_name);
        allocator.free(self.id);
        self.* = undefined;
    }

    fn view(self: *const OwnedConnection) contract.ModelConnectionView {
        var models: []const contract.ModelConnectionModelView = &.{};
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
            .test_status = self.test_status,
            .credential_status = self.credential_status,
            .enabled = self.enabled,
            .models = models,
            .selected_model = self.selected_model,
            // Phase B keeps the existing public connection command shape;
            // phase D hard-cuts this wire field to the split revisions.
            .connection_generation = self.connection_revision,
            .source_generation = self.source_generation,
            .catalog_generation = self.catalog_generation,
        };
    }
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    connections: std.ArrayList(OwnedConnection) = .empty,
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
    preference_recovery_required: bool = false,
    connections_recovery_required: bool = false,
    default_migration_required: bool = false,
    view_storage: std.ArrayList(contract.ModelConnectionView) = .empty,
    model_view_storage: std.ArrayList(contract.ModelConnectionModelView) = .empty,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Registry) void {
        for (self.connections.items) |*connection|
            connection.deinit(self.allocator);
        self.connections.deinit(self.allocator);
        for (self.pending_credential_deletions.items) |connection_id|
            self.allocator.free(connection_id);
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
        result.preference_recovery_required = self.preference_recovery_required;
        result.connections_recovery_required = self.connections_recovery_required;
        result.default_migration_required = self.default_migration_required;
        try result.pending_credential_deletions.ensureTotalCapacity(
            self.allocator,
            self.pending_credential_deletions.items.len,
        );
        for (self.pending_credential_deletions.items) |connection_id| {
            const owned = try self.allocator.dupe(u8, connection_id);
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
        try result.connections.ensureTotalCapacity(
            self.allocator,
            self.connections.items.len,
        );
        for (self.connections.items) |connection|
            try result.connections.append(
                self.allocator,
                try cloneConnection(self.allocator, connection),
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

    pub fn views(self: *Registry) []const contract.ModelConnectionView {
        self.rebuildViews();
        return self.view_storage.items;
    }

    pub fn create(
        self: *Registry,
        input: contract.ModelConnectionCreateCommand,
        connection_revision: u64,
        source_generation: u64,
        catalog_generation: u64,
    ) (std.mem.Allocator.Error || Error)!void {
        if (self.connections.items.len >= contract.Limits.model_connection_entries)
            return error.Capacity;
        contract.validateModelConnectionSpec(input.spec) catch
            return error.InvalidConnection;
        if (input.credential_slot.id.len == 0 or input.model_id.len == 0 or
            connection_revision == 0 or source_generation == 0 or
            catalog_generation == 0)
            return error.InvalidConnection;
        for (self.connections.items) |connection|
            if (std.mem.eql(u8, connection.normalized_base_url, input.spec.normalized_base_url) and
                connection.protocol == input.spec.protocol)
                return error.InvalidConnection;

        if (input.connection_id.len == 0 or
            input.connection_id.len > contract.Limits.instance_id_bytes or
            !std.mem.eql(u8, input.connection_id, input.credential_slot.id) or
            self.findIndex(input.connection_id) != null)
            return error.InvalidConnection;
        var connection: OwnedConnection = .{
            .id = try self.allocator.dupe(u8, input.connection_id),
            .display_name = try self.allocator.dupe(u8, input.spec.display_name),
            .normalized_base_url = try self.allocator.dupe(u8, input.spec.normalized_base_url),
            .protocol = input.spec.protocol,
            .state = .configuring,
            .connection_revision = connection_revision,
            .source_generation = source_generation,
            .catalog_generation = catalog_generation,
        };
        errdefer connection.deinit(self.allocator);
        try connection.models.append(self.allocator, .{
            .id = try self.allocator.dupe(u8, input.model_id),
            .display_name = try self.allocator.dupe(u8, input.model_display_name),
        });
        connection.selected_model = try self.allocator.dupe(u8, input.model_id);
        try self.connections.append(self.allocator, connection);
    }

    pub fn remove(
        self: *Registry,
        selection: contract.ModelConnectionSelectionCommand,
        next_selection_revision: ?u64,
    ) (std.mem.Allocator.Error || Error)!void {
        const index = self.findIndex(selection.connection_id) orelse
            return error.ConnectionNotFound;
        const connection = &self.connections.items[index];
        if (connection.connection_revision != selection.expected_connection_generation)
            return error.GenerationMismatch;
        if (self.pending_credential_deletions.items.len >=
            max_pending_credential_deletions)
            return error.Capacity;
        const cleanup_id = try self.allocator.dupe(u8, connection.id);
        errdefer self.allocator.free(cleanup_id);
        try self.pending_credential_deletions.append(self.allocator, cleanup_id);
        connection.deinit(self.allocator);
        _ = self.connections.orderedRemove(index);
        if (std.mem.eql(u8, self.default_source_id, selection.connection_id)) {
            const revision = next_selection_revision orelse return error.InvalidConnection;
            if (revision == 0 or revision == self.selection_revision)
                return error.InvalidConnection;
            self.clearDefaultSelection();
            self.selection_revision = revision;
        } else if (next_selection_revision != null) {
            return error.InvalidConnection;
        }
    }

    /// Persists an intent to delete a not-yet-committed credential. Creation
    /// writes this recovery fact before touching the platform credential
    /// store, then removes it atomically with the new connection metadata.
    pub fn reserveCredentialDeletion(
        self: *Registry,
        connection_id: []const u8,
    ) (std.mem.Allocator.Error || Error)!void {
        if (connection_id.len == 0 or
            connection_id.len > contract.Limits.instance_id_bytes or
            self.findIndex(connection_id) != null or
            self.pending_credential_deletions.items.len >=
                max_pending_credential_deletions)
            return error.InvalidConnection;
        for (self.pending_credential_deletions.items) |candidate|
            if (std.mem.eql(u8, candidate, connection_id))
                return error.InvalidConnection;
        const owned = try self.allocator.dupe(u8, connection_id);
        errdefer self.allocator.free(owned);
        try self.pending_credential_deletions.append(self.allocator, owned);
    }

    pub fn nextCredentialDeletion(self: *const Registry) ?[]const u8 {
        if (self.pending_credential_deletions.items.len == 0) return null;
        return self.pending_credential_deletions.items[0];
    }

    pub fn completeCredentialDeletion(
        self: *Registry,
        connection_id: []const u8,
    ) Error!void {
        if (self.pending_credential_deletions.items.len == 0 or
            !std.mem.eql(
                u8,
                self.pending_credential_deletions.items[0],
                connection_id,
            ))
            return error.InvalidConnection;
        const removed = self.pending_credential_deletions.orderedRemove(0);
        self.allocator.free(removed);
    }

    pub fn update(
        self: *Registry,
        input: contract.ModelConnectionUpdateCommand,
        next_connection_revision: u64,
        next_source_generation: ?u64,
        next_selection_revision: ?u64,
    ) (std.mem.Allocator.Error || Error)!void {
        contract.validateModelConnectionSpec(input.spec) catch
            return error.InvalidConnection;
        const connection = try self.selected(input.selection);
        const binding_changed = connection.protocol != input.spec.protocol or
            !std.mem.eql(u8, connection.normalized_base_url, input.spec.normalized_base_url) or
            input.credential_slot != null;
        for (self.connections.items) |candidate|
            if (!std.mem.eql(u8, candidate.id, connection.id) and
                candidate.protocol == input.spec.protocol and
                std.mem.eql(
                    u8,
                    candidate.normalized_base_url,
                    input.spec.normalized_base_url,
                ))
                return error.InvalidConnection;
        if (next_connection_revision == 0 or
            next_connection_revision == connection.connection_revision or
            (binding_changed and (next_source_generation == null or
                next_source_generation.? == 0 or
                next_source_generation.? == connection.source_generation)) or
            (!binding_changed and next_source_generation != null))
            return error.InvalidConnection;
        const display_name = try self.allocator.dupe(u8, input.spec.display_name);
        errdefer self.allocator.free(display_name);
        const base_url = try self.allocator.dupe(u8, input.spec.normalized_base_url);
        errdefer self.allocator.free(base_url);
        if (input.credential_slot) |slot| {
            if (!std.mem.eql(u8, slot.id, connection.id))
                return error.InvalidConnection;
        }
        self.allocator.free(connection.display_name);
        self.allocator.free(connection.normalized_base_url);
        connection.display_name = display_name;
        connection.normalized_base_url = base_url;
        if (input.credential_slot != null) {
            connection.credential_status = .ready;
        }
        connection.protocol = input.spec.protocol;
        connection.connection_revision = next_connection_revision;
        if (binding_changed) {
            connection.state = .configuring;
            connection.test_status = .untested;
            connection.source_generation = next_source_generation.?;
            if (std.mem.eql(u8, self.default_source_id, connection.id)) {
                const revision = next_selection_revision orelse return error.InvalidConnection;
                if (revision == 0 or revision == self.selection_revision)
                    return error.InvalidConnection;
                self.clearDefaultSelection();
                self.selection_revision = revision;
            } else if (next_selection_revision != null) {
                return error.InvalidConnection;
            }
        } else if (next_selection_revision != null) {
            return error.InvalidConnection;
        }
    }

    /// A connection test has no durable worker. A persisted `testing` value
    /// therefore means the process stopped before publishing its terminal
    /// result. Recovery makes that interruption explicit while preserving a
    /// previously verified generation's readiness.
    pub fn reconcileInterruptedTests(self: *Registry) bool {
        var changed = false;
        for (self.connections.items) |*connection| {
            if (connection.test_status != .testing) continue;
            connection.test_status = .failed;
            changed = true;
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
    ) (std.mem.Allocator.Error || Error)!void {
        const same_selection = std.mem.eql(u8, principal_ref, self.metask_principal_ref) and
            std.mem.eql(u8, api_key_id, self.metask_api_key_id) and
            std.mem.eql(u8, model_id, self.metask_model_id);
        if (principal_ref.len == 0 or principal_ref.len > contract.Limits.principal_ref_bytes or
            api_key_id.len == 0 or api_key_id.len > contract.Limits.api_key_id_bytes or
            model_id.len == 0 or model_id.len > contract.Limits.model_id_bytes or
            ((protocol == null) != (source_generation == 0)) or selection_revision == 0 or
            (!same_selection and selection_revision == self.metask_selection_revision))
            return error.InvalidData;
        const principal = try self.allocator.dupe(u8, principal_ref);
        errdefer self.allocator.free(principal);
        const api_key = try self.allocator.dupe(u8, api_key_id);
        errdefer self.allocator.free(api_key);
        const model = try self.allocator.dupe(u8, model_id);
        self.freeSelectionText(&self.metask_principal_ref);
        self.freeSelectionText(&self.metask_api_key_id);
        self.freeSelectionText(&self.metask_model_id);
        self.metask_principal_ref = principal;
        self.metask_api_key_id = api_key;
        self.metask_model_id = model;
        self.metask_protocol = protocol;
        self.metask_source_generation = source_generation;
        self.metask_selection_revision = selection_revision;
    }

    pub fn clearMetaskRuntimeAuthority(self: *Registry) void {
        _ = self;
        // Durable non-secret intent intentionally survives authorization loss.
    }

    pub fn defaultSelection(self: *const Registry) ?contract.ModelRef {
        if (self.default_source_id.len == 0) return null;
        return .{
            .source_id = self.default_source_id,
            .model_id = self.default_model_id,
        };
    }

    pub fn sourceGenerationForConnection(self: *const Registry, connection_id: []const u8) ?u64 {
        const index = self.findIndex(connection_id) orelse return null;
        return self.connections.items[index].source_generation;
    }

    pub fn connectionCount(self: *const Registry) usize {
        return self.connections.items.len;
    }

    pub fn reseedLegacyConnection(
        self: *Registry,
        index: usize,
        source_generation: u64,
        catalog_generation: u64,
    ) Error!void {
        if (index >= self.connections.items.len or source_generation == 0 or
            catalog_generation == 0)
            return error.InvalidData;
        const connection = &self.connections.items[index];
        if (connection.source_generation != 0 or connection.catalog_generation != 0)
            return error.InvalidData;
        connection.source_generation = source_generation;
        connection.catalog_generation = catalog_generation;
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
        return connectionHasModel(&self.connections.items[index], model_id);
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
        selection: contract.ModelConnectionSelectionCommand,
        model_id: []const u8,
        selection_revision: u64,
    ) (std.mem.Allocator.Error || Error)!void {
        if (selection_revision == 0 or selection_revision == self.selection_revision)
            return error.InvalidConnection;
        const connection = try self.selected(selection);
        if (connection.state != .ready or connection.credential_status != .ready or
            !connection.enabled)
            return error.InvalidConnection;
        for (connection.models.items) |model| {
            if (!std.mem.eql(u8, model.id, model_id)) continue;
            const selected_model = try self.allocator.dupe(u8, model_id);
            errdefer self.allocator.free(selected_model);
            const default_source_id = try self.allocator.dupe(u8, connection.id);
            errdefer self.allocator.free(default_source_id);
            const default_model_id = try self.allocator.dupe(u8, model_id);
            if (connection.selected_model.len != 0)
                self.allocator.free(connection.selected_model);
            connection.selected_model = selected_model;
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

    pub fn activateMigratedDefault(self: *Registry, selection_revision: u64) Error!void {
        if (self.default_source_id.len == 0 or self.default_model_id.len == 0 or
            self.selection_revision != 0 or selection_revision == 0 or
            !self.validDurableSelection(self.default_source_id, self.default_model_id))
            return error.InvalidData;
        self.selection_revision = selection_revision;
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
        selection: contract.ModelConnectionSelectionCommand,
    ) Error!void {
        const connection = try self.selected(selection);
        connection.credential_status = .missing;
        connection.state = .configuring;
        connection.test_status = .untested;
    }

    pub const DefaultBinding = struct {
        connection_id: []const u8,
        model_id: []const u8,
        protocol: contract.Protocol,
        normalized_base_url: []const u8,
        connection_revision: u64,
        source_generation: u64,
    };

    pub fn desiredDefaultBinding(self: *const Registry) ?DefaultBinding {
        if (self.default_source_id.len == 0 or self.default_model_id.len == 0 or
            self.selection_revision == 0)
            return null;
        const index = self.findIndex(self.default_source_id) orelse return null;
        const connection = self.connections.items[index];
        var model_matches: usize = 0;
        for (connection.models.items) |model| {
            if (std.mem.eql(u8, model.id, self.default_model_id))
                model_matches += 1;
        }
        if (model_matches != 1) return null;
        return .{
            .connection_id = connection.id,
            .model_id = self.default_model_id,
            .protocol = connection.protocol,
            .normalized_base_url = connection.normalized_base_url,
            .connection_revision = connection.connection_revision,
            .source_generation = connection.source_generation,
        };
    }

    pub fn defaultBinding(self: *const Registry) ?DefaultBinding {
        const desired = self.desiredDefaultBinding() orelse return null;
        const index = self.findIndex(desired.connection_id) orelse return null;
        const connection = self.connections.items[index];
        if (connection.state != .ready or
            connection.credential_status != .ready or !connection.enabled)
            return null;
        return desired;
    }

    pub fn executionBinding(
        self: *const Registry,
        selection: contract.ModelConnectionSelectionCommand,
        model_id: []const u8,
    ) Error!DefaultBinding {
        const index = self.findIndex(selection.connection_id) orelse
            return error.ConnectionNotFound;
        const connection = self.connections.items[index];
        if (connection.connection_revision != selection.expected_connection_generation)
            return error.GenerationMismatch;
        if (connection.state != .ready or connection.credential_status != .ready or
            !connection.enabled)
            return error.InvalidConnection;
        var matches: usize = 0;
        for (connection.models.items) |model| {
            if (std.mem.eql(u8, model.id, model_id)) matches += 1;
        }
        if (matches != 1) return error.ModelNotFound;
        return .{
            .connection_id = connection.id,
            .model_id = model_id,
            .protocol = connection.protocol,
            .normalized_base_url = connection.normalized_base_url,
            .connection_revision = connection.connection_revision,
            .source_generation = connection.source_generation,
        };
    }

    pub fn probeBinding(
        self: *const Registry,
        selection: contract.ModelConnectionSelectionCommand,
        model_id: []const u8,
    ) Error!DefaultBinding {
        const index = self.findIndex(selection.connection_id) orelse
            return error.ConnectionNotFound;
        const connection = self.connections.items[index];
        if (connection.connection_revision != selection.expected_connection_generation)
            return error.GenerationMismatch;
        if (connection.credential_status != .ready or !connection.enabled)
            return error.InvalidConnection;
        var matches: usize = 0;
        for (connection.models.items) |model| {
            if (std.mem.eql(u8, model.id, model_id)) matches += 1;
        }
        if (matches != 1) return error.ModelNotFound;
        return .{
            .connection_id = connection.id,
            .model_id = model_id,
            .protocol = connection.protocol,
            .normalized_base_url = connection.normalized_base_url,
            .connection_revision = connection.connection_revision,
            .source_generation = connection.source_generation,
        };
    }

    pub fn markTesting(
        self: *Registry,
        selection: contract.ModelConnectionSelectionCommand,
        model_id: []const u8,
    ) Error!void {
        const connection = try self.selected(selection);
        for (connection.models.items) |model|
            if (std.mem.eql(u8, model.id, model_id)) {
                if (connection.credential_status != .ready or !connection.enabled)
                    return error.InvalidConnection;
                if (connection.test_status == .testing)
                    return error.InvalidConnection;
                connection.test_status = .testing;
                return;
            };
        return error.ModelNotFound;
    }

    pub fn completeTest(
        self: *Registry,
        selection: contract.ModelConnectionSelectionCommand,
        model_id: []const u8,
        succeeded: bool,
    ) Error!void {
        const connection = try self.selected(selection);
        for (connection.models.items) |model|
            if (std.mem.eql(u8, model.id, model_id)) {
                if (connection.test_status != .testing) return error.InvalidConnection;
                connection.test_status = if (succeeded) .connected else .failed;
                if (succeeded) connection.state = .ready;
                return;
            };
        return error.ModelNotFound;
    }

    fn selected(
        self: *Registry,
        selection: contract.ModelConnectionSelectionCommand,
    ) Error!*OwnedConnection {
        const index = self.findIndex(selection.connection_id) orelse
            return error.ConnectionNotFound;
        const connection = &self.connections.items[index];
        if (connection.connection_revision != selection.expected_connection_generation)
            return error.GenerationMismatch;
        return connection;
    }

    fn findIndex(self: *const Registry, id: []const u8) ?usize {
        for (self.connections.items, 0..) |connection, index|
            if (std.mem.eql(u8, connection.id, id)) return index;
        return null;
    }

    fn rebuildViews(self: *Registry) void {
        self.view_storage.clearRetainingCapacity();
        self.model_view_storage.clearRetainingCapacity();
        var model_count: usize = 0;
        for (self.connections.items) |connection| model_count += connection.models.items.len;
        self.view_storage.ensureTotalCapacity(self.allocator, self.connections.items.len) catch
            @panic("model connection view capacity exhausted");
        self.model_view_storage.ensureTotalCapacity(self.allocator, model_count) catch
            @panic("model connection view capacity exhausted");
        for (self.connections.items) |*connection| {
            const model_start = self.model_view_storage.items.len;
            for (connection.models.items) |model|
                self.model_view_storage.append(self.allocator, .{
                    .id = model.id,
                    .display_name = model.display_name,
                }) catch @panic("model connection view capacity exhausted");
            const model_end = self.model_view_storage.items.len;
            self.view_storage.append(self.allocator, .{
                .id = connection.id,
                .display_name = connection.display_name,
                .protocol = connection.protocol,
                .normalized_base_url = connection.normalized_base_url,
                .state = connection.state,
                .test_status = connection.test_status,
                .credential_status = connection.credential_status,
                .enabled = connection.enabled,
                .models = self.model_view_storage.items[model_start..model_end],
                .selected_model = connection.selected_model,
                .connection_generation = connection.connection_revision,
                .source_generation = connection.source_generation,
                .catalog_generation = connection.catalog_generation,
            }) catch @panic("model connection view capacity exhausted");
        }
    }
};

pub fn metaskSourceIdAlloc(
    allocator: std.mem.Allocator,
    api_key_id: []const u8,
) std.mem.Allocator.Error![]u8 {
    return std.fmt.allocPrint(allocator, "metask:{s}", .{api_key_id});
}

fn cloneConnection(
    allocator: std.mem.Allocator,
    source: OwnedConnection,
) (std.mem.Allocator.Error || Error)!OwnedConnection {
    var result: OwnedConnection = .{
        .id = try allocator.dupe(u8, source.id),
        .display_name = try allocator.dupe(u8, source.display_name),
        .normalized_base_url = try allocator.dupe(u8, source.normalized_base_url),
        .protocol = source.protocol,
        .state = source.state,
        .test_status = source.test_status,
        .credential_status = source.credential_status,
        .enabled = source.enabled,
        .connection_revision = source.connection_revision,
        .source_generation = source.source_generation,
        .catalog_generation = source.catalog_generation,
    };
    errdefer result.deinit(allocator);
    try result.models.ensureTotalCapacity(allocator, source.models.items.len);
    for (source.models.items) |model| {
        var cloned: OwnedModel = .{
            .id = try allocator.dupe(u8, model.id),
            .display_name = try allocator.dupe(u8, model.display_name),
        };
        errdefer cloned.deinit(allocator);
        try result.models.append(allocator, cloned);
    }
    if (source.selected_model.len != 0)
        result.selected_model = try allocator.dupe(u8, source.selected_model);
    return result;
}

const ModelWire = struct {
    id: []const u8,
    display_name: []const u8,
};

const LegacyConnectionWire = struct {
    id: []const u8,
    display_name: []const u8,
    normalized_base_url: []const u8,
    protocol: contract.Protocol,
    state: contract.ModelConnectionState,
    test_status: contract.ModelConnectionTestStatus,
    credential_status: contract.ModelConnectionCredentialStatus,
    enabled: bool,
    connection_generation: u64,
    models: []const ModelWire,
    selected_model: []const u8,
};

const LegacyRegistryWire = struct {
    default_connection_id: []const u8,
    default_execution_generation: u64,
    pending_credential_deletions: []const []const u8,
    connections: []const LegacyConnectionWire,
};

pub fn encodeLegacyAlloc(
    allocator: std.mem.Allocator,
    registry: *const Registry,
) (std.mem.Allocator.Error || Error)![]u8 {
    var connection_storage: [contract.Limits.model_connection_entries]LegacyConnectionWire = undefined;
    var model_storage: [contract.Limits.model_connection_entries][contract.Limits.model_connection_model_entries]ModelWire = undefined;
    for (registry.connections.items, 0..) |connection, connection_index| {
        if (connection.models.items.len > contract.Limits.model_connection_model_entries)
            return error.InvalidData;
        for (connection.models.items, 0..) |model, model_index|
            model_storage[connection_index][model_index] = .{
                .id = model.id,
                .display_name = model.display_name,
            };
        connection_storage[connection_index] = .{
            .id = connection.id,
            .display_name = connection.display_name,
            .normalized_base_url = connection.normalized_base_url,
            .protocol = connection.protocol,
            .state = connection.state,
            .test_status = connection.test_status,
            .credential_status = connection.credential_status,
            .enabled = connection.enabled,
            .connection_generation = connection.connection_revision,
            .models = model_storage[connection_index][0..connection.models.items.len],
            .selected_model = connection.selected_model,
        };
    }
    const wire: LegacyRegistryWire = .{
        .default_connection_id = registry.default_source_id,
        // The canonical store never writes Product binding generation. This
        // encoder exists only for legacy-format tests and migration fixtures.
        .default_execution_generation = if (registry.default_source_id.len == 0) 0 else 1,
        .pending_credential_deletions = registry.pending_credential_deletions.items,
        .connections = connection_storage[0..registry.connections.items.len],
    };
    const bytes = try std.json.Stringify.valueAlloc(allocator, wire, .{});
    if (bytes.len == 0 or bytes.len > max_store_bytes) {
        allocator.free(bytes);
        return error.InvalidData;
    }
    return bytes;
}

pub fn decodeLegacy(
    allocator: std.mem.Allocator,
    input: []const u8,
) (std.mem.Allocator.Error || Error)!Registry {
    if (input.len == 0 or input.len > max_store_bytes) return error.InvalidData;
    var parsed = std.json.parseFromSlice(
        LegacyRegistryWire,
        allocator,
        input,
        .{ .ignore_unknown_fields = false },
    ) catch return error.InvalidData;
    defer parsed.deinit();
    const wire = parsed.value;
    if (wire.connections.len > contract.Limits.model_connection_entries or
        wire.pending_credential_deletions.len > max_pending_credential_deletions or
        ((wire.default_connection_id.len == 0) != (wire.default_execution_generation == 0)))
        return error.InvalidData;
    var result = Registry.init(allocator);
    errdefer result.deinit();
    for (wire.pending_credential_deletions, 0..) |connection_id, index| {
        if (connection_id.len == 0 or
            connection_id.len > contract.Limits.instance_id_bytes)
            return error.InvalidData;
        for (wire.pending_credential_deletions[0..index]) |prior|
            if (std.mem.eql(u8, prior, connection_id)) return error.InvalidData;
        const owned = try allocator.dupe(u8, connection_id);
        errdefer allocator.free(owned);
        try result.pending_credential_deletions.append(allocator, owned);
    }
    for (wire.connections) |connection_wire| {
        if (connection_wire.id.len == 0 or
            connection_wire.id.len > contract.Limits.instance_id_bytes or
            connection_wire.connection_generation == 0 or
            connection_wire.models.len == 0 or
            connection_wire.models.len > contract.Limits.model_connection_model_entries)
            return error.InvalidData;
        contract.validateModelConnectionSpec(.{
            .display_name = connection_wire.display_name,
            .protocol = connection_wire.protocol,
            .normalized_base_url = connection_wire.normalized_base_url,
        }) catch return error.InvalidData;
        if (result.findIndex(connection_wire.id) != null) return error.InvalidData;
        for (result.pending_credential_deletions.items) |connection_id|
            if (std.mem.eql(u8, connection_id, connection_wire.id))
                return error.InvalidData;
        var connection: OwnedConnection = .{
            .id = try allocator.dupe(u8, connection_wire.id),
            .display_name = try allocator.dupe(u8, connection_wire.display_name),
            .normalized_base_url = try allocator.dupe(u8, connection_wire.normalized_base_url),
            .protocol = connection_wire.protocol,
            .state = connection_wire.state,
            .test_status = connection_wire.test_status,
            .credential_status = connection_wire.credential_status,
            .enabled = connection_wire.enabled,
            .connection_revision = connection_wire.connection_generation,
            // Legacy connection_generation was a mixed CAS and cannot prove
            // source or catalog authority. Bootstrap assigns fresh tokens.
            .source_generation = 0,
            .catalog_generation = 0,
        };
        errdefer connection.deinit(allocator);
        for (connection_wire.models) |model_wire| {
            if (model_wire.id.len == 0 or
                model_wire.id.len > contract.Limits.model_id_bytes or
                model_wire.display_name.len > contract.Limits.model_display_name_bytes)
                return error.InvalidData;
            for (connection.models.items) |model|
                if (std.mem.eql(u8, model.id, model_wire.id)) return error.InvalidData;
            try connection.models.append(allocator, .{
                .id = try allocator.dupe(u8, model_wire.id),
                .display_name = try allocator.dupe(u8, model_wire.display_name),
            });
        }
        var selected_matches: usize = 0;
        for (connection.models.items) |model| {
            if (std.mem.eql(u8, model.id, connection_wire.selected_model))
                selected_matches += 1;
        }
        if (selected_matches != 1) return error.InvalidData;
        connection.selected_model = try allocator.dupe(u8, connection_wire.selected_model);
        try result.connections.append(allocator, connection);
    }
    if (wire.default_connection_id.len != 0) {
        const index = result.findIndex(wire.default_connection_id) orelse
            return error.InvalidData;
        const connection = result.connections.items[index];
        result.default_source_id = try allocator.dupe(u8, connection.id);
        result.default_model_id = try allocator.dupe(u8, connection.selected_model);
        // Replaced with a fresh opaque value before the canonical migration
        // commit; zero keeps this legacy candidate non-authoritative.
        result.selection_revision = 0;
    }
    for (result.views()) |view|
        contract.validateModelConnectionView(view) catch return error.InvalidData;
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

pub const legacy_preference_bytes: usize = 8 * 1024;

const LegacyPreferenceWire = struct {
    selection_owner_account_id: []const u8,
    api_key_id: []const u8,
    model_id: []const u8,
    metask_source_generation: u64,
};

pub const LegacyPreference = struct {
    allocator: std.mem.Allocator,
    principal_ref: []u8,
    api_key_id: []u8,
    model_id: []u8,
    source_generation: u64,

    pub fn deinit(self: *LegacyPreference) void {
        self.allocator.free(self.principal_ref);
        self.allocator.free(self.api_key_id);
        self.allocator.free(self.model_id);
        self.* = undefined;
    }
};

pub fn decodeLegacyPreference(
    allocator: std.mem.Allocator,
    input: []const u8,
) (std.mem.Allocator.Error || Error)!LegacyPreference {
    if (input.len == 0 or input.len > legacy_preference_bytes) return error.InvalidData;
    var parsed = std.json.parseFromSlice(
        LegacyPreferenceWire,
        allocator,
        input,
        .{ .ignore_unknown_fields = false },
    ) catch return error.InvalidData;
    defer parsed.deinit();
    const wire = parsed.value;
    if (wire.selection_owner_account_id.len == 0 or
        wire.selection_owner_account_id.len > contract.Limits.principal_ref_bytes or
        wire.api_key_id.len == 0 or wire.api_key_id.len > contract.Limits.api_key_id_bytes or
        wire.model_id.len == 0 or wire.model_id.len > contract.Limits.model_id_bytes or
        wire.metask_source_generation == 0 or
        !std.unicode.utf8ValidateSlice(wire.selection_owner_account_id) or
        !std.unicode.utf8ValidateSlice(wire.api_key_id) or
        !std.unicode.utf8ValidateSlice(wire.model_id))
        return error.InvalidData;
    const principal_ref = try allocator.dupe(u8, wire.selection_owner_account_id);
    errdefer allocator.free(principal_ref);
    const api_key_id = try allocator.dupe(u8, wire.api_key_id);
    errdefer allocator.free(api_key_id);
    const model_id = try allocator.dupe(u8, wire.model_id);
    return .{
        .allocator = allocator,
        .principal_ref = principal_ref,
        .api_key_id = api_key_id,
        .model_id = model_id,
        .source_generation = wire.metask_source_generation,
    };
}

const CanonicalConnectionWire = struct {
    id: []const u8,
    display_name: []const u8,
    normalized_base_url: []const u8,
    protocol: contract.Protocol,
    state: contract.ModelConnectionState,
    test_status: contract.ModelConnectionTestStatus,
    credential_status: contract.ModelConnectionCredentialStatus,
    enabled: bool,
    connection_revision: u64,
    source_generation: u64,
    catalog_generation: u64,
    models: []const ModelWire,
    selected_model: []const u8,
};

const MigrationWire = struct {
    preference_recovery_required: bool,
    connections_recovery_required: bool,
    default_migration_required: bool,
};

const CanonicalWire = struct {
    schema: u32,
    metask: ?MetaskIntentWire,
    default_selection: ?ModelRefWire,
    selection_revision: u64,
    migration: MigrationWire,
    pending_credential_deletions: []const []const u8,
    connections: []const CanonicalConnectionWire,
};

pub fn encodeAlloc(
    allocator: std.mem.Allocator,
    registry: *const Registry,
) (std.mem.Allocator.Error || Error)![]u8 {
    var connection_storage: [contract.Limits.model_connection_entries]CanonicalConnectionWire = undefined;
    var model_storage: [contract.Limits.model_connection_entries][contract.Limits.model_connection_model_entries]ModelWire = undefined;
    for (registry.connections.items, 0..) |connection, connection_index| {
        if (connection.models.items.len == 0 or
            connection.models.items.len > contract.Limits.model_connection_model_entries)
            return error.InvalidData;
        for (connection.models.items, 0..) |model, model_index|
            model_storage[connection_index][model_index] = .{
                .id = model.id,
                .display_name = model.display_name,
            };
        connection_storage[connection_index] = .{
            .id = connection.id,
            .display_name = connection.display_name,
            .normalized_base_url = connection.normalized_base_url,
            .protocol = connection.protocol,
            .state = connection.state,
            .test_status = connection.test_status,
            .credential_status = connection.credential_status,
            .enabled = connection.enabled,
            .connection_revision = connection.connection_revision,
            .source_generation = connection.source_generation,
            .catalog_generation = connection.catalog_generation,
            .models = model_storage[connection_index][0..connection.models.items.len],
            .selected_model = connection.selected_model,
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
        .migration = .{
            .preference_recovery_required = registry.preference_recovery_required,
            .connections_recovery_required = registry.connections_recovery_required,
            .default_migration_required = registry.default_migration_required,
        },
        .pending_credential_deletions = registry.pending_credential_deletions.items,
        .connections = connection_storage[0..registry.connections.items.len],
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
    ) catch return error.InvalidData;
    defer parsed.deinit();
    const wire = parsed.value;
    if (wire.schema != 1 or
        wire.connections.len > contract.Limits.model_connection_entries or
        wire.pending_credential_deletions.len > max_pending_credential_deletions or
        ((wire.default_selection == null) and wire.selection_revision == 0 and
            wire.migration.default_migration_required))
        return error.InvalidData;
    var result = Registry.init(allocator);
    errdefer result.deinit();
    result.selection_revision = wire.selection_revision;
    result.preference_recovery_required = wire.migration.preference_recovery_required;
    result.connections_recovery_required = wire.migration.connections_recovery_required;
    result.default_migration_required = wire.migration.default_migration_required;
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
        );
    }
    for (wire.pending_credential_deletions, 0..) |connection_id, index| {
        if (connection_id.len == 0 or
            connection_id.len > contract.Limits.instance_id_bytes)
            return error.InvalidData;
        for (wire.pending_credential_deletions[0..index]) |prior|
            if (std.mem.eql(u8, prior, connection_id)) return error.InvalidData;
        const owned = try allocator.dupe(u8, connection_id);
        errdefer allocator.free(owned);
        try result.pending_credential_deletions.append(allocator, owned);
    }
    for (wire.connections) |connection_wire| {
        if (connection_wire.id.len == 0 or
            connection_wire.id.len > contract.Limits.instance_id_bytes or
            connection_wire.connection_revision == 0 or
            connection_wire.source_generation == 0 or
            connection_wire.catalog_generation == 0 or
            connection_wire.models.len == 0 or
            connection_wire.models.len > contract.Limits.model_connection_model_entries)
            return error.InvalidData;
        contract.validateModelConnectionSpec(.{
            .display_name = connection_wire.display_name,
            .protocol = connection_wire.protocol,
            .normalized_base_url = connection_wire.normalized_base_url,
        }) catch return error.InvalidData;
        if (result.findIndex(connection_wire.id) != null) return error.InvalidData;
        for (result.pending_credential_deletions.items) |connection_id|
            if (std.mem.eql(u8, connection_id, connection_wire.id))
                return error.InvalidData;
        var connection: OwnedConnection = .{
            .id = try allocator.dupe(u8, connection_wire.id),
            .display_name = try allocator.dupe(u8, connection_wire.display_name),
            .normalized_base_url = try allocator.dupe(u8, connection_wire.normalized_base_url),
            .protocol = connection_wire.protocol,
            .state = connection_wire.state,
            .test_status = connection_wire.test_status,
            .credential_status = connection_wire.credential_status,
            .enabled = connection_wire.enabled,
            .connection_revision = connection_wire.connection_revision,
            .source_generation = connection_wire.source_generation,
            .catalog_generation = connection_wire.catalog_generation,
        };
        errdefer connection.deinit(allocator);
        for (connection_wire.models) |model_wire| {
            if (model_wire.id.len == 0 or
                model_wire.id.len > contract.Limits.model_id_bytes or
                model_wire.display_name.len > contract.Limits.model_display_name_bytes)
                return error.InvalidData;
            for (connection.models.items) |model|
                if (std.mem.eql(u8, model.id, model_wire.id)) return error.InvalidData;
            try connection.models.append(allocator, .{
                .id = try allocator.dupe(u8, model_wire.id),
                .display_name = try allocator.dupe(u8, model_wire.display_name),
            });
        }
        if (!connectionHasModel(&connection, connection_wire.selected_model))
            return error.InvalidData;
        connection.selected_model = try allocator.dupe(u8, connection_wire.selected_model);
        try result.connections.append(allocator, connection);
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
        contract.validateModelConnectionView(view) catch return error.InvalidData;
    return result;
}

fn connectionHasModel(connection: *const OwnedConnection, model_id: []const u8) bool {
    var matches: usize = 0;
    for (connection.models.items) |model| {
        if (std.mem.eql(u8, model.id, model_id)) matches += 1;
    }
    return matches == 1;
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
        return self.loadNamedAlloc(allocator, store_file_name, max_store_bytes);
    }

    pub fn loadNamedAlloc(
        self: *FileStore,
        allocator: std.mem.Allocator,
        name: []const u8,
        max_bytes: usize,
    ) (FileStoreError || std.mem.Allocator.Error)!?[]u8 {
        if (name.len == 0 or max_bytes == 0) return error.ReadFailed;
        var file = self.dir.openFile(self.io, name, .{
            .follow_symlinks = false,
            .resolve_beneath = true,
        }) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return error.ReadFailed,
        };
        if (builtin.os.tag == .windows) file.flags.nonblocking = true;
        defer file.close(self.io);
        const length = file.length(self.io) catch return error.ReadFailed;
        if (length == 0 or length > max_bytes) return error.ReadFailed;
        const bytes = try allocator.alloc(u8, @intCast(length));
        errdefer allocator.free(bytes);
        const read = file.readPositionalAll(self.io, bytes, 0) catch
            return error.ReadFailed;
        if (read != bytes.len) return error.ReadFailed;
        return bytes;
    }

    pub fn archiveLegacy(self: *FileStore, name: []const u8, archived_name: []const u8) void {
        if (name.len == 0 or archived_name.len == 0) return;
        self.dir.rename(name, self.dir, archived_name, self.io) catch {};
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

test "registry creates and selects a native model connection" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try testCreate(&registry, .{
        .connection_id = "slot-1",
        .spec = .{
            .display_name = "OpenAI",
            .protocol = .openai_chat_completions,
            .normalized_base_url = "https://api.openai.com/v1/chat/completions",
        },
        .credential_slot = .{ .id = "slot-1" },
        .model_id = "gpt-5",
    });
    const values = registry.views();
    try std.testing.expectEqual(@as(usize, 1), values.len);
    try std.testing.expectEqualStrings("slot-1", values[0].id);
    try std.testing.expectEqualStrings("gpt-5", values[0].selected_model);
    try contract.validateModelConnectionView(values[0]);
}

test "registry hard cut rejects the retired provider field" {
    const retired =
        \\{"default_connection_id":"","default_execution_generation":0,"pending_credential_deletions":[],"connections":[{"id":"slot-1","display_name":"OpenAI","normalized_base_url":"https://api.openai.com/v1/chat/completions","provider":"openai","state":"configuring","test_status":"untested","credential_status":"ready","enabled":true,"connection_generation":1,"models":[{"id":"gpt-5","display_name":""}],"selected_model":"gpt-5"}]}
    ;
    try std.testing.expectError(
        error.InvalidData,
        decode(std.testing.allocator, retired),
    );
}

test "registry codec restores every admitted protocol" {
    const cases = [_]struct {
        connection_id: []const u8,
        protocol: contract.Protocol,
        endpoint: []const u8,
        model_id: []const u8,
    }{
        .{
            .connection_id = "responses-connection",
            .protocol = .openai_responses,
            .endpoint = "https://api.openai.com/v1/responses",
            .model_id = "gpt-5",
        },
        .{
            .connection_id = "anthropic-connection",
            .protocol = .anthropic_messages,
            .endpoint = "https://api.anthropic.com/v1/messages",
            .model_id = "claude-sonnet-4-5",
        },
        .{
            .connection_id = "chat-completions-connection",
            .protocol = .openai_chat_completions,
            .endpoint = "https://api.openai.com/v1/chat/completions",
            .model_id = "gpt-4.1",
        },
        .{
            .connection_id = "gemini-connection",
            .protocol = .gemini_native,
            .endpoint = "https://generativelanguage.googleapis.com",
            .model_id = "gemini-2.5-flash",
        },
    };
    for (cases) |case| {
        var registry = Registry.init(std.testing.allocator);
        defer registry.deinit();
        try testCreate(&registry, .{
            .connection_id = case.connection_id,
            .spec = .{
                .display_name = case.connection_id,
                .protocol = case.protocol,
                .normalized_base_url = case.endpoint,
            },
            .credential_slot = .{ .id = case.connection_id },
            .model_id = case.model_id,
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
        .connection_id = "slot-1",
        .spec = .{
            .display_name = "Gemini",
            .protocol = .gemini_native,
            .normalized_base_url = "https://generativelanguage.googleapis.com",
        },
        .credential_slot = .{ .id = "slot-1" },
        .model_id = "gemini-2.5-flash",
    });
    try registry.markTesting(.{
        .connection_id = "slot-1",
        .expected_connection_generation = 1,
    }, "gemini-2.5-flash");
    try registry.completeTest(.{
        .connection_id = "slot-1",
        .expected_connection_generation = 1,
    }, "gemini-2.5-flash", true);
    try std.testing.expectError(error.GenerationMismatch, registry.selectDefault(.{
        .connection_id = "slot-1",
        .expected_connection_generation = 2,
    }, "gemini-2.5-flash", 1));
    try std.testing.expectError(error.ModelNotFound, registry.selectDefault(.{
        .connection_id = "slot-1",
        .expected_connection_generation = 1,
    }, "missing", 1));
}

test "registry updates public metadata without exposing credential bytes" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try testCreate(&registry, .{
        .connection_id = "slot-opaque",
        .spec = .{
            .display_name = "OpenAI",
            .protocol = .openai_chat_completions,
            .normalized_base_url = "https://api.openai.com/v1/chat/completions",
        },
        .credential_slot = .{ .id = "slot-opaque" },
        .model_id = "gpt-5",
    });
    try registry.update(.{
        .selection = .{
            .connection_id = "slot-opaque",
            .expected_connection_generation = 1,
        },
        .spec = .{
            .display_name = "OpenAI Team",
            .protocol = .openai_chat_completions,
            .normalized_base_url = "https://api.openai.com/v1/chat/completions",
        },
    }, 2, null, null);
    const view = registry.views()[0];
    try std.testing.expectEqualStrings("OpenAI Team", view.display_name);
    try std.testing.expectEqual(@as(u64, 2), view.connection_generation);
    try std.testing.expect(view.credential_status == .ready);
}

test "registry fails closed when a durable credential disappears" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try testCreate(&registry, .{
        .connection_id = "slot-missing",
        .spec = .{
            .display_name = "OpenAI",
            .protocol = .openai_chat_completions,
            .normalized_base_url = "https://api.openai.com/v1/chat/completions",
        },
        .credential_slot = .{ .id = "slot-missing" },
        .model_id = "gpt-5",
    });
    const selection: contract.ModelConnectionSelectionCommand = .{
        .connection_id = "slot-missing",
        .expected_connection_generation = 1,
    };
    try registry.markTesting(selection, "gpt-5");
    try registry.completeTest(selection, "gpt-5", true);
    try registry.selectDefault(selection, "gpt-5", 7);

    try registry.markCredentialMissing(selection);

    const view = registry.views()[0];
    try std.testing.expectEqual(contract.ModelConnectionCredentialStatus.missing, view.credential_status);
    try std.testing.expectEqual(contract.ModelConnectionState.configuring, view.state);
    try std.testing.expectEqual(contract.ModelConnectionTestStatus.untested, view.test_status);
    try std.testing.expect(registry.defaultBinding() == null);
}

test "registry codec restores opaque slots and the durable default binding" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try testCreate(&registry, .{
        .connection_id = "model-connection-0123456789abcdef0123456789abcdef",
        .spec = .{
            .display_name = "Gemini",
            .protocol = .gemini_native,
            .normalized_base_url = "https://generativelanguage.googleapis.com",
        },
        .credential_slot = .{ .id = "model-connection-0123456789abcdef0123456789abcdef" },
        .model_id = "gemini-2.5-flash",
        .model_display_name = "Gemini 2.5 Flash",
    });
    try registry.markTesting(.{
        .connection_id = "model-connection-0123456789abcdef0123456789abcdef",
        .expected_connection_generation = 1,
    }, "gemini-2.5-flash");
    try registry.completeTest(.{
        .connection_id = "model-connection-0123456789abcdef0123456789abcdef",
        .expected_connection_generation = 1,
    }, "gemini-2.5-flash", true);
    try registry.selectDefault(.{
        .connection_id = "model-connection-0123456789abcdef0123456789abcdef",
        .expected_connection_generation = 1,
    }, "gemini-2.5-flash", 9);

    const encoded = try encodeAlloc(std.testing.allocator, &registry);
    defer std.testing.allocator.free(encoded);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "api-key") == null);
    var restored = try decode(std.testing.allocator, encoded);
    defer restored.deinit();
    const binding = restored.defaultBinding() orelse
        return error.TestExpectedEqual;
    try std.testing.expectEqualStrings(
        "model-connection-0123456789abcdef0123456789abcdef",
        binding.connection_id,
    );
    try std.testing.expectEqualStrings("gemini-2.5-flash", binding.model_id);
    try std.testing.expectEqual(@as(u64, 2), binding.source_generation);
    try restored.markTesting(.{
        .connection_id = binding.connection_id,
        .expected_connection_generation = binding.connection_revision,
    }, binding.model_id);
    try std.testing.expectEqual(
        contract.ModelConnectionTestStatus.testing,
        restored.views()[0].test_status,
    );
    try std.testing.expect(restored.defaultBinding() != null);
    try std.testing.expect(restored.reconcileInterruptedTests());
    const failed_retest = restored.views()[0];
    try std.testing.expectEqual(contract.ModelConnectionState.ready, failed_retest.state);
    try std.testing.expectEqual(contract.ModelConnectionTestStatus.failed, failed_retest.test_status);
    try std.testing.expect(restored.defaultBinding() != null);
}

test "model connection file store atomically restores registry bytes" {
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
    const canonical = "{\"schema\":1,\"metask\":null,\"default_selection\":null,\"selection_revision\":0,\"migration\":{\"preference_recovery_required\":false,\"connections_recovery_required\":false,\"default_migration_required\":false},\"pending_credential_deletions\":[],\"connections\":[]}";
    try file_store.commit(canonical);
    const restored = (try file_store.loadAlloc(std.testing.allocator)) orelse
        return error.TestExpectedEqual;
    defer std.testing.allocator.free(restored);
    try std.testing.expectEqualStrings(
        canonical,
        restored,
    );
}

fn testCreate(registry: *Registry, input: contract.ModelConnectionCreateCommand) !void {
    try registry.create(input, 1, 2, 3);
}
