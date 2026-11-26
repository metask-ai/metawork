//! Product snapshot composition copy of the canonical, secret-free Account
//! identity projection. Model providers, catalogs, and selections are copied
//! from Models independently.

const std = @import("std");
const account = @import("metawork_account_contract");

fn FixedText(comptime capacity: usize) type {
    return struct {
        bytes: [capacity]u8 = undefined,
        len: usize = 0,

        const Self = @This();

        fn setNoFail(self: *Self, value: []const u8) void {
            std.debug.assert(value.len <= capacity);
            std.debug.assert(std.unicode.utf8ValidateSlice(value));
            @memcpy(self.bytes[0..value.len], value);
            self.len = value.len;
        }

        fn view(self: *const Self) []const u8 {
            return self.bytes[0..self.len];
        }
    };
}

const HistoryDayProjection = struct {
    date: FixedText(account.Limits.calendar_date_bytes) = .{},
    input_tokens: FixedText(account.Limits.decimal_bytes) = .{},
    output_tokens: FixedText(account.Limits.decimal_bytes) = .{},
    cache_creation_tokens: FixedText(account.Limits.decimal_bytes) = .{},
    cache_read_tokens: FixedText(account.Limits.decimal_bytes) = .{},
    total_tokens: FixedText(account.Limits.decimal_bytes) = .{},
    actual_cost_u: FixedText(account.Limits.decimal_bytes) = .{},
};

pub const Projection = struct {
    allocator: std.mem.Allocator,
    state: account.AccountState = .checking,
    actions: account.AccountActions = .{},
    cannot_reach: bool = false,
    attempt: ?struct {
        id: u64,
        action: account.AccountCommand,
        outcome: ?account.AccountAttempt.Outcome,
        error_code: account.ErrorCode,
        safe_diagnostic: FixedText(account.Limits.safe_diagnostic_bytes) = .{},
    } = null,
    account_id: FixedText(account.Limits.account_id_bytes) = .{},
    display_name: FixedText(account.Limits.display_name_bytes) = .{},
    email_hint: FixedText(account.Limits.email_hint_bytes) = .{},
    phone_hint: FixedText(account.Limits.phone_hint_bytes) = .{},
    safe_diagnostic: FixedText(account.Limits.safe_diagnostic_bytes) = .{},
    error_code: account.ErrorCode = .none,
    summary_operation: account.SummaryOperation = .idle,
    usage_eligibility: account.UsageEligibility = .unknown,
    history_availability: account.SummaryAvailability = .unavailable,
    history_start_date: FixedText(account.Limits.calendar_date_bytes) = .{},
    history_end_date: FixedText(account.Limits.calendar_date_bytes) = .{},
    history_days: [account.Limits.usage_history_days]HistoryDayProjection =
        @splat(.{}),
    history_day_views: [account.Limits.usage_history_days]account.UsageHistoryDayView =
        undefined,
    history_days_len: usize = 0,
    history_synced_at_unix_ms: FixedText(account.Limits.decimal_bytes) = .{},
    history_error_code: account.ErrorCode = .none,
    history_safe_diagnostic: FixedText(account.Limits.safe_diagnostic_bytes) = .{},

    pub fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!Projection {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Projection) void {
        self.* = undefined;
    }

    pub fn commitNoFail(self: *Projection, fact: account.AccountFact) void {
        account.validateFact(fact) catch
            @panic("Account published an invalid AccountFact");
        const source = fact.view;
        self.state = source.state;
        self.actions = source.actions;
        self.cannot_reach = source.cannot_reach;
        self.attempt = if (source.attempt) |attempt| .{
            .id = attempt.id,
            .action = attempt.action,
            .outcome = attempt.outcome,
            .error_code = attempt.error_code,
        } else null;
        if (self.attempt) |*attempt| attempt.safe_diagnostic.setNoFail(source.attempt.?.safe_diagnostic);
        self.account_id.setNoFail(source.account_id);
        self.display_name.setNoFail(source.display_name);
        self.email_hint.setNoFail(source.email_hint);
        self.phone_hint.setNoFail(source.phone_hint);
        self.error_code = source.error_code;
        self.safe_diagnostic.setNoFail(source.safe_diagnostic);
        const summary = source.summary;
        self.summary_operation = summary.operation;
        self.usage_eligibility = summary.usage_eligibility;
        self.history_availability = summary.history.availability;
        self.history_start_date.setNoFail(summary.history.start_date);
        self.history_end_date.setNoFail(summary.history.end_date);
        self.history_days_len = summary.history.days.len;
        for (summary.history.days, 0..) |day, index| {
            self.history_days[index].date.setNoFail(day.date);
            self.history_days[index].input_tokens.setNoFail(day.input_tokens);
            self.history_days[index].output_tokens.setNoFail(day.output_tokens);
            self.history_days[index].cache_creation_tokens.setNoFail(day.cache_creation_tokens);
            self.history_days[index].cache_read_tokens.setNoFail(day.cache_read_tokens);
            self.history_days[index].total_tokens.setNoFail(day.total_tokens);
            self.history_days[index].actual_cost_u.setNoFail(day.actual_cost_u);
        }
        self.history_synced_at_unix_ms.setNoFail(summary.history.synced_at_unix_ms);
        self.history_error_code = summary.history.error_code;
        self.history_safe_diagnostic.setNoFail(summary.history.safe_diagnostic);
    }

    pub fn view(self: *Projection) account.AccountView {
        for (self.history_days[0..self.history_days_len], 0..) |*day, index| {
            self.history_day_views[index] = .{
                .date = day.date.view(),
                .input_tokens = day.input_tokens.view(),
                .output_tokens = day.output_tokens.view(),
                .cache_creation_tokens = day.cache_creation_tokens.view(),
                .cache_read_tokens = day.cache_read_tokens.view(),
                .total_tokens = day.total_tokens.view(),
                .actual_cost_u = day.actual_cost_u.view(),
            };
        }
        return .{
            .state = self.state,
            .actions = self.actions,
            .cannot_reach = self.cannot_reach,
            .attempt = if (self.attempt) |*attempt| .{
                .id = attempt.id,
                .action = attempt.action,
                .outcome = attempt.outcome,
                .error_code = attempt.error_code,
                .safe_diagnostic = attempt.safe_diagnostic.view(),
            } else null,
            .account_id = self.account_id.view(),
            .display_name = self.display_name.view(),
            .email_hint = self.email_hint.view(),
            .phone_hint = self.phone_hint.view(),
            .error_code = self.error_code,
            .safe_diagnostic = self.safe_diagnostic.view(),
            .summary = .{
                .operation = self.summary_operation,
                .usage_eligibility = self.usage_eligibility,
                .history = .{
                    .availability = self.history_availability,
                    .start_date = self.history_start_date.view(),
                    .end_date = self.history_end_date.view(),
                    .days = self.history_day_views[0..self.history_days_len],
                    .synced_at_unix_ms = self.history_synced_at_unix_ms.view(),
                    .error_code = self.history_error_code,
                    .safe_diagnostic = self.history_safe_diagnostic.view(),
                },
            },
        };
    }

    pub fn accountId(self: *const Projection) []const u8 {
        return self.account_id.view();
    }
};

test "Account projection copies identity without allocating after initialization" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var projection = try Projection.init(failing.allocator());
    defer projection.deinit();

    const fact: account.AccountFact = .{ .view = .{ .state = .signed_out } };
    const allocations_after_init = failing.alloc_index;
    failing.fail_index = allocations_after_init;
    projection.commitNoFail(fact);
    const first = projection.view();
    try account.validateView(first);
    try std.testing.expectEqual(account.AccountState.signed_out, first.state);
    projection.commitNoFail(fact);
    _ = projection.view();
    try std.testing.expectEqual(allocations_after_init, failing.alloc_index);
}

test "Account projection copies the complete summary without allocating" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var projection = try Projection.init(failing.allocator());
    defer projection.deinit();
    const history_days = [_]account.UsageHistoryDayView{.{
        .date = "2026-09-15",
        .input_tokens = "1",
        .output_tokens = "2",
        .cache_creation_tokens = "3",
        .cache_read_tokens = "4",
        .total_tokens = "10",
        .actual_cost_u = "0.25",
    }};
    const fact: account.AccountFact = .{
        .view = .{
            .state = .authenticated,
            .account_id = "42",
            .display_name = "Fixture User",
            .email_hint = "f***@example.com",
            .phone_hint = "138****8000",
            .summary = .{
                .usage_eligibility = .enabled,
                .history = .{
                    .availability = .ready,
                    .start_date = "2025-09-15",
                    .end_date = "2026-09-15",
                    .days = &history_days,
                    .synced_at_unix_ms = "1720000000000",
                },
            },
        },
    };
    const allocations_after_init = failing.alloc_index;
    failing.fail_index = allocations_after_init;
    projection.commitNoFail(fact);
    const view = projection.view();
    try account.validateView(view);
    try std.testing.expectEqualStrings("138****8000", view.phone_hint);
    try std.testing.expectEqualStrings("2025-09-15", view.summary.history.start_date);
    try std.testing.expectEqualStrings("10", view.summary.history.days[0].total_tokens);
    try std.testing.expectEqual(allocations_after_init, failing.alloc_index);
}
