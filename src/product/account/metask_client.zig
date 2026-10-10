//! Product Account Metask protocol client.
const std = @import("std");
const contract = @import("metawork_account_contract");
const state = @import("account_state");
const oauth = @import("account_oauth");
const summary = @import("account_summary");
const transport_api = @import("metask_transport");

pub const userinfo_url = oauth.userinfo_url;
pub const usage_stats_url = "https://app.metask-ai.com/v1/usage/stats";

pub const RequestKind = enum {
    exchange_code,
    refresh_token,
    userinfo,
    usage_stats,
};

pub const Request = struct {
    kind: RequestKind,
    body: []const u8 = "",
    bearer: ?[]const u8 = null,
    control: ?RequestControl = null,
    usage_stats_range: ?UsageStatsRange = null,
};

pub const UsageStatsRange = struct {
    since: []const u8,
    before: []const u8,
};

pub const Response = transport_api.Response;
pub const TransportError = transport_api.TransportError;
pub const Cancellation = transport_api.Cancellation;
pub const RequestControl = transport_api.RequestControl;

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

pub const AuthorizationResult = oauth.TokenSet;

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

pub fn exchangeAuthorizationCode(
    allocator: std.mem.Allocator,
    transport: Transport,
    code: *const oauth.Secret,
    verifier: []const u8,
    callback_port: u16,
    now_unix_seconds: i64,
    control: ?RequestControl,
) ClientError!oauth.TokenSet {
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
    return oauth.parseTokenResponse(
        allocator,
        response.body,
        now_unix_seconds,
    ) catch return error.ProtocolInvalid;
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
        return classifyRefreshFailure(response);
    var tokens = oauth.parseTokenResponse(
        allocator,
        response.body,
        now_unix_seconds,
    ) catch return error.ProtocolInvalid;
    if (std.mem.eql(u8, tokens.refresh_token.view(), refresh_token.view())) {
        tokens.deinit();
        return error.ProtocolInvalid;
    }
    return tokens.take();
}

pub fn fetchIdentity(
    transport: Transport,
    tokens: *const oauth.TokenSet,
    control: ?RequestControl,
) ClientError!state.AccountIdentity {
    var userinfo_storage: [oauth.Limits.current_user_body_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &userinfo_storage);
    const response = transport.perform(
        .{
            .kind = .userinfo,
            .bearer = tokens.access_token.view(),
            .control = control,
        },
        &userinfo_storage,
    ) catch |err| return transportFailure(err);
    if (response.status != 200)
        return classifyIdentityFailure(response);
    const userinfo = oauth.parseCurrentUser(response.body) catch
        return error.ProtocolInvalid;
    return state.AccountIdentity.init(
        userinfo.accountId(),
        userinfo.usernameView(),
        userinfo.emailHintView(),
        userinfo.phoneHintView(),
        userinfo.concurrency_limit,
    ) catch return error.ProtocolInvalid;
}

pub fn fetchUsageHistory(
    transport: Transport,
    bearer: []const u8,
    range: summary.HistoryRange,
    control: ?RequestControl,
) ClientError!summary.UsageHistoryData {
    const stats_range = range.usageStatsRange() catch
        return error.ProtocolInvalid;
    var storage: [192 * 1024]u8 = undefined;
    defer std.crypto.secureZero(u8, &storage);
    const response = transport.perform(
        .{
            .kind = .usage_stats,
            .bearer = bearer,
            .control = control,
            .usage_stats_range = .{
                .since = stats_range.since.view(),
                .before = stats_range.before.view(),
            },
        },
        &storage,
    ) catch |err| return transportFailure(err);
    if (response.status != 200) return classifyStatus(response.status, false);
    return summary.parseUsageStats(response.body, range) catch
        return error.ProtocolInvalid;
}

fn transportFailure(transport_error: TransportError) ClientError {
    return switch (transport_error) {
        error.Cancelled, error.CancelledNotSent => error.Cancelled,
        error.DeadlineExceeded, error.DeadlineExceededNotSent => error.DeadlineExceeded,
        error.NetworkFailed, error.NetworkNotSent => error.ServiceUnavailable,
        error.ResponseTooLarge,
        error.ProtocolFailed,
        => error.ProtocolInvalid,
    };
}

fn oauthError(response: Response) ?[]const u8 {
    // Return only known static codes; the bounded parser and its storage die here.
    if (response.body.len == 0 or response.body.len > oauth.Limits.token_body_bytes) return null;
    var scratch: [oauth.Limits.token_body_bytes * 2]u8 = undefined;
    defer std.crypto.secureZero(u8, &scratch);
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    var parsed = std.json.parseFromSlice(struct { @"error": []const u8 }, fba.allocator(), response.body, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    inline for (.{ "invalid_grant", "invalid_request", "invalid_client", "unauthorized_client", "unsupported_grant_type", "invalid_scope", "authorization_revoked", "user_not_found" }) |code| {
        if (std.mem.eql(u8, parsed.value.@"error", code)) return code;
    }
    return null;
}

fn classifyRefreshFailure(response: Response) ClientError {
    const code = oauthError(response) orelse return nonCredentialFailure(response.status);
    if (response.status == 400 and std.mem.eql(u8, code, "invalid_grant")) return error.Unauthorized;
    if ((response.status == 401 and std.mem.eql(u8, code, "invalid_client")) or
        (response.status == 400 and (std.mem.eql(u8, code, "invalid_request") or
            std.mem.eql(u8, code, "unauthorized_client") or std.mem.eql(u8, code, "unsupported_grant_type") or
            std.mem.eql(u8, code, "invalid_scope")))) return error.TokenRefreshFailed;
    return nonCredentialFailure(response.status);
}

fn classifyIdentityFailure(response: Response) ClientError {
    if (response.status == 401) {
        if (oauthError(response)) |code| {
            if (std.mem.eql(u8, code, "authorization_revoked") or std.mem.eql(u8, code, "user_not_found")) return error.Unauthorized;
        }
    }
    return nonCredentialFailure(response.status);
}

fn nonCredentialFailure(status: u16) ClientError {
    return switch (status) {
        429 => error.RateLimited,
        500...599 => error.ServiceUnavailable,
        else => error.ProtocolInvalid,
    };
}

fn classifyStatus(status: u16, exchange: bool) ClientError {
    return switch (status) {
        400 => if (exchange) error.OAuthExchangeFailed else error.ProtocolInvalid,
        401, 403 => if (exchange)
            error.OAuthExchangeFailed
        else
            error.Unauthorized,
        429 => error.RateLimited,
        500...599 => error.ServiceUnavailable,
        else => error.ProtocolInvalid,
    };
}

test "401 and 403 invalidate retained credentials outside code exchange" {
    try std.testing.expectEqual(error.Unauthorized, classifyStatus(401, false));
    try std.testing.expectEqual(error.Unauthorized, classifyStatus(403, false));
    try std.testing.expectEqual(error.OAuthExchangeFailed, classifyStatus(401, true));
    try std.testing.expectEqual(error.OAuthExchangeFailed, classifyStatus(403, true));
}

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
                    "client_id=metawork",
                ) == null) return error.ProtocolFailed;
                if (std.mem.indexOf(
                    u8,
                    request.body,
                    "redirect_uri=http%3A%2F%2Flocalhost%3A49152%2Fauth%2Fmetask%2Fcallback",
                ) == null) return error.ProtocolFailed;
                break :blk
                \\{"access_token":"access","refresh_token":"refresh","token_type":"Bearer","expires_in":3600}
                ;
            },
            1 => blk: {
                if (request.kind != .userinfo or
                    !std.mem.eql(u8, request.bearer orelse "", "access"))
                    return error.ProtocolFailed;
                break :blk
                \\{"sub":"1","email":"user@example.com","email_verified":true,"name":"Meta User","phone_number":"13800138000","client_id":"metawork","authorization_id":"auth-1"}
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

test "login exchanges tokens before resolving a strict identity" {
    var fake: FakeTransport = .{};
    var code = try oauth.Secret.init(
        std.testing.allocator,
        "authorization-code",
    );
    defer code.deinit();
    var tokens = try exchangeAuthorizationCode(
        std.testing.allocator,
        fake.transport(),
        &code,
        "verifier",
        49152,
        100,
        null,
    );
    defer tokens.deinit();
    try std.testing.expectEqualStrings("access", tokens.access_token.view());
    try std.testing.expectEqual(@as(usize, 1), fake.step);
    const identity = try fetchIdentity(fake.transport(), &tokens, null);
    try std.testing.expectEqualStrings(
        "1",
        identity.accountId(),
    );
    try std.testing.expectEqualStrings(
        "Meta User",
        identity.displayName(),
    );
    try std.testing.expectEqualStrings(
        "u***@example.com",
        identity.emailHint(),
    );
    try std.testing.expectEqualStrings("138****8000", identity.phoneHint());
    try std.testing.expectEqual(@as(?u32, null), identity.concurrency_limit);
    try std.testing.expectEqual(@as(usize, 2), fake.step);
}

test "userinfo failure never infers a principal from the token" {
    var tokens = try oauth.TokenSet.fromStored(
        std.testing.allocator,
        "access",
        "refresh",
        100,
        "1",
    );
    defer tokens.deinit();
    var failing = struct {
        fn perform(
            _: *anyopaque,
            request: Request,
            output: []u8,
        ) TransportError!Response {
            if (request.kind != .userinfo) return error.ProtocolFailed;
            const body = "{}";
            @memcpy(output[0..body.len], body);
            return .{ .status = 503, .body = output[0..body.len] };
        }
    }{};
    try std.testing.expectError(
        error.ServiceUnavailable,
        fetchIdentity(
            .{ .context = &failing, .perform_fn = @TypeOf(failing).perform },
            &tokens,
            null,
        ),
    );
}

test "refresh requires and installs the rotated refresh token" {
    var previous = try oauth.parseTokenResponse(
        std.testing.allocator,
        \\{"access_token":"old-access","refresh_token":"old-refresh","token_type":"Bearer","expires_in":20,"scope":"read model:invoke"}
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
                !std.mem.eql(
                    u8,
                    request.body,
                    "grant_type=refresh_token&client_id=metawork&refresh_token=old-refresh",
                ))
                return error.ProtocolFailed;
            const body =
                \\{"access_token":"new-access","refresh_token":"new-refresh","token_type":"bearer","expires_in":30}
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

test "refresh HTTP 400 distinguishes invalid grant from request and protocol errors" {
    const Case = struct { body: []const u8, expected: ClientError };
    const cases = [_]Case{
        .{ .body = "{\"error\":\"invalid_grant\",\"error_description\":\"refresh token expired\"}", .expected = error.Unauthorized },
        .{ .body = "{\"error\":\"invalid_request\",\"error_description\":\"client_id required\"}", .expected = error.TokenRefreshFailed },
        .{ .body = "{\"error\":\"invalid_client\"}", .expected = error.ProtocolInvalid },
        .{ .body = "{\"error\":\"unauthorized_client\"}", .expected = error.TokenRefreshFailed },
        .{ .body = "{\"error\":\"unsupported_grant_type\"}", .expected = error.TokenRefreshFailed },
        .{ .body = "{\"error\":\"invalid_scope\"}", .expected = error.TokenRefreshFailed },
        .{ .body = "{\"error\":\"unknown\"}", .expected = error.ProtocolInvalid },
        .{ .body = "{\"error\":42}", .expected = error.ProtocolInvalid },
        .{ .body = "{}", .expected = error.ProtocolInvalid },
        .{ .body = "<html>Bad Request</html>", .expected = error.ProtocolInvalid },
    };
    const ErrorTransport = struct {
        body: []const u8,
        fn perform(context: *anyopaque, request: Request, output: []u8) TransportError!Response {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (request.kind != .refresh_token or !std.mem.eql(
                u8,
                request.body,
                "grant_type=refresh_token&client_id=metawork&refresh_token=retained-refresh",
            )) return error.ProtocolFailed;
            @memcpy(output[0..self.body.len], self.body);
            return .{ .status = 400, .body = output[0..self.body.len] };
        }
    };
    var token = try oauth.Secret.init(std.testing.allocator, "retained-refresh");
    defer token.deinit();
    for (cases) |case| {
        var transport: ErrorTransport = .{ .body = case.body };
        try std.testing.expectError(case.expected, refreshWithToken(
            std.testing.allocator,
            .{ .context = &transport, .perform_fn = ErrorTransport.perform },
            &token,
            100,
            null,
        ));
    }
}

test "refresh and identity invalidate only exact endpoint error pairs" {
    try std.testing.expectEqual(error.TokenRefreshFailed, classifyRefreshFailure(.{ .status = 401, .body = "{\"error\":\"invalid_client\"}" }));
    try std.testing.expectEqual(error.ProtocolInvalid, classifyRefreshFailure(.{ .status = 401, .body = "{\"error\":\"invalid_grant\"}" }));
    try std.testing.expectEqual(error.ProtocolInvalid, classifyRefreshFailure(.{ .status = 403, .body = "{}" }));
    try std.testing.expectEqual(error.ServiceUnavailable, classifyRefreshFailure(.{ .status = 503, .body = "{\"error\":\"invalid_grant\"}" }));
    try std.testing.expectEqual(error.ProtocolInvalid, classifyIdentityFailure(.{ .status = 401, .body = "{\"error\":\"invalid_token\"}" }));
    try std.testing.expectEqual(error.ProtocolInvalid, classifyIdentityFailure(.{ .status = 403, .body = "{\"error\":\"authorization_revoked\"}" }));
    try std.testing.expectEqual(error.Unauthorized, classifyIdentityFailure(.{ .status = 401, .body = "{\"error\":\"authorization_revoked\"}" }));
    try std.testing.expectEqual(error.Unauthorized, classifyIdentityFailure(.{ .status = 401, .body = "{\"error\":\"user_not_found\"}" }));
}
