//! Pure continuation and recovery admission policy.
//!
//! Callers provide already-observed Product facts. This module owns no store,
//! Agent, Task, Workspace, Skill, MCP, Permission, or projection resource.

const std = @import("std");

pub const Attachment = enum { detached, attached_available, attached_session_poisoned, closing };
pub const Operation = enum { none, run, compact, restore };

pub const UnavailableReason = enum {
    session_poisoned,
    closing,
    task_archived,
    session_recovery_required,
    session_recovery_in_progress,
    session_recovery_failed,
    persistence_unavailable,
    checkpoint_unavailable,
    execution_rebind_required,
    workspace_unavailable,
    authority_unavailable,
    runtime_unavailable,
    history_read_only,
};

pub const Capability = union(enum) { available, unavailable: UnavailableReason };
pub const Projection = struct {
    continuation: Capability,
    recovery_available: bool = false,
};

pub const RuntimeAdmission = enum { available, busy, capacity_reached, unavailable, shutting_down };
pub const ExecutionAdmission = enum { available, unavailable };

/// Stable Product identities that make a historical Conversation belong to
/// the current Task attachment. Optional capability authority is deliberately
/// absent: Skill, MCP and durable permission continuity may only narrow the
/// restored Session after this decision.
pub const CoreRecoveryAuthority = struct {
    /// A detached Task may start a new empty AgentCore Conversation only when
    /// Product history proves that no operation belongs to a prior
    /// checkpointed Conversation. Excluded history still remains visible.
    fresh_conversation_allowed: bool = false,
    checkpoint_available: bool = false,
    checkpoint_binding_exact: bool = false,
    checkpoint_history_exact: bool = false,
    workspace_identity_exact: bool = false,
    automatic_owner_exact: bool = false,
    authority_stable: bool = false,
};

pub const RecoveryAdmissionFacts = struct {
    archived: bool = false,
    attachment: Attachment = .detached,
    operation: Operation = .none,
    task_persistence_ready: bool = false,
    checkpoint_store_ready: bool = false,
    runtime_admission: RuntimeAdmission = .unavailable,
    execution_admission: ExecutionAdmission = .unavailable,
    core: CoreRecoveryAuthority = .{},
    recovery_failed: bool = false,
    history_read_only: bool = false,
};

pub const AdmissionDecision = union(enum) { admitted, denied: UnavailableReason };

pub fn evaluateRecoveryAdmission(facts: RecoveryAdmissionFacts) AdmissionDecision {
    if (facts.history_read_only) return .{ .denied = .history_read_only };
    if (facts.operation == .restore) return .{ .denied = .session_recovery_in_progress };
    if (facts.operation != .none) return .{ .denied = .authority_unavailable };
    if (facts.archived) return .{ .denied = .task_archived };
    if (!facts.task_persistence_ready) return .{ .denied = .persistence_unavailable };
    if (!facts.core.fresh_conversation_allowed) {
        if (!facts.checkpoint_store_ready) return .{ .denied = .checkpoint_unavailable };
        if (!facts.core.checkpoint_available or
            !facts.core.checkpoint_binding_exact or
            !facts.core.checkpoint_history_exact)
            return .{ .denied = .checkpoint_unavailable };
    }
    if (facts.execution_admission != .available)
        return .{ .denied = .execution_rebind_required };
    if (!facts.core.workspace_identity_exact or !facts.core.automatic_owner_exact)
        return .{ .denied = .workspace_unavailable };
    if (facts.runtime_admission != .available)
        return .{ .denied = .runtime_unavailable };
    if (!facts.core.authority_stable) return .{ .denied = .authority_unavailable };
    return .admitted;
}

pub fn project(facts: RecoveryAdmissionFacts) Projection {
    return switch (facts.attachment) {
        .closing => unavailable(.closing),
        .attached_available => .{ .continuation = .available },
        .attached_session_poisoned => unavailable(.session_poisoned),
        .detached => projectDetached(facts),
    };
}

fn projectDetached(facts: RecoveryAdmissionFacts) Projection {
    switch (evaluateRecoveryAdmission(facts)) {
        .denied => |reason| return unavailable(reason),
        .admitted => {},
    }
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

fn eligibleFacts() RecoveryAdmissionFacts {
    return .{
        .task_persistence_ready = true,
        .checkpoint_store_ready = true,
        .runtime_admission = .available,
        .execution_admission = .available,
        .core = .{
            .checkpoint_available = true,
            .checkpoint_binding_exact = true,
            .checkpoint_history_exact = true,
            .workspace_identity_exact = true,
            .automatic_owner_exact = true,
            .authority_stable = true,
        },
    };
}

test "eligible detached task exposes recovery through continuation truth" {
    const result = project(eligibleFacts());
    try std.testing.expect(result.recovery_available);
    try std.testing.expectEqual(UnavailableReason.session_recovery_required, result.continuation.unavailable);
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
    try std.testing.expectEqual(UnavailableReason.session_recovery_in_progress, in_progress.continuation.unavailable);
}

test "failed recovery remains one retryable continuation state" {
    var facts = eligibleFacts();
    facts.recovery_failed = true;
    const result = project(facts);
    try std.testing.expect(result.recovery_available);
    try std.testing.expectEqual(UnavailableReason.session_recovery_failed, result.continuation.unavailable);
}

test "read-only history never offers recovery" {
    var facts = eligibleFacts();
    facts.history_read_only = true;
    const result = project(facts);
    try std.testing.expect(!result.recovery_available);
    try std.testing.expectEqual(UnavailableReason.history_read_only, result.continuation.unavailable);
}

test "fresh Conversation recovery does not require a checkpoint store" {
    var facts = eligibleFacts();
    facts.checkpoint_store_ready = false;
    facts.core.checkpoint_available = false;
    facts.core.checkpoint_binding_exact = false;
    facts.core.checkpoint_history_exact = false;
    facts.core.fresh_conversation_allowed = true;
    const result = project(facts);
    try std.testing.expect(result.recovery_available);
    try std.testing.expectEqual(
        UnavailableReason.session_recovery_required,
        result.continuation.unavailable,
    );
}

test "covered history without a checkpoint remains fail closed" {
    var facts = eligibleFacts();
    facts.core.checkpoint_available = false;
    facts.core.checkpoint_binding_exact = false;
    facts.core.checkpoint_history_exact = false;
    facts.core.fresh_conversation_allowed = false;
    const result = project(facts);
    try std.testing.expect(!result.recovery_available);
    try std.testing.expectEqual(
        UnavailableReason.checkpoint_unavailable,
        result.continuation.unavailable,
    );
}

test "recovery admission is fail closed for every core prerequisite" {
    const Case = struct {
        field: enum {
            task_persistence,
            checkpoint_store,
            checkpoint,
            binding,
            history,
            execution,
            workspace,
            automatic_owner,
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
        .{ .field = .execution, .reason = .execution_rebind_required },
        .{ .field = .workspace, .reason = .workspace_unavailable },
        .{ .field = .automatic_owner, .reason = .workspace_unavailable },
        .{ .field = .runtime, .reason = .runtime_unavailable },
        .{ .field = .authority, .reason = .authority_unavailable },
    }) |case| {
        var facts = eligibleFacts();
        switch (case.field) {
            .task_persistence => facts.task_persistence_ready = false,
            .checkpoint_store => facts.checkpoint_store_ready = false,
            .checkpoint => facts.core.checkpoint_available = false,
            .binding => facts.core.checkpoint_binding_exact = false,
            .history => facts.core.checkpoint_history_exact = false,
            .execution => facts.execution_admission = .unavailable,
            .workspace => facts.core.workspace_identity_exact = false,
            .automatic_owner => facts.core.automatic_owner_exact = false,
            .runtime => facts.runtime_admission = .capacity_reached,
            .authority => facts.core.authority_stable = false,
        }
        const result = project(facts);
        try std.testing.expect(!result.recovery_available);
        try std.testing.expectEqual(case.reason, result.continuation.unavailable);
    }
}
