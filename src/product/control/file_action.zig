//! One bounded, lazy worker for the file operations a user asked for. No file
//! content crosses this lane; the Application owns every file effect.
const std = @import("std");
const executor_impl = @import("product_control_executor");
const file_target = @import("product_control_file_target");
const task = @import("metawork_product_task");
const ports = @import("metawork_product_control_ports");

/// What a user may do with one Workspace file.
pub const Action = enum {
    open,
    reveal,
    copy_path,
    check_current,
    save,
    check,

    pub fn accepts(self: Action, target: file_target.Target) bool {
        return switch (self) {
            // Only a delivery recorded the content there is to compare with.
            .check => target == .output,
            .open, .reveal, .copy_path, .check_current, .save => true,
        };
    }
};

pub const Subject = union(enum) {
    file: struct { target: file_target.Target, action: Action },
    registration: Registration,

    pub const Registration = struct { task_id: u64, run_id: u64, change_id: []const u8 };

    fn clone(self: Subject, allocator: std.mem.Allocator) std.mem.Allocator.Error!Subject {
        switch (self) {
            .file => |value| return .{ .file = .{ .target = try value.target.clone(allocator), .action = value.action } },
            .registration => |value| {
                var copy = value;
                copy.change_id = try allocator.dupe(u8, value.change_id);
                return .{ .registration = copy };
            },
        }
    }

    fn free(self: Subject, allocator: std.mem.Allocator) void {
        switch (self) {
            .file => |value| value.target.free(allocator),
            .registration => |value| allocator.free(value.change_id),
        }
    }
};

/// Host-only owned input to one bounded file operation. This is a snapshot,
/// never a lasting grant: resolve the subject again on the main loop before
/// publishing bytes or invoking a platform effect. No Task/Run pointers
/// survive admission.
pub const Input = struct {
    allocator: std.mem.Allocator,
    subject: Subject,
    location: file_target.Location,
    security_epoch: u64,

    pub fn init(allocator: std.mem.Allocator, subject: Subject, location: file_target.Location, security_epoch: u64) std.mem.Allocator.Error!Input {
        const owned_subject = try subject.clone(allocator);
        errdefer owned_subject.free(allocator);
        return .{
            .allocator = allocator,
            .subject = owned_subject,
            .location = try location.clone(allocator),
            .security_epoch = security_epoch,
        };
    }

    pub fn deinit(self: *Input) void {
        self.location.free(self.allocator);
        self.subject.free(self.allocator);
        self.* = undefined;
    }
};

pub const State = enum { ready, revealed, saved, registered, opened, open_unsupported, open_failed, path_copied, copy_failed, save_failed, target_changed, cleanup_failed, busy, missing, restricted, changed, too_large, cancelled, timed_out, stale_security, unavailable, failed };
pub const max_in_flight = 2;
const timeout_ns = 30 * std.time.ns_per_s;
pub const Notifier = struct { context: ?*anyopaque, wake_fn: *const fn (?*anyopaque) bool };

pub const Work = union(enum) {
    /// Reads the whole file for its digest.
    inspect: task.OwnedFileDelivery,
    /// Proves which file the name is and prepares one main-loop effect on it.
    effect: ports.OwnedFileEffect,
    save: ports.OwnedFileSave,

    pub fn deinit(self: *Work) void {
        switch (self.*) {
            .inspect => |*value| value.deinit(),
            .effect => |*value| value.deinit(),
            .save => |*value| value.deinit(),
        }
    }
};
const Decision = enum(u8) { waiting, commit, cancelled, timed_out, restricted, missing, stale_security, failed };
const Job = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    input: Input,
    work: Work,
    completion_id: u64,
    notifier: Notifier,
    created_at: std.Io.Timestamp,
    cancelled: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    awaiting_publication: std.atomic.Value(bool) = .init(false),
    decision: std.atomic.Value(Decision) = .init(.waiting),
    decided: std.Io.Event = .unset,
    state: State = .failed,
    inspected: ?file_target.Delivered = null,
    expired: bool = false,
    taken: bool = false,

    fn execute(context: *anyopaque) void {
        const self: *Job = @ptrCast(@alignCast(context));
        switch (self.work) {
            .save => self.executeSave(),
            .effect => |effect| self.state = if (effect.inspect_fn(effect.context, &self.cancelled)) |_| .ready else |err| effectFailure(err),
            .inspect => |delivery| self.state = self.inspect(delivery),
        }
        self.publish();
    }

    fn inspect(self: *Job, delivery: task.OwnedFileDelivery) State {
        if (self.cancelled.load(.acquire)) return .cancelled;
        return switch (delivery.input.inspect_fn(delivery.input.context, self.input.location.relative, &self.cancelled)) {
            .verified => |value| verified: {
                self.inspected = .{ .size_bytes = value.size_bytes, .sha256 = value.sha256 };
                const delivered = self.input.location.delivered orelse break :verified .ready;
                break :verified if (std.meta.eql(delivered, self.inspected.?)) .ready else .changed;
            },
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
        if (!setBy(self.io, &self.decided, self.created_at.addDuration(.fromNanoseconds(timeout_ns))))
            _ = self.decision.cmpxchgStrong(.waiting, .timed_out, .acq_rel, .acquire);
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
        self.input.deinit();
        allocator.destroy(self);
    }
};

/// How a refused or failed file effect reads to the user. Shared by the worker
/// that inspects and the main loop that performs.
pub fn effectFailure(err: anyerror) State {
    return switch (err) {
        error.UnsupportedService, error.RuntimeUnavailable => .unavailable,
        error.Cancelled, error.Canceled => .cancelled,
        error.FileNotFound, error.NotDir => .missing,
        error.OutputTooLarge => .too_large,
        error.OutputChanged => .changed,
        error.FileOpenFailed => .open_failed,
        error.ClipboardWriteFailed => .copy_failed,
        error.InvalidOutputPath, error.InvalidWorkspaceRoot, error.NotRegularOutput, error.RestrictedOutput, error.AccessDenied, error.SymLinkLoop => .restricted,
        else => .failed,
    };
}

pub const Taken = struct { job: *Job, input: *const Input, completion_id: u64, state: State, committed: bool };

/// Whether `event` is set before `deadline` passes on the awake clock.
///
/// Not one call of `Event.waitTimeout`: that waits once and answers `Timeout`
/// whenever the event is still unset afterwards, and std allows the wait to
/// end spuriously, as it does the `futexWaitTimeout` under it, on every
/// platform. Once the bytes are staged, the main loop rechecks the request and
/// the target file and decides; read as the deadline passing, an early answer
/// between the worker waking the main loop and that decision -- usually
/// milliseconds, longer while the loop is busy -- discards a save that was
/// still in time. So this waits again until the clock says the deadline has
/// passed.
///
/// The wait's errors are dropped, `error.Canceled` included: the Lane's worker
/// is a plain `std.Thread`, which `std.Io` cancelation does not reach.
fn setBy(io: std.Io, event: *std.Io.Event, deadline: std.Io.Timestamp) bool {
    while (!event.isSet()) {
        if (std.Io.Timestamp.now(io, .awake).nanoseconds >= deadline.nanoseconds) return event.isSet();
        event.waitTimeout(io, .{ .deadline = deadline.withClock(.awake) }) catch {};
    }
    return true;
}

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
pub const Publication = struct { job: *Job, input: *const Input, completion_id: u64 };

pub const Lane = struct {
    executor: ?*executor_impl.Executor = null,
    jobs: [max_in_flight]?*Job = @splat(null),
    stopping: bool = false,

    /// Takes both owned values only on success. Admission/release are main-loop
    /// operations; the worker sees only the job's immutable input and atomics.
    pub fn begin(self: *Lane, io: std.Io, allocator: std.mem.Allocator, notifier: Notifier, completion_id: u64, input: Input, work: Work) !void {
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
        job.* = .{ .io = io, .allocator = allocator, .input = input, .work = work, .completion_id = completion_id, .notifier = notifier, .created_at = .now(io, .awake) };
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
                return .{ .job = job, .input = &job.input, .completion_id = job.completion_id };
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
            return .{ .job = job, .input = &job.input, .completion_id = job.completion_id, .committed = committed, .state = if (job.work == .save or committed) job.state else if (job.expired) .timed_out else if (job.cancelled.load(.acquire)) .cancelled else job.state };
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

test "a decision deadline holds through waits that end early" {
    // A wake without a set is what an early end of `Event.waitTimeout` is, on
    // every platform. Woken again and again, the wait must still last until
    // the clock passes the deadline, and a set must still end it at once.
    const io = std.testing.io;
    const Waker = struct {
        event: *std.Io.Event,
        wakes: usize,
        set: bool,

        fn run(self: *@This()) void {
            for (0..self.wakes) |_| {
                std.Io.sleep(io, .fromMilliseconds(5), .awake) catch {};
                io.futexWake(std.Io.Event, self.event, 1);
            }
            if (self.set) self.event.set(io);
        }
    };

    var never: std.Io.Event = .unset;
    var early: Waker = .{ .event = &never, .wakes = 40, .set = false };
    const deadline = std.Io.Timestamp.now(io, .awake).addDuration(.fromMilliseconds(150));
    const early_thread = try std.Thread.spawn(.{}, Waker.run, .{&early});
    const never_set = setBy(io, &never, deadline);
    const returned_at = std.Io.Timestamp.now(io, .awake);
    early_thread.join();
    try std.testing.expect(!never_set);
    try std.testing.expect(returned_at.nanoseconds >= deadline.nanoseconds);

    var decided: std.Io.Event = .unset;
    var late: Waker = .{ .event = &decided, .wakes = 10, .set = true };
    const started = std.Io.Timestamp.now(io, .awake);
    const late_thread = try std.Thread.spawn(.{}, Waker.run, .{&late});
    const set = setBy(io, &decided, started.addDuration(.fromNanoseconds(timeout_ns)));
    const elapsed = started.durationTo(.now(io, .awake));
    late_thread.join();
    try std.testing.expect(set);
    try std.testing.expect(elapsed.nanoseconds < timeout_ns / 3);
}

test "a file action input is copied whole and released on every failed allocation" {
    const Case = struct {
        fn run(allocator: std.mem.Allocator) !void {
            for ([_]Subject{
                .{ .file = .{ .target = .{ .output = .{ .task_id = 3, .run_id = 7, .id = @splat(3) } }, .action = .check } },
                .{ .file = .{ .target = .{ .reference = .{ .task_id = 3, .run_id = 7, .id = "file-3-1-1-1" } }, .action = .reveal } },
                .{ .registration = .{ .task_id = 3, .run_id = 7, .change_id = "change-3-1-1" } },
            }) |subject| {
                var input = try Input.init(allocator, subject, .{ .workspace_id = 1, .workspace_epoch = 1, .root = "/workspace", .relative = "a.txt" }, 4);
                defer input.deinit();
                try std.testing.expectEqualDeep(subject, input.subject);
                try std.testing.expectEqual(@as(u64, 4), input.security_epoch);
            }
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}
