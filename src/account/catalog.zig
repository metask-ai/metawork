const std = @import("std");
const contract = @import("metawork_account_contract");
const metask = @import("metask_client");

pub const api_keys_url = metask.api_keys_url;
pub const models_url = metask.models_url;
pub const anthropic_messages_url =
    contract.metask_anthropic_messages_url;
pub const openai_chat_completions_url =
    contract.metask_openai_chat_completions_url;

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
const ProfileId = BoundedString(contract.Limits.profile_id_bytes);
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
    provider_kind: contract.ProviderKind,
    secret: Secret,

    fn deinit(self: *ApiKeyEntry) void {
        self.secret.deinit();
        self.* = undefined;
    }
};

const ModelEntry = struct {
    id: ModelId,
    display_name: ModelDisplayName,
};

pub const CatalogSession = struct {
    allocator: std.mem.Allocator,
    api_keys: std.ArrayList(ApiKeyEntry) = .empty,
    models: std.ArrayList(ModelEntry) = .empty,
    selected_key_index: ?usize = null,
    owner_account_id: AccountId = .{},
    owner_profile_id: ProfileId = .{},

    pub fn init(allocator: std.mem.Allocator) CatalogSession {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *CatalogSession) void {
        self.clearApiKeys();
        self.api_keys.deinit(self.allocator);
        self.models.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn loadApiKeys(
        self: *CatalogSession,
        transport: metask.Transport,
        oauth_access_token: []const u8,
        account_id: []const u8,
        profile_id: []const u8,
        control: ?metask.RequestControl,
    ) Error!void {
        const validated_account_id = try AccountId.init(account_id);
        const validated_profile_id = try ProfileId.init(profile_id);
        var replacement = try fetchApiKeys(
            self.allocator,
            transport,
            oauth_access_token,
            profile_id,
            control,
        );
        errdefer replacement.deinit();
        self.clearApiKeys();
        self.api_keys.deinit(self.allocator);
        self.api_keys = replacement.entries;
        replacement.entries = .empty;
        self.selected_key_index = null;
        self.owner_account_id = validated_account_id;
        self.owner_profile_id = validated_profile_id;
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
        const credential = self.api_keys.items[index].secret.view();
        if (credential.len == 0) return error.ApiKeyNotFound;
        const profile_id = self.owner_profile_id.view();
        if (profile_id.len == 0) return error.ProtocolInvalid;
        var replacement = try fetchModels(
            self.allocator,
            transport,
            credential,
            profile_id,
            control,
        );
        errdefer replacement.deinit();
        self.models.deinit(self.allocator);
        self.models = replacement.entries;
        replacement.entries = .empty;
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
        const base_url = baseUrl(entry.provider_kind) orelse
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
            entry.provider_kind,
            transferred_model,
            transferred_base_url,
            execution_generation,
            owned_secret,
        ) catch return error.ExecutionTargetInvalid;
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

    pub fn ownerAccountId(self: *const CatalogSession) []const u8 {
        return self.owner_account_id.view();
    }

    pub fn ownerProfileId(self: *const CatalogSession) []const u8 {
        return self.owner_profile_id.view();
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
        self.owner_profile_id = .{};
    }
};

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
    profile_id: []const u8,
    control: ?metask.RequestControl,
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
        .profile_id = profile_id,
        .control = control,
    }, response_buffer) catch |err| return transportError(err);
    try requireSuccess(response.status);
    return parseApiKeys(allocator, response.body);
}

fn fetchModels(
    allocator: std.mem.Allocator,
    transport: metask.Transport,
    api_key: []const u8,
    profile_id: []const u8,
    control: ?metask.RequestControl,
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
        .profile_id = profile_id,
        .control = control,
    }, response_buffer) catch |err| return transportError(err);
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
    user_id: u64,
    key: []const u8,
    name: []const u8,
    group_id: u64,
    status: []const u8,
    ip_whitelist: ?std.json.Value,
    ip_blacklist: ?std.json.Value,
    last_used_at: ?[]const u8,
    quota: std.json.Value,
    quota_used: std.json.Value,
    expires_at: ?[]const u8,
    created_at: []const u8,
    updated_at: []const u8,
    rate_limit_5h: std.json.Value,
    rate_limit_1d: std.json.Value,
    rate_limit_7d: std.json.Value,
    usage_5h: std.json.Value,
    usage_1d: std.json.Value,
    usage_7d: std.json.Value,
    window_5h_start: ?[]const u8,
    window_1d_start: ?[]const u8,
    window_7d_start: ?[]const u8,
    group: GroupWire,
};

const GroupWire = struct {
    id: u64,
    name: []const u8,
    description: []const u8,
    platform: []const u8,
    rate_multiplier: std.json.Value,
    visibility: []const u8,
    is_exclusive: bool,
    status: []const u8,
    image_price_1k: ?std.json.Value,
    image_price_2k: ?std.json.Value,
    image_price_4k: ?std.json.Value,
    sora_image_price_360: ?std.json.Value,
    sora_image_price_540: ?std.json.Value,
    sora_video_price_per_request: ?std.json.Value,
    sora_video_price_per_request_hd: ?std.json.Value,
    claude_code_only: bool,
    fallback_group_id: ?u64,
    fallback_group_id_on_invalid_request: ?u64,
    sora_storage_quota_bytes: std.json.Value,
    allow_messages_dispatch: bool,
    created_at: []const u8,
    updated_at: []const u8,
};

const ModelsResponse = struct {
    object: []const u8,
    data: []const ModelWire,
    first_id: ?[]const u8,
    last_id: ?[]const u8,
    has_more: bool,
    remaining: std.json.Value,
    unit: []const u8,
};

const ModelWire = struct {
    id: []const u8,
    object: []const u8,
    created: std.json.Value,
    owned_by: []const u8,
    type: []const u8,
    display_name: ?[]const u8 = null,
    created_at: []const u8,
    max_input_tokens: ?u64 = null,
    max_tokens: ?u64 = null,
    anthropic_family_tier: ?std.json.Value = null,
    capabilities: ?std.json.Value = null,
};

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
            .ignore_unknown_fields = false,
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
        const provider_kind = providerKind(item.group.platform) orelse
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
            .provider_kind = provider_kind,
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
            .ignore_unknown_fields = false,
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
            !std.mem.eql(u8, model.type, "model") or
            model.max_input_tokens == 0 or model.max_tokens == 0)
            return error.ProtocolInvalid;
        const id = try ModelId.init(model.id);
        for (result.entries.items) |*existing| {
            if (std.mem.eql(u8, existing.id.view(), id.view()))
                return error.ProtocolInvalid;
        }
        result.entries.append(allocator, .{
            .id = id,
            .display_name = try .optional(model.display_name orelse ""),
        }) catch return error.OutOfMemory;
    }
    if (result.entries.items.len == 0) return error.NoModels;
    return result;
}

fn providerKind(platform: []const u8) ?contract.ProviderKind {
    if (std.mem.eql(u8, platform, "anthropic")) return .anthropic;
    if (std.mem.eql(u8, platform, "openai")) return .openai;
    return null;
}

fn jsonScratchSize(body_len: usize) usize {
    const minimum = 64 * 1024;
    return @min(
        Limits.json_scratch_bytes,
        @max(minimum, body_len * 4),
    );
}

fn baseUrl(provider_kind: contract.ProviderKind) ?[]const u8 {
    return switch (provider_kind) {
        .anthropic => anthropic_messages_url,
        .openai => openai_chat_completions_url,
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
    \\"max_input_tokens":200000,"max_tokens":32000,
    \\"anthropic_family_tier":"pro","capabilities":{"thinking":{"supported":true}}}],
    \\"first_id":"model-1","last_id":"model-1","has_more":false,
    \\"remaining":0,"unit":"model"}
;

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

    var execution = try session.prepareExecution("model-1", 1);
    defer execution.deinit();
    try std.testing.expectEqual(
        contract.ProviderKind.anthropic,
        execution.input().target.provider_kind,
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
}

test "catalog rejects duplicate ids, unknown fields, pagination, and platforms" {
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
    try std.testing.expectError(
        error.ProtocolInvalid,
        parseApiKeys(std.testing.allocator, unknown),
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
        "\"platform\":\"gemini\"",
    ) catch return error.SkipZigTest;
    defer std.testing.allocator.free(unsupported);
    try std.testing.expectError(
        error.UnsupportedProvider,
        parseApiKeys(std.testing.allocator, unsupported),
    );
}

test "catalog request flow binds OAuth and API key credentials to profile" {
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
                        !std.mem.eql(
                            u8,
                            request.bearer orelse "",
                            "oauth-access",
                        ) or
                        !std.mem.eql(
                            u8,
                            request.profile_id orelse "",
                            "profile-1",
                        ))
                        return error.ProtocolFailed;
                    break :blk key_fixture;
                },
                1 => blk: {
                    if (request.kind != .models or
                        !std.mem.eql(
                            u8,
                            request.bearer orelse "",
                            "test-api-key-1234",
                        ) or
                        !std.mem.eql(
                            u8,
                            request.profile_id orelse "",
                            "profile-1",
                        ))
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
        "profile-1",
        null,
    );
    try session.selectApiKey("325");
    try session.loadModels(transport, null);
    try std.testing.expectEqualStrings(
        "account-1",
        session.ownerAccountId(),
    );
    try std.testing.expectEqualStrings(
        "profile-1",
        session.ownerProfileId(),
    );
    try std.testing.expectEqual(@as(usize, 2), fake.step);
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
