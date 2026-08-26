//! Product MCP catalog-refresh worker payload and callback lifecycle.
//! The worker owns its immutable inputs and outcome; it never retains a
//! Workbench, Product MCP Runtime, or mutable aggregate pointer.

const std = @import("std");
const agent = @import("metawork_agent");
const ports = @import("product_mcp_ports");

pub const State = enum(u8) {
    queued,
    running,
    completed,
    cancelled,
};

pub const Outcome = union(enum) {
    empty,
    activated: struct {
        activation: *agent.McpActivation,
        selection: ?*agent.McpSelection,
    },
    unavailable,
};

pub const Job = struct {
    allocator: std.mem.Allocator,
    catalog: ports.Catalog,
    notifier: ports.Notifier,
    request_generation: u64,
    requested_at_ms: ?u64,
    arena: std.heap.ArenaAllocator,
    allowlists: []const agent.McpServerAllowlist,
    build_admission: bool,
    state: std.atomic.Value(State) = .init(.queued),
    outcome: Outcome = .unavailable,

    pub fn executorJob(self: *Job) ports.Job {
        return .{
            .identity = self,
            .context = self,
            .execute_fn = execute,
            .cancel_fn = cancel,
        };
    }

    pub fn deinit(self: *Job) void {
        switch (self.outcome) {
            .activated => |activated| {
                if (activated.selection) |selection| selection.deinit();
                activated.activation.deinit();
            },
            .empty, .unavailable => {},
        }
        self.arena.deinit();
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }

    pub fn execute(context: *anyopaque) void {
        const self: *Job = @ptrCast(@alignCast(context));
        const claimed = self.state.cmpxchgStrong(
            .queued,
            .running,
            .acq_rel,
            .acquire,
        );
        std.debug.assert(claimed == null);
        self.outcome = if (self.catalog.activate()) |outcome|
            switch (outcome) {
                .empty => .empty,
                .activated => |activation| activated: {
                    if (activation.takeSelection()) |startup_selection|
                        startup_selection.deinit();
                    const selection = if (self.build_admission)
                        self.catalog.createAdmissionSelection(
                            activation,
                            self.allowlists,
                        ) catch {
                            activation.deinit();
                            break :activated .unavailable;
                        }
                    else
                        null;
                    break :activated .{ .activated = .{
                        .activation = activation,
                        .selection = selection,
                    } };
                },
                .unavailable => .unavailable,
            }
        else |_|
            .unavailable;
        self.state.store(.completed, .release);
        _ = self.notifier.notify();
    }

    pub fn cancel(context: *anyopaque) void {
        const self: *Job = @ptrCast(@alignCast(context));
        const prior = self.state.cmpxchgStrong(
            .queued,
            .cancelled,
            .acq_rel,
            .acquire,
        );
        std.debug.assert(prior == null);
        _ = self.notifier.notify();
    }
};

const TestHarness = struct {
    notifications: usize = 0,

    fn activate(_: *anyopaque) anyerror!agent.McpActivationOutcome {
        return .empty;
    }

    fn createAdmissionSelection(
        _: *anyopaque,
        _: *const agent.McpActivation,
        _: []const agent.McpServerAllowlist,
    ) anyerror!?*agent.McpSelection {
        return null;
    }

    fn notify(context: ?*anyopaque) bool {
        const self: *TestHarness = @ptrCast(@alignCast(context.?));
        self.notifications += 1;
        return true;
    }

    fn job(self: *TestHarness) !*Job {
        const allocator = std.testing.allocator;
        const value = try allocator.create(Job);
        value.* = .{
            .allocator = allocator,
            .catalog = .{
                .context = self,
                .activate_fn = activate,
                .create_admission_selection_fn = createAdmissionSelection,
            },
            .notifier = .{ .context = self, .notify_fn = notify },
            .request_generation = 1,
            .requested_at_ms = null,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .allowlists = &.{},
            .build_admission = false,
        };
        return value;
    }
};

test "Product MCP refresh job completes an empty catalog without aggregate access" {
    var harness = TestHarness{};
    const job = try harness.job();
    defer job.deinit();

    job.executorJob().execute_fn(job);

    try std.testing.expectEqual(State.completed, job.state.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), harness.notifications);
    try std.testing.expect(job.outcome == .empty);
}

test "Product MCP refresh job cancellation transfers queued ownership once" {
    var harness = TestHarness{};
    const job = try harness.job();
    defer job.deinit();

    job.executorJob().cancel_fn(job);

    try std.testing.expectEqual(State.cancelled, job.state.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), harness.notifications);
}
