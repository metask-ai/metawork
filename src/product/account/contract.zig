//! Product Account identity and authorization contract.
//!
//! Account owns the Metask login session and token lifecycle. Provider
//! catalogs, model selection, execution configuration, and consumer admission
//! belong to Models and Product Control.

const std = @import("std");

/// Host projection inspection only. Account retains ownership; visitors may
/// make bounded read-preparation copies, never retain a borrowed token.
pub const AccessTokenProjection = struct {
    context: *anyopaque,
    generation_fn: *const fn (*anyopaque) u64,
    visit_fn: *const fn (*anyopaque, *anyopaque, *const fn (*anyopaque, []const u8) std.mem.Allocator.Error!void) std.mem.Allocator.Error!void,

    pub fn generation(self: AccessTokenProjection) u64 {
        return self.generation_fn(self.context);
    }

    pub fn visit(self: AccessTokenProjection, context: *anyopaque, visitor: *const fn (*anyopaque, []const u8) std.mem.Allocator.Error!void) std.mem.Allocator.Error!void {
        return self.visit_fn(self.context, context, visitor);
    }
};

pub const Limits = struct {
    pub const account_id_bytes: usize = 256;
    pub const display_name_bytes: usize = 256;
    pub const email_bytes: usize = 320;
    pub const email_hint_bytes: usize = 324;
    pub const phone_hint_bytes: usize = 16;
    // Native SDK Keychain values are currently capped at 4096 bytes.
    pub const authorization_token_bytes: usize = 4096;
    pub const safe_diagnostic_bytes: usize = 512;
    pub const decimal_bytes: usize = 64;
    pub const calendar_date_bytes: usize = 10;
    pub const usage_history_days: usize = 371;
};

pub const recharge_page_url = "https://app.metask-ai.com/app/billing";

test "recharge page uses the canonical Metask billing URL" {
    try std.testing.expectEqualStrings(
        "https://app.metask-ai.com/app/billing",
        recharge_page_url,
    );
}

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

pub const UsageHistoryDayView = struct {
    date: []const u8,
    input_tokens: []const u8,
    output_tokens: []const u8,
    cache_creation_tokens: []const u8,
    cache_read_tokens: []const u8,
    total_tokens: []const u8,
    actual_cost_u: []const u8,
};

pub const UsageHistoryView = struct {
    availability: SummaryAvailability = .unavailable,
    start_date: []const u8 = "",
    end_date: []const u8 = "",
    days: []const UsageHistoryDayView = &.{},
    synced_at_unix_ms: []const u8 = "",
    error_code: ErrorCode = .none,
    safe_diagnostic: []const u8 = "",
};

pub const AccountSummaryView = struct {
    operation: SummaryOperation = .idle,
    usage_eligibility: UsageEligibility = .unknown,
    wallet: WalletSummaryView = .{},
    usage: UsageSummaryView = .{},
    history: UsageHistoryView = .{},
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
    email_hint: []const u8 = "",
    phone_hint: []const u8 = "",
    concurrency_limit: ?u32 = null,
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
    open_recharge,
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
    try validateOptional(view.email_hint, Limits.email_hint_bytes);
    try validateOptional(view.phone_hint, Limits.phone_hint_bytes);
    try validateOptional(view.safe_diagnostic, Limits.safe_diagnostic_bytes);
    if (view.error_code == .none and view.safe_diagnostic.len != 0)
        return error.InconsistentState;
    if (view.can_cancel and view.state != .authorizing)
        return error.InconsistentState;
    switch (view.state) {
        .checking, .signed_out, .authorizing => {
            if (view.account_id.len != 0 or view.display_name.len != 0 or
                view.email_hint.len != 0 or view.phone_hint.len != 0 or
                view.concurrency_limit != null)
                return error.InconsistentState;
            if (view.state != .authorizing and view.can_cancel)
                return error.InconsistentState;
            if (!isEmptySummary(view.summary)) return error.InconsistentState;
        },
        .authenticated => {
            if (view.account_id.len == 0) return error.InconsistentState;
        },
    }
    try validateSummary(view.summary);
}

fn validateSummary(summary: AccountSummaryView) ValidationError!void {
    try validateWallet(summary.wallet);
    try validateUsage(summary.usage);
    try validateHistory(summary.history);
    if (summary.usage_eligibility == .disabled and
        (summary.usage.availability != .unavailable or
            summary.usage.error_code != .none or
            summary.history.availability != .unavailable or
            summary.history.error_code != .none))
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

fn validateHistory(history: UsageHistoryView) ValidationError!void {
    try validateOptional(history.safe_diagnostic, Limits.safe_diagnostic_bytes);
    try validateSummaryError(history.error_code, history.safe_diagnostic);
    if (history.days.len > Limits.usage_history_days)
        return error.InconsistentState;
    switch (history.availability) {
        .unavailable, .loading => {
            if (history.start_date.len != 0 or history.end_date.len != 0 or
                history.days.len != 0 or history.synced_at_unix_ms.len != 0)
                return error.InconsistentState;
        },
        .ready, .stale => {
            try validateCalendarDate(history.start_date);
            try validateCalendarDate(history.end_date);
            if (std.mem.order(u8, history.start_date, history.end_date) == .gt)
                return error.InconsistentState;
            var previous: ?[]const u8 = null;
            for (history.days) |day| {
                try validateCalendarDate(day.date);
                if (std.mem.order(u8, day.date, history.start_date) == .lt or
                    std.mem.order(u8, day.date, history.end_date) == .gt)
                    return error.InconsistentState;
                if (previous) |date| {
                    if (std.mem.order(u8, date, day.date) != .lt)
                        return error.InconsistentState;
                }
                previous = day.date;
                try validateUnsignedDecimal(day.input_tokens);
                try validateUnsignedDecimal(day.output_tokens);
                try validateUnsignedDecimal(day.cache_creation_tokens);
                try validateUnsignedDecimal(day.cache_read_tokens);
                try validateUnsignedDecimal(day.total_tokens);
                try validateUnsignedDecimal(day.actual_cost_u);
            }
            try validateUnsignedDecimal(history.synced_at_unix_ms);
        },
    }
}

fn validateCalendarDate(value: []const u8) ValidationError!void {
    if (value.len != Limits.calendar_date_bytes or
        value[4] != '-' or value[7] != '-')
        return error.InconsistentState;
    for (value, 0..) |byte, index| {
        if (index == 4 or index == 7) continue;
        if (!std.ascii.isDigit(byte)) return error.InconsistentState;
    }
    const year = std.fmt.parseInt(u16, value[0..4], 10) catch
        return error.InconsistentState;
    const month = std.fmt.parseInt(u8, value[5..7], 10) catch
        return error.InconsistentState;
    const day = std.fmt.parseInt(u8, value[8..10], 10) catch
        return error.InconsistentState;
    if (year == 0 or month == 0 or month > 12 or day == 0 or
        day > daysInMonth(year, month))
        return error.InconsistentState;
}

fn daysInMonth(year: u16, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (@mod(year, 4) == 0 and
            (@mod(year, 100) != 0 or @mod(year, 400) == 0)) 29 else 28,
        else => 0,
    };
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
        summary.usage.safe_diagnostic.len == 0 and
        summary.history.availability == .unavailable and
        summary.history.start_date.len == 0 and
        summary.history.end_date.len == 0 and
        summary.history.days.len == 0 and
        summary.history.synced_at_unix_ms.len == 0 and
        summary.history.error_code == .none and
        summary.history.safe_diagnostic.len == 0;
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
    const integer_start = index;
    while (index < value.len and value[index] != '.') : (index += 1) {
        if (!std.ascii.isDigit(value[index])) return error.InconsistentState;
    }
    if (index == integer_start or
        (index - integer_start > 1 and value[integer_start] == '0'))
        return error.InconsistentState;
    if (index < value.len) {
        index += 1;
        if (index == value.len) return error.InconsistentState;
        while (index < value.len) : (index += 1) {
            if (!std.ascii.isDigit(value[index])) return error.InconsistentState;
        }
        if (value[value.len - 1] == '0') return error.InconsistentState;
    }
    if (value[0] == '-' and value.len == 2 and value[1] == '0')
        return error.InconsistentState;
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
    const history_days = [_]UsageHistoryDayView{.{
        .date = "2026-09-15",
        .input_tokens = "1",
        .output_tokens = "2",
        .cache_creation_tokens = "3",
        .cache_read_tokens = "4",
        .total_tokens = "10",
        .actual_cost_u = "0.5",
    }};
    try validateView(.{
        .state = .authenticated,
        .account_id = "account-1",
        .display_name = "Metask User",
        .concurrency_limit = 5,
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
            .history = .{
                .availability = .ready,
                .start_date = "2025-09-15",
                .end_date = "2026-09-15",
                .days = &history_days,
                .synced_at_unix_ms = "1000",
            },
        },
    });
    try validateView(.{
        .state = .authenticated,
        .account_id = "account-1",
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
        .concurrency_limit = 5,
        .summary = .{
            .usage_eligibility = .disabled,
            .usage = .{
                .availability = .unavailable,
                .error_code = .metask_service_unavailable,
            },
        },
    }));
    try std.testing.expectError(error.InconsistentState, validateView(.{
        .state = .authenticated,
        .account_id = "account-1",
        .display_name = "Metask User",
        .concurrency_limit = 5,
        .summary = .{
            .wallet = .{
                .availability = .ready,
                .balance_u = "01.25",
                .synced_at_unix_ms = "1000",
            },
        },
    }));
    const duplicate_days = [_]UsageHistoryDayView{ history_days[0], history_days[0] };
    try std.testing.expectError(error.InconsistentState, validateView(.{
        .state = .authenticated,
        .account_id = "account-1",
        .display_name = "Metask User",
        .concurrency_limit = 5,
        .summary = .{
            .usage_eligibility = .enabled,
            .history = .{
                .availability = .ready,
                .start_date = "2025-09-15",
                .end_date = "2026-09-15",
                .days = &duplicate_days,
                .synced_at_unix_ms = "1000",
            },
        },
    }));
}
