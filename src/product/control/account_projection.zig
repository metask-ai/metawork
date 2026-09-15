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
    can_cancel: bool = false,
    account_id: FixedText(account.Limits.account_id_bytes) = .{},
    display_name: FixedText(account.Limits.display_name_bytes) = .{},
    email_hint: FixedText(account.Limits.email_hint_bytes) = .{},
    concurrency_limit: ?u32 = null,
    safe_diagnostic: FixedText(account.Limits.safe_diagnostic_bytes) = .{},
    error_code: account.ErrorCode = .none,
    summary_operation: account.SummaryOperation = .idle,
    usage_eligibility: account.UsageEligibility = .unknown,
    wallet_availability: account.SummaryAvailability = .unavailable,
    wallet_balance_u: FixedText(account.Limits.decimal_bytes) = .{},
    wallet_synced_at_unix_ms: FixedText(account.Limits.decimal_bytes) = .{},
    wallet_error_code: account.ErrorCode = .none,
    wallet_safe_diagnostic: FixedText(account.Limits.safe_diagnostic_bytes) = .{},
    usage_availability: account.SummaryAvailability = .unavailable,
    usage_has_data: bool = false,
    usage_today_input_tokens: FixedText(account.Limits.decimal_bytes) = .{},
    usage_today_output_tokens: FixedText(account.Limits.decimal_bytes) = .{},
    usage_today_cache_creation_tokens: FixedText(account.Limits.decimal_bytes) = .{},
    usage_today_cache_read_tokens: FixedText(account.Limits.decimal_bytes) = .{},
    usage_today_total_tokens: FixedText(account.Limits.decimal_bytes) = .{},
    usage_today_actual_cost_u: FixedText(account.Limits.decimal_bytes) = .{},
    usage_total_tokens: FixedText(account.Limits.decimal_bytes) = .{},
    usage_total_actual_cost_u: FixedText(account.Limits.decimal_bytes) = .{},
    usage_synced_at_unix_ms: FixedText(account.Limits.decimal_bytes) = .{},
    usage_error_code: account.ErrorCode = .none,
    usage_safe_diagnostic: FixedText(account.Limits.safe_diagnostic_bytes) = .{},
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
        self.can_cancel = source.can_cancel;
        self.account_id.setNoFail(source.account_id);
        self.display_name.setNoFail(source.display_name);
        self.email_hint.setNoFail(source.email_hint);
        self.concurrency_limit = source.concurrency_limit;
        self.error_code = source.error_code;
        self.safe_diagnostic.setNoFail(source.safe_diagnostic);
        const summary = source.summary;
        self.summary_operation = summary.operation;
        self.usage_eligibility = summary.usage_eligibility;
        self.wallet_availability = summary.wallet.availability;
        self.wallet_balance_u.setNoFail(summary.wallet.balance_u);
        self.wallet_synced_at_unix_ms.setNoFail(summary.wallet.synced_at_unix_ms);
        self.wallet_error_code = summary.wallet.error_code;
        self.wallet_safe_diagnostic.setNoFail(summary.wallet.safe_diagnostic);
        self.usage_availability = summary.usage.availability;
        self.usage_synced_at_unix_ms.setNoFail(summary.usage.synced_at_unix_ms);
        self.usage_error_code = summary.usage.error_code;
        self.usage_safe_diagnostic.setNoFail(summary.usage.safe_diagnostic);
        self.usage_has_data = summary.usage.today != null;
        if (summary.usage.today) |today| {
            const total = summary.usage.total.?;
            self.usage_today_input_tokens.setNoFail(today.input_tokens);
            self.usage_today_output_tokens.setNoFail(today.output_tokens);
            self.usage_today_cache_creation_tokens.setNoFail(today.cache_creation_tokens);
            self.usage_today_cache_read_tokens.setNoFail(today.cache_read_tokens);
            self.usage_today_total_tokens.setNoFail(today.total_tokens);
            self.usage_today_actual_cost_u.setNoFail(today.actual_cost_u);
            self.usage_total_tokens.setNoFail(total.total_tokens);
            self.usage_total_actual_cost_u.setNoFail(total.actual_cost_u);
        } else {
            self.usage_today_input_tokens.setNoFail("");
            self.usage_today_output_tokens.setNoFail("");
            self.usage_today_cache_creation_tokens.setNoFail("");
            self.usage_today_cache_read_tokens.setNoFail("");
            self.usage_today_total_tokens.setNoFail("");
            self.usage_today_actual_cost_u.setNoFail("");
            self.usage_total_tokens.setNoFail("");
            self.usage_total_actual_cost_u.setNoFail("");
        }
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
            .can_cancel = self.can_cancel,
            .account_id = self.account_id.view(),
            .display_name = self.display_name.view(),
            .email_hint = self.email_hint.view(),
            .concurrency_limit = self.concurrency_limit,
            .error_code = self.error_code,
            .safe_diagnostic = self.safe_diagnostic.view(),
            .summary = .{
                .operation = self.summary_operation,
                .usage_eligibility = self.usage_eligibility,
                .wallet = .{
                    .availability = self.wallet_availability,
                    .balance_u = self.wallet_balance_u.view(),
                    .synced_at_unix_ms = self.wallet_synced_at_unix_ms.view(),
                    .error_code = self.wallet_error_code,
                    .safe_diagnostic = self.wallet_safe_diagnostic.view(),
                },
                .usage = .{
                    .availability = self.usage_availability,
                    .today = if (self.usage_has_data) .{
                        .input_tokens = self.usage_today_input_tokens.view(),
                        .output_tokens = self.usage_today_output_tokens.view(),
                        .cache_creation_tokens = self.usage_today_cache_creation_tokens.view(),
                        .cache_read_tokens = self.usage_today_cache_read_tokens.view(),
                        .total_tokens = self.usage_today_total_tokens.view(),
                        .actual_cost_u = self.usage_today_actual_cost_u.view(),
                    } else null,
                    .total = if (self.usage_has_data) .{
                        .total_tokens = self.usage_total_tokens.view(),
                        .actual_cost_u = self.usage_total_actual_cost_u.view(),
                    } else null,
                    .synced_at_unix_ms = self.usage_synced_at_unix_ms.view(),
                    .error_code = self.usage_error_code,
                    .safe_diagnostic = self.usage_safe_diagnostic.view(),
                },
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

    const fact: account.AccountFact = .{
        .kind = .restored,
        .view = .{ .state = .signed_out },
    };
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
        .kind = .summary_changed,
        .view = .{
            .state = .authenticated,
            .account_id = "42",
            .display_name = "Fixture User",
            .email_hint = "f***@example.com",
            .concurrency_limit = 5,
            .summary = .{
                .usage_eligibility = .enabled,
                .wallet = .{
                    .availability = .ready,
                    .balance_u = "-1.25",
                    .synced_at_unix_ms = "1720000000000",
                },
                .usage = .{
                    .availability = .ready,
                    .today = .{
                        .input_tokens = "10",
                        .output_tokens = "20",
                        .cache_creation_tokens = "3",
                        .cache_read_tokens = "4",
                        .total_tokens = "37",
                        .actual_cost_u = "0.125",
                    },
                    .total = .{ .total_tokens = "300", .actual_cost_u = "2.5" },
                    .synced_at_unix_ms = "1720000000000",
                },
                .history = .{
                    .availability = .ready,
                    .start_date = "2025-09-16",
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
    try std.testing.expectEqualStrings("-1.25", view.summary.wallet.balance_u);
    try std.testing.expectEqualStrings("37", view.summary.usage.today.?.total_tokens);
    try std.testing.expectEqualStrings("2.5", view.summary.usage.total.?.actual_cost_u);
    try std.testing.expectEqualStrings("2025-09-16", view.summary.history.start_date);
    try std.testing.expectEqualStrings("10", view.summary.history.days[0].total_tokens);
    try std.testing.expectEqual(allocations_after_init, failing.alloc_index);
}
