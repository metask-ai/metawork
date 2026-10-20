const std = @import("std");
const native_sdk = @import("native_sdk");
const models_ports = @import("product_models_ports");
const product_identity = @import("metawork_product_identity");

// This exact service identity predates the Execution owner split. Keep it
// stable so existing credentials remain addressable without making Execution
// depend on Account's credential-store implementation.
const custom_provider_service = product_identity.customProviderCredentialService();

/// Application-owned platform adapter for Product Models credentials.
/// It owns no registry state. User-entered Custom Provider bytes arrive only
/// through the dedicated create/replace command and are never projected back.
pub const Adapter = struct {
    runtime: *native_sdk.Runtime,
    io: std.Io,
    main_thread_id: std.Thread.Id,

    pub fn init(
        runtime: *native_sdk.Runtime,
        io: std.Io,
        main_thread_id: std.Thread.Id,
    ) Adapter {
        return .{
            .runtime = runtime,
            .io = io,
            .main_thread_id = main_thread_id,
        };
    }

    pub fn ports(self: *Adapter) models_ports.CredentialVault {
        return .{
            .context = self,
            .generate_slot_fn = generateCredentialSlot,
            .store_fn = storeCredential,
            .get_fn = getCredential,
            .delete_fn = deleteCredential,
        };
    }

    fn assertMainThread(self: *const Adapter) !void {
        if (std.Thread.getCurrentId() != self.main_thread_id)
            return error.WrongThread;
    }

    fn generateCredentialSlot(
        context: *anyopaque,
        output: *[models_ports.credential_slot_bytes]u8,
    ) anyerror!void {
        const self: *Adapter = @ptrCast(@alignCast(context));
        try self.assertMainThread();
        var random: [16]u8 = undefined;
        defer std.crypto.secureZero(u8, &random);
        try std.Io.randomSecure(self.io, &random);
        @memcpy(
            output[0..models_ports.credential_slot_prefix.len],
            models_ports.credential_slot_prefix,
        );
        const hex = std.fmt.bytesToHex(random, .lower);
        @memcpy(output[models_ports.credential_slot_prefix.len..], &hex);
    }

    fn storeCredential(
        context: *anyopaque,
        slot: []const u8,
        secret: []const u8,
    ) anyerror!void {
        const self: *Adapter = @ptrCast(@alignCast(context));
        try self.assertMainThread();
        if (secret.len > native_sdk.platform.max_credential_secret_bytes)
            return error.WriteFailed;
        self.runtime.setCredential(.{
            .service = custom_provider_service,
            .account = slot,
            .secret = secret,
        }) catch return error.WriteFailed;
    }

    fn getCredential(
        context: *anyopaque,
        slot: []const u8,
        output: []u8,
    ) anyerror!?[]const u8 {
        const self: *Adapter = @ptrCast(@alignCast(context));
        try self.assertMainThread();
        return self.runtime.getCredential(.{
            .service = custom_provider_service,
            .account = slot,
        }, output) catch return error.ReadFailed;
    }

    fn deleteCredential(
        context: *anyopaque,
        slot: []const u8,
    ) anyerror!void {
        const self: *Adapter = @ptrCast(@alignCast(context));
        try self.assertMainThread();
        _ = self.runtime.deleteCredential(.{
            .service = custom_provider_service,
            .account = slot,
        }) catch return error.DeleteFailed;
    }
};

test "SDK consumption Models vault preserves namespace missing and delete semantics" {
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
    var binding = Adapter.init(&harness.runtime, std.testing.io, std.Thread.getCurrentId());
    const vault = binding.ports();
    var slot_storage: [models_ports.credential_slot_bytes]u8 = undefined;
    const slot = try vault.generateSlot(&slot_storage);
    var output: [native_sdk.platform.max_credential_secret_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &output);
    try std.testing.expect((try vault.get(slot, &output)) == null);
    try vault.delete(slot);
    try vault.store(slot, "test-secret");
    try std.testing.expectEqualStrings(custom_provider_service, harness.null_platform.credential_service[0..harness.null_platform.credential_service_len]);
    try std.testing.expectEqualStrings(slot, harness.null_platform.credential_account[0..harness.null_platform.credential_account_len]);
    const set_fn = harness.runtime.options.platform.services.set_credential_fn;
    harness.runtime.options.platform.services.set_credential_fn = Failure.write;
    try std.testing.expectError(error.WriteFailed, vault.store(slot, "replacement"));
    harness.runtime.options.platform.services.set_credential_fn = set_fn;
    try std.testing.expectEqualStrings("test-secret", (try vault.get(slot, &output)).?);
    try std.testing.expectError(error.ReadFailed, vault.get(slot, output[0..1]));
    const get_fn = harness.runtime.options.platform.services.get_credential_fn;
    harness.runtime.options.platform.services.get_credential_fn = Failure.read;
    try std.testing.expectError(error.ReadFailed, vault.get(slot, &output));
    harness.runtime.options.platform.services.get_credential_fn = get_fn;
    const delete_fn = harness.runtime.options.platform.services.delete_credential_fn;
    harness.runtime.options.platform.services.delete_credential_fn = Failure.delete;
    try std.testing.expectError(error.DeleteFailed, vault.delete(slot));
    harness.runtime.options.platform.services.delete_credential_fn = delete_fn;
    try std.testing.expectEqualStrings("test-secret", (try vault.get(slot, &output)).?);
    binding.main_thread_id +%= 1;
    try std.testing.expectError(error.WrongThread, vault.get(slot, &output));
    try std.testing.expectError(error.WrongThread, vault.store(slot, "wrong-thread"));
    try std.testing.expectError(error.WrongThread, vault.delete(slot));
    binding.main_thread_id -%= 1;
    try vault.delete(slot);
    try vault.delete(slot);
    try std.testing.expect((try vault.get(slot, &output)) == null);
}
