//! Process-only Task resource ownership and legal operation state.

const std = @import("std");
const agent = @import("metawork_agent");
const catalog_snapshot = @import("workbench_catalog_snapshot");
const owned_execution = @import("workbench_owned_task_execution");
const recovery_job = @import("workbench_task_recovery_job");

pub const DetachmentCause = enum {
    cold_start,
    closed,
    session_poisoned,
    event_projection_failure,
};

pub const AttachedHealth = enum {
    available,
    session_poisoned,
    event_projection_failure,
};

pub const LiveAttachment = struct {
    session: *agent.Session,
    execution: owned_execution.OwnedTaskExecution,
    route_id: u64,
    pinned_catalog: ?catalog_snapshot.Snapshot,
    health: AttachedHealth = .available,
};

pub const ClosingAttachment = struct {
    live: LiveAttachment,
};

pub const Attachment = union(enum) {
    detached: DetachmentCause,
    attached: LiveAttachment,
    closing: ClosingAttachment,
};

pub const RestoreAttempt = struct {
    id: u64,
};

/// Typed permission accounting returned by AgentCore checkpoint restore.
/// This is runtime health state only: it is never persisted as a permission
/// rule and cannot be used to recreate or replay a prior response.
pub const RestorePermissionSummary = struct {
    restored_rules: u32 = 0,
    invalidated_rules: u32 = 0,
};

pub const ActiveOperation = union(enum) {
    none,
    run: u64,
    compact: u64,
    restore: RestoreAttempt,
};

pub const CloseCompletion = enum(u8) {
    none,
    running,
    closed,
    failed_reusable,
    failed_poisoned,
    failed_closing,
};

pub const State = struct {
    attachment: Attachment = .{ .detached = .cold_start },
    worker_references: std.atomic.Value(usize) = .init(0),
    pending_ui_request_id: u64 = 0,
    pending_ui_order: u64 = 0,
    active_run_id: u64 = 0,
    active_operation: ActiveOperation = .none,
    restore_job: ?*recovery_job.Job = null,
    last_restore_failure: ?recovery_job.Failure = null,
    last_restore_permission: ?RestorePermissionSummary = null,
    close_thread: ?std.Thread = null,
    close_completion: std.atomic.Value(CloseCompletion) = .init(.none),
    close_failed: bool = false,
    cancel_requested: bool = false,
    /// Runtime-only model selection requested while the Session is busy.
    /// It is deliberately not part of task persistence and is dropped on
    /// restart/detach.
    pending_model: ?[]u8 = null,

    pub fn attached(self: *State) ?*LiveAttachment {
        return switch (self.attachment) {
            .attached => |*value| value,
            .detached, .closing => null,
        };
    }

    pub fn attachedConst(self: *const State) ?*const LiveAttachment {
        return switch (self.attachment) {
            .attached => |*value| value,
            .detached, .closing => null,
        };
    }

    pub fn live(self: *State) ?*LiveAttachment {
        return switch (self.attachment) {
            .attached => |*value| value,
            .closing => |*value| &value.live,
            .detached => null,
        };
    }

    pub fn liveConst(self: *const State) ?*const LiveAttachment {
        return switch (self.attachment) {
            .attached => |*value| value,
            .closing => |*value| &value.live,
            .detached => null,
        };
    }

    pub fn session(self: *State) ?*agent.Session {
        const value = self.attached() orelse return null;
        return value.session;
    }

    pub fn closingSession(self: *State) ?*agent.Session {
        return switch (self.attachment) {
            .closing => |*value| value.live.session,
            .detached, .attached => null,
        };
    }

    pub fn execution(self: *State) ?*owned_execution.OwnedTaskExecution {
        const value = self.live() orelse return null;
        return &value.execution;
    }

    pub fn executionConst(self: *const State) ?*const owned_execution.OwnedTaskExecution {
        const value = self.liveConst() orelse return null;
        return &value.execution;
    }

    pub fn routeId(self: *const State) u64 {
        const value = self.liveConst() orelse return 0;
        return value.route_id;
    }

    pub fn pinnedCatalog(self: *State) ?*catalog_snapshot.Snapshot {
        const value = self.live() orelse return null;
        return if (value.pinned_catalog) |*snapshot| snapshot else null;
    }

    pub fn pinnedCatalogConst(self: *const State) ?*const catalog_snapshot.Snapshot {
        const value = self.liveConst() orelse return null;
        return if (value.pinned_catalog) |*snapshot| snapshot else null;
    }

    pub fn beginClosing(self: *State) bool {
        const value = switch (self.attachment) {
            .attached => |value| value,
            .detached, .closing => return false,
        };
        self.attachment = .{ .closing = .{ .live = value } };
        return true;
    }

    pub fn restoreCloseFailure(self: *State, health: AttachedHealth) void {
        var value = switch (self.attachment) {
            .closing => |value| value.live,
            .detached, .attached => unreachable,
        };
        value.health = health;
        self.attachment = .{ .attached = value };
    }

    pub fn detach(self: *State, cause: DetachmentCause) LiveAttachment {
        const value = switch (self.attachment) {
            .attached => |value| value,
            .closing => |value| value.live,
            .detached => unreachable,
        };
        self.attachment = .{ .detached = cause };
        return value;
    }
};

test "attachment and operation states exclude partial resource tuples" {
    try std.testing.expectEqual(@as(usize, 3), std.meta.fields(Attachment).len);
    try std.testing.expectEqual(@as(usize, 4), std.meta.fields(ActiveOperation).len);
    var state = State{};
    try std.testing.expect(state.session() == null);
    try std.testing.expect(state.execution() == null);
    try std.testing.expectEqual(@as(u64, 0), state.routeId());
}
