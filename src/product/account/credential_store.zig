//! Product Account refresh-token persistence policy.
//!
//! Model/provider preferences are owned and migrated by Models. Account only
//! persists the credential required to restore the company identity session.
const std = @import("std");
const oauth = @import("account_oauth");
const product_identity = @import("metawork_product_identity");

pub const service = product_identity.accountCredentialService();
pub const refresh_token_account = "metask-refresh-token";

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
    account: RestoredAccount,

    pub fn deinit(self: *RestoreResult) void {
        switch (self.*) {
            .account => |*account| account.deinit(),
            .signed_out => {},
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
}

const FakeBackend = struct {
    refresh_token: ?[]const u8 = null,

    fn backend(self: *FakeBackend) Backend {
        return .{
            .context = self,
            .set_refresh_token_fn = setRefreshToken,
            .get_refresh_token_fn = getRefreshToken,
            .delete_refresh_token_fn = deleteRefreshToken,
        };
    }

    fn setRefreshToken(context: *anyopaque, value: []const u8) StoreError!void {
        const self: *FakeBackend = @ptrCast(@alignCast(context));
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
