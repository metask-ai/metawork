//! Product Account OAuth policy and value types.
const std = @import("std");
const contract = @import("metawork_account_contract");
const mechanics = @import("metawork_oauth_mechanics");

pub const authority = "https://www.metask-ai.com";
pub const authorize_url = authority ++ "/oauth/authorize";
pub const token_url = authority ++ "/api/oauth/token";
pub const userinfo_url = authority ++ "/api/oauth/userinfo";
pub const revoke_url = authority ++ "/api/oauth/revoke";
pub const client_id = "metawork";
pub const scope = "read model:invoke";
pub const callback_path = "/auth/metask/callback";

pub const Limits = struct {
    pub const secret_bytes: usize = 4096;
    pub const state_bytes: usize = 43;
    pub const verifier_bytes: usize = 43;
    pub const challenge_bytes: usize = 43;
    pub const authorization_url_bytes: usize = 4096;
    pub const callback_target_bytes: usize = 8192;
    pub const callback_error_bytes: usize = 256;
    pub const callback_error_description_bytes: usize = 4096;
    pub const token_body_bytes: usize = 16 * 1024;
    pub const current_user_body_bytes: usize = 16 * 1024;
    pub const authorization_id_bytes: usize = 256;
};

pub const ProtocolError = error{
    BufferTooSmall,
    InvalidEncoding,
    InvalidCallback,
    StateMismatch,
    AuthorizationRejected,
    InvalidTokenResponse,
    InvalidCurrentUserResponse,
    FieldTooLarge,
    ExpiryOverflow,
    MissingRefreshToken,
};

pub const Secret = mechanics.Secret(.{ .max_bytes = Limits.secret_bytes });

pub const AttemptMaterial = mechanics.AttemptMaterial;

pub fn writeRedirectUri(writer: *std.Io.Writer, port: u16) !void {
    if (port == 0) return error.InvalidCallback;
    try writer.print("http://localhost:{d}{s}", .{ port, callback_path });
}

pub fn buildAuthorizeUrl(
    output: []u8,
    port: u16,
    material: *const AttemptMaterial,
) ProtocolError![]const u8 {
    var redirect_storage: [128]u8 = undefined;
    var redirect_writer = std.Io.Writer.fixed(&redirect_storage);
    writeRedirectUri(&redirect_writer, port) catch return error.InvalidCallback;
    const callback_uri = redirect_writer.buffered();

    var writer = std.Io.Writer.fixed(output);
    mechanics.writeAuthorizationUrl(&writer, authorize_url, material, .{
        .client_id = client_id,
        .redirect_uri = callback_uri,
        .scope = scope,
    }) catch return error.BufferTooSmall;
    return writer.buffered();
}

pub const Callback = union(enum) {
    code: Secret,
    rejected: Refusal,

    pub fn deinit(self: *Callback) void {
        switch (self.*) {
            .code => |*value| value.deinit(),
            .rejected => {},
        }
        self.* = .{ .rejected = .{} };
    }
};

/// The authorization server's refusal (RFC 6749 section 4.1.2.1). Its
/// `error` is kept only when it is an error code as the RFC writes them
/// (lowercase letters and underscores); nothing else it said is kept.
pub const Refusal = struct {
    code_storage: [32]u8 = undefined,
    code_len: usize = 0,

    fn from(code_value: ?[]const u8) Refusal {
        var result: Refusal = .{};
        const value = code_value orelse return result;
        if (value.len > result.code_storage.len) return result;
        for (value) |byte| if (byte != '_' and (byte < 'a' or byte > 'z')) return result;
        @memcpy(result.code_storage[0..value.len], value);
        result.code_len = value.len;
        return result;
    }

    pub fn code(self: *const Refusal) ?[]const u8 {
        return if (self.code_len == 0) null else self.code_storage[0..self.code_len];
    }

    /// Only the person declining is a cancellation.
    pub fn declined(self: *const Refusal) bool {
        const value = self.code() orelse return false;
        return std.mem.eql(u8, value, "access_denied");
    }
};

pub fn parseCallbackTarget(
    allocator: std.mem.Allocator,
    target: []const u8,
    expected_state: []const u8,
) (ProtocolError || std.mem.Allocator.Error)!Callback {
    return parseCallbackTargetValidated(
        allocator,
        target,
        expected_state,
        .{},
    );
}

/// Product-neutral RFC 9207 callback validation used by MCP after it has
/// recorded an issuer from validated authorization-server metadata. Account
/// uses the same additive-parameter rules via `parseCallbackTarget`; it
/// neither requests nor interprets `iss`.
pub const CallbackValidation = struct {
    expected_issuer: ?[]const u8 = null,
    issuer_required: bool = false,
};

const CallbackMechanics = mechanics.CallbackParser(.{
    .secret_bytes = Limits.secret_bytes,
    .state_bytes = Limits.state_bytes,
    .target_bytes = Limits.callback_target_bytes,
    .issuer_bytes = Limits.authorization_url_bytes,
    .error_bytes = Limits.callback_error_bytes,
    .error_description_bytes = Limits.callback_error_description_bytes,
});

pub fn parseCallbackTargetValidated(
    allocator: std.mem.Allocator,
    target: []const u8,
    expected_state: []const u8,
    validation: CallbackValidation,
) (ProtocolError || std.mem.Allocator.Error)!Callback {
    var parsed = try CallbackMechanics.parse(
        allocator,
        target,
        expected_state,
        .{
            .callback_path = callback_path,
            .expected_issuer = validation.expected_issuer,
            .issuer_required = validation.issuer_required,
            // Metask does not request or interpret RFC 9207 `iss`, but it is
            // a known additive response parameter under the Account policy.
            .allow_unvalidated_issuer = true,
        },
    );
    defer parsed.deinit();
    return switch (parsed) {
        .code => |code| .{ .code = try Secret.init(allocator, code.view()) },
        .rejected => |rejection| .{ .rejected = .from(rejection.errorCode()) },
    };
}

pub const TokenSet = struct {
    access_token: Secret,
    refresh_token: Secret,
    expires_at: i64,

    pub fn deinit(self: *TokenSet) void {
        self.access_token.deinit();
        self.refresh_token.deinit();
        self.expires_at = 0;
    }

    pub fn take(self: *TokenSet) TokenSet {
        var result = self.*;
        result.access_token = self.access_token.take();
        result.refresh_token = self.refresh_token.take();
        self.expires_at = 0;
        return result;
    }
};

const TokenResponse = mechanics.TokenResponse(.{
    .body_bytes = Limits.token_body_bytes,
    .scope = .decoded,
});

pub fn parseTokenResponse(
    allocator: std.mem.Allocator,
    body: []const u8,
    now_unix_seconds: i64,
) (ProtocolError || std.mem.Allocator.Error)!TokenSet {
    var response: TokenResponse = .{};
    defer response.deinit();
    try response.decode(body);
    // Account requires both a refresh token and a lifetime it can store.
    const refresh_token = response.refresh_token orelse
        return error.InvalidTokenResponse;
    const expires_in = response.expires_in orelse
        return error.InvalidTokenResponse;
    if (expires_in > std.math.maxInt(i64))
        return error.InvalidTokenResponse;
    const expires_at = std.math.add(
        i64,
        now_unix_seconds,
        @intCast(expires_in),
    ) catch return error.ExpiryOverflow;
    if (expires_at < 0) return error.ExpiryOverflow;

    var result: TokenSet = .{
        .access_token = try Secret.init(allocator, response.access_token),
        .refresh_token = undefined,
        .expires_at = expires_at,
    };
    errdefer result.access_token.deinit();
    if (refresh_token.len == 0) return error.MissingRefreshToken;
    result.refresh_token = try Secret.init(allocator, refresh_token);
    errdefer result.refresh_token.deinit();

    switch (response.scope) {
        .absent => {},
        .text => |granted| if (!hasRequestedScope(granted))
            return error.InvalidTokenResponse,
    }
    return result;
}

// Account only admits the full scope it requested. OAuth scope order and
// repeated tokens do not change the granted set; names remain case-sensitive.
fn hasRequestedScope(value: []const u8) bool {
    var read = false;
    var invoke = false;
    var tokens = std.mem.splitScalar(u8, value, ' ');
    while (tokens.next()) |token| {
        if (std.mem.eql(u8, token, "read")) {
            read = true;
        } else if (std.mem.eql(u8, token, "model:invoke")) {
            invoke = true;
        } else return false;
    }
    return read and invoke;
}

pub const CurrentUser = struct {
    account_id: [contract.Limits.account_id_bytes]u8 = undefined,
    account_id_len: usize = 0,
    username: [contract.Limits.display_name_bytes]u8 = undefined,
    username_len: usize = 0,
    email_hint: [contract.Limits.email_hint_bytes]u8 = undefined,
    email_hint_len: usize = 0,
    phone_hint: [contract.Limits.phone_hint_bytes]u8 = undefined,
    phone_hint_len: usize = 0,
    concurrency_limit: ?u32 = null,

    pub fn accountId(self: *const CurrentUser) []const u8 {
        return self.account_id[0..self.account_id_len];
    }

    pub fn usernameView(self: *const CurrentUser) []const u8 {
        return self.username[0..self.username_len];
    }

    pub fn emailHintView(self: *const CurrentUser) []const u8 {
        return self.email_hint[0..self.email_hint_len];
    }

    pub fn phoneHintView(self: *const CurrentUser) []const u8 {
        return self.phone_hint[0..self.phone_hint_len];
    }
};

const CurrentUserResponse = struct {
    sub: []const u8,
    client_id: []const u8,
    authorization_id: []const u8,
    // These profile fields are deliberately dynamic: a missing or unusable
    // value must not make otherwise valid principal evidence fail login.
    name: std.json.Value = .null,
    email: std.json.Value = .null,
    email_verified: std.json.Value = .null,
    phone_number: std.json.Value = .null,
};

/// Metask gives a person who signed up by phone an address of this domain
/// that nobody verified; it is no address of theirs to show.
const phone_placeholder_domain = "@phone.metask-ai.com";

fn optionalText(output: []u8, value: std.json.Value) []const u8 {
    const text = switch (value) {
        .string => |text| text,
        else => return output[0..0],
    };
    if (text.len > output.len or !std.unicode.utf8ValidateSlice(text))
        return output[0..0];
    @memcpy(output[0..text.len], text);
    return output[0..text.len];
}

fn maskEmail(output: []u8, email: []const u8) ProtocolError![]const u8 {
    if (email.len == 0) return output[0..0];
    if (email.len > contract.Limits.email_bytes or
        !std.unicode.utf8ValidateSlice(email))
        return error.InvalidCurrentUserResponse;
    for (email) |byte| {
        if (byte < 0x20 or byte == 0x7f)
            return error.InvalidCurrentUserResponse;
    }
    const at = std.mem.lastIndexOfScalar(u8, email, '@') orelse
        return error.InvalidCurrentUserResponse;
    if (at == 0 or at + 1 >= email.len or
        std.mem.indexOfScalar(u8, email[0..at], '@') != null)
        return error.InvalidCurrentUserResponse;
    const first_len = std.unicode.utf8ByteSequenceLength(email[0]) catch
        return error.InvalidCurrentUserResponse;
    var writer = std.Io.Writer.fixed(output);
    writer.writeAll(email[0..first_len]) catch
        return error.InvalidCurrentUserResponse;
    writer.writeAll("***@") catch return error.InvalidCurrentUserResponse;
    writer.writeAll(email[at + 1 ..]) catch
        return error.InvalidCurrentUserResponse;
    return writer.buffered();
}

fn maskPhone(output: []u8, phone: []const u8) ProtocolError![]const u8 {
    if (phone.len == 0) return output[0..0];
    const digits = if (phone[0] == '+') phone[1..] else phone;
    if (digits.len < 7 or digits.len > 20)
        return error.InvalidCurrentUserResponse;
    // Metask sends the number already masked (`138****0000`): digits, one
    // run of asterisks, digits. It is shown as it came.
    if (std.mem.indexOfScalar(u8, digits, '*')) |first| {
        const last = std.mem.lastIndexOfScalar(u8, digits, '*').?;
        if (first == 0 or last + 1 == digits.len or phone.len > output.len)
            return error.InvalidCurrentUserResponse;
        for (digits, 0..) |byte, index| {
            const masked = index >= first and index <= last;
            if (if (masked) byte != '*' else (byte < '0' or byte > '9'))
                return error.InvalidCurrentUserResponse;
        }
        @memcpy(output[0..phone.len], phone);
        return output[0..phone.len];
    }
    for (digits) |byte| {
        if (byte < '0' or byte > '9')
            return error.InvalidCurrentUserResponse;
    }
    const prefix_len = @min(@as(usize, 3), digits.len - 4);
    var writer = std.Io.Writer.fixed(output);
    if (phone[0] == '+')
        writer.writeByte('+') catch return error.InvalidCurrentUserResponse;
    writer.writeAll(digits[0..prefix_len]) catch
        return error.InvalidCurrentUserResponse;
    writer.writeAll("****") catch return error.InvalidCurrentUserResponse;
    writer.writeAll(digits[digits.len - 4 ..]) catch
        return error.InvalidCurrentUserResponse;
    return writer.buffered();
}

pub fn parseCurrentUser(
    body: []const u8,
) ProtocolError!CurrentUser {
    if (body.len == 0 or body.len > Limits.current_user_body_bytes)
        return error.InvalidCurrentUserResponse;
    var scratch: [Limits.current_user_body_bytes * 2]u8 = undefined;
    defer std.crypto.secureZero(u8, &scratch);
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    var parsed = std.json.parseFromSlice(
        CurrentUserResponse,
        fba.allocator(),
        body,
        .{ .ignore_unknown_fields = true },
    ) catch return error.InvalidCurrentUserResponse;
    defer parsed.deinit();
    const raw = parsed.value;
    if (raw.sub.len == 0 or
        raw.sub.len > contract.Limits.account_id_bytes or
        !std.unicode.utf8ValidateSlice(raw.sub) or
        !std.mem.eql(u8, raw.client_id, client_id) or
        raw.authorization_id.len == 0 or
        raw.authorization_id.len > Limits.authorization_id_bytes or
        !std.unicode.utf8ValidateSlice(raw.authorization_id))
        return error.InvalidCurrentUserResponse;
    var result: CurrentUser = .{};
    @memcpy(result.account_id[0..raw.sub.len], raw.sub);
    result.account_id_len = raw.sub.len;
    const username = optionalText(&result.username, raw.name);
    result.username_len = username.len;
    const placeholder = switch (raw.email) {
        .string => |email| raw.email_verified == .bool and !raw.email_verified.bool and
            std.ascii.endsWithIgnoreCase(email, phone_placeholder_domain),
        else => false,
    };
    const email_hint = switch (raw.email) {
        .string => |email| if (placeholder)
            result.email_hint[0..0]
        else
            maskEmail(&result.email_hint, email) catch result.email_hint[0..0],
        else => result.email_hint[0..0],
    };
    result.email_hint_len = email_hint.len;
    const phone_hint = switch (raw.phone_number) {
        .string => |phone| maskPhone(&result.phone_hint, phone) catch result.phone_hint[0..0],
        else => result.phone_hint[0..0],
    };
    result.phone_hint_len = phone_hint.len;
    result.concurrency_limit = null;
    return result;
}

pub fn buildAuthorizationCodeBody(
    output: []u8,
    code: *const Secret,
    verifier: []const u8,
    port: u16,
) ProtocolError![]const u8 {
    var redirect_storage: [128]u8 = undefined;
    var redirect_writer = std.Io.Writer.fixed(&redirect_storage);
    writeRedirectUri(&redirect_writer, port) catch return error.InvalidCallback;
    var writer = std.Io.Writer.fixed(output);
    mechanics.writeAuthorizationCodeGrant(&writer, .{
        .client_id = client_id,
        .code = code.view(),
        .code_verifier = verifier,
        .redirect_uri = redirect_writer.buffered(),
    }) catch return error.BufferTooSmall;
    return writer.buffered();
}

pub fn buildRefreshBody(
    output: []u8,
    refresh_token: *const Secret,
) ProtocolError![]const u8 {
    var writer = std.Io.Writer.fixed(output);
    mechanics.writeRefreshTokenGrant(&writer, .{
        .client_id = client_id,
        .refresh_token = refresh_token.view(),
    }) catch return error.BufferTooSmall;
    return writer.buffered();
}

/// RFC 7009 revocation of a refresh token by this public client.
pub fn buildRevokeBody(output: []u8, refresh_token: *const Secret) ProtocolError![]const u8 {
    var writer = std.Io.Writer.fixed(output);
    const pairs = [_]struct { []const u8, []const u8 }{
        .{ "token", refresh_token.view() },
        .{ "token_type_hint", "refresh_token" },
        .{ "client_id", client_id },
    };
    for (pairs, 0..) |pair, index| {
        if (index != 0) writer.writeByte('&') catch return error.BufferTooSmall;
        mechanics.writeFormPair(&writer, pair[0], pair[1]) catch return error.BufferTooSmall;
    }
    return writer.buffered();
}

test "PKCE authorize URL carries the dynamically assigned loopback port" {
    const callback_port: u16 = 49152;
    const material = AttemptMaterial.fromSeeds(
        @splat(0x11),
        @splat(0x22),
    );
    try std.testing.expectEqual(Limits.verifier_bytes, material.verifier.len);
    try std.testing.expectEqual(Limits.state_bytes, material.state.len);
    try std.testing.expectEqual(Limits.challenge_bytes, material.challenge.len);
    var buffer: [Limits.authorization_url_bytes]u8 = undefined;
    const url = try buildAuthorizeUrl(&buffer, callback_port, &material);
    try std.testing.expect(std.mem.startsWith(u8, url, authorize_url ++ "?"));
    try std.testing.expect(std.mem.indexOf(u8, url, "scope=read%20model%3Ainvoke&") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        url,
        "redirect_uri=http%3A%2F%2Flocalhost%3A49152%2Fauth%2Fmetask%2Fcallback",
    ) != null);
    try std.testing.expect(std.mem.endsWith(
        u8,
        url,
        "code_challenge_method=S256",
    ));
    try std.testing.expectError(
        error.InvalidCallback,
        buildAuthorizeUrl(&buffer, 0, &material),
    );

    const another_url = try buildAuthorizeUrl(
        &buffer,
        callback_port + 1,
        &material,
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        another_url,
        "redirect_uri=http%3A%2F%2Flocalhost%3A49153%2Fauth%2Fmetask%2Fcallback",
    ) != null);
}

test "callback parser rejects wrong path duplicates and state mismatch" {
    const expected = "0123456789012345678901234567890123456789012";
    var callback = try parseCallbackTarget(
        std.testing.allocator,
        callback_path ++ "?code=secret-code&state=" ++ expected,
        expected,
    );
    defer callback.deinit();
    try std.testing.expectEqualStrings(
        "secret-code",
        callback.code.view(),
    );
    try std.testing.expectError(
        error.StateMismatch,
        parseCallbackTarget(
            std.testing.allocator,
            callback_path ++ "?code=secret-code&state=wrong",
            expected,
        ),
    );
    try std.testing.expectError(
        error.InvalidCallback,
        parseCallbackTarget(
            std.testing.allocator,
            "/wrong?code=secret-code&state=" ++ expected,
            expected,
        ),
    );
    try std.testing.expectError(
        error.InvalidCallback,
        parseCallbackTarget(
            std.testing.allocator,
            callback_path ++ "?code=a&code=b&state=" ++ expected,
            expected,
        ),
    );
    try std.testing.expectError(
        error.InvalidCallback,
        parseCallbackTarget(
            std.testing.allocator,
            callback_path ++
                "?code=secret-code&error_description=ignored&state=" ++ expected,
            expected,
        ),
    );
}

test "callback parser validates RFC 9207 issuer without normalization" {
    const expected_state = "0123456789012345678901234567890123456789012";
    const issuer = "https://auth.example.test/tenant";
    var callback = try parseCallbackTargetValidated(
        std.testing.allocator,
        callback_path ++
            "?code=secret-code&state=" ++ expected_state ++
            "&iss=https%3A%2F%2Fauth.example.test%2Ftenant&extension=1",
        expected_state,
        .{ .expected_issuer = issuer, .issuer_required = true },
    );
    defer callback.deinit();
    try std.testing.expectEqualStrings("secret-code", callback.code.view());
    try std.testing.expectError(
        error.InvalidCallback,
        parseCallbackTargetValidated(
            std.testing.allocator,
            callback_path ++ "?code=secret-code&state=" ++ expected_state,
            expected_state,
            .{ .expected_issuer = issuer, .issuer_required = true },
        ),
    );
    try std.testing.expectError(
        error.InvalidCallback,
        parseCallbackTargetValidated(
            std.testing.allocator,
            callback_path ++
                "?error=access_denied&state=" ++ expected_state ++
                "&iss=https%3A%2F%2FAUTH.example.test%2Ftenant&extension=1",
            expected_state,
            .{ .expected_issuer = issuer },
        ),
    );
    var callback_without_issuer_policy = try parseCallbackTarget(
        std.testing.allocator,
        callback_path ++
            "?code=secret-code&state=" ++ expected_state ++
            "&iss=https%3A%2F%2Fauth.example.test%2Ftenant&extension=1",
        expected_state,
    );
    callback_without_issuer_policy.deinit();
}

test "token decoder validates consumed fields and tolerates additive metadata" {
    var tokens = try parseTokenResponse(
        std.testing.allocator,
        \\{"access_token":"new-access","refresh_token":"new-refresh","token_type":"Bearer","expires_in":3600,"gateway_url":"https://www.metask-ai.com"}
    ,
        100,
    );
    defer tokens.deinit();
    try std.testing.expectEqualStrings("new-access", tokens.access_token.view());
    try std.testing.expectEqualStrings("new-refresh", tokens.refresh_token.view());
    try std.testing.expectEqual(@as(i64, 3700), tokens.expires_at);
    var extended = try parseTokenResponse(
        std.testing.allocator,
        \\{"access_token":"a","refresh_token":"r","token_type":"Bearer","expires_in":1,"unknown":true}
    ,
        0,
    );
    extended.deinit();
}

test "token scope is a case-sensitive set and omission inherits the requested grant" {
    var storage: [512]u8 = undefined;
    const format =
        \\{{"access_token":"a","refresh_token":"r","token_type":"Bearer","expires_in":1,"scope":"{s}"}}
    ;
    for ([_][]const u8{ "read model:invoke", "model:invoke read", "read read model:invoke" }) |granted| {
        const body = try std.fmt.bufPrint(&storage, format, .{granted});
        var tokens = try parseTokenResponse(std.testing.allocator, body, 0);
        tokens.deinit();
    }
    for ([_][]const u8{
        "",                        "read",               "model:invoke",       "READ model:invoke",  "openid profile email",
        "read model:invoke admin", " read model:invoke", "read model:invoke ", "read  model:invoke", "read\\tmodel:invoke",
    }) |granted| {
        const body = try std.fmt.bufPrint(&storage, format, .{granted});
        try std.testing.expectError(
            error.InvalidTokenResponse,
            parseTokenResponse(std.testing.allocator, body, 0),
        );
    }
    for ([_][]const u8{
        \\{"access_token":"a","refresh_token":"r","token_type":"Bearer","expires_in":1,"scope":null}
        ,
        \\{"access_token":"a","refresh_token":"r","token_type":"Bearer","expires_in":1,"scope":42}
    }) |body| {
        try std.testing.expectError(
            error.InvalidTokenResponse,
            parseTokenResponse(std.testing.allocator, body, 0),
        );
    }
}

test "current user decoder binds the principal and projects optional profile fields" {
    const info = try parseCurrentUser(
        \\{"sub":"user-42","email":"user@example.com","email_verified":true,"name":"Meta User","phone_number":"13800138000","client_id":"metawork","authorization_id":"auth-1","unknown":true}
    );
    try std.testing.expectEqualStrings("user-42", info.accountId());
    try std.testing.expectEqualStrings("Meta User", info.usernameView());
    try std.testing.expectEqualStrings("u***@example.com", info.emailHintView());
    try std.testing.expectEqualStrings("138****8000", info.phoneHintView());
    try std.testing.expectEqual(@as(?u32, null), info.concurrency_limit);
    try std.testing.expectError(
        error.InvalidCurrentUserResponse,
        parseCurrentUser(
            \\{"sub":"user-42","name":"Meta User","client_id":"another-client","authorization_id":"auth-1"}
        ),
    );
    const incomplete = try parseCurrentUser(
        \\{"sub":"user-42","name":"","email":null,"phone_number":null,"client_id":"metawork","authorization_id":"auth-1"}
    );
    try std.testing.expectEqualStrings("", incomplete.usernameView());
    try std.testing.expectEqualStrings("", incomplete.emailHintView());
    try std.testing.expectEqualStrings("", incomplete.phoneHintView());
    try std.testing.expectEqual(@as(?u32, null), incomplete.concurrency_limit);
    const malformed = try parseCurrentUser(
        \\{"sub":"user-42","name":7,"email":{"value":"user@example.com"},"phone_number":13800138000,"client_id":"metawork","authorization_id":"auth-1"}
    );
    try std.testing.expectEqualStrings("", malformed.usernameView());
    try std.testing.expectEqualStrings("", malformed.emailHintView());
    try std.testing.expectEqualStrings("", malformed.phoneHintView());
}

test "current user decoder ignores unusable optional profile values" {
    const unicode = try parseCurrentUser(
        \\{"sub":"user-42","email":"朱健@example.com","name":"Meta User","client_id":"metawork","authorization_id":"auth-1"}
    );
    try std.testing.expectEqualStrings("朱***@example.com", unicode.emailHintView());

    const phone = try parseCurrentUser(
        \\{"sub":"user-42","phone_number":"+8613800138000","client_id":"metawork","authorization_id":"auth-1"}
    );
    try std.testing.expectEqualStrings("+861****8000", phone.phoneHintView());

    // A person signed up by phone: Metask masks the number itself and gives
    // an unverified placeholder address, which is not shown.
    const phone_user = try parseCurrentUser(
        \\{"sub":"user-42","email":"13800000000@phone.metask-ai.com","email_verified":false,"phone_number":"138****0000","client_id":"metawork","authorization_id":"auth-1"}
    );
    try std.testing.expectEqualStrings("", phone_user.emailHintView());
    try std.testing.expectEqualStrings("138****0000", phone_user.phoneHintView());
    // Verified, it is an address like any other.
    const verified = try parseCurrentUser(
        \\{"sub":"user-42","email":"13800000000@phone.metask-ai.com","email_verified":true,"client_id":"metawork","authorization_id":"auth-1"}
    );
    try std.testing.expectEqualStrings("1***@phone.metask-ai.com", verified.emailHintView());

    const absent = try parseCurrentUser(
        \\{"sub":"user-42","name":"Meta User","client_id":"metawork","authorization_id":"auth-1"}
    );
    try std.testing.expectEqualStrings("", absent.emailHintView());

    for ([_][]const u8{
        "{\"sub\":\"user-42\",\"email\":\"invalid\",\"name\":\"Meta User\",\"client_id\":\"metawork\",\"authorization_id\":\"auth-1\"}",
        "{\"sub\":\"user-42\",\"email\":\"a@@example.com\",\"name\":\"Meta User\",\"client_id\":\"metawork\",\"authorization_id\":\"auth-1\"}",
    }) |payload| {
        const invalid = try parseCurrentUser(payload);
        try std.testing.expectEqualStrings("", invalid.emailHintView());
    }

    for ([_][]const u8{
        "{\"sub\":\"user-42\",\"phone_number\":\"12345\",\"client_id\":\"metawork\",\"authorization_id\":\"auth-1\"}",
        "{\"sub\":\"user-42\",\"phone_number\":\"138-0013-8000\",\"client_id\":\"metawork\",\"authorization_id\":\"auth-1\"}",
        "{\"sub\":\"user-42\",\"phone_number\":\"++8613800138000\",\"client_id\":\"metawork\",\"authorization_id\":\"auth-1\"}",
        "{\"sub\":\"user-42\",\"phone_number\":\"****0000000\",\"client_id\":\"metawork\",\"authorization_id\":\"auth-1\"}",
        "{\"sub\":\"user-42\",\"phone_number\":\"138**00*000\",\"client_id\":\"metawork\",\"authorization_id\":\"auth-1\"}",
    }) |payload| {
        const invalid = try parseCurrentUser(payload);
        try std.testing.expectEqualStrings("", invalid.phoneHintView());
    }

    var long_username: [contract.Limits.display_name_bytes + 1]u8 = undefined;
    @memset(&long_username, 'x');
    const payload = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"sub\":\"user-42\",\"name\":\"{s}\",\"client_id\":\"metawork\",\"authorization_id\":\"auth-1\"}}",
        .{&long_username},
    );
    defer std.testing.allocator.free(payload);
    const oversized = try parseCurrentUser(payload);
    try std.testing.expectEqualStrings("", oversized.usernameView());
}

test "optional account summary fields never become identity gates" {
    const info = try parseCurrentUser(
        \\{"sub":"user-42","name":"Meta User","client_id":"metawork","authorization_id":"auth-1","balance":"temporarily-invalid","run_mode":7}
    );
    try std.testing.expectEqualStrings("Meta User", info.usernameView());
}

test "authorization code and refresh bodies do not widen client contract" {
    const callback_port: u16 = 49152;
    var code = try Secret.init(std.testing.allocator, "abc /?");
    defer code.deinit();
    var body_storage: [1024]u8 = undefined;
    const body = try buildAuthorizationCodeBody(
        &body_storage,
        &code,
        "verifier",
        callback_port,
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        body,
        "client_id=metawork",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "code=abc%20%2F%3F") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        body,
        "redirect_uri=http%3A%2F%2Flocalhost%3A49152%2Fauth%2Fmetask%2Fcallback",
    ) != null);

    var refresh = try Secret.init(std.testing.allocator, "refresh-token");
    defer refresh.deinit();
    const refresh_body = try buildRefreshBody(&body_storage, &refresh);
    try std.testing.expectEqualStrings(
        "grant_type=refresh_token&client_id=metawork&refresh_token=refresh-token",
        refresh_body,
    );
}
