//! Process-only timing for one installed OAuth grant. Registry reconciliation
//! supplies the binding; this leaf owns no identifiers, persistence or effects.
const std = @import("std");

pub const Grant = struct {
    expires_at: u64,
    refresh_due: ?u64 = null,
    retry_not_before: u64 = 0,
    failures: u8 = 0,

    pub fn observeTime(self: *Grant, now_ms: ?u64) void {
        const now = now_ms orelse return;
        if (now == 0 or self.refresh_due != null) return;
        const remaining = self.expires_at -| now;
        self.refresh_due = self.expires_at - @min(remaining / 4, 60_000);
    }

    pub fn eligibleAt(self: Grant) u64 {
        return @max(self.refresh_due orelse self.expires_at, self.retry_not_before);
    }

    pub fn deferAttempt(self: *Grant, now_ms: ?u64) void {
        const now = now_ms orelse return;
        if (now == 0) return;
        const delay = @min(@as(u64, 30_000) << @as(u6, @intCast(@min(self.failures, 4))), 300_000);
        self.failures +|= 1;
        self.retry_not_before = now +| delay;
    }
};

test "grant timing handles unavailable past short and saturating time without changing expiry" {
    var grant: Grant = .{ .expires_at = 1000 };
    grant.observeTime(null);
    grant.observeTime(0);
    try std.testing.expect(grant.refresh_due == null);
    grant.observeTime(996);
    try std.testing.expectEqual(@as(u64, 999), grant.eligibleAt());
    grant.observeTime(10_000);
    try std.testing.expectEqual(@as(u64, 999), grant.eligibleAt());
    grant.deferAttempt(std.math.maxInt(u64) - 1);
    try std.testing.expectEqual(std.math.maxInt(u64), grant.eligibleAt());
    try std.testing.expectEqual(@as(u64, 1000), grant.expires_at);
    var expired: Grant = .{ .expires_at = 1000 };
    expired.observeTime(2000);
    try std.testing.expectEqual(@as(u64, 1000), expired.eligibleAt());
}
