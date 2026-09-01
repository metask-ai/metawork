//! Bounded-executor job for rebuilding one Task's Agent attachment.
//!
//! The worker owns immutable attempt input only. It never retains a Task or
//! Workspace pointer and publishes exactly one linear completion.

const std = @import("std");
const agent = @import("metawork_agent");
const execution_contract = @import("metawork_product_execution_contract");
const agent_session = @import("product_task_agent_session");
const checkpoint_record = @import("product_task_checkpoint_record");
const checkpoint_store = @import("product_task_checkpoint_store");
const owned_execution = @import("product_task_execution_binding");
const agent_protocol = @import("product_agent_protocol_adapter");

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

pub const WorkspaceKind = enum { manual, automatic };

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
    workspace_id: u64,
    workspace_epoch: u64,
    workspace_kind: WorkspaceKind,
    checkpoint: checkpoint_record.Record,
    workspace: OwnedWorkspaceBinding,
    execution: owned_execution.OwnedTaskExecution,
    source_execution_generation: u64,
    target_execution_generation: u64,
    task_model: []u8,
    protocol: execution_contract.Protocol,
    permission_mode: agent.PermissionMode,
    shell_policy: agent.ShellPolicy,
    permission_interaction: agent.PermissionInteraction,
};

/// Callback-time facts supplied by composition when a completed restore
/// candidate is considered for installation. Every field names authority
/// that may have changed while the worker was running; none is retained by
/// the Task Runtime.
pub const CommitAuthority = struct {
    task_id: u64,
    binding_epoch: u64,
    workspace_id: u64,
    workspace_epoch: u64,
    workspace_kind: WorkspaceKind,
    workspace_root: []const u8,
    source_execution_generation: u64,
    target_execution_generation: u64,
    task_model: []const u8,
    protocol: execution_contract.Protocol,
    active_attempt_id: ?u64,
    shutting_down: bool,
    archived: bool,
    attachment_detached: bool,
    checkpoint_matches: bool,
    workspace_authority_exact: bool,
    automatic_owner_exact: bool,
    target_execution_authority_exact: bool,
};

pub const AttemptAuthority = struct {
    attempt_id: u64,
    task_id: u64,
    binding_epoch: u64,
    workspace_id: u64,
    workspace_epoch: u64,
    workspace_kind: WorkspaceKind,
    workspace_root: []const u8,
    source_execution_generation: u64,
    target_execution_generation: u64,
    task_model: []const u8,
    protocol: execution_contract.Protocol,
};

/// A restore completion is publishable only while every authority token that
/// admitted the attempt remains exact. Stale candidates are discarded and
/// are never implicitly retried.
pub fn commitAllowed(
    attempt: *const PreparedAttempt,
    authority: CommitAuthority,
) bool {
    return authorityExact(.{
        .attempt_id = attempt.attempt_id,
        .task_id = attempt.task_id,
        .binding_epoch = attempt.binding_epoch,
        .workspace_id = attempt.workspace_id,
        .workspace_epoch = attempt.workspace_epoch,
        .workspace_kind = attempt.workspace_kind,
        .workspace_root = attempt.workspace.canonical_root,
        .source_execution_generation = attempt.source_execution_generation,
        .target_execution_generation = attempt.target_execution_generation,
        .task_model = attempt.task_model,
        .protocol = attempt.protocol,
    }, authority);
}

pub fn authorityExact(
    attempt: AttemptAuthority,
    authority: CommitAuthority,
) bool {
    return !authority.shutting_down and
        !authority.archived and
        authority.attachment_detached and
        authority.checkpoint_matches and
        authority.workspace_authority_exact and
        authority.automatic_owner_exact and
        authority.target_execution_authority_exact and
        authority.active_attempt_id != null and
        authority.active_attempt_id.? == attempt.attempt_id and
        authority.task_id == attempt.task_id and
        authority.binding_epoch == attempt.binding_epoch and
        authority.workspace_id == attempt.workspace_id and
        authority.workspace_epoch == attempt.workspace_epoch and
        authority.workspace_kind == attempt.workspace_kind and
        std.mem.eql(u8, authority.workspace_root, attempt.workspace_root) and
        authority.source_execution_generation == attempt.source_execution_generation and
        authority.target_execution_generation == attempt.target_execution_generation and
        std.mem.eql(u8, authority.task_model, attempt.task_model) and
        authority.protocol == attempt.protocol;
}

test "restore authority rejects every stale asynchronous dimension" {
    const attempt: AttemptAuthority = .{
        .attempt_id = 11,
        .task_id = 7,
        .binding_epoch = 3,
        .workspace_id = 5,
        .workspace_epoch = 9,
        .workspace_kind = .automatic,
        .workspace_root = "C:/workspace",
        .source_execution_generation = 13,
        .target_execution_generation = 17,
        .task_model = "model-a",
        .protocol = .anthropic_messages,
    };
    const current: CommitAuthority = .{
        .task_id = 7,
        .binding_epoch = 3,
        .workspace_id = 5,
        .workspace_epoch = 9,
        .workspace_kind = .automatic,
        .workspace_root = "C:/workspace",
        .source_execution_generation = 13,
        .target_execution_generation = 17,
        .task_model = "model-a",
        .protocol = .anthropic_messages,
        .active_attempt_id = 11,
        .shutting_down = false,
        .archived = false,
        .attachment_detached = true,
        .checkpoint_matches = true,
        .workspace_authority_exact = true,
        .automatic_owner_exact = true,
        .target_execution_authority_exact = true,
    };
    try std.testing.expect(authorityExact(attempt, current));

    var stale = current;
    stale.workspace_epoch += 1;
    try std.testing.expect(!authorityExact(attempt, stale));
    stale = current;
    stale.workspace_root = "C:/replacement";
    try std.testing.expect(!authorityExact(attempt, stale));
    stale = current;
    stale.workspace_kind = .manual;
    try std.testing.expect(!authorityExact(attempt, stale));
    stale = current;
    stale.source_execution_generation += 1;
    try std.testing.expect(!authorityExact(attempt, stale));
    stale = current;
    stale.target_execution_generation += 1;
    try std.testing.expect(!authorityExact(attempt, stale));
    stale = current;
    stale.task_model = "model-b";
    try std.testing.expect(!authorityExact(attempt, stale));
    stale = current;
    stale.active_attempt_id = 12;
    try std.testing.expect(!authorityExact(attempt, stale));
    stale = current;
    stale.checkpoint_matches = false;
    try std.testing.expect(!authorityExact(attempt, stale));
    stale = current;
    stale.workspace_authority_exact = false;
    try std.testing.expect(!authorityExact(attempt, stale));
    stale = current;
    stale.automatic_owner_exact = false;
    try std.testing.expect(!authorityExact(attempt, stale));
    stale = current;
    stale.target_execution_authority_exact = false;
    try std.testing.expect(!authorityExact(attempt, stale));
    stale = current;
    stale.shutting_down = true;
    try std.testing.expect(!authorityExact(attempt, stale));
}

pub const Failure = enum {
    cancelled,
    checkpoint_missing,
    checkpoint_mismatch,
    checkpoint_io,
    runtime_busy,
    runtime_refresh_required,
    runtime_unavailable,
    session_capacity,
    restore_rejected,
    binding_epoch_exhausted,
    binding_persistence_failed,
    binding_persistence_unknown,
    candidate_cleanup_failed,
};

pub const Candidate = struct {
    binding: agent_session.Binding,
    report: agent.CheckpointRestoreReport,
    execution: owned_execution.OwnedTaskExecution,

    pub fn takeExecution(self: *Candidate) owned_execution.OwnedTaskExecution {
        return self.execution.take();
    }

    pub fn takeBinding(self: *Candidate) agent_session.Binding {
        return self.binding.take();
    }

    /// Releases every candidate-owned resource on all paths. A failed close or
    /// release leaves the Session owned by the Agent Runtime, but the execution
    /// secret must never survive that failure.
    pub fn discard(self: *Candidate) bool {
        var released = switch (self.binding.closeOutcome(.session_close)) {
            .closed => true,
            .failure => false,
        };
        if (released) self.binding.releaseClosed() catch {
            released = false;
        };
        self.execution.deinit();
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
        self.allocator.free(self.attempt.task_model);
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
        var restored = agent_session.restore(self.runtime, .{
            .session = .{
                .provider_id = execution.target.provider_id,
                .protocol = agent_protocol.toAgent(execution.target.protocol),
                .permission_mode = self.attempt.permission_mode,
                .shell_policy = self.attempt.shell_policy,
                .permission_interaction = self.attempt.permission_interaction,
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
                .skill_catalog = null,
                .skill_policy = null,
                .mcp_selection = null,
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
        var access = restored.binding.acquireAccess() catch {
            return .{ .failure = if (discardBinding(&restored.binding))
                .restore_rejected
            else
                .candidate_cleanup_failed };
        };
        access.setModel(self.attempt.task_model) catch {
            access.deinit();
            return .{ .failure = if (discardBinding(&restored.binding))
                .restore_rejected
            else
                .candidate_cleanup_failed };
        };
        access.deinit();

        return .{ .candidate = .{
            .binding = restored.takeBinding(),
            .report = restored.report,
            .execution = self.attempt.execution.take(),
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
        error.McpRefreshInProgress => .runtime_busy,
        error.McpNotRefreshed,
        error.StaleMcpSelection,
        error.InvalidMcpSelection,
        error.McpCatalogBindingMismatch,
        => .runtime_refresh_required,
        error.RuntimeShuttingDown => .runtime_unavailable,
        error.SessionCapacity => .session_capacity,
        else => .restore_rejected,
    };
}

fn discardBinding(binding: *agent_session.Binding) bool {
    switch (binding.closeOutcome(.session_close)) {
        .closed => {},
        .failure => return false,
    }
    binding.releaseClosed() catch return false;
    return true;
}

test "restore Runtime serialization failures remain retryable job outcomes" {
    try std.testing.expectEqual(
        Failure.runtime_refresh_required,
        mapRestoreError(error.McpNotRefreshed),
    );
    try std.testing.expectEqual(
        Failure.runtime_refresh_required,
        mapRestoreError(error.StaleMcpSelection),
    );
    try std.testing.expectEqual(
        Failure.runtime_busy,
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
