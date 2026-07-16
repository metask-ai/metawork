//! Coalesced Workbench revision delivery state.

const std = @import("std");

pub const retry_timer_id: u64 = 0x4d57_5245_5652_5952;
pub const retry_interval_ns: u64 = 50 * std.time.ns_per_ms;
pub const event_name = "metawork:workbench-changed";

pub const State = struct {
    last_emitted: u64 = 0,
    pending: bool = false,

    pub fn needsDelivery(self: State, revision: u64) bool {
        return self.pending or revision != self.last_emitted;
    }

    pub fn fail(self: *State) void {
        self.pending = true;
    }

    pub fn commit(self: *State, revision: u64) void {
        self.last_emitted = revision;
        self.pending = false;
    }
};

test "revision state coalesces failures until the newest revision commits" {
    var state = State{};
    try std.testing.expect(!state.needsDelivery(0));
    state.fail();
    try std.testing.expect(state.needsDelivery(0));
    state.commit(9);
    try std.testing.expect(!state.pending);
    try std.testing.expect(!state.needsDelivery(9));
    try std.testing.expect(state.needsDelivery(10));
}
