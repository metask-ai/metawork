//! Live Product Task aggregate.
//! The Runtime owns Task collection identity, runtime-only failure evidence and
//! process lifecycle facts. Cross-owner admission and shared history commit
//! effects are supplied by composition; they are never retained here.

const std = @import("std");
const task_state = @import("product_task_state");
const task_persistence = @import("product_task_persistence");

pub const DurableCommit = task_persistence.Commit;

pub const DurableMutationState = enum {
    available,
    /// The backing store may or may not contain the candidate. Further Task
    /// mutation is forbidden because neither rollback nor retry is sound.
    outcome_unknown,
};

pub const FailureRecord = struct {
    task_id: u64,
    recent_order: u64,
    reason: []u8,
};

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    tasks: []?task_state.Task,
    failures: std.ArrayList(FailureRecord) = .empty,
    next_task_id: u64 = 1,
    next_recent_order: u64 = 1,
    next_restore_attempt_id: u64 = 1,
    late_terminal_event_count: u64 = 0,
    recovery_poisoned: bool = false,
    agent_runtime_shutdown_complete: bool = false,
    durable_mutation_state: DurableMutationState = .available,

    pub fn init(
        allocator: std.mem.Allocator,
        capacity: usize,
    ) std.mem.Allocator.Error!Runtime {
        std.debug.assert(capacity != 0);
        const tasks = try allocator.alloc(?task_state.Task, capacity);
        @memset(tasks, null);
        return .{ .allocator = allocator, .tasks = tasks };
    }

    /// Composition must first drain/deinitialize every Task record because
    /// bounded projection allocations remain in the shared root budget.
    pub fn deinitStorage(self: *Runtime) void {
        for (self.tasks) |entry| std.debug.assert(entry == null);
        self.allocator.free(self.tasks);
        for (self.failures.items) |failure| self.allocator.free(failure.reason);
        self.failures.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn find(self: *Runtime, task_id: u64) ?*task_state.Task {
        if (task_id == 0) return null;
        for (self.tasks) |*entry| {
            const task = &(entry.* orelse continue);
            if (task.durable.id == task_id) return task;
        }
        return null;
    }

    pub fn findConst(self: *const Runtime, task_id: u64) ?*const task_state.Task {
        if (task_id == 0) return null;
        for (self.tasks) |*entry| {
            const task = &(entry.* orelse continue);
            if (task.durable.id == task_id) return task;
        }
        return null;
    }

    pub fn emptyIndex(self: *const Runtime) ?usize {
        for (self.tasks, 0..) |entry, index| if (entry == null) return index;
        return null;
    }

    pub fn takeRecentOrder(self: *Runtime) u64 {
        const result = self.next_recent_order;
        if (self.next_recent_order != std.math.maxInt(u64))
            self.next_recent_order += 1;
        return result;
    }

    pub fn noteLateTerminal(self: *Runtime) u64 {
        self.late_terminal_event_count +|= 1;
        return self.late_terminal_event_count;
    }

    /// Closes a Product Task durable transaction after composition has made
    /// the one shared Workspace+Task history commit. A definite failure stays
    /// retryable after caller rollback; an unknown outcome permanently freezes
    /// this Runtime's mutation surface.
    pub fn observeDurableCommit(self: *Runtime, outcome: DurableCommit) void {
        switch (outcome) {
            .committed, .failed => {},
            .outcome_unknown => self.durable_mutation_state = .outcome_unknown,
        }
    }

    pub fn durableMutationAvailable(self: *const Runtime) bool {
        return self.durable_mutation_state == .available;
    }
};

test "Runtime owns bounded Task collection and monotonic process facts" {
    var runtime = try Runtime.init(std.testing.allocator, 2);
    defer runtime.deinitStorage();
    try std.testing.expectEqual(@as(?usize, 0), runtime.emptyIndex());
    try std.testing.expectEqual(@as(u64, 1), runtime.takeRecentOrder());
    try std.testing.expectEqual(@as(u64, 2), runtime.next_recent_order);
    try std.testing.expectEqual(@as(u64, 1), runtime.noteLateTerminal());
    runtime.observeDurableCommit(.failed);
    try std.testing.expect(runtime.durableMutationAvailable());
    runtime.observeDurableCommit(.outcome_unknown);
    try std.testing.expect(!runtime.durableMutationAvailable());
}
