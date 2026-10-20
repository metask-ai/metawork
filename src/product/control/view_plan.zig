//! Product-owned immutable sanitized read plan and bounded JSON encoding.
//! String escaping uses Zig's encoder; no credential, execution handle or Product pointer is retained.
const std = @import("std");
// CPU work quantum; independent of the Bridge single-result transport ceiling.
pub const max_step_bytes = 32 * 1024;
pub const Error = std.mem.Allocator.Error || error{ SnapshotTooLarge, InvalidViewEncoding, StaleSnapshot, InvalidOffset };
const String = struct { at: usize, start: usize, len: usize, escaped_len: usize, child: ?*Plan = null };
pub const Plan = struct {
    skeleton: []u8 = &.{},
    text: std.ArrayList(u8) = .empty,
    strings: std.ArrayList(String) = .empty,
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
        writer.writeAll("\"\"") catch return error.SnapshotTooLarge;
    }
    /// A child is an owned Product fragment, prepared separately before the
    /// final descriptor exists. It never borrows a mutable Product object.
    pub fn appendChild(self: *Plan, allocator: std.mem.Allocator, writer: *std.Io.Writer) Error!*Plan {
        const child = try allocator.create(Plan);
        errdefer allocator.destroy(child);
        child.* = .{ .id = self.id, .security_epoch = self.security_epoch };
        writer.writeAll("[]") catch return error.SnapshotTooLarge;
        try self.strings.append(allocator, .{ .at = writer.end - 2, .start = 0, .len = 0, .escaped_len = 0, .child = child });
        return child;
    }
    pub fn encodedPosition(self: *const Plan, skeleton_position: usize) Error!usize {
        var result = skeleton_position;
        for (self.strings.items) |item| {
            if (item.at >= skeleton_position) break;
            const extra = if (item.child) |child| child.total -| 2 else item.escaped_len;
            result = std.math.add(usize, result, extra) catch return error.SnapshotTooLarge;
        }
        return result;
    }
    fn sourceSize(self: *const Plan, start: usize, end: usize) Error!usize {
        var size = 8 + end - start;
        for (self.strings.items) |item| {
            if (item.at < start or item.at >= end) continue;
            const payload = if (item.child) |child| try child.sourceSize(0, child.skeleton.len) else item.len;
            size = std.math.add(usize, size, 17 + payload) catch return error.SnapshotTooLarge;
        }
        return size;
    }
    fn writeSource(self: *const Plan, writer: *std.Io.Writer, start: usize, end: usize) std.Io.Writer.Error!void {
        try writer.writeInt(u64, end - start, .little);
        try writer.writeAll(self.skeleton[start..end]);
        for (self.strings.items) |item| {
            if (item.at < start or item.at >= end) continue;
            try writer.writeInt(u64, item.at - start, .little);
            try writer.writeByte(@intFromBool(item.child != null));
            const payload = if (item.child) |child| child.sourceSize(0, child.skeleton.len) catch unreachable else item.len;
            try writer.writeInt(u64, payload, .little);
            if (item.child) |child| try child.writeSource(writer, 0, child.skeleton.len) else try writer.writeAll(self.text.items[item.start..][0..item.len]);
        }
    }
    /// Exact unescaped identity, including independently prepared fragments.
    pub fn sourceRange(self: *const Plan, allocator: std.mem.Allocator, budget: usize, start: usize, end: usize) Error![]u8 {
        const size = try self.sourceSize(start, end);
        if (size > budget) return error.SnapshotTooLarge;
        const result = try allocator.alloc(u8, size);
        errdefer allocator.free(result);
        var writer = std.Io.Writer.fixed(result);
        self.writeSource(&writer, start, end) catch return error.SnapshotTooLarge;
        std.debug.assert(writer.end == result.len);
        return result;
    }
    /// Capture skeleton ownership now; lengths can be finalized after children
    /// have been prepared. The numeric output identity is never dereferenced.
    pub fn capture(self: *Plan, allocator: std.mem.Allocator, skeleton: []const u8) Error!void {
        self.skeleton = try allocator.dupe(u8, skeleton);
        self.storage_identity = @intFromPtr(skeleton.ptr);
    }
    pub fn appendSkeleton(self: *Plan, allocator: std.mem.Allocator, budget: usize, suffix: []const u8) Error!void {
        if (suffix.len > budget -| self.skeleton.len) return error.SnapshotTooLarge;
        const old = self.skeleton.len;
        self.skeleton = try allocator.realloc(self.skeleton, old + suffix.len);
        @memcpy(self.skeleton[old..], suffix);
    }
    /// Replace a complete block with confirmed null or safe encoded cache bytes.
    /// Later block offsets move by the returned signed delta.
    pub fn replaceSpan(self: *Plan, allocator: std.mem.Allocator, budget: usize, start: usize, end: usize, replacement: []const u8) Error!isize {
        const length = self.skeleton.len - (end - start) + replacement.len;
        if (length > budget) return error.SnapshotTooLarge;
        const next = try allocator.alloc(u8, length);
        @memcpy(next[0..start], self.skeleton[0..start]);
        @memcpy(next[start..][0..replacement.len], replacement);
        @memcpy(next[start + replacement.len ..], self.skeleton[end..]);
        const delta = @as(isize, @intCast(replacement.len)) - @as(isize, @intCast(end - start));
        var kept: usize = 0;
        for (self.strings.items) |original| {
            var item = original;
            if (item.at >= start and item.at < end) {
                if (item.child) |child| {
                    child.clear(allocator);
                    allocator.destroy(child);
                } else std.crypto.secureZero(u8, self.text.items[item.start..][0..item.len]);
                continue;
            }
            if (item.at >= end) item.at = @intCast(@as(isize, @intCast(item.at)) + delta);
            self.strings.items[kept] = item;
            kept += 1;
        }
        self.strings.items.len = kept;
        std.crypto.secureZero(u8, self.skeleton);
        allocator.free(self.skeleton);
        self.skeleton = next;
        return delta;
    }
    pub fn finalize(self: *Plan, budget: usize) Error!void {
        const total = try self.encodedPosition(self.skeleton.len);
        if (total == 0 or total > budget or self.ownedBytes() > budget) return error.SnapshotTooLarge;
        self.total = total;
    }
    pub fn ownedBytes(self: *const Plan) usize {
        var bytes = self.skeleton.len + self.text.capacity + self.strings.capacity * @sizeOf(String);
        for (self.strings.items) |item| if (item.child) |child| {
            bytes += @sizeOf(Plan) + child.ownedBytes();
        };
        return bytes;
    }
    pub fn seal(self: *Plan, allocator: std.mem.Allocator, budget: usize, skeleton: []const u8) Error!void {
        try self.capture(allocator, skeleton);
        try self.finalize(budget);
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
                if (string.child) |child| {
                    const size = @min(output.len - writer.end, child.total - child.produced);
                    if (size != 0) {
                        _ = try child.writeNext(output[writer.end..][0..size]);
                        writer.end += size;
                    }
                    if (child.produced == child.total) {
                        self.skeleton_at += 2;
                        self.string_at += 1;
                    }
                    continue;
                }
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
        for (self.strings.items) |item| if (item.child) |child| {
            child.clear(allocator);
            allocator.destroy(child);
        };
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
            try plan.appendText(allocator, output.len, "sanitized string");
            try plan.commitString(allocator, &writer, 0);
            try plan.capture(allocator, writer.buffered());
            const source = try plan.sourceRange(allocator, output.len, 0, plan.skeleton.len);
            defer allocator.free(source);
            try plan.finalize(output.len);
            _ = try plan.writeNext(output[0..plan.total]);
            try std.testing.expectEqual(plan.total, plan.produced);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Scenario.run, .{});
}

test "Product view prepared children preserve identity and exact output across every chunk boundary" {
    const expected = "{\"tool\":{\"content\":\"line\\n\\\"quoted\\\"\"},\"other\":true}";
    for (1..18) |quantum| {
        var root: Plan = .{ .id = 1 };
        defer root.clear(std.testing.allocator);
        var scratch: [512]u8 = undefined;
        var writer = std.Io.Writer.fixed(&scratch);
        try writer.writeAll("{\"tool\":");
        const child = try root.appendChild(std.testing.allocator, &writer);
        try writer.writeAll(",\"other\":true}");
        try root.capture(std.testing.allocator, writer.buffered());
        var child_storage: [256]u8 = undefined;
        var child_writer = std.Io.Writer.fixed(&child_storage);
        try child_writer.writeAll("{\"content\":");
        try child.appendText(std.testing.allocator, 1024, "line\n\"quoted\"");
        try child.commitString(std.testing.allocator, &child_writer, 0);
        try child_writer.writeByte('}');
        try child.seal(std.testing.allocator, 4096, child_writer.buffered());
        try root.finalize(4096);
        const identity = try root.sourceRange(std.testing.allocator, 4096, 0, root.skeleton.len);
        defer std.testing.allocator.free(identity);
        var offset: usize = 0;
        while (offset < root.total) {
            const size = @min(quantum, root.total - offset);
            _ = try root.writeNext(scratch[offset..][0..size]);
            offset += size;
        }
        try std.testing.expectEqualStrings(expected, scratch[0..root.total]);
        const after = try root.sourceRange(std.testing.allocator, 4096, 0, root.skeleton.len);
        defer std.testing.allocator.free(after);
        try std.testing.expectEqualSlices(u8, identity, after);
    }
}

test "Product view child allocation failure and block replacement release owned fragments" {
    const Scenario = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var root: Plan = .{ .id = 1 };
            defer root.clear(allocator);
            var bytes: [128]u8 = undefined;
            var writer = std.Io.Writer.fixed(&bytes);
            try writer.writeByte('[');
            const child = try root.appendChild(allocator, &writer);
            try child.seal(allocator, 4096, "{\"value\":1}");
            try writer.writeByte(']');
            try root.capture(allocator, writer.buffered());
            _ = try root.replaceSpan(allocator, 4096, 1, 3, "null");
            try root.finalize(4096);
            _ = try root.writeNext(bytes[0..root.total]);
            try std.testing.expectEqualStrings("[null]", bytes[0..root.total]);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Scenario.run, .{});
}
