//! Product Account public contract.
const std = @import("std");

/// Compile-time bounds shared by Account, Workbench, and Bridge. Network
/// clients may use tighter limits, but may never widen these product bounds.
pub const Limits = struct {
    pub const account_id_bytes: usize = 256;
    pub const display_name_bytes: usize = 256;
    pub const api_key_id_bytes: usize = 128;
    pub const provider_id_bytes: usize = @tagName(ExecutionSource.model_connection).len + 1 + api_key_id_bytes;
    pub const api_key_name_bytes: usize = 256;
    pub const api_key_suffix_bytes: usize = 32;
    pub const model_id_bytes: usize = 256;
    pub const model_display_name_bytes: usize = 256;
    pub const base_url_bytes: usize = 2048;
    // Native SDK Keychain values are currently capped at 4096 bytes.
    pub const api_key_bytes: usize = 4096;
    pub const safe_diagnostic_bytes: usize = 512;
    pub const api_key_entries: usize = 256;
    pub const model_entries: usize = 512;
    pub const model_connection_entries: usize = 8;
    pub const model_connection_model_entries: usize = 16;
};

pub const AccountState = enum {
    checking,
    signed_out,
    authorizing,
    authenticated,
};

pub const CatalogState = enum {
    unavailable,
    loading,
    choosing,
    ready,
    failed,
};

pub const ExecutionSource = enum {
    metask,
    model_connection,
};

/// Exact wire protocol selected for one model-service connection. Product
/// state never compresses this fact into a vendor or provider category.
pub const Protocol = enum {
    openai_responses,
    anthropic_messages,
    openai_chat_completions,
    gemini_native,
};

pub const ModelConnectionState = enum {
    configuring,
    ready,
    disabled,
};

/// Latest isolated connection-test operation/result. This is deliberately
/// separate from execution readiness: a failed retest must not invalidate an
/// already verified generation or its installed default execution.
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

/// Secret-free projection for Renderer and Workbench snapshots. The
/// credential is represented only by status; its bytes never cross this
/// contract boundary.
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
};

pub const ModelConnectionSpec = struct {
    display_name: []const u8,
    protocol: Protocol,
    normalized_base_url: []const u8,
};

/// Opaque reference to a credential already captured by a Host-owned secure
/// input capability. It is not the credential itself and is never accepted
/// from a Renderer payload as plaintext.
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

pub const ModelConnectionCommand = union(enum) {
    create: ModelConnectionCreateCommand,
    update: ModelConnectionUpdateCommand,
    remove: ModelConnectionSelectionCommand,
    test_connection: ModelConnectionTestCommand,
    select_default: struct {
        selection: ModelConnectionSelectionCommand,
        model_id: []const u8,
    },
};

pub const ModelConnectionCommandResult = struct {
    accepted: bool,
    error_code: ErrorCode,
    attempt_id: ?u64 = null,
};

pub const metask_anthropic_messages_url =
    "https://napi.metask-ai.com/v1/messages";
pub const metask_openai_chat_completions_url =
    "https://napi.metask-ai.com/v1/chat/completions";
pub const metask_gemini_base_url =
    "https://generativelanguage.googleapis.com";

/// Stable product error identity. The Renderer localizes these codes and may
/// display the accompanying bounded diagnostic; it never receives raw network
/// or credential-store errors.
pub const ErrorCode = enum {
    none,
    invalid_command,
    invalid_state,
    operation_in_progress,
    execution_in_use,
    session_in_use,
    oauth_bind_failed,
    oauth_browser_open_failed,
    oauth_callback_rejected,
    oauth_state_mismatch,
    oauth_exchange_failed,
    user_cancelled,
    deadline_exceeded,
    token_refresh_failed,
    metask_unauthorized,
    metask_rate_limited,
    metask_service_unavailable,
    metask_protocol_invalid,
    catalog_too_large,
    catalog_field_too_large,
    no_api_keys,
    no_models,
    execution_target_invalid,
    execution_config_invalid,
    credential_store_read_failed,
    credential_store_write_failed,
    credential_store_delete_failed,
    generation_mismatch,
    recovery_state_invalid,
    local_resource_exhausted,
    dependency_contract_invalid,
    model_connection_invalid,
    model_connection_not_found,
    model_connection_capture_unavailable,
    model_connection_persistence_unavailable,
    model_connection_test_unavailable,
};

pub const ApiKeyView = struct {
    id: []const u8,
    name: []const u8,
    suffix: []const u8,
    protocol: Protocol,
};

/// Server declarations, not MetaWork feature gates or verified runtime support.
/// null means the server did not report the capability, never "unsupported".
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
    /// Positive server-reported limits. Missing/null/zero normalize to unknown.
    max_input_tokens: ?u64 = null,
    max_output_tokens: ?u64 = null,
    capabilities: ModelCapabilities = .{},
};

pub const ModelView = struct {
    id: []const u8,
    display_name: []const u8,
    metadata: ModelMetadata = .{},
};

pub const ExecutionTarget = struct {
    /// Source-qualified service instance reference; never a wire adapter name.
    provider_id: []const u8,
    protocol: Protocol,
    model: []const u8,
    base_url: []const u8,
};

/// Borrowed, secret-free product projection. Its slices are valid only for the
/// synchronous call that receives it; Workbench must copy into owned storage.
pub const AccountView = struct {
    state: AccountState,
    catalog_state: CatalogState,
    execution_source: ExecutionSource = .metask,
    can_cancel: bool = false,
    account_id: []const u8 = "",
    display_name: []const u8 = "",
    api_keys: []const ApiKeyView = &.{},
    models: []const ModelView = &.{},
    selected_api_key_id: []const u8 = "",
    selected_model: []const u8 = "",
    candidate_api_key_id: []const u8 = "",
    candidate_model: []const u8 = "",
    model_catalog_api_key_id: []const u8 = "",
    model_connections: []const ModelConnectionView = &.{},
    selected_model_connection_id: []const u8 = "",
    can_create_task: bool = false,
    error_code: ErrorCode = .none,
    safe_diagnostic: []const u8 = "",
    catalog_generation: u64 = 0,
    /// The committed Metask execution generation, even when another source is
    /// currently selected for new Tasks.
    metask_execution_generation: u64 = 0,
    execution_generation: u64 = 0,
};

pub const AccountFactKind = enum {
    restored,
    session_changed,
    execution_changed,
    default_changed,
    catalog_changed,
    model_connections_changed,
    operation_failed,
    signed_out,
};

/// A canonical, secret-free fact prepared by Account and installed by
/// Workbench without allocating or calling back into Account.
pub const AccountFact = struct {
    kind: AccountFactKind,
    view: AccountView,
};

pub const AccountSelectionCommand = struct {
    selection_id: []const u8,
    expected_catalog_generation: u64,
    expected_execution_generation: u64,
};

pub const AccountActivationCommand = struct {
    expected_catalog_generation: u64,
    expected_execution_generation: u64,
};

pub const AccountCommand = union(enum) {
    begin_login,
    cancel_operation,
    refresh_catalog,
    select_api_key: AccountSelectionCommand,
    select_model: AccountSelectionCommand,
    activate_metask: AccountActivationCommand,
    model_connection: ModelConnectionCommand,
    logout,
};

pub const AccountCommandResult = struct {
    accepted: bool,
    error_code: ErrorCode,
    attempt_id: ?u64 = null,

    pub fn acceptedAttempt(attempt_id: ?u64) AccountCommandResult {
        return .{
            .accepted = true,
            .error_code = .none,
            .attempt_id = attempt_id,
        };
    }

    pub fn rejected(error_code: ErrorCode) AccountCommandResult {
        std.debug.assert(error_code != .none);
        return .{
            .accepted = false,
            .error_code = error_code,
        };
    }
};

/// Narrow synchronous main-thread command port. It is not a queue, a platform
/// capability, or a generic message bus.
pub const AccountCommandSink = struct {
    context: *anyopaque,
    submit_fn: *const fn (context: *anyopaque, command: AccountCommand) AccountCommandResult,

    pub fn submit(self: AccountCommandSink, command: AccountCommand) AccountCommandResult {
        return self.submit_fn(self.context, command);
    }
};

pub const ExecutionConfigInput = struct {
    target: ExecutionTarget,
    api_key: []const u8,
    execution_generation: u64,
};

const SecretBuffer = struct {
    allocator: std.mem.Allocator = undefined,
    bytes: []u8 = &.{},
    owned: bool = false,

    fn initOwned(allocator: std.mem.Allocator, bytes: []u8) SecretBuffer {
        std.debug.assert(bytes.len > 0);
        return .{
            .allocator = allocator,
            .bytes = bytes,
            .owned = true,
        };
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

fn secureFree(allocator: std.mem.Allocator, bytes: []u8) void {
    if (bytes.len == 0) return;
    std.crypto.secureZero(u8, bytes);
    allocator.rawFree(bytes, .of(u8), @returnAddress());
}

const OwnedBuffer = struct {
    allocator: std.mem.Allocator = undefined,
    bytes: []u8 = &.{},
    owned: bool = false,

    fn initOwned(allocator: std.mem.Allocator, bytes: []u8) OwnedBuffer {
        std.debug.assert(bytes.len > 0);
        return .{
            .allocator = allocator,
            .bytes = bytes,
            .owned = true,
        };
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

/// Single-owner transfer from Account preparation into the
/// Application/Product Control commit path.
/// Do not bit-copy this value. Transfer ownership only with
/// `take`; every live owner must call `deinit`, which securely clears the key.
pub const OwnedExecutionConfig = struct {
    provider_id: OwnedBuffer,
    protocol: Protocol,
    model: OwnedBuffer,
    base_url: OwnedBuffer,
    execution_generation: u64,
    secret: SecretBuffer,
    model_connection: bool = false,

    pub fn initOwned(
        allocator: std.mem.Allocator,
        protocol: Protocol,
        owned_model: []u8,
        owned_base_url: []u8,
        execution_generation: u64,
        owned_api_key: []u8,
        api_key_id: []const u8,
    ) (error{InvalidExecutionConfig} || std.mem.Allocator.Error)!OwnedExecutionConfig {
        return init(allocator, protocol, owned_model, owned_base_url, execution_generation, owned_api_key, api_key_id, .metask);
    }

    pub fn initModelConnectionOwned(
        allocator: std.mem.Allocator,
        protocol: Protocol,
        owned_model: []u8,
        owned_base_url: []u8,
        execution_generation: u64,
        owned_api_key: []u8,
        connection_id: []const u8,
    ) (error{InvalidExecutionConfig} || std.mem.Allocator.Error)!OwnedExecutionConfig {
        return init(allocator, protocol, owned_model, owned_base_url, execution_generation, owned_api_key, connection_id, .model_connection);
    }

    fn init(
        allocator: std.mem.Allocator,
        protocol: Protocol,
        owned_model: []u8,
        owned_base_url: []u8,
        execution_generation: u64,
        owned_api_key: []u8,
        instance_id: []const u8,
        source: ExecutionSource,
    ) (error{InvalidExecutionConfig} || std.mem.Allocator.Error)!OwnedExecutionConfig {
        errdefer allocator.free(owned_model);
        errdefer allocator.free(owned_base_url);
        errdefer secureFree(allocator, owned_api_key);
        validateRequired(instance_id, Limits.api_key_id_bytes) catch return error.InvalidExecutionConfig;
        const provider_id = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ @tagName(source), instance_id });
        errdefer allocator.free(provider_id);
        const config_input: ExecutionConfigInput = .{
            .target = .{
                .provider_id = provider_id,
                .protocol = protocol,
                .model = owned_model,
                .base_url = owned_base_url,
            },
            .api_key = owned_api_key,
            .execution_generation = execution_generation,
        };
        const validation = switch (source) {
            .metask => validateExecutionConfig(config_input),
            .model_connection => validateModelConnectionExecutionConfig(config_input),
        };
        validation catch return error.InvalidExecutionConfig;
        return .{
            .provider_id = .initOwned(allocator, provider_id),
            .protocol = protocol,
            .model = .initOwned(allocator, owned_model),
            .base_url = .initOwned(allocator, owned_base_url),
            .execution_generation = execution_generation,
            .secret = .initOwned(allocator, owned_api_key),
            .model_connection = source == .model_connection,
        };
    }

    pub fn take(self: *OwnedExecutionConfig) OwnedExecutionConfig {
        return .{
            .provider_id = self.provider_id.take(),
            .protocol = self.protocol,
            .model = self.model.take(),
            .base_url = self.base_url.take(),
            .execution_generation = self.execution_generation,
            .secret = self.secret.take(),
            .model_connection = self.model_connection,
        };
    }

    pub fn input(self: *const OwnedExecutionConfig) ExecutionConfigInput {
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

    pub fn deinit(self: *OwnedExecutionConfig) void {
        self.provider_id.deinit();
        self.model.deinit();
        self.base_url.deinit();
        self.secret.deinit();
        self.protocol = undefined;
        self.execution_generation = 0;
        self.model_connection = false;
    }
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

/// Product admission is explicit and exhaustive so adding another protocol
/// cannot silently expose it to user-managed connections.
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
            try validateRequired(value.connection_id, Limits.api_key_id_bytes);
            try validateModelConnectionSpec(value.spec);
            try validateRequired(value.credential_slot.id, Limits.api_key_id_bytes);
            try validateRequired(value.model_id, Limits.model_id_bytes);
            try validateOptional(value.model_display_name, Limits.model_display_name_bytes);
        },
        .update => |value| {
            try validateRequired(
                value.selection.connection_id,
                Limits.api_key_id_bytes,
            );
            if (value.selection.expected_connection_generation == 0)
                return error.InvalidGeneration;
            try validateModelConnectionSpec(value.spec);
            if (value.credential_slot) |slot|
                try validateRequired(slot.id, Limits.api_key_id_bytes);
        },
        .remove => |value| {
            try validateRequired(value.connection_id, Limits.api_key_id_bytes);
            if (value.expected_connection_generation == 0)
                return error.InvalidGeneration;
        },
        .test_connection => |value| {
            try validateRequired(value.selection.connection_id, Limits.api_key_id_bytes);
            if (value.selection.expected_connection_generation == 0)
                return error.InvalidGeneration;
            try validateRequired(value.model_id, Limits.model_id_bytes);
        },
        .select_default => |value| {
            try validateRequired(value.selection.connection_id, Limits.api_key_id_bytes);
            if (value.selection.expected_connection_generation == 0)
                return error.InvalidGeneration;
            try validateRequired(value.model_id, Limits.model_id_bytes);
        },
    }
}

/// Validate a user-managed connection before any credential capture or
/// AgentCore test is started. This is intentionally pure and secret-free.
pub fn validateModelConnectionSpec(spec: ModelConnectionSpec) ValidationError!void {
    try validateRequired(spec.display_name, Limits.display_name_bytes);
    try validateRequired(spec.normalized_base_url, Limits.base_url_bytes);
    if (!modelConnectionProtocolAvailable(spec.protocol))
        return error.UnsupportedProtocol;
    if (!validModelConnectionEndpoint(spec.protocol, spec.normalized_base_url)) {
        return error.InvalidBaseUrl;
    }
}

pub fn validModelConnectionEndpoint(
    protocol: Protocol,
    value: []const u8,
) bool {
    if (value.len == 0 or value.len > Limits.base_url_bytes or
        !std.unicode.utf8ValidateSlice(value)) return false;
    for (value) |byte| if (byte <= 0x20 or byte == 0x7f or byte == '\\')
        return false;
    const uri = std.Uri.parse(value) catch return false;
    if (uri.user != null or uri.password != null or uri.query != null or
        uri.fragment != null or uri.host == null) return false;
    const scheme = uri.scheme;
    const is_https = std.ascii.eqlIgnoreCase(scheme, "https");
    const is_http_loopback = std.ascii.eqlIgnoreCase(scheme, "http") and
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

/// Canonicalizes only the URI components whose comparison is defined as
/// ASCII case-insensitive. Provider paths remain exact because AgentCore owns
/// their protocol semantics. Credentials, query parameters, fragments and
/// percent-encoded authorities are rejected before allocation.
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

fn isLoopbackHost(host: std.Uri.Component) bool {
    const value = switch (host) {
        .raw, .percent_encoded => |bytes| bytes,
    };
    return std.ascii.eqlIgnoreCase(value, "localhost") or
        std.mem.eql(u8, value, "127.0.0.1") or
        std.mem.eql(u8, value, "[::1]");
}

pub fn validateModelConnectionView(view: ModelConnectionView) ValidationError!void {
    try validateRequired(view.id, Limits.api_key_id_bytes);
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
            if (std.mem.eql(u8, prior.id, model.id)) return error.InconsistentState;
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

pub fn validateCommand(command: AccountCommand) ValidationError!void {
    switch (command) {
        .select_api_key => |selection| try validateRequired(
            selection.selection_id,
            Limits.api_key_id_bytes,
        ),
        .select_model => |selection| try validateRequired(
            selection.selection_id,
            Limits.model_id_bytes,
        ),
        .activate_metask => |activation| {
            if (activation.expected_catalog_generation == 0 or
                activation.expected_execution_generation == 0)
                return error.InvalidGeneration;
        },
        .model_connection => |connection_command| try validateModelConnectionCommand(connection_command),
        else => {},
    }
}

pub fn validateExecutionConfig(input: ExecutionConfigInput) ValidationError!void {
    try validateRequired(input.target.provider_id, Limits.provider_id_bytes);
    try validateRequired(input.target.model, Limits.model_id_bytes);
    try validateRequired(input.target.base_url, Limits.base_url_bytes);
    const expected_base_url: []const u8 = switch (input.target.protocol) {
        .openai_responses => return error.UnsupportedProtocol,
        .anthropic_messages => metask_anthropic_messages_url,
        .openai_chat_completions => metask_openai_chat_completions_url,
        .gemini_native => metask_gemini_base_url,
    };
    if (!std.mem.eql(u8, input.target.base_url, expected_base_url))
        return error.InvalidBaseUrl;
    try validateOpaqueRequired(input.api_key, Limits.api_key_bytes);
    if (input.execution_generation == 0) return error.InvalidGeneration;
}

pub fn validateModelConnectionExecutionConfig(
    input: ExecutionConfigInput,
) ValidationError!void {
    try validateRequired(input.target.model, Limits.model_id_bytes);
    try validateRequired(input.target.base_url, Limits.base_url_bytes);
    try validateRequired(input.target.provider_id, Limits.provider_id_bytes);
    const protocol = input.target.protocol;
    if (!modelConnectionProtocolAvailable(protocol))
        return error.UnsupportedProtocol;
    if (!validModelConnectionEndpoint(
        protocol,
        input.target.base_url,
    )) return error.InvalidBaseUrl;
    try validateOpaqueRequired(input.api_key, Limits.api_key_bytes);
    if (input.execution_generation == 0) return error.InvalidGeneration;
}

pub fn validateView(view: AccountView) ValidationError!void {
    try validateOptional(view.account_id, Limits.account_id_bytes);
    try validateOptional(view.display_name, Limits.display_name_bytes);
    try validateOptional(view.selected_api_key_id, Limits.api_key_id_bytes);
    try validateOptional(view.selected_model, Limits.model_id_bytes);
    try validateOptional(view.candidate_api_key_id, Limits.api_key_id_bytes);
    try validateOptional(view.candidate_model, Limits.model_id_bytes);
    try validateOptional(
        view.model_catalog_api_key_id,
        Limits.api_key_id_bytes,
    );
    try validateOptional(
        view.selected_model_connection_id,
        Limits.api_key_id_bytes,
    );
    try validateOptional(view.safe_diagnostic, Limits.safe_diagnostic_bytes);
    if (view.api_keys.len > Limits.api_key_entries or view.models.len > Limits.model_entries)
        return error.CollectionTooLarge;
    if (view.model_connections.len > Limits.model_connection_entries)
        return error.CollectionTooLarge;
    for (view.model_connections, 0..) |connection, connection_index| {
        try validateModelConnectionView(connection);
        for (view.model_connections[0..connection_index]) |prior|
            if (std.mem.eql(u8, prior.id, connection.id))
                return error.InconsistentState;
    }

    for (view.api_keys, 0..) |key, key_index| {
        try validateRequired(key.id, Limits.api_key_id_bytes);
        try validateOptional(key.name, Limits.api_key_name_bytes);
        try validateOptional(key.suffix, Limits.api_key_suffix_bytes);
        for (view.api_keys[0..key_index]) |prior|
            if (std.mem.eql(u8, prior.id, key.id))
                return error.InconsistentState;
    }
    for (view.models, 0..) |model, model_index| {
        try validateRequired(model.id, Limits.model_id_bytes);
        try validateOptional(model.display_name, Limits.model_display_name_bytes);
        if (model.metadata.max_input_tokens == 0 or
            model.metadata.max_output_tokens == 0)
            return error.InconsistentState;
        for (view.models[0..model_index]) |prior|
            if (std.mem.eql(u8, prior.id, model.id))
                return error.InconsistentState;
    }
    const candidate_allowed = view.state == .authenticated and
        (view.catalog_state == .loading or view.catalog_state == .choosing);
    if (!candidate_allowed and
        (view.candidate_api_key_id.len != 0 or view.candidate_model.len != 0))
        return error.InconsistentState;
    if (view.candidate_model.len != 0 and view.candidate_api_key_id.len == 0)
        return error.InconsistentState;
    if (view.candidate_api_key_id.len != 0 and view.catalog_state == .choosing) {
        var candidate_api_matches: usize = 0;
        for (view.api_keys) |key| {
            if (std.mem.eql(u8, key.id, view.candidate_api_key_id))
                candidate_api_matches += 1;
        }
        if (candidate_api_matches != 1) return error.InconsistentState;
    }
    if (view.candidate_model.len != 0 and view.models.len != 0) {
        var candidate_model_matches: usize = 0;
        for (view.models) |model| {
            if (std.mem.eql(u8, model.id, view.candidate_model))
                candidate_model_matches += 1;
        }
        if (candidate_model_matches != 1) return error.InconsistentState;
    }

    if (view.execution_source == .model_connection) {
        if (view.can_create_task and
            (view.execution_generation == 0 or
                view.selected_model_connection_id.len == 0))
            return error.InconsistentState;
        if (view.can_create_task) {
            var selected_matches: usize = 0;
            for (view.model_connections) |connection| {
                if (std.mem.eql(u8, connection.id, view.selected_model_connection_id) and
                    connection.state == .ready and
                    connection.credential_status == .ready and
                    connection.selected_model.len != 0)
                    selected_matches += 1;
            }
            if (selected_matches != 1) return error.InconsistentState;
        }
    } else if (view.selected_model_connection_id.len != 0) {
        return error.InconsistentState;
    }

    if (view.catalog_state == .ready) {
        if (view.metask_execution_generation == 0 or
            view.account_id.len == 0 or
            view.selected_api_key_id.len == 0 or
            view.selected_model.len == 0)
            return error.InconsistentState;
        var api_key_matches: usize = 0;
        for (view.api_keys) |key| {
            if (std.mem.eql(u8, key.id, view.selected_api_key_id))
                api_key_matches += 1;
        }
        var model_matches: usize = 0;
        for (view.models) |model| {
            if (std.mem.eql(u8, model.id, view.selected_model))
                model_matches += 1;
        }
        if (api_key_matches != 1 or model_matches != 1)
            return error.InconsistentState;
    } else if (view.execution_source == .metask and view.can_create_task) {
        return error.InconsistentState;
    }
    if (view.models.len == 0) {
        if (view.model_catalog_api_key_id.len != 0 and
            view.catalog_state != .loading)
            return error.InconsistentState;
    } else {
        if (view.model_catalog_api_key_id.len == 0)
            return error.InconsistentState;
        var catalog_owner_matches: usize = 0;
        for (view.api_keys) |key| {
            if (std.mem.eql(u8, key.id, view.model_catalog_api_key_id))
                catalog_owner_matches += 1;
        }
        if (catalog_owner_matches != 1) return error.InconsistentState;
    }
    if (view.error_code == .none and view.safe_diagnostic.len != 0)
        return error.InconsistentState;
    if (view.can_cancel and view.state != .authorizing and
        view.catalog_state != .loading and view.catalog_state != .choosing)
        return error.InconsistentState;
    switch (view.state) {
        .checking, .signed_out, .authorizing => {
            if (view.catalog_state != .unavailable or
                view.account_id.len != 0 or view.display_name.len != 0 or
                view.api_keys.len != 0 or view.models.len != 0 or
                view.selected_api_key_id.len != 0 or
                view.selected_model.len != 0 or
                view.candidate_api_key_id.len != 0 or
                view.candidate_model.len != 0 or
                view.model_catalog_api_key_id.len != 0 or
                view.metask_execution_generation != 0 or
                (view.execution_source == .metask and
                    (view.execution_generation != 0 or view.can_create_task)))
                return error.InconsistentState;
            if (view.state != .authorizing and view.can_cancel)
                return error.InconsistentState;
        },
        .authenticated => {
            if (view.account_id.len == 0 or view.display_name.len == 0)
                return error.InconsistentState;
            if (view.catalog_state == .choosing and view.api_keys.len == 0)
                return error.InconsistentState;
            if (view.catalog_state == .failed and view.error_code == .none)
                return error.InconsistentState;
        },
    }
    if (view.execution_source == .metask and
        view.metask_execution_generation != view.execution_generation)
        return error.InconsistentState;
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

test "AccountCommandSink returns only public acceptance metadata" {
    const Context = struct {
        calls: usize = 0,

        fn submit(raw: *anyopaque, command: AccountCommand) AccountCommandResult {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            return switch (command) {
                .begin_login => .acceptedAttempt(17),
                else => .rejected(.invalid_state),
            };
        }
    };

    var context: Context = .{};
    const sink: AccountCommandSink = .{
        .context = &context,
        .submit_fn = Context.submit,
    };
    const result = sink.submit(.begin_login);
    try std.testing.expect(result.accepted);
    try std.testing.expectEqual(ErrorCode.none, result.error_code);
    try std.testing.expectEqual(@as(?u64, 17), result.attempt_id);
    try std.testing.expectEqual(@as(usize, 1), context.calls);
}

test "AccountView rejects ready execution without committed generation" {
    try std.testing.expectError(error.InconsistentState, validateView(.{
        .state = .authenticated,
        .catalog_state = .ready,
        .account_id = "account-1",
        .display_name = "User",
        .selected_model = "metask-model",
        .can_create_task = true,
    }));
}

test "AccountView rejects an actionless catalog choice" {
    try std.testing.expectError(error.InconsistentState, validateView(.{
        .state = .authenticated,
        .catalog_state = .choosing,
        .account_id = "account-1",
        .display_name = "User",
        .can_cancel = true,
    }));
}

test "AccountView accepts the published logout transition" {
    try validateView(.{
        .state = .authenticated,
        .catalog_state = .unavailable,
        .account_id = "account-1",
        .display_name = "User",
        .selected_api_key_id = "key-1",
        .selected_model = "model-1",
        .metask_execution_generation = 7,
        .execution_generation = 7,
    });
}

test "AccountView accepts an unresolved model candidate while loading" {
    const api_keys = [_]ApiKeyView{.{
        .id = "key-1",
        .name = "Primary",
        .suffix = "1234",
        .protocol = .anthropic_messages,
    }};
    try validateView(.{
        .state = .authenticated,
        .catalog_state = .loading,
        .account_id = "account-1",
        .display_name = "User",
        .api_keys = &api_keys,
        .candidate_api_key_id = "key-1",
        .candidate_model = "model-pending",
        .model_catalog_api_key_id = "key-1",
    });
}

test "execution config requires typed HTTPS target and bounded secret" {
    try std.testing.expectError(error.InvalidBaseUrl, validateExecutionConfig(.{
        .target = .{
            .provider_id = "metask:fixture-provider",
            .protocol = .anthropic_messages,
            .model = "metask-model",
            .base_url = "http://127.0.0.1/v1",
        },
        .api_key = "secret",
        .execution_generation = 1,
    }));
}

test "execution config treats credential as bounded opaque bytes" {
    try validateExecutionConfig(.{
        .target = .{
            .provider_id = "metask:fixture-provider",
            .protocol = .anthropic_messages,
            .model = "metask-model",
            .base_url = metask_anthropic_messages_url,
        },
        .api_key = &.{ 0xff, 0x00, 0x7f },
        .execution_generation = 1,
    });
}

test "user-managed model connection accepts only registered native endpoints" {
    try validateModelConnectionSpec(.{
        .display_name = "OpenAI Responses",
        .protocol = .openai_responses,
        .normalized_base_url = "https://api.openai.com/v1/responses",
    });
    try validateModelConnectionSpec(.{
        .display_name = "Anthropic",
        .protocol = .anthropic_messages,
        .normalized_base_url = "https://api.anthropic.com/v1/messages",
    });
    try validateModelConnectionSpec(.{
        .display_name = "My OpenAI",
        .protocol = .openai_chat_completions,
        .normalized_base_url = "https://api.example.com/v1/chat/completions",
    });
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

test "user-managed model connection endpoint normalization is deterministic" {
    const responses = try normalizeModelConnectionEndpointAlloc(
        std.testing.allocator,
        .openai_responses,
        "HTTPS://API.OpenAI.COM/v1/responses",
    );
    defer std.testing.allocator.free(responses);
    try std.testing.expectEqualStrings(
        "https://api.openai.com/v1/responses",
        responses,
    );
    const anthropic = try normalizeModelConnectionEndpointAlloc(
        std.testing.allocator,
        .anthropic_messages,
        "HTTPS://API.Anthropic.COM/v1/messages",
    );
    defer std.testing.allocator.free(anthropic);
    try std.testing.expectEqualStrings(
        "https://api.anthropic.com/v1/messages",
        anthropic,
    );
    const normalized = try normalizeModelConnectionEndpointAlloc(
        std.testing.allocator,
        .openai_chat_completions,
        "HTTPS://API.Example.COM/v1/chat/completions",
    );
    defer std.testing.allocator.free(normalized);
    try std.testing.expectEqualStrings(
        "https://api.example.com/v1/chat/completions",
        normalized,
    );
    const gemini = try normalizeModelConnectionEndpointAlloc(
        std.testing.allocator,
        .gemini_native,
        "https://GenerativeLanguage.GoogleApis.com/",
    );
    defer std.testing.allocator.free(gemini);
    try std.testing.expectEqualStrings(
        "https://generativelanguage.googleapis.com",
        gemini,
    );
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
    });
}

test "model connection execution identifies its exact default connection" {
    const models = [_]ModelConnectionModelView{.{ .id = "shared-model" }};
    const connections = [_]ModelConnectionView{
        .{
            .id = "connection-a",
            .display_name = "Connection A",
            .protocol = .openai_chat_completions,
            .normalized_base_url = "https://a.example/v1/chat/completions",
            .state = .ready,
            .test_status = .connected,
            .credential_status = .ready,
            .enabled = true,
            .models = &models,
            .selected_model = "shared-model",
            .connection_generation = 1,
        },
        .{
            .id = "connection-b",
            .display_name = "Connection B",
            .protocol = .openai_chat_completions,
            .normalized_base_url = "https://b.example/v1/chat/completions",
            .state = .ready,
            .test_status = .connected,
            .credential_status = .ready,
            .enabled = true,
            .models = &models,
            .selected_model = "shared-model",
            .connection_generation = 1,
        },
    };
    try validateView(.{
        .state = .signed_out,
        .catalog_state = .unavailable,
        .execution_source = .model_connection,
        .model_connections = &connections,
        .selected_model_connection_id = "connection-b",
        .can_create_task = true,
        .execution_generation = 9,
    });
}

test "model connection commands carry only opaque credential slots" {
    try validateModelConnectionCommand(.{ .create = .{
        .connection_id = "slot-1",
        .spec = .{
            .display_name = "OpenAI",
            .protocol = .openai_chat_completions,
            .normalized_base_url = "https://api.openai.com/v1/chat/completions",
        },
        .credential_slot = .{ .id = "slot-1" },
        .model_id = "gpt-5",
    } });
    try std.testing.expectError(error.FieldEmpty, validateModelConnectionCommand(.{
        .create = .{
            .connection_id = "",
            .spec = .{
                .display_name = "OpenAI",
                .protocol = .openai_chat_completions,
                .normalized_base_url = "https://api.openai.com/v1/chat/completions",
            },
            .credential_slot = .{ .id = "" },
            .model_id = "gpt-5",
        },
    }));
}

test "OwnedExecutionConfig moves one secret owner and securely releases it" {
    const allocator = std.testing.allocator;
    const model = try allocator.dupe(u8, "metask-model");
    const base_url = try allocator.dupe(
        u8,
        metask_anthropic_messages_url,
    );
    const secret = try allocator.dupe(u8, "test-secret");
    var source = try OwnedExecutionConfig.initOwned(
        allocator,
        .anthropic_messages,
        model,
        base_url,
        4,
        secret,
        "fixture-provider",
    );
    var destination = source.take();
    try std.testing.expectEqualStrings("metask-model", destination.input().target.model);
    try std.testing.expectEqualStrings("test-secret", destination.input().api_key);
    source.deinit();
    try std.testing.expectEqualStrings("metask:fixture-provider", destination.input().target.provider_id);
    try std.testing.expectEqual(Protocol.anthropic_messages, destination.input().target.protocol);
    destination.deinit();
}

test "execution references distinguish connections and sources with identical credentials" {
    const allocator = std.testing.allocator;
    var first = try OwnedExecutionConfig.initModelConnectionOwned(
        allocator,
        .openai_chat_completions,
        try allocator.dupe(u8, "model"),
        try allocator.dupe(u8, metask_openai_chat_completions_url),
        1,
        try allocator.dupe(u8, "same-secret"),
        "service-a",
    );
    defer first.deinit();
    var second = try OwnedExecutionConfig.initModelConnectionOwned(
        allocator,
        .openai_chat_completions,
        try allocator.dupe(u8, "model"),
        try allocator.dupe(u8, metask_openai_chat_completions_url),
        1,
        try allocator.dupe(u8, "same-secret"),
        "service-b",
    );
    defer second.deinit();
    var managed = try OwnedExecutionConfig.initOwned(
        allocator,
        .openai_chat_completions,
        try allocator.dupe(u8, "model"),
        try allocator.dupe(u8, metask_openai_chat_completions_url),
        1,
        try allocator.dupe(u8, "same-secret"),
        "service-a",
    );
    defer managed.deinit();
    try std.testing.expectEqualStrings("model_connection:service-a", first.input().target.provider_id);
    try std.testing.expectEqualStrings("model_connection:service-b", second.input().target.provider_id);
    try std.testing.expectEqualStrings("metask:service-a", managed.input().target.provider_id);
}

test "OwnedExecutionConfig consumes invalid owned secret on rejection" {
    const allocator = std.testing.allocator;
    const model = try allocator.dupe(u8, "metask-model");
    const base_url = try allocator.dupe(u8, "http://invalid.example/v1");
    const secret = try allocator.dupe(u8, "test-secret");
    try std.testing.expectError(
        error.InvalidExecutionConfig,
        OwnedExecutionConfig.initOwned(
            allocator,
            .anthropic_messages,
            model,
            base_url,
            4,
            secret,
            "fixture-provider",
        ),
    );
}

test "OwnedExecutionConfig preserves zeroing through allocator release" {
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
                    for (memory) |byte| {
                        if (byte != 0) self.secret_was_zero = false;
                    }
                }
            }
            self.backing.rawFree(memory, alignment, ret_addr);
        }
    };

    var observing: ObservingAllocator = .{
        .backing = std.testing.allocator,
    };
    const allocator = observing.allocator();
    const model = try allocator.dupe(u8, "metask-model");
    const base_url = try allocator.dupe(
        u8,
        metask_anthropic_messages_url,
    );
    const secret = try allocator.dupe(u8, "test-secret");
    observing.secret_ptr = secret.ptr;
    observing.secret_len = secret.len;

    var config = try OwnedExecutionConfig.initOwned(
        allocator,
        .anthropic_messages,
        model,
        base_url,
        1,
        secret,
        "fixture-provider",
    );
    config.deinit();

    try std.testing.expect(observing.saw_secret_free);
    try std.testing.expect(observing.secret_was_zero);
}
