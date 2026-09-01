//! Product Control's installed execution authority and secret-free Account
//! read model. This is an internal kernel, not a Product aggregate or owner.
//! It owns replacement/redaction ordering but retains no caller or aggregate
//! capability beyond each synchronous call.

const std = @import("std");
const builtin = @import("builtin");
const account = @import("metawork_account_contract");

fn FixedText(comptime capacity: usize) type {
    return struct {
        bytes: [capacity]u8 = undefined,
        len: usize = 0,

        const Self = @This();

        fn setNoFail(self: *Self, value: []const u8) void {
            std.debug.assert(value.len <= capacity);
            std.debug.assert(std.unicode.utf8ValidateSlice(value));
            @memcpy(self.bytes[0..value.len], value);
            self.len = value.len;
        }

        fn view(self: *const Self) []const u8 {
            return self.bytes[0..self.len];
        }
    };
}

const ApiKeyProjection = struct {
    id: FixedText(account.Limits.api_key_id_bytes) = .{},
    name: FixedText(account.Limits.api_key_name_bytes) = .{},
    suffix: FixedText(account.Limits.api_key_suffix_bytes) = .{},
    provider_kind: account.ProviderKind = .anthropic,
};

const ModelProjection = struct {
    id: FixedText(account.Limits.model_id_bytes) = .{},
    display_name: FixedText(account.Limits.model_display_name_bytes) = .{},
};

const ModelConnectionProjection = struct {
    id: FixedText(account.Limits.api_key_id_bytes) = .{},
    display_name: FixedText(account.Limits.display_name_bytes) = .{},
    normalized_base_url: FixedText(account.Limits.base_url_bytes) = .{},
    protocol: account.ModelConnectionProtocol = .anthropic_messages,
    state: account.ModelConnectionState = .configuring,
    test_status: account.ModelConnectionTestStatus = .untested,
    credential_status: account.ModelConnectionCredentialStatus = .missing,
    enabled: bool = false,
    selected_model: FixedText(account.Limits.model_id_bytes) = .{},
    connection_generation: u64 = 0,
    models: []ModelProjection = &.{},
    model_views: []account.ModelConnectionModelView = &.{},
    model_count: usize = 0,
};

const AccountProjection = struct {
    allocator: std.mem.Allocator,
    state: account.AccountState = .checking,
    catalog_state: account.CatalogState = .unavailable,
    can_cancel: bool = false,
    account_id: FixedText(account.Limits.account_id_bytes) = .{},
    display_name: FixedText(account.Limits.display_name_bytes) = .{},
    selected_api_key_id: FixedText(account.Limits.api_key_id_bytes) = .{},
    selected_model: FixedText(account.Limits.model_id_bytes) = .{},
    candidate_api_key_id: FixedText(account.Limits.api_key_id_bytes) = .{},
    candidate_model: FixedText(account.Limits.model_id_bytes) = .{},
    model_catalog_api_key_id: FixedText(account.Limits.api_key_id_bytes) = .{},
    safe_diagnostic: FixedText(account.Limits.safe_diagnostic_bytes) = .{},
    api_keys: []ApiKeyProjection,
    api_key_views: []account.ApiKeyView,
    api_key_count: usize = 0,
    models: []ModelProjection,
    model_views: []account.ModelView,
    model_count: usize = 0,
    model_connections: []ModelConnectionProjection,
    model_connection_models: []ModelProjection,
    model_connection_views: []account.ModelConnectionView,
    model_connection_model_views: []account.ModelConnectionModelView,
    model_connection_count: usize = 0,
    account_can_create_task: bool = false,
    error_code: account.ErrorCode = .none,
    catalog_generation: u64 = 0,
    metask_execution_generation: u64 = 0,
    execution_generation: u64 = 0,

    fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!AccountProjection {
        const api_keys = try allocator.alloc(ApiKeyProjection, account.Limits.api_key_entries);
        errdefer allocator.free(api_keys);
        @memset(api_keys, .{});
        const api_key_views = try allocator.alloc(account.ApiKeyView, account.Limits.api_key_entries);
        errdefer allocator.free(api_key_views);
        const models = try allocator.alloc(ModelProjection, account.Limits.model_entries);
        errdefer allocator.free(models);
        @memset(models, .{});
        const model_views = try allocator.alloc(account.ModelView, account.Limits.model_entries);
        errdefer allocator.free(model_views);
        const model_connections = try allocator.alloc(
            ModelConnectionProjection,
            account.Limits.model_connection_entries,
        );
        errdefer allocator.free(model_connections);
        @memset(model_connections, .{});
        const connection_model_capacity = account.Limits.model_connection_entries *
            account.Limits.model_connection_model_entries;
        const model_connection_models = try allocator.alloc(
            ModelProjection,
            connection_model_capacity,
        );
        errdefer allocator.free(model_connection_models);
        @memset(model_connection_models, .{});
        const model_connection_views = try allocator.alloc(
            account.ModelConnectionView,
            account.Limits.model_connection_entries,
        );
        errdefer allocator.free(model_connection_views);
        const model_connection_model_views = try allocator.alloc(
            account.ModelConnectionModelView,
            connection_model_capacity,
        );
        errdefer allocator.free(model_connection_model_views);
        for (model_connections, 0..) |*connection, index| {
            const start = index * account.Limits.model_connection_model_entries;
            const end = start + account.Limits.model_connection_model_entries;
            connection.models = model_connection_models[start..end];
            connection.model_views = model_connection_model_views[start..end];
        }
        return .{
            .allocator = allocator,
            .api_keys = api_keys,
            .api_key_views = api_key_views,
            .models = models,
            .model_views = model_views,
            .model_connections = model_connections,
            .model_connection_models = model_connection_models,
            .model_connection_views = model_connection_views,
            .model_connection_model_views = model_connection_model_views,
        };
    }

    fn deinit(self: *AccountProjection) void {
        self.allocator.free(self.model_connection_model_views);
        self.allocator.free(self.model_connection_views);
        self.allocator.free(self.model_connection_models);
        self.allocator.free(self.model_connections);
        self.allocator.free(self.model_views);
        self.allocator.free(self.models);
        self.allocator.free(self.api_key_views);
        self.allocator.free(self.api_keys);
        self.* = undefined;
    }

    fn commitNoFail(self: *AccountProjection, source_view: account.AccountView) void {
        account.validateView(source_view) catch
            @panic("Account published an invalid AccountView");
        std.debug.assert(source_view.api_keys.len <= self.api_keys.len);
        std.debug.assert(source_view.models.len <= self.models.len);
        std.debug.assert(source_view.model_connections.len <= self.model_connections.len);
        self.model_connection_count = 0;
        self.state = source_view.state;
        self.catalog_state = source_view.catalog_state;
        self.can_cancel = source_view.can_cancel;
        self.account_id.setNoFail(source_view.account_id);
        self.display_name.setNoFail(source_view.display_name);
        self.selected_api_key_id.setNoFail(source_view.selected_api_key_id);
        self.selected_model.setNoFail(source_view.selected_model);
        self.candidate_api_key_id.setNoFail(source_view.candidate_api_key_id);
        self.candidate_model.setNoFail(source_view.candidate_model);
        self.model_catalog_api_key_id.setNoFail(source_view.model_catalog_api_key_id);
        self.safe_diagnostic.setNoFail(source_view.safe_diagnostic);
        self.api_key_count = source_view.api_keys.len;
        for (
            source_view.api_keys,
            self.api_keys[0..source_view.api_keys.len],
            self.api_key_views[0..source_view.api_keys.len],
        ) |source, *target, *target_view| {
            target.id.setNoFail(source.id);
            target.name.setNoFail(source.name);
            target.suffix.setNoFail(source.suffix);
            target.provider_kind = source.provider_kind;
            target_view.* = .{
                .id = target.id.view(),
                .name = target.name.view(),
                .suffix = target.suffix.view(),
                .provider_kind = target.provider_kind,
            };
        }
        for (
            source_view.model_connections,
            self.model_connections[0..source_view.model_connections.len],
            self.model_connection_views[0..source_view.model_connections.len],
        ) |source, *target, *target_view| {
            const target_models = target.models;
            const target_model_views = target.model_views;
            target.* = .{
                .protocol = source.protocol,
                .state = source.state,
                .test_status = source.test_status,
                .credential_status = source.credential_status,
                .enabled = source.enabled,
                .connection_generation = source.connection_generation,
                .models = target_models,
                .model_views = target_model_views,
                .model_count = source.models.len,
            };
            std.debug.assert(source.models.len <= target.models.len);
            target.id.setNoFail(source.id);
            target.display_name.setNoFail(source.display_name);
            target.normalized_base_url.setNoFail(source.normalized_base_url);
            target.selected_model.setNoFail(source.selected_model);
            for (
                source.models,
                target.models[0..source.models.len],
                target.model_views[0..source.models.len],
            ) |model, *owned, *model_view| {
                owned.* = .{};
                owned.id.setNoFail(model.id);
                owned.display_name.setNoFail(model.display_name);
                model_view.* = .{
                    .id = owned.id.view(),
                    .display_name = owned.display_name.view(),
                };
            }
            target_view.* = .{
                .id = target.id.view(),
                .display_name = target.display_name.view(),
                .protocol = target.protocol,
                .normalized_base_url = target.normalized_base_url.view(),
                .state = target.state,
                .test_status = target.test_status,
                .credential_status = target.credential_status,
                .enabled = target.enabled,
                .models = target.model_views[0..target.model_count],
                .selected_model = target.selected_model.view(),
                .connection_generation = target.connection_generation,
            };
        }
        self.model_connection_count = source_view.model_connections.len;
        self.model_count = source_view.models.len;
        for (
            source_view.models,
            self.models[0..source_view.models.len],
            self.model_views[0..source_view.models.len],
        ) |source, *target, *target_view| {
            target.id.setNoFail(source.id);
            target.display_name.setNoFail(source.display_name);
            target_view.* = .{
                .id = target.id.view(),
                .display_name = target.display_name.view(),
                .metadata = source.metadata,
            };
        }
        self.account_can_create_task = source_view.can_create_task;
        self.error_code = source_view.error_code;
        self.catalog_generation = source_view.catalog_generation;
        self.metask_execution_generation = source_view.metask_execution_generation;
        self.execution_generation = source_view.execution_generation;
    }

    fn view(self: *const AccountProjection, can_create_task: bool) account.AccountView {
        return .{
            .state = self.state,
            .catalog_state = self.catalog_state,
            .can_cancel = self.can_cancel,
            .account_id = self.account_id.view(),
            .display_name = self.display_name.view(),
            .api_keys = self.api_key_views[0..self.api_key_count],
            .models = self.model_views[0..self.model_count],
            .model_connections = self.model_connection_views[0..self.model_connection_count],
            .selected_api_key_id = self.selected_api_key_id.view(),
            .selected_model = self.selected_model.view(),
            .candidate_api_key_id = self.candidate_api_key_id.view(),
            .candidate_model = self.candidate_model.view(),
            .model_catalog_api_key_id = self.model_catalog_api_key_id.view(),
            .can_create_task = can_create_task,
            .error_code = self.error_code,
            .safe_diagnostic = self.safe_diagnostic.view(),
            .catalog_generation = self.catalog_generation,
            .metask_execution_generation = self.metask_execution_generation,
            .execution_generation = self.execution_generation,
        };
    }

    fn hasModel(self: *const AccountProjection, model: []const u8) bool {
        for (self.model_views[0..self.model_count]) |candidate|
            if (std.mem.eql(u8, candidate.id, model)) return true;
        return false;
    }

    fn selectedProvider(self: *const AccountProjection) ?account.ProviderKind {
        for (self.api_key_views[0..self.api_key_count]) |api_key| {
            if (std.mem.eql(u8, api_key.id, self.selected_api_key_id.view()))
                return api_key.provider_kind;
        }
        return null;
    }
};

const ActiveExecution = struct {
    allocator: std.mem.Allocator,
    credential_storage: []u8,
    model_storage: []u8,
    base_url_storage: []u8,
    credential_len: usize = 0,
    model_len: usize = 0,
    base_url_len: usize = 0,
    provider_id_storage: [account.Limits.provider_id_bytes]u8 = undefined,
    provider_id_len: usize = 0,
    protocol: ?account.ModelConnectionProtocol = null,
    provider: ?account.ProviderKind = null,
    generation: u64 = 0,

    fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!ActiveExecution {
        const credential_storage = try allocator.alloc(u8, account.Limits.api_key_bytes);
        errdefer allocator.free(credential_storage);
        const model_storage = try allocator.alloc(u8, account.Limits.model_id_bytes);
        errdefer allocator.free(model_storage);
        const base_url_storage = try allocator.alloc(u8, account.Limits.base_url_bytes);
        errdefer allocator.free(base_url_storage);
        return .{
            .allocator = allocator,
            .credential_storage = credential_storage,
            .model_storage = model_storage,
            .base_url_storage = base_url_storage,
        };
    }

    fn deinit(self: *ActiveExecution) void {
        std.crypto.secureZero(u8, self.credential_storage);
        self.allocator.free(self.base_url_storage);
        self.allocator.free(self.model_storage);
        self.allocator.free(self.credential_storage);
        self.* = undefined;
    }

    fn installNoFail(self: *ActiveExecution, execution: *account.OwnedExecutionConfig) void {
        const input = execution.input();
        const validation = if (execution.model_connection)
            account.validateModelConnectionExecutionConfig(input)
        else
            account.validateExecutionConfig(input);
        validation catch @panic("Account published an invalid ExecutionConfig");
        self.installBytesNoFail(input);
        execution.deinit();
    }

    fn installBytesNoFail(self: *ActiveExecution, input: account.ExecutionConfigInput) void {
        const provider = input.target.provider_kind;
        const credential_bytes = input.api_key;
        const model_id = input.target.model;
        const base_url = input.target.base_url;
        const generation = input.execution_generation;
        std.debug.assert(input.target.provider_id.len <= self.provider_id_storage.len);
        @memcpy(self.provider_id_storage[0..input.target.provider_id.len], input.target.provider_id);
        self.provider_id_len = input.target.provider_id.len;
        self.protocol = input.target.protocol;
        std.debug.assert(credential_bytes.len <= self.credential_storage.len);
        std.debug.assert(model_id.len <= self.model_storage.len);
        std.debug.assert(base_url.len <= self.base_url_storage.len);
        std.crypto.secureZero(u8, self.credential_storage);
        @memcpy(self.credential_storage[0..credential_bytes.len], credential_bytes);
        @memcpy(self.model_storage[0..model_id.len], model_id);
        @memcpy(self.base_url_storage[0..base_url.len], base_url);
        self.credential_len = credential_bytes.len;
        self.model_len = model_id.len;
        self.base_url_len = base_url.len;
        self.provider = provider;
        self.generation = generation;
    }

    fn clearNoFail(self: *ActiveExecution) void {
        std.crypto.secureZero(u8, self.credential_storage);
        self.credential_len = 0;
        self.model_len = 0;
        self.base_url_len = 0;
        self.provider = null;
        self.protocol = null;
        self.provider_id_len = 0;
        self.generation = 0;
    }

    fn providerId(self: *const ActiveExecution) []const u8 {
        return self.provider_id_storage[0..self.provider_id_len];
    }
    fn credential(self: *const ActiveExecution) []const u8 {
        return self.credential_storage[0..self.credential_len];
    }
    fn model(self: *const ActiveExecution) []const u8 {
        return self.model_storage[0..self.model_len];
    }
    fn baseUrl(self: *const ActiveExecution) []const u8 {
        return self.base_url_storage[0..self.base_url_len];
    }
    fn ready(self: *const ActiveExecution) bool {
        return self.generation != 0 and self.provider != null and self.protocol != null and
            self.provider_id_len != 0 and
            self.credential_len != 0 and self.model_len != 0;
    }
};

const ReplacementKind = enum { none, default, identity };

const RedactionPreparation = union(enum) {
    none,
    install: struct {
        generation: u64,
        credential_ptr: [*]const u8,
        credential_len: usize,
    },
    clear: u64,
};

pub const PreparedModelConnectionBinding = struct {
    allocator: std.mem.Allocator,
    connection_id: []u8,
    model_id: []u8,

    pub fn init(
        allocator: std.mem.Allocator,
        connection_id: []const u8,
        model_id: []const u8,
    ) std.mem.Allocator.Error!PreparedModelConnectionBinding {
        const owned_connection_id = try allocator.dupe(u8, connection_id);
        errdefer allocator.free(owned_connection_id);
        return .{
            .allocator = allocator,
            .connection_id = owned_connection_id,
            .model_id = try allocator.dupe(u8, model_id),
        };
    }

    pub fn deinit(self: *PreparedModelConnectionBinding) void {
        self.allocator.free(self.model_id);
        self.allocator.free(self.connection_id);
        self.* = undefined;
    }
};

pub const ExecutionIdentity = struct {
    generation: u64,
    provider: account.ProviderKind,
};

pub const AutomationInput = struct {
    provider: account.ProviderKind,
    credential: []const u8,
    model: []const u8,
    base_url: []const u8,
    generation: u64,
};

pub const ProjectionRedaction = struct {
    context: *anyopaque,
    apply_fn: *const fn (*anyopaque, []const u8) void,

    pub fn apply(self: ProjectionRedaction, credential: []const u8) void {
        self.apply_fn(self.context, credential);
    }
};

pub const State = struct {
    projection: AccountProjection,
    execution: ActiveExecution,
    replacement: ReplacementKind = .none,
    redaction_preparation: RedactionPreparation = .none,
    custom_binding: ?PreparedModelConnectionBinding = null,

    pub fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!State {
        var projection = try AccountProjection.init(allocator);
        errdefer projection.deinit();
        return .{
            .projection = projection,
            .execution = try ActiveExecution.init(allocator),
        };
    }

    pub fn deinit(self: *State) void {
        self.execution.deinit();
        if (self.custom_binding) |*binding| binding.deinit();
        self.projection.deinit();
        self.* = undefined;
    }

    pub fn commitAccountFactNoFail(self: *State, fact: account.AccountFact) void {
        self.projection.commitNoFail(fact.view);
    }

    pub fn beginIdentityReplacement(self: *State) error{ExecutionInUse}!void {
        if (self.replacement != .none) return error.ExecutionInUse;
        std.debug.assert(self.redaction_preparation == .none);
        self.replacement = .identity;
    }

    pub fn beginDefaultReplacement(self: *State) error{ExecutionInUse}!void {
        if (self.replacement != .none) return error.ExecutionInUse;
        std.debug.assert(self.redaction_preparation == .none);
        self.replacement = .default;
    }

    pub fn endReplacementNoFail(self: *State) void {
        std.debug.assert(self.replacement != .none);
        self.replacement = .none;
        self.redaction_preparation = .none;
    }

    pub fn prepareInstall(self: *State, input: account.ExecutionConfigInput, durable: anytype) !void {
        std.debug.assert(self.replacement != .none);
        std.debug.assert(self.redaction_preparation == .none);
        try durable.apply(input.api_key);
        self.redaction_preparation = .{ .install = .{
            .generation = input.execution_generation,
            .credential_ptr = input.api_key.ptr,
            .credential_len = input.api_key.len,
        } };
    }

    pub fn prepareClear(self: *State, durable: anytype) !void {
        std.debug.assert(self.replacement != .none);
        std.debug.assert(self.redaction_preparation == .none);
        try durable.apply("");
        self.redaction_preparation = .{ .clear = self.execution.generation };
    }

    pub fn installMetaskNoFail(
        self: *State,
        execution: *account.OwnedExecutionConfig,
        redaction: ProjectionRedaction,
    ) void {
        std.debug.assert(self.replacement != .none);
        const input = execution.input();
        std.debug.assert(self.projection.catalog_state == .ready);
        std.debug.assert(self.projection.execution_generation == input.execution_generation);
        std.debug.assert(std.mem.eql(u8, self.projection.selected_model.view(), input.target.model));
        self.consumeInstallPreparation(input);
        redaction.apply(self.execution.credential());
        redaction.apply(input.api_key);
        if (self.custom_binding) |*binding| binding.deinit();
        self.custom_binding = null;
        self.execution.installNoFail(execution);
    }

    pub fn installModelConnectionNoFail(
        self: *State,
        execution: *account.OwnedExecutionConfig,
        prepared_binding: *PreparedModelConnectionBinding,
        redaction: ProjectionRedaction,
    ) void {
        std.debug.assert(self.replacement != .none);
        self.consumeInstallPreparation(execution.input());
        redaction.apply(self.execution.credential());
        redaction.apply(execution.input().api_key);
        self.execution.installNoFail(execution);
        if (self.custom_binding) |*previous| previous.deinit();
        self.custom_binding = prepared_binding.*;
        prepared_binding.* = undefined;
    }

    pub fn installAutomationNoFail(
        self: *State,
        input: AutomationInput,
        redaction: ProjectionRedaction,
    ) void {
        const execution_input: account.ExecutionConfigInput = .{
            .target = .{
                .provider_id = "metask:automation-key",
                .protocol = account.protocolForProviderKind(input.provider),
                .provider_kind = input.provider,
                .model = input.model,
                .base_url = input.base_url,
            },
            .api_key = input.credential,
            .execution_generation = input.generation,
        };
        self.consumeInstallPreparation(execution_input);
        redaction.apply(self.execution.credential());
        redaction.apply(input.credential);
        if (self.custom_binding) |*binding| binding.deinit();
        self.custom_binding = null;
        self.execution.installBytesNoFail(execution_input);
    }

    pub fn clearNoFail(self: *State, redaction: ProjectionRedaction) void {
        std.debug.assert(self.replacement != .none);
        std.debug.assert(self.projection.execution_generation == 0);
        self.consumeClearPreparation(self.execution.generation);
        redaction.apply(self.execution.credential());
        self.execution.clearNoFail();
        if (self.custom_binding) |*binding| binding.deinit();
        self.custom_binding = null;
    }

    fn consumeInstallPreparation(self: *State, input: account.ExecutionConfigInput) void {
        switch (self.redaction_preparation) {
            .install => |prepared| {
                std.debug.assert(prepared.generation == input.execution_generation);
                std.debug.assert(prepared.credential_len == input.api_key.len);
                std.debug.assert(prepared.credential_ptr == input.api_key.ptr);
            },
            else => unreachable,
        }
        self.redaction_preparation = .none;
    }

    fn consumeClearPreparation(self: *State, execution_generation: u64) void {
        switch (self.redaction_preparation) {
            .clear => |prepared| std.debug.assert(prepared == execution_generation),
            else => unreachable,
        }
        self.redaction_preparation = .none;
    }

    pub fn accountView(self: *const State, owner_available: bool) account.AccountView {
        var result = self.projection.view(self.canCreateTask(owner_available));
        if (self.custom_binding) |binding| {
            result.execution_source = .model_connection;
            result.selected_model_connection_id = binding.connection_id;
            result.execution_generation = self.execution.generation;
        }
        return result;
    }

    pub fn canCreateTask(self: *const State, owner_available: bool) bool {
        return owner_available and self.replacement == .none and self.execution.ready() and
            if (self.custom_binding != null)
                true
            else
                self.projection.account_can_create_task and
                    self.projection.catalog_state == .ready and
                    self.projection.execution_generation == self.execution.generation;
    }

    pub fn taskModelSelectionAuthorized(
        self: *const State,
        identity: ExecutionIdentity,
        expected_catalog_generation: u64,
        model_id: []const u8,
    ) bool {
        return self.replacement == .none and
            self.custom_binding == null and
            self.execution.ready() and
            self.projection.account_can_create_task and
            self.projection.catalog_state == .ready and
            self.projection.catalog_generation != 0 and
            expected_catalog_generation == self.projection.catalog_generation and
            self.projection.execution_generation == self.execution.generation and
            self.projection.metask_execution_generation == self.execution.generation and
            identity.generation == self.execution.generation and
            identity.provider == self.execution.provider.? and
            self.projection.selectedProvider() == identity.provider and
            self.projection.hasModel(model_id);
    }

    pub fn supportsTaskExecution(
        self: *const State,
        provider_kind: account.ProviderKind,
        model_id: []const u8,
    ) bool {
        return self.replacement == .none and self.execution.ready() and
            provider_kind == self.execution.provider.? and
            if (self.custom_binding) |binding|
                std.mem.eql(u8, binding.model_id, self.execution.model()) and
                    std.mem.eql(u8, model_id, binding.model_id)
            else
                self.projection.account_can_create_task and
                    self.projection.catalog_state == .ready and
                    self.projection.execution_generation == self.execution.generation and
                    self.projection.hasModel(model_id);
    }

    pub fn recoveryAuthorityExact(
        self: *const State,
        execution_generation: u64,
        provider_kind: account.ProviderKind,
        model_id: []const u8,
    ) bool {
        return execution_generation == self.execution.generation and
            self.supportsTaskExecution(provider_kind, model_id);
    }

    pub fn validExecutionGeneration(self: *const State, execution_generation: u64) bool {
        return execution_generation != 0 and execution_generation == self.execution.generation and
            (self.custom_binding != null or execution_generation == self.projection.execution_generation);
    }

    pub fn executionInput(self: *const State) ?account.ExecutionConfigInput {
        if (!self.execution.ready()) return null;
        return .{
            .target = .{
                .provider_id = self.execution.providerId(),
                .protocol = self.execution.protocol.?,
                .provider_kind = self.execution.provider.?,
                .model = self.execution.model(),
                .base_url = self.execution.baseUrl(),
            },
            .api_key = self.execution.credential(),
            .execution_generation = self.execution.generation,
        };
    }

    pub fn admissionModel(self: *const State) []const u8 {
        return if (self.custom_binding != null)
            self.execution.model()
        else
            self.projection.selected_model.view();
    }

    pub fn credential(self: *const State) []const u8 {
        return self.execution.credential();
    }
    pub fn generation(self: *const State) u64 {
        return self.execution.generation;
    }
    pub fn catalogGeneration(self: *const State) u64 {
        return self.projection.catalog_generation;
    }
    pub fn provider(self: *const State) ?account.ProviderKind {
        return self.execution.provider;
    }
    pub fn model(self: *const State) []const u8 {
        return self.execution.model();
    }
    pub fn ready(self: *const State) bool {
        return self.execution.ready();
    }
    pub fn replacementPending(self: *const State) bool {
        return self.replacement != .none;
    }
    pub fn identityReplacementPending(self: *const State) bool {
        return self.replacement == .identity;
    }
    pub fn defaultReplacementPending(self: *const State) bool {
        return self.replacement == .default;
    }
    pub fn modelConnectionActive(self: *const State, connection_id: []const u8) bool {
        const binding = self.custom_binding orelse return false;
        return std.mem.eql(u8, binding.connection_id, connection_id);
    }
    pub fn modelConnectionSelected(self: *const State) bool {
        return self.custom_binding != null;
    }
};

pub const testing = if (builtin.is_test) struct {
    pub fn clearExecutionNoFail(state: *State) void {
        state.execution.clearNoFail();
    }

    pub fn setGenerationAlignment(state: *State, generation: u64) void {
        state.execution.generation = generation;
        state.projection.execution_generation = generation;
    }

    pub fn setCredentialBytes(state: *State, credential: []const u8) void {
        std.debug.assert(credential.len <= state.execution.credential_storage.len);
        std.crypto.secureZero(u8, state.execution.credential_storage);
        @memcpy(state.execution.credential_storage[0..credential.len], credential);
        state.execution.credential_len = credential.len;
    }

    pub fn installModelConnectionBinding(
        state: *State,
        binding: *PreparedModelConnectionBinding,
    ) void {
        std.debug.assert(state.custom_binding == null);
        state.custom_binding = binding.*;
        binding.* = undefined;
    }
} else struct {};

const TestDurableRedaction = struct {
    calls: *usize,

    fn apply(self: TestDurableRedaction, credential: []const u8) !void {
        _ = credential;
        self.calls.* += 1;
    }
};

const TestProjectionRedaction = struct {
    calls: usize = 0,

    fn capability(self: *TestProjectionRedaction) ProjectionRedaction {
        return .{
            .context = self,
            .apply_fn = apply,
        };
    }

    fn apply(context: *anyopaque, credential: []const u8) void {
        _ = credential;
        const self: *TestProjectionRedaction = @ptrCast(@alignCast(context));
        self.calls += 1;
    }
};

fn secureFreeTest(bytes: []u8) void {
    std.crypto.secureZero(u8, bytes);
    std.testing.allocator.free(bytes);
}

fn testExecution(
    provider: account.ProviderKind,
    model: []const u8,
    generation: u64,
    credential: []const u8,
) !account.OwnedExecutionConfig {
    const owned_model = try std.testing.allocator.dupe(u8, model);
    errdefer std.testing.allocator.free(owned_model);
    const owned_base_url = try std.testing.allocator.dupe(
        u8,
        account.metask_anthropic_messages_url,
    );
    errdefer std.testing.allocator.free(owned_base_url);
    const owned_credential = try std.testing.allocator.dupe(u8, credential);
    errdefer secureFreeTest(owned_credential);
    return account.OwnedExecutionConfig.initOwned(
        std.testing.allocator,
        provider,
        owned_model,
        owned_base_url,
        generation,
        owned_credential,
        "fixture-provider",
    ) catch unreachable;
}

fn testModelConnectionExecution() !account.OwnedExecutionConfig {
    const owned_model = try std.testing.allocator.dupe(u8, "gpt-5");
    errdefer std.testing.allocator.free(owned_model);
    const owned_base_url = try std.testing.allocator.dupe(
        u8,
        "https://api.openai.com/v1/chat/completions",
    );
    errdefer std.testing.allocator.free(owned_base_url);
    const owned_credential = try std.testing.allocator.dupe(u8, "SECRET-TWO");
    errdefer secureFreeTest(owned_credential);
    return account.OwnedExecutionConfig.initModelConnectionOwned(
        std.testing.allocator,
        .openai_chat_completions,
        owned_model,
        owned_base_url,
        3,
        owned_credential,
        "fixture-provider",
    ) catch unreachable;
}

test "Task model mutation requires the exact installed Metask authority" {
    var state = try State.init(std.testing.allocator);
    defer state.deinit();

    const api_keys = [_]account.ApiKeyView{.{
        .id = "key-1",
        .name = "Primary",
        .suffix = "1234",
        .provider_kind = .anthropic,
    }};
    const initial_models = [_]account.ModelView{
        .{ .id = "model-old", .display_name = "Old" },
        .{ .id = "model-next", .display_name = "Next" },
    };
    state.commitAccountFactNoFail(.{
        .kind = .execution_changed,
        .view = .{
            .state = .authenticated,
            .catalog_state = .ready,
            .account_id = "account-1",
            .display_name = "Metask User",
            .api_keys = &api_keys,
            .models = &initial_models,
            .selected_api_key_id = "key-1",
            .selected_model = "model-old",
            .model_catalog_api_key_id = "key-1",
            .can_create_task = true,
            .catalog_generation = 1,
            .metask_execution_generation = 1,
            .execution_generation = 1,
        },
    });
    var execution = try testExecution(.anthropic, "model-old", 1, "SECRET-ONE");
    var execution_owned = true;
    defer if (execution_owned) execution.deinit();
    try state.beginDefaultReplacement();
    var durable_calls: usize = 0;
    try state.prepareInstall(
        execution.input(),
        TestDurableRedaction{ .calls = &durable_calls },
    );
    var projection_redaction: TestProjectionRedaction = .{};
    state.installMetaskNoFail(&execution, projection_redaction.capability());
    execution_owned = false;
    state.endReplacementNoFail();
    try std.testing.expectEqual(@as(usize, 1), durable_calls);
    try std.testing.expectEqual(@as(usize, 2), projection_redaction.calls);

    const current_models = [_]account.ModelView{.{
        .id = "model-next",
        .display_name = "Next",
    }};
    state.commitAccountFactNoFail(.{
        .kind = .catalog_changed,
        .view = .{
            .state = .authenticated,
            .catalog_state = .ready,
            .account_id = "account-1",
            .display_name = "Metask User",
            .api_keys = &api_keys,
            .models = &current_models,
            .selected_api_key_id = "key-1",
            .selected_model = "model-next",
            .model_catalog_api_key_id = "key-1",
            .can_create_task = true,
            .catalog_generation = 2,
            .metask_execution_generation = 1,
            .execution_generation = 1,
        },
    });
    try std.testing.expect(state.taskModelSelectionAuthorized(
        .{ .generation = 1, .provider = .anthropic },
        2,
        "model-next",
    ));
    try std.testing.expect(!state.taskModelSelectionAuthorized(
        .{ .generation = 1, .provider = .anthropic },
        1,
        "model-next",
    ));
    try std.testing.expect(!state.taskModelSelectionAuthorized(
        .{ .generation = 2, .provider = .anthropic },
        2,
        "model-next",
    ));
    try std.testing.expect(!state.taskModelSelectionAuthorized(
        .{ .generation = 1, .provider = .openai },
        2,
        "model-next",
    ));
    try std.testing.expect(!state.taskModelSelectionAuthorized(
        .{ .generation = 1, .provider = .anthropic },
        2,
        "model-old",
    ));

    try state.beginDefaultReplacement();
    try std.testing.expect(!state.taskModelSelectionAuthorized(
        .{ .generation = 1, .provider = .anthropic },
        2,
        "model-next",
    ));
    state.endReplacementNoFail();
}

test "Model Connection execution never borrows Metask model authority" {
    var state = try State.init(std.testing.allocator);
    defer state.deinit();

    const api_keys = [_]account.ApiKeyView{.{
        .id = "key-1",
        .name = "Primary",
        .suffix = "1234",
        .provider_kind = .anthropic,
    }};
    const metask_models = [_]account.ModelView{.{
        .id = "gpt-5",
        .display_name = "GPT-5",
    }};
    state.commitAccountFactNoFail(.{
        .kind = .catalog_changed,
        .view = .{
            .state = .authenticated,
            .catalog_state = .ready,
            .account_id = "account-1",
            .display_name = "Metask User",
            .api_keys = &api_keys,
            .models = &metask_models,
            .selected_api_key_id = "key-1",
            .selected_model = "gpt-5",
            .model_catalog_api_key_id = "key-1",
            .can_create_task = true,
            .catalog_generation = 7,
            .metask_execution_generation = 3,
            .execution_generation = 3,
        },
    });
    var execution = try testModelConnectionExecution();
    var execution_owned = true;
    defer if (execution_owned) execution.deinit();
    var binding = try PreparedModelConnectionBinding.init(
        std.testing.allocator,
        "connection-1",
        "gpt-5",
    );
    var binding_owned = true;
    defer if (binding_owned) binding.deinit();
    var durable_calls: usize = 0;
    var projection_redaction: TestProjectionRedaction = .{};
    try state.beginDefaultReplacement();
    try state.prepareInstall(
        execution.input(),
        TestDurableRedaction{ .calls = &durable_calls },
    );
    state.installModelConnectionNoFail(
        &execution,
        &binding,
        projection_redaction.capability(),
    );
    execution_owned = false;
    binding_owned = false;
    state.endReplacementNoFail();

    try std.testing.expect(state.modelConnectionSelected());
    const resolved = state.executionInput().?;
    try std.testing.expectEqualStrings("model_connection:fixture-provider", resolved.target.provider_id);
    try std.testing.expectEqual(account.ModelConnectionProtocol.openai_chat_completions, resolved.target.protocol);
    try std.testing.expect(!state.taskModelSelectionAuthorized(
        .{ .generation = 3, .provider = .openai },
        7,
        "gpt-5",
    ));
}

test "Account projection commit and view allocate nothing after initialization" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var state = try State.init(failing.allocator());
    defer state.deinit();

    const connection_models = [_]account.ModelConnectionModelView{
        .{ .id = "model-00", .display_name = "Model 00" },
        .{ .id = "model-01", .display_name = "Model 01" },
        .{ .id = "model-02", .display_name = "Model 02" },
        .{ .id = "model-03", .display_name = "Model 03" },
        .{ .id = "model-04", .display_name = "Model 04" },
        .{ .id = "model-05", .display_name = "Model 05" },
        .{ .id = "model-06", .display_name = "Model 06" },
        .{ .id = "model-07", .display_name = "Model 07" },
        .{ .id = "model-08", .display_name = "Model 08" },
        .{ .id = "model-09", .display_name = "Model 09" },
        .{ .id = "model-10", .display_name = "Model 10" },
        .{ .id = "model-11", .display_name = "Model 11" },
        .{ .id = "model-12", .display_name = "Model 12" },
        .{ .id = "model-13", .display_name = "Model 13" },
        .{ .id = "model-14", .display_name = "Model 14" },
        .{ .id = "model-15", .display_name = "Model 15" },
    };
    var connection_id_storage: [account.Limits.model_connection_entries][32]u8 = undefined;
    var connections: [account.Limits.model_connection_entries]account.ModelConnectionView = undefined;
    for (&connections, 0..) |*connection, index| {
        const id = try std.fmt.bufPrint(&connection_id_storage[index], "connection-{d}", .{index});
        connection.* = .{
            .id = id,
            .display_name = id,
            .protocol = .openai_chat_completions,
            .normalized_base_url = "https://api.openai.com/v1/chat/completions",
            .state = .ready,
            .test_status = .connected,
            .credential_status = .ready,
            .enabled = true,
            .models = &connection_models,
            .selected_model = connection_models[0].id,
            .connection_generation = @intCast(index + 1),
        };
    }
    const fact: account.AccountFact = .{
        .kind = .model_connections_changed,
        .view = .{
            .state = .signed_out,
            .catalog_state = .unavailable,
            .model_connections = &connections,
        },
    };

    const allocations_after_init = failing.alloc_index;
    failing.fail_index = allocations_after_init;
    state.commitAccountFactNoFail(fact);
    const first = state.accountView(true);
    try account.validateView(first);
    try std.testing.expectEqual(account.Limits.model_connection_entries, first.model_connections.len);
    try std.testing.expectEqual(
        account.Limits.model_connection_model_entries,
        first.model_connections[first.model_connections.len - 1].models.len,
    );
    state.commitAccountFactNoFail(fact);
    _ = state.accountView(true);
    try std.testing.expectEqual(allocations_after_init, failing.alloc_index);
}
