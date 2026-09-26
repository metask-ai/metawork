//! Models-owned Metask provider catalog policy.
const std = @import("std");
const builtin = @import("builtin");
const contract = @import("metawork_product_models_contract");
const models_ports = @import("product_models_ports");
const transport_api = @import("metask_transport");

pub const models_url = "https://app.metask-ai.com/v1/models";
pub const anthropic_messages_url = contract.metask_anthropic_messages_url;

pub const Limits = struct {
    pub const response_bytes: usize = 4 * 1024 * 1024;
    pub const json_scratch_bytes: usize = 8 * 1024 * 1024;
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
    NoModels,
    ModelNotFound,
    SourceCandidateInvalid,
    OutOfMemory,
};

pub fn errorCode(err: Error) contract.ModelsError {
    return switch (err) {
        error.Unauthorized => .authorization_unavailable,
        error.RateLimited,
        error.ServiceUnavailable,
        error.Cancelled,
        error.DeadlineExceeded,
        => .catalog_unavailable,
        error.ProtocolInvalid => .catalog_invalid,
        error.CatalogTooLarge => .catalog_too_large,
        error.CatalogFieldTooLarge => .catalog_too_large,
        error.NoModels => .no_models,
        error.ModelNotFound,
        error.SourceCandidateInvalid,
        => .catalog_invalid,
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

const AccountId = BoundedString(contract.Limits.principal_ref_bytes);
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
        if (value.len > contract.Limits.credential_bytes)
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

    fn deinit(self: *Secret) void {
        if (!self.owned) return;
        secureFree(self.allocator, self.bytes);
        self.* = .{};
    }
};

const ModelEntry = struct {
    id: ModelId,
    display_name: ModelDisplayName,
    metadata: contract.ModelMetadata = .{},
};

pub const CatalogSession = struct {
    allocator: std.mem.Allocator,
    models: std.ArrayList(ModelEntry) = .empty,
    credential: Secret = .{},
    owner_account_id: AccountId = .{},
    /// HTTP status of the most recent catalog request, 0 before any request
    /// or after a transport-level failure. Owned by the single in-flight
    /// worker; read by the same worker to build the failure diagnostic.
    last_http_status: u16 = 0,

    pub fn init(allocator: std.mem.Allocator) CatalogSession {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *CatalogSession) void {
        self.credential.deinit();
        self.models.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn take(self: *CatalogSession) CatalogSession {
        const result = self.*;
        self.* = .{ .allocator = result.allocator };
        return result;
    }

    pub fn reset(self: *CatalogSession) void {
        self.credential.deinit();
        self.models.clearRetainingCapacity();
        self.owner_account_id = .{};
    }

    pub fn loadModels(
        self: *CatalogSession,
        transport: transport_api.Transport,
        oauth_access_token: []const u8,
        account_id: []const u8,
        control: ?transport_api.RequestControl,
    ) Error!void {
        const validated_account_id = try AccountId.init(account_id);
        self.last_http_status = 0;
        var replacement = try fetchModels(
            self.allocator,
            transport,
            oauth_access_token,
            control,
            &self.last_http_status,
        );
        errdefer replacement.deinit();
        var credential = try Secret.init(self.allocator, oauth_access_token);
        errdefer credential.deinit();
        self.credential.deinit();
        self.models.deinit(self.allocator);
        self.models = replacement.entries;
        replacement.entries = .empty;
        self.credential = credential;
        credential = .{};
        self.owner_account_id = validated_account_id;
    }

    pub fn prepareSourceCandidate(
        self: *CatalogSession,
        model_id: []const u8,
        metask_source_generation: u64,
    ) Error!contract.OwnedSourceCandidate {
        if (metask_source_generation == 0)
            return error.SourceCandidateInvalid;
        if (self.findModel(model_id) == null)
            return error.ModelNotFound;
        if (self.credential.view().len == 0)
            return error.SourceCandidateInvalid;

        var owned_model: ?[]u8 = self.allocator.dupe(
            u8,
            model_id,
        ) catch return error.OutOfMemory;
        errdefer if (owned_model) |bytes| self.allocator.free(bytes);
        var owned_base_url: ?[]u8 = self.allocator.dupe(
            u8,
            anthropic_messages_url,
        ) catch return error.OutOfMemory;
        errdefer if (owned_base_url) |bytes| self.allocator.free(bytes);
        // The Models source retains its runtime credential so it can issue
        // more than one independently owned binding. Each candidate receives
        // a bounded copy that it will secure-zero on every terminal path.
        const owned_secret = self.allocator.dupe(
            u8,
            self.credential.view(),
        ) catch return error.OutOfMemory;
        const transferred_model = owned_model.?;
        const transferred_base_url = owned_base_url.?;
        owned_model = null;
        owned_base_url = null;
        var result = contract.OwnedSourceCandidate.initOwned(
            self.allocator,
            .metask,
            .anthropic_messages,
            transferred_model,
            transferred_base_url,
            metask_source_generation,
            owned_secret,
            "",
        ) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.SourceCandidateInvalid;
        errdefer result.deinit();
        contract.validateMetaskSourceCandidate(result.input()) catch
            return error.SourceCandidateInvalid;
        return result;
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

    pub fn selectedProtocol(self: *const CatalogSession) ?contract.Protocol {
        return if (self.credential.view().len == 0) null else .anthropic_messages;
    }

    pub fn ownsSourceSelection(
        self: *const CatalogSession,
        account_id: []const u8,
        model_id: []const u8,
    ) bool {
        if (!std.mem.eql(u8, self.ownerAccountId(), account_id) or
            self.findModel(model_id) == null)
            return false;
        return self.credential.view().len > 0;
    }

    pub fn firstModelId(self: *const CatalogSession) ?[]const u8 {
        if (self.models.items.len == 0) return null;
        return self.models.items[0].id.view();
    }

    pub fn hasModel(self: *const CatalogSession, id: []const u8) bool {
        return self.findModel(id) != null;
    }

    pub fn ownerAccountId(self: *const CatalogSession) []const u8 {
        return self.owner_account_id.view();
    }

    fn findModel(self: *const CatalogSession, id: []const u8) ?usize {
        for (self.models.items, 0..) |*entry, index| {
            if (std.mem.eql(u8, entry.id.view(), id)) return index;
        }
        return null;
    }
};

pub const OwnedCatalogCompletion = struct {
    allocator: std.mem.Allocator,
    session: CatalogSession,
    selected_model_id: []u8,
    owned: bool = true,

    pub fn init(
        allocator: std.mem.Allocator,
        session: *CatalogSession,
        selected_model_id: []const u8,
    ) Error!OwnedCatalogCompletion {
        if (!session.hasModel(selected_model_id)) return error.ModelNotFound;
        const model = allocator.dupe(u8, selected_model_id) catch return error.OutOfMemory;
        return .{
            .allocator = allocator,
            .session = session.take(),
            .selected_model_id = model,
        };
    }

    pub fn deinit(self: *OwnedCatalogCompletion) void {
        if (!self.owned) return;
        self.session.deinit();
        self.allocator.free(self.selected_model_id);
        self.* = undefined;
    }

    /// Erases the provider-private completion at the Application/Control
    /// boundary. The returned port borrows this object and must be consumed
    /// exactly once before its storage is released.
    pub fn ownedPort(self: *OwnedCatalogCompletion) models_ports.OwnedCatalogCompletion {
        return .{
            .context = self,
            .deinit_fn = deinitErasedCatalogCompletion,
        };
    }
};

pub fn fromOwnedPort(
    completion: *models_ports.OwnedCatalogCompletion,
) ?*OwnedCatalogCompletion {
    if (completion.deinit_fn != deinitErasedCatalogCompletion) return null;
    return @ptrCast(@alignCast(completion.context));
}

fn deinitErasedCatalogCompletion(context: *anyopaque) void {
    const completion: *OwnedCatalogCompletion = @ptrCast(@alignCast(context));
    completion.deinit();
}

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

const PublicModel = struct {
    id: PublicText(contract.Limits.model_id_bytes) = .{},
    display_name: PublicText(contract.Limits.model_display_name_bytes) = .{},
    metadata: contract.ModelMetadata = .{},
};

/// Secret-free, fixed-capacity Models projection. Network workers mutate the
/// private candidate CatalogSession, then the App main thread snapshots a
/// successful stage here. The composition root keeps committed and candidate
/// PublicCatalog slots stay separate until source preference persistence succeeds. Other
/// state changes read only those secret-free caches, so cancel and shutdown
/// never race worker-owned secrets.
pub const PublicCatalog = struct {
    models: [contract.Limits.model_entries]PublicModel = @splat(.{}),
    model_views: [contract.Limits.model_entries]contract.ModelView =
        undefined,
    model_count: usize = 0,

    pub fn replaceFromSession(
        self: *PublicCatalog,
        session: *const CatalogSession,
    ) void {
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

    pub fn clear(self: *PublicCatalog) void {
        self.model_count = 0;
    }

    pub fn hasModel(self: *const PublicCatalog, id: []const u8) bool {
        for (self.models[0..self.model_count]) |*entry|
            if (std.mem.eql(u8, entry.id.view(), id)) return true;
        return false;
    }

    pub fn modelViews(self: *PublicCatalog) []const contract.ModelView {
        for (
            self.models[0..self.model_count],
            self.model_views[0..self.model_count],
        ) |*storage, *view| {
            view.* = .{
                .id = storage.id.view(),
                .display_name = storage.display_name.view(),
                .metadata = storage.metadata,
            };
        }
        return self.model_views[0..self.model_count];
    }
};

pub const TestSupport = if (builtin.is_test) struct {
    pub fn replaceOwnedCatalog(
        session: *CatalogSession,
        account_id: []const u8,
        access_token: []const u8,
        models: []const contract.ModelView,
    ) Error!void {
        session.reset();
        session.owner_account_id = try .init(account_id);
        session.credential = try Secret.init(session.allocator, access_token);
        for (models) |model| {
            session.models.append(session.allocator, .{
                .id = try .init(model.id),
                .display_name = try .optional(model.display_name),
                .metadata = model.metadata,
            }) catch return error.OutOfMemory;
        }
    }
} else struct {};

const ParsedModels = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(ModelEntry) = .empty,

    fn deinit(self: *ParsedModels) void {
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }
};

fn fetchModels(
    allocator: std.mem.Allocator,
    transport: transport_api.Transport,
    access_token: []const u8,
    control: ?transport_api.RequestControl,
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
        .bearer = access_token,
        .control = control,
    }, response_buffer) catch |err| return transportError(err);
    status_out.* = response.status;
    try requireSuccess(response.status);
    return parseModels(allocator, response.body);
}

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

fn jsonScratchSize(body_len: usize) usize {
    const minimum = 64 * 1024;
    return @min(
        Limits.json_scratch_bytes,
        @max(minimum, body_len * 4),
    );
}

fn validHeaderCredential(value: []const u8) bool {
    if (value.len == 0 or
        value.len > contract.Limits.credential_bytes)
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

fn transportError(err: transport_api.TransportError) Error {
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

    var committed: PublicCatalog = .{};
    committed.replaceFromSession(&session);
    session.reset();
    try std.testing.expectEqualDeep(expected, committed.modelViews()[0].metadata);

    parsed = try parseModels(std.testing.allocator, model_fixture);
    session.models.deinit(session.allocator);
    session.models = parsed.entries;
    parsed.entries = .empty;
    committed.replaceFromSession(&session);
    try std.testing.expectEqualDeep(contract.ModelMetadata{}, committed.modelViews()[0].metadata);
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

test "OAuth catalog issues independent Anthropic Messages candidates" {
    var session = CatalogSession.init(std.testing.allocator);
    defer session.deinit();
    session.owner_account_id = try .init("account-1");
    session.credential = try Secret.init(std.testing.allocator, "oauth-access");
    var models = try parseModels(std.testing.allocator, model_fixture);
    session.models = models.entries;
    models.entries = .empty;
    try std.testing.expectEqualStrings("model-1", session.firstModelId().?);
    var public_catalog: PublicCatalog = .{};
    public_catalog.replaceFromSession(&session);

    var candidate = try session.prepareSourceCandidate("model-1", 1);
    defer candidate.deinit();
    try std.testing.expectEqual(
        contract.Protocol.anthropic_messages,
        candidate.input().target.protocol,
    );
    try std.testing.expectEqualStrings(
        anthropic_messages_url,
        candidate.input().target.base_url,
    );
    try std.testing.expectEqualStrings(
        "oauth-access",
        candidate.input().api_key,
    );
    var second_candidate = try session.prepareSourceCandidate("model-1", 2);
    defer second_candidate.deinit();
    try std.testing.expectEqualStrings(
        "oauth-access",
        second_candidate.input().api_key,
    );
    session.reset();
    const public_models = public_catalog.modelViews();
    try std.testing.expectEqual(@as(usize, 1), public_models.len);
    try std.testing.expectEqualStrings("model-1", public_models[0].id);
}

test "catalog accepts additive model metadata" {
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
}

test "catalog request flow uses OAuth access token directly" {
    const Fake = struct {
        step: usize = 0,

        fn perform(
            context: *anyopaque,
            request: transport_api.Request,
            response_buffer: []u8,
        ) transport_api.TransportError!transport_api.Response {
            const self: *@This() = @ptrCast(@alignCast(context));
            const body = switch (self.step) {
                0 => blk: {
                    if (request.kind != .models or
                        !std.mem.eql(u8, request.bearer orelse "", "oauth-access"))
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
    const transport: transport_api.Transport = .{
        .context = &fake,
        .perform_fn = Fake.perform,
    };
    try session.loadModels(
        transport,
        "oauth-access",
        "account-1",
        null,
    );
    try std.testing.expectEqualStrings(
        "account-1",
        session.ownerAccountId(),
    );
    try std.testing.expectEqual(@as(usize, 1), fake.step);
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
        parseModels(std.testing.allocator, oversized),
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
