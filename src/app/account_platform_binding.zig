const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const ports_api = @import("account_ports");
const store = @import("account_credential_store");

pub const InitError = error{
    WrongThread,
    AccountDirectoryUnavailable,
};

/// Application-owned binding for the platform effects required by Account.
/// Account owns the policy and transaction boundaries exposed by `ports.zig`;
/// this adapter only executes Native SDK and filesystem mechanics.
pub const Adapter = struct {
    services: native_sdk.platform.PlatformServices,
    io: std.Io,
    main_thread_id: std.Thread.Id,
    account_dir: std.Io.Dir,

    pub fn init(
        services: native_sdk.platform.PlatformServices,
        io: std.Io,
        main_thread_id: std.Thread.Id,
        absolute_account_dir: []const u8,
    ) (InitError || store.StoreError)!Adapter {
        if (std.Thread.getCurrentId() != main_thread_id)
            return error.WrongThread;
        if (!std.fs.path.isAbsolute(absolute_account_dir))
            return error.AccountDirectoryUnavailable;
        const dir = std.Io.Dir.cwd().createDirPathOpen(
            io,
            absolute_account_dir,
            .{
                .open_options = .{ .follow_symlinks = false },
                .permissions = directoryPermissions(),
            },
        ) catch return error.AccountDirectoryUnavailable;
        return .{
            .services = services,
            .io = io,
            .main_thread_id = main_thread_id,
            .account_dir = dir,
        };
    }

    pub fn deinit(self: *Adapter) void {
        self.assertMainThread() catch @panic(
            "Account platform binding released off main thread",
        );
        self.account_dir.close(self.io);
        self.* = undefined;
    }

    pub fn ports(self: *Adapter) ports_api.Platform {
        return .{
            .credentials = .{
                .context = self,
                .set_refresh_token_fn = setRefreshToken,
                .get_refresh_token_fn = getRefreshToken,
                .delete_refresh_token_fn = deleteRefreshToken,
            },
            .authorization_url = .{
                .context = self,
                .open_fn = openAuthorizationUrl,
            },
            .timer = .{
                .context = self,
                .start_fn = startTimer,
                .cancel_fn = cancelTimer,
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
};

fn directoryPermissions() std.Io.File.Permissions {
    return if (builtin.os.tag == .windows)
        .default_dir
    else
        .fromMode(0o700);
}
