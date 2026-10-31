const std = @import("std");
const native_sdk = @import("native_sdk");

pub const max_path_bytes: usize = 16 * 1024;
pub const lifetime_nanoseconds: u64 = 5 * 60 * std.time.ns_per_s;
pub const Preparation = struct { id: u64, revision: u64 };
const Grant = struct {
    token: u64,
    generation: u64,
    window_id: native_sdk.platform.WindowId,
    expires_at_monotonic_ns: u64,
    preparation: Preparation,
};

/// A connection capability for Product-owned preparation. No source bytes,
/// paths or Product policy live here. Retargeting never renews the deadline.
pub const State = struct {
    next_token: u64 = 1,
    grant: ?Grant = null,

    pub fn invalidate(self: *State) ?Preparation {
        const old = self.grant;
        self.grant = null;
        return if (old) |value| value.preparation else null;
    }

    pub fn issue(self: *State, generation: u64, window_id: native_sdk.platform.WindowId, now_ns: u64, preparation: Preparation) error{InvalidPreview}!u64 {
        if (generation == 0 or window_id == 0 or preparation.id == 0 or preparation.revision == 0 or self.next_token == std.math.maxInt(u64) or now_ns > std.math.maxInt(u64) - lifetime_nanoseconds) return error.InvalidPreview;
        const token = self.next_token;
        self.next_token += 1;
        self.grant = .{ .token = token, .generation = generation, .window_id = window_id, .expires_at_monotonic_ns = now_ns + lifetime_nanoseconds, .preparation = preparation };
        return token;
    }

    pub fn check(self: *const State, token: u64, revision: u64, window_id: native_sdk.platform.WindowId, generation: u64, now_ns: u64) error{SkillPreviewNotTrusted}!Preparation {
        const grant = self.grant orelse return error.SkillPreviewNotTrusted;
        if (grant.token != token or grant.preparation.revision != revision or grant.window_id != window_id or grant.generation != generation or now_ns > grant.expires_at_monotonic_ns) return error.SkillPreviewNotTrusted;
        return grant.preparation;
    }

    pub fn retarget(self: *State, preparation: Preparation) void {
        std.debug.assert(self.grant != null and self.grant.?.preparation.id == preparation.id and preparation.revision > self.grant.?.preparation.revision);
        self.grant.?.preparation = preparation;
    }

    /// Every consume attempt invalidates the capability, including rejection.
    pub fn consume(self: *State, token: u64, revision: u64, window_id: native_sdk.platform.WindowId, generation: u64, now_ns: u64) error{SkillPreviewNotTrusted}!Preparation {
        defer _ = self.invalidate();
        return self.check(token, revision, window_id, generation, now_ns);
    }
};

test "Skill grants are one-shot, revision/window/connection bound and never renewed" {
    var state: State = .{};
    const token = try state.issue(3, 7, 100, .{ .id = 5, .revision = 1 });
    _ = try state.check(token, 1, 7, 3, 101); // Read-only admission may return busy.
    state.retarget(.{ .id = 5, .revision = 2 });
    try std.testing.expectError(error.SkillPreviewNotTrusted, state.check(token, 1, 7, 3, 101));
    try std.testing.expectError(error.SkillPreviewNotTrusted, state.check(token, 2, 8, 3, 101));
    try std.testing.expectError(error.SkillPreviewNotTrusted, state.check(token, 2, 7, 4, 101));
    const consumed = try state.consume(token, 2, 7, 3, 100 + lifetime_nanoseconds);
    try std.testing.expectEqual(@as(u64, 5), consumed.id);
    try std.testing.expectError(error.SkillPreviewNotTrusted, state.consume(token, 2, 7, 3, 101));
    const expiring = try state.issue(3, 7, 100, .{ .id = 6, .revision = 1 });
    state.retarget(.{ .id = 6, .revision = 2 });
    try std.testing.expectError(error.SkillPreviewNotTrusted, state.consume(expiring, 2, 7, 3, 101 + lifetime_nanoseconds));
    try std.testing.expect(state.grant == null);
    const wrong = try state.issue(3, 7, 100, .{ .id = 7, .revision = 1 });
    try std.testing.expectError(error.SkillPreviewNotTrusted, state.consume(wrong + 1, 1, 7, 3, 101));
    try std.testing.expect(state.grant == null);
}
