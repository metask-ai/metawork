//! Product-neutral OAuth trust-boundary mechanics.
//!
//! Callers own endpoint paths, issuer policy, field limits, response copy and
//! domain error mapping. This leaf only owns PKCE generation, bounded secret
//! lifetime, strict callback query parsing and constant-time state comparison.
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

    return struct {
        const Self = @This();

        pub const Secret = struct {
            allocator: std.mem.Allocator = undefined,
            bytes: []u8 = &.{},
            owned: bool = false,

            pub fn init(
                allocator: std.mem.Allocator,
                value: []const u8,
            ) (error{FieldTooLarge} || std.mem.Allocator.Error)!Secret {
                if (value.len == 0 or value.len > limits.secret_bytes)
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
            var code: ?[]const u8 = null;
            var state_value: ?[]const u8 = null;
            var issuer_value: ?[]const u8 = null;
            var issuer_seen = false;

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
                    error_seen = true;
                } else if (std.mem.eql(u8, key, "error_description")) {
                    if (error_description_seen) return error.InvalidCallback;
                    var description_storage: [limits.error_description_bytes]u8 = undefined;
                    defer std.crypto.secureZero(u8, &description_storage);
                    _ = try percentDecode(value, &description_storage);
                    error_description_seen = true;
                } else {
                    return error.InvalidCallback;
                }
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

test "PKCE material has the RFC 7636 S256 shape" {
    var material = AttemptMaterial.fromSeeds(@splat(0x11), @splat(0x22));
    defer material.deinit();
    try std.testing.expectEqual(pkce_encoded_bytes, material.verifier.len);
    try std.testing.expectEqual(pkce_encoded_bytes, material.state.len);
    try std.testing.expectEqual(pkce_encoded_bytes, material.challenge.len);
}

test "callback parser rejects duplicate and unknown parameters" {
    const Parser = CallbackParser(.{
        .secret_bytes = 64,
        .state_bytes = pkce_encoded_bytes,
        .target_bytes = 512,
        .issuer_bytes = 128,
        .error_bytes = 64,
        .error_description_bytes = 128,
    });
    const state = "0123456789012345678901234567890123456789012";
    try std.testing.expectError(
        error.InvalidCallback,
        Parser.parse(
            std.testing.allocator,
            "/callback?code=a&code=b&state=" ++ state,
            state,
            .{ .callback_path = "/callback" },
        ),
    );
    try std.testing.expectError(
        error.InvalidCallback,
        Parser.parse(
            std.testing.allocator,
            "/callback?code=a&state=" ++ state ++ "&extra=1",
            state,
            .{ .callback_path = "/callback" },
        ),
    );
}
