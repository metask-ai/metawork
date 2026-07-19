//! Coalesced Workbench revision delivery state.

const std = @import("std");

pub const retry_timer_id: u64 = 0x4d57_5245_5652_5952;
pub const retry_interval_ns: u64 = 50 * std.time.ns_per_ms;
pub const retry_deadline_ns: u64 = 2 * std.time.ns_per_s;
pub const max_retry_attempts: u8 = 3;
pub const event_name = "metawork:workbench-changed";

pub const FailureDecision = enum { retry, exhausted };

pub const State = struct {
    last_emitted: u64 = 0,
    pending: bool = false,
    retry_attempts: u8 = 0,
    first_failure_ns: ?u64 = null,
    timer_armed: bool = false,

    pub fn needsDelivery(self: State, revision: u64) bool {
        return self.pending or revision != self.last_emitted;
    }

    pub fn fail(self: *State, now_ns: u64) FailureDecision {
        self.pending = true;
        if (self.first_failure_ns == null) self.first_failure_ns = now_ns;
        self.retry_attempts +|= 1;
        const elapsed = now_ns -| self.first_failure_ns.?;
        return if (self.retry_attempts >= max_retry_attempts or elapsed >= retry_deadline_ns)
            .exhausted
        else
            .retry;
    }

    pub fn timerScheduled(self: *State) void {
        self.timer_armed = true;
    }

    pub fn timerFired(self: *State) void {
        self.timer_armed = false;
    }

    pub fn commit(self: *State, revision: u64) void {
        self.last_emitted = revision;
        self.resetRetry();
    }

    pub fn resetConnection(self: *State) void {
        self.last_emitted = 0;
        self.resetRetry();
    }

    fn resetRetry(self: *State) void {
        self.pending = false;
        self.retry_attempts = 0;
        self.first_failure_ns = null;
        self.timer_armed = false;
    }
};

test "revision state coalesces failures until the newest revision commits" {
    var state = State{};
    try std.testing.expect(!state.needsDelivery(0));
    try std.testing.expectEqual(FailureDecision.retry, state.fail(10));
    try std.testing.expect(state.needsDelivery(0));
    state.timerScheduled();
    try std.testing.expect(state.timer_armed);
    state.timerFired();
    state.commit(9);
    try std.testing.expect(!state.pending);
    try std.testing.expectEqual(@as(u8, 0), state.retry_attempts);
    try std.testing.expect(!state.needsDelivery(9));
    try std.testing.expect(state.needsDelivery(10));
}

test "revision retry is bounded by attempts and deadline" {
    var attempts = State{};
    try std.testing.expectEqual(FailureDecision.retry, attempts.fail(1));
    try std.testing.expectEqual(FailureDecision.retry, attempts.fail(2));
    try std.testing.expectEqual(FailureDecision.exhausted, attempts.fail(3));

    var deadline = State{};
    try std.testing.expectEqual(FailureDecision.retry, deadline.fail(5));
    try std.testing.expectEqual(
        FailureDecision.exhausted,
        deadline.fail(5 + retry_deadline_ns),
    );
}
