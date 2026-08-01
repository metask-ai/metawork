const std = @import("std");
const lifecycle = @import("metawork_agent");
const account_contract = @import("metawork_account_contract");
const executor_impl = @import("workbench_executor");
const managed_workspace_store = @import("workbench_managed_workspace_store");
const scheduled_tasks_impl = @import("workbench_scheduled_tasks");
const scheduled_task_persistence = @import("workbench_scheduled_task_persistence");
const contract_fixture = @import("workbench_contract_fixture");
const build_options = @import("build_options");

pub const Error = lifecycle.Error || scheduled_tasks_impl.Error || scheduled_task_persistence.Error || std.mem.Allocator.Error || std.Thread.SpawnError || error{
    ProjectionCapacity,
    RunCapacity,
    ToolCapacity,
    SnapshotTooLarge,
    CloseInProgress,
    TaskBusy,
    TaskNotClosed,
    InvalidTaskTitle,
    InvalidScheduledTaskInput,
    ScheduleTimerUnavailable,
    ScheduledTaskPersistenceUnavailable,
    ScheduledTaskPersistenceFailed,
    ScheduledTaskPersistenceOutcomeUnknown,
    RunGenerationExhausted,
    ExecutorShuttingDown,
    TaskCapacity,
    TaskIdentityExhausted,
    WorkspaceCapacity,
    WorkspaceIdentityExhausted,
    WorkspaceOrderExhausted,
    UnknownTask,
    UnknownWorkspace,
    TaskClosing,
    ExecutionUnavailable,
    ExecutionInUse,
    ExecutionGenerationMismatch,
    BindingEpochMismatch,
    InvalidAutomationExecution,
    InvalidWorkspace,
    WorkspaceUnavailable,
    WorkspaceRemovalInProgress,
    WorkspaceEpochMismatch,
    WorkspaceEpochExhausted,
    CatalogLoading,
    CatalogUnavailable,
    CatalogRequestGenerationExhausted,
    StaleCatalog,
    SkillNotFound,
    InvalidSkillArguments,
    EventAfterTerminalDrain,
};

pub const Limits = struct {
    worker_count: usize = 4,
    queue_capacity: usize = 16,
    max_tasks: usize = 8,
    max_workspaces: usize = 16,
    max_scheduled_tasks: usize = 16,
    max_runs_per_task: usize = 16,
    max_tools_per_run: usize = 32,
    max_projection_bytes: usize = 512 * 1024,
    max_workspace_bytes: usize = 16 * 1024,
    max_catalog_projection_bytes: usize = 64 * 1024,
    max_scheduled_task_projection_bytes: usize = 256 * 1024,
    max_catalog_skills: usize = 128,
    max_catalog_issues: usize = 128,
    max_skill_arguments: usize = 64,
    max_task_title_bytes: usize = 512,
    max_user_message_bytes: usize = 64 * 1024,
    max_assistant_message_bytes: usize = 256 * 1024,
    max_tool_field_bytes: usize = 256 * 1024,
    max_pending_ui_json_bytes: usize = 256 * 1024,
    max_pending_ui_requests: usize = 4,
    max_ui_history_per_task: usize = 8,
    max_terminal_diagnostic_bytes: usize = 512,
    max_snapshot_bytes: usize = 16 * 1024 * 1024,
};

pub const Provider = enum {
    anthropic,
    openai,
};

pub const TaskWorkspaceTrust = union(enum) {
    explicitly_trusted,
    temporary: []const u8,
};

pub const TaskCreateInput = struct {
    workspace_root: []const u8,
    trust: TaskWorkspaceTrust,
};

pub const TaskWorkspaceRequest = union(enum) {
    existing: struct {
        workspace_id: u64,
        expected_epoch: u64,
    },
    managed,
};

pub const TaskRunInput = union(enum) {
    text: []const u8,
    skill: struct {
        skill_id: []const u8,
        catalog_revision: []const u8,
        argument_values: []const []const u8,
    },
};

pub const ScheduledTaskRecurrence = scheduled_tasks_impl.Recurrence;

pub const ScheduledTaskTarget = union(enum) {
    default,
    explicit: struct {
        workspace_id: u64,
        expected_workspace_epoch: u64,
    },
};

pub const ScheduledTaskDefinitionInput = struct {
    title: []const u8,
    target: ScheduledTaskTarget,
    expected_execution_generation: u64,
    input: TaskRunInput,
    recurrence: ScheduledTaskRecurrence,
};

pub const WorkspaceAuthorization = enum {
    available,
    removing,
    reauthorization_required,
};

pub const WorkspaceOrigin = enum {
    user,
    managed,
};

pub const WorkspaceRemovalFailure = enum {
    none,
    task_close_failed,
};

pub const WorkspaceSignals = struct {
    running: u32 = 0,
    attention: u32 = 0,
    failed_or_interrupted: u32 = 0,
};

/// Borrowed, bounded Host-owned Workspace projection.
pub const WorkspaceProjection = struct {
    id: u64,
    epoch: u64,
    origin: WorkspaceOrigin,
    canonical_root: []const u8,
    display_name: []const u8,
    authorization: WorkspaceAuthorization,
    last_removal_failure: WorkspaceRemovalFailure,
    recent_order: u64,
    signals: WorkspaceSignals,
};

pub const CatalogAvailability = enum {
    uninitialized,
    loading,
    ready,
    degraded,
    unavailable,
};

pub const SkillProjection = struct {
    skill_id: []const u8,
    invocation_name: []const u8,
    display_name: []const u8,
    description: []const u8,
    argument_names: []const []const u8,
    max_values: u32,
};

pub const CatalogIssueProjection = struct {
    code: lifecycle.CatalogIssueCode,
    invocation_name: ?[]const u8,
};

pub const CatalogProjection = struct {
    availability: CatalogAvailability,
    redacted: bool = false,
    revision: []const u8 = "",
    skills: []const SkillProjection = &.{},
    issues: []const CatalogIssueProjection = &.{},
};

pub const ExecutionIdentity = struct {
    generation: u64,
    provider: Provider,
    model: []const u8,
};

pub const AutomationExecutionInput = struct {
    provider: account_contract.ProviderKind,
    credential: []const u8,
    model: []const u8,
    base_url: []const u8,
};

pub const PermissionChoice = enum {
    allow_once,
    allow_always,
    deny_once,
    deny_tool_session,
};

pub const UiResponse = union(enum) {
    answers: []const []const []const u8,
    permission: PermissionChoice,
};

pub const AppDirectories = struct {
    canonical_user_home: ?[]const u8 = null,
    managed_workspace_root: ?*managed_workspace_store.Root = null,
};

pub const Configuration = struct {
    change_notifier: ChangeNotifier = .{},
    directories: AppDirectories = .{},
    schedule_timer: ScheduleTimer = .{},
    schedule_persistence: SchedulePersistence = .{},
    schedule_notifier: ScheduleNotifier = .{},
};

pub const SchedulePersistenceCommit = enum {
    committed,
    failed,
    outcome_unknown,
};

pub const SchedulePersistence = struct {
    context: ?*anyopaque = null,
    enabled: bool = false,
    restored_bytes: ?[]const u8 = null,
    restore_failed: bool = false,
    commit_fn: *const fn (
        context: ?*anyopaque,
        bytes: []const u8,
    ) SchedulePersistenceCommit = unsupportedCommit,

    fn commit(
        self: SchedulePersistence,
        bytes: []const u8,
    ) SchedulePersistenceCommit {
        if (!self.enabled) return .failed;
        return self.commit_fn(self.context, bytes);
    }

    fn unsupportedCommit(
        _: ?*anyopaque,
        _: []const u8,
    ) SchedulePersistenceCommit {
        return .failed;
    }
};

pub const SchedulePersistenceHealth = enum {
    unavailable,
    ready,
    read_failed,
    corrupt,
    write_failed,
    outcome_unknown,
};

pub const ScheduleNotificationKind = enum {
    completed,
    failed,
    skipped,
    needs_attention,
};

pub const ScheduleNotification = struct {
    scheduled_task_id: u64,
    task_id: u64 = 0,
    title: []const u8,
    kind: ScheduleNotificationKind,
};

pub const ScheduleNotifier = struct {
    context: ?*anyopaque = null,
    enabled: bool = false,
    notify_fn: *const fn (
        context: ?*anyopaque,
        notification: ScheduleNotification,
    ) bool = noScheduleNotification,

    fn notify(
        self: ScheduleNotifier,
        notification: ScheduleNotification,
    ) bool {
        return self.enabled and self.notify_fn(self.context, notification);
    }
};

fn noScheduleNotification(
    _: ?*anyopaque,
    _: ScheduleNotification,
) bool {
    return false;
}

const json_string_expansion: usize = 6;
const pending_ui_reencode_expansion: usize = 2;
const root_snapshot_overhead: usize = 1024;
const account_snapshot_text_bytes: usize =
    account_contract.Limits.account_id_bytes +
    account_contract.Limits.display_name_bytes +
    account_contract.Limits.api_key_id_bytes +
    account_contract.Limits.model_id_bytes +
    account_contract.Limits.safe_diagnostic_bytes +
    account_contract.Limits.api_key_entries *
        (account_contract.Limits.api_key_id_bytes +
            account_contract.Limits.api_key_name_bytes +
            account_contract.Limits.api_key_suffix_bytes) +
    account_contract.Limits.model_entries *
        (account_contract.Limits.model_id_bytes +
            account_contract.Limits.model_display_name_bytes);
const account_snapshot_overhead: usize = 1024 +
    account_contract.Limits.api_key_entries * 128 +
    account_contract.Limits.model_entries * 128;
const workspace_snapshot_overhead: usize = 512;
const task_snapshot_overhead: usize = 1024;
const scheduled_task_snapshot_overhead: usize = 1024;
const run_snapshot_overhead: usize = 1024;
const catalog_snapshot_overhead: usize = 256;
const catalog_skill_snapshot_overhead: usize = 256;
const catalog_argument_snapshot_overhead: usize = 16;
const catalog_issue_snapshot_overhead: usize = 128;
const tool_snapshot_overhead: usize = 512;
const pending_ui_snapshot_overhead: usize = 8 * 1024;
const ui_record_detail_capacity: usize = 512;
const ui_record_snapshot_overhead: usize = 512;
const tool_route_digest_bytes = std.crypto.hash.sha2.Sha256.digest_length;
const tool_product_id_capacity = "tool-".len + 20;
const binding_model_display_bytes = @max(
    account_contract.Limits.model_id_bytes,
    account_contract.Limits.model_display_name_bytes,
);

const ToolState = enum { running, completed, failed };
const RunPhase = enum {
    queued,
    running,
    waiting_ui,
    stopping,
    completed,
    stopped,
    cancelled,
    interrupted,
    failed,
};

const RunOutcome = enum {
    completed,
    stopped,
    cancelled,
    interrupted,
    failed,
    dependency_contract_failure,
};

/// Workbench-owned durable product cause.
const RunCause = enum {
    user_cancel,
    timeout,
    session_close,
    app_shutdown,
    event_pipeline_failure,
    queue_capacity_failure,
    ui_pipeline_failure,
    stale_catalog,
    skill_not_found,
    invalid_skill_arguments,
    skill_policy_violation,
    skill_unavailable,
    dependency_contract_failure,
};

const TaskLifecycle = enum { open, closing, closed };

const ContinuationUnavailableReason = enum {
    session_poisoned,
    event_projection_failure,
    closing,
    closed,
};

const ContinuationCapability = union(enum) {
    available,
    unavailable: ContinuationUnavailableReason,
};

const CloseCompletion = enum(u8) {
    none,
    running,
    closed,
    failed_reusable,
    failed_poisoned,
    failed_closing,
};

pub const ChangeNotifier = struct {
    context: ?*anyopaque = null,
    wake: *const fn (?*anyopaque) bool = noChangeNotification,

    fn notify(self: ChangeNotifier) bool {
        return self.wake(self.context);
    }
};

pub const ScheduleTimer = struct {
    context: ?*anyopaque = null,
    enabled: bool = false,
    now_unix_seconds: *const fn (?*anyopaque) ?u64 = noScheduleClock,
    arm: *const fn (?*anyopaque, u64) bool = noScheduleArm,
    cancel: *const fn (?*anyopaque) void = noScheduleCancel,

    fn now(self: ScheduleTimer) ?u64 {
        if (!self.enabled) return null;
        return self.now_unix_seconds(self.context);
    }

    fn armAt(self: ScheduleTimer, due_unix_seconds: u64) bool {
        return self.enabled and self.arm(self.context, due_unix_seconds);
    }

    fn cancelCurrent(self: ScheduleTimer) void {
        if (self.enabled) self.cancel(self.context);
    }
};

fn noScheduleClock(_: ?*anyopaque) ?u64 {
    return null;
}

fn noScheduleArm(_: ?*anyopaque, _: u64) bool {
    return false;
}

fn noScheduleCancel(_: ?*anyopaque) void {}

pub const TransportFailureStage = enum {
    ingress_validation,
    command_dispatch,
    response_delivery,
    revision_delivery,
    snapshot_transport,
    connection_generation,
};

pub const TransportFailureReport = struct {
    stage: TransportFailureStage,
    session_id: u64 = 0,
    run_id: u64 = 0,
};

pub const TransportFailureDecision = enum {
    reject_command,
    retry,
    detach_renderer,
    request_run_termination,
};

/// Workbench owns product impact policy; Bridge supplies transport facts only.
/// Current Renderer transport failures never terminate an Agent Run.
pub fn decideTransportFailure(report: TransportFailureReport) TransportFailureDecision {
    std.debug.assert((report.session_id == 0) == (report.run_id == 0));
    return switch (report.stage) {
        .ingress_validation, .command_dispatch => .reject_command,
        .revision_delivery, .snapshot_transport => .retry,
        .response_delivery, .connection_generation => .detach_renderer,
    };
}

const TrackedText = struct {
    list: std.ArrayList(u8) = .empty,
    /// Bytes before this offset are final sanitized output. Bytes at and after
    /// it are the only suffix that can still become a cross-chunk credential.
    committed_len: usize = 0,
};

const ToolView = struct {
    /// One-way correlation key for SDK tool events. The raw AgentCore tool ID
    /// is not retained in Workbench product history.
    route_digest: [tool_route_digest_bytes]u8,
    id: []u8,
    order: u64,
    name: []u8,
    input: []u8,
    progress: []u8,
    content: []u8,
    state: ToolState,
    is_error: bool = false,
    elapsed_ms: u64 = 0,
    input_truncated: bool = false,
    progress_truncated: bool = false,
    content_truncated: bool = false,
    redacted: bool = false,
};

const UsageView = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cache_read_input_tokens: u64 = 0,
    cache_creation_input_tokens: u64 = 0,
};

const TerminalPublication = enum(u8) { open, publishing, published };
const EventProjectionFailure = enum { consumer_rejected };
const AgentHandoffState = enum(u8) { queued, starting, running, finishing };
const RunTerminationDispatch = enum {
    pending,
    requested,
    already_requested,
    already_finishing,
    already_terminal,
    stale_run,
    session_closing,
};

const PendingInterruption = enum(u8) {
    none,
    user_cancel,
    timeout,
    session_close,
    app_shutdown,
};

const TerminalPayload = struct {
    phase: RunPhase,
    outcome: RunOutcome,
    cause: ?RunCause,
    session_disposition_at_completion: lifecycle.SessionDisposition,
    diagnostic_len: usize = 0,
    diagnostic_truncated: bool = false,
    diagnostic_redacted: bool = false,
};

const RunInputRecord = union(enum) {
    text: struct {
        value: []u8,
        redacted: bool = false,
    },
    skill: struct {
        skill_id: []u8,
        catalog_revision: []u8,
        invocation_name: []u8,
        display_name: []u8,
        argument_values: [][]u8,
        redacted: bool = false,
    },
};

const RunRecord = struct {
    id: u64,
    generation: u64,
    execution_generation: u64,
    execution_provider: Provider,
    execution_model: []const u8,
    input: RunInputRecord,
    assistant: TrackedText = .{},
    assistant_redacted: bool = false,
    active_phase: RunPhase = .queued,
    tools: []?ToolView,
    usage: UsageView = .{},
    status_text: []u8,
    terminal_publication: std.atomic.Value(TerminalPublication) = .init(.open),
    terminal_payload: TerminalPayload = undefined,
    terminal_observed: bool = false,
    terminal_event_drain_marked: bool = false,
    event_stream_finalized: bool = false,
    event_projection_failure: ?EventProjectionFailure = null,
    terminal_diagnostic: []u8,
    redaction_secret: []const u8 = &.{},
    next_activity_order: u64 = 1,
    workbench: *Workbench = undefined,
    task: *TaskView = undefined,
    session: *lifecycle.Session = undefined,
    worker_reference_held: std.atomic.Value(bool) = .init(false),
    agent_handoff: std.atomic.Value(AgentHandoffState) = .init(.queued),
    pending_termination: std.atomic.Value(PendingInterruption) = .init(.none),
    run_control: lifecycle.RunControl = undefined,
};

const UiRecordKind = enum { ask_question, permission };

const UiRecordState = enum {
    answered,
    allowed_once,
    allowed_always,
    denied,
    denied_session,
    cancelled,
};

const UiRecord = struct {
    request_id: u64,
    run_id: u64,
    order: u64 = 0,
    kind: UiRecordKind,
    state: UiRecordState,
    detail: [ui_record_detail_capacity]u8 = undefined,
    detail_len: usize = 0,
    item_count: u32 = 0,
    detail_truncated: bool = false,
    redacted: bool = false,

    fn detailSlice(self: *const UiRecord) []const u8 {
        return self.detail[0..self.detail_len];
    }
};

const TaskView = struct {
    session: ?*lifecycle.Session,
    execution: ?OwnedTaskExecution = null,
    id: u64,
    recent_order: u64,
    route_id: u64,
    execution_generation: u64,
    execution_provider: Provider,
    execution_model: []u8,
    binding_epoch: u64 = 1,
    binding_account_id: []u8,
    binding_profile_id: []u8,
    binding_account_name: []u8,
    binding_api_key_id: []u8,
    binding_api_key_name: []u8,
    binding_api_key_suffix: []u8,
    binding_model_id: []u8,
    binding_model_display_name: []u8,
    workspace_id: u64,
    workspace_epoch: u64 = 1,
    workspace_root: []u8,
    pinned_catalog: ?CatalogSnapshot = null,
    title: []u8,
    title_redacted: bool = false,
    archived: bool = false,
    runs: []?RunRecord,
    next_run_generation: u64 = 0,
    worker_references: std.atomic.Value(usize) = .init(0),
    delete_pending: bool = false,
    ui_history: []?UiRecord,
    ui_history_count: usize = 0,
    ui_history_next: usize = 0,
    pending_ui_request_id: u64 = 0,
    pending_ui_order: u64 = 0,
    lifecycle: TaskLifecycle = .open,
    continuation: ContinuationCapability = .available,
    active_run_id: u64 = 0,
    closing_session: ?*lifecycle.Session = null,
    close_thread: ?std.Thread = null,
    close_completion: std.atomic.Value(CloseCompletion) = .init(.none),
    close_failed: bool = false,
    cancel_requested: bool = false,
};

/// Process-local execution material owned by a Task after Workbench admission.
/// Production values have already crossed the strict Account contract before
/// they reach ActiveExecution. Automation builds may instead bind a loopback
/// fixture endpoint, so Task continuation must validate its stable identity,
/// not reinterpret this owned runtime copy as fresh Account input.
const OwnedTaskExecution = struct {
    allocator: std.mem.Allocator,
    provider_kind: account_contract.ProviderKind,
    model: []u8,
    base_url: []u8,
    execution_generation: u64,
    secret: []u8,
    owned: bool = true,

    fn clone(
        allocator: std.mem.Allocator,
        provider_kind: account_contract.ProviderKind,
        model: []const u8,
        base_url: []const u8,
        execution_generation: u64,
        api_key: []const u8,
    ) std.mem.Allocator.Error!OwnedTaskExecution {
        std.debug.assert(model.len != 0);
        std.debug.assert(base_url.len != 0);
        std.debug.assert(execution_generation != 0);
        std.debug.assert(api_key.len != 0);
        const owned_model = try allocator.dupe(u8, model);
        errdefer allocator.free(owned_model);
        const owned_base_url = try allocator.dupe(u8, base_url);
        errdefer allocator.free(owned_base_url);
        const owned_secret = try allocator.dupe(u8, api_key);
        errdefer {
            std.crypto.secureZero(u8, owned_secret);
            allocator.free(owned_secret);
        }
        return .{
            .allocator = allocator,
            .provider_kind = provider_kind,
            .model = owned_model,
            .base_url = owned_base_url,
            .execution_generation = execution_generation,
            .secret = owned_secret,
        };
    }

    fn take(self: *OwnedTaskExecution) OwnedTaskExecution {
        std.debug.assert(self.owned);
        const result = self.*;
        self.owned = false;
        self.model = &.{};
        self.base_url = &.{};
        self.secret = &.{};
        self.execution_generation = 0;
        return result;
    }

    fn input(self: *const OwnedTaskExecution) account_contract.ExecutionConfigInput {
        std.debug.assert(self.owned);
        return .{
            .target = .{
                .provider_kind = self.provider_kind,
                .model = self.model,
                .base_url = self.base_url,
            },
            .api_key = self.secret,
            .execution_generation = self.execution_generation,
        };
    }

    fn deinit(self: *OwnedTaskExecution) void {
        if (!self.owned) return;
        std.crypto.secureZero(u8, self.secret);
        self.allocator.free(self.secret);
        self.allocator.free(self.base_url);
        self.allocator.free(self.model);
        self.owned = false;
        self.model = &.{};
        self.base_url = &.{};
        self.secret = &.{};
        self.execution_generation = 0;
    }
};

const WorkspaceTrust = union(enum) {
    explicitly_trusted,
    temporary: []u8,
};

const CatalogSnapshot = struct {
    arena: std.heap.ArenaAllocator,
    revision: []const u8,
    health: lifecycle.CatalogHealth,
    skills: []const SkillProjection,
    issues: []const CatalogIssueProjection,
    projected_bytes: usize,
    redacted: bool = false,

    fn init(
        allocator: std.mem.Allocator,
        source: lifecycle.CatalogProjection,
        limits: Limits,
        available_projection_bytes: usize,
    ) Error!CatalogSnapshot {
        if (source.skills.len > limits.max_catalog_skills or
            source.issues.len > limits.max_catalog_issues)
            return error.ProjectionCapacity;
        var projected_bytes = source.revision.len;
        for (source.skills) |skill| {
            if (skill.argument_names.len > limits.max_skill_arguments)
                return error.ProjectionCapacity;
            inline for (.{
                skill.skill_id,
                skill.invocation_name,
                skill.display_name,
                skill.description,
            }) |field| {
                projected_bytes = try addCatalogProjectionBytes(
                    projected_bytes,
                    field.len,
                    limits,
                    available_projection_bytes,
                );
            }
            for (skill.argument_names) |name|
                projected_bytes = try addCatalogProjectionBytes(
                    projected_bytes,
                    name.len,
                    limits,
                    available_projection_bytes,
                );
        }
        for (source.issues) |issue| {
            if (issue.invocation_name) |name|
                projected_bytes = try addCatalogProjectionBytes(
                    projected_bytes,
                    name.len,
                    limits,
                    available_projection_bytes,
                );
        }
        if (projected_bytes > limits.max_catalog_projection_bytes or
            projected_bytes > available_projection_bytes)
            return error.ProjectionCapacity;

        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const owned = arena.allocator();
        const skills = try owned.alloc(SkillProjection, source.skills.len);
        for (source.skills, skills) |skill, *target| {
            const argument_names = try owned.alloc(
                []const u8,
                skill.argument_names.len,
            );
            for (skill.argument_names, argument_names) |name, *target_name|
                target_name.* = try owned.dupe(u8, name);
            target.* = .{
                .skill_id = try owned.dupe(u8, skill.skill_id),
                .invocation_name = try owned.dupe(u8, skill.invocation_name),
                .display_name = try owned.dupe(u8, skill.display_name),
                .description = try owned.dupe(u8, skill.description),
                .argument_names = argument_names,
                .max_values = skill.max_values,
            };
        }
        const issues = try owned.alloc(
            CatalogIssueProjection,
            source.issues.len,
        );
        for (source.issues, issues) |issue, *target| target.* = .{
            .code = issue.code,
            .invocation_name = if (issue.invocation_name) |name|
                try owned.dupe(u8, name)
            else
                null,
        };
        return .{
            .arena = arena,
            .revision = try owned.dupe(u8, source.revision),
            .health = source.health,
            .skills = skills,
            .issues = issues,
            .projected_bytes = projected_bytes,
        };
    }

    fn clone(
        self: *const CatalogSnapshot,
        allocator: std.mem.Allocator,
        limits: Limits,
        available_projection_bytes: usize,
    ) Error!CatalogSnapshot {
        if (self.projected_bytes > limits.max_catalog_projection_bytes or
            self.projected_bytes > available_projection_bytes)
            return error.ProjectionCapacity;
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const owned = arena.allocator();
        const skills = try owned.alloc(SkillProjection, self.skills.len);
        for (self.skills, skills) |skill, *target| {
            const argument_names = try owned.alloc(
                []const u8,
                skill.argument_names.len,
            );
            for (skill.argument_names, argument_names) |name, *target_name|
                target_name.* = try owned.dupe(u8, name);
            target.* = .{
                .skill_id = try owned.dupe(u8, skill.skill_id),
                .invocation_name = try owned.dupe(u8, skill.invocation_name),
                .display_name = try owned.dupe(u8, skill.display_name),
                .description = try owned.dupe(u8, skill.description),
                .argument_names = argument_names,
                .max_values = skill.max_values,
            };
        }
        const issues = try owned.alloc(CatalogIssueProjection, self.issues.len);
        for (self.issues, issues) |issue, *target| target.* = .{
            .code = issue.code,
            .invocation_name = if (issue.invocation_name) |name|
                try owned.dupe(u8, name)
            else
                null,
        };
        return .{
            .arena = arena,
            .revision = try owned.dupe(u8, self.revision),
            .health = self.health,
            .skills = skills,
            .issues = issues,
            .projected_bytes = self.projected_bytes,
            .redacted = self.redacted,
        };
    }

    fn view(self: *const CatalogSnapshot) CatalogProjection {
        return .{
            .availability = switch (self.health) {
                .healthy => .ready,
                .degraded => .degraded,
            },
            .redacted = self.redacted,
            .revision = self.revision,
            .skills = self.skills,
            .issues = self.issues,
        };
    }

    fn findSkill(
        self: *const CatalogSnapshot,
        skill_id: []const u8,
    ) ?*const SkillProjection {
        for (self.skills) |*skill|
            if (std.mem.eql(u8, skill.skill_id, skill_id)) return skill;
        return null;
    }

    fn identityContainsCredential(
        self: *const CatalogSnapshot,
        credential: []const u8,
    ) bool {
        if (credential.len == 0) return false;
        if (std.mem.indexOf(u8, self.revision, credential) != null) return true;
        for (self.skills) |skill|
            if (std.mem.indexOf(u8, skill.skill_id, credential) != null or
                std.mem.indexOf(u8, skill.invocation_name, credential) != null)
                return true;
        return false;
    }

    fn redactPresentationNoFail(
        self: *CatalogSnapshot,
        credential: []const u8,
    ) void {
        var redacted = false;
        for (self.skills) |*skill| {
            redacted = redactFixedWidthNoFail(
                @constCast(skill.display_name),
                credential,
            ) or redacted;
            redacted = redactFixedWidthNoFail(
                @constCast(skill.description),
                credential,
            ) or redacted;
            for (skill.argument_names) |name| {
                redacted = redactFixedWidthNoFail(
                    @constCast(name),
                    credential,
                ) or redacted;
            }
        }
        for (self.issues) |*issue| {
            if (issue.invocation_name) |name| {
                redacted = redactFixedWidthNoFail(
                    @constCast(name),
                    credential,
                ) or redacted;
            }
        }
        self.redacted = self.redacted or redacted;
    }

    fn deinit(self: *CatalogSnapshot) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

const CatalogJobState = enum(u8) {
    queued,
    running,
    completed,
    cancelled,
};

const CatalogJobOutcome = union(enum) {
    success: lifecycle.CatalogAcquisition,
    failure,
};

const CatalogJobTarget = union(enum) {
    skills: u64,
    workspace: struct {
        id: u64,
        epoch: u64,
        request_generation: u64,
    },
};

const CatalogJob = struct {
    allocator: std.mem.Allocator,
    runtime: *lifecycle.Runtime,
    notifier: ChangeNotifier,
    target: CatalogJobTarget,
    canonical_root: []u8,
    canonical_user_home: []u8,
    epoch_token: []u8,
    state: std.atomic.Value(CatalogJobState) = .init(.queued),
    outcome: CatalogJobOutcome = .failure,

    fn deinit(self: *CatalogJob) void {
        self.allocator.free(self.epoch_token);
        self.allocator.free(self.canonical_user_home);
        self.allocator.free(self.canonical_root);
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }
};

const WorkspaceView = struct {
    id: u64,
    origin: WorkspaceOrigin = .user,
    managed_task_id: u64 = 0,
    epoch: u64 = 1,
    canonical_root: []u8,
    projected_root_storage: []u8,
    projected_root_len: usize,
    display_name_storage: []u8,
    display_name_len: usize,
    projection_redacted: bool = false,
    trust: WorkspaceTrust,
    authorization: WorkspaceAuthorization = .available,
    last_removal_failure: WorkspaceRemovalFailure = .none,
    visible: bool = true,
    recent_order: u64,
    catalog_availability: CatalogAvailability = .uninitialized,
    catalog_request_generation: u64 = 0,
    catalog_job: ?*CatalogJob = null,
    catalog_reschedule_pending: bool = false,
    catalog_lease: ?*lifecycle.CatalogLease = null,
    catalog: ?CatalogSnapshot = null,
};

fn FixedText(comptime capacity: usize) type {
    return struct {
        bytes: [capacity]u8 = undefined,
        len: usize = 0,

        const Self = @This();

        fn setNoFail(self: *Self, value: []const u8) void {
            std.debug.assert(value.len <= capacity);
            std.debug.assert(std.unicode.utf8ValidateSlice(value));
            @memcpy(self.bytes[0..value.len], value);
            self.len = value.len;
        }

        fn clear(self: *Self) void {
            self.len = 0;
        }

        fn view(self: *const Self) []const u8 {
            return self.bytes[0..self.len];
        }
    };
}

const ApiKeyProjection = struct {
    id: FixedText(account_contract.Limits.api_key_id_bytes) = .{},
    name: FixedText(account_contract.Limits.api_key_name_bytes) = .{},
    suffix: FixedText(account_contract.Limits.api_key_suffix_bytes) = .{},
    provider_kind: account_contract.ProviderKind = .anthropic,
};

const ModelProjection = struct {
    id: FixedText(account_contract.Limits.model_id_bytes) = .{},
    display_name: FixedText(account_contract.Limits.model_display_name_bytes) = .{},
};

const AccountProjection = struct {
    allocator: std.mem.Allocator,
    session_state: account_contract.AccountSessionState = .restoring,
    execution_state: account_contract.ExecutionState = .none,
    operation: account_contract.OperationKind = .none,
    readiness: account_contract.AccountReadiness = .checking,
    primary_action: account_contract.AccountPrimaryAction = .none,
    can_cancel: bool = false,
    account_id: FixedText(account_contract.Limits.account_id_bytes) = .{},
    profile_id: FixedText(account_contract.Limits.profile_id_bytes) = .{},
    display_name: FixedText(account_contract.Limits.display_name_bytes) = .{},
    selected_api_key_id: FixedText(account_contract.Limits.api_key_id_bytes) = .{},
    selected_model: FixedText(account_contract.Limits.model_id_bytes) = .{},
    candidate_api_key_id: FixedText(account_contract.Limits.api_key_id_bytes) = .{},
    candidate_model: FixedText(account_contract.Limits.model_id_bytes) = .{},
    model_catalog_api_key_id: FixedText(account_contract.Limits.api_key_id_bytes) = .{},
    safe_diagnostic: FixedText(account_contract.Limits.safe_diagnostic_bytes) = .{},
    api_keys: []ApiKeyProjection,
    api_key_views: []account_contract.ApiKeyView,
    api_key_count: usize = 0,
    models: []ModelProjection,
    model_views: []account_contract.ModelView,
    model_count: usize = 0,
    account_can_create_task: bool = false,
    error_code: account_contract.ErrorCode = .none,
    catalog_generation: u64 = 0,
    execution_generation: u64 = 0,

    fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!AccountProjection {
        const api_keys = try allocator.alloc(
            ApiKeyProjection,
            account_contract.Limits.api_key_entries,
        );
        errdefer allocator.free(api_keys);
        @memset(api_keys, .{});
        const api_key_views = try allocator.alloc(
            account_contract.ApiKeyView,
            account_contract.Limits.api_key_entries,
        );
        errdefer allocator.free(api_key_views);
        const models = try allocator.alloc(
            ModelProjection,
            account_contract.Limits.model_entries,
        );
        errdefer allocator.free(models);
        @memset(models, .{});
        const model_views = try allocator.alloc(
            account_contract.ModelView,
            account_contract.Limits.model_entries,
        );
        errdefer allocator.free(model_views);
        return .{
            .allocator = allocator,
            .api_keys = api_keys,
            .api_key_views = api_key_views,
            .models = models,
            .model_views = model_views,
        };
    }

    fn deinit(self: *AccountProjection) void {
        self.allocator.free(self.model_views);
        self.allocator.free(self.models);
        self.allocator.free(self.api_key_views);
        self.allocator.free(self.api_keys);
        self.* = undefined;
    }

    fn commitNoFail(
        self: *AccountProjection,
        source_view: account_contract.AccountView,
    ) void {
        account_contract.validateView(source_view) catch
            @panic("Account published an invalid AccountView");
        std.debug.assert(source_view.api_keys.len <= self.api_keys.len);
        std.debug.assert(source_view.models.len <= self.models.len);
        self.session_state = source_view.session_state;
        self.execution_state = source_view.execution_state;
        self.operation = source_view.operation;
        self.readiness = source_view.readiness;
        self.primary_action = source_view.primary_action;
        self.can_cancel = source_view.can_cancel;
        self.account_id.setNoFail(source_view.account_id);
        self.profile_id.setNoFail(source_view.profile_id);
        self.display_name.setNoFail(source_view.display_name);
        self.selected_api_key_id.setNoFail(source_view.selected_api_key_id);
        self.selected_model.setNoFail(source_view.selected_model);
        self.candidate_api_key_id.setNoFail(source_view.candidate_api_key_id);
        self.candidate_model.setNoFail(source_view.candidate_model);
        self.model_catalog_api_key_id.setNoFail(
            source_view.model_catalog_api_key_id,
        );
        self.safe_diagnostic.setNoFail(source_view.safe_diagnostic);
        self.api_key_count = source_view.api_keys.len;
        for (
            source_view.api_keys,
            self.api_keys[0..source_view.api_keys.len],
            self.api_key_views[0..source_view.api_keys.len],
        ) |source, *target, *target_view| {
            target.id.setNoFail(source.id);
            target.name.setNoFail(source.name);
            target.suffix.setNoFail(source.suffix);
            target.provider_kind = source.provider_kind;
            target_view.* = .{
                .id = target.id.view(),
                .name = target.name.view(),
                .suffix = target.suffix.view(),
                .provider_kind = target.provider_kind,
            };
        }
        self.model_count = source_view.models.len;
        for (
            source_view.models,
            self.models[0..source_view.models.len],
            self.model_views[0..source_view.models.len],
        ) |source, *target, *target_view| {
            target.id.setNoFail(source.id);
            target.display_name.setNoFail(source.display_name);
            target_view.* = .{
                .id = target.id.view(),
                .display_name = target.display_name.view(),
            };
        }
        self.account_can_create_task = source_view.can_create_task;
        self.error_code = source_view.error_code;
        self.catalog_generation = source_view.catalog_generation;
        self.execution_generation = source_view.execution_generation;
    }

    fn view(
        self: *const AccountProjection,
        can_create_task: bool,
    ) account_contract.AccountView {
        return .{
            .session_state = self.session_state,
            .execution_state = self.execution_state,
            .operation = self.operation,
            .readiness = self.readiness,
            .primary_action = self.primary_action,
            .can_cancel = self.can_cancel,
            .account_id = self.account_id.view(),
            .profile_id = self.profile_id.view(),
            .display_name = self.display_name.view(),
            .api_keys = self.api_key_views[0..self.api_key_count],
            .models = self.model_views[0..self.model_count],
            .selected_api_key_id = self.selected_api_key_id.view(),
            .selected_model = self.selected_model.view(),
            .candidate_api_key_id = self.candidate_api_key_id.view(),
            .candidate_model = self.candidate_model.view(),
            .model_catalog_api_key_id = self.model_catalog_api_key_id.view(),
            .can_create_task = can_create_task,
            .error_code = self.error_code,
            .safe_diagnostic = self.safe_diagnostic.view(),
            .catalog_generation = self.catalog_generation,
            .execution_generation = self.execution_generation,
        };
    }

    fn selectedApiKey(self: *const AccountProjection) ?account_contract.ApiKeyView {
        for (self.api_key_views[0..self.api_key_count]) |candidate|
            if (std.mem.eql(u8, candidate.id, self.selected_api_key_id.view()))
                return candidate;
        return null;
    }

    fn selectedModel(self: *const AccountProjection) ?account_contract.ModelView {
        for (self.model_views[0..self.model_count]) |candidate|
            if (std.mem.eql(u8, candidate.id, self.selected_model.view()))
                return candidate;
        return null;
    }
};

const ActiveExecution = struct {
    allocator: std.mem.Allocator,
    credential_storage: []u8,
    model_storage: []u8,
    base_url_storage: []u8,
    credential_len: usize = 0,
    model_len: usize = 0,
    base_url_len: usize = 0,
    provider: ?Provider = null,
    generation: u64 = 0,

    fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!ActiveExecution {
        const credential_storage = try allocator.alloc(
            u8,
            account_contract.Limits.api_key_bytes,
        );
        errdefer allocator.free(credential_storage);
        const model_storage = try allocator.alloc(
            u8,
            account_contract.Limits.model_id_bytes,
        );
        errdefer allocator.free(model_storage);
        const base_url_storage = try allocator.alloc(
            u8,
            account_contract.Limits.base_url_bytes,
        );
        errdefer allocator.free(base_url_storage);
        return .{
            .allocator = allocator,
            .credential_storage = credential_storage,
            .model_storage = model_storage,
            .base_url_storage = base_url_storage,
        };
    }

    fn deinit(self: *ActiveExecution) void {
        std.crypto.secureZero(u8, self.credential_storage);
        self.allocator.free(self.base_url_storage);
        self.allocator.free(self.model_storage);
        self.allocator.free(self.credential_storage);
        self.* = undefined;
    }

    fn installNoFail(
        self: *ActiveExecution,
        execution: *account_contract.OwnedExecutionConfig,
    ) void {
        const input = execution.input();
        account_contract.validateExecutionConfig(input) catch
            @panic("Account published an invalid ExecutionConfig");
        std.debug.assert(input.api_key.len <= self.credential_storage.len);
        std.debug.assert(input.target.model.len <= self.model_storage.len);
        std.debug.assert(input.target.base_url.len <= self.base_url_storage.len);
        self.installBytesNoFail(
            accountProvider(input.target.provider_kind),
            input.api_key,
            input.target.model,
            input.target.base_url,
            input.execution_generation,
        );
        execution.deinit();
    }

    fn installAutomationNoFail(
        self: *ActiveExecution,
        input: AutomationExecutionInput,
    ) void {
        std.debug.assert(build_options.automation);
        self.installBytesNoFail(
            accountProvider(input.provider),
            input.credential,
            input.model,
            input.base_url,
            1,
        );
    }

    fn installBytesNoFail(
        self: *ActiveExecution,
        provider: Provider,
        credential_bytes: []const u8,
        model_bytes: []const u8,
        base_url_bytes: []const u8,
        generation: u64,
    ) void {
        std.debug.assert(
            credential_bytes.len <= self.credential_storage.len,
        );
        std.debug.assert(model_bytes.len <= self.model_storage.len);
        std.debug.assert(
            base_url_bytes.len <= self.base_url_storage.len,
        );
        std.crypto.secureZero(u8, self.credential_storage);
        @memcpy(
            self.credential_storage[0..credential_bytes.len],
            credential_bytes,
        );
        @memcpy(
            self.model_storage[0..model_bytes.len],
            model_bytes,
        );
        @memcpy(
            self.base_url_storage[0..base_url_bytes.len],
            base_url_bytes,
        );
        self.credential_len = credential_bytes.len;
        self.model_len = model_bytes.len;
        self.base_url_len = base_url_bytes.len;
        self.provider = provider;
        self.generation = generation;
    }

    fn clearNoFail(self: *ActiveExecution) void {
        std.crypto.secureZero(u8, self.credential_storage);
        self.credential_len = 0;
        self.model_len = 0;
        self.base_url_len = 0;
        self.provider = null;
        self.generation = 0;
    }

    fn credential(self: *const ActiveExecution) []const u8 {
        return self.credential_storage[0..self.credential_len];
    }

    fn model(self: *const ActiveExecution) []const u8 {
        return self.model_storage[0..self.model_len];
    }

    fn baseUrl(self: *const ActiveExecution) []const u8 {
        return self.base_url_storage[0..self.base_url_len];
    }

    fn ready(self: *const ActiveExecution) bool {
        return self.generation != 0 and self.provider != null and
            self.credential_len != 0 and self.model_len != 0;
    }

    fn cloneOwned(
        self: *const ActiveExecution,
        allocator: std.mem.Allocator,
    ) std.mem.Allocator.Error!OwnedTaskExecution {
        std.debug.assert(self.ready());
        return OwnedTaskExecution.clone(
            allocator,
            accountProviderKind(self.provider.?),
            self.model(),
            self.baseUrl(),
            self.generation,
            self.credential(),
        );
    }
};

/// Workbench-owned product projection. AgentCore protocol is interpreted only
/// through the bundle SDK; the Renderer receives this bounded domain view.
/// All methods currently run on the Native loop thread.
pub const Workbench = struct {
    allocator: std.mem.Allocator,
    agent_runtime: *lifecycle.Runtime,
    limits: Limits,
    workspaces: []?WorkspaceView,
    tasks: []?TaskView,
    scheduled_tasks: scheduled_tasks_impl.Store,
    schedule_timer: ScheduleTimer,
    schedule_persistence: SchedulePersistence,
    schedule_persistence_health: SchedulePersistenceHealth,
    schedule_notifier: ScheduleNotifier,
    schedule_background_available: bool = false,
    change_notifier: ChangeNotifier,
    executor: *executor_impl.Executor,
    shutting_down: bool = false,
    executor_shutdown: bool = false,
    projection_bytes: usize = 0,
    revision: u64 = 0,
    account: AccountProjection,
    execution: ActiveExecution,
    canonical_user_home: ?[]u8,
    managed_workspaces: ?managed_workspace_store.Store,
    skill_catalog_availability: CatalogAvailability = .uninitialized,
    skill_catalog_request_generation: u64 = 0,
    skill_catalog_job: ?*CatalogJob = null,
    skill_catalog_lease: ?*lifecycle.CatalogLease = null,
    skill_catalog: ?CatalogSnapshot = null,
    execution_replacement_pending: bool = false,
    selected_workspace_id: u64 = 0,
    next_workspace_id: u64 = 1,
    next_workspace_recent_order: u64 = 1,
    next_task_id: u64 = 1,
    next_task_recent_order: u64 = 1,

    pub fn init(
        allocator: std.mem.Allocator,
        agent_runtime: *lifecycle.Runtime,
        limits: Limits,
        configuration: Configuration,
    ) Error!Workbench {
        if (limits.worker_count == 0 or limits.queue_capacity == 0 or
            limits.max_tasks == 0 or limits.max_workspaces == 0 or
            limits.max_scheduled_tasks == 0 or
            limits.max_runs_per_task == 0 or
            limits.max_tools_per_run == 0 or limits.max_projection_bytes == 0 or
            limits.max_workspace_bytes == 0 or
            limits.max_catalog_projection_bytes == 0 or
            limits.max_scheduled_task_projection_bytes == 0 or
            limits.max_catalog_skills == 0 or
            limits.max_catalog_issues == 0 or
            limits.max_skill_arguments == 0 or
            limits.max_task_title_bytes == 0 or
            limits.max_user_message_bytes == 0 or limits.max_assistant_message_bytes == 0 or
            limits.max_tool_field_bytes == 0 or limits.max_pending_ui_json_bytes == 0 or
            limits.max_pending_ui_requests == 0 or
            limits.max_ui_history_per_task == 0 or
            limits.max_terminal_diagnostic_bytes == 0 or
            limits.max_snapshot_bytes == 0 or
            (worstCaseSnapshotBytes(limits) orelse return error.ProjectionCapacity) > limits.max_snapshot_bytes)
            return error.ProjectionCapacity;
        var account = try AccountProjection.init(allocator);
        errdefer account.deinit();
        var execution = try ActiveExecution.init(allocator);
        errdefer execution.deinit();
        const canonical_user_home = if (configuration.directories.canonical_user_home) |home| home_copy: {
            if (home.len == 0 or !std.fs.path.isAbsolute(home) or
                !std.unicode.utf8ValidateSlice(home))
                return error.InvalidWorkspace;
            const resolved = std.Io.Dir.realPathFileAbsoluteAlloc(
                agent_runtime.io,
                home,
                allocator,
            ) catch return error.InvalidWorkspace;
            defer allocator.free(resolved);
            if (!std.mem.eql(u8, resolved, home)) return error.InvalidWorkspace;
            break :home_copy try allocator.dupe(u8, home);
        } else null;
        errdefer if (canonical_user_home) |home| allocator.free(home);
        var managed_workspaces = if (configuration.directories.managed_workspace_root) |root|
            managed_workspace_store.Store.init(root)
        else
            null;
        errdefer if (managed_workspaces) |*store| store.deinit();
        const workspace_capacity = workspaceRecordCapacity(limits) orelse
            return error.ProjectionCapacity;
        const workspaces = try allocator.alloc(?WorkspaceView, workspace_capacity);
        errdefer allocator.free(workspaces);
        @memset(workspaces, null);
        const tasks = try allocator.alloc(?TaskView, limits.max_tasks);
        errdefer allocator.free(tasks);
        @memset(tasks, null);
        const scheduled_limits: scheduled_tasks_impl.Limits = .{
            .max_items = limits.max_scheduled_tasks,
            .max_projection_bytes = limits.max_scheduled_task_projection_bytes,
        };
        var schedule_persistence_health: SchedulePersistenceHealth =
            if (configuration.schedule_persistence.enabled)
                .ready
            else
                .unavailable;
        if (configuration.schedule_persistence.restore_failed)
            schedule_persistence_health = .read_failed;
        var scheduled_tasks = if (schedule_persistence_health == .ready and
            configuration.schedule_persistence.restored_bytes != null)
            scheduled_task_persistence.decode(
                allocator,
                configuration.schedule_persistence.restored_bytes.?,
                scheduled_limits,
            ) catch restore: {
                schedule_persistence_health = .corrupt;
                break :restore try scheduled_tasks_impl.Store.init(
                    allocator,
                    scheduled_limits,
                );
            }
        else
            try scheduled_tasks_impl.Store.init(allocator, scheduled_limits);
        errdefer scheduled_tasks.deinit();
        const executor = executor_impl.Executor.create(agent_runtime.io, allocator, .{
            .worker_count = limits.worker_count,
            .queue_capacity = limits.queue_capacity,
        }) catch |err| switch (err) {
            error.InvalidLimits => unreachable,
            else => return err,
        };
        var workbench: Workbench = .{
            .allocator = allocator,
            .agent_runtime = agent_runtime,
            .limits = limits,
            .workspaces = workspaces,
            .tasks = tasks,
            .scheduled_tasks = scheduled_tasks,
            .schedule_timer = configuration.schedule_timer,
            .schedule_persistence = configuration.schedule_persistence,
            .schedule_persistence_health = schedule_persistence_health,
            .schedule_notifier = configuration.schedule_notifier,
            .change_notifier = configuration.change_notifier,
            .executor = executor,
            .account = account,
            .execution = execution,
            .canonical_user_home = canonical_user_home,
            .managed_workspaces = managed_workspaces,
        };
        if (workbench.schedule_persistence_health == .ready) {
            var recovered = workbench.scheduled_tasks.clone(allocator) catch null;
            if (recovered) |*candidate| {
                var candidate_owned = true;
                defer if (candidate_owned) candidate.deinit();
                if (candidate.interruptClaimedOccurrences()) {
                    workbench.commitScheduledTaskCandidate(candidate) catch {};
                    if (workbench.schedule_persistence_health == .ready) {
                        workbench.replaceScheduledTaskStore(candidate);
                        candidate_owned = false;
                    }
                }
            }
        }
        workbench.scheduleSkillCatalogQuery() catch
            workbench.markSkillCatalogUnavailable();
        return workbench;
    }

    pub fn setScheduleBackgroundAvailableNoFail(
        self: *Workbench,
        available: bool,
    ) void {
        if (self.schedule_background_available == available) return;
        self.schedule_background_available = available;
        if (available)
            self.rearmScheduledTaskTimerNoFail()
        else
            self.schedule_timer.cancelCurrent();
        self.bumpRevision();
    }

    pub fn managedWorkspacesAvailable(self: *const Workbench) bool {
        return self.managed_workspaces != null;
    }

    pub fn hasEnabledScheduledTasks(self: *Workbench) bool {
        for (self.scheduled_tasks.items) |*entry| {
            const item = &(entry.* orelse continue);
            if (item.enabled) return true;
        }
        return false;
    }

    pub fn commitAccountFactNoFail(
        self: *Workbench,
        fact: account_contract.AccountFact,
    ) void {
        self.account.commitNoFail(fact.view);
    }

    pub fn installExecutionNoFail(
        self: *Workbench,
        execution: *account_contract.OwnedExecutionConfig,
    ) void {
        std.debug.assert(self.execution_replacement_pending);
        const input = execution.input();
        std.debug.assert(self.account.execution_state == .ready);
        std.debug.assert(
            self.account.execution_generation == input.execution_generation,
        );
        std.debug.assert(std.mem.eql(
            u8,
            self.account.selected_model.view(),
            input.target.model,
        ));
        self.redactAllProductProjectionsNoFail(self.execution.credential());
        self.redactAllProductProjectionsNoFail(input.api_key);
        self.execution.installNoFail(execution);
    }

    pub fn clearExecutionNoFail(self: *Workbench) void {
        std.debug.assert(self.execution_replacement_pending);
        std.debug.assert(self.account.execution_state != .ready);
        self.redactAllProductProjectionsNoFail(self.execution.credential());
        self.execution.clearNoFail();
    }

    pub fn finishAccountCommitNoFail(self: *Workbench) void {
        if (self.canCreateTask()) {
            _ = self.reconcileScheduledTaskBindingsNoFail();
            self.rearmScheduledTaskTimerNoFail();
        } else {
            self.schedule_timer.cancelCurrent();
        }
        self.bumpRevision();
    }

    pub fn accountView(self: *const Workbench) account_contract.AccountView {
        return self.account.view(self.canCreateTask());
    }

    /// The AgentCore vertical fixture keeps its local provider outside the production Account
    /// contract. This path is compiled only into `-Dautomation=true` builds;
    /// release builds reject it before observing any input.
    pub fn installAutomationExecution(
        self: *Workbench,
        input: AutomationExecutionInput,
    ) Error!void {
        if (!build_options.automation)
            return error.InvalidAutomationExecution;
        if (input.credential.len == 0 or
            input.credential.len > account_contract.Limits.api_key_bytes or
            input.model.len == 0 or
            input.model.len > account_contract.Limits.model_id_bytes or
            input.base_url.len == 0 or
            input.base_url.len > account_contract.Limits.base_url_bytes or
            !std.unicode.utf8ValidateSlice(input.model) or
            !std.unicode.utf8ValidateSlice(input.base_url) or
            std.mem.indexOfAny(u8, input.base_url, "\r\n") != null)
            return error.InvalidAutomationExecution;
        try self.beginExecutionReplacement();
        errdefer self.endExecutionReplacementNoFail();
        const api_keys = [_]account_contract.ApiKeyView{.{
            .id = "automation-key",
            .name = "Automation",
            .suffix = "",
            .provider_kind = input.provider,
        }};
        const models = [_]account_contract.ModelView{.{
            .id = input.model,
            .display_name = input.model,
        }};
        self.commitAccountFactNoFail(.{
            .kind = .execution_changed,
            .view = .{
                .session_state = .authenticated,
                .execution_state = .ready,
                .operation = .none,
                .readiness = .ready,
                .primary_action = .none,
                .account_id = "automation-account",
                .profile_id = "automation-profile",
                .display_name = "Automation",
                .api_keys = &api_keys,
                .models = &models,
                .selected_api_key_id = "automation-key",
                .selected_model = input.model,
                .model_catalog_api_key_id = "automation-key",
                .can_create_task = true,
                .execution_generation = 1,
            },
        });
        self.redactAllProductProjectionsNoFail(self.execution.credential());
        self.redactAllProductProjectionsNoFail(input.credential);
        self.execution.installAutomationNoFail(input);
        self.endExecutionReplacementNoFail();
        self.finishAccountCommitNoFail();
    }

    pub fn beginExecutionReplacement(self: *Workbench) Error!void {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        self.syncLifecycle();
        self.releaseQuiescentTaskExecutions();
        if (self.execution_replacement_pending)
            return error.ExecutionInUse;
        self.execution_replacement_pending = true;
        if (!self.executionQuiescent()) {
            self.execution_replacement_pending = false;
            return error.ExecutionInUse;
        }
    }

    pub fn beginDefaultExecutionReplacement(self: *Workbench) Error!void {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        self.syncLifecycle();
        if (self.execution_replacement_pending)
            return error.ExecutionInUse;
        self.execution_replacement_pending = true;
    }

    pub fn endExecutionReplacementNoFail(self: *Workbench) void {
        std.debug.assert(self.execution_replacement_pending);
        self.execution_replacement_pending = false;
    }

    pub fn executionReplacementPending(self: *const Workbench) bool {
        return self.execution_replacement_pending;
    }

    /// Validates and selects a Host-owned Workspace independently of Task
    /// creation. A successful selection is therefore visible even when the
    /// user has not sent the New task draft yet.
    pub fn openWorkspace(
        self: *Workbench,
        input: TaskCreateInput,
    ) Error!u64 {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        self.syncLifecycle();
        const recent_order = try self.takeWorkspaceRecentOrder();
        const workspace = try self.upsertWorkspace(input);
        self.selected_workspace_id = workspace.id;
        workspace.recent_order = recent_order;
        if (workspace.catalog_availability == .uninitialized) {
            if (workspace.catalog_job != null) {
                workspace.catalog_reschedule_pending = true;
                workspace.catalog_availability = .loading;
            } else {
                self.scheduleCatalogQuery(workspace) catch
                    self.markWorkspaceCatalogUnavailable(workspace);
            }
        }
        self.bumpRevision();
        return workspace.id;
    }

    pub fn workspaceCatalog(
        self: *Workbench,
        workspace_id: u64,
    ) Error!CatalogProjection {
        self.syncLifecycle();
        const workspace = self.findWorkspace(workspace_id) orelse
            return error.UnknownWorkspace;
        return catalogProjection(
            workspace.catalog_availability,
            if (workspace.catalog) |*snapshot| snapshot else null,
        );
    }

    pub fn skillCatalog(self: *Workbench) CatalogProjection {
        self.syncLifecycle();
        return catalogProjection(
            self.skill_catalog_availability,
            if (self.skill_catalog) |*snapshot| snapshot else null,
        );
    }

    pub fn refreshSkillCatalog(self: *Workbench) Error!void {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        self.syncLifecycle();
        if (self.skill_catalog_job != null) return error.CatalogLoading;
        try self.scheduleSkillCatalogQuery();
        self.bumpRevision();
    }

    pub fn taskCatalog(
        self: *Workbench,
        task_id: u64,
    ) Error!CatalogProjection {
        self.syncLifecycle();
        const task = self.findTask(task_id) orelse return error.UnknownTask;
        return taskCatalogProjection(task);
    }

    pub fn refreshWorkspaceCatalog(
        self: *Workbench,
        workspace_id: u64,
        expected_workspace_epoch: u64,
    ) Error!void {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        self.syncLifecycle();
        const workspace = self.findWorkspace(workspace_id) orelse
            return error.UnknownWorkspace;
        if (workspace.origin != .user) return error.WorkspaceUnavailable;
        if (workspace.epoch != expected_workspace_epoch)
            return error.WorkspaceEpochMismatch;
        if (!workspace.visible or workspace.authorization != .available)
            return error.WorkspaceUnavailable;
        if (workspace.catalog_job != null) return error.CatalogLoading;
        try self.scheduleCatalogQuery(workspace);
        self.bumpRevision();
    }

    pub fn refreshTaskCatalog(
        self: *Workbench,
        task_id: u64,
        expected_binding_epoch: u64,
    ) Error!void {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        self.syncLifecycle();
        const task = self.findTask(task_id) orelse return error.UnknownTask;
        if (task.binding_epoch != expected_binding_epoch)
            return error.BindingEpochMismatch;
        if (!self.taskContinuationAvailable(task) or hasNonTerminalRun(task))
            return error.TaskBusy;
        const workspace = self.findWorkspace(task.workspace_id) orelse
            return error.WorkspaceUnavailable;
        if (workspace.origin != .user) return error.CatalogUnavailable;
        if (workspace.epoch != task.workspace_epoch)
            return error.WorkspaceEpochMismatch;
        const current = workspace.catalog orelse
            return switch (workspace.catalog_availability) {
                .loading => error.CatalogLoading,
                else => error.CatalogUnavailable,
            };
        if (workspace.catalog_availability != .ready and
            workspace.catalog_availability != .degraded)
            return error.CatalogUnavailable;
        const lease = workspace.catalog_lease orelse
            return error.CatalogUnavailable;
        var replacement = try current.clone(
            self.allocator,
            self.limits,
            self.limits.max_projection_bytes - self.projection_bytes,
        );
        errdefer replacement.deinit();
        const session = task.session orelse return error.TaskClosing;
        try session.refreshSkillCatalog(lease);
        if (task.pinned_catalog) |*old| {
            self.projection_bytes -= old.projected_bytes;
            old.deinit();
        }
        self.projection_bytes += replacement.projected_bytes;
        task.pinned_catalog = replacement;
        self.bumpRevision();
    }

    pub fn selectWorkspace(self: *Workbench, workspace_id: u64) Error!void {
        const workspace = self.findWorkspace(workspace_id) orelse
            return error.UnknownWorkspace;
        return self.selectWorkspaceAtEpoch(workspace_id, workspace.epoch);
    }

    pub fn selectWorkspaceAtEpoch(
        self: *Workbench,
        workspace_id: u64,
        expected_workspace_epoch: u64,
    ) Error!void {
        self.syncLifecycle();
        const workspace = self.findWorkspace(workspace_id) orelse
            return error.UnknownWorkspace;
        if (workspace.origin != .user or !workspace.visible)
            return error.UnknownWorkspace;
        if (expected_workspace_epoch == 0 or workspace.epoch != expected_workspace_epoch)
            return error.WorkspaceEpochMismatch;
        if (workspace.authorization == .removing)
            return error.WorkspaceRemovalInProgress;
        const recent_order = try self.takeWorkspaceRecentOrder();
        self.selected_workspace_id = workspace.id;
        workspace.recent_order = recent_order;
        self.bumpRevision();
    }

    pub fn selectedWorkspaceId(self: *const Workbench) u64 {
        return self.selected_workspace_id;
    }

    pub fn workspaceEpoch(self: *Workbench, workspace_id: u64) Error!u64 {
        self.syncLifecycle();
        const workspace = self.findWorkspace(workspace_id) orelse
            return error.UnknownWorkspace;
        return workspace.epoch;
    }

    pub fn workspaceOrigin(
        self: *Workbench,
        workspace_id: u64,
    ) Error!WorkspaceOrigin {
        self.syncLifecycle();
        const workspace = self.findWorkspace(workspace_id) orelse
            return error.UnknownWorkspace;
        return workspace.origin;
    }

    pub fn taskWorkspaceId(self: *Workbench, task_id: u64) Error!u64 {
        self.syncLifecycle();
        const task = self.findTask(task_id) orelse return error.UnknownTask;
        return task.workspace_id;
    }

    /// Copies the canonical Workspace projection without allocating. Hidden
    /// user Workspaces remain omitted; managed Workspaces stay projected so
    /// their Task routes remain addressable. Aggregate signals are computed
    /// from canonical Task state.
    pub fn copyWorkspaceProjections(
        self: *Workbench,
        output: []WorkspaceProjection,
    ) Error![]const WorkspaceProjection {
        self.syncLifecycle();
        var count: usize = 0;
        for (self.workspaces) |*entry| {
            const workspace = &(entry.* orelse continue);
            if (workspace.origin == .user and !workspace.visible) continue;
            if (count == output.len) return error.WorkspaceCapacity;
            output[count] = .{
                .id = workspace.id,
                .epoch = workspace.epoch,
                .origin = workspace.origin,
                .canonical_root = workspace.projected_root_storage[0..workspace.projected_root_len],
                .display_name = workspace.display_name_storage[0..workspace.display_name_len],
                .authorization = workspace.authorization,
                .last_removal_failure = workspace.last_removal_failure,
                .recent_order = workspace.recent_order,
                .signals = self.workspaceSignals(workspace.id),
            };
            count += 1;
        }
        std.mem.sort(
            WorkspaceProjection,
            output[0..count],
            {},
            struct {
                fn lessThan(_: void, left: WorkspaceProjection, right: WorkspaceProjection) bool {
                    return left.recent_order > right.recent_order;
                }
            }.lessThan,
        );
        return output[0..count];
    }

    /// Removes a Workspace from navigation, makes future Run admission fail
    /// closed, and starts closing every live Task Session in that Workspace.
    /// Task history and files remain owned by their original systems.
    pub fn removeWorkspace(
        self: *Workbench,
        workspace_id: u64,
    ) Error!void {
        const workspace = self.findWorkspace(workspace_id) orelse
            return error.UnknownWorkspace;
        return self.removeWorkspaceAtEpoch(workspace_id, workspace.epoch);
    }

    pub fn removeWorkspaceAtEpoch(
        self: *Workbench,
        workspace_id: u64,
        expected_workspace_epoch: u64,
    ) Error!void {
        self.syncLifecycle();
        const workspace = self.findWorkspace(workspace_id) orelse
            return error.UnknownWorkspace;
        if (workspace.origin != .user or !workspace.visible)
            return error.UnknownWorkspace;
        if (expected_workspace_epoch == 0 or workspace.epoch != expected_workspace_epoch)
            return error.WorkspaceEpochMismatch;
        if (workspace.authorization == .removing)
            return error.WorkspaceRemovalInProgress;
        if (workspace.epoch == std.math.maxInt(u64))
            return error.WorkspaceEpochExhausted;
        self.markWorkspaceCatalogUnavailable(workspace);
        workspace.epoch += 1;
        workspace.authorization = .removing;
        workspace.last_removal_failure = .none;
        self.bumpRevision();
        for (self.tasks) |*entry| {
            const task = &(entry.* orelse continue);
            if (task.workspace_id != workspace_id or task.session == null) continue;
            self.closeTask(task.id) catch |err| switch (err) {
                error.CloseInProgress => {},
                else => {
                    workspace.authorization = .available;
                    workspace.last_removal_failure = .task_close_failed;
                    self.bumpRevision();
                    return err;
                },
            };
        }
        if (self.finalizeWorkspaceRemovalsNoFail()) self.bumpRevision();
    }

    pub fn createTask(
        self: *Workbench,
        input: TaskCreateInput,
    ) Error!u64 {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        self.syncLifecycle();
        if (self.execution_replacement_pending)
            return error.ExecutionInUse;
        if (!self.canCreateTask())
            return error.ExecutionUnavailable;
        if (findEmpty(TaskView, self.tasks) == null) return error.TaskCapacity;
        const workspace_id = try self.openWorkspace(input);
        return self.createTaskInWorkspace(
            workspace_id,
            (self.findWorkspace(workspace_id) orelse return error.UnknownWorkspace).epoch,
            self.execution.generation,
            null,
        );
    }

    pub fn createTaskInWorkspace(
        self: *Workbench,
        workspace_id: u64,
        expected_workspace_epoch: u64,
        expected_execution_generation: u64,
        expected_skill_catalog_revision: ?[]const u8,
    ) Error!u64 {
        return self.createTaskInWorkspaceInternal(
            workspace_id,
            expected_workspace_epoch,
            expected_execution_generation,
            expected_skill_catalog_revision,
            false,
        );
    }

    pub fn createTaskForWorkspace(
        self: *Workbench,
        request: TaskWorkspaceRequest,
        expected_execution_generation: u64,
        expected_skill_catalog_revision: ?[]const u8,
    ) Error!u64 {
        return switch (request) {
            .existing => |existing| self.createTaskInWorkspace(
                existing.workspace_id,
                existing.expected_epoch,
                expected_execution_generation,
                expected_skill_catalog_revision,
            ),
            .managed => self.createManagedTask(
                expected_execution_generation,
                expected_skill_catalog_revision,
            ),
        };
    }

    fn createTaskInWorkspaceInternal(
        self: *Workbench,
        workspace_id: u64,
        expected_workspace_epoch: u64,
        expected_execution_generation: u64,
        expected_skill_catalog_revision: ?[]const u8,
        allow_unowned_managed: bool,
    ) Error!u64 {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        self.syncLifecycle();
        if (self.execution_replacement_pending)
            return error.ExecutionInUse;
        if (!self.canCreateTask())
            return error.ExecutionUnavailable;
        if (expected_execution_generation == 0 or
            expected_execution_generation != self.execution.generation or
            expected_execution_generation != self.account.execution_generation)
            return error.ExecutionGenerationMismatch;
        const workspace_view = self.findWorkspace(workspace_id) orelse
            return error.UnknownWorkspace;
        if (expected_workspace_epoch == 0 or
            expected_workspace_epoch != workspace_view.epoch)
            return error.WorkspaceEpochMismatch;
        if (workspace_view.origin == .managed and
            (!allow_unowned_managed or workspace_view.managed_task_id != 0))
            return error.WorkspaceUnavailable;
        if (workspace_view.origin == .user and !workspace_view.visible)
            return error.WorkspaceUnavailable;
        if (workspace_view.authorization == .removing)
            return error.WorkspaceRemovalInProgress;
        if (workspace_view.authorization != .available)
            return error.WorkspaceUnavailable;
        var pinned_catalog: ?CatalogSnapshot = null;
        errdefer if (pinned_catalog) |*snapshot| {
            self.projection_bytes -= snapshot.projected_bytes;
            snapshot.deinit();
        };
        var catalog_lease: ?*lifecycle.CatalogLease = null;
        switch (workspace_view.catalog_availability) {
            .ready, .degraded => {
                const current = workspace_view.catalog orelse
                    return error.CatalogUnavailable;
                if (expected_skill_catalog_revision) |expected|
                    if (!std.mem.eql(u8, expected, current.revision))
                        return error.StaleCatalog;
                pinned_catalog = try current.clone(
                    self.allocator,
                    self.limits,
                    self.limits.max_projection_bytes - self.projection_bytes,
                );
                self.projection_bytes += pinned_catalog.?.projected_bytes;
                catalog_lease = workspace_view.catalog_lease orelse
                    return error.CatalogUnavailable;
            },
            .loading => if (expected_skill_catalog_revision != null)
                return error.CatalogLoading,
            .uninitialized, .unavailable => if (expected_skill_catalog_revision != null)
                return error.CatalogUnavailable,
        }
        var task_execution = try self.execution.cloneOwned(self.allocator);
        errdefer task_execution.deinit();
        const task_execution_input = task_execution.input();
        const slot = findEmpty(TaskView, self.tasks) orelse return error.TaskCapacity;
        const canonical = workspace_view.canonical_root;
        const workspace_trust: lifecycle.WorkspaceTrust = switch (workspace_view.trust) {
            .explicitly_trusted => .explicitly_trusted,
            .temporary => |root| .{ .temporary = root },
        };
        const workspace_projection = try self.copyProjected(
            canonical,
            self.limits.max_workspace_bytes,
            task_execution_input.api_key,
        );
        std.debug.assert(!workspace_projection.truncated);
        const workspace = workspace_projection.value;
        errdefer self.freeTracked(workspace);
        const title = try self.copyBounded("", self.limits.max_task_title_bytes);
        errdefer self.freeTracked(title);
        const execution_model = try self.copyBounded(
            task_execution_input.target.model,
            account_contract.Limits.model_id_bytes,
        );
        errdefer self.freeTracked(execution_model);
        const binding_account_id = try self.copyBounded(
            self.account.account_id.view(),
            account_contract.Limits.account_id_bytes,
        );
        errdefer self.freeTracked(binding_account_id);
        const binding_profile_id = try self.copyBounded(
            self.account.profile_id.view(),
            account_contract.Limits.profile_id_bytes,
        );
        errdefer self.freeTracked(binding_profile_id);
        const binding_account_name = try self.copyBounded(
            self.account.display_name.view(),
            account_contract.Limits.display_name_bytes,
        );
        errdefer self.freeTracked(binding_account_name);
        const binding_api_key_id = try self.copyBounded(
            self.account.selected_api_key_id.view(),
            account_contract.Limits.api_key_id_bytes,
        );
        errdefer self.freeTracked(binding_api_key_id);
        const selected_api_key = self.account.selectedApiKey();
        const binding_api_key_name = try self.copyBounded(
            if (selected_api_key) |key| key.name else "",
            account_contract.Limits.api_key_name_bytes,
        );
        errdefer self.freeTracked(binding_api_key_name);
        const binding_api_key_suffix = try self.copyBounded(
            if (selected_api_key) |key| key.suffix else "",
            account_contract.Limits.api_key_suffix_bytes,
        );
        errdefer self.freeTracked(binding_api_key_suffix);
        const selected_model = self.account.selectedModel();
        const binding_model_id = try self.copyBounded(
            task_execution_input.target.model,
            account_contract.Limits.model_id_bytes,
        );
        errdefer self.freeTracked(binding_model_id);
        const binding_model_display_name = try self.copyBounded(
            if (selected_model) |model| model.display_name else task_execution_input.target.model,
            binding_model_display_bytes,
        );
        errdefer self.freeTracked(binding_model_display_name);
        const runs = try self.allocator.alloc(?RunRecord, self.limits.max_runs_per_task);
        errdefer self.allocator.free(runs);
        @memset(runs, null);
        const ui_history = try self.allocator.alloc(?UiRecord, self.limits.max_ui_history_per_task);
        errdefer self.allocator.free(ui_history);
        @memset(ui_history, null);
        if (self.next_task_id == 0) return error.TaskIdentityExhausted;
        const task_id = self.next_task_id;
        var epoch_storage: [32]u8 = undefined;
        const epoch_token = std.fmt.bufPrint(
            &epoch_storage,
            "{d}",
            .{workspace_view.epoch},
        ) catch unreachable;
        const route = self.agent_runtime.createSessionRoute(.{
            .provider = agentProvider(accountProvider(task_execution_input.target.provider_kind)),
            .permission_mode = .default,
            .shell_policy = .unrestricted,
            .credential = task_execution_input.api_key,
            .model = task_execution_input.target.model,
            .base_url = task_execution_input.target.base_url,
            .workspace = .{
                .canonical_root = canonical,
                .trust = workspace_trust,
            },
            .canonical_user_home = self.canonical_user_home orelse "",
            .workspace_epoch = if (self.canonical_user_home != null)
                epoch_token
            else
                "",
            .skill_catalog = catalog_lease,
        }) catch |err| switch (err) {
            error.SessionCapacity => return error.TaskCapacity,
            else => return err,
        };
        self.next_task_id +%= 1;
        self.tasks[slot] = .{
            .session = route.session,
            .execution = task_execution.take(),
            .id = task_id,
            .recent_order = self.takeTaskRecentOrder(),
            .route_id = route.id,
            .execution_generation = task_execution_input.execution_generation,
            .execution_provider = accountProvider(task_execution_input.target.provider_kind),
            .execution_model = execution_model,
            .binding_account_id = binding_account_id,
            .binding_profile_id = binding_profile_id,
            .binding_account_name = binding_account_name,
            .binding_api_key_id = binding_api_key_id,
            .binding_api_key_name = binding_api_key_name,
            .binding_api_key_suffix = binding_api_key_suffix,
            .binding_model_id = binding_model_id,
            .binding_model_display_name = binding_model_display_name,
            .workspace_id = workspace_id,
            .workspace_epoch = workspace_view.epoch,
            .workspace_root = workspace,
            .pinned_catalog = pinned_catalog,
            .title = title,
            .runs = runs,
            .ui_history = ui_history,
        };
        self.bumpRevision();
        return task_id;
    }

    fn createManagedTask(
        self: *Workbench,
        expected_execution_generation: u64,
        expected_skill_catalog_revision: ?[]const u8,
    ) Error!u64 {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        self.syncLifecycle();
        if (self.execution_replacement_pending)
            return error.ExecutionInUse;
        if (!self.canCreateTask())
            return error.ExecutionUnavailable;
        if (expected_execution_generation == 0 or
            expected_execution_generation != self.execution.generation or
            expected_execution_generation != self.account.execution_generation)
            return error.ExecutionGenerationMismatch;
        if (expected_skill_catalog_revision != null)
            return error.CatalogUnavailable;
        if (findEmpty(TaskView, self.tasks) == null) return error.TaskCapacity;
        if (self.workspaceCount(.managed) >= self.limits.max_tasks)
            return error.WorkspaceCapacity;
        const store = if (self.managed_workspaces) |*value| value else return error.WorkspaceUnavailable;
        var allocation = store.allocate() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidManagedRoot => return error.InvalidWorkspace,
            error.RootUnavailable, error.AllocationUnavailable => return error.WorkspaceUnavailable,
        };
        errdefer _ = store.rollback(&allocation);
        const workspace = try self.registerManagedWorkspace(allocation.path());
        errdefer self.releaseManagedWorkspaceNoFail(workspace.id);
        const task_id = try self.createTaskInWorkspaceInternal(
            workspace.id,
            workspace.epoch,
            expected_execution_generation,
            null,
            true,
        );
        workspace.managed_task_id = task_id;
        allocation.deinit();
        return task_id;
    }

    pub fn runTask(
        self: *Workbench,
        task_id: u64,
        input: TaskRunInput,
    ) Error!u64 {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        self.syncLifecycle();
        const task = self.findTask(task_id) orelse return error.UnknownTask;
        return self.runTaskAtBinding(task_id, task.binding_epoch, input);
    }

    pub fn taskBindingEpoch(self: *Workbench, task_id: u64) Error!u64 {
        self.syncLifecycle();
        return (self.findTask(task_id) orelse return error.UnknownTask).binding_epoch;
    }

    pub fn runTaskAtBinding(
        self: *Workbench,
        task_id: u64,
        expected_binding_epoch: u64,
        input: TaskRunInput,
    ) Error!u64 {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        self.syncLifecycle();
        const view = self.findTask(task_id) orelse return error.UnknownTask;
        if (expected_binding_epoch == 0 or expected_binding_epoch != view.binding_epoch)
            return error.BindingEpochMismatch;
        if (!self.taskContinuationAvailable(view)) return error.TaskClosing;
        const workspace = self.findWorkspace(view.workspace_id) orelse
            return error.WorkspaceUnavailable;
        if (workspace.origin == .user and !workspace.visible)
            return error.WorkspaceUnavailable;
        if (workspace.authorization == .removing)
            return error.WorkspaceRemovalInProgress;
        if (workspace.authorization != .available)
            return error.WorkspaceUnavailable;
        if (workspace.epoch != view.workspace_epoch)
            return error.WorkspaceEpochMismatch;
        if (workspace.origin == .managed and switch (input) {
            .text => false,
            .skill => true,
        })
            return error.CatalogUnavailable;
        _ = try taskExecutionInput(view);
        if (hasNonTerminalRun(view)) return error.TaskBusy;
        const session = view.session orelse return error.TaskClosing;
        const agent_input: lifecycle.RunInput = switch (input) {
            .text => |text| .{ .text = text },
            .skill => |skill_input| skill_admission: {
                const pinned = view.pinned_catalog orelse
                    return error.CatalogUnavailable;
                if (!std.mem.eql(
                    u8,
                    skill_input.catalog_revision,
                    pinned.revision,
                ))
                    return error.StaleCatalog;
                const skill = pinned.findSkill(skill_input.skill_id) orelse
                    return error.SkillNotFound;
                if (skill_input.argument_values.len >
                    @min(
                        @as(usize, @intCast(skill.max_values)),
                        self.limits.max_skill_arguments,
                    ))
                    return error.InvalidSkillArguments;
                var argument_bytes = std.math.add(
                    usize,
                    skill.skill_id.len,
                    pinned.revision.len,
                ) catch return error.ProjectionCapacity;
                if (argument_bytes > self.limits.max_user_message_bytes)
                    return error.ProjectionCapacity;
                for (skill_input.argument_values) |value| {
                    if (!std.unicode.utf8ValidateSlice(value))
                        return error.InvalidSkillArguments;
                    argument_bytes = std.math.add(
                        usize,
                        argument_bytes,
                        value.len,
                    ) catch return error.ProjectionCapacity;
                    if (argument_bytes > self.limits.max_user_message_bytes)
                        return error.ProjectionCapacity;
                }
                break :skill_admission .{ .skill = .{
                    .skill_id = skill.skill_id,
                    .catalog_revision = pinned.revision,
                    .argument_values = skill_input.argument_values,
                } };
            },
        };
        const recent_order = try self.takeWorkspaceRecentOrder();
        const run_id = try session.prepareRun(agent_input);
        errdefer cancelPreparedRunOrPanic(session, run_id);
        const slot = try self.reserveRunRecord(view, input);
        errdefer self.discardRunRecord(view, slot);
        const run = &view.runs[slot].?;
        run.id = run_id;
        run.workbench = self;
        run.task = view;
        run.session = session;
        _ = view.worker_references.fetchAdd(1, .acq_rel);
        run.worker_reference_held.store(true, .release);
        self.executor.enqueue(.{
            .context = run,
            .execute_fn = executeRunJob,
            .cancel_fn = cancelRunJobForShutdown,
        }) catch |err| {
            releaseWorkerReference(run);
            return err;
        };
        view.active_run_id = run_id;
        view.cancel_requested = false;
        self.touchTask(view);
        workspace.recent_order = recent_order;
        self.bumpRevision();
        return run_id;
    }

    pub fn taskExecutionIdentity(
        self: *Workbench,
        task_id: u64,
    ) Error!ExecutionIdentity {
        const task = self.findTask(task_id) orelse return error.UnknownTask;
        return .{
            .generation = task.execution_generation,
            .provider = task.execution_provider,
            .model = task.execution_model,
        };
    }

    pub fn runExecutionIdentity(
        self: *Workbench,
        task_id: u64,
        run_id: u64,
    ) Error!ExecutionIdentity {
        const task = self.findTask(task_id) orelse return error.UnknownTask;
        const run = findRun(task.runs, run_id) orelse
            return error.NoSuchRun;
        return .{
            .generation = run.execution_generation,
            .provider = run.execution_provider,
            .model = run.execution_model,
        };
    }

    pub fn cancel(self: *Workbench, task_id: u64, run_id: u64) Error!void {
        self.syncLifecycle();
        const view = self.findTask(task_id) orelse return error.UnknownTask;
        const run = findRun(view.runs, run_id) orelse return error.NoSuchRun;
        if (terminalPayload(run) != null) return;
        const session = view.session orelse
            return error.TaskClosing;
        const record = self.prepareCancelledUiRecord(
            session,
            run_id,
            run.redaction_secret,
        );
        if (self.executor.cancel(run)) {
            cancelPreparedRunOrPanic(session, run_id);
            releaseWorkerReference(run);
            _ = commitTerminal(
                run,
                .cancelled,
                .cancelled,
                .user_cancel,
                .reusable,
                "",
                false,
            );
            run.terminal_observed = true;
            if (record) |value| self.pushUiRecord(view, value);
            view.cancel_requested = false;
            self.touchTask(view);
            self.bumpRevision();
            return;
        }
        const dispatch = requestRunTermination(run, .user_cancel);
        const stopping = switch (dispatch) {
            .pending, .requested, .already_requested => true,
            .already_finishing, .already_terminal, .stale_run, .session_closing => false,
        };
        if (!stopping) {
            self.syncLifecycle();
            return;
        }
        if (record) |value| self.pushUiRecord(view, value);
        view.cancel_requested = true;
        _ = setActivePhase(run, .stopping);
        self.touchTask(view);
        self.bumpRevision();
    }

    pub fn respondUi(
        self: *Workbench,
        task_id: u64,
        run_id: u64,
        request_id: u64,
        response: UiResponse,
    ) Error!void {
        self.syncLifecycle();
        const view = self.findTask(task_id) orelse return error.UnknownTask;
        const run = findRun(view.runs, run_id) orelse return error.NoSuchRun;
        const session = view.session orelse
            return error.TaskClosing;
        const answer_count = switch (response) {
            .answers => |answers| answers.len,
            .permission => 0,
        };
        const answer_buffer = try self.allocator.alloc(lifecycle.Answer, answer_count);
        defer self.allocator.free(answer_buffer);
        const agent_response = agentUiResponse(response, answer_buffer);
        const record = self.prepareUiRecord(
            session,
            run_id,
            request_id,
            agent_response,
            run.redaction_secret,
        );
        try session.respondUi(run_id, request_id, agent_response);
        self.pushUiRecord(view, record);
        self.touchTask(view);
        self.bumpRevision();
    }

    pub fn closeTask(self: *Workbench, task_id: u64) Error!void {
        self.syncLifecycle();
        const view = self.findTask(task_id) orelse return error.UnknownTask;
        if (view.close_completion.load(.acquire) == .running) return error.CloseInProgress;
        const session = view.session orelse return;
        const prior_lifecycle = view.lifecycle;
        const prior_continuation = view.continuation;
        const cancelled_ui = self.prepareCancelledUiRecord(
            session,
            view.active_run_id,
            if (findRun(view.runs, view.active_run_id)) |run|
                run.redaction_secret
            else if (view.execution) |*execution|
                execution.input().api_key
            else
                &.{},
        );
        if (findRun(view.runs, view.active_run_id)) |run| {
            if (self.executor.cancel(run)) {
                cancelPreparedRunOrPanic(session, view.active_run_id);
                releaseWorkerReference(run);
                _ = commitTerminal(
                    run,
                    .interrupted,
                    .interrupted,
                    .session_close,
                    .closing,
                    "",
                    false,
                );
                run.terminal_observed = true;
            } else consumeLifecycleTermination(
                requestRunTermination(run, .session_close),
                run.id,
            );
        }
        view.session = null;
        view.closing_session = session;
        view.lifecycle = .closing;
        view.continuation = .{ .unavailable = .closing };
        view.cancel_requested = view.active_run_id != 0;
        if (findRun(view.runs, view.active_run_id)) |run| {
            if (!isTerminalPhase(runPhase(run))) _ = setActivePhase(run, .stopping);
        }
        view.close_failed = false;
        view.close_completion.store(.running, .release);
        view.close_thread = std.Thread.spawn(.{}, closeWorker, .{
            self.agent_runtime,
            view,
            session,
            self.change_notifier,
        }) catch |err| {
            view.close_completion.store(.none, .release);
            view.closing_session = null;
            view.session = session;
            view.lifecycle = prior_lifecycle;
            view.continuation = prior_continuation;
            return err;
        };
        if (cancelled_ui) |record|
            self.pushUiRecord(view, record);
        self.touchTask(view);
        self.bumpRevision();
    }

    pub fn renameTask(self: *Workbench, task_id: u64, title: []const u8) Error!void {
        self.syncLifecycle();
        const view = self.findTask(task_id) orelse return error.UnknownTask;
        const trimmed = std.mem.trim(u8, title, " \t\r\n");
        if (trimmed.len == 0 or trimmed.len > self.limits.max_task_title_bytes or
            !std.unicode.utf8ValidateSlice(trimmed))
            return error.InvalidTaskTitle;
        for (trimmed) |byte| if (byte < 0x20) return error.InvalidTaskTitle;
        const projected = try self.replaceTrackedProjected(
            &view.title,
            trimmed,
            self.limits.max_task_title_bytes,
            if (view.execution) |*execution| execution.input().api_key else &.{},
        );
        view.title_redacted = projected.redacted;
        self.touchTask(view);
        self.bumpRevision();
    }

    pub fn createScheduledTask(
        self: *Workbench,
        input: ScheduledTaskDefinitionInput,
    ) Error!u64 {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        self.syncLifecycle();
        const now = self.schedule_timer.now() orelse
            return error.ScheduleTimerUnavailable;
        const definition = try self.scheduledTaskDefinition(input);
        var candidate = try self.scheduled_tasks.clone(self.allocator);
        var candidate_owned = true;
        defer if (candidate_owned) candidate.deinit();
        const id = try candidate.create(definition, now);
        self.redactScheduledTaskNoFail(
            candidate.find(id).?,
            self.execution.credential(),
        );
        try self.commitScheduledTaskCandidate(&candidate);
        self.replaceScheduledTaskStore(&candidate);
        candidate_owned = false;
        self.bumpRevision();
        self.rearmScheduledTaskTimerNoFail();
        return id;
    }

    pub fn updateScheduledTask(
        self: *Workbench,
        id: u64,
        expected_epoch: u64,
        input: ScheduledTaskDefinitionInput,
    ) Error!void {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        self.syncLifecycle();
        const now = self.schedule_timer.now() orelse
            return error.ScheduleTimerUnavailable;
        const definition = try self.scheduledTaskDefinition(input);
        var candidate = try self.scheduled_tasks.clone(self.allocator);
        var candidate_owned = true;
        defer if (candidate_owned) candidate.deinit();
        try candidate.update(id, expected_epoch, definition, now);
        self.redactScheduledTaskNoFail(
            candidate.find(id).?,
            self.execution.credential(),
        );
        try self.commitScheduledTaskCandidate(&candidate);
        self.replaceScheduledTaskStore(&candidate);
        candidate_owned = false;
        self.bumpRevision();
        self.rearmScheduledTaskTimerNoFail();
    }

    pub fn setScheduledTaskEnabled(
        self: *Workbench,
        id: u64,
        expected_epoch: u64,
        enabled: bool,
    ) Error!void {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        self.syncLifecycle();
        const now = self.schedule_timer.now() orelse
            return error.ScheduleTimerUnavailable;
        const current = self.scheduled_tasks.find(id) orelse
            return error.UnknownScheduledTask;
        if (expected_epoch == 0 or current.epoch != expected_epoch)
            return error.ScheduledTaskEpochMismatch;
        if (enabled and current.health == .needs_attention)
            return error.ScheduledTaskNeedsAttention;
        var candidate = try self.scheduled_tasks.clone(self.allocator);
        var candidate_owned = true;
        defer if (candidate_owned) candidate.deinit();
        try candidate.setEnabled(id, expected_epoch, enabled, now);
        _ = self.reconcileScheduledTaskBindingsInStore(&candidate);
        try self.commitScheduledTaskCandidate(&candidate);
        self.replaceScheduledTaskStore(&candidate);
        candidate_owned = false;
        self.bumpRevision();
        self.rearmScheduledTaskTimerNoFail();
    }

    pub fn deleteScheduledTask(
        self: *Workbench,
        id: u64,
        expected_epoch: u64,
    ) Error!void {
        self.syncLifecycle();
        var candidate = try self.scheduled_tasks.clone(self.allocator);
        var candidate_owned = true;
        defer if (candidate_owned) candidate.deinit();
        try candidate.delete(id, expected_epoch);
        try self.commitScheduledTaskCandidate(&candidate);
        self.replaceScheduledTaskStore(&candidate);
        candidate_owned = false;
        self.bumpRevision();
        self.rearmScheduledTaskTimerNoFail();
    }

    pub fn scheduledTaskEpoch(
        self: *Workbench,
        id: u64,
    ) Error!u64 {
        self.syncLifecycle();
        return (self.scheduled_tasks.find(id) orelse
            return error.UnknownScheduledTask).epoch;
    }

    pub fn runScheduledTaskNow(
        self: *Workbench,
        id: u64,
        expected_epoch: u64,
    ) Error!u64 {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        self.syncLifecycle();
        const now = self.schedule_timer.now() orelse
            return error.ScheduleTimerUnavailable;
        const item = self.scheduled_tasks.find(id) orelse
            return error.UnknownScheduledTask;
        if (expected_epoch == 0 or item.epoch != expected_epoch)
            return error.ScheduledTaskEpochMismatch;
        return self.triggerScheduledTask(id, now, now, .manual);
    }

    pub fn onScheduledTaskTimer(self: *Workbench) void {
        if (self.shutting_down) return;
        self.syncLifecycle();
        const now = self.schedule_timer.now() orelse return;
        const item = self.scheduled_tasks.earliestDue() orelse return;
        const id = item.id;
        const planned = item.next_run_at_unix_seconds orelse return;
        if (planned > now) {
            self.rearmScheduledTaskTimerNoFail();
            return;
        }
        _ = self.triggerScheduledTask(id, planned, now, .timer) catch {};
        self.rearmScheduledTaskTimerNoFail();
    }

    pub fn setTaskArchived(self: *Workbench, task_id: u64, archived: bool) Error!void {
        self.syncLifecycle();
        const view = self.findTask(task_id) orelse return error.UnknownTask;
        if (view.lifecycle == .closing or hasNonTerminalRun(view)) return error.TaskBusy;
        if (view.archived == archived) return;
        view.archived = archived;
        self.touchTask(view);
        self.bumpRevision();
    }

    pub fn deleteTask(self: *Workbench, task_id: u64) Error!void {
        self.syncLifecycle();
        const index = self.findTaskIndex(task_id) orelse return error.UnknownTask;
        const view = &(self.tasks[index] orelse unreachable);
        if (view.lifecycle != .closed or view.close_thread != null or view.session != null)
            return error.TaskNotClosed;
        // A closed Task must not release Run storage while the composition
        // root still owes that Run its final event-pump drain. This is
        // normally implied by close publication in `syncLifecycle`; keep the
        // explicit guard here because deletion is the destructive boundary.
        if (hasUnfinalizedTerminalEvents(view)) return error.TaskBusy;
        if (view.worker_references.load(.acquire) != 0) {
            if (!view.delete_pending) {
                view.delete_pending = true;
                self.bumpRevision();
            }
            return;
        }
        const workspace_id = view.workspace_id;
        const release_managed_workspace = if (self.findWorkspace(workspace_id)) |workspace|
            workspace.origin == .managed
        else
            false;
        self.deinitTaskView(view);
        self.tasks[index] = null;
        if (release_managed_workspace)
            self.releaseManagedWorkspaceNoFail(workspace_id);
        self.bumpRevision();
    }

    pub fn currentRevision(self: *Workbench) u64 {
        self.syncLifecycle();
        return self.revision;
    }

    /// Reconciles worker-owned lifecycle state into the main-thread product
    /// projection. It never allocates, so an effects wake cannot fail merely
    /// while publishing a terminal state.
    pub fn syncLifecycle(self: *Workbench) void {
        var changed = self.commitCatalogJobsNoFail();
        for (self.tasks) |*entry| {
            const view = &(entry.* orelse continue);
            if (view.delete_pending and view.lifecycle == .closed and view.close_thread == null and
                view.session == null and !hasUnfinalizedTerminalEvents(view) and
                view.worker_references.load(.acquire) == 0)
            {
                const workspace_id = view.workspace_id;
                const release_managed_workspace = if (self.findWorkspace(workspace_id)) |workspace|
                    workspace.origin == .managed
                else
                    false;
                self.deinitTaskView(view);
                entry.* = null;
                if (release_managed_workspace)
                    self.releaseManagedWorkspaceNoFail(workspace_id);
                changed = true;
                continue;
            }
            const close_completion = view.close_completion.load(.acquire);
            // Session close may finish after Agent execution but before the
            // main thread has drained callbacks already enqueued for the Run.
            // Keep the Task in `closing` until those events and the immutable
            // terminal result become product-visible together.
            if (close_completion != .none and close_completion != .running and
                !hasUnfinalizedTerminalEvents(view))
            {
                view.close_thread.?.join();
                view.close_thread = null;
                const closing_session = view.closing_session;
                view.closing_session = null;
                view.close_completion.store(.none, .release);
                switch (close_completion) {
                    .closed => {
                        view.lifecycle = .closed;
                        view.continuation = .{ .unavailable = .closed };
                        view.session = null;
                        view.close_failed = false;
                    },
                    .failed_reusable, .failed_poisoned, .failed_closing => {
                        view.session = closing_session;
                        view.close_failed = true;
                        switch (close_completion) {
                            .failed_reusable => {
                                view.lifecycle = .open;
                                view.continuation = .available;
                            },
                            .failed_poisoned => {
                                view.lifecycle = .open;
                                view.continuation = .{ .unavailable = .session_poisoned };
                            },
                            .failed_closing => {
                                view.lifecycle = .closing;
                                view.continuation = .{ .unavailable = .closing };
                            },
                            else => unreachable,
                        }
                    },
                    .none, .running => unreachable,
                }
                view.cancel_requested = false;
                changed = true;
            }
            const session = view.session;
            const pending = if (session) |value| value.pendingUiObservation() else null;
            const pending_request_id = if (pending) |value| value.request_id else 0;
            if (view.pending_ui_request_id != pending_request_id) {
                view.pending_ui_request_id = pending_request_id;
                view.pending_ui_order = 0;
                if (pending) |observation| {
                    if (findRun(view.runs, observation.run_id)) |pending_run|
                        view.pending_ui_order = takeActivityOrder(pending_run);
                }
                changed = true;
            }
            const run = findRun(view.runs, view.active_run_id) orelse continue;
            if (productTerminalFacts(run)) |terminal| {
                view.cancel_requested = false;
                if (!run.terminal_observed) {
                    foldTerminalDisposition(view, terminal.session_disposition_at_completion);
                    if (run.event_projection_failure != null and view.lifecycle == .open)
                        view.continuation = .{ .unavailable = .event_projection_failure };
                    run.terminal_observed = true;
                    changed = true;
                }
                continue;
            }
            const next_phase: RunPhase = if (view.cancel_requested)
                .stopping
            else if (pending != null)
                .waiting_ui
            else switch (run.agent_handoff.load(.acquire)) {
                .queued, .starting => .queued,
                .running, .finishing => .running,
            };
            if (runPhase(run) != next_phase and setActivePhase(run, next_phase))
                changed = true;
        }
        if (self.finalizeWorkspaceRemovalsNoFail()) changed = true;
        if (self.reconcileScheduledTaskBindingsNoFail()) changed = true;
        if (self.reconcileScheduledTaskCompletionsNoFail()) changed = true;
        if (changed) self.bumpRevision();
    }

    pub fn applyEvent(self: *Workbench, envelope: *const lifecycle.OwnedCoreEvent) Error!void {
        const task = self.findTaskByRouteId(envelope.session_id) orelse return error.UnknownTask;
        const run = findRun(task.runs, envelope.run_id) orelse return error.NoSuchRun;
        if (run.event_stream_finalized) {
            if (task.lifecycle == .open) {
                const task_id = task.id;
                try self.closeTask(task_id);
                const current = self.findTask(task_id) orelse
                    return error.EventAfterTerminalDrain;
                if (current.lifecycle == .open and continuationAvailable(current.continuation)) {
                    current.continuation = .{ .unavailable = .session_poisoned };
                    self.bumpRevision();
                }
            }
            return error.EventAfterTerminalDrain;
        }
        const event = switch (envelope.event.value) {
            .unknown => return,
            .known => |known| known,
        };
        switch (event) {
            .text_chunk => |text| {
                try self.appendTrackedText(&run.assistant, text, self.limits.max_assistant_message_bytes);
                if (self.redactTrackedText(&run.assistant, run.redaction_secret))
                    run.assistant_redacted = true;
            },
            .tool_start => |tool| {
                const view = try self.findOrCreateTool(run, tool.id, tool.name, tool.input);
                view.state = .running;
                _ = try self.replaceTrackedProjected(&run.status_text, tool.name, self.limits.max_tool_field_bytes, run.redaction_secret);
            },
            .tool_progress => |progress| {
                const tool = findTool(run.tools, progress.id) orelse return error.ToolCapacity;
                const projected = try self.replaceTrackedProjected(&tool.progress, progress.text, self.limits.max_tool_field_bytes, run.redaction_secret);
                tool.progress_truncated = projected.truncated;
                tool.redacted = tool.redacted or projected.redacted;
            },
            .progress => |progress| _ = try self.replaceTrackedProjected(&run.status_text, progress.tool_name, self.limits.max_tool_field_bytes, run.redaction_secret),
            .tool_result => |result| {
                const tool = try self.findOrCreateTool(run, result.id, result.name, result.input);
                const input = try self.replaceTrackedProjected(&tool.input, result.input, self.limits.max_tool_field_bytes, run.redaction_secret);
                const content = try self.replaceTrackedProjected(&tool.content, result.content, self.limits.max_tool_field_bytes, run.redaction_secret);
                tool.input_truncated = input.truncated;
                tool.content_truncated = content.truncated;
                tool.redacted = tool.redacted or input.redacted or content.redacted;
                tool.is_error = result.is_error;
                tool.elapsed_ms = result.elapsed_ms;
                tool.state = if (result.is_error) .failed else .completed;
            },
            .usage => |usage| {
                run.usage.input_tokens = try addU64(run.usage.input_tokens, usage.input_tokens);
                run.usage.output_tokens = try addU64(run.usage.output_tokens, usage.output_tokens);
                run.usage.cache_read_input_tokens = try addU64(run.usage.cache_read_input_tokens, usage.cache_read_input_tokens);
                run.usage.cache_creation_input_tokens = try addU64(run.usage.cache_creation_input_tokens, usage.cache_creation_input_tokens);
            },
            .context_warning => |warning| _ = try self.replaceTrackedProjected(&run.status_text, warning.level, self.limits.max_tool_field_bytes, run.redaction_secret),
            .auto_compact => _ = try self.replaceTrackedProjected(&run.status_text, "Context compacted", self.limits.max_tool_field_bytes, run.redaction_secret),
            .retry_notice => _ = try self.replaceTrackedProjected(&run.status_text, "Retrying provider", self.limits.max_tool_field_bytes, run.redaction_secret),
            .stream_done => _ = try self.replaceTrackedProjected(&run.status_text, "Finishing", self.limits.max_tool_field_bytes, run.redaction_secret),
        }
        self.bumpRevision();
    }

    /// Records canonical event loss independently of Agent execution state.
    /// A termination request may arrive after Agent terminal publication, so
    /// it cannot be the only owner of this product failure fact.
    pub fn recordEventProjectionFailure(
        self: *Workbench,
        route_id: u64,
        run_id: u64,
    ) void {
        const task = self.findTaskByRouteId(route_id) orelse return;
        const run = findRun(task.runs, run_id) orelse return;
        if (run.event_projection_failure != null) return;
        run.event_projection_failure = .consumer_rejected;
        if (task.lifecycle == .open)
            task.continuation = .{ .unavailable = .event_projection_failure };
        self.touchTask(task);
        self.bumpRevision();
    }

    /// Marks terminal Runs before the composition root performs one more
    /// complete Agent event-pump drain. The acquire in `terminalPayload`
    /// observes every callback enqueue that happened before Run completion.
    pub fn markTerminalRunsBeforeEventDrain(self: *Workbench) void {
        for (self.tasks) |*task_entry| {
            const task = &(task_entry.* orelse continue);
            for (task.runs) |*run_entry| {
                const run = &(run_entry.* orelse continue);
                if (run.event_stream_finalized or run.terminal_event_drain_marked)
                    continue;
                if (terminalPayload(run) != null)
                    run.terminal_event_drain_marked = true;
            }
        }
    }

    /// Commits the final assistant suffix only after the composition root has
    /// drained the Agent event pump following `markTerminalRunsBeforeEventDrain`.
    /// Any later event for the Run is rejected by `applyEvent`.
    pub fn finalizeMarkedTerminalRunsAfterEventDrain(self: *Workbench) void {
        var changed = false;
        for (self.tasks) |*task_entry| {
            const task = &(task_entry.* orelse continue);
            for (task.runs) |*run_entry| {
                const run = &(run_entry.* orelse continue);
                if (!run.terminal_event_drain_marked) continue;
                std.debug.assert(terminalPayload(run) != null);
                run.terminal_event_drain_marked = false;
                run.event_stream_finalized = true;
                // Product terminal visibility changes even when the assistant
                // has no withheld suffix.
                changed = true;
                self.touchTask(task);
                if (run.assistant.committed_len != run.assistant.list.items.len) {
                    run.assistant.committed_len = run.assistant.list.items.len;
                }
            }
        }
        if (changed) self.bumpRevision();
    }

    pub fn writeSnapshot(self: *Workbench, output: []u8) Error![]const u8 {
        self.syncLifecycle();
        var writer = std.Io.Writer.fixed(output);
        const schedule_persistence_ready =
            self.schedule_persistence_health == .ready;
        const background_schedule_wake = self.schedule_background_available;
        writer.print("{{\"revision\":\"{d}\",\"capabilities\":{{\"taskHistoryPersistence\":false,\"conversationRecovery\":false,\"executionRebind\":false,\"structuredPlan\":false,\"typedOutputs\":false,\"typedFileChanges\":false,\"persistentWorkspacePermissions\":false,\"managedWorkspaces\":{},\"scheduledTasks\":{},\"scheduledTaskPersistence\":{},\"scheduledTaskPersistenceHealth\":\"{s}\",\"backgroundScheduleWake\":{}}},\"account\":", .{
            self.revision,
            self.managed_workspaces != null,
            self.schedule_timer.enabled and schedule_persistence_ready and
                background_schedule_wake,
            schedule_persistence_ready,
            @tagName(self.schedule_persistence_health),
            background_schedule_wake,
        }) catch
            return error.SnapshotTooLarge;
        try self.writeAccount(&writer);
        writer.writeAll(",\"skillCatalog\":") catch
            return error.SnapshotTooLarge;
        try self.writeCatalogProjection(
            &writer,
            catalogProjection(
                self.skill_catalog_availability,
                if (self.skill_catalog) |*snapshot| snapshot else null,
            ),
        );
        writer.writeAll(",\"selectedWorkspaceId\":") catch
            return error.SnapshotTooLarge;
        if (self.selected_workspace_id == 0)
            writer.writeAll("null") catch return error.SnapshotTooLarge
        else
            writer.print("\"{d}\"", .{self.selected_workspace_id}) catch
                return error.SnapshotTooLarge;
        writer.writeAll(",\"workspaces\":[") catch return error.SnapshotTooLarge;
        var workspace_count: usize = 0;
        for (self.workspaces) |*entry| {
            const workspace = &(entry.* orelse continue);
            if (workspace.origin == .user and !workspace.visible) continue;
            if (workspace_count != 0) writer.writeByte(',') catch
                return error.SnapshotTooLarge;
            workspace_count += 1;
            try self.writeWorkspace(&writer, workspace);
        }
        writer.writeAll("],\"scheduledTasks\":[") catch
            return error.SnapshotTooLarge;
        var scheduled_task_count: usize = 0;
        for (self.scheduled_tasks.items) |*entry| {
            const scheduled_task = &(entry.* orelse continue);
            if (scheduled_task_count != 0) writer.writeByte(',') catch
                return error.SnapshotTooLarge;
            scheduled_task_count += 1;
            try self.writeScheduledTask(&writer, scheduled_task);
        }
        writer.writeAll("],\"tasks\":[") catch
            return error.SnapshotTooLarge;
        var task_count: usize = 0;
        for (self.tasks) |*entry| {
            const task = &(entry.* orelse continue);
            if (task_count != 0) writer.writeByte(',') catch return error.SnapshotTooLarge;
            task_count += 1;
            try self.writeTask(&writer, task);
        }
        writer.writeAll("]}") catch return error.SnapshotTooLarge;
        return writer.buffered();
    }

    fn writeScheduledTask(
        self: *Workbench,
        writer: *std.Io.Writer,
        item: *const scheduled_tasks_impl.Item,
    ) Error!void {
        writer.print(
            "{{\"id\":\"{d}\",\"epoch\":\"{d}\",\"title\":",
            .{ item.id, item.epoch },
        ) catch return error.SnapshotTooLarge;
        try self.projectedJsonValueWithKnownCredentials(writer, item.title);
        writer.print(
            ",\"titleRedacted\":{},\"enabled\":{},\"health\":\"{s}\",\"failureReason\":",
            .{ item.title_redacted, item.enabled, @tagName(item.health) },
        ) catch return error.SnapshotTooLarge;
        if (item.failure_reason) |reason|
            writer.print("\"{s}\"", .{@tagName(reason)}) catch
                return error.SnapshotTooLarge
        else
            writer.writeAll("null") catch return error.SnapshotTooLarge;
        writer.writeAll(",\"target\":") catch return error.SnapshotTooLarge;
        switch (item.target) {
            .default => writer.writeAll("{\"kind\":\"default\"}") catch
                return error.SnapshotTooLarge,
            .explicit => |explicit| writer.print(
                "{{\"kind\":\"explicit\",\"workspaceId\":\"{d}\",\"workspaceEpoch\":\"{d}\"}}",
                .{ explicit.workspace_id, explicit.workspace_epoch },
            ) catch return error.SnapshotTooLarge,
        }
        writer.print(
            ",\"execution\":{{\"generation\":\"{d}\",\"provider\":\"{s}\",\"model\":",
            .{ item.execution_generation, @tagName(item.execution_provider) },
        ) catch return error.SnapshotTooLarge;
        try self.projectedJsonValueWithKnownCredentials(
            writer,
            item.execution_model,
        );
        writer.writeAll("},\"input\":") catch return error.SnapshotTooLarge;
        switch (item.input) {
            .text => |text| {
                writer.writeAll("{\"kind\":\"text\",\"text\":") catch
                    return error.SnapshotTooLarge;
                try self.projectedJsonValueWithKnownCredentials(
                    writer,
                    text.value,
                );
                writer.print(",\"redacted\":{}}}", .{text.redacted}) catch
                    return error.SnapshotTooLarge;
            },
            .skill => |skill| {
                writer.writeAll("{\"kind\":\"skill\",\"skillId\":") catch
                    return error.SnapshotTooLarge;
                try self.projectedJsonValueWithKnownCredentials(
                    writer,
                    skill.skill_id,
                );
                writer.writeAll(",\"catalogRevision\":") catch
                    return error.SnapshotTooLarge;
                try self.projectedJsonValueWithKnownCredentials(
                    writer,
                    skill.catalog_revision,
                );
                writer.writeAll(",\"argumentValues\":[") catch
                    return error.SnapshotTooLarge;
                for (skill.argument_values, 0..) |value, index| {
                    if (index != 0) writer.writeByte(',') catch
                        return error.SnapshotTooLarge;
                    try self.projectedJsonValueWithKnownCredentials(
                        writer,
                        value,
                    );
                }
                writer.print("],\"redacted\":{}}}", .{skill.redacted}) catch
                    return error.SnapshotTooLarge;
            },
        }
        writer.writeAll(",\"recurrence\":") catch return error.SnapshotTooLarge;
        switch (item.recurrence) {
            .once => |once| writer.print(
                "{{\"kind\":\"once\",\"atUnixSeconds\":\"{d}\"}}",
                .{once.at_unix_seconds},
            ) catch return error.SnapshotTooLarge,
            .interval => |interval| writer.print(
                "{{\"kind\":\"interval\",\"startAtUnixSeconds\":\"{d}\",\"everySeconds\":\"{d}\"}}",
                .{ interval.start_at_unix_seconds, interval.every_seconds },
            ) catch return error.SnapshotTooLarge,
        }
        writer.writeAll(",\"nextRunAtUnixSeconds\":") catch
            return error.SnapshotTooLarge;
        if (item.next_run_at_unix_seconds) |next|
            writer.print("\"{d}\"", .{next}) catch
                return error.SnapshotTooLarge
        else
            writer.writeAll("null") catch return error.SnapshotTooLarge;
        writer.writeAll(",\"occurrences\":[") catch
            return error.SnapshotTooLarge;
        for (item.occurrences(), 0..) |occurrence, index| {
            if (index != 0) writer.writeByte(',') catch
                return error.SnapshotTooLarge;
            writer.print(
                "{{\"plannedAtUnixSeconds\":\"{d}\",\"triggeredAtUnixSeconds\":\"{d}\",\"source\":\"{s}\",\"result\":\"{s}\",\"taskId\":",
                .{
                    occurrence.planned_at_unix_seconds,
                    occurrence.triggered_at_unix_seconds,
                    @tagName(occurrence.source),
                    @tagName(occurrence.result),
                },
            ) catch return error.SnapshotTooLarge;
            if (occurrence.task_id == 0)
                writer.writeAll("null") catch return error.SnapshotTooLarge
            else
                writer.print("\"{d}\"", .{occurrence.task_id}) catch
                    return error.SnapshotTooLarge;
            writer.writeAll(",\"reason\":") catch return error.SnapshotTooLarge;
            if (occurrence.reason) |reason|
                writer.print("\"{s}\"", .{@tagName(reason)}) catch
                    return error.SnapshotTooLarge
            else
                writer.writeAll("null") catch return error.SnapshotTooLarge;
            writer.writeAll(",\"taskOutcome\":") catch
                return error.SnapshotTooLarge;
            if (occurrence.task_outcome) |outcome|
                writer.print("\"{s}\"", .{@tagName(outcome)}) catch
                    return error.SnapshotTooLarge
            else
                writer.writeAll("null") catch return error.SnapshotTooLarge;
            writer.writeByte('}') catch return error.SnapshotTooLarge;
        }
        writer.writeAll("]}") catch return error.SnapshotTooLarge;
    }

    fn writeAccount(
        self: *Workbench,
        writer: *std.Io.Writer,
    ) Error!void {
        const view = self.accountView();
        writer.print(
            "{{\"sessionState\":\"{s}\",\"executionState\":\"{s}\",\"operation\":\"{s}\",\"readiness\":\"{s}\",\"primaryAction\":\"{s}\",\"canCancel\":{},\"accountId\":",
            .{
                @tagName(view.session_state),
                @tagName(view.execution_state),
                @tagName(view.operation),
                @tagName(view.readiness),
                @tagName(view.primary_action),
                view.can_cancel,
            },
        ) catch return error.SnapshotTooLarge;
        try self.projectedJsonValue(writer, view.account_id);
        writer.writeAll(",\"profileId\":") catch
            return error.SnapshotTooLarge;
        try self.projectedJsonValue(writer, view.profile_id);
        writer.writeAll(",\"displayName\":") catch
            return error.SnapshotTooLarge;
        try self.projectedJsonValue(writer, view.display_name);
        writer.writeAll(",\"apiKeys\":[") catch
            return error.SnapshotTooLarge;
        for (view.api_keys, 0..) |api_key, index| {
            if (index != 0) writer.writeByte(',') catch
                return error.SnapshotTooLarge;
            writer.writeAll("{\"selectionId\":") catch
                return error.SnapshotTooLarge;
            try self.projectedJsonValue(writer, api_key.id);
            writer.writeAll(",\"name\":") catch
                return error.SnapshotTooLarge;
            try self.projectedJsonValue(writer, api_key.name);
            writer.writeAll(",\"suffix\":") catch
                return error.SnapshotTooLarge;
            try self.projectedJsonValue(writer, api_key.suffix);
            writer.print(",\"provider\":\"{s}\"", .{@tagName(api_key.provider_kind)}) catch
                return error.SnapshotTooLarge;
            writer.writeByte('}') catch return error.SnapshotTooLarge;
        }
        writer.writeAll("],\"models\":[") catch
            return error.SnapshotTooLarge;
        for (view.models, 0..) |model, index| {
            if (index != 0) writer.writeByte(',') catch
                return error.SnapshotTooLarge;
            writer.writeAll("{\"selectionId\":") catch
                return error.SnapshotTooLarge;
            try self.projectedJsonValue(writer, model.id);
            writer.writeAll(",\"displayName\":") catch
                return error.SnapshotTooLarge;
            try self.projectedJsonValue(writer, model.display_name);
            writer.writeByte('}') catch return error.SnapshotTooLarge;
        }
        writer.writeAll("],\"selectedApiKeySelectionId\":") catch
            return error.SnapshotTooLarge;
        try self.projectedJsonValue(writer, view.selected_api_key_id);
        writer.writeAll(",\"selectedModelSelectionId\":") catch
            return error.SnapshotTooLarge;
        try self.projectedJsonValue(writer, view.selected_model);
        writer.writeAll(",\"candidateApiKeySelectionId\":") catch
            return error.SnapshotTooLarge;
        try self.projectedJsonValue(writer, view.candidate_api_key_id);
        writer.writeAll(",\"candidateModelSelectionId\":") catch
            return error.SnapshotTooLarge;
        try self.projectedJsonValue(writer, view.candidate_model);
        writer.writeAll(",\"modelCatalogApiKeySelectionId\":") catch
            return error.SnapshotTooLarge;
        try self.projectedJsonValue(writer, view.model_catalog_api_key_id);
        writer.print(
            ",\"canCreateTask\":{},\"errorCode\":\"{s}\",\"safeDiagnostic\":",
            .{ view.can_create_task, @tagName(view.error_code) },
        ) catch return error.SnapshotTooLarge;
        try self.projectedJsonValue(writer, view.safe_diagnostic);
        writer.print(
            ",\"catalogGeneration\":\"{d}\",\"executionGeneration\":\"{d}\"}}",
            .{ view.catalog_generation, view.execution_generation },
        ) catch return error.SnapshotTooLarge;
    }

    fn writeWorkspace(
        self: *Workbench,
        writer: *std.Io.Writer,
        workspace: *const WorkspaceView,
    ) Error!void {
        const signals = self.workspaceSignals(workspace.id);
        writer.print("{{\"id\":\"{d}\",\"epoch\":\"{d}\",\"origin\":\"{s}\",\"displayName\":", .{
            workspace.id,
            workspace.epoch,
            @tagName(workspace.origin),
        }) catch
            return error.SnapshotTooLarge;
        const display_name = workspace.display_name_storage[0..workspace.display_name_len];
        const projected_root = workspace.projected_root_storage[0..workspace.projected_root_len];
        try self.projectedJsonValueWithKnownCredentials(writer, display_name);
        writer.writeAll(",\"canonicalRoot\":") catch return error.SnapshotTooLarge;
        try self.projectedJsonValueWithKnownCredentials(writer, projected_root);
        writer.print(",\"redacted\":{},\"authorization\":\"{s}\",\"lastRemovalFailure\":", .{
            workspace.projection_redacted or
                self.containsKnownCredential(display_name) or
                self.containsKnownCredential(projected_root),
            @tagName(workspace.authorization),
        }) catch return error.SnapshotTooLarge;
        if (workspace.last_removal_failure == .none)
            writer.writeAll("null") catch return error.SnapshotTooLarge
        else
            writer.print("\"{s}\"", .{@tagName(workspace.last_removal_failure)}) catch
                return error.SnapshotTooLarge;
        writer.writeAll(",\"skillCatalog\":") catch
            return error.SnapshotTooLarge;
        try self.writeCatalogProjection(
            writer,
            catalogProjection(
                workspace.catalog_availability,
                if (workspace.catalog) |*snapshot| snapshot else null,
            ),
        );
        writer.print(",\"recentOrder\":\"{d}\",\"signals\":{{\"running\":{},\"attention\":{},\"failedOrInterrupted\":{}}}}}", .{
            workspace.recent_order,
            signals.running,
            signals.attention,
            signals.failed_or_interrupted,
        }) catch return error.SnapshotTooLarge;
    }

    pub fn deinit(self: *Workbench) void {
        self.shutdownExecutor();
        self.schedule_timer.cancelCurrent();
        self.markSkillCatalogUnavailable();
        for (self.tasks) |*entry| {
            const task = &(entry.* orelse continue);
            if (task.close_thread) |thread| thread.join();
            self.deinitTaskView(task);
            entry.* = null;
        }
        self.allocator.free(self.tasks);
        for (self.workspaces) |*entry| {
            const workspace = &(entry.* orelse continue);
            self.deinitWorkspaceView(workspace);
        }
        self.allocator.free(self.workspaces);
        self.scheduled_tasks.deinit();
        if (self.managed_workspaces) |*store| store.deinit();
        if (self.canonical_user_home) |home| self.allocator.free(home);
        self.execution.deinit();
        self.account.deinit();
        std.debug.assert(self.projection_bytes == 0);
        self.executor.deinit();
        self.* = undefined;
    }

    pub fn shutdownExecutor(self: *Workbench) void {
        if (self.executor_shutdown) return;
        self.shutting_down = true;
        self.schedule_timer.cancelCurrent();
        for (self.tasks) |*entry| {
            const view = &(entry.* orelse continue);
            const session = view.session orelse continue;
            const run = findRun(view.runs, view.active_run_id) orelse continue;
            if (isTerminalPhase(runPhase(run))) continue;
            if (self.executor.cancel(run)) {
                cancelPreparedRunOrPanic(session, run.id);
                releaseWorkerReference(run);
                _ = commitTerminal(
                    run,
                    .interrupted,
                    .interrupted,
                    .app_shutdown,
                    .closing,
                    "",
                    false,
                );
                run.terminal_observed = true;
            } else {
                consumeLifecycleTermination(
                    requestRunTermination(run, .app_shutdown),
                    run.id,
                );
            }
        }
        self.executor.shutdown();
        self.executor_shutdown = true;
        _ = self.commitCatalogJobsNoFail();
        self.markSkillCatalogUnavailable();
        for (self.workspaces) |*entry| {
            const workspace = &(entry.* orelse continue);
            self.markWorkspaceCatalogUnavailable(workspace);
        }
        self.syncLifecycle();
    }

    fn writeTask(self: *Workbench, writer: *std.Io.Writer, view: *TaskView) Error!void {
        writer.print("{{\"id\":\"{d}\",\"recentOrder\":\"{d}\",\"title\":", .{
            view.id,
            view.recent_order,
        }) catch return error.SnapshotTooLarge;
        try self.projectedJsonValueWithKnownCredentials(writer, view.title);
        writer.print(",\"workspaceId\":\"{d}\",\"binding\":{{\"epoch\":\"{d}\",\"availability\":\"{s}\",\"accountId\":", .{
            view.workspace_id,
            view.binding_epoch,
            if (view.execution == null) "unavailable" else "available",
        }) catch return error.SnapshotTooLarge;
        try self.projectedJsonValueWithKnownCredentials(writer, view.binding_account_id);
        writer.writeAll(",\"profileId\":") catch return error.SnapshotTooLarge;
        try self.projectedJsonValueWithKnownCredentials(writer, view.binding_profile_id);
        writer.writeAll(",\"accountDisplayName\":") catch return error.SnapshotTooLarge;
        try self.projectedJsonValueWithKnownCredentials(writer, view.binding_account_name);
        writer.writeAll(",\"apiKeySelectionId\":") catch return error.SnapshotTooLarge;
        try self.projectedJsonValueWithKnownCredentials(writer, view.binding_api_key_id);
        writer.writeAll(",\"apiKeyName\":") catch return error.SnapshotTooLarge;
        try self.projectedJsonValueWithKnownCredentials(writer, view.binding_api_key_name);
        writer.writeAll(",\"apiKeySuffix\":") catch return error.SnapshotTooLarge;
        try self.projectedJsonValueWithKnownCredentials(writer, view.binding_api_key_suffix);
        writer.print(",\"provider\":\"{s}\",\"modelSelectionId\":", .{@tagName(view.execution_provider)}) catch
            return error.SnapshotTooLarge;
        try self.projectedJsonValueWithKnownCredentials(writer, view.binding_model_id);
        writer.writeAll(",\"modelDisplayName\":") catch return error.SnapshotTooLarge;
        try self.projectedJsonValueWithKnownCredentials(writer, view.binding_model_display_name);
        writer.print(",\"executionGeneration\":\"{d}\",\"unavailableReason\":", .{view.execution_generation}) catch
            return error.SnapshotTooLarge;
        if (view.execution == null)
            writer.writeAll("\"credential_released\"") catch return error.SnapshotTooLarge
        else
            writer.writeAll("null") catch return error.SnapshotTooLarge;
        writer.writeByte('}') catch return error.SnapshotTooLarge;
        writer.writeAll(",\"skillCatalog\":") catch
            return error.SnapshotTooLarge;
        try self.writeCatalogProjection(
            writer,
            taskCatalogProjection(view),
        );
        writer.print(",\"lifecycle\":\"{s}\",\"continuationAvailable\":{},\"archived\":{},\"closeFailed\":{},\"currentRunId\":\"{d}\",\"currentRunPhase\":", .{
            @tagName(view.lifecycle),
            self.taskContinuationAvailable(view),
            view.archived,
            view.close_failed,
            if (currentRunPhase(view) == null) 0 else view.active_run_id,
        }) catch return error.SnapshotTooLarge;
        if (currentRunPhase(view)) |phase| jsonValue(writer, @tagName(phase)) catch return error.SnapshotTooLarge else writer.writeAll("null") catch return error.SnapshotTooLarge;
        const last_terminal = lastTerminalFacts(view.runs);
        writer.writeAll(",\"lastRunOutcome\":") catch return error.SnapshotTooLarge;
        if (last_terminal) |terminal| jsonValue(writer, @tagName(terminal.outcome)) catch return error.SnapshotTooLarge else writer.writeAll("null") catch return error.SnapshotTooLarge;
        writer.writeAll(",\"cause\":") catch return error.SnapshotTooLarge;
        if (last_terminal) |terminal| {
            if (terminal.cause) |cause| jsonValue(writer, @tagName(cause)) catch return error.SnapshotTooLarge else writer.writeAll("null") catch return error.SnapshotTooLarge;
        } else writer.writeAll("null") catch return error.SnapshotTooLarge;
        writer.writeAll(",\"runs\":[") catch return error.SnapshotTooLarge;
        var run_count: usize = 0;
        for (view.runs) |*entry| {
            const run = &(entry.* orelse continue);
            if (run_count != 0) writer.writeByte(',') catch return error.SnapshotTooLarge;
            run_count += 1;
            try self.writeRun(writer, run);
        }
        writer.writeAll("],\"pendingUi\":") catch return error.SnapshotTooLarge;
        try self.writePendingUi(writer, view);
        writer.writeAll(",\"uiHistory\":[") catch return error.SnapshotTooLarge;
        try self.writeUiHistory(writer, view);
        writer.writeByte(']') catch return error.SnapshotTooLarge;
        writer.writeByte('}') catch return error.SnapshotTooLarge;
    }

    fn writeCatalogProjection(
        self: *Workbench,
        writer: *std.Io.Writer,
        catalog: CatalogProjection,
    ) Error!void {
        writer.print("{{\"availability\":\"{s}\",\"redacted\":{},\"revision\":", .{
            @tagName(catalog.availability),
            catalog.redacted or self.catalogContainsKnownCredential(catalog),
        }) catch return error.SnapshotTooLarge;
        switch (catalog.availability) {
            .ready, .degraded => try self.projectedJsonValueWithKnownCredentials(
                writer,
                catalog.revision,
            ),
            .uninitialized, .loading, .unavailable => writer.writeAll("null") catch
                return error.SnapshotTooLarge,
        }
        writer.writeAll(",\"skills\":[") catch return error.SnapshotTooLarge;
        for (catalog.skills, 0..) |skill, index| {
            if (index != 0) writer.writeByte(',') catch
                return error.SnapshotTooLarge;
            writer.writeAll("{\"skillId\":") catch return error.SnapshotTooLarge;
            try self.projectedJsonValueWithKnownCredentials(
                writer,
                skill.skill_id,
            );
            writer.writeAll(",\"invocationName\":") catch
                return error.SnapshotTooLarge;
            try self.projectedJsonValueWithKnownCredentials(
                writer,
                skill.invocation_name,
            );
            writer.writeAll(",\"displayName\":") catch
                return error.SnapshotTooLarge;
            try self.projectedJsonValueWithKnownCredentials(
                writer,
                skill.display_name,
            );
            writer.writeAll(",\"description\":") catch
                return error.SnapshotTooLarge;
            try self.projectedJsonValueWithKnownCredentials(
                writer,
                skill.description,
            );
            writer.writeAll(",\"argumentNames\":[") catch
                return error.SnapshotTooLarge;
            for (skill.argument_names, 0..) |name, argument_index| {
                if (argument_index != 0) writer.writeByte(',') catch
                    return error.SnapshotTooLarge;
                try self.projectedJsonValueWithKnownCredentials(writer, name);
            }
            writer.print("],\"maxValues\":{d}}}", .{skill.max_values}) catch
                return error.SnapshotTooLarge;
        }
        writer.writeAll("],\"issues\":[") catch return error.SnapshotTooLarge;
        for (catalog.issues, 0..) |issue, index| {
            if (index != 0) writer.writeByte(',') catch
                return error.SnapshotTooLarge;
            writer.print("{{\"code\":\"{s}\",\"invocationName\":", .{
                @tagName(issue.code),
            }) catch return error.SnapshotTooLarge;
            if (issue.invocation_name) |name|
                try self.projectedJsonValueWithKnownCredentials(writer, name)
            else
                writer.writeAll("null") catch return error.SnapshotTooLarge;
            writer.writeByte('}') catch return error.SnapshotTooLarge;
        }
        writer.writeAll("]}") catch return error.SnapshotTooLarge;
    }

    fn catalogContainsKnownCredential(
        self: *const Workbench,
        catalog: CatalogProjection,
    ) bool {
        if (self.containsKnownCredential(catalog.revision)) return true;
        for (catalog.skills) |skill| {
            inline for (.{
                skill.skill_id,
                skill.invocation_name,
                skill.display_name,
                skill.description,
            }) |field|
                if (self.containsKnownCredential(field)) return true;
            for (skill.argument_names) |name|
                if (self.containsKnownCredential(name)) return true;
        }
        for (catalog.issues) |issue|
            if (issue.invocation_name) |name|
                if (self.containsKnownCredential(name)) return true;
        return false;
    }

    fn writePendingUi(self: *Workbench, writer: *std.Io.Writer, view: *TaskView) Error!void {
        const session = view.session orelse {
            writer.writeAll("null") catch return error.SnapshotTooLarge;
            return;
        };
        var pending = session.copyPendingUiRequest(self.allocator) catch |err| switch (err) {
            error.NoPendingUiRequest, error.StaleUiResponse => {
                writer.writeAll("null") catch return error.SnapshotTooLarge;
                return;
            },
            else => return err,
        };
        defer pending.deinit();
        var parsed = lifecycle.decodeUiRequest(self.allocator, pending.json) catch return error.InvalidUiResponse;
        defer parsed.deinit();
        // The synchronous callback may publish between lifecycle reconciliation
        // and serialization. Omit that just-arrived request from this snapshot;
        // its notification drives the next revision instead of failing the
        // whole product snapshot on a benign observation race.
        if (view.pending_ui_request_id != pending.request_id or view.pending_ui_order == 0) {
            writer.writeAll("null") catch return error.SnapshotTooLarge;
            return;
        }
        if (findRun(view.runs, pending.run_id) == null)
            return error.InvalidUiResponse;
        try self.writePendingUiProjection(
            writer,
            pending.request_id,
            pending.run_id,
            view.pending_ui_order,
            parsed.value,
        );
    }

    fn findOrCreateTool(
        self: *Workbench,
        run: *RunRecord,
        id: []const u8,
        name: []const u8,
        input: []const u8,
    ) Error!*ToolView {
        const route_digest = toolRouteDigest(id);
        if (findToolByRouteDigest(run.tools, route_digest)) |tool| return tool;
        const slot = findEmpty(ToolView, run.tools) orelse return error.ToolCapacity;
        const order = run.next_activity_order;
        var product_id_storage: [tool_product_id_capacity]u8 = undefined;
        const product_id = std.fmt.bufPrint(&product_id_storage, "tool-{d}", .{order}) catch unreachable;
        const owned_id = try self.copyBounded(product_id, tool_product_id_capacity);
        errdefer self.freeTracked(owned_id);
        const name_projection = try self.copyProjected(name, self.limits.max_tool_field_bytes, run.redaction_secret);
        const owned_name = name_projection.value;
        errdefer self.freeTracked(owned_name);
        const input_projection = try self.copyProjected(input, self.limits.max_tool_field_bytes, run.redaction_secret);
        const owned_input = input_projection.value;
        errdefer self.freeTracked(owned_input);
        const progress = try self.copyBounded("", self.limits.max_tool_field_bytes);
        errdefer self.freeTracked(progress);
        const content = try self.copyBounded("", self.limits.max_tool_field_bytes);
        run.tools[slot] = .{
            .route_digest = route_digest,
            .id = owned_id,
            .order = takeActivityOrder(run),
            .name = owned_name,
            .input = owned_input,
            .progress = progress,
            .content = content,
            .state = .running,
            .input_truncated = input_projection.truncated,
            .redacted = name_projection.redacted or
                input_projection.redacted,
        };
        return &run.tools[slot].?;
    }

    fn taskContinuationAvailable(self: *const Workbench, task: *const TaskView) bool {
        return !self.shutting_down and
            task.lifecycle == .open and
            continuationAvailable(task.continuation);
    }

    fn taskExecutionInput(
        task: *const TaskView,
    ) Error!account_contract.ExecutionConfigInput {
        const execution = &(task.execution orelse return error.ExecutionUnavailable);
        const input = execution.input();
        if (input.execution_generation != task.execution_generation or
            accountProvider(input.target.provider_kind) != task.execution_provider or
            !std.mem.eql(u8, input.target.model, task.execution_model))
            return error.ExecutionGenerationMismatch;
        return input;
    }

    fn canCreateTask(self: *const Workbench) bool {
        return !self.shutting_down and
            !self.execution_replacement_pending and
            self.account.account_can_create_task and
            self.account.execution_state == .ready and
            self.execution.ready() and
            self.account.execution_generation == self.execution.generation;
    }

    fn scheduledTaskDefinition(
        self: *Workbench,
        input: ScheduledTaskDefinitionInput,
    ) Error!scheduled_tasks_impl.Definition {
        if (!self.canCreateTask()) return error.ExecutionUnavailable;
        if (input.expected_execution_generation == 0 or
            input.expected_execution_generation != self.execution.generation or
            input.expected_execution_generation != self.account.execution_generation)
            return error.ExecutionGenerationMismatch;
        const title = std.mem.trim(u8, input.title, " \t\r\n");
        if (title.len == 0 or title.len > self.limits.max_task_title_bytes or
            !std.unicode.utf8ValidateSlice(title))
            return error.InvalidTaskTitle;
        for (title) |byte| if (byte < 0x20) return error.InvalidTaskTitle;
        const workspace: ?*WorkspaceView = switch (input.target) {
            .default => if (self.managed_workspaces != null)
                null
            else
                return error.WorkspaceUnavailable,
            .explicit => |explicit| explicit_target: {
                const candidate = self.findWorkspace(explicit.workspace_id) orelse
                    return error.UnknownWorkspace;
                if (explicit.expected_workspace_epoch == 0 or
                    explicit.expected_workspace_epoch != candidate.epoch)
                    return error.WorkspaceEpochMismatch;
                if (candidate.origin != .user or !candidate.visible or
                    candidate.authorization != .available)
                    return error.WorkspaceUnavailable;
                break :explicit_target candidate;
            },
        };
        try input.recurrence.validate();
        const scheduled_input: scheduled_tasks_impl.Input = switch (input.input) {
            .text => |text| text_input: {
                const trimmed = std.mem.trim(u8, text, " \t\r\n");
                if (trimmed.len == 0 or
                    trimmed.len > self.limits.max_user_message_bytes or
                    !std.unicode.utf8ValidateSlice(trimmed))
                    return error.InvalidScheduledTaskInput;
                break :text_input .{ .text = trimmed };
            },
            .skill => |skill_input| skill_admission: {
                const explicit_workspace = workspace orelse
                    return error.InvalidScheduledTaskInput;
                const catalog = explicit_workspace.catalog orelse
                    return error.CatalogUnavailable;
                if (!std.mem.eql(
                    u8,
                    skill_input.catalog_revision,
                    catalog.revision,
                ))
                    return error.StaleCatalog;
                const skill = catalog.findSkill(skill_input.skill_id) orelse
                    return error.SkillNotFound;
                if (skill_input.argument_values.len >
                    @min(
                        @as(usize, @intCast(skill.max_values)),
                        self.limits.max_skill_arguments,
                    ))
                    return error.InvalidSkillArguments;
                var bytes = std.math.add(
                    usize,
                    skill.skill_id.len,
                    catalog.revision.len,
                ) catch return error.ProjectionCapacity;
                for (skill_input.argument_values) |value| {
                    if (!std.unicode.utf8ValidateSlice(value))
                        return error.InvalidSkillArguments;
                    bytes = std.math.add(usize, bytes, value.len) catch
                        return error.ProjectionCapacity;
                    if (bytes > self.limits.max_user_message_bytes)
                        return error.ProjectionCapacity;
                }
                break :skill_admission .{ .skill = .{
                    .skill_id = skill.skill_id,
                    .catalog_revision = catalog.revision,
                    .argument_values = skill_input.argument_values,
                } };
            },
        };
        return .{
            .title = title,
            .target = switch (input.target) {
                .default => .default,
                .explicit => .{ .explicit = .{
                    .workspace_id = workspace.?.id,
                    .workspace_epoch = workspace.?.epoch,
                } },
            },
            .execution_generation = self.execution.generation,
            .execution_provider = scheduledProvider(self.execution.provider.?),
            .execution_model = self.execution.model(),
            .input = scheduled_input,
            .recurrence = input.recurrence,
        };
    }

    fn triggerScheduledTask(
        self: *Workbench,
        id: u64,
        planned_at_unix_seconds: u64,
        triggered_at_unix_seconds: u64,
        source: scheduled_tasks_impl.OccurrenceSource,
    ) Error!u64 {
        const item = self.scheduled_tasks.find(id) orelse
            return error.UnknownScheduledTask;
        if (item.last_occurrence) |last| if (last.task_id != 0) {
            if (self.findTask(last.task_id)) |task| {
                if (hasNonTerminalRun(task)) {
                    if (source == .timer) {
                        var skipped = try self.scheduled_tasks.clone(
                            self.allocator,
                        );
                        var skipped_owned = true;
                        defer if (skipped_owned) skipped.deinit();
                        try skipped.markSkipped(
                            skipped.find(id).?,
                            planned_at_unix_seconds,
                            triggered_at_unix_seconds,
                        );
                        try self.commitScheduledTaskCandidate(&skipped);
                        self.replaceScheduledTaskStore(&skipped);
                        skipped_owned = false;
                        self.bumpRevision();
                        _ = self.schedule_notifier.notify(.{
                            .scheduled_task_id = id,
                            .task_id = last.task_id,
                            .title = (self.scheduled_tasks.find(id) orelse
                                unreachable).title,
                            .kind = .skipped,
                        });
                        return last.task_id;
                    }
                    return error.TaskBusy;
                }
            }
        };
        var claimed = try self.scheduled_tasks.clone(self.allocator);
        var claimed_owned = true;
        defer if (claimed_owned) claimed.deinit();
        try claimed.claim(
            claimed.find(id).?,
            planned_at_unix_seconds,
            triggered_at_unix_seconds,
            source,
        );
        try self.commitScheduledTaskCandidate(&claimed);
        self.replaceScheduledTaskStore(&claimed);
        claimed_owned = false;

        const claimed_item = self.scheduled_tasks.find(id) orelse unreachable;
        const expected_catalog_revision = switch (claimed_item.input) {
            .text => null,
            .skill => |skill| skill.catalog_revision,
        };
        const workspace_request: TaskWorkspaceRequest = switch (claimed_item.target) {
            .default => .managed,
            .explicit => |explicit| .{ .existing = .{
                .workspace_id = explicit.workspace_id,
                .expected_epoch = explicit.workspace_epoch,
            } },
        };
        const task_id = self.createTaskForWorkspace(
            workspace_request,
            claimed_item.execution_generation,
            expected_catalog_revision,
        ) catch |err| {
            self.finalizeScheduledTaskClaimRejected(
                id,
                planned_at_unix_seconds,
                source,
                scheduledFailure(err),
            );
            return err;
        };
        self.renameTask(task_id, claimed_item.title) catch |err| {
            self.finalizeScheduledTaskClaimRejected(
                id,
                planned_at_unix_seconds,
                source,
                .task_start_failed,
            );
            return err;
        };
        const task = self.findTask(task_id) orelse unreachable;
        const run_input: TaskRunInput = switch (claimed_item.input.borrowed()) {
            .text => |text| .{ .text = text },
            .skill => |skill| .{ .skill = .{
                .skill_id = skill.skill_id,
                .catalog_revision = skill.catalog_revision,
                .argument_values = skill.argument_values,
            } },
        };
        _ = self.runTaskAtBinding(task_id, task.binding_epoch, run_input) catch |err| {
            self.finalizeScheduledTaskClaimRejected(
                id,
                planned_at_unix_seconds,
                source,
                scheduledFailure(err),
            );
            return err;
        };
        try self.finalizeScheduledTaskClaimSubmitted(
            id,
            planned_at_unix_seconds,
            source,
            task_id,
        );
        return task_id;
    }

    fn finalizeScheduledTaskClaimSubmitted(
        self: *Workbench,
        id: u64,
        planned_at_unix_seconds: u64,
        source: scheduled_tasks_impl.OccurrenceSource,
        task_id: u64,
    ) Error!void {
        var candidate = try self.scheduled_tasks.clone(self.allocator);
        var candidate_owned = true;
        defer if (candidate_owned) candidate.deinit();
        try candidate.finalizeClaimSubmitted(
            candidate.find(id) orelse return error.UnknownScheduledTask,
            planned_at_unix_seconds,
            source,
            task_id,
        );
        try self.commitScheduledTaskCandidate(&candidate);
        self.replaceScheduledTaskStore(&candidate);
        candidate_owned = false;
        self.bumpRevision();
    }

    fn finalizeScheduledTaskClaimRejected(
        self: *Workbench,
        id: u64,
        planned_at_unix_seconds: u64,
        source: scheduled_tasks_impl.OccurrenceSource,
        reason: scheduled_tasks_impl.FailureReason,
    ) void {
        var candidate = self.scheduled_tasks.clone(self.allocator) catch return;
        var candidate_owned = true;
        defer if (candidate_owned) candidate.deinit();
        candidate.finalizeClaimRejected(
            candidate.find(id) orelse return,
            planned_at_unix_seconds,
            source,
            reason,
        ) catch return;
        self.commitScheduledTaskCandidate(&candidate) catch return;
        self.replaceScheduledTaskStore(&candidate);
        candidate_owned = false;
        self.bumpRevision();
        _ = self.schedule_notifier.notify(.{
            .scheduled_task_id = id,
            .title = (self.scheduled_tasks.find(id) orelse unreachable).title,
            .kind = .needs_attention,
        });
    }

    fn rearmScheduledTaskTimerNoFail(self: *Workbench) void {
        self.schedule_timer.cancelCurrent();
        if (!self.schedule_background_available) return;
        if (self.schedule_persistence_health != .ready) return;
        if (!self.canCreateTask()) return;
        const item = self.scheduled_tasks.earliestDue() orelse return;
        const due = item.next_run_at_unix_seconds orelse return;
        if (self.schedule_timer.armAt(due)) return;
        var candidate = self.scheduled_tasks.clone(self.allocator) catch return;
        var candidate_owned = true;
        defer if (candidate_owned) candidate.deinit();
        candidate.markNeedsAttention(
            candidate.find(item.id) orelse return,
            .timer_unavailable,
        );
        self.commitScheduledTaskCandidate(&candidate) catch return;
        self.replaceScheduledTaskStore(&candidate);
        candidate_owned = false;
        self.bumpRevision();
    }

    fn reconcileScheduledTaskCompletionsNoFail(self: *Workbench) bool {
        if (self.schedule_persistence_health != .ready) return false;
        for (self.scheduled_tasks.items) |*entry| {
            const item = &(entry.* orelse continue);
            for (item.occurrences()) |occurrence| {
                if (occurrence.result != .submitted or
                    occurrence.task_id == 0 or occurrence.notification_sent)
                    continue;
                const task = self.findTask(occurrence.task_id) orelse continue;
                const terminal = lastTerminalFacts(task.runs) orelse continue;
                const notification_kind: ScheduleNotificationKind =
                    if (terminal.outcome == .completed) .completed else .failed;
                const item_id = item.id;
                var candidate = self.scheduled_tasks.clone(self.allocator) catch
                    return false;
                var candidate_owned = true;
                defer if (candidate_owned) candidate.deinit();
                candidate.finalizeOccurrenceTask(
                    candidate.find(item_id) orelse return false,
                    occurrence.planned_at_unix_seconds,
                    occurrence.source,
                    scheduledOccurrenceOutcome(terminal.outcome),
                ) catch return false;
                self.commitScheduledTaskCandidate(&candidate) catch return false;
                self.replaceScheduledTaskStore(&candidate);
                candidate_owned = false;
                const committed = self.scheduled_tasks.find(item_id) orelse
                    return true;
                _ = self.schedule_notifier.notify(.{
                    .scheduled_task_id = committed.id,
                    .task_id = occurrence.task_id,
                    .title = committed.title,
                    .kind = notification_kind,
                });
                return true;
            }
        }
        return false;
    }

    fn reconcileScheduledTaskBindingsNoFail(self: *Workbench) bool {
        if (self.schedule_persistence_health != .ready) return false;
        var candidate = self.scheduled_tasks.clone(self.allocator) catch
            return false;
        var candidate_owned = true;
        defer if (candidate_owned) candidate.deinit();
        const changed = self.reconcileScheduledTaskBindingsInStore(&candidate);
        if (!changed) return false;
        self.commitScheduledTaskCandidate(&candidate) catch return false;
        self.replaceScheduledTaskStore(&candidate);
        candidate_owned = false;
        self.rearmScheduledTaskTimerNoFail();
        return true;
    }

    fn reconcileScheduledTaskBindingsInStore(
        self: *Workbench,
        store: *scheduled_tasks_impl.Store,
    ) bool {
        var changed = false;
        for (store.items) |*entry| {
            const item = &(entry.* orelse continue);
            if (!item.enabled or item.health != .ready) continue;
            const reason: ?scheduled_tasks_impl.FailureReason = binding: {
                if (!self.canCreateTask() or
                    item.execution_generation != self.execution.generation or
                    item.execution_provider != scheduledProvider(self.execution.provider orelse
                        break :binding .execution_changed) or
                    !std.mem.eql(u8, item.execution_model, self.execution.model()))
                    break :binding .execution_changed;
                const workspace: ?*WorkspaceView = switch (item.target) {
                    .default => if (self.managed_workspaces != null)
                        null
                    else
                        break :binding .workspace_unavailable,
                    .explicit => |explicit| explicit_target: {
                        const candidate = self.findWorkspace(explicit.workspace_id) orelse
                            break :binding .workspace_unavailable;
                        if (candidate.origin != .user or !candidate.visible or
                            candidate.authorization != .available)
                            break :binding .workspace_unavailable;
                        if (candidate.epoch != explicit.workspace_epoch)
                            break :binding .workspace_changed;
                        break :explicit_target candidate;
                    },
                };
                switch (item.input) {
                    .text => {},
                    .skill => |skill| {
                        const explicit_workspace = workspace orelse
                            break :binding .catalog_changed;
                        const catalog = explicit_workspace.catalog orelse
                            break :binding .catalog_changed;
                        if (!std.mem.eql(
                            u8,
                            skill.catalog_revision,
                            catalog.revision,
                        ))
                            break :binding .catalog_changed;
                    },
                }
                break :binding null;
            };
            if (reason) |failure| {
                store.markNeedsAttention(item, failure);
                changed = true;
            }
        }
        return changed;
    }

    fn commitScheduledTaskCandidate(
        self: *Workbench,
        candidate: *const scheduled_tasks_impl.Store,
    ) Error!void {
        switch (self.schedule_persistence_health) {
            .ready => {},
            .outcome_unknown => return error.ScheduledTaskPersistenceOutcomeUnknown,
            else => return error.ScheduledTaskPersistenceUnavailable,
        }
        const output = try self.allocator.alloc(
            u8,
            scheduled_task_persistence.max_store_bytes,
        );
        defer self.allocator.free(output);
        const bytes = try scheduled_task_persistence.encode(output, candidate);
        switch (self.schedule_persistence.commit(bytes)) {
            .committed => {},
            .failed => {
                self.schedule_persistence_health = .write_failed;
                self.bumpRevision();
                return error.ScheduledTaskPersistenceFailed;
            },
            .outcome_unknown => {
                self.schedule_persistence_health = .outcome_unknown;
                self.bumpRevision();
                return error.ScheduledTaskPersistenceOutcomeUnknown;
            },
        }
    }

    fn replaceScheduledTaskStore(
        self: *Workbench,
        candidate: *scheduled_tasks_impl.Store,
    ) void {
        self.scheduled_tasks.deinit();
        self.scheduled_tasks = candidate.*;
        candidate.* = undefined;
    }

    fn executionQuiescent(self: *const Workbench) bool {
        for (self.tasks) |*entry| {
            const task = &(entry.* orelse continue);
            if (task.lifecycle != .closed or
                task.execution != null or
                task.session != null or
                task.closing_session != null or
                task.close_thread != null or
                task.worker_references.load(.acquire) != 0 or
                hasNonTerminalRun(task))
                return false;
        }
        return true;
    }

    fn releaseQuiescentTaskExecutions(self: *Workbench) void {
        for (self.tasks) |*entry| {
            const task = &(entry.* orelse continue);
            if (task.lifecycle != .closed or task.execution == null or
                task.session != null or task.closing_session != null or
                task.close_thread != null or
                task.worker_references.load(.acquire) != 0 or
                hasNonTerminalRun(task))
                continue;
            self.releaseTaskExecutionNoFail(task);
        }
    }

    /// Product projections may contain a credential that became known only
    /// after those facts were recorded. Every Task-owned secret release must
    /// pass through this function so the final live copy scrubs all retained
    /// projections before secure-zero makes the credential unavailable.
    fn releaseTaskExecutionNoFail(self: *Workbench, task: *TaskView) void {
        const execution = if (task.execution) |*value| value else return;
        const credential = execution.input().api_key;
        self.redactAllProductProjectionsNoFail(credential);
        for (task.runs) |*run_entry| {
            const run = &(run_entry.* orelse continue);
            run.redaction_secret = &.{};
        }
        execution.deinit();
        task.execution = null;
    }

    fn upsertWorkspace(
        self: *Workbench,
        input: TaskCreateInput,
    ) Error!*WorkspaceView {
        if (!std.fs.path.isAbsolute(input.workspace_root))
            return error.InvalidWorkspace;
        const canonical = std.Io.Dir.realPathFileAbsoluteAlloc(
            self.agent_runtime.io,
            input.workspace_root,
            self.allocator,
        ) catch return error.InvalidWorkspace;
        defer self.allocator.free(canonical);
        if (canonical.len > self.limits.max_workspace_bytes)
            return error.ProjectionCapacity;
        const workspace_stat = std.Io.Dir.cwd().statFile(
            self.agent_runtime.io,
            canonical,
            .{},
        ) catch return error.InvalidWorkspace;
        if (workspace_stat.kind != .directory) return error.InvalidWorkspace;
        if (self.managed_workspaces) |*store|
            if (store.containsCanonicalPath(canonical))
                return error.InvalidWorkspace;

        var canonical_temporary: ?[:0]u8 = null;
        defer if (canonical_temporary) |root| self.allocator.free(root);
        switch (input.trust) {
            .explicitly_trusted => {},
            .temporary => |root| {
                if (!std.fs.path.isAbsolute(root))
                    return error.InvalidWorkspace;
                const temporary = std.Io.Dir.realPathFileAbsoluteAlloc(
                    self.agent_runtime.io,
                    root,
                    self.allocator,
                ) catch return error.InvalidWorkspace;
                canonical_temporary = temporary;
                if (temporary.len > self.limits.max_workspace_bytes)
                    return error.ProjectionCapacity;
                const root_stat = std.Io.Dir.cwd().statFile(
                    self.agent_runtime.io,
                    temporary,
                    .{},
                ) catch return error.InvalidWorkspace;
                if (root_stat.kind != .directory) return error.InvalidWorkspace;
                if (!workspacePathWithin(temporary, canonical))
                    return error.WorkspaceNotTrusted;
            },
        }

        if (self.findWorkspaceByRoot(canonical)) |workspace| {
            if (workspace.authorization == .removing)
                return error.WorkspaceRemovalInProgress;
            const reauthorizing = !workspace.visible or
                workspace.authorization == .reauthorization_required;
            if (reauthorizing and workspace.epoch == std.math.maxInt(u64))
                return error.WorkspaceEpochExhausted;
            const next_temporary = if (canonical_temporary) |root|
                try self.copyBounded(root, self.limits.max_workspace_bytes)
            else
                null;
            if (workspace.trust == .temporary)
                self.freeTracked(workspace.trust.temporary);
            workspace.trust = if (next_temporary) |root|
                .{ .temporary = root }
            else
                .explicitly_trusted;
            workspace.authorization = .available;
            workspace.visible = true;
            if (reauthorizing) {
                self.markWorkspaceCatalogUnavailable(workspace);
                workspace.catalog_availability = .uninitialized;
                workspace.catalog_reschedule_pending =
                    workspace.catalog_job != null;
                workspace.epoch += 1;
            }
            self.redactWorkspaceProjectionNoFail(
                workspace,
                self.execution.credential(),
            );
            return workspace;
        }

        var slot: ?usize = null;
        for (self.workspaces, 0..) |*entry, index| {
            const workspace = &(entry.* orelse continue);
            if (workspace.origin != .user or workspace.visible or
                workspace.catalog_job != null or
                self.workspaceHasTasks(workspace.id))
                continue;
            self.deinitWorkspaceView(workspace);
            entry.* = null;
            slot = index;
            break;
        }
        if (slot == null and self.workspaceCount(.user) >= self.limits.max_workspaces)
            return error.WorkspaceCapacity;
        if (slot == null) slot = findEmpty(WorkspaceView, self.workspaces);
        const target = slot orelse return error.WorkspaceCapacity;
        if (self.next_workspace_id == 0) return error.WorkspaceIdentityExhausted;

        const owned_root = try self.copyBounded(canonical, self.limits.max_workspace_bytes);
        errdefer self.freeTracked(owned_root);
        const base_name = std.fs.path.basename(canonical);
        const projected_root = try self.copyProjected(
            canonical,
            self.limits.max_workspace_bytes,
            self.execution.credential(),
        );
        errdefer self.freeTracked(projected_root.value);
        const display_name = try self.copyProjected(
            if (base_name.len == 0) canonical else base_name,
            self.limits.max_workspace_bytes,
            self.execution.credential(),
        );
        errdefer self.freeTracked(display_name.value);
        const owned_temporary = if (canonical_temporary) |root|
            try self.copyBounded(root, self.limits.max_workspace_bytes)
        else
            null;
        errdefer if (owned_temporary) |root| self.freeTracked(root);

        const workspace_id = self.next_workspace_id;
        self.next_workspace_id +%= 1;
        self.workspaces[target] = .{
            .id = workspace_id,
            .canonical_root = owned_root,
            .projected_root_storage = projected_root.value,
            .projected_root_len = projected_root.value.len,
            .display_name_storage = display_name.value,
            .display_name_len = display_name.value.len,
            .projection_redacted = projected_root.redacted or display_name.redacted,
            .trust = if (owned_temporary) |root|
                .{ .temporary = root }
            else
                .explicitly_trusted,
            .recent_order = 0,
        };
        return &self.workspaces[target].?;
    }

    fn registerManagedWorkspace(
        self: *Workbench,
        canonical_root: []const u8,
    ) Error!*WorkspaceView {
        const store = if (self.managed_workspaces) |*value| value else return error.WorkspaceUnavailable;
        if (!std.fs.path.isAbsolute(canonical_root) or
            canonical_root.len > self.limits.max_workspace_bytes or
            !std.unicode.utf8ValidateSlice(canonical_root) or
            !store.containsCanonicalPath(canonical_root) or
            self.findWorkspaceByRoot(canonical_root) != null)
            return error.InvalidWorkspace;
        if (self.workspaceCount(.managed) >= self.limits.max_tasks)
            return error.WorkspaceCapacity;
        const target = findEmpty(WorkspaceView, self.workspaces) orelse
            return error.WorkspaceCapacity;
        if (self.next_workspace_id == 0) return error.WorkspaceIdentityExhausted;

        const owned_root = try self.copyBounded(
            canonical_root,
            self.limits.max_workspace_bytes,
        );
        errdefer self.freeTracked(owned_root);
        const projected_root = try self.copyProjected(
            canonical_root,
            self.limits.max_workspace_bytes,
            self.execution.credential(),
        );
        errdefer self.freeTracked(projected_root.value);
        const display_name = try self.copyProjected(
            "Managed workspace",
            self.limits.max_workspace_bytes,
            self.execution.credential(),
        );
        errdefer self.freeTracked(display_name.value);
        const owned_temporary = try self.copyBounded(
            canonical_root,
            self.limits.max_workspace_bytes,
        );
        errdefer self.freeTracked(owned_temporary);

        const workspace_id = self.next_workspace_id;
        self.next_workspace_id +%= 1;
        self.workspaces[target] = .{
            .id = workspace_id,
            .origin = .managed,
            .canonical_root = owned_root,
            .projected_root_storage = projected_root.value,
            .projected_root_len = projected_root.value.len,
            .display_name_storage = display_name.value,
            .display_name_len = display_name.value.len,
            .projection_redacted = projected_root.redacted or display_name.redacted,
            .trust = .{ .temporary = owned_temporary },
            .visible = false,
            .recent_order = 0,
        };
        return &self.workspaces[target].?;
    }

    fn releaseManagedWorkspaceNoFail(
        self: *Workbench,
        workspace_id: u64,
    ) void {
        for (self.workspaces) |*entry| {
            const workspace = &(entry.* orelse continue);
            if (workspace.id != workspace_id) continue;
            std.debug.assert(workspace.origin == .managed);
            std.debug.assert(!self.workspaceHasTasks(workspace_id));
            std.debug.assert(workspace.catalog_job == null);
            self.deinitWorkspaceView(workspace);
            entry.* = null;
            return;
        }
        unreachable;
    }

    fn takeWorkspaceRecentOrder(self: *Workbench) Error!u64 {
        if (self.next_workspace_recent_order == 0)
            return error.WorkspaceOrderExhausted;
        const recent_order = self.next_workspace_recent_order;
        self.next_workspace_recent_order +%= 1;
        return recent_order;
    }

    fn takeTaskRecentOrder(self: *Workbench) u64 {
        const recent_order = self.next_task_recent_order;
        if (self.next_task_recent_order != std.math.maxInt(u64))
            self.next_task_recent_order += 1;
        return recent_order;
    }

    fn touchTask(self: *Workbench, task: *TaskView) void {
        task.recent_order = self.takeTaskRecentOrder();
    }

    fn findWorkspace(self: *Workbench, workspace_id: u64) ?*WorkspaceView {
        if (workspace_id == 0) return null;
        for (self.workspaces) |*entry| if (entry.*) |*workspace|
            if (workspace.id == workspace_id) return workspace;
        return null;
    }

    fn findWorkspaceByRoot(self: *Workbench, canonical_root: []const u8) ?*WorkspaceView {
        for (self.workspaces) |*entry| if (entry.*) |*workspace|
            if (std.mem.eql(u8, workspace.canonical_root, canonical_root)) return workspace;
        return null;
    }

    fn workspaceCount(self: *const Workbench, origin: WorkspaceOrigin) usize {
        var count: usize = 0;
        for (self.workspaces) |entry| if (entry) |workspace|
            if (workspace.origin == origin) {
                count += 1;
            };
        return count;
    }

    fn scheduleCatalogQuery(
        self: *Workbench,
        workspace: *WorkspaceView,
    ) Error!void {
        if (workspace.origin != .user) return error.CatalogUnavailable;
        if (workspace.catalog_job != null) return error.CatalogLoading;
        const home = self.canonical_user_home orelse {
            self.markWorkspaceCatalogUnavailable(workspace);
            return error.CatalogUnavailable;
        };
        if (workspace.catalog_request_generation == std.math.maxInt(u64))
            return error.CatalogRequestGenerationExhausted;
        const generation = workspace.catalog_request_generation + 1;
        const epoch_token = try std.fmt.allocPrint(
            self.allocator,
            "{d}",
            .{workspace.epoch},
        );
        errdefer self.allocator.free(epoch_token);
        const root = try self.allocator.dupe(u8, workspace.canonical_root);
        errdefer self.allocator.free(root);
        const owned_home = try self.allocator.dupe(u8, home);
        errdefer self.allocator.free(owned_home);
        const job = try self.allocator.create(CatalogJob);
        errdefer self.allocator.destroy(job);
        job.* = .{
            .allocator = self.allocator,
            .runtime = self.agent_runtime,
            .notifier = self.change_notifier,
            .target = .{ .workspace = .{
                .id = workspace.id,
                .epoch = workspace.epoch,
                .request_generation = generation,
            } },
            .canonical_root = root,
            .canonical_user_home = owned_home,
            .epoch_token = epoch_token,
        };
        try self.executor.enqueue(.{
            .context = job,
            .execute_fn = executeCatalogJob,
            .cancel_fn = cancelCatalogJob,
        });
        workspace.catalog_request_generation = generation;
        workspace.catalog_job = job;
        workspace.catalog_reschedule_pending = false;
        workspace.catalog_availability = .loading;
    }

    fn scheduleSkillCatalogQuery(self: *Workbench) Error!void {
        if (self.skill_catalog_job != null) return error.CatalogLoading;
        const home = self.canonical_user_home orelse {
            self.markSkillCatalogUnavailable();
            return error.CatalogUnavailable;
        };
        if (self.skill_catalog_request_generation == std.math.maxInt(u64))
            return error.CatalogRequestGenerationExhausted;
        const generation = self.skill_catalog_request_generation + 1;
        const root = try self.allocator.dupe(u8, home);
        errdefer self.allocator.free(root);
        const owned_home = try self.allocator.dupe(u8, home);
        errdefer self.allocator.free(owned_home);
        const epoch_token = try self.allocator.dupe(u8, "");
        errdefer self.allocator.free(epoch_token);
        const job = try self.allocator.create(CatalogJob);
        errdefer self.allocator.destroy(job);
        job.* = .{
            .allocator = self.allocator,
            .runtime = self.agent_runtime,
            .notifier = self.change_notifier,
            .target = .{ .skills = generation },
            .canonical_root = root,
            .canonical_user_home = owned_home,
            .epoch_token = epoch_token,
        };
        try self.executor.enqueue(.{
            .context = job,
            .execute_fn = executeCatalogJob,
            .cancel_fn = cancelCatalogJob,
        });
        self.skill_catalog_request_generation = generation;
        self.skill_catalog_job = job;
        self.skill_catalog_availability = .loading;
    }

    fn commitCatalogJobsNoFail(self: *Workbench) bool {
        var changed = false;
        if (self.skill_catalog_job) |job| {
            const state = job.state.load(.acquire);
            if (state != .queued and state != .running) {
                self.skill_catalog_job = null;
                const expected_generation = switch (job.target) {
                    .skills => |generation| generation,
                    .workspace => unreachable,
                };
                const still_current =
                    self.skill_catalog_request_generation == expected_generation and
                    !self.shutting_down;
                switch (state) {
                    .completed => switch (job.outcome) {
                        .success => |*acquisition| {
                            if (still_current) {
                                const snapshot = CatalogSnapshot.init(
                                    self.allocator,
                                    acquisition.projection,
                                    self.limits,
                                    self.limits.max_projection_bytes -
                                        self.projection_bytes,
                                ) catch {
                                    acquisition.projection.deinit();
                                    self.agent_runtime.releaseSkillCatalog(
                                        acquisition.lease,
                                    ) catch
                                        @panic("Agent rejected the MetaWork Skill catalog lease");
                                    self.skill_catalog_availability = .unavailable;
                                    job.deinit();
                                    return true;
                                };
                                acquisition.projection.deinit();
                                const old_lease = self.skill_catalog_lease;
                                if (self.skill_catalog) |*old| {
                                    self.projection_bytes -= old.projected_bytes;
                                    old.deinit();
                                }
                                self.projection_bytes += snapshot.projected_bytes;
                                self.skill_catalog = snapshot;
                                self.skill_catalog_lease = acquisition.lease;
                                self.skill_catalog_availability = switch (snapshot.health) {
                                    .healthy => .ready,
                                    .degraded => .degraded,
                                };
                                if (old_lease) |lease|
                                    self.agent_runtime.releaseSkillCatalog(lease) catch
                                        @panic("Agent rejected the prior MetaWork Skill catalog lease");
                            } else {
                                acquisition.projection.deinit();
                                self.agent_runtime.releaseSkillCatalog(
                                    acquisition.lease,
                                ) catch
                                    @panic("Agent rejected a stale MetaWork Skill catalog lease");
                            }
                        },
                        .failure => {
                            if (still_current)
                                self.skill_catalog_availability = .unavailable;
                        },
                    },
                    .cancelled => {
                        if (still_current)
                            self.skill_catalog_availability = .unavailable;
                    },
                    .queued, .running => unreachable,
                }
                job.deinit();
                changed = true;
            }
        }
        for (self.workspaces) |*entry| {
            const workspace = &(entry.* orelse continue);
            const job = workspace.catalog_job orelse continue;
            const state = job.state.load(.acquire);
            if (state == .queued or state == .running) continue;
            workspace.catalog_job = null;
            const reschedule = workspace.catalog_reschedule_pending and
                workspace.visible and
                workspace.authorization == .available and
                !self.shutting_down;
            workspace.catalog_reschedule_pending = false;
            const identity = switch (job.target) {
                .workspace => |value| value,
                .skills => unreachable,
            };
            const current = self.findWorkspace(identity.id);
            const still_current = current == workspace and
                workspace.epoch == identity.epoch and
                workspace.catalog_request_generation == identity.request_generation and
                workspace.visible and workspace.authorization == .available and
                !self.shutting_down;
            switch (state) {
                .completed => switch (job.outcome) {
                    .success => |*acquisition| {
                        if (still_current) {
                            const snapshot = CatalogSnapshot.init(
                                self.allocator,
                                acquisition.projection,
                                self.limits,
                                self.limits.max_projection_bytes -
                                    self.projection_bytes,
                            ) catch {
                                acquisition.projection.deinit();
                                self.agent_runtime.releaseSkillCatalog(
                                    acquisition.lease,
                                ) catch
                                    @panic("Agent rejected a Workbench-owned catalog lease");
                                workspace.catalog_availability = .unavailable;
                                job.deinit();
                                changed = true;
                                continue;
                            };
                            acquisition.projection.deinit();
                            const old_lease = workspace.catalog_lease;
                            if (workspace.catalog) |*old| {
                                self.projection_bytes -= old.projected_bytes;
                                old.deinit();
                            }
                            self.projection_bytes += snapshot.projected_bytes;
                            workspace.catalog = snapshot;
                            workspace.catalog_lease = acquisition.lease;
                            workspace.catalog_availability = switch (snapshot.health) {
                                .healthy => .ready,
                                .degraded => .degraded,
                            };
                            if (old_lease) |lease|
                                self.agent_runtime.releaseSkillCatalog(lease) catch
                                    @panic("Agent rejected a Workbench-owned catalog lease");
                        } else {
                            acquisition.projection.deinit();
                            self.agent_runtime.releaseSkillCatalog(
                                acquisition.lease,
                            ) catch
                                @panic("Agent rejected a stale Workbench catalog lease");
                            if (current == workspace)
                                self.markWorkspaceCatalogUnavailable(workspace);
                        }
                    },
                    .failure => {
                        if (still_current)
                            workspace.catalog_availability = .unavailable;
                    },
                },
                .cancelled => if (current == workspace)
                    self.markWorkspaceCatalogUnavailable(workspace),
                .queued, .running => unreachable,
            }
            job.deinit();
            if (reschedule)
                self.scheduleCatalogQuery(workspace) catch
                    self.markWorkspaceCatalogUnavailable(workspace);
            changed = true;
        }
        return changed;
    }

    fn markSkillCatalogUnavailable(self: *Workbench) void {
        if (self.skill_catalog) |*snapshot| {
            self.projection_bytes -= snapshot.projected_bytes;
            snapshot.deinit();
            self.skill_catalog = null;
        }
        if (self.skill_catalog_lease) |lease| {
            self.agent_runtime.releaseSkillCatalog(lease) catch
                @panic("Agent rejected the MetaWork Skill catalog lease");
            self.skill_catalog_lease = null;
        }
        self.skill_catalog_availability = .unavailable;
    }

    fn markWorkspaceCatalogUnavailable(
        self: *Workbench,
        workspace: *WorkspaceView,
    ) void {
        if (workspace.catalog) |*snapshot| {
            self.projection_bytes -= snapshot.projected_bytes;
            snapshot.deinit();
            workspace.catalog = null;
        }
        if (workspace.catalog_lease) |lease| {
            self.agent_runtime.releaseSkillCatalog(lease) catch
                @panic("Agent rejected a Workbench-owned catalog lease");
            workspace.catalog_lease = null;
        }
        workspace.catalog_availability = .unavailable;
    }

    fn workspaceHasTasks(self: *const Workbench, workspace_id: u64) bool {
        for (self.tasks) |entry| if (entry) |task|
            if (task.workspace_id == workspace_id) return true;
        return false;
    }

    /// Completes the second phase of Workspace removal only after every Task
    /// Session in that Workspace has reached a stable terminal owner state.
    /// A close failure restores admission so the user can retry explicitly.
    fn finalizeWorkspaceRemovalsNoFail(self: *Workbench) bool {
        var changed = false;
        for (self.workspaces) |*entry| {
            const workspace = &(entry.* orelse continue);
            if (!workspace.visible or workspace.authorization != .removing) continue;
            var pending = false;
            var failed = false;
            for (self.tasks) |*task_entry| {
                const task = &(task_entry.* orelse continue);
                if (task.workspace_id != workspace.id) continue;
                if (task.close_failed) {
                    failed = true;
                    break;
                }
                if (task.session != null or task.closing_session != null or
                    task.close_thread != null or
                    task.worker_references.load(.acquire) != 0 or
                    hasNonTerminalRun(task))
                {
                    pending = true;
                }
            }
            if (failed) {
                workspace.authorization = .available;
                workspace.last_removal_failure = .task_close_failed;
                changed = true;
                continue;
            }
            if (pending) continue;
            workspace.authorization = .reauthorization_required;
            workspace.visible = false;
            if (self.selected_workspace_id == workspace.id)
                self.selected_workspace_id = 0;
            changed = true;
        }
        return changed;
    }

    fn workspaceSignals(self: *const Workbench, workspace_id: u64) WorkspaceSignals {
        var signals: WorkspaceSignals = .{};
        for (self.tasks) |*entry| {
            const task = &(entry.* orelse continue);
            if (task.workspace_id != workspace_id or task.archived) continue;
            if (currentRunPhase(task)) |phase| {
                switch (phase) {
                    .waiting_ui => signals.attention +|= 1,
                    .queued, .running, .stopping => signals.running +|= 1,
                    else => unreachable,
                }
                continue;
            }
            if (lastTerminalFacts(task.runs)) |terminal| switch (terminal.outcome) {
                .failed, .interrupted, .dependency_contract_failure => signals.failed_or_interrupted +|= 1,
                .completed, .stopped, .cancelled => {},
            };
        }
        return signals;
    }

    fn deinitWorkspaceView(self: *Workbench, workspace: *WorkspaceView) void {
        std.debug.assert(workspace.catalog_job == null);
        std.debug.assert(!workspace.catalog_reschedule_pending);
        if (workspace.catalog) |*snapshot| {
            self.projection_bytes -= snapshot.projected_bytes;
            snapshot.deinit();
        }
        if (workspace.catalog_lease) |lease|
            self.agent_runtime.releaseSkillCatalog(lease) catch
                @panic("Agent rejected a Workbench-owned catalog lease");
        self.freeTracked(workspace.canonical_root);
        self.freeTracked(workspace.projected_root_storage);
        self.freeTracked(workspace.display_name_storage);
        if (workspace.trust == .temporary)
            self.freeTracked(workspace.trust.temporary);
        workspace.* = undefined;
    }

    fn redactWorkspaceProjectionsNoFail(
        self: *Workbench,
        credential: []const u8,
    ) void {
        if (credential.len == 0) return;
        for (self.workspaces) |*entry| {
            const workspace = &(entry.* orelse continue);
            self.redactWorkspaceProjectionNoFail(workspace, credential);
        }
    }

    /// A credential may become known after older product facts were stored,
    /// or may be about to leave the set scanned by snapshot serialization.
    /// Permanently scrub every Renderer-facing projection before either edge.
    fn redactAllProductProjectionsNoFail(
        self: *Workbench,
        credential: []const u8,
    ) void {
        if (credential.len == 0) return;
        self.redactWorkspaceProjectionsNoFail(credential);
        self.redactCatalogProjectionsNoFail(credential);
        for (self.scheduled_tasks.items) |*entry| {
            const item = &(entry.* orelse continue);
            self.redactScheduledTaskNoFail(item, credential);
        }
        for (self.tasks) |*entry| {
            const task = &(entry.* orelse continue);
            self.redactTaskProjectionNoFail(task, credential);
        }
    }

    fn redactScheduledTaskNoFail(
        _: *Workbench,
        item: *scheduled_tasks_impl.Item,
        credential: []const u8,
    ) void {
        if (credential.len == 0) return;
        item.title_redacted =
            redactFixedWidthNoFail(item.title, credential) or
            item.title_redacted;
        _ = redactFixedWidthNoFail(item.execution_model, credential);
        switch (item.input) {
            .text => |*text| {
                text.redacted =
                    redactFixedWidthNoFail(text.value, credential) or
                    text.redacted;
            },
            .skill => |*skill| {
                var redacted =
                    redactFixedWidthNoFail(skill.skill_id, credential) or
                    redactFixedWidthNoFail(
                        skill.catalog_revision,
                        credential,
                    );
                for (skill.argument_values) |value|
                    redacted =
                        redactFixedWidthNoFail(value, credential) or redacted;
                skill.redacted = skill.redacted or redacted;
            },
        }
    }

    fn redactCatalogProjectionsNoFail(
        self: *Workbench,
        credential: []const u8,
    ) void {
        if (self.skill_catalog) |*snapshot| {
            if (snapshot.identityContainsCredential(credential)) {
                self.markSkillCatalogUnavailable();
            } else {
                snapshot.redactPresentationNoFail(credential);
            }
        }
        for (self.workspaces) |*entry| {
            const workspace = &(entry.* orelse continue);
            const snapshot = if (workspace.catalog) |*value| value else continue;
            if (snapshot.identityContainsCredential(credential)) {
                self.markWorkspaceCatalogUnavailable(workspace);
            } else {
                snapshot.redactPresentationNoFail(credential);
            }
        }
        for (self.tasks) |*entry| {
            const task = &(entry.* orelse continue);
            const snapshot = if (task.pinned_catalog) |*value| value else continue;
            if (snapshot.identityContainsCredential(credential)) {
                self.projection_bytes -= snapshot.projected_bytes;
                snapshot.deinit();
                task.pinned_catalog = null;
            } else {
                snapshot.redactPresentationNoFail(credential);
            }
        }
    }

    fn redactTaskProjectionNoFail(
        _: *Workbench,
        task: *TaskView,
        credential: []const u8,
    ) void {
        if (credential.len == 0) return;
        task.title_redacted = redactFixedWidthNoFail(task.title, credential) or
            task.title_redacted;
        _ = redactFixedWidthNoFail(task.workspace_root, credential);
        _ = redactFixedWidthNoFail(task.binding_account_id, credential);
        _ = redactFixedWidthNoFail(task.binding_profile_id, credential);
        _ = redactFixedWidthNoFail(task.binding_account_name, credential);
        _ = redactFixedWidthNoFail(task.binding_api_key_id, credential);
        _ = redactFixedWidthNoFail(task.binding_api_key_name, credential);
        _ = redactFixedWidthNoFail(task.binding_api_key_suffix, credential);
        _ = redactFixedWidthNoFail(task.binding_model_id, credential);
        _ = redactFixedWidthNoFail(task.binding_model_display_name, credential);
        for (task.runs) |*run_entry| {
            const run = &(run_entry.* orelse continue);
            switch (run.input) {
                .text => |*text| {
                    text.redacted = redactFixedWidthNoFail(
                        text.value,
                        credential,
                    ) or text.redacted;
                },
                .skill => |*skill| {
                    var redacted = redactFixedWidthNoFail(
                        skill.skill_id,
                        credential,
                    );
                    redacted = redactFixedWidthNoFail(
                        skill.catalog_revision,
                        credential,
                    ) or redacted;
                    redacted = redactFixedWidthNoFail(
                        skill.invocation_name,
                        credential,
                    ) or redacted;
                    redacted = redactFixedWidthNoFail(
                        skill.display_name,
                        credential,
                    ) or redacted;
                    for (skill.argument_values) |value|
                        redacted = redactFixedWidthNoFail(
                            value,
                            credential,
                        ) or redacted;
                    skill.redacted = redacted or skill.redacted;
                },
            }
            run.assistant_redacted = redactFixedWidthNoFail(
                run.assistant.list.items,
                credential,
            ) or run.assistant_redacted;
            _ = redactFixedWidthNoFail(run.status_text, credential);
            for (run.tools) |*tool_entry| {
                const tool = &(tool_entry.* orelse continue);
                const id_redacted = redactFixedWidthNoFail(tool.id, credential);
                const name_redacted = redactFixedWidthNoFail(tool.name, credential);
                const input_redacted = redactFixedWidthNoFail(tool.input, credential);
                const progress_redacted = redactFixedWidthNoFail(tool.progress, credential);
                const content_redacted = redactFixedWidthNoFail(tool.content, credential);
                tool.redacted = id_redacted or name_redacted or input_redacted or
                    progress_redacted or content_redacted or tool.redacted;
            }
        }
        for (task.ui_history) |*record_entry| {
            const record = &(record_entry.* orelse continue);
            record.redacted = redactFixedWidthNoFail(
                record.detail[0..record.detail_len],
                credential,
            ) or record.redacted;
        }
    }

    fn redactWorkspaceProjectionNoFail(
        _: *Workbench,
        workspace: *WorkspaceView,
        credential: []const u8,
    ) void {
        if (credential.len == 0) return;
        const root_redacted = redactWorkspaceBytesNoFail(
            workspace.projected_root_storage,
            &workspace.projected_root_len,
            credential,
        );
        const name_redacted = redactWorkspaceBytesNoFail(
            workspace.display_name_storage,
            &workspace.display_name_len,
            credential,
        );
        workspace.projection_redacted = root_redacted or name_redacted or
            workspace.projection_redacted;
    }

    fn findTask(self: *Workbench, task_id: u64) ?*TaskView {
        if (task_id == 0) return null;
        for (self.tasks) |*entry| if (entry.*) |*task|
            if (task.id == task_id) return task;
        return null;
    }

    fn findTaskByRouteId(self: *Workbench, route_id: u64) ?*TaskView {
        if (route_id == 0) return null;
        for (self.tasks) |*entry| if (entry.*) |*task|
            if (task.route_id == route_id) return task;
        return null;
    }

    fn findTaskIndex(self: *Workbench, task_id: u64) ?usize {
        if (task_id == 0) return null;
        for (self.tasks, 0..) |entry, index|
            if (entry) |task| if (task.id == task_id) return index;
        return null;
    }

    fn copyRunInputRecord(
        self: *Workbench,
        task: *const TaskView,
        input: TaskRunInput,
        credential: []const u8,
    ) Error!RunInputRecord {
        return switch (input) {
            .text => |text| {
                if (text.len > self.limits.max_user_message_bytes)
                    return error.ProjectionCapacity;
                const projected = try self.copyProjected(
                    text,
                    self.limits.max_user_message_bytes,
                    credential,
                );
                return .{ .text = .{
                    .value = projected.value,
                    .redacted = projected.redacted,
                } };
            },
            .skill => |skill_input| {
                const pinned = task.pinned_catalog orelse
                    return error.CatalogUnavailable;
                if (!std.mem.eql(
                    u8,
                    skill_input.catalog_revision,
                    pinned.revision,
                ))
                    return error.StaleCatalog;
                const skill = pinned.findSkill(skill_input.skill_id) orelse
                    return error.SkillNotFound;
                const skill_id = try self.copyBounded(
                    skill.skill_id,
                    self.limits.max_catalog_projection_bytes,
                );
                errdefer self.freeTracked(skill_id);
                const revision = try self.copyBounded(
                    pinned.revision,
                    self.limits.max_catalog_projection_bytes,
                );
                errdefer self.freeTracked(revision);
                const invocation = try self.copyProjected(
                    skill.invocation_name,
                    self.limits.max_catalog_projection_bytes,
                    credential,
                );
                errdefer self.freeTracked(invocation.value);
                const display = try self.copyProjected(
                    skill.display_name,
                    self.limits.max_catalog_projection_bytes,
                    credential,
                );
                errdefer self.freeTracked(display.value);
                const values = try self.allocator.alloc(
                    []u8,
                    skill_input.argument_values.len,
                );
                errdefer self.allocator.free(values);
                var initialized: usize = 0;
                var redacted = invocation.redacted or display.redacted;
                errdefer for (values[0..initialized]) |value|
                    self.freeTracked(value);
                for (skill_input.argument_values, values) |value, *target| {
                    const projected = try self.copyProjected(
                        value,
                        self.limits.max_user_message_bytes,
                        credential,
                    );
                    target.* = projected.value;
                    initialized += 1;
                    redacted = redacted or projected.redacted;
                }
                return .{ .skill = .{
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

    fn deinitRunInputRecord(
        self: *Workbench,
        input: *RunInputRecord,
    ) void {
        switch (input.*) {
            .text => |text| self.freeTracked(text.value),
            .skill => |skill| {
                self.freeTracked(skill.skill_id);
                self.freeTracked(skill.catalog_revision);
                self.freeTracked(skill.invocation_name);
                self.freeTracked(skill.display_name);
                for (skill.argument_values) |value| self.freeTracked(value);
                self.allocator.free(skill.argument_values);
            },
        }
        input.* = undefined;
    }

    fn reserveRunRecord(
        self: *Workbench,
        task: *TaskView,
        input: TaskRunInput,
    ) Error!usize {
        const execution = try taskExecutionInput(task);
        const slot = findEmpty(RunRecord, task.runs) orelse return error.RunCapacity;
        if (task.next_run_generation == std.math.maxInt(u64)) return error.RunGenerationExhausted;
        var input_record = try self.copyRunInputRecord(
            task,
            input,
            execution.api_key,
        );
        errdefer self.deinitRunInputRecord(&input_record);
        const status_text = try self.copyBounded("Queued", self.limits.max_tool_field_bytes);
        errdefer self.freeTracked(status_text);
        const tools = try self.allocator.alloc(?ToolView, self.limits.max_tools_per_run);
        errdefer self.allocator.free(tools);
        @memset(tools, null);
        const terminal_diagnostic = try self.allocTrackedCapacity(self.limits.max_terminal_diagnostic_bytes);
        errdefer self.freeTracked(terminal_diagnostic);
        task.next_run_generation += 1;
        task.runs[slot] = .{
            .id = 0,
            .generation = task.next_run_generation,
            .execution_generation = task.execution_generation,
            .execution_provider = task.execution_provider,
            .execution_model = task.execution_model,
            .input = input_record,
            .tools = tools,
            .status_text = status_text,
            .terminal_diagnostic = terminal_diagnostic,
            .redaction_secret = execution.api_key,
            .workbench = undefined,
            .task = undefined,
            .session = undefined,
        };
        return slot;
    }

    fn discardRunRecord(self: *Workbench, task: *TaskView, slot: usize) void {
        const run = &(task.runs[slot] orelse return);
        self.deinitRunRecord(run);
        task.runs[slot] = null;
    }

    fn deinitRunRecord(self: *Workbench, run: *RunRecord) void {
        for (run.tools) |*tool_entry| {
            const tool = &(tool_entry.* orelse continue);
            self.freeTracked(tool.id);
            self.freeTracked(tool.name);
            self.freeTracked(tool.input);
            self.freeTracked(tool.progress);
            self.freeTracked(tool.content);
        }
        self.allocator.free(run.tools);
        self.deinitRunInputRecord(&run.input);
        self.freeTrackedText(&run.assistant);
        self.freeTracked(run.status_text);
        self.freeTracked(run.terminal_diagnostic);
        run.* = undefined;
    }

    fn deinitTaskView(self: *Workbench, task: *TaskView) void {
        std.debug.assert(task.worker_references.load(.acquire) == 0);
        self.releaseTaskExecutionNoFail(task);
        for (task.runs) |*run_entry| {
            const run = &(run_entry.* orelse continue);
            self.deinitRunRecord(run);
        }
        self.allocator.free(task.runs);
        self.allocator.free(task.ui_history);
        self.freeTracked(task.execution_model);
        self.freeTracked(task.binding_account_id);
        self.freeTracked(task.binding_profile_id);
        self.freeTracked(task.binding_account_name);
        self.freeTracked(task.binding_api_key_id);
        self.freeTracked(task.binding_api_key_name);
        self.freeTracked(task.binding_api_key_suffix);
        self.freeTracked(task.binding_model_id);
        self.freeTracked(task.binding_model_display_name);
        self.freeTracked(task.workspace_root);
        if (task.pinned_catalog) |*snapshot| {
            self.projection_bytes -= snapshot.projected_bytes;
            snapshot.deinit();
        }
        self.freeTracked(task.title);
        task.* = undefined;
    }

    fn copyBounded(self: *Workbench, value: []const u8, max: usize) Error![]u8 {
        if (value.len > max or value.len > self.limits.max_projection_bytes - self.projection_bytes)
            return error.ProjectionCapacity;
        const result = try self.allocator.dupe(u8, value);
        self.projection_bytes += result.len;
        return result;
    }

    fn allocTrackedCapacity(self: *Workbench, capacity: usize) Error![]u8 {
        if (capacity > self.limits.max_projection_bytes - self.projection_bytes)
            return error.ProjectionCapacity;
        const result = try self.allocator.alloc(u8, capacity);
        self.projection_bytes += result.len;
        return result;
    }

    fn appendTrackedText(self: *Workbench, target: *TrackedText, suffix: []const u8, max: usize) Error!void {
        if (suffix.len > max - target.list.items.len) return error.ProjectionCapacity;
        const needed = target.list.items.len + suffix.len;
        if (needed > target.list.capacity) {
            const growth = @max(@as(usize, 1024), target.list.capacity / 2);
            const desired = @min(max, @max(needed, target.list.capacity + growth));
            const added_capacity = desired - target.list.capacity;
            if (added_capacity > self.limits.max_projection_bytes - self.projection_bytes)
                return error.ProjectionCapacity;
            try target.list.ensureTotalCapacityPrecise(self.allocator, desired);
            self.projection_bytes += added_capacity;
        }
        target.list.appendSliceAssumeCapacity(suffix);
    }

    const ProjectedCopy = struct {
        value: []u8,
        truncated: bool,
        redacted: bool,
    };

    fn copyProjected(
        self: *Workbench,
        value: []const u8,
        max: usize,
        credential: []const u8,
    ) Error!ProjectedCopy {
        const capacity = @min(value.len, max);
        const scratch = try self.allocator.alloc(u8, capacity);
        defer self.allocator.free(scratch);
        const result = sanitizeInto(
            scratch,
            value,
            credential,
        );
        return .{
            .value = try self.copyBounded(scratch[0..result.len], max),
            .truncated = result.truncated,
            .redacted = result.redacted,
        };
    }

    fn replaceTrackedProjected(
        self: *Workbench,
        target: *[]u8,
        value: []const u8,
        max: usize,
        credential: []const u8,
    ) Error!SanitizeResult {
        const capacity = @min(value.len, max);
        const scratch = try self.allocator.alloc(u8, capacity);
        defer self.allocator.free(scratch);
        const result = sanitizeInto(
            scratch,
            value,
            credential,
        );
        try self.replaceTracked(target, scratch[0..result.len], max);
        return result;
    }

    fn redactTrackedText(
        _: *Workbench,
        target: *TrackedText,
        credential: []const u8,
    ) bool {
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

    fn projectedJsonValue(self: *Workbench, writer: *std.Io.Writer, value: []const u8) Error!void {
        return self.projectedJsonValueWithKnownCredentials(writer, value);
    }

    fn containsKnownCredential(self: *const Workbench, value: []const u8) bool {
        const current = self.execution.credential();
        if (containsKnownSecret(value, current)) return true;
        for (self.tasks) |*entry| {
            const task = &(entry.* orelse continue);
            if (task.execution) |*execution|
                if (containsKnownSecret(value, execution.input().api_key)) return true;
        }
        return false;
    }

    fn matchedKnownCredentialLen(
        self: *const Workbench,
        value: []const u8,
    ) usize {
        var longest: usize = 0;
        const current = self.execution.credential();
        if (current.len != 0 and std.mem.startsWith(u8, value, current))
            longest = current.len;
        for (self.tasks) |*entry| {
            const task = &(entry.* orelse continue);
            if (task.execution) |*execution| {
                const credential = execution.input().api_key;
                if (credential.len > longest and std.mem.startsWith(u8, value, credential))
                    longest = credential.len;
            }
        }
        return longest;
    }

    fn projectedJsonValueWithKnownCredentials(
        self: *Workbench,
        writer: *std.Io.Writer,
        value: []const u8,
    ) Error!void {
        const hex = "0123456789abcdef";
        writer.writeByte('"') catch return error.SnapshotTooLarge;
        var index: usize = 0;
        while (index < value.len) {
            if (self.knownCredentialEndAtCodepoint(value, index)) |redaction_end| {
                _ = writer.splatByte('*', @min(redaction_end - index, 3)) catch
                    return error.SnapshotTooLarge;
                index = redaction_end;
                continue;
            }
            const byte = value[index];
            switch (byte) {
                '"' => writer.writeAll("\\\"") catch return error.SnapshotTooLarge,
                '\\' => writer.writeAll("\\\\") catch return error.SnapshotTooLarge,
                0x08 => writer.writeAll("\\b") catch return error.SnapshotTooLarge,
                0x0c => writer.writeAll("\\f") catch return error.SnapshotTooLarge,
                '\n' => writer.writeAll("\\n") catch return error.SnapshotTooLarge,
                '\r' => writer.writeAll("\\r") catch return error.SnapshotTooLarge,
                '\t' => writer.writeAll("\\t") catch return error.SnapshotTooLarge,
                0x00...0x07, 0x0b, 0x0e...0x1f => {
                    writer.writeAll("\\u00") catch return error.SnapshotTooLarge;
                    writer.writeByte(hex[byte >> 4]) catch return error.SnapshotTooLarge;
                    writer.writeByte(hex[byte & 0x0f]) catch return error.SnapshotTooLarge;
                },
                else => writer.writeByte(byte) catch return error.SnapshotTooLarge,
            }
            index += 1;
        }
        writer.writeByte('"') catch return error.SnapshotTooLarge;
    }

    fn knownCredentialEndAtCodepoint(
        self: *const Workbench,
        value: []const u8,
        codepoint_start: usize,
    ) ?usize {
        const codepoint_len = utf8CodepointLen(value, codepoint_start);
        var match_end: usize = 0;
        for (0..codepoint_len) |offset| {
            const credential_len = self.matchedKnownCredentialLen(
                value[codepoint_start + offset ..],
            );
            if (credential_len != 0)
                match_end = @max(
                    match_end,
                    codepoint_start + offset + credential_len,
                );
        }
        if (match_end == 0) return null;
        return utf8RedactionBounds(
            value,
            codepoint_start,
            match_end - codepoint_start,
        ).end;
    }

    fn projectedJsonValueWithCredential(
        _: *Workbench,
        writer: *std.Io.Writer,
        value: []const u8,
        credential: []const u8,
    ) Error!void {
        const hex = "0123456789abcdef";
        writer.writeByte('"') catch return error.SnapshotTooLarge;
        var index: usize = 0;
        while (index < value.len) {
            if (credentialEndAtCodepoint(value, index, credential)) |redaction_end| {
                _ = writer.splatByte('*', @min(redaction_end - index, 3)) catch
                    return error.SnapshotTooLarge;
                index = redaction_end;
                continue;
            }
            const byte = value[index];
            switch (byte) {
                '"' => writer.writeAll("\\\"") catch return error.SnapshotTooLarge,
                '\\' => writer.writeAll("\\\\") catch return error.SnapshotTooLarge,
                0x08 => writer.writeAll("\\b") catch return error.SnapshotTooLarge,
                0x0c => writer.writeAll("\\f") catch return error.SnapshotTooLarge,
                '\n' => writer.writeAll("\\n") catch return error.SnapshotTooLarge,
                '\r' => writer.writeAll("\\r") catch return error.SnapshotTooLarge,
                '\t' => writer.writeAll("\\t") catch return error.SnapshotTooLarge,
                0x00...0x07, 0x0b, 0x0e...0x1f => {
                    writer.writeAll("\\u00") catch return error.SnapshotTooLarge;
                    writer.writeByte(hex[byte >> 4]) catch return error.SnapshotTooLarge;
                    writer.writeByte(hex[byte & 0x0f]) catch return error.SnapshotTooLarge;
                },
                else => writer.writeByte(byte) catch return error.SnapshotTooLarge,
            }
            index += 1;
        }
        writer.writeByte('"') catch return error.SnapshotTooLarge;
    }

    fn writePendingUiProjection(
        self: *Workbench,
        writer: *std.Io.Writer,
        request_id: u64,
        run_id: u64,
        order: u64,
        request: lifecycle.UiRequest,
    ) Error!void {
        writer.print("{{\"requestId\":\"{d}\",\"runId\":\"{d}\",\"order\":\"{d}\",\"redacted\":{},", .{
            request_id,
            run_id,
            order,
            self.requestContainsKnownCredential(request),
        }) catch return error.SnapshotTooLarge;
        switch (request) {
            .ask_question => |questions| {
                writer.writeAll("\"kind\":\"ask_question\",\"questions\":[") catch return error.SnapshotTooLarge;
                for (questions, 0..) |question, question_index| {
                    if (question_index != 0) writer.writeByte(',') catch return error.SnapshotTooLarge;
                    writer.writeAll("{\"question\":") catch return error.SnapshotTooLarge;
                    try self.projectedJsonValueWithKnownCredentials(writer, question.question);
                    writer.writeAll(",\"header\":") catch return error.SnapshotTooLarge;
                    try self.projectedJsonValueWithKnownCredentials(writer, question.header);
                    writer.print(",\"multi\":{},\"options\":[", .{question.multi}) catch return error.SnapshotTooLarge;
                    for (question.options, 0..) |option, option_index| {
                        if (option_index != 0) writer.writeByte(',') catch return error.SnapshotTooLarge;
                        writer.writeAll("{\"label\":") catch return error.SnapshotTooLarge;
                        try self.projectedJsonValueWithKnownCredentials(writer, option.label);
                        writer.writeAll(",\"description\":") catch return error.SnapshotTooLarge;
                        try self.projectedJsonValueWithKnownCredentials(writer, option.description);
                        writer.writeAll(",\"preview\":") catch return error.SnapshotTooLarge;
                        try self.projectedJsonValueWithKnownCredentials(writer, option.preview);
                        writer.writeByte('}') catch return error.SnapshotTooLarge;
                    }
                    writer.writeAll("]}") catch return error.SnapshotTooLarge;
                }
                writer.writeByte(']') catch return error.SnapshotTooLarge;
            },
            .permission => |permission| {
                writer.writeAll("\"kind\":\"permission\",\"tool\":") catch return error.SnapshotTooLarge;
                try self.projectedJsonValueWithKnownCredentials(writer, permission.tool);
                writer.writeAll(",\"args\":") catch return error.SnapshotTooLarge;
                try self.projectedJsonValueWithKnownCredentials(writer, permission.args);
            },
        }
        writer.writeByte('}') catch return error.SnapshotTooLarge;
    }

    fn requestContainsKnownCredential(self: *const Workbench, request: lifecycle.UiRequest) bool {
        return switch (request) {
            .ask_question => |questions| questions_block: {
                for (questions) |question| {
                    if (self.containsKnownCredential(question.question) or self.containsKnownCredential(question.header))
                        break :questions_block true;
                    for (question.options) |option|
                        if (self.containsKnownCredential(option.label) or
                            self.containsKnownCredential(option.description) or
                            self.containsKnownCredential(option.preview))
                            break :questions_block true;
                }
                break :questions_block false;
            },
            .permission => |permission| self.containsKnownCredential(permission.tool) or
                self.containsKnownCredential(permission.args),
        };
    }

    fn containsKnownSecret(value: []const u8, credential: []const u8) bool {
        return credential.len != 0 and
            std.mem.indexOf(u8, value, credential) != null;
    }

    fn writeRun(self: *Workbench, writer: *std.Io.Writer, run: *RunRecord) Error!void {
        const terminal = productTerminalFacts(run);
        writer.print("{{\"id\":\"{d}\",\"phase\":\"{s}\",\"input\":", .{
            run.id,
            @tagName(runPhase(run)),
        }) catch return error.SnapshotTooLarge;
        switch (run.input) {
            .text => |text| {
                writer.writeAll("{\"kind\":\"text\",\"text\":") catch
                    return error.SnapshotTooLarge;
                try self.projectedJsonValueWithKnownCredentials(
                    writer,
                    text.value,
                );
                writer.print(",\"redacted\":{}}}", .{text.redacted}) catch
                    return error.SnapshotTooLarge;
            },
            .skill => |skill| {
                writer.writeAll("{\"kind\":\"skill\",\"skillId\":") catch
                    return error.SnapshotTooLarge;
                try self.projectedJsonValueWithKnownCredentials(
                    writer,
                    skill.skill_id,
                );
                writer.writeAll(",\"catalogRevision\":") catch
                    return error.SnapshotTooLarge;
                try self.projectedJsonValueWithKnownCredentials(
                    writer,
                    skill.catalog_revision,
                );
                writer.writeAll(",\"invocationName\":") catch
                    return error.SnapshotTooLarge;
                try self.projectedJsonValueWithKnownCredentials(
                    writer,
                    skill.invocation_name,
                );
                writer.writeAll(",\"displayName\":") catch
                    return error.SnapshotTooLarge;
                try self.projectedJsonValueWithKnownCredentials(
                    writer,
                    skill.display_name,
                );
                writer.writeAll(",\"argumentValues\":[") catch
                    return error.SnapshotTooLarge;
                for (skill.argument_values, 0..) |value, index| {
                    if (index != 0) writer.writeByte(',') catch
                        return error.SnapshotTooLarge;
                    try self.projectedJsonValueWithKnownCredentials(
                        writer,
                        value,
                    );
                }
                writer.print("],\"redacted\":{}}}", .{skill.redacted}) catch
                    return error.SnapshotTooLarge;
            },
        }
        writer.writeAll(",\"assistant\":") catch return error.SnapshotTooLarge;
        try self.projectedJsonValueWithKnownCredentials(
            writer,
            run.assistant.list.items[0..run.assistant.committed_len],
        );
        writer.print(",\"assistantRedacted\":{},\"status\":", .{run.assistant_redacted}) catch return error.SnapshotTooLarge;
        try self.projectedJsonValueWithKnownCredentials(writer, run.status_text);
        writer.writeAll(",\"outcome\":") catch return error.SnapshotTooLarge;
        if (terminal) |value| jsonValue(writer, @tagName(value.outcome)) catch return error.SnapshotTooLarge else writer.writeAll("null") catch return error.SnapshotTooLarge;
        writer.writeAll(",\"cause\":") catch return error.SnapshotTooLarge;
        if (terminal) |value| {
            if (value.cause) |cause| jsonValue(writer, @tagName(cause)) catch return error.SnapshotTooLarge else writer.writeAll("null") catch return error.SnapshotTooLarge;
        } else writer.writeAll("null") catch return error.SnapshotTooLarge;
        writer.print(",\"usage\":{{\"input\":\"{d}\",\"output\":\"{d}\",\"cacheRead\":\"{d}\",\"cacheCreation\":\"{d}\"}},\"tools\":[", .{
            run.usage.input_tokens,
            run.usage.output_tokens,
            run.usage.cache_read_input_tokens,
            run.usage.cache_creation_input_tokens,
        }) catch return error.SnapshotTooLarge;
        var tool_count: usize = 0;
        for (run.tools) |*entry| {
            const tool = &(entry.* orelse continue);
            if (tool_count != 0) writer.writeByte(',') catch return error.SnapshotTooLarge;
            tool_count += 1;
            writer.writeAll("{\"id\":") catch return error.SnapshotTooLarge;
            try self.projectedJsonValueWithKnownCredentials(writer, tool.id);
            writer.print(",\"order\":\"{d}\"", .{tool.order}) catch return error.SnapshotTooLarge;
            writer.writeAll(",\"name\":") catch return error.SnapshotTooLarge;
            try self.projectedJsonValueWithKnownCredentials(writer, tool.name);
            writer.writeAll(",\"input\":") catch return error.SnapshotTooLarge;
            try self.projectedJsonValueWithKnownCredentials(writer, tool.input);
            writer.writeAll(",\"progress\":") catch return error.SnapshotTooLarge;
            try self.projectedJsonValueWithKnownCredentials(writer, tool.progress);
            writer.writeAll(",\"content\":") catch return error.SnapshotTooLarge;
            try self.projectedJsonValueWithKnownCredentials(writer, tool.content);
            writer.print(",\"state\":\"{s}\",\"isError\":{},\"elapsedMs\":\"{d}\",\"inputTruncated\":{},\"progressTruncated\":{},\"contentTruncated\":{},\"redacted\":{}}}", .{
                @tagName(tool.state),
                tool.is_error,
                tool.elapsed_ms,
                tool.input_truncated,
                tool.progress_truncated,
                tool.content_truncated,
                tool.redacted,
            }) catch return error.SnapshotTooLarge;
        }
        writer.writeAll("]}") catch return error.SnapshotTooLarge;
    }

    fn prepareUiRecord(
        self: *Workbench,
        session: *lifecycle.Session,
        run_id: u64,
        request_id: u64,
        response: lifecycle.UiResponse,
        credential: []const u8,
    ) UiRecord {
        var record = UiRecord{
            .request_id = request_id,
            .run_id = run_id,
            .kind = kindForResponse(response),
            .state = stateForResponse(response),
        };
        var pending = session.copyPendingUiRequest(self.allocator) catch return record;
        defer pending.deinit();
        if (pending.run_id != run_id or pending.request_id != request_id) return record;
        var parsed = lifecycle.decodeUiRequest(self.allocator, pending.json) catch return record;
        defer parsed.deinit();
        record.kind = kindForRequest(parsed.value);
        self.fillUiRecord(&record, parsed.value, credential);
        return record;
    }

    fn prepareCancelledUiRecord(
        self: *Workbench,
        session: *lifecycle.Session,
        run_id: u64,
        credential: []const u8,
    ) ?UiRecord {
        if (run_id == 0) return null;
        var pending = session.copyPendingUiRequest(self.allocator) catch return null;
        defer pending.deinit();
        if (pending.run_id != run_id) return null;
        var parsed = lifecycle.decodeUiRequest(self.allocator, pending.json) catch return null;
        defer parsed.deinit();
        var record = UiRecord{
            .request_id = pending.request_id,
            .run_id = run_id,
            .kind = kindForRequest(parsed.value),
            .state = .cancelled,
        };
        self.fillUiRecord(&record, parsed.value, credential);
        return record;
    }

    fn fillUiRecord(
        _: *Workbench,
        record: *UiRecord,
        request: lifecycle.UiRequest,
        credential: []const u8,
    ) void {
        const value = switch (request) {
            .ask_question => |questions| value: {
                record.item_count = @intCast(@min(questions.len, std.math.maxInt(u32)));
                break :value if (questions.len == 0) "" else questions[0].question;
            },
            .permission => |permission| permission.args,
        };
        const result = sanitizeInto(
            &record.detail,
            value,
            credential,
        );
        record.detail_len = result.len;
        record.detail_truncated = result.truncated;
        record.redacted = result.redacted;
    }

    fn writeUiHistory(
        self: *Workbench,
        writer: *std.Io.Writer,
        view: *const TaskView,
    ) Error!void {
        const start = if (view.ui_history_count == view.ui_history.len) view.ui_history_next else 0;
        for (0..view.ui_history_count) |offset| {
            if (offset != 0) writer.writeByte(',') catch return error.SnapshotTooLarge;
            const index = (start + offset) % view.ui_history.len;
            const record = &(view.ui_history[index] orelse unreachable);
            writer.print("{{\"requestId\":\"{d}\",\"runId\":\"{d}\",\"order\":\"{d}\",\"kind\":\"{s}\",\"state\":\"{s}\",\"detail\":", .{
                record.request_id,
                record.run_id,
                record.order,
                @tagName(record.kind),
                @tagName(record.state),
            }) catch return error.SnapshotTooLarge;
            try self.projectedJsonValueWithKnownCredentials(writer, record.detailSlice());
            writer.print(",\"itemCount\":{d},\"detailTruncated\":{},\"redacted\":{}}}", .{
                record.item_count,
                record.detail_truncated,
                record.redacted,
            }) catch return error.SnapshotTooLarge;
        }
    }

    fn pushUiRecord(_: *Workbench, view: *TaskView, record: UiRecord) void {
        for (view.ui_history) |entry| if (entry) |existing|
            if (existing.request_id == record.request_id) return;
        var stored = record;
        if (view.pending_ui_request_id == stored.request_id and view.pending_ui_order != 0) {
            stored.order = view.pending_ui_order;
            view.pending_ui_request_id = 0;
            view.pending_ui_order = 0;
        } else {
            const run = findRun(view.runs, stored.run_id) orelse unreachable;
            stored.order = takeActivityOrder(run);
        }
        view.ui_history[view.ui_history_next] = stored;
        view.ui_history_next = (view.ui_history_next + 1) % view.ui_history.len;
        view.ui_history_count = @min(view.ui_history_count + 1, view.ui_history.len);
    }

    fn freeTrackedText(self: *Workbench, target: *TrackedText) void {
        self.projection_bytes -= target.list.capacity;
        target.list.deinit(self.allocator);
        target.* = undefined;
    }

    fn replaceTracked(self: *Workbench, target: *[]u8, value: []const u8, max: usize) Error!void {
        if (value.len > max or value.len > self.limits.max_projection_bytes - (self.projection_bytes - target.len))
            return error.ProjectionCapacity;
        const next = try self.allocator.dupe(u8, value);
        self.projection_bytes = self.projection_bytes - target.len + next.len;
        self.allocator.free(target.*);
        target.* = next;
    }

    fn freeTracked(self: *Workbench, value: []u8) void {
        self.projection_bytes -= value.len;
        self.allocator.free(value);
    }

    fn bumpRevision(self: *Workbench) void {
        if (self.revision != std.math.maxInt(u64)) self.revision += 1;
    }
};

fn closeWorker(
    agent_runtime: *lifecycle.Runtime,
    view: *TaskView,
    session: *lifecycle.Session,
    notifier: ChangeNotifier,
) void {
    const completion: CloseCompletion = close: {
        switch (session.closeOutcome(.session_close)) {
            .closed => {},
            .failure => |failure| break :close closeFailureCompletion(
                failure.session_disposition,
            ),
        }
        agent_runtime.releaseClosedSession(session) catch
            break :close .failed_closing;
        break :close .closed;
    };
    view.close_completion.store(completion, .release);
    _ = notifier.notify();
}

fn executeRunJob(context: *anyopaque) void {
    const run: *RunRecord = @ptrCast(@alignCast(context));
    const claimed = run.agent_handoff.cmpxchgStrong(
        .queued,
        .starting,
        .acq_rel,
        .acquire,
    );
    std.debug.assert(claimed == null);
    var agent_run = switch (run.session.beginRunOutcome(run.id)) {
        .run => |agent_run| agent_run,
        .failure => |failure| {
            run.agent_handoff.store(.finishing, .release);
            commitBeginFailure(run, failure);
            const notifier = run.workbench.change_notifier;
            releaseWorkerReference(run);
            _ = notifier.notify();
            return;
        },
    };
    run.run_control = agent_run.control();
    run.agent_handoff.store(.running, .release);
    if (run.pending_termination.load(.acquire) != .none) {
        if (run.run_control.tryAcquireLease()) |lease_value| {
            var lease = lease_value;
            const result = lease.requestTermination(pendingTerminationSignal(run));
            lease.deinit();
            if (result == .stale_run) std.debug.panic(
                "newly published RunControl for Run {d} was already stale",
                .{run.id},
            );
        }
    }
    var terminal = agent_run.execute();
    run.agent_handoff.store(.finishing, .release);
    _ = commitAgentTerminal(run, &terminal);
    terminal.deinit();
    agent_run.deinit();
    const notifier = run.workbench.change_notifier;
    releaseWorkerReference(run);
    _ = notifier.notify();
}

fn executeCatalogJob(context: *anyopaque) void {
    const job: *CatalogJob = @ptrCast(@alignCast(context));
    const claimed = job.state.cmpxchgStrong(
        .queued,
        .running,
        .acq_rel,
        .acquire,
    );
    std.debug.assert(claimed == null);
    job.outcome = if (job.runtime.querySkillCatalog(.{
        .workspace_root = job.canonical_root,
        .canonical_user_home = job.canonical_user_home,
        .workspace_epoch = job.epoch_token,
    })) |acquisition|
        .{ .success = acquisition }
    else |_|
        .failure;
    job.state.store(.completed, .release);
    _ = job.notifier.notify();
}

fn cancelCatalogJob(context: *anyopaque) void {
    const job: *CatalogJob = @ptrCast(@alignCast(context));
    const prior = job.state.cmpxchgStrong(
        .queued,
        .cancelled,
        .acq_rel,
        .acquire,
    );
    std.debug.assert(prior == null);
    _ = job.notifier.notify();
}

fn requestRunTermination(
    run: *RunRecord,
    interruption: lifecycle.ExternalInterruption,
) RunTerminationDispatch {
    const pending = pendingInterruption(interruption);
    _ = run.pending_termination.cmpxchgStrong(.none, pending, .acq_rel, .acquire);
    switch (run.agent_handoff.load(.acquire)) {
        .queued, .starting => return .pending,
        .finishing => return .already_finishing,
        .running => {},
    }
    const lease_value = run.run_control.tryAcquireLease() orelse return .already_finishing;
    var lease = lease_value;
    defer lease.deinit();
    return switch (lease.requestTermination(pendingTerminationSignal(run))) {
        .requested => .requested,
        .already_requested => .already_requested,
        .already_terminal => .already_terminal,
        .stale_run => .stale_run,
        .session_closing => .session_closing,
    };
}

fn consumeLifecycleTermination(dispatch: RunTerminationDispatch, run_id: u64) void {
    switch (dispatch) {
        .pending,
        .requested,
        .already_requested,
        .already_finishing,
        .already_terminal,
        .session_closing,
        => {},
        .stale_run => std.debug.panic(
            "active lifecycle Run {d} published a stale RunControl",
            .{run_id},
        ),
    }
}

fn pendingInterruption(interruption: lifecycle.ExternalInterruption) PendingInterruption {
    return switch (interruption) {
        .user_cancel => .user_cancel,
        .session_close => .session_close,
        .app_shutdown => .app_shutdown,
        .timeout => .timeout,
    };
}

fn pendingTerminationSignal(run: *const RunRecord) lifecycle.TerminationSignal {
    return .{ .interrupted = switch (run.pending_termination.load(.acquire)) {
        .none => unreachable,
        .user_cancel => .user_cancel,
        .timeout => .timeout,
        .session_close => .session_close,
        .app_shutdown => .app_shutdown,
    } };
}

fn cancelRunJobForShutdown(context: *anyopaque) void {
    const run: *RunRecord = @ptrCast(@alignCast(context));
    cancelPreparedRunOrPanic(run.session, run.id);
    _ = commitTerminal(
        run,
        .interrupted,
        .interrupted,
        .app_shutdown,
        .closing,
        "",
        false,
    );
    const notifier = run.workbench.change_notifier;
    releaseWorkerReference(run);
    _ = notifier.notify();
}

fn cancelPreparedRunOrPanic(
    session: *lifecycle.Session,
    run_id: u64,
) void {
    session.cancelPreparedRun(run_id) catch |err| std.debug.panic(
        "Executor removed queued Run {d}, but Agent rejected prepared cancellation: {s}",
        .{ run_id, @errorName(err) },
    );
}

fn releaseWorkerReference(run: *RunRecord) void {
    std.debug.assert(run.worker_reference_held.swap(false, .acq_rel));
    const references = &run.task.worker_references;
    const previous = references.fetchSub(1, .release);
    std.debug.assert(previous != 0);
}

fn noChangeNotification(_: ?*anyopaque) bool {
    return true;
}

fn closeFailureCompletion(
    disposition: lifecycle.SessionDisposition,
) CloseCompletion {
    return switch (disposition) {
        .reusable => .failed_reusable,
        .poisoned => .failed_poisoned,
        .closing => .failed_closing,
    };
}

fn agentProvider(provider: Provider) lifecycle.ProviderKind {
    return switch (provider) {
        .anthropic => .anthropic,
        .openai => .openai,
    };
}

fn accountProviderKind(provider: Provider) account_contract.ProviderKind {
    return switch (provider) {
        .anthropic => .anthropic,
        .openai => .openai,
    };
}

fn accountProvider(
    provider: account_contract.ProviderKind,
) Provider {
    return switch (provider) {
        .anthropic => .anthropic,
        .openai => .openai,
    };
}

fn scheduledProvider(provider: Provider) scheduled_tasks_impl.Provider {
    return switch (provider) {
        .anthropic => .anthropic,
        .openai => .openai,
    };
}

fn scheduledOccurrenceOutcome(
    outcome: RunOutcome,
) scheduled_tasks_impl.OccurrenceTaskOutcome {
    return switch (outcome) {
        .completed => .completed,
        .stopped => .stopped,
        .cancelled => .cancelled,
        .interrupted => .interrupted,
        .failed => .failed,
        .dependency_contract_failure => .dependency_contract_failure,
    };
}

fn scheduledFailure(err: anyerror) scheduled_tasks_impl.FailureReason {
    return switch (err) {
        error.ExecutionUnavailable,
        error.ExecutionInUse,
        error.ExecutionGenerationMismatch,
        => .execution_changed,
        error.UnknownWorkspace,
        error.WorkspaceUnavailable,
        error.WorkspaceRemovalInProgress,
        => .workspace_unavailable,
        error.WorkspaceEpochMismatch => .workspace_changed,
        error.CatalogLoading,
        error.CatalogUnavailable,
        error.StaleCatalog,
        error.SkillNotFound,
        error.InvalidSkillArguments,
        => .catalog_changed,
        error.TaskCapacity,
        error.WorkspaceCapacity,
        error.RunCapacity,
        error.ExecutorShuttingDown,
        error.QueueFull,
        => .capacity_reached,
        else => .task_start_failed,
    };
}

fn agentUiResponse(
    response: UiResponse,
    answer_buffer: []lifecycle.Answer,
) lifecycle.UiResponse {
    return switch (response) {
        .answers => |answers| answers_response: {
            std.debug.assert(answer_buffer.len == answers.len);
            for (answers, answer_buffer) |values, *answer|
                answer.* = .{ .values = values };
            break :answers_response .{ .answers = answer_buffer };
        },
        .permission => |choice| .{ .permission = switch (choice) {
            .allow_once => .allow_once,
            .allow_always => .allow_session,
            .deny_once => .deny_once,
            .deny_tool_session => .deny_session,
        } },
    };
}

fn phaseForOutcome(outcome: RunOutcome) RunPhase {
    return switch (outcome) {
        .completed => .completed,
        .stopped => .stopped,
        .cancelled => .cancelled,
        .interrupted => .interrupted,
        .failed, .dependency_contract_failure => .failed,
    };
}

fn commitTerminal(
    run: *RunRecord,
    phase: RunPhase,
    outcome: RunOutcome,
    cause: ?RunCause,
    session_disposition_at_completion: lifecycle.SessionDisposition,
    diagnostic: []const u8,
    source_diagnostic_truncated: bool,
) bool {
    std.debug.assert(isTerminalPhase(phase));
    if (run.terminal_publication.cmpxchgStrong(.open, .publishing, .acq_rel, .acquire) == null) {
        const diagnostic_projection = sanitizeInto(
            run.terminal_diagnostic,
            diagnostic,
            run.redaction_secret,
        );
        run.terminal_payload = .{
            .phase = phase,
            .outcome = outcome,
            .cause = cause,
            .session_disposition_at_completion = session_disposition_at_completion,
            .diagnostic_len = diagnostic_projection.len,
            .diagnostic_truncated = source_diagnostic_truncated or diagnostic_projection.truncated,
            .diagnostic_redacted = diagnostic_projection.redacted,
        };
        run.terminal_publication.store(.published, .release);
        return true;
    }
    _ = terminalPayload(run).?;
    return false;
}

const TerminalDecision = struct {
    phase: RunPhase,
    outcome: RunOutcome,
    cause: ?RunCause,
};

fn commitAgentTerminal(run: *RunRecord, result: *const lifecycle.TerminalResult) bool {
    const decision = classifyAgentTerminal(result);
    return commitTerminal(
        run,
        decision.phase,
        decision.outcome,
        decision.cause,
        result.session_disposition_at_completion,
        result.diagnostic(),
        result.diagnostic_truncated,
    );
}

fn classifyAgentTerminal(result: *const lifecycle.TerminalResult) TerminalDecision {
    if (result.failure == .dependency_contract) return .{
        .phase = .failed,
        .outcome = .dependency_contract_failure,
        .cause = .dependency_contract_failure,
    };
    if (result.failure == .abi_status) return .{
        .phase = .failed,
        .outcome = .failed,
        .cause = if (result.termination_signal) |signal|
            causeForSignal(signal)
        else if (result.abi_status) |status|
            switch (status) {
                .stale_catalog => .stale_catalog,
                .skill_not_found => .skill_not_found,
                .invalid_skill_arguments => .invalid_skill_arguments,
                .skill_policy_violation => .skill_policy_violation,
                .skill_unavailable => .skill_unavailable,
                else => null,
            }
        else
            null,
    };
    if (result.stop_reason) |reason| return switch (reason) {
        .end_turn => .{ .phase = .completed, .outcome = .completed, .cause = null },
        .max_turns, .tool_loop => .{ .phase = .stopped, .outcome = .stopped, .cause = null },
        .aborted => decisionForSignal(result.termination_signal),
        .tool_error, .api_error => .{
            .phase = .failed,
            .outcome = .failed,
            .cause = if (result.termination_signal) |signal| causeForSignal(signal) else null,
        },
    };
    if (result.termination_signal != null and result.raw_status_code == null)
        return decisionForSignal(result.termination_signal);
    return .{
        .phase = .failed,
        .outcome = .dependency_contract_failure,
        .cause = .dependency_contract_failure,
    };
}

fn decisionForSignal(signal: ?lifecycle.TerminationSignal) TerminalDecision {
    const value = signal orelse return .{ .phase = .failed, .outcome = .failed, .cause = null };
    return switch (value) {
        .interrupted => |interruption| switch (interruption) {
            .user_cancel, .timeout => .{
                .phase = .cancelled,
                .outcome = .cancelled,
                .cause = causeForSignal(value),
            },
            .session_close, .app_shutdown => .{
                .phase = .interrupted,
                .outcome = .interrupted,
                .cause = causeForSignal(value),
            },
        },
        .callback_failure,
        .event_pump_failure,
        .event_consumer_notification_failure,
        => .{ .phase = .failed, .outcome = .failed, .cause = causeForSignal(value) },
    };
}

fn causeForSignal(signal: lifecycle.TerminationSignal) RunCause {
    return switch (signal) {
        .interrupted => |interruption| switch (interruption) {
            .user_cancel => .user_cancel,
            .timeout => .timeout,
            .session_close => .session_close,
            .app_shutdown => .app_shutdown,
        },
        .callback_failure => |failure| switch (failure) {
            .event => .event_pipeline_failure,
            .ui => .ui_pipeline_failure,
        },
        .event_pump_failure => |failure| switch (failure) {
            .event_too_large, .capacity => .queue_capacity_failure,
            .invalid_event, .allocation, .consumer_rejected => .event_pipeline_failure,
        },
        .event_consumer_notification_failure => .event_pipeline_failure,
    };
}

fn commitBeginFailure(run: *RunRecord, failure: lifecycle.BeginRunFailure) void {
    const pending = run.pending_termination.load(.acquire);
    if (pending != .none) {
        const decision = decisionForSignal(pendingTerminationSignal(run));
        _ = commitTerminal(
            run,
            decision.phase,
            decision.outcome,
            decision.cause,
            failure.session_disposition,
            "",
            false,
        );
        return;
    }
    if (failure.err == error.SessionClosing) {
        _ = commitTerminal(
            run,
            .interrupted,
            .interrupted,
            .session_close,
            failure.session_disposition,
            "",
            false,
        );
        return;
    }
    _ = commitTerminal(
        run,
        .failed,
        .dependency_contract_failure,
        .dependency_contract_failure,
        failure.session_disposition,
        "",
        false,
    );
}

fn terminalPayload(run: *const RunRecord) ?*const TerminalPayload {
    while (true) switch (run.terminal_publication.load(.acquire)) {
        .open => return null,
        .publishing => std.atomic.spinLoopHint(),
        .published => return &run.terminal_payload,
    };
}

/// Returns the terminal result only after the composition root has drained all
/// Agent events that happened-before terminal publication. `terminalPayload`
/// is the worker-to-main-thread fact; this is the product visibility gate.
fn productTerminalPayload(run: *const RunRecord) ?*const TerminalPayload {
    if (!run.event_stream_finalized) return null;
    return terminalPayload(run);
}

const ProductTerminalFacts = struct {
    phase: RunPhase,
    outcome: RunOutcome,
    cause: ?RunCause,
    session_disposition_at_completion: lifecycle.SessionDisposition,
};

fn productTerminalFacts(run: *const RunRecord) ?ProductTerminalFacts {
    const terminal = productTerminalPayload(run) orelse return null;
    if (run.event_projection_failure != null) return .{
        .phase = .failed,
        .outcome = .failed,
        .cause = .event_pipeline_failure,
        .session_disposition_at_completion = terminal.session_disposition_at_completion,
    };
    return .{
        .phase = terminal.phase,
        .outcome = terminal.outcome,
        .cause = terminal.cause,
        .session_disposition_at_completion = terminal.session_disposition_at_completion,
    };
}

fn runPhase(run: *const RunRecord) RunPhase {
    return if (productTerminalFacts(run)) |terminal| terminal.phase else run.active_phase;
}

fn setActivePhase(run: *RunRecord, phase: RunPhase) bool {
    std.debug.assert(!isTerminalPhase(phase));
    // Terminal publication is owned by a worker and may win after the caller's
    // observation. `active_phase` is irrelevant once the write-once terminal
    // payload is published, so a late phase write is harmless; an assertion
    // here would turn a legal completion race into a process crash.
    if (run.terminal_publication.load(.acquire) != .open) return false;
    run.active_phase = phase;
    return run.terminal_publication.load(.acquire) == .open;
}

fn lastTerminalFacts(runs: []?RunRecord) ?ProductTerminalFacts {
    var latest: ?*const RunRecord = null;
    for (runs) |*entry| {
        const run = &(entry.* orelse continue);
        if (latest == null or run.id > latest.?.id) latest = run;
    }
    return if (latest) |run| productTerminalFacts(run) else null;
}

fn currentRunPhase(view: *const TaskView) ?RunPhase {
    const run = findRun(view.runs, view.active_run_id) orelse return null;
    const phase = runPhase(run);
    return if (isTerminalPhase(phase)) null else phase;
}

fn continuationAvailable(capability: ContinuationCapability) bool {
    return switch (capability) {
        .available => true,
        .unavailable => false,
    };
}

fn foldTerminalDisposition(
    task: *TaskView,
    disposition: lifecycle.SessionDisposition,
) void {
    if (task.lifecycle != .open) return;
    switch (disposition) {
        .reusable => task.continuation = .available,
        .poisoned => task.continuation = .{ .unavailable = .session_poisoned },
        .closing => {
            task.lifecycle = .closing;
            task.continuation = .{ .unavailable = .closing };
        },
    }
}

fn hasNonTerminalRun(view: *const TaskView) bool {
    if (currentRunPhase(view)) |phase| return !isTerminalPhase(phase);
    return false;
}

fn hasUnfinalizedTerminalEvents(view: *const TaskView) bool {
    for (view.runs) |*entry| {
        const run = &(entry.* orelse continue);
        if (!run.event_stream_finalized and terminalPayload(run) != null)
            return true;
    }
    return false;
}

fn isTerminalPhase(phase: RunPhase) bool {
    return switch (phase) {
        .queued, .running, .waiting_ui, .stopping => false,
        .completed, .stopped, .cancelled, .interrupted, .failed => true,
    };
}

fn workspacePathWithin(parent: []const u8, child: []const u8) bool {
    if (std.mem.eql(u8, parent, child)) return true;
    if (!std.mem.startsWith(u8, child, parent)) return false;
    if (parent.len != 0 and std.fs.path.isSep(parent[parent.len - 1])) return true;
    return child.len > parent.len and std.fs.path.isSep(child[parent.len]);
}

const SanitizeResult = struct {
    len: usize,
    truncated: bool,
    redacted: bool,
};

fn sanitizeInto(destination: []u8, value: []const u8, secret: []const u8) SanitizeResult {
    var read: usize = 0;
    var write: usize = 0;
    var redacted = false;
    while (read < value.len) {
        if (credentialEndAtCodepoint(value, read, secret)) |redaction_end| {
            const marker_len = @min(redaction_end - read, 3);
            if (marker_len > destination.len - write) break;
            @memset(destination[write..][0..marker_len], '*');
            write += marker_len;
            read = redaction_end;
            redacted = true;
            continue;
        }
        const sequence_len = utf8CodepointLen(value, read);
        if (sequence_len > value.len - read or sequence_len > destination.len - write) break;
        @memcpy(destination[write..][0..sequence_len], value[read..][0..sequence_len]);
        write += sequence_len;
        read += sequence_len;
    }
    return .{ .len = write, .truncated = read != value.len, .redacted = redacted };
}

fn redactWorkspaceBytesNoFail(
    storage: []u8,
    projected_len: *usize,
    credential: []const u8,
) bool {
    if (credential.len == 0) return false;
    var read: usize = 0;
    var write: usize = 0;
    var redacted = false;
    while (read < projected_len.*) {
        const projected = storage[0..projected_len.*];
        if (credentialEndAtCodepoint(projected, read, credential)) |redaction_end| {
            const marker_len = @min(redaction_end - read, 3);
            @memset(storage[write..][0..marker_len], '*');
            write += marker_len;
            read = redaction_end;
            redacted = true;
            continue;
        }
        const codepoint_len = utf8CodepointLen(projected, read);
        std.mem.copyForwards(
            u8,
            storage[write..][0..codepoint_len],
            projected[read..][0..codepoint_len],
        );
        write += codepoint_len;
        read += codepoint_len;
    }
    projected_len.* = write;
    return redacted;
}

fn redactFixedWidthNoFail(storage: []u8, credential: []const u8) bool {
    if (credential.len == 0 or storage.len < credential.len) return false;
    var cursor: usize = 0;
    var redacted = false;
    while (cursor <= storage.len - credential.len) {
        const relative = std.mem.indexOf(u8, storage[cursor..], credential) orelse break;
        const match_start = cursor + relative;
        const bounds = utf8RedactionBounds(storage, match_start, credential.len);
        @memset(storage[bounds.start..bounds.end], '*');
        cursor = bounds.end;
        redacted = true;
    }
    return redacted;
}

const RedactionBounds = struct { start: usize, end: usize };

fn utf8CodepointLen(value: []const u8, start: usize) usize {
    return @min(
        std.unicode.utf8ByteSequenceLength(value[start]) catch 1,
        value.len - start,
    );
}

fn utf8RedactionBounds(
    value: []const u8,
    match_start: usize,
    match_len: usize,
) RedactionBounds {
    var start = match_start;
    while (start > 0 and value[start] & 0xc0 == 0x80) start -= 1;
    var end = @min(value.len, match_start + match_len);
    while (end < value.len and value[end] & 0xc0 == 0x80) end += 1;
    return .{ .start = start, .end = end };
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
        if (std.mem.startsWith(
            u8,
            value[codepoint_start + offset ..],
            credential,
        ))
            match_end = @max(
                match_end,
                codepoint_start + offset + credential.len,
            );
    }
    if (match_end == 0) return null;
    return utf8RedactionBounds(
        value,
        codepoint_start,
        match_end - codepoint_start,
    ).end;
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
            std.mem.startsWith(u8, credential, remaining))
            return true;
    }
    return false;
}

fn kindForRequest(request: lifecycle.UiRequest) UiRecordKind {
    return switch (request) {
        .ask_question => .ask_question,
        .permission => .permission,
    };
}

fn kindForResponse(response: lifecycle.UiResponse) UiRecordKind {
    return switch (response) {
        .answers => .ask_question,
        .permission => .permission,
    };
}

fn stateForResponse(response: lifecycle.UiResponse) UiRecordState {
    return switch (response) {
        .answers => .answered,
        .permission => |permission| switch (permission) {
            .allow_once => .allowed_once,
            .allow_session => .allowed_always,
            .deny_once => .denied,
            .deny_session => .denied_session,
        },
    };
}

fn jsonValue(writer: *std.Io.Writer, value: anytype) !void {
    try std.json.Stringify.value(value, .{ .emit_nonportable_numbers_as_strings = true }, writer);
}

fn findEmpty(comptime T: type, entries: []?T) ?usize {
    for (entries, 0..) |entry, index| if (entry == null) return index;
    return null;
}

fn findRun(entries: []?RunRecord, run_id: u64) ?*RunRecord {
    if (run_id == 0) return null;
    for (entries) |*entry| if (entry.*) |*run| if (run.id == run_id) return run;
    return null;
}

fn toolRouteDigest(id: []const u8) [tool_route_digest_bytes]u8 {
    var digest: [tool_route_digest_bytes]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(id, &digest, .{});
    return digest;
}

fn findTool(entries: []?ToolView, id: []const u8) ?*ToolView {
    return findToolByRouteDigest(entries, toolRouteDigest(id));
}

fn findToolByRouteDigest(
    entries: []?ToolView,
    route_digest: [tool_route_digest_bytes]u8,
) ?*ToolView {
    for (entries) |*entry| if (entry.*) |*tool|
        if (std.mem.eql(u8, &tool.route_digest, &route_digest)) return tool;
    return null;
}

fn addU64(left: u64, right: u64) error{ProjectionCapacity}!u64 {
    return std.math.add(u64, left, right) catch error.ProjectionCapacity;
}

fn addCatalogProjectionBytes(
    current: usize,
    added: usize,
    limits: Limits,
    available_projection_bytes: usize,
) error{ProjectionCapacity}!usize {
    const total = std.math.add(usize, current, added) catch
        return error.ProjectionCapacity;
    if (total > limits.max_catalog_projection_bytes or
        total > available_projection_bytes)
        return error.ProjectionCapacity;
    return total;
}

fn catalogProjection(
    availability: CatalogAvailability,
    snapshot: ?*const CatalogSnapshot,
) CatalogProjection {
    return switch (availability) {
        .ready, .degraded => if (snapshot) |value|
            value.view()
        else
            .{ .availability = .unavailable },
        .uninitialized, .loading, .unavailable => .{
            .availability = availability,
        },
    };
}

fn taskCatalogProjection(task: *const TaskView) CatalogProjection {
    return if (task.pinned_catalog) |*snapshot|
        snapshot.view()
    else
        .{ .availability = .uninitialized };
}

fn takeActivityOrder(run: *RunRecord) u64 {
    const result = run.next_activity_order;
    std.debug.assert(result != std.math.maxInt(u64));
    run.next_activity_order += 1;
    return result;
}

fn workspaceRecordCapacity(limits: Limits) ?usize {
    return std.math.add(usize, limits.max_workspaces, limits.max_tasks) catch
        null;
}

fn worstCaseSnapshotBytes(limits: Limits) ?usize {
    var total = std.math.mul(usize, limits.max_projection_bytes, json_string_expansion) catch return null;
    total = std.math.add(
        usize,
        total,
        std.math.mul(
            usize,
            limits.max_scheduled_task_projection_bytes,
            json_string_expansion,
        ) catch return null,
    ) catch return null;
    total = std.math.add(usize, total, root_snapshot_overhead) catch return null;
    total = std.math.add(
        usize,
        total,
        std.math.mul(
            usize,
            account_snapshot_text_bytes,
            json_string_expansion,
        ) catch return null,
    ) catch return null;
    total = std.math.add(usize, total, account_snapshot_overhead) catch
        return null;
    total = std.math.add(
        usize,
        total,
        std.math.mul(
            usize,
            workspaceRecordCapacity(limits) orelse return null,
            workspace_snapshot_overhead,
        ) catch return null,
    ) catch return null;
    total = std.math.add(
        usize,
        total,
        std.math.mul(usize, limits.max_tasks, task_snapshot_overhead) catch return null,
    ) catch return null;
    total = std.math.add(
        usize,
        total,
        std.math.mul(
            usize,
            limits.max_scheduled_tasks,
            scheduled_task_snapshot_overhead,
        ) catch return null,
    ) catch return null;
    const catalog_skill_structure = std.math.add(
        usize,
        catalog_skill_snapshot_overhead,
        std.math.mul(
            usize,
            limits.max_skill_arguments,
            catalog_argument_snapshot_overhead,
        ) catch return null,
    ) catch return null;
    const catalog_structure = std.math.add(
        usize,
        catalog_snapshot_overhead,
        std.math.add(
            usize,
            std.math.mul(
                usize,
                limits.max_catalog_skills,
                catalog_skill_structure,
            ) catch return null,
            std.math.mul(
                usize,
                limits.max_catalog_issues,
                catalog_issue_snapshot_overhead,
            ) catch return null,
        ) catch return null,
    ) catch return null;
    const workspace_and_task_catalogs = std.math.add(
        usize,
        limits.max_workspaces,
        limits.max_tasks,
    ) catch return null;
    const catalog_copies = std.math.add(
        usize,
        workspace_and_task_catalogs,
        1,
    ) catch return null;
    total = std.math.add(
        usize,
        total,
        std.math.mul(
            usize,
            catalog_copies,
            catalog_structure,
        ) catch return null,
    ) catch return null;
    const runs = std.math.mul(usize, limits.max_tasks, limits.max_runs_per_task) catch return null;
    total = std.math.add(
        usize,
        total,
        std.math.mul(usize, runs, run_snapshot_overhead) catch return null,
    ) catch return null;
    const tools = std.math.mul(usize, runs, limits.max_tools_per_run) catch return null;
    total = std.math.add(
        usize,
        total,
        std.math.mul(usize, tools, tool_snapshot_overhead) catch return null,
    ) catch return null;
    const pending_ui_payload = std.math.mul(
        usize,
        limits.max_pending_ui_json_bytes,
        pending_ui_reencode_expansion,
    ) catch return null;
    const pending_ui = std.math.add(
        usize,
        pending_ui_payload,
        pending_ui_snapshot_overhead,
    ) catch return null;
    total = std.math.add(
        usize,
        total,
        std.math.mul(usize, limits.max_pending_ui_requests, pending_ui) catch return null,
    ) catch return null;
    const ui_record = std.math.add(
        usize,
        std.math.mul(usize, ui_record_detail_capacity, json_string_expansion) catch return null,
        ui_record_snapshot_overhead,
    ) catch return null;
    const ui_records = std.math.mul(
        usize,
        limits.max_tasks,
        limits.max_ui_history_per_task,
    ) catch return null;
    total = std.math.add(
        usize,
        total,
        std.math.mul(usize, ui_records, ui_record) catch return null,
    ) catch return null;
    return total;
}

var test_agent_runtime: lifecycle.Runtime = undefined;

fn testLimits() Limits {
    return .{
        .max_tasks = 2,
        .max_scheduled_tasks = 2,
        .max_runs_per_task = 2,
        .max_tools_per_run = 2,
        .max_projection_bytes = 64 * 1024,
        .max_scheduled_task_projection_bytes = 4 * 1024,
        .max_workspace_bytes = 1024,
        .max_catalog_skills = 8,
        .max_catalog_issues = 8,
        .max_skill_arguments = 8,
        .max_user_message_bytes = 1024,
        .max_assistant_message_bytes = 32 * 1024,
        .max_tool_field_bytes = 8 * 1024,
        .max_pending_ui_json_bytes = 64 * 1024,
        .max_pending_ui_requests = 2,
        .max_snapshot_bytes = 4 * 1024 * 1024,
    };
}

fn installTestExecution(workbench: *Workbench) !void {
    var execution = try account_contract.OwnedExecutionConfig.initOwned(
        std.testing.allocator,
        .anthropic,
        try std.testing.allocator.dupe(u8, "fixture-model"),
        try std.testing.allocator.dupe(
            u8,
            account_contract.metask_anthropic_messages_url,
        ),
        1,
        try std.testing.allocator.dupe(u8, "SECRET-KEY"),
    );
    errdefer execution.deinit();
    try workbench.beginExecutionReplacement();
    const api_keys = [_]account_contract.ApiKeyView{.{
        .id = "key-1",
        .name = "Primary",
        .suffix = "1234",
        .provider_kind = .anthropic,
    }};
    const models = [_]account_contract.ModelView{.{
        .id = "fixture-model",
        .display_name = "Fixture model",
    }};
    workbench.commitAccountFactNoFail(.{
        .kind = .execution_changed,
        .view = .{
            .session_state = .authenticated,
            .execution_state = .ready,
            .operation = .none,
            .readiness = .ready,
            .primary_action = .none,
            .account_id = "account-1",
            .profile_id = "profile-1",
            .display_name = "Metask User",
            .api_keys = &api_keys,
            .models = &models,
            .selected_api_key_id = "key-1",
            .selected_model = "fixture-model",
            .model_catalog_api_key_id = "key-1",
            .can_create_task = true,
            .catalog_generation = 1,
            .execution_generation = 1,
        },
    });
    workbench.installExecutionNoFail(&execution);
    workbench.endExecutionReplacementNoFail();
    workbench.finishAccountCommitNoFail();
}

fn testWorkbench() !Workbench {
    test_agent_runtime.io = std.testing.io;
    var workbench = try Workbench.init(
        std.testing.allocator,
        &test_agent_runtime,
        testLimits(),
        .{},
    );
    try installTestExecution(&workbench);
    var task_execution = try workbench.execution.cloneOwned(workbench.allocator);
    errdefer task_execution.deinit();
    workbench.revision = 0;
    const workspace = try workbench.copyBounded("/tmp/metawork-test", workbench.limits.max_workspace_bytes);
    workbench.workspaces[0] = .{
        .id = 1,
        .canonical_root = try workbench.copyBounded(
            "/tmp/metawork-test",
            workbench.limits.max_workspace_bytes,
        ),
        .projected_root_storage = try workbench.copyBounded(
            "/tmp/metawork-test",
            workbench.limits.max_workspace_bytes,
        ),
        .projected_root_len = "/tmp/metawork-test".len,
        .display_name_storage = try workbench.copyBounded(
            "metawork-test",
            workbench.limits.max_workspace_bytes,
        ),
        .display_name_len = "metawork-test".len,
        .trust = .explicitly_trusted,
        .recent_order = 1,
    };
    workbench.selected_workspace_id = 1;
    workbench.next_workspace_id = 2;
    workbench.next_workspace_recent_order = 2;
    workbench.next_task_id = 4;
    const execution_model = try workbench.copyBounded(
        workbench.execution.model(),
        account_contract.Limits.model_id_bytes,
    );
    const runs = try workbench.allocator.alloc(?RunRecord, workbench.limits.max_runs_per_task);
    @memset(runs, null);
    const ui_history = try workbench.allocator.alloc(?UiRecord, workbench.limits.max_ui_history_per_task);
    @memset(ui_history, null);
    const tools = try workbench.allocator.alloc(?ToolView, workbench.limits.max_tools_per_run);
    @memset(tools, null);
    runs[0] = .{
        .id = 7,
        .generation = 1,
        .execution_generation = 1,
        .execution_provider = .anthropic,
        .execution_model = execution_model,
        .input = .{ .text = .{
            .value = try workbench.copyBounded(
                "inspect",
                workbench.limits.max_user_message_bytes,
            ),
        } },
        .active_phase = .running,
        .agent_handoff = .init(.running),
        .tools = tools,
        .status_text = try workbench.copyBounded("Queued", workbench.limits.max_tool_field_bytes),
        .terminal_diagnostic = try workbench.allocTrackedCapacity(workbench.limits.max_terminal_diagnostic_bytes),
        .redaction_secret = workbench.execution.credential(),
    };
    workbench.tasks[0] = .{
        .session = null,
        .execution = task_execution.take(),
        .id = 3,
        .recent_order = 1,
        .route_id = 3,
        .execution_generation = 1,
        .execution_provider = .anthropic,
        .execution_model = execution_model,
        .binding_account_id = try workbench.copyBounded(
            "account-1",
            account_contract.Limits.account_id_bytes,
        ),
        .binding_profile_id = try workbench.copyBounded(
            "profile-1",
            account_contract.Limits.profile_id_bytes,
        ),
        .binding_account_name = try workbench.copyBounded(
            "Metask User",
            account_contract.Limits.display_name_bytes,
        ),
        .binding_api_key_id = try workbench.copyBounded(
            "key-1",
            account_contract.Limits.api_key_id_bytes,
        ),
        .binding_api_key_name = try workbench.copyBounded(
            "Primary",
            account_contract.Limits.api_key_name_bytes,
        ),
        .binding_api_key_suffix = try workbench.copyBounded(
            "1234",
            account_contract.Limits.api_key_suffix_bytes,
        ),
        .binding_model_id = try workbench.copyBounded(
            "fixture-model",
            account_contract.Limits.model_id_bytes,
        ),
        .binding_model_display_name = try workbench.copyBounded(
            "Fixture model",
            binding_model_display_bytes,
        ),
        .workspace_id = 1,
        .workspace_root = workspace,
        .title = try workbench.copyBounded("", workbench.limits.max_task_title_bytes),
        .runs = runs,
        .next_run_generation = 1,
        .ui_history = ui_history,
        .active_run_id = 7,
    };
    return workbench;
}

const TestScheduleClock = struct {
    now: u64,
    armed_at: ?u64 = null,
    cancel_count: usize = 0,

    fn nowUnixSeconds(context: ?*anyopaque) ?u64 {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        return self.now;
    }

    fn arm(context: ?*anyopaque, due_unix_seconds: u64) bool {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.armed_at = due_unix_seconds;
        return true;
    }

    fn cancel(context: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.armed_at = null;
        self.cancel_count += 1;
    }

    fn timer(self: *@This()) ScheduleTimer {
        return .{
            .context = self,
            .enabled = true,
            .now_unix_seconds = nowUnixSeconds,
            .arm = arm,
            .cancel = cancel,
        };
    }
};

const TestSchedulePersistence = struct {
    commits: usize = 0,
    result: SchedulePersistenceCommit = .committed,

    fn commit(
        context: ?*anyopaque,
        bytes: []const u8,
    ) SchedulePersistenceCommit {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        std.debug.assert(bytes.len != 0);
        self.commits += 1;
        return self.result;
    }

    fn capability(self: *@This()) SchedulePersistence {
        return .{
            .context = self,
            .enabled = true,
            .commit_fn = commit,
        };
    }
};

fn replaceTaskCredentialForTest(
    task: *TaskView,
    credential: []const u8,
) !void {
    task.execution.?.deinit();
    var replacement = try OwnedTaskExecution.clone(
        std.testing.allocator,
        .anthropic,
        "fixture-model",
        account_contract.metask_anthropic_messages_url,
        task.execution_generation,
        credential,
    );
    task.execution = replacement.take();
    const redaction_secret = task.execution.?.input().api_key;
    for (task.runs) |*run_entry| {
        if (run_entry.*) |*run| run.redaction_secret = redaction_secret;
    }
}

fn testEnvelope(session_id: u64, run_id: u64, encoded: []const u8) !lifecycle.OwnedCoreEvent {
    const allocator = std.testing.allocator;
    return .{
        .session_id = session_id,
        .run_id = run_id,
        .encoded_bytes = encoded.len,
        .json = try allocator.dupe(u8, encoded),
        .event = try lifecycle.decodeCoreEvent(allocator, encoded),
        .allocator = allocator,
    };
}

fn finalizeTestTerminalEvents(workbench: *Workbench) void {
    workbench.markTerminalRunsBeforeEventDrain();
    workbench.finalizeMarkedTerminalRunsAfterEventDrain();
    workbench.syncLifecycle();
}

test "Workspace containment accepts platform roots and rejects path prefixes" {
    const root = if (std.fs.path.sep == '\\') "C:\\" else "/";
    const child = if (std.fs.path.sep == '\\') "C:\\project" else "/project";
    const sibling_prefix = if (std.fs.path.sep == '\\')
        workspacePathWithin("C:\\project", "C:\\project-other")
    else
        workspacePathWithin("/project", "/project-other");
    try std.testing.expect(workspacePathWithin(root, child));
    try std.testing.expect(!sibling_prefix);
}

test "managed Workspace root is optional and reserved from user registration" {
    test_agent_runtime.io = std.testing.io;
    var unavailable = try Workbench.init(
        std.testing.allocator,
        &test_agent_runtime,
        testLimits(),
        .{},
    );
    try std.testing.expect(!unavailable.managedWorkspacesAvailable());
    try installTestExecution(&unavailable);
    try std.testing.expectError(
        error.WorkspaceUnavailable,
        unavailable.createTaskForWorkspace(.managed, 1, null),
    );
    unavailable.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var canonical_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const canonical_len = try tmp.dir.realPath(
        std.testing.io,
        &canonical_storage,
    );
    var root = try managed_workspace_store.Root.open(
        std.testing.io,
        std.testing.allocator,
        canonical_storage[0..canonical_len],
    );
    defer root.deinit();
    var workbench = try Workbench.init(
        std.testing.allocator,
        &test_agent_runtime,
        testLimits(),
        .{ .directories = .{ .managed_workspace_root = &root } },
    );
    defer workbench.deinit();
    try std.testing.expect(workbench.managedWorkspacesAvailable());
    try std.testing.expectError(
        error.InvalidWorkspace,
        workbench.openWorkspace(.{
            .workspace_root = workbench.managed_workspaces.?.canonicalRoot(),
            .trust = .explicitly_trusted,
        }),
    );
    var allocation = try workbench.managed_workspaces.?.allocate();
    defer allocation.deinit();
    try std.testing.expectError(
        error.InvalidWorkspace,
        workbench.openWorkspace(.{
            .workspace_root = allocation.path(),
            .trust = .explicitly_trusted,
        }),
    );
    try std.testing.expect(workbench.managed_workspaces.?.rollback(&allocation));
}

test "Workspace registry owns empty selection recent use authorization and capacity" {
    test_agent_runtime.io = std.testing.io;
    const root_path = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(root_path);
    const source_path = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        "src",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(source_path);
    const tests_path = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        "tests",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(tests_path);
    var workbench = try Workbench.init(
        std.testing.allocator,
        &test_agent_runtime,
        .{
            .max_workspaces = 2,
            .max_tasks = 1,
            .max_runs_per_task = 1,
            .max_tools_per_run = 1,
        },
        .{},
    );
    defer workbench.deinit();

    try std.testing.expectError(
        error.InvalidWorkspace,
        workbench.openWorkspace(.{
            .workspace_root = ".",
            .trust = .explicitly_trusted,
        }),
    );
    try std.testing.expectEqual(@as(u64, 0), workbench.selectedWorkspaceId());

    const root_id = try workbench.openWorkspace(.{
        .workspace_root = root_path,
        .trust = .explicitly_trusted,
    });
    try std.testing.expect(root_id != 0);
    try std.testing.expectEqual(root_id, workbench.selectedWorkspaceId());
    try std.testing.expect(workbench.tasks[0] == null);

    const source_id = try workbench.openWorkspace(.{
        .workspace_root = source_path,
        .trust = .{ .temporary = root_path },
    });
    try std.testing.expect(source_id != root_id);

    var storage: [2]WorkspaceProjection = undefined;
    const projections = try workbench.copyWorkspaceProjections(&storage);
    try std.testing.expectEqual(@as(usize, 2), projections.len);
    try std.testing.expectEqual(source_id, projections[0].id);
    try std.testing.expectEqual(source_id, workbench.selectedWorkspaceId());
    try std.testing.expectEqual(WorkspaceAuthorization.available, projections[0].authorization);
    try std.testing.expectEqualStrings("src", projections[0].display_name);
    try std.testing.expect(std.fs.path.isAbsolute(projections[0].canonical_root));

    try workbench.selectWorkspace(root_id);
    const reordered = try workbench.copyWorkspaceProjections(&storage);
    try std.testing.expectEqual(root_id, reordered[0].id);
    try std.testing.expect(reordered[0].recent_order > reordered[1].recent_order);

    try workbench.removeWorkspace(root_id);
    try std.testing.expectEqual(@as(u64, 2), try workbench.workspaceEpoch(root_id));
    try std.testing.expectEqual(@as(u64, 0), workbench.selectedWorkspaceId());
    const remaining = try workbench.copyWorkspaceProjections(&storage);
    try std.testing.expectEqual(@as(usize, 1), remaining.len);
    try std.testing.expectError(error.UnknownWorkspace, workbench.selectWorkspace(root_id));

    const restored_id = try workbench.openWorkspace(.{
        .workspace_root = root_path,
        .trust = .explicitly_trusted,
    });
    try std.testing.expectEqual(root_id, restored_id);
    const restored = try workbench.copyWorkspaceProjections(&storage);
    try std.testing.expectEqual(root_id, restored[0].id);
    try std.testing.expectEqual(@as(u64, 3), restored[0].epoch);
    try std.testing.expectEqual(WorkspaceAuthorization.available, restored[0].authorization);

    var no_space: [0]WorkspaceProjection = .{};
    try std.testing.expectError(
        error.WorkspaceCapacity,
        workbench.copyWorkspaceProjections(&no_space),
    );
    try std.testing.expectError(
        error.WorkspaceCapacity,
        workbench.openWorkspace(.{
            .workspace_root = tests_path,
            .trust = .{ .temporary = root_path },
        }),
    );
}

test "Workspace projection derives aggregate Task signals and removal preserves history" {
    var workbench = try testWorkbench();
    defer workbench.deinit();
    var storage: [2]WorkspaceProjection = undefined;

    const running = try workbench.copyWorkspaceProjections(&storage);
    try std.testing.expectEqual(@as(u32, 1), running[0].signals.running);
    try std.testing.expectEqual(@as(u32, 0), running[0].signals.attention);

    workbench.tasks[0].?.runs[0].?.active_phase = .waiting_ui;
    const attention = workbench.workspaceSignals(1);
    try std.testing.expectEqual(@as(u32, 0), attention.running);
    try std.testing.expectEqual(@as(u32, 1), attention.attention);

    const run = &workbench.tasks[0].?.runs[0].?;
    _ = commitTerminal(run, .failed, .failed, null, .reusable, "", false);
    finalizeTestTerminalEvents(&workbench);
    const failed = try workbench.copyWorkspaceProjections(&storage);
    try std.testing.expectEqual(@as(u32, 1), failed[0].signals.failed_or_interrupted);

    const task_root = workbench.tasks[0].?.workspace_root;
    try workbench.removeWorkspace(1);
    try std.testing.expect(workbench.tasks[0] != null);
    try std.testing.expectEqualStrings(task_root, workbench.tasks[0].?.workspace_root);
    const removed = try workbench.copyWorkspaceProjections(&storage);
    try std.testing.expectEqual(@as(usize, 0), removed.len);
    try std.testing.expectError(
        error.WorkspaceUnavailable,
        workbench.runTask(3, .{ .text = "continue" }),
    );
}

test "Workbench snapshot serializer matches the Renderer contract fixture" {
    var workbench = try testWorkbench();
    defer workbench.deinit();

    try std.testing.expectEqual(
        CatalogAvailability.uninitialized,
        (try workbench.taskCatalog(3)).availability,
    );
    var storage: [4096]u8 = undefined;
    const snapshot = try workbench.writeSnapshot(&storage);
    const fixture = std.mem.trimEnd(
        u8,
        contract_fixture.snapshot,
        "\r\n",
    );
    try std.testing.expectEqualStrings(fixture, snapshot);
    try std.testing.expect(
        std.mem.indexOf(u8, snapshot, "SECRET-KEY") == null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, snapshot, "\"apiKey\"") == null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, snapshot, "\"baseUrl\"") == null,
    );
}

test "Scheduled Task admission is bounded redacted and arms the Workbench clock" {
    var workbench = try testWorkbench();
    defer workbench.deinit();
    var clock: TestScheduleClock = .{ .now = 1_000 };
    var persistence: TestSchedulePersistence = .{};
    workbench.schedule_timer = clock.timer();
    workbench.schedule_persistence = persistence.capability();
    workbench.schedule_persistence_health = .ready;
    try std.testing.expectError(
        error.WorkspaceUnavailable,
        workbench.createScheduledTask(.{
            .title = "Independent review",
            .target = .default,
            .expected_execution_generation = 1,
            .input = .{ .text = "Review current work" },
            .recurrence = .{ .once = .{ .at_unix_seconds = 2_000 } },
        }),
    );
    try std.testing.expectEqual(@as(usize, 0), persistence.commits);
    const id = try workbench.createScheduledTask(.{
        .title = "Review SECRET-KEY",
        .target = .{ .explicit = .{
            .workspace_id = 1,
            .expected_workspace_epoch = 1,
        } },
        .expected_execution_generation = 1,
        .input = .{ .text = "Inspect SECRET-KEY usage" },
        .recurrence = .{ .interval = .{
            .start_at_unix_seconds = 2_000,
            .every_seconds = 300,
        } },
    });
    try std.testing.expect(clock.armed_at == null);
    workbench.setScheduleBackgroundAvailableNoFail(true);
    try std.testing.expectEqual(@as(u64, 2_000), clock.armed_at.?);
    try std.testing.expectEqual(@as(usize, 1), persistence.commits);
    const item = workbench.scheduled_tasks.find(id).?;
    try std.testing.expect(item.title_redacted);
    try std.testing.expect(
        std.mem.indexOf(u8, item.title, "SECRET-KEY") == null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            item.input.text.value,
            "SECRET-KEY",
        ) == null,
    );
    const storage = try std.testing.allocator.alloc(
        u8,
        workbench.limits.max_snapshot_bytes,
    );
    defer std.testing.allocator.free(storage);
    const snapshot = try workbench.writeSnapshot(storage);
    try std.testing.expect(
        std.mem.indexOf(u8, snapshot, "\"scheduledTasks\":[{") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, snapshot, "SECRET-KEY") == null,
    );
    try workbench.setScheduledTaskEnabled(id, item.epoch, false);
    try std.testing.expectEqual(@as(usize, 2), persistence.commits);
    try std.testing.expect(clock.armed_at == null);
    try std.testing.expectEqual(
        scheduled_tasks_impl.Health.paused,
        workbench.scheduled_tasks.find(id).?.health,
    );
    const committed_epoch = workbench.scheduled_tasks.find(id).?.epoch;
    persistence.result = .failed;
    try std.testing.expectError(
        error.ScheduledTaskPersistenceFailed,
        workbench.deleteScheduledTask(id, committed_epoch),
    );
    try std.testing.expect(workbench.scheduled_tasks.find(id) != null);
    try std.testing.expectEqual(
        committed_epoch,
        workbench.scheduled_tasks.find(id).?.epoch,
    );
    try std.testing.expectEqual(
        SchedulePersistenceHealth.write_failed,
        workbench.schedule_persistence_health,
    );
}

test "Skill catalog snapshot reports redaction without exposing credential bytes" {
    var workbench = try testWorkbench();
    defer workbench.deinit();
    const skills = [_]SkillProjection{.{
        .skill_id = "builtin.review",
        .invocation_name = "review",
        .display_name = "Review",
        .description = "Review SECRET-KEY usage",
        .argument_names = &.{"target"},
        .max_values = 1,
    }};
    var storage: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try workbench.writeCatalogProjection(&writer, .{
        .availability = .ready,
        .revision = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        .skills = &skills,
    });
    const encoded = writer.buffered();
    try std.testing.expect(
        std.mem.indexOf(u8, encoded, "\"redacted\":true") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, encoded, "SECRET-KEY") == null,
    );
}

test "credential release permanently scrubs catalog and every Skill history field" {
    var workbench = try testWorkbench();
    defer workbench.deinit();
    const source_skills = [_]lifecycle.CatalogSkill{.{
        .skill_id = "builtin.review",
        .invocation_name = "review",
        .display_name = "Review SECRET-KEY",
        .description = "Review SECRET-KEY usage",
        .argument_names = &.{"SECRET-KEY target"},
        .max_values = 1,
    }};
    const workspace_catalog = try CatalogSnapshot.init(
        workbench.allocator,
        .{
            .revision = "safe-revision",
            .health = .healthy,
            .skills = &source_skills,
            .issues = &.{},
            .storage = undefined,
        },
        workbench.limits,
        workbench.limits.max_projection_bytes - workbench.projection_bytes,
    );
    const task_catalog = try workspace_catalog.clone(
        workbench.allocator,
        workbench.limits,
        workbench.limits.max_projection_bytes -
            workbench.projection_bytes -
            workspace_catalog.projected_bytes,
    );
    workbench.projection_bytes += workspace_catalog.projected_bytes;
    workbench.workspaces[0].?.catalog = workspace_catalog;
    workbench.workspaces[0].?.catalog_availability = .ready;
    workbench.projection_bytes += task_catalog.projected_bytes;
    workbench.tasks[0].?.pinned_catalog = task_catalog;

    const task = &workbench.tasks[0].?;
    const run = &task.runs[0].?;
    const history_input: RunInputRecord = history: {
        const skill_id = try workbench.copyBounded(
            "history-SECRET-KEY",
            workbench.limits.max_catalog_projection_bytes,
        );
        errdefer workbench.freeTracked(skill_id);
        const revision = try workbench.copyBounded(
            "revision-SECRET-KEY",
            workbench.limits.max_catalog_projection_bytes,
        );
        errdefer workbench.freeTracked(revision);
        const invocation = try workbench.copyBounded(
            "review-SECRET-KEY",
            workbench.limits.max_catalog_projection_bytes,
        );
        errdefer workbench.freeTracked(invocation);
        const display = try workbench.copyBounded(
            "Review SECRET-KEY",
            workbench.limits.max_catalog_projection_bytes,
        );
        errdefer workbench.freeTracked(display);
        const values = try workbench.allocator.alloc([]u8, 1);
        errdefer workbench.allocator.free(values);
        values[0] = try workbench.copyBounded(
            "SECRET-KEY target",
            workbench.limits.max_user_message_bytes,
        );
        errdefer workbench.freeTracked(values[0]);
        break :history .{ .skill = .{
            .skill_id = skill_id,
            .catalog_revision = revision,
            .invocation_name = invocation,
            .display_name = display,
            .argument_values = values,
        } };
    };
    workbench.deinitRunInputRecord(&run.input);
    run.input = history_input;

    workbench.redactAllProductProjectionsNoFail("SECRET-KEY");
    workbench.execution.clearNoFail();
    if (task.execution) |*execution| {
        execution.deinit();
        task.execution = null;
    }
    run.redaction_secret = &.{};

    var storage: [16 * 1024]u8 = undefined;
    const snapshot = try workbench.writeSnapshot(&storage);
    try std.testing.expect(
        std.mem.indexOf(u8, snapshot, "SECRET-KEY") == null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, snapshot, "\"redacted\":true") != null,
    );
    try std.testing.expect(workbench.workspaces[0].?.catalog.?.redacted);
    try std.testing.expect(workbench.tasks[0].?.pinned_catalog.?.redacted);
}

test "mutation admission rejects stale execution and binding facts" {
    var workbench = try testWorkbench();
    defer workbench.deinit();

    try std.testing.expectError(
        error.ExecutionGenerationMismatch,
        workbench.createTaskInWorkspace(1, 1, 0, null),
    );
    try std.testing.expectError(
        error.ExecutionGenerationMismatch,
        workbench.createTaskInWorkspace(1, 1, 2, null),
    );
    try std.testing.expectError(
        error.WorkspaceEpochMismatch,
        workbench.createTaskInWorkspace(1, 2, 1, null),
    );
    try std.testing.expectError(
        error.BindingEpochMismatch,
        workbench.runTaskAtBinding(3, 2, .{ .text = "stale continuation" }),
    );
}

test "Task metadata mutations preserve lifecycle guards and projection accounting" {
    var workbench = try testWorkbench();
    defer workbench.deinit();

    try std.testing.expectError(error.TaskBusy, workbench.setTaskArchived(3, true));
    try std.testing.expectError(error.TaskNotClosed, workbench.deleteTask(3));
    try std.testing.expectError(error.InvalidTaskTitle, workbench.renameTask(3, "  \n  "));
    try std.testing.expectError(error.InvalidTaskTitle, workbench.renameTask(3, "bad\ttitle"));
    try std.testing.expectError(error.InvalidTaskTitle, workbench.renameTask(3, &.{0xff}));

    try workbench.renameTask(3, "Review release readiness");
    try std.testing.expectEqualStrings("Review release readiness", workbench.tasks[0].?.title);

    workbench.tasks[0].?.active_run_id = 0;
    const completed = &workbench.tasks[0].?.runs[0].?;
    _ = commitTerminal(completed, .completed, .completed, null, .reusable, "", false);
    finalizeTestTerminalEvents(&workbench);
    try workbench.setTaskArchived(3, true);
    try std.testing.expect(workbench.tasks[0].?.archived);

    workbench.tasks[0].?.lifecycle = .closing;
    workbench.tasks[0].?.continuation = .{ .unavailable = .closing };
    try std.testing.expectError(error.TaskBusy, workbench.setTaskArchived(3, false));
    workbench.tasks[0].?.lifecycle = .closed;
    workbench.tasks[0].?.continuation = .{ .unavailable = .closed };
    const tracked_before_delete = workbench.projection_bytes;
    try workbench.deleteTask(3);
    try std.testing.expect(workbench.tasks[0] == null);
    try std.testing.expect(workbench.projection_bytes < tracked_before_delete);
    try std.testing.expectError(error.UnknownTask, workbench.renameTask(3, "gone"));
}

test "Run admission reserves a stable generation and rolls back every fallible allocation" {
    var workbench = try testWorkbench();
    defer workbench.deinit();
    const task = &workbench.tasks[0].?;
    const tracked_before = workbench.projection_bytes;
    const generation_before = task.next_run_generation;
    var oversized_prompt: [1025]u8 = undefined;
    @memset(&oversized_prompt, 'x');
    try std.testing.expectError(
        error.ProjectionCapacity,
        workbench.reserveRunRecord(task, .{ .text = &oversized_prompt }),
    );
    try std.testing.expectEqual(tracked_before, workbench.projection_bytes);
    try std.testing.expectEqual(generation_before, task.next_run_generation);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const allocator = workbench.allocator;
    workbench.allocator = failing.allocator();
    defer workbench.allocator = allocator;
    try std.testing.expectError(
        error.OutOfMemory,
        workbench.reserveRunRecord(task, .{ .text = "will fail" }),
    );
    workbench.allocator = allocator;
    try std.testing.expectEqual(tracked_before, workbench.projection_bytes);
    try std.testing.expectEqual(generation_before, task.next_run_generation);

    const slot = try workbench.reserveRunRecord(task, .{ .text = "reserved" });
    const first_generation = task.runs[slot].?.generation;
    try std.testing.expectEqual(
        task.execution_generation,
        task.runs[slot].?.execution_generation,
    );
    try std.testing.expectEqual(
        task.execution_provider,
        task.runs[slot].?.execution_provider,
    );
    try std.testing.expectEqualStrings(
        task.execution_model,
        task.runs[slot].?.execution_model,
    );
    workbench.discardRunRecord(task, slot);
    const reused_slot = try workbench.reserveRunRecord(
        task,
        .{ .text = "reserved again" },
    );
    try std.testing.expectEqual(slot, reused_slot);
    try std.testing.expect(task.runs[reused_slot].?.generation > first_generation);
    try std.testing.expectError(
        error.RunCapacity,
        workbench.reserveRunRecord(task, .{ .text = "overflow" }),
    );
    workbench.discardRunRecord(task, reused_slot);
}

test "Workbench starts without execution and fails Task admission closed" {
    test_agent_runtime.io = std.testing.io;
    var workbench = try Workbench.init(
        std.testing.allocator,
        &test_agent_runtime,
        .{
            .max_tasks = 1,
            .max_runs_per_task = 1,
            .max_tools_per_run = 1,
        },
        .{},
    );
    defer workbench.deinit();
    try std.testing.expectError(
        error.ExecutionUnavailable,
        workbench.createTask(.{
            .workspace_root = "/tmp",
            .trust = .{ .temporary = "/tmp" },
        }),
    );
    try std.testing.expectEqual(@as(u64, 0), workbench.currentRevision());
}

test "Account projection and execution install use preallocated no-fail storage" {
    test_agent_runtime.io = std.testing.io;
    var workbench = try Workbench.init(
        std.testing.allocator,
        &test_agent_runtime,
        .{
            .max_tasks = 1,
            .max_runs_per_task = 1,
            .max_tools_per_run = 1,
        },
        .{},
    );
    defer workbench.deinit();
    var execution = try account_contract.OwnedExecutionConfig.initOwned(
        std.testing.allocator,
        .openai,
        try std.testing.allocator.dupe(u8, "model-1"),
        try std.testing.allocator.dupe(
            u8,
            account_contract.metask_openai_chat_completions_url,
        ),
        1,
        try std.testing.allocator.dupe(u8, "secret-key"),
    );
    errdefer execution.deinit();
    const api_keys = [_]account_contract.ApiKeyView{.{
        .id = "key-1",
        .name = "Primary",
        .suffix = "1234",
        .provider_kind = .openai,
    }};
    const models = [_]account_contract.ModelView{.{
        .id = "model-1",
        .display_name = "Model One",
    }};
    try workbench.beginExecutionReplacement();
    workbench.commitAccountFactNoFail(.{
        .kind = .execution_changed,
        .view = .{
            .session_state = .authenticated,
            .execution_state = .ready,
            .operation = .none,
            .readiness = .ready,
            .primary_action = .none,
            .account_id = "account-1",
            .profile_id = "profile-1",
            .display_name = "Metask User",
            .api_keys = &api_keys,
            .models = &models,
            .selected_api_key_id = "key-1",
            .selected_model = "model-1",
            .model_catalog_api_key_id = "key-1",
            .can_create_task = true,
            .catalog_generation = 2,
            .execution_generation = 1,
        },
    });
    workbench.installExecutionNoFail(&execution);
    try std.testing.expect(!workbench.accountView().can_create_task);
    workbench.endExecutionReplacementNoFail();
    workbench.finishAccountCommitNoFail();
    const view = workbench.accountView();
    try std.testing.expect(view.can_create_task);
    try std.testing.expectEqualStrings("Primary", view.api_keys[0].name);
    try std.testing.expectEqualStrings("Model One", view.models[0].display_name);
    try std.testing.expectEqual(@as(u64, 1), workbench.currentRevision());
}

test "execution replacement gate rejects live Task state and admits closed history" {
    var workbench = try testWorkbench();
    defer workbench.deinit();
    try workbench.beginDefaultExecutionReplacement();
    try std.testing.expect(workbench.executionReplacementPending());
    try std.testing.expect(!workbench.accountView().can_create_task);
    workbench.endExecutionReplacementNoFail();
    try std.testing.expectError(
        error.ExecutionInUse,
        workbench.beginExecutionReplacement(),
    );
    try std.testing.expect(!workbench.executionReplacementPending());
    const task = &workbench.tasks[0].?;
    task.runs[0].?.active_phase = .completed;
    task.lifecycle = .closed;
    task.continuation = .{ .unavailable = .closed };
    task.active_run_id = 0;
    try workbench.beginExecutionReplacement();
    try std.testing.expect(workbench.executionReplacementPending());
    try std.testing.expect(task.execution == null);
    try std.testing.expectEqualStrings("fixture-model", task.execution_model);
    try std.testing.expect(!workbench.accountView().can_create_task);
    workbench.endExecutionReplacementNoFail();
    try std.testing.expect(workbench.accountView().can_create_task);
}

test "default replacement preserves Task generation and installs the next admission default" {
    var workbench = try testWorkbench();
    defer workbench.deinit();

    const task = &workbench.tasks[0].?;
    try workbench.replaceTracked(
        &task.title,
        "review future metawork credential",
        workbench.limits.max_task_title_bytes,
    );
    try workbench.replaceTracked(
        &task.runs[0].?.status_text,
        "future metawork status",
        workbench.limits.max_tool_field_bytes,
    );
    const old_input = try Workbench.taskExecutionInput(task);
    try std.testing.expectEqual(@as(u64, 1), old_input.execution_generation);
    try std.testing.expectEqualStrings("SECRET-KEY", old_input.api_key);

    var replacement = try account_contract.OwnedExecutionConfig.initOwned(
        std.testing.allocator,
        .openai,
        try std.testing.allocator.dupe(u8, "fixture-model-2"),
        try std.testing.allocator.dupe(
            u8,
            account_contract.metask_openai_chat_completions_url,
        ),
        2,
        try std.testing.allocator.dupe(u8, "metawork"),
    );
    errdefer replacement.deinit();
    const replacement_api_keys = [_]account_contract.ApiKeyView{.{
        .id = "key-2",
        .name = "Secondary",
        .suffix = "5678",
        .provider_kind = .openai,
    }};
    const replacement_models = [_]account_contract.ModelView{.{
        .id = "fixture-model-2",
        .display_name = "Fixture model 2",
    }};
    try workbench.beginDefaultExecutionReplacement();
    try std.testing.expect(workbench.taskContinuationAvailable(task));
    try std.testing.expectEqual(
        @as(u64, 1),
        (try Workbench.taskExecutionInput(task)).execution_generation,
    );
    try std.testing.expect(!workbench.accountView().can_create_task);
    workbench.commitAccountFactNoFail(.{
        .kind = .execution_changed,
        .view = .{
            .session_state = .authenticated,
            .execution_state = .ready,
            .operation = .none,
            .readiness = .ready,
            .primary_action = .none,
            .account_id = "account-1",
            .profile_id = "profile-1",
            .display_name = "Metask User",
            .api_keys = &replacement_api_keys,
            .models = &replacement_models,
            .selected_api_key_id = "key-2",
            .selected_model = "fixture-model-2",
            .model_catalog_api_key_id = "key-2",
            .can_create_task = true,
            .execution_generation = 2,
        },
    });
    workbench.installExecutionNoFail(&replacement);
    workbench.endExecutionReplacementNoFail();
    workbench.finishAccountCommitNoFail();

    const preserved = try Workbench.taskExecutionInput(task);
    try std.testing.expectEqual(@as(u64, 1), preserved.execution_generation);
    try std.testing.expectEqualStrings("fixture-model", preserved.target.model);
    try std.testing.expectEqualStrings("SECRET-KEY", preserved.api_key);
    try std.testing.expectEqual(@as(u64, 2), workbench.execution.generation);
    try std.testing.expectEqualStrings("fixture-model-2", workbench.execution.model());
    try std.testing.expectEqualStrings("fixture-model", task.execution_model);
    try std.testing.expect(std.mem.indexOf(u8, task.title, "metawork") == null);
    try std.testing.expect(std.mem.indexOf(u8, task.runs[0].?.status_text, "metawork") == null);
    var scrubbed_snapshot_storage: [96 * 1024]u8 = undefined;
    const scrubbed_snapshot = try workbench.writeSnapshot(&scrubbed_snapshot_storage);
    try std.testing.expect(std.mem.indexOf(u8, scrubbed_snapshot, "metawork") == null);
    var workspace_storage: [2]WorkspaceProjection = undefined;
    const workspace_projection = try workbench.copyWorkspaceProjections(&workspace_storage);
    try std.testing.expect(workspace_projection[0].canonical_root.len != 0);
    try std.testing.expect(std.mem.indexOf(
        u8,
        workspace_projection[0].canonical_root,
        "metawork",
    ) == null);

    var next_task_execution = try workbench.execution.cloneOwned(std.testing.allocator);
    defer next_task_execution.deinit();
    try std.testing.expectEqual(
        @as(u64, 2),
        next_task_execution.input().execution_generation,
    );

    const slot = try workbench.reserveRunRecord(
        task,
        .{ .text = "old SECRET-KEY remains private" },
    );
    defer workbench.discardRunRecord(task, slot);
    try std.testing.expectEqual(@as(u64, 1), task.runs[slot].?.execution_generation);
    try std.testing.expectEqualStrings(
        "old *** remains private",
        task.runs[slot].?.input.text.value,
    );
    try std.testing.expectEqualStrings("SECRET-KEY", task.runs[slot].?.redaction_secret);

    task.execution_generation = 2;
    try std.testing.expectError(
        error.ExecutionGenerationMismatch,
        Workbench.taskExecutionInput(task),
    );
    try std.testing.expectError(
        error.ExecutionGenerationMismatch,
        workbench.runTask(
            task.id,
            .{ .text = "must reject a mismatched binding" },
        ),
    );
    task.execution_generation = 1;
}

test "released Task credential is permanently scrubbed from every product projection" {
    var workbench = try testWorkbench();
    defer workbench.deinit();
    const task = &workbench.tasks[0].?;
    const run = &task.runs[0].?;

    try workbench.replaceTracked(
        &task.title,
        "title SECRET-KEY",
        workbench.limits.max_task_title_bytes,
    );
    try workbench.replaceTracked(
        &task.binding_model_id,
        "model-SECRET-KEY",
        account_contract.Limits.model_id_bytes,
    );
    try workbench.replaceTracked(
        &run.input.text.value,
        "prompt SECRET-KEY",
        workbench.limits.max_user_message_bytes,
    );
    try workbench.appendTrackedText(
        &run.assistant,
        "answer SECRET-KEY",
        workbench.limits.max_assistant_message_bytes,
    );
    try workbench.replaceTracked(
        &run.status_text,
        "status SECRET-KEY",
        workbench.limits.max_tool_field_bytes,
    );
    run.tools[0] = .{
        .route_digest = toolRouteDigest("SECRET-KEY"),
        .id = try workbench.copyBounded("id SECRET-KEY", workbench.limits.max_tool_field_bytes),
        .order = 1,
        .name = try workbench.copyBounded("name SECRET-KEY", workbench.limits.max_tool_field_bytes),
        .input = try workbench.copyBounded("input SECRET-KEY", workbench.limits.max_tool_field_bytes),
        .progress = try workbench.copyBounded("progress SECRET-KEY", workbench.limits.max_tool_field_bytes),
        .content = try workbench.copyBounded("content SECRET-KEY", workbench.limits.max_tool_field_bytes),
        .state = .completed,
    };
    const workspace = &workbench.workspaces[0].?;
    @memcpy(workspace.projected_root_storage[0.."SECRET-KEY".len], "SECRET-KEY");
    workspace.projected_root_len = "SECRET-KEY".len;
    task.ui_history[0] = .{
        .request_id = 8,
        .run_id = run.id,
        .kind = .permission,
        .state = .denied,
    };
    @memcpy(task.ui_history[0].?.detail[0.."SECRET-KEY".len], "SECRET-KEY");
    task.ui_history[0].?.detail_len = "SECRET-KEY".len;
    task.ui_history_count = 1;

    run.active_phase = .completed;
    task.lifecycle = .closed;
    task.continuation = .{ .unavailable = .closed };
    task.active_run_id = 0;
    try workbench.beginExecutionReplacement();
    try std.testing.expect(task.execution == null);
    try std.testing.expectEqualStrings("fixture-model", task.execution_model);
    try std.testing.expect(std.mem.indexOf(u8, task.binding_model_id, "SECRET-KEY") == null);
    var snapshot_storage: [96 * 1024]u8 = undefined;
    const snapshot = try workbench.writeSnapshot(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "SECRET-KEY") == null);
    workbench.endExecutionReplacementNoFail();
}

test "clearing the last default execution scrubs its credential before secure zero" {
    test_agent_runtime.io = std.testing.io;
    var workbench = try Workbench.init(
        std.testing.allocator,
        &test_agent_runtime,
        .{
            .max_tasks = 1,
            .max_runs_per_task = 1,
            .max_tools_per_run = 1,
        },
        .{},
    );
    defer workbench.deinit();
    try installTestExecution(&workbench);
    workbench.workspaces[0] = .{
        .id = 1,
        .canonical_root = try workbench.copyBounded("/tmp", workbench.limits.max_workspace_bytes),
        .projected_root_storage = try workbench.copyBounded(
            "path-SECRET-KEY",
            workbench.limits.max_workspace_bytes,
        ),
        .projected_root_len = "path-SECRET-KEY".len,
        .display_name_storage = try workbench.copyBounded(
            "SECRET-KEY",
            workbench.limits.max_workspace_bytes,
        ),
        .display_name_len = "SECRET-KEY".len,
        .trust = .explicitly_trusted,
        .recent_order = 1,
    };
    workbench.selected_workspace_id = 1;

    try workbench.beginDefaultExecutionReplacement();
    workbench.commitAccountFactNoFail(.{
        .kind = .signed_out,
        .view = .{
            .session_state = .signed_out,
            .execution_state = .none,
            .operation = .none,
            .readiness = .sign_in_required,
            .primary_action = .sign_in,
        },
    });
    workbench.clearExecutionNoFail();
    workbench.endExecutionReplacementNoFail();
    workbench.finishAccountCommitNoFail();

    try std.testing.expectEqual(@as(usize, 0), workbench.execution.credential().len);
    var snapshot_storage: [96 * 1024]u8 = undefined;
    const snapshot = try workbench.writeSnapshot(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "SECRET-KEY") == null);
}

test "known credential matching chooses the longest overlapping secret" {
    var workbench = try testWorkbench();
    defer workbench.deinit();
    std.crypto.secureZero(u8, workbench.execution.credential_storage);
    @memcpy(workbench.execution.credential_storage[0.."SECRET".len], "SECRET");
    workbench.execution.credential_len = "SECRET".len;

    try std.testing.expectEqual(
        @as(usize, "SECRET-KEY".len),
        workbench.matchedKnownCredentialLen("SECRET-KEY suffix"),
    );
    try workbench.replaceTracked(
        &workbench.tasks[0].?.runs[0].?.status_text,
        "SECRET-KEY suffix",
        workbench.limits.max_tool_field_bytes,
    );
    var snapshot_storage: [96 * 1024]u8 = undefined;
    const snapshot = try workbench.writeSnapshot(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "SECRET-KEY") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "***-KEY") == null);
}

test "opaque credential redaction preserves UTF-8 projection validity" {
    var workbench = try testWorkbench();
    defer workbench.deinit();
    std.crypto.secureZero(u8, workbench.execution.credential_storage);
    workbench.execution.credential_storage[0] = 0xa9;
    workbench.execution.credential_len = 1;

    var output: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    try workbench.projectedJsonValueWithKnownCredentials(&writer, "café");
    try std.testing.expectEqualStrings("\"caf**\"", writer.buffered());
    try std.testing.expect(std.unicode.utf8ValidateSlice(writer.buffered()));

    var fixed = "café".*;
    try std.testing.expect(redactFixedWidthNoFail(&fixed, &.{0xa9}));
    try std.testing.expectEqualStrings("caf**", &fixed);
    try std.testing.expect(std.unicode.utf8ValidateSlice(&fixed));
}

test "opaque credential redaction is UTF-8 safe across product inputs and assistant chunks" {
    var workbench = try testWorkbench();
    defer workbench.deinit();
    const task = &workbench.tasks[0].?;
    try replaceTaskCredentialForTest(task, &.{0xa9});

    const slot = try workbench.reserveRunRecord(task, .{ .text = "café" });
    defer workbench.discardRunRecord(task, slot);
    try std.testing.expectEqualStrings(
        "caf**",
        task.runs[slot].?.input.text.value,
    );
    try std.testing.expect(std.unicode.utf8ValidateSlice(
        task.runs[slot].?.input.text.value,
    ));

    var tool_event = try testEnvelope(
        task.route_id,
        7,
        "{\"tool_start\":{\"id\":\"tool-1\",\"name\":\"café\",\"input\":\"café\"}}",
    );
    defer tool_event.deinit();
    try workbench.applyEvent(&tool_event);
    const tool = &task.runs[0].?.tools[0].?;
    try std.testing.expectEqualStrings("caf**", tool.name);
    try std.testing.expectEqualStrings("caf**", tool.input);
    try std.testing.expect(std.unicode.utf8ValidateSlice(tool.name));
    try std.testing.expect(std.unicode.utf8ValidateSlice(tool.input));

    const request = lifecycle.UiRequest{
        .permission = .{ .tool = "café", .args = "café" },
    };
    var pending_storage: [4096]u8 = undefined;
    var pending_writer = std.Io.Writer.fixed(&pending_storage);
    try workbench.writePendingUiProjection(&pending_writer, 9, 7, 1, request);
    try std.testing.expect(std.unicode.utf8ValidateSlice(pending_writer.buffered()));
    try std.testing.expect(std.mem.indexOf(u8, pending_writer.buffered(), &.{0xa9}) == null);

    var assistant = TrackedText{};
    defer assistant.list.deinit(std.testing.allocator);
    try assistant.list.appendSlice(std.testing.allocator, "café");
    try std.testing.expect(workbench.redactTrackedText(&assistant, &.{0xa9}));
    try std.testing.expectEqualStrings("caf**", assistant.list.items);
    try std.testing.expect(std.unicode.utf8ValidateSlice(assistant.list.items));
}

test "assistant redaction withholds a UTF-8 codepoint across credential chunks" {
    var workbench = try testWorkbench();
    defer workbench.deinit();
    var assistant = TrackedText{};
    defer assistant.list.deinit(std.testing.allocator);
    const credential = [_]u8{ 0xa9, 'X' };

    try assistant.list.appendSlice(std.testing.allocator, "é");
    try std.testing.expect(!workbench.redactTrackedText(&assistant, &credential));
    try std.testing.expectEqual(@as(usize, 0), assistant.committed_len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(assistant.list.items));

    try assistant.list.appendSlice(std.testing.allocator, "X tail");
    try std.testing.expect(workbench.redactTrackedText(&assistant, &credential));
    try std.testing.expectEqualStrings("*** tail", assistant.list.items);
    try std.testing.expectEqual(assistant.list.items.len, assistant.committed_len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(assistant.list.items));
}

test "product Task identity is independent from Agent Session route identity" {
    var workbench = try testWorkbench();
    defer workbench.deinit();
    workbench.tasks[0].?.route_id = 99;

    var routed = try testEnvelope(99, 7, "{\"text_chunk\":\"routed\"}");
    defer routed.deinit();
    try workbench.applyEvent(&routed);
    try std.testing.expectEqual(@as(u64, 3), workbench.tasks[0].?.id);
    try std.testing.expectEqualStrings(
        "routed",
        workbench.tasks[0].?.runs[0].?.assistant.list.items,
    );

    var product_id_is_not_route = try testEnvelope(3, 7, "{\"text_chunk\":\"wrong\"}");
    defer product_id_is_not_route.deinit();
    try std.testing.expectError(
        error.UnknownTask,
        workbench.applyEvent(&product_id_is_not_route),
    );
}

test "streaming Run events do not reorder Task navigation" {
    var workbench = try testWorkbench();
    defer workbench.deinit();
    const before = workbench.tasks[0].?.recent_order;

    var text = try testEnvelope(3, 7, "{\"text_chunk\":\"streaming\"}");
    defer text.deinit();
    try workbench.applyEvent(&text);
    try std.testing.expectEqual(before, workbench.tasks[0].?.recent_order);

    var usage = try testEnvelope(
        3,
        7,
        "{\"usage\":{\"input_tokens\":1,\"output_tokens\":1,\"cache_read_input_tokens\":0,\"cache_creation_input_tokens\":0}}",
    );
    defer usage.deinit();
    try workbench.applyEvent(&usage);
    try std.testing.expectEqual(before, workbench.tasks[0].?.recent_order);
}

test "event projection failure routes by Agent Session identity not product Task identity" {
    var workbench = try testWorkbench();
    defer workbench.deinit();
    const task = &workbench.tasks[0].?;
    task.route_id = 99;

    workbench.recordEventProjectionFailure(task.id, 7);
    try std.testing.expect(task.runs[0].?.event_projection_failure == null);
    try std.testing.expect(workbench.taskContinuationAvailable(task));

    workbench.recordEventProjectionFailure(task.route_id, 7);
    try std.testing.expectEqual(
        EventProjectionFailure.consumer_rejected,
        task.runs[0].?.event_projection_failure.?,
    );
    try std.testing.expect(!workbench.taskContinuationAvailable(task));
}

test "Workbench shutdown releases current and Task-owned execution generations" {
    var workbench = try testWorkbench();
    try workbench.beginDefaultExecutionReplacement();
    var replacement = try account_contract.OwnedExecutionConfig.initOwned(
        std.testing.allocator,
        .anthropic,
        try std.testing.allocator.dupe(u8, "fixture-model-2"),
        try std.testing.allocator.dupe(
            u8,
            account_contract.metask_anthropic_messages_url,
        ),
        2,
        try std.testing.allocator.dupe(u8, "SECRET-KEY-2"),
    );
    errdefer replacement.deinit();
    const replacement_api_keys = [_]account_contract.ApiKeyView{.{
        .id = "key-2",
        .name = "Secondary",
        .suffix = "5678",
        .provider_kind = .anthropic,
    }};
    const replacement_models = [_]account_contract.ModelView{.{
        .id = "fixture-model-2",
        .display_name = "Fixture model 2",
    }};
    workbench.commitAccountFactNoFail(.{
        .kind = .execution_changed,
        .view = .{
            .session_state = .authenticated,
            .execution_state = .ready,
            .operation = .none,
            .readiness = .ready,
            .primary_action = .none,
            .account_id = "account-1",
            .profile_id = "profile-1",
            .display_name = "Metask User",
            .api_keys = &replacement_api_keys,
            .models = &replacement_models,
            .selected_api_key_id = "key-2",
            .selected_model = "fixture-model-2",
            .model_catalog_api_key_id = "key-2",
            .can_create_task = true,
            .execution_generation = 2,
        },
    });
    workbench.installExecutionNoFail(&replacement);
    workbench.endExecutionReplacementNoFail();
    workbench.deinit();
}

test "terminal publication is allocation-free write-once bounded history" {
    var workbench = try testWorkbench();
    defer workbench.deinit();
    const run = &workbench.tasks[0].?.runs[0].?;
    const diagnostic = try std.testing.allocator.alloc(u8, run.terminal_diagnostic.len + 17);
    defer std.testing.allocator.free(diagnostic);
    @memset(diagnostic, 'x');

    try std.testing.expect(commitTerminal(
        run,
        .failed,
        .failed,
        .event_pipeline_failure,
        .poisoned,
        diagnostic,
        false,
    ));
    const terminal = terminalPayload(run).?;
    try std.testing.expectEqual(RunPhase.failed, terminal.phase);
    try std.testing.expectEqual(RunOutcome.failed, terminal.outcome);
    try std.testing.expectEqual(@as(?RunCause, .event_pipeline_failure), terminal.cause);
    try std.testing.expectEqual(run.terminal_diagnostic.len, terminal.diagnostic_len);
    try std.testing.expect(terminal.diagnostic_truncated);
    try std.testing.expectEqualSlices(u8, diagnostic[0..run.terminal_diagnostic.len], run.terminal_diagnostic);
    try std.testing.expect(!commitTerminal(
        run,
        .failed,
        .failed,
        .event_pipeline_failure,
        .reusable,
        diagnostic,
        false,
    ));
    try std.testing.expect(!commitTerminal(
        run,
        .interrupted,
        .interrupted,
        .session_close,
        .closing,
        "late mutation",
        false,
    ));
    try std.testing.expect(!setActivePhase(run, .stopping));
    try std.testing.expectEqual(RunOutcome.failed, terminalPayload(run).?.outcome);
    try std.testing.expectEqual(@as(?RunCause, .event_pipeline_failure), terminalPayload(run).?.cause);
}

test "terminal disposition folds exactly once without reopening a closing Task" {
    var workbench = try testWorkbench();
    defer workbench.deinit();
    const task = &workbench.tasks[0].?;

    task.continuation = .available;
    foldTerminalDisposition(task, .poisoned);
    try std.testing.expectEqual(TaskLifecycle.open, task.lifecycle);
    try std.testing.expectEqual(
        ContinuationUnavailableReason.session_poisoned,
        task.continuation.unavailable,
    );

    task.lifecycle = .closing;
    task.continuation = .{ .unavailable = .closing };
    foldTerminalDisposition(task, .reusable);
    try std.testing.expectEqual(TaskLifecycle.closing, task.lifecycle);
    try std.testing.expectEqual(
        ContinuationUnavailableReason.closing,
        task.continuation.unavailable,
    );

    task.lifecycle = .closed;
    task.continuation = .{ .unavailable = .closed };
    foldTerminalDisposition(task, .reusable);
    try std.testing.expectEqual(TaskLifecycle.closed, task.lifecycle);
    try std.testing.expectEqual(
        ContinuationUnavailableReason.closed,
        task.continuation.unavailable,
    );
}

test "canonical prompt title and terminal diagnostic never retain the registered credential" {
    var workbench = try testWorkbench();
    defer workbench.deinit();
    const task = &workbench.tasks[0].?;

    try workbench.renameTask(task.id, "Review SECRET-KEY usage");
    try std.testing.expect(std.mem.indexOf(u8, task.title, "SECRET-KEY") == null);
    try std.testing.expect(task.title_redacted);

    const slot = try workbench.reserveRunRecord(
        task,
        .{ .text = "prompt SECRET-KEY payload" },
    );
    const run = &task.runs[slot].?;
    try std.testing.expect(
        std.mem.indexOf(u8, run.input.text.value, "SECRET-KEY") == null,
    );
    try std.testing.expect(run.input.text.redacted);
    try std.testing.expect(commitTerminal(
        run,
        .failed,
        .failed,
        .dependency_contract_failure,
        .poisoned,
        "diagnostic SECRET-KEY payload",
        false,
    ));
    const terminal = terminalPayload(run).?;
    try std.testing.expect(terminal.diagnostic_redacted);
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            run.terminal_diagnostic[0..terminal.diagnostic_len],
            "SECRET-KEY",
        ) == null,
    );
}

test "Agent terminal facts map once into Workbench product outcomes" {
    var terminal = lifecycle.TerminalResult{
        .allocator = std.testing.allocator,
        .diagnostic_storage = &.{},
        .diagnostic_len = 0,
        .diagnostic_truncated = false,
        .abi_status = .ok,
        .raw_status_code = @intFromEnum(lifecycle.Status.ok),
        .stop_reason = .end_turn,
        .raw_stop_reason_code = @intFromEnum(lifecycle.StopReason.end_turn),
        .abort_status = null,
        .raw_abort_status_code = null,
        .termination_signal = null,
        .failure = null,
        .session_disposition_at_completion = .reusable,
    };
    try std.testing.expectEqual(
        TerminalDecision{ .phase = .completed, .outcome = .completed, .cause = null },
        classifyAgentTerminal(&terminal),
    );

    terminal.abi_status = null;
    terminal.raw_status_code = null;
    terminal.stop_reason = null;
    terminal.raw_stop_reason_code = null;
    terminal.termination_signal = .{ .interrupted = .user_cancel };
    try std.testing.expectEqual(
        TerminalDecision{ .phase = .cancelled, .outcome = .cancelled, .cause = .user_cancel },
        classifyAgentTerminal(&terminal),
    );

    terminal.raw_status_code = @intFromEnum(lifecycle.Status.callback_failed);
    terminal.failure = .abi_status;
    terminal.termination_signal = .{ .callback_failure = .ui };
    try std.testing.expectEqual(
        TerminalDecision{ .phase = .failed, .outcome = .failed, .cause = .ui_pipeline_failure },
        classifyAgentTerminal(&terminal),
    );

    terminal.failure = .dependency_contract;
    try std.testing.expectEqual(
        TerminalDecision{
            .phase = .failed,
            .outcome = .dependency_contract_failure,
            .cause = .dependency_contract_failure,
        },
        classifyAgentTerminal(&terminal),
    );
}

test "Renderer transport failures never own Agent Run termination" {
    const cases = [_]struct {
        stage: TransportFailureStage,
        decision: TransportFailureDecision,
    }{
        .{ .stage = .ingress_validation, .decision = .reject_command },
        .{ .stage = .command_dispatch, .decision = .reject_command },
        .{ .stage = .response_delivery, .decision = .detach_renderer },
        .{ .stage = .revision_delivery, .decision = .retry },
        .{ .stage = .snapshot_transport, .decision = .retry },
        .{ .stage = .connection_generation, .decision = .detach_renderer },
    };
    for (cases) |case| {
        const decision = decideTransportFailure(.{ .stage = case.stage });
        try std.testing.expectEqual(case.decision, decision);
        try std.testing.expect(decision != .request_run_termination);
    }
}

test "Task deletion scrubs retained projections before releasing its credential" {
    var workbench = try testWorkbench();
    defer workbench.deinit();
    const task = &workbench.tasks[0].?;
    const workspace = &workbench.workspaces[0].?;
    @memcpy(workspace.projected_root_storage[0.."SECRET-KEY".len], "SECRET-KEY");
    workspace.projected_root_len = "SECRET-KEY".len;
    workspace.projection_redacted = false;
    task.lifecycle = .closed;
    task.continuation = .{ .unavailable = .closed };
    task.active_run_id = 0;
    _ = commitTerminal(
        &task.runs[0].?,
        .completed,
        .completed,
        null,
        .reusable,
        "",
        false,
    );
    finalizeTestTerminalEvents(&workbench);

    try workbench.deleteTask(3);
    try std.testing.expect(workbench.tasks[0] == null);
    try std.testing.expect(workspace.projection_redacted);
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            workspace.projected_root_storage[0..workspace.projected_root_len],
            "SECRET-KEY",
        ) == null,
    );
}

test "Workbench projection preserves text bytes with bounded geometric growth" {
    var workbench = try testWorkbench();
    defer workbench.deinit();

    const chunk = "0123456789abcdef";
    for (0..2048) |_| {
        var envelope = try testEnvelope(3, 7, "{\"text_chunk\":\"0123456789abcdef\"}");
        defer envelope.deinit();
        try workbench.applyEvent(&envelope);
    }
    const run = findRun(workbench.tasks[0].?.runs, 7).?;
    try std.testing.expectEqual(@as(usize, chunk.len * 2048), run.assistant.list.items.len);
    for (0..2048) |index|
        try std.testing.expectEqualStrings(chunk, run.assistant.list.items[index * chunk.len ..][0..chunk.len]);
    var overflow = try testEnvelope(3, 7, "{\"text_chunk\":\"x\"}");
    defer overflow.deinit();
    try std.testing.expectError(error.ProjectionCapacity, workbench.applyEvent(&overflow));
    try std.testing.expect(run.assistant.list.capacity <= workbench.limits.max_assistant_message_bytes);
    try std.testing.expect(workbench.projection_bytes <= workbench.limits.max_projection_bytes);
}

test "Workbench snapshot budget includes JSON escaping and structural overhead" {
    const limits = Limits{};
    const worst_case = worstCaseSnapshotBytes(limits).?;
    try std.testing.expect(worst_case <= limits.max_snapshot_bytes);
    try std.testing.expect(worst_case > 1024 * 1024);
    try std.testing.expectEqual(@as(usize, 512 * 1024), limits.max_projection_bytes);
    try std.testing.expectEqual(@as(usize, 16), limits.max_runs_per_task);
    const single_pending_budget = limits.max_pending_ui_json_bytes * pending_ui_reencode_expansion + pending_ui_snapshot_overhead;
    try std.testing.expect(worst_case >= single_pending_budget * limits.max_pending_ui_requests);

    var workbench = try testWorkbench();
    defer workbench.deinit();
    const run = findRun(workbench.tasks[0].?.runs, 7).?;
    const remaining = @min(
        workbench.limits.max_assistant_message_bytes,
        workbench.limits.max_projection_bytes - workbench.projection_bytes,
    );
    const controls = try std.testing.allocator.alloc(u8, remaining);
    defer std.testing.allocator.free(controls);
    @memset(controls, 1);
    try workbench.appendTrackedText(&run.assistant, controls, workbench.limits.max_assistant_message_bytes);
    _ = workbench.redactTrackedText(&run.assistant, run.redaction_secret);

    const snapshot_storage = try std.testing.allocator.alloc(u8, workbench.limits.max_snapshot_bytes);
    defer std.testing.allocator.free(snapshot_storage);
    const snapshot = try workbench.writeSnapshot(snapshot_storage);
    try std.testing.expect(snapshot.len > controls.len * 5);
}

fn installMaximumAccountProjection(workbench: *Workbench) !void {
    const account_id: [account_contract.Limits.account_id_bytes]u8 =
        @splat('a');
    const profile_id: [account_contract.Limits.profile_id_bytes]u8 =
        @splat('p');
    const display_name: [account_contract.Limits.display_name_bytes]u8 =
        @splat('d');
    const api_key_name: [account_contract.Limits.api_key_name_bytes]u8 =
        @splat('n');
    const api_key_suffix: [account_contract.Limits.api_key_suffix_bytes]u8 =
        @splat('s');
    const model_name: [account_contract.Limits.model_display_name_bytes]u8 =
        @splat('v');
    const diagnostic: [account_contract.Limits.safe_diagnostic_bytes]u8 =
        @splat('x');
    const api_keys = try std.testing.allocator.alloc(
        account_contract.ApiKeyView,
        account_contract.Limits.api_key_entries,
    );
    defer std.testing.allocator.free(api_keys);
    const api_key_ids = try std.testing.allocator.alloc(
        [account_contract.Limits.api_key_id_bytes]u8,
        account_contract.Limits.api_key_entries,
    );
    defer std.testing.allocator.free(api_key_ids);
    for (api_keys, api_key_ids, 0..) |*api_key, *id, index| {
        id.* = @splat('k');
        var value = index;
        for (0..20) |offset| {
            id[id.len - 1 - offset] = @intCast('0' + value % 10);
            value /= 10;
        }
        api_key.* = .{
            .id = id,
            .name = &api_key_name,
            .suffix = &api_key_suffix,
            .provider_kind = .anthropic,
        };
    }
    const models = try std.testing.allocator.alloc(
        account_contract.ModelView,
        account_contract.Limits.model_entries,
    );
    defer std.testing.allocator.free(models);
    const model_ids = try std.testing.allocator.alloc(
        [account_contract.Limits.model_id_bytes]u8,
        account_contract.Limits.model_entries,
    );
    defer std.testing.allocator.free(model_ids);
    for (models, model_ids, 0..) |*model, *id, index| {
        id.* = @splat('m');
        var value = index;
        for (0..20) |offset| {
            id[id.len - 1 - offset] = @intCast('0' + value % 10);
            value /= 10;
        }
        model.* = .{
            .id = id,
            .display_name = &model_name,
        };
    }
    workbench.commitAccountFactNoFail(.{
        .kind = .catalog_changed,
        .view = .{
            .session_state = .authenticated,
            .execution_state = .ready,
            .operation = .none,
            .readiness = .ready,
            .primary_action = .none,
            .account_id = &account_id,
            .profile_id = &profile_id,
            .display_name = &display_name,
            .api_keys = api_keys,
            .models = models,
            .selected_api_key_id = &api_key_ids[0],
            .selected_model = &model_ids[0],
            .model_catalog_api_key_id = &api_key_ids[0],
            .can_create_task = false,
            .error_code = .invalid_state,
            .safe_diagnostic = &diagnostic,
            .catalog_generation = std.math.maxInt(u64),
            .execution_generation = std.math.maxInt(u64),
        },
    });
    workbench.finishAccountCommitNoFail();
}

test "default snapshot budget contains the maximum structural projection" {
    const limits = Limits{};
    test_agent_runtime.io = std.testing.io;
    var workbench = try Workbench.init(
        std.testing.allocator,
        &test_agent_runtime,
        limits,
        .{},
    );
    defer workbench.deinit();
    try installMaximumAccountProjection(&workbench);

    for (0..limits.max_tasks) |task_index| {
        const execution_model = try workbench.copyBounded(
            "fixture-model",
            account_contract.Limits.model_id_bytes,
        );
        const runs = try workbench.allocator.alloc(?RunRecord, limits.max_runs_per_task);
        @memset(runs, null);
        const ui_history = try workbench.allocator.alloc(?UiRecord, limits.max_ui_history_per_task);
        @memset(ui_history, null);
        for (0..limits.max_runs_per_task) |run_index| {
            const tools = try workbench.allocator.alloc(?ToolView, limits.max_tools_per_run);
            @memset(tools, null);
            for (0..limits.max_tools_per_run) |tool_index| {
                tools[tool_index] = .{
                    .route_digest = toolRouteDigest(""),
                    .id = try workbench.copyBounded("", limits.max_tool_field_bytes),
                    .order = @intCast(tool_index + 1),
                    .name = try workbench.copyBounded("", limits.max_tool_field_bytes),
                    .input = try workbench.copyBounded("", limits.max_tool_field_bytes),
                    .progress = try workbench.copyBounded("", limits.max_tool_field_bytes),
                    .content = try workbench.copyBounded("", limits.max_tool_field_bytes),
                    .state = .completed,
                    .elapsed_ms = std.math.maxInt(u64),
                };
            }
            runs[run_index] = .{
                .id = @intCast(run_index + 1),
                .generation = @intCast(run_index + 1),
                .execution_generation = 1,
                .execution_provider = .anthropic,
                .execution_model = execution_model,
                .input = .{ .text = .{
                    .value = try workbench.copyBounded(
                        "",
                        limits.max_user_message_bytes,
                    ),
                } },
                .tools = tools,
                .status_text = try workbench.copyBounded("", limits.max_tool_field_bytes),
                .terminal_diagnostic = try workbench.allocTrackedCapacity(limits.max_terminal_diagnostic_bytes),
            };
        }
        workbench.tasks[task_index] = .{
            .session = null,
            .id = @intCast(task_index + 1),
            .recent_order = @intCast(task_index + 1),
            .route_id = @intCast(task_index + 1),
            .execution_generation = 1,
            .execution_provider = .anthropic,
            .execution_model = execution_model,
            .binding_account_id = try workbench.copyBounded(
                "",
                account_contract.Limits.account_id_bytes,
            ),
            .binding_profile_id = try workbench.copyBounded(
                "",
                account_contract.Limits.profile_id_bytes,
            ),
            .binding_account_name = try workbench.copyBounded(
                "",
                account_contract.Limits.display_name_bytes,
            ),
            .binding_api_key_id = try workbench.copyBounded(
                "",
                account_contract.Limits.api_key_id_bytes,
            ),
            .binding_api_key_name = try workbench.copyBounded(
                "",
                account_contract.Limits.api_key_name_bytes,
            ),
            .binding_api_key_suffix = try workbench.copyBounded(
                "",
                account_contract.Limits.api_key_suffix_bytes,
            ),
            .binding_model_id = try workbench.copyBounded(
                "",
                account_contract.Limits.model_id_bytes,
            ),
            .binding_model_display_name = try workbench.copyBounded(
                "",
                binding_model_display_bytes,
            ),
            .workspace_id = 0,
            .workspace_root = try workbench.copyBounded("", limits.max_workspace_bytes),
            .title = try workbench.copyBounded("", limits.max_task_title_bytes),
            .runs = runs,
            .next_run_generation = @intCast(limits.max_runs_per_task),
            .ui_history = ui_history,
        };
        for (0..limits.max_ui_history_per_task) |record_index| {
            var record = UiRecord{
                .request_id = @intCast(record_index + 1),
                .run_id = 1,
                .order = @intCast(limits.max_tools_per_run + record_index + 1),
                .kind = .permission,
                .state = .allowed_once,
                .detail_len = ui_record_detail_capacity,
                .detail_truncated = true,
            };
            @memset(&record.detail, 3);
            workbench.tasks[task_index].?.ui_history[record_index] = record;
        }
        workbench.tasks[task_index].?.ui_history_count = limits.max_ui_history_per_task;
    }

    const escaped_assistant = try std.testing.allocator.alloc(u8, limits.max_assistant_message_bytes);
    defer std.testing.allocator.free(escaped_assistant);
    @memset(escaped_assistant, 1);
    try workbench.appendTrackedText(
        &workbench.tasks[0].?.runs[0].?.assistant,
        escaped_assistant,
        limits.max_assistant_message_bytes,
    );
    _ = workbench.redactTrackedText(
        &workbench.tasks[0].?.runs[0].?.assistant,
        workbench.tasks[0].?.runs[0].?.redaction_secret,
    );
    const remaining_projection = limits.max_projection_bytes - workbench.projection_bytes;
    const escaped_tool = try std.testing.allocator.alloc(
        u8,
        @min(limits.max_tool_field_bytes, remaining_projection),
    );
    defer std.testing.allocator.free(escaped_tool);
    @memset(escaped_tool, 2);
    try workbench.replaceTracked(
        &workbench.tasks[0].?.runs[0].?.tools[0].?.content,
        escaped_tool,
        limits.max_tool_field_bytes,
    );
    try std.testing.expectEqual(limits.max_projection_bytes, workbench.projection_bytes);

    const storage = try std.testing.allocator.alloc(u8, limits.max_snapshot_bytes);
    defer std.testing.allocator.free(storage);
    const snapshot = try workbench.writeSnapshot(storage);
    try std.testing.expect(snapshot.len <= worstCaseSnapshotBytes(limits).?);
    try std.testing.expect(snapshot.len <= limits.max_snapshot_bytes);
}

test "pending UI re-encoding remains inside its concurrent snapshot allowance" {
    const limits = Limits{};
    const payload_len = (limits.max_pending_ui_json_bytes - 256) / json_string_expansion;
    const payload = try std.testing.allocator.alloc(u8, payload_len);
    defer std.testing.allocator.free(payload);
    @memset(payload, 1);
    const request = lifecycle.UiRequest{ .ask_question = &.{.{
        .question = payload,
        .header = "Large request",
        .multi = false,
        .options = &.{},
    }} };
    const encoded = try std.json.Stringify.valueAlloc(std.testing.allocator, request, .{});
    defer std.testing.allocator.free(encoded);
    try std.testing.expect(encoded.len <= limits.max_pending_ui_json_bytes);

    const allowance = limits.max_pending_ui_json_bytes * pending_ui_reencode_expansion + pending_ui_snapshot_overhead;
    const storage = try std.testing.allocator.alloc(u8, allowance);
    defer std.testing.allocator.free(storage);
    var writer = std.Io.Writer.fixed(storage);
    var workbench = try testWorkbench();
    defer workbench.deinit();
    try workbench.writePendingUiProjection(
        &writer,
        std.math.maxInt(u64),
        std.math.maxInt(u64),
        std.math.maxInt(u64),
        request,
    );
    try std.testing.expect(writer.buffered().len <= allowance);
}

test "Workbench projects tools and full-width usage without parsing protocol in Renderer" {
    var workbench = try testWorkbench();
    defer workbench.deinit();

    const events = [_][]const u8{
        "{\"tool_start\":{\"id\":\"tool-1\",\"name\":\"Bash\",\"input\":\"{\\\"command\\\":\\\"printf ok\\\"}\"}}",
        "{\"tool_progress\":{\"id\":\"tool-1\",\"text\":\"running\"}}",
        "{\"tool_result\":{\"id\":\"tool-1\",\"name\":\"Bash\",\"input\":\"{}\",\"content\":\"stdout\\nexit 0\",\"is_error\":false,\"elapsed_ms\":18446744073709551615}}",
        "{\"usage\":{\"input_tokens\":18446744073709551615,\"output_tokens\":0,\"cache_read_input_tokens\":0,\"cache_creation_input_tokens\":0}}",
    };
    for (events) |encoded| {
        var envelope = try testEnvelope(3, 7, encoded);
        defer envelope.deinit();
        try workbench.applyEvent(&envelope);
    }

    var snapshot_storage: [96 * 1024]u8 = undefined;
    const snapshot = try workbench.writeSnapshot(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"name\":\"Bash\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "stdout\\nexit 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"elapsedMs\":\"18446744073709551615\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"input\":\"18446744073709551615\"") != null);
}

test "known Host credentials are removed from assistant, tool, and UI projections" {
    var workbench = try testWorkbench();
    defer workbench.deinit();
    const events = [_][]const u8{
        "{\"text_chunk\":\"prefix SECRET-\"}",
        "{\"text_chunk\":\"KEY suffix\"}",
        "{\"tool_start\":{\"id\":\"tool-SECRET-KEY\",\"name\":\"Bash SECRET-KEY\",\"input\":\"SECRET-KEY\"}}",
        "{\"tool_progress\":{\"id\":\"tool-SECRET-KEY\",\"text\":\"using SECRET-KEY\"}}",
        "{\"tool_result\":{\"id\":\"tool-SECRET-KEY\",\"name\":\"Bash SECRET-KEY\",\"input\":\"SECRET-KEY\",\"content\":\"SECRET-KEY\",\"is_error\":false,\"elapsed_ms\":1}}",
    };
    for (events) |encoded| {
        var envelope = try testEnvelope(3, 7, encoded);
        defer envelope.deinit();
        try workbench.applyEvent(&envelope);
    }
    const tool = &workbench.tasks[0].?.runs[0].?.tools[0].?;
    for ([_][]const u8{
        tool.id,
        tool.name,
        tool.input,
        tool.progress,
        tool.content,
    }) |canonical_text|
        try std.testing.expect(std.mem.indexOf(u8, canonical_text, "SECRET-KEY") == null);
    try std.testing.expect(tool.redacted);
    try std.testing.expectEqual(ToolState.completed, tool.state);

    const request = lifecycle.UiRequest{ .permission = .{ .tool = "Bash", .args = "token=SECRET-KEY" } };
    var pending_storage: [4096]u8 = undefined;
    var pending_writer = std.Io.Writer.fixed(&pending_storage);
    try workbench.writePendingUiProjection(
        &pending_writer,
        9,
        7,
        1,
        request,
    );

    var snapshot_storage: [96 * 1024]u8 = undefined;
    const snapshot = try workbench.writeSnapshot(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "SECRET-KEY") == null);
    try std.testing.expect(std.mem.indexOf(u8, pending_writer.buffered(), "SECRET-KEY") == null);
    try std.testing.expect(std.mem.indexOf(u8, pending_writer.buffered(), "\"redacted\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "prefix *** suffix") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"id\":\"tool-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"name\":\"Bash ***\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"assistantRedacted\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"redacted\":true") != null);
}

test "Workbench product tool identities remain unique after raw ID redaction" {
    var workbench = try testWorkbench();
    defer workbench.deinit();
    const events = [_][]const u8{
        "{\"tool_start\":{\"id\":\"SECRET-KEY\",\"name\":\"Read\",\"input\":\"first\"}}",
        "{\"tool_start\":{\"id\":\"***\",\"name\":\"Bash\",\"input\":\"second\"}}",
        "{\"tool_progress\":{\"id\":\"SECRET-KEY\",\"text\":\"first progress\"}}",
        "{\"tool_progress\":{\"id\":\"***\",\"text\":\"second progress\"}}",
    };
    for (events) |encoded| {
        var envelope = try testEnvelope(3, 7, encoded);
        defer envelope.deinit();
        try workbench.applyEvent(&envelope);
    }

    const first = &workbench.tasks[0].?.runs[0].?.tools[0].?;
    const second = &workbench.tasks[0].?.runs[0].?.tools[1].?;
    try std.testing.expectEqualStrings("tool-1", first.id);
    try std.testing.expectEqualStrings("tool-2", second.id);
    try std.testing.expectEqualStrings("first progress", first.progress);
    try std.testing.expectEqualStrings("second progress", second.progress);
    try std.testing.expect(!std.mem.eql(u8, &first.route_digest, &second.route_digest));
}

test "assistant credential redaction finalizes ordinary chunks without rescanning history" {
    var workbench = try testWorkbench();
    defer workbench.deinit();
    const assistant = &workbench.tasks[0].?.runs[0].?.assistant;

    for (0..4096) |_| {
        try workbench.appendTrackedText(assistant, "x", workbench.limits.max_assistant_message_bytes);
        try std.testing.expect(!workbench.redactTrackedText(assistant, workbench.execution.credential()));
        try std.testing.expectEqual(assistant.list.items.len, assistant.committed_len);
    }
    try std.testing.expectEqual(@as(usize, 4096), assistant.list.items.len);

    try workbench.appendTrackedText(assistant, "SECRET-", workbench.limits.max_assistant_message_bytes);
    try std.testing.expect(!workbench.redactTrackedText(assistant, workbench.execution.credential()));
    try std.testing.expectEqual(assistant.list.items.len - "SECRET-".len, assistant.committed_len);

    var pending_snapshot_storage: [96 * 1024]u8 = undefined;
    const pending_snapshot = try workbench.writeSnapshot(&pending_snapshot_storage);
    try std.testing.expect(std.mem.indexOf(u8, pending_snapshot, "SECRET-") == null);

    try workbench.appendTrackedText(assistant, "KEY", workbench.limits.max_assistant_message_bytes);
    try std.testing.expect(workbench.redactTrackedText(assistant, workbench.execution.credential()));
    try std.testing.expectEqual(assistant.list.items.len, assistant.committed_len);
    try std.testing.expect(std.mem.endsWith(u8, assistant.list.items, "***"));

    try workbench.appendTrackedText(assistant, " tail SECRET-", workbench.limits.max_assistant_message_bytes);
    try std.testing.expect(!workbench.redactTrackedText(assistant, workbench.execution.credential()));
    const run = &workbench.tasks[0].?.runs[0].?;
    try std.testing.expect(commitTerminal(
        run,
        .completed,
        .completed,
        null,
        .reusable,
        "",
        false,
    ));
    workbench.markTerminalRunsBeforeEventDrain();
    var terminal_pending_storage: [96 * 1024]u8 = undefined;
    const terminal_pending = try workbench.writeSnapshot(&terminal_pending_storage);
    try std.testing.expect(std.mem.indexOf(u8, terminal_pending, "tail SECRET-") == null);
    const revision_before_finalization = workbench.revision;
    workbench.finalizeMarkedTerminalRunsAfterEventDrain();
    try std.testing.expectEqual(assistant.list.items.len, assistant.committed_len);
    try std.testing.expectEqual(revision_before_finalization + 1, workbench.revision);

    var terminal_snapshot_storage: [96 * 1024]u8 = undefined;
    const terminal_snapshot = try workbench.writeSnapshot(&terminal_snapshot_storage);
    try std.testing.expect(std.mem.indexOf(u8, terminal_snapshot, "tail SECRET-") != null);

    var late_event = try testEnvelope(3, 7, "{\"text_chunk\":\"late\"}");
    defer late_event.deinit();
    const revision_before_late_event = workbench.revision;
    try std.testing.expectError(
        error.EventAfterTerminalDrain,
        workbench.applyEvent(&late_event),
    );
    try std.testing.expectEqual(revision_before_late_event + 1, workbench.revision);
    try std.testing.expect(!continuationAvailable(workbench.tasks[0].?.continuation));
}

test "projection failure after Agent terminal becomes a product failure" {
    var workbench = try testWorkbench();
    defer workbench.deinit();
    const events = [_][]const u8{
        "{\"tool_start\":{\"id\":\"first\",\"name\":\"Read\",\"input\":\"one\"}}",
        "{\"tool_start\":{\"id\":\"second\",\"name\":\"Bash\",\"input\":\"two\"}}",
    };
    for (events) |encoded| {
        var envelope = try testEnvelope(3, 7, encoded);
        defer envelope.deinit();
        try workbench.applyEvent(&envelope);
    }

    const run = &workbench.tasks[0].?.runs[0].?;
    try std.testing.expect(commitTerminal(
        run,
        .completed,
        .completed,
        null,
        .reusable,
        "",
        false,
    ));
    var overflow = try testEnvelope(
        3,
        7,
        "{\"tool_start\":{\"id\":\"third\",\"name\":\"Edit\",\"input\":\"three\"}}",
    );
    defer overflow.deinit();
    try std.testing.expectError(error.ToolCapacity, workbench.applyEvent(&overflow));
    workbench.recordEventProjectionFailure(3, 7);
    finalizeTestTerminalEvents(&workbench);

    // Agent completion remains immutable; only Workbench product facts report
    // that the canonical event stream could not be represented completely.
    try std.testing.expectEqual(RunOutcome.completed, terminalPayload(run).?.outcome);
    const product = productTerminalFacts(run).?;
    try std.testing.expectEqual(RunOutcome.failed, product.outcome);
    try std.testing.expectEqual(RunCause.event_pipeline_failure, product.cause.?);
    try std.testing.expect(!continuationAvailable(workbench.tasks[0].?.continuation));

    var snapshot_storage: [96 * 1024]u8 = undefined;
    const snapshot = try workbench.writeSnapshot(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"phase\":\"failed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"lastRunOutcome\":\"failed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"cause\":\"event_pipeline_failure\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"continuationAvailable\":false") != null);
}

test "event drain barrier atomically publishes terminal product state" {
    var workbench = try testWorkbench();
    defer workbench.deinit();
    const run = &workbench.tasks[0].?.runs[0].?;

    try workbench.appendTrackedText(
        &run.assistant,
        "final assistant suffix",
        workbench.limits.max_assistant_message_bytes,
    );
    try std.testing.expect(commitTerminal(
        run,
        .failed,
        .failed,
        .timeout,
        .poisoned,
        "",
        false,
    ));

    try std.testing.expectError(error.TaskBusy, workbench.setTaskArchived(3, true));
    var pending_storage: [96 * 1024]u8 = undefined;
    const pending = try workbench.writeSnapshot(&pending_storage);
    try std.testing.expect(std.mem.indexOf(u8, pending, "\"phase\":\"running\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, pending, "\"lastRunOutcome\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, pending, "\"outcome\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, pending, "\"cause\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, pending, "\"continuationAvailable\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, pending, "final assistant suffix") == null);

    const revision_before_finalization = workbench.revision;
    finalizeTestTerminalEvents(&workbench);
    try std.testing.expect(workbench.revision > revision_before_finalization);

    var terminal_storage: [96 * 1024]u8 = undefined;
    const terminal = try workbench.writeSnapshot(&terminal_storage);
    try std.testing.expect(std.mem.indexOf(u8, terminal, "\"phase\":\"failed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, terminal, "\"lastRunOutcome\":\"failed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, terminal, "\"outcome\":\"failed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, terminal, "\"cause\":\"timeout\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, terminal, "\"continuationAvailable\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, terminal, "final assistant suffix") != null);
}

test "close and delete wait for terminal event drain" {
    const Harness = struct {
        fn complete() void {}
    };

    var workbench = try testWorkbench();
    defer workbench.deinit();
    const task = &workbench.tasks[0].?;
    const run = &task.runs[0].?;
    task.session = null;
    task.lifecycle = .closing;
    task.continuation = .{ .unavailable = .closing };
    task.close_thread = try std.Thread.spawn(.{}, Harness.complete, .{});
    task.close_completion.store(.closed, .release);
    try std.testing.expect(commitTerminal(
        run,
        .interrupted,
        .interrupted,
        .session_close,
        .closing,
        "",
        false,
    ));

    workbench.syncLifecycle();
    try std.testing.expectEqual(TaskLifecycle.closing, task.lifecycle);
    try std.testing.expect(task.close_thread != null);
    try std.testing.expectError(error.TaskNotClosed, workbench.deleteTask(3));

    var queued_event = try testEnvelope(3, 7, "{\"text_chunk\":\"queued before terminal\"}");
    defer queued_event.deinit();
    try workbench.applyEvent(&queued_event);

    finalizeTestTerminalEvents(&workbench);
    try std.testing.expectEqual(TaskLifecycle.closed, task.lifecycle);
    try std.testing.expect(task.close_thread == null);

    var late_event = try testEnvelope(3, 7, "{\"text_chunk\":\"late\"}");
    defer late_event.deinit();
    try std.testing.expectError(
        error.EventAfterTerminalDrain,
        workbench.applyEvent(&late_event),
    );
    try workbench.deleteTask(3);
    try std.testing.expect(workbench.tasks[0] == null);
}

test "streaming projection escaping is allocation-free JSON with redaction" {
    var workbench = try testWorkbench();
    defer workbench.deinit();
    var storage: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try workbench.projectedJsonValue(&writer, "quote\" slash\\ control\x01 line\n 界 SECRET-KEY");
    try std.testing.expectEqualStrings(
        "\"quote\\\" slash\\\\ control\\u0001 line\\n 界 ***\"",
        writer.buffered(),
    );
}

test "tool projection truncates on UTF-8 boundaries and records bounded UI history" {
    var workbench = try testWorkbench();
    defer workbench.deinit();

    const long = try std.testing.allocator.alloc(u8, workbench.limits.max_tool_field_bytes + 4);
    defer std.testing.allocator.free(long);
    @memset(long, 'x');
    @memcpy(long[long.len - 3 ..], "界");
    const projected = try workbench.copyProjected(
        long,
        workbench.limits.max_tool_field_bytes,
        workbench.execution.credential(),
    );
    defer workbench.freeTracked(projected.value);
    try std.testing.expect(projected.truncated);
    try std.testing.expect(std.unicode.utf8ValidateSlice(projected.value));

    const view = &workbench.tasks[0].?;
    for (1..11) |request_id| {
        var record = UiRecord{
            .request_id = request_id,
            .run_id = 7,
            .kind = .ask_question,
            .state = .answered,
        };
        const detail = sanitizeInto(&record.detail, "Continue?", "");
        record.detail_len = detail.len;
        workbench.pushUiRecord(view, record);
    }
    try std.testing.expectEqual(workbench.limits.max_ui_history_per_task, view.ui_history_count);
    var storage: [96 * 1024]u8 = undefined;
    const snapshot = try workbench.writeSnapshot(&storage);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"requestId\":\"1\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"requestId\":\"3\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"requestId\":\"10\"") != null);
}

test "Workbench rejects cross-session routes and usage overflow" {
    var workbench = try testWorkbench();
    defer workbench.deinit();

    var foreign_session = try testEnvelope(4, 7, "{\"text_chunk\":\"wrong\"}");
    defer foreign_session.deinit();
    try std.testing.expectError(error.UnknownTask, workbench.applyEvent(&foreign_session));

    var foreign_run = try testEnvelope(3, 8, "{\"text_chunk\":\"wrong\"}");
    defer foreign_run.deinit();
    try std.testing.expectError(error.NoSuchRun, workbench.applyEvent(&foreign_run));

    var maximum = try testEnvelope(3, 7, "{\"usage\":{\"input_tokens\":18446744073709551615}}");
    defer maximum.deinit();
    try workbench.applyEvent(&maximum);
    var overflow = try testEnvelope(3, 7, "{\"usage\":{\"input_tokens\":1}}");
    defer overflow.deinit();
    try std.testing.expectError(error.ProjectionCapacity, workbench.applyEvent(&overflow));
}

test "Workbench outcomes map to truthful terminal product phases" {
    try std.testing.expectEqual(RunPhase.completed, phaseForOutcome(.completed));
    try std.testing.expectEqual(RunPhase.stopped, phaseForOutcome(.stopped));
    try std.testing.expectEqual(RunPhase.cancelled, phaseForOutcome(.cancelled));
    try std.testing.expectEqual(RunPhase.interrupted, phaseForOutcome(.interrupted));
    try std.testing.expectEqual(RunPhase.failed, phaseForOutcome(.dependency_contract_failure));
}
