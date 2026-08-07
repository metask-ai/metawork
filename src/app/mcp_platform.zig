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
        var media_type: ?ResponseMediaType = null;
        var iterator = response.head.iterateHeaders();
        while (iterator.next()) |header| {
            if (result.status < 200 or result.status >= 300) continue;
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
        if (result.status == 401 or result.status == 403) return error.Auth;
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
        if (!workbench.validMcpHttpHeaderCredential(secret))
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
    var context: HttpContext = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .arena = arena,
        .url = url,
        .custom_headers = &.{},
        .secret_values = &.{},
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
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":1}",
        (try result).body,
    );
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
