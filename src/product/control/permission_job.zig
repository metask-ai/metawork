//! One independently owned, bounded-lifetime review. No Task/Run references.
const std = @import("std");
const thread_stack = @import("metawork_thread_stack");
const agent = @import("metawork_agent");
const task = @import("metawork_product_task");
const reviewer = @import("product_permission_review");

pub const capacity = 8;
pub const timeout_ms = reviewer.timeout_ms;

pub const Job = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    prepared: task.PreparedPermissionReview,
    arguments: []u8,
    owner: *agent.Completion,
    cancellation: agent.CompletionCancellation,
    deadline: std.Io.Clock.Timestamp,
    notify_context: ?*anyopaque,
    notify_fn: *const fn (?*anyopaque) bool,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    outcome: reviewer.Outcome = .{ .failure = .cancelled },

    pub fn start(self: *Job) !void {
        self.thread = try std.Thread.spawn(thread_stack.config, execute, .{self});
    }

    fn execute(self: *Job) void {
        self.outcome = reviewer.review(self.allocator, self.io, self.owner, self.prepared.input, &self.cancellation, self.deadline);
        self.done.store(true, .release);
        _ = self.notify_fn(self.notify_context);
    }

    pub fn cancel(self: *Job) void {
        self.cancellation.request();
    }

    /// The owner joins even after observing done; notifier and transport are
    /// still borrowed until the actual thread has returned.
    pub fn deinit(self: *Job) void {
        self.cancel();
        if (self.thread) |thread| thread.join();
        self.owner.deinit();
        self.prepared.deinit();
        std.crypto.secureZero(u8, self.arguments);
        self.allocator.free(self.arguments);
        std.crypto.secureZero(u8, std.mem.asBytes(&self.outcome));
        const allocator = self.allocator;
        allocator.destroy(self);
    }
};
