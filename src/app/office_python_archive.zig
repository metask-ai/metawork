//! First-stage, fixed Windows embeddable-Python ZIP only. Authenticate one
//! bounded owned snapshot, then use std ZIP layouts and the std raw inflater.
//! No interpreter, subprocess, links or general archive installation authority.
const std = @import("std");
const paths = @import("office_component_archive.zig");

pub const Expected = struct { bytes: u64, sha256: [32]u8 };
pub const Limits = struct {
    archive_bytes: u64 = 32 * 1024 * 1024,
    unpacked_bytes: u64 = 64 * 1024 * 1024,
    member_bytes: u64 = 16 * 1024 * 1024,
    members: usize = 128,
    metadata_bytes: usize = 64 * 1024,
};
pub const Summary = struct { files: usize, unpacked_bytes: u64 };
pub const Observer = struct {
    context: ?*anyopaque = null,
    observe_fn: ?*const fn (?*anyopaque, Summary) bool = null,

    fn check(self: Observer, progress: Summary) !void {
        if (self.observe_fn) |observe| if (!observe(self.context, progress)) return error.Cancelled;
    }
};
const Member = struct {
    name: []const u8,
    data: []const u8,
    method: std.zip.CompressionMethod,
    bytes: u32,
    crc: u32,
};

fn entries(allocator: std.mem.Allocator, bytes: []const u8, limits: Limits) ![]const Member {
    if (bytes.len < @sizeOf(std.zip.EndRecord)) return error.PythonZipFormat;
    var end_reader: std.Io.Reader = .fixed(bytes[bytes.len - @sizeOf(std.zip.EndRecord) ..]);
    const end = try end_reader.takeStruct(std.zip.EndRecord, .little);
    if (!std.mem.eql(u8, &end.signature, &std.zip.end_record_sig) or end.need_zip64() or
        end.disk_number != 0 or end.central_directory_disk_number != 0 or end.comment_len != 0 or
        end.record_count_disk != end.record_count_total or end.record_count_total == 0 or
        end.record_count_total > limits.members or end.central_directory_size > limits.metadata_bytes or
        @as(u64, end.central_directory_offset) + end.central_directory_size != bytes.len - @sizeOf(std.zip.EndRecord)) return error.PythonZipFormat;
    const members = try allocator.alloc(Member, end.record_count_total);
    var directory: std.Io.Reader = .fixed(bytes[end.central_directory_offset .. bytes.len - @sizeOf(std.zip.EndRecord)]);
    var names: std.StringHashMapUnmanaged(void) = .empty;
    var local_end: usize = 0;
    var total: u64 = 0;
    for (members) |*member| {
        const header = try directory.takeStruct(std.zip.CentralDirectoryFileHeader, .little);
        const flags: u16 = @bitCast(header.flags);
        const kind = (header.external_file_attributes >> 16) & 0xf000;
        if (!std.mem.eql(u8, &header.signature, &std.zip.central_file_header_sig) or
            (flags != 0 and flags != 0x800) or header.version_needed_to_extract > 20 or
            header.disk_number != 0 or header.extra_len != 0 or header.comment_len != 0 or
            (kind != 0 and kind != 0x8000) or header.external_file_attributes & 0x10 != 0 or
            header.filename_len == 0 or header.filename_len > 128 or
            header.uncompressed_size > limits.member_bytes or header.compressed_size > limits.archive_bytes or
            (header.compression_method != .store and header.compression_method != .deflate)) return error.PythonZipFormat;
        total += header.uncompressed_size;
        if (total > limits.unpacked_bytes) return error.PythonZipBudget;
        const name = try directory.take(header.filename_len);
        try paths.checkPath(name);
        for (name) |byte| if (byte >= 128 or byte == '/') return error.PythonZipPath;
        const lower = try std.ascii.allocLowerString(allocator, name);
        if ((try names.getOrPut(allocator, lower)).found_existing) return error.PythonZipCollision;
        if (header.local_file_header_offset != local_end or local_end > end.central_directory_offset) return error.PythonZipFormat;
        var local: std.Io.Reader = .fixed(bytes[local_end..end.central_directory_offset]);
        const entry = try local.takeStruct(std.zip.LocalFileHeader, .little);
        if (!std.mem.eql(u8, &entry.signature, &std.zip.local_file_header_sig) or
            entry.version_needed_to_extract != header.version_needed_to_extract or @as(u16, @bitCast(entry.flags)) != flags or
            entry.compression_method != header.compression_method or entry.crc32 != header.crc32 or
            entry.compressed_size != header.compressed_size or entry.uncompressed_size != header.uncompressed_size or
            entry.last_modification_time != header.last_modification_time or entry.last_modification_date != header.last_modification_date or
            entry.filename_len != header.filename_len or entry.extra_len != 0 or
            !std.mem.eql(u8, try local.take(entry.filename_len), name)) return error.PythonZipFormat;
        const data = try local.take(header.compressed_size);
        local_end += local.seek;
        member.* = .{ .name = name, .data = data, .method = header.compression_method, .bytes = header.uncompressed_size, .crc = header.crc32 };
    }
    if (directory.seek != directory.end or local_end != end.central_directory_offset or !names.contains("python.exe")) return error.PythonZipFormat;
    return members;
}

/// Owns only one new flat child. Every written byte comes from the same
/// authenticated memory, so source replacement cannot change extraction bytes.
pub fn unpack(allocator: std.mem.Allocator, io: std.Io, input: *std.Io.Reader, parent: std.Io.Dir, name: []const u8, expected: Expected, limits: Limits, observer: Observer) !Summary {
    try paths.checkPath(name);
    if (std.mem.indexOfScalar(u8, name, '/') != null or expected.bytes == 0 or expected.bytes > limits.archive_bytes or
        std.mem.allEqual(u8, &expected.sha256, 0)) return error.PythonZipBudget;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const snapshot = try arena.allocator().alloc(u8, @intCast(expected.bytes));
    var hash: std.crypto.hash.sha2.Sha256 = .init(.{});
    var offset: usize = 0;
    while (offset < snapshot.len) {
        try observer.check(.{ .files = 0, .unpacked_bytes = 0 });
        const count = try input.readSliceShort(snapshot[offset..@min(snapshot.len, offset + 64 * 1024)]);
        if (count == 0) return error.PythonZipSize;
        hash.update(snapshot[offset..][0..count]);
        offset += count;
    }
    var tail: [1]u8 = undefined;
    if (try input.readSliceShort(&tail) != 0) return error.PythonZipSize;
    if (!std.mem.eql(u8, &hash.finalResult(), &expected.sha256)) return error.PythonZipDigest;
    const members = try entries(arena.allocator(), snapshot, limits);
    try observer.check(.{ .files = 0, .unpacked_bytes = 0 });
    try parent.createDir(io, name, .default_dir);
    var identity: ?std.Io.File.Stat = null;
    const result = blk: {
        const output = parent.openDir(io, name, .{ .iterate = true, .follow_symlinks = false }) catch |failure| break :blk @as(anyerror!Summary, failure);
        defer output.close(io);
        identity = output.stat(io) catch |failure| break :blk @as(anyerror!Summary, failure);
        const summary = extract(allocator, io, output, members, limits, observer) catch |failure| break :blk @as(anyerror!Summary, failure);
        const named = parent.statFile(io, name, .{ .follow_symlinks = false }) catch |failure| break :blk @as(anyerror!Summary, failure);
        if (named.kind != .directory or named.inode != identity.?.inode) break :blk @as(anyerror!Summary, error.StageChanged);
        break :blk summary;
    };
    return result catch |failure| {
        const created = identity orelse return error.CleanupIncomplete;
        const named = parent.statFile(io, name, .{ .follow_symlinks = false }) catch return error.CleanupIncomplete;
        if (named.kind != .directory or named.inode != created.inode) return error.CleanupIncomplete;
        parent.deleteTree(io, name) catch return error.CleanupIncomplete;
        return failure;
    };
}

fn extract(allocator: std.mem.Allocator, io: std.Io, output: std.Io.Dir, members: []const Member, limits: Limits, observer: Observer) !Summary {
    var result: Summary = .{ .files = 0, .unpacked_bytes = 0 };
    for (members) |member| {
        try observer.check(result);
        var encoded: std.Io.Reader = .fixed(member.data);
        var window: [std.compress.flate.max_window_len]u8 = undefined;
        var inflate: std.compress.flate.Decompress = .init(&encoded, .raw, &window);
        const decoded = if (member.method == .deflate) &inflate.reader else &encoded;
        const content = try allocator.alloc(u8, member.bytes);
        defer allocator.free(content);
        var offset: usize = 0;
        var crc: std.hash.Crc32 = .init();
        while (offset < content.len) {
            try observer.check(result);
            const count = decoded.readSliceShort(content[offset..@min(content.len, offset + 64 * 1024)]) catch return error.PythonZipPayload;
            if (count == 0) return error.PythonZipPayload;
            crc.update(content[offset..][0..count]);
            offset += count;
            result.unpacked_bytes += count;
            if (result.unpacked_bytes > limits.unpacked_bytes) return error.PythonZipBudget;
        }
        var tail: [1]u8 = undefined;
        if ((decoded.readSliceShort(&tail) catch return error.PythonZipPayload) != 0 or encoded.seek != member.data.len or crc.final() != member.crc) return error.PythonZipPayload;
        const file = try output.createFile(io, member.name, .{ .exclusive = true, .resolve_beneath = true });
        defer file.close(io);
        try file.writeStreamingAll(io, content);
        result.files += 1;
    }
    try observer.check(result);
    return result;
}

fn fixtureExpected(comptime name: []const u8) !Expected {
    const fixture = @embedFile("office_python_archive_fixtures/" ++ name ++ ".zip");
    const index = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, @embedFile("office_python_archive_fixtures/index.json"), .{});
    defer index.deinit();
    const entry = index.value.object.get(name).?.object;
    var result: Expected = .{ .bytes = @intCast(entry.get("bytes").?.integer), .sha256 = undefined };
    _ = try std.fmt.hexToBytes(&result.sha256, entry.get("sha256").?.string);
    try std.testing.expectEqual(result.bytes, fixture.len);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(fixture, &hash, .{});
    try std.testing.expectEqual(result.sha256, hash);
    return result;
}

test "flat Python ZIP extracts exact regular bytes with CRC and complete counts" {
    var temporary = std.testing.tmpDir(.{ .iterate = true });
    defer temporary.cleanup();
    var reader: std.Io.Reader = .fixed(@embedFile("office_python_archive_fixtures/valid.zip"));
    const summary = try unpack(std.testing.allocator, std.testing.io, &reader, temporary.dir, "bootstrap", try fixtureExpected("valid"), .{}, .{});
    try std.testing.expectEqual(@as(usize, 2), summary.files);
    try std.testing.expectEqual(@as(u64, 16 + 7 * 4096), summary.unpacked_bytes);
    const content = try temporary.dir.readFileAlloc(std.testing.io, "bootstrap/python.exe", std.testing.allocator, .limited(32));
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("embedded-runtime", content);
}

test "Python ZIP rejects paths aliases links flags framing CRC and hidden payload" {
    inline for (.{
        .{ "traversal", error.ComponentPath },          .{ "backslash", error.ComponentPath },        .{ "reserved", error.ComponentPath },
        .{ "nested", error.PythonZipPath },             .{ "case-alias", error.PythonZipCollision },  .{ "symlink", error.PythonZipFormat },
        .{ "directory", error.PythonZipFormat },        .{ "crc", error.PythonZipPayload },           .{ "local-name", error.PythonZipFormat },
        .{ "encrypted", error.PythonZipFormat },        .{ "descriptor", error.PythonZipFormat },     .{ "bad-deflate", error.PythonZipPayload },
        .{ "actual-size", error.PythonZipPayload },     .{ "zip64", error.PythonZipFormat },          .{ "member-trailing", error.PythonZipPayload },
        .{ "archive-trailing", error.PythonZipFormat }, .{ "archive-prefix", error.PythonZipFormat },
    }) |fixture| {
        var temporary = std.testing.tmpDir(.{ .iterate = true });
        defer temporary.cleanup();
        var reader: std.Io.Reader = .fixed(@embedFile("office_python_archive_fixtures/" ++ fixture[0] ++ ".zip"));
        try std.testing.expectError(fixture[1], unpack(std.testing.allocator, std.testing.io, &reader, temporary.dir, "bootstrap", try fixtureExpected(fixture[0]), .{}, .{}));
        try std.testing.expectError(error.FileNotFound, temporary.dir.statFile(std.testing.io, "bootstrap", .{}));
    }
}

test "Python ZIP input size and identity fail before output creation" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const fixture = @embedFile("office_python_archive_fixtures/valid.zip");
    var expected = try fixtureExpected("valid");
    expected.sha256 = @splat(1);
    var reader: std.Io.Reader = .fixed(fixture);
    try std.testing.expectError(error.PythonZipDigest, unpack(std.testing.allocator, std.testing.io, &reader, temporary.dir, "bootstrap", expected, .{}, .{}));
    expected = try fixtureExpected("valid");
    reader = .fixed(fixture[0 .. fixture.len - 1]);
    try std.testing.expectError(error.PythonZipSize, unpack(std.testing.allocator, std.testing.io, &reader, temporary.dir, "bootstrap", expected, .{}, .{}));
    reader = .fixed(fixture ++ "extra");
    try std.testing.expectError(error.PythonZipSize, unpack(std.testing.allocator, std.testing.io, &reader, temporary.dir, "bootstrap", expected, .{}, .{}));
    try std.testing.expectError(error.FileNotFound, temporary.dir.statFile(std.testing.io, "bootstrap", .{}));
}

test "Python ZIP source mutation after authentication cannot alter decoded bytes" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const bytes = try std.testing.allocator.dupe(u8, @embedFile("office_python_archive_fixtures/valid.zip"));
    defer std.testing.allocator.free(bytes);
    const Change = struct {
        bytes: []u8,
        calls: usize = 0,
        fn observe(context: ?*anyopaque, _: Summary) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            if (self.calls == 2) @memset(self.bytes, 0);
            return true;
        }
    };
    var state: Change = .{ .bytes = bytes };
    var reader: std.Io.Reader = .fixed(bytes);
    _ = try unpack(std.testing.allocator, std.testing.io, &reader, temporary.dir, "bootstrap", try fixtureExpected("valid"), .{}, .{ .context = &state, .observe_fn = Change.observe });
    try std.testing.expect(state.calls >= 2);
    try std.testing.expect(std.mem.allEqual(u8, bytes, 0));
    const content = try temporary.dir.readFileAlloc(std.testing.io, "bootstrap/python.exe", std.testing.allocator, .limited(32));
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("embedded-runtime", content);
}

test "Python ZIP cancellation after a member removes only the new child" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const keep = try temporary.dir.createFile(std.testing.io, "keep", .{ .exclusive = true });
    keep.close(std.testing.io);
    const Stop = struct {
        fn observe(_: ?*anyopaque, progress: Summary) bool {
            return progress.files == 0;
        }
    };
    var reader: std.Io.Reader = .fixed(@embedFile("office_python_archive_fixtures/valid.zip"));
    try std.testing.expectError(error.Cancelled, unpack(std.testing.allocator, std.testing.io, &reader, temporary.dir, "bootstrap", try fixtureExpected("valid"), .{}, .{ .observe_fn = Stop.observe }));
    try std.testing.expectError(error.FileNotFound, temporary.dir.statFile(std.testing.io, "bootstrap", .{}));
    _ = try temporary.dir.statFile(std.testing.io, "keep", .{});
}

test "Python ZIP budgets are enforced without accepting partial output" {
    inline for (.{ Limits{ .members = 1 }, Limits{ .member_bytes = 1 }, Limits{ .metadata_bytes = 1 }, Limits{ .unpacked_bytes = 1 } }) |limits| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var reader: std.Io.Reader = .fixed(@embedFile("office_python_archive_fixtures/valid.zip"));
        const expected_error = if (limits.unpacked_bytes == 1) error.PythonZipBudget else error.PythonZipFormat;
        try std.testing.expectError(expected_error, unpack(std.testing.allocator, std.testing.io, &reader, temporary.dir, "bootstrap", try fixtureExpected("valid"), limits, .{}));
        try std.testing.expectError(error.FileNotFound, temporary.dir.statFile(std.testing.io, "bootstrap", .{}));
    }
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var reader: std.Io.Reader = .fixed(@embedFile("office_python_archive_fixtures/valid.zip"));
    try std.testing.expectError(error.PythonZipBudget, unpack(std.testing.allocator, std.testing.io, &reader, temporary.dir, "bootstrap", try fixtureExpected("valid"), .{ .archive_bytes = 1 }, .{}));
    try std.testing.expectEqual(@as(usize, 0), reader.seek);
}

test "Python ZIP never overwrites or cleans a pre-existing output directory" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDir(std.testing.io, "bootstrap", .default_dir);
    const keep = try temporary.dir.createFile(std.testing.io, "bootstrap/keep", .{ .exclusive = true });
    keep.close(std.testing.io);
    var reader: std.Io.Reader = .fixed(@embedFile("office_python_archive_fixtures/valid.zip"));
    try std.testing.expectError(error.PathAlreadyExists, unpack(std.testing.allocator, std.testing.io, &reader, temporary.dir, "bootstrap", try fixtureExpected("valid"), .{}, .{}));
    _ = try temporary.dir.statFile(std.testing.io, "bootstrap/keep", .{});
    try std.testing.expectError(error.FileNotFound, temporary.dir.statFile(std.testing.io, "bootstrap/python.exe", .{}));
}
