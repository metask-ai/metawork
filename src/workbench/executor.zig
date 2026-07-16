const std = @import("std");
const agentcore = @import("metawork_agentcore");

pub const Error = error{
    HostShuttingDown,
    QueueFull,
};

pub const Limits = struct {
    worker_count: usize,
    queue_capacity: usize,
};

pub const Executor = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    queue: []?agentcore.ScheduledRun,
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
        const queue = try allocator.alloc(?agentcore.ScheduledRun, limits.queue_capacity);
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

    pub fn scheduler(self: *Executor) agentcore.Scheduler {
        return .{
            .context = self,
            .enqueue_fn = enqueueFromAgentCore,
            .cancel_fn = cancelFromAgentCore,
            .shutdown_fn = shutdownFromAgentCore,
            .deinit_fn = deinitFromAgentCore,
        };
    }

    /// Releases an executor whose scheduler ownership was not transferred to
    /// AgentCore Host initialization.
    pub fn destroy(self: *Executor) void {
        self.shutdown();
        deinitFromAgentCore(self);
    }

    fn enqueue(self: *Executor, item: agentcore.ScheduledRun) Error!void {
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

    fn cancel(self: *Executor, context: *anyopaque) bool {
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

    fn shutdown(self: *Executor) void {
        self.lock();
        if (self.joined) {
            self.unlock();
            return;
        }
        self.stopping = true;
        self.broadcast();
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
            if (self.stopping and self.queued == 0) {
                self.unlock();
                return;
            }
            var next: ?agentcore.ScheduledRun = null;
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
            item.execute(item.context);
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

    fn enqueueFromAgentCore(context: *anyopaque, run: agentcore.ScheduledRun) error{ HostShuttingDown, QueueFull }!void {
        const self: *Executor = @ptrCast(@alignCast(context));
        return self.enqueue(run);
    }

    fn cancelFromAgentCore(context: *anyopaque, run_context: *anyopaque) bool {
        const self: *Executor = @ptrCast(@alignCast(context));
        return self.cancel(run_context);
    }

    fn shutdownFromAgentCore(context: *anyopaque) void {
        const self: *Executor = @ptrCast(@alignCast(context));
        self.shutdown();
    }

    fn deinitFromAgentCore(context: *anyopaque) void {
        const self: *Executor = @ptrCast(@alignCast(context));
        std.debug.assert(self.joined);
        const allocator = self.allocator;
        allocator.destroy(self);
    }
};
