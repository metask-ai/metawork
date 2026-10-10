//! Product Account refresh-token persistence policy.
//!
//! Model/provider preferences are owned and migrated by Models. Account only
//! persists the credential required to restore the company identity session.
const std = @import("std");
const oauth = @import("account_oauth");
const product_identity = @import("metawork_product_identity");

pub const service = product_identity.accountCredentialService();
pub const refresh_token_account = "metask-refresh-token";
pub const refresh_in_flight_account = "metask-refresh-in-flight";
pub const marker_bytes = 67;

pub fn refreshBinding(value: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(value, &digest, .{});
    return digest;
}

pub fn refreshMarker(value: []const u8) [marker_bytes]u8 {
    var digest = refreshBinding(value);
    defer std.crypto.secureZero(u8, &digest);
    var marker: [marker_bytes]u8 = undefined;
    @memcpy(marker[0..3], "v1:");
    const hex = std.fmt.bytesToHex(digest, .lower);
    @memcpy(marker[3..], &hex);
    return marker;
}

fn validMarker(value: []const u8) bool {
    if (value.len != marker_bytes or !std.mem.startsWith(u8, value, "v1:")) return false;
    for (value[3..]) |c| if (!(c >= '0' and c <= '9') and !(c >= 'a' and c <= 'f')) return false;
    return true;
}

pub const StoreError = error{
    ReadFailed,
    WriteFailed,
    DeleteFailed,
};

pub const Backend = struct {
    context: *anyopaque,
    set_refresh_token_fn: *const fn (*anyopaque, []const u8) StoreError!void,
    get_refresh_token_fn: *const fn (*anyopaque, []u8) StoreError!?[]const u8,
    delete_refresh_token_fn: *const fn (*anyopaque) StoreError!void,

    set_refresh_marker_fn: *const fn (*anyopaque, []const u8) StoreError!void,
    get_refresh_marker_fn: *const fn (*anyopaque, []u8) StoreError!?[]const u8,
    delete_refresh_marker_fn: *const fn (*anyopaque) StoreError!void,

    pub fn beginRefresh(self: Backend, token: *const oauth.Secret) StoreError!void {
        var marker = refreshMarker(token.view());
        defer std.crypto.secureZero(u8, &marker);
        try self.set_refresh_marker_fn(self.context, &marker);
    }

    pub fn clearRefreshMarker(self: Backend) StoreError!void {
        try self.delete_refresh_marker_fn(self.context);
    }

    pub fn setRefreshToken(self: Backend, value: []const u8) StoreError!void {
        if (value.len == 0 or value.len > oauth.Limits.secret_bytes)
            return error.WriteFailed;
        return self.set_refresh_token_fn(self.context, value);
    }

    pub fn getRefreshToken(self: Backend, output: []u8) StoreError!?[]const u8 {
        return self.get_refresh_token_fn(self.context, output);
    }

    pub fn deleteRefreshToken(self: Backend) StoreError!void {
        return self.delete_refresh_token_fn(self.context);
    }
};

pub const RestoredAccount = struct {
    refresh_token: oauth.Secret,

    pub fn deinit(self: *RestoredAccount) void {
        self.refresh_token.deinit();
        self.* = undefined;
    }
};

pub const RestoreResult = union(enum) {
    signed_out,
    blocked,
    account: RestoredAccount,

    pub fn deinit(self: *RestoreResult) void {
        switch (self.*) {
            .account => |*account| account.deinit(),
            .signed_out, .blocked => {},
        }
        self.* = .signed_out;
    }
};

pub fn restore(
    allocator: std.mem.Allocator,
    backend: Backend,
) (StoreError || std.mem.Allocator.Error || oauth.ProtocolError)!RestoreResult {
    var refresh_storage: [oauth.Limits.secret_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &refresh_storage);
    const refresh_token = try backend.getRefreshToken(&refresh_storage);
    var marker_storage: [marker_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &marker_storage);
    const marker = try backend.get_refresh_marker_fn(backend.context, &marker_storage);
    if (marker) |value| {
        if (!validMarker(value)) return error.ReadFailed;
        if (refresh_token) |token| {
            var expected = refreshMarker(token);
            defer std.crypto.secureZero(u8, &expected);
            if (std.crypto.timing_safe.eql([marker_bytes]u8, expected, value[0..marker_bytes].*)) return .blocked;
        } else {
            try backend.clearRefreshMarker();
        }
    }
    if (refresh_token == null) return .signed_out;
    return .{ .account = .{
        .refresh_token = try oauth.Secret.init(allocator, refresh_token.?),
    } };
}

pub fn commitRefresh(
    backend: Backend,
    refresh_token: *const oauth.Secret,
) StoreError!void {
    try backend.setRefreshToken(refresh_token.view());
}

/// Logout revokes only Account-owned durable authorization. Models owns and
/// preserves provider/default intent independently of the identity session.
pub fn commitSignedOut(backend: Backend) StoreError!void {
    try backend.deleteRefreshToken();
    try backend.clearRefreshMarker();
}

const FakeBackend = struct {
    refresh_token: ?[]const u8 = null,
    marker: ?[marker_bytes]u8 = null,
    marker_delete_fails: bool = false,
    write_fails: bool = false,
    delete_fails: bool = false,

    fn backend(self: *FakeBackend) Backend {
        return .{
            .context = self,
            .set_refresh_token_fn = setRefreshToken,
            .get_refresh_token_fn = getRefreshToken,
            .delete_refresh_token_fn = deleteRefreshToken,
            .set_refresh_marker_fn = setMarker,
            .get_refresh_marker_fn = getMarker,
            .delete_refresh_marker_fn = deleteMarker,
        };
    }

    fn setMarker(context: *anyopaque, value: []const u8) StoreError!void {
        const self: *FakeBackend = @ptrCast(@alignCast(context));
        self.marker = value[0..marker_bytes].*;
    }
    fn getMarker(context: *anyopaque, output: []u8) StoreError!?[]const u8 {
        const self: *FakeBackend = @ptrCast(@alignCast(context));
        const marker = self.marker orelse return null;
        @memcpy(output[0..marker_bytes], &marker);
        return output[0..marker_bytes];
    }
    fn deleteMarker(context: *anyopaque) StoreError!void {
        const self: *FakeBackend = @ptrCast(@alignCast(context));
        if (self.marker_delete_fails) return error.DeleteFailed;
        self.marker = null;
    }

    fn setRefreshToken(context: *anyopaque, value: []const u8) StoreError!void {
        const self: *FakeBackend = @ptrCast(@alignCast(context));
        if (self.write_fails) return error.WriteFailed;
        self.refresh_token = value;
    }

    fn getRefreshToken(
        context: *anyopaque,
        output: []u8,
    ) StoreError!?[]const u8 {
        const self: *FakeBackend = @ptrCast(@alignCast(context));
        const value = self.refresh_token orelse return null;
        if (value.len > output.len) return error.ReadFailed;
        @memcpy(output[0..value.len], value);
        return output[0..value.len];
    }

    fn deleteRefreshToken(context: *anyopaque) StoreError!void {
        const self: *FakeBackend = @ptrCast(@alignCast(context));
        if (self.delete_fails) return error.DeleteFailed;
        self.refresh_token = null;
    }
};

test "Account restores only its refresh credential" {
    var fake: FakeBackend = .{ .refresh_token = "refresh-token" };
    var restored = try restore(std.testing.allocator, fake.backend());
    defer restored.deinit();
    try std.testing.expectEqualStrings(
        "refresh-token",
        restored.account.refresh_token.view(),
    );
}

test "Account logout deletes only its refresh credential" {
    var fake: FakeBackend = .{ .refresh_token = "refresh-token" };
    try commitSignedOut(fake.backend());
    try std.testing.expect(fake.refresh_token == null);
}

test "definite credential write failure preserves the committed credential" {
    var fake: FakeBackend = .{
        .refresh_token = "old-refresh-token",
        .write_fails = true,
    };
    var replacement = try oauth.Secret.init(
        std.testing.allocator,
        "new-refresh-token",
    );
    defer replacement.deinit();

    try std.testing.expectError(
        error.WriteFailed,
        commitRefresh(fake.backend(), &replacement),
    );
    try std.testing.expectEqualStrings(
        "old-refresh-token",
        fake.refresh_token.?,
    );
}

test "definite credential delete failure preserves the committed credential" {
    var fake: FakeBackend = .{
        .refresh_token = "refresh-token",
        .delete_fails = true,
    };

    try std.testing.expectError(
        error.DeleteFailed,
        commitSignedOut(fake.backend()),
    );
    try std.testing.expectEqualStrings("refresh-token", fake.refresh_token.?);
}

test "restart blocks the consumed candidate and accepts a committed replacement" {
    var fake: FakeBackend = .{ .refresh_token = "old-token" };
    var old = try oauth.Secret.init(std.testing.allocator, "old-token");
    defer old.deinit();
    try fake.backend().beginRefresh(&old);
    var uncertain = try restore(std.testing.allocator, fake.backend());
    defer uncertain.deinit();
    try std.testing.expect(uncertain == .blocked);

    fake.refresh_token = "new-token";
    fake.marker_delete_fails = true;
    try std.testing.expectError(error.DeleteFailed, fake.backend().clearRefreshMarker());
    var committed = try restore(std.testing.allocator, fake.backend());
    defer committed.deinit();
    try std.testing.expectEqualStrings("new-token", committed.account.refresh_token.view());
    try fake.backend().beginRefresh(&committed.account.refresh_token);
    var marked_new = try restore(std.testing.allocator, fake.backend());
    defer marked_new.deinit();
    try std.testing.expect(marked_new == .blocked);
}

test "restart rejects unknown markers and cleans token-free residues" {
    var fake: FakeBackend = .{ .marker = refreshMarker("old-token") };
    fake.marker.?[0] = 'x';
    try std.testing.expectError(error.ReadFailed, restore(std.testing.allocator, fake.backend()));
    fake.marker = refreshMarker("old-token");
    var empty = try restore(std.testing.allocator, fake.backend());
    defer empty.deinit();
    try std.testing.expect(empty == .signed_out);
    try std.testing.expect(fake.marker == null);
}

test "logout never clears the blocking marker before token deletion succeeds" {
    var fake: FakeBackend = .{ .refresh_token = "old-token", .marker = refreshMarker("old-token"), .delete_fails = true };
    try std.testing.expectError(error.DeleteFailed, commitSignedOut(fake.backend()));
    try std.testing.expect(fake.marker != null);
    fake.delete_fails = false;
    fake.marker_delete_fails = true;
    try std.testing.expectError(error.DeleteFailed, commitSignedOut(fake.backend()));
    try std.testing.expect(fake.refresh_token == null);
    try std.testing.expect(fake.marker != null);
}
