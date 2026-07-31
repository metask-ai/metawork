const std = @import("std");

pub const minimum_interval_seconds: u64 = 60;

pub const Error = std.mem.Allocator.Error || error{
    ScheduledTaskCapacity,
    ScheduledTaskIdentityExhausted,
    UnknownScheduledTask,
    ScheduledTaskEpochMismatch,
    InvalidSchedule,
    ProjectionCapacity,
};

pub const Provider = enum {
    anthropic,
    openai,
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

pub const Input = union(enum) {
    text: []const u8,
    skill: struct {
        skill_id: []const u8,
        catalog_revision: []const u8,
        argument_values: []const []const u8,
    },
};

pub const OwnedInput = union(enum) {
    text: struct {
        value: []u8,
        redacted: bool = false,
    },
    skill: struct {
        skill_id: []u8,
        catalog_revision: []u8,
        argument_values: [][]u8,
        redacted: bool = false,
    },

    pub fn borrowed(self: *const OwnedInput) Input {
        return switch (self.*) {
            .text => |text| .{ .text = text.value },
            .skill => |skill| .{ .skill = .{
                .skill_id = skill.skill_id,
                .catalog_revision = skill.catalog_revision,
                .argument_values = skill.argument_values,
            } },
        };
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
    workspace_changed,
    workspace_unavailable,
    catalog_changed,
    capacity_reached,
    shutting_down,
    task_start_failed,
    timer_unavailable,
};

pub const OccurrenceSource = enum {
    timer,
    manual,
};

pub const OccurrenceResult = enum {
    submitted,
    skipped,
    rejected,
};

pub const Occurrence = struct {
    planned_at_unix_seconds: u64,
    triggered_at_unix_seconds: u64,
    source: OccurrenceSource,
    result: OccurrenceResult,
    task_id: u64 = 0,
    reason: ?FailureReason = null,
};

pub const Definition = struct {
    title: []const u8,
    workspace_id: u64,
    workspace_epoch: u64,
    execution_generation: u64,
    execution_provider: Provider,
    execution_model: []const u8,
    input: Input,
    recurrence: Recurrence,
};

pub const Item = struct {
    id: u64,
    epoch: u64 = 1,
    title: []u8,
    title_redacted: bool = false,
    workspace_id: u64,
    workspace_epoch: u64,
    execution_generation: u64,
    execution_provider: Provider,
    execution_model: []u8,
    input: OwnedInput,
    recurrence: Recurrence,
    enabled: bool = true,
    health: Health = .ready,
    failure_reason: ?FailureReason = null,
    next_run_at_unix_seconds: ?u64,
    last_occurrence: ?Occurrence = null,
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

    pub fn create(
        self: *Store,
        definition: Definition,
        now_unix_seconds: u64,
    ) Error!u64 {
        const slot = self.emptySlot() orelse return error.ScheduledTaskCapacity;
        if (self.next_id == 0) return error.ScheduledTaskIdentityExhausted;
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
        self.next_id +%= 1;
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
        _: *Store,
        item: *Item,
        planned_at_unix_seconds: u64,
        triggered_at_unix_seconds: u64,
        source: OccurrenceSource,
        task_id: u64,
    ) error{InvalidSchedule}!void {
        std.debug.assert(task_id != 0);
        item.last_occurrence = .{
            .planned_at_unix_seconds = planned_at_unix_seconds,
            .triggered_at_unix_seconds = triggered_at_unix_seconds,
            .source = source,
            .result = .submitted,
            .task_id = task_id,
        };
        if (source == .manual) return;
        try advanceAfterTimer(item, triggered_at_unix_seconds);
    }

    pub fn markSkipped(
        _: *Store,
        item: *Item,
        planned_at_unix_seconds: u64,
        triggered_at_unix_seconds: u64,
    ) error{InvalidSchedule}!void {
        item.last_occurrence = .{
            .planned_at_unix_seconds = planned_at_unix_seconds,
            .triggered_at_unix_seconds = triggered_at_unix_seconds,
            .source = .timer,
            .result = .skipped,
            .reason = .previous_task_running,
        };
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
    ) void {
        item.last_occurrence = .{
            .planned_at_unix_seconds = planned_at_unix_seconds,
            .triggered_at_unix_seconds = triggered_at_unix_seconds,
            .source = source,
            .result = .rejected,
            .reason = reason,
        };
        self.markNeedsAttention(item, reason);
    }

    fn cloneDefinition(
        self: *Store,
        id: u64,
        epoch: u64,
        definition: Definition,
        next_run: u64,
    ) Error!Item {
        var item: Item = undefined;
        const title = try self.copy(definition.title);
        errdefer self.free(title);
        const model = try self.copy(definition.execution_model);
        errdefer self.free(model);
        var input = try self.cloneInput(definition.input);
        errdefer self.deinitInput(&input);
        item = .{
            .id = id,
            .epoch = epoch,
            .title = title,
            .workspace_id = definition.workspace_id,
            .workspace_epoch = definition.workspace_epoch,
            .execution_generation = definition.execution_generation,
            .execution_provider = definition.execution_provider,
            .execution_model = model,
            .input = input,
            .recurrence = definition.recurrence,
            .next_run_at_unix_seconds = next_run,
        };
        return item;
    }

    fn cloneInput(self: *Store, input: Input) Error!OwnedInput {
        return switch (input) {
            .text => |text| .{ .text = .{ .value = try self.copy(text) } },
            .skill => |skill| skill_copy: {
                const skill_id = try self.copy(skill.skill_id);
                errdefer self.free(skill_id);
                const revision = try self.copy(skill.catalog_revision);
                errdefer self.free(revision);
                const values = try self.copyArgumentArray(
                    skill.argument_values,
                );
                break :skill_copy .{ .skill = .{
                    .skill_id = skill_id,
                    .catalog_revision = revision,
                    .argument_values = values,
                } };
            },
        };
    }

    fn copyArgumentArray(
        self: *Store,
        values: []const []const u8,
    ) Error![][]u8 {
        const structure_bytes = std.math.mul(
            usize,
            values.len,
            @sizeOf([]u8),
        ) catch return error.ProjectionCapacity;
        try self.reserve(structure_bytes);
        const copied = try self.allocator.alloc([]u8, values.len);
        self.projection_bytes += structure_bytes;
        errdefer {
            self.projection_bytes -= structure_bytes;
            self.allocator.free(copied);
        }
        var completed: usize = 0;
        errdefer for (copied[0..completed]) |value| self.free(value);
        for (values, copied) |value, *target| {
            target.* = try self.copy(value);
            completed += 1;
        }
        return copied;
    }

    fn deinitItem(self: *Store, item: *Item) void {
        self.free(item.title);
        self.free(item.execution_model);
        self.deinitInput(&item.input);
        item.* = undefined;
    }

    fn deinitInput(self: *Store, input: *OwnedInput) void {
        switch (input.*) {
            .text => |text| self.free(text.value),
            .skill => |skill| {
                for (skill.argument_values) |value| self.free(value);
                self.projection_bytes -=
                    skill.argument_values.len * @sizeOf([]u8);
                self.allocator.free(skill.argument_values);
                self.free(skill.catalog_revision);
                self.free(skill.skill_id);
            },
        }
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
        .workspace_id = 7,
        .workspace_epoch = 3,
        .execution_generation = 9,
        .execution_provider = .openai,
        .execution_model = "gpt-test",
        .input = .{ .text = "Summarize the project" },
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
