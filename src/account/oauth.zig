const std = @import("std");
const contract = @import("metawork_account_contract");

pub const authority = "https://napi.metask-ai.com";
pub const authorize_url = authority ++ "/oauth/authorize";
pub const token_url = authority ++ "/oauth/token";
pub const revoke_url = authority ++ "/oauth/revoke";
pub const profiles_url = authority ++ "/v1/profiles";
pub const client_id = "metawork-app";
pub const scope = "metawork:use";
pub const callback_path = "/auth/callback";

pub const Limits = struct {
    pub const secret_bytes: usize = 4096;
    pub const state_bytes: usize = 43;
    pub const verifier_bytes: usize = 43;
    pub const challenge_bytes: usize = 43;
    pub const authorization_url_bytes: usize = 4096;
    pub const callback_target_bytes: usize = 8192;
    pub const token_body_bytes: usize = 16 * 1024;
    pub const profiles_body_bytes: usize = 64 * 1024;
    pub const current_user_body_bytes: usize = 16 * 1024;
    pub const profile_entries: usize = 64;
    pub const scope_bytes: usize = 256;
};

pub const ProtocolError = error{
    BufferTooSmall,
    InvalidEncoding,
    InvalidCallback,
    StateMismatch,
    AuthorizationRejected,
    InvalidTokenResponse,
    InvalidProfileResponse,
    InvalidCurrentUserResponse,
    FieldTooLarge,
    TooManyProfiles,
    ExpiryOverflow,
    MissingRefreshToken,
};

pub const Secret = struct {
    allocator: std.mem.Allocator = undefined,
    bytes: []u8 = &.{},
    owned: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        value: []const u8,
    ) (ProtocolError || std.mem.Allocator.Error)!Secret {
        if (value.len == 0 or value.len > Limits.secret_bytes)
            return error.FieldTooLarge;
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
        const result = self.*;
        self.* = .{};
        return result;
    }

    pub fn deinit(self: *Secret) void {
        if (!self.owned) return;
        std.crypto.secureZero(u8, self.bytes);
        self.allocator.free(self.bytes);
        self.* = .{};
    }
};

pub const AttemptMaterial = struct {
    verifier: [Limits.verifier_bytes]u8,
    state: [Limits.state_bytes]u8,
    challenge: [Limits.challenge_bytes]u8,

    pub fn generate(
        io: std.Io,
        output: *AttemptMaterial,
    ) !void {
        var verifier_seed: [32]u8 = undefined;
        var state_seed: [32]u8 = undefined;
        defer std.crypto.secureZero(u8, &verifier_seed);
        defer std.crypto.secureZero(u8, &state_seed);
        try std.Io.randomSecure(io, &verifier_seed);
        try std.Io.randomSecure(io, &state_seed);
        fillFromSeeds(output, &verifier_seed, &state_seed);
    }

    pub fn fromSeeds(verifier_seed: [32]u8, state_seed: [32]u8) AttemptMaterial {
        var result: AttemptMaterial = undefined;
        fillFromSeeds(&result, &verifier_seed, &state_seed);
        return result;
    }

    fn fillFromSeeds(
        result: *AttemptMaterial,
        verifier_seed: *const [32]u8,
        state_seed: *const [32]u8,
    ) void {
        _ = std.base64.url_safe_no_pad.Encoder.encode(
            &result.verifier,
            verifier_seed,
        );
        _ = std.base64.url_safe_no_pad.Encoder.encode(
            &result.state,
            state_seed,
        );
        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        defer std.crypto.secureZero(u8, &digest);
        std.crypto.hash.sha2.Sha256.hash(&result.verifier, &digest, .{});
        _ = std.base64.url_safe_no_pad.Encoder.encode(
            &result.challenge,
            &digest,
        );
    }

    pub fn deinit(self: *AttemptMaterial) void {
        std.crypto.secureZero(u8, &self.verifier);
        std.crypto.secureZero(u8, &self.state);
        std.crypto.secureZero(u8, &self.challenge);
    }
};

pub fn writeRedirectUri(writer: *std.Io.Writer, port: u16) !void {
    if (port == 0) return error.InvalidCallback;
    try writer.print(
        "http://127.0.0.1:{d}" ++ callback_path,
        .{port},
    );
}

pub fn buildAuthorizeUrl(
    output: []u8,
    port: u16,
    material: *const AttemptMaterial,
) ProtocolError![]const u8 {
    var redirect_storage: [128]u8 = undefined;
    var redirect_writer = std.Io.Writer.fixed(&redirect_storage);
    writeRedirectUri(&redirect_writer, port) catch return error.InvalidCallback;
    const redirect_uri = redirect_writer.buffered();

    var writer = std.Io.Writer.fixed(output);
    writer.writeAll(authorize_url) catch return error.BufferTooSmall;
    writer.writeByte('?') catch return error.BufferTooSmall;
    writePair(&writer, "response_type", "code") catch return error.BufferTooSmall;
    writer.writeByte('&') catch return error.BufferTooSmall;
    writePair(&writer, "client_id", client_id) catch return error.BufferTooSmall;
    writer.writeByte('&') catch return error.BufferTooSmall;
    writePair(&writer, "redirect_uri", redirect_uri) catch return error.BufferTooSmall;
    writer.writeByte('&') catch return error.BufferTooSmall;
    writePair(&writer, "scope", scope) catch return error.BufferTooSmall;
    writer.writeByte('&') catch return error.BufferTooSmall;
    writePair(&writer, "state", &material.state) catch return error.BufferTooSmall;
    writer.writeByte('&') catch return error.BufferTooSmall;
    writePair(&writer, "code_challenge", &material.challenge) catch
        return error.BufferTooSmall;
    writer.writeAll("&code_challenge_method=S256") catch
        return error.BufferTooSmall;
    return writer.buffered();
}

pub const Callback = union(enum) {
    code: Secret,
    rejected,

    pub fn deinit(self: *Callback) void {
        switch (self.*) {
            .code => |*value| value.deinit(),
            .rejected => {},
        }
        self.* = .rejected;
    }
};

pub fn parseCallbackTarget(
    allocator: std.mem.Allocator,
    target: []const u8,
    expected_state: []const u8,
) (ProtocolError || std.mem.Allocator.Error)!Callback {
    if (target.len == 0 or target.len > Limits.callback_target_bytes)
        return error.InvalidCallback;
    const query_index = std.mem.indexOfScalar(u8, target, '?') orelse
        return error.InvalidCallback;
    if (!std.mem.eql(u8, target[0..query_index], callback_path))
        return error.InvalidCallback;
    const query = target[query_index + 1 ..];
    if (query.len == 0 or std.mem.indexOfScalar(u8, query, '#') != null)
        return error.InvalidCallback;

    var code_storage: [Limits.secret_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &code_storage);
    var state_storage: [Limits.state_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &state_storage);
    var error_seen = false;
    var error_description_seen = false;
    var code: ?[]const u8 = null;
    var state_value: ?[]const u8 = null;

    var pairs = std.mem.splitScalar(u8, query, '&');
    while (pairs.next()) |pair| {
        if (pair.len == 0) return error.InvalidCallback;
        const equals = std.mem.indexOfScalar(u8, pair, '=') orelse
            return error.InvalidCallback;
        const key = pair[0..equals];
        const value = pair[equals + 1 ..];
        if (std.mem.eql(u8, key, "code")) {
            if (code != null) return error.InvalidCallback;
            code = try percentDecode(value, &code_storage);
        } else if (std.mem.eql(u8, key, "state")) {
            if (state_value != null) return error.InvalidCallback;
            state_value = try percentDecode(value, &state_storage);
        } else if (std.mem.eql(u8, key, "error")) {
            if (error_seen) return error.InvalidCallback;
            var error_storage: [256]u8 = undefined;
            defer std.crypto.secureZero(u8, &error_storage);
            const decoded = try percentDecode(value, &error_storage);
            if (decoded.len == 0) return error.InvalidCallback;
            error_seen = true;
        } else if (std.mem.eql(u8, key, "error_description")) {
            if (error_description_seen) return error.InvalidCallback;
            // The description is deliberately ignored and never logged.
            error_description_seen = true;
        } else {
            return error.InvalidCallback;
        }
    }

    const actual_state = state_value orelse return error.StateMismatch;
    if (expected_state.len != Limits.state_bytes or
        actual_state.len != Limits.state_bytes)
        return error.StateMismatch;
    if (!std.crypto.timing_safe.eql(
        [Limits.state_bytes]u8,
        paddedState(expected_state),
        paddedState(actual_state),
    )) return error.StateMismatch;
    if (error_seen) {
        if (code != null) return error.InvalidCallback;
        return .rejected;
    }
    if (error_description_seen) return error.InvalidCallback;
    return .{
        .code = try Secret.init(
            allocator,
            code orelse return error.InvalidCallback,
        ),
    };
}

fn paddedState(value: []const u8) [Limits.state_bytes]u8 {
    var padded: [Limits.state_bytes]u8 = @splat(0);
    const len = @min(value.len, padded.len);
    @memcpy(padded[0..len], value[0..len]);
    return padded;
}

pub const TokenSet = struct {
    access_token: Secret,
    refresh_token: Secret,
    expires_at: i64,
    scope_value: [Limits.scope_bytes]u8 = undefined,
    scope_len: usize = 0,
    account_id: [contract.Limits.account_id_bytes]u8 = undefined,
    account_id_len: usize = 0,

    pub fn scopeView(self: *const TokenSet) []const u8 {
        return self.scope_value[0..self.scope_len];
    }

    pub fn accountId(self: *const TokenSet) []const u8 {
        return self.account_id[0..self.account_id_len];
    }

    pub fn deinit(self: *TokenSet) void {
        self.access_token.deinit();
        self.refresh_token.deinit();
        std.crypto.secureZero(u8, &self.scope_value);
        std.crypto.secureZero(u8, &self.account_id);
        self.scope_len = 0;
        self.account_id_len = 0;
        self.expires_at = 0;
    }

    pub fn take(self: *TokenSet) TokenSet {
        var result = self.*;
        result.access_token = self.access_token.take();
        result.refresh_token = self.refresh_token.take();
        std.crypto.secureZero(u8, &self.scope_value);
        std.crypto.secureZero(u8, &self.account_id);
        self.scope_len = 0;
        self.account_id_len = 0;
        self.expires_at = 0;
        return result;
    }

    pub fn fromStored(
        allocator: std.mem.Allocator,
        access_token: []const u8,
        refresh_token: []const u8,
        expires_at: i64,
        stored_scope: []const u8,
        stored_account_id: []const u8,
    ) (ProtocolError || std.mem.Allocator.Error)!TokenSet {
        if (expires_at < 0 or
            !std.mem.eql(u8, stored_scope, scope) or
            stored_account_id.len == 0 or
            stored_account_id.len > contract.Limits.account_id_bytes)
            return error.InvalidTokenResponse;
        var result: TokenSet = .{
            .access_token = try Secret.init(allocator, access_token),
            .refresh_token = undefined,
            .expires_at = expires_at,
        };
        errdefer result.access_token.deinit();
        result.refresh_token = try Secret.init(allocator, refresh_token);
        errdefer result.refresh_token.deinit();
        @memcpy(result.scope_value[0..stored_scope.len], stored_scope);
        result.scope_len = stored_scope.len;
        @memcpy(result.account_id[0..stored_account_id.len], stored_account_id);
        result.account_id_len = stored_account_id.len;
        return result;
    }
};

const TokenResponse = struct {
    access_token: []const u8,
    refresh_token: []const u8,
    token_type: []const u8,
    expires_in: u64,
    scope: ?[]const u8 = null,
    account_id: []const u8,
};

pub fn parseTokenResponse(
    allocator: std.mem.Allocator,
    body: []const u8,
    now_unix_seconds: i64,
) (ProtocolError || std.mem.Allocator.Error)!TokenSet {
    if (body.len == 0 or body.len > Limits.token_body_bytes)
        return error.InvalidTokenResponse;
    var scratch: [Limits.token_body_bytes * 2]u8 = undefined;
    defer std.crypto.secureZero(u8, &scratch);
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    var parsed = std.json.parseFromSlice(
        TokenResponse,
        fba.allocator(),
        body,
        .{ .ignore_unknown_fields = true },
    ) catch return error.InvalidTokenResponse;
    defer parsed.deinit();
    const raw = parsed.value;
    if (raw.access_token.len == 0 or
        !std.ascii.eqlIgnoreCase(raw.token_type, "bearer") or
        raw.expires_in == 0 or
        raw.expires_in > std.math.maxInt(i64))
        return error.InvalidTokenResponse;
    const expires_at = std.math.add(
        i64,
        now_unix_seconds,
        @intCast(raw.expires_in),
    ) catch return error.ExpiryOverflow;
    if (expires_at < 0) return error.ExpiryOverflow;

    var result: TokenSet = .{
        .access_token = try Secret.init(allocator, raw.access_token),
        .refresh_token = undefined,
        .expires_at = expires_at,
    };
    errdefer result.access_token.deinit();
    if (raw.refresh_token.len == 0) return error.MissingRefreshToken;
    result.refresh_token = try Secret.init(allocator, raw.refresh_token);
    errdefer result.refresh_token.deinit();

    const response_scope = raw.scope orelse scope;
    if (!std.mem.eql(u8, response_scope, scope))
        return error.InvalidTokenResponse;
    @memcpy(result.scope_value[0..response_scope.len], response_scope);
    result.scope_len = response_scope.len;
    if (raw.account_id.len == 0 or raw.account_id.len > result.account_id.len)
        return error.FieldTooLarge;
    if (!std.unicode.utf8ValidateSlice(raw.account_id))
        return error.InvalidEncoding;
    @memcpy(result.account_id[0..raw.account_id.len], raw.account_id);
    result.account_id_len = raw.account_id.len;
    return result;
}

pub const Profile = struct {
    id: [contract.Limits.profile_id_bytes]u8 = undefined,
    id_len: usize = 0,
    display_name: [contract.Limits.display_name_bytes]u8 = undefined,
    display_name_len: usize = 0,

    pub fn idView(self: *const Profile) []const u8 {
        return self.id[0..self.id_len];
    }

    pub fn displayName(self: *const Profile) []const u8 {
        return self.display_name[0..self.display_name_len];
    }
};

const ProfilesResponse = struct {
    data: []const ProfileResponse,
};

const ProfileResponse = struct {
    id: []const u8,
    name: ?[]const u8 = null,
    display_name: ?[]const u8 = null,
    status: []const u8,
    is_default: bool,
};

pub fn parseFirstProfile(body: []const u8) ProtocolError!?Profile {
    if (body.len == 0 or body.len > Limits.profiles_body_bytes)
        return error.InvalidProfileResponse;
    var scratch: [Limits.profiles_body_bytes * 2]u8 = undefined;
    defer std.crypto.secureZero(u8, &scratch);
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    var parsed = std.json.parseFromSlice(
        ProfilesResponse,
        fba.allocator(),
        body,
        .{ .ignore_unknown_fields = true },
    ) catch return error.InvalidProfileResponse;
    defer parsed.deinit();
    if (parsed.value.data.len > Limits.profile_entries)
        return error.TooManyProfiles;
    var first_active: ?ProfileResponse = null;
    var default_active: ?ProfileResponse = null;
    for (parsed.value.data) |entry| {
        if (entry.id.len == 0 or
            !std.mem.eql(u8, entry.status, "active"))
            continue;
        if (first_active == null) first_active = entry;
        if (entry.is_default) {
            if (default_active != null)
                return error.InvalidProfileResponse;
            default_active = entry;
        }
    }
    const selected = default_active orelse first_active orelse return null;
    const display =
        selected.display_name orelse selected.name orelse selected.id;
    if (selected.id.len > contract.Limits.profile_id_bytes or
        display.len > contract.Limits.display_name_bytes)
        return error.FieldTooLarge;
    if (!std.unicode.utf8ValidateSlice(selected.id) or
        !std.unicode.utf8ValidateSlice(display))
        return error.InvalidEncoding;
    var result: Profile = .{};
    @memcpy(result.id[0..selected.id.len], selected.id);
    result.id_len = selected.id.len;
    @memcpy(result.display_name[0..display.len], display);
    result.display_name_len = display.len;
    return result;
}

pub const CurrentUser = struct {
    username: [contract.Limits.display_name_bytes]u8 = undefined,
    username_len: usize = 0,

    pub fn usernameView(self: *const CurrentUser) []const u8 {
        return self.username[0..self.username_len];
    }
};

const CurrentUserEnvelope = struct {
    code: i64,
    data: CurrentUserResponse,
};

const CurrentUserResponse = struct {
    id: i64,
    username: []const u8,
};

pub fn parseCurrentUser(
    body: []const u8,
    expected_account_id: []const u8,
) ProtocolError!CurrentUser {
    if (body.len == 0 or body.len > Limits.current_user_body_bytes)
        return error.InvalidCurrentUserResponse;
    var scratch: [Limits.current_user_body_bytes * 2]u8 = undefined;
    defer std.crypto.secureZero(u8, &scratch);
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    var parsed = std.json.parseFromSlice(
        CurrentUserEnvelope,
        fba.allocator(),
        body,
        .{ .ignore_unknown_fields = true },
    ) catch return error.InvalidCurrentUserResponse;
    defer parsed.deinit();
    const raw = parsed.value;
    var account_id_storage: [32]u8 = undefined;
    const account_id = std.fmt.bufPrint(
        &account_id_storage,
        "{d}",
        .{raw.data.id},
    ) catch return error.InvalidCurrentUserResponse;
    if (raw.code != 0 or raw.data.id <= 0 or
        !std.mem.eql(u8, account_id, expected_account_id) or
        raw.data.username.len == 0 or
        raw.data.username.len > contract.Limits.display_name_bytes or
        !std.unicode.utf8ValidateSlice(raw.data.username))
        return error.InvalidCurrentUserResponse;
    var result: CurrentUser = .{};
    @memcpy(result.username[0..raw.data.username.len], raw.data.username);
    result.username_len = raw.data.username.len;
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
    return writeForm(output, &.{
        .{ "grant_type", "authorization_code" },
        .{ "client_id", client_id },
        .{ "code", code.view() },
        .{ "code_verifier", verifier },
        .{ "redirect_uri", redirect_writer.buffered() },
    });
}

pub fn buildRefreshBody(
    output: []u8,
    refresh_token: *const Secret,
) ProtocolError![]const u8 {
    return writeForm(output, &.{
        .{ "grant_type", "refresh_token" },
        .{ "client_id", client_id },
        .{ "refresh_token", refresh_token.view() },
    });
}

fn writeForm(
    output: []u8,
    pairs: []const struct { []const u8, []const u8 },
) ProtocolError![]const u8 {
    var writer = std.Io.Writer.fixed(output);
    for (pairs, 0..) |pair, index| {
        if (index != 0) writer.writeByte('&') catch return error.BufferTooSmall;
        writePair(&writer, pair[0], pair[1]) catch return error.BufferTooSmall;
    }
    return writer.buffered();
}

fn writePair(writer: *std.Io.Writer, key: []const u8, value: []const u8) !void {
    try percentEncode(writer, key);
    try writer.writeByte('=');
    try percentEncode(writer, value);
}

fn percentEncode(writer: *std.Io.Writer, input: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (input) |byte| {
        if (std.ascii.isAlphanumeric(byte) or
            byte == '-' or byte == '.' or byte == '_' or byte == '~')
        {
            try writer.writeByte(byte);
        } else {
            try writer.writeAll(&.{
                '%',
                hex[byte >> 4],
                hex[byte & 0x0f],
            });
        }
    }
}

fn percentDecode(input: []const u8, output: []u8) ProtocolError![]const u8 {
    var read_index: usize = 0;
    var write_index: usize = 0;
    while (read_index < input.len) {
        if (write_index == output.len) return error.FieldTooLarge;
        const byte = input[read_index];
        if (byte == '%') {
            if (read_index + 2 >= input.len) return error.InvalidEncoding;
            const high = hexValue(input[read_index + 1]) orelse
                return error.InvalidEncoding;
            const low = hexValue(input[read_index + 2]) orelse
                return error.InvalidEncoding;
            output[write_index] = (high << 4) | low;
            read_index += 3;
        } else {
            output[write_index] = if (byte == '+') ' ' else byte;
            read_index += 1;
        }
        write_index += 1;
    }
    if (!std.unicode.utf8ValidateSlice(output[0..write_index]))
        return error.InvalidEncoding;
    return output[0..write_index];
}

fn hexValue(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

test "PKCE uses RFC 7636 S256 shape and authorize URL is fixed origin" {
    const material = AttemptMaterial.fromSeeds(
        @splat(0x11),
        @splat(0x22),
    );
    try std.testing.expectEqual(Limits.verifier_bytes, material.verifier.len);
    try std.testing.expectEqual(Limits.state_bytes, material.state.len);
    try std.testing.expectEqual(Limits.challenge_bytes, material.challenge.len);
    var buffer: [Limits.authorization_url_bytes]u8 = undefined;
    const url = try buildAuthorizeUrl(&buffer, 49152, &material);
    try std.testing.expect(std.mem.startsWith(u8, url, authorize_url ++ "?"));
    try std.testing.expect(std.mem.indexOf(
        u8,
        url,
        "redirect_uri=http%3A%2F%2F127.0.0.1%3A49152%2Fauth%2Fcallback",
    ) != null);
    try std.testing.expect(std.mem.endsWith(
        u8,
        url,
        "code_challenge_method=S256",
    ));
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

test "token decoder validates consumed fields and tolerates additive metadata" {
    var tokens = try parseTokenResponse(
        std.testing.allocator,
        \\{"access_token":"new-access","refresh_token":"new-refresh","token_type":"Bearer","expires_in":3600,"scope":"metawork:use","account_id":"acct-1"}
    ,
        100,
    );
    defer tokens.deinit();
    try std.testing.expectEqualStrings("new-access", tokens.access_token.view());
    try std.testing.expectEqualStrings("new-refresh", tokens.refresh_token.view());
    try std.testing.expectEqual(@as(i64, 3700), tokens.expires_at);
    try std.testing.expectEqualStrings("acct-1", tokens.accountId());
    var extended = try parseTokenResponse(
        std.testing.allocator,
        \\{"access_token":"a","refresh_token":"r","token_type":"Bearer","expires_in":1,"account_id":"acct-1","unknown":true}
    ,
        0,
    );
    extended.deinit();
    try std.testing.expectError(
        error.InvalidTokenResponse,
        parseTokenResponse(
            std.testing.allocator,
            \\{"access_token":"a","refresh_token":"r","token_type":"Bearer","expires_in":1,"scope":"unexpected","account_id":"acct-1"}
        ,
            0,
        ),
    );
    try std.testing.expectError(
        error.InvalidTokenResponse,
        parseTokenResponse(
            std.testing.allocator,
            \\{"access_token":"a","refresh_token":"r","token_type":"Bearer","expires_in":1,"scope":"metawork:use"}
        ,
            0,
        ),
    );
}

test "profile decoder selects one active default and tolerates additive metadata" {
    const profile = (try parseFirstProfile(
        \\{"data":[
        \\{"id":"profile-1","name":"first","display_name":"First",
        \\"status":"active","platform":"anthropic","group_id":1,
        \\"group_name":"First","expires_at":null,"is_default":false},
        \\{"id":"profile-2","name":"main","display_name":"Main",
        \\"status":"active","platform":"anthropic","group_id":2,
        \\"group_name":"Main","expires_at":null,"is_default":true}]}
    )).?;
    try std.testing.expectEqualStrings("profile-2", profile.idView());
    try std.testing.expectEqualStrings("Main", profile.displayName());
    const extended = (try parseFirstProfile(
        \\{"data":[{"id":"profile-1","name":"main",
        \\"display_name":"Main","status":"active",
        \\"platform":"anthropic","group_id":1,"group_name":"Main",
        \\"expires_at":null,"is_default":true,"extra":"allowed"}]}
    )).?;
    try std.testing.expectEqualStrings("profile-1", extended.idView());
    try std.testing.expect((try parseFirstProfile("{\"data\":[]}")) == null);
}

test "current user decoder binds username to the token account" {
    const info = try parseCurrentUser(
        \\{"code":0,"message":"success","data":{"id":42,"email":"user@example.com","username":"Meta User","role":"user","unknown":true}}
    ,
        "42",
    );
    try std.testing.expectEqualStrings("Meta User", info.usernameView());
    try std.testing.expectError(
        error.InvalidCurrentUserResponse,
        parseCurrentUser(
            \\{"code":0,"data":{"id":43,"username":"Meta User"}}
        ,
            "42",
        ),
    );
    try std.testing.expectError(
        error.InvalidCurrentUserResponse,
        parseCurrentUser(
            \\{"code":0,"data":{"id":42,"username":""}}
        ,
            "42",
        ),
    );
}

test "authorization code and refresh bodies do not widen client contract" {
    var code = try Secret.init(std.testing.allocator, "abc /?");
    defer code.deinit();
    var body_storage: [1024]u8 = undefined;
    const body = try buildAuthorizationCodeBody(
        &body_storage,
        &code,
        "verifier",
        12345,
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        body,
        "client_id=metawork-app",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "code=abc%20%2F%3F") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        body,
        "redirect_uri=http%3A%2F%2F127.0.0.1%3A12345%2Fauth%2Fcallback",
    ) != null);

    var refresh = try Secret.init(std.testing.allocator, "refresh-token");
    defer refresh.deinit();
    const refresh_body = try buildRefreshBody(&body_storage, &refresh);
    try std.testing.expectEqualStrings(
        "grant_type=refresh_token&client_id=metawork-app&refresh_token=refresh-token",
        refresh_body,
    );
}
