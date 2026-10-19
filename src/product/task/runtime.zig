//! Live Product Task aggregate.
//! The Runtime owns Task collection identity, runtime-only failure evidence and
//! process lifecycle facts. Cross-owner admission and shared history commit
//! effects are supplied by composition; they are never retained here.

const std = @import("std");
const agent = @import("metawork_agent");
const models_contract = @import("metawork_product_models_contract");
const task_state = @import("product_task_state");
pub const SendInputResult = task_state.SendInputResult;
pub const SendInputReason = task_state.SendInputReason;
const task_persistence = @import("product_task_persistence");
const task_policy = @import("product_task_policy");
const task_view = @import("product_task_view");
const checkpoint_store = @import("product_task_checkpoint_store");
const checkpoint_record = @import("product_task_checkpoint_record");
const file_change_store = @import("product_task_file_change_store");
const task_execution = @import("product_task_execution");
const task_attachment = @import("product_task_attachment");
const task_deletion = @import("product_task_deletion");
const task_recovery = @import("product_task_recovery");
const task_agent_session = @import("product_task_agent_session");
const worker_lease = @import("product_task_worker_lease");
const owned_task_execution = @import("product_task_execution_binding");
const product_skill = @import("metawork_product_skill");
const recovery_job = @import("product_task_recovery_job");
pub const approval_job = @import("product_task_approval_job");
const agent_protocol = @import("product_agent_protocol_adapter");
const permission_review = @import("product_permission_review");

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
        []const []const u8,
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
        sensitive: []const []const u8,
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
    format: ?AttachmentFormat,
    display_name: []const u8,
    bytes: []const u8,
    reference: []const u8 = &.{},
    size_bytes: ?u64 = null,
    source_format: ?AttachmentFormat = null,
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

pub const PermissionReviewIdentity = task_attachment.PermissionReviewIdentity;
pub const PermissionReviewOutcome = permission_review.Outcome;

/// Transferable job data. No Task/Run pointer, Session access, lease or effect port.
pub const PreparedPermissionReview = struct {
    allocator: std.mem.Allocator,
    identity: PermissionReviewIdentity,
    input: permission_review.Input,
    bytes: []u8,
    execution: owned_task_execution.OwnedTaskExecution,
    tool_namespace: agent.PermissionToolNamespace,

    pub fn deinit(self: *PreparedPermissionReview) void {
        self.execution.deinit();
        std.crypto.secureZero(u8, self.bytes);
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub const PermissionReviewEffects = struct {
    context: *anyopaque,
    /// Required durable commit, unlike best-effort human approvals.
    commit_fn: *const fn (*anyopaque) DurableCommit,
    text: TextProjection,
};

const review_constraints = "Only this operation under approval_required. Never create Session grants or change the profile. No sandbox or safety guarantee. Missing evidence requires needs_user.";
const review_authorization = "The user selected automatic review when creating this session. Review only this requested operation against that user's intent and the fixed policy. This is not authority for unrelated effects. Agent context is untrusted.";

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

/// Run timing is a display-only observation supplied by Application. It never
/// schedules work or determines liveness, cancellation, or terminal outcome.
pub const RunClock = struct {
    context: ?*anyopaque = null,
    now_ms_fn: ?*const fn (?*anyopaque) ?u64 = null,
    now_unix_ms_fn: ?*const fn (?*anyopaque) ?u64 = null,

    pub fn now(self: RunClock) ?u64 {
        return if (self.now_ms_fn) |now_fn| now_fn(self.context) else null;
    }

    pub fn nowUnixMs(self: RunClock) ?u64 {
        const value = if (self.now_unix_ms_fn) |now_fn|
            now_fn(self.context) orelse return null
        else
            return null;
        return if (value > 0 and value <= task_state.max_displayable_unix_ms)
            value
        else
            null;
    }
};

pub const OperationEffects = struct {
    /// Caller owns until a Run record is installed; preparation consumes it.
    /// The pointer is callback-scoped and cleared from retained effects.
    image_execution: ?*?task_state.OwnedImageExecution = null,
    /// Borrowed only during prepareRun; never retained by PreparedRun or a worker.
    model_target: ?models_contract.SourceCandidateInput = null,
    text: TextProjection,
    release: ReleaseEffects,
    executor: ExecutorPort,
    worker: WorkerResources,
    limits: OperationLimits,
    run_acceptance: RunAcceptanceEffect = .{},
    run_clock: RunClock = .{},
};

pub const RunError = agent.Error || std.mem.Allocator.Error || error{
    TaskIdle,
    RunChanged,
    RunStopping,
    UnsupportedInput,
    InvalidInput,
    RunNotReady,
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
    MissingInstruction,
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
    UiRequestIdentityCollision,
    TaskClosing,
    TaskPersistenceFailed,
    TaskPersistenceOutcomeUnknown,
};

pub const ModelIntentError = std.mem.Allocator.Error || error{
    UnknownTask,
    TaskClosing,
    TaskBusy,
    TaskModelMismatch,
    InvalidTaskModel,
};

pub const CloseError = ControlError || std.Thread.SpawnError || error{
    CloseInProgress,
    TaskBusy,
};

pub const RecoveryMode = enum { checkpoint, fresh };

pub const RecoveryStartFacts = struct {
    mode: RecoveryMode,
    workspace_id: u64,
    workspace_epoch: u64,
    execution_model: []const u8,
};

pub const RecoveryWorkspaceTrust = enum { explicitly_trusted, temporary };

pub const RestoreCapabilities = recovery_job.RestoreCapabilities;
pub const ModelIntentAuthority = recovery_job.ModelIntentAuthority;

pub const ModelRebindStart = struct {
    source_id: []const u8,
    selection_revision: u64,
    catalog_generation: u64,
    /// Cleared when the bounded attempt takes ownership, including a later
    /// executor admission failure. Before that point errors consume nothing.
    capabilities: ?*?RestoreCapabilities = null,
    text: TextProjection,
};

pub const RecoveryStartInput = struct {
    expected_binding_epoch: u64,
    workspace_id: u64,
    workspace_epoch: u64,
    workspace_root: []const u8,
    canonical_user_home: []const u8,
    workspace_trust: RecoveryWorkspaceTrust,
    workspace_kind: recovery_job.WorkspaceKind,
    execution: models_contract.ConfigInput,
    source_generation: u64 = 0,
    agent_runtime: *agent.Runtime,
    checkpoint_store: ?*checkpoint_store.FileStore,
    checkpoint_limits: agent.CheckpointLimits,
    notifier: task_execution.Notifier,
    executor: ExecutorPort,
    rebind: ?ModelRebindStart = null,
    checkpoint_store_health: ?*std.atomic.Value(checkpoint_store.Health) = null,
};

pub const RecoveryStartError = agent.Error || std.mem.Allocator.Error || error{
    UnknownTask,
    BindingEpochMismatch,
    RecoveryUnavailable,
    RestoreAttemptExhausted,
    ExecutorShuttingDown,
    QueueFull,
    BindingEpochExhausted,
    TaskPersistenceFailed,
    TaskPersistenceOutcomeUnknown,
    ProjectionCapacity,
    ExecutionUnavailable,
    ExecutionGenerationMismatch,
};

pub const MutationError = std.mem.Allocator.Error || error{
    ProjectionCapacity,
    UnknownTask,
    TaskBusy,
    TaskReadOnly,
    InvalidTaskTitle,
    TaskPersistenceFailed,
    TaskPersistenceOutcomeUnknown,
};

pub const DeletionError = error{
    TaskBusy,
    UnknownTask,
    TaskNotArchived,
    TaskReadOnly,
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
    model_intent: ?task_state.ModelIntent = null,
    permission_profile: task_state.PermissionProfile,
    permission_review_delegated: bool = false,
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
    model_ref: ?models_contract.ModelRef = null,
    source_generation: u64 = 0,
    permission_profile: task_state.PermissionProfile,
    permission_review_delegated: bool = false,
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
    InvalidTaskModel,
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

/// Synchronous history overlay. Control must complete the durable write before
/// completing this transaction, or roll it back before publishing a snapshot.
/// Neither path changes the installed Session, Run, or permission authority.
pub const PreparedModelIntent = struct {
    allocator: std.mem.Allocator,
    task: *task_state.Task,
    previous: ?task_state.ModelIntent,
    active: bool = true,

    pub fn complete(self: *PreparedModelIntent) void {
        std.debug.assert(self.active);
        if (self.previous) |*intent| intent.deinit(self.allocator);
        self.task.model_intent_prepared = false;
        self.active = false;
    }

    pub fn rollback(self: *PreparedModelIntent) void {
        std.debug.assert(self.active);
        self.task.durable.model_intent.?.deinit(self.allocator);
        self.task.durable.model_intent = self.previous;
        self.task.model_intent_prepared = false;
        self.active = false;
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
        run_record.admitted_at_ms = self.effects.run_clock.now();
        self.effects.executor.enqueue(
            run_record,
            self.job,
            task_execution.executeRun,
            task_execution.cancelRun,
        ) catch |err| {
            task_execution.publishAutomaticTitleFallback(run_record);
            task_execution.cancelPreparedRunOrPanic(self.job.sessionAccess(), self.run_id);
            self.job.destroy();
            run_record.coverage = .excluded;
            _ = task_execution.commitRunTerminal(
                self.effects.worker.projector,
                run_record,
                .interrupted,
                .interrupted,
                .queue_capacity_failure,
                .reusable,
                "",
                false,
                true,
            );
            run_record.terminal_observed = true;
            task_state.freezeRunElapsedMs(run_record, self.effects.run_clock.now());
            run_record.event_stream_finalized = true;
            run_record.finished_at_unix_ms = self.effects.run_clock.nowUnixMs();
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
            compact.coverage = .excluded;
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
                true,
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
    history_inserted: bool,
    active: bool = true,

    pub fn rollback(self: *PreparedUiResponse) void {
        std.debug.assert(self.active);
        if (self.history_inserted) {
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
        } else {
            self.task.runtime.pending_ui_request_id = self.previous_pending_request_id;
            self.task.runtime.pending_ui_order = self.previous_pending_order;
        }
        self.access.deinit();
        self.active = false;
    }

    pub fn deliver(
        self: *PreparedUiResponse,
    ) (agent.Error || std.mem.Allocator.Error)!void {
        std.debug.assert(self.active);
        if (!self.history_inserted) {
            self.access.deinit();
            self.active = false;
            return;
        }
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
    resources_quiescent_fn: ?*const fn (*anyopaque, u64, u64) bool = null,
    delete_checkpoint_task_fn: *const fn (*anyopaque, u64) void,
    delete_file_change_task_fn: *const fn (*anyopaque, u64) void,
    delete_attachment_task_fn: *const fn (*anyopaque, u64) void,
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

    fn deleteAttachmentTask(self: DeletionEffects, task_id: u64) void {
        self.delete_attachment_task_fn(self.context, task_id);
    }
};

pub const RecoveryAuthorityQuery = struct {
    task_id: u64,
    workspace_id: u64,
    workspace_epoch: u64,
    target_execution_generation: u64,
    task_model: []const u8,
    protocol: models_contract.Protocol,
    model_intent: ?recovery_job.ModelIntentAuthority = null,
    original_restore: bool = false,
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
    queue_binding_fn: *const fn (*anyopaque, u64) anyerror!?DurableCommit,
    executor: ?ExecutorPort = null,
    refresh_capabilities_fn: ?*const fn (*anyopaque, u64) bool = null,
    retire_checkpoint_fn: ?*const fn (*anyopaque, checkpoint_store.Identity) void = null,

    fn authority(
        self: RecoveryEffects,
        query: RecoveryAuthorityQuery,
    ) RecoveryExternalAuthority {
        return self.authority_fn(self.context, query);
    }

    fn queueBinding(self: RecoveryEffects, task_id: u64) !?DurableCommit {
        return self.queue_binding_fn(self.context, task_id);
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
    notifier: task_execution.Notifier,
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
    model_rebind_required: bool = false,
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
    now_ms: ?u64 = null,
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
    /// Borrowed from the Runtime; valid until its history next changes.
    read_only_tasks: []task_persistence.ReadOnlyPayload,
    retained: []const task_persistence.RetainedRecord,
    next_task_id: u64,
    next_recent_order: u64,

    pub fn deinit(self: *HistoryFrames) void {
        task_persistence.deinitTaskWires(self.allocator, self.tasks);
        self.allocator.free(self.failures);
        self.allocator.free(self.read_only_tasks);
        self.* = undefined;
    }
};

const PendingUiContext = struct {
    runtime: *Runtime,
    max_json_bytes: usize,
};

const EventContext = struct {
    image_secret: []const u8 = &.{},
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
    /// History frames this build cannot restore; payloads are owned and are
    /// written back unchanged by every commit.
    retained: std.ArrayList(task_persistence.RetainedRecord) = .empty,
    next_task_id: u64 = 1,
    next_recent_order: u64 = 1,
    next_restore_attempt_id: u64 = 1,
    /// Runtime-wide execution-only input ownership, separate from safe projection.
    pending_input_bytes: usize = 0,
    late_terminal_event_count: u64 = 0,
    recovery_poisoned: bool = false,
    agent_runtime_shutdown_complete: bool = false,
    permission_reviews_closed: bool = false,
    approval_cleanup_leases: worker_lease.WorkerLeaseSet = .{},
    approval_jobs: [approval_job.max_operations]?struct { task_id: u64, restore_attempt_id: ?u64 = null, job: *approval_job.Job } = @splat(null),

    pub const ApprovalError = error{
        UnknownTask,
        BindingEpochMismatch,
        ApprovalRevisionMismatch,
        ApprovalRevisionExhausted,
        ReviewGenerationExhausted,
        TaskBusy,
        TaskClosing,
        UnsupportedPermissionProfile,
        ApprovalUnavailable,
    };

    /// Projection and commands share the same per-target admission decision.
    fn approvalChangeRevision(
        self: *const Runtime,
        task: *const task_state.Task,
        expected_binding_epoch: u64,
        expected_revision: u64,
        target: task_state.ApprovalMode,
        authority: ProjectionAuthority,
    ) ApprovalError!u64 {
        if (expected_binding_epoch == 0 or expected_binding_epoch != task.durable.binding_epoch)
            return error.BindingEpochMismatch;
        if (expected_revision == 0 or expected_revision != task.durable.approval_revision)
            return error.ApprovalRevisionMismatch;
        if (task.approval_change != null) return error.TaskBusy;
        if (task.durable.permission_interaction != .interactive) return error.UnsupportedPermissionProfile;
        if (task_policy.taskLifecycle(task) != .open or task.durable.archived or task.deletion != .idle)
            return error.TaskClosing;
        const current = task_state.ApprovalMode.fromFacts(task.durable.permission_profile, task.durable.permission_review_delegated);
        if (current == target) return task.durable.approval_revision;
        if (self.permission_reviews_closed or task.runtime.active_operation == .compact or task.runtime.active_operation == .restore)
            return error.TaskBusy;
        if (authority.shutting_down or !authority.task_persistence_ready or
            !authority.workspace_identity_exact or !authority.automatic_owner_exact or !authority.authority_stable)
            return error.ApprovalUnavailable;
        if (!task.runtime.hasAttachedSession() and
            (authority.execution_admission != .available or authority.runtime_admission != .available))
            return error.ApprovalUnavailable;
        if ((current.profile() != target.profile() or !task.runtime.hasAttachedSession()) and !authority.checkpoint_store_ready)
            return error.ApprovalUnavailable;
        var pending_count: usize = 0;
        for (self.tasks) |entry| if (entry) |item| if (item.approval_change != null) {
            pending_count += 1;
        };
        if (pending_count >= approval_job.max_operations) return error.TaskBusy;
        if (target == .auto_review and (task.runtime.permission_review.exhausted or
            task.runtime.permission_review.generation == std.math.maxInt(u64)))
            return error.ReviewGenerationExhausted;
        return std.math.add(u64, task.durable.approval_revision, 1) catch return error.ApprovalRevisionExhausted;
    }

    fn availableApprovalModes(self: *const Runtime, task: *const task_state.Task, authority: ProjectionAuthority, buffer: *[3]task_state.ApprovalMode) []const task_state.ApprovalMode {
        if (authority.shutting_down) return &.{};
        var count: usize = 0;
        for (std.enums.values(task_state.ApprovalMode)) |mode| {
            _ = self.approvalChangeRevision(task, task.durable.binding_epoch, task.durable.approval_revision, mode, authority) catch continue;
            buffer[count] = mode;
            count += 1;
        }
        return buffer[0..count];
    }

    pub fn beginApprovalChange(
        self: *Runtime,
        task_id: u64,
        expected_binding_epoch: u64,
        expected_revision: u64,
        target: task_state.ApprovalMode,
        effects: RecoveryAdmissionEffects,
    ) ApprovalError!u64 {
        const task = self.find(task_id) orelse return error.UnknownTask;
        if (task.read_only_history != null) return error.TaskClosing;
        const revision = try self.approvalChangeRevision(task, expected_binding_epoch, expected_revision, target, effects.authority(projectionAuthorityQuery(task)));
        if (revision == task.durable.approval_revision) return revision;
        _ = self.cancelInputContinuation(task_id, null, .continuation_cancelled);
        task.runtime.permission_review.invalidate();
        if (target == .manual and task.runtime.pending_ui_request_id != 0) {
            task.runtime.permission_review.phase = .needs_user;
            task.runtime.permission_review.settled_request_id = task.runtime.pending_ui_request_id;
        }
        task.approval_result = null;
        task.approval_change = .{ .revision = revision, .binding_epoch = task.durable.binding_epoch, .target = target };
        return revision;
    }

    fn approvalJobSlot(self: *Runtime) error{QueueFull}!usize {
        for (self.approval_jobs, 0..) |entry, index| if (entry == null) return index;
        return error.QueueFull;
    }

    pub fn approvalJobFor(self: *const Runtime, task_id: u64) bool {
        for (self.approval_jobs) |entry| if (entry) |slot| if (slot.task_id == task_id) return true;
        return false;
    }

    pub fn approvalHistoryWorkerActive(self: *const Runtime) bool {
        for (self.approval_jobs) |entry| if (entry) |slot| if (slot.job.work == .history) return true;
        return false;
    }

    pub fn approvalHistoryBlocked(self: *const Runtime) bool {
        if (self.approvalHistoryWorkerActive()) return true;
        for (self.tasks) |entry| if (entry) |task| {
            if (task.approval_change) |change| if (change.phase == .outcome_unknown) return true;
            if (task.runtime.restore_job) |job| if (job.binding_commit != .not_started) return true;
        };
        return false;
    }

    pub fn approvalCoreIdle(self: *const Runtime, task_id: u64) bool {
        const task = self.findConst(task_id) orelse return false;
        return task.runtime.active_operation == .none and
            !task.runtime.worker_leases.hasLive() and !task_state.hasUnfinalizedTerminalEvents(task);
    }

    pub fn queueApprovalCheckpoint(self: *Runtime, task_id: u64, mutate: bool, resources: task_execution.CheckpointResources, executor: ExecutorPort, notifier: task_execution.Notifier) !void {
        const task = self.find(task_id) orelse return error.UnknownTask;
        const change = task.approval_change orelse return error.TaskBusy;
        if (self.approvalJobFor(task_id) or task.runtime.active_operation != .none or
            task.runtime.worker_leases.hasLive() or task_state.hasUnfinalizedTerminalEvents(task)) return error.TaskBusy;
        const store = resources.store orelse return error.ApprovalUnavailable;
        const slot = try self.approvalJobSlot();
        var access = try task.runtime.acquireAccess();
        var access_live = true;
        errdefer if (access_live) access.deinit();
        const model = try self.allocator.dupe(u8, task.durable.execution_model);
        errdefer self.allocator.free(model);
        var lease = try task.runtime.worker_leases.acquire();
        var lease_live = true;
        errdefer if (lease_live) lease.deinit();
        const job = try self.allocator.create(approval_job.Job);
        errdefer self.allocator.destroy(job);
        job.* = .{
            .allocator = self.allocator,
            .lease = lease.take(),
            .notifier = .{ .context = notifier.context, .notify_fn = notifier.notify_fn },
            .work = .{ .checkpoint = .{
                .access = access.take(),
                .model = model,
                .store = store,
                .store_health = resources.store_health,
                .limits = resources.limits,
                .task_id = task_id,
                .binding_epoch = task.durable.binding_epoch,
                .approval_revision = if (mutate) change.revision else task.durable.approval_revision,
                .last_run_id = task_policy.lastConversationRunId(task) orelse 0,
                .last_compact_id = task_policy.lastConversationCompactId(task),
                .expected_mode = agentSessionPermission(task.durable.permission_profile, task.durable.permission_interaction).mode,
                .target_mode = agentSessionPermission(change.target.profile(), task.durable.permission_interaction).mode,
                .mutate = mutate,
            } },
        };
        // The job owns resources even if executor admission rejects it.
        access_live = false;
        lease_live = false;
        executor.enqueue(job, job, approval_job.Job.execute, approval_job.Job.cancelQueued) catch |err| {
            job.work.checkpoint.access.deinit();
            job.lease.deinit();
            return err;
        };
        self.approval_jobs[slot] = .{ .task_id = task_id, .job = job };
        task.approval_change.?.phase = if (mutate) .mutation_export else .baseline_export;
    }

    pub fn queueApprovalHistory(self: *Runtime, task_id: u64, bytes: []u8, capability: task_persistence.Capability, executor: ExecutorPort, notifier: task_execution.Notifier) !void {
        if (self.approvalHistoryBlocked()) return error.TaskBusy;
        return self.queueApprovalHistoryWork(task_id, null, bytes, capability, false, executor, notifier);
    }

    pub fn queueApprovalResolution(self: *Runtime, task_id: u64, capability: task_persistence.Capability, executor: ExecutorPort, notifier: task_execution.Notifier) !void {
        if (self.approvalHistoryWorkerActive()) return error.TaskBusy;
        const task = self.find(task_id) orelse return error.UnknownTask;
        const change = task.approval_change orelse return error.TaskBusy;
        if (change.phase != .outcome_unknown) return error.TaskBusy;
        const history = change.unknown_history orelse return error.ApprovalUnavailable;
        const bytes = try self.allocator.dupe(u8, history.bytes);
        errdefer self.allocator.free(bytes);
        try self.queueApprovalHistoryWork(task_id, null, bytes, capability, true, executor, notifier);
    }

    /// A post-commit projection uses the same bounded writer and outlives the
    /// completed Task intent, like retirement of its superseded checkpoint.
    pub fn queueApprovalProjection(self: *Runtime, bytes: []u8, capability: task_persistence.Capability, resolve_only: bool, executor: ExecutorPort, notifier: task_execution.Notifier) !void {
        if (self.approvalHistoryWorkerActive()) return error.TaskBusy;
        return self.queueApprovalHistoryWork(0, null, bytes, capability, resolve_only, executor, notifier);
    }

    /// Recovery binding confirmation shares the same single history writer.
    /// Only immutable bytes and capabilities cross into that worker.
    pub fn queueRecoveryHistory(self: *Runtime, task_id: u64, bytes: []u8, capability: task_persistence.Capability, resolve_only: bool, executor: ExecutorPort, notifier: task_execution.Notifier) !void {
        if (self.approvalHistoryWorkerActive() or (!resolve_only and self.approvalHistoryBlocked())) return error.TaskBusy;
        const task = self.find(task_id) orelse return error.UnknownTask;
        const restore = task.runtime.restore_job orelse return error.TaskBusy;
        if (resolve_only and (restore.binding_commit != .outcome_unknown or restore.unknown_history == null)) return error.TaskBusy;
        try self.queueApprovalHistoryWork(task_id, restore.attempt.attempt_id, bytes, capability, resolve_only, executor, notifier);
    }

    fn queueApprovalHistoryWork(self: *Runtime, task_id: u64, restore_attempt_id: ?u64, bytes: []u8, capability: task_persistence.Capability, resolve_only: bool, executor: ExecutorPort, notifier: task_execution.Notifier) !void {
        const leases = if (task_id == 0) &self.approval_cleanup_leases else leases: {
            const task = self.find(task_id) orelse return error.UnknownTask;
            break :leases &task.runtime.worker_leases;
        };
        const slot = try self.approvalJobSlot();
        var lease = try leases.acquire();
        var lease_live = true;
        errdefer if (lease_live) lease.deinit();
        const job = try self.allocator.create(approval_job.Job);
        errdefer self.allocator.destroy(job);
        job.* = .{
            .allocator = self.allocator,
            .lease = lease.take(),
            .notifier = .{ .context = notifier.context, .notify_fn = notifier.notify_fn },
            .work = .{ .history = .{ .bytes = bytes, .capability = capability, .resolve_only = resolve_only } },
        };
        lease_live = false;
        executor.enqueue(job, job, approval_job.Job.execute, approval_job.Job.cancelQueued) catch |err| {
            job.lease.deinit();
            return err;
        };
        self.approval_jobs[slot] = .{ .task_id = task_id, .restore_attempt_id = restore_attempt_id, .job = job };
    }

    pub fn queueApprovalRetirement(self: *Runtime, store: *checkpoint_store.FileStore, identity: checkpoint_store.Identity, executor: ExecutorPort, notifier: task_execution.Notifier) !void {
        const slot = try self.approvalJobSlot();
        var lease = try self.approval_cleanup_leases.acquire();
        var lease_live = true;
        errdefer if (lease_live) lease.deinit();
        const job = try self.allocator.create(approval_job.Job);
        errdefer self.allocator.destroy(job);
        job.* = .{
            .allocator = self.allocator,
            .lease = lease.take(),
            .notifier = .{ .context = notifier.context, .notify_fn = notifier.notify_fn },
            .work = .{ .retire = .{ .store = store, .identity = identity } },
        };
        lease_live = false;
        executor.enqueue(job, job, approval_job.Job.execute, approval_job.Job.cancelQueued) catch |err| {
            job.lease.deinit();
            return err;
        };
        self.approval_jobs[slot] = .{ .task_id = 0, .job = job };
    }

    pub const PreparedApprovalCommit = struct {
        task: *task_state.Task,
        previous_profile: task_state.PermissionProfile,
        previous_delegated: bool,
        previous_revision: u64,
        coverage: ?CheckpointCoverageOverlay,
        checkpoint: ?*const checkpoint_record.Record,

        pub fn rollback(self: PreparedApprovalCommit) void {
            self.task.durable.permission_profile = self.previous_profile;
            self.task.durable.permission_review_delegated = self.previous_delegated;
            self.task.durable.approval_revision = self.previous_revision;
            if (self.coverage) |overlay| rollbackCheckpointCoverageOverlay(self.task, overlay);
        }
    };

    pub fn prepareApprovalCommit(self: *Runtime, task_id: u64) !PreparedApprovalCommit {
        const task = self.find(task_id) orelse return error.UnknownTask;
        const change = task.approval_change orelse return error.TaskBusy;
        var prepared = PreparedApprovalCommit{
            .task = task,
            .previous_profile = task.durable.permission_profile,
            .previous_delegated = task.durable.permission_review_delegated,
            .previous_revision = task.durable.approval_revision,
            .coverage = null,
            .checkpoint = null,
        };
        if (change.phase == .mode_commit) {
            task.durable.permission_profile = change.target.profile();
            task.durable.permission_review_delegated = change.target == .auto_review;
            task.durable.approval_revision = change.revision;
        }
        errdefer prepared.rollback();
        if (task.approval_change.?.candidate) |*record| {
            const candidate = task_state.CheckpointCandidate{ .record = record.*, .metrics = .{ .chunk_count = 0, .export_duration_ns = 0 } };
            prepared.coverage = beginCheckpointCoverageOverlay(task, &candidate) orelse return error.ApprovalUnavailable;
            prepared.checkpoint = record;
        }
        return prepared;
    }

    pub fn recordApprovalCheckpoint(self: *Runtime, task_id: u64, record: checkpoint_record.Record) void {
        const task = self.find(task_id) orelse unreachable;
        const change = &task.approval_change.?;
        std.debug.assert(change.candidate == null);
        change.candidate = record;
        change.phase = switch (change.phase) {
            .baseline_export => .baseline_commit,
            .mutation_export => .mode_commit,
            else => unreachable,
        };
    }

    pub fn failApprovalChange(self: *Runtime, task_id: u64, reason: task_state.ApprovalFailureReason, restore_required: bool) void {
        const task = self.find(task_id) orelse return;
        const change = &(task.approval_change orelse return);
        const revision = change.revision;
        if (task.approval_change.?.unknown_history) |history| self.allocator.free(history.bytes);
        task.approval_change.?.unknown_history = null;
        if (task.approval_change.?.candidate) |*record| record.deinit(self.allocator);
        task.approval_change.?.candidate = null;
        if (restore_required) {
            task.approval_change.?.failure = reason;
            task.approval_change.?.phase = .recovering;
        } else {
            task.approval_result = .{ .revision = revision, .outcome = .failed, .reason = reason };
            task.approval_change = null;
        }
    }

    /// A failed close cannot make a mutated, uncommitted Session reusable.
    /// Keep the existing explicit close-retry path and end this approval intent.
    pub fn failApprovalRecovery(self: *Runtime, task_id: u64) void {
        const task = self.find(task_id) orelse return;
        if (task.runtime.attached()) |attached| attached.health = .session_poisoned;
        task.runtime.close_failed = true;
        self.failApprovalChange(task_id, .recovery_failed, false);
    }

    pub fn markApprovalUnknown(self: *Runtime, task_id: u64, bytes: ?[]u8) void {
        const task = self.find(task_id) orelse unreachable;
        const change = &task.approval_change.?;
        if (bytes) |candidate| {
            std.debug.assert(change.unknown_history == null);
            change.unknown_history = .{ .bytes = candidate, .mode_commit = change.phase == .mode_commit };
        }
        change.phase = .outcome_unknown;
        change.failure = .outcome_unknown;
    }

    pub fn resumeApprovalConfirmation(self: *Runtime, task_id: u64) !void {
        const task = self.find(task_id) orelse return error.UnknownTask;
        const change = &(task.approval_change orelse return error.TaskBusy);
        if (change.phase != .outcome_unknown) return;
        const history = change.unknown_history orelse return error.ApprovalUnavailable;
        task.approval_change.?.phase = if (history.mode_commit) .mode_commit else .baseline_commit;
    }

    pub fn acceptApprovalCommit(self: *Runtime, task_id: u64) !?checkpoint_store.Identity {
        const task = self.find(task_id) orelse return error.UnknownTask;
        const prepared = try self.prepareApprovalCommit(task_id);
        // The same candidate was durably confirmed; retain this overlay.
        var old_identity: ?checkpoint_store.Identity = null;
        if (task.approval_change.?.candidate) |record| {
            if (task.durable.checkpoint) |*old| {
                if (!std.meta.eql(old.blob, record.blob)) old_identity = old.blob;
                old.deinit(self.allocator);
            }
            task.durable.checkpoint = record;
            task.approval_change.?.candidate = null;
            task.durable.checkpoint_anchor = .available;
            task.durable.checkpoint_attempt = .none;
        }
        _ = prepared;
        if (task.approval_change.?.unknown_history) |history| self.allocator.free(history.bytes);
        task.approval_change.?.unknown_history = null;
        if (task.approval_change.?.phase == .baseline_commit) {
            task.approval_change.?.baseline_confirmed = true;
            task.approval_change.?.phase = .waiting;
        } else {
            task.approval_result = .{ .revision = task.durable.approval_revision, .outcome = .completed };
            task.approval_change = null;
        }
        return old_identity;
    }

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
        for (self.approval_jobs) |entry| std.debug.assert(entry == null);
        std.debug.assert(!self.approval_cleanup_leases.hasLive());
        for (self.tasks) |entry| std.debug.assert(entry == null);
        std.debug.assert(self.pending_input_bytes == 0);
        self.allocator.free(self.tasks);
        for (self.failures.items) |failure| self.allocator.free(failure.reason);
        self.failures.deinit(self.allocator);
        self.clearRetained();
        self.retained.deinit(self.allocator);
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
        var model_intent = if (input.model_ref) |model|
            task_state.ModelIntent.init(self.allocator, model, 1) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidModelIntent => return error.InvalidTaskModel,
            }
        else
            null;
        var intent_live = true;
        errdefer if (intent_live) if (model_intent) |*intent| intent.deinit(self.allocator);
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
            &.{input.execution.api_key},
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
        execution.source_generation = input.source_generation;
        execution.model_intent_revision = if (input.source_generation != 0)
            if (model_intent) |intent| intent.revision else 0
        else
            0;
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
            .model_intent = model_intent,
            .permission_profile = input.permission_profile,
            .permission_review_delegated = input.permission_review_delegated,
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
        intent_live = false;
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
                .model_intent = owned.model_intent,
                .permission_profile = owned.permission_profile,
                .permission_review_delegated = owned.permission_review_delegated,
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

    /// Eligibility never depends on checkpoint storage health.
    pub fn beginSendInputOperation(self: *Runtime, task_id: u64, operation_id: []const u8) RunError!*task_state.SendInputResult {
        const task = self.find(task_id) orelse return error.UnknownTask;
        if (operation_id.len == 0 or operation_id.len > 64) return error.InvalidInput;
        task.send_input_result = .{ .task_id = task_id, .operation_id_len = @intCast(operation_id.len) };
        const result = &task.send_input_result.?;
        @memcpy(result.operation_id[0..operation_id.len], operation_id);
        return result;
    }

    /// Immediately targets this Run. Safe history is reserved before the SDK
    /// effect; neither a rejection nor an uncertain result can schedule work.
    pub fn submitInput(self: *Runtime, task_id: u64, binding_epoch: u64, run_id: u64, text: []const u8, effects: OperationEffects) RunError!void {
        const task = self.find(task_id) orelse return error.UnknownTask;
        if (task.durable.binding_epoch != binding_epoch) return error.BindingEpochMismatch;
        if (self.inputContinuation(task_id) != null) return error.TaskBusy;
        if (task.read_only_history != null or task.durable.archived or task.runtime.close_requested or task.deletion != .idle) return error.TaskClosing;
        if (task.approval_change != null) return error.TaskBusy;
        switch (task.runtime.active_operation) {
            .run => |id| if (id != run_id) return error.RunChanged,
            else => return error.RunChanged,
        }
        const run = task_state.findRun(task.durable.runs, run_id) orelse return error.RunChanged;
        if (run.input == .skill) return error.UnsupportedInput;
        if (task.runtime.cancel_requested or run.pending_termination.load(.acquire) != .none) return error.RunStopping;
        if (task_state.terminalPayload(run) != null) return error.RunChanged;
        if (run.agent_handoff.load(.acquire) != .running) return error.RunNotReady;
        var lease = run.run_control.tryAcquireLease() orelse return error.RunNotReady;
        defer lease.deinit();
        if (!lease.inputObservation().ready) return error.RunNotReady;
        if (!std.unicode.utf8ValidateSlice(text) or std.mem.trim(u8, text, " \t\r\n").len == 0) return error.MissingInstruction;
        if (text.len > effects.limits.max_user_message_bytes) return error.ProjectionCapacity;
        if (run.next_input_id == std.math.maxInt(u64)) return error.ProjectionCapacity;
        var slot: ?usize = null;
        for (run.additional_inputs, 0..) |entry, i| if (entry == null) {
            slot = i;
            break;
        };
        const index = slot orelse return error.ProjectionCapacity;
        if (text.len > agent.max_submitted_input_bytes - self.pending_input_bytes)
            return error.ProjectionCapacity;
        const raw = try self.allocator.dupe(u8, text);
        self.pending_input_bytes += raw.len;
        var raw_owned = true;
        defer if (raw_owned) self.releaseInputPayload(raw);
        try effects.text.reserveBytes(task_state.additional_input_projection_bytes);
        errdefer effects.text.releaseBytes(task_state.additional_input_projection_bytes);
        const projected = try effects.text.project(text, effects.limits.max_user_message_bytes, &run.redactionSecrets(), 0);
        const result = &task.send_input_result.?;
        const id = run.next_input_id;
        run.next_input_id += 1;
        var record: task_state.AdditionalInput = .{
            .id = id,
            .after_output_count = run.outputPartCount(),
            .operation_id_len = result.operation_id_len,
            .text = projected.value,
            .redacted = projected.redacted,
            .raw_text = raw,
        };
        @memcpy(record.operation_id[0..record.operation_id_len], result.operationId());
        run.additional_inputs[index] = record;
        run.input_continuation_binding_epoch = binding_epoch;
        result.run_id = run_id;
        switch (lease.submitInput(id, text)) {
            .accepted => |sequence| {
                raw_owned = false;
                run.additional_inputs[index].?.sequence = sequence;
                run.input_continuation_cancelled = false;
                run.input_continuation_failure = null;
                result.outcome = .submitted;
                result.input_id = id;
                result.sequence = sequence;
            },
            .unknown => {
                raw_owned = false;
                run.additional_inputs[index].?.state = .unknown;
                result.outcome = .unknown;
                result.input_id = id;
            },
            .rejected => |reason| {
                effects.text.discardCandidate(projected.value);
                effects.text.releaseBytes(task_state.additional_input_projection_bytes);
                run.additional_inputs[index] = null;
                result.reason = switch (reason) {
                    .stale_run => .run_changed,
                    .not_ready => .run_not_ready,
                    .stopping => .run_stopping,
                    .unsupported_input => .unsupported_input,
                    .invalid_input => .invalid_input,
                    .resource_limit => .resource_limit,
                    .checkpoint_budget_required => .checkpoint_budget_required,
                    .too_late => .too_late,
                    .unavailable => .binding_unavailable,
                };
                result.run_id = null;
            },
        }
    }

    fn releaseInputPayload(self: *Runtime, raw: []u8) void {
        std.debug.assert(self.pending_input_bytes >= raw.len);
        self.pending_input_bytes -= raw.len;
        std.crypto.secureZero(u8, raw);
        self.allocator.free(raw);
    }

    pub fn discardInputPayloads(self: *Runtime, run: *task_state.RunRecord) void {
        for (&run.additional_inputs) |*entry| if (entry.*) |*record| {
            if (record.raw_text) |raw| self.releaseInputPayload(raw);
            record.raw_text = null;
        };
    }

    pub fn inputContinuation(self: *Runtime, task_id: u64) ?*task_state.RunRecord {
        const task = self.find(task_id) orelse return null;
        for (task.durable.runs) |*entry| if (entry.*) |*run| {
            if (run.input_continuation_pending) return run;
        };
        return null;
    }

    pub fn cancelInputContinuation(self: *Runtime, task_id: u64, source_id: ?u64, reason: SendInputReason) bool {
        const task = self.find(task_id) orelse return false;
        var changed = false;
        for (task.durable.runs) |*entry| if (entry.*) |*run| {
            if (source_id) |id| if (run.id != id) continue;
            var has_payload = false;
            for (run.additional_inputs) |input| if (input) |record| {
                has_payload = has_payload or record.raw_text != null;
            };
            if (!run.input_continuation_pending and !has_payload) continue;
            run.input_continuation_cancelled = true;
            run.input_continuation_pending = false;
            run.input_continuation_failure = reason;
            for (&run.additional_inputs) |*input| if (input.*) |*record| {
                if (record.raw_text != null) record.continuation_cancel_reason = reason;
            };
            self.discardInputPayloads(run);
            changed = true;
        };
        return changed;
    }

    pub fn mergeInputContinuation(self: *Runtime, run: *task_state.RunRecord, max: usize) (std.mem.Allocator.Error || error{ InputContinuationTooLarge, MissingInputPayload })![]u8 {
        var size: usize = 0;
        var count: usize = 0;
        for (run.additional_inputs) |entry| if (entry) |record| {
            if (record.state != .unadopted or record.continuation_cancel_reason != null) continue;
            const raw = record.raw_text orelse return error.MissingInputPayload;
            const separator: usize = if (count == 0) 0 else 2;
            if (size > max or separator > max - size or raw.len > max - size - separator)
                return error.InputContinuationTooLarge;
            size += separator + raw.len;
            count += 1;
        };
        if (count == 0) return error.MissingInputPayload;
        const merged = try self.allocator.alloc(u8, size);
        var offset: usize = 0;
        for (run.additional_inputs) |entry| if (entry) |record| {
            if (record.state != .unadopted or record.continuation_cancel_reason != null) continue;
            if (offset != 0) {
                @memcpy(merged[offset..][0..2], "\n\n");
                offset += 2;
            }
            const raw = record.raw_text.?;
            @memcpy(merged[offset..][0..raw.len], raw);
            offset += raw.len;
        };
        return merged;
    }

    pub fn markInputTransferred(self: *Runtime, task_id: u64, source_id: u64, target_id: ?u64) void {
        const task = self.find(task_id) orelse unreachable;
        const run = task_state.findRun(task.durable.runs, source_id) orelse unreachable;
        for (&run.additional_inputs) |*entry| if (entry.*) |*record| {
            if (record.state != .unadopted and record.state != .transferred) continue;
            if (record.continuation_cancel_reason != null) continue;
            record.state = if (target_id != null) .transferred else .unadopted;
            record.transferred_to_run_id = target_id;
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
        return self.prepareRun(task_id, expected_binding_epoch, input, workspace, effects);
    }

    fn prepareRun(
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
        _ = try taskExecutionInput(task);
        if (self.inputContinuation(task_id) != null) return error.TaskBusy;
        if (task_policy.hasActiveOperation(task) or
            checkpointMutationPending(task, effects.worker.checkpoint.store_health))
            return error.TaskBusy;
        var access = task.runtime.acquireAccess() catch return error.TaskClosing;
        var access_live = true;
        errdefer if (access_live) access.deinit();
        try applyModelIntent(self, task, &access, effects);
        const execution = try taskExecutionInput(task);
        var input_parts: [agent.multimodal_input_limits.max_parts]agent.InputPart = undefined;
        const agent_input = try validateRunInput(task, input, effects.limits, &input_parts);
        const image = if (effects.image_execution) |owned| if (owned.*) |*value| value.input() else null else null;
        const run_id = try access.prepareRunWithImage(agent_input, image);
        var prepared = true;
        errdefer if (prepared)
            task_execution.cancelPreparedRunOrPanic(&access, run_id);
        if (run_id <= task_policy.runHistoryHighWater(task))
            return error.CoreCallFailed;
        const slot = try reserveRun(self, task, input, effects);
        var record_owned = true;
        errdefer if (record_owned) discardRun(self, task, slot, effects.release);
        const run_record = &task.durable.runs[slot].?;
        run_record.id = run_id;
        if (effects.image_execution) |owned| {
            run_record.image_execution = owned.*;
            owned.* = null;
        }

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
            .last_compact_id = task_policy.lastConversationCompactId(task),
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
            .effects = cleanRunEffects(effects),
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
        if (self.inputContinuation(task_id) != null) return error.TaskBusy;
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
        const after_run_id = task_policy.lastConversationRunId(task) orelse
            return error.NoSuchRun;
        var access = task.runtime.acquireAccess() catch return error.TaskClosing;
        var access_live = true;
        errdefer if (access_live) access.deinit();
        const operation_id = try access.prepareCompact();
        var prepared = true;
        errdefer if (prepared)
            task_execution.cancelPreparedCompactOrPanic(&access, operation_id);
        if (operation_id <= task_policy.compactHistoryHighWater(task))
            return error.CoreCallFailed;
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
        const continuation_cancelled = self.cancelInputContinuation(task_id, run_id, .continuation_cancelled);
        if (task_state.terminalPayload(run_record) != null) return continuation_cancelled;
        var access = task.runtime.acquireAccess() catch return error.TaskClosing;
        defer access.deinit();
        const record = prepareCancelledUiRecord(
            self,
            &access,
            run_id,
            &run_record.redactionSecrets(),
        );
        var identity_collision = false;
        const dispatch = requestRunTermination(run_record, .user_cancel);
        if (effects.executor.cancel(run_record)) {
            task.runtime.permission_review.invalidate();
            run_record.terminal_observed = true;
            if (record) |value| switch (pushUiRecord(task, value)) {
                .inserted, .already_resolved => {},
                .identity_collision => {
                    identity_collision = true;
                    failUiRequestIdentityCollision(task, &access, run_id);
                },
            };
            task.runtime.cancel_requested = identity_collision;
            task.durable.recent_order = self.takeRecentOrder();
            return true;
        }
        const stopping = switch (dispatch) {
            .pending, .requested, .already_requested => true,
            .already_finishing, .already_terminal, .stale_run, .session_closing => false,
        };
        if (!stopping) return continuation_cancelled;
        task.runtime.permission_review.invalidate();
        if (record) |value| switch (pushUiRecord(task, value)) {
            .inserted, .already_resolved => {},
            .identity_collision => failUiRequestIdentityCollision(task, &access, run_id),
        };
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
        errdefer access.deinit();
        const pending = access.pendingUiObservation() orelse
            return error.NoPendingUiRequest;
        if (pending.run_id != run_id or pending.request_id != request_id)
            return error.StaleUiResponse;
        const record = try prepareUiRecord(
            self,
            &access,
            run_id,
            request_id,
            response,
            &run_record.redactionSecrets(),
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
        const insertion = pushUiRecord(task, record);
        switch (insertion) {
            .inserted => {
                task.runtime.permission_review.settle(request_id);
                task.durable.recent_order = self.takeRecentOrder();
            },
            .already_resolved => {},
            .identity_collision => {
                failUiRequestIdentityCollision(task, &access, run_id);
                return error.UiRequestIdentityCollision;
            },
        }
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
            .history_inserted = insertion == .inserted,
        };
    }

    /// Main-thread preparation. A failed attempt remains manual for this
    /// request; polling never retries it implicitly.
    pub fn preparePermissionReview(
        self: *Runtime,
        task_id: u64,
        text: TextProjection,
    ) !?PreparedPermissionReview {
        const task = self.find(task_id) orelse return error.UnknownTask;
        if (self.permission_reviews_closed) return null;
        if (!reviewTaskEligible(task)) return null;
        const run = task_state.findRun(task.durable.runs, task.runtime.active_run_id) orelse return null;
        if (task_state.terminalPayload(run) != null or run.pending_termination.load(.acquire) != .none)
            return null;
        var access = task.runtime.acquireAccess() catch return null;
        defer access.deinit();
        const observation = access.pendingUiObservation() orelse return null;
        if (observation.run_id != run.id or
            task.runtime.permission_review.settled_request_id == observation.request_id)
            return null;
        if (task.runtime.permission_review.identity) |identity| {
            if (identity.request_id == observation.request_id) return null;
        }
        errdefer task.runtime.permission_review.settle(observation.request_id);
        var pending = try access.copyPendingUiRequest(self.allocator);
        defer {
            std.crypto.secureZero(u8, pending.json);
            pending.deinit();
        }
        if (pending.run_id != run.id or pending.request_id != observation.request_id) return null;
        var parsed = try agent.decodePermissionRequest(self.allocator, pending.json);
        defer {
            std.crypto.secureZero(u8, @constCast(parsed.value().arguments_json));
            parsed.deinit();
        }
        const request = parsed.value();
        if (request.run_id != run.id or classifyUiRecordIdentity(task.durable.ui_history, run.id, pending.request_id) != .inserted)
            return null;
        const identity = reviewIdentity(task, run, pending.request_id, request.policy_generation);
        task.runtime.permission_review.identity = identity;
        task.runtime.permission_review.phase = .reviewing;
        if (inputBlocksAutomaticAllow(run)) {
            _ = self.finishPermissionReview(identity);
            return null;
        }
        const execution = task.runtime.execution() orelse return error.ReviewUnavailable;
        var config = execution.input();
        if (config.execution_generation != run.execution_generation or config.target.protocol != run.execution_protocol)
            return error.ReviewUnavailable;
        config.target.model = run.execution_model;
        var owned_execution = try owned_task_execution.OwnedTaskExecution.clone(self.allocator, config);
        errdefer owned_execution.deinit();
        const bytes = try self.allocator.alloc(u8, permission_review.max_input_bytes);
        errdefer {
            std.crypto.secureZero(u8, bytes);
            self.allocator.free(bytes);
        }
        var writer = std.Io.Writer.fixed(bytes);
        var intent_buffer: [8 * 1024]u8 = undefined;
        defer std.crypto.secureZero(u8, &intent_buffer);
        var root_intent_buffer: [8 * 1024]u8 = undefined;
        defer std.crypto.secureZero(u8, &root_intent_buffer);
        const root_intent = try reviewIntent(&run.input, &root_intent_buffer);
        var intent_writer = std.Io.Writer.fixed(&intent_buffer);
        try intent_writer.writeAll(root_intent);
        for (1..@as(usize, pending.input_adopted_count) + 1) |sequence| {
            var found = false;
            for (run.additional_inputs) |entry| if (entry) |record| {
                if (record.sequence != @as(u32, @intCast(sequence))) continue;
                try intent_writer.writeAll("\n\n[Additional user instruction]\n");
                try intent_writer.writeAll(record.text);
                found = true;
                break;
            };
            if (!found) return error.ReviewIntentUnavailable;
        }
        const intent = intent_writer.buffered();
        if (std.mem.trim(u8, intent, " \t\r\n").len == 0) return error.ReviewIntentUnavailable;
        const context = latestReviewContext(run);
        const constraints = if (agent.imageGenerationPermissionContext(request.tool.namespace, request.tool.name)) |effects| blk: {
            const start = writer.end;
            try writer.print("{s}\n{s}", .{ review_constraints, effects });
            break :blk writer.buffered()[start..];
        } else review_constraints;
        const input: permission_review.Input = .{
            .host = .{ .delegated = true, .constraints = constraints, .authorization = review_authorization },
            .user_intent = try copyReviewField(&writer, text, intent, 8 * 1024, &run.redactionSecrets()),
            .request = .{
                .tool_name = try copyReviewField(&writer, text, request.tool.name, 128, &run.redactionSecrets()),
                .arguments_json = try copyReviewField(&writer, text, request.arguments_json, 16 * 1024, &run.redactionSecrets()),
                .working_directory = try copyReviewField(&writer, text, task.durable.workspace_root, 2 * 1024, &run.redactionSecrets()),
            },
            .context = try copyReviewField(&writer, text, context, 4 * 1024, &run.redactionSecrets()),
        };
        return .{ .allocator = self.allocator, .identity = identity, .input = input, .bytes = bytes, .execution = owned_execution, .tool_namespace = request.tool.namespace };
    }

    pub fn prepareNextPermissionReview(self: *Runtime, text: TextProjection) ?PreparedPermissionReview {
        for (self.tasks) |*entry| {
            const task = &(entry.* orelse continue);
            if (self.preparePermissionReview(task.durable.id, text) catch null) |prepared| return prepared;
        }
        return null;
    }

    pub fn permissionReviewCurrent(self: *const Runtime, identity: PermissionReviewIdentity) bool {
        if (self.permission_reviews_closed) return false;
        const task = self.findConst(identity.task_id) orelse return false;
        if (!reviewTaskEligible(task) or !task.runtime.permission_review.matches(identity)) return false;
        const run = task_state.findRun(task.durable.runs, identity.run_id) orelse return false;
        return task.runtime.active_run_id == identity.run_id and
            std.meta.eql(identity, reviewIdentity(task, run, identity.request_id, identity.policy_generation)) and
            task_state.terminalPayload(run) == null and run.pending_termination.load(.acquire) == .none;
    }

    /// For capacity rejection/cancellation before a worker was started as well
    /// as reviewer failure. It never answers or expires the Agent request.
    pub fn finishPermissionReview(self: *Runtime, identity: PermissionReviewIdentity) bool {
        const task = self.find(identity.task_id) orelse return false;
        if (!task.runtime.permission_review.matches(identity)) return false;
        task.runtime.permission_review.settle(identity.request_id);
        return true;
    }

    /// Called on the main thread. No LLM invocation or worker scheduling here.
    pub fn acceptPermissionReview(
        self: *Runtime,
        identity: PermissionReviewIdentity,
        outcome: permission_review.Outcome,
        effects: PermissionReviewEffects,
    ) !bool {
        const task = self.find(identity.task_id) orelse return false;
        if (self.permission_reviews_closed) return false;
        if (!reviewTaskEligible(task) or !task.runtime.permission_review.matches(identity)) return false;
        defer _ = self.finishPermissionReview(identity);
        if (task.runtime.active_run_id != identity.run_id) return false;
        const run = task_state.findRun(task.durable.runs, identity.run_id) orelse return false;
        if (!std.meta.eql(identity, reviewIdentity(task, run, identity.request_id, identity.policy_generation)) or
            task_state.terminalPayload(run) != null or run.pending_termination.load(.acquire) != .none)
            return false;
        const suggestion = switch (outcome) {
            .failure => return false,
            .suggestion => |value| value,
        };
        const choice: PermissionChoice = switch (suggestion.decision) {
            .needs_user => return false,
            .allow_once => if (inputBlocksAutomaticAllow(run)) return false else .allow_once,
            .deny => .deny_once,
        };
        // Check the exact current SDK request, not just a saved UI observation.
        var access = task.runtime.acquireAccess() catch return false;
        defer access.deinit();
        var pending = access.copyPendingUiRequest(self.allocator) catch return false;
        defer {
            std.crypto.secureZero(u8, pending.json);
            pending.deinit();
        }
        if (pending.run_id != identity.run_id or pending.request_id != identity.request_id) return false;
        var parsed = try agent.decodePermissionRequest(self.allocator, pending.json);
        defer {
            std.crypto.secureZero(u8, @constCast(parsed.value().arguments_json));
            parsed.deinit();
        }
        const request = parsed.value();
        if (request.run_id != identity.run_id or request.policy_generation != identity.policy_generation or
            std.mem.indexOfScalar(agent.PermissionChoice, request.responses, permissionChoice(choice)) == null)
        {
            return false;
        }
        if (suggestion.reason.len == 0 or suggestion.reason.len > permission_review.max_reason_bytes) {
            return false;
        }
        if (!validReviewReason(suggestion.reason.text())) return false;
        const projected = try effects.text.project(suggestion.reason.text(), task_state.ui_record_detail_capacity, &run.redactionSecrets(), 0);
        defer {
            std.crypto.secureZero(u8, projected.value);
            effects.text.discardCandidate(projected.value);
        }
        if (projected.truncated or !validReviewReason(projected.value)) {
            return false;
        }
        var prepared = try self.respondUi(identity.task_id, identity.run_id, identity.request_id, .{ .permission = choice });
        if (!prepared.history_inserted) {
            prepared.rollback();
            return false;
        }
        const record = &task.durable.ui_history[prepared.history_slot].?;
        record.answered_by = .reviewer;
        @memcpy(record.review_reason[0..projected.value.len], projected.value);
        record.review_reason_len = projected.value.len;
        record.redacted = record.redacted or projected.redacted;
        switch (effects.commit_fn(effects.context)) {
            .committed => {},
            .failed, .outcome_unknown => {
                prepared.rollback();
                return false;
            },
        }
        prepared.deliver() catch |err| {
            // Delivery rolls back its candidate; persist that new observation.
            _ = effects.commit_fn(effects.context);
            return err;
        };
        return true;
    }

    pub fn prepareModelIntent(
        self: *Runtime,
        task_id: u64,
        expected_revision: u64,
        target: models_contract.ModelRef,
    ) ModelIntentError!PreparedModelIntent {
        const task = self.find(task_id) orelse return error.UnknownTask;
        if (task.read_only_history != null or task.durable.archived or
            task.deletion != .idle or task.runtime.close_requested)
            return error.TaskClosing;
        if (task.approval_change != null or task.model_intent_prepared) return error.TaskBusy;
        const revision = if (task.durable.model_intent) |intent| intent.revision else 0;
        if (expected_revision != revision) return error.TaskModelMismatch;
        const next_revision = std.math.add(u64, revision, 1) catch return error.InvalidTaskModel;
        const replacement = task_state.ModelIntent.init(self.allocator, target, next_revision) catch |err| switch (err) {
            error.InvalidModelIntent => return error.InvalidTaskModel,
            error.OutOfMemory => return error.OutOfMemory,
        };
        const prepared = PreparedModelIntent{
            .allocator = self.allocator,
            .task = task,
            .previous = task.durable.model_intent,
        };
        task.durable.model_intent = replacement;
        task.model_intent_prepared = true;
        return prepared;
    }

    pub fn beginDetach(
        self: *Runtime,
        task_id: u64,
        effects: OperationEffects,
    ) CloseError!bool {
        const task = self.find(task_id) orelse return error.UnknownTask;
        if (task.runtime.close_requested or task.runtime.close_thread != null)
            return error.CloseInProgress;
        const retrying = task.runtime.close_failed and
            task.runtime.hasClosingSession();
        if (task.runtime.live() == null) return false;
        _ = self.cancelInputContinuation(task_id, null, .continuation_cancelled);
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
                    &run_record.redactionSecrets()
                else if (task.runtime.execution()) |execution|
                    &.{execution.input().api_key}
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
        task.runtime.cancel_requested = task.runtime.active_operation == .run;
        if (task_state.findRun(
            task.durable.runs,
            task.runtime.active_run_id,
        )) |run_record| {
            if (!task_state.isTerminalPhase(task_state.runPhase(run_record)))
                _ = task_state.setActivePhase(run_record, .stopping);
        }
        task.runtime.close_requested = true;
        task.runtime.permission_review.invalidate();
        if (closeReady(task))
            try startCloseWorker(task, effects.worker.notifier, retrying);
        if (cancelled_ui) |record| switch (pushUiRecord(task, record)) {
            .inserted, .already_resolved => {},
            .identity_collision => if (observation_access) |*access|
                failUiRequestIdentityCollision(task, access, record.run_id),
        };
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

    pub fn taskApprovalMode(self: *const Runtime, task_id: u64) ?task_state.ApprovalMode {
        const task = self.findConst(task_id) orelse return null;
        return task_state.ApprovalMode.fromFacts(task.durable.permission_profile, task.durable.permission_review_delegated);
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

    pub fn validateExecutionBinding(self: *const Runtime, task_id: u64) error{ UnknownTask, ExecutionUnavailable, ExecutionGenerationMismatch }!void {
        const task = self.findConst(task_id) orelse return error.UnknownTask;
        _ = try taskExecutionInput(task);
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

    pub fn initialCatalogNeeded(self: *const Runtime, task_id: u64) bool {
        const task = self.findConst(task_id) orelse return false;
        return task.durable.permission_interaction == .interactive and
            !task.durable.archived and task.deletion == .idle and
            task.runtime.hasAttachedSession() and task.runtime.pinnedCatalogConst() == null and
            task.initial_catalog_preparation == .uninitialized and
            task_policy.taskLifecycle(task) == .open and !task_policy.hasActiveOperation(task);
    }

    pub fn markInitialCatalog(self: *Runtime, task_id: u64, loading: bool) void {
        const task = self.find(task_id) orelse return;
        task.initial_catalog_preparation = if (loading) .loading else .unavailable;
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
        if (task.read_only_history != null) return error.TaskReadOnly;
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
            &.{sensitive},
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
        if (task.read_only_history != null) return error.TaskReadOnly;
        if (task.model_intent_prepared or task.deletion == .deleting or
            task_policy.taskLifecycle(task) == .closing or
            task_policy.hasActiveOperation(task))
            return error.TaskBusy;
        if (task.durable.archived == archived) return false;
        task.durable.archived = archived;
        if (archived) {
            _ = self.cancelInputContinuation(task_id, null, .continuation_cancelled);
            task.runtime.permission_review.invalidate();
            acknowledgeLatestCompletion(task);
        }
        if (!archived and task.deletion == .failed) task.deletion = .idle;
        task.durable.recent_order = self.takeRecentOrder();
        return true;
    }

    /// Test-only invalidation seam; no production per-Task delegation toggle.
    pub fn testSetPermissionReviewDelegation(
        self: *Runtime,
        task_id: u64,
        delegated: bool,
    ) error{ UnknownTask, TaskBusy, UnsupportedPermissionProfile, ReviewGenerationExhausted }!bool {
        if (!@import("builtin").is_test) @compileError("permission delegation mutation is a test-only seam");
        const task = self.find(task_id) orelse return error.UnknownTask;
        if (delegated) {
            if (self.permission_reviews_closed) return error.TaskBusy;
            if (task.durable.permission_profile != .approval_required or
                task.durable.permission_interaction != .interactive)
                return error.UnsupportedPermissionProfile;
            if (task.durable.archived or task.deletion != .idle or
                task.runtime.close_requested or !task.runtime.hasAttachedSession())
                return error.TaskBusy;
            if (task.runtime.permission_review.exhausted or
                task.runtime.permission_review.generation == std.math.maxInt(u64))
                return error.ReviewGenerationExhausted;
        }
        if (task.durable.permission_review_delegated == delegated) return false;
        task.runtime.permission_review.invalidate();
        task.durable.permission_review_delegated = delegated;
        return true;
    }

    pub fn markCompletionSeen(self: *Runtime, task_id: u64, run_id: u64) bool {
        if (run_id == 0) return false;
        const task = self.find(task_id) orelse return false;
        if (task.read_only_history != null or task.durable.archived or task.deletion == .deleting) return false;
        const latest = task_policy.latestTerminalRun(task.durable.runs) orelse return false;
        const terminal = task_state.productTerminalFacts(latest) orelse unreachable;
        if (latest.id != run_id or terminal.outcome != .completed or
            task.durable.completion_seen_run_id == run_id)
            return false;
        task.durable.completion_seen_run_id = run_id;
        return true;
    }

    pub fn requestDeletion(self: *Runtime, task_id: u64) DeletionError!bool {
        const task = self.find(task_id) orelse return error.UnknownTask;
        if (task.read_only_history != null) return error.TaskReadOnly;
        if (!task.durable.archived) return error.TaskNotArchived;
        if (task.model_intent_prepared) return error.TaskBusy;
        if (task.deletion == .deleting) return false;
        task.runtime.permission_review.invalidate();
        task.deletion = .deleting;
        _ = self.cancelInputContinuation(task_id, null, .continuation_cancelled);
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
                // A requested close may still be waiting for worker leases;
                // deletion must not issue a second detach in that interval.
                .close_operation_running = task.runtime.close_requested or
                    task.runtime.close_completion.load(.acquire) == .running or
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
                    if (effects.resources_quiescent_fn) |quiescent|
                        if (!quiescent(effects.context, task.durable.id, task.durable.workspace_id)) continue;
                    const task_id = task.durable.id;
                    const workspace_id = task.durable.workspace_id;
                    var removed = task.*;
                    entry.* = null;
                    switch (effects.commitWithoutTask(workspace_id)) {
                        .committed => {
                            effects.deleteCheckpointTask(task_id);
                            effects.deleteFileChangeTask(task_id);
                            effects.deleteAttachmentTask(task_id);
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
            _ = self.cancelInputContinuation(task.durable.id, null, .workspace_removing);
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
                    .waiting_ui => if (task.permissionReviewPhase() == .reviewing) {
                        signals.running +|= 1;
                    } else {
                        signals.attention +|= 1;
                    },
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
        errdefer self.allocator.free(failures);
        for (self.failures.items, failures) |failure, *target| target.* = .{
            .task_id = failure.task_id,
            .recent_order = failure.recent_order,
            .reason = failure.reason,
        };
        var read_only_count: usize = 0;
        for (self.tasks) |entry| if (entry) |task| if (task.read_only_history != null) {
            read_only_count += 1;
        };
        const read_only_tasks = try self.allocator.alloc(
            task_persistence.ReadOnlyPayload,
            read_only_count,
        );
        var read_only_index: usize = 0;
        for (self.tasks) |entry| if (entry) |task| if (task.read_only_history) |history| {
            read_only_tasks[read_only_index] = .{
                .task_id = task.durable.id,
                .recent_order = history.recent_order,
                .payload = history.payload,
            };
            read_only_index += 1;
        };
        return .{
            .allocator = self.allocator,
            .tasks = tasks,
            .failures = failures,
            .read_only_tasks = read_only_tasks,
            .retained = self.retained.items,
            .next_task_id = self.next_task_id,
            .next_recent_order = self.next_recent_order,
        };
    }

    /// Keeps a history frame this build cannot restore so later commits write
    /// it back unchanged.
    pub fn retainRecord(
        self: *Runtime,
        record: task_persistence.RetainedRecord,
    ) std.mem.Allocator.Error!void {
        const payload = try self.allocator.dupe(u8, record.payload);
        errdefer self.allocator.free(payload);
        var owned = record;
        owned.payload = payload;
        try self.retained.append(self.allocator, owned);
    }

    pub fn retainedTaskCount(self: *const Runtime) usize {
        var count: usize = 0;
        for (self.retained.items) |record| {
            if (record.kind == .task) count += 1;
        }
        return count;
    }

    pub fn clearRetained(self: *Runtime) void {
        for (self.retained.items) |record| self.allocator.free(record.payload);
        self.retained.clearRetainingCapacity();
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

    /// `frames` holds the original frame of each wire. A Task that cannot be
    /// restored keeps that frame; a Task listed in `read_only` is restored
    /// read-only and keeps its frame for commits.
    pub fn restoreTasks(
        self: *Runtime,
        wires: []const task_persistence.TaskWire,
        frames: []const task_persistence.RetainedRecord,
        read_only: []const task_persistence.ReadOnlyPayload,
        projection: task_persistence.RestoreProjection,
    ) RestoreError!usize {
        std.debug.assert(wires.len == frames.len);
        for (self.tasks) |entry| std.debug.assert(entry == null);
        var restored_count: usize = 0;
        var retained: usize = 0;
        for (wires, frames) |wire, frame| {
            const original: ?task_persistence.ReadOnlyPayload = for (read_only) |value| {
                if (value.task_id == wire.id) break value;
            } else null;
            const payload = if (original) |value| try self.allocator.dupe(u8, value.payload) else null;
            var restored = task_persistence.restoreTask(projection, wire) catch |err| {
                if (payload) |bytes| self.allocator.free(bytes);
                switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {
                        retained += 1;
                        try self.retainRecord(frame);
                        continue;
                    },
                }
            };
            if (original) |value| restored.read_only_history = .{
                .recent_order = value.recent_order,
                .payload = payload.?,
            };
            std.debug.assert(restored_count < self.tasks.len);
            self.tasks[restored_count] = restored;
            restored_count += 1;
        }
        return retained;
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
        var context = EventContext{ .runtime = self, .effects = effects, .image_secret = if (task_state.findRun(task.durable.runs, envelope.run_id)) |run| run.redactionSecrets()[1] else &.{} };
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
        const application_result = try task_state.applyEvent(task, envelope, projection);
        if (application_result == .applied) {
            const run = task_state.findRun(task.durable.runs, envelope.run_id).?;
            for (&run.additional_inputs) |*entry| if (entry.*) |*record| {
                if (record.state != .adopted) continue;
                if (record.raw_text) |raw| self.releaseInputPayload(raw);
                record.raw_text = null;
            };
        }
        return switch (application_result) {
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

    pub fn finalizeMarkedTerminalRunsAfterEventDrain(
        self: *Runtime,
        finished_at_ms: ?u64,
        finished_at_unix_ms: ?u64,
    ) bool {
        var changed = false;
        for (self.tasks) |*entry| {
            const task = &(entry.* orelse continue);
            if (!task_state.finalizeMarkedTerminalRunsAfterEventDrain(
                task,
                finished_at_ms,
                finished_at_unix_ms,
            )) continue;
            _ = self.settleActiveRunTerminal(task);
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
                        &run.redactionSecrets(),
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

    /// Image effects and projection scrub credentials outlive both execution
    /// and event drain. Worker leases also cover automatic title production.
    pub fn releaseQuiescentImages(self: *Runtime, effects: ReleaseEffects) void {
        for (self.tasks) |*entry| {
            const task = &(entry.* orelse continue);
            if (task.runtime.worker_leases.hasLive()) continue;
            for (task.durable.runs) |*run_entry| {
                const run = &(run_entry.* orelse continue);
                if (run.event_stream_finalized and run.automatic_title.state.load(.acquire) != .running)
                    releaseImageExecution(run, effects);
            }
        }
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
                const overlay = beginCheckpointCoverageOverlay(
                    task,
                    candidate,
                ) orelse {
                    task.durable.checkpoint_attempt = .dependency_contract;
                    _ = effects.commit(null);
                    const rejected_identity = candidate.record.blob;
                    candidate.record.deinit(self.allocator);
                    postprocess.payload = .none;
                    postprocess.state.store(.settled, .release);
                    releaseCheckpointLease(postprocess);
                    effects.delete(rejected_identity);
                    return true;
                };
                switch (effects.commit(.{
                    .task_id = task.durable.id,
                    .record = &candidate.record,
                    .anchor = .available,
                })) {
                    .committed => {},
                    .failed => {
                        rollbackCheckpointCoverageOverlay(task, overlay);
                        candidate.record.deinit(self.allocator);
                        postprocess.payload = .none;
                        postprocess.state.store(.settled, .release);
                        releaseCheckpointLease(postprocess);
                        return true;
                    },
                    .outcome_unknown => {
                        rollbackCheckpointCoverageOverlay(task, overlay);
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
        approval_executor: ExecutorCancellation,
    ) void {
        for (self.approval_jobs) |entry| if (entry) |slot| {
            slot.job.requestCancellation();
            _ = approval_executor.cancel(slot.job);
        };
        self.permission_reviews_closed = true;
        for (self.tasks) |*entry| {
            const task = &(entry.* orelse continue);
            _ = self.cancelInputContinuation(task.durable.id, null, .continuation_cancelled);
            task.runtime.permission_review.invalidate();
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

    /// Called only after the Product executor has joined and checkpoint
    /// postprocesses have settled. Any remaining pending operation is visible
    /// Product history that the final checkpoint did not cover.
    pub fn excludePendingConversationTailAfterShutdown(self: *Runtime) void {
        for (self.tasks) |*entry| {
            const task = &(entry.* orelse continue);
            std.debug.assert(!task.runtime.worker_leases.hasLive());
            _ = excludePendingConversationTail(task);
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
            var credentials = RetainedCredentials{ .task = task };
            while (credentials.next()) |credential| {
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
            var credentials = RetainedCredentials{ .task = task };
            while (credentials.next()) |credential| {
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
            var credentials = RetainedCredentials{ .task = task };
            while (credentials.next()) |credential| {
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
            var credentials = RetainedCredentials{ .task = task };
            while (credentials.next()) |credential| {
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
            if (task.runtime.restore_catalog) |*snapshot| {
                if (snapshot.identityContainsCredential(credential)) {
                    effects.releaseProjectionBytes(snapshot.projected_bytes);
                    snapshot.deinit();
                    task.runtime.restore_catalog = null;
                } else snapshot.redactPresentationNoFail(credential);
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
            var available_modes: [3]task_state.ApprovalMode = undefined;
            const modes = self.availableApprovalModes(task, external, &available_modes);
            task_view.writeProjection(writer, .{
                .task = task,
                .now_ms = effects.now_ms,
                .recovery = recovery,
                .model_selection_availability = external.model_selection_availability,
                .available_approval_modes = modes,
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
            .mode = if (freshConversationAllowed(task)) .fresh else .checkpoint,
            .workspace_id = task.durable.workspace_id,
            .workspace_epoch = task.durable.workspace_epoch,
            .execution_model = task.durable.execution_model,
        };
    }

    /// Enqueues attachment reconstruction from a checkpoint or an empty
    /// Conversation. Excluded Product history supplies only allocation floors.
    pub fn startRecovery(
        self: *Runtime,
        task_id: u64,
        input: RecoveryStartInput,
    ) RecoveryStartError!u64 {
        const task = self.find(task_id) orelse return error.UnknownTask;
        if (self.inputContinuation(task_id) != null) return error.RestoreBusy;
        if (input.expected_binding_epoch == 0 or
            input.expected_binding_epoch != task.durable.binding_epoch)
            return error.BindingEpochMismatch;
        const checkpoint = task.durable.checkpoint;
        const attached_rebind = input.rebind != null and task.runtime.hasAttachedSession();
        if (attached_rebind) _ = try taskExecutionInput(task);
        if (input.workspace_id != task.durable.workspace_id or
            input.workspace_epoch != task.durable.workspace_epoch or
            (!attached_rebind and checkpoint == null and !freshConversationAllowed(task)) or
            (checkpoint != null and input.checkpoint_store == null))
            return error.RecoveryUnavailable;
        if (input.execution.execution_generation == 0 or
            (input.rebind == null and input.execution.target.protocol != task.durable.execution_protocol))
            return error.RecoveryUnavailable;
        if (task.runtime.active_operation != .none or
            (!attached_rebind and task.runtime.liveConst() != null) or task.runtime.close_requested or task.runtime.close_failed or
            task.runtime.worker_leases.hasLive() or task_state.hasUnfinalizedTerminalEvents(task) or
            task.model_intent_prepared or task.approval_change != null or task.durable.archived or
            (attached_rebind and (input.checkpoint_store == null or input.rebind.?.capabilities == null)) or
            (input.rebind != null and input.checkpoint_store != null and input.checkpoint_store_health == null))
            return error.RecoveryUnavailable;
        if (self.next_restore_attempt_id == 0 or
            self.next_restore_attempt_id == std.math.maxInt(u64))
            return error.RestoreAttemptExhausted;
        const attempt_id = self.next_restore_attempt_id;
        var checkpoint_copy = if (checkpoint) |record| try record.clone(self.allocator) else null;
        var checkpoint_live = true;
        errdefer if (checkpoint_live) if (checkpoint_copy) |*record| record.deinit(self.allocator);
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
            if (input.canonical_user_home.len != 0) epoch_token else "",
            switch (input.workspace_trust) {
                .explicitly_trusted => .explicitly_trusted,
                .temporary => .temporary,
            },
        );
        var workspace_live = true;
        errdefer if (workspace_live) workspace.deinit();
        var restored_execution = input.execution;
        if (input.rebind == null) restored_execution.target.model = task.durable.execution_model;
        var execution = try owned_task_execution.OwnedTaskExecution.clone(
            self.allocator,
            restored_execution,
        );
        execution.source_generation = input.source_generation;
        if (input.rebind) |rebind| execution.model_intent_revision = rebind.selection_revision;
        errdefer execution.deinit();
        const model = try self.allocator.dupe(u8, restored_execution.target.model);
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
                job.state.store(.cancelled, .release);
                if (job.rebind) |*rebind| if (rebind.projected_model) |value| {
                    input.rebind.?.text.discardCandidate(value);
                    rebind.projected_model = null;
                };
                if (!job.deinit()) self.recovery_poisoned = true;
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
                .run_id_floor = task_policy.runHistoryHighWater(task),
                .compact_id_floor = task_policy.compactHistoryHighWater(task),
                .ui_request_id_floor = task_policy.uiRequestHistoryHighWater(task),
                .workspace = workspace,
                .execution = execution.take(),
                .source_execution_generation = task.durable.execution_generation,
                .target_execution_generation = input.execution.execution_generation,
                .task_model = model,
                .protocol = restored_execution.target.protocol,
                .permission_mode = permission.mode,
                .shell_policy = permission.shell,
                .permission_interaction = permission.interaction,
            },
        };
        job.credential = job.attempt.execution.secret;
        restore_lease_owned = false;
        job_initialized = true;
        checkpoint_live = false;
        workspace_live = false;
        model_live = false;
        if (input.rebind) |rebind_input| {
            const intent = task.durable.model_intent orelse return error.RecoveryUnavailable;
            if (intent.revision != rebind_input.selection_revision or !std.mem.eql(u8, intent.source_id, rebind_input.source_id) or
                !std.mem.eql(u8, intent.model_id, model)) return error.RecoveryUnavailable;
            var original: ?owned_task_execution.OwnedTaskExecution = null;
            errdefer if (original) |*value| value.deinit();
            if (attached_rebind) {
                const installed = task.runtime.executionConst().?;
                original = try owned_task_execution.OwnedTaskExecution.clone(self.allocator, installed.input());
                original.?.source_generation = installed.source_generation;
                original.?.model_intent_revision = installed.model_intent_revision;
            }
            const original_model = if (attached_rebind) try self.allocator.dupe(u8, task.durable.execution_model) else null;
            errdefer if (original_model) |value| self.allocator.free(value);
            const source_id = try self.allocator.dupe(u8, rebind_input.source_id);
            errdefer self.allocator.free(source_id);
            const projected = try rebind_input.text.project(model, models_contract.Limits.model_id_bytes, &.{input.execution.api_key}, 0);
            errdefer rebind_input.text.discardCandidate(projected.value);
            var access = if (attached_rebind) try task.runtime.acquireAccess() else null;
            errdefer if (access) |*value| value.deinit();
            const capabilities = if (rebind_input.capabilities) |owner| owner.* orelse return error.RecoveryUnavailable else null;
            job.rebind = .{
                .phase = if (attached_rebind) .exporting_baseline else .restoring_target,
                .source_id = source_id,
                .selection_revision = rebind_input.selection_revision,
                .source_generation = input.source_generation,
                .catalog_generation = rebind_input.catalog_generation,
                .approval_revision = task.durable.approval_revision,
                .last_run_id = task_policy.lastConversationRunId(task) orelse 0,
                .last_compact_id = task_policy.lastConversationCompactId(task),
                .original_execution = if (original) |*value| value.take() else null,
                .original_credential = &.{},
                .original_model = original_model,
                .capabilities = capabilities,
                .projected_model = projected.value,
                .baseline_access = if (access) |*value| value.take() else null,
                .store_health = input.checkpoint_store_health,
            };
            if (rebind_input.capabilities) |owner| owner.* = null;
            if (job.rebind.?.original_execution) |value| job.rebind.?.original_credential = value.secret;
            job.export_checkpoint_fn = exportRecoveryCheckpoint;
            if (capabilities) |value| {
                job.attempt.permission_mode = value.original.permission_mode;
                job.attempt.shell_policy = value.original.shell_policy;
                job.attempt.permission_interaction = value.original.permission_interaction;
            }
        }
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
        if (task.runtime.active_operation == .none and task.runtime.attachedConst() != null and
            task.runtime.attachedConst().?.health == .available and external.model_rebind_required)
        {
            return .{
                .continuation = .{ .unavailable = if (task.runtime.last_restore_failure != null) .session_recovery_failed else .session_recovery_required },
                .recovery_available = !external.shutting_down and !task.durable.archived and task.read_only_history == null and
                    external.task_persistence_ready and external.checkpoint_store_ready and external.workspace_identity_exact and
                    external.automatic_owner_exact and external.authority_stable and external.runtime_admission == .available,
            };
        }
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
                .fresh_conversation_allowed = freshConversationAllowed(task),
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
            .history_read_only = task.read_only_history != null,
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
            const observed_pending = if (observation_access) |*access|
                access.pendingUiObservation()
            else
                null;
            var pending = observed_pending;
            if (observed_pending) |observation| switch (classifyUiRecordIdentity(
                task.durable.ui_history,
                observation.run_id,
                observation.request_id,
            )) {
                .inserted => {},
                .already_resolved => pending = null,
                .identity_collision => {
                    pending = null;
                    if (observation_access) |*access|
                        failUiRequestIdentityCollision(task, access, observation.run_id);
                    result.changed = true;
                },
            };
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
                        if (terminal.exclude_on_product_terminal and compact.coverage == .pending)
                            compact.coverage = .excluded;
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
                const terminal_changed = self.settleActiveRunTerminal(task);
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

    fn settleActiveRunTerminal(self: *Runtime, task: *task_state.Task) bool {
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
            for (&run.additional_inputs) |*entry| if (entry.*) |*record| {
                if (record.state == .adopted or record.state == .transferred) continue;
                record.state = .unknown;
                if (run.completed_input_counts) |counts| if (record.sequence) |sequence| {
                    record.state = if (sequence <= counts.adopted) .adopted else .unadopted;
                };
            };
            task_policy.foldTerminalDisposition(
                task,
                terminal.session_disposition_at_completion,
            );
            run.terminal_observed = true;
            const eligible = terminal.outcome == .completed and
                terminal.session_disposition_at_completion == .reusable and
                run.event_projection_failure == null and
                run.completed_input_counts != null and
                !run.input_continuation_cancelled and !run.input_continuation_attempted;
            var pending = false;
            for (&run.additional_inputs) |*entry| if (entry.*) |*record| {
                if (eligible and record.state == .unadopted and record.raw_text != null) {
                    pending = true;
                } else {
                    if (record.raw_text) |raw| self.releaseInputPayload(raw);
                    record.raw_text = null;
                }
            };
            run.input_continuation_pending = pending;
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
    ) LifecycleSync {
        var result: LifecycleSync = .{};
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
                    const rebind_close = if (task.runtime.restore_job) |job| if (job.rebind) |rebind|
                        rebind.phase == .closing_original or rebind.phase == .closing_candidate
                    else
                        false else false;
                    std.debug.assert(task.runtime.worker_leases.liveCount() == @as(usize, if (rebind_close) 1 else 0));
                    result.durable_changed = excludePendingConversationTail(task) or
                        result.durable_changed;
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
                    task.runtime.close_requested = false;
                    task.runtime.close_failed = false;
                },
                .failed_reusable, .failed_poisoned, .failed_closing => {
                    task.runtime.close_requested = false;
                    task.runtime.close_failed = true;
                    if (task.deletion == .deleting) task.deletion = .failed;
                    if (task.runtime.discarding_restore) task.runtime.last_restore_failure = .candidate_cleanup_failed;
                    switch (completion) {
                        .failed_reusable => task.runtime.restoreCloseFailure(if (task.runtime.discarding_restore) .session_poisoned else .available),
                        .failed_poisoned => task.runtime.restoreCloseFailure(.session_poisoned),
                        .failed_closing => {},
                        else => unreachable,
                    }
                },
                .none, .running => unreachable,
            }
            task.runtime.cancel_requested = false;
            result.changed = true;
        }
        return result;
    }

    /// A poisoned Session cannot accept another operation. Once the operation
    /// that produced that disposition and its checkpoint transaction have
    /// settled, route it through the ordinary close/release owner so the Task
    /// can become detached and use Conversation recovery. Close failures stay
    /// attached/closing and require an explicit retry; otherwise a persistent
    /// destroy failure would become a busy automatic retry loop.
    pub fn requestPoisonedSessionCloses(self: *Runtime) bool {
        var changed = false;
        for (self.tasks) |*entry| {
            const task = &(entry.* orelse continue);
            if (task.deletion == .deleting or
                task.runtime.close_requested or
                task.runtime.close_failed or
                task.runtime.close_thread != null)
                continue;
            const attached = task.runtime.attachedConst() orelse continue;
            if (attached.health != .session_poisoned) continue;
            task.runtime.close_requested = true;
            changed = true;
        }
        return changed;
    }

    fn syncRequestedCloses(
        self: *Runtime,
        notifier: task_execution.Notifier,
    ) bool {
        var changed = false;
        for (self.tasks) |*entry| {
            const task = &(entry.* orelse continue);
            if (!task.runtime.close_requested or !closeReady(task)) continue;
            const retrying = task.runtime.hasClosingSession();
            startCloseWorker(task, notifier, retrying) catch {
                task.runtime.close_requested = false;
                task.runtime.close_failed = true;
            };
            changed = true;
        }
        return changed;
    }

    fn retireUnusedRecoveryCheckpoint(task: *const task_state.Task, record: checkpoint_record.Record, effects: RecoveryEffects) void {
        if (task.durable.checkpoint) |current| if (checkpointIdentityEqual(current.blob, record.blob)) return;
        if (effects.retire_checkpoint_fn) |retire| retire(effects.context, record.blob);
    }

    fn finishRecovery(self: *Runtime, task: *task_state.Task, job: *recovery_job.Job, effects: RecoveryEffects, release: ReleaseEffects) void {
        // Pending/unknown history owns every possible witness. Main must
        // resolve it, or transfer the barrier to Control during shutdown;
        // Control declines all retirement while shutting down.
        std.debug.assert(job.binding_commit != .pending and job.binding_commit != .outcome_unknown);
        if (job.attempt.checkpoint) |record| retireUnusedRecoveryCheckpoint(task, record, effects);
        if (job.outcome == .baseline) retireUnusedRecoveryCheckpoint(task, job.outcome.baseline, effects);
        if (job.rebind) |*rebind| {
            if (rebind.baseline) |record| retireUnusedRecoveryCheckpoint(task, record, effects);
            if (rebind.projected_model) |value| {
                release.releaseProjectionBytes(value.len);
                self.allocator.free(value);
                rebind.projected_model = null;
            }
            if (task.runtime.restore_catalog) |*snapshot| {
                release.releaseProjectionBytes(snapshot.projected_bytes);
                snapshot.deinit();
                task.runtime.restore_catalog = null;
            }
        }
        task.runtime.restore_job = null;
        task.runtime.active_operation = .none;
        if (!job.deinit()) {
            self.recovery_poisoned = true;
            task.runtime.last_restore_failure = .candidate_cleanup_failed;
        }
    }

    fn rebindAuthority(task: *const task_state.Task, job: *const recovery_job.Job, effects: RecoveryEffects) RecoveryExternalAuthority {
        const rebind = &job.rebind.?;
        return effects.authority(.{
            .task_id = task.durable.id,
            .workspace_id = task.durable.workspace_id,
            .workspace_epoch = task.durable.workspace_epoch,
            .target_execution_generation = job.attempt.target_execution_generation,
            .task_model = job.attempt.task_model,
            .protocol = job.attempt.protocol,
            .model_intent = if (rebind.phase == .restoring_original) null else rebind.authority(),
            .original_restore = rebind.phase == .restoring_original,
        });
    }

    fn enqueueRecovery(job: *recovery_job.Job, effects: RecoveryEffects) void {
        job.outcome = .none;
        job.state.store(.queued, .release);
        const executor = effects.executor orelse {
            job.outcome = .{ .failure = .runtime_unavailable };
            job.state.store(.completed, .release);
            return;
        };
        executor.enqueue(job, job, recovery_job.Job.execute, recovery_job.Job.cancelQueued) catch |err| {
            job.outcome = .{ .failure = if (err == error.QueueFull) .runtime_busy else .runtime_unavailable };
            job.state.store(.completed, .release);
        };
    }

    fn beginOriginalRestore(self: *Runtime, task: *task_state.Task, job: *recovery_job.Job, effects: RecoveryEffects, release: ReleaseEffects) void {
        const rebind = &job.rebind.?;
        if (rebind.original_execution == null or !rebind.original_execution.?.owned or effects.refresh_capabilities_fn == null or
            !effects.refresh_capabilities_fn.?(effects.context, task.durable.id))
        {
            self.finishRecovery(task, job, effects, release);
            return;
        }
        const authority = rebindAuthority(task, job, effects);
        if (authority.shutting_down or !authority.workspace_authority_exact or !authority.automatic_owner_exact) {
            self.finishRecovery(task, job, effects, release);
            return;
        }
        job.credential = &.{};
        job.attempt.execution.deinit();
        job.attempt.execution = rebind.original_execution.?.take();
        job.credential = job.attempt.execution.secret;
        self.allocator.free(job.attempt.task_model);
        job.attempt.task_model = rebind.original_model.?;
        rebind.original_model = null;
        job.attempt.protocol = job.attempt.execution.protocol;
        job.attempt.source_execution_generation = task.durable.execution_generation;
        job.attempt.target_execution_generation = job.attempt.execution.execution_generation;
        job.attempt.binding_epoch = task.durable.binding_epoch;
        job.attempt.checkpoint.?.anchor.binding_epoch = task.durable.binding_epoch;
        rebind.phase = .restoring_original;
        job.binding_commit = .not_started;
        job.cancellation.store(false, .release);
        enqueueRecovery(job, effects);
    }

    /// Advances preparation on the composition thread. Core export/restore,
    /// history confirmation and close each retain their existing worker owner.
    fn syncRebindPreparation(self: *Runtime, task: *task_state.Task, job: *recovery_job.Job, effects: RecoveryEffects, release: ReleaseEffects, notifier: task_execution.Notifier) enum { waiting, changed, candidate } {
        const rebind = &job.rebind.?;
        switch (rebind.phase) {
            .exporting_baseline => {
                if (job.outcome == .baseline) {
                    var duplicate = job.outcome.baseline.clone(self.allocator) catch {
                        task.runtime.last_restore_failure = .checkpoint_io;
                        self.finishRecovery(task, job, effects, release);
                        return .changed;
                    };
                    if (job.attempt.checkpoint) |*previous| previous.deinit(self.allocator);
                    job.attempt.checkpoint = duplicate;
                    duplicate = undefined;
                    rebind.baseline = job.outcome.baseline;
                    job.outcome = .none;
                    rebind.phase = .confirming_baseline;
                    return .changed;
                }
                task.runtime.last_restore_failure = job.failure() orelse .checkpoint_io;
                if (rebind.export_poisoned) if (task.runtime.attached()) |attached| {
                    attached.health = .session_poisoned;
                };
                self.finishRecovery(task, job, effects, release);
                return .changed;
            },
            .confirming_baseline => {
                switch (job.binding_commit) {
                    .pending, .outcome_unknown => return .waiting,
                    .not_started => {
                        if (job.cancellation.load(.acquire)) {
                            task.runtime.last_restore_failure = .cancelled;
                            self.finishRecovery(task, job, effects, release);
                            return .changed;
                        }
                        const candidate: task_state.CheckpointCandidate = .{ .record = rebind.baseline.?, .metrics = .{ .chunk_count = 0, .export_duration_ns = 0 } };
                        const overlay = beginCheckpointCoverageOverlay(task, &candidate) orelse {
                            task.runtime.last_restore_failure = .checkpoint_mismatch;
                            self.finishRecovery(task, job, effects, release);
                            return .changed;
                        };
                        const previous = task.durable.checkpoint;
                        const previous_anchor = task.durable.checkpoint_anchor;
                        task.durable.checkpoint = rebind.baseline;
                        task.durable.checkpoint_anchor = .available;
                        const commit = effects.queueBinding(task.durable.id) catch |err| failed: {
                            break :failed @as(?DurableCommit, if (err == error.TaskBusy or err == error.QueueFull) null else .failed);
                        };
                        task.durable.checkpoint = previous;
                        task.durable.checkpoint_anchor = previous_anchor;
                        rollbackCheckpointCoverageOverlay(task, overlay);
                        if (commit) |outcome| job.binding_commit = switch (outcome) {
                            .committed => .committed,
                            .failed => .failed,
                            .outcome_unknown => .outcome_unknown,
                        };
                        return if (job.binding_commit == .not_started) .waiting else .changed;
                    },
                    .failed => {
                        task.runtime.last_restore_failure = task.runtime.last_restore_failure orelse .binding_persistence_failed;
                        self.finishRecovery(task, job, effects, release);
                        return .changed;
                    },
                    .committed => {
                        const candidate: task_state.CheckpointCandidate = .{ .record = rebind.baseline.?, .metrics = .{ .chunk_count = 0, .export_duration_ns = 0 } };
                        _ = beginCheckpointCoverageOverlay(task, &candidate) orelse unreachable;
                        if (task.durable.checkpoint) |*old| {
                            if (!checkpointIdentityEqual(old.blob, rebind.baseline.?.blob))
                                if (effects.retire_checkpoint_fn) |retire| retire(effects.context, old.blob);
                            old.deinit(self.allocator);
                        }
                        task.durable.checkpoint = rebind.baseline;
                        task.durable.checkpoint_anchor = .available;
                        task.durable.checkpoint_attempt = .none;
                        rebind.baseline = null;
                        job.binding_commit = .not_started;
                        const authority = rebindAuthority(task, job, effects);
                        if (job.cancellation.load(.acquire) or authority.shutting_down or !authority.workspace_authority_exact or
                            !authority.automatic_owner_exact or !authority.target_execution_authority_exact)
                        {
                            task.runtime.last_restore_failure = if (job.cancellation.load(.acquire)) .cancelled else .restore_rejected;
                            self.finishRecovery(task, job, effects, release);
                            return .changed;
                        }
                        std.debug.assert(task.runtime.worker_leases.liveCount() == 1);
                        const attached = task.runtime.attached().?;
                        task.runtime.restore_catalog = attached.pinned_catalog;
                        attached.pinned_catalog = null;
                        rebind.phase = .closing_original;
                        startCloseWorker(task, notifier, false) catch {
                            task.runtime.attached().?.pinned_catalog = task.runtime.restore_catalog;
                            task.runtime.restore_catalog = null;
                            task.runtime.last_restore_failure = .runtime_busy;
                            self.finishRecovery(task, job, effects, release);
                        };
                        return .changed;
                    },
                }
            },
            .closing_original, .closing_candidate => {
                if (task.runtime.close_thread != null) return .waiting;
                if (task.runtime.close_failed) {
                    if (rebind.phase == .closing_original) if (task.runtime.live()) |live| {
                        live.pinned_catalog = task.runtime.restore_catalog;
                        task.runtime.restore_catalog = null;
                    };
                    task.runtime.last_restore_failure = .candidate_cleanup_failed;
                    self.finishRecovery(task, job, effects, release);
                    return .changed;
                }
                if (task.runtime.attachment != .detached) return .waiting;
                const authority = rebindAuthority(task, job, effects);
                if (authority.shutting_down) {
                    task.runtime.last_restore_failure = .cancelled;
                    self.finishRecovery(task, job, effects, release);
                    return .changed;
                }
                if (rebind.phase == .closing_candidate or job.cancellation.load(.acquire) or
                    !authority.workspace_authority_exact or !authority.automatic_owner_exact or !authority.target_execution_authority_exact)
                {
                    rebind.failure = rebind.failure orelse .restore_rejected;
                    self.beginOriginalRestore(task, job, effects, release);
                    return .changed;
                }
                rebind.phase = .restoring_target;
                enqueueRecovery(job, effects);
                return .changed;
            },
            .restoring_target, .restoring_original => {
                if (job.outcome == .candidate) return .candidate;
                task.runtime.last_restore_failure = job.failure() orelse .restore_rejected;
                if (rebind.phase == .restoring_target) {
                    rebind.failure = task.runtime.last_restore_failure;
                    self.beginOriginalRestore(task, job, effects, release);
                } else self.finishRecovery(task, job, effects, release);
                return .changed;
            },
        }
    }

    pub fn syncRecoveryCompletions(
        self: *Runtime,
        effects: RecoveryEffects,
        release: ReleaseEffects,
        notifier: task_execution.Notifier,
    ) RecoverySync {
        var result: RecoverySync = .{};
        for (self.tasks) |*entry| {
            const task = &(entry.* orelse continue);
            const job = task.runtime.restore_job orelse continue;
            if (!job.completionReady()) continue;
            if (job.rebind != null) switch (self.syncRebindPreparation(task, job, effects, release, notifier)) {
                .waiting => continue,
                .changed => {
                    result.changed = true;
                    continue;
                },
                .candidate => {},
            };
            const external = if (job.rebind != null) rebindAuthority(task, job, effects) else effects.authority(.{
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
            if (job.outcome == .candidate) {
                const rejection: ?recovery_job.Failure = if (job.cancellation.load(.acquire)) .cancelled else job.outcome.candidate.rejection;
                if (rejection) |reason| task.runtime.last_restore_failure = reason;
                const checkpoint_matches = if (job.rebind != null and job.rebind.?.phase == .restoring_original) original: {
                    const expected = job.attempt.checkpoint.?;
                    const current = task.durable.checkpoint orelse break :original false;
                    break :original std.mem.eql(u8, current.session.logical_session_id, expected.session.logical_session_id) and
                        current.session.last_run_id == expected.session.last_run_id and current.session.last_compact_id == expected.session.last_compact_id;
                } else if (job.attempt.checkpoint) |expected|
                    if (task.durable.checkpoint) |record|
                        checkpointIdentityEqual(record.blob, expected.blob) and task_policy.checkpointMatchesCurrentHistory(task, record)
                    else
                        false
                else
                    freshConversationAllowed(task) and
                        task_policy.runHistoryHighWater(task) == job.attempt.run_id_floor and
                        task_policy.compactHistoryHighWater(task) == job.attempt.compact_id_floor and
                        task_policy.uiRequestHistoryHighWater(task) == job.attempt.ui_request_id_floor;
                const allowed = rejection == null and recovery_job.commitAllowed(
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
                        .task_model = if (job.rebind != null) job.attempt.task_model else task.durable.execution_model,
                        .protocol = if (job.rebind != null) job.attempt.protocol else task.durable.execution_protocol,
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
                const advances_binding = job.attempt.source_execution_generation != job.attempt.target_execution_generation;
                if (advances_binding or job.rebind != null) {
                    switch (job.binding_commit) {
                        .pending, .outcome_unknown => continue,
                        .not_started => if (allowed) adoption: {
                            const previous_epoch = task.durable.binding_epoch;
                            if (advances_binding and previous_epoch == std.math.maxInt(u64)) {
                                task.runtime.last_restore_failure = .binding_epoch_exhausted;
                                install_candidate = false;
                                break :adoption;
                            }
                            const next_epoch = previous_epoch + @as(u64, if (advances_binding) 1 else 0);
                            const previous_checkpoint = task.durable.checkpoint;
                            const previous_model = task.durable.execution_model;
                            const previous_protocol = task.durable.execution_protocol;
                            var checkpoint = job.outcome.candidate.checkpoint;
                            if (checkpoint == null) checkpoint = previous_checkpoint;
                            if (advances_binding) if (checkpoint) |*record| {
                                record.adoptBindingEpoch(previous_epoch, next_epoch) catch {
                                    task.runtime.last_restore_failure = .binding_persistence_failed;
                                    install_candidate = false;
                                    break :adoption;
                                };
                            };
                            task.durable.checkpoint = checkpoint;
                            if (job.rebind) |rebind| {
                                if (rebind.phase == .restoring_target or !std.mem.eql(u8, previous_model, job.attempt.task_model))
                                    task.durable.execution_model = rebind.projected_model.?;
                                task.durable.execution_protocol = job.attempt.protocol;
                            }
                            task.durable.execution_generation = job.attempt.target_execution_generation;
                            task.durable.binding_epoch = next_epoch;
                            const commit = effects.queueBinding(task.durable.id) catch |err| failed: {
                                if (err == error.TaskBusy or err == error.QueueFull) break :failed null;
                                break :failed @as(?DurableCommit, .failed);
                            };
                            task.durable.execution_generation = job.attempt.source_execution_generation;
                            task.durable.binding_epoch = previous_epoch;
                            task.durable.checkpoint = previous_checkpoint;
                            task.durable.execution_model = previous_model;
                            task.durable.execution_protocol = previous_protocol;
                            // null means an accepted worker or temporarily full
                            // writer. Composition marks pending upon admission.
                            if (commit) |outcome| job.binding_commit = switch (outcome) {
                                .committed => .committed,
                                .failed => .failed,
                                .outcome_unknown => .outcome_unknown,
                            };
                            if (job.binding_commit != .not_started) result.changed = true;
                            continue;
                        },
                        .committed => {
                            // Durable truth must be adopted even if external
                            // authority became stale after the writer started.
                            std.debug.assert(task.durable.binding_epoch == job.attempt.binding_epoch);
                            std.debug.assert(task.durable.execution_generation == job.attempt.source_execution_generation);
                            const previous_epoch = task.durable.binding_epoch;
                            const next_epoch = previous_epoch + @as(u64, if (advances_binding) 1 else 0);
                            if (job.rebind) |*rebind| {
                                if (job.outcome.candidate.checkpoint) |value| {
                                    var record = value;
                                    if (advances_binding) record.adoptBindingEpoch(previous_epoch, next_epoch) catch unreachable;
                                    if (task.durable.checkpoint) |*old| {
                                        // The original baseline is still needed
                                        // for a possible rollback. A superseded
                                        // committed target is no longer needed.
                                        const baseline_owned = if (job.attempt.checkpoint) |baseline| checkpointIdentityEqual(old.blob, baseline.blob) else false;
                                        if (!baseline_owned and !checkpointIdentityEqual(old.blob, record.blob))
                                            if (effects.retire_checkpoint_fn) |retire| retire(effects.context, old.blob);
                                        old.deinit(self.allocator);
                                    }
                                    task.durable.checkpoint = record;
                                } else if (advances_binding) if (task.durable.checkpoint) |*record| record.adoptBindingEpoch(previous_epoch, next_epoch) catch unreachable;
                                job.outcome.candidate.checkpoint = null;
                                if (rebind.phase == .restoring_target or !std.mem.eql(u8, task.durable.execution_model, job.attempt.task_model)) {
                                    const previous_model = task.durable.execution_model;
                                    task.durable.execution_model = rebind.projected_model.?;
                                    rebind.projected_model = previous_model;
                                }
                                task.durable.execution_protocol = job.attempt.protocol;
                            } else if (task.durable.checkpoint) |*record| record.adoptBindingEpoch(previous_epoch, next_epoch) catch unreachable;
                            task.durable.binding_epoch = next_epoch;
                            task.durable.execution_generation = job.attempt.target_execution_generation;
                        },
                        .failed => {
                            if (task.runtime.last_restore_failure != .binding_persistence_unknown and task.runtime.last_restore_failure != .cancelled)
                                task.runtime.last_restore_failure = .binding_persistence_failed;
                            install_candidate = false;
                        },
                    }
                }
                var candidate = job.takeCandidate().?;
                if (candidate.checkpoint) |*record| {
                    retireUnusedRecoveryCheckpoint(task, record.*, effects);
                    record.deinit(self.allocator);
                }
                if (install_candidate) {
                    task.runtime.last_restore_report = candidate.report;
                    task.runtime.last_restore_permission = if (candidate.report) |report| .{
                        .restored_rules = report.restored_permission_rules,
                        .invalidated_rules = report.invalidated_permission_rules,
                    } else null;
                    var pinned: ?product_skill.catalog.Snapshot = null;
                    if (job.rebind != null and job.rebind.?.capabilities != null) {
                        const rebind = &job.rebind.?;
                        pinned = task.runtime.restore_catalog;
                        task.runtime.restore_catalog = null;
                        if (pinned) |*snapshot| for (snapshot.skills) |*skill| {
                            const granted = if (rebind.capabilities) |capabilities| if (capabilities.skill) |inputs| inputs.borrow().policy.granted_skill_ids else &.{} else &.{};
                            skill.enabled = skill.enabled and for (granted) |id| {
                                if (std.mem.eql(u8, id, skill.skill_id)) break true;
                            } else false;
                        };
                        if (pinned) |*snapshot| if (candidate.report) |report| if (report.invalidated_skill_authority != 0) {
                            snapshot.health = .degraded;
                        };
                        task.initial_catalog_preparation = .unavailable;
                    } else {
                        task.runtime.mcp_authority_at_creation = .unavailable;
                        task.initial_catalog_preparation = .uninitialized;
                    }
                    task.runtime.attachment = .{ .attached = .{
                        .binding = candidate.takeBinding(),
                        .execution = candidate.takeExecution(),
                        .pinned_catalog = pinned,
                    } };
                    task.conversation_observation = .{};
                    task.runtime.last_restore_failure = if (job.rebind) |rebind| if (rebind.phase == .restoring_original) rebind.failure else null else null;
                } else {
                    std.debug.assert(task.runtime.attachment == .detached);
                    release.redactAll(candidate.execution.input().api_key);
                    job.credential = &.{};
                    if (job.rebind) |*rebind| if (rebind.original_credential.ptr == candidate.execution.secret.ptr) {
                        rebind.original_credential = &.{};
                    };
                    candidate.execution.clearCredential();
                    // Only the ordinary close worker receives this binding.
                    // It is never published as an executable attachment.
                    task.initial_catalog_preparation = .uninitialized;
                    task.runtime.attachment = .{ .attached = .{
                        .binding = candidate.takeBinding(),
                        .execution = candidate.takeExecution(),
                        .pinned_catalog = null,
                        .health = .session_poisoned,
                    } };
                    std.debug.assert(task.runtime.beginClosing());
                    task.runtime.discarding_restore = true;
                    task.runtime.close_requested = true;
                    if (job.rebind) |*rebind| {
                        rebind.failure = rebind.failure orelse task.runtime.last_restore_failure orelse .restore_rejected;
                        const restore_original = !external.shutting_down and rebind.phase != .restoring_original and
                            rebind.original_execution != null and rebind.original_execution.?.owned;
                        if (restore_original) {
                            rebind.phase = .closing_candidate;
                            task.runtime.close_requested = false;
                            startCloseWorker(task, notifier, true) catch {
                                task.runtime.close_failed = true;
                            };
                            result.changed = true;
                            continue;
                        }
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
            self.finishRecovery(task, job, effects, release);
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

        const recovery = self.syncRecoveryCompletions(effects.recovery, effects.release, effects.notifier);
        result.changed = recovery.changed or result.changed;
        result.durable_changed = recovery.durable_changed or result.durable_changed;
        result.mcp_refresh_needed = recovery.mcp_refresh_needed;

        result.changed = self.requestPermissionStops() or result.changed;
        const operations = self.syncOperationRecords();
        result.changed = operations.changed or result.changed;
        result.durable_changed = operations.durable_changed or result.durable_changed;
        result.changed = self.syncCheckpointPostprocesses(effects.checkpoint) or result.changed;
        result.changed = self.requestPoisonedSessionCloses() or result.changed;
        result.changed = self.syncRequestedCloses(effects.notifier) or result.changed;
        const closes = self.syncCloseCompletions(effects.release);
        result.changed = closes.changed or result.changed;
        result.durable_changed = closes.durable_changed or result.durable_changed;
        // Checkpoint/close reconciliation above can retire the final lease on
        // this very pass. Do not retain the scrub credential until another wake.
        self.releaseQuiescentImages(effects.release);
        return result;
    }
};

const CheckpointCoverageOverlay = struct {
    prior_run_id: u64,
    prior_compact_id: u64,
    next_run_id: u64,
    next_compact_id: u64,
};

fn beginCheckpointCoverageOverlay(
    task: *task_state.Task,
    candidate: *const task_state.CheckpointCandidate,
) ?CheckpointCoverageOverlay {
    const record = candidate.record;
    record.validateBinding(task.durable.id, task.durable.binding_epoch) catch
        return null;
    const prior_run_id = if (task.durable.checkpoint) |prior|
        prior.session.last_run_id
    else
        0;
    const prior_compact_id = if (task.durable.checkpoint) |prior|
        prior.session.last_compact_id
    else
        0;
    if (record.session.last_run_id < prior_run_id or
        record.session.last_compact_id < prior_compact_id)
        return null;

    for (task.durable.runs) |*entry| {
        const run = &(entry.* orelse continue);
        switch (run.coverage) {
            .excluded => {},
            .covered => if (run.id > prior_run_id or
                run.id > record.session.last_run_id) return null,
            .pending => if (run.id <= prior_run_id or
                run.id > record.session.last_run_id) return null,
        }
    }
    for (task.durable.compacts) |*entry| {
        const compact = &(entry.* orelse continue);
        switch (compact.coverage) {
            .excluded => {},
            .covered => if (compact.id > prior_compact_id or
                compact.id > record.session.last_compact_id) return null,
            .pending => if (compact.id <= prior_compact_id or
                compact.id > record.session.last_compact_id) return null,
        }
    }

    const overlay: CheckpointCoverageOverlay = .{
        .prior_run_id = prior_run_id,
        .prior_compact_id = prior_compact_id,
        .next_run_id = record.session.last_run_id,
        .next_compact_id = record.session.last_compact_id,
    };
    for (task.durable.runs) |*entry| {
        const run = &(entry.* orelse continue);
        if (run.coverage == .pending) run.coverage = .covered;
    }
    for (task.durable.compacts) |*entry| {
        const compact = &(entry.* orelse continue);
        if (compact.coverage == .pending) compact.coverage = .covered;
    }
    if (!task_policy.checkpointMatchesCurrentHistory(task, record)) {
        rollbackCheckpointCoverageOverlay(task, overlay);
        return null;
    }
    return overlay;
}

fn rollbackCheckpointCoverageOverlay(
    task: *task_state.Task,
    overlay: CheckpointCoverageOverlay,
) void {
    for (task.durable.runs) |*entry| {
        const run = &(entry.* orelse continue);
        if (run.coverage == .covered and
            run.id > overlay.prior_run_id and
            run.id <= overlay.next_run_id)
            run.coverage = .pending;
    }
    for (task.durable.compacts) |*entry| {
        const compact = &(entry.* orelse continue);
        if (compact.coverage == .covered and
            compact.id > overlay.prior_compact_id and
            compact.id <= overlay.next_compact_id)
            compact.coverage = .pending;
    }
}

fn excludePendingConversationTail(task: *task_state.Task) bool {
    var changed = false;
    for (task.durable.runs) |*entry| {
        const run = &(entry.* orelse continue);
        if (run.coverage == .pending) {
            run.coverage = .excluded;
            changed = true;
        }
    }
    for (task.durable.compacts) |*entry| {
        const compact = &(entry.* orelse continue);
        if (compact.coverage == .pending) {
            compact.coverage = .excluded;
            changed = true;
        }
    }
    return changed;
}

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

fn redactInputProjection(input: *task_state.RunInputRecord, credential: []const u8, effects: RedactionEffects) void {
    switch (input.*) {
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
}

fn redactTaskProjection(
    task: *task_state.Task,
    credential: []const u8,
    effects: RedactionEffects,
) void {
    if (task.send_input_result) |*result| _ = effects.redact(result.operation_id[0..result.operation_id_len], credential);
    task.durable.title_redacted = effects.redact(task.durable.title, credential) or
        task.durable.title_redacted;
    _ = effects.redact(task.durable.workspace_root, credential);
    _ = effects.redact(task.durable.execution_model, credential);
    for (task.durable.runs) |*entry| {
        const run = &(entry.* orelse continue);
        redactInputProjection(&run.input, credential, effects);
        for (&run.additional_inputs) |*message| if (message.*) |*record| {
            record.redacted = effects.redact(record.text, credential) or record.redacted;
            _ = effects.redact(record.operation_id[0..record.operation_id_len], credential);
        };
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
        redacted = effects.redact(
            record.review_reason[0..record.review_reason_len],
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
    if (classifyUiRecordIdentity(
        task.durable.ui_history,
        pending.run_id,
        pending.request_id,
    ) != .inserted) {
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
    return redactTrackedTextSecrets(target, &.{ credential, context.image_secret });
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
    return redactTrackedTextSecrets(target, &.{ credential, context.image_secret });
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
        &.{ credential, context.image_secret },
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
        &run_record.redactionSecrets(),
        0,
    );
    errdefer context.effects.text.discardCandidate(owned_name.value);
    const owned_input = try context.effects.text.project(
        input,
        context.effects.max_tool_field_bytes,
        &run_record.redactionSecrets(),
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
            &.{ credential, context.image_secret },
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
            &.{ credential, context.image_secret },
            0,
        );
        owned.display_path = display.value;
        display_live = true;
        const kind = try context.effects.text.project(
            reference.kind,
            context.effects.max_file_ref_field_bytes,
            &.{ credential, context.image_secret },
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
            &run.redactionSecrets(),
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
                &run.redactionSecrets(),
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
    return redactTrackedTextSecrets(target, &.{credential});
}

fn redactTrackedTextSecrets(target: *task_state.TrackedText, secrets: []const []const u8) bool {
    std.debug.assert(target.committed_len <= target.list.items.len);
    var read = target.committed_len;
    var write = target.committed_len;
    var redacted = false;
    while (read < target.list.items.len) {
        const value = target.list.items;
        var match_end: usize = 0;
        var cursor = read;
        while (cursor == read or cursor < match_end) : (cursor += utf8CodepointLen(value, cursor)) {
            for (secrets) |secret| if (credentialEndAtCodepoint(value, cursor, secret)) |end| {
                match_end = @max(match_end, end);
            };
        }
        if (match_end != 0) {
            const redaction_end = match_end;
            const marker_len = @min(redaction_end - read, 3);
            @memset(target.list.items[write..][0..marker_len], '*');
            write += marker_len;
            read = redaction_end;
            redacted = true;
            continue;
        }
        const partial = for (secrets) |secret| {
            if (credentialMayContinueAtCodepoint(value, read, secret)) break true;
        } else false;
        if (partial) {
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

fn releaseImageExecution(run: *task_state.RunRecord, effects: ReleaseEffects) void {
    if (run.image_execution) |*image| {
        effects.redactAll(image.candidate.input().bearer);
        image.deinit();
        run.image_execution = null;
    }
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
    if (candidate.model_intent) |*intent| intent.deinit(self.allocator);
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

fn freshConversationAllowed(task: *const task_state.Task) bool {
    return task.durable.checkpoint == null and
        task_policy.maxCoveredRunId(task) == 0 and
        task_policy.maxCoveredCompactId(task) == 0 and
        !task_policy.hasPendingConversationCoverage(task);
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
    parts: *[agent.multimodal_input_limits.max_parts]agent.InputPart,
) RunError!agent.RunInput {
    return switch (input) {
        .text => |value| .{ .text = value },
        .multimodal => |multimodal| blk: {
            if (multimodal.attachments.len == 0) return error.InvalidRunInput;
            var part_count: usize = 0;
            if (multimodal.text.len != 0) {
                parts[part_count] = .{ .text = multimodal.text };
                part_count += 1;
            }
            if (multimodal.attachments.len > parts.len - part_count)
                return error.RunInputTooLarge;
            var has_text_attachment = false;
            for (multimodal.attachments) |item| {
                if (part_count >= parts.len) return error.RunInputTooLarge;
                parts[part_count] = switch (item.kind) {
                    .image => .{ .image = .{
                        .format = switch (item.format orelse return error.InvalidRunInput) {
                            .png => .png,
                            .jpeg => .jpeg,
                            .webp => .webp,
                        },
                        .bytes = item.bytes,
                    } },
                    .file => text: {
                        if (item.format != null) return error.InvalidRunInput;
                        has_text_attachment = true;
                        break :text .{ .text_attachment = .{
                            .display_name = item.display_name,
                            .bytes = item.bytes,
                        } };
                    },
                };
                part_count += 1;
                if (item.reference.len != 0) {
                    if (part_count >= parts.len) return error.RunInputTooLarge;
                    parts[part_count] = .{ .text_attachment = .{ .display_name = item.display_name, .bytes = item.reference } };
                    part_count += 1;
                }
            }
            if (has_text_attachment and
                std.mem.trim(u8, multimodal.text, " \t\r\n").len == 0)
                return error.MissingInstruction;
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
            if (bytes > @min(limits.max_user_message_bytes, 64 * 1024))
                return error.ProjectionCapacity;
            for (skill_input.argument_values) |value| {
                if (!std.unicode.utf8ValidateSlice(value))
                    return error.InvalidSkillArguments;
                bytes = std.math.add(usize, bytes, value.len) catch
                    return error.ProjectionCapacity;
                if (bytes > @min(limits.max_user_message_bytes, 64 * 1024))
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
    credentials: []const []const u8,
    effects: OperationEffects,
) RunError!task_state.RunInputRecord {
    return switch (input) {
        .text => |value| blk: {
            if (value.len > effects.limits.max_user_message_bytes)
                return error.ProjectionCapacity;
            const projected = try effects.text.project(
                value,
                effects.limits.max_user_message_bytes,
                credentials,
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
                    credentials,
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
                    credentials,
                    0,
                );
                record.* = .{
                    .kind = item.kind,
                    .format = item.source_format orelse item.format,
                    .display_name = display.value,
                    .size_bytes = item.size_bytes orelse item.bytes.len,
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
                credentials,
                0,
            );
            errdefer effects.text.discardCandidate(invocation.value);
            const display = try effects.text.project(
                skill.display_name,
                effects.limits.max_catalog_projection_bytes,
                credentials,
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
                    credentials,
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
    var input_record = try copyRunInput(self, task, input, &.{ execution.api_key, if (effects.image_execution) |owned| if (owned.*) |*image| image.candidate.input().bearer else &.{} else &.{} }, effects);
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
        .submitted_at_unix_ms = effects.run_clock.nowUnixMs(),
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
        &.{credential},
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

fn cleanRunEffects(effects: OperationEffects) OperationEffects {
    var clean = effects;
    clean.model_target = null;
    clean.image_execution = null;
    return clean;
}

fn applyModelIntent(
    self: *Runtime,
    task: *task_state.Task,
    access: *task_agent_session.Access,
    effects: OperationEffects,
) RunError!void {
    if (task.model_intent_prepared) return error.TaskPersistenceOutcomeUnknown;
    const intent = task.durable.model_intent orelse return;
    const installed = task.runtime.execution().?;
    if (installed.model_intent_revision == intent.revision) return;
    const target = effects.model_target orelse return error.ExecutionUnavailable;
    if (!std.mem.eql(u8, intent.model_id, target.target.model)) return error.ExecutionGenerationMismatch;
    if (!installed.matchesSource(target))
        return error.ExecutionGenerationMismatch;
    if (std.mem.eql(u8, intent.model_id, task.durable.execution_model)) {
        installed.model_intent_revision = intent.revision;
        return;
    }
    const owned_model = try self.allocator.dupe(u8, intent.model_id);
    errdefer self.allocator.free(owned_model);
    const previous = task.durable.execution_model;
    const replacement = try effects.text.project(intent.model_id, effects.limits.max_model_id_bytes, &.{installed.secret}, previous.len);
    errdefer {
        effects.text.discardCandidate(replacement.value);
        effects.text.restorePrevious(previous.len);
    }
    // Every fallible Host allocation precedes the Session mutation.
    try access.setModel(intent.model_id);
    task.durable.execution_model = replacement.value;
    effects.text.discardPrevious(previous);
    self.allocator.free(installed.model);
    installed.model = owned_model;
    installed.model_intent_revision = intent.revision;
}

fn cancelTaskAutomaticTitles(task: *task_state.Task) void {
    for (task.durable.runs) |*entry| {
        const run = &(entry.* orelse continue);
        run.automatic_title.cancel_requested.store(true, .release);
        task_execution.publishAutomaticTitleFallback(run);
    }
}

fn acknowledgeLatestCompletion(task: *task_state.Task) void {
    const latest = task_policy.latestTerminalRun(task.durable.runs) orelse return;
    const terminal = task_state.productTerminalFacts(latest) orelse unreachable;
    if (terminal.outcome == .completed)
        task.durable.completion_seen_run_id = latest.id;
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

/// Read-only secret views stay stable while the worker transfers its owned
/// execution into a candidate. No worker mutates these composition views.
const RetainedCredentials = struct {
    task: *const task_state.Task,
    index: usize = 0,

    fn next(self: *RetainedCredentials) ?[]const u8 {
        while (self.index < 3 + self.task.durable.runs.len) {
            const index = self.index;
            self.index += 1;
            if (index == 0) {
                if (self.task.runtime.executionConst()) |execution| return execution.secret;
            } else if (index == 1) {
                if (self.task.runtime.restore_job) |job| return job.credential;
            } else if (index == 2) {
                if (self.task.runtime.restore_job) |job| if (job.rebind) |rebind| return rebind.original_credential;
            } else {
                if (self.task.durable.runs[index - 3]) |*run| if (run.image_execution) |*image| return image.candidate.input().bearer;
            }
        }
        return null;
    }
};

fn exportRecoveryCheckpoint(job: *recovery_job.Job, access: *task_agent_session.Access, model: []const u8) recovery_job.ExportOutcome {
    const rebind = &job.rebind.?;
    var work: approval_job.CheckpointWork = .{
        .access = access.*,
        .store = job.store.?,
        .store_health = rebind.store_health.?,
        .limits = job.checkpoint_limits,
        .task_id = job.attempt.task_id,
        .binding_epoch = job.attempt.binding_epoch,
        .approval_revision = rebind.approval_revision,
        .last_run_id = rebind.last_run_id,
        .last_compact_id = rebind.last_compact_id,
        .model = model,
        .expected_mode = job.attempt.permission_mode,
        .target_mode = job.attempt.permission_mode,
        .mutate = false,
    };
    return switch (approval_job.exportCheckpoint(job.allocator, &job.cancellation, &work)) {
        .checkpoint => |record| .{ .checkpoint = record },
        .failure => |failure| .{ .failure = .{ .reason = switch (failure.reason) {
            .cancelled => .cancelled,
            .busy => .runtime_busy,
            else => .checkpoint_io,
        }, .poisoned = failure.restore_required } },
        .none, .history, .retired => unreachable,
    };
}

fn closeReady(task: *const task_state.Task) bool {
    if (task.runtime.active_operation != .none or
        task_state.hasUnfinalizedTerminalEvents(task) or
        task.runtime.worker_leases.hasLive())
        return false;
    for (task.durable.runs) |*entry| {
        const run = &(entry.* orelse continue);
        switch (run.checkpoint.state.load(.acquire)) {
            .none, .settled => {},
            .exporting, .failure_ready, .candidate_ready => return false,
        }
    }
    for (task.durable.compacts) |*entry| {
        const compact = &(entry.* orelse continue);
        switch (compact.checkpoint.state.load(.acquire)) {
            .none, .settled => {},
            .exporting, .failure_ready, .candidate_ready => return false,
        }
    }
    return true;
}

fn startCloseWorker(
    task: *task_state.Task,
    notifier: task_execution.Notifier,
    retrying: bool,
) std.Thread.SpawnError!void {
    const prior_health = if (task.runtime.attached()) |attached|
        attached.health
    else
        task_attachment.AttachedHealth.available;
    if (!retrying) std.debug.assert(task.runtime.beginClosing());
    const binding = task.runtime.closingWorkerBinding() orelse unreachable;
    task.runtime.close_failed = false;
    task.runtime.close_completion.store(.running, .release);
    task.runtime.close_thread = std.Thread.spawn(.{}, closeWorker, .{
        &task.runtime.close_completion,
        binding,
        notifier,
    }) catch |err| {
        task.runtime.close_completion.store(.none, .release);
        task.runtime.close_requested = false;
        if (retrying)
            task.runtime.close_failed = true
        else
            task.runtime.restoreCloseFailure(prior_health);
        return err;
    };
    task.runtime.close_requested = false;
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

fn failUiRequestIdentityCollision(
    task: *task_state.Task,
    access: *task_agent_session.Access,
    run_id: u64,
) void {
    task.runtime.pending_ui_request_id = 0;
    task.runtime.pending_ui_order = 0;
    task.runtime.cancel_requested = true;
    if (task_state.findRun(task.durable.runs, run_id)) |run_record| {
        if (!task_state.isTerminalPhase(task_state.runPhase(run_record))) {
            _ = task_state.setActivePhase(run_record, .stopping);
        }
    }
    access.failUiRequestIdentityContract(run_id) catch {};
    poisonAttachment(task);
}

fn reviewTaskEligible(task: *const task_state.Task) bool {
    if (task.approval_change != null) return false;
    const attached = task.runtime.attachedConst() orelse return false;
    return task.durable.permission_review_delegated and
        task.durable.permission_profile == .approval_required and
        task.durable.permission_interaction == .interactive and
        !task.durable.archived and task.deletion == .idle and
        !task.runtime.close_requested and !task.runtime.cancel_requested and
        task.runtime.active_operation == .run and task.runtime.active_run_id != 0 and
        task.runtime.active_operation.run == task.runtime.active_run_id and
        !task.runtime.permission_review.exhausted and
        attached.health == .available;
}

fn reviewIdentity(task: *const task_state.Task, run: *const task_state.RunRecord, request_id: u64, policy_generation: u64) PermissionReviewIdentity {
    return .{
        .task_id = task.durable.id,
        .run_id = run.id,
        .run_generation = run.generation,
        .execution_generation = run.execution_generation,
        .binding_epoch = task.durable.binding_epoch,
        .workspace_epoch = task.durable.workspace_epoch,
        .route_id = task.runtime.routeId(),
        .request_id = request_id,
        .policy_generation = policy_generation,
        .delegation_generation = task.runtime.permission_review.generation,
    };
}

fn inputBlocksAutomaticAllow(run: *const task_state.RunRecord) bool {
    if (run.agent_handoff.load(.acquire) != .running) return true;
    var lease = run.run_control.tryAcquireLease() orelse return true;
    defer lease.deinit();
    return lease.inputObservation().blocksAutomaticAllow();
}

fn latestReviewContext(run: *const task_state.RunRecord) []const u8 {
    if (run.commentary_count == 0) return "No closed Agent commentary is available; prior Tool output is omitted.";
    const end: usize = @intCast(run.commentary_ends[run.commentary_count - 1]);
    const start: usize = if (run.commentary_count < 2) 0 else @intCast(run.commentary_ends[run.commentary_count - 2]);
    return run.assistant.list.items[start..end];
}

/// Only explicit user-selected input metadata is included. Skill instructions,
/// attachment contents and Tool output do not become authorization evidence.
fn reviewIntent(input: *const task_state.RunInputRecord, buffer: []u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    switch (input.*) {
        .text => |value| return value.value,
        .skill => |value| std.json.Stringify.value(.{
            .kind = "explicit_skill_selection",
            .invocation_name = value.invocation_name,
            .display_name = value.display_name,
            .argument_values = value.argument_values,
            .limitation = "Skill instructions are not included; selection alone does not authorize every operation.",
        }, .{}, &writer) catch return error.ReviewInputLimit,
        .multimodal => |value| std.json.Stringify.value(.{
            .kind = "explicit_multimodal_input",
            .text = value.text,
            .attachments = value.attachments,
            .limitation = "Attachment contents are not included; do not infer their instructions from filenames.",
        }, .{}, &writer) catch return error.ReviewInputLimit,
    }
    return writer.buffered();
}

fn copyReviewField(writer: *std.Io.Writer, text: TextProjection, value: []const u8, max: usize, credentials: []const []const u8) ![]const u8 {
    if (value.len > max) return error.ReviewInputLimit;
    if (!std.unicode.utf8ValidateSlice(value)) return error.ReviewInputInvalid;
    const projected = try text.project(value, max, credentials, 0);
    defer {
        std.crypto.secureZero(u8, projected.value);
        text.discardCandidate(projected.value);
    }
    if (projected.truncated) return error.ReviewInputLimit;
    const start = writer.end;
    writer.writeAll(projected.value) catch return error.ReviewInputLimit;
    return writer.buffer[start..writer.end];
}

fn validReviewReason(value: []const u8) bool {
    if (value.len == 0 or value.len > task_state.ui_record_detail_capacity or
        !std.unicode.utf8ValidateSlice(value) or std.mem.trim(u8, value, " \t\r\n").len == 0)
        return false;
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}

fn prepareUiRecord(
    self: *Runtime,
    access: *task_agent_session.Access,
    run_id: u64,
    request_id: u64,
    response: UiResponse,
    secrets: []const []const u8,
) ControlError!task_state.UiRecord {
    var record = task_state.UiRecord{
        .request_id = request_id,
        .run_id = run_id,
        .kind = kindForResponse(response),
        .state = stateForResponse(response),
        .answered_by = .user,
    };
    var pending = try access.copyPendingUiRequest(self.allocator);
    defer {
        std.crypto.secureZero(u8, pending.json);
        pending.deinit();
    }
    if (pending.run_id != run_id or pending.request_id != request_id) return error.StaleUiResponse;
    var parsed = agent.decodePermissionRequest(self.allocator, pending.json) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidUiResponse,
    };
    defer {
        std.crypto.secureZero(u8, @constCast(parsed.value().arguments_json));
        parsed.deinit();
    }
    const request = parsed.value();
    // Validate before inserting the history candidate and invalidating review.
    // Session delivery still rechecks freshness and encodes the actual response.
    if (request.run_id != run_id or
        std.mem.indexOfScalar(agent.PermissionChoice, request.responses, permissionChoice(response.permission)) == null)
        return error.InvalidUiResponse;
    switch (response.permission) {
        .allow_session, .deny_session => if (request.candidate == null) return error.InvalidUiResponse,
        .allow_once, .deny_once => {},
    }
    fillUiRecord(&record, request, secrets);
    return record;
}

fn prepareCancelledUiRecord(
    self: *Runtime,
    access: *task_agent_session.Access,
    run_id: u64,
    secrets: []const []const u8,
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
    fillUiRecord(&record, parsed.value(), secrets);
    return record;
}

fn fillUiRecord(
    record: *task_state.UiRecord,
    permission: agent.PermissionRequest,
    secrets: []const []const u8,
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
        secrets,
    );
    record.detail_len = projected.len;
    record.detail_truncated = projected.truncated;
    record.redacted = projected.redacted;
}

const UiRecordInsertion = enum {
    inserted,
    already_resolved,
    identity_collision,
};

fn classifyUiRecordIdentity(
    history: []const ?task_state.UiRecord,
    run_id: u64,
    request_id: u64,
) UiRecordInsertion {
    for (history) |entry| if (entry) |existing| {
        if (existing.request_id != request_id) continue;
        return if (existing.run_id == run_id)
            .already_resolved
        else
            .identity_collision;
    };
    return .inserted;
}

fn pushUiRecord(
    task: *task_state.Task,
    record: task_state.UiRecord,
) UiRecordInsertion {
    const identity = classifyUiRecordIdentity(
        task.durable.ui_history,
        record.run_id,
        record.request_id,
    );
    if (identity != .inserted) {
        if (identity == .already_resolved and
            task.runtime.active_run_id == record.run_id and
            task.runtime.pending_ui_request_id == record.request_id)
        {
            task.runtime.pending_ui_request_id = 0;
            task.runtime.pending_ui_order = 0;
        }
        return identity;
    }
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
    return .inserted;
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
    releaseImageExecution(run, effects);
    releaseAutomaticTitle(&run.automatic_title);
    for (run.tools) |*entry| if (entry.*) |*tool|
        deinitTool(self, effects, tool);
    self.allocator.free(run.tools);
    for (run.file_changes) |*entry| if (entry.*) |*change|
        deinitFileChange(self, effects, change);
    if (run.file_changes.len != 0) self.allocator.free(run.file_changes);
    self.allocator.free(run.commentary_ends);
    deinitRunInput(self, effects, &run.input);
    self.discardInputPayloads(run);
    for (run.additional_inputs) |entry| if (entry) |record| {
        releaseProjectedSlice(self, effects, record.text);
        effects.releaseProjectionBytes(task_state.additional_input_projection_bytes);
    };
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
    std.debug.assert(task.runtime.restore_catalog == null);
    releaseAttachmentNoFail(self, task, effects, .cold_start);
    for (task.durable.runs) |*entry| if (entry.*) |*run|
        deinitRun(self, effects, run);
    self.allocator.free(task.durable.runs);
    for (task.durable.compacts) |*entry| if (entry.*) |*compact|
        deinitCompact(self, effects, compact);
    self.allocator.free(task.durable.compacts);
    self.allocator.free(task.durable.ui_history);
    if (task.durable.model_intent) |*intent| intent.deinit(self.allocator);
    releaseProjectedSlice(self, effects, task.durable.execution_model);
    releaseProjectedSlice(self, effects, task.durable.workspace_root);
    releaseProjectedSlice(self, effects, task.durable.title);
    if (task.durable.checkpoint) |*checkpoint|
        checkpoint.deinit(self.allocator);
    if (task.approval_change) |*change| {
        if (change.candidate) |*candidate| candidate.deinit(self.allocator);
        if (change.unknown_history) |history| self.allocator.free(history.bytes);
    }
    if (task.read_only_history) |history| self.allocator.free(history.payload);
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

fn testModelIntentTask() task_state.Task {
    return .{
        .durable = .{
            .id = 1,
            .recent_order = 1,
            .execution_generation = 7,
            .execution_protocol = .openai_responses,
            .execution_model = @constCast("installed-model"),
            .permission_profile = .approval_required,
            .permission_interaction = .interactive,
            .workspace_id = 1,
            .workspace_root = @constCast("root"),
            .title = @constCast("title"),
            .runs = &.{},
            .compacts = &.{},
            .ui_history = &.{},
        },
        .runtime = .{},
    };
}

test "Task model intent transaction uses its own revision and rolls back without Session effects" {
    var runtime = try Runtime.init(std.testing.allocator, 1);
    defer runtime.deinitStorage();
    runtime.tasks[0] = testModelIntentTask();
    const task = runtime.find(1).?;
    defer {
        if (task.durable.model_intent) |*intent| intent.deinit(runtime.allocator);
        runtime.tasks[0] = null;
    }
    const target = models_contract.ModelRef{ .source_id = "provider-b", .model_id = "same-model" };
    try std.testing.expectError(error.UnknownTask, runtime.prepareModelIntent(2, 0, target));
    try std.testing.expectError(error.TaskModelMismatch, runtime.prepareModelIntent(1, 1, target));
    try std.testing.expect(task.durable.model_intent == null);
    var first = try runtime.prepareModelIntent(1, 0, target);
    try std.testing.expectEqual(@as(u64, 1), task.durable.model_intent.?.revision);
    try std.testing.expectError(error.TaskBusy, runtime.prepareModelIntent(1, 1, target));
    first.rollback();
    try std.testing.expect(task.durable.model_intent == null);
    try std.testing.expect(!task.model_intent_prepared);

    first = try runtime.prepareModelIntent(1, 0, target);
    first.complete();
    try std.testing.expect(!task.model_intent_prepared);
    const original_source = task.durable.model_intent.?.source_id.ptr;
    var second = try runtime.prepareModelIntent(1, 1, .{ .source_id = "provider-c", .model_id = "same-model" });
    try std.testing.expectEqual(@as(u64, 2), task.durable.model_intent.?.revision);
    second.rollback();
    try std.testing.expectEqual(original_source, task.durable.model_intent.?.source_id.ptr);
    try std.testing.expectEqualStrings("provider-b", task.durable.model_intent.?.source_id);
    try std.testing.expectEqual(@as(u64, 1), task.durable.model_intent.?.revision);
    try std.testing.expectError(error.TaskModelMismatch, runtime.prepareModelIntent(1, 0, target));
    try std.testing.expectError(error.InvalidTaskModel, runtime.prepareModelIntent(1, 1, .{ .source_id = "bad\nsource", .model_id = "model" }));

    // The same transaction is legal while a Run is active. It neither obtains
    // Session access nor changes the Run/permission/installed binding facts.
    task.runtime.active_operation = .{ .run = 12 };
    task.runtime.active_run_id = 12;
    task.runtime.pending_ui_request_id = 33;
    second = try runtime.prepareModelIntent(1, 1, .{ .source_id = "provider-c", .model_id = "same-model" });
    second.complete();
    try std.testing.expectEqualStrings("provider-c", task.durable.model_intent.?.source_id);
    try std.testing.expectEqual(@as(u64, 2), task.durable.model_intent.?.revision);
    try std.testing.expectEqual(@as(u64, 12), task.runtime.active_operation.run);
    try std.testing.expectEqual(@as(u64, 12), task.runtime.active_run_id);
    try std.testing.expectEqual(@as(u64, 33), task.runtime.pending_ui_request_id);
    try std.testing.expectEqual(task_state.PermissionProfile.approval_required, task.durable.permission_profile);
    try std.testing.expectEqualStrings("installed-model", task.durable.execution_model);
    try std.testing.expectEqual(@as(u64, 7), task.durable.execution_generation);
    try std.testing.expectEqual(@as(u64, 1), task.durable.binding_epoch);
    try std.testing.expect(task.runtime.attachment == .detached);

    task.durable.archived = true;
    try std.testing.expectError(error.TaskClosing, runtime.prepareModelIntent(1, 2, target));
    task.durable.archived = false;
    task.durable.model_intent.?.revision = std.math.maxInt(u64);
    try std.testing.expectError(error.InvalidTaskModel, runtime.prepareModelIntent(1, std.math.maxInt(u64), target));
    try std.testing.expectEqualStrings("provider-c", task.durable.model_intent.?.source_id);
}

test "Task model intent allocation failure preserves the exact committed identity" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            var runtime = try Runtime.init(allocator, 1);
            defer runtime.deinitStorage();
            runtime.tasks[0] = testModelIntentTask();
            const task = runtime.find(1).?;
            defer {
                if (task.durable.model_intent) |*intent| intent.deinit(allocator);
                runtime.tasks[0] = null;
            }
            task.durable.model_intent = try task_state.ModelIntent.init(allocator, .{ .source_id = "source", .model_id = "model" }, 5);
            const previous = task.durable.model_intent.?;
            var prepared = runtime.prepareModelIntent(1, 5, .{ .source_id = "new-source", .model_id = "new-model" }) catch |err| {
                try std.testing.expectEqual(previous.source_id.ptr, task.durable.model_intent.?.source_id.ptr);
                try std.testing.expectEqual(previous.model_id.ptr, task.durable.model_intent.?.model_id.ptr);
                try std.testing.expectEqual(@as(u64, 5), task.durable.model_intent.?.revision);
                return err;
            };
            prepared.rollback();
            try std.testing.expectEqual(previous.source_id.ptr, task.durable.model_intent.?.source_id.ptr);
            try std.testing.expectEqual(previous.model_id.ptr, task.durable.model_intent.?.model_id.ptr);
        }
    }.run, .{});
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

test "permission review delegation defaults off is revocable and is independent of profile" {
    var runtime = try Runtime.init(std.testing.allocator, 1);
    defer runtime.deinitStorage();
    runtime.tasks[0] = .{
        .durable = .{
            .id = 1,
            .recent_order = 1,
            .execution_generation = 1,
            .execution_protocol = .openai_responses,
            .execution_model = @constCast("m"),
            .permission_profile = .approval_required,
            .permission_interaction = .interactive,
            .workspace_id = 1,
            .workspace_root = @constCast("root"),
            .title = @constCast("title"),
            .runs = &.{},
            .compacts = &.{},
            .ui_history = &.{},
        },
        .runtime = .{ .attachment = .{ .attached = .{
            .binding = task_agent_session.Binding.testFixture(1),
            .execution = undefined,
            .pinned_catalog = null,
        } } },
    };
    defer runtime.tasks[0] = null;
    const task = runtime.find(1).?;
    try std.testing.expect(!task.durable.permission_review_delegated);
    try std.testing.expect(try runtime.testSetPermissionReviewDelegation(1, true));
    const generation = task.runtime.permission_review.generation;
    try std.testing.expect(!try runtime.testSetPermissionReviewDelegation(1, true));
    try std.testing.expectEqual(generation, task.runtime.permission_review.generation);
    try std.testing.expect(try runtime.testSetPermissionReviewDelegation(1, false));
    try std.testing.expect(try runtime.testSetPermissionReviewDelegation(1, true));
    try std.testing.expect(task.runtime.permission_review.generation > generation);
    try std.testing.expectEqual(.approval_required, task.durable.permission_profile);
    task.runtime.close_requested = true;
    try std.testing.expect(try runtime.testSetPermissionReviewDelegation(1, false));
    try std.testing.expectError(error.TaskBusy, runtime.testSetPermissionReviewDelegation(1, true));
    task.runtime.close_requested = false;
    task.durable.permission_profile = .full_access;
    try std.testing.expectError(error.UnsupportedPermissionProfile, runtime.testSetPermissionReviewDelegation(1, true));
    task.durable.permission_profile = .approval_required;
    task.durable.permission_interaction = .noninteractive;
    try std.testing.expectError(error.UnsupportedPermissionProfile, runtime.testSetPermissionReviewDelegation(1, true));
    task.durable.permission_interaction = .interactive;
    task.runtime.permission_review.generation = std.math.maxInt(u64);
    try std.testing.expectError(error.ReviewGenerationExhausted, runtime.testSetPermissionReviewDelegation(1, true));
}

test "UI history distinguishes idempotent settlement from cross-Run collision" {
    const history = [_]?task_state.UiRecord{
        .{
            .request_id = 9,
            .run_id = 3,
            .kind = .permission,
            .state = .allowed_once,
        },
        null,
    };
    try std.testing.expectEqual(
        UiRecordInsertion.already_resolved,
        classifyUiRecordIdentity(&history, 3, 9),
    );
    try std.testing.expectEqual(
        UiRecordInsertion.identity_collision,
        classifyUiRecordIdentity(&history, 4, 9),
    );
    try std.testing.expectEqual(
        UiRecordInsertion.inserted,
        classifyUiRecordIdentity(&history, 4, 10),
    );

    var runs: [0]?task_state.RunRecord = .{};
    var compacts: [0]?task_state.CompactRecord = .{};
    var mutable_history = history;
    var task = task_state.Task{
        .durable = .{
            .id = 1,
            .recent_order = 1,
            .execution_generation = 1,
            .execution_protocol = .anthropic_messages,
            .execution_model = @constCast("model"),
            .permission_profile = .approval_required,
            .permission_interaction = .interactive,
            .workspace_id = 1,
            .workspace_root = @constCast("root"),
            .title = @constCast("title"),
            .runs = &runs,
            .compacts = &compacts,
            .ui_history = &mutable_history,
            .ui_history_count = 1,
            .ui_history_next = 1,
        },
        .runtime = .{
            .active_run_id = 3,
            .pending_ui_request_id = 9,
            .pending_ui_order = 7,
        },
    };
    try std.testing.expectEqual(
        UiRecordInsertion.already_resolved,
        pushUiRecord(&task, .{
            .request_id = 9,
            .run_id = 3,
            .kind = .permission,
            .state = .denied,
        }),
    );
    try std.testing.expectEqual(@as(u64, 0), task.runtime.pending_ui_request_id);
    try std.testing.expectEqual(@as(usize, 1), task.durable.ui_history_count);

    task.runtime.active_run_id = 4;
    task.runtime.pending_ui_request_id = 9;
    task.runtime.pending_ui_order = 8;
    try std.testing.expectEqual(
        UiRecordInsertion.identity_collision,
        pushUiRecord(&task, .{
            .request_id = 9,
            .run_id = 4,
            .kind = .permission,
            .state = .denied,
        }),
    );
    try std.testing.expectEqual(@as(u64, 9), task.runtime.pending_ui_request_id);
    try std.testing.expectEqual(@as(usize, 1), task.durable.ui_history_count);
}

test "permission review intent includes only bounded explicit Skill and multimodal metadata" {
    var buffer: [8 * 1024]u8 = undefined;
    var arguments = [_][]u8{@constCast("src/main.zig")};
    var skill: task_state.RunInputRecord = .{ .skill = .{
        .skill_id = @constCast("skill-id"),
        .catalog_revision = @constCast("catalog"),
        .invocation_name = @constCast("inspect"),
        .display_name = @constCast("Inspect code"),
        .argument_values = &arguments,
    } };
    const skill_intent = try reviewIntent(&skill, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, skill_intent, "explicit_skill_selection") != null);
    try std.testing.expect(std.mem.indexOf(u8, skill_intent, "src/main.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, skill_intent, "skill-id") == null);
    var short: [8]u8 = undefined;
    try std.testing.expectError(error.ReviewInputLimit, reviewIntent(&skill, &short));
    var attachments = [_]task_state.AttachmentRecord{.{
        .kind = .file,
        .format = null,
        .display_name = @constCast("instructions.txt"),
        .size_bytes = 12,
    }};
    var multimodal: task_state.RunInputRecord = .{ .multimodal = .{ .text = null, .attachments = &attachments } };
    const multimodal_intent = try reviewIntent(&multimodal, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, multimodal_intent, "explicit_multimodal_input") != null);
    try std.testing.expect(std.mem.indexOf(u8, multimodal_intent, "Attachment contents are not included") != null);
    var decoded = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, multimodal_intent, .{});
    defer decoded.deinit();
    try std.testing.expect(decoded.value.object.get("text").? == .null);
    try std.testing.expectEqualStrings("instructions.txt", decoded.value.object.get("attachments").?.array.items[0].object.get("display_name").?.string);
}

test "pending model rebind never hides poisoned or closing attachment truth" {
    var runtime = try Runtime.init(std.testing.allocator, 1);
    defer runtime.deinitStorage();
    var task: task_state.Task = .{
        .durable = .{
            .id = 1,
            .recent_order = 1,
            .execution_generation = 1,
            .execution_protocol = .openai_responses,
            .execution_model = @constCast("m"),
            .permission_profile = .approval_required,
            .permission_interaction = .interactive,
            .workspace_id = 1,
            .workspace_root = @constCast("root"),
            .title = @constCast("title"),
            .runs = &.{},
            .compacts = &.{},
            .ui_history = &.{},
        },
        .runtime = .{ .attachment = .{ .attached = .{
            .binding = task_agent_session.Binding.testFixture(1),
            .execution = undefined,
            .pinned_catalog = null,
        } } },
    };
    const authority: ProjectionAuthority = .{
        .shutting_down = false,
        .task_persistence_ready = true,
        .checkpoint_store_ready = true,
        .execution_admission = .available,
        .workspace_identity_exact = true,
        .automatic_owner_exact = true,
        .runtime_admission = .available,
        .authority_stable = true,
        .model_selection_availability = .available,
        .model_rebind_required = true,
    };
    const healthy = runtime.recoveryProjectionWithAuthority(&task, authority);
    try std.testing.expect(healthy.recovery_available);
    try std.testing.expectEqual(.session_recovery_required, healthy.continuation.unavailable);
    task.runtime.attached().?.health = .session_poisoned;
    const poisoned = runtime.recoveryProjectionWithAuthority(&task, authority);
    try std.testing.expect(!poisoned.recovery_available);
    try std.testing.expectEqual(.session_poisoned, poisoned.continuation.unavailable);
    try std.testing.expect(task.runtime.beginClosing());
    const closing = runtime.recoveryProjectionWithAuthority(&task, authority);
    try std.testing.expect(!closing.recovery_available);
    try std.testing.expectEqual(.closing, closing.continuation.unavailable);
}

test "approval intent CAS, no-op, delegation commit and history authority stay distinct" {
    const Harness = struct {
        fn authority(context: *anyopaque, _: ProjectionAuthorityQuery) ProjectionAuthority {
            const facts: *const ProjectionAuthority = @ptrCast(@alignCast(context));
            return facts.*;
        }
    };
    var runtime = try Runtime.init(std.testing.allocator, 1);
    defer runtime.deinitStorage();
    runtime.tasks[0] = .{
        .durable = .{
            .id = 1,
            .recent_order = 1,
            .execution_generation = 1,
            .execution_protocol = .openai_responses,
            .execution_model = @constCast("m"),
            .permission_profile = .approval_required,
            .permission_interaction = .interactive,
            .workspace_id = 1,
            .workspace_root = @constCast("root"),
            .title = @constCast("title"),
            .runs = &.{},
            .compacts = &.{},
            .ui_history = &.{},
        },
        .runtime = .{ .attachment = .{ .attached = .{
            .binding = task_agent_session.Binding.testFixture(1),
            .execution = undefined,
            .pinned_catalog = null,
        } } },
    };
    defer runtime.tasks[0] = null;

    const task = runtime.find(1).?;
    var authority = ProjectionAuthority{ .shutting_down = false, .task_persistence_ready = true, .checkpoint_store_ready = true, .execution_admission = .available, .workspace_identity_exact = true, .automatic_owner_exact = true, .runtime_admission = .available, .authority_stable = true, .model_selection_availability = .available };
    const effects = RecoveryAdmissionEffects{ .context = &authority, .authority_fn = Harness.authority };
    const generation = task.runtime.permission_review.generation;
    var mode_buffer: [3]task_state.ApprovalMode = undefined;
    try std.testing.expectEqualSlices(task_state.ApprovalMode, &.{ .manual, .auto_review, .full_access }, runtime.availableApprovalModes(task, authority, &mode_buffer));
    authority.checkpoint_store_ready = false;
    try std.testing.expectEqualSlices(task_state.ApprovalMode, &.{ .manual, .auto_review }, runtime.availableApprovalModes(task, authority, &mode_buffer));
    authority.checkpoint_store_ready = true;
    task.durable.permission_interaction = .noninteractive;
    try std.testing.expectEqual(@as(usize, 0), runtime.availableApprovalModes(task, authority, &mode_buffer).len);
    task.durable.permission_interaction = .interactive;
    authority.shutting_down = true;
    try std.testing.expectEqual(@as(usize, 0), runtime.availableApprovalModes(task, authority, &mode_buffer).len);
    authority.shutting_down = false;
    try std.testing.expect(task.approval_change == null);
    try std.testing.expectEqual(generation, task.runtime.permission_review.generation);
    try std.testing.expectEqual(@as(u64, 1), try runtime.beginApprovalChange(1, 1, 1, .manual, effects));
    try std.testing.expectEqual(generation, task.runtime.permission_review.generation);
    try std.testing.expect(task.approval_change == null);
    try std.testing.expectError(error.BindingEpochMismatch, runtime.beginApprovalChange(1, 2, 1, .auto_review, effects));
    try std.testing.expectError(error.ApprovalRevisionMismatch, runtime.beginApprovalChange(1, 1, 2, .auto_review, effects));
    try std.testing.expectEqual(@as(u64, 2), try runtime.beginApprovalChange(1, 1, 1, .auto_review, effects));
    try std.testing.expect(task_policy.hasActiveOperation(task));
    try std.testing.expect(!task.durable.permission_review_delegated);
    try std.testing.expectEqual(@as(usize, 0), runtime.availableApprovalModes(task, authority, &mode_buffer).len);
    try std.testing.expectError(error.TaskBusy, runtime.beginApprovalChange(1, 1, 1, .manual, effects));
    task.approval_change.?.phase = .mode_commit;
    const prepared = try runtime.prepareApprovalCommit(1);
    try std.testing.expect(task.durable.permission_review_delegated);
    try std.testing.expectEqual(@as(u64, 2), task.durable.approval_revision);
    prepared.rollback();
    try std.testing.expect(!task.durable.permission_review_delegated);
    try std.testing.expectEqual(@as(u64, 1), task.durable.approval_revision);
    try std.testing.expectEqual(null, try runtime.acceptApprovalCommit(1));
    try std.testing.expect(task.durable.permission_review_delegated);
    try std.testing.expectEqual(@as(u64, 2), task.durable.approval_revision);
    try std.testing.expect(task.approval_change == null);
    task.runtime.pending_ui_request_id = 7;
    _ = try runtime.beginApprovalChange(1, 1, 2, .manual, effects);
    try std.testing.expectEqual(.needs_user, task.runtime.permission_review.phase);
    try std.testing.expectEqual(@as(u64, 7), task.runtime.permission_review.settled_request_id);
    task.approval_change.?.phase = .outcome_unknown;
    try std.testing.expect(runtime.approvalHistoryBlocked());
    task.approval_change.?.phase = .mode_commit;
    try std.testing.expectEqual(null, try runtime.acceptApprovalCommit(1));
    try std.testing.expectEqual(@as(u64, 3), task.durable.approval_revision);
    try std.testing.expect(!task.durable.permission_review_delegated);
    // A -> B -> A returns to the same mode, but an old intent remains stale,
    // including an otherwise harmless no-op or delayed duplicate.
    const settled_generation = task.runtime.permission_review.generation;
    try std.testing.expectError(error.ApprovalRevisionMismatch, runtime.beginApprovalChange(1, 1, 1, .manual, effects));
    try std.testing.expectError(error.ApprovalRevisionMismatch, runtime.beginApprovalChange(1, 1, 2, .auto_review, effects));
    try std.testing.expectError(error.BindingEpochMismatch, runtime.beginApprovalChange(1, 0, 3, .auto_review, effects));
    try std.testing.expectEqual(@as(u64, 3), try runtime.beginApprovalChange(1, 1, 3, .manual, effects));
    try std.testing.expectEqual(settled_generation, task.runtime.permission_review.generation);
    const ready_authority = authority;
    const invalid = enum { shutdown, persistence, workspace, automatic_owner, unstable, checkpoint, execution, runtime };
    for (std.enums.values(invalid)) |failure| {
        authority = ready_authority;
        const attached = task.runtime.attachment;
        switch (failure) {
            .shutdown => authority.shutting_down = true,
            .persistence => authority.task_persistence_ready = false,
            .workspace => authority.workspace_identity_exact = false,
            .automatic_owner => authority.automatic_owner_exact = false,
            .unstable => authority.authority_stable = false,
            .checkpoint => authority.checkpoint_store_ready = false,
            .execution => {
                task.runtime.attachment = .{ .detached = .cold_start };
                authority.execution_admission = .unavailable;
            },
            .runtime => {
                task.runtime.attachment = .{ .detached = .cold_start };
                authority.runtime_admission = .unavailable;
            },
        }
        try std.testing.expectError(error.ApprovalUnavailable, runtime.beginApprovalChange(1, 1, 3, .full_access, effects));
        try std.testing.expect(task.approval_change == null);
        try std.testing.expectEqual(@as(u64, 3), task.durable.approval_revision);
        try std.testing.expectEqual(settled_generation, task.runtime.permission_review.generation);
        task.runtime.attachment = attached;
    }
    authority = ready_authority;
    task.durable.archived = true;
    try std.testing.expectError(error.TaskClosing, runtime.beginApprovalChange(1, 1, 3, .auto_review, effects));
    task.durable.archived = false;
    task.deletion = .deleting;
    try std.testing.expectError(error.TaskClosing, runtime.beginApprovalChange(1, 1, 3, .auto_review, effects));
    task.deletion = .idle;
    task.runtime.active_operation = .{ .compact = 7 };
    try std.testing.expectError(error.TaskBusy, runtime.beginApprovalChange(1, 1, 3, .auto_review, effects));
    task.runtime.active_operation = .{ .restore = .{ .id = 7 } };
    try std.testing.expectError(error.TaskBusy, runtime.beginApprovalChange(1, 1, 3, .auto_review, effects));
    task.runtime.active_operation = .none;
    runtime.permission_reviews_closed = true;
    try std.testing.expectError(error.TaskBusy, runtime.beginApprovalChange(1, 1, 3, .auto_review, effects));
    runtime.permission_reviews_closed = false;
    task.durable.permission_interaction = .noninteractive;
    try std.testing.expectError(error.UnsupportedPermissionProfile, runtime.beginApprovalChange(1, 1, 3, .full_access, effects));
    try std.testing.expect(task.approval_change == null);
    try std.testing.expectEqual(settled_generation, task.runtime.permission_review.generation);
}

test "image Run incremental projection keeps a credential prefix private across chunks" {
    var text: task_state.TrackedText = .{};
    defer text.list.deinit(std.testing.allocator);
    try text.list.appendSlice(std.testing.allocator, "prefix image-");
    try std.testing.expect(!redactTrackedTextSecrets(&text, &.{ "dialogue-secret", "image-token" }));
    try std.testing.expectEqual(@as(usize, "prefix ".len), text.committed_len);
    try text.list.appendSlice(std.testing.allocator, "token suffix");
    try std.testing.expect(redactTrackedTextSecrets(&text, &.{ "dialogue-secret", "image-token" }));
    try std.testing.expectEqualStrings("prefix *** suffix", text.list.items);
    try std.testing.expectEqual(text.list.items.len, text.committed_len);
}
