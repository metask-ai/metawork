//! Search-only Unicode default case folding. No normalization or owned corpus.
const std = @import("std");
const mappings = @import("search_casefold_data.zig").mappings;
pub const max_expansion_bytes = 12;
pub const Result = enum { match, miss, exhausted };

const Folded = struct { bytes: [max_expansion_bytes]u8 = undefined, len: usize = 0 };

fn fold(point: u21) Folded {
    var points: [3]u21 = .{ point, 0, 0 };
    if (point < 128) {
        points[0] = std.ascii.toLower(@intCast(point));
    } else {
        var low: usize = 0;
        var high: usize = mappings.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (mappings[middle][1] < point) low = middle + 1 else high = middle;
        }
        if (low < mappings.len) {
            const row = mappings[low];
            if (row[0] <= point and (point - row[0]) % row[2] == 0)
                points = .{ row[3] + point - row[0], row[4], row[5] };
        }
    }
    var result: Folded = .{};
    for (points, 0..) |value, index| {
        if (index != 0 and value == 0) break;
        result.len += std.unicode.utf8Encode(value, result.bytes[result.len..][0..4]) catch unreachable;
    }
    return result;
}

const Iterator = struct {
    source: []const u8,
    offset: usize = 0,
    pending: Folded = .{},
    at: usize = 0,

    fn next(self: *Iterator) ?u8 {
        if (self.at == self.pending.len) {
            if (self.offset == self.source.len) return null;
            const width = std.unicode.utf8ByteSequenceLength(self.source[self.offset]) catch return null;
            if (width > self.source.len - self.offset) return null;
            const point = std.unicode.utf8Decode(self.source[self.offset..][0..width]) catch return null;
            self.offset += width;
            self.pending = fold(point);
            self.at = 0;
        }
        const byte = self.pending.bytes[self.at];
        self.at += 1;
        return byte;
    }
};

pub fn writeFolded(source: []const u8, storage: []u8) error{NoSpaceLeft}![]const u8 {
    var iterator = Iterator{ .source = source };
    var len: usize = 0;
    while (iterator.next()) |byte| {
        if (len == storage.len) return error.NoSpaceLeft;
        storage[len] = byte;
        len += 1;
    }
    return storage[0..len];
}

/// The caller supplies a complete UTF-8 start and enough raw lookahead for the
/// folded query. Exhaustion leaves that raw candidate available for continuation.
pub fn prefixMatches(source: []const u8, query: []const u8, remaining: *usize) Result {
    if (source.len == 0) return .miss;
    const width = std.unicode.utf8ByteSequenceLength(source[0]) catch return .miss;
    if (width > source.len) return .miss;
    const point = std.unicode.utf8Decode(source[0..width]) catch return .miss;
    const first = fold(point);
    // Expansion may contain a match starting after its first codepoint, e.g.
    // default folding of "ße" contains "se". Map that hit to the same raw start.
    for (first.bytes[0..first.len], 0..) |byte, start| {
        if (byte & 0xc0 == 0x80) continue;
        var iterator = Iterator{ .source = source, .offset = width, .pending = first, .at = start };
        var equal = true;
        for (query) |expected| {
            if (remaining.* == 0) return .exhausted;
            const actual = iterator.next() orelse {
                equal = false;
                break;
            };
            remaining.* -= 1;
            if (actual != expected) {
                equal = false;
                break;
            }
        }
        if (equal) return .match;
    }
    return .miss;
}

test "search folds accented Cyrillic Greek supplementary and expanding characters" {
    var storage: [128]u8 = undefined;
    for ([_]struct { source: []const u8, folded: []const u8 }{
        .{ .source = "CAFÉ", .folded = "café" },
        .{ .source = "ПРИВЕТ", .folded = "привет" },
        .{ .source = "ΟΣ", .folded = "οσ" },
        .{ .source = "ος", .folded = "οσ" },
        .{ .source = "𐐀", .folded = "𐐨" },
        .{ .source = "İ", .folded = "i\u{307}" },
        .{ .source = "Straße", .folded = "strasse" },
        .{ .source = "中文 😀", .folded = "中文 😀" },
    }) |case| try std.testing.expectEqualStrings(case.folded, try writeFolded(case.source, &storage));
}

test "search folding handles expansion substring starts and resumable work exhaustion" {
    var remaining: usize = 3;
    try std.testing.expectEqual(Result.exhausted, prefixMatches("aaaaab", "aaaaab", &remaining));
    try std.testing.expectEqual(@as(usize, 0), remaining);
    remaining = 64;
    try std.testing.expectEqual(Result.match, prefixMatches("aaaaab", "aaaaab", &remaining));
    try std.testing.expectEqual(Result.match, prefixMatches("ße", "se", &remaining));
    try std.testing.expectEqual(Result.miss, prefixMatches("CAFÉ", "cafe", &remaining));
}
