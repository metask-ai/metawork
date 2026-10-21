//! Pure encoded-image container facts. Callers own admission and EOF policy.
//! No pixel decoder, platform effects, credentials, or Product/Agent authority.
const std = @import("std");

test "container termination is a fact and trailing bytes do not repair truncation" {
    // Structurally bounded JPEG; this fixture does not assert pixel decodability.
    const jpeg = "\xff\xd8\xff\xc0\x00\x0b\x08\x00\x02\x00\x03\x01\x01\x11\x00" ++
        "\xff\xda\x00\x08\x01\x01\x00\x00\x3f\x00\x01\xff\xd9";
    const info = try inspect(jpeg ++ "appended-motion-data");
    try std.testing.expectEqual(Format.jpeg, info.format);
    try std.testing.expectEqual(@as(u32, 3), info.width);
    try std.testing.expectEqual(@as(u32, 2), info.height);
    try std.testing.expectEqual(jpeg.len, info.primary_end);
    try std.testing.expectEqual(@as(usize, 20), info.trailingBytes(jpeg.len + 20));
    for (0..jpeg.len) |len| {
        if (inspect(jpeg[0..len])) |_| return error.TruncatedContainerAccepted else |_| {}
    }
}

test "WebP RIFF bounds remain strict inside a file with trailing data" {
    const webp = "RIFF\x12\x00\x00\x00WEBPVP8L\x05\x00\x00\x00\x2f\x02\x40\x00\x00\x00";
    const info = try inspect(webp ++ "tail");
    try std.testing.expectEqual(Format.webp, info.format);
    try std.testing.expectEqual(webp.len, info.container_end);
    try std.testing.expectEqual(@as(u64, 6), info.pixels());
    var damaged = webp.*;
    damaged[16] = 0xff;
    try std.testing.expectError(error.InvalidImage, inspect(&damaged));
    damaged = webp.*;
    damaged[4] = 0xff;
    try std.testing.expectError(error.InvalidImage, inspect(&damaged));
}

pub const Format = enum { png, jpeg, webp };
pub const Info = struct {
    format: Format,
    width: u32,
    height: u32,
    animated: bool = false,
    primary_end: usize,
    container_end: usize,

    pub fn pixels(self: Info) u64 {
        return @as(u64, self.width) * self.height;
    }
    pub fn trailingBytes(self: Info, length: usize) usize {
        return length - self.container_end;
    }
    pub fn mediaType(self: Info) []const u8 {
        return switch (self.format) {
            .png => "image/png",
            .jpeg => "image/jpeg",
            .webp => "image/webp",
        };
    }
};

pub fn inspect(bytes: []const u8) error{ InvalidImage, UnsupportedFormat }!Info {
    if (std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n")) return inspectPng(bytes);
    if (std.mem.startsWith(u8, bytes, "\xff\xd8")) return inspectJpeg(bytes);
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) return inspectWebp(bytes);
    return error.UnsupportedFormat;
}

fn inspectJpeg(bytes: []const u8) !Info {
    var width: u32 = 0;
    var height: u32 = 0;
    var offset: usize = 2;
    var frame = false;
    var scan = false;
    var entropy = false;
    while (offset < bytes.len) {
        if (entropy) {
            while (offset < bytes.len and bytes[offset] != 0xff) : (offset += 1) {}
        }
        if (offset >= bytes.len or bytes[offset] != 0xff) return error.InvalidImage;
        while (offset < bytes.len and bytes[offset] == 0xff) : (offset += 1) {}
        if (offset >= bytes.len) return error.InvalidImage;
        const marker = bytes[offset];
        offset += 1;
        if (entropy and (marker == 0 or (marker >= 0xd0 and marker <= 0xd7))) continue;
        entropy = false;
        if (marker == 0xd9) {
            if (!frame or !scan or width == 0 or height == 0) return error.InvalidImage;
            return .{ .format = .jpeg, .width = width, .height = height, .primary_end = offset, .container_end = offset };
        }
        if (marker == 0 or marker == 0xd8 or (marker >= 0xd0 and marker <= 0xd7)) return error.InvalidImage;
        if (marker == 0x01) continue;
        if (bytes.len - offset < 2) return error.InvalidImage;
        const length: usize = std.mem.readInt(u16, bytes[offset..][0..2], .big);
        if (length < 2 or length > bytes.len - offset) return error.InvalidImage;
        const segment = bytes[offset..][0..length];
        const is_frame = marker >= 0xc0 and marker <= 0xcf and marker != 0xc4 and marker != 0xc8 and marker != 0xcc;
        if (is_frame) {
            if (frame or length < 8) return error.InvalidImage;
            const components: usize = segment[7];
            if (components == 0 or components > 4 or length != 8 + 3 * components) return error.InvalidImage;
            width = std.mem.readInt(u16, segment[5..7], .big);
            height = std.mem.readInt(u16, segment[3..5], .big);
            frame = true;
        }
        if (marker == 0xda) {
            if (!frame or length < 6) return error.InvalidImage;
            const components: usize = segment[2];
            if (components == 0 or components > 4 or length != 6 + 2 * components) return error.InvalidImage;
            scan = true;
            entropy = true;
        }
        offset += length;
    }
    return error.InvalidImage;
}

fn inspectWebp(input: []const u8) !Info {
    const declared: usize = std.mem.readInt(u32, input[4..8], .little);
    if (declared < 4 or declared > input.len - 8) return error.InvalidImage;
    const bytes = input[0 .. declared + 8];
    var animated = false;
    var offset: usize = 12;
    var image = false;
    var width: u32 = 0;
    var height: u32 = 0;
    var canvas_width: u32 = 0;
    var canvas_height: u32 = 0;
    while (bytes.len - offset >= 8) {
        const kind = bytes[offset..][0..4];
        const length: usize = std.mem.readInt(u32, bytes[offset + 4 ..][0..4], .little);
        if (length > bytes.len - offset - 8) return error.InvalidImage;
        const data = bytes[offset + 8 ..][0..length];
        if (std.mem.eql(u8, kind, "ANIM") or std.mem.eql(u8, kind, "ANMF")) animated = true;
        if (std.mem.eql(u8, kind, "VP8X")) {
            if (offset != 12 or length != 10) return error.InvalidImage;
            if (data[0] & 2 != 0) animated = true;
            canvas_width = 1 + @as(u32, std.mem.readInt(u24, data[4..7], .little));
            canvas_height = 1 + @as(u32, std.mem.readInt(u24, data[7..10], .little));
        } else if (std.mem.eql(u8, kind, "VP8 ")) {
            if (image or length < 10 or data[0] & 1 != 0 or !std.mem.eql(u8, data[3..6], "\x9d\x01\x2a")) return error.InvalidImage;
            width = std.mem.readInt(u16, data[6..8], .little) & 0x3fff;
            height = std.mem.readInt(u16, data[8..10], .little) & 0x3fff;
            image = true;
        } else if (std.mem.eql(u8, kind, "VP8L")) {
            if (image or length < 5 or data[0] != 0x2f) return error.InvalidImage;
            const packed_size = std.mem.readInt(u32, data[1..5], .little);
            if (packed_size >> 29 != 0) return error.InvalidImage;
            width = (packed_size & 0x3fff) + 1;
            height = ((packed_size >> 14) & 0x3fff) + 1;
            image = true;
        }
        offset += 8 + length;
        if (length & 1 != 0) {
            if (offset >= bytes.len) return error.InvalidImage;
            offset += 1;
        }
    }
    if ((!image and !animated) or offset != bytes.len) return error.InvalidImage;
    if (image and canvas_width != 0 and (canvas_width != width or canvas_height != height)) return error.InvalidImage;
    if (!image) {
        width = canvas_width;
        height = canvas_height;
    }
    if (width == 0 or height == 0) return error.InvalidImage;
    return .{ .format = .webp, .width = width, .height = height, .animated = animated, .primary_end = bytes.len, .container_end = bytes.len };
}

fn inspectPng(bytes: []const u8) !Info {
    var width: u32 = 0;
    var height: u32 = 0;
    var animated = false;
    if (bytes.len < 45 or !std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) return error.InvalidImage;
    var offset: usize = 8;
    var saw_data = false;
    while (bytes.len - offset >= 12) {
        const len: usize = std.mem.readInt(u32, bytes[offset..][0..4], .big);
        if (len > bytes.len - offset - 12) return error.InvalidImage;
        const kind = bytes[offset + 4 ..][0..4];
        const payload = bytes[offset + 8 ..][0..len];
        const crc = std.mem.readInt(u32, bytes[offset + 8 + len ..][0..4], .big);
        if (std.hash.Crc32.hash(bytes[offset + 4 ..][0 .. len + 4]) != crc) return error.InvalidImage;
        if (offset == 8) {
            if (!std.mem.eql(u8, kind, "IHDR") or len != 13) return error.InvalidImage;
            width = std.mem.readInt(u32, payload[0..4], .big);
            height = std.mem.readInt(u32, payload[4..8], .big);
            if (width == 0 or height == 0) return error.InvalidImage;
        } else if (std.mem.eql(u8, kind, "IHDR")) return error.InvalidImage;
        if (std.mem.eql(u8, kind, "acTL") or std.mem.eql(u8, kind, "fcTL") or std.mem.eql(u8, kind, "fdAT")) animated = true;
        if (std.mem.eql(u8, kind, "IDAT")) saw_data = true;
        offset += len + 12;
        if (std.mem.eql(u8, kind, "IEND")) {
            if (len != 0 or !saw_data) return error.InvalidImage;
            return .{ .format = .png, .width = width, .height = height, .animated = animated, .primary_end = offset, .container_end = offset };
        }
    }
    return error.InvalidImage;
}
