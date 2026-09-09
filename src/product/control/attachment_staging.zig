//! Bounded worker lane that turns native file paths into validated bytes.
const std = @import("std");
const attachment = @import("metawork_product_attachment");

pub const max_in_flight: usize = 4;
pub const worker_count: usize = 2;

pub const Rejection = enum {
    unsupported_type,
    file_too_large,
    too_many_files,
    staging_capacity,
    read_failed,
    file_changed,
    shutting_down,
};

pub const Input = struct {
    completion_id: u64,
    path_count: usize,
    paths: []const u8,
    limits: attachment.Limits,
};

pub const Completion = struct {
    completion_id: u64,
    rejection: ?Rejection,
    candidates: []const attachment.Candidate,
};

pub const Taken = struct { job: *anyopaque, completion: Completion };
pub const Notifier = struct {
    context: ?*anyopaque = null,
    wake_fn: *const fn (?*anyopaque) bool,
};
pub const ExecutorJob = struct {
    identity: *anyopaque,
    context: *anyopaque,
    execute_fn: *const fn (*anyopaque) void,
    cancel_fn: *const fn (*anyopaque) void,
};
pub const Executor = struct {
    context: *anyopaque,
    enqueue_fn: *const fn (*anyopaque, ExecutorJob) error{ ExecutorShuttingDown, QueueFull }!void,

    fn enqueue(self: Executor, job: ExecutorJob) error{ ExecutorShuttingDown, QueueFull }!void {
        return self.enqueue_fn(self.context, job);
    }
};
pub const Error = std.mem.Allocator.Error || error{ ShuttingDown, Capacity, InvalidInput };

const Job = struct {
    lane: *Lane,
    completion_id: u64,
    path_count: usize,
    paths: []u8,
    limits: attachment.Limits,
    rejection: ?Rejection = .read_failed,
    candidate_storage: ?[]attachment.Candidate = null,
    candidates: []attachment.Candidate = &.{},

    fn execute(context: *anyopaque) void {
        const self: *Job = @ptrCast(@alignCast(context));
        self.readBatch();
        self.lane.publish(self);
    }

    fn cancel(context: *anyopaque) void {
        const self: *Job = @ptrCast(@alignCast(context));
        self.rejection = .shutting_down;
        self.lane.publish(self);
    }

    fn readBatch(self: *Job) void {
        if (self.path_count == 0 or self.path_count > self.limits.max_files) {
            self.rejection = .too_many_files;
            return;
        }
        const candidates = self.lane.allocator.alloc(attachment.Candidate, self.path_count) catch {
            self.rejection = .staging_capacity;
            return;
        };
        self.candidate_storage = candidates;
        self.candidates = candidates[0..0];
        var split = std.mem.splitScalar(u8, self.paths, '\n');
        var total: usize = 0;
        while (split.next()) |path| {
            if (self.candidates.len == self.path_count or path.len == 0 or
                !std.fs.path.isAbsolute(path))
            {
                self.rejection = .read_failed;
                return;
            }
            const display_name = std.fs.path.basename(path);
            if (display_name.len == 0 or
                display_name.len > self.limits.max_display_name_bytes)
            {
                self.rejection = .unsupported_type;
                return;
            }
            var file = std.Io.Dir.openFileAbsolute(self.lane.io, path, .{
                .allow_directory = false,
                .follow_symlinks = false,
            }) catch {
                self.rejection = .read_failed;
                return;
            };
            defer file.close(self.lane.io);
            if (@import("builtin").os.tag == .windows) file.flags.nonblocking = true;
            const before = file.stat(self.lane.io) catch {
                self.rejection = .read_failed;
                return;
            };
            if (before.kind != .file or before.size == 0) {
                self.rejection = .unsupported_type;
                return;
            }
            if (before.size > self.limits.max_file_bytes or before.size > std.math.maxInt(usize)) {
                self.rejection = .file_too_large;
                return;
            }
            const size: usize = @intCast(before.size);
            if (size > self.limits.max_staged_bytes - total) {
                self.rejection = .staging_capacity;
                return;
            }
            const bytes = self.lane.allocator.alloc(u8, size) catch {
                self.rejection = .staging_capacity;
                return;
            };
            const read = file.readPositionalAll(self.lane.io, bytes, 0) catch {
                std.crypto.secureZero(u8, bytes);
                self.lane.allocator.free(bytes);
                self.rejection = .read_failed;
                return;
            };
            const after = file.stat(self.lane.io) catch {
                std.crypto.secureZero(u8, bytes);
                self.lane.allocator.free(bytes);
                self.rejection = .read_failed;
                return;
            };
            if (read != size or metadataChanged(before, after)) {
                std.crypto.secureZero(u8, bytes);
                self.lane.allocator.free(bytes);
                self.rejection = .file_changed;
                return;
            }
            const format = detectFormat(bytes);
            self.candidates.len += 1;
            self.candidates[self.candidates.len - 1] = .{
                .display_name = display_name,
                .format = format,
                .bytes = bytes,
            };
            total += size;
        }
        if (self.candidates.len != self.path_count) {
            self.rejection = .read_failed;
            return;
        }
        self.rejection = null;
    }

    fn deinit(self: *Job) void {
        for (self.candidates) |candidate| {
            const bytes = @constCast(candidate.bytes);
            std.crypto.secureZero(u8, bytes);
            self.lane.allocator.free(bytes);
        }
        if (self.candidate_storage) |storage| self.lane.allocator.free(storage);
        std.crypto.secureZero(u8, self.paths);
        self.lane.allocator.free(self.paths);
        self.lane.allocator.destroy(self);
    }
};

test "attachment staging lane classifies an ordered file batch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "picture.png",
        .data = "\x89PNG\r\n\x1a\nbody",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "notes.txt",
        .data = "plain text",
    });

    var root_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_storage);
    const paths = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}{c}picture.png\n{s}{c}notes.txt",
        .{ root_storage[0..root_len], std.fs.path.sep, root_storage[0..root_len], std.fs.path.sep },
    );
    defer std.testing.allocator.free(paths);

    const Wake = struct {
        count: usize = 0,
        fn notify(context: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.count += 1;
            return true;
        }
    };
    const TestExecutor = struct {
        fn enqueue(_: *anyopaque, job: ExecutorJob) error{ ExecutorShuttingDown, QueueFull }!void {
            job.execute_fn(job.context);
        }
    };
    var wake = Wake{};
    var executor_context: u8 = 0;
    const lane = try Lane.create(std.testing.io, std.testing.allocator, .{
        .context = &wake,
        .wake_fn = Wake.notify,
    }, .{
        .context = &executor_context,
        .enqueue_fn = TestExecutor.enqueue,
    });
    defer {
        lane.stopAdmission();
        lane.deinit();
    }
    try lane.begin(.{
        .completion_id = 7,
        .path_count = 2,
        .paths = paths,
        .limits = testLimits(),
    });
    try std.testing.expectEqual(@as(usize, 1), wake.count);
    const taken = lane.take() orelse return error.TestUnexpectedResult;
    defer lane.release(taken);
    try std.testing.expectEqual(@as(u64, 7), taken.completion.completion_id);
    try std.testing.expectEqual(@as(?Rejection, null), taken.completion.rejection);
    try std.testing.expectEqual(@as(usize, 2), taken.completion.candidates.len);
    try std.testing.expectEqual(@as(?attachment.Format, .png), taken.completion.candidates[0].format);
    try std.testing.expectEqualStrings("picture.png", taken.completion.candidates[0].display_name);
    try std.testing.expectEqual(@as(?attachment.Format, null), taken.completion.candidates[1].format);
    try std.testing.expectEqualStrings("notes.txt", taken.completion.candidates[1].display_name);
}

test "attachment staging lane rejects a mixed empty-file batch atomically" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "picture.webp",
        .data = "RIFF\x04\x00\x00\x00WEBPbody",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "notes.txt",
        .data = "",
    });
    var root_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_storage);
    const paths = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}{c}picture.webp\n{s}{c}notes.txt",
        .{ root_storage[0..root_len], std.fs.path.sep, root_storage[0..root_len], std.fs.path.sep },
    );
    defer std.testing.allocator.free(paths);

    const Wake = struct {
        fn notify(_: ?*anyopaque) bool {
            return true;
        }
    };
    const TestExecutor = struct {
        fn enqueue(_: *anyopaque, job: ExecutorJob) error{ ExecutorShuttingDown, QueueFull }!void {
            job.execute_fn(job.context);
        }
    };
    var context: u8 = 0;
    const lane = try Lane.create(std.testing.io, std.testing.allocator, .{
        .wake_fn = Wake.notify,
    }, .{
        .context = &context,
        .enqueue_fn = TestExecutor.enqueue,
    });
    defer {
        lane.stopAdmission();
        lane.deinit();
    }
    try lane.begin(.{
        .completion_id = 8,
        .path_count = 2,
        .paths = paths,
        .limits = testLimits(),
    });
    const taken = lane.take() orelse return error.TestUnexpectedResult;
    defer lane.release(taken);
    try std.testing.expectEqual(Rejection.unsupported_type, taken.completion.rejection.?);
}

fn testLimits() attachment.Limits {
    return .{
        .max_files = 4,
        .max_display_name_bytes = 128,
        .max_file_bytes = 1024,
        .max_staged_bytes = 4096,
    };
}

pub const Lane = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    notifier: Notifier,
    executor: Executor,
    mutex: std.Io.Mutex = .init,
    completions: [max_in_flight]?*Job = @splat(null),
    head: usize = 0,
    tail: usize = 0,
    completion_count: usize = 0,
    active_count: usize = 0,
    accepting: bool = true,

    pub fn create(io: std.Io, allocator: std.mem.Allocator, notifier: Notifier, executor: Executor) !*Lane {
        const self = try allocator.create(Lane);
        self.* = .{ .io = io, .allocator = allocator, .notifier = notifier, .executor = executor };
        return self;
    }

    pub fn begin(self: *Lane, input: Input) Error!void {
        if (input.paths.len == 0 or input.path_count == 0) return error.InvalidInput;
        self.lock();
        if (!self.accepting or self.active_count == max_in_flight) {
            const accepting = self.accepting;
            self.unlock();
            return if (accepting) error.Capacity else error.ShuttingDown;
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
        const paths = try self.allocator.dupe(u8, input.paths);
        errdefer self.allocator.free(paths);
        job.* = .{
            .lane = self,
            .completion_id = input.completion_id,
            .path_count = input.path_count,
            .paths = paths,
            .limits = input.limits,
        };
        self.executor.enqueue(.{
            .identity = job,
            .context = job,
            .execute_fn = Job.execute,
            .cancel_fn = Job.cancel,
        }) catch |err| return switch (err) {
            error.ExecutorShuttingDown => error.ShuttingDown,
            error.QueueFull => error.Capacity,
        };
    }

    pub fn stopAdmission(self: *Lane) void {
        self.lock();
        self.accepting = false;
        self.unlock();
    }

    pub fn take(self: *Lane) ?Taken {
        self.lock();
        if (self.completion_count == 0) {
            self.unlock();
            return null;
        }
        const job = self.completions[self.head].?;
        self.completions[self.head] = null;
        self.head = (self.head + 1) % self.completions.len;
        self.completion_count -= 1;
        self.unlock();
        return .{ .job = job, .completion = .{
            .completion_id = job.completion_id,
            .rejection = job.rejection,
            .candidates = job.candidates,
        } };
    }

    pub fn release(self: *Lane, taken: Taken) void {
        const job: *Job = @ptrCast(@alignCast(taken.job));
        job.deinit();
        self.lock();
        self.active_count -= 1;
        self.unlock();
    }

    pub fn deinit(self: *Lane) void {
        std.debug.assert(!self.accepting and self.active_count == 0 and self.completion_count == 0);
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    fn publish(self: *Lane, job: *Job) void {
        self.lock();
        self.completions[self.tail] = job;
        self.tail = (self.tail + 1) % self.completions.len;
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

const detectFormat = attachment.detectFormat;

test "attachment staging detects every published image signature and rejects PDF" {
    try std.testing.expectEqual(
        attachment.Format.png,
        detectFormat("\x89PNG\r\n\x1a\npayload").?,
    );
    try std.testing.expectEqual(
        attachment.Format.jpeg,
        detectFormat("\xff\xd8\xffpayload").?,
    );
    try std.testing.expectEqual(
        attachment.Format.webp,
        detectFormat("RIFFxxxxWEBPpayload").?,
    );
    try std.testing.expectEqual(@as(?attachment.Format, null), detectFormat("%PDF-1.7\npayload"));
    try std.testing.expectEqual(@as(?attachment.Format, null), detectFormat("GIF89a"));
}

fn metadataChanged(before: std.Io.File.Stat, after: std.Io.File.Stat) bool {
    return before.inode != after.inode or before.size != after.size or
        before.kind != after.kind or !std.meta.eql(before.mtime, after.mtime) or
        !std.meta.eql(before.ctime, after.ctime);
}
