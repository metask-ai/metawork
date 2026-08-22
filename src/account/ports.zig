const std = @import("std");
const oauth = @import("account_oauth");
const credential_store = @import("account_credential_store");

pub const model_connection_slot_prefix = "model-connection-";
pub const model_connection_slot_bytes = model_connection_slot_prefix.len + 32;

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

pub const ModelCredentialVault = struct {
    context: *anyopaque,
    generate_slot_fn: *const fn (
        *anyopaque,
        *[model_connection_slot_bytes]u8,
    ) credential_store.StoreError!void,
    store_fn: *const fn (*anyopaque, []const u8, []const u8) credential_store.StoreError!void,
    get_fn: *const fn (*anyopaque, []const u8, []u8) credential_store.StoreError!?[]const u8,
    delete_fn: *const fn (*anyopaque, []const u8) credential_store.StoreError!void,

    pub fn generateSlot(
        self: ModelCredentialVault,
        output: *[model_connection_slot_bytes]u8,
    ) credential_store.StoreError![]const u8 {
        try self.generate_slot_fn(self.context, output);
        const slot = output[0..];
        if (!validModelConnectionSlot(slot)) return error.InvalidData;
        return slot;
    }

    pub fn store(
        self: ModelCredentialVault,
        slot: []const u8,
        secret: []const u8,
    ) credential_store.StoreError!void {
        if (!validModelConnectionSlot(slot) or secret.len == 0)
            return error.WriteFailed;
        return self.store_fn(self.context, slot, secret);
    }

    pub fn get(
        self: ModelCredentialVault,
        slot: []const u8,
        output: []u8,
    ) credential_store.StoreError!?[]const u8 {
        if (!validModelConnectionSlot(slot)) return error.InvalidData;
        return self.get_fn(self.context, slot, output);
    }

    pub fn delete(
        self: ModelCredentialVault,
        slot: []const u8,
    ) credential_store.StoreError!void {
        if (!validModelConnectionSlot(slot)) return error.InvalidData;
        return self.delete_fn(self.context, slot);
    }
};

pub const Platform = struct {
    credentials: credential_store.Backend,
    authorization_url: AuthorizationUrl,
    timer: Timer,
    model_credentials: ModelCredentialVault,
};

pub fn validModelConnectionSlot(slot: []const u8) bool {
    if (slot.len != model_connection_slot_bytes or
        !std.mem.startsWith(u8, slot, model_connection_slot_prefix))
        return false;
    for (slot[model_connection_slot_prefix.len..]) |byte|
        if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) return false;
    return true;
}

test "model credential vault rejects malformed slots before invoking effect" {
    const Fake = struct {
        calls: usize = 0,

        fn storeEffect(
            context: *anyopaque,
            _: []const u8,
            _: []const u8,
        ) credential_store.StoreError!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
        }
    };
    var fake: Fake = .{};
    const vault: ModelCredentialVault = .{
        .context = &fake,
        .generate_slot_fn = undefined,
        .store_fn = Fake.storeEffect,
        .get_fn = undefined,
        .delete_fn = undefined,
    };
    try std.testing.expectError(error.WriteFailed, vault.store("bad", "secret"));
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
}
