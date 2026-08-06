//! Workbench-owned MCP registry codec and single-writer file capability.
//! The registry contains product configuration and credential locators only;
//! credential material is resolved by a separate Host capability.

const std = @import("std");
const builtin = @import("builtin");

pub const schema_version: u8 = 1;
pub const file_name = "registry.json";
pub const transaction_file_name = "transaction.json";
pub const max_store_bytes: usize = 256 * 1024;
pub const max_transaction_bytes: usize = 64 * 1024;
const lock_file_name = ".registry.lock";

pub const Limits = struct {
    max_servers: usize,
    max_tools_per_server: usize,
    max_identity_bytes: usize = 128,
    max_display_name_bytes: usize = 256,
    max_namespace_bytes: usize,
    max_command_bytes: usize = 4096,
    max_argument_count: usize = 128,
    max_argument_bytes: usize = 16 * 1024,
    max_environment_count: usize = 128,
    max_header_count: usize = 128,
    max_url_bytes: usize = 4096,
    max_credential_locators: usize,
    max_credential_locator_bytes: usize = 256,
    max_credential_secret_bytes: usize = 16 * 1024,
    max_tool_name_bytes: usize = 256,
};

pub const Error = error{
    RegistryEmpty,
    RegistryTooLarge,
    RegistryCorrupt,
    RegistryEncodeFailed,
    TransactionCorrupt,
    TransactionEncodeFailed,
    TransactionGenerationMismatch,
    CredentialCleanupFailed,
};

pub const FileStoreError = std.mem.Allocator.Error || error{
    DirectoryUnavailable,
    WriterAlreadyActive,
    ReadFailed,
    WriteFailed,
    PersistenceOutcomeUnknown,
};

pub const RegistryWire = struct {
    schema_version: u8,
    generation: u64,
    servers: []ServerWire,
};

pub const ServerWire = struct {
    id: []const u8,
    namespace: []const u8,
    display_name: []const u8,
    enabled: bool,
    negotiation: []const u8,
    timeout_ms: u32,
    transport: TransportWire,
    tools: []const []const u8 = &.{},
};

pub const TransportWire = struct {
    kind: []const u8,
    command: ?[]const u8 = null,
    arguments: []ValueSourceWire = &.{},
    cwd: ?[]const u8 = null,
    environment: []NamedValueWire = &.{},
    url: ?[]const u8 = null,
    headers: []NamedValueWire = &.{},
};

/// Exactly one field must be present. `literal` is ordinary configuration;
/// credential material must be represented by `credential_ref`.
pub const ValueSourceWire = struct {
    literal: ?[]const u8 = null,
    credential_ref: ?[]const u8 = null,
};

pub const NamedValueWire = struct {
    name: []const u8,
    value: ValueSourceWire,
};

pub const TransactionWire = struct {
    schema_version: u8,
    base_generation: u64,
    target_generation: u64,
    candidate_locators: []const []const u8,
    retired_locators: []const []const u8,
};

pub const CredentialCleanup = struct {
    context: ?*anyopaque = null,
    available: bool = false,
    delete_fn: *const fn (?*anyopaque, []const u8) bool = unavailableDelete,

    fn delete(self: CredentialCleanup, locator: []const u8) bool {
        return self.available and self.delete_fn(self.context, locator);
    }

    fn unavailableDelete(_: ?*anyopaque, _: []const u8) bool {
        return false;
    }
};

pub const ServerProblem = enum {
    invalid_display_name,
    invalid_negotiation,
    invalid_timeout,
    invalid_transport,
    invalid_allowlist,
    invalid_credential_locator,
};

pub const ServerPreparationState = union(enum) {
    eligible,
    disabled,
    needs_authentication,
    invalid_catalog: ServerProblem,
};

pub const UnavailableReason = enum {
    persistence_unavailable,
    read_failed,
    corrupt,
    credential_store_unavailable,
};

pub const PreparationState = union(enum) {
    empty,
    available,
    unavailable: UnavailableReason,
};

pub const CredentialResolution = union(enum) {
    /// The callback allocates with the supplied allocator and transfers
    /// ownership to the caller.
    value: []u8,
    missing,
    unavailable,
    out_of_memory,
};

pub const CredentialResolver = struct {
    context: ?*anyopaque = null,
    available: bool = false,
    resolve_fn: *const fn (
        context: ?*anyopaque,
        allocator: std.mem.Allocator,
        locator: []const u8,
    ) CredentialResolution = unavailableCredential,

    fn resolve(
        self: CredentialResolver,
        allocator: std.mem.Allocator,
        locator: []const u8,
    ) CredentialResolution {
        if (!self.available) return .unavailable;
        return self.resolve_fn(self.context, allocator, locator);
    }

    fn unavailableCredential(
        _: ?*anyopaque,
        _: std.mem.Allocator,
        _: []const u8,
    ) CredentialResolution {
        return .unavailable;
    }
};

pub const ResolvedCredential = struct {
    locator: []const u8,
    secret: []u8,
};

pub const Preparation = struct {
    allocator: std.mem.Allocator,
    state: PreparationState,
    registry: ?std.json.Parsed(RegistryWire) = null,
    server_states: []ServerPreparationState = &.{},
    credentials: []ResolvedCredential = &.{},

    pub fn deinit(self: *Preparation) void {
        for (self.credentials) |credential| secureFree(self.allocator, credential.secret);
        if (self.credentials.len != 0) self.allocator.free(self.credentials);
        if (self.server_states.len != 0) self.allocator.free(self.server_states);
        if (self.registry) |*registry| registry.deinit();
        self.* = undefined;
    }

    pub fn generation(self: *const Preparation) ?u64 {
        return if (self.registry) |registry| registry.value.generation else null;
    }

    /// Releases the linear credential staging copy after App has constructed
    /// Agent-owned transport capabilities. Product state retains only the
    /// registry and per-server preparation facts.
    pub fn releaseCredentials(self: *Preparation) void {
        for (self.credentials) |credential| secureFree(self.allocator, credential.secret);
        if (self.credentials.len != 0) self.allocator.free(self.credentials);
        self.credentials = &.{};
    }

    /// Moves the complete preparation into Workbench after every other
    /// fallible initialization step has succeeded.
    pub fn take(self: *Preparation) Preparation {
        const moved = self.*;
        self.* = undefined;
        return moved;
    }
};

/// Restores a registry and resolves only credentials referenced by enabled,
/// semantically valid servers. Expected MCP failures become typed state; only
/// allocator failure escapes as a fatal error.
pub fn prepare(
    allocator: std.mem.Allocator,
    restored_bytes: ?[]const u8,
    persistence_available: bool,
    restore_failed: bool,
    resolver: CredentialResolver,
    limits: Limits,
) std.mem.Allocator.Error!Preparation {
    if (!persistence_available)
        return .{ .allocator = allocator, .state = .{ .unavailable = .persistence_unavailable } };
    if (restore_failed)
        return .{ .allocator = allocator, .state = .{ .unavailable = .read_failed } };
    const bytes = restored_bytes orelse
        return .{ .allocator = allocator, .state = .empty };
    var registry = decode(allocator, bytes, limits) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .allocator = allocator, .state = .{ .unavailable = .corrupt } },
    };
    errdefer registry.deinit();
    const server_states = try allocator.alloc(ServerPreparationState, registry.value.servers.len);
    errdefer allocator.free(server_states);
    var credentials: std.ArrayList(ResolvedCredential) = .empty;
    errdefer {
        for (credentials.items) |credential| secureFree(allocator, credential.secret);
        credentials.deinit(allocator);
    }

    for (registry.value.servers, 0..) |server, index| {
        if (serverProblem(server, limits)) |problem| {
            server_states[index] = .{ .invalid_catalog = problem };
            continue;
        }
        if (!server.enabled) {
            server_states[index] = .disabled;
            continue;
        }
        const resolution = resolveServerCredentials(
            allocator,
            server,
            resolver,
            limits,
            &credentials,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.CredentialStoreUnavailable => {
                for (credentials.items) |credential| secureFree(allocator, credential.secret);
                credentials.deinit(allocator);
                allocator.free(server_states);
                registry.deinit();
                return .{
                    .allocator = allocator,
                    .state = .{ .unavailable = .credential_store_unavailable },
                };
            },
        };
        server_states[index] = if (resolution) .eligible else .needs_authentication;
    }
    pruneUnusedCredentials(registry.value.servers, server_states, allocator, &credentials);
    return .{
        .allocator = allocator,
        .state = .available,
        .registry = registry,
        .server_states = server_states,
        .credentials = try credentials.toOwnedSlice(allocator),
    };
}

fn pruneUnusedCredentials(
    servers: []const ServerWire,
    states: []const ServerPreparationState,
    allocator: std.mem.Allocator,
    credentials: *std.ArrayList(ResolvedCredential),
) void {
    var write: usize = 0;
    for (credentials.items) |credential| {
        var used = false;
        for (servers, states) |server, state| {
            if (state != .eligible) continue;
            if (serverReferencesCredential(server, credential.locator)) {
                used = true;
                break;
            }
        }
        if (!used) {
            secureFree(allocator, credential.secret);
            continue;
        }
        credentials.items[write] = credential;
        write += 1;
    }
    credentials.shrinkRetainingCapacity(write);
}

fn serverReferencesCredential(server: ServerWire, locator: []const u8) bool {
    for (server.transport.arguments) |value|
        if (value.credential_ref) |candidate|
            if (std.mem.eql(u8, candidate, locator)) return true;
    for (server.transport.environment) |entry|
        if (entry.value.credential_ref) |candidate|
            if (std.mem.eql(u8, candidate, locator)) return true;
    for (server.transport.headers) |entry|
        if (entry.value.credential_ref) |candidate|
            if (std.mem.eql(u8, candidate, locator)) return true;
    return false;
}

const ResolveError = std.mem.Allocator.Error || error{CredentialStoreUnavailable};

fn resolveServerCredentials(
    allocator: std.mem.Allocator,
    server: ServerWire,
    resolver: CredentialResolver,
    limits: Limits,
    credentials: *std.ArrayList(ResolvedCredential),
) ResolveError!bool {
    var ready = true;
    for (server.transport.arguments) |value| {
        if (value.credential_ref) |locator| {
            ready = (try resolveCredential(allocator, locator, resolver, limits, credentials)) and ready;
        }
    }
    for (server.transport.environment) |entry| {
        if (entry.value.credential_ref) |locator| {
            ready = (try resolveCredential(allocator, locator, resolver, limits, credentials)) and ready;
        }
    }
    for (server.transport.headers) |entry| {
        if (entry.value.credential_ref) |locator| {
            ready = (try resolveCredential(allocator, locator, resolver, limits, credentials)) and ready;
        }
    }
    return ready;
}

fn resolveCredential(
    allocator: std.mem.Allocator,
    locator: []const u8,
    resolver: CredentialResolver,
    limits: Limits,
    credentials: *std.ArrayList(ResolvedCredential),
) ResolveError!bool {
    for (credentials.items) |credential|
        if (std.mem.eql(u8, credential.locator, locator)) return true;
    return switch (resolver.resolve(allocator, locator)) {
        .unavailable => error.CredentialStoreUnavailable,
        .out_of_memory => error.OutOfMemory,
        .missing => false,
        .value => |secret| blk: {
            if (secret.len == 0 or secret.len > limits.max_credential_secret_bytes) {
                secureFree(allocator, secret);
                break :blk false;
            }
            errdefer secureFree(allocator, secret);
            try credentials.append(allocator, .{ .locator = locator, .secret = secret });
            break :blk true;
        },
    };
}

fn secureFree(allocator: std.mem.Allocator, bytes: []u8) void {
    std.crypto.secureZero(u8, bytes);
    allocator.free(bytes);
}

pub fn decode(
    allocator: std.mem.Allocator,
    input: []const u8,
    limits: Limits,
) (Error || std.mem.Allocator.Error)!std.json.Parsed(RegistryWire) {
    if (input.len == 0) return error.RegistryEmpty;
    if (input.len > max_store_bytes) return error.RegistryTooLarge;
    var parsed = std.json.parseFromSlice(
        RegistryWire,
        allocator,
        input,
        .{ .ignore_unknown_fields = false },
    ) catch return error.RegistryCorrupt;
    errdefer parsed.deinit();
    validateRegistryIdentity(&parsed.value, limits) catch
        return error.RegistryCorrupt;
    return parsed;
}

pub fn encode(output: []u8, registry: RegistryWire, limits: Limits) Error![]const u8 {
    if (output.len == 0) return error.RegistryEncodeFailed;
    validateRegistryIdentity(&registry, limits) catch
        return error.RegistryEncodeFailed;
    var writer = std.Io.Writer.fixed(output);
    std.json.Stringify.value(registry, .{}, &writer) catch
        return error.RegistryEncodeFailed;
    const encoded = writer.buffered();
    if (encoded.len > max_store_bytes) return error.RegistryTooLarge;
    return encoded;
}

pub fn decodeTransaction(
    allocator: std.mem.Allocator,
    input: []const u8,
    limits: Limits,
) (Error || std.mem.Allocator.Error)!std.json.Parsed(TransactionWire) {
    if (input.len == 0 or input.len > max_transaction_bytes)
        return error.TransactionCorrupt;
    var parsed = std.json.parseFromSlice(
        TransactionWire,
        allocator,
        input,
        .{ .ignore_unknown_fields = false },
    ) catch return error.TransactionCorrupt;
    errdefer parsed.deinit();
    validateTransaction(&parsed.value, limits) catch
        return error.TransactionCorrupt;
    return parsed;
}

pub fn encodeTransaction(
    output: []u8,
    transaction: TransactionWire,
    limits: Limits,
) Error![]const u8 {
    if (output.len == 0) return error.TransactionEncodeFailed;
    validateTransaction(&transaction, limits) catch
        return error.TransactionEncodeFailed;
    var writer = std.Io.Writer.fixed(output);
    std.json.Stringify.value(transaction, .{}, &writer) catch
        return error.TransactionEncodeFailed;
    const encoded = writer.buffered();
    if (encoded.len > max_transaction_bytes) return error.TransactionEncodeFailed;
    return encoded;
}

/// Recovery is decided from the durable registry generation, not from a
/// separately mutable phase flag. At the old generation candidate credentials
/// are orphaned; at the target generation retired credentials are obsolete.
pub fn recoverCredentialTransaction(
    transaction: TransactionWire,
    current_registry_generation: u64,
    cleanup: CredentialCleanup,
) Error!void {
    const locators = if (current_registry_generation == transaction.base_generation)
        transaction.candidate_locators
    else if (current_registry_generation == transaction.target_generation)
        transaction.retired_locators
    else
        return error.TransactionGenerationMismatch;
    for (locators) |locator|
        if (!cleanup.delete(locator)) return error.CredentialCleanupFailed;
}

fn validateTransaction(transaction: *const TransactionWire, limits: Limits) !void {
    if (transaction.schema_version != schema_version or
        transaction.base_generation == std.math.maxInt(u64) or
        transaction.target_generation != transaction.base_generation + 1 or
        limits.max_credential_locators == 0 or
        transaction.candidate_locators.len > limits.max_credential_locators or
        transaction.retired_locators.len >
            limits.max_credential_locators - transaction.candidate_locators.len)
        return error.Invalid;
    for (transaction.candidate_locators, 0..) |locator, index| {
        if (!validCredentialLocator(locator, limits.max_credential_locator_bytes))
            return error.Invalid;
        for (transaction.candidate_locators[0..index]) |previous|
            if (std.mem.eql(u8, previous, locator)) return error.Invalid;
    }
    for (transaction.retired_locators, 0..) |locator, index| {
        if (!validCredentialLocator(locator, limits.max_credential_locator_bytes))
            return error.Invalid;
        for (transaction.retired_locators[0..index]) |previous|
            if (std.mem.eql(u8, previous, locator)) return error.Invalid;
        for (transaction.candidate_locators) |candidate|
            if (std.mem.eql(u8, candidate, locator)) return error.Invalid;
    }
}

/// Server-local semantic failures remain classifiable product state instead
/// of making the complete registry unreadable.
pub fn serverProblem(server: ServerWire, limits: Limits) ?ServerProblem {
    if (!validText(server.display_name, limits.max_display_name_bytes, false))
        return .invalid_display_name;
    if (!oneOf(server.negotiation, &.{ "automatic", "modern_only", "compat_only" }))
        return .invalid_negotiation;
    if (server.timeout_ms == 0) return .invalid_timeout;
    for (server.tools, 0..) |tool, index| {
        if (!validText(tool, limits.max_tool_name_bytes, false))
            return .invalid_allowlist;
        for (server.tools[0..index]) |previous|
            if (std.mem.eql(u8, previous, tool)) return .invalid_allowlist;
    }
    return validateTransport(server.transport, limits);
}

fn validateRegistryIdentity(registry: *const RegistryWire, limits: Limits) !void {
    if (registry.schema_version != schema_version or registry.generation == 0 or
        registry.servers.len > limits.max_servers or limits.max_servers == 0 or
        limits.max_tools_per_server == 0 or limits.max_namespace_bytes == 0)
        return error.Invalid;
    for (registry.servers, 0..) |server, index| {
        if (!validIdentifier(server.id, limits.max_identity_bytes) or
            !validNamespace(server.namespace, limits.max_namespace_bytes) or
            server.tools.len > limits.max_tools_per_server)
            return error.Invalid;
        for (registry.servers[0..index]) |previous|
            if (std.mem.eql(u8, previous.id, server.id) or
                std.mem.eql(u8, previous.namespace, server.namespace))
                return error.Invalid;
    }
    var credential_locators: usize = 0;
    for (registry.servers) |server| {
        credential_locators = std.math.add(
            usize,
            credential_locators,
            credentialReferenceCount(server),
        ) catch return error.Invalid;
        if (credential_locators > limits.max_credential_locators)
            return error.Invalid;
    }
}

fn credentialReferenceCount(server: ServerWire) usize {
    var count: usize = 0;
    for (server.transport.arguments) |value| if (value.credential_ref != null) {
        count += 1;
    };
    for (server.transport.environment) |entry| if (entry.value.credential_ref != null) {
        count += 1;
    };
    for (server.transport.headers) |entry| if (entry.value.credential_ref != null) {
        count += 1;
    };
    return count;
}

fn validateTransport(transport: TransportWire, limits: Limits) ?ServerProblem {
    if (std.mem.eql(u8, transport.kind, "stdio")) {
        const command = transport.command orelse return .invalid_transport;
        if (transport.url != null or transport.headers.len != 0 or
            !validText(command, limits.max_command_bytes, false) or
            std.mem.indexOfScalar(u8, command, 0) != null or
            transport.arguments.len > limits.max_argument_count or
            transport.environment.len > limits.max_environment_count)
            return .invalid_transport;
        if (transport.cwd) |cwd|
            if (!validText(cwd, limits.max_command_bytes, false) or
                !std.fs.path.isAbsolute(cwd) or
                std.mem.indexOfScalar(u8, cwd, 0) != null)
                return .invalid_transport;
        var argument_bytes: usize = 0;
        for (transport.arguments) |argument| {
            if (argument.credential_ref != null) return .invalid_credential_locator;
            const value = validateValueSource(argument, limits) orelse
                return .invalid_credential_locator;
            argument_bytes = std.math.add(usize, argument_bytes, value.len) catch
                return .invalid_transport;
            if (argument_bytes > limits.max_argument_bytes)
                return .invalid_transport;
        }
        for (transport.environment, 0..) |entry, index| {
            if (!validEnvironmentName(entry.name)) return .invalid_transport;
            if (entry.value.literal != null or
                validateValueSource(entry.value, limits) == null)
                return .invalid_credential_locator;
            for (transport.environment[0..index]) |previous|
                if (std.ascii.eqlIgnoreCase(previous.name, entry.name))
                    return .invalid_transport;
        }
        return null;
    }
    if (!std.mem.eql(u8, transport.kind, "streamable_http"))
        return .invalid_transport;
    const url = transport.url orelse return .invalid_transport;
    if (transport.command != null or transport.arguments.len != 0 or
        transport.cwd != null or transport.environment.len != 0 or
        transport.headers.len > limits.max_header_count or
        !validEndpoint(url, limits.max_url_bytes))
        return .invalid_transport;
    for (transport.headers, 0..) |entry, index| {
        if (!validHeaderName(entry.name) or reservedHttpHeader(entry.name))
            return .invalid_transport;
        const source = validateValueSource(entry.value, limits) orelse
            return .invalid_credential_locator;
        if (entry.value.literal != null)
            return .invalid_credential_locator;
        if (source.len == 0) return .invalid_transport;
        for (transport.headers[0..index]) |previous|
            if (std.ascii.eqlIgnoreCase(previous.name, entry.name))
                return .invalid_transport;
    }
    return null;
}

fn reservedHttpHeader(name: []const u8) bool {
    inline for (.{
        "Accept",
        "Accept-Encoding",
        "Content-Length",
        "Content-Type",
        "Host",
        "MCP-Protocol-Version",
        "Mcp-Session-Id",
    }) |reserved| if (std.ascii.eqlIgnoreCase(name, reserved)) return true;
    return false;
}

fn validateValueSource(value: ValueSourceWire, limits: Limits) ?[]const u8 {
    if ((value.literal == null) == (value.credential_ref == null)) return null;
    if (value.credential_ref) |locator|
        return if (validCredentialLocator(locator, limits.max_credential_locator_bytes))
            locator
        else
            null;
    const literal = value.literal.?;
    return if (validText(literal, limits.max_argument_bytes, true) and
        std.mem.indexOfScalar(u8, literal, 0) == null)
        literal
    else
        null;
}

fn validEndpoint(value: []const u8, max_bytes: usize) bool {
    if (!validText(value, max_bytes, false) or
        std.mem.indexOfAny(u8, value, "?#\r\n") != null)
        return false;
    const uri = std.Uri.parse(value) catch return false;
    if (uri.user != null or uri.password != null or uri.query != null or
        uri.fragment != null or uri.host == null)
        return false;
    if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) return true;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http")) return false;
    var host_storage: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = uri.getHost(&host_storage) catch return false;
    return std.ascii.eqlIgnoreCase(host.bytes, "localhost") or
        std.mem.eql(u8, host.bytes, "127.0.0.1") or
        std.mem.eql(u8, host.bytes, "::1") or
        std.mem.eql(u8, host.bytes, "[::1]");
}

fn validIdentifier(value: []const u8, max_bytes: usize) bool {
    if (value.len == 0 or value.len > max_bytes) return false;
    for (value) |byte|
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_')
            return false;
    return true;
}

fn validNamespace(value: []const u8, max_bytes: usize) bool {
    if (value.len == 0 or value.len > max_bytes) return false;
    for (value) |byte|
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_')
            return false;
    return true;
}

fn validCredentialLocator(value: []const u8, max_bytes: usize) bool {
    if (value.len == 0 or value.len > max_bytes) return false;
    for (value) |byte|
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_' and
            byte != '.' and byte != '/')
            return false;
    return true;
}

fn validEnvironmentName(value: []const u8) bool {
    if (value.len == 0 or value.len > 256 or
        (!std.ascii.isAlphabetic(value[0]) and value[0] != '_'))
        return false;
    for (value[1..]) |byte|
        if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
    return true;
}

fn validHeaderName(value: []const u8) bool {
    if (value.len == 0 or value.len > 256) return false;
    for (value) |byte|
        if (!std.ascii.isAlphanumeric(byte) and
            std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", byte) == null)
            return false;
    return true;
}

fn validText(value: []const u8, max_bytes: usize, allow_empty: bool) bool {
    return (allow_empty or value.len != 0) and value.len <= max_bytes and
        std.unicode.utf8ValidateSlice(value);
}

fn oneOf(value: []const u8, choices: []const []const u8) bool {
    for (choices) |choice| if (std.mem.eql(u8, value, choice)) return true;
    return false;
}

pub const FileStore = struct {
    io: std.Io,
    dir: std.Io.Dir,
    lock_file: std.Io.File,

    pub fn init(io: std.Io, absolute_directory: []const u8) FileStoreError!FileStore {
        if (!std.fs.path.isAbsolute(absolute_directory))
            return error.DirectoryUnavailable;
        const dir = std.Io.Dir.cwd().createDirPathOpen(io, absolute_directory, .{
            .open_options = .{ .follow_symlinks = false },
            .permissions = directoryPermissions(),
        }) catch return error.DirectoryUnavailable;
        errdefer dir.close(io);
        const lock_file = openOrCreateLock(io, dir) catch |err| switch (err) {
            error.WouldBlock => return error.WriterAlreadyActive,
            else => return error.DirectoryUnavailable,
        };
        return .{ .io = io, .dir = dir, .lock_file = lock_file };
    }

    pub fn deinit(self: *FileStore) void {
        self.lock_file.close(self.io);
        self.dir.close(self.io);
        self.* = undefined;
    }

    pub fn loadAlloc(self: *FileStore, allocator: std.mem.Allocator) FileStoreError!?[]u8 {
        return self.loadNamedAlloc(allocator, file_name, max_store_bytes);
    }

    pub fn loadTransactionAlloc(
        self: *FileStore,
        allocator: std.mem.Allocator,
    ) FileStoreError!?[]u8 {
        return self.loadNamedAlloc(allocator, transaction_file_name, max_transaction_bytes);
    }

    fn loadNamedAlloc(
        self: *FileStore,
        allocator: std.mem.Allocator,
        name: []const u8,
        max_bytes: usize,
    ) FileStoreError!?[]u8 {
        var file = self.dir.openFile(self.io, name, .{
            .follow_symlinks = false,
            .resolve_beneath = true,
        }) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return error.ReadFailed,
        };
        if (builtin.os.tag == .windows) file.flags.nonblocking = true;
        defer file.close(self.io);
        const length = file.length(self.io) catch return error.ReadFailed;
        if (length == 0 or length > max_bytes) return error.ReadFailed;
        const bytes = try allocator.alloc(u8, @intCast(length));
        errdefer allocator.free(bytes);
        const read = file.readPositionalAll(self.io, bytes, 0) catch
            return error.ReadFailed;
        if (read != length) return error.ReadFailed;
        return bytes;
    }

    pub fn commit(self: *FileStore, bytes: []const u8) FileStoreError!void {
        if (bytes.len == 0 or bytes.len > max_store_bytes) return error.WriteFailed;
        return self.commitNamed(bytes, file_name, ".registry");
    }

    pub fn commitTransaction(self: *FileStore, bytes: []const u8) FileStoreError!void {
        if (bytes.len == 0 or bytes.len > max_transaction_bytes) return error.WriteFailed;
        return self.commitNamed(bytes, transaction_file_name, ".transaction");
    }

    pub fn clearTransaction(self: *FileStore) FileStoreError!void {
        self.dir.deleteFile(self.io, transaction_file_name) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return error.WriteFailed,
        };
        // Replaying credential cleanup is idempotent. Windows cannot fsync the
        // containing directory, so a crash may leave the journal to be replayed
        // once more instead of making the cleanup outcome ambiguous.
        if (!self.syncCommit(null)) return error.PersistenceOutcomeUnknown;
    }

    pub fn recoverPendingCredentialTransaction(
        self: *FileStore,
        allocator: std.mem.Allocator,
        current_registry_generation: u64,
        cleanup: CredentialCleanup,
        limits: Limits,
    ) (FileStoreError || Error)!bool {
        const bytes = (try self.loadTransactionAlloc(allocator)) orelse return false;
        defer allocator.free(bytes);
        var transaction = try decodeTransaction(allocator, bytes, limits);
        defer transaction.deinit();
        try recoverCredentialTransaction(
            transaction.value,
            current_registry_generation,
            cleanup,
        );
        try self.clearTransaction();
        return true;
    }

    fn commitNamed(
        self: *FileStore,
        bytes: []const u8,
        target_name: []const u8,
        temp_prefix: []const u8,
    ) FileStoreError!void {
        var random: [8]u8 = undefined;
        std.Io.randomSecure(self.io, &random) catch return error.WriteFailed;
        const random_hex = std.fmt.bytesToHex(random, .lower);
        var name_storage: [64]u8 = undefined;
        var writer = std.Io.Writer.fixed(&name_storage);
        writer.print("{s}.{s}.tmp", .{ temp_prefix, random_hex }) catch
            return error.WriteFailed;
        const temp_name = writer.buffered();
        const file = self.dir.createFile(self.io, temp_name, .{
            .exclusive = true,
            .permissions = privateFilePermissions(),
            .resolve_beneath = true,
        }) catch return error.WriteFailed;
        var file_open = true;
        var temp_exists = true;
        defer {
            if (file_open) file.close(self.io);
            if (temp_exists) self.dir.deleteFile(self.io, temp_name) catch {};
        }
        file.writeStreamingAll(self.io, bytes) catch return error.WriteFailed;
        file.sync(self.io) catch return error.WriteFailed;
        file.close(self.io);
        file_open = false;
        self.dir.rename(temp_name, self.dir, target_name, self.io) catch
            return error.WriteFailed;
        temp_exists = false;
        if (!self.syncCommit(target_name)) return error.PersistenceOutcomeUnknown;
    }

    fn syncCommit(self: *FileStore, target_name: ?[]const u8) bool {
        if (builtin.os.tag == .windows) {
            const name = target_name orelse return true;
            const file = self.dir.openFile(self.io, name, .{
                .mode = .read_write,
                .allow_directory = false,
                .follow_symlinks = false,
                .resolve_beneath = true,
            }) catch return false;
            defer file.close(self.io);
            file.sync(self.io) catch return false;
            return true;
        }
        const directory_file: std.Io.File = .{
            .handle = self.dir.handle,
            .flags = .{ .nonblocking = false },
        };
        directory_file.sync(self.io) catch return false;
        return true;
    }
};

fn openOrCreateLock(io: std.Io, dir: std.Io.Dir) !std.Io.File {
    const existing = dir.openFile(io, lock_file_name, .{
        .mode = .read_write,
        .lock = .exclusive,
        .lock_nonblocking = true,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (existing) |file| return file;
    return dir.createFile(io, lock_file_name, .{
        .read = true,
        .truncate = false,
        .exclusive = true,
        .lock = .exclusive,
        .lock_nonblocking = true,
        .permissions = privateFilePermissions(),
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.PathAlreadyExists => return dir.openFile(io, lock_file_name, .{
            .mode = .read_write,
            .lock = .exclusive,
            .lock_nonblocking = true,
            .follow_symlinks = false,
            .resolve_beneath = true,
        }),
        else => return err,
    };
}

fn directoryPermissions() std.Io.File.Permissions {
    return if (builtin.os.tag == .windows) .default_dir else .fromMode(0o700);
}

fn privateFilePermissions() std.Io.File.Permissions {
    return if (builtin.os.tag == .windows) .default_file else .fromMode(0o600);
}

const test_limits: Limits = .{
    .max_servers = 4,
    .max_tools_per_server = 8,
    .max_namespace_bytes = 24,
    .max_credential_locators = 16,
};

test "registry strictly decodes valid stdio and HTTP configuration" {
    const bytes =
        \\{"schema_version":1,"generation":7,"servers":[{"id":"local-files","namespace":"files","display_name":"Files","enabled":true,"negotiation":"automatic","timeout_ms":1000,"transport":{"kind":"stdio","command":"/usr/bin/files-mcp","arguments":[{"literal":"--root"},{"literal":"/tmp"}],"environment":[{"name":"FILES_TOKEN","value":{"credential_ref":"files/token"}}]},"tools":["read_file"]},{"id":"remote-search","namespace":"search","display_name":"Search","enabled":true,"negotiation":"compat_only","timeout_ms":2000,"transport":{"kind":"streamable_http","url":"https://mcp.example.test/rpc","headers":[{"name":"Authorization","value":{"credential_ref":"search/bearer"}}]},"tools":[]}]}
    ;
    var parsed = try decode(std.testing.allocator, bytes, test_limits);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u64, 7), parsed.value.generation);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.servers.len);
    for (parsed.value.servers) |server|
        try std.testing.expectEqual(@as(?ServerProblem, null), serverProblem(server, test_limits));
}

test "registry preserves server-local invalid configuration for product classification" {
    const bytes =
        \\{"schema_version":1,"generation":1,"servers":[{"id":"remote","namespace":"remote","display_name":"Remote","enabled":true,"negotiation":"automatic","timeout_ms":1000,"transport":{"kind":"streamable_http","url":"https://mcp.example.test/rpc","headers":[{"name":"Authorization","value":{"literal":"raw-secret"}}]}}]}
    ;
    var parsed = try decode(std.testing.allocator, bytes, test_limits);
    defer parsed.deinit();
    try std.testing.expectEqual(
        ServerProblem.invalid_credential_locator,
        serverProblem(parsed.value.servers[0], test_limits).?,
    );
}

test "registry never treats argv env or headers as secret-capable literals" {
    const cases = [_][]const u8{
        \\{"schema_version":1,"generation":1,"servers":[{"id":"argv","namespace":"argv","display_name":"Argv","enabled":true,"negotiation":"automatic","timeout_ms":1000,"transport":{"kind":"stdio","command":"tool","arguments":[{"credential_ref":"secret/arg"}]}}]}
        ,
        \\{"schema_version":1,"generation":1,"servers":[{"id":"env","namespace":"env","display_name":"Env","enabled":true,"negotiation":"automatic","timeout_ms":1000,"transport":{"kind":"stdio","command":"tool","environment":[{"name":"TOKEN","value":{"literal":"secret"}}]}}]}
        ,
        \\{"schema_version":1,"generation":1,"servers":[{"id":"header","namespace":"header","display_name":"Header","enabled":true,"negotiation":"automatic","timeout_ms":1000,"transport":{"kind":"streamable_http","url":"https://mcp.example.test/rpc","headers":[{"name":"X-Custom-Token","value":{"literal":"secret"}}]}}]}
        ,
    };
    for (cases) |bytes| {
        var parsed = try decode(std.testing.allocator, bytes, test_limits);
        defer parsed.deinit();
        try std.testing.expectEqual(
            ServerProblem.invalid_credential_locator,
            serverProblem(parsed.value.servers[0], test_limits).?,
        );
    }
}

test "registry reserves Host-owned Streamable HTTP mechanics headers" {
    inline for (.{
        "Accept",
        "accept-encoding",
        "Content-Length",
        "content-type",
        "Host",
        "mcp-protocol-version",
        "Mcp-Session-Id",
    }) |header_name| {
        const bytes = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"schema_version\":1,\"generation\":1,\"servers\":[{{\"id\":\"remote\",\"namespace\":\"remote\",\"display_name\":\"Remote\",\"enabled\":true,\"negotiation\":\"automatic\",\"timeout_ms\":1000,\"transport\":{{\"kind\":\"streamable_http\",\"url\":\"https://mcp.example.test/rpc\",\"headers\":[{{\"name\":\"{s}\",\"value\":{{\"credential_ref\":\"secret/header\"}}}}]}}}}]}}",
            .{header_name},
        );
        defer std.testing.allocator.free(bytes);
        var parsed = try decode(std.testing.allocator, bytes, test_limits);
        defer parsed.deinit();
        try std.testing.expectEqual(
            ServerProblem.invalid_transport,
            serverProblem(parsed.value.servers[0], test_limits).?,
        );
    }
}

test "registry bounds the aggregate credential locator count" {
    var limits = test_limits;
    limits.max_credential_locators = 1;
    try std.testing.expectError(
        error.RegistryCorrupt,
        decode(
            std.testing.allocator,
            "{\"schema_version\":1,\"generation\":1,\"servers\":[{\"id\":\"env\",\"namespace\":\"env\",\"display_name\":\"Env\",\"enabled\":true,\"negotiation\":\"automatic\",\"timeout_ms\":1000,\"transport\":{\"kind\":\"stdio\",\"command\":\"tool\",\"environment\":[{\"name\":\"FIRST\",\"value\":{\"credential_ref\":\"secret/one\"}},{\"name\":\"SECOND\",\"value\":{\"credential_ref\":\"secret/two\"}}]}}]}",
            limits,
        ),
    );
}

test "registry rejects ambiguous identity and unknown fields" {
    try std.testing.expectError(
        error.RegistryCorrupt,
        decode(
            std.testing.allocator,
            "{\"schema_version\":1,\"generation\":1,\"servers\":[],\"extra\":true}",
            test_limits,
        ),
    );
    try std.testing.expectError(
        error.RegistryCorrupt,
        decode(
            std.testing.allocator,
            "{\"schema_version\":1,\"generation\":1,\"servers\":[{\"id\":\"same\",\"namespace\":\"one\",\"display_name\":\"One\",\"enabled\":false,\"negotiation\":\"automatic\",\"timeout_ms\":1,\"transport\":{\"kind\":\"stdio\",\"command\":\"tool\"}},{\"id\":\"same\",\"namespace\":\"two\",\"display_name\":\"Two\",\"enabled\":false,\"negotiation\":\"automatic\",\"timeout_ms\":1,\"transport\":{\"kind\":\"stdio\",\"command\":\"tool\"}}]}",
            test_limits,
        ),
    );
}

test "registry permits plaintext HTTP only for exact loopback authorities" {
    try std.testing.expect(validEndpoint("http://localhost:4310/mcp", 4096));
    try std.testing.expect(validEndpoint("http://127.0.0.1/mcp", 4096));
    try std.testing.expect(validEndpoint("http://[::1]:4310/mcp", 4096));
    try std.testing.expect(!validEndpoint("http://localhost.example/mcp", 4096));
    try std.testing.expect(!validEndpoint("http://127.0.0.1.example/mcp", 4096));
    try std.testing.expect(!validEndpoint("http://localhost:70000/mcp", 4096));
}

test "registry file store atomically replaces bytes under one writer lock" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const lock = try tmp.dir.createFile(std.testing.io, lock_file_name, .{
        .read = true,
        .truncate = false,
    });
    var store: FileStore = .{ .io = std.testing.io, .dir = tmp.dir, .lock_file = lock };
    try store.commit("{\"schema_version\":1}");
    const restored = (try store.loadAlloc(std.testing.allocator)).?;
    defer std.testing.allocator.free(restored);
    try std.testing.expectEqualStrings("{\"schema_version\":1}", restored);
    try store.commitTransaction("{\"schema_version\":1}");
    const transaction = (try store.loadTransactionAlloc(std.testing.allocator)).?;
    defer std.testing.allocator.free(transaction);
    try std.testing.expectEqualStrings("{\"schema_version\":1}", transaction);
    try store.clearTransaction();
    try std.testing.expectEqual(
        @as(?[]u8, null),
        try store.loadTransactionAlloc(std.testing.allocator),
    );
    store.lock_file.close(std.testing.io);
}

test "credential transaction recovery follows the durable registry generation" {
    const Cleanup = struct {
        deleted: [2][]const u8 = undefined,
        count: usize = 0,

        fn remove(context: ?*anyopaque, locator: []const u8) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.deleted[self.count] = locator;
            self.count += 1;
            return true;
        }
    };
    const bytes =
        \\{"schema_version":1,"base_generation":4,"target_generation":5,"candidate_locators":["candidate/a"],"retired_locators":["retired/a"]}
    ;
    var parsed = try decodeTransaction(std.testing.allocator, bytes, test_limits);
    defer parsed.deinit();
    var cleanup: Cleanup = .{};
    const capability: CredentialCleanup = .{
        .context = &cleanup,
        .available = true,
        .delete_fn = Cleanup.remove,
    };
    try recoverCredentialTransaction(parsed.value, 4, capability);
    try std.testing.expectEqualStrings("candidate/a", cleanup.deleted[0]);
    cleanup.count = 0;
    try recoverCredentialTransaction(parsed.value, 5, capability);
    try std.testing.expectEqualStrings("retired/a", cleanup.deleted[0]);
    try std.testing.expectError(
        error.TransactionGenerationMismatch,
        recoverCredentialTransaction(parsed.value, 6, capability),
    );

    var initial = try decodeTransaction(
        std.testing.allocator,
        "{\"schema_version\":1,\"base_generation\":0,\"target_generation\":1,\"candidate_locators\":[\"candidate/a\"],\"retired_locators\":[]}",
        test_limits,
    );
    defer initial.deinit();
    cleanup.count = 0;
    try recoverCredentialTransaction(initial.value, 0, capability);
    try std.testing.expectEqualStrings("candidate/a", cleanup.deleted[0]);
}

test "file store recovery cleans and closes a pending credential transaction" {
    const Cleanup = struct {
        count: usize = 0,

        fn remove(context: ?*anyopaque, locator: []const u8) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (!std.mem.eql(u8, locator, "candidate/a")) return false;
            self.count += 1;
            return true;
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const lock = try tmp.dir.createFile(std.testing.io, lock_file_name, .{
        .read = true,
        .truncate = false,
    });
    var store: FileStore = .{ .io = std.testing.io, .dir = tmp.dir, .lock_file = lock };
    defer store.lock_file.close(std.testing.io);
    try store.commitTransaction(
        "{\"schema_version\":1,\"base_generation\":4,\"target_generation\":5,\"candidate_locators\":[\"candidate/a\"],\"retired_locators\":[]}",
    );
    var cleanup: Cleanup = .{};
    try std.testing.expect(try store.recoverPendingCredentialTransaction(
        std.testing.allocator,
        4,
        .{ .context = &cleanup, .available = true, .delete_fn = Cleanup.remove },
        test_limits,
    ));
    try std.testing.expectEqual(@as(usize, 1), cleanup.count);
    try std.testing.expect(!(try store.recoverPendingCredentialTransaction(
        std.testing.allocator,
        4,
        .{ .context = &cleanup, .available = true, .delete_fn = Cleanup.remove },
        test_limits,
    )));
}

test "credential transaction rejects aliases across candidate and retired sets" {
    try std.testing.expectError(
        error.TransactionCorrupt,
        decodeTransaction(
            std.testing.allocator,
            "{\"schema_version\":1,\"base_generation\":1,\"target_generation\":2,\"candidate_locators\":[\"same\"],\"retired_locators\":[\"same\"]}",
            test_limits,
        ),
    );

    var limits = test_limits;
    limits.max_credential_locators = 1;
    try std.testing.expectError(
        error.TransactionCorrupt,
        decodeTransaction(
            std.testing.allocator,
            "{\"schema_version\":1,\"base_generation\":1,\"target_generation\":2,\"candidate_locators\":[\"candidate\"],\"retired_locators\":[\"retired\"]}",
            limits,
        ),
    );
}

test "preparation separates disabled invalid missing-auth and eligible servers" {
    const Resolver = struct {
        fn resolve(
            _: ?*anyopaque,
            allocator: std.mem.Allocator,
            locator: []const u8,
        ) CredentialResolution {
            if (std.mem.eql(u8, locator, "present/token"))
                return .{ .value = allocator.dupe(u8, "credential-value") catch
                    return .out_of_memory };
            return .missing;
        }
    };
    const bytes =
        \\{"schema_version":1,"generation":9,"servers":[{"id":"disabled","namespace":"disabled","display_name":"Disabled","enabled":false,"negotiation":"automatic","timeout_ms":1000,"transport":{"kind":"stdio","command":"tool"}},{"id":"invalid","namespace":"invalid","display_name":"Invalid","enabled":true,"negotiation":"automatic","timeout_ms":0,"transport":{"kind":"stdio","command":"tool"}},{"id":"missing","namespace":"missing","display_name":"Missing","enabled":true,"negotiation":"automatic","timeout_ms":1000,"transport":{"kind":"stdio","command":"tool","environment":[{"name":"TOKEN","value":{"credential_ref":"missing/token"}}]}},{"id":"ready","namespace":"ready","display_name":"Ready","enabled":true,"negotiation":"automatic","timeout_ms":1000,"transport":{"kind":"stdio","command":"tool","environment":[{"name":"TOKEN","value":{"credential_ref":"present/token"}}]}}]}
    ;
    var prepared = try prepare(
        std.testing.allocator,
        bytes,
        true,
        false,
        .{ .available = true, .resolve_fn = Resolver.resolve },
        test_limits,
    );
    defer prepared.deinit();
    try std.testing.expect(prepared.state == .available);
    try std.testing.expect(prepared.server_states[0] == .disabled);
    try std.testing.expectEqual(
        ServerProblem.invalid_timeout,
        prepared.server_states[1].invalid_catalog,
    );
    try std.testing.expect(prepared.server_states[2] == .needs_authentication);
    try std.testing.expect(prepared.server_states[3] == .eligible);
    try std.testing.expectEqual(@as(usize, 1), prepared.credentials.len);
    try std.testing.expectEqualStrings("present/token", prepared.credentials[0].locator);
    try std.testing.expectEqualStrings("credential-value", prepared.credentials[0].secret);
}

test "preparation classifies unsafe disabled server facts before projection" {
    const registry =
        \\{"schema_version":1,"generation":1,"servers":[{"id":"disabled","namespace":"disabled","display_name":"","enabled":false,"negotiation":"automatic","timeout_ms":1000,"transport":{"kind":"stdio","command":"tool"},"tools":[]}]}
    ;
    var prepared = try prepare(
        std.testing.allocator,
        registry,
        true,
        false,
        .{},
        test_limits,
    );
    defer prepared.deinit();
    try std.testing.expectEqual(
        ServerProblem.invalid_display_name,
        prepared.server_states[0].invalid_catalog,
    );
}

test "preparation keeps ordinary MCP empty or eligible without credential services" {
    var empty = try prepare(
        std.testing.allocator,
        null,
        true,
        false,
        .{},
        test_limits,
    );
    defer empty.deinit();
    try std.testing.expect(empty.state == .empty);

    const bytes =
        \\{"schema_version":1,"generation":1,"servers":[{"id":"local","namespace":"local","display_name":"Local","enabled":true,"negotiation":"automatic","timeout_ms":1000,"transport":{"kind":"stdio","command":"tool","arguments":[{"literal":"--safe"}]}}]}
    ;
    var local = try prepare(
        std.testing.allocator,
        bytes,
        true,
        false,
        .{},
        test_limits,
    );
    defer local.deinit();
    try std.testing.expect(local.state == .available);
    try std.testing.expect(local.server_states[0] == .eligible);
}

test "preparation makes credential backend failure globally unavailable" {
    const bytes =
        \\{"schema_version":1,"generation":1,"servers":[{"id":"remote","namespace":"remote","display_name":"Remote","enabled":true,"negotiation":"automatic","timeout_ms":1000,"transport":{"kind":"streamable_http","url":"https://mcp.example.test/rpc","headers":[{"name":"Authorization","value":{"credential_ref":"remote/token"}}]}}]}
    ;
    var prepared = try prepare(
        std.testing.allocator,
        bytes,
        true,
        false,
        .{},
        test_limits,
    );
    defer prepared.deinit();
    try std.testing.expectEqual(
        UnavailableReason.credential_store_unavailable,
        prepared.state.unavailable,
    );
    try std.testing.expectEqual(@as(?u64, null), prepared.generation());
}

test "preparation keeps resolver allocation failure fatal" {
    const Resolver = struct {
        fn resolve(
            _: ?*anyopaque,
            _: std.mem.Allocator,
            _: []const u8,
        ) CredentialResolution {
            return .out_of_memory;
        }
    };
    const bytes =
        \\{"schema_version":1,"generation":1,"servers":[{"id":"remote","namespace":"remote","display_name":"Remote","enabled":true,"negotiation":"automatic","timeout_ms":1000,"transport":{"kind":"streamable_http","url":"https://mcp.example.test/rpc","headers":[{"name":"Authorization","value":{"credential_ref":"remote/token"}}]}}]}
    ;
    try std.testing.expectError(
        error.OutOfMemory,
        prepare(
            std.testing.allocator,
            bytes,
            true,
            false,
            .{ .available = true, .resolve_fn = Resolver.resolve },
            test_limits,
        ),
    );
}

test "preparation does not retain partial credentials for ineligible servers" {
    const Resolver = struct {
        fn resolve(
            _: ?*anyopaque,
            allocator: std.mem.Allocator,
            locator: []const u8,
        ) CredentialResolution {
            if (std.mem.eql(u8, locator, "present/token"))
                return .{ .value = allocator.dupe(u8, "must-not-remain") catch
                    return .out_of_memory };
            return .missing;
        }
    };
    const bytes =
        \\{"schema_version":1,"generation":1,"servers":[{"id":"partial","namespace":"partial","display_name":"Partial","enabled":true,"negotiation":"automatic","timeout_ms":1000,"transport":{"kind":"stdio","command":"tool","environment":[{"name":"FIRST","value":{"credential_ref":"present/token"}},{"name":"SECOND","value":{"credential_ref":"missing/token"}}]}}]}
    ;
    var prepared = try prepare(
        std.testing.allocator,
        bytes,
        true,
        false,
        .{ .available = true, .resolve_fn = Resolver.resolve },
        test_limits,
    );
    defer prepared.deinit();
    try std.testing.expect(prepared.server_states[0] == .needs_authentication);
    try std.testing.expectEqual(@as(usize, 0), prepared.credentials.len);
}
