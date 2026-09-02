//! Product Account identity and authorization contract.
//!
//! Account owns the Metask login session and token lifecycle. Provider
//! catalogs, model selection, execution configuration, and consumer admission
//! belong to Models and Product Control.

const std = @import("std");

pub const Limits = struct {
    pub const account_id_bytes: usize = 256;
    pub const display_name_bytes: usize = 256;
    // Native SDK Keychain values are currently capped at 4096 bytes.
    pub const authorization_token_bytes: usize = 4096;
    pub const safe_diagnostic_bytes: usize = 512;
};

pub const AccountState = enum {
    checking,
    signed_out,
    authorizing,
    authenticated,
};

/// One bounded Account-owned authorization transfer. Application may move it
/// into a single Metask provider operation; neither Models state nor any
/// public projection may retain the OAuth token.
pub const OwnedAuthorizationLease = struct {
    allocator: std.mem.Allocator,
    principal_ref: []u8,
    access_token: []u8,
    authorization_generation: u64,
    owned: bool = true,

    pub fn init(
        allocator: std.mem.Allocator,
        principal_ref: []const u8,
        access_token: []const u8,
        authorization_generation: u64,
    ) (std.mem.Allocator.Error || ValidationError)!OwnedAuthorizationLease {
        try validateRequired(principal_ref, Limits.account_id_bytes);
        try validateOpaqueRequired(access_token, Limits.authorization_token_bytes);
        if (authorization_generation == 0) return error.InvalidGeneration;
        const principal = try allocator.dupe(u8, principal_ref);
        errdefer allocator.free(principal);
        const token = try allocator.dupe(u8, access_token);
        return .{
            .allocator = allocator,
            .principal_ref = principal,
            .access_token = token,
            .authorization_generation = authorization_generation,
        };
    }

    pub fn take(self: *OwnedAuthorizationLease) OwnedAuthorizationLease {
        std.debug.assert(self.owned);
        const result = self.*;
        self.owned = false;
        self.principal_ref = &.{};
        self.access_token = &.{};
        self.authorization_generation = 0;
        return result;
    }

    pub fn deinit(self: *OwnedAuthorizationLease) void {
        if (!self.owned) return;
        std.crypto.secureZero(u8, self.access_token);
        self.allocator.free(self.access_token);
        self.allocator.free(self.principal_ref);
        self.* = undefined;
    }
};

/// Stable Account error identity. Model catalog errors are defined by Models.
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
    metask_platform_unsupported,
    credential_store_read_failed,
    credential_store_write_failed,
    credential_store_delete_failed,
    generation_mismatch,
    recovery_state_invalid,
    local_resource_exhausted,
    account_operation_failed,
};

/// Borrowed, secret-free Account projection. Its slices are valid only for the
/// synchronous call that receives it; Product Control copies them if needed.
pub const AccountView = struct {
    state: AccountState,
    can_cancel: bool = false,
    account_id: []const u8 = "",
    display_name: []const u8 = "",
    error_code: ErrorCode = .none,
    safe_diagnostic: []const u8 = "",
};

pub const AccountFactKind = enum {
    restored,
    session_changed,
    operation_failed,
    signed_out,
};

/// Canonical secret-free identity fact prepared by Account and installed by
/// Product Control without allocating or calling back into Account.
pub const AccountFact = struct {
    kind: AccountFactKind,
    view: AccountView,
};

pub const AccountCommand = enum {
    begin_login,
    cancel_operation,
    logout,
};

pub const AccountCommandResult = struct {
    accepted: bool,
    error_code: ErrorCode,
    attempt_id: ?u64 = null,

    pub fn acceptedAttempt(attempt_id: ?u64) AccountCommandResult {
        return .{ .accepted = true, .error_code = .none, .attempt_id = attempt_id };
    }

    pub fn rejected(error_code: ErrorCode) AccountCommandResult {
        std.debug.assert(error_code != .none);
        return .{ .accepted = false, .error_code = error_code };
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
    InvalidGeneration,
    InvalidEncoding,
    InconsistentState,
};

pub fn validateCommand(_: AccountCommand) ValidationError!void {}

pub fn validateView(view: AccountView) ValidationError!void {
    try validateOptional(view.account_id, Limits.account_id_bytes);
    try validateOptional(view.display_name, Limits.display_name_bytes);
    try validateOptional(view.safe_diagnostic, Limits.safe_diagnostic_bytes);
    if (view.error_code == .none and view.safe_diagnostic.len != 0)
        return error.InconsistentState;
    if (view.can_cancel and view.state != .authorizing)
        return error.InconsistentState;
    switch (view.state) {
        .checking, .signed_out, .authorizing => {
            if (view.account_id.len != 0 or view.display_name.len != 0)
                return error.InconsistentState;
            if (view.state != .authorizing and view.can_cancel)
                return error.InconsistentState;
        },
        .authenticated => {
            if (view.account_id.len == 0 or view.display_name.len == 0)
                return error.InconsistentState;
        },
    }
}

pub fn validateFact(fact: AccountFact) ValidationError!void {
    try validateView(fact.view);
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

test "Account command sink returns only public acceptance metadata" {
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
    const sink: AccountCommandSink = .{ .context = &context, .submit_fn = Context.submit };
    const result = sink.submit(.begin_login);
    try std.testing.expect(result.accepted);
    try std.testing.expectEqual(ErrorCode.none, result.error_code);
    try std.testing.expectEqual(@as(?u64, 17), result.attempt_id);
    try std.testing.expectEqual(@as(usize, 1), context.calls);
}

test "Account view contains only identity state" {
    try validateView(.{
        .state = .authenticated,
        .account_id = "account-1",
        .display_name = "Metask User",
    });
    try std.testing.expectError(error.InconsistentState, validateView(.{
        .state = .signed_out,
        .account_id = "account-1",
    }));
}
