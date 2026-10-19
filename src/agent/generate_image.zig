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

pub fn result(buffer: []u8, outcome: image.Outcome) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    switch (outcome) {
        .saved => |*receipt| try std.json.Stringify.value(.{
            .status = "saved",
            .path = receipt.pathView(),
            .media_type = "image/png",
            .size_bytes = receipt.size_bytes,
        }, .{}, &writer),
        .failed => |failure| try std.json.Stringify.value(.{ .status = @tagName(failure) }, .{}, &writer),
    }
    return writer.buffered();
}

test "GenerateImage arguments reject execution configuration and duplicate keys" {
    for ([_][]const u8{ "{}", "{\"prompt\":\" \"}", "{\"prompt\":1}", "{\"prompt\":\"a\",\"model\":\"other\"}", "{\"prompt\":\"a\",\"prompt\":\"b\"}" }) |value|
        try std.testing.expectError(error.InvalidArguments, prompt(std.testing.allocator, value, 64));
    const value = try prompt(std.testing.allocator, "{\"prompt\":\"http://example.test/ is part of the picture\"}", 64);
    defer std.testing.allocator.free(value);
    try std.testing.expect(std.mem.startsWith(u8, value, "http://"));
}

test "GenerateImage every valid receipt fits the minimum result budget including JSON escaping" {
    const path = [_]u8{1} ** image.Receipt.max_path_bytes;
    const receipt = try image.Receipt.init(&path, std.math.maxInt(usize));
    var buffer: [image.min_result_bytes]u8 = undefined;
    const encoded = try result(&buffer, .{ .saved = receipt });
    const decoded = try std.json.parseFromSlice(struct { status: []const u8, path: []const u8, media_type: []const u8, size_bytes: usize }, std.testing.allocator, encoded, .{});
    defer decoded.deinit();
    try std.testing.expectEqualSlices(u8, &path, decoded.value.path);
    try std.testing.expectEqual(std.math.maxInt(usize), decoded.value.size_bytes);
    try std.testing.expect(!(image.Limits{ .result_bytes = 256 }).validate());
    var limits: image.Limits = .{};
    limits.memory_bytes = limits.workingBytes();
    try std.testing.expect(limits.validate());
}
