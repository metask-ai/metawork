//! MCP OAuth wire pins: authorization URL, token request and client
//! authentication bytes, token response acceptance and OAuth error
//! classification, exactly as observed at the MCP effect boundary. Any change
//! to these results is a behavior change.
const std = @import("std");
const mcp = @import("mcp_oauth.zig");

const AttemptMaterial = @FieldType(mcp.AuthorizationAttempt, "material");

const now_ms: u64 = 1000;
const redirect = "http://127.0.0.1:49152/auth/callback";
const resource = "https://mcp.example.test/mcp/v1?tenant=a&x=y";
const reserved_value = "c0de -._~+/%?&=\x00\x7f\xff\xe4\xb8\xad";

fn material() AttemptMaterial {
    return AttemptMaterial.fromSeeds(@splat(0x11), @splat(0x22));
}

fn authorizationServer(
    methods: []const mcp.TokenEndpointAuthMethod,
    authorization_endpoint: []const u8,
) !mcp.AuthorizationServer {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    errdefer arena.deinit();
    const owned = try arena.allocator().dupe(mcp.TokenEndpointAuthMethod, methods);
    return .{
        .arena = arena,
        .issuer = "https://auth.example.test",
        .authorization_endpoint = authorization_endpoint,
        .token_endpoint = "https://auth.example.test/token",
        .registration_endpoint = "https://auth.example.test/register",
        .scopes_supported = &.{},
        .token_endpoint_auth_methods = owned,
        .refresh_token_supported = true,
        .authorization_response_issuer_required = false,
        .client_id_metadata_document_supported = false,
    };
}

test "MCP authorization URL bytes" {
    const attempt = material();
    var plain = try authorizationServer(&.{.none}, "https://auth.example.test/authorize");
    defer plain.deinit();
    var with_query = try authorizationServer(&.{.none}, "https://auth.example.test/authorize?prompt=consent");
    defer with_query.deinit();
    var buffer: [8192]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://auth.example.test/authorize?response_type=code&client_id=client%20id%2F%2B&redirect_uri=http%3A%2F%2F127.0.0.1%3A49152%2Fauth%2Fcallback&scope=files%3Aread%20openid&state=IiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiI&code_challenge=tZ5lxAKmKebFsoNVx2KKEAImK1W0OlL5QcAnQOO9-vw&code_challenge_method=S256&resource=https%3A%2F%2Fmcp.example.test%2Fmcp%2Fv1%3Ftenant%3Da%26x%3Dy",
        try mcp.buildAuthorizationUrl(&buffer, &plain, "client id/+", redirect, resource, &.{ "files:read", "openid" }, &attempt),
    );
    try std.testing.expectEqualStrings(
        "https://auth.example.test/authorize?prompt=consent&response_type=code&client_id=client&redirect_uri=http%3A%2F%2F127.0.0.1%3A49152%2Fauth%2Fcallback&state=IiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiI&code_challenge=tZ5lxAKmKebFsoNVx2KKEAImK1W0OlL5QcAnQOO9-vw&code_challenge_method=S256&resource=https%3A%2F%2Fmcp.example.test%2Fmcp%2Fv1%3Ftenant%3Da%26x%3Dy",
        try mcp.buildAuthorizationUrl(&buffer, &with_query, "client", redirect, resource, &.{}, &attempt),
    );
    const exact_len = (try mcp.buildAuthorizationUrl(&buffer, &plain, "client", redirect, resource, &.{"openid"}, &attempt)).len;
    var exact: [8192]u8 = undefined;
    _ = try mcp.buildAuthorizationUrl(exact[0..exact_len], &plain, "client", redirect, resource, &.{"openid"}, &attempt);
    try std.testing.expectError(
        error.InvalidAuthorizationRequest,
        mcp.buildAuthorizationUrl(exact[0 .. exact_len - 1], &plain, "client", redirect, resource, &.{"openid"}, &attempt),
    );
    try std.testing.expectError(
        error.InvalidAuthorizationRequest,
        mcp.buildAuthorizationUrl(&buffer, &plain, "c" ** 4000, redirect, resource, &.{}, &attempt),
    );
    try std.testing.expectError(
        error.InvalidAuthorizationRequest,
        mcp.buildAuthorizationUrl(&buffer, &plain, "client", redirect, resource, &.{ "openid", "files:read" }, &attempt),
    );
}

const Recorder = struct {
    response: mcp.Response,
    body: [32 * 1024]u8 = undefined,
    body_len: usize = 0,
    authorization: [1024]u8 = undefined,
    authorization_len: ?usize = null,
    header_count: usize = 0,

    fn fetch(
        context: ?*anyopaque,
        request: mcp.Request,
        _: []u8,
        _: []u8,
    ) mcp.FetchError!mcp.Response {
        const self: *Recorder = @ptrCast(@alignCast(context.?));
        @memcpy(self.body[0..request.body.len], request.body);
        self.body_len = request.body.len;
        self.header_count = request.headers.len;
        self.authorization_len = null;
        for (request.headers) |header| {
            if (!std.mem.eql(u8, header.name, "Authorization")) continue;
            @memcpy(self.authorization[0..header.value.len], header.value);
            self.authorization_len = header.value.len;
        }
        return self.response;
    }

    fn transport(self: *Recorder) mcp.Transport {
        return .{ .context = self, .fetch_fn = fetch };
    }

    fn sentBody(self: *const Recorder) []const u8 {
        return self.body[0..self.body_len];
    }

    fn sentAuthorization(self: *const Recorder) ?[]const u8 {
        return if (self.authorization_len) |len| self.authorization[0..len] else null;
    }
};

const minimal_success: mcp.Response = .{
    .status = 200,
    .content_type = "application/json",
    .body = "{\"access_token\":\"a\",\"token_type\":\"Bearer\"}",
};

const client_secret = "s3cr:t/+ &";

fn exchange(
    recorder: *Recorder,
    server: *const mcp.AuthorizationServer,
    secret: ?[]const u8,
    method: mcp.TokenEndpointAuthMethod,
) !mcp.TokenSet {
    const attempt = material();
    var code = try mcp.AuthorizationCode.init(std.testing.allocator, reserved_value);
    defer code.deinit();
    return mcp.exchangeAuthorizationCodeEffect(
        std.testing.allocator,
        recorder.transport(),
        server,
        "client id/+",
        secret,
        method,
        &code,
        &attempt.verifier,
        redirect,
        resource,
        now_ms,
        null,
    );
}

fn refresh(
    recorder: *Recorder,
    server: *const mcp.AuthorizationServer,
    secret: ?[]const u8,
    method: mcp.TokenEndpointAuthMethod,
) !mcp.TokenSet {
    return mcp.refreshAccessTokenEffect(
        std.testing.allocator,
        recorder.transport(),
        server,
        .{
            .issuer = "https://auth.example.test",
            .client_id = "client id/+",
            .token_endpoint_auth_method = method,
            .resource = resource,
            .consent_epoch = 3,
            .token_revision = 8,
        },
        secret,
        reserved_value,
        now_ms,
    );
}

test "MCP token request and client authentication bytes" {
    var server = try authorizationServer(&.{ .none, .client_secret_post, .client_secret_basic }, "https://auth.example.test/authorize");
    defer server.deinit();
    var recorder: Recorder = .{ .response = minimal_success };

    var tokens = try exchange(&recorder, &server, null, .none);
    tokens.deinit();
    try std.testing.expectEqualStrings("grant_type=authorization_code&client_id=client%20id%2F%2B&code=c0de%20-._~%2B%2F%25%3F%26%3D%00%7F%FF%E4%B8%AD&code_verifier=ERERERERERERERERERERERERERERERERERERERERERE&redirect_uri=http%3A%2F%2F127.0.0.1%3A49152%2Fauth%2Fcallback&resource=https%3A%2F%2Fmcp.example.test%2Fmcp%2Fv1%3Ftenant%3Da%26x%3Dy", recorder.sentBody());
    try std.testing.expectEqual(@as(usize, 2), recorder.header_count);
    try std.testing.expectEqual(@as(?[]const u8, null), recorder.sentAuthorization());

    tokens = try exchange(&recorder, &server, client_secret, .client_secret_post);
    tokens.deinit();
    try std.testing.expectEqualStrings("grant_type=authorization_code&client_id=client%20id%2F%2B&code=c0de%20-._~%2B%2F%25%3F%26%3D%00%7F%FF%E4%B8%AD&code_verifier=ERERERERERERERERERERERERERERERERERERERERERE&redirect_uri=http%3A%2F%2F127.0.0.1%3A49152%2Fauth%2Fcallback&resource=https%3A%2F%2Fmcp.example.test%2Fmcp%2Fv1%3Ftenant%3Da%26x%3Dy&client_secret=s3cr%3At%2F%2B%20%26", recorder.sentBody());
    try std.testing.expectEqual(@as(usize, 2), recorder.header_count);

    tokens = try exchange(&recorder, &server, client_secret, .client_secret_basic);
    tokens.deinit();
    try std.testing.expectEqualStrings("grant_type=authorization_code&client_id=client%20id%2F%2B&code=c0de%20-._~%2B%2F%25%3F%26%3D%00%7F%FF%E4%B8%AD&code_verifier=ERERERERERERERERERERERERERERERERERERERERERE&redirect_uri=http%3A%2F%2F127.0.0.1%3A49152%2Fauth%2Fcallback&resource=https%3A%2F%2Fmcp.example.test%2Fmcp%2Fv1%3Ftenant%3Da%26x%3Dy", recorder.sentBody());
    try std.testing.expectEqual(@as(usize, 3), recorder.header_count);
    try std.testing.expectEqualStrings("Basic Y2xpZW50JTIwaWQlMkYlMkI6czNjciUzQXQlMkYlMkIlMjAlMjY=", recorder.sentAuthorization().?);

    tokens = try refresh(&recorder, &server, null, .none);
    tokens.deinit();
    try std.testing.expectEqualStrings("grant_type=refresh_token&client_id=client%20id%2F%2B&refresh_token=c0de%20-._~%2B%2F%25%3F%26%3D%00%7F%FF%E4%B8%AD&resource=https%3A%2F%2Fmcp.example.test%2Fmcp%2Fv1%3Ftenant%3Da%26x%3Dy", recorder.sentBody());
    try std.testing.expectEqual(@as(usize, 2), recorder.header_count);

    tokens = try refresh(&recorder, &server, client_secret, .client_secret_post);
    tokens.deinit();
    try std.testing.expectEqualStrings("grant_type=refresh_token&client_id=client%20id%2F%2B&refresh_token=c0de%20-._~%2B%2F%25%3F%26%3D%00%7F%FF%E4%B8%AD&resource=https%3A%2F%2Fmcp.example.test%2Fmcp%2Fv1%3Ftenant%3Da%26x%3Dy&client_secret=s3cr%3At%2F%2B%20%26", recorder.sentBody());

    tokens = try refresh(&recorder, &server, client_secret, .client_secret_basic);
    tokens.deinit();
    try std.testing.expectEqualStrings("grant_type=refresh_token&client_id=client%20id%2F%2B&refresh_token=c0de%20-._~%2B%2F%25%3F%26%3D%00%7F%FF%E4%B8%AD&resource=https%3A%2F%2Fmcp.example.test%2Fmcp%2Fv1%3Ftenant%3Da%26x%3Dy", recorder.sentBody());
    try std.testing.expectEqualStrings("Basic Y2xpZW50JTIwaWQlMkYlMkI6czNjciUzQXQlMkYlMkIlMjAlMjY=", recorder.sentAuthorization().?);
}

const Accepted = struct {
    access: []const u8,
    refresh: ?[]const u8,
    expires_at_unix_ms: ?u64,
};

const Expected = union(enum) {
    accept: Accepted,
    reject: anyerror,
};

const TokenCase = struct {
    status: u16 = 200,
    content_type: ?[]const u8 = "application/json",
    body: []const u8,
    expected: Expected,
};

fn ok(access: []const u8, refresh_token: ?[]const u8, expires_at_unix_ms: ?u64) Expected {
    return .{ .accept = .{ .access = access, .refresh = refresh_token, .expires_at_unix_ms = expires_at_unix_ms } };
}

const unknown: Expected = .{ .reject = error.TokenOutcomeUnknown };
const invalid_grant: Expected = .{ .reject = error.InvalidGrant };

fn token(comptime members: []const u8) []const u8 {
    return "{" ++ members ++ "}";
}

const base = "\"access_token\":\"a\",\"token_type\":\"Bearer\"";
const x16000 = "x" ** 16000;
const y16000 = "y" ** 16000;
const x16384 = "x" ** 16384;
const x16385 = "x" ** 16385;

fn padded(comptime prefix: []const u8, comptime total: usize) []const u8 {
    const suffix = "\"}";
    return prefix ++ "p" ** (total - prefix.len - suffix.len) ++ suffix;
}

const token_cases = [_]TokenCase{
    // Accepted shapes.
    .{ .body = token(base), .expected = ok("a", null, null) },
    .{ .body = token(base ++ ",\"refresh_token\":\"r\",\"expires_in\":60"), .expected = ok("a", "r", 61_000) },
    .{ .body = token(base ++ ",\"x\":1,\"x\":2,\"nested\":{\"k\":[1,2]}"), .expected = ok("a", null, null) },
    .{ .body = token("\"access_token\":\"a\\u0062c\",\"refresh_token\":\"r\\u0065f\",\"token_type\":\"Bearer\""), .expected = ok("abc", "ref", null) },
    // refresh_token.
    .{ .body = token(base ++ ",\"refresh_token\":null"), .expected = ok("a", null, null) },
    .{ .body = token(base ++ ",\"refresh_token\":\"\""), .expected = unknown },
    .{ .body = token(base ++ ",\"refresh_token\":42"), .expected = unknown },
    .{ .body = token(base ++ ",\"refresh_token\":\"r\\u0000\""), .expected = unknown },
    .{ .body = token(base ++ ",\"refresh_token\":\"" ++ x16384 ++ "\""), .expected = ok("a", x16384, null) },
    .{ .body = token(base ++ ",\"refresh_token\":\"" ++ x16385 ++ "\""), .expected = unknown },
    // expires_in.
    .{ .body = token(base ++ ",\"expires_in\":null"), .expected = ok("a", null, null) },
    .{ .body = token(base ++ ",\"expires_in\":0"), .expected = unknown },
    .{ .body = token(base ++ ",\"expires_in\":-1"), .expected = unknown },
    .{ .body = token(base ++ ",\"expires_in\":1.5"), .expected = unknown },
    .{ .body = token(base ++ ",\"expires_in\":\"60\""), .expected = ok("a", null, 61_000) },
    .{ .body = token(base ++ ",\"expires_in\":60.0"), .expected = ok("a", null, 61_000) },
    .{ .body = token(base ++ ",\"expires_in\":6e1"), .expected = ok("a", null, 61_000) },
    .{ .body = token(base ++ ",\"expires_in\":\"0\""), .expected = unknown },
    .{ .body = token(base ++ ",\"expires_in\":18446744073709550"), .expected = ok("a", null, 18_446_744_073_709_551_000) },
    .{ .body = token(base ++ ",\"expires_in\":18446744073709551"), .expected = unknown },
    .{ .body = token(base ++ ",\"expires_in\":18446744073709551615"), .expected = unknown },
    .{ .body = token(base ++ ",\"expires_in\":18446744073709551616"), .expected = unknown },
    // token_type.
    .{ .body = token("\"access_token\":\"a\",\"token_type\":\"bearer\""), .expected = ok("a", null, null) },
    .{ .body = token("\"access_token\":\"a\",\"token_type\":\"BEARER\""), .expected = ok("a", null, null) },
    .{ .body = token("\"access_token\":\"a\",\"token_type\":\"mac\""), .expected = unknown },
    .{ .body = token("\"access_token\":\"a\""), .expected = unknown },
    .{ .body = token("\"access_token\":\"a\",\"token_type\":1"), .expected = unknown },
    // access_token.
    .{ .body = token("\"token_type\":\"Bearer\""), .expected = unknown },
    .{ .body = token("\"access_token\":\"\",\"token_type\":\"Bearer\""), .expected = unknown },
    .{ .body = token("\"access_token\":\"a\\r\\nb\",\"token_type\":\"Bearer\""), .expected = unknown },
    .{ .body = token("\"access_token\":\"a\\u007f\",\"token_type\":\"Bearer\""), .expected = unknown },
    .{ .body = token("\"access_token\":\"a\x7f\",\"token_type\":\"Bearer\""), .expected = unknown },
    .{ .body = token("\"access_token\":\"a\\tb\",\"token_type\":\"Bearer\""), .expected = ok("a\tb", null, null) },
    .{ .body = token("\"access_token\":\"" ++ x16384 ++ "\",\"token_type\":\"Bearer\""), .expected = ok(x16384, null, null) },
    .{ .body = token("\"access_token\":\"" ++ x16385 ++ "\",\"token_type\":\"Bearer\""), .expected = unknown },
    .{ .body = token("\"access_token\":\"a\",\"access_token\":\"b\",\"token_type\":\"Bearer\""), .expected = unknown },
    // Both tokens near the secret limit inside the 32 KiB body.
    .{ .body = token("\"access_token\":\"" ++ x16000 ++ "\",\"refresh_token\":\"" ++ y16000 ++ "\",\"token_type\":\"Bearer\""), .expected = ok(x16000, y16000, null) },
    // Escaped near-limit tokens exhaust the fixed parse scratch; measured as rejected.
    .{ .body = token("\"access_token\":\"\\u0078" ++ x16000[1..] ++ "\",\"refresh_token\":\"\\u0079" ++ y16000[1..] ++ "\",\"token_type\":\"Bearer\""), .expected = unknown },
    // scope is not consumed.
    .{ .body = token(base ++ ",\"scope\":null"), .expected = ok("a", null, null) },
    .{ .body = token(base ++ ",\"scope\":42"), .expected = ok("a", null, null) },
    .{ .body = token(base ++ ",\"scope\":{}"), .expected = ok("a", null, null) },
    .{ .body = token(base ++ ",\"scope\":\"a\",\"scope\":\"b\""), .expected = ok("a", null, null) },
    // Body bounds and shape.
    .{ .body = padded("{" ++ base ++ ",\"pad\":\"", 32 * 1024), .expected = ok("a", null, null) },
    .{ .body = padded("{" ++ base ++ ",\"pad\":\"", 32 * 1024 + 1), .expected = unknown },
    .{ .body = "", .expected = unknown },
    .{ .body = "not json", .expected = unknown },
    .{ .body = "[]", .expected = unknown },
    .{ .body = token(base) ++ " x", .expected = unknown },
    // A body that parses is accepted whatever its Content-Type says.
    .{ .content_type = "text/plain", .body = token(base), .expected = ok("a", null, null) },
    .{ .content_type = null, .body = token(base), .expected = ok("a", null, null) },
    // OAuth error responses.
    .{ .status = 400, .body = "{\"error\":\"invalid_grant\"}", .expected = invalid_grant },
    .{ .status = 400, .body = "{\"error\":\"invalid_grant\",\"error_description\":\"x\",\"extra\":{\"k\":[1]}}", .expected = invalid_grant },
    .{ .status = 400, .body = "{\"error\":\"invalid\\u005fgrant\"}", .expected = invalid_grant },
    .{ .status = 400, .content_type = "text/plain", .body = "{\"error\":\"invalid_grant\"}", .expected = invalid_grant },
    .{ .status = 400, .body = padded("{\"error\":\"invalid_grant\",\"pad\":\"", 32 * 1024), .expected = invalid_grant },
    .{ .status = 400, .body = padded("{\"error\":\"invalid_grant\",\"pad\":\"", 32 * 1024 + 1), .expected = unknown },
    .{ .status = 400, .body = "{\"error\":\"invalid_grant\",\"error\":\"invalid_grant\"}", .expected = unknown },
    .{ .status = 400, .body = "{\"error\":\"invalid_request\"}", .expected = unknown },
    .{ .status = 400, .body = "{\"error\":null}", .expected = unknown },
    .{ .status = 400, .body = "not json", .expected = unknown },
    .{ .status = 401, .body = "{\"error\":\"invalid_grant\"}", .expected = unknown },
};

test "MCP token response acceptance through exchange and refresh" {
    var server = try authorizationServer(&.{.none}, "https://auth.example.test/authorize");
    defer server.deinit();
    for (token_cases, 0..) |case, index| {
        errdefer std.debug.print("token case {d}: {s}\n", .{ index, case.body[0..@min(case.body.len, 160)] });
        var recorder: Recorder = .{ .response = .{
            .status = case.status,
            .content_type = case.content_type,
            .body = case.body,
        } };
        for (0..2) |path| {
            const result = if (path == 0)
                exchange(&recorder, &server, null, .none)
            else
                refresh(&recorder, &server, null, .none);
            switch (case.expected) {
                .accept => |expected| {
                    var tokens = try result;
                    defer tokens.deinit();
                    try std.testing.expectEqualStrings(expected.access, tokens.access_token.view());
                    if (expected.refresh) |value| {
                        try std.testing.expectEqualStrings(value, tokens.refresh_token.?.view());
                    } else try std.testing.expect(tokens.refresh_token == null);
                    try std.testing.expectEqual(expected.expires_at_unix_ms, tokens.expires_at_unix_ms);
                },
                .reject => |expected| try std.testing.expectError(expected, result),
            }
        }
    }
}

const RegistrationCase = struct {
    content_type: ?[]const u8 = "application/json",
    body: []const u8,
    expected: anyerror,
};

const registration_cases = [_]RegistrationCase{
    .{ .body = "{\"error\":\"invalid_redirect_uri\"}", .expected = error.RegistrationRejected },
    .{ .body = "{\"error\":\"invalid_client_metadata\",\"error_description\":\"x\"}", .expected = error.RegistrationRejected },
    .{ .body = "{\"error\":\"invalid_software_statement\"}", .expected = error.RegistrationRejected },
    .{ .body = "{\"error\":\"unapproved_software_statement\"}", .expected = error.RegistrationRejected },
    .{ .body = "{\"error\":\"invalid\\u005fredirect_uri\"}", .expected = error.RegistrationRejected },
    .{ .body = padded("{\"error\":\"invalid_redirect_uri\",\"pad\":\"", 32 * 1024), .expected = error.RegistrationRejected },
    .{ .body = padded("{\"error\":\"invalid_redirect_uri\",\"pad\":\"", 32 * 1024 + 1), .expected = error.RegistrationOutcomeUnknown },
    .{ .body = "{\"error\":\"invalid_request\"}", .expected = error.RegistrationOutcomeUnknown },
    .{ .body = "{\"error\":\"invalid_redirect_uri\",\"error\":\"invalid_redirect_uri\"}", .expected = error.RegistrationOutcomeUnknown },
    // The error body decides, whatever its Content-Type says.
    .{ .content_type = "text/plain", .body = "{\"error\":\"invalid_redirect_uri\"}", .expected = error.RegistrationRejected },
};

test "MCP dynamic registration error classification" {
    var server = try authorizationServer(&.{.none}, "https://auth.example.test/authorize");
    defer server.deinit();
    for (registration_cases, 0..) |case, index| {
        errdefer std.debug.print("registration case {d}\n", .{index});
        var recorder: Recorder = .{ .response = .{
            .status = 400,
            .content_type = case.content_type,
            .body = case.body,
        } };
        try std.testing.expectError(case.expected, mcp.registerDynamicClientEffect(
            std.testing.allocator,
            recorder.transport(),
            &server,
            redirect,
            null,
        ));
    }
}
