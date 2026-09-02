//! Product Models effect ports. Credential bytes remain Host-owned and
//! are borrowed only for bounded synchronous resolution.

const std = @import("std");

pub const credential_slot_prefix = "model-connection-";
pub const credential_slot_bytes = credential_slot_prefix.len + 32;

pub const CredentialVault = struct {
    context: *anyopaque,
    generate_slot_fn: *const fn (*anyopaque, *[credential_slot_bytes]u8) anyerror!void,
    store_fn: *const fn (*anyopaque, []const u8, []const u8) anyerror!void,
    get_fn: *const fn (*anyopaque, []const u8, []u8) anyerror!?[]const u8,
    delete_fn: *const fn (*anyopaque, []const u8) anyerror!void,

    pub fn generateSlot(self: CredentialVault, output: *[credential_slot_bytes]u8) ![]const u8 {
        try self.generate_slot_fn(self.context, output);
        const slot = output[0..];
        if (!validCredentialSlot(slot)) return error.InvalidData;
        return slot;
    }

    pub fn store(self: CredentialVault, slot: []const u8, secret: []const u8) !void {
        if (!validCredentialSlot(slot) or secret.len == 0) return error.WriteFailed;
        try self.store_fn(self.context, slot, secret);
    }

    pub fn get(self: CredentialVault, slot: []const u8, output: []u8) !?[]const u8 {
        if (!validCredentialSlot(slot)) return error.InvalidData;
        return self.get_fn(self.context, slot, output);
    }

    pub fn delete(self: CredentialVault, slot: []const u8) !void {
        if (!validCredentialSlot(slot)) return error.InvalidData;
        try self.delete_fn(self.context, slot);
    }
};

pub fn validCredentialSlot(slot: []const u8) bool {
    if (slot.len != credential_slot_bytes or
        !std.mem.startsWith(u8, slot, credential_slot_prefix)) return false;
    for (slot[credential_slot_prefix.len..]) |byte|
        if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) return false;
    return true;
}

test "credential vault rejects malformed slots before invoking effect" {
    const Fake = struct {
        calls: usize = 0,
        fn store(context: *anyopaque, _: []const u8, _: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
        }
    };
    var fake: Fake = .{};
    const vault: CredentialVault = .{
        .context = &fake,
        .generate_slot_fn = undefined,
        .store_fn = Fake.store,
        .get_fn = undefined,
        .delete_fn = undefined,
    };
    try std.testing.expectError(error.WriteFailed, vault.store("bad", "secret"));
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
}
