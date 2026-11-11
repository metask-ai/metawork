//! Product-owned originals. Staging and accepted Task files share one private
//! store so admission moves a file rather than copying a large attachment.
const std = @import("std");

pub const Error = std.mem.Allocator.Error || error{ DirectoryUnavailable, ReadFailed, WriteFailed, UnsupportedType, FileChanged, FileTooLarge, DeleteFailed };
pub const File = struct {
    name: [32]u8,
    task_id: u64 = 0,
    size: usize,
    extension: Extension = .{},
};

/// Only a bounded ASCII suffix reaches the owned random filename. The user's
/// display name never becomes a storage path or a format authority.
pub const Extension = struct {
    pub const max_bytes = 16;
    bytes: [max_bytes]u8 = .{ 'b', 'i', 'n' } ++ .{0} ** (max_bytes - 3),
    len: usize = 3,

    pub fn slice(self: *const Extension) []const u8 {
        return self.bytes[0..self.len];
    }
    pub fn fromName(name: []const u8) Extension {
        const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return .{};
        return fromSuffix(name[dot + 1 ..]) catch .{};
    }
    pub fn fromSuffix(suffix: []const u8) error{UnsupportedType}!Extension {
        if (suffix.len == 0 or suffix.len > max_bytes) return error.UnsupportedType;
        var result: Extension = .{};
        for (suffix, 0..) |byte, index| {
            if (!std.ascii.isAlphanumeric(byte)) return error.UnsupportedType;
            result.bytes[index] = std.ascii.toLower(byte);
        }
        result.len = suffix.len;
        return result;
    }
};
pub const max_relative_bytes = 20 + 1 + 32 + 1 + Extension.max_bytes;
const max_filename_bytes = 32 + 1 + Extension.max_bytes;

pub const Source = struct {
    handle: std.Io.File,
    before: std.Io.File.Stat,
    pub fn close(self: Source, io: std.Io) void {
        self.handle.close(io);
    }
};

pub const FileStore = struct {
    io: std.Io,
    root: std.Io.Dir,
    lock_file: std.Io.File,
    directory: []u8,
    allocator: std.mem.Allocator,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, directory: []const u8) Error!FileStore {
        if (!std.fs.path.isAbsolute(directory)) return error.DirectoryUnavailable;
        const root = std.Io.Dir.cwd().createDirPathOpen(io, directory, .{
            .open_options = .{ .follow_symlinks = false },
            .permissions = directoryPermissions(),
        }) catch return error.DirectoryUnavailable;
        errdefer root.close(io);
        const lock_file = root.createFile(io, ".attachment-store.lock", .{ .read = true, .truncate = false, .lock = .exclusive, .lock_nonblocking = true, .permissions = filePermissions(), .resolve_beneath = true }) catch return error.DirectoryUnavailable;
        errdefer lock_file.close(io);
        root.deleteTree(io, "0") catch return error.DirectoryUnavailable;
        const owned = try allocator.dupe(u8, directory);
        return .{ .io = io, .root = root, .lock_file = lock_file, .directory = owned, .allocator = allocator };
    }

    pub fn deinit(self: *FileStore) void {
        self.lock_file.close(self.io);
        self.root.close(self.io);
        self.allocator.free(self.directory);
        self.* = undefined;
    }

    fn relative(file: File, buffer: []u8) Error![]const u8 {
        return std.fmt.bufPrint(buffer, "{d}/{s}.{s}", .{ file.task_id, file.name, file.extension.slice() }) catch error.WriteFailed;
    }

    /// Store-relative location for an independent bounded reader.
    pub fn relativePath(file: File, buffer: []u8) Error![]const u8 {
        return relative(file, buffer);
    }

    pub fn allocate(self: *FileStore, size: usize) Error!File {
        var random: [16]u8 = undefined;
        std.Io.randomSecure(self.io, &random) catch return error.WriteFailed;
        return .{ .name = std.fmt.bytesToHex(random, .lower), .size = size };
    }

    pub fn create(self: *FileStore, value: File) Error!void {
        var dir = self.root.createDirPathOpen(self.io, "0", .{ .open_options = .{ .follow_symlinks = false }, .permissions = directoryPermissions() }) catch return error.WriteFailed;
        defer dir.close(self.io);
        var name_buffer: [max_filename_bytes]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buffer, "{s}.{s}", .{ value.name, value.extension.slice() }) catch return error.WriteFailed;
        const file = dir.createFile(self.io, name, .{ .exclusive = true, .permissions = filePermissions(), .resolve_beneath = true }) catch return error.WriteFailed;
        file.close(self.io);
    }

    pub fn begin(self: *FileStore, size: usize) Error!File {
        const value = try self.allocate(size);
        try self.create(value);
        return value;
    }

    pub fn append(self: *FileStore, value: File, offset: usize, bytes: []const u8) Error!void {
        if (offset > value.size or bytes.len > value.size - offset) return error.WriteFailed;
        var buffer: [max_relative_bytes]u8 = undefined;
        const path = try relative(value, &buffer);
        const file = positionalHandle(self.root.openFile(self.io, path, .{ .mode = .read_write, .follow_symlinks = false, .resolve_beneath = true }) catch return error.WriteFailed);
        defer file.close(self.io);
        file.writePositionalAll(self.io, bytes, offset) catch return error.WriteFailed;
    }

    pub fn finish(self: *FileStore, value: File) Error!void {
        var buffer: [max_relative_bytes]u8 = undefined;
        const file = positionalHandle(self.root.openFile(self.io, try relative(value, &buffer), .{ .mode = .read_write, .follow_symlinks = false, .resolve_beneath = true }) catch return error.WriteFailed);
        defer file.close(self.io);
        const stat = file.stat(self.io) catch return error.WriteFailed;
        if (stat.kind != .file or stat.size != value.size) return error.FileChanged;
        file.sync(self.io) catch return error.WriteFailed;
    }

    pub fn put(self: *FileStore, bytes: []const u8) Error!File {
        const value = try self.begin(bytes.len);
        errdefer self.delete(value);
        try self.append(value, 0, bytes);
        try self.finish(value);
        return value;
    }

    pub fn openSource(self: *FileStore, path: []const u8) Error!Source {
        const source = positionalHandle(std.Io.Dir.openFileAbsolute(self.io, path, .{ .allow_directory = false, .follow_symlinks = false }) catch return error.ReadFailed);
        errdefer source.close(self.io);
        const stat = source.stat(self.io) catch return error.ReadFailed;
        if (stat.kind != .file or stat.size == 0) return error.UnsupportedType;
        return .{ .handle = source, .before = stat };
    }

    /// Source is opened exactly once at probe; copy keeps that identity and
    /// checks cancellation between bounded reads and writes.
    pub fn copySource(self: *FileStore, source: Source, value: File, cancelled: ?*const std.atomic.Value(bool)) (Error || error{Cancelled})!void {
        var bytes: [64 * 1024]u8 = undefined;
        defer std.crypto.secureZero(u8, &bytes);
        var offset: usize = 0;
        while (offset < value.size) {
            if (cancelled) |token| if (token.load(.acquire)) return error.Cancelled;
            const chunk = bytes[0..@min(bytes.len, value.size - offset)];
            const count = source.handle.readPositionalAll(self.io, chunk, offset) catch return error.ReadFailed;
            if (count != chunk.len) return error.FileChanged;
            if (cancelled) |token| if (token.load(.acquire)) return error.Cancelled;
            try self.append(value, offset, chunk);
            offset += count;
        }
        const after = source.handle.stat(self.io) catch return error.ReadFailed;
        const before = source.before;
        if (before.inode != after.inode or before.size != after.size or !std.meta.eql(before.mtime, after.mtime) or !std.meta.eql(before.ctime, after.ctime)) return error.FileChanged;
        try self.finish(value);
    }

    pub fn copyPath(self: *FileStore, path: []const u8, max_bytes: usize) Error!File {
        const source = try self.openSource(path);
        defer source.close(self.io);
        if (source.before.size > max_bytes) return error.FileTooLarge;
        const value = try self.begin(@intCast(source.before.size));
        errdefer self.delete(value);
        self.copySource(source, value, null) catch |err| return switch (err) {
            error.Cancelled => unreachable,
            else => |failure| failure,
        };
        return value;
    }

    pub fn read(self: *FileStore, value: File, offset: usize, bytes: []u8) Error!usize {
        var buffer: [max_relative_bytes]u8 = undefined;
        const file = positionalHandle(self.root.openFile(self.io, try relative(value, &buffer), .{ .follow_symlinks = false, .resolve_beneath = true }) catch return error.ReadFailed);
        defer file.close(self.io);
        return file.readPositionalAll(self.io, bytes, offset) catch error.ReadFailed;
    }

    pub fn readAlloc(self: *FileStore, allocator: std.mem.Allocator, value: File) Error![]u8 {
        const bytes = try allocator.alloc(u8, value.size);
        errdefer allocator.free(bytes);
        if (try self.read(value, 0, bytes) != bytes.len) return error.FileChanged;
        return bytes;
    }

    pub fn move(self: *FileStore, value: *File, task_id: u64) Error!void {
        var target = value.*;
        target.task_id = task_id;
        try self.rename(value, target);
    }

    pub fn setExtension(self: *FileStore, value: *File, extension: []const u8) Error!void {
        var target = value.*;
        target.extension = try Extension.fromSuffix(extension);
        if (std.mem.eql(u8, value.extension.slice(), target.extension.slice())) return;
        try self.rename(value, target);
    }

    fn rename(self: *FileStore, value: *File, target: File) Error!void {
        const task_id = target.task_id;
        var source_buffer: [max_relative_bytes]u8 = undefined;
        var target_buffer: [max_relative_bytes]u8 = undefined;
        var dir_buffer: [32]u8 = undefined;
        const task_dir = std.fmt.bufPrint(&dir_buffer, "{d}", .{task_id}) catch return error.WriteFailed;
        var dir = self.root.createDirPathOpen(self.io, task_dir, .{ .open_options = .{ .follow_symlinks = false }, .permissions = directoryPermissions() }) catch return error.WriteFailed;
        defer dir.close(self.io);
        self.root.rename(try relative(value.*, &source_buffer), self.root, try relative(target, &target_buffer), self.io) catch return error.WriteFailed;
        value.* = target;
        if (@import("builtin").os.tag != .windows) {
            const directory_file: std.Io.File = .{ .handle = dir.handle, .flags = .{ .nonblocking = false } };
            directory_file.sync(self.io) catch return error.WriteFailed;
            const root_file: std.Io.File = .{ .handle = self.root.handle, .flags = .{ .nonblocking = false } };
            root_file.sync(self.io) catch return error.WriteFailed;
        }
    }

    pub fn pathAlloc(self: *FileStore, allocator: std.mem.Allocator, value: File) Error![]u8 {
        var buffer: [max_relative_bytes]u8 = undefined;
        return std.fs.path.join(allocator, &.{ self.directory, try relative(value, &buffer) });
    }

    pub fn delete(self: *FileStore, value: File) void {
        self.deleteChecked(value) catch {};
    }

    pub fn deleteChecked(self: *FileStore, value: File) Error!void {
        var buffer: [max_relative_bytes]u8 = undefined;
        self.root.deleteFile(self.io, try relative(value, &buffer)) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return error.DeleteFailed,
        };
    }

    pub fn deleteTask(self: *FileStore, task_id: u64) void {
        if (task_id == 0) return;
        var buffer: [32]u8 = undefined;
        const path = std.fmt.bufPrint(&buffer, "{d}", .{task_id}) catch return;
        self.root.deleteTree(self.io, path) catch {};
    }
};

// Windows no-follow opens use asynchronous handles. Reflect that mode in the
// owned File so std.Io waits for pending positional operations correctly.
fn positionalHandle(opened: std.Io.File) std.Io.File {
    var file = opened;
    if (@import("builtin").os.tag == .windows) file.flags.nonblocking = true;
    return file;
}

fn directoryPermissions() std.Io.File.Permissions {
    return if (@import("builtin").os.tag == .windows) .default_dir else .fromMode(0o700);
}
fn filePermissions() std.Io.File.Permissions {
    return if (@import("builtin").os.tag == .windows) .default_file else .fromMode(0o600);
}

test "accepted originals survive reopening and Task deletion removes them" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buffer);
    const directory = path_buffer[0..path_len];
    var initial = try FileStore.init(std.testing.io, std.testing.allocator, directory);
    var accepted = try initial.put("complete original\nsecond line\n");
    // Existing checkpoint references with a .txt path remain readable.
    try initial.setExtension(&accepted, "txt");
    try initial.move(&accepted, 42);
    const abandoned = try initial.put("unaccepted draft");
    initial.deinit();
    var reopened = try FileStore.init(std.testing.io, std.testing.allocator, directory);
    defer reopened.deinit();
    const original = try reopened.readAlloc(std.testing.allocator, accepted);
    defer std.testing.allocator.free(original);
    try std.testing.expectEqualStrings("complete original\nsecond line\n", original);
    var bytes: [64]u8 = undefined;
    try std.testing.expectError(error.ReadFailed, reopened.read(abandoned, 0, &bytes));
    reopened.deleteTask(42);
    try std.testing.expectError(error.ReadFailed, reopened.read(accepted, 0, &bytes));
}

test "positional originals and bounded path copy retain exact bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buffer);
    var store = try FileStore.init(std.testing.io, std.testing.allocator, path_buffer[0..path_len]);
    defer store.deinit();
    const value = try store.begin(8);
    defer store.delete(value);
    try store.append(value, 4, "efgh");
    try store.append(value, 0, "abcd");
    try store.finish(value);
    var part: [3]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3), try store.read(value, 2, &part));
    try std.testing.expectEqualStrings("cde", &part);
    const source_path = try store.pathAlloc(std.testing.allocator, value);
    defer std.testing.allocator.free(source_path);
    const copied = try store.copyPath(source_path, 8);
    defer store.delete(copied);
    const bytes = try store.readAlloc(std.testing.allocator, copied);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("abcdefgh", bytes);
    try std.testing.expectError(error.FileTooLarge, store.copyPath(source_path, 7));
}

test "copy rejects a changed source using the original open handle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "source.txt", .data = "abc" });
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &root);
    var file_store = try FileStore.init(std.testing.io, std.testing.allocator, root[0..len]);
    defer file_store.deinit();
    const path = try std.fs.path.join(std.testing.allocator, &.{ root[0..len], "source.txt" });
    defer std.testing.allocator.free(path);
    const source = try file_store.openSource(path);
    defer source.close(std.testing.io);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "source.txt", .data = "abcd" });
    const target = try file_store.begin(3);
    defer file_store.delete(target);
    try std.testing.expectError(error.FileChanged, file_store.copySource(source, target, null));
}

test "owned suffix preserves document types without admitting user paths" {
    for ([_][]const u8{ "DOCX", "xlsx", "pptx", "zip", "1234567890abcdef" }) |suffix| {
        var ext = try Extension.fromSuffix(suffix);
        try std.testing.expectEqual(suffix.len, ext.slice().len);
    }
    var office = Extension.fromName("report.DOCX");
    try std.testing.expectEqualStrings("docx", office.slice());
    for ([_][]const u8{ "no-extension", "report.", "a.1234567890abcdefg", "a.bad/slash", "a.bad\\slash", "a.é" }) |name| {
        var ext = Extension.fromName(name);
        try std.testing.expectEqualStrings("bin", ext.slice());
    }
    try std.testing.expectError(error.UnsupportedType, Extension.fromSuffix("../zip"));
}
