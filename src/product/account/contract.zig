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
    pub const decimal_bytes: usize = 64;
};

pub const AccountState = enum {
    checking,
    signed_out,
    authorizing,
    authenticated,
};

pub const SummaryOperation = enum {
    idle,
    refreshing,
};

pub const SummaryAvailability = enum {
    unavailable,
    loading,
    ready,
    stale,
};

pub const UsageEligibility = enum {
    unknown,
    disabled,
    enabled,
};

pub const WalletSummaryView = struct {
    availability: SummaryAvailability = .unavailable,
    balance_u: []const u8 = "",
    synced_at_unix_ms: []const u8 = "",
    error_code: ErrorCode = .none,
    safe_diagnostic: []const u8 = "",
};

pub const UsageTodayView = struct {
    input_tokens: []const u8,
    output_tokens: []const u8,
    cache_creation_tokens: []const u8,
    cache_read_tokens: []const u8,
    total_tokens: []const u8,
    actual_cost_u: []const u8,
};

pub const UsageTotalView = struct {
    total_tokens: []const u8,
    actual_cost_u: []const u8,
};

pub const UsageSummaryView = struct {
    availability: SummaryAvailability = .unavailable,
    today: ?UsageTodayView = null,
    total: ?UsageTotalView = null,
    synced_at_unix_ms: []const u8 = "",
    error_code: ErrorCode = .none,
    safe_diagnostic: []const u8 = "",
};

pub const AccountSummaryView = struct {
    operation: SummaryOperation = .idle,
    usage_eligibility: UsageEligibility = .unknown,
    wallet: WalletSummaryView = .{},
    usage: UsageSummaryView = .{},
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
    refresh_schedule_failed,
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
    summary: AccountSummaryView = .{},
};

pub const AccountFactKind = enum {
    restored,
    session_changed,
    operation_failed,
    signed_out,
    summary_changed,
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
    retry_refresh,
    refresh_summary,
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
            if (!isEmptySummary(view.summary)) return error.InconsistentState;
        },
        .authenticated => {
            if (view.account_id.len == 0 or view.display_name.len == 0)
                return error.InconsistentState;
        },
    }
    try validateSummary(view.summary);
}

fn validateSummary(summary: AccountSummaryView) ValidationError!void {
    try validateWallet(summary.wallet);
    try validateUsage(summary.usage);
    if (summary.usage_eligibility == .disabled and
        (summary.usage.availability != .unavailable or
            summary.usage.error_code != .none))
        return error.InconsistentState;
}

fn validateWallet(wallet: WalletSummaryView) ValidationError!void {
    try validateOptional(wallet.safe_diagnostic, Limits.safe_diagnostic_bytes);
    try validateSummaryError(wallet.error_code, wallet.safe_diagnostic);
    switch (wallet.availability) {
        .unavailable, .loading => {
            if (wallet.balance_u.len != 0 or wallet.synced_at_unix_ms.len != 0)
                return error.InconsistentState;
        },
        .ready, .stale => {
            try validateSignedDecimal(wallet.balance_u);
            try validateUnsignedDecimal(wallet.synced_at_unix_ms);
        },
    }
}

fn validateUsage(usage: UsageSummaryView) ValidationError!void {
    try validateOptional(usage.safe_diagnostic, Limits.safe_diagnostic_bytes);
    try validateSummaryError(usage.error_code, usage.safe_diagnostic);
    switch (usage.availability) {
        .unavailable, .loading => {
            if (usage.today != null or usage.total != null or
                usage.synced_at_unix_ms.len != 0)
                return error.InconsistentState;
        },
        .ready, .stale => {
            const today = usage.today orelse return error.InconsistentState;
            const total = usage.total orelse return error.InconsistentState;
            try validateUnsignedDecimal(today.input_tokens);
            try validateUnsignedDecimal(today.output_tokens);
            try validateUnsignedDecimal(today.cache_creation_tokens);
            try validateUnsignedDecimal(today.cache_read_tokens);
            try validateUnsignedDecimal(today.total_tokens);
            try validateUnsignedDecimal(today.actual_cost_u);
            try validateUnsignedDecimal(total.total_tokens);
            try validateUnsignedDecimal(total.actual_cost_u);
            try validateUnsignedDecimal(usage.synced_at_unix_ms);
        },
    }
}

fn validateSummaryError(error_code: ErrorCode, diagnostic: []const u8) ValidationError!void {
    if (error_code == .none and diagnostic.len != 0)
        return error.InconsistentState;
}

fn isEmptySummary(summary: AccountSummaryView) bool {
    return summary.operation == .idle and
        summary.usage_eligibility == .unknown and
        summary.wallet.availability == .unavailable and
        summary.wallet.balance_u.len == 0 and
        summary.wallet.synced_at_unix_ms.len == 0 and
        summary.wallet.error_code == .none and
        summary.wallet.safe_diagnostic.len == 0 and
        summary.usage.availability == .unavailable and
        summary.usage.today == null and
        summary.usage.total == null and
        summary.usage.synced_at_unix_ms.len == 0 and
        summary.usage.error_code == .none and
        summary.usage.safe_diagnostic.len == 0;
}

fn validateUnsignedDecimal(value: []const u8) ValidationError!void {
    try validateDecimal(value, false);
}

fn validateSignedDecimal(value: []const u8) ValidationError!void {
    try validateDecimal(value, true);
}

fn validateDecimal(value: []const u8, signed: bool) ValidationError!void {
    try validateRequired(value, Limits.decimal_bytes);
    var index: usize = 0;
    if (signed and value[0] == '-') {
        if (value.len == 1) return error.InconsistentState;
        index = 1;
    }
    var decimal_seen = false;
    while (index < value.len) : (index += 1) {
        const byte = value[index];
        if (byte == '.') {
            if (decimal_seen or index == 0 or index + 1 == value.len)
                return error.InconsistentState;
            decimal_seen = true;
        } else if (!std.ascii.isDigit(byte)) {
            return error.InconsistentState;
        }
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

test "Account view validates identity and nested summary independently" {
    try validateView(.{
        .state = .authenticated,
        .account_id = "account-1",
        .display_name = "Metask User",
        .summary = .{
            .usage_eligibility = .enabled,
            .wallet = .{
                .availability = .ready,
                .balance_u = "-1.25",
                .synced_at_unix_ms = "1000",
            },
            .usage = .{
                .availability = .ready,
                .today = .{
                    .input_tokens = "1",
                    .output_tokens = "2",
                    .cache_creation_tokens = "3",
                    .cache_read_tokens = "4",
                    .total_tokens = "10",
                    .actual_cost_u = "0.5",
                },
                .total = .{ .total_tokens = "20", .actual_cost_u = "1" },
                .synced_at_unix_ms = "1000",
            },
        },
    });
    try std.testing.expectError(error.InconsistentState, validateView(.{
        .state = .signed_out,
        .account_id = "account-1",
    }));
    try std.testing.expectError(error.InconsistentState, validateView(.{
        .state = .signed_out,
        .summary = .{ .operation = .refreshing },
    }));
    try std.testing.expectError(error.InconsistentState, validateView(.{
        .state = .authenticated,
        .account_id = "account-1",
        .display_name = "Metask User",
        .summary = .{
            .usage_eligibility = .disabled,
            .usage = .{
                .availability = .unavailable,
                .error_code = .metask_service_unavailable,
            },
        },
    }));
}
