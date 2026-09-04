//! Linear ownership for every asynchronous Task activity.
//!
//! A Task owns one `WorkerLeaseSet`; only Task Runtime constructs leases.
//! Jobs may transfer a lease, but every live lease has exactly one owner and
//! must be released exactly once before the Task can be destroyed.

const std = @import("std");

pub const AcquireError = error{WorkerLeaseOverflow};

pub const WorkerLeaseSet = struct {
    live: std.atomic.Value(usize) = .init(0),

    pub fn acquire(self: *WorkerLeaseSet) AcquireError!WorkerLease {
        var observed = self.live.load(.acquire);
        while (true) {
            if (observed == std.math.maxInt(usize))
                return error.WorkerLeaseOverflow;
            if (self.live.cmpxchgWeak(
                observed,
                observed + 1,
                .acq_rel,
                .acquire,
            )) |changed| {
                observed = changed;
                continue;
            }
            return .{ .set = self };
        }
    }

    pub fn liveCount(self: *const WorkerLeaseSet) usize {
        return self.live.load(.acquire);
    }

    pub fn hasLive(self: *const WorkerLeaseSet) bool {
        return self.liveCount() != 0;
    }
};

pub const WorkerLease = struct {
    set: ?*WorkerLeaseSet,

    pub fn take(self: *WorkerLease) WorkerLease {
        const set = self.set orelse @panic("WorkerLease taken after release");
        self.set = null;
        return .{ .set = set };
    }

    pub fn isActive(self: *const WorkerLease) bool {
        return self.set != null;
    }

    pub fn deinit(self: *WorkerLease) void {
        const set = self.set orelse @panic("WorkerLease released more than once");
        self.set = null;
        const previous = set.live.fetchSub(1, .acq_rel);
        std.debug.assert(previous != 0);
    }
};

test "WorkerLease acquire and take preserve one linear owner" {
    var set: WorkerLeaseSet = .{};
    var first = try set.acquire();
    var second = try set.acquire();
    try std.testing.expectEqual(@as(usize, 2), set.liveCount());
    try std.testing.expect(set.hasLive());

    var moved = first.take();
    try std.testing.expect(!first.isActive());
    try std.testing.expect(moved.isActive());
    moved.deinit();
    try std.testing.expectEqual(@as(usize, 1), set.liveCount());
    second.deinit();
    try std.testing.expectEqual(@as(usize, 0), set.liveCount());
    try std.testing.expect(!set.hasLive());
}

test "independent checkpoint lease keeps Task live after job and title settle" {
    var set: WorkerLeaseSet = .{};
    var job_and_title = try set.acquire();
    var checkpoint_source = try set.acquire();
    var checkpoint = checkpoint_source.take();

    job_and_title.deinit();
    try std.testing.expect(set.hasLive());
    try std.testing.expectEqual(@as(usize, 1), set.liveCount());
    checkpoint.deinit();
    try std.testing.expect(!set.hasLive());
}

test "queued cancellation releases its sole lease" {
    var set: WorkerLeaseSet = .{};
    var queued = try set.acquire();
    queued.deinit();
    try std.testing.expectEqual(@as(usize, 0), set.liveCount());
}

test "WorkerLease acquire rejects counter overflow without mutation" {
    var set: WorkerLeaseSet = .{};
    set.live.store(std.math.maxInt(usize), .release);
    try std.testing.expectError(error.WorkerLeaseOverflow, set.acquire());
    try std.testing.expectEqual(std.math.maxInt(usize), set.liveCount());
}
