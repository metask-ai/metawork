//! App-owned MCP platform composition. This module resolves system credential
//! locators on the Native main thread and constructs concrete stdio or
//! preauthorized HTTP transport owners. It does not interpret MCP payloads.

const std = @import("std");
const http_execution = @import("app_http_transport");
const select_start = @import("app_select_start");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const agent = @import("metawork_agent");
const mcp_configuration = @import("metawork_product_mcp").contract;
const mcp_oauth = @import("metawork_mcp_oauth");
const product_identity = @import("metawork_product_identity");
const process_compat = @import("metawork_mcp_process_compat");
const quarantine_compat = @import("metawork_mcp_quarantine_compat");
const catalog_budget = @import("mcp_catalog_budget.zig");
const process_observation = @import("mcp_process_observation.zig");
pub const StdioObservations = process_observation.Collection;
pub const CatalogBudget = catalog_budget.Budget;

// Shared by formal connections and disposable test Runtime connections.
// Core-internal process creation cannot participate in this lock.
var windows_spawn_mutex: std.Io.Mutex = .init;

pub const credential_service = product_identity.mcpCredentialService();
pub const max_credential_secret_bytes = native_sdk.platform.max_credential_secret_bytes;
const client_name = "MetaWork";
const client_version = product_identity.version;
const max_custom_headers: usize = 128;
const stdio_io_buffer_bytes: usize = 4096;
const max_stdio_argv_count: usize = 129;
const max_stdio_argv_bytes: usize = 64 * 1024;

pub fn quarantineMove() mcp_configuration.QuarantineMove {
    return .{ .move_fn = moveQuarantine };
}

fn moveQuarantine(io: std.Io, source: std.Io.Dir, target: std.Io.Dir, request: mcp_configuration.QuarantineMove.Request) mcp_configuration.FileStoreError!void {
    var storage: [25]u8 = undefined;
    const source_name = request.sourceName();
    const target_name = request.targetName(&storage);
    if (builtin.os.tag == .macos) {
        quarantine_compat.move(io, source, source_name, target, target_name) catch return error.WriteFailed;
    } else {
        source.renamePreserve(source_name, target, target_name, io) catch return error.WriteFailed;
    }
}

pub const CredentialStore = struct {
    io: std.Io,
    runtime: *native_sdk.Runtime,
    main_thread_id: std.Thread.Id,

    pub fn resolver(self: *CredentialStore) mcp_configuration.CredentialResolver {
        return .{
            .context = self,
            .available = self.runtime.options.platform.services.get_credential_fn != null,
            .resolve_fn = resolve,
        };
    }

    pub fn resolveSecret(
        self: *CredentialStore,
        allocator: std.mem.Allocator,
        locator: []const u8,
    ) mcp_configuration.CredentialResolution {
        return resolve(self, allocator, locator);
    }

    pub fn cleanup(self: *CredentialStore) mcp_configuration.CredentialCleanup {
        return .{
            .context = self,
            .available = self.runtime.options.platform.services.delete_credential_fn != null,
            .delete_fn = delete,
        };
    }

    pub fn effects(self: *CredentialStore) mcp_configuration.CredentialEffects {
        return .{
            .context = self,
            .available = self.runtime.options.platform.services.get_credential_fn != null and
                self.runtime.options.platform.services.set_credential_fn != null and
                self.runtime.options.platform.services.delete_credential_fn != null,
            .probe_fn = probe,
            .create_fn = create,
            .delete_fn = delete,
        };
    }

    pub fn locatorGenerator(self: *CredentialStore) mcp_configuration.FreshLocatorGenerator {
        return .{
            .context = self,
            .available = true,
            .fill_fn = fillLocatorEntropy,
        };
    }

    pub fn serverIdentityGenerator(self: *CredentialStore) mcp_configuration.FreshServerIdentityGenerator {
        return .{
            .context = self,
            .available = true,
            .fill_fn = fillLocatorEntropy,
        };
    }

    fn fillLocatorEntropy(context: ?*anyopaque, output: *[16]u8) bool {
        const self: *CredentialStore = @ptrCast(@alignCast(context orelse return false));
        if (std.Thread.getCurrentId() != self.main_thread_id) return false;
        std.Io.randomSecure(self.io, output) catch return false;
        return true;
    }

    fn resolve(
        context: ?*anyopaque,
        allocator: std.mem.Allocator,
        locator: []const u8,
    ) mcp_configuration.CredentialResolution {
        const self: *CredentialStore = @ptrCast(@alignCast(context orelse return .unavailable));
        if (std.Thread.getCurrentId() != self.main_thread_id)
            return .unavailable;
        var storage: [native_sdk.platform.max_credential_secret_bytes]u8 = undefined;
        defer std.crypto.secureZero(u8, &storage);
        const value = (self.runtime.getCredential(.{
            .service = credential_service,
            .account = locator,
        }, &storage) catch return .unavailable) orelse return .missing;
        return .{ .value = allocator.dupe(u8, value) catch return .out_of_memory };
    }

    fn probe(
        context: ?*anyopaque,
        locator: []const u8,
    ) mcp_configuration.CredentialPresence {
        const self: *CredentialStore = @ptrCast(@alignCast(context orelse return .unavailable));
        if (std.Thread.getCurrentId() != self.main_thread_id)
            return .unavailable;
        var storage: [native_sdk.platform.max_credential_secret_bytes]u8 = undefined;
        defer std.crypto.secureZero(u8, &storage);
        _ = (self.runtime.getCredential(.{
            .service = credential_service,
            .account = locator,
        }, &storage) catch return .unavailable) orelse return .missing;
        return .present;
    }

    fn create(
        context: ?*anyopaque,
        locator: []const u8,
        secret: []const u8,
    ) bool {
        const self: *CredentialStore = @ptrCast(@alignCast(context orelse return false));
        if (std.Thread.getCurrentId() != self.main_thread_id or
            secret.len == 0 or
            secret.len > native_sdk.platform.max_credential_secret_bytes or
            probe(context, locator) != .missing)
            return false;
        self.runtime.setCredential(.{
            .service = credential_service,
            .account = locator,
            .secret = secret,
        }) catch return false;
        return true;
    }

    fn delete(context: ?*anyopaque, locator: []const u8) bool {
        const self: *CredentialStore = @ptrCast(@alignCast(context orelse return false));
        if (std.Thread.getCurrentId() != self.main_thread_id) return false;
        _ = self.runtime.deleteCredential(.{
            .service = credential_service,
            .account = locator,
        }) catch return false;
        return true;
    }
};

pub const BuildError = std.mem.Allocator.Error || error{InvalidConfig};

pub const HttpTokenUpdate = struct {
    access_token: []const u8,
    refresh_token: ?[]const u8 = null,
};

const HttpAuthSecrets = struct {
    access_token: []const u8,
    refresh_token: ?[]const u8 = null,
    client_secret: ?[]const u8 = null,
};

const HttpAuthSnapshot = struct {
    allocator: std.mem.Allocator,
    references: std.atomic.Value(usize) = .init(1),
    consent_epoch: u64,
    token_revision: u64,
    access_token: []u8,
    refresh_token: ?[]u8,
    client_secret: ?[]u8,
    next: ?*HttpAuthSnapshot = null,

    fn create(
        allocator: std.mem.Allocator,
        consent_epoch: u64,
        token_revision: u64,
        secrets: HttpAuthSecrets,
    ) std.mem.Allocator.Error!*HttpAuthSnapshot {
        const self = try allocator.create(HttpAuthSnapshot);
        errdefer allocator.destroy(self);
        const access = try allocator.dupe(u8, secrets.access_token);
        errdefer secureFree(allocator, access);
        const refresh = if (secrets.refresh_token) |value| try allocator.dupe(u8, value) else null;
        errdefer if (refresh) |value| secureFree(allocator, value);
        const client = if (secrets.client_secret) |value| try allocator.dupe(u8, value) else null;
        self.* = .{
            .allocator = allocator,
            .consent_epoch = consent_epoch,
            .token_revision = token_revision,
            .access_token = access,
            .refresh_token = refresh,
            .client_secret = client,
        };
        return self;
    }

    fn retain(self: *HttpAuthSnapshot) void {
        const previous = self.references.fetchAdd(1, .acq_rel);
        std.debug.assert(previous != 0 and previous != std.math.maxInt(usize));
    }

    fn release(self: *HttpAuthSnapshot) void {
        const previous = self.references.fetchSub(1, .acq_rel);
        std.debug.assert(previous != 0);
        if (previous != 1) return;
        std.crypto.secureZero(u8, self.access_token);
        self.allocator.free(self.access_token);
        if (self.refresh_token) |secret| secureFree(self.allocator, secret);
        if (self.client_secret) |secret| secureFree(self.allocator, secret);
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }

    fn acceptsResponse(self: *const HttpAuthSnapshot, bytes: []const u8) bool {
        if (std.mem.indexOf(u8, bytes, self.access_token) != null) return false;
        if (self.refresh_token) |secret| if (std.mem.indexOf(u8, bytes, secret) != null) return false;
        if (self.client_secret) |secret| if (std.mem.indexOf(u8, bytes, secret) != null) return false;
        return true;
    }
};

const OwnedRuntimeScopes = struct {
    arena: std.heap.ArenaAllocator,
    values: []const []const u8,

    fn deinit(self: *OwnedRuntimeScopes) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

fn ownRuntimeScopes(
    allocator: std.mem.Allocator,
    first: []const []const u8,
    second: []const []const u8,
) (std.mem.Allocator.Error || error{ScopeCapacity})!OwnedRuntimeScopes {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const owned = arena.allocator();
    const values = try owned.alloc([]const u8, mcp_oauth.Limits.scopes);
    var count: usize = 0;
    for (first) |scope| {
        if (count == values.len) return error.ScopeCapacity;
        values[count] = try owned.dupe(u8, scope);
        count += 1;
    }
    for (second) |scope| {
        var duplicate = false;
        for (values[0..count]) |existing| if (std.mem.eql(u8, existing, scope)) {
            duplicate = true;
            break;
        };
        if (duplicate) continue;
        if (count == values.len) return error.ScopeCapacity;
        values[count] = try owned.dupe(u8, scope);
        count += 1;
    }
    std.mem.sort([]const u8, values[0..count], {}, struct {
        fn lessThan(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.order(u8, left, right) == .lt;
        }
    }.lessThan);
    return .{ .arena = arena, .values = values[0..count] };
}

const PendingRuntimeAuthFailure = struct {
    consent_epoch: u64,
    token_revision: u64,
    scopes: ?OwnedRuntimeScopes = null,
    scopes_complete: bool = true,

    fn deinit(self: *PendingRuntimeAuthFailure) void {
        if (self.scopes) |*scopes| scopes.deinit();
        self.* = undefined;
    }
};

pub const RuntimeAuthFailure = struct {
    server_id: []const u8,
    source_fingerprint: [32]u8,
    trusted_challenge: bool,
    consent_epoch: u64,
    token_revision: u64,
    challenge_scopes: []const []const u8,
    challenge_scopes_complete: bool,
    scopes_owner: ?OwnedRuntimeScopes = null,
    slot: *HttpAuthSlot,

    pub fn deinit(self: *RuntimeAuthFailure) void {
        if (self.scopes_owner) |*scopes| scopes.deinit();
        self.* = undefined;
    }
};

pub const RuntimeAuthFailureBatch = struct {
    allocator: std.mem.Allocator,
    storage: []RuntimeAuthFailure,
    values: []RuntimeAuthFailure,

    pub fn deinit(self: *RuntimeAuthFailureBatch) void {
        for (self.values) |*failure| failure.deinit();
        if (self.storage.len != 0) self.allocator.free(self.storage);
        self.* = undefined;
    }
};

pub const RuntimeAuthFailureNotifier = struct {
    context: *anyopaque,
    notify_fn: *const fn (*anyopaque) void,

    fn notify(self: RuntimeAuthFailureNotifier) void {
        self.notify_fn(self.context);
    }
};

const HttpAuthSlot = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    references: std.atomic.Value(usize) = .init(1),
    mutex: std.Io.Mutex = .init,
    server_id: []u8,
    source_fingerprint: [32]u8,
    current: *HttpAuthSnapshot,
    rotation_reserved: bool = false,
    pending_failure: ?PendingRuntimeAuthFailure = null,
    untrusted_failure: ?PendingRuntimeAuthFailure = null,
    failure_notifier: ?RuntimeAuthFailureNotifier = null,

    fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        server_id: []const u8,
        source_fingerprint: [32]u8,
        consent_epoch: u64,
        token_revision: u64,
        secrets: HttpAuthSecrets,
    ) std.mem.Allocator.Error!*HttpAuthSlot {
        const self = try allocator.create(HttpAuthSlot);
        errdefer allocator.destroy(self);
        const owned_id = try allocator.dupe(u8, server_id);
        errdefer allocator.free(owned_id);
        const snapshot = try HttpAuthSnapshot.create(allocator, consent_epoch, token_revision, secrets);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .server_id = owned_id,
            .source_fingerprint = source_fingerprint,
            .current = snapshot,
        };
        return self;
    }

    fn retain(self: *HttpAuthSlot) void {
        const previous = self.references.fetchAdd(1, .acq_rel);
        std.debug.assert(previous != 0 and previous != std.math.maxInt(usize));
    }

    fn release(self: *HttpAuthSlot) void {
        const previous = self.references.fetchSub(1, .acq_rel);
        std.debug.assert(previous != 0);
        if (previous != 1) return;
        if (self.pending_failure) |*failure| failure.deinit();
        if (self.untrusted_failure) |*failure| failure.deinit();
        std.debug.assert(self.current.next == null);
        self.current.release();
        self.allocator.free(self.server_id);
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }

    fn lease(self: *HttpAuthSlot) HttpAuthLease {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.current.retain();
        self.retain();
        return .{ .slot = self, .snapshot = self.current };
    }

    fn acceptsResponse(self: *HttpAuthSlot, bytes: []const u8) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var snapshot: ?*HttpAuthSnapshot = self.current;
        while (snapshot) |value| : (snapshot = value.next)
            if (!value.acceptsResponse(bytes)) return false;
        return true;
    }

    /// Each registered snapshot has one list reference; retired snapshots
    /// survive only while actual request/inspection leases still use them.
    fn pruneSnapshotLocked(self: *HttpAuthSlot, snapshot: *HttpAuthSnapshot) void {
        if (snapshot == self.current or snapshot.references.load(.acquire) != 1) return;
        var link: *?*HttpAuthSnapshot = &self.current.next;
        while (link.*) |value| {
            if (value == snapshot) {
                link.* = value.next;
                value.release();
                return;
            }
            link = &value.next;
        }
        unreachable;
    }

    fn setFailureNotifier(
        self: *HttpAuthSlot,
        notifier: ?RuntimeAuthFailureNotifier,
    ) void {
        self.mutex.lockUncancelable(self.io);
        self.failure_notifier = notifier;
        self.mutex.unlock(self.io);
    }

    fn recordRuntimeAuthFailure(
        self: *HttpAuthSlot,
        auth_lease: *const HttpAuthLease,
        challenge_scopes: ?[]const []const u8,
    ) void {
        self.mutex.lockUncancelable(self.io);
        const epoch = auth_lease.snapshot.consent_epoch;
        const revision = auth_lease.snapshot.token_revision;
        if (self.pending_failure) |*pending| {
            if (pending.consent_epoch != epoch) {
                pending.deinit();
                var scopes_complete = challenge_scopes != null;
                const scopes = if (challenge_scopes) |values| ownRuntimeScopes(
                    self.allocator,
                    &.{},
                    values,
                ) catch scopes: {
                    scopes_complete = false;
                    break :scopes null;
                } else null;
                pending.* = .{
                    .consent_epoch = epoch,
                    .token_revision = revision,
                    .scopes = scopes,
                    .scopes_complete = scopes_complete,
                };
            } else {
                pending.token_revision = @max(pending.token_revision, revision);
                if (challenge_scopes == null) {
                    if (pending.scopes) |*scopes| scopes.deinit();
                    pending.scopes = null;
                    pending.scopes_complete = false;
                } else if (pending.scopes_complete and challenge_scopes.?.len != 0) {
                    const existing = if (pending.scopes) |*scopes|
                        scopes.values
                    else
                        &.{};
                    if (ownRuntimeScopes(
                        self.allocator,
                        existing,
                        challenge_scopes.?,
                    )) |replacement| {
                        if (pending.scopes) |*scopes| scopes.deinit();
                        pending.scopes = replacement;
                    } else |_| {
                        if (pending.scopes) |*scopes| scopes.deinit();
                        pending.scopes = null;
                        pending.scopes_complete = false;
                    }
                }
            }
        } else {
            var scopes_complete = challenge_scopes != null;
            const scopes = if (challenge_scopes) |values| ownRuntimeScopes(
                self.allocator,
                &.{},
                values,
            ) catch scopes: {
                scopes_complete = false;
                break :scopes null;
            } else null;
            self.pending_failure = .{
                .consent_epoch = epoch,
                .token_revision = revision,
                .scopes = scopes,
                .scopes_complete = scopes_complete,
            };
        }
        const notifier = self.failure_notifier;
        self.mutex.unlock(self.io);
        if (notifier) |value| value.notify();
    }

    fn recordHttpAuthRejection(self: *HttpAuthSlot, auth_lease: *const HttpAuthLease) void {
        self.mutex.lockUncancelable(self.io);
        if (self.untrusted_failure == null or self.untrusted_failure.?.consent_epoch != auth_lease.snapshot.consent_epoch or self.untrusted_failure.?.token_revision <= auth_lease.snapshot.token_revision) {
            self.untrusted_failure = .{ .consent_epoch = auth_lease.snapshot.consent_epoch, .token_revision = auth_lease.snapshot.token_revision, .scopes_complete = false };
        }
        const notifier = self.failure_notifier;
        self.mutex.unlock(self.io);
        if (notifier) |value| value.notify();
    }

    fn snapshotRuntimeAuthFailure(
        self: *HttpAuthSlot,
        trusted: bool,
    ) std.mem.Allocator.Error!?RuntimeAuthFailure {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const pending = (if (trusted) self.pending_failure else self.untrusted_failure) orelse return null;
        const scopes_owner = if (pending.scopes) |*owner|
            ownRuntimeScopes(self.allocator, owner.values, &.{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.ScopeCapacity => unreachable,
            }
        else
            null;
        return .{
            .server_id = self.server_id,
            .source_fingerprint = self.source_fingerprint,
            .trusted_challenge = trusted,
            .consent_epoch = pending.consent_epoch,
            .token_revision = pending.token_revision,
            .challenge_scopes = if (scopes_owner) |*owner| owner.values else &.{},
            .challenge_scopes_complete = pending.scopes_complete,
            .scopes_owner = scopes_owner,
            .slot = self,
        };
    }

    fn runtimeAuthFailureCount(self: *HttpAuthSlot) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return @as(usize, @intFromBool(self.pending_failure != null)) + @intFromBool(self.untrusted_failure != null);
    }

    fn acknowledgeRuntimeAuthFailure(
        self: *HttpAuthSlot,
        failure: *const RuntimeAuthFailure,
    ) bool {
        if (failure.slot != self) return false;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const owner = if (failure.trusted_challenge) &self.pending_failure else &self.untrusted_failure;
        const pending = if (owner.*) |*value| value else return false;
        const pending_scopes = if (pending.scopes) |*scopes| scopes.values else &.{};
        if (pending.consent_epoch != failure.consent_epoch or
            pending.token_revision != failure.token_revision or
            pending.scopes_complete != failure.challenge_scopes_complete or
            !runtimeScopeSetsEqual(pending_scopes, failure.challenge_scopes))
            return false;
        pending.deinit();
        owner.* = null;
        return true;
    }

    fn reserveRotation(
        self: *HttpAuthSlot,
        expected_consent_epoch: u64,
        expected_token_revision: u64,
        replacement: *HttpAuthSnapshot,
    ) HttpAuthRotationOutcome {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.current.consent_epoch != expected_consent_epoch)
            return .consent_epoch_mismatch;
        if (self.rotation_reserved or
            self.current.token_revision != expected_token_revision or
            replacement.token_revision != expected_token_revision + 1 or
            replacement.consent_epoch != expected_consent_epoch)
            return .token_revision_mismatch;
        self.rotation_reserved = true;
        return .replaced;
    }

    fn commitReservedRotation(
        self: *HttpAuthSlot,
        expected_consent_epoch: u64,
        expected_token_revision: u64,
        replacement: *HttpAuthSnapshot,
    ) void {
        self.mutex.lockUncancelable(self.io);
        const current = self.current;
        std.debug.assert(self.rotation_reserved);
        std.debug.assert(current.consent_epoch == expected_consent_epoch);
        std.debug.assert(current.token_revision == expected_token_revision);
        std.debug.assert(replacement.consent_epoch == expected_consent_epoch);
        std.debug.assert(replacement.token_revision == expected_token_revision + 1);
        replacement.next = current;
        self.current = replacement;
        self.rotation_reserved = false;
        self.pruneSnapshotLocked(current);
        self.mutex.unlock(self.io);
    }

    fn cancelReservedRotation(self: *HttpAuthSlot) void {
        self.mutex.lockUncancelable(self.io);
        std.debug.assert(self.rotation_reserved);
        self.rotation_reserved = false;
        self.mutex.unlock(self.io);
    }
};

const HttpAuthLease = struct {
    slot: *HttpAuthSlot,
    snapshot: *HttpAuthSnapshot,

    fn token(self: *const HttpAuthLease) []const u8 {
        return self.snapshot.access_token;
    }

    fn deinit(self: *HttpAuthLease) void {
        const slot = self.slot;
        slot.mutex.lockUncancelable(slot.io);
        self.snapshot.release();
        slot.pruneSnapshotLocked(self.snapshot);
        slot.mutex.unlock(slot.io);
        slot.release();
        self.* = undefined;
    }
};

pub const HttpAuthRotationOutcome = enum {
    replaced,
    server_not_loaded,
    consent_epoch_mismatch,
    token_revision_mismatch,
};

pub const PendingHttpAuthRotation = struct {
    slot: ?*HttpAuthSlot,
    replacement: ?*HttpAuthSnapshot,
    expected_consent_epoch: u64,
    expected_token_revision: u64,

    pub fn commit(self: *PendingHttpAuthRotation) void {
        const slot = self.slot orelse unreachable;
        const replacement = self.replacement orelse unreachable;
        slot.commitReservedRotation(
            self.expected_consent_epoch,
            self.expected_token_revision,
            replacement,
        );
        self.replacement = null;
    }

    pub fn deinit(self: *PendingHttpAuthRotation) void {
        if (self.replacement) |replacement| {
            if (self.slot) |slot| slot.cancelReservedRotation();
            replacement.release();
        }
        if (self.slot) |slot| slot.release();
        self.* = undefined;
    }
};

pub const HttpAuthRotationPreparation = union(enum) {
    prepared: PendingHttpAuthRotation,
    server_not_loaded,
    consent_epoch_mismatch,
    token_revision_mismatch,
};

/// Application-owned lookup authority for the OAuth HTTP transports loaded by
/// the current Agent Runtime. The registry and each transport retain the same
/// slot independently, so shutdown ordering cannot invalidate an in-flight
/// request. Rotation is a same-consent-epoch compare-and-swap only.
pub const HttpAuthorizations = struct {
    allocator: std.mem.Allocator,
    slots: []*HttpAuthSlot = &.{},
    /// One rejected candidate's Host auth references, retained only until its
    /// typed observations are consumed. Never used for membership or rotation.
    pending_slots: []*HttpAuthSlot = &.{},
    pending_slot_storage: []*HttpAuthSlot = &.{},

    /// Prepare the actual member mapping before apply. Unchanged transports
    /// retain their existing rotation/failure slot, including retained members.
    pub fn compose(self: *const HttpAuthorizations, additions: *const HttpAuthorizations, ids: []const []const u8, replaced_id: ?[]const u8) std.mem.Allocator.Error!HttpAuthorizations {
        var slots: std.ArrayList(*HttpAuthSlot) = .empty;
        defer slots.deinit(self.allocator);
        errdefer for (slots.items) |slot| slot.release();
        for (ids) |id| {
            const source = if (replaced_id != null and std.mem.eql(u8, replaced_id.?, id)) additions else self;
            for (source.slots) |slot| {
                if (!std.mem.eql(u8, slot.server_id, id)) continue;
                try slots.append(self.allocator, slot);
                slot.retain();
                break;
            }
        }
        return .{ .allocator = self.allocator, .slots = try slots.toOwnedSlice(self.allocator) };
    }

    pub fn deinit(self: *HttpAuthorizations) void {
        for (self.slots) |slot| slot.release();
        if (self.slots.len != 0) self.allocator.free(self.slots);
        for (self.pending_slots) |slot| slot.release();
        if (self.pending_slot_storage.len != 0) self.allocator.free(self.pending_slot_storage);
        self.* = undefined;
    }

    pub fn retainRejectedFailures(self: *HttpAuthorizations, rejected: *HttpAuthorizations) void {
        std.debug.assert(self.pending_slots.len == 0 and rejected.pending_slots.len == 0);
        const storage = rejected.slots;
        rejected.slots = &.{};
        var count: usize = 0;
        for (storage) |slot| {
            const shared = for (self.slots) |active| {
                if (active == slot) break true;
            } else false;
            if (shared or slot.runtimeAuthFailureCount() == 0) {
                slot.release();
            } else {
                storage[count] = slot;
                count += 1;
            }
        }
        if (count == 0) {
            if (storage.len != 0) self.allocator.free(storage);
            return;
        }
        // Compact without allocating: retain the complete backing allocation
        // for correct release, and expose only candidate-owned observations.
        self.pending_slot_storage = storage;
        self.pending_slots = storage[0..count];
    }

    pub fn releaseDeliveredFailures(self: *HttpAuthorizations) bool {
        if (self.pending_slots.len == 0) return false;
        for (self.pending_slots) |slot| if (slot.runtimeAuthFailureCount() != 0) return false;
        for (self.pending_slots) |slot| slot.release();
        self.allocator.free(self.pending_slot_storage);
        self.pending_slots = &.{};
        self.pending_slot_storage = &.{};
        return true;
    }

    pub fn setRuntimeAuthFailureNotifier(
        self: *HttpAuthorizations,
        notifier: ?RuntimeAuthFailureNotifier,
    ) void {
        for ([_][]*HttpAuthSlot{ self.slots, self.pending_slots }) |slots|
            for (slots) |slot| slot.setFailureNotifier(notifier);
    }

    pub fn snapshotRuntimeAuthFailures(
        self: *HttpAuthorizations,
    ) std.mem.Allocator.Error!RuntimeAuthFailureBatch {
        var pending_count: usize = 0;
        for ([_][]*HttpAuthSlot{ self.slots, self.pending_slots }) |slots|
            for (slots) |slot| {
                pending_count += slot.runtimeAuthFailureCount();
            };
        if (pending_count == 0) return .{
            .allocator = self.allocator,
            .storage = &.{},
            .values = &.{},
        };
        const storage = try self.allocator.alloc(RuntimeAuthFailure, pending_count);
        var count: usize = 0;
        errdefer {
            for (storage[0..count]) |*failure| failure.deinit();
            self.allocator.free(storage);
        }
        for ([_][]*HttpAuthSlot{ self.slots, self.pending_slots }) |slots| for (slots) |slot| for ([_]bool{ true, false }) |trusted| {
            if (count == storage.len) break;
            if (try slot.snapshotRuntimeAuthFailure(trusted)) |failure| {
                storage[count] = failure;
                count += 1;
            }
        };
        return .{
            .allocator = self.allocator,
            .storage = storage,
            .values = storage[0..count],
        };
    }

    pub fn acknowledgeRuntimeAuthFailure(
        self: *HttpAuthorizations,
        failure: *const RuntimeAuthFailure,
    ) bool {
        for ([_][]*HttpAuthSlot{ self.slots, self.pending_slots }) |slots| for (slots) |slot|
            if (slot == failure.slot)
                return slot.acknowledgeRuntimeAuthFailure(failure);
        return false;
    }

    pub fn rotate(
        self: *HttpAuthorizations,
        server_id: []const u8,
        expected_consent_epoch: u64,
        expected_token_revision: u64,
        update: HttpTokenUpdate,
    ) std.mem.Allocator.Error!HttpAuthRotationOutcome {
        var pending = switch (try self.prepareRotation(
            server_id,
            expected_consent_epoch,
            expected_token_revision,
            update,
        )) {
            .prepared => |prepared| prepared,
            .server_not_loaded => return .server_not_loaded,
            .consent_epoch_mismatch => return .consent_epoch_mismatch,
            .token_revision_mismatch => return .token_revision_mismatch,
        };
        defer pending.deinit();
        pending.commit();
        return .replaced;
    }

    pub fn prepareRotation(
        self: *HttpAuthorizations,
        server_id: []const u8,
        expected_consent_epoch: u64,
        expected_token_revision: u64,
        update: HttpTokenUpdate,
    ) std.mem.Allocator.Error!HttpAuthRotationPreparation {
        if (!mcp_configuration.validHttpHeaderCredential(update.access_token) or
            expected_token_revision == std.math.maxInt(u64))
            return .token_revision_mismatch;
        const slot = for (self.slots) |candidate| {
            if (std.mem.eql(u8, candidate.server_id, server_id)) break candidate;
        } else return .server_not_loaded;
        slot.retain();
        var slot_owned = true;
        defer if (slot_owned) slot.release();
        var previous = slot.lease();
        defer previous.deinit();
        const replacement = try HttpAuthSnapshot.create(
            self.allocator,
            expected_consent_epoch,
            expected_token_revision + 1,
            .{
                .access_token = update.access_token,
                .refresh_token = update.refresh_token orelse previous.snapshot.refresh_token,
                .client_secret = previous.snapshot.client_secret,
            },
        );
        var replacement_owned = true;
        defer if (replacement_owned) replacement.release();
        switch (slot.reserveRotation(
            expected_consent_epoch,
            expected_token_revision,
            replacement,
        )) {
            .replaced => {},
            .server_not_loaded => unreachable,
            .consent_epoch_mismatch => return .consent_epoch_mismatch,
            .token_revision_mismatch => return .token_revision_mismatch,
        }
        slot_owned = false;
        replacement_owned = false;
        return .{ .prepared = .{
            .slot = slot,
            .replacement = replacement,
            .expected_consent_epoch = expected_consent_epoch,
            .expected_token_revision = expected_token_revision,
        } };
    }
};

fn runtimeScopeSetsEqual(left: []const []const u8, right: []const []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_scope, right_scope|
        if (!std.mem.eql(u8, left_scope, right_scope)) return false;
    return true;
}

pub const RuntimeBuild = struct {
    input: ?agent.McpRuntimeInput = null,
    authorizations: HttpAuthorizations,
    processes: ?StdioObservations = null,

    pub fn deinit(self: *RuntimeBuild) void {
        if (self.input) |*input| input.deinit();
        self.authorizations.deinit();
        if (self.processes) |*processes| processes.deinit();
        self.* = undefined;
    }

    pub fn takeAuthorizations(self: *RuntimeBuild) HttpAuthorizations {
        const result = self.authorizations;
        self.authorizations = .{ .allocator = result.allocator };
        return result;
    }
};

pub const DraftHttpObservation = struct {
    const max_redirect_bytes = 4096;

    mutex: std.Io.Mutex = .init,
    status: u16 = 0,
    challenge: [mcp_oauth.Limits.header_bytes]u8 = @splat(0),
    challenge_len: usize = 0,
    redirect: [max_redirect_bytes]u8 = @splat(0),
    redirect_len: usize = 0,

    fn recordRedirect(self: *DraftHttpObservation, io: std.Io, endpoint: []const u8, response: *std.http.Client.Response) void {
        var location: ?[]const u8 = null;
        var headers = response.head.iterateHeaders();
        while (headers.next()) |header_value| {
            if (!std.ascii.eqlIgnoreCase(header_value.name, "Location")) continue;
            if (location != null) return;
            location = header_value.value;
        }
        const reference = location orelse return;
        if (reference.len == 0 or reference.len > max_redirect_bytes) return;
        const base = std.Uri.parse(endpoint) catch return;
        var scratch: [3 * max_redirect_bytes]u8 = undefined;
        defer std.crypto.secureZero(u8, &scratch);
        @memcpy(scratch[0..reference.len], reference);
        var aux: []u8 = &scratch;
        const resolved = std.Uri.resolveInPlace(base, reference.len, &aux) catch return;
        if (!std.ascii.eqlIgnoreCase(base.scheme, resolved.scheme)) return;
        const default_port: u16 = if (std.ascii.eqlIgnoreCase(base.scheme, "https")) 443 else 80;
        if ((base.port orelse default_port) != (resolved.port orelse default_port)) return;
        var target_buffer: [max_redirect_bytes]u8 = undefined;
        defer std.crypto.secureZero(u8, &target_buffer);
        var writer = std.Io.Writer.fixed(&target_buffer);
        resolved.format(&writer) catch return;
        const target = writer.buffered();
        if (mcp_configuration.endpointOrigin(target, max_redirect_bytes) == null or std.mem.eql(u8, endpoint, target)) return;
        var base_host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
        var target_host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
        const base_host = base.getHost(&base_host_buffer) catch return;
        const target_host = resolved.getHost(&target_host_buffer) catch return;
        if (!std.ascii.eqlIgnoreCase(base_host.bytes, target_host.bytes)) return;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.redirect_len != 0) return;
        @memcpy(self.redirect[0..target.len], target);
        self.redirect_len = target.len;
    }

    fn record(self: *DraftHttpObservation, io: std.Io, status: u16, challenge_value: []const u8) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.status == 401 and status != 401) return;
        if (self.status == status and challenge_value.len == 0) return;
        self.status = status;
        std.crypto.secureZero(u8, &self.challenge);
        @memcpy(self.challenge[0..challenge_value.len], challenge_value);
        self.challenge_len = challenge_value.len;
    }

    // Read after the isolated Runtime and its transports have shut down.
    pub fn header(self: *const DraftHttpObservation) ?[]const u8 {
        if (self.challenge_len == 0) return null;
        return self.challenge[0..self.challenge_len];
    }
};

pub const HostEnvironment = struct {
    http_engine: ?*http_execution.Engine = null,
    process_attempt: u64 = 0,
    process_notifier: ?process_observation.Notifier = null,
    catalog_budget: ?*catalog_budget.Budget = null,
    draft_http_observation: ?*DraftHttpObservation = null,
    executable_search_path: ?[]const u8 = null,
    windows_system_root: ?[]const u8 = null,

    pub fn fromProcess(environ_map: *const std.process.Environ.Map) HostEnvironment {
        return .{
            .executable_search_path = environ_map.get("PATH") orelse
                if (builtin.os.tag == .windows) environ_map.get("Path") else null,
            .windows_system_root = if (builtin.os.tag == .windows)
                environ_map.get("SystemRoot")
            else
                null,
        };
    }
};

/// Builds a single-use Agent input from eligible servers only. On failure no
/// transport owner is consumed; successful Agent input construction takes all
/// concrete contexts as one commit.
pub fn buildRuntimeInput(
    io: std.Io,
    allocator: std.mem.Allocator,
    preparation: *const mcp_configuration.Preparation,
    host_environment: HostEnvironment,
) BuildError!?agent.McpRuntimeInput {
    var build = try buildRuntime(io, allocator, preparation, host_environment);
    defer build.authorizations.deinit();
    defer if (build.processes) |*processes| processes.deinit();
    return build.input;
}

pub fn buildRuntime(
    io: std.Io,
    allocator: std.mem.Allocator,
    preparation: *const mcp_configuration.Preparation,
    host_environment: HostEnvironment,
) BuildError!RuntimeBuild {
    var process_slots: std.ArrayList(*process_observation.Slot) = .empty;
    defer process_slots.deinit(allocator);
    errdefer for (process_slots.items) |slot| slot.release();
    var authorization_list: std.ArrayList(*HttpAuthSlot) = .empty;
    defer authorization_list.deinit(allocator);
    errdefer for (authorization_list.items) |slot| slot.release();
    if (preparation.state != .available or preparation.registry == null)
        return .{ .authorizations = .{ .allocator = allocator } };
    const registry = preparation.registry.?.value;
    var eligible_count: usize = 0;
    for (preparation.server_states) |state| {
        if (state == .eligible) eligible_count += 1;
    }
    if (eligible_count == 0) {
        if (registry.generation == 0)
            return .{ .authorizations = .{ .allocator = allocator } };
        return .{
            .input = try agent.McpRuntimeInput.init(
                allocator,
                registry.generation,
                &.{},
            ),
            .authorizations = .{ .allocator = allocator },
        };
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const temporary = arena.allocator();
    const inputs = try temporary.alloc(agent.McpServerInput, eligible_count);
    const owners = try temporary.alloc(*agent.McpTransportOwner, eligible_count);
    var initialized: usize = 0;
    errdefer for (owners[0..initialized]) |owner| {
        owner.deinit();
        allocator.destroy(owner);
    };

    var write: usize = 0;
    for (registry.servers, preparation.server_states) |server, state| {
        if (state != .eligible) continue;
        if (std.mem.eql(u8, server.transport.kind, "streamable_http") and host_environment.http_engine == null) return error.InvalidConfig;
        const owner = try allocator.create(agent.McpTransportOwner);
        var authorization: ?*HttpAuthSlot = null;
        var observation: ?*process_observation.Slot = null;
        if (std.mem.eql(u8, server.transport.kind, "stdio")) if (host_environment.process_notifier) |notifier| {
            const slot = process_observation.Slot.init(allocator, server, host_environment.process_attempt, notifier) catch |err| {
                allocator.destroy(owner);
                return err;
            };
            process_slots.append(allocator, slot) catch |err| {
                slot.release();
                allocator.destroy(owner);
                return err;
            };
            observation = slot;
        };
        owner.* = (if (std.mem.eql(u8, server.transport.kind, "stdio"))
            createStdioOwner(io, allocator, server, preparation, host_environment, observation)
        else if (std.mem.eql(u8, server.transport.kind, "streamable_http"))
            createHttpOwner(host_environment.http_engine.?, io, allocator, server, preparation, &authorization, host_environment.draft_http_observation)
        else
            error.InvalidConfig) catch |err| {
            allocator.destroy(owner);
            return err;
        };
        owner.* = catalog_budget.wrapTransport(allocator, owner, server.timeout_ms, host_environment.catalog_budget, mcp_configuration.initialInstallation(server) and host_environment.catalog_budget != null) catch |err| {
            owner.deinit();
            allocator.destroy(owner);
            return err;
        };
        if (authorization) |slot| {
            authorization_list.append(allocator, slot) catch |err| {
                owner.deinit();
                allocator.destroy(owner);
                return err;
            };
            slot.retain();
        }
        owners[write] = owner;
        initialized += 1;
        const secrets = try serverSecrets(temporary, server, preparation);
        inputs[write] = .{
            .id = server.id,
            .transport_owner = owner,
            .secrets = secrets,
            .transport = if (std.mem.eql(u8, server.transport.kind, "stdio"))
                .stdio
            else
                .streamable_http,
            .negotiation = negotiation(server.negotiation) orelse
                return error.InvalidConfig,
            .namespace = server.namespace,
            .client_name = client_name,
            .client_version = client_version,
            .timeout_ms = if (mcp_configuration.initialInstallation(server) and host_environment.catalog_budget != null) @max(server.timeout_ms, mcp_configuration.initial_installation_timeout_ms) else server.timeout_ms,
            .configuration_fingerprint = mcp_configuration.runtimeDescriptorFingerprint(server),
            .allowed_tools = server.tools,
        };
        write += 1;
    }
    const slots = try authorization_list.toOwnedSlice(allocator);
    var slots_owned = true;
    errdefer if (slots_owned) {
        for (slots) |slot| slot.release();
        if (slots.len != 0) allocator.free(slots);
    };
    const owned_process_slots = try process_slots.toOwnedSlice(allocator);
    errdefer {
        for (owned_process_slots) |slot| slot.release();
        if (owned_process_slots.len != 0) allocator.free(owned_process_slots);
    }
    const input = agent.McpRuntimeInput.init(
        allocator,
        registry.generation,
        inputs,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidConfig,
    };
    // McpRuntimeInput consumed every concrete owner value. The heap wrappers
    // carried only the move source and are no longer part of transport life.
    for (owners) |owner| allocator.destroy(owner);
    initialized = 0;
    slots_owned = false;
    return .{
        .input = input,
        .processes = .{ .allocator = allocator, .slots = owned_process_slots },
        .authorizations = .{ .allocator = allocator, .slots = slots },
    };
}

fn negotiation(value: []const u8) ?agent.McpNegotiationPolicy {
    if (std.mem.eql(u8, value, "automatic")) return .automatic;
    if (std.mem.eql(u8, value, "modern_only")) return .modern_only;
    if (std.mem.eql(u8, value, "compat_only")) return .compat_only;
    return null;
}

fn resolvedCredential(
    preparation: *const mcp_configuration.Preparation,
    locator: []const u8,
) ?[]const u8 {
    for (preparation.credentials) |credential|
        if (std.mem.eql(u8, credential.locator, locator)) return credential.secret;
    return null;
}

fn serverSecrets(
    allocator: std.mem.Allocator,
    server: mcp_configuration.ServerWire,
    preparation: *const mcp_configuration.Preparation,
) BuildError![]const []const u8 {
    const count = server.transport.environment.len + server.transport.headers.len + if (server.installation) |operation| operation.credentials.len else @as(usize, 0);
    const values = try allocator.alloc([]const u8, count);
    var write: usize = 0;
    for (server.transport.environment) |entry| {
        const locator = entry.credential_ref orelse return error.InvalidConfig;
        const secret = resolvedCredential(preparation, locator) orelse
            return error.InvalidConfig;
        if (!containsSecret(values[0..write], secret)) {
            values[write] = secret;
            write += 1;
        }
    }
    for (server.transport.headers) |entry| {
        const locator = entry.credential_ref orelse return error.InvalidConfig;
        const secret = resolvedCredential(preparation, locator) orelse
            return error.InvalidConfig;
        if (!containsSecret(values[0..write], secret)) {
            values[write] = secret;
            write += 1;
        }
    }
    if (server.installation) |operation| for (operation.credentials) |slot| if (slot.credential_ref) |locator| {
        const secret = resolvedCredential(preparation, locator) orelse return error.InvalidConfig;
        if (!containsSecret(values[0..write], secret)) {
            values[write] = secret;
            write += 1;
        }
    };
    return values[0..write];
}

fn containsSecret(values: []const []const u8, candidate: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, candidate)) return true;
    return false;
}

const StdioContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    arena: std.heap.ArenaAllocator,
    environment: std.process.Environ.Map,
    argv: []const []const u8,
    cwd: std.process.Child.Cwd,
    backend: agent.McpStdioBackend,
    observation: ?*process_observation.Slot = null,

    fn endpoint(self: *StdioContext) agent.McpStdioProcessEndpoint {
        return .{
            .context = self,
            .validate_fn = validateEndpoint,
            .open_fn = open,
            .exchange_fn = exchange,
            .notify_fn = notify,
            .close_fn = close,
        };
    }

    fn validateEndpoint(raw: *anyopaque) bool {
        const self: *StdioContext = @ptrCast(@alignCast(raw));
        if (self.argv.len == 0 or self.argv.len > max_stdio_argv_count or
            self.argv[0].len == 0) return false;
        var total: usize = 0;
        for (self.argv) |argument| {
            if (std.mem.indexOfScalar(u8, argument, 0) != null) return false;
            total = std.math.add(usize, total, argument.len) catch return false;
        }
        if (total > max_stdio_argv_bytes) return false;
        return switch (self.cwd) {
            .path => |path| path.len != 0 and
                std.mem.indexOfScalar(u8, path, 0) == null,
            .inherit, .dir => true,
        };
    }

    const Connection = struct {
        context: *StdioContext,
        child: std.process.Child,
        stdin: std.Io.File,
        stdout: std.Io.File,
        stderr: std.Io.File,
        stdout_buffer: []u8,
        stdout_reader: std.Io.File.Reader,
        stderr_task: std.Io.Future(void),
        job: if (builtin.os.tag == .windows) process_compat.Job else void,
        dead: std.atomic.Value(bool) = .init(false),

        fn terminate(self: *Connection) void {
            if (self.dead.swap(true, .acq_rel)) return;
            if (builtin.os.tag == .windows) {
                self.job.deinit();
                if (self.child.id != null) self.child.kill(self.context.io);
                return;
            }
            if (self.child.id) |pid| {
                std.posix.kill(-pid, .KILL) catch {};
                _ = self.child.wait(self.context.io) catch {};
            }
        }

        fn deinit(self: *Connection) void {
            self.terminate();
            self.stderr_task.cancel(self.context.io);
            self.stdin.close(self.context.io);
            self.stdout.close(self.context.io);
            std.crypto.secureZero(u8, self.stdout_buffer);
            const context = self.context;
            context.allocator.free(self.stdout_buffer);
            context.allocator.destroy(self);
        }
    };

    fn open(raw: *anyopaque, _: u32) agent.McpStdioOpenOutcome {
        const self: *StdioContext = @ptrCast(@alignCast(raw));
        const connection = self.openConnection() catch |err| {
            if (err == error.ResourceUnavailable) if (self.observation) |slot| slot.record(.host_resource_unavailable);
            return .{ .failure = switch (err) {
                error.SpawnFailed => .child_exit,
                error.ResourceUnavailable => .fatal,
            } };
        };
        return .{ .connection = connection };
    }

    const OpenError = error{ SpawnFailed, ResourceUnavailable };

    fn openConnection(self: *StdioContext) OpenError!*Connection {
        var job = if (builtin.os.tag == .windows)
            process_compat.Job.init() catch return error.ResourceUnavailable
        else {};
        errdefer if (builtin.os.tag == .windows) job.deinit();
        // std closes temporary child-side handles before spawn returns.
        // The lock must not extend to activation, I/O, or process waiting.
        if (builtin.os.tag == .windows) windows_spawn_mutex.lockUncancelable(self.io);
        var child = std.process.spawn(self.io, .{
            .argv = self.argv,
            .cwd = self.cwd,
            .environ_map = &self.environment,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
            .pgid = if (builtin.os.tag == .windows) null else 0,
            .create_no_window = true,
            .start_suspended = builtin.os.tag == .windows,
        }) catch |err| {
            if (builtin.os.tag == .windows) windows_spawn_mutex.unlock(self.io);
            if (self.observation) |slot| slot.record(switch (err) {
                error.FileNotFound => .executable_missing,
                error.AccessDenied => .access_denied,
                error.InvalidExe => .invalid_executable,
                else => .spawn_failed,
            });
            return error.SpawnFailed;
        };
        if (builtin.os.tag == .windows) windows_spawn_mutex.unlock(self.io);
        if (self.observation) |slot| slot.record(.spawned);
        errdefer child.kill(self.io);
        if (builtin.os.tag == .windows)
            job.attachAndResume(&child) catch return error.ResourceUnavailable;
        const stdin = child.stdin.?;
        const stdout = child.stdout.?;
        const stderr = child.stderr.?;
        child.stdin = null;
        child.stdout = null;
        child.stderr = null;
        errdefer stdin.close(self.io);
        errdefer stdout.close(self.io);
        errdefer stderr.close(self.io);
        const stdout_buffer = self.allocator.alloc(u8, stdio_io_buffer_bytes) catch
            return error.ResourceUnavailable;
        errdefer {
            std.crypto.secureZero(u8, stdout_buffer);
            self.allocator.free(stdout_buffer);
        }
        const connection = self.allocator.create(Connection) catch
            return error.ResourceUnavailable;
        errdefer self.allocator.destroy(connection);
        connection.* = .{
            .context = self,
            .child = child,
            .stdin = stdin,
            .stdout = stdout,
            .stderr = stderr,
            .stdout_buffer = stdout_buffer,
            .stdout_reader = stdout.readerStreaming(self.io, stdout_buffer),
            .stderr_task = undefined,
            .job = job,
        };
        connection.stderr_task = std.Io.concurrent(
            self.io,
            drainStderr,
            .{connection},
        ) catch return error.ResourceUnavailable;
        return connection;
    }

    const WaitResult = enum { expired, cancelled };
    const ExchangeEvent = union(enum) {
        exchange: agent.McpStdioPerformOutcome,
        timeout: WaitResult,
        cancellation: WaitResult,
    };

    fn exchange(
        _: *anyopaque,
        raw_connection: *anyopaque,
        write: agent.McpStdioWrite,
        sink: *const agent.McpStdioResponseSink,
    ) agent.McpStdioPerformOutcome {
        const connection: *Connection = @ptrCast(@alignCast(raw_connection));
        if (connection.dead.load(.acquire)) return .{ .failure = .child_exit };
        if (write.cancellation.isCancelled()) return .{ .failure = .cancelled };
        var events: [3]ExchangeEvent = undefined;
        var select = std.Io.Select(ExchangeEvent).init(connection.context.io, &events);
        select_start.startWithCleanup(&select, .{
            .{ .exchange, pumpExchange, .{ connection, write.fragments, sink } },
            .{ .timeout, waitTimeout, .{ connection.context.io, write.timeout_ms } },
            .{ .cancellation, waitCancellation, .{ connection.context.io, write.cancellation } },
        }, terminateAndCancel, .{ connection, &select }) catch return .{ .failure = .fatal };
        const first = select.await() catch {
            connection.terminate();
            select.cancelDiscard();
            return .{ .failure = .cancelled };
        };
        const result: agent.McpStdioPerformOutcome = switch (first) {
            .exchange => |value| value,
            .timeout => |wait| switch (wait) {
                .expired => .{ .failure = .timeout },
                .cancelled => .{ .failure = .fatal },
            },
            .cancellation => |wait| switch (wait) {
                .expired => .{ .failure = .cancelled },
                .cancelled => .{ .failure = .fatal },
            },
        };
        switch (result) {
            .completed => {},
            .failure => connection.terminate(),
        }
        select.cancelDiscard();
        return result;
    }

    fn pumpExchange(
        connection: *Connection,
        fragments: []const []const u8,
        sink: *const agent.McpStdioResponseSink,
    ) agent.McpStdioPerformOutcome {
        for (fragments) |fragment|
            connection.stdin.writeStreamingAll(
                connection.context.io,
                fragment,
            ) catch return .{ .failure = .child_exit };
        while (true) {
            const chunk = connection.stdout_reader.interface.peekGreedy(1) catch |err|
                switch (err) {
                    error.EndOfStream => {
                        if (connection.context.observation) |slot| slot.record(.stdio_closed);
                        _ = sink.finish_fn(sink.context);
                        return .completed;
                    },
                    else => return .{ .failure = .child_exit },
                };
            const fed = sink.feed_fn(sink.context, chunk);
            if (fed.consumed > chunk.len) return .{ .failure = .fatal };
            connection.stdout_reader.interface.toss(fed.consumed);
            if (fed.flow == .stop) return .completed;
            if (fed.consumed != chunk.len) return .{ .failure = .fatal };
        }
    }

    const NotifyEvent = union(enum) {
        write: ?agent.McpStdioPortFailure,
        timeout: WaitResult,
        cancellation: WaitResult,
    };

    fn notify(
        _: *anyopaque,
        raw_connection: *anyopaque,
        write: agent.McpStdioWrite,
    ) ?agent.McpStdioPortFailure {
        const connection: *Connection = @ptrCast(@alignCast(raw_connection));
        if (connection.dead.load(.acquire)) return .child_exit;
        if (write.cancellation.isCancelled()) return .cancelled;
        var events: [3]NotifyEvent = undefined;
        var select = std.Io.Select(NotifyEvent).init(connection.context.io, &events);
        select_start.startWithCleanup(&select, .{
            .{ .write, writeNotification, .{ connection, write.fragments } },
            .{ .timeout, waitTimeout, .{ connection.context.io, write.timeout_ms } },
            .{ .cancellation, waitCancellation, .{ connection.context.io, write.cancellation } },
        }, terminateAndCancel, .{ connection, &select }) catch return .fatal;
        const first = select.await() catch {
            connection.terminate();
            select.cancelDiscard();
            return .cancelled;
        };
        const result: ?agent.McpStdioPortFailure = switch (first) {
            .write => |value| value,
            .timeout => |wait| switch (wait) {
                .expired => .timeout,
                .cancelled => .fatal,
            },
            .cancellation => |wait| switch (wait) {
                .expired => .cancelled,
                .cancelled => .fatal,
            },
        };
        if (result != null) connection.terminate();
        select.cancelDiscard();
        return result;
    }

    fn writeNotification(
        connection: *Connection,
        fragments: []const []const u8,
    ) ?agent.McpStdioPortFailure {
        for (fragments) |fragment|
            connection.stdin.writeStreamingAll(
                connection.context.io,
                fragment,
            ) catch return .child_exit;
        return null;
    }

    fn terminateAndCancel(connection: *Connection, selection: anytype) void {
        connection.terminate();
        selection.cancelDiscard();
    }

    fn close(_: *anyopaque, raw_connection: *anyopaque) void {
        const connection: *Connection = @ptrCast(@alignCast(raw_connection));
        connection.deinit();
    }

    fn waitTimeout(io: std.Io, timeout_ms: u32) WaitResult {
        std.Io.Timeout.sleep(.{ .duration = .{
            .raw = std.Io.Duration.fromMilliseconds(timeout_ms),
            .clock = .awake,
        } }, io) catch return .cancelled;
        return .expired;
    }

    fn waitCancellation(io: std.Io, cancellation: agent.McpCancellation) WaitResult {
        while (!cancellation.isCancelled())
            std.Io.Timeout.sleep(.{ .duration = .{
                .raw = std.Io.Duration.fromMilliseconds(5),
                .clock = .awake,
            } }, io) catch return .cancelled;
        return .expired;
    }

    fn drainStderr(connection: *Connection) void {
        defer connection.stderr.close(connection.context.io);
        var buffer: [stdio_io_buffer_bytes]u8 = undefined;
        defer std.crypto.secureZero(u8, &buffer);
        while (true) {
            const count = connection.stderr.readStreaming(
                connection.context.io,
                &.{&buffer},
            ) catch return;
            if (count == 0) return;
            std.crypto.secureZero(u8, buffer[0..count]);
        }
    }

    fn destroy(raw: *anyopaque) void {
        const backend: *agent.McpStdioBackend = @ptrCast(@alignCast(raw));
        const self: *StdioContext = @fieldParentPtr("backend", backend);
        self.backend.deinit() catch @panic("MCP stdio owner released with live connections");
        if (self.observation) |slot| slot.release();
        secureEnvironmentDeinit(&self.environment);
        self.arena.deinit();
        const allocator = self.allocator;
        allocator.destroy(self);
    }
};

/// Builds an App-owned process/pipe effect and wraps it with the Agent-owned
/// stdio protocol backend. Launch data is deep-copied; directory handles, when
/// supplied, remain borrowed until the returned owner is released.
pub fn createStdioTransportOwner(
    io: std.Io,
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    cwd: std.process.Child.Cwd,
    environment: *const std.process.Environ.Map,
) BuildError!agent.McpTransportOwner {
    const context = try allocator.create(StdioContext);
    errdefer allocator.destroy(context);
    context.* = .{
        .allocator = allocator,
        .io = io,
        .arena = std.heap.ArenaAllocator.init(allocator),
        .environment = std.process.Environ.Map.init(allocator),
        .argv = &.{},
        .cwd = .inherit,
        .backend = undefined,
    };
    errdefer context.arena.deinit();
    errdefer secureEnvironmentDeinit(&context.environment);
    const owned = context.arena.allocator();
    const owned_argv = try owned.alloc([]const u8, argv.len);
    for (argv, owned_argv) |argument, *target|
        target.* = try owned.dupe(u8, argument);
    var iterator = environment.iterator();
    while (iterator.next()) |entry|
        try context.environment.put(entry.key_ptr.*, entry.value_ptr.*);
    context.argv = owned_argv;
    context.cwd = switch (cwd) {
        .path => |path| .{ .path = try owned.dupe(u8, path) },
        .inherit => .inherit,
        .dir => |dir| .{ .dir = dir },
    };
    context.backend = agent.McpStdioBackend.init(.{
        .io = io,
        .allocator = allocator,
        .endpoint = context.endpoint(),
    }) catch return error.InvalidConfig;
    return agent.McpTransportOwner.init(context.backend.transport(), StdioContext.destroy);
}

fn createStdioOwner(
    io: std.Io,
    allocator: std.mem.Allocator,
    server: mcp_configuration.ServerWire,
    preparation: *const mcp_configuration.Preparation,
    host_environment: HostEnvironment,
    observation: ?*process_observation.Slot,
) BuildError!agent.McpTransportOwner {
    const context = try allocator.create(StdioContext);
    errdefer allocator.destroy(context);
    context.* = .{
        .allocator = allocator,
        .io = io,
        .arena = std.heap.ArenaAllocator.init(allocator),
        .environment = std.process.Environ.Map.init(allocator),
        .argv = &.{},
        .cwd = .inherit,
        .backend = undefined,
    };
    errdefer context.arena.deinit();
    errdefer secureEnvironmentDeinit(&context.environment);
    const owned = context.arena.allocator();
    const argv = try owned.alloc([]const u8, server.transport.arguments.len + 1);
    argv[0] = try owned.dupe(u8, server.transport.command orelse
        return error.InvalidConfig);
    try installStdioHostEnvironment(
        &context.environment,
        allocator,
        host_environment,
        argv[0],
    );
    for (server.transport.arguments, argv[1..]) |argument, *target|
        target.* = try owned.dupe(u8, argument.literal orelse
            return error.InvalidConfig);
    for (server.transport.environment) |entry| {
        if (reservedStdioEnvironmentName(entry.name)) return error.InvalidConfig;
        const locator = entry.credential_ref orelse return error.InvalidConfig;
        const secret = resolvedCredential(preparation, locator) orelse
            return error.InvalidConfig;
        if (!mcp_configuration.validEnvironmentCredential(secret))
            return error.InvalidConfig;
        try context.environment.put(entry.name, secret);
    }
    const cwd: std.process.Child.Cwd = if (server.transport.cwd) |path|
        .{ .path = try owned.dupe(u8, path) }
    else
        .inherit;
    context.argv = argv;
    context.cwd = cwd;
    context.backend = agent.McpStdioBackend.init(.{
        .io = io,
        .allocator = allocator,
        .endpoint = context.endpoint(),
    }) catch return error.InvalidConfig;
    if (observation) |slot| {
        slot.retain();
        context.observation = slot;
    }
    return agent.McpTransportOwner.init(context.backend.transport(), StdioContext.destroy);
}

fn installStdioHostEnvironment(
    environment: *std.process.Environ.Map,
    allocator: std.mem.Allocator,
    host_environment: HostEnvironment,
    command: []const u8,
) BuildError!void {
    const inherited_path = host_environment.executable_search_path orelse
        return error.InvalidConfig;
    if (inherited_path.len == 0 or
        std.mem.indexOfScalar(u8, inherited_path, 0) != null)
        return error.InvalidConfig;
    const command_directory = std.fs.path.dirname(command);
    if (command_directory != null and std.fs.path.isAbsolute(command) and
        command_directory.?.len != 0)
    {
        const value = try std.fmt.allocPrint(
            allocator,
            "{s}{c}{s}",
            .{
                command_directory.?,
                if (builtin.os.tag == .windows) ';' else ':',
                inherited_path,
            },
        );
        defer allocator.free(value);
        try environment.put(
            if (builtin.os.tag == .windows) "Path" else "PATH",
            value,
        );
    } else {
        try environment.put(
            if (builtin.os.tag == .windows) "Path" else "PATH",
            inherited_path,
        );
    }

    if (builtin.os.tag == .windows) {
        const system_root = host_environment.windows_system_root orelse
            return error.InvalidConfig;
        if (system_root.len == 0 or
            std.mem.indexOfScalar(u8, system_root, 0) != null)
            return error.InvalidConfig;
        try environment.put("SystemRoot", system_root);
    }
}

fn reservedStdioEnvironmentName(name: []const u8) bool {
    if (builtin.os.tag == .windows)
        return std.ascii.eqlIgnoreCase(name, "SystemRoot") or
            std.ascii.eqlIgnoreCase(name, "Path");
    return std.mem.eql(u8, name, "PATH");
}

const HttpContext = struct {
    http_engine: *http_execution.Engine,
    /// Connection reuse belongs to this MCP server; retired with the owner.
    isolation: http_execution.Isolation,
    allocator: std.mem.Allocator,
    io: std.Io,
    arena: std.heap.ArenaAllocator,
    url: []const u8,
    custom_headers: []std.http.Header,
    secret_values: [][]u8,
    authorization: ?*HttpAuthSlot = null,
    draft_http_observation: ?*DraftHttpObservation = null,
    backend: agent.McpHttpBackend,

    const Inspection = struct {
        context: *HttpContext,
        lease: ?*const HttpAuthLease,

        fn check(raw: *anyopaque, bytes: []const u8) bool {
            const self: *@This() = @ptrCast(@alignCast(raw));
            for (self.context.secret_values) |secret|
                if (std.mem.indexOf(u8, bytes, secret) != null) return false;
            if (self.lease) |used| return used.slot.acceptsResponse(bytes);
            return true;
        }
    };

    fn destroy(raw: *anyopaque) void {
        const backend: *agent.McpHttpBackend = @ptrCast(@alignCast(raw));
        const self: *HttpContext = @fieldParentPtr("backend", backend);
        self.backend.deinit() catch @panic("MCP HTTP owner released with live connections");
        // Delete, disable, reconfiguration and shutdown all release the owner.
        self.http_engine.retire(self.isolation);
        if (self.authorization) |authorization| authorization.release();
        for (self.secret_values) |secret| std.crypto.secureZero(u8, secret);
        self.arena.deinit();
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    fn endpoint(self: *HttpContext) agent.McpAuthorizedEndpoint {
        return .{
            .context = self,
            .validate_fn = validateEndpoint,
            .perform_fn = perform,
        };
    }

    fn validateEndpoint(raw: *anyopaque) bool {
        const self: *HttpContext = @ptrCast(@alignCast(raw));
        return self.url.len != 0 and self.custom_headers.len <= max_custom_headers;
    }

    fn perform(
        raw: *anyopaque,
        request: agent.McpHttpRequest,
        sink: *const agent.McpHttpResponseSink,
    ) agent.McpHttpPerformOutcome {
        const self: *HttpContext = @ptrCast(@alignCast(raw));
        if (request.cancellation.isCancelled()) return .{ .failure = .cancelled };
        self.fetch(
            request,
            sink,
        ) catch |failure| return .{ .failure = switch (failure) {
            error.Timeout => .timeout,
            error.Cancelled => .cancelled,
            error.Auth => .auth,
            error.Server => .server,
            error.Network => .network,
            error.InvalidResponse => .fatal,
        } };
        return .completed;
    }

    const FetchFailure = error{ Timeout, Cancelled, Auth, Server, Network, InvalidResponse };
    fn fetch(self: *HttpContext, request: agent.McpHttpRequest, sink: *const agent.McpHttpResponseSink) FetchFailure!void {
        const result = self.http_engine.run(.{
            .consumer = .mcp,
            .isolation = self.isolation,
            .budget = .{ .deadline = .fromNow(self.io, .{ .raw = .fromMilliseconds(request.timeout_ms), .clock = .awake }) },
            .cancellation = .{ .context = &request.cancellation, .requested_fn = requested, .wait_fn = waitCancellation },
        }, fetchOne, .{ self, request, sink });
        return switch (result.outcome) {
            .completed => |response| response,
            .failed => |err| mapHttpError(err),
        };
    }

    fn mapHttpError(err: http_execution.Error) FetchFailure {
        return switch (err) {
            error.Cancelled => error.Cancelled,
            error.DeadlineExceeded => error.Timeout,
            error.InvalidRequest, error.InvalidResponse, error.ResponseTooLarge => error.InvalidResponse,
            else => error.Network,
        };
    }

    fn fetchOne(operation: *http_execution.Operation, self: *HttpContext, request_value: agent.McpHttpRequest, sink: *const agent.McpHttpResponseSink) FetchFailure!void {
        var authorization_lease = if (self.authorization) |authorization|
            authorization.lease()
        else
            null;
        defer if (authorization_lease) |*lease| lease.deinit();
        var inspection: Inspection = .{
            .context = self,
            .lease = if (authorization_lease) |*lease| lease else null,
        };
        const bearer = if (authorization_lease) |*lease| bearer: {
            const value = self.allocator.alloc(u8, "Bearer ".len + lease.token().len) catch
                return error.Network;
            @memcpy(value[0.."Bearer ".len], "Bearer ");
            @memcpy(value["Bearer ".len..], lease.token());
            break :bearer value;
        } else null;
        defer if (bearer) |value| {
            std.crypto.secureZero(u8, value);
            self.allocator.free(value);
        };
        var headers: [max_custom_headers + 8]std.http.Header = undefined;
        var request = try self.beginRequest(operation, request_value, bearer, &headers, &inspection);
        defer request.deinit();
        var response = request.receiveHead() catch |err| return mapHttpError(err);
        const status: u16 = @intFromEnum(response.head.status);
        self.observeHttpStatus(&response, status, &inspection, request_value.method == .post);
        if (response.head.content_encoding != .identity) return error.InvalidResponse;
        const exchange: Exchange = .{ .operation = operation, .request = request_value, .bearer = bearer, .inspection = &inspection };
        try self.deliverResponse(operation, &response, status, sink, &inspection, &exchange);
        if (!sink.inspect_fn(sink.context, .{ .context = &inspection, .check_fn = Inspection.check }))
            return error.InvalidResponse;
    }

    const Exchange = struct {
        operation: *http_execution.Operation,
        request: agent.McpHttpRequest,
        bearer: ?[]const u8,
        inspection: *Inspection,
    };

    fn beginRequest(self: *HttpContext, operation: *http_execution.Operation, request_value: agent.McpHttpRequest, bearer: ?[]const u8, headers: *[max_custom_headers + 8]std.http.Header, inspection: *Inspection) FetchFailure!http_execution.Request {
        if (!Inspection.check(inspection, request_value.body)) return error.InvalidResponse;
        const uri = std.Uri.parse(self.url) catch return error.InvalidResponse;
        var count: usize = 0;
        for (request_value.headers) |header| {
            if (count == headers.len) return error.InvalidResponse;
            headers[count] = .{ .name = header.name, .value = header.value };
            count += 1;
        }
        for (self.custom_headers) |header| {
            if (count == headers.len) return error.InvalidResponse;
            headers[count] = header;
            count += 1;
        }
        const method: std.http.Method = switch (request_value.method) {
            .post => .POST,
            .delete => .DELETE,
        };
        var request = operation.open(method, uri, .{
            .standard_headers = .{
                .accept_encoding = .{ .override = "identity" },
                .authorization = if (bearer) |value|
                    .{ .override = value }
                else
                    .default,
            },
            .headers = headers[0..count],
        }) catch |err| return mapHttpError(err);
        errdefer request.deinit();
        request.send(if (request_value.method == .post) request_value.body else null) catch |err| return mapHttpError(err);
        return request;
    }

    fn observeHttpStatus(self: *HttpContext, response: *std.http.Client.Response, status: u16, inspection: *Inspection, observe_draft: bool) void {
        if (status == 307 or status == 308) {
            if (observe_draft) if (self.draft_http_observation) |observation| {
                observation.recordRedirect(self.io, self.url, response);
            };
            return;
        }
        if (status != 401 and status != 403) return;
        var authenticate_storage: [mcp_oauth.Limits.header_bytes]u8 = undefined;
        defer std.crypto.secureZero(u8, &authenticate_storage);
        var authenticate_writer = std.Io.Writer.fixed(&authenticate_storage);
        var authenticate_invalid = false;
        var iterator = response.head.iterateHeaders();
        while (iterator.next()) |header| {
            if (!std.ascii.eqlIgnoreCase(header.name, "WWW-Authenticate")) continue;
            if (authenticate_writer.buffered().len != 0)
                authenticate_writer.writeAll(", ") catch {
                    authenticate_invalid = true;
                    break;
                };
            authenticate_writer.writeAll(header.value) catch {
                authenticate_invalid = true;
                break;
            };
        }
        if (observe_draft) if (self.draft_http_observation) |observation| {
            observation.record(self.io, status, if (authenticate_invalid) "" else authenticate_writer.buffered());
        };
        if (self.authorization) |authorization| if (inspection.lease) |lease| {
            var challenge = if (!authenticate_invalid and
                authenticate_writer.buffered().len != 0)
                mcp_oauth.parseRuntimeBearerChallenge(
                    self.allocator,
                    authenticate_writer.buffered(),
                ) catch null
            else
                null;
            defer if (challenge) |*value| value.deinit();
            if (challenge) |*value| {
                var scopes_safe = true;
                for (value.scopes) |scope| if (!Inspection.check(inspection, scope)) {
                    scopes_safe = false;
                    break;
                };
                authorization.recordRuntimeAuthFailure(lease, if (scopes_safe) value.scopes else null);
            } else authorization.recordHttpAuthRejection(lease);
        };
    }

    fn sendContinuation(self: *HttpContext, exchange: *const Exchange, post: agent.McpHttpContinuationPost) FetchFailure!void {
        exchange.operation.check() catch |err| return mapHttpError(err);
        var control = exchange.operation.control;
        control.continuation = true;
        const result = self.http_engine.run(control, continuation, .{ self, exchange, post });
        return switch (result.outcome) {
            .completed => |response| response,
            .failed => |err| mapHttpError(err),
        };
    }

    fn continuation(operation: *http_execution.Operation, self: *HttpContext, exchange: *const Exchange, post: agent.McpHttpContinuationPost) FetchFailure!void {
        var request_value = exchange.request;
        request_value.method = .post;
        request_value.headers = post.headers;
        request_value.body = post.body;
        var headers: [max_custom_headers + 8]std.http.Header = undefined;
        var request = try self.beginRequest(operation, request_value, exchange.bearer, &headers, exchange.inspection);
        defer request.deinit();
        var response = request.receiveHead() catch |err| return mapHttpError(err);
        if (response.head.content_encoding != .identity) return error.InvalidResponse;
        const status: u16 = @intFromEnum(response.head.status);
        self.observeHttpStatus(&response, status, exchange.inspection, true);
        try self.deliverResponse(operation, &response, status, &post.response_sink, exchange.inspection, null);
        if (!post.response_sink.inspect_fn(post.response_sink.context, .{ .context = exchange.inspection, .check_fn = Inspection.check })) return error.InvalidResponse;
    }

    fn deliverResponse(
        self: *HttpContext,
        operation: *http_execution.Operation,
        response: *std.http.Client.Response,
        status: u16,
        sink: *const agent.McpHttpResponseSink,
        inspection: *Inspection,
        exchange: ?*const Exchange,
    ) FetchFailure!void {
        if (sink.begin_fn(sink.context, status) == .stop) {
            // Request callbacks preserve a complete 401/403 response for
            // AgentCore. Notifications have no response descriptor, so keep
            // their transport-level auth classification after recording the
            // OAuth challenge above.
            if (status == 401 or status == 403) return error.Auth;
            return;
        }
        var iterator = response.head.iterateHeaders();
        while (iterator.next()) |header| {
            if (!Inspection.check(inspection, header.value)) return error.InvalidResponse;
            if (sink.header_fn(sink.context, header.name, header.value) == .stop) return;
        }
        if (sink.end_headers_fn(sink.context) == .stop) return;
        var transfer_buffer: [4096]u8 = undefined;
        defer std.crypto.secureZero(u8, &transfer_buffer);
        const reader = response.reader(&transfer_buffer);
        while (true) {
            operation.check() catch |err| return mapHttpError(err);
            const chunk = reader.peekGreedy(1) catch |err| switch (err) {
                error.EndOfStream => {
                    _ = sink.finish_fn(sink.context);
                    return;
                },
                else => return error.InvalidResponse,
            };
            const fed = sink.feed_fn(sink.context, chunk);
            if (fed.consumed > chunk.len) return error.InvalidResponse;
            reader.toss(fed.consumed);
            if (fed.flow == .stop) {
                const active = exchange orelse return;
                if (!sink.inspect_fn(sink.context, .{ .context = inspection, .check_fn = Inspection.check })) return error.InvalidResponse;
                switch (sink.control_fn(sink.context, .stopped)) {
                    .stop => return,
                    .continue_reading => return error.InvalidResponse,
                    .post => |post| {
                        try self.sendContinuation(active, post);
                        operation.check() catch |err| return mapHttpError(err);
                        switch (sink.control_fn(sink.context, .reply_completed)) {
                            .continue_reading => continue,
                            .stop => return,
                            .post => return error.InvalidResponse,
                        }
                    },
                }
            }
            if (fed.consumed != chunk.len) return error.InvalidResponse;
        }
    }

    fn requested(context: *const anyopaque) bool {
        const cancellation: *const agent.McpCancellation = @ptrCast(@alignCast(context));
        return cancellation.isCancelled();
    }

    fn waitCancellation(io: std.Io, context: *const anyopaque) std.Io.Cancelable!void {
        while (!requested(context)) try std.Io.sleep(io, .fromMilliseconds(5), .awake);
    }
};

fn createHttpOwner(
    http_engine: *http_execution.Engine,
    io: std.Io,
    allocator: std.mem.Allocator,
    server: mcp_configuration.ServerWire,
    preparation: *const mcp_configuration.Preparation,
    authorization_output: *?*HttpAuthSlot,
    draft_http_observation: ?*DraftHttpObservation,
) BuildError!agent.McpTransportOwner {
    authorization_output.* = null;
    const context = try allocator.create(HttpContext);
    errdefer allocator.destroy(context);
    context.* = .{
        .http_engine = http_engine,
        .isolation = .of(.mcp_server, server.id),
        .allocator = allocator,
        .io = io,
        .arena = std.heap.ArenaAllocator.init(allocator),
        .url = undefined,
        .custom_headers = &.{},
        .secret_values = &.{},
        .authorization = null,
        .draft_http_observation = draft_http_observation,
        .backend = undefined,
    };
    errdefer context.arena.deinit();
    errdefer if (context.authorization) |authorization| authorization.release();
    const owned = context.arena.allocator();
    context.url = mcp_configuration.resolveEndpoint(owned, server.transport, preparation.credentials, 4096) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidEndpoint => return error.InvalidConfig,
    };
    errdefer std.crypto.secureZero(u8, @constCast(context.url));
    context.custom_headers = try owned.alloc(std.http.Header, server.transport.headers.len);
    const installation_secret_count = if (server.installation) |operation| operation.credentials.len else @as(usize, 0);
    const private_secret_count = if (server.transport.sensitive_endpoint) |endpoint| 1 + endpoint.secret_parts.len else 0;
    context.secret_values = try owned.alloc([]u8, server.transport.headers.len + private_secret_count + installation_secret_count);
    for (context.secret_values) |*secret| secret.* = &.{};
    errdefer for (context.secret_values) |secret|
        if (secret.len != 0) std.crypto.secureZero(u8, secret);
    if (server.installation) |operation| for (operation.credentials, 0..) |slot, i| {
        const locator = slot.credential_ref orelse return error.InvalidConfig;
        const value = resolvedCredential(preparation, locator) orelse return error.InvalidConfig;
        context.secret_values[server.transport.headers.len + private_secret_count + i] = try owned.dupe(u8, value);
    };
    if (server.transport.sensitive_endpoint) |endpoint| {
        context.secret_values[server.transport.headers.len] = @constCast(context.url);
        for (endpoint.secret_parts, 0..) |part, i| {
            if (part >= endpoint.credential_refs.len) return error.InvalidConfig;
            const value = resolvedCredential(preparation, endpoint.credential_refs[part]) orelse return error.InvalidConfig;
            context.secret_values[server.transport.headers.len + 1 + i] = try owned.dupe(u8, value);
        }
    }
    for (server.transport.headers, context.custom_headers, context.secret_values[0..server.transport.headers.len]) |source, *header, *secret_value| {
        const locator = source.credential_ref orelse return error.InvalidConfig;
        const secret = resolvedCredential(preparation, locator) orelse
            return error.InvalidConfig;
        if (!mcp_configuration.validHttpHeaderCredential(secret))
            return error.InvalidConfig;
        secret_value.* = try owned.dupe(u8, secret);
        header.* = .{
            .name = try owned.dupe(u8, source.name),
            .value = secret_value.*,
        };
    }
    if (server.auth.oauth) |oauth| {
        const grant = oauth.grant orelse return error.InvalidConfig;
        const access_token = resolvedCredential(
            preparation,
            grant.access_token_ref,
        ) orelse return error.InvalidConfig;
        if (!mcp_configuration.validHttpHeaderCredential(access_token))
            return error.InvalidConfig;
        context.authorization = try HttpAuthSlot.create(
            allocator,
            io,
            server.id,
            mcp_configuration.runtimeDescriptorFingerprint(server),
            grant.consent_epoch,
            grant.token_revision,
            .{
                .access_token = access_token,
                .refresh_token = if (grant.refresh_token_ref) |locator|
                    resolvedCredential(preparation, locator) orelse return error.InvalidConfig
                else
                    null,
                .client_secret = if (oauth.registration.client_secret_ref) |locator|
                    resolvedCredential(preparation, locator) orelse return error.InvalidConfig
                else
                    null,
            },
        );
    }
    context.backend = agent.McpHttpBackend.init(.{
        .io = io,
        .allocator = allocator,
        .endpoint = context.endpoint(),
    }) catch return error.InvalidConfig;
    authorization_output.* = context.authorization;
    return agent.McpTransportOwner.init(context.backend.transport(), HttpContext.destroy);
}

fn secureEnvironmentDeinit(environment: *std.process.Environ.Map) void {
    for (environment.values()) |value|
        std.crypto.secureZero(u8, @constCast(value));
    environment.deinit();
}

fn secureFree(allocator: std.mem.Allocator, bytes: []u8) void {
    std.crypto.secureZero(u8, bytes);
    allocator.free(bytes);
}

test "STDIO receives only the required host process baseline" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer secureEnvironmentDeinit(&environment);
    try std.testing.expectError(
        error.InvalidConfig,
        installStdioHostEnvironment(
            &environment,
            std.testing.allocator,
            .{},
            if (builtin.os.tag == .windows) "C:\\Tools\\npx.cmd" else "/opt/tools/npx",
        ),
    );
    if (builtin.os.tag == .windows) {
        try installStdioHostEnvironment(
            &environment,
            std.testing.allocator,
            .{
                .executable_search_path = "C:\\Windows\\System32",
                .windows_system_root = "C:\\Windows",
            },
            "C:\\Tools\\npx.cmd",
        );
        try std.testing.expectEqual(@as(usize, 2), environment.count());
        try std.testing.expectEqualStrings(
            "C:\\Windows",
            environment.get("SystemRoot").?,
        );
        try std.testing.expectEqualStrings(
            "C:\\Tools;C:\\Windows\\System32",
            environment.get("Path").?,
        );
        try std.testing.expect(reservedStdioEnvironmentName("SYSTEMROOT"));
        try std.testing.expect(reservedStdioEnvironmentName("PATH"));
    } else {
        try installStdioHostEnvironment(
            &environment,
            std.testing.allocator,
            .{ .executable_search_path = "/usr/bin:/bin" },
            "/opt/tools/npx",
        );
        try std.testing.expectEqual(@as(usize, 1), environment.count());
        try std.testing.expectEqualStrings(
            "/opt/tools:/usr/bin:/bin",
            environment.get("PATH").?,
        );
        try std.testing.expect(!reservedStdioEnvironmentName("SystemRoot"));
        try std.testing.expect(reservedStdioEnvironmentName("PATH"));
    }
}

test "OAuth response inspection covers live revisions and retires the last old lease" {
    const slot = try HttpAuthSlot.create(std.testing.allocator, std.testing.io, "server", @splat(0), 1, 1, .{ .access_token = "access-one", .refresh_token = "refresh-one", .client_secret = "client-secret" });
    defer slot.release();
    const slots = try std.testing.allocator.alloc(*HttpAuthSlot, 1);
    slots[0] = slot;
    slot.retain();
    var authorizations: HttpAuthorizations = .{ .allocator = std.testing.allocator, .slots = slots };
    defer authorizations.deinit();
    var first = slot.lease();
    defer first.deinit();
    try std.testing.expectEqual(HttpAuthRotationOutcome.replaced, try authorizations.rotate("server", 1, 1, .{ .access_token = "access-two", .refresh_token = "refresh-two" }));
    var second = slot.lease();
    var second_owned = true;
    defer if (second_owned) second.deinit();
    try std.testing.expectEqual(HttpAuthRotationOutcome.replaced, try authorizations.rotate("server", 1, 2, .{ .access_token = "access-three", .refresh_token = "refresh-three" }));
    for ([_][]const u8{ "access-one", "access-two", "access-three", "refresh-one", "refresh-two", "refresh-three", "client-secret" }) |secret|
        try std.testing.expect(!slot.acceptsResponse(secret));
    second.deinit();
    second_owned = false;
    try std.testing.expect(slot.acceptsResponse("access-two"));
    try std.testing.expect(slot.acceptsResponse("refresh-two"));
    try std.testing.expect(!slot.acceptsResponse("access-one"));
    try std.testing.expect(slot.acceptsResponse("ordinary result"));
}

test "OAuth snapshot secret copies clean up every partial allocation" {
    const Probe = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const slot = try HttpAuthSlot.create(allocator, std.testing.io, "server", @splat(0), 1, 1, .{ .access_token = "access", .refresh_token = "refresh", .client_secret = "client" });
            defer slot.release();
            var lease = slot.lease();
            defer lease.deinit();
            try std.testing.expectEqualStrings("access", lease.token());
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.run, .{});
}

test "rejected candidate handoff excludes shared slots and preserves only its own failures" {
    const allocator = std.testing.allocator;
    for ([_]bool{ false, true }) |shared_failure| for ([_]bool{ false, true }) |candidate_failure| {
        var active = try testing.pendingAuthorizations(allocator, std.testing.io);
        defer active.deinit();
        if (!shared_failure) {
            var initial = try active.snapshotRuntimeAuthFailures();
            defer initial.deinit();
            _ = active.acknowledgeRuntimeAuthFailure(&initial.values[0]);
        }
        const shared = active.slots[0];
        const candidate = try HttpAuthSlot.create(allocator, std.testing.io, "candidate", @splat(0), 1, 1, .{ .access_token = "candidate-token" });
        const irrelevant = try HttpAuthSlot.create(allocator, std.testing.io, "idle", @splat(0), 1, 1, .{ .access_token = "idle-token" });
        if (candidate_failure) {
            var lease = candidate.lease();
            defer lease.deinit();
            candidate.recordRuntimeAuthFailure(&lease, &.{});
        }
        const slots = try allocator.alloc(*HttpAuthSlot, 3);
        shared.retain();
        slots[0] = shared;
        slots[1] = candidate;
        slots[2] = irrelevant;
        var rejected: HttpAuthorizations = .{ .allocator = allocator, .slots = slots };
        defer rejected.deinit();
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
        active.allocator = failing.allocator();
        active.retainRejectedFailures(&rejected);
        active.allocator = allocator;
        try std.testing.expectEqual(@as(usize, if (candidate_failure) 1 else 0), active.pending_slots.len);
        var batch = try active.snapshotRuntimeAuthFailures();
        defer batch.deinit();
        try std.testing.expectEqual(@as(usize, @intFromBool(shared_failure)) + @intFromBool(candidate_failure), batch.values.len);
        for (batch.values) |*failure| if (std.mem.eql(u8, failure.server_id, "candidate")) {
            try std.testing.expect(active.acknowledgeRuntimeAuthFailure(failure));
        };
        try std.testing.expectEqual(candidate_failure, active.releaseDeliveredFailures());
        try std.testing.expectEqual(@as(usize, 0), active.pending_slots.len);
        var remaining = try active.snapshotRuntimeAuthFailures();
        defer remaining.deinit();
        try std.testing.expectEqual(@as(usize, @intFromBool(shared_failure)), remaining.values.len);
    };
}

test "OAuth HTTP authorization rotates only by same-epoch revision CAS" {
    const slot = try HttpAuthSlot.create(
        std.testing.allocator,
        std.testing.io,
        "oauth-server",
        @splat(0),
        4,
        7,
        .{ .access_token = "old-access-token" },
    );
    defer slot.release();
    const slots = try std.testing.allocator.alloc(*HttpAuthSlot, 1);
    slots[0] = slot;
    slot.retain();
    var authorizations: HttpAuthorizations = .{
        .allocator = std.testing.allocator,
        .slots = slots,
    };
    defer authorizations.deinit();

    var in_flight = slot.lease();
    defer in_flight.deinit();
    var pending = (try authorizations.prepareRotation(
        "oauth-server",
        4,
        7,
        .{ .access_token = "new-access-token" },
    )).prepared;
    defer pending.deinit();
    pending.commit();
    try std.testing.expectEqualStrings("old-access-token", in_flight.token());
    var next = slot.lease();
    defer next.deinit();
    try std.testing.expectEqualStrings("new-access-token", next.token());
    try std.testing.expectEqual(
        HttpAuthRotationOutcome.consent_epoch_mismatch,
        try authorizations.rotate("oauth-server", 5, 8, .{ .access_token = "wrong-epoch" }),
    );
    try std.testing.expectEqual(
        HttpAuthRotationOutcome.token_revision_mismatch,
        try authorizations.rotate("oauth-server", 4, 7, .{ .access_token = "stale-revision" }),
    );
}

test "OAuth HTTP authorization reservation is exclusive and abandonment is retryable" {
    const slot = try HttpAuthSlot.create(
        std.testing.allocator,
        std.testing.io,
        "oauth-server",
        @splat(0),
        4,
        7,
        .{ .access_token = "old-access-token" },
    );
    defer slot.release();
    const slots = try std.testing.allocator.alloc(*HttpAuthSlot, 1);
    slots[0] = slot;
    slot.retain();
    var authorizations: HttpAuthorizations = .{
        .allocator = std.testing.allocator,
        .slots = slots,
    };
    defer authorizations.deinit();

    var first = (try authorizations.prepareRotation(
        "oauth-server",
        4,
        7,
        .{ .access_token = "first-token" },
    )).prepared;
    try std.testing.expect((try authorizations.prepareRotation(
        "oauth-server",
        4,
        7,
        .{ .access_token = "second-token" },
    )) == .token_revision_mismatch);
    first.deinit();

    var retry = (try authorizations.prepareRotation(
        "oauth-server",
        4,
        7,
        .{ .access_token = "retry-token" },
    )).prepared;
    defer retry.deinit();
    retry.commit();
    var lease = slot.lease();
    defer lease.deinit();
    try std.testing.expectEqualStrings("retry-token", lease.token());
}

test "OAuth HTTP authorization publishes the exact rejected snapshot fact" {
    const Wake = struct {
        calls: usize = 0,

        fn notify(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
        }
    };
    const slot = try HttpAuthSlot.create(
        std.testing.allocator,
        std.testing.io,
        "oauth-server",
        @splat(0),
        4,
        7,
        .{ .access_token = "old-access-token" },
    );
    defer slot.release();
    const slots = try std.testing.allocator.alloc(*HttpAuthSlot, 1);
    slots[0] = slot;
    slot.retain();
    var authorizations: HttpAuthorizations = .{
        .allocator = std.testing.allocator,
        .slots = slots,
    };
    defer authorizations.deinit();
    var wake: Wake = .{};
    authorizations.setRuntimeAuthFailureNotifier(.{
        .context = &wake,
        .notify_fn = Wake.notify,
    });

    var rejected = slot.lease();
    defer rejected.deinit();
    try std.testing.expectEqual(
        HttpAuthRotationOutcome.replaced,
        try authorizations.rotate("oauth-server", 4, 7, .{ .access_token = "new-access-token" }),
    );
    slot.recordRuntimeAuthFailure(&rejected, &.{ "files.write", "files.read" });
    try std.testing.expectEqual(@as(usize, 1), wake.calls);

    var batch = try authorizations.snapshotRuntimeAuthFailures();
    defer batch.deinit();
    try std.testing.expectEqual(@as(usize, 1), batch.values.len);
    const failure = &batch.values[0];
    try std.testing.expectEqualStrings("oauth-server", failure.server_id);
    try std.testing.expectEqual(@as(u64, 4), failure.consent_epoch);
    try std.testing.expectEqual(@as(u64, 7), failure.token_revision);
    try std.testing.expect(failure.challenge_scopes_complete);
    try std.testing.expectEqualStrings("files.read", failure.challenge_scopes[0]);
    try std.testing.expectEqualStrings("files.write", failure.challenge_scopes[1]);
    var retained = try authorizations.snapshotRuntimeAuthFailures();
    defer retained.deinit();
    try std.testing.expectEqual(@as(usize, 1), retained.values.len);
    try std.testing.expect(authorizations.acknowledgeRuntimeAuthFailure(failure));
    var empty = try authorizations.snapshotRuntimeAuthFailures();
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.values.len);
}

test "OAuth HTTP authorization exact acknowledgement retains a newer failure" {
    const slot = try HttpAuthSlot.create(
        std.testing.allocator,
        std.testing.io,
        "oauth-server",
        @splat(0),
        4,
        7,
        .{ .access_token = "access-token" },
    );
    defer slot.release();
    const slots = try std.testing.allocator.alloc(*HttpAuthSlot, 1);
    slots[0] = slot;
    slot.retain();
    var authorizations: HttpAuthorizations = .{
        .allocator = std.testing.allocator,
        .slots = slots,
    };
    defer authorizations.deinit();
    var rejected = slot.lease();
    defer rejected.deinit();

    slot.recordRuntimeAuthFailure(&rejected, &.{"files.read"});
    var first = try authorizations.snapshotRuntimeAuthFailures();
    defer first.deinit();
    slot.recordRuntimeAuthFailure(&rejected, &.{"files.write"});
    try std.testing.expect(!authorizations.acknowledgeRuntimeAuthFailure(&first.values[0]));

    var merged = try authorizations.snapshotRuntimeAuthFailures();
    defer merged.deinit();
    try std.testing.expectEqual(@as(usize, 2), merged.values[0].challenge_scopes.len);
    try std.testing.expect(authorizations.acknowledgeRuntimeAuthFailure(&merged.values[0]));
}

test "MCP platform owns stdio process pipes and stderr drain" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const request_bytes = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}";
    const response_bytes = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}";
    const script =
        \\printf 'discarded-secret' >&2
        \\while IFS= read -r line; do
        \\  [ "$line" = "$1" ] || exit 1
        \\  printf '%s\n' "$2"
        \\done
    ;
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    var owner = try createStdioTransportOwner(
        std.testing.io,
        std.testing.allocator,
        &.{ "/bin/sh", "-c", script, "mcp-stdio-fixture", request_bytes, response_bytes },
        .inherit,
        &environment,
    );
    defer owner.deinit();
    const transport = owner.transport;
    const connection = switch (transport.open_fn(
        transport.context,
        .actual,
        .modern_2026_07_28,
        1000,
    )) {
        .connection => |value| value,
        .failure => return error.TestUnexpectedResult,
    };
    var connection_open = true;
    defer if (connection_open) transport.close_fn(connection);
    const response = switch (transport.request_fn(
        connection,
        std.testing.allocator,
        request_bytes,
        1000,
        .{},
    )) {
        .response => |value| value,
        .failure => return error.TestUnexpectedResult,
    };
    defer std.testing.allocator.free(response.body);
    try std.testing.expectEqual(@as(u32, 0), response.http_status);
    try std.testing.expectEqualStrings(response_bytes, response.body);
    transport.close_fn(connection);
    connection_open = false;
}

test "MCP platform closes stdio after a normal child exit" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const request_bytes = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\"}";
    const response_bytes = "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{}}";
    const script =
        \\IFS= read -r line || exit 1
        \\[ "$line" = "$1" ] || exit 1
        \\printf '%s\n' "$2"
        \\exit 0
    ;
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    var owner = try createStdioTransportOwner(
        std.testing.io,
        std.testing.allocator,
        &.{ "/bin/sh", "-c", script, "mcp-stdio-fixture", request_bytes, response_bytes },
        .inherit,
        &environment,
    );
    defer owner.deinit();
    const transport = owner.transport;
    const connection = switch (transport.open_fn(
        transport.context,
        .actual,
        .modern_2026_07_28,
        1000,
    )) {
        .connection => |value| value,
        .failure => return error.TestUnexpectedResult,
    };
    var connection_open = true;
    defer if (connection_open) transport.close_fn(connection);
    const response = switch (transport.request_fn(
        connection,
        std.testing.allocator,
        request_bytes,
        1000,
        .{},
    )) {
        .response => |value| value,
        .failure => return error.TestUnexpectedResult,
    };
    defer std.testing.allocator.free(response.body);
    try std.testing.expectEqual(@as(u32, 0), response.http_status);
    try std.testing.expectEqualStrings(response_bytes, response.body);
    std.Io.Timeout.sleep(.{ .duration = .{
        .raw = std.Io.Duration.fromMilliseconds(20),
        .clock = .awake,
    } }, std.testing.io) catch {};
    transport.close_fn(connection);
    connection_open = false;
}

test "MCP HTTP rejects rotated credential echoes before returning JSON or SSE to Core" {
    const TestServer = struct {
        listener: *std.Io.net.Server,
        authorizations: *HttpAuthorizations,
        echoed: []const u8,
        sse: bool,
        requests: usize = 0,
        failure: ?anyerror = null,

        fn run(self: *@This()) void {
            self.serve() catch |err| {
                self.failure = err;
            };
        }

        fn serve(self: *@This()) !void {
            const io = std.testing.io;
            var stream = try self.listener.accept(io);
            defer stream.close(io);
            var read_buffer: [4096]u8 = undefined;
            var write_buffer: [4096]u8 = undefined;
            var reader = stream.reader(io, &read_buffer);
            var writer = stream.writer(io, &write_buffer);
            var http: std.http.Server = .init(&reader.interface, &writer.interface);
            var request = try http.receiveHead();
            var headers = request.iterateHeaders();
            var authorized = false;
            while (headers.next()) |header| if (std.ascii.eqlIgnoreCase(header.name, "Authorization")) {
                authorized = std.mem.eql(u8, header.value, "Bearer access-one");
            };
            if (!authorized) return error.UnexpectedAuthorization;
            self.requests += 1;
            if (try self.authorizations.rotate("server", 1, 1, .{ .access_token = "access-two", .refresh_token = "refresh-two" }) != .replaced)
                return error.UnexpectedRotation;
            var body: [512]u8 = undefined;
            const json = try std.fmt.bufPrint(&body, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\"{s}\"}}", .{self.echoed});
            var frame: [600]u8 = undefined;
            const payload = if (self.sse) try std.fmt.bufPrint(&frame, "data: {s}\n\n", .{json}) else json;
            try request.respond(payload, .{ .keep_alive = false, .extra_headers = &.{.{ .name = "Content-Type", .value = if (self.sse) "text/event-stream" else "application/json" }} });
        }
    };
    for ([_]bool{ false, true }) |sse| {
        for ([_][]const u8{ "access-one", "access-two", "refresh-one", "refresh-two", "client-secret", "static-secret", "ordinary" }) |echoed| {
            const allocator = std.testing.allocator;
            const io = std.testing.io;
            const slot = try HttpAuthSlot.create(allocator, io, "server", @splat(0), 1, 1, .{ .access_token = "access-one", .refresh_token = "refresh-one", .client_secret = "client-secret" });
            defer slot.release();
            const slots = try allocator.alloc(*HttpAuthSlot, 1);
            slots[0] = slot;
            slot.retain();
            var authorizations: HttpAuthorizations = .{ .allocator = allocator, .slots = slots };
            defer authorizations.deinit();
            var listener = try (std.Io.net.IpAddress{ .ip4 = .loopback(0) }).listen(io, .{ .kernel_backlog = 1 });
            defer listener.deinit(io);
            const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/mcp", .{listener.socket.address.getPort()});
            defer allocator.free(url);
            const secret = try allocator.dupe(u8, "static-secret");
            defer secureFree(allocator, secret);
            var secrets = [_][]u8{secret};
            var engine: http_execution.Engine = undefined;
            engine.init(allocator, io);
            defer engine.deinit();
            var context: HttpContext = .{ .http_engine = &engine, .isolation = .public, .allocator = allocator, .io = io, .arena = .init(allocator), .url = url, .custom_headers = &.{}, .secret_values = &secrets, .authorization = slot, .backend = undefined };
            defer context.arena.deinit();
            context.backend = try agent.McpHttpBackend.init(.{ .io = io, .allocator = allocator, .endpoint = context.endpoint() });
            defer context.backend.deinit() catch unreachable;
            const transport = context.backend.transport();
            if (std.mem.eql(u8, echoed, "ordinary")) {
                for ([_][]const u8{ "access-one", "refresh-one", "client-secret", "static-secret" }) |secret_value| {
                    const denied = switch (transport.open_fn(transport.context, .actual, .modern_2026_07_28, 100)) {
                        .connection => |value| value,
                        else => return error.TestUnexpectedResult,
                    };
                    defer transport.close_fn(denied);
                    var body: [256]u8 = undefined;
                    const request = try std.fmt.bufPrint(&body, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":\"{s}\"}}", .{secret_value});
                    // No server is accepting yet: a missing outbound guard
                    // would enter the network path and time out instead.
                    switch (transport.request_fn(denied, allocator, request, 100, .{})) {
                        .failure => |failure| try std.testing.expectEqual(@as(agent.McpTransportFailure, .fatal), failure),
                        .response => |response| {
                            allocator.free(response.body);
                            return error.TestUnexpectedResult;
                        },
                    }
                }
            }
            const connection = switch (transport.open_fn(transport.context, .actual, .modern_2026_07_28, 5000)) {
                .connection => |value| value,
                else => return error.TestUnexpectedResult,
            };
            defer transport.close_fn(connection);
            var server: TestServer = .{ .listener = &listener, .authorizations = &authorizations, .echoed = echoed, .sse = sse };
            const thread = try std.Thread.spawn(.{}, TestServer.run, .{&server});
            const outcome = transport.request_fn(connection, allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\"}", 5000, .{});
            thread.join();
            try std.testing.expectEqual(@as(?anyerror, null), server.failure);
            try std.testing.expectEqual(@as(usize, 1), server.requests);
            if (outcome == .response) {
                defer allocator.free(outcome.response.body);
                try std.testing.expectEqualStrings("ordinary", echoed);
            } else {
                try std.testing.expect(!std.mem.eql(u8, echoed, "ordinary"));
                try std.testing.expectEqual(@as(agent.McpTransportFailure, .fatal), outcome.failure);
            }
        }
    }
}

test "MCP platform returns a loopback SSE response before the stream closes" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .async_limit = .nothing });
    defer threaded.deinit();
    const TestServer = struct {
        io: std.Io,
        listener: *std.Io.net.Server,
        failure: ?anyerror = null,
        authorization_seen: bool = false,

        fn run(self: *@This()) void {
            self.serve() catch |err| {
                self.failure = err;
            };
        }

        fn serve(self: *@This()) !void {
            var connection = try self.listener.accept(self.io);
            defer connection.close(self.io);
            var read_buffer: [4096]u8 = undefined;
            var write_buffer: [4096]u8 = undefined;
            var stream_reader = connection.reader(self.io, &read_buffer);
            var stream_writer = connection.writer(self.io, &write_buffer);
            var server: std.http.Server = .init(
                &stream_reader.interface,
                &stream_writer.interface,
            );
            var request = try server.receiveHead();
            if (request.head.method != .POST) return error.UnexpectedMethod;
            var headers = request.iterateHeaders();
            while (headers.next()) |header| {
                if (!std.ascii.eqlIgnoreCase(header.name, "Authorization")) continue;
                if (!std.mem.eql(u8, header.value, "Bearer runtime-access-token"))
                    return error.UnexpectedAuthorization;
                self.authorization_seen = true;
            }
            if (!self.authorization_seen) return error.MissingAuthorization;
            var response_buffer: [512]u8 = undefined;
            var response = try request.respondStreaming(&response_buffer, .{
                .respond_options = .{
                    .keep_alive = true,
                    .extra_headers = &.{.{
                        .name = "Content-Type",
                        .value = "text/event-stream",
                    }},
                },
            });
            try response.writer.writeAll("data: {\"jsonrpc\":\"2.0\",\"id\":1}\n\n");
            try response.writer.flush();
            try response.flush();
            // Keep the event stream open until the client has accepted the
            // complete event and closed its non-reusable response connection.
            _ = stream_reader.interface.discardRemaining() catch {};
        }
    };

    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var listener = try address.listen(std.testing.io, .{
        .kernel_backlog = 1,
        .reuse_address = false,
    });
    defer listener.deinit(std.testing.io);
    var server: TestServer = .{ .io = std.testing.io, .listener = &listener };

    const url = try std.fmt.allocPrint(
        std.testing.allocator,
        "http://127.0.0.1:{d}/mcp",
        .{listener.socket.address.getPort()},
    );
    defer std.testing.allocator.free(url);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const authorization = try HttpAuthSlot.create(
        std.testing.allocator,
        std.testing.io,
        "remote",
        @splat(0),
        1,
        1,
        .{ .access_token = "runtime-access-token" },
    );
    defer authorization.release();
    var engine: http_execution.Engine = undefined;
    engine.init(std.testing.allocator, threaded.io());
    defer engine.deinit();
    var context: HttpContext = .{
        .http_engine = &engine,
        .isolation = .public,
        .allocator = std.testing.allocator,
        .io = threaded.io(),
        .arena = arena,
        .url = url,
        .custom_headers = &.{},
        .secret_values = &.{},
        .authorization = authorization,
        .backend = undefined,
    };
    context.backend = try agent.McpHttpBackend.init(.{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .endpoint = context.endpoint(),
    });
    defer context.backend.deinit() catch unreachable;
    const transport = context.backend.transport();
    const connection = switch (transport.open_fn(
        transport.context,
        .actual,
        .modern_2026_07_28,
        1000,
    )) {
        .connection => |value| value,
        .failure => return error.TestUnexpectedResult,
    };
    defer transport.close_fn(connection);
    const thread = try std.Thread.spawn(.{}, TestServer.run, .{&server});
    const result = transport.request_fn(
        connection,
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}",
        1000,
        .{},
    );
    thread.join();
    try std.testing.expectEqual(@as(?anyerror, null), server.failure);
    try std.testing.expect(server.authorization_seen);
    const response = switch (result) {
        .response => |value| value,
        .failure => return error.TestUnexpectedResult,
    };
    defer std.testing.allocator.free(response.body);
    try std.testing.expectEqual(@as(u32, 200), response.http_status);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":1}", response.body);
}

test "MCP HTTP ping keeps the original stream lease session deadline and cancellation" {
    const Scenario = enum { buffered, waiting, auth, scope_echo, ping_echo_old, ping_echo_new, cancel_pong, timeout_stream, wrong_session };
    const Peer = struct {
        io: std.Io,
        listener: *std.Io.net.Server,
        authorizations: *HttpAuthorizations,
        scenario: Scenario,
        cancelled: std.atomic.Value(bool) = .init(false),
        tool_posts: usize = 0,
        pongs: usize = 0,
        deletes: usize = 0,
        failure: ?anyerror = null,
        const rpc = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\"}";
        const pong = "{\"jsonrpc\":\"2.0\",\"id\":\"server-ping\",\"result\":{}}";
        const result = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"value\":42}}";
        fn isCancelled(raw: ?*const anyopaque) bool {
            return (@as(*const @This(), @ptrCast(@alignCast(raw.?)))).cancelled.load(.acquire);
        }
        fn run(self: *@This()) void {
            self.serve() catch |err| {
                if (err != error.Canceled) self.failure = err;
            };
        }
        fn headers(request: *std.http.Server.Request, token: []const u8, session: []const u8) !void {
            var iterator = request.iterateHeaders();
            var auth_ok = false;
            var era_ok = false;
            var observed_session: []const u8 = "";
            while (iterator.next()) |header| {
                if (std.ascii.eqlIgnoreCase(header.name, "Authorization")) auth_ok = std.mem.eql(u8, token, header.value);
                if (std.ascii.eqlIgnoreCase(header.name, "MCP-Protocol-Version")) era_ok = std.mem.eql(u8, "2026-07-28", header.value);
                if (std.ascii.eqlIgnoreCase(header.name, "Mcp-Session-Id")) observed_session = header.value;
            }
            if (!auth_ok or !era_ok or !std.mem.eql(u8, session, observed_session)) return error.UnexpectedHeaders;
        }
        fn body(request: *std.http.Server.Request, storage: []u8) ![]const u8 {
            if (request.head.method != .POST or request.head.content_length == null or request.head.content_length.? >= storage.len) return error.UnexpectedRequest;
            var transfer: [64]u8 = undefined;
            const reader = request.readerExpectNone(&transfer);
            const count = try reader.readSliceShort(storage);
            return storage[0..count];
        }
        fn serve(self: *@This()) !void {
            var original = try self.listener.accept(self.io);
            defer original.close(self.io);
            var original_read: [4096]u8 = undefined;
            var original_write: [4096]u8 = undefined;
            var original_reader = original.reader(self.io, &original_read);
            var original_writer = original.writer(self.io, &original_write);
            var server: std.http.Server = .init(&original_reader.interface, &original_writer.interface);
            var request = try server.receiveHead();
            try headers(&request, "Bearer access-one", "");
            var request_storage: [512]u8 = undefined;
            if (!std.mem.eql(u8, try body(&request, &request_storage), rpc)) return error.UnexpectedRequest;
            self.tool_posts += 1;
            if (try self.authorizations.rotate("server", 1, 1, .{ .access_token = "access-two", .refresh_token = "refresh-two" }) != .replaced) return error.UnexpectedRotation;
            var stream_buffer: [1024]u8 = undefined;
            var response = try request.respondStreaming(&stream_buffer, .{ .respond_options = .{ .keep_alive = true, .extra_headers = &.{ .{ .name = "Content-Type", .value = "text/event-stream" }, .{ .name = "Mcp-Session-Id", .value = "stream-session" } } } });
            const ping_id = switch (self.scenario) {
                .ping_echo_old => "access-one",
                .ping_echo_new => "access-two",
                else => "server-ping",
            };
            try response.writer.print("data: {{\"jsonrpc\":\"2.0\",\"method\":\"ping\",\"id\":\"{s}\"}}\r\n\r\n", .{ping_id});
            if (self.scenario == .buffered) {
                try response.writer.writeAll("data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"}\n\n");
                try response.writer.print("data: {s}\n\n", .{result});
            }
            try response.writer.flush();
            try response.flush();
            var reply_stream = try self.listener.accept(self.io);
            defer reply_stream.close(self.io);
            var reply_read: [4096]u8 = undefined;
            var reply_write: [4096]u8 = undefined;
            var reply_reader = reply_stream.reader(self.io, &reply_read);
            var reply_writer = reply_stream.writer(self.io, &reply_write);
            var reply_server: std.http.Server = .init(&reply_reader.interface, &reply_writer.interface);
            var reply = try reply_server.receiveHead();
            try headers(&reply, "Bearer access-one", "stream-session");
            var reply_storage: [512]u8 = undefined;
            const reply_body = try body(&reply, &reply_storage);
            if (std.mem.eql(u8, reply_body, rpc)) self.tool_posts += 1 else self.pongs += 1;
            if (!std.mem.eql(u8, reply_body, pong)) return error.UnexpectedPong;
            if (self.scenario == .cancel_pong) {
                self.cancelled.store(true, .release);
                try std.Io.sleep(self.io, .fromSeconds(60), .awake);
                return error.ExpectedCancellation;
            }
            if (self.scenario == .auth or self.scenario == .scope_echo) {
                try reply.respond("{\"error\":\"denied\"}", .{ .status = .unauthorized, .keep_alive = false, .extra_headers = &.{ .{ .name = "Content-Type", .value = "application/json" }, .{ .name = "WWW-Authenticate", .value = if (self.scenario == .scope_echo) "Bearer scope=\"access-two\"" else "Bearer scope=\"files.read\"" } } });
            } else {
                try reply.respond("", .{ .status = .accepted, .keep_alive = false, .extra_headers = if (self.scenario == .wrong_session) &.{.{ .name = "Mcp-Session-Id", .value = "wrong-session" }} else &.{} });
            }
            if (self.scenario == .timeout_stream) {
                try std.Io.sleep(self.io, .fromSeconds(60), .awake);
                return error.ExpectedTimeout;
            }
            if (self.scenario == .waiting) {
                try response.writer.print("data: {s}\n\n", .{result});
                try response.writer.flush();
                try response.flush();
            }
            _ = original_reader.interface.discardRemaining() catch {};
            if (self.scenario != .buffered and self.scenario != .waiting) return;
            var close_stream = try self.listener.accept(self.io);
            defer close_stream.close(self.io);
            var close_read: [4096]u8 = undefined;
            var close_write: [4096]u8 = undefined;
            var close_reader = close_stream.reader(self.io, &close_read);
            var close_writer = close_stream.writer(self.io, &close_write);
            var close_server: std.http.Server = .init(&close_reader.interface, &close_writer.interface);
            var close = try close_server.receiveHead();
            if (close.head.method != .DELETE) return error.UnexpectedRequest;
            try headers(&close, "Bearer access-two", "stream-session");
            self.deletes += 1;
            try close.respond("", .{ .keep_alive = false });
        }
    };
    for (std.enums.values(Scenario)) |scenario| {
        const allocator = std.testing.allocator;
        var threaded = std.Io.Threaded.init(allocator, .{ .async_limit = .nothing });
        defer threaded.deinit();
        const io = threaded.io();
        const slot = try HttpAuthSlot.create(allocator, io, "server", @splat(0), 1, 1, .{ .access_token = "access-one", .refresh_token = "refresh-one", .client_secret = "client-secret" });
        defer slot.release();
        const slots = try allocator.alloc(*HttpAuthSlot, 1);
        slots[0] = slot;
        slot.retain();
        var authorizations: HttpAuthorizations = .{ .allocator = allocator, .slots = slots };
        defer authorizations.deinit();
        var listener = try (std.Io.net.IpAddress{ .ip4 = .loopback(0) }).listen(io, .{ .kernel_backlog = 2 });
        defer listener.deinit(io);
        const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/mcp", .{listener.socket.address.getPort()});
        defer allocator.free(url);
        var engine: http_execution.Engine = undefined;
        engine.init(allocator, io);
        defer engine.deinit();
        var context: HttpContext = .{ .http_engine = &engine, .isolation = .public, .allocator = allocator, .io = io, .arena = .init(allocator), .url = url, .custom_headers = &.{}, .secret_values = &.{}, .authorization = slot, .backend = undefined };
        defer context.arena.deinit();
        context.backend = try agent.McpHttpBackend.init(.{ .io = io, .allocator = allocator, .endpoint = context.endpoint(), .max_response_bytes = 4096 });
        defer context.backend.deinit() catch unreachable;
        const transport = context.backend.transport();
        const connection = transport.open_fn(transport.context, .actual, .modern_2026_07_28, 5000).connection;
        var open = true;
        defer if (open) transport.close_fn(connection);
        var peer: Peer = .{ .io = io, .listener = &listener, .authorizations = &authorizations, .scenario = scenario };
        var task = try std.Io.concurrent(io, Peer.run, .{&peer});
        var running = true;
        defer if (running) task.cancel(io);
        const outcome = transport.request_fn(connection, allocator, Peer.rpc, if (scenario == .timeout_stream) 200 else 5000, .{ .context = &peer, .is_cancelled_fn = Peer.isCancelled });
        transport.close_fn(connection);
        open = false;
        task.cancel(io);
        running = false;
        try std.testing.expectEqual(@as(?anyerror, null), peer.failure);
        try std.testing.expectEqual(@as(usize, 1), peer.tool_posts);
        try std.testing.expectEqual(@as(usize, if (scenario == .ping_echo_old or scenario == .ping_echo_new) 0 else 1), peer.pongs);
        const success = scenario == .buffered or scenario == .waiting;
        try std.testing.expectEqual(@as(usize, if (success) 1 else 0), peer.deletes);
        if (success) {
            try std.testing.expect(outcome == .response);
            defer allocator.free(outcome.response.body);
            try std.testing.expectEqualStrings(Peer.result, outcome.response.body);
        } else {
            const failure: agent.McpTransportFailure = switch (scenario) {
                .auth, .scope_echo => .auth,
                .cancel_pong => .cancelled,
                .timeout_stream => .timeout,
                else => .fatal,
            };
            try std.testing.expectEqual(failure, outcome.failure);
        }
        try std.testing.expect(slot.current.next == null);
        var facts = try authorizations.snapshotRuntimeAuthFailures();
        defer facts.deinit();
        if (scenario == .auth or scenario == .scope_echo) {
            try std.testing.expectEqual(@as(usize, 1), facts.values.len);
            try std.testing.expectEqual(@as(u64, 1), facts.values[0].token_revision);
            try std.testing.expectEqual(scenario == .auth, facts.values[0].challenge_scopes_complete);
            if (scenario == .auth) try std.testing.expectEqualStrings("files.read", facts.values[0].challenge_scopes[0]) else try std.testing.expectEqual(@as(usize, 0), facts.values[0].challenge_scopes.len);
        } else try std.testing.expectEqual(@as(usize, 0), facts.values.len);
    }
}

pub const testing = if (builtin.is_test) struct {
    pub fn pendingAuthorizations(allocator: std.mem.Allocator, io: std.Io) !HttpAuthorizations {
        const slot = try HttpAuthSlot.create(allocator, io, "server", @splat(0), 1, 1, .{ .access_token = "fixture-access" });
        errdefer slot.release();
        var lease = slot.lease();
        defer lease.deinit();
        slot.recordRuntimeAuthFailure(&lease, &.{});
        const slots = try allocator.alloc(*HttpAuthSlot, 1);
        slots[0] = slot;
        return .{ .allocator = allocator, .slots = slots };
    }
} else struct {};

const ProcessFixture = if (builtin.is_test) struct {
    const echo = "require('node:readline').createInterface({input:process.stdin}).on('line',line=>process.stdout.write(line+'\\n'));";
    const hold = "process.stdin.resume();process.stdin.on('data',()=>process.stdout.write('waiting\\n'));";
    var cancellation: std.atomic.Value(bool) = .init(false);

    fn context(io: std.Io, argv: []const []const u8) !StdioContext {
        var environment = std.process.Environ.Map.init(std.testing.allocator);
        errdefer environment.deinit();
        try installStdioHostEnvironment(&environment, std.testing.allocator, testHostEnvironment(), argv[0]);
        return .{ .allocator = std.testing.allocator, .io = io, .arena = std.heap.ArenaAllocator.init(std.testing.allocator), .environment = environment, .argv = argv, .cwd = .inherit, .backend = undefined };
    }

    fn cancelled(_: ?*const anyopaque) bool {
        return cancellation.load(.acquire);
    }

    fn feed(_: *anyopaque, bytes: []const u8) agent.McpStdioFeedOutcome {
        return .{ .consumed = bytes.len, .flow = .stop };
    }

    fn cancelOnResponse(_: *anyopaque, bytes: []const u8) agent.McpStdioFeedOutcome {
        cancellation.store(true, .release);
        return .{ .consumed = bytes.len, .flow = .continue_reading };
    }

    fn finish(_: *anyopaque) agent.McpStdioSinkFlow {
        return .stop;
    }
} else struct {};

test "MCP real process exchange and notify progress without async capacity" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .async_limit = .nothing });
    defer threaded.deinit();
    const argv = [_][]const u8{ @import("mcp_platform_test_options").node_path, "-e", ProcessFixture.echo };
    var context = try ProcessFixture.context(threaded.io(), &argv);
    defer context.arena.deinit();
    defer context.environment.deinit();
    const connection = try context.openConnection();
    defer connection.deinit();
    var sink: agent.McpStdioResponseSink = .{ .context = &context, .feed_fn = ProcessFixture.feed, .finish_fn = ProcessFixture.finish };
    const write: agent.McpStdioWrite = .{ .fragments = &.{"{}\n"}, .timeout_ms = 5000, .cancellation = .{} };
    try std.testing.expect(StdioContext.exchange(&context, connection, write, &sink) == .completed);
    try std.testing.expectEqual(@as(?agent.McpStdioPortFailure, null), StdioContext.notify(&context, connection, write));
    try std.testing.expect(!connection.dead.load(.acquire));
}

test "MCP process observations distinguish missing executable from started STDIO closure" {
    const Host = struct {
        fn notify(_: *anyopaque) void {}
    };
    var marker: u8 = 0;
    const server: mcp_configuration.ServerWire = .{ .id = "local", .namespace = "local", .display_name = "Local", .enabled = true, .negotiation = "modern_only", .timeout_ms = 5000, .transport = .{ .kind = "stdio", .command = "node" }, .auth = .{ .kind = "none", .oauth = null }, .connection_approval = null, .tools = &.{} };
    const slot = try process_observation.Slot.init(std.testing.allocator, server, 1, .{ .context = &marker, .notify_fn = Host.notify });
    defer slot.release();
    var missing = try ProcessFixture.context(std.testing.io, &.{"metawork-missing-process-fixture-7ab419"});
    defer missing.environment.deinit();
    defer missing.arena.deinit();
    missing.observation = slot;
    try std.testing.expect(StdioContext.open(&missing, 5000) == .failure);
    try std.testing.expectEqual(mcp_configuration.ProcessFact.executable_missing, slot.snapshot().fact);
    const argv = [_][]const u8{ @import("mcp_platform_test_options").node_path, "-e", "process.stderr.write('SYNTHETIC-RAW-STDERR');process.exit(7);" };
    var context = try ProcessFixture.context(std.testing.io, &argv);
    defer context.environment.deinit();
    defer context.arena.deinit();
    context.observation = slot;
    const connection = try context.openConnection();
    defer connection.deinit();
    try std.testing.expectEqual(mcp_configuration.ProcessFact.spawned, slot.snapshot().fact);
    var sink: agent.McpStdioResponseSink = .{ .context = &context, .feed_fn = ProcessFixture.feed, .finish_fn = ProcessFixture.finish };
    try std.testing.expect(StdioContext.pumpExchange(connection, &.{}, &sink) == .completed);
    try std.testing.expectEqual(mcp_configuration.ProcessFact.stdio_closed, slot.snapshot().fact);
    // EOF is a pipe fact; it did not turn into a fabricated exit status.
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 7 }, try connection.child.wait(std.testing.io));
}

test "MCP concurrent connections close independently" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .async_limit = .nothing });
    defer threaded.deinit();
    const io = threaded.io();
    const argv = [_][]const u8{ @import("mcp_platform_test_options").node_path, "-e", ProcessFixture.echo };
    var context = try ProcessFixture.context(io, &argv);
    defer context.arena.deinit();
    defer context.environment.deinit();
    var first = try std.Io.concurrent(io, StdioContext.openConnection, .{&context});
    var second = std.Io.concurrent(io, StdioContext.openConnection, .{&context}) catch |err| {
        if (first.cancel(io)) |conn| conn.deinit() else |_| {}
        return err;
    };
    defer if (second.cancel(io)) |conn| conn.deinit() else |_| {};
    const one = try first.await(io);
    one.deinit();
    const two = try second.await(io);
    var sink: agent.McpStdioResponseSink = .{ .context = &context, .feed_fn = ProcessFixture.feed, .finish_fn = ProcessFixture.finish };
    try std.testing.expect(StdioContext.exchange(&context, two, .{ .fragments = &.{"{}\n"}, .timeout_ms = 5000, .cancellation = .{} }, &sink) == .completed);
}

test "MCP failed stderr task creation releases process resources" {
    const Probe = struct {
        fn concurrent(_: ?*anyopaque, _: usize, _: std.mem.Alignment, _: []const u8, _: std.mem.Alignment, _: *const fn (*const anyopaque, *anyopaque) void) std.Io.ConcurrentError!*std.Io.AnyFuture {
            return error.ConcurrencyUnavailable;
        }
    };
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .async_limit = .nothing });
    defer threaded.deinit();
    var vtable = threaded.io().vtable.*;
    vtable.concurrent = Probe.concurrent;
    const io: std.Io = .{ .userdata = threaded.io().userdata, .vtable = &vtable };
    const argv = [_][]const u8{ @import("mcp_platform_test_options").node_path, "-e", ProcessFixture.echo };
    var context = try ProcessFixture.context(io, &argv);
    defer context.arena.deinit();
    defer context.environment.deinit();
    try std.testing.expectError(error.ResourceUnavailable, context.openConnection());
}

test "MCP Windows close terminates descendants after their launcher exits" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const Probe = struct {
        extern "kernel32" fn OpenProcess(u32, i32, u32) callconv(.winapi) ?std.os.windows.HANDLE;
        bytes: [32]u8 = undefined,
        len: usize = 0,

        fn feed(raw: *anyopaque, bytes: []const u8) agent.McpStdioFeedOutcome {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const newline = std.mem.indexOfScalar(u8, bytes, '\n');
            const count = if (newline) |index| index + 1 else bytes.len;
            if (count > self.bytes.len - self.len) return .{ .consumed = 0, .flow = .stop };
            @memcpy(self.bytes[self.len..][0..count], bytes[0..count]);
            self.len += count;
            return .{ .consumed = count, .flow = if (newline != null) .stop else .continue_reading };
        }
    };
    const script =
        \\const {spawn} = require('node:child_process');
        \\const child = spawn(process.execPath, ['-e', "setInterval(()=>{},1000)"], {stdio:['ignore','inherit','inherit']});
        \\process.stdout.write(String(child.pid) + String.fromCharCode(10));
        \\child.unref();
    ;
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .async_limit = .nothing });
    defer threaded.deinit();
    const io = threaded.io();
    const argv = [_][]const u8{ @import("mcp_platform_test_options").node_path, "-e", script };
    var context = try ProcessFixture.context(io, &argv);
    defer context.arena.deinit();
    defer context.environment.deinit();
    const connection = try context.openConnection();
    var connection_open = true;
    defer if (connection_open) connection.deinit();
    var probe: Probe = .{};
    var sink: agent.McpStdioResponseSink = .{ .context = &probe, .feed_fn = Probe.feed, .finish_fn = ProcessFixture.finish };
    try std.testing.expect(StdioContext.exchange(&context, connection, .{ .fragments = &.{}, .timeout_ms = 5000, .cancellation = .{} }, &sink) == .completed);
    const pid = try std.fmt.parseInt(u32, std.mem.trim(u8, probe.bytes[0..probe.len], "\r\n"), 10);
    const process = Probe.OpenProcess(0x00100001, 0, pid) orelse return error.TestUnexpectedResult;
    defer std.os.windows.CloseHandle(process);
    defer _ = std.os.windows.ntdll.NtTerminateProcess(process, @enumFromInt(1));
    const zero: std.os.windows.LARGE_INTEGER = 0;
    try std.testing.expectEqual(std.os.windows.NTSTATUS.TIMEOUT, std.os.windows.ntdll.NtWaitForSingleObject(process, .FALSE, &zero));
    // Waiting only for the launcher is bounded: the unreferenced child cannot
    // keep it alive. The Job must retain responsibility for that descendant.
    _ = try connection.child.wait(io);
    connection.deinit();
    connection_open = false;
    const timeout: std.os.windows.LARGE_INTEGER = -5 * 10_000_000;
    try std.testing.expectEqual(std.os.windows.NTSTATUS.WAIT_0, std.os.windows.ntdll.NtWaitForSingleObject(process, .FALSE, &timeout));
}

test "MCP Windows close cancels stderr while an unrelated process holds its writer" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .async_limit = .nothing });
    defer threaded.deinit();
    const io = threaded.io();
    const argv = [_][]const u8{ @import("mcp_platform_test_options").node_path, "-e", ProcessFixture.echo };
    var context = try ProcessFixture.context(io, &argv);
    defer context.arena.deinit();
    defer context.environment.deinit();
    const connection = try context.openConnection();
    var connection_open = true;
    defer if (connection_open) connection.deinit();

    // Force the escaped-writer condition, independently of spawn scheduling.
    // The holder is deliberately outside the MCP Job and our spawn lock.
    const pipe = try threaded.windowsCreatePipe(.{
        .server = .{ .attributes = .{ .INHERIT = false }, .mode = .{ .IO = .ASYNCHRONOUS } },
        .client = .{ .attributes = .{ .INHERIT = true }, .mode = .{ .IO = .SYNCHRONOUS_NONALERT } },
        .inbound = true,
    });
    var read_open = true;
    var write_open = true;
    defer if (read_open) std.os.windows.CloseHandle(pipe[0]);
    defer if (write_open) std.os.windows.CloseHandle(pipe[1]);
    var holder = try std.process.spawn(io, .{
        .argv = &.{ argv[0], "-e", "process.stdin.resume();" },
        .environ_map = &context.environment,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
        .create_no_window = true,
    });
    defer holder.kill(io);
    std.os.windows.CloseHandle(pipe[1]);
    write_open = false;
    connection.stderr_task.cancel(io);
    connection.stderr = .{ .handle = pipe[0], .flags = .{ .nonblocking = true } };
    read_open = false;
    connection.stderr_task = std.Io.concurrent(io, StdioContext.drainStderr, .{connection}) catch |err| {
        connection.stderr.close(io);
        return err;
    };

    const Closing = struct {
        fn run(conn: *StdioContext.Connection, done: *std.Io.Event) void {
            const task_io = conn.context.io;
            conn.deinit();
            done.set(task_io);
        }
    };
    var done: std.Io.Event = .unset;
    const closer = try std.Thread.spawn(.{}, Closing.run, .{ connection, &done });
    connection_open = false;
    const completed = completed: {
        done.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } }) catch {
            // Unblock an EOF-dependent regression so the test fails rather
            // than hanging the complete Native graph.
            holder.stdin.?.close(io);
            holder.stdin = null;
            break :completed false;
        };
        break :completed true;
    };
    closer.join();
    try std.testing.expect(completed);
    const zero: std.os.windows.LARGE_INTEGER = 0;
    try std.testing.expectEqual(std.os.windows.NTSTATUS.TIMEOUT, std.os.windows.ntdll.NtWaitForSingleObject(holder.id.?, .FALSE, &zero));
}

test "MCP real process cancellation and deadline terminate blocked exchange" {
    for ([_]bool{ false, true }) |cancel| {
        var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .async_limit = .nothing });
        defer threaded.deinit();
        ProcessFixture.cancellation.store(false, .release);
        const argv = [_][]const u8{ @import("mcp_platform_test_options").node_path, "-e", ProcessFixture.hold };
        var context = try ProcessFixture.context(threaded.io(), &argv);
        defer context.arena.deinit();
        defer context.environment.deinit();
        const connection = try context.openConnection();
        defer connection.deinit();
        var sink: agent.McpStdioResponseSink = .{ .context = &context, .feed_fn = if (cancel) ProcessFixture.cancelOnResponse else ProcessFixture.feed, .finish_fn = ProcessFixture.finish };
        // A deadline case sends no input, so the child keeps stdout open silently.
        const write: agent.McpStdioWrite = .{ .fragments = if (cancel) &.{"{}\n"} else &.{}, .timeout_ms = if (cancel) 5000 else 100, .cancellation = .{ .is_cancelled_fn = ProcessFixture.cancelled } };
        const result = StdioContext.exchange(&context, connection, write, &sink);
        try std.testing.expectEqual(@as(agent.McpStdioPortFailure, if (cancel) .cancelled else .timeout), result.failure);
        try std.testing.expect(connection.dead.load(.acquire));
    }
}

test "MCP real process partial registration failure terminates exchange and notify" {
    const Probe = struct {
        var io: std.Io = undefined;
        var registered: usize = 0;
        var fail_at: usize = 0;

        fn concurrent(userdata: ?*anyopaque, group: *std.Io.Group, bytes: []const u8, alignment: std.mem.Alignment, start_fn: *const fn (*const anyopaque) void) std.Io.ConcurrentError!void {
            const index = registered;
            registered += 1;
            if (index == fail_at) return error.ConcurrencyUnavailable;
            return io.vtable.groupConcurrent(userdata, group, bytes, alignment, start_fn);
        }
    };
    for ([_]bool{ false, true }) |notify| {
        for (0..3) |fail_at| {
            var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .async_limit = .nothing });
            defer threaded.deinit();
            Probe.io = threaded.io();
            Probe.registered = 0;
            Probe.fail_at = fail_at;
            var vtable = Probe.io.vtable.*;
            vtable.groupConcurrent = Probe.concurrent;
            const io: std.Io = .{ .userdata = Probe.io.userdata, .vtable = &vtable };
            const argv = [_][]const u8{ @import("mcp_platform_test_options").node_path, "-e", ProcessFixture.hold };
            var context = try ProcessFixture.context(io, &argv);
            defer context.arena.deinit();
            defer context.environment.deinit();
            const connection = try context.openConnection();
            defer connection.deinit();
            var sink: agent.McpStdioResponseSink = .{ .context = &context, .feed_fn = ProcessFixture.feed, .finish_fn = ProcessFixture.finish };
            const write: agent.McpStdioWrite = .{ .fragments = &.{"{}\n"}, .timeout_ms = 5000, .cancellation = .{} };
            if (notify)
                try std.testing.expectEqual(@as(?agent.McpStdioPortFailure, .fatal), StdioContext.notify(&context, connection, write))
            else
                try std.testing.expectEqual(agent.McpStdioPortFailure.fatal, StdioContext.exchange(&context, connection, write, &sink).failure);
            try std.testing.expectEqual(fail_at + 1, Probe.registered);
            try std.testing.expect(connection.dead.load(.acquire));
        }
    }
}

test "MCP real process cancellation and deadline interrupt a blocked notification write" {
    const Probe = struct {
        var checks: std.atomic.Value(usize) = .init(0);
        fn cancelled(_: ?*const anyopaque) bool {
            return checks.fetchAdd(1, .monotonic) > 0;
        }
    };
    for ([_]bool{ false, true }) |cancel| {
        Probe.checks.store(0, .monotonic);
        var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .async_limit = .nothing });
        defer threaded.deinit();
        const argv = [_][]const u8{ @import("mcp_platform_test_options").node_path, "-e", "setInterval(()=>{},1000);" };
        var context = try ProcessFixture.context(threaded.io(), &argv);
        defer context.arena.deinit();
        defer context.environment.deinit();
        const connection = try context.openConnection();
        defer connection.deinit();
        const payload = try std.testing.allocator.alloc(u8, 1024 * 1024);
        defer std.testing.allocator.free(payload);
        @memset(payload, 'x');
        const write: agent.McpStdioWrite = .{ .fragments = &.{payload}, .timeout_ms = if (cancel) 5000 else 100, .cancellation = if (cancel) .{ .is_cancelled_fn = Probe.cancelled } else .{} };
        try std.testing.expectEqual(@as(?agent.McpStdioPortFailure, if (cancel) .cancelled else .timeout), StdioContext.notify(&context, connection, write));
        try std.testing.expect(connection.dead.load(.acquire));
    }
}

test "MCP HTTP cancellation deadline and partial startup failure close the request" {
    const Fixture = struct {
        var io: std.Io = undefined;
        var registered: usize = 0;
        var fail_at: ?usize = null;
        var received: std.Io.Event = .unset;
        var cancellation: std.atomic.Value(bool) = .init(false);
        listener: *std.Io.net.Server,
        cancel: bool,
        failure: ?anyerror = null,

        fn concurrent(userdata: ?*anyopaque, group: *std.Io.Group, bytes: []const u8, alignment: std.mem.Alignment, start_fn: *const fn (*const anyopaque) void) std.Io.ConcurrentError!void {
            const index = registered;
            registered += 1;
            if (fail_at == index) {
                return error.ConcurrencyUnavailable;
            }
            return io.vtable.groupConcurrent(userdata, group, bytes, alignment, start_fn);
        }

        fn cancelled(_: ?*const anyopaque) bool {
            return cancellation.load(.acquire);
        }

        fn run(self: *@This()) void {
            self.serve() catch |err| {
                self.failure = err;
            };
        }

        fn serve(self: *@This()) !void {
            var connection = try self.listener.accept(std.testing.io);
            defer connection.close(std.testing.io);
            var reads: [4096]u8 = undefined;
            var writes: [256]u8 = undefined;
            var reader = connection.reader(std.testing.io, &reads);
            var writer = connection.writer(std.testing.io, &writes);
            var server = std.http.Server.init(&reader.interface, &writer.interface);
            var request = try server.receiveHead();
            const body = request.readerExpectNone(&.{});
            var data: [2]u8 = undefined;
            try body.readSliceAll(&data);
            received.set(std.testing.io);
            if (self.cancel) cancellation.store(true, .release);
            // EOF proves the failed/cancelled fetch has released its socket.
            _ = reader.interface.takeByte() catch |err| switch (err) {
                error.EndOfStream => return,
                else => return err,
            };
            return error.UnexpectedExtraRequest;
        }
    };
    for (0..4) |mode| {
        var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .async_limit = .nothing });
        defer threaded.deinit();
        Fixture.io = threaded.io();
        Fixture.registered = 0;
        Fixture.fail_at = if (mode >= 2) mode - 1 else null;
        Fixture.received = .unset;
        Fixture.cancellation.store(false, .release);
        var vtable = Fixture.io.vtable.*;
        vtable.groupConcurrent = Fixture.concurrent;
        const io: std.Io = .{ .userdata = Fixture.io.userdata, .vtable = &vtable };
        const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        var listener = try address.listen(std.testing.io, .{ .kernel_backlog = 1 });
        defer listener.deinit(std.testing.io);
        var fixture: Fixture = .{ .listener = &listener, .cancel = mode == 0 };
        const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/mcp", .{listener.socket.address.getPort()});
        defer std.testing.allocator.free(url);
        var engine: http_execution.Engine = undefined;
        engine.init(std.testing.allocator, io);
        defer engine.deinit();
        var context: HttpContext = .{ .http_engine = &engine, .isolation = .public, .allocator = std.testing.allocator, .io = io, .arena = std.heap.ArenaAllocator.init(std.testing.allocator), .url = url, .custom_headers = &.{}, .secret_values = &.{}, .backend = undefined };
        defer context.arena.deinit();
        context.backend = try agent.McpHttpBackend.init(.{ .io = io, .allocator = std.testing.allocator, .endpoint = context.endpoint() });
        defer context.backend.deinit() catch unreachable;
        const transport = context.backend.transport();
        const connection = switch (transport.open_fn(transport.context, .actual, .modern_2026_07_28, 5000)) {
            .connection => |value| value,
            .failure => return error.TestUnexpectedResult,
        };
        defer transport.close_fn(connection);
        const thread = if (mode < 2) try std.Thread.spawn(.{}, Fixture.run, .{&fixture}) else null;
        const result = transport.request_fn(connection, std.testing.allocator, "{}", if (mode == 1) 500 else 5000, .{ .is_cancelled_fn = Fixture.cancelled });
        if (thread) |started| started.join();
        try std.testing.expectEqual(@as(?anyerror, null), fixture.failure);
        try std.testing.expectEqual(@as(agent.McpTransportFailure, switch (mode) {
            0 => .cancelled,
            1 => .timeout,
            else => .network,
        }), result.failure);
    }
}

test "MCP platform distinguishes trusted Bearer challenges from bare HTTP auth rejection" {
    const TestServer = struct {
        io: std.Io,
        listener: *std.Io.net.Server,
        failure: ?anyerror = null,

        fn run(self: *@This()) void {
            self.serve() catch |err| {
                self.failure = err;
            };
        }

        fn serve(self: *@This()) !void {
            try self.serveOne(true, .unauthorized);
            try self.serveOne(false, .forbidden);
            try self.serveOne(false, .unauthorized);
        }

        fn serveOne(self: *@This(), include_challenge: bool, status: std.http.Status) !void {
            var connection = try self.listener.accept(self.io);
            defer connection.close(self.io);
            var read_buffer: [4096]u8 = undefined;
            var write_buffer: [4096]u8 = undefined;
            var stream_reader = connection.reader(self.io, &read_buffer);
            var stream_writer = connection.writer(self.io, &write_buffer);
            var server: std.http.Server = .init(
                &stream_reader.interface,
                &stream_writer.interface,
            );
            var request = try server.receiveHead();
            if (include_challenge)
                try request.respond("", .{
                    .status = .unauthorized,
                    .extra_headers = &.{.{
                        .name = "WWW-Authenticate",
                        .value = "Bearer error=\"insufficient_scope\", scope=\"files.write files.read\"",
                    }},
                })
            else
                try request.respond("", .{ .status = status });
        }
    };

    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var listener = try address.listen(std.testing.io, .{
        .kernel_backlog = 1,
        .reuse_address = false,
    });
    defer listener.deinit(std.testing.io);
    var server: TestServer = .{ .io = std.testing.io, .listener = &listener };
    const url = try std.fmt.allocPrint(
        std.testing.allocator,
        "http://127.0.0.1:{d}/mcp",
        .{listener.socket.address.getPort()},
    );
    defer std.testing.allocator.free(url);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const authorization = try HttpAuthSlot.create(
        std.testing.allocator,
        std.testing.io,
        "remote",
        @splat(0),
        3,
        8,
        .{ .access_token = "runtime-access-token" },
    );
    defer authorization.release();
    var engine: http_execution.Engine = undefined;
    engine.init(std.testing.allocator, std.testing.io);
    defer engine.deinit();
    var context: HttpContext = .{
        .http_engine = &engine,
        .isolation = .public,
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .arena = arena,
        .url = url,
        .custom_headers = &.{},
        .secret_values = &.{},
        .authorization = authorization,
        .backend = undefined,
    };
    context.backend = try agent.McpHttpBackend.init(.{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .endpoint = context.endpoint(),
    });
    defer context.backend.deinit() catch unreachable;
    const transport = context.backend.transport();
    const thread = try std.Thread.spawn(.{}, TestServer.run, .{&server});
    const first = switch (transport.open_fn(
        transport.context,
        .actual,
        .modern_2026_07_28,
        1000,
    )) {
        .connection => |value| value,
        .failure => return error.TestUnexpectedResult,
    };
    switch (transport.request_fn(
        first,
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}",
        1000,
        .{},
    )) {
        .failure => return error.TestUnexpectedResult,
        .response => |response| {
            try std.testing.expectEqual(@as(u32, 401), response.http_status);
            try std.testing.expectEqual(@as(usize, 0), response.body.len);
        },
    }
    transport.close_fn(first);
    {
        var failure = (try authorization.snapshotRuntimeAuthFailure(true)).?;
        defer failure.deinit();
        try std.testing.expectEqual(@as(u64, 3), failure.consent_epoch);
        try std.testing.expectEqual(@as(u64, 8), failure.token_revision);
        try std.testing.expect(failure.challenge_scopes_complete);
        try std.testing.expectEqualStrings("files.read", failure.challenge_scopes[0]);
        try std.testing.expectEqualStrings("files.write", failure.challenge_scopes[1]);
        try std.testing.expect(authorization.acknowledgeRuntimeAuthFailure(&failure));
    }
    const second = switch (transport.open_fn(
        transport.context,
        .actual,
        .modern_2026_07_28,
        1000,
    )) {
        .connection => |value| value,
        .failure => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(
        @as(?agent.McpTransportFailure, .auth),
        transport.notify_fn(
            second,
            "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}",
            1000,
            .{},
        ),
    );
    transport.close_fn(second);
    const third = transport.open_fn(transport.context, .actual, .modern_2026_07_28, 1000).connection;
    const bare_response = transport.request_fn(third, std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"initialize\"}", 1000, .{}).response;
    try std.testing.expectEqual(@as(u32, 401), bare_response.http_status);
    transport.close_fn(third);
    thread.join();
    try std.testing.expectEqual(@as(?anyerror, null), server.failure);
    try std.testing.expect((try authorization.snapshotRuntimeAuthFailure(true)) == null);
    var bare_failure = (try authorization.snapshotRuntimeAuthFailure(false)).?;
    defer bare_failure.deinit();
    try std.testing.expect(!bare_failure.trusted_challenge);
    try std.testing.expectEqual(@as(u64, 8), bare_failure.token_revision);
    try std.testing.expectEqual(@as(usize, 0), bare_failure.challenge_scopes.len);
    try std.testing.expect(authorization.acknowledgeRuntimeAuthFailure(&bare_failure));
}

test "MCP private endpoint is resolved only in its HTTP owner and rejects cross-origin assembly" {
    const allocator = std.testing.allocator;
    const secret = try allocator.dupe(u8, "https://mcp.example.test/k/synthetic?route=private");
    defer secureFree(allocator, secret);
    var credentials = [_]mcp_configuration.ResolvedCredential{.{ .locator = "endpoint/fixture", .secret = secret }};
    const preparation: mcp_configuration.Preparation = .{ .allocator = allocator, .state = .available, .credentials = &credentials };
    const server: mcp_configuration.ServerWire = .{
        .id = "private",
        .namespace = "private",
        .display_name = "Private",
        .enabled = true,
        .negotiation = "automatic",
        .timeout_ms = 1000,
        .transport = .{ .kind = "streamable_http", .sensitive_endpoint = .{ .origin = "https://mcp.example.test", .identity = "endpoint-generation", .credential_refs = &.{"endpoint/fixture"} } },
        .auth = .{ .kind = "none", .oauth = null },
        .connection_approval = null,
        .tools = &.{},
    };
    var authorization: ?*HttpAuthSlot = null;
    var engine: http_execution.Engine = undefined;
    engine.init(allocator, std.testing.io);
    defer engine.deinit();
    var owner = try createHttpOwner(&engine, std.testing.io, allocator, server, &preparation, &authorization, null);
    defer owner.deinit();
    const backend: *agent.McpHttpBackend = @ptrCast(@alignCast(owner.transport.context));
    const context: *HttpContext = @fieldParentPtr("backend", backend);
    try std.testing.expectEqualStrings(secret, context.url);
    @memset(secret, 'x');
    try std.testing.expectEqualStrings("https://mcp.example.test/k/synthetic?route=private", context.url);
    var inspection: HttpContext.Inspection = .{ .context = context, .lease = null };
    try std.testing.expect(!HttpContext.Inspection.check(&inspection, context.url));
    try std.testing.expectError(error.InvalidConfig, createHttpOwner(&engine, std.testing.io, allocator, server, &preparation, &authorization, null));
}

test "MCP HTTP owner release retires its server's pooled connections" {
    const KeepAlive = struct {
        listener: *std.Io.net.Server,
        closed: std.atomic.Value(bool) = .init(false),
        fn run(self: *@This()) void {
            var connection = self.listener.accept(std.testing.io) catch return;
            defer {
                connection.close(std.testing.io);
                self.closed.store(true, .release);
            }
            var reads: [4096]u8 = undefined;
            var writes: [4096]u8 = undefined;
            var reader = connection.reader(std.testing.io, &reads);
            var writer = connection.writer(std.testing.io, &writes);
            var http: std.http.Server = .init(&reader.interface, &writer.interface);
            var request = http.receiveHead() catch return;
            request.respond("{}", .{ .keep_alive = true }) catch return;
            _ = http.receiveHead() catch {};
        }
        fn get(operation: *http_execution.Operation, url: []const u8) http_execution.Error!void {
            var request = try operation.open(.GET, std.Uri.parse(url) catch return error.InvalidRequest, .{});
            defer request.deinit();
            try request.send(null);
            var response = try request.receiveHead();
            var output: [8]u8 = undefined;
            _ = try request.readAll(&response, &output);
        }
    };
    const allocator = std.testing.allocator;
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var listener = try address.listen(std.testing.io, .{});
    defer listener.deinit(std.testing.io);
    var server: KeepAlive = .{ .listener = &listener };
    const thread = try std.Thread.spawn(.{}, KeepAlive.run, .{&server});
    defer thread.join();
    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/mcp", .{listener.socket.address.getPort()});
    defer allocator.free(url);
    const secret = try allocator.dupe(u8, "https://mcp.example.test/k/synthetic?route=private");
    defer secureFree(allocator, secret);
    var credentials = [_]mcp_configuration.ResolvedCredential{.{ .locator = "endpoint/fixture", .secret = secret }};
    const preparation: mcp_configuration.Preparation = .{ .allocator = allocator, .state = .available, .credentials = &credentials };
    const server_wire: mcp_configuration.ServerWire = .{
        .id = "private",
        .namespace = "private",
        .display_name = "Private",
        .enabled = true,
        .negotiation = "automatic",
        .timeout_ms = 1000,
        .transport = .{ .kind = "streamable_http", .sensitive_endpoint = .{ .origin = "https://mcp.example.test", .identity = "endpoint-generation", .credential_refs = &.{"endpoint/fixture"} } },
        .auth = .{ .kind = "none", .oauth = null },
        .connection_approval = null,
        .tools = &.{},
    };
    var authorization: ?*HttpAuthSlot = null;
    var engine: http_execution.Engine = undefined;
    engine.init(allocator, std.testing.io);
    defer engine.deinit();
    var owner = try createHttpOwner(&engine, std.testing.io, allocator, server_wire, &preparation, &authorization, null);
    var owner_live = true;
    defer if (owner_live) owner.deinit();
    const backend: *agent.McpHttpBackend = @ptrCast(@alignCast(owner.transport.context));
    const context: *HttpContext = @fieldParentPtr("backend", backend);
    try std.testing.expect(context.isolation.eql(.of(.mcp_server, "private")));
    // A connection pooled under this server's isolation.
    const result = engine.run(.{ .consumer = .mcp, .isolation = context.isolation, .budget = .{ .deadline = .fromNow(std.testing.io, .{ .raw = .fromSeconds(5), .clock = .awake }) } }, KeepAlive.get, .{url});
    try result.outcome.completed;
    owner_live = false;
    owner.deinit();
    for (0..400) |_| {
        if (server.closed.load(.acquire)) break;
        std.Io.sleep(std.testing.io, .fromMilliseconds(5), .awake) catch {};
    }
    try std.testing.expect(server.closed.load(.acquire));
    for (&engine.slots) |*slot| try std.testing.expectEqual(@as(usize, 0), slot.client.connection_pool.free_len);
}

test "MCP platform builds lazy stdio and HTTP transport owners without opening them" {
    var servers = [_]mcp_configuration.ServerWire{
        .{
            .id = "stdio",
            .namespace = "local",
            .display_name = "Local",
            .enabled = true,
            .negotiation = "modern_only",
            .timeout_ms = 1000,
            .transport = .{ .kind = "stdio", .command = "/bin/echo" },
            .auth = .{ .kind = "none", .oauth = null },
            .connection_approval = null,
            .tools = &.{},
        },
        .{
            .id = "http",
            .namespace = "remote",
            .display_name = "Remote",
            .enabled = true,
            .negotiation = "compat_only",
            .timeout_ms = 1000,
            .transport = .{
                .kind = "streamable_http",
                .url = "https://example.test/mcp",
            },
            .auth = .{ .kind = "none", .oauth = null },
            .connection_approval = null,
            .tools = &.{},
        },
    };
    var approvals: [servers.len][64]u8 = undefined;
    for (&servers, 0..) |*server, index| {
        approvals[index] = mcp_configuration.connectionFingerprint(server.*);
        server.connection_approval = .{ .fingerprint = &approvals[index] };
    }
    var registry_buffer: [mcp_configuration.max_store_bytes]u8 = undefined;
    const registry = try mcp_configuration.encode(
        &registry_buffer,
        .{
            .schema_version = mcp_configuration.schema_version,
            .generation = 3,
            .oauth_operation = null,
            .servers = &servers,
        },
        .{
            .max_servers = 8,
            .max_tools_per_server = 32,
            .max_namespace_bytes = 128,
            .max_credential_locators = 64,
            .max_runtime_secrets_per_server = (agent.McpRuntimeLimits{}).max_secrets,
            .max_runtime_secret_bytes_per_server = (agent.McpRuntimeLimits{}).max_secret_bytes,
        },
    );
    var preparation = try mcp_configuration.prepare(
        std.testing.allocator,
        registry,
        true,
        false,
        .{},
        .{
            .max_servers = 8,
            .max_tools_per_server = 32,
            .max_namespace_bytes = 128,
            .max_credential_locators = 64,
            .max_runtime_secrets_per_server = (agent.McpRuntimeLimits{}).max_secrets,
            .max_runtime_secret_bytes_per_server = (agent.McpRuntimeLimits{}).max_secret_bytes,
        },
    );
    defer preparation.deinit();
    var engine: http_execution.Engine = undefined;
    engine.init(std.testing.allocator, std.testing.io);
    defer engine.deinit();
    var environment = testHostEnvironment();
    environment.http_engine = &engine;
    var input = (try buildRuntimeInput(
        std.testing.io,
        std.testing.allocator,
        &preparation,
        environment,
    )).?;
    defer input.deinit();
}

test "MCP platform creates no owner and reads no credential before approval" {
    const Resolver = struct {
        calls: usize = 0,

        fn resolve(
            context: ?*anyopaque,
            _: std.mem.Allocator,
            _: []const u8,
        ) mcp_configuration.CredentialResolution {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            return .unavailable;
        }
    };
    var server_environment = [_]mcp_configuration.SecretSlotWire{.{
        .name = "MCP_TOKEN",
        .credential_ref = null,
    }};
    var servers = [_]mcp_configuration.ServerWire{.{
        .id = "unapproved",
        .namespace = "unapproved",
        .display_name = "Unapproved",
        .enabled = true,
        .negotiation = "automatic",
        .timeout_ms = 1000,
        .transport = .{
            .kind = "stdio",
            .command = "/bin/echo",
            .environment = &server_environment,
        },
        .auth = .{ .kind = "static", .oauth = null },
        .connection_approval = null,
        .tools = &.{},
    }};
    var registry_buffer: [mcp_configuration.max_store_bytes]u8 = undefined;
    const limits: mcp_configuration.Limits = .{
        .max_servers = 8,
        .max_tools_per_server = 32,
        .max_namespace_bytes = 128,
        .max_credential_locators = 64,
        .max_runtime_secrets_per_server = (agent.McpRuntimeLimits{}).max_secrets,
        .max_runtime_secret_bytes_per_server = (agent.McpRuntimeLimits{}).max_secret_bytes,
    };
    const registry = try mcp_configuration.encode(
        &registry_buffer,
        .{
            .schema_version = mcp_configuration.schema_version,
            .generation = 1,
            .oauth_operation = null,
            .servers = &servers,
        },
        limits,
    );
    var resolver: Resolver = .{};
    var preparation = try mcp_configuration.prepare(
        std.testing.allocator,
        registry,
        true,
        false,
        .{
            .context = &resolver,
            .available = true,
            .resolve_fn = Resolver.resolve,
        },
        limits,
    );
    defer preparation.deinit();
    try std.testing.expectEqual(mcp_configuration.ServerPreparationState.unapproved, preparation.server_states[0]);
    try std.testing.expectEqual(@as(usize, 0), resolver.calls);
    var input = (try buildRuntimeInput(
        std.testing.io,
        std.testing.allocator,
        &preparation,
        testHostEnvironment(),
    )).?;
    defer input.deinit();
    try std.testing.expectEqual(@as(u64, 1), input.generation);
}

fn testHostEnvironment() HostEnvironment {
    return .{
        .executable_search_path = if (builtin.os.tag == .windows)
            "C:\\Windows\\System32"
        else
            "/usr/bin:/bin",
        .windows_system_root = if (builtin.os.tag == .windows)
            "C:\\Windows"
        else
            null,
    };
}

test "SDK consumption MCP credentials distinguish null empty unavailable and idempotent delete" {
    const Failure = struct {
        fn write(_: ?*anyopaque, _: native_sdk.platform.Credential) anyerror!void {
            return error.CredentialStoreLocked;
        }
        fn read(_: ?*anyopaque, _: native_sdk.platform.CredentialKey, _: []u8) anyerror![]const u8 {
            return error.PermissionDenied;
        }
        fn empty(_: ?*anyopaque, _: native_sdk.platform.CredentialKey, output: []u8) anyerror![]const u8 {
            return output[0..0];
        }
        fn delete(_: ?*anyopaque, _: native_sdk.platform.CredentialKey) anyerror!void {
            return error.PermissionDenied;
        }
    };
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    var store: CredentialStore = .{ .io = std.testing.io, .runtime = &harness.runtime, .main_thread_id = std.Thread.getCurrentId() };
    const effects = store.effects();
    const locator = "mcp-test-locator";
    try std.testing.expect(effects.available);
    try std.testing.expectEqual(mcp_configuration.CredentialPresence.missing, effects.probe_fn(effects.context, locator));
    try std.testing.expect(store.resolveSecret(std.testing.allocator, locator) == .missing);
    try std.testing.expect(effects.delete_fn(effects.context, locator));
    try std.testing.expect(effects.create_fn(effects.context, locator, "test-mcp-secret"));
    try std.testing.expect(!effects.create_fn(effects.context, locator, "replacement"));
    try std.testing.expectEqualStrings(credential_service, harness.null_platform.credential_service[0..harness.null_platform.credential_service_len]);
    try std.testing.expectEqualStrings(locator, harness.null_platform.credential_account[0..harness.null_platform.credential_account_len]);
    const resolved = store.resolveSecret(std.testing.allocator, locator);
    try std.testing.expect(resolved == .value);
    defer {
        std.crypto.secureZero(u8, resolved.value);
        std.testing.allocator.free(resolved.value);
    }
    try std.testing.expectEqualStrings("test-mcp-secret", resolved.value);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expect(store.resolveSecret(failing.allocator(), locator) == .out_of_memory);
    const get_fn = harness.runtime.options.platform.services.get_credential_fn;
    harness.runtime.options.platform.services.get_credential_fn = Failure.empty;
    try std.testing.expectEqual(mcp_configuration.CredentialPresence.present, effects.probe_fn(effects.context, locator));
    const empty = store.resolveSecret(std.testing.allocator, locator);
    try std.testing.expect(empty == .value);
    defer std.testing.allocator.free(empty.value);
    try std.testing.expectEqual(@as(usize, 0), empty.value.len);
    harness.runtime.options.platform.services.get_credential_fn = Failure.read;
    try std.testing.expectEqual(mcp_configuration.CredentialPresence.unavailable, effects.probe_fn(effects.context, locator));
    try std.testing.expect(store.resolveSecret(std.testing.allocator, locator) == .unavailable);
    harness.runtime.options.platform.services.get_credential_fn = null;
    try std.testing.expect(!store.resolver().available);
    try std.testing.expect(!store.effects().available);
    harness.runtime.options.platform.services.get_credential_fn = get_fn;
    const delete_fn = harness.runtime.options.platform.services.delete_credential_fn;
    harness.runtime.options.platform.services.delete_credential_fn = Failure.delete;
    try std.testing.expect(!effects.delete_fn(effects.context, locator));
    harness.runtime.options.platform.services.delete_credential_fn = delete_fn;
    store.main_thread_id +%= 1;
    try std.testing.expect(store.resolveSecret(std.testing.allocator, locator) == .unavailable);
    try std.testing.expect(!effects.create_fn(effects.context, locator, "wrong-thread"));
    try std.testing.expect(!effects.delete_fn(effects.context, locator));
    store.main_thread_id -%= 1;
    try std.testing.expect(effects.delete_fn(effects.context, locator));
    const cleanup = store.cleanup();
    try std.testing.expect(cleanup.delete_fn(cleanup.context, locator));
    try std.testing.expect(store.resolveSecret(std.testing.allocator, locator) == .missing);
    const set_fn = harness.runtime.options.platform.services.set_credential_fn;
    harness.runtime.options.platform.services.set_credential_fn = Failure.write;
    try std.testing.expect(!effects.create_fn(effects.context, locator, "replacement"));
    harness.runtime.options.platform.services.set_credential_fn = set_fn;
    try std.testing.expect(store.resolveSecret(std.testing.allocator, locator) == .missing);
}
