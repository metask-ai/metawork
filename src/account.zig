const std = @import("std");
const state_impl = @import("account_state");
const inbox_impl = @import("account_completion_inbox");
const oauth_impl = @import("account_oauth");
const metask_client_impl = @import("metask_client");
const credential_store_impl = @import("account_credential_store");
const platform_impl = @import("account_platform");
const loopback_impl = @import("account_loopback");
const login_attempt_impl = @import("account_login_attempt");
const catalog_impl = @import("account_catalog");

pub const Account = state_impl.Account;
pub const AccountIdentity = state_impl.AccountIdentity;
pub const CompletionInbox = inbox_impl.CompletionInbox;
pub const Effect = state_impl.Effect;
pub const EffectSink = state_impl.EffectSink;
pub const PrepareResult = state_impl.PrepareResult;
pub const PreparedTransition = state_impl.PreparedTransition;
pub const PublishResult = inbox_impl.PublishResult;
pub const RestoreReady = state_impl.RestoreReady;
pub const RestoreAccountOnly = state_impl.RestoreAccountOnly;
pub const RestoreResult = state_impl.RestoreResult;
pub const RestoreSignedOut = state_impl.RestoreSignedOut;
pub const WakeSink = inbox_impl.WakeSink;
pub const WorkerCompletion = state_impl.WorkerCompletion;
pub const WorkerFailure = state_impl.WorkerFailure;
pub const OAuth = oauth_impl;
pub const MetaskClient = metask_client_impl;
pub const CredentialStore = credential_store_impl;
pub const Platform = platform_impl;
pub const Loopback = loopback_impl;
pub const LoginAttempt = login_attempt_impl;
pub const Catalog = catalog_impl;

/// Concrete Account-owned secret lifetime. App may compose this owner and
/// coordinate commits, but it never receives a borrowed token slice or takes
/// over the underlying allocations.
pub const CredentialOwner = struct {
    tokens: ?oauth_impl.TokenSet = null,
    cleanup_pending: bool = false,

    pub fn replace(
        self: *CredentialOwner,
        tokens: *oauth_impl.TokenSet,
    ) void {
        self.clear();
        self.tokens = tokens.take();
    }

    pub fn clear(self: *CredentialOwner) void {
        if (self.tokens) |*tokens| tokens.deinit();
        self.tokens = null;
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

test {
    _ = state_impl;
    _ = inbox_impl;
    _ = oauth_impl;
    _ = metask_client_impl;
    _ = credential_store_impl;
    _ = platform_impl;
    _ = loopback_impl;
    _ = login_attempt_impl;
    _ = catalog_impl;
}

test "CredentialOwner replaces and clears OAuth secret ownership" {
    var first = try oauth_impl.TokenSet.fromStored(
        std.testing.allocator,
        "access-1",
        "refresh-1",
        10,
        oauth_impl.scope,
        "account-1",
    );
    defer first.deinit();
    var second = try oauth_impl.TokenSet.fromStored(
        std.testing.allocator,
        "access-2",
        "refresh-2",
        20,
        oauth_impl.scope,
        "account-1",
    );
    defer second.deinit();
    var owner: CredentialOwner = .{};
    defer owner.deinit();

    owner.replace(&first);
    try std.testing.expect(owner.tokens != null);
    owner.replace(&second);
    try std.testing.expect(owner.tokens != null);
    owner.setCleanupPending(true);
    try std.testing.expect(owner.cleanupPending());
    owner.clear();
    try std.testing.expect(owner.tokens == null);
}
