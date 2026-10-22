//! Worker-only inspection of explicitly selected Workspace output files.
//! This proves bytes at a locator; it does not register a Product Output or
//! infer delivery from ordinary file references or tool text.
const std = @import("std");
const builtin = @import("builtin");

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
        if (copy) |value| try value.destination.writeStreamingAll(io, buffer[0..count]);
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

fn openRoot(io: std.Io, path: []const u8) !std.Io.Dir {
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
