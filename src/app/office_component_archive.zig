//! Windows Office bootstrap. Uses Zig's gzip decoder and tar iterator; no
//! component executable is run until these exact streamed bytes are verified.
//! The caller owns the parent directory and serializes component installation.
const std = @import("std");
const builtin = @import("builtin");

pub const Limits = struct {
    compressed_bytes: u64 = 800 * 1024 * 1024,
    unpacked_bytes: u64 = 3 * 1024 * 1024 * 1024,
    member_bytes: u64 = 512 * 1024 * 1024,
    members: usize = 60_000,
    metadata_bytes: usize = 16 * 1024 * 1024,
    manifest_bytes: usize = 8 * 1024 * 1024,
};

pub const Expected = struct {
    sha256: [32]u8,
    archive_bytes: u64,
    unpacked_bytes: u64,
    files: usize,
    target: []const u8,
};

pub const Progress = struct { compressed_bytes: u64, unpacked_bytes: u64, files: usize };
pub const Observer = struct {
    context: ?*anyopaque = null,
    /// Worker-only observation. False requests cancellation, never publication.
    observe_fn: ?*const fn (?*anyopaque, Progress) bool = null,

    fn check(self: Observer, progress: Progress) !void {
        if (self.observe_fn) |observe| if (!observe(self.context, progress)) return error.Cancelled;
    }
};

pub const Summary = struct { files: usize, unpacked_bytes: u64, manifest_sha256: [32]u8 };
const Seen = struct { directory: bool, bytes: u64, sha256: [32]u8 };
const Manifest = struct {
    schema: u32,
    target: []const u8,
    payloadBytes: u64,
    files: []const struct { path: []const u8, bytes: u64, sha256: []const u8 },
};

/// Creates one new child staging directory. Failure removes only that child,
/// after all writer/directory handles close. Cleanup failure is explicit.
pub fn unpack(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: *std.Io.Reader,
    parent: std.Io.Dir,
    stage_name: []const u8,
    expected: Expected,
    limits: Limits,
    observer: Observer,
) !Summary {
    try checkPath(stage_name);
    if (std.mem.indexOfScalar(u8, stage_name, '/') != null) return error.InvalidStageName;
    if (expected.archive_bytes == 0 or expected.archive_bytes > limits.compressed_bytes or
        expected.unpacked_bytes > limits.unpacked_bytes or expected.files == 0 or expected.files > limits.members)
        return error.ComponentBudget;
    try parent.createDir(io, stage_name, directoryPermissions());
    var identity: ?std.Io.File.Stat = null;
    const result = blk: {
        const destination = parent.openDir(io, stage_name, .{ .iterate = true, .follow_symlinks = false }) catch |failure| break :blk @as(anyerror!Summary, failure);
        defer destination.close(io);
        identity = destination.stat(io) catch |failure| break :blk @as(anyerror!Summary, failure);
        const summary = extract(allocator, io, input, destination, expected, limits, observer) catch |failure| break :blk @as(anyerror!Summary, failure);
        const named = parent.statFile(io, stage_name, .{ .follow_symlinks = false }) catch |failure| break :blk @as(anyerror!Summary, failure);
        if (named.kind != .directory or named.inode != identity.?.inode) break :blk @as(anyerror!Summary, error.StageChanged);
        break :blk summary;
    };
    return result catch |failure| {
        const created = identity orelse return error.CleanupIncomplete;
        const current = parent.statFile(io, stage_name, .{ .follow_symlinks = false }) catch return error.CleanupIncomplete;
        if (current.kind != .directory or current.inode != created.inode) return error.CleanupIncomplete;
        parent.deleteTree(io, stage_name) catch return error.CleanupIncomplete;
        return failure;
    };
}

/// Counts and hashes the compressed bytes actually delivered to the decoder,
/// including its lookahead. No reopen/hash-then-extract pathname race exists.
const Source = struct {
    input: *std.Io.Reader,
    expected_bytes: u64,
    count: u64 = 0,
    digest: std.crypto.hash.sha2.Sha256 = .init(.{}),
    reader: std.Io.Reader,

    fn init(input: *std.Io.Reader, buffer: []u8, size: u64) Source {
        return .{ .input = input, .expected_bytes = size, .reader = .{
            .buffer = buffer,
            .seek = 0,
            .end = 0,
            .vtable = &.{ .stream = stream },
        } };
    }

    fn stream(reader: *std.Io.Reader, writer: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *Source = @alignCast(@fieldParentPtr("reader", reader));
        var buffer: [32 * 1024]u8 = undefined;
        const capacity = @min(buffer.len, @intFromEnum(limit));
        if (capacity == 0) return 0;
        const size = try self.input.readSliceShort(buffer[0..capacity]);
        if (size == 0) return error.EndOfStream;
        if (size > self.expected_bytes -| self.count) {
            return error.ReadFailed;
        }
        self.count += size;
        self.digest.update(buffer[0..size]);
        try writer.writeAll(buffer[0..size]);
        return size;
    }
};

fn extract(allocator: std.mem.Allocator, io: std.Io, input: *std.Io.Reader, destination: std.Io.Dir, expected: Expected, limits: Limits, observer: Observer) !Summary {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const temporary = arena.allocator();
    var source_buffer: [64 * 1024]u8 = undefined;
    var source = Source.init(input, &source_buffer, expected.archive_bytes);
    // The producer emits a fixed-size gzip header, with no names, optional
    // fields or extensible metadata. Reject them before the decoder consumes it.
    const gzip_header = try source.reader.peek(10);
    if (!std.mem.eql(u8, gzip_header[0..4], &.{ 0x1f, 0x8b, 8, 0 })) return error.ComponentGzipHeader;
    var inflate_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var decoder: std.compress.flate.Decompress = .init(&source.reader, .gzip, &inflate_buffer);
    var name_buffer: [512]u8 = undefined;
    var link_buffer: [512]u8 = undefined;
    var iterator: std.tar.Iterator = .init(&decoder.reader, .{ .file_name_buffer = &name_buffer, .link_name_buffer = &link_buffer });
    var members: std.StringHashMapUnmanaged(Seen) = .empty;
    var manifest_bytes: std.ArrayList(u8) = .empty;
    var gzip_hash: std.compress.flate.Container.Hasher = .init(.gzip);
    var expanded: u64 = 0;
    var unpacked: u64 = 0;
    var metadata: usize = 0;
    var files: usize = 0;
    while (true) {
        try observer.check(.{ .compressed_bytes = source.count, .unpacked_bytes = unpacked, .files = files });
        // Inspect only the narrow producer dialect before asking the standard
        // iterator to parse it. This prevents invisible PAX/GNU metadata loops.
        const raw = try decoder.reader.peek(iterator.padding + 512);
        if (!std.mem.allEqual(u8, raw[0..iterator.padding], 0)) return error.ComponentPadding;
        const header = raw[iterator.padding..][0..512];
        expanded += raw.len;
        if (expanded > limits.unpacked_bytes) return error.ExpandedBudget;
        gzip_hash.update(raw);
        if (std.mem.allEqual(u8, header, 0)) {
            if (try iterator.next() != null) return error.ComponentTarEnd;
            break;
        }
        if (!std.mem.eql(u8, header[257..265], "ustar\x0000") or (header[156] != '0' and header[156] != '5'))
            return error.ComponentTarDialect;
        // USTAR uses octal size fields. The general iterator also accepts GNU
        // binary sizes; reject those before its block-alignment arithmetic.
        if (header[124] & 0x80 != 0) return error.ComponentTarDialect;
        const file = (try iterator.next()) orelse return error.ComponentTarEnd;
        const name = if (file.kind == .directory and std.mem.endsWith(u8, file.name, "/")) file.name[0 .. file.name.len - 1] else file.name;
        try checkPath(name);
        if (members.count() >= limits.members) return error.MemberBudget;
        metadata += name.len;
        if (metadata > limits.metadata_bytes) return error.MetadataBudget;
        const owned_name = try std.ascii.allocLowerString(temporary, name);
        const inserted = try members.getOrPut(temporary, owned_name);
        if (inserted.found_existing) return error.ComponentPathCollision;
        inserted.value_ptr.* = .{ .directory = file.kind == .directory, .bytes = file.size, .sha256 = @splat(0) };
        if (file.link_name.len != 0 or file.size > limits.member_bytes) return error.ComponentMember;
        switch (file.kind) {
            .directory => {
                if (file.size != 0) return error.ComponentDirectoryData;
                // Producer order includes every parent before its children.
                // Exclusive creation also catches Windows case/device aliases.
                try destination.createDir(io, name, directoryPermissions());
            },
            .sym_link => return error.ComponentLink,
            .file => {
                if (file.size > limits.unpacked_bytes -| unpacked) return error.UnpackedBudget;
                const is_manifest = std.mem.eql(u8, name, "office-runtime.json");
                if (is_manifest and (file.size > limits.manifest_bytes or file.size > limits.metadata_bytes -| metadata))
                    return error.MetadataBudget;
                if (std.mem.endsWith(u8, owned_name, ".pyc") or std.mem.endsWith(u8, owned_name, ".pdb"))
                    return error.ComponentDebugResource;
                const output = try destination.createFile(io, name, .{ .exclusive = true, .permissions = filePermissions() });
                defer output.close(io);
                var hash: std.crypto.hash.sha2.Sha256 = .init(.{});
                var remaining = file.size;
                var buffer: [64 * 1024]u8 = undefined;
                while (remaining != 0) {
                    try observer.check(.{ .compressed_bytes = source.count, .unpacked_bytes = unpacked, .files = files });
                    const count: usize = @intCast(@min(remaining, buffer.len));
                    try decoder.reader.readSliceAll(buffer[0..count]);
                    const bytes = buffer[0..count];
                    expanded += count;
                    if (expanded > limits.unpacked_bytes) return error.ExpandedBudget;
                    gzip_hash.update(bytes);
                    hash.update(bytes);
                    try output.writeStreamingAll(io, bytes);
                    if (is_manifest) try manifest_bytes.appendSlice(temporary, bytes);
                    unpacked += count;
                    remaining -= count;
                }
                iterator.unread_file_bytes = 0;
                hash.final(&inserted.value_ptr.sha256);
                files += 1;
                if (is_manifest) metadata += @intCast(file.size);
            },
        }
    }
    // Consume zero tar padding through the decoder to validate its footer;
    // std's decoder exposes gzip CRC/length, rather than comparing them itself.
    var tail_bytes: usize = 0;
    var tail: [4096]u8 = undefined;
    while (true) {
        const size = try decoder.reader.readSliceShort(&tail);
        if (size == 0) break;
        tail_bytes += size;
        expanded += size;
        if (expanded > limits.unpacked_bytes) return error.ExpandedBudget;
        if (tail_bytes > 10240 or !std.mem.allEqual(u8, tail[0..size], 0)) return error.ComponentTrailingData;
        gzip_hash.update(tail[0..size]);
    }
    const checksum = decoder.container_metadata.gzip;
    if (checksum.crc != gzip_hash.gzip.crc.final() or checksum.count != gzip_hash.gzip.count)
        return error.ComponentGzipChecksum;
    if (source.reader.peek(1)) |_| return error.ComponentTrailingData else |failure| {
        if (failure != error.EndOfStream) return failure;
    }
    var compressed_hash: [32]u8 = undefined;
    source.digest.final(&compressed_hash);
    if (source.count != expected.archive_bytes or !std.mem.eql(u8, &compressed_hash, &expected.sha256)) return error.ComponentDigest;
    if (files != expected.files or unpacked != expected.unpacked_bytes or manifest_bytes.items.len == 0) return error.ComponentContents;
    const parsed = try std.json.parseFromSlice(Manifest, temporary, manifest_bytes.items, .{ .allocate = .alloc_always, .max_value_len = 1024 });
    const manifest = parsed.value;
    if (manifest.schema != 1 or !std.mem.eql(u8, manifest.target, expected.target) or manifest.files.len + 1 != files or
        manifest.payloadBytes != unpacked - manifest_bytes.items.len) return error.ComponentManifest;
    for (manifest.files) |entry| {
        try checkPath(entry.path);
        if (std.mem.eql(u8, entry.path, "office-runtime.json")) return error.ComponentManifest;
        const actual = members.getPtr(try std.ascii.allocLowerString(temporary, entry.path)) orelse return error.ComponentManifest;
        var digest: [32]u8 = undefined;
        if (entry.sha256.len != 64) return error.ComponentManifest;
        _ = std.fmt.hexToBytes(&digest, entry.sha256) catch return error.ComponentManifest;
        if (actual.directory or actual.bytes != entry.bytes or !std.mem.eql(u8, &actual.sha256, &digest)) return error.ComponentManifest;
        // A duplicate manifest path can never consume the same member twice.
        actual.directory = true;
    }
    var manifest_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(manifest_bytes.items, &manifest_digest, .{});
    return .{ .files = files, .unpacked_bytes = unpacked, .manifest_sha256 = manifest_digest };
}

fn checkPath(name: []const u8) !void {
    if (name.len == 0 or name.len > 512 or !std.unicode.utf8ValidateSlice(name)) return error.ComponentPath;
    var parts = std.mem.splitScalar(u8, name, '/');
    var depth: usize = 0;
    while (parts.next()) |part| {
        depth += 1;
        if (depth > 32 or part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..") or
            part[part.len - 1] == ' ' or part[part.len - 1] == '.') return error.ComponentPath;
        for (part) |byte| if (std.ascii.isControl(byte) or std.mem.indexOfScalar(u8, "\\:<>\"|?*", byte) != null) return error.ComponentPath;
        const stem = part[0 .. std.mem.indexOfScalar(u8, part, '.') orelse part.len];
        for ([_][]const u8{ "CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$" }) |reserved|
            if (std.ascii.eqlIgnoreCase(stem, reserved)) return error.ComponentPath;
        if (stem.len == 4 and (std.ascii.eqlIgnoreCase(stem[0..3], "COM") or std.ascii.eqlIgnoreCase(stem[0..3], "LPT")) and
            stem[3] >= '1' and stem[3] <= '9') return error.ComponentPath;
    }
}

fn directoryPermissions() std.Io.Dir.Permissions {
    return if (builtin.os.tag == .windows) .default_dir else .fromMode(0o700);
}

fn filePermissions() std.Io.File.Permissions {
    return if (builtin.os.tag == .windows) .default_file else .fromMode(0o600);
}

test "component paths use strict Windows relative names" {
    for ([_][]const u8{ "../escape", "/absolute", "C:/absolute", "a\\b", "a//b", "NUL.txt", "COM1", "a.", "a ", "a/../b" }) |path|
        try std.testing.expectError(error.ComponentPath, checkPath(path));
    try checkPath("skills/docx/scripts/office/validate.py");
}

fn fixtureExpected(comptime name: []const u8) !Expected {
    const Metadata = struct { sha256: []const u8, archive_bytes: u64, unpacked_bytes: u64, files: usize, target: []const u8 };
    const parsed = try std.json.parseFromSlice(Metadata, std.testing.allocator, @embedFile("office_component_archive_fixtures/" ++ name ++ ".json"), .{});
    defer parsed.deinit();
    var sha256: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&sha256, parsed.value.sha256);
    return .{ .sha256 = sha256, .archive_bytes = parsed.value.archive_bytes, .unpacked_bytes = parsed.value.unpacked_bytes, .files = parsed.value.files, .target = "x86_64-windows-msvc" };
}

test "component bootstrap streams verified bytes and leaves the caller's directory intact" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{ .iterate = true });
    defer temporary.cleanup();
    var reader: std.Io.Reader = .fixed(@embedFile("office_component_archive_fixtures/valid.tar.gz"));
    const summary = try unpack(std.testing.allocator, io, &reader, temporary.dir, "stage", try fixtureExpected("valid"), .{}, .{});
    try std.testing.expectEqual(@as(usize, 2), summary.files);
    const file = try temporary.dir.openFile(io, "stage/payload.bin", .{});
    defer file.close(io);
    var contents: [7]u8 = undefined;
    try std.testing.expectEqual(contents.len, try file.readPositionalAll(io, &contents, 0));
    try std.testing.expectEqualStrings("runtime", &contents);
    try std.testing.expectError(error.PathAlreadyExists, unpack(std.testing.allocator, io, &reader, temporary.dir, "stage", try fixtureExpected("valid"), .{}, .{}));
}

test "component USTAR directories accept one conventional trailing slash" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{ .iterate = true });
    defer temporary.cleanup();
    var reader: std.Io.Reader = .fixed(@embedFile("office_component_archive_fixtures/directory.tar.gz"));
    _ = try unpack(std.testing.allocator, io, &reader, temporary.dir, "stage", try fixtureExpected("directory"), .{}, .{});
    const file = try temporary.dir.statFile(io, "stage/tools/payload.bin", .{});
    try std.testing.expectEqual(@as(u64, 7), file.size);
}

test "component bootstrap rejects invalid dialect, links, aliases, identities and trailing data with cleanup" {
    const io = std.testing.io;
    inline for (.{ "traversal", "symlink", "pax", "binary-size", "crc", "wrong-target", "wrong-member", "duplicate-manifest", "case-collision", "debug", "trailing", "trailing-tar" }) |name| {
        var temporary = std.testing.tmpDir(.{ .iterate = true });
        defer temporary.cleanup();
        const keep = try temporary.dir.createFile(io, "preserved", .{ .read = true, .exclusive = true });
        defer keep.close(io);
        try keep.writeStreamingAll(io, "user");
        var reader: std.Io.Reader = .fixed(@embedFile("office_component_archive_fixtures/" ++ name ++ ".tar.gz"));
        if (unpack(std.testing.allocator, io, &reader, temporary.dir, "stage", try fixtureExpected(name), .{}, .{})) |_| {
            std.debug.print("unexpectedly accepted component fixture: {s}\n", .{name});
            return error.AcceptedInvalidComponent;
        } else |_| {}
        try std.testing.expectError(error.FileNotFound, temporary.dir.statFile(io, "stage", .{ .follow_symlinks = false }));
        var contents: [4]u8 = undefined;
        try std.testing.expectEqual(contents.len, try keep.readPositionalAll(io, &contents, 0));
        try std.testing.expectEqualStrings("user", &contents);
    }
}

test "component cancellation, byte and member budgets clean only their own partial stage" {
    const io = std.testing.io;
    const Cancel = struct {
        fn observe(_: ?*anyopaque, progress: Progress) bool {
            return progress.files == 0;
        }
    };
    var temporary = std.testing.tmpDir(.{ .iterate = true });
    defer temporary.cleanup();
    const expected = try fixtureExpected("valid");
    var reader: std.Io.Reader = .fixed(@embedFile("office_component_archive_fixtures/valid.tar.gz"));
    try std.testing.expectError(error.Cancelled, unpack(std.testing.allocator, io, &reader, temporary.dir, "cancelled", expected, .{}, .{ .observe_fn = Cancel.observe }));
    try std.testing.expectError(error.FileNotFound, temporary.dir.statFile(io, "cancelled", .{}));
    for ([_]Limits{ .{ .member_bytes = 4 }, .{ .members = 1 }, .{ .metadata_bytes = 1 }, .{ .manifest_bytes = 1 } }) |limits| {
        reader = .fixed(@embedFile("office_component_archive_fixtures/valid.tar.gz"));
        if (unpack(std.testing.allocator, io, &reader, temporary.dir, "limited", expected, limits, .{})) |_| return error.AcceptedOversizeComponent else |_| {}
        try std.testing.expectError(error.FileNotFound, temporary.dir.statFile(io, "limited", .{}));
    }
    var wrong = expected;
    wrong.sha256[0] ^= 1;
    reader = .fixed(@embedFile("office_component_archive_fixtures/valid.tar.gz"));
    try std.testing.expectError(error.ComponentDigest, unpack(std.testing.allocator, io, &reader, temporary.dir, "digest", wrong, .{}, .{}));
    try std.testing.expectError(error.FileNotFound, temporary.dir.statFile(io, "digest", .{}));
}
