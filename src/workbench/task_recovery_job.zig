//! Bounded-executor job for rebuilding one Task's Agent attachment.
//!
//! The worker owns immutable attempt input only. It never retains a Task or
//! Workspace pointer and publishes exactly one linear completion.

const std = @import("std");
const agent = @import("metawork_agent");
const checkpoint_record = @import("workbench_checkpoint_record");
const checkpoint_store = @import("workbench_checkpoint_store");
const catalog_snapshot = @import("workbench_catalog_snapshot");
const owned_execution = @import("workbench_owned_task_execution");

pub const Notifier = struct {
    context: ?*anyopaque = null,
    notify_fn: *const fn (?*anyopaque) bool,

    pub fn notify(self: Notifier) void {
        _ = self.notify_fn(self.context);
    }
};

pub const WorkspaceTrust = enum {
    explicitly_trusted,
    temporary,
};

pub const OwnedWorkspaceBinding = struct {
    arena: std.heap.ArenaAllocator,
    canonical_root: []const u8,
    canonical_user_home: []const u8,
    epoch_token: []const u8,
    trust: WorkspaceTrust,

    pub fn init(
        allocator: std.mem.Allocator,
        canonical_root: []const u8,
        canonical_user_home: []const u8,
        epoch_token: []const u8,
        trust: WorkspaceTrust,
    ) std.mem.Allocator.Error!OwnedWorkspaceBinding {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const owned = arena.allocator();
        const owned_root = try owned.dupe(u8, canonical_root);
        const owned_home = try owned.dupe(u8, canonical_user_home);
        const owned_epoch = try owned.dupe(u8, epoch_token);
        return .{
            .arena = arena,
            .canonical_root = owned_root,
            .canonical_user_home = owned_home,
            .epoch_token = owned_epoch,
            .trust = trust,
        };
    }

    pub fn deinit(self: *OwnedWorkspaceBinding) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const PreparedAttempt = struct {
    attempt_id: u64,
    task_id: u64,
    binding_epoch: u64,
    checkpoint: checkpoint_record.Record,
    workspace: OwnedWorkspaceBinding,
    execution: owned_execution.OwnedTaskExecution,
    model: []u8,
    provider: agent.ProviderKind,
    builtin_tool_profile: ?agent.BuiltinToolProfile,
    mcp_selection: ?*agent.McpSelection,
    mcp_catalog_generation: ?u64,
};

pub const Failure = enum {
    cancelled,
    checkpoint_missing,
    checkpoint_mismatch,
    checkpoint_io,
    skill_catalog_unavailable,
    catalog_projection_unavailable,
    mcp_authority_stale,
    runtime_unavailable,
    session_capacity,
    restore_rejected,
    degraded,
    candidate_cleanup_failed,
};

pub const Candidate = struct {
    runtime: *agent.Runtime,
    route: agent.SessionRestoreRoute,
    execution: owned_execution.OwnedTaskExecution,
    pinned_catalog: catalog_snapshot.Snapshot,

    pub fn takeExecution(self: *Candidate) owned_execution.OwnedTaskExecution {
        return self.execution.take();
    }

    pub fn takeCatalog(self: *Candidate) catalog_snapshot.Snapshot {
        const value = self.pinned_catalog;
        self.pinned_catalog = undefined;
        return value;
    }

    /// Releases every candidate-owned resource on all paths. A failed close or
    /// release leaves the Session owned by the Agent Runtime, but the execution
    /// secret and catalog projection must never survive that failure.
    pub fn discard(self: *Candidate) bool {
        var released = switch (self.route.session.closeOutcome(.session_close)) {
            .closed => true,
            .failure => false,
        };
        if (released) self.runtime.releaseClosedSession(self.route.session) catch {
            released = false;
        };
        self.execution.deinit();
        self.pinned_catalog.deinit();
        self.* = undefined;
        return released;
    }
};

pub const Outcome = union(enum) {
    none,
    failure: Failure,
    candidate: Candidate,
};

pub const State = enum(u8) {
    queued,
    running,
    completed,
    cancelled,
};

pub const Job = struct {
    allocator: std.mem.Allocator,
    runtime: *agent.Runtime,
    store: *checkpoint_store.FileStore,
    notifier: Notifier,
    catalog_limits: catalog_snapshot.Limits,
    available_projection_bytes: usize,
    checkpoint_limits: agent.CheckpointLimits,
    attempt: PreparedAttempt,
    cancellation: std.atomic.Value(bool) = .init(false),
    state: std.atomic.Value(State) = .init(.queued),
    outcome: Outcome = .none,

    pub fn execute(context: *anyopaque) void {
        const self: *Job = @ptrCast(@alignCast(context));
        const claimed = self.state.cmpxchgStrong(
            .queued,
            .running,
            .acq_rel,
            .acquire,
        );
        std.debug.assert(claimed == null);
        self.outcome = self.run();
        self.state.store(.completed, .release);
        self.notifier.notify();
    }

    pub fn cancelQueued(context: *anyopaque) void {
        const self: *Job = @ptrCast(@alignCast(context));
        self.cancellation.store(true, .release);
        const prior = self.state.cmpxchgStrong(
            .queued,
            .cancelled,
            .acq_rel,
            .acquire,
        );
        std.debug.assert(prior == null);
        self.outcome = .{ .failure = .cancelled };
        self.notifier.notify();
    }

    pub fn requestCancellation(self: *Job) void {
        self.cancellation.store(true, .release);
    }

    pub fn completionReady(self: *const Job) bool {
        return switch (self.state.load(.acquire)) {
            .completed, .cancelled => true,
            .queued, .running => false,
        };
    }

    pub fn takeCandidate(self: *Job) ?Candidate {
        return switch (self.outcome) {
            .candidate => |candidate| candidate: {
                self.outcome = .none;
                break :candidate candidate;
            },
            .none, .failure => null,
        };
    }

    pub fn failure(self: *const Job) ?Failure {
        return switch (self.outcome) {
            .failure => |reason| reason,
            .none, .candidate => null,
        };
    }

    pub fn deinit(self: *Job) void {
        std.debug.assert(self.completionReady());
        switch (self.outcome) {
            .candidate => |*candidate| _ = candidate.discard(),
            .none, .failure => {},
        }
        if (self.attempt.mcp_selection) |selection| selection.deinit();
        self.allocator.free(self.attempt.model);
        self.attempt.execution.deinit();
        self.attempt.workspace.deinit();
        self.attempt.checkpoint.deinit(self.allocator);
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }

    fn run(self: *Job) Outcome {
        if (self.cancellation.load(.acquire))
            return .{ .failure = .cancelled };

        var acquisition = self.runtime.querySkillCatalog(.{
            .workspace_root = self.attempt.workspace.canonical_root,
            .canonical_user_home = self.attempt.workspace.canonical_user_home,
            .workspace_epoch = self.attempt.workspace.epoch_token,
        }) catch return .{ .failure = .skill_catalog_unavailable };
        var projection_live = true;
        var lease_live = true;
        defer if (lease_live) {
            if (projection_live) acquisition.projection.deinit();
            self.runtime.releaseSkillCatalog(acquisition.lease) catch {};
        };

        var snapshot = catalog_snapshot.Snapshot.init(
            self.allocator,
            acquisition.projection,
            self.catalog_limits,
            self.available_projection_bytes,
        ) catch return .{ .failure = .catalog_projection_unavailable };
        var snapshot_live = true;
        defer if (snapshot_live) snapshot.deinit();
        acquisition.projection.deinit();
        projection_live = false;

        var source = self.store.openVerified(
            self.attempt.checkpoint.blob,
            &self.cancellation,
        ) catch |err| return .{ .failure = switch (err) {
            error.Cancelled => .cancelled,
            error.BlobMissing => .checkpoint_missing,
            error.BlobMismatch => .checkpoint_mismatch,
            else => .checkpoint_io,
        } };
        defer source.deinit();

        const execution = self.attempt.execution.input();
        const route = self.runtime.restoreSessionRoute(.{
            .session = .{
                .provider = self.attempt.provider,
                .permission_mode = .default,
                .shell_policy = .unrestricted,
                .credential = execution.api_key,
                .model = self.attempt.checkpoint.session.model,
                .base_url = execution.target.base_url,
                .workspace = .{
                    .canonical_root = self.attempt.workspace.canonical_root,
                    .trust = switch (self.attempt.workspace.trust) {
                        .explicitly_trusted => .explicitly_trusted,
                        .temporary => .{ .temporary = self.attempt.workspace.canonical_root },
                    },
                },
                .canonical_user_home = self.attempt.workspace.canonical_user_home,
                .workspace_epoch = self.attempt.workspace.epoch_token,
                .allowed_tools = if (self.attempt.builtin_tool_profile) |profile|
                    agent.builtinToolsForProfile(profile)
                else
                    &agent.default_builtin_tools,
                .skill_catalog = acquisition.lease,
                .mcp_selection = self.attempt.mcp_selection,
            },
            .checkpoint_limits = self.checkpoint_limits,
            .source = .{ .context = &source, .read_fn = readCheckpoint },
            .expectation = .{
                .logical_session_id = self.attempt.checkpoint.session.logical_session_id,
                .checkpoint_generation = self.attempt.checkpoint.blob.generation,
                .last_run_id = self.attempt.checkpoint.session.last_run_id,
                .last_compact_id = self.attempt.checkpoint.session.last_compact_id,
                .model = self.attempt.checkpoint.session.model,
            },
        }) catch |err| return .{ .failure = mapRestoreError(err) };
        self.runtime.releaseSkillCatalog(acquisition.lease) catch {
            lease_live = false;
            return .{ .failure = if (discardRoute(self.runtime, route))
                .skill_catalog_unavailable
            else
                .candidate_cleanup_failed };
        };
        lease_live = false;
        if (route.report.health != .complete)
            return .{ .failure = if (discardRoute(self.runtime, route))
                .degraded
            else
                .candidate_cleanup_failed };

        route.session.setModel(self.attempt.model) catch {
            return .{ .failure = if (discardRoute(self.runtime, route))
                .restore_rejected
            else
                .candidate_cleanup_failed };
        };

        snapshot_live = false;
        return .{ .candidate = .{
            .runtime = self.runtime,
            .route = route,
            .execution = self.attempt.execution.take(),
            .pinned_catalog = snapshot,
        } };
    }
};

fn readCheckpoint(context: ?*anyopaque, destination: []u8) agent.CheckpointSourceReadResult {
    const source: *checkpoint_store.VerifiedSource = @ptrCast(@alignCast(
        context orelse return .contract_failed,
    ));
    return switch (source.read(destination)) {
        .bytes => |count| .{ .bytes = count },
        .eof => .eof,
        .cancelled => .cancelled,
        .io_failed => .io_failed,
    };
}

fn mapRestoreError(err: anyerror) Failure {
    return switch (err) {
        error.StaleMcpSelection,
        error.McpRefreshInProgress,
        error.McpNotRefreshed,
        error.InvalidMcpSelection,
        error.McpCatalogBindingMismatch,
        => .mcp_authority_stale,
        error.RuntimeShuttingDown => .runtime_unavailable,
        error.SessionCapacity => .session_capacity,
        else => .restore_rejected,
    };
}

fn discardRoute(runtime: *agent.Runtime, route: agent.SessionRestoreRoute) bool {
    switch (route.session.closeOutcome(.session_close)) {
        .closed => {},
        .failure => return false,
    }
    runtime.releaseClosedSession(route.session) catch return false;
    return true;
}

test "restore authority failures remain retryable job outcomes" {
    try std.testing.expectEqual(
        Failure.mcp_authority_stale,
        mapRestoreError(error.StaleMcpSelection),
    );
    try std.testing.expectEqual(
        Failure.mcp_authority_stale,
        mapRestoreError(error.McpRefreshInProgress),
    );
    try std.testing.expectEqual(
        Failure.runtime_unavailable,
        mapRestoreError(error.RuntimeShuttingDown),
    );
    try std.testing.expectEqual(
        Failure.session_capacity,
        mapRestoreError(error.SessionCapacity),
    );
}
