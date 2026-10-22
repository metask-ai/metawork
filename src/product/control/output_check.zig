//! One bounded, lazy worker for hashing explicitly delivered files. No file
//! content crosses this lane; the Application owns the frozen read capability.
const std = @import("std");
const executor_impl = @import("product_control_executor");
const task = @import("metawork_product_task");

/// Host-only owned input to a bounded file operation. This is a snapshot,
/// never a lasting grant: revalidate on the main loop before publishing bytes
/// or invoking a platform effect. No Task/Run pointers survive admission.
pub const Target = struct {
    allocator: std.mem.Allocator,
    storage: []u8,
    task_id: u64,
    run_id: u64,
    output_id: [16]u8,
    workspace_id: u64,
    workspace_epoch: u64,
    security_epoch: u64,
    workspace_root: []const u8,
    relative_path: []const u8,
    size_bytes: u64,
    sha256: [32]u8,

    pub fn deinit(self: *Target) void {
        self.allocator.free(self.storage);
        self.* = undefined;
    }
};

pub const State = enum { ready, busy, missing, restricted, changed, too_large, cancelled, timed_out, stale_security, unavailable, failed };
pub const max_in_flight = 2;
const timeout_ns = 30 * std.time.ns_per_s;
pub const Notifier = struct { context: ?*anyopaque, wake_fn: *const fn (?*anyopaque) bool };

const Job = struct {
    allocator: std.mem.Allocator,
    target: Target,
    delivery: task.OwnedFileDelivery,
    completion_id: u64,
    notifier: Notifier,
    created_at: std.Io.Timestamp,
    cancelled: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    state: State = .failed,
    expired: bool = false,
    taken: bool = false,

    fn execute(context: *anyopaque) void {
        const self: *Job = @ptrCast(@alignCast(context));
        self.state = if (self.cancelled.load(.acquire)) .cancelled else switch (self.delivery.input.inspect_fn(self.delivery.input.context, self.target.relative_path, &self.cancelled)) {
            .verified => |value| if (value.size_bytes == self.target.size_bytes and std.mem.eql(u8, &value.sha256, &self.target.sha256)) .ready else .changed,
            .failed => |reason| switch (reason) {
                .unavailable => .unavailable,
                .invalid_arguments, .restricted => .restricted,
                .capacity => .busy,
                .cancelled => .cancelled,
                .missing => .missing,
                .changed => .changed,
                .too_large => .too_large,
                .read_failed => .failed,
            },
        };
        self.publish();
    }

    fn cancelQueued(context: *anyopaque) void {
        const self: *Job = @ptrCast(@alignCast(context));
        self.cancelled.store(true, .release);
        self.state = .cancelled;
        self.publish();
    }

    fn publish(self: *Job) void {
        // The main loop may release this job immediately after observing done.
        // Retain only a local notifier after the release-store, never self.
        const notifier = self.notifier;
        self.done.store(true, .release);
        _ = notifier.wake_fn(notifier.context);
    }

    fn deinit(self: *Job) void {
        const allocator = self.allocator;
        self.delivery.deinit();
        self.target.deinit();
        allocator.destroy(self);
    }
};

pub const Taken = struct { job: *Job, target: *const Target, completion_id: u64, state: State };

pub const Lane = struct {
    executor: ?*executor_impl.Executor = null,
    jobs: [max_in_flight]?*Job = @splat(null),
    stopping: bool = false,

    /// Takes both owned values only on success. Admission/release are main-loop
    /// operations; the worker sees only the job's immutable input and atomics.
    pub fn begin(self: *Lane, io: std.Io, allocator: std.mem.Allocator, notifier: Notifier, completion_id: u64, target: Target, delivery: task.OwnedFileDelivery) !void {
        if (self.stopping) return error.ShuttingDown;
        if (completion_id == 0) return error.InvalidCompletion;
        for (self.jobs) |entry| if (entry) |job| {
            if (job.completion_id == completion_id) return error.Capacity;
        };
        const slot = for (&self.jobs) |*entry| {
            if (entry.* == null) break entry;
        } else return error.Capacity;
        if (self.executor == null) self.executor = try executor_impl.Executor.create(io, allocator, .{ .worker_count = 1, .queue_capacity = max_in_flight });
        const job = try allocator.create(Job);
        errdefer allocator.destroy(job);
        job.* = .{ .allocator = allocator, .target = target, .delivery = delivery, .completion_id = completion_id, .notifier = notifier, .created_at = .now(io, .awake) };
        slot.* = job;
        errdefer slot.* = null;
        try self.executor.?.enqueue(.{ .identity = job, .context = job, .execute_fn = Job.execute, .cancel_fn = Job.cancelQueued });
    }

    pub fn cancel(self: *Lane, completion_id: u64) bool {
        for (self.jobs) |entry| if (entry) |job| {
            if (job.completion_id != completion_id) continue;
            job.cancelled.store(true, .release);
            _ = self.executor.?.cancel(job);
            return true;
        };
        return false;
    }

    pub fn hasPending(self: *const Lane) bool {
        for (self.jobs) |entry| if (entry != null) return true;
        return false;
    }

    pub fn take(self: *Lane, io: std.Io) ?Taken {
        const now: std.Io.Timestamp = .now(io, .awake);
        for (self.jobs) |entry| if (entry) |job| {
            if (!job.expired and job.created_at.durationTo(now).nanoseconds >= timeout_ns) {
                job.expired = true;
                _ = self.cancel(job.completion_id);
            }
            if (!job.done.load(.acquire) or job.taken) continue;
            job.taken = true;
            return .{ .job = job, .target = &job.target, .completion_id = job.completion_id, .state = if (job.expired) .timed_out else if (job.cancelled.load(.acquire)) .cancelled else job.state };
        };
        return null;
    }

    pub fn release(self: *Lane, taken: Taken) void {
        for (&self.jobs) |*entry| {
            if (entry.* != taken.job) continue;
            std.debug.assert(taken.job.done.load(.acquire) and taken.job.taken);
            entry.* = null;
            taken.job.deinit();
            return;
        }
        unreachable;
    }

    pub fn stopAdmission(self: *Lane) void {
        self.stopping = true;
        for (self.jobs) |entry| if (entry) |job| {
            _ = self.cancel(job.completion_id);
        };
    }

    pub fn shutdown(self: *Lane) void {
        self.stopAdmission();
        if (self.executor) |executor| executor.shutdown();
    }

    pub fn deinit(self: *Lane) void {
        self.shutdown();
        for (&self.jobs) |*entry| if (entry.*) |job| {
            std.debug.assert(job.done.load(.acquire));
            job.deinit();
            entry.* = null;
        };
        if (self.executor) |executor| executor.deinit();
        self.* = undefined;
    }
};
