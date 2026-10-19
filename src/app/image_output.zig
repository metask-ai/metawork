//! Application file effect bound to frozen Product Workspace authority.
//! Agent callbacks consume only the bounded output port on their worker thread.
const std = @import("std");
const builtin = @import("builtin");
const agent = @import("metawork_agent");
const workspace = @import("metawork_product_workspace");

const Result = agent.ImageGenerationOutputResult;
const Failure = agent.ImageGenerationOutputFailure;
const Cancellation = agent.ImageGenerationCancellation;
const Receipt = agent.ImageGenerationReceipt;
pub const directory_name = "generated-images";
const max_name_attempts = 4;

pub const Output = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    main_thread_id: std.Thread.Id,
    workspace_id: u64,
    workspace_epoch: u64,
    root: []u8,
    test_hook: if (builtin.is_test) ?Hook else void = if (builtin.is_test) null else {},

    /// Caller must have validated owning Task/Workspace authority at admission.
    /// No filesystem operation occurs while capturing this owned directory input.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, main_thread_id: std.Thread.Id, authority: workspace.TaskAuthority) !Output {
        if (authority.id == 0 or authority.epoch == 0 or authority.canonical_root.len == 0 or
            authority.canonical_root.len > std.Io.Dir.max_path_bytes or !std.fs.path.isAbsolute(authority.canonical_root) or
            !std.unicode.utf8ValidateSlice(authority.canonical_root)) return error.InvalidAuthority;
        for (authority.canonical_root) |byte| if (std.ascii.isControl(byte)) return error.InvalidAuthority;
        return .{
            .allocator = allocator,
            .io = io,
            .main_thread_id = main_thread_id,
            .workspace_id = authority.id,
            .workspace_epoch = authority.epoch,
            .root = try allocator.dupe(u8, authority.canonical_root),
        };
    }

    pub fn deinit(self: *Output) void {
        self.allocator.free(self.root);
        self.* = undefined;
    }

    /// This object must remain at a stable address until all callbacks quiesce.
    pub fn port(self: *Output) agent.ImageGenerationOutput {
        return .{ .context = self, .commit_fn = commit };
    }

    fn commit(context: *anyopaque, bytes: []const u8, cancellation: *const Cancellation) Result {
        const self: *Output = @ptrCast(@alignCast(context));
        if (std.Thread.getCurrentId() == self.main_thread_id or bytes.len == 0)
            return failed(.unavailable);
        if (cancellation.isRequested()) return failed(.cancelled);
        var attempt: Attempt = .{ .output = self, .bytes = bytes, .cancellation = cancellation };
        var events: [2]Event = undefined;
        var selection = std.Io.Select(Event).init(self.io, &events);
        selection.async(.operation, Attempt.run, .{&attempt});
        selection.async(.cancelled, waitCancellation, .{ cancellation, self.io });
        _ = selection.await() catch {
            selection.cancelDiscard();
            return attempt.result;
        };
        // Join before observing result or releasing any file/directory owner.
        // A committed receipt survives even if cancellation won the selection.
        selection.cancelDiscard();
        return attempt.result;
    }

    const Event = union(enum) { operation: void, cancelled: void };

    fn waitCancellation(cancellation: *const Cancellation, io: std.Io) void {
        // A transport's wake callback is optional and belongs to that effect.
        // File cancellation depends only on the shared token, not HTTP wiring.
        while (!cancellation.isRequested())
            std.Io.Timeout.sleep(.{ .duration = .{ .raw = .fromMilliseconds(5), .clock = .awake } }, io) catch return;
    }
    const Attempt = struct {
        output: *Output,
        bytes: []const u8,
        cancellation: *const Cancellation,
        result: Result = failed(.cancelled),

        fn run(self: *Attempt) void {
            self.result = self.output.write(self.bytes, self.cancellation);
        }
    };

    fn write(self: *Output, bytes: []const u8, cancellation: *const Cancellation) Result {
        if (cancellation.isRequested()) return failed(.cancelled);
        var root = openRoot(self.io, self.root) catch |err| return failed(code(err));
        defer root.close(self.io);
        const root_stat = root.stat(self.io) catch |err| return failed(code(err));
        root.createDir(self.io, directory_name, directoryPermissions()) catch |err| {
            if (err != error.PathAlreadyExists) return failed(code(err));
        };
        var directory = root.openDir(self.io, directory_name, .{ .access_sub_paths = true, .follow_symlinks = false }) catch |err| return failed(code(err));
        defer directory.close(self.io);
        const directory_stat = directory.stat(self.io) catch |err| return failed(code(err));
        if (directory_stat.kind != .directory) return failed(.unavailable);

        for (0..max_name_attempts) |_| {
            if (cancellation.isRequested()) return failed(.cancelled);
            var random: [16]u8 = undefined;
            std.Io.randomSecure(self.io, &random) catch |err| return failed(code(err));
            var name_buffer: [64]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buffer, "image-{x}.png", .{random}) catch unreachable;
            var path_buffer: [Receipt.max_path_bytes]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ directory_name, name }) catch unreachable;
            const receipt = Receipt.init(path, bytes.len) catch unreachable;
            self.hook(.before_create, directory, null, name, cancellation) catch |err| return failed(code(err));
            const file = directory.createFile(self.io, name, .{ .read = true, .exclusive = true, .permissions = filePermissions() }) catch |err| {
                if (err == error.PathAlreadyExists) continue;
                return failed(code(err));
            };
            const created = file.stat(self.io) catch {
                file.close(self.io);
                return incomplete(receipt.pathView());
            };
            if (created.kind != .file) {
                file.close(self.io);
                return incomplete(receipt.pathView());
            }
            self.writeCreated(directory, directory_stat, root_stat, file, created, bytes, name, cancellation) catch |err| {
                file.close(self.io);
                return self.cleanup(directory, name, created, receipt.pathView(), cancellation, err);
            };
            file.close(self.io);
            // Test-only observation cannot reverse an already committed file.
            self.hook(.committed, directory, null, name, cancellation) catch {};
            return .{ .saved = receipt };
        }
        return failed(.write_failed);
    }

    fn writeCreated(self: *Output, directory: std.Io.Dir, directory_stat: std.Io.File.Stat, root_stat: std.Io.File.Stat, file: std.Io.File, created: std.Io.File.Stat, bytes: []const u8, name: []const u8, cancellation: *const Cancellation) !void {
        try self.hook(.created, directory, file, name, cancellation);
        if (cancellation.isRequested()) return error.Cancelled;
        try file.writeStreamingAll(self.io, bytes);
        try self.hook(.written, directory, file, name, cancellation);
        if (cancellation.isRequested()) return error.Cancelled;
        try file.sync(self.io);
        const actual = try file.stat(self.io);
        const named = try directory.statFile(self.io, name, .{ .follow_symlinks = false });
        if (actual.kind != .file or actual.inode != created.inode or actual.size != bytes.len or
            named.kind != .file or named.inode != created.inode or named.size != bytes.len) return error.FileChanged;
        // An open handle can refer to a moved directory; verify the named chain
        // again before publishing a Workspace-relative receipt.
        var current_root = try openRoot(self.io, self.root);
        defer current_root.close(self.io);
        const current_root_stat = try current_root.stat(self.io);
        const current_directory = try current_root.statFile(self.io, directory_name, .{ .follow_symlinks = false });
        if (current_root_stat.inode != root_stat.inode or current_directory.kind != .directory or
            current_directory.inode != directory_stat.inode) return error.DirectoryChanged;
        if (cancellation.isRequested()) return error.Cancelled;
    }

    fn cleanup(self: *Output, directory: std.Io.Dir, name: []const u8, created: std.Io.File.Stat, path: []const u8, cancellation: *const Cancellation, failure: anyerror) Result {
        self.hook(.cleanup, directory, null, name, cancellation) catch return incomplete(path);
        const current = directory.statFile(self.io, name, .{ .follow_symlinks = false }) catch return incomplete(path);
        if (current.kind != .file or current.inode != created.inode) return incomplete(path);
        directory.deleteFile(self.io, name) catch return incomplete(path);
        return failed(code(failure));
    }

    fn hook(self: *Output, stage: Stage, directory: std.Io.Dir, file: ?std.Io.File, name: []const u8, cancellation: *const Cancellation) !void {
        if (builtin.is_test) if (self.test_hook) |injected|
            try injected.run_fn(injected.context, stage, directory, file, name, cancellation);
    }
};

// Fault injection is compiled out of product instances; there is one file path.
const Stage = enum { before_create, created, written, cleanup, committed };
const Hook = struct {
    context: *anyopaque,
    run_fn: *const fn (*anyopaque, Stage, std.Io.Dir, ?std.Io.File, []const u8, *const Cancellation) anyerror!void,
};

fn failed(reason: Failure.Code) Result {
    return .{ .failed = .{ .code = reason } };
}

fn incomplete(path: []const u8) Result {
    return .{ .failed = Failure.init(.cleanup_incomplete, path) catch unreachable };
}

fn code(err: anyerror) Failure.Code {
    return if (err == error.Canceled or err == error.Cancelled) .cancelled else .write_failed;
}

fn openRoot(io: std.Io, path: []const u8) !std.Io.Dir {
    var parts = std.fs.path.componentIterator(path);
    const volume = parts.root() orelse return error.InvalidAuthority;
    var current = try std.Io.Dir.openDirAbsolute(io, volume, .{ .access_sub_paths = true, .follow_symlinks = false });
    errdefer current.close(io);
    if ((try current.stat(io)).kind != .directory) return error.RestrictedPath;
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part.name, ".") or std.mem.eql(u8, part.name, "..")) return error.RestrictedPath;
        var child = try current.openDir(io, part.name, .{ .access_sub_paths = true, .follow_symlinks = false });
        errdefer child.close(io);
        if ((try child.stat(io)).kind != .directory) return error.RestrictedPath;
        current.close(io);
        current = child;
    }
    return current;
}

fn directoryPermissions() std.Io.Dir.Permissions {
    return if (builtin.os.tag == .windows) .default_dir else .fromMode(0o700);
}

fn filePermissions() std.Io.File.Permissions {
    return if (builtin.os.tag == .windows) .default_file else .fromMode(0o600);
}

pub const TestSupport = if (builtin.is_test) struct {
    pub const Barrier = struct {
        io: std.Io,
        entered: std.atomic.Value(bool) = .init(false),
        released: std.atomic.Value(u32) = .init(0),

        pub fn release(self: *Barrier) void {
            self.released.store(1, .release);
            self.io.futexWake(u32, &self.released.raw, std.math.maxInt(u32));
        }

        fn run(context: *anyopaque, stage: Stage, _: std.Io.Dir, _: ?std.Io.File, _: []const u8, _: *const Cancellation) !void {
            if (stage != .created) return;
            const self: *Barrier = @ptrCast(@alignCast(context));
            self.entered.store(true, .release);
            while (self.released.load(.acquire) == 0)
                try self.io.futexWait(u32, &self.released.raw, 0);
        }
    };

    pub fn blockBeforeWrite(output: *Output, barrier: *Barrier) void {
        output.test_hook = .{ .context = barrier, .run_fn = Barrier.run };
    }
} else struct {};

const TestWork = struct {
    output: *Output,
    cancellation: *const Cancellation,
    bytes: []const u8 = "fixture image bytes",
    result: Result = failed(.unavailable),

    fn run(self: *TestWork) void {
        const port = self.output.port();
        self.result = port.commit_fn(port.context, self.bytes, self.cancellation);
    }

    fn execute(self: *TestWork) !void {
        const thread = try std.Thread.spawn(.{}, run, .{self});
        thread.join();
    }
};

test "Workspace image output captures authority without effects and commits unique bytes on workers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var output = try Output.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId(), .{
        .id = 1,
        .epoch = 2,
        .kind = .manual,
        .canonical_root = root,
        .trust = .explicitly_trusted,
    });
    defer output.deinit();
    @memset(root, 0);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, directory_name, .{}));
    var cancellation: Cancellation = .{};
    const port = output.port();
    try std.testing.expectEqual(Failure.Code.unavailable, port.commit_fn(port.context, "bytes", &cancellation).failed.code);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, directory_name, .{}));
    var first: TestWork = .{ .output = &output, .cancellation = &cancellation };
    var second: TestWork = .{ .output = &output, .cancellation = &cancellation };
    const a = try std.Thread.spawn(.{}, TestWork.run, .{&first});
    const b = std.Thread.spawn(.{}, TestWork.run, .{&second}) catch |err| {
        a.join();
        return err;
    };
    a.join();
    b.join();
    for ([_]*TestWork{ &first, &second }) |work| {
        const receipt = work.result.saved;
        const bytes = try tmp.dir.readFileAlloc(std.testing.io, receipt.pathView(), std.testing.allocator, .limited(1024));
        defer std.testing.allocator.free(bytes);
        try std.testing.expectEqualSlices(u8, work.bytes, bytes);
        try std.testing.expectEqual(work.bytes.len, receipt.size_bytes);
    }
    try std.testing.expect(!std.mem.eql(u8, first.result.saved.pathView(), second.result.saved.pathView()));
    try std.testing.expectEqual(@as(u64, 1), output.workspace_id);
    try std.testing.expectEqual(@as(u64, 2), output.workspace_epoch);
}

test "Workspace image output conflicts partial writes replacement and late cancellation retain exact facts" {
    const Faults = struct {
        const Mode = enum { conflict, conflict_exhausted, partial, cleanup_failed, replaced, moved, directory_replaced, late_cancel };
        mode: Mode,
        root_dir: std.Io.Dir,
        name: [64]u8 = undefined,
        name_len: usize = 0,
        creates: usize = 0,
        rename_error: ?anyerror = null,

        fn run(context: *anyopaque, stage: Stage, directory: std.Io.Dir, file: ?std.Io.File, name: []const u8, cancellation: *const Cancellation) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (stage == .before_create) {
                self.creates += 1;
                if (self.creates == 1) {
                    @memcpy(self.name[0..name.len], name);
                    self.name_len = name.len;
                }
                if (self.mode == .conflict_exhausted or (self.mode == .conflict and self.creates == 1)) {
                    const old = try directory.createFile(std.testing.io, name, .{ .exclusive = true });
                    defer old.close(std.testing.io);
                    try old.writeStreamingAll(std.testing.io, "keep");
                }
            }
            if (stage == .created) switch (self.mode) {
                .partial, .cleanup_failed => {
                    try file.?.writeStreamingAll(std.testing.io, "part");
                    return error.InjectedWriteFailure;
                },
                .replaced, .moved => {
                    try directory.rename(name, directory, "moved.png", std.testing.io);
                    if (self.mode == .replaced) {
                        const replacement = try directory.createFile(std.testing.io, name, .{ .exclusive = true });
                        defer replacement.close(std.testing.io);
                        try replacement.writeStreamingAll(std.testing.io, "keep");
                    }
                    return error.InjectedWriteFailure;
                },
                else => {},
            };
            if (stage == .cleanup and self.mode == .cleanup_failed) return error.InjectedCleanupFailure;
            if (stage == .written and self.mode == .directory_replaced) {
                self.root_dir.rename(directory_name, self.root_dir, "old-images", std.testing.io) catch |err| {
                    self.rename_error = err;
                    return err;
                };
                try self.root_dir.createDir(std.testing.io, directory_name, .default_dir);
                var replacement_dir = try self.root_dir.openDir(std.testing.io, directory_name, .{});
                defer replacement_dir.close(std.testing.io);
                const replacement = try replacement_dir.createFile(std.testing.io, "keep.txt", .{ .exclusive = true });
                defer replacement.close(std.testing.io);
                try replacement.writeStreamingAll(std.testing.io, "keep");
            }
            if (stage == .committed and self.mode == .late_cancel) {
                @constCast(cancellation).request();
            }
        }
    };
    inline for (std.enums.values(Faults.Mode)) |mode| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        defer std.testing.allocator.free(root);
        var output = try Output.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId(), .{
            .id = 1,
            .epoch = 1,
            .kind = .automatic,
            .canonical_root = root,
            .trust = .explicitly_trusted,
        });
        defer output.deinit();
        var faults: Faults = .{ .mode = mode, .root_dir = tmp.dir };
        output.test_hook = .{ .context = &faults, .run_fn = Faults.run };
        var cancellation: Cancellation = .{};
        var work: TestWork = .{ .output = &output, .cancellation = &cancellation };
        try work.execute();
        var directory = try tmp.dir.openDir(std.testing.io, directory_name, .{ .iterate = true });
        defer directory.close(std.testing.io);
        switch (mode) {
            .conflict, .late_cancel => {
                const receipt = work.result.saved;
                const bytes = try tmp.dir.readFileAlloc(std.testing.io, receipt.pathView(), std.testing.allocator, .limited(1024));
                defer std.testing.allocator.free(bytes);
                try std.testing.expectEqualSlices(u8, work.bytes, bytes);
                if (mode == .conflict) {
                    const old = try directory.readFileAlloc(std.testing.io, faults.name[0..faults.name_len], std.testing.allocator, .limited(1024));
                    defer std.testing.allocator.free(old);
                    try std.testing.expectEqualStrings("keep", old);
                    try std.testing.expectEqual(@as(usize, 2), faults.creates);
                } else try std.testing.expect(cancellation.isRequested());
            },
            .partial => {
                try std.testing.expectEqual(Failure.Code.write_failed, work.result.failed.code);
                try std.testing.expect(work.result.failed.pathView() == null);
                try std.testing.expectError(error.FileNotFound, directory.statFile(std.testing.io, faults.name[0..faults.name_len], .{}));
            },
            .conflict_exhausted => {
                try std.testing.expectEqual(Failure.Code.write_failed, work.result.failed.code);
                try std.testing.expectEqual(@as(usize, max_name_attempts), faults.creates);
                var entries = directory.iterate();
                var files: usize = 0;
                while (try entries.next(std.testing.io)) |entry| {
                    const old = try directory.readFileAlloc(std.testing.io, entry.name, std.testing.allocator, .limited(1024));
                    defer std.testing.allocator.free(old);
                    try std.testing.expectEqualStrings("keep", old);
                    files += 1;
                }
                try std.testing.expectEqual(@as(usize, max_name_attempts), files);
            },
            .cleanup_failed => {
                try std.testing.expectEqual(Failure.Code.cleanup_incomplete, work.result.failed.code);
                try std.testing.expect(work.result.failed.pathView() != null);
                const partial = try directory.readFileAlloc(std.testing.io, faults.name[0..faults.name_len], std.testing.allocator, .limited(1024));
                defer std.testing.allocator.free(partial);
                try std.testing.expectEqualStrings("part", partial);
            },
            .replaced, .moved => {
                try std.testing.expectEqual(Failure.Code.cleanup_incomplete, work.result.failed.code);
                try std.testing.expect(work.result.failed.pathView() != null);
                _ = try directory.statFile(std.testing.io, "moved.png", .{});
                if (mode == .replaced) {
                    const replacement = try directory.readFileAlloc(std.testing.io, faults.name[0..faults.name_len], std.testing.allocator, .limited(1024));
                    defer std.testing.allocator.free(replacement);
                    try std.testing.expectEqualStrings("keep", replacement);
                }
            },
            .directory_replaced => {
                try std.testing.expectEqual(Failure.Code.write_failed, work.result.failed.code);
                if (faults.rename_error) |err| {
                    // Windows can prevent directory replacement while child
                    // handles are open. Assert that refusal, rather than claim
                    // this platform exercised the post-replacement branch.
                    try std.testing.expectEqual(error.AccessDenied, err);
                    var entries = directory.iterate();
                    try std.testing.expectEqual(@as(?std.Io.Dir.Entry, null), try entries.next(std.testing.io));
                } else {
                    const replacement = try directory.readFileAlloc(std.testing.io, "keep.txt", std.testing.allocator, .limited(1024));
                    defer std.testing.allocator.free(replacement);
                    try std.testing.expectEqualStrings("keep", replacement);
                    var old_directory = try tmp.dir.openDir(std.testing.io, "old-images", .{ .iterate = true });
                    defer old_directory.close(std.testing.io);
                    var entries = old_directory.iterate();
                    try std.testing.expectEqual(@as(?std.Io.Dir.Entry, null), try entries.next(std.testing.io));
                }
            },
        }
    }
}

test "Workspace file I/O cancellation joins and cleans its own uncommitted image" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var output = try Output.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId(), .{
        .id = 1,
        .epoch = 1,
        .kind = .manual,
        .canonical_root = root,
        .trust = .explicitly_trusted,
    });
    defer output.deinit();
    var barrier: TestSupport.Barrier = .{ .io = std.testing.io };
    TestSupport.blockBeforeWrite(&output, &barrier);
    var cancellation: Cancellation = .{};
    var work: TestWork = .{ .output = &output, .cancellation = &cancellation };
    const thread = try std.Thread.spawn(.{}, TestWork.run, .{&work});
    var joined = false;
    defer {
        barrier.release();
        if (!joined) thread.join();
    }
    const deadline = std.Io.Timestamp.now(std.testing.io, .awake).nanoseconds + 3 * std.time.ns_per_s;
    while (!barrier.entered.load(.acquire)) {
        if (std.Io.Timestamp.now(std.testing.io, .awake).nanoseconds >= deadline) return error.TestUnexpectedResult;
        try std.Io.Timeout.sleep(.{ .duration = .{ .raw = .fromMilliseconds(5), .clock = .awake } }, std.testing.io);
    }
    cancellation.request();
    // Joining is done before reading result; the barrier's wait is cancellable.
    thread.join();
    joined = true;
    try std.testing.expectEqual(Failure.Code.cancelled, work.result.failed.code);
    var directory = try tmp.dir.openDir(std.testing.io, directory_name, .{ .iterate = true });
    defer directory.close(std.testing.io);
    var entries = directory.iterate();
    try std.testing.expectEqual(@as(?std.Io.Dir.Entry, null), try entries.next(std.testing.io));
}
