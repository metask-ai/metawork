//! Account-owned, secret-free Metask wallet and usage summary.
const std = @import("std");
const contract = @import("metawork_account_contract");

pub const ProtocolError = error{InvalidSummaryResponse};

pub const Decimal = struct {
    bytes: [contract.Limits.decimal_bytes]u8 = undefined,
    len: usize = 0,

    pub fn view(self: *const Decimal) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn fromInteger(value: i64, allow_negative: bool) ProtocolError!Decimal {
        if (!allow_negative and value < 0) return error.InvalidSummaryResponse;
        var result: Decimal = .{};
        const rendered = std.fmt.bufPrint(&result.bytes, "{d}", .{value}) catch
            return error.InvalidSummaryResponse;
        result.len = rendered.len;
        return result;
    }

    pub fn fromFloat(value: f64, allow_negative: bool) ProtocolError!Decimal {
        if (!std.math.isFinite(value) or (!allow_negative and value < 0))
            return error.InvalidSummaryResponse;
        if (value == 0) return fromInteger(0, allow_negative);
        var result: Decimal = .{};
        const rendered = std.fmt.bufPrint(&result.bytes, "{d:.8}", .{value}) catch
            return error.InvalidSummaryResponse;
        var end = rendered.len;
        while (end > 0 and result.bytes[end - 1] == '0') end -= 1;
        if (end > 0 and result.bytes[end - 1] == '.') end -= 1;
        if (end == 0 or (end == 1 and result.bytes[0] == '-'))
            return error.InvalidSummaryResponse;
        result.len = end;
        return result;
    }
};

pub const WalletData = struct {
    balance_u: Decimal,
    usage_eligibility: contract.UsageEligibility,
};

pub const UsageData = struct {
    today_input_tokens: Decimal,
    today_output_tokens: Decimal,
    today_cache_creation_tokens: Decimal,
    today_cache_read_tokens: Decimal,
    today_total_tokens: Decimal,
    today_actual_cost_u: Decimal,
    total_tokens: Decimal,
    total_actual_cost_u: Decimal,
};

const WalletEnvelope = struct {
    code: i64,
    data: struct {
        id: i64,
        balance: ?f64 = null,
        run_mode: ?[]const u8 = null,
    },
};

pub fn parseWallet(body: []const u8, expected_account_id: []const u8) ProtocolError!WalletData {
    if (body.len == 0 or body.len > 16 * 1024)
        return error.InvalidSummaryResponse;
    var scratch: [32 * 1024]u8 = undefined;
    defer std.crypto.secureZero(u8, &scratch);
    var fixed = std.heap.FixedBufferAllocator.init(&scratch);
    var parsed = std.json.parseFromSlice(
        WalletEnvelope,
        fixed.allocator(),
        body,
        .{ .ignore_unknown_fields = true },
    ) catch return error.InvalidSummaryResponse;
    defer parsed.deinit();
    const raw = parsed.value;
    var account_id_storage: [32]u8 = undefined;
    const account_id = std.fmt.bufPrint(
        &account_id_storage,
        "{d}",
        .{raw.data.id},
    ) catch return error.InvalidSummaryResponse;
    if (raw.code != 0 or raw.data.id <= 0 or
        !std.mem.eql(u8, account_id, expected_account_id))
        return error.InvalidSummaryResponse;
    const balance = raw.data.balance orelse return error.InvalidSummaryResponse;
    return .{
        .balance_u = try Decimal.fromFloat(balance, true),
        .usage_eligibility = if (raw.data.run_mode) |mode|
            if (std.mem.eql(u8, mode, "standard"))
                .enabled
            else if (std.mem.eql(u8, mode, "simple"))
                .disabled
            else
                .unknown
        else
            .unknown,
    };
}

const UsageEnvelope = struct {
    code: i64,
    data: struct {
        total_tokens: i64,
        total_actual_cost: f64,
        today_input_tokens: i64,
        today_output_tokens: i64,
        today_cache_creation_tokens: i64,
        today_cache_read_tokens: i64,
        today_tokens: i64,
        today_actual_cost: f64,
    },
};

pub fn parseUsage(body: []const u8) ProtocolError!UsageData {
    if (body.len == 0 or body.len > 32 * 1024)
        return error.InvalidSummaryResponse;
    var scratch: [64 * 1024]u8 = undefined;
    defer std.crypto.secureZero(u8, &scratch);
    var fixed = std.heap.FixedBufferAllocator.init(&scratch);
    var parsed = std.json.parseFromSlice(
        UsageEnvelope,
        fixed.allocator(),
        body,
        .{ .ignore_unknown_fields = true },
    ) catch return error.InvalidSummaryResponse;
    defer parsed.deinit();
    const raw = parsed.value;
    if (raw.code != 0) return error.InvalidSummaryResponse;
    return .{
        .today_input_tokens = try Decimal.fromInteger(raw.data.today_input_tokens, false),
        .today_output_tokens = try Decimal.fromInteger(raw.data.today_output_tokens, false),
        .today_cache_creation_tokens = try Decimal.fromInteger(raw.data.today_cache_creation_tokens, false),
        .today_cache_read_tokens = try Decimal.fromInteger(raw.data.today_cache_read_tokens, false),
        .today_total_tokens = try Decimal.fromInteger(raw.data.today_tokens, false),
        .today_actual_cost_u = try Decimal.fromFloat(raw.data.today_actual_cost, false),
        .total_tokens = try Decimal.fromInteger(raw.data.total_tokens, false),
        .total_actual_cost_u = try Decimal.fromFloat(raw.data.total_actual_cost, false),
    };
}

pub const Outcome = union(enum) {
    not_requested,
    succeeded: UsageData,
    failed: contract.ErrorCode,
};

pub const Completion = struct {
    attempt_id: u64,
    authorization_generation: u64,
    principal_ref: [contract.Limits.account_id_bytes]u8 = undefined,
    principal_ref_len: usize,
    synced_at_unix_ms: Decimal,
    wallet: union(enum) {
        succeeded: WalletData,
        failed: contract.ErrorCode,
    },
    usage: Outcome,

    pub fn principalRef(self: *const Completion) []const u8 {
        return self.principal_ref[0..self.principal_ref_len];
    }
};

const Authority = struct {
    generation: u64,
    principal_ref: [contract.Limits.account_id_bytes]u8 = undefined,
    principal_ref_len: usize,

    fn init(principal_ref: []const u8, generation: u64) Authority {
        std.debug.assert(principal_ref.len > 0 and principal_ref.len <= contract.Limits.account_id_bytes);
        std.debug.assert(generation != 0);
        var result: Authority = .{
            .generation = generation,
            .principal_ref_len = principal_ref.len,
        };
        @memcpy(result.principal_ref[0..principal_ref.len], principal_ref);
        return result;
    }

    fn principalRef(self: *const Authority) []const u8 {
        return self.principal_ref[0..self.principal_ref_len];
    }

    fn matches(self: Authority, principal_ref: []const u8, generation: u64) bool {
        return self.generation == generation and
            std.mem.eql(u8, self.principalRef(), principal_ref);
    }
};

const WalletState = struct {
    availability: contract.SummaryAvailability = .unavailable,
    data: ?WalletData = null,
    synced_at_unix_ms: Decimal = .{},
    error_code: contract.ErrorCode = .none,

    fn begin(self: *WalletState) void {
        self.error_code = .none;
        if (self.data == null) self.availability = .loading;
    }

    fn succeed(self: *WalletState, data: WalletData, synced_at: Decimal) void {
        self.* = .{
            .availability = .ready,
            .data = data,
            .synced_at_unix_ms = synced_at,
        };
    }

    fn fail(self: *WalletState, error_code: contract.ErrorCode) void {
        self.error_code = error_code;
        self.availability = if (self.data == null) .unavailable else .stale;
    }

    fn view(self: *const WalletState) contract.WalletSummaryView {
        return .{
            .availability = self.availability,
            .balance_u = if (self.data) |*data| data.balance_u.view() else "",
            .synced_at_unix_ms = if (self.data != null) self.synced_at_unix_ms.view() else "",
            .error_code = self.error_code,
        };
    }
};

const UsageState = struct {
    availability: contract.SummaryAvailability = .unavailable,
    data: ?UsageData = null,
    synced_at_unix_ms: Decimal = .{},
    error_code: contract.ErrorCode = .none,

    fn begin(self: *UsageState, eligibility: contract.UsageEligibility) void {
        self.error_code = .none;
        if (eligibility == .disabled) {
            self.* = .{};
        } else if (self.data == null) {
            self.availability = .loading;
        }
    }

    fn succeed(self: *UsageState, data: UsageData, synced_at: Decimal) void {
        self.* = .{
            .availability = .ready,
            .data = data,
            .synced_at_unix_ms = synced_at,
        };
    }

    fn fail(self: *UsageState, error_code: contract.ErrorCode) void {
        self.error_code = error_code;
        self.availability = if (self.data == null) .unavailable else .stale;
    }

    fn view(self: *const UsageState) contract.UsageSummaryView {
        const today: ?contract.UsageTodayView = if (self.data) |*data| .{
            .input_tokens = data.today_input_tokens.view(),
            .output_tokens = data.today_output_tokens.view(),
            .cache_creation_tokens = data.today_cache_creation_tokens.view(),
            .cache_read_tokens = data.today_cache_read_tokens.view(),
            .total_tokens = data.today_total_tokens.view(),
            .actual_cost_u = data.today_actual_cost_u.view(),
        } else null;
        const total: ?contract.UsageTotalView = if (self.data) |*data| .{
            .total_tokens = data.total_tokens.view(),
            .actual_cost_u = data.total_actual_cost_u.view(),
        } else null;
        return .{
            .availability = self.availability,
            .today = today,
            .total = total,
            .synced_at_unix_ms = if (self.data != null) self.synced_at_unix_ms.view() else "",
            .error_code = self.error_code,
        };
    }
};

pub const RefreshPreparation = struct {
    attempt_id: u64,
};

pub const State = struct {
    operation: contract.SummaryOperation = .idle,
    usage_eligibility: contract.UsageEligibility = .unknown,
    wallet: WalletState = .{},
    usage: UsageState = .{},
    authority: ?Authority = null,
    active_attempt_id: ?u64 = null,
    next_attempt_id: u64 = 1,

    pub fn matchesAuthority(
        self: *const State,
        principal_ref: []const u8,
        authorization_generation: u64,
    ) bool {
        const current = self.authority orelse return false;
        return current.matches(principal_ref, authorization_generation);
    }

    pub fn begin(
        self: *State,
        principal_ref: []const u8,
        authorization_generation: u64,
    ) error{OperationInProgress}!RefreshPreparation {
        if (self.active_attempt_id != null) return error.OperationInProgress;
        if (self.authority == null or
            !self.authority.?.matches(principal_ref, authorization_generation))
        {
            const next_attempt_id = self.next_attempt_id;
            self.* = .{
                .authority = Authority.init(principal_ref, authorization_generation),
                .next_attempt_id = next_attempt_id,
            };
        }
        const attempt_id = self.next_attempt_id;
        self.next_attempt_id +%= 1;
        if (self.next_attempt_id == 0) self.next_attempt_id = 1;
        self.active_attempt_id = attempt_id;
        self.operation = .refreshing;
        self.wallet.begin();
        self.usage.begin(self.usage_eligibility);
        return .{ .attempt_id = attempt_id };
    }

    pub fn fail(
        self: *State,
        attempt_id: u64,
        error_code: contract.ErrorCode,
    ) bool {
        if (self.active_attempt_id != attempt_id) return false;
        self.active_attempt_id = null;
        self.operation = .idle;
        self.wallet.fail(error_code);
        if (self.usage_eligibility != .disabled) self.usage.fail(error_code);
        return true;
    }

    pub fn complete(self: *State, completion: *const Completion) bool {
        const authority = self.authority orelse return false;
        if (self.active_attempt_id != completion.attempt_id or
            !authority.matches(completion.principalRef(), completion.authorization_generation))
            return false;
        self.active_attempt_id = null;
        self.operation = .idle;
        switch (completion.wallet) {
            .succeeded => |wallet| {
                self.wallet.succeed(wallet, completion.synced_at_unix_ms);
                self.usage_eligibility = wallet.usage_eligibility;
                switch (wallet.usage_eligibility) {
                    .disabled => self.usage = .{},
                    .unknown => self.usage.fail(.metask_protocol_invalid),
                    .enabled => switch (completion.usage) {
                        .succeeded => |usage| self.usage.succeed(usage, completion.synced_at_unix_ms),
                        .failed => |error_code| self.usage.fail(error_code),
                        .not_requested => self.usage.fail(.metask_protocol_invalid),
                    },
                }
            },
            .failed => |error_code| {
                self.wallet.fail(error_code);
                if (self.usage_eligibility != .disabled) self.usage.fail(error_code);
            },
        }
        return true;
    }

    pub fn clearAuthorization(self: *State) bool {
        const changed = self.authority != null or self.active_attempt_id != null or
            self.operation != .idle or self.usage_eligibility != .unknown or
            self.wallet.availability != .unavailable or
            self.usage.availability != .unavailable;
        const next_attempt_id = self.next_attempt_id;
        self.* = .{ .next_attempt_id = next_attempt_id };
        return changed;
    }

    pub fn view(self: *const State) contract.AccountSummaryView {
        return .{
            .operation = self.operation,
            .usage_eligibility = self.usage_eligibility,
            .wallet = self.wallet.view(),
            .usage = self.usage.view(),
        };
    }
};

test "wallet summary accepts overdraft balance and normalizes run mode" {
    const wallet = try parseWallet(
        \\{"code":0,"data":{"id":42,"username":"User","balance":-12.5,"run_mode":"standard","email":"ignored@example.com"}}
    , "42");
    try std.testing.expectEqualStrings("-12.5", wallet.balance_u.view());
    try std.testing.expectEqual(contract.UsageEligibility.enabled, wallet.usage_eligibility);
}

test "wallet summary keeps unknown optional run mode out of login semantics" {
    const wallet = try parseWallet(
        \\{"code":0,"data":{"id":42,"balance":100}}
    , "42");
    try std.testing.expectEqualStrings("100", wallet.balance_u.view());
    try std.testing.expectEqual(contract.UsageEligibility.unknown, wallet.usage_eligibility);
    const mismatched =
        \\{"code":0,"data":{"id":7,"balance":100}}
    ;
    try std.testing.expectError(
        error.InvalidSummaryResponse,
        parseWallet(mismatched, "42"),
    );
}

test "usage summary rejects negative counters and normalizes costs" {
    const usage = try parseUsage(
        \\{"code":0,"data":{"total_tokens":120400000,"total_actual_cost":23420.1178,"today_input_tokens":344800,"today_output_tokens":496100,"today_cache_creation_tokens":0,"today_cache_read_tokens":1490000,"today_tokens":1200000,"today_actual_cost":149.739}}
    );
    try std.testing.expectEqualStrings("120400000", usage.total_tokens.view());
    try std.testing.expectEqualStrings("23420.1178", usage.total_actual_cost_u.view());
    try std.testing.expectEqualStrings("149.739", usage.today_actual_cost_u.view());
    try std.testing.expectError(
        error.InvalidSummaryResponse,
        parseUsage(
            \\{"code":0,"data":{"total_tokens":-1,"total_actual_cost":1,"today_input_tokens":0,"today_output_tokens":0,"today_cache_creation_tokens":0,"today_cache_read_tokens":0,"today_tokens":0,"today_actual_cost":0}}
        ),
    );
}

test "summary state preserves partial success as stale and clears on authorization loss" {
    var state: State = .{};
    const first = try state.begin("42", 3);
    var completion: Completion = .{
        .attempt_id = first.attempt_id,
        .authorization_generation = 3,
        .principal_ref_len = 2,
        .synced_at_unix_ms = try Decimal.fromInteger(1000, false),
        .wallet = .{ .succeeded = .{
            .balance_u = try Decimal.fromFloat(10.5, true),
            .usage_eligibility = .enabled,
        } },
        .usage = .{ .succeeded = try parseUsage(
            \\{"code":0,"data":{"total_tokens":8,"total_actual_cost":2,"today_input_tokens":1,"today_output_tokens":2,"today_cache_creation_tokens":3,"today_cache_read_tokens":4,"today_tokens":10,"today_actual_cost":1}}
        ) },
    };
    @memcpy(completion.principal_ref[0..2], "42");
    try std.testing.expect(state.complete(&completion));
    const retry = try state.begin("42", 3);
    try std.testing.expect(state.fail(retry.attempt_id, .metask_service_unavailable));
    const stale = state.view();
    try std.testing.expectEqual(contract.SummaryAvailability.stale, stale.wallet.availability);
    try std.testing.expectEqual(contract.SummaryAvailability.stale, stale.usage.availability);
    try std.testing.expectEqualStrings("10.5", stale.wallet.balance_u);
    try std.testing.expect(state.clearAuthorization());
    try contract.validateView(.{ .state = .signed_out, .summary = state.view() });
}

test "summary state ignores stale generation completion and disables usage explicitly" {
    var state: State = .{};
    const first = try state.begin("42", 1);
    try std.testing.expect(state.clearAuthorization());
    const second = try state.begin("42", 2);
    var stale: Completion = .{
        .attempt_id = first.attempt_id,
        .authorization_generation = 1,
        .principal_ref_len = 2,
        .synced_at_unix_ms = try Decimal.fromInteger(1000, false),
        .wallet = .{ .failed = .metask_service_unavailable },
        .usage = .not_requested,
    };
    @memcpy(stale.principal_ref[0..2], "42");
    try std.testing.expect(!state.complete(&stale));
    var disabled: Completion = .{
        .attempt_id = second.attempt_id,
        .authorization_generation = 2,
        .principal_ref_len = 2,
        .synced_at_unix_ms = try Decimal.fromInteger(2000, false),
        .wallet = .{ .succeeded = .{
            .balance_u = try Decimal.fromFloat(5, true),
            .usage_eligibility = .disabled,
        } },
        .usage = .not_requested,
    };
    @memcpy(disabled.principal_ref[0..2], "42");
    try std.testing.expect(state.complete(&disabled));
    const view = state.view();
    try std.testing.expectEqual(contract.UsageEligibility.disabled, view.usage_eligibility);
    try std.testing.expectEqual(contract.SummaryAvailability.unavailable, view.usage.availability);
    try std.testing.expectEqual(contract.ErrorCode.none, view.usage.error_code);
}
