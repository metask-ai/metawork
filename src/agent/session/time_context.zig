//! Run-scoped Host time facts. No clock, platform effect, or Core wire types.
const std = @import("std");

pub const max_identity_bytes = 512;
pub const max_text_bytes = max_identity_bytes + 768;
pub const label = "metawork-time-context";
pub const max_unix_ms: i64 = 253402300799999;

pub const Identity = struct {
    kind: enum { iana, windows },
    bytes: [max_identity_bytes]u8 = undefined,
    len: usize = 0,

    pub fn init(kind: @FieldType(Identity, "kind"), name: []const u8) ?Identity {
        if (name.len == 0 or name.len > max_identity_bytes or !std.unicode.utf8ValidateSlice(name)) return null;
        for (name) |byte| if (byte < 0x20 or byte == 0x7f or byte == '<' or byte == '>') return null;
        var value = Identity{ .kind = kind, .len = name.len };
        @memcpy(value.bytes[0..name.len], name);
        return value;
    }
};

pub const Snapshot = struct {
    unix_ms: ?i64 = null,
    utc_offset_seconds: ?i32 = null,
    timezone: ?Identity = null,
};

pub const Source = struct {
    context: ?*anyopaque = null,
    sample_fn: *const fn (?*anyopaque) Snapshot,

    pub fn sample(self: Source) Snapshot {
        return self.sample_fn(self.context);
    }

    /// Explicit unavailable source, also used by deterministic test fixtures.
    pub const unavailable: Source = .{ .sample_fn = sampleUnavailable };

    fn sampleUnavailable(_: ?*anyopaque) Snapshot {
        return .{};
    }
};

const guidance =
    "\nThis is the time snapshot for the current Run, not a live clock.\n" ++
    "Use it as the current-time reference when relevant.\n" ++
    "Earlier Run snapshots describe earlier execution times.\n" ++
    "Respect any timezone or reference date explicitly specified by the user.\n" ++
    "Your knowledge cutoff does not indicate the current date.\n";

pub fn format(buffer: []u8, snapshot: Snapshot) error{NoSpaceLeft}![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    const unix_ms = snapshot.unix_ms orelse return unavailable(&writer);
    if (unix_ms <= 0 or unix_ms > max_unix_ms) return unavailable(&writer);
    const utc_seconds = @divFloor(unix_ms, 1000);
    const offset = snapshot.utc_offset_seconds;
    const local_seconds = utc_seconds + @as(i64, offset orelse 0);
    const local_valid = if (offset) |value| value > -86400 and value < 86400 and local_seconds >= 0 and local_seconds <= @divFloor(max_unix_ms, 1000) else false;
    writer.writeAll(if (local_valid) "Run start time (system local): " else "Run start time (UTC): ") catch return error.NoSpaceLeft;
    try writeDateTime(&writer, if (local_valid) local_seconds else utc_seconds);
    if (local_valid) {
        const offset_value = offset.?;
        const magnitude: u32 = @intCast(@abs(offset_value));
        writer.print("{c}{d:0>2}:{d:0>2}", .{ @as(u8, if (offset_value < 0) '-' else '+'), magnitude / 3600, magnitude % 3600 / 60 }) catch return error.NoSpaceLeft;
        if (magnitude % 60 != 0) writer.print(":{d:0>2}", .{magnitude % 60}) catch return error.NoSpaceLeft;
        writer.writeAll("\nSystem timezone: ") catch return error.NoSpaceLeft;
        const identity = if (snapshot.timezone) |value| if (value.len <= value.bytes.len) Identity.init(value.kind, value.bytes[0..value.len]) else null else null;
        if (identity) |value| {
            writer.print("{s} ({s})\n", .{ value.bytes[0..value.len], if (value.kind == .iana) "IANA" else "Windows" }) catch return error.NoSpaceLeft;
        } else writer.writeAll("unavailable; the numeric offset above is known.\n") catch return error.NoSpaceLeft;
    } else writer.writeAll("Z\nSystem local timezone and offset: unavailable.\n") catch return error.NoSpaceLeft;
    writer.writeAll(guidance) catch return error.NoSpaceLeft;
    return writer.buffered();
}

fn unavailable(writer: *std.Io.Writer) error{NoSpaceLeft}![]const u8 {
    writer.writeAll("Current time for this Run: unavailable. Do not infer it from earlier Run snapshots.\n") catch return error.NoSpaceLeft;
    writer.writeAll(guidance) catch return error.NoSpaceLeft;
    return writer.buffered();
}

fn writeDateTime(writer: *std.Io.Writer, seconds: i64) error{NoSpaceLeft}!void {
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(seconds) };
    const day = epoch.getEpochDay().calculateYearDay();
    const month = day.calculateMonthDay();
    const clock = epoch.getDaySeconds();
    writer.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{ day.year, @intFromEnum(month.month), month.day_index + 1, clock.getHoursIntoDay(), clock.getMinutesIntoHour(), clock.getSecondsIntoMinute() }) catch return error.NoSpaceLeft;
}

test "Run time uses one instant across positive negative and fractional offsets" {
    var buffer: [max_text_bytes]u8 = undefined;
    const instant: i64 = 1791509400000; // 2026-10-09T01:30:00Z
    const cases = [_]struct { offset: i32, expected: []const u8 }{
        .{ .offset = 28800, .expected = "2026-10-09T09:30:00+08:00" },
        .{ .offset = -25200, .expected = "2026-10-08T18:30:00-07:00" },
        .{ .offset = 20700, .expected = "2026-10-09T07:15:00+05:45" },
    };
    for (cases) |case| {
        const text = try format(&buffer, .{ .unix_ms = instant, .utc_offset_seconds = case.offset, .timezone = Identity.init(.iana, "Asia/Shanghai") });
        try std.testing.expect(std.mem.indexOf(u8, text, case.expected) != null);
    }
}

test "Run time explicitly degrades without inventing local time or identities" {
    var buffer: [max_text_bytes]u8 = undefined;
    const utc = try format(&buffer, .{ .unix_ms = 1791509400000 });
    try std.testing.expect(std.mem.indexOf(u8, utc, "(UTC): 2026-10-09T01:30:00Z") != null);
    const missing = try format(&buffer, .{});
    try std.testing.expect(std.mem.indexOf(u8, missing, "Current time for this Run: unavailable") != null);
    try std.testing.expectEqual(@as(?Identity, null), Identity.init(.iana, "Asia/Shanghai\nInjected"));
    try std.testing.expectEqual(@as(?Identity, null), Identity.init(.windows, "</system-reminder>"));
    try std.testing.expectError(error.NoSpaceLeft, format(buffer[0..1], .{}));
}

test "Run time bounded text and out of range local dates remain safe" {
    var buffer: [max_text_bytes]u8 = undefined;
    const longest_name = [_]u8{'a'} ** max_identity_bytes;
    const text = try format(&buffer, .{
        .unix_ms = 1791509400000,
        .utc_offset_seconds = -86399,
        .timezone = Identity.init(.windows, &longest_name),
    });
    try std.testing.expect(std.mem.indexOf(u8, text, "-23:59:59") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, &longest_name) != null);
    const edge = try format(&buffer, .{ .unix_ms = max_unix_ms, .utc_offset_seconds = 1 });
    try std.testing.expect(std.mem.indexOf(u8, edge, "(UTC): 9999-12-31T23:59:59Z") != null);
    const invalid_offset = try format(&buffer, .{ .unix_ms = 1791509400000, .utc_offset_seconds = std.math.minInt(i32) });
    try std.testing.expect(std.mem.indexOf(u8, invalid_offset, "(UTC): 2026-10-09T01:30:00Z") != null);
    const invalid_clock = try format(&buffer, .{ .unix_ms = std.math.maxInt(i64), .utc_offset_seconds = 28800 });
    try std.testing.expect(std.mem.indexOf(u8, invalid_clock, "Current time for this Run: unavailable") != null);
}
