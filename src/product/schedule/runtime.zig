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

const preflight_retry_seconds: u64 = 60;

pub const Recurrence = state.Recurrence;
pub const LocalRecurrence = state.LocalRecurrence;
pub const calendarDayMask = state.calendarDayMask;
pub const TimeZone = state.TimeZone;
pub const CalendarFrequency = state.CalendarFrequency;
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

pub const Persistence = struct {
    context: ?*anyopaque = null,
    enabled: bool = false,
    restored_bytes: ?[]const u8 = null,
    restore_failed: bool = false,
    commit_fn: *const fn (?*anyopaque, []const u8) PersistenceCommit = unsupportedCommit,
    recover_fn: *const fn (?*anyopaque, []const u8) PersistenceCommit = unsupportedCommit,

    fn commit(self: Persistence, bytes: []const u8) PersistenceCommit {
        if (!self.enabled) return .failed;
        return self.commit_fn(self.context, bytes);
    }

    fn recover(self: Persistence, bytes: []const u8) PersistenceCommit {
        if (!self.enabled) return .failed;
        return self.recover_fn(self.context, bytes);
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
    return persistence.decode(
        allocator,
        persistence_capability.restored_bytes.?,
        limits,
    ) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (!try persistence.isRetiredStore(allocator, persistence_capability.restored_bytes.?)) {
            health.* = .corrupt;
            return state.Store.init(allocator, limits);
        }
        var empty = try state.Store.init(allocator, limits);
        errdefer empty.deinit();
        const output = try allocator.alloc(u8, persistence.max_store_bytes);
        defer allocator.free(output);
        const bytes = try persistence.encode(output, &empty);
        health.* = switch (persistence_capability.recover(bytes)) {
            .committed => .ready,
            .failed => .write_failed,
            .outcome_unknown => .outcome_unknown,
        };
        return empty;
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

pub const ModelBinding = state.Binding;
pub const BindingAvailability = enum { ready, unavailable, invalid };

/// Callback-scoped per-definition authority; never a global model binding.
pub const ExecutionBinding = struct {
    available: bool,
    automatic_workspace_available: bool,
    context: ?*anyopaque = null,
    validate_fn: *const fn (?*anyopaque, ModelBinding) BindingAvailability = unavailableBinding,

    fn status(self: ExecutionBinding, binding: ModelBinding) BindingAvailability {
        return self.validate_fn(self.context, binding);
    }
};

fn unavailableBinding(_: ?*anyopaque, _: ModelBinding) BindingAvailability {
    return .unavailable;
}

const Due = struct {
    id: u64,
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
    protocol: Protocol,
    permission_profile: PermissionProfile,
    completion: ?state.Store,

    pub fn deinit(self: *Claim) void {
        if (self.completion) |*candidate| candidate.deinit();
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

const CompletionResolution = struct {
    pending: PendingCompletion,
    outcome: OccurrenceTaskOutcome,
    permission_required: bool,
};

/// Callback-scoped access to the Task aggregate. Schedule owns occurrence
/// transaction order; Product Control retains authority checks and the real
/// Task effects behind this opaque capability. Runtime never retains it.
pub const TaskLaunch = struct {
    title: []const u8,
    input: []const u8,
    model_ref: models_contract.ModelRef,
    source_generation: u64,
    protocol: Protocol,
    permission_profile: PermissionProfile,
};

pub const TaskTerminal = struct {
    outcome: TaskOutcome,
    permission_required: bool,
};

pub const TaskObservation = union(enum) {
    pending,
    unavailable,
    terminal: TaskTerminal,
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

/// Causes are returned to the caller unchanged; Schedule branches only on
/// these admission categories, never on another aggregate's error names.
pub const TaskPreflight = union(enum) { ready, wait, retry: anyerror, rejected: anyerror };

pub const TaskEffects = struct {
    context: *anyopaque,
    has_active_fn: *const fn (*anyopaque, u64) bool,
    preflight_fn: *const fn (*anyopaque, TaskLaunch) TaskPreflight,
    launch_fn: *const fn (*anyopaque, TaskLaunch) TaskLaunchOutcome,
    observe_fn: *const fn (*anyopaque, u64) TaskObservation,

    fn hasActive(self: TaskEffects, task_id: u64) bool {
        return self.has_active_fn(self.context, task_id);
    }

    fn launch(self: TaskEffects, input: TaskLaunch) TaskLaunchOutcome {
        return self.launch_fn(self.context, input);
    }

    fn observe(self: TaskEffects, task_id: u64) TaskObservation {
        return self.observe_fn(self.context, task_id);
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
    /// Result of this reconciliation pass, including failures before persistence.
    completion_confirmation_failed_task: ?u64 = null,

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

    pub fn resolveLocalRecurrence(self: *Runtime, input: LocalRecurrence, id: ?u64) Error!Recurrence {
        const now_unix_seconds = self.timer.now() orelse return error.ScheduleTimerUnavailable;
        const previous = if (id) |item_id|
            (self.store.find(item_id) orelse return error.UnknownScheduledTask).recurrence
        else
            null;
        return input.resolve(now_unix_seconds, previous);
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
            .unavailable, .ready => false,
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
        _ = candidate.interruptClaimedOccurrences();
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
        _ = reconcileBindingsInStore(&candidate, binding);
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
    ) Error!bool {
        const current = self.timer.now() orelse return error.ScheduleTimerUnavailable;
        const existing = self.store.find(id) orelse
            return error.UnknownScheduledTask;
        if (expected_epoch == 0 or existing.epoch != expected_epoch)
            return error.ScheduledTaskEpochMismatch;
        if (existing.health == .needs_attention)
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
        return self.store.find(id).?.enabled;
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
        ) catch |err| {
            if (err == error.ScheduledOccurrenceCapacity)
                self.stopForOccurrenceCapacity(id, redaction);
            return err;
        };
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
        ) catch |err| {
            if (err == error.ScheduledOccurrenceCapacity) {
                self.stopForOccurrenceCapacity(due.id, redaction);
            } else if (err == error.ScheduleAdmissionWaiting) {
                self.store.find(due.id).?.waiting_for_task_history = true;
            } else {
                const item = self.store.find(due.id).?;
                const rejected = if (item.last_occurrence) |occurrence|
                    occurrence.result == .rejected and occurrence.source == .timer and
                        occurrence.planned_at_unix_seconds == due.planned_at_unix_seconds
                else
                    false;
                // A confirmed rejection consumed this occurrence. Rearm for
                // other definitions, but never replay an unclaimed due point.
                if (self.persistence_health != .ready or
                    (!rejected and item.preflight_retry_at_unix_seconds == null))
                {
                    self.timer.cancelCurrent();
                    return;
                }
            }
        };
        _ = self.rearmNoFail(binding, redaction);
    }

    pub fn hasTaskHistoryWaits(self: *const Runtime) bool {
        for (self.store.items) |*entry| {
            if (entry.*) |*item| if (item.waiting_for_task_history) return true;
        }
        return false;
    }

    /// Only release waits established before a claim by the Task history writer.
    pub fn releaseTaskHistoryWaits(self: *Runtime) bool {
        var released = false;
        for (self.store.items) |*entry| {
            if (entry.*) |*item| if (item.waiting_for_task_history) {
                item.waiting_for_task_history = false;
                released = true;
            };
        }
        return released;
    }

    pub fn reconcileNoFail(
        self: *Runtime,
        binding: ExecutionBinding,
        redaction: Redaction,
        tasks: TaskEffects,
    ) bool {
        self.completion_confirmation_failed_task = null;
        var changed = self.reconcileBindingsNoFail(binding, redaction);
        changed = self.reconcileCompletionNoFail(tasks, redaction) or changed;
        return changed;
    }

    pub fn refreshBindingNoFail(
        self: *Runtime,
        binding: ExecutionBinding,
        redaction: Redaction,
    ) bool {
        for (self.store.items) |*entry| {
            if (entry.*) |*item| item.preflight_retry_at_unix_seconds = null;
        }
        return self.reconcileBindingsNoFail(binding, redaction);
    }

    pub fn bindingAt(self: *Runtime, id: u64, expected_epoch: u64) Error!ModelBinding {
        const item = self.store.find(id) orelse return error.UnknownScheduledTask;
        if (expected_epoch == 0 or item.epoch != expected_epoch) return error.ScheduledTaskEpochMismatch;
        return item.bindingView();
    }

    pub fn epoch(self: *Runtime, id: u64) Error!u64 {
        return (self.store.find(id) orelse return error.UnknownScheduledTask).epoch;
    }

    fn validateManual(self: *Runtime, id: u64, expected_epoch: u64) Error!void {
        const item = self.store.find(id) orelse return error.UnknownScheduledTask;
        if (expected_epoch == 0 or item.epoch != expected_epoch)
            return error.ScheduledTaskEpochMismatch;
        if (item.health == .needs_attention)
            return error.ScheduledTaskNeedsAttention;
    }

    fn dueNow(
        self: *Runtime,
        binding: ExecutionBinding,
        redaction: Redaction,
    ) ?Due {
        if (!self.background_available or self.persistence_health != .ready or !binding.available) {
            self.timer.cancelCurrent();
            return null;
        }
        const current = self.timer.now() orelse return null;
        const item = self.earliestReady(binding) orelse return null;
        if (timerDueAt(item) > current) {
            _ = self.rearmNoFail(binding, redaction);
            return null;
        }
        return .{
            .id = item.id,
            .planned_at_unix_seconds = (item.recurrence.lastAtOrBefore(current) catch return null) orelse return null,
            .triggered_at_unix_seconds = current,
        };
    }

    fn beginOccurrence(
        self: *Runtime,
        id: u64,
        planned_at: u64,
        triggered_at: u64,
        source: OccurrenceSource,
        blocking_task_id: u64,
        redaction: Redaction,
    ) Error!BeginOutcome {
        _ = self.store.find(id) orelse return error.UnknownScheduledTask;
        if (blocking_task_id != 0) {
            if (source != .timer) return error.PreviousTaskActive;
            var skipped = try self.store.clone(self.allocator);
            var owned = true;
            defer if (owned) skipped.deinit();
            try skipped.markSkipped(
                skipped.find(id).?,
                planned_at,
                triggered_at,
                blocking_task_id,
            );
            try self.commitCandidate(&skipped, redaction);
            self.replace(&skipped);
            owned = false;
            _ = self.notifier.notify(.{
                .scheduled_task_id = id,
                .task_id = blocking_task_id,
                .title = self.store.find(id).?.title,
                .kind = .skipped,
            });
            return .{ .skipped = blocking_task_id };
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
        const current_binding = candidate_item.bindingView();
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
        // Reserve the external-result state before committing the claim.
        // No allocation failure may leave a claim that was never launched.
        var completion = try candidate.clone(self.allocator);
        errdefer completion.deinit();
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
            .protocol = current_binding.protocol,
            .permission_profile = candidate_item.permission_profile,
            .completion = completion,
        } };
    }

    fn activeTaskId(self: *Runtime, id: u64, tasks: TaskEffects) Error!u64 {
        const item = self.store.find(id) orelse return error.UnknownScheduledTask;
        var index = item.occurrence_count;
        while (index != 0) {
            index -= 1;
            const occurrence = item.occurrence_history[index];
            if (occurrence.task_id != 0 and tasks.hasActive(occurrence.task_id))
                return occurrence.task_id;
        }
        return 0;
    }

    fn stopForOccurrenceCapacity(self: *Runtime, id: u64, redaction: Redaction) void {
        self.timer.cancelCurrent();
        var candidate = self.store.clone(self.allocator) catch {
            self.persistence_health = .write_failed;
            self.changed = true;
            return;
        };
        var owned = true;
        defer if (owned) candidate.deinit();
        candidate.markNeedsAttention(candidate.find(id) orelse return, .capacity_reached);
        self.commitCandidate(&candidate, redaction) catch {
            if (self.persistence_health == .ready) {
                self.persistence_health = .write_failed;
                self.changed = true;
            }
            return;
        };
        self.replace(&candidate);
        owned = false;
    }

    fn retainExternalResult(
        self: *Runtime,
        candidate: *state.Store,
        redaction: Redaction,
    ) bool {
        var committed = true;
        self.commitCandidate(candidate, redaction) catch {
            committed = false;
            // The Task effect has already happened and cannot be rolled back.
            // Retain its identity in memory while persistence health keeps all
            // further automatic triggers fail closed.
            if (self.persistence_health == .ready) {
                self.persistence_health = .write_failed;
                self.changed = true;
            }
            self.timer.cancelCurrent();
        };
        self.replace(candidate);
        return committed;
    }

    /// Prevent a successor from replacing the terminal observed for this occurrence.
    pub fn hasPendingSubmittedOccurrence(self: *const Runtime, task_id: u64) bool {
        for (self.store.items) |entry| {
            const item = entry orelse continue;
            for (item.occurrences()) |occurrence| {
                if (occurrence.task_id == task_id and occurrence.result == .submitted and !occurrence.notification_sent) return true;
            }
        }
        return false;
    }

    pub const ContinuationConfirmation = enum { confirmed, pending, failed };

    /// Observe after reconciliation, for a continuation already gated by an occurrence.
    pub fn continuationConfirmation(self: *const Runtime, task_id: u64) ContinuationConfirmation {
        if (self.persistence_health != .ready) return .failed;
        if (!self.hasPendingSubmittedOccurrence(task_id)) return .confirmed;
        return if (self.completion_confirmation_failed_task == task_id) .failed else .pending;
    }

    fn nextCompletionResolution(
        self: *Runtime,
        tasks: TaskEffects,
    ) ?CompletionResolution {
        for (self.store.items) |*entry| {
            const item = &(entry.* orelse continue);
            for (item.occurrences()) |occurrence| {
                if (occurrence.result != .submitted or occurrence.task_id == 0 or
                    occurrence.notification_sent) continue;
                const pending: PendingCompletion = .{
                    .scheduled_task_id = item.id,
                    .planned_at_unix_seconds = occurrence.planned_at_unix_seconds,
                    .source = occurrence.source,
                    .task_id = occurrence.task_id,
                };
                switch (tasks.observe(occurrence.task_id)) {
                    .pending => continue,
                    .unavailable => return .{
                        .pending = pending,
                        .outcome = .unavailable,
                        .permission_required = false,
                    },
                    .terminal => |terminal| return .{
                        .pending = pending,
                        .outcome = terminal.outcome,
                        .permission_required = terminal.permission_required,
                    },
                }
            }
        }
        return null;
    }

    fn finishCompletionNoFail(
        self: *Runtime,
        resolution: CompletionResolution,
        redaction: Redaction,
    ) bool {
        const pending = resolution.pending;
        var candidate = self.store.clone(self.allocator) catch return false;
        var owned = true;
        defer if (owned) candidate.deinit();
        const needs_attention = candidate.finalizeOccurrenceTask(
            candidate.find(pending.scheduled_task_id) orelse return false,
            pending.planned_at_unix_seconds,
            pending.source,
            pending.task_id,
            resolution.outcome,
            if (resolution.permission_required) .permission_required else null,
        ) catch return false;
        self.commitCandidate(&candidate, redaction) catch return false;
        self.replace(&candidate);
        owned = false;
        if (resolution.outcome == .unavailable) return true;
        const committed = self.store.find(pending.scheduled_task_id) orelse return true;
        _ = self.notifier.notify(.{
            .scheduled_task_id = committed.id,
            .task_id = pending.task_id,
            .title = committed.title,
            .kind = if (needs_attention)
                .needs_attention
            else if (resolution.outcome == .completed)
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
        const blocking_task_id = try self.activeTaskId(id, tasks);
        const item = self.store.find(id) orelse return error.UnknownScheduledTask;
        if (blocking_task_id == 0) {
            const binding = item.bindingView();
            // Control resolves the complete source authority before the
            // durable claim. No credential or live capability enters Schedule.
            switch (tasks.preflight_fn(tasks.context, .{
                .title = item.title,
                .input = item.input.borrowed(),
                .model_ref = binding.model_ref,
                .source_generation = binding.source_generation,
                .protocol = binding.protocol,
                .permission_profile = item.permission_profile,
            })) {
                .ready => {},
                .wait => return error.ScheduleAdmissionWaiting,
                .retry => |cause| {
                    item.preflight_retry_at_unix_seconds = triggered_at_unix_seconds +| preflight_retry_seconds;
                    return cause;
                },
                .rejected => |cause| {
                    item.preflight_retry_at_unix_seconds = null;
                    return cause;
                },
            }
        }
        item.preflight_retry_at_unix_seconds = null;
        const begin = try self.beginOccurrence(
            id,
            planned_at_unix_seconds,
            triggered_at_unix_seconds,
            source,
            blocking_task_id,
            redaction,
        );
        var claim = switch (begin) {
            .skipped => |task_id| return task_id,
            .claimed => |value| value,
        };
        defer claim.deinit();
        const completion = &claim.completion.?;
        const launch = tasks.launch(.{
            .title = claim.title,
            .input = claim.input,
            .model_ref = .{
                .source_id = claim.source_id,
                .model_id = claim.model_id,
            },
            .source_generation = claim.source_generation,
            .protocol = claim.protocol,
            .permission_profile = claim.permission_profile,
        });
        switch (launch) {
            .submitted => |task_id| {
                completion.finalizeClaimSubmitted(
                    completion.find(claim.id) orelse unreachable,
                    claim.planned_at_unix_seconds,
                    claim.source,
                    task_id,
                ) catch unreachable;
                _ = self.retainExternalResult(completion, redaction);
                claim.completion = null;
                return task_id;
            },
            .rejected => |failure| {
                completion.finalizeClaimRejected(
                    completion.find(claim.id) orelse unreachable,
                    claim.planned_at_unix_seconds,
                    claim.source,
                    failure.reason,
                    failure.task_id,
                ) catch unreachable;
                const committed = self.retainExternalResult(completion, redaction);
                claim.completion = null;
                if (committed) _ = self.notifier.notify(.{
                    .scheduled_task_id = claim.id,
                    .task_id = failure.task_id,
                    .title = self.store.find(claim.id).?.title,
                    .kind = .needs_attention,
                });
                return failure.cause;
            },
        }
    }

    fn reconcileCompletionNoFail(
        self: *Runtime,
        tasks: TaskEffects,
        redaction: Redaction,
    ) bool {
        var changed = false;
        while (self.nextCompletionResolution(tasks)) |resolution| {
            if (!self.finishCompletionNoFail(resolution, redaction)) {
                self.completion_confirmation_failed_task = resolution.pending.task_id;
                break;
            }
            changed = true;
        }
        return changed;
    }

    fn reconcileBindingsNoFail(
        self: *Runtime,
        binding: ExecutionBinding,
        redaction: Redaction,
    ) bool {
        // Timer admission can change without any durable definition changing.
        defer _ = self.rearmNoFail(binding, redaction);
        if (self.persistence_health != .ready) return false;
        var candidate = self.store.clone(self.allocator) catch return false;
        var owned = true;
        defer if (owned) candidate.deinit();
        if (!reconcileBindingsInStore(&candidate, binding)) return false;
        self.commitCandidate(&candidate, redaction) catch return false;
        self.replace(&candidate);
        owned = false;
        return true;
    }

    pub fn recoverInterruptedNoFail(self: *Runtime, redaction: Redaction) bool {
        if (self.persistence_health != .ready) return false;
        const interrupted = for (self.store.items) |entry| {
            const item = entry orelse continue;
            for (item.occurrences()) |occurrence| {
                if (occurrence.result == .claimed) break;
            } else continue;
            break true;
        } else false;
        if (!interrupted) return false;
        var candidate = self.store.clone(self.allocator) catch {
            self.persistence_health = .write_failed;
            self.changed = true;
            return false;
        };
        var owned = true;
        defer if (owned) candidate.deinit();
        if (!candidate.interruptClaimedOccurrences()) return false;
        self.commitCandidate(&candidate, redaction) catch {
            if (self.persistence_health == .ready) {
                self.persistence_health = .write_failed;
                self.changed = true;
            }
            return false;
        };
        self.replace(&candidate);
        owned = false;
        return true;
    }

    /// Installed credentials were durably scrubbed before admission and every
    /// later Schedule write scans live owners. A clean store needs no new I/O;
    /// a dirty store must commit before its last protecting owner can leave.
    pub fn prepareCredentialRelease(self: *Runtime, credential: []const u8, redaction: Redaction) bool {
        if (!self.containsCredential(credential)) return true;
        _ = self.prepareCredentialRedaction(credential, redaction) catch return false;
        return true;
    }

    fn containsCredential(self: *const Runtime, credential: []const u8) bool {
        if (credential.len == 0) return false;
        return for (self.store.items) |entry| {
            const item = entry orelse continue;
            if (std.mem.indexOf(u8, item.title, credential) != null or
                std.mem.indexOf(u8, item.input.borrowed(), credential) != null or
                std.mem.indexOf(u8, item.bindingView().model_ref.model_id, credential) != null) break true;
        } else false;
    }

    pub fn prepareCredentialRedaction(
        self: *Runtime,
        additional_credential: []const u8,
        redaction: Redaction,
    ) Error!bool {
        // Only a matching durable text creates a Schedule dependency. An
        // unrelated broken store must not gate Task creation or renewal.
        if (!self.containsCredential(additional_credential)) return false;
        if (self.persistence.enabled) switch (self.persistence_health) {
            .ready => {},
            .outcome_unknown => return error.ScheduledTaskPersistenceOutcomeUnknown,
            else => return error.ScheduledTaskPersistenceUnavailable,
        };
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

    fn timerDueAt(item: *const state.Item) u64 {
        return @max(item.next_run_at_unix_seconds.?, item.preflight_retry_at_unix_seconds orelse 0);
    }

    fn earliestReady(self: *Runtime, authority: ExecutionBinding) ?*state.Item {
        var earliest: ?*state.Item = null;
        for (self.store.items) |*entry| {
            const item = if (entry.*) |*value| value else continue;
            if (!item.enabled or item.health != .ready or item.next_run_at_unix_seconds == null or
                item.waiting_for_task_history or
                authority.status(item.bindingView()) != .ready) continue;
            if (earliest == null or timerDueAt(item) < timerDueAt(earliest.?)) earliest = item;
        }
        return earliest;
    }

    pub fn rearmNoFail(
        self: *Runtime,
        binding: ExecutionBinding,
        redaction: Redaction,
    ) bool {
        self.timer.cancelCurrent();
        if (!self.background_available or self.persistence_health != .ready or
            !binding.available) return false;
        const item = self.earliestReady(binding) orelse return false;
        if (self.timer.armAt(timerDueAt(item))) return false;
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
            self.timer.cancelCurrent();
            return error.ScheduledTaskPersistenceFailed;
        }
        switch (self.persistence.commit(bytes)) {
            .committed => {},
            .failed => {
                self.persistence_health = .write_failed;
                self.changed = true;
                self.timer.cancelCurrent();
                return error.ScheduledTaskPersistenceFailed;
            },
            .outcome_unknown => {
                self.persistence_health = .outcome_unknown;
                self.changed = true;
                self.timer.cancelCurrent();
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
        last_occurrence: ?Occurrence,
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
            .last_occurrence = stored.last_occurrence,
        };
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
        // A temporarily unavailable execution catalog is an admission fact,
        // not a durable change to this schedule's captured binding.
        if (!binding.available) continue;
        const availability = binding.status(item.bindingView());
        const reason: ?FailureReason = if (availability == .invalid)
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
    fail_commit_at: ?usize = null,
    recovery_result: PersistenceCommit = .committed,
    commits: usize = 0,
    recoveries: usize = 0,
    notifications: usize = 0,
    notification_kind: ?NotificationKind = null,
    notification_task_id: u64 = 0,
    armed_at: ?u64 = null,
    durable_storage: ?[]u8 = null,
    durable_len: usize = 0,
    unknown_landed: bool = false,

    fn clock(context: ?*anyopaque) ?u64 {
        const self: *TestEffects = @ptrCast(@alignCast(context.?));
        return self.now;
    }

    fn arm(context: ?*anyopaque, at: u64) bool {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.armed_at = at;
        return true;
    }

    fn cancel(context: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.armed_at = null;
    }

    fn commit(context: ?*anyopaque, bytes: []const u8) PersistenceCommit {
        const self: *TestEffects = @ptrCast(@alignCast(context.?));
        self.commits += 1;
        if (self.fail_commit_at == self.commits) return .failed;
        if (self.commit_result == .committed or
            (self.commit_result == .outcome_unknown and self.unknown_landed))
        {
            if (self.durable_storage) |storage| {
                std.debug.assert(bytes.len <= storage.len);
                @memcpy(storage[0..bytes.len], bytes);
                self.durable_len = bytes.len;
            }
        }
        return self.commit_result;
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
        };
    }

    fn notify(context: ?*anyopaque, notification: Notification) bool {
        const self: *TestEffects = @ptrCast(@alignCast(context.?));
        self.notifications += 1;
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
    next_task_id: u64 = 42,
    unavailable_task_id: u64 = 0,
    terminal_task_id: u64 = 0,
    active_task_id: u64 = 0,
    preflight_error: ?anyerror = null,
    preflight_result: TaskPreflight = .ready,
    preflight_blocked_title: ?[]const u8 = null,
    rejection: ?TaskLaunchFailure = null,
    launch_effects: ?*TestEffects = null,
    launch_commit: PersistenceCommit = .committed,

    fn preflight(context: *anyopaque, input: TaskLaunch) TaskPreflight {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (self.preflight_blocked_title) |title|
            if (std.mem.eql(u8, title, input.title)) return .{ .retry = error.ExecutionUnavailable };
        if (self.preflight_error) |err| return .{ .retry = err };
        return self.preflight_result;
    }

    fn hasActive(context: *anyopaque, id: u64) bool {
        const self: *@This() = @ptrCast(@alignCast(context));
        return self.active_task_id != 0 and self.active_task_id == id;
    }

    fn launch(context: *anyopaque, input: TaskLaunch) TaskLaunchOutcome {
        const self: *TestTasks = @ptrCast(@alignCast(context));
        if (self.launch_effects) |value| value.commit_result = self.launch_commit;
        if (self.rejection) |failure| return .{ .rejected = failure };
        self.launched_profile = input.permission_profile;
        const task_id = self.next_task_id;
        self.next_task_id += 1;
        return .{ .submitted = task_id };
    }

    fn observe(context: *anyopaque, task_id: u64) TaskObservation {
        const self: *TestTasks = @ptrCast(@alignCast(context));
        if (task_id == self.unavailable_task_id) return .unavailable;
        if (self.terminal) |terminal| {
            if (self.terminal_task_id == 0 or
                task_id == self.terminal_task_id)
                return .{ .terminal = terminal };
        }
        return .pending;
    }

    fn effects(self: *TestTasks) TaskEffects {
        return .{
            .context = self,
            .has_active_fn = hasActive,
            .preflight_fn = preflight,
            .launch_fn = launch,
            .observe_fn = observe,
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

fn validTestBinding(_: ?*anyopaque, binding: ModelBinding) BindingAvailability {
    return if (binding.source_generation == 1 and binding.protocol == .anthropic_messages) .ready else .invalid;
}

fn invalidTestBinding(_: ?*anyopaque, _: ModelBinding) BindingAvailability {
    return .invalid;
}

fn testBinding() ExecutionBinding {
    return .{ .available = true, .automatic_workspace_available = true, .validate_fn = validTestBinding };
}

fn testDefinition(title: []const u8, input: []const u8) Definition {
    return .{
        .title = title,
        .binding = .{
            .model_ref = .{ .source_id = "metask:test", .model_id = "model" },
            .source_generation = 1,
            .protocol = .anthropic_messages,
        },
        .permission_profile = .approval_required,
        .input = input,
        .recurrence = .{ .once = .{ .at_unix_seconds = 200 } },
    };
}

test "credential release retains its protecting owner until a dirty Schedule commits" {
    const Scrub = struct {
        fn redact(_: *anyopaque, projection: MutableProjection, secret: []const u8) bool {
            if (secret.len == 0) return false;
            var changed = false;
            for ([_][]u8{ projection.title, projection.binding_model, projection.input }) |text| {
                while (std.mem.indexOf(u8, text, secret)) |offset| {
                    @memset(text[offset..][0..secret.len], '*');
                    changed = true;
                }
            }
            return changed;
        }
    };
    var effects: TestEffects = .{};
    var runtime = try Runtime.init(std.testing.allocator, .{ .max_items = 1, .max_projection_bytes = 8192 }, .{ .timer = effects.timer(), .persistence = effects.persistence() });
    defer runtime.deinit();
    const id = try runtime.create(testDefinition("late-secret", "inspect"), testBinding(), testRedaction(&effects));
    const redaction: Redaction = .{ .context = &effects, .redact_fn = Scrub.redact, .contains_fn = noCredential };
    effects.commit_result = .failed;
    try std.testing.expect(!runtime.prepareCredentialRelease("late-secret", redaction));
    try std.testing.expectEqualStrings("late-secret", runtime.store.find(id).?.title);
    // A clean credential can leave even when unrelated persistence is down.
    try std.testing.expect(runtime.prepareCredentialRelease("other-secret", redaction));
    runtime.persistence_health = .ready;
    effects.commit_result = .committed;
    try std.testing.expect(runtime.prepareCredentialRelease("late-secret", redaction));
    try std.testing.expect(std.mem.indexOf(u8, runtime.store.find(id).?.title, "late-secret") == null);
}

test "clean credential admission ignores unrelated Schedule persistence failures" {
    for ([_]PersistenceHealth{ .unavailable, .read_failed, .corrupt, .write_failed, .outcome_unknown }) |health| {
        var effects: TestEffects = .{};
        var runtime = try Runtime.init(std.testing.allocator, .{ .max_items = 1, .max_projection_bytes = 8192 }, .{ .timer = effects.timer(), .persistence = effects.persistence() });
        defer runtime.deinit();
        runtime.persistence_health = health;
        try std.testing.expect(!try runtime.prepareCredentialRedaction("new-secret", testRedaction(&effects)));
        try std.testing.expectEqual(@as(usize, 0), effects.commits);
        runtime.persistence_health = .ready;
        _ = try runtime.create(testDefinition("unrelated plan", "inspect"), testBinding(), testRedaction(&effects));
        runtime.persistence_health = health;
        const commits = effects.commits;
        try std.testing.expect(!try runtime.prepareCredentialRedaction("new-secret", testRedaction(&effects)));
        try std.testing.expectEqual(commits, effects.commits);
        try std.testing.expectEqual(health, runtime.persistence_health);
    }
}

test "matching credential admission preserves the dirty Schedule and rejects unhealthy persistence" {
    for ([_]PersistenceHealth{ .unavailable, .read_failed, .corrupt, .write_failed, .outcome_unknown }) |health| {
        var effects: TestEffects = .{};
        var runtime = try Runtime.init(std.testing.allocator, .{ .max_items = 1, .max_projection_bytes = 8192 }, .{ .timer = effects.timer(), .persistence = effects.persistence() });
        defer runtime.deinit();
        const id = try runtime.create(testDefinition("new-secret", "inspect"), testBinding(), testRedaction(&effects));
        const commits = effects.commits;
        runtime.persistence_health = health;
        const expected: Error = if (health == .outcome_unknown) error.ScheduledTaskPersistenceOutcomeUnknown else error.ScheduledTaskPersistenceUnavailable;
        try std.testing.expectError(expected, runtime.prepareCredentialRedaction("new-secret", testRedaction(&effects)));
        try std.testing.expectEqual(commits, effects.commits);
        try std.testing.expectEqualStrings("new-secret", runtime.store.find(id).?.title);
    }
}

const retired_schedule_bytes =
    "{\"schema_version\":1,\"next_id\":8,\"items\":[{\"id\":7,\"epoch\":3,\"title\":\"Legacy schedule\",\"execution_generation\":19,\"execution_protocol\":\"anthropic_messages\",\"execution_model\":\"legacy-model\",\"permission_profile\":\"approval_required\",\"input\":{\"kind\":\"text\",\"text\":\"inspect\"},\"recurrence\":{\"kind\":\"once\",\"at_unix_seconds\":200},\"enabled\":true,\"health\":\"ready\",\"failure_reason\":null,\"next_run_at_unix_seconds\":200,\"occurrences\":[]}]}";

test "bootstrap quarantines retired Schedule shapes and continues with an empty current store" {
    var effects: TestEffects = .{ .restored_bytes = retired_schedule_bytes };
    var runtime = try Runtime.init(std.testing.allocator, .{
        .max_items = 2,
        .max_projection_bytes = 4096,
    }, .{
        .timer = effects.timer(),
        .persistence = effects.persistence(),
    });
    defer runtime.deinit();

    try std.testing.expectEqual(PersistenceHealth.ready, runtime.persistenceHealth());
    try std.testing.expectEqual(@as(usize, 0), effects.commits);
    try std.testing.expectEqual(@as(usize, 1), effects.recoveries);
    try std.testing.expect(!runtime.persistenceRecoveryAvailable());
    try std.testing.expect(testing.item(&runtime, 7) == null);
}

test "current Schedule corruption and allocation exhaustion never authorize an automatic hard cut" {
    for ([_][]const u8{ "not-json", "{\"schema_version\":3,\"next_id\":1,\"items\":[]}", "{\"schema_version\":1,\"next_id\":1,\"items\":[],\"extra\":true}" }) |bytes| {
        var effects: TestEffects = .{ .restored_bytes = bytes };
        var runtime = try Runtime.init(std.testing.allocator, .{ .max_items = 1, .max_projection_bytes = 4096 }, .{ .persistence = effects.persistence() });
        defer runtime.deinit();
        try std.testing.expectEqual(PersistenceHealth.corrupt, runtime.persistenceHealth());
        try std.testing.expectEqual(@as(usize, 0), effects.recoveries);
        try std.testing.expectEqual(@as(usize, 0), effects.commits);
    }
    var effects: TestEffects = .{ .restored_bytes = "{\"schema_version\":1,\"next_id\":1,\"items\":[]}" };
    var allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, Runtime.init(allocator.allocator(), .{ .max_items = 1, .max_projection_bytes = 4096 }, .{ .persistence = effects.persistence() }));
    try std.testing.expectEqual(@as(usize, 0), effects.recoveries);
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
        0,
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

test "consecutive skips retain the active Task and pending completion beyond history capacity" {
    var effects: TestEffects = .{};
    var tasks: TestTasks = .{};
    var runtime = try Runtime.init(std.testing.allocator, .{ .max_items = 1, .max_projection_bytes = 8192 }, .{
        .timer = effects.timer(),
        .persistence = effects.persistence(),
    });
    defer runtime.deinit();
    const redaction = testRedaction(&effects);
    var definition = testDefinition("long running", "inspect");
    definition.recurrence = .{ .interval = .{ .start_at_unix_seconds = 200, .every_seconds = 60 } };
    const id = try runtime.create(definition, testBinding(), redaction);
    _ = runtime.setBackgroundAvailable(true, testBinding(), redaction);
    effects.now = 200;
    runtime.onTimer(testBinding(), redaction, tasks.effects());
    tasks.active_task_id = 42;
    for (1..state.max_occurrence_history * 2) |n| {
        effects.now = 200 + @as(u64, @intCast(n)) * 60;
        runtime.onTimer(testBinding(), redaction, tasks.effects());
        try std.testing.expectEqual(@as(u64, 43), tasks.next_task_id);
        try std.testing.expectError(error.PreviousTaskActive, runtime.runNow(id, 1, redaction, tasks.effects()));
    }
    const item = runtime.store.find(id).?;
    try std.testing.expectEqual(state.max_occurrence_history, item.occurrence_count);
    try std.testing.expectEqual(@as(u64, 42), item.last_occurrence.?.task_id);
    try std.testing.expect(runtime.hasPendingSubmittedOccurrence(42));
    // A previously valid empty skipped Task id must not erase the retained blocker.
    item.occurrence_history[item.occurrence_count - 1].task_id = 0;
    item.last_occurrence.?.task_id = 0;
    try std.testing.expectError(error.PreviousTaskActive, runtime.runNow(id, 1, redaction, tasks.effects()));
    tasks.active_task_id = 0;
    tasks.terminal = .{ .outcome = .completed, .permission_required = false };
    _ = runtime.reconcileNoFail(testBinding(), redaction, tasks.effects());
    try std.testing.expect(!runtime.hasPendingSubmittedOccurrence(42));
    try std.testing.expectEqual(@as(u64, 43), try runtime.runNow(id, 1, redaction, tasks.effects()));
}

test "full protected history stops without eviction or an overdue timer retry" {
    for ([_]PersistenceCommit{ .committed, .failed, .outcome_unknown }) |result| {
        var effects: TestEffects = .{};
        var tasks: TestTasks = .{};
        var runtime = try Runtime.init(std.testing.allocator, .{ .max_items = 1, .max_projection_bytes = 8192 }, .{
            .timer = effects.timer(),
            .persistence = effects.persistence(),
        });
        defer runtime.deinit();
        const redaction = testRedaction(&effects);
        const id = try runtime.create(testDefinition("protected", "inspect"), testBinding(), redaction);
        _ = runtime.setBackgroundAvailable(true, testBinding(), redaction);
        const item = runtime.store.find(id).?;
        for (0..state.max_occurrence_history) |n|
            try runtime.store.claim(item, 101 + @as(u64, @intCast(n)), 101 + @as(u64, @intCast(n)), .manual);
        effects.commit_result = result;
        effects.now = 200;
        runtime.onTimer(testBinding(), redaction, tasks.effects());
        try std.testing.expectEqual(@as(?u64, null), effects.armed_at);
        try std.testing.expectEqual(@as(u64, 42), tasks.next_task_id);
        const retained = runtime.store.find(id).?;
        try std.testing.expectEqual(state.max_occurrence_history, retained.occurrence_count);
        for (retained.occurrences()) |occurrence|
            try std.testing.expectEqual(state.OccurrenceResult.claimed, occurrence.result);
        switch (result) {
            .committed => {
                try std.testing.expectEqual(Health.needs_attention, retained.health);
                try std.testing.expectEqual(FailureReason.capacity_reached, retained.failure_reason.?);
            },
            .failed => try std.testing.expectEqual(PersistenceHealth.write_failed, runtime.persistenceHealth()),
            .outcome_unknown => try std.testing.expectEqual(PersistenceHealth.outcome_unknown, runtime.persistenceHealth()),
        }
    }
}

test "preflight policy follows admission categories rather than opaque causes" {
    for ([_]TaskPreflight{ .wait, .{ .retry = error.OpaqueAdmissionFailure }, .{ .rejected = error.OpaqueAdmissionFailure } }) |result| {
        var effects: TestEffects = .{};
        var tasks: TestTasks = .{ .preflight_result = result };
        var runtime = try Runtime.init(std.testing.allocator, .{ .max_items = 1, .max_projection_bytes = 8192 }, .{ .timer = effects.timer(), .persistence = effects.persistence() });
        defer runtime.deinit();
        const redaction = testRedaction(&effects);
        const id = try runtime.create(testDefinition("preflight", "inspect"), testBinding(), redaction);
        _ = runtime.setBackgroundAvailable(true, testBinding(), redaction);
        effects.now = 200;
        const commits = effects.commits;
        runtime.onTimer(testBinding(), redaction, tasks.effects());
        try std.testing.expectEqual(commits, effects.commits);
        try std.testing.expectEqual(@as(usize, 0), runtime.store.find(id).?.occurrence_count);
        switch (result) {
            .wait => try std.testing.expect(runtime.hasTaskHistoryWaits()),
            .retry => try std.testing.expectEqual(@as(?u64, 260), effects.armed_at),
            .rejected => try std.testing.expectEqual(@as(?u64, null), effects.armed_at),
            .ready => unreachable,
        }
    }
}

test "transient preflight failure retries without a claim and runs only the latest due occurrence" {
    var effects: TestEffects = .{};
    var tasks: TestTasks = .{ .preflight_error = error.ExecutionUnavailable };
    var runtime = try Runtime.init(std.testing.allocator, .{ .max_items = 1, .max_projection_bytes = 8192 }, .{
        .timer = effects.timer(),
        .persistence = effects.persistence(),
    });
    defer runtime.deinit();
    const redaction = testRedaction(&effects);
    var definition = testDefinition("preflight", "inspect");
    definition.recurrence = .{ .interval = .{ .start_at_unix_seconds = 200, .every_seconds = 60 } };
    const id = try runtime.create(definition, testBinding(), redaction);
    _ = runtime.setBackgroundAvailable(true, testBinding(), redaction);
    const commits = effects.commits;
    effects.now = 200;
    runtime.onTimer(testBinding(), redaction, tasks.effects());
    try std.testing.expectEqual(@as(?u64, 260), effects.armed_at);
    effects.now = 259;
    runtime.onTimer(testBinding(), redaction, tasks.effects());
    try std.testing.expectEqual(@as(?u64, 260), effects.armed_at);
    effects.now = 260;
    runtime.onTimer(testBinding(), redaction, tasks.effects());
    try std.testing.expectEqual(@as(?u64, 320), effects.armed_at);
    try std.testing.expectEqual(commits, effects.commits);
    try std.testing.expectEqual(@as(usize, 0), runtime.store.find(id).?.occurrence_count);
    try std.testing.expectEqual(Health.ready, runtime.store.find(id).?.health);
    try std.testing.expectError(error.ExecutionUnavailable, runtime.runNow(id, 1, redaction, tasks.effects()));
    try std.testing.expectEqual(commits, effects.commits);
    tasks.preflight_error = null;
    effects.now = 382;
    runtime.onTimer(testBinding(), redaction, tasks.effects());
    runtime.onTimer(testBinding(), redaction, tasks.effects());
    try std.testing.expectEqual(@as(u64, 43), tasks.next_task_id);
    const item = runtime.store.find(id).?;
    try std.testing.expectEqual(@as(usize, 1), item.occurrence_count);
    try std.testing.expectEqual(@as(u64, 380), item.occurrences()[0].planned_at_unix_seconds);
    try std.testing.expectEqual(@as(?u64, 440), effects.armed_at);
}

test "unavailable binding cancels an armed timer without invalidating a due definition" {
    var effects: TestEffects = .{};
    var tasks: TestTasks = .{};
    var runtime = try Runtime.init(std.testing.allocator, .{ .max_items = 1, .max_projection_bytes = 8192 }, .{
        .timer = effects.timer(),
        .persistence = effects.persistence(),
    });
    defer runtime.deinit();
    const redaction = testRedaction(&effects);
    const id = try runtime.create(testDefinition("replacement", "inspect"), testBinding(), redaction);
    _ = runtime.setBackgroundAvailable(true, testBinding(), redaction);
    const commits = effects.commits;
    var unavailable = testBinding();
    unavailable.available = false;
    _ = runtime.refreshBindingNoFail(unavailable, redaction);
    try std.testing.expectEqual(@as(?u64, null), effects.armed_at);
    effects.now = 200;
    runtime.onTimer(unavailable, redaction, tasks.effects());
    try std.testing.expectEqual(commits, effects.commits);
    try std.testing.expectEqual(Health.ready, runtime.store.find(id).?.health);
    try std.testing.expectEqual(@as(usize, 0), runtime.store.find(id).?.occurrence_count);
}

test "late timer claims only the latest due interval and advances past wake time" {
    var effects: TestEffects = .{};
    var tasks: TestTasks = .{};
    var runtime = try Runtime.init(std.testing.allocator, .{ .max_items = 1, .max_projection_bytes = 8192 }, .{
        .timer = effects.timer(),
        .persistence = effects.persistence(),
    });
    defer runtime.deinit();
    const redaction = testRedaction(&effects);
    var definition = testDefinition("late", "inspect");
    definition.recurrence = .{ .interval = .{ .start_at_unix_seconds = 200, .every_seconds = 60 } };
    const id = try runtime.create(definition, testBinding(), redaction);
    _ = runtime.setBackgroundAvailable(true, testBinding(), redaction);
    effects.now = 399;
    runtime.onTimer(testBinding(), redaction, tasks.effects());
    const item = runtime.store.find(id).?;
    try std.testing.expectEqual(@as(usize, 1), item.occurrence_count);
    try std.testing.expectEqual(@as(u64, 380), item.last_occurrence.?.planned_at_unix_seconds);
    try std.testing.expectEqual(@as(u64, 399), item.last_occurrence.?.triggered_at_unix_seconds);
    try std.testing.expectEqual(@as(?u64, 440), effects.armed_at);
    runtime.onTimer(testBinding(), redaction, tasks.effects());
    try std.testing.expectEqual(@as(u64, 43), tasks.next_task_id);
}

test "attention requires editing while enable acknowledgements describe reconciled state" {
    var effects: TestEffects = .{};
    var tasks: TestTasks = .{};
    var runtime = try Runtime.init(std.testing.allocator, .{ .max_items = 1, .max_projection_bytes = 8192 }, .{
        .timer = effects.timer(),
        .persistence = effects.persistence(),
    });
    defer runtime.deinit();
    const redaction = testRedaction(&effects);
    const id = try runtime.create(testDefinition("attention", "inspect"), testBinding(), redaction);
    try std.testing.expect(!try runtime.setEnabled(id, 1, false, testBinding(), redaction));
    var changed = testBinding();
    changed.validate_fn = invalidTestBinding;
    try std.testing.expect(!try runtime.setEnabled(id, 2, true, changed, redaction));
    const epoch = try runtime.epoch(id);
    try std.testing.expectError(error.ScheduledTaskNeedsAttention, runtime.setEnabled(id, epoch, false, changed, redaction));
    try std.testing.expectError(error.ScheduledTaskNeedsAttention, runtime.setEnabled(id, epoch, true, changed, redaction));
    try std.testing.expectError(error.ScheduledTaskNeedsAttention, runtime.runNow(id, epoch, redaction, tasks.effects()));
    try std.testing.expectEqual(@as(u64, 42), tasks.next_task_id);
    try runtime.update(id, epoch, testDefinition("confirmed", "inspect"), testBinding(), redaction);
    try std.testing.expectEqual(Health.ready, runtime.store.find(id).?.health);
}

test "environment refresh preserves each fixed binding without a global selection revision" {
    var effects: TestEffects = .{};
    var runtime = try Runtime.init(std.testing.allocator, .{ .max_items = 1, .max_projection_bytes = 4096 }, .{ .timer = effects.timer(), .persistence = effects.persistence() });
    defer runtime.deinit();
    const redaction = testRedaction(&effects);
    const id = try runtime.create(testDefinition("stable", "inspect"), testBinding(), redaction);
    try std.testing.expect(!runtime.refreshBindingNoFail(testBinding(), redaction));
    const item = testing.item(&runtime, id).?;
    try std.testing.expect(item.enabled);
    try std.testing.expectEqual(Health.ready, item.health);
    try std.testing.expectEqual(@as(u64, 1), item.binding.source_generation);
}

test "temporary execution unavailability does not durably invalidate schedules" {
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
        testDefinition("cold start", "inspect"),
        testBinding(),
        redaction,
    );
    const commits_before = effects.commits;
    const unavailable: ExecutionBinding = .{
        .available = false,
        .automatic_workspace_available = true,
    };

    try std.testing.expect(!runtime.refreshBindingNoFail(unavailable, redaction));
    try std.testing.expectEqual(commits_before, effects.commits);
    const item = testing.item(&runtime, id).?;
    try std.testing.expect(item.enabled);
    try std.testing.expectEqual(Health.ready, item.health);
    try std.testing.expectEqual(@as(?FailureReason, null), item.failure_reason);
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

test "submitted Task identity remains in memory when Schedule commit fails" {
    var effects: TestEffects = .{};
    var tasks: TestTasks = .{};
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
        testDefinition("retained Task", "inspect"),
        testBinding(),
        redaction,
    );
    effects.fail_commit_at = 3;

    try std.testing.expectEqual(
        @as(u64, 42),
        try runtime.runNow(id, 1, redaction, tasks.effects()),
    );
    try std.testing.expectEqual(PersistenceHealth.write_failed, runtime.persistenceHealth());
    const occurrence = testing.item(&runtime, id).?.last_occurrence.?;
    try std.testing.expectEqual(state.OccurrenceResult.submitted, occurrence.result);
    try std.testing.expectEqual(@as(u64, 42), occurrence.task_id);
    try std.testing.expectEqual(@as(?OccurrenceTaskOutcome, null), occurrence.task_outcome);

    try std.testing.expectEqual(
        PersistenceRecoveryOutcome.recovered,
        runtime.recoverPersistence(redaction),
    );
    try std.testing.expectEqual(PersistenceHealth.ready, runtime.persistenceHealth());
    try std.testing.expectEqual(
        @as(u64, 42),
        testing.item(&runtime, id).?.last_occurrence.?.task_id,
    );
}

test "unavailable Task does not block later Schedule completion reconciliation" {
    var effects: TestEffects = .{};
    var tasks: TestTasks = .{ .next_task_id = 41 };
    var runtime = try Runtime.init(std.testing.allocator, .{
        .max_items = 2,
        .max_projection_bytes = 4096,
    }, .{
        .timer = effects.timer(),
        .persistence = effects.persistence(),
        .notifier = effects.notifier(),
    });
    defer runtime.deinit();
    const redaction = testRedaction(&effects);
    const first = try runtime.create(
        testDefinition("missing", "inspect first"),
        testBinding(),
        redaction,
    );
    const second = try runtime.create(
        testDefinition("complete", "inspect second"),
        testBinding(),
        redaction,
    );
    try std.testing.expectEqual(
        @as(u64, 41),
        try runtime.runNow(first, 1, redaction, tasks.effects()),
    );
    try std.testing.expectEqual(
        @as(u64, 42),
        try runtime.runNow(second, 1, redaction, tasks.effects()),
    );
    tasks.unavailable_task_id = 41;
    tasks.terminal_task_id = 42;
    tasks.terminal = .{
        .outcome = .completed,
        .permission_required = false,
    };

    try std.testing.expect(runtime.reconcileNoFail(
        testBinding(),
        redaction,
        tasks.effects(),
    ));
    const missing = testing.item(&runtime, first).?.last_occurrence.?;
    try std.testing.expectEqual(
        OccurrenceTaskOutcome.unavailable,
        missing.task_outcome.?,
    );
    try std.testing.expect(missing.notification_sent);
    const completed = testing.item(&runtime, second).?.last_occurrence.?;
    try std.testing.expectEqual(
        OccurrenceTaskOutcome.completed,
        completed.task_outcome.?,
    );
    try std.testing.expect(completed.notification_sent);
    try std.testing.expectEqual(@as(usize, 1), effects.notifications);
    try std.testing.expectEqual(@as(u64, 42), effects.notification_task_id);
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

test "permission failure from an older definition stays in history without disabling the update" {
    var effects: TestEffects = .{};
    var tasks: TestTasks = .{};
    var runtime = try Runtime.init(std.testing.allocator, .{ .max_items = 1, .max_projection_bytes = 8192 }, .{ .timer = effects.timer(), .persistence = effects.persistence(), .notifier = effects.notifier() });
    defer runtime.deinit();
    const redaction = testRedaction(&effects);
    var definition = testDefinition("scheduled", "inspect");
    const id = try runtime.create(definition, testBinding(), redaction);
    const original_task = try runtime.runNow(id, 1, redaction, tasks.effects());
    definition.permission_profile = .full_access;
    try runtime.update(id, 1, definition, testBinding(), redaction);
    tasks.terminal = .{ .outcome = .stopped, .permission_required = true };
    tasks.terminal_task_id = original_task;
    try std.testing.expect(runtime.reconcileNoFail(testBinding(), redaction, tasks.effects()));
    const updated = runtime.store.find(id).?;
    try std.testing.expect(updated.enabled);
    try std.testing.expectEqual(Health.ready, updated.health);
    try std.testing.expectEqual(PermissionProfile.full_access, updated.permission_profile);
    try std.testing.expectEqual(FailureReason.permission_required, updated.occurrences()[0].reason.?);
    try std.testing.expectEqual(TaskOutcome.stopped, updated.occurrences()[0].task_outcome.?);
    try std.testing.expectEqual(NotificationKind.failed, effects.notification_kind.?);
}

test "input continuation gate includes submitted occurrences skipped after earlier write failure" {
    var effects: TestEffects = .{};
    var tasks: TestTasks = .{ .next_task_id = 41 };
    var runtime = try Runtime.init(std.testing.allocator, .{ .max_items = 2, .max_projection_bytes = 8192 }, .{ .timer = effects.timer(), .persistence = effects.persistence() });
    defer runtime.deinit();
    const redaction = testRedaction(&effects);
    const first = try runtime.create(testDefinition("first", "first"), testBinding(), redaction);
    const second = try runtime.create(testDefinition("second", "second"), testBinding(), redaction);
    _ = try runtime.runNow(first, 1, redaction, tasks.effects());
    _ = try runtime.runNow(second, 1, redaction, tasks.effects());
    tasks.terminal = .{ .outcome = .completed, .permission_required = false };
    effects.fail_commit_at = effects.commits + 1;
    _ = runtime.reconcileNoFail(testBinding(), redaction, tasks.effects());
    try std.testing.expectEqual(@as(?u64, 41), runtime.completion_confirmation_failed_task);
    try std.testing.expect(runtime.hasPendingSubmittedOccurrence(41));
    try std.testing.expect(runtime.hasPendingSubmittedOccurrence(42));
    try std.testing.expect(!runtime.hasPendingSubmittedOccurrence(43));
    effects.fail_commit_at = null;
    try std.testing.expectEqual(PersistenceRecoveryOutcome.recovered, runtime.recoverPersistence(redaction));
    _ = runtime.reconcileNoFail(testBinding(), redaction, tasks.effects());
    try std.testing.expect(runtime.completion_confirmation_failed_task == null);
    try std.testing.expect(!runtime.hasPendingSubmittedOccurrence(41));
    try std.testing.expect(!runtime.hasPendingSubmittedOccurrence(42));
}

test "input continuation observes completion allocation failure even when persistence stays ready" {
    var observed_allocation_failure = false;
    for (0..12) |failure_index| {
        var effects: TestEffects = .{};
        var tasks: TestTasks = .{};
        var runtime = try Runtime.init(std.testing.allocator, .{ .max_items = 1, .max_projection_bytes = 4096 }, .{ .timer = effects.timer(), .persistence = effects.persistence() });
        defer runtime.deinit();
        const redaction = testRedaction(&effects);
        const id = try runtime.create(testDefinition("source", "source"), testBinding(), redaction);
        _ = try runtime.runNow(id, 1, redaction, tasks.effects());
        tasks.terminal = .{ .outcome = .completed, .permission_required = false };
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = failure_index });
        runtime.allocator = failing.allocator();
        defer runtime.allocator = std.testing.allocator;
        _ = runtime.reconcileNoFail(testBinding(), redaction, tasks.effects());
        if (runtime.hasPendingSubmittedOccurrence(42)) {
            observed_allocation_failure = true;
            try std.testing.expectEqual(@as(?u64, 42), runtime.completion_confirmation_failed_task);
            // Clone/encode failure does not have to touch store health.
            try std.testing.expectEqual(.ready, runtime.persistenceHealth());
            runtime.allocator = std.testing.allocator;
            _ = runtime.reconcileNoFail(testBinding(), redaction, tasks.effects());
            try std.testing.expect(!runtime.hasPendingSubmittedOccurrence(42));
            try std.testing.expect(runtime.completion_confirmation_failed_task == null);
        }
    }
    try std.testing.expect(observed_allocation_failure);
}

test "an invalid plan cannot block a valid plan timer" {
    var effects: TestEffects = .{};
    var tasks: TestTasks = .{};
    var runtime = try Runtime.init(std.testing.allocator, .{ .max_items = 2, .max_projection_bytes = 8192 }, .{ .timer = effects.timer(), .persistence = effects.persistence() });
    defer runtime.deinit();
    const redaction = testRedaction(&effects);
    var invalid = testDefinition("invalid", "inspect");
    invalid.binding.source_generation = 2;
    const invalid_id = try runtime.create(invalid, testBinding(), redaction);
    const valid_id = try runtime.create(testDefinition("valid", "inspect"), testBinding(), redaction);
    _ = runtime.setBackgroundAvailable(true, testBinding(), redaction);
    try std.testing.expect(runtime.refreshBindingNoFail(testBinding(), redaction));
    try std.testing.expectEqual(Health.needs_attention, runtime.store.find(invalid_id).?.health);
    try std.testing.expectEqual(@as(?u64, 200), effects.armed_at);
    effects.now = 200;
    runtime.onTimer(testBinding(), redaction, tasks.effects());
    try std.testing.expectEqual(@as(usize, 0), runtime.store.find(invalid_id).?.occurrence_count);
    try std.testing.expectEqual(@as(usize, 1), runtime.store.find(valid_id).?.occurrence_count);
    try std.testing.expectEqual(@as(u64, 42), runtime.store.find(valid_id).?.last_occurrence.?.task_id);
}

test "old Schedule canonical is quarantined before bootstrap installs the empty current store" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var files: persistence.FileStore = .{ .io = std.testing.io, .dir = tmp.dir };
    try files.commit(retired_schedule_bytes);
    const old = (try files.loadAlloc(std.testing.allocator)).?;
    defer std.testing.allocator.free(old);
    const Recover = struct {
        fn apply(context: ?*anyopaque, bytes: []const u8) PersistenceCommit {
            const store: *persistence.FileStore = @ptrCast(@alignCast(context.?));
            store.recover(bytes) catch |err| return if (err == error.PersistenceOutcomeUnknown) .outcome_unknown else .failed;
            return .committed;
        }
    };
    var runtime = try Runtime.init(std.testing.allocator, .{ .max_items = 2, .max_projection_bytes = 8192 }, .{ .persistence = .{ .enabled = true, .context = &files, .restored_bytes = old, .recover_fn = Recover.apply } });
    defer runtime.deinit();
    try std.testing.expectEqual(PersistenceHealth.ready, runtime.persistenceHealth());
    try std.testing.expect(runtime.store.find(7) == null);
    const current = (try files.loadAlloc(std.testing.allocator)).?;
    defer std.testing.allocator.free(current);
    var decoded = try persistence.decode(std.testing.allocator, current, .{ .max_items = 2, .max_projection_bytes = 8192 });
    defer decoded.deinit();
    try std.testing.expect(decoded.find(7) == null);
    var dir = try tmp.dir.openDir(std.testing.io, ".", .{ .iterate = true, .follow_symlinks = false });
    defer dir.close(std.testing.io);
    var it = dir.iterate();
    var count: usize = 0;
    while (try it.next(std.testing.io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".quarantine")) continue;
        var file = try dir.openFile(std.testing.io, entry.name, .{});
        if (builtin.os.tag == .windows) file.flags.nonblocking = true;
        defer file.close(std.testing.io);
        var bytes: [retired_schedule_bytes.len]u8 = undefined;
        try std.testing.expectEqual(bytes.len, try file.readPositionalAll(std.testing.io, &bytes, 0));
        try std.testing.expectEqualStrings(retired_schedule_bytes, &bytes);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "preflight failure isolates one plan across lifecycle wakes and store replacements" {
    var effects: TestEffects = .{};
    var tasks: TestTasks = .{ .preflight_blocked_title = "blocked" };
    var runtime = try Runtime.init(std.testing.allocator, .{ .max_items = 3, .max_projection_bytes = 8192 }, .{ .timer = effects.timer(), .persistence = effects.persistence() });
    defer runtime.deinit();
    const redaction = testRedaction(&effects);
    const blocked = try runtime.create(testDefinition("blocked", "inspect"), testBinding(), redaction);
    const valid = try runtime.create(testDefinition("valid", "inspect"), testBinding(), redaction);
    _ = runtime.setBackgroundAvailable(true, testBinding(), redaction);
    effects.now = 200;
    runtime.onTimer(testBinding(), redaction, tasks.effects());
    try std.testing.expectEqual(@as(?u64, 200), effects.armed_at);
    _ = runtime.reconcileNoFail(testBinding(), redaction, tasks.effects());
    runtime.onTimer(testBinding(), redaction, tasks.effects());
    try std.testing.expectEqual(@as(u64, 43), tasks.next_task_id);
    try std.testing.expectEqual(@as(usize, 1), runtime.store.find(valid).?.occurrence_count);
    try std.testing.expectEqual(@as(usize, 0), runtime.store.find(blocked).?.occurrence_count);
    _ = runtime.reconcileNoFail(testBinding(), redaction, tasks.effects());
    try std.testing.expectEqual(@as(?u64, 260), effects.armed_at);
    tasks.preflight_blocked_title = null;
    effects.now = 260;
    runtime.onTimer(testBinding(), redaction, tasks.effects());
    try std.testing.expectEqual(@as(u64, 44), tasks.next_task_id);
}

test "allocation failure before launch never strands a committed claim" {
    var failures: usize = 0;
    for (0..40) |index| {
        var effects: TestEffects = .{};
        var tasks: TestTasks = .{};
        var runtime = try Runtime.init(std.testing.allocator, .{ .max_items = 1, .max_projection_bytes = 8192 }, .{ .timer = effects.timer(), .persistence = effects.persistence() });
        defer runtime.deinit();
        const redaction = testRedaction(&effects);
        const id = try runtime.create(testDefinition("allocation", "inspect"), testBinding(), redaction);
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = index });
        runtime.allocator = failing.allocator();
        const result = runtime.runNow(id, 1, redaction, tasks.effects());
        runtime.allocator = std.testing.allocator;
        if (result) |_| {} else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            failures += 1;
        }
        for (runtime.store.find(id).?.occurrences()) |occurrence|
            try std.testing.expect(occurrence.result != .claimed);
        if (tasks.next_task_id == 42) {
            try std.testing.expectEqual(@as(usize, 0), runtime.store.find(id).?.occurrence_count);
            try std.testing.expectEqual(PersistenceHealth.ready, runtime.persistenceHealth());
            _ = try runtime.runNow(id, 1, redaction, tasks.effects());
        } else {
            try std.testing.expectEqual(@as(u64, 42), runtime.store.find(id).?.occurrences()[0].task_id);
        }
    }
    try std.testing.expect(failures > 0);
}

test "only a confirmed launch rejection rearms the timer for another due schedule" {
    for ([_]PersistenceCommit{ .committed, .failed, .outcome_unknown }) |commit| {
        var effects: TestEffects = .{};
        var tasks: TestTasks = .{ .rejection = .{ .cause = error.TaskCapacity, .reason = .capacity_reached, .task_id = 0 }, .launch_effects = &effects, .launch_commit = commit };
        var runtime = try Runtime.init(std.testing.allocator, .{ .max_items = 2, .max_projection_bytes = 8192 }, .{ .timer = effects.timer(), .persistence = effects.persistence() });
        defer runtime.deinit();
        const redaction = testRedaction(&effects);
        const first = try runtime.create(testDefinition("first", "inspect"), testBinding(), redaction);
        const second = try runtime.create(testDefinition("second", "inspect"), testBinding(), redaction);
        _ = runtime.setBackgroundAvailable(true, testBinding(), redaction);
        effects.now = 200;
        runtime.onTimer(testBinding(), redaction, tasks.effects());
        try std.testing.expectEqual(@as(usize, 0), runtime.store.find(second).?.occurrence_count);
        if (commit == .committed) {
            try std.testing.expectEqual(Health.needs_attention, runtime.store.find(first).?.health);
            try std.testing.expectEqual(@as(?u64, 200), effects.armed_at);
            tasks.rejection = null;
            runtime.onTimer(testBinding(), redaction, tasks.effects());
            try std.testing.expectEqual(@as(u64, 42), runtime.store.find(second).?.last_occurrence.?.task_id);
        } else {
            try std.testing.expectEqual(@as(?u64, null), effects.armed_at);
            try std.testing.expect(runtime.persistenceHealth() != .ready);
        }
    }
}

test "rejected launch notification follows a confirmed Schedule commit" {
    for ([_]PersistenceCommit{ .committed, .failed, .outcome_unknown }) |commit| {
        var effects: TestEffects = .{};
        var tasks: TestTasks = .{ .rejection = .{ .cause = error.QueueFull, .reason = .capacity_reached, .task_id = 42 }, .launch_effects = &effects, .launch_commit = commit };
        var runtime = try Runtime.init(std.testing.allocator, .{ .max_items = 1, .max_projection_bytes = 8192 }, .{ .timer = effects.timer(), .persistence = effects.persistence(), .notifier = effects.notifier() });
        defer runtime.deinit();
        const redaction = testRedaction(&effects);
        const id = try runtime.create(testDefinition("rejected", "inspect"), testBinding(), redaction);
        try std.testing.expectError(error.QueueFull, runtime.runNow(id, 1, redaction, tasks.effects()));
        try std.testing.expectEqual(@as(usize, if (commit == .committed) 1 else 0), effects.notifications);
        if (commit == .committed) try std.testing.expectEqual(@as(u64, 42), effects.notification_task_id);
        try std.testing.expectEqual(@as(u64, 42), runtime.store.find(id).?.occurrences()[0].task_id);
    }
}

test "same-second manual occurrences reconcile by their actual Task identity" {
    var effects: TestEffects = .{};
    var tasks: TestTasks = .{};
    var runtime = try Runtime.init(std.testing.allocator, .{ .max_items = 1, .max_projection_bytes = 8192 }, .{ .timer = effects.timer(), .persistence = effects.persistence() });
    defer runtime.deinit();
    const redaction = testRedaction(&effects);
    const id = try runtime.create(testDefinition("manual", "inspect"), testBinding(), redaction);
    const first = try runtime.runNow(id, 1, redaction, tasks.effects());
    const second = try runtime.runNow(id, 1, redaction, tasks.effects());
    tasks.terminal = .{ .outcome = .completed, .permission_required = false };
    tasks.terminal_task_id = first;
    _ = runtime.reconcileNoFail(testBinding(), redaction, tasks.effects());
    try std.testing.expect(!runtime.hasPendingSubmittedOccurrence(first));
    try std.testing.expect(runtime.hasPendingSubmittedOccurrence(second));
    try std.testing.expectEqual(@as(?TaskOutcome, null), runtime.store.find(id).?.occurrences()[1].task_outcome);
    tasks.terminal_task_id = second;
    tasks.terminal = .{ .outcome = .failed, .permission_required = false };
    _ = runtime.reconcileNoFail(testBinding(), redaction, tasks.effects());
    try std.testing.expect(!runtime.hasPendingSubmittedOccurrence(second));
    try std.testing.expectEqual(TaskOutcome.completed, runtime.store.find(id).?.occurrences()[0].task_outcome.?);
    try std.testing.expectEqual(TaskOutcome.failed, runtime.store.find(id).?.last_occurrence.?.task_outcome.?);
}

test "startup claim recovery is fail closed on allocation failure and explicit recovery settles every claim" {
    for (0..8) |index| {
        var effects: TestEffects = .{};
        var runtime = try Runtime.init(std.testing.allocator, .{ .max_items = 1, .max_projection_bytes = 8192 }, .{ .timer = effects.timer(), .persistence = effects.persistence() });
        defer runtime.deinit();
        const redaction = testRedaction(&effects);
        const id = try runtime.create(testDefinition("interrupted", "inspect"), testBinding(), redaction);
        const item = runtime.store.find(id).?;
        try runtime.store.claim(item, 100, 100, .manual);
        try runtime.store.claim(item, 101, 101, .manual);
        // A later record must not hide an older interrupted claim.
        try runtime.store.markSkipped(item, 200, 200, 0);
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = index });
        runtime.allocator = failing.allocator();
        const recovered = runtime.recoverInterruptedNoFail(redaction);
        runtime.allocator = std.testing.allocator;
        if (!recovered) {
            try std.testing.expectEqual(PersistenceHealth.write_failed, runtime.persistenceHealth());
            _ = runtime.setBackgroundAvailable(true, testBinding(), redaction);
            try std.testing.expectEqual(@as(?u64, null), effects.armed_at);
            try std.testing.expectEqual(PersistenceRecoveryOutcome.recovered, runtime.recoverPersistence(redaction));
        }
        const restored = runtime.store.find(id).?;
        try std.testing.expectEqual(Health.needs_attention, restored.health);
        for (restored.occurrences()[0..2]) |occurrence| {
            try std.testing.expectEqual(state.OccurrenceResult.rejected, occurrence.result);
            try std.testing.expectEqual(FailureReason.host_interrupted, occurrence.reason.?);
        }
        try std.testing.expectEqual(state.OccurrenceResult.skipped, restored.last_occurrence.?.result);
    }
}

test "backward wall-clock movement cannot replay a consumed timer occurrence" {
    var effects: TestEffects = .{};
    var tasks: TestTasks = .{};
    var runtime = try Runtime.init(std.testing.allocator, .{ .max_items = 1, .max_projection_bytes = 8192 }, .{ .timer = effects.timer(), .persistence = effects.persistence() });
    defer runtime.deinit();
    const redaction = testRedaction(&effects);
    var definition = testDefinition("clock", "inspect");
    definition.recurrence = .{ .interval = .{ .start_at_unix_seconds = 200, .every_seconds = 60 } };
    const id = try runtime.create(definition, testBinding(), redaction);
    _ = runtime.setBackgroundAvailable(true, testBinding(), redaction);
    effects.now = 200;
    runtime.onTimer(testBinding(), redaction, tasks.effects());
    effects.now = 100;
    runtime.onTimer(testBinding(), redaction, tasks.effects());
    effects.now = 200;
    runtime.onTimer(testBinding(), redaction, tasks.effects());
    try std.testing.expectEqual(@as(u64, 43), tasks.next_task_id);
    try std.testing.expectEqual(@as(usize, 1), runtime.store.find(id).?.occurrence_count);
    try std.testing.expectEqual(@as(?u64, 260), effects.armed_at);
}

test "failed Schedule mutations cancel an existing timer without publishing their candidate" {
    for ([_]PersistenceCommit{ .failed, .outcome_unknown }) |commit| {
        var effects: TestEffects = .{};
        var runtime = try Runtime.init(std.testing.allocator, .{ .max_items = 1, .max_projection_bytes = 8192 }, .{ .timer = effects.timer(), .persistence = effects.persistence() });
        defer runtime.deinit();
        const redaction = testRedaction(&effects);
        const id = try runtime.create(testDefinition("retained", "inspect"), testBinding(), redaction);
        _ = runtime.setBackgroundAvailable(true, testBinding(), redaction);
        _ = runtime.takeChanged();
        effects.commit_result = commit;
        const result = runtime.setEnabled(id, 1, false, testBinding(), redaction);
        if (commit == .failed) {
            try std.testing.expectError(error.ScheduledTaskPersistenceFailed, result);
        } else try std.testing.expectError(error.ScheduledTaskPersistenceOutcomeUnknown, result);
        try std.testing.expectEqual(@as(?u64, null), effects.armed_at);
        try std.testing.expect(runtime.takeChanged());
        try std.testing.expectEqual(Health.ready, runtime.store.find(id).?.health);
        try std.testing.expectEqual(@as(u64, 1), runtime.store.find(id).?.epoch);
    }
}

test "restart never replays a launched occurrence after a failed or indeterminate result commit" {
    const storage = try std.testing.allocator.alloc(u8, persistence.max_store_bytes);
    defer std.testing.allocator.free(storage);
    const Scenario = struct { commit: PersistenceCommit, landed: bool };
    for ([_]Scenario{ .{ .commit = .failed, .landed = false }, .{ .commit = .outcome_unknown, .landed = false }, .{ .commit = .outcome_unknown, .landed = true } }) |scenario| {
        var effects: TestEffects = .{ .durable_storage = storage, .unknown_landed = scenario.landed };
        var tasks: TestTasks = .{ .launch_effects = &effects, .launch_commit = scenario.commit };
        var runtime = try Runtime.init(std.testing.allocator, .{ .max_items = 1, .max_projection_bytes = 8192 }, .{ .timer = effects.timer(), .persistence = effects.persistence() });
        const redaction = testRedaction(&effects);
        const id = runtime.create(testDefinition("restart", "inspect"), testBinding(), redaction) catch |err| {
            runtime.deinit();
            return err;
        };
        _ = runtime.setBackgroundAvailable(true, testBinding(), redaction);
        effects.now = 200;
        runtime.onTimer(testBinding(), redaction, tasks.effects());
        try std.testing.expectEqual(@as(u64, 42), runtime.store.find(id).?.occurrences()[0].task_id);
        try std.testing.expectEqual(@as(?u64, null), effects.armed_at);
        runtime.deinit();
        effects.restored_bytes = storage[0..effects.durable_len];
        effects.commit_result = .committed;
        var restored = try Runtime.init(std.testing.allocator, .{ .max_items = 1, .max_projection_bytes = 8192 }, .{ .timer = effects.timer(), .persistence = effects.persistence() });
        defer restored.deinit();
        _ = restored.recoverInterruptedNoFail(redaction);
        _ = restored.setBackgroundAvailable(true, testBinding(), redaction);
        effects.now = 400;
        restored.onTimer(testBinding(), redaction, tasks.effects());
        try std.testing.expectEqual(@as(u64, 43), tasks.next_task_id);
        const occurrence = restored.store.find(id).?.occurrences()[0];
        if (scenario.landed) {
            try std.testing.expectEqual(state.OccurrenceResult.submitted, occurrence.result);
            try std.testing.expectEqual(@as(u64, 42), occurrence.task_id);
        } else {
            try std.testing.expectEqual(state.OccurrenceResult.rejected, occurrence.result);
            try std.testing.expectEqual(FailureReason.host_interrupted, occurrence.reason.?);
        }
    }
}

test "unrelated mutations retain in-process redaction facts" {
    var effects: TestEffects = .{};
    var runtime = try Runtime.init(std.testing.allocator, .{ .max_items = 2, .max_projection_bytes = 8192 }, .{ .timer = effects.timer(), .persistence = effects.persistence() });
    defer runtime.deinit();
    const redaction = testRedaction(&effects);
    const first = try runtime.create(testDefinition("[redacted]", "[redacted]"), testBinding(), redaction);
    runtime.store.find(first).?.title_redacted = true;
    runtime.store.find(first).?.input.redacted = true;
    _ = try runtime.create(testDefinition("unrelated", "inspect"), testBinding(), redaction);
    try std.testing.expect(runtime.store.find(first).?.title_redacted);
    try std.testing.expect(runtime.store.find(first).?.input.redacted);
}

test "late calendar wake selects one latest local occurrence and advances past the DST fold" {
    var effects: TestEffects = .{ .now = 1_793_424_600 };
    var tasks: TestTasks = .{};
    var runtime = try Runtime.init(std.testing.allocator, .{ .max_items = 1, .max_projection_bytes = 8192 }, .{ .timer = effects.timer(), .persistence = effects.persistence() });
    defer runtime.deinit();
    const redaction = testRedaction(&effects);
    var definition = testDefinition("calendar", "inspect");
    definition.recurrence = .{ .calendar = .{ .start_at_unix_seconds = effects.now, .timezone = .@"America/New_York", .frequency = .daily } };
    const id = try runtime.create(definition, testBinding(), redaction);
    _ = runtime.setBackgroundAvailable(true, testBinding(), redaction);
    effects.now = 1_793_513_400; // Second 01:10, after the first 01:30 has passed.
    runtime.onTimer(testBinding(), redaction, tasks.effects());
    const occurrence = runtime.store.find(id).?.occurrences()[0];
    try std.testing.expectEqual(@as(u64, 1_793_511_000), occurrence.planned_at_unix_seconds);
    try std.testing.expectEqual(@as(?u64, 1_793_601_000), effects.armed_at);
    runtime.onTimer(testBinding(), redaction, tasks.effects());
    try std.testing.expectEqual(@as(u64, 43), tasks.next_task_id);
}

test "creation timezone is captured once and survives edits and restart" {
    var effects: TestEffects = .{};
    var runtime = try Runtime.init(std.testing.allocator, .{ .max_items = 1, .max_projection_bytes = 8192 }, .{ .timer = effects.timer(), .persistence = effects.persistence() });
    defer runtime.deinit();
    const redaction = testRedaction(&effects);
    var definition = testDefinition("zone", "inspect");
    definition.recurrence = .{ .calendar = .{ .start_at_unix_seconds = 200, .timezone = .@"Asia/Shanghai", .frequency = .daily } };
    const id = try runtime.create(definition, testBinding(), redaction);
    definition.recurrence.calendar.timezone = .@"Europe/Berlin";
    try runtime.update(id, 1, definition, testBinding(), redaction);
    var bytes: [persistence.max_store_bytes]u8 = undefined;
    const encoded = try persistence.encode(&bytes, &runtime.store);
    var restored = try persistence.decode(std.testing.allocator, encoded, .{ .max_items = 1, .max_projection_bytes = 8192 });
    defer restored.deinit();
    try std.testing.expectEqual(TimeZone.@"Asia/Shanghai", restored.find(id).?.created_timezone.?);
}

test "title-only edit must not replay a consumed timer occurrence" {
    var effects: TestEffects = .{};
    var tasks: TestTasks = .{};
    var runtime = try Runtime.init(std.testing.allocator, .{ .max_items = 1, .max_projection_bytes = 8192 }, .{ .timer = effects.timer(), .persistence = effects.persistence() });
    defer runtime.deinit();
    const redaction = testRedaction(&effects);
    var definition = testDefinition("before", "inspect");
    definition.recurrence = .{ .interval = .{ .start_at_unix_seconds = 200, .every_seconds = 60 } };
    const id = try runtime.create(definition, testBinding(), redaction);
    _ = runtime.setBackgroundAvailable(true, testBinding(), redaction);
    effects.now = 200;
    runtime.onTimer(testBinding(), redaction, tasks.effects());
    tasks.terminal = .{ .outcome = .completed, .permission_required = false };
    _ = runtime.reconcileNoFail(testBinding(), redaction, tasks.effects());
    definition.title = "after";
    try runtime.update(id, 1, definition, testBinding(), redaction);
    runtime.onTimer(testBinding(), redaction, tasks.effects());
    try std.testing.expectEqual(@as(usize, 1), runtime.store.find(id).?.occurrence_count);
    try std.testing.expectEqual(@as(u64, 43), tasks.next_task_id);
}

test "pause and resume after clock rollback must not replay a consumed point" {
    var effects: TestEffects = .{};
    var tasks: TestTasks = .{};
    var runtime = try Runtime.init(std.testing.allocator, .{ .max_items = 1, .max_projection_bytes = 8192 }, .{ .timer = effects.timer(), .persistence = effects.persistence() });
    defer runtime.deinit();
    const redaction = testRedaction(&effects);
    var definition = testDefinition("clock", "inspect");
    definition.recurrence = .{ .interval = .{ .start_at_unix_seconds = 200, .every_seconds = 60 } };
    const id = try runtime.create(definition, testBinding(), redaction);
    _ = runtime.setBackgroundAvailable(true, testBinding(), redaction);
    effects.now = 200;
    runtime.onTimer(testBinding(), redaction, tasks.effects());
    tasks.terminal = .{ .outcome = .completed, .permission_required = false };
    _ = runtime.reconcileNoFail(testBinding(), redaction, tasks.effects());
    _ = try runtime.setEnabled(id, 1, false, testBinding(), redaction);
    effects.now = 150;
    _ = try runtime.setEnabled(id, 2, true, testBinding(), redaction);
    effects.now = 200;
    runtime.onTimer(testBinding(), redaction, tasks.effects());
    try std.testing.expectEqual(@as(usize, 1), runtime.store.find(id).?.occurrence_count);
    try std.testing.expectEqual(@as(u64, 43), tasks.next_task_id);
}

test "consumed one-time schedules stay completed after editing and enabling" {
    var effects: TestEffects = .{};
    var tasks: TestTasks = .{};
    var runtime = try Runtime.init(std.testing.allocator, .{ .max_items = 1, .max_projection_bytes = 8192 }, .{ .timer = effects.timer(), .persistence = effects.persistence() });
    defer runtime.deinit();
    const redaction = testRedaction(&effects);
    var definition = testDefinition("once", "inspect");
    const id = try runtime.create(definition, testBinding(), redaction);
    _ = runtime.setBackgroundAvailable(true, testBinding(), redaction);
    effects.now = 200;
    runtime.onTimer(testBinding(), redaction, tasks.effects());
    effects.now = 150;
    definition.title = "renamed";
    try runtime.update(id, 1, definition, testBinding(), redaction);
    try std.testing.expect(!try runtime.setEnabled(id, 2, true, testBinding(), redaction));
    try std.testing.expectEqual(Health.completed, runtime.store.find(id).?.health);
    try std.testing.expectEqual(@as(?u64, null), effects.armed_at);
    effects.now = 200;
    runtime.onTimer(testBinding(), redaction, tasks.effects());
    try std.testing.expectEqual(@as(u64, 43), tasks.next_task_id);
}

test "calendar edits and resume respect the consumed absolute boundary" {
    var effects: TestEffects = .{};
    var tasks: TestTasks = .{};
    var runtime = try Runtime.init(std.testing.allocator, .{ .max_items = 1, .max_projection_bytes = 8192 }, .{ .timer = effects.timer(), .persistence = effects.persistence() });
    defer runtime.deinit();
    const redaction = testRedaction(&effects);
    var definition = testDefinition("calendar", "inspect");
    definition.recurrence = .{ .calendar = .{ .start_at_unix_seconds = 200, .timezone = .UTC, .frequency = .daily } };
    const id = try runtime.create(definition, testBinding(), redaction);
    try std.testing.expectEqual(@as(u64, 1), try runtime.epoch(id));
    try std.testing.expectEqual(@as(u64, 1), try runtime.epoch(id));
    _ = runtime.setBackgroundAvailable(true, testBinding(), redaction);
    effects.now = 200;
    runtime.onTimer(testBinding(), redaction, tasks.effects());
    definition.title = "renamed";
    try runtime.update(id, 1, definition, testBinding(), redaction);
    try std.testing.expectEqual(@as(?u64, 86600), effects.armed_at);
    _ = try runtime.setEnabled(id, 2, false, testBinding(), redaction);
    effects.now = 150;
    _ = try runtime.setEnabled(id, 3, true, testBinding(), redaction);
    try std.testing.expectEqual(@as(?u64, 86600), effects.armed_at);
    effects.now = 200;
    runtime.onTimer(testBinding(), redaction, tasks.effects());
    try std.testing.expectEqual(@as(u64, 43), tasks.next_task_id);
    // An explicit rule change also cannot reuse an already consumed identity.
    definition.recurrence = .{ .interval = .{ .start_at_unix_seconds = 199, .every_seconds = 60 } };
    effects.now = 150;
    try runtime.update(id, 4, definition, testBinding(), redaction);
    try std.testing.expectEqual(@as(?u64, 259), effects.armed_at);
    try std.testing.expectEqual(@as(u64, 5), try runtime.epoch(id));
}

test "multiple weekdays admit only the latest due occurrence and keep the consumed boundary" {
    var effects: TestEffects = .{};
    effects.now = 1793606400 - 1;
    var tasks: TestTasks = .{};
    var runtime = try Runtime.init(std.testing.allocator, .{ .max_items = 1, .max_projection_bytes = 8192 }, .{ .timer = effects.timer(), .persistence = effects.persistence() });
    defer runtime.deinit();
    const redaction = testRedaction(&effects);
    var definition = testDefinition("weekdays", "inspect");
    definition.recurrence = .{ .calendar = .{ .start_at_unix_seconds = 1793606400, .timezone = .UTC, .frequency = .weekly, .days = 10 } };
    const id = try runtime.create(definition, testBinding(), redaction);
    _ = runtime.setBackgroundAvailable(true, testBinding(), redaction);
    try std.testing.expectEqual(@as(?u64, 1793692800), effects.armed_at);
    effects.now = 1793952000;
    runtime.onTimer(testBinding(), redaction, tasks.effects());
    const item = runtime.store.find(id).?;
    try std.testing.expectEqual(@as(usize, 1), item.occurrence_count);
    try std.testing.expectEqual(@as(?u64, 1793865600), item.last_timer_planned_at_unix_seconds);
    try std.testing.expectEqual(@as(?u64, 1794297600), item.next_run_at_unix_seconds);
    tasks.terminal = .{ .outcome = .completed, .permission_required = false };
    _ = runtime.reconcileNoFail(testBinding(), redaction, tasks.effects());
    _ = try runtime.setEnabled(id, 1, false, testBinding(), redaction);
    effects.now = 1793692800;
    _ = try runtime.setEnabled(id, 2, true, testBinding(), redaction);
    try std.testing.expectEqual(@as(?u64, 1794297600), runtime.store.find(id).?.next_run_at_unix_seconds);
    runtime.onTimer(testBinding(), redaction, tasks.effects());
    try std.testing.expectEqual(@as(usize, 1), runtime.store.find(id).?.occurrence_count);
}
