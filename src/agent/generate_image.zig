//! Exact model-facing tool shape and bounded callback result encoding.
const std = @import("std");
const image = @import("image_generation.zig");

pub const name = "GenerateImage";
pub const description = "Generate one new image from a prompt and save it in the current workspace. Every invocation creates a new image, including identical prompts. Available only when the host supplies image execution configuration. On outcome_unknown the request may already have been accepted or charged; do not blindly retry. The result is a saved file reference, not a claim that you have viewed the image.";
pub const schema =
    \\{"type":"object","properties":{"prompt":{"type":"string","description":"Describe the requested image."}},"required":["prompt"],"additionalProperties":false}
;

pub fn prompt(allocator: std.mem.Allocator, arguments: []const u8, limit: usize) ![]u8 {
    if (arguments.len > limit * 6 + 64) return error.InvalidArguments;
    const parsed = std.json.parseFromSlice(struct { prompt: []const u8 }, allocator, arguments, .{
        .duplicate_field_behavior = .@"error",
        .max_value_len = limit,
    }) catch return error.InvalidArguments;
    defer parsed.deinit();
    const value = parsed.value.prompt;
    if (value.len == 0 or value.len > limit or std.mem.trim(u8, value, " \r\n\t").len == 0 or
        !std.unicode.utf8ValidateSlice(value)) return error.InvalidArguments;
    return allocator.dupe(u8, value);
}

pub fn result(allocator: std.mem.Allocator, outcome: image.Outcome) ![]u8 {
    return switch (outcome) {
        .saved => |*receipt| std.json.Stringify.valueAlloc(allocator, .{
            .status = "saved",
            .path = receipt.pathView(),
            .media_type = "image/png",
            .size_bytes = receipt.size_bytes,
        }, .{}),
        .failed => |failure| std.json.Stringify.valueAlloc(allocator, .{ .status = @tagName(failure) }, .{}),
    };
}

test "GenerateImage arguments reject execution configuration and duplicate keys" {
    for ([_][]const u8{ "{}", "{\"prompt\":\" \"}", "{\"prompt\":1}", "{\"prompt\":\"a\",\"model\":\"other\"}", "{\"prompt\":\"a\",\"prompt\":\"b\"}" }) |value|
        try std.testing.expectError(error.InvalidArguments, prompt(std.testing.allocator, value, 64));
    const value = try prompt(std.testing.allocator, "{\"prompt\":\"http://example.test/ is part of the picture\"}", 64);
    defer std.testing.allocator.free(value);
    try std.testing.expect(std.mem.startsWith(u8, value, "http://"));
}
