const std = @import("std");
const codec = @import("codec.zig");
const types = @import("types.zig");

const WirePart = struct {
    text: []const u8,
};

const WireContent = struct {
    role: []const u8,
    parts: []const WirePart,
};

const WireSystemInstruction = struct {
    parts: []const WirePart,
};

pub fn encode(
    allocator: std.mem.Allocator,
    config: types.Config,
    request: types.Request,
) codec.Error!codec.EncodedRequest {
    const parts = allocator.alloc(WirePart, request.messages.len) catch
        return error.OutOfMemory;
    defer allocator.free(parts);
    const contents = allocator.alloc(WireContent, request.messages.len) catch
        return error.OutOfMemory;
    defer allocator.free(contents);
    for (request.messages, 0..) |message, index| {
        parts[index] = .{ .text = message.text };
        contents[index] = .{
            .role = switch (message.role) {
                .user => "user",
                .assistant => "model",
            },
            .parts = parts[index..][0..1],
        };
    }
    const body = if (request.system.len == 0)
        std.json.Stringify.valueAlloc(allocator, .{
            .contents = contents,
        }, .{}) catch return error.OutOfMemory
    else body: {
        const system_parts = [_]WirePart{.{ .text = request.system }};
        break :body std.json.Stringify.valueAlloc(allocator, .{
            .systemInstruction = WireSystemInstruction{ .parts = &system_parts },
            .contents = contents,
        }, .{}) catch return error.OutOfMemory;
    };
    const encoded_model = try encodePathSegment(allocator, config.model);
    defer allocator.free(encoded_model);
    const separator: []const u8 = if (std.mem.endsWith(u8, config.base_url, "/")) "" else "/";
    const url = std.fmt.allocPrint(
        allocator,
        "{s}{s}v1beta/models/{s}:generateContent",
        .{ config.base_url, separator, encoded_model },
    ) catch return error.OutOfMemory;
    defer allocator.free(url);
    var encoded = try codec.EncodedRequest.init(allocator, url, body);
    errdefer encoded.deinit();
    try encoded.addHeader("content-type", "application/json", false);
    try encoded.addHeader("accept", "application/json", false);
    try encoded.addHeader("x-goog-api-key", config.credential, true);
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
    const candidates = try codec.array(root.get("candidates") orelse
        return error.MalformedResponse);
    if (candidates.items.len != 1) return error.UnsupportedResponse;
    const candidate = try codec.object(candidates.items[0]);
    const content = try codec.object(candidate.get("content") orelse
        return error.MalformedResponse);
    const parts = try codec.array(content.get("parts") orelse
        return error.MalformedResponse);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    for (parts.items) |part_value| {
        const part = try codec.object(part_value);
        inline for (.{
            "functionCall",
            "functionResponse",
            "inlineData",
            "executableCode",
            "codeExecutionResult",
        }) |field| if (part.get(field)) |value| if (value != .null)
            return error.UnsupportedResponse;
        const text = try codec.string(part.get("text") orelse
            return error.UnsupportedResponse);
        const thought = if (part.get("thought")) |value|
            try codec.boolean(value)
        else
            false;
        if (!thought) try codec.appendText(allocator, &output, text);
    }
    const reason = try stopReason(try codec.string(candidate.get("finishReason") orelse
        return error.MalformedResponse));
    const usage = if (root.get("usageMetadata")) |value|
        try decodeUsage(try codec.object(value))
    else
        types.Usage{};
    return codec.finishResult(allocator, &output, usage, reason);
}

fn decodeUsage(value: std.json.ObjectMap) codec.Error!types.Usage {
    return .{
        .input_tokens = try codec.usageField(value, "promptTokenCount"),
        .output_tokens = try codec.usageField(value, "candidatesTokenCount"),
        .cache_read_input_tokens = try codec.usageField(value, "cachedContentTokenCount"),
    };
}

fn stopReason(value: []const u8) codec.Error!types.StopReason {
    if (std.mem.eql(u8, value, "STOP")) return .end_turn;
    if (std.mem.eql(u8, value, "MAX_TOKENS")) return .max_tokens;
    inline for (.{
        "SAFETY",
        "RECITATION",
        "BLOCKLIST",
        "PROHIBITED_CONTENT",
        "SPII",
    }) |blocked| if (std.mem.eql(u8, value, blocked)) return .content_filter;
    return error.UnsupportedResponse;
}

fn encodePathSegment(
    allocator: std.mem.Allocator,
    value: []const u8,
) codec.Error![]u8 {
    const maximum = std.math.mul(usize, value.len, 3) catch
        return error.ResourceLimit;
    const output = allocator.alloc(u8, maximum) catch return error.OutOfMemory;
    var length: usize = 0;
    const hex = "0123456789ABCDEF";
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or
            byte == '.' or byte == '~')
        {
            output[length] = byte;
            length += 1;
        } else {
            output[length] = '%';
            output[length + 1] = hex[byte >> 4];
            output[length + 2] = hex[byte & 0x0f];
            length += 3;
        }
    }
    return allocator.realloc(output, length) catch {
        allocator.free(output);
        return error.OutOfMemory;
    };
}

test "Gemini codec decodes one non-streaming text result" {
    var result = try decode(
        std.testing.allocator,
        "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"hidden\",\"thought\":true},{\"text\":\"hello\"}]},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":3,\"candidatesTokenCount\":1}}",
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("hello", result.text);
    try std.testing.expectEqual(types.StopReason.end_turn, result.stop_reason);
}

test "Gemini request is non-streaming and keeps the credential out of the URL" {
    var encoded = try encode(std.testing.allocator, .{
        .provider = .gemini,
        .credential = "SECRET",
        .base_url = "https://generativelanguage.googleapis.com",
        .model = "gemini/test",
    }, .{ .messages = &.{.{ .role = .user, .text = "hello" }} });
    defer encoded.deinit();
    try std.testing.expect(std.mem.endsWith(u8, encoded.url, ":generateContent"));
    try std.testing.expect(std.mem.indexOf(u8, encoded.url, "SECRET") == null);
    try std.testing.expect(encoded.headers[2].sensitive);
}

test "Gemini codec rejects function calls" {
    try std.testing.expectError(
        error.UnsupportedResponse,
        decode(
            std.testing.allocator,
            "{\"candidates\":[{\"content\":{\"parts\":[{\"functionCall\":{}}]},\"finishReason\":\"STOP\"}]}",
        ),
    );
}
