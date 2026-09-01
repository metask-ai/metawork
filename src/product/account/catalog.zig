//! Product Account catalog policy.
const std = @import("std");
const builtin = @import("builtin");
const contract = @import("metawork_account_contract");
const metask = @import("metask_client");

pub const api_keys_url = metask.api_keys_url;
pub const models_url = metask.models_url;
pub const anthropic_messages_url =
    contract.metask_anthropic_messages_url;
pub const openai_chat_completions_url =
    contract.metask_openai_chat_completions_url;
pub const gemini_base_url = contract.metask_gemini_base_url;

pub const Limits = struct {
    pub const response_bytes: usize = 4 * 1024 * 1024;
    pub const json_scratch_bytes: usize = 8 * 1024 * 1024;
    pub const api_key_suffix_bytes: usize = 4;
};

pub const Error = error{
    Unauthorized,
    RateLimited,
    ServiceUnavailable,
    Cancelled,
    DeadlineExceeded,
    ProtocolInvalid,
    CatalogTooLarge,
    CatalogFieldTooLarge,
    NoApiKeys,
    NoModels,
    ApiKeyNotFound,
    ModelNotFound,
    UnsupportedProvider,
    ExecutionTargetInvalid,
    OutOfMemory,
};

pub fn errorCode(err: Error) contract.ErrorCode {
    return switch (err) {
        error.Unauthorized => .metask_unauthorized,
        error.RateLimited => .metask_rate_limited,
        error.ServiceUnavailable => .metask_service_unavailable,
        error.Cancelled => .user_cancelled,
        error.DeadlineExceeded => .deadline_exceeded,
        error.ProtocolInvalid => .metask_protocol_invalid,
        error.CatalogTooLarge => .catalog_too_large,
        error.CatalogFieldTooLarge => .catalog_field_too_large,
        error.NoApiKeys => .no_api_keys,
        error.NoModels => .no_models,
        error.ApiKeyNotFound, error.ModelNotFound => .invalid_command,
        error.UnsupportedProvider,
        error.ExecutionTargetInvalid,
        => .execution_target_invalid,
        error.OutOfMemory => .local_resource_exhausted,
    };
}

fn BoundedString(comptime capacity: usize) type {
    return struct {
        bytes: [capacity]u8 = undefined,
        len: usize = 0,

        const Self = @This();

        fn init(value: []const u8) Error!Self {
            var result: Self = .{};
            if (value.len == 0) return error.ProtocolInvalid;
            if (value.len > capacity) return error.CatalogFieldTooLarge;
            if (!std.unicode.utf8ValidateSlice(value))
                return error.ProtocolInvalid;
            @memcpy(result.bytes[0..value.len], value);
            result.len = value.len;
            return result;
        }

        fn optional(value: []const u8) Error!Self {
            if (value.len == 0) return .{};
            return init(value);
        }

        fn view(self: *const Self) []const u8 {
            return self.bytes[0..self.len];
        }
    };
}

const ApiKeyId = BoundedString(contract.Limits.api_key_id_bytes);
const AccountId = BoundedString(contract.Limits.account_id_bytes);
const ApiKeyName = BoundedString(contract.Limits.api_key_name_bytes);
const ApiKeySuffix = BoundedString(contract.Limits.api_key_suffix_bytes);
const ModelId = BoundedString(contract.Limits.model_id_bytes);
const ModelDisplayName =
    BoundedString(contract.Limits.model_display_name_bytes);

const Secret = struct {
    allocator: std.mem.Allocator = undefined,
    bytes: []u8 = &.{},
    owned: bool = false,

    fn init(
        allocator: std.mem.Allocator,
        value: []const u8,
    ) Error!Secret {
        if (!validHeaderCredential(value))
            return error.ProtocolInvalid;
        if (value.len > contract.Limits.api_key_bytes)
            return error.CatalogFieldTooLarge;
        return .{
            .allocator = allocator,
            .bytes = allocator.dupe(u8, value) catch return error.OutOfMemory,
            .owned = true,
        };
    }

    fn view(self: *const Secret) []const u8 {
        if (!self.owned) return "";
        return self.bytes;
    }

    fn takeBytes(self: *Secret) []u8 {
        std.debug.assert(self.owned);
        const bytes = self.bytes;
        self.* = .{};
        return bytes;
    }

    fn deinit(self: *Secret) void {
        if (!self.owned) return;
        secureFree(self.allocator, self.bytes);
        self.* = .{};
    }
};

const ApiKeyEntry = struct {
    id: ApiKeyId,
    name: ApiKeyName,
    suffix: ApiKeySuffix,
    protocol: contract.Protocol,
    secret: Secret,

    fn deinit(self: *ApiKeyEntry) void {
        self.secret.deinit();
        self.* = undefined;
    }
};

const ModelEntry = struct {
    id: ModelId,
    display_name: ModelDisplayName,
    metadata: contract.ModelMetadata = .{},
};

pub const CatalogSession = struct {
    allocator: std.mem.Allocator,
    api_keys: std.ArrayList(ApiKeyEntry) = .empty,
    models: std.ArrayList(ModelEntry) = .empty,
    selected_key_index: ?usize = null,
    owner_account_id: AccountId = .{},
    /// HTTP status of the most recent catalog request, 0 before any request
    /// or after a transport-level failure. Owned by the single in-flight
    /// worker; read by the same worker to build the failure diagnostic.
    last_http_status: u16 = 0,

    pub fn init(allocator: std.mem.Allocator) CatalogSession {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *CatalogSession) void {
        self.clearApiKeys();
        self.api_keys.deinit(self.allocator);
        self.models.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn reset(self: *CatalogSession) void {
        self.clearApiKeys();
    }

    pub fn loadApiKeys(
        self: *CatalogSession,
        transport: metask.Transport,
        oauth_access_token: []const u8,
        account_id: []const u8,
        control: ?metask.RequestControl,
    ) Error!void {
        const validated_account_id = try AccountId.init(account_id);
        self.last_http_status = 0;
        var replacement = try fetchApiKeys(
            self.allocator,
            transport,
            oauth_access_token,
            control,
            &self.last_http_status,
        );
        errdefer replacement.deinit();
        self.clearApiKeys();
        self.api_keys.deinit(self.allocator);
        self.api_keys = replacement.entries;
        replacement.entries = .empty;
        self.selected_key_index = null;
        self.owner_account_id = validated_account_id;
    }

    pub fn selectApiKey(
        self: *CatalogSession,
        id: []const u8,
    ) Error!void {
        const index = self.findApiKey(id) orelse
            return error.ApiKeyNotFound;
        if (self.api_keys.items[index].secret.view().len == 0)
            return error.ApiKeyNotFound;
        self.models.clearRetainingCapacity();
        self.selected_key_index = index;
    }

    pub fn loadModels(
        self: *CatalogSession,
        transport: metask.Transport,
        control: ?metask.RequestControl,
    ) Error!void {
        const index = self.selected_key_index orelse
            return error.ApiKeyNotFound;
        try self.loadModelsForApiKeyIndex(index, transport, control);
    }

    pub fn loadModelsForApiKey(
        self: *CatalogSession,
        id: []const u8,
        transport: metask.Transport,
        control: ?metask.RequestControl,
    ) Error!void {
        const index = self.findApiKey(id) orelse
            return error.ApiKeyNotFound;
        try self.loadModelsForApiKeyIndex(index, transport, control);
    }

    fn loadModelsForApiKeyIndex(
        self: *CatalogSession,
        index: usize,
        transport: metask.Transport,
        control: ?metask.RequestControl,
    ) Error!void {
        const credential = self.api_keys.items[index].secret.view();
        if (credential.len == 0) return error.ApiKeyNotFound;
        self.last_http_status = 0;
        var replacement = try fetchModels(
            self.allocator,
            transport,
            credential,
            control,
            &self.last_http_status,
        );
        errdefer replacement.deinit();
        self.models.deinit(self.allocator);
        self.models = replacement.entries;
        replacement.entries = .empty;
        self.selected_key_index = index;
    }

    pub fn prepareExecution(
        self: *CatalogSession,
        model_id: []const u8,
        execution_generation: u64,
    ) Error!contract.OwnedExecutionConfig {
        if (execution_generation == 0)
            return error.ExecutionTargetInvalid;
        const key_index = self.selected_key_index orelse
            return error.ApiKeyNotFound;
        if (self.findModel(model_id) == null)
            return error.ModelNotFound;
        const entry = &self.api_keys.items[key_index];
        const base_url = baseUrl(entry.protocol) orelse
            return error.UnsupportedProvider;
        if (entry.secret.view().len == 0)
            return error.ApiKeyNotFound;

        var owned_model: ?[]u8 = self.allocator.dupe(
            u8,
            model_id,
        ) catch return error.OutOfMemory;
        errdefer if (owned_model) |bytes| self.allocator.free(bytes);
        var owned_base_url: ?[]u8 = self.allocator.dupe(
            u8,
            base_url,
        ) catch return error.OutOfMemory;
        errdefer if (owned_base_url) |bytes| self.allocator.free(bytes);
        const owned_secret = entry.secret.takeBytes();
        const transferred_model = owned_model.?;
        const transferred_base_url = owned_base_url.?;
        owned_model = null;
        owned_base_url = null;
        return contract.OwnedExecutionConfig.initOwned(
            self.allocator,
            entry.protocol,
            transferred_model,
            transferred_base_url,
            execution_generation,
            owned_secret,
            entry.id.view(),
        ) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.ExecutionTargetInvalid;
    }

    pub fn writeApiKeyViews(
        self: *const CatalogSession,
        output: []contract.ApiKeyView,
    ) []const contract.ApiKeyView {
        std.debug.assert(output.len >= self.api_keys.items.len);
        for (self.api_keys.items, output[0..self.api_keys.items.len]) |
            *entry,
            *view,
        | {
            view.* = .{
                .id = entry.id.view(),
                .name = entry.name.view(),
                .suffix = entry.suffix.view(),
                .protocol = entry.protocol,
            };
        }
        return output[0..self.api_keys.items.len];
    }

    pub fn writeModelViews(
        self: *const CatalogSession,
        output: []contract.ModelView,
    ) []const contract.ModelView {
        std.debug.assert(output.len >= self.models.items.len);
        for (self.models.items, output[0..self.models.items.len]) |
            *entry,
            *view,
        | {
            view.* = .{
                .id = entry.id.view(),
                .display_name = entry.display_name.view(),
                .metadata = entry.metadata,
            };
        }
        return output[0..self.models.items.len];
    }

    pub fn selectedApiKeyId(
        self: *const CatalogSession,
    ) []const u8 {
        const index = self.selected_key_index orelse return "";
        return self.api_keys.items[index].id.view();
    }

    pub fn ownsExecutionSelection(
        self: *const CatalogSession,
        account_id: []const u8,
        api_key_id: []const u8,
        model_id: []const u8,
    ) bool {
        if (!std.mem.eql(u8, self.ownerAccountId(), account_id) or
            !std.mem.eql(u8, self.selectedApiKeyId(), api_key_id) or
            self.findModel(model_id) == null)
            return false;
        const index = self.selected_key_index orelse return false;
        return self.api_keys.items[index].secret.view().len > 0;
    }

    /// Default candidate for automatic continuation: the catalog's first
    /// entry. Selection stays overridable in settings afterwards.
    pub fn firstApiKeyId(self: *const CatalogSession) ?[]const u8 {
        if (self.api_keys.items.len == 0) return null;
        return self.api_keys.items[0].id.view();
    }

    pub fn firstModelId(self: *const CatalogSession) ?[]const u8 {
        if (self.models.items.len == 0) return null;
        return self.models.items[0].id.view();
    }

    pub fn hasApiKey(self: *const CatalogSession, id: []const u8) bool {
        return self.findApiKey(id) != null;
    }

    pub fn hasModel(self: *const CatalogSession, id: []const u8) bool {
        return self.findModel(id) != null;
    }

    pub fn ownerAccountId(self: *const CatalogSession) []const u8 {
        return self.owner_account_id.view();
    }

    fn findApiKey(self: *const CatalogSession, id: []const u8) ?usize {
        for (self.api_keys.items, 0..) |*entry, index| {
            if (std.mem.eql(u8, entry.id.view(), id)) return index;
        }
        return null;
    }

    fn findModel(self: *const CatalogSession, id: []const u8) ?usize {
        for (self.models.items, 0..) |*entry, index| {
            if (std.mem.eql(u8, entry.id.view(), id)) return index;
        }
        return null;
    }

    fn clearApiKeys(self: *CatalogSession) void {
        for (self.api_keys.items) |*entry| entry.deinit();
        self.api_keys.clearRetainingCapacity();
        self.models.clearRetainingCapacity();
        self.selected_key_index = null;
        self.owner_account_id = .{};
    }
};

fn PublicText(comptime capacity: usize) type {
    return struct {
        bytes: [capacity]u8 = undefined,
        len: usize = 0,

        fn set(self: *@This(), value: []const u8) void {
            std.debug.assert(value.len <= capacity);
            @memcpy(self.bytes[0..value.len], value);
            self.len = value.len;
        }

        fn view(self: *const @This()) []const u8 {
            return self.bytes[0..self.len];
        }
    };
}

const PublicApiKey = struct {
    id: PublicText(contract.Limits.api_key_id_bytes) = .{},
    name: PublicText(contract.Limits.api_key_name_bytes) = .{},
    suffix: PublicText(contract.Limits.api_key_suffix_bytes) = .{},
    protocol: contract.Protocol = .anthropic_messages,
};

const PublicModel = struct {
    id: PublicText(contract.Limits.model_id_bytes) = .{},
    display_name: PublicText(contract.Limits.model_display_name_bytes) = .{},
    metadata: contract.ModelMetadata = .{},
};

/// Secret-free, fixed-capacity Account projection. Network workers mutate the
/// private candidate CatalogSession, then the App main thread snapshots a
/// successful stage here. The composition root keeps committed and candidate
/// PublicCatalog slots separate until execution persistence succeeds. Other
/// state changes read only those secret-free caches, so cancel and shutdown
/// never race worker-owned secrets.
pub const PublicCatalog = struct {
    api_keys: [contract.Limits.api_key_entries]PublicApiKey =
        @splat(.{}),
    api_key_views: [contract.Limits.api_key_entries]contract.ApiKeyView =
        undefined,
    api_key_count: usize = 0,
    models: [contract.Limits.model_entries]PublicModel = @splat(.{}),
    model_views: [contract.Limits.model_entries]contract.ModelView =
        undefined,
    model_count: usize = 0,

    pub fn replaceFromSession(
        self: *PublicCatalog,
        session: *const CatalogSession,
    ) void {
        var api_key_views: [contract.Limits.api_key_entries]contract.ApiKeyView =
            undefined;
        const source_api_keys = session.writeApiKeyViews(&api_key_views);
        std.debug.assert(source_api_keys.len <= self.api_keys.len);
        self.api_key_count = source_api_keys.len;
        for (
            source_api_keys,
            self.api_keys[0..source_api_keys.len],
        ) |source, *storage| {
            storage.id.set(source.id);
            storage.name.set(source.name);
            storage.suffix.set(source.suffix);
            storage.protocol = source.protocol;
        }

        var model_views: [contract.Limits.model_entries]contract.ModelView =
            undefined;
        const source_models = session.writeModelViews(&model_views);
        std.debug.assert(source_models.len <= self.models.len);
        self.model_count = source_models.len;
        for (
            source_models,
            self.models[0..source_models.len],
        ) |source, *storage| {
            storage.id.set(source.id);
            storage.display_name.set(source.display_name);
            storage.metadata = source.metadata;
        }
    }

    pub fn replaceFromPublic(
        self: *PublicCatalog,
        source: *const PublicCatalog,
    ) void {
        for (source.api_keys[0..source.api_key_count], 0..) |key, index|
            self.api_keys[index] = key;
        for (source.models[0..source.model_count], 0..) |model, index|
            self.models[index] = model;
        self.api_key_count = source.api_key_count;
        self.model_count = source.model_count;
    }

    /// Restored execution persistence contains the selected catalog identities
    /// but no complete Metask catalog. Publish the smallest truthful catalog
    /// until the authenticated catalog refresh replaces it. This keeps a ready
    /// AccountView internally consistent without inventing display metadata.
    pub fn replaceRestoredSelection(
        self: *PublicCatalog,
        api_key_id: []const u8,
        protocol: contract.Protocol,
        model_id: []const u8,
    ) void {
        std.debug.assert(api_key_id.len > 0);
        std.debug.assert(model_id.len > 0);
        self.api_key_count = 1;
        self.api_keys[0].id.set(api_key_id);
        self.api_keys[0].name.set("");
        self.api_keys[0].suffix.set("");
        self.api_keys[0].protocol = protocol;
        self.model_count = 1;
        self.models[0].id.set(model_id);
        self.models[0].display_name.set("");
        self.models[0].metadata = .{};
    }

    pub fn clear(self: *PublicCatalog) void {
        self.api_key_count = 0;
        self.model_count = 0;
    }

    pub fn hasApiKey(self: *const PublicCatalog, id: []const u8) bool {
        for (self.api_keys[0..self.api_key_count]) |*entry|
            if (std.mem.eql(u8, entry.id.view(), id)) return true;
        return false;
    }

    pub fn hasModel(self: *const PublicCatalog, id: []const u8) bool {
        for (self.models[0..self.model_count]) |*entry|
            if (std.mem.eql(u8, entry.id.view(), id)) return true;
        return false;
    }

    pub fn decorate(
        self: *PublicCatalog,
        view: *contract.AccountView,
    ) void {
        for (
            self.api_keys[0..self.api_key_count],
            self.api_key_views[0..self.api_key_count],
        ) |*storage, *api_key_view| {
            api_key_view.* = .{
                .id = storage.id.view(),
                .name = storage.name.view(),
                .suffix = storage.suffix.view(),
                .protocol = storage.protocol,
            };
        }
        for (
            self.models[0..self.model_count],
            self.model_views[0..self.model_count],
        ) |*storage, *model_view| {
            model_view.* = .{
                .id = storage.id.view(),
                .display_name = storage.display_name.view(),
                .metadata = storage.metadata,
            };
        }
        view.api_keys = self.api_key_views[0..self.api_key_count];
        view.models = self.model_views[0..self.model_count];
    }
};

pub const TestSupport = if (builtin.is_test) struct {
    pub fn replaceOwnedSelection(
        session: *CatalogSession,
        account_id: []const u8,
        api_key: contract.ApiKeyView,
        secret_value: []const u8,
        models: []const contract.ModelView,
    ) Error!void {
        session.reset();
        session.owner_account_id = try .init(account_id);
        var secret = try Secret.init(session.allocator, secret_value);
        errdefer secret.deinit();
        session.api_keys.append(session.allocator, .{
            .id = try .init(api_key.id),
            .name = try .init(api_key.name),
            .suffix = try .init(api_key.suffix),
            .protocol = api_key.protocol,
            .secret = secret,
        }) catch return error.OutOfMemory;
        secret = .{};
        session.selected_key_index = 0;
        for (models) |model| {
            session.models.append(session.allocator, .{
                .id = try .init(model.id),
                .display_name = try .optional(model.display_name),
                .metadata = model.metadata,
            }) catch return error.OutOfMemory;
        }
    }

    pub fn appendOwnedApiKey(
        session: *CatalogSession,
        api_key: contract.ApiKeyView,
        secret_value: []const u8,
    ) Error!void {
        var secret = try Secret.init(session.allocator, secret_value);
        errdefer secret.deinit();
        session.api_keys.append(session.allocator, .{
            .id = try .init(api_key.id),
            .name = try .init(api_key.name),
            .suffix = try .init(api_key.suffix),
            .protocol = api_key.protocol,
            .secret = secret,
        }) catch return error.OutOfMemory;
        secret = .{};
    }

    pub fn replacePublic(
        catalog: *PublicCatalog,
        api_keys: []const contract.ApiKeyView,
        models: []const contract.ModelView,
    ) void {
        std.debug.assert(api_keys.len <= catalog.api_keys.len);
        std.debug.assert(models.len <= catalog.models.len);
        catalog.api_key_count = api_keys.len;
        for (api_keys, catalog.api_keys[0..api_keys.len]) |source, *target| {
            target.id.set(source.id);
            target.name.set(source.name);
            target.suffix.set(source.suffix);
            target.protocol = source.protocol;
        }
        catalog.model_count = models.len;
        for (models, catalog.models[0..models.len]) |source, *target| {
            target.id.set(source.id);
            target.display_name.set(source.display_name);
            target.metadata = source.metadata;
        }
    }
} else struct {};

const ParsedApiKeys = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(ApiKeyEntry) = .empty,

    fn deinit(self: *ParsedApiKeys) void {
        for (self.entries.items) |*entry| entry.deinit();
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }
};

const ParsedModels = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(ModelEntry) = .empty,

    fn deinit(self: *ParsedModels) void {
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }
};

fn fetchApiKeys(
    allocator: std.mem.Allocator,
    transport: metask.Transport,
    oauth_access_token: []const u8,
    control: ?metask.RequestControl,
    status_out: *u16,
) Error!ParsedApiKeys {
    const response_buffer = allocator.alloc(
        u8,
        Limits.response_bytes,
    ) catch return error.OutOfMemory;
    defer {
        std.crypto.secureZero(u8, response_buffer);
        allocator.free(response_buffer);
    }
    const response = transport.perform(.{
        .kind = .keys,
        .bearer = oauth_access_token,
        .control = control,
    }, response_buffer) catch |err| return transportError(err);
    status_out.* = response.status;
    try requireSuccess(response.status);
    return parseApiKeys(allocator, response.body);
}

fn fetchModels(
    allocator: std.mem.Allocator,
    transport: metask.Transport,
    api_key: []const u8,
    control: ?metask.RequestControl,
    status_out: *u16,
) Error!ParsedModels {
    const response_buffer = allocator.alloc(
        u8,
        Limits.response_bytes,
    ) catch return error.OutOfMemory;
    defer {
        std.crypto.secureZero(u8, response_buffer);
        allocator.free(response_buffer);
    }
    const response = transport.perform(.{
        .kind = .models,
        .bearer = api_key,
        .control = control,
    }, response_buffer) catch |err| return transportError(err);
    status_out.* = response.status;
    try requireSuccess(response.status);
    return parseModels(allocator, response.body);
}

const ApiKeysResponse = struct {
    code: i64,
    message: []const u8,
    data: struct {
        items: []const ApiKeyWire,
        total: usize,
        page: usize,
        page_size: usize,
        pages: usize,
    },
};

const ApiKeyWire = struct {
    id: u64,
    key: []const u8,
    name: []const u8,
    group_id: u64,
    status: []const u8,
    group: GroupWire,
};

const GroupWire = struct {
    id: u64,
    platform: []const u8,
    status: []const u8,
};

const ModelsResponse = struct {
    object: []const u8,
    data: []const ModelWire,
    has_more: bool,
};

const ModelWire = struct {
    id: []const u8,
    object: []const u8,
    type: []const u8,
    display_name: ?[]const u8 = null,
    max_input_tokens: std.json.Value = .null,
    max_tokens: std.json.Value = .null,
    capabilities: ?ModelCapabilitiesWire = null,
};

const CapabilityWire = struct { supported: ?bool = null };

const ModelCapabilitiesWire = struct {
    image_input: ?CapabilityWire = null,
    pdf_input: ?CapabilityWire = null,
    batch: ?CapabilityWire = null,
    citations: ?CapabilityWire = null,
    code_execution: ?CapabilityWire = null,
    structured_outputs: ?CapabilityWire = null,
    thinking: ?struct {
        supported: ?bool = null,
        types: ?struct {
            adaptive: ?CapabilityWire = null,
            enabled: ?CapabilityWire = null,
        } = null,
    } = null,
    effort: ?struct {
        supported: ?bool = null,
        low: ?CapabilityWire = null,
        medium: ?CapabilityWire = null,
        high: ?CapabilityWire = null,
        max: ?CapabilityWire = null,
    } = null,
    context_management: ?struct {
        supported: ?bool = null,
        clear_thinking_20251015: ?CapabilityWire = null,
        clear_tool_uses_20250919: ?CapabilityWire = null,
        compact_20260112: ?CapabilityWire = null,
    } = null,

    fn projection(self: ModelCapabilitiesWire) contract.ModelCapabilities {
        var result: contract.ModelCapabilities = .{
            .image_input = supported(self.image_input),
            .pdf_input = supported(self.pdf_input),
            .batch = supported(self.batch),
            .citations = supported(self.citations),
            .code_execution = supported(self.code_execution),
            .structured_outputs = supported(self.structured_outputs),
        };
        if (self.thinking) |thinking| {
            result.thinking.supported = thinking.supported;
            if (thinking.types) |types| {
                result.thinking.adaptive = supported(types.adaptive);
                result.thinking.enabled = supported(types.enabled);
            }
        }
        if (self.effort) |effort| result.effort = .{
            .supported = effort.supported,
            .low = supported(effort.low),
            .medium = supported(effort.medium),
            .high = supported(effort.high),
            .max = supported(effort.max),
        };
        if (self.context_management) |context| result.context_management = .{
            .supported = context.supported,
            .clear_thinking_20251015 = supported(context.clear_thinking_20251015),
            .clear_tool_uses_20250919 = supported(context.clear_tool_uses_20250919),
            .compact_20260112 = supported(context.compact_20260112),
        };
        return result;
    }
};

fn supported(capability: ?CapabilityWire) ?bool {
    return if (capability) |value| value.supported else null;
}

fn tokenLimit(value: std.json.Value) Error!?u64 {
    const number = switch (value) {
        .null => return null,
        .number_string => |text| blk: {
            for (text) |byte| if (!std.ascii.isDigit(byte)) return error.ProtocolInvalid;
            break :blk std.fmt.parseInt(u64, text, 10) catch return error.ProtocolInvalid;
        },
        else => return error.ProtocolInvalid,
    };
    return if (number == 0) null else number;
}

fn parseApiKeys(
    allocator: std.mem.Allocator,
    body: []const u8,
) Error!ParsedApiKeys {
    if (body.len == 0 or body.len > Limits.response_bytes)
        return error.CatalogTooLarge;
    const scratch = allocator.alloc(
        u8,
        jsonScratchSize(body.len),
    ) catch return error.OutOfMemory;
    defer {
        std.crypto.secureZero(u8, scratch);
        allocator.free(scratch);
    }
    var fba = std.heap.FixedBufferAllocator.init(scratch);
    const response = std.json.parseFromSliceLeaky(
        ApiKeysResponse,
        fba.allocator(),
        body,
        .{
            .ignore_unknown_fields = true,
            .max_value_len = contract.Limits.api_key_bytes,
            .allocate = .alloc_if_needed,
        },
    ) catch |err| return parseError(err);
    if (response.code != 0 or
        !std.mem.eql(u8, response.message, "success") or
        response.data.page != 1 or
        response.data.page_size != 100 or
        response.data.pages != 1 or
        response.data.total != response.data.items.len)
        return error.ProtocolInvalid;
    if (response.data.items.len > contract.Limits.api_key_entries)
        return error.CatalogTooLarge;

    var result: ParsedApiKeys = .{ .allocator = allocator };
    errdefer result.deinit();
    for (response.data.items) |item| {
        if (!std.mem.eql(u8, item.status, "active") or
            !std.mem.eql(u8, item.group.status, "active"))
            continue;
        if (item.group_id != item.group.id)
            return error.ProtocolInvalid;
        const protocol = protocolForPlatform(item.group.platform) orelse
            return error.UnsupportedProvider;
        var id_storage: [contract.Limits.api_key_id_bytes]u8 = undefined;
        const id = std.fmt.bufPrint(&id_storage, "{d}", .{item.id}) catch
            return error.CatalogFieldTooLarge;
        for (result.entries.items) |*existing| {
            if (std.mem.eql(u8, existing.id.view(), id))
                return error.ProtocolInvalid;
        }
        if (item.key.len < Limits.api_key_suffix_bytes * 2)
            return error.ProtocolInvalid;
        var entry: ApiKeyEntry = .{
            .id = try .init(id),
            .name = try .optional(item.name),
            .suffix = try .init(
                item.key[item.key.len - Limits.api_key_suffix_bytes ..],
            ),
            .protocol = protocol,
            .secret = try .init(allocator, item.key),
        };
        errdefer entry.deinit();
        result.entries.append(allocator, entry) catch
            return error.OutOfMemory;
    }
    if (result.entries.items.len == 0) return error.NoApiKeys;
    return result;
}

fn parseModels(
    allocator: std.mem.Allocator,
    body: []const u8,
) Error!ParsedModels {
    if (body.len == 0 or body.len > Limits.response_bytes)
        return error.CatalogTooLarge;
    const scratch = allocator.alloc(
        u8,
        jsonScratchSize(body.len),
    ) catch return error.OutOfMemory;
    defer {
        std.crypto.secureZero(u8, scratch);
        allocator.free(scratch);
    }
    var fba = std.heap.FixedBufferAllocator.init(scratch);
    const response = std.json.parseFromSliceLeaky(
        ModelsResponse,
        fba.allocator(),
        body,
        .{
            .ignore_unknown_fields = true,
            .parse_numbers = false,
            .max_value_len = contract.Limits.model_display_name_bytes,
            .allocate = .alloc_if_needed,
        },
    ) catch |err| return parseError(err);
    if (!std.mem.eql(u8, response.object, "list") or
        response.has_more)
        return error.ProtocolInvalid;
    if (response.data.len > contract.Limits.model_entries)
        return error.CatalogTooLarge;

    var result: ParsedModels = .{ .allocator = allocator };
    errdefer result.deinit();
    for (response.data) |model| {
        if (!std.mem.eql(u8, model.object, "model") or
            !std.mem.eql(u8, model.type, "model"))
            return error.ProtocolInvalid;
        const id = try ModelId.init(model.id);
        for (result.entries.items) |*existing| {
            if (std.mem.eql(u8, existing.id.view(), id.view()))
                return error.ProtocolInvalid;
        }
        result.entries.append(allocator, .{
            .id = id,
            .display_name = try .optional(model.display_name orelse ""),
            .metadata = .{
                .max_input_tokens = try tokenLimit(model.max_input_tokens),
                .max_output_tokens = try tokenLimit(model.max_tokens),
                .capabilities = if (model.capabilities) |value| value.projection() else .{},
            },
        }) catch return error.OutOfMemory;
    }
    if (result.entries.items.len == 0) return error.NoModels;
    return result;
}

fn protocolForPlatform(platform: []const u8) ?contract.Protocol {
    if (std.mem.eql(u8, platform, "anthropic")) return .anthropic_messages;
    if (std.mem.eql(u8, platform, "openai")) return .openai_chat_completions;
    if (std.mem.eql(u8, platform, "gemini")) return .gemini_native;
    return null;
}

fn jsonScratchSize(body_len: usize) usize {
    const minimum = 64 * 1024;
    return @min(
        Limits.json_scratch_bytes,
        @max(minimum, body_len * 4),
    );
}

fn baseUrl(protocol: contract.Protocol) ?[]const u8 {
    return switch (protocol) {
        .openai_responses => null,
        .anthropic_messages => anthropic_messages_url,
        .openai_chat_completions => openai_chat_completions_url,
        .gemini_native => gemini_base_url,
    };
}

fn validHeaderCredential(value: []const u8) bool {
    if (value.len == 0 or
        value.len > contract.Limits.api_key_bytes)
        return false;
    for (value) |byte| {
        if (byte < 0x21 or byte > 0x7e) return false;
    }
    return true;
}

fn requireSuccess(status: u16) Error!void {
    return switch (status) {
        200 => {},
        401, 403 => error.Unauthorized,
        429 => error.RateLimited,
        500...599 => error.ServiceUnavailable,
        else => error.ProtocolInvalid,
    };
}

fn transportError(err: metask.TransportError) Error {
    return switch (err) {
        error.NetworkFailed => error.ServiceUnavailable,
        error.ResponseTooLarge => error.CatalogTooLarge,
        error.ProtocolFailed => error.ProtocolInvalid,
        error.Cancelled => error.Cancelled,
        error.DeadlineExceeded => error.DeadlineExceeded,
    };
}

fn parseError(err: anyerror) Error {
    return switch (err) {
        error.ValueTooLong => error.CatalogFieldTooLarge,
        error.OutOfMemory => error.CatalogTooLarge,
        else => error.ProtocolInvalid,
    };
}

fn secureFree(allocator: std.mem.Allocator, bytes: []u8) void {
    if (bytes.len == 0) return;
    std.crypto.secureZero(u8, bytes);
    allocator.rawFree(bytes, .of(u8), @returnAddress());
}

const key_fixture =
    \\{"code":0,"message":"success","data":{"items":[{
    \\"id":325,"user_id":7,"key":"test-api-key-1234","name":"Prod",
    \\"group_id":11,"status":"active","ip_whitelist":null,
    \\"ip_blacklist":null,"last_used_at":"2026-07-20T00:00:00Z",
    \\"quota":100,"quota_used":1,"expires_at":null,
    \\"created_at":"2026-07-19T00:00:00Z",
    \\"updated_at":"2026-07-20T00:00:00Z",
    \\"rate_limit_5h":100,"rate_limit_1d":200,"rate_limit_7d":300,
    \\"usage_5h":1,"usage_1d":2,"usage_7d":3,
    \\"window_5h_start":null,"window_1d_start":null,
    \\"window_7d_start":null,"group":{"id":11,"name":"Group",
    \\"description":"","platform":"anthropic","rate_multiplier":1,
    \\"visibility":"public","is_exclusive":false,"status":"active",
    \\"image_price_1k":null,"image_price_2k":null,
    \\"image_price_4k":null,"sora_image_price_360":null,
    \\"sora_image_price_540":null,
    \\"sora_video_price_per_request":null,
    \\"sora_video_price_per_request_hd":null,
    \\"claude_code_only":false,"fallback_group_id":null,
    \\"fallback_group_id_on_invalid_request":null,
    \\"sora_storage_quota_bytes":0,"allow_messages_dispatch":false,
    \\"created_at":"2026-07-19T00:00:00Z",
    \\"updated_at":"2026-07-20T00:00:00Z"}}],
    \\"total":1,"page":1,"page_size":100,"pages":1}}
;

const model_fixture =
    \\{"object":"list","data":[{"id":"model-1","object":"model",
    \\"created":1,"owned_by":"Metask","type":"model",
    \\"display_name":"Model 1","created_at":"2026-07-20T00:00:00Z",
    \\"max_input_tokens":0,"max_tokens":0}],
    \\"first_id":"model-1","last_id":"model-1","has_more":false,
    \\"remaining":0,"unit":"model"}
;

const declared_model_fixture =
    \\{"object":"list","has_more":false,"data":[{
    \\"id":"model-1","object":"model","type":"model","display_name":"Model 1",
    \\"max_input_tokens":1048576,"max_tokens":64000,"capabilities":{
    \\"image_input":{"supported":false},"pdf_input":{"supported":false},
    \\"batch":{"supported":false},"citations":{"supported":false},
    \\"code_execution":{"supported":false},"structured_outputs":{"supported":true},
    \\"thinking":{"supported":true,"types":{"adaptive":{"supported":false},"enabled":{"supported":true}}},
    \\"effort":{"supported":false,"low":{"supported":false},"medium":{"supported":false},"high":{"supported":false},"max":{"supported":false}},
    \\"context_management":{"supported":true,"clear_thinking_20251015":{"supported":false},"clear_tool_uses_20250919":{"supported":false},"compact_20260112":{"supported":true}},
    \\"future_capability":{"supported":true}}}]}
;

test "model declarations survive owned catalog copies and never leak into a replacement" {
    const expected: contract.ModelMetadata = .{
        .max_input_tokens = 1048576,
        .max_output_tokens = 64000,
        .capabilities = .{
            .image_input = false,
            .pdf_input = false,
            .batch = false,
            .citations = false,
            .code_execution = false,
            .structured_outputs = true,
            .thinking = .{ .supported = true, .adaptive = false, .enabled = true },
            .effort = .{ .supported = false, .low = false, .medium = false, .high = false, .max = false },
            .context_management = .{
                .supported = true,
                .clear_thinking_20251015 = false,
                .clear_tool_uses_20250919 = false,
                .compact_20260112 = true,
            },
        },
    };
    var session = CatalogSession.init(std.testing.allocator);
    defer session.deinit();
    var parsed = try parseModels(std.testing.allocator, declared_model_fixture);
    session.models = parsed.entries;
    parsed.entries = .empty;
    var views: [contract.Limits.model_entries]contract.ModelView = undefined;
    try std.testing.expectEqualDeep(expected, session.writeModelViews(&views)[0].metadata);

    var candidate: PublicCatalog = .{};
    candidate.replaceFromSession(&session);
    var committed: PublicCatalog = .{};
    committed.replaceFromPublic(&candidate);
    session.reset();
    candidate.replaceRestoredSelection("other-key", .openai_chat_completions, "model-1");
    var view: contract.AccountView = .{
        .state = .authenticated,
        .catalog_state = .ready,
    };
    committed.decorate(&view);
    try std.testing.expectEqualDeep(expected, view.models[0].metadata);

    candidate.decorate(&view);
    try std.testing.expectEqualDeep(contract.ModelMetadata{}, view.models[0].metadata);

    parsed = try parseModels(std.testing.allocator, model_fixture);
    session.models.deinit(session.allocator);
    session.models = parsed.entries;
    parsed.entries = .empty;
    committed.replaceFromSession(&session);
    committed.decorate(&view);
    try std.testing.expectEqualDeep(contract.ModelMetadata{}, view.models[0].metadata);
}

test "model declarations distinguish unknown, supported, and unsupported without coercion" {
    const prefix = "{\"object\":\"list\",\"has_more\":false,\"data\":[{\"id\":\"m\",\"object\":\"model\",\"type\":\"model\"";
    const cases = [_]struct { fields: []const u8, expected: contract.ModelMetadata }{
        .{ .fields = "", .expected = .{} },
        .{ .fields = ",\"max_input_tokens\":null,\"max_tokens\":0,\"capabilities\":null", .expected = .{} },
        .{ .fields = ",\"capabilities\":{\"image_input\":null,\"pdf_input\":{},\"thinking\":{\"types\":null},\"effort\":null}", .expected = .{} },
        .{ .fields = ",\"capabilities\":{\"image_input\":{\"supported\":true},\"pdf_input\":{\"supported\":false},\"batch\":{\"supported\":null}}", .expected = .{ .capabilities = .{ .image_input = true, .pdf_input = false } } },
        .{ .fields = ",\"max_input_tokens\":18446744073709551615,\"max_tokens\":1", .expected = .{ .max_input_tokens = std.math.maxInt(u64), .max_output_tokens = 1 } },
    };
    for (cases) |case| {
        const body = try std.fmt.allocPrint(std.testing.allocator, "{s}{s}}}]}}", .{ prefix, case.fields });
        defer std.testing.allocator.free(body);
        var models = try parseModels(std.testing.allocator, body);
        defer models.deinit();
        try std.testing.expectEqualDeep(case.expected, models.entries.items[0].metadata);
    }
    const invalid_fields = [_][]const u8{
        ",\"max_input_tokens\":\"1024\"",
        ",\"max_tokens\":-1",
        ",\"max_input_tokens\":-0",
        ",\"max_input_tokens\":1.5",
        ",\"max_tokens\":1e3",
        ",\"max_tokens\":18446744073709551616",
        ",\"max_tokens\":true",
        ",\"max_input_tokens\":{}",
        ",\"capabilities\":false",
        ",\"capabilities\":{\"image_input\":true}",
        ",\"capabilities\":{\"pdf_input\":{\"supported\":1}}",
        ",\"capabilities\":{\"thinking\":{\"types\":{\"adaptive\":{\"supported\":\"true\"}}}}",
        ",\"capabilities\":{\"effort\":{\"low\":{\"supported\":[]}}}",
        ",\"capabilities\":{\"context_management\":{\"compact_20260112\":{\"supported\":{}}}}",
    };
    for (invalid_fields) |fields| {
        const body = try std.fmt.allocPrint(std.testing.allocator, "{s}{s}}}]}}", .{ prefix, fields });
        defer std.testing.allocator.free(body);
        try std.testing.expectError(error.ProtocolInvalid, parseModels(std.testing.allocator, body));
    }
}

test "live-shape catalogs expose only masked views and move one key owner" {
    var keys = try parseApiKeys(std.testing.allocator, key_fixture);
    var session = CatalogSession.init(std.testing.allocator);
    defer session.deinit();
    session.api_keys = keys.entries;
    keys.entries = .empty;
    try session.selectApiKey("325");
    var models = try parseModels(std.testing.allocator, model_fixture);
    session.models = models.entries;
    models.entries = .empty;
    try std.testing.expectEqualStrings("325", session.firstApiKeyId().?);
    try std.testing.expectEqualStrings("model-1", session.firstModelId().?);

    var key_views: [contract.Limits.api_key_entries]contract.ApiKeyView =
        undefined;
    const visible_keys = session.writeApiKeyViews(&key_views);
    try std.testing.expectEqual(@as(usize, 1), visible_keys.len);
    try std.testing.expectEqualStrings("1234", visible_keys[0].suffix);
    try std.testing.expect(std.mem.indexOf(
        u8,
        visible_keys[0].name,
        "test-api-key",
    ) == null);
    var public_catalog: PublicCatalog = .{};
    public_catalog.replaceFromSession(&session);

    var execution = try session.prepareExecution("model-1", 1);
    defer execution.deinit();
    try std.testing.expectEqual(
        contract.Protocol.anthropic_messages,
        execution.input().target.protocol,
    );
    try std.testing.expectEqualStrings(
        anthropic_messages_url,
        execution.input().target.base_url,
    );
    try std.testing.expectEqualStrings(
        "test-api-key-1234",
        execution.input().api_key,
    );
    try std.testing.expectError(
        error.ApiKeyNotFound,
        session.prepareExecution("model-1", 2),
    );
    session.reset();
    var public_view: contract.AccountView = .{
        .state = .authenticated,
        .catalog_state = .ready,
    };
    public_catalog.decorate(&public_view);
    try std.testing.expectEqual(@as(usize, 1), public_view.api_keys.len);
    try std.testing.expectEqualStrings("325", public_view.api_keys[0].id);
    try std.testing.expectEqual(@as(usize, 1), public_view.models.len);
    try std.testing.expectEqualStrings("model-1", public_view.models[0].id);
}

test "catalog maps Gemini platform to AgentCore Gemini target" {
    const gemini_fixture = std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        key_fixture,
        "\"platform\":\"anthropic\"",
        "\"platform\":\"gemini\"",
    ) catch return error.SkipZigTest;
    defer std.testing.allocator.free(gemini_fixture);

    var keys = try parseApiKeys(std.testing.allocator, gemini_fixture);
    var session = CatalogSession.init(std.testing.allocator);
    defer session.deinit();
    session.api_keys = keys.entries;
    keys.entries = .empty;
    try session.selectApiKey("325");

    var models = try parseModels(std.testing.allocator, model_fixture);
    session.models = models.entries;
    models.entries = .empty;
    var execution = try session.prepareExecution("model-1", 1);
    defer execution.deinit();
    try std.testing.expectEqual(
        contract.Protocol.gemini_native,
        execution.input().target.protocol,
    );
    try std.testing.expectEqualStrings(
        gemini_base_url,
        execution.input().target.base_url,
    );
}

test "catalog accepts additive metadata and rejects duplicate ids, pagination, and platforms" {
    const items_marker = "\"items\":[";
    const item_start =
        (std.mem.indexOf(u8, key_fixture, items_marker) orelse
            return error.SkipZigTest) + items_marker.len;
    const item_end = std.mem.lastIndexOf(u8, key_fixture, "],") orelse
        return error.SkipZigTest;
    const duplicated_items = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s},{s}{s}",
        .{
            key_fixture[0..item_end],
            key_fixture[item_start..item_end],
            key_fixture[item_end..],
        },
    );
    defer std.testing.allocator.free(duplicated_items);
    const duplicate = std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        duplicated_items,
        "\"total\":1",
        "\"total\":2",
    ) catch return error.SkipZigTest;
    defer std.testing.allocator.free(duplicate);
    try std.testing.expectError(
        error.ProtocolInvalid,
        parseApiKeys(std.testing.allocator, duplicate),
    );
    const unknown = std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        key_fixture,
        "\"code\":0",
        "\"code\":0,\"unknown\":true",
    ) catch return error.SkipZigTest;
    defer std.testing.allocator.free(unknown);
    var additive_keys = try parseApiKeys(std.testing.allocator, unknown);
    defer additive_keys.deinit();
    try std.testing.expectEqual(
        @as(usize, 1),
        additive_keys.entries.items.len,
    );
    const model_unknown = std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        model_fixture,
        "\"object\":\"list\"",
        "\"object\":\"list\",\"metadata\":{\"revision\":2}",
    ) catch return error.SkipZigTest;
    defer std.testing.allocator.free(model_unknown);
    var additive_models = try parseModels(
        std.testing.allocator,
        model_unknown,
    );
    defer additive_models.deinit();
    try std.testing.expectEqual(
        @as(usize, 1),
        additive_models.entries.items.len,
    );
    const missing_consumed = std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        key_fixture,
        "\"group_id\":11",
        "\"group_identifier\":11",
    ) catch return error.SkipZigTest;
    defer std.testing.allocator.free(missing_consumed);
    try std.testing.expectError(
        error.ProtocolInvalid,
        parseApiKeys(std.testing.allocator, missing_consumed),
    );
    const paged = std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        key_fixture,
        "\"pages\":1",
        "\"pages\":2",
    ) catch return error.SkipZigTest;
    defer std.testing.allocator.free(paged);
    try std.testing.expectError(
        error.ProtocolInvalid,
        parseApiKeys(std.testing.allocator, paged),
    );
    const unsupported = std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        key_fixture,
        "\"platform\":\"anthropic\"",
        "\"platform\":\"unknown\"",
    ) catch return error.SkipZigTest;
    defer std.testing.allocator.free(unsupported);
    try std.testing.expectError(
        error.UnsupportedProvider,
        parseApiKeys(std.testing.allocator, unsupported),
    );
}

test "catalog request flow uses OAuth then direct API key credentials" {
    const Fake = struct {
        step: usize = 0,

        fn perform(
            context: *anyopaque,
            request: metask.Request,
            response_buffer: []u8,
        ) metask.TransportError!metask.Response {
            const self: *@This() = @ptrCast(@alignCast(context));
            const body = switch (self.step) {
                0 => blk: {
                    if (request.kind != .keys or
                        !std.mem.eql(u8, request.bearer orelse "", "oauth-access"))
                        return error.ProtocolFailed;
                    break :blk key_fixture;
                },
                1 => blk: {
                    if (request.kind != .models or
                        !std.mem.eql(u8, request.bearer orelse "", "test-api-key-1234"))
                        return error.ProtocolFailed;
                    break :blk model_fixture;
                },
                else => return error.ProtocolFailed,
            };
            if (body.len > response_buffer.len)
                return error.ResponseTooLarge;
            @memcpy(response_buffer[0..body.len], body);
            self.step += 1;
            return .{
                .status = 200,
                .body = response_buffer[0..body.len],
            };
        }
    };

    var fake: Fake = .{};
    var session = CatalogSession.init(std.testing.allocator);
    defer session.deinit();
    const transport: metask.Transport = .{
        .context = &fake,
        .perform_fn = Fake.perform,
    };
    try session.loadApiKeys(
        transport,
        "oauth-access",
        "account-1",
        null,
    );
    try session.selectApiKey("325");
    try session.loadModels(transport, null);
    try std.testing.expectEqualStrings(
        "account-1",
        session.ownerAccountId(),
    );
    try std.testing.expectEqual(@as(usize, 2), fake.step);
}

test "failed model reload preserves the committed private catalog" {
    const Fake = struct {
        step: usize = 0,

        fn perform(
            context: *anyopaque,
            request: metask.Request,
            response_buffer: []u8,
        ) metask.TransportError!metask.Response {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (request.kind != .models) return error.ProtocolFailed;
            const body = switch (self.step) {
                0 => declared_model_fixture,
                1 =>
                \\{"object":"list","has_more":false,"data":[{"id":"model-1","object":"model","type":"model","max_tokens":"invalid"}]}
                ,
                else => return error.NetworkFailed,
            };
            self.step += 1;
            if (body.len > response_buffer.len)
                return error.ResponseTooLarge;
            @memcpy(response_buffer[0..body.len], body);
            return .{
                .status = 200,
                .body = response_buffer[0..body.len],
            };
        }
    };

    var keys = try parseApiKeys(std.testing.allocator, key_fixture);
    var session = CatalogSession.init(std.testing.allocator);
    defer session.deinit();
    session.api_keys = keys.entries;
    keys.entries = .empty;
    session.owner_account_id = try .init("account-1");
    var fake: Fake = .{};
    const transport: metask.Transport = .{
        .context = &fake,
        .perform_fn = Fake.perform,
    };

    try session.loadModelsForApiKey("325", transport, null);
    try std.testing.expectEqualStrings("model-1", session.firstModelId().?);
    const original_metadata = session.models.items[0].metadata;
    try std.testing.expectError(
        error.ProtocolInvalid,
        session.loadModelsForApiKey("325", transport, null),
    );
    try std.testing.expectEqualDeep(original_metadata, session.models.items[0].metadata);
    try std.testing.expectError(
        error.ServiceUnavailable,
        session.loadModelsForApiKey("325", transport, null),
    );
    try std.testing.expectEqualStrings("model-1", session.firstModelId().?);
    try std.testing.expectEqualDeep(original_metadata, session.models.items[0].metadata);
}

test "catalog enforces response and field bounds before publication" {
    const oversized = try std.testing.allocator.alloc(
        u8,
        Limits.response_bytes + 1,
    );
    defer std.testing.allocator.free(oversized);
    @memset(oversized, ' ');
    try std.testing.expectError(
        error.CatalogTooLarge,
        parseApiKeys(std.testing.allocator, oversized),
    );

    const long_name = try std.testing.allocator.alloc(
        u8,
        contract.Limits.api_key_name_bytes + 1,
    );
    defer std.testing.allocator.free(long_name);
    @memset(long_name, 'x');
    const replacement = try std.fmt.allocPrint(
        std.testing.allocator,
        "\"name\":\"{s}\"",
        .{long_name},
    );
    defer std.testing.allocator.free(replacement);
    const invalid = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        key_fixture,
        "\"name\":\"Prod\"",
        replacement,
    );
    defer std.testing.allocator.free(invalid);
    try std.testing.expectError(
        error.CatalogFieldTooLarge,
        parseApiKeys(std.testing.allocator, invalid),
    );
}

test "catalog status mapping is fail closed" {
    try requireSuccess(200);
    try std.testing.expectError(error.Unauthorized, requireSuccess(401));
    try std.testing.expectError(error.Unauthorized, requireSuccess(403));
    try std.testing.expectError(error.RateLimited, requireSuccess(429));
    try std.testing.expectError(
        error.ServiceUnavailable,
        requireSuccess(503),
    );
    try std.testing.expectError(error.ProtocolInvalid, requireSuccess(302));
}
