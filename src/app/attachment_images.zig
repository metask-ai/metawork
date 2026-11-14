//! Application-owned image preview capability using public Native SDK APIs.
const std = @import("std");
const native_sdk = @import("native_sdk");
const product_control = @import("metawork_product_control");
const app_platform = @import("platform.zig");

/// Public SDK codec runs on the Native loop thread. Original bytes remain
/// in the Product store; a bounded PNG serves model input at its encoded byte
/// ceiling. The caller owns both budgets: the pixel budget bounds the decoded
/// buffer and the decoder's own downscale, the byte budget bounds the encoded
/// result. Decoded dimensions are returned because only this capability knows
/// them and both the chip derivative and the Renderer layout need them.
pub fn prepare(
    context: ?*anyopaque,
    allocator: std.mem.Allocator,
    bytes: []const u8,
    max_bytes: usize,
    max_pixels: usize,
) anyerror!product_control.AttachmentPreparedImage {
    if (max_bytes == 0 or max_bytes > product_control.max_attachment_preview_bytes) return error.ImageTooLarge;
    if (max_pixels == 0 or max_pixels > product_control.max_attachment_preview_pixels) return error.ImageTooLarge;
    const self: *app_platform.Adapter = @ptrCast(@alignCast(context orelse return error.RuntimeUnavailable));
    if (std.Thread.getCurrentId() != self.main_thread_id) return error.WrongThread;
    const svc = self.services() orelse return error.RuntimeUnavailable;
    const pixels = try allocator.alloc(u8, max_pixels * 4);
    defer {
        std.crypto.secureZero(u8, pixels);
        allocator.free(pixels);
    }
    var pixel_budget = max_pixels;
    while (true) {
        const image = try svc.decodeImage(bytes, pixels, pixel_budget);
        const output = try native_sdk.canvas.app_icon.encodePng(allocator, image.rgba8, image.width, image.height);
        if (output.len <= max_bytes) return .{
            .bytes = output,
            .width = std.math.cast(u32, image.width) orelse return error.ImageTooLarge,
            .height = std.math.cast(u32, image.height) orelse return error.ImageTooLarge,
        };
        const next_budget = pixel_budget * max_bytes / output.len * 9 / 10;
        std.crypto.secureZero(u8, output);
        allocator.free(output);
        // Preserve useful screenshot resolution when compression fits. For
        // high-entropy images, reduce the same preview within the byte budget.
        if (pixel_budget == 1) return error.ImageTooLarge;
        pixel_budget = @max(1, @min(pixel_budget - 1, next_budget));
    }
}

test "high-entropy previews reduce pixel count and remain within the encoded input budget" {
    const Decoder = struct {
        calls: usize = 0,
        fn decode(context: ?*anyopaque, _: []const u8, buffer: []u8, max_pixels: usize) anyerror!native_sdk.platform.DecodedImage {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            const width = @min(max_pixels, 1200);
            const height = max_pixels / width;
            const pixels = buffer[0 .. width * height * 4];
            var state: u32 = 12345;
            for (pixels) |*byte| {
                state = state *% 1664525 +% 1013904223;
                byte.* = @truncate(state >> 24);
            }
            return .{ .width = width, .height = height, .rgba8 = pixels };
        }
    };
    var decoder: Decoder = .{};
    var platform = app_platform.Adapter.init(std.testing.io, std.Thread.getCurrentId());
    platform.platform_services = .{ .context = &decoder, .decode_image_fn = Decoder.decode };
    const preview = try prepare(
        &platform,
        std.testing.allocator,
        "original decoder input",
        product_control.max_attachment_preview_bytes,
        product_control.max_attachment_preview_pixels,
    );
    defer std.testing.allocator.free(preview.bytes);
    try std.testing.expect(decoder.calls >= 2);
    try std.testing.expect(preview.bytes.len <= product_control.max_attachment_preview_bytes);
    try std.testing.expectEqual(@as(u64, preview.width) * preview.height <= product_control.max_attachment_preview_pixels, true);
    try std.testing.expectEqualSlices(u8, &native_sdk.canvas.png.signature, preview.bytes[0..8]);
    // This worst-case preview actually exercises the larger checkpoint string
    // budget after Base64 encoding, instead of proving it with a tiny image.
    try std.testing.expect(std.base64.standard.Encoder.calcSize(preview.bytes.len) > 1024 * 1024);
}

test "a chip derivative decodes once inside its own pixel budget" {
    const Decoder = struct {
        calls: usize = 0,
        budget: usize = 0,
        fn decode(context: ?*anyopaque, _: []const u8, buffer: []u8, max_pixels: usize) anyerror!native_sdk.platform.DecodedImage {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            self.budget = max_pixels;
            // The real codec scales to fit the budget while keeping the ratio.
            const width = @max(1, std.math.sqrt(max_pixels * 4 / 3));
            const height = @max(1, max_pixels / width);
            const pixels = buffer[0 .. width * height * 4];
            @memset(pixels, 0x20);
            return .{ .width = width, .height = height, .rgba8 = pixels };
        }
    };
    var decoder: Decoder = .{};
    var platform = app_platform.Adapter.init(std.testing.io, std.Thread.getCurrentId());
    platform.platform_services = .{ .context = &decoder, .decode_image_fn = Decoder.decode };
    const budget = product_control.attachmentThumbnailPixelBudget(1673, 1255);
    const thumbnail = try prepare(
        &platform,
        std.testing.allocator,
        "bounded preview input",
        product_control.max_attachment_thumbnail_bytes,
        budget,
    );
    defer std.testing.allocator.free(thumbnail.bytes);
    try std.testing.expectEqual(@as(usize, 1), decoder.calls);
    try std.testing.expectEqual(budget, decoder.budget);
    try std.testing.expect(thumbnail.bytes.len <= product_control.max_attachment_thumbnail_bytes);
    try std.testing.expect(@max(thumbnail.width, thumbnail.height) <= product_control.max_attachment_thumbnail_side);
}
