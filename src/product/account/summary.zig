//! Account-owned, secret-free Metask wallet, usage, and daily history summary.
const std = @import("std");
const contract = @import("metawork_account_contract");

pub const ProtocolError = error{InvalidSummaryResponse};

pub const history_timezone = "Asia/Shanghai";
const history_timezone_offset_seconds: i64 = 8 * std.time.s_per_hour;
const history_week_columns: i64 = 53;

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

    pub fn fromMilliUnits(value: i64) ProtocolError!Decimal {
        if (value < 0) return error.InvalidSummaryResponse;
        var result: Decimal = .{};
        const whole = @divTrunc(value, 1000);
        const remainder = @mod(value, 1000);
        const rendered = std.fmt.bufPrint(&result.bytes, "{d}", .{whole}) catch
            return error.InvalidSummaryResponse;
        result.len = rendered.len;
        if (remainder == 0) return result;
        if (result.len + 4 > result.bytes.len)
            return error.InvalidSummaryResponse;
        result.bytes[result.len] = '.';
        result.bytes[result.len + 1] = digit(@divTrunc(remainder, 100));
        result.bytes[result.len + 2] = digit(@divTrunc(@mod(remainder, 100), 10));
        result.bytes[result.len + 3] = digit(@mod(remainder, 10));
        result.len += 4;
        while (result.bytes[result.len - 1] == '0') result.len -= 1;
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

pub const CalendarDate = struct {
    bytes: [contract.Limits.calendar_date_bytes]u8,

    pub fn view(self: *const CalendarDate) []const u8 {
        return &self.bytes;
    }

    fn parse(value: []const u8) ProtocolError!CalendarDate {
        _ = try dayNumber(value);
        var result: CalendarDate = undefined;
        @memcpy(&result.bytes, value);
        return result;
    }

    fn fromDayNumber(day_number: i64) ProtocolError!CalendarDate {
        const z = std.math.add(i64, day_number, 719468) catch
            return error.InvalidSummaryResponse;
        const era = @divFloor(z, 146097);
        const day_of_era = z - era * 146097;
        const year_of_era = @divFloor(
            day_of_era - @divFloor(day_of_era, 1460) +
                @divFloor(day_of_era, 36524) - @divFloor(day_of_era, 146096),
            365,
        );
        var year = year_of_era + era * 400;
        const day_of_year = day_of_era -
            (365 * year_of_era + @divFloor(year_of_era, 4) -
                @divFloor(year_of_era, 100));
        const month_prime = @divFloor(5 * day_of_year + 2, 153);
        const day = day_of_year - @divFloor(153 * month_prime + 2, 5) + 1;
        const month = month_prime + (if (month_prime < 10) @as(i64, 3) else -9);
        year += if (month <= 2) 1 else 0;
        if (year < 1 or year > 9999) return error.InvalidSummaryResponse;
        const year_value: u16 = @intCast(year);
        const month_value: u8 = @intCast(month);
        const day_value: u8 = @intCast(day);
        return .{ .bytes = .{
            digit(@divTrunc(year_value, 1000)),
            digit(@divTrunc(year_value, 100) % 10),
            digit(@divTrunc(year_value, 10) % 10),
            digit(year_value % 10),
            '-',
            digit(@divTrunc(month_value, 10)),
            digit(month_value % 10),
            '-',
            digit(@divTrunc(day_value, 10)),
            digit(day_value % 10),
        } };
    }
};

fn digit(value: anytype) u8 {
    return '0' + @as(u8, @intCast(value));
}

pub const HistoryRange = struct {
    start_date: CalendarDate,
    end_date: CalendarDate,

    pub fn fromUnixSeconds(now_unix_seconds: i64) ProtocolError!HistoryRange {
        if (now_unix_seconds < 0) return error.InvalidSummaryResponse;
        const shanghai_seconds = std.math.add(
            i64,
            now_unix_seconds,
            history_timezone_offset_seconds,
        ) catch return error.InvalidSummaryResponse;
        const end_day = @divFloor(shanghai_seconds, std.time.s_per_day);
        const weekday_from_monday = @mod(end_day + 3, 7);
        const start_day = end_day - weekday_from_monday -
            (history_week_columns - 1) * 7;
        return .{
            .start_date = try CalendarDate.fromDayNumber(start_day),
            .end_date = try CalendarDate.fromDayNumber(end_day),
        };
    }

    pub fn usageStatsRange(self: HistoryRange) ProtocolError!UsageStatsRange {
        const start_day = try dayNumber(self.start_date.view());
        const end_day = try dayNumber(self.end_date.view());
        return .{
            .since = try UtcInstant.fromShanghaiDay(start_day),
            .before = try UtcInstant.fromShanghaiDay(
                std.math.add(i64, end_day, 1) catch
                    return error.InvalidSummaryResponse,
            ),
        };
    }
};

pub const UtcInstant = struct {
    bytes: [20]u8,

    pub fn view(self: *const UtcInstant) []const u8 {
        return &self.bytes;
    }

    fn fromShanghaiDay(day_number: i64) ProtocolError!UtcInstant {
        const utc_date = try CalendarDate.fromDayNumber(
            std.math.sub(i64, day_number, 1) catch
                return error.InvalidSummaryResponse,
        );
        var result: UtcInstant = undefined;
        @memcpy(result.bytes[0..10], utc_date.view());
        @memcpy(result.bytes[10..], "T16:00:00Z");
        return result;
    }
};

pub const UsageStatsRange = struct {
    since: UtcInstant,
    before: UtcInstant,
};

pub const UsageHistoryDayData = struct {
    date: CalendarDate,
    input_tokens: Decimal,
    output_tokens: Decimal,
    cache_creation_tokens: Decimal,
    cache_read_tokens: Decimal,
    total_tokens: Decimal,
    actual_cost_u: Decimal,
};

pub const UsageHistoryData = struct {
    start_date: CalendarDate,
    end_date: CalendarDate,
    days: [contract.Limits.usage_history_days]UsageHistoryDayData = undefined,
    days_len: usize = 0,
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

const UsageStatsTotals = struct {
    requests: i64,
    input_tokens: i64,
    output_tokens: i64,
    cache_creation_tokens: i64,
    cache_read_tokens: i64,
    total_tokens: i64,
    cost_mu: i64,
};

const UsageStatsBucket = struct {
    bucket: []const u8,
    bucket_start: []const u8,
    requests: i64,
    input_tokens: i64,
    output_tokens: i64,
    cache_creation_tokens: i64,
    cache_read_tokens: i64,
    total_tokens: i64,
    cost_mu: i64,
};

const UsageStatsEnvelope = struct {
    object: []const u8,
    scope: []const u8,
    granularity: []const u8,
    timezone: []const u8,
    unit: ?[]const u8 = null,
    since: []const u8,
    before: []const u8,
    cost_complete: ?bool = null,
    totals: UsageStatsTotals,
    data: []const UsageStatsBucket,
};

pub fn parseUsageStats(
    body: []const u8,
    expected_range: HistoryRange,
) ProtocolError!UsageHistoryData {
    if (body.len == 0 or body.len > 192 * 1024)
        return error.InvalidSummaryResponse;
    var scratch: [256 * 1024]u8 = undefined;
    defer std.crypto.secureZero(u8, &scratch);
    var fixed = std.heap.FixedBufferAllocator.init(&scratch);
    var parsed = std.json.parseFromSlice(
        UsageStatsEnvelope,
        fixed.allocator(),
        body,
        .{ .ignore_unknown_fields = true },
    ) catch return error.InvalidSummaryResponse;
    defer parsed.deinit();
    const raw = parsed.value;
    const stats_range = try expected_range.usageStatsRange();
    if (!std.mem.eql(u8, raw.object, "usage_stats") or
        !std.mem.eql(u8, raw.scope, "user") or
        !std.mem.eql(u8, raw.granularity, "day") or
        !std.mem.eql(u8, raw.timezone, history_timezone) or
        !std.mem.eql(u8, raw.since, stats_range.since.view()) or
        !std.mem.eql(u8, raw.before, stats_range.before.view()) or
        raw.data.len > contract.Limits.usage_history_days)
        return error.InvalidSummaryResponse;
    if (raw.unit) |unit| {
        if (!std.mem.eql(u8, unit, "mU"))
            return error.InvalidSummaryResponse;
    }
    try validateUsageStatsTotals(raw.totals);

    var result: UsageHistoryData = .{
        .start_date = expected_range.start_date,
        .end_date = expected_range.end_date,
    };
    var previous_date: ?CalendarDate = null;
    var sums: UsageStatsTotals = .{
        .requests = 0,
        .input_tokens = 0,
        .output_tokens = 0,
        .cache_creation_tokens = 0,
        .cache_read_tokens = 0,
        .total_tokens = 0,
        .cost_mu = 0,
    };
    for (raw.data, 0..) |raw_day, index| {
        const date = try CalendarDate.parse(raw_day.bucket);
        if (std.mem.order(u8, date.view(), expected_range.start_date.view()) == .lt or
            std.mem.order(u8, date.view(), expected_range.end_date.view()) == .gt)
            return error.InvalidSummaryResponse;
        if (previous_date) |previous| {
            if (std.mem.order(u8, previous.view(), date.view()) != .lt)
                return error.InvalidSummaryResponse;
        }
        const bucket_start = try UtcInstant.fromShanghaiDay(try dayNumber(date.view()));
        if (!std.mem.eql(u8, raw_day.bucket_start, bucket_start.view()) or
            raw_day.requests <= 0)
            return error.InvalidSummaryResponse;
        try validateUsageStatsBucket(raw_day);
        sums.requests = try checkedAdd(sums.requests, raw_day.requests);
        sums.input_tokens = try checkedAdd(sums.input_tokens, raw_day.input_tokens);
        sums.output_tokens = try checkedAdd(sums.output_tokens, raw_day.output_tokens);
        sums.cache_creation_tokens = try checkedAdd(sums.cache_creation_tokens, raw_day.cache_creation_tokens);
        sums.cache_read_tokens = try checkedAdd(sums.cache_read_tokens, raw_day.cache_read_tokens);
        sums.total_tokens = try checkedAdd(sums.total_tokens, raw_day.total_tokens);
        sums.cost_mu = try checkedAdd(sums.cost_mu, raw_day.cost_mu);
        result.days[index] = .{
            .date = date,
            .input_tokens = try Decimal.fromInteger(raw_day.input_tokens, false),
            .output_tokens = try Decimal.fromInteger(raw_day.output_tokens, false),
            .cache_creation_tokens = try Decimal.fromInteger(raw_day.cache_creation_tokens, false),
            .cache_read_tokens = try Decimal.fromInteger(raw_day.cache_read_tokens, false),
            .total_tokens = try Decimal.fromInteger(raw_day.total_tokens, false),
            .actual_cost_u = try Decimal.fromMilliUnits(raw_day.cost_mu),
        };
        previous_date = date;
    }
    if (!std.meta.eql(sums, raw.totals))
        return error.InvalidSummaryResponse;
    result.days_len = raw.data.len;
    return result;
}

fn validateUsageStatsTotals(value: UsageStatsTotals) ProtocolError!void {
    if (value.requests < 0 or value.input_tokens < 0 or
        value.output_tokens < 0 or value.cache_creation_tokens < 0 or
        value.cache_read_tokens < 0 or value.total_tokens < 0 or
        value.cost_mu < 0 or
        try tokenTotal(
            value.input_tokens,
            value.output_tokens,
            value.cache_creation_tokens,
            value.cache_read_tokens,
        ) != value.total_tokens)
        return error.InvalidSummaryResponse;
}

fn validateUsageStatsBucket(value: UsageStatsBucket) ProtocolError!void {
    if (value.input_tokens < 0 or value.output_tokens < 0 or
        value.cache_creation_tokens < 0 or value.cache_read_tokens < 0 or
        value.total_tokens < 0 or value.cost_mu < 0 or
        try tokenTotal(
            value.input_tokens,
            value.output_tokens,
            value.cache_creation_tokens,
            value.cache_read_tokens,
        ) != value.total_tokens)
        return error.InvalidSummaryResponse;
}

fn tokenTotal(input: i64, output: i64, cache_creation: i64, cache_read: i64) ProtocolError!i64 {
    var total = try checkedAdd(input, output);
    total = try checkedAdd(total, cache_creation);
    return checkedAdd(total, cache_read);
}

fn checkedAdd(left: i64, right: i64) ProtocolError!i64 {
    return std.math.add(i64, left, right) catch
        return error.InvalidSummaryResponse;
}

fn dayNumber(value: []const u8) ProtocolError!i64 {
    if (value.len != contract.Limits.calendar_date_bytes or
        value[4] != '-' or value[7] != '-')
        return error.InvalidSummaryResponse;
    for (value, 0..) |byte, index| {
        if (index == 4 or index == 7) continue;
        if (!std.ascii.isDigit(byte)) return error.InvalidSummaryResponse;
    }
    const year = std.fmt.parseInt(i64, value[0..4], 10) catch
        return error.InvalidSummaryResponse;
    const month = std.fmt.parseInt(i64, value[5..7], 10) catch
        return error.InvalidSummaryResponse;
    const day = std.fmt.parseInt(i64, value[8..10], 10) catch
        return error.InvalidSummaryResponse;
    if (year < 1 or month < 1 or month > 12 or day < 1 or
        day > daysInMonth(year, month))
        return error.InvalidSummaryResponse;
    const adjusted_year = year - (if (month <= 2) @as(i64, 1) else 0);
    const era = @divFloor(adjusted_year, 400);
    const year_of_era = adjusted_year - era * 400;
    const month_prime = month + (if (month > 2) @as(i64, -3) else 9);
    const day_of_year = @divFloor(153 * month_prime + 2, 5) + day - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) -
        @divFloor(year_of_era, 100) + day_of_year;
    return era * 146097 + day_of_era - 719468;
}

fn daysInMonth(year: i64, month: i64) i64 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (@mod(year, 4) == 0 and
            (@mod(year, 100) != 0 or @mod(year, 400) == 0)) 29 else 28,
        else => 0,
    };
}

pub const UsageOutcome = union(enum) {
    not_requested,
    succeeded: UsageData,
    failed: contract.ErrorCode,
};

pub const WalletOutcome = union(enum) {
    not_requested,
    succeeded: WalletData,
    failed: contract.ErrorCode,
};

pub const HistoryOutcome = union(enum) {
    not_requested,
    succeeded: UsageHistoryData,
    failed: contract.ErrorCode,
};

pub const Completion = struct {
    attempt_id: u64,
    authorization_generation: u64,
    principal_ref: [contract.Limits.account_id_bytes]u8 = undefined,
    principal_ref_len: usize,
    synced_at_unix_ms: Decimal,
    wallet: WalletOutcome = .not_requested,
    usage: UsageOutcome = .not_requested,
    history: HistoryOutcome = .not_requested,

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

const HistoryState = struct {
    availability: contract.SummaryAvailability = .unavailable,
    data: ?UsageHistoryData = null,
    day_views: [contract.Limits.usage_history_days]contract.UsageHistoryDayView = undefined,
    synced_at_unix_ms: Decimal = .{},
    error_code: contract.ErrorCode = .none,

    fn begin(self: *HistoryState, eligibility: contract.UsageEligibility) void {
        self.error_code = .none;
        if (eligibility == .disabled) {
            self.* = .{};
        } else if (self.data == null) {
            self.availability = .loading;
        }
    }

    fn succeed(self: *HistoryState, data: UsageHistoryData, synced_at: Decimal) void {
        self.availability = .ready;
        self.data = data;
        self.synced_at_unix_ms = synced_at;
        self.error_code = .none;
        const stored = &self.data.?;
        for (stored.days[0..stored.days_len], 0..) |*day, index| {
            self.day_views[index] = .{
                .date = day.date.view(),
                .input_tokens = day.input_tokens.view(),
                .output_tokens = day.output_tokens.view(),
                .cache_creation_tokens = day.cache_creation_tokens.view(),
                .cache_read_tokens = day.cache_read_tokens.view(),
                .total_tokens = day.total_tokens.view(),
                .actual_cost_u = day.actual_cost_u.view(),
            };
        }
    }

    fn fail(self: *HistoryState, error_code: contract.ErrorCode) void {
        self.error_code = error_code;
        self.availability = if (self.data == null) .unavailable else .stale;
    }

    fn view(self: *const HistoryState) contract.UsageHistoryView {
        const data = if (self.data) |*value| value else return .{
            .availability = self.availability,
            .error_code = self.error_code,
        };
        return .{
            .availability = self.availability,
            .start_date = data.start_date.view(),
            .end_date = data.end_date.view(),
            .days = self.day_views[0..data.days_len],
            .synced_at_unix_ms = self.synced_at_unix_ms.view(),
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
    history: HistoryState = .{},
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
        self.usage_eligibility = .enabled;
        const attempt_id = self.next_attempt_id;
        self.next_attempt_id +%= 1;
        if (self.next_attempt_id == 0) self.next_attempt_id = 1;
        self.active_attempt_id = attempt_id;
        self.operation = .refreshing;
        self.history.begin(.enabled);
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
        self.history.fail(error_code);
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
            },
            .failed => |error_code| self.wallet.fail(error_code),
            .not_requested => {},
        }
        switch (completion.usage) {
            .succeeded => |usage| self.usage.succeed(usage, completion.synced_at_unix_ms),
            .failed => |error_code| self.usage.fail(error_code),
            .not_requested => {},
        }
        switch (completion.history) {
            .succeeded => |history| self.history.succeed(history, completion.synced_at_unix_ms),
            .failed => |error_code| self.history.fail(error_code),
            .not_requested => self.history.fail(.metask_protocol_invalid),
        }
        return true;
    }

    pub fn clearAuthorization(self: *State) bool {
        const changed = self.authority != null or self.active_attempt_id != null or
            self.operation != .idle or self.usage_eligibility != .unknown or
            self.wallet.availability != .unavailable or
            self.usage.availability != .unavailable or
            self.history.availability != .unavailable;
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
            .history = self.history.view(),
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

test "history range uses 53 Monday-aligned weeks in Asia Shanghai" {
    const range = try HistoryRange.fromUnixSeconds(1_789_440_000);
    try std.testing.expectEqualStrings("2025-09-15", range.start_date.view());
    try std.testing.expectEqualStrings("2026-09-15", range.end_date.view());
}

test "history range rolls over at Asia Shanghai midnight" {
    const before_midnight = try HistoryRange.fromUnixSeconds(1_789_401_599);
    try std.testing.expectEqualStrings("2026-09-14", before_midnight.end_date.view());

    const at_midnight = try HistoryRange.fromUnixSeconds(1_789_401_600);
    try std.testing.expectEqualStrings("2026-09-15", at_midnight.end_date.view());
}

test "daily usage stats strictly validates contract range totals and values" {
    const range: HistoryRange = .{
        .start_date = try CalendarDate.parse("2025-09-15"),
        .end_date = try CalendarDate.parse("2026-09-15"),
    };
    const history = try parseUsageStats(
        \\{"object":"usage_stats","scope":"user","granularity":"day","timezone":"Asia/Shanghai","since":"2025-09-14T16:00:00Z","before":"2026-09-15T16:00:00Z","totals":{"requests":3,"input_tokens":50,"output_tokens":70,"cache_creation_tokens":60,"cache_read_tokens":100,"total_tokens":280,"cost_mu":3750},"data":[{"bucket":"2026-09-14","bucket_start":"2026-09-13T16:00:00Z","requests":1,"input_tokens":10,"output_tokens":20,"cache_creation_tokens":0,"cache_read_tokens":30,"total_tokens":60,"cost_mu":1250},{"bucket":"2026-09-15","bucket_start":"2026-09-14T16:00:00Z","requests":2,"input_tokens":40,"output_tokens":50,"cache_creation_tokens":60,"cache_read_tokens":70,"total_tokens":220,"cost_mu":2500}]}
    , range);
    try std.testing.expectEqual(@as(usize, 2), history.days_len);
    try std.testing.expectEqualStrings("2026-09-14", history.days[0].date.view());
    try std.testing.expectEqualStrings("220", history.days[1].total_tokens.view());
    try std.testing.expectEqualStrings("2.5", history.days[1].actual_cost_u.view());

    const duplicate =
        \\{"object":"usage_stats","scope":"user","granularity":"day","timezone":"Asia/Shanghai","since":"2025-09-14T16:00:00Z","before":"2026-09-15T16:00:00Z","totals":{"requests":2,"input_tokens":0,"output_tokens":0,"cache_creation_tokens":0,"cache_read_tokens":0,"total_tokens":0,"cost_mu":0},"data":[{"bucket":"2026-09-15","bucket_start":"2026-09-14T16:00:00Z","requests":1,"input_tokens":0,"output_tokens":0,"cache_creation_tokens":0,"cache_read_tokens":0,"total_tokens":0,"cost_mu":0},{"bucket":"2026-09-15","bucket_start":"2026-09-14T16:00:00Z","requests":1,"input_tokens":0,"output_tokens":0,"cache_creation_tokens":0,"cache_read_tokens":0,"total_tokens":0,"cost_mu":0}]}
    ;
    try std.testing.expectError(
        error.InvalidSummaryResponse,
        parseUsageStats(duplicate, range),
    );
    const invalid_value =
        \\{"object":"usage_stats","scope":"user","granularity":"day","timezone":"Asia/Shanghai","since":"2025-09-14T16:00:00Z","before":"2026-09-15T16:00:00Z","totals":{"requests":1,"input_tokens":0,"output_tokens":0,"cache_creation_tokens":0,"cache_read_tokens":0,"total_tokens":0,"cost_mu":0},"data":[{"bucket":"2026-02-30","bucket_start":"2026-02-28T16:00:00Z","requests":1,"input_tokens":-1,"output_tokens":0,"cache_creation_tokens":0,"cache_read_tokens":0,"total_tokens":0,"cost_mu":0}]}
    ;
    try std.testing.expectError(
        error.InvalidSummaryResponse,
        parseUsageStats(invalid_value, range),
    );
    const mismatched_range =
        \\{"object":"usage_stats","scope":"user","granularity":"day","timezone":"Asia/Shanghai","since":"2025-09-16T16:00:00Z","before":"2026-09-15T16:00:00Z","totals":{"requests":0,"input_tokens":0,"output_tokens":0,"cache_creation_tokens":0,"cache_read_tokens":0,"total_tokens":0,"cost_mu":0},"data":[]}
    ;
    try std.testing.expectError(
        error.InvalidSummaryResponse,
        parseUsageStats(mismatched_range, range),
    );

    const invalid_unit =
        \\{"object":"usage_stats","scope":"user","granularity":"day","timezone":"Asia/Shanghai","unit":"U","since":"2025-09-14T16:00:00Z","before":"2026-09-15T16:00:00Z","cost_complete":false,"totals":{"requests":0,"input_tokens":0,"output_tokens":0,"cache_creation_tokens":0,"cache_read_tokens":0,"total_tokens":0,"cost_mu":0},"data":[]}
    ;
    try std.testing.expectError(
        error.InvalidSummaryResponse,
        parseUsageStats(invalid_unit, range),
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
        .history = .{ .succeeded = try parseUsageStats(
            \\{"object":"usage_stats","scope":"user","granularity":"day","timezone":"Asia/Shanghai","unit":"mU","since":"2025-09-14T16:00:00Z","before":"2026-09-15T16:00:00Z","cost_complete":false,"totals":{"requests":1,"input_tokens":1,"output_tokens":2,"cache_creation_tokens":3,"cache_read_tokens":4,"total_tokens":10,"cost_mu":1000},"data":[{"bucket":"2026-09-15","bucket_start":"2026-09-14T16:00:00Z","requests":1,"input_tokens":1,"output_tokens":2,"cache_creation_tokens":3,"cache_read_tokens":4,"total_tokens":10,"cost_mu":1000}]}
        , .{
            .start_date = try CalendarDate.parse("2025-09-15"),
            .end_date = try CalendarDate.parse("2026-09-15"),
        }) },
    };
    @memcpy(completion.principal_ref[0..2], "42");
    try std.testing.expect(state.complete(&completion));
    const retry = try state.begin("42", 3);
    try std.testing.expect(state.fail(retry.attempt_id, .metask_service_unavailable));
    const stale = state.view();
    try std.testing.expectEqual(contract.SummaryAvailability.ready, stale.wallet.availability);
    try std.testing.expectEqual(contract.SummaryAvailability.ready, stale.usage.availability);
    try std.testing.expectEqual(contract.SummaryAvailability.stale, stale.history.availability);
    try std.testing.expectEqualStrings("10.5", stale.wallet.balance_u);
    try std.testing.expect(state.clearAuthorization());
    try contract.validateView(.{ .state = .signed_out, .summary = state.view() });
}

test "summary state ignores stale generation completion and enables gateway history" {
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
    var current: Completion = .{
        .attempt_id = second.attempt_id,
        .authorization_generation = 2,
        .principal_ref_len = 2,
        .synced_at_unix_ms = try Decimal.fromInteger(2000, false),
        .history = .{ .failed = .metask_service_unavailable },
    };
    @memcpy(current.principal_ref[0..2], "42");
    try std.testing.expect(state.complete(&current));
    const view = state.view();
    try std.testing.expectEqual(contract.UsageEligibility.enabled, view.usage_eligibility);
    try std.testing.expectEqual(contract.SummaryAvailability.unavailable, view.usage.availability);
    try std.testing.expectEqual(contract.ErrorCode.none, view.usage.error_code);
    try std.testing.expectEqual(contract.SummaryAvailability.unavailable, view.history.availability);
    try std.testing.expectEqual(contract.ErrorCode.metask_service_unavailable, view.history.error_code);
}
