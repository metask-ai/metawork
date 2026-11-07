//! Pure calendar recurrence against one pinned IANA data set on every target.
const tempora = @import("tempora");
const data = @import("schedule_timezones");

pub const Zone = data.Zone;
pub const Frequency = enum { hourly, daily, weekly };
pub const max_timestamp: u64 = 253_402_300_799; // End of Gregorian year 9999.

pub const Rule = struct {
    start_at_unix_seconds: u64,
    timezone: Zone,
    frequency: Frequency,

    pub fn validate(self: Rule) error{InvalidSchedule}!void {
        if (self.start_at_unix_seconds == 0 or self.start_at_unix_seconds > max_timestamp)
            return error.InvalidSchedule;
    }

    pub fn firstAtOrAfter(self: Rule, query: u64) error{InvalidSchedule}!?u64 {
        try self.validate();
        if (query > max_timestamp) return null;
        if (query <= self.start_at_unix_seconds) return self.start_at_unix_seconds;
        return self.aligned(query, .forward);
    }

    pub fn lastAtOrBefore(self: Rule, query: u64) error{InvalidSchedule}!?u64 {
        try self.validate();
        if (query < self.start_at_unix_seconds) return null;
        return (try self.aligned(@min(query, max_timestamp), .backward)) orelse self.start_at_unix_seconds;
    }

    fn aligned(self: Rule, query: u64, direction: enum { forward, backward }) error{InvalidSchedule}!?u64 {
        if (query > max_timestamp) return error.InvalidSchedule;
        const start: i64 = @intCast(self.start_at_unix_seconds);
        const current: i64 = @intCast(query);
        const anchor = start + offsetAt(self.timezone, start);
        const period: i64 = switch (self.frequency) {
            .hourly => 3600,
            .daily => 86400,
            .weekly => 604800,
        };
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
        var wall = anchor + @divFloor(local_bound - anchor, period) * period;
        // Cover both the conservative starting bound and the largest possible
        // wall-time gap, plus the adjacent grid points. This includes full-day
        // date-line changes as well as sub-period DST gaps.
        const attempts: usize = @intCast(@divFloor(2 * (maximum - minimum) + period - 1, period) + 3);
        for (0..attempts) |_| {
            if (direction == .forward and wall - maximum > max_timestamp) return null;
            if (direction == .backward and wall < anchor) return null;
            if (resolveWall(self.timezone, wall)) |instant| {
                if (instant >= start and instant <= max_timestamp and
                    ((direction == .forward and instant >= current) or
                        (direction == .backward and instant <= current))) return @intCast(instant);
            }
            wall += if (direction == .forward) period else -period;
        }
        return error.InvalidSchedule;
    }
};

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
