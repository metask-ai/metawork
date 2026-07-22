const std = @import("std");
const contract = @import("metawork_account_contract");
const state = @import("account_state");
const oauth = @import("account_oauth");

pub const service = "dev.metawork.account";
pub const refresh_token_account = "metask-refresh-token";
pub const public_state_name = "account.json";

pub const StoreError = error{
    ReadFailed,
    WriteFailed,
    DeleteFailed,
    InvalidData,
};

fn PublicText(comptime capacity: usize) type {
    return struct {
        bytes: [capacity]u8 = undefined,
        len: usize = 0,

        fn set(self: *@This(), value: []const u8) StoreError!void {
            if (value.len == 0 or value.len > capacity or
                !std.unicode.utf8ValidateSlice(value))
                return error.InvalidData;
            @memcpy(self.bytes[0..value.len], value);
            self.len = value.len;
        }

        fn setOptional(self: *@This(), value: []const u8) StoreError!void {
            if (value.len == 0) {
                self.len = 0;
                return;
            }
            try self.set(value);
        }

        pub fn view(self: *const @This()) []const u8 {
            return self.bytes[0..self.len];
        }
    };
}

/// Windows persists only secret-free account identity and the user's last
/// catalog selection. It is deliberately unversioned: rapid-development
/// changes hard-cut this file in place instead of accumulating parsers.
pub const PublicState = struct {
    account_id: PublicText(contract.Limits.account_id_bytes) = .{},
    profile_id: PublicText(contract.Limits.profile_id_bytes) = .{},
    display_name: PublicText(contract.Limits.display_name_bytes) = .{},
    api_key_id: PublicText(contract.Limits.api_key_id_bytes) = .{},
    model_id: PublicText(contract.Limits.model_id_bytes) = .{},

    pub fn init(
        account_identity: state.AccountIdentity,
        api_key_id: []const u8,
        model_id: []const u8,
    ) StoreError!PublicState {
        var result: PublicState = .{};
        try result.account_id.set(account_identity.accountId());
        try result.profile_id.set(account_identity.profileId());
        try result.display_name.set(account_identity.displayName());
        try result.api_key_id.setOptional(api_key_id);
        try result.model_id.setOptional(model_id);
        if ((result.api_key_id.len == 0) != (result.model_id.len == 0))
            return error.InvalidData;
        return result;
    }

    pub fn identity(self: *const PublicState) StoreError!state.AccountIdentity {
        return state.AccountIdentity.init(
            self.account_id.view(),
            self.profile_id.view(),
            self.display_name.view(),
        ) catch error.InvalidData;
    }

    pub fn apiKeyId(self: *const PublicState) []const u8 {
        return self.api_key_id.view();
    }

    pub fn modelId(self: *const PublicState) []const u8 {
        return self.model_id.view();
    }
};

pub const Backend = struct {
    context: *anyopaque,
    set_refresh_token_fn: *const fn (*anyopaque, []const u8) StoreError!void,
    get_refresh_token_fn: *const fn (*anyopaque, []u8) StoreError!?[]const u8,
    delete_refresh_token_fn: *const fn (*anyopaque) StoreError!void,
    load_public_state_fn: *const fn (*anyopaque) StoreError!?PublicState,
    commit_public_state_fn: *const fn (*anyopaque, PublicState) StoreError!void,
    delete_public_state_fn: *const fn (*anyopaque) StoreError!void,

    pub fn setRefreshToken(self: Backend, value: []const u8) StoreError!void {
        return self.set_refresh_token_fn(self.context, value);
    }

    pub fn getRefreshToken(
        self: Backend,
        output: []u8,
    ) StoreError!?[]const u8 {
        return self.get_refresh_token_fn(self.context, output);
    }

    pub fn deleteRefreshToken(self: Backend) StoreError!void {
        return self.delete_refresh_token_fn(self.context);
    }

    pub fn loadPublicState(self: Backend) StoreError!?PublicState {
        return self.load_public_state_fn(self.context);
    }

    pub fn commitPublicState(
        self: Backend,
        value: PublicState,
    ) StoreError!void {
        return self.commit_public_state_fn(self.context, value);
    }

    pub fn deletePublicState(self: Backend) StoreError!void {
        return self.delete_public_state_fn(self.context);
    }
};

pub const RestoredAccount = struct {
    public_state: PublicState,
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
    const public_state = try backend.loadPublicState();
    var refresh_storage: [oauth.Limits.secret_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &refresh_storage);
    const refresh_token = try backend.getRefreshToken(&refresh_storage);
    if (public_state == null or refresh_token == null) return .signed_out;
    _ = try public_state.?.identity();
    return .{ .account = .{
        .public_state = public_state.?,
        .refresh_token = try oauth.Secret.init(allocator, refresh_token.?),
    } };
}

pub fn commitAuthenticated(
    backend: Backend,
    refresh_token: *const oauth.Secret,
    identity: state.AccountIdentity,
) StoreError!PublicState {
    const public_state = try PublicState.init(identity, "", "");
    try backend.commitPublicState(public_state);
    try backend.setRefreshToken(refresh_token.view());
    return public_state;
}

pub fn commitRefresh(
    backend: Backend,
    refresh_token: *const oauth.Secret,
) StoreError!void {
    try backend.setRefreshToken(refresh_token.view());
}

pub fn commitSelection(
    backend: Backend,
    identity: state.AccountIdentity,
    api_key_id: []const u8,
    model_id: []const u8,
) StoreError!PublicState {
    const public_state = try PublicState.init(
        identity,
        api_key_id,
        model_id,
    );
    try backend.commitPublicState(public_state);
    return public_state;
}

pub fn commitSignedOut(backend: Backend) StoreError!void {
    try backend.deleteRefreshToken();
    try backend.deletePublicState();
}

const FakeBackend = struct {
    refresh_token: ?[]const u8 = null,
    public_state: ?PublicState = null,
    set_refresh_count: usize = 0,
    delete_refresh_count: usize = 0,
    delete_state_count: usize = 0,

    fn backend(self: *FakeBackend) Backend {
        return .{
            .context = self,
            .set_refresh_token_fn = setRefresh,
            .get_refresh_token_fn = getRefresh,
            .delete_refresh_token_fn = deleteRefresh,
            .load_public_state_fn = loadState,
            .commit_public_state_fn = commitState,
            .delete_public_state_fn = deleteState,
        };
    }

    fn setRefresh(context: *anyopaque, value: []const u8) StoreError!void {
        const self: *FakeBackend = @ptrCast(@alignCast(context));
        self.refresh_token = value;
        self.set_refresh_count += 1;
    }

    fn getRefresh(
        context: *anyopaque,
        output: []u8,
    ) StoreError!?[]const u8 {
        const self: *FakeBackend = @ptrCast(@alignCast(context));
        const value = self.refresh_token orelse return null;
        if (value.len > output.len) return error.ReadFailed;
        @memcpy(output[0..value.len], value);
        return output[0..value.len];
    }

    fn deleteRefresh(context: *anyopaque) StoreError!void {
        const self: *FakeBackend = @ptrCast(@alignCast(context));
        self.refresh_token = null;
        self.delete_refresh_count += 1;
    }

    fn loadState(context: *anyopaque) StoreError!?PublicState {
        const self: *FakeBackend = @ptrCast(@alignCast(context));
        return self.public_state;
    }

    fn commitState(context: *anyopaque, value: PublicState) StoreError!void {
        const self: *FakeBackend = @ptrCast(@alignCast(context));
        self.public_state = value;
    }

    fn deleteState(context: *anyopaque) StoreError!void {
        const self: *FakeBackend = @ptrCast(@alignCast(context));
        self.public_state = null;
        self.delete_state_count += 1;
    }
};

test "Windows restore requires one refresh token and matching public state" {
    const identity = try state.AccountIdentity.init(
        "account-1",
        "profile-1",
        "MetaWork User",
    );
    var fake: FakeBackend = .{};
    try std.testing.expect((try restore(
        std.testing.allocator,
        fake.backend(),
    )) == .signed_out);

    fake.public_state = try PublicState.init(identity, "api-1", "model-1");
    try std.testing.expect((try restore(
        std.testing.allocator,
        fake.backend(),
    )) == .signed_out);

    fake.refresh_token = "refresh-only";
    var restored = try restore(std.testing.allocator, fake.backend());
    defer restored.deinit();
    try std.testing.expect(restored == .account);
    try std.testing.expectEqualStrings(
        "refresh-only",
        restored.account.refresh_token.view(),
    );
    try std.testing.expectEqualStrings(
        "api-1",
        restored.account.public_state.apiKeyId(),
    );
}

test "Windows persistence stores no access token or provider credential" {
    const identity = try state.AccountIdentity.init(
        "account-1",
        "profile-1",
        "MetaWork User",
    );
    var refresh = try oauth.Secret.init(std.testing.allocator, "refresh-only");
    defer refresh.deinit();
    var fake: FakeBackend = .{};
    _ = try commitAuthenticated(fake.backend(), &refresh, identity);
    _ = try commitSelection(
        fake.backend(),
        identity,
        "api-public-id",
        "model-public-id",
    );
    try std.testing.expectEqualStrings("refresh-only", fake.refresh_token.?);
    try std.testing.expectEqual(@as(usize, 1), fake.set_refresh_count);
    try std.testing.expectEqualStrings(
        "api-public-id",
        fake.public_state.?.apiKeyId(),
    );
    try std.testing.expectEqualStrings(
        "model-public-id",
        fake.public_state.?.modelId(),
    );
}

test "Windows logout removes the refresh token before public state" {
    var fake: FakeBackend = .{
        .refresh_token = "refresh-only",
        .public_state = .{},
    };
    try commitSignedOut(fake.backend());
    try std.testing.expect(fake.refresh_token == null);
    try std.testing.expect(fake.public_state == null);
    try std.testing.expectEqual(@as(usize, 1), fake.delete_refresh_count);
    try std.testing.expectEqual(@as(usize, 1), fake.delete_state_count);
}
