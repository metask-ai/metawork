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
    protocol: contract.Protocol,
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
        const model_index = self.findModel(model_id) orelse return error.ModelNotFound;
        const protocol = self.models.items[model_index].protocol;
        if (self.credential.view().len == 0)
            return error.SourceCandidateInvalid;

        var owned_model: ?[]u8 = self.allocator.dupe(
            u8,
            model_id,
        ) catch return error.OutOfMemory;
        errdefer if (owned_model) |bytes| self.allocator.free(bytes);
        var owned_base_url: ?[]u8 = self.allocator.dupe(
            u8,
            contract.metaskEndpoint(protocol) orelse return error.SourceCandidateInvalid,
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
            protocol,
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

    pub fn modelProtocol(self: *const CatalogSession, model_id: []const u8) ?contract.Protocol {
        if (self.credential.view().len == 0) return null;
        const index = self.findModel(model_id) orelse return null;
        return self.models.items[index].protocol;
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
    session: CatalogSession,
    owned: bool = true,

    pub fn init(session: *CatalogSession) OwnedCatalogCompletion {
        return .{ .session = session.take() };
    }

    pub fn deinit(self: *OwnedCatalogCompletion) void {
        if (!self.owned) return;
        self.session.deinit();
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
    pub fn loadCatalogResponse(session: *CatalogSession, principal_ref: []const u8, access_token: []const u8, response_body: []const u8) !void {
        const Fake = struct {
            body: []const u8,
            fn perform(context: *anyopaque, _: transport_api.Request, output: []u8) transport_api.TransportError!transport_api.Response {
                const self: *@This() = @ptrCast(@alignCast(context));
                if (self.body.len > output.len) return error.ResponseTooLarge;
                @memcpy(output[0..self.body.len], self.body);
                return .{ .status = 200, .body = output[0..self.body.len] };
            }
        };
        var fake: Fake = .{ .body = response_body };
        try session.loadModels(.{ .context = &fake, .perform_fn = Fake.perform }, access_token, principal_ref, null);
    }

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
                .protocol = .anthropic_messages,
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

const ModelEndpointsWire = struct {
    messages: ?CapabilityWire = null,
    responses: ?CapabilityWire = null,
    chat_completions: ?CapabilityWire = null,
    images_generations: ?CapabilityWire = null,
    videos: ?CapabilityWire = null,
    embeddings: ?CapabilityWire = null,

    fn selectedProtocol(self: ModelEndpointsWire) ?contract.Protocol {
        if (supported(self.messages)) return .anthropic_messages;
        if (supported(self.responses)) return .openai_responses;
        if (supported(self.chat_completions)) return .openai_chat_completions;
        return null;
    }
};

const ModelCapabilitiesWire = struct {
    endpoints: ?ModelEndpointsWire = null,
    input: ?struct {
        text: ?CapabilityWire = null,
        audio: ?CapabilityWire = null,
        video: ?CapabilityWire = null,
        image: ?CapabilityWire = null,
        pdf: ?CapabilityWire = null,
    } = null,
    output: ?struct {
        text: ?CapabilityWire = null,
        image: ?CapabilityWire = null,
        audio: ?CapabilityWire = null,
        video: ?CapabilityWire = null,
        embedding: ?CapabilityWire = null,
    } = null,
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
            .text_input = if (self.input) |input| supported(input.text) else false,
            .audio_input = if (self.input) |input| supported(input.audio) else false,
            .video_input = if (self.input) |input| supported(input.video) else false,
            .output = .{
                .text = if (self.output) |output| supported(output.text) else false,
                .image = if (self.output) |output| supported(output.image) else false,
                .audio = if (self.output) |output| supported(output.audio) else false,
                .video = if (self.output) |output| supported(output.video) else false,
                .embedding = if (self.output) |output| supported(output.embedding) else false,
            },
            .image_input = if (self.input) |input| supported(input.image) else false,
            .pdf_input = if (self.input) |input| supported(input.pdf) else false,
            .batch = supported(self.batch),
            .citations = supported(self.citations),
            .code_execution = supported(self.code_execution),
            .structured_outputs = supported(self.structured_outputs),
            .thinking = .{ .supported = false, .adaptive = false, .enabled = false },
            .effort = .{ .supported = false, .low = false, .medium = false, .high = false, .max = false },
            .context_management = .{
                .supported = false,
                .clear_thinking_20251015 = false,
                .clear_tool_uses_20250919 = false,
                .compact_20260112 = false,
            },
        };
        if (self.thinking) |thinking| {
            result.thinking.supported = thinking.supported orelse false;
            if (thinking.types) |types| {
                result.thinking.adaptive = supported(types.adaptive);
                result.thinking.enabled = supported(types.enabled);
            }
        }
        if (self.effort) |effort| result.effort = .{
            .supported = effort.supported orelse false,
            .low = supported(effort.low),
            .medium = supported(effort.medium),
            .high = supported(effort.high),
            .max = supported(effort.max),
        };
        if (self.context_management) |context| result.context_management = .{
            .supported = context.supported orelse false,
            .clear_thinking_20251015 = supported(context.clear_thinking_20251015),
            .clear_tool_uses_20250919 = supported(context.clear_tool_uses_20250919),
            .compact_20260112 = supported(context.compact_20260112),
        };
        return result;
    }
};

fn supported(capability: ?CapabilityWire) bool {
    return if (capability) |value| value.supported orelse false else false;
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
    for (response.data, 0..) |model, index| {
        if (!std.mem.eql(u8, model.object, "model") or
            !std.mem.eql(u8, model.type, "model"))
            return error.ProtocolInvalid;
        const id = try ModelId.init(model.id);
        for (response.data[0..index]) |existing| {
            if (std.mem.eql(u8, existing.id, id.view()))
                return error.ProtocolInvalid;
        }
        const capabilities: ModelCapabilitiesWire = model.capabilities orelse .{};
        var entry: ModelEntry = .{
            .id = id,
            .protocol = undefined,
            .display_name = try .optional(model.display_name orelse ""),
            .metadata = .{
                .max_input_tokens = try tokenLimit(model.max_input_tokens),
                .max_output_tokens = try tokenLimit(model.max_tokens),
                .capabilities = capabilities.projection(),
            },
        };
        // Endpoint declarations own both model purpose and execution protocol.
        // A dialogue endpoint does not admit a mixed media-generation model.
        const endpoints: ModelEndpointsWire = capabilities.endpoints orelse .{};
        if (supported(endpoints.images_generations) or supported(endpoints.videos)) continue;
        entry.protocol = endpoints.selectedProtocol() orelse continue;
        result.entries.append(allocator, entry) catch return error.OutOfMemory;
    }
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
        error.NetworkFailed, error.NetworkNotSent => error.ServiceUnavailable,
        error.ResponseTooLarge => error.CatalogTooLarge,
        error.ProtocolFailed => error.ProtocolInvalid,
        error.Cancelled, error.CancelledNotSent => error.Cancelled,
        error.DeadlineExceeded, error.DeadlineExceededNotSent => error.DeadlineExceeded,
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
    \\"max_input_tokens":0,"max_tokens":0,"capabilities":{"endpoints":{"messages":{"supported":true}}}}],
    \\"first_id":"model-1","last_id":"model-1","has_more":false,
    \\"remaining":0,"unit":"model"}
;

const declared_model_fixture =
    \\{"object":"list","has_more":false,"data":[{
    \\"id":"model-1","object":"model","type":"model","display_name":"Model 1",
    \\"max_input_tokens":1048576,"max_tokens":64000,"capabilities":{"endpoints":{"messages":{"supported":true}},
    \\"input":{"image":{"supported":true},"pdf":{"supported":true}},
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
            .text_input = false,
            .audio_input = false,
            .video_input = false,
            .output = .{ .text = false, .image = false, .audio = false, .video = false, .embedding = false },
            .image_input = true,
            .pdf_input = true,
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
    try std.testing.expectEqualDeep(contract.ModelMetadata{ .capabilities = (ModelCapabilitiesWire{}).projection() }, committed.modelViews()[0].metadata);
}

test "Metask capabilities default to unsupported without coercion" {
    const prefix = "{\"object\":\"list\",\"has_more\":false,\"data\":[{\"id\":\"m\",\"object\":\"model\",\"type\":\"model\"";
    const unsupported_metadata: contract.ModelMetadata = .{ .capabilities = (ModelCapabilitiesWire{}).projection() };
    const image_capabilities = blk: {
        var capabilities = (ModelCapabilitiesWire{}).projection();
        capabilities.image_input = true;
        break :blk capabilities;
    };
    const cases = [_]struct { fields: []const u8, expected: contract.ModelMetadata, eligible: bool = true }{
        .{ .fields = ",\"capabilities\":{\"endpoints\":{\"messages\":{\"supported\":true}}}", .expected = unsupported_metadata },
        .{ .fields = ",\"max_input_tokens\":null,\"max_tokens\":0,\"capabilities\":null", .expected = unsupported_metadata, .eligible = false },
        .{ .fields = ",\"capabilities\":{\"endpoints\":{\"messages\":{\"supported\":true}},\"input\":{\"image\":null,\"pdf\":{}},\"thinking\":{\"types\":null},\"effort\":null}", .expected = unsupported_metadata },
        .{ .fields = ",\"capabilities\":{\"endpoints\":{\"messages\":{\"supported\":true}},\"input\":{\"image\":{\"supported\":true},\"pdf\":{\"supported\":false}},\"batch\":{\"supported\":null}}", .expected = .{ .capabilities = image_capabilities } },
        .{ .fields = ",\"max_input_tokens\":18446744073709551615,\"max_tokens\":1,\"capabilities\":{\"endpoints\":{\"messages\":{\"supported\":true}}}", .expected = .{ .max_input_tokens = std.math.maxInt(u64), .max_output_tokens = 1, .capabilities = unsupported_metadata.capabilities } },
    };
    for (cases) |case| {
        const body = try std.fmt.allocPrint(std.testing.allocator, "{s}{s}}}]}}", .{ prefix, case.fields });
        defer std.testing.allocator.free(body);
        var models = try parseModels(std.testing.allocator, body);
        defer models.deinit();
        try std.testing.expectEqual(@as(usize, if (case.eligible) 1 else 0), models.entries.items.len);
        if (case.eligible) try std.testing.expectEqualDeep(case.expected, models.entries.items[0].metadata);
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
        ",\"capabilities\":{\"input\":{\"image\":true}}",
        ",\"capabilities\":{\"input\":{\"pdf\":{\"supported\":1}}}",
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

test "empty catalog is a valid authoritative result" {
    var models = try parseModels(std.testing.allocator, "{\"object\":\"list\",\"has_more\":false,\"data\":[]}");
    defer models.deinit();
    try std.testing.expectEqual(@as(usize, 0), models.entries.items.len);
}

test "endpoint declarations classify dialogue and exclude media generation models" {
    const cases = [_]struct { endpoints: []const u8, count: usize }{
        .{ .endpoints = "{\"messages\":{\"supported\":true}}", .count = 1 },
        .{ .endpoints = "{\"messages\":{\"supported\":true},\"images_generations\":null,\"videos\":{}}", .count = 1 },
        .{ .endpoints = "{\"chat_completions\":{\"supported\":true},\"images_generations\":{\"supported\":null}}", .count = 1 },
        .{ .endpoints = "{\"responses\":{\"supported\":true},\"images_generations\":{\"supported\":false},\"videos\":{\"supported\":false}}", .count = 1 },
        .{ .endpoints = "{\"messages\":{\"supported\":true},\"images_generations\":{\"supported\":true}}", .count = 0 },
        .{ .endpoints = "{\"chat_completions\":{\"supported\":true},\"videos\":{\"supported\":true}}", .count = 0 },
        .{ .endpoints = "{\"responses\":{\"supported\":true},\"images_generations\":{\"supported\":true},\"videos\":{\"supported\":true}}", .count = 0 },
        .{ .endpoints = "{\"images_generations\":{\"supported\":true}}", .count = 0 },
        .{ .endpoints = "{\"videos\":{\"supported\":true}}", .count = 0 },
        .{ .endpoints = "{\"embeddings\":{\"supported\":true}}", .count = 0 },
    };
    for (cases) |case| {
        const body = try std.fmt.allocPrint(std.testing.allocator, "{{\"object\":\"list\",\"has_more\":false,\"data\":[{{\"id\":\"m\",\"object\":\"model\",\"type\":\"model\",\"capabilities\":{{\"endpoints\":{s}}}}}]}}", .{case.endpoints});
        defer std.testing.allocator.free(body);
        var parsed = try parseModels(std.testing.allocator, body);
        defer parsed.deinit();
        try std.testing.expectEqual(case.count, parsed.entries.items.len);
    }
}

test "excluded media models cannot hide invalid catalog metadata or duplicate identity" {
    const cases = [_][]const u8{
        "{\"object\":\"list\",\"has_more\":false,\"data\":[{\"id\":\"media\",\"object\":\"model\",\"type\":\"model\",\"capabilities\":{\"endpoints\":{\"images_generations\":{\"supported\":\"true\"}}}}]}",
        "{\"object\":\"list\",\"has_more\":false,\"data\":[{\"id\":\"media\",\"object\":\"model\",\"type\":\"model\",\"capabilities\":{\"endpoints\":{\"videos\":true}}}]}",
        "{\"object\":\"list\",\"has_more\":false,\"data\":[{\"id\":\"media\",\"object\":\"model\",\"type\":\"model\",\"max_tokens\":-1,\"capabilities\":{\"endpoints\":{\"images_generations\":{\"supported\":true}}}}]}",
        "{\"object\":\"list\",\"has_more\":false,\"data\":[{\"id\":\"media\",\"object\":\"model\",\"type\":\"model\",\"capabilities\":{\"endpoints\":{\"images_generations\":{\"supported\":true}}}},{\"id\":\"media\",\"object\":\"model\",\"type\":\"model\"}]}",
    };
    for (cases) |body| {
        try std.testing.expectError(error.ProtocolInvalid, parseModels(std.testing.allocator, body));
    }
}

test "media generation endpoints exclude source resolution and public catalog" {
    var session = CatalogSession.init(std.testing.allocator);
    defer session.deinit();
    session.owner_account_id = try .init("account-1");
    session.credential = try Secret.init(std.testing.allocator, "oauth-access");
    var parsed = try parseModels(std.testing.allocator, "{\"object\":\"list\",\"has_more\":false,\"data\":[{\"id\":\"media\",\"object\":\"model\",\"type\":\"model\",\"capabilities\":{\"endpoints\":{\"chat_completions\":{\"supported\":true},\"images_generations\":{\"supported\":true}}}},{\"id\":\"chat\",\"object\":\"model\",\"type\":\"model\",\"capabilities\":{\"endpoints\":{\"messages\":{\"supported\":true}}}}]}");
    session.models = parsed.entries;
    parsed.entries = .empty;
    try std.testing.expect(!session.hasModel("media"));
    try std.testing.expectError(error.ModelNotFound, session.prepareSourceCandidate("media", 1));
    try std.testing.expectEqualStrings("chat", session.firstModelId().?);
    var catalog: PublicCatalog = .{};
    catalog.replaceFromSession(&session);
    try std.testing.expectEqual(@as(usize, 1), catalog.modelViews().len);
    try std.testing.expectEqualStrings("chat", catalog.modelViews()[0].id);
}

test "endpoint declarations choose a deterministic protocol with no implicit support" {
    const prefix = "{\"object\":\"list\",\"has_more\":false,\"data\":[{\"id\":\"model\",\"object\":\"model\",\"type\":\"model\",\"capabilities\":{\"endpoints\":";
    const cases = [_]struct { endpoints: []const u8, protocol: ?contract.Protocol }{
        .{ .endpoints = "null", .protocol = null },
        .{ .endpoints = "{}", .protocol = null },
        .{ .endpoints = "{\"messages\":null,\"responses\":{},\"chat_completions\":{\"supported\":null}}", .protocol = null },
        .{ .endpoints = "{\"messages\":{\"supported\":false,\"status\":\"unknown\"},\"responses\":{\"supported\":false},\"chat_completions\":{\"supported\":false}}", .protocol = null },
        .{ .endpoints = "{\"messages\":{\"supported\":true},\"responses\":{\"supported\":true},\"chat_completions\":{\"supported\":true}}", .protocol = .anthropic_messages },
        .{ .endpoints = "{\"responses\":{\"supported\":true},\"messages\":{\"supported\":false},\"chat_completions\":{\"supported\":true}}", .protocol = .openai_responses },
        .{ .endpoints = "{\"chat_completions\":{\"supported\":true},\"responses\":{\"supported\":false},\"messages\":{\"supported\":false}}", .protocol = .openai_chat_completions },
    };
    for (cases) |case| {
        const body = try std.mem.concat(std.testing.allocator, u8, &.{ prefix, case.endpoints, "}}]}" });
        defer std.testing.allocator.free(body);
        var parsed = try parseModels(std.testing.allocator, body);
        defer parsed.deinit();
        try std.testing.expectEqual(@as(usize, if (case.protocol != null) 1 else 0), parsed.entries.items.len);
        if (case.protocol) |protocol| {
            var session = CatalogSession.init(std.testing.allocator);
            defer session.deinit();
            session.models = parsed.entries;
            parsed.entries = .empty;
            session.credential = try Secret.init(std.testing.allocator, "oauth-access");
            session.owner_account_id = try .init("principal");
            try std.testing.expectEqual(protocol, session.modelProtocol("model").?);
            var candidate = try session.prepareSourceCandidate("model", 17);
            defer candidate.deinit();
            try std.testing.expectEqual(protocol, candidate.input().target.protocol);
            try std.testing.expectEqualStrings(contract.metaskEndpoint(protocol).?, candidate.input().target.base_url);
            try contract.validateMetaskSourceCandidate(candidate.input());
        }
    }
    var missing = try parseModels(std.testing.allocator, "{\"object\":\"list\",\"has_more\":false,\"data\":[{\"id\":\"model\",\"object\":\"model\",\"type\":\"model\"}]}");
    defer missing.deinit();
    try std.testing.expectEqual(@as(usize, 0), missing.entries.items.len);
}

test "invalid endpoint supported declarations reject the whole response" {
    const prefix = "{\"object\":\"list\",\"has_more\":false,\"data\":[{\"id\":\"model\",\"object\":\"model\",\"type\":\"model\",\"capabilities\":{\"endpoints\":";
    for ([_][]const u8{ "true", "{\"messages\":true}", "{\"responses\":{\"supported\":\"true\"}}", "{\"chat_completions\":{\"supported\":1}}" }) |endpoints| {
        const body = try std.mem.concat(std.testing.allocator, u8, &.{ prefix, endpoints, "}}]}" });
        defer std.testing.allocator.free(body);
        try std.testing.expectError(error.ProtocolInvalid, parseModels(std.testing.allocator, body));
    }
}

test "only endpoints decide admission despite redundant output declarations" {
    const cases = [_]struct { body: []const u8, count: usize }{
        .{ .body = "{\"object\":\"list\",\"has_more\":false,\"data\":[{\"id\":\"media\",\"object\":\"model\",\"type\":\"model\",\"capabilities\":{\"endpoints\":{\"messages\":{\"supported\":true}},\"image_output\":{\"supported\":true},\"video_output\":{\"supported\":true},\"output\":{\"image\":{\"supported\":true},\"video\":{\"supported\":true}}}}]}", .count = 1 },
        .{ .body = "{\"object\":\"list\",\"has_more\":false,\"data\":[{\"id\":\"media\",\"object\":\"model\",\"type\":\"model\",\"capabilities\":{\"endpoints\":{\"chat_completions\":{\"supported\":true,\"input\":[\"image\"],\"output\":[\"image\",\"video\"]}},\"image_input\":{\"supported\":true}}}]}", .count = 1 },
        .{ .body = "{\"object\":\"list\",\"has_more\":false,\"data\":[{\"id\":\"media\",\"object\":\"model\",\"type\":\"model\",\"capabilities\":{\"endpoints\":{\"messages\":{\"supported\":true},\"images_generations\":{\"supported\":true}},\"image_output\":{\"supported\":false},\"output\":{\"image\":{\"supported\":false}}}}]}", .count = 0 },
        .{ .body = "{\"object\":\"list\",\"has_more\":false,\"data\":[{\"id\":\"media\",\"object\":\"model\",\"type\":\"model\",\"capabilities\":{\"image_output\":{\"supported\":false},\"text_output\":{\"supported\":true},\"output\":{\"text\":{\"supported\":true}}}}]}", .count = 0 },
    };
    for (cases) |case| {
        var parsed = try parseModels(std.testing.allocator, case.body);
        defer parsed.deinit();
        try std.testing.expectEqual(case.count, parsed.entries.items.len);
    }
}

test "input image and pdf declarations are authoritative without legacy or document fallback" {
    const cases = [_]struct { body: []const u8, image: bool, pdf: bool }{
        .{ .body = "{\"object\":\"list\",\"has_more\":false,\"data\":[{\"id\":\"m\",\"object\":\"model\",\"type\":\"model\",\"capabilities\":{\"endpoints\":{\"messages\":{\"supported\":true}}}}]}", .image = false, .pdf = false },
        .{ .body = "{\"object\":\"list\",\"has_more\":false,\"data\":[{\"id\":\"m\",\"object\":\"model\",\"type\":\"model\",\"capabilities\":{\"input\":null,\"endpoints\":{\"messages\":{\"supported\":true}}}}]}", .image = false, .pdf = false },
        .{ .body = "{\"object\":\"list\",\"has_more\":false,\"data\":[{\"id\":\"m\",\"object\":\"model\",\"type\":\"model\",\"capabilities\":{\"input\":{},\"endpoints\":{\"messages\":{\"supported\":true}}}}]}", .image = false, .pdf = false },
        .{ .body = "{\"object\":\"list\",\"has_more\":false,\"data\":[{\"id\":\"m\",\"object\":\"model\",\"type\":\"model\",\"capabilities\":{\"input\":{\"image\":null,\"pdf\":{\"supported\":null}},\"endpoints\":{\"messages\":{\"supported\":true}}}}]}", .image = false, .pdf = false },
        .{ .body = "{\"object\":\"list\",\"has_more\":false,\"data\":[{\"id\":\"m\",\"object\":\"model\",\"type\":\"model\",\"capabilities\":{\"input\":{\"image\":{\"supported\":true},\"pdf\":{\"supported\":true}},\"image_input\":{\"supported\":false},\"pdf_input\":{\"supported\":false},\"endpoints\":{\"messages\":{\"supported\":true}}}}]}", .image = true, .pdf = true },
        .{ .body = "{\"object\":\"list\",\"has_more\":false,\"data\":[{\"id\":\"m\",\"object\":\"model\",\"type\":\"model\",\"capabilities\":{\"input\":{\"image\":{\"supported\":false},\"pdf\":{\"supported\":false},\"document\":{\"supported\":true}},\"image_input\":{\"supported\":true},\"pdf_input\":{\"supported\":true},\"endpoints\":{\"messages\":{\"supported\":true}}}}]}", .image = false, .pdf = false },
        .{ .body = "{\"object\":\"list\",\"has_more\":false,\"data\":[{\"id\":\"m\",\"object\":\"model\",\"type\":\"model\",\"capabilities\":{\"input\":{\"image\":{\"supported\":true},\"document\":{\"supported\":true}},\"pdf_input\":{\"supported\":true},\"limits\":{\"document\":{\"formats\":[\"application/pdf\"]}},\"endpoints\":{\"messages\":{\"supported\":true}}}}]}", .image = true, .pdf = false },
        .{ .body = "{\"object\":\"list\",\"has_more\":false,\"data\":[{\"id\":\"m\",\"object\":\"model\",\"type\":\"model\",\"capabilities\":{\"image_input\":{\"supported\":true},\"pdf_input\":{\"supported\":true},\"endpoints\":{\"messages\":{\"supported\":true}}}}]}", .image = false, .pdf = false },
        .{ .body = "{\"object\":\"list\",\"has_more\":false,\"data\":[{\"id\":\"m\",\"object\":\"model\",\"type\":\"model\",\"capabilities\":{\"endpoints\":{\"messages\":{\"supported\":true,\"input\":[\"image\",\"pdf\"]}}}}]}", .image = false, .pdf = false },
    };
    for (cases) |case| {
        var parsed = try parseModels(std.testing.allocator, case.body);
        defer parsed.deinit();
        try std.testing.expectEqual(@as(usize, 1), parsed.entries.items.len);
        const caps = parsed.entries.items[0].metadata.capabilities;
        try std.testing.expectEqual(@as(?bool, case.image), caps.image_input);
        try std.testing.expectEqual(@as(?bool, case.pdf), caps.pdf_input);
    }
}

test "input declarations reject malformed known fields" {
    const inputs = [_][]const u8{
        "true",
        "[]",
        "{\"image\":false}",
        "{\"image\":{\"supported\":1}}",
        "{\"pdf\":true}",
        "{\"pdf\":{\"supported\":\"true\"}}",
        "{\"pdf\":{\"supported\":[]}}",
    };
    for (inputs) |input| {
        const body = try std.fmt.allocPrint(std.testing.allocator, "{{\"object\":\"list\",\"has_more\":false,\"data\":[{{\"id\":\"m\",\"object\":\"model\",\"type\":\"model\",\"capabilities\":{{\"input\":{s},\"endpoints\":{{\"messages\":{{\"supported\":true}}}}}}}}]}}", .{input});
        defer std.testing.allocator.free(body);
        try std.testing.expectError(error.ProtocolInvalid, parseModels(std.testing.allocator, body));
    }
}

test "all global input and output supported declarations use exact booleans" {
    inline for (.{ "input", "output" }) |direction| {
        inline for (if (comptime std.mem.eql(u8, direction, "input")) .{ "text", "image", "pdf", "audio", "video" } else .{ "text", "image", "audio", "video", "embedding" }) |kind| {
            inline for (.{ "true", "false", "null" }) |flag| {
                const body = "{\"object\":\"list\",\"has_more\":false,\"data\":[{\"id\":\"m\",\"object\":\"model\",\"type\":\"model\",\"capabilities\":{\"endpoints\":{\"messages\":{\"supported\":true}},\"" ++ direction ++ "\":{\"" ++ kind ++ "\":{\"supported\":" ++ flag ++ "}}}}]}";
                var parsed = try parseModels(std.testing.allocator, body);
                defer parsed.deinit();
                const caps = parsed.entries.items[0].metadata.capabilities;
                const actual = if (comptime std.mem.eql(u8, direction, "input")) @field(caps, kind ++ "_input") else @field(caps.output, kind);
                try std.testing.expectEqual(@as(?bool, std.mem.eql(u8, flag, "true")), actual);
            }
            inline for (.{ "1", "\"true\"", "[]", "{}" }) |flag| {
                const body = "{\"object\":\"list\",\"has_more\":false,\"data\":[{\"id\":\"m\",\"object\":\"model\",\"type\":\"model\",\"capabilities\":{\"" ++ direction ++ "\":{\"" ++ kind ++ "\":{\"supported\":" ++ flag ++ "}}}}]}";
                try std.testing.expectError(error.ProtocolInvalid, parseModels(std.testing.allocator, body));
            }
        }
    }
}

test "root tokens and full modalities survive catalog ownership and authoritative replacement" {
    const body =
        \\{"object":"list","has_more":false,"data":[{"id":"m","object":"model","type":"model",
        \\"max_input_tokens":1000000,"max_tokens":131072,"capabilities":{"endpoints":{"responses":{"supported":true}},
        \\"input":{"text":{"supported":true},"image":{"supported":true},"pdf":{"supported":true},"audio":{"supported":true},"video":{"supported":true}},
        \\"output":{"text":{"supported":true},"image":{"supported":true},"audio":{"supported":true},"video":{"supported":true},"embedding":{"supported":true}},
        \\"limits":{"max_input_tokens":1,"max_output_tokens":2}}}]}
    ;
    var session = CatalogSession.init(std.testing.allocator);
    defer session.deinit();
    const catalog = try std.testing.allocator.create(PublicCatalog);
    defer std.testing.allocator.destroy(catalog);
    catalog.* = .{};
    try TestSupport.loadCatalogResponse(&session, "principal", "access", body);
    catalog.replaceFromSession(&session);
    session.reset();
    const metadata = catalog.modelViews()[0].metadata;
    try std.testing.expectEqual(@as(?u64, 1000000), metadata.max_input_tokens);
    try std.testing.expectEqual(@as(?u64, 131072), metadata.max_output_tokens);
    inline for (.{ "text", "image", "pdf", "audio", "video" }) |kind|
        try std.testing.expectEqual(@as(?bool, true), @field(metadata.capabilities, kind ++ "_input"));
    inline for (.{ "text", "image", "audio", "video", "embedding" }) |kind|
        try std.testing.expectEqual(@as(?bool, true), @field(metadata.capabilities.output, kind));
    try TestSupport.loadCatalogResponse(&session, "principal", "access", model_fixture);
    catalog.replaceFromSession(&session);
    try std.testing.expectEqualDeep(contract.ModelMetadata{ .capabilities = (ModelCapabilitiesWire{}).projection() }, catalog.modelViews()[0].metadata);
}

test "root token fields are authoritative and nested limits are ignored" {
    const cases = [_]struct { root: []const u8, limits: []const u8, input: ?u64 = null, output: ?u64 = null }{
        .{ .root = ",\"max_input_tokens\":12,\"max_tokens\":34", .limits = "{\"max_input_tokens\":56,\"max_output_tokens\":78}", .input = 12, .output = 34 },
        .{ .root = "", .limits = "{\"max_input_tokens\":56,\"max_output_tokens\":78}" },
        .{ .root = ",\"max_input_tokens\":null,\"max_tokens\":0", .limits = "{\"max_input_tokens\":56,\"max_output_tokens\":78}" },
        .{ .root = ",\"max_input_tokens\":12,\"max_tokens\":34", .limits = "false", .input = 12, .output = 34 },
        .{ .root = ",\"max_input_tokens\":12,\"max_tokens\":34", .limits = "{\"max_input_tokens\":-1,\"image\":{\"formats\":[1]}}", .input = 12, .output = 34 },
    };
    for (cases) |case| {
        const body = try std.fmt.allocPrint(std.testing.allocator, "{{\"object\":\"list\",\"has_more\":false,\"data\":[{{\"id\":\"m\",\"object\":\"model\",\"type\":\"model\"{s},\"capabilities\":{{\"limits\":{s},\"endpoints\":{{\"messages\":{{\"supported\":true}}}}}}}}]}}", .{ case.root, case.limits });
        defer std.testing.allocator.free(body);
        var parsed = try parseModels(std.testing.allocator, body);
        defer parsed.deinit();
        try std.testing.expectEqual(case.input, parsed.entries.items[0].metadata.max_input_tokens);
        try std.testing.expectEqual(case.output, parsed.entries.items[0].metadata.max_output_tokens);
    }
}
