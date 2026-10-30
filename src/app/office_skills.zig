//! Small immutable built-in Skill resources. No runtime or catalog version owner.
const std = @import("std");
const builtin = @import("builtin");
const archive = @embedFile("office-skills.tar.gz");
fn versionName() [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(archive, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn prepare(allocator: std.mem.Allocator, io: std.Io, data_root: []const u8) ![:0]u8 {
    const version = versionName();
    const base = try std.fs.path.join(allocator, &.{ data_root, "builtin-office" });
    defer allocator.free(base);
    const parent = try std.Io.Dir.cwd().createDirPathOpen(io, base, .{ .open_options = .{ .follow_symlinks = false } });
    defer parent.close(io);
    try publish(allocator, io, parent);
    const path = try std.fs.path.join(allocator, &.{ base, &version });
    defer allocator.free(path);
    return std.Io.Dir.realPathFileAbsoluteAlloc(io, path, allocator);
}

fn contents(allocator: std.mem.Allocator) ![]u8 {
    var source = std.Io.Reader.fixed(archive);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decoder: std.compress.flate.Decompress = .init(&source, .gzip, &window);
    const bytes = try decoder.reader.allocRemaining(allocator, .limited(8 * 1024 * 1024));
    errdefer allocator.free(bytes);
    if (decoder.container_metadata.gzip.crc != std.hash.Crc32.hash(bytes) or decoder.container_metadata.gzip.count != bytes.len)
        return error.SkillArchiveCorrupt;
    return bytes;
}

fn safePath(path: []const u8) !void {
    if (path.len == 0 or path.len > 256 or std.mem.indexOfAny(u8, path, "\\:\x00") != null) return error.SkillArchivePath;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.SkillArchivePath;
    }
}

fn visit(allocator: std.mem.Allocator, io: std.Io, directory: std.Io.Dir, write: bool) !void {
    const bytes = try contents(allocator);
    defer allocator.free(bytes);
    var reader = std.Io.Reader.fixed(bytes);
    var names: [256]u8 = undefined;
    var links: [256]u8 = undefined;
    var iterator: std.tar.Iterator = .init(&reader, .{ .file_name_buffer = &names, .link_name_buffer = &links });
    var count: usize = 0;
    while (try iterator.next()) |entry| {
        try safePath(entry.name);
        count += 1;
        if (entry.kind != .file or entry.link_name.len != 0 or entry.size > 1024 * 1024 or count > 512) return error.SkillArchiveBudget;
        const data = try allocator.alloc(u8, @intCast(entry.size));
        defer allocator.free(data);
        try reader.readSliceAll(data);
        iterator.unread_file_bytes = 0;
        if (write) {
            if (std.fs.path.dirname(entry.name)) |parent| try directory.createDirPath(io, parent);
            const file = try directory.createFile(io, entry.name, .{ .exclusive = true });
            defer file.close(io);
            try file.writeStreamingAll(io, data);
        } else {
            var file = try directory.openFile(io, entry.name, .{ .follow_symlinks = false });
            defer file.close(io);
            if (builtin.os.tag == .windows) file.flags.nonblocking = true;
            if ((try file.stat(io)).size != data.len) return error.SkillSourceChanged;
            const actual = try allocator.alloc(u8, data.len);
            defer allocator.free(actual);
            if (try file.readPositionalAll(io, actual, 0) != data.len or !std.mem.eql(u8, actual, data)) return error.SkillSourceChanged;
        }
    }
    if (!write) {
        var walker = try directory.walk(allocator);
        defer walker.deinit();
        var actual_count: usize = 0;
        while (try walker.next(io)) |entry| switch (entry.kind) {
            .directory => {},
            .file => actual_count += 1,
            else => return error.SkillSourceChanged,
        };
        if (actual_count != count) return error.SkillSourceChanged;
    }
}

fn publish(allocator: std.mem.Allocator, io: std.Io, parent: std.Io.Dir) !void {
    const version = versionName();
    if (parent.openDir(io, &version, .{ .follow_symlinks = false, .iterate = true })) |directory| {
        defer directory.close(io);
        // Preserve a damaged source. Failure disables Office, not Application.
        return visit(allocator, io, directory, false);
    } else |failure| if (failure != error.FileNotFound) return failure;
    var random: [16]u8 = undefined;
    try std.Io.randomSecure(io, &random);
    var buffer: [48]u8 = undefined;
    const name = try std.fmt.bufPrint(&buffer, ".{s}.tmp", .{std.fmt.bytesToHex(random, .lower)});
    try parent.createDir(io, name, .default_dir);
    var pending = true;
    defer if (pending) parent.deleteTree(io, name) catch {};
    {
        const directory = try parent.openDir(io, name, .{ .follow_symlinks = false, .iterate = true });
        defer directory.close(io);
        try visit(allocator, io, directory, true);
        try visit(allocator, io, directory, false);
    }
    if (builtin.os.tag == .macos) {
        @import("metawork_office_resource_publish_compat").publish(parent, name, &version) catch |failure| {
            if (failure != error.PathAlreadyExists) return failure;
            const winner = try parent.openDir(io, &version, .{ .follow_symlinks = false, .iterate = true });
            defer winner.close(io);
            return visit(allocator, io, winner, false);
        };
    } else {
        try parent.renamePreserve(name, parent, &version, io);
    }
    pending = false;
}

test "full Office resources publish without preparing interpreters and reject changed sources" {
    const version = versionName();
    var temporary = std.testing.tmpDir(.{ .iterate = true });
    defer temporary.cleanup();
    try publish(std.testing.allocator, std.testing.io, temporary.dir);
    try publish(std.testing.allocator, std.testing.io, temporary.dir);
    for ([_][]const u8{ "docx", "xlsx", "pptx" }) |skill| {
        for ([_][]const u8{ "SKILL.md", "environment/run.py", "scripts/office/validate.py" }) |entry| {
            const path = try std.fs.path.join(std.testing.allocator, &.{ &version, skill, entry });
            defer std.testing.allocator.free(path);
            const data = try temporary.dir.readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(1024 * 1024));
            defer std.testing.allocator.free(data);
            try std.testing.expect(data.len > 0);
        }
    }
    const verify_path = try std.fs.path.join(std.testing.allocator, &.{ &version, "xlsx/scripts/verify.py" });
    defer std.testing.allocator.free(verify_path);
    const verify = try temporary.dir.readFileAlloc(std.testing.io, verify_path, std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(verify);
    try std.testing.expect(std.mem.indexOf(u8, verify, "from office_archive import") != null);
    const definition = try std.fs.path.join(std.testing.allocator, &.{ &version, "docx/SKILL.md" });
    defer std.testing.allocator.free(definition);
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = definition, .data = "changed" });
    try std.testing.expectError(error.SkillSourceChanged, publish(std.testing.allocator, std.testing.io, temporary.dir));
}
