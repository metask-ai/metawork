//! Account OAuth wire pins: authorization URL and token request bytes, token
//! response acceptance and OAuth error classification, exactly as observed at
//! the Account boundary. Any change to these results is a behavior change.
const std = @import("std");
const oauth = @import("account_oauth");
const client = @import("metask_client.zig");

const now: i64 = 100;
const reserved_value = "c0de -._~+/%?&=\x00\x7f\xff\xe4\xb8\xad";

fn material() oauth.AttemptMaterial {
    return oauth.AttemptMaterial.fromSeeds(@splat(0x11), @splat(0x22));
}

test "Account authorization URL bytes" {
    const attempt = material();
    var buffer: [oauth.Limits.authorization_url_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://www.metask-ai.com/oauth/authorize?response_type=code&client_id=metawork&redirect_uri=http%3A%2F%2Flocalhost%3A49152%2Fauth%2Fmetask%2Fcallback&scope=read%20model%3Ainvoke&state=IiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiI&code_challenge=tZ5lxAKmKebFsoNVx2KKEAImK1W0OlL5QcAnQOO9-vw&code_challenge_method=S256",
        try oauth.buildAuthorizeUrl(&buffer, 49152, &attempt),
    );
    try std.testing.expectEqualStrings(
        "https://www.metask-ai.com/oauth/authorize?response_type=code&client_id=metawork&redirect_uri=http%3A%2F%2Flocalhost%3A65535%2Fauth%2Fmetask%2Fcallback&scope=read%20model%3Ainvoke&state=IiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiI&code_challenge=tZ5lxAKmKebFsoNVx2KKEAImK1W0OlL5QcAnQOO9-vw&code_challenge_method=S256",
        try oauth.buildAuthorizeUrl(&buffer, 65535, &attempt),
    );
    const exact_len = (try oauth.buildAuthorizeUrl(&buffer, 49152, &attempt)).len;
    var exact: [exact_len_storage]u8 = undefined;
    _ = try oauth.buildAuthorizeUrl(exact[0..exact_len], 49152, &attempt);
    try std.testing.expectError(
        error.BufferTooSmall,
        oauth.buildAuthorizeUrl(exact[0 .. exact_len - 1], 49152, &attempt),
    );
    try std.testing.expectError(
        error.InvalidCallback,
        oauth.buildAuthorizeUrl(&buffer, 0, &attempt),
    );
}

const exact_len_storage = oauth.Limits.authorization_url_bytes;

test "Account token request body bytes" {
    const attempt = material();
    var code = try oauth.Secret.init(std.testing.allocator, reserved_value);
    defer code.deinit();
    var refresh = try oauth.Secret.init(std.testing.allocator, reserved_value);
    defer refresh.deinit();
    var buffer: [oauth.Limits.token_body_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(
        "grant_type=authorization_code&client_id=metawork&code=c0de%20-._~%2B%2F%25%3F%26%3D%00%7F%FF%E4%B8%AD&code_verifier=ERERERERERERERERERERERERERERERERERERERERERE&redirect_uri=http%3A%2F%2Flocalhost%3A49152%2Fauth%2Fmetask%2Fcallback",
        try oauth.buildAuthorizationCodeBody(&buffer, &code, &attempt.verifier, 49152),
    );
    try std.testing.expectEqualStrings(
        "grant_type=refresh_token&client_id=metawork&refresh_token=c0de%20-._~%2B%2F%25%3F%26%3D%00%7F%FF%E4%B8%AD",
        try oauth.buildRefreshBody(&buffer, &refresh),
    );
    var small: [32]u8 = undefined;
    try std.testing.expectError(
        error.BufferTooSmall,
        oauth.buildAuthorizationCodeBody(&small, &code, &attempt.verifier, 49152),
    );
    try std.testing.expectError(
        error.BufferTooSmall,
        oauth.buildRefreshBody(&small, &refresh),
    );
    try std.testing.expectError(
        error.InvalidCallback,
        oauth.buildAuthorizationCodeBody(&buffer, &code, &attempt.verifier, 0),
    );
}

const Accepted = struct {
    access: []const u8,
    refresh: []const u8,
    expires_at: i64,
};

const Expected = union(enum) {
    accept: Accepted,
    reject: anyerror,
};

const TokenCase = struct {
    body: []const u8,
    expected: Expected,
};

fn ok(access: []const u8, refresh: []const u8, expires_at: i64) Expected {
    return .{ .accept = .{ .access = access, .refresh = refresh, .expires_at = expires_at } };
}

fn no(err: anyerror) Expected {
    return .{ .reject = err };
}

fn token(comptime members: []const u8) []const u8 {
    return "{" ++ members ++ "}";
}

const base = "\"access_token\":\"a\",\"refresh_token\":\"r\",\"token_type\":\"Bearer\"";
const x4096 = "x" ** 4096;
const x4097 = "x" ** 4097;

fn padded(comptime total: usize) []const u8 {
    const prefix = "{" ++ base ++ ",\"expires_in\":60,\"pad\":\"";
    const suffix = "\"}";
    return prefix ++ "p" ** (total - prefix.len - suffix.len) ++ suffix;
}

const token_cases = [_]TokenCase{
    // Accepted shapes.
    .{ .body = token(base ++ ",\"expires_in\":3600"), .expected = ok("a", "r", 3700) },
    .{ .body = token(base ++ ",\"expires_in\":3600,\"gateway_url\":\"x\",\"nested\":{\"k\":[1,2]}"), .expected = ok("a", "r", 3700) },
    .{ .body = token(base ++ ",\"expires_in\":1,\"x\":1,\"x\":2"), .expected = ok("a", "r", 101) },
    .{ .body = token("\"access_token\":\"a\\u0062c\",\"refresh_token\":\"r\\u0065f\",\"token_type\":\"Bearer\",\"expires_in\":1"), .expected = ok("abc", "ref", 101) },
    // refresh_token.
    .{ .body = token("\"access_token\":\"a\",\"token_type\":\"Bearer\",\"expires_in\":1"), .expected = no(error.InvalidTokenResponse) },
    .{ .body = token("\"access_token\":\"a\",\"refresh_token\":null,\"token_type\":\"Bearer\",\"expires_in\":1"), .expected = no(error.InvalidTokenResponse) },
    .{ .body = token("\"access_token\":\"a\",\"refresh_token\":\"\",\"token_type\":\"Bearer\",\"expires_in\":1"), .expected = no(error.MissingRefreshToken) },
    .{ .body = token("\"access_token\":\"a\",\"refresh_token\":42,\"token_type\":\"Bearer\",\"expires_in\":1"), .expected = no(error.InvalidTokenResponse) },
    // expires_in.
    .{ .body = token(base), .expected = no(error.InvalidTokenResponse) },
    .{ .body = token(base ++ ",\"expires_in\":null"), .expected = no(error.InvalidTokenResponse) },
    .{ .body = token(base ++ ",\"expires_in\":0"), .expected = no(error.InvalidTokenResponse) },
    .{ .body = token(base ++ ",\"expires_in\":-1"), .expected = no(error.InvalidTokenResponse) },
    .{ .body = token(base ++ ",\"expires_in\":1.5"), .expected = no(error.InvalidTokenResponse) },
    .{ .body = token(base ++ ",\"expires_in\":\"3600\""), .expected = ok("a", "r", 3700) },
    .{ .body = token(base ++ ",\"expires_in\":3600.0"), .expected = ok("a", "r", 3700) },
    .{ .body = token(base ++ ",\"expires_in\":3.6e3"), .expected = ok("a", "r", 3700) },
    .{ .body = token(base ++ ",\"expires_in\":\"0\""), .expected = no(error.InvalidTokenResponse) },
    .{ .body = token(base ++ ",\"expires_in\":9223372036854775707"), .expected = ok("a", "r", std.math.maxInt(i64)) },
    .{ .body = token(base ++ ",\"expires_in\":9223372036854775708"), .expected = no(error.ExpiryOverflow) },
    .{ .body = token(base ++ ",\"expires_in\":9223372036854775807"), .expected = no(error.ExpiryOverflow) },
    .{ .body = token(base ++ ",\"expires_in\":9223372036854775808"), .expected = no(error.InvalidTokenResponse) },
    .{ .body = token(base ++ ",\"expires_in\":18446744073709551616"), .expected = no(error.InvalidTokenResponse) },
    // token_type.
    .{ .body = token("\"access_token\":\"a\",\"refresh_token\":\"r\",\"token_type\":\"bearer\",\"expires_in\":1"), .expected = ok("a", "r", 101) },
    .{ .body = token("\"access_token\":\"a\",\"refresh_token\":\"r\",\"token_type\":\"BEARER\",\"expires_in\":1"), .expected = ok("a", "r", 101) },
    .{ .body = token("\"access_token\":\"a\",\"refresh_token\":\"r\",\"token_type\":\"mac\",\"expires_in\":1"), .expected = no(error.InvalidTokenResponse) },
    .{ .body = token("\"access_token\":\"a\",\"refresh_token\":\"r\",\"expires_in\":1"), .expected = no(error.InvalidTokenResponse) },
    .{ .body = token("\"access_token\":\"a\",\"refresh_token\":\"r\",\"token_type\":1,\"expires_in\":1"), .expected = no(error.InvalidTokenResponse) },
    // access_token.
    .{ .body = token("\"refresh_token\":\"r\",\"token_type\":\"Bearer\",\"expires_in\":1"), .expected = no(error.InvalidTokenResponse) },
    .{ .body = token("\"access_token\":\"\",\"refresh_token\":\"r\",\"token_type\":\"Bearer\",\"expires_in\":1"), .expected = no(error.InvalidTokenResponse) },
    .{ .body = token("\"access_token\":\"" ++ x4096 ++ "\",\"refresh_token\":\"r\",\"token_type\":\"Bearer\",\"expires_in\":1"), .expected = ok(x4096, "r", 101) },
    .{ .body = token("\"access_token\":\"" ++ x4097 ++ "\",\"refresh_token\":\"r\",\"token_type\":\"Bearer\",\"expires_in\":1"), .expected = no(error.FieldTooLarge) },
    .{ .body = token("\"access_token\":\"a\",\"refresh_token\":\"" ++ x4096 ++ "\",\"token_type\":\"Bearer\",\"expires_in\":1"), .expected = ok("a", x4096, 101) },
    .{ .body = token("\"access_token\":\"a\",\"refresh_token\":\"" ++ x4097 ++ "\",\"token_type\":\"Bearer\",\"expires_in\":1"), .expected = no(error.FieldTooLarge) },
    .{ .body = token("\"access_token\":\"a\",\"access_token\":\"b\",\"refresh_token\":\"r\",\"token_type\":\"Bearer\",\"expires_in\":1"), .expected = no(error.InvalidTokenResponse) },
    // scope.
    .{ .body = token(base ++ ",\"expires_in\":1,\"scope\":\"read model:invoke\""), .expected = ok("a", "r", 101) },
    .{ .body = token(base ++ ",\"expires_in\":1,\"scope\":\"model:invoke read\""), .expected = ok("a", "r", 101) },
    .{ .body = token(base ++ ",\"expires_in\":1,\"scope\":\"read read model:invoke\""), .expected = ok("a", "r", 101) },
    .{ .body = token(base ++ ",\"expires_in\":1,\"scope\":\"read\""), .expected = no(error.InvalidTokenResponse) },
    .{ .body = token(base ++ ",\"expires_in\":1,\"scope\":null"), .expected = no(error.InvalidTokenResponse) },
    .{ .body = token(base ++ ",\"expires_in\":1,\"scope\":42"), .expected = no(error.InvalidTokenResponse) },
    .{ .body = token(base ++ ",\"expires_in\":1,\"scope\":\"read model:invoke\",\"scope\":\"read model:invoke\""), .expected = no(error.InvalidTokenResponse) },
    // Body bounds and shape.
    .{ .body = padded(oauth.Limits.token_body_bytes), .expected = ok("a", "r", 160) },
    .{ .body = padded(oauth.Limits.token_body_bytes + 1), .expected = no(error.InvalidTokenResponse) },
    .{ .body = "", .expected = no(error.InvalidTokenResponse) },
    .{ .body = "not json", .expected = no(error.InvalidTokenResponse) },
    .{ .body = "[]", .expected = no(error.InvalidTokenResponse) },
    .{ .body = "null", .expected = no(error.InvalidTokenResponse) },
    .{ .body = token(base ++ ",\"expires_in\":1") ++ " x", .expected = no(error.InvalidTokenResponse) },
    // Check order when several rules fail at once.
    .{ .body = token("\"access_token\":\"a\",\"token_type\":\"Bearer\",\"expires_in\":9223372036854775807"), .expected = no(error.InvalidTokenResponse) },
    .{ .body = token("\"access_token\":\"" ++ x4097 ++ "\",\"refresh_token\":\"r\",\"token_type\":\"Bearer\",\"expires_in\":9223372036854775807"), .expected = no(error.ExpiryOverflow) },
    .{ .body = token("\"access_token\":\"a\",\"refresh_token\":\"\",\"token_type\":\"Bearer\",\"expires_in\":1,\"scope\":\"read\""), .expected = no(error.MissingRefreshToken) },
    .{ .body = token("\"access_token\":\"" ++ x4097 ++ "\",\"refresh_token\":\"\",\"token_type\":\"Bearer\",\"expires_in\":1"), .expected = no(error.FieldTooLarge) },
    .{ .body = token("\"access_token\":\"a\",\"refresh_token\":\"" ++ x4097 ++ "\",\"token_type\":\"Bearer\",\"expires_in\":1,\"scope\":\"read\""), .expected = no(error.FieldTooLarge) },
    .{ .body = token("\"access_token\":\"a\",\"refresh_token\":\"\",\"token_type\":\"mac\",\"expires_in\":1"), .expected = no(error.InvalidTokenResponse) },
    .{ .body = token("\"access_token\":\"" ++ x4097 ++ "\",\"refresh_token\":\"r\",\"token_type\":\"Bearer\",\"expires_in\":0"), .expected = no(error.InvalidTokenResponse) },
    .{ .body = token("\"access_token\":\"a\",\"refresh_token\":\"r\",\"token_type\":\"Bearer\",\"expires_in\":9223372036854775808,\"scope\":\"read\""), .expected = no(error.InvalidTokenResponse) },
};

test "Account token response acceptance" {
    for (token_cases, 0..) |case, index| {
        errdefer std.debug.print("token case {d}: {s}\n", .{ index, case.body[0..@min(case.body.len, 160)] });
        switch (case.expected) {
            .accept => |expected| {
                var tokens = try oauth.parseTokenResponse(std.testing.allocator, case.body, now);
                defer tokens.deinit();
                try std.testing.expectEqualStrings(expected.access, tokens.access_token.view());
                try std.testing.expectEqualStrings(expected.refresh, tokens.refresh_token.view());
                try std.testing.expectEqual(expected.expires_at, tokens.expires_at);
            },
            .reject => |expected| try std.testing.expectError(
                expected,
                oauth.parseTokenResponse(std.testing.allocator, case.body, now),
            ),
        }
    }
}

const ErrorCase = struct {
    status: u16,
    body: []const u8,
    expected: client.ClientError,
};

fn errorPadded(comptime total: usize) []const u8 {
    const prefix = "{\"error\":\"invalid_grant\",\"pad\":\"";
    const suffix = "\"}";
    return prefix ++ "p" ** (total - prefix.len - suffix.len) ++ suffix;
}

const refresh_error_cases = [_]ErrorCase{
    .{ .status = 400, .body = "{\"error\":\"invalid_grant\",\"extra\":{\"nested\":[1]}}", .expected = error.Unauthorized },
    .{ .status = 400, .body = "{\"error\":\"invalid\\u005fgrant\"}", .expected = error.Unauthorized },
    .{ .status = 400, .body = "{\"error\":\"invalid_grant\",\"error\":\"invalid_request\"}", .expected = error.ProtocolInvalid },
    .{ .status = 400, .body = "{\"error\":null}", .expected = error.ProtocolInvalid },
    .{ .status = 400, .body = "[\"invalid_grant\"]", .expected = error.ProtocolInvalid },
    .{ .status = 400, .body = "", .expected = error.ProtocolInvalid },
    .{ .status = 400, .body = "{\"error\":\"INVALID_GRANT\"}", .expected = error.ProtocolInvalid },
    .{ .status = 400, .body = errorPadded(16 * 1024), .expected = error.Unauthorized },
    .{ .status = 400, .body = "{\"error\":\"invalid_scope\",\"error_description\":\"x\"}", .expected = error.TokenRefreshFailed },
    .{ .status = 401, .body = "{\"error\":\"invalid_client\",\"x\":1}", .expected = error.TokenRefreshFailed },
    .{ .status = 401, .body = "{\"error\":\"invalid_grant\"}", .expected = error.ProtocolInvalid },
    .{ .status = 429, .body = "{\"error\":\"invalid_grant\"}", .expected = error.RateLimited },
};

const identity_error_cases = [_]ErrorCase{
    .{ .status = 401, .body = "{\"error\":\"user_not_found\",\"error_description\":\"x\"}", .expected = error.Unauthorized },
    .{ .status = 401, .body = "{\"error\":\"authorization_revoked\",\"error\":\"authorization_revoked\"}", .expected = error.ProtocolInvalid },
    .{ .status = 401, .body = "{\"error\":\"authorization\\u005frevoked\"}", .expected = error.Unauthorized },
    .{ .status = 401, .body = "{\"error\":7}", .expected = error.ProtocolInvalid },
    .{ .status = 403, .body = "{\"error\":\"user_not_found\"}", .expected = error.ProtocolInvalid },
};

const ErrorTransport = struct {
    status: u16,
    body: []const u8,

    fn perform(
        context: *anyopaque,
        _: client.Request,
        output: []u8,
    ) client.TransportError!client.Response {
        const self: *ErrorTransport = @ptrCast(@alignCast(context));
        if (self.body.len > output.len) return error.ResponseTooLarge;
        @memcpy(output[0..self.body.len], self.body);
        return .{ .status = self.status, .body = output[0..self.body.len] };
    }

    fn transport(self: *ErrorTransport) client.Transport {
        return .{ .context = self, .perform_fn = perform, .retire_fn = client.retireNothing };
    }
};

test "Account OAuth error classification" {
    var refresh = try oauth.Secret.init(std.testing.allocator, "retained-refresh");
    defer refresh.deinit();
    for (refresh_error_cases, 0..) |case, index| {
        errdefer std.debug.print("refresh error case {d}\n", .{index});
        var fake: ErrorTransport = .{ .status = case.status, .body = case.body };
        try std.testing.expectError(case.expected, client.refreshWithToken(
            std.testing.allocator,
            fake.transport(),
            &refresh,
            null,
            now,
            null,
        ));
    }
    for (identity_error_cases, 0..) |case, index| {
        errdefer std.debug.print("identity error case {d}\n", .{index});
        var fake: ErrorTransport = .{ .status = case.status, .body = case.body };
        try std.testing.expectError(case.expected, client.fetchIdentity(fake.transport(), "access", null));
    }
}
