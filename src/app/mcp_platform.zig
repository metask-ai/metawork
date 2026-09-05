//! App-owned MCP platform composition. This module resolves system credential
//! locators on the Native main thread and constructs concrete stdio or
//! preauthorized HTTP transport owners. It does not interpret MCP payloads.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const agent = @import("metawork_agent");
const mcp_configuration = @import("metawork_product_mcp").contract;
const mcp_oauth = @import("metawork_mcp_oauth");
const product_identity = @import("metawork_product_identity");

pub const credential_service = product_identity.mcpCredentialService();
pub const max_credential_secret_bytes = native_sdk.platform.max_credential_secret_bytes;
const client_name = "MetaWork";
const client_version = product_identity.version;
const max_custom_headers: usize = 128;
const stdio_io_buffer_bytes: usize = 4096;
const max_stdio_argv_count: usize = 129;
const max_stdio_argv_bytes: usize = 64 * 1024;

pub const CredentialStore = struct {
    io: std.Io,
    services: native_sdk.platform.PlatformServices,
    main_thread_id: std.Thread.Id,

    pub fn resolver(self: *CredentialStore) mcp_configuration.CredentialResolver {
        return .{
            .context = self,
            .available = self.services.get_credential_fn != null,
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
            .available = self.services.delete_credential_fn != null,
            .delete_fn = delete,
        };
    }

    pub fn effects(self: *CredentialStore) mcp_configuration.CredentialEffects {
        return .{
            .context = self,
            .available = self.services.get_credential_fn != null and
                self.services.set_credential_fn != null and
                self.services.delete_credential_fn != null,
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
        const value = self.services.getCredential(.{
            .service = credential_service,
            .account = locator,
        }, &storage) catch |err| return switch (err) {
            error.CredentialNotFound => .missing,
            else => .unavailable,
        };
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
        _ = self.services.getCredential(.{
            .service = credential_service,
            .account = locator,
        }, &storage) catch |err| return switch (err) {
            error.CredentialNotFound => .missing,
            else => .unavailable,
        };
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
        self.services.setCredential(.{
            .service = credential_service,
            .account = locator,
            .secret = secret,
        }) catch return false;
        return true;
    }

    fn delete(context: ?*anyopaque, locator: []const u8) bool {
        const self: *CredentialStore = @ptrCast(@alignCast(context orelse return false));
        if (std.Thread.getCurrentId() != self.main_thread_id) return false;
        self.services.deleteCredential(.{
            .service = credential_service,
            .account = locator,
        }) catch |err| switch (err) {
            error.CredentialNotFound => {},
            else => return false,
        };
        return true;
    }
};

pub const BuildError = std.mem.Allocator.Error || error{InvalidConfig};

const HttpAuthSnapshot = struct {
    allocator: std.mem.Allocator,
    references: std.atomic.Value(usize) = .init(1),
    consent_epoch: u64,
    token_revision: u64,
    access_token: []u8,

    fn create(
        allocator: std.mem.Allocator,
        consent_epoch: u64,
        token_revision: u64,
        access_token: []const u8,
    ) std.mem.Allocator.Error!*HttpAuthSnapshot {
        const self = try allocator.create(HttpAuthSnapshot);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .consent_epoch = consent_epoch,
            .token_revision = token_revision,
            .access_token = try allocator.dupe(u8, access_token),
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
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
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
    consent_epoch: u64,
    token_revision: u64,
    challenge_scopes: []const []const u8,
    challenge_scopes_complete: bool,
    scopes_owner: ?OwnedRuntimeScopes = null,

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
    current: *HttpAuthSnapshot,
    rotation_reserved: bool = false,
    pending_failure: ?PendingRuntimeAuthFailure = null,
    failure_notifier: ?RuntimeAuthFailureNotifier = null,

    fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        server_id: []const u8,
        consent_epoch: u64,
        token_revision: u64,
        access_token: []const u8,
    ) std.mem.Allocator.Error!*HttpAuthSlot {
        const self = try allocator.create(HttpAuthSlot);
        errdefer allocator.destroy(self);
        const owned_id = try allocator.dupe(u8, server_id);
        errdefer allocator.free(owned_id);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .server_id = owned_id,
            .current = try HttpAuthSnapshot.create(
                allocator,
                consent_epoch,
                token_revision,
                access_token,
            ),
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
        return .{ .snapshot = self.current };
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
        challenge_scopes: []const []const u8,
    ) void {
        self.mutex.lockUncancelable(self.io);
        const epoch = auth_lease.snapshot.consent_epoch;
        const revision = auth_lease.snapshot.token_revision;
        if (self.pending_failure) |*pending| {
            if (pending.consent_epoch != epoch) {
                pending.deinit();
                var scopes_complete = true;
                const scopes = ownRuntimeScopes(
                    self.allocator,
                    &.{},
                    challenge_scopes,
                ) catch scopes: {
                    scopes_complete = false;
                    break :scopes null;
                };
                pending.* = .{
                    .consent_epoch = epoch,
                    .token_revision = revision,
                    .scopes = scopes,
                    .scopes_complete = scopes_complete,
                };
            } else {
                pending.token_revision = @max(pending.token_revision, revision);
                if (pending.scopes_complete and challenge_scopes.len != 0) {
                    const existing = if (pending.scopes) |*scopes|
                        scopes.values
                    else
                        &.{};
                    if (ownRuntimeScopes(
                        self.allocator,
                        existing,
                        challenge_scopes,
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
            var scopes_complete = true;
            const scopes = ownRuntimeScopes(
                self.allocator,
                &.{},
                challenge_scopes,
            ) catch scopes: {
                scopes_complete = false;
                break :scopes null;
            };
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

    fn takeRuntimeAuthFailure(self: *HttpAuthSlot) ?RuntimeAuthFailure {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var pending = self.pending_failure orelse return null;
        self.pending_failure = null;
        const scopes = if (pending.scopes) |*owner| owner.values else &.{};
        const result: RuntimeAuthFailure = .{
            .server_id = self.server_id,
            .consent_epoch = pending.consent_epoch,
            .token_revision = pending.token_revision,
            .challenge_scopes = scopes,
            .challenge_scopes_complete = pending.scopes_complete,
            .scopes_owner = pending.scopes,
        };
        pending.scopes = null;
        return result;
    }

    fn hasRuntimeAuthFailure(self: *HttpAuthSlot) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.pending_failure != null;
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
        self.current = replacement;
        self.rotation_reserved = false;
        self.mutex.unlock(self.io);
        current.release();
    }

    fn cancelReservedRotation(self: *HttpAuthSlot) void {
        self.mutex.lockUncancelable(self.io);
        std.debug.assert(self.rotation_reserved);
        self.rotation_reserved = false;
        self.mutex.unlock(self.io);
    }
};

const HttpAuthLease = struct {
    snapshot: *HttpAuthSnapshot,

    fn token(self: *const HttpAuthLease) []const u8 {
        return self.snapshot.access_token;
    }

    fn deinit(self: *HttpAuthLease) void {
        self.snapshot.release();
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

const HttpAuthRotationPreparation = union(enum) {
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

    pub fn deinit(self: *HttpAuthorizations) void {
        for (self.slots) |slot| slot.release();
        if (self.slots.len != 0) self.allocator.free(self.slots);
        self.* = undefined;
    }

    pub fn setRuntimeAuthFailureNotifier(
        self: *HttpAuthorizations,
        notifier: ?RuntimeAuthFailureNotifier,
    ) void {
        for (self.slots) |slot| slot.setFailureNotifier(notifier);
    }

    pub fn takeRuntimeAuthFailures(
        self: *HttpAuthorizations,
    ) std.mem.Allocator.Error!RuntimeAuthFailureBatch {
        var pending_count: usize = 0;
        for (self.slots) |slot| {
            if (slot.hasRuntimeAuthFailure()) pending_count += 1;
        }
        if (pending_count == 0) return .{
            .allocator = self.allocator,
            .storage = &.{},
            .values = &.{},
        };
        const storage = try self.allocator.alloc(RuntimeAuthFailure, pending_count);
        var count: usize = 0;
        for (self.slots) |slot| {
            if (count == storage.len) break;
            if (slot.takeRuntimeAuthFailure()) |failure| {
                storage[count] = failure;
                count += 1;
            }
        }
        return .{
            .allocator = self.allocator,
            .storage = storage,
            .values = storage[0..count],
        };
    }

    pub fn rotate(
        self: *HttpAuthorizations,
        server_id: []const u8,
        expected_consent_epoch: u64,
        expected_token_revision: u64,
        access_token: []const u8,
    ) std.mem.Allocator.Error!HttpAuthRotationOutcome {
        var pending = switch (try self.prepareRotationDetailed(
            server_id,
            expected_consent_epoch,
            expected_token_revision,
            access_token,
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
        access_token: []const u8,
    ) std.mem.Allocator.Error!?PendingHttpAuthRotation {
        return switch (try self.prepareRotationDetailed(
            server_id,
            expected_consent_epoch,
            expected_token_revision,
            access_token,
        )) {
            .prepared => |prepared| prepared,
            .server_not_loaded,
            .consent_epoch_mismatch,
            .token_revision_mismatch,
            => null,
        };
    }

    fn prepareRotationDetailed(
        self: *HttpAuthorizations,
        server_id: []const u8,
        expected_consent_epoch: u64,
        expected_token_revision: u64,
        access_token: []const u8,
    ) std.mem.Allocator.Error!HttpAuthRotationPreparation {
        if (!mcp_configuration.validHttpHeaderCredential(access_token) or
            expected_token_revision == std.math.maxInt(u64))
            return .token_revision_mismatch;
        const slot = for (self.slots) |candidate| {
            if (std.mem.eql(u8, candidate.server_id, server_id)) break candidate;
        } else return .server_not_loaded;
        slot.retain();
        var slot_owned = true;
        defer if (slot_owned) slot.release();
        const replacement = try HttpAuthSnapshot.create(
            self.allocator,
            expected_consent_epoch,
            expected_token_revision + 1,
            access_token,
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

pub const RuntimeBuild = struct {
    input: ?agent.McpRuntimeInput = null,
    authorizations: HttpAuthorizations,

    pub fn deinit(self: *RuntimeBuild) void {
        if (self.input) |*input| input.deinit();
        self.authorizations.deinit();
        self.* = undefined;
    }

    pub fn takeAuthorizations(self: *RuntimeBuild) HttpAuthorizations {
        const result = self.authorizations;
        self.authorizations = .{ .allocator = result.allocator };
        return result;
    }
};

pub const HostEnvironment = struct {
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
    return build.input;
}

pub fn buildRuntime(
    io: std.Io,
    allocator: std.mem.Allocator,
    preparation: *const mcp_configuration.Preparation,
    host_environment: HostEnvironment,
) BuildError!RuntimeBuild {
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
        const owner = try allocator.create(agent.McpTransportOwner);
        var authorization: ?*HttpAuthSlot = null;
        owner.* = (if (std.mem.eql(u8, server.transport.kind, "stdio"))
            createStdioOwner(io, allocator, server, preparation, host_environment)
        else if (std.mem.eql(u8, server.transport.kind, "streamable_http"))
            createHttpOwner(io, allocator, server, preparation, &authorization)
        else
            error.InvalidConfig) catch |err| {
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
            .timeout_ms = server.timeout_ms,
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
    const oauth_extra: usize = if (server.auth.oauth) |oauth|
        @as(usize, @intFromBool(oauth.registration.client_secret_ref != null)) +
            @as(usize, @intFromBool(oauth.grant != null)) +
            @as(usize, @intFromBool(oauth.grant != null and
                oauth.grant.?.refresh_token_ref != null))
    else
        0;
    const count = server.transport.environment.len +
        server.transport.headers.len + oauth_extra;
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
    if (server.auth.oauth) |oauth| {
        if (oauth.registration.client_secret_ref) |locator| {
            const secret = resolvedCredential(preparation, locator) orelse
                return error.InvalidConfig;
            if (!containsSecret(values[0..write], secret)) {
                values[write] = secret;
                write += 1;
            }
        }
        if (oauth.grant) |grant| {
            const access_token = resolvedCredential(
                preparation,
                grant.access_token_ref,
            ) orelse return error.InvalidConfig;
            if (!containsSecret(values[0..write], access_token)) {
                values[write] = access_token;
                write += 1;
            }
            if (grant.refresh_token_ref) |locator| {
                const refresh_token = resolvedCredential(preparation, locator) orelse
                    return error.InvalidConfig;
                if (!containsSecret(values[0..write], refresh_token)) {
                    values[write] = refresh_token;
                    write += 1;
                }
            }
        }
    }
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
        stderr_thread: std.Thread,
        dead: std.atomic.Value(bool) = .init(false),

        fn terminate(self: *Connection) void {
            if (self.dead.swap(true, .acq_rel)) return;
            if (builtin.os.tag == .windows) {
                self.child.kill(self.context.io);
                return;
            }
            if (self.child.id) |pid| {
                std.posix.kill(-pid, .KILL) catch {};
                _ = self.child.wait(self.context.io) catch {};
            }
        }

        fn deinit(self: *Connection) void {
            self.terminate();
            self.stderr_thread.join();
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
        const connection = self.openConnection() catch |err| return .{
            .failure = switch (err) {
                error.SpawnFailed => .child_exit,
                error.ResourceUnavailable => .fatal,
            },
        };
        return .{ .connection = connection };
    }

    const OpenError = error{ SpawnFailed, ResourceUnavailable };

    fn openConnection(self: *StdioContext) OpenError!*Connection {
        var child = std.process.spawn(self.io, .{
            .argv = self.argv,
            .cwd = self.cwd,
            .environ_map = &self.environment,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
            .pgid = if (builtin.os.tag == .windows) null else 0,
            .create_no_window = true,
        }) catch return error.SpawnFailed;
        errdefer child.kill(self.io);
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
            .stderr_thread = undefined,
        };
        connection.stderr_thread = std.Thread.spawn(
            .{},
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
        select.async(.exchange, pumpExchange, .{ connection, write.fragments, sink });
        select.async(.timeout, waitTimeout, .{ connection.context.io, write.timeout_ms });
        select.async(.cancellation, waitCancellation, .{
            connection.context.io,
            write.cancellation,
        });
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
        select.async(.write, writeNotification, .{ connection, write.fragments });
        select.async(.timeout, waitTimeout, .{ connection.context.io, write.timeout_ms });
        select.async(.cancellation, waitCancellation, .{
            connection.context.io,
            write.cancellation,
        });
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
    allocator: std.mem.Allocator,
    io: std.Io,
    arena: std.heap.ArenaAllocator,
    url: []const u8,
    custom_headers: []std.http.Header,
    secret_values: [][]u8,
    authorization: ?*HttpAuthSlot = null,
    backend: agent.McpHttpBackend,

    fn destroy(raw: *anyopaque) void {
        const backend: *agent.McpHttpBackend = @ptrCast(@alignCast(raw));
        const self: *HttpContext = @fieldParentPtr("backend", backend);
        self.backend.deinit() catch @panic("MCP HTTP owner released with live connections");
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
    const Event = union(enum) {
        response: FetchFailure!void,
        timeout,
        cancelled,
    };

    fn fetch(
        self: *HttpContext,
        request: agent.McpHttpRequest,
        sink: *const agent.McpHttpResponseSink,
    ) FetchFailure!void {
        var events: [3]Event = undefined;
        var select = std.Io.Select(Event).init(self.io, &events);
        select.async(.response, fetchOne, .{
            self,
            request,
            sink,
        });
        select.async(.timeout, waitTimeout, .{ self.io, request.timeout_ms });
        select.async(.cancelled, waitCancellation, .{ self.io, request.cancellation });
        const first = select.await() catch {
            select.cancelDiscard();
            return error.Cancelled;
        };
        defer select.cancelDiscard();
        return switch (first) {
            .response => |result| try result,
            .timeout => error.Timeout,
            .cancelled => error.Cancelled,
        };
    }

    fn fetchOne(
        self: *HttpContext,
        request_value: agent.McpHttpRequest,
        sink: *const agent.McpHttpResponseSink,
    ) FetchFailure!void {
        var client: std.http.Client = .{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();
        const uri = std.Uri.parse(self.url) catch return error.InvalidResponse;
        var authorization_lease = if (self.authorization) |authorization|
            authorization.lease()
        else
            null;
        defer if (authorization_lease) |*lease| lease.deinit();
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
        var request = client.request(method, uri, .{
            .redirect_behavior = .unhandled,
            .headers = .{
                .accept_encoding = .{ .override = "identity" },
                .authorization = if (bearer) |value|
                    .{ .override = value }
                else
                    .default,
            },
            .extra_headers = headers[0..count],
        }) catch return error.Network;
        defer request.deinit();
        if (request_value.method == .post) {
            request.transfer_encoding = .{ .content_length = request_value.body.len };
            var request_body = request.sendBodyUnflushed(&.{}) catch return error.Network;
            request_body.writer.writeAll(request_value.body) catch return error.Network;
            request_body.end() catch return error.Network;
            request.connection.?.flush() catch return error.Network;
        } else request.sendBodiless() catch return error.Network;
        var response = request.receiveHead(&.{}) catch return error.Network;
        if (response.head.content_encoding != .identity) return error.InvalidResponse;
        const status: u16 = @intFromEnum(response.head.status);
        var authenticate_storage: [mcp_oauth.Limits.header_bytes]u8 = undefined;
        var authenticate_writer = std.Io.Writer.fixed(&authenticate_storage);
        var authenticate_invalid = false;
        var iterator = response.head.iterateHeaders();
        while (iterator.next()) |header| {
            if (status < 200 or status >= 300) {
                if ((status == 401 or status == 403) and
                    std.ascii.eqlIgnoreCase(header.name, "WWW-Authenticate") and
                    !authenticate_invalid)
                {
                    if (authenticate_writer.buffered().len != 0)
                        authenticate_writer.writeAll(", ") catch {
                            authenticate_invalid = true;
                            continue;
                        };
                    authenticate_writer.writeAll(header.value) catch {
                        authenticate_invalid = true;
                        continue;
                    };
                }
            }
        }
        if (status == 401 or status == 403) {
            if (self.authorization) |authorization| if (authorization_lease) |*lease| {
                var challenge = if (!authenticate_invalid and
                    authenticate_writer.buffered().len != 0)
                    mcp_oauth.parseRuntimeBearerChallenge(
                        self.allocator,
                        authenticate_writer.buffered(),
                    ) catch null
                else
                    null;
                defer if (challenge) |*value| value.deinit();
                if (challenge) |*value|
                    authorization.recordRuntimeAuthFailure(lease, value.scopes);
            };
        }
        if (sink.begin_fn(sink.context, status) == .stop) {
            // Request callbacks preserve a complete 401/403 response for
            // AgentCore. Notifications have no response descriptor, so keep
            // their transport-level auth classification after recording the
            // OAuth challenge above.
            if (status == 401 or status == 403) return error.Auth;
            return;
        }
        iterator = response.head.iterateHeaders();
        while (iterator.next()) |header| if (sink.header_fn(
            sink.context,
            header.name,
            header.value,
        ) == .stop) return;
        if (sink.end_headers_fn(sink.context) == .stop) return;
        var transfer_buffer: [4096]u8 = undefined;
        const reader = response.reader(&transfer_buffer);
        while (true) {
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
            if (fed.flow == .stop) return;
            if (fed.consumed != chunk.len) return error.InvalidResponse;
        }
    }

    fn waitTimeout(io: std.Io, timeout_ms: u32) void {
        std.Io.Timeout.sleep(.{ .duration = .{
            .raw = std.Io.Duration.fromMilliseconds(timeout_ms),
            .clock = .awake,
        } }, io) catch {};
    }

    fn waitCancellation(io: std.Io, cancellation: agent.McpCancellation) void {
        while (!cancellation.isCancelled())
            std.Io.Timeout.sleep(.{ .duration = .{
                .raw = std.Io.Duration.fromMilliseconds(5),
                .clock = .awake,
            } }, io) catch return;
    }
};

fn createHttpOwner(
    io: std.Io,
    allocator: std.mem.Allocator,
    server: mcp_configuration.ServerWire,
    preparation: *const mcp_configuration.Preparation,
    authorization_output: *?*HttpAuthSlot,
) BuildError!agent.McpTransportOwner {
    authorization_output.* = null;
    const context = try allocator.create(HttpContext);
    errdefer allocator.destroy(context);
    context.* = .{
        .allocator = allocator,
        .io = io,
        .arena = std.heap.ArenaAllocator.init(allocator),
        .url = undefined,
        .custom_headers = &.{},
        .secret_values = &.{},
        .authorization = null,
        .backend = undefined,
    };
    errdefer context.arena.deinit();
    errdefer if (context.authorization) |authorization| authorization.release();
    const owned = context.arena.allocator();
    context.url = try owned.dupe(u8, server.transport.url orelse
        return error.InvalidConfig);
    context.custom_headers = try owned.alloc(std.http.Header, server.transport.headers.len);
    context.secret_values = try owned.alloc([]u8, server.transport.headers.len);
    for (context.secret_values) |*secret| secret.* = &.{};
    errdefer for (context.secret_values) |secret|
        if (secret.len != 0) std.crypto.secureZero(u8, secret);
    for (server.transport.headers, context.custom_headers, context.secret_values) |source, *header, *secret_value| {
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
            grant.consent_epoch,
            grant.token_revision,
            access_token,
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

test "OAuth HTTP authorization rotates only by same-epoch revision CAS" {
    const slot = try HttpAuthSlot.create(
        std.testing.allocator,
        std.testing.io,
        "oauth-server",
        4,
        7,
        "old-access-token",
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
        "new-access-token",
    )).?;
    defer pending.deinit();
    pending.commit();
    try std.testing.expectEqualStrings("old-access-token", in_flight.token());
    var next = slot.lease();
    defer next.deinit();
    try std.testing.expectEqualStrings("new-access-token", next.token());
    try std.testing.expectEqual(
        HttpAuthRotationOutcome.consent_epoch_mismatch,
        try authorizations.rotate("oauth-server", 5, 8, "wrong-epoch"),
    );
    try std.testing.expectEqual(
        HttpAuthRotationOutcome.token_revision_mismatch,
        try authorizations.rotate("oauth-server", 4, 7, "stale-revision"),
    );
}

test "OAuth HTTP authorization reservation is exclusive and abandonment is retryable" {
    const slot = try HttpAuthSlot.create(
        std.testing.allocator,
        std.testing.io,
        "oauth-server",
        4,
        7,
        "old-access-token",
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
        "first-token",
    )).?;
    try std.testing.expect((try authorizations.prepareRotation(
        "oauth-server",
        4,
        7,
        "second-token",
    )) == null);
    first.deinit();

    var retry = (try authorizations.prepareRotation(
        "oauth-server",
        4,
        7,
        "retry-token",
    )).?;
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
        4,
        7,
        "old-access-token",
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
        try authorizations.rotate("oauth-server", 4, 7, "new-access-token"),
    );
    slot.recordRuntimeAuthFailure(&rejected, &.{ "files.write", "files.read" });
    try std.testing.expectEqual(@as(usize, 1), wake.calls);

    var batch = try authorizations.takeRuntimeAuthFailures();
    defer batch.deinit();
    try std.testing.expectEqual(@as(usize, 1), batch.values.len);
    const failure = batch.values[0];
    try std.testing.expectEqualStrings("oauth-server", failure.server_id);
    try std.testing.expectEqual(@as(u64, 4), failure.consent_epoch);
    try std.testing.expectEqual(@as(u64, 7), failure.token_revision);
    try std.testing.expect(failure.challenge_scopes_complete);
    try std.testing.expectEqualStrings("files.read", failure.challenge_scopes[0]);
    try std.testing.expectEqualStrings("files.write", failure.challenge_scopes[1]);
}

test "MCP platform owns stdio process pipes and stderr drain" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const script =
        \\printf 'discarded-secret' >&2
        \\while IFS= read -r line; do printf '%s\n' "$line"; done
    ;
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    var owner = try createStdioTransportOwner(
        std.testing.io,
        std.testing.allocator,
        &.{ "/bin/sh", "-c", script },
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
    const request_bytes = "{\"jsonrpc\":\"2.0\",\"id\":1}";
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
    try std.testing.expectEqualStrings(request_bytes, response.body);
    transport.close_fn(connection);
    connection_open = false;
}

test "MCP platform closes stdio after a normal child exit" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    var owner = try createStdioTransportOwner(
        std.testing.io,
        std.testing.allocator,
        &.{
            "/bin/sh",
            "-c",
            "IFS= read -r line; printf '%s\\n' \"$line\"; exit 0",
        },
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
        "{}",
        1000,
        .{},
    )) {
        .response => |value| value,
        .failure => return error.TestUnexpectedResult,
    };
    defer std.testing.allocator.free(response.body);
    try std.testing.expectEqual(@as(u32, 0), response.http_status);
    try std.testing.expectEqualStrings("{}", response.body);
    std.Io.Timeout.sleep(.{ .duration = .{
        .raw = std.Io.Duration.fromMilliseconds(20),
        .clock = .awake,
    } }, std.testing.io) catch {};
    transport.close_fn(connection);
    connection_open = false;
}

test "MCP platform returns a loopback SSE response before the stream closes" {
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
        1,
        1,
        "runtime-access-token",
    );
    defer authorization.release();
    var context: HttpContext = .{
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

test "MCP platform publishes only a valid HTTP Bearer challenge" {
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
            try self.serveOne(true);
            try self.serveOne(false);
        }

        fn serveOne(self: *@This(), include_challenge: bool) !void {
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
                try request.respond("", .{ .status = .forbidden });
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
        3,
        8,
        "runtime-access-token",
    );
    defer authorization.release();
    var context: HttpContext = .{
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
        var failure = authorization.takeRuntimeAuthFailure().?;
        defer failure.deinit();
        try std.testing.expectEqual(@as(u64, 3), failure.consent_epoch);
        try std.testing.expectEqual(@as(u64, 8), failure.token_revision);
        try std.testing.expect(failure.challenge_scopes_complete);
        try std.testing.expectEqualStrings("files.read", failure.challenge_scopes[0]);
        try std.testing.expectEqualStrings("files.write", failure.challenge_scopes[1]);
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
    thread.join();
    try std.testing.expectEqual(@as(?anyerror, null), server.failure);
    try std.testing.expect(authorization.takeRuntimeAuthFailure() == null);
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
            .schema_version = 2,
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
    var input = (try buildRuntimeInput(
        std.testing.io,
        std.testing.allocator,
        &preparation,
        testHostEnvironment(),
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
            .schema_version = 2,
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
