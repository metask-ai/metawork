//! Owned multimodal input and its Runtime-wide preparation/execution budget.
const std = @import("std");
const sdk = @import("metask_agentcore");

pub const InputLimits = struct {
    max_parts: usize,
    max_image_raw_bytes: usize,
};

pub const input_limits: InputLimits = .{
    .max_parts = sdk.types.MAX_RUN_INPUT_PARTS_V1,
    .max_image_raw_bytes = sdk.types.MAX_RUN_INPUT_IMAGE_DATA_BYTES_V1 / 4 * 3,
};

pub const ImageFormat = enum {
    png,
    jpeg,
    gif,
    webp,

    fn mediaType(self: ImageFormat) []const u8 {
        return switch (self) {
            .png => "image/png",
            .jpeg => "image/jpeg",
            .gif => "image/gif",
            .webp => "image/webp",
        };
    }
};

pub const InputPart = union(enum) {
    text: []const u8,
    image: struct {
        format: ImageFormat,
        /// Encoded image-file bytes, not pixels or Base64. Borrowed until
        /// prepareRun returns; the caller owns format/content correctness.
        bytes: []const u8,
    },
};

const Error = error{ InvalidRunInput, RunInputTooLarge, RunInputBudgetExceeded };

pub const Budget = struct {
    limit: usize,
    used: std.atomic.Value(usize) = .init(0),

    fn reserve(self: *Budget, bytes: usize) Error!void {
        var used = self.used.load(.monotonic);
        while (true) {
            if (bytes > self.limit - used) return error.RunInputBudgetExceeded;
            used = self.used.cmpxchgWeak(used, used + bytes, .monotonic, .monotonic) orelse return;
        }
    }

    fn release(self: *Budget, bytes: usize) void {
        const previous = self.used.fetchSub(bytes, .monotonic);
        std.debug.assert(previous >= bytes);
    }
};

pub const OwnedInput = struct {
    parts: []sdk.types.RunInputPartV1,
    storage: []u8,
    has_images: bool,
    budget: *Budget,
    reserved_bytes: usize,

    pub fn init(
        allocator: std.mem.Allocator,
        input: []const InputPart,
        max_text_bytes: usize,
        budget: *Budget,
    ) (Error || std.mem.Allocator.Error)!OwnedInput {
        if (input.len == 0) return error.InvalidRunInput;
        if (input.len > sdk.types.MAX_RUN_INPUT_PARTS_V1) return error.RunInputTooLarge;
        var text_bytes: usize = 0;
        var storage_bytes: usize = 0;
        var prompt_bytes: usize = 0;
        var has_images = false;
        for (input) |part| {
            const size = switch (part) {
                .text => |value| text: {
                    text_bytes = try add(text_bytes, value.len);
                    if (text_bytes > max_text_bytes) return error.RunInputTooLarge;
                    if (value.len == 0 or !std.unicode.utf8ValidateSlice(value))
                        return error.InvalidRunInput;
                    break :text value.len;
                },
                .image => |value| image: {
                    const encoded_size = try base64EncodedSize(
                        value.bytes.len,
                        sdk.types.MAX_RUN_INPUT_IMAGE_DATA_BYTES_V1,
                    );
                    has_images = true;
                    prompt_bytes = try add(prompt_bytes, value.format.mediaType().len);
                    break :image encoded_size;
                },
            };
            storage_bytes = try add(storage_bytes, size);
            prompt_bytes = try add(prompt_bytes, size);
            if (prompt_bytes > sdk.types.MAX_PROMPT_BYTES_V1) return error.RunInputTooLarge;
        }
        const parts_bytes = std.math.mul(usize, input.len, @sizeOf(sdk.types.RunInputPartV1)) catch
            return error.RunInputTooLarge;
        const reserved_bytes = try add(storage_bytes, parts_bytes);
        try budget.reserve(reserved_bytes);
        errdefer budget.release(reserved_bytes);
        const parts = try allocator.alloc(sdk.types.RunInputPartV1, input.len);
        errdefer allocator.free(parts);
        const storage = try allocator.alloc(u8, storage_bytes);
        errdefer allocator.free(storage);
        var offset: usize = 0;
        for (input, parts) |part, *owned| {
            switch (part) {
                .text => |value| {
                    const destination = storage[offset..][0..value.len];
                    @memcpy(destination, value);
                    owned.* = sdk.textPart(destination);
                    offset += destination.len;
                },
                .image => |value| {
                    const size = std.base64.standard.Encoder.calcSize(value.bytes.len);
                    const encoded = std.base64.standard.Encoder.encode(storage[offset..][0..size], value.bytes);
                    owned.* = sdk.imagePart(value.format.mediaType(), encoded);
                    offset += size;
                },
            }
        }
        return .{
            .parts = parts,
            .storage = storage,
            .has_images = has_images,
            .budget = budget,
            .reserved_bytes = reserved_bytes,
        };
    }

    pub fn deinit(self: *OwnedInput, allocator: std.mem.Allocator) void {
        allocator.free(self.storage);
        allocator.free(self.parts);
        self.budget.release(self.reserved_bytes);
        self.* = undefined;
    }
};

fn add(a: usize, b: usize) Error!usize {
    return std.math.add(usize, a, b) catch error.RunInputTooLarge;
}

fn base64EncodedSize(raw_bytes: usize, max_encoded_bytes: usize) Error!usize {
    if (raw_bytes == 0) return error.InvalidRunInput;
    std.debug.assert(max_encoded_bytes % 4 == 0);
    // Bound raw input before calculating Base64 size or allocating.
    if (raw_bytes > max_encoded_bytes / 4 * 3) return error.RunInputTooLarge;
    return std.base64.standard.Encoder.calcSize(raw_bytes);
}
