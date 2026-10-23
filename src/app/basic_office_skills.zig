//! Application publishes the small built-in method guides. Executable resources
//! belong to the optional Office component, not this application resource set.
const std = @import("std");
const builtin = @import("builtin");

const guides = .{
    .{ "docx", @embedFile("basic_office_skills/docx/SKILL.md") },
    .{ "xlsx", @embedFile("basic_office_skills/xlsx/SKILL.md") },
    .{ "pptx", @embedFile("basic_office_skills/pptx/SKILL.md") },
};
const version = value: {
    @setEvalBranchQuota(500_000);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var size: usize = 0;
    for (guides) |guide| {
        hash.update(guide[0]);
        hash.update("\x00");
        hash.update(guide[1]);
        size += guide[1].len;
    }
    if (size > 16 * 1024) @compileError("Basic Office guides exceed the lightweight resource budget");
    break :value std.fmt.bytesToHex(hash.finalResult(), .lower);
};

/// Called only by the primary Application before catalog queries can start.
/// The returned canonical path is allocator-owned. Versions are immutable and
/// distinct so an app update never rewrites files referenced by a live catalog.
pub fn prepare(allocator: std.mem.Allocator, io: std.Io, data_root: []const u8) ![:0]u8 {
    const parent_path = try std.fs.path.join(allocator, &.{ data_root, "builtin-office" });
    defer allocator.free(parent_path);
    const parent = try std.Io.Dir.cwd().createDirPathOpen(io, parent_path, .{
        .open_options = .{ .follow_symlinks = false },
        .permissions = directoryPermissions(),
    });
    defer parent.close(io);
    try publish(io, parent);
    const path = try std.fs.path.join(allocator, &.{ parent_path, &version });
    defer allocator.free(path);
    return std.Io.Dir.realPathFileAbsoluteAlloc(io, path, allocator);
}

fn publish(io: std.Io, parent: std.Io.Dir) !void {
    verify(io, parent) catch |failure| {
        if (failure == error.Canceled) return failure;
        var random: [16]u8 = undefined;
        try std.Io.randomSecure(io, &random);
        var name_buffer: [64]u8 = undefined;
        const isolated = try std.fmt.bufPrint(&name_buffer, "quarantined-{s}", .{std.fmt.bytesToHex(random, .lower)});
        // Primary startup precedes every catalog. Preserve a changed entry by
        // rename; never rewrite it or follow it while recreating trusted bytes.
        parent.renamePreserve(&version, parent, isolated, io) catch |rename_failure| {
            if (rename_failure != error.FileNotFound) return rename_failure;
        };
        try std.Io.randomSecure(io, &random);
        const name = try std.fmt.bufPrint(&name_buffer, ".{s}.tmp", .{std.fmt.bytesToHex(random, .lower)});
        try parent.createDir(io, name, directoryPermissions());
        var temporary_exists = true;
        defer if (temporary_exists) parent.deleteTree(io, name) catch {};
        {
            const temporary = try parent.openDir(io, name, .{ .follow_symlinks = false });
            defer temporary.close(io);
            inline for (guides) |guide| {
                try temporary.createDir(io, guide[0], directoryPermissions());
                const file = try temporary.createFile(io, guide[0] ++ "/SKILL.md", .{
                    .exclusive = true,
                    .permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(0o600),
                });
                defer file.close(io);
                try file.writeStreamingAll(io, guide[1]);
                try file.sync(io);
            }
        }
        try parent.renamePreserve(name, parent, &version, io);
        temporary_exists = false;
        try verify(io, parent);
    };
}

fn verify(io: std.Io, parent: std.Io.Dir) !void {
    const root = try parent.openDir(io, &version, .{ .follow_symlinks = false, .iterate = true });
    defer root.close(io);
    var entries = root.iterate();
    var count: usize = 0;
    while (try entries.next(io)) |entry| {
        if (entry.kind != .directory) return error.BasicSkillChanged;
        var known = false;
        inline for (guides) |guide| {
            if (std.mem.eql(u8, entry.name, guide[0])) known = true;
        }
        if (!known) return error.BasicSkillChanged;
        count += 1;
    }
    if (count != guides.len) return error.BasicSkillChanged;
    inline for (guides) |guide| {
        const directory = root.openDir(io, guide[0], .{ .follow_symlinks = false, .iterate = true }) catch return error.BasicSkillChanged;
        defer directory.close(io);
        var files = directory.iterate();
        const definition = try files.next(io) orelse return error.BasicSkillChanged;
        if (definition.kind != .file or !std.mem.eql(u8, definition.name, "SKILL.md") or try files.next(io) != null)
            return error.BasicSkillChanged;
        var file = directory.openFile(io, "SKILL.md", .{ .follow_symlinks = false }) catch return error.BasicSkillChanged;
        // Zig 0.16 opens Windows directory-relative file handles asynchronously.
        if (builtin.os.tag == .windows) file.flags.nonblocking = true;
        defer file.close(io);
        const before = try file.stat(io);
        if (before.kind != .file or before.size != guide[1].len) return error.BasicSkillChanged;
        var contents: [guide[1].len]u8 = undefined;
        if (try file.readPositionalAll(io, &contents, 0) != contents.len or !std.mem.eql(u8, &contents, guide[1])) return error.BasicSkillChanged;
        const after = try file.stat(io);
        if (after.size != before.size or after.mtime.nanoseconds != before.mtime.nanoseconds) return error.BasicSkillChanged;
    }
}

fn directoryPermissions() std.Io.Dir.Permissions {
    return if (builtin.os.tag == .windows) .default_dir else .fromMode(0o700);
}

test "basic Office guides publish immutably without an installed interpreter" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{ .iterate = true });
    defer temporary.cleanup();
    try publish(io, temporary.dir);
    try publish(io, temporary.dir);
    try verify(io, temporary.dir);
    try temporary.dir.writeFile(io, .{ .sub_path = version ++ "/docx/SKILL.md", .data = "changed" });
    try publish(io, temporary.dir);
    try verify(io, temporary.dir);
    const changed = try temporary.dir.statFile(io, version ++ "/docx/SKILL.md", .{});
    try std.testing.expect(changed.size > 7);
    var entries = temporary.dir.iterate();
    var quarantines: usize = 0;
    while (try entries.next(io)) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "quarantined-")) continue;
        const isolated = try temporary.dir.openDir(io, entry.name, .{});
        defer isolated.close(io);
        var file = try isolated.openFile(io, "docx/SKILL.md", .{});
        defer file.close(io);
        if (builtin.os.tag == .windows) file.flags.nonblocking = true;
        var bytes: [7]u8 = undefined;
        try std.testing.expectEqual(@as(usize, 7), try file.readPositionalAll(io, &bytes, 0));
        try std.testing.expectEqualStrings("changed", &bytes);
        quarantines += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), quarantines);
}

test "basic Office publication repairs a partial existing version before catalogs" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDir(io, &version, directoryPermissions());
    try publish(io, temporary.dir);
    try verify(io, temporary.dir);
}

test "basic Office source cannot acquire additional definitions or executable resources" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try publish(io, temporary.dir);
    try temporary.dir.writeFile(io, .{ .sub_path = version ++ "/docx/extra.py", .data = "unexpected" });
    try publish(io, temporary.dir);
    try verify(io, temporary.dir);
    try temporary.dir.createDir(io, version ++ "/extra", directoryPermissions());
    try publish(io, temporary.dir);
    try verify(io, temporary.dir);
}

test "basic Office prepared source returns its complete owned canonical allocation" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const prepared = try prepare(std.testing.allocator, std.testing.io, root);
    defer std.testing.allocator.free(prepared);
    try std.testing.expect(std.fs.path.isAbsolute(prepared));
    const opened = try std.Io.Dir.cwd().openDir(std.testing.io, prepared, .{});
    opened.close(std.testing.io);
}
