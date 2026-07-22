const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const oauth = @import("account_oauth");
const account_state = @import("account_state");
const store = @import("account_credential_store");
const windows_store = @import("account_windows_store");

const manifest_name = store.manifest_name;
// The contract bounds UTF-8 source bytes, while JSON may expand one byte into
// a six-byte escape. Keep the persisted envelope large enough for every
// contract-valid manifest, not only ordinary production identifiers.
const manifest_bytes = 16 * 1024;
const public_state_bytes = 8 * 1024;

pub const PlatformError = error{
    WrongThread,
    InvalidAuthorizationUrl,
    AccountDirectoryUnavailable,
};

pub const MacosBackend = struct {
    services: native_sdk.platform.PlatformServices,
    io: std.Io,
    main_thread_id: std.Thread.Id,
    account_dir: std.Io.Dir,

    pub fn init(
        services: native_sdk.platform.PlatformServices,
        io: std.Io,
        main_thread_id: std.Thread.Id,
        absolute_account_dir: []const u8,
    ) (PlatformError || store.StoreError)!MacosBackend {
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

    pub fn deinit(self: *MacosBackend) void {
        self.assertMainThread() catch @panic("Account platform released off main thread");
        self.account_dir.close(self.io);
        self.* = undefined;
    }

    pub fn backend(self: *MacosBackend) store.Backend {
        return .{
            .context = self,
            .set_fn = setCredential,
            .get_fn = getCredential,
            .delete_fn = deleteCredential,
            .load_manifest_fn = loadManifest,
            .commit_manifest_fn = commitManifest,
        };
    }

    pub fn openAuthorizationUrl(
        self: *MacosBackend,
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

    fn assertMainThread(self: *const MacosBackend) PlatformError!void {
        if (std.Thread.getCurrentId() != self.main_thread_id)
            return error.WrongThread;
    }

    fn setCredential(
        context: *anyopaque,
        key: store.CredentialKey,
        secret_value: []const u8,
    ) store.StoreError!void {
        const self: *MacosBackend = @ptrCast(@alignCast(context));
        self.assertMainThread() catch return error.WriteFailed;
        if (secret_value.len == 0 or
            secret_value.len > native_sdk.platform.max_credential_secret_bytes)
            return error.WriteFailed;
        self.services.setCredential(.{
            .service = store.service,
            .account = key.account(),
            .secret = secret_value,
        }) catch return error.WriteFailed;
    }

    fn getCredential(
        context: *anyopaque,
        key: store.CredentialKey,
        output: []u8,
    ) store.StoreError!?[]const u8 {
        const self: *MacosBackend = @ptrCast(@alignCast(context));
        self.assertMainThread() catch return error.ReadFailed;
        return self.services.getCredential(.{
            .service = store.service,
            .account = key.account(),
        }, output) catch |err| switch (err) {
            error.CredentialNotFound => null,
            else => error.ReadFailed,
        };
    }

    fn deleteCredential(
        context: *anyopaque,
        key: store.CredentialKey,
    ) store.StoreError!void {
        const self: *MacosBackend = @ptrCast(@alignCast(context));
        self.assertMainThread() catch return error.DeleteFailed;
        self.services.deleteCredential(.{
            .service = store.service,
            .account = key.account(),
        }) catch |err| switch (err) {
            error.CredentialNotFound => {},
            else => return error.DeleteFailed,
        };
    }

    fn loadManifest(context: *anyopaque) store.StoreError!?store.Manifest {
        const self: *MacosBackend = @ptrCast(@alignCast(context));
        self.assertMainThread() catch return error.ReadFailed;
        const file = self.account_dir.openFile(
            self.io,
            manifest_name,
            .{ .follow_symlinks = false },
        ) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return error.ReadFailed,
        };
        defer file.close(self.io);
        const length = file.length(self.io) catch return error.ReadFailed;
        if (length == 0 or length > manifest_bytes)
            return error.ManifestCorrupt;
        var bytes: [manifest_bytes]u8 = undefined;
        defer std.crypto.secureZero(u8, &bytes);
        const read = file.readPositionalAll(
            self.io,
            bytes[0..@intCast(length)],
            0,
        ) catch return error.ReadFailed;
        if (read != length) return error.ReadFailed;
        return @as(
            ?store.Manifest,
            try decodeManifest(bytes[0..read]),
        );
    }

    fn commitManifest(
        context: *anyopaque,
        manifest: store.Manifest,
    ) store.StoreError!void {
        const self: *MacosBackend = @ptrCast(@alignCast(context));
        self.assertMainThread() catch return error.WriteFailed;
        var encoded_storage: [manifest_bytes]u8 = undefined;
        defer std.crypto.secureZero(u8, &encoded_storage);
        const encoded = encodeManifest(
            &encoded_storage,
            manifest,
        ) catch return error.InvalidData;
        var random: [8]u8 = undefined;
        defer std.crypto.secureZero(u8, &random);
        std.Io.randomSecure(self.io, &random) catch return error.WriteFailed;
        const random_hex = std.fmt.bytesToHex(random, .lower);
        var temp_name_storage: [64]u8 = undefined;
        var name_writer = std.Io.Writer.fixed(&temp_name_storage);
        name_writer.print(
            ".manifest.{s}.tmp",
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
            manifest_name,
            self.io,
        ) catch return error.WriteFailed;
        temp_exists = false;
        if (!self.syncManifestCommit())
            return error.PersistenceOutcomeUnknown;
    }

    fn syncManifestCommit(self: *MacosBackend) bool {
        if (builtin.os.tag == .windows) {
            const manifest = self.account_dir.openFile(
                self.io,
                manifest_name,
                .{
                    .mode = .read_write,
                    .allow_directory = false,
                    .follow_symlinks = false,
                    .resolve_beneath = true,
                },
            ) catch return false;
            defer manifest.close(self.io);
            manifest.sync(self.io) catch return false;
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

/// Windows intentionally does not share the macOS manifest/A-B persistence
/// protocol. Credential Manager owns one refresh token; account.json contains
/// only secret-free identity and catalog selection.
pub const WindowsBackend = struct {
    services: native_sdk.platform.PlatformServices,
    io: std.Io,
    main_thread_id: std.Thread.Id,
    account_dir: std.Io.Dir,

    pub fn init(
        services: native_sdk.platform.PlatformServices,
        io: std.Io,
        main_thread_id: std.Thread.Id,
        absolute_account_dir: []const u8,
    ) (PlatformError || windows_store.StoreError)!WindowsBackend {
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

    pub fn deinit(self: *WindowsBackend) void {
        self.assertMainThread() catch @panic(
            "Account platform released off main thread",
        );
        self.account_dir.close(self.io);
        self.* = undefined;
    }

    pub fn backend(self: *WindowsBackend) windows_store.Backend {
        return .{
            .context = self,
            .set_refresh_token_fn = setRefreshToken,
            .get_refresh_token_fn = getRefreshToken,
            .delete_refresh_token_fn = deleteRefreshToken,
            .load_public_state_fn = loadPublicState,
            .commit_public_state_fn = commitPublicState,
            .delete_public_state_fn = deletePublicState,
        };
    }

    pub fn openAuthorizationUrl(
        self: *WindowsBackend,
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

    fn assertMainThread(self: *const WindowsBackend) PlatformError!void {
        if (std.Thread.getCurrentId() != self.main_thread_id)
            return error.WrongThread;
    }

    fn setRefreshToken(
        context: *anyopaque,
        secret_value: []const u8,
    ) windows_store.StoreError!void {
        const self: *WindowsBackend = @ptrCast(@alignCast(context));
        self.assertMainThread() catch return error.WriteFailed;
        if (secret_value.len == 0 or
            secret_value.len > native_sdk.platform.max_credential_secret_bytes)
            return error.WriteFailed;
        self.services.setCredential(.{
            .service = windows_store.service,
            .account = windows_store.refresh_token_account,
            .secret = secret_value,
        }) catch return error.WriteFailed;
    }

    fn getRefreshToken(
        context: *anyopaque,
        output: []u8,
    ) windows_store.StoreError!?[]const u8 {
        const self: *WindowsBackend = @ptrCast(@alignCast(context));
        self.assertMainThread() catch return error.ReadFailed;
        return self.services.getCredential(.{
            .service = windows_store.service,
            .account = windows_store.refresh_token_account,
        }, output) catch |err| switch (err) {
            error.CredentialNotFound => null,
            else => error.ReadFailed,
        };
    }

    fn deleteRefreshToken(
        context: *anyopaque,
    ) windows_store.StoreError!void {
        const self: *WindowsBackend = @ptrCast(@alignCast(context));
        self.assertMainThread() catch return error.DeleteFailed;
        self.services.deleteCredential(.{
            .service = windows_store.service,
            .account = windows_store.refresh_token_account,
        }) catch |err| switch (err) {
            error.CredentialNotFound => {},
            else => return error.DeleteFailed,
        };
    }

    fn loadPublicState(
        context: *anyopaque,
    ) windows_store.StoreError!?windows_store.PublicState {
        const self: *WindowsBackend = @ptrCast(@alignCast(context));
        self.assertMainThread() catch return error.ReadFailed;
        var file = self.account_dir.openFile(
            self.io,
            windows_store.public_state_name,
            .{ .follow_symlinks = false },
        ) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return error.ReadFailed,
        };
        // Zig 0.16 opens a no-follow Windows file asynchronously but currently
        // mislabels the returned handle as synchronous. Correct the flag so
        // std.Io uses its APC path instead of treating STATUS_PENDING as an
        // impossible state.
        file.flags.nonblocking = true;
        defer file.close(self.io);
        const length = file.length(self.io) catch return error.ReadFailed;
        if (length == 0 or length > public_state_bytes)
            return error.InvalidData;
        var bytes: [public_state_bytes]u8 = undefined;
        const read = file.readPositionalAll(
            self.io,
            bytes[0..@intCast(length)],
            0,
        ) catch return error.ReadFailed;
        if (read != length) return error.ReadFailed;
        return try decodeWindowsPublicState(bytes[0..read]);
    }

    fn commitPublicState(
        context: *anyopaque,
        value: windows_store.PublicState,
    ) windows_store.StoreError!void {
        const self: *WindowsBackend = @ptrCast(@alignCast(context));
        self.assertMainThread() catch return error.WriteFailed;
        var encoded_storage: [public_state_bytes]u8 = undefined;
        const encoded = encodeWindowsPublicState(
            &encoded_storage,
            value,
        ) catch return error.InvalidData;
        var random: [8]u8 = undefined;
        defer std.crypto.secureZero(u8, &random);
        std.Io.randomSecure(self.io, &random) catch return error.WriteFailed;
        const random_hex = std.fmt.bytesToHex(random, .lower);
        var temp_name_storage: [64]u8 = undefined;
        var name_writer = std.Io.Writer.fixed(&temp_name_storage);
        name_writer.print(
            ".account.{s}.tmp",
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
            windows_store.public_state_name,
            self.io,
        ) catch return error.WriteFailed;
        temp_exists = false;
    }

    fn deletePublicState(
        context: *anyopaque,
    ) windows_store.StoreError!void {
        const self: *WindowsBackend = @ptrCast(@alignCast(context));
        self.assertMainThread() catch return error.DeleteFailed;
        self.account_dir.deleteFile(
            self.io,
            windows_store.public_state_name,
        ) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return error.DeleteFailed,
        };
    }
};

pub const NativeBackend = if (builtin.os.tag == .windows)
    WindowsBackend
else
    MacosBackend;

const WindowsPublicStateWire = struct {
    account_id: []const u8,
    profile_id: []const u8,
    display_name: []const u8,
    api_key_id: ?[]const u8,
    model_id: ?[]const u8,
};

pub fn encodeWindowsPublicState(
    output: []u8,
    value: windows_store.PublicState,
) ![]const u8 {
    _ = try value.identity();
    if ((value.apiKeyId().len == 0) != (value.modelId().len == 0))
        return error.InvalidData;
    const wire: WindowsPublicStateWire = .{
        .account_id = value.account_id.view(),
        .profile_id = value.profile_id.view(),
        .display_name = value.display_name.view(),
        .api_key_id = if (value.apiKeyId().len == 0)
            null
        else
            value.apiKeyId(),
        .model_id = if (value.modelId().len == 0)
            null
        else
            value.modelId(),
    };
    var writer = std.Io.Writer.fixed(output);
    try std.json.Stringify.value(wire, .{}, &writer);
    return writer.buffered();
}

pub fn decodeWindowsPublicState(
    input: []const u8,
) windows_store.StoreError!windows_store.PublicState {
    if (input.len == 0 or input.len > public_state_bytes)
        return error.InvalidData;
    var scratch: [public_state_bytes * 2]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    var parsed = std.json.parseFromSlice(
        WindowsPublicStateWire,
        fba.allocator(),
        input,
        .{ .ignore_unknown_fields = false },
    ) catch return error.InvalidData;
    defer parsed.deinit();
    if ((parsed.value.api_key_id == null) !=
        (parsed.value.model_id == null)) return error.InvalidData;
    const identity = account_state.AccountIdentity.init(
        parsed.value.account_id,
        parsed.value.profile_id,
        parsed.value.display_name,
    ) catch return error.InvalidData;
    return windows_store.PublicState.init(
        identity,
        parsed.value.api_key_id orelse "",
        parsed.value.model_id orelse "",
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

const ManifestWire = struct {
    version: u8,
    state: []const u8,
    active_slot: ?[]const u8,
    generation: ?[]const u8,
    expires_at: i64,
    scope: ?[]const u8,
    account_id: ?[]const u8,
    profile_id: ?[]const u8,
    display_name: ?[]const u8,
    execution_slot: ?[]const u8,
    execution_credential_generation: ?[]const u8,
    api_key_id: ?[]const u8,
    provider_kind: ?[]const u8,
    model: ?[]const u8,
    base_url: ?[]const u8,
    execution_generation: u64,
    execution_high_watermark: u64,
};

pub fn encodeManifest(
    output: []u8,
    manifest: store.Manifest,
) ![]const u8 {
    try manifest.validate();
    const generation_hex = std.fmt.bytesToHex(manifest.generation, .lower);
    const execution_generation_hex = std.fmt.bytesToHex(
        manifest.execution_credential_generation,
        .lower,
    );
    const wire: ManifestWire = .{
        .version = manifest.version,
        .state = @tagName(manifest.state),
        .active_slot = if (manifest.active_slot) |slot| @tagName(slot) else null,
        .generation = if (manifest.active_slot != null) &generation_hex else null,
        .expires_at = manifest.expires_at,
        .scope = if (manifest.scope_len > 0) manifest.scopeView() else null,
        .account_id = if (manifest.account_id_len > 0) manifest.accountId() else null,
        .profile_id = if (manifest.profile_id_len > 0) manifest.profileId() else null,
        .display_name = if (manifest.display_name_len > 0)
            manifest.displayName()
        else
            null,
        .execution_slot = if (manifest.execution_slot) |slot|
            @tagName(slot)
        else
            null,
        .execution_credential_generation = if (manifest.execution_slot != null)
            &execution_generation_hex
        else
            null,
        .api_key_id = if (manifest.api_key_id_len > 0)
            manifest.apiKeyId()
        else
            null,
        .provider_kind = if (manifest.provider_kind) |provider|
            @tagName(provider)
        else
            null,
        .model = if (manifest.model_len > 0) manifest.modelView() else null,
        .base_url = if (manifest.base_url_len > 0)
            manifest.baseUrl()
        else
            null,
        .execution_generation = manifest.execution_generation,
        .execution_high_watermark = manifest.execution_high_watermark,
    };
    var writer = std.Io.Writer.fixed(output);
    try std.json.Stringify.value(wire, .{}, &writer);
    return writer.buffered();
}

pub fn decodeManifest(input: []const u8) store.StoreError!store.Manifest {
    if (input.len == 0 or input.len > manifest_bytes)
        return error.ManifestCorrupt;
    var scratch: [manifest_bytes * 2]u8 = undefined;
    defer std.crypto.secureZero(u8, &scratch);
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    var parsed = std.json.parseFromSlice(
        ManifestWire,
        fba.allocator(),
        input,
        .{ .ignore_unknown_fields = false },
    ) catch return error.ManifestCorrupt;
    defer parsed.deinit();
    const wire = parsed.value;
    const manifest_state = std.meta.stringToEnum(
        store.ManifestState,
        wire.state,
    ) orelse return error.ManifestCorrupt;
    var result = if (manifest_state == .signed_out)
        store.Manifest.signedOut(wire.execution_high_watermark)
    else
        store.Manifest{
            .state = manifest_state,
            .execution_high_watermark = wire.execution_high_watermark,
        };
    result.version = wire.version;
    if (manifest_state == .signed_out) {
        if (wire.active_slot != null or wire.generation != null or
            wire.scope != null or wire.account_id != null or
            wire.profile_id != null or wire.display_name != null or
            wire.execution_slot != null or
            wire.execution_credential_generation != null or
            wire.api_key_id != null or wire.provider_kind != null or
            wire.model != null or wire.base_url != null or
            wire.expires_at != 0 or wire.execution_generation != 0)
            return error.ManifestCorrupt;
        try result.validate();
        return result;
    }

    result.active_slot = std.meta.stringToEnum(
        store.Slot,
        wire.active_slot orelse return error.ManifestCorrupt,
    ) orelse return error.ManifestCorrupt;
    const generation_text = wire.generation orelse
        return error.ManifestCorrupt;
    if (generation_text.len != result.generation.len * 2)
        return error.ManifestCorrupt;
    _ = std.fmt.hexToBytes(
        &result.generation,
        generation_text,
    ) catch return error.ManifestCorrupt;
    result.expires_at = wire.expires_at;
    const stored_scope = wire.scope orelse return error.ManifestCorrupt;
    const account_id = wire.account_id orelse return error.ManifestCorrupt;
    const profile_id = wire.profile_id orelse return error.ManifestCorrupt;
    const display_name = wire.display_name orelse return error.ManifestCorrupt;
    if (stored_scope.len > result.scope_value.len or
        account_id.len > result.account_id.len or
        profile_id.len > result.profile_id.len or
        display_name.len > result.display_name.len)
        return error.ManifestCorrupt;
    @memcpy(result.scope_value[0..stored_scope.len], stored_scope);
    result.scope_len = stored_scope.len;
    @memcpy(result.account_id[0..account_id.len], account_id);
    result.account_id_len = account_id.len;
    @memcpy(result.profile_id[0..profile_id.len], profile_id);
    result.profile_id_len = profile_id.len;
    @memcpy(result.display_name[0..display_name.len], display_name);
    result.display_name_len = display_name.len;
    if (manifest_state == .execution_ready) {
        result.execution_slot = std.meta.stringToEnum(
            store.Slot,
            wire.execution_slot orelse return error.ManifestCorrupt,
        ) orelse return error.ManifestCorrupt;
        const execution_generation_text =
            wire.execution_credential_generation orelse
            return error.ManifestCorrupt;
        if (execution_generation_text.len !=
            result.execution_credential_generation.len * 2)
            return error.ManifestCorrupt;
        _ = std.fmt.hexToBytes(
            &result.execution_credential_generation,
            execution_generation_text,
        ) catch return error.ManifestCorrupt;
        const api_key_id = wire.api_key_id orelse
            return error.ManifestCorrupt;
        const model = wire.model orelse return error.ManifestCorrupt;
        const base_url = wire.base_url orelse return error.ManifestCorrupt;
        if (api_key_id.len > result.api_key_id.len or
            model.len > result.model.len or
            base_url.len > result.base_url.len)
            return error.ManifestCorrupt;
        result.provider_kind = std.meta.stringToEnum(
            store.ProviderKind,
            wire.provider_kind orelse return error.ManifestCorrupt,
        ) orelse return error.ManifestCorrupt;
        @memcpy(result.api_key_id[0..api_key_id.len], api_key_id);
        result.api_key_id_len = api_key_id.len;
        @memcpy(result.model[0..model.len], model);
        result.model_len = model.len;
        @memcpy(result.base_url[0..base_url.len], base_url);
        result.base_url_len = base_url.len;
        result.execution_generation = wire.execution_generation;
    } else if (wire.execution_slot != null or
        wire.execution_credential_generation != null or
        wire.api_key_id != null or wire.provider_kind != null or
        wire.model != null or wire.base_url != null or
        wire.execution_generation != 0)
        return error.ManifestCorrupt;
    try result.validate();
    return result;
}

test "manifest codec is strict and round trips account-only state" {
    const state = @import("account_state");
    var tokens = try oauth.TokenSet.fromStored(
        std.testing.allocator,
        "access",
        "refresh",
        1234,
        oauth.scope,
        "acct-1",
    );
    defer tokens.deinit();
    const identity = try state.AccountIdentity.init(
        "acct-1",
        "profile-1",
        "Metask User",
    );
    const manifest = try store.Manifest.accountOnly(
        .B,
        @splat(0x55),
        &tokens,
        &identity,
        7,
    );
    var encoded_storage: [manifest_bytes]u8 = undefined;
    const encoded = try encodeManifest(&encoded_storage, manifest);
    const decoded = try decodeManifest(encoded);
    try std.testing.expectEqual(store.ManifestState.account_only, decoded.state);
    try std.testing.expectEqual(store.Slot.B, decoded.active_slot.?);
    try std.testing.expectEqualStrings("acct-1", decoded.accountId());
    try std.testing.expectError(
        error.ManifestCorrupt,
        decodeManifest(
            \\{"version":1,"state":"signed_out","active_slot":null,"generation":null,"expires_at":0,"scope":null,"account_id":null,"display_name":null,"execution_high_watermark":0,"unknown":true}
        ),
    );
}

test "manifest codec round trips one atomic execution-ready pointer" {
    const state = @import("account_state");
    const contract = @import("metawork_account_contract");
    var tokens = try oauth.TokenSet.fromStored(
        std.testing.allocator,
        "access",
        "refresh",
        1234,
        oauth.scope,
        "acct-1",
    );
    defer tokens.deinit();
    const identity = try state.AccountIdentity.init(
        "acct-1",
        "profile-1",
        "Metask User",
    );
    const account_manifest = try store.Manifest.accountOnly(
        .A,
        @splat(0x11),
        &tokens,
        &identity,
        0,
    );
    var execution = try contract.OwnedExecutionConfig.initOwned(
        std.testing.allocator,
        .openai,
        try std.testing.allocator.dupe(u8, "model-1"),
        try std.testing.allocator.dupe(
            u8,
            contract.metask_openai_chat_completions_url,
        ),
        1,
        try std.testing.allocator.dupe(u8, "execution-api-key"),
    );
    defer execution.deinit();
    const manifest = try store.Manifest.executionReady(
        account_manifest,
        .B,
        @splat(0x22),
        "325",
        &execution,
    );
    var encoded_storage: [manifest_bytes]u8 = undefined;
    const encoded = try encodeManifest(&encoded_storage, manifest);
    const decoded = try decodeManifest(encoded);
    try std.testing.expectEqual(
        store.ManifestState.execution_ready,
        decoded.state,
    );
    try std.testing.expectEqual(store.Slot.A, decoded.active_slot.?);
    try std.testing.expectEqual(store.Slot.B, decoded.execution_slot.?);
    try std.testing.expectEqualStrings("profile-1", decoded.profileId());
    try std.testing.expectEqualStrings("325", decoded.apiKeyId());
    try std.testing.expectEqual(
        contract.ProviderKind.openai,
        decoded.provider_kind.?,
    );
    try std.testing.expectEqualStrings("model-1", decoded.modelView());
    try std.testing.expectEqualStrings(
        contract.metask_openai_chat_completions_url,
        decoded.baseUrl(),
    );
    try std.testing.expectEqual(@as(u64, 1), decoded.execution_generation);
}

test "manifest codec accepts worst-case JSON escaping within contract bounds" {
    const state = @import("account_state");
    const contract = @import("metawork_account_contract");
    const account_id: [contract.Limits.account_id_bytes]u8 = @splat(0x01);
    const profile_id: [contract.Limits.profile_id_bytes]u8 = @splat(0x02);
    const display_name: [contract.Limits.display_name_bytes]u8 = @splat(0x03);
    const api_key_id: [contract.Limits.api_key_id_bytes]u8 = @splat(0x04);
    const model: [contract.Limits.model_id_bytes]u8 = @splat(0x05);
    var tokens = try oauth.TokenSet.fromStored(
        std.testing.allocator,
        "access",
        "refresh",
        1234,
        oauth.scope,
        &account_id,
    );
    defer tokens.deinit();
    const identity = try state.AccountIdentity.init(
        &account_id,
        &profile_id,
        &display_name,
    );
    const account_manifest = try store.Manifest.accountOnly(
        .A,
        @splat(0x11),
        &tokens,
        &identity,
        0,
    );
    var execution = try contract.OwnedExecutionConfig.initOwned(
        std.testing.allocator,
        .anthropic,
        try std.testing.allocator.dupe(u8, &model),
        try std.testing.allocator.dupe(
            u8,
            contract.metask_anthropic_messages_url,
        ),
        1,
        try std.testing.allocator.dupe(u8, "execution-api-key"),
    );
    defer execution.deinit();
    const manifest = try store.Manifest.executionReady(
        account_manifest,
        .B,
        @splat(0x22),
        &api_key_id,
        &execution,
    );
    var encoded_storage: [manifest_bytes]u8 = undefined;
    const encoded = try encodeManifest(&encoded_storage, manifest);
    const decoded = try decodeManifest(encoded);
    try std.testing.expectEqualStrings(&account_id, decoded.accountId());
    try std.testing.expectEqualStrings(&profile_id, decoded.profileId());
    try std.testing.expectEqualStrings(&display_name, decoded.displayName());
    try std.testing.expectEqualStrings(&api_key_id, decoded.apiKeyId());
    try std.testing.expectEqualStrings(&model, decoded.modelView());
}

test "Windows public state codec is unversioned and secret-free" {
    const identity = try account_state.AccountIdentity.init(
        "account-1",
        "profile-1",
        "MetaWork User",
    );
    const public_state = try windows_store.PublicState.init(
        identity,
        "api-42",
        "model-7",
    );
    var encoded_storage: [public_state_bytes]u8 = undefined;
    const encoded = try encodeWindowsPublicState(
        &encoded_storage,
        public_state,
    );
    try std.testing.expect(std.mem.indexOf(u8, encoded, "version") == null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "token") == null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "credential") == null);
    const decoded = try decodeWindowsPublicState(encoded);
    try std.testing.expectEqualStrings("account-1", decoded.account_id.view());
    try std.testing.expectEqualStrings("api-42", decoded.apiKeyId());
    try std.testing.expectEqualStrings("model-7", decoded.modelId());
}

test "Windows public state codec rejects versions and partial selections" {
    try std.testing.expectError(
        error.InvalidData,
        decodeWindowsPublicState(
            \\{"version":2,"account_id":"account-1","profile_id":"profile-1","display_name":"User","api_key_id":null,"model_id":null}
        ),
    );
    try std.testing.expectError(
        error.InvalidData,
        decodeWindowsPublicState(
            \\{"account_id":"account-1","profile_id":"profile-1","display_name":"User","api_key_id":"api-1","model_id":null}
        ),
    );
}

test "Windows public state cold-start read ignores manifest.v2" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var backend: WindowsBackend = .{
        .services = .{},
        .io = std.testing.io,
        .main_thread_id = std.Thread.getCurrentId(),
        .account_dir = tmp.dir,
    };
    const identity = try account_state.AccountIdentity.init(
        "account-1",
        "profile-1",
        "MetaWork User",
    );
    const first = try windows_store.PublicState.init(
        identity,
        "api-1",
        "model-1",
    );
    try backend.backend().commitPublicState(first);
    const second = try windows_store.PublicState.init(
        identity,
        "api-2",
        "model-2",
    );
    try backend.backend().commitPublicState(second);

    const legacy = try tmp.dir.createFile(
        std.testing.io,
        store.manifest_name,
        .{},
    );
    try legacy.writeStreamingAll(
        std.testing.io,
        "not-a-valid-macos-manifest",
    );
    legacy.close(std.testing.io);

    const restored = (try backend.backend().loadPublicState()).?;
    try std.testing.expectEqualStrings("api-2", restored.apiKeyId());
    try std.testing.expectEqualStrings("model-2", restored.modelId());
}
