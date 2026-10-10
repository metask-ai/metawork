const std = @import("std");
const native_sdk = @import("native_sdk");
const ports_api = @import("account_ports");
const store = @import("account_credential_store");

pub const InitError = error{
    WrongThread,
};

/// Application-owned binding for the platform effects required by Account.
/// Account owns the policy and transaction boundaries exposed by `ports.zig`;
/// this adapter only executes Native SDK and filesystem mechanics.
pub const Adapter = struct {
    services: native_sdk.platform.PlatformServices,
    io: std.Io,
    main_thread_id: std.Thread.Id,

    pub fn init(
        services: native_sdk.platform.PlatformServices,
        io: std.Io,
        main_thread_id: std.Thread.Id,
    ) InitError!Adapter {
        if (std.Thread.getCurrentId() != main_thread_id)
            return error.WrongThread;
        return .{
            .services = services,
            .io = io,
            .main_thread_id = main_thread_id,
        };
    }

    pub fn deinit(self: *Adapter) void {
        self.assertMainThread() catch @panic(
            "Account platform binding released off main thread",
        );
        self.* = undefined;
    }

    pub fn ports(self: *Adapter) ports_api.Platform {
        return .{
            .credentials = .{
                .context = self,
                .set_refresh_token_fn = setRefreshToken,
                .get_refresh_token_fn = getRefreshToken,
                .delete_refresh_token_fn = deleteRefreshToken,
                .set_refresh_marker_fn = setRefreshMarker,
                .get_refresh_marker_fn = getRefreshMarker,
                .delete_refresh_marker_fn = deleteRefreshMarker,
            },
            .authorization_url = .{
                .context = self,
                .open_fn = openAuthorizationUrl,
            },
            .recharge_page = .{
                .context = self,
                .open_fn = openRechargePage,
            },
            .timer = .{
                .context = self,
                .start_fn = startTimer,
                .cancel_fn = cancelTimer,
            },
            .wall_clock = .{
                .context = self,
                .now_unix_seconds_fn = nowUnixSeconds,
            },
        };
    }

    fn assertMainThread(self: *const Adapter) InitError!void {
        if (std.Thread.getCurrentId() != self.main_thread_id)
            return error.WrongThread;
    }

    fn openAuthorizationUrl(context: *anyopaque, url: []const u8) !void {
        const self: *Adapter = @ptrCast(@alignCast(context));
        try self.assertMainThread();
        try self.services.openExternalUrl(url);
    }

    fn openRechargePage(context: *anyopaque, url: []const u8) !void {
        const self: *Adapter = @ptrCast(@alignCast(context));
        try self.assertMainThread();
        try self.services.openExternalUrl(url);
    }

    fn startTimer(
        context: *anyopaque,
        timer_id: u64,
        interval_ns: u64,
        repeats: bool,
    ) !void {
        const self: *Adapter = @ptrCast(@alignCast(context));
        try self.assertMainThread();
        try self.services.startTimer(timer_id, interval_ns, repeats);
    }

    fn cancelTimer(context: *anyopaque, timer_id: u64) !void {
        const self: *Adapter = @ptrCast(@alignCast(context));
        try self.assertMainThread();
        try self.services.cancelTimer(timer_id);
    }

    fn nowUnixSeconds(context: *anyopaque) ?i64 {
        const self: *Adapter = @ptrCast(@alignCast(context));
        self.assertMainThread() catch return null;
        const nanoseconds = std.Io.Timestamp.now(self.io, .real).nanoseconds;
        if (nanoseconds < 0) return null;
        const seconds = @divFloor(nanoseconds, std.time.ns_per_s);
        if (seconds > std.math.maxInt(i64)) return null;
        return @intCast(seconds);
    }

    fn setRefreshToken(
        context: *anyopaque,
        secret_value: []const u8,
    ) store.StoreError!void {
        const self: *Adapter = @ptrCast(@alignCast(context));
        self.assertMainThread() catch return error.WriteFailed;
        if (secret_value.len == 0 or
            secret_value.len > native_sdk.platform.max_credential_secret_bytes)
            return error.WriteFailed;
        self.services.setCredential(.{
            .service = store.service,
            .account = store.refresh_token_account,
            .secret = secret_value,
        }) catch return error.WriteFailed;
    }

    fn getRefreshToken(
        context: *anyopaque,
        output: []u8,
    ) store.StoreError!?[]const u8 {
        const self: *Adapter = @ptrCast(@alignCast(context));
        self.assertMainThread() catch return error.ReadFailed;
        return self.services.getCredential(.{
            .service = store.service,
            .account = store.refresh_token_account,
        }, output) catch |err| switch (err) {
            error.CredentialNotFound => null,
            else => error.ReadFailed,
        };
    }

    fn deleteRefreshToken(context: *anyopaque) store.StoreError!void {
        const self: *Adapter = @ptrCast(@alignCast(context));
        self.assertMainThread() catch return error.DeleteFailed;
        self.services.deleteCredential(.{
            .service = store.service,
            .account = store.refresh_token_account,
        }) catch |err| switch (err) {
            error.CredentialNotFound => {},
            else => return error.DeleteFailed,
        };
    }
    fn setRefreshMarker(context: *anyopaque, value: []const u8) store.StoreError!void {
        const self: *Adapter = @ptrCast(@alignCast(context));
        self.assertMainThread() catch return error.WriteFailed;
        if (value.len != store.marker_bytes) return error.WriteFailed;
        self.services.setCredential(.{
            .service = store.service,
            .account = store.refresh_in_flight_account,
            .secret = value,
        }) catch return error.WriteFailed;
    }

    fn getRefreshMarker(context: *anyopaque, output: []u8) store.StoreError!?[]const u8 {
        const self: *Adapter = @ptrCast(@alignCast(context));
        self.assertMainThread() catch return error.ReadFailed;
        return self.services.getCredential(.{
            .service = store.service,
            .account = store.refresh_in_flight_account,
        }, output) catch |err| switch (err) {
            error.CredentialNotFound => null,
            else => error.ReadFailed,
        };
    }

    fn deleteRefreshMarker(context: *anyopaque) store.StoreError!void {
        const self: *Adapter = @ptrCast(@alignCast(context));
        self.assertMainThread() catch return error.DeleteFailed;
        self.services.deleteCredential(.{
            .service = store.service,
            .account = store.refresh_in_flight_account,
        }) catch |err| switch (err) {
            error.CredentialNotFound => {},
            else => return error.DeleteFailed,
        };
    }
};
