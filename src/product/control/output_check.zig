//! One bounded, lazy worker for hashing explicitly delivered files. No file
//! content crosses this lane; the Application owns the frozen read capability.
const std = @import("std");
const executor_impl = @import("product_control_executor");
const task = @import("metawork_product_task");
const ports = @import("metawork_product_control_ports");

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

pub const Kind = enum { check, reveal, save };
pub const State = enum { ready, revealed, saved, save_failed, target_changed, cleanup_failed, busy, missing, restricted, changed, too_large, cancelled, timed_out, stale_security, unavailable, failed };
pub const max_in_flight = 2;
const timeout_ns = 30 * std.time.ns_per_s;
pub const Notifier = struct { context: ?*anyopaque, wake_fn: *const fn (?*anyopaque) bool };

pub const Work = union(enum) {
    inspect: task.OwnedFileDelivery,
    save: ports.OwnedOutputSave,
    pub fn deinit(self: *Work) void {
        switch (self.*) {
            .inspect => |*value| value.deinit(),
            .save => |*value| value.deinit(),
        }
    }
};
const Decision = enum(u8) { waiting, commit, cancelled, timed_out, restricted, missing, stale_security, failed };
const Job = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    target: Target,
    work: Work,
    completion_id: u64,
    kind: Kind,
    notifier: Notifier,
    created_at: std.Io.Timestamp,
    cancelled: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    awaiting_publication: std.atomic.Value(bool) = .init(false),
    decision: std.atomic.Value(Decision) = .init(.waiting),
    decided: std.Io.Event = .unset,
    state: State = .failed,
    expired: bool = false,
    taken: bool = false,

    fn execute(context: *anyopaque) void {
        const self: *Job = @ptrCast(@alignCast(context));
        if (self.work == .save) {
            self.executeSave();
            self.publish();
            return;
        }
        const delivery = self.work.inspect;
        self.state = if (self.cancelled.load(.acquire)) .cancelled else switch (delivery.input.inspect_fn(delivery.input.context, self.target.relative_path, &self.cancelled)) {
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

    fn executeSave(self: *Job) void {
        const save = self.work.save;
        save.stage_fn(save.context, &self.cancelled) catch |err| {
            self.state = saveFailure(err);
            if (self.state != .cleanup_failed) self.state = deniedState(self.decision.load(.acquire)) orelse self.state;
            return;
        };
        self.awaiting_publication.store(true, .release);
        _ = self.notifier.wake_fn(self.notifier.context);
        self.decided.waitTimeout(self.io, .{ .deadline = self.created_at.addDuration(.fromMilliseconds(30000)).withClock(.awake) }) catch {
            _ = self.decision.cmpxchgStrong(.waiting, .timed_out, .acq_rel, .acquire);
        };
        const decision = self.decision.load(.acquire);
        if (decision == .commit) {
            save.publish_fn(save.context) catch |err| {
                self.state = saveFailure(err);
                return;
            };
            self.state = .saved;
        } else {
            save.discard_fn(save.context) catch {
                self.state = .cleanup_failed;
                return;
            };
            self.state = deniedState(decision) orelse .failed;
        }
    }

    fn cancelQueued(context: *anyopaque) void {
        const self: *Job = @ptrCast(@alignCast(context));
        self.cancelled.store(true, .release);
        self.state = deniedState(self.decision.load(.acquire)) orelse .cancelled;
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
        self.work.deinit();
        self.target.deinit();
        allocator.destroy(self);
    }
};

pub const Taken = struct { job: *Job, target: *const Target, completion_id: u64, kind: Kind, state: State, committed: bool };

fn deniedState(decision: Decision) ?State {
    return switch (decision) {
        .waiting, .commit => null,
        .cancelled => .cancelled,
        .timed_out => .timed_out,
        .restricted => .restricted,
        .missing => .missing,
        .stale_security => .stale_security,
        .failed => .failed,
    };
}
fn saveFailure(err: anyerror) State {
    return switch (err) {
        error.Cancelled, error.Canceled => .cancelled,
        error.OutputChanged, error.OutputCopyChanged => .changed,
        error.OutputDestinationChanged => .target_changed,
        error.OutputCleanupFailed => .cleanup_failed,
        error.SameOutputDestination, error.InvalidOutputPath, error.InvalidWorkspaceRoot, error.InvalidOutputDestination, error.RestrictedOutput, error.AccessDenied, error.SymLinkLoop => .restricted,
        error.OutputTooLarge => .too_large,
        else => .save_failed,
    };
}
pub const Publication = struct { job: *Job, target: *const Target, completion_id: u64 };

pub const Lane = struct {
    executor: ?*executor_impl.Executor = null,
    jobs: [max_in_flight]?*Job = @splat(null),
    stopping: bool = false,

    /// Takes both owned values only on success. Admission/release are main-loop
    /// operations; the worker sees only the job's immutable input and atomics.
    pub fn begin(self: *Lane, io: std.Io, allocator: std.mem.Allocator, notifier: Notifier, completion_id: u64, kind: Kind, target: Target, work: Work) !void {
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
        job.* = .{ .io = io, .allocator = allocator, .target = target, .work = work, .completion_id = completion_id, .kind = kind, .notifier = notifier, .created_at = .now(io, .awake) };
        slot.* = job;
        errdefer slot.* = null;
        try self.executor.?.enqueue(.{ .identity = job, .context = job, .execute_fn = Job.execute, .cancel_fn = Job.cancelQueued });
    }

    pub fn cancel(self: *Lane, completion_id: u64) bool {
        for (self.jobs) |entry| if (entry) |job| {
            if (job.completion_id != completion_id) continue;
            if (job.decision.cmpxchgStrong(.waiting, .cancelled, .acq_rel, .acquire)) |old| if (old == .commit) return false;
            job.cancelled.store(true, .release);
            job.decided.set(job.io);
            _ = self.executor.?.cancel(job);
            return true;
        };
        return false;
    }

    pub fn hasPending(self: *const Lane) bool {
        for (self.jobs) |entry| if (entry != null) return true;
        return false;
    }

    pub fn publicationCommitted(self: *const Lane, id: u64) bool {
        for (self.jobs) |entry| if (entry) |job| {
            if (job.completion_id == id) return job.decision.load(.acquire) == .commit;
        };
        return false;
    }

    pub fn expire(self: *Lane, io: std.Io) void {
        const now: std.Io.Timestamp = .now(io, .awake);
        for (self.jobs) |entry| if (entry) |job| {
            if (job.created_at.durationTo(now).nanoseconds < timeout_ns) continue;
            if (job.decision.cmpxchgStrong(.waiting, .timed_out, .acq_rel, .acquire)) |old| {
                if (old == .commit) continue;
            }
            job.expired = job.decision.load(.acquire) == .timed_out;
            job.cancelled.store(true, .release);
            job.decided.set(job.io);
            _ = self.executor.?.cancel(job);
        };
    }

    pub fn awaitingPublication(self: *Lane) ?Publication {
        for (self.jobs) |entry| if (entry) |job| {
            if (job.awaiting_publication.load(.acquire) and job.decision.load(.acquire) == .waiting)
                return .{ .job = job, .target = &job.target, .completion_id = job.completion_id };
        };
        return null;
    }

    pub fn decide(_: *Lane, publication: Publication, state: State) void {
        const decision: Decision = switch (state) {
            .ready => .commit,
            .cancelled => .cancelled,
            .timed_out => .timed_out,
            .restricted => .restricted,
            .missing => .missing,
            .stale_security => .stale_security,
            else => .failed,
        };
        _ = publication.job.decision.cmpxchgStrong(.waiting, decision, .acq_rel, .acquire);
        publication.job.decided.set(publication.job.io);
    }

    pub fn take(self: *Lane, io: std.Io) ?Taken {
        self.expire(io);
        for (self.jobs) |entry| if (entry) |job| {
            if (!job.done.load(.acquire) or job.taken) continue;
            job.taken = true;
            const committed = job.decision.load(.acquire) == .commit;
            return .{ .job = job, .target = &job.target, .completion_id = job.completion_id, .kind = job.kind, .committed = committed, .state = if (job.kind == .save or committed) job.state else if (job.expired) .timed_out else if (job.cancelled.load(.acquire)) .cancelled else job.state };
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
