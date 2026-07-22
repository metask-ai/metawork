const std = @import("std");
const state = @import("account_state");
const oauth = @import("account_oauth");
const metask = @import("metask_client");
const catalog = @import("account_catalog");

/// Opaque refreshed OAuth generation. App may persist and atomically install
/// it, but token bytes remain owned and interpreted by Account.
pub const CredentialRotation = struct {
    tokens: oauth.TokenSet,
    identity: ?state.AccountIdentity = null,
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
            .identity = self.identity,
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

    pub fn refreshedIdentity(
        self: *const CredentialRotation,
    ) ?state.AccountIdentity {
        std.debug.assert(self.owned);
        return self.identity;
    }
};

/// Concrete Account-owned secret lifetime. App may compose this owner and
/// coordinate commits, but it never receives a borrowed token slice or takes
/// over the underlying allocations.
pub const CredentialOwner = struct {
    tokens: ?oauth.TokenSet = null,
    stored_refresh_token: ?oauth.Secret = null,
    cleanup_pending: bool = false,

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
            oauth.scope,
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

    pub fn refresh(
        self: *const CredentialOwner,
        allocator: std.mem.Allocator,
        transport: metask.Transport,
        now_unix_seconds: i64,
        control: ?metask.RequestControl,
        expected_identity: ?state.AccountIdentity,
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
        errdefer refreshed.deinit();
        const identity = if (expected_identity) |expected| identity: {
            const remote = try metask.fetchIdentity(
                transport,
                &refreshed,
                control,
            );
            break :identity state.AccountIdentity.init(
                if (refreshed.accountId().len > 0)
                    remote.accountId()
                else
                    expected.accountId(),
                remote.profileId(),
                remote.displayName(),
            ) catch return error.ProtocolInvalid;
        } else null;
        return .{
            .tokens = refreshed.take(),
            .identity = identity,
        };
    }

    pub fn loadApiKeys(
        self: *const CredentialOwner,
        session: *catalog.CatalogSession,
        transport: metask.Transport,
        identity: state.AccountIdentity,
        control: ?metask.RequestControl,
    ) catalog.Error!void {
        const current = if (self.tokens) |*value|
            value
        else
            return error.Unauthorized;
        try session.loadApiKeys(
            transport,
            current.access_token.view(),
            identity.accountId(),
            identity.profileId(),
            control,
        );
    }

    pub fn clear(self: *CredentialOwner) void {
        if (self.tokens) |*current| current.deinit();
        self.tokens = null;
        if (self.stored_refresh_token) |*current| current.deinit();
        self.stored_refresh_token = null;
    }

    pub fn setCleanupPending(
        self: *CredentialOwner,
        pending: bool,
    ) void {
        self.cleanup_pending = pending;
    }

    pub fn cleanupPending(self: *const CredentialOwner) bool {
        return self.cleanup_pending;
    }

    pub fn deinit(self: *CredentialOwner) void {
        self.clear();
        self.cleanup_pending = false;
    }
};

test "CredentialOwner replaces and clears OAuth secret ownership" {
    var first = try oauth.TokenSet.fromStored(
        std.testing.allocator,
        "access-1",
        "refresh-1",
        10,
        oauth.scope,
        "account-1",
    );
    defer first.deinit();
    var second = try oauth.TokenSet.fromStored(
        std.testing.allocator,
        "access-2",
        "refresh-2",
        20,
        oauth.scope,
        "account-1",
    );
    defer second.deinit();
    var owner: CredentialOwner = .{};
    defer owner.deinit();

    owner.replace(&first);
    try std.testing.expect(owner.available());
    owner.replace(&second);
    try std.testing.expect(owner.available());
    owner.setCleanupPending(true);
    try std.testing.expect(owner.cleanupPending());
    owner.clear();
    try std.testing.expect(!owner.available());
}

test "CredentialOwner can restore a refresh-only Windows session" {
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
