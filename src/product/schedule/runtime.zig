//! Product Schedule live aggregate.
//!
//! Owns bounded Schedule state, persistence transactions, timer policy and
//! occurrence transitions. Cross-aggregate Task launch and terminal lookup
//! remain callback-scoped Product Control orchestration.

const std = @import("std");
const builtin = @import("builtin");
const state = @import("product_schedule_state");
const persistence = @import("product_schedule_persistence");
const view = @import("product_schedule_view");

pub const Recurrence = state.Recurrence;
pub const Provider = state.Provider;
pub const Definition = state.Definition;
pub const Occurrence = state.Occurrence;
pub const OccurrenceSource = state.OccurrenceSource;
pub const OccurrenceTaskOutcome = state.OccurrenceTaskOutcome;
pub const FailureReason = state.FailureReason;
pub const Health = state.Health;
pub const TextProjection = view.TextProjection;
pub const ViewError = view.Error;

pub const Error = state.Error || persistence.Error || error{
    ScheduleTimerUnavailable,
    ScheduledTaskPersistenceUnavailable,
    ScheduledTaskPersistenceFailed,
    ScheduledTaskPersistenceOutcomeUnknown,
    PreviousTaskActive,
};

pub const Limits = struct {
    max_items: usize,
    max_projection_bytes: usize,
};

pub const PersistenceCommit = enum { committed, failed, outcome_unknown };

pub const Persistence = struct {
    context: ?*anyopaque = null,
    enabled: bool = false,
    restored_bytes: ?[]const u8 = null,
    restore_failed: bool = false,
    commit_fn: *const fn (?*anyopaque, []const u8) PersistenceCommit = unsupportedCommit,

    fn commit(self: Persistence, bytes: []const u8) PersistenceCommit {
        if (!self.enabled) return .failed;
        return self.commit_fn(self.context, bytes);
    }

    fn unsupportedCommit(_: ?*anyopaque, _: []const u8) PersistenceCommit {
        return .failed;
    }
};

pub const PersistenceHealth = enum {
    unavailable,
    ready,
    read_failed,
    corrupt,
    write_failed,
    outcome_unknown,
};

pub const Timer = struct {
    context: ?*anyopaque = null,
    enabled: bool = false,
    now_unix_seconds: *const fn (?*anyopaque) ?u64 = noClock,
    arm: *const fn (?*anyopaque, u64) bool = noArm,
    cancel: *const fn (?*anyopaque) void = noCancel,

    fn now(self: Timer) ?u64 {
        if (!self.enabled) return null;
        return self.now_unix_seconds(self.context);
    }

    fn armAt(self: Timer, due: u64) bool {
        return self.enabled and self.arm(self.context, due);
    }

    fn cancelCurrent(self: Timer) void {
        if (self.enabled) self.cancel(self.context);
    }
};

fn noClock(_: ?*anyopaque) ?u64 {
    return null;
}
fn noArm(_: ?*anyopaque, _: u64) bool {
    return false;
}
fn noCancel(_: ?*anyopaque) void {}

pub const NotificationKind = enum { completed, failed, skipped, needs_attention };
pub const Notification = struct {
    scheduled_task_id: u64,
    task_id: u64 = 0,
    title: []const u8,
    kind: NotificationKind,
};

pub const Notifier = struct {
    context: ?*anyopaque = null,
    enabled: bool = false,
    notify_fn: *const fn (?*anyopaque, Notification) bool = noNotification,

    fn notify(self: Notifier, value: Notification) bool {
        return self.enabled and self.notify_fn(self.context, value);
    }
};

fn noNotification(_: ?*anyopaque, _: Notification) bool {
    return false;
}

pub const Configuration = struct {
    timer: Timer = .{},
    persistence: Persistence = .{},
    notifier: Notifier = .{},
};

pub const MutableProjection = struct {
    title: []u8,
    title_redacted: *bool,
    execution_model: []u8,
    input: []u8,
    input_redacted: *bool,
};

pub const Redaction = struct {
    context: *anyopaque,
    redact_fn: *const fn (*anyopaque, MutableProjection, []const u8) bool,
    contains_fn: *const fn (*anyopaque, []const u8) bool,

    fn redact(
        self: Redaction,
        item: *state.Item,
        additional_credential: []const u8,
    ) bool {
        return self.redact_fn(self.context, .{
            .title = item.title,
            .title_redacted = &item.title_redacted,
            .execution_model = item.execution_model,
            .input = item.input.value,
            .input_redacted = &item.input.redacted,
        }, additional_credential);
    }

    fn contains(self: Redaction, bytes: []const u8) bool {
        return self.contains_fn(self.context, bytes);
    }
};

pub const ExecutionBinding = struct {
    available: bool,
    generation: u64 = 0,
    provider: ?Provider = null,
    model: []const u8 = "",
    automatic_workspace_available: bool,
};

pub const Due = struct {
    id: u64,
    epoch: u64,
    planned_at_unix_seconds: u64,
    triggered_at_unix_seconds: u64,
};

pub const Claim = struct {
    allocator: std.mem.Allocator,
    id: u64,
    planned_at_unix_seconds: u64,
    source: OccurrenceSource,
    title: []u8,
    input: []u8,
    execution_generation: u64,

    pub fn deinit(self: *Claim) void {
        self.allocator.free(self.title);
        self.allocator.free(self.input);
        self.* = undefined;
    }
};

pub const BeginOutcome = union(enum) {
    skipped: u64,
    claimed: Claim,
};

pub const PendingCompletion = struct {
    scheduled_task_id: u64,
    planned_at_unix_seconds: u64,
    source: OccurrenceSource,
    task_id: u64,
};

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    store: state.Store,
    timer: Timer,
    persistence: Persistence,
    persistence_health: PersistenceHealth,
    notifier: Notifier,
    background_available: bool = false,
    changed: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        limits: Limits,
        configuration: Configuration,
    ) Error!Runtime {
        const state_limits: state.Limits = .{
            .max_items = limits.max_items,
            .max_projection_bytes = limits.max_projection_bytes,
        };
        var health: PersistenceHealth =
            if (configuration.persistence.enabled) .ready else .unavailable;
        if (configuration.persistence.restore_failed) health = .read_failed;
        const store = if (health == .ready and
            configuration.persistence.restored_bytes != null)
            persistence.decode(
                allocator,
                configuration.persistence.restored_bytes.?,
                state_limits,
            ) catch restored: {
                health = .corrupt;
                break :restored try state.Store.init(allocator, state_limits);
            }
        else
            try state.Store.init(allocator, state_limits);
        return .{
            .allocator = allocator,
            .store = store,
            .timer = configuration.timer,
            .persistence = configuration.persistence,
            .persistence_health = health,
            .notifier = configuration.notifier,
        };
    }

    pub fn deinit(self: *Runtime) void {
        self.timer.cancelCurrent();
        self.store.deinit();
        self.* = undefined;
    }

    pub fn now(self: *const Runtime) ?u64 {
        return self.timer.now();
    }

    pub fn timerEnabled(self: *const Runtime) bool {
        return self.timer.enabled;
    }

    pub fn persistenceHealth(self: *const Runtime) PersistenceHealth {
        return self.persistence_health;
    }

    pub fn backgroundAvailable(self: *const Runtime) bool {
        return self.background_available;
    }

    pub fn hasEnabled(self: *const Runtime) bool {
        for (self.store.items) |entry| {
            if (entry) |item| if (item.enabled) return true;
        }
        return false;
    }

    /// Product Control remains the single owner of the global revision. This
    /// latch reports both committed Schedule state changes and health changes
    /// caused by a failed/uncertain persistence effect.
    pub fn takeChanged(self: *Runtime) bool {
        const changed = self.changed;
        self.changed = false;
        return changed;
    }

    pub fn setBackgroundAvailable(
        self: *Runtime,
        available: bool,
        binding: ExecutionBinding,
        redaction: Redaction,
    ) bool {
        if (self.background_available == available) return false;
        self.background_available = available;
        self.changed = true;
        if (available) {
            _ = self.rearmNoFail(binding, redaction);
        } else self.timer.cancelCurrent();
        return true;
    }

    pub fn cancelTimer(self: *Runtime) void {
        self.timer.cancelCurrent();
    }

    pub fn create(
        self: *Runtime,
        definition: Definition,
        binding: ExecutionBinding,
        redaction: Redaction,
    ) Error!u64 {
        const current = self.timer.now() orelse return error.ScheduleTimerUnavailable;
        var candidate = try self.store.clone(self.allocator);
        var owned = true;
        defer if (owned) candidate.deinit();
        const id = try candidate.create(definition, current);
        try self.commitCandidate(&candidate, redaction);
        self.replace(&candidate);
        owned = false;
        _ = self.rearmNoFail(binding, redaction);
        return id;
    }

    pub fn update(
        self: *Runtime,
        id: u64,
        expected_epoch: u64,
        definition: Definition,
        binding: ExecutionBinding,
        redaction: Redaction,
    ) Error!void {
        const current = self.timer.now() orelse return error.ScheduleTimerUnavailable;
        var candidate = try self.store.clone(self.allocator);
        var owned = true;
        defer if (owned) candidate.deinit();
        try candidate.update(id, expected_epoch, definition, current);
        try self.commitCandidate(&candidate, redaction);
        self.replace(&candidate);
        owned = false;
        _ = self.rearmNoFail(binding, redaction);
    }

    pub fn setEnabled(
        self: *Runtime,
        id: u64,
        expected_epoch: u64,
        enabled: bool,
        binding: ExecutionBinding,
        redaction: Redaction,
    ) Error!void {
        const current = self.timer.now() orelse return error.ScheduleTimerUnavailable;
        const existing = self.store.find(id) orelse
            return error.UnknownScheduledTask;
        if (expected_epoch == 0 or existing.epoch != expected_epoch)
            return error.ScheduledTaskEpochMismatch;
        if (enabled and existing.health == .needs_attention)
            return error.ScheduledTaskNeedsAttention;
        var candidate = try self.store.clone(self.allocator);
        var owned = true;
        defer if (owned) candidate.deinit();
        try candidate.setEnabled(id, expected_epoch, enabled, current);
        _ = reconcileBindingsInStore(&candidate, binding);
        try self.commitCandidate(&candidate, redaction);
        self.replace(&candidate);
        owned = false;
        _ = self.rearmNoFail(binding, redaction);
    }

    pub fn delete(
        self: *Runtime,
        id: u64,
        expected_epoch: u64,
        binding: ExecutionBinding,
        redaction: Redaction,
    ) Error!void {
        var candidate = try self.store.clone(self.allocator);
        var owned = true;
        defer if (owned) candidate.deinit();
        try candidate.delete(id, expected_epoch);
        try self.commitCandidate(&candidate, redaction);
        self.replace(&candidate);
        owned = false;
        _ = self.rearmNoFail(binding, redaction);
    }

    pub fn epoch(self: *Runtime, id: u64) Error!u64 {
        return (self.store.find(id) orelse return error.UnknownScheduledTask).epoch;
    }

    pub fn validateManual(self: *Runtime, id: u64, expected_epoch: u64) Error!void {
        const item = self.store.find(id) orelse return error.UnknownScheduledTask;
        if (expected_epoch == 0 or item.epoch != expected_epoch)
            return error.ScheduledTaskEpochMismatch;
    }

    pub fn dueNow(
        self: *Runtime,
        binding: ExecutionBinding,
        redaction: Redaction,
    ) ?Due {
        const current = self.timer.now() orelse return null;
        const item = self.store.earliestDue() orelse return null;
        const planned = item.next_run_at_unix_seconds orelse return null;
        if (planned > current) {
            _ = self.rearmNoFail(binding, redaction);
            return null;
        }
        return .{
            .id = item.id,
            .epoch = item.epoch,
            .planned_at_unix_seconds = planned,
            .triggered_at_unix_seconds = current,
        };
    }

    pub fn beginOccurrence(
        self: *Runtime,
        id: u64,
        planned_at: u64,
        triggered_at: u64,
        source: OccurrenceSource,
        previous_task_active: bool,
        redaction: Redaction,
    ) Error!BeginOutcome {
        const current = self.store.find(id) orelse return error.UnknownScheduledTask;
        const previous_task_id = if (current.last_occurrence) |last| last.task_id else 0;
        if (previous_task_id != 0 and previous_task_active) {
            if (source != .timer) return error.PreviousTaskActive;
            var skipped = try self.store.clone(self.allocator);
            var owned = true;
            defer if (owned) skipped.deinit();
            try skipped.markSkipped(
                skipped.find(id).?,
                planned_at,
                triggered_at,
            );
            try self.commitCandidate(&skipped, redaction);
            self.replace(&skipped);
            owned = false;
            _ = self.notifier.notify(.{
                .scheduled_task_id = id,
                .task_id = previous_task_id,
                .title = self.store.find(id).?.title,
                .kind = .skipped,
            });
            return .{ .skipped = previous_task_id };
        }
        var candidate = try self.store.clone(self.allocator);
        var owned = true;
        defer if (owned) candidate.deinit();
        try candidate.claim(candidate.find(id).?, planned_at, triggered_at, source);
        _ = redactStore(&candidate, redaction, "");
        const candidate_item = candidate.find(id).?;
        const title = try self.allocator.dupe(u8, candidate_item.title);
        errdefer self.allocator.free(title);
        const input = try self.allocator.dupe(u8, candidate_item.input.borrowed());
        errdefer self.allocator.free(input);
        try self.commitCandidate(&candidate, redaction);
        self.replace(&candidate);
        owned = false;
        return .{ .claimed = .{
            .allocator = self.allocator,
            .id = id,
            .planned_at_unix_seconds = planned_at,
            .source = source,
            .title = title,
            .input = input,
            .execution_generation = candidate_item.execution_generation,
        } };
    }

    pub fn previousTaskId(self: *Runtime, id: u64) Error!u64 {
        const item = self.store.find(id) orelse return error.UnknownScheduledTask;
        return if (item.last_occurrence) |last| last.task_id else 0;
    }

    pub fn finishSubmitted(
        self: *Runtime,
        claim: *const Claim,
        task_id: u64,
        redaction: Redaction,
    ) Error!void {
        var candidate = try self.store.clone(self.allocator);
        var owned = true;
        defer if (owned) candidate.deinit();
        try candidate.finalizeClaimSubmitted(
            candidate.find(claim.id) orelse return error.UnknownScheduledTask,
            claim.planned_at_unix_seconds,
            claim.source,
            task_id,
        );
        try self.commitCandidate(&candidate, redaction);
        self.replace(&candidate);
        owned = false;
    }

    pub fn finishRejectedNoFail(
        self: *Runtime,
        claim: *const Claim,
        reason: FailureReason,
        task_id: u64,
        redaction: Redaction,
    ) bool {
        var candidate = self.store.clone(self.allocator) catch return false;
        var owned = true;
        defer if (owned) candidate.deinit();
        candidate.finalizeClaimRejected(
            candidate.find(claim.id) orelse return false,
            claim.planned_at_unix_seconds,
            claim.source,
            reason,
            task_id,
        ) catch return false;
        self.commitCandidate(&candidate, redaction) catch return false;
        self.replace(&candidate);
        owned = false;
        _ = self.notifier.notify(.{
            .scheduled_task_id = claim.id,
            .title = self.store.find(claim.id).?.title,
            .kind = .needs_attention,
        });
        return true;
    }

    pub fn nextPendingCompletion(self: *Runtime) ?PendingCompletion {
        for (self.store.items) |*entry| {
            const item = &(entry.* orelse continue);
            for (item.occurrences()) |occurrence| {
                if (occurrence.result != .submitted or occurrence.task_id == 0 or
                    occurrence.notification_sent) continue;
                return .{
                    .scheduled_task_id = item.id,
                    .planned_at_unix_seconds = occurrence.planned_at_unix_seconds,
                    .source = occurrence.source,
                    .task_id = occurrence.task_id,
                };
            }
        }
        return null;
    }

    pub fn finishCompletionNoFail(
        self: *Runtime,
        pending: PendingCompletion,
        outcome: OccurrenceTaskOutcome,
        notification_kind: NotificationKind,
        redaction: Redaction,
    ) bool {
        var candidate = self.store.clone(self.allocator) catch return false;
        var owned = true;
        defer if (owned) candidate.deinit();
        candidate.finalizeOccurrenceTask(
            candidate.find(pending.scheduled_task_id) orelse return false,
            pending.planned_at_unix_seconds,
            pending.source,
            outcome,
        ) catch return false;
        self.commitCandidate(&candidate, redaction) catch return false;
        self.replace(&candidate);
        owned = false;
        const committed = self.store.find(pending.scheduled_task_id) orelse return true;
        _ = self.notifier.notify(.{
            .scheduled_task_id = committed.id,
            .task_id = pending.task_id,
            .title = committed.title,
            .kind = notification_kind,
        });
        return true;
    }

    pub fn reconcileBindingsNoFail(
        self: *Runtime,
        binding: ExecutionBinding,
        redaction: Redaction,
    ) bool {
        if (self.persistence_health != .ready) return false;
        var candidate = self.store.clone(self.allocator) catch return false;
        var owned = true;
        defer if (owned) candidate.deinit();
        if (!reconcileBindingsInStore(&candidate, binding)) return false;
        self.commitCandidate(&candidate, redaction) catch return false;
        self.replace(&candidate);
        owned = false;
        _ = self.rearmNoFail(binding, redaction);
        return true;
    }

    pub fn recoverInterruptedNoFail(self: *Runtime, redaction: Redaction) bool {
        if (self.persistence_health != .ready) return false;
        var candidate = self.store.clone(self.allocator) catch return false;
        var owned = true;
        defer if (owned) candidate.deinit();
        if (!candidate.interruptClaimedOccurrences()) return false;
        self.commitCandidate(&candidate, redaction) catch return false;
        self.replace(&candidate);
        owned = false;
        return true;
    }

    pub fn prepareCredentialRedaction(
        self: *Runtime,
        additional_credential: []const u8,
        redaction: Redaction,
    ) Error!bool {
        if (self.persistence.enabled) switch (self.persistence_health) {
            .ready => {},
            .outcome_unknown => return error.ScheduledTaskPersistenceOutcomeUnknown,
            else => return error.ScheduledTaskPersistenceUnavailable,
        };
        var has_items = false;
        for (self.store.items) |entry| if (entry != null) {
            has_items = true;
            break;
        };
        if (!has_items) return false;
        var candidate = try self.store.clone(self.allocator);
        var owned = true;
        defer if (owned) candidate.deinit();
        if (!redactStore(&candidate, redaction, additional_credential)) return false;
        try self.commitCandidate(&candidate, redaction);
        self.replace(&candidate);
        owned = false;
        return true;
    }

    /// Defense-in-depth scrub for a credential whose final owned copy is
    /// about to leave Product Control. Durable mutations use
    /// `prepareCredentialRedaction`; this method only repairs the live
    /// projection after the durable gate has already succeeded.
    pub fn redactInMemoryNoFail(
        self: *Runtime,
        additional_credential: []const u8,
        redaction: Redaction,
    ) bool {
        return redactStore(&self.store, redaction, additional_credential);
    }

    pub fn rearmNoFail(
        self: *Runtime,
        binding: ExecutionBinding,
        redaction: Redaction,
    ) bool {
        self.timer.cancelCurrent();
        if (!self.background_available or self.persistence_health != .ready or
            !binding.available) return false;
        const item = self.store.earliestDue() orelse return false;
        const due = item.next_run_at_unix_seconds orelse return false;
        if (self.timer.armAt(due)) return false;
        var candidate = self.store.clone(self.allocator) catch return false;
        var owned = true;
        defer if (owned) candidate.deinit();
        candidate.markNeedsAttention(candidate.find(item.id) orelse return false, .timer_unavailable);
        self.commitCandidate(&candidate, redaction) catch return false;
        self.replace(&candidate);
        owned = false;
        return true;
    }

    pub fn writeProjection(
        self: *const Runtime,
        writer: *std.Io.Writer,
        text: TextProjection,
    ) ViewError!void {
        return view.writeProjection(writer, &self.store, text);
    }

    fn commitCandidate(
        self: *Runtime,
        candidate: *state.Store,
        redaction: Redaction,
    ) Error!void {
        switch (self.persistence_health) {
            .ready => {},
            .outcome_unknown => return error.ScheduledTaskPersistenceOutcomeUnknown,
            else => return error.ScheduledTaskPersistenceUnavailable,
        }
        _ = redactStore(candidate, redaction, "");
        const output = try self.allocator.alloc(u8, persistence.max_store_bytes);
        defer self.allocator.free(output);
        const bytes = try persistence.encode(output, candidate);
        if (redaction.contains(bytes)) {
            self.persistence_health = .write_failed;
            self.changed = true;
            return error.ScheduledTaskPersistenceFailed;
        }
        switch (self.persistence.commit(bytes)) {
            .committed => {},
            .failed => {
                self.persistence_health = .write_failed;
                self.changed = true;
                return error.ScheduledTaskPersistenceFailed;
            },
            .outcome_unknown => {
                self.persistence_health = .outcome_unknown;
                self.changed = true;
                return error.ScheduledTaskPersistenceOutcomeUnknown;
            },
        }
    }

    fn replace(self: *Runtime, candidate: *state.Store) void {
        self.store.deinit();
        self.store = candidate.*;
        candidate.* = undefined;
        self.changed = true;
    }
};

pub const testing = if (builtin.is_test) struct {
    pub const max_store_bytes = persistence.max_store_bytes;
    pub const Item = struct {
        id: u64,
        epoch: u64,
        title: []const u8,
        title_redacted: bool,
        input: []const u8,
        enabled: bool,
        health: Health,
        failure_reason: ?FailureReason,
        next_run_at_unix_seconds: ?u64,
    };

    pub fn configure(
        runtime: *Runtime,
        timer: Timer,
        persistence_capability: Persistence,
        persistence_health: PersistenceHealth,
    ) void {
        runtime.timer = timer;
        runtime.persistence = persistence_capability;
        runtime.persistence_health = persistence_health;
    }

    pub fn setPersistenceHealth(
        runtime: *Runtime,
        health: PersistenceHealth,
    ) void {
        runtime.persistence_health = health;
    }

    pub fn item(runtime: *Runtime, id: u64) ?Item {
        const stored = runtime.store.find(id) orelse return null;
        return .{
            .id = stored.id,
            .epoch = stored.epoch,
            .title = stored.title,
            .title_redacted = stored.title_redacted,
            .input = stored.input.borrowed(),
            .enabled = stored.enabled,
            .health = stored.health,
            .failure_reason = stored.failure_reason,
            .next_run_at_unix_seconds = stored.next_run_at_unix_seconds,
        };
    }

    pub fn overwriteInputPrefix(
        runtime: *Runtime,
        id: u64,
        bytes: []const u8,
    ) void {
        const stored = runtime.store.find(id) orelse unreachable;
        std.debug.assert(bytes.len <= stored.input.value.len);
        @memcpy(stored.input.value[0..bytes.len], bytes);
    }
} else struct {};

fn redactStore(
    store: *state.Store,
    redaction: Redaction,
    additional_credential: []const u8,
) bool {
    var changed = false;
    for (store.items) |*entry| {
        const item = &(entry.* orelse continue);
        changed = redaction.redact(item, additional_credential) or changed;
    }
    return changed;
}

fn reconcileBindingsInStore(
    store: *state.Store,
    binding: ExecutionBinding,
) bool {
    var changed = false;
    for (store.items) |*entry| {
        const item = &(entry.* orelse continue);
        if (!item.enabled or item.health != .ready) continue;
        const reason: ?FailureReason = if (!binding.available or
            item.execution_generation != binding.generation or
            binding.provider == null or
            item.execution_provider != binding.provider.? or
            !std.mem.eql(u8, item.execution_model, binding.model))
            .execution_changed
        else if (!binding.automatic_workspace_available)
            .workspace_unavailable
        else
            null;
        if (reason) |failure| {
            store.markNeedsAttention(item, failure);
            changed = true;
        }
    }
    return changed;
}

const TestEffects = struct {
    now: u64 = 100,
    commit_result: PersistenceCommit = .committed,

    fn clock(context: ?*anyopaque) ?u64 {
        const self: *TestEffects = @ptrCast(@alignCast(context.?));
        return self.now;
    }

    fn arm(_: ?*anyopaque, _: u64) bool {
        return true;
    }

    fn cancel(_: ?*anyopaque) void {}

    fn commit(context: ?*anyopaque, _: []const u8) PersistenceCommit {
        const self: *TestEffects = @ptrCast(@alignCast(context.?));
        return self.commit_result;
    }

    fn timer(self: *TestEffects) Timer {
        return .{
            .context = self,
            .enabled = true,
            .now_unix_seconds = clock,
            .arm = arm,
            .cancel = cancel,
        };
    }

    fn persistence(self: *TestEffects) Persistence {
        return .{
            .context = self,
            .enabled = true,
            .commit_fn = commit,
        };
    }
};

fn noRedaction(_: *anyopaque, _: MutableProjection, _: []const u8) bool {
    return false;
}

fn noCredential(_: *anyopaque, _: []const u8) bool {
    return false;
}

fn testRedaction(context: *anyopaque) Redaction {
    return .{
        .context = context,
        .redact_fn = noRedaction,
        .contains_fn = noCredential,
    };
}

fn testBinding() ExecutionBinding {
    return .{
        .available = true,
        .generation = 1,
        .provider = .anthropic,
        .model = "model",
        .automatic_workspace_available = true,
    };
}

fn testDefinition(title: []const u8, input: []const u8) Definition {
    return .{
        .title = title,
        .execution_generation = 1,
        .execution_provider = .anthropic,
        .execution_model = "model",
        .input = input,
        .recurrence = .{ .once = .{ .at_unix_seconds = 200 } },
    };
}

test "occurrence claim owns launch facts across later store replacement" {
    var effects: TestEffects = .{};
    var runtime = try Runtime.init(std.testing.allocator, .{
        .max_items = 2,
        .max_projection_bytes = 4096,
    }, .{
        .timer = effects.timer(),
        .persistence = effects.persistence(),
    });
    defer runtime.deinit();
    const redaction = testRedaction(&effects);
    const id = try runtime.create(
        testDefinition("first", "launch input"),
        testBinding(),
        redaction,
    );
    _ = runtime.takeChanged();
    var claim = switch (try runtime.beginOccurrence(
        id,
        200,
        200,
        .manual,
        false,
        redaction,
    )) {
        .claimed => |value| value,
        .skipped => return error.TestUnexpectedResult,
    };
    defer claim.deinit();
    _ = try runtime.create(
        testDefinition("second", "other input"),
        testBinding(),
        redaction,
    );
    try std.testing.expectEqualStrings("first", claim.title);
    try std.testing.expectEqualStrings("launch input", claim.input);
}

test "persistence health failure remains observable through change latch" {
    var effects: TestEffects = .{ .commit_result = .failed };
    var runtime = try Runtime.init(std.testing.allocator, .{
        .max_items = 1,
        .max_projection_bytes = 4096,
    }, .{
        .timer = effects.timer(),
        .persistence = effects.persistence(),
    });
    defer runtime.deinit();
    try std.testing.expectError(
        error.ScheduledTaskPersistenceFailed,
        runtime.create(
            testDefinition("first", "input"),
            testBinding(),
            testRedaction(&effects),
        ),
    );
    try std.testing.expectEqual(PersistenceHealth.write_failed, runtime.persistenceHealth());
    try std.testing.expect(runtime.takeChanged());
    try std.testing.expect(!runtime.takeChanged());
}
