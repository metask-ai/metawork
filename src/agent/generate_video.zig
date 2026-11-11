//! Model-facing GenerateVideo contract. The Run supplies the execution effect.
const std = @import("std");
const delivery = @import("agent_file_delivery");

pub const name = "GenerateVideo";
pub const description = "Generate one new MP4 video from a prompt and save it in the current workspace. A request may incur a charge even if it fails or is interrupted. Do not automatically retry. After a successful save, use DeliverFile to deliver the finished file to the user.";
pub const schema =
    \\{"type":"object","properties":{"prompt":{"type":"string","description":"Describe the requested video."}},"required":["prompt"],"additionalProperties":false}
;

pub const max_prompt_bytes = 16 * 1024;
pub const max_arguments_bytes = max_prompt_bytes * 6 + 64;
pub const result_bytes = delivery.Receipt.max_path_bytes * 6 + 128;

/// The owner retains the context until Run callbacks are quiescent. The effect
/// borrows the prompt and cancellation signal only during the call. It returns
/// saved only after committing the file, including if cancellation races with
/// that commit. Once submitted, an uncertain provider outcome must be reported
/// as outcome_unknown and must not be retried by the effect.
pub const Input = struct {
    context: *anyopaque,
    generate_fn: *const fn (*anyopaque, []const u8, *const std.atomic.Value(bool)) Outcome,
};

pub const Receipt = struct {
    path: [delivery.Receipt.max_path_bytes]u8 = @splat(0),
    path_len: usize,
    size_bytes: u64,

    pub fn init(path: []const u8, size_bytes: u64) !Receipt {
        try validateFile(path, size_bytes);
        var receipt: Receipt = .{ .path_len = path.len, .size_bytes = size_bytes };
        @memcpy(receipt.path[0..path.len], path);
        return receipt;
    }

    fn validate(self: *const Receipt) !void {
        if (self.path_len > self.path.len) return error.InvalidReceipt;
        try validateFile(self.path[0..self.path_len], self.size_bytes);
    }

    fn validateFile(path: []const u8, size_bytes: u64) !void {
        if (size_bytes == 0 or !std.mem.endsWith(u8, path, ".mp4")) return error.InvalidReceipt;
        delivery.validatePath(path) catch return error.InvalidReceipt;
    }
};

pub const Failure = enum { invalid_arguments, unavailable, capacity, cancelled, outcome_unknown, provider_rejected, invalid_response, output_failed };
pub const Outcome = union(enum) { saved: Receipt, failed: Failure };

const PromptText = struct {
    value: []const u8,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !PromptText {
        if (try source.peekNextTokenType() != .string) return error.UnexpectedToken;
        return .{ .value = try std.json.innerParse([]const u8, allocator, source, options) };
    }
};

pub fn prompt(allocator: std.mem.Allocator, arguments: []const u8) ![]u8 {
    if (arguments.len > max_arguments_bytes) return error.InvalidArguments;
    const parsed = std.json.parseFromSlice(struct { prompt: PromptText }, allocator, arguments, .{
        .duplicate_field_behavior = .@"error",
        .max_value_len = max_prompt_bytes,
    }) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidArguments;
    defer parsed.deinit();
    const value = parsed.value.prompt.value;
    if (value.len > max_prompt_bytes or std.mem.trim(u8, value, " \r\n\t").len == 0 or
        !std.unicode.utf8ValidateSlice(value)) return error.InvalidArguments;
    return allocator.dupe(u8, value);
}

pub fn result(buffer: []u8, outcome: Outcome) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    switch (outcome) {
        .saved => |*receipt| {
            try receipt.validate();
            try std.json.Stringify.value(.{
                .status = "saved",
                .path = receipt.path[0..receipt.path_len],
                .media_type = "video/mp4",
                .size_bytes = receipt.size_bytes,
            }, .{}, &writer);
        },
        .failed => |failure| try std.json.Stringify.value(.{ .status = @tagName(failure) }, .{}, &writer),
    }
    return writer.buffered();
}
