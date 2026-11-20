//! Product-neutral OAuth trust-boundary mechanics, a Foundation contract:
//! types and pure functions only. PKCE generation borrows the caller's `Io`
//! for entropy and nothing here holds a handle or starts an effect.
//!
//! This contract owns PKCE generation, bounded secret lifetime, strict callback
//! query parsing with constant-time state comparison, and the RFC 6749 protocol
//! codec: form encoding, the authorization request, the authorization-code and
//! refresh-token request bodies, and decoding of token and error responses.
//! Callers own endpoints, client identity, scope, required members, limits,
//! time units, response copy and domain error mapping.
const std = @import("std");

pub const pkce_seed_bytes: usize = 32;
pub const pkce_encoded_bytes: usize = 43;

pub const AttemptMaterial = struct {
    verifier: [pkce_encoded_bytes]u8,
    state: [pkce_encoded_bytes]u8,
    challenge: [pkce_encoded_bytes]u8,

    pub fn generate(io: std.Io, output: *AttemptMaterial) !void {
        var verifier_seed: [pkce_seed_bytes]u8 = undefined;
        var state_seed: [pkce_seed_bytes]u8 = undefined;
        defer std.crypto.secureZero(u8, &verifier_seed);
        defer std.crypto.secureZero(u8, &state_seed);
        try std.Io.randomSecure(io, &verifier_seed);
        try std.Io.randomSecure(io, &state_seed);
        fillFromSeeds(output, &verifier_seed, &state_seed);
    }

    pub fn fromSeeds(
        verifier_seed: [pkce_seed_bytes]u8,
        state_seed: [pkce_seed_bytes]u8,
    ) AttemptMaterial {
        var result: AttemptMaterial = undefined;
        fillFromSeeds(&result, &verifier_seed, &state_seed);
        return result;
    }

    fn fillFromSeeds(
        result: *AttemptMaterial,
        verifier_seed: *const [pkce_seed_bytes]u8,
        state_seed: *const [pkce_seed_bytes]u8,
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

/// Owned secret bytes: one allocation, moved by `take`, scrubbed on release.
/// Admission here is length only; a caller with a stricter byte policy applies
/// it before `init`.
pub fn Secret(comptime limits: struct { max_bytes: usize }) type {
    if (limits.max_bytes == 0)
        @compileError("OAuth secret limit must be non-zero");

    return struct {
        const Self = @This();

        allocator: std.mem.Allocator = undefined,
        bytes: []u8 = &.{},
        owned: bool = false,

        pub fn init(
            allocator: std.mem.Allocator,
            value: []const u8,
        ) (error{FieldTooLarge} || std.mem.Allocator.Error)!Self {
            if (value.len == 0 or value.len > limits.max_bytes)
                return error.FieldTooLarge;
            return .{
                .allocator = allocator,
                .bytes = try allocator.dupe(u8, value),
                .owned = true,
            };
        }

        pub fn view(self: *const Self) []const u8 {
            std.debug.assert(self.owned);
            return self.bytes;
        }

        pub fn take(self: *Self) Self {
            std.debug.assert(self.owned);
            const result = self.*;
            self.* = .{};
            return result;
        }

        pub fn deinit(self: *Self) void {
            if (!self.owned) return;
            std.crypto.secureZero(u8, self.bytes);
            self.allocator.free(self.bytes);
            self.* = .{};
        }
    };
}

pub fn writeLoopbackRedirectUri(
    writer: *std.Io.Writer,
    port: u16,
    callback_path: []const u8,
) !void {
    if (port == 0 or callback_path.len < 2 or callback_path[0] != '/' or
        std.mem.indexOfAny(u8, callback_path, "?#\\") != null)
        return error.InvalidCallback;
    try writer.print("http://127.0.0.1:{d}{s}", .{ port, callback_path });
}

/// RFC 6749 section 4.1.2.1 error fields of a rejected callback, kept as
/// bounded copies of the decoded UTF-8 values. An `error` longer than its
/// bound is dropped rather than cut; a description is cut at a code point
/// boundary. Display policy (control bytes, credential echoes) stays with
/// each caller.
pub const Rejection = struct {
    pub const error_bytes: usize = 64;
    pub const description_bytes: usize = 512;

    error_storage: [error_bytes]u8 = undefined,
    error_len: usize = 0,
    description_storage: [description_bytes]u8 = undefined,
    description_len: usize = 0,
    description_truncated: bool = false,

    pub fn errorCode(self: *const Rejection) ?[]const u8 {
        return if (self.error_len == 0) null else self.error_storage[0..self.error_len];
    }

    pub fn description(self: *const Rejection) ?[]const u8 {
        return if (self.description_len == 0) null else self.description_storage[0..self.description_len];
    }

    fn retainError(self: *Rejection, value: []const u8) void {
        if (value.len > error_bytes) return;
        @memcpy(self.error_storage[0..value.len], value);
        self.error_len = value.len;
    }

    fn retainDescription(self: *Rejection, value: []const u8) void {
        const len = utf8Prefix(value, description_bytes);
        @memcpy(self.description_storage[0..len], value[0..len]);
        self.description_len = len;
        self.description_truncated = len < value.len;
    }

    pub fn deinit(self: *Rejection) void {
        std.crypto.secureZero(u8, &self.error_storage);
        std.crypto.secureZero(u8, &self.description_storage);
        self.* = .{};
    }
};

/// Longest prefix of valid UTF-8 `value` that fits `max` bytes without
/// splitting a code point.
pub fn utf8Prefix(value: []const u8, max: usize) usize {
    if (value.len <= max) return value.len;
    var len = max;
    while (len > 0 and value[len] & 0xc0 == 0x80) len -= 1;
    return len;
}

pub fn CallbackParser(comptime limits: struct {
    secret_bytes: usize,
    state_bytes: usize,
    target_bytes: usize,
    issuer_bytes: usize,
    error_bytes: usize,
    error_description_bytes: usize,
}) type {
    if (limits.secret_bytes == 0 or limits.state_bytes == 0 or
        limits.target_bytes == 0 or limits.issuer_bytes == 0 or
        limits.error_bytes == 0 or limits.error_description_bytes == 0)
        @compileError("OAuth callback parser limits must be non-zero");
    const CodeSecret = Secret(.{ .max_bytes = limits.secret_bytes });

    return struct {
        const Self = @This();

        pub const Secret = CodeSecret;

        pub const Callback = union(enum) {
            code: CodeSecret,
            rejected: Rejection,

            pub fn deinit(self: *Callback) void {
                switch (self.*) {
                    .code => |*value| value.deinit(),
                    .rejected => |*value| value.deinit(),
                }
                self.* = .{ .rejected = .{} };
            }
        };

        pub const Validation = struct {
            callback_path: []const u8,
            expected_issuer: ?[]const u8 = null,
            issuer_required: bool = false,
            allow_unvalidated_issuer: bool = false,
        };

        pub const Error = error{
            FieldTooLarge,
            InvalidEncoding,
            InvalidCallback,
            StateMismatch,
        };

        pub fn parse(
            allocator: std.mem.Allocator,
            target: []const u8,
            expected_state: []const u8,
            validation: Validation,
        ) (Error || std.mem.Allocator.Error)!Callback {
            if (validation.issuer_required and validation.expected_issuer == null)
                return error.InvalidCallback;
            if (validation.callback_path.len < 2 or
                validation.callback_path[0] != '/' or
                target.len == 0 or target.len > limits.target_bytes)
                return error.InvalidCallback;
            const query_index = std.mem.indexOfScalar(u8, target, '?') orelse
                return error.InvalidCallback;
            if (!std.mem.eql(
                u8,
                target[0..query_index],
                validation.callback_path,
            )) return error.InvalidCallback;
            const query = target[query_index + 1 ..];
            if (query.len == 0 or std.mem.indexOfScalar(u8, query, '#') != null)
                return error.InvalidCallback;

            var code_storage: [limits.secret_bytes]u8 = undefined;
            defer std.crypto.secureZero(u8, &code_storage);
            var state_storage: [limits.state_bytes]u8 = undefined;
            defer std.crypto.secureZero(u8, &state_storage);
            var issuer_storage: [limits.issuer_bytes]u8 = undefined;
            defer std.crypto.secureZero(u8, &issuer_storage);
            var error_seen = false;
            var error_description_seen = false;
            var error_uri_seen = false;
            var code: ?[]const u8 = null;
            var state_value: ?[]const u8 = null;
            var issuer_value: ?[]const u8 = null;
            var issuer_seen = false;

            var rejection: Rejection = .{};
            errdefer rejection.deinit();

            var key_storage: [limits.target_bytes]u8 = undefined;
            defer std.crypto.secureZero(u8, &key_storage);
            var pairs = std.mem.splitScalar(u8, query, '&');
            while (pairs.next()) |pair| {
                if (pair.len == 0) return error.InvalidCallback;
                const equals = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
                const key = try percentDecode(pair[0..equals], &key_storage);
                const value = if (equals < pair.len) pair[equals + 1 ..] else "";
                if (std.mem.eql(u8, key, "code")) {
                    if (code != null) return error.InvalidCallback;
                    code = try percentDecode(value, &code_storage);
                } else if (std.mem.eql(u8, key, "state")) {
                    if (state_value != null) return error.InvalidCallback;
                    state_value = try percentDecode(value, &state_storage);
                } else if (std.mem.eql(u8, key, "iss")) {
                    if (issuer_seen) return error.InvalidCallback;
                    issuer_seen = true;
                    if (validation.expected_issuer != null) {
                        issuer_value = try percentDecode(value, &issuer_storage);
                    } else if (!validation.allow_unvalidated_issuer) {
                        return error.InvalidCallback;
                    } else {
                        _ = try percentDecode(value, &issuer_storage);
                    }
                } else if (std.mem.eql(u8, key, "error")) {
                    if (error_seen) return error.InvalidCallback;
                    var error_storage: [limits.error_bytes]u8 = undefined;
                    defer std.crypto.secureZero(u8, &error_storage);
                    const decoded = try percentDecode(value, &error_storage);
                    if (decoded.len == 0) return error.InvalidCallback;
                    rejection.retainError(decoded);
                    error_seen = true;
                } else if (std.mem.eql(u8, key, "error_description")) {
                    if (error_description_seen) return error.InvalidCallback;
                    var description_storage: [limits.error_description_bytes]u8 = undefined;
                    defer std.crypto.secureZero(u8, &description_storage);
                    rejection.retainDescription(try percentDecode(value, &description_storage));
                    error_description_seen = true;
                } else if (std.mem.eql(u8, key, "error_uri")) {
                    if (error_uri_seen) return error.InvalidCallback;
                    var uri_storage: [limits.target_bytes]u8 = undefined;
                    defer std.crypto.secureZero(u8, &uri_storage);
                    _ = try percentDecode(value, &uri_storage);
                    error_uri_seen = true;
                }
                // RFC 6749: unrecognized response parameters are ignored.
                // No extension can supply state, code or issuer authority.
            }

            const actual_state = state_value orelse return error.StateMismatch;
            if (expected_state.len != limits.state_bytes or
                actual_state.len != limits.state_bytes)
                return error.StateMismatch;
            if (!std.crypto.timing_safe.eql(
                [limits.state_bytes]u8,
                paddedState(expected_state),
                paddedState(actual_state),
            )) return error.StateMismatch;
            if (issuer_value) |actual_issuer| {
                if (!std.mem.eql(u8, validation.expected_issuer.?, actual_issuer))
                    return error.InvalidCallback;
            } else if (validation.issuer_required) return error.InvalidCallback;
            if (error_seen) {
                if (code != null) return error.InvalidCallback;
                return .{ .rejected = rejection };
            }
            if (error_description_seen or error_uri_seen) return error.InvalidCallback;
            rejection.deinit();
            return .{
                .code = try CodeSecret.init(
                    allocator,
                    code orelse return error.InvalidCallback,
                ),
            };
        }

        fn paddedState(value: []const u8) [limits.state_bytes]u8 {
            var padded: [limits.state_bytes]u8 = @splat(0);
            const len = @min(value.len, padded.len);
            @memcpy(padded[0..len], value[0..len]);
            return padded;
        }

        fn percentDecode(input: []const u8, output: []u8) Error![]const u8 {
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
    };
}

/// application/x-www-form-urlencoded byte encoding: RFC 3986 unreserved bytes
/// stay literal and every other byte becomes an upper-case `%XX`, so a space
/// is `%20`.
pub fn percentEncode(
    writer: *std.Io.Writer,
    bytes: []const u8,
) std.Io.Writer.Error!void {
    const hex = "0123456789ABCDEF";
    for (bytes) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '.' or
            byte == '_' or byte == '~')
            try writer.writeByte(byte)
        else
            try writer.writeAll(&.{ '%', hex[byte >> 4], hex[byte & 0x0f] });
    }
}

pub fn writeFormPair(
    writer: *std.Io.Writer,
    key: []const u8,
    value: []const u8,
) std.Io.Writer.Error!void {
    try percentEncode(writer, key);
    try writer.writeByte('=');
    try percentEncode(writer, value);
}

fn writeForm(
    writer: *std.Io.Writer,
    pairs: []const struct { []const u8, []const u8 },
) std.Io.Writer.Error!void {
    for (pairs, 0..) |pair, index| {
        if (index != 0) try writer.writeByte('&');
        try writeFormPair(writer, pair[0], pair[1]);
    }
}

fn writeOptionalPair(
    writer: *std.Io.Writer,
    key: []const u8,
    value: ?[]const u8,
) std.Io.Writer.Error!void {
    const text = value orelse return;
    try writer.writeByte('&');
    try writeFormPair(writer, key, text);
}

/// RFC 6749 section 4.1.1 authorization request, with the RFC 7636 S256
/// challenge and the RFC 8707 resource indicator. Every value is the caller's
/// and already accepted by its policy.
pub const AuthorizationRequest = struct {
    client_id: []const u8,
    redirect_uri: []const u8,
    /// Space-delimited; omitted when empty.
    scope: []const u8 = "",
    resource: ?[]const u8 = null,
};

/// Appends the request to `endpoint`, joining with `&` when the endpoint
/// already carries a query.
pub fn writeAuthorizationUrl(
    writer: *std.Io.Writer,
    endpoint: []const u8,
    material: *const AttemptMaterial,
    request: AuthorizationRequest,
) std.Io.Writer.Error!void {
    try writer.writeAll(endpoint);
    try writer.writeByte(
        if (std.mem.indexOfScalar(u8, endpoint, '?') == null) '?' else '&',
    );
    try writeForm(writer, &.{
        .{ "response_type", "code" },
        .{ "client_id", request.client_id },
        .{ "redirect_uri", request.redirect_uri },
    });
    if (request.scope.len != 0) {
        try writer.writeByte('&');
        try writeFormPair(writer, "scope", request.scope);
    }
    try writer.writeByte('&');
    try writeForm(writer, &.{
        .{ "state", &material.state },
        .{ "code_challenge", &material.challenge },
        .{ "code_challenge_method", "S256" },
    });
    try writeOptionalPair(writer, "resource", request.resource);
}

/// RFC 6749 section 4.1.3 token request body. Client authentication is the
/// caller's and follows the body.
pub const AuthorizationCodeGrant = struct {
    client_id: []const u8,
    code: []const u8,
    code_verifier: []const u8,
    redirect_uri: []const u8,
    resource: ?[]const u8 = null,
};

pub fn writeAuthorizationCodeGrant(
    writer: *std.Io.Writer,
    grant: AuthorizationCodeGrant,
) std.Io.Writer.Error!void {
    try writeForm(writer, &.{
        .{ "grant_type", "authorization_code" },
        .{ "client_id", grant.client_id },
        .{ "code", grant.code },
        .{ "code_verifier", grant.code_verifier },
        .{ "redirect_uri", grant.redirect_uri },
    });
    try writeOptionalPair(writer, "resource", grant.resource);
}

/// RFC 6749 section 6 refresh request body. Client authentication is the
/// caller's and follows the body.
pub const RefreshTokenGrant = struct {
    client_id: []const u8,
    refresh_token: []const u8,
    resource: ?[]const u8 = null,
};

pub fn writeRefreshTokenGrant(
    writer: *std.Io.Writer,
    grant: RefreshTokenGrant,
) std.Io.Writer.Error!void {
    try writeForm(writer, &.{
        .{ "grant_type", "refresh_token" },
        .{ "client_id", grant.client_id },
        .{ "refresh_token", grant.refresh_token },
    });
    try writeOptionalPair(writer, "resource", grant.resource);
}

/// The RFC 6749 section 5.1 `scope` member: absent, or a string.
pub const Scope = union(enum) {
    absent,
    text: []const u8,

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !Scope {
        return .{
            .text = try std.json.innerParse([]const u8, allocator, source, options),
        };
    }
};

/// RFC 6749 section 5.1 successful token response at the protocol layer: a
/// non-empty `access_token`, a Bearer `token_type`, and the optional
/// `refresh_token`, `expires_in` and, when the caller consumes it, `scope`.
/// Members follow std.json's typed rules, so `expires_in` decodes as std.json
/// decodes a u64 ("3600" and 3.6e3 do, 1.5 and out-of-range values do not)
/// and a decoded 0 is rejected. Required members, scope policy, secret limits
/// and time units belong to the caller.
pub fn TokenResponse(comptime options: struct {
    body_bytes: usize,
    scope: enum { ignored, decoded } = .ignored,
}) type {
    if (options.body_bytes == 0)
        @compileError("OAuth token response limit must be non-zero");
    const Raw = switch (options.scope) {
        .decoded => struct {
            access_token: []const u8,
            refresh_token: ?[]const u8 = null,
            token_type: []const u8,
            expires_in: ?u64 = null,
            scope: Scope = .absent,
        },
        .ignored => struct {
            access_token: []const u8,
            refresh_token: ?[]const u8 = null,
            token_type: []const u8,
            expires_in: ?u64 = null,
        },
    };
    const ScopeMember = if (options.scope == .decoded) Scope else void;
    const scope_absent: ScopeMember = if (options.scope == .decoded) .absent else {};

    return struct {
        const Self = @This();

        // Views borrow the decoded body and this value's scratch, so the value
        // stays in place from `decode` until `deinit`.
        access_token: []const u8 = "",
        refresh_token: ?[]const u8 = null,
        expires_in: ?u64 = null,
        scope: ScopeMember = scope_absent,
        fixed: std.heap.FixedBufferAllocator = undefined,
        parsed: ?std.json.Parsed(Raw) = null,
        scratch: [options.body_bytes * 2]u8 = undefined,

        pub fn decode(
            self: *Self,
            body: []const u8,
        ) error{InvalidTokenResponse}!void {
            std.debug.assert(self.parsed == null);
            if (body.len == 0 or body.len > options.body_bytes)
                return error.InvalidTokenResponse;
            self.fixed = .init(&self.scratch);
            self.parsed = std.json.parseFromSlice(
                Raw,
                self.fixed.allocator(),
                body,
                .{ .ignore_unknown_fields = true },
            ) catch return error.InvalidTokenResponse;
            const raw = self.parsed.?.value;
            if (raw.access_token.len == 0 or
                !std.ascii.eqlIgnoreCase(raw.token_type, "Bearer"))
                return error.InvalidTokenResponse;
            if (raw.expires_in) |seconds|
                if (seconds == 0) return error.InvalidTokenResponse;
            self.access_token = raw.access_token;
            self.refresh_token = raw.refresh_token;
            self.expires_in = raw.expires_in;
            if (options.scope == .decoded) self.scope = raw.scope;
        }

        /// Valid after any `decode` outcome.
        pub fn deinit(self: *Self) void {
            if (self.parsed) |*parsed| parsed.deinit();
            std.crypto.secureZero(u8, &self.scratch);
            self.parsed = null;
            self.access_token = "";
            self.refresh_token = null;
            self.expires_in = null;
            self.scope = scope_absent;
        }
    };
}

/// RFC 6749 section 5.2 error response, a shape RFC 7591 section 3.2.2 reuses:
/// the entry of `codes` equal to the `error` member, or null when the body is
/// not a bounded JSON object with a string `error` or carries another code.
pub fn errorCode(
    comptime limits: struct { body_bytes: usize },
    body: []const u8,
    comptime codes: []const []const u8,
) ?[]const u8 {
    if (body.len == 0 or body.len > limits.body_bytes) return null;
    var scratch: [limits.body_bytes * 2]u8 = undefined;
    defer std.crypto.secureZero(u8, &scratch);
    var fixed = std.heap.FixedBufferAllocator.init(&scratch);
    var parsed = std.json.parseFromSlice(
        struct { @"error": []const u8 },
        fixed.allocator(),
        body,
        .{ .ignore_unknown_fields = true },
    ) catch return null;
    defer parsed.deinit();
    inline for (codes) |code| {
        if (std.mem.eql(u8, parsed.value.@"error", code)) return code;
    }
    return null;
}

test "PKCE material has the RFC 7636 S256 shape" {
    var material = AttemptMaterial.fromSeeds(@splat(0x11), @splat(0x22));
    defer material.deinit();
    try std.testing.expectEqual(pkce_encoded_bytes, material.verifier.len);
    try std.testing.expectEqual(pkce_encoded_bytes, material.state.len);
    try std.testing.expectEqual(pkce_encoded_bytes, material.challenge.len);
}

test "callback extensions cannot bypass recognized fields or state" {
    const Parser = CallbackParser(.{
        .secret_bytes = 64,
        .state_bytes = pkce_encoded_bytes,
        .target_bytes = 512,
        .issuer_bytes = 128,
        .error_bytes = 64,
        .error_description_bytes = 128,
    });
    const state = "0123456789012345678901234567890123456789012";
    var callback = try Parser.parse(
        std.testing.allocator,
        "/callback?co%64e=a&state=" ++ state ++ "&extra=1&extra=2&flag",
        state,
        .{ .callback_path = "/callback" },
    );
    defer callback.deinit();
    try std.testing.expectEqualStrings("a", callback.code.view());
    for ([_][]const u8{
        "/callback?code=a&co%64e=b&state=" ++ state,
        "/callback?code=a&state=" ++ state ++ "&st%61te=" ++ state,
        "/callback?code=a&error=access_denied&state=" ++ state ++ "&extra=1",
        "/callback?error=a&error=a&state=" ++ state,
        "/callback?error=a&error_description=a&error_description=a&state=" ++ state,
        "/callback?error=a&error_uri=a&error_uri=a&state=" ++ state,
        "/callback?code=a&error_uri=a&state=" ++ state,
        "/callback?code=a&iss=a&iss=a&state=" ++ state,
    }) |target| {
        try std.testing.expectError(
            error.InvalidCallback,
            Parser.parse(std.testing.allocator, target, state, .{
                .callback_path = "/callback",
                .allow_unvalidated_issuer = true,
            }),
        );
    }
    try std.testing.expectError(
        error.StateMismatch,
        Parser.parse(
            std.testing.allocator,
            "/callback?code=a&state=wrong&extra=" ++ state,
            state,
            .{ .callback_path = "/callback" },
        ),
    );
    for ([_][]const u8{
        "&error_uri=https%3A%2F%2Fexample.test%2Ferror&error_description=Denied&extension=1",
        "&error_description=Denied&error_uri=https%3A%2F%2Fexample.test%2Ferror&extension=1",
    }) |suffix| {
        var storage: [512]u8 = undefined;
        const target = try std.fmt.bufPrint(&storage, "/callback?error=access_denied&state={s}{s}", .{ state, suffix });
        var rejection = try Parser.parse(std.testing.allocator, target, state, .{ .callback_path = "/callback" });
        defer rejection.deinit();
        try std.testing.expect(rejection == .rejected);
        try std.testing.expectEqualStrings("access_denied", rejection.rejected.errorCode().?);
        try std.testing.expectEqualStrings("Denied", rejection.rejected.description().?);
    }
}

test "callback rejection keeps bounded error fields without splitting code points" {
    const Parser = CallbackParser(.{
        .secret_bytes = 64,
        .state_bytes = pkce_encoded_bytes,
        .target_bytes = 4096,
        .issuer_bytes = 128,
        .error_bytes = 256,
        .error_description_bytes = 2048,
    });
    const state = "0123456789012345678901234567890123456789012";
    var storage: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try writer.writeAll("/callback?state=" ++ state ++ "&error=" ++ "e" ** (Rejection.error_bytes + 1) ++ "&error_description=a");
    // 511 ASCII bytes then a two-byte code point straddling the 512-byte bound.
    try writer.writeAll("b" ** (Rejection.description_bytes - 2) ++ "%C3%A9tail");
    var rejection = try Parser.parse(std.testing.allocator, writer.buffered(), state, .{ .callback_path = "/callback" });
    defer rejection.deinit();
    try std.testing.expect(rejection.rejected.errorCode() == null);
    const description = rejection.rejected.description().?;
    try std.testing.expectEqual(Rejection.description_bytes - 1, description.len);
    try std.testing.expect(rejection.rejected.description_truncated);
    try std.testing.expect(std.unicode.utf8ValidateSlice(description));
}

test "secret admission is length only and moves exactly one owned copy" {
    const Bounded = Secret(.{ .max_bytes = 4 });
    var secret = try Bounded.init(std.testing.allocator, "a\x00\x7f");
    try std.testing.expectEqualStrings("a\x00\x7f", secret.view());
    var moved = secret.take();
    defer moved.deinit();
    try std.testing.expect(!secret.owned);
    secret.deinit();
    try std.testing.expectError(error.FieldTooLarge, Bounded.init(std.testing.allocator, ""));
    try std.testing.expectError(error.FieldTooLarge, Bounded.init(std.testing.allocator, "12345"));
    const Parser = CallbackParser(.{
        .secret_bytes = 4,
        .state_bytes = pkce_encoded_bytes,
        .target_bytes = 64,
        .issuer_bytes = 64,
        .error_bytes = 64,
        .error_description_bytes = 64,
    });
    try std.testing.expect(Parser.Secret == Bounded);
}

test "form encoding keeps only RFC 3986 unreserved bytes literal" {
    var storage: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try writeFormPair(&writer, "k y", "aZ09-._~ +/%?&=\x00\x7f\xff");
    try std.testing.expectEqualStrings(
        "k%20y=aZ09-._~%20%2B%2F%25%3F%26%3D%00%7F%FF",
        writer.buffered(),
    );
}

test "authorization request joins an endpoint query and omits empty members" {
    const material = AttemptMaterial.fromSeeds(@splat(0x11), @splat(0x22));
    const pkce = "&state=IiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiI" ++
        "&code_challenge=tZ5lxAKmKebFsoNVx2KKEAImK1W0OlL5QcAnQOO9-vw" ++
        "&code_challenge_method=S256";
    var storage: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try writeAuthorizationUrl(&writer, "https://as.test/authorize?x=1", &material, .{
        .client_id = "c",
        .redirect_uri = "http://127.0.0.1:1/cb",
    });
    try std.testing.expectEqualStrings(
        "https://as.test/authorize?x=1&response_type=code&client_id=c" ++
            "&redirect_uri=http%3A%2F%2F127.0.0.1%3A1%2Fcb" ++ pkce,
        writer.buffered(),
    );
    writer = std.Io.Writer.fixed(&storage);
    try writeAuthorizationUrl(&writer, "https://as.test/authorize", &material, .{
        .client_id = "c",
        .redirect_uri = "http://127.0.0.1:1/cb",
        .scope = "a b",
        .resource = "https://r.test/",
    });
    try std.testing.expectEqualStrings(
        "https://as.test/authorize?response_type=code&client_id=c" ++
            "&redirect_uri=http%3A%2F%2F127.0.0.1%3A1%2Fcb&scope=a%20b" ++ pkce ++
            "&resource=https%3A%2F%2Fr.test%2F",
        writer.buffered(),
    );
}

test "token request bodies put the resource indicator last" {
    var storage: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try writeAuthorizationCodeGrant(&writer, .{
        .client_id = "c",
        .code = "x y",
        .code_verifier = "v",
        .redirect_uri = "r",
        .resource = "s",
    });
    try std.testing.expectEqualStrings(
        "grant_type=authorization_code&client_id=c&code=x%20y&code_verifier=v&redirect_uri=r&resource=s",
        writer.buffered(),
    );
    writer = std.Io.Writer.fixed(&storage);
    try writeRefreshTokenGrant(&writer, .{ .client_id = "c", .refresh_token = "t" });
    try std.testing.expectEqualStrings(
        "grant_type=refresh_token&client_id=c&refresh_token=t",
        writer.buffered(),
    );
}

test "token responses decode protocol members and leave policy to the caller" {
    const Decoded = TokenResponse(.{ .body_bytes = 256, .scope = .decoded });
    var full: Decoded = .{};
    defer full.deinit();
    try full.decode(
        \\{"access_token":"a","refresh_token":null,"token_type":"bearer","expires_in":"60","scope":"read","extra":1}
    );
    try std.testing.expectEqualStrings("a", full.access_token);
    try std.testing.expectEqual(@as(?[]const u8, null), full.refresh_token);
    try std.testing.expectEqual(@as(?u64, 60), full.expires_in);
    try std.testing.expectEqualStrings("read", full.scope.text);

    var minimal: Decoded = .{};
    defer minimal.deinit();
    try minimal.decode(
        \\{"access_token":"a","refresh_token":"","token_type":"Bearer"}
    );
    try std.testing.expectEqualStrings("", minimal.refresh_token.?);
    try std.testing.expectEqual(@as(?u64, null), minimal.expires_in);
    try std.testing.expect(minimal.scope == .absent);

    for ([_][]const u8{
        "",
        "{}",
        "x" ** 257,
        \\{"access_token":"","token_type":"Bearer"}
        ,
        \\{"access_token":"a","token_type":"mac"}
        ,
        \\{"access_token":"a","token_type":"Bearer","expires_in":0}
        ,
        \\{"access_token":"a","token_type":"Bearer","expires_in":"0"}
        ,
        \\{"access_token":"a","token_type":"Bearer","expires_in":1.5}
        ,
        \\{"access_token":"a","token_type":"Bearer","scope":null}
        ,
        \\{"access_token":"a","token_type":"Bearer","scope":42}
        ,
        \\{"access_token":"a","access_token":"b","token_type":"Bearer"}
        ,
    }) |body| {
        var rejected: Decoded = .{};
        defer rejected.deinit();
        try std.testing.expectError(error.InvalidTokenResponse, rejected.decode(body));
    }

    const Ignored = TokenResponse(.{ .body_bytes = 256 });
    for ([_][]const u8{
        \\{"access_token":"a","token_type":"Bearer","scope":null}
        ,
        \\{"access_token":"a","token_type":"Bearer","scope":42,"scope":"x"}
        ,
    }) |body| {
        var accepted: Ignored = .{};
        defer accepted.deinit();
        try accepted.decode(body);
        try std.testing.expectEqualStrings("a", accepted.access_token);
    }
}

test "error responses match only the caller's codes" {
    const codes: []const []const u8 = &.{ "invalid_request", "invalid_grant" };
    try std.testing.expectEqualStrings("invalid_grant", errorCode(
        .{ .body_bytes = 1024 },
        "{\"error\":\"invalid\\u005fgrant\",\"x\":{\"y\":[1]}}",
        codes,
    ).?);
    for ([_][]const u8{
        "",
        "[]",
        "{\"error\":7}",
        "{\"error\":\"invalid_scope\"}",
        "{\"error\":\"invalid_grant\",\"error\":\"invalid_grant\"}",
        "{\"error\":\"invalid_grant\",\"pad\":\"" ++ "p" ** 1000 ++ "\"}",
    }) |body|
        try std.testing.expectEqual(
            @as(?[]const u8, null),
            errorCode(.{ .body_bytes = 1024 }, body, codes),
        );
}
