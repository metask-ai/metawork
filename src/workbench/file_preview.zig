const std = @import("std");

pub const max_in_flight: usize = 8;
pub const worker_count: usize = 2;

pub const State = enum {
    ready,
    missing,
    restricted,
    unsupported,
    changing,
    failed,
};

pub const Input = struct {
    completion_id: u64,
    task_id: u64,
    run_id: u64,
    workspace_id: u64,
    workspace_epoch: u64,
    reference_id: []const u8,
    workspace_root: []const u8,
    relative_path: []const u8,
    max_bytes: usize,
    max_lines: usize,
    max_line_bytes: usize,
};

pub const Completion = struct {
    completion_id: u64,
    task_id: u64,
    run_id: u64,
    workspace_id: u64,
    workspace_epoch: u64,
    reference_id: []const u8,
    workspace_root: []const u8,
    state: State,
    content: []const u8,
    truncated: bool,
};

pub const Taken = struct {
    job: *anyopaque,
    completion: Completion,
};

pub const Notifier = struct {
    context: ?*anyopaque = null,
    wake_fn: *const fn (?*anyopaque) bool,
};

pub const Error = error{
    ShuttingDown,
    Capacity,
} || std.mem.Allocator.Error;

const Job = struct {
    lane: *Lane,
    completion_id: u64,
    task_id: u64,
    run_id: u64,
    workspace_id: u64,
    workspace_epoch: u64,
    reference_id: []u8,
    workspace_root: []u8,
    relative_path: []u8,
    max_bytes: usize,
    max_lines: usize,
    max_line_bytes: usize,
    state: State = .failed,
    buffer: []u8 = &.{},
    content: []const u8 = &.{},
    truncated: bool = false,

    fn execute(context: *anyopaque) void {
        const self: *Job = @ptrCast(@alignCast(context));
        self.readWithRetry();
        self.lane.publish(self);
    }

    fn cancel(context: *anyopaque) void {
        const self: *Job = @ptrCast(@alignCast(context));
        self.state = .failed;
        self.lane.publish(self);
    }

    fn readWithRetry(self: *Job) void {
        var attempt: u8 = 0;
        while (attempt < 2) : (attempt += 1) {
            const outcome = self.readOnce();
            switch (outcome) {
                .completed => return,
                .changed => {
                    self.clearContent();
                    if (attempt == 1) {
                        self.state = .changing;
                        return;
                    }
                },
            }
        }
        unreachable;
    }

    const ReadOutcome = enum { completed, changed };

    fn readOnce(self: *Job) ReadOutcome {
        var root = std.Io.Dir.openDirAbsolute(self.lane.io, self.workspace_root, .{
            .access_sub_paths = true,
            .follow_symlinks = false,
        }) catch {
            self.state = .restricted;
            return .completed;
        };
        defer root.close(self.lane.io);
        var file = root.openFile(self.lane.io, self.relative_path, .{
            .allow_directory = false,
            .follow_symlinks = false,
            .resolve_beneath = true,
        }) catch |err| {
            self.state = switch (err) {
                error.FileNotFound, error.NotDir => .missing,
                else => .restricted,
            };
            return .completed;
        };
        defer file.close(self.lane.io);
        if (@import("builtin").os.tag == .windows) file.flags.nonblocking = true;

        const before = file.stat(self.lane.io) catch {
            self.state = .failed;
            return .completed;
        };
        if (before.kind != .file) {
            self.state = .unsupported;
            return .completed;
        }
        const wanted: usize = @intCast(@min(before.size, self.max_bytes));
        if (wanted == 0) {
            const after = file.stat(self.lane.io) catch {
                self.state = .failed;
                return .completed;
            };
            if (metadataChanged(before, after)) return .changed;
            self.state = .ready;
            self.content = &.{};
            self.truncated = before.size > self.max_bytes;
            return .completed;
        }
        const bytes = self.lane.allocator.alloc(u8, wanted) catch {
            self.state = .failed;
            return .completed;
        };
        self.buffer = bytes;
        self.content = bytes;
        const read = file.readPositionalAll(self.lane.io, bytes, 0) catch {
            self.clearContent();
            self.state = .failed;
            return .completed;
        };
        const after = file.stat(self.lane.io) catch {
            self.clearContent();
            self.state = .failed;
            return .completed;
        };
        if (read != wanted or metadataChanged(before, after)) return .changed;

        var visible = trimIncompleteUtf8Tail(bytes);
        if (!std.unicode.utf8ValidateSlice(visible) or containsUnsafeControl(visible)) {
            self.clearContent();
            self.state = .unsupported;
            return .completed;
        }
        const cutoff = boundedCutoff(visible, self.max_lines, self.max_line_bytes);
        if (cutoff < visible.len) visible = trimIncompleteUtf8Tail(visible[0..cutoff]);
        self.content = bytes[0..visible.len];
        self.truncated = before.size > self.max_bytes or visible.len < wanted;
        self.state = .ready;
        return .completed;
    }

    fn clearContent(self: *Job) void {
        if (self.buffer.len != 0) {
            std.crypto.secureZero(u8, self.buffer);
            self.lane.allocator.free(self.buffer);
        }
        self.buffer = &.{};
        self.content = &.{};
        self.truncated = false;
    }

    fn deinit(self: *Job) void {
        self.clearContent();
        std.crypto.secureZero(u8, self.relative_path);
        std.crypto.secureZero(u8, self.workspace_root);
        std.crypto.secureZero(u8, self.reference_id);
        self.lane.allocator.free(self.relative_path);
        self.lane.allocator.free(self.workspace_root);
        self.lane.allocator.free(self.reference_id);
        self.lane.allocator.destroy(self);
    }
};

pub const Lane = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    notifier: Notifier,
    executor: *Executor,
    mutex: std.Io.Mutex = .init,
    completions: [max_in_flight]?*Job = @splat(null),
    completion_head: usize = 0,
    completion_tail: usize = 0,
    completion_count: usize = 0,
    active_count: usize = 0,
    accepting: bool = true,
    shutdown: bool = false,

    const Executor = @import("workbench_executor").Executor;

    pub fn create(
        io: std.Io,
        allocator: std.mem.Allocator,
        notifier: Notifier,
    ) (std.mem.Allocator.Error || std.Thread.SpawnError)!*Lane {
        const self = try allocator.create(Lane);
        errdefer allocator.destroy(self);
        const executor = @import("workbench_executor").Executor.create(io, allocator, .{
            .worker_count = worker_count,
            .queue_capacity = max_in_flight,
        }) catch |err| switch (err) {
            error.InvalidLimits => unreachable,
            else => return @errorCast(err),
        };
        self.* = .{
            .io = io,
            .allocator = allocator,
            .notifier = notifier,
            .executor = executor,
        };
        return self;
    }

    pub fn begin(self: *Lane, input: Input) Error!void {
        self.lock();
        if (!self.accepting) {
            self.unlock();
            return error.ShuttingDown;
        }
        if (self.active_count == max_in_flight) {
            self.unlock();
            return error.Capacity;
        }
        self.active_count += 1;
        self.unlock();
        errdefer {
            self.lock();
            self.active_count -= 1;
            self.unlock();
        }

        const job = try self.allocator.create(Job);
        errdefer self.allocator.destroy(job);
        const reference_id = try self.allocator.dupe(u8, input.reference_id);
        errdefer self.allocator.free(reference_id);
        const workspace_root = try self.allocator.dupe(u8, input.workspace_root);
        errdefer self.allocator.free(workspace_root);
        const relative_path = try self.allocator.dupe(u8, input.relative_path);
        errdefer self.allocator.free(relative_path);
        job.* = .{
            .lane = self,
            .completion_id = input.completion_id,
            .task_id = input.task_id,
            .run_id = input.run_id,
            .workspace_id = input.workspace_id,
            .workspace_epoch = input.workspace_epoch,
            .reference_id = reference_id,
            .workspace_root = workspace_root,
            .relative_path = relative_path,
            .max_bytes = input.max_bytes,
            .max_lines = input.max_lines,
            .max_line_bytes = input.max_line_bytes,
        };
        self.executor.enqueue(.{
            .identity = job,
            .context = job,
            .execute_fn = Job.execute,
            .cancel_fn = Job.cancel,
        }) catch |err| switch (err) {
            error.ExecutorShuttingDown => return error.ShuttingDown,
            error.QueueFull => return error.Capacity,
        };
    }

    pub fn stopAdmission(self: *Lane) void {
        self.lock();
        self.accepting = false;
        self.unlock();
    }

    pub fn shutdownExecutor(self: *Lane) void {
        if (self.shutdown) return;
        self.stopAdmission();
        self.executor.shutdown();
        self.shutdown = true;
    }

    pub fn deinit(self: *Lane) void {
        self.shutdownExecutor();
        std.debug.assert(self.active_count == 0);
        std.debug.assert(self.completion_count == 0);
        self.executor.deinit();
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    pub fn take(self: *Lane) ?Taken {
        self.lock();
        if (self.completion_count == 0) {
            self.unlock();
            return null;
        }
        const job = self.completions[self.completion_head].?;
        self.completions[self.completion_head] = null;
        self.completion_head = (self.completion_head + 1) % self.completions.len;
        self.completion_count -= 1;
        self.unlock();
        return .{
            .job = job,
            .completion = .{
                .completion_id = job.completion_id,
                .task_id = job.task_id,
                .run_id = job.run_id,
                .workspace_id = job.workspace_id,
                .workspace_epoch = job.workspace_epoch,
                .reference_id = job.reference_id,
                .workspace_root = job.workspace_root,
                .state = job.state,
                .content = job.content,
                .truncated = job.truncated,
            },
        };
    }

    pub fn release(self: *Lane, taken: Taken) void {
        const job: *Job = @ptrCast(@alignCast(taken.job));
        job.deinit();
        self.lock();
        std.debug.assert(self.active_count != 0);
        self.active_count -= 1;
        self.unlock();
    }

    fn publish(self: *Lane, job: *Job) void {
        self.lock();
        std.debug.assert(self.completion_count < self.completions.len);
        self.completions[self.completion_tail] = job;
        self.completion_tail = (self.completion_tail + 1) % self.completions.len;
        self.completion_count += 1;
        self.unlock();
        _ = self.notifier.wake_fn(self.notifier.context);
    }

    fn lock(self: *Lane) void {
        self.mutex.lockUncancelable(self.io);
    }

    fn unlock(self: *Lane) void {
        self.mutex.unlock(self.io);
    }
};

fn metadataChanged(before: std.Io.File.Stat, after: std.Io.File.Stat) bool {
    return before.inode != after.inode or
        before.size != after.size or
        before.kind != after.kind or
        !std.meta.eql(before.mtime, after.mtime) or
        !std.meta.eql(before.ctime, after.ctime);
}

fn containsUnsafeControl(bytes: []const u8) bool {
    for (bytes) |byte| switch (byte) {
        0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => return true,
        else => {},
    };
    return false;
}

fn boundedCutoff(bytes: []const u8, max_lines: usize, max_line_bytes: usize) usize {
    var lines: usize = 1;
    var line_bytes: usize = 0;
    for (bytes, 0..) |byte, index| {
        if (byte == '\n') {
            lines += 1;
            line_bytes = 0;
            if (lines > max_lines) return index;
        } else {
            line_bytes += 1;
            if (line_bytes > max_line_bytes) return index;
        }
    }
    return bytes.len;
}

fn trimIncompleteUtf8Tail(bytes: []u8) []u8 {
    if (std.unicode.utf8ValidateSlice(bytes) or bytes.len == 0) return bytes;
    var suffix_start = bytes.len;
    var continuation_count: usize = 0;
    while (suffix_start > 0 and continuation_count < 3 and
        (bytes[suffix_start - 1] & 0xc0) == 0x80)
    {
        suffix_start -= 1;
        continuation_count += 1;
    }
    if (suffix_start == 0) return bytes;
    const lead_index = suffix_start - 1;
    const lead = bytes[lead_index];
    if (lead < 0xc2 or lead > 0xf4) return bytes;
    const sequence_len = std.unicode.utf8ByteSequenceLength(lead) catch return bytes;
    if (bytes.len - lead_index < sequence_len) return bytes[0..lead_index];
    return bytes;
}

test "file preview lane classifies bounded text empty and unsafe files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "text.txt",
        .data = "hello world",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "unsafe.txt",
        .data = "bad\x01data",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "empty.txt",
        .data = "",
    });
    var root_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_storage);

    const Wake = struct {
        count: std.atomic.Value(usize) = .init(0),

        fn notify(context: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            _ = self.count.fetchAdd(1, .release);
            return true;
        }
    };
    var wake = Wake{};
    const lane = try Lane.create(std.testing.io, std.testing.allocator, .{
        .context = &wake,
        .wake_fn = Wake.notify,
    });
    defer lane.deinit();

    inline for (.{
        .{ @as(u64, 1), "text.txt", @as(usize, 5) },
        .{ @as(u64, 2), "unsafe.txt", @as(usize, 64) },
        .{ @as(u64, 3), "empty.txt", @as(usize, 64) },
    }) |entry| try lane.begin(.{
        .completion_id = entry[0],
        .task_id = 11,
        .run_id = 12,
        .workspace_id = 13,
        .workspace_epoch = 14,
        .reference_id = "ref",
        .workspace_root = root_storage[0..root_len],
        .relative_path = entry[1],
        .max_bytes = entry[2],
        .max_lines = 100,
        .max_line_bytes = 100,
    });

    while (wake.count.load(.acquire) != 3) std.Thread.yield() catch {};
    var seen: [3]bool = @splat(false);
    while (lane.take()) |taken| {
        defer lane.release(taken);
        switch (taken.completion.completion_id) {
            1 => {
                try std.testing.expectEqual(State.ready, taken.completion.state);
                try std.testing.expectEqualStrings("hello", taken.completion.content);
                try std.testing.expect(taken.completion.truncated);
                seen[0] = true;
            },
            2 => {
                try std.testing.expectEqual(State.unsupported, taken.completion.state);
                try std.testing.expectEqualStrings("", taken.completion.content);
                try std.testing.expect(!taken.completion.truncated);
                seen[1] = true;
            },
            3 => {
                try std.testing.expectEqual(State.ready, taken.completion.state);
                try std.testing.expectEqualStrings("", taken.completion.content);
                try std.testing.expect(!taken.completion.truncated);
                seen[2] = true;
            },
            else => return error.TestUnexpectedResult,
        }
    }
    try std.testing.expectEqual([3]bool{ true, true, true }, seen);
    lane.shutdownExecutor();
}

test "file preview text bounds stop before an over-limit line or codepoint" {
    try std.testing.expectEqual(@as(usize, 3), boundedCutoff("abcde", 10, 3));
    try std.testing.expectEqual(@as(usize, 3), boundedCutoff("a\nb\nc", 2, 10));
    var incomplete = [_]u8{ 'a', 0xe4, 0xbd };
    try std.testing.expectEqualStrings("a", trimIncompleteUtf8Tail(&incomplete));
    try std.testing.expect(!containsUnsafeControl("a\tb\nc\r"));
    try std.testing.expect(containsUnsafeControl("a\x00b"));
}
