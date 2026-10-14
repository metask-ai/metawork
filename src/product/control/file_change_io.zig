const std = @import("std");
const store = @import("product_task_file_change_store");

pub const max_in_flight: usize = 16;

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

pub const Notifier = struct {
    context: ?*anyopaque = null,
    wake_fn: *const fn (?*anyopaque) bool,
};

pub const Error = error{ ShuttingDown, Capacity } || std.mem.Allocator.Error;

pub const WriteInput = struct {
    task_id: u64,
    run_generation: u64,
    change_order: u64,
    /// Ownership transfers only when beginWrite succeeds.
    content: []u8,
    redacted: bool,
    max_bytes: usize,
};

pub const ReadInput = struct {
    completion_id: u64,
    identity: store.Identity,
    max_bytes: usize,
    complete: bool,
    redacted: bool,
};

pub const WriteCompletion = struct {
    task_id: u64,
    run_generation: u64,
    change_order: u64,
    identity: ?store.Identity,
    redacted: bool,
};

pub const ReadState = enum { ready, missing, corrupt, failed };

pub const ReadCompletion = struct {
    completion_id: u64,
    identity: store.Identity,
    state: ReadState,
    /// Mutable lane-owned read buffer. The main-thread consumer may scrub it
    /// in place before the synchronous sink call; `release` then secure-zeros
    /// and frees it.
    content: []u8,
    complete: bool,
    redacted: bool,
};

pub const Completion = union(enum) {
    write: WriteCompletion,
    read: ReadCompletion,
};

pub const Taken = struct {
    job: *anyopaque,
    completion: Completion,
};

const Job = struct {
    lane: *Lane,
    slot: usize,
    operation: union(enum) {
        write: struct {
            task_id: u64,
            run_generation: u64,
            change_order: u64,
            content: []u8,
            redacted: bool,
            max_bytes: usize,
            identity: ?store.Identity = null,
        },
        read: struct {
            completion_id: u64,
            identity: store.Identity,
            max_bytes: usize,
            complete: bool,
            redacted: bool,
            state: ReadState = .failed,
            content: []u8 = &.{},
        },
    },

    fn execute(context: *anyopaque) void {
        const self: *Job = @ptrCast(@alignCast(context));
        switch (self.operation) {
            .write => |*write| {
                write.identity = self.lane.store.put(
                    write.task_id,
                    write.run_generation,
                    write.change_order,
                    write.content,
                    write.max_bytes,
                ) catch null;
            },
            .read => |*read| {
                read.content = self.lane.store.readAlloc(
                    self.lane.allocator,
                    read.identity,
                    read.max_bytes,
                ) catch |err| {
                    read.state = switch (err) {
                        error.BlobMissing => .missing,
                        error.BlobMismatch, error.InvalidIdentity, error.UnsupportedContent => .corrupt,
                        else => .failed,
                    };
                    self.lane.publish(self);
                    return;
                };
                read.state = .ready;
            },
        }
        self.lane.publish(self);
    }

    fn cancel(context: *anyopaque) void {
        const self: *Job = @ptrCast(@alignCast(context));
        self.lane.publish(self);
    }

    fn completion(self: *Job) Completion {
        return switch (self.operation) {
            .write => |write| .{ .write = .{
                .task_id = write.task_id,
                .run_generation = write.run_generation,
                .change_order = write.change_order,
                .identity = write.identity,
                .redacted = write.redacted,
            } },
            .read => |read| .{ .read = .{
                .completion_id = read.completion_id,
                .identity = read.identity,
                .state = read.state,
                .content = read.content,
                .complete = read.complete,
                .redacted = read.redacted,
            } },
        };
    }

    fn deinit(self: *Job) void {
        switch (self.operation) {
            .write => |write| {
                std.crypto.secureZero(u8, write.content);
                self.lane.allocator.free(write.content);
            },
            .read => |read| if (read.content.len != 0) {
                std.crypto.secureZero(u8, read.content);
                self.lane.allocator.free(read.content);
            },
        }
        self.lane.allocator.destroy(self);
    }
};

pub const Lane = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    store: *store.FileStore,
    notifier: Notifier,
    executor: Executor,
    mutex: std.Io.Mutex = .init,
    completions: [max_in_flight]?*Job = @splat(null),
    completion_head: usize = 0,
    completion_tail: usize = 0,
    completion_count: usize = 0,
    active_count: usize = 0,
    active_tasks: [max_in_flight]?u64 = @splat(null),
    accepting: bool = true,

    pub fn create(
        io: std.Io,
        allocator: std.mem.Allocator,
        file_store: *store.FileStore,
        notifier: Notifier,
        executor: Executor,
    ) std.mem.Allocator.Error!*Lane {
        const self = try allocator.create(Lane);
        self.* = .{
            .io = io,
            .allocator = allocator,
            .store = file_store,
            .notifier = notifier,
            .executor = executor,
        };
        return self;
    }

    pub fn beginWrite(self: *Lane, input: WriteInput) Error!void {
        const slot = try self.reserve(input.task_id);
        errdefer self.unreserve(slot);
        const job = try self.allocator.create(Job);
        errdefer self.allocator.destroy(job);
        job.* = .{ .lane = self, .slot = slot, .operation = .{ .write = .{
            .task_id = input.task_id,
            .run_generation = input.run_generation,
            .change_order = input.change_order,
            .content = input.content,
            .redacted = input.redacted,
            .max_bytes = input.max_bytes,
        } } };
        self.enqueue(job) catch |err| return err;
    }

    pub fn beginRead(self: *Lane, input: ReadInput) Error!void {
        const slot = try self.reserve(input.identity.task_id);
        errdefer self.unreserve(slot);
        const job = try self.allocator.create(Job);
        errdefer self.allocator.destroy(job);
        job.* = .{ .lane = self, .slot = slot, .operation = .{ .read = .{
            .completion_id = input.completion_id,
            .identity = input.identity,
            .max_bytes = input.max_bytes,
            .complete = input.complete,
            .redacted = input.redacted,
        } } };
        self.enqueue(job) catch |err| return err;
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
        const job = self.completions[self.completion_head].?;
        self.completions[self.completion_head] = null;
        self.completion_head = (self.completion_head + 1) % self.completions.len;
        self.completion_count -= 1;
        self.unlock();
        return .{ .job = job, .completion = job.completion() };
    }

    pub fn release(self: *Lane, taken: Taken) void {
        const job: *Job = @ptrCast(@alignCast(taken.job));
        const slot = job.slot;
        job.deinit();
        self.unreserve(slot);
    }

    pub fn deinit(self: *Lane) void {
        std.debug.assert(!self.accepting);
        std.debug.assert(self.active_count == 0);
        std.debug.assert(self.completion_count == 0);
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    pub fn hasTaskJob(self: *Lane, task_id: u64) bool {
        self.lock();
        defer self.unlock();
        for (self.active_tasks) |entry| if (entry == task_id) return true;
        return false;
    }

    fn reserve(self: *Lane, task_id: u64) Error!usize {
        self.lock();
        defer self.unlock();
        if (!self.accepting) return error.ShuttingDown;
        if (self.active_count == max_in_flight) return error.Capacity;
        const slot = for (self.active_tasks, 0..) |entry, index| {
            if (entry == null) break index;
        } else unreachable;
        self.active_tasks[slot] = task_id;
        self.active_count += 1;
        return slot;
    }

    fn unreserve(self: *Lane, slot: usize) void {
        self.lock();
        std.debug.assert(self.active_count != 0);
        std.debug.assert(self.active_tasks[slot] != null);
        self.active_tasks[slot] = null;
        self.active_count -= 1;
        self.unlock();
    }

    fn enqueue(self: *Lane, job: *Job) Error!void {
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
