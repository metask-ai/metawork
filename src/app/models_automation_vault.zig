const std = @import("std");
const models_contract = @import("metawork_product_models_contract");
const models_ports = @import("product_models_ports");

/// Automation owns one bounded, process-local credential. The Models FileStore
/// remains real, while this port prevents vertical fixtures from leaving random
/// slots in the user's system credential store.
pub const Vault = struct {
    pub const slot = "model-connection-00000000000000000000000000000001";

    secret: [models_contract.Limits.credential_bytes]u8 =
        [_]u8{0} ** models_contract.Limits.credential_bytes,
    secret_len: usize = 0,
    present: bool = false,

    comptime {
        std.debug.assert(models_ports.validCredentialSlot(slot));
    }

    pub fn port(self: *Vault) models_ports.CredentialVault {
        return .{
            .context = self,
            .generate_slot_fn = generateSlot,
            .store_fn = store,
            .get_fn = get,
            .delete_fn = delete,
        };
    }

    pub fn deinit(self: *Vault) void {
        std.crypto.secureZero(u8, &self.secret);
        self.secret_len = 0;
        self.present = false;
    }

    fn generateSlot(_: *anyopaque, output: *[models_ports.credential_slot_bytes]u8) !void {
        @memcpy(output, slot);
    }

    fn store(context: *anyopaque, credential_slot: []const u8, secret: []const u8) !void {
        const self: *Vault = @ptrCast(@alignCast(context));
        if (!std.mem.eql(u8, credential_slot, slot) or
            secret.len > self.secret.len) return error.WriteFailed;
        std.crypto.secureZero(u8, &self.secret);
        @memcpy(self.secret[0..secret.len], secret);
        self.secret_len = secret.len;
        self.present = true;
    }

    fn get(context: *anyopaque, credential_slot: []const u8, output: []u8) !?[]const u8 {
        const self: *Vault = @ptrCast(@alignCast(context));
        if (!self.present or !std.mem.eql(u8, credential_slot, slot)) return null;
        if (output.len < self.secret_len) return error.BufferTooSmall;
        @memcpy(output[0..self.secret_len], self.secret[0..self.secret_len]);
        return output[0..self.secret_len];
    }

    fn delete(context: *anyopaque, credential_slot: []const u8) !void {
        const self: *Vault = @ptrCast(@alignCast(context));
        if (!std.mem.eql(u8, credential_slot, slot) or !self.present) return;
        std.crypto.secureZero(u8, &self.secret);
        self.secret_len = 0;
        self.present = false;
    }
};
