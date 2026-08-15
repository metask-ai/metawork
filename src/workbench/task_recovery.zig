//! Pure continuation and recovery eligibility policy.
//!
//! Callers must provide already-observed in-memory facts. This module owns no
//! store, Agent, Task, or Workspace resource and cannot perform I/O.

const std = @import("std");

pub const Attachment = enum {
    detached,
    attached_available,
    attached_session_poisoned,
    closing,
};

pub const Operation = enum {
    none,
    run,
    compact,
    restore,
};

pub const UnavailableReason = enum {
    session_poisoned,
    closing,
    closed,
    task_archived,
    session_recovery_required,
    session_recovery_in_progress,
    session_recovery_failed,
    persistence_unavailable,
    checkpoint_unavailable,
    execution_mismatch,
    workspace_unavailable,
    authority_unavailable,
    runtime_unavailable,
};

pub const Capability = union(enum) {
    available,
    unavailable: UnavailableReason,
};

pub const Projection = struct {
    continuation: Capability,
    recovery_available: bool = false,
};

pub const Facts = struct {
    closed: bool = false,
    archived: bool = false,
    attachment: Attachment = .detached,
    operation: Operation = .none,
    task_persistence_ready: bool = false,
    checkpoint_store_ready: bool = false,
    checkpoint_available: bool = false,
    checkpoint_binding_valid: bool = false,
    checkpoint_history_current: bool = false,
    execution_exact: bool = false,
    workspace_authorized: bool = false,
    runtime_admission_available: bool = false,
    authority_stable: bool = false,
    recovery_failed: bool = false,
};

pub fn project(facts: Facts) Projection {
    if (facts.closed) return unavailable(.closed);
    return switch (facts.attachment) {
        .closing => unavailable(.closing),
        .attached_available => .{ .continuation = .available },
        .attached_session_poisoned => unavailable(.session_poisoned),
        .detached => projectDetached(facts),
    };
}

fn projectDetached(facts: Facts) Projection {
    if (facts.operation == .restore)
        return unavailable(.session_recovery_in_progress);
    if (facts.operation != .none)
        return unavailable(.authority_unavailable);
    if (facts.archived) return unavailable(.task_archived);
    if (!facts.task_persistence_ready) return unavailable(.persistence_unavailable);
    if (!facts.checkpoint_store_ready) return unavailable(.checkpoint_unavailable);
    if (!facts.checkpoint_available or
        !facts.checkpoint_binding_valid or
        !facts.checkpoint_history_current)
        return unavailable(.checkpoint_unavailable);
    if (!facts.execution_exact) return unavailable(.execution_mismatch);
    if (!facts.workspace_authorized) return unavailable(.workspace_unavailable);
    if (!facts.runtime_admission_available) return unavailable(.runtime_unavailable);
    if (!facts.authority_stable) return unavailable(.authority_unavailable);
    return .{
        .continuation = .{ .unavailable = if (facts.recovery_failed)
            .session_recovery_failed
        else
            .session_recovery_required },
        .recovery_available = true,
    };
}

fn unavailable(reason: UnavailableReason) Projection {
    return .{ .continuation = .{ .unavailable = reason } };
}

fn eligibleFacts() Facts {
    return .{
        .task_persistence_ready = true,
        .checkpoint_store_ready = true,
        .checkpoint_available = true,
        .checkpoint_binding_valid = true,
        .checkpoint_history_current = true,
        .execution_exact = true,
        .workspace_authorized = true,
        .runtime_admission_available = true,
        .authority_stable = true,
    };
}

test "eligible detached task exposes recovery through continuation truth" {
    const result = project(eligibleFacts());
    try std.testing.expect(result.recovery_available);
    try std.testing.expectEqual(
        UnavailableReason.session_recovery_required,
        result.continuation.unavailable,
    );
}

test "attached and restoring tasks cannot expose a second recovery state" {
    var attached = eligibleFacts();
    attached.attachment = .attached_available;
    const continued = project(attached);
    try std.testing.expect(!continued.recovery_available);
    try std.testing.expect(continued.continuation == .available);

    var restoring = eligibleFacts();
    restoring.operation = .restore;
    const in_progress = project(restoring);
    try std.testing.expect(!in_progress.recovery_available);
    try std.testing.expectEqual(
        UnavailableReason.session_recovery_in_progress,
        in_progress.continuation.unavailable,
    );
}

test "failed recovery remains one retryable continuation state" {
    var facts = eligibleFacts();
    facts.recovery_failed = true;
    const result = project(facts);
    try std.testing.expect(result.recovery_available);
    try std.testing.expectEqual(
        UnavailableReason.session_recovery_failed,
        result.continuation.unavailable,
    );
}

test "recovery eligibility is fail closed for every external prerequisite" {
    const Case = struct {
        field: enum {
            task_persistence,
            checkpoint_store,
            checkpoint,
            binding,
            history,
            execution,
            workspace,
            runtime,
            authority,
        },
        reason: UnavailableReason,
    };
    for ([_]Case{
        .{ .field = .task_persistence, .reason = .persistence_unavailable },
        .{ .field = .checkpoint_store, .reason = .checkpoint_unavailable },
        .{ .field = .checkpoint, .reason = .checkpoint_unavailable },
        .{ .field = .binding, .reason = .checkpoint_unavailable },
        .{ .field = .history, .reason = .checkpoint_unavailable },
        .{ .field = .execution, .reason = .execution_mismatch },
        .{ .field = .workspace, .reason = .workspace_unavailable },
        .{ .field = .runtime, .reason = .runtime_unavailable },
        .{ .field = .authority, .reason = .authority_unavailable },
    }) |case| {
        var facts = eligibleFacts();
        switch (case.field) {
            .task_persistence => facts.task_persistence_ready = false,
            .checkpoint_store => facts.checkpoint_store_ready = false,
            .checkpoint => facts.checkpoint_available = false,
            .binding => facts.checkpoint_binding_valid = false,
            .history => facts.checkpoint_history_current = false,
            .execution => facts.execution_exact = false,
            .workspace => facts.workspace_authorized = false,
            .runtime => facts.runtime_admission_available = false,
            .authority => facts.authority_stable = false,
        }
        const result = project(facts);
        try std.testing.expect(!result.recovery_available);
        try std.testing.expectEqual(case.reason, result.continuation.unavailable);
    }
}
