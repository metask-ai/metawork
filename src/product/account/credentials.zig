//! Product Account runtime credential ownership.
const std = @import("std");
const builtin = @import("builtin");
const oauth = @import("account_oauth");

/// A moment on both clocks. Whichever reaches it first decides: the wall
/// clock can be set back, and only it survives a restart of the machine.
pub const Moment = struct {
    wall: ?i64,
    boot: i64,

    pub fn reached(self: Moment, wall_now: ?i64, boot_now: i64) bool {
        if (self.boot <= boot_now) return true;
        const at = self.wall orelse return false;
        return at <= (wall_now orelse return false);
    }
};

/// What one token response issued. Made before its request is sent, so a
/// rotation the server already made is never lost to a local allocation.
/// Lives on the heap and is never copied: its secrets are its own storage.
pub const Grant = struct {
    allocator: std.mem.Allocator,
    storage: [2 * oauth.Limits.secret_bytes]u8 = undefined,
    fixed: std.heap.FixedBufferAllocator = undefined,
    refresh_token: oauth.Secret = .{},
    /// Absent for a stored login whose refresh token was not exchanged yet.
    access_token: oauth.Secret = .{},
    expires_at: i64 = 0,
    /// When the access token is over and when it is renewed, once dated.
    times: ?struct { expires: Moment, renews: Moment } = null,
    /// Counts the access tokens installed in this process.
    generation: u64 = 0,
    /// False once a logout could not delete the stored refresh token: its
    /// marker is stored beside it, so nothing may send it any more.
    renewable: bool = true,

    pub fn create(allocator: std.mem.Allocator) std.mem.Allocator.Error!*Grant {
        const self = try allocator.create(Grant);
        self.* = .{ .allocator = allocator };
        self.fixed = .init(&self.storage);
        return self;
    }

    /// A login restored from its refresh token alone.
    pub fn createStored(allocator: std.mem.Allocator, refresh_token: []const u8) !*Grant {
        const self = try create(allocator);
        errdefer self.destroy();
        self.refresh_token = try .init(self.secretAllocator(), refresh_token);
        return self;
    }

    pub fn destroy(self: *Grant) void {
        self.refresh_token.deinit();
        self.access_token.deinit();
        std.crypto.secureZero(u8, &self.storage);
        self.allocator.destroy(self);
    }

    /// Holds both secrets of a response at their largest.
    pub fn secretAllocator(self: *Grant) std.mem.Allocator {
        return self.fixed.allocator();
    }

    /// Takes tokens parsed into `secretAllocator`.
    pub fn issue(self: *Grant, tokens: *oauth.TokenSet) void {
        self.access_token = tokens.access_token.take();
        self.refresh_token = tokens.refresh_token.take();
        self.expires_at = tokens.expires_at;
    }

    pub fn accessToken(self: *const Grant) ?[]const u8 {
        return if (self.access_token.owned) self.access_token.view() else null;
    }

    /// Ownership leaves `slot`.
    pub fn take(slot: *?*Grant) *Grant {
        const result = slot.*.?;
        slot.* = null;
        return result;
    }
};

/// What this process holds of the login. Only a commit changes it. Requests are
/// sent with their own copies, so nothing borrows it beyond a main-thread call.
pub const Credentials = struct {
    current: ?*Grant = null,
    generation: u64 = 0,

    pub fn install(self: *Credentials, grant: *Grant) void {
        self.drop();
        if (grant.accessToken() != null) {
            self.advance();
            grant.generation = self.generation;
        }
        self.current = grant;
    }

    pub fn end(self: *Credentials) void {
        if (self.current == null) return;
        self.drop();
        self.advance();
    }

    /// An access token is held; a stored login may have none yet.
    pub fn available(self: *const Credentials) bool {
        return self.accessToken() != null;
    }

    pub fn accessToken(self: *const Credentials) ?[]const u8 {
        return (self.current orelse return null).accessToken();
    }

    pub fn refreshToken(self: *const Credentials) ?*const oauth.Secret {
        return &(self.current orelse return null).refresh_token;
    }

    pub fn deinit(self: *Credentials) void {
        self.drop();
    }

    fn drop(self: *Credentials) void {
        if (self.current) |grant| grant.destroy();
        self.current = null;
    }

    fn advance(self: *Credentials) void {
        self.generation +%= 1;
        if (self.generation == 0) self.generation = 1;
    }
};

pub const TestSupport = if (builtin.is_test) struct {
    /// A grant as a token response leaves it.
    pub fn issued(allocator: std.mem.Allocator, access_token: []const u8, refresh_token: []const u8, expires_at: i64) !*Grant {
        const grant = try Grant.createStored(allocator, refresh_token);
        errdefer grant.destroy();
        grant.access_token = try .init(grant.secretAllocator(), access_token);
        grant.expires_at = expires_at;
        return grant;
    }
} else struct {};

test "a grant holds a response of the largest tokens without allocating again" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    const grant = try Grant.create(failing.allocator());
    defer grant.destroy();
    const token = "t" ** oauth.Limits.secret_bytes;
    const body = "{\"access_token\":\"" ++ token ++ "\",\"refresh_token\":\"" ++ token ++ "\",\"token_type\":\"Bearer\",\"expires_in\":3600}";
    var tokens = try oauth.parseTokenResponse(grant.secretAllocator(), body, 100);
    grant.issue(&tokens);
    try std.testing.expectEqualStrings(token, grant.accessToken().?);
    try std.testing.expectEqualStrings(token, grant.refresh_token.view());
    try std.testing.expectEqual(@as(i64, 3700), grant.expires_at);
    try std.testing.expect(!failing.has_induced_failure);
}

test "credentials hold one grant and a stored login has no access token" {
    var credentials: Credentials = .{};
    defer credentials.deinit();
    try std.testing.expect(credentials.refreshToken() == null);
    credentials.install(try Grant.createStored(std.testing.allocator, "refresh-only"));
    try std.testing.expect(!credentials.available());
    try std.testing.expectEqualStrings("refresh-only", credentials.refreshToken().?.view());
    credentials.install(try TestSupport.issued(std.testing.allocator, "access-1", "refresh-1", 10));
    try std.testing.expectEqualStrings("access-1", credentials.accessToken().?);
    try std.testing.expectEqualStrings("refresh-1", credentials.refreshToken().?.view());
    try std.testing.expectEqual(@as(u64, 1), credentials.current.?.generation);
    credentials.end();
    try std.testing.expect(!credentials.available() and credentials.current == null);
}
