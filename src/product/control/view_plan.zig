//! Product-owned immutable sanitized read plan and bounded JSON encoding.
//! String escaping uses Zig's encoder; no credential, execution handle or Product pointer is retained.
const std = @import("std");
// CPU work quantum; independent of the Bridge single-result transport ceiling.
pub const max_step_bytes = 128 * 1024;
pub const Error = std.mem.Allocator.Error || error{ SnapshotTooLarge, InvalidViewEncoding, StaleSnapshot, InvalidOffset };
const String = struct { at: usize, start: usize, len: usize, escaped_len: usize };
pub const Mark = struct { strings: usize, text: usize, expansion: usize };
pub const Plan = struct {
    skeleton: []u8 = &.{},
    text: std.ArrayList(u8) = .empty,
    strings: std.ArrayList(String) = .empty,
    expansion: usize = 0,
    total: usize = 0,
    id: u64 = 0,
    security_epoch: u64 = 0,
    storage_identity: usize = 0,
    produced: usize = 0,
    skeleton_at: usize = 0,
    string_at: usize = 0,
    text_at: usize = 0,
    opened: bool = false,
    tail: [6]u8 = undefined,
    tail_at: usize = 0,
    tail_len: usize = 0,

    pub fn mark(self: *const Plan) Mark {
        return .{ .strings = self.strings.items.len, .text = self.text.items.len, .expansion = self.expansion };
    }
    pub fn rollback(self: *Plan, point: Mark) void {
        std.crypto.secureZero(u8, self.text.items[point.text..]);
        self.text.shrinkRetainingCapacity(point.text);
        self.strings.shrinkRetainingCapacity(point.strings);
        self.expansion = point.expansion;
    }
    pub fn appendText(self: *Plan, allocator: std.mem.Allocator, budget: usize, text: []const u8) Error!void {
        if (text.len > budget -| self.text.items.len) return error.SnapshotTooLarge;
        try self.text.appendSlice(allocator, text);
    }
    pub fn commitString(self: *Plan, allocator: std.mem.Allocator, writer: *std.Io.Writer, start: usize) Error!void {
        const text = self.text.items[start..];
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidViewEncoding;
        var escaped_len: usize = 0;
        for (text) |byte| escaped_len += switch (byte) {
            34, 92, 10, 13, 9, 8, 12 => @as(usize, 2),
            0...7, 11, 14...31 => 6,
            else => 1,
        };
        try self.strings.append(allocator, .{ .at = writer.end, .start = start, .len = text.len, .escaped_len = escaped_len });
        self.expansion = std.math.add(usize, self.expansion, escaped_len) catch return error.SnapshotTooLarge;
        writer.writeAll("\"\"") catch return error.SnapshotTooLarge;
    }
    pub fn encodedPosition(self: *const Plan, skeleton_position: usize) Error!usize {
        // Each placeholder already includes the opening and closing quote.
        return std.math.add(usize, skeleton_position, self.expansion) catch error.SnapshotTooLarge;
    }
    /// Canonical encoding-free identity for exact content/version comparisons.
    pub fn blockSource(self: *const Plan, allocator: std.mem.Allocator, budget: usize, skeleton: []const u8, start: usize, point: Mark) Error![]u8 {
        const strings = self.strings.items[point.strings..];
        const token_bytes = std.math.mul(usize, strings.len, 16) catch return error.SnapshotTooLarge;
        const total = std.math.add(usize, 8 + skeleton.len - start, token_bytes) catch return error.SnapshotTooLarge;
        const bytes = std.math.add(usize, total, self.text.items.len - point.text) catch return error.SnapshotTooLarge;
        if (bytes > budget) return error.SnapshotTooLarge;
        const result = try allocator.alloc(u8, bytes);
        var writer = std.Io.Writer.fixed(result);
        writer.writeInt(u64, skeleton.len - start, .little) catch unreachable;
        writer.writeAll(skeleton[start..]) catch unreachable;
        for (strings) |item| {
            writer.writeInt(u64, item.at - start, .little) catch unreachable;
            writer.writeInt(u64, item.len, .little) catch unreachable;
            writer.writeAll(self.text.items[item.start..][0..item.len]) catch unreachable;
        }
        std.debug.assert(writer.end == result.len);
        return result;
    }
    pub fn seal(self: *Plan, allocator: std.mem.Allocator, budget: usize, skeleton: []const u8) Error!void {
        const total = try self.encodedPosition(skeleton.len);
        if (total == 0 or total > budget or self.text.capacity + self.strings.capacity * @sizeOf(String) + skeleton.len > budget) return error.SnapshotTooLarge;
        self.skeleton = try allocator.dupe(u8, skeleton);
        self.storage_identity = @intFromPtr(skeleton.ptr);
        self.total = total;
    }
    pub fn writeNext(self: *Plan, output: []u8) Error![]const u8 {
        if (self.id == 0) return error.StaleSnapshot;
        if (output.len == 0 or output.len > max_step_bytes or output.len > self.total - self.produced) return error.InvalidOffset;
        var writer = std.Io.Writer.fixed(output);
        while (writer.end < output.len) {
            if (self.tail_at < self.tail_len) {
                const count = @min(output.len - writer.end, self.tail_len - self.tail_at);
                writer.writeAll(self.tail[self.tail_at..][0..count]) catch unreachable;
                self.tail_at += count;
                continue;
            }
            const item = if (self.string_at < self.strings.items.len) self.strings.items[self.string_at] else null;
            if (item != null and self.skeleton_at == item.?.at) {
                const string = item.?;
                if (!self.opened) {
                    writer.writeByte('"') catch unreachable;
                    self.opened = true;
                    continue;
                }
                if (self.text_at == string.len) {
                    writer.writeByte('"') catch unreachable;
                    self.skeleton_at += 2;
                    self.string_at += 1;
                    self.text_at = 0;
                    self.opened = false;
                    continue;
                }
                const text = self.text.items[string.start..][0..string.len];
                var end = @min(string.len, self.text_at + (output.len - writer.end) / 6);
                while (end > self.text_at and end < string.len and (text[end] & 0xc0) == 0x80) end -= 1;
                if (end > self.text_at) {
                    std.json.Stringify.encodeJsonStringChars(text[self.text_at..end], .{}, &writer) catch return error.InvalidViewEncoding;
                    self.text_at = end;
                } else {
                    const codepoint_len = std.unicode.utf8ByteSequenceLength(text[self.text_at]) catch return error.InvalidViewEncoding;
                    var tail_writer = std.Io.Writer.fixed(&self.tail);
                    std.json.Stringify.encodeJsonStringChars(text[self.text_at..][0..codepoint_len], .{}, &tail_writer) catch return error.InvalidViewEncoding;
                    self.tail_at = 0;
                    self.tail_len = tail_writer.end;
                    self.text_at += codepoint_len;
                }
            } else {
                const end = if (item) |next| next.at else self.skeleton.len;
                if (end <= self.skeleton_at) return error.InvalidViewEncoding;
                const count = @min(output.len - writer.end, end - self.skeleton_at);
                writer.writeAll(self.skeleton[self.skeleton_at..][0..count]) catch unreachable;
                self.skeleton_at += count;
            }
        }
        self.produced += writer.end;
        return writer.buffered();
    }
    pub fn releasePayload(self: *Plan, allocator: std.mem.Allocator) void {
        std.crypto.secureZero(u8, self.skeleton);
        allocator.free(self.skeleton);
        std.crypto.secureZero(u8, self.text.items);
        self.text.deinit(allocator);
        self.strings.deinit(allocator);
        self.skeleton = &.{};
        self.text = .empty;
        self.strings = .empty;
    }
    pub fn clear(self: *Plan, allocator: std.mem.Allocator) void {
        self.releasePayload(allocator);
        self.* = .{};
    }
};

test "Product view incremental encoding matches the standard encoder at every tiny chunk boundary" {
    const text = "quote \" slash \\ newline\n tab\t \x01 caf\xc3\xa9 \xf0\x9f\x8f\x94";
    const expected = try std.json.Stringify.valueAlloc(std.testing.allocator, .{ .text = text, .next = "" }, .{});
    defer std.testing.allocator.free(expected);
    for (1..18) |chunk_size| {
        var plan: Plan = .{ .id = 1, .security_epoch = 1 };
        defer plan.clear(std.testing.allocator);
        var storage: [1024]u8 = undefined;
        var writer = std.Io.Writer.fixed(&storage);
        try writer.writeAll("{\"text\":");
        try plan.appendText(std.testing.allocator, storage.len, text);
        try plan.commitString(std.testing.allocator, &writer, 0);
        try writer.writeAll(",\"next\":");
        try plan.commitString(std.testing.allocator, &writer, plan.text.items.len);
        try writer.writeByte('}');
        try plan.seal(std.testing.allocator, storage.len, writer.buffered());
        try std.testing.expectEqual(expected.len, plan.total);
        @memset(&storage, 0); // The plan owns its skeleton; caller scratch may disappear.
        var offset: usize = 0;
        while (offset < plan.total) {
            const size = @min(chunk_size, plan.total - offset);
            _ = try plan.writeNext(storage[offset..][0..size]);
            offset += size;
        }
        try std.testing.expectEqualStrings(expected, storage[0..plan.total]);
    }
}

test "Product view plan rejects malformed UTF-8 and clears a revoked read" {
    var plan: Plan = .{ .id = 1 };
    defer plan.clear(std.testing.allocator);
    var storage: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try plan.appendText(std.testing.allocator, storage.len, &.{0xc3});
    try std.testing.expectError(error.InvalidViewEncoding, plan.commitString(std.testing.allocator, &writer, 0));
    plan.clear(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), plan.text.items.len);
    try std.testing.expectError(error.StaleSnapshot, plan.writeNext(storage[0..1]));
}

test "Product view frozen plan allocation failures release every owned buffer" {
    const Scenario = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var plan: Plan = .{ .id = 1 };
            defer plan.clear(allocator);
            var output: [4096]u8 = undefined;
            var writer = std.Io.Writer.fixed(&output);
            const point = plan.mark();
            try plan.appendText(allocator, output.len, "sanitized string");
            try plan.commitString(allocator, &writer, 0);
            const source = try plan.blockSource(allocator, output.len, writer.buffered(), 0, point);
            defer allocator.free(source);
            try plan.seal(allocator, output.len, writer.buffered());
            _ = try plan.writeNext(output[0..plan.total]);
            try std.testing.expectEqual(plan.total, plan.produced);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Scenario.run, .{});
}
