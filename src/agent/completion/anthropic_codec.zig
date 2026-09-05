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
    const messages = allocator.alloc(WireMessage, request.messages.len) catch
        return error.OutOfMemory;
    defer allocator.free(messages);
    for (request.messages, 0..) |message, index| {
        messages[index] = .{
            .role = switch (message.role) {
                .user => "user",
                .assistant => "assistant",
            },
            .content = message.text,
        };
    }
    const body = if (request.system.len == 0)
        std.json.Stringify.valueAlloc(allocator, .{
            .model = config.model,
            .messages = messages,
            .max_tokens = request.max_output_tokens,
        }, .{}) catch return error.OutOfMemory
    else
        std.json.Stringify.valueAlloc(allocator, .{
            .model = config.model,
            .system = request.system,
            .messages = messages,
            .max_tokens = request.max_output_tokens,
        }, .{}) catch return error.OutOfMemory;
    var encoded = try codec.EncodedRequest.init(allocator, config.base_url, body);
    errdefer encoded.deinit();
    try encoded.addHeader("content-type", "application/json", false);
    try encoded.addHeader("accept", "application/json", false);
    try encoded.addHeader("anthropic-version", "2023-06-01", false);
    try encoded.addHeader("x-api-key", config.credential, true);
    return encoded;
}

pub fn decode(
    allocator: std.mem.Allocator,
    body: []const u8,
) codec.Error!types.Result {
    var parsed = try codec.parseJson(allocator, body);
    defer parsed.deinit();
    const root = try codec.object(parsed.value);
    if (root.get("type")) |value| {
        const root_type = try codec.string(value);
        if (std.mem.eql(u8, root_type, "error")) return error.MalformedResponse;
        if (!std.mem.eql(u8, root_type, "message")) return error.MalformedResponse;
    }
    const blocks = try codec.array(root.get("content") orelse
        return error.MalformedResponse);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    for (blocks.items) |block_value| {
        const block = try codec.object(block_value);
        const block_type = try codec.string(block.get("type") orelse
            return error.MalformedResponse);
        if (std.mem.eql(u8, block_type, "text")) {
            try codec.appendText(
                allocator,
                &output,
                try codec.string(block.get("text") orelse
                    return error.MalformedResponse),
            );
        } else if (std.mem.eql(u8, block_type, "thinking")) {
            _ = try codec.string(block.get("thinking") orelse
                return error.MalformedResponse);
        } else if (std.mem.eql(u8, block_type, "redacted_thinking")) {
            _ = block.get("data") orelse return error.MalformedResponse;
        } else {
            return error.UnsupportedResponse;
        }
    }
    const reason = try stopReason(try codec.string(root.get("stop_reason") orelse
        return error.MalformedResponse));
    const usage = if (root.get("usage")) |value|
        try decodeUsage(try codec.object(value))
    else
        types.Usage{};
    return codec.finishResult(allocator, &output, usage, reason);
}

fn decodeUsage(value: std.json.ObjectMap) codec.Error!types.Usage {
    return .{
        .input_tokens = try codec.usageField(value, "input_tokens"),
        .output_tokens = try codec.usageField(value, "output_tokens"),
        .cache_read_input_tokens = try codec.usageField(value, "cache_read_input_tokens"),
        .cache_creation_input_tokens = try codec.usageField(value, "cache_creation_input_tokens"),
    };
}

fn stopReason(value: []const u8) codec.Error!types.StopReason {
    if (std.mem.eql(u8, value, "end_turn")) return .end_turn;
    if (std.mem.eql(u8, value, "max_tokens")) return .max_tokens;
    if (std.mem.eql(u8, value, "stop_sequence")) return .stop_sequence;
    if (std.mem.eql(u8, value, "refusal")) return .refusal;
    if (std.mem.eql(u8, value, "tool_use")) return error.UnsupportedResponse;
    return error.UnsupportedResponse;
}

test "Anthropic codec uses the caller's explicit output budget" {
    var encoded = try encode(std.testing.allocator, .{
        .credential = "fixture-secret",
        .base_url = "https://example.test/v1/messages",
        .model = "fixture-model",
    }, .{
        .messages = &.{.{ .role = .user, .text = "hello" }},
        .max_output_tokens = 1234,
    });
    defer encoded.deinit();
    var parsed = try codec.parseJson(std.testing.allocator, encoded.body);
    defer parsed.deinit();
    const root = try codec.object(parsed.value);
    try std.testing.expectEqual(@as(i64, 1234), root.get("max_tokens").?.integer);
}

test "Anthropic codec decodes one non-streaming text result" {
    var result = try decode(
        std.testing.allocator,
        "{\"type\":\"message\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"hidden\"},{\"type\":\"text\",\"text\":\"hello\"}],\"stop_reason\":\"end_turn\",\"usage\":{\"input_tokens\":3,\"output_tokens\":1}}",
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("hello", result.text);
    try std.testing.expectEqual(types.StopReason.end_turn, result.stop_reason);
}

test "Anthropic codec rejects tool use" {
    try std.testing.expectError(
        error.UnsupportedResponse,
        decode(
            std.testing.allocator,
            "{\"type\":\"message\",\"content\":[{\"type\":\"tool_use\"}],\"stop_reason\":\"tool_use\"}",
        ),
    );
}
