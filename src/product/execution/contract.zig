//! Product Control-owned execution value contract.
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
    pub const model_connection_entries: usize = 8;
    pub const model_connection_model_entries: usize = 16;
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

/// Stable Product Execution availability cause. Command rejection remains a
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

/// Product-internal management result. Bridge adapters may map these stable
/// execution-domain failures onto their existing wire error vocabulary.
pub const ManagementError = enum {
    invalid_connection,
    connection_not_found,
    generation_mismatch,
    model_not_found,
    capacity,
    persistence_unavailable,
    capture_unavailable,
    credential_write_failed,
    execution_in_use,
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

/// Opaque, synchronous ownership handoff for an execution candidate. The
/// sequencing owner may route this capability, but only the receiving
/// execution owner can materialize the credential-bearing configuration.
pub const OwnedConfigTransfer = struct {
    context: *anyopaque,
    take_fn: *const fn (*anyopaque) OwnedConfig,

    pub fn take(self: OwnedConfigTransfer) OwnedConfig {
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
        .select_default => |value| {
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
