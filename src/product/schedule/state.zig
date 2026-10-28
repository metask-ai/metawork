//! Product Schedule-owned bounded state and occurrence transitions.

const std = @import("std");
const models_contract = @import("metawork_product_models_contract");

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

pub const Recurrence = union(enum) {
    once: struct {
        at_unix_seconds: u64,
    },
    interval: struct {
        start_at_unix_seconds: u64,
        every_seconds: u64,
    },

    pub fn validate(self: Recurrence) error{InvalidSchedule}!void {
        switch (self) {
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
                .interval => error.InvalidSchedule,
            };
        return self.firstAtOrAfter(unix_seconds + 1);
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
};

pub const Binding = struct {
    model_ref: models_contract.ModelRef,
    source_generation: u64,
    selection_revision: u64,
    protocol: Protocol,
};

const OwnedBinding = struct {
    source_id: []u8,
    model_id: []u8,
    source_generation: u64,
    selection_revision: u64,
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
    enabled: bool = true,
    health: Health = .ready,
    failure_reason: ?FailureReason = null,
    next_run_at_unix_seconds: ?u64,
    last_occurrence: ?Occurrence = null,
    occurrence_history: [max_occurrence_history]Occurrence = undefined,
    occurrence_count: usize = 0,

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
            .selection_revision = self.binding.selection_revision,
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
            });
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
        const slot = self.emptySlot() orelse return error.ScheduledTaskCapacity;
        var item = try self.cloneDefinition(
            restored.id,
            restored.epoch,
            restored.definition,
            restored.next_run_at_unix_seconds,
        );
        errdefer self.deinitItem(&item);
        item.enabled = restored.enabled;
        item.health = restored.health;
        item.failure_reason = restored.failure_reason;
        for (restored.occurrences, 0..) |occurrence, index| {
            if (!validOccurrence(occurrence))
                return error.InvalidScheduledTaskRestore;
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
        const next_run = (try definition.recurrence.firstAtOrAfter(
            now_unix_seconds,
        )) orelse return error.InvalidSchedule;
        var replacement = try self.cloneDefinition(
            id,
            current.epoch + 1,
            definition,
            next_run,
        );
        errdefer self.deinitItem(&replacement);
        replacement.last_occurrence = current.last_occurrence;
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
        if (item.enabled == enabled and
            ((enabled and item.health == .ready) or
                (!enabled and item.health == .paused)))
            return;
        if (item.epoch == std.math.maxInt(u64))
            return error.ScheduledTaskIdentityExhausted;
        if (enabled) {
            item.next_run_at_unix_seconds =
                (try item.recurrence.firstAtOrAfter(now_unix_seconds)) orelse
                return error.InvalidSchedule;
            item.enabled = true;
            item.health = .ready;
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
            if (item.occurrence_count == 0) continue;
            const occurrence = &item.occurrence_history[item.occurrence_count - 1];
            if (occurrence.result != .claimed) continue;
            occurrence.result = .rejected;
            occurrence.reason = .host_interrupted;
            item.last_occurrence = occurrence.*;
            self.markNeedsAttention(item, .host_interrupted);
            changed = true;
        }
        return changed;
    }

    pub fn finalizeOccurrenceTask(
        self: *Store,
        item: *Item,
        planned_at_unix_seconds: u64,
        source: OccurrenceSource,
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
                planned_at_unix_seconds or occurrence.source != source)
                continue;
            if (occurrence.task_outcome != null or occurrence.notification_sent)
                return error.InvalidSchedule;
            occurrence.task_outcome = outcome;
            occurrence.reason = reason;
            occurrence.notification_sent = true;
            if (item.last_occurrence != null and
                item.last_occurrence.?.planned_at_unix_seconds ==
                    planned_at_unix_seconds and
                item.last_occurrence.?.source == source)
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
            .selection_revision = binding.selection_revision,
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

fn validRestoredState(restored: RestoredItem) bool {
    if (restored.enabled) {
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
        binding.source_generation == 0 or binding.selection_revision == 0)
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
            .selection_revision = 11,
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
            .selection_revision = 11,
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
