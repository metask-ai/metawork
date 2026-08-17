//! Session-bound control handles.
//!
//! These values are intentionally separate from the pure control values in
//! control.zig.  They retain a Session and participate in the Session
//! quiescence/termination lifecycle.

const std = @import("std");
const root = @import("../session.zig");
const control = @import("control.zig");

const control_closed_bit = @as(usize, 1) << (@bitSizeOf(usize) - 1);
const control_reference_mask = control_closed_bit - 1;

pub const SessionControlBlock = struct {
    session: *root.Session,
    lifetime: std.atomic.Value(usize) = .init(1),
    wait_mutex: std.Io.Mutex = .init,
    wait_condition: std.Io.Condition = .init,

    pub fn tryRetain(self: *SessionControlBlock) bool {
        var current = self.lifetime.load(.acquire);
        while (current & control_closed_bit == 0) {
            const references = current & control_reference_mask;
            if (references == control_reference_mask) return false;
            if (self.lifetime.cmpxchgWeak(
                current,
                current + 1,
                .acq_rel,
                .acquire,
            )) |observed| {
                current = observed;
            } else return true;
        }
        return false;
    }

    fn release(self: *SessionControlBlock) void {
        self.wait_mutex.lockUncancelable(self.session.agent_runtime.io);
        const previous = self.lifetime.fetchSub(1, .acq_rel);
        std.debug.assert(previous & control_reference_mask > 1);
        self.wait_condition.broadcast(self.session.agent_runtime.io);
        self.wait_mutex.unlock(self.session.agent_runtime.io);
    }

    pub fn disableNewLeases(self: *SessionControlBlock) void {
        _ = self.lifetime.fetchOr(control_closed_bit, .acq_rel);
    }

    pub fn waitForLeaseQuiescence(self: *SessionControlBlock) void {
        self.wait_mutex.lockUncancelable(self.session.agent_runtime.io);
        defer self.wait_mutex.unlock(self.session.agent_runtime.io);
        while (self.lifetime.load(.acquire) & control_reference_mask != 1)
            self.wait_condition.waitUncancelable(
                self.session.agent_runtime.io,
                &self.wait_mutex,
            );
    }

    pub fn deinit(self: *SessionControlBlock) void {
        const lifetime = self.lifetime.load(.acquire);
        std.debug.assert(lifetime & control_closed_bit != 0);
        std.debug.assert(lifetime & control_reference_mask == 1);
    }
};

pub const RunControl = struct {
    block: *SessionControlBlock,
    run_id: u64,
    generation: u64,

    pub fn tryAcquireLease(self: RunControl) ?RunControlLease {
        if (!self.block.tryRetain()) return null;
        return .{
            .block = self.block,
            .run_id = self.run_id,
            .generation = self.generation,
        };
    }
};

/// A retained Agent control reference. This is a linear value: callers must
/// not copy it and must call `deinit` exactly once.
pub const RunControlLease = struct {
    block: *SessionControlBlock,
    run_id: u64,
    generation: u64,
    released: bool = false,

    pub fn requestTermination(
        self: *const RunControlLease,
        signal: control.TerminationSignal,
    ) control.TerminationRequestResult {
        std.debug.assert(!self.released);
        return self.block.session.requestControlledTermination(
            self.run_id,
            self.generation,
            signal,
        );
    }

    pub fn deinit(self: *RunControlLease) void {
        std.debug.assert(!self.released);
        self.released = true;
        self.block.release();
    }
};
