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
                .load_preference_fn = loadPreference,
                .commit_preference_fn = commitPreference,
                .delete_preference_fn = deletePreference,
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

    fn loadPreference(context: *anyopaque) store.StoreError!?store.Preference {
        const self: *Adapter = @ptrCast(@alignCast(context));
        self.assertMainThread() catch return error.ReadFailed;
        var file = self.account_dir.openFile(
            self.io,
            store.preference_name,
            .{ .follow_symlinks = false },
        ) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return error.ReadFailed,
        };
        if (builtin.os.tag == .windows) file.flags.nonblocking = true;
        defer file.close(self.io);
        const length = file.length(self.io) catch return error.ReadFailed;
        if (length == 0 or length > store.preference_bytes)
            return error.InvalidData;
        var bytes: [store.preference_bytes]u8 = undefined;
        const read = file.readPositionalAll(
            self.io,
            bytes[0..@intCast(length)],
            0,
        ) catch return error.ReadFailed;
        if (read != length) return error.ReadFailed;
        return @as(?store.Preference, try store.decodePreference(bytes[0..read]));
    }

    fn commitPreference(
        context: *anyopaque,
        value: store.Preference,
    ) store.StoreError!void {
        const self: *Adapter = @ptrCast(@alignCast(context));
        self.assertMainThread() catch return error.WriteFailed;
        var encoded_storage: [store.preference_bytes]u8 = undefined;
        const encoded = store.encodePreference(&encoded_storage, value) catch
            return error.InvalidData;
        var random: [8]u8 = undefined;
        defer std.crypto.secureZero(u8, &random);
        std.Io.randomSecure(self.io, &random) catch return error.WriteFailed;
        const random_hex = std.fmt.bytesToHex(random, .lower);
        var temp_name_storage: [64]u8 = undefined;
        var name_writer = std.Io.Writer.fixed(&temp_name_storage);
        name_writer.print(
            ".preferences.{s}.tmp",
            .{random_hex},
        ) catch return error.WriteFailed;
        const temp_name = name_writer.buffered();
        const file = self.account_dir.createFile(
            self.io,
            temp_name,
            .{
                .exclusive = true,
                .permissions = privateFilePermissions(),
                .resolve_beneath = true,
            },
        ) catch return error.WriteFailed;
        var file_open = true;
        var temp_exists = true;
        defer {
            if (file_open) file.close(self.io);
            if (temp_exists) self.account_dir.deleteFile(
                self.io,
                temp_name,
            ) catch {};
        }
        file.writeStreamingAll(self.io, encoded) catch
            return error.WriteFailed;
        file.sync(self.io) catch return error.WriteFailed;
        file.close(self.io);
        file_open = false;
        self.account_dir.rename(
            temp_name,
            self.account_dir,
            store.preference_name,
            self.io,
        ) catch return error.WriteFailed;
        temp_exists = false;
        if (!self.syncPreferenceCommit())
            return error.PersistenceOutcomeUnknown;
    }

    fn deletePreference(context: *anyopaque) store.StoreError!void {
        const self: *Adapter = @ptrCast(@alignCast(context));
        self.assertMainThread() catch return error.DeleteFailed;
        self.account_dir.deleteFile(
            self.io,
            store.preference_name,
        ) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return error.DeleteFailed,
        };
    }

    fn syncPreferenceCommit(self: *Adapter) bool {
        if (builtin.os.tag == .windows) {
            var preference = self.account_dir.openFile(
                self.io,
                store.preference_name,
                .{
                    .mode = .read_write,
                    .allow_directory = false,
                    .follow_symlinks = false,
                    .resolve_beneath = true,
                },
            ) catch return false;
            preference.flags.nonblocking = true;
            defer preference.close(self.io);
            preference.sync(self.io) catch return false;
            return true;
        }
        const directory_file: std.Io.File = .{
            .handle = self.account_dir.handle,
            .flags = .{ .nonblocking = false },
        };
        directory_file.sync(self.io) catch return false;
        return true;
    }
};

fn directoryPermissions() std.Io.File.Permissions {
    return if (builtin.os.tag == .windows)
        .default_dir
    else
        .fromMode(0o700);
}

fn privateFilePermissions() std.Io.File.Permissions {
    return if (builtin.os.tag == .windows)
        .default_file
    else
        .fromMode(0o600);
}
