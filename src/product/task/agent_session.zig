//! Product Task's sole ownership gateway to Agent Session.
//!
//! `Binding` owns the Product-side responsibility to return one Runtime slot.
//! `Access` is a linear, retained Session reference: it adds no allocation and
//! must be released exactly once. The wrapped Agent APIs keep their existing
//! allocation and ownership contracts.

const std = @import("std");
const agent = @import("metawork_agent");

pub const BindingState = enum {
    owned,
    closed,
    released,
    relinquished,
    moved,
    fixture,
    abandoned,
};

const Owned = struct {
    runtime: *agent.Runtime,
    session: *agent.Session,
};

pub const Binding = struct {
    owner: ?Owned,
    route_id: u64,
    binding_state: BindingState,

    pub fn open(
        runtime: *agent.Runtime,
        options: agent.SessionOpenOptions,
    ) !Binding {
        const route = try runtime.createSessionRoute(options);
        return initRoute(runtime, route);
    }

    fn initRoute(runtime: *agent.Runtime, route: agent.SessionRoute) Binding {
        std.debug.assert(route.id != 0);
        return .{
            .owner = .{
                .runtime = runtime,
                .session = route.session,
            },
            .route_id = route.id,
            .binding_state = .owned,
        };
    }

    fn initRestoreRoute(
        runtime: *agent.Runtime,
        route: agent.SessionRestoreRoute,
    ) Restored {
        return .{
            .binding = initRoute(runtime, .{
                .id = route.id,
                .session = route.session,
            }),
            .report = route.report,
        };
    }

    pub fn state(self: *const Binding) BindingState {
        return self.binding_state;
    }

    pub fn routeId(self: *const Binding) u64 {
        return self.route_id;
    }

    pub fn testFixture(route_id: u64) Binding {
        std.debug.assert(@import("builtin").is_test);
        std.debug.assert(route_id != 0);
        return .{
            .owner = null,
            .route_id = route_id,
            .binding_state = .fixture,
        };
    }

    pub fn markClosedForTest(self: *Binding) void {
        std.debug.assert(@import("builtin").is_test);
        std.debug.assert(self.binding_state == .fixture);
        self.binding_state = .closed;
    }

    pub fn markReleasedForTest(self: *Binding) void {
        std.debug.assert(@import("builtin").is_test);
        std.debug.assert(self.binding_state == .fixture);
        self.route_id = 0;
        self.binding_state = .released;
    }

    pub fn acquireAccess(self: *Binding) error{
        SessionClosing,
        RuntimeShuttingDown,
    }!Access {
        if (self.binding_state == .relinquished)
            return error.RuntimeShuttingDown;
        if (self.binding_state != .owned)
            return error.SessionClosing;
        const session = self.owner.?.session;
        if (!session.retainReference()) return error.SessionClosing;
        return .{ .session = session };
    }

    /// Starts Agent close. Existing Access leases remain valid references and
    /// Agent close waits for all of them before returning.
    pub fn closeOutcome(
        self: *Binding,
        interruption: agent.ExternalInterruption,
    ) agent.CloseOutcome {
        std.debug.assert(self.binding_state == .owned);
        const outcome = self.owner.?.session.closeOutcome(interruption);
        switch (outcome) {
            .closed => self.binding_state = .closed,
            .failure => {},
        }
        return outcome;
    }

    /// Returns a successfully closed Session slot to Agent Runtime. Success
    /// invalidates the Session pointer and makes this Binding terminal.
    pub fn releaseClosed(self: *Binding) !void {
        std.debug.assert(self.binding_state == .closed);
        const value = self.owner.?;
        try value.runtime.releaseClosedSession(value.session);
        self.owner = null;
        self.route_id = 0;
        self.binding_state = .released;
    }

    /// Runtime shutdown owns final Session destruction. This is deliberately
    /// separate from ordinary close/release and permanently disables access.
    pub fn relinquishAfterRuntimeShutdown(self: *Binding) void {
        std.debug.assert(self.binding_state == .owned or
            self.binding_state == .closed);
        self.owner = null;
        self.route_id = 0;
        self.binding_state = .relinquished;
    }

    /// Last-resort Application teardown after Runtime.shutdown failed. Runtime
    /// still owns and destroys the slot during its own immediate deinit.
    pub fn abandonForRuntimeDeinit(self: *Binding) void {
        std.debug.assert(self.binding_state == .owned or
            self.binding_state == .closed);
        self.owner = null;
        self.route_id = 0;
        self.binding_state = .abandoned;
    }

    pub fn take(self: *Binding) Binding {
        std.debug.assert(self.binding_state == .owned or
            self.binding_state == .closed or
            self.binding_state == .fixture);
        const value = self.*;
        self.owner = null;
        self.route_id = 0;
        self.binding_state = .moved;
        return value;
    }
};

pub const Restored = struct {
    binding: Binding,
    report: agent.CheckpointRestoreReport,

    pub fn takeBinding(self: *Restored) Binding {
        return self.binding.take();
    }
};

pub fn restore(
    runtime: *agent.Runtime,
    options: agent.SessionRestoreOptions,
) !Restored {
    const route = try runtime.restoreSessionRoute(options);
    return Binding.initRestoreRoute(runtime, route);
}

/// Linear retained Session capability. Copying an Access value is forbidden;
/// ownership is transferred only with `take`, and every live value must call
/// `deinit` exactly once.
pub const Access = struct {
    session: ?*agent.Session,

    pub fn take(self: *Access) Access {
        const session = self.session orelse unreachable;
        self.session = null;
        return .{ .session = session };
    }

    pub fn deinit(self: *Access) void {
        const session = self.session orelse unreachable;
        self.session = null;
        session.releaseReference();
    }

    fn get(self: *Access) *agent.Session {
        return self.session orelse unreachable;
    }

    pub fn refreshSkillCatalog(
        self: *Access,
        lease: *agent.CatalogLease,
        skill_policy: agent.SkillPolicyInput,
    ) !void {
        return self.get().refreshSkillCatalog(lease, skill_policy);
    }

    pub fn setModel(self: *Access, model: []const u8) !void {
        return self.get().setModel(model);
    }

    pub fn captureRestoreInputs(self: *Access) !agent.SessionRestoreInputs {
        return self.get().captureRestoreInputs();
    }

    pub fn sessionState(self: *Access) agent.SessionState {
        return self.get().snapshot().state;
    }

    pub fn updatePermissionMode(self: *Access, expected: agent.PermissionMode, target: agent.PermissionMode) !agent.PermissionModeUpdate {
        return self.get().updatePermissionMode(expected, target);
    }

    pub fn prepareRun(self: *Access, input: agent.RunInput) !u64 {
        return self.get().prepareRun(input);
    }

    pub fn prepareRunWithTools(self: *Access, input: agent.RunInput, image: ?agent.ImageGenerationRunInput, delivery: ?agent.FileDeliveryInput) !u64 {
        return self.get().prepareRunWithTools(input, image, delivery);
    }

    pub fn beginRunOutcome(self: *Access, run_id: u64) agent.BeginRunOutcome {
        return self.get().beginRunOutcome(run_id);
    }

    pub fn cancelPreparedRun(self: *Access, run_id: u64) !void {
        return self.get().cancelPreparedRun(run_id);
    }

    pub fn prepareCompact(self: *Access) !u64 {
        return self.get().prepareCompact();
    }

    pub fn cancelPreparedCompact(self: *Access, operation_id: u64) !void {
        return self.get().cancelPreparedCompact(operation_id);
    }

    pub fn executePreparedCompact(
        self: *Access,
        operation_id: u64,
    ) !agent.CompactTerminalResult {
        return self.get().executePreparedCompact(operation_id);
    }

    pub fn requestCompactCancellation(
        self: *Access,
        operation_id: u64,
        interruption: agent.ExternalInterruption,
    ) !void {
        return self.get().requestCompactCancellation(operation_id, interruption);
    }

    pub fn respondPermission(
        self: *Access,
        run_id: u64,
        request_id: u64,
        choice: agent.PermissionChoice,
    ) !void {
        return self.get().respondPermission(run_id, request_id, choice);
    }

    pub fn failUiRequestIdentityContract(self: *Access, run_id: u64) !void {
        return self.get().failUiRequestIdentityContract(run_id);
    }

    pub fn pendingUiObservation(
        self: *Access,
    ) ?agent.Session.PendingUiObservation {
        return self.get().pendingUiObservation();
    }

    pub fn permissionStopRequest(self: *Access) ?u64 {
        return self.get().permissionStopRequest();
    }

    pub fn copyPendingUiRequest(
        self: *Access,
        allocator: std.mem.Allocator,
    ) !agent.PendingUiRequest {
        return self.get().copyPendingUiRequest(allocator);
    }

    pub fn exportCheckpoint(
        self: *Access,
        limits: agent.CheckpointLimits,
        sink: agent.CheckpointSink,
        expected_last_run_id: u64,
        expected_last_compact_id: u64,
        expected_model: []const u8,
    ) !agent.CheckpointOutcome {
        return self.get().exportCheckpoint(
            limits,
            sink,
            expected_last_run_id,
            expected_last_compact_id,
            expected_model,
        );
    }
};

test "moved and relinquished bindings are terminal" {
    var origin = Binding.testFixture(7);
    const taken = origin.take();
    try std.testing.expectEqual(BindingState.moved, origin.state());
    try std.testing.expectEqual(@as(u64, 0), origin.routeId());
    try std.testing.expectError(error.SessionClosing, origin.acquireAccess());
    try std.testing.expectEqual(BindingState.fixture, taken.state());
    try std.testing.expectEqual(@as(u64, 7), taken.routeId());

    var relinquished = Binding{
        .owner = null,
        .route_id = 0,
        .binding_state = .relinquished,
    };
    try std.testing.expectError(
        error.RuntimeShuttingDown,
        relinquished.acquireAccess(),
    );
}
