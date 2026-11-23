//! Opening a user instruction file so that what is checked is what is read.
//!
//! The file is opened first and every fact about it comes from the handle:
//! its kind, size and modification time, and, where a caller needs it, the
//! path it resolves to. A path can be swapped for another file between a stat
//! and an open; a handle cannot.
//!
//! On POSIX the open does not wait. A FIFO or a device at the path would
//! otherwise hold the opener until a writer appeared; with `O_NONBLOCK` it
//! opens at once, the handle reports what it is, and anything but a regular
//! file is closed unread. A regular file then has the flag cleared, so reads
//! behave as ordinary blocking reads.
const std = @import("std");
const builtin = @import("builtin");

pub const OpenError = error{
    FileNotFound,
    AccessDenied,
    NotRegularFile,
    InputOutput,
};

pub const Opened = struct {
    file: std.Io.File,
    stat: std.Io.File.Stat,
};

/// A regular file at `path`, followed through links, with its handle's
/// stat. Anything else is closed before this returns.
pub fn openRegular(io: std.Io, path: []const u8) OpenError!Opened {
    const file = try openWithoutWaiting(io, path);
    errdefer file.close(io);
    const stat = file.stat(io) catch |err| return switch (err) {
        error.AccessDenied, error.PermissionDenied => error.AccessDenied,
        else => error.InputOutput,
    };
    if (stat.kind != .file) return error.NotRegularFile;
    return .{ .file = try blocking(file), .stat = stat };
}

fn openWithoutWaiting(io: std.Io, path: []const u8) OpenError!std.Io.File {
    if (builtin.os.tag == .windows) {
        // Opening a path on Windows never waits for a writer, and the open
        // itself refuses a directory.
        return std.Io.Dir.openFileAbsolute(io, path, .{ .allow_directory = false }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => error.FileNotFound,
            error.AccessDenied, error.PermissionDenied => error.AccessDenied,
            error.IsDir => error.NotRegularFile,
            else => error.InputOutput,
        };
    }
    const posix = std.posix;
    var flags: posix.O = .{ .ACCMODE = .RDONLY, .NONBLOCK = true };
    if (@hasField(posix.O, "CLOEXEC")) flags.CLOEXEC = true;
    if (@hasField(posix.O, "NOCTTY")) flags.NOCTTY = true;
    if (@hasField(posix.O, "LARGEFILE")) flags.LARGEFILE = true;
    const fd = posix.openat(posix.AT.FDCWD, path, flags, 0) catch |err| return switch (err) {
        error.FileNotFound, error.NotDir => error.FileNotFound,
        error.AccessDenied, error.PermissionDenied => error.AccessDenied,
        error.IsDir => error.NotRegularFile,
        // A FIFO without a writer, or a device, can refuse a read-only open
        // outright rather than wait.
        error.NoDevice, error.WouldBlock, error.DeviceBusy => error.NotRegularFile,
        else => error.InputOutput,
    };
    return .{ .handle = fd, .flags = .{ .nonblocking = true } };
}

/// Clears `O_NONBLOCK` from a regular file's handle. Windows handles were
/// opened synchronous and need nothing.
fn blocking(file: std.Io.File) OpenError!std.Io.File {
    if (builtin.os.tag == .windows) return file;
    const posix = std.posix;
    const current: usize = while (true) {
        const rc = posix.system.fcntl(file.handle, posix.F.GETFL, @as(usize, 0));
        switch (posix.errno(rc)) {
            .SUCCESS => break @intCast(rc),
            .INTR => continue,
            else => return error.InputOutput,
        }
    };
    const cleared = current & ~@as(usize, 1 << @bitOffsetOf(posix.O, "NONBLOCK"));
    while (true) switch (posix.errno(posix.system.fcntl(file.handle, posix.F.SETFL, cleared))) {
        .SUCCESS => break,
        .INTR => continue,
        else => return error.InputOutput,
    };
    return .{ .handle = file.handle, .flags = .{ .nonblocking = false } };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn tmpPath(dir: std.testing.TmpDir, name: []const u8) ![]u8 {
    const root = try dir.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    return std.fs.path.join(testing.allocator, &.{ root, name });
}

test "only a regular file opens, and its handle reports what it is" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "AGENTS.md", .data = "Use tabs." });
    try tmp.dir.createDirPath(testing.io, "directory");
    const file_path = try tmpPath(tmp, "AGENTS.md");
    defer testing.allocator.free(file_path);
    const opened = try openRegular(testing.io, file_path);
    defer opened.file.close(testing.io);
    try testing.expect(!opened.file.flags.nonblocking);
    try testing.expectEqual(@as(u64, "Use tabs.".len), opened.stat.size);
    var buffer: [16]u8 = undefined;
    try testing.expectEqualStrings("Use tabs.", buffer[0..try opened.file.readPositionalAll(testing.io, &buffer, 0)]);

    const directory = try tmpPath(tmp, "directory");
    defer testing.allocator.free(directory);
    try testing.expectError(error.NotRegularFile, openRegular(testing.io, directory));
    const missing = try tmpPath(tmp, "missing.md");
    defer testing.allocator.free(missing);
    try testing.expectError(error.FileNotFound, openRegular(testing.io, missing));
}

test "a FIFO is closed unread instead of holding the opener" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(tmp, "AGENTS.md");
    defer testing.allocator.free(path);
    const path_z = try testing.allocator.dupeZ(u8, path);
    defer testing.allocator.free(path_z);
    if (!makeFifo(path_z)) return error.SkipZigTest;
    // No writer exists: a blocking open would never return.
    try testing.expectError(error.NotRegularFile, openRegular(testing.io, path));
}

fn makeFifo(path: [:0]const u8) bool {
    if (builtin.os.tag == .linux) {
        const posix = std.posix;
        return posix.errno(std.os.linux.mknodat(posix.AT.FDCWD, path, posix.S.IFIFO | 0o600, 0)) == .SUCCESS;
    }
    if (!builtin.link_libc) return false;
    return mkfifo(path, 0o600) == 0;
}

extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;
