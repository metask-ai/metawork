const std = @import("std");

/// Compile-time bounds shared by Account, Workbench, and Bridge. Network
/// clients may use tighter limits, but may never widen these product bounds.
pub const Limits = struct {
    pub const account_id_bytes: usize = 256;
    pub const profile_id_bytes: usize = 256;
    pub const display_name_bytes: usize = 256;
    pub const api_key_id_bytes: usize = 128;
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
};

pub const AccountSessionState = enum {
    restoring,
    signed_out,
    authorizing,
    authenticated,
    refreshing,
    reauth_required,
    shutting_down,
};

pub const ExecutionState = enum {
    none,
    preparing,
    ready,
    reconfiguring,
    invalid,
};

pub const OperationKind = enum {
    none,
    oauth_callback,
    token_exchange,
    loading_keys,
    selecting_key,
    loading_models,
    selecting_model,
    persisting,
    logging_out,
};

/// User-facing readiness is published by the Host. The Renderer must not
/// reconstruct it from AccountSessionState, ExecutionState, or OperationKind.
pub const AccountReadiness = enum {
    checking,
    sign_in_required,
    preparing,
    choice_required,
    ready,
    needs_attention,
    restart_required,
};

/// The one product action that may be visually primary for the current
/// readiness state. Settings actions such as logout are intentionally outside
/// this onboarding projection.
pub const AccountPrimaryAction = enum {
    none,
    sign_in,
    reopen_login,
    choose_api_key,
    choose_model,
    retry_catalog,
    reauthenticate,
    restart,
};

pub const ProviderKind = enum {
    anthropic,
    openai,
};

pub const metask_anthropic_messages_url =
    "https://napi.metask-ai.com/v1/messages";
pub const metask_openai_chat_completions_url =
    "https://napi.metask-ai.com/v1/chat/completions";

/// Stable product error identity. The Renderer localizes these codes and may
/// display the accompanying bounded diagnostic; it never receives raw network
/// or credential-store errors.
pub const ErrorCode = enum {
    none,
    invalid_command,
    invalid_state,
    operation_in_progress,
    execution_in_use,
    oauth_bind_failed,
    oauth_browser_open_failed,
    oauth_callback_rejected,
    oauth_state_mismatch,
    oauth_exchange_failed,
    user_cancelled,
    deadline_exceeded,
    token_refresh_failed,
    account_mismatch,
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
    shutting_down,
};

pub const ApiKeyView = struct {
    id: []const u8,
    name: []const u8,
    suffix: []const u8,
    provider_kind: ProviderKind,
};

pub const ModelView = struct {
    id: []const u8,
    display_name: []const u8,
};

pub const ExecutionTarget = struct {
    provider_kind: ProviderKind,
    model: []const u8,
    base_url: []const u8,
};

/// Borrowed, secret-free product projection. Its slices are valid only for the
/// synchronous call that receives it; Workbench must copy into owned storage.
pub const AccountView = struct {
    session_state: AccountSessionState,
    execution_state: ExecutionState,
    operation: OperationKind,
    readiness: AccountReadiness,
    primary_action: AccountPrimaryAction,
    can_cancel: bool = false,
    account_id: []const u8 = "",
    profile_id: []const u8 = "",
    display_name: []const u8 = "",
    api_keys: []const ApiKeyView = &.{},
    models: []const ModelView = &.{},
    selected_api_key_id: []const u8 = "",
    selected_model: []const u8 = "",
    model_catalog_api_key_id: []const u8 = "",
    can_create_task: bool = false,
    error_code: ErrorCode = .none,
    safe_diagnostic: []const u8 = "",
    catalog_generation: u64 = 0,
    execution_generation: u64 = 0,
};

pub const AccountFactKind = enum {
    restored,
    session_changed,
    execution_changed,
    catalog_changed,
    operation_failed,
    signed_out,
};

/// A canonical, secret-free fact prepared by Account and installed by
/// Workbench without allocating or calling back into Account.
pub const AccountFact = struct {
    kind: AccountFactKind,
    view: AccountView,
};

pub const AccountCommand = union(enum) {
    begin_login,
    reopen_login,
    reauthenticate,
    cancel_operation,
    refresh_catalog,
    select_api_key: []const u8,
    select_model: []const u8,
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

/// Single-owner transfer from Account preparation into the App/Workbench
/// commit path. Do not bit-copy this value. Transfer ownership only with
/// `take`; every live owner must call `deinit`, which securely clears the key.
pub const OwnedExecutionConfig = struct {
    provider_kind: ProviderKind,
    model: OwnedBuffer,
    base_url: OwnedBuffer,
    execution_generation: u64,
    secret: SecretBuffer,

    pub fn initOwned(
        allocator: std.mem.Allocator,
        provider_kind: ProviderKind,
        owned_model: []u8,
        owned_base_url: []u8,
        execution_generation: u64,
        owned_api_key: []u8,
    ) error{InvalidExecutionConfig}!OwnedExecutionConfig {
        const config_input: ExecutionConfigInput = .{
            .target = .{
                .provider_kind = provider_kind,
                .model = owned_model,
                .base_url = owned_base_url,
            },
            .api_key = owned_api_key,
            .execution_generation = execution_generation,
        };
        validateExecutionConfig(config_input) catch {
            allocator.free(owned_model);
            allocator.free(owned_base_url);
            secureFree(allocator, owned_api_key);
            return error.InvalidExecutionConfig;
        };
        return .{
            .provider_kind = provider_kind,
            .model = .initOwned(allocator, owned_model),
            .base_url = .initOwned(allocator, owned_base_url),
            .execution_generation = execution_generation,
            .secret = .initOwned(allocator, owned_api_key),
        };
    }

    pub fn take(self: *OwnedExecutionConfig) OwnedExecutionConfig {
        return .{
            .provider_kind = self.provider_kind,
            .model = self.model.take(),
            .base_url = self.base_url.take(),
            .execution_generation = self.execution_generation,
            .secret = self.secret.take(),
        };
    }

    pub fn input(self: *const OwnedExecutionConfig) ExecutionConfigInput {
        return .{
            .target = .{
                .provider_kind = self.provider_kind,
                .model = self.model.view(),
                .base_url = self.base_url.view(),
            },
            .api_key = self.secret.view(),
            .execution_generation = self.execution_generation,
        };
    }

    pub fn deinit(self: *OwnedExecutionConfig) void {
        self.model.deinit();
        self.base_url.deinit();
        self.secret.deinit();
        self.provider_kind = undefined;
        self.execution_generation = 0;
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
};

pub fn validateCommand(command: AccountCommand) ValidationError!void {
    switch (command) {
        .select_api_key => |id| try validateRequired(id, Limits.api_key_id_bytes),
        .select_model => |model| try validateRequired(model, Limits.model_id_bytes),
        else => {},
    }
}

pub fn validateExecutionConfig(input: ExecutionConfigInput) ValidationError!void {
    try validateRequired(input.target.model, Limits.model_id_bytes);
    try validateRequired(input.target.base_url, Limits.base_url_bytes);
    const expected_base_url: []const u8 = switch (input.target.provider_kind) {
        .anthropic => metask_anthropic_messages_url,
        .openai => metask_openai_chat_completions_url,
    };
    if (!std.mem.eql(u8, input.target.base_url, expected_base_url))
        return error.InvalidBaseUrl;
    try validateOpaqueRequired(input.api_key, Limits.api_key_bytes);
    if (input.execution_generation == 0) return error.InvalidGeneration;
}

pub fn validateView(view: AccountView) ValidationError!void {
    try validateOptional(view.account_id, Limits.account_id_bytes);
    try validateOptional(view.profile_id, Limits.profile_id_bytes);
    try validateOptional(view.display_name, Limits.display_name_bytes);
    try validateOptional(view.selected_api_key_id, Limits.api_key_id_bytes);
    try validateOptional(view.selected_model, Limits.model_id_bytes);
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
        for (view.models[0..model_index]) |prior|
            if (std.mem.eql(u8, prior.id, model.id))
                return error.InconsistentState;
    }

    if (view.execution_state == .ready) {
        if (view.execution_generation == 0 or
            view.account_id.len == 0 or
            view.profile_id.len == 0 or
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
        const catalog_reconfiguration = switch (view.operation) {
            .loading_keys,
            .selecting_key,
            .loading_models,
            .selecting_model,
            .persisting,
            => true,
            else => false,
        };
        if (!catalog_reconfiguration and
            (api_key_matches != 1 or model_matches != 1))
            return error.InconsistentState;
        if (catalog_reconfiguration and view.can_create_task)
            return error.InconsistentState;
    } else if (view.can_create_task) {
        return error.InconsistentState;
    }
    if (view.models.len == 0) {
        if (view.model_catalog_api_key_id.len != 0 and
            view.operation != .loading_models)
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
    const expected_can_cancel = view.operation != .none and
        view.operation != .logging_out and
        view.operation != .persisting;
    if (view.can_cancel != expected_can_cancel)
        return error.InconsistentState;
    switch (view.readiness) {
        .checking => if (view.primary_action != .none or
            view.session_state != .restoring)
            return error.InconsistentState,
        .sign_in_required => if (view.primary_action != .sign_in or
            view.session_state != .signed_out or
            view.operation != .none)
            return error.InconsistentState,
        .preparing => if ((view.primary_action != .none and
            view.primary_action != .reopen_login) or
            view.operation == .none or
            view.operation == .selecting_key or
            view.operation == .selecting_model)
            return error.InconsistentState,
        .choice_required => switch (view.primary_action) {
            .choose_api_key => if (view.operation != .selecting_key or
                view.api_keys.len == 0)
                return error.InconsistentState,
            .choose_model => if (view.operation != .selecting_model or
                view.models.len == 0)
                return error.InconsistentState,
            else => return error.InconsistentState,
        },
        .ready => if (view.primary_action != .none or
            view.execution_state != .ready)
            return error.InconsistentState,
        .needs_attention => switch (view.primary_action) {
            .retry_catalog => if (view.session_state != .authenticated or
                view.operation != .none)
                return error.InconsistentState,
            .reauthenticate => if (view.session_state != .reauth_required or
                view.operation != .none)
                return error.InconsistentState,
            else => return error.InconsistentState,
        },
        .restart_required => if (view.primary_action != .restart or
            view.session_state != .shutting_down)
            return error.InconsistentState,
    }
    if (view.primary_action == .reopen_login and
        (view.session_state != .authorizing or
            view.operation != .oauth_callback))
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
        .session_state = .authenticated,
        .execution_state = .ready,
        .operation = .none,
        .readiness = .ready,
        .primary_action = .none,
        .selected_model = "metask-model",
        .can_create_task = true,
    }));
}

test "AccountView rejects an actionless catalog choice" {
    try std.testing.expectError(error.InconsistentState, validateView(.{
        .session_state = .authenticated,
        .execution_state = .preparing,
        .operation = .selecting_key,
        .readiness = .choice_required,
        .primary_action = .choose_api_key,
        .can_cancel = true,
    }));
    try std.testing.expectError(error.InconsistentState, validateView(.{
        .session_state = .authenticated,
        .execution_state = .preparing,
        .operation = .selecting_model,
        .readiness = .choice_required,
        .primary_action = .choose_model,
        .can_cancel = true,
    }));
}

test "execution config requires typed HTTPS target and bounded secret" {
    try std.testing.expectError(error.InvalidBaseUrl, validateExecutionConfig(.{
        .target = .{
            .provider_kind = .anthropic,
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
            .provider_kind = .anthropic,
            .model = "metask-model",
            .base_url = metask_anthropic_messages_url,
        },
        .api_key = &.{ 0xff, 0x00, 0x7f },
        .execution_generation = 1,
    });
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
        .anthropic,
        model,
        base_url,
        4,
        secret,
    );
    var destination = source.take();
    try std.testing.expectEqualStrings("metask-model", destination.input().target.model);
    try std.testing.expectEqualStrings("test-secret", destination.input().api_key);
    source.deinit();
    destination.deinit();
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
            .anthropic,
            model,
            base_url,
            4,
            secret,
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
        .anthropic,
        model,
        base_url,
        1,
        secret,
    );
    config.deinit();

    try std.testing.expect(observing.saw_secret_free);
    try std.testing.expect(observing.secret_was_zero);
}
