//! App-owned MCP platform composition. This module resolves system credential
//! locators on the Native main thread and constructs concrete stdio or
//! preauthorized HTTP transport owners. It does not interpret MCP payloads.

const std = @import("std");
const native_sdk = @import("native_sdk");
const agent = @import("metawork_agent");
const workbench = @import("metawork_workbench");
const mcp_oauth = @import("metawork_mcp_oauth");
const product_identity = @import("metawork_product_identity");

pub const credential_service = product_identity.mcp_credential_service;
pub const max_credential_secret_bytes = native_sdk.platform.max_credential_secret_bytes;
const client_name = "MetaWork";
const client_version = product_identity.version;
const max_custom_headers: usize = 128;
const max_session_token_bytes: usize = 1024;
const max_sse_framing_bytes: usize = 64 * 1024;

pub const CredentialStore = struct {
    io: std.Io,
    services: native_sdk.platform.PlatformServices,
    main_thread_id: std.Thread.Id,

    pub fn resolver(self: *CredentialStore) workbench.McpCredentialResolver {
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
    ) workbench.McpCredentialResolution {
        return resolve(self, allocator, locator);
    }

    pub fn cleanup(self: *CredentialStore) workbench.McpCredentialCleanup {
        return .{
            .context = self,
            .available = self.services.delete_credential_fn != null,
            .delete_fn = delete,
        };
    }

    pub fn effects(self: *CredentialStore) workbench.McpCredentialEffects {
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

    pub fn locatorGenerator(self: *CredentialStore) workbench.McpFreshLocatorGenerator {
        return .{
            .context = self,
            .available = true,
            .fill_fn = fillLocatorEntropy,
        };
    }

    pub fn serverIdentityGenerator(self: *CredentialStore) workbench.McpFreshServerIdentityGenerator {
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
    ) workbench.McpCredentialResolution {
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
    ) workbench.McpCredentialPresence {
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

    fn replace(
        self: *HttpAuthSlot,
        expected_consent_epoch: u64,
        expected_token_revision: u64,
        replacement: *HttpAuthSnapshot,
    ) HttpAuthRotationOutcome {
        self.mutex.lockUncancelable(self.io);
        const current = self.current;
        if (current.consent_epoch != expected_consent_epoch) {
            self.mutex.unlock(self.io);
            return .consent_epoch_mismatch;
        }
        if (current.token_revision != expected_token_revision or
            replacement.token_revision != expected_token_revision + 1 or
            replacement.consent_epoch != expected_consent_epoch)
        {
            self.mutex.unlock(self.io);
            return .token_revision_mismatch;
        }
        self.current = replacement;
        self.mutex.unlock(self.io);
        current.release();
        return .replaced;
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

    pub fn commit(self: *PendingHttpAuthRotation) HttpAuthRotationOutcome {
        const slot = self.slot orelse return .server_not_loaded;
        const replacement = self.replacement orelse return .token_revision_mismatch;
        const outcome = slot.replace(
            self.expected_consent_epoch,
            self.expected_token_revision,
            replacement,
        );
        if (outcome == .replaced) self.replacement = null;
        return outcome;
    }

    pub fn deinit(self: *PendingHttpAuthRotation) void {
        if (self.replacement) |replacement| replacement.release();
        if (self.slot) |slot| slot.release();
        self.* = undefined;
    }
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
        if (expected_token_revision == std.math.maxInt(u64))
            return .token_revision_mismatch;
        var pending = (try self.prepareRotation(
            server_id,
            expected_consent_epoch,
            expected_token_revision,
            access_token,
        )) orelse return .server_not_loaded;
        defer pending.deinit();
        const outcome = pending.commit();
        return outcome;
    }

    pub fn prepareRotation(
        self: *HttpAuthorizations,
        server_id: []const u8,
        expected_consent_epoch: u64,
        expected_token_revision: u64,
        access_token: []const u8,
    ) std.mem.Allocator.Error!?PendingHttpAuthRotation {
        if (!workbench.validMcpHttpHeaderCredential(access_token)) return null;
        const slot = for (self.slots) |candidate| {
            if (std.mem.eql(u8, candidate.server_id, server_id)) break candidate;
        } else return null;
        if (expected_token_revision == std.math.maxInt(u64)) return null;
        slot.retain();
        errdefer slot.release();
        return .{
            .slot = slot,
            .replacement = try HttpAuthSnapshot.create(
                self.allocator,
                expected_consent_epoch,
                expected_token_revision + 1,
                access_token,
            ),
            .expected_consent_epoch = expected_consent_epoch,
            .expected_token_revision = expected_token_revision,
        };
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

/// Builds a single-use Agent input from eligible servers only. On failure no
/// transport owner is consumed; successful Agent input construction takes all
/// concrete contexts as one commit.
pub fn buildRuntimeInput(
    io: std.Io,
    allocator: std.mem.Allocator,
    preparation: *const workbench.McpPreparedConfiguration,
) BuildError!?agent.McpRuntimeInput {
    var build = try buildRuntime(io, allocator, preparation);
    defer build.authorizations.deinit();
    return build.input;
}

pub fn buildRuntime(
    io: std.Io,
    allocator: std.mem.Allocator,
    preparation: *const workbench.McpPreparedConfiguration,
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
    if (eligible_count == 0)
        return .{ .authorizations = .{ .allocator = allocator } };

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
            createStdioOwner(io, allocator, server, preparation)
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
    preparation: *const workbench.McpPreparedConfiguration,
    locator: []const u8,
) ?[]const u8 {
    for (preparation.credentials) |credential|
        if (std.mem.eql(u8, credential.locator, locator)) return credential.secret;
    return null;
}

fn serverSecrets(
    allocator: std.mem.Allocator,
    server: workbench.McpServerConfigurationWire,
    preparation: *const workbench.McpPreparedConfiguration,
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
    arena: std.heap.ArenaAllocator,
    environment: std.process.Environ.Map,
    backend: agent.McpStdioBackend,

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

fn createStdioOwner(
    io: std.Io,
    allocator: std.mem.Allocator,
    server: workbench.McpServerConfigurationWire,
    preparation: *const workbench.McpPreparedConfiguration,
) BuildError!agent.McpTransportOwner {
    const context = try allocator.create(StdioContext);
    errdefer allocator.destroy(context);
    context.* = .{
        .allocator = allocator,
        .arena = std.heap.ArenaAllocator.init(allocator),
        .environment = std.process.Environ.Map.init(allocator),
        .backend = undefined,
    };
    errdefer context.arena.deinit();
    errdefer secureEnvironmentDeinit(&context.environment);
    const owned = context.arena.allocator();
    const argv = try owned.alloc([]const u8, server.transport.arguments.len + 1);
    argv[0] = try owned.dupe(u8, server.transport.command orelse
        return error.InvalidConfig);
    for (server.transport.arguments, argv[1..]) |argument, *target|
        target.* = try owned.dupe(u8, argument.literal orelse
            return error.InvalidConfig);
    for (server.transport.environment) |entry| {
        const locator = entry.credential_ref orelse return error.InvalidConfig;
        const secret = resolvedCredential(preparation, locator) orelse
            return error.InvalidConfig;
        if (!workbench.validMcpEnvironmentCredential(secret))
            return error.InvalidConfig;
        try context.environment.put(entry.name, secret);
    }
    const cwd: std.process.Child.Cwd = if (server.transport.cwd) |path|
        .{ .path = try owned.dupe(u8, path) }
    else
        .inherit;
    context.backend = agent.McpStdioBackend.init(.{
        .io = io,
        .allocator = allocator,
        .argv = argv,
        .cwd = cwd,
        .environ_map = &context.environment,
    }) catch return error.InvalidConfig;
    return agent.McpTransportOwner.init(context.backend.transport(), StdioContext.destroy);
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
            .close_fn = close,
        };
    }

    fn validateEndpoint(raw: *anyopaque) bool {
        const self: *HttpContext = @ptrCast(@alignCast(raw));
        return self.url.len != 0 and self.custom_headers.len <= max_custom_headers;
    }

    fn perform(
        raw: *anyopaque,
        allocator: std.mem.Allocator,
        request: agent.McpHttpRequest,
    ) agent.McpHttpPerformOutcome {
        const self: *HttpContext = @ptrCast(@alignCast(raw));
        if (request.cancellation.isCancelled()) return .{ .failure = .cancelled };
        const scratch = allocator.alloc(u8, request.max_response_bytes) catch
            return .{ .failure = .fatal };
        defer {
            std.crypto.secureZero(u8, scratch);
            allocator.free(scratch);
        }
        const fetched = self.fetch(
            .POST,
            if (request.notification) .notification else .request,
            request.era,
            request.session_token,
            request.body,
            request.timeout_ms,
            request.cancellation,
            scratch,
        ) catch |failure| return .{ .failure = switch (failure) {
            error.Timeout => .timeout,
            error.Cancelled => .cancelled,
            error.Auth => .auth,
            error.Server => .server,
            error.Network => .network,
            error.InvalidResponse => .fatal,
        } };
        const body = allocator.dupe(u8, fetched.body) catch
            return .{ .failure = .fatal };
        const session_token = if (fetched.sessionToken().len == 0)
            null
        else
            allocator.dupe(u8, fetched.sessionToken()) catch {
                std.crypto.secureZero(u8, body);
                allocator.free(body);
                return .{ .failure = .fatal };
            };
        return .{ .response = .{
            .body = body,
            .status = fetched.status,
            .session_token = session_token orelse &.{},
            .owned_session_token = session_token,
        } };
    }

    fn close(raw: *anyopaque, era: agent.McpEra, session_token: []const u8) void {
        if (session_token.len == 0) return;
        const self: *HttpContext = @ptrCast(@alignCast(raw));
        var scratch: [1024]u8 = undefined;
        _ = self.fetch(
            .DELETE,
            .close,
            era,
            session_token,
            "",
            1000,
            .{},
            &scratch,
        ) catch {};
        std.crypto.secureZero(u8, &scratch);
    }

    const FetchFailure = error{ Timeout, Cancelled, Auth, Server, Network, InvalidResponse };
    const ExchangeKind = enum { request, notification, close };
    const FetchResult = struct {
        status: u16,
        body: []const u8,
        session_token: [max_session_token_bytes]u8 = undefined,
        session_token_len: usize = 0,

        fn sessionToken(self: *const FetchResult) []const u8 {
            return self.session_token[0..self.session_token_len];
        }
    };
    const Event = union(enum) {
        response: FetchFailure!FetchResult,
        timeout,
        cancelled,
    };

    fn fetch(
        self: *HttpContext,
        method: std.http.Method,
        kind: ExchangeKind,
        era: agent.McpEra,
        session_token: []const u8,
        body: []const u8,
        timeout_ms: u32,
        cancellation: agent.McpCancellation,
        response_buffer: []u8,
    ) FetchFailure!FetchResult {
        var events: [3]Event = undefined;
        var select = std.Io.Select(Event).init(self.io, &events);
        select.async(.response, fetchOne, .{
            self,
            method,
            kind,
            era,
            session_token,
            body,
            response_buffer,
        });
        select.async(.timeout, waitTimeout, .{ self.io, timeout_ms });
        select.async(.cancelled, waitCancellation, .{ self.io, cancellation });
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
        method: std.http.Method,
        kind: ExchangeKind,
        era: agent.McpEra,
        session_token: []const u8,
        body: []const u8,
        response_buffer: []u8,
    ) FetchFailure!FetchResult {
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
        var headers: [max_custom_headers + 5]std.http.Header = undefined;
        var count: usize = 0;
        headers[count] = .{ .name = "Accept", .value = "application/json, text/event-stream" };
        count += 1;
        headers[count] = .{ .name = "MCP-Protocol-Version", .value = protocolVersion(era) };
        count += 1;
        if (method == .POST) {
            headers[count] = .{ .name = "Content-Type", .value = "application/json" };
            count += 1;
        }
        if (session_token.len != 0) {
            headers[count] = .{ .name = "Mcp-Session-Id", .value = session_token };
            count += 1;
        }
        for (self.custom_headers) |header| {
            headers[count] = header;
            count += 1;
        }
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
        if (method == .POST) {
            request.transfer_encoding = .{ .content_length = body.len };
            var request_body = request.sendBodyUnflushed(&.{}) catch return error.Network;
            request_body.writer.writeAll(body) catch return error.Network;
            request_body.end() catch return error.Network;
            request.connection.?.flush() catch return error.Network;
        } else request.sendBodiless() catch return error.Network;
        var response = request.receiveHead(&.{}) catch return error.Network;
        if (response.head.content_encoding != .identity) return error.InvalidResponse;
        var result: FetchResult = .{
            .status = @intFromEnum(response.head.status),
            .body = &.{},
        };
        var media_type: ?ResponseMediaType = null;
        var authenticate_storage: [mcp_oauth.Limits.header_bytes]u8 = undefined;
        var authenticate_writer = std.Io.Writer.fixed(&authenticate_storage);
        var authenticate_invalid = false;
        var iterator = response.head.iterateHeaders();
        while (iterator.next()) |header| {
            if (result.status < 200 or result.status >= 300) {
                if ((result.status == 401 or result.status == 403) and
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
                continue;
            }
            if (std.ascii.eqlIgnoreCase(header.name, "Mcp-Session-Id")) {
                if (result.session_token_len != 0 or header.value.len == 0 or
                    header.value.len > result.session_token.len)
                    return error.InvalidResponse;
                @memcpy(result.session_token[0..header.value.len], header.value);
                result.session_token_len = header.value.len;
                continue;
            }
            if (std.ascii.eqlIgnoreCase(header.name, "Content-Type")) {
                if (kind != .request) continue;
                if (media_type != null) return error.InvalidResponse;
                media_type = responseMediaType(header.value) orelse
                    return error.InvalidResponse;
            }
        }
        var transfer_buffer: [4096]u8 = undefined;
        const reader = response.reader(&transfer_buffer);
        if (result.status == 401 or result.status == 403) {
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
            return error.Auth;
        }
        if (result.status < 200 or result.status >= 300) return error.Server;
        result.body = switch (kind) {
            .request => switch (media_type orelse return error.InvalidResponse) {
                .json => try readBoundedBody(reader, response_buffer),
                .event_stream => try readSseResponse(reader, response_buffer),
            },
            .notification => body: {
                if (result.status != 202) return error.Server;
                const bytes = try readBoundedBody(reader, response_buffer);
                if (bytes.len != 0) return error.InvalidResponse;
                break :body bytes;
            },
            .close => try readBoundedBody(reader, response_buffer),
        };
        return result;
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

const ResponseMediaType = enum { json, event_stream };

fn responseMediaType(value: []const u8) ?ResponseMediaType {
    const separator = std.mem.indexOfScalar(u8, value, ';') orelse value.len;
    const essence = std.mem.trim(u8, value[0..separator], " \t");
    if (std.ascii.eqlIgnoreCase(essence, "application/json")) return .json;
    if (std.ascii.eqlIgnoreCase(essence, "text/event-stream")) return .event_stream;
    return null;
}

fn readBoundedBody(
    reader: *std.Io.Reader,
    response_buffer: []u8,
) error{InvalidResponse}![]const u8 {
    var writer = std.Io.Writer.fixed(response_buffer);
    _ = reader.streamRemaining(&writer) catch return error.InvalidResponse;
    return writer.buffered();
}

const SseDecoder = struct {
    const FeedResult = enum { pending, complete };
    const LineKind = enum { pending, data, event, other, comment };

    output: []u8,
    output_len: usize = 0,
    max_wire_bytes: usize,
    wire_bytes: usize = 0,
    stream_start: bool = true,
    bom_len: u2 = 0,
    saw_data: bool = false,
    event_is_message: bool = true,
    ignore_lf_after_cr: bool = false,
    line_kind: LineKind = .pending,
    line_has_bytes: bool = false,
    in_value: bool = false,
    skip_value_space: bool = false,
    field_storage: [16]u8 = undefined,
    field_len: usize = 0,
    field_overflow: bool = false,
    event_value_len: usize = 0,
    event_value_matches: bool = true,

    fn init(output: []u8, max_wire_bytes: usize) SseDecoder {
        return .{ .output = output, .max_wire_bytes = max_wire_bytes };
    }

    fn message(self: *const SseDecoder) []const u8 {
        return self.output[0..self.output_len];
    }

    fn feedByte(self: *SseDecoder, byte: u8) error{InvalidResponse}!FeedResult {
        if (self.wire_bytes == self.max_wire_bytes) return error.InvalidResponse;
        self.wire_bytes += 1;
        if (self.stream_start) {
            const bom = "\xef\xbb\xbf";
            if (self.bom_len != 0) {
                if (byte != bom[self.bom_len]) return error.InvalidResponse;
                self.bom_len += 1;
                if (self.bom_len == bom.len) self.stream_start = false;
                return .pending;
            }
            if (byte == bom[0]) {
                self.bom_len = 1;
                return .pending;
            }
            self.stream_start = false;
        }
        if (byte == '\n' and self.ignore_lf_after_cr) {
            self.ignore_lf_after_cr = false;
            return .pending;
        }
        self.ignore_lf_after_cr = false;
        if (byte == '\r') {
            self.ignore_lf_after_cr = true;
            return self.finishLine();
        }
        if (byte == '\n') return self.finishLine();

        self.line_has_bytes = true;
        if (self.line_kind == .comment) return .pending;
        if (!self.in_value) {
            if (self.field_len == 0 and byte == ':') {
                self.line_kind = .comment;
                self.in_value = true;
                return .pending;
            }
            if (byte == ':') {
                self.in_value = true;
                self.classifyField();
                self.beginValue() catch return error.InvalidResponse;
                self.skip_value_space = true;
                return .pending;
            }
            if (self.field_len < self.field_storage.len) {
                self.field_storage[self.field_len] = byte;
                self.field_len += 1;
            } else self.field_overflow = true;
            return .pending;
        }

        if (self.skip_value_space) {
            self.skip_value_space = false;
            if (byte == ' ') return .pending;
        }
        switch (self.line_kind) {
            .data => try self.appendDataByte(byte),
            .event => {
                const expected = "message";
                if (self.event_value_len >= expected.len or
                    byte != expected[self.event_value_len])
                    self.event_value_matches = false;
                self.event_value_len += 1;
            },
            else => {},
        }
        return .pending;
    }

    fn finishLine(self: *SseDecoder) error{InvalidResponse}!FeedResult {
        if (!self.line_has_bytes) {
            const complete = self.saw_data and self.event_is_message;
            if (!complete) {
                self.output_len = 0;
                self.saw_data = false;
                self.event_is_message = true;
            }
            self.resetLine();
            return if (complete) .complete else .pending;
        }
        if (!self.in_value) {
            self.classifyField();
            try self.beginValue();
        }
        if (self.line_kind == .event) {
            self.event_is_message = self.event_value_len == 0 or
                (self.event_value_matches and self.event_value_len == "message".len);
        }
        self.resetLine();
        return .pending;
    }

    fn classifyField(self: *SseDecoder) void {
        if (self.field_overflow) {
            self.line_kind = .other;
        } else if (std.mem.eql(u8, self.field_storage[0..self.field_len], "data")) {
            self.line_kind = .data;
        } else if (std.mem.eql(u8, self.field_storage[0..self.field_len], "event")) {
            self.line_kind = .event;
        } else {
            self.line_kind = .other;
        }
    }

    fn beginValue(self: *SseDecoder) error{InvalidResponse}!void {
        switch (self.line_kind) {
            .data => {
                if (self.saw_data) try self.appendDataByte('\n');
                self.saw_data = true;
            },
            .event => {
                self.event_value_len = 0;
                self.event_value_matches = true;
            },
            else => {},
        }
    }

    fn appendDataByte(self: *SseDecoder, byte: u8) error{InvalidResponse}!void {
        if (self.output_len == self.output.len) return error.InvalidResponse;
        self.output[self.output_len] = byte;
        self.output_len += 1;
    }

    fn resetLine(self: *SseDecoder) void {
        self.line_kind = .pending;
        self.line_has_bytes = false;
        self.in_value = false;
        self.skip_value_space = false;
        self.field_len = 0;
        self.field_overflow = false;
        self.event_value_len = 0;
        self.event_value_matches = true;
    }
};

fn readSseResponse(
    reader: *std.Io.Reader,
    response_buffer: []u8,
) error{InvalidResponse}![]const u8 {
    const max_wire_bytes = std.math.add(
        usize,
        response_buffer.len,
        max_sse_framing_bytes,
    ) catch return error.InvalidResponse;
    var decoder = SseDecoder.init(response_buffer, max_wire_bytes);
    while (true) {
        const chunk = reader.peekGreedy(1) catch return error.InvalidResponse;
        for (chunk, 0..) |byte, index| {
            if (try decoder.feedByte(byte) == .complete) {
                reader.toss(index + 1);
                return decoder.message();
            }
        }
        reader.toss(chunk.len);
    }
}

fn createHttpOwner(
    io: std.Io,
    allocator: std.mem.Allocator,
    server: workbench.McpServerConfigurationWire,
    preparation: *const workbench.McpPreparedConfiguration,
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
        if (!workbench.validMcpHttpHeaderCredential(secret))
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
        if (!workbench.validMcpHttpHeaderCredential(access_token))
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

fn protocolVersion(era: agent.McpEra) []const u8 {
    return switch (era) {
        .modern_2026_07_28 => "2026-07-28",
        .compat_2025_11_25 => "2025-11-25",
    };
}

fn secureEnvironmentDeinit(environment: *std.process.Environ.Map) void {
    for (environment.values()) |value|
        std.crypto.secureZero(u8, @constCast(value));
    environment.deinit();
}

test "MCP platform protocol versions remain AgentCore era facts" {
    try std.testing.expectEqualStrings("2026-07-28", protocolVersion(.modern_2026_07_28));
    try std.testing.expectEqualStrings("2025-11-25", protocolVersion(.compat_2025_11_25));
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
    try std.testing.expectEqual(HttpAuthRotationOutcome.replaced, pending.commit());
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

test "MCP platform classifies JSON and event-stream response media types" {
    try std.testing.expectEqual(
        ResponseMediaType.json,
        responseMediaType(" Application/JSON ; charset=utf-8").?,
    );
    try std.testing.expectEqual(
        ResponseMediaType.event_stream,
        responseMediaType("text/event-stream; charset=utf-8").?,
    );
    try std.testing.expectEqual(
        @as(?ResponseMediaType, null),
        responseMediaType("text/plain"),
    );
}

test "MCP platform normalizes one bounded SSE message without waiting for EOF" {
    const input =
        "\xef\xbb\xbf: heartbeat\r\n" ++
        "event: ping\r\n" ++
        "data: ignored\r\n\r\n" ++
        "event: message\r\n" ++
        "data: {\"jsonrpc\":\"2.0\",\r\n" ++
        "data: \"id\":1}\r\n\r\n" ++
        "data: trailing-must-not-be-read\r\n\r\n";
    var reader = std.Io.Reader.fixed(input);
    var output: [128]u8 = undefined;
    const message = try readSseResponse(&reader, &output);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\n\"id\":1}",
        message,
    );
    try std.testing.expect(reader.seek < input.len);
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
    var output: [1024]u8 = undefined;
    const thread = try std.Thread.spawn(.{}, TestServer.run, .{&server});
    const result = context.fetch(
        .POST,
        .request,
        .modern_2026_07_28,
        "",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}",
        1000,
        .{},
        &output,
    );
    thread.join();
    try std.testing.expectEqual(@as(?anyerror, null), server.failure);
    try std.testing.expect(server.authorization_seen);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":1}",
        (try result).body,
    );
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
    var output: [1024]u8 = undefined;
    const thread = try std.Thread.spawn(.{}, TestServer.run, .{&server});
    try std.testing.expectError(error.Auth, context.fetch(
        .POST,
        .request,
        .modern_2026_07_28,
        "",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}",
        1000,
        .{},
        &output,
    ));
    {
        var failure = authorization.takeRuntimeAuthFailure().?;
        defer failure.deinit();
        try std.testing.expectEqual(@as(u64, 3), failure.consent_epoch);
        try std.testing.expectEqual(@as(u64, 8), failure.token_revision);
        try std.testing.expect(failure.challenge_scopes_complete);
        try std.testing.expectEqualStrings("files.read", failure.challenge_scopes[0]);
        try std.testing.expectEqualStrings("files.write", failure.challenge_scopes[1]);
    }
    try std.testing.expectError(error.Auth, context.fetch(
        .POST,
        .notification,
        .modern_2026_07_28,
        "",
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}",
        1000,
        .{},
        &output,
    ));
    thread.join();
    try std.testing.expectEqual(@as(?anyerror, null), server.failure);
    try std.testing.expect(authorization.takeRuntimeAuthFailure() == null);
}

test "MCP platform rejects an SSE payload beyond the response bound" {
    var reader = std.Io.Reader.fixed("data: 12345\n\n");
    var output: [4]u8 = undefined;
    try std.testing.expectError(
        error.InvalidResponse,
        readSseResponse(&reader, &output),
    );
}

test "MCP platform bounds ignored SSE framing bytes" {
    var output: [4]u8 = undefined;
    const input = try std.testing.allocator.alloc(
        u8,
        output.len + max_sse_framing_bytes + 1,
    );
    defer std.testing.allocator.free(input);
    @memset(input, 'x');
    input[0] = ':';
    var reader = std.Io.Reader.fixed(input);
    try std.testing.expectError(
        error.InvalidResponse,
        readSseResponse(&reader, &output),
    );
}

test "MCP platform builds lazy stdio and HTTP transport owners without opening them" {
    var servers = [_]workbench.McpServerConfigurationWire{
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
        approvals[index] = workbench.mcpConnectionFingerprint(server.*);
        server.connection_approval = .{ .fingerprint = &approvals[index] };
    }
    var registry_buffer: [workbench.mcp_registry_max_bytes]u8 = undefined;
    const registry = try workbench.encodeMcpRegistry(
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
    var preparation = try workbench.prepareMcpConfiguration(
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
        ) workbench.McpCredentialResolution {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            return .unavailable;
        }
    };
    var server_environment = [_]workbench.McpSecretSlotWire{.{
        .name = "MCP_TOKEN",
        .credential_ref = null,
    }};
    var servers = [_]workbench.McpServerConfigurationWire{.{
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
    var registry_buffer: [workbench.mcp_registry_max_bytes]u8 = undefined;
    const limits: workbench.McpConfigurationLimits = .{
        .max_servers = 8,
        .max_tools_per_server = 32,
        .max_namespace_bytes = 128,
        .max_credential_locators = 64,
        .max_runtime_secrets_per_server = (agent.McpRuntimeLimits{}).max_secrets,
        .max_runtime_secret_bytes_per_server = (agent.McpRuntimeLimits{}).max_secret_bytes,
    };
    const registry = try workbench.encodeMcpRegistry(
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
    var preparation = try workbench.prepareMcpConfiguration(
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
    try std.testing.expectEqual(workbench.McpServerPreparationState.unapproved, preparation.server_states[0]);
    try std.testing.expectEqual(@as(usize, 0), resolver.calls);
    try std.testing.expect((try buildRuntimeInput(
        std.testing.io,
        std.testing.allocator,
        &preparation,
    )) == null);
}
