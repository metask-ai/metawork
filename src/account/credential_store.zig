const std = @import("std");
const contract = @import("metawork_account_contract");
const state = @import("account_state");
const oauth = @import("account_oauth");

pub const persistence_revision: u8 = 2;
pub const service = std.fmt.comptimePrint(
    "dev.metawork.account.v{d}",
    .{persistence_revision},
);
pub const manifest_name = std.fmt.comptimePrint(
    "manifest.v{d}",
    .{persistence_revision},
);
pub const ProviderKind = contract.ProviderKind;

pub const Family = enum {
    oauth,
    execution,
};

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
    api_key,
    marker,
};

pub const CredentialKey = struct {
    family: Family = .oauth,
    slot: Slot,
    kind: RecordKind,

    pub fn account(self: CredentialKey) []const u8 {
        return switch (self.family) {
            .oauth => switch (self.slot) {
                .A => switch (self.kind) {
                    .access => "oauth/A/access",
                    .refresh => "oauth/A/refresh",
                    .marker => "oauth/A/marker",
                    .api_key => unreachable,
                },
                .B => switch (self.kind) {
                    .access => "oauth/B/access",
                    .refresh => "oauth/B/refresh",
                    .marker => "oauth/B/marker",
                    .api_key => unreachable,
                },
            },
            .execution => switch (self.slot) {
                .A => switch (self.kind) {
                    .api_key => "execution/A/api-key",
                    .marker => "execution/A/marker",
                    .access, .refresh => unreachable,
                },
                .B => switch (self.kind) {
                    .api_key => "execution/B/api-key",
                    .marker => "execution/B/marker",
                    .access, .refresh => unreachable,
                },
            },
        };
    }
};

pub const Generation = [16]u8;

pub const ManifestState = enum {
    signed_out,
    account_only,
    execution_ready,
};

pub const Manifest = struct {
    version: u8 = persistence_revision,
    state: ManifestState,
    active_slot: ?Slot = null,
    generation: Generation = @splat(0),
    expires_at: i64 = 0,
    scope_value: [oauth.Limits.scope_bytes]u8 = undefined,
    scope_len: usize = 0,
    account_id: [contract.Limits.account_id_bytes]u8 = undefined,
    account_id_len: usize = 0,
    profile_id: [contract.Limits.profile_id_bytes]u8 = undefined,
    profile_id_len: usize = 0,
    display_name: [contract.Limits.display_name_bytes]u8 = undefined,
    display_name_len: usize = 0,
    execution_slot: ?Slot = null,
    execution_credential_generation: Generation = @splat(0),
    api_key_id: [contract.Limits.api_key_id_bytes]u8 = undefined,
    api_key_id_len: usize = 0,
    provider_kind: ?contract.ProviderKind = null,
    model: [contract.Limits.model_id_bytes]u8 = undefined,
    model_len: usize = 0,
    base_url: [contract.Limits.base_url_bytes]u8 = undefined,
    base_url_len: usize = 0,
    execution_generation: u64 = 0,
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
        const profile_id = identity.profileId();
        const display_name = identity.displayName();
        const token_scope = tokens.scopeView();
        if (account_id.len == 0 or
            account_id.len > contract.Limits.account_id_bytes or
            profile_id.len == 0 or
            profile_id.len > contract.Limits.profile_id_bytes or
            display_name.len > contract.Limits.display_name_bytes or
            token_scope.len == 0 or token_scope.len > oauth.Limits.scope_bytes)
            return error.InvalidData;
        if (tokens.accountId().len > 0 and
            !std.mem.eql(u8, tokens.accountId(), account_id))
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
        @memcpy(result.profile_id[0..profile_id.len], profile_id);
        result.profile_id_len = profile_id.len;
        @memcpy(result.display_name[0..display_name.len], display_name);
        result.display_name_len = display_name.len;
        try result.validate();
        return result;
    }

    fn withOAuth(
        previous: ?Manifest,
        slot: Slot,
        generation_value: Generation,
        tokens: *const oauth.TokenSet,
        identity: *const state.AccountIdentity,
        execution_high_watermark: u64,
    ) StoreError!Manifest {
        var result = try accountOnly(
            slot,
            generation_value,
            tokens,
            identity,
            execution_high_watermark,
        );
        const prior = previous orelse return result;
        if (execution_high_watermark != prior.execution_high_watermark)
            return error.InvalidData;
        if (prior.state != .signed_out and
            (!std.mem.eql(u8, prior.accountId(), identity.accountId()) or
                !std.mem.eql(
                    u8,
                    prior.profileId(),
                    identity.profileId(),
                )))
            return error.InvalidData;
        if (prior.state != .execution_ready) return result;
        result.copyExecutionFrom(prior);
        try result.validate();
        return result;
    }

    pub fn executionReady(
        previous: Manifest,
        slot: Slot,
        credential_generation: Generation,
        api_key_id: []const u8,
        execution: *const contract.OwnedExecutionConfig,
    ) StoreError!Manifest {
        if (previous.state != .account_only and
            previous.state != .execution_ready)
            return error.InvalidData;
        if (std.mem.allEqual(u8, &credential_generation, 0) or
            api_key_id.len == 0 or
            api_key_id.len > contract.Limits.api_key_id_bytes)
            return error.InvalidData;
        const input = execution.input();
        contract.validateExecutionConfig(input) catch
            return error.InvalidData;
        if (previous.execution_high_watermark == std.math.maxInt(u64) or
            input.execution_generation !=
                previous.execution_high_watermark + 1)
            return error.InvalidData;

        var result = previous;
        result.state = .execution_ready;
        result.execution_slot = slot;
        result.execution_credential_generation = credential_generation;
        @memcpy(result.api_key_id[0..api_key_id.len], api_key_id);
        result.api_key_id_len = api_key_id.len;
        result.provider_kind = input.target.provider_kind;
        @memcpy(result.model[0..input.target.model.len], input.target.model);
        result.model_len = input.target.model.len;
        @memcpy(
            result.base_url[0..input.target.base_url.len],
            input.target.base_url,
        );
        result.base_url_len = input.target.base_url.len;
        result.execution_generation = input.execution_generation;
        result.execution_high_watermark = input.execution_generation;
        try result.validate();
        return result;
    }

    fn copyExecutionFrom(self: *Manifest, previous: Manifest) void {
        std.debug.assert(previous.state == .execution_ready);
        self.state = .execution_ready;
        self.execution_slot = previous.execution_slot;
        self.execution_credential_generation =
            previous.execution_credential_generation;
        @memcpy(
            self.api_key_id[0..previous.api_key_id_len],
            previous.apiKeyId(),
        );
        self.api_key_id_len = previous.api_key_id_len;
        self.provider_kind = previous.provider_kind;
        @memcpy(
            self.model[0..previous.model_len],
            previous.modelView(),
        );
        self.model_len = previous.model_len;
        @memcpy(
            self.base_url[0..previous.base_url_len],
            previous.baseUrl(),
        );
        self.base_url_len = previous.base_url_len;
        self.execution_generation = previous.execution_generation;
        self.execution_high_watermark = previous.execution_high_watermark;
    }

    pub fn validate(self: *const Manifest) StoreError!void {
        if (self.version != persistence_revision) return error.ManifestCorrupt;
        switch (self.state) {
            .signed_out => {
                if (self.active_slot != null or
                    !std.mem.allEqual(u8, &self.generation, 0) or
                    self.expires_at != 0 or self.scope_len != 0 or
                    self.account_id_len != 0 or self.profile_id_len != 0 or
                    self.display_name_len != 0 or
                    !self.executionFieldsEmpty())
                    return error.ManifestCorrupt;
            },
            .account_only => {
                if (!self.oauthFieldsValid() or
                    !self.executionFieldsEmpty())
                    return error.ManifestCorrupt;
            },
            .execution_ready => {
                if (!self.oauthFieldsValid() or
                    self.execution_slot == null or
                    std.mem.allEqual(
                        u8,
                        &self.execution_credential_generation,
                        0,
                    ) or
                    self.api_key_id_len == 0 or
                    self.api_key_id_len > self.api_key_id.len or
                    self.provider_kind == null or
                    self.model_len == 0 or self.model_len > self.model.len or
                    self.base_url_len == 0 or
                    self.base_url_len > self.base_url.len or
                    self.execution_generation == 0 or
                    self.execution_generation !=
                        self.execution_high_watermark)
                    return error.ManifestCorrupt;
                contract.validateExecutionConfig(.{
                    .target = .{
                        .provider_kind = self.provider_kind.?,
                        .model = self.modelView(),
                        .base_url = self.baseUrl(),
                    },
                    .api_key = "manifest-validation-placeholder",
                    .execution_generation = self.execution_generation,
                }) catch return error.ManifestCorrupt;
                if (!std.unicode.utf8ValidateSlice(self.apiKeyId()))
                    return error.ManifestCorrupt;
            },
        }
    }

    fn oauthFieldsValid(self: *const Manifest) bool {
        if (self.active_slot == null or
            std.mem.allEqual(u8, &self.generation, 0) or
            self.expires_at < 0 or
            !std.mem.eql(u8, self.scopeView(), oauth.scope) or
            self.account_id_len == 0 or
            self.account_id_len > self.account_id.len or
            self.profile_id_len == 0 or
            self.profile_id_len > self.profile_id.len or
            self.display_name_len > self.display_name.len)
            return false;
        return std.unicode.utf8ValidateSlice(self.accountId()) and
            std.unicode.utf8ValidateSlice(self.profileId()) and
            std.unicode.utf8ValidateSlice(self.displayName());
    }

    fn executionFieldsEmpty(self: *const Manifest) bool {
        return self.execution_slot == null and
            std.mem.allEqual(
                u8,
                &self.execution_credential_generation,
                0,
            ) and
            self.api_key_id_len == 0 and
            self.provider_kind == null and
            self.model_len == 0 and
            self.base_url_len == 0 and
            self.execution_generation == 0;
    }

    pub fn accountId(self: *const Manifest) []const u8 {
        return self.account_id[0..self.account_id_len];
    }

    pub fn displayName(self: *const Manifest) []const u8 {
        return self.display_name[0..self.display_name_len];
    }

    pub fn profileId(self: *const Manifest) []const u8 {
        return self.profile_id[0..self.profile_id_len];
    }

    pub fn apiKeyId(self: *const Manifest) []const u8 {
        return self.api_key_id[0..self.api_key_id_len];
    }

    pub fn modelView(self: *const Manifest) []const u8 {
        return self.model[0..self.model_len];
    }

    pub fn baseUrl(self: *const Manifest) []const u8 {
        return self.base_url[0..self.base_url_len];
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
        if (manifest.state != .signed_out) manifest.active_slot else null
    else
        null;
    const target = Slot.inactive(old_slot);
    const manifest = try Manifest.withOAuth(
        previous,
        target,
        generation,
        tokens,
        identity,
        execution_high_watermark,
    );
    clearSlot(backend, .oauth, target) catch return error.DeleteFailed;
    var committed = false;
    defer if (!committed) clearSlot(backend, .oauth, target) catch {};

    try backend.set(.{ .slot = target, .kind = .access }, tokens.access_token.view());
    try backend.set(.{ .slot = target, .kind = .refresh }, tokens.refresh_token.view());
    try backend.set(.{ .slot = target, .kind = .marker }, &generation);
    try verifySlot(backend, target, generation, tokens);

    backend.commitManifest(manifest) catch |err| {
        if (err == error.PersistenceOutcomeUnknown)
            committed = true;
        return err;
    };
    committed = true;
    var cleanup_pending = false;
    if (old_slot) |slot| {
        clearSlot(backend, .oauth, slot) catch {
            cleanup_pending = true;
        };
    }
    return .{
        .manifest = manifest,
        .retired_cleanup_pending = cleanup_pending,
    };
}

pub fn commitExecutionReady(
    backend: Backend,
    credential_generation: Generation,
    owner_account_id: []const u8,
    owner_profile_id: []const u8,
    api_key_id: []const u8,
    execution: *const contract.OwnedExecutionConfig,
) StoreError!CommitResult {
    if (std.mem.allEqual(u8, &credential_generation, 0))
        return error.InvalidData;
    const previous = (try backend.loadManifest()) orelse
        return error.InvalidData;
    try previous.validate();
    if (previous.state == .signed_out) return error.InvalidData;
    if (!std.mem.eql(u8, previous.accountId(), owner_account_id) or
        !std.mem.eql(u8, previous.profileId(), owner_profile_id))
        return error.InvalidData;
    const old_slot = if (previous.state == .execution_ready)
        previous.execution_slot
    else
        null;
    const target = Slot.inactive(old_slot);
    const manifest = try Manifest.executionReady(
        previous,
        target,
        credential_generation,
        api_key_id,
        execution,
    );
    clearSlot(backend, .execution, target) catch
        return error.DeleteFailed;
    var committed = false;
    defer if (!committed)
        clearSlot(backend, .execution, target) catch {};

    const input = execution.input();
    try backend.set(.{
        .family = .execution,
        .slot = target,
        .kind = .api_key,
    }, input.api_key);
    try backend.set(.{
        .family = .execution,
        .slot = target,
        .kind = .marker,
    }, &credential_generation);
    try verifyExecutionSlot(
        backend,
        target,
        credential_generation,
        input.api_key,
    );

    backend.commitManifest(manifest) catch |err| {
        if (err == error.PersistenceOutcomeUnknown)
            committed = true;
        return err;
    };
    committed = true;
    var cleanup_pending = false;
    if (old_slot) |slot| {
        clearSlot(backend, .execution, slot) catch {
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

pub const RestoredSignedOut = struct {
    execution_high_watermark: u64,
    cleanup_pending: bool,
};

pub const RestoredExecution = struct {
    tokens: oauth.TokenSet,
    identity: state.AccountIdentity,
    api_key_id: [contract.Limits.api_key_id_bytes]u8 = undefined,
    api_key_id_len: usize,
    execution: contract.OwnedExecutionConfig,
    cleanup_pending: bool,

    pub fn apiKeyId(self: *const RestoredExecution) []const u8 {
        return self.api_key_id[0..self.api_key_id_len];
    }

    pub fn deinit(self: *RestoredExecution) void {
        self.tokens.deinit();
        self.execution.deinit();
        self.* = undefined;
    }
};

pub const RestoreResult = union(enum) {
    signed_out: RestoredSignedOut,
    account_only: RestoredAccount,
    execution_ready: RestoredExecution,
};

pub fn restore(
    allocator: std.mem.Allocator,
    backend: Backend,
) StoreError!RestoreResult {
    const loaded = try backend.loadManifest();
    if (loaded == null) {
        const cleanup_pending = clearAll(backend);
        if (cleanup_pending) return error.DeleteFailed;
        return .{ .signed_out = .{
            .execution_high_watermark = 0,
            .cleanup_pending = false,
        } };
    }
    const manifest = loaded.?;
    try manifest.validate();
    if (manifest.state == .signed_out) {
        return .{ .signed_out = .{
            .execution_high_watermark = manifest.execution_high_watermark,
            .cleanup_pending = clearAll(backend),
        } };
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
        manifest.profileId(),
        manifest.displayName(),
    ) catch return error.ManifestCorrupt;
    var cleanup_pending = false;
    clearSlot(backend, .oauth, Slot.inactive(slot)) catch {
        cleanup_pending = true;
    };
    if (manifest.state == .account_only) {
        clearSlot(backend, .execution, .A) catch {
            cleanup_pending = true;
        };
        clearSlot(backend, .execution, .B) catch {
            cleanup_pending = true;
        };
        return .{ .account_only = .{
            .tokens = tokens.take(),
            .identity = identity,
            .execution_high_watermark = manifest.execution_high_watermark,
            .cleanup_pending = cleanup_pending,
        } };
    }

    const execution_slot = manifest.execution_slot.?;
    var api_key_storage: [contract.Limits.api_key_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &api_key_storage);
    const api_key = try backend.get(.{
        .family = .execution,
        .slot = execution_slot,
        .kind = .api_key,
    }, &api_key_storage) orelse return error.VerificationFailed;
    std.crypto.secureZero(u8, &marker_storage);
    const execution_marker = try backend.get(.{
        .family = .execution,
        .slot = execution_slot,
        .kind = .marker,
    }, &marker_storage) orelse return error.VerificationFailed;
    if (!constantTimeEqual(
        execution_marker,
        &manifest.execution_credential_generation,
    )) return error.VerificationFailed;
    var owned_model: ?[]u8 = allocator.dupe(
        u8,
        manifest.modelView(),
    ) catch return error.ReadFailed;
    errdefer if (owned_model) |bytes| allocator.free(bytes);
    var owned_base_url: ?[]u8 = allocator.dupe(
        u8,
        manifest.baseUrl(),
    ) catch return error.ReadFailed;
    errdefer if (owned_base_url) |bytes| allocator.free(bytes);
    const owned_api_key = allocator.dupe(
        u8,
        api_key,
    ) catch return error.ReadFailed;
    const transferred_model = owned_model.?;
    const transferred_base_url = owned_base_url.?;
    owned_model = null;
    owned_base_url = null;
    var execution = contract.OwnedExecutionConfig.initOwned(
        allocator,
        manifest.provider_kind.?,
        transferred_model,
        transferred_base_url,
        manifest.execution_generation,
        owned_api_key,
    ) catch return error.ManifestCorrupt;
    errdefer execution.deinit();
    clearSlot(
        backend,
        .execution,
        Slot.inactive(execution_slot),
    ) catch {
        cleanup_pending = true;
    };
    var restored: RestoredExecution = .{
        .tokens = tokens.take(),
        .identity = identity,
        .api_key_id_len = manifest.api_key_id_len,
        .execution = execution.take(),
        .cleanup_pending = cleanup_pending,
    };
    @memcpy(
        restored.api_key_id[0..manifest.api_key_id_len],
        manifest.apiKeyId(),
    );
    return .{ .execution_ready = restored };
}

pub fn commitSignedOut(
    backend: Backend,
    execution_high_watermark: u64,
) StoreError!bool {
    if (try backend.loadManifest()) |previous| {
        try previous.validate();
        if (previous.execution_high_watermark !=
            execution_high_watermark)
            return error.InvalidData;
    }
    try backend.commitManifest(Manifest.signedOut(execution_high_watermark));
    return clearAll(backend);
}

/// Retries only deletion work that is provably retired by the committed
/// manifest. The active OAuth and Execution slots are never touched.
pub fn cleanupRetiredCredentials(
    backend: Backend,
) StoreError!bool {
    const loaded = try backend.loadManifest();
    if (loaded == null) return clearAll(backend);
    const manifest = loaded.?;
    try manifest.validate();
    if (manifest.state == .signed_out) return clearAll(backend);

    var cleanup_pending = false;
    clearSlot(
        backend,
        .oauth,
        Slot.inactive(manifest.active_slot.?),
    ) catch {
        cleanup_pending = true;
    };
    switch (manifest.state) {
        .signed_out => unreachable,
        .account_only => {
            clearSlot(backend, .execution, .A) catch {
                cleanup_pending = true;
            };
            clearSlot(backend, .execution, .B) catch {
                cleanup_pending = true;
            };
        },
        .execution_ready => clearSlot(
            backend,
            .execution,
            Slot.inactive(manifest.execution_slot.?),
        ) catch {
            cleanup_pending = true;
        },
    }
    return cleanup_pending;
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

fn verifyExecutionSlot(
    backend: Backend,
    slot: Slot,
    generation: Generation,
    api_key: []const u8,
) StoreError!void {
    var buffer: [contract.Limits.api_key_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &buffer);
    const stored_key = try backend.get(.{
        .family = .execution,
        .slot = slot,
        .kind = .api_key,
    }, &buffer) orelse return error.VerificationFailed;
    if (!constantTimeEqual(stored_key, api_key))
        return error.VerificationFailed;
    std.crypto.secureZero(u8, &buffer);
    const marker = try backend.get(.{
        .family = .execution,
        .slot = slot,
        .kind = .marker,
    }, &buffer) orelse return error.VerificationFailed;
    if (!constantTimeEqual(marker, &generation))
        return error.VerificationFailed;
}

fn clearSlot(
    backend: Backend,
    family: Family,
    slot: Slot,
) StoreError!void {
    var first_error: ?StoreError = null;
    const kinds: []const RecordKind = switch (family) {
        .oauth => &.{ .access, .refresh, .marker },
        .execution => &.{ .api_key, .marker },
    };
    for (kinds) |kind| {
        backend.delete(.{
            .family = family,
            .slot = slot,
            .kind = kind,
        }) catch |err| {
            if (first_error == null) first_error = err;
        };
    }
    if (first_error) |err| return err;
}

fn clearAll(backend: Backend) bool {
    var failed = false;
    inline for (std.meta.tags(Family)) |family| {
        inline for (std.meta.tags(Slot)) |slot| {
            clearSlot(backend, family, slot) catch {
                failed = true;
            };
        }
    }
    return failed;
}

fn constantTimeEqual(left: []const u8, right: []const u8) bool {
    var difference: usize = left.len ^ right.len;
    var index: usize = 0;
    while (index < contract.Limits.api_key_bytes) : (index += 1) {
        const left_byte: u8 = if (index < left.len) left[index] else 0;
        const right_byte: u8 = if (index < right.len) right[index] else 0;
        difference |= left_byte ^ right_byte;
    }
    return difference == 0;
}

const FakeBackend = struct {
    records: [2][2][4][contract.Limits.api_key_bytes]u8 = undefined,
    lengths: [2][2][4]usize = @splat(@splat(@splat(0))),
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

    fn indices(key: CredentialKey) struct { usize, usize, usize } {
        return .{
            @intFromEnum(key.family),
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
        if (secret_value.len > contract.Limits.api_key_bytes)
            return error.WriteFailed;
        const family_index, const slot_index, const kind_index = indices(key);
        @memcpy(
            self.records[family_index][slot_index][kind_index][0..secret_value.len],
            secret_value,
        );
        self.lengths[family_index][slot_index][kind_index] = secret_value.len;
    }

    fn get(
        context: *anyopaque,
        key: CredentialKey,
        output: []u8,
    ) StoreError!?[]const u8 {
        const self: *FakeBackend = @ptrCast(@alignCast(context));
        const family_index, const slot_index, const kind_index = indices(key);
        const len = self.lengths[family_index][slot_index][kind_index];
        if (len == 0) return null;
        if (len > output.len) return error.ReadFailed;
        @memcpy(
            output[0..len],
            self.records[family_index][slot_index][kind_index][0..len],
        );
        return output[0..len];
    }

    fn delete(
        context: *anyopaque,
        key: CredentialKey,
    ) StoreError!void {
        const self: *FakeBackend = @ptrCast(@alignCast(context));
        if (self.fail_delete) return error.DeleteFailed;
        const family_index, const slot_index, const kind_index = indices(key);
        std.crypto.secureZero(
            u8,
            &self.records[family_index][slot_index][kind_index],
        );
        self.lengths[family_index][slot_index][kind_index] = 0;
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
        try manifest.validate();
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

fn testExecution(
    generation: u64,
    api_key: []const u8,
) !contract.OwnedExecutionConfig {
    return contract.OwnedExecutionConfig.initOwned(
        std.testing.allocator,
        .anthropic,
        try std.testing.allocator.dupe(u8, "model-1"),
        try std.testing.allocator.dupe(
            u8,
            contract.metask_anthropic_messages_url,
        ),
        generation,
        try std.testing.allocator.dupe(u8, api_key),
    );
}

test "account-only commit stages fixed inactive slot then restores it" {
    var fake: FakeBackend = .{};
    var tokens = try testTokens("access", "refresh");
    defer tokens.deinit();
    const identity = try state.AccountIdentity.init(
        "acct-1",
        "profile-1",
        "Metask User",
    );
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
        .execution_ready => |*execution| execution.deinit(),
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
    const identity = try state.AccountIdentity.init(
        "acct-1",
        "profile-1",
        "Metask User",
    );
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
    const identity = try state.AccountIdentity.init(
        "acct-1",
        "profile-1",
        "Metask User",
    );
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
    try std.testing.expect(
        fake.lengths[@intFromEnum(Family.oauth)][@intFromEnum(Slot.A)][@intFromEnum(RecordKind.access)] > 0,
    );
    try std.testing.expect(
        fake.lengths[@intFromEnum(Family.oauth)][@intFromEnum(Slot.A)][@intFromEnum(RecordKind.refresh)] > 0,
    );
    try std.testing.expect(
        fake.lengths[@intFromEnum(Family.oauth)][@intFromEnum(Slot.A)][@intFromEnum(RecordKind.marker)] > 0,
    );
}

test "logout tombstone wins even when credential cleanup fails" {
    var fake: FakeBackend = .{};
    var tokens = try testTokens("access", "refresh");
    defer tokens.deinit();
    const identity = try state.AccountIdentity.init(
        "acct-1",
        "profile-1",
        "Metask User",
    );
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
    const pending = try restore(std.testing.allocator, fake.backend());
    try std.testing.expectEqual(
        @as(u64, 9),
        pending.signed_out.execution_high_watermark,
    );
    try std.testing.expect(pending.signed_out.cleanup_pending);
    fake.fail_delete = false;
    const restored = try restore(std.testing.allocator, fake.backend());
    try std.testing.expectEqual(
        @as(u64, 9),
        restored.signed_out.execution_high_watermark,
    );
    try std.testing.expect(!restored.signed_out.cleanup_pending);
}

test "execution commit atomically restores OAuth identity and AgentCore target" {
    var fake: FakeBackend = .{};
    var tokens = try testTokens("access", "refresh");
    defer tokens.deinit();
    const identity = try state.AccountIdentity.init(
        "acct-1",
        "profile-1",
        "Metask User",
    );
    _ = try commitAccountOnly(
        fake.backend(),
        @splat(0x11),
        &tokens,
        &identity,
        0,
    );
    var execution = try testExecution(1, "execution-api-key-1");
    defer execution.deinit();
    const committed = try commitExecutionReady(
        fake.backend(),
        @splat(0x22),
        "acct-1",
        "profile-1",
        "325",
        &execution,
    );
    try std.testing.expectEqual(
        ManifestState.execution_ready,
        committed.manifest.state,
    );
    try std.testing.expectEqual(Slot.A, committed.manifest.execution_slot.?);

    var restored = try restore(std.testing.allocator, fake.backend());
    defer restored.execution_ready.deinit();
    try std.testing.expectEqualStrings(
        "access",
        restored.execution_ready.tokens.access_token.view(),
    );
    try std.testing.expectEqualStrings(
        "profile-1",
        restored.execution_ready.identity.profileId(),
    );
    try std.testing.expectEqualStrings(
        "325",
        restored.execution_ready.apiKeyId(),
    );
    try std.testing.expectEqualStrings(
        "execution-api-key-1",
        restored.execution_ready.execution.input().api_key,
    );
    try std.testing.expectEqualStrings(
        contract.metask_anthropic_messages_url,
        restored.execution_ready.execution.input().target.base_url,
    );
}

test "OAuth rotation preserves the committed execution family" {
    var fake: FakeBackend = .{};
    const identity = try state.AccountIdentity.init(
        "acct-1",
        "profile-1",
        "Metask User",
    );
    var old_tokens = try testTokens("old-access", "old-refresh");
    defer old_tokens.deinit();
    _ = try commitAccountOnly(
        fake.backend(),
        @splat(0x11),
        &old_tokens,
        &identity,
        0,
    );
    var execution = try testExecution(1, "execution-api-key-1");
    defer execution.deinit();
    _ = try commitExecutionReady(
        fake.backend(),
        @splat(0x22),
        "acct-1",
        "profile-1",
        "325",
        &execution,
    );
    const execution_slot = fake.manifest.?.execution_slot;

    var new_tokens = try testTokens("new-access", "new-refresh");
    defer new_tokens.deinit();
    const refreshed = try commitAccountOnly(
        fake.backend(),
        @splat(0x33),
        &new_tokens,
        &identity,
        1,
    );
    try std.testing.expectEqual(
        ManifestState.execution_ready,
        refreshed.manifest.state,
    );
    try std.testing.expectEqual(
        execution_slot,
        refreshed.manifest.execution_slot,
    );
    var restored = try restore(std.testing.allocator, fake.backend());
    defer restored.execution_ready.deinit();
    try std.testing.expectEqualStrings(
        "new-access",
        restored.execution_ready.tokens.access_token.view(),
    );
    try std.testing.expectEqualStrings(
        "execution-api-key-1",
        restored.execution_ready.execution.input().api_key,
    );
}

test "failed execution staging cannot replace committed generation" {
    var fake: FakeBackend = .{};
    var tokens = try testTokens("access", "refresh");
    defer tokens.deinit();
    const identity = try state.AccountIdentity.init(
        "acct-1",
        "profile-1",
        "Metask User",
    );
    _ = try commitAccountOnly(
        fake.backend(),
        @splat(0x11),
        &tokens,
        &identity,
        0,
    );
    var old_execution = try testExecution(1, "old-execution-key");
    defer old_execution.deinit();
    _ = try commitExecutionReady(
        fake.backend(),
        @splat(0x22),
        "acct-1",
        "profile-1",
        "325",
        &old_execution,
    );
    var new_execution = try testExecution(2, "new-execution-key");
    defer new_execution.deinit();
    fake.fail_set_number = fake.set_count + 2;
    try std.testing.expectError(
        error.WriteFailed,
        commitExecutionReady(
            fake.backend(),
            @splat(0x33),
            "acct-1",
            "profile-1",
            "326",
            &new_execution,
        ),
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        fake.manifest.?.execution_generation,
    );
    var restored = try restore(std.testing.allocator, fake.backend());
    defer restored.execution_ready.deinit();
    try std.testing.expectEqualStrings(
        "old-execution-key",
        restored.execution_ready.execution.input().api_key,
    );
}

test "unknown execution manifest outcome retains staged slot" {
    var fake: FakeBackend = .{};
    var tokens = try testTokens("access", "refresh");
    defer tokens.deinit();
    const identity = try state.AccountIdentity.init(
        "acct-1",
        "profile-1",
        "Metask User",
    );
    _ = try commitAccountOnly(
        fake.backend(),
        @splat(0x11),
        &tokens,
        &identity,
        0,
    );
    var execution = try testExecution(1, "execution-api-key-1");
    defer execution.deinit();
    fake.fail_manifest = true;
    try std.testing.expectError(
        error.PersistenceOutcomeUnknown,
        commitExecutionReady(
            fake.backend(),
            @splat(0x22),
            "acct-1",
            "profile-1",
            "325",
            &execution,
        ),
    );
    try std.testing.expect(
        fake.lengths[@intFromEnum(Family.execution)][@intFromEnum(Slot.A)][@intFromEnum(RecordKind.api_key)] > 0,
    );
    try std.testing.expect(
        fake.lengths[@intFromEnum(Family.execution)][@intFromEnum(Slot.A)][@intFromEnum(RecordKind.marker)] > 0,
    );
}

test "restore rejects partial committed execution slot" {
    var fake: FakeBackend = .{};
    var tokens = try testTokens("access", "refresh");
    defer tokens.deinit();
    const identity = try state.AccountIdentity.init(
        "acct-1",
        "profile-1",
        "Metask User",
    );
    _ = try commitAccountOnly(
        fake.backend(),
        @splat(0x11),
        &tokens,
        &identity,
        0,
    );
    var execution = try testExecution(1, "execution-api-key-1");
    defer execution.deinit();
    _ = try commitExecutionReady(
        fake.backend(),
        @splat(0x22),
        "acct-1",
        "profile-1",
        "325",
        &execution,
    );
    try fake.backend().delete(.{
        .family = .execution,
        .slot = fake.manifest.?.execution_slot.?,
        .kind = .marker,
    });
    try std.testing.expectError(
        error.VerificationFailed,
        restore(std.testing.allocator, fake.backend()),
    );
}

test "store rejects identity mixing and generation rollback before staging" {
    var fake: FakeBackend = .{};
    var tokens = try testTokens("access", "refresh");
    defer tokens.deinit();
    const identity = try state.AccountIdentity.init(
        "acct-1",
        "profile-1",
        "Metask User",
    );
    _ = try commitAccountOnly(
        fake.backend(),
        @splat(0x11),
        &tokens,
        &identity,
        7,
    );
    const set_count = fake.set_count;
    try std.testing.expectError(
        error.InvalidData,
        commitAccountOnly(
            fake.backend(),
            @splat(0x22),
            &tokens,
            &identity,
            6,
        ),
    );
    const other_profile = try state.AccountIdentity.init(
        "acct-1",
        "profile-2",
        "Other Profile",
    );
    try std.testing.expectError(
        error.InvalidData,
        commitAccountOnly(
            fake.backend(),
            @splat(0x22),
            &tokens,
            &other_profile,
            7,
        ),
    );
    try std.testing.expectEqual(set_count, fake.set_count);
    try std.testing.expectError(
        error.InvalidData,
        commitSignedOut(fake.backend(), 6),
    );

    var execution = try testExecution(8, "execution-api-key-1");
    defer execution.deinit();
    try std.testing.expectError(
        error.InvalidData,
        commitExecutionReady(
            fake.backend(),
            @splat(0x33),
            "acct-1",
            "profile-2",
            "325",
            &execution,
        ),
    );
    try std.testing.expectEqual(set_count, fake.set_count);
}

test "logout tombstone retires both committed credential families" {
    var fake: FakeBackend = .{};
    var tokens = try testTokens("access", "refresh");
    defer tokens.deinit();
    const identity = try state.AccountIdentity.init(
        "acct-1",
        "profile-1",
        "Metask User",
    );
    _ = try commitAccountOnly(
        fake.backend(),
        @splat(0x11),
        &tokens,
        &identity,
        0,
    );
    var execution = try testExecution(1, "execution-api-key-1");
    defer execution.deinit();
    _ = try commitExecutionReady(
        fake.backend(),
        @splat(0x22),
        "acct-1",
        "profile-1",
        "325",
        &execution,
    );
    try std.testing.expect(!try commitSignedOut(fake.backend(), 1));
    try std.testing.expectEqual(
        ManifestState.signed_out,
        fake.manifest.?.state,
    );
    for (fake.lengths) |family| {
        for (family) |slot| {
            for (slot) |length| {
                try std.testing.expectEqual(@as(usize, 0), length);
            }
        }
    }
    const restored = try restore(std.testing.allocator, fake.backend());
    try std.testing.expectEqual(
        @as(u64, 1),
        restored.signed_out.execution_high_watermark,
    );
}

test "retired cleanup never deletes the committed OAuth slot" {
    var fake: FakeBackend = .{};
    var tokens = try testTokens("access", "refresh");
    defer tokens.deinit();
    const identity = try state.AccountIdentity.init(
        "acct-1",
        "profile-1",
        "Metask User",
    );
    _ = try commitAccountOnly(
        fake.backend(),
        @splat(0x11),
        &tokens,
        &identity,
        0,
    );
    const active = fake.manifest.?.active_slot.?;
    const retired = Slot.inactive(active);
    try fake.backend().set(.{
        .family = .oauth,
        .slot = retired,
        .kind = .access,
    }, "retired-access");
    try fake.backend().set(.{
        .family = .oauth,
        .slot = retired,
        .kind = .refresh,
    }, "retired-refresh");
    try fake.backend().set(.{
        .family = .oauth,
        .slot = retired,
        .kind = .marker,
    }, &@as(Generation, @splat(0x44)));
    try fake.backend().set(.{
        .family = .execution,
        .slot = .A,
        .kind = .api_key,
    }, "retired-api-key");
    try fake.backend().set(.{
        .family = .execution,
        .slot = .A,
        .kind = .marker,
    }, &@as(Generation, @splat(0x55)));

    try std.testing.expect(
        !try cleanupRetiredCredentials(fake.backend()),
    );
    var buffer: [contract.Limits.api_key_bytes]u8 = undefined;
    try std.testing.expect((try fake.backend().get(.{
        .family = .oauth,
        .slot = active,
        .kind = .access,
    }, &buffer)) != null);
    try std.testing.expect((try fake.backend().get(.{
        .family = .oauth,
        .slot = retired,
        .kind = .access,
    }, &buffer)) == null);
    try std.testing.expect((try fake.backend().get(.{
        .family = .execution,
        .slot = .A,
        .kind = .api_key,
    }, &buffer)) == null);
}
