const std = @import("std");

/// Product Task runtime-only state of the destructive deletion use case.
/// Archive remains the only durable Task fact; Agent Session lifecycle is a
/// separate participant and never becomes a Task product state.
pub const State = enum(u8) {
    idle,
    deleting,
    failed,
};

pub const Session = enum(u8) {
    detached,
    attached,
    closing,
    retryable_close_failure,
};

/// Read-only owner facts consumed by deletion policy. Each fact remains owned
/// by its original subsystem; this type grants no capability to mutate it.
pub const Facts = struct {
    checkpoint_pending: bool,
    close_operation_running: bool,
    unfinalized_terminal_events: bool,
    session: Session,
    worker_references: usize,
};

pub const Decision = enum(u8) {
    wait,
    cancel_checkpoint,
    release_session,
    commit_record_deletion,
};

/// Returns the single next effect for a Task deletion. The priority order is
/// the invariant: checkpoint ownership settles before Session release; event
/// publication settles before attachment teardown is observed; durable record
/// deletion happens only after every live reference is gone.
pub fn decide(state: State, facts: Facts) Decision {
    if (state != .deleting) return .wait;
    if (facts.checkpoint_pending) return .cancel_checkpoint;
    if (facts.close_operation_running or facts.unfinalized_terminal_events)
        return .wait;
    switch (facts.session) {
        .attached, .retryable_close_failure => return .release_session,
        .closing => return .wait,
        .detached => {},
    }
    if (facts.worker_references != 0) return .wait;
    return .commit_record_deletion;
}

test "Task deletion policy advances resources in owner order" {
    const base: Facts = .{
        .checkpoint_pending = false,
        .close_operation_running = false,
        .unfinalized_terminal_events = false,
        .session = .detached,
        .worker_references = 0,
    };
    try std.testing.expectEqual(Decision.wait, decide(.idle, base));
    try std.testing.expectEqual(Decision.wait, decide(.failed, base));
    try std.testing.expectEqual(Decision.commit_record_deletion, decide(.deleting, base));

    var facts = base;
    facts.worker_references = 1;
    try std.testing.expectEqual(Decision.wait, decide(.deleting, facts));
    facts.session = .attached;
    try std.testing.expectEqual(Decision.release_session, decide(.deleting, facts));
    facts.checkpoint_pending = true;
    try std.testing.expectEqual(Decision.cancel_checkpoint, decide(.deleting, facts));
}

test "Task deletion policy makes failed Session release explicitly retryable" {
    const facts: Facts = .{
        .checkpoint_pending = false,
        .close_operation_running = false,
        .unfinalized_terminal_events = false,
        .session = .retryable_close_failure,
        .worker_references = 0,
    };
    try std.testing.expectEqual(Decision.wait, decide(.failed, facts));
    try std.testing.expectEqual(Decision.release_session, decide(.deleting, facts));
}
