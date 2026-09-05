const std = @import("std");
const codec = @import("codec.zig");
const types = @import("types.zig");

const WireMessage = struct {
    role: []const u8,
    content: []const u8,
};

pub fn encode(
    allocator: std.mem.Allocator,
    config: types.CodecConfig,
    request: types.Request,
) codec.Error!codec.EncodedRequest {
    const extra: usize = @intFromBool(request.system.len != 0);
    const messages = allocator.alloc(WireMessage, request.messages.len + extra) catch
        return error.OutOfMemory;
    defer allocator.free(messages);
    var index: usize = 0;
    if (request.system.len != 0) {
        messages[index] = .{ .role = "system", .content = request.system };
        index += 1;
    }
    for (request.messages) |message| {
        messages[index] = .{
            .role = switch (message.role) {
                .user => "user",
                .assistant => "assistant",
            },
            .content = message.text,
        };
        index += 1;
    }
    const body = std.json.Stringify.valueAlloc(allocator, .{
        .model = config.model,
        .messages = messages,
        .max_completion_tokens = request.max_output_tokens,
    }, .{}) catch return error.OutOfMemory;
    var encoded = try codec.EncodedRequest.init(allocator, config.base_url, body);
    errdefer encoded.deinit();
    try encoded.addHeader("content-type", "application/json", false);
    try encoded.addHeader("accept", "application/json", false);
    const authorization = std.fmt.allocPrint(
        allocator,
        "Bearer {s}",
        .{config.credential},
    ) catch return error.OutOfMemory;
    defer {
        std.crypto.secureZero(u8, authorization);
        allocator.free(authorization);
    }
    try encoded.addHeader("authorization", authorization, true);
    return encoded;
}

pub fn decode(
    allocator: std.mem.Allocator,
    body: []const u8,
) codec.Error!types.Result {
    var parsed = try codec.parseJson(allocator, body);
    defer parsed.deinit();
    const root = try codec.object(parsed.value);
    if (root.get("error")) |value| if (value != .null)
        return error.MalformedResponse;

    const choices = try codec.array(root.get("choices") orelse
        return error.MalformedResponse);
    if (choices.items.len != 1) return error.UnsupportedResponse;
    const choice = try codec.object(choices.items[0]);
    const reason = try stopReason(try codec.string(choice.get("finish_reason") orelse
        return error.MalformedResponse));
    const message = try codec.object(choice.get("message") orelse
        return error.MalformedResponse);
    if (message.get("tool_calls")) |value| switch (value) {
        .null => {},
        .array => |items| if (items.items.len != 0) return error.UnsupportedResponse,
        else => return error.MalformedResponse,
    };
    inline for (.{ "function_call", "refusal" }) |field| {
        if (message.get(field)) |value| if (value != .null)
            return error.UnsupportedResponse;
    }
    const text = try codec.string(message.get("content") orelse
        return error.MalformedResponse);
    const usage = if (root.get("usage")) |value|
        try decodeUsage(try codec.object(value))
    else
        types.Usage{};
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try codec.appendText(allocator, &output, text);
    return codec.finishResult(allocator, &output, usage, reason);
}

fn decodeUsage(value: std.json.ObjectMap) codec.Error!types.Usage {
    var usage: types.Usage = .{
        .input_tokens = try codec.usageField(value, "prompt_tokens"),
        .output_tokens = try codec.usageField(value, "completion_tokens"),
    };
    if (value.get("prompt_tokens_details")) |details_value| if (details_value != .null) {
        usage.cache_read_input_tokens = try codec.usageField(
            try codec.object(details_value),
            "cached_tokens",
        );
    };
    return usage;
}

fn stopReason(value: []const u8) codec.Error!types.StopReason {
    if (std.mem.eql(u8, value, "stop")) return .end_turn;
    if (std.mem.eql(u8, value, "length")) return .max_tokens;
    if (std.mem.eql(u8, value, "content_filter")) return .content_filter;
    if (std.mem.eql(u8, value, "tool_calls") or
        std.mem.eql(u8, value, "function_call"))
        return error.UnsupportedResponse;
    return error.UnsupportedResponse;
}

test "OpenAI Chat codec encodes an explicit completion budget" {
    var encoded = try encode(std.testing.allocator, .{
        .credential = "fixture-secret",
        .base_url = "https://example.test/v1/chat/completions",
        .model = "fixture-model",
    }, .{
        .messages = &.{.{ .role = .user, .text = "hello" }},
        .max_output_tokens = 1234,
    });
    defer encoded.deinit();
    var parsed = try codec.parseJson(std.testing.allocator, encoded.body);
    defer parsed.deinit();
    const root = try codec.object(parsed.value);
    try std.testing.expectEqual(
        @as(i64, 1234),
        root.get("max_completion_tokens").?.integer,
    );
    try std.testing.expect(root.get("max_tokens") == null);
}

test "OpenAI codec decodes one non-streaming text result" {
    var result = try decode(
        std.testing.allocator,
        "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"hello\"},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":1}}",
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("hello", result.text);
    try std.testing.expectEqual(types.StopReason.end_turn, result.stop_reason);
    try std.testing.expectEqual(@as(u64, 3), result.usage.input_tokens);
}

test "OpenAI codec rejects tool calls" {
    try std.testing.expectError(
        error.UnsupportedResponse,
        decode(
            std.testing.allocator,
            "{\"choices\":[{\"message\":{\"content\":null,\"tool_calls\":[{}]},\"finish_reason\":\"tool_calls\"}]}",
        ),
    );
}
