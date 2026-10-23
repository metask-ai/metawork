//! Worker-only inspection of explicitly selected Workspace output files.
//! This proves bytes at a locator; it does not register a Product Output or
//! infer delivery from ordinary file references or tool text.
const std = @import("std");
const builtin = @import("builtin");

pub fn absolutePath(allocator: std.mem.Allocator, root: []const u8, relative: []const u8) ![]u8 {
    if (!std.fs.path.isAbsolute(root)) return error.InvalidWorkspaceRoot;
    try validatePath(relative);
    const path = try std.fs.path.join(allocator, &.{ root, relative });
    if (builtin.os.tag == .windows) for (path) |*byte| {
        if (byte.* == '/') byte.* = '\\';
    };
    return path;
}

test "Windows reveal path normalizes nested Workspace separators" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const path = try absolutePath(std.testing.allocator, "C:\\Workspace", "results/中文/report.docx");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("C:\\Workspace\\results\\中文\\report.docx", path);
}

pub const max_file_bytes = 256 * 1024 * 1024;
pub const max_path_bytes = 512;
pub const Inspection = struct { size_bytes: u64, sha256: [32]u8 };

pub const Request = struct {
    workspace_root: []const u8,
    relative_path: []const u8,
    main_thread_id: std.Thread.Id,
    test_after_chunk: if (builtin.is_test) ?Hook else void = if (builtin.is_test) null else {},
};

pub fn validatePath(path: []const u8) error{InvalidOutputPath}!void {
    if (path.len == 0 or path.len > max_path_bytes or !std.unicode.utf8ValidateSlice(path))
        return error.InvalidOutputPath;
    for (path) |byte| if (std.ascii.isControl(byte) or std.mem.indexOfScalar(u8, "\\:<>\"|?*", byte) != null)
        return error.InvalidOutputPath;
    var parts = std.mem.splitScalar(u8, path, '/');
    var count: usize = 0;
    while (parts.next()) |part| {
        count += 1;
        if (count > 32 or part.len == 0 or part.len > 255 or
            std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..") or
            part[part.len - 1] == '.' or part[part.len - 1] == ' ')
            return error.InvalidOutputPath;
        const base = part[0 .. std.mem.indexOfScalar(u8, part, '.') orelse part.len];
        for ([_][]const u8{ "CON", "PRN", "AUX", "NUL" }) |device|
            if (std.ascii.eqlIgnoreCase(base, device)) return error.InvalidOutputPath;
        if (base.len == 4 and (std.ascii.eqlIgnoreCase(base[0..3], "COM") or
            std.ascii.eqlIgnoreCase(base[0..3], "LPT")) and base[3] >= '1' and base[3] <= '9')
            return error.InvalidOutputPath;
    }
}

/// Borrowed request bytes and cancellation owner must live through this call.
/// The admitting Product owner separately validates Task/Run/Workspace authority.
pub fn inspect(io: std.Io, request: Request, cancelled: *const std.atomic.Value(bool)) !Inspection {
    return read(io, request, cancelled, null);
}

/// Copies and hashes the same actual read stream. Destination is a caller-owned
/// empty temporary file, never the published Save As name. The caller discards
/// it on every failure and publishes it only after authority is revalidated.
pub fn copyVerified(io: std.Io, request: Request, cancelled: *const std.atomic.Value(bool), expected: Inspection, destination: std.Io.File) !void {
    _ = try read(io, request, cancelled, .{ .expected = expected, .destination = destination });
}

/// One selected Save As transaction. Construction and release only own bytes;
/// stage/publish/discard perform all filesystem effects on a worker. The caller
/// must authorize publication after stage verifies the actual copied stream.
pub const Save = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    main_thread_id: std.Thread.Id,
    storage: []u8,
    root: []const u8,
    relative: []const u8,
    destination: []const u8,
    expected: Inspection,
    pending: ?Pending = null,

    const Pending = struct {
        parent: std.Io.Dir,
        parent_identity: std.Io.File.Stat,
        previous: ?std.Io.File.Stat,
        atomic_file: std.Io.File.Atomic,
        copied_identity: ?std.Io.File.Stat = null,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, request: Request, destination: []const u8, expected: Inspection) !Save {
        try validatePath(request.relative_path);
        if (request.workspace_root.len == 0 or request.workspace_root.len > std.Io.Dir.max_path_bytes or
            !std.fs.path.isAbsolute(request.workspace_root) or !std.unicode.utf8ValidateSlice(request.workspace_root) or expected.size_bytes > max_file_bytes)
            return error.InvalidWorkspaceRoot;
        if (!std.fs.path.isAbsolute(destination) or destination.len > 4096 or
            !std.unicode.utf8ValidateSlice(destination)) return error.InvalidOutputDestination;
        for (destination) |byte| if (std.ascii.isControl(byte)) return error.InvalidOutputDestination;
        try validatePath(std.fs.path.basename(destination));
        const storage = try allocator.alloc(u8, request.workspace_root.len + request.relative_path.len + destination.len);
        const root = storage[0..request.workspace_root.len];
        const relative = storage[root.len..][0..request.relative_path.len];
        const target = storage[root.len + relative.len ..];
        @memcpy(root, request.workspace_root);
        @memcpy(relative, request.relative_path);
        @memcpy(target, destination);
        return .{ .allocator = allocator, .io = io, .main_thread_id = request.main_thread_id, .storage = storage, .root = root, .relative = relative, .destination = target, .expected = expected };
    }

    pub fn deinit(self: *Save) void {
        std.debug.assert(self.pending == null);
        self.allocator.free(self.storage);
        self.* = undefined;
    }

    pub fn stage(self: *Save, cancelled: *const std.atomic.Value(bool)) !void {
        try self.requireWorker();
        self.stageInner(cancelled) catch |err| {
            self.discard() catch return error.OutputCleanupFailed;
            return err;
        };
    }

    fn stageInner(self: *Save, cancelled: *const std.atomic.Value(bool)) !void {
        try self.requireWorker();
        if (self.pending != null) return error.InvalidOutputDestination;
        if (cancelled.load(.acquire)) return error.Cancelled;
        const parent_path = std.fs.path.dirname(self.destination) orelse return error.InvalidOutputDestination;
        var parent = try openRoot(self.io, parent_path);
        var parent_owned = true;
        errdefer if (parent_owned) parent.close(self.io);
        const parent_identity = try parent.stat(self.io);
        const basename = std.fs.path.basename(self.destination);
        const previous = try destinationStat(self.io, parent, basename);
        // Reject selecting the source itself, including another name for the
        // same inode on the same volume. A different volume can reuse an inode.
        if (previous) |existing| {
            var source_root = try openRoot(self.io, self.root);
            defer source_root.close(self.io);
            var source = try openScopedFile(self.io, source_root, self.relative);
            defer source.close(self.io);
            const source_stat = try source.stat(self.io);
            const same_volume = if (builtin.os.tag == .windows)
                std.ascii.eqlIgnoreCase(std.fs.path.diskDesignator(self.root), std.fs.path.diskDesignator(self.destination))
            else
                true;
            if (same_volume and existing.inode == source_stat.inode) return error.SameOutputDestination;
        }
        const atomic_file = try parent.createFileAtomic(self.io, basename, .{ .replace = true, .permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(0o600) });
        self.pending = .{ .parent = parent, .parent_identity = parent_identity, .previous = previous, .atomic_file = atomic_file };
        parent_owned = false;
        // std Atomic creates a write-only Windows handle. Byte-copy validation
        // also needs read attributes, so retain a read/write handle to that
        // same exclusive temporary name before copying.
        if (builtin.os.tag == .windows) {
            const temporary_name = std.fmt.hex(self.pending.?.atomic_file.file_basename_hex);
            var readable = try parent.openFile(self.io, &temporary_name, .{ .mode = .read_write, .allow_directory = false, .follow_symlinks = false, .resolve_beneath = true });
            readable.flags.nonblocking = true;
            self.pending.?.atomic_file.file.close(self.io);
            self.pending.?.atomic_file.file = readable;
        }
        try copyVerified(self.io, .{ .workspace_root = self.root, .relative_path = self.relative, .main_thread_id = self.main_thread_id }, cancelled, self.expected, self.pending.?.atomic_file.file);
        self.pending.?.copied_identity = try self.pending.?.atomic_file.file.stat(self.io);
    }

    /// Only called after the Product owner's publication decision. Cancellation
    /// is no longer accepted once that decision has committed this operation.
    pub fn publish(self: *Save) !void {
        try self.requireWorker();
        self.publishInner() catch |err| {
            self.discard() catch return error.OutputCleanupFailed;
            return err;
        };
        try self.discard();
    }

    fn publishInner(self: *Save) !void {
        try self.requireWorker();
        const pending = if (self.pending) |*value| value else return error.InvalidOutputDestination;
        var named_parent = try openRoot(self.io, std.fs.path.dirname(self.destination).?);
        defer named_parent.close(self.io);
        if ((try named_parent.stat(self.io)).inode != pending.parent_identity.inode) return error.OutputDestinationChanged;
        const current = try destinationStat(self.io, pending.parent, std.fs.path.basename(self.destination));
        if (pending.previous) |old| {
            if (current == null or !stable(old, current.?)) return error.OutputDestinationChanged;
        } else if (current != null) return error.OutputDestinationChanged;
        const temporary_name = std.fmt.hex(pending.atomic_file.file_basename_hex);
        var named_temporary = try pending.parent.openFile(self.io, &temporary_name, .{ .allow_directory = false, .follow_symlinks = false, .resolve_beneath = true });
        const named_identity = named_temporary.stat(self.io) catch |err| {
            named_temporary.close(self.io);
            return err;
        };
        named_temporary.close(self.io);
        const copied_identity = try pending.atomic_file.file.stat(self.io);
        if (!stable(named_identity, copied_identity) or pending.copied_identity == null or
            !stable(pending.copied_identity.?, copied_identity) or copied_identity.size != self.expected.size_bytes) return error.OutputCopyChanged;
        try pending.atomic_file.replace(self.io);
    }

    /// std Atomic.deinit intentionally ignores deletion errors. Observe cleanup
    /// explicitly here so an external destination cannot leave a hidden failure.
    /// Every handle closes even if deletion is refused; callers must report it.
    pub fn discard(self: *Save) !void {
        try self.requireWorker();
        var pending = self.pending orelse return;
        self.pending = null;
        var cleanup_failed = false;
        if (pending.atomic_file.file_open) {
            pending.atomic_file.file.close(self.io);
            pending.atomic_file.file_open = false;
        }
        if (pending.atomic_file.file_exists) {
            const temporary_name = std.fmt.hex(pending.atomic_file.file_basename_hex);
            pending.parent.deleteFile(self.io, &temporary_name) catch {
                cleanup_failed = true;
            };
            pending.atomic_file.file_exists = false;
        }
        pending.atomic_file.deinit(self.io);
        pending.parent.close(self.io);
        if (cleanup_failed) return error.OutputCleanupFailed;
    }

    fn requireWorker(self: *const Save) !void {
        if (std.Thread.getCurrentId() == self.main_thread_id) return error.MainThreadFileEffect;
    }
};

fn destinationStat(io: std.Io, parent: std.Io.Dir, basename: []const u8) !?std.Io.File.Stat {
    var file = parent.openFile(io, basename, .{ .allow_directory = false, .follow_symlinks = false, .resolve_beneath = true }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file) return error.InvalidOutputDestination;
    return stat;
}

const Copy = struct { expected: Inspection, destination: std.Io.File };

fn read(io: std.Io, request: Request, cancelled: *const std.atomic.Value(bool), copy: ?Copy) !Inspection {
    if (std.Thread.getCurrentId() == request.main_thread_id) return error.MainThreadFileEffect;
    try validatePath(request.relative_path);
    if (request.workspace_root.len == 0 or request.workspace_root.len > std.Io.Dir.max_path_bytes or
        !std.fs.path.isAbsolute(request.workspace_root) or !std.unicode.utf8ValidateSlice(request.workspace_root))
        return error.InvalidWorkspaceRoot;
    for (request.workspace_root) |byte| if (std.ascii.isControl(byte)) return error.InvalidWorkspaceRoot;
    if (cancelled.load(.acquire)) return error.Cancelled;
    var root = try openRoot(io, request.workspace_root);
    defer root.close(io);
    const root_before = try root.stat(io);
    var file = try openScopedFile(io, root, request.relative_path);
    defer file.close(io);
    if (builtin.os.tag == .windows) file.flags.nonblocking = true;
    const before = try file.stat(io);
    if (before.kind != .file) return error.NotRegularOutput;
    if (before.size > max_file_bytes) return error.OutputTooLarge;
    const destination_before: ?std.Io.File.Stat = if (copy) |value| destination: {
        if (before.size != value.expected.size_bytes) return error.OutputChanged;
        const stat = try value.destination.stat(io);
        if (stat.kind != .file or stat.size != 0 or stat.inode == before.inode) return error.InvalidOutputDestination;
        break :destination stat;
    } else null;
    var hash: std.crypto.hash.sha2.Sha256 = .init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (offset < before.size) {
        if (cancelled.load(.acquire)) return error.Cancelled;
        const amount: usize = @intCast(@min(before.size - offset, buffer.len));
        const count = try file.readPositionalAll(io, buffer[0..amount], offset);
        if (count != amount) return error.OutputChanged;
        hash.update(buffer[0..count]);
        if (copy) |value| try value.destination.writePositionalAll(io, buffer[0..count], offset);
        offset += count;
        if (builtin.is_test) if (request.test_after_chunk) |hook| try hook.call_fn(hook.context);
    }
    if (cancelled.load(.acquire)) return error.Cancelled;
    const after = try file.stat(io);
    if (!stable(before, after)) return error.OutputChanged;
    // An open handle may still refer to a moved/replaced name. Re-open the
    // authorized root and locator before publishing an inspection receipt.
    var named_root = try openRoot(io, request.workspace_root);
    defer named_root.close(io);
    if ((try named_root.stat(io)).inode != root_before.inode) return error.OutputChanged;
    var named_file = try openScopedFile(io, named_root, request.relative_path);
    defer named_file.close(io);
    if (!stable(after, try named_file.stat(io))) return error.OutputChanged;
    if (cancelled.load(.acquire)) return error.Cancelled;
    const result: Inspection = .{ .size_bytes = offset, .sha256 = hash.finalResult() };
    if (copy) |value| {
        if (!std.mem.eql(u8, &result.sha256, &value.expected.sha256)) return error.OutputChanged;
        try value.destination.sync(io);
        const actual = try value.destination.stat(io);
        if (actual.kind != .file or actual.inode != destination_before.?.inode or actual.size != result.size_bytes)
            return error.OutputCopyChanged;
        if (cancelled.load(.acquire)) return error.Cancelled;
    }
    return result;
}

fn stable(before: std.Io.File.Stat, after: std.Io.File.Stat) bool {
    return before.kind == after.kind and before.inode == after.inode and before.size == after.size and
        std.meta.eql(before.mtime, after.mtime) and std.meta.eql(before.ctime, after.ctime);
}

fn openScopedFile(io: std.Io, root: std.Io.Dir, path: []const u8) !std.Io.File {
    var current = root;
    var owned = false;
    defer if (owned) current.close(io);
    const last = std.mem.lastIndexOfScalar(u8, path, '/');
    if (last) |index| {
        var parents = std.mem.splitScalar(u8, path[0..index], '/');
        while (parents.next()) |name| {
            var child = try current.openDir(io, name, .{ .access_sub_paths = true, .follow_symlinks = false });
            errdefer child.close(io);
            // Windows' no-follow flag on a multi-component file open protects
            // only the last component. Inspect every intermediate directory.
            if ((try child.stat(io)).kind != .directory) return error.RestrictedOutput;
            if (owned) current.close(io);
            current = child;
            owned = true;
        }
    }
    return current.openFile(io, path[if (last) |index| index + 1 else 0..], .{
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    });
}

/// Application filesystem effects share the same no-follow ancestor walk.
pub fn openRoot(io: std.Io, path: []const u8) !std.Io.Dir {
    var parts = std.fs.path.componentIterator(path);
    const volume = parts.root() orelse return error.InvalidWorkspaceRoot;
    var current = try std.Io.Dir.openDirAbsolute(io, volume, .{ .access_sub_paths = true, .follow_symlinks = false });
    errdefer current.close(io);
    if ((try current.stat(io)).kind != .directory) return error.InvalidWorkspaceRoot;
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part.name, ".") or std.mem.eql(u8, part.name, "..")) return error.InvalidWorkspaceRoot;
        var child = try current.openDir(io, part.name, .{ .access_sub_paths = true, .follow_symlinks = false });
        errdefer child.close(io);
        if ((try child.stat(io)).kind != .directory) return error.InvalidWorkspaceRoot;
        current.close(io);
        current = child;
    }
    return current;
}

const Hook = struct { context: *anyopaque, call_fn: *const fn (*anyopaque) anyerror!void };

const TestWork = struct {
    request: Request,
    cancelled: std.atomic.Value(bool) = .init(false),
    result: anyerror!Inspection = error.NotStarted,
    copy: ?Copy = null,

    fn run(self: *TestWork) void {
        self.result = read(std.testing.io, self.request, &self.cancelled, self.copy);
    }
    fn execute(self: *TestWork) !Inspection {
        const thread = try std.Thread.spawn(.{}, run, .{self});
        thread.join();
        return self.result;
    }
};

test "output paths reject escape, alternate streams, devices and ambiguous aliases" {
    for ([_][]const u8{ "", "/file", "../file", "a/../file", "a//file", "a/./file", "C:/file", "a\\file", "file:stream", "NUL.txt", "com1", "a/aux", "file.", "file ", "a/\x00b", "a/*", "\xff" }) |value|
        try std.testing.expectError(error.InvalidOutputPath, validatePath(value));
    try validatePath("成果/最终报告.docx");
    try validatePath("some folder/results.csv");
}

test "output copy verifies actual copied bytes and preserves existing destination files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "source.txt", .data = "abc" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var work: TestWork = .{ .request = .{ .workspace_root = root, .relative_path = "source.txt", .main_thread_id = std.Thread.getCurrentId() } };
    const expected = try work.execute();
    const destination = try tmp.dir.createFile(std.testing.io, "new.tmp", .{ .read = true, .exclusive = true });
    defer destination.close(std.testing.io);
    try std.testing.expectError(error.MainThreadFileEffect, copyVerified(std.testing.io, work.request, &work.cancelled, expected, destination));
    work.copy = .{ .expected = expected, .destination = destination };
    _ = try work.execute();
    var bytes: [3]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3), try destination.readPositionalAll(std.testing.io, &bytes, 0));
    try std.testing.expectEqualStrings("abc", &bytes);
    const existing = try tmp.dir.createFile(std.testing.io, "existing.txt", .{ .read = true, .exclusive = true });
    defer existing.close(std.testing.io);
    try existing.writeStreamingAll(std.testing.io, "keep");
    work.copy.?.destination = existing;
    try std.testing.expectError(error.InvalidOutputDestination, work.execute());
    var kept: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), try existing.readPositionalAll(std.testing.io, &kept, 0));
    try std.testing.expectEqualStrings("keep", &kept);
    // Caller must supply a fresh private file, never truncate an existing name.
    work.copy.?.destination = destination;
    try std.testing.expectError(error.InvalidOutputDestination, work.execute());
    const other = try tmp.dir.createFile(std.testing.io, "other.tmp", .{ .read = true, .exclusive = true });
    defer other.close(std.testing.io);
    work.copy.?.destination = other;
    // Same-size edits after delivery must fail against the copied stream's hash.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "source.txt", .data = "abd" });
    try std.testing.expectError(error.OutputChanged, work.execute());
    try std.testing.expectEqual(@as(usize, 3), try other.readPositionalAll(std.testing.io, &bytes, 0));
    try std.testing.expectEqualStrings("abd", &bytes);
}

test "output inspection rejects the main thread and computes complete worker-only file digests" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "abc.txt", .data = "abc" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "empty.txt", .data = "" });
    try tmp.dir.createDir(std.testing.io, "成果", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "成果/最终报告.docx", .data = "abc" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var work: TestWork = .{ .request = .{ .workspace_root = root, .relative_path = "abc.txt", .main_thread_id = std.Thread.getCurrentId() } };
    try std.testing.expectError(error.MainThreadFileEffect, inspect(std.testing.io, work.request, &work.cancelled));
    const result = try work.execute();
    try std.testing.expectEqual(@as(u64, 3), result.size_bytes);
    try std.testing.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", &std.fmt.bytesToHex(result.sha256, .lower));
    work.request.relative_path = "empty.txt";
    const empty = try work.execute();
    try std.testing.expectEqual(@as(u64, 0), empty.size_bytes);
    try std.testing.expectEqualStrings("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", &std.fmt.bytesToHex(empty.sha256, .lower));
    work.request.relative_path = "成果/最终报告.docx";
    const nested = try work.execute();
    try std.testing.expectEqualSlices(u8, &result.sha256, &nested.sha256);
    var long_bytes = [_]u8{'a'} ** (64 * 1024 + 1);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "long.bin", .data = &long_bytes });
    work.request.relative_path = "long.bin";
    const first = try work.execute();
    long_bytes[long_bytes.len - 1] = 'b';
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "long.bin", .data = &long_bytes });
    const second = try work.execute();
    try std.testing.expectEqual(@as(u64, long_bytes.len), first.size_bytes);
    try std.testing.expect(!std.mem.eql(u8, &first.sha256, &second.sha256));
    work.request.relative_path = "missing.txt";
    try std.testing.expectError(error.FileNotFound, work.execute());
    work.cancelled.store(true, .release);
    try std.testing.expectError(error.Cancelled, work.execute());
}

test "output inspection bounds actual reads and detects changes or cancellation between chunks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const large = try tmp.dir.createFile(std.testing.io, "large.bin", .{});
    try large.setLength(std.testing.io, max_file_bytes + 1);
    large.close(std.testing.io);
    var work: TestWork = .{ .request = .{ .workspace_root = root, .relative_path = "large.bin", .main_thread_id = std.Thread.getCurrentId() } };
    try std.testing.expectError(error.OutputTooLarge, work.execute());
    const bytes = [_]u8{'a'} ** (64 * 1024 + 1);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "changing.bin", .data = &bytes });
    const Fault = struct {
        dir: std.Io.Dir,
        cancelled: *std.atomic.Value(bool),
        mode: enum { truncate, replace, cancel } = .truncate,
        fired: bool = false,
        fn run(context: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.fired) return;
            self.fired = true;
            switch (self.mode) {
                .cancel => self.cancelled.store(true, .release),
                .truncate => {
                    const file = try self.dir.openFile(std.testing.io, "changing.bin", .{ .mode = .read_write });
                    defer file.close(std.testing.io);
                    try file.setLength(std.testing.io, 0);
                },
                .replace => {
                    try self.dir.rename("changing.bin", self.dir, "old.bin", std.testing.io);
                    try self.dir.writeFile(std.testing.io, .{ .sub_path = "changing.bin", .data = &bytes });
                },
            }
        }
    };
    var fault: Fault = .{ .dir = tmp.dir, .cancelled = &work.cancelled };
    work.request.relative_path = "changing.bin";
    work.request.test_after_chunk = .{ .context = &fault, .call_fn = Fault.run };
    try std.testing.expectError(error.OutputChanged, work.execute());
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "changing.bin", .data = &bytes });
    fault.fired = false;
    fault.mode = .replace;
    try std.testing.expectError(error.OutputChanged, work.execute());
    fault.fired = false;
    fault.mode = .cancel;
    try std.testing.expectError(error.Cancelled, work.execute());
}

test "output inspection refuses a Windows junction at a relative ancestor or Workspace root" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "workspace", .default_dir);
    try tmp.dir.createDir(std.testing.io, "outside", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "outside/private.txt", .data = "outside authority" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const result = try std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = &.{ "cmd.exe", "/d", "/c", "mklink", "/J", "workspace\\linked", "outside" },
        .cwd = .{ .path = root },
        .create_no_window = true,
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited == 0);
    const workspace = try std.fs.path.join(std.testing.allocator, &.{ root, "workspace" });
    defer std.testing.allocator.free(workspace);
    var work: TestWork = .{ .request = .{ .workspace_root = workspace, .relative_path = "linked/private.txt", .main_thread_id = std.Thread.getCurrentId() } };
    if (work.execute()) |_| return error.TestUnexpectedResult else |_| {}
    const linked = try std.fs.path.join(std.testing.allocator, &.{ workspace, "linked" });
    defer std.testing.allocator.free(linked);
    work.request.workspace_root = linked;
    work.request.relative_path = "private.txt";
    if (work.execute()) |_| return error.TestUnexpectedResult else |_| {}
    const outside = try tmp.dir.readFileAlloc(std.testing.io, "outside/private.txt", std.testing.allocator, .limited(100));
    defer std.testing.allocator.free(outside);
    try std.testing.expectEqualStrings("outside authority", outside);
}

const TestSave = struct {
    save: *Save,
    operation: enum { stage, publish, discard },
    cancelled: std.atomic.Value(bool) = .init(false),
    result: anyerror!void = error.NotStarted,
    fn run(self: *TestSave) void {
        self.result = switch (self.operation) {
            .stage => self.save.stage(&self.cancelled),
            .publish => self.save.publish(),
            .discard => self.save.discard(),
        };
    }
    fn execute(self: *TestSave) !void {
        const thread = try std.Thread.spawn(.{}, run, .{self});
        thread.join();
        return self.result;
    }
};

fn expectSaveContents(dir: std.Io.Dir, path: []const u8, expected: []const u8) !void {
    const actual = try dir.readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

fn expectSaveFiles(dir: std.Io.Dir, expected: usize) !void {
    var readable = try dir.openDir(std.testing.io, ".", .{ .iterate = true });
    defer readable.close(std.testing.io);
    var iterator = readable.iterate();
    var count: usize = 0;
    while (try iterator.next(std.testing.io)) |_| count += 1;
    try std.testing.expectEqual(expected, count);
}

test "Save As stages verified bytes without changing the selected target then atomically publishes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "source.txt", .data = "abc" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "最终结果.txt", .data = "keep me" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const selected = try std.fs.path.join(std.testing.allocator, &.{ root, "最终结果.txt" });
    defer std.testing.allocator.free(selected);
    var source: TestWork = .{ .request = .{ .workspace_root = root, .relative_path = "source.txt", .main_thread_id = std.Thread.getCurrentId() } };
    const expected = try source.execute();
    var save = try Save.init(std.testing.allocator, std.testing.io, source.request, selected, expected);
    defer save.deinit();
    var stage: TestSave = .{ .save = &save, .operation = .stage };
    try stage.execute();
    try expectSaveContents(tmp.dir, "最终结果.txt", "keep me");
    try expectSaveFiles(tmp.dir, 3);
    var publish: TestSave = .{ .save = &save, .operation = .publish };
    try publish.execute();
    try expectSaveContents(tmp.dir, "最终结果.txt", "abc");
    try expectSaveContents(tmp.dir, "source.txt", "abc");
    try expectSaveFiles(tmp.dir, 2);
}

test "Save As cancellation discard and wrong digest preserve existing bytes and remove staging" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "source.txt", .data = "abc" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "target.txt", .data = "original target" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const selected = try std.fs.path.join(std.testing.allocator, &.{ root, "target.txt" });
    defer std.testing.allocator.free(selected);
    var source: TestWork = .{ .request = .{ .workspace_root = root, .relative_path = "source.txt", .main_thread_id = std.Thread.getCurrentId() } };
    var expected = try source.execute();
    var save = try Save.init(std.testing.allocator, std.testing.io, source.request, selected, expected);
    defer save.deinit();
    var stage: TestSave = .{ .save = &save, .operation = .stage };
    stage.cancelled.store(true, .release);
    try std.testing.expectError(error.Cancelled, stage.execute());
    try expectSaveFiles(tmp.dir, 2);
    stage.cancelled.store(false, .release);
    try stage.execute();
    var discard: TestSave = .{ .save = &save, .operation = .discard };
    try discard.execute();
    try expectSaveContents(tmp.dir, "target.txt", "original target");
    try expectSaveFiles(tmp.dir, 2);
    expected.sha256[0] ^= 1;
    save.expected = expected;
    try std.testing.expectError(error.OutputChanged, stage.execute());
    try expectSaveContents(tmp.dir, "target.txt", "original target");
    try expectSaveFiles(tmp.dir, 2);
}

test "Save As refuses a target modified after selection or newly occupied before publication" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "source.txt", .data = "abc" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const selected = try std.fs.path.join(std.testing.allocator, &.{ root, "target.txt" });
    defer std.testing.allocator.free(selected);
    var source: TestWork = .{ .request = .{ .workspace_root = root, .relative_path = "source.txt", .main_thread_id = std.Thread.getCurrentId() } };
    const expected = try source.execute();
    var save = try Save.init(std.testing.allocator, std.testing.io, source.request, selected, expected);
    defer save.deinit();
    var stage: TestSave = .{ .save = &save, .operation = .stage };
    var publish: TestSave = .{ .save = &save, .operation = .publish };
    try stage.execute();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "target.txt", .data = "new occupant" });
    try std.testing.expectError(error.OutputDestinationChanged, publish.execute());
    try expectSaveContents(tmp.dir, "target.txt", "new occupant");
    try expectSaveFiles(tmp.dir, 2);
    try stage.execute();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "target.txt", .data = "modified during copy approval" });
    try std.testing.expectError(error.OutputDestinationChanged, publish.execute());
    try expectSaveContents(tmp.dir, "target.txt", "modified during copy approval");
    try expectSaveFiles(tmp.dir, 2);
}

test "Save As refuses source overwrite and main thread effects and releases allocation failures" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "source.txt", .data = "abc" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const selected = try std.fs.path.join(std.testing.allocator, &.{ root, "source.txt" });
    defer std.testing.allocator.free(selected);
    var source: TestWork = .{ .request = .{ .workspace_root = root, .relative_path = "source.txt", .main_thread_id = std.Thread.getCurrentId() } };
    const expected = try source.execute();
    var save = try Save.init(std.testing.allocator, std.testing.io, source.request, selected, expected);
    defer save.deinit();
    var stage: TestSave = .{ .save = &save, .operation = .stage };
    try std.testing.expectError(error.MainThreadFileEffect, save.stage(&stage.cancelled));
    try std.testing.expectError(error.SameOutputDestination, stage.execute());
    try expectSaveContents(tmp.dir, "source.txt", "abc");
    try expectSaveFiles(tmp.dir, 1);
    const Harness = struct {
        fn init(allocator: std.mem.Allocator, request: Request, path: []const u8, value: Inspection) !void {
            var candidate = try Save.init(allocator, std.testing.io, request, path, value);
            defer candidate.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Harness.init, .{ source.request, selected, expected });
}
