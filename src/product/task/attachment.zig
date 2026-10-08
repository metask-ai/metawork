//! Process-only Task resource ownership and legal operation state.

const std = @import("std");
const agent = @import("metawork_agent");
const catalog_snapshot = @import("metawork_product_skill").catalog;
const agent_session = @import("product_task_agent_session");
const owned_execution = @import("product_task_execution_binding");
const recovery_job = @import("product_task_recovery_job");
const worker_lease = @import("product_task_worker_lease");

pub const DetachmentCause = enum {
    cold_start,
    released,
    session_poisoned,
};

pub const AttachedHealth = enum {
    available,
    session_poisoned,
};

/// Immutable process-lifetime fact describing the MCP authority copied when
/// this Task's Session was created. It is projected to Renderer, but is not
/// persisted and never contains server, tool, or credential details.
pub const McpAuthorityAtCreation = enum {
    ready_with_selection,
    ready_without_selection,
    unavailable,
};

pub const LiveAttachment = struct {
    binding: agent_session.Binding,
    execution: owned_execution.OwnedTaskExecution,
    pinned_catalog: ?catalog_snapshot.Snapshot,
    health: AttachedHealth = .available,
};

pub const ClosingAttachment = struct {
    live: LiveAttachment,
    /// Immutable main-thread routing fact retained until the closing Task has
    /// drained every event that was queued before Agent close completed.
    route_id: u64,
    /// `beginClosing` moves the linear Session owner here. Only the close
    /// worker may touch it until the main thread joins that worker.
    worker_binding: agent_session.Binding,
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

/// Main-thread identity only. Review jobs must not retain Task/Run pointers or leases.
pub const PermissionReviewIdentity = struct {
    task_id: u64,
    run_id: u64,
    run_generation: u64,
    execution_generation: u64,
    binding_epoch: u64,
    workspace_epoch: u64,
    route_id: u64,
    request_id: u64,
    policy_generation: u64,
    delegation_generation: u64,
};

pub const PermissionReviewState = struct {
    generation: u64 = 1,
    exhausted: bool = false,
    phase: enum { idle, reviewing, needs_user } = .idle,
    identity: ?PermissionReviewIdentity = null,
    settled_request_id: u64 = 0,

    pub fn invalidate(self: *PermissionReviewState) void {
        if (self.generation == std.math.maxInt(u64)) {
            self.exhausted = true;
        } else {
            self.generation += 1;
        }
        self.phase = .idle;
        self.identity = null;
        self.settled_request_id = 0;
    }

    pub fn settle(self: *PermissionReviewState, request_id: u64) void {
        self.invalidate();
        self.phase = .needs_user;
        self.settled_request_id = request_id;
    }

    pub fn matches(self: *const PermissionReviewState, identity: PermissionReviewIdentity) bool {
        return !self.exhausted and self.phase == .reviewing and
            self.identity != null and std.meta.eql(self.identity.?, identity) and
            self.generation == identity.delegation_generation;
    }
};

pub const State = struct {
    attachment: Attachment = .{ .detached = .cold_start },
    mcp_authority_at_creation: McpAuthorityAtCreation = .unavailable,
    worker_leases: worker_lease.WorkerLeaseSet = .{},
    pending_ui_request_id: u64 = 0,
    pending_ui_order: u64 = 0,
    permission_review: PermissionReviewState = .{},
    active_run_id: u64 = 0,
    active_operation: ActiveOperation = .none,
    restore_job: ?*recovery_job.Job = null,
    last_restore_failure: ?recovery_job.Failure = null,
    /// Full AgentCore restore health is retained only in process memory. It is
    /// not a recovery admission fact and is never persisted or sent over the
    /// Renderer Bridge.
    last_restore_report: ?agent.CheckpointRestoreReport = null,
    last_restore_permission: ?RestorePermissionSummary = null,
    close_thread: ?std.Thread = null,
    close_completion: std.atomic.Value(CloseCompletion) = .init(.none),
    /// Admission closes immediately, while the Session close itself waits for
    /// the active operation and its checkpoint transaction to settle.
    close_requested: bool = false,
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

    pub fn acquireAccess(self: *State) !agent_session.Access {
        const value = self.attached() orelse return error.SessionClosing;
        return value.binding.acquireAccess();
    }

    pub fn hasAttachedSession(self: *const State) bool {
        return self.attachedConst() != null;
    }

    pub fn hasClosingSession(self: *const State) bool {
        return self.attachment == .closing;
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
        return switch (self.attachment) {
            .attached => |*value| value.binding.routeId(),
            .closing => |*value| value.route_id,
            .detached => 0,
        };
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
        var value = switch (self.attachment) {
            .attached => |value| value,
            .detached, .closing => return false,
        };
        const route_id = value.binding.routeId();
        const worker_binding = value.binding.take();
        self.attachment = .{ .closing = .{
            .live = value,
            .route_id = route_id,
            .worker_binding = worker_binding,
        } };
        self.permission_review.invalidate();
        return true;
    }

    /// Returns the close worker's exclusive owner slot. The main thread may
    /// select its address before spawn, but must not read or mutate it again
    /// until the close thread has been joined.
    pub fn closingWorkerBinding(self: *State) ?*agent_session.Binding {
        return switch (self.attachment) {
            .closing => |*value| &value.worker_binding,
            .detached, .attached => null,
        };
    }

    /// Returns the binding that remains after a close worker has been joined.
    /// Calling this while `close_thread` is live violates the ownership
    /// contract; the composition layer owns that join precondition.
    pub fn bindingAfterCloseJoin(self: *State) ?*agent_session.Binding {
        return switch (self.attachment) {
            .attached => |*value| &value.binding,
            .closing => |*value| &value.worker_binding,
            .detached => null,
        };
    }

    /// Runtime shutdown is a terminal fence: after the joined Binding has
    /// relinquished or abandoned its Session owner, no routing identity may
    /// continue to describe this closing attachment as live.
    pub fn clearClosingRouteAfterRuntimeShutdown(self: *State) void {
        switch (self.attachment) {
            .closing => |*value| value.route_id = 0,
            .detached, .attached => {},
        }
    }

    pub fn restoreCloseFailure(self: *State, health: AttachedHealth) void {
        var closing = switch (self.attachment) {
            .closing => |value| value,
            .detached, .attached => unreachable,
        };
        closing.live.binding = closing.worker_binding.take();
        closing.live.health = health;
        self.attachment = .{ .attached = closing.live };
    }

    pub fn detach(self: *State, cause: DetachmentCause) LiveAttachment {
        const value = switch (self.attachment) {
            .attached => |value| value,
            .closing => |value| closing: {
                std.debug.assert(self.close_thread == null);
                var closing_value = value;
                switch (closing_value.worker_binding.state()) {
                    .owned, .closed, .fixture => closing_value.live.binding =
                        closing_value.worker_binding.take(),
                    .released, .relinquished, .abandoned => {},
                    .moved => unreachable,
                }
                break :closing closing_value.live;
            },
            .detached => unreachable,
        };
        self.attachment = .{ .detached = cause };
        self.permission_review.invalidate();
        return value;
    }
};

test "attachment and operation states exclude partial resource tuples" {
    try std.testing.expectEqual(@as(usize, 3), std.meta.fields(Attachment).len);
    try std.testing.expectEqual(@as(usize, 4), std.meta.fields(ActiveOperation).len);
    var state = State{};
    try std.testing.expect(!state.hasAttachedSession());
    try std.testing.expect(state.execution() == null);
    try std.testing.expectEqual(@as(u64, 0), state.routeId());
}

test "permission review invalidation never reuses a delegation generation" {
    var state = PermissionReviewState{};
    state.invalidate();
    try std.testing.expectEqual(@as(u64, 2), state.generation);
    state.phase = .needs_user;
    state.invalidate();
    try std.testing.expectEqual(@as(u64, 3), state.generation);
    try std.testing.expectEqual(.idle, state.phase);
    state.generation = std.math.maxInt(u64);
    state.invalidate();
    try std.testing.expect(state.exhausted);
    try std.testing.expect(state.identity == null);
}
