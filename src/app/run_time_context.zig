//! Application binding of official SDK clock and the registered timezone seam.
const native_sdk = @import("native_sdk");
const agent = @import("metawork_agent");
const timezone = @import("../native_sdk_compat/run_local_timezone.zig");

pub const source: agent.RunTimeSource = .{ .sample_fn = sample };

fn sample(_: ?*anyopaque) agent.RunTimeSnapshot {
    const unix_ms = native_sdk.runtime.nowMs();
    if (unix_ms <= 0) return .{};
    const observed = timezone.sample(unix_ms);
    return .{
        .unix_ms = unix_ms,
        .utc_offset_seconds = observed.offset_seconds,
        .timezone = agent.RunTimeZoneIdentity.init(switch (observed.kind) {
            .iana => .iana,
            .windows => .windows,
        }, observed.name[0..observed.name_len]),
    };
}

test "Run time Application source samples bounded owned local facts" {
    const std = @import("std");
    const snapshot = source.sample();
    try std.testing.expect(snapshot.unix_ms != null);
    try std.testing.expect(snapshot.utc_offset_seconds != null);
    try std.testing.expect(snapshot.timezone != null);
}
