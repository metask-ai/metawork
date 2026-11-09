//! Product Schedule-owned bounded state and occurrence transitions.

const std = @import("std");
const models_contract = @import("metawork_product_models_contract");
const calendar = @import("product_schedule_calendar");
pub const TimeZone = calendar.Zone;
pub const CalendarFrequency = calendar.Frequency;
pub const calendarDayMask = calendar.dayMask;
pub const localMinute = calendar.localMinute;

pub const minimum_interval_seconds: u64 = 60;
pub const max_occurrence_history: usize = 16;

pub const Error = std.mem.Allocator.Error || error{
    ScheduledTaskCapacity,
    ScheduledTaskIdentityExhausted,
    UnknownScheduledTask,
    ScheduledTaskEpochMismatch,
    ScheduledTaskNeedsAttention,
    ScheduledOccurrenceCapacity,
    InvalidSchedule,
    InvalidScheduledTaskRestore,
    ProjectionCapacity,
};

pub const Protocol = models_contract.Protocol;

pub const PermissionProfile = enum {
    approval_required,
    full_access,
};

pub const LocalRecurrence = struct {
    timezone: TimeZone,
    minute: u16,
    frequency: CalendarFrequency,
    days: u32,

    pub fn resolve(self: LocalRecurrence, now: u64, previous: ?Recurrence) error{InvalidSchedule}!Recurrence {
        const start = switch (self.frequency) {
            .daily, .weekly, .monthly => calendar.nextLocalTime(self.timezone, self.minute, self.frequency, self.days, now),
            .hourly, .yearly => legacy: {
                const prior = previous orelse return error.InvalidSchedule;
                if (prior != .calendar or prior.calendar.frequency != self.frequency) return error.InvalidSchedule;
                break :legacy calendar.timeOnAnchorDate(self.timezone, self.minute, prior.calendar.start_at_unix_seconds);
            },
        } orelse return error.InvalidSchedule;
        return .{ .calendar = .{
            .start_at_unix_seconds = start,
            .timezone = self.timezone,
            .frequency = self.frequency,
            .days = self.days,
        } };
    }
};

pub const Recurrence = union(enum) {
    calendar: calendar.Rule,
    once: struct {
        at_unix_seconds: u64,
    },
    interval: struct {
        start_at_unix_seconds: u64,
        every_seconds: u64,
    },

    pub fn validate(self: Recurrence) error{InvalidSchedule}!void {
        switch (self) {
            .calendar => |rule| try rule.validate(),
            .once => |once| {
                if (once.at_unix_seconds == 0) return error.InvalidSchedule;
            },
            .interval => |interval| {
                if (interval.start_at_unix_seconds == 0 or
                    interval.every_seconds < minimum_interval_seconds)
                    return error.InvalidSchedule;
            },
        }
    }

    pub fn firstAtOrAfter(
        self: Recurrence,
        unix_seconds: u64,
    ) error{InvalidSchedule}!?u64 {
        try self.validate();
        return switch (self) {
            .calendar => |rule| try rule.firstAtOrAfter(unix_seconds),
            .once => |once| if (once.at_unix_seconds >= unix_seconds)
                once.at_unix_seconds
            else
                null,
            .interval => |interval| blk: {
                if (unix_seconds <= interval.start_at_unix_seconds)
                    break :blk interval.start_at_unix_seconds;
                const elapsed = unix_seconds - interval.start_at_unix_seconds;
                const completed = elapsed / interval.every_seconds;
                const aligned = std.math.mul(
                    u64,
                    completed,
                    interval.every_seconds,
                ) catch return error.InvalidSchedule;
                var candidate = std.math.add(
                    u64,
                    interval.start_at_unix_seconds,
                    aligned,
                ) catch return error.InvalidSchedule;
                if (candidate < unix_seconds)
                    candidate = std.math.add(
                        u64,
                        candidate,
                        interval.every_seconds,
                    ) catch return error.InvalidSchedule;
                break :blk candidate;
            },
        };
    }

    pub fn firstStrictlyAfter(
        self: Recurrence,
        unix_seconds: u64,
    ) error{InvalidSchedule}!?u64 {
        if (unix_seconds == std.math.maxInt(u64))
            return switch (self) {
                .once => null,
                .interval, .calendar => error.InvalidSchedule,
            };
        return self.firstAtOrAfter(unix_seconds + 1);
    }

    pub fn lastAtOrBefore(self: Recurrence, unix_seconds: u64) error{InvalidSchedule}!?u64 {
        try self.validate();
        return switch (self) {
            .once => |once| if (unix_seconds >= once.at_unix_seconds) once.at_unix_seconds else null,
            .interval => |interval| if (unix_seconds < interval.start_at_unix_seconds) null else interval.start_at_unix_seconds + ((unix_seconds - interval.start_at_unix_seconds) / interval.every_seconds) * interval.every_seconds,
            .calendar => |rule| try rule.lastAtOrBefore(unix_seconds),
        };
    }
};

pub const OwnedInput = struct {
    value: []u8,
    redacted: bool = false,

    pub fn borrowed(self: *const OwnedInput) []const u8 {
        return self.value;
    }
};

pub const Health = enum {
    ready,
    paused,
    needs_attention,
    completed,
};

pub const FailureReason = enum {
    previous_task_running,
    execution_changed,
    workspace_unavailable,
    capacity_reached,
    shutting_down,
    task_start_failed,
    timer_unavailable,
    persistence_failed,
    host_interrupted,
    permission_required,
};

pub const OccurrenceSource = enum {
    timer,
    manual,
};

pub const OccurrenceResult = enum {
    claimed,
    submitted,
    skipped,
    rejected,
};

pub const OccurrenceTaskOutcome = enum {
    completed,
    stopped,
    cancelled,
    interrupted,
    failed,
    dependency_contract_failure,
    unavailable,
};

pub const Occurrence = struct {
    planned_at_unix_seconds: u64,
    triggered_at_unix_seconds: u64,
    source: OccurrenceSource,
    result: OccurrenceResult,
    task_id: u64 = 0,
    reason: ?FailureReason = null,
    task_outcome: ?OccurrenceTaskOutcome = null,
    notification_sent: bool = false,
};

pub const Definition = struct {
    title: []const u8,
    binding: Binding,
    permission_profile: PermissionProfile,
    input: []const u8,
    recurrence: Recurrence,
    timezone: ?TimeZone = null,
};

pub const Binding = struct {
    model_ref: models_contract.ModelRef,
    source_generation: u64,
    protocol: Protocol,
};

const OwnedBinding = struct {
    source_id: []u8,
    model_id: []u8,
    source_generation: u64,
    protocol: Protocol,
};

pub const Item = struct {
    id: u64,
    epoch: u64 = 1,
    title: []u8,
    title_redacted: bool = false,
    binding: OwnedBinding,
    permission_profile: PermissionProfile,
    input: OwnedInput,
    recurrence: Recurrence,
    created_timezone: ?TimeZone = null,
    enabled: bool = true,
    health: Health = .ready,
    failure_reason: ?FailureReason = null,
    next_run_at_unix_seconds: ?u64,
    /// Monotonic automatic-occurrence boundary, independent of bounded history.
    last_timer_planned_at_unix_seconds: ?u64 = null,
    last_occurrence: ?Occurrence = null,
    occurrence_history: [max_occurrence_history]Occurrence = undefined,
    occurrence_count: usize = 0,
    /// Transient resolve refusal, cleared by an authority refresh or edit.
    /// Never persisted: it does not invalidate the captured definition.
    preflight_blocked: bool = false,

    pub fn occurrences(self: *const Item) []const Occurrence {
        return self.occurrence_history[0..self.occurrence_count];
    }

    pub fn bindingView(self: *const Item) Binding {
        return .{
            .model_ref = .{
                .source_id = self.binding.source_id,
                .model_id = self.binding.model_id,
            },
            .source_generation = self.binding.source_generation,
            .protocol = self.binding.protocol,
        };
    }

    pub fn bindingModelMutable(self: *Item) []u8 {
        return self.binding.model_id;
    }
};

pub const RestoredItem = struct {
    id: u64,
    epoch: u64,
    definition: Definition,
    enabled: bool,
    health: Health,
    failure_reason: ?FailureReason,
    next_run_at_unix_seconds: ?u64,
    occurrences: []const Occurrence,
    created_timezone: ?TimeZone = null,
    last_timer_planned_at_unix_seconds: ?u64 = null,
};

pub const Limits = struct {
    max_items: usize,
    max_projection_bytes: usize,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    items: []?Item,
    max_projection_bytes: usize,
    projection_bytes: usize = 0,
    next_id: u64 = 1,

    pub fn init(
        allocator: std.mem.Allocator,
        limits: Limits,
    ) (std.mem.Allocator.Error || error{ProjectionCapacity})!Store {
        if (limits.max_items == 0 or limits.max_projection_bytes == 0)
            return error.ProjectionCapacity;
        const items = try allocator.alloc(?Item, limits.max_items);
        @memset(items, null);
        return .{
            .allocator = allocator,
            .items = items,
            .max_projection_bytes = limits.max_projection_bytes,
        };
    }

    pub fn deinit(self: *Store) void {
        for (self.items) |*entry| {
            const item = &(entry.* orelse continue);
            self.deinitItem(item);
        }
        self.allocator.free(self.items);
        std.debug.assert(self.projection_bytes == 0);
        self.* = undefined;
    }

    pub fn clone(
        self: *const Store,
        allocator: std.mem.Allocator,
    ) Error!Store {
        var result = try Store.init(allocator, .{
            .max_items = self.items.len,
            .max_projection_bytes = self.max_projection_bytes,
        });
        errdefer result.deinit();
        for (self.items) |entry| {
            const item = entry orelse continue;
            try result.restoreItem(.{
                .id = item.id,
                .epoch = item.epoch,
                .definition = .{
                    .title = item.title,
                    .binding = item.bindingView(),
                    .permission_profile = item.permission_profile,
                    .input = item.input.borrowed(),
                    .recurrence = item.recurrence,
                },
                .enabled = item.enabled,
                .health = item.health,
                .failure_reason = item.failure_reason,
                .next_run_at_unix_seconds = item.next_run_at_unix_seconds,
                .occurrences = item.occurrences(),
                .created_timezone = item.created_timezone,
                .last_timer_planned_at_unix_seconds = item.last_timer_planned_at_unix_seconds,
            });
            const copied = result.find(item.id).?;
            copied.preflight_blocked = item.preflight_blocked;
            copied.title_redacted = item.title_redacted;
            copied.input.redacted = item.input.redacted;
        }
        result.next_id = self.next_id;
        return result;
    }

    pub fn restoreItem(
        self: *Store,
        restored: RestoredItem,
    ) Error!void {
        if (restored.id == 0 or restored.id == std.math.maxInt(u64) or
            restored.epoch == 0 or
            restored.occurrences.len > max_occurrence_history or
            self.find(restored.id) != null)
            return error.InvalidScheduledTaskRestore;
        if (!validDefinition(restored.definition))
            return error.InvalidScheduledTaskRestore;
        try restored.definition.recurrence.validate();
        if (!validRestoredState(restored))
            return error.InvalidScheduledTaskRestore;
        var snapshot = restored;
        if (snapshot.last_timer_planned_at_unix_seconds == 0)
            return error.InvalidScheduledTaskRestore;
        for (restored.occurrences) |occurrence| {
            if (!validOccurrence(occurrence)) return error.InvalidScheduledTaskRestore;
            if (occurrence.source != .timer) continue;
            if (restored.last_timer_planned_at_unix_seconds) |last|
                if (occurrence.planned_at_unix_seconds > last) return error.InvalidScheduledTaskRestore;
            snapshot.last_timer_planned_at_unix_seconds = @max(
                snapshot.last_timer_planned_at_unix_seconds orelse 0,
                occurrence.planned_at_unix_seconds,
            );
        }
        // Older schema-1 stores have no independent boundary. Recover it
        // from retained timer facts, and repair a cursor rewound by the old
        // edit/resume path without discarding the persisted definitions.
        if (restored.last_timer_planned_at_unix_seconds == null and snapshot.enabled) {
            if (snapshot.last_timer_planned_at_unix_seconds) |last| {
                if (snapshot.next_run_at_unix_seconds) |next| {
                    if (next <= last) {
                        snapshot.next_run_at_unix_seconds = try snapshot.definition.recurrence.firstStrictlyAfter(last);
                        if (snapshot.next_run_at_unix_seconds == null) {
                            snapshot.enabled = false;
                            snapshot.health = .completed;
                        }
                    }
                }
            }
        }
        if (!validRestoredState(snapshot))
            return error.InvalidScheduledTaskRestore;
        const slot = self.emptySlot() orelse return error.ScheduledTaskCapacity;
        var item = try self.cloneDefinition(
            restored.id,
            restored.epoch,
            restored.definition,
            snapshot.next_run_at_unix_seconds,
        );
        errdefer self.deinitItem(&item);
        item.enabled = snapshot.enabled;
        item.health = snapshot.health;
        item.failure_reason = restored.failure_reason;
        item.created_timezone = restored.created_timezone;
        item.last_timer_planned_at_unix_seconds = snapshot.last_timer_planned_at_unix_seconds;
        for (restored.occurrences, 0..) |occurrence, index| {
            item.occurrence_history[index] = occurrence;
        }
        item.occurrence_count = restored.occurrences.len;
        item.last_occurrence = if (item.occurrence_count == 0)
            null
        else
            item.occurrence_history[item.occurrence_count - 1];
        self.items[slot] = item;
        if (restored.id >= self.next_id) {
            if (restored.id == std.math.maxInt(u64))
                return error.ScheduledTaskIdentityExhausted;
            self.next_id = restored.id + 1;
        }
    }

    pub fn restoreNextId(self: *Store, next_id: u64) Error!void {
        if (next_id == 0 or next_id < self.next_id)
            return error.InvalidScheduledTaskRestore;
        self.next_id = next_id;
    }

    pub fn create(
        self: *Store,
        definition: Definition,
        now_unix_seconds: u64,
    ) Error!u64 {
        const slot = self.emptySlot() orelse return error.ScheduledTaskCapacity;
        if (self.next_id == 0 or self.next_id == std.math.maxInt(u64))
            return error.ScheduledTaskIdentityExhausted;
        const next_run = (try definition.recurrence.firstAtOrAfter(
            now_unix_seconds,
        )) orelse return error.InvalidSchedule;
        var item = try self.cloneDefinition(
            self.next_id,
            1,
            definition,
            next_run,
        );
        errdefer self.deinitItem(&item);
        const id = self.next_id;
        item.created_timezone = definition.timezone orelse switch (definition.recurrence) {
            .calendar => |rule| rule.timezone,
            else => null,
        };
        self.next_id += 1;
        self.items[slot] = item;
        return id;
    }

    pub fn update(
        self: *Store,
        id: u64,
        expected_epoch: u64,
        definition: Definition,
        now_unix_seconds: u64,
    ) Error!void {
        const slot = self.findIndex(id) orelse return error.UnknownScheduledTask;
        const current = &(self.items[slot] orelse unreachable);
        if (expected_epoch == 0 or current.epoch != expected_epoch)
            return error.ScheduledTaskEpochMismatch;
        if (current.epoch == std.math.maxInt(u64))
            return error.ScheduledTaskIdentityExhausted;
        const preserve_paused = current.health == .paused;
        const next_run = try nextUnconsumedAtOrAfter(current, definition.recurrence, now_unix_seconds);
        var replacement = try self.cloneDefinition(
            id,
            current.epoch + 1,
            definition,
            next_run,
        );
        errdefer self.deinitItem(&replacement);
        replacement.last_occurrence = current.last_occurrence;
        replacement.created_timezone = current.created_timezone;
        replacement.last_timer_planned_at_unix_seconds = current.last_timer_planned_at_unix_seconds;
        replacement.occurrence_count = current.occurrence_count;
        @memcpy(
            replacement.occurrence_history[0..current.occurrence_count],
            current.occurrence_history[0..current.occurrence_count],
        );
        if (preserve_paused) {
            replacement.enabled = false;
            replacement.health = .paused;
            replacement.failure_reason = null;
            replacement.next_run_at_unix_seconds = null;
        } else if (next_run == null) {
            replacement.enabled = false;
            replacement.health = .completed;
        }
        self.deinitItem(current);
        self.items[slot] = replacement;
    }

    pub fn setEnabled(
        self: *Store,
        id: u64,
        expected_epoch: u64,
        enabled: bool,
        now_unix_seconds: u64,
    ) Error!void {
        const item = try self.require(id, expected_epoch);
        if (item.health == .needs_attention) return error.ScheduledTaskNeedsAttention;
        if (item.enabled == enabled and
            ((enabled and item.health == .ready) or
                (!enabled and item.health == .paused)))
            return;
        if (item.epoch == std.math.maxInt(u64))
            return error.ScheduledTaskIdentityExhausted;
        if (enabled) {
            item.next_run_at_unix_seconds = try nextUnconsumedAtOrAfter(item, item.recurrence, now_unix_seconds);
            item.enabled = item.next_run_at_unix_seconds != null;
            item.health = if (item.enabled) .ready else .completed;
            item.failure_reason = null;
        } else {
            item.enabled = false;
            item.health = .paused;
            item.failure_reason = null;
            item.next_run_at_unix_seconds = null;
        }
        item.epoch += 1;
    }

    pub fn delete(
        self: *Store,
        id: u64,
        expected_epoch: u64,
    ) Error!void {
        const slot = self.findIndex(id) orelse return error.UnknownScheduledTask;
        const item = &(self.items[slot] orelse unreachable);
        if (expected_epoch == 0 or item.epoch != expected_epoch)
            return error.ScheduledTaskEpochMismatch;
        self.deinitItem(item);
        self.items[slot] = null;
    }

    pub fn find(self: *Store, id: u64) ?*Item {
        const index = self.findIndex(id) orelse return null;
        return &(self.items[index] orelse unreachable);
    }

    pub fn earliestDue(self: *Store) ?*Item {
        var earliest: ?*Item = null;
        for (self.items) |*entry| {
            const item = &(entry.* orelse continue);
            if (!item.enabled or item.health != .ready or
                item.next_run_at_unix_seconds == null)
                continue;
            if (earliest == null or
                item.next_run_at_unix_seconds.? <
                    earliest.?.next_run_at_unix_seconds.?)
                earliest = item;
        }
        return earliest;
    }

    pub fn markSubmitted(
        self: *Store,
        item: *Item,
        planned_at_unix_seconds: u64,
        triggered_at_unix_seconds: u64,
        source: OccurrenceSource,
        task_id: u64,
    ) error{ InvalidSchedule, ScheduledOccurrenceCapacity }!void {
        std.debug.assert(task_id != 0);
        try self.recordOccurrence(item, .{
            .planned_at_unix_seconds = planned_at_unix_seconds,
            .triggered_at_unix_seconds = triggered_at_unix_seconds,
            .source = source,
            .result = .submitted,
            .task_id = task_id,
        });
        if (source == .manual) return;
        try advanceAfterTimer(item, triggered_at_unix_seconds);
    }

    pub fn claim(
        self: *Store,
        item: *Item,
        planned_at_unix_seconds: u64,
        triggered_at_unix_seconds: u64,
        source: OccurrenceSource,
    ) error{ InvalidSchedule, ScheduledOccurrenceCapacity }!void {
        try self.recordOccurrence(item, .{
            .planned_at_unix_seconds = planned_at_unix_seconds,
            .triggered_at_unix_seconds = triggered_at_unix_seconds,
            .source = source,
            .result = .claimed,
        });
        if (source == .timer)
            try advanceAfterTimer(item, triggered_at_unix_seconds);
    }

    pub fn finalizeClaimSubmitted(
        _: *Store,
        item: *Item,
        planned_at_unix_seconds: u64,
        source: OccurrenceSource,
        task_id: u64,
    ) error{InvalidSchedule}!void {
        if (task_id == 0) return error.InvalidSchedule;
        const occurrence = claimedOccurrence(
            item,
            planned_at_unix_seconds,
            source,
        ) orelse return error.InvalidSchedule;
        occurrence.result = .submitted;
        occurrence.task_id = task_id;
        item.last_occurrence = occurrence.*;
    }

    pub fn finalizeClaimRejected(
        self: *Store,
        item: *Item,
        planned_at_unix_seconds: u64,
        source: OccurrenceSource,
        reason: FailureReason,
        task_id: u64,
    ) error{InvalidSchedule}!void {
        const occurrence = claimedOccurrence(
            item,
            planned_at_unix_seconds,
            source,
        ) orelse return error.InvalidSchedule;
        occurrence.result = .rejected;
        occurrence.reason = reason;
        occurrence.task_id = task_id;
        item.last_occurrence = occurrence.*;
        self.markNeedsAttention(item, reason);
    }

    pub fn interruptClaimedOccurrences(self: *Store) bool {
        var changed = false;
        for (self.items) |*entry| {
            const item = &(entry.* orelse continue);
            for (item.occurrence_history[0..item.occurrence_count], 0..) |*occurrence, index| {
                if (occurrence.result != .claimed) continue;
                occurrence.result = .rejected;
                occurrence.reason = .host_interrupted;
                if (index + 1 == item.occurrence_count) item.last_occurrence = occurrence.*;
                self.markNeedsAttention(item, .host_interrupted);
                changed = true;
            }
        }
        return changed;
    }

    pub fn finalizeOccurrenceTask(
        self: *Store,
        item: *Item,
        planned_at_unix_seconds: u64,
        source: OccurrenceSource,
        task_id: u64,
        outcome: OccurrenceTaskOutcome,
        reason: ?FailureReason,
    ) error{InvalidSchedule}!void {
        if (reason != null and reason != .permission_required)
            return error.InvalidSchedule;
        var index = item.occurrence_count;
        while (index != 0) {
            index -= 1;
            const occurrence = &item.occurrence_history[index];
            if (occurrence.planned_at_unix_seconds !=
                planned_at_unix_seconds or occurrence.source != source or
                occurrence.task_id != task_id or occurrence.result != .submitted)
                continue;
            if (occurrence.task_outcome != null or occurrence.notification_sent)
                return error.InvalidSchedule;
            occurrence.task_outcome = outcome;
            occurrence.reason = reason;
            occurrence.notification_sent = true;
            if (item.last_occurrence != null and
                item.last_occurrence.?.planned_at_unix_seconds ==
                    planned_at_unix_seconds and
                item.last_occurrence.?.source == source and
                item.last_occurrence.?.task_id == task_id)
            {
                item.last_occurrence.?.task_outcome = outcome;
                item.last_occurrence.?.reason = reason;
                item.last_occurrence.?.notification_sent = true;
            }
            if (reason) |value| self.markNeedsAttention(item, value);
            return;
        }
        return error.InvalidSchedule;
    }

    pub fn markSkipped(
        self: *Store,
        item: *Item,
        planned_at_unix_seconds: u64,
        triggered_at_unix_seconds: u64,
        blocking_task_id: u64,
    ) error{ InvalidSchedule, ScheduledOccurrenceCapacity }!void {
        try self.recordOccurrence(item, .{
            .planned_at_unix_seconds = planned_at_unix_seconds,
            .triggered_at_unix_seconds = triggered_at_unix_seconds,
            .source = .timer,
            .result = .skipped,
            .task_id = blocking_task_id,
            .reason = .previous_task_running,
        });
        try advanceAfterTimer(item, triggered_at_unix_seconds);
    }

    pub fn markNeedsAttention(
        _: *Store,
        item: *Item,
        reason: FailureReason,
    ) void {
        item.enabled = false;
        item.health = .needs_attention;
        item.failure_reason = reason;
        item.next_run_at_unix_seconds = null;
    }

    pub fn markRejected(
        self: *Store,
        item: *Item,
        planned_at_unix_seconds: u64,
        triggered_at_unix_seconds: u64,
        source: OccurrenceSource,
        reason: FailureReason,
    ) error{ScheduledOccurrenceCapacity}!void {
        try self.recordOccurrence(item, .{
            .planned_at_unix_seconds = planned_at_unix_seconds,
            .triggered_at_unix_seconds = triggered_at_unix_seconds,
            .source = source,
            .result = .rejected,
            .reason = reason,
        });
        self.markNeedsAttention(item, reason);
    }

    fn recordOccurrence(
        _: *Store,
        item: *Item,
        occurrence: Occurrence,
    ) error{ScheduledOccurrenceCapacity}!void {
        if (item.occurrence_count == max_occurrence_history) {
            const evict = for (item.occurrences(), 0..) |prior, index| {
                if (prior.result != .claimed and
                    (prior.result != .submitted or prior.notification_sent))
                    break index;
            } else return error.ScheduledOccurrenceCapacity;
            std.mem.copyForwards(
                Occurrence,
                item.occurrence_history[evict .. max_occurrence_history - 1],
                item.occurrence_history[evict + 1 .. max_occurrence_history],
            );
            item.occurrence_count -= 1;
        }
        item.occurrence_history[item.occurrence_count] = occurrence;
        item.occurrence_count += 1;
        item.last_occurrence = occurrence;
        if (occurrence.source == .timer)
            item.last_timer_planned_at_unix_seconds = @max(
                item.last_timer_planned_at_unix_seconds orelse 0,
                occurrence.planned_at_unix_seconds,
            );
    }

    fn cloneDefinition(
        self: *Store,
        id: u64,
        epoch: u64,
        definition: Definition,
        next_run: ?u64,
    ) Error!Item {
        var item: Item = undefined;
        const title = try self.copy(definition.title);
        errdefer self.free(title);
        var binding = try self.cloneBinding(definition.binding);
        errdefer self.deinitBinding(&binding);
        var input = try self.cloneInput(definition.input);
        errdefer self.deinitInput(&input);
        item = .{
            .id = id,
            .epoch = epoch,
            .title = title,
            .binding = binding,
            .permission_profile = definition.permission_profile,
            .input = input,
            .recurrence = definition.recurrence,
            .next_run_at_unix_seconds = next_run,
        };
        return item;
    }

    fn cloneBinding(self: *Store, binding: Binding) Error!OwnedBinding {
        const source_id = try self.copy(binding.model_ref.source_id);
        errdefer self.free(source_id);
        return .{
            .source_id = source_id,
            .model_id = try self.copy(binding.model_ref.model_id),
            .source_generation = binding.source_generation,
            .protocol = binding.protocol,
        };
    }

    fn cloneInput(self: *Store, input: []const u8) Error!OwnedInput {
        return .{ .value = try self.copy(input) };
    }

    fn deinitItem(self: *Store, item: *Item) void {
        self.free(item.title);
        self.deinitBinding(&item.binding);
        self.deinitInput(&item.input);
        item.* = undefined;
    }

    fn deinitBinding(self: *Store, binding: *OwnedBinding) void {
        self.free(binding.source_id);
        self.free(binding.model_id);
        binding.* = undefined;
    }

    fn deinitInput(self: *Store, input: *OwnedInput) void {
        self.free(input.value);
        input.* = undefined;
    }

    fn require(
        self: *Store,
        id: u64,
        expected_epoch: u64,
    ) Error!*Item {
        const item = self.find(id) orelse return error.UnknownScheduledTask;
        if (expected_epoch == 0 or item.epoch != expected_epoch)
            return error.ScheduledTaskEpochMismatch;
        return item;
    }

    fn emptySlot(self: *Store) ?usize {
        for (self.items, 0..) |entry, index|
            if (entry == null) return index;
        return null;
    }

    fn findIndex(self: *Store, id: u64) ?usize {
        if (id == 0) return null;
        for (self.items, 0..) |entry, index|
            if (entry) |item| if (item.id == id) return index;
        return null;
    }

    fn reserve(self: *Store, bytes: usize) Error!void {
        if (bytes > self.max_projection_bytes - self.projection_bytes)
            return error.ProjectionCapacity;
    }

    fn copy(self: *Store, value: []const u8) Error![]u8 {
        try self.reserve(value.len);
        const result = try self.allocator.dupe(u8, value);
        self.projection_bytes += result.len;
        return result;
    }

    fn free(self: *Store, value: []u8) void {
        self.projection_bytes -= value.len;
        self.allocator.free(value);
    }
};

fn advanceAfterTimer(
    item: *Item,
    triggered_at_unix_seconds: u64,
) error{InvalidSchedule}!void {
    const next = try item.recurrence.firstStrictlyAfter(
        triggered_at_unix_seconds,
    );
    item.next_run_at_unix_seconds = next;
    if (next == null) {
        item.enabled = false;
        item.health = .completed;
        item.failure_reason = null;
    }
}

fn nextUnconsumedAtOrAfter(item: *const Item, recurrence: Recurrence, now: u64) error{InvalidSchedule}!?u64 {
    const next = try recurrence.firstAtOrAfter(now);
    if (item.last_timer_planned_at_unix_seconds) |last| {
        if (next) |value| if (value > last) return value;
        const following = try recurrence.firstStrictlyAfter(last);
        // An exhausted consumed rule stays completed; a newly selected past
        // one-time target which was never consumed remains invalid.
        if (next == null and following != null) return error.InvalidSchedule;
        return following;
    }
    return next orelse return error.InvalidSchedule;
}

fn validRestoredState(restored: RestoredItem) bool {
    if (restored.enabled) {
        const next = restored.next_run_at_unix_seconds orelse return false;
        if (restored.last_timer_planned_at_unix_seconds) |last|
            if (next <= last) return false;
        switch (restored.definition.recurrence) {
            .calendar => |rule| {
                const aligned = rule.firstAtOrAfter(next) catch return false;
                if (aligned == null or aligned.? != next) return false;
            },
            .once => |once| if (next != once.at_unix_seconds) return false,
            .interval => |interval| {
                if (next < interval.start_at_unix_seconds or
                    (next - interval.start_at_unix_seconds) % interval.every_seconds != 0)
                    return false;
            },
        }
        return restored.health == .ready and
            restored.failure_reason == null and
            restored.next_run_at_unix_seconds != null;
    }
    return switch (restored.health) {
        .paused => restored.failure_reason == null and
            restored.next_run_at_unix_seconds == null,
        .needs_attention => restored.failure_reason != null and
            restored.next_run_at_unix_seconds == null,
        .completed => restored.failure_reason == null and
            restored.next_run_at_unix_seconds == null,
        .ready => false,
    };
}

fn validDefinition(definition: Definition) bool {
    if (definition.title.len == 0 or
        !std.unicode.utf8ValidateSlice(definition.title))
        return false;
    const binding = definition.binding;
    if (binding.model_ref.source_id.len == 0 or
        binding.model_ref.source_id.len > models_contract.Limits.provider_id_bytes or
        !std.unicode.utf8ValidateSlice(binding.model_ref.source_id) or
        binding.model_ref.model_id.len == 0 or
        binding.model_ref.model_id.len > models_contract.Limits.model_id_bytes or
        !std.unicode.utf8ValidateSlice(binding.model_ref.model_id) or
        binding.source_generation == 0)
        return false;
    if (definition.input.len == 0 or
        !std.unicode.utf8ValidateSlice(definition.input)) return false;
    return true;
}

fn validOccurrence(occurrence: Occurrence) bool {
    if (occurrence.planned_at_unix_seconds == 0 or
        occurrence.triggered_at_unix_seconds == 0)
        return false;
    if ((occurrence.task_outcome != null) != occurrence.notification_sent)
        return false;
    return switch (occurrence.result) {
        .claimed => occurrence.task_id == 0 and occurrence.reason == null and
            occurrence.task_outcome == null,
        .submitted => occurrence.task_id != 0 and
            (occurrence.reason == null or
                (occurrence.reason == .permission_required and
                    occurrence.task_outcome != null)),
        .skipped => (occurrence.task_id == 0 or occurrence.reason == .previous_task_running) and occurrence.reason != null and
            occurrence.task_outcome == null,
        .rejected => occurrence.reason != null and
            occurrence.task_outcome == null,
    };
}

fn claimedOccurrence(
    item: *Item,
    planned_at_unix_seconds: u64,
    source: OccurrenceSource,
) ?*Occurrence {
    if (item.occurrence_count == 0) return null;
    const occurrence = &item.occurrence_history[item.occurrence_count - 1];
    if (occurrence.result != .claimed or
        occurrence.planned_at_unix_seconds != planned_at_unix_seconds or
        occurrence.source != source)
        return null;
    return occurrence;
}

test "local Schedule submission uses the Host date for selected days" {
    const now = 1_959_163_200; // 2032-01-31 12:00 UTC
    var local: LocalRecurrence = .{
        .timezone = .UTC,
        .minute = 9 * 60 + 30,
        .frequency = .weekly,
        .days = try calendarDayMask(.weekly, &.{ 1, 3 }),
    };
    try std.testing.expectEqual(@as(u64, 1_959_327_000), (try local.resolve(now, null)).calendar.start_at_unix_seconds);
    local.frequency = .monthly;
    local.days = try calendarDayMask(.monthly, &.{31});
    try std.testing.expectEqual(@as(u64, 1_964_338_200), (try local.resolve(now, null)).calendar.start_at_unix_seconds);
}

test "fixed recurrence aligns without replaying missed occurrences" {
    const recurrence: Recurrence = .{ .interval = .{
        .start_at_unix_seconds = 1_000,
        .every_seconds = 300,
    } };
    try std.testing.expectEqual(
        @as(?u64, 1_000),
        try recurrence.firstAtOrAfter(900),
    );
    try std.testing.expectEqual(
        @as(?u64, 1_600),
        try recurrence.firstAtOrAfter(1_301),
    );
    try std.testing.expectEqual(
        @as(?u64, 1_600),
        try recurrence.firstStrictlyAfter(1_500),
    );
}

test "store updates optimistically and a one-time occurrence completes" {
    var store = try Store.init(std.testing.allocator, .{
        .max_items = 2,
        .max_projection_bytes = 4096,
    });
    defer store.deinit();
    const id = try store.create(.{
        .title = "Daily summary",
        .binding = .{
            .model_ref = .{ .source_id = "metask:test", .model_id = "gpt-test" },
            .source_generation = 9,
            .protocol = .openai_chat_completions,
        },
        .permission_profile = .approval_required,
        .input = "Summarize the project",
        .recurrence = .{ .once = .{ .at_unix_seconds = 2_000 } },
    }, 1_000);
    const item = store.find(id).?;
    try std.testing.expectEqual(@as(u64, 1), item.epoch);
    try store.markSubmitted(item, 2_000, 2_001, .timer, 42);
    try std.testing.expectEqual(Health.completed, item.health);
    try std.testing.expect(!item.enabled);
    try std.testing.expect(item.next_run_at_unix_seconds == null);
    try std.testing.expectEqual(@as(u64, 42), item.last_occurrence.?.task_id);
    try std.testing.expectError(
        error.ScheduledTaskEpochMismatch,
        store.delete(id, 2),
    );
    try store.delete(id, 1);
}

test "updating a paused schedule preserves its paused state" {
    var store = try Store.init(std.testing.allocator, .{
        .max_items = 2,
        .max_projection_bytes = 4096,
    });
    defer store.deinit();
    const original: Definition = .{
        .title = "Daily summary",
        .binding = .{
            .model_ref = .{ .source_id = "metask:test", .model_id = "gpt-test" },
            .source_generation = 9,
            .protocol = .openai_chat_completions,
        },
        .permission_profile = .approval_required,
        .input = "Summarize the project",
        .recurrence = .{ .interval = .{
            .start_at_unix_seconds = 2_000,
            .every_seconds = 300,
        } },
    };
    const id = try store.create(original, 1_000);
    try store.setEnabled(id, 1, false, 1_100);

    var updated = original;
    updated.title = "Updated daily summary";
    try store.update(id, 2, updated, 1_200);

    const item = store.find(id).?;
    try std.testing.expectEqual(@as(u64, 3), item.epoch);
    try std.testing.expect(!item.enabled);
    try std.testing.expectEqual(Health.paused, item.health);
    try std.testing.expectEqual(@as(?FailureReason, null), item.failure_reason);
    try std.testing.expectEqual(@as(?u64, null), item.next_run_at_unix_seconds);
    try std.testing.expectEqualStrings("Updated daily summary", item.title);
}

test "daily calendar recurrence skips DST gaps and selects the first fold instant once" {
    const spring: Recurrence = .{ .calendar = .{ .start_at_unix_seconds = 1_772_868_600, .timezone = .@"America/New_York", .frequency = .daily } };
    try std.testing.expectEqual(@as(?u64, 1_773_037_800), try spring.firstStrictlyAfter(1_772_868_600));
    try std.testing.expectEqual(@as(?u64, 1_772_868_600), try spring.lastAtOrBefore(1_772_955_000));
    const autumn: Recurrence = .{ .calendar = .{ .start_at_unix_seconds = 1_793_424_600, .timezone = .@"America/New_York", .frequency = .daily } };
    try std.testing.expectEqual(@as(?u64, 1_793_511_000), try autumn.firstStrictlyAfter(1_793_424_600));
    try std.testing.expectEqual(@as(?u64, 1_793_601_000), try autumn.firstStrictlyAfter(1_793_511_000));
    try std.testing.expectEqual(@as(?u64, 1_793_511_000), try autumn.lastAtOrBefore(1_793_514_600));
    // During the second 01:10, today's first 01:30 is already in the past.
    try std.testing.expectEqual(@as(?u64, 1_793_511_000), try autumn.lastAtOrBefore(1_793_513_400));
}

test "calendar rules survive date-line gaps and use future POSIX transitions" {
    const apia: Recurrence = .{ .calendar = .{ .start_at_unix_seconds = 1_325_181_600, .timezone = .@"Pacific/Apia", .frequency = .daily } };
    try std.testing.expectEqual(@as(?u64, 1_325_268_000), try apia.firstStrictlyAfter(1_325_181_600));
    const future: Recurrence = .{ .calendar = .{ .start_at_unix_seconds = 2_530_683_000, .timezone = .@"America/New_York", .frequency = .daily } };
    try std.testing.expectEqual(@as(?u64, 2_530_852_200), try future.firstStrictlyAfter(2_530_683_000));
}

test "hourly and weekly calendar rules preserve local components across DST" {
    const hourly: Recurrence = .{ .calendar = .{ .start_at_unix_seconds = 1_793_511_000, .timezone = .@"America/New_York", .frequency = .hourly } };
    try std.testing.expectEqual(@as(?u64, 1_793_518_200), try hourly.firstStrictlyAfter(1_793_511_000));
    const weekly: Recurrence = .{ .calendar = .{ .start_at_unix_seconds = 1_793_424_600, .timezone = .@"America/New_York", .frequency = .weekly } };
    try std.testing.expectEqual(@as(?u64, 1_794_033_000), try weekly.firstStrictlyAfter(1_793_424_600));
}

test "calendar handles southern hemisphere half-hour DST changes" {
    const spring: Recurrence = .{ .calendar = .{ .start_at_unix_seconds = 1_790_955_900, .timezone = .@"Australia/Lord_Howe", .frequency = .daily } };
    try std.testing.expectEqual(@as(?u64, 1_791_126_900), try spring.firstStrictlyAfter(1_790_955_900));
    const autumn: Recurrence = .{ .calendar = .{ .start_at_unix_seconds = 1_775_227_500, .timezone = .@"Australia/Lord_Howe", .frequency = .daily } };
    try std.testing.expectEqual(@as(?u64, 1_775_313_900), try autumn.firstStrictlyAfter(1_775_227_500));
    try std.testing.expectEqual(@as(?u64, 1_775_402_100), try autumn.firstStrictlyAfter(1_775_313_900));
}

test "calendar boundaries and round trips hold across every supported IANA zone" {
    for (std.enums.values(TimeZone)) |zone| {
        for (std.enums.values(CalendarFrequency)) |frequency| {
            for ([_]u64{ 1, 1_793_424_600, 2_530_683_000, calendar.max_timestamp - 86400 }) |start| {
                const recurrence: Recurrence = .{ .calendar = .{ .start_at_unix_seconds = start, .timezone = zone, .frequency = frequency } };
                try std.testing.expectEqual(@as(?u64, start), try recurrence.firstAtOrAfter(start));
                try std.testing.expectEqual(@as(?u64, start), try recurrence.lastAtOrBefore(start));
                if (try recurrence.firstStrictlyAfter(start)) |next| {
                    try std.testing.expect(next > start);
                    try std.testing.expectEqual(@as(?u64, next), try recurrence.lastAtOrBefore(next));
                    try std.testing.expectEqual(@as(?u64, next), try recurrence.firstAtOrAfter(next));
                }
                try std.testing.expectEqual(@as(?u64, null), try recurrence.firstStrictlyAfter(calendar.max_timestamp));
                try std.testing.expect((try recurrence.lastAtOrBefore(std.math.maxInt(u64))).? <= calendar.max_timestamp);
            }
        }
    }
}

test "monthly and yearly calendars skip missing dates and retain the anchor" {
    // January 31st keeps the 31st, skipping February and April.
    const monthly: Recurrence = .{ .calendar = .{ .start_at_unix_seconds = 1769860800, .timezone = .UTC, .frequency = .monthly } };
    try std.testing.expectEqual(@as(?u64, 1774958400), try monthly.firstStrictlyAfter(1769860800));
    try std.testing.expectEqual(@as(?u64, 1780228800), try monthly.firstStrictlyAfter(1774958400));
    try std.testing.expectEqual(@as(?u64, 1774958400), try monthly.lastAtOrBefore(1777636800));
    const yearly: Recurrence = .{ .calendar = .{ .start_at_unix_seconds = 1709208000, .timezone = .UTC, .frequency = .yearly } };
    try std.testing.expectEqual(@as(?u64, 1835438400), try yearly.firstStrictlyAfter(1709208000));
    try std.testing.expectEqual(@as(?u64, 4233729600), try yearly.firstStrictlyAfter(3981355200));
    try std.testing.expectEqual(@as(?u64, 3981355200), try yearly.lastAtOrBefore(4133980800));
}

test "monthly calendar skips a DST gap and resumes at the original local time" {
    // New York, the 8th at 02:30: March 8, 2026 does not exist.
    const rule: Recurrence = .{ .calendar = .{ .start_at_unix_seconds = 1767857400, .timezone = .@"America/New_York", .frequency = .monthly } };
    try std.testing.expectEqual(@as(?u64, 1775629800), try rule.firstStrictlyAfter(1770535800));
    try std.testing.expectEqual(@as(?u64, 1770535800), try rule.lastAtOrBefore(1775001600));
}

test "weekly selections schedule only selected weekdays on both sides of a query" {
    const rule = try (Recurrence{ .calendar = .{ .start_at_unix_seconds = 1793606400, .timezone = .UTC, .frequency = .weekly } }).calendar.withDays(&.{ 2, 4 });
    const recurrence: Recurrence = .{ .calendar = rule };
    try std.testing.expectEqual(@as(?u64, 1793692800), try recurrence.firstAtOrAfter(1793606400));
    try std.testing.expectEqual(@as(?u64, 1793865600), try recurrence.firstStrictlyAfter(1793692800));
    try std.testing.expectEqual(@as(?u64, 1793692800), try recurrence.lastAtOrBefore(1793833200));
    try std.testing.expectEqual(@as(?u64, null), try recurrence.lastAtOrBefore(1793606400));
    try std.testing.expectEqual(@as(?u64, 1794297600), try recurrence.firstStrictlyAfter(1793865600));
}

test "monthly selections cross months and skip absent dates" {
    const rule = try (Recurrence{ .calendar = .{ .start_at_unix_seconds = 1769760000, .timezone = .UTC, .frequency = .monthly } }).calendar.withDays(&.{ 1, 15, 31 });
    const recurrence: Recurrence = .{ .calendar = rule };
    try std.testing.expectEqual(@as(?u64, 1769846400), try recurrence.firstAtOrAfter(1769760000));
    try std.testing.expectEqual(@as(?u64, 1769932800), try recurrence.firstStrictlyAfter(1769846400));
    try std.testing.expectEqual(@as(?u64, 1771142400), try recurrence.firstStrictlyAfter(1769932800));
    try std.testing.expectEqual(@as(?u64, 1772352000), try recurrence.firstStrictlyAfter(1771142400));
    try std.testing.expectEqual(@as(?u64, 1771142400), try recurrence.lastAtOrBefore(1772352000 - 1));
    try std.testing.expectEqual(@as(?u64, null), try recurrence.lastAtOrBefore(1769760000));
}

test "calendar selections reject empty duplicate unordered or invalid days" {
    const weekly: Recurrence = .{ .calendar = .{ .start_at_unix_seconds = 1000, .timezone = .UTC, .frequency = .weekly } };
    for ([_][]const u8{ &.{}, &.{0}, &.{8}, &.{ 1, 1 }, &.{ 2, 1 } }) |days| try std.testing.expectError(error.InvalidSchedule, weekly.calendar.withDays(days));
    const monthly: Recurrence = .{ .calendar = .{ .start_at_unix_seconds = 1000, .timezone = .UTC, .frequency = .monthly } };
    try std.testing.expectError(error.InvalidSchedule, monthly.calendar.withDays(&.{32}));
    const daily: Recurrence = .{ .calendar = .{ .start_at_unix_seconds = 1000, .timezone = .UTC, .frequency = .daily } };
    try std.testing.expectError(error.InvalidSchedule, daily.calendar.withDays(&.{1}));
}
