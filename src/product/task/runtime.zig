//! Live Product Task aggregate.
//! The Runtime owns Task collection identity, runtime-only failure evidence and
//! process lifecycle facts. Cross-owner admission and shared history commit
//! effects are supplied by composition; they are never retained here.

const std = @import("std");
const agent = @import("metawork_agent");
const models_contract = @import("metawork_product_models_contract");
const task_state = @import("product_task_state");
const task_persistence = @import("product_task_persistence");
const task_policy = @import("product_task_policy");
const task_view = @import("product_task_view");
const checkpoint_store = @import("product_task_checkpoint_store");
const file_change_store = @import("product_task_file_change_store");
const task_execution = @import("product_task_execution");
const task_attachment = @import("product_task_attachment");
const task_deletion = @import("product_task_deletion");
const task_recovery = @import("product_task_recovery");
const task_agent_session = @import("product_task_agent_session");
const owned_task_execution = @import("product_task_execution_binding");
const product_skill = @import("metawork_product_skill");
const recovery_job = @import("product_task_recovery_job");
const agent_protocol = @import("product_agent_protocol_adapter");

pub const DurableCommit = task_persistence.Commit;
pub const RunOutcome = task_state.RunOutcome;
pub const TerminalSummary = struct {
    outcome: RunOutcome,
    permission_required: bool,
};
pub const ContinuationCapability = task_state.ContinuationCapability;
pub const ExecutionIdentity = struct {
    generation: u64,
    protocol: task_state.Protocol,
    model: []const u8,
};

pub const FileLocatorKind = enum { workspace_path, absolute_path, uri };
pub const FilePosition = struct { line: u64, column: u64 };
pub const FileRange = struct { start: FilePosition, end: FilePosition };
pub const FileReference = struct {
    workspace_id: u64,
    workspace_epoch: u64,
    workspace_root: []const u8,
    id: []const u8,
    title: []const u8,
    display_path: []const u8,
    kind: []const u8,
    locator_kind: FileLocatorKind,
    locator: []const u8,
    range: ?FileRange,
};

pub const FileChangeArtifactReference = struct {
    artifact: task_state.FileChangeArtifact,
    diff_complete: bool,
    redacted: bool,
};

pub const EventProjection = task_state.EventProjection;
pub const FileChangeDiffAdmission = union(enum) {
    queued: struct { redacted: bool },
    unavailable,
};
pub const FileChangeDiffEffects = struct {
    context: *anyopaque,
    enqueue_fn: *const fn (
        *anyopaque,
        u64,
        u64,
        u64,
        []const u8,
    ) FileChangeDiffAdmission,

    fn enqueue(
        self: FileChangeDiffEffects,
        task_id: u64,
        run_generation: u64,
        change_order: u64,
        content: []const u8,
    ) FileChangeDiffAdmission {
        return self.enqueue_fn(
            self.context,
            task_id,
            run_generation,
            change_order,
            content,
        );
    }
};
pub const EventEffects = struct {
    text: TextProjection,
    file_change_diff: FileChangeDiffEffects,
    max_assistant_message_bytes: usize,
    max_commentary_segments_per_run: usize,
    max_tool_field_bytes: usize,
    max_file_refs_per_tool: usize,
    max_file_ref_field_bytes: usize,
    max_file_changes_per_run: usize = 256,
    max_file_change_field_bytes: usize = 4096,
    max_file_change_diff_bytes: usize = 256 * 1024,
};
pub const EventOutcome = union(enum) {
    unknown,
    unchanged,
    late_terminal: struct { task_id: u64, count: u64 },
    applied: struct { durable_boundary: bool },
};

pub const WorkspaceSignals = struct {
    running: u32 = 0,
    attention: u32 = 0,
    failed_or_interrupted: u32 = 0,
};

pub const WorkspaceRemovalState = enum {
    ready,
    pending,
    close_failed,
};

pub const CatalogRefreshFacts = struct {
    workspace_id: u64,
    workspace_epoch: u64,
};

pub const CatalogRefreshError = error{
    UnknownTask,
    BindingEpochMismatch,
    TaskBusy,
    TaskClosing,
};

pub const ProjectedText = struct {
    value: []u8,
    truncated: bool,
    redacted: bool,
};

pub const TextProjection = struct {
    context: *anyopaque,
    project_fn: *const fn (
        *anyopaque,
        []const u8,
        usize,
        []const u8,
        usize,
    ) (std.mem.Allocator.Error || error{ProjectionCapacity})!ProjectedText,
    discard_candidate_fn: *const fn (*anyopaque, []u8) void,
    discard_previous_fn: *const fn (*anyopaque, []u8) void,
    restore_previous_fn: *const fn (*anyopaque, usize) void,
    allocate_capacity_fn: *const fn (*anyopaque, usize) (std.mem.Allocator.Error || error{ProjectionCapacity})![]u8,
    reserve_bytes_fn: *const fn (*anyopaque, usize) error{ProjectionCapacity}!void,
    release_bytes_fn: *const fn (*anyopaque, usize) void,

    fn project(
        self: TextProjection,
        value: []const u8,
        max: usize,
        sensitive: []const u8,
        reclaimable: usize,
    ) (std.mem.Allocator.Error || error{ProjectionCapacity})!ProjectedText {
        return self.project_fn(self.context, value, max, sensitive, reclaimable);
    }

    fn discardCandidate(self: TextProjection, value: []u8) void {
        self.discard_candidate_fn(self.context, value);
    }

    fn discardPrevious(self: TextProjection, value: []u8) void {
        self.discard_previous_fn(self.context, value);
    }

    fn restorePrevious(self: TextProjection, bytes: usize) void {
        self.restore_previous_fn(self.context, bytes);
    }

    fn allocateCapacity(
        self: TextProjection,
        capacity: usize,
    ) (std.mem.Allocator.Error || error{ProjectionCapacity})![]u8 {
        return self.allocate_capacity_fn(self.context, capacity);
    }

    fn reserveBytes(self: TextProjection, bytes: usize) error{ProjectionCapacity}!void {
        return self.reserve_bytes_fn(self.context, bytes);
    }

    fn releaseBytes(self: TextProjection, bytes: usize) void {
        self.release_bytes_fn(self.context, bytes);
    }
};

pub const AttachmentKind = task_state.AttachmentKind;
pub const AttachmentFormat = task_state.AttachmentFormat;
pub const MultimodalAttachment = struct {
    kind: AttachmentKind,
    format: AttachmentFormat,
    display_name: []const u8,
    bytes: []const u8,
};

pub const RunInput = union(enum) {
    text: []const u8,
    skill: struct {
        skill_id: []const u8,
        catalog_revision: []const u8,
        selection_revision: u64,
        argument_values: []const []const u8,
    },
    multimodal: struct {
        text: []const u8,
        attachments: []const MultimodalAttachment,
    },
};

pub const RunAcceptanceEffect = struct {
    context: ?*anyopaque = null,
    accept_fn: *const fn (?*anyopaque) void = ignoreRunAcceptance,
    irreversible: bool = false,

    fn accept(self: RunAcceptanceEffect) void {
        self.accept_fn(self.context);
    }
};

fn ignoreRunAcceptance(_: ?*anyopaque) void {}

pub const PermissionChoice = enum {
    allow_once,
    allow_session,
    deny_once,
    deny_session,
};

pub const UiResponse = struct { permission: PermissionChoice };

pub const OperationLimits = struct {
    max_user_message_bytes: usize,
    max_catalog_projection_bytes: usize,
    max_tool_field_bytes: usize,
    max_terminal_diagnostic_bytes: usize,
    max_tools_per_run: usize,
    max_file_changes_per_run: usize = 256,
    max_commentary_segments_per_run: usize,
    max_skill_arguments: usize,
    max_task_title_bytes: usize,
    max_model_id_bytes: usize,
};

pub const ExecutorPort = struct {
    context: *anyopaque,
    enqueue_fn: *const fn (
        *anyopaque,
        *anyopaque,
        *anyopaque,
        *const fn (*anyopaque) void,
        *const fn (*anyopaque) void,
    ) error{ ExecutorShuttingDown, QueueFull }!void,
    cancel_fn: *const fn (*anyopaque, *anyopaque) bool,

    fn enqueue(
        self: ExecutorPort,
        identity: *anyopaque,
        context: *anyopaque,
        execute_fn: *const fn (*anyopaque) void,
        cancel_fn: *const fn (*anyopaque) void,
    ) error{ ExecutorShuttingDown, QueueFull }!void {
        return self.enqueue_fn(
            self.context,
            identity,
            context,
            execute_fn,
            cancel_fn,
        );
    }

    fn cancel(self: ExecutorPort, identity: *anyopaque) bool {
        return self.cancel_fn(self.context, identity);
    }
};

pub const WorkerResources = struct {
    notifier: task_execution.Notifier,
    completion_factory: task_execution.CompletionFactory,
    projector: task_execution.TextProjector = .{
        .project_fn = task_execution.projectSanitized,
    },
    checkpoint: task_execution.CheckpointResources,
};

pub const WorkspaceOrderEffect = struct {
    context: *anyopaque,
    manual: bool,
    recent_order: u64,
    apply_fn: *const fn (*anyopaque, u64) void,
    rollback_fn: *const fn (*anyopaque, u64) void,

    fn apply(self: WorkspaceOrderEffect) void {
        if (self.manual) self.apply_fn(self.context, self.recent_order);
    }

    fn rollback(self: WorkspaceOrderEffect) void {
        if (self.manual) self.rollback_fn(self.context, self.recent_order);
    }
};

pub const OperationEffects = struct {
    text: TextProjection,
    release: ReleaseEffects,
    executor: ExecutorPort,
    worker: WorkerResources,
    limits: OperationLimits,
    run_acceptance: RunAcceptanceEffect = .{},
};

pub const RunError = agent.Error || std.mem.Allocator.Error || error{
    ProjectionCapacity,
    UnknownTask,
    BindingEpochMismatch,
    TaskClosing,
    TaskBusy,
    ExecutionUnavailable,
    ExecutionGenerationMismatch,
    CatalogUnavailable,
    StaleCatalog,
    SkillNotFound,
    SkillUnavailable,
    InvalidSkillArguments,
    RunCapacity,
    RunGenerationExhausted,
    TaskPersistenceFailed,
    TaskPersistenceOutcomeUnknown,
    ExecutorShuttingDown,
    QueueFull,
};

pub const CompactError = agent.Error || std.mem.Allocator.Error || error{
    ProjectionCapacity,
    UnknownTask,
    BindingEpochMismatch,
    TaskClosing,
    TaskBusy,
    ExecutionUnavailable,
    ExecutionGenerationMismatch,
    CompactCapacity,
    NoSuchRun,
    TaskPersistenceFailed,
    TaskPersistenceOutcomeUnknown,
    ExecutorShuttingDown,
    QueueFull,
};

pub const ControlError = agent.Error || std.mem.Allocator.Error || error{
    ProjectionCapacity,
    UnknownTask,
    NoSuchRun,
    NoSuchCompact,
    TaskClosing,
    TaskPersistenceFailed,
    TaskPersistenceOutcomeUnknown,
};

pub const ModelError = agent.Error || std.mem.Allocator.Error || error{
    ProjectionCapacity,
    UnknownTask,
    TaskBusy,
    TaskClosing,
    TaskModelMismatch,
    TaskPersistenceFailed,
    TaskPersistenceOutcomeUnknown,
};

pub const CloseError = ControlError || std.Thread.SpawnError || error{
    CloseInProgress,
    TaskBusy,
};

pub const RecoveryStartFacts = struct {
    workspace_id: u64,
    workspace_epoch: u64,
    execution_model: []const u8,
};

pub const RecoveryWorkspaceTrust = enum { explicitly_trusted, temporary };

pub const RecoveryStartInput = struct {
    expected_binding_epoch: u64,
    workspace_id: u64,
    workspace_epoch: u64,
    workspace_root: []const u8,
    canonical_user_home: []const u8,
    workspace_trust: RecoveryWorkspaceTrust,
    workspace_kind: recovery_job.WorkspaceKind,
    execution: models_contract.ConfigInput,
    agent_runtime: *agent.Runtime,
    checkpoint_store: *checkpoint_store.FileStore,
    checkpoint_limits: agent.CheckpointLimits,
    notifier: task_execution.Notifier,
    executor: ExecutorPort,
};

pub const RecoveryStartError = agent.Error || std.mem.Allocator.Error || error{
    UnknownTask,
    BindingEpochMismatch,
    RecoveryUnavailable,
    RestoreAttemptExhausted,
    ExecutorShuttingDown,
    QueueFull,
};

pub const MutationError = std.mem.Allocator.Error || error{
    ProjectionCapacity,
    UnknownTask,
    TaskBusy,
    InvalidTaskTitle,
    TaskPersistenceFailed,
    TaskPersistenceOutcomeUnknown,
};

pub const DeletionError = error{
    UnknownTask,
    TaskNotArchived,
    TaskPersistenceFailed,
    TaskPersistenceOutcomeUnknown,
};

pub const DeletionSync = struct {
    changed: bool = false,
    failed_task_id: ?u64 = null,
    failed_commit: ?DurableCommit = null,
};

pub const CreateCandidate = struct {
    execution_generation: u64,
    execution_protocol: task_state.Protocol,
    execution_model: []u8,
    permission_profile: task_state.PermissionProfile,
    permission_interaction: task_state.PermissionInteraction,
    workspace_id: u64,
    workspace_epoch: u64,
    workspace_root: []u8,
    title: []u8,
    binding: task_agent_session.Binding,
    execution: owned_task_execution.OwnedTaskExecution,
    pinned_catalog: ?product_skill.catalog.Snapshot,
    mcp_authority: task_attachment.McpAuthorityAtCreation,
};

pub const CreateWorkspaceTrust = union(enum) {
    explicitly_trusted,
    temporary: []const u8,
};

pub const CreateTaskInput = struct {
    agent_runtime: *agent.Runtime,
    execution: models_contract.ConfigInput,
    protocol: task_state.Protocol,
    model: []const u8,
    permission_profile: task_state.PermissionProfile,
    permission_interaction: task_state.PermissionInteraction,
    workspace_id: u64,
    workspace_epoch: u64,
    workspace_root: []const u8,
    workspace_trust: CreateWorkspaceTrust,
    canonical_user_home: []const u8,
    skill_catalog: ?*agent.CatalogLease,
    granted_skill_ids: []const []const u8,
    mcp_selection: ?*const agent.McpSelection,
    mcp_authority: task_attachment.McpAuthorityAtCreation,
    pinned_catalog: *?product_skill.catalog.Snapshot,
    max_workspace_bytes: usize,
    max_title_bytes: usize,
    max_model_id_bytes: usize,
    max_runs: usize,
    max_compacts: usize,
    max_ui_history: usize,
    workspace_order: WorkspaceOrderEffect,
    text: TextProjection,
    release: ReleaseEffects,
};

pub const CreateTaskError = CreateError || agent.Error || error{
    ProjectionCapacity,
};

pub const CreateError = std.mem.Allocator.Error || error{
    TaskCapacity,
    TaskIdentityExhausted,
    TaskPersistenceFailed,
    TaskPersistenceOutcomeUnknown,
};

pub const LifecycleSync = struct {
    changed: bool = false,
    durable_changed: bool = false,
};

pub const ReleaseEffects = struct {
    context: *anyopaque,
    redact_all_fn: *const fn (*anyopaque, []const u8) void,
    release_projection_bytes_fn: *const fn (*anyopaque, usize) void,

    fn redactAll(self: ReleaseEffects, credential: []const u8) void {
        self.redact_all_fn(self.context, credential);
    }

    fn releaseProjectionBytes(self: ReleaseEffects, bytes: usize) void {
        self.release_projection_bytes_fn(self.context, bytes);
    }
};

pub const PreparedCreate = struct {
    runtime: *Runtime,
    slot: usize,
    task_id: u64,
    previous_next_recent_order: u64,
    release: ReleaseEffects,
    active: bool = true,

    pub fn id(self: *const PreparedCreate) u64 {
        return self.task_id;
    }

    pub fn complete(self: *PreparedCreate) u64 {
        std.debug.assert(self.active);
        self.active = false;
        return self.task_id;
    }

    pub fn rollback(self: *PreparedCreate) void {
        std.debug.assert(self.active);
        var removed = self.runtime.tasks[self.slot].?;
        self.runtime.tasks[self.slot] = null;
        self.runtime.next_task_id = self.task_id;
        self.runtime.next_recent_order = self.previous_next_recent_order;
        deinitTask(self.runtime, &removed, self.release);
        self.active = false;
    }
};

pub const PreparedRun = struct {
    runtime: *Runtime,
    task: *task_state.Task,
    slot: usize,
    run_id: u64,
    job: *task_execution.RunJob,
    workspace: WorkspaceOrderEffect,
    effects: OperationEffects,
    previous_active_run_id: u64,
    previous_active_operation: task_state.ActiveOperation,
    previous_recent_order: u64,
    previous_next_recent_order: u64,
    previous_title: []u8,
    previous_title_redacted: bool,
    provisional_title_applied: bool,
    active: bool = true,

    pub fn id(self: *const PreparedRun) u64 {
        return self.run_id;
    }

    pub fn rollback(self: *PreparedRun) void {
        std.debug.assert(self.active);
        task_execution.cancelPreparedRunOrPanic(self.job.sessionAccess(), self.run_id);
        self.job.destroy();
        self.task.runtime.active_run_id = self.previous_active_run_id;
        self.task.runtime.active_operation = self.previous_active_operation;
        self.task.durable.recent_order = self.previous_recent_order;
        self.runtime.next_recent_order = self.previous_next_recent_order;
        self.workspace.rollback();
        self.task.durable.next_run_generation -= 1;
        if (self.provisional_title_applied) {
            self.effects.text.discardCandidate(self.task.durable.title);
            self.effects.text.restorePrevious(self.previous_title.len);
            self.task.durable.title = self.previous_title;
            self.task.durable.title_redacted = self.previous_title_redacted;
        }
        discardRun(self.runtime, self.task, self.slot, self.effects.release);
        self.active = false;
    }

    pub fn submit(
        self: *PreparedRun,
    ) error{ ExecutorShuttingDown, QueueFull }!u64 {
        std.debug.assert(self.active);
        if (self.provisional_title_applied)
            self.effects.text.discardPrevious(self.previous_title);
        self.effects.run_acceptance.accept();
        const run_record = &self.task.durable.runs[self.slot].?;
        self.effects.executor.enqueue(
            run_record,
            self.job,
            task_execution.executeRun,
            task_execution.cancelRun,
        ) catch |err| {
            task_execution.publishAutomaticTitleFallback(run_record);
            task_execution.cancelPreparedRunOrPanic(self.job.sessionAccess(), self.run_id);
            self.job.destroy();
            _ = task_execution.commitRunTerminal(
                self.effects.worker.projector,
                run_record,
                .interrupted,
                .interrupted,
                .queue_capacity_failure,
                .reusable,
                "",
                false,
            );
            run_record.terminal_observed = true;
            run_record.event_stream_finalized = true;
            self.task.runtime.active_operation = .none;
            self.active = false;
            return err;
        };
        self.active = false;
        return self.run_id;
    }
};

pub const PreparedCompact = struct {
    runtime: *Runtime,
    task: *task_state.Task,
    slot: usize,
    operation_id: u64,
    job: *task_execution.CompactJob,
    effects: OperationEffects,
    previous_active_operation: task_state.ActiveOperation,
    previous_recent_order: u64,
    previous_next_recent_order: u64,
    active: bool = true,

    pub fn id(self: *const PreparedCompact) u64 {
        return self.operation_id;
    }

    pub fn rollback(self: *PreparedCompact) void {
        std.debug.assert(self.active);
        task_execution.cancelPreparedCompactOrPanic(
            self.job.sessionAccess(),
            self.operation_id,
        );
        self.job.destroy();
        self.task.runtime.active_operation = self.previous_active_operation;
        self.task.durable.recent_order = self.previous_recent_order;
        self.runtime.next_recent_order = self.previous_next_recent_order;
        discardCompact(self.runtime, self.task, self.slot, self.effects.release);
        self.active = false;
    }

    pub fn submit(
        self: *PreparedCompact,
    ) error{ ExecutorShuttingDown, QueueFull }!u64 {
        std.debug.assert(self.active);
        const compact = &self.task.durable.compacts[self.slot].?;
        self.effects.executor.enqueue(
            compact,
            self.job,
            task_execution.executeCompact,
            task_execution.cancelCompact,
        ) catch |err| {
            task_execution.cancelPreparedCompactOrPanic(
                self.job.sessionAccess(),
                self.operation_id,
            );
            self.job.destroy();
            _ = task_execution.commitCompactProductTerminal(
                self.effects.worker.projector,
                compact,
                .failed,
                .resource_limit,
                .reusable,
                .{},
                0,
                0,
                "",
                false,
            );
            compact.terminal_observed = true;
            self.task.runtime.active_operation = .none;
            self.active = false;
            return err;
        };
        self.active = false;
        return self.operation_id;
    }
};

pub const PreparedUiResponse = struct {
    runtime: *Runtime,
    task: *task_state.Task,
    run: *task_state.RunRecord,
    access: task_agent_session.Access,
    run_id: u64,
    request_id: u64,
    response: UiResponse,
    history_slot: usize,
    previous_history_record: ?task_state.UiRecord,
    previous_history_next: usize,
    previous_history_count: usize,
    previous_pending_request_id: u64,
    previous_pending_order: u64,
    previous_activity_order: u64,
    previous_recent_order: u64,
    previous_next_recent_order: u64,
    active: bool = true,

    pub fn rollback(self: *PreparedUiResponse) void {
        std.debug.assert(self.active);
        rollbackUiRecord(
            self.task,
            self.run,
            self.history_slot,
            self.previous_history_record,
            self.previous_history_next,
            self.previous_history_count,
            self.previous_pending_request_id,
            self.previous_pending_order,
            self.previous_activity_order,
            self.previous_recent_order,
        );
        self.runtime.next_recent_order = self.previous_next_recent_order;
        self.access.deinit();
        self.active = false;
    }

    pub fn deliver(
        self: *PreparedUiResponse,
    ) (agent.Error || std.mem.Allocator.Error)!void {
        std.debug.assert(self.active);
        self.access.respondPermission(
            self.run_id,
            self.request_id,
            permissionChoice(self.response.permission),
        ) catch |err| {
            self.rollback();
            return err;
        };
        self.access.deinit();
        self.active = false;
    }
};

pub const RedactionEffects = struct {
    redact_fn: *const fn ([]u8, []const u8) bool,
    release_projection_bytes_fn: *const fn (*anyopaque, usize) void,
    context: *anyopaque,

    fn redact(self: RedactionEffects, value: []u8, credential: []const u8) bool {
        return self.redact_fn(value, credential);
    }

    fn releaseProjectionBytes(self: RedactionEffects, bytes: usize) void {
        self.release_projection_bytes_fn(self.context, bytes);
    }
};

pub const CheckpointEffects = struct {
    context: *anyopaque,
    commit_fn: *const fn (
        *anyopaque,
        ?task_persistence.CheckpointPersistenceOverride,
    ) DurableCommit,
    delete_fn: *const fn (*anyopaque, checkpoint_store.Identity) void,

    fn commit(
        self: CheckpointEffects,
        value: ?task_persistence.CheckpointPersistenceOverride,
    ) DurableCommit {
        return self.commit_fn(self.context, value);
    }

    fn delete(self: CheckpointEffects, identity: checkpoint_store.Identity) void {
        self.delete_fn(self.context, identity);
    }
};

pub const SessionReleaseOutcome = enum { unchanged, started, failed };

pub const SessionReleaseEffect = struct {
    context: *anyopaque,
    release_fn: *const fn (*anyopaque, u64) SessionReleaseOutcome,

    fn release(self: SessionReleaseEffect, task_id: u64) SessionReleaseOutcome {
        return self.release_fn(self.context, task_id);
    }
};

pub const ExecutorCancellation = struct {
    context: *anyopaque,
    cancel_fn: *const fn (*anyopaque, *anyopaque) bool,

    fn cancel(self: ExecutorCancellation, identity: *anyopaque) bool {
        return self.cancel_fn(self.context, identity);
    }
};

pub const DeletionEffects = struct {
    context: *anyopaque,
    release_session_fn: *const fn (*anyopaque, u64) SessionReleaseOutcome,
    commit_without_task_fn: *const fn (*anyopaque, u64) DurableCommit,
    delete_checkpoint_task_fn: *const fn (*anyopaque, u64) void,
    delete_file_change_task_fn: *const fn (*anyopaque, u64) void,
    release: ReleaseEffects,

    fn releaseSession(self: DeletionEffects, task_id: u64) SessionReleaseOutcome {
        return self.release_session_fn(self.context, task_id);
    }

    fn commitWithoutTask(self: DeletionEffects, workspace_id: u64) DurableCommit {
        return self.commit_without_task_fn(self.context, workspace_id);
    }

    fn deleteCheckpointTask(self: DeletionEffects, task_id: u64) void {
        self.delete_checkpoint_task_fn(self.context, task_id);
    }

    fn deleteFileChangeTask(self: DeletionEffects, task_id: u64) void {
        self.delete_file_change_task_fn(self.context, task_id);
    }
};

pub const RecoveryAuthorityQuery = struct {
    task_id: u64,
    workspace_id: u64,
    workspace_epoch: u64,
    target_execution_generation: u64,
    task_model: []const u8,
    protocol: models_contract.Protocol,
};

pub const RecoveryExternalAuthority = struct {
    workspace_root: []const u8,
    workspace_kind: recovery_job.WorkspaceKind,
    target_execution_generation: u64,
    shutting_down: bool,
    workspace_authority_exact: bool,
    automatic_owner_exact: bool,
    target_execution_authority_exact: bool,
};

pub const RecoveryEffects = struct {
    context: *anyopaque,
    authority_fn: *const fn (
        *anyopaque,
        RecoveryAuthorityQuery,
    ) RecoveryExternalAuthority,
    commit_binding_fn: *const fn (*anyopaque) DurableCommit,

    fn authority(
        self: RecoveryEffects,
        query: RecoveryAuthorityQuery,
    ) RecoveryExternalAuthority {
        return self.authority_fn(self.context, query);
    }

    fn commitBinding(self: RecoveryEffects) DurableCommit {
        return self.commit_binding_fn(self.context);
    }
};

pub const RecoverySync = struct {
    changed: bool = false,
    durable_changed: bool = false,
    mcp_refresh_needed: bool = false,
};

pub const LifecycleEffects = struct {
    max_title_bytes: usize,
    text: TextProjection,
    recovery: RecoveryEffects,
    release: ReleaseEffects,
    checkpoint: CheckpointEffects,
};

pub const ProjectionAuthorityQuery = struct {
    task_id: u64,
    workspace_id: u64,
    workspace_epoch: u64,
    workspace_root: []const u8,
    execution_generation: u64,
    execution_protocol: task_state.Protocol,
    execution_model: []const u8,
    runtime_attached: bool,
};

pub const ProjectionAuthority = struct {
    shutting_down: bool,
    task_persistence_ready: bool,
    checkpoint_store_ready: bool,
    execution_admission: task_recovery.ExecutionAdmission,
    workspace_identity_exact: bool,
    automatic_owner_exact: bool,
    runtime_admission: task_recovery.RuntimeAdmission,
    authority_stable: bool,
    model_selection_availability: task_view.ModelSelectionAvailability,
};

/// Command admission uses its own typed observation port. It deliberately
/// cannot see projection writers, budgets, visibility or optional capability
/// readiness.
pub const RecoveryAdmissionEffects = struct {
    context: *anyopaque,
    authority_fn: *const fn (*anyopaque, ProjectionAuthorityQuery) ProjectionAuthority,

    fn authority(
        self: RecoveryAdmissionEffects,
        query: ProjectionAuthorityQuery,
    ) ProjectionAuthority {
        return self.authority_fn(self.context, query);
    }
};

pub const ProjectionEffects = struct {
    context: *anyopaque,
    authority_fn: *const fn (*anyopaque, ProjectionAuthorityQuery) ProjectionAuthority,
    text: task_view.TextProjection,
    catalog: task_view.CatalogProjection,
    max_pending_ui_json_bytes: usize,

    fn authority(
        self: ProjectionEffects,
        query: ProjectionAuthorityQuery,
    ) ProjectionAuthority {
        return self.authority_fn(self.context, query);
    }
};

pub const HistoryFrames = struct {
    allocator: std.mem.Allocator,
    tasks: []task_persistence.TaskWire,
    failures: []task_persistence.TaskFailureWire,
    next_task_id: u64,
    next_recent_order: u64,

    pub fn deinit(self: *HistoryFrames) void {
        task_persistence.deinitTaskWires(self.allocator, self.tasks);
        self.allocator.free(self.failures);
        self.* = undefined;
    }
};

const PendingUiContext = struct {
    runtime: *Runtime,
    max_json_bytes: usize,
};

const EventContext = struct {
    runtime: *Runtime,
    effects: EventEffects,
};

pub const RestoreError = task_persistence.RestoreError || error{TaskStoreCorrupt};

pub const FailureRecord = struct {
    task_id: u64,
    recent_order: u64,
    reason: []u8,
};

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    tasks: []?task_state.Task,
    failures: std.ArrayList(FailureRecord) = .empty,
    next_task_id: u64 = 1,
    next_recent_order: u64 = 1,
    next_restore_attempt_id: u64 = 1,
    late_terminal_event_count: u64 = 0,
    recovery_poisoned: bool = false,
    agent_runtime_shutdown_complete: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        capacity: usize,
    ) std.mem.Allocator.Error!Runtime {
        std.debug.assert(capacity != 0);
        const tasks = try allocator.alloc(?task_state.Task, capacity);
        @memset(tasks, null);
        return .{ .allocator = allocator, .tasks = tasks };
    }

    /// Composition must first drain/deinitialize every Task record because
    /// bounded projection allocations remain in the shared root budget.
    pub fn deinitStorage(self: *Runtime) void {
        for (self.tasks) |entry| std.debug.assert(entry == null);
        self.allocator.free(self.tasks);
        for (self.failures.items) |failure| self.allocator.free(failure.reason);
        self.failures.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn find(self: *Runtime, task_id: u64) ?*task_state.Task {
        if (task_id == 0) return null;
        for (self.tasks) |*entry| {
            const task = &(entry.* orelse continue);
            if (task.durable.id == task_id) return task;
        }
        return null;
    }

    pub fn findConst(self: *const Runtime, task_id: u64) ?*const task_state.Task {
        if (task_id == 0) return null;
        for (self.tasks) |*entry| {
            const task = &(entry.* orelse continue);
            if (task.durable.id == task_id) return task;
        }
        return null;
    }

    fn findByRouteId(self: *Runtime, route_id: u64) ?*task_state.Task {
        if (route_id == 0) return null;
        for (self.tasks) |*entry| {
            const task = &(entry.* orelse continue);
            if (task.runtime.routeId() == route_id) return task;
        }
        return null;
    }

    pub fn emptyIndex(self: *const Runtime) ?usize {
        for (self.tasks, 0..) |entry, index| if (entry == null) return index;
        return null;
    }

    pub fn findIndex(self: *const Runtime, task_id: u64) ?usize {
        if (task_id == 0) return null;
        for (self.tasks, 0..) |entry, index|
            if (entry) |task| if (task.durable.id == task_id) return index;
        return null;
    }

    pub fn hasCapacity(self: *const Runtime) bool {
        return self.emptyIndex() != null;
    }

    pub fn openTask(
        self: *Runtime,
        input: CreateTaskInput,
    ) CreateTaskError!PreparedCreate {
        const execution_model = (try input.text.project(
            input.model,
            input.max_model_id_bytes,
            &.{},
            0,
        )).value;
        var model_live = true;
        errdefer if (model_live) input.text.discardCandidate(execution_model);
        const projected_workspace = try input.text.project(
            input.workspace_root,
            input.max_workspace_bytes,
            input.execution.api_key,
            0,
        );
        var workspace_live = true;
        errdefer if (workspace_live)
            input.text.discardCandidate(projected_workspace.value);
        const title = (try input.text.project(
            "",
            input.max_title_bytes,
            &.{},
            0,
        )).value;
        var title_live = true;
        errdefer if (title_live) input.text.discardCandidate(title);
        var execution = try owned_task_execution.OwnedTaskExecution.clone(
            self.allocator,
            input.execution,
        );
        errdefer execution.deinit();
        var epoch_storage: [32]u8 = undefined;
        const epoch_token = std.fmt.bufPrint(
            &epoch_storage,
            "{d}",
            .{input.workspace_epoch},
        ) catch unreachable;
        const permission = agentSessionPermission(
            input.permission_profile,
            input.permission_interaction,
        );
        var binding = try task_agent_session.Binding.open(input.agent_runtime, .{
            .model_binding = .{
                .target = .{
                    .provider_id = input.execution.target.provider_id,
                    .protocol = agent_protocol.toAgent(input.execution.target.protocol),
                    .base_url = input.execution.target.base_url,
                    .model = input.model,
                },
                .credential = input.execution.api_key,
            },
            .permission_mode = permission.mode,
            .shell_policy = permission.shell,
            .permission_interaction = permission.interaction,
            .workspace = .{
                .canonical_root = input.workspace_root,
                .trust = switch (input.workspace_trust) {
                    .explicitly_trusted => .explicitly_trusted,
                    .temporary => |root| .{ .temporary = root },
                },
            },
            .canonical_user_home = input.canonical_user_home,
            .workspace_epoch = if (input.canonical_user_home.len != 0)
                epoch_token
            else
                "",
            .skill_catalog = input.skill_catalog,
            .skill_policy = if (input.skill_catalog != null) .{
                .granted_skill_ids = input.granted_skill_ids,
            } else null,
            .mcp_selection = input.mcp_selection,
        });
        var pinned: ?product_skill.catalog.Snapshot = input.pinned_catalog.*;
        input.pinned_catalog.* = null;
        var candidate = CreateCandidate{
            .execution_generation = input.execution.execution_generation,
            .execution_protocol = input.protocol,
            .execution_model = execution_model,
            .permission_profile = input.permission_profile,
            .permission_interaction = input.permission_interaction,
            .workspace_id = input.workspace_id,
            .workspace_epoch = input.workspace_epoch,
            .workspace_root = projected_workspace.value,
            .title = title,
            .binding = binding.take(),
            .execution = execution.take(),
            .pinned_catalog = pinned,
            .mcp_authority = input.mcp_authority,
        };
        model_live = false;
        workspace_live = false;
        title_live = false;
        pinned = null;
        input.workspace_order.apply();
        const result = self.create(
            &candidate,
            input.max_runs,
            input.max_compacts,
            input.max_ui_history,
            input.release,
        ) catch |err| {
            input.workspace_order.rollback();
            return err;
        };
        return result;
    }

    /// Takes every owned field in `candidate` on entry. Failure closes the
    /// fresh Session and releases all candidate resources; success publishes a
    /// fully formed Task as a prepared candidate for the composition-owned
    /// durable decision.
    pub fn create(
        self: *Runtime,
        candidate: *CreateCandidate,
        max_runs: usize,
        max_compacts: usize,
        max_ui_history: usize,
        release: ReleaseEffects,
    ) CreateError!PreparedCreate {
        var owned = candidate.*;
        candidate.* = undefined;
        var owned_live = true;
        errdefer if (owned_live) deinitCreateCandidate(self, &owned, release);
        const slot = self.emptyIndex() orelse return error.TaskCapacity;
        const runs = try self.allocator.alloc(?task_state.RunRecord, max_runs);
        var runs_owned = true;
        errdefer if (runs_owned) self.allocator.free(runs);
        @memset(runs, null);
        const compacts = try self.allocator.alloc(?task_state.CompactRecord, max_compacts);
        var compacts_owned = true;
        errdefer if (compacts_owned) self.allocator.free(compacts);
        @memset(compacts, null);
        const ui_history = try self.allocator.alloc(?task_state.UiRecord, max_ui_history);
        var ui_history_owned = true;
        errdefer if (ui_history_owned) self.allocator.free(ui_history);
        @memset(ui_history, null);
        const task_id = try self.takeTaskId();
        const previous_next_recent_order = self.next_recent_order;
        self.tasks[slot] = .{
            .durable = .{
                .id = task_id,
                .recent_order = self.takeRecentOrder(),
                .execution_generation = owned.execution_generation,
                .execution_protocol = owned.execution_protocol,
                .execution_model = owned.execution_model,
                .permission_profile = owned.permission_profile,
                .permission_interaction = owned.permission_interaction,
                .workspace_id = owned.workspace_id,
                .workspace_epoch = owned.workspace_epoch,
                .workspace_root = owned.workspace_root,
                .title = owned.title,
                .runs = runs,
                .compacts = compacts,
                .ui_history = ui_history,
            },
            .runtime = .{
                .mcp_authority_at_creation = owned.mcp_authority,
                .attachment = .{ .attached = .{
                    .binding = owned.binding.take(),
                    .execution = owned.execution.take(),
                    .pinned_catalog = owned.pinned_catalog,
                } },
            },
        };
        runs_owned = false;
        compacts_owned = false;
        ui_history_owned = false;
        owned_live = false;
        owned = undefined;
        return .{
            .runtime = self,
            .slot = slot,
            .task_id = task_id,
            .previous_next_recent_order = previous_next_recent_order,
            .release = release,
        };
    }

    pub fn startRun(
        self: *Runtime,
        task_id: u64,
        expected_binding_epoch: u64,
        input: RunInput,
        workspace: WorkspaceOrderEffect,
        effects: OperationEffects,
    ) RunError!PreparedRun {
        const task = self.find(task_id) orelse return error.UnknownTask;
        if (expected_binding_epoch == 0 or
            expected_binding_epoch != task.durable.binding_epoch)
            return error.BindingEpochMismatch;
        const execution = try taskExecutionInput(task);
        if (task_policy.hasActiveOperation(task) or
            checkpointMutationPending(task, effects.worker.checkpoint.store_health))
            return error.TaskBusy;
        var access = task.runtime.acquireAccess() catch return error.TaskClosing;
        var access_live = true;
        errdefer if (access_live) access.deinit();
        try applyPendingModel(self, task, &access, effects);
        const agent_input = try validateRunInput(task, input, effects.limits);
        const run_id = try access.prepareRun(agent_input);
        var prepared = true;
        errdefer if (prepared)
            task_execution.cancelPreparedRunOrPanic(&access, run_id);
        const slot = try reserveRun(self, task, input, effects);
        var record_owned = true;
        errdefer if (record_owned) discardRun(self, task, slot, effects.release);
        const run_record = &task.durable.runs[slot].?;
        run_record.id = run_id;

        var run_lease = task.runtime.worker_leases.acquire() catch return error.TaskBusy;
        var run_lease_owned = true;
        errdefer if (run_lease_owned) run_lease.deinit();
        var checkpoint_lease = task.runtime.worker_leases.acquire() catch return error.TaskBusy;
        var checkpoint_lease_owned = true;
        errdefer if (checkpoint_lease_owned) checkpoint_lease.deinit();
        const job = try std.heap.c_allocator.create(task_execution.RunJob);
        var job_owned = true;
        errdefer if (job_owned) job.destroy();
        job.* = .{
            .run = run_record,
            .lease = run_lease.take(),
            .checkpoint_lease = checkpoint_lease.take(),
            .notifier = effects.worker.notifier,
            .projector = effects.worker.projector,
            .completion_factory = effects.worker.completion_factory,
            .checkpoint = effects.worker.checkpoint,
        };
        run_lease_owned = false;
        checkpoint_lease_owned = false;
        if (run_record.automatic_title.state.load(.acquire) == .pending) {
            job.title_execution = owned_task_execution.OwnedTaskExecution.clone(
                self.allocator,
                execution,
            ) catch null;
            if (job.title_execution == null)
                run_record.automatic_title.state.store(.ready, .release);
        }
        run_record.checkpoint_export_context = .{
            .task_id = task.durable.id,
            .binding_epoch = task.durable.binding_epoch,
            .terminal_kind = .run,
            .terminal_id = run_id,
            .last_run_id = run_id,
            .last_compact_id = task_policy.latestCompactId(task),
            .model = run_record.execution_model,
        };

        const previous_title = task.durable.title;
        const previous_title_redacted = task.durable.title_redacted;
        const provisional_title_applied = applyProvisionalTitle(
            task,
            run_record,
            effects.limits.max_task_title_bytes,
            effects.text,
            execution.api_key,
        );
        run_record.automatic_title.provisional_applied = provisional_title_applied;
        const previous_active_run_id = task.runtime.active_run_id;
        const previous_active_operation = task.runtime.active_operation;
        const previous_recent_order = task.durable.recent_order;
        const previous_next_recent_order = self.next_recent_order;
        task.runtime.active_run_id = run_id;
        task.runtime.active_operation = .{ .run = run_id };
        task.runtime.cancel_requested = false;
        task.durable.recent_order = self.takeRecentOrder();
        workspace.apply();
        job.access = access.take();
        access_live = false;
        prepared = false;
        job_owned = false;
        record_owned = false;
        return .{
            .runtime = self,
            .task = task,
            .slot = slot,
            .run_id = run_id,
            .job = job,
            .workspace = workspace,
            .effects = effects,
            .previous_active_run_id = previous_active_run_id,
            .previous_active_operation = previous_active_operation,
            .previous_recent_order = previous_recent_order,
            .previous_next_recent_order = previous_next_recent_order,
            .previous_title = previous_title,
            .previous_title_redacted = previous_title_redacted,
            .provisional_title_applied = provisional_title_applied,
        };
    }

    pub fn startCompact(
        self: *Runtime,
        task_id: u64,
        expected_binding_epoch: u64,
        effects: OperationEffects,
    ) CompactError!PreparedCompact {
        const task = self.find(task_id) orelse return error.UnknownTask;
        if (expected_binding_epoch == 0 or
            expected_binding_epoch != task.durable.binding_epoch)
            return error.BindingEpochMismatch;
        _ = try taskExecutionInput(task);
        if (task_policy.hasActiveOperation(task) or
            checkpointMutationPending(task, effects.worker.checkpoint.store_health) or
            task_state.hasUnfinalizedTerminalEvents(task))
            return error.TaskBusy;
        const slot = findEmptyCompact(task.durable.compacts) orelse
            return error.CompactCapacity;
        const after_run_id = task_policy.lastFinalizedRunId(task) orelse
            return error.NoSuchRun;
        var access = task.runtime.acquireAccess() catch return error.TaskClosing;
        var access_live = true;
        errdefer if (access_live) access.deinit();
        const operation_id = try access.prepareCompact();
        var prepared = true;
        errdefer if (prepared)
            task_execution.cancelPreparedCompactOrPanic(&access, operation_id);
        const diagnostic = try effects.text.allocateCapacity(
            effects.limits.max_terminal_diagnostic_bytes,
        );
        errdefer effects.text.discardCandidate(diagnostic);
        const execution = try taskExecutionInput(task);
        task.durable.compacts[slot] = .{
            .id = operation_id,
            .after_run_id = after_run_id,
            .terminal_diagnostic = diagnostic,
            .redaction_secret = execution.api_key,
        };
        var record_owned = true;
        errdefer if (record_owned)
            discardCompact(self, task, slot, effects.release);
        const compact = &task.durable.compacts[slot].?;
        var compact_lease = task.runtime.worker_leases.acquire() catch return error.TaskBusy;
        var compact_lease_owned = true;
        errdefer if (compact_lease_owned) compact_lease.deinit();
        var checkpoint_lease = task.runtime.worker_leases.acquire() catch return error.TaskBusy;
        var checkpoint_lease_owned = true;
        errdefer if (checkpoint_lease_owned) checkpoint_lease.deinit();
        const job = try std.heap.c_allocator.create(task_execution.CompactJob);
        var job_owned = true;
        errdefer if (job_owned) job.destroy();
        job.* = .{
            .compact = compact,
            .lease = compact_lease.take(),
            .checkpoint_lease = checkpoint_lease.take(),
            .notifier = effects.worker.notifier,
            .projector = effects.worker.projector,
            .checkpoint = effects.worker.checkpoint,
        };
        compact_lease_owned = false;
        checkpoint_lease_owned = false;
        compact.checkpoint_export_context = .{
            .task_id = task.durable.id,
            .binding_epoch = task.durable.binding_epoch,
            .terminal_kind = .compact,
            .terminal_id = operation_id,
            .last_run_id = after_run_id,
            .last_compact_id = operation_id,
            .model = task.durable.execution_model,
        };
        const previous_active_operation = task.runtime.active_operation;
        const previous_recent_order = task.durable.recent_order;
        const previous_next_recent_order = self.next_recent_order;
        task.runtime.active_operation = .{ .compact = operation_id };
        task.durable.recent_order = self.takeRecentOrder();
        job.access = access.take();
        access_live = false;
        prepared = false;
        job_owned = false;
        record_owned = false;
        return .{
            .runtime = self,
            .task = task,
            .slot = slot,
            .operation_id = operation_id,
            .job = job,
            .effects = effects,
            .previous_active_operation = previous_active_operation,
            .previous_recent_order = previous_recent_order,
            .previous_next_recent_order = previous_next_recent_order,
        };
    }

    pub fn cancelCompact(
        self: *Runtime,
        task_id: u64,
        operation_id: u64,
        interruption: agent.ExternalInterruption,
        effects: OperationEffects,
    ) ControlError!task_state.CompactTerminationDispatch {
        const task = self.find(task_id) orelse return error.UnknownTask;
        const active_id = switch (task.runtime.active_operation) {
            .compact => |id| id,
            .none, .run, .restore => return error.NoSuchCompact,
        };
        if (operation_id == 0 or operation_id != active_id)
            return error.NoSuchCompact;
        const compact = task_state.findCompact(
            task.durable.compacts,
            operation_id,
        ) orelse return error.NoSuchCompact;
        return cancelCompactRecord(self, task, compact, interruption, effects);
    }

    pub fn cancelRun(
        self: *Runtime,
        task_id: u64,
        run_id: u64,
        effects: OperationEffects,
    ) ControlError!bool {
        const task = self.find(task_id) orelse return error.UnknownTask;
        const run_record = task_state.findRun(task.durable.runs, run_id) orelse
            return error.NoSuchRun;
        if (task_state.terminalPayload(run_record) != null) return false;
        var access = task.runtime.acquireAccess() catch return error.TaskClosing;
        defer access.deinit();
        const record = prepareCancelledUiRecord(
            self,
            &access,
            run_id,
            run_record.redaction_secret,
        );
        const dispatch = requestRunTermination(run_record, .user_cancel);
        if (effects.executor.cancel(run_record)) {
            run_record.terminal_observed = true;
            if (record) |value| pushUiRecord(task, value);
            task.runtime.cancel_requested = false;
            task.durable.recent_order = self.takeRecentOrder();
            return true;
        }
        const stopping = switch (dispatch) {
            .pending, .requested, .already_requested => true,
            .already_finishing, .already_terminal, .stale_run, .session_closing => false,
        };
        if (!stopping) return false;
        if (record) |value| pushUiRecord(task, value);
        task.runtime.cancel_requested = true;
        _ = task_state.setActivePhase(run_record, .stopping);
        task.durable.recent_order = self.takeRecentOrder();
        return true;
    }

    pub fn respondUi(
        self: *Runtime,
        task_id: u64,
        run_id: u64,
        request_id: u64,
        response: UiResponse,
    ) ControlError!PreparedUiResponse {
        const task = self.find(task_id) orelse return error.UnknownTask;
        const run_record = task_state.findRun(task.durable.runs, run_id) orelse
            return error.NoSuchRun;
        var access = task.runtime.acquireAccess() catch return error.TaskClosing;
        const record = prepareUiRecord(
            self,
            &access,
            run_id,
            request_id,
            response,
            run_record.redaction_secret,
        );
        const history_slot = task.durable.ui_history_next;
        const previous_history_record = task.durable.ui_history[history_slot];
        const previous_history_next = task.durable.ui_history_next;
        const previous_history_count = task.durable.ui_history_count;
        const previous_pending_request_id = task.runtime.pending_ui_request_id;
        const previous_pending_order = task.runtime.pending_ui_order;
        const previous_activity_order = run_record.next_activity_order;
        const previous_recent_order = task.durable.recent_order;
        const previous_next_recent_order = self.next_recent_order;
        pushUiRecord(task, record);
        task.durable.recent_order = self.takeRecentOrder();
        return .{
            .runtime = self,
            .task = task,
            .run = run_record,
            .access = access.take(),
            .run_id = run_id,
            .request_id = request_id,
            .response = response,
            .history_slot = history_slot,
            .previous_history_record = previous_history_record,
            .previous_history_next = previous_history_next,
            .previous_history_count = previous_history_count,
            .previous_pending_request_id = previous_pending_request_id,
            .previous_pending_order = previous_pending_order,
            .previous_activity_order = previous_activity_order,
            .previous_recent_order = previous_recent_order,
            .previous_next_recent_order = previous_next_recent_order,
        };
    }

    pub fn selectModel(
        self: *Runtime,
        task_id: u64,
        expected_model: []const u8,
        model: []const u8,
        checkpoint_health: *const std.atomic.Value(checkpoint_store.Health),
        text: TextProjection,
        max_model_id_bytes: usize,
    ) ModelError!bool {
        const task = self.find(task_id) orelse return error.UnknownTask;
        if (!std.mem.eql(u8, expected_model, task.durable.execution_model))
            return error.TaskModelMismatch;
        if (task_policy.hasActiveOperation(task)) {
            const replacement = try self.allocator.dupe(u8, model);
            if (task.runtime.pending_model) |old| self.allocator.free(old);
            task.runtime.pending_model = replacement;
            return true;
        }
        if (checkpointMutationPending(task, checkpoint_health))
            return error.TaskBusy;
        var access = task.runtime.acquireAccess() catch return error.TaskClosing;
        defer access.deinit();
        try access.setModel(model);
        const previous = task.durable.execution_model;
        const projected = text.project(
            model,
            max_model_id_bytes,
            &.{},
            previous.len,
        ) catch |err| {
            access.setModel(expected_model) catch {
                poisonAttachment(task);
                return error.TaskClosing;
            };
            return err;
        };
        task.durable.execution_model = projected.value;
        text.discardPrevious(previous);
        return true;
    }

    pub fn beginDetach(
        self: *Runtime,
        task_id: u64,
        effects: OperationEffects,
    ) CloseError!bool {
        const task = self.find(task_id) orelse return error.UnknownTask;
        if (!task_policy.hasActiveOperation(task) and
            checkpointMutationPending(task, effects.worker.checkpoint.store_health))
        {
            cancelTaskCheckpoints(task);
            return error.TaskBusy;
        }
        if (task.runtime.close_thread != null) return error.CloseInProgress;
        const retrying = task.runtime.close_failed and
            task.runtime.hasClosingSession();
        if (task.runtime.live() == null) return false;
        const prior_health = if (task.runtime.attached()) |attached|
            attached.health
        else
            task_attachment.AttachedHealth.available;
        if (task.runtime.active_operation == .compact) {
            const compact_id = switch (task.runtime.active_operation) {
                .compact => |id| id,
                else => unreachable,
            };
            const compact = task_state.findCompact(
                task.durable.compacts,
                compact_id,
            ) orelse return error.NoSuchCompact;
            _ = try cancelCompactRecord(
                self,
                task,
                compact,
                .session_close,
                effects,
            );
        }
        var observation_access = task.runtime.acquireAccess() catch null;
        defer if (observation_access) |*access| access.deinit();
        const cancelled_ui = if (task.runtime.pending_ui_request_id != 0 and
            observation_access != null)
            prepareCancelledUiRecord(
                self,
                &observation_access.?,
                task.runtime.active_run_id,
                if (task_state.findRun(
                    task.durable.runs,
                    task.runtime.active_run_id,
                )) |run_record|
                    run_record.redaction_secret
                else if (task.runtime.execution()) |execution|
                    execution.input().api_key
                else
                    &.{},
            )
        else
            null;
        if (task_state.findRun(
            task.durable.runs,
            task.runtime.active_run_id,
        )) |run_record| {
            const dispatch = requestRunTermination(run_record, .session_close);
            if (effects.executor.cancel(run_record)) {
                run_record.terminal_observed = true;
            } else if (dispatch == .stale_run) {
                std.debug.panic(
                    "active Task Run {d} published a stale RunControl",
                    .{run_record.id},
                );
            }
        }
        if (!retrying) std.debug.assert(task.runtime.beginClosing());
        const binding = task.runtime.closingWorkerBinding() orelse unreachable;
        task.runtime.cancel_requested = task.runtime.active_operation == .run;
        if (task_state.findRun(
            task.durable.runs,
            task.runtime.active_run_id,
        )) |run_record| {
            if (!task_state.isTerminalPhase(task_state.runPhase(run_record)))
                _ = task_state.setActivePhase(run_record, .stopping);
        }
        task.runtime.close_failed = false;
        task.runtime.close_completion.store(.running, .release);
        task.runtime.close_thread = std.Thread.spawn(.{}, closeWorker, .{
            &task.runtime.close_completion,
            binding,
            effects.worker.notifier,
        }) catch |err| {
            task.runtime.close_completion.store(.none, .release);
            if (retrying)
                task.runtime.close_failed = true
            else
                task.runtime.restoreCloseFailure(prior_health);
            return err;
        };
        if (cancelled_ui) |record| pushUiRecord(task, record);
        task.durable.recent_order = self.takeRecentOrder();
        return true;
    }

    pub fn taskWorkspaceId(self: *const Runtime, task_id: u64) ?u64 {
        const task = self.findConst(task_id) orelse return null;
        return task.durable.workspace_id;
    }

    pub fn taskPermissionProfile(
        self: *const Runtime,
        task_id: u64,
    ) ?task_state.PermissionProfile {
        const task = self.findConst(task_id) orelse return null;
        return task.durable.permission_profile;
    }

    pub fn taskPermissionInteraction(
        self: *const Runtime,
        task_id: u64,
    ) ?task_state.PermissionInteraction {
        const task = self.findConst(task_id) orelse return null;
        return task.durable.permission_interaction;
    }

    pub fn taskWorkspaceEpoch(self: *const Runtime, task_id: u64) ?u64 {
        const task = self.findConst(task_id) orelse return null;
        return task.durable.workspace_epoch;
    }

    pub fn taskCountInWorkspace(self: *const Runtime, workspace_id: u64) usize {
        var count: usize = 0;
        for (self.tasks) |entry| if (entry) |task|
            if (task.durable.workspace_id == workspace_id) {
                count += 1;
            };
        return count;
    }

    pub fn taskBindingEpoch(self: *const Runtime, task_id: u64) ?u64 {
        const task = self.findConst(task_id) orelse return null;
        return task.durable.binding_epoch;
    }

    pub fn taskMcpAuthority(
        self: *const Runtime,
        task_id: u64,
    ) ?task_attachment.McpAuthorityAtCreation {
        const task = self.findConst(task_id) orelse return null;
        return task.runtime.mcp_authority_at_creation;
    }

    pub fn taskExecutionIdentity(
        self: *const Runtime,
        task_id: u64,
    ) ?ExecutionIdentity {
        const task = self.findConst(task_id) orelse return null;
        return .{
            .generation = task.durable.execution_generation,
            .protocol = task.durable.execution_protocol,
            .model = task.durable.execution_model,
        };
    }

    pub fn runExecutionIdentity(
        self: *const Runtime,
        task_id: u64,
        run_id: u64,
    ) ?ExecutionIdentity {
        const task = self.findConst(task_id) orelse return null;
        const run = task_state.findRun(task.durable.runs, run_id) orelse return null;
        return .{
            .generation = run.execution_generation,
            .protocol = run.execution_protocol,
            .model = run.execution_model,
        };
    }

    pub fn fileReference(
        self: *const Runtime,
        task_id: u64,
        run_id: u64,
        reference_id: []const u8,
    ) ?FileReference {
        const task = self.findConst(task_id) orelse return null;
        const run = task_state.findRun(task.durable.runs, run_id) orelse return null;
        for (run.tools) |*tool_entry| {
            const tool = &(tool_entry.* orelse continue);
            const references = tool.file_refs orelse continue;
            for (references) |reference_entry| {
                const reference = reference_entry orelse continue;
                if (!std.mem.eql(u8, reference.id, reference_id)) continue;
                return .{
                    .workspace_id = task.durable.workspace_id,
                    .workspace_epoch = task.durable.workspace_epoch,
                    .workspace_root = task.durable.workspace_root,
                    .id = reference.id,
                    .title = reference.title,
                    .display_path = reference.display_path,
                    .kind = reference.kind,
                    .locator_kind = switch (reference.locator_kind) {
                        .workspace_path => .workspace_path,
                        .absolute_path => .absolute_path,
                        .uri => .uri,
                    },
                    .locator = reference.locator,
                    .range = if (reference.range) |range| .{
                        .start = .{ .line = range.start.line, .column = range.start.column },
                        .end = .{ .line = range.end.line, .column = range.end.column },
                    } else null,
                };
            }
        }
        return null;
    }

    pub fn catalogProjection(
        self: *const Runtime,
        task_id: u64,
    ) ?product_skill.catalog.CatalogProjection {
        const task = self.findConst(task_id) orelse return null;
        return task_view.catalogProjection(task);
    }

    pub fn catalogRefreshFacts(
        self: *const Runtime,
        task_id: u64,
        expected_binding_epoch: u64,
    ) CatalogRefreshError!CatalogRefreshFacts {
        const task = self.findConst(task_id) orelse return error.UnknownTask;
        if (task.durable.binding_epoch != expected_binding_epoch)
            return error.BindingEpochMismatch;
        if (task_policy.taskLifecycle(task) != .open or
            task_policy.hasActiveOperation(task))
            return error.TaskBusy;
        return .{
            .workspace_id = task.durable.workspace_id,
            .workspace_epoch = task.durable.workspace_epoch,
        };
    }

    /// On success takes `replacement`; on failure the caller retains it.
    pub fn installCatalogRefresh(
        self: *Runtime,
        task_id: u64,
        expected_binding_epoch: u64,
        lease: *agent.CatalogLease,
        granted_skill_ids: []const []const u8,
        replacement: *product_skill.catalog.Snapshot,
    ) (CatalogRefreshError || agent.Error || std.mem.Allocator.Error)!usize {
        const task = self.find(task_id) orelse return error.UnknownTask;
        if (task.durable.binding_epoch != expected_binding_epoch)
            return error.BindingEpochMismatch;
        if (task_policy.taskLifecycle(task) != .open or
            task_policy.hasActiveOperation(task))
            return error.TaskBusy;
        var access = task.runtime.acquireAccess() catch return error.TaskClosing;
        defer access.deinit();
        try access.refreshSkillCatalog(lease, .{
            .granted_skill_ids = granted_skill_ids,
        });
        const old_bytes = if (task.runtime.pinnedCatalog()) |old| old.projected_bytes else 0;
        if (task.runtime.pinnedCatalog()) |old| old.deinit();
        task.runtime.attached().?.pinned_catalog = replacement.*;
        replacement.* = undefined;
        return old_bytes;
    }

    pub fn renameTask(
        self: *Runtime,
        task_id: u64,
        title: []const u8,
        max_title_bytes: usize,
        text: TextProjection,
    ) MutationError!void {
        const task = self.find(task_id) orelse return error.UnknownTask;
        if (task.deletion == .deleting) return error.TaskBusy;
        const trimmed = std.mem.trim(u8, title, " \t\r\n");
        if (trimmed.len == 0 or trimmed.len > max_title_bytes or
            !std.unicode.utf8ValidateSlice(trimmed))
            return error.InvalidTaskTitle;
        for (trimmed) |byte| if (byte < 0x20) return error.InvalidTaskTitle;

        const sensitive = if (task.runtime.execution()) |execution|
            execution.input().api_key
        else
            &.{};
        const previous_title = task.durable.title;
        const projected = try text.project(
            trimmed,
            max_title_bytes,
            sensitive,
            previous_title.len,
        );
        task.durable.title = projected.value;
        task.durable.title_redacted = projected.redacted;
        task.durable.recent_order = self.takeRecentOrder();
        text.discardPrevious(previous_title);
        markAutomaticTitleUserOverride(task);
    }

    pub fn setArchived(
        self: *Runtime,
        task_id: u64,
        archived: bool,
    ) MutationError!bool {
        const task = self.find(task_id) orelse return error.UnknownTask;
        if (task.deletion == .deleting or
            task_policy.taskLifecycle(task) == .closing or
            task_policy.hasActiveOperation(task))
            return error.TaskBusy;
        if (task.durable.archived == archived) return false;
        task.durable.archived = archived;
        if (!archived and task.deletion == .failed) task.deletion = .idle;
        task.durable.recent_order = self.takeRecentOrder();
        return true;
    }

    pub fn requestDeletion(self: *Runtime, task_id: u64) DeletionError!bool {
        const task = self.find(task_id) orelse return error.UnknownTask;
        if (!task.durable.archived) return error.TaskNotArchived;
        if (task.deletion == .deleting) return false;
        task.deletion = .deleting;
        return true;
    }

    /// Advances accepted Task deletion intents. The Runtime owns the state
    /// machine and removes the Task candidate before the shared history commit;
    /// composition may remove an automatic Workspace in that same callback.
    pub fn syncDeletions(
        self: *Runtime,
        checkpoint_store_available: bool,
        effects: DeletionEffects,
    ) DeletionSync {
        var result: DeletionSync = .{};
        for (self.tasks) |*entry| {
            const task = &(entry.* orelse continue);
            if (task.deletion != .deleting) continue;
            const session: task_deletion.Session = if (task.runtime.hasAttachedSession())
                .attached
            else if (task.runtime.hasClosingSession())
                if (task.runtime.close_failed) .retryable_close_failure else .closing
            else
                .detached;
            const decision = task_deletion.decide(task.deletion, .{
                .checkpoint_pending = checkpoint_store_available and
                    task.runtime.worker_leases.hasLive(),
                .close_operation_running = task.runtime.close_completion.load(.acquire) == .running or
                    task.runtime.close_thread != null,
                .unfinalized_terminal_events = task_state.hasUnfinalizedTerminalEvents(task),
                .session = session,
                .has_live_workers = task.runtime.worker_leases.hasLive(),
            });
            switch (decision) {
                .wait => {},
                .cancel_checkpoint => cancelTaskCheckpoints(task),
                .release_session => switch (effects.releaseSession(task.durable.id)) {
                    .unchanged, .started => result.changed = true,
                    .failed => {
                        task.deletion = .failed;
                        result.changed = true;
                        result.failed_task_id = task.durable.id;
                    },
                },
                .commit_record_deletion => {
                    const task_id = task.durable.id;
                    const workspace_id = task.durable.workspace_id;
                    var removed = task.*;
                    entry.* = null;
                    switch (effects.commitWithoutTask(workspace_id)) {
                        .committed => {
                            effects.deleteCheckpointTask(task_id);
                            effects.deleteFileChangeTask(task_id);
                            deinitTask(self, &removed, effects.release);
                            result.changed = true;
                        },
                        .failed => {
                            entry.* = removed;
                            entry.*.?.deletion = .failed;
                            result.changed = true;
                            result.failed_task_id = task_id;
                            result.failed_commit = .failed;
                        },
                        .outcome_unknown => {
                            entry.* = removed;
                            entry.*.?.deletion = .failed;
                            result.changed = true;
                            result.failed_task_id = task_id;
                            result.failed_commit = .outcome_unknown;
                        },
                    }
                },
            }
        }
        return result;
    }

    pub fn workspaceHasTasks(self: *const Runtime, workspace_id: u64) bool {
        for (self.tasks) |entry| if (entry) |task|
            if (task.durable.workspace_id == workspace_id) return true;
        return false;
    }

    pub fn releaseWorkspaceSessions(
        self: *Runtime,
        workspace_id: u64,
        effect: SessionReleaseEffect,
    ) bool {
        for (self.tasks) |*entry| {
            const task = &(entry.* orelse continue);
            if (task.durable.workspace_id != workspace_id or
                !task.runtime.hasAttachedSession()) continue;
            if (effect.release(task.durable.id) == .failed) return false;
        }
        return true;
    }

    pub fn hasActiveOperation(self: *const Runtime, workspace_id: ?u64) bool {
        for (self.tasks) |entry| {
            const task = entry orelse continue;
            if (workspace_id) |expected|
                if (task.durable.workspace_id != expected) continue;
            if (task_policy.hasActiveOperation(&task)) return true;
        }
        return false;
    }

    pub fn taskHasActiveOperation(self: *const Runtime, task_id: u64) bool {
        const task = self.findConst(task_id) orelse return false;
        return task_policy.hasActiveOperation(task);
    }

    pub fn lastTerminalSummary(self: *const Runtime, task_id: u64) ?TerminalSummary {
        const task = self.findConst(task_id) orelse return null;
        const terminal = task_policy.lastTerminalFacts(task.durable.runs) orelse return null;
        return .{
            .outcome = terminal.outcome,
            .permission_required = terminal.cause == .permission_required,
        };
    }

    pub fn workspaceRemovalState(
        self: *const Runtime,
        workspace_id: u64,
    ) WorkspaceRemovalState {
        var pending = false;
        for (self.tasks) |*entry| {
            const task = &(entry.* orelse continue);
            if (task.durable.workspace_id != workspace_id) continue;
            if (task.runtime.close_failed) return .close_failed;
            if (task.runtime.hasAttachedSession() or
                task.runtime.hasClosingSession() or
                task.runtime.close_thread != null or
                task.runtime.worker_leases.hasLive() or
                task_policy.hasActiveOperation(task))
                pending = true;
        }
        return if (pending) .pending else .ready;
    }

    pub fn workspaceSignals(
        self: *const Runtime,
        workspace_id: u64,
    ) WorkspaceSignals {
        var signals: WorkspaceSignals = .{};
        for (self.tasks) |*entry| {
            const task = &(entry.* orelse continue);
            if (task.durable.workspace_id != workspace_id or task.durable.archived) continue;
            if (task_policy.currentRunPhase(task)) |phase| {
                switch (phase) {
                    .waiting_ui => signals.attention +|= 1,
                    .queued, .running, .stopping => signals.running +|= 1,
                    else => unreachable,
                }
                continue;
            }
            if (switch (task.runtime.active_operation) {
                .compact => true,
                .none, .run, .restore => false,
            }) {
                signals.running +|= 1;
                continue;
            }
            if (task_policy.lastTerminalFacts(task.durable.runs)) |terminal| switch (terminal.outcome) {
                .failed, .interrupted, .dependency_contract_failure => signals.failed_or_interrupted +|= 1,
                .completed, .stopped, .cancelled => {},
            };
        }
        return signals;
    }

    pub fn projectHistory(
        self: *Runtime,
        checkpoint_override: ?task_persistence.CheckpointPersistenceOverride,
    ) (std.mem.Allocator.Error || error{ProjectionCapacity})!HistoryFrames {
        var task_count: usize = 0;
        for (self.tasks) |entry| if (entry != null) {
            task_count += 1;
        };
        const tasks = try self.allocator.alloc(task_persistence.TaskWire, task_count);
        errdefer self.allocator.free(tasks);
        var task_index: usize = 0;
        errdefer task_persistence.deinitTaskWires(self.allocator, tasks[0..task_index]);
        for (self.tasks) |*entry| {
            const task = &(entry.* orelse continue);
            tasks[task_index] = try task_persistence.projectTask(
                self.allocator,
                task,
                checkpoint_override,
            );
            task_index += 1;
        }
        const failures = try self.allocator.alloc(
            task_persistence.TaskFailureWire,
            self.failures.items.len,
        );
        for (self.failures.items, failures) |failure, *target| target.* = .{
            .task_id = failure.task_id,
            .recent_order = failure.recent_order,
            .reason = failure.reason,
        };
        return .{
            .allocator = self.allocator,
            .tasks = tasks,
            .failures = failures,
            .next_task_id = self.next_task_id,
            .next_recent_order = self.next_recent_order,
        };
    }

    pub fn recordFailure(
        self: *Runtime,
        task_id: u64,
        recent_order: u64,
        reason: []const u8,
    ) (std.mem.Allocator.Error || error{TaskStoreCorrupt})!void {
        if (task_id == 0 or reason.len == 0 or
            reason.len > task_persistence.max_failure_reason_bytes)
            return error.TaskStoreCorrupt;
        for (self.failures.items) |failure|
            if (failure.task_id == task_id and std.mem.eql(u8, failure.reason, reason))
                return;
        const owned_reason = try self.allocator.dupe(u8, reason);
        errdefer self.allocator.free(owned_reason);
        try self.failures.append(self.allocator, .{
            .task_id = task_id,
            .recent_order = recent_order,
            .reason = owned_reason,
        });
    }

    pub fn restoreTasks(
        self: *Runtime,
        wires: []const task_persistence.TaskWire,
        projection: task_persistence.RestoreProjection,
    ) RestoreError!usize {
        for (self.tasks) |entry| std.debug.assert(entry == null);
        var restored_count: usize = 0;
        var dropped: usize = 0;
        for (wires) |wire| {
            const restored = task_persistence.restoreTask(projection, wire) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    dropped += 1;
                    try self.recordFailure(wire.id, wire.recent_order, "task_restore");
                    continue;
                },
            };
            std.debug.assert(restored_count < self.tasks.len);
            self.tasks[restored_count] = restored;
            restored_count += 1;
        }
        return dropped;
    }

    pub fn restoreIdentityState(
        self: *Runtime,
        next_task_id: u64,
        next_recent_order: u64,
    ) void {
        self.next_task_id = next_task_id;
        self.next_recent_order = next_recent_order;
    }

    pub fn takeRecentOrder(self: *Runtime) u64 {
        const result = self.next_recent_order;
        if (self.next_recent_order != std.math.maxInt(u64))
            self.next_recent_order += 1;
        return result;
    }

    fn takeTaskId(self: *Runtime) error{TaskIdentityExhausted}!u64 {
        if (self.next_task_id == 0 or
            self.next_task_id == std.math.maxInt(u64))
            return error.TaskIdentityExhausted;
        const result = self.next_task_id;
        self.next_task_id += 1;
        return result;
    }

    pub fn noteLateTerminal(self: *Runtime) u64 {
        self.late_terminal_event_count +|= 1;
        return self.late_terminal_event_count;
    }

    pub fn applyEvent(
        self: *Runtime,
        envelope: *const agent.OwnedCoreEvent,
        effects: EventEffects,
    ) (task_state.EventApplyError || error{UnknownTask})!EventOutcome {
        const task = self.findByRouteId(envelope.session_id) orelse
            return error.UnknownTask;
        var context = EventContext{ .runtime = self, .effects = effects };
        const projection = EventProjection{
            .context = &context,
            .max_assistant_message_bytes = effects.max_assistant_message_bytes,
            .max_commentary_segments_per_run = effects.max_commentary_segments_per_run,
            .max_tool_field_bytes = effects.max_tool_field_bytes,
            .append_assistant_fn = appendEventAssistant,
            .append_group_fn = appendEventGroup,
            .replace_text_fn = replaceEventText,
            .find_or_create_tool_fn = findOrCreateEventTool,
            .replace_file_references_fn = replaceEventFileReferences,
            .record_file_changes_fn = recordEventFileChanges,
        };
        return switch (try task_state.applyEvent(task, envelope, projection)) {
            .unknown => .unknown,
            .unchanged => .unchanged,
            .late_terminal => .{ .late_terminal = .{
                .task_id = task.durable.id,
                .count = self.noteLateTerminal(),
            } },
            .applied => |application| .{ .applied = .{
                .durable_boundary = application.durable_boundary,
            } },
        };
    }

    pub fn completeFileChangeArtifact(
        self: *Runtime,
        task_id: u64,
        run_generation: u64,
        change_order: u64,
        identity: ?task_state.FileChangeArtifact,
        redacted: bool,
    ) bool {
        const task = self.find(task_id) orelse return false;
        var run: ?*task_state.RunRecord = null;
        for (task.durable.runs) |*entry| {
            const candidate = &(entry.* orelse continue);
            if (candidate.generation == run_generation) {
                run = candidate;
                break;
            }
        }
        const target_run = run orelse return false;
        var target: ?*task_state.FileChangeView = null;
        for (target_run.file_changes) |*entry| {
            const change = &(entry.* orelse continue);
            if (change.order == change_order) {
                target = change;
                break;
            }
        }
        if (target_run.pending_file_change_artifacts == 0) return false;
        target_run.pending_file_change_artifacts -= 1;
        const change = target orelse {
            _ = markFileChangesIncomplete(target_run);
            return true;
        };
        if (identity) |artifact| {
            if (artifact.run_generation == run_generation and
                artifact.change_order == change_order)
                change.artifact = artifact
            else
                _ = markFileChangesIncomplete(target_run);
        } else _ = markFileChangesIncomplete(target_run);
        change.redacted = change.redacted or redacted;
        if (target_run.event_stream_finalized and
            target_run.pending_file_change_artifacts == 0 and
            target_run.file_change_observation == .collecting)
        {
            const terminal = task_state.terminalPayload(target_run).?;
            target_run.file_change_observation = if (terminal.phase == .completed and !target_run.file_changes_known_loss) .complete else .incomplete;
        }
        task.durable.recent_order = self.takeRecentOrder();
        return true;
    }

    pub fn fileChangeArtifact(
        self: *const Runtime,
        task_id: u64,
        run_id: u64,
        file_change_id: []const u8,
    ) ?FileChangeArtifactReference {
        const task = self.findConst(task_id) orelse return null;
        var run: ?*const task_state.RunRecord = null;
        for (task.durable.runs) |*entry| {
            const candidate = &(entry.* orelse continue);
            if (candidate.id == run_id) {
                run = candidate;
                break;
            }
        }
        const target_run = run orelse return null;
        for (target_run.file_changes) |entry| {
            const change = entry orelse continue;
            if (!std.mem.eql(u8, change.id, file_change_id)) continue;
            return .{
                .artifact = change.artifact orelse return null,
                .diff_complete = change.diff_complete,
                .redacted = change.redacted,
            };
        }
        return null;
    }

    pub fn ownsFileChangeArtifact(
        self: *const Runtime,
        identity: task_state.FileChangeArtifact,
        task_id: u64,
    ) bool {
        const task = self.findConst(task_id) orelse return false;
        for (task.durable.runs) |*entry| {
            const run = &(entry.* orelse continue);
            if (run.generation != identity.run_generation) continue;
            for (run.file_changes) |change_entry| {
                const change = change_entry orelse continue;
                if (change.order != identity.change_order) continue;
                const artifact = change.artifact orelse return false;
                return artifact.run_generation == identity.run_generation and
                    artifact.change_order == identity.change_order and
                    artifact.byte_size == identity.byte_size and
                    std.mem.eql(u8, &artifact.digest, &identity.digest);
            }
            return false;
        }
        return false;
    }

    pub fn recordEventProjectionFailure(
        self: *Runtime,
        route_id: u64,
        run_id: u64,
    ) bool {
        const task = self.findByRouteId(route_id) orelse return false;
        const run = task_state.findRun(task.durable.runs, run_id) orelse return false;
        if (!task_state.recordEventProjectionFailure(run)) return false;
        task.durable.recent_order = self.takeRecentOrder();
        return true;
    }

    pub fn recordDependencyContractFailure(
        self: *Runtime,
        route_id: u64,
        run_id: u64,
    ) bool {
        const task = self.findByRouteId(route_id) orelse return false;
        const run = task_state.findRun(task.durable.runs, run_id) orelse return false;
        if (!task_state.recordDependencyContractFailure(run)) return false;
        task.durable.recent_order = self.takeRecentOrder();
        return true;
    }

    pub fn markTerminalRunsBeforeEventDrain(self: *Runtime) bool {
        var changed = false;
        for (self.tasks) |*entry| {
            const task = &(entry.* orelse continue);
            changed = task_state.markTerminalRunsBeforeEventDrain(task) or changed;
        }
        return changed;
    }

    pub fn finalizeMarkedTerminalRunsAfterEventDrain(self: *Runtime) bool {
        var changed = false;
        for (self.tasks) |*entry| {
            const task = &(entry.* orelse continue);
            if (!task_state.finalizeMarkedTerminalRunsAfterEventDrain(task)) continue;
            _ = settleActiveRunTerminal(task);
            task.durable.recent_order = self.takeRecentOrder();
            changed = true;
        }
        return changed;
    }

    /// Settles completed automatic-title jobs against Task-owned title state.
    /// Redaction and shared projection accounting stay in a callback-scoped
    /// projector; the Runtime never retains credential material or the owner.
    pub fn syncAutomaticTitles(
        self: *Runtime,
        max_title_bytes: usize,
        projection: TextProjection,
    ) LifecycleSync {
        var result: LifecycleSync = .{};
        for (self.tasks) |*entry| {
            const task = &(entry.* orelse continue);
            for (task.durable.runs) |*run_entry| {
                const run = &(run_entry.* orelse continue);
                if (run.automatic_title.state.load(.acquire) != .ready) continue;
                result.changed = true;
                const candidate = if (run.automatic_title.generated)
                    task_policy.generatedAutomaticTitleCandidate(
                        run.automatic_title.result[0..run.automatic_title.result_len],
                    )
                else
                    null;
                const selected = candidate orelse
                    task_policy.automaticTitleCandidate(&run.input);
                const may_replace = run.generation == 1 and
                    !run.automatic_title.user_overrode and
                    (task.durable.title.len == 0 or
                        run.automatic_title.provisional_applied);
                const keep_provisional = run.automatic_title.provisional_applied and
                    candidate == null;
                if (may_replace and !keep_provisional) if (selected) |value| {
                    const reclaimable = task.durable.title.len;
                    const projected = projection.project(
                        task_policy.boundAutomaticTitle(value),
                        max_title_bytes,
                        run.redaction_secret,
                        reclaimable,
                    ) catch null;
                    if (projected) |title| {
                        const redacted = title.redacted or
                            run.automatic_title.generated_redacted;
                        if (title.value.len == 0 or
                            (std.mem.eql(u8, title.value, task.durable.title) and
                                redacted == task.durable.title_redacted))
                        {
                            projection.discardCandidate(title.value);
                            projection.restorePrevious(reclaimable);
                        } else {
                            projection.discardPrevious(task.durable.title);
                            task.durable.title = title.value;
                            task.durable.title_redacted = redacted;
                            result.durable_changed = true;
                        }
                    } else {
                        projection.restorePrevious(reclaimable);
                    }
                };
                std.crypto.secureZero(u8, &run.automatic_title.result);
                run.automatic_title.result_len = 0;
                run.automatic_title.generated = false;
                run.automatic_title.generated_redacted = false;
                run.automatic_title.state.store(.settled, .release);
            }
        }
        return result;
    }

    /// Settles checkpoint export results after the event-drain barrier. Blob
    /// I/O and the shared Workspace+Task history transaction are callback
    /// effects; ownership of the Task checkpoint state machine stays here.
    pub fn syncCheckpointPostprocesses(
        self: *Runtime,
        effects: CheckpointEffects,
    ) bool {
        var changed = false;
        for (self.tasks) |*entry| {
            const task = &(entry.* orelse continue);
            for (task.durable.runs) |*run_entry| {
                const run = &(run_entry.* orelse continue);
                if (!run.event_stream_finalized) continue;
                if (!self.syncCheckpointPostprocess(task, &run.checkpoint, effects))
                    continue;
                changed = true;
            }
            for (task.durable.compacts) |*compact_entry| {
                const compact = &(compact_entry.* orelse continue);
                if (!compact.terminal_observed) continue;
                if (!self.syncCheckpointPostprocess(task, &compact.checkpoint, effects))
                    continue;
                changed = true;
            }
        }
        return changed;
    }

    pub fn reconcileCheckpointStoreNoFail(
        self: *Runtime,
        store: *checkpoint_store.FileStore,
        health: *std.atomic.Value(checkpoint_store.Health),
        effects: CheckpointEffects,
    ) void {
        for (self.tasks) |*entry| {
            const task = &(entry.* orelse continue);
            const record = task.durable.checkpoint orelse continue;
            store.verify(record.blob) catch |err| {
                const anchor: task_state.CheckpointAnchor = switch (err) {
                    error.BlobMissing => .blob_missing,
                    error.BlobMismatch => .blob_mismatch,
                    else => {
                        health.store(.unavailable, .release);
                        return;
                    },
                };
                var removed = task.durable.checkpoint.?;
                const previous_anchor = task.durable.checkpoint_anchor;
                task.durable.checkpoint = null;
                task.durable.checkpoint_anchor = anchor;
                if (effects.commit(null) != .committed) {
                    task.durable.checkpoint = removed;
                    task.durable.checkpoint_anchor = previous_anchor;
                    return;
                }
                removed.deinit(self.allocator);
            };
        }
        var reference_count: usize = 0;
        for (self.tasks) |entry| if (entry) |task|
            if (task.durable.checkpoint != null) {
                reference_count += 1;
            };
        const references = self.allocator.alloc(
            checkpoint_store.Identity,
            reference_count,
        ) catch {
            health.store(.unavailable, .release);
            return;
        };
        defer self.allocator.free(references);
        var index: usize = 0;
        for (self.tasks) |entry| if (entry) |task|
            if (task.durable.checkpoint) |record| {
                references[index] = record.blob;
                index += 1;
            };
        store.cleanupOrphans(self.allocator, references) catch |err| {
            health.store(
                if (err == error.PersistenceOutcomeUnknown)
                    .outcome_unknown
                else
                    .unavailable,
                .release,
            );
        };
    }

    pub fn cleanupFileChangeStoreNoFail(
        self: *Runtime,
        store: *file_change_store.FileStore,
        max_bytes: usize,
    ) void {
        var reference_count: usize = 0;
        for (self.tasks) |entry| {
            const task = entry orelse continue;
            for (task.durable.runs) |run_entry| {
                const run = run_entry orelse continue;
                for (run.file_changes) |change_entry| {
                    const change = change_entry orelse continue;
                    if (change.artifact != null) reference_count += 1;
                }
            }
        }
        const references = self.allocator.alloc(
            file_change_store.Identity,
            reference_count,
        ) catch return;
        defer self.allocator.free(references);
        var index: usize = 0;
        for (self.tasks) |entry| {
            const task = entry orelse continue;
            for (task.durable.runs) |run_entry| {
                const run = run_entry orelse continue;
                for (run.file_changes) |change_entry| {
                    const change = change_entry orelse continue;
                    const artifact = change.artifact orelse continue;
                    references[index] = .{
                        .task_id = task.durable.id,
                        .run_generation = artifact.run_generation,
                        .change_order = artifact.change_order,
                        .digest = artifact.digest,
                        .byte_size = artifact.byte_size,
                    };
                    index += 1;
                }
            }
        }
        store.cleanupOrphans(self.allocator, references, max_bytes) catch return;
    }

    fn syncCheckpointPostprocess(
        self: *Runtime,
        task: *task_state.Task,
        postprocess: *task_state.CheckpointPostprocess,
        effects: CheckpointEffects,
    ) bool {
        switch (postprocess.state.load(.acquire)) {
            .none, .exporting, .settled => return false,
            .failure_ready => {
                const attempt = postprocess.payload.failure;
                const previous = task.durable.checkpoint_attempt;
                task.durable.checkpoint_attempt = attempt;
                if (effects.commit(null) != .committed)
                    task.durable.checkpoint_attempt = previous;
                postprocess.payload = .none;
                postprocess.state.store(.settled, .release);
                releaseCheckpointLease(postprocess);
                return true;
            },
            .candidate_ready => {
                const candidate = &postprocess.payload.candidate;
                switch (effects.commit(.{
                    .task_id = task.durable.id,
                    .record = &candidate.record,
                    .anchor = .available,
                })) {
                    .committed => {},
                    .failed => {
                        candidate.record.deinit(self.allocator);
                        postprocess.payload = .none;
                        postprocess.state.store(.settled, .release);
                        releaseCheckpointLease(postprocess);
                        return true;
                    },
                    .outcome_unknown => {
                        task.durable.checkpoint_attempt = .outcome_unknown;
                        candidate.record.deinit(self.allocator);
                        postprocess.payload = .none;
                        postprocess.state.store(.settled, .release);
                        releaseCheckpointLease(postprocess);
                        return true;
                    },
                }
                const old_identity = if (task.durable.checkpoint) |old| old.blob else null;
                if (task.durable.checkpoint) |*old| old.deinit(self.allocator);
                task.durable.checkpoint = candidate.record;
                candidate.record = undefined;
                task.durable.checkpoint_anchor = .available;
                task.durable.checkpoint_attempt = .none;
                postprocess.payload = .none;
                postprocess.state.store(.settled, .release);
                releaseCheckpointLease(postprocess);
                if (old_identity) |identity| effects.delete(identity);
                return true;
            },
        }
    }

    /// Executor shutdown has already joined every worker. This method consumes
    /// any uncommitted checkpoint candidates and releases the last Task worker
    /// references without performing persistence or file effects.
    pub fn settleCheckpointTransactionsForShutdown(self: *Runtime) void {
        for (self.tasks) |*entry| {
            const task = &(entry.* orelse continue);
            for (task.durable.runs) |*run_entry| {
                const run = &(run_entry.* orelse continue);
                self.settleCheckpointPostprocessForShutdown(&run.checkpoint);
            }
            for (task.durable.compacts) |*compact_entry| {
                const compact = &(compact_entry.* orelse continue);
                self.settleCheckpointPostprocessForShutdown(&compact.checkpoint);
            }
        }
    }

    pub fn prepareShutdown(
        self: *Runtime,
        executor: ExecutorCancellation,
    ) void {
        for (self.tasks) |*entry| {
            const task = &(entry.* orelse continue);
            cancelTaskCheckpoints(task);
            cancelTaskAutomaticTitles(task);
            if (!task.runtime.worker_leases.hasLive()) continue;
            switch (task.runtime.active_operation) {
                .none => {},
                .restore => {
                    const job = task.runtime.restore_job orelse continue;
                    job.requestCancellation();
                    _ = executor.cancel(job);
                },
                .compact => |operation_id| {
                    const compact = task_state.findCompact(
                        task.durable.compacts,
                        operation_id,
                    ) orelse continue;
                    _ = compact.pending_interruption.cmpxchgStrong(
                        .none,
                        .app_shutdown,
                        .acq_rel,
                        .acquire,
                    );
                    if (!executor.cancel(compact)) {
                        var access = task.runtime.acquireAccess() catch continue;
                        defer access.deinit();
                        access.requestCompactCancellation(
                            compact.id,
                            task_policy.pendingExternalInterruption(compact),
                        ) catch {};
                    }
                },
                .run => |run_id| {
                    const run = task_state.findRun(task.durable.runs, run_id) orelse
                        continue;
                    if (task_state.isTerminalPhase(task_state.runPhase(run))) continue;
                    _ = requestRunTermination(run, .app_shutdown);
                    if (executor.cancel(run)) run.terminal_observed = true;
                },
            }
        }
    }

    pub fn relinquishSessionsAfterRuntimeShutdown(self: *Runtime) void {
        for (self.tasks) |*entry| {
            const task = &(entry.* orelse continue);
            if (task.runtime.close_thread) |thread| {
                thread.join();
                task.runtime.close_thread = null;
            }
            const binding = task.runtime.bindingAfterCloseJoin() orelse continue;
            switch (binding.state()) {
                .owned, .closed => binding.relinquishAfterRuntimeShutdown(),
                .released, .relinquished, .moved, .fixture, .abandoned => {},
            }
            task.runtime.clearClosingRouteAfterRuntimeShutdown();
        }
        self.agent_runtime_shutdown_complete = true;
    }

    pub fn abandonSessionsForRuntimeDeinit(self: *Runtime) void {
        for (self.tasks) |*entry| {
            const task = &(entry.* orelse continue);
            if (task.runtime.close_thread) |thread| {
                thread.join();
                task.runtime.close_thread = null;
            }
            const binding = task.runtime.bindingAfterCloseJoin() orelse continue;
            switch (binding.state()) {
                .owned, .closed => binding.abandonForRuntimeDeinit(),
                .released, .relinquished, .moved, .fixture, .abandoned => {},
            }
            task.runtime.clearClosingRouteAfterRuntimeShutdown();
        }
        self.agent_runtime_shutdown_complete = true;
    }

    pub fn deinitTasks(self: *Runtime, effects: ReleaseEffects) void {
        for (self.tasks) |*entry| {
            const task = &(entry.* orelse continue);
            if (task.runtime.close_thread) |thread| {
                thread.join();
                task.runtime.close_thread = null;
            }
            deinitTask(self, task, effects);
            entry.* = null;
        }
    }

    pub fn resetIdentity(self: *Runtime) void {
        std.debug.assert(self.taskCount() == 0);
        self.next_task_id = 1;
        self.next_recent_order = 1;
    }

    pub fn taskCount(self: *const Runtime) usize {
        var count: usize = 0;
        for (self.tasks) |entry| if (entry != null) {
            count += 1;
        };
        return count;
    }

    pub fn recoveryAuthorityPossible(self: *const Runtime) bool {
        return !self.recovery_poisoned;
    }

    pub fn testRestoreCancellationRequested(
        self: *const Runtime,
        task_id: u64,
    ) bool {
        std.debug.assert(@import("builtin").is_test);
        const task = self.findConst(task_id) orelse return false;
        const job = task.runtime.restore_job orelse return false;
        return job.cancellation.load(.acquire);
    }

    pub fn testLateTerminalEventCount(self: *const Runtime) u64 {
        std.debug.assert(@import("builtin").is_test);
        return self.late_terminal_event_count;
    }

    pub fn testReserveRun(
        self: *Runtime,
        task_id: u64,
        input: RunInput,
        effects: OperationEffects,
    ) RunError!usize {
        std.debug.assert(@import("builtin").is_test);
        const task = self.find(task_id) orelse return error.UnknownTask;
        return reserveRun(self, task, input, effects);
    }

    pub fn testDiscardRun(
        self: *Runtime,
        task_id: u64,
        slot: usize,
        release: ReleaseEffects,
    ) void {
        std.debug.assert(@import("builtin").is_test);
        const task = self.find(task_id) orelse return;
        discardRun(self, task, slot, release);
    }

    pub fn testReserveCompact(
        self: *Runtime,
        task_id: u64,
        operation_id: u64,
        after_run_id: u64,
        effects: OperationEffects,
    ) CompactError!usize {
        std.debug.assert(@import("builtin").is_test);
        const task = self.find(task_id) orelse return error.UnknownTask;
        const slot = findEmptyCompact(task.durable.compacts) orelse
            return error.CompactCapacity;
        const diagnostic = try effects.text.allocateCapacity(
            effects.limits.max_terminal_diagnostic_bytes,
        );
        task.durable.compacts[slot] = .{
            .id = operation_id,
            .after_run_id = after_run_id,
            .terminal_diagnostic = diagnostic,
            .redaction_secret = (try taskExecutionInput(task)).api_key,
        };
        return slot;
    }

    pub fn testDiscardCompact(
        self: *Runtime,
        task_id: u64,
        slot: usize,
        release: ReleaseEffects,
    ) void {
        std.debug.assert(@import("builtin").is_test);
        const task = self.find(task_id) orelse return;
        discardCompact(self, task, slot, release);
    }

    pub fn testReleaseAttachment(
        self: *Runtime,
        task_id: u64,
        cause: task_attachment.DetachmentCause,
        release: ReleaseEffects,
    ) void {
        std.debug.assert(@import("builtin").is_test);
        const task = self.find(task_id) orelse return;
        releaseAttachmentNoFail(self, task, release, cause);
    }

    pub fn testExecutionInput(
        self: *const Runtime,
        task_id: u64,
    ) error{ UnknownTask, ExecutionUnavailable, ExecutionGenerationMismatch }!models_contract.ConfigInput {
        std.debug.assert(@import("builtin").is_test);
        const task = self.findConst(task_id) orelse return error.UnknownTask;
        return taskExecutionInput(task);
    }

    pub fn testDeinitRunInput(
        self: *Runtime,
        input: *task_state.RunInputRecord,
        release: ReleaseEffects,
    ) void {
        std.debug.assert(@import("builtin").is_test);
        deinitRunInput(self, release, input);
    }

    pub fn containsExecutionCredential(
        self: *const Runtime,
        value: []const u8,
    ) bool {
        for (self.tasks) |*entry| {
            const task = &(entry.* orelse continue);
            if (task.runtime.executionConst()) |execution| {
                const credential = execution.input().api_key;
                if (credential.len != 0 and
                    std.mem.indexOf(u8, value, credential) != null)
                    return true;
            }
        }
        return false;
    }

    /// Applies a callback-scoped projection scrubber against every credential
    /// still retained by a live Task execution. The callback may observe a
    /// borrowed credential only for the duration of the call and must not
    /// retain it; only the aggregate redaction result is returned.
    pub fn redactWithExecutionCredentialsNoFail(
        self: *const Runtime,
        value: []u8,
        redact_fn: *const fn ([]u8, []const u8) bool,
    ) bool {
        var changed = false;
        for (self.tasks) |*entry| {
            const task = &(entry.* orelse continue);
            if (task.runtime.executionConst()) |execution| {
                const credential = execution.input().api_key;
                if (credential.len != 0)
                    changed = redact_fn(value, credential) or changed;
            }
        }
        return changed;
    }

    pub fn matchedExecutionCredentialPrefix(
        self: *const Runtime,
        value: []const u8,
    ) usize {
        var longest: usize = 0;
        for (self.tasks) |*entry| {
            const task = &(entry.* orelse continue);
            if (task.runtime.executionConst()) |execution| {
                const credential = execution.input().api_key;
                if (credential.len > longest and
                    std.mem.startsWith(u8, value, credential))
                    longest = credential.len;
            }
        }
        return longest;
    }

    pub fn executionCredentialMayContinue(
        self: *const Runtime,
        value: []const u8,
    ) bool {
        if (value.len == 0) return false;
        for (self.tasks) |*entry| {
            const task = &(entry.* orelse continue);
            if (task.runtime.executionConst()) |execution| {
                const credential = execution.input().api_key;
                if (value.len < credential.len and
                    std.mem.startsWith(u8, credential, value)) return true;
            }
        }
        return false;
    }

    pub fn redactProjectionsNoFail(
        self: *Runtime,
        credential: []const u8,
        effects: RedactionEffects,
    ) void {
        if (credential.len == 0) return;
        for (self.tasks) |*entry| {
            const task = &(entry.* orelse continue);
            if (task.runtime.pinnedCatalog()) |snapshot| {
                if (snapshot.identityContainsCredential(credential)) {
                    effects.releaseProjectionBytes(snapshot.projected_bytes);
                    snapshot.deinit();
                    task.runtime.live().?.pinned_catalog = null;
                } else {
                    snapshot.redactPresentationNoFail(credential);
                }
            }
            redactTaskProjection(task, credential, effects);
        }
    }

    pub fn writeProjectionList(
        self: *Runtime,
        writer: *std.Io.Writer,
        effects: ProjectionEffects,
    ) task_view.Error!void {
        var pending_ui_context = PendingUiContext{
            .runtime = self,
            .max_json_bytes = effects.max_pending_ui_json_bytes,
        };
        var count: usize = 0;
        for (self.tasks) |*entry| {
            const task = &(entry.* orelse continue);
            if (count != 0) writer.writeByte(',') catch
                return error.SnapshotTooLarge;
            count += 1;
            const external = effects.authority(projectionAuthorityQuery(task));
            const recovery = self.recoveryProjectionWithAuthority(task, external);
            task_view.writeProjection(writer, .{
                .task = task,
                .recovery = recovery,
                .model_selection_availability = external.model_selection_availability,
                .shutting_down = external.shutting_down,
                .text = effects.text,
                .catalog = effects.catalog,
                .pending_ui = .{
                    .context = &pending_ui_context,
                    .write_fn = writePendingUiProjection,
                },
            }) catch |err| return err;
        }
    }

    pub fn recoveryStartFacts(
        self: *const Runtime,
        task_id: u64,
        expected_binding_epoch: u64,
        effects: RecoveryAdmissionEffects,
    ) error{ UnknownTask, BindingEpochMismatch, RecoveryUnavailable }!RecoveryStartFacts {
        const task = self.findConst(task_id) orelse return error.UnknownTask;
        if (expected_binding_epoch == 0 or
            expected_binding_epoch != task.durable.binding_epoch)
            return error.BindingEpochMismatch;
        const external = effects.authority(projectionAuthorityQuery(task));
        switch (task_recovery.evaluateRecoveryAdmission(
            self.recoveryAdmissionFacts(task, external),
        )) {
            .admitted => {},
            .denied => return error.RecoveryUnavailable,
        }
        return .{
            .workspace_id = task.durable.workspace_id,
            .workspace_epoch = task.durable.workspace_epoch,
            .execution_model = task.durable.execution_model,
        };
    }

    pub fn startRecovery(
        self: *Runtime,
        task_id: u64,
        input: RecoveryStartInput,
    ) RecoveryStartError!u64 {
        const task = self.find(task_id) orelse return error.UnknownTask;
        if (input.expected_binding_epoch == 0 or
            input.expected_binding_epoch != task.durable.binding_epoch)
            return error.BindingEpochMismatch;
        const checkpoint = task.durable.checkpoint orelse
            return error.RecoveryUnavailable;
        if (input.execution.execution_generation == 0 or
            input.execution.target.protocol != task.durable.execution_protocol)
            return error.RecoveryUnavailable;
        if (task.runtime.active_operation != .none or
            task.runtime.liveConst() != null)
            return error.RecoveryUnavailable;
        if (self.next_restore_attempt_id == 0 or
            self.next_restore_attempt_id == std.math.maxInt(u64))
            return error.RestoreAttemptExhausted;
        const attempt_id = self.next_restore_attempt_id;
        var checkpoint_copy = try checkpoint.clone(self.allocator);
        var checkpoint_live = true;
        errdefer if (checkpoint_live) checkpoint_copy.deinit(self.allocator);
        var epoch_storage: [32]u8 = undefined;
        const epoch_token = std.fmt.bufPrint(
            &epoch_storage,
            "{d}",
            .{input.workspace_epoch},
        ) catch unreachable;
        var workspace = try recovery_job.OwnedWorkspaceBinding.init(
            self.allocator,
            input.workspace_root,
            input.canonical_user_home,
            epoch_token,
            switch (input.workspace_trust) {
                .explicitly_trusted => .explicitly_trusted,
                .temporary => .temporary,
            },
        );
        var workspace_live = true;
        errdefer if (workspace_live) workspace.deinit();
        var execution = try owned_task_execution.OwnedTaskExecution.clone(
            self.allocator,
            input.execution,
        );
        errdefer execution.deinit();
        const model = try self.allocator.dupe(u8, task.durable.execution_model);
        var model_live = true;
        errdefer if (model_live) self.allocator.free(model);
        var restore_lease = task.runtime.worker_leases.acquire() catch return error.RestoreBusy;
        var restore_lease_owned = true;
        errdefer if (restore_lease_owned) restore_lease.deinit();
        const job = try self.allocator.create(recovery_job.Job);
        var job_owned = true;
        var job_initialized = false;
        errdefer if (job_owned) {
            if (job_initialized) {
                job.deinit();
            } else {
                self.allocator.destroy(job);
            }
        };
        const permission = agentSessionPermission(
            task.durable.permission_profile,
            task.durable.permission_interaction,
        );
        job.* = .{
            .allocator = self.allocator,
            .runtime = input.agent_runtime,
            .store = input.checkpoint_store,
            .notifier = .{
                .context = input.notifier.context,
                .notify_fn = input.notifier.notify_fn,
            },
            .checkpoint_limits = input.checkpoint_limits,
            .lease = restore_lease.take(),
            .attempt = .{
                .attempt_id = attempt_id,
                .task_id = task_id,
                .binding_epoch = input.expected_binding_epoch,
                .workspace_id = input.workspace_id,
                .workspace_epoch = input.workspace_epoch,
                .workspace_kind = input.workspace_kind,
                .checkpoint = checkpoint_copy,
                .workspace = workspace,
                .execution = execution.take(),
                .source_execution_generation = task.durable.execution_generation,
                .target_execution_generation = input.execution.execution_generation,
                .task_model = model,
                .protocol = task.durable.execution_protocol,
                .permission_mode = permission.mode,
                .shell_policy = permission.shell,
                .permission_interaction = permission.interaction,
            },
        };
        restore_lease_owned = false;
        job_initialized = true;
        checkpoint_live = false;
        workspace_live = false;
        model_live = false;
        task.runtime.active_operation = .{ .restore = .{ .id = attempt_id } };
        task.runtime.restore_job = job;
        task.runtime.last_restore_failure = null;
        input.executor.enqueue(
            job,
            job,
            recovery_job.Job.execute,
            recovery_job.Job.cancelQueued,
        ) catch |err| {
            task.runtime.restore_job = null;
            task.runtime.active_operation = .none;
            job.outcome = .{ .failure = .cancelled };
            job.state.store(.cancelled, .release);
            return err;
        };
        job_owned = false;
        self.next_restore_attempt_id += 1;
        return attempt_id;
    }

    pub fn continuationAvailable(
        self: *const Runtime,
        task_id: u64,
        effects: ProjectionEffects,
    ) bool {
        const task = self.findConst(task_id) orelse return false;
        const external = effects.authority(projectionAuthorityQuery(task));
        return !external.shutting_down and
            task_policy.taskLifecycle(task) == .open and
            task_policy.continuationAvailable(
                self.recoveryProjectionWithAuthority(task, external).continuation,
            );
    }

    pub fn continuationProjection(
        self: *const Runtime,
        task_id: u64,
        effects: ProjectionEffects,
    ) ?ContinuationCapability {
        const task = self.findConst(task_id) orelse return null;
        return self.recoveryProjection(task, effects).continuation;
    }

    fn recoveryProjection(
        self: *const Runtime,
        task: *const task_state.Task,
        effects: ProjectionEffects,
    ) task_recovery.Projection {
        return self.recoveryProjectionWithAuthority(
            task,
            effects.authority(projectionAuthorityQuery(task)),
        );
    }

    fn recoveryProjectionWithAuthority(
        self: *const Runtime,
        task: *const task_state.Task,
        external: ProjectionAuthority,
    ) task_recovery.Projection {
        return task_recovery.project(self.recoveryAdmissionFacts(task, external));
    }

    fn recoveryAdmissionFacts(
        self: *const Runtime,
        task: *const task_state.Task,
        external: ProjectionAuthority,
    ) task_recovery.RecoveryAdmissionFacts {
        const checkpoint = task.durable.checkpoint;
        const checkpoint_binding_valid = if (checkpoint) |record| binding: {
            if (record.blob.generation == 0) break :binding false;
            record.validateBinding(task.durable.id, task.durable.binding_epoch) catch
                break :binding false;
            break :binding true;
        } else false;
        return .{
            .archived = task.durable.archived,
            .attachment = if (task.deletion == .deleting)
                .closing
            else
                task_policy.recoveryAttachment(task.runtime.attachment),
            .operation = task_policy.recoveryOperation(task.runtime.active_operation),
            .task_persistence_ready = external.task_persistence_ready,
            .checkpoint_store_ready = external.checkpoint_store_ready,
            .runtime_admission = external.runtime_admission,
            .execution_admission = external.execution_admission,
            .core = .{
                .checkpoint_available = checkpoint != null and
                    task.durable.checkpoint_anchor == .available,
                .checkpoint_binding_exact = checkpoint_binding_valid,
                .checkpoint_history_exact = if (checkpoint) |record|
                    task_policy.checkpointMatchesCurrentHistory(task, record)
                else
                    false,
                .workspace_identity_exact = external.workspace_identity_exact,
                .automatic_owner_exact = external.automatic_owner_exact,
                .authority_stable = !self.recovery_poisoned and external.authority_stable,
            },
            .recovery_failed = task.runtime.last_restore_failure != null,
        };
    }

    fn settleCheckpointPostprocessForShutdown(
        self: *Runtime,
        postprocess: *task_state.CheckpointPostprocess,
    ) void {
        switch (postprocess.payload) {
            .candidate => |*candidate| candidate.record.deinit(self.allocator),
            .none, .failure => {},
        }
        postprocess.payload = .none;
        postprocess.state.store(.settled, .release);
        releaseCheckpointLease(postprocess);
    }

    fn releaseCheckpointLease(postprocess: *task_state.CheckpointPostprocess) void {
        if (postprocess.lease) |*lease| lease.deinit();
        postprocess.lease = null;
    }

    /// Reconciles Task-owned Session observations and immutable Run/Compact
    /// terminal facts. It performs no cross-owner effect and does not touch
    /// persistence, revision publication, Workspace, Skill or MCP authority.
    pub fn syncOperationRecords(self: *Runtime) LifecycleSync {
        var result: LifecycleSync = .{};
        for (self.tasks) |*entry| {
            const task = &(entry.* orelse continue);
            var observation_access = if (task.runtime.worker_leases.hasLive() and
                task.runtime.active_run_id != 0)
                task.runtime.acquireAccess() catch null
            else
                null;
            defer if (observation_access) |*access| access.deinit();
            const pending = if (observation_access) |*access|
                access.pendingUiObservation()
            else
                null;
            const pending_request_id = if (pending) |value| value.request_id else 0;
            if (task.runtime.pending_ui_request_id != pending_request_id) {
                task.runtime.pending_ui_request_id = pending_request_id;
                task.runtime.pending_ui_order = 0;
                if (pending) |observation| {
                    if (task_state.findRun(task.durable.runs, observation.run_id)) |pending_run| {
                        task.runtime.pending_ui_order = takeActivityOrder(pending_run);
                    }
                }
                result.changed = true;
            }
            if (switch (task.runtime.active_operation) {
                .compact => true,
                .none, .run, .restore => false,
            }) {
                const operation_id = switch (task.runtime.active_operation) {
                    .compact => |id| id,
                    .none, .run, .restore => unreachable,
                };
                const compact = task_state.findCompact(
                    task.durable.compacts,
                    operation_id,
                ) orelse {
                    task.runtime.active_operation = .none;
                    result.changed = true;
                    continue;
                };
                if (task_state.compactTerminalPayload(compact)) |terminal| {
                    if (!compact.terminal_observed) {
                        task_policy.foldTerminalDisposition(
                            task,
                            terminal.session_disposition_at_completion,
                        );
                        compact.terminal_observed = true;
                    }
                    task.runtime.active_operation = .none;
                    result.changed = true;
                    result.durable_changed = true;
                }
                continue;
            }
            const run = task_state.findRun(
                task.durable.runs,
                task.runtime.active_run_id,
            ) orelse continue;
            if (task_state.productTerminalFacts(run) != null) {
                const terminal_changed = settleActiveRunTerminal(task);
                result.changed = terminal_changed or result.changed;
                result.durable_changed = terminal_changed or result.durable_changed;
                continue;
            }
            const next_phase: task_state.ActiveRunPhase = if (task.runtime.cancel_requested)
                .stopping
            else if (pending != null)
                .waiting_ui
            else switch (run.agent_handoff.load(.acquire)) {
                .queued, .starting => .queued,
                .running, .finishing => .running,
            };
            if (run.active_phase != next_phase and
                task_state.setActivePhase(run, next_phase))
                result.changed = true;
        }
        return result;
    }

    fn settleActiveRunTerminal(task: *task_state.Task) bool {
        const run = task_state.findRun(
            task.durable.runs,
            task.runtime.active_run_id,
        ) orelse return false;
        const terminal = task_state.productTerminalFacts(run) orelse return false;
        var changed = false;
        task.runtime.cancel_requested = false;
        if (switch (task.runtime.active_operation) {
            .run => |id| id == run.id,
            .none, .compact, .restore => false,
        }) {
            task.runtime.active_operation = .none;
            changed = true;
        }
        if (!run.terminal_observed) {
            task_policy.foldTerminalDisposition(
                task,
                terminal.session_disposition_at_completion,
            );
            run.terminal_observed = true;
            changed = true;
        }
        return changed;
    }

    /// Turns the Agent-owned noninteractive permission stop observation into
    /// a bounded Run-control effect. Terminal publication remains worker-owned
    /// and is reconciled separately by `syncOperationRecords`.
    pub fn requestPermissionStops(self: *Runtime) bool {
        var changed = false;
        for (self.tasks) |*entry| {
            const task = &(entry.* orelse continue);
            if (!task.runtime.worker_leases.hasLive() or
                task.runtime.active_run_id == 0 or
                task.runtime.cancel_requested)
                continue;
            const active_run_id = switch (task.runtime.active_operation) {
                .run => |run_id| run_id,
                .none, .compact, .restore => continue,
            };
            if (active_run_id != task.runtime.active_run_id) continue;
            const run = task_state.findRun(
                task.durable.runs,
                active_run_id,
            ) orelse continue;
            if (task_state.terminalPayload(run) != null) continue;
            var access = task.runtime.acquireAccess() catch continue;
            defer access.deinit();
            if (access.permissionStopRequest() != active_run_id) continue;
            const dispatch = requestPermissionTermination(run);
            const stopping = switch (dispatch) {
                .requested, .already_requested => true,
                .pending,
                .already_finishing,
                .already_terminal,
                .stale_run,
                .session_closing,
                => false,
            };
            if (!stopping) continue;
            task.runtime.cancel_requested = true;
            changed = true;
            if (task_state.setActivePhase(run, .stopping)) changed = true;
        }
        return changed;
    }

    pub fn syncCloseCompletions(
        self: *Runtime,
        effects: ReleaseEffects,
    ) bool {
        var changed = false;
        for (self.tasks) |*entry| {
            const task = &(entry.* orelse continue);
            const completion = task.runtime.close_completion.load(.acquire);
            if (completion == .none or completion == .running or
                task_state.hasUnfinalizedTerminalEvents(task))
                continue;
            task.runtime.close_thread.?.join();
            task.runtime.close_thread = null;
            std.debug.assert(task.runtime.hasClosingSession());
            task.runtime.close_completion.store(.none, .release);
            switch (completion) {
                .closed => {
                    std.debug.assert(
                        task.runtime.closingWorkerBinding().?.state() == .released,
                    );
                    var live = task.runtime.detach(.released);
                    releaseExecutionValueNoFail(task, &live.execution, effects);
                    if (live.pinned_catalog) |*snapshot| {
                        effects.releaseProjectionBytes(snapshot.projected_bytes);
                        snapshot.deinit();
                    }
                    task.conversation_observation = .{};
                    task.runtime.close_failed = false;
                },
                .failed_reusable, .failed_poisoned, .failed_closing => {
                    task.runtime.close_failed = true;
                    if (task.deletion == .deleting) task.deletion = .failed;
                    switch (completion) {
                        .failed_reusable => task.runtime.restoreCloseFailure(.available),
                        .failed_poisoned => task.runtime.restoreCloseFailure(.session_poisoned),
                        .failed_closing => {},
                        else => unreachable,
                    }
                },
                .none, .running => unreachable,
            }
            task.runtime.cancel_requested = false;
            changed = true;
        }
        return changed;
    }

    pub fn syncRecoveryCompletions(
        self: *Runtime,
        effects: RecoveryEffects,
    ) RecoverySync {
        var result: RecoverySync = .{};
        for (self.tasks) |*entry| {
            const task = &(entry.* orelse continue);
            const job = task.runtime.restore_job orelse continue;
            if (!job.completionReady()) continue;
            const external = effects.authority(.{
                .task_id = task.durable.id,
                .workspace_id = task.durable.workspace_id,
                .workspace_epoch = task.durable.workspace_epoch,
                .target_execution_generation = job.attempt.target_execution_generation,
                .task_model = task.durable.execution_model,
                .protocol = task.durable.execution_protocol,
            });
            const active_attempt_id: ?u64 = switch (task.runtime.active_operation) {
                .restore => |attempt| attempt.id,
                .none, .run, .compact => null,
            };
            if (job.takeCandidate()) |candidate_value| {
                var candidate = candidate_value;
                const checkpoint_matches = if (task.durable.checkpoint) |record|
                    checkpointIdentityEqual(record.blob, job.attempt.checkpoint.blob)
                else
                    false;
                const allowed = recovery_job.commitAllowed(
                    &job.attempt,
                    .{
                        .task_id = task.durable.id,
                        .binding_epoch = task.durable.binding_epoch,
                        .workspace_id = task.durable.workspace_id,
                        .workspace_epoch = task.durable.workspace_epoch,
                        .workspace_kind = external.workspace_kind,
                        .workspace_root = external.workspace_root,
                        .source_execution_generation = task.durable.execution_generation,
                        .target_execution_generation = external.target_execution_generation,
                        .task_model = task.durable.execution_model,
                        .protocol = task.durable.execution_protocol,
                        .active_attempt_id = active_attempt_id,
                        .shutting_down = external.shutting_down,
                        .archived = task.durable.archived,
                        .attachment_detached = task.runtime.attachment == .detached,
                        .checkpoint_matches = checkpoint_matches,
                        .workspace_authority_exact = external.workspace_authority_exact,
                        .automatic_owner_exact = external.automatic_owner_exact,
                        .target_execution_authority_exact = external.target_execution_authority_exact,
                    },
                );
                var install_candidate = allowed;
                if (install_candidate and
                    job.attempt.source_execution_generation !=
                        job.attempt.target_execution_generation)
                adoption: {
                    if (task.durable.binding_epoch == std.math.maxInt(u64)) {
                        task.runtime.last_restore_failure = .binding_epoch_exhausted;
                        install_candidate = false;
                        break :adoption;
                    }
                    const previous_generation = task.durable.execution_generation;
                    const previous_epoch = task.durable.binding_epoch;
                    const next_epoch = previous_epoch + 1;
                    const checkpoint = &(task.durable.checkpoint orelse {
                        task.runtime.last_restore_failure = .binding_persistence_failed;
                        install_candidate = false;
                        break :adoption;
                    });
                    checkpoint.adoptBindingEpoch(previous_epoch, next_epoch) catch {
                        task.runtime.last_restore_failure = .binding_persistence_failed;
                        install_candidate = false;
                        break :adoption;
                    };
                    task.durable.execution_generation =
                        job.attempt.target_execution_generation;
                    task.durable.binding_epoch = next_epoch;
                    switch (effects.commitBinding()) {
                        .committed => {},
                        .failed, .outcome_unknown => |outcome| {
                            task.durable.execution_generation = previous_generation;
                            task.durable.binding_epoch = previous_epoch;
                            checkpoint.anchor.binding_epoch = previous_epoch;
                            task.runtime.last_restore_failure = switch (outcome) {
                                .failed => .binding_persistence_failed,
                                .outcome_unknown => .binding_persistence_unknown,
                                .committed => unreachable,
                            };
                            install_candidate = false;
                        },
                    }
                }
                if (install_candidate) {
                    task.runtime.last_restore_report = candidate.report;
                    task.runtime.last_restore_permission = .{
                        .restored_rules = candidate.report.restored_permission_rules,
                        .invalidated_rules = candidate.report.invalidated_permission_rules,
                    };
                    task.runtime.attachment = .{ .attached = .{
                        .binding = candidate.takeBinding(),
                        .execution = candidate.takeExecution(),
                        .pinned_catalog = null,
                    } };
                    task.conversation_observation = .{};
                    task.runtime.last_restore_failure = null;
                } else {
                    if (!candidate.discard()) {
                        self.recovery_poisoned = true;
                        task.runtime.last_restore_failure = .candidate_cleanup_failed;
                    }
                }
            } else if (job.failure()) |failure| {
                task.runtime.last_restore_failure = failure;
                result.mcp_refresh_needed = result.mcp_refresh_needed or
                    failure == .runtime_refresh_required;
                switch (failure) {
                    .checkpoint_missing => {
                        task.durable.checkpoint_anchor = .blob_missing;
                        result.durable_changed = true;
                    },
                    .checkpoint_mismatch => {
                        task.durable.checkpoint_anchor = .blob_mismatch;
                        result.durable_changed = true;
                    },
                    .checkpoint_io => {
                        task.durable.checkpoint_attempt = .io_failed;
                        result.durable_changed = true;
                    },
                    .candidate_cleanup_failed => self.recovery_poisoned = true,
                    else => {},
                }
            }
            task.runtime.restore_job = null;
            task.runtime.active_operation = .none;
            job.deinit();
            result.changed = true;
        }
        return result;
    }

    /// The only production entry point that settles asynchronous Task-owned
    /// lifecycle state on the composition thread.
    pub fn reconcileLifecycle(
        self: *Runtime,
        effects: LifecycleEffects,
    ) RecoverySync {
        var result: RecoverySync = .{};
        const titles = self.syncAutomaticTitles(
            effects.max_title_bytes,
            effects.text,
        );
        result.changed = titles.changed;
        result.durable_changed = titles.durable_changed;

        const recovery = self.syncRecoveryCompletions(effects.recovery);
        result.changed = recovery.changed or result.changed;
        result.durable_changed = recovery.durable_changed or result.durable_changed;
        result.mcp_refresh_needed = recovery.mcp_refresh_needed;

        result.changed = self.syncCloseCompletions(effects.release) or result.changed;
        result.changed = self.requestPermissionStops() or result.changed;
        const operations = self.syncOperationRecords();
        result.changed = operations.changed or result.changed;
        result.durable_changed = operations.durable_changed or result.durable_changed;
        result.changed = self.syncCheckpointPostprocesses(effects.checkpoint) or result.changed;
        return result;
    }
};

fn markAutomaticTitleUserOverride(task: *task_state.Task) void {
    for (task.durable.runs) |*entry| {
        const run = &(entry.* orelse continue);
        if (!run.automatic_title.provisional_applied) continue;
        switch (run.automatic_title.state.load(.acquire)) {
            .pending, .running, .ready => run.automatic_title.user_overrode = true,
            .none, .settled => {},
        }
    }
}

fn projectionAuthorityQuery(
    task: *const task_state.Task,
) ProjectionAuthorityQuery {
    return .{
        .task_id = task.durable.id,
        .workspace_id = task.durable.workspace_id,
        .workspace_epoch = task.durable.workspace_epoch,
        .workspace_root = task.durable.workspace_root,
        .execution_generation = task.durable.execution_generation,
        .execution_protocol = task.durable.execution_protocol,
        .execution_model = task.durable.execution_model,
        .runtime_attached = task.runtime.executionConst() != null,
    };
}

fn redactTaskProjection(
    task: *task_state.Task,
    credential: []const u8,
    effects: RedactionEffects,
) void {
    task.durable.title_redacted = effects.redact(task.durable.title, credential) or
        task.durable.title_redacted;
    _ = effects.redact(task.durable.workspace_root, credential);
    _ = effects.redact(task.durable.execution_model, credential);
    for (task.durable.runs) |*entry| {
        const run = &(entry.* orelse continue);
        switch (run.input) {
            .text => |*text| text.redacted = effects.redact(text.value, credential) or
                text.redacted,
            .multimodal => |*multimodal| {
                var redacted = false;
                if (multimodal.text) |text|
                    redacted = effects.redact(text, credential);
                for (multimodal.attachments) |*item| {
                    item.redacted = effects.redact(item.display_name, credential) or
                        item.redacted;
                    redacted = redacted or item.redacted;
                }
                multimodal.redacted = redacted or multimodal.redacted;
            },
            .skill => |*skill| {
                var redacted = effects.redact(skill.skill_id, credential);
                redacted = effects.redact(skill.catalog_revision, credential) or redacted;
                redacted = effects.redact(skill.invocation_name, credential) or redacted;
                redacted = effects.redact(skill.display_name, credential) or redacted;
                for (skill.argument_values) |value|
                    redacted = effects.redact(value, credential) or redacted;
                skill.redacted = redacted or skill.redacted;
            },
        }
        run.assistant_redacted = effects.redact(
            run.assistant.list.items,
            credential,
        ) or run.assistant_redacted;
        run.output_segment_redacted = effects.redact(
            run.output_segment.list.items,
            credential,
        ) or run.output_segment_redacted;
        run.output_continued_redacted = effects.redact(
            run.output_continued.list.items,
            credential,
        ) or run.output_continued_redacted;
        for (run.tools) |*tool_entry| {
            const tool = &(tool_entry.* orelse continue);
            var redacted = effects.redact(tool.id, credential);
            redacted = effects.redact(tool.name, credential) or redacted;
            redacted = effects.redact(tool.input, credential) or redacted;
            redacted = effects.redact(tool.progress, credential) or redacted;
            redacted = effects.redact(tool.content, credential) or redacted;
            if (tool.file_refs) |references| for (references) |*reference_entry| {
                const reference = &(reference_entry.* orelse continue);
                redacted = effects.redact(reference.id, credential) or redacted;
                redacted = effects.redact(reference.title, credential) or redacted;
                redacted = effects.redact(reference.display_path, credential) or redacted;
                redacted = effects.redact(reference.kind, credential) or redacted;
                redacted = effects.redact(reference.locator, credential) or redacted;
            };
            tool.redacted = redacted or tool.redacted;
        }
        if (run.permission_provenance) |*permission|
            _ = redactPermissionSummary(permission, credential, effects);
        for (run.file_changes) |*change_entry| {
            const change = &(change_entry.* orelse continue);
            var redacted = effects.redact(change.id, credential);
            redacted = effects.redact(change.display_path, credential) or redacted;
            if (change.from_display_path) |from|
                redacted = effects.redact(from, credential) or redacted;
            change.redacted = redacted or change.redacted;
        }
        if (task_state.terminalPayload(run)) |terminal| {
            const mutable = @constCast(terminal);
            mutable.diagnostic_redacted = effects.redact(
                run.terminal_diagnostic[0..mutable.diagnostic_len],
                credential,
            ) or mutable.diagnostic_redacted;
        }
        if (run.automatic_title.state.load(.acquire) == .ready and
            run.automatic_title.generated)
        {
            run.automatic_title.generated_redacted = effects.redact(
                run.automatic_title.result[0..run.automatic_title.result_len],
                credential,
            ) or run.automatic_title.generated_redacted;
        }
    }
    for (task.durable.compacts) |*entry| {
        const compact = &(entry.* orelse continue);
        if (task_state.compactTerminalPayload(compact)) |terminal| {
            const mutable = @constCast(terminal);
            mutable.diagnostic_redacted = effects.redact(
                compact.terminal_diagnostic[0..mutable.diagnostic_len],
                credential,
            ) or mutable.diagnostic_redacted;
        }
    }
    for (task.durable.ui_history) |*entry| {
        const record = &(entry.* orelse continue);
        var redacted = effects.redact(
            record.detail[0..record.detail_len],
            credential,
        );
        redacted = effects.redact(
            record.agent_request_id[0..record.agent_request_id_len],
            credential,
        ) or redacted;
        if (record.permission) |*permission|
            redacted = redactPermissionSummary(
                permission,
                credential,
                effects,
            ) or redacted;
        record.redacted = redacted or record.redacted;
    }
}

fn redactPermissionSummary(
    permission: *task_state.PermissionSummary,
    credential: []const u8,
    effects: RedactionEffects,
) bool {
    var changed = effects.redact(
        permission.request_id[0..permission.request_id_len],
        credential,
    );
    changed = effects.redact(
        permission.matched_rule_id[0..permission.matched_rule_id_len],
        credential,
    ) or changed;
    changed = effects.redact(
        permission.tool_name[0..permission.tool_name_len],
        credential,
    ) or changed;
    changed = effects.redact(
        permission.tool_binding[0..permission.tool_binding_len],
        credential,
    ) or changed;
    return changed;
}

fn writePendingUiProjection(
    context: *anyopaque,
    writer: *std.Io.Writer,
    task: *const task_state.Task,
    text_projection: task_view.TextProjection,
) task_view.Error!void {
    const pending_context: *PendingUiContext = @ptrCast(@alignCast(context));
    _ = pending_context.max_json_bytes;
    if (task.runtime.pending_ui_request_id == 0) {
        writer.writeAll("null") catch return error.SnapshotTooLarge;
        return;
    }
    var access = @constCast(&task.runtime).acquireAccess() catch {
        writer.writeAll("null") catch return error.SnapshotTooLarge;
        return;
    };
    defer access.deinit();
    var pending = access.copyPendingUiRequest(pending_context.runtime.allocator) catch |err| switch (err) {
        error.NoPendingUiRequest, error.StaleUiResponse => {
            writer.writeAll("null") catch return error.SnapshotTooLarge;
            return;
        },
        else => return error.OutOfMemory,
    };
    defer pending.deinit();
    var parsed = agent.decodePermissionRequest(
        pending_context.runtime.allocator,
        pending.json,
    ) catch return error.InvalidUiResponse;
    defer parsed.deinit();
    if (task.runtime.pending_ui_request_id != pending.request_id or
        task.runtime.pending_ui_order == 0)
    {
        writer.writeAll("null") catch return error.SnapshotTooLarge;
        return;
    }
    if (task_state.findRun(task.durable.runs, pending.run_id) == null)
        return error.InvalidUiResponse;
    task_view.writePendingUi(
        writer,
        text_projection,
        pending.request_id,
        pending.run_id,
        task.runtime.pending_ui_order,
        parsed.value(),
    ) catch |err| return err;
}

fn takeActivityOrder(run: *task_state.RunRecord) u64 {
    const order = run.next_activity_order;
    std.debug.assert(order != std.math.maxInt(u64));
    run.next_activity_order += 1;
    return order;
}

fn appendEventAssistant(
    raw_context: *anyopaque,
    target: *task_state.TrackedText,
    suffix: []const u8,
    max: usize,
    credential: []const u8,
) task_state.EventProjectionError!bool {
    const context: *EventContext = @ptrCast(@alignCast(raw_context));
    if (suffix.len > max - target.list.items.len)
        return error.ProjectionCapacity;
    const needed = target.list.items.len + suffix.len;
    if (needed > target.list.capacity) {
        const growth = @max(@as(usize, 1024), target.list.capacity / 2);
        const desired = @min(max, @max(needed, target.list.capacity + growth));
        const added = desired - target.list.capacity;
        try context.effects.text.reserveBytes(added);
        target.list.ensureTotalCapacityPrecise(
            context.runtime.allocator,
            desired,
        ) catch |err| {
            context.effects.text.releaseBytes(added);
            return err;
        };
    }
    target.list.appendSliceAssumeCapacity(suffix);
    return redactTrackedText(target, credential);
}

fn appendEventGroup(
    raw_context: *anyopaque,
    target: *task_state.TrackedText,
    first: []const u8,
    second: []const u8,
    max: usize,
    credential: []const u8,
) task_state.EventProjectionError!bool {
    const context: *EventContext = @ptrCast(@alignCast(raw_context));
    const added = std.math.add(usize, first.len, second.len) catch
        return error.ProjectionCapacity;
    if (target.list.items.len > max or added > max - target.list.items.len)
        return error.ProjectionCapacity;
    const needed = target.list.items.len + added;
    if (needed > target.list.capacity) {
        const growth = @max(@as(usize, 1024), target.list.capacity / 2);
        const desired = @min(max, @max(needed, target.list.capacity + growth));
        const reserved = desired - target.list.capacity;
        try context.effects.text.reserveBytes(reserved);
        target.list.ensureTotalCapacityPrecise(
            context.runtime.allocator,
            desired,
        ) catch |err| {
            context.effects.text.releaseBytes(reserved);
            return err;
        };
    }
    // No fallible operation remains after the reserve, so callers may commit
    // their segment state immediately after this returns.
    target.list.appendSliceAssumeCapacity(first);
    target.list.appendSliceAssumeCapacity(second);
    return redactTrackedText(target, credential);
}

fn replaceEventText(
    raw_context: *anyopaque,
    target: *[]u8,
    value: []const u8,
    max: usize,
    credential: []const u8,
) task_state.EventProjectionError!task_state.TextProjectionResult {
    const context: *EventContext = @ptrCast(@alignCast(raw_context));
    const previous = target.*;
    const projected = try context.effects.text.project(
        value,
        max,
        credential,
        previous.len,
    );
    target.* = projected.value;
    context.effects.text.discardPrevious(previous);
    return .{ .truncated = projected.truncated, .redacted = projected.redacted };
}

fn findOrCreateEventTool(
    raw_context: *anyopaque,
    run_record: *task_state.RunRecord,
    id: []const u8,
    name: []const u8,
    input: []const u8,
) task_state.EventProjectionError!*task_state.ToolView {
    const context: *EventContext = @ptrCast(@alignCast(raw_context));
    const digest = toolRouteDigest(id);
    if (findToolByRouteDigest(run_record.tools, digest)) |tool| return tool;
    const slot = findEmptyTool(run_record.tools) orelse return error.ToolCapacity;
    const order = run_record.next_activity_order;
    var product_id_storage: [task_state.tool_product_id_capacity]u8 = undefined;
    const product_id = std.fmt.bufPrint(
        &product_id_storage,
        "tool-{d}",
        .{order},
    ) catch unreachable;
    const owned_id = (try context.effects.text.project(
        product_id,
        task_state.tool_product_id_capacity,
        &.{},
        0,
    )).value;
    errdefer context.effects.text.discardCandidate(owned_id);
    const owned_name = try context.effects.text.project(
        name,
        context.effects.max_tool_field_bytes,
        run_record.redaction_secret,
        0,
    );
    errdefer context.effects.text.discardCandidate(owned_name.value);
    const owned_input = try context.effects.text.project(
        input,
        context.effects.max_tool_field_bytes,
        run_record.redaction_secret,
        0,
    );
    errdefer context.effects.text.discardCandidate(owned_input.value);
    const progress = (try context.effects.text.project(
        "",
        context.effects.max_tool_field_bytes,
        &.{},
        0,
    )).value;
    errdefer context.effects.text.discardCandidate(progress);
    const content = (try context.effects.text.project(
        "",
        context.effects.max_tool_field_bytes,
        &.{},
        0,
    )).value;
    errdefer context.effects.text.discardCandidate(content);
    const refs = try context.runtime.allocator.alloc(
        ?task_state.FileReferenceView,
        context.effects.max_file_refs_per_tool,
    );
    errdefer context.runtime.allocator.free(refs);
    @memset(refs, null);
    run_record.tools[slot] = .{
        .route_digest = digest,
        .id = owned_id,
        .order = takeActivityOrder(run_record),
        .name = owned_name.value,
        .input = owned_input.value,
        .progress = progress,
        .content = content,
        .file_refs = refs,
        .state = .running,
        .input_truncated = owned_input.value.len < input.len,
        .redacted = owned_name.redacted or owned_input.redacted,
    };
    return &run_record.tools[slot].?;
}

fn replaceEventFileReferences(
    raw_context: *anyopaque,
    tool: *task_state.ToolView,
    envelope: *const agent.OwnedCoreEvent,
    credential: []const u8,
    task_id: u64,
    run_generation: u64,
) task_state.EventProjectionError!void {
    const context: *EventContext = @ptrCast(@alignCast(raw_context));
    const event = switch (envelope.event.value) {
        .unknown => unreachable,
        .known => |known| known,
    };
    const result = switch (event) {
        .tool_result => |value| value,
        else => unreachable,
    };
    const refs = if (comptime @hasField(@TypeOf(result), "file_refs"))
        result.file_refs
    else
        null;
    clearEventFileReferences(context, tool);
    const values = refs orelse return;
    if (values.len > context.effects.max_file_refs_per_tool)
        return error.ToolCapacity;
    if (tool.file_refs == null) {
        tool.file_refs = try context.runtime.allocator.alloc(
            ?task_state.FileReferenceView,
            context.effects.max_file_refs_per_tool,
        );
        @memset(tool.file_refs.?, null);
    }
    errdefer clearEventFileReferences(context, tool);
    for (values, 0..) |reference, index| {
        const locator_kind: task_state.FileReferenceLocatorKind = switch (reference.locator) {
            .workspace_path => .workspace_path,
            .absolute_path => .absolute_path,
            .uri => .uri,
        };
        const locator = switch (reference.locator) {
            .workspace_path => |value| value,
            .absolute_path => |value| value,
            .uri => |value| value,
        };
        if (locator.len > context.effects.max_file_ref_field_bytes or
            reference.title.len > context.effects.max_file_ref_field_bytes or
            reference.kind.len > context.effects.max_file_ref_field_bytes)
            return error.ToolCapacity;
        var id_storage: [96]u8 = undefined;
        const id = formatFileReferenceId(
            &id_storage,
            task_id,
            run_generation,
            tool.order,
            index + 1,
        );
        var owned = task_state.FileReferenceView{
            .id = undefined,
            .title = undefined,
            .display_path = undefined,
            .kind = undefined,
            .locator_kind = locator_kind,
            .locator = undefined,
            .range = if (reference.range) |range| .{
                .start = .{ .line = range.start.line, .column = range.start.column },
                .end = .{ .line = range.end.line, .column = range.end.column },
            } else null,
        };
        var id_live = false;
        var title_live = false;
        var display_live = false;
        var kind_live = false;
        var locator_live = false;
        errdefer {
            if (id_live) context.effects.text.discardCandidate(owned.id);
            if (title_live) context.effects.text.discardCandidate(owned.title);
            if (display_live) context.effects.text.discardCandidate(owned.display_path);
            if (kind_live) context.effects.text.discardCandidate(owned.kind);
            if (locator_live) context.effects.text.discardCandidate(owned.locator);
        }
        owned.id = (try context.effects.text.project(id, id.len, &.{}, 0)).value;
        id_live = true;
        const title = try context.effects.text.project(
            reference.title,
            context.effects.max_file_ref_field_bytes,
            credential,
            0,
        );
        owned.title = title.value;
        title_live = true;
        const display_source = if (locator_kind == .workspace_path)
            locator
        else if (reference.title.len != 0)
            reference.title
        else
            "file";
        const display = try context.effects.text.project(
            display_source,
            context.effects.max_file_ref_field_bytes,
            credential,
            0,
        );
        owned.display_path = display.value;
        display_live = true;
        const kind = try context.effects.text.project(
            reference.kind,
            context.effects.max_file_ref_field_bytes,
            credential,
            0,
        );
        owned.kind = kind.value;
        kind_live = true;
        owned.locator = (try context.effects.text.project(
            locator,
            context.effects.max_file_ref_field_bytes,
            &.{},
            0,
        )).value;
        locator_live = true;
        tool.file_refs.?[index] = owned;
        id_live = false;
        title_live = false;
        display_live = false;
        kind_live = false;
        locator_live = false;
        tool.redacted = tool.redacted or title.redacted or
            display.redacted or kind.redacted;
    }
}

fn clearEventFileReferences(context: *EventContext, tool: *task_state.ToolView) void {
    const refs = tool.file_refs orelse return;
    for (refs) |*entry| {
        if (entry.*) |*reference| {
            context.effects.text.discardCandidate(reference.id);
            context.effects.text.discardCandidate(reference.title);
            context.effects.text.discardCandidate(reference.display_path);
            context.effects.text.discardCandidate(reference.kind);
            context.effects.text.discardCandidate(reference.locator);
        }
        entry.* = null;
    }
}

fn recordEventFileChanges(
    raw_context: *anyopaque,
    run: *task_state.RunRecord,
    envelope: *const agent.OwnedCoreEvent,
    task_id: u64,
    workspace_root: []const u8,
) bool {
    const context: *EventContext = @ptrCast(@alignCast(raw_context));
    const event = switch (envelope.event.value) {
        .unknown => unreachable,
        .known => |known| known,
    };
    const observation = switch (event) {
        .file_changes => |value| value,
        else => unreachable,
    };
    var changed = false;
    if (observation.overflow or observation.lost)
        changed = markFileChangesIncomplete(run) or changed;
    for (observation.changes, 0..) |change, index| {
        const status: task_state.FileChangeStatus = switch (change.status) {
            .applied => .applied,
            .partial => .partial,
            .no_change, .failed, .rejected => continue,
        };
        const kind: task_state.FileChangeKind = switch (change.kind) {
            .created => .created,
            .modified => .modified,
            .deleted => .deleted,
            .moved => .moved,
        };
        const route_digest = fileChangeRouteDigest(observation.id, index);
        if (findFileChangeByRouteDigest(run.file_changes, route_digest) != null)
            continue;
        const slot = findEmptyFileChange(run.file_changes) orelse {
            changed = markFileChangesIncomplete(run) or changed;
            break;
        };
        var path_storage: [4096]u8 = undefined;
        const display_path = normalizedFileChangePath(
            change.locator,
            workspace_root,
            &path_storage,
        ) orelse {
            changed = markFileChangesIncomplete(run) or changed;
            continue;
        };
        var from_storage: [4096]u8 = undefined;
        const from_display_path = if (kind == .moved) blk: {
            const from = change.from_locator orelse {
                changed = markFileChangesIncomplete(run) or changed;
                continue;
            };
            break :blk normalizedFileChangePath(
                from,
                workspace_root,
                &from_storage,
            ) orelse {
                changed = markFileChangesIncomplete(run) or changed;
                continue;
            };
        } else null;
        const order = run.next_activity_order;
        var id_storage: [task_state.file_change_product_id_capacity]u8 = undefined;
        const product_id = std.fmt.bufPrint(
            &id_storage,
            "change-{d}-{d}-{d}",
            .{ task_id, run.generation, order },
        ) catch unreachable;
        var owned_id: ?[]u8 = null;
        var owned_path: ?[]u8 = null;
        var owned_from: ?[]u8 = null;
        const id_projection = context.effects.text.project(
            product_id,
            product_id.len,
            &.{},
            0,
        ) catch {
            changed = markFileChangesIncomplete(run) or changed;
            continue;
        };
        owned_id = id_projection.value;
        const path_projection = context.effects.text.project(
            display_path,
            context.effects.max_file_change_field_bytes,
            run.redaction_secret,
            0,
        ) catch {
            context.effects.text.discardCandidate(owned_id.?);
            changed = markFileChangesIncomplete(run) or changed;
            continue;
        };
        owned_path = path_projection.value;
        if (path_projection.truncated) {
            context.effects.text.discardCandidate(owned_path.?);
            context.effects.text.discardCandidate(owned_id.?);
            changed = markFileChangesIncomplete(run) or changed;
            continue;
        }
        var from_redacted = false;
        if (from_display_path) |from| {
            const from_projection = context.effects.text.project(
                from,
                context.effects.max_file_change_field_bytes,
                run.redaction_secret,
                0,
            ) catch {
                context.effects.text.discardCandidate(owned_path.?);
                context.effects.text.discardCandidate(owned_id.?);
                changed = markFileChangesIncomplete(run) or changed;
                continue;
            };
            owned_from = from_projection.value;
            if (from_projection.truncated) {
                context.effects.text.discardCandidate(owned_from.?);
                context.effects.text.discardCandidate(owned_path.?);
                context.effects.text.discardCandidate(owned_id.?);
                changed = markFileChangesIncomplete(run) or changed;
                continue;
            }
            from_redacted = from_projection.redacted;
        }
        run.file_changes[slot] = .{
            .route_digest = route_digest,
            .id = owned_id.?,
            .order = takeActivityOrder(run),
            .kind = kind,
            .status = status,
            .display_path = owned_path.?,
            .from_display_path = owned_from,
            .before_bytes = change.before_bytes,
            .after_bytes = change.after_bytes,
            .diff_complete = change.diff_complete,
            .redacted = path_projection.redacted or from_redacted,
        };
        std.debug.assert(run.file_changes[slot].?.order == order);
        if (change.unified_diff) |diff| if (diff.len != 0) {
            switch (context.effects.file_change_diff.enqueue(
                task_id,
                run.generation,
                order,
                diff,
            )) {
                .queued => |queued| {
                    run.pending_file_change_artifacts += 1;
                    run.file_changes[slot].?.redacted =
                        run.file_changes[slot].?.redacted or queued.redacted;
                },
                .unavailable => changed = markFileChangesIncomplete(run) or changed,
            }
        };
        changed = true;
    }
    return changed;
}

fn markFileChangesIncomplete(run: *task_state.RunRecord) bool {
    run.file_changes_known_loss = true;
    if (run.file_change_observation == .incomplete) return false;
    run.file_change_observation = .incomplete;
    return true;
}

fn fileChangeRouteDigest(
    event_id: []const u8,
    index: usize,
) [task_state.file_change_route_digest_bytes]u8 {
    var digest = std.crypto.hash.sha2.Sha256.init(.{});
    digest.update(event_id);
    digest.update(&.{0});
    var index_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &index_bytes, @intCast(index), .big);
    digest.update(&index_bytes);
    var result: [task_state.file_change_route_digest_bytes]u8 = undefined;
    digest.final(&result);
    return result;
}

fn findFileChangeByRouteDigest(
    changes: []?task_state.FileChangeView,
    digest: [task_state.file_change_route_digest_bytes]u8,
) ?*task_state.FileChangeView {
    for (changes) |*entry| if (entry.*) |*change|
        if (std.mem.eql(u8, &change.route_digest, &digest)) return change;
    return null;
}

fn findEmptyFileChange(changes: []?task_state.FileChangeView) ?usize {
    for (changes, 0..) |entry, index| if (entry == null) return index;
    return null;
}

fn normalizedFileChangePath(
    locator: anytype,
    workspace_root: []const u8,
    storage: []u8,
) ?[]const u8 {
    const source = switch (locator) {
        .workspace_path => |path| path,
        .absolute_path => |absolute| absoluteInsideWorkspace(
            workspace_root,
            absolute,
        ) orelse return null,
        .uri => return null,
    };
    if (source.len == 0 or source.len > storage.len or std.fs.path.isAbsolute(source))
        return null;
    var written: usize = 0;
    var component_start: usize = 0;
    var index: usize = 0;
    while (index <= source.len) : (index += 1) {
        if (index != source.len and source[index] != '/' and source[index] != '\\')
            continue;
        const component = source[component_start..index];
        if (component.len == 0 or std.mem.eql(u8, component, ".") or
            std.mem.eql(u8, component, "..") or
            std.mem.indexOfScalar(u8, component, 0) != null or
            (@import("builtin").os.tag == .windows and
                std.mem.indexOfScalar(u8, component, ':') != null))
            return null;
        if (written != 0) {
            if (written == storage.len) return null;
            storage[written] = '/';
            written += 1;
        }
        if (component.len > storage.len - written) return null;
        @memcpy(storage[written..][0..component.len], component);
        written += component.len;
        component_start = index + 1;
    }
    return storage[0..written];
}

fn absoluteInsideWorkspace(root: []const u8, absolute: []const u8) ?[]const u8 {
    if (!std.fs.path.isAbsolute(absolute)) return null;
    var root_len = root.len;
    while (root_len > 1 and (root[root_len - 1] == '/' or root[root_len - 1] == '\\'))
        root_len -= 1;
    if (absolute.len <= root_len) return null;
    for (root[0..root_len], absolute[0..root_len]) |left, right| {
        const same_separator = (left == '/' or left == '\\') and
            (right == '/' or right == '\\');
        const same = if (@import("builtin").os.tag == .windows)
            std.ascii.toLower(left) == std.ascii.toLower(right)
        else
            left == right;
        if (!same and !same_separator) return null;
    }
    if (absolute[root_len] != '/' and absolute[root_len] != '\\') return null;
    return absolute[root_len + 1 ..];
}

fn findEmptyTool(entries: []?task_state.ToolView) ?usize {
    for (entries, 0..) |entry, index| if (entry == null) return index;
    return null;
}

fn toolRouteDigest(id: []const u8) [task_state.tool_route_digest_bytes]u8 {
    var digest: [task_state.tool_route_digest_bytes]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(id, &digest, .{});
    return digest;
}

fn findToolByRouteDigest(
    tools: []?task_state.ToolView,
    digest: [task_state.tool_route_digest_bytes]u8,
) ?*task_state.ToolView {
    for (tools) |*entry| if (entry.*) |*tool|
        if (std.mem.eql(u8, &tool.route_digest, &digest)) return tool;
    return null;
}

fn formatFileReferenceId(
    storage: []u8,
    task_id: u64,
    run_generation: u64,
    tool_order: u64,
    index: usize,
) []const u8 {
    return std.fmt.bufPrint(
        storage,
        "file-{d}-{d}-{d}-{d}",
        .{ task_id, run_generation, tool_order, index },
    ) catch unreachable;
}

fn redactTrackedText(target: *task_state.TrackedText, credential: []const u8) bool {
    std.debug.assert(target.committed_len <= target.list.items.len);
    if (credential.len == 0) {
        target.committed_len = target.list.items.len;
        return false;
    }
    var read = target.committed_len;
    var write = target.committed_len;
    var redacted = false;
    while (read < target.list.items.len) {
        const value = target.list.items;
        if (credentialEndAtCodepoint(value, read, credential)) |redaction_end| {
            const marker_len = @min(redaction_end - read, 3);
            @memset(target.list.items[write..][0..marker_len], '*');
            write += marker_len;
            read = redaction_end;
            redacted = true;
            continue;
        }
        if (credentialMayContinueAtCodepoint(value, read, credential)) {
            const remaining = value[read..];
            std.mem.copyForwards(
                u8,
                target.list.items[write..][0..remaining.len],
                remaining,
            );
            target.list.items.len = write + remaining.len;
            target.committed_len = write;
            return redacted;
        }
        const codepoint_len = utf8CodepointLen(value, read);
        std.mem.copyForwards(
            u8,
            target.list.items[write..][0..codepoint_len],
            value[read..][0..codepoint_len],
        );
        write += codepoint_len;
        read += codepoint_len;
    }
    target.list.items.len = write;
    target.committed_len = write;
    return redacted;
}

fn utf8CodepointLen(value: []const u8, start: usize) usize {
    return @min(
        std.unicode.utf8ByteSequenceLength(value[start]) catch 1,
        value.len - start,
    );
}

fn credentialEndAtCodepoint(
    value: []const u8,
    codepoint_start: usize,
    credential: []const u8,
) ?usize {
    if (credential.len == 0) return null;
    const codepoint_len = utf8CodepointLen(value, codepoint_start);
    var match_end: usize = 0;
    for (0..codepoint_len) |offset| {
        if (std.mem.startsWith(u8, value[codepoint_start + offset ..], credential))
            match_end = @max(match_end, codepoint_start + offset + credential.len);
    }
    if (match_end == 0) return null;
    var end = @min(value.len, match_end);
    while (end < value.len and value[end] & 0xc0 == 0x80) end += 1;
    return end;
}

fn credentialMayContinueAtCodepoint(
    value: []const u8,
    codepoint_start: usize,
    credential: []const u8,
) bool {
    if (credential.len == 0) return false;
    const codepoint_len = utf8CodepointLen(value, codepoint_start);
    for (0..codepoint_len) |offset| {
        const remaining = value[codepoint_start + offset ..];
        if (remaining.len < credential.len and
            std.mem.startsWith(u8, credential, remaining)) return true;
    }
    return false;
}

fn releaseExecutionValueNoFail(
    task: *task_state.Task,
    execution: anytype,
    effects: ReleaseEffects,
) void {
    const credential = execution.input().api_key;
    effects.redactAll(credential);
    for (task.durable.runs) |*entry| {
        const run = &(entry.* orelse continue);
        run.redaction_secret = &.{};
    }
    for (task.durable.compacts) |*entry| {
        const compact = &(entry.* orelse continue);
        compact.redaction_secret = &.{};
    }
    execution.deinit();
}

fn releaseProjectedSlice(
    self: *Runtime,
    effects: ReleaseEffects,
    value: []u8,
) void {
    effects.releaseProjectionBytes(value.len);
    self.allocator.free(value);
}

fn deinitCreateCandidate(
    self: *Runtime,
    candidate: *CreateCandidate,
    effects: ReleaseEffects,
) void {
    switch (candidate.binding.state()) {
        .owned => {
            switch (candidate.binding.closeOutcome(.session_close)) {
                .closed => {},
                .failure => @panic("fresh Task Session close failed during create rollback"),
            }
            candidate.binding.releaseClosed() catch |err| {
                if (err == error.RuntimeShuttingDown)
                    candidate.binding.abandonForRuntimeDeinit()
                else
                    @panic("fresh Task Session release failed during create rollback");
            };
        },
        .closed => candidate.binding.releaseClosed() catch
            candidate.binding.abandonForRuntimeDeinit(),
        .released, .relinquished, .moved, .fixture, .abandoned => {},
    }
    const credential = candidate.execution.input().api_key;
    effects.redactAll(credential);
    candidate.execution.deinit();
    if (candidate.pinned_catalog) |*catalog| {
        effects.releaseProjectionBytes(catalog.projected_bytes);
        catalog.deinit();
    }
    releaseProjectedSlice(self, effects, candidate.execution_model);
    releaseProjectedSlice(self, effects, candidate.workspace_root);
    releaseProjectedSlice(self, effects, candidate.title);
    candidate.* = undefined;
}

fn releaseTrackedText(
    self: *Runtime,
    effects: ReleaseEffects,
    value: *task_state.TrackedText,
) void {
    effects.releaseProjectionBytes(value.list.capacity);
    value.list.deinit(self.allocator);
    value.* = undefined;
}

fn deinitFileReference(
    self: *Runtime,
    effects: ReleaseEffects,
    reference: *task_state.FileReferenceView,
) void {
    releaseProjectedSlice(self, effects, reference.id);
    releaseProjectedSlice(self, effects, reference.title);
    releaseProjectedSlice(self, effects, reference.display_path);
    releaseProjectedSlice(self, effects, reference.kind);
    releaseProjectedSlice(self, effects, reference.locator);
    reference.* = undefined;
}

fn deinitFileChange(
    self: *Runtime,
    effects: ReleaseEffects,
    change: *task_state.FileChangeView,
) void {
    releaseProjectedSlice(self, effects, change.id);
    releaseProjectedSlice(self, effects, change.display_path);
    if (change.from_display_path) |path|
        releaseProjectedSlice(self, effects, path);
    change.* = undefined;
}

fn deinitTool(
    self: *Runtime,
    effects: ReleaseEffects,
    tool: *task_state.ToolView,
) void {
    releaseProjectedSlice(self, effects, tool.id);
    releaseProjectedSlice(self, effects, tool.name);
    releaseProjectedSlice(self, effects, tool.input);
    releaseProjectedSlice(self, effects, tool.progress);
    releaseProjectedSlice(self, effects, tool.content);
    if (tool.file_refs) |refs| {
        for (refs) |*entry| if (entry.*) |*reference|
            deinitFileReference(self, effects, reference);
        self.allocator.free(refs);
    }
    tool.* = undefined;
}

fn deinitRunInput(
    self: *Runtime,
    effects: ReleaseEffects,
    input: *task_state.RunInputRecord,
) void {
    switch (input.*) {
        .text => |text| releaseProjectedSlice(self, effects, text.value),
        .multimodal => |multimodal| {
            if (multimodal.text) |text| releaseProjectedSlice(self, effects, text);
            for (multimodal.attachments) |item|
                releaseProjectedSlice(self, effects, item.display_name);
            self.allocator.free(multimodal.attachments);
        },
        .skill => |skill| {
            releaseProjectedSlice(self, effects, skill.skill_id);
            releaseProjectedSlice(self, effects, skill.catalog_revision);
            releaseProjectedSlice(self, effects, skill.invocation_name);
            releaseProjectedSlice(self, effects, skill.display_name);
            for (skill.argument_values) |value|
                releaseProjectedSlice(self, effects, value);
            self.allocator.free(skill.argument_values);
        },
    }
    input.* = undefined;
}

fn releaseAutomaticTitle(title: *task_state.AutomaticTitle) void {
    std.debug.assert(title.state.load(.acquire) != .running);
    std.crypto.secureZero(u8, &title.result);
    title.state.store(.settled, .release);
}

fn cancelTaskCheckpoints(task: *task_state.Task) void {
    for (task.durable.runs) |*entry| {
        const run = &(entry.* orelse continue);
        switch (run.checkpoint.state.load(.acquire)) {
            .none, .exporting => run.checkpoint.cancelled.store(true, .release),
            else => {},
        }
    }
    for (task.durable.compacts) |*entry| {
        const compact = &(entry.* orelse continue);
        switch (compact.checkpoint.state.load(.acquire)) {
            .none, .exporting => compact.checkpoint.cancelled.store(true, .release),
            else => {},
        }
    }
}

fn checkpointMutationPending(
    task: *const task_state.Task,
    health: *const std.atomic.Value(checkpoint_store.Health),
) bool {
    return health.load(.acquire) != .unavailable and
        task.runtime.worker_leases.hasLive();
}

fn taskExecutionInput(
    task: *const task_state.Task,
) error{ ExecutionUnavailable, ExecutionGenerationMismatch }!models_contract.ConfigInput {
    const execution = task.runtime.executionConst() orelse
        return error.ExecutionUnavailable;
    const input = execution.input();
    if (input.execution_generation != task.durable.execution_generation or
        input.target.protocol != task.durable.execution_protocol)
        return error.ExecutionGenerationMismatch;
    return input;
}

const AgentSessionPermission = struct {
    mode: agent.PermissionMode,
    shell: agent.ShellPolicy,
    interaction: agent.PermissionInteraction,
};

/// The sole Product compiler from an admitted MetaWork profile to AgentCore
/// execution configuration. Fresh create and checkpoint restore both consume
/// this function; callers must not reconstruct the mapping independently.
fn agentSessionPermission(
    profile: task_state.PermissionProfile,
    interaction: task_state.PermissionInteraction,
) AgentSessionPermission {
    return .{
        .mode = switch (profile) {
            .approval_required => .accept_edits,
            .full_access => .full_access,
        },
        .shell = .unrestricted,
        .interaction = switch (interaction) {
            .interactive => .interactive,
            .noninteractive => .noninteractive,
        },
    };
}

fn validateRunInput(
    task: *const task_state.Task,
    input: RunInput,
    limits: OperationLimits,
) RunError!agent.RunInput {
    return switch (input) {
        .text => |value| .{ .text = value },
        .multimodal => |multimodal| blk: {
            if (multimodal.attachments.len == 0) return error.InvalidRunInput;
            var parts: [agent.multimodal_input_limits.max_parts]agent.InputPart = undefined;
            var part_count: usize = 0;
            if (multimodal.text.len != 0) {
                parts[part_count] = .{ .text = multimodal.text };
                part_count += 1;
            }
            if (multimodal.attachments.len > parts.len - part_count)
                return error.RunInputTooLarge;
            for (multimodal.attachments) |item| {
                parts[part_count] = switch (item.kind) {
                    .image => .{ .image = .{
                        .format = switch (item.format) {
                            .png => .png,
                            .jpeg => .jpeg,
                            .webp => .webp,
                        },
                        .bytes = item.bytes,
                    } },
                };
                part_count += 1;
            }
            break :blk .{ .multimodal = parts[0..part_count] };
        },
        .skill => |skill_input| blk: {
            const pinned = task.runtime.pinnedCatalogConst() orelse
                return error.CatalogUnavailable;
            if (!std.mem.eql(u8, skill_input.catalog_revision, pinned.revision) or
                skill_input.selection_revision != pinned.selection_revision)
                return error.StaleCatalog;
            const skill = pinned.findSkill(skill_input.skill_id) orelse
                return error.SkillNotFound;
            if (!skill.enabled) return error.SkillUnavailable;
            if (skill_input.argument_values.len > @min(
                @as(usize, @intCast(skill.max_values)),
                limits.max_skill_arguments,
            )) return error.InvalidSkillArguments;
            var bytes = std.math.add(
                usize,
                skill.skill_id.len,
                pinned.revision.len,
            ) catch return error.ProjectionCapacity;
            if (bytes > limits.max_user_message_bytes)
                return error.ProjectionCapacity;
            for (skill_input.argument_values) |value| {
                if (!std.unicode.utf8ValidateSlice(value))
                    return error.InvalidSkillArguments;
                bytes = std.math.add(usize, bytes, value.len) catch
                    return error.ProjectionCapacity;
                if (bytes > limits.max_user_message_bytes)
                    return error.ProjectionCapacity;
            }
            break :blk .{ .skill = .{
                .skill_id = skill.skill_id,
                .catalog_revision = pinned.revision,
                .argument_values = skill_input.argument_values,
            } };
        },
    };
}

fn copyRunInput(
    self: *Runtime,
    task: *const task_state.Task,
    input: RunInput,
    credential: []const u8,
    effects: OperationEffects,
) RunError!task_state.RunInputRecord {
    return switch (input) {
        .text => |value| blk: {
            if (value.len > effects.limits.max_user_message_bytes)
                return error.ProjectionCapacity;
            const projected = try effects.text.project(
                value,
                effects.limits.max_user_message_bytes,
                credential,
                0,
            );
            break :blk .{ .text = .{
                .value = projected.value,
                .redacted = projected.redacted,
            } };
        },
        .multimodal => |multimodal| blk: {
            if (multimodal.text.len > effects.limits.max_user_message_bytes)
                return error.ProjectionCapacity;
            var text: ?[]u8 = null;
            var redacted = false;
            if (multimodal.text.len != 0) {
                const projected = try effects.text.project(
                    multimodal.text,
                    effects.limits.max_user_message_bytes,
                    credential,
                    0,
                );
                text = projected.value;
                redacted = projected.redacted;
            }
            errdefer if (text) |value| effects.text.discardCandidate(value);
            const records = try self.allocator.alloc(
                task_state.AttachmentRecord,
                multimodal.attachments.len,
            );
            errdefer self.allocator.free(records);
            var initialized: usize = 0;
            errdefer for (records[0..initialized]) |record|
                effects.text.discardCandidate(record.display_name);
            for (multimodal.attachments, records) |item, *record| {
                const display = try effects.text.project(
                    item.display_name,
                    effects.limits.max_tool_field_bytes,
                    credential,
                    0,
                );
                record.* = .{
                    .kind = item.kind,
                    .format = item.format,
                    .display_name = display.value,
                    .size_bytes = item.bytes.len,
                    .redacted = display.redacted,
                };
                initialized += 1;
                redacted = redacted or display.redacted;
            }
            break :blk .{ .multimodal = .{
                .text = text,
                .attachments = records,
                .redacted = redacted,
            } };
        },
        .skill => |skill_input| blk: {
            const pinned = task.runtime.pinnedCatalogConst() orelse
                return error.CatalogUnavailable;
            if (!std.mem.eql(u8, skill_input.catalog_revision, pinned.revision) or
                skill_input.selection_revision != pinned.selection_revision)
                return error.StaleCatalog;
            const skill = pinned.findSkill(skill_input.skill_id) orelse
                return error.SkillNotFound;
            if (!skill.enabled) return error.SkillUnavailable;
            const skill_id = (try effects.text.project(
                skill.skill_id,
                effects.limits.max_catalog_projection_bytes,
                &.{},
                0,
            )).value;
            errdefer effects.text.discardCandidate(skill_id);
            const revision = (try effects.text.project(
                pinned.revision,
                effects.limits.max_catalog_projection_bytes,
                &.{},
                0,
            )).value;
            errdefer effects.text.discardCandidate(revision);
            const invocation = try effects.text.project(
                skill.invocation_name,
                effects.limits.max_catalog_projection_bytes,
                credential,
                0,
            );
            errdefer effects.text.discardCandidate(invocation.value);
            const display = try effects.text.project(
                skill.display_name,
                effects.limits.max_catalog_projection_bytes,
                credential,
                0,
            );
            errdefer effects.text.discardCandidate(display.value);
            const values = try self.allocator.alloc(
                []u8,
                skill_input.argument_values.len,
            );
            errdefer self.allocator.free(values);
            var initialized: usize = 0;
            var redacted = invocation.redacted or display.redacted;
            errdefer for (values[0..initialized]) |value|
                effects.text.discardCandidate(value);
            for (skill_input.argument_values, values) |value, *target| {
                const projected = try effects.text.project(
                    value,
                    effects.limits.max_user_message_bytes,
                    credential,
                    0,
                );
                target.* = projected.value;
                initialized += 1;
                redacted = redacted or projected.redacted;
            }
            break :blk .{ .skill = .{
                .skill_id = skill_id,
                .catalog_revision = revision,
                .invocation_name = invocation.value,
                .display_name = display.value,
                .argument_values = values,
                .redacted = redacted,
            } };
        },
    };
}

fn reserveRun(
    self: *Runtime,
    task: *task_state.Task,
    input: RunInput,
    effects: OperationEffects,
) RunError!usize {
    const execution = try taskExecutionInput(task);
    const slot = findEmptyRun(task.durable.runs) orelse return error.RunCapacity;
    if (task.durable.next_run_generation == std.math.maxInt(u64))
        return error.RunGenerationExhausted;
    var input_record = try copyRunInput(self, task, input, execution.api_key, effects);
    errdefer deinitRunInput(self, effects.release, &input_record);
    const tools = try self.allocator.alloc(
        ?task_state.ToolView,
        effects.limits.max_tools_per_run,
    );
    errdefer self.allocator.free(tools);
    @memset(tools, null);
    const commentary_ends = try self.allocator.alloc(
        u64,
        effects.limits.max_commentary_segments_per_run,
    );
    errdefer self.allocator.free(commentary_ends);
    const file_changes = try self.allocator.alloc(
        ?task_state.FileChangeView,
        effects.limits.max_file_changes_per_run,
    );
    errdefer self.allocator.free(file_changes);
    @memset(file_changes, null);
    const diagnostic = try effects.text.allocateCapacity(
        effects.limits.max_terminal_diagnostic_bytes,
    );
    errdefer effects.text.discardCandidate(diagnostic);
    const execution_model = (try effects.text.project(
        task.durable.execution_model,
        effects.limits.max_model_id_bytes,
        &.{},
        0,
    )).value;
    errdefer effects.text.discardCandidate(execution_model);
    task.durable.next_run_generation += 1;
    var title = task_state.AutomaticTitle{};
    if (task.durable.next_run_generation == 1 and task.durable.title.len == 0)
        title.state.store(.pending, .release);
    task.durable.runs[slot] = .{
        .id = 0,
        .generation = task.durable.next_run_generation,
        .execution_generation = task.durable.execution_generation,
        .execution_protocol = task.durable.execution_protocol,
        .execution_model = execution_model,
        .execution_model_owned = true,
        .permission_profile = task.durable.permission_profile,
        .permission_interaction = task.durable.permission_interaction,
        .input = input_record,
        .commentary_ends = commentary_ends,
        .tools = tools,
        .file_change_observation = .collecting,
        .file_changes = file_changes,
        .terminal_diagnostic = diagnostic,
        .redaction_secret = execution.api_key,
        .automatic_title = title,
    };
    return slot;
}

fn findEmptyRun(entries: []?task_state.RunRecord) ?usize {
    for (entries, 0..) |entry, index| if (entry == null) return index;
    return null;
}

fn findEmptyCompact(entries: []?task_state.CompactRecord) ?usize {
    for (entries, 0..) |entry, index| if (entry == null) return index;
    return null;
}

fn discardCompact(
    self: *Runtime,
    task: *task_state.Task,
    slot: usize,
    release: ReleaseEffects,
) void {
    const compact = &(task.durable.compacts[slot] orelse return);
    deinitCompact(self, release, compact);
    task.durable.compacts[slot] = null;
}

fn discardRun(
    self: *Runtime,
    task: *task_state.Task,
    slot: usize,
    release: ReleaseEffects,
) void {
    const run_record = &(task.durable.runs[slot] orelse return);
    deinitRun(self, release, run_record);
    task.durable.runs[slot] = null;
}

fn applyProvisionalTitle(
    task: *task_state.Task,
    run_record: *const task_state.RunRecord,
    max_title_bytes: usize,
    text: TextProjection,
    credential: []const u8,
) bool {
    if (task.durable.title.len != 0 or run_record.generation != 1) return false;
    const candidate = task_policy.automaticTitleCandidate(&run_record.input) orelse
        return false;
    const previous = task.durable.title;
    const projected = text.project(
        task_policy.boundAutomaticTitle(candidate),
        max_title_bytes,
        credential,
        previous.len,
    ) catch return false;
    if (projected.value.len == 0) {
        text.discardCandidate(projected.value);
        text.restorePrevious(previous.len);
        return false;
    }
    task.durable.title = projected.value;
    task.durable.title_redacted = projected.redacted;
    return true;
}

fn applyPendingModel(
    self: *Runtime,
    task: *task_state.Task,
    access: *task_agent_session.Access,
    effects: OperationEffects,
) RunError!void {
    const pending = task.runtime.pending_model orelse return;
    const previous = task.durable.execution_model;
    try access.setModel(pending);
    const replacement = effects.text.project(
        pending,
        effects.limits.max_model_id_bytes,
        &.{},
        previous.len,
    ) catch |err| {
        access.setModel(previous) catch {
            if (task.runtime.attached()) |attached|
                attached.health = .session_poisoned;
            return error.TaskClosing;
        };
        return err;
    };
    task.durable.execution_model = replacement.value;
    task.runtime.pending_model = null;
    effects.text.discardPrevious(previous);
    self.allocator.free(pending);
}

fn cancelTaskAutomaticTitles(task: *task_state.Task) void {
    for (task.durable.runs) |*entry| {
        const run = &(entry.* orelse continue);
        run.automatic_title.cancel_requested.store(true, .release);
        task_execution.publishAutomaticTitleFallback(run);
    }
}

fn requestRunTermination(
    run: *task_state.RunRecord,
    interruption: agent.ExternalInterruption,
) task_state.RunTerminationDispatch {
    const pending = task_policy.pendingInterruption(interruption);
    _ = run.pending_termination.cmpxchgStrong(
        .none,
        pending,
        .acq_rel,
        .acquire,
    );
    switch (run.agent_handoff.load(.acquire)) {
        .queued, .starting => return .pending,
        .finishing => return .already_finishing,
        .running => {},
    }
    const lease_value = run.run_control.tryAcquireLease() orelse
        return .already_finishing;
    var lease = lease_value;
    defer lease.deinit();
    return switch (lease.requestTermination(task_policy.pendingTerminationSignal(run))) {
        .requested => .requested,
        .already_requested => .already_requested,
        .already_terminal => .already_terminal,
        .stale_run => .stale_run,
        .session_closing => .session_closing,
    };
}

fn requestPermissionTermination(
    run: *task_state.RunRecord,
) task_state.RunTerminationDispatch {
    switch (run.agent_handoff.load(.acquire)) {
        .queued, .starting => return .pending,
        .finishing => return .already_finishing,
        .running => {},
    }
    const lease_value = run.run_control.tryAcquireLease() orelse
        return .already_finishing;
    var lease = lease_value;
    defer lease.deinit();
    return switch (lease.requestTermination(.permission_required)) {
        .requested => .requested,
        .already_requested => .already_requested,
        .already_terminal => .already_terminal,
        .stale_run => .stale_run,
        .session_closing => .session_closing,
    };
}

fn closeWorker(
    completion_out: *std.atomic.Value(task_attachment.CloseCompletion),
    binding: *task_agent_session.Binding,
    notifier: task_execution.Notifier,
) void {
    const completion: task_attachment.CloseCompletion = close: {
        switch (binding.state()) {
            .owned => switch (binding.closeOutcome(.session_close)) {
                .closed => {},
                .failure => |failure| break :close task_policy.closeFailureCompletion(
                    failure.session_disposition,
                ),
            },
            .closed => {},
            .released, .relinquished, .moved, .fixture, .abandoned => unreachable,
        }
        binding.releaseClosed() catch break :close .failed_closing;
        break :close .closed;
    };
    completion_out.store(completion, .release);
    notifier.notify();
}

fn cancelCompactRecord(
    self: *Runtime,
    task: *task_state.Task,
    compact: *task_state.CompactRecord,
    interruption: agent.ExternalInterruption,
    effects: OperationEffects,
) ControlError!task_state.CompactTerminationDispatch {
    if (task_state.compactTerminalPayload(compact) != null)
        return .already_terminal;
    const pending = task_policy.pendingInterruption(interruption);
    const prior = compact.pending_interruption.cmpxchgStrong(
        .none,
        pending,
        .acq_rel,
        .acquire,
    );
    if (task_state.compactTerminalPayload(compact) != null)
        return .already_terminal;
    if (effects.executor.cancel(compact)) {
        task.durable.recent_order = self.takeRecentOrder();
        return .queued_aborted;
    }
    var access = task.runtime.acquireAccess() catch return .session_closing;
    defer access.deinit();
    access.requestCompactCancellation(
        compact.id,
        task_policy.pendingExternalInterruption(compact),
    ) catch |err| switch (err) {
        error.NoSuchCompact => return .already_terminal,
        error.SessionClosing => return .session_closing,
    };
    task.durable.recent_order = self.takeRecentOrder();
    return if (prior == null) .requested else .already_requested;
}

fn poisonAttachment(task: *task_state.Task) void {
    if (task.runtime.attached()) |attached|
        attached.health = .session_poisoned;
}

fn prepareUiRecord(
    self: *Runtime,
    access: *task_agent_session.Access,
    run_id: u64,
    request_id: u64,
    response: UiResponse,
    credential: []const u8,
) task_state.UiRecord {
    var record = task_state.UiRecord{
        .request_id = request_id,
        .run_id = run_id,
        .kind = kindForResponse(response),
        .state = stateForResponse(response),
    };
    var pending = access.copyPendingUiRequest(self.allocator) catch return record;
    defer pending.deinit();
    if (pending.run_id != run_id or pending.request_id != request_id) return record;
    var parsed = agent.decodePermissionRequest(self.allocator, pending.json) catch
        return record;
    defer parsed.deinit();
    fillUiRecord(&record, parsed.value(), credential);
    return record;
}

fn prepareCancelledUiRecord(
    self: *Runtime,
    access: *task_agent_session.Access,
    run_id: u64,
    credential: []const u8,
) ?task_state.UiRecord {
    if (run_id == 0) return null;
    var pending = access.copyPendingUiRequest(self.allocator) catch return null;
    defer pending.deinit();
    if (pending.run_id != run_id) return null;
    var parsed = agent.decodePermissionRequest(self.allocator, pending.json) catch
        return null;
    defer parsed.deinit();
    var record = task_state.UiRecord{
        .request_id = pending.request_id,
        .run_id = run_id,
        .kind = .permission,
        .state = .cancelled,
    };
    fillUiRecord(&record, parsed.value(), credential);
    return record;
}

fn fillUiRecord(
    record: *task_state.UiRecord,
    permission: agent.PermissionRequest,
    credential: []const u8,
) void {
    if (permission.request_id.len <= task_state.permission_summary_field_capacity) {
        @memcpy(
            record.agent_request_id[0..permission.request_id.len],
            permission.request_id,
        );
        record.agent_request_id_len = permission.request_id.len;
    }
    const projected = task_execution.projectSanitized(
        &record.detail,
        permission.arguments_json,
        credential,
    );
    record.detail_len = projected.len;
    record.detail_truncated = projected.truncated;
    record.redacted = projected.redacted;
}

fn pushUiRecord(task: *task_state.Task, record: task_state.UiRecord) void {
    for (task.durable.ui_history) |entry| if (entry) |existing|
        if (existing.request_id == record.request_id) return;
    var stored = record;
    if (stored.permission == null and stored.agent_request_id_len != 0) {
        if (task_state.findRun(task.durable.runs, stored.run_id)) |run_record| {
            if (run_record.permission_provenance) |summary| {
                if (std.mem.eql(
                    u8,
                    stored.agent_request_id[0..stored.agent_request_id_len],
                    summary.requestId(),
                )) stored.permission = summary;
            }
        }
    }
    if (task.runtime.pending_ui_request_id == stored.request_id and
        task.runtime.pending_ui_order != 0)
    {
        stored.order = task.runtime.pending_ui_order;
        task.runtime.pending_ui_request_id = 0;
        task.runtime.pending_ui_order = 0;
    } else {
        const run_record = task_state.findRun(
            task.durable.runs,
            stored.run_id,
        ) orelse unreachable;
        stored.order = takeActivityOrder(run_record);
    }
    task.durable.ui_history[task.durable.ui_history_next] = stored;
    task.durable.ui_history_next =
        (task.durable.ui_history_next + 1) % task.durable.ui_history.len;
    task.durable.ui_history_count = @min(
        task.durable.ui_history_count + 1,
        task.durable.ui_history.len,
    );
}

fn rollbackUiRecord(
    task: *task_state.Task,
    run_record: *task_state.RunRecord,
    history_slot: usize,
    previous_record: ?task_state.UiRecord,
    previous_next: usize,
    previous_count: usize,
    previous_request_id: u64,
    previous_pending_order: u64,
    previous_activity_order: u64,
    previous_recent_order: u64,
) void {
    task.durable.ui_history[history_slot] = previous_record;
    task.durable.ui_history_next = previous_next;
    task.durable.ui_history_count = previous_count;
    task.runtime.pending_ui_request_id = previous_request_id;
    task.runtime.pending_ui_order = previous_pending_order;
    run_record.next_activity_order = previous_activity_order;
    task.durable.recent_order = previous_recent_order;
}

fn permissionChoice(choice: PermissionChoice) agent.PermissionChoice {
    return switch (choice) {
        .allow_once => .allow_once,
        .allow_session => .allow_session,
        .deny_once => .deny_once,
        .deny_session => .deny_session,
    };
}

fn kindForResponse(response: UiResponse) task_state.UiRecordKind {
    _ = response;
    return .permission;
}

fn stateForResponse(response: UiResponse) task_state.UiRecordState {
    return switch (response.permission) {
        .allow_once => .allowed_once,
        .allow_session => .allowed_always,
        .deny_once => .denied,
        .deny_session => .denied_session,
    };
}

fn deinitRun(
    self: *Runtime,
    effects: ReleaseEffects,
    run: *task_state.RunRecord,
) void {
    std.debug.assert(run.checkpoint.lease == null);
    releaseAutomaticTitle(&run.automatic_title);
    for (run.tools) |*entry| if (entry.*) |*tool|
        deinitTool(self, effects, tool);
    self.allocator.free(run.tools);
    for (run.file_changes) |*entry| if (entry.*) |*change|
        deinitFileChange(self, effects, change);
    if (run.file_changes.len != 0) self.allocator.free(run.file_changes);
    self.allocator.free(run.commentary_ends);
    deinitRunInput(self, effects, &run.input);
    releaseTrackedText(self, effects, &run.assistant);
    releaseTrackedText(self, effects, &run.output_segment);
    releaseTrackedText(self, effects, &run.output_continued);
    if (run.execution_model_owned)
        releaseProjectedSlice(self, effects, @constCast(run.execution_model));
    releaseProjectedSlice(self, effects, run.terminal_diagnostic);
    run.* = undefined;
}

fn deinitCompact(
    self: *Runtime,
    effects: ReleaseEffects,
    compact: *task_state.CompactRecord,
) void {
    std.debug.assert(compact.checkpoint.lease == null);
    std.debug.assert(compact.terminal_publication.load(.acquire) != .publishing);
    releaseProjectedSlice(self, effects, compact.terminal_diagnostic);
    compact.* = undefined;
}

fn releaseAttachmentNoFail(
    self: *Runtime,
    task: *task_state.Task,
    effects: ReleaseEffects,
    cause: task_attachment.DetachmentCause,
) void {
    task.conversation_observation = .{};
    if (task.runtime.pending_model) |model| {
        self.allocator.free(model);
        task.runtime.pending_model = null;
    }
    if (task.runtime.live() == null) {
        task.runtime.attachment = .{ .detached = cause };
        return;
    }
    var live = task.runtime.detach(cause);
    switch (live.binding.state()) {
        .owned => {
            switch (live.binding.closeOutcome(.session_close)) {
                .closed => {},
                .failure => @panic("Task Session close failed during attachment release"),
            }
            live.binding.releaseClosed() catch |err| {
                if (err == error.RuntimeShuttingDown) {
                    if (self.agent_runtime_shutdown_complete)
                        live.binding.relinquishAfterRuntimeShutdown()
                    else
                        live.binding.abandonForRuntimeDeinit();
                } else @panic("Task Session slot release failed during attachment release");
            };
        },
        .closed => live.binding.releaseClosed() catch |err| {
            if (err == error.RuntimeShuttingDown) {
                if (self.agent_runtime_shutdown_complete)
                    live.binding.relinquishAfterRuntimeShutdown()
                else
                    live.binding.abandonForRuntimeDeinit();
            } else @panic("closed Task Session slot release failed during attachment release");
        },
        .released, .relinquished, .moved, .fixture, .abandoned => {},
    }
    releaseExecutionValueNoFail(task, &live.execution, effects);
    if (live.pinned_catalog) |*snapshot| {
        effects.releaseProjectionBytes(snapshot.projected_bytes);
        snapshot.deinit();
    }
}

fn deinitTask(
    self: *Runtime,
    task: *task_state.Task,
    effects: ReleaseEffects,
) void {
    std.debug.assert(!task.runtime.worker_leases.hasLive());
    std.debug.assert(task.runtime.restore_job == null);
    releaseAttachmentNoFail(self, task, effects, .cold_start);
    for (task.durable.runs) |*entry| if (entry.*) |*run|
        deinitRun(self, effects, run);
    self.allocator.free(task.durable.runs);
    for (task.durable.compacts) |*entry| if (entry.*) |*compact|
        deinitCompact(self, effects, compact);
    self.allocator.free(task.durable.compacts);
    self.allocator.free(task.durable.ui_history);
    releaseProjectedSlice(self, effects, task.durable.execution_model);
    releaseProjectedSlice(self, effects, task.durable.workspace_root);
    releaseProjectedSlice(self, effects, task.durable.title);
    if (task.durable.checkpoint) |*checkpoint|
        checkpoint.deinit(self.allocator);
    if (task.runtime.pending_model) |model| self.allocator.free(model);
    task.* = undefined;
}

fn checkpointIdentityEqual(left: anytype, right: @TypeOf(left)) bool {
    return left.task_id == right.task_id and
        left.generation == right.generation and
        left.byte_size == right.byte_size and
        std.mem.eql(u8, &left.digest, &right.digest);
}

test "Task execution owns the service reference and protocol across clone and transfer" {
    var provider_id = "custom_provider:service-a".*;
    var owned = try owned_task_execution.OwnedTaskExecution.clone(std.testing.allocator, .{
        .target = .{
            .provider_id = &provider_id,
            .protocol = .openai_chat_completions,
            .model = "model",
            .base_url = "https://example.test/v1/chat/completions",
        },
        .api_key = "fixture-secret",
        .execution_generation = 7,
    });
    @memset(&provider_id, 'x');
    var transferred = owned.take();
    owned.deinit();
    defer transferred.deinit();
    const resolved = transferred.input();
    try std.testing.expectEqualStrings("custom_provider:service-a", resolved.target.provider_id);
    try std.testing.expectEqual(models_contract.Protocol.openai_chat_completions, resolved.target.protocol);
    try std.testing.expectEqual(@as(u64, 7), resolved.execution_generation);
}

test "Runtime owns bounded Task collection and monotonic process facts" {
    var runtime = try Runtime.init(std.testing.allocator, 2);
    defer runtime.deinitStorage();
    try std.testing.expectEqual(@as(?usize, 0), runtime.emptyIndex());
    try std.testing.expectEqual(@as(u64, 1), runtime.takeRecentOrder());
    try std.testing.expectEqual(@as(u64, 2), runtime.next_recent_order);
    try std.testing.expectEqual(@as(u64, 1), runtime.noteLateTerminal());

    runtime.next_task_id = std.math.maxInt(u64);
    try std.testing.expectError(
        error.TaskIdentityExhausted,
        runtime.takeTaskId(),
    );
    try std.testing.expectEqual(std.math.maxInt(u64), runtime.next_task_id);
}
