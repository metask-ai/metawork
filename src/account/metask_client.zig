const std = @import("std");
const contract = @import("metawork_account_contract");
const state = @import("account_state");
const oauth = @import("account_oauth");

pub const api_keys_url =
    "https://napi.metask-ai.com/api/v1/keys?page=1&page_size=100";
pub const models_url = "https://napi.metask-ai.com/v1/models";

pub const RequestKind = enum {
    exchange_code,
    refresh_token,
    profiles,
    keys,
    models,
};

pub const Request = struct {
    kind: RequestKind,
    body: []const u8 = "",
    bearer: ?[]const u8 = null,
    profile_id: ?[]const u8 = null,
    control: ?RequestControl = null,
};

pub const Response = struct {
    status: u16,
    body: []const u8,
};

pub const TransportError = error{
    NetworkFailed,
    ResponseTooLarge,
    ProtocolFailed,
    Cancelled,
    DeadlineExceeded,
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

    pub fn wait(self: *const Cancellation) void {
        while (!self.isCancelled()) {
            self.io.futexWait(
                u32,
                &self.state.raw,
                0,
            ) catch return;
        }
    }
};

pub const RequestControl = struct {
    cancellation: *const Cancellation,
    deadline: std.Io.Clock.Timestamp,
};

pub const Transport = struct {
    context: *anyopaque,
    perform_fn: *const fn (
        context: *anyopaque,
        request: Request,
        response_buffer: []u8,
    ) TransportError!Response,

    pub fn perform(
        self: Transport,
        request: Request,
        response_buffer: []u8,
    ) TransportError!Response {
        return self.perform_fn(self.context, request, response_buffer);
    }
};

pub const ClientError = error{
    OAuthExchangeFailed,
    TokenRefreshFailed,
    Unauthorized,
    RateLimited,
    ServiceUnavailable,
    ProtocolInvalid,
    Cancelled,
    DeadlineExceeded,
};

pub fn workerFailure(client_error: ClientError) state.WorkerFailure {
    return .fromCode(errorCode(client_error));
}

pub fn errorCode(client_error: ClientError) contract.ErrorCode {
    return switch (client_error) {
        error.OAuthExchangeFailed => .oauth_exchange_failed,
        error.TokenRefreshFailed => .token_refresh_failed,
        error.Unauthorized => .metask_unauthorized,
        error.RateLimited => .metask_rate_limited,
        error.ServiceUnavailable => .metask_service_unavailable,
        error.ProtocolInvalid => .metask_protocol_invalid,
        error.Cancelled => .user_cancelled,
        error.DeadlineExceeded => .deadline_exceeded,
    };
}

pub const LoginResult = struct {
    tokens: oauth.TokenSet,
    identity: state.AccountIdentity,
    owned: bool = true,

    pub fn deinit(self: *LoginResult) void {
        if (!self.owned) return;
        self.tokens.deinit();
        self.owned = false;
    }

    pub fn take(self: *LoginResult) LoginResult {
        std.debug.assert(self.owned);
        const result: LoginResult = .{
            .tokens = self.tokens.take(),
            .identity = self.identity,
        };
        self.owned = false;
        return result;
    }
};

pub fn exchangeAndIdentify(
    allocator: std.mem.Allocator,
    transport: Transport,
    code: *const oauth.Secret,
    verifier: []const u8,
    callback_port: u16,
    now_unix_seconds: i64,
    control: ?RequestControl,
) ClientError!LoginResult {
    var request_body: [oauth.Limits.token_body_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &request_body);
    const body = oauth.buildAuthorizationCodeBody(
        &request_body,
        code,
        verifier,
        callback_port,
    ) catch return error.OAuthExchangeFailed;
    var response_storage: [oauth.Limits.token_body_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &response_storage);
    const response = transport.perform(
        .{ .kind = .exchange_code, .body = body, .control = control },
        &response_storage,
    ) catch |err| return transportFailure(err);
    if (response.status != 200)
        return classifyStatus(response.status, true);
    var tokens = oauth.parseTokenResponse(
        allocator,
        response.body,
        now_unix_seconds,
    ) catch return error.ProtocolInvalid;
    errdefer tokens.deinit();
    const identity = fetchIdentity(transport, &tokens, control) catch |err| {
        // Exchanging the authorization code is the OAuth commit boundary.
        // Profile discovery is a subsequent business API call, so a gateway
        // failure must not discard a newly issued refresh token.
        if (err == error.Cancelled) return err;
        const account_only = accountOnlyIdentity(&tokens) catch
            return error.ProtocolInvalid;
        return .{ .tokens = tokens.take(), .identity = account_only };
    };
    return .{ .tokens = tokens.take(), .identity = identity };
}

pub fn accountOnlyIdentity(tokens: *const oauth.TokenSet) !state.AccountIdentity {
    return state.AccountIdentity.init(
        tokens.accountId(),
        "",
        tokens.accountId(),
    );
}

pub fn refresh(
    allocator: std.mem.Allocator,
    transport: Transport,
    previous: *const oauth.TokenSet,
    now_unix_seconds: i64,
    control: ?RequestControl,
) ClientError!oauth.TokenSet {
    return refreshWithToken(
        allocator,
        transport,
        &previous.refresh_token,
        now_unix_seconds,
        control,
    );
}

pub fn refreshWithToken(
    allocator: std.mem.Allocator,
    transport: Transport,
    refresh_token: *const oauth.Secret,
    now_unix_seconds: i64,
    control: ?RequestControl,
) ClientError!oauth.TokenSet {
    var request_body: [oauth.Limits.token_body_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &request_body);
    const body = oauth.buildRefreshBody(
        &request_body,
        refresh_token,
    ) catch return error.TokenRefreshFailed;
    var response_storage: [oauth.Limits.token_body_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &response_storage);
    const response = transport.perform(
        .{ .kind = .refresh_token, .body = body, .control = control },
        &response_storage,
    ) catch |err| return transportFailure(err);
    if (response.status != 200)
        return classifyStatus(response.status, false);
    return oauth.parseTokenResponse(
        allocator,
        response.body,
        now_unix_seconds,
    ) catch return error.ProtocolInvalid;
}

pub fn fetchIdentity(
    transport: Transport,
    tokens: *const oauth.TokenSet,
    control: ?RequestControl,
) ClientError!state.AccountIdentity {
    var response_storage: [oauth.Limits.profiles_body_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &response_storage);
    const response = transport.perform(
        .{
            .kind = .profiles,
            .bearer = tokens.access_token.view(),
            .control = control,
        },
        &response_storage,
    ) catch |err| return transportFailure(err);
    if (response.status != 200)
        return classifyStatus(response.status, false);
    const profile = oauth.parseFirstProfile(response.body) catch
        return error.ProtocolInvalid;
    const profile_id = if (profile) |selected| selected.idView() else "";
    return state.AccountIdentity.init(
        tokens.accountId(),
        profile_id,
        tokens.accountId(),
    ) catch return error.ProtocolInvalid;
}

fn transportFailure(transport_error: TransportError) ClientError {
    return switch (transport_error) {
        error.Cancelled => error.Cancelled,
        error.DeadlineExceeded => error.DeadlineExceeded,
        error.NetworkFailed => error.ServiceUnavailable,
        error.ResponseTooLarge,
        error.ProtocolFailed,
        => error.ProtocolInvalid,
    };
}

fn classifyStatus(status: u16, exchange: bool) ClientError {
    return switch (status) {
        400, 401 => if (exchange)
            error.OAuthExchangeFailed
        else
            error.Unauthorized,
        403 => error.Unauthorized,
        429 => error.RateLimited,
        500...599 => error.ServiceUnavailable,
        else => error.ProtocolInvalid,
    };
}

pub const StdHttpTransport = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    const default_request_timeout: std.Io.Clock.Duration = .{
        .raw = .fromSeconds(30),
        .clock = .boot,
    };

    const FetchResult = union(enum) {
        completed: struct {
            status: u16,
            body_len: usize,
        },
        network_failed,
        response_too_large,
        protocol_failed,
    };

    const Outcome = union(enum) {
        fetch: FetchResult,
        deadline,
        cancelled,
    };

    pub fn transport(self: *StdHttpTransport) Transport {
        return .{
            .context = self,
            .perform_fn = perform,
        };
    }

    fn perform(
        context: *anyopaque,
        request: Request,
        response_buffer: []u8,
    ) TransportError!Response {
        const self: *StdHttpTransport = @ptrCast(@alignCast(context));
        const deadline = if (request.control) |control|
            control.deadline
        else
            std.Io.Clock.Timestamp.fromNow(
                self.io,
                default_request_timeout,
            );
        var outcome_storage: [3]Outcome = undefined;
        var selection = std.Io.Select(Outcome).init(
            self.io,
            &outcome_storage,
        );
        selection.async(
            .fetch,
            fetch,
            .{ self, request, response_buffer },
        );
        selection.async(
            .deadline,
            waitDeadline,
            .{ self.io, deadline },
        );
        if (request.control) |control| {
            selection.async(
                .cancelled,
                waitCancellation,
                .{control.cancellation},
            );
        }
        const outcome = selection.await() catch {
            selection.cancelDiscard();
            return error.NetworkFailed;
        };
        switch (outcome) {
            .fetch => |result| {
                selection.cancelDiscard();
                if (request.control) |control| {
                    if (control.cancellation.isCancelled())
                        return error.Cancelled;
                }
                return switch (result) {
                    .completed => |completed| .{
                        .status = completed.status,
                        .body = response_buffer[0..completed.body_len],
                    },
                    .network_failed => error.NetworkFailed,
                    .response_too_large => error.ResponseTooLarge,
                    .protocol_failed => error.ProtocolFailed,
                };
            },
            .deadline => {
                selection.cancelDiscard();
                return error.DeadlineExceeded;
            },
            .cancelled => {
                selection.cancelDiscard();
                return error.Cancelled;
            },
        }
    }

    fn fetch(
        self: *StdHttpTransport,
        request: Request,
        response_buffer: []u8,
    ) FetchResult {
        var response_writer = std.Io.Writer.fixed(response_buffer);
        var client: std.http.Client = .{
            .allocator = self.allocator,
            .io = self.io,
        };
        defer client.deinit();

        var authorization_storage: [oauth.Limits.secret_bytes + "Bearer ".len]u8 =
            undefined;
        defer std.crypto.secureZero(u8, &authorization_storage);
        var authorization: []const u8 = "";
        if (request.bearer) |bearer| {
            if (bearer.len == 0 or
                bearer.len > oauth.Limits.secret_bytes or
                std.mem.indexOfAny(u8, bearer, "\r\n") != null)
                return .protocol_failed;
            @memcpy(authorization_storage[0.."Bearer ".len], "Bearer ");
            @memcpy(
                authorization_storage["Bearer ".len .. "Bearer ".len + bearer.len],
                bearer,
            );
            authorization = authorization_storage[0 .. "Bearer ".len + bearer.len];
        }

        const endpoint, const method: std.http.Method = switch (request.kind) {
            .exchange_code, .refresh_token => .{ oauth.token_url, .POST },
            .profiles => .{ oauth.profiles_url, .GET },
            .keys => .{ api_keys_url, .GET },
            .models => .{ models_url, .GET },
        };
        var headers: [4]std.http.Header = undefined;
        var header_count: usize = 0;
        headers[header_count] = .{
            .name = "Accept",
            .value = "application/json",
        };
        header_count += 1;
        if (method == .POST) {
            headers[header_count] = .{
                .name = "Content-Type",
                .value = "application/x-www-form-urlencoded",
            };
            header_count += 1;
        }
        if (method == .GET) {
            if (authorization.len == 0) return .protocol_failed;
            headers[header_count] = .{
                .name = "Authorization",
                .value = authorization,
            };
            header_count += 1;
        } else if (request.bearer != null) {
            return .protocol_failed;
        }
        switch (request.kind) {
            .keys, .models => {
                const profile_id = request.profile_id orelse
                    return .protocol_failed;
                if (profile_id.len == 0 or
                    profile_id.len > contract.Limits.profile_id_bytes or
                    std.mem.indexOfAny(u8, profile_id, "\r\n") != null)
                    return .protocol_failed;
                headers[header_count] = .{
                    .name = "X-Profile-ID",
                    .value = profile_id,
                };
                header_count += 1;
            },
            else => if (request.profile_id != null)
                return .protocol_failed,
        }

        const result = client.fetch(.{
            .location = .{ .url = endpoint },
            .method = method,
            .payload = if (method == .POST) request.body else null,
            .redirect_behavior = .unhandled,
            .response_writer = &response_writer,
            .extra_headers = headers[0..header_count],
        }) catch |err| switch (err) {
            error.StreamTooLong => return .response_too_large,
            else => return .network_failed,
        };
        return .{ .completed = .{
            .status = @intFromEnum(result.status),
            .body_len = response_writer.buffered().len,
        } };
    }

    fn waitDeadline(
        io: std.Io,
        deadline: std.Io.Clock.Timestamp,
    ) void {
        deadline.wait(io) catch {};
    }

    fn waitCancellation(cancellation: *const Cancellation) void {
        cancellation.wait();
    }
};

const FakeTransport = struct {
    step: usize = 0,

    fn transport(self: *FakeTransport) Transport {
        return .{ .context = self, .perform_fn = perform };
    }

    fn perform(
        context: *anyopaque,
        request: Request,
        response_buffer: []u8,
    ) TransportError!Response {
        const self: *FakeTransport = @ptrCast(@alignCast(context));
        const body = switch (self.step) {
            0 => blk: {
                if (request.kind != .exchange_code or request.bearer != null)
                    return error.ProtocolFailed;
                if (std.mem.indexOf(
                    u8,
                    request.body,
                    "client_id=metawork-app",
                ) == null) return error.ProtocolFailed;
                break :blk
                \\{"access_token":"access","refresh_token":"refresh","token_type":"Bearer","expires_in":3600,"scope":"metawork:use","account_id":"acct-1"}
                ;
            },
            1 => blk: {
                if (request.kind != .profiles or
                    !std.mem.eql(u8, request.bearer orelse "", "access"))
                    return error.ProtocolFailed;
                break :blk
                \\{"data":[{"id":"profile-1","name":"main","display_name":"Main","status":"active","platform":"anthropic","group_id":1,"group_name":"Main","expires_at":null,"is_default":true}]}
                ;
            },
            else => return error.ProtocolFailed,
        };
        if (body.len > response_buffer.len) return error.ResponseTooLarge;
        @memcpy(response_buffer[0..body.len], body);
        self.step += 1;
        return .{ .status = 200, .body = response_buffer[0..body.len] };
    }
};

test "login exchanges the code then resolves a secret-free identity" {
    var fake: FakeTransport = .{};
    var code = try oauth.Secret.init(
        std.testing.allocator,
        "authorization-code",
    );
    defer code.deinit();
    var result = try exchangeAndIdentify(
        std.testing.allocator,
        fake.transport(),
        &code,
        "verifier",
        40123,
        100,
        null,
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("access", result.tokens.access_token.view());
    try std.testing.expectEqualStrings(
        "acct-1",
        result.identity.accountId(),
    );
    try std.testing.expectEqualStrings(
        "profile-1",
        result.identity.profileId(),
    );
    try std.testing.expectEqualStrings(
        "acct-1",
        result.identity.displayName(),
    );
    try std.testing.expectEqual(@as(usize, 2), fake.step);
}

test "login remains authenticated when the documented profile list is empty" {
    var fake = struct {
        step: usize = 0,

        fn perform(
            context: *anyopaque,
            request: Request,
            response_buffer: []u8,
        ) TransportError!Response {
            const self: *@This() = @ptrCast(@alignCast(context));
            const body = switch (self.step) {
                0 => blk: {
                    if (request.kind != .exchange_code) return error.ProtocolFailed;
                    break :blk
                    \\{"access_token":"access","refresh_token":"refresh","token_type":"Bearer","expires_in":3600,"scope":"metawork:use","account_id":"acct-1"}
                    ;
                },
                1 => blk: {
                    if (request.kind != .profiles) return error.ProtocolFailed;
                    break :blk "{\"data\":[]}";
                },
                else => return error.ProtocolFailed,
            };
            if (body.len > response_buffer.len) return error.ResponseTooLarge;
            @memcpy(response_buffer[0..body.len], body);
            self.step += 1;
            return .{ .status = 200, .body = response_buffer[0..body.len] };
        }
    }{};
    var code = try oauth.Secret.init(std.testing.allocator, "authorization-code");
    defer code.deinit();
    var result = try exchangeAndIdentify(
        std.testing.allocator,
        .{ .context = &fake, .perform_fn = @TypeOf(fake).perform },
        &code,
        "verifier",
        40123,
        100,
        null,
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("acct-1", result.identity.accountId());
    try std.testing.expectEqualStrings("", result.identity.profileId());
    try std.testing.expectEqualStrings("acct-1", result.identity.displayName());
}

test "login keeps issued tokens when profile discovery rejects the new scope" {
    var fake = struct {
        step: usize = 0,

        fn perform(
            context: *anyopaque,
            request: Request,
            response_buffer: []u8,
        ) TransportError!Response {
            const self: *@This() = @ptrCast(@alignCast(context));
            defer self.step += 1;
            return switch (self.step) {
                0 => blk: {
                    if (request.kind != .exchange_code) return error.ProtocolFailed;
                    const body =
                        \\{"access_token":"new-access","refresh_token":"new-refresh","token_type":"Bearer","expires_in":3600,"scope":"metawork:use","account_id":"acct-1"}
                    ;
                    @memcpy(response_buffer[0..body.len], body);
                    break :blk .{ .status = 200, .body = response_buffer[0..body.len] };
                },
                1 => blk: {
                    if (request.kind != .profiles or
                        !std.mem.eql(u8, request.bearer orelse "", "new-access"))
                        return error.ProtocolFailed;
                    const body = "{\"code\":\"INVALID_API_KEY\"}";
                    @memcpy(response_buffer[0..body.len], body);
                    break :blk .{ .status = 401, .body = response_buffer[0..body.len] };
                },
                else => return error.ProtocolFailed,
            };
        }
    }{};
    var code = try oauth.Secret.init(std.testing.allocator, "authorization-code");
    defer code.deinit();
    var result = try exchangeAndIdentify(
        std.testing.allocator,
        .{ .context = &fake, .perform_fn = @TypeOf(fake).perform },
        &code,
        "verifier",
        40123,
        100,
        null,
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("new-refresh", result.tokens.refresh_token.view());
    try std.testing.expectEqualStrings("acct-1", result.identity.accountId());
    try std.testing.expectEqualStrings("", result.identity.profileId());
    try std.testing.expectEqual(@as(usize, 2), fake.step);
}

test "refresh requires and installs the rotated refresh token" {
    var previous = try oauth.parseTokenResponse(
        std.testing.allocator,
        \\{"access_token":"old-access","refresh_token":"old-refresh","token_type":"Bearer","expires_in":20,"scope":"metawork:use","account_id":"acct-1"}
    ,
        0,
    );
    defer previous.deinit();
    var fake = struct {
        fn perform(
            _: *anyopaque,
            request: Request,
            response_buffer: []u8,
        ) TransportError!Response {
            if (request.kind != .refresh_token or
                std.mem.indexOf(
                    u8,
                    request.body,
                    "refresh_token=old-refresh",
                ) == null)
                return error.ProtocolFailed;
            const body =
                \\{"access_token":"new-access","refresh_token":"new-refresh","token_type":"bearer","expires_in":30,"scope":"metawork:use","account_id":"acct-1"}
            ;
            @memcpy(response_buffer[0..body.len], body);
            return .{ .status = 200, .body = response_buffer[0..body.len] };
        }
    }{};
    var tokens = try refresh(
        std.testing.allocator,
        .{ .context = &fake, .perform_fn = @TypeOf(fake).perform },
        &previous,
        20,
        null,
    );
    defer tokens.deinit();
    try std.testing.expectEqualStrings("new-access", tokens.access_token.view());
    try std.testing.expectEqualStrings("new-refresh", tokens.refresh_token.view());
    try std.testing.expectEqual(@as(i64, 50), tokens.expires_at);
}
