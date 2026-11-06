//! Capacity-one, nonblocking Agent ingress. Canonical pending data stays on main.
const std = @import("std");
const agent = @import("metawork_agent");
const ports = @import("product_mcp_ports");

pub const Payload = struct {
    id: u64,
    task_id: u64,
    run_id: u64,
    run_generation: u64,
    draft: agent.McpInstallationDraft,
    pub fn deinit(self: *Payload) void {
        self.draft.deinit();
        self.* = undefined;
    }
};

test "installation mailbox never waits for main and keeps its reservation after take" {
    const Wake = struct {
        fn notify(_: ?*anyopaque) bool {
            return true;
        }
    };
    var mailbox: Mailbox = .{ .allocator = std.testing.allocator, .notifier = .{ .context = null, .notify_fn = Wake.notify } };
    defer mailbox.deinit();
    const input = mailbox.input(std.testing.io);
    const make = struct {
        fn draft() !agent.McpInstallationDraft {
            return .{ .allocator = std.testing.allocator, .json = try std.testing.allocator.dupe(u8, "{}") };
        }
    }.draft;
    var refused = try make();
    defer refused.deinit();
    mailbox.mutex.lockUncancelable(std.testing.io);
    const contended = input.try_put_fn(input.context, 1, 2, 3, refused);
    mailbox.mutex.unlock(std.testing.io);
    try std.testing.expectEqual(.busy, std.meta.activeTag(contended));
    const accepted = input.try_put_fn(input.context, 1, 2, 3, try make());
    const id = accepted.proposal_submitted;
    try std.testing.expectEqual(.busy, std.meta.activeTag(input.try_put_fn(input.context, 4, 5, 6, refused)));
    var taken = mailbox.take(std.testing.io).?;
    defer taken.deinit();
    try std.testing.expectEqual(@as(u64, 1), taken.task_id);
    try std.testing.expectEqual(.busy, std.meta.activeTag(input.try_put_fn(input.context, 4, 5, 6, refused)));
    try std.testing.expect(!mailbox.release(std.testing.io, id + 1));
    try std.testing.expect(mailbox.release(std.testing.io, id));
    const next = input.try_put_fn(input.context, 4, 5, 6, try make()).proposal_submitted;
    try std.testing.expect(next > id);
    try std.testing.expect(!mailbox.release(std.testing.io, id));
    mailbox.close(std.testing.io);
    try std.testing.expect(mailbox.take(std.testing.io) == null);
    try std.testing.expectEqual(.unavailable, std.meta.activeTag(input.try_put_fn(input.context, 1, 2, 3, refused)));
}

test "concurrent installation callbacks transfer exactly one owner" {
    const Worker = struct {
        input: agent.McpInstallationInput,
        accepted: *std.atomic.Value(usize),
        fn run(self: @This()) void {
            var draft: agent.McpInstallationDraft = .{ .allocator = std.testing.allocator, .json = std.testing.allocator.dupe(u8, "{}") catch unreachable };
            const result = self.input.try_put_fn(self.input.context, 1, 2, 3, draft);
            if (result == .proposal_submitted) {
                _ = self.accepted.fetchAdd(1, .acq_rel);
            } else draft.deinit();
        }
        fn wake(_: ?*anyopaque) bool {
            return true;
        }
    };
    var mailbox: Mailbox = .{ .allocator = std.testing.allocator, .notifier = .{ .context = null, .notify_fn = Worker.wake } };
    defer mailbox.deinit();
    var accepted: std.atomic.Value(usize) = .init(0);
    const worker: Worker = .{ .input = mailbox.input(std.testing.io), .accepted = &accepted };
    var threads: [8]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, Worker.run, .{worker});
    for (threads) |thread| thread.join();
    try std.testing.expectEqual(@as(usize, 1), accepted.load(.acquire));
    mailbox.close(std.testing.io);
}

pub const Mailbox = struct {
    allocator: std.mem.Allocator,
    notifier: ports.Notifier,
    io: ?std.Io = null,
    mutex: std.Io.Mutex = .init,
    closed: bool = false,
    next_id: u64 = 0,
    reserved_id: u64 = 0,
    queued: ?Payload = null,

    pub fn input(self: *Mailbox, io: std.Io) agent.McpInstallationInput {
        if (self.io == null) self.io = io;
        return .{ .context = self, .allocator = self.allocator, .try_put_fn = tryPut, .wake_fn = wake };
    }
    fn tryPut(raw: *anyopaque, task_id: u64, run_id: u64, generation: u64, draft: agent.McpInstallationDraft) agent.McpInstallationResult {
        const self: *Mailbox = @ptrCast(@alignCast(raw));
        if (!self.mutex.tryLock()) return .busy;
        defer self.mutex.unlock(self.io.?);
        if (self.closed) return .unavailable;
        if (task_id == 0 or run_id == 0 or generation == 0) return .cancelled;
        if (self.reserved_id != 0) return .busy;
        if (self.next_id == std.math.maxInt(u64)) return .unavailable;
        self.next_id += 1;
        self.reserved_id = self.next_id;
        self.queued = .{ .id = self.next_id, .task_id = task_id, .run_id = run_id, .run_generation = generation, .draft = draft };
        return .{ .proposal_submitted = self.next_id };
    }
    fn wake(raw: *anyopaque) void {
        const self: *Mailbox = @ptrCast(@alignCast(raw));
        _ = self.notifier.notify();
    }
    pub fn take(self: *Mailbox, io: std.Io) ?Payload {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const payload = self.queued;
        self.queued = null;
        // Main-held proposals retain the single reservation.
        return payload;
    }
    pub fn release(self: *Mailbox, io: std.Io, id: u64) bool {
        self.mutex.lockUncancelable(io);
        const matches = id != 0 and self.reserved_id == id;
        const discarded = if (matches) self.queued else null;
        if (matches) {
            self.queued = null;
            self.reserved_id = 0;
        }
        self.mutex.unlock(io);
        if (discarded) |value| {
            var owned = value;
            owned.deinit();
        }
        return matches;
    }
    pub fn close(self: *Mailbox, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        self.closed = true;
        self.reserved_id = 0;
        const discarded = self.queued;
        self.queued = null;
        self.mutex.unlock(io);
        if (discarded) |value| {
            var owned = value;
            owned.deinit();
        }
    }
    /// Caller has joined all Run/callback owners. No concurrent access remains.
    pub fn deinit(self: *Mailbox) void {
        if (self.queued) |*value| value.deinit();
        self.queued = null;
        self.closed = true;
    }
};
