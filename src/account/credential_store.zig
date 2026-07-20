const std = @import("std");
const contract = @import("metawork_account_contract");
const state = @import("account_state");
const oauth = @import("account_oauth");

pub const service = "dev.metawork.account.oauth.v1";

pub const Slot = enum {
    A,
    B,

    fn inactive(active: ?Slot) Slot {
        return switch (active orelse return .A) {
            .A => .B,
            .B => .A,
        };
    }
};

pub const RecordKind = enum {
    access,
    refresh,
    marker,
};

pub const CredentialKey = struct {
    slot: Slot,
    kind: RecordKind,

    pub fn account(self: CredentialKey) []const u8 {
        return switch (self.slot) {
            .A => switch (self.kind) {
                .access => "oauth/A/access",
                .refresh => "oauth/A/refresh",
                .marker => "oauth/A/marker",
            },
            .B => switch (self.kind) {
                .access => "oauth/B/access",
                .refresh => "oauth/B/refresh",
                .marker => "oauth/B/marker",
            },
        };
    }
};

pub const Generation = [16]u8;

pub const ManifestState = enum {
    signed_out,
    account_only,
};

pub const Manifest = struct {
    version: u8 = 1,
    state: ManifestState,
    active_slot: ?Slot = null,
    generation: Generation = @splat(0),
    expires_at: i64 = 0,
    scope_value: [oauth.Limits.scope_bytes]u8 = undefined,
    scope_len: usize = 0,
    account_id: [contract.Limits.account_id_bytes]u8 = undefined,
    account_id_len: usize = 0,
    display_name: [contract.Limits.display_name_bytes]u8 = undefined,
    display_name_len: usize = 0,
    execution_high_watermark: u64 = 0,

    pub fn signedOut(execution_high_watermark: u64) Manifest {
        return .{
            .state = .signed_out,
            .execution_high_watermark = execution_high_watermark,
        };
    }

    pub fn accountOnly(
        slot: Slot,
        generation: Generation,
        tokens: *const oauth.TokenSet,
        identity: *const state.AccountIdentity,
        execution_high_watermark: u64,
    ) StoreError!Manifest {
        const account_id = identity.accountId();
        const display_name = identity.displayName();
        const token_scope = tokens.scopeView();
        if (account_id.len == 0 or
            account_id.len > contract.Limits.account_id_bytes or
            display_name.len > contract.Limits.display_name_bytes or
            token_scope.len == 0 or token_scope.len > oauth.Limits.scope_bytes)
            return error.InvalidData;
        var result: Manifest = .{
            .state = .account_only,
            .active_slot = slot,
            .generation = generation,
            .expires_at = tokens.expires_at,
            .execution_high_watermark = execution_high_watermark,
        };
        @memcpy(result.scope_value[0..token_scope.len], token_scope);
        result.scope_len = token_scope.len;
        @memcpy(result.account_id[0..account_id.len], account_id);
        result.account_id_len = account_id.len;
        @memcpy(result.display_name[0..display_name.len], display_name);
        result.display_name_len = display_name.len;
        return result;
    }

    pub fn validate(self: *const Manifest) StoreError!void {
        if (self.version != 1) return error.ManifestCorrupt;
        switch (self.state) {
            .signed_out => {
                if (self.active_slot != null or
                    !std.mem.allEqual(u8, &self.generation, 0) or
                    self.expires_at != 0 or self.scope_len != 0 or
                    self.account_id_len != 0 or self.display_name_len != 0)
                    return error.ManifestCorrupt;
            },
            .account_only => {
                if (self.active_slot == null or
                    std.mem.allEqual(u8, &self.generation, 0) or
                    self.expires_at < 0 or
                    !std.mem.eql(u8, self.scopeView(), oauth.scope) or
                    self.account_id_len == 0 or
                    self.account_id_len > self.account_id.len or
                    self.display_name_len > self.display_name.len)
                    return error.ManifestCorrupt;
                if (!std.unicode.utf8ValidateSlice(
                    self.account_id[0..self.account_id_len],
                ) or !std.unicode.utf8ValidateSlice(
                    self.display_name[0..self.display_name_len],
                )) return error.ManifestCorrupt;
            },
        }
    }

    pub fn accountId(self: *const Manifest) []const u8 {
        return self.account_id[0..self.account_id_len];
    }

    pub fn displayName(self: *const Manifest) []const u8 {
        return self.display_name[0..self.display_name_len];
    }

    pub fn scopeView(self: *const Manifest) []const u8 {
        return self.scope_value[0..self.scope_len];
    }
};

pub const StoreError = error{
    ReadFailed,
    WriteFailed,
    DeleteFailed,
    ManifestCorrupt,
    PersistenceOutcomeUnknown,
    InvalidData,
    VerificationFailed,
};

pub const Backend = struct {
    context: *anyopaque,
    set_fn: *const fn (
        context: *anyopaque,
        key: CredentialKey,
        secret: []const u8,
    ) StoreError!void,
    get_fn: *const fn (
        context: *anyopaque,
        key: CredentialKey,
        output: []u8,
    ) StoreError!?[]const u8,
    delete_fn: *const fn (
        context: *anyopaque,
        key: CredentialKey,
    ) StoreError!void,
    load_manifest_fn: *const fn (
        context: *anyopaque,
    ) StoreError!?Manifest,
    commit_manifest_fn: *const fn (
        context: *anyopaque,
        manifest: Manifest,
    ) StoreError!void,

    fn set(
        self: Backend,
        key: CredentialKey,
        secret: []const u8,
    ) StoreError!void {
        return self.set_fn(self.context, key, secret);
    }

    fn get(
        self: Backend,
        key: CredentialKey,
        output: []u8,
    ) StoreError!?[]const u8 {
        return self.get_fn(self.context, key, output);
    }

    fn delete(self: Backend, key: CredentialKey) StoreError!void {
        return self.delete_fn(self.context, key);
    }

    fn loadManifest(self: Backend) StoreError!?Manifest {
        return self.load_manifest_fn(self.context);
    }

    fn commitManifest(
        self: Backend,
        manifest: Manifest,
    ) StoreError!void {
        return self.commit_manifest_fn(self.context, manifest);
    }
};

pub const CommitResult = struct {
    manifest: Manifest,
    retired_cleanup_pending: bool,
};

pub fn commitAccountOnly(
    backend: Backend,
    generation: Generation,
    tokens: *const oauth.TokenSet,
    identity: *const state.AccountIdentity,
    execution_high_watermark: u64,
) StoreError!CommitResult {
    if (std.mem.allEqual(u8, &generation, 0)) return error.InvalidData;
    const previous = try backend.loadManifest();
    if (previous) |manifest| try manifest.validate();
    const old_slot = if (previous) |manifest|
        if (manifest.state == .account_only) manifest.active_slot else null
    else
        null;
    const target = Slot.inactive(old_slot);
    clearSlot(backend, target) catch return error.DeleteFailed;
    var committed = false;
    defer if (!committed) clearSlot(backend, target) catch {};

    try backend.set(.{ .slot = target, .kind = .access }, tokens.access_token.view());
    try backend.set(.{ .slot = target, .kind = .refresh }, tokens.refresh_token.view());
    try backend.set(.{ .slot = target, .kind = .marker }, &generation);
    try verifySlot(backend, target, generation, tokens);

    const manifest = try Manifest.accountOnly(
        target,
        generation,
        tokens,
        identity,
        execution_high_watermark,
    );
    backend.commitManifest(manifest) catch |err| {
        if (err == error.PersistenceOutcomeUnknown)
            committed = true;
        return err;
    };
    committed = true;
    var cleanup_pending = false;
    if (old_slot) |slot| {
        clearSlot(backend, slot) catch {
            cleanup_pending = true;
        };
    }
    return .{
        .manifest = manifest,
        .retired_cleanup_pending = cleanup_pending,
    };
}

pub const RestoredAccount = struct {
    tokens: oauth.TokenSet,
    identity: state.AccountIdentity,
    execution_high_watermark: u64,
    cleanup_pending: bool,

    pub fn deinit(self: *RestoredAccount) void {
        self.tokens.deinit();
        self.* = undefined;
    }
};

pub const RestoreResult = union(enum) {
    signed_out: u64,
    account_only: RestoredAccount,
};

pub fn restore(
    allocator: std.mem.Allocator,
    backend: Backend,
) StoreError!RestoreResult {
    const loaded = try backend.loadManifest();
    if (loaded == null) {
        const cleanup_pending = clearAll(backend);
        if (cleanup_pending) return error.DeleteFailed;
        return .{ .signed_out = 0 };
    }
    const manifest = loaded.?;
    try manifest.validate();
    if (manifest.state == .signed_out) {
        _ = clearAll(backend);
        return .{ .signed_out = manifest.execution_high_watermark };
    }

    const slot = manifest.active_slot.?;
    var access_storage: [oauth.Limits.secret_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &access_storage);
    var refresh_storage: [oauth.Limits.secret_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &refresh_storage);
    var marker_storage: [oauth.Limits.secret_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &marker_storage);
    const access = try backend.get(
        .{ .slot = slot, .kind = .access },
        &access_storage,
    ) orelse return error.VerificationFailed;
    const refresh = try backend.get(
        .{ .slot = slot, .kind = .refresh },
        &refresh_storage,
    ) orelse return error.VerificationFailed;
    const marker = try backend.get(
        .{ .slot = slot, .kind = .marker },
        &marker_storage,
    ) orelse return error.VerificationFailed;
    if (!constantTimeEqual(marker, &manifest.generation))
        return error.VerificationFailed;

    var tokens = oauth.TokenSet.fromStored(
        allocator,
        access,
        refresh,
        manifest.expires_at,
        manifest.scopeView(),
        manifest.accountId(),
    ) catch return error.VerificationFailed;
    errdefer tokens.deinit();
    const identity = state.AccountIdentity.init(
        manifest.accountId(),
        manifest.displayName(),
    ) catch return error.ManifestCorrupt;
    var cleanup_pending = false;
    clearSlot(backend, Slot.inactive(slot)) catch {
        cleanup_pending = true;
    };
    return .{ .account_only = .{
        .tokens = tokens.take(),
        .identity = identity,
        .execution_high_watermark = manifest.execution_high_watermark,
        .cleanup_pending = cleanup_pending,
    } };
}

pub fn commitSignedOut(
    backend: Backend,
    execution_high_watermark: u64,
) StoreError!bool {
    try backend.commitManifest(Manifest.signedOut(execution_high_watermark));
    return clearAll(backend);
}

fn verifySlot(
    backend: Backend,
    slot: Slot,
    generation: Generation,
    tokens: *const oauth.TokenSet,
) StoreError!void {
    var buffer: [oauth.Limits.secret_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &buffer);
    const access = try backend.get(
        .{ .slot = slot, .kind = .access },
        &buffer,
    ) orelse return error.VerificationFailed;
    if (!constantTimeEqual(access, tokens.access_token.view()))
        return error.VerificationFailed;
    std.crypto.secureZero(u8, &buffer);
    const refresh = try backend.get(
        .{ .slot = slot, .kind = .refresh },
        &buffer,
    ) orelse return error.VerificationFailed;
    if (!constantTimeEqual(refresh, tokens.refresh_token.view()))
        return error.VerificationFailed;
    std.crypto.secureZero(u8, &buffer);
    const marker = try backend.get(
        .{ .slot = slot, .kind = .marker },
        &buffer,
    ) orelse return error.VerificationFailed;
    if (!constantTimeEqual(marker, &generation))
        return error.VerificationFailed;
}

fn clearSlot(backend: Backend, slot: Slot) StoreError!void {
    var first_error: ?StoreError = null;
    inline for (std.meta.tags(RecordKind)) |kind| {
        backend.delete(.{ .slot = slot, .kind = kind }) catch |err| {
            if (first_error == null) first_error = err;
        };
    }
    if (first_error) |err| return err;
}

fn clearAll(backend: Backend) bool {
    var failed = false;
    clearSlot(backend, .A) catch {
        failed = true;
    };
    clearSlot(backend, .B) catch {
        failed = true;
    };
    return failed;
}

fn constantTimeEqual(left: []const u8, right: []const u8) bool {
    var difference: usize = left.len ^ right.len;
    var index: usize = 0;
    while (index < oauth.Limits.secret_bytes) : (index += 1) {
        const left_byte: u8 = if (index < left.len) left[index] else 0;
        const right_byte: u8 = if (index < right.len) right[index] else 0;
        difference |= left_byte ^ right_byte;
    }
    return difference == 0;
}

const FakeBackend = struct {
    records: [2][3][oauth.Limits.secret_bytes]u8 = undefined,
    lengths: [2][3]usize = @splat(@splat(0)),
    manifest: ?Manifest = null,
    fail_set_number: ?usize = null,
    set_count: usize = 0,
    fail_manifest: bool = false,
    fail_delete: bool = false,

    fn backend(self: *FakeBackend) Backend {
        return .{
            .context = self,
            .set_fn = set,
            .get_fn = get,
            .delete_fn = delete,
            .load_manifest_fn = loadManifest,
            .commit_manifest_fn = commitManifest,
        };
    }

    fn indices(key: CredentialKey) struct { usize, usize } {
        return .{
            @intFromEnum(key.slot),
            @intFromEnum(key.kind),
        };
    }

    fn set(
        context: *anyopaque,
        key: CredentialKey,
        secret_value: []const u8,
    ) StoreError!void {
        const self: *FakeBackend = @ptrCast(@alignCast(context));
        self.set_count += 1;
        if (self.fail_set_number == self.set_count) return error.WriteFailed;
        if (secret_value.len > oauth.Limits.secret_bytes) return error.WriteFailed;
        const slot_index, const kind_index = indices(key);
        @memcpy(
            self.records[slot_index][kind_index][0..secret_value.len],
            secret_value,
        );
        self.lengths[slot_index][kind_index] = secret_value.len;
    }

    fn get(
        context: *anyopaque,
        key: CredentialKey,
        output: []u8,
    ) StoreError!?[]const u8 {
        const self: *FakeBackend = @ptrCast(@alignCast(context));
        const slot_index, const kind_index = indices(key);
        const len = self.lengths[slot_index][kind_index];
        if (len == 0) return null;
        if (len > output.len) return error.ReadFailed;
        @memcpy(output[0..len], self.records[slot_index][kind_index][0..len]);
        return output[0..len];
    }

    fn delete(
        context: *anyopaque,
        key: CredentialKey,
    ) StoreError!void {
        const self: *FakeBackend = @ptrCast(@alignCast(context));
        if (self.fail_delete) return error.DeleteFailed;
        const slot_index, const kind_index = indices(key);
        std.crypto.secureZero(
            u8,
            &self.records[slot_index][kind_index],
        );
        self.lengths[slot_index][kind_index] = 0;
    }

    fn loadManifest(context: *anyopaque) StoreError!?Manifest {
        const self: *FakeBackend = @ptrCast(@alignCast(context));
        return self.manifest;
    }

    fn commitManifest(
        context: *anyopaque,
        manifest: Manifest,
    ) StoreError!void {
        const self: *FakeBackend = @ptrCast(@alignCast(context));
        if (self.fail_manifest) return error.PersistenceOutcomeUnknown;
        self.manifest = manifest;
    }
};

fn testTokens(access: []const u8, refresh_token: []const u8) !oauth.TokenSet {
    return oauth.TokenSet.fromStored(
        std.testing.allocator,
        access,
        refresh_token,
        1234,
        oauth.scope,
        "acct-1",
    );
}

test "account-only commit stages fixed inactive slot then restores it" {
    var fake: FakeBackend = .{};
    var tokens = try testTokens("access", "refresh");
    defer tokens.deinit();
    const identity = try state.AccountIdentity.init("acct-1", "Metask User");
    const generation: Generation = @splat(0x2a);
    const committed = try commitAccountOnly(
        fake.backend(),
        generation,
        &tokens,
        &identity,
        7,
    );
    try std.testing.expectEqual(Slot.A, committed.manifest.active_slot.?);
    var restored = try restore(std.testing.allocator, fake.backend());
    defer switch (restored) {
        .account_only => |*account| account.deinit(),
        .signed_out => {},
    };
    try std.testing.expectEqualStrings(
        "access",
        restored.account_only.tokens.access_token.view(),
    );
    try std.testing.expectEqualStrings(
        "acct-1",
        restored.account_only.identity.accountId(),
    );
    try std.testing.expectEqual(@as(u64, 7), restored.account_only.execution_high_watermark);
}

test "failed staging cannot replace the previous committed slot" {
    var fake: FakeBackend = .{};
    var old_tokens = try testTokens("old-access", "old-refresh");
    defer old_tokens.deinit();
    const identity = try state.AccountIdentity.init("acct-1", "Metask User");
    _ = try commitAccountOnly(
        fake.backend(),
        @splat(0x11),
        &old_tokens,
        &identity,
        0,
    );
    var new_tokens = try testTokens("new-access", "new-refresh");
    defer new_tokens.deinit();
    fake.fail_set_number = fake.set_count + 2;
    try std.testing.expectError(
        error.WriteFailed,
        commitAccountOnly(
            fake.backend(),
            @splat(0x22),
            &new_tokens,
            &identity,
            0,
        ),
    );
    try std.testing.expectEqual(Slot.A, fake.manifest.?.active_slot.?);
    var restored = try restore(std.testing.allocator, fake.backend());
    defer restored.account_only.deinit();
    try std.testing.expectEqualStrings(
        "old-access",
        restored.account_only.tokens.access_token.view(),
    );
}

test "unknown manifest outcome retains the staged slot for restore reconciliation" {
    var fake: FakeBackend = .{ .fail_manifest = true };
    var tokens = try testTokens("access", "refresh");
    defer tokens.deinit();
    const identity = try state.AccountIdentity.init("acct-1", "Metask User");
    try std.testing.expectError(
        error.PersistenceOutcomeUnknown,
        commitAccountOnly(
            fake.backend(),
            @splat(0x44),
            &tokens,
            &identity,
            0,
        ),
    );
    try std.testing.expect(fake.lengths[@intFromEnum(Slot.A)][@intFromEnum(RecordKind.access)] > 0);
    try std.testing.expect(fake.lengths[@intFromEnum(Slot.A)][@intFromEnum(RecordKind.refresh)] > 0);
    try std.testing.expect(fake.lengths[@intFromEnum(Slot.A)][@intFromEnum(RecordKind.marker)] > 0);
}

test "logout tombstone wins even when credential cleanup fails" {
    var fake: FakeBackend = .{};
    var tokens = try testTokens("access", "refresh");
    defer tokens.deinit();
    const identity = try state.AccountIdentity.init("acct-1", "Metask User");
    _ = try commitAccountOnly(
        fake.backend(),
        @splat(0x33),
        &tokens,
        &identity,
        9,
    );
    fake.fail_delete = true;
    try std.testing.expect(try commitSignedOut(fake.backend(), 9));
    try std.testing.expectEqual(ManifestState.signed_out, fake.manifest.?.state);
    fake.fail_delete = false;
    const restored = try restore(std.testing.allocator, fake.backend());
    try std.testing.expectEqual(@as(u64, 9), restored.signed_out);
}
