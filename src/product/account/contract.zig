//! Product Account public contract.
const std = @import("std");
const execution = @import("metawork_product_execution_contract");

/// Compile-time bounds shared by Account, Workbench, and Bridge. Network
/// clients may use tighter limits, but may never widen these product bounds.
pub const Limits = struct {
    pub const account_id_bytes: usize = 256;
    pub const display_name_bytes: usize = 256;
    pub const api_key_id_bytes: usize = 128;
    pub const provider_id_bytes: usize = execution.Limits.provider_id_bytes;
    pub const api_key_name_bytes: usize = 256;
    pub const api_key_suffix_bytes: usize = 32;
    pub const model_id_bytes: usize = execution.Limits.model_id_bytes;
    pub const model_display_name_bytes: usize = execution.Limits.model_display_name_bytes;
    pub const base_url_bytes: usize = execution.Limits.base_url_bytes;
    // Native SDK Keychain values are currently capped at 4096 bytes.
    pub const api_key_bytes: usize = execution.Limits.credential_bytes;
    pub const safe_diagnostic_bytes: usize = 512;
    pub const api_key_entries: usize = 256;
    pub const model_entries: usize = 512;
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
    metask_platform_unsupported,
    credential_store_read_failed,
    credential_store_write_failed,
    credential_store_delete_failed,
    generation_mismatch,
    recovery_state_invalid,
    local_resource_exhausted,
    account_operation_failed,
};

pub const ApiKeyView = struct {
    id: []const u8,
    name: []const u8,
    suffix: []const u8,
    protocol: execution.Protocol,
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

/// Borrowed, secret-free product projection. Its slices are valid only for the
/// synchronous call that receives it; Workbench must copy into owned storage.
pub const AccountView = struct {
    state: AccountState,
    catalog_state: CatalogState,
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
    error_code: ErrorCode = .none,
    safe_diagnostic: []const u8 = "",
    catalog_generation: u64 = 0,
};

pub const AccountFactKind = enum {
    restored,
    session_changed,
    execution_changed,
    default_changed,
    catalog_changed,
    operation_failed,
    signed_out,
};

/// Secret-free authority published to Product Control. This is not part of
/// AccountView and never crosses the Renderer Bridge.
pub const MetaskSourceAuthority = struct {
    account_id: []const u8,
    api_key_id: []const u8,
    model_id: []const u8,
    protocol: execution.Protocol,
    source_generation: u64,
};

/// A canonical, secret-free fact prepared by Account and installed by
/// Workbench without allocating or calling back into Account.
pub const AccountFact = struct {
    kind: AccountFactKind,
    view: AccountView,
    authority: ?MetaskSourceAuthority = null,
};

pub const AccountSelectionCommand = struct {
    selection_id: []const u8,
    expected_catalog_generation: u64,
};

pub const AccountCommand = union(enum) {
    begin_login,
    cancel_operation,
    refresh_catalog,
    select_api_key: AccountSelectionCommand,
    select_model: AccountSelectionCommand,
    /// Product-internal source resolution. Renderer has no Account command for
    /// selecting the global default source.
    resolve_metask_source,
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
        else => {},
    }
}

pub fn validateExecutionConfig(input: execution.ConfigInput) ValidationError!void {
    execution.validateConfigStructure(input) catch return error.InconsistentState;
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
    try validateOptional(view.safe_diagnostic, Limits.safe_diagnostic_bytes);
    if (view.api_keys.len > Limits.api_key_entries or view.models.len > Limits.model_entries)
        return error.CollectionTooLarge;
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

    if (view.catalog_state == .ready) {
        if (view.account_id.len == 0 or
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
                view.model_catalog_api_key_id.len != 0)
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
}

pub fn validateAuthority(authority: MetaskSourceAuthority) ValidationError!void {
    try validateRequired(authority.account_id, Limits.account_id_bytes);
    try validateRequired(authority.api_key_id, Limits.api_key_id_bytes);
    try validateRequired(authority.model_id, Limits.model_id_bytes);
    if (authority.source_generation == 0) return error.InvalidGeneration;
}

pub fn validateFact(fact: AccountFact) ValidationError!void {
    try validateView(fact.view);
    const ready = fact.view.state == .authenticated and
        fact.view.catalog_state == .ready;
    if (fact.authority) |authority| {
        if (!ready) return error.InconsistentState;
        try validateAuthority(authority);
        if (!std.mem.eql(u8, authority.account_id, fact.view.account_id) or
            !std.mem.eql(u8, authority.api_key_id, fact.view.selected_api_key_id) or
            !std.mem.eql(u8, authority.model_id, fact.view.selected_model))
            return error.InconsistentState;
        var protocol_matches: usize = 0;
        for (fact.view.api_keys) |key| {
            if (std.mem.eql(u8, key.id, authority.api_key_id) and
                key.protocol == authority.protocol)
                protocol_matches += 1;
        }
        if (protocol_matches != 1) return error.InconsistentState;
    } else if (ready) {
        return error.InconsistentState;
    }
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

test "AccountView rejects ready Metask catalog without selected membership" {
    try std.testing.expectError(error.InconsistentState, validateView(.{
        .state = .authenticated,
        .catalog_state = .ready,
        .account_id = "account-1",
        .display_name = "User",
        .selected_model = "metask-model",
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

test "AccountFact keeps source authority outside Renderer view" {
    const api_keys = [_]ApiKeyView{.{
        .id = "key-1",
        .name = "Primary",
        .suffix = "1234",
        .protocol = .anthropic_messages,
    }};
    const models = [_]ModelView{.{
        .id = "model-1",
        .display_name = "Model One",
    }};
    try validateFact(.{
        .kind = .default_changed,
        .view = .{
            .state = .authenticated,
            .catalog_state = .ready,
            .account_id = "account-1",
            .display_name = "User",
            .api_keys = &api_keys,
            .models = &models,
            .selected_api_key_id = "key-1",
            .selected_model = "model-1",
            .model_catalog_api_key_id = "key-1",
        },
        .authority = .{
            .account_id = "account-1",
            .api_key_id = "key-1",
            .model_id = "model-1",
            .protocol = .anthropic_messages,
            .source_generation = 7,
        },
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

test "OwnedConfig moves one secret owner and securely releases it" {
    const allocator = std.testing.allocator;
    const model = try allocator.dupe(u8, "metask-model");
    const base_url = try allocator.dupe(
        u8,
        metask_anthropic_messages_url,
    );
    const secret = try allocator.dupe(u8, "test-secret");
    var source = try execution.OwnedConfig.initOwned(
        allocator,
        .metask,
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
    try std.testing.expectEqual(execution.Protocol.anthropic_messages, destination.input().target.protocol);
    destination.deinit();
}

test "execution references distinguish connections and sources with identical credentials" {
    const allocator = std.testing.allocator;
    var first = try execution.OwnedConfig.initOwned(
        allocator,
        .model_connection,
        .openai_chat_completions,
        try allocator.dupe(u8, "model"),
        try allocator.dupe(u8, metask_openai_chat_completions_url),
        1,
        try allocator.dupe(u8, "same-secret"),
        "service-a",
    );
    defer first.deinit();
    var second = try execution.OwnedConfig.initOwned(
        allocator,
        .model_connection,
        .openai_chat_completions,
        try allocator.dupe(u8, "model"),
        try allocator.dupe(u8, metask_openai_chat_completions_url),
        1,
        try allocator.dupe(u8, "same-secret"),
        "service-b",
    );
    defer second.deinit();
    var managed = try execution.OwnedConfig.initOwned(
        allocator,
        .metask,
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

test "OwnedConfig consumes invalid owned secret on rejection" {
    const allocator = std.testing.allocator;
    const model = try allocator.dupe(u8, "metask-model");
    const base_url = try allocator.dupe(u8, "http://invalid.example/v1");
    const secret = try allocator.dupe(u8, "test-secret");
    try std.testing.expectError(
        error.InvalidExecutionConfig,
        execution.OwnedConfig.initOwned(
            allocator,
            .model_connection,
            .anthropic_messages,
            model,
            base_url,
            4,
            secret,
            "fixture-provider",
        ),
    );
}

test "OwnedConfig preserves zeroing through allocator release" {
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

    var config = try execution.OwnedConfig.initOwned(
        allocator,
        .metask,
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
