//! Product Account effect ports.
const std = @import("std");
const oauth = @import("account_oauth");
const credential_store = @import("account_credential_store");
const contract = @import("metawork_account_contract");

pub const AuthorizationUrl = struct {
    context: *anyopaque,
    open_fn: *const fn (*anyopaque, []const u8) anyerror!void,

    pub fn open(self: AuthorizationUrl, url: []const u8) !void {
        if (url.len == 0 or
            url.len > oauth.Limits.authorization_url_bytes or
            !std.mem.startsWith(u8, url, oauth.authorize_url ++ "?"))
            return error.InvalidAuthorizationUrl;
        try self.open_fn(self.context, url);
    }
};

pub const RechargePage = struct {
    context: *anyopaque,
    open_fn: *const fn (*anyopaque, []const u8) anyerror!void,

    pub fn open(self: RechargePage) !void {
        try self.open_fn(self.context, contract.recharge_page_url);
    }
};

pub const Timer = struct {
    context: *anyopaque,
    start_fn: *const fn (*anyopaque, u64, u64, bool) anyerror!void,
    cancel_fn: *const fn (*anyopaque, u64) anyerror!void,

    pub fn start(
        self: Timer,
        timer_id: u64,
        interval_ns: u64,
        repeats: bool,
    ) !void {
        try self.start_fn(self.context, timer_id, interval_ns, repeats);
    }

    pub fn cancel(self: Timer, timer_id: u64) !void {
        try self.cancel_fn(self.context, timer_id);
    }
};

pub const WallClock = struct {
    context: *anyopaque,
    now_unix_seconds_fn: *const fn (*anyopaque) ?i64,

    pub fn nowUnixSeconds(self: WallClock) ?i64 {
        return self.now_unix_seconds_fn(self.context);
    }
};

pub const Platform = struct {
    credentials: credential_store.Backend,
    authorization_url: AuthorizationUrl,
    recharge_page: RechargePage,
    timer: Timer,
    wall_clock: WallClock,
};
