const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const oauth = @import("account_oauth");
const store = @import("account_credential_store");

const preference_bytes = 8 * 1024;

pub const Services = native_sdk.platform.PlatformServices;

pub const PlatformError = error{
    WrongThread,
    InvalidAuthorizationUrl,
    AccountDirectoryUnavailable,
};

/// One platform adapter backs the same Account persistence contract on every
/// desktop OS: one secure refresh token and one atomic non-secret preference.
pub const NativeBackend = struct {
    services: Services,
    io: std.Io,
    main_thread_id: std.Thread.Id,
    account_dir: std.Io.Dir,

    pub fn init(
        services: Services,
        io: std.Io,
        main_thread_id: std.Thread.Id,
        absolute_account_dir: []const u8,
    ) (PlatformError || store.StoreError)!NativeBackend {
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

    pub fn deinit(self: *NativeBackend) void {
        self.assertMainThread() catch @panic(
            "Account platform released off main thread",
        );
        self.account_dir.close(self.io);
        self.* = undefined;
    }

    pub fn backend(self: *NativeBackend) store.Backend {
        return .{
            .context = self,
            .set_refresh_token_fn = setRefreshToken,
            .get_refresh_token_fn = getRefreshToken,
            .delete_refresh_token_fn = deleteRefreshToken,
            .load_preference_fn = loadPreference,
            .commit_preference_fn = commitPreference,
            .delete_preference_fn = deletePreference,
        };
    }

    pub fn openAuthorizationUrl(
        self: *NativeBackend,
        url: []const u8,
    ) PlatformError!void {
        try self.assertMainThread();
        if (url.len == 0 or
            url.len > oauth.Limits.authorization_url_bytes or
            !std.mem.startsWith(u8, url, oauth.authorize_url ++ "?"))
            return error.InvalidAuthorizationUrl;
        self.services.openExternalUrl(url) catch
            return error.InvalidAuthorizationUrl;
    }

    fn assertMainThread(self: *const NativeBackend) PlatformError!void {
        if (std.Thread.getCurrentId() != self.main_thread_id)
            return error.WrongThread;
    }

    fn setRefreshToken(
        context: *anyopaque,
        secret_value: []const u8,
    ) store.StoreError!void {
        const self: *NativeBackend = @ptrCast(@alignCast(context));
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
        const self: *NativeBackend = @ptrCast(@alignCast(context));
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
        const self: *NativeBackend = @ptrCast(@alignCast(context));
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
        const self: *NativeBackend = @ptrCast(@alignCast(context));
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
        if (length == 0 or length > preference_bytes)
            return error.InvalidData;
        var bytes: [preference_bytes]u8 = undefined;
        const read = file.readPositionalAll(
            self.io,
            bytes[0..@intCast(length)],
            0,
        ) catch return error.ReadFailed;
        if (read != length) return error.ReadFailed;
        return try decodePreference(bytes[0..read]);
    }

    fn commitPreference(
        context: *anyopaque,
        value: store.Preference,
    ) store.StoreError!void {
        const self: *NativeBackend = @ptrCast(@alignCast(context));
        self.assertMainThread() catch return error.WriteFailed;
        var encoded_storage: [preference_bytes]u8 = undefined;
        const encoded = encodePreference(&encoded_storage, value) catch
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
        const self: *NativeBackend = @ptrCast(@alignCast(context));
        self.assertMainThread() catch return error.DeleteFailed;
        self.account_dir.deleteFile(
            self.io,
            store.preference_name,
        ) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return error.DeleteFailed,
        };
    }

    fn syncPreferenceCommit(self: *NativeBackend) bool {
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

pub fn startTimer(
    backend: *NativeBackend,
    timer_id: u64,
    interval_ns: u64,
    repeats: bool,
) !void {
    try backend.assertMainThread();
    try backend.services.startTimer(timer_id, interval_ns, repeats);
}

pub fn cancelTimer(backend: *NativeBackend, timer_id: u64) !void {
    try backend.assertMainThread();
    try backend.services.cancelTimer(timer_id);
}

const PreferenceWire = struct {
    selection_owner_account_id: []const u8,
    api_key_id: []const u8,
    model_id: []const u8,
    execution_generation: u64,
};

pub fn encodePreference(
    output: []u8,
    preference: store.Preference,
) ![]const u8 {
    try preference.validate();
    const wire: PreferenceWire = .{
        .selection_owner_account_id = preference.ownerAccountId(),
        .api_key_id = preference.apiKeyId(),
        .model_id = preference.modelId(),
        .execution_generation = preference.execution_generation,
    };
    var writer = std.Io.Writer.fixed(output);
    try std.json.Stringify.value(wire, .{}, &writer);
    return writer.buffered();
}

pub fn decodePreference(input: []const u8) store.StoreError!store.Preference {
    if (input.len == 0 or input.len > preference_bytes)
        return error.InvalidData;
    var scratch: [preference_bytes * 2]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    var parsed = std.json.parseFromSlice(
        PreferenceWire,
        fba.allocator(),
        input,
        .{ .ignore_unknown_fields = false },
    ) catch return error.InvalidData;
    defer parsed.deinit();
    return store.Preference.init(
        parsed.value.selection_owner_account_id,
        parsed.value.api_key_id,
        parsed.value.model_id,
        parsed.value.execution_generation,
    );
}

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

test "preference codec is strict, unversioned, and secret-free" {
    const value = try store.Preference.init(
        "account-1",
        "api-1",
        "model-1",
        9,
    );
    var bytes: [preference_bytes]u8 = undefined;
    const encoded = try encodePreference(&bytes, value);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "account-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "refresh") == null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "schema") == null);
    const decoded = try decodePreference(encoded);
    try std.testing.expectEqualStrings("account-1", decoded.ownerAccountId());
    try std.testing.expectEqualStrings("api-1", decoded.apiKeyId());
    try std.testing.expectEqualStrings("model-1", decoded.modelId());
    try std.testing.expectEqual(@as(u64, 9), decoded.execution_generation);
}

test "preference codec rejects unknown fields and zero generation" {
    try std.testing.expectError(
        error.InvalidData,
        decodePreference(
            "{\"selection_owner_account_id\":\"account-1\",\"api_key_id\":\"api-1\",\"model_id\":\"model-1\",\"execution_generation\":1,\"schema\":1}",
        ),
    );
    try std.testing.expectError(
        error.InvalidData,
        decodePreference(
            "{\"selection_owner_account_id\":\"account-1\",\"api_key_id\":\"api-1\",\"model_id\":\"model-1\",\"execution_generation\":0}",
        ),
    );
}
