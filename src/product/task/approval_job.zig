//! Bounded approval transaction work. Inputs own an Access and immutable
//! observations, or an encoded history candidate; no worker reads Task state.

const std = @import("std");
const agent = @import("metawork_agent");
const agent_session = @import("product_task_agent_session");
const checkpoint_record = @import("product_task_checkpoint_record");
const checkpoint_store = @import("product_task_checkpoint_store");
const persistence = @import("product_task_persistence");
const worker_lease = @import("product_task_worker_lease");

pub const max_operations: usize = 8;
const state = @import("product_task_state");
pub const FailureReason = state.ApprovalFailureReason;

pub const Notifier = struct {
    context: ?*anyopaque,
    notify_fn: *const fn (?*anyopaque) bool,

    fn notify(self: Notifier) void {
        _ = self.notify_fn(self.context);
    }
};

pub const CheckpointWork = struct {
    access: agent_session.Access,
    store: *checkpoint_store.FileStore,
    store_health: *std.atomic.Value(checkpoint_store.Health),
    limits: agent.CheckpointLimits,
    task_id: u64,
    binding_epoch: u64,
    approval_revision: u64,
    last_run_id: u64,
    last_compact_id: u64,
    model: []const u8,
    expected_mode: agent.PermissionMode,
    target_mode: agent.PermissionMode,
    mutate: bool,
};

pub const HistoryWork = struct {
    bytes: []u8,
    capability: persistence.Capability,
    resolve_only: bool = false,
};

pub const Work = union(enum) {
    checkpoint: CheckpointWork,
    history: HistoryWork,
    retire: struct { store: *checkpoint_store.FileStore, identity: checkpoint_store.Identity },
};

pub const Failure = struct {
    reason: FailureReason,
    /// True requires closing the attachment and restoring the confirmed
    /// baseline. A failed reverse mutation cannot reconstruct revoked grants.
    restore_required: bool,
};

pub const Outcome = union(enum) {
    none,
    checkpoint: checkpoint_record.Record,
    history: persistence.Commit,
    retired,
    failure: Failure,
};

pub const Job = struct {
    allocator: std.mem.Allocator,
    lease: worker_lease.WorkerLease,
    notifier: Notifier,
    work: Work,
    cancelled: std.atomic.Value(bool) = .init(false),
    state: std.atomic.Value(enum(u8) { queued, running, completed, cancelled }) = .init(.queued),
    outcome: Outcome = .none,

    pub fn execute(context: *anyopaque) void {
        const self: *Job = @ptrCast(@alignCast(context));
        const prior = self.state.cmpxchgStrong(.queued, .running, .acq_rel, .acquire);
        std.debug.assert(prior == null);
        self.outcome = self.run();
        const notifier = self.notifier;
        self.state.store(.completed, .release);
        notifier.notify();
    }

    pub fn cancelQueued(context: *anyopaque) void {
        const self: *Job = @ptrCast(@alignCast(context));
        self.cancelled.store(true, .release);
        const prior = self.state.cmpxchgStrong(.queued, .running, .acq_rel, .acquire);
        std.debug.assert(prior == null);
        // Publish completion last, after every worker-owned result.
        self.outcome = .{ .failure = .{ .reason = .cancelled, .restore_required = false } };
        const notifier = self.notifier;
        self.state.store(.cancelled, .release);
        notifier.notify();
    }

    pub fn requestCancellation(self: *Job) void {
        self.cancelled.store(true, .release);
    }

    pub fn completionReady(self: *const Job) bool {
        return switch (self.state.load(.acquire)) {
            .queued, .running => false,
            .completed, .cancelled => true,
        };
    }

    pub fn takeCheckpoint(self: *Job) ?checkpoint_record.Record {
        if (self.outcome != .checkpoint) return null;
        const record = self.outcome.checkpoint;
        self.outcome = .none;
        return record;
    }

    pub fn takeHistory(self: *Job) ?[]u8 {
        if (self.work != .history) return null;
        const bytes = self.work.history.bytes;
        self.work.history.bytes = &.{};
        return bytes;
    }

    pub fn deinit(self: *Job) void {
        std.debug.assert(self.completionReady());
        if (self.outcome == .checkpoint) self.outcome.checkpoint.deinit(self.allocator);
        switch (self.work) {
            .checkpoint => |*work| {
                work.access.deinit();
                self.allocator.free(work.model);
            },
            .history => |work| self.allocator.free(work.bytes),
            .retire => {},
        }
        self.lease.deinit();
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }

    fn fail(reason: FailureReason, restore_required: bool) Outcome {
        return .{ .failure = .{ .reason = reason, .restore_required = restore_required } };
    }

    fn run(self: *Job) Outcome {
        if (self.cancelled.load(.acquire)) return fail(.cancelled, false);
        switch (self.work) {
            .history => |work| return .{ .history = if (work.resolve_only) work.capability.resolveCommit(work.bytes) else work.capability.commitConfirmed(work.bytes) },
            .retire => |work| {
                work.store.delete(work.identity);
                return .retired;
            },
            .checkpoint => |*work| return exportCheckpoint(self.allocator, &self.cancelled, work),
        }
    }
};

/// Export work shared by approval changes and execution rebind. The caller
/// retains Access ownership and confirms the returned record separately.
pub fn exportCheckpoint(allocator: std.mem.Allocator, cancelled: *const std.atomic.Value(bool), work: *CheckpointWork) Outcome {
    if (work.store_health.load(.acquire) != .ready) return Job.fail(.checkpoint_failed, false);
    var writer = work.store.begin(work.task_id, work.limits.hard_bytes) catch return Job.fail(.checkpoint_failed, false);
    defer writer.deinit();
    var mutated = false;
    var generation: ?u64 = null;
    if (work.mutate) {
        const result = work.access.updatePermissionMode(work.expected_mode, work.target_mode) catch |err| {
            const poisoned = work.access.sessionState() == .poisoned;
            return Job.fail(switch (err) {
                error.PermissionModeBudgetRequired => .budget_required,
                error.SessionNotIdle => .busy,
                else => .mode_update_failed,
            }, poisoned);
        };
        mutated = result.changed;
        generation = result.policy_generation;
        if (!mutated) return Job.fail(.dependency_contract, true);
    }
    if (cancelled.load(.acquire)) return Job.fail(.cancelled, mutated);
    var sink = Sink{ .writer = &writer, .cancelled = cancelled };
    var outcome = work.access.exportCheckpoint(
        work.limits,
        .{ .context = &sink, .write_fn = Sink.write },
        work.last_run_id,
        work.last_compact_id,
        work.model,
    ) catch return Job.fail(.checkpoint_failed, mutated or work.access.sessionState() == .poisoned);
    defer outcome.deinit();
    if (outcome == .failure) return Job.fail(
        if (outcome.failure.reason == .busy) .busy else .checkpoint_failed,
        mutated or outcome.failure.disposition == .poisoned,
    );
    const success = &outcome.success;
    if (generation) |expected| if (success.description.policy_generation != expected)
        return Job.fail(.dependency_contract, true);
    if (!permissionModeMatches(success.description.permission_mode, if (work.mutate) work.target_mode else work.expected_mode))
        return Job.fail(.dependency_contract, true);
    const logical_id = allocator.dupe(u8, success.description.session_id) catch return Job.fail(.checkpoint_failed, mutated);
    const model = allocator.dupe(u8, success.description.model) catch {
        allocator.free(logical_id);
        return Job.fail(.checkpoint_failed, mutated);
    };
    var record = checkpoint_record.Record{
        .blob = .{
            .task_id = work.task_id,
            .generation = success.checkpoint.generation,
            .digest = success.checkpoint.digest,
            .byte_size = success.checkpoint.total_bytes,
        },
        .session = .{
            .logical_session_id = logical_id,
            .last_run_id = success.description.last_run_id,
            .last_compact_id = success.description.last_compact_id,
            .model = model,
        },
        .anchor = .{ .terminal = .{ .approval = work.approval_revision }, .binding_epoch = work.binding_epoch },
    };
    _ = writer.commit(record.blob.generation, record.blob.digest, record.blob.byte_size) catch |err| {
        if (err == error.BlobAlreadyExists) {
            // Identical exports may use an existing immutable blob,
            // but only after the canonical reader verifies it.
            var existing = work.store.openVerified(record.blob, cancelled) catch {
                record.deinit(allocator);
                return Job.fail(.checkpoint_failed, mutated);
            };
            existing.deinit();
            return .{ .checkpoint = record };
        }
        if (err == error.PersistenceOutcomeUnknown) work.store_health.store(.outcome_unknown, .release);
        record.deinit(allocator);
        return Job.fail(if (err == error.PersistenceOutcomeUnknown) .outcome_unknown else .checkpoint_failed, mutated);
    };
    return .{ .checkpoint = record };
}

fn permissionModeMatches(mode: anytype, expected: agent.PermissionMode) bool {
    return std.mem.eql(u8, @tagName(mode), @tagName(expected));
}

const Sink = struct {
    writer: *checkpoint_store.Writer,
    cancelled: *const std.atomic.Value(bool),

    fn write(context: ?*anyopaque, bytes: []const u8) agent.CheckpointSinkWriteResult {
        const self: *Sink = @ptrCast(@alignCast(context orelse return .contract_failed));
        if (self.cancelled.load(.acquire)) return .cancelled;
        self.writer.write(bytes) catch |err| return switch (err) {
            error.ResourceLimit => .contract_failed,
            error.WriteFailed => .io_failed,
        };
        return .ok;
    }
};

test "queued approval cancellation publishes one completion and releases owned resources" {
    const Harness = struct {
        fn notify(_: ?*anyopaque) bool {
            return true;
        }
        fn commit(_: ?*anyopaque, _: []const u8) persistence.Commit {
            return .committed;
        }
    };
    var leases: worker_lease.WorkerLeaseSet = .{};
    const job = try std.testing.allocator.create(Job);
    job.* = .{
        .allocator = std.testing.allocator,
        .lease = try leases.acquire(),
        .notifier = .{ .context = null, .notify_fn = Harness.notify },
        .work = .{ .history = .{
            .bytes = try std.testing.allocator.dupe(u8, "candidate"),
            .capability = .{ .enabled = true, .confirmed_commit_fn = Harness.commit },
        } },
    };
    Job.cancelQueued(job);
    try std.testing.expect(job.completionReady());
    try std.testing.expectEqual(FailureReason.cancelled, job.outcome.failure.reason);
    try std.testing.expect(!job.outcome.failure.restore_required);
    job.deinit();
    try std.testing.expectEqual(@as(usize, 0), leases.liveCount());
}

test "approval history worker publishes the confirmed commit disposition exactly once" {
    const Harness = struct {
        calls: usize = 0,
        result: persistence.Commit,
        fn notify(_: ?*anyopaque) bool {
            return true;
        }
        fn commit(context: ?*anyopaque, bytes: []const u8) persistence.Commit {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            std.debug.assert(std.mem.eql(u8, bytes, "candidate"));
            self.calls += 1;
            return self.result;
        }
    };
    for ([_]persistence.Commit{ .committed, .failed, .outcome_unknown }) |result| {
        var harness = Harness{ .result = result };
        var leases: worker_lease.WorkerLeaseSet = .{};
        const job = try std.testing.allocator.create(Job);
        job.* = .{
            .allocator = std.testing.allocator,
            .lease = try leases.acquire(),
            .notifier = .{ .context = null, .notify_fn = Harness.notify },
            .work = .{ .history = .{
                .bytes = try std.testing.allocator.dupe(u8, "candidate"),
                .capability = .{ .enabled = true, .context = &harness, .confirmed_commit_fn = Harness.commit },
            } },
        };
        Job.execute(job);
        try std.testing.expect(job.completionReady());
        try std.testing.expectEqual(result, job.outcome.history);
        try std.testing.expectEqual(@as(usize, 1), harness.calls);
        job.deinit();
        try std.testing.expectEqual(@as(usize, 0), leases.liveCount());
    }
}

test "approval resolution worker only reads the retained candidate and releases its own copy" {
    const Harness = struct {
        writes: usize = 0,
        reads: usize = 0,
        fn notify(_: ?*anyopaque) bool {
            return true;
        }
        fn write(context: ?*anyopaque, _: []const u8) persistence.Commit {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.writes += 1;
            return .committed;
        }
        fn read(context: ?*anyopaque, bytes: []const u8) persistence.Commit {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.reads += 1;
            std.debug.assert(std.mem.eql(u8, bytes, "retained candidate"));
            return .committed;
        }
    };
    var harness: Harness = .{};
    var leases: worker_lease.WorkerLeaseSet = .{};
    const job = try std.testing.allocator.create(Job);
    job.* = .{
        .allocator = std.testing.allocator,
        .lease = try leases.acquire(),
        .notifier = .{ .context = null, .notify_fn = Harness.notify },
        .work = .{ .history = .{
            .bytes = try std.testing.allocator.dupe(u8, "retained candidate"),
            .resolve_only = true,
            .capability = .{ .enabled = true, .context = &harness, .confirmed_commit_fn = Harness.write, .resolve_commit_fn = Harness.read },
        } },
    };
    Job.execute(job);
    try std.testing.expectEqual(persistence.Commit.committed, job.outcome.history);
    try std.testing.expectEqual(@as(usize, 0), harness.writes);
    try std.testing.expectEqual(@as(usize, 1), harness.reads);
    job.deinit();
    try std.testing.expectEqual(@as(usize, 0), leases.liveCount());
}
