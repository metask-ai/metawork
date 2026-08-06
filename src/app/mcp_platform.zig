//! App-owned MCP platform composition. This module resolves system credential
//! locators on the Native main thread and constructs concrete stdio or
//! preauthorized HTTP transport owners. It does not interpret MCP payloads.

const std = @import("std");
const native_sdk = @import("native_sdk");
const agent = @import("metawork_agent");
const workbench = @import("metawork_workbench");
const product_identity = @import("metawork_product_identity");

pub const credential_service = product_identity.mcp_credential_service;
const client_name = "MetaWork";
const client_version = product_identity.version;
const max_custom_headers: usize = 128;
const max_session_token_bytes: usize = 1024;

pub const CredentialStore = struct {
    services: native_sdk.platform.PlatformServices,
    main_thread_id: std.Thread.Id,

    pub fn resolver(self: *CredentialStore) workbench.McpCredentialResolver {
        return .{
            .context = self,
            .available = self.services.get_credential_fn != null,
            .resolve_fn = resolve,
        };
    }

    pub fn cleanup(self: *CredentialStore) workbench.McpCredentialCleanup {
        return .{
            .context = self,
            .available = self.services.delete_credential_fn != null,
            .delete_fn = delete,
        };
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

/// Builds a single-use Agent input from eligible servers only. On failure no
/// transport owner is consumed; successful Agent input construction takes all
/// concrete contexts as one commit.
pub fn buildRuntimeInput(
    io: std.Io,
    allocator: std.mem.Allocator,
    preparation: *const workbench.McpPreparedConfiguration,
) BuildError!?agent.McpRuntimeInput {
    if (preparation.state != .available or preparation.registry == null)
        return null;
    const registry = preparation.registry.?.value;
    var eligible_count: usize = 0;
    for (preparation.server_states) |state| {
        if (state == .eligible) eligible_count += 1;
    }
    if (eligible_count == 0) return null;

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
        owner.* = (if (std.mem.eql(u8, server.transport.kind, "stdio"))
            createStdioOwner(io, allocator, server, preparation)
        else if (std.mem.eql(u8, server.transport.kind, "streamable_http"))
            createHttpOwner(io, allocator, server, preparation)
        else
            error.InvalidConfig) catch |err| {
            allocator.destroy(owner);
            return err;
        };
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
    return input;
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
    const count = server.transport.environment.len + server.transport.headers.len;
    const values = try allocator.alloc([]const u8, count);
    var write: usize = 0;
    for (server.transport.environment) |entry| {
        const locator = entry.value.credential_ref orelse return error.InvalidConfig;
        const secret = resolvedCredential(preparation, locator) orelse
            return error.InvalidConfig;
        if (!containsSecret(values[0..write], secret)) {
            values[write] = secret;
            write += 1;
        }
    }
    for (server.transport.headers) |entry| {
        const locator = entry.value.credential_ref orelse return error.InvalidConfig;
        const secret = resolvedCredential(preparation, locator) orelse
            return error.InvalidConfig;
        if (!containsSecret(values[0..write], secret)) {
            values[write] = secret;
            write += 1;
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
        const locator = entry.value.credential_ref orelse return error.InvalidConfig;
        const secret = resolvedCredential(preparation, locator) orelse
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
    backend: agent.McpHttpBackend,

    fn destroy(raw: *anyopaque) void {
        const backend: *agent.McpHttpBackend = @ptrCast(@alignCast(raw));
        const self: *HttpContext = @fieldParentPtr("backend", backend);
        self.backend.deinit() catch @panic("MCP HTTP owner released with live connections");
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
        era: agent.McpEra,
        session_token: []const u8,
        body: []const u8,
        response_buffer: []u8,
    ) FetchFailure!FetchResult {
        var client: std.http.Client = .{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();
        const uri = std.Uri.parse(self.url) catch return error.InvalidResponse;
        var headers: [max_custom_headers + 4]std.http.Header = undefined;
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
            .headers = .{ .accept_encoding = .{ .override = "identity" } },
            .privileged_headers = headers[0..count],
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
        var iterator = response.head.iterateHeaders();
        while (iterator.next()) |header| if (std.ascii.eqlIgnoreCase(
            header.name,
            "Mcp-Session-Id",
        )) {
            if (result.session_token_len != 0 or header.value.len == 0 or
                header.value.len > result.session_token.len)
                return error.InvalidResponse;
            @memcpy(result.session_token[0..header.value.len], header.value);
            result.session_token_len = header.value.len;
        };
        var writer = std.Io.Writer.fixed(response_buffer);
        const reader = response.reader(&.{});
        _ = reader.streamRemaining(&writer) catch return error.InvalidResponse;
        result.body = writer.buffered();
        if (result.status == 401 or result.status == 403) return error.Auth;
        if (result.status < 200 or result.status >= 300) return error.Server;
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

fn createHttpOwner(
    io: std.Io,
    allocator: std.mem.Allocator,
    server: workbench.McpServerConfigurationWire,
    preparation: *const workbench.McpPreparedConfiguration,
) BuildError!agent.McpTransportOwner {
    const context = try allocator.create(HttpContext);
    errdefer allocator.destroy(context);
    context.* = .{
        .allocator = allocator,
        .io = io,
        .arena = std.heap.ArenaAllocator.init(allocator),
        .url = undefined,
        .custom_headers = &.{},
        .secret_values = &.{},
        .backend = undefined,
    };
    errdefer context.arena.deinit();
    const owned = context.arena.allocator();
    context.url = try owned.dupe(u8, server.transport.url orelse
        return error.InvalidConfig);
    context.custom_headers = try owned.alloc(std.http.Header, server.transport.headers.len);
    context.secret_values = try owned.alloc([]u8, server.transport.headers.len);
    for (context.secret_values) |*secret| secret.* = &.{};
    errdefer for (context.secret_values) |secret|
        if (secret.len != 0) std.crypto.secureZero(u8, secret);
    for (server.transport.headers, context.custom_headers, context.secret_values) |source, *header, *secret_value| {
        const locator = source.value.credential_ref orelse return error.InvalidConfig;
        const secret = resolvedCredential(preparation, locator) orelse
            return error.InvalidConfig;
        secret_value.* = try owned.dupe(u8, secret);
        header.* = .{
            .name = try owned.dupe(u8, source.name),
            .value = secret_value.*,
        };
    }
    context.backend = agent.McpHttpBackend.init(.{
        .io = io,
        .allocator = allocator,
        .endpoint = context.endpoint(),
    }) catch return error.InvalidConfig;
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

test "MCP platform builds lazy stdio and HTTP transport owners without opening them" {
    const registry =
        \\{"schema_version":1,"generation":3,"servers":[{"id":"stdio","namespace":"local","display_name":"Local","enabled":true,"negotiation":"modern_only","timeout_ms":1000,"transport":{"kind":"stdio","command":"/bin/echo","arguments":[],"environment":[]},"tools":[]},{"id":"http","namespace":"remote","display_name":"Remote","enabled":true,"negotiation":"compat_only","timeout_ms":1000,"transport":{"kind":"streamable_http","url":"https://example.test/mcp","headers":[]},"tools":[]}]}
    ;
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
