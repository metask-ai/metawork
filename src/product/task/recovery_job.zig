//! Bounded-executor job for rebuilding one Task's Agent attachment.
//!
//! The worker owns immutable attempt input only. It never retains a Task or
//! Workspace pointer and publishes exactly one linear completion.

const std = @import("std");
const agent = @import("metawork_agent");
const models_contract = @import("metawork_product_models_contract");
const agent_session = @import("product_task_agent_session");
const checkpoint_record = @import("product_task_checkpoint_record");
const checkpoint_store = @import("product_task_checkpoint_store");
const owned_execution = @import("product_task_execution_binding");
const agent_protocol = @import("product_agent_protocol_adapter");
const worker_lease = @import("product_task_worker_lease");

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
    checkpoint: ?checkpoint_record.Record,
    run_id_floor: u64,
    compact_id_floor: u64,
    ui_request_id_floor: u64,
    workspace: OwnedWorkspaceBinding,
    execution: owned_execution.OwnedTaskExecution,
    source_execution_generation: u64,
    target_execution_generation: u64,
    task_model: []u8,
    protocol: models_contract.Protocol,
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
    protocol: models_contract.Protocol,
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
    protocol: models_contract.Protocol,
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
    report: ?agent.CheckpointRestoreReport,
    execution: owned_execution.OwnedTaskExecution,
    /// A created Session always returns to the Task's ordinary close owner,
    /// including a cancellation or mutation failure before publication.
    rejection: ?Failure = null,
    checkpoint: ?checkpoint_record.Record = null,

    pub fn takeExecution(self: *Candidate) owned_execution.OwnedTaskExecution {
        return self.execution.take();
    }

    pub fn takeBinding(self: *Candidate) agent_session.Binding {
        return self.binding.take();
    }
};

pub const Outcome = union(enum) {
    none,
    failure: Failure,
    candidate: Candidate,
    baseline: checkpoint_record.Record,
};

pub const ExportOutcome = union(enum) {
    checkpoint: checkpoint_record.Record,
    failure: struct { reason: Failure, poisoned: bool },
};

pub const RebindPhase = enum {
    exporting_baseline,
    confirming_baseline,
    closing_original,
    restoring_target,
    closing_candidate,
    restoring_original,
};

pub const ModelIntentAuthority = struct {
    source_id: []const u8,
    selection_revision: u64,
    source_generation: u64,
    catalog_generation: u64,
};

pub const RestoreCapabilities = struct {
    original: agent.SessionRestoreInputs,
    skill: ?*agent.SkillRestoreInputs,
    mcp: ?*agent.McpSelection,
    mcp_catalog_generation: ?u64 = null,

    pub fn deinit(self: *RestoreCapabilities) agent.Error!void {
        if (self.mcp) |selection| selection.deinit();
        var failure: ?agent.Error = null;
        if (self.skill) |inputs| inputs.deinit() catch |err| {
            failure = err;
        };
        self.original.deinit() catch |err| {
            failure = err;
        };
        self.* = undefined;
        if (failure) |err| return err;
    }
};

/// Process-only authority kept until publication or one original restore.
/// Only the composition thread mutates phase or the retained projection.
pub const Rebind = struct {
    phase: RebindPhase = .exporting_baseline,
    source_id: []u8,
    selection_revision: u64,
    source_generation: u64,
    catalog_generation: u64,
    approval_revision: u64,
    last_run_id: u64,
    last_compact_id: u64,
    original_execution: ?owned_execution.OwnedTaskExecution,
    original_credential: []const u8,
    original_model: ?[]u8,
    capabilities: ?RestoreCapabilities,
    projected_model: ?[]u8,
    baseline: ?checkpoint_record.Record = null,
    baseline_access: ?agent_session.Access,
    store_health: ?*std.atomic.Value(checkpoint_store.Health),
    failure: ?Failure = null,
    export_poisoned: bool = false,

    pub fn authority(self: *const Rebind) ModelIntentAuthority {
        return .{ .source_id = self.source_id, .selection_revision = self.selection_revision, .source_generation = self.source_generation, .catalog_generation = self.catalog_generation };
    }
};

pub const State = enum(u8) {
    queued,
    running,
    completed,
    cancelled,
};

/// Composition-thread state after the restore worker has completed. The
/// candidate and its lease remain owned until canonical binding is known.
pub const BindingCommit = enum { not_started, pending, committed, failed, outcome_unknown };

pub const Job = struct {
    allocator: std.mem.Allocator,
    runtime: *agent.Runtime,
    store: ?*checkpoint_store.FileStore,
    notifier: Notifier,
    checkpoint_limits: agent.CheckpointLimits,
    attempt: PreparedAttempt,
    cancellation: std.atomic.Value(bool) = .init(false),
    state: std.atomic.Value(State) = .init(.queued),
    outcome: Outcome = .none,
    lease: worker_lease.WorkerLease,
    binding_commit: BindingCommit = .not_started,
    unknown_history: ?[]u8 = null,
    rebind: ?Rebind = null,
    metask_authorization_scope: u64 = 0,
    continuation_source_id: ?u64 = null,
    export_checkpoint_fn: ?*const fn (*Job, *agent_session.Access, []const u8) ExportOutcome = null,
    /// Borrowed from the transferred execution owner. Workers never mutate
    /// this view; composition clears it before freeing a rejected execution.
    credential: []const u8 = &.{},

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
        const notifier = self.notifier;
        self.state.store(.completed, .release);
        notifier.notify();
    }

    pub fn cancelQueued(context: *anyopaque) void {
        const self: *Job = @ptrCast(@alignCast(context));
        self.cancellation.store(true, .release);
        const prior = self.state.cmpxchgStrong(
            .queued,
            .running,
            .acq_rel,
            .acquire,
        );
        std.debug.assert(prior == null);
        self.outcome = .{ .failure = .cancelled };
        const notifier = self.notifier;
        self.state.store(.cancelled, .release);
        notifier.notify();
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
            .none, .failure, .baseline => null,
        };
    }

    pub fn failure(self: *const Job) ?Failure {
        return switch (self.outcome) {
            .failure => |reason| reason,
            .none, .candidate, .baseline => null,
        };
    }

    pub fn deinit(self: *Job) bool {
        std.debug.assert(self.completionReady());
        // Composition must install or transfer the candidate to its ordinary
        // closing owner before freeing the restore attempt.
        std.debug.assert(self.outcome != .candidate);
        var cleanup_ok = true;
        if (self.outcome == .baseline) self.outcome.baseline.deinit(self.allocator);
        if (self.rebind) |*rebind| {
            std.debug.assert(rebind.projected_model == null);
            if (rebind.baseline_access) |*access| access.deinit();
            if (rebind.baseline) |*baseline| baseline.deinit(self.allocator);
            if (rebind.capabilities) |*capabilities| capabilities.deinit() catch {
                cleanup_ok = false;
            };
            if (rebind.original_model) |model| self.allocator.free(model);
            if (rebind.original_execution) |*execution| execution.deinit();
            self.allocator.free(rebind.source_id);
        }
        if (self.unknown_history) |bytes| self.allocator.free(bytes);
        self.allocator.free(self.attempt.task_model);
        self.attempt.execution.deinit();
        self.attempt.workspace.deinit();
        if (self.attempt.checkpoint) |*checkpoint| checkpoint.deinit(self.allocator);
        self.lease.deinit();
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
        return cleanup_ok;
    }

    fn run(self: *Job) Outcome {
        if (self.cancellation.load(.acquire))
            return .{ .failure = .cancelled };

        if (self.rebind) |*rebind| if (rebind.phase == .exporting_baseline) {
            var access = rebind.baseline_access.?.take();
            rebind.baseline_access = null;
            defer access.deinit();
            const result = self.export_checkpoint_fn.?(self, &access, rebind.original_execution.?.model);
            return switch (result) {
                .checkpoint => |record| .{ .baseline = record },
                .failure => |failure_value| failed: {
                    rebind.export_poisoned = failure_value.poisoned;
                    break :failed .{ .failure = failure_value.reason };
                },
            };
        };

        const execution = self.attempt.execution.input();
        const capabilities = if (self.rebind) |rebind| rebind.capabilities else null;
        var image_capabilities: [models_contract.max_model_image_capabilities]agent.ModelImageCapability = undefined;
        std.debug.assert(execution.target.image_capabilities.len <= image_capabilities.len);
        for (execution.target.image_capabilities, 0..) |entry, index| image_capabilities[index] = .{ .model = entry.model, .supported = entry.supported };
        const options: agent.SessionOpenOptions = .{
            .model_binding = .{
                .image_capabilities = image_capabilities[0..execution.target.image_capabilities.len],
                .target = .{
                    .provider_id = execution.target.provider_id,
                    .protocol = agent_protocol.toAgent(execution.target.protocol),
                    .base_url = execution.target.base_url,
                    .model = if (self.attempt.checkpoint) |checkpoint| checkpoint.session.model else self.attempt.task_model,
                },
                .credential = execution.api_key,
            },
            .permission_mode = self.attempt.permission_mode,
            .shell_policy = self.attempt.shell_policy,
            .permission_interaction = self.attempt.permission_interaction,
            .workspace = .{
                .canonical_root = self.attempt.workspace.canonical_root,
                .trust = switch (self.attempt.workspace.trust) {
                    .explicitly_trusted => .explicitly_trusted,
                    .temporary => .{ .temporary = self.attempt.workspace.canonical_root },
                },
            },
            .canonical_user_home = self.attempt.workspace.canonical_user_home,
            .workspace_epoch = self.attempt.workspace.epoch_token,
            .skill_catalog = if (capabilities) |value| if (value.skill) |inputs| inputs.borrow().catalog else null else null,
            .skill_policy = if (capabilities) |value| if (value.skill) |inputs| inputs.borrow().policy else null else null,
            .mcp_selection = if (capabilities) |value| value.mcp else null,
            .operation_id_floor = .{
                .last_run_id = self.attempt.run_id_floor,
                .last_compact_id = self.attempt.compact_id_floor,
                .last_ui_request_id = self.attempt.ui_request_id_floor,
            },
        };
        var report: ?agent.CheckpointRestoreReport = null;
        var binding = if (self.attempt.checkpoint) |checkpoint| restored: {
            var source = self.store.?.openVerified(checkpoint.blob, &self.cancellation) catch |err| return .{ .failure = switch (err) {
                error.Cancelled => .cancelled,
                error.BlobMissing => .checkpoint_missing,
                error.BlobMismatch => .checkpoint_mismatch,
                else => .checkpoint_io,
            } };
            defer source.deinit();
            var restored = agent_session.restore(self.runtime, .{
                .session = options,
                .checkpoint_limits = self.checkpoint_limits,
                .source = .{ .context = &source, .read_fn = readCheckpoint },
                .expectation = .{
                    .logical_session_id = checkpoint.session.logical_session_id,
                    .checkpoint_generation = checkpoint.blob.generation,
                    .last_run_id = checkpoint.session.last_run_id,
                    .last_compact_id = checkpoint.session.last_compact_id,
                    .model = checkpoint.session.model,
                },
            }) catch |err| return .{ .failure = mapRestoreError(err) };
            report = restored.report;
            break :restored restored.takeBinding();
        } else agent_session.Binding.open(self.runtime, options) catch |err| return .{ .failure = mapRestoreError(err) };
        if (self.cancellation.load(.acquire)) return self.rejectCandidate(&binding, report, .cancelled);
        var access = binding.acquireAccess() catch {
            return self.rejectCandidate(&binding, report, .restore_rejected);
        };
        access.setModel(self.attempt.task_model) catch {
            access.deinit();
            return self.rejectCandidate(&binding, report, .restore_rejected);
        };
        access.deinit();

        var target_checkpoint: ?checkpoint_record.Record = null;
        const export_target = if (self.rebind) |rebind| rebind.capabilities != null or
            (self.attempt.checkpoint != null and !std.mem.eql(u8, self.attempt.checkpoint.?.session.model, self.attempt.task_model)) else false;
        if (export_target and self.store != null) {
            var export_access = binding.acquireAccess() catch return self.rejectCandidate(&binding, report, .restore_rejected);
            defer export_access.deinit();
            switch (self.export_checkpoint_fn.?(self, &export_access, self.attempt.task_model)) {
                .checkpoint => |record| target_checkpoint = record,
                .failure => |failure_value| return self.rejectCandidate(&binding, report, failure_value.reason),
            }
        }

        return .{ .candidate = .{
            .binding = binding.take(),
            .report = report,
            .execution = self.attempt.execution.take(),
            .checkpoint = target_checkpoint,
        } };
    }

    fn rejectCandidate(self: *Job, binding: *agent_session.Binding, report: ?agent.CheckpointRestoreReport, reason: Failure) Outcome {
        return .{ .candidate = .{
            .binding = binding.take(),
            .report = report,
            .execution = self.attempt.execution.take(),
            .rejection = reason,
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
