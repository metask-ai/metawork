//! Bounded attachment I/O jobs. Product retains identities and quotas; workers
//! receive frozen files, one owned chunk, or opened source handles.
const std = @import("std");
const attachment = @import("metawork_product_attachment");
pub const max_in_flight: usize = 4;
pub const worker_count: usize = 2;
pub const Rejection = enum { unsupported_type, file_too_large, text_file_too_large, too_many_files, staging_capacity, read_failed, file_changed, invalid_transfer, stale_transfer, input_busy, cleanup_failed, shutting_down };
pub fn reject(err: anyerror) Rejection {
    return switch (err) {
        error.UnsupportedType, error.EmptyFile, error.InvalidDisplayName => .unsupported_type,
        error.FileTooLarge => .file_too_large,
        error.TextFileTooLarge => .text_file_too_large,
        error.TooManyFiles, error.EmptyBatch => .too_many_files,
        error.StagingCapacity, error.OutOfMemory, error.IdentityExhausted, error.Capacity => .staging_capacity,
        error.FileChanged => .file_changed,
        error.InvalidTransfer => .invalid_transfer,
        error.StaleTransfer => .stale_transfer,
        error.InputBusy => .input_busy,
        error.CleanupFailed, error.DeleteFailed => .cleanup_failed,
        error.ShuttingDown, error.ExecutorShuttingDown => .shutting_down,
        else => .read_failed,
    };
}
pub const Input = struct { completion_id: u64, path_count: usize, paths: []const u8, limits: attachment.Limits, file_store: *attachment.FileStore };
pub const Phase = enum { probed, copied, initialized, written, validated };
pub const Completion = struct { completion_id: u64, phase: Phase, rejection: ?Rejection, cancelled: bool, files: []const attachment.ReceiveFile };
pub const Taken = struct { job: *anyopaque, completion: Completion };
pub const Notifier = struct { context: ?*anyopaque = null, wake_fn: *const fn (?*anyopaque) bool };
pub const ExecutorJob = struct { identity: *anyopaque, context: *anyopaque, execute_fn: *const fn (*anyopaque) void, cancel_fn: *const fn (*anyopaque) void };
pub const Executor = struct {
    context: *anyopaque,
    enqueue_fn: *const fn (*anyopaque, ExecutorJob) error{ ExecutorShuttingDown, QueueFull }!void,
    fn enqueue(self: Executor, job: ExecutorJob) error{ ExecutorShuttingDown, QueueFull }!void {
        return self.enqueue_fn(self.context, job);
    }
};
pub const Error = std.mem.Allocator.Error || error{ ShuttingDown, Capacity, InvalidInput, TooManyFiles };
const Job = struct {
    lane: *Lane,
    completion_id: u64,
    file_store: *attachment.FileStore,
    phase: Phase = .probed,
    cancelled: std.atomic.Value(bool) = .init(false),
    rejection: ?Rejection = null,
    paths: []u8 = &.{},
    metadata: []attachment.ReceiveFile = &.{},
    sources: []attachment.store.Source = &.{},
    source_count: usize = 0,
    targets: []attachment.store.File = &.{},
    chunk: []u8 = &.{},
    offset: usize = 0,
    limits: attachment.Limits = undefined,
    fn execute(context: *anyopaque) void {
        const self: *Job = @ptrCast(@alignCast(context));
        self.perform() catch |err| {
            if (err != error.Cancelled) self.rejection = reject(err);
        };
        // The completion boundary proves no worker uses these handles/buffers.
        if (self.phase != .probed or self.rejection != null or self.cancelled.load(.acquire)) self.closeSources();
        self.lane.publish(self);
    }
    fn cancel(context: *anyopaque) void {
        const self: *Job = @ptrCast(@alignCast(context));
        self.cancelled.store(true, .release);
        self.closeSources();
        self.lane.publish(self);
    }
    fn check(self: *Job) error{Cancelled}!void {
        if (self.cancelled.load(.acquire)) return error.Cancelled;
    }
    fn perform(self: *Job) !void {
        try self.check();
        switch (self.phase) {
            .probed => {
                var split = std.mem.splitScalar(u8, self.paths, '\n');
                for (self.metadata, 0..) |*meta, index| {
                    try self.check();
                    const path = split.next() orelse return error.InvalidInput;
                    if (path.len == 0 or !std.fs.path.isAbsolute(path)) return error.ReadFailed;
                    const source = try self.file_store.openSource(path);
                    self.sources[index] = source;
                    self.source_count += 1;
                    meta.* = .{ .display_name = std.fs.path.basename(path), .size_bytes = std.math.cast(usize, source.before.size) orelse return error.FileTooLarge };
                }
                if (split.next() != null) return error.InvalidInput;
            },
            .copied => {
                for (self.targets, self.sources) |file, source| {
                    try self.check();
                    try self.file_store.create(file);
                    try self.file_store.copySource(source, file, &self.cancelled);
                }
            },
            .initialized => for (self.targets) |file| {
                try self.check();
                try self.file_store.create(file);
            },
            .written => {
                try self.file_store.append(self.targets[0], self.offset, self.chunk);
            },
            .validated => for (self.targets) |file| {
                try self.check();
                try self.file_store.finish(file);
            },
        }
        try self.check();
    }
    fn closeSources(self: *Job) void {
        for (self.sources[0..self.source_count]) |source| source.close(self.file_store.io);
        self.source_count = 0;
    }
    fn deinit(self: *Job) void {
        self.closeSources();
        for ([_][]u8{ self.paths, self.chunk }) |bytes| {
            std.crypto.secureZero(u8, bytes);
            self.lane.allocator.free(bytes);
        }
        self.lane.allocator.free(self.metadata);
        self.lane.allocator.free(self.sources);
        self.lane.allocator.free(self.targets);
        self.lane.allocator.destroy(self);
    }
};
pub const Lane = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    notifier: Notifier,
    executor: Executor,
    mutex: std.Io.Mutex = .init,
    jobs: [max_in_flight]?*Job = @splat(null),
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
    fn allocate(self: *Lane, id: u64, store: *attachment.FileStore) Error!*Job {
        self.lock();
        defer self.unlock();
        if (!self.accepting) return error.ShuttingDown;
        if (self.active_count == max_in_flight) return error.Capacity;
        const job = try self.allocator.create(Job);
        job.* = .{ .lane = self, .completion_id = id, .file_store = store };
        for (&self.jobs) |*slot| if (slot.* == null) {
            slot.* = job;
            break;
        };
        self.active_count += 1;
        return job;
    }
    fn enqueue(self: *Lane, job: *Job) Error!void {
        self.executor.enqueue(.{ .identity = job, .context = job, .execute_fn = Job.execute, .cancel_fn = Job.cancel }) catch |err| return switch (err) {
            error.ExecutorShuttingDown => error.ShuttingDown,
            error.QueueFull => error.Capacity,
        };
    }
    pub fn begin(self: *Lane, input: Input) Error!void {
        if (input.path_count > input.limits.max_files) return error.TooManyFiles;
        if (input.path_count == 0 or input.paths.len == 0) return error.InvalidInput;
        const job = try self.allocate(input.completion_id, input.file_store);
        errdefer self.release(.{ .job = job, .completion = undefined });
        job.paths = try self.allocator.dupe(u8, input.paths);
        job.metadata = try self.allocator.alloc(attachment.ReceiveFile, input.path_count);
        job.sources = try self.allocator.alloc(attachment.store.Source, input.path_count);
        job.limits = input.limits;
        try self.enqueue(job);
    }
    /// Transfer the probed job and opened source handles into a copy job. The
    /// caller must not release Taken after this succeeds.
    pub fn continueCopy(self: *Lane, taken: Taken, files: []const attachment.store.File) Error!void {
        const job: *Job = @ptrCast(@alignCast(taken.job));
        if (job.phase != .probed or files.len != job.source_count) return error.InvalidInput;
        job.targets = try self.allocator.dupe(attachment.store.File, files);
        job.phase = .copied;
        try self.enqueue(job);
    }
    pub fn continueValidation(self: *Lane, taken: Taken) Error!void {
        const job: *Job = @ptrCast(@alignCast(taken.job));
        if (job.phase != .copied) return error.InvalidInput;
        job.phase = .validated;
        try self.enqueue(job);
    }
    pub fn beginFiles(self: *Lane, id: u64, store: *attachment.FileStore, phase: Phase, files: []const attachment.store.File, offset: usize, bytes: []const u8) Error!void {
        if (phase == .probed or phase == .copied or files.len == 0 or bytes.len > 128 * 1024 or (phase == .written and (files.len != 1 or bytes.len == 0))) return error.InvalidInput;
        const job = try self.allocate(id, store);
        errdefer self.release(.{ .job = job, .completion = undefined });
        job.phase = phase;
        job.targets = try self.allocator.dupe(attachment.store.File, files);
        job.offset = offset;
        job.chunk = try self.allocator.dupe(u8, bytes);
        try self.enqueue(job);
    }
    pub fn cancel(self: *Lane, id: u64) void {
        self.lock();
        defer self.unlock();
        for (self.jobs) |slot| if (slot) |job| {
            if (job.completion_id == id) job.cancelled.store(true, .release);
        };
    }
    pub fn stopAdmission(self: *Lane) void {
        self.lock();
        defer self.unlock();
        self.accepting = false;
        for (self.jobs) |slot| if (slot) |job| {
            job.cancelled.store(true, .release);
        };
    }
    pub fn take(self: *Lane) ?Taken {
        self.lock();
        defer self.unlock();
        if (self.completion_count == 0) return null;
        const job = self.completions[self.head].?;
        self.completions[self.head] = null;
        self.head = (self.head + 1) % max_in_flight;
        self.completion_count -= 1;
        return .{ .job = job, .completion = .{ .completion_id = job.completion_id, .phase = job.phase, .rejection = job.rejection, .cancelled = job.cancelled.load(.acquire), .files = job.metadata } };
    }
    pub fn release(self: *Lane, taken: Taken) void {
        const job: *Job = @ptrCast(@alignCast(taken.job));
        self.lock();
        for (&self.jobs) |*slot| if (slot.* == job) {
            slot.* = null;
            break;
        };
        self.active_count -= 1;
        self.unlock();
        job.deinit();
    }
    pub fn deinit(self: *Lane) void {
        std.debug.assert(!self.accepting and self.active_count == 0 and self.completion_count == 0);
        self.allocator.destroy(self);
    }
    fn publish(self: *Lane, job: *Job) void {
        self.lock();
        self.completions[self.tail] = job;
        self.tail = (self.tail + 1) % max_in_flight;
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

test "path probe reserves before copy and cancellation joins the writer" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "source.zip", .data = "PK\x03\x04\x00\xffbinary" });
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &root);
    var store = try attachment.FileStore.init(std.testing.io, std.testing.allocator, root[0..len]);
    defer store.deinit();
    const path = try std.fs.path.join(std.testing.allocator, &.{ root[0..len], "source.zip" });
    defer std.testing.allocator.free(path);
    const Queue = struct {
        pending: ?ExecutorJob = null,
        fn enqueue(context: *anyopaque, job: ExecutorJob) error{ ExecutorShuttingDown, QueueFull }!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            std.debug.assert(self.pending == null);
            self.pending = job;
        }
        fn run(self: *@This()) void {
            const job = self.pending.?;
            self.pending = null;
            job.execute_fn(job.context);
        }
        fn wake(_: ?*anyopaque) bool {
            return true;
        }
    };
    var queue = Queue{};
    const lane = try Lane.create(std.testing.io, std.testing.allocator, .{ .wake_fn = Queue.wake }, .{ .context = &queue, .enqueue_fn = Queue.enqueue });
    defer {
        lane.stopAdmission();
        lane.deinit();
    }
    const limits: attachment.Limits = .{ .max_files = 2, .max_display_name_bytes = 64, .max_file_bytes = 64, .max_staged_bytes = 128 };
    try std.testing.expectError(error.TooManyFiles, lane.begin(.{ .completion_id = 1, .path_count = limits.max_files + 1, .paths = path, .limits = limits, .file_store = &store }));
    try std.testing.expectError(error.InvalidInput, lane.begin(.{ .completion_id = 1, .path_count = 0, .paths = path, .limits = limits, .file_store = &store }));
    try std.testing.expectError(error.InvalidInput, lane.begin(.{ .completion_id = 1, .path_count = 1, .paths = &.{}, .limits = limits, .file_store = &store }));
    try std.testing.expectEqual(@as(usize, 0), lane.active_count);
    try std.testing.expect(queue.pending == null);
    var runtime = try attachment.Runtime.init(std.testing.allocator, limits, &store, .{}, null);
    defer runtime.deinit();
    const id = try runtime.beginPreparing();
    try lane.begin(.{ .completion_id = 1, .path_count = 1, .paths = path, .limits = limits, .file_store = &store });
    queue.run();
    const probe = lane.take().?;
    try std.testing.expectEqual(Phase.probed, probe.completion.phase);
    try std.testing.expectEqual(@as(?Rejection, null), probe.completion.rejection);
    try std.testing.expectError(error.FileNotFound, store.root.openDir(std.testing.io, "0", .{}));
    try runtime.reservePrepared(id, probe.completion.files);
    var targets: [2]attachment.store.File = undefined;
    const files = try runtime.writeFiles(id, &targets);
    try lane.continueCopy(probe, files);
    lane.cancel(1);
    queue.run();
    const copied = lane.take().?;
    try std.testing.expect(copied.completion.cancelled);
    lane.release(copied);
    try std.testing.expect(try runtime.cancelReceiveChecked(id));
    try std.testing.expectEqual(@as(usize, 0), runtime.used_bytes);
    try std.testing.expectEqual(@as(usize, 0), lane.active_count);
    const next_id = try runtime.beginPreparing();
    try lane.begin(.{ .completion_id = 2, .path_count = 1, .paths = path, .limits = limits, .file_store = &store });
    queue.run();
    const next_probe = lane.take().?;
    try runtime.reservePrepared(next_id, next_probe.completion.files);
    const next_files = try runtime.writeFiles(next_id, &targets);
    try lane.continueCopy(next_probe, next_files);
    queue.run();
    const next_copy = lane.take().?;
    try std.testing.expectEqual(@as(?Rejection, null), next_copy.completion.rejection);
    try runtime.acknowledgeCopied(next_id);
    try lane.continueValidation(next_copy);
    queue.run();
    const validated = lane.take().?;
    try std.testing.expectEqual(@as(?Rejection, null), validated.completion.rejection);
    lane.release(validated);
    var output: [2]attachment.Descriptor = undefined;
    const ready = try runtime.finishValidated(next_id, &output);
    const original = try store.readAlloc(std.testing.allocator, runtime.slots[0].?.file);
    defer std.testing.allocator.free(original);
    try std.testing.expectEqualStrings("PK\x03\x04\x00\xffbinary", original);
    try std.testing.expect(runtime.release(ready[0].id));
}
