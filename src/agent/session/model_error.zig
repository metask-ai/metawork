//! Bounded, self-contained model failure observation for one Run.
//! Views borrow this value, never the SDK parser or the owning Session.

const std = @import("std");
const sdk = @import("metask_agentcore");

pub const ModelError = struct {
    pub const Category = sdk.protocol.ModelErrorCategory;
    pub const Retry = sdk.protocol.ModelErrorRetry;
    pub const View = sdk.protocol.ModelError;

    // Acceptance limits from the locked Core's AGENTCORE_BINARY_ABI.md,
    // "Model failure detail". The SDK does not export these limits; the
    // canonical Host provider probe independently qualifies its output bounds.
    pub const limits = struct {
        pub const message_bytes = 1024;
        pub const code_bytes = 128;
        pub const type_bytes = 128;
        pub const request_id_bytes = 128;
    };

    run_id: u64,
    category: Category,
    code: ?Text(limits.code_bytes),
    type: ?Text(limits.type_bytes),
    message: Text(limits.message_bytes),
    http_status: ?u16,
    request_id: ?Text(limits.request_id_bytes),
    retry: Retry,
    retry_after_ms: ?u64,
    attempts: u32,
    truncated: bool,

    pub fn init(value: View) error{InvalidModelError}!ModelError {
        if (value.run_id == 0 or value.attempts == 0 or value.message.len == 0)
            return error.InvalidModelError;
        return .{
            .run_id = value.run_id,
            .category = value.category,
            .code = try Text(limits.code_bytes).optional(value.code),
            .type = try Text(limits.type_bytes).optional(value.type),
            .message = try Text(limits.message_bytes).init(value.message),
            .http_status = value.http_status,
            .request_id = try Text(limits.request_id_bytes).optional(value.request_id),
            .retry = value.retry,
            .retry_after_ms = value.retry_after_ms,
            .attempts = value.attempts,
            .truncated = value.truncated,
        };
    }

    pub fn view(self: *const ModelError) View {
        return .{
            .run_id = self.run_id,
            .category = self.category,
            .code = if (self.code) |*value| value.slice() else null,
            .type = if (self.type) |*value| value.slice() else null,
            .message = self.message.slice(),
            .http_status = self.http_status,
            .request_id = if (self.request_id) |*value| value.slice() else null,
            .retry = self.retry,
            .retry_after_ms = self.retry_after_ms,
            .attempts = self.attempts,
            .truncated = self.truncated,
        };
    }
};

fn Text(comptime capacity: usize) type {
    return struct {
        bytes: [capacity]u8 = @splat(0),
        len: usize,

        fn init(value: []const u8) error{InvalidModelError}!@This() {
            if (value.len > capacity or !std.unicode.utf8ValidateSlice(value))
                return error.InvalidModelError;
            var result: @This() = .{ .len = value.len };
            @memcpy(result.bytes[0..value.len], value);
            return result;
        }

        fn optional(value: ?[]const u8) error{InvalidModelError}!?@This() {
            return if (value) |text| try init(text) else null;
        }

        fn slice(self: *const @This()) []const u8 {
            return self.bytes[0..self.len];
        }
    };
}

test "ModelError owns parsed fields and copied values have independent views" {
    var parsed = try sdk.decodeCoreEvent(std.testing.allocator,
        \\{"model_error":{"run_id":9,"category":"rate_limited","code":"future_quota_code","type":"future_type","message":"服务拒绝","http_status":200,"request_id":"req-fixture","retry":"unknown","retry_after_ms":123,"attempts":2,"truncated":true}}
    );
    var owned = ModelError.init(parsed.value.known.model_error) catch |err| {
        parsed.deinit();
        return err;
    };
    parsed.deinit();
    const copied = owned;
    @memset(&owned.message.bytes, 'x');
    @memset(&owned.code.?.bytes, 'y');
    const observed = copied.view();
    try std.testing.expectEqual(@as(u64, 9), observed.run_id);
    try std.testing.expectEqual(.rate_limited, observed.category);
    try std.testing.expectEqualStrings("future_quota_code", observed.code.?);
    try std.testing.expectEqualStrings("future_type", observed.type.?);
    try std.testing.expectEqualStrings("服务拒绝", observed.message);
    try std.testing.expectEqual(@as(?u16, 200), observed.http_status);
    try std.testing.expectEqualStrings("req-fixture", observed.request_id.?);
    try std.testing.expectEqual(.unknown, observed.retry);
    try std.testing.expectEqual(@as(?u64, 123), observed.retry_after_ms);
    try std.testing.expectEqual(@as(u32, 2), observed.attempts);
    try std.testing.expect(observed.truncated);
}

test "ModelError preserves null and present empty optional fields" {
    var value: ModelError.View = .{ .run_id = 1, .category = .unknown, .message = "unknown", .retry = .unknown, .attempts = 1 };
    const absent = try ModelError.init(value);
    try std.testing.expect(absent.view().code == null);
    try std.testing.expect(absent.view().type == null);
    try std.testing.expect(absent.view().request_id == null);
    try std.testing.expect(absent.view().http_status == null);
    try std.testing.expect(absent.view().retry_after_ms == null);
    value.code = "";
    value.type = "";
    value.request_id = "";
    const empty = try ModelError.init(value);
    try std.testing.expectEqualStrings("", empty.view().code.?);
    try std.testing.expectEqualStrings("", empty.view().type.?);
    try std.testing.expectEqualStrings("", empty.view().request_id.?);
    try std.testing.expect(!empty.view().truncated);
}

test "ModelError accepts exact UTF-8 capacities without changing upstream truncation" {
    var message = [_]u8{'m'} ** ModelError.limits.message_bytes;
    var code = [_]u8{'c'} ** ModelError.limits.code_bytes;
    var kind = [_]u8{'t'} ** ModelError.limits.type_bytes;
    var request = [_]u8{'r'} ** ModelError.limits.request_id_bytes;
    @memcpy(message[message.len - 2 ..], "é");
    @memcpy(code[code.len - 2 ..], "é");
    @memcpy(kind[kind.len - 2 ..], "é");
    @memcpy(request[request.len - 2 ..], "é");
    const owned = try ModelError.init(.{ .run_id = 1, .category = .output_limit, .message = &message, .code = &code, .type = &kind, .request_id = &request, .retry = .not_retryable, .attempts = 1 });
    const view = owned.view();
    try std.testing.expectEqualStrings(&message, view.message);
    try std.testing.expectEqualStrings(&code, view.code.?);
    try std.testing.expectEqualStrings(&kind, view.type.?);
    try std.testing.expectEqualStrings(&request, view.request_id.?);
    try std.testing.expect(!view.truncated);
    try std.testing.expect(view.http_status == null);
}

test "ModelError rejects each oversized or invalid UTF-8 field" {
    inline for (.{ "message", "code", "type", "request_id" }) |field| {
        const capacity = @field(ModelError.limits, field ++ "_bytes");
        const oversized = [_]u8{'x'} ** (capacity + 1);
        var value: ModelError.View = .{ .run_id = 1, .category = .unknown, .message = "valid", .retry = .unknown, .attempts = 1 };
        @field(value, field) = &oversized;
        try std.testing.expectError(error.InvalidModelError, ModelError.init(value));
        @field(value, field) = &.{0xff};
        try std.testing.expectError(error.InvalidModelError, ModelError.init(value));
    }
}

test "ModelError rejects missing Run message or attempt facts" {
    var value: ModelError.View = .{ .run_id = 0, .category = .unknown, .message = "valid", .retry = .unknown, .attempts = 1 };
    try std.testing.expectError(error.InvalidModelError, ModelError.init(value));
    value.run_id = 1;
    value.attempts = 0;
    try std.testing.expectError(error.InvalidModelError, ModelError.init(value));
    value.attempts = 1;
    value.message = "";
    try std.testing.expectError(error.InvalidModelError, ModelError.init(value));
}
