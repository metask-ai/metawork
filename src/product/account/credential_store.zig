//! Product Account credential and preference persistence policy.
const std = @import("std");
const contract = @import("metawork_account_contract");
const oauth = @import("account_oauth");
const product_identity = @import("metawork_product_identity");

pub const service = product_identity.accountCredentialService();
pub const refresh_token_account = "metask-refresh-token";
pub const preference_name = "preferences.json";
pub const preference_bytes = 8 * 1024;

pub const StoreError = error{
    ReadFailed,
    WriteFailed,
    DeleteFailed,
    InvalidData,
    PersistenceOutcomeUnknown,
};

fn PublicText(comptime capacity: usize) type {
    return struct {
        bytes: [capacity]u8 = undefined,
        len: usize = 0,

        fn set(self: *@This(), value: []const u8) StoreError!void {
            if (value.len == 0 or value.len > capacity or
                !std.unicode.utf8ValidateSlice(value))
                return error.InvalidData;
            @memcpy(self.bytes[0..value.len], value);
            self.len = value.len;
        }

        pub fn view(self: *const @This()) []const u8 {
            return self.bytes[0..self.len];
        }
    };
}

/// The only non-secret Account persistence. The owner is used solely to
/// decide whether a verified current identity may reuse this default.
pub const Preference = struct {
    selection_owner_account_id: PublicText(contract.Limits.account_id_bytes) = .{},
    api_key_id: PublicText(contract.Limits.api_key_id_bytes) = .{},
    model_id: PublicText(contract.Limits.model_id_bytes) = .{},
    execution_generation: u64 = 0,

    pub fn init(
        owner_account_id: []const u8,
        api_key_id: []const u8,
        model_id: []const u8,
        execution_generation: u64,
    ) StoreError!Preference {
        if (execution_generation == 0) return error.InvalidData;
        var result: Preference = .{ .execution_generation = execution_generation };
        try result.selection_owner_account_id.set(owner_account_id);
        try result.api_key_id.set(api_key_id);
        try result.model_id.set(model_id);
        return result;
    }

    pub fn validate(self: *const Preference) StoreError!void {
        _ = try Preference.init(
            self.ownerAccountId(),
            self.apiKeyId(),
            self.modelId(),
            self.execution_generation,
        );
    }

    pub fn ownerAccountId(self: *const Preference) []const u8 {
        return self.selection_owner_account_id.view();
    }

    pub fn apiKeyId(self: *const Preference) []const u8 {
        return self.api_key_id.view();
    }

    pub fn modelId(self: *const Preference) []const u8 {
        return self.model_id.view();
    }
};

const PreferenceWire = struct {
    selection_owner_account_id: []const u8,
    api_key_id: []const u8,
    model_id: []const u8,
    execution_generation: u64,
};

pub fn encodePreference(
    output: []u8,
    preference: Preference,
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

pub fn decodePreference(input: []const u8) StoreError!Preference {
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
    return Preference.init(
        parsed.value.selection_owner_account_id,
        parsed.value.api_key_id,
        parsed.value.model_id,
        parsed.value.execution_generation,
    );
}

pub const Backend = struct {
    context: *anyopaque,
    set_refresh_token_fn: *const fn (*anyopaque, []const u8) StoreError!void,
    get_refresh_token_fn: *const fn (*anyopaque, []u8) StoreError!?[]const u8,
    delete_refresh_token_fn: *const fn (*anyopaque) StoreError!void,
    load_preference_fn: *const fn (*anyopaque) StoreError!?Preference,
    commit_preference_fn: *const fn (*anyopaque, Preference) StoreError!void,
    delete_preference_fn: *const fn (*anyopaque) StoreError!void,

    pub fn setRefreshToken(self: Backend, value: []const u8) StoreError!void {
        return self.set_refresh_token_fn(self.context, value);
    }

    pub fn getRefreshToken(self: Backend, output: []u8) StoreError!?[]const u8 {
        return self.get_refresh_token_fn(self.context, output);
    }

    pub fn deleteRefreshToken(self: Backend) StoreError!void {
        return self.delete_refresh_token_fn(self.context);
    }

    pub fn loadPreference(self: Backend) StoreError!?Preference {
        return self.load_preference_fn(self.context);
    }

    pub fn commitPreference(self: Backend, value: Preference) StoreError!void {
        try value.validate();
        return self.commit_preference_fn(self.context, value);
    }

    pub fn deletePreference(self: Backend) StoreError!void {
        return self.delete_preference_fn(self.context);
    }
};

pub const RestoredAccount = struct {
    refresh_token: oauth.Secret,
    preference: ?Preference,

    pub fn deinit(self: *RestoredAccount) void {
        self.refresh_token.deinit();
        self.* = undefined;
    }
};

pub const RestoreResult = union(enum) {
    signed_out,
    account: RestoredAccount,

    pub fn deinit(self: *RestoreResult) void {
        switch (self.*) {
            .account => |*account| account.deinit(),
            .signed_out => {},
        }
        self.* = .signed_out;
    }
};

pub fn restore(
    allocator: std.mem.Allocator,
    backend: Backend,
) (StoreError || std.mem.Allocator.Error || oauth.ProtocolError)!RestoreResult {
    var refresh_storage: [oauth.Limits.secret_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &refresh_storage);
    const refresh_token = try backend.getRefreshToken(&refresh_storage);
    if (refresh_token == null) {
        backend.deletePreference() catch {};
        return .signed_out;
    }

    const preference = backend.loadPreference() catch blk: {
        backend.deletePreference() catch {};
        break :blk null;
    };
    if (preference) |value| value.validate() catch {
        backend.deletePreference() catch {};
        return .{ .account = .{
            .refresh_token = try oauth.Secret.init(allocator, refresh_token.?),
            .preference = null,
        } };
    };
    return .{ .account = .{
        .refresh_token = try oauth.Secret.init(allocator, refresh_token.?),
        .preference = preference,
    } };
}

/// Rotation commit boundary. Callers must persist the new refresh token before
/// using any later catalog result.
pub fn commitRefresh(
    backend: Backend,
    refresh_token: *const oauth.Secret,
) StoreError!void {
    try backend.setRefreshToken(refresh_token.view());
}

pub fn commitPreference(
    backend: Backend,
    owner_account_id: []const u8,
    api_key_id: []const u8,
    model_id: []const u8,
    execution_generation: u64,
) StoreError!Preference {
    const preference = try Preference.init(
        owner_account_id,
        api_key_id,
        model_id,
        execution_generation,
    );
    try backend.commitPreference(preference);
    return preference;
}

pub fn clearPreference(backend: Backend) StoreError!void {
    try backend.deletePreference();
}

pub fn commitSignedOut(backend: Backend) StoreError!void {
    try backend.deleteRefreshToken();
    backend.deletePreference() catch {};
}

const FakeBackend = struct {
    refresh_token: ?[]const u8 = null,
    preference: ?Preference = null,
    preference_corrupt: bool = false,
    fail_preference_write: bool = false,
    fail_preference_delete: bool = false,
    delete_order: [2]u8 = .{ 0, 0 },
    delete_count: usize = 0,

    fn backend(self: *FakeBackend) Backend {
        return .{
            .context = self,
            .set_refresh_token_fn = setRefresh,
            .get_refresh_token_fn = getRefresh,
            .delete_refresh_token_fn = deleteRefresh,
            .load_preference_fn = loadPreference,
            .commit_preference_fn = commitPreferenceValue,
            .delete_preference_fn = deletePreference,
        };
    }

    fn setRefresh(context: *anyopaque, value: []const u8) StoreError!void {
        const self: *FakeBackend = @ptrCast(@alignCast(context));
        self.refresh_token = value;
    }

    fn getRefresh(context: *anyopaque, output: []u8) StoreError!?[]const u8 {
        const self: *FakeBackend = @ptrCast(@alignCast(context));
        const value = self.refresh_token orelse return null;
        if (value.len > output.len) return error.ReadFailed;
        @memcpy(output[0..value.len], value);
        return output[0..value.len];
    }

    fn deleteRefresh(context: *anyopaque) StoreError!void {
        const self: *FakeBackend = @ptrCast(@alignCast(context));
        self.refresh_token = null;
        self.delete_order[self.delete_count] = 1;
        self.delete_count += 1;
    }

    fn loadPreference(context: *anyopaque) StoreError!?Preference {
        const self: *FakeBackend = @ptrCast(@alignCast(context));
        if (self.preference_corrupt) return error.InvalidData;
        return self.preference;
    }

    fn commitPreferenceValue(context: *anyopaque, value: Preference) StoreError!void {
        const self: *FakeBackend = @ptrCast(@alignCast(context));
        if (self.fail_preference_write) return error.WriteFailed;
        self.preference = value;
    }

    fn deletePreference(context: *anyopaque) StoreError!void {
        const self: *FakeBackend = @ptrCast(@alignCast(context));
        if (self.fail_preference_delete) return error.DeleteFailed;
        self.preference = null;
        self.preference_corrupt = false;
        if (self.delete_count < self.delete_order.len) {
            self.delete_order[self.delete_count] = 2;
            self.delete_count += 1;
        }
    }
};

test "refresh token restores independently of optional preference" {
    var fake: FakeBackend = .{ .refresh_token = "refresh-only" };
    var restored = try restore(std.testing.allocator, fake.backend());
    defer restored.deinit();
    try std.testing.expect(restored == .account);
    try std.testing.expect(restored.account.preference == null);
    try std.testing.expectEqualStrings(
        "refresh-only",
        restored.account.refresh_token.view(),
    );
}

test "corrupt preference is cleared without blocking refresh restore" {
    var fake: FakeBackend = .{
        .refresh_token = "refresh-only",
        .preference_corrupt = true,
    };
    var restored = try restore(std.testing.allocator, fake.backend());
    defer restored.deinit();
    try std.testing.expect(restored == .account);
    try std.testing.expect(restored.account.preference == null);
    try std.testing.expect(!fake.preference_corrupt);
}

test "preference failure cannot roll back a committed refresh rotation" {
    var old = try oauth.Secret.init(std.testing.allocator, "rotated-refresh");
    defer old.deinit();
    var fake: FakeBackend = .{ .fail_preference_write = true };
    try commitRefresh(fake.backend(), &old);
    try std.testing.expectError(error.WriteFailed, commitPreference(
        fake.backend(),
        "account-1",
        "api-1",
        "model-1",
        1,
    ));
    try std.testing.expectEqualStrings("rotated-refresh", fake.refresh_token.?);
}

test "logout deletes the refresh token before non-secret preference" {
    var fake: FakeBackend = .{
        .refresh_token = "refresh-only",
        .preference = try .init("account-1", "api-1", "model-1", 1),
    };
    try commitSignedOut(fake.backend());
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, &fake.delete_order);
}

test "optional preference deletion cannot block logout" {
    var fake: FakeBackend = .{
        .refresh_token = "refresh-only",
        .preference = try .init("account-1", "api-1", "model-1", 1),
        .fail_preference_delete = true,
    };
    try commitSignedOut(fake.backend());
    try std.testing.expectEqual(@as(?[]const u8, null), fake.refresh_token);
    try std.testing.expect(fake.preference != null);
}

test "automation credential namespace is compile-time isolated" {
    if (product_identity.artifact_kind == .automation) {
        try std.testing.expect(std.mem.endsWith(u8, service, ".automation.account"));
    } else {
        try std.testing.expectEqualStrings(
            product_identity.development_account_credential_service,
            service,
        );
    }
}

test "preference codec is strict, unversioned, and secret-free" {
    const value = try Preference.init(
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
