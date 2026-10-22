//! Product Control's single optional Office component. Filesystem, download,
//! signature verification and processes remain Application effects.
const std = @import("std");

pub const Release = struct {
    identity: [32]u8,
    download_bytes: u64,
    installed_bytes: u64,
};
pub const Health = enum { unavailable, ready, read_failed, corrupt, outcome_unknown, restart_required };
pub const InstalledState = enum { ready, damaged, incompatible, unverified };
pub const Current = struct { identity: [32]u8, state: InstalledState };
pub const Kind = enum { check, install, repair, remove, cleanup };
pub const Phase = enum { preparing, downloading, unpacking, verifying, testing, publishing, finalizing, activating, cleaning };
pub const Reason = enum {
    unsupported_platform,
    unavailable,
    unpublished,
    stale_generation,
    busy,
    recovery_required,
    not_installed,
    already_installed,
    not_needed,
    nothing_to_clean,
    too_late,
    shutting_down,
    revision_exhausted,
    download_failed,
    invalid_component,
    insufficient_space,
    resource_limit,
    process_cleanup_incomplete,
    write_failed,
    outcome_unknown,
    cleanup_failed,
};
pub const Outcome = enum { succeeded, cancelled, failed };
pub const Terminal = struct { id: u64, kind: Kind, outcome: Outcome, reason: ?Reason = null };
pub const Operation = struct {
    id: u64,
    kind: Kind,
    phase: Phase = .preparing,
    bytes: u64 = 0,
    total: u64 = 0,
    cancelling: bool = false,
};
pub const Progress = struct { phase: Phase, bytes: u64 = 0, total: u64 = 0 };

/// The only worker-visible product decision. Its stable address is borrowed
/// until Application joins that operation. No worker calls Product Runtime.
pub const Attempt = struct {
    id: u64 = 0,
    gate: std.atomic.Value(enum(u8) { working, cancelled, activating }) = .init(.working),

    pub fn cancelRequested(self: *const Attempt) bool {
        return self.gate.load(.acquire) == .cancelled;
    }

    pub fn beginActivation(self: *Attempt) bool {
        return self.gate.cmpxchgStrong(.working, .activating, .acq_rel, .acquire) == null;
    }

    fn cancel(self: *Attempt) bool {
        return self.gate.cmpxchgStrong(.working, .cancelled, .acq_rel, .acquire) == null;
    }
};

pub const Admission = struct { accepted: bool = false, changed: bool = false, operation_id: ?u64 = null, reason: ?Reason = null };
pub const Actions = struct { install: bool, repair: bool, remove: bool, retry: bool, cleanup: bool, cancel: bool };
pub const View = struct {
    generation: u64,
    supported: bool,
    health: Health,
    offered: ?Release,
    current: ?Current,
    update_available: bool,
    operation: ?Operation,
    terminal: ?Terminal,
    cleanup_pending: bool,
    actions: Actions,
};
pub const Completion = struct {
    current: ?Current,
    health: Health,
    cleanup_pending: bool,
    outcome: Outcome,
    reason: ?Reason = null,
    /// A committed filesystem fact survives a later cancellation. Application
    /// must first install the matching verified Skill source on the owner thread.
    committed: bool = false,
};

pub const Configuration = struct {
    supported: bool = false,
    available: bool = false,
    offered: ?Release = null,
};

pub const State = struct {
    supported: bool = false,
    available: bool = false,
    offered: ?Release = null,
    generation: u64 = 1,
    health: Health = .unavailable,
    current: ?Current = null,
    operation: ?Operation = null,
    attempt: Attempt = .{},
    terminal: ?Terminal = null,
    cleanup_pending: bool = false,
    shutting_down: bool = false,
    next_operation: u64 = 1,
    installation_capacity: bool = true,

    pub fn init(configuration: Configuration) State {
        return .{ .supported = configuration.supported, .available = configuration.available, .offered = if (configuration.supported) configuration.offered else null };
    }

    pub fn view(self: *const State) View {
        const idle = self.available and self.supported and !self.shutting_down and self.operation == null and self.generation != std.math.maxInt(u64);
        const mutable = idle and self.health == .ready;
        const is_current = if (self.current) |installed| if (self.offered) |offered| std.mem.eql(u8, &installed.identity, &offered.identity) else false else false;
        return .{
            .generation = self.generation,
            .supported = self.supported,
            .health = self.health,
            .offered = self.offered,
            .current = self.current,
            .update_available = self.current != null and self.offered != null and !is_current,
            .operation = self.operation,
            .terminal = self.terminal,
            .cleanup_pending = self.cleanup_pending,
            .actions = .{
                .install = mutable and self.installation_capacity and self.offered != null and !is_current,
                .repair = mutable and self.installation_capacity and self.offered != null and self.current != null,
                .remove = mutable and self.current != null,
                .retry = idle and self.health != .ready and self.health != .restart_required,
                .cleanup = mutable and self.cleanup_pending,
                .cancel = if (self.operation) |operation| !self.shutting_down and operation.kind != .check and !operation.cancelling and (operation.kind == .cleanup or @intFromEnum(operation.phase) < @intFromEnum(Phase.activating)) else false,
            },
        };
    }

    pub fn begin(self: *State, kind: Kind, expected_generation: u64) Admission {
        if (self.shutting_down) return .{ .reason = .shutting_down };
        if (expected_generation != self.generation) return .{ .reason = .stale_generation };
        if (!self.supported) return .{ .reason = .unsupported_platform };
        if (!self.available) return .{ .reason = .unavailable };
        if (self.operation != null) return .{ .reason = .busy };
        if (self.generation == std.math.maxInt(u64) or self.next_operation == std.math.maxInt(u64)) return .{ .reason = .revision_exhausted };
        if (self.health == .restart_required) return .{ .reason = .process_cleanup_incomplete };
        if (kind != .check and self.health != .ready) return .{ .reason = .recovery_required };
        switch (kind) {
            .install, .repair => {
                if (!self.installation_capacity) return .{ .reason = .resource_limit };
                const offered = self.offered orelse return .{ .reason = .unpublished };
                if (kind == .repair and self.current == null) return .{ .reason = .not_installed };
                if (kind == .install) if (self.current) |current| {
                    if (std.mem.eql(u8, &current.identity, &offered.identity)) return .{ .reason = .already_installed };
                };
            },
            .remove => if (self.current == null) return .{ .reason = .not_installed },
            .cleanup => if (!self.cleanup_pending) return .{ .reason = .nothing_to_clean },
            .check => if (self.health == .ready) return .{ .reason = .not_needed },
        }
        const id = self.next_operation;
        self.next_operation += 1;
        self.attempt = .{ .id = id };
        self.operation = .{ .id = id, .kind = kind };
        self.terminal = null;
        self.bump();
        return .{ .accepted = true, .changed = true, .operation_id = id };
    }

    pub fn cancel(self: *State, expected_generation: u64, id: u64) Admission {
        if (self.shutting_down) return .{ .reason = .shutting_down };
        if (expected_generation != self.generation) return .{ .reason = .stale_generation };
        const operation = self.operation orelse return .{ .reason = .too_late };
        if (operation.id != id or !self.view().actions.cancel) return .{ .reason = .too_late };
        if (!self.attempt.cancel()) {
            // Observe the worker's activation decision on the owner thread;
            // projection never reads a concurrently changing atomic directly.
            self.operation.?.phase = .activating;
            self.bump();
            return .{ .reason = .too_late, .changed = true, .operation_id = id };
        }
        self.operation.?.cancelling = true;
        self.bump();
        return .{ .accepted = true, .changed = true, .operation_id = id };
    }

    pub fn progress(self: *State, id: u64, update: Progress) bool {
        const operation = if (self.operation) |*operation| operation else return false;
        if (operation.id != id or update.bytes > update.total or @intFromEnum(update.phase) < @intFromEnum(operation.phase)) return false;
        if (operation.phase == update.phase and (update.bytes < operation.bytes or update.total < operation.total)) return false;
        if (operation.phase == update.phase and operation.bytes == update.bytes and operation.total == update.total) return false;
        operation.phase = update.phase;
        operation.bytes = update.bytes;
        operation.total = update.total;
        self.bump();
        return true;
    }

    /// Only after the matching Application worker has joined and source handoff
    /// is complete. A stale completion never consumes the active attempt.
    pub fn finish(self: *State, id: u64, completion: Completion) bool {
        const operation = self.operation orelse return false;
        if (operation.id != id) return false;
        std.debug.assert(completion.outcome == .failed or completion.reason == null);
        self.current = completion.current;
        self.health = completion.health;
        self.cleanup_pending = completion.cleanup_pending;
        self.terminal = .{
            .id = id,
            .kind = operation.kind,
            .outcome = if (completion.committed) .succeeded else completion.outcome,
            .reason = if (completion.committed) null else completion.reason,
        };
        self.operation = null;
        self.bump();
        return true;
    }

    pub fn setInstallationCapacity(self: *State, available: bool) bool {
        if (self.installation_capacity == available) return false;
        self.installation_capacity = available;
        self.bump();
        return true;
    }

    pub fn setCleanupPending(self: *State, pending: bool) bool {
        if (self.cleanup_pending == pending) return false;
        self.cleanup_pending = pending;
        self.bump();
        return true;
    }

    pub fn beginShutdown(self: *State) void {
        if (self.shutting_down) return;
        self.shutting_down = true;
        if (self.operation != null) _ = self.attempt.cancel();
        self.bump();
    }

    fn bump(self: *State) void {
        self.generation +|= 1;
    }
};

fn fixtureState() State {
    return .{ .supported = true, .available = true, .health = .ready, .offered = .{ .identity = @splat(1), .download_bytes = 100, .installed_bytes = 300 } };
}

test "Office admission distinguishes basic skills from available optional environment" {
    var unsupported: State = .{};
    try std.testing.expectEqual(Reason.unsupported_platform, unsupported.begin(.install, 1).reason.?);
    var unpublished = fixtureState();
    unpublished.offered = null;
    try std.testing.expect(!unpublished.view().actions.install);
    try std.testing.expectEqual(Reason.unpublished, unpublished.begin(.install, 1).reason.?);
    var state = fixtureState();
    const initial = state.generation;
    try std.testing.expect(state.view().actions.install);
    const started = state.begin(.install, initial);
    try std.testing.expect(started.accepted);
    try std.testing.expect(state.current == null);
    try std.testing.expectEqual(Reason.stale_generation, state.begin(.install, initial).reason.?);
    try std.testing.expectEqual(Reason.busy, state.begin(.repair, state.generation).reason.?);
    try std.testing.expect(!state.view().actions.install);
}

test "failed Office update preserves independently verified current and permits an explicit retry" {
    var state = fixtureState();
    const previous: Current = .{ .identity = @splat(2), .state = .ready };
    state.current = previous;
    try std.testing.expect(state.view().update_available);
    const id = state.begin(.install, state.generation).operation_id.?;
    try std.testing.expect(state.finish(id, .{ .current = previous, .health = .ready, .cleanup_pending = false, .outcome = .failed, .reason = .download_failed }));
    try std.testing.expectEqual(previous, state.current.?);
    try std.testing.expectEqual(Outcome.failed, state.terminal.?.outcome);
    try std.testing.expect(state.view().actions.install);
    const retry = state.begin(.install, state.generation);
    try std.testing.expect(retry.accepted and retry.operation_id.? != id);
    try std.testing.expect(!state.finish(id, .{ .current = null, .health = .unavailable, .cleanup_pending = false, .outcome = .succeeded }));
    try std.testing.expectEqual(previous, state.current.?);
}

test "Office cancellation and activation have one winner and committed receipt wins late cancellation" {
    var cancelled = fixtureState();
    const first = cancelled.begin(.install, cancelled.generation).operation_id.?;
    try std.testing.expect(cancelled.cancel(cancelled.generation, first).accepted);
    try std.testing.expect(cancelled.attempt.cancelRequested());
    try std.testing.expect(!cancelled.attempt.beginActivation());
    try std.testing.expect(cancelled.finish(first, .{ .current = null, .health = .ready, .cleanup_pending = false, .outcome = .cancelled }));
    try std.testing.expectEqual(Outcome.cancelled, cancelled.terminal.?.outcome);
    var committed = fixtureState();
    const second = committed.begin(.install, committed.generation).operation_id.?;
    try std.testing.expect(committed.attempt.beginActivation());
    const refused = committed.cancel(committed.generation, second);
    try std.testing.expect(!refused.accepted and refused.changed);
    try std.testing.expectEqual(Reason.too_late, refused.reason.?);
    try std.testing.expect(!committed.view().actions.cancel);
    try std.testing.expect(committed.finish(second, .{ .current = .{ .identity = @splat(1), .state = .ready }, .health = .ready, .cleanup_pending = true, .outcome = .cancelled, .committed = true }));
    try std.testing.expectEqual(Outcome.succeeded, committed.terminal.?.outcome);
    try std.testing.expect(committed.view().actions.cleanup);
    try std.testing.expect(!committed.view().actions.install);
    try std.testing.expect(committed.view().actions.repair);
}

test "Office progress rejects stale or regressing samples without changing canonical generation" {
    var state = fixtureState();
    const id = state.begin(.install, state.generation).operation_id.?;
    try std.testing.expect(state.progress(id, .{ .phase = .downloading, .bytes = 10, .total = 100 }));
    const generation = state.generation;
    try std.testing.expect(!state.progress(id + 1, .{ .phase = .activating }));
    try std.testing.expect(!state.progress(id, .{ .phase = .downloading, .bytes = 9, .total = 100 }));
    try std.testing.expect(!state.progress(id, .{ .phase = .downloading, .bytes = 101, .total = 100 }));
    try std.testing.expect(!state.progress(id, .{ .phase = .preparing }));
    try std.testing.expectEqual(generation, state.generation);
    try std.testing.expect(state.progress(id, .{ .phase = .unpacking, .bytes = 1, .total = 300 }));
    try std.testing.expectEqual(@as(u64, 1), state.operation.?.bytes);
}

test "unknown Office persistence freezes mutation but never fabricates loss of the usable current" {
    var state = fixtureState();
    const previous: Current = .{ .identity = @splat(2), .state = .ready };
    state.current = previous;
    const id = state.begin(.install, state.generation).operation_id.?;
    try std.testing.expect(state.finish(id, .{ .current = previous, .health = .outcome_unknown, .cleanup_pending = true, .outcome = .failed, .reason = .outcome_unknown }));
    const actions = state.view().actions;
    try std.testing.expect(actions.retry and !actions.install and !actions.repair and !actions.remove and !actions.cleanup);
    try std.testing.expectEqual(previous, state.current.?);
    const check = state.begin(.check, state.generation);
    try std.testing.expect(check.accepted);
    state.beginShutdown();
    try std.testing.expect(state.attempt.cancelRequested());
    try std.testing.expectEqual(Reason.shutting_down, state.begin(.install, state.generation).reason.?);
    try std.testing.expect(!state.view().actions.retry);
}

test "unproven process quiescence requires restart and cannot be retried as ordinary recovery" {
    var state = fixtureState();
    state.health = .restart_required;
    state.current = .{ .identity = @splat(2), .state = .ready };
    state.cleanup_pending = true;
    const actions = state.view().actions;
    try std.testing.expect(!actions.install and !actions.repair and !actions.remove and !actions.retry and !actions.cleanup);
    try std.testing.expectEqual(Reason.process_cleanup_incomplete, state.begin(.check, state.generation).reason.?);
    try std.testing.expectEqual(InstalledState.ready, state.current.?.state);
}

test "component reference capacity blocks installation without blocking release of retired resources" {
    var state = fixtureState();
    state.current = .{ .identity = @splat(2), .state = .ready };
    state.cleanup_pending = true;
    try std.testing.expect(state.setInstallationCapacity(false));
    try std.testing.expect(!state.view().actions.install and !state.view().actions.repair);
    try std.testing.expect(state.view().actions.cleanup and state.view().actions.remove);
    try std.testing.expectEqual(Reason.resource_limit, state.begin(.install, state.generation).reason.?);
    try std.testing.expect(state.begin(.cleanup, state.generation).accepted);
    const id = state.operation.?.id;
    try std.testing.expect(state.progress(id, .{ .phase = .cleaning }));
    try std.testing.expect(state.view().actions.cancel);
    try std.testing.expect(state.cancel(state.generation, id).accepted);
}
