//! Public CoreFoundation timezone observation; no timezone setters or handles escape.
const std = @import("std");
const contract = @import("../run_local_timezone.zig");
const Ref = *const anyopaque;
const utf8: u32 = 0x08000100;
const unix_to_cf_seconds = 978307200;

extern "CoreFoundation" fn CFTimeZoneResetSystem() void;
extern "CoreFoundation" fn CFTimeZoneCopySystem() ?Ref;
extern "CoreFoundation" fn CFTimeZoneGetSecondsFromGMT(Ref, f64) f64;
extern "CoreFoundation" fn CFTimeZoneGetName(Ref) ?Ref;
extern "CoreFoundation" fn CFStringGetCString(Ref, [*]u8, isize, u32) u8;
extern "CoreFoundation" fn CFRelease(Ref) void;

pub fn sample(unix_ms: i64) contract.Observation {
    // CoreFoundation caches this ambient fact. Invalidate its cache so a new
    // Run observes system timezone changes; this does not set any timezone.
    CFTimeZoneResetSystem();
    const zone = CFTimeZoneCopySystem() orelse return .{};
    defer CFRelease(zone);
    return observe(zone, unix_ms);
}

fn observe(zone: Ref, unix_ms: i64) contract.Observation {
    var result = contract.Observation{ .kind = .iana };
    const instant = @as(f64, @floatFromInt(unix_ms)) / 1000 - unix_to_cf_seconds;
    const offset = CFTimeZoneGetSecondsFromGMT(zone, instant);
    if (!std.math.isFinite(offset) or @trunc(offset) != offset or offset <= -86400 or offset >= 86400) return result;
    result.offset_seconds = @intFromFloat(offset);
    const name = CFTimeZoneGetName(zone) orelse return result;
    var buffer: [contract.max_name_bytes + 1]u8 = undefined;
    if (CFStringGetCString(name, &buffer, buffer.len, utf8) == 0) return result;
    const len = std.mem.indexOfScalar(u8, &buffer, 0) orelse return result;
    @memcpy(result.name[0..len], buffer[0..len]);
    result.name_len = len;
    return result;
}

extern "CoreFoundation" fn CFStringCreateWithCString(?Ref, [*:0]const u8, u32) ?Ref;
extern "CoreFoundation" fn CFTimeZoneCreateWithName(?Ref, Ref, u8) ?Ref;

test "Run local timezone macOS applies DST rules to the sampled instant" {
    const name = CFStringCreateWithCString(null, "America/New_York", utf8) orelse return error.TestUnexpectedResult;
    defer CFRelease(name);
    const zone = CFTimeZoneCreateWithName(null, name, 0) orelse return error.TestUnexpectedResult;
    defer CFRelease(zone);
    const before = observe(zone, 1772953140000); // 2026-03-08T06:59:00Z
    const after = observe(zone, 1772953260000); // 2026-03-08T07:01:00Z
    try std.testing.expectEqual(@as(?i32, -18000), before.offset_seconds);
    try std.testing.expectEqual(@as(?i32, -14400), after.offset_seconds);
    try std.testing.expectEqualStrings("America/New_York", after.name[0..after.name_len]);
}

test "Run local timezone macOS system sample owns its identity across calls" {
    const first = sample(1791511800000);
    _ = sample(1791598200000);
    try std.testing.expect(first.offset_seconds != null);
    try std.testing.expect(first.name_len > 0);
    try std.testing.expect(std.unicode.utf8ValidateSlice(first.name[0..first.name_len]));
}
