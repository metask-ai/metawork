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
    services: native_sdk.platform.PlatformServices,
    io: std.Io,
    main_thread_id: std.Thread.Id,

    pub fn init(
        services: native_sdk.platform.PlatformServices,
        io: std.Io,
        main_thread_id: std.Thread.Id,
    ) Adapter {
        return .{
            .services = services,
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
        self.services.setCredential(.{
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
        return self.services.getCredential(.{
            .service = custom_provider_service,
            .account = slot,
        }, output) catch |err| switch (err) {
            error.CredentialNotFound => null,
            else => error.ReadFailed,
        };
    }

    fn deleteCredential(
        context: *anyopaque,
        slot: []const u8,
    ) anyerror!void {
        const self: *Adapter = @ptrCast(@alignCast(context));
        try self.assertMainThread();
        self.services.deleteCredential(.{
            .service = custom_provider_service,
            .account = slot,
        }) catch |err| switch (err) {
            error.CredentialNotFound => {},
            else => return error.DeleteFailed,
        };
    }
};
