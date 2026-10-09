//! Application-owned run_local_timezone capability. Official SDK clock reads
//! remain outside this seam; only structured timezone facts are missing.
const builtin = @import("builtin");

pub const max_name_bytes = 512;
pub const Observation = struct {
    offset_seconds: ?i32 = null,
    kind: enum { iana, windows } = .iana,
    name: [max_name_bytes]u8 = undefined,
    name_len: usize = 0,
};

const Platform = switch (builtin.os.tag) {
    .macos => @import("run_local_timezone/macos.zig"),
    .windows => @import("run_local_timezone/windows.zig"),
    else => struct {
        pub fn sample(_: i64) Observation {
            return .{};
        }
    },
};

pub fn sample(unix_ms: i64) Observation {
    return Platform.sample(unix_ms);
}

test "Run local timezone snapshot owns bounded system facts" {
    const std = @import("std");
    const observed = sample(1791509400000);
    try std.testing.expect(observed.name_len <= observed.name.len);
    if (builtin.os.tag == .macos or builtin.os.tag == .windows)
        try std.testing.expect(observed.offset_seconds != null);
    _ = Platform;
}
