//! Product Account runtime credential ownership.
const std = @import("std");
const contract = @import("metawork_account_contract");
const state = @import("account_state");
const oauth = @import("account_oauth");
const metask = @import("metask_client");

/// Opaque refreshed OAuth generation. App may persist and atomically install
/// it, but token bytes remain owned and interpreted by Account.
pub const CredentialRotation = struct {
    tokens: oauth.TokenSet,
    owned: bool = true,

    pub fn deinit(self: *CredentialRotation) void {
        if (!self.owned) return;
        self.tokens.deinit();
        self.owned = false;
    }

    pub fn accountId(self: *const CredentialRotation) []const u8 {
        std.debug.assert(self.owned);
        return self.tokens.accountId();
    }

    pub fn belongsToAccount(
        self: *const CredentialRotation,
        account_id: []const u8,
    ) bool {
        return std.mem.eql(u8, self.accountId(), account_id);
    }

    pub fn persistenceInput(
        self: *const CredentialRotation,
    ) *const oauth.TokenSet {
        std.debug.assert(self.owned);
        return &self.tokens;
    }

    pub fn take(self: *CredentialRotation) CredentialRotation {
        std.debug.assert(self.owned);
        const result: CredentialRotation = .{
            .tokens = self.tokens.take(),
        };
        self.owned = false;
        return result;
    }

    fn takeTokens(self: *CredentialRotation) oauth.TokenSet {
        std.debug.assert(self.owned);
        const result = self.tokens.take();
        self.owned = false;
        return result;
    }
};

/// Concrete Account-owned secret lifetime. App may compose this owner and
/// coordinate commits, but it never receives a borrowed token slice or takes
/// over the underlying allocations.
pub const CredentialOwner = struct {
    tokens: ?oauth.TokenSet = null,
    stored_refresh_token: ?oauth.Secret = null,

    pub fn installRefreshToken(
        self: *CredentialOwner,
        refresh_token: *oauth.Secret,
    ) void {
        self.clear();
        self.stored_refresh_token = refresh_token.take();
    }

    pub fn installStored(
        self: *CredentialOwner,
        allocator: std.mem.Allocator,
        access_token: []const u8,
        refresh_token: []const u8,
        expires_at: i64,
        account_id: []const u8,
    ) !void {
        var stored = try oauth.TokenSet.fromStored(
            allocator,
            access_token,
            refresh_token,
            expires_at,
            account_id,
        );
        self.replace(&stored);
    }

    pub fn replace(
        self: *CredentialOwner,
        replacement: *oauth.TokenSet,
    ) void {
        self.clear();
        self.tokens = replacement.take();
    }

    pub fn replaceRotation(
        self: *CredentialOwner,
        rotation: *CredentialRotation,
    ) void {
        self.clear();
        self.tokens = rotation.takeTokens();
    }

    pub fn available(self: *const CredentialOwner) bool {
        return self.tokens != null;
    }

    pub fn refreshAvailable(self: *const CredentialOwner) bool {
        return self.tokens != null or self.stored_refresh_token != null;
    }

    pub fn expiresAt(self: *const CredentialOwner) ?i64 {
        return if (self.tokens) |*tokens| tokens.expires_at else null;
    }

    pub fn belongsToPrincipal(
        self: *const CredentialOwner,
        principal_ref: []const u8,
    ) bool {
        const current = if (self.tokens) |*value| value else return false;
        return std.mem.eql(u8, current.accountId(), principal_ref);
    }

    pub fn refresh(
        self: *const CredentialOwner,
        allocator: std.mem.Allocator,
        transport: metask.Transport,
        now_unix_seconds: i64,
        control: ?metask.RequestControl,
    ) metask.ClientError!CredentialRotation {
        var refreshed = if (self.tokens) |*current| try metask.refresh(
            allocator,
            transport,
            current,
            now_unix_seconds,
            control,
        ) else blk: {
            const refresh_token = if (self.stored_refresh_token) |*value|
                value
            else
                return error.TokenRefreshFailed;
            break :blk try metask.refreshWithToken(
                allocator,
                transport,
                refresh_token,
                now_unix_seconds,
                control,
            );
        };
        return .{ .tokens = refreshed.take() };
    }

    pub fn fetchIdentity(
        self: *const CredentialOwner,
        transport: metask.Transport,
        control: ?metask.RequestControl,
    ) metask.ClientError!state.AccountIdentity {
        const current = if (self.tokens) |*value|
            value
        else
            return error.Unauthorized;
        return metask.fetchIdentity(transport, current, control);
    }

    pub fn authorizationLease(
        self: *const CredentialOwner,
        allocator: std.mem.Allocator,
        principal_ref: []const u8,
        authorization_generation: u64,
    ) !contract.OwnedAuthorizationLease {
        const current = if (self.tokens) |*value| value else return error.Unauthorized;
        if (!std.mem.eql(u8, current.accountId(), principal_ref))
            return error.Unauthorized;
        return contract.OwnedAuthorizationLease.init(
            allocator,
            principal_ref,
            current.access_token.view(),
            authorization_generation,
        );
    }

    pub fn clear(self: *CredentialOwner) void {
        if (self.tokens) |*current| current.deinit();
        self.tokens = null;
        if (self.stored_refresh_token) |*current| current.deinit();
        self.stored_refresh_token = null;
    }

    pub fn deinit(self: *CredentialOwner) void {
        self.clear();
    }
};

test "CredentialOwner replaces and clears OAuth secret ownership" {
    var first = try oauth.TokenSet.fromStored(
        std.testing.allocator,
        "access-1",
        "refresh-1",
        10,
        "account-1",
    );
    defer first.deinit();
    var second = try oauth.TokenSet.fromStored(
        std.testing.allocator,
        "access-2",
        "refresh-2",
        20,
        "account-1",
    );
    defer second.deinit();
    var owner: CredentialOwner = .{};
    defer owner.deinit();

    owner.replace(&first);
    try std.testing.expect(owner.available());
    owner.replace(&second);
    try std.testing.expect(owner.available());
    owner.clear();
    try std.testing.expect(!owner.available());
}

test "CredentialOwner can restore a refresh-only session" {
    var refresh = try oauth.Secret.init(
        std.testing.allocator,
        "refresh-only",
    );
    defer refresh.deinit();
    var owner: CredentialOwner = .{};
    defer owner.deinit();
    owner.installRefreshToken(&refresh);
    try std.testing.expect(owner.refreshAvailable());
    try std.testing.expect(!owner.available());
    owner.clear();
    try std.testing.expect(!owner.refreshAvailable());
}

test "CredentialOwner issues a bounded authorization lease for its principal" {
    var owner: CredentialOwner = .{};
    defer owner.deinit();
    try owner.installStored(
        std.testing.allocator,
        "access-token",
        "refresh-token",
        10,
        "account-1",
    );

    var lease = try owner.authorizationLease(
        std.testing.allocator,
        "account-1",
        7,
    );
    defer lease.deinit();
    try std.testing.expectEqualStrings("account-1", lease.principal_ref);
    try std.testing.expectEqualStrings("access-token", lease.access_token);
    try std.testing.expectEqual(@as(u64, 7), lease.authorization_generation);
    try std.testing.expectError(
        error.Unauthorized,
        owner.authorizationLease(std.testing.allocator, "account-2", 8),
    );
}

test "refresh rotation is available before strict identity lookup" {
    var owner: CredentialOwner = .{};
    defer owner.deinit();
    try owner.installStored(
        std.testing.allocator,
        "old-access",
        "old-refresh",
        10,
        "account-1",
    );
    var fake = struct {
        step: usize = 0,

        fn perform(
            context: *anyopaque,
            request: metask.Request,
            output: []u8,
        ) metask.TransportError!metask.Response {
            const self: *@This() = @ptrCast(@alignCast(context));
            defer self.step += 1;
            return switch (self.step) {
                0 => blk: {
                    if (request.kind != .refresh_token) return error.ProtocolFailed;
                    const body =
                        \\{"access_token":"new-access","refresh_token":"new-refresh","token_type":"Bearer","expires_in":3600,"scope":"metawork:use","account_id":"account-1"}
                    ;
                    @memcpy(output[0..body.len], body);
                    break :blk .{ .status = 200, .body = output[0..body.len] };
                },
                1 => blk: {
                    if (request.kind != .current_user or
                        !std.mem.eql(u8, request.bearer orelse "", "new-access"))
                        return error.ProtocolFailed;
                    const body = "{\"code\":\"INVALID_API_KEY\"}";
                    @memcpy(output[0..body.len], body);
                    break :blk .{ .status = 401, .body = output[0..body.len] };
                },
                else => return error.ProtocolFailed,
            };
        }
    }{};
    var rotation = try owner.refresh(
        std.testing.allocator,
        .{ .context = &fake, .perform_fn = @TypeOf(fake).perform },
        100,
        null,
    );
    defer rotation.deinit();
    try std.testing.expectEqualStrings(
        "new-refresh",
        rotation.persistenceInput().refresh_token.view(),
    );
    try std.testing.expectEqual(@as(usize, 1), fake.step);
    owner.replaceRotation(&rotation);
    try std.testing.expectError(
        error.Unauthorized,
        owner.fetchIdentity(
            .{ .context = &fake, .perform_fn = @TypeOf(fake).perform },
            null,
        ),
    );
    try std.testing.expectEqual(@as(usize, 2), fake.step);
}

test "refresh rotation identity is captured before ownership transfer" {
    var owner: CredentialOwner = .{};
    defer owner.deinit();
    try owner.installStored(
        std.testing.allocator,
        "old-access",
        "old-refresh",
        10,
        "account-1",
    );
    var rotated_tokens = try oauth.TokenSet.fromStored(
        std.testing.allocator,
        "new-access",
        "new-refresh",
        20,
        "account-1",
    );
    var rotation: CredentialRotation = .{
        .tokens = rotated_tokens.take(),
    };
    defer rotation.deinit();

    const belongs_to_current_account = rotation.belongsToAccount("account-1");
    owner.replaceRotation(&rotation);

    try std.testing.expect(belongs_to_current_account);
    try std.testing.expect(owner.available());
}
