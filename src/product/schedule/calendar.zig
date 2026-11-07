//! Pure calendar recurrence against one pinned IANA data set on every target.
const tempora = @import("tempora");
const data = @import("schedule_timezones");

pub const Zone = data.Zone;
pub const Frequency = enum { hourly, daily, weekly, monthly, yearly };
const Direction = enum { forward, backward };
pub const max_timestamp: u64 = 253_402_300_799; // End of Gregorian year 9999.

pub const Rule = struct {
    start_at_unix_seconds: u64,
    timezone: Zone,
    frequency: Frequency,
    // Zero preserves the single anchor date of existing persisted rules.
    days: u32 = 0,

    pub fn selectedDays(self: Rule) u32 {
        if (self.days != 0) return self.days;
        const start: i64 = @intCast(self.start_at_unix_seconds);
        const date = wallDate(start + offsetAt(self.timezone, start));
        const day: u5 = @intCast(switch (self.frequency) {
            .weekly => date.week_day().as_iso() - 1,
            .monthly => date.ymd().day.as_number() - 1,
            else => return 0,
        });
        return @as(u32, 1) << day;
    }

    pub fn withDays(self: Rule, days: []const u8) error{InvalidSchedule}!Rule {
        const limit: u8 = switch (self.frequency) {
            .weekly => 7,
            .monthly => 31,
            else => return error.InvalidSchedule,
        };
        if (days.len == 0 or days.len > limit) return error.InvalidSchedule;
        var mask: u32 = 0;
        var previous: u8 = 0;
        for (days) |day| {
            if (day <= previous or day > limit) return error.InvalidSchedule;
            mask |= @as(u32, 1) << @as(u5, @intCast(day - 1));
            previous = day;
        }
        var result = self;
        result.days = mask;
        try result.validate();
        return result;
    }

    fn anchorSelected(self: Rule) bool {
        if (self.frequency != .weekly and self.frequency != .monthly) return true;
        var anchor = self;
        anchor.days = 0;
        return self.selectedDays() & anchor.selectedDays() != 0;
    }

    pub fn validate(self: Rule) error{InvalidSchedule}!void {
        if (self.start_at_unix_seconds == 0 or self.start_at_unix_seconds > max_timestamp)
            return error.InvalidSchedule;
        const allowed: u32 = switch (self.frequency) {
            .weekly => 0x7f,
            .monthly => 0x7fffffff,
            else => 0,
        };
        if (self.days & ~allowed != 0) return error.InvalidSchedule;
    }

    pub fn firstAtOrAfter(self: Rule, query: u64) error{InvalidSchedule}!?u64 {
        try self.validate();
        if (query > max_timestamp) return null;
        if (query <= self.start_at_unix_seconds and self.anchorSelected()) return self.start_at_unix_seconds;
        return self.aligned(@max(query, self.start_at_unix_seconds), .forward);
    }

    pub fn lastAtOrBefore(self: Rule, query: u64) error{InvalidSchedule}!?u64 {
        try self.validate();
        if (query < self.start_at_unix_seconds) return null;
        return (try self.aligned(@min(query, max_timestamp), .backward)) orelse
            if (self.anchorSelected()) self.start_at_unix_seconds else null;
    }

    fn aligned(self: Rule, query: u64, direction: Direction) error{InvalidSchedule}!?u64 {
        if (query > max_timestamp) return error.InvalidSchedule;
        const start: i64 = @intCast(self.start_at_unix_seconds);
        const current: i64 = @intCast(query);
        const anchor = start + offsetAt(self.timezone, start);
        const zone = data.entries[@intFromEnum(self.timezone)];
        var minimum: i64 = zone.initial_offset;
        var maximum = minimum;
        for (zone.offsets) |offset| {
            minimum = @min(minimum, offset);
            maximum = @max(maximum, offset);
        }
        // UTC order differs from wall order inside a fold. Start outside
        // every possible offset so a previously elapsed wall point is not
        // missed when the clock has moved back before its local time.
        const local_bound = current + if (direction == .forward) minimum else maximum;
        if (self.frequency == .monthly or self.frequency == .yearly)
            return self.alignedMonths(anchor, current, local_bound, direction);
        const period: i64 = switch (self.frequency) {
            .hourly => 3600,
            .daily => 86400,
            .weekly => 86400,
            .monthly, .yearly => unreachable,
        };
        var wall = anchor + @divFloor(local_bound - anchor, period) * period;
        // Cover both the conservative starting bound and the largest possible
        // wall-time gap, plus the adjacent grid points. This includes full-day
        // date-line changes as well as sub-period DST gaps.
        const attempts: usize = @intCast(@divFloor(2 * (maximum - minimum) + period - 1, period) + if (self.frequency == .weekly) @as(i64, 10) else @as(i64, 3));
        for (0..attempts) |_| {
            if (direction == .forward and wall - maximum > max_timestamp) return null;
            if (direction == .backward and wall < anchor) return null;
            const selected = self.frequency != .weekly or
                self.selectedDays() & (@as(u32, 1) << @as(u5, @intCast(wallDate(wall).week_day().as_iso() - 1))) != 0;
            if (selected) {
                if (resolveWall(self.timezone, wall)) |instant| {
                    if (instant >= start and instant <= max_timestamp and
                        ((direction == .forward and instant >= current) or
                            (direction == .backward and instant <= current))) return @intCast(instant);
                }
            }
            wall += if (direction == .forward) period else -period;
        }
        return error.InvalidSchedule;
    }

    fn alignedMonths(self: Rule, anchor: i64, current: i64, local_bound: i64, direction: Direction) ?u64 {
        const anchor_date = wallDate(anchor).ymd();
        const bound_date = wallDate(local_bound).ymd();
        const anchor_month = anchor_date.year.as_number() * 12 + anchor_date.month.as_number() - 1;
        const bound_month = bound_date.year.as_number() * 12 + bound_date.month.as_number() - 1;
        const step: i32 = if (self.frequency == .monthly) 1 else 12;
        var index = anchor_month + @divFloor(bound_month - anchor_month, step) * step;
        while (index <= 10000 * 12 + 11) : (index += if (direction == .forward) step else -step) {
            if (index < anchor_month) {
                if (direction == .backward) return null;
                continue;
            }
            const month = @mod(index, 12) + 1;
            for (0..31) |position| {
                const day: u5 = @intCast(if (direction == .forward) position else 30 - position);
                const mask: u32 = if (self.frequency == .monthly) self.selectedDays() else @as(u32, 1) << @as(u5, @intCast(anchor_date.day.as_number() - 1));
                if (mask & (@as(u32, 1) << day) == 0) continue;
                const date = tempora.Date.from_ymd_numbers(@divFloor(index, 12), month, @as(i32, day) + 1);
                // Missing days are skipped rather than normalized into another month.
                if (date.month().as_number() != month) continue;
                const days: i64 = @intFromEnum(date) - @intFromEnum(tempora.Date.unix_epoch);
                const wall = days * 86400 + @mod(anchor, 86400);
                if (resolveWall(self.timezone, wall)) |instant| {
                    if (instant >= self.start_at_unix_seconds and instant <= max_timestamp and
                        ((direction == .forward and instant >= current) or
                            (direction == .backward and instant <= current))) return @intCast(instant);
                }
            }
        }
        return null;
    }
};

fn wallDate(wall: i64) tempora.Date {
    return tempora.Date.unix_epoch.plus_days(@intCast(@divFloor(wall, 86400)));
}

pub fn offsetAt(zone: Zone, timestamp: i64) i64 {
    const value = data.entries[@intFromEnum(zone)];
    const transitions = value.transitions;
    if (transitions.len == 0 or timestamp > transitions[transitions.len - 1].at) {
        if (value.footer) |footer| {
            const rule = tempora.Timezone.Posix.parse(footer) catch unreachable;
            return rule.info(timestamp, if (transitions.len == 0) null else transitions[transitions.len - 1].at).utc_offset_seconds;
        }
    }
    var low: usize = 0;
    var high = transitions.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (transitions[middle].at <= timestamp) low = middle + 1 else high = middle;
    }
    return if (low == 0) value.initial_offset else transitions[low - 1].offset;
}

fn resolveWall(zone: Zone, wall: i64) ?i64 {
    const value = data.entries[@intFromEnum(zone)];
    var earliest: ?i64 = null;
    for (value.offsets) |offset| {
        const instant = wall - offset;
        if (offsetAt(zone, instant) == offset and (earliest == null or instant < earliest.?)) earliest = instant;
    }
    return earliest;
}
