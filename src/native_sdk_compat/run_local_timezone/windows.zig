//! Public Windows dynamic-timezone observation; identity stays Windows-native.
const std = @import("std");
const windows = std.os.windows;
const contract = @import("../run_local_timezone.zig");

const SystemTime = extern struct {
    year: u16,
    month: u16,
    day_of_week: u16,
    day: u16,
    hour: u16,
    minute: u16,
    second: u16,
    milliseconds: u16,
};
const FileTime = extern struct { low: u32, high: u32 };
const DynamicZone = extern struct {
    bias: i32,
    standard_name: [32]u16,
    standard_date: SystemTime,
    standard_bias: i32,
    daylight_name: [32]u16,
    daylight_date: SystemTime,
    daylight_bias: i32,
    key_name: [128]u16,
    daylight_disabled: u8,
};
extern "kernel32" fn GetDynamicTimeZoneInformation(*DynamicZone) callconv(.winapi) u32;
extern "kernel32" fn FileTimeToSystemTime(*const FileTime, *SystemTime) callconv(.winapi) windows.BOOL;
extern "kernel32" fn SystemTimeToTzSpecificLocalTimeEx(*const DynamicZone, *const SystemTime, *SystemTime) callconv(.winapi) windows.BOOL;
extern "kernel32" fn SystemTimeToFileTime(*const SystemTime, *FileTime) callconv(.winapi) windows.BOOL;

pub fn sample(unix_ms: i64) contract.Observation {
    var result = contract.Observation{ .kind = .windows };
    if (unix_ms <= 0) return result;
    var zone: DynamicZone = undefined;
    if (GetDynamicTimeZoneInformation(&zone) == 0xffffffff) return result;
    const ticks = std.math.add(u64, std.math.mul(u64, @intCast(unix_ms), 10000) catch return result, 116444736000000000) catch return result;
    const utc_file = FileTime{ .low = @truncate(ticks), .high = @intCast(ticks >> 32) };
    var utc: SystemTime = undefined;
    var local: SystemTime = undefined;
    var local_file: FileTime = undefined;
    if (!FileTimeToSystemTime(&utc_file, &utc).toBool() or
        !SystemTimeToTzSpecificLocalTimeEx(&zone, &utc, &local).toBool() or
        !SystemTimeToFileTime(&local, &local_file).toBool()) return result;
    const local_ticks = @as(u64, local_file.high) << 32 | local_file.low;
    const delta = @as(i128, local_ticks) - ticks;
    if (@rem(delta, 10000000) != 0) return result;
    const offset = @divTrunc(delta, 10000000);
    if (offset <= -86400 or offset >= 86400) return result;
    result.offset_seconds = @intCast(offset);
    const len = std.mem.indexOfScalar(u16, &zone.key_name, 0) orelse return result;
    result.name_len = std.unicode.utf16LeToUtf8(&result.name, zone.key_name[0..len]) catch return result;
    return result;
}

comptime {
    std.debug.assert(@sizeOf(SystemTime) == 16);
    std.debug.assert(@sizeOf(DynamicZone) == 432);
}
