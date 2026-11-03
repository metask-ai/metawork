//! Product Models value contract.
//!
//! This leaf owns the protocol axis, frozen execution configuration, and
//! user-managed custom-provider values. It has no runtime, Account, Agent,
//! Application, Bridge, or persistence dependency.

const std = @import("std");

pub const Limits = struct {
    pub const instance_id_bytes: usize = 128;
    pub const provider_id_bytes: usize = @tagName(Source.custom_provider).len + 1 + instance_id_bytes;
    pub const display_name_bytes: usize = 256;
    pub const model_id_bytes: usize = 256;
    pub const model_display_name_bytes: usize = 256;
    pub const base_url_bytes: usize = 2048;
    pub const credential_bytes: usize = 4096;
    pub const principal_ref_bytes: usize = 256;
    pub const safe_diagnostic_bytes: usize = 512;
    pub const model_entries: usize = 512;
    pub const custom_provider_entries: usize = 8;
    pub const custom_provider_model_entries: usize = 16;
};

pub const metask_source_id = "metask";
pub const metask_anthropic_messages_url =
    "https://www.metask-ai.com/v1/messages";
pub const metask_default_image_model = "gemini-3.1-flash-image-preview";
pub const metask_images_generations_url =
    "https://www.metask-ai.com/v1/images/generations";

pub fn metaskEndpoint(protocol: Protocol) ?[]const u8 {
    return switch (protocol) {
        .anthropic_messages => metask_anthropic_messages_url,
        .openai_responses => "https://www.metask-ai.com/v1/responses",
        .openai_chat_completions => "https://www.metask-ai.com/v1/chat/completions",
        .gemini_native => null,
    };
}

pub const ModelRef = struct {
    source_id: []const u8,
    model_id: []const u8,
};

pub const Source = enum {
    metask,
    custom_provider,
};

/// Exact request/response wire dialect. This is not a vendor category.
pub const Protocol = enum {
    openai_responses,
    anthropic_messages,
    openai_chat_completions,
    gemini_native,
};

/// Stable identity for a MetaWork-maintained official Provider recipe. This
/// selects configuration policy only; Agent execution still consumes the
/// explicit Protocol and endpoint stored on the resulting Provider.
pub const BuiltinProviderId = enum {
    deepseek,
    kimi,
    minimax,
    glm,
};

pub const BuiltinProviderPresetView = struct {
    id: BuiltinProviderId,
    display_name: []const u8,
    protocol: Protocol,
    default_base_url: []const u8,
    api_key_url: []const u8,
    documentation_url: []const u8,
    model_ids: []const []const u8,
};

pub const CatalogState = enum {
    needs_authentication,
    loading,
    choosing,
    ready,
    failed,
    unavailable,
};

pub const PersistenceHealth = enum {
    ready,
    recovery_required,
    unavailable,
};

pub const ModelsOperation = enum {
    idle,
    refreshing_catalog,
};

pub const ModelsError = enum {
    none,
    preference_not_saved,
    authorization_unavailable,
    persistence_unavailable,
    catalog_unavailable,
    catalog_invalid,
    catalog_too_large,
    no_models,
    operation_in_progress,
    local_resource_exhausted,
};

/// Provider declarations, not MetaWork feature gates. null means unknown.
pub const ModelCapabilities = struct {
    text_input: ?bool = null,
    audio_input: ?bool = null,
    video_input: ?bool = null,
    output: struct {
        text: ?bool = null,
        image: ?bool = null,
        audio: ?bool = null,
        video: ?bool = null,
        embedding: ?bool = null,
    } = .{},
    image_input: ?bool = null,
    pdf_input: ?bool = null,
    batch: ?bool = null,
    citations: ?bool = null,
    code_execution: ?bool = null,
    structured_outputs: ?bool = null,
    thinking: struct {
        supported: ?bool = null,
        adaptive: ?bool = null,
        enabled: ?bool = null,
    } = .{},
    effort: struct {
        supported: ?bool = null,
        low: ?bool = null,
        medium: ?bool = null,
        high: ?bool = null,
        max: ?bool = null,
    } = .{},
    context_management: struct {
        supported: ?bool = null,
        clear_thinking_20251015: ?bool = null,
        clear_tool_uses_20250919: ?bool = null,
        compact_20260112: ?bool = null,
    } = .{},
};

pub const ModelMetadata = struct {
    max_input_tokens: ?u64 = null,
    max_output_tokens: ?u64 = null,
    capabilities: ModelCapabilities = .{},
};

pub const ModelMetadataProvenance = enum {
    unknown,
    user_declared,
    provider_declared,
    runtime_verified,
};

pub const ModelView = struct {
    id: []const u8,
    display_name: []const u8,
    metadata: ModelMetadata = .{},
    metadata_provenance: ModelMetadataProvenance = .provider_declared,
};

pub const ProviderView = struct {
    id: []const u8,
    display_name: []const u8,
    recommended: bool,
    catalog_state: CatalogState,
    principal_ref: []const u8 = "",
    models: []const ModelView = &.{},
    catalog_generation: u64 = 0,
    source_generation: u64 = 0,
    error_code: ModelsError = .none,
    safe_diagnostic: []const u8 = "",
};

pub const ModelsView = struct {
    availability: CatalogState,
    persistence_health: PersistenceHealth,
    providers: []const ProviderView = &.{},
    default_selection: ?ModelRef = null,
    selection_revision: u64 = 0,
    operation: ModelsOperation = .idle,
    error_code: ModelsError = .none,
    builtin_provider_presets: []const BuiltinProviderPresetView = &.{},
    custom_providers: []const CustomProviderView = &.{},
};

pub const CatalogRefreshPreparation = struct {
    attempt_id: u64,
    principal_ref: []const u8,
    authorization_generation: u64,
};

pub const CatalogRefreshPrepareResult = union(enum) {
    ready: CatalogRefreshPreparation,
    rejected: ModelsError,
};

/// Route-scoped declarations frozen with an execution binding. Unknown models
/// are omitted; an explicit false remains an authoritative declaration.
pub const ModelImageCapability = struct {
    model: []const u8,
    supported: bool,
};

pub const max_model_image_capabilities: usize = 256;

pub fn sameImageCapabilities(a: []const ModelImageCapability, b: []const ModelImageCapability) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (!std.mem.eql(u8, left.model, right.model) or left.supported != right.supported) return false;
    }
    return true;
}

pub const OwnedImageCapabilities = struct {
    allocator: ?std.mem.Allocator = null,
    entries: []const ModelImageCapability = &.{},

    pub fn copy(allocator: std.mem.Allocator, entries: []const ModelImageCapability) std.mem.Allocator.Error!OwnedImageCapabilities {
        if (entries.len == 0) return .{};
        const owned = try allocator.alloc(ModelImageCapability, entries.len);
        var copied: usize = 0;
        errdefer {
            for (owned[0..copied]) |entry| allocator.free(entry.model);
            allocator.free(owned);
        }
        for (entries, 0..) |entry, index| {
            owned[index] = .{ .model = try allocator.dupe(u8, entry.model), .supported = entry.supported };
            copied += 1;
        }
        return .{ .allocator = allocator, .entries = owned };
    }

    pub fn take(self: *OwnedImageCapabilities) OwnedImageCapabilities {
        const result = self.*;
        self.* = .{};
        return result;
    }

    pub fn deinit(self: *OwnedImageCapabilities) void {
        if (self.allocator) |allocator| {
            for (self.entries) |entry| allocator.free(entry.model);
            allocator.free(self.entries);
        }
        self.* = .{};
    }
};

pub const Target = struct {
    image_capabilities: []const ModelImageCapability = &.{},
    /// Source-qualified service instance reference; never a wire adapter name.
    provider_id: []const u8,
    protocol: Protocol,
    model: []const u8,
    base_url: []const u8,
};

pub const ConfigInput = struct {
    target: Target,
    api_key: []const u8,
    execution_generation: u64,
};

/// Credential-bearing input produced by a source owner before Product Control
/// assigns an execution generation. `source_generation` identifies the source
/// authority only; it must never be copied into `execution_generation` by
/// convention or assumed to share its numeric value.
pub const SourceCandidateInput = struct {
    target: Target,
    api_key: []const u8,
    source_generation: u64,
};

pub const CustomProviderState = enum {
    configuring,
    ready,
    disabled,
};

pub const CustomModelTestStatus = enum {
    untested,
    testing,
    connected,
    failed,
};

pub const CustomProviderCredentialStatus = enum {
    missing,
    ready,
    invalid,
    capture_unavailable,
};

pub const CustomProviderModelView = struct {
    id: []const u8,
    display_name: []const u8 = "",
    metadata: ModelMetadata = .{},
    metadata_provenance: ModelMetadataProvenance = .unknown,
    test_status: CustomModelTestStatus = .untested,
    /// A successful probe for the current source authority exists. A later
    /// failed retry updates test_status without revoking that proof.
    ready: bool = false,
};

pub const CustomProviderView = struct {
    id: []const u8,
    builtin_provider_id: ?BuiltinProviderId = null,
    display_name: []const u8,
    protocol: Protocol,
    normalized_base_url: []const u8,
    state: CustomProviderState,
    credential_status: CustomProviderCredentialStatus,
    enabled: bool,
    models: []const CustomProviderModelView = &.{},
    provider_revision: u64,
    source_generation: u64,
    catalog_generation: u64,
};

pub const CustomProviderSpec = struct {
    builtin_provider_id: ?BuiltinProviderId = null,
    display_name: []const u8,
    protocol: Protocol,
    normalized_base_url: []const u8,
    initial_model: ?CustomModelInput = null,
};

pub const CustomProviderCredentialSlot = struct {
    id: []const u8,
};

pub const CustomProviderSelectionCommand = struct {
    source_id: []const u8,
    expected_provider_revision: u64,
};

pub const CustomModelInput = struct {
    id: []const u8,
    display_name: []const u8 = "",
    metadata: ModelMetadata = .{},
};

pub const CustomProviderCreateCommand = struct {
    provider_id: []const u8,
    spec: CustomProviderSpec,
    credential_slot: CustomProviderCredentialSlot,
};

pub const CustomProviderUpdateCommand = struct {
    selection: CustomProviderSelectionCommand,
    spec: CustomProviderSpec,
};

pub const CustomModelTestCommand = struct {
    model: ModelRef,
    expected_provider_revision: u64,
    expected_source_generation: u64,
    expected_catalog_generation: u64,
};

pub const CustomModelAddCommand = struct {
    source_id: []const u8,
    expected_provider_revision: u64,
    expected_catalog_generation: u64,
    model: CustomModelInput,
};

pub const CustomModelReplaceCommand = struct {
    selection: ModelRef,
    expected_provider_revision: u64,
    expected_catalog_generation: u64,
    replacement: CustomModelInput,
};

pub const CustomModelRemoveCommand = struct {
    selection: ModelRef,
    expected_provider_revision: u64,
    expected_catalog_generation: u64,
};

/// Borrowed only during preparation, from the Host's current authorization
/// lease. Models does not acquire, cache, refresh or persist this authorization.
pub const ImagePreparationInput = struct {
    principal_ref: []const u8,
    authorization_generation: u64,
    bearer: []const u8,
};

pub const ImageCandidateInput = struct {
    selection: ModelRef,
    endpoint: []const u8,
    bearer: []const u8,
    catalog_generation: u64,
};

pub const ImagePreparation = union(enum) {
    ready: OwnedImageCandidate,
    rejected: ManagementError,
};

pub const CustomProviderCommand = union(enum) {
    create: CustomProviderCreateCommand,
    update: CustomProviderUpdateCommand,
    remove: CustomProviderSelectionCommand,
    test_model: CustomModelTestCommand,
    add_custom_model: CustomModelAddCommand,
    replace_custom_model: CustomModelReplaceCommand,
    remove_custom_model: CustomModelRemoveCommand,
};

/// Product-internal Models management result. Bridge adapters may map these
/// stable failures onto the Renderer wire error vocabulary.
pub const ManagementError = enum {
    authorization_unavailable,
    catalog_unavailable,
    invalid_provider,
    provider_not_found,
    generation_mismatch,
    model_not_found,
    capacity,
    persistence_unavailable,
    capture_unavailable,
    credential_write_failed,
    operation_in_progress,
    test_unavailable,
    user_cancelled,
    local_resource_exhausted,
};

pub const CommandResult = struct {
    accepted: bool,
    error_code: ?ManagementError = null,

    pub fn acceptedResult() CommandResult {
        return .{ .accepted = true };
    }

    pub fn rejected(error_code: ManagementError) CommandResult {
        return .{ .accepted = false, .error_code = error_code };
    }
};

pub const CommandSink = struct {
    context: *anyopaque,
    submit_fn: *const fn (*anyopaque, CustomProviderCommand) CommandResult,

    pub fn submit(self: CommandSink, command: CustomProviderCommand) CommandResult {
        return self.submit_fn(self.context, command);
    }
};

pub const Preparation = union(enum) {
    ready: OwnedConfig,
    rejected: ManagementError,
};

pub const ValidationError = error{
    FieldEmpty,
    FieldTooLarge,
    CollectionTooLarge,
    InvalidGeneration,
    InvalidBaseUrl,
    InvalidEncoding,
    InvalidMetadata,
    InconsistentState,
    SecretExposed,
    UnsupportedProtocol,
};

const SecretBuffer = struct {
    allocator: std.mem.Allocator = undefined,
    bytes: []u8 = &.{},
    owned: bool = false,

    fn initOwned(allocator: std.mem.Allocator, bytes: []u8) SecretBuffer {
        std.debug.assert(bytes.len > 0);
        return .{ .allocator = allocator, .bytes = bytes, .owned = true };
    }

    fn take(self: *SecretBuffer) SecretBuffer {
        std.debug.assert(self.owned);
        const result = self.*;
        self.* = .{};
        return result;
    }

    fn view(self: *const SecretBuffer) []const u8 {
        std.debug.assert(self.owned);
        return self.bytes;
    }

    fn deinit(self: *SecretBuffer) void {
        if (!self.owned) return;
        secureFree(self.allocator, self.bytes);
        self.* = .{};
    }
};

const OwnedBuffer = struct {
    allocator: std.mem.Allocator = undefined,
    bytes: []u8 = &.{},
    owned: bool = false,

    fn initOwned(allocator: std.mem.Allocator, bytes: []u8) OwnedBuffer {
        std.debug.assert(bytes.len > 0);
        return .{ .allocator = allocator, .bytes = bytes, .owned = true };
    }

    fn take(self: *OwnedBuffer) OwnedBuffer {
        std.debug.assert(self.owned);
        const result = self.*;
        self.* = .{};
        return result;
    }

    fn view(self: *const OwnedBuffer) []const u8 {
        std.debug.assert(self.owned);
        return self.bytes;
    }

    fn deinit(self: *OwnedBuffer) void {
        if (!self.owned) return;
        self.allocator.free(self.bytes);
        self.* = .{};
    }
};

/// Linear image input with one Models-owned target. No dialogue protocol,
/// principal or authorization generation is transferred to the executor.
pub const OwnedImageCandidate = struct {
    model: OwnedBuffer,
    secret: SecretBuffer,
    catalog_generation: u64,

    pub fn copy(
        allocator: std.mem.Allocator,
        model: []const u8,
        bearer: []const u8,
        catalog_generation: u64,
    ) (ValidationError || std.mem.Allocator.Error)!OwnedImageCandidate {
        try validateRequired(model, Limits.model_id_bytes);
        for (model) |byte| if (std.ascii.isControl(byte)) return error.InvalidEncoding;
        try validateOpaqueRequired(bearer, Limits.credential_bytes);
        if (catalog_generation == 0) return error.InvalidGeneration;
        const owned_model = try allocator.dupe(u8, model);
        errdefer allocator.free(owned_model);
        const owned_bearer = try allocator.dupe(u8, bearer);
        return .{
            .model = .initOwned(allocator, owned_model),
            .secret = .initOwned(allocator, owned_bearer),
            .catalog_generation = catalog_generation,
        };
    }

    pub fn input(self: *const OwnedImageCandidate) ImageCandidateInput {
        return .{
            .selection = .{ .source_id = metask_source_id, .model_id = self.model.view() },
            .endpoint = metask_images_generations_url,
            .bearer = self.secret.view(),
            .catalog_generation = self.catalog_generation,
        };
    }

    pub fn take(self: *OwnedImageCandidate) OwnedImageCandidate {
        return .{
            .model = self.model.take(),
            .secret = self.secret.take(),
            .catalog_generation = self.catalog_generation,
        };
    }

    pub fn deinit(self: *OwnedImageCandidate) void {
        self.secret.deinit();
        self.model.deinit();
        self.catalog_generation = 0;
    }
};

/// Linear candidate transferred from an execution source into Product
/// Control. It deliberately has no Product execution generation.
pub const OwnedSourceCandidate = struct {
    image_capabilities: OwnedImageCapabilities = .{},
    provider_id: OwnedBuffer,
    protocol: Protocol,
    model: OwnedBuffer,
    base_url: OwnedBuffer,
    source_generation: u64,
    secret: SecretBuffer,
    source: Source,

    pub fn initOwned(
        allocator: std.mem.Allocator,
        source: Source,
        protocol: Protocol,
        owned_model: []u8,
        owned_base_url: []u8,
        source_generation: u64,
        owned_api_key: []u8,
        instance_id: []const u8,
    ) (error{InvalidSourceCandidate} || std.mem.Allocator.Error)!OwnedSourceCandidate {
        errdefer allocator.free(owned_model);
        errdefer allocator.free(owned_base_url);
        errdefer secureFree(allocator, owned_api_key);
        const provider_id = switch (source) {
            .metask => blk: {
                if (instance_id.len != 0) return error.InvalidSourceCandidate;
                break :blk try allocator.dupe(u8, metask_source_id);
            },
            .custom_provider => blk: {
                validateRequired(instance_id, Limits.instance_id_bytes) catch
                    return error.InvalidSourceCandidate;
                break :blk try std.fmt.allocPrint(
                    allocator,
                    "{s}:{s}",
                    .{ @tagName(source), instance_id },
                );
            },
        };
        errdefer allocator.free(provider_id);
        const candidate_input: SourceCandidateInput = .{
            .target = .{
                .provider_id = provider_id,
                .protocol = protocol,
                .model = owned_model,
                .base_url = owned_base_url,
            },
            .api_key = owned_api_key,
            .source_generation = source_generation,
        };
        validateSourceCandidateStructure(candidate_input) catch
            return error.InvalidSourceCandidate;
        return .{
            .provider_id = .initOwned(allocator, provider_id),
            .protocol = protocol,
            .model = .initOwned(allocator, owned_model),
            .base_url = .initOwned(allocator, owned_base_url),
            .source_generation = source_generation,
            .secret = .initOwned(allocator, owned_api_key),
            .source = source,
        };
    }

    pub fn take(self: *OwnedSourceCandidate) OwnedSourceCandidate {
        return .{
            .image_capabilities = self.image_capabilities.take(),
            .provider_id = self.provider_id.take(),
            .protocol = self.protocol,
            .model = self.model.take(),
            .base_url = self.base_url.take(),
            .source_generation = self.source_generation,
            .secret = self.secret.take(),
            .source = self.source,
        };
    }

    pub fn input(self: *const OwnedSourceCandidate) SourceCandidateInput {
        return .{
            .target = .{
                .image_capabilities = self.image_capabilities.entries,
                .provider_id = self.provider_id.view(),
                .protocol = self.protocol,
                .model = self.model.view(),
                .base_url = self.base_url.view(),
            },
            .api_key = self.secret.view(),
            .source_generation = self.source_generation,
        };
    }

    /// Product Control is the only caller allowed to assign this generation.
    pub fn intoConfig(
        self: *OwnedSourceCandidate,
        execution_generation: u64,
    ) error{InvalidExecutionConfig}!OwnedConfig {
        if (execution_generation == 0) return error.InvalidExecutionConfig;
        var result: OwnedConfig = .{
            .image_capabilities = self.image_capabilities.take(),
            .provider_id = self.provider_id.take(),
            .protocol = self.protocol,
            .model = self.model.take(),
            .base_url = self.base_url.take(),
            .execution_generation = execution_generation,
            .secret = self.secret.take(),
            .source = self.source,
        };
        self.source_generation = 0;
        validateConfigStructure(result.input()) catch {
            result.deinit();
            return error.InvalidExecutionConfig;
        };
        return result;
    }

    pub fn deinit(self: *OwnedSourceCandidate) void {
        self.image_capabilities.deinit();
        self.provider_id.deinit();
        self.model.deinit();
        self.base_url.deinit();
        self.secret.deinit();
        self.protocol = undefined;
        self.source_generation = 0;
        self.source = undefined;
    }
};

/// Linear resolved configuration carrying a generation assigned by its
/// receiving owner. The provider does not choose that consumer identity.
pub const OwnedConfig = struct {
    image_capabilities: OwnedImageCapabilities = .{},
    provider_id: OwnedBuffer,
    protocol: Protocol,
    model: OwnedBuffer,
    base_url: OwnedBuffer,
    execution_generation: u64,
    secret: SecretBuffer,
    source: Source,

    pub fn initOwned(
        allocator: std.mem.Allocator,
        source: Source,
        protocol: Protocol,
        owned_model: []u8,
        owned_base_url: []u8,
        execution_generation: u64,
        owned_api_key: []u8,
        instance_id: []const u8,
    ) (error{InvalidExecutionConfig} || std.mem.Allocator.Error)!OwnedConfig {
        errdefer allocator.free(owned_model);
        errdefer allocator.free(owned_base_url);
        errdefer secureFree(allocator, owned_api_key);
        const provider_id = switch (source) {
            .metask => blk: {
                if (instance_id.len != 0) return error.InvalidExecutionConfig;
                break :blk try allocator.dupe(u8, metask_source_id);
            },
            .custom_provider => blk: {
                validateRequired(instance_id, Limits.instance_id_bytes) catch
                    return error.InvalidExecutionConfig;
                break :blk try std.fmt.allocPrint(
                    allocator,
                    "{s}:{s}",
                    .{ @tagName(source), instance_id },
                );
            },
        };
        errdefer allocator.free(provider_id);
        const config_input: ConfigInput = .{
            .target = .{
                .provider_id = provider_id,
                .protocol = protocol,
                .model = owned_model,
                .base_url = owned_base_url,
            },
            .api_key = owned_api_key,
            .execution_generation = execution_generation,
        };
        validateConfigStructure(config_input) catch return error.InvalidExecutionConfig;
        if (source == .custom_provider)
            validateCustomProviderExecutionConfig(config_input) catch
                return error.InvalidExecutionConfig;
        return .{
            .provider_id = .initOwned(allocator, provider_id),
            .protocol = protocol,
            .model = .initOwned(allocator, owned_model),
            .base_url = .initOwned(allocator, owned_base_url),
            .execution_generation = execution_generation,
            .secret = .initOwned(allocator, owned_api_key),
            .source = source,
        };
    }

    pub fn take(self: *OwnedConfig) OwnedConfig {
        return .{
            .image_capabilities = self.image_capabilities.take(),
            .provider_id = self.provider_id.take(),
            .protocol = self.protocol,
            .model = self.model.take(),
            .base_url = self.base_url.take(),
            .execution_generation = self.execution_generation,
            .secret = self.secret.take(),
            .source = self.source,
        };
    }

    pub fn input(self: *const OwnedConfig) ConfigInput {
        return .{
            .target = .{
                .image_capabilities = self.image_capabilities.entries,
                .provider_id = self.provider_id.view(),
                .protocol = self.protocol,
                .model = self.model.view(),
                .base_url = self.base_url.view(),
            },
            .api_key = self.secret.view(),
            .execution_generation = self.execution_generation,
        };
    }

    pub fn deinit(self: *OwnedConfig) void {
        self.image_capabilities.deinit();
        self.provider_id.deinit();
        self.model.deinit();
        self.base_url.deinit();
        self.secret.deinit();
        self.protocol = undefined;
        self.execution_generation = 0;
        self.source = undefined;
    }
};

pub fn customProviderProtocolAvailable(protocol: Protocol) bool {
    return switch (protocol) {
        .openai_responses,
        .anthropic_messages,
        .openai_chat_completions,
        .gemini_native,
        => true,
    };
}

pub fn validateCustomProviderCommand(command: CustomProviderCommand) ValidationError!void {
    switch (command) {
        .create => |value| {
            try validateRequired(value.provider_id, Limits.instance_id_bytes);
            try validateCustomProviderSpec(value.spec);
            try validateRequired(value.credential_slot.id, Limits.instance_id_bytes);
        },
        .update => |value| {
            try validateRequired(value.selection.source_id, Limits.instance_id_bytes);
            if (value.selection.expected_provider_revision == 0)
                return error.InvalidGeneration;
            try validateCustomProviderSpec(value.spec);
        },
        .remove => |value| {
            try validateRequired(value.source_id, Limits.instance_id_bytes);
            if (value.expected_provider_revision == 0)
                return error.InvalidGeneration;
        },
        .test_model => |value| {
            try validateRequired(value.model.source_id, Limits.instance_id_bytes);
            try validateRequired(value.model.model_id, Limits.model_id_bytes);
            if (value.expected_provider_revision == 0 or
                value.expected_source_generation == 0 or
                value.expected_catalog_generation == 0)
                return error.InvalidGeneration;
        },
        .add_custom_model => |value| {
            try validateRequired(value.source_id, Limits.instance_id_bytes);
            if (value.expected_provider_revision == 0 or
                value.expected_catalog_generation == 0)
                return error.InvalidGeneration;
            try validateCustomModelInput(value.model);
        },
        .replace_custom_model => |value| {
            try validateRequired(value.selection.source_id, Limits.instance_id_bytes);
            try validateRequired(value.selection.model_id, Limits.model_id_bytes);
            if (value.expected_provider_revision == 0 or
                value.expected_catalog_generation == 0)
                return error.InvalidGeneration;
            try validateCustomModelInput(value.replacement);
        },
        .remove_custom_model => |value| {
            try validateRequired(value.selection.source_id, Limits.instance_id_bytes);
            try validateRequired(value.selection.model_id, Limits.model_id_bytes);
            if (value.expected_provider_revision == 0 or
                value.expected_catalog_generation == 0)
                return error.InvalidGeneration;
        },
    }
}

pub fn validateCustomModelInput(model: CustomModelInput) ValidationError!void {
    try validateRequired(model.id, Limits.model_id_bytes);
    try validateOptional(model.display_name, Limits.model_display_name_bytes);
    if ((model.metadata.max_input_tokens orelse 1) == 0 or
        (model.metadata.max_output_tokens orelse 1) == 0)
        return error.InvalidMetadata;
}

pub fn validateCustomProviderSpec(spec: CustomProviderSpec) ValidationError!void {
    if (spec.initial_model) |model| try validateCustomModelInput(model);
    try validateRequired(spec.display_name, Limits.display_name_bytes);
    try validateRequired(spec.normalized_base_url, Limits.base_url_bytes);
    if (!customProviderProtocolAvailable(spec.protocol))
        return error.UnsupportedProtocol;
    if (!validCustomProviderEndpoint(spec.protocol, spec.normalized_base_url))
        return error.InvalidBaseUrl;
}

pub fn validCustomProviderEndpoint(protocol: Protocol, value: []const u8) bool {
    if (value.len == 0 or value.len > Limits.base_url_bytes or
        !std.unicode.utf8ValidateSlice(value)) return false;
    for (value) |byte| if (byte <= 0x20 or byte == 0x7f or byte == '\\')
        return false;
    const uri = std.Uri.parse(value) catch return false;
    if (uri.user != null or uri.password != null or uri.query != null or
        uri.fragment != null or uri.host == null) return false;
    const is_https = std.ascii.eqlIgnoreCase(uri.scheme, "https");
    const is_http_loopback = std.ascii.eqlIgnoreCase(uri.scheme, "http") and
        isLoopbackHost(uri.host.?);
    if (!is_https and !is_http_loopback) return false;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |bytes| bytes,
    };
    return switch (protocol) {
        .openai_responses => std.mem.endsWith(u8, path, "/responses"),
        .anthropic_messages => std.mem.endsWith(u8, path, "/v1/messages"),
        .openai_chat_completions => std.mem.endsWith(u8, path, "/chat/completions"),
        .gemini_native => path.len == 0 or std.mem.eql(u8, path, "/"),
    };
}

pub fn validProviderBaseUrl(value: []const u8) bool {
    if (value.len == 0 or value.len > Limits.base_url_bytes or
        !std.unicode.utf8ValidateSlice(value)) return false;
    for (value) |byte| if (byte <= 0x20 or byte == 0x7f or byte == '\\')
        return false;
    const uri = std.Uri.parse(value) catch return false;
    if (uri.user != null or uri.password != null or uri.query != null or
        uri.fragment != null or uri.host == null) return false;
    const is_https = std.ascii.eqlIgnoreCase(uri.scheme, "https");
    const is_http_loopback = std.ascii.eqlIgnoreCase(uri.scheme, "http") and
        isLoopbackHost(uri.host.?);
    return is_https or is_http_loopback;
}

pub fn completionEndpointFromBaseUrlAlloc(
    allocator: std.mem.Allocator,
    protocol: Protocol,
    value: []const u8,
) (std.mem.Allocator.Error || ValidationError)![]u8 {
    if (!customProviderProtocolAvailable(protocol))
        return error.UnsupportedProtocol;
    if (!validProviderBaseUrl(value)) return error.InvalidBaseUrl;
    var base_url_end = value.len;
    while (base_url_end > 0 and value[base_url_end - 1] == '/') : (base_url_end -= 1) {}
    const base_url = value[0..base_url_end];
    const suffix = switch (protocol) {
        .openai_responses => "/responses",
        .anthropic_messages => "/v1/messages",
        .openai_chat_completions => "/chat/completions",
        .gemini_native => "",
    };
    if (base_url.len + suffix.len > Limits.base_url_bytes)
        return error.InvalidBaseUrl;
    const candidate = try std.mem.concat(allocator, u8, &.{ base_url, suffix });
    defer allocator.free(candidate);
    return normalizeCustomProviderEndpointAlloc(allocator, protocol, candidate);
}

pub fn normalizeCustomProviderEndpointAlloc(
    allocator: std.mem.Allocator,
    protocol: Protocol,
    value: []const u8,
) (std.mem.Allocator.Error || ValidationError)![]u8 {
    if (!customProviderProtocolAvailable(protocol))
        return error.UnsupportedProtocol;
    if (!validCustomProviderEndpoint(protocol, value))
        return error.InvalidBaseUrl;
    const scheme_end = std.mem.indexOf(u8, value, "://") orelse
        return error.InvalidBaseUrl;
    const authority_start = scheme_end + 3;
    const authority_end = std.mem.indexOfScalarPos(
        u8,
        value,
        authority_start,
        '/',
    ) orelse value.len;
    if (authority_start == authority_end or
        std.mem.indexOfScalar(u8, value[authority_start..authority_end], '%') != null)
        return error.InvalidBaseUrl;
    const omit_gemini_root = protocol == .gemini_native and
        authority_end + 1 == value.len and value[authority_end] == '/';
    const result_len = value.len - @intFromBool(omit_gemini_root);
    const result = try allocator.alloc(u8, result_len);
    errdefer allocator.free(result);
    for (value[0..scheme_end], 0..) |byte, index|
        result[index] = std.ascii.toLower(byte);
    @memcpy(result[scheme_end..authority_start], "://");
    for (value[authority_start..authority_end], authority_start..) |byte, index|
        result[index] = std.ascii.toLower(byte);
    if (authority_end < result_len)
        @memcpy(result[authority_end..], value[authority_end..result_len]);
    return result;
}

pub fn validateCustomProviderView(view: CustomProviderView) ValidationError!void {
    try validateRequired(view.id, Limits.instance_id_bytes);
    try validateRequired(view.display_name, Limits.display_name_bytes);
    try validateRequired(view.normalized_base_url, Limits.base_url_bytes);
    if (!customProviderProtocolAvailable(view.protocol))
        return error.UnsupportedProtocol;
    if (!validCustomProviderEndpoint(view.protocol, view.normalized_base_url))
        return error.InvalidBaseUrl;
    if (view.provider_revision == 0 or view.source_generation == 0 or
        view.catalog_generation == 0)
        return error.InvalidGeneration;
    if (view.models.len > Limits.custom_provider_model_entries)
        return error.CollectionTooLarge;
    if (view.models.len == 0 and view.state != .configuring)
        return error.InconsistentState;
    var ready_models: usize = 0;
    for (view.models, 0..) |model, index| {
        try validateCustomModelInput(.{
            .id = model.id,
            .display_name = model.display_name,
            .metadata = model.metadata,
        });
        if (model.ready) ready_models += 1;
        if ((model.test_status == .connected and !model.ready) or
            (model.ready and model.test_status == .untested))
            return error.InconsistentState;
        for (view.models[0..index]) |prior|
            if (std.mem.eql(u8, prior.id, model.id))
                return error.InconsistentState;
    }
    if (view.state == .ready and
        (view.credential_status != .ready or !view.enabled or ready_models == 0))
        return error.InconsistentState;
    if (view.state != .ready and ready_models != 0)
        return error.InconsistentState;
}

fn validateImageCapabilities(entries: []const ModelImageCapability) ValidationError!void {
    if (entries.len > max_model_image_capabilities) return error.CollectionTooLarge;
    for (entries, 0..) |entry, index| {
        try validateRequired(entry.model, Limits.model_id_bytes);
        for (entries[0..index]) |prior| {
            if (std.ascii.eqlIgnoreCase(prior.model, entry.model)) return error.InvalidMetadata;
        }
    }
}

pub fn validateConfigStructure(input: ConfigInput) ValidationError!void {
    try validateImageCapabilities(input.target.image_capabilities);
    try validateRequired(input.target.provider_id, Limits.provider_id_bytes);
    try validateRequired(input.target.model, Limits.model_id_bytes);
    try validateRequired(input.target.base_url, Limits.base_url_bytes);
    try validateOpaqueRequired(input.api_key, Limits.credential_bytes);
    if (input.execution_generation == 0) return error.InvalidGeneration;
}

pub fn validateSourceCandidateStructure(input: SourceCandidateInput) ValidationError!void {
    try validateImageCapabilities(input.target.image_capabilities);
    try validateRequired(input.target.provider_id, Limits.provider_id_bytes);
    try validateRequired(input.target.model, Limits.model_id_bytes);
    try validateRequired(input.target.base_url, Limits.base_url_bytes);
    try validateOpaqueRequired(input.api_key, Limits.credential_bytes);
    if (input.source_generation == 0) return error.InvalidGeneration;
}

pub fn validateMetaskSourceCandidate(input: SourceCandidateInput) ValidationError!void {
    try validateSourceCandidateStructure(input);
    if (!std.mem.eql(u8, input.target.provider_id, metask_source_id))
        return error.InconsistentState;
    const endpoint = metaskEndpoint(input.target.protocol) orelse return error.UnsupportedProtocol;
    if (!std.mem.eql(u8, input.target.base_url, endpoint))
        return error.InvalidBaseUrl;
}

pub fn validateCustomProviderExecutionConfig(input: ConfigInput) ValidationError!void {
    try validateConfigStructure(input);
    if (!customProviderProtocolAvailable(input.target.protocol))
        return error.UnsupportedProtocol;
    if (!validCustomProviderEndpoint(input.target.protocol, input.target.base_url))
        return error.InvalidBaseUrl;
}

fn isLoopbackHost(host: std.Uri.Component) bool {
    const value = switch (host) {
        .raw, .percent_encoded => |bytes| bytes,
    };
    return std.ascii.eqlIgnoreCase(value, "localhost") or
        std.mem.eql(u8, value, "127.0.0.1") or
        std.mem.eql(u8, value, "[::1]");
}

fn secureFree(allocator: std.mem.Allocator, bytes: []u8) void {
    if (bytes.len == 0) return;
    std.crypto.secureZero(u8, bytes);
    allocator.rawFree(bytes, .of(u8), @returnAddress());
}

fn validateRequired(value: []const u8, max_bytes: usize) ValidationError!void {
    if (value.len == 0) return error.FieldEmpty;
    try validateOptional(value, max_bytes);
}

fn validateOpaqueRequired(value: []const u8, max_bytes: usize) ValidationError!void {
    if (value.len == 0) return error.FieldEmpty;
    if (value.len > max_bytes) return error.FieldTooLarge;
}

fn validateOptional(value: []const u8, max_bytes: usize) ValidationError!void {
    if (value.len > max_bytes) return error.FieldTooLarge;
    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidEncoding;
}

const ObservingAllocator = struct {
    backing: std.mem.Allocator,
    secret_ptr: ?[*]u8 = null,
    secret_len: usize = 0,
    saw_secret_free: bool = false,
    secret_was_zero: bool = false,

    const Self = @This();
    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn allocator(self: *Self) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn observe(self: *Self, secret: []u8) void {
        self.secret_ptr = secret.ptr;
        self.secret_len = secret.len;
        self.saw_secret_free = false;
        self.secret_was_zero = false;
    }

    fn alloc(
        raw: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(raw));
        return self.backing.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(
        raw: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *Self = @ptrCast(@alignCast(raw));
        return self.backing.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(
        raw: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(raw));
        return self.backing.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(
        raw: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) void {
        const self: *Self = @ptrCast(@alignCast(raw));
        if (self.secret_ptr) |secret_ptr| {
            if (memory.ptr == secret_ptr and memory.len == self.secret_len) {
                self.saw_secret_free = true;
                self.secret_was_zero = true;
                for (memory) |byte| if (byte != 0) {
                    self.secret_was_zero = false;
                    break;
                };
            }
        }
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};

fn observingSourceCandidate(
    allocator: std.mem.Allocator,
    secret: []u8,
) !OwnedSourceCandidate {
    return OwnedSourceCandidate.initOwned(
        allocator,
        .metask,
        .anthropic_messages,
        try allocator.dupe(u8, "metask-model"),
        try allocator.dupe(u8, metask_anthropic_messages_url),
        7,
        secret,
        "",
    );
}

test "image candidate owns borrowed inputs and zeroes moved credentials" {
    var observing: ObservingAllocator = .{ .backing = std.testing.allocator };
    var model = "image-model".*;
    var bearer = "lease-secret".*;
    var candidate = try OwnedImageCandidate.copy(observing.allocator(), &model, &bearer, 7);
    observing.observe(candidate.secret.bytes);
    @memset(&model, 'x');
    @memset(&bearer, 0);
    var moved = candidate.take();
    candidate.deinit();
    try std.testing.expectEqualStrings("image-model", moved.input().selection.model_id);
    try std.testing.expectEqualStrings(metask_source_id, moved.input().selection.source_id);
    try std.testing.expectEqualStrings(metask_images_generations_url, moved.input().endpoint);
    try std.testing.expectEqualStrings("lease-secret", moved.input().bearer);
    try std.testing.expectEqual(@as(u64, 7), moved.input().catalog_generation);
    moved.deinit();
    try std.testing.expect(observing.saw_secret_free);
    try std.testing.expect(observing.secret_was_zero);
    try std.testing.expectError(error.FieldEmpty, OwnedImageCandidate.copy(std.testing.allocator, "image", "", 7));
    try std.testing.expectError(error.InvalidGeneration, OwnedImageCandidate.copy(std.testing.allocator, "image", "secret", 0));
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            var owned = try OwnedImageCandidate.copy(allocator, "image", "secret", 7);
            defer owned.deinit();
        }
    }.run, .{});
}

test "source candidate secure-zeroes rejected and released owned secrets" {
    var observing: ObservingAllocator = .{ .backing = std.testing.allocator };
    const allocator = observing.allocator();

    const rejected_secret = try allocator.dupe(u8, "rejected-secret");
    observing.observe(rejected_secret);
    try std.testing.expectError(
        error.InvalidSourceCandidate,
        OwnedSourceCandidate.initOwned(
            allocator,
            .metask,
            .anthropic_messages,
            try allocator.dupe(u8, "metask-model"),
            try allocator.dupe(u8, metask_anthropic_messages_url),
            0,
            rejected_secret,
            "key-1",
        ),
    );
    try std.testing.expect(observing.saw_secret_free);
    try std.testing.expect(observing.secret_was_zero);

    const released_secret = try allocator.dupe(u8, "released-secret");
    observing.observe(released_secret);
    var candidate = try observingSourceCandidate(allocator, released_secret);
    var moved = candidate.take();
    candidate.deinit();
    moved.deinit();
    try std.testing.expect(observing.saw_secret_free);
    try std.testing.expect(observing.secret_was_zero);
}

test "source candidate secure-zero survives intoConfig success and failure" {
    var observing: ObservingAllocator = .{ .backing = std.testing.allocator };
    const allocator = observing.allocator();

    const success_secret = try allocator.dupe(u8, "success-secret");
    observing.observe(success_secret);
    var success_candidate = try observingSourceCandidate(allocator, success_secret);
    var config = try success_candidate.intoConfig(29);
    success_candidate.deinit();
    config.deinit();
    try std.testing.expect(observing.saw_secret_free);
    try std.testing.expect(observing.secret_was_zero);

    const failed_secret = try allocator.dupe(u8, "failed-secret");
    observing.observe(failed_secret);
    var failed_candidate = try observingSourceCandidate(allocator, failed_secret);
    try std.testing.expectError(
        error.InvalidExecutionConfig,
        failed_candidate.intoConfig(0),
    );
    failed_candidate.deinit();
    try std.testing.expect(observing.saw_secret_free);
    try std.testing.expect(observing.secret_was_zero);
}

test "source candidate keeps source and execution generations independent" {
    const allocator = std.testing.allocator;
    var candidate = try OwnedSourceCandidate.initOwned(
        allocator,
        .metask,
        .anthropic_messages,
        try allocator.dupe(u8, "metask-model"),
        try allocator.dupe(u8, metask_anthropic_messages_url),
        7,
        try allocator.dupe(u8, "secret"),
        "",
    );
    defer candidate.deinit();

    try std.testing.expectEqual(@as(u64, 7), candidate.input().source_generation);
    var config = try candidate.intoConfig(29);
    defer config.deinit();
    try std.testing.expectEqual(@as(u64, 29), config.input().execution_generation);
    try std.testing.expectEqualStrings("metask", config.input().target.provider_id);
    try std.testing.expectEqualStrings("secret", config.input().api_key);
}

test "custom provider protocols have endpoint contracts" {
    inline for (.{
        .{ Protocol.openai_responses, "https://api.openai.com/v1/responses" },
        .{ Protocol.anthropic_messages, "https://api.anthropic.com/v1/messages" },
        .{ Protocol.anthropic_messages, "http://127.0.0.1:43123/v1/messages" },
        .{ Protocol.openai_chat_completions, "https://api.openai.com/v1/chat/completions" },
        .{ Protocol.openai_chat_completions, "https://open.bigmodel.cn/api/paas/v4/chat/completions" },
        .{ Protocol.anthropic_messages, "https://api.minimaxi.com/anthropic/v1/messages" },
        .{ Protocol.gemini_native, "https://generativelanguage.googleapis.com" },
    }) |case| try std.testing.expect(validCustomProviderEndpoint(case[0], case[1]));
    try validateCustomProviderSpec(.{
        .display_name = "Local Gemini",
        .protocol = .gemini_native,
        .normalized_base_url = "http://127.0.0.1:9000",
    });
    try std.testing.expectError(error.InvalidBaseUrl, validateCustomProviderSpec(.{
        .display_name = "Protocol path mismatch",
        .protocol = .openai_chat_completions,
        .normalized_base_url = "https://api.example.com/v1/responses",
    }));
    try std.testing.expectError(error.InvalidBaseUrl, validateCustomProviderSpec(.{
        .display_name = "Remote HTTP is not allowed",
        .protocol = .gemini_native,
        .normalized_base_url = "http://api.example.com",
    }));
    try std.testing.expectError(error.InvalidBaseUrl, validateCustomProviderSpec(.{
        .display_name = "Automation path must remain exact",
        .protocol = .anthropic_messages,
        .normalized_base_url = "http://127.0.0.1:43123/v1/messages?fixture=true",
    }));
}

test "custom provider endpoint normalization is deterministic" {
    const responses = try normalizeCustomProviderEndpointAlloc(
        std.testing.allocator,
        .openai_responses,
        "HTTPS://API.OpenAI.COM/v1/responses",
    );
    defer std.testing.allocator.free(responses);
    try std.testing.expectEqualStrings("https://api.openai.com/v1/responses", responses);
    const anthropic = try normalizeCustomProviderEndpointAlloc(
        std.testing.allocator,
        .anthropic_messages,
        "HTTPS://API.Anthropic.COM/v1/messages",
    );
    defer std.testing.allocator.free(anthropic);
    try std.testing.expectEqualStrings("https://api.anthropic.com/v1/messages", anthropic);
    const chat = try normalizeCustomProviderEndpointAlloc(
        std.testing.allocator,
        .openai_chat_completions,
        "HTTPS://API.Example.COM/v1/chat/completions",
    );
    defer std.testing.allocator.free(chat);
    try std.testing.expectEqualStrings("https://api.example.com/v1/chat/completions", chat);
    const gemini = try normalizeCustomProviderEndpointAlloc(
        std.testing.allocator,
        .gemini_native,
        "https://GenerativeLanguage.GoogleApis.com/",
    );
    defer std.testing.allocator.free(gemini);
    try std.testing.expectEqualStrings("https://generativelanguage.googleapis.com", gemini);
    try std.testing.expectError(error.InvalidBaseUrl, normalizeCustomProviderEndpointAlloc(
        std.testing.allocator,
        .openai_chat_completions,
        "https://api%2eexample.com/v1/chat/completions",
    ));
}

test "provider Base URLs map to exact protocol endpoints" {
    inline for (.{
        .{ Protocol.openai_responses, "https://api.openai.com/v1/", "https://api.openai.com/v1/responses" },
        .{ Protocol.anthropic_messages, "https://api.minimaxi.com/anthropic", "https://api.minimaxi.com/anthropic/v1/messages" },
        .{ Protocol.openai_chat_completions, "HTTPS://API.Moonshot.CN/v1/", "https://api.moonshot.cn/v1/chat/completions" },
        .{ Protocol.gemini_native, "https://generativelanguage.googleapis.com/", "https://generativelanguage.googleapis.com" },
    }) |case| {
        const endpoint = try completionEndpointFromBaseUrlAlloc(
            std.testing.allocator,
            case[0],
            case[1],
        );
        defer std.testing.allocator.free(endpoint);
        try std.testing.expectEqualStrings(case[2], endpoint);
    }
    try std.testing.expectError(error.InvalidBaseUrl, completionEndpointFromBaseUrlAlloc(
        std.testing.allocator,
        .openai_chat_completions,
        "https://user@example.com/v1",
    ));
    try std.testing.expectError(error.InvalidBaseUrl, completionEndpointFromBaseUrlAlloc(
        std.testing.allocator,
        .openai_chat_completions,
        "https://api.example.com/v1?token=secret",
    ));
    try std.testing.expectError(error.InvalidBaseUrl, completionEndpointFromBaseUrlAlloc(
        std.testing.allocator,
        .openai_chat_completions,
        "http://api.example.com/v1",
    ));
}

test "ready custom provider view requires a ready credential and exact model proof" {
    const models = [_]CustomProviderModelView{.{
        .id = "gemini-2.5-flash",
        .test_status = .connected,
        .ready = true,
    }};
    try std.testing.expectError(error.InconsistentState, validateCustomProviderView(.{
        .id = "provider-1",
        .display_name = "Gemini",
        .protocol = .gemini_native,
        .normalized_base_url = "https://generativelanguage.googleapis.com",
        .state = .ready,
        .credential_status = .capture_unavailable,
        .enabled = true,
        .models = &models,
        .provider_revision = 1,
        .source_generation = 2,
        .catalog_generation = 3,
    }));
    try validateCustomProviderView(.{
        .id = "provider-1",
        .display_name = "Gemini",
        .protocol = .gemini_native,
        .normalized_base_url = "https://generativelanguage.googleapis.com",
        .state = .ready,
        .credential_status = .ready,
        .enabled = true,
        .models = &models,
        .provider_revision = 1,
        .source_generation = 2,
        .catalog_generation = 3,
    });
}

fn copyImageCapabilitiesUnderAllocationFailure(allocator: std.mem.Allocator) !void {
    var model = "vision-model".*;
    const entries = [_]ModelImageCapability{ .{ .model = &model, .supported = true }, .{ .model = "text-model", .supported = false } };
    var owned = try OwnedImageCapabilities.copy(allocator, &entries);
    defer owned.deinit();
    var moved = owned.take();
    defer moved.deinit();
    @memset(&model, 'x');
    try std.testing.expectEqualStrings("vision-model", moved.entries[0].model);
    try std.testing.expect(moved.entries[0].supported);
    try std.testing.expect(!moved.entries[1].supported);
    try std.testing.expectEqual(@as(usize, 0), owned.entries.len);
}

test "image capability ownership survives transfer and allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, copyImageCapabilitiesUnderAllocationFailure, .{});
    const duplicate = [_]ModelImageCapability{ .{ .model = "GLM", .supported = true }, .{ .model = "glm", .supported = false } };
    try std.testing.expectError(error.InvalidMetadata, validateImageCapabilities(&duplicate));
    const excessive = [_]ModelImageCapability{.{ .model = "m", .supported = true }} ** (max_model_image_capabilities + 1);
    try std.testing.expectError(error.CollectionTooLarge, validateImageCapabilities(&excessive));
}
