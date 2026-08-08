//! Application-owned MCP OAuth mechanics. This module owns bounded HTTP
//! discovery/registration/token codecs and authorization-request construction;
//! Workbench remains the owner of durable product state and operation markers.

const std = @import("std");
const account_oauth = @import("account_oauth");
const account_loopback = @import("account_loopback");

pub const Limits = struct {
    pub const url_bytes: usize = 4096;
    pub const header_bytes: usize = 16 * 1024;
    pub const metadata_body_bytes: usize = 64 * 1024;
    pub const registration_body_bytes: usize = 32 * 1024;
    pub const token_body_bytes: usize = 32 * 1024;
    pub const request_body_bytes: usize = 32 * 1024;
    pub const issuers: usize = 8;
    pub const scopes: usize = 128;
    pub const scope_bytes: usize = 256;
    pub const client_id_bytes: usize = 4096;
    pub const secret_bytes: usize = 16 * 1024;
};

pub const Method = enum { get, post };

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Request = struct {
    method: Method,
    url: []const u8,
    headers: []const Header = &.{},
    body: []const u8 = "",
};

pub const Response = struct {
    status: u16,
    content_type: ?[]const u8 = null,
    www_authenticate: ?[]const u8 = null,
    body: []const u8 = "",
};

pub const FetchError = error{
    CancelledBeforeSend,
    Cancelled,
    DeadlineExceeded,
    Network,
    ResponseTooLarge,
    InvalidResponse,
};

/// Response slices are borrowed for the duration of the call and point into
/// caller-provided buffers or static storage.
pub const Transport = struct {
    context: ?*anyopaque = null,
    fetch_fn: *const fn (
        ?*anyopaque,
        Request,
        []u8,
        []u8,
    ) FetchError!Response,

    fn fetch(
        self: Transport,
        request: Request,
        body_buffer: []u8,
        header_buffer: []u8,
    ) FetchError!Response {
        return self.fetch_fn(self.context, request, body_buffer, header_buffer);
    }
};

pub const Cancellation = struct {
    io: std.Io,
    state: std.atomic.Value(u32) = .init(0),

    pub fn init(io: std.Io) Cancellation {
        return .{ .io = io };
    }

    pub fn cancel(self: *Cancellation) void {
        self.state.store(1, .release);
        self.io.futexWake(u32, &self.state.raw, std.math.maxInt(u32));
    }

    pub fn isCancelled(self: *const Cancellation) bool {
        return self.state.load(.acquire) != 0;
    }

    fn wait(self: *const Cancellation) void {
        while (!self.isCancelled())
            self.io.futexWait(u32, &self.state.raw, 0) catch return;
    }
};

/// Application HTTP effect for one sequential OAuth attempt. Deadline and
/// cancellation cover discovery as well as non-idempotent POSTs; callers must
/// still classify cancellation after a POST may have started as outcome
/// unknown rather than as proof that no remote effect occurred.
pub const StdHttpTransport = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cancellation: *const Cancellation,
    deadline: std.Io.Clock.Timestamp,

    pub fn transport(self: *StdHttpTransport) Transport {
        return .{ .context = self, .fetch_fn = fetch };
    }

    fn fetch(
        raw: ?*anyopaque,
        request: Request,
        body_buffer: []u8,
        header_buffer: []u8,
    ) FetchError!Response {
        const self: *StdHttpTransport = @ptrCast(@alignCast(raw.?));
        if (self.cancellation.isCancelled()) return error.CancelledBeforeSend;
        const Event = union(enum) {
            response: FetchError!Response,
            deadline,
            cancelled,
        };
        var events: [3]Event = undefined;
        var selection = std.Io.Select(Event).init(self.io, &events);
        selection.async(.response, fetchOne, .{
            self,
            request,
            body_buffer,
            header_buffer,
        });
        selection.async(.deadline, waitDeadline, .{ self.io, self.deadline });
        selection.async(.cancelled, waitCancellation, .{self.cancellation});
        const outcome = selection.await() catch {
            selection.cancelDiscard();
            return error.Network;
        };
        defer selection.cancelDiscard();
        return switch (outcome) {
            .response => |response| if (self.cancellation.isCancelled())
                error.Cancelled
            else
                response,
            .deadline => error.DeadlineExceeded,
            .cancelled => error.Cancelled,
        };
    }

    fn fetchOne(
        self: *StdHttpTransport,
        request: Request,
        body_buffer: []u8,
        header_buffer: []u8,
    ) FetchError!Response {
        if (!validHttpsUrl(request.url) or request.headers.len > 8)
            return error.InvalidResponse;
        const uri = std.Uri.parse(request.url) catch return error.InvalidResponse;
        var headers: [8]std.http.Header = undefined;
        var header_count: usize = 0;
        var authorization: ?[]const u8 = null;
        for (request.headers) |header| {
            if (header.name.len == 0 or
                std.mem.indexOfAny(u8, header.name, "\r\n:") != null or
                std.mem.indexOfAny(u8, header.value, "\r\n") != null)
                return error.InvalidResponse;
            if (std.ascii.eqlIgnoreCase(header.name, "Authorization")) {
                if (authorization != null) return error.InvalidResponse;
                authorization = header.value;
                continue;
            }
            headers[header_count] = .{ .name = header.name, .value = header.value };
            header_count += 1;
        }
        var client: std.http.Client = .{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();
        const method: std.http.Method = switch (request.method) {
            .get => .GET,
            .post => .POST,
        };
        var http_request = client.request(method, uri, .{
            .redirect_behavior = .unhandled,
            .headers = .{
                .accept_encoding = .{ .override = "identity" },
                .authorization = if (authorization) |value|
                    .{ .override = value }
                else
                    .default,
            },
            .extra_headers = headers[0..header_count],
        }) catch return error.Network;
        defer http_request.deinit();
        if (method == .POST) {
            http_request.transfer_encoding = .{ .content_length = request.body.len };
            var request_body = http_request.sendBodyUnflushed(&.{}) catch
                return error.Network;
            request_body.writer.writeAll(request.body) catch return error.Network;
            request_body.end() catch return error.Network;
            http_request.connection.?.flush() catch return error.Network;
        } else {
            if (request.body.len != 0) return error.InvalidResponse;
            http_request.sendBodiless() catch return error.Network;
        }
        var response = http_request.receiveHead(&.{}) catch return error.Network;
        if (response.head.content_encoding != .identity)
            return error.InvalidResponse;
        var header_writer = std.Io.Writer.fixed(header_buffer);
        var content_type: ?[]const u8 = null;
        var www_authenticate: ?[]const u8 = null;
        var iterator = response.head.iterateHeaders();
        while (iterator.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "Content-Type")) {
                if (content_type != null) return error.InvalidResponse;
                content_type = copyHeaderValue(&header_writer, header.value) catch
                    return error.ResponseTooLarge;
            } else if (www_authenticate == null and
                std.ascii.eqlIgnoreCase(header.name, "WWW-Authenticate"))
            {
                if (selectBearerChallenge(header.value)) |challenge|
                    www_authenticate = copyHeaderValue(&header_writer, challenge) catch
                        return error.ResponseTooLarge;
            }
        }
        var body_writer = std.Io.Writer.fixed(body_buffer);
        var transfer_buffer: [4096]u8 = undefined;
        const reader = response.reader(&transfer_buffer);
        _ = reader.streamRemaining(&body_writer) catch return error.ResponseTooLarge;
        return .{
            .status = @intFromEnum(response.head.status),
            .content_type = content_type,
            .www_authenticate = www_authenticate,
            .body = body_writer.buffered(),
        };
    }

    fn waitDeadline(io: std.Io, deadline: std.Io.Clock.Timestamp) void {
        deadline.wait(io) catch {};
    }

    fn waitCancellation(cancellation: *const Cancellation) void {
        cancellation.wait();
    }
};

pub const Error = FetchError || error{
    InvalidEndpoint,
    InvalidChallenge,
    InvalidMetadata,
    UnsupportedAuthorizationServer,
    InvalidAuthorizationRequest,
    InvalidRegistrationResponse,
    RegistrationRejected,
    RegistrationOutcomeUnknown,
    InvalidTokenResponse,
    InvalidGrant,
    TokenOutcomeUnknown,
    ExpiryOverflow,
};

pub const ResourceDiscovery = struct {
    arena: std.heap.ArenaAllocator,
    resource: []const u8,
    authorization_servers: []const []const u8,
    scopes_supported: []const []const u8,
    requested_scopes: []const []const u8,

    pub fn deinit(self: *ResourceDiscovery) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const TokenEndpointAuthMethod = enum {
    none,
    client_secret_basic,
    client_secret_post,

    pub fn wire(self: TokenEndpointAuthMethod) []const u8 {
        return switch (self) {
            .none => "none",
            .client_secret_basic => "client_secret_basic",
            .client_secret_post => "client_secret_post",
        };
    }

    pub fn fromWire(value: []const u8) ?TokenEndpointAuthMethod {
        if (std.mem.eql(u8, value, "none")) return .none;
        if (std.mem.eql(u8, value, "client_secret_basic"))
            return .client_secret_basic;
        if (std.mem.eql(u8, value, "client_secret_post"))
            return .client_secret_post;
        return null;
    }
};

pub const AuthorizationServer = struct {
    arena: std.heap.ArenaAllocator,
    issuer: []const u8,
    authorization_endpoint: []const u8,
    token_endpoint: []const u8,
    registration_endpoint: ?[]const u8,
    scopes_supported: []const []const u8,
    token_endpoint_auth_methods: []const TokenEndpointAuthMethod,
    refresh_token_supported: bool,
    authorization_response_issuer_required: bool,
    client_id_metadata_document_supported: bool,

    pub fn deinit(self: *AuthorizationServer) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn dynamicRegistrationAuthMethod(
        self: *const AuthorizationServer,
    ) ?TokenEndpointAuthMethod {
        if (containsAuthMethod(self.token_endpoint_auth_methods, .none))
            return .none;
        if (containsAuthMethod(self.token_endpoint_auth_methods, .client_secret_basic))
            return .client_secret_basic;
        if (containsAuthMethod(self.token_endpoint_auth_methods, .client_secret_post))
            return .client_secret_post;
        return null;
    }
};

pub const Secret = struct {
    allocator: std.mem.Allocator = undefined,
    bytes: []u8 = &.{},
    owned: bool = false,

    pub fn init(allocator: std.mem.Allocator, value: []const u8) !Secret {
        if (value.len == 0 or value.len > Limits.secret_bytes or
            !validSecretValue(value))
            return error.InvalidTokenResponse;
        return .{
            .allocator = allocator,
            .bytes = try allocator.dupe(u8, value),
            .owned = true,
        };
    }

    pub fn view(self: *const Secret) []const u8 {
        std.debug.assert(self.owned);
        return self.bytes;
    }

    pub fn take(self: *Secret) Secret {
        std.debug.assert(self.owned);
        const moved = self.*;
        self.* = .{};
        return moved;
    }

    pub fn deinit(self: *Secret) void {
        if (!self.owned) return;
        std.crypto.secureZero(u8, self.bytes);
        self.allocator.free(self.bytes);
        self.* = .{};
    }
};

fn validSecretValue(value: []const u8) bool {
    for (value) |byte|
        if ((byte < 0x20 and byte != '\t') or byte == 0x7f) return false;
    return true;
}

pub const Registration = struct {
    allocator: std.mem.Allocator,
    client_id: []u8,
    client_secret: ?Secret,
    token_endpoint_auth_method: TokenEndpointAuthMethod,

    pub fn deinit(self: *Registration) void {
        if (self.client_secret) |*secret| secret.deinit();
        std.crypto.secureZero(u8, self.client_id);
        self.allocator.free(self.client_id);
        self.* = undefined;
    }
};

pub const TokenSet = struct {
    access_token: Secret,
    refresh_token: ?Secret,
    expires_at_unix_ms: ?u64,

    pub fn deinit(self: *TokenSet) void {
        self.access_token.deinit();
        if (self.refresh_token) |*secret| secret.deinit();
        self.* = undefined;
    }
};

pub const AuthorizationCallback = struct {
    attempt_id: u64,
    callback: account_oauth.Callback,

    pub fn deinit(self: *AuthorizationCallback) void {
        self.callback.deinit();
        self.* = undefined;
    }
};

/// One authorization attempt owns one PKCE material set and one loopback
/// listener. Callers keep this value in stable memory, open the returned URL,
/// and must cancel/join any wait thread before deinit.
pub const AuthorizationAttempt = struct {
    attempt_id: u64 = 0,
    server: account_loopback.Server = undefined,
    material: account_oauth.AttemptMaterial = undefined,
    redirect_storage: [128]u8 = undefined,
    redirect_len: usize = 0,
    issuer_storage: [Limits.url_bytes]u8 = undefined,
    issuer_len: usize = 0,
    issuer_required: bool = false,
    authorization_url_storage: [account_oauth.Limits.authorization_url_bytes]u8 =
        undefined,
    authorization_url_len: usize = 0,
    active: bool = false,

    fn init(self: *AuthorizationAttempt, io: std.Io, attempt_id: u64) !void {
        if (self.active) return error.InvalidAuthorizationRequest;
        if (attempt_id == 0) return error.InvalidAuthorizationRequest;
        self.* = .{};
        self.attempt_id = attempt_id;
        account_oauth.AttemptMaterial.generate(io, &self.material) catch
            return error.InvalidAuthorizationRequest;
        errdefer self.material.deinit();
        self.server = account_loopback.Server.init(io) catch |err| return err;
        errdefer self.server.deinit();
        var writer = std.Io.Writer.fixed(&self.redirect_storage);
        account_oauth.writeRedirectUri(&writer, self.server.port()) catch
            return error.InvalidAuthorizationRequest;
        self.redirect_len = writer.buffered().len;
        self.active = true;
    }

    pub fn redirectUri(self: *const AuthorizationAttempt) []const u8 {
        std.debug.assert(self.active);
        return self.redirect_storage[0..self.redirect_len];
    }

    pub fn prepare(
        self: *AuthorizationAttempt,
        io: std.Io,
        attempt_id: u64,
        state: StatePort,
        server_id: []const u8,
        resource: *const ResourceDiscovery,
        server: *const AuthorizationServer,
    ) (Error || StateError || account_loopback.ServerError)!void {
        if (!containsText(resource.authorization_servers, server.issuer))
            return error.InvalidAuthorizationRequest;
        try self.init(io, attempt_id);
        errdefer self.deinit();
        const binding = try state.authorize(.{
            .attempt_id = attempt_id,
            .server_id = server_id,
            .issuer = server.issuer,
            .resource = resource.resource,
            .scopes = resource.requested_scopes,
            .redirect_uri = self.redirectUri(),
        });
        if (binding.attempt_id != attempt_id or
            !std.mem.eql(u8, binding.server_id, server_id) or
            !std.mem.eql(u8, binding.issuer, server.issuer) or
            !std.mem.eql(u8, binding.resource, resource.resource) or
            !stringSetsEqual(binding.scopes, resource.requested_scopes) or
            !std.mem.eql(u8, binding.redirect_uri, self.redirectUri()) or
            !validClientId(binding.client_id))
            return error.InvalidAuthorizationRequest;
        @memcpy(self.issuer_storage[0..binding.issuer.len], binding.issuer);
        self.issuer_len = binding.issuer.len;
        self.issuer_required = server.authorization_response_issuer_required;
        const url = try buildAuthorizationUrl(
            &self.authorization_url_storage,
            server,
            binding.client_id,
            binding.redirect_uri,
            binding.resource,
            binding.scopes,
            &self.material,
        );
        self.authorization_url_len = url.len;
    }

    pub fn authorizationUrl(self: *const AuthorizationAttempt) []const u8 {
        std.debug.assert(self.active and self.authorization_url_len != 0);
        return self.authorization_url_storage[0..self.authorization_url_len];
    }

    pub fn wait(
        self: *AuthorizationAttempt,
        allocator: std.mem.Allocator,
        deadline: std.Io.Clock.Timestamp,
    ) account_loopback.ServerError!AuthorizationCallback {
        std.debug.assert(self.active);
        return .{
            .attempt_id = self.attempt_id,
            .callback = try self.server.waitValidated(
                allocator,
                &self.material.state,
                .{
                    .expected_issuer = self.issuer_storage[0..self.issuer_len],
                    .issuer_required = self.issuer_required,
                },
                deadline,
            ),
        };
    }

    pub fn matches(self: *const AuthorizationAttempt, attempt_id: u64) bool {
        return self.active and self.attempt_id == attempt_id;
    }

    pub fn verifier(self: *const AuthorizationAttempt) []const u8 {
        std.debug.assert(self.active);
        return &self.material.verifier;
    }

    pub fn cancel(self: *AuthorizationAttempt) void {
        if (self.active) self.server.cancel();
    }

    pub fn deinit(self: *AuthorizationAttempt) void {
        if (!self.active) return;
        self.server.deinit();
        self.material.deinit();
        std.crypto.secureZero(u8, &self.redirect_storage);
        std.crypto.secureZero(u8, &self.issuer_storage);
        std.crypto.secureZero(u8, &self.authorization_url_storage);
        self.* = .{};
    }
};

const ResourceMetadata = struct {
    resource: []const u8,
    authorization_servers: []const []const u8,
    scopes_supported: []const []const u8 = &.{},
};

const AuthorizationMetadata = struct {
    issuer: []const u8,
    authorization_endpoint: []const u8,
    token_endpoint: []const u8,
    registration_endpoint: ?[]const u8 = null,
    scopes_supported: []const []const u8 = &.{},
    response_types_supported: []const []const u8 = &.{},
    grant_types_supported: []const []const u8 = &.{"authorization_code"},
    code_challenge_methods_supported: []const []const u8 = &.{},
    token_endpoint_auth_methods_supported: []const []const u8 = &.{"client_secret_basic"},
    authorization_response_iss_parameter_supported: bool = false,
    client_id_metadata_document_supported: bool = false,
};

const RegistrationResponse = struct {
    client_id: []const u8,
    client_secret: ?[]const u8 = null,
    client_secret_expires_at: ?u64 = null,
    redirect_uris: []const []const u8 = &.{},
    grant_types: []const []const u8 = &.{},
    response_types: []const []const u8 = &.{},
    token_endpoint_auth_method: ?[]const u8 = null,
};

const TokenResponse = struct {
    access_token: []const u8,
    refresh_token: ?[]const u8 = null,
    token_type: []const u8,
    expires_in: ?u64 = null,
};

const OAuthErrorResponse = struct {
    @"error": []const u8,
};

const Challenge = struct {
    resource_metadata: ?[]const u8 = null,
    scope: ?[]const u8 = null,
};

pub fn discoverResourceEffect(
    allocator: std.mem.Allocator,
    transport: Transport,
    endpoint: []const u8,
) (Error || std.mem.Allocator.Error)!ResourceDiscovery {
    if (!validHttpsUrl(endpoint)) return error.InvalidEndpoint;
    var body_buffer: [Limits.metadata_body_bytes]u8 = undefined;
    var header_buffer: [Limits.header_bytes]u8 = undefined;
    var challenge: ?Challenge = null;
    const probe = transport.fetch(
        .{ .method = .get, .url = endpoint, .headers = &.{.{
            .name = "Accept",
            .value = "application/json",
        }} },
        &body_buffer,
        &header_buffer,
    ) catch |err| switch (err) {
        error.CancelledBeforeSend => return error.Cancelled,
        error.Cancelled => return error.Cancelled,
        error.DeadlineExceeded => return error.DeadlineExceeded,
        error.Network, error.ResponseTooLarge, error.InvalidResponse => null,
    };
    if (probe) |response| if (response.status == 401) {
        if (response.www_authenticate) |header|
            challenge = parseBearerChallenge(header) catch
                return error.InvalidChallenge;
    };

    if (challenge) |value| if (value.resource_metadata) |metadata_url| {
        if (!validHttpsUrl(metadata_url)) return error.InvalidChallenge;
        return fetchResourceMetadata(
            allocator,
            transport,
            endpoint,
            metadata_url,
            value.scope,
        );
    };

    var path_storage: [Limits.url_bytes]u8 = undefined;
    const path_url = try protectedResourceMetadataUrl(&path_storage, endpoint, true);
    if (fetchResourceMetadata(
        allocator,
        transport,
        endpoint,
        path_url,
        if (challenge) |value| value.scope else null,
    )) |result| return result else |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.CancelledBeforeSend => return error.Cancelled,
        error.Cancelled => return error.Cancelled,
        error.DeadlineExceeded => return error.DeadlineExceeded,
        else => {},
    }

    var root_storage: [Limits.url_bytes]u8 = undefined;
    const root_url = try protectedResourceMetadataUrl(&root_storage, endpoint, false);
    return fetchResourceMetadata(
        allocator,
        transport,
        endpoint,
        root_url,
        if (challenge) |value| value.scope else null,
    );
}

fn fetchResourceMetadata(
    allocator: std.mem.Allocator,
    transport: Transport,
    endpoint: []const u8,
    metadata_url: []const u8,
    challenge_scope: ?[]const u8,
) (Error || std.mem.Allocator.Error)!ResourceDiscovery {
    var body_buffer: [Limits.metadata_body_bytes]u8 = undefined;
    var header_buffer: [Limits.header_bytes]u8 = undefined;
    const response = try transport.fetch(
        .{ .method = .get, .url = metadata_url, .headers = &.{.{
            .name = "Accept",
            .value = "application/json",
        }} },
        &body_buffer,
        &header_buffer,
    );
    if (response.status != 200 or !jsonContentType(response.content_type) or
        response.body.len == 0 or response.body.len > Limits.metadata_body_bytes)
        return error.InvalidMetadata;
    var parsed = std.json.parseFromSlice(
        ResourceMetadata,
        allocator,
        response.body,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    ) catch return error.InvalidMetadata;
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.resource, endpoint) or
        parsed.value.authorization_servers.len == 0 or
        parsed.value.authorization_servers.len > Limits.issuers)
        return error.InvalidMetadata;
    for (parsed.value.authorization_servers, 0..) |issuer, index| {
        if (!validHttpsIssuer(issuer)) return error.InvalidMetadata;
        for (parsed.value.authorization_servers[0..index]) |previous|
            if (std.mem.eql(u8, previous, issuer)) return error.InvalidMetadata;
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const owned = arena.allocator();
    const owned_resource = try owned.dupe(u8, endpoint);
    const owned_issuers = try cloneStrings(
        owned,
        parsed.value.authorization_servers,
        Limits.issuers,
        Limits.url_bytes,
    );
    const scopes_supported = try cloneSortedScopes(
        owned,
        parsed.value.scopes_supported,
    );
    const requested_scopes = if (challenge_scope) |scope|
        try parseScopeSet(owned, scope)
    else
        &.{};
    return .{
        .arena = arena,
        .resource = owned_resource,
        .authorization_servers = owned_issuers,
        .scopes_supported = scopes_supported,
        .requested_scopes = requested_scopes,
    };
}

pub fn discoverAuthorizationServer(
    allocator: std.mem.Allocator,
    transport: Transport,
    resource: *const ResourceDiscovery,
    selected_issuer: []const u8,
) (Error || std.mem.Allocator.Error)!AuthorizationServer {
    if (!containsText(resource.authorization_servers, selected_issuer))
        return error.UnsupportedAuthorizationServer;
    var storage: [3][Limits.url_bytes]u8 = undefined;
    var candidates: [3][]const u8 = undefined;
    const count = try authorizationMetadataUrls(&storage, &candidates, selected_issuer);
    var last_error: Error = error.InvalidMetadata;
    for (candidates[0..count]) |url| {
        const result = fetchAuthorizationMetadata(
            allocator,
            transport,
            selected_issuer,
            url,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.CancelledBeforeSend => return error.Cancelled,
            error.Cancelled => return error.Cancelled,
            error.DeadlineExceeded => return error.DeadlineExceeded,
            else => {
                last_error = @errorCast(err);
                continue;
            },
        };
        return result;
    }
    return last_error;
}

fn fetchAuthorizationMetadata(
    allocator: std.mem.Allocator,
    transport: Transport,
    selected_issuer: []const u8,
    metadata_url: []const u8,
) (Error || std.mem.Allocator.Error)!AuthorizationServer {
    var body_buffer: [Limits.metadata_body_bytes]u8 = undefined;
    var header_buffer: [Limits.header_bytes]u8 = undefined;
    const response = try transport.fetch(
        .{ .method = .get, .url = metadata_url, .headers = &.{.{
            .name = "Accept",
            .value = "application/json",
        }} },
        &body_buffer,
        &header_buffer,
    );
    if (response.status != 200 or !jsonContentType(response.content_type) or
        response.body.len == 0 or response.body.len > Limits.metadata_body_bytes)
        return error.InvalidMetadata;
    var parsed = std.json.parseFromSlice(
        AuthorizationMetadata,
        allocator,
        response.body,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    ) catch return error.InvalidMetadata;
    defer parsed.deinit();
    const metadata = parsed.value;
    if (!std.mem.eql(u8, metadata.issuer, selected_issuer) or
        !validHttpsUrl(metadata.authorization_endpoint) or
        !validHttpsUrl(metadata.token_endpoint) or
        !containsText(metadata.response_types_supported, "code") or
        !containsText(metadata.grant_types_supported, "authorization_code") or
        !containsText(metadata.code_challenge_methods_supported, "S256") or
        metadata.scopes_supported.len > Limits.scopes)
        return error.InvalidMetadata;
    if (metadata.registration_endpoint) |url|
        if (!validHttpsUrl(url)) return error.InvalidMetadata;
    const methods = try parseAuthMethods(allocator, metadata.token_endpoint_auth_methods_supported);
    defer allocator.free(methods);
    if (methods.len == 0) return error.UnsupportedAuthorizationServer;

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const owned = arena.allocator();
    const issuer = try owned.dupe(u8, metadata.issuer);
    const authorization_endpoint = try owned.dupe(u8, metadata.authorization_endpoint);
    const token_endpoint = try owned.dupe(u8, metadata.token_endpoint);
    const registration_endpoint = if (metadata.registration_endpoint) |url|
        try owned.dupe(u8, url)
    else
        null;
    const scopes_supported = try cloneSortedScopes(owned, metadata.scopes_supported);
    const token_endpoint_auth_methods = try owned.dupe(TokenEndpointAuthMethod, methods);
    return .{
        .arena = arena,
        .issuer = issuer,
        .authorization_endpoint = authorization_endpoint,
        .token_endpoint = token_endpoint,
        .registration_endpoint = registration_endpoint,
        .scopes_supported = scopes_supported,
        .token_endpoint_auth_methods = token_endpoint_auth_methods,
        .refresh_token_supported = containsText(
            metadata.grant_types_supported,
            "refresh_token",
        ),
        .authorization_response_issuer_required = metadata.authorization_response_iss_parameter_supported,
        .client_id_metadata_document_supported = metadata.client_id_metadata_document_supported,
    };
}

pub fn buildAuthorizationUrl(
    output: []u8,
    server: *const AuthorizationServer,
    client_id: []const u8,
    redirect_uri: []const u8,
    resource: []const u8,
    scopes: []const []const u8,
    material: *const account_oauth.AttemptMaterial,
) Error![]const u8 {
    if (!validClientId(client_id) or !validLoopbackRedirect(redirect_uri) or
        !validHttpsUrl(resource) or scopes.len > Limits.scopes)
        return error.InvalidAuthorizationRequest;
    var scope_storage: [Limits.scopes * (Limits.scope_bytes + 1)]u8 = undefined;
    const scope = joinScopes(&scope_storage, scopes) catch
        return error.InvalidAuthorizationRequest;
    var writer = std.Io.Writer.fixed(output);
    writer.writeAll(server.authorization_endpoint) catch
        return error.InvalidAuthorizationRequest;
    writer.writeByte(if (std.mem.indexOfScalar(
        u8,
        server.authorization_endpoint,
        '?',
    ) == null) '?' else '&') catch return error.InvalidAuthorizationRequest;
    writeFormPairs(&writer, &.{
        .{ "response_type", "code" },
        .{ "client_id", client_id },
        .{ "redirect_uri", redirect_uri },
    }) catch return error.InvalidAuthorizationRequest;
    if (scope.len != 0) {
        writer.writeByte('&') catch return error.InvalidAuthorizationRequest;
        writePair(&writer, "scope", scope) catch return error.InvalidAuthorizationRequest;
    }
    writer.writeByte('&') catch return error.InvalidAuthorizationRequest;
    writeFormPairs(&writer, &.{
        .{ "state", &material.state },
        .{ "code_challenge", &material.challenge },
        .{ "code_challenge_method", "S256" },
        .{ "resource", resource },
    }) catch return error.InvalidAuthorizationRequest;
    if (writer.buffered().len > account_oauth.Limits.authorization_url_bytes)
        return error.InvalidAuthorizationRequest;
    return writer.buffered();
}

pub const OperationHandle = struct {
    id: []const u8,
    server_id: []const u8,
};

pub const ApprovedEndpoint = struct {
    server_id: []const u8,
    url: []const u8,
};

pub const DynamicRegistrationPlan = struct {
    server_id: []const u8,
    resource: []const u8,
    issuer: []const u8,
    scopes: []const []const u8,
    redirect_uri: []const u8,
};

pub const AuthorizationPlan = struct {
    attempt_id: u64,
    server_id: []const u8,
    issuer: []const u8,
    resource: []const u8,
    scopes: []const []const u8,
    redirect_uri: []const u8,
};

pub const AuthorizationBinding = struct {
    attempt_id: u64,
    server_id: []const u8,
    issuer: []const u8,
    resource: []const u8,
    scopes: []const []const u8,
    redirect_uri: []const u8,
    client_id: []const u8,
};

pub const CodeExchangeOperation = struct {
    operation: OperationHandle,
    issuer: []const u8,
    client_id: []const u8,
    token_endpoint_auth_method: TokenEndpointAuthMethod,
    resource: []const u8,
    redirect_uri: []const u8,
};

pub const StateError = error{
    StateRejected,
    StatePersistenceFailed,
    StateOutcomeUnknown,
};

/// Narrow Workbench seam used by Application OAuth flows. `begin_*` must
/// durably commit the operation marker (and any reduced Admission candidate)
/// before returning. `complete_*` must consume the remote result into fresh
/// credential locators. `uncertain` must converge the bound server to
/// reauth_required without replaying the operation.
pub const StatePort = struct {
    context: *anyopaque,
    approved_endpoint_fn: *const fn (
        *anyopaque,
        []const u8,
    ) StateError!ApprovedEndpoint,
    authorize_fn: *const fn (
        *anyopaque,
        AuthorizationPlan,
    ) StateError!AuthorizationBinding,
    begin_dynamic_registration_fn: *const fn (
        *anyopaque,
        DynamicRegistrationPlan,
    ) StateError!OperationHandle,
    complete_dynamic_registration_fn: *const fn (
        *anyopaque,
        OperationHandle,
        *Registration,
    ) StateError!void,
    begin_code_exchange_fn: *const fn (
        *anyopaque,
        []const u8,
    ) StateError!CodeExchangeOperation,
    complete_code_exchange_fn: *const fn (
        *anyopaque,
        OperationHandle,
        *TokenSet,
    ) StateError!void,
    clear_fn: *const fn (*anyopaque, OperationHandle) StateError!void,
    uncertain_fn: *const fn (*anyopaque, OperationHandle) StateError!void,

    fn approvedEndpoint(
        self: StatePort,
        server_id: []const u8,
    ) StateError!ApprovedEndpoint {
        return self.approved_endpoint_fn(self.context, server_id);
    }

    fn authorize(
        self: StatePort,
        plan: AuthorizationPlan,
    ) StateError!AuthorizationBinding {
        return self.authorize_fn(self.context, plan);
    }

    fn beginDynamicRegistration(
        self: StatePort,
        plan: DynamicRegistrationPlan,
    ) StateError!OperationHandle {
        return self.begin_dynamic_registration_fn(self.context, plan);
    }

    fn completeDynamicRegistration(
        self: StatePort,
        operation: OperationHandle,
        registration: *Registration,
    ) StateError!void {
        return self.complete_dynamic_registration_fn(
            self.context,
            operation,
            registration,
        );
    }

    fn beginCodeExchange(
        self: StatePort,
        server_id: []const u8,
    ) StateError!CodeExchangeOperation {
        return self.begin_code_exchange_fn(self.context, server_id);
    }

    fn completeCodeExchange(
        self: StatePort,
        operation: OperationHandle,
        tokens: *TokenSet,
    ) StateError!void {
        return self.complete_code_exchange_fn(self.context, operation, tokens);
    }

    fn clear(self: StatePort, operation: OperationHandle) StateError!void {
        return self.clear_fn(self.context, operation);
    }

    fn uncertain(self: StatePort, operation: OperationHandle) StateError!void {
        return self.uncertain_fn(self.context, operation);
    }
};

pub fn discoverApprovedResource(
    allocator: std.mem.Allocator,
    state: StatePort,
    transport: Transport,
    server_id: []const u8,
) (Error || StateError || std.mem.Allocator.Error)!ResourceDiscovery {
    const approved = try state.approvedEndpoint(server_id);
    if (!std.mem.eql(u8, approved.server_id, server_id) or
        !validHttpsUrl(approved.url))
        return error.InvalidEndpoint;
    return discoverResourceEffect(allocator, transport, approved.url);
}

pub const FlowOutcome = enum {
    completed,
    rejected,
    cancelled_before_send,
    invalid_grant,
    outcome_unknown,
};

pub fn performDynamicRegistration(
    allocator: std.mem.Allocator,
    state: StatePort,
    transport: Transport,
    resource: *const ResourceDiscovery,
    server: *const AuthorizationServer,
    plan: DynamicRegistrationPlan,
) (Error || StateError || std.mem.Allocator.Error)!FlowOutcome {
    if (!std.mem.eql(u8, plan.resource, resource.resource) or
        !std.mem.eql(u8, plan.issuer, server.issuer) or
        !containsText(resource.authorization_servers, plan.issuer) or
        !stringSetsEqual(plan.scopes, resource.requested_scopes))
        return error.InvalidAuthorizationRequest;
    const operation = try state.beginDynamicRegistration(plan);
    var registration = registerDynamicClientEffect(
        allocator,
        transport,
        server,
        plan.redirect_uri,
    ) catch |err| switch (err) {
        error.RegistrationRejected => {
            try state.clear(operation);
            return .rejected;
        },
        error.CancelledBeforeSend => {
            try state.clear(operation);
            return .cancelled_before_send;
        },
        error.RegistrationOutcomeUnknown => {
            try state.uncertain(operation);
            return .outcome_unknown;
        },
        else => {
            try state.clear(operation);
            return err;
        },
    };
    defer registration.deinit();
    state.completeDynamicRegistration(operation, &registration) catch {
        try state.uncertain(operation);
        return .outcome_unknown;
    };
    return .completed;
}

pub fn performCodeExchange(
    allocator: std.mem.Allocator,
    state: StatePort,
    transport: Transport,
    server_id: []const u8,
    server: *const AuthorizationServer,
    client_secret: ?[]const u8,
    code: *const account_oauth.Secret,
    verifier: []const u8,
    now_unix_ms: u64,
) (Error || StateError || std.mem.Allocator.Error)!FlowOutcome {
    const binding = try state.beginCodeExchange(server_id);
    if (!std.mem.eql(u8, binding.operation.server_id, server_id) or
        !std.mem.eql(u8, binding.issuer, server.issuer))
    {
        try state.clear(binding.operation);
        return error.InvalidAuthorizationRequest;
    }
    var tokens = exchangeAuthorizationCodeEffect(
        allocator,
        transport,
        server,
        binding.client_id,
        client_secret,
        binding.token_endpoint_auth_method,
        code,
        verifier,
        binding.redirect_uri,
        binding.resource,
        now_unix_ms,
    ) catch |err| switch (err) {
        error.InvalidGrant => {
            try state.uncertain(binding.operation);
            return .invalid_grant;
        },
        error.CancelledBeforeSend => {
            try state.clear(binding.operation);
            return .cancelled_before_send;
        },
        error.TokenOutcomeUnknown => {
            try state.uncertain(binding.operation);
            return .outcome_unknown;
        },
        else => {
            try state.clear(binding.operation);
            return err;
        },
    };
    defer tokens.deinit();
    state.completeCodeExchange(binding.operation, &tokens) catch {
        try state.uncertain(binding.operation);
        return .outcome_unknown;
    };
    return .completed;
}

fn registerDynamicClientEffect(
    allocator: std.mem.Allocator,
    transport: Transport,
    server: *const AuthorizationServer,
    redirect_uri: []const u8,
) (Error || std.mem.Allocator.Error)!Registration {
    const endpoint = server.registration_endpoint orelse
        return error.UnsupportedAuthorizationServer;
    if (!validLoopbackRedirect(redirect_uri)) return error.InvalidAuthorizationRequest;
    const requested_method = server.dynamicRegistrationAuthMethod() orelse
        return error.UnsupportedAuthorizationServer;
    var request_storage: [Limits.request_body_bytes]u8 = undefined;
    var writer = std.Io.Writer.fixed(&request_storage);
    const grant_types: []const []const u8 = if (server.refresh_token_supported)
        &.{ "authorization_code", "refresh_token" }
    else
        &.{"authorization_code"};
    std.json.Stringify.value(.{
        .client_name = "MetaWork",
        .redirect_uris = &.{redirect_uri},
        .grant_types = grant_types,
        .response_types = &.{"code"},
        .token_endpoint_auth_method = requested_method.wire(),
        .application_type = "native",
    }, .{}, &writer) catch return error.InvalidAuthorizationRequest;
    var body_buffer: [Limits.registration_body_bytes]u8 = undefined;
    var header_buffer: [Limits.header_bytes]u8 = undefined;
    const response = transport.fetch(.{
        .method = .post,
        .url = endpoint,
        .headers = &.{
            .{ .name = "Accept", .value = "application/json" },
            .{ .name = "Content-Type", .value = "application/json" },
        },
        .body = writer.buffered(),
    }, &body_buffer, &header_buffer) catch |err| switch (err) {
        error.CancelledBeforeSend => return error.CancelledBeforeSend,
        else => return error.RegistrationOutcomeUnknown,
    };
    if (response.status == 400 and jsonContentType(response.content_type) and
        registrationErrorProvesNoClient(response.body))
        return error.RegistrationRejected;
    if (response.status != 200 and response.status != 201)
        return error.RegistrationOutcomeUnknown;
    if (!jsonContentType(response.content_type) or response.body.len == 0 or
        response.body.len > Limits.registration_body_bytes)
        return error.RegistrationOutcomeUnknown;
    return parseRegistrationResponse(
        allocator,
        response.body,
        redirect_uri,
        requested_method,
        server.refresh_token_supported,
    ) catch return error.RegistrationOutcomeUnknown;
}

fn parseRegistrationResponse(
    allocator: std.mem.Allocator,
    body: []const u8,
    redirect_uri: []const u8,
    requested_method: TokenEndpointAuthMethod,
    refresh_token_requested: bool,
) (Error || std.mem.Allocator.Error)!Registration {
    var parsed = std.json.parseFromSlice(
        RegistrationResponse,
        allocator,
        body,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    ) catch return error.InvalidRegistrationResponse;
    defer parsed.deinit();
    const value = parsed.value;
    if (!validClientId(value.client_id) or
        (value.client_secret_expires_at != null and
            value.client_secret_expires_at.? != 0) or
        (value.redirect_uris.len != 0 and
            !containsText(value.redirect_uris, redirect_uri)) or
        (value.grant_types.len != 0 and
            !containsText(value.grant_types, "authorization_code")) or
        (refresh_token_requested and value.grant_types.len != 0 and
            !containsText(value.grant_types, "refresh_token")) or
        (value.response_types.len != 0 and
            !containsText(value.response_types, "code")))
        return error.InvalidRegistrationResponse;
    const method = if (value.token_endpoint_auth_method) |wire|
        parseAuthMethod(wire) orelse return error.InvalidRegistrationResponse
    else
        requested_method;
    if (method != requested_method or
        ((method == .none) != (value.client_secret == null)))
        return error.InvalidRegistrationResponse;
    var result: Registration = .{
        .allocator = allocator,
        .client_id = try allocator.dupe(u8, value.client_id),
        .client_secret = null,
        .token_endpoint_auth_method = method,
    };
    errdefer {
        std.crypto.secureZero(u8, result.client_id);
        allocator.free(result.client_id);
    }
    if (value.client_secret) |secret|
        result.client_secret = Secret.init(allocator, secret) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidRegistrationResponse,
        };
    return result;
}

fn exchangeAuthorizationCodeEffect(
    allocator: std.mem.Allocator,
    transport: Transport,
    server: *const AuthorizationServer,
    client_id: []const u8,
    client_secret: ?[]const u8,
    auth_method: TokenEndpointAuthMethod,
    code: *const account_oauth.Secret,
    verifier: []const u8,
    redirect_uri: []const u8,
    resource: []const u8,
    now_unix_ms: u64,
) (Error || std.mem.Allocator.Error)!TokenSet {
    if (!validClientId(client_id) or !validLoopbackRedirect(redirect_uri) or
        !validHttpsUrl(resource) or verifier.len != account_oauth.Limits.verifier_bytes or
        ((auth_method == .none) != (client_secret == null)) or
        !containsAuthMethod(server.token_endpoint_auth_methods, auth_method))
        return error.InvalidAuthorizationRequest;
    var request_storage: [Limits.request_body_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &request_storage);
    var writer = std.Io.Writer.fixed(&request_storage);
    writeFormPairs(&writer, &.{
        .{ "grant_type", "authorization_code" },
        .{ "client_id", client_id },
        .{ "code", code.view() },
        .{ "code_verifier", verifier },
        .{ "redirect_uri", redirect_uri },
        .{ "resource", resource },
    }) catch return error.InvalidAuthorizationRequest;
    if (auth_method == .client_secret_post) {
        writer.writeByte('&') catch return error.InvalidAuthorizationRequest;
        writePair(&writer, "client_secret", client_secret.?) catch
            return error.InvalidAuthorizationRequest;
    }
    // form-encoding can triple both components before base64 expands the
    // result by 4/3, so four bytes per input byte is the actual upper bound.
    var basic_storage: [4 * (Limits.client_id_bytes + Limits.secret_bytes) + 16]u8 =
        undefined;
    defer std.crypto.secureZero(u8, &basic_storage);
    var headers: [3]Header = .{
        .{ .name = "Accept", .value = "application/json" },
        .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
        .{ .name = "Authorization", .value = "" },
    };
    const header_count: usize = if (auth_method == .client_secret_basic) basic: {
        headers[2].value = buildBasicAuthorization(
            &basic_storage,
            client_id,
            client_secret.?,
        ) catch return error.InvalidAuthorizationRequest;
        break :basic 3;
    } else 2;
    var body_buffer: [Limits.token_body_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &body_buffer);
    var header_buffer: [Limits.header_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &header_buffer);
    const response = transport.fetch(.{
        .method = .post,
        .url = server.token_endpoint,
        .headers = headers[0..header_count],
        .body = writer.buffered(),
    }, &body_buffer, &header_buffer) catch |err| switch (err) {
        error.CancelledBeforeSend => return error.CancelledBeforeSend,
        else => return error.TokenOutcomeUnknown,
    };
    if (response.status == 400 and oauthErrorIs(response.body, "invalid_grant"))
        return error.InvalidGrant;
    if (response.status != 200 or !jsonContentType(response.content_type) or
        response.body.len == 0 or response.body.len > Limits.token_body_bytes)
        return error.TokenOutcomeUnknown;
    return parseTokenResponse(allocator, response.body, now_unix_ms) catch
        return error.TokenOutcomeUnknown;
}

pub const DurableRefreshRequest = struct {
    issuer: []const u8,
    client_id: []const u8,
    token_endpoint_auth_method: TokenEndpointAuthMethod,
    resource: []const u8,
    consent_epoch: u64,
    token_revision: u64,
};

/// Executes only the remote refresh effect for a binding returned after the
/// Workbench marker/reduced-authority commit. It never retries. A cancellation
/// or transport failure after the POST is admitted is outcome-unknown.
pub fn refreshAccessTokenEffect(
    allocator: std.mem.Allocator,
    transport: Transport,
    server: *const AuthorizationServer,
    request: DurableRefreshRequest,
    client_secret: ?[]const u8,
    refresh_token: []const u8,
    now_unix_ms: u64,
) (Error || std.mem.Allocator.Error)!TokenSet {
    if (!std.mem.eql(u8, request.issuer, server.issuer) or
        !validClientId(request.client_id) or
        !validHttpsUrl(request.resource) or
        request.consent_epoch == 0 or request.token_revision == 0 or
        refresh_token.len == 0 or refresh_token.len > Limits.secret_bytes or
        ((request.token_endpoint_auth_method == .none) != (client_secret == null)) or
        !containsAuthMethod(
            server.token_endpoint_auth_methods,
            request.token_endpoint_auth_method,
        ))
        return error.InvalidAuthorizationRequest;
    var request_storage: [Limits.request_body_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &request_storage);
    var writer = std.Io.Writer.fixed(&request_storage);
    writeFormPairs(&writer, &.{
        .{ "grant_type", "refresh_token" },
        .{ "client_id", request.client_id },
        .{ "refresh_token", refresh_token },
        .{ "resource", request.resource },
    }) catch return error.InvalidAuthorizationRequest;
    if (request.token_endpoint_auth_method == .client_secret_post) {
        writer.writeByte('&') catch return error.InvalidAuthorizationRequest;
        writePair(&writer, "client_secret", client_secret.?) catch
            return error.InvalidAuthorizationRequest;
    }
    var basic_storage: [4 * (Limits.client_id_bytes + Limits.secret_bytes) + 16]u8 =
        undefined;
    defer std.crypto.secureZero(u8, &basic_storage);
    var headers: [3]Header = .{
        .{ .name = "Accept", .value = "application/json" },
        .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
        .{ .name = "Authorization", .value = "" },
    };
    const header_count: usize = if (request.token_endpoint_auth_method == .client_secret_basic) basic: {
        headers[2].value = buildBasicAuthorization(
            &basic_storage,
            request.client_id,
            client_secret.?,
        ) catch return error.InvalidAuthorizationRequest;
        break :basic 3;
    } else 2;
    var body_buffer: [Limits.token_body_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &body_buffer);
    var header_buffer: [Limits.header_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &header_buffer);
    const response = transport.fetch(.{
        .method = .post,
        .url = server.token_endpoint,
        .headers = headers[0..header_count],
        .body = writer.buffered(),
    }, &body_buffer, &header_buffer) catch |err| switch (err) {
        error.CancelledBeforeSend => return error.CancelledBeforeSend,
        else => return error.TokenOutcomeUnknown,
    };
    if (response.status == 400 and oauthErrorIs(response.body, "invalid_grant"))
        return error.InvalidGrant;
    if (response.status != 200 or !jsonContentType(response.content_type) or
        response.body.len == 0 or response.body.len > Limits.token_body_bytes)
        return error.TokenOutcomeUnknown;
    return parseTokenResponse(allocator, response.body, now_unix_ms) catch
        return error.TokenOutcomeUnknown;
}

fn parseTokenResponse(
    allocator: std.mem.Allocator,
    body: []const u8,
    now_unix_ms: u64,
) (Error || std.mem.Allocator.Error)!TokenSet {
    var parsed = std.json.parseFromSlice(
        TokenResponse,
        allocator,
        body,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    ) catch return error.InvalidTokenResponse;
    defer parsed.deinit();
    const value = parsed.value;
    if (!std.ascii.eqlIgnoreCase(value.token_type, "Bearer"))
        return error.InvalidTokenResponse;
    var result: TokenSet = .{
        .access_token = Secret.init(allocator, value.access_token) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidTokenResponse,
        },
        .refresh_token = null,
        .expires_at_unix_ms = null,
    };
    errdefer result.access_token.deinit();
    if (value.refresh_token) |secret|
        result.refresh_token = Secret.init(allocator, secret) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidTokenResponse,
        };
    errdefer if (result.refresh_token) |*secret| secret.deinit();
    if (value.expires_in) |seconds| {
        if (seconds == 0) return error.InvalidTokenResponse;
        const duration = std.math.mul(u64, seconds, 1000) catch
            return error.ExpiryOverflow;
        result.expires_at_unix_ms = std.math.add(u64, now_unix_ms, duration) catch
            return error.ExpiryOverflow;
    }
    return result;
}

fn oauthErrorIs(body: []const u8, expected: []const u8) bool {
    if (body.len == 0 or body.len > Limits.token_body_bytes) return false;
    var scratch: [Limits.token_body_bytes * 2]u8 = undefined;
    defer std.crypto.secureZero(u8, &scratch);
    var fixed = std.heap.FixedBufferAllocator.init(&scratch);
    var parsed = std.json.parseFromSlice(
        OAuthErrorResponse,
        fixed.allocator(),
        body,
        .{ .ignore_unknown_fields = true },
    ) catch return false;
    defer parsed.deinit();
    return std.mem.eql(u8, parsed.value.@"error", expected);
}

fn registrationErrorProvesNoClient(body: []const u8) bool {
    if (body.len == 0 or body.len > Limits.registration_body_bytes) return false;
    var scratch: [Limits.registration_body_bytes * 2]u8 = undefined;
    defer std.crypto.secureZero(u8, &scratch);
    var fixed = std.heap.FixedBufferAllocator.init(&scratch);
    var parsed = std.json.parseFromSlice(
        OAuthErrorResponse,
        fixed.allocator(),
        body,
        .{ .ignore_unknown_fields = true },
    ) catch return false;
    defer parsed.deinit();
    return containsText(&.{
        "invalid_redirect_uri",
        "invalid_client_metadata",
        "invalid_software_statement",
        "unapproved_software_statement",
    }, parsed.value.@"error");
}

fn parseBearerChallenge(input: []const u8) error{InvalidChallenge}!Challenge {
    if (input.len == 0 or input.len > Limits.header_bytes)
        return error.InvalidChallenge;
    var cursor = std.mem.trim(u8, input, " \t");
    if (cursor.len < 6 or !std.ascii.eqlIgnoreCase(cursor[0..6], "Bearer"))
        return error.InvalidChallenge;
    cursor = std.mem.trimStart(u8, cursor[6..], " \t");
    var result: Challenge = .{};
    while (cursor.len != 0) {
        const equals = std.mem.indexOfScalar(u8, cursor, '=') orelse
            return error.InvalidChallenge;
        const name = std.mem.trim(u8, cursor[0..equals], " \t");
        cursor = cursor[equals + 1 ..];
        if (cursor.len == 0 or cursor[0] != '"') return error.InvalidChallenge;
        const relative_end = std.mem.indexOfScalar(u8, cursor[1..], '"') orelse
            return error.InvalidChallenge;
        const end = relative_end + 1;
        const value = cursor[1..end];
        if (std.mem.indexOfScalar(u8, value, '\\') != null)
            return error.InvalidChallenge;
        if (std.ascii.eqlIgnoreCase(name, "resource_metadata")) {
            if (result.resource_metadata != null) return error.InvalidChallenge;
            result.resource_metadata = value;
        } else if (std.ascii.eqlIgnoreCase(name, "scope")) {
            if (result.scope != null) return error.InvalidChallenge;
            result.scope = value;
        }
        cursor = std.mem.trimStart(u8, cursor[end + 1 ..], " \t");
        if (cursor.len == 0) break;
        if (cursor[0] != ',') return error.InvalidChallenge;
        cursor = std.mem.trimStart(u8, cursor[1..], " \t");
    }
    return result;
}

fn copyHeaderValue(
    writer: *std.Io.Writer,
    value: []const u8,
) error{WriteFailed}![]const u8 {
    const start = writer.buffered().len;
    try writer.writeAll(value);
    const end = writer.buffered().len;
    return writer.buffered()[start..end];
}

/// Selects a Bearer challenge from one possibly combined WWW-Authenticate
/// field without confusing comma-separated Bearer auth-params with the start
/// of the next scheme.
fn selectBearerChallenge(value: []const u8) ?[]const u8 {
    var search: usize = 0;
    while (search < value.len) {
        while (search < value.len and
            (value[search] == ' ' or value[search] == '\t' or value[search] == ','))
            search += 1;
        const start = search;
        while (search < value.len and std.ascii.isAlphanumeric(value[search]))
            search += 1;
        if (search == start) return null;
        const scheme = value[start..search];
        if (std.ascii.eqlIgnoreCase(scheme, "Bearer")) {
            var end = value.len;
            var comma = search;
            while (std.mem.indexOfScalarPos(u8, value, comma, ',')) |found| {
                var candidate = found + 1;
                while (candidate < value.len and
                    (value[candidate] == ' ' or value[candidate] == '\t'))
                    candidate += 1;
                var token_end = candidate;
                while (token_end < value.len and
                    std.ascii.isAlphanumeric(value[token_end]))
                    token_end += 1;
                var after_token = token_end;
                while (after_token < value.len and
                    (value[after_token] == ' ' or value[after_token] == '\t'))
                    after_token += 1;
                if (token_end > candidate and after_token > token_end and
                    (after_token >= value.len or value[after_token] != '='))
                {
                    end = found;
                    break;
                }
                comma = found + 1;
            }
            return std.mem.trim(u8, value[start..end], " \t");
        }
        const comma = std.mem.indexOfScalarPos(u8, value, search, ',') orelse
            return null;
        search = comma + 1;
    }
    return null;
}

fn protectedResourceMetadataUrl(
    output: []u8,
    resource: []const u8,
    include_path: bool,
) Error![]const u8 {
    const parts = urlParts(resource) orelse return error.InvalidEndpoint;
    var writer = std.Io.Writer.fixed(output);
    writer.writeAll(resource[0..parts.origin_end]) catch return error.InvalidEndpoint;
    writer.writeAll("/.well-known/oauth-protected-resource") catch
        return error.InvalidEndpoint;
    if (include_path and parts.path.len != 0 and !std.mem.eql(u8, parts.path, "/"))
        writer.writeAll(parts.path) catch return error.InvalidEndpoint;
    return writer.buffered();
}

fn authorizationMetadataUrls(
    storage: *[3][Limits.url_bytes]u8,
    output: *[3][]const u8,
    issuer: []const u8,
) Error!usize {
    if (!validHttpsIssuer(issuer)) return error.InvalidEndpoint;
    const parts = urlParts(issuer) orelse return error.InvalidEndpoint;
    const has_path = parts.path.len != 0 and !std.mem.eql(u8, parts.path, "/");
    const origin = issuer[0..parts.origin_end];
    output[0] = buildUrl(&storage[0], &.{
        origin,
        "/.well-known/oauth-authorization-server",
        if (has_path) parts.path else "",
    }) catch return error.InvalidEndpoint;
    output[1] = buildUrl(&storage[1], &.{
        origin,
        "/.well-known/openid-configuration",
        if (has_path) parts.path else "",
    }) catch return error.InvalidEndpoint;
    if (!has_path) return 2;
    output[2] = buildUrl(&storage[2], &.{
        issuer,
        "/.well-known/openid-configuration",
    }) catch return error.InvalidEndpoint;
    return 3;
}

const UrlParts = struct {
    origin_end: usize,
    path: []const u8,
};

fn urlParts(value: []const u8) ?UrlParts {
    if (!validHttpsUrl(value)) return null;
    const scheme = std.mem.indexOf(u8, value, "://") orelse return null;
    const authority_start = scheme + 3;
    const query_start = std.mem.indexOfScalarPos(u8, value, authority_start, '?') orelse
        value.len;
    const slash_start = std.mem.indexOfScalarPos(u8, value, authority_start, '/') orelse
        value.len;
    const origin_end = @min(slash_start, query_start);
    const path = if (slash_start < query_start)
        value[slash_start..query_start]
    else
        "";
    return .{ .origin_end = origin_end, .path = path };
}

fn validHttpsUrl(value: []const u8) bool {
    if (value.len == 0 or value.len > Limits.url_bytes or
        !std.unicode.utf8ValidateSlice(value) or
        value.len < "https://".len or
        !std.ascii.eqlIgnoreCase(value[0.."https://".len], "https://") or
        std.mem.indexOfAny(u8, value, "#\\") != null)
        return false;
    for (value) |byte| if (byte <= 0x20 or byte == 0x7f) return false;
    const scheme = std.mem.indexOf(u8, value, "://") orelse return false;
    const authority_start = scheme + 3;
    const authority_end = std.mem.indexOfScalarPos(
        u8,
        value,
        authority_start,
        '/',
    ) orelse value.len;
    const authority = value[authority_start..authority_end];
    if (authority.len == 0 or std.mem.indexOfAny(u8, authority, "@%") != null)
        return false;
    const uri = std.Uri.parse(value) catch return false;
    return uri.host != null and uri.user == null and uri.password == null and
        uri.fragment == null;
}

fn validHttpsIssuer(value: []const u8) bool {
    if (!validHttpsUrl(value)) return false;
    const uri = std.Uri.parse(value) catch return false;
    return uri.query == null;
}

fn validLoopbackRedirect(value: []const u8) bool {
    if (value.len == 0 or value.len > Limits.url_bytes or
        !std.mem.startsWith(u8, value, "http://127.0.0.1:") or
        !std.mem.endsWith(u8, value, account_oauth.callback_path) or
        std.mem.indexOfAny(u8, value, "?#\\@%") != null)
        return false;
    const uri = std.Uri.parse(value) catch return false;
    const authority_start = "http://".len;
    const path_start = std.mem.indexOfScalarPos(u8, value, authority_start, '/') orelse
        return false;
    return std.mem.eql(u8, value[path_start..], account_oauth.callback_path) and
        uri.host != null and uri.port != null and uri.port.? != 0 and
        uri.user == null and uri.password == null and uri.query == null and
        uri.fragment == null;
}

fn validClientId(value: []const u8) bool {
    if (value.len == 0 or value.len > Limits.client_id_bytes or
        !std.unicode.utf8ValidateSlice(value)) return false;
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}

fn jsonContentType(value: ?[]const u8) bool {
    const raw = value orelse return false;
    const semicolon = std.mem.indexOfScalar(u8, raw, ';') orelse raw.len;
    return std.ascii.eqlIgnoreCase(
        std.mem.trim(u8, raw[0..semicolon], " \t"),
        "application/json",
    );
}

fn parseAuthMethods(
    allocator: std.mem.Allocator,
    values: []const []const u8,
) std.mem.Allocator.Error![]TokenEndpointAuthMethod {
    const result = try allocator.alloc(TokenEndpointAuthMethod, values.len);
    var count: usize = 0;
    for (values) |value| {
        const method = parseAuthMethod(value) orelse continue;
        if (containsAuthMethod(result[0..count], method)) continue;
        result[count] = method;
        count += 1;
    }
    return allocator.realloc(result, count);
}

fn parseAuthMethod(value: []const u8) ?TokenEndpointAuthMethod {
    return TokenEndpointAuthMethod.fromWire(value);
}

fn containsAuthMethod(
    methods: []const TokenEndpointAuthMethod,
    candidate: TokenEndpointAuthMethod,
) bool {
    for (methods) |method| if (method == candidate) return true;
    return false;
}

fn cloneStrings(
    allocator: std.mem.Allocator,
    values: []const []const u8,
    max_count: usize,
    max_bytes: usize,
) ![]const []const u8 {
    if (values.len > max_count) return error.InvalidMetadata;
    const result = try allocator.alloc([]const u8, values.len);
    for (values, result) |value, *target| {
        if (value.len == 0 or value.len > max_bytes or
            !std.unicode.utf8ValidateSlice(value)) return error.InvalidMetadata;
        target.* = try allocator.dupe(u8, value);
    }
    return result;
}

fn cloneSortedScopes(
    allocator: std.mem.Allocator,
    scopes: []const []const u8,
) ![]const []const u8 {
    const result = try cloneStrings(
        allocator,
        scopes,
        Limits.scopes,
        Limits.scope_bytes,
    );
    for (result) |scope| if (!validScope(scope)) return error.InvalidMetadata;
    std.mem.sort([]const u8, @constCast(result), {}, lessText);
    if (result.len > 1)
        for (result[1..], result[0 .. result.len - 1]) |current, previous|
            if (std.mem.eql(u8, current, previous)) return error.InvalidMetadata;
    return result;
}

fn parseScopeSet(allocator: std.mem.Allocator, value: []const u8) ![]const []const u8 {
    var count: usize = 0;
    var iterator = std.mem.splitScalar(u8, value, ' ');
    while (iterator.next()) |scope| {
        if (!validScope(scope)) return error.InvalidChallenge;
        count += 1;
        if (count > Limits.scopes) return error.InvalidChallenge;
    }
    const result = try allocator.alloc([]const u8, count);
    iterator = std.mem.splitScalar(u8, value, ' ');
    for (result) |*scope| scope.* = try allocator.dupe(u8, iterator.next().?);
    std.mem.sort([]const u8, result, {}, lessText);
    if (result.len > 1)
        for (result[1..], result[0 .. result.len - 1]) |current, previous|
            if (std.mem.eql(u8, current, previous)) return error.InvalidChallenge;
    return result;
}

fn validScope(value: []const u8) bool {
    if (value.len == 0 or value.len > Limits.scope_bytes) return false;
    for (value) |byte| if (byte == ' ' or byte == '"' or byte == '\\' or
        byte < 0x21 or byte > 0x7e) return false;
    return true;
}

fn lessText(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

fn containsText(values: []const []const u8, candidate: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, candidate)) return true;
    return false;
}

fn stringSetsEqual(left: []const []const u8, right: []const []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_value, right_value|
        if (!std.mem.eql(u8, left_value, right_value)) return false;
    return true;
}

fn joinScopes(output: []u8, scopes: []const []const u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(output);
    for (scopes, 0..) |scope, index| {
        if (!validScope(scope) or (index != 0 and
            std.mem.order(u8, scopes[index - 1], scope) != .lt))
            return error.InvalidAuthorizationRequest;
        if (index != 0) try writer.writeByte(' ');
        try writer.writeAll(scope);
    }
    return writer.buffered();
}

fn writeFormPairs(
    writer: *std.Io.Writer,
    pairs: []const struct { []const u8, []const u8 },
) !void {
    for (pairs, 0..) |pair, index| {
        if (index != 0) try writer.writeByte('&');
        try writePair(writer, pair[0], pair[1]);
    }
}

fn writePair(writer: *std.Io.Writer, key: []const u8, value: []const u8) !void {
    try percentEncode(writer, key);
    try writer.writeByte('=');
    try percentEncode(writer, value);
}

fn percentEncode(writer: *std.Io.Writer, input: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (input) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '.' or
            byte == '_' or byte == '~')
            try writer.writeByte(byte)
        else
            try writer.writeAll(&.{ '%', hex[byte >> 4], hex[byte & 0x0f] });
    }
}

fn buildBasicAuthorization(
    output: []u8,
    client_id: []const u8,
    client_secret: []const u8,
) ![]const u8 {
    var credential_storage: [Limits.client_id_bytes * 3 + Limits.secret_bytes * 3]u8 =
        undefined;
    defer std.crypto.secureZero(u8, &credential_storage);
    var credential_writer = std.Io.Writer.fixed(&credential_storage);
    try percentEncode(&credential_writer, client_id);
    try credential_writer.writeByte(':');
    try percentEncode(&credential_writer, client_secret);
    var writer = std.Io.Writer.fixed(output);
    try writer.writeAll("Basic ");
    const encoded_len = std.base64.standard.Encoder.calcSize(credential_writer.buffered().len);
    const encoded = try writer.writableSliceGreedy(encoded_len);
    _ = std.base64.standard.Encoder.encode(
        encoded[0..encoded_len],
        credential_writer.buffered(),
    );
    writer.advance(encoded_len);
    return writer.buffered();
}

fn buildUrl(output: []u8, parts: []const []const u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(output);
    for (parts) |part| try writer.writeAll(part);
    return writer.buffered();
}

test "MCP OAuth declaration graph compiles" {
    std.testing.refAllDecls(@This());
}

test "MCP OAuth token secrets reject HTTP control bytes" {
    try std.testing.expectError(
        error.InvalidTokenResponse,
        Secret.init(std.testing.allocator, "access\r\ninjected"),
    );
    try std.testing.expectError(
        error.InvalidTokenResponse,
        Secret.init(std.testing.allocator, "access\x7f"),
    );
}

test "MCP OAuth discovery validates resource issuer PKCE and exact metadata" {
    const Fake = struct {
        calls: usize = 0,

        fn fetch(
            context: ?*anyopaque,
            request: Request,
            _: []u8,
            _: []u8,
        ) FetchError!Response {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            if (std.mem.eql(u8, request.url, "https://mcp.example.test/mcp"))
                return .{
                    .status = 401,
                    .www_authenticate = "Bearer resource_metadata=\"https://mcp.example.test/oauth-resource\", scope=\"files.write files.read\"",
                };
            if (std.mem.eql(u8, request.url, "https://mcp.example.test/oauth-resource"))
                return .{
                    .status = 200,
                    .content_type = "application/json; charset=utf-8",
                    .body = "{\"resource\":\"https://mcp.example.test/mcp\",\"authorization_servers\":[\"https://auth.example.test/tenant\"],\"scopes_supported\":[\"ignored\"]}",
                };
            if (std.mem.eql(
                u8,
                request.url,
                "https://auth.example.test/.well-known/oauth-authorization-server/tenant",
            )) return .{
                .status = 200,
                .content_type = "application/json",
                .body = "{\"issuer\":\"https://auth.example.test/tenant\",\"authorization_endpoint\":\"https://auth.example.test/authorize\",\"token_endpoint\":\"https://auth.example.test/token\",\"registration_endpoint\":\"https://auth.example.test/register\",\"response_types_supported\":[\"code\"],\"grant_types_supported\":[\"authorization_code\",\"refresh_token\"],\"code_challenge_methods_supported\":[\"S256\"],\"token_endpoint_auth_methods_supported\":[\"none\",\"client_secret_basic\"],\"authorization_response_iss_parameter_supported\":true}",
            };
            return .{ .status = 404 };
        }
    };
    var fake: Fake = .{};
    const transport: Transport = .{ .context = &fake, .fetch_fn = Fake.fetch };
    var resource = try discoverResourceEffect(
        std.testing.allocator,
        transport,
        "https://mcp.example.test/mcp",
    );
    defer resource.deinit();
    try std.testing.expectEqualStrings("files.read", resource.requested_scopes[0]);
    try std.testing.expectEqualStrings("files.write", resource.requested_scopes[1]);
    try std.testing.expectEqualStrings("ignored", resource.scopes_supported[0]);
    var server = try discoverAuthorizationServer(
        std.testing.allocator,
        transport,
        &resource,
        resource.authorization_servers[0],
    );
    defer server.deinit();
    try std.testing.expect(server.authorization_response_issuer_required);
    try std.testing.expectEqual(
        TokenEndpointAuthMethod.none,
        server.dynamicRegistrationAuthMethod().?,
    );
    const material = account_oauth.AttemptMaterial.fromSeeds(
        @splat(0x11),
        @splat(0x22),
    );
    var url_storage: [account_oauth.Limits.authorization_url_bytes]u8 = undefined;
    const url = try buildAuthorizationUrl(
        &url_storage,
        &server,
        "client-one",
        "http://127.0.0.1:49152/auth/callback",
        resource.resource,
        resource.requested_scopes,
        &material,
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        url,
        "scope=files.read%20files.write",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        url,
        "resource=https%3A%2F%2Fmcp.example.test%2Fmcp",
    ) != null);
    server.authorization_endpoint = "https://auth.example.test/authorize?audience=mcp";
    const queried_url = try buildAuthorizationUrl(
        &url_storage,
        &server,
        "client-one",
        "http://127.0.0.1:49152/auth/callback",
        resource.resource,
        resource.requested_scopes,
        &material,
    );
    try std.testing.expect(std.mem.startsWith(
        u8,
        queried_url,
        "https://auth.example.test/authorize?audience=mcp&response_type=code",
    ));
    try std.testing.expectEqual(@as(usize, 3), fake.calls);
}

test "MCP OAuth does not request every advertised supported scope" {
    const Fake = struct {
        fn fetch(
            _: ?*anyopaque,
            request: Request,
            _: []u8,
            _: []u8,
        ) FetchError!Response {
            if (std.mem.eql(
                u8,
                request.url,
                "https://mcp.example.test/.well-known/oauth-protected-resource/mcp",
            )) return .{
                .status = 200,
                .content_type = "application/json",
                .body = "{\"resource\":\"https://mcp.example.test/mcp\",\"authorization_servers\":[\"https://auth.example.test\"],\"scopes_supported\":[\"admin\",\"read\"]}",
            };
            return .{ .status = 404 };
        }
    };
    var resource = try discoverResourceEffect(
        std.testing.allocator,
        .{ .fetch_fn = Fake.fetch },
        "https://mcp.example.test/mcp",
    );
    defer resource.deinit();
    try std.testing.expectEqual(@as(usize, 0), resource.requested_scopes.len);
    try std.testing.expectEqual(@as(usize, 2), resource.scopes_supported.len);
}

test "MCP OAuth DCR and code exchange are bounded and secret owned" {
    const Fake = struct {
        fn fetch(
            _: ?*anyopaque,
            request: Request,
            _: []u8,
            _: []u8,
        ) FetchError!Response {
            if (std.mem.eql(u8, request.url, "https://auth.example.test/register")) {
                if (std.mem.indexOf(u8, request.body, "\"application_type\":\"native\"") == null)
                    return .{ .status = 400 };
                return .{
                    .status = 201,
                    .content_type = "application/json",
                    .body = "{\"client_id\":\"issued-client\",\"redirect_uris\":[\"http://127.0.0.1:49152/auth/callback\"],\"grant_types\":[\"authorization_code\"],\"response_types\":[\"code\"],\"token_endpoint_auth_method\":\"none\"}",
                };
            }
            if (std.mem.eql(u8, request.url, "https://auth.example.test/token")) {
                if (std.mem.indexOf(u8, request.body, "resource=https%3A%2F%2Fmcp.example.test%2Fmcp") == null)
                    return .{ .status = 400 };
                return .{
                    .status = 200,
                    .content_type = "application/json",
                    .body = "{\"access_token\":\"access-secret\",\"refresh_token\":\"refresh-secret\",\"token_type\":\"Bearer\",\"expires_in\":60}",
                };
            }
            return .{ .status = 404 };
        }
    };
    var server_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const methods = try server_arena.allocator().dupe(
        TokenEndpointAuthMethod,
        &.{.none},
    );
    var server: AuthorizationServer = .{
        .arena = server_arena,
        .issuer = "https://auth.example.test",
        .authorization_endpoint = "https://auth.example.test/authorize",
        .token_endpoint = "https://auth.example.test/token",
        .registration_endpoint = "https://auth.example.test/register",
        .scopes_supported = &.{},
        .token_endpoint_auth_methods = methods,
        .refresh_token_supported = false,
        .authorization_response_issuer_required = false,
        .client_id_metadata_document_supported = false,
    };
    defer server.deinit();
    const transport: Transport = .{ .fetch_fn = Fake.fetch };
    var registration = try registerDynamicClientEffect(
        std.testing.allocator,
        transport,
        &server,
        "http://127.0.0.1:49152/auth/callback",
    );
    defer registration.deinit();
    try std.testing.expectEqualStrings("issued-client", registration.client_id);
    try std.testing.expect(registration.client_secret == null);
    var code = try account_oauth.Secret.init(std.testing.allocator, "auth-code");
    defer code.deinit();
    var tokens = try exchangeAuthorizationCodeEffect(
        std.testing.allocator,
        transport,
        &server,
        registration.client_id,
        null,
        .none,
        &code,
        "0123456789012345678901234567890123456789012",
        "http://127.0.0.1:49152/auth/callback",
        "https://mcp.example.test/mcp",
        1000,
    );
    defer tokens.deinit();
    try std.testing.expectEqualStrings("access-secret", tokens.access_token.view());
    try std.testing.expectEqual(@as(?u64, 61_000), tokens.expires_at_unix_ms);
}

test "MCP OAuth refresh is single-shot and preserves optional refresh rotation" {
    const Fake = struct {
        calls: usize = 0,

        fn fetch(
            context: ?*anyopaque,
            request: Request,
            _: []u8,
            _: []u8,
        ) FetchError!Response {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            if (std.mem.indexOf(u8, request.body, "grant_type=refresh_token") == null or
                std.mem.indexOf(u8, request.body, "refresh_token=old-refresh") == null or
                std.mem.indexOf(
                    u8,
                    request.body,
                    "resource=https%3A%2F%2Fmcp.example.test%2Fmcp",
                ) == null)
                return .{ .status = 400, .body = "{\"error\":\"invalid_grant\"}" };
            return .{
                .status = 200,
                .content_type = "application/json",
                .body = "{\"access_token\":\"new-access\",\"refresh_token\":\"new-refresh\",\"token_type\":\"Bearer\",\"expires_in\":60}",
            };
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const methods = try arena.allocator().dupe(
        TokenEndpointAuthMethod,
        &.{.none},
    );
    var server: AuthorizationServer = .{
        .arena = arena,
        .issuer = "https://auth.example.test",
        .authorization_endpoint = "https://auth.example.test/authorize",
        .token_endpoint = "https://auth.example.test/token",
        .registration_endpoint = null,
        .scopes_supported = &.{},
        .token_endpoint_auth_methods = methods,
        .refresh_token_supported = false,
        .authorization_response_issuer_required = false,
        .client_id_metadata_document_supported = false,
    };
    defer server.deinit();
    var fake: Fake = .{};
    var tokens = try refreshAccessTokenEffect(
        std.testing.allocator,
        .{ .context = &fake, .fetch_fn = Fake.fetch },
        &server,
        .{
            .issuer = "https://auth.example.test",
            .client_id = "client",
            .token_endpoint_auth_method = .none,
            .resource = "https://mcp.example.test/mcp",
            .consent_epoch = 3,
            .token_revision = 8,
        },
        null,
        "old-refresh",
        1000,
    );
    defer tokens.deinit();
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqualStrings("new-access", tokens.access_token.view());
    try std.testing.expectEqualStrings(
        "new-refresh",
        tokens.refresh_token.?.view(),
    );
    try std.testing.expectEqual(@as(?u64, 61_000), tokens.expires_at_unix_ms);
}

test "MCP OAuth flow commits marker before every non-idempotent POST" {
    const Harness = struct {
        marker: bool = false,
        authorized: usize = 0,
        completed: usize = 0,
        calls: usize = 0,

        fn port(self: *@This()) StatePort {
            return .{
                .context = self,
                .approved_endpoint_fn = approvedEndpoint,
                .authorize_fn = authorize,
                .begin_dynamic_registration_fn = beginDynamic,
                .complete_dynamic_registration_fn = completeDynamic,
                .begin_code_exchange_fn = beginCode,
                .complete_code_exchange_fn = completeCode,
                .clear_fn = clear,
                .uncertain_fn = uncertain,
            };
        }

        fn approvedEndpoint(
            _: *anyopaque,
            server_id: []const u8,
        ) StateError!ApprovedEndpoint {
            return .{
                .server_id = server_id,
                .url = "https://mcp.example.test/mcp",
            };
        }

        fn authorize(
            context: *anyopaque,
            plan: AuthorizationPlan,
        ) StateError!AuthorizationBinding {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.authorized += 1;
            return .{
                .attempt_id = plan.attempt_id,
                .server_id = plan.server_id,
                .issuer = plan.issuer,
                .resource = plan.resource,
                .scopes = plan.scopes,
                .redirect_uri = plan.redirect_uri,
                .client_id = "issued-client",
            };
        }

        fn beginDynamic(
            context: *anyopaque,
            _: DynamicRegistrationPlan,
        ) StateError!OperationHandle {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.marker) return error.StateRejected;
            self.marker = true;
            return .{ .id = "dcr-1", .server_id = "remote" };
        }

        fn completeDynamic(
            context: *anyopaque,
            operation: OperationHandle,
            registration: *Registration,
        ) StateError!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (!self.marker or !std.mem.eql(u8, operation.id, "dcr-1") or
                !std.mem.eql(u8, registration.client_id, "issued-client"))
                return error.StateRejected;
            self.marker = false;
            self.completed += 1;
        }

        fn beginCode(
            context: *anyopaque,
            server_id: []const u8,
        ) StateError!CodeExchangeOperation {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.marker or !std.mem.eql(u8, server_id, "remote"))
                return error.StateRejected;
            self.marker = true;
            return .{
                .operation = .{ .id = "code-1", .server_id = server_id },
                .issuer = "https://auth.example.test",
                .client_id = "issued-client",
                .token_endpoint_auth_method = .none,
                .resource = "https://mcp.example.test/mcp",
                .redirect_uri = "http://127.0.0.1:49152/auth/callback",
            };
        }

        fn completeCode(
            context: *anyopaque,
            operation: OperationHandle,
            tokens: *TokenSet,
        ) StateError!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (!self.marker or !std.mem.eql(u8, operation.id, "code-1") or
                !std.mem.eql(u8, tokens.access_token.view(), "access-secret"))
                return error.StateRejected;
            self.marker = false;
            self.completed += 1;
        }

        fn clear(context: *anyopaque, _: OperationHandle) StateError!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.marker = false;
        }

        fn uncertain(context: *anyopaque, _: OperationHandle) StateError!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.marker = false;
        }

        fn fetch(
            context: ?*anyopaque,
            request: Request,
            _: []u8,
            _: []u8,
        ) FetchError!Response {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (!self.marker) return error.InvalidResponse;
            self.calls += 1;
            if (std.mem.endsWith(u8, request.url, "/register")) return .{
                .status = 201,
                .content_type = "application/json",
                .body = "{\"client_id\":\"issued-client\",\"redirect_uris\":[\"http://127.0.0.1:49152/auth/callback\"],\"grant_types\":[\"authorization_code\"],\"response_types\":[\"code\"],\"token_endpoint_auth_method\":\"none\"}",
            };
            return .{
                .status = 200,
                .content_type = "application/json",
                .body = "{\"access_token\":\"access-secret\",\"token_type\":\"Bearer\"}",
            };
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const methods = try arena.allocator().dupe(
        TokenEndpointAuthMethod,
        &.{.none},
    );
    var server: AuthorizationServer = .{
        .arena = arena,
        .issuer = "https://auth.example.test",
        .authorization_endpoint = "https://auth.example.test/authorize",
        .token_endpoint = "https://auth.example.test/token",
        .registration_endpoint = "https://auth.example.test/register",
        .scopes_supported = &.{},
        .token_endpoint_auth_methods = methods,
        .refresh_token_supported = false,
        .authorization_response_issuer_required = false,
        .client_id_metadata_document_supported = false,
    };
    defer server.deinit();
    const resource_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var resource: ResourceDiscovery = .{
        .arena = resource_arena,
        .resource = "https://mcp.example.test/mcp",
        .authorization_servers = &.{"https://auth.example.test"},
        .scopes_supported = &.{},
        .requested_scopes = &.{"files.read"},
    };
    defer resource.deinit();
    var harness: Harness = .{};
    const transport: Transport = .{ .context = &harness, .fetch_fn = Harness.fetch };
    var attempt: AuthorizationAttempt = .{};
    try attempt.prepare(
        std.testing.io,
        41,
        harness.port(),
        "remote",
        &resource,
        &server,
    );
    defer attempt.deinit();
    try std.testing.expect(attempt.matches(41));
    try std.testing.expect(std.mem.indexOf(
        u8,
        attempt.authorizationUrl(),
        "client_id=issued-client",
    ) != null);
    try std.testing.expectEqual(
        FlowOutcome.completed,
        try performDynamicRegistration(
            std.testing.allocator,
            harness.port(),
            transport,
            &resource,
            &server,
            .{
                .server_id = "remote",
                .resource = "https://mcp.example.test/mcp",
                .issuer = "https://auth.example.test",
                .scopes = &.{"files.read"},
                .redirect_uri = "http://127.0.0.1:49152/auth/callback",
            },
        ),
    );
    var code = try account_oauth.Secret.init(std.testing.allocator, "auth-code");
    defer code.deinit();
    try std.testing.expectEqual(
        FlowOutcome.completed,
        try performCodeExchange(
            std.testing.allocator,
            harness.port(),
            transport,
            "remote",
            &server,
            null,
            &code,
            "0123456789012345678901234567890123456789012",
            1000,
        ),
    );
    try std.testing.expect(!harness.marker);
    try std.testing.expectEqual(@as(usize, 2), harness.calls);
    try std.testing.expectEqual(@as(usize, 2), harness.completed);
    try std.testing.expectEqual(@as(usize, 1), harness.authorized);
}

test "MCP OAuth never treats malformed success as a replayable failure" {
    const Fake = struct {
        mode: enum { registration, token } = .registration,

        fn fetch(
            context: ?*anyopaque,
            _: Request,
            _: []u8,
            _: []u8,
        ) FetchError!Response {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            return switch (self.mode) {
                .registration => .{
                    .status = 201,
                    .content_type = "application/json",
                    .body = "{\"client_id\":",
                },
                .token => .{
                    .status = 200,
                    .content_type = "application/json",
                    .body = "{\"access_token\":",
                },
            };
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const methods = try arena.allocator().dupe(
        TokenEndpointAuthMethod,
        &.{.none},
    );
    var server: AuthorizationServer = .{
        .arena = arena,
        .issuer = "https://auth.example.test",
        .authorization_endpoint = "https://auth.example.test/authorize",
        .token_endpoint = "https://auth.example.test/token",
        .registration_endpoint = "https://auth.example.test/register",
        .scopes_supported = &.{},
        .token_endpoint_auth_methods = methods,
        .refresh_token_supported = false,
        .authorization_response_issuer_required = false,
        .client_id_metadata_document_supported = false,
    };
    defer server.deinit();
    var fake: Fake = .{};
    const transport: Transport = .{ .context = &fake, .fetch_fn = Fake.fetch };
    try std.testing.expectError(
        error.RegistrationOutcomeUnknown,
        registerDynamicClientEffect(
            std.testing.allocator,
            transport,
            &server,
            "http://127.0.0.1:49152/auth/callback",
        ),
    );
    fake.mode = .token;
    var code = try account_oauth.Secret.init(std.testing.allocator, "auth-code");
    defer code.deinit();
    try std.testing.expectError(
        error.TokenOutcomeUnknown,
        exchangeAuthorizationCodeEffect(
            std.testing.allocator,
            transport,
            &server,
            "client",
            null,
            .none,
            &code,
            "0123456789012345678901234567890123456789012",
            "http://127.0.0.1:49152/auth/callback",
            "https://mcp.example.test/mcp",
            1000,
        ),
    );
}

test "MCP OAuth selects Bearer from combined challenges" {
    try std.testing.expectEqualStrings(
        "Bearer resource_metadata=\"https://mcp.example.test/prm\", scope=\"a b\"",
        selectBearerChallenge(
            "Basic realm=\"legacy\", Bearer resource_metadata=\"https://mcp.example.test/prm\", scope=\"a b\", DPoP realm=\"future\"",
        ).?,
    );
}

test "MCP OAuth cancellation stops discovery fallback and POST is outcome unknown" {
    const Fake = struct {
        calls: usize = 0,

        fn fetch(
            context: ?*anyopaque,
            _: Request,
            _: []u8,
            _: []u8,
        ) FetchError!Response {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            return error.Cancelled;
        }
    };
    var fake: Fake = .{};
    const transport: Transport = .{ .context = &fake, .fetch_fn = Fake.fetch };
    try std.testing.expectError(
        error.Cancelled,
        discoverResourceEffect(
            std.testing.allocator,
            transport,
            "https://mcp.example.test/mcp",
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), fake.calls);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const methods = try arena.allocator().dupe(
        TokenEndpointAuthMethod,
        &.{.none},
    );
    var server: AuthorizationServer = .{
        .arena = arena,
        .issuer = "https://auth.example.test",
        .authorization_endpoint = "https://auth.example.test/authorize",
        .token_endpoint = "https://auth.example.test/token",
        .registration_endpoint = "https://auth.example.test/register",
        .scopes_supported = &.{},
        .token_endpoint_auth_methods = methods,
        .refresh_token_supported = false,
        .authorization_response_issuer_required = false,
        .client_id_metadata_document_supported = false,
    };
    defer server.deinit();
    try std.testing.expectError(
        error.RegistrationOutcomeUnknown,
        registerDynamicClientEffect(
            std.testing.allocator,
            transport,
            &server,
            "http://127.0.0.1:49152/auth/callback",
        ),
    );
    try std.testing.expectEqual(@as(usize, 2), fake.calls);

    const BeforeSend = struct {
        fn fetch(
            _: ?*anyopaque,
            _: Request,
            _: []u8,
            _: []u8,
        ) FetchError!Response {
            return error.CancelledBeforeSend;
        }
    };
    try std.testing.expectError(
        error.CancelledBeforeSend,
        registerDynamicClientEffect(
            std.testing.allocator,
            .{ .fetch_fn = BeforeSend.fetch },
            &server,
            "http://127.0.0.1:49152/auth/callback",
        ),
    );
}

test "MCP OAuth well-known derivation omits resource query but preserves identity" {
    var storage: [Limits.url_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://mcp.example.test/.well-known/oauth-protected-resource/rpc",
        try protectedResourceMetadataUrl(
            &storage,
            "https://mcp.example.test/rpc?tenant=one",
            true,
        ),
    );
}
