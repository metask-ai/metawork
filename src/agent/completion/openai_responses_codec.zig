//! Bounded, non-streaming Responses text Completion. No server-side state or tools.
const std = @import("std");
const codec = @import("codec.zig");
const types = @import("types.zig");

pub fn encode(
    allocator: std.mem.Allocator,
    config: types.CodecConfig,
    request: types.Request,
) codec.Error!codec.EncodedRequest {
    const Input = struct { role: []const u8, content: []const u8 };
    const input = allocator.alloc(Input, request.messages.len) catch return error.OutOfMemory;
    defer allocator.free(input);
    for (request.messages, input) |message, *item| item.* = .{
        .role = switch (message.role) {
            .user => "user",
            .assistant => "assistant",
        },
        .content = message.text,
    };
    const body = std.json.Stringify.valueAlloc(allocator, .{
        .model = config.model,
        .instructions = if (request.system.len != 0) request.system else @as(?[]const u8, null),
        .input = input,
        .max_output_tokens = request.max_output_tokens,
        .stream = false,
        .store = false,
    }, .{ .emit_null_optional_fields = false }) catch return error.OutOfMemory;
    var encoded = try codec.EncodedRequest.init(allocator, config.base_url, body);
    errdefer encoded.deinit();
    try encoded.addHeader("content-type", "application/json", false);
    try encoded.addHeader("accept", "application/json", false);
    const authorization = std.fmt.allocPrint(allocator, "Bearer {s}", .{config.credential}) catch return error.OutOfMemory;
    defer {
        std.crypto.secureZero(u8, authorization);
        allocator.free(authorization);
    }
    try encoded.addHeader("authorization", authorization, true);
    return encoded;
}

pub fn decode(allocator: std.mem.Allocator, body: []const u8) codec.Error!types.Result {
    var parsed = try codec.parseJson(allocator, body);
    defer parsed.deinit();
    const root = try codec.object(parsed.value);
    if (root.get("error")) |value| if (value != .null) return error.MalformedResponse;
    const status = try codec.string(root.get("status") orelse return error.MalformedResponse);
    const reason: types.StopReason = if (std.mem.eql(u8, status, "completed")) completed: {
        if (root.get("incomplete_details")) |value| if (value != .null) return error.MalformedResponse;
        break :completed .end_turn;
    } else if (std.mem.eql(u8, status, "incomplete")) incomplete: {
        const details = try codec.object(root.get("incomplete_details") orelse return error.MalformedResponse);
        const value = try codec.string(details.get("reason") orelse return error.MalformedResponse);
        if (std.mem.eql(u8, value, "max_output_tokens")) break :incomplete .max_tokens;
        if (std.mem.eql(u8, value, "content_filter")) break :incomplete .content_filter;
        return error.UnsupportedResponse;
    } else return error.UnsupportedResponse;

    const items = try codec.array(root.get("output") orelse return error.MalformedResponse);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    for (items.items) |item_value| {
        const item = try codec.object(item_value);
        const kind = try codec.string(item.get("type") orelse return error.MalformedResponse);
        // A one-shot caller does not continue the response. Never project private
        // reasoning, summaries or encrypted reasoning into title/probe text.
        if (std.mem.eql(u8, kind, "reasoning")) continue;
        if (!std.mem.eql(u8, kind, "message")) return error.UnsupportedResponse;
        const role = try codec.string(item.get("role") orelse return error.MalformedResponse);
        if (!std.mem.eql(u8, role, "assistant")) return error.UnsupportedResponse;
        const message_status = try codec.string(item.get("status") orelse return error.MalformedResponse);
        if (!std.mem.eql(u8, message_status, "completed") and
            !(reason != .end_turn and std.mem.eql(u8, message_status, "incomplete")))
            return error.UnsupportedResponse;
        const content = try codec.array(item.get("content") orelse return error.MalformedResponse);
        for (content.items) |part_value| {
            const part = try codec.object(part_value);
            const part_kind = try codec.string(part.get("type") orelse return error.MalformedResponse);
            if (!std.mem.eql(u8, part_kind, "output_text")) return error.UnsupportedResponse;
            try codec.appendText(allocator, &output, try codec.string(part.get("text") orelse return error.MalformedResponse));
        }
    }
    var usage: types.Usage = .{};
    if (root.get("usage")) |value| if (value != .null) {
        const fields = try codec.object(value);
        usage.input_tokens = try codec.usageField(fields, "input_tokens");
        usage.output_tokens = try codec.usageField(fields, "output_tokens");
        if (fields.get("input_tokens_details")) |details| if (details != .null) {
            usage.cache_read_input_tokens = try codec.usageField(try codec.object(details), "cached_tokens");
            if (usage.cache_read_input_tokens > usage.input_tokens) return error.MalformedResponse;
        };
    };
    return codec.finishResult(allocator, &output, usage, reason);
}

test "Responses Completion owns an explicit non-streaming stateless request" {
    var encoded = try encode(std.testing.allocator, .{
        .credential = "fixture-secret",
        .base_url = "https://example.test/custom-endpoint",
        .model = "fixture-model",
    }, .{
        .system = "title only",
        .messages = &.{.{ .role = .user, .text = "hello\nworld" }},
        .max_output_tokens = 1234,
        .connect_timeout_ms = 1_000,
    });
    defer encoded.deinit();
    try std.testing.expectEqualStrings("https://example.test/custom-endpoint", encoded.view("fixture-source", 1).url);
    var parsed = try codec.parseJson(std.testing.allocator, encoded.body);
    defer parsed.deinit();
    const root = try codec.object(parsed.value);
    try std.testing.expectEqual(false, root.get("stream").?.bool);
    try std.testing.expectEqual(false, root.get("store").?.bool);
    try std.testing.expectEqual(@as(i64, 1234), root.get("max_output_tokens").?.integer);
    try std.testing.expect(root.get("messages") == null and root.get("tools") == null);
    try std.testing.expectEqualStrings("title only", root.get("instructions").?.string);
    const input = root.get("input").?.array.items[0].object;
    try std.testing.expectEqualStrings("user", input.get("role").?.string);
    try std.testing.expectEqualStrings("hello\nworld", input.get("content").?.string);
    try std.testing.expect(encoded.view("fixture-source", 1).headers[2].sensitive);
    try std.testing.expectEqualStrings("Bearer fixture-secret", encoded.view("fixture-source", 1).headers[2].value);
}

test "Responses request releases partial allocations on failure" {
    const Fixture = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var encoded = try encode(allocator, .{
                .credential = "fixture-secret",
                .base_url = "https://example.test/endpoint",
                .model = "fixture-model",
            }, .{
                .messages = &.{.{ .role = .user, .text = "hello" }},
                .max_output_tokens = 1234,
                .connect_timeout_ms = 1_000,
            });
            defer encoded.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Fixture.run, .{});
}

const text_item =
    \\{"type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"title"}]}
;

test "Responses Completion projects only output text and preserves usage" {
    var result = try decode(std.testing.allocator,
        \\{"status":"completed","output":[{"type":"reasoning","encrypted_content":"private","summary":[{"text":"not a title"}]},
    ++ text_item ++
        \\],"usage":{"input_tokens":10,"output_tokens":3,"input_tokens_details":{"cached_tokens":4}}}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("title", result.text);
    try std.testing.expectEqual(types.StopReason.end_turn, result.stop_reason);
    try std.testing.expectEqual(@as(u64, 10), result.usage.input_tokens);
    try std.testing.expectEqual(@as(u64, 3), result.usage.output_tokens);
    try std.testing.expectEqual(@as(u64, 4), result.usage.cache_read_input_tokens);
}

test "Responses Completion rejects tools, refusal, nonterminal and empty output" {
    for ([_][]const u8{
        "{\"status\":\"completed\",\"output\":[" ++ text_item ++ ",{\"type\":\"function_call\"}]}",
        "{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{\"type\":\"refusal\",\"refusal\":\"no\"}]}]}",
        "{\"status\":\"in_progress\",\"output\":[" ++ text_item ++ "]}",
        "{\"status\":\"failed\",\"output\":[" ++ text_item ++ "]}",
    }) |body| try std.testing.expectError(error.UnsupportedResponse, decode(std.testing.allocator, body));
    try std.testing.expectError(error.MalformedResponse, decode(std.testing.allocator, "{\"status\":\"completed\",\"output\":[]}"));
}

test "Responses Completion keeps truncation distinct from success" {
    var result = try decode(
        std.testing.allocator,
        "{\"status\":\"incomplete\",\"incomplete_details\":{\"reason\":\"max_output_tokens\"},\"output\":[" ++ text_item ++ "]}",
    );
    defer result.deinit();
    try std.testing.expectEqual(types.StopReason.max_tokens, result.stop_reason);
    try std.testing.expectError(error.UnsupportedResponse, decode(
        std.testing.allocator,
        "{\"status\":\"incomplete\",\"incomplete_details\":{\"reason\":\"unknown\"},\"output\":[" ++ text_item ++ "]}",
    ));
}
