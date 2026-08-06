//! Synchronous Native Bridge callback ingress and quiescence gate.

const std = @import("std");

pub const Error = error{ BridgeStopping, BridgeCallbackCapacity };

pub const State = struct {
    ingress_open: bool = true,
    active: usize = 0,

    pub const Lease = struct {
        state: *State,

        pub fn deinit(self: *Lease) void {
            std.debug.assert(self.state.active != 0);
            self.state.active -= 1;
            self.* = undefined;
        }
    };

    pub fn enter(self: *State) Error!Lease {
        if (!self.ingress_open) return error.BridgeStopping;
        self.active = std.math.add(usize, self.active, 1) catch
            return error.BridgeCallbackCapacity;
        return .{ .state = self };
    }

    pub fn stopIngress(self: *State) void {
        self.ingress_open = false;
    }

    pub fn startIngress(self: *State) void {
        std.debug.assert(!self.ingress_open);
        std.debug.assert(self.active == 0);
        self.ingress_open = true;
    }

    pub fn assertQuiescent(self: *const State) void {
        // Native SDK dispatches synchronous handlers and app.stop on the same
        // platform loop. If that contract changes, this must become a real
        // wait primitive rather than silently weakening the lifetime rule.
        std.debug.assert(!self.ingress_open);
        std.debug.assert(self.active == 0);
    }
};

test "callback gate rejects ingress after quiescence begins" {
    var state = State{};
    var lease = try state.enter();
    lease.deinit();
    state.stopIngress();
    state.assertQuiescent();
    try std.testing.expectError(error.BridgeStopping, state.enter());
}

test "callback gate opens only from a quiescent startup boundary" {
    var state = State{};
    state.stopIngress();
    state.startIngress();
    var lease = try state.enter();
    lease.deinit();
}
