//! Product Schedule live aggregate.
//!
//! Owns bounded Schedule state, persistence transactions, timer policy and
//! occurrence transitions. Cross-aggregate Task launch and terminal lookup
//! remain callback-scoped Product Control orchestration.

const std = @import("std");
const builtin = @import("builtin");
const models_contract = @import("metawork_product_models_contract");
const state = @import("product_schedule_state");
const persistence = @import("product_schedule_persistence");
const view = @import("product_schedule_view");

pub const Recurrence = state.Recurrence;
pub const Protocol = state.Protocol;
pub const PermissionProfile = state.PermissionProfile;
pub const Definition = state.Definition;
const Occurrence = state.Occurrence;
const OccurrenceSource = state.OccurrenceSource;
pub const TaskOutcome = state.OccurrenceTaskOutcome;
const OccurrenceTaskOutcome = TaskOutcome;
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
pub const PersistenceObservation = enum { before, after, unknown };

pub const Persistence = struct {
    context: ?*anyopaque = null,
    enabled: bool = false,
    restored_bytes: ?[]const u8 = null,
    restore_failed: bool = false,
    commit_fn: *const fn (?*anyopaque, []const u8) PersistenceCommit = unsupportedCommit,
    recover_fn: *const fn (?*anyopaque, []const u8) PersistenceCommit = unsupportedCommit,
    observe_fn: *const fn (
        ?*anyopaque,
        []const u8,
        []const u8,
    ) PersistenceObservation = unsupportedObserve,

    fn commit(self: Persistence, bytes: []const u8) PersistenceCommit {
        if (!self.enabled) return .failed;
        return self.commit_fn(self.context, bytes);
    }

    fn recover(self: Persistence, bytes: []const u8) PersistenceCommit {
        if (!self.enabled) return .failed;
        return self.recover_fn(self.context, bytes);
    }

    fn observe(
        self: Persistence,
        before: []const u8,
        after: []const u8,
    ) PersistenceObservation {
        if (!self.enabled) return .unknown;
        return self.observe_fn(self.context, before, after);
    }

    fn unsupportedCommit(_: ?*anyopaque, _: []const u8) PersistenceCommit {
        return .failed;
    }

    fn unsupportedObserve(
        _: ?*anyopaque,
        _: []const u8,
        _: []const u8,
    ) PersistenceObservation {
        return .unknown;
    }
};

pub const PersistenceHealth = enum {
    unavailable,
    ready,
    read_failed,
    corrupt,
    migration_failed,
    write_failed,
    outcome_unknown,
};

pub const PersistenceRecoveryOutcome = enum {
    recovered,
    unavailable,
    failed,
    outcome_unknown,
};

fn bootstrapStore(
    allocator: std.mem.Allocator,
    limits: state.Limits,
    persistence_capability: Persistence,
    health: *PersistenceHealth,
) Error!state.Store {
    if (health.* != .ready or persistence_capability.restored_bytes == null)
        return state.Store.init(allocator, limits);
    const restored_bytes = persistence_capability.restored_bytes.?;
    const decoded = persistence.decodeForBootstrap(
        allocator,
        restored_bytes,
        limits,
    ) catch {
        health.* = .corrupt;
        return state.Store.init(allocator, limits);
    };
    return switch (decoded) {
        .current => |store| store,
        .migrated => |store_value| migrated: {
            var store = store_value;
            var owned = true;
            defer if (owned) store.deinit();
            const output = allocator.alloc(u8, persistence.max_store_bytes) catch {
                health.* = .migration_failed;
                break :migrated try state.Store.init(allocator, limits);
            };
            defer allocator.free(output);
            const next_bytes = persistence.encode(output, &store) catch {
                health.* = .migration_failed;
                break :migrated try state.Store.init(allocator, limits);
            };
            const committed = switch (persistence_capability.commit(next_bytes)) {
                .committed => true,
                .failed => false,
                .outcome_unknown => switch (persistence_capability.observe(
                    restored_bytes,
                    next_bytes,
                )) {
                    .after => true,
                    .before => false,
                    .unknown => {
                        health.* = .outcome_unknown;
                        break :migrated try state.Store.init(allocator, limits);
                    },
                },
            };
            if (!committed) {
                health.* = .migration_failed;
                break :migrated try state.Store.init(allocator, limits);
            }
            owned = false;
            break :migrated store;
        },
    };
}

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
    binding_model: []u8,
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
            .binding_model = item.bindingModelMutable(),
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
    model_ref: ?models_contract.ModelRef = null,
    source_generation: u64 = 0,
    selection_revision: u64 = 0,
    protocol: ?Protocol = null,
    automatic_workspace_available: bool,
};

const Due = struct {
    id: u64,
    epoch: u64,
    planned_at_unix_seconds: u64,
    triggered_at_unix_seconds: u64,
};

const Claim = struct {
    allocator: std.mem.Allocator,
    id: u64,
    planned_at_unix_seconds: u64,
    source: OccurrenceSource,
    title: []u8,
    input: []u8,
    source_id: []u8,
    model_id: []u8,
    source_generation: u64,
    selection_revision: u64,
    protocol: Protocol,
    permission_profile: PermissionProfile,

    pub fn deinit(self: *Claim) void {
        self.allocator.free(self.title);
        self.allocator.free(self.input);
        self.allocator.free(self.source_id);
        self.allocator.free(self.model_id);
        self.* = undefined;
    }
};

const BeginOutcome = union(enum) {
    skipped: u64,
    claimed: Claim,
};

const PendingCompletion = struct {
    scheduled_task_id: u64,
    planned_at_unix_seconds: u64,
    source: OccurrenceSource,
    task_id: u64,
};

/// Callback-scoped access to the Task aggregate. Schedule owns occurrence
/// transaction order; Product Control retains authority checks and the real
/// Task effects behind this opaque capability. Runtime never retains it.
pub const TaskLaunch = struct {
    title: []const u8,
    input: []const u8,
    model_ref: models_contract.ModelRef,
    source_generation: u64,
    selection_revision: u64,
    protocol: Protocol,
    permission_profile: PermissionProfile,
};

pub const TaskTerminal = struct {
    outcome: TaskOutcome,
    permission_required: bool,
};

pub const TaskLaunchFailure = struct {
    cause: anyerror,
    reason: FailureReason,
    task_id: u64,
};

pub const TaskLaunchOutcome = union(enum) {
    submitted: u64,
    rejected: TaskLaunchFailure,
};

pub const TaskEffects = struct {
    context: *anyopaque,
    has_active_fn: *const fn (*anyopaque, u64) bool,
    launch_fn: *const fn (*anyopaque, TaskLaunch) TaskLaunchOutcome,
    terminal_fn: *const fn (*anyopaque, u64) ?TaskTerminal,

    fn hasActive(self: TaskEffects, task_id: u64) bool {
        return self.has_active_fn(self.context, task_id);
    }

    fn launch(self: TaskEffects, input: TaskLaunch) TaskLaunchOutcome {
        return self.launch_fn(self.context, input);
    }

    fn terminal(self: TaskEffects, task_id: u64) ?TaskTerminal {
        return self.terminal_fn(self.context, task_id);
    }
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
        const store = try bootstrapStore(
            allocator,
            state_limits,
            configuration.persistence,
            &health,
        );
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

    pub fn persistenceRecoveryAvailable(self: *const Runtime) bool {
        if (!self.persistence.enabled) return false;
        return switch (self.persistence_health) {
            .read_failed, .corrupt, .write_failed, .outcome_unknown => true,
            .unavailable, .ready, .migration_failed => false,
        };
    }

    pub fn recoverPersistence(
        self: *Runtime,
        redaction: Redaction,
    ) PersistenceRecoveryOutcome {
        if (!self.persistenceRecoveryAvailable()) return .unavailable;
        var candidate = self.store.clone(self.allocator) catch return .failed;
        var owned = true;
        defer if (owned) candidate.deinit();
        _ = redactStore(&candidate, redaction, "");
        const output = self.allocator.alloc(u8, persistence.max_store_bytes) catch
            return .failed;
        defer self.allocator.free(output);
        const bytes = persistence.encode(output, &candidate) catch return .failed;
        if (redaction.contains(bytes)) return .failed;
        switch (self.persistence.recover(bytes)) {
            .committed => {
                self.persistence_health = .ready;
                self.replace(&candidate);
                owned = false;
                return .recovered;
            },
            .failed => return .failed,
            .outcome_unknown => {
                self.persistence_health = .outcome_unknown;
                self.changed = true;
                return .outcome_unknown;
            },
        }
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

    pub fn runNow(
        self: *Runtime,
        id: u64,
        expected_epoch: u64,
        redaction: Redaction,
        tasks: TaskEffects,
    ) anyerror!u64 {
        try self.validateManual(id, expected_epoch);
        const current = self.timer.now() orelse return error.ScheduleTimerUnavailable;
        return self.triggerOccurrence(
            id,
            current,
            current,
            .manual,
            tasks,
            redaction,
        );
    }

    pub fn onTimer(
        self: *Runtime,
        binding: ExecutionBinding,
        redaction: Redaction,
        tasks: TaskEffects,
    ) void {
        const due = self.dueNow(binding, redaction) orelse return;
        _ = self.triggerOccurrence(
            due.id,
            due.planned_at_unix_seconds,
            due.triggered_at_unix_seconds,
            .timer,
            tasks,
            redaction,
        ) catch {};
        _ = self.rearmNoFail(binding, redaction);
    }

    pub fn reconcileNoFail(
        self: *Runtime,
        binding: ExecutionBinding,
        redaction: Redaction,
        tasks: TaskEffects,
    ) bool {
        var changed = self.reconcileBindingsNoFail(binding, redaction);
        changed = self.reconcileCompletionNoFail(tasks, redaction) or changed;
        return changed;
    }

    pub fn refreshBindingNoFail(
        self: *Runtime,
        binding: ExecutionBinding,
        redaction: Redaction,
    ) bool {
        return self.reconcileBindingsNoFail(binding, redaction);
    }

    pub fn epoch(self: *Runtime, id: u64) Error!u64 {
        return (self.store.find(id) orelse return error.UnknownScheduledTask).epoch;
    }

    fn validateManual(self: *Runtime, id: u64, expected_epoch: u64) Error!void {
        const item = self.store.find(id) orelse return error.UnknownScheduledTask;
        if (expected_epoch == 0 or item.epoch != expected_epoch)
            return error.ScheduledTaskEpochMismatch;
    }

    fn dueNow(
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

    fn beginOccurrence(
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
        const current_binding = switch (candidate_item.bindingView()) {
            .current => |binding| binding,
            .migration_required => return error.InvalidSchedule,
        };
        const source_id = try self.allocator.dupe(
            u8,
            current_binding.model_ref.source_id,
        );
        errdefer self.allocator.free(source_id);
        const model_id = try self.allocator.dupe(
            u8,
            current_binding.model_ref.model_id,
        );
        errdefer self.allocator.free(model_id);
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
            .source_id = source_id,
            .model_id = model_id,
            .source_generation = current_binding.source_generation,
            .selection_revision = current_binding.selection_revision,
            .protocol = current_binding.protocol,
            .permission_profile = candidate_item.permission_profile,
        } };
    }

    fn previousTaskId(self: *Runtime, id: u64) Error!u64 {
        const item = self.store.find(id) orelse return error.UnknownScheduledTask;
        return if (item.last_occurrence) |last| last.task_id else 0;
    }

    fn finishSubmitted(
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

    fn finishRejectedNoFail(
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

    fn nextPendingCompletion(self: *Runtime) ?PendingCompletion {
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

    fn finishCompletionNoFail(
        self: *Runtime,
        pending: PendingCompletion,
        terminal: TaskTerminal,
        redaction: Redaction,
    ) bool {
        var candidate = self.store.clone(self.allocator) catch return false;
        var owned = true;
        defer if (owned) candidate.deinit();
        candidate.finalizeOccurrenceTask(
            candidate.find(pending.scheduled_task_id) orelse return false,
            pending.planned_at_unix_seconds,
            pending.source,
            terminal.outcome,
            if (terminal.permission_required) .permission_required else null,
        ) catch return false;
        self.commitCandidate(&candidate, redaction) catch return false;
        self.replace(&candidate);
        owned = false;
        const committed = self.store.find(pending.scheduled_task_id) orelse return true;
        _ = self.notifier.notify(.{
            .scheduled_task_id = committed.id,
            .task_id = pending.task_id,
            .title = committed.title,
            .kind = if (terminal.permission_required)
                .needs_attention
            else if (terminal.outcome == .completed)
                .completed
            else
                .failed,
        });
        return true;
    }

    fn triggerOccurrence(
        self: *Runtime,
        id: u64,
        planned_at_unix_seconds: u64,
        triggered_at_unix_seconds: u64,
        source: OccurrenceSource,
        tasks: TaskEffects,
        redaction: Redaction,
    ) anyerror!u64 {
        const previous_task_id = try self.previousTaskId(id);
        const previous_task_active = previous_task_id != 0 and
            tasks.hasActive(previous_task_id);
        const begin = try self.beginOccurrence(
            id,
            planned_at_unix_seconds,
            triggered_at_unix_seconds,
            source,
            previous_task_active,
            redaction,
        );
        var claim = switch (begin) {
            .skipped => |task_id| return task_id,
            .claimed => |value| value,
        };
        defer claim.deinit();
        const task_id = switch (tasks.launch(.{
            .title = claim.title,
            .input = claim.input,
            .model_ref = .{
                .source_id = claim.source_id,
                .model_id = claim.model_id,
            },
            .source_generation = claim.source_generation,
            .selection_revision = claim.selection_revision,
            .protocol = claim.protocol,
            .permission_profile = claim.permission_profile,
        })) {
            .submitted => |task_id| task_id,
            .rejected => |failure| {
                _ = self.finishRejectedNoFail(
                    &claim,
                    failure.reason,
                    failure.task_id,
                    redaction,
                );
                return failure.cause;
            },
        };
        try self.finishSubmitted(&claim, task_id, redaction);
        return task_id;
    }

    fn reconcileCompletionNoFail(
        self: *Runtime,
        tasks: TaskEffects,
        redaction: Redaction,
    ) bool {
        const pending = self.nextPendingCompletion() orelse return false;
        const terminal = tasks.terminal(pending.task_id) orelse return false;
        return self.finishCompletionNoFail(
            pending,
            terminal,
            redaction,
        );
    }

    fn reconcileBindingsNoFail(
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
        binding: state.Binding,
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
            .binding = stored.bindingView(),
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
        const current = switch (item.bindingView()) {
            .current => |value| value,
            .migration_required => {
                store.markNeedsAttention(item, .binding_migration_required);
                changed = true;
                continue;
            },
        };
        const exact_model = if (binding.model_ref) |model_ref|
            std.mem.eql(u8, current.model_ref.source_id, model_ref.source_id) and
                std.mem.eql(u8, current.model_ref.model_id, model_ref.model_id)
        else
            false;
        const reason: ?FailureReason = if (!binding.available or
            !exact_model or
            current.source_generation != binding.source_generation or
            current.selection_revision != binding.selection_revision or
            binding.protocol == null or
            current.protocol != binding.protocol.?)
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
    restored_bytes: ?[]const u8 = null,
    commit_result: PersistenceCommit = .committed,
    recovery_result: PersistenceCommit = .committed,
    observation: PersistenceObservation = .unknown,
    commits: usize = 0,
    recoveries: usize = 0,
    notification_kind: ?NotificationKind = null,
    notification_task_id: u64 = 0,

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
        self.commits += 1;
        return self.commit_result;
    }

    fn observe(
        context: ?*anyopaque,
        _: []const u8,
        _: []const u8,
    ) PersistenceObservation {
        const self: *TestEffects = @ptrCast(@alignCast(context.?));
        return self.observation;
    }

    fn recover(context: ?*anyopaque, _: []const u8) PersistenceCommit {
        const self: *TestEffects = @ptrCast(@alignCast(context.?));
        self.recoveries += 1;
        return self.recovery_result;
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
            .restored_bytes = self.restored_bytes,
            .commit_fn = commit,
            .recover_fn = recover,
            .observe_fn = observe,
        };
    }

    fn notify(context: ?*anyopaque, notification: Notification) bool {
        const self: *TestEffects = @ptrCast(@alignCast(context.?));
        self.notification_kind = notification.kind;
        self.notification_task_id = notification.task_id;
        return true;
    }

    fn notifier(self: *TestEffects) Notifier {
        return .{
            .context = self,
            .enabled = true,
            .notify_fn = notify,
        };
    }
};

const TestTasks = struct {
    launched_profile: ?PermissionProfile = null,
    terminal: ?TaskTerminal = null,

    fn hasActive(_: *anyopaque, _: u64) bool {
        return false;
    }

    fn launch(context: *anyopaque, input: TaskLaunch) TaskLaunchOutcome {
        const self: *TestTasks = @ptrCast(@alignCast(context));
        self.launched_profile = input.permission_profile;
        return .{ .submitted = 42 };
    }

    fn readTerminal(context: *anyopaque, _: u64) ?TaskTerminal {
        const self: *TestTasks = @ptrCast(@alignCast(context));
        return self.terminal;
    }

    fn effects(self: *TestTasks) TaskEffects {
        return .{
            .context = self,
            .has_active_fn = hasActive,
            .launch_fn = launch,
            .terminal_fn = readTerminal,
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
        .model_ref = .{ .source_id = "metask:test", .model_id = "model" },
        .source_generation = 1,
        .selection_revision = 1,
        .protocol = .anthropic_messages,
        .automatic_workspace_available = true,
    };
}

fn testDefinition(title: []const u8, input: []const u8) Definition {
    return .{
        .title = title,
        .binding = .{ .current = .{
            .model_ref = .{ .source_id = "metask:test", .model_id = "model" },
            .source_generation = 1,
            .selection_revision = 1,
            .protocol = .anthropic_messages,
        } },
        .permission_profile = .approval_required,
        .input = input,
        .recurrence = .{ .once = .{ .at_unix_seconds = 200 } },
    };
}

const legacy_schedule_bytes =
    "{\"schema_version\":1,\"next_id\":8,\"items\":[{\"id\":7,\"epoch\":3,\"title\":\"Legacy schedule\",\"execution_generation\":19,\"execution_protocol\":\"anthropic_messages\",\"execution_model\":\"legacy-model\",\"permission_profile\":\"approval_required\",\"input\":{\"kind\":\"text\",\"text\":\"inspect\"},\"recurrence\":{\"kind\":\"once\",\"at_unix_seconds\":200},\"enabled\":true,\"health\":\"ready\",\"failure_reason\":null,\"next_run_at_unix_seconds\":200,\"occurrences\":[]}]}";

test "schema 1 bootstrap persists a disabled explicit-rebind definition" {
    var effects: TestEffects = .{ .restored_bytes = legacy_schedule_bytes };
    var runtime = try Runtime.init(std.testing.allocator, .{
        .max_items = 2,
        .max_projection_bytes = 4096,
    }, .{
        .timer = effects.timer(),
        .persistence = effects.persistence(),
    });
    defer runtime.deinit();

    try std.testing.expectEqual(PersistenceHealth.ready, runtime.persistenceHealth());
    try std.testing.expectEqual(@as(usize, 1), effects.commits);
    const item = testing.item(&runtime, 7).?;
    try std.testing.expect(!item.enabled);
    try std.testing.expectEqual(Health.needs_attention, item.health);
    try std.testing.expectEqual(
        FailureReason.binding_migration_required,
        item.failure_reason.?,
    );
    switch (item.binding) {
        .migration_required => |legacy| {
            try std.testing.expectEqual(@as(u64, 19), legacy.execution_generation);
            try std.testing.expectEqualStrings("legacy-model", legacy.model);
        },
        .current => return error.TestUnexpectedResult,
    }

    try runtime.update(
        7,
        3,
        testDefinition("Rebound schedule", "inspect"),
        testBinding(),
        testRedaction(&effects),
    );
    const rebound = testing.item(&runtime, 7).?;
    try std.testing.expect(rebound.enabled);
    try std.testing.expectEqual(Health.ready, rebound.health);
    try std.testing.expect(rebound.failure_reason == null);
    try std.testing.expectEqual(@as(u64, 4), rebound.epoch);
    switch (rebound.binding) {
        .current => |binding| try std.testing.expectEqualStrings(
            "metask:test",
            binding.model_ref.source_id,
        ),
        .migration_required => return error.TestUnexpectedResult,
    }
}

test "schema 1 bootstrap fails closed around migration commit certainty" {
    const limits: Limits = .{ .max_items = 2, .max_projection_bytes = 4096 };

    var failed_effects: TestEffects = .{
        .restored_bytes = legacy_schedule_bytes,
        .commit_result = .failed,
    };
    var failed = try Runtime.init(
        std.testing.allocator,
        limits,
        .{ .persistence = failed_effects.persistence() },
    );
    defer failed.deinit();
    try std.testing.expectEqual(PersistenceHealth.migration_failed, failed.persistenceHealth());
    try std.testing.expect(testing.item(&failed, 7) == null);
    try std.testing.expect(!failed.persistenceRecoveryAvailable());

    var before_effects: TestEffects = .{
        .restored_bytes = legacy_schedule_bytes,
        .commit_result = .outcome_unknown,
        .observation = .before,
    };
    var before = try Runtime.init(
        std.testing.allocator,
        limits,
        .{ .persistence = before_effects.persistence() },
    );
    defer before.deinit();
    try std.testing.expectEqual(PersistenceHealth.migration_failed, before.persistenceHealth());
    try std.testing.expect(testing.item(&before, 7) == null);

    var after_effects: TestEffects = .{
        .restored_bytes = legacy_schedule_bytes,
        .commit_result = .outcome_unknown,
        .observation = .after,
    };
    var after = try Runtime.init(
        std.testing.allocator,
        limits,
        .{ .persistence = after_effects.persistence() },
    );
    defer after.deinit();
    try std.testing.expectEqual(PersistenceHealth.ready, after.persistenceHealth());
    try std.testing.expect(testing.item(&after, 7) != null);

    var unknown_effects: TestEffects = .{
        .restored_bytes = legacy_schedule_bytes,
        .commit_result = .outcome_unknown,
    };
    var unknown = try Runtime.init(
        std.testing.allocator,
        limits,
        .{ .persistence = unknown_effects.persistence() },
    );
    defer unknown.deinit();
    try std.testing.expectEqual(PersistenceHealth.outcome_unknown, unknown.persistenceHealth());
    try std.testing.expect(testing.item(&unknown, 7) == null);
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

test "selection revision prevents default-binding ABA from launching" {
    var effects: TestEffects = .{};
    var runtime = try Runtime.init(std.testing.allocator, .{
        .max_items = 1,
        .max_projection_bytes = 4096,
    }, .{
        .timer = effects.timer(),
        .persistence = effects.persistence(),
    });
    defer runtime.deinit();
    const redaction = testRedaction(&effects);
    const id = try runtime.create(
        testDefinition("ABA", "inspect"),
        testBinding(),
        redaction,
    );
    var changed_binding = testBinding();
    changed_binding.selection_revision = 3;
    try std.testing.expect(runtime.refreshBindingNoFail(changed_binding, redaction));
    const item = testing.item(&runtime, id).?;
    try std.testing.expect(!item.enabled);
    try std.testing.expectEqual(Health.needs_attention, item.health);
    try std.testing.expectEqual(FailureReason.execution_changed, item.failure_reason.?);
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

test "explicit Schedule recovery preserves memory and only reopens committed persistence" {
    var effects: TestEffects = .{};
    var runtime = try Runtime.init(std.testing.allocator, .{
        .max_items = 1,
        .max_projection_bytes = 4096,
    }, .{
        .timer = effects.timer(),
        .persistence = effects.persistence(),
    });
    defer runtime.deinit();
    const id = try runtime.create(
        testDefinition("retained", "current memory"),
        testBinding(),
        testRedaction(&effects),
    );
    testing.setPersistenceHealth(&runtime, .corrupt);
    try std.testing.expect(runtime.persistenceRecoveryAvailable());

    effects.recovery_result = .failed;
    try std.testing.expectEqual(
        PersistenceRecoveryOutcome.failed,
        runtime.recoverPersistence(testRedaction(&effects)),
    );
    try std.testing.expectEqual(PersistenceHealth.corrupt, runtime.persistenceHealth());
    try std.testing.expect(testing.item(&runtime, id) != null);

    effects.recovery_result = .outcome_unknown;
    try std.testing.expectEqual(
        PersistenceRecoveryOutcome.outcome_unknown,
        runtime.recoverPersistence(testRedaction(&effects)),
    );
    try std.testing.expectEqual(PersistenceHealth.outcome_unknown, runtime.persistenceHealth());
    try std.testing.expect(testing.item(&runtime, id) != null);

    effects.recovery_result = .committed;
    try std.testing.expectEqual(
        PersistenceRecoveryOutcome.recovered,
        runtime.recoverPersistence(testRedaction(&effects)),
    );
    try std.testing.expectEqual(PersistenceHealth.ready, runtime.persistenceHealth());
    try std.testing.expect(testing.item(&runtime, id) != null);
    try std.testing.expectEqual(@as(usize, 3), effects.recoveries);
}

test "permission-required scheduled occurrence stops without waiting for UI" {
    var effects: TestEffects = .{};
    var tasks: TestTasks = .{};
    var runtime = try Runtime.init(std.testing.allocator, .{
        .max_items = 1,
        .max_projection_bytes = 4096,
    }, .{
        .timer = effects.timer(),
        .persistence = effects.persistence(),
        .notifier = effects.notifier(),
    });
    defer runtime.deinit();
    const redaction = testRedaction(&effects);
    var definition = testDefinition("unattended", "inspect");
    definition.permission_profile = .full_access;
    const id = try runtime.create(definition, testBinding(), redaction);

    try std.testing.expectEqual(
        @as(u64, 42),
        try runtime.runNow(id, 1, redaction, tasks.effects()),
    );
    try std.testing.expectEqual(
        PermissionProfile.full_access,
        tasks.launched_profile.?,
    );
    tasks.terminal = .{
        .outcome = .stopped,
        .permission_required = true,
    };
    try std.testing.expect(runtime.reconcileNoFail(
        testBinding(),
        redaction,
        tasks.effects(),
    ));
    const item = testing.item(&runtime, id).?;
    try std.testing.expectEqual(Health.needs_attention, item.health);
    try std.testing.expectEqual(
        FailureReason.permission_required,
        item.failure_reason.?,
    );
    try std.testing.expectEqual(
        NotificationKind.needs_attention,
        effects.notification_kind.?,
    );
    try std.testing.expectEqual(@as(u64, 42), effects.notification_task_id);
}
