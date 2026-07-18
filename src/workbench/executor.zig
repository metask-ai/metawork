const std = @import("std");

pub const Error = error{
    HostShuttingDown,
    QueueFull,
};

pub const Limits = struct {
    worker_count: usize,
    queue_capacity: usize,
};

pub const Job = struct {
    context: *anyopaque,
    execute_fn: *const fn (*anyopaque) void,
    cancel_fn: *const fn (*anyopaque) void,

    fn execute(self: Job) void {
        self.execute_fn(self.context);
    }

    fn cancel(self: Job) void {
        self.cancel_fn(self.context);
    }
};

pub const Executor = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    queue: []?Job,
    queued: usize = 0,
    workers: []std.Thread,
    stopping: bool = false,
    joined: bool = false,

    pub fn create(
        io: std.Io,
        allocator: std.mem.Allocator,
        limits: Limits,
    ) (error{InvalidLimits} || std.mem.Allocator.Error || std.Thread.SpawnError)!*Executor {
        if (limits.worker_count == 0 or limits.queue_capacity == 0) return error.InvalidLimits;
        const self = try allocator.create(Executor);
        errdefer allocator.destroy(self);
        const queue = try allocator.alloc(?Job, limits.queue_capacity);
        errdefer allocator.free(queue);
        @memset(queue, null);
        const workers = try allocator.alloc(std.Thread, limits.worker_count);
        errdefer allocator.free(workers);
        self.* = .{
            .io = io,
            .allocator = allocator,
            .queue = queue,
            .workers = workers,
        };
        var started: usize = 0;
        errdefer {
            self.lock();
            self.stopping = true;
            self.broadcast();
            self.unlock();
            for (self.workers[0..started]) |thread| thread.join();
        }
        for (self.workers) |*worker| {
            worker.* = try std.Thread.spawn(.{}, workerMain, .{self});
            started += 1;
        }
        return self;
    }

    pub fn deinit(self: *Executor) void {
        self.shutdown();
        std.debug.assert(self.joined);
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    pub fn enqueue(self: *Executor, item: Job) Error!void {
        self.lock();
        defer self.unlock();
        if (self.stopping) return error.HostShuttingDown;
        if (self.queued == self.queue.len) return error.QueueFull;
        for (self.queue) |*entry| {
            if (entry.* == null) {
                entry.* = item;
                self.queued += 1;
                self.signal();
                return;
            }
        }
        unreachable;
    }

    pub fn cancel(self: *Executor, context: *anyopaque) bool {
        self.lock();
        defer self.unlock();
        for (self.queue) |*entry| {
            if (entry.*) |item| {
                if (item.context == context) {
                    entry.* = null;
                    self.queued -= 1;
                    return true;
                }
            }
        }
        return false;
    }

    pub fn shutdown(self: *Executor) void {
        self.lock();
        if (self.joined) {
            self.unlock();
            return;
        }
        self.stopping = true;
        self.broadcast();
        while (self.queued != 0) {
            var cancelled: ?Job = null;
            for (self.queue) |*entry| {
                if (entry.*) |item| {
                    cancelled = item;
                    entry.* = null;
                    self.queued -= 1;
                    break;
                }
            }
            self.unlock();
            cancelled.?.cancel();
            self.lock();
        }
        self.unlock();
        for (self.workers) |thread| thread.join();
        self.lock();
        self.joined = true;
        self.unlock();
        self.allocator.free(self.workers);
        self.allocator.free(self.queue);
    }

    fn workerMain(self: *Executor) void {
        while (true) {
            self.lock();
            while (self.queued == 0 and !self.stopping)
                self.wait();
            if (self.stopping) {
                self.unlock();
                return;
            }
            var next: ?Job = null;
            for (self.queue) |*entry| {
                if (entry.*) |item| {
                    next = item;
                    entry.* = null;
                    self.queued -= 1;
                    break;
                }
            }
            self.unlock();
            const item = next.?;
            item.execute();
        }
    }

    fn lock(self: *Executor) void {
        self.mutex.lockUncancelable(self.io);
    }

    fn unlock(self: *Executor) void {
        self.mutex.unlock(self.io);
    }

    fn wait(self: *Executor) void {
        self.condition.waitUncancelable(self.io, &self.mutex);
    }

    fn signal(self: *Executor) void {
        self.condition.signal(self.io);
    }

    fn broadcast(self: *Executor) void {
        self.condition.broadcast(self.io);
    }
};

test "shutdown cancels queued jobs and joins the active worker" {
    const Harness = struct {
        started: std.atomic.Value(bool) = .init(false),
        release: std.atomic.Value(bool) = .init(false),
        executed: std.atomic.Value(usize) = .init(0),
        cancelled: std.atomic.Value(usize) = .init(0),

        fn execute(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            _ = self.executed.fetchAdd(1, .acq_rel);
            self.started.store(true, .release);
            while (!self.release.load(.acquire)) std.Thread.yield() catch {};
        }

        fn cancel(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            _ = self.cancelled.fetchAdd(1, .acq_rel);
        }
    };
    const Shutdown = struct {
        fn run(executor: *Executor) void {
            executor.shutdown();
        }
    };

    var harness = Harness{};
    const executor = try Executor.create(std.testing.io, std.testing.allocator, .{
        .worker_count = 1,
        .queue_capacity = 2,
    });
    defer executor.deinit();
    try executor.enqueue(.{
        .context = &harness,
        .execute_fn = Harness.execute,
        .cancel_fn = Harness.cancel,
    });
    while (!harness.started.load(.acquire)) std.Thread.yield() catch {};
    try executor.enqueue(.{
        .context = &harness,
        .execute_fn = Harness.execute,
        .cancel_fn = Harness.cancel,
    });

    const shutdown_thread = try std.Thread.spawn(.{}, Shutdown.run, .{executor});
    while (harness.cancelled.load(.acquire) == 0) std.Thread.yield() catch {};
    harness.release.store(true, .release);
    shutdown_thread.join();

    try std.testing.expectEqual(@as(usize, 1), harness.executed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), harness.cancelled.load(.acquire));
}
