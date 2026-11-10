//! Byte matching for credential redaction at UTF-8 codepoint boundaries.
//! Callers own replacement, streaming, and output limits.
const std = @import("std");

pub fn codepointLen(value: []const u8, start: usize) usize {
    return @min(
        std.unicode.utf8ByteSequenceLength(value[start]) catch 1,
        value.len - start,
    );
}

pub fn matchEnd(value: []const u8, start: usize, credential: []const u8) ?usize {
    if (credential.len == 0) return null;
    var end: usize = 0;
    for (0..codepointLen(value, start)) |offset| {
        if (std.mem.startsWith(u8, value[start + offset ..], credential))
            end = @max(end, start + offset + credential.len);
    }
    if (end == 0) return null;
    while (end < value.len and value[end] & 0xc0 == 0x80) end += 1;
    return end;
}

pub fn mayContinue(value: []const u8, start: usize, credential: []const u8) bool {
    if (credential.len == 0) return false;
    for (0..codepointLen(value, start)) |offset| {
        const remaining = value[start + offset ..];
        if (remaining.len < credential.len and std.mem.startsWith(u8, credential, remaining))
            return true;
    }
    return false;
}
