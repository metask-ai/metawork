//! Product Models value contract.
//!
//! This leaf owns the protocol axis, frozen execution configuration, and
//! user-managed model-connection values. It has no runtime, Account, Agent,
//! Application, Bridge, or persistence dependency.

const std = @import("std");

pub const Limits = struct {
    pub const instance_id_bytes: usize = 128;
    pub const provider_id_bytes: usize = @tagName(Source.model_connection).len + 1 + instance_id_bytes;
    pub const display_name_bytes: usize = 256;
    pub const model_id_bytes: usize = 256;
    pub const model_display_name_bytes: usize = 256;
    pub const base_url_bytes: usize = 2048;
    pub const credential_bytes: usize = 4096;
    pub const principal_ref_bytes: usize = 256;
    pub const api_key_id_bytes: usize = 128;
    pub const api_key_name_bytes: usize = 256;
    pub const api_key_suffix_bytes: usize = 32;
    pub const safe_diagnostic_bytes: usize = 512;
    pub const api_key_entries: usize = 256;
    pub const model_entries: usize = 512;
    pub const model_connection_entries: usize = 8;
    pub const model_connection_model_entries: usize = 16;
};

pub const metask_source_id = "metask";
pub const metask_anthropic_messages_url =
    "https://napi.metask-ai.com/v1/messages";
pub const metask_openai_chat_completions_url =
    "https://napi.metask-ai.com/v1/chat/completions";
pub const metask_gemini_base_url =
    "https://generativelanguage.googleapis.com";

pub const ModelRef = struct {
    source_id: []const u8,
    model_id: []const u8,
};

pub const Source = enum {
    metask,
    model_connection,
};

pub const Availability = enum {
    unavailable,
    ready,
    replacing,
};

/// Stable Product Models availability cause. Command rejection remains a
/// separate result and Account never publishes these failures.
pub const AvailabilityError = enum {
    none,
    model_connection_persistence_unavailable,
    credential_unavailable,
    invalid_candidate,
    resource_exhausted,
    schedule_persistence_unavailable,
    schedule_persistence_failed,
    schedule_persistence_outcome_unknown,
};

/// Exact request/response wire dialect. This is not a vendor category.
pub const Protocol = enum {
    openai_responses,
    anthropic_messages,
    openai_chat_completions,
    gemini_native,
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
    migration_required,
    recovery_required,
    unavailable,
};

pub const ModelsOperation = enum {
    idle,
    refreshing_catalog,
};

pub const ModelsError = enum {
    none,
    authorization_unavailable,
    persistence_unavailable,
    migration_required,
    catalog_unavailable,
    catalog_invalid,
    catalog_too_large,
    no_api_keys,
    no_models,
    operation_in_progress,
    local_resource_exhausted,
};

pub const ApiKeyView = struct {
    id: []const u8,
    name: []const u8,
    suffix: []const u8,
    protocol: Protocol,
};

/// Provider declarations, not MetaWork feature gates. null means unknown.
pub const ModelCapabilities = struct {
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

pub const ModelView = struct {
    id: []const u8,
    display_name: []const u8,
    metadata: ModelMetadata = .{},
};

pub const ProviderView = struct {
    id: []const u8,
    display_name: []const u8,
    recommended: bool,
    catalog_state: CatalogState,
    principal_ref: []const u8 = "",
    api_keys: []const ApiKeyView = &.{},
    models: []const ModelView = &.{},
    selected_api_key_id: []const u8 = "",
    catalog_generation: u64 = 0,
    source_generation: u64 = 0,
    error_code: ModelsError = .none,
    safe_diagnostic: []const u8 = "",
};

pub const ModelsView = struct {
    availability: CatalogState,
    persistence_health: PersistenceHealth,
    providers: []const ProviderView = &.{},
    metask_selection: ?ModelRef = null,
    metask_selection_revision: u64 = 0,
    default_selection: ?ModelRef = null,
    selection_revision: u64 = 0,
    operation: ModelsOperation = .idle,
    error_code: ModelsError = .none,
    model_connections: []const ModelConnectionView = &.{},
};

pub const CatalogRefreshPreparation = struct {
    attempt_id: u64,
    principal_ref: []const u8,
    authorization_generation: u64,
    preferred_api_key_id: []const u8,
    preferred_model_id: []const u8,
};

pub const CatalogRefreshPrepareResult = union(enum) {
    ready: CatalogRefreshPreparation,
    rejected: ModelsError,
};

pub const Target = struct {
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

pub const ModelConnectionState = enum {
    configuring,
    ready,
    disabled,
};

pub const ModelConnectionTestStatus = enum {
    untested,
    testing,
    connected,
    failed,
};

pub const ModelConnectionCredentialStatus = enum {
    missing,
    ready,
    invalid,
    capture_unavailable,
};

pub const ModelConnectionModelView = struct {
    id: []const u8,
    display_name: []const u8 = "",
};

pub const ModelConnectionView = struct {
    id: []const u8,
    display_name: []const u8,
    protocol: Protocol,
    normalized_base_url: []const u8,
    state: ModelConnectionState,
    test_status: ModelConnectionTestStatus,
    credential_status: ModelConnectionCredentialStatus,
    enabled: bool,
    models: []const ModelConnectionModelView = &.{},
    selected_model: []const u8 = "",
    connection_generation: u64,
    source_generation: u64,
    catalog_generation: u64,
};

/// Borrowed, secret-free Product Control projection. The default source is
/// durable user intent; the active source is the process-local installed
/// execution and may be absent independently.
pub const ExecutionView = struct {
    state: Availability,
    default_source: ?Source = null,
    active_source: ?Source = null,
    active_generation: u64 = 0,
    task_creation_available: bool = false,
    selected_model_connection_id: []const u8 = "",
    model_connections: []const ModelConnectionView = &.{},
    error_code: AvailabilityError = .none,
};

pub const ModelConnectionSpec = struct {
    display_name: []const u8,
    protocol: Protocol,
    normalized_base_url: []const u8,
};

pub const ModelConnectionCredentialSlot = struct {
    id: []const u8,
};

pub const ModelConnectionSelectionCommand = struct {
    connection_id: []const u8,
    expected_connection_generation: u64,
};

pub const ModelConnectionCreateCommand = struct {
    connection_id: []const u8,
    spec: ModelConnectionSpec,
    credential_slot: ModelConnectionCredentialSlot,
    model_id: []const u8,
    model_display_name: []const u8 = "",
};

pub const ModelConnectionUpdateCommand = struct {
    selection: ModelConnectionSelectionCommand,
    spec: ModelConnectionSpec,
    credential_slot: ?ModelConnectionCredentialSlot = null,
};

pub const ModelConnectionTestCommand = struct {
    selection: ModelConnectionSelectionCommand,
    model_id: []const u8,
};

pub const ConfigureMetaskSelectionCommand = struct {
    selection: ModelRef,
    expected_metask_selection_revision: u64,
    expected_catalog_generation: u64,
};

pub const SelectDefaultCommand = struct {
    selection: ModelRef,
    expected_selection_revision: u64,
    expected_source_generation: u64,
    expected_catalog_generation: u64,
};

/// Borrowed durable default identity published by Models for Product Control
/// reconciliation. This describes desired authority only and carries no
/// credential or Product binding generation.
pub const DefaultSelectionAuthority = struct {
    selection: ModelRef,
    source: Source,
    source_generation: u64,
    selection_revision: u64,
    protocol: Protocol,
};

pub const ModelConnectionCommand = union(enum) {
    create: ModelConnectionCreateCommand,
    update: ModelConnectionUpdateCommand,
    remove: ModelConnectionSelectionCommand,
    test_connection: ModelConnectionTestCommand,
};

/// Product-internal Models management result. Bridge adapters may map these
/// stable failures onto the Renderer wire error vocabulary.
pub const ManagementError = enum {
    authorization_unavailable,
    catalog_unavailable,
    invalid_connection,
    connection_not_found,
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
    submit_fn: *const fn (*anyopaque, ModelConnectionCommand) CommandResult,

    pub fn submit(self: CommandSink, command: ModelConnectionCommand) CommandResult {
        return self.submit_fn(self.context, command);
    }
};

pub const DefaultBinding = struct {
    connection_id: []const u8,
    model_id: []const u8,
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

/// Linear candidate transferred from an execution source into Product
/// Control. It deliberately has no Product execution generation.
pub const OwnedSourceCandidate = struct {
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
        validateRequired(instance_id, Limits.instance_id_bytes) catch
            return error.InvalidSourceCandidate;
        const provider_id = try std.fmt.allocPrint(
            allocator,
            "{s}:{s}",
            .{ @tagName(source), instance_id },
        );
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
        self.provider_id.deinit();
        self.model.deinit();
        self.base_url.deinit();
        self.secret.deinit();
        self.protocol = undefined;
        self.source_generation = 0;
        self.source = undefined;
    }
};

/// Linear owned configuration transferred from a Product execution source
/// into Product Control and then into Task-owned execution attachments.
pub const OwnedConfig = struct {
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
        validateRequired(instance_id, Limits.instance_id_bytes) catch
            return error.InvalidExecutionConfig;
        const provider_id = try std.fmt.allocPrint(
            allocator,
            "{s}:{s}",
            .{ @tagName(source), instance_id },
        );
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
        if (source == .model_connection)
            validateModelConnectionExecutionConfig(config_input) catch
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
        self.provider_id.deinit();
        self.model.deinit();
        self.base_url.deinit();
        self.secret.deinit();
        self.protocol = undefined;
        self.execution_generation = 0;
        self.source = undefined;
    }
};

/// Opaque, synchronous ownership handoff for a source candidate. The source
/// authority stays distinct from the Product execution generation assigned by
/// the receiving owner.
pub const OwnedSourceCandidateTransfer = struct {
    context: *anyopaque,
    take_fn: *const fn (*anyopaque) OwnedSourceCandidate,

    pub fn take(self: OwnedSourceCandidateTransfer) OwnedSourceCandidate {
        return self.take_fn(self.context);
    }
};

pub fn modelConnectionProtocolAvailable(protocol: Protocol) bool {
    return switch (protocol) {
        .openai_responses,
        .anthropic_messages,
        .openai_chat_completions,
        .gemini_native,
        => true,
    };
}

pub fn validateModelConnectionCommand(command: ModelConnectionCommand) ValidationError!void {
    switch (command) {
        .create => |value| {
            try validateRequired(value.connection_id, Limits.instance_id_bytes);
            try validateModelConnectionSpec(value.spec);
            try validateRequired(value.credential_slot.id, Limits.instance_id_bytes);
            try validateRequired(value.model_id, Limits.model_id_bytes);
            try validateOptional(value.model_display_name, Limits.model_display_name_bytes);
        },
        .update => |value| {
            try validateRequired(value.selection.connection_id, Limits.instance_id_bytes);
            if (value.selection.expected_connection_generation == 0)
                return error.InvalidGeneration;
            try validateModelConnectionSpec(value.spec);
            if (value.credential_slot) |slot|
                try validateRequired(slot.id, Limits.instance_id_bytes);
        },
        .remove => |value| {
            try validateRequired(value.connection_id, Limits.instance_id_bytes);
            if (value.expected_connection_generation == 0)
                return error.InvalidGeneration;
        },
        .test_connection => |value| {
            try validateRequired(value.selection.connection_id, Limits.instance_id_bytes);
            if (value.selection.expected_connection_generation == 0)
                return error.InvalidGeneration;
            try validateRequired(value.model_id, Limits.model_id_bytes);
        },
    }
}

pub fn validateModelConnectionSpec(spec: ModelConnectionSpec) ValidationError!void {
    try validateRequired(spec.display_name, Limits.display_name_bytes);
    try validateRequired(spec.normalized_base_url, Limits.base_url_bytes);
    if (!modelConnectionProtocolAvailable(spec.protocol))
        return error.UnsupportedProtocol;
    if (!validModelConnectionEndpoint(spec.protocol, spec.normalized_base_url))
        return error.InvalidBaseUrl;
}

pub fn validModelConnectionEndpoint(protocol: Protocol, value: []const u8) bool {
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
        .openai_responses => std.mem.eql(u8, path, "/v1/responses"),
        .anthropic_messages => std.mem.eql(u8, path, "/v1/messages"),
        .openai_chat_completions => std.mem.eql(u8, path, "/v1/chat/completions"),
        .gemini_native => path.len == 0 or std.mem.eql(u8, path, "/"),
    };
}

pub fn normalizeModelConnectionEndpointAlloc(
    allocator: std.mem.Allocator,
    protocol: Protocol,
    value: []const u8,
) (std.mem.Allocator.Error || ValidationError)![]u8 {
    if (!modelConnectionProtocolAvailable(protocol))
        return error.UnsupportedProtocol;
    if (!validModelConnectionEndpoint(protocol, value))
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

pub fn validateModelConnectionView(view: ModelConnectionView) ValidationError!void {
    try validateRequired(view.id, Limits.instance_id_bytes);
    try validateRequired(view.display_name, Limits.display_name_bytes);
    try validateRequired(view.normalized_base_url, Limits.base_url_bytes);
    if (!modelConnectionProtocolAvailable(view.protocol))
        return error.UnsupportedProtocol;
    if (!validModelConnectionEndpoint(view.protocol, view.normalized_base_url))
        return error.InvalidBaseUrl;
    if (view.connection_generation == 0) return error.InvalidGeneration;
    if (view.models.len > Limits.model_connection_model_entries)
        return error.CollectionTooLarge;
    if (view.selected_model.len != 0)
        try validateRequired(view.selected_model, Limits.model_id_bytes);
    for (view.models, 0..) |model, index| {
        try validateRequired(model.id, Limits.model_id_bytes);
        try validateOptional(model.display_name, Limits.model_display_name_bytes);
        for (view.models[0..index]) |prior|
            if (std.mem.eql(u8, prior.id, model.id))
                return error.InconsistentState;
    }
    if (view.selected_model.len != 0) {
        var matches: usize = 0;
        for (view.models) |model| {
            if (std.mem.eql(u8, model.id, view.selected_model)) matches += 1;
        }
        if (matches != 1) return error.InconsistentState;
    }
    if (view.state == .ready and
        (view.credential_status != .ready or !view.enabled or
            view.selected_model.len == 0 or view.test_status == .untested))
        return error.InconsistentState;
    if (view.state != .ready and view.test_status == .connected)
        return error.InconsistentState;
}

pub fn validateConfigStructure(input: ConfigInput) ValidationError!void {
    try validateRequired(input.target.provider_id, Limits.provider_id_bytes);
    try validateRequired(input.target.model, Limits.model_id_bytes);
    try validateRequired(input.target.base_url, Limits.base_url_bytes);
    try validateOpaqueRequired(input.api_key, Limits.credential_bytes);
    if (input.execution_generation == 0) return error.InvalidGeneration;
}

pub fn validateSourceCandidateStructure(input: SourceCandidateInput) ValidationError!void {
    try validateRequired(input.target.provider_id, Limits.provider_id_bytes);
    try validateRequired(input.target.model, Limits.model_id_bytes);
    try validateRequired(input.target.base_url, Limits.base_url_bytes);
    try validateOpaqueRequired(input.api_key, Limits.credential_bytes);
    if (input.source_generation == 0) return error.InvalidGeneration;
}

pub fn validateMetaskSourceCandidate(input: SourceCandidateInput) ValidationError!void {
    try validateSourceCandidateStructure(input);
    const prefix = @tagName(Source.metask) ++ ":";
    if (!std.mem.startsWith(u8, input.target.provider_id, prefix) or
        input.target.provider_id.len == prefix.len)
        return error.InconsistentState;
    const expected_endpoint: []const u8 = switch (input.target.protocol) {
        .openai_responses => return error.UnsupportedProtocol,
        .anthropic_messages => metask_anthropic_messages_url,
        .openai_chat_completions => metask_openai_chat_completions_url,
        .gemini_native => metask_gemini_base_url,
    };
    if (!std.mem.eql(u8, input.target.base_url, expected_endpoint))
        return error.InvalidBaseUrl;
}

pub fn validateModelConnectionExecutionConfig(input: ConfigInput) ValidationError!void {
    try validateConfigStructure(input);
    if (!modelConnectionProtocolAvailable(input.target.protocol))
        return error.UnsupportedProtocol;
    if (!validModelConnectionEndpoint(input.target.protocol, input.target.base_url))
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
        try allocator.dupe(u8, "https://napi.metask-ai.com/v1/messages"),
        7,
        secret,
        "key-1",
    );
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
            try allocator.dupe(u8, "https://napi.metask-ai.com/v1/messages"),
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
        try allocator.dupe(u8, "https://napi.metask-ai.com/v1/messages"),
        7,
        try allocator.dupe(u8, "secret"),
        "key-1",
    );
    defer candidate.deinit();

    try std.testing.expectEqual(@as(u64, 7), candidate.input().source_generation);
    var config = try candidate.intoConfig(29);
    defer config.deinit();
    try std.testing.expectEqual(@as(u64, 29), config.input().execution_generation);
    try std.testing.expectEqualStrings("metask:key-1", config.input().target.provider_id);
    try std.testing.expectEqualStrings("secret", config.input().api_key);
}

test "model connection protocols have exact endpoint contracts" {
    inline for (.{
        .{ Protocol.openai_responses, "https://api.openai.com/v1/responses" },
        .{ Protocol.anthropic_messages, "https://api.anthropic.com/v1/messages" },
        .{ Protocol.openai_chat_completions, "https://api.openai.com/v1/chat/completions" },
        .{ Protocol.gemini_native, "https://generativelanguage.googleapis.com" },
    }) |case| try std.testing.expect(validModelConnectionEndpoint(case[0], case[1]));
    try validateModelConnectionSpec(.{
        .display_name = "Local Gemini",
        .protocol = .gemini_native,
        .normalized_base_url = "http://127.0.0.1:9000",
    });
    try std.testing.expectError(error.InvalidBaseUrl, validateModelConnectionSpec(.{
        .display_name = "Protocol path mismatch",
        .protocol = .openai_chat_completions,
        .normalized_base_url = "https://api.example.com/v1/responses",
    }));
    try std.testing.expectError(error.InvalidBaseUrl, validateModelConnectionSpec(.{
        .display_name = "Remote HTTP is not allowed",
        .protocol = .gemini_native,
        .normalized_base_url = "http://api.example.com",
    }));
}

test "model connection endpoint normalization is deterministic" {
    const responses = try normalizeModelConnectionEndpointAlloc(
        std.testing.allocator,
        .openai_responses,
        "HTTPS://API.OpenAI.COM/v1/responses",
    );
    defer std.testing.allocator.free(responses);
    try std.testing.expectEqualStrings("https://api.openai.com/v1/responses", responses);
    const anthropic = try normalizeModelConnectionEndpointAlloc(
        std.testing.allocator,
        .anthropic_messages,
        "HTTPS://API.Anthropic.COM/v1/messages",
    );
    defer std.testing.allocator.free(anthropic);
    try std.testing.expectEqualStrings("https://api.anthropic.com/v1/messages", anthropic);
    const chat = try normalizeModelConnectionEndpointAlloc(
        std.testing.allocator,
        .openai_chat_completions,
        "HTTPS://API.Example.COM/v1/chat/completions",
    );
    defer std.testing.allocator.free(chat);
    try std.testing.expectEqualStrings("https://api.example.com/v1/chat/completions", chat);
    const gemini = try normalizeModelConnectionEndpointAlloc(
        std.testing.allocator,
        .gemini_native,
        "https://GenerativeLanguage.GoogleApis.com/",
    );
    defer std.testing.allocator.free(gemini);
    try std.testing.expectEqualStrings("https://generativelanguage.googleapis.com", gemini);
    try std.testing.expectError(error.InvalidBaseUrl, normalizeModelConnectionEndpointAlloc(
        std.testing.allocator,
        .openai_chat_completions,
        "https://api%2eexample.com/v1/chat/completions",
    ));
}

test "ready model connection view requires a ready credential and selected model" {
    const models = [_]ModelConnectionModelView{.{ .id = "gemini-2.5-flash" }};
    try std.testing.expectError(error.InconsistentState, validateModelConnectionView(.{
        .id = "connection-1",
        .display_name = "Gemini",
        .protocol = .gemini_native,
        .normalized_base_url = "https://generativelanguage.googleapis.com",
        .state = .ready,
        .test_status = .connected,
        .credential_status = .capture_unavailable,
        .enabled = true,
        .models = &models,
        .connection_generation = 1,
        .source_generation = 2,
        .catalog_generation = 3,
    }));
    try validateModelConnectionView(.{
        .id = "connection-1",
        .display_name = "Gemini",
        .protocol = .gemini_native,
        .normalized_base_url = "https://generativelanguage.googleapis.com",
        .state = .ready,
        .test_status = .connected,
        .credential_status = .ready,
        .enabled = true,
        .models = &models,
        .selected_model = "gemini-2.5-flash",
        .connection_generation = 1,
        .source_generation = 2,
        .catalog_generation = 3,
    });
}
