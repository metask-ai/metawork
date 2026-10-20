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
    runtime: *native_sdk.Runtime,
    io: std.Io,
    main_thread_id: std.Thread.Id,

    pub fn init(
        runtime: *native_sdk.Runtime,
        io: std.Io,
        main_thread_id: std.Thread.Id,
    ) InitError!Adapter {
        if (std.Thread.getCurrentId() != main_thread_id)
            return error.WrongThread;
        return .{
            .runtime = runtime,
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
        try self.runtime.options.platform.services.openExternalUrl(url);
    }

    fn openRechargePage(context: *anyopaque, url: []const u8) !void {
        const self: *Adapter = @ptrCast(@alignCast(context));
        try self.assertMainThread();
        try self.runtime.options.platform.services.openExternalUrl(url);
    }

    fn startTimer(
        context: *anyopaque,
        timer_id: u64,
        interval_ns: u64,
        repeats: bool,
    ) !void {
        const self: *Adapter = @ptrCast(@alignCast(context));
        try self.assertMainThread();
        try self.runtime.startTimer(timer_id, interval_ns, repeats);
    }

    fn cancelTimer(context: *anyopaque, timer_id: u64) !void {
        const self: *Adapter = @ptrCast(@alignCast(context));
        try self.assertMainThread();
        try self.runtime.cancelTimer(timer_id);
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
        self.runtime.setCredential(.{
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
        return self.runtime.getCredential(.{
            .service = store.service,
            .account = store.refresh_token_account,
        }, output) catch return error.ReadFailed;
    }

    fn deleteRefreshToken(context: *anyopaque) store.StoreError!void {
        const self: *Adapter = @ptrCast(@alignCast(context));
        self.assertMainThread() catch return error.DeleteFailed;
        _ = self.runtime.deleteCredential(.{
            .service = store.service,
            .account = store.refresh_token_account,
        }) catch return error.DeleteFailed;
    }
    fn setRefreshMarker(context: *anyopaque, value: []const u8) store.StoreError!void {
        const self: *Adapter = @ptrCast(@alignCast(context));
        self.assertMainThread() catch return error.WriteFailed;
        if (value.len != store.marker_bytes) return error.WriteFailed;
        self.runtime.setCredential(.{
            .service = store.service,
            .account = store.refresh_in_flight_account,
            .secret = value,
        }) catch return error.WriteFailed;
    }

    fn getRefreshMarker(context: *anyopaque, output: []u8) store.StoreError!?[]const u8 {
        const self: *Adapter = @ptrCast(@alignCast(context));
        self.assertMainThread() catch return error.ReadFailed;
        return self.runtime.getCredential(.{
            .service = store.service,
            .account = store.refresh_in_flight_account,
        }, output) catch return error.ReadFailed;
    }

    fn deleteRefreshMarker(context: *anyopaque) store.StoreError!void {
        const self: *Adapter = @ptrCast(@alignCast(context));
        self.assertMainThread() catch return error.DeleteFailed;
        _ = self.runtime.deleteCredential(.{
            .service = store.service,
            .account = store.refresh_in_flight_account,
        }) catch return error.DeleteFailed;
    }
};

test "SDK consumption Account URLs keep their Host intent with navigation denied" {
    const Spy = struct {
        var calls: usize = 0;
        var last: []const u8 = "";
        var fail = false;
        fn open(_: ?*anyopaque, url: []const u8) anyerror!void {
            calls += 1;
            last = url;
            if (fail) return error.InjectedHandlerFailure;
        }
    };
    Spy.calls = 0;
    Spy.fail = false;
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.runtime.options.platform.services.open_external_url_fn = Spy.open;
    var binding = try Adapter.init(&harness.runtime, std.testing.io, std.Thread.getCurrentId());
    defer binding.deinit();
    const port = binding.ports();
    const oauth = @import("account_oauth");
    const material = oauth.AttemptMaterial.fromSeeds(@splat(0x11), @splat(0x22));
    var buffer: [oauth.Limits.authorization_url_bytes]u8 = undefined;
    const url = try oauth.buildAuthorizeUrl(&buffer, 49152, &material);
    try std.testing.expectError(error.NavigationDenied, harness.runtime.openExternalUrl(url));
    try std.testing.expectError(error.InvalidAuthorizationUrl, port.authorization_url.open("https://unrelated.example.invalid/"));
    try std.testing.expectEqual(@as(usize, 0), Spy.calls);
    try port.authorization_url.open(url);
    try std.testing.expectEqualStrings(url, Spy.last);
    try port.recharge_page.open();
    try std.testing.expectEqualStrings(@import("metawork_account_contract").recharge_page_url, Spy.last);
    try std.testing.expectEqual(@as(usize, 2), Spy.calls);
    Spy.fail = true;
    try std.testing.expectError(error.InjectedHandlerFailure, port.recharge_page.open());
    try std.testing.expectEqual(@as(usize, 3), Spy.calls);
    binding.main_thread_id +%= 1;
    try std.testing.expectError(error.WrongThread, port.authorization_url.open(url));
    try std.testing.expectEqual(@as(usize, 3), Spy.calls);
    binding.main_thread_id -%= 1;
}

test "SDK consumption Account timer propagates errors and rejects wrong thread" {
    const Spy = struct {
        var calls: usize = 0;
        fn start(_: ?*anyopaque, id: u64, ns: u64, repeats: bool) anyerror!void {
            calls += 1;
            try std.testing.expectEqual(@as(u64, 42), id);
            try std.testing.expectEqual(@as(u64, 123), ns);
            try std.testing.expect(!repeats);
            return error.InjectedTimerFailure;
        }
        fn cancel(_: ?*anyopaque, id: u64) anyerror!void {
            calls += 1;
            try std.testing.expectEqual(@as(u64, 42), id);
            return error.InjectedTimerFailure;
        }
    };
    Spy.calls = 0;
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.runtime.options.platform.services.start_timer_fn = Spy.start;
    harness.runtime.options.platform.services.cancel_timer_fn = Spy.cancel;
    var binding = try Adapter.init(&harness.runtime, std.testing.io, std.Thread.getCurrentId());
    defer binding.deinit();
    const timer = binding.ports().timer;
    try std.testing.expectError(error.InjectedTimerFailure, timer.start(42, 123, false));
    try std.testing.expectError(error.InjectedTimerFailure, timer.cancel(42));
    binding.main_thread_id +%= 1;
    try std.testing.expectError(error.WrongThread, timer.start(42, 123, false));
    try std.testing.expectEqual(@as(usize, 2), Spy.calls);
    binding.main_thread_id -%= 1;
}

test "SDK consumption Account credential Runtime mapping preserves refresh recovery" {
    const Failure = struct {
        fn write(_: ?*anyopaque, _: native_sdk.platform.Credential) anyerror!void {
            return error.CredentialStoreLocked;
        }
        fn read(_: ?*anyopaque, _: native_sdk.platform.CredentialKey, _: []u8) anyerror![]const u8 {
            return error.PermissionDenied;
        }
        fn delete(_: ?*anyopaque, _: native_sdk.platform.CredentialKey) anyerror!void {
            return error.PermissionDenied;
        }
    };
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    var binding = try Adapter.init(&harness.runtime, std.testing.io, std.Thread.getCurrentId());
    defer binding.deinit();
    const backend = binding.ports().credentials;
    var output: [native_sdk.platform.max_credential_secret_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &output);
    try std.testing.expect((try backend.getRefreshToken(&output)) == null);
    try store.commitSignedOut(backend); // Both Runtime delete(false) results are idempotent success.
    try backend.setRefreshToken("old-test-token");
    try std.testing.expectEqualStrings(store.service, harness.null_platform.credential_service[0..harness.null_platform.credential_service_len]);
    try std.testing.expectEqualStrings(store.refresh_token_account, harness.null_platform.credential_account[0..harness.null_platform.credential_account_len]);
    var marker = store.refreshMarker("old-test-token");
    defer std.crypto.secureZero(u8, &marker);
    try backend.set_refresh_marker_fn(backend.context, &marker);
    try std.testing.expectEqualStrings(store.refresh_in_flight_account, harness.null_platform.credential_account[0..harness.null_platform.credential_account_len]);
    var restored = try store.restore(std.testing.allocator, backend);
    defer restored.deinit();
    try std.testing.expect(restored == .blocked);
    const set_fn = harness.runtime.options.platform.services.set_credential_fn;
    harness.runtime.options.platform.services.set_credential_fn = Failure.write;
    try std.testing.expectError(error.WriteFailed, backend.setRefreshToken("new-test-token"));
    harness.runtime.options.platform.services.set_credential_fn = set_fn;
    try std.testing.expectEqualStrings("old-test-token", (try backend.getRefreshToken(&output)).?);
    try std.testing.expectError(error.WriteFailed, backend.setRefreshToken("bad\x00token"));
    try backend.setRefreshToken("new-test-token");
    var rotated = try store.restore(std.testing.allocator, backend);
    defer rotated.deinit();
    try std.testing.expect(rotated == .account);
    try std.testing.expectEqualStrings("new-test-token", rotated.account.refresh_token.view());
    const get_fn = harness.runtime.options.platform.services.get_credential_fn;
    harness.runtime.options.platform.services.get_credential_fn = Failure.read;
    try std.testing.expectError(error.ReadFailed, backend.getRefreshToken(&output));
    harness.runtime.options.platform.services.get_credential_fn = get_fn;
    try std.testing.expectError(error.ReadFailed, backend.getRefreshToken(output[0..1]));
    const delete_fn = harness.runtime.options.platform.services.delete_credential_fn;
    harness.runtime.options.platform.services.delete_credential_fn = Failure.delete;
    try std.testing.expectError(error.DeleteFailed, store.commitSignedOut(backend));
    harness.runtime.options.platform.services.delete_credential_fn = delete_fn;
    try std.testing.expectEqualStrings("new-test-token", (try backend.getRefreshToken(&output)).?);
    binding.main_thread_id +%= 1;
    try std.testing.expectError(error.ReadFailed, backend.getRefreshToken(&output));
    try std.testing.expectError(error.WriteFailed, backend.setRefreshToken("wrong-thread"));
    try std.testing.expectError(error.DeleteFailed, backend.deleteRefreshToken());
    binding.main_thread_id -%= 1;
    try store.commitSignedOut(backend);
    var signed_out = try store.restore(std.testing.allocator, backend);
    defer signed_out.deinit();
    try std.testing.expect(signed_out == .signed_out);
}
