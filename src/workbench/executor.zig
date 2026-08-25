const std = @import("std");

pub const Error = error{
    ExecutorShuttingDown,
    QueueFull,
};

pub const Limits = struct {
    worker_count: usize,
    queue_capacity: usize,
};

pub const Job = struct {
    /// Stable owner identity used to remove a queued job without exposing its
    /// executor-only payload to product records.
    identity: *anyopaque,
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
    head: usize = 0,
    tail: usize = 0,
    queued: usize = 0,
    workers: []std.Thread,
    stopping: bool = false,
    shutdown_running: bool = false,
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
        if (self.stopping) return error.ExecutorShuttingDown;
        if (self.queued == self.queue.len) return error.QueueFull;
        std.debug.assert(self.queue[self.tail] == null);
        self.queue[self.tail] = item;
        self.tail = (self.tail + 1) % self.queue.len;
        self.queued += 1;
        self.signal();
    }

    /// Removes a queued job by owner identity and synchronously runs its queued
    /// cancellation callback. A job already claimed by a worker is untouched.
    pub fn cancel(self: *Executor, identity: *anyopaque) bool {
        self.lock();
        for (0..self.queued) |offset| {
            const index = (self.head + offset) % self.queue.len;
            const item = self.queue[index].?;
            if (item.identity != identity) continue;
            for (offset..self.queued - 1) |shift| {
                const destination = (self.head + shift) % self.queue.len;
                const source = (self.head + shift + 1) % self.queue.len;
                self.queue[destination] = self.queue[source];
            }
            self.tail = (self.tail + self.queue.len - 1) % self.queue.len;
            self.queue[self.tail] = null;
            self.queued -= 1;
            self.unlock();
            item.cancel();
            return true;
        }
        self.unlock();
        return false;
    }

    /// Concurrent shutdown callers serialize here. `deinit` still requires all
    /// external callers to be quiescent before destroying the Executor object.
    pub fn shutdown(self: *Executor) void {
        self.lock();
        if (self.joined) {
            self.unlock();
            return;
        }
        if (self.shutdown_running) {
            while (!self.joined) self.wait();
            self.unlock();
            return;
        }
        self.shutdown_running = true;
        self.stopping = true;
        self.broadcast();
        while (self.queued != 0) {
            const cancelled = self.popLocked();
            self.unlock();
            cancelled.cancel();
            self.lock();
        }
        self.unlock();
        for (self.workers) |thread| thread.join();
        self.allocator.free(self.workers);
        self.allocator.free(self.queue);
        self.workers = &.{};
        self.queue = &.{};
        self.lock();
        self.joined = true;
        self.shutdown_running = false;
        self.broadcast();
        self.unlock();
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
            const next = self.popLocked();
            self.unlock();
            next.execute();
        }
    }

    fn popLocked(self: *Executor) Job {
        std.debug.assert(self.queued != 0);
        const item = self.queue[self.head].?;
        self.queue[self.head] = null;
        self.head = (self.head + 1) % self.queue.len;
        self.queued -= 1;
        return item;
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
        .identity = &harness,
        .context = &harness,
        .execute_fn = Harness.execute,
        .cancel_fn = Harness.cancel,
    });
    while (!harness.started.load(.acquire)) std.Thread.yield() catch {};
    try executor.enqueue(.{
        .identity = &harness,
        .context = &harness,
        .execute_fn = Harness.execute,
        .cancel_fn = Harness.cancel,
    });

    const first_shutdown = try std.Thread.spawn(.{}, Shutdown.run, .{executor});
    const second_shutdown = try std.Thread.spawn(.{}, Shutdown.run, .{executor});
    while (harness.cancelled.load(.acquire) == 0) std.Thread.yield() catch {};
    harness.release.store(true, .release);
    first_shutdown.join();
    second_shutdown.join();

    try std.testing.expectEqual(@as(usize, 1), harness.executed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), harness.cancelled.load(.acquire));
}

test "ring queue preserves FIFO when a freed head slot is reused" {
    const Harness = struct {
        order: [3]u8 = undefined,
        count: std.atomic.Value(usize) = .init(0),
        first_started: std.atomic.Value(bool) = .init(false),
        release_first: std.atomic.Value(bool) = .init(false),
    };
    const Item = struct {
        harness: *Harness,
        id: u8,
        block: bool = false,

        fn execute(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            const index = self.harness.count.load(.monotonic);
            self.harness.order[index] = self.id;
            self.harness.count.store(index + 1, .release);
            if (self.block) {
                self.harness.first_started.store(true, .release);
                while (!self.harness.release_first.load(.acquire)) std.Thread.yield() catch {};
            }
        }

        fn cancel(_: *anyopaque) void {
            unreachable;
        }
    };

    var harness = Harness{};
    var first = Item{ .harness = &harness, .id = 1, .block = true };
    var second = Item{ .harness = &harness, .id = 2 };
    var third = Item{ .harness = &harness, .id = 3 };
    const executor = try Executor.create(std.testing.io, std.testing.allocator, .{
        .worker_count = 1,
        .queue_capacity = 2,
    });
    defer executor.deinit();
    try executor.enqueue(.{ .identity = &first, .context = &first, .execute_fn = Item.execute, .cancel_fn = Item.cancel });
    while (!harness.first_started.load(.acquire)) std.Thread.yield() catch {};
    try executor.enqueue(.{ .identity = &second, .context = &second, .execute_fn = Item.execute, .cancel_fn = Item.cancel });
    try executor.enqueue(.{ .identity = &third, .context = &third, .execute_fn = Item.execute, .cancel_fn = Item.cancel });
    harness.release_first.store(true, .release);
    while (harness.count.load(.acquire) != 3) std.Thread.yield() catch {};
    executor.shutdown();

    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, &harness.order);
}

test "queued cancellation separates owner identity from executor payload" {
    const Payload = struct {
        cancelled: bool = false,

        fn execute(_: *anyopaque) void {
            unreachable;
        }

        fn cancel(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.cancelled = true;
        }
    };

    var identity: u8 = 0;
    var payload = Payload{};
    const executor = try Executor.create(std.testing.io, std.testing.allocator, .{
        .worker_count = 1,
        .queue_capacity = 1,
    });
    defer executor.deinit();

    // Keep the sole worker occupied so the payload remains queued.
    const Blocker = struct {
        started: std.atomic.Value(bool) = .init(false),
        release: std.atomic.Value(bool) = .init(false),

        fn execute(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.started.store(true, .release);
            while (!self.release.load(.acquire)) std.Thread.yield() catch {};
        }

        fn cancel(_: *anyopaque) void {
            unreachable;
        }
    };
    var blocker = Blocker{};
    try executor.enqueue(.{
        .identity = &blocker,
        .context = &blocker,
        .execute_fn = Blocker.execute,
        .cancel_fn = Blocker.cancel,
    });
    while (!blocker.started.load(.acquire)) std.Thread.yield() catch {};
    try executor.enqueue(.{
        .identity = &identity,
        .context = &payload,
        .execute_fn = Payload.execute,
        .cancel_fn = Payload.cancel,
    });

    try std.testing.expect(executor.cancel(&identity));
    try std.testing.expect(payload.cancelled);
    blocker.release.store(true, .release);
}
