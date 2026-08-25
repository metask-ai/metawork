const std = @import("std");
const builtin = @import("builtin");
const lifecycle = @import("metawork_agent");
const account_contract = @import("metawork_account_contract");
const executor_impl = @import("workbench_executor");
const automatic_workspace_allocator = @import("workbench_automatic_workspace_allocator");
const scheduled_tasks_impl = @import("workbench_scheduled_tasks");
const scheduled_task_persistence = @import("workbench_scheduled_task_persistence");
const skill_management_impl = @import("workbench_skill_management");
const skill_enablement_impl = @import("workbench_skill_enablement");
const skill_package_impl = @import("metawork_product_skill").package;
const product_task = @import("metawork_product_task");
const task_persistence = product_task.persistence;
const TaskPersistenceCommit = task_persistence.Commit;
const TaskPersistence = task_persistence.Capability;
const TaskPersistenceHealth = task_persistence.Health;
const checkpoint_store = product_task.checkpoint_store;
const checkpoint_record = product_task.checkpoint_record;
const catalog_snapshot = @import("metawork_product_skill").catalog;
const owned_task_execution = product_task.execution_binding;
const task_agent_session = product_task.agent_session;
const task_runtime = product_task.runtime;
const task_deletion = product_task.deletion;
const task_recovery = product_task.recovery;
const task_recovery_job = product_task.recovery_job;
const task_model = product_task.state;
const task_policy = product_task.policy;
const task_view = product_task.view;
const product_mcp = @import("metawork_product_mcp");
const mcp_configuration = product_mcp.configuration;
const mcp_state = product_mcp.state;
const mcp_policy = product_mcp.policy;
const mcp_view = product_mcp.view;
const contract_fixture = @import("workbench_contract_fixture");
const build_options = @import("build_options");

pub const Error = lifecycle.Error || scheduled_tasks_impl.Error || scheduled_task_persistence.Error || skill_management_impl.Error || skill_enablement_impl.Error || skill_enablement_impl.FileStoreError || skill_package_impl.Error || task_persistence.Error || std.mem.Allocator.Error || std.Thread.SpawnError || error{
    ProjectionCapacity,
    RunCapacity,
    CompactCapacity,
    ToolCapacity,
    SnapshotTooLarge,
    CloseInProgress,
    TaskBusy,
    TaskNotArchived,
    InvalidTaskTitle,
    InvalidScheduledTaskInput,
    ScheduleTimerUnavailable,
    ScheduledTaskPersistenceUnavailable,
    ScheduledTaskPersistenceFailed,
    ScheduledTaskPersistenceOutcomeUnknown,
    TaskPersistenceUnavailable,
    TaskPersistenceFailed,
    TaskPersistenceOutcomeUnknown,
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
    TaskModelMismatch,
    InvalidTaskModel,
    BindingEpochMismatch,
    InvalidAutomationExecution,
    InvalidWorkspace,
    WorkspaceUnavailable,
    WorkspaceRemovalInProgress,
    WorkspaceEpochMismatch,
    WorkspaceEpochExhausted,
    CatalogLoading,
    CatalogUnavailable,
    McpManagementUnavailable,
    McpOauthScopeCapacity,
    CatalogRequestGenerationExhausted,
    StaleCatalog,
    SkillNotFound,
    SkillUnavailable,
    InvalidSkillArguments,
    RecoveryUnavailable,
    RestoreAttemptExhausted,
    UnsupportedBuiltinProfile,
    FileReferenceNotFound,
    FilePreviewMissing,
    FilePreviewRestricted,
    FilePreviewUnsupported,
    FilePreviewReadFailed,
};

pub const Limits = struct {
    worker_count: usize = 4,
    queue_capacity: usize = 16,
    max_tasks: usize = 50,
    max_workspaces: usize = 16,
    max_scheduled_tasks: usize = 16,
    max_skill_assets: usize = 256,
    max_runs_per_task: usize = 16,
    max_compacts_per_task: usize = 16,
    max_tools_per_run: usize = 32,
    // Must contain the maximum structural projection (every Task/Run/Compact
    // at capacity, including their eager terminal diagnostics) plus one full
    // assistant message; the budget test binds this floor exactly.
    max_projection_bytes: usize = 1536 * 1024,
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
    max_file_refs_per_tool: usize = 32,
    max_file_ref_field_bytes: usize = 8192,
    max_file_preview_bytes: usize = 256 * 1024,
    max_file_preview_line_bytes: usize = 8192,
    max_file_preview_lines: usize = 5000,
    max_pending_ui_json_bytes: usize = 256 * 1024,
    max_pending_ui_requests: usize = 4,
    max_ui_history_per_task: usize = 8,
    max_terminal_diagnostic_bytes: usize = 512,
    max_snapshot_bytes: usize = 64 * 1024 * 1024,
};

// Single Workbench-owned production source. Agent validates these product
// limits against the official ABI ceilings at the dependency boundary.
const checkpoint_export_limits: lifecycle.CheckpointLimits = .{
    .hard_bytes = 64 * 1024 * 1024,
    .max_section_bytes = 16 * 1024 * 1024,
    .max_string_bytes = 1024 * 1024,
    .max_messages = 4096,
    .max_blocks_per_message = 256,
    .chunk_bytes = 256 * 1024,
};

// Automatic titles are intentionally shorter than the durable Task title
// limit. Completion is best-effort metadata generation; the local candidate
// remains the deterministic fallback when it cannot produce a usable title.
const automatic_title_max_codepoints: usize = 32;
const automatic_title_result_capacity = task_model.automatic_title_result_capacity;
const automatic_title_timeout_ms: u32 = 15_000;
const automatic_title_watchdog_poll_ms: u32 = 10;
const automatic_title_system_prompt =
    "Generate a concise title for this task. Return only one plain-text title " ++
    "in the user's language, without quotes or Markdown. Use at most 32 Unicode characters.";

pub const Provider = task_model.Provider;

pub const TaskWorkspaceTrust = union(enum) {
    explicitly_trusted,
    temporary: []const u8,
};

pub const TaskCreateInput = struct {
    workspace_root: []const u8,
    trust: TaskWorkspaceTrust,
};

pub const TaskWorkspaceRequest = union(enum) {
    manual: struct {
        workspace_id: u64,
        expected_epoch: u64,
    },
    automatic,
};

pub const TaskRunInput = union(enum) {
    text: []const u8,
    skill: struct {
        skill_id: []const u8,
        catalog_revision: []const u8,
        selection_revision: u64,
        argument_values: []const []const u8,
    },
};

pub const ScheduledTaskRecurrence = scheduled_tasks_impl.Recurrence;

pub const ScheduledTaskDefinitionInput = struct {
    title: []const u8,
    expected_execution_generation: u64,
    input: []const u8,
    recurrence: ScheduledTaskRecurrence,
};

pub const WorkspaceAuthorization = enum {
    available,
    removing,
    reauthorization_required,
};

pub const WorkspaceKind = enum {
    manual,
    automatic,
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
    kind: WorkspaceKind,
    canonical_root: []const u8,
    display_name: []const u8,
    authorization: WorkspaceAuthorization,
    last_removal_failure: WorkspaceRemovalFailure,
    recent_order: u64,
    signals: WorkspaceSignals,
};

pub const CatalogAvailability = catalog_snapshot.CatalogAvailability;

pub const SkillProjection = catalog_snapshot.SkillProjection;
pub const CatalogIssueProjection = catalog_snapshot.CatalogIssueProjection;
pub const CatalogProjection = catalog_snapshot.CatalogProjection;

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
    allow_session,
    deny_once,
    deny_session,
};

pub const UiResponse = struct {
    permission: PermissionChoice,
};

pub const AppDirectories = struct {
    canonical_user_home: ?[]const u8 = null,
    automatic_workspace_root: ?*automatic_workspace_allocator.Root = null,
};

pub const SkillManagementHealth = enum {
    unavailable,
    ready,
    read_failed,
    corrupt,
    write_failed,
    outcome_unknown,
};

pub const SkillManagementConfiguration = struct {
    file_store: ?*skill_management_impl.FileStore = null,
    staging_root: ?[]const u8 = null,
    restored_bytes: ?[]const u8 = null,
    restore_failed: bool = false,
};

pub const SkillEnablementHealth = enum {
    unavailable,
    ready,
    read_failed,
    corrupt,
    write_failed,
    outcome_unknown,
};

pub const SkillEnablementConfiguration = struct {
    file_store: ?*skill_enablement_impl.FileStore = null,
    restored_bytes: ?[]const u8 = null,
    restore_failed: bool = false,
};

pub const SkillEnablementScope = union(enum) {
    personal,
    project: struct {
        workspace_id: u64,
        expected_workspace_epoch: u64,
    },
};

pub const SkillEnablementState = skill_enablement_impl.OverrideState;

pub const SkillEnablementMutation = struct {
    scope: SkillEnablementScope,
    skill_policy_key: []const u8,
    state: SkillEnablementState,
    expected_catalog_revision: []const u8,
    expected_selection_revision: u64,
};

pub const SkillInstallInput = struct {
    source_kind: skill_management_impl.SourceKind,
    scope: skill_management_impl.Scope,
    expected_invocation_name: []const u8,
    expected_content_hash: skill_management_impl.ContentHash,
    allow_replace: bool = false,
};

pub const SkillMutationResult = struct {
    install_id: skill_management_impl.InstallId,
    verification_pending: bool,
};

pub const SkillExportResult = struct {
    file_name: [skill_management_impl.max_target_entry_bytes + 6]u8,
    file_name_len: usize,

    pub fn fileName(self: *const SkillExportResult) []const u8 {
        return self.file_name[0..self.file_name_len];
    }
};

const SkillReconciliation = struct {
    install_id: skill_management_impl.InstallId,
    scope: skill_management_impl.Scope,
    invocation_name: [skill_management_impl.max_target_entry_bytes]u8,
    invocation_name_len: usize,
    operation: skill_management_impl.Operation,

    fn invocationName(self: *const SkillReconciliation) []const u8 {
        return self.invocation_name[0..self.invocation_name_len];
    }
};

pub const Configuration = struct {
    change_notifier: ChangeNotifier = .{},
    directories: AppDirectories = .{},
    schedule_timer: ScheduleTimer = .{},
    mcp_refresh_timer: McpRefreshTimer = .{},
    schedule_persistence: SchedulePersistence = .{},
    task_persistence: TaskPersistence = .{},
    checkpoint_store: CheckpointStoreConfiguration = .{},
    schedule_notifier: ScheduleNotifier = .{},
    skill_management: SkillManagementConfiguration = .{},
    skill_enablement: SkillEnablementConfiguration = .{},
    model_connections: ModelConnectionCapabilities = .{},
    mcp: McpStartupConfiguration = .{},
    completion_factory: CompletionFactory = .{},
};

pub const CompletionFactory = struct {
    context: ?*anyopaque = null,
    create_fn: ?*const fn (
        ?*anyopaque,
        std.mem.Allocator,
        lifecycle.CompletionConfig,
    ) anyerror!*lifecycle.Completion = null,

    fn create(
        self: CompletionFactory,
        allocator: std.mem.Allocator,
        config: lifecycle.CompletionConfig,
    ) anyerror!*lifecycle.Completion {
        if (self.create_fn) |create_fn|
            return create_fn(self.context, allocator, config);
        if (builtin.is_test) return error.CompletionUnavailable;
        return lifecycle.Completion.init(allocator, config);
    }
};

pub const ModelConnectionCapabilities = struct {
    management: bool = false,
    secret_capture: bool = false,
    connection_test: bool = false,
};

pub const CheckpointStoreConfiguration = struct {
    file_store: ?*checkpoint_store.FileStore = null,
    open_failed: bool = false,
};

pub const McpHostCapabilities = mcp_state.McpHostCapabilities;
pub const McpStartupConfiguration = mcp_state.McpStartupConfiguration;
pub const McpAdmissionBlockReason = mcp_state.McpAdmissionBlockReason;
const McpAdmissionReady = mcp_state.McpAdmissionReady;
const McpAdmissionAuthority = mcp_state.McpAdmissionAuthority;
const RecoveryMcpAuthority = mcp_state.RecoveryMcpAuthority;
pub const McpOauthRefreshBinding = mcp_state.McpOauthRefreshBinding;
pub const McpOauthRefreshBeginOutcome = mcp_state.McpOauthRefreshBeginOutcome;
pub const McpOauthAuthorizationPlan = mcp_state.McpOauthAuthorizationPlan;
pub const McpOauthAuthorizationBinding = mcp_state.McpOauthAuthorizationBinding;
pub const McpOauthAuthorizationOutcome = mcp_state.McpOauthAuthorizationOutcome;
pub const McpOauthOperationHandle = mcp_state.McpOauthOperationHandle;
pub const McpOauthCodeExchangeBinding = mcp_state.McpOauthCodeExchangeBinding;
pub const McpOauthOperationBeginOutcome = mcp_state.McpOauthOperationBeginOutcome;
pub const McpOauthCodeExchangeBeginOutcome = mcp_state.McpOauthCodeExchangeBeginOutcome;
pub const McpOauthExpiry = mcp_state.McpOauthExpiry;
pub const McpRuntimeAuthorizationFailure = mcp_state.McpRuntimeAuthorizationFailure;
pub const McpRuntimeAuthorizationFailureOutcome = mcp_state.McpRuntimeAuthorizationFailureOutcome;
pub const McpAuthorizationPhase = mcp_state.McpAuthorizationPhase;
pub const McpConnectionTestOutcome = mcp_state.McpConnectionTestOutcome;
pub const McpConfigurationApplyState = mcp_state.McpConfigurationApplyState;
const McpConnectionTest = mcp_state.McpConnectionTest;
pub const McpAuthorizationOperationView = mcp_state.McpAuthorizationOperationView;
pub const McpAuthorizationStart = mcp_state.McpAuthorizationStart;
pub const McpSecretCaptureTarget = mcp_state.McpSecretCaptureTarget;
const McpAuthorizationOperation = mcp_state.McpAuthorizationOperation;
pub const McpOauthRuntimeCommit = mcp_state.McpOauthRuntimeCommit;
const McpProductState = mcp_state.McpProductState;
pub const McpRefreshTimer = mcp_state.McpRefreshTimer;

const initialMcpAdmission = mcp_state.initialMcpAdmission;
const findMcpServer = mcp_state.findMcpServer;
const ownMcpScopeUnion = mcp_state.ownMcpScopeUnion;
const mcpRefreshDelayMs = mcp_state.mcpRefreshDelayMs;
const mcpRefreshDeadlineMs = mcp_state.mcpRefreshDeadlineMs;

fn textSetsEqual(left: []const []const u8, right: []const []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_value, right_value|
        if (!std.mem.eql(u8, left_value, right_value)) return false;
    return true;
}

fn writeQuotedField(
    writer: *std.Io.Writer,
    label: []const u8,
    value: []const u8,
) !void {
    try writer.print("{s}: ", .{label});
    try std.json.Stringify.value(value, .{}, writer);
    try writer.writeByte('\n');
}

fn writeQuotedListItem(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeAll("  ");
    try std.json.Stringify.value(value, .{}, writer);
    try writer.writeByte('\n');
}

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
const model_connection_snapshot_text_bytes: usize =
    account_contract.Limits.model_connection_entries *
    (account_contract.Limits.api_key_id_bytes +
        account_contract.Limits.display_name_bytes +
        account_contract.Limits.base_url_bytes +
        account_contract.Limits.model_id_bytes +
        account_contract.Limits.model_connection_model_entries *
            (account_contract.Limits.model_id_bytes +
                account_contract.Limits.model_display_name_bytes));
const account_snapshot_overhead: usize = 1024 +
    account_contract.Limits.api_key_entries * 128 +
    account_contract.Limits.model_entries * 128;
const model_connection_snapshot_overhead: usize = 1024 +
    account_contract.Limits.model_connection_entries * 256;
const workspace_snapshot_overhead: usize = 512;
const task_snapshot_overhead: usize = 1024;
const scheduled_task_snapshot_overhead: usize = 1024;
const skill_asset_snapshot_overhead: usize = 1024;
const run_snapshot_overhead: usize = 1024;
const compact_snapshot_overhead: usize = 512;
const catalog_snapshot_overhead: usize = 256;
const catalog_skill_snapshot_overhead: usize = 256;
const catalog_argument_snapshot_overhead: usize = 16;
const catalog_issue_snapshot_overhead: usize = 128;
const tool_snapshot_overhead: usize = 512;
const pending_ui_snapshot_overhead: usize = 8 * 1024;
const ui_record_detail_capacity = task_model.ui_record_detail_capacity;
const ui_record_snapshot_overhead: usize = 1024;
const tool_route_digest_bytes = task_model.tool_route_digest_bytes;
const tool_product_id_capacity = task_model.tool_product_id_capacity;
const ToolState = task_model.ToolState;
const RunPhase = task_model.RunPhase;
const RunOutcome = task_model.RunOutcome;
const CompactPhase = task_model.CompactPhase;
const CompactCause = task_model.CompactCause;
const CompactTerminationDispatch = task_model.CompactTerminationDispatch;
const ActiveOperation = task_model.ActiveOperation;
const RunCause = task_model.RunCause;
const TaskLifecycle = task_model.TaskLifecycle;
const ContinuationUnavailableReason = task_model.ContinuationUnavailableReason;
const ContinuationCapability = task_model.ContinuationCapability;
const CloseCompletion = task_model.CloseCompletion;

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

const TrackedText = task_model.TrackedText;
const permission_summary_field_capacity = task_model.permission_summary_field_capacity;
const PermissionSummary = task_model.PermissionSummary;

const ToolView = task_model.ToolView;
pub const FileReferencePositionView = task_model.FileReferencePositionView;
pub const FileReferenceRangeView = task_model.FileReferenceRangeView;

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

const FileReferenceLocatorKind = task_model.FileReferenceLocatorKind;

fn absoluteReferenceRelativePath(
    root: []const u8,
    absolute: []const u8,
    storage: []u8,
) ?[]const u8 {
    if (!std.fs.path.isAbsolute(absolute) or absolute.len <= root.len) return null;
    const same = if (builtin.os.tag == .windows)
        std.ascii.eqlIgnoreCase(root, absolute[0..root.len])
    else
        std.mem.eql(u8, root, absolute[0..root.len]);
    if (!same) return null;
    const separator = absolute[root.len];
    if (separator != '/' and separator != '\\') return null;
    const relative = absolute[root.len + 1 ..];
    if (relative.len == 0 or relative.len > storage.len) return null;
    @memcpy(storage[0..relative.len], relative);
    return storage[0..relative.len];
}

fn boundedPreviewCutoff(bytes: []const u8, max_lines: usize, max_line_bytes: usize) usize {
    var lines: usize = 1;
    var line_bytes: usize = 0;
    for (bytes, 0..) |byte, index| {
        if (byte == '\n') {
            lines += 1;
            line_bytes = 0;
            if (lines > max_lines) return index;
        } else {
            line_bytes += 1;
            if (line_bytes > max_line_bytes) return index;
        }
    }
    return bytes.len;
}

fn trimIncompleteUtf8Tail(bytes: []u8) []u8 {
    if (std.unicode.utf8ValidateSlice(bytes) or bytes.len == 0) return bytes;

    var suffix_start = bytes.len;
    var continuation_count: usize = 0;
    while (suffix_start > 0 and continuation_count < 3 and
        (bytes[suffix_start - 1] & 0xc0) == 0x80)
    {
        suffix_start -= 1;
        continuation_count += 1;
    }
    if (suffix_start == 0) return bytes;

    const lead_index = suffix_start - 1;
    const lead = bytes[lead_index];
    if (lead < 0xc2 or lead > 0xf4) return bytes;
    const sequence_len = std.unicode.utf8ByteSequenceLength(lead) catch return bytes;
    if (bytes.len - lead_index < sequence_len) return bytes[0..lead_index];
    return bytes;
}

/// Workbench-owned projection of AgentCore's typed file reference. The raw
/// locator is retained only on the Host side; snapshot serialization uses the
/// safe display path and opaque product id below.
const FileReferenceView = task_model.FileReferenceView;

pub const FilePreviewState = enum { ready, truncated, missing, restricted, unsupported, failed };

pub const FilePreview = struct {
    id: []u8,
    title: []u8,
    display_path: []u8,
    language: []u8,
    content: []u8,
    truncated: bool,
    range: ?FileReferenceRangeView,
    state: FilePreviewState,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *FilePreview) void {
        self.allocator.free(self.id);
        self.allocator.free(self.title);
        self.allocator.free(self.display_path);
        self.allocator.free(self.language);
        self.allocator.free(self.content);
        self.* = undefined;
    }
};

const UsageView = task_model.UsageView;
const TerminalPublication = task_model.TerminalPublication;
const EventProjectionFailure = task_model.EventProjectionFailure;
const AgentHandoffState = task_model.AgentHandoffState;
const RunTerminationDispatch = task_model.RunTerminationDispatch;
const PendingInterruption = task_model.PendingInterruption;
const TerminalPayload = task_model.TerminalPayload;
const CompactTerminalPayload = task_model.CompactTerminalPayload;
const RunInputRecord = task_model.RunInputRecord;
const CheckpointExportContext = task_model.CheckpointExportContext;
const RunRecord = task_model.RunRecord;
const AutomaticTitleState = task_model.AutomaticTitleState;
const AutomaticTitle = task_model.AutomaticTitle;
const CompactRecord = task_model.CompactRecord;

/// Executor-only resources for one queued or running Run. Product records keep
/// stable state and cancellation identity; this sidecar owns the composition
/// references needed only while the executor has the job.
const RunJobContext = struct {
    workbench: *Workbench,
    task: *TaskView,
    run: *RunRecord,
    access: ?task_agent_session.Access = null,

    fn sessionAccess(self: *@This()) *task_agent_session.Access {
        return if (self.access) |*value| value else unreachable;
    }

    fn releaseSessionAccess(self: *@This()) void {
        if (self.access) |*access| access.deinit();
        self.access = null;
    }

    fn destroy(self: *@This()) void {
        self.releaseSessionAccess();
        std.heap.c_allocator.destroy(self);
    }
};

/// Executor-only resources for one queued or running compact operation.
const CompactJobContext = struct {
    workbench: *Workbench,
    task: *TaskView,
    compact: *CompactRecord,
    access: ?task_agent_session.Access = null,

    fn sessionAccess(self: *@This()) *task_agent_session.Access {
        return if (self.access) |*value| value else unreachable;
    }

    fn destroy(self: *@This()) void {
        if (self.access) |*access| access.deinit();
        std.heap.c_allocator.destroy(self);
    }
};

const UiRecordKind = task_model.UiRecordKind;
const UiRecordState = task_model.UiRecordState;
const UiRecord = task_model.UiRecord;
const DurableTaskRecord = task_model.DurableTaskRecord;
const CheckpointAnchor = task_model.CheckpointAnchor;
const CheckpointAttempt = task_model.CheckpointAttempt;
const CheckpointPostprocessState = task_model.CheckpointPostprocessState;
const CheckpointCandidate = task_model.CheckpointCandidate;
const CheckpointPostprocessPayload = task_model.CheckpointPostprocessPayload;
const CheckpointPostprocess = task_model.CheckpointPostprocess;
const RuntimeAttachment = task_model.RuntimeAttachment;
const TaskView = task_model.Task;
const ProductTerminalFacts = task_model.ProductTerminalFacts;
const terminalPayload = task_model.terminalPayload;
const productTerminalPayload = task_model.productTerminalPayload;
const productTerminalFacts = task_model.productTerminalFacts;
const runPhase = task_model.runPhase;
const setActivePhase = task_model.setActivePhase;
const compactTerminalPayload = task_model.compactTerminalPayload;
const activeCompactPhase = task_model.activeCompactPhase;
const isTerminalPhase = task_model.isTerminalPhase;
const isTerminalCompactPhase = task_model.isTerminalCompactPhase;
const findRun = task_model.findRun;
const findCompact = task_model.findCompact;
const hasUnfinalizedTerminalEvents = task_model.hasUnfinalizedTerminalEvents;
const pendingInterruption = task_policy.pendingInterruption;
const pendingTerminationSignal = task_policy.pendingTerminationSignal;
const pendingExternalInterruption = task_policy.pendingExternalInterruption;
const compactCauseForInterruption = task_policy.compactCauseForInterruption;
const closeFailureCompletion = task_policy.closeFailureCompletion;
const classifyAgentTerminal = task_policy.classifyAgentTerminal;
const decisionForSignal = task_policy.decisionForSignal;
const lastTerminalFacts = task_policy.lastTerminalFacts;
const currentRunPhase = task_policy.currentRunPhase;
const hasActiveOperation = task_policy.hasActiveOperation;
const lastFinalizedRunId = task_policy.lastFinalizedRunId;
const latestCompactId = task_policy.latestCompactId;
const continuationAvailable = task_policy.continuationAvailable;
const taskLifecycle = task_policy.taskLifecycle;
const recoveryAttachment = task_policy.recoveryAttachment;
const recoveryOperation = task_policy.recoveryOperation;
const checkpointMatchesCurrentHistory = task_policy.checkpointMatchesCurrentHistory;
const foldTerminalDisposition = task_policy.foldTerminalDisposition;
const checkpointFailureAttempt = task_policy.checkpointFailureAttempt;

const TaskFailureRecord = struct {
    task_id: u64,
    recent_order: u64,
    reason: []u8,
};

test "Task aggregate separates Task runtime ownership from product history" {
    try std.testing.expect(@hasField(TaskView, "durable"));
    try std.testing.expect(@hasField(TaskView, "runtime"));
    try std.testing.expect(@hasField(TaskView, "deletion"));
    inline for (&.{
        "attachment",
        "worker_references",
        "close_thread",
        "active_operation",
    }) |field_name| {
        try std.testing.expect(@hasField(RuntimeAttachment, field_name));
        try std.testing.expect(!@hasField(DurableTaskRecord, field_name));
    }
    inline for (&.{
        "binding",
        "execution",
        "pinned_catalog",
    }) |field_name| {
        try std.testing.expect(@hasField(task_runtime.LiveAttachment, field_name));
        try std.testing.expect(!@hasField(RuntimeAttachment, field_name));
        try std.testing.expect(!@hasField(DurableTaskRecord, field_name));
    }
    try std.testing.expect(!@hasField(task_runtime.LiveAttachment, "session"));
    try std.testing.expect(!@hasField(task_runtime.LiveAttachment, "route_id"));
    try std.testing.expect(@hasField(task_runtime.ClosingAttachment, "route_id"));
    try std.testing.expect(@hasField(task_runtime.ClosingAttachment, "worker_binding"));
    try std.testing.expect(!@hasField(RuntimeAttachment, "lifecycle"));
    try std.testing.expect(!@hasField(RuntimeAttachment, "continuation"));
    try std.testing.expect(!@hasField(RuntimeAttachment, "deletion"));
    try std.testing.expect(!@hasField(DurableTaskRecord, "deletion"));
    inline for (&.{
        "id",
        "workspace_id",
        "binding_epoch",
        "title",
        "runs",
        "compacts",
        "ui_history",
    }) |field_name| {
        try std.testing.expect(@hasField(DurableTaskRecord, field_name));
        try std.testing.expect(!@hasField(RuntimeAttachment, field_name));
    }
}

const OwnedTaskExecution = owned_task_execution.OwnedTaskExecution;

const WorkspaceTrust = union(enum) {
    explicitly_trusted,
    temporary: []u8,
};

const CatalogSnapshot = catalog_snapshot.Snapshot;

const CatalogLeaseOwner = struct {
    agent: if (builtin.is_test) ?*lifecycle.CatalogLease else *lifecycle.CatalogLease,

    fn init(lease: *lifecycle.CatalogLease) CatalogLeaseOwner {
        return .{ .agent = lease };
    }

    fn fixture() CatalogLeaseOwner {
        comptime std.debug.assert(builtin.is_test);
        return .{ .agent = null };
    }

    fn borrow(self: CatalogLeaseOwner) ?*lifecycle.CatalogLease {
        return self.agent;
    }

    fn release(self: CatalogLeaseOwner, runtime: *lifecycle.Runtime) void {
        const lease = self.borrow() orelse return;
        runtime.releaseSkillCatalog(lease) catch
            @panic("Agent rejected a Workbench-owned Skill catalog lease");
    }
};

const CommittedSkillAuthority = struct {
    lease: CatalogLeaseOwner,
    snapshot: CatalogSnapshot,

    fn deinit(self: *CommittedSkillAuthority, runtime: *lifecycle.Runtime) void {
        self.snapshot.deinit();
        self.lease.release(runtime);
        self.* = undefined;
    }
};

const CatalogSlot = union(enum) {
    uninitialized,
    unavailable,
    committed: CommittedSkillAuthority,

    fn availability(self: *const CatalogSlot, refreshing: bool) CatalogAvailability {
        return switch (self.*) {
            .committed => |authority| switch (authority.snapshot.health) {
                .healthy => .ready,
                .degraded => .degraded,
            },
            .uninitialized => if (refreshing) .loading else .uninitialized,
            .unavailable => if (refreshing) .loading else .unavailable,
        };
    }

    fn snapshot(self: *CatalogSlot) ?*CatalogSnapshot {
        return switch (self.*) {
            .committed => |*authority| &authority.snapshot,
            .uninitialized, .unavailable => null,
        };
    }

    fn snapshotConst(self: *const CatalogSlot) ?*const CatalogSnapshot {
        return switch (self.*) {
            .committed => |*authority| &authority.snapshot,
            .uninitialized, .unavailable => null,
        };
    }

    fn lease(self: *const CatalogSlot) ?*lifecycle.CatalogLease {
        return switch (self.*) {
            .committed => |authority| authority.lease.borrow(),
            .uninitialized, .unavailable => null,
        };
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

const McpRefreshJobOutcome = union(enum) {
    empty,
    activated: struct {
        activation: *lifecycle.McpActivation,
        selection: ?*lifecycle.McpSelection,
    },
    unavailable,
};

const McpRefreshJob = struct {
    allocator: std.mem.Allocator,
    runtime: *lifecycle.Runtime,
    notifier: ChangeNotifier,
    request_generation: u64,
    requested_at_ms: ?u64,
    arena: std.heap.ArenaAllocator,
    allowlists: []const lifecycle.McpServerAllowlist,
    build_admission: bool,
    state: std.atomic.Value(CatalogJobState) = .init(.queued),
    outcome: McpRefreshJobOutcome = .unavailable,

    fn deinit(self: *McpRefreshJob) void {
        switch (self.outcome) {
            .activated => |activated| {
                if (activated.selection) |selection| selection.deinit();
                activated.activation.deinit();
            },
            .empty, .unavailable => {},
        }
        self.arena.deinit();
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }
};

const WorkspaceView = struct {
    id: u64,
    kind: WorkspaceKind = .manual,
    automatic_task_id: u64 = 0,
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
    catalog_slot: CatalogSlot = .uninitialized,
    catalog_request_generation: u64 = 0,
    catalog_job: ?*CatalogJob = null,
    catalog_reschedule_pending: bool = false,
};

const ExistingWorkspaceState = struct {
    trust: WorkspaceTrust,
    authorization: WorkspaceAuthorization,
    visible: bool,
    epoch: u64,
    recent_order: u64,
};

const WorkspaceUpsert = struct {
    index: usize,
    reauthorizing: bool = false,
    previous: union(enum) {
        existing: ExistingWorkspaceState,
        created: struct {
            next_workspace_id: u64,
            replaced: ?WorkspaceView,
        },
    },
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

const ModelConnectionProjection = struct {
    id: FixedText(account_contract.Limits.api_key_id_bytes) = .{},
    display_name: FixedText(account_contract.Limits.display_name_bytes) = .{},
    normalized_base_url: FixedText(account_contract.Limits.base_url_bytes) = .{},
    protocol: account_contract.ModelConnectionProtocol = .anthropic_messages,
    state: account_contract.ModelConnectionState = .configuring,
    test_status: account_contract.ModelConnectionTestStatus = .untested,
    credential_status: account_contract.ModelConnectionCredentialStatus = .missing,
    enabled: bool = false,
    selected_model: FixedText(account_contract.Limits.model_id_bytes) = .{},
    connection_generation: u64 = 0,
    models: std.ArrayList(ModelProjection) = .empty,

    fn deinit(self: *ModelConnectionProjection, allocator: std.mem.Allocator) void {
        self.models.deinit(allocator);
        self.* = undefined;
    }
};

const AccountProjection = struct {
    allocator: std.mem.Allocator,
    state: account_contract.AccountState = .checking,
    catalog_state: account_contract.CatalogState = .unavailable,
    can_cancel: bool = false,
    account_id: FixedText(account_contract.Limits.account_id_bytes) = .{},
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
    model_connections: []ModelConnectionProjection,
    model_connection_views: std.ArrayList(account_contract.ModelConnectionView) = .empty,
    model_connection_model_views: std.ArrayList(account_contract.ModelConnectionModelView) = .empty,
    model_connection_count: usize = 0,
    account_can_create_task: bool = false,
    error_code: account_contract.ErrorCode = .none,
    catalog_generation: u64 = 0,
    metask_execution_generation: u64 = 0,
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
        const model_connections = try allocator.alloc(
            ModelConnectionProjection,
            account_contract.Limits.model_connection_entries,
        );
        errdefer allocator.free(model_connections);
        @memset(model_connections, .{});
        return .{
            .allocator = allocator,
            .api_keys = api_keys,
            .api_key_views = api_key_views,
            .models = models,
            .model_views = model_views,
            .model_connections = model_connections,
        };
    }

    fn deinit(self: *AccountProjection) void {
        for (self.model_connections[0..self.model_connection_count]) |*connection|
            connection.deinit(self.allocator);
        self.model_connection_model_views.deinit(self.allocator);
        self.model_connection_views.deinit(self.allocator);
        self.allocator.free(self.model_connections);
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
        std.debug.assert(source_view.model_connections.len <= self.model_connections.len);
        for (self.model_connections[0..self.model_connection_count]) |*connection|
            connection.deinit(self.allocator);
        self.model_connection_count = 0;
        self.state = source_view.state;
        self.catalog_state = source_view.catalog_state;
        self.can_cancel = source_view.can_cancel;
        self.account_id.setNoFail(source_view.account_id);
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
        for (source_view.model_connections, self.model_connections[0..source_view.model_connections.len]) |source, *target| {
            target.* = .{
                .protocol = source.protocol,
                .state = source.state,
                .test_status = source.test_status,
                .credential_status = source.credential_status,
                .enabled = source.enabled,
                .connection_generation = source.connection_generation,
            };
            target.id.setNoFail(source.id);
            target.display_name.setNoFail(source.display_name);
            target.normalized_base_url.setNoFail(source.normalized_base_url);
            target.selected_model.setNoFail(source.selected_model);
            for (source.models) |model| {
                var owned: ModelProjection = .{};
                owned.id.setNoFail(model.id);
                owned.display_name.setNoFail(model.display_name);
                target.models.append(self.allocator, owned) catch
                    @panic("model connection projection capacity exhausted");
            }
        }
        self.model_connection_count = source_view.model_connections.len;
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
        self.metask_execution_generation = source_view.metask_execution_generation;
        self.execution_generation = source_view.execution_generation;
    }

    fn view(
        self: *const AccountProjection,
        can_create_task: bool,
    ) account_contract.AccountView {
        const mutable = @constCast(self);
        mutable.model_connection_views.clearRetainingCapacity();
        mutable.model_connection_model_views.clearRetainingCapacity();
        var model_count: usize = 0;
        for (self.model_connections[0..self.model_connection_count]) |connection|
            model_count += connection.models.items.len;
        mutable.model_connection_views.ensureTotalCapacity(self.allocator, self.model_connection_count) catch
            @panic("model connection view capacity exhausted");
        mutable.model_connection_model_views.ensureTotalCapacity(self.allocator, model_count) catch
            @panic("model connection view capacity exhausted");
        for (self.model_connections[0..self.model_connection_count]) |connection| {
            const start = mutable.model_connection_model_views.items.len;
            for (connection.models.items) |model|
                mutable.model_connection_model_views.append(self.allocator, .{
                    .id = model.id.view(),
                    .display_name = model.display_name.view(),
                }) catch @panic("model connection view capacity exhausted");
            const end = mutable.model_connection_model_views.items.len;
            mutable.model_connection_views.append(self.allocator, .{
                .id = connection.id.view(),
                .display_name = connection.display_name.view(),
                .protocol = connection.protocol,
                .normalized_base_url = connection.normalized_base_url.view(),
                .state = connection.state,
                .test_status = connection.test_status,
                .credential_status = connection.credential_status,
                .enabled = connection.enabled,
                .models = mutable.model_connection_model_views.items[start..end],
                .selected_model = connection.selected_model.view(),
                .connection_generation = connection.connection_generation,
            }) catch @panic("model connection view capacity exhausted");
        }
        return .{
            .state = self.state,
            .catalog_state = self.catalog_state,
            .can_cancel = self.can_cancel,
            .account_id = self.account_id.view(),
            .display_name = self.display_name.view(),
            .api_keys = self.api_key_views[0..self.api_key_count],
            .models = self.model_views[0..self.model_count],
            .model_connections = mutable.model_connection_views.items,
            .selected_api_key_id = self.selected_api_key_id.view(),
            .selected_model = self.selected_model.view(),
            .candidate_api_key_id = self.candidate_api_key_id.view(),
            .candidate_model = self.candidate_model.view(),
            .model_catalog_api_key_id = self.model_catalog_api_key_id.view(),
            .can_create_task = can_create_task,
            .error_code = self.error_code,
            .safe_diagnostic = self.safe_diagnostic.view(),
            .catalog_generation = self.catalog_generation,
            .metask_execution_generation = self.metask_execution_generation,
            .execution_generation = self.execution_generation,
        };
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
        const validation = if (execution.model_connection)
            account_contract.validateModelConnectionExecutionConfig(input)
        else
            account_contract.validateExecutionConfig(input);
        validation catch
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
const ExecutionReplacementKind = enum { none, default, identity };

pub const PreparedModelConnectionBinding = struct {
    allocator: std.mem.Allocator,
    connection_id: []u8,
    model_id: []u8,

    fn init(
        allocator: std.mem.Allocator,
        connection_id: []const u8,
        model_id: []const u8,
    ) std.mem.Allocator.Error!PreparedModelConnectionBinding {
        return .{
            .allocator = allocator,
            .connection_id = try allocator.dupe(u8, connection_id),
            .model_id = try allocator.dupe(u8, model_id),
        };
    }

    pub fn deinit(self: *PreparedModelConnectionBinding) void {
        self.allocator.free(self.model_id);
        self.allocator.free(self.connection_id);
        self.* = undefined;
    }
};

const CustomExecutionBinding = PreparedModelConnectionBinding;

pub const Workbench = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    agent_runtime: *lifecycle.Runtime,
    limits: Limits,
    workspaces: []?WorkspaceView,
    tasks: []?TaskView,
    task_failures: std.ArrayList(TaskFailureRecord),
    task_persistence: TaskPersistence,
    task_persistence_health: TaskPersistenceHealth,
    /// Bounded diagnostic count of canonical Agent events that arrived after
    /// their Run's terminal drain was finalized. Runtime-only evidence for
    /// the Stop-barrier investigation; never persisted or published.
    late_terminal_event_count: u64 = 0,
    checkpoint_store: ?*checkpoint_store.FileStore,
    checkpoint_store_health: std.atomic.Value(checkpoint_store.Health),
    scheduled_tasks: scheduled_tasks_impl.Store,
    skill_inventory: ?skill_management_impl.Inventory,
    skill_transactions: ?skill_management_impl.Transactions,
    skill_management_health: SkillManagementHealth,
    skill_enablement: skill_enablement_impl.Store,
    skill_enablement_file_store: ?*skill_enablement_impl.FileStore,
    skill_enablement_health: SkillEnablementHealth,
    skill_staging_root: ?[]u8,
    skill_reconciliation: ?SkillReconciliation = null,
    schedule_timer: ScheduleTimer,
    mcp_refresh_timer: McpRefreshTimer,
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
    automatic_workspaces: ?automatic_workspace_allocator.Allocator,
    skill_catalog_slot: CatalogSlot = .uninitialized,
    skill_catalog_request_generation: u64 = 0,
    skill_catalog_job: ?*CatalogJob = null,
    execution_replacement: ExecutionReplacementKind = .none,
    custom_execution_binding: ?CustomExecutionBinding = null,
    model_connection_capabilities: ModelConnectionCapabilities,
    completion_factory: CompletionFactory,
    mcp: ?McpProductState = null,
    mcp_refresh_job: ?*McpRefreshJob = null,
    next_workspace_id: u64 = 1,
    next_workspace_recent_order: u64 = 1,
    next_task_id: u64 = 1,
    next_task_recent_order: u64 = 1,
    next_restore_attempt_id: u64 = 1,
    recovery_poisoned: bool = false,
    agent_runtime_shutdown_complete: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        agent_runtime: *lifecycle.Runtime,
        limits: Limits,
        configuration: Configuration,
    ) Error!Workbench {
        if (limits.worker_count == 0 or limits.queue_capacity == 0 or
            limits.max_tasks == 0 or limits.max_workspaces == 0 or
            limits.max_scheduled_tasks == 0 or
            limits.max_skill_assets == 0 or
            limits.max_runs_per_task == 0 or
            limits.max_compacts_per_task == 0 or
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
                io,
                home,
                allocator,
            ) catch return error.InvalidWorkspace;
            defer allocator.free(resolved);
            if (!std.mem.eql(u8, resolved, home)) return error.InvalidWorkspace;
            break :home_copy try allocator.dupe(u8, home);
        } else null;
        errdefer if (canonical_user_home) |home| allocator.free(home);
        var automatic_workspaces = if (configuration.directories.automatic_workspace_root) |root|
            automatic_workspace_allocator.Allocator.init(root)
        else
            null;
        errdefer if (automatic_workspaces) |*store| store.deinit();
        const workspace_capacity = workspaceRecordCapacity(limits) orelse
            return error.ProjectionCapacity;
        const workspaces = try allocator.alloc(?WorkspaceView, workspace_capacity);
        errdefer allocator.free(workspaces);
        @memset(workspaces, null);
        const tasks = try allocator.alloc(?TaskView, limits.max_tasks);
        errdefer allocator.free(tasks);
        @memset(tasks, null);
        var task_persistence_health: TaskPersistenceHealth =
            if (configuration.task_persistence.enabled) .ready else .unavailable;
        if (configuration.task_persistence.restore_failed)
            task_persistence_health = .read_failed;
        const checkpoint_store_health: checkpoint_store.Health =
            if (configuration.checkpoint_store.file_store != null and
            !configuration.checkpoint_store.open_failed)
                .ready
            else
                .unavailable;
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
        var skill_management_health: SkillManagementHealth =
            if (configuration.skill_management.file_store != null and
            configuration.skill_management.staging_root != null)
                .ready
            else
                .unavailable;
        if (configuration.skill_management.restore_failed)
            skill_management_health = .read_failed;
        var skill_inventory = if (skill_management_health == .ready and
            configuration.skill_management.restored_bytes != null)
            skill_management_impl.decode(
                allocator,
                configuration.skill_management.restored_bytes.?,
                .{ .max_assets = limits.max_skill_assets },
            ) catch restore: {
                skill_management_health = .corrupt;
                break :restore skill_management_impl.Inventory.init(
                    allocator,
                    .{ .max_assets = limits.max_skill_assets },
                );
            }
        else
            skill_management_impl.Inventory.init(
                allocator,
                .{ .max_assets = limits.max_skill_assets },
            );
        var skill_inventory_owned = true;
        errdefer if (skill_inventory_owned) skill_inventory.deinit();
        var skill_transactions: ?skill_management_impl.Transactions =
            if (configuration.skill_management.file_store) |file_store|
                skill_management_impl.Transactions.init(
                    io,
                    allocator,
                    skill_inventory,
                    file_store,
                )
            else
                null;
        if (skill_transactions != null) skill_inventory_owned = false;
        errdefer if (skill_transactions) |*transactions| transactions.deinit();
        const skill_staging_root = if (skill_management_health == .ready) root: {
            const configured = configuration.skill_management.staging_root.?;
            if (!std.fs.path.isAbsolute(configured) or
                !std.unicode.utf8ValidateSlice(configured))
            {
                skill_management_health = .read_failed;
                break :root null;
            }
            const dir = std.Io.Dir.cwd().createDirPathOpen(
                io,
                configured,
                .{ .open_options = .{ .follow_symlinks = false } },
            ) catch {
                skill_management_health = .read_failed;
                break :root null;
            };
            defer dir.close(io);
            var canonical_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const canonical_len = dir.realPath(
                io,
                &canonical_storage,
            ) catch {
                skill_management_health = .read_failed;
                break :root null;
            };
            break :root try allocator.dupe(u8, canonical_storage[0..canonical_len]);
        } else null;
        errdefer if (skill_staging_root) |root| allocator.free(root);
        const skill_enablement_limits: skill_enablement_impl.Limits = .{
            .max_workspaces = limits.max_workspaces,
            .max_policy_keys = limits.max_catalog_skills,
            .max_policy_key_bytes = limits.max_tool_field_bytes,
        };
        var skill_enablement_health: SkillEnablementHealth =
            if (configuration.skill_enablement.file_store != null)
                .ready
            else
                .unavailable;
        if (configuration.skill_enablement.restore_failed)
            skill_enablement_health = .read_failed;
        var skill_enablement = if (skill_enablement_health == .ready and
            configuration.skill_enablement.restored_bytes != null)
            skill_enablement_impl.decode(
                allocator,
                configuration.skill_enablement.restored_bytes.?,
                skill_enablement_limits,
            ) catch restore: {
                skill_enablement_health = .corrupt;
                break :restore try skill_enablement_impl.Store.init(
                    allocator,
                    skill_enablement_limits,
                );
            }
        else
            try skill_enablement_impl.Store.init(
                allocator,
                skill_enablement_limits,
            );
        var skill_enablement_owned = true;
        errdefer if (skill_enablement_owned) skill_enablement.deinit();
        var mcp_management: ?mcp_configuration.ManagementPort =
            if (configuration.mcp.preparation) |preparation|
                if (configuration.mcp.management) |management|
                    try mcp_configuration.ManagementPort.init(
                        allocator,
                        if (preparation.registry) |registry| registry.value else null,
                        management,
                    )
                else
                    null
            else
                null;
        errdefer if (mcp_management) |*management| management.deinit();
        const executor = executor_impl.Executor.create(io, allocator, .{
            .worker_count = limits.worker_count,
            .queue_capacity = limits.queue_capacity,
        }) catch |err| switch (err) {
            error.InvalidLimits => unreachable,
            else => return err,
        };
        var workbench: Workbench = .{
            .allocator = allocator,
            .io = io,
            .agent_runtime = agent_runtime,
            .limits = limits,
            .workspaces = workspaces,
            .tasks = tasks,
            .task_failures = .empty,
            .task_persistence = configuration.task_persistence,
            .task_persistence_health = task_persistence_health,
            .checkpoint_store = configuration.checkpoint_store.file_store,
            .checkpoint_store_health = .init(checkpoint_store_health),
            .scheduled_tasks = scheduled_tasks,
            .skill_inventory = if (skill_transactions == null)
                skill_inventory
            else
                null,
            .skill_transactions = skill_transactions,
            .skill_management_health = skill_management_health,
            .skill_enablement = skill_enablement,
            .skill_enablement_file_store = configuration.skill_enablement.file_store,
            .skill_enablement_health = skill_enablement_health,
            .skill_staging_root = skill_staging_root,
            .schedule_timer = configuration.schedule_timer,
            .mcp_refresh_timer = configuration.mcp_refresh_timer,
            .schedule_persistence = configuration.schedule_persistence,
            .schedule_persistence_health = schedule_persistence_health,
            .schedule_notifier = configuration.schedule_notifier,
            .change_notifier = configuration.change_notifier,
            .executor = executor,
            .account = account,
            .execution = execution,
            .canonical_user_home = canonical_user_home,
            .automatic_workspaces = automatic_workspaces,
            .model_connection_capabilities = configuration.model_connections,
            .completion_factory = configuration.completion_factory,
        };
        if (workbench.skill_inventory != null) skill_inventory_owned = false;
        skill_enablement_owned = false;
        skill_transactions = null;
        if ((workbench.task_persistence_health == .ready or
            workbench.task_persistence_health == .degraded) and
            configuration.task_persistence.restored_bytes != null)
        {
            workbench.restoreTaskState(
                configuration.task_persistence.restored_bytes.?,
            ) catch |err| {
                workbench.clearRestoredTaskStateNoFail();
                switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => workbench.task_persistence_health = .corrupt,
                }
            };
        }
        workbench.reconcileCheckpointStoreNoFail();
        workbench.reconcileSkillEnablementNoFail();
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
        workbench.recoverSkillTransactionsForScopeNoFail(.personal);
        workbench.scheduleSkillCatalogQuery() catch
            workbench.markSkillCatalogUnavailable();
        // This is the last ownership move in init: no later operation may fail.
        // The first health observation is committed before App exposes Bridge
        // ingress or loads the Renderer window.
        if (configuration.mcp.preparation) |preparation| {
            const admission = initialMcpAdmission(
                configuration.mcp.activation,
                configuration.mcp.activation_failed,
                if (mcp_management) |*management| management else null,
            );
            workbench.mcp = .{
                .preparation = preparation.take(),
                .activation = configuration.mcp.activation,
                .activation_failed = configuration.mcp.activation_failed,
                .management = mcp_management,
                .admission = admission,
                .host_capabilities = configuration.mcp.host_capabilities,
            };
            mcp_management = null;
            _ = workbench.syncMcpHealthNoFail();
            workbench.updateMcpRefreshDeadlineNoFail();
            workbench.rearmMcpRefreshTimerNoFail();
        }
        return workbench;
    }

    /// Re-authorizes a projected file reference and returns a bounded UTF-8
    /// preview. Renderer callers only provide the opaque product id; locator
    /// and workspace ownership remain inside Workbench.
    pub fn previewFileReference(self: *Workbench, reference_id: []const u8) Error!FilePreview {
        const Match = struct { reference: *const FileReferenceView, task: *const TaskView };
        var match: ?Match = null;
        for (self.tasks) |*task_entry| {
            const task = &(task_entry.* orelse continue);
            for (task.durable.runs) |*run_entry| {
                const run = &(run_entry.* orelse continue);
                for (run.tools) |*tool_entry| {
                    const tool = &(tool_entry.* orelse continue);
                    const references = tool.file_refs orelse continue;
                    for (references) |*reference_entry| {
                        if (reference_entry.*) |*reference|
                            if (std.mem.eql(u8, reference.id, reference_id)) {
                                match = .{ .reference = reference, .task = task };
                                break;
                            };
                    }
                    if (match != null) break;
                }
                if (match != null) break;
            }
            if (match != null) break;
        }
        const found = match orelse return error.FileReferenceNotFound;
        const reference = found.reference;
        var workspace_valid = false;
        for (self.workspaces) |*workspace_entry| {
            const workspace = workspace_entry.* orelse continue;
            if (workspace.id == found.task.durable.workspace_id) {
                workspace_valid = workspace.epoch == found.task.durable.workspace_epoch and
                    std.mem.eql(u8, workspace.canonical_root, found.task.durable.workspace_root);
                break;
            }
        }
        if (!workspace_valid) return error.FilePreviewRestricted;
        if (reference.locator_kind == .uri) return error.FilePreviewUnsupported;

        var relative_storage: [4096]u8 = undefined;
        const relative = switch (reference.locator_kind) {
            .workspace_path => reference.locator,
            .absolute_path => absoluteReferenceRelativePath(
                found.task.durable.workspace_root,
                reference.locator,
                &relative_storage,
            ) orelse return error.FilePreviewRestricted,
            .uri => unreachable,
        };
        if (relative.len == 0 or relative.len > relative_storage.len)
            return error.FilePreviewRestricted;

        var root = std.Io.Dir.openDirAbsolute(self.io, found.task.durable.workspace_root, .{
            .access_sub_paths = true,
            .follow_symlinks = false,
        }) catch return error.FilePreviewRestricted;
        defer root.close(self.io);
        var file = root.openFile(self.io, relative, .{
            .allow_directory = false,
            .follow_symlinks = false,
            .resolve_beneath = true,
        }) catch |err| return switch (err) {
            error.FileNotFound, error.NotDir => error.FilePreviewMissing,
            else => error.FilePreviewRestricted,
        };
        defer file.close(self.io);
        if (builtin.os.tag == .windows) file.flags.nonblocking = true;
        const length = file.length(self.io) catch return error.FilePreviewReadFailed;
        if (length > self.limits.max_file_preview_bytes) {
            const bytes = try self.allocator.alloc(u8, self.limits.max_file_preview_bytes);
            var bytes_owned = true;
            defer if (bytes_owned) self.allocator.free(bytes);
            const read = file.readPositionalAll(self.io, bytes, 0) catch return error.FilePreviewReadFailed;
            if (read != bytes.len) return error.FilePreviewUnsupported;
            const complete_bytes = trimIncompleteUtf8Tail(bytes);
            if (!std.unicode.utf8ValidateSlice(complete_bytes))
                return error.FilePreviewUnsupported;
            const preview = try self.finishFilePreview(reference, complete_bytes, true);
            if (preview.content.ptr == bytes.ptr) bytes_owned = false;
            return preview;
        }
        const bytes = try self.allocator.alloc(u8, @intCast(length));
        var bytes_owned = true;
        defer if (bytes_owned) self.allocator.free(bytes);
        const read = file.readPositionalAll(self.io, bytes, 0) catch return error.FilePreviewReadFailed;
        if (read != bytes.len or !std.unicode.utf8ValidateSlice(bytes))
            return error.FilePreviewUnsupported;
        const preview = try self.finishFilePreview(reference, bytes, false);
        if (preview.content.ptr == bytes.ptr) bytes_owned = false;
        return preview;
    }

    fn finishFilePreview(
        self: *Workbench,
        reference: *const FileReferenceView,
        bytes: []u8,
        truncated: bool,
    ) Error!FilePreview {
        const cutoff = boundedPreviewCutoff(
            bytes,
            self.limits.max_file_preview_lines,
            self.limits.max_file_preview_line_bytes,
        );
        const safe_cutoff = if (cutoff < bytes.len)
            trimIncompleteUtf8Tail(bytes[0..cutoff]).len
        else
            cutoff;
        var content = bytes;
        var content_truncated = truncated;
        var content_is_owned = false;
        errdefer if (content_is_owned) self.allocator.free(content);
        if (safe_cutoff < bytes.len) {
            content = try self.allocator.alloc(u8, safe_cutoff);
            @memcpy(content, bytes[0..safe_cutoff]);
            content_is_owned = true;
            content_truncated = true;
        }
        const id = try self.copyPreviewBounded(reference.id, self.limits.max_file_ref_field_bytes);
        errdefer self.allocator.free(id);
        const title = try self.copyPreviewBounded(reference.title, self.limits.max_file_ref_field_bytes);
        errdefer self.allocator.free(title);
        const display_path = try self.copyPreviewBounded(
            reference.display_path,
            self.limits.max_file_ref_field_bytes,
        );
        errdefer self.allocator.free(display_path);
        const extension = std.fs.path.extension(reference.display_path);
        const language = if (extension.len > 1) extension[1..] else "text";
        const language_copy = try self.copyPreviewBounded(language, 64);
        errdefer self.allocator.free(language_copy);
        content_is_owned = false;
        return .{
            .id = id,
            .title = title,
            .display_path = display_path,
            .language = language_copy,
            .content = content,
            .truncated = content_truncated,
            .range = reference.range,
            .state = if (content_truncated) .truncated else .ready,
            .allocator = self.allocator,
        };
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

    pub fn previewSkillDirectory(
        self: *Workbench,
        absolute_path: []const u8,
    ) Error!skill_package_impl.Preview {
        if (self.skill_management_health != .ready or self.shutting_down)
            return error.PersistenceFailed;
        if (!std.fs.path.isAbsolute(absolute_path) or
            !std.unicode.utf8ValidateSlice(absolute_path))
            return error.InvalidAsset;
        const source = std.Io.Dir.openDirAbsolute(
            self.io,
            absolute_path,
            .{ .follow_symlinks = false, .iterate = true },
        ) catch return error.InvalidAsset;
        defer source.close(self.io);
        return skill_package_impl.previewDirectory(
            self.io,
            self.allocator,
            source,
            .{},
        );
    }

    pub fn previewSkillArchive(
        self: *Workbench,
        absolute_path: []const u8,
    ) Error!skill_package_impl.Preview {
        if (self.skill_management_health != .ready or self.shutting_down)
            return error.PersistenceFailed;
        if (!std.fs.path.isAbsolute(absolute_path) or
            !std.unicode.utf8ValidateSlice(absolute_path) or
            !hasSkillArchiveExtension(absolute_path))
            return error.InvalidAsset;
        const archive = std.Io.Dir.openFileAbsolute(
            self.io,
            absolute_path,
            .{ .follow_symlinks = false },
        ) catch return error.InvalidAsset;
        defer archive.close(self.io);
        const inspection = skill_package_impl.inspectArchive(
            self.io,
            self.allocator,
            archive,
            .{},
        ) catch return error.InvalidAsset;
        const staging_path = self.skill_staging_root orelse
            return error.PersistenceFailed;
        const staging = std.Io.Dir.openDirAbsolute(
            self.io,
            staging_path,
            .{ .follow_symlinks = false },
        ) catch return error.PersistenceFailed;
        defer staging.close(self.io);
        var random: [16]u8 = undefined;
        std.Io.randomSecure(self.io, &random) catch
            return error.PersistenceFailed;
        const hex = std.fmt.bytesToHex(random, .lower);
        var scratch_name: [47]u8 = undefined;
        @memcpy(scratch_name[0..15], ".skill-preview-");
        @memcpy(scratch_name[15..], &hex);
        staging.createDir(
            self.io,
            &scratch_name,
            privateDirectoryPermissions(),
        ) catch return error.PersistenceFailed;
        defer staging.deleteTree(self.io, &scratch_name) catch {};
        const scratch = staging.openDir(self.io, &scratch_name, .{
            .follow_symlinks = false,
        }) catch return error.PersistenceFailed;
        defer scratch.close(self.io);
        skill_package_impl.extractArchive(
            self.io,
            archive,
            scratch,
        ) catch return error.InvalidAsset;
        const source = if (inspection.wrapperName()) |wrapper|
            scratch.openDir(self.io, wrapper, .{
                .follow_symlinks = false,
            }) catch return error.InvalidAsset
        else
            scratch;
        defer if (inspection.wrapperName() != null)
            source.close(self.io);
        return skill_package_impl.previewDirectory(
            self.io,
            self.allocator,
            source,
            .{},
        ) catch return error.InvalidAsset;
    }

    pub fn installSkillDirectory(
        self: *Workbench,
        absolute_path: []const u8,
        input: SkillInstallInput,
    ) Error!SkillMutationResult {
        if (input.source_kind != .local_directory) return error.InvalidAsset;
        if (!std.fs.path.isAbsolute(absolute_path) or
            !std.unicode.utf8ValidateSlice(absolute_path))
            return error.InvalidAsset;
        const source = std.Io.Dir.openDirAbsolute(
            self.io,
            absolute_path,
            .{ .follow_symlinks = false, .iterate = true },
        ) catch return error.InvalidAsset;
        defer source.close(self.io);
        return self.installSkillSource(source, input);
    }

    pub fn installSkillArchive(
        self: *Workbench,
        absolute_path: []const u8,
        input: SkillInstallInput,
    ) Error!SkillMutationResult {
        if (input.source_kind != .local_package or
            !std.fs.path.isAbsolute(absolute_path) or
            !std.unicode.utf8ValidateSlice(absolute_path) or
            !hasSkillArchiveExtension(absolute_path))
            return error.InvalidAsset;
        const archive = std.Io.Dir.openFileAbsolute(
            self.io,
            absolute_path,
            .{ .follow_symlinks = false },
        ) catch return error.InvalidAsset;
        defer archive.close(self.io);
        const inspection = skill_package_impl.inspectArchive(
            self.io,
            self.allocator,
            archive,
            .{},
        ) catch return error.InvalidAsset;
        const staging_path = self.skill_staging_root orelse
            return error.PersistenceFailed;
        const staging = std.Io.Dir.openDirAbsolute(
            self.io,
            staging_path,
            .{ .follow_symlinks = false },
        ) catch return error.PersistenceFailed;
        defer staging.close(self.io);
        var random: [16]u8 = undefined;
        std.Io.randomSecure(self.io, &random) catch
            return error.PersistenceFailed;
        const hex = std.fmt.bytesToHex(random, .lower);
        var scratch_name: [46]u8 = undefined;
        @memcpy(scratch_name[0..14], ".skill-import-");
        @memcpy(scratch_name[14..], &hex);
        staging.createDir(
            self.io,
            &scratch_name,
            privateDirectoryPermissions(),
        ) catch return error.PersistenceFailed;
        defer staging.deleteTree(self.io, &scratch_name) catch {};
        const scratch = staging.openDir(self.io, &scratch_name, .{
            .follow_symlinks = false,
        }) catch return error.PersistenceFailed;
        defer scratch.close(self.io);
        skill_package_impl.extractArchive(
            self.io,
            archive,
            scratch,
        ) catch return error.InvalidAsset;
        const source = if (inspection.wrapperName()) |wrapper|
            scratch.openDir(self.io, wrapper, .{
                .follow_symlinks = false,
            }) catch return error.InvalidAsset
        else
            scratch;
        defer if (inspection.wrapperName() != null)
            source.close(self.io);
        return self.installSkillSource(source, input);
    }

    fn installSkillSource(
        self: *Workbench,
        source: std.Io.Dir,
        input: SkillInstallInput,
    ) Error!SkillMutationResult {
        try self.requireSkillMutationAvailable(input.scope);
        var preview = try skill_package_impl.previewDirectory(
            self.io,
            self.allocator,
            source,
            .{},
        );
        defer preview.deinit();
        if (!std.mem.eql(u8, preview.invocation_name, input.expected_invocation_name) or
            !std.mem.eql(
                u8,
                &preview.content_hash,
                &input.expected_content_hash,
            ))
            return error.InvalidAsset;
        var manifest = try skill_package_impl.inspectDirectory(
            self.io,
            self.allocator,
            source,
            .{},
        );
        defer manifest.deinit();
        if (!std.mem.eql(
            u8,
            &manifest.content_hash,
            &input.expected_content_hash,
        )) return error.InvalidAsset;
        var root = try self.openSkillRoot(input.scope);
        defer root.deinit();
        const now = self.schedule_timer.now() orelse return error.PersistenceFailed;
        if (now == 0) return error.PersistenceFailed;
        const install_id = skill_management_impl.generateInstallId(
            self.io,
        ) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.PersistenceFailed,
        };
        const transactions = if (self.skill_transactions) |*value| value else return error.PersistenceFailed;
        const published = try transactions.publish(
            &root,
            source,
            &manifest,
            .{
                .asset = .{
                    .install_id = install_id,
                    .source_kind = input.source_kind,
                    .scope = input.scope,
                    .target_entry = preview.invocation_name,
                    .content_hash = manifest.content_hash,
                    .installed_at_unix_seconds = now,
                },
                .allow_replace = input.allow_replace,
            },
        );
        transactions.markReconciliationUnavailable(install_id) catch |err| {
            self.noteSkillPersistenceFailure(err);
            return err;
        };
        var reconciliation: SkillReconciliation = .{
            .install_id = install_id,
            .scope = input.scope,
            .invocation_name = undefined,
            .invocation_name_len = preview.invocation_name.len,
            .operation = if (published.replaced_existing) .replace else .install,
        };
        @memcpy(
            reconciliation.invocation_name[0..preview.invocation_name.len],
            preview.invocation_name,
        );
        self.skill_reconciliation = reconciliation;
        self.scheduleSkillReconciliation(input.scope) catch {
            self.skill_reconciliation = null;
            self.bumpRevision();
            return .{
                .install_id = install_id,
                .verification_pending = true,
            };
        };
        self.bumpRevision();
        return .{
            .install_id = install_id,
            .verification_pending = true,
        };
    }

    pub fn reimportSkillDirectory(
        self: *Workbench,
        install_id: skill_management_impl.InstallId,
        absolute_path: []const u8,
        expected_invocation_name: []const u8,
        expected_content_hash: skill_management_impl.ContentHash,
    ) Error!SkillMutationResult {
        if (!std.fs.path.isAbsolute(absolute_path) or
            !std.unicode.utf8ValidateSlice(absolute_path))
            return error.InvalidAsset;
        const source = std.Io.Dir.openDirAbsolute(
            self.io,
            absolute_path,
            .{ .follow_symlinks = false, .iterate = true },
        ) catch return error.InvalidAsset;
        defer source.close(self.io);
        return self.reimportSkillSource(
            install_id,
            source,
            expected_invocation_name,
            expected_content_hash,
        );
    }

    pub fn reimportSkillArchive(
        self: *Workbench,
        install_id: skill_management_impl.InstallId,
        absolute_path: []const u8,
        expected_invocation_name: []const u8,
        expected_content_hash: skill_management_impl.ContentHash,
    ) Error!SkillMutationResult {
        if (!std.fs.path.isAbsolute(absolute_path) or
            !std.unicode.utf8ValidateSlice(absolute_path) or
            !hasSkillArchiveExtension(absolute_path))
            return error.InvalidAsset;
        const archive = std.Io.Dir.openFileAbsolute(
            self.io,
            absolute_path,
            .{ .follow_symlinks = false },
        ) catch return error.InvalidAsset;
        defer archive.close(self.io);
        const inspection = skill_package_impl.inspectArchive(
            self.io,
            self.allocator,
            archive,
            .{},
        ) catch return error.InvalidAsset;
        const staging = try self.openSkillStagingRoot();
        defer staging.close(self.io);
        var random: [16]u8 = undefined;
        std.Io.randomSecure(self.io, &random) catch
            return error.PersistenceFailed;
        const hex = std.fmt.bytesToHex(random, .lower);
        var scratch_name: [48]u8 = undefined;
        @memcpy(scratch_name[0..16], ".skill-reimport-");
        @memcpy(scratch_name[16..], &hex);
        staging.createDir(
            self.io,
            &scratch_name,
            privateDirectoryPermissions(),
        ) catch return error.PersistenceFailed;
        defer staging.deleteTree(self.io, &scratch_name) catch {};
        const scratch = staging.openDir(self.io, &scratch_name, .{
            .follow_symlinks = false,
        }) catch return error.PersistenceFailed;
        defer scratch.close(self.io);
        skill_package_impl.extractArchive(
            self.io,
            archive,
            scratch,
        ) catch return error.InvalidAsset;
        const source = if (inspection.wrapperName()) |wrapper|
            scratch.openDir(self.io, wrapper, .{
                .follow_symlinks = false,
            }) catch return error.InvalidAsset
        else
            scratch;
        defer if (inspection.wrapperName() != null)
            source.close(self.io);
        return self.reimportSkillSource(
            install_id,
            source,
            expected_invocation_name,
            expected_content_hash,
        );
    }

    fn reimportSkillSource(
        self: *Workbench,
        install_id: skill_management_impl.InstallId,
        source: std.Io.Dir,
        expected_invocation_name: []const u8,
        expected_content_hash: skill_management_impl.ContentHash,
    ) Error!SkillMutationResult {
        const current = self.skillInventory().findConst(install_id) orelse
            return error.AssetNotFound;
        const scope = current.scope;
        const target_entry = try self.allocator.dupe(u8, current.target_entry);
        defer self.allocator.free(target_entry);
        try self.requireSkillMutationAvailable(scope);
        var preview = try skill_package_impl.previewDirectory(
            self.io,
            self.allocator,
            source,
            .{},
        );
        defer preview.deinit();
        if (!std.mem.eql(u8, preview.invocation_name, expected_invocation_name) or
            !std.mem.eql(u8, preview.invocation_name, target_entry) or
            !std.mem.eql(u8, &preview.content_hash, &expected_content_hash))
            return error.InvalidAsset;
        var manifest = try skill_package_impl.inspectDirectory(
            self.io,
            self.allocator,
            source,
            .{},
        );
        defer manifest.deinit();
        if (!std.mem.eql(u8, &manifest.content_hash, &expected_content_hash))
            return error.InvalidAsset;
        var root = try self.openSkillRoot(scope);
        defer root.deinit();
        const transactions = if (self.skill_transactions) |*value| value else return error.PersistenceFailed;
        try transactions.reimport(&root, install_id, source, &manifest);
        transactions.markReconciliationUnavailable(install_id) catch |err| {
            self.noteSkillPersistenceFailure(err);
            return err;
        };
        self.setSkillReconciliation(
            install_id,
            scope,
            target_entry,
            .replace,
        );
        self.scheduleSkillReconciliation(scope) catch {
            self.skill_reconciliation = null;
            self.bumpRevision();
            return .{ .install_id = install_id, .verification_pending = true };
        };
        self.bumpRevision();
        return .{ .install_id = install_id, .verification_pending = true };
    }

    pub fn uninstallSkill(
        self: *Workbench,
        install_id: skill_management_impl.InstallId,
    ) Error!SkillMutationResult {
        const current = self.skillInventory().findConst(install_id) orelse
            return error.AssetNotFound;
        const scope = current.scope;
        const target_entry = try self.allocator.dupe(u8, current.target_entry);
        defer self.allocator.free(target_entry);
        const pending_operation = if (current.state == .pending_verification and
            current.recovery != null)
            current.recovery.?.operation
        else
            null;
        try self.requireSkillMutationAvailable(scope);
        var root = try self.openSkillRoot(scope);
        defer root.deinit();
        const transactions = if (self.skill_transactions) |*value| value else return error.PersistenceFailed;
        if (pending_operation) |operation| switch (operation) {
            .install => {
                try transactions.rollbackReconciliation(&root, install_id);
                self.scheduleSkillReconciliation(scope) catch {};
                self.bumpRevision();
                return .{
                    .install_id = install_id,
                    .verification_pending = false,
                };
            },
            .uninstall => {
                const now = self.schedule_timer.now() orelse
                    return error.PersistenceFailed;
                try transactions.commitReconciliation(
                    &root,
                    install_id,
                    null,
                    now,
                );
                self.scheduleSkillReconciliation(scope) catch {};
                self.bumpRevision();
                return .{
                    .install_id = install_id,
                    .verification_pending = false,
                };
            },
            .replace => try transactions.rollbackReconciliation(
                &root,
                install_id,
            ),
        };
        try transactions.uninstall(&root, install_id);
        transactions.markReconciliationUnavailable(install_id) catch |err| {
            self.noteSkillPersistenceFailure(err);
            return err;
        };
        self.setSkillReconciliation(
            install_id,
            scope,
            target_entry,
            .uninstall,
        );
        self.scheduleSkillReconciliation(scope) catch {
            self.skill_reconciliation = null;
            self.bumpRevision();
            return .{ .install_id = install_id, .verification_pending = true };
        };
        self.bumpRevision();
        return .{ .install_id = install_id, .verification_pending = true };
    }

    pub fn retrySkillVerification(
        self: *Workbench,
        install_id: skill_management_impl.InstallId,
    ) Error!SkillMutationResult {
        const current = self.skillInventory().findConst(install_id) orelse
            return error.AssetNotFound;
        if (current.state != .pending_verification or current.recovery == null)
            return error.InvalidAsset;
        const scope = current.scope;
        const target_entry = try self.allocator.dupe(u8, current.target_entry);
        defer self.allocator.free(target_entry);
        const operation = current.recovery.?.operation;
        try self.requireSkillMutationAvailable(scope);
        self.setSkillReconciliation(
            install_id,
            scope,
            target_entry,
            operation,
        );
        self.scheduleSkillReconciliation(scope) catch |err| {
            self.skill_reconciliation = null;
            return err;
        };
        self.bumpRevision();
        return .{ .install_id = install_id, .verification_pending = true };
    }

    pub fn readSkillDefinition(
        self: *Workbench,
        install_id: skill_management_impl.InstallId,
    ) Error!skill_package_impl.Preview {
        if (self.skill_management_health != .ready or self.shutting_down)
            return error.PersistenceFailed;
        const current = self.skillInventory().findConst(install_id) orelse
            return error.AssetNotFound;
        if (current.recovery != null) return error.InvalidAsset;
        const scope = current.scope;
        const target_entry = try self.allocator.dupe(u8, current.target_entry);
        defer self.allocator.free(target_entry);
        var root = try self.openSkillRoot(scope);
        defer root.deinit();
        const source = root.dir.openDir(
            self.io,
            target_entry,
            .{ .follow_symlinks = false, .iterate = true },
        ) catch return error.TargetUnavailable;
        defer source.close(self.io);
        return skill_package_impl.previewDirectory(
            self.io,
            self.allocator,
            source,
            .{},
        );
    }

    pub fn exportSkill(
        self: *Workbench,
        install_id: skill_management_impl.InstallId,
        absolute_destination: []const u8,
    ) Error!SkillExportResult {
        if (self.skill_management_health != .ready or self.shutting_down or
            !std.fs.path.isAbsolute(absolute_destination) or
            !std.unicode.utf8ValidateSlice(absolute_destination))
            return error.InvalidAsset;
        const current = self.skillInventory().findConst(install_id) orelse
            return error.AssetNotFound;
        if (current.state != .ready or current.recovery != null)
            return error.InvalidAsset;
        const scope = current.scope;
        const target_entry = try self.allocator.dupe(u8, current.target_entry);
        defer self.allocator.free(target_entry);
        var root = try self.openSkillRoot(scope);
        defer root.deinit();
        const source = root.dir.openDir(
            self.io,
            target_entry,
            .{ .follow_symlinks = false, .iterate = true },
        ) catch return error.TargetUnavailable;
        defer source.close(self.io);
        var manifest = try skill_package_impl.inspectDirectory(
            self.io,
            self.allocator,
            source,
            .{},
        );
        defer manifest.deinit();
        const destination = std.Io.Dir.openDirAbsolute(
            self.io,
            absolute_destination,
            .{ .follow_symlinks = false },
        ) catch return error.DestinationUnavailable;
        defer destination.close(self.io);
        var result: SkillExportResult = .{
            .file_name = undefined,
            .file_name_len = target_entry.len + ".skill".len,
        };
        @memcpy(result.file_name[0..target_entry.len], target_entry);
        @memcpy(
            result.file_name[target_entry.len..result.file_name_len],
            ".skill",
        );
        const output = destination.createFile(
            self.io,
            result.fileName(),
            .{
                .exclusive = true,
                .permissions = privateFilePermissions(),
                .resolve_beneath = true,
            },
        ) catch |err| return switch (err) {
            error.PathAlreadyExists => error.TargetAlreadyExists,
            else => error.DestinationUnavailable,
        };
        var output_open = true;
        var output_exists = true;
        defer {
            if (output_open) output.close(self.io);
            if (output_exists)
                destination.deleteFile(self.io, result.fileName()) catch {};
        }
        skill_package_impl.exportArchive(
            self.io,
            source,
            output,
            &manifest,
        ) catch return error.WriteFailed;
        output.sync(self.io) catch return error.WriteFailed;
        output.close(self.io);
        output_open = false;
        output_exists = false;
        return result;
    }

    fn openSkillStagingRoot(self: *Workbench) Error!std.Io.Dir {
        const path = self.skill_staging_root orelse return error.PersistenceFailed;
        return std.Io.Dir.openDirAbsolute(
            self.io,
            path,
            .{ .follow_symlinks = false },
        ) catch error.PersistenceFailed;
    }

    fn setSkillReconciliation(
        self: *Workbench,
        install_id: skill_management_impl.InstallId,
        scope: skill_management_impl.Scope,
        invocation_name: []const u8,
        operation: skill_management_impl.Operation,
    ) void {
        std.debug.assert(invocation_name.len <= skill_management_impl.max_target_entry_bytes);
        var reconciliation: SkillReconciliation = .{
            .install_id = install_id,
            .scope = scope,
            .invocation_name = undefined,
            .invocation_name_len = invocation_name.len,
            .operation = operation,
        };
        @memcpy(
            reconciliation.invocation_name[0..invocation_name.len],
            invocation_name,
        );
        self.skill_reconciliation = reconciliation;
    }

    pub fn automaticWorkspacesAvailable(self: *const Workbench) bool {
        return self.automatic_workspaces != null;
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
        if (self.custom_execution_binding) |*binding| binding.deinit();
        self.custom_execution_binding = null;
        std.debug.assert(self.execution_replacement != .none);
        const input = execution.input();
        std.debug.assert(self.account.catalog_state == .ready);
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

    /// Installs a Host-resolved user Model Connection execution without
    /// pretending that it is a Metask OAuth account/catalog. The active
    /// execution still uses the same Workbench-owned secret and generation
    /// machinery as the built-in path.
    pub fn prepareModelConnectionBinding(
        self: *Workbench,
        connection_id: []const u8,
        model_id: []const u8,
    ) std.mem.Allocator.Error!PreparedModelConnectionBinding {
        return PreparedModelConnectionBinding.init(
            self.allocator,
            connection_id,
            model_id,
        );
    }

    pub fn installModelConnectionExecutionNoFail(
        self: *Workbench,
        execution: *account_contract.OwnedExecutionConfig,
        prepared_binding: *PreparedModelConnectionBinding,
    ) void {
        std.debug.assert(self.execution_replacement != .none);
        self.redactAllProductProjectionsNoFail(self.execution.credential());
        self.redactAllProductProjectionsNoFail(execution.input().api_key);
        self.execution.installNoFail(execution);
        if (self.custom_execution_binding) |*previous| previous.deinit();
        self.custom_execution_binding = prepared_binding.*;
        prepared_binding.* = undefined;
    }

    pub fn clearExecutionNoFail(self: *Workbench) void {
        std.debug.assert(self.execution_replacement != .none);
        std.debug.assert(self.account.execution_generation == 0);
        self.redactAllProductProjectionsNoFail(self.execution.credential());
        self.execution.clearNoFail();
        if (self.custom_execution_binding) |*binding| binding.deinit();
        self.custom_execution_binding = null;
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
        var result = self.account.view(self.canCreateTask());
        if (self.custom_execution_binding != null) {
            result.execution_source = .model_connection;
            result.selected_model_connection_id = self.custom_execution_binding.?.connection_id;
            result.execution_generation = self.execution.generation;
        }
        return result;
    }

    pub fn modelConnectionExecutionActive(
        self: *const Workbench,
        connection_id: []const u8,
    ) bool {
        const binding = self.custom_execution_binding orelse return false;
        return std.mem.eql(u8, binding.connection_id, connection_id);
    }

    pub fn modelConnectionExecutionSelected(self: *const Workbench) bool {
        return self.custom_execution_binding != null;
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
                .state = .authenticated,
                .catalog_state = .ready,
                .account_id = "automation-account",
                .display_name = "Automation",
                .api_keys = &api_keys,
                .models = &models,
                .selected_api_key_id = "automation-key",
                .selected_model = input.model,
                .model_catalog_api_key_id = "automation-key",
                .can_create_task = true,
                .execution_generation = 1,
                .metask_execution_generation = 1,
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
        if (self.execution_replacement != .none)
            return error.ExecutionInUse;
        // Identity replacement changes only Account-owned admission defaults.
        // Live Tasks keep their owned ExecutionConfig until their own runtime
        // lifecycle releases it, so their references cannot block this gate.
        self.execution_replacement = .identity;
    }

    pub fn beginDefaultExecutionReplacement(self: *Workbench) Error!void {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        self.syncLifecycle();
        if (self.execution_replacement != .none)
            return error.ExecutionInUse;
        self.execution_replacement = .default;
    }

    pub fn endExecutionReplacementNoFail(self: *Workbench) void {
        std.debug.assert(self.execution_replacement != .none);
        self.execution_replacement = .none;
    }

    pub fn executionReplacementPending(self: *const Workbench) bool {
        return self.execution_replacement != .none;
    }

    pub fn identityReplacementPending(self: *const Workbench) bool {
        return self.execution_replacement == .identity;
    }

    pub fn defaultExecutionReplacementPending(self: *const Workbench) bool {
        return self.execution_replacement == .default;
    }

    /// Registers or reauthorizes a manually selected Workspace.
    pub fn openWorkspace(
        self: *Workbench,
        input: TaskCreateInput,
    ) Error!u64 {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        self.syncLifecycle();
        try self.requireTaskPersistenceMutation();
        const recent_order = try self.takeWorkspaceRecentOrder();
        const upsert = try self.upsertWorkspace(input);
        const workspace = &self.workspaces[upsert.index].?;
        workspace.recent_order = recent_order;
        self.commitTaskStateIfConfigured() catch |err| {
            self.next_workspace_recent_order = recent_order;
            self.rollbackWorkspaceUpsert(upsert);
            return err;
        };
        self.finishWorkspaceUpsert(upsert);
        self.reconcileSkillEnablementNoFail();
        self.recoverSkillTransactionsForScopeNoFail(.{ .project = .{
            .workspace_id = workspace.id,
            .workspace_epoch = workspace.epoch,
        } });
        if (workspace.catalog_slot == .uninitialized) {
            if (workspace.catalog_job != null) {
                workspace.catalog_reschedule_pending = true;
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
            workspace.catalog_slot.availability(workspace.catalog_job != null),
            workspace.catalog_slot.snapshotConst(),
        );
    }

    pub fn skillCatalog(self: *Workbench) CatalogProjection {
        self.syncLifecycle();
        return catalogProjection(
            self.skill_catalog_slot.availability(self.skill_catalog_job != null),
            self.skill_catalog_slot.snapshotConst(),
        );
    }

    pub fn refreshSkillCatalog(self: *Workbench) Error!void {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        self.syncLifecycle();
        if (self.skill_catalog_job != null) return error.CatalogLoading;
        try self.scheduleSkillCatalogQuery();
        self.bumpRevision();
    }

    pub fn setSkillEnabled(
        self: *Workbench,
        mutation: SkillEnablementMutation,
    ) Error!u64 {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        self.syncLifecycle();
        if (self.skill_enablement_health != .ready or
            self.skill_enablement_file_store == null)
            return error.PersistenceFailed;
        const catalog: *CatalogSnapshot = switch (mutation.scope) {
            .personal => personal: {
                if (mutation.state == .inherit) return error.InvalidPolicyKey;
                break :personal self.skill_catalog_slot.snapshot() orelse
                    return error.CatalogUnavailable;
            },
            .project => |project| project_catalog: {
                const workspace = self.findWorkspace(project.workspace_id) orelse
                    return error.UnknownWorkspace;
                if (workspace.kind != .manual or !workspace.visible or
                    workspace.authorization != .available)
                    return error.WorkspaceUnavailable;
                if (project.expected_workspace_epoch == 0 or
                    project.expected_workspace_epoch != workspace.epoch)
                    return error.WorkspaceEpochMismatch;
                break :project_catalog workspace.catalog_slot.snapshot() orelse
                    return error.CatalogUnavailable;
            },
        };
        if (!std.mem.eql(u8, mutation.expected_catalog_revision, catalog.revision))
            return error.StaleCatalog;
        if (mutation.expected_selection_revision != catalog.selection_revision)
            return error.StaleCatalog;
        _ = catalog.findSkillByPolicyKey(mutation.skill_policy_key) orelse
            return error.SkillNotFound;
        var candidate = try self.skill_enablement.clone();
        var candidate_owned = true;
        defer if (candidate_owned) candidate.deinit();
        const next_revision = switch (mutation.scope) {
            .personal => blk: {
                const enabled = mutation.state == .enabled;
                if (candidate.isUserEnabled(mutation.skill_policy_key) == enabled)
                    return mutation.expected_selection_revision;
                break :blk try candidate.applyUser(.{
                    .skill_policy_key = mutation.skill_policy_key,
                    .enabled = enabled,
                    .expected_revision = mutation.expected_selection_revision,
                });
            },
            .project => |project| blk: {
                const identity: skill_enablement_impl.WorkspaceIdentity = .{
                    .workspace_id = project.workspace_id,
                    .workspace_epoch = project.expected_workspace_epoch,
                };
                if (candidate.workspaceOverride(identity, mutation.skill_policy_key) == mutation.state)
                    return mutation.expected_selection_revision;
                break :blk try candidate.applyWorkspace(.{
                    .identity = identity,
                    .skill_policy_key = mutation.skill_policy_key,
                    .state = mutation.state,
                    .expected_revision = mutation.expected_selection_revision,
                });
            },
        };
        const WorkspaceCatalogCandidate = struct {
            index: usize,
            workspace_id: u64,
            workspace_epoch: u64,
            snapshot: CatalogSnapshot,
        };
        var personal_catalog_candidate: ?CatalogSnapshot = null;
        var workspace_catalog_candidates: std.ArrayList(WorkspaceCatalogCandidate) = .empty;
        defer workspace_catalog_candidates.deinit(self.allocator);
        var catalog_candidates_owned = true;
        defer if (catalog_candidates_owned) {
            if (personal_catalog_candidate) |*snapshot| snapshot.deinit();
            for (workspace_catalog_candidates.items) |*item| item.snapshot.deinit();
        };
        switch (mutation.scope) {
            .personal => {
                personal_catalog_candidate = try self.recompileCatalogSnapshot(
                    self.skill_catalog_slot.snapshot().?,
                    &candidate,
                    .personal,
                );
                for (self.workspaces, 0..) |*entry, index| {
                    const workspace = &(entry.* orelse continue);
                    const snapshot = workspace.catalog_slot.snapshot() orelse continue;
                    var replacement = try self.recompileCatalogSnapshot(
                        snapshot,
                        &candidate,
                        .{ .project = .{
                            .workspace_id = workspace.id,
                            .workspace_epoch = workspace.epoch,
                        } },
                    );
                    errdefer replacement.deinit();
                    try workspace_catalog_candidates.append(self.allocator, .{
                        .index = index,
                        .workspace_id = workspace.id,
                        .workspace_epoch = workspace.epoch,
                        .snapshot = replacement,
                    });
                }
            },
            .project => |project| {
                const workspace = self.findWorkspace(project.workspace_id) orelse
                    unreachable;
                var replacement = try self.recompileCatalogSnapshot(
                    workspace.catalog_slot.snapshot().?,
                    &candidate,
                    .{ .project = .{
                        .workspace_id = workspace.id,
                        .workspace_epoch = workspace.epoch,
                    } },
                );
                errdefer replacement.deinit();
                const index = for (self.workspaces, 0..) |entry, candidate_index| {
                    const value = entry orelse continue;
                    if (value.id == project.workspace_id) break candidate_index;
                } else unreachable;
                try workspace_catalog_candidates.append(self.allocator, .{
                    .index = index,
                    .workspace_id = workspace.id,
                    .workspace_epoch = workspace.epoch,
                    .snapshot = replacement,
                });
            },
        }
        self.commitSkillEnablementCandidate(&candidate) catch |err| {
            self.noteSkillEnablementPersistenceFailure(err);
            return err;
        };
        candidate_owned = false;
        if (personal_catalog_candidate) |replacement| {
            const authority = &self.skill_catalog_slot.committed;
            authority.snapshot.deinit();
            authority.snapshot = replacement;
        }
        for (workspace_catalog_candidates.items) |item| {
            const workspace = &self.workspaces[item.index].?;
            std.debug.assert(workspace.id == item.workspace_id);
            std.debug.assert(workspace.epoch == item.workspace_epoch);
            const authority = &workspace.catalog_slot.committed;
            authority.snapshot.deinit();
            authority.snapshot = item.snapshot;
        }
        catalog_candidates_owned = false;
        self.bumpRevision();
        return next_revision;
    }

    pub fn refreshMcpCatalog(self: *Workbench) Error!void {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        self.syncLifecycle();
        if (!try self.requestMcpCatalogRefresh(false)) return error.CatalogLoading;
    }

    /// Records every refresh trigger before attempting to enqueue work. A
    /// request that arrives while refresh, apply, or OAuth owns the Runtime is
    /// retained and consumed after that operation reaches its main-thread
    /// completion boundary.
    fn requestMcpCatalogRefresh(
        self: *Workbench,
        invalidate_admission: bool,
    ) Error!bool {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        const mcp = if (self.mcp) |*value| value else return error.CatalogUnavailable;
        if (!mcp.committed) return error.CatalogUnavailable;
        switch (mcp.preparation.state) {
            .empty, .available => {},
            .unavailable => return error.CatalogUnavailable,
        }
        const management = if (mcp.management) |*value| value else return error.CatalogUnavailable;
        const inspection = management.inspect();
        if (inspection.health != .ready) return error.McpManagementUnavailable;
        _ = management.desiredRegistry() orelse
            return error.McpManagementUnavailable;
        if (mcp.refresh_request_generation == std.math.maxInt(u64))
            return error.CatalogRequestGenerationExhausted;
        self.mcp_refresh_timer.cancelCurrent();
        mcp.refresh_request_generation += 1;
        mcp.refresh_pending = true;
        mcp.refresh_pending_blocks_admission =
            mcp.refresh_pending_blocks_admission or invalidate_admission;
        if (invalidate_admission) mcp_policy.blockAdmission(mcp, .refreshing);
        const started = try self.startPendingMcpCatalogRefresh();
        if (!started) self.bumpRevision();
        return started;
    }

    fn startPendingMcpCatalogRefresh(self: *Workbench) Error!bool {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        const mcp = if (self.mcp) |*value| value else return error.CatalogUnavailable;
        if (!mcp.refresh_pending) return false;
        if (self.mcp_refresh_job != null or
            mcp.configuration_apply_state == .applying or
            mcp.authorization_operation != null)
            return false;
        const management = if (mcp.management) |*value| value else return error.CatalogUnavailable;
        const inspection = management.inspect();
        if (inspection.health != .ready) return error.McpManagementUnavailable;
        const desired = management.desiredRegistry() orelse
            return error.McpManagementUnavailable;
        if (desired.oauth_operation != null) return false;
        const generation = mcp.refresh_request_generation;
        std.debug.assert(generation != 0);
        var refresh_arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer refresh_arena.deinit();
        const alignment = inspection.runtime_alignment;
        const allowlists = try mcp_policy.buildRefreshAllowlists(
            refresh_arena.allocator(),
            mcp,
            desired,
        );
        const job = try self.allocator.create(McpRefreshJob);
        errdefer self.allocator.destroy(job);
        job.* = .{
            .allocator = self.allocator,
            .runtime = self.agent_runtime,
            .notifier = self.change_notifier,
            .request_generation = generation,
            .requested_at_ms = self.mcp_refresh_timer.now(),
            .arena = refresh_arena,
            .allowlists = allowlists,
            .build_admission = alignment == .current,
        };
        try self.executor.enqueue(.{
            .identity = job,
            .context = job,
            .execute_fn = executeMcpRefreshJob,
            .cancel_fn = cancelMcpRefreshJob,
        });
        mcp_policy.blockAdmission(mcp, .refreshing);
        mcp.refresh_pending = false;
        mcp.refresh_pending_blocks_admission = false;
        self.mcp_refresh_job = job;
        self.bumpRevision();
        return true;
    }

    /// Native one-shot timer ingress. Refresh work is always enqueued on the
    /// bounded Workbench executor; the main thread never performs catalog I/O.
    pub fn onMcpRefreshTimer(self: *Workbench) void {
        if (self.shutting_down) return;
        self.syncLifecycle();
        _ = self.requestMcpCatalogRefresh(true) catch {
            if (self.mcp) |*mcp| {
                if (self.mcp_refresh_job == null and !mcp.refresh_pending)
                    mcp_policy.blockAdmissionForCurrentState(mcp);
                self.bumpRevision();
            }
        };
    }

    pub fn taskCatalog(
        self: *Workbench,
        task_id: u64,
    ) Error!CatalogProjection {
        self.syncLifecycle();
        const task = self.findTask(task_id) orelse return error.UnknownTask;
        return task_view.catalogProjection(task);
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
        if (workspace.kind != .manual) return error.WorkspaceUnavailable;
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
        if (task.durable.binding_epoch != expected_binding_epoch)
            return error.BindingEpochMismatch;
        if (!self.taskContinuationAvailable(task) or hasActiveOperation(task))
            return error.TaskBusy;
        const workspace = self.findWorkspace(task.durable.workspace_id) orelse
            return error.WorkspaceUnavailable;
        if (self.skill_enablement_health != .ready)
            return error.RecoveryUnavailable;
        if (workspace.kind != .manual) return error.CatalogUnavailable;
        if (workspace.epoch != task.durable.workspace_epoch)
            return error.WorkspaceEpochMismatch;
        const current = workspace.catalog_slot.snapshot() orelse
            return switch (workspace.catalog_slot.availability(workspace.catalog_job != null)) {
                .loading => error.CatalogLoading,
                else => error.CatalogUnavailable,
            };
        const lease = workspace.catalog_slot.lease() orelse
            return error.CatalogUnavailable;
        var replacement = try current.clone(
            self.allocator,
            catalogSnapshotLimits(self.limits),
            self.limits.max_projection_bytes - self.projection_bytes,
        );
        errdefer replacement.deinit();
        var granted_skill_ids: std.ArrayList([]const u8) = .empty;
        defer granted_skill_ids.deinit(self.allocator);
        for (replacement.skills) |skill|
            if (skill.enabled) try granted_skill_ids.append(
                self.allocator,
                skill.skill_id,
            );
        var access = task.runtime.acquireAccess() catch return error.TaskClosing;
        defer access.deinit();
        try access.refreshSkillCatalog(lease, .{
            .granted_skill_ids = granted_skill_ids.items,
        });
        if (task.runtime.pinnedCatalog()) |old| {
            self.projection_bytes -= old.projected_bytes;
            old.deinit();
        }
        self.projection_bytes += replacement.projected_bytes;
        task.runtime.attached().?.pinned_catalog = replacement;
        self.bumpRevision();
    }

    pub fn workspaceEpoch(self: *Workbench, workspace_id: u64) Error!u64 {
        self.syncLifecycle();
        const workspace = self.findWorkspace(workspace_id) orelse
            return error.UnknownWorkspace;
        return workspace.epoch;
    }

    pub fn workspaceKind(
        self: *Workbench,
        workspace_id: u64,
    ) Error!WorkspaceKind {
        self.syncLifecycle();
        const workspace = self.findWorkspace(workspace_id) orelse
            return error.UnknownWorkspace;
        return workspace.kind;
    }

    pub fn taskWorkspaceId(self: *Workbench, task_id: u64) Error!u64 {
        self.syncLifecycle();
        const task = self.findTask(task_id) orelse return error.UnknownTask;
        return task.durable.workspace_id;
    }

    /// Copies the canonical Workspace projection without allocating. Hidden
    /// Manual Workspaces that are no longer registered remain omitted;
    /// Automatic Workspaces stay projected so
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
            if (workspace.kind == .manual and !workspace.visible) continue;
            if (count == output.len) return error.WorkspaceCapacity;
            output[count] = .{
                .id = workspace.id,
                .epoch = workspace.epoch,
                .kind = workspace.kind,
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
        try self.requireTaskPersistenceMutation();
        const workspace = self.findWorkspace(workspace_id) orelse
            return error.UnknownWorkspace;
        if (workspace.kind != .manual or !workspace.visible)
            return error.UnknownWorkspace;
        if (expected_workspace_epoch == 0 or workspace.epoch != expected_workspace_epoch)
            return error.WorkspaceEpochMismatch;
        if (workspace.authorization == .removing)
            return error.WorkspaceRemovalInProgress;
        if (workspace.epoch == std.math.maxInt(u64))
            return error.WorkspaceEpochExhausted;
        const previous_epoch = workspace.epoch;
        const previous_authorization = workspace.authorization;
        const previous_failure = workspace.last_removal_failure;
        workspace.epoch += 1;
        workspace.authorization = .removing;
        workspace.last_removal_failure = .none;
        self.commitTaskStateIfConfigured() catch |err| {
            workspace.epoch = previous_epoch;
            workspace.authorization = previous_authorization;
            workspace.last_removal_failure = previous_failure;
            return err;
        };
        self.reconcileSkillEnablementNoFail();
        self.markWorkspaceCatalogUnavailable(workspace);
        self.bumpRevision();
        for (self.tasks) |*entry| {
            const task = &(entry.* orelse continue);
            if (task.durable.workspace_id != workspace_id or
                !task.runtime.hasAttachedSession()) continue;
            self.detachTaskSession(task.durable.id) catch |err| switch (err) {
                error.CloseInProgress => {},
                else => {
                    workspace.authorization = .available;
                    workspace.last_removal_failure = .task_close_failed;
                    self.commitTaskStateNoFail();
                    self.bumpRevision();
                    return err;
                },
            };
        }
        if (self.finalizeWorkspaceRemovalsNoFail()) {
            self.commitTaskStateNoFail();
            self.bumpRevision();
        }
    }

    pub fn createTask(
        self: *Workbench,
        input: TaskCreateInput,
    ) Error!u64 {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        self.syncLifecycle();
        if (self.execution_replacement != .none)
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
            null,
        );
    }

    pub fn createTaskInWorkspace(
        self: *Workbench,
        workspace_id: u64,
        expected_workspace_epoch: u64,
        expected_execution_generation: u64,
        expected_skill_catalog_revision: ?[]const u8,
        expected_skill_selection_revision: ?u64,
    ) Error!u64 {
        return self.createTaskInWorkspaceInternal(
            workspace_id,
            expected_workspace_epoch,
            expected_execution_generation,
            expected_skill_catalog_revision,
            expected_skill_selection_revision,
            false,
        );
    }

    pub fn createTaskForWorkspace(
        self: *Workbench,
        request: TaskWorkspaceRequest,
        expected_execution_generation: u64,
        expected_skill_catalog_revision: ?[]const u8,
        expected_skill_selection_revision: ?u64,
    ) Error!u64 {
        return switch (request) {
            .manual => |manual| self.createTaskInWorkspace(
                manual.workspace_id,
                manual.expected_epoch,
                expected_execution_generation,
                expected_skill_catalog_revision,
                expected_skill_selection_revision,
            ),
            .automatic => self.createAutomaticTask(
                expected_execution_generation,
                expected_skill_catalog_revision,
                expected_skill_selection_revision,
            ),
        };
    }

    fn createTaskInWorkspaceInternal(
        self: *Workbench,
        workspace_id: u64,
        expected_workspace_epoch: u64,
        expected_execution_generation: u64,
        expected_skill_catalog_revision: ?[]const u8,
        expected_skill_selection_revision: ?u64,
        allow_unowned_automatic: bool,
    ) Error!u64 {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        self.syncLifecycle();
        if (self.mcp) |*mcp|
            if (self.mcp_refresh_job != null or mcp.refresh_pending_blocks_admission)
                return error.CatalogLoading;
        try self.requireTaskPersistenceMutation();
        if (self.execution_replacement != .none)
            return error.ExecutionInUse;
        if (!self.canCreateTask())
            return error.ExecutionUnavailable;
        if (!self.validExecutionGeneration(expected_execution_generation))
            return error.ExecutionGenerationMismatch;
        const workspace_view = self.findWorkspace(workspace_id) orelse
            return error.UnknownWorkspace;
        if (expected_workspace_epoch == 0 or
            expected_workspace_epoch != workspace_view.epoch)
            return error.WorkspaceEpochMismatch;
        if (workspace_view.kind == .automatic and
            (!allow_unowned_automatic or workspace_view.automatic_task_id != 0))
            return error.WorkspaceUnavailable;
        if (workspace_view.kind == .manual and !workspace_view.visible)
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
        switch (workspace_view.catalog_slot.availability(workspace_view.catalog_job != null)) {
            .ready, .degraded => {
                const current = workspace_view.catalog_slot.snapshot() orelse
                    return error.CatalogUnavailable;
                if (expected_skill_catalog_revision) |expected|
                    if (!std.mem.eql(u8, expected, current.revision))
                        return error.StaleCatalog;
                if ((expected_skill_catalog_revision == null) !=
                    (expected_skill_selection_revision == null))
                    return error.StaleCatalog;
                if (expected_skill_selection_revision) |expected|
                    if (expected != current.selection_revision)
                        return error.StaleCatalog;
                pinned_catalog = try current.clone(
                    self.allocator,
                    catalogSnapshotLimits(self.limits),
                    self.limits.max_projection_bytes - self.projection_bytes,
                );
                self.projection_bytes += pinned_catalog.?.projected_bytes;
                catalog_lease = workspace_view.catalog_slot.lease() orelse
                    return error.CatalogUnavailable;
            },
            .loading => if (expected_skill_catalog_revision != null)
                return error.CatalogLoading,
            .uninitialized, .unavailable => if (expected_skill_catalog_revision != null)
                return error.CatalogUnavailable,
        }
        if (expected_skill_catalog_revision == null and
            expected_skill_selection_revision != null)
            return error.StaleCatalog;
        var granted_skill_ids: std.ArrayList([]const u8) = .empty;
        defer granted_skill_ids.deinit(self.allocator);
        if (pinned_catalog) |*snapshot| for (snapshot.skills) |skill|
            if (skill.enabled) try granted_skill_ids.append(
                self.allocator,
                skill.skill_id,
            );
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
            self.admissionModel(),
            account_contract.Limits.model_id_bytes,
        );
        errdefer self.freeTracked(execution_model);
        const runs = try self.allocator.alloc(?RunRecord, self.limits.max_runs_per_task);
        errdefer self.allocator.free(runs);
        @memset(runs, null);
        const compacts = try self.allocator.alloc(
            ?CompactRecord,
            self.limits.max_compacts_per_task,
        );
        errdefer self.allocator.free(compacts);
        @memset(compacts, null);
        const ui_history = try self.allocator.alloc(?UiRecord, self.limits.max_ui_history_per_task);
        errdefer self.allocator.free(ui_history);
        @memset(ui_history, null);
        const workspace_recent_order = if (workspace_view.kind == .manual)
            try self.takeWorkspaceRecentOrder()
        else
            0;
        errdefer {
            if (workspace_view.kind == .manual)
                self.next_workspace_recent_order = workspace_recent_order;
        }
        const previous_workspace_recent_order = workspace_view.recent_order;
        if (self.next_task_id == 0) return error.TaskIdentityExhausted;
        const task_id = self.next_task_id;
        var epoch_storage: [32]u8 = undefined;
        const epoch_token = std.fmt.bufPrint(
            &epoch_storage,
            "{d}",
            .{workspace_view.epoch},
        ) catch unreachable;
        var binding = task_agent_session.Binding.open(self.agent_runtime, .{
            .provider = agentProvider(accountProvider(task_execution_input.target.provider_kind)),
            .permission_mode = .accept_edits,
            .shell_policy = .unrestricted,
            .credential = task_execution_input.api_key,
            .model = self.admissionModel(),
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
            .skill_policy = if (catalog_lease != null) .{
                .granted_skill_ids = granted_skill_ids.items,
            } else null,
            .mcp_selection = mcp_policy.selectionForNewTask(if (self.mcp) |*mcp| mcp else null),
        }) catch |err| switch (err) {
            error.SessionCapacity => return error.TaskCapacity,
            error.McpNotRefreshed => {
                self.recoverExpiredMcpCatalogNoFail();
                return error.CatalogLoading;
            },
            else => return err,
        };
        self.next_task_id +%= 1;
        self.tasks[slot] = .{
            .durable = .{
                .id = task_id,
                .recent_order = self.takeTaskRecentOrder(),
                .execution_generation = task_execution_input.execution_generation,
                .execution_provider = accountProvider(task_execution_input.target.provider_kind),
                .execution_model = execution_model,
                .workspace_id = workspace_id,
                .workspace_epoch = workspace_view.epoch,
                .workspace_root = workspace,
                .title = title,
                .runs = runs,
                .compacts = compacts,
                .ui_history = ui_history,
            },
            .runtime = .{
                .attachment = .{ .attached = .{
                    .binding = binding.take(),
                    .execution = task_execution.take(),
                    .pinned_catalog = pinned_catalog,
                } },
            },
        };
        if (workspace_view.kind == .manual)
            workspace_view.recent_order = workspace_recent_order;
        errdefer {
            if (workspace_view.kind == .manual)
                workspace_view.recent_order = previous_workspace_recent_order;
        }
        self.commitTaskStateIfConfigured() catch |err| {
            const inserted = &self.tasks[slot].?;
            var live = inserted.runtime.detach(.cold_start);
            switch (live.binding.closeOutcome(.session_close)) {
                .closed => live.binding.releaseClosed() catch
                    @panic("fresh Task Session release failed during persistence rollback"),
                .failure => @panic("fresh Task Session close failed during persistence rollback"),
            }
            live.execution.deinit();
            self.tasks[slot] = null;
            self.next_task_id = task_id;
            return err;
        };
        self.bumpRevision();
        return task_id;
    }

    fn createAutomaticTask(
        self: *Workbench,
        expected_execution_generation: u64,
        expected_skill_catalog_revision: ?[]const u8,
        expected_skill_selection_revision: ?u64,
    ) Error!u64 {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        self.syncLifecycle();
        if (self.execution_replacement != .none)
            return error.ExecutionInUse;
        if (!self.canCreateTask())
            return error.ExecutionUnavailable;
        if (!self.validExecutionGeneration(expected_execution_generation))
            return error.ExecutionGenerationMismatch;
        if (expected_skill_catalog_revision != null or
            expected_skill_selection_revision != null)
            return error.CatalogUnavailable;
        if (findEmpty(TaskView, self.tasks) == null) return error.TaskCapacity;
        if (self.workspaceCount(.automatic) >= self.limits.max_tasks)
            return error.WorkspaceCapacity;
        const store = if (self.automatic_workspaces) |*value| value else return error.WorkspaceUnavailable;
        var allocation = store.allocate() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidAutomaticRoot => return error.InvalidWorkspace,
            error.RootUnavailable, error.AllocationUnavailable => return error.WorkspaceUnavailable,
        };
        errdefer _ = store.rollback(&allocation);
        const workspace = try self.registerAutomaticWorkspace(allocation.path());
        errdefer self.releaseAutomaticWorkspaceNoFail(workspace.id);
        const task_id = try self.createTaskInWorkspaceInternal(
            workspace.id,
            workspace.epoch,
            expected_execution_generation,
            null,
            null,
            true,
        );
        workspace.automatic_task_id = task_id;
        allocation.deinit();
        return task_id;
    }

    /// Admits an explicit attachment reconstruction. Success means only that
    /// the bounded recovery attempt was enqueued; the canonical Snapshot owns
    /// publication of the eventual result.
    pub fn restoreTaskConversation(
        self: *Workbench,
        task_id: u64,
        expected_binding_epoch: u64,
    ) Error!u64 {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        self.syncLifecycle();
        const task = self.findTask(task_id) orelse return error.UnknownTask;
        if (expected_binding_epoch == 0 or
            expected_binding_epoch != task.durable.binding_epoch)
            return error.BindingEpochMismatch;
        if (!self.taskRecoveryProjection(task).recovery_available)
            return error.RecoveryUnavailable;
        const checkpoint = task.durable.checkpoint orelse
            return error.RecoveryUnavailable;
        const workspace = self.findWorkspace(task.durable.workspace_id) orelse
            return error.WorkspaceUnavailable;
        if (workspace.kind == .manual and self.skill_enablement_health != .ready)
            return error.RecoveryUnavailable;
        const canonical_user_home = self.canonical_user_home orelse
            return error.WorkspaceUnavailable;
        if (self.next_restore_attempt_id == 0)
            return error.RestoreAttemptExhausted;
        const attempt_id = self.next_restore_attempt_id;

        var checkpoint_copy = try checkpoint.clone(self.allocator);
        var checkpoint_copy_live = true;
        errdefer if (checkpoint_copy_live) checkpoint_copy.deinit(self.allocator);
        var epoch_storage: [32]u8 = undefined;
        const epoch_token = std.fmt.bufPrint(
            &epoch_storage,
            "{d}",
            .{workspace.epoch},
        ) catch unreachable;
        var workspace_copy = try task_recovery_job.OwnedWorkspaceBinding.init(
            self.allocator,
            workspace.canonical_root,
            canonical_user_home,
            epoch_token,
            switch (workspace.trust) {
                .explicitly_trusted => .explicitly_trusted,
                .temporary => .temporary,
            },
        );
        var workspace_copy_live = true;
        errdefer if (workspace_copy_live) workspace_copy.deinit();
        const skill_identity: skill_enablement_impl.WorkspaceIdentity = .{
            .workspace_id = workspace.id,
            .workspace_epoch = workspace.epoch,
        };
        const current_catalog = workspace.catalog_slot.snapshot() orelse
            return error.RecoveryUnavailable;
        var disabled_skill_policy_keys: std.ArrayList([]const u8) = .empty;
        defer disabled_skill_policy_keys.deinit(self.allocator);
        for (current_catalog.skills) |skill|
            if (!self.skill_enablement.isEnabled(skill_identity, skill.skill_policy_key))
                try disabled_skill_policy_keys.append(self.allocator, skill.skill_policy_key);
        var skill_policy = try task_recovery_job.OwnedSkillPolicy.init(
            self.allocator,
            self.skill_enablement.revision(skill_identity),
            disabled_skill_policy_keys.items,
        );
        var skill_policy_live = true;
        errdefer if (skill_policy_live) skill_policy.deinit();
        var execution = try self.execution.cloneOwned(self.allocator);
        errdefer execution.deinit();
        const target_model = try self.allocator.dupe(
            u8,
            task.durable.execution_model,
        );
        errdefer self.allocator.free(target_model);
        var mcp = try self.createRecoveryMcpAuthority();
        errdefer mcp.deinit();
        const job = try self.allocator.create(task_recovery_job.Job);
        errdefer self.allocator.destroy(job);
        job.* = .{
            .allocator = self.allocator,
            .runtime = self.agent_runtime,
            .store = self.checkpoint_store orelse return error.RecoveryUnavailable,
            .notifier = .{
                .context = self.change_notifier.context,
                .notify_fn = self.change_notifier.wake,
            },
            .catalog_limits = catalogSnapshotLimits(self.limits),
            .available_projection_bytes = self.limits.max_projection_bytes - self.projection_bytes,
            .checkpoint_limits = checkpoint_export_limits,
            .attempt = .{
                .attempt_id = attempt_id,
                .task_id = task_id,
                .binding_epoch = expected_binding_epoch,
                .checkpoint = checkpoint_copy,
                .workspace = workspace_copy,
                .skill_policy = skill_policy,
                .execution = execution.take(),
                .model = target_model,
                .provider = agentProvider(task.durable.execution_provider),
                .mcp_selection = mcp.selection,
                .mcp_catalog_generation = mcp.catalog_generation,
            },
        };
        checkpoint_copy_live = false;
        workspace_copy_live = false;
        skill_policy_live = false;
        mcp.selection = null;
        task.runtime.active_operation = .{ .restore = .{ .id = attempt_id } };
        task.runtime.restore_job = job;
        task.runtime.last_restore_failure = null;
        _ = task.runtime.worker_references.fetchAdd(1, .acq_rel);
        self.executor.enqueue(.{
            .identity = job,
            .context = job,
            .execute_fn = task_recovery_job.Job.execute,
            .cancel_fn = task_recovery_job.Job.cancelQueued,
        }) catch |err| {
            task.runtime.restore_job = null;
            task.runtime.active_operation = .none;
            const previous = task.runtime.worker_references.fetchSub(1, .release);
            std.debug.assert(previous != 0);
            job.outcome = .{ .failure = .cancelled };
            job.state.store(.cancelled, .release);
            job.deinit();
            return err;
        };
        self.next_restore_attempt_id +%= 1;
        self.bumpRevision();
        return attempt_id;
    }

    pub fn runTask(
        self: *Workbench,
        task_id: u64,
        input: TaskRunInput,
    ) Error!u64 {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        self.syncLifecycle();
        const task = self.findTask(task_id) orelse return error.UnknownTask;
        return self.runTaskAtBinding(task_id, task.durable.binding_epoch, input);
    }

    pub fn taskBindingEpoch(self: *Workbench, task_id: u64) Error!u64 {
        self.syncLifecycle();
        return (self.findTask(task_id) orelse return error.UnknownTask).durable.binding_epoch;
    }

    /// Selects the model for one Task. Credentials and their execution
    /// generation remain pinned; only the Task model binding changes. A
    /// request received during a Run is kept in runtime-only pending state
    /// and applied before the next Run.
    pub fn selectTaskModel(
        self: *Workbench,
        task_id: u64,
        expected_model: []const u8,
        expected_catalog_generation: u64,
        model: []const u8,
    ) Error!void {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        self.syncLifecycle();
        try self.requireTaskPersistenceMutation();
        const task = self.findTask(task_id) orelse return error.UnknownTask;
        if (expected_model.len == 0 or model.len == 0 or
            expected_model.len > account_contract.Limits.model_id_bytes or
            model.len > account_contract.Limits.model_id_bytes or
            !std.unicode.utf8ValidateSlice(expected_model) or
            !std.unicode.utf8ValidateSlice(model))
            return error.InvalidTaskModel;
        if (!std.mem.eql(u8, expected_model, task.durable.execution_model))
            return error.TaskModelMismatch;
        if (self.account.catalog_state != .ready or
            expected_catalog_generation == 0 or
            expected_catalog_generation != self.account.catalog_generation)
            return error.StaleCatalog;
        var found = false;
        for (self.account.model_views[0..self.account.model_count]) |candidate| {
            if (std.mem.eql(u8, candidate.id, model)) {
                found = true;
                break;
            }
        }
        if (!found) return error.StaleCatalog;
        if (hasActiveOperation(task)) {
            const replacement = try self.allocator.dupe(u8, model);
            if (task.runtime.pending_model) |old| self.allocator.free(old);
            task.runtime.pending_model = replacement;
            self.bumpRevision();
            return;
        }
        if (self.checkpointMutationPending(task)) return error.TaskBusy;
        var access = task.runtime.acquireAccess() catch return error.TaskClosing;
        var access_live = true;
        defer if (access_live) access.deinit();
        try access.setModel(model);
        const replacement = self.copyBounded(
            model,
            account_contract.Limits.model_id_bytes,
        ) catch |err| {
            if (!restoreTaskModel(&access, expected_model)) {
                access.deinit();
                access_live = false;
                self.beginTaskSessionDetachAfterModelFailureNoFail(task);
            }
            return err;
        };
        const previous = task.durable.execution_model;
        task.durable.execution_model = replacement;
        self.commitTaskStateIfConfigured() catch |err| {
            // Keep the durable binding and live Session coherent if the
            // persistence commit fails after AgentCore accepted the change.
            const must_close = err == error.TaskPersistenceOutcomeUnknown or
                !restoreTaskModel(&access, expected_model);
            if (must_close) {
                access.deinit();
                access_live = false;
                self.beginTaskSessionDetachAfterModelFailureNoFail(task);
            }
            self.freeTracked(task.durable.execution_model);
            task.durable.execution_model = previous;
            return err;
        };
        self.freeTracked(previous);
        self.bumpRevision();
    }

    pub fn runTaskAtBinding(
        self: *Workbench,
        task_id: u64,
        expected_binding_epoch: u64,
        input: TaskRunInput,
    ) Error!u64 {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        self.syncLifecycle();
        try self.requireTaskPersistenceMutation();
        const view = self.findTask(task_id) orelse return error.UnknownTask;
        if (expected_binding_epoch == 0 or expected_binding_epoch != view.durable.binding_epoch)
            return error.BindingEpochMismatch;
        if (!self.taskContinuationAvailable(view)) return error.TaskClosing;
        const workspace = self.findWorkspace(view.durable.workspace_id) orelse
            return error.WorkspaceUnavailable;
        if (workspace.kind == .manual and !workspace.visible)
            return error.WorkspaceUnavailable;
        if (workspace.authorization == .removing)
            return error.WorkspaceRemovalInProgress;
        if (workspace.authorization != .available)
            return error.WorkspaceUnavailable;
        if (workspace.epoch != view.durable.workspace_epoch)
            return error.WorkspaceEpochMismatch;
        if (workspace.kind == .automatic and switch (input) {
            .text => false,
            .skill => true,
        })
            return error.CatalogUnavailable;
        _ = try taskExecutionInput(view);
        if (hasActiveOperation(view)) return error.TaskBusy;
        if (self.checkpointMutationPending(view)) return error.TaskBusy;
        var access = view.runtime.acquireAccess() catch return error.TaskClosing;
        var access_live = true;
        errdefer if (access_live) access.deinit();
        self.applyPendingTaskModel(view, &access) catch |err| {
            access.deinit();
            access_live = false;
            if (err == error.TaskPersistenceOutcomeUnknown or
                err == error.TaskClosing)
                self.beginTaskSessionDetachAfterModelFailureNoFail(view);
            return err;
        };
        _ = try taskExecutionInput(view);
        const agent_input: lifecycle.RunInput = switch (input) {
            .text => |text| .{ .text = text },
            .skill => |skill_input| skill_admission: {
                const pinned = view.runtime.pinnedCatalogConst() orelse
                    return error.CatalogUnavailable;
                if (!std.mem.eql(
                    u8,
                    skill_input.catalog_revision,
                    pinned.revision,
                ))
                    return error.StaleCatalog;
                if (skill_input.selection_revision != pinned.selection_revision)
                    return error.StaleCatalog;
                const skill = pinned.findSkill(skill_input.skill_id) orelse
                    return error.SkillNotFound;
                if (!skill.enabled) return error.SkillUnavailable;
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
        const recent_order = if (workspace.kind == .manual)
            try self.takeWorkspaceRecentOrder()
        else
            0;
        const run_id = try access.prepareRun(agent_input);
        var prepared = true;
        errdefer if (prepared) cancelPreparedRunOrPanic(&access, run_id);
        const slot = try self.reserveRunRecord(view, input);
        var record_owned = true;
        errdefer if (record_owned) self.discardRunRecord(view, slot);
        const run = &view.durable.runs[slot].?;
        run.id = run_id;
        const job_context = try std.heap.c_allocator.create(RunJobContext);
        var job_context_owned = true;
        errdefer if (job_context_owned) job_context.destroy();
        job_context.* = .{
            .workbench = self,
            .task = view,
            .run = run,
        };
        run.checkpoint_export_context = .{
            .task_id = view.durable.id,
            .binding_epoch = view.durable.binding_epoch,
            .terminal_kind = .run,
            .terminal_id = run_id,
            .last_run_id = run_id,
            .last_compact_id = latestCompactId(view),
            .model = run.execution_model,
        };
        const previous_title = view.durable.title;
        const previous_title_redacted = view.durable.title_redacted;
        const provisional_title_applied = self.applyProvisionalTaskTitle(view, run);
        run.automatic_title.provisional_applied = provisional_title_applied;
        const previous_active_run_id = view.runtime.active_run_id;
        const previous_active_operation = view.runtime.active_operation;
        const previous_task_recent_order = view.durable.recent_order;
        const previous_next_task_recent_order = self.next_task_recent_order;
        const previous_workspace_recent_order = workspace.recent_order;
        view.runtime.active_run_id = run_id;
        view.runtime.active_operation = .{ .run = run_id };
        view.runtime.cancel_requested = false;
        self.touchTask(view);
        if (workspace.kind == .manual) workspace.recent_order = recent_order;
        self.commitTaskStateIfConfigured() catch |err| {
            view.runtime.active_run_id = previous_active_run_id;
            view.runtime.active_operation = previous_active_operation;
            view.durable.recent_order = previous_task_recent_order;
            self.next_task_recent_order = previous_next_task_recent_order;
            if (workspace.kind == .manual) {
                workspace.recent_order = previous_workspace_recent_order;
                self.next_workspace_recent_order = recent_order;
            }
            view.durable.next_run_generation -= 1;
            if (provisional_title_applied)
                self.rollbackProvisionalTaskTitle(
                    view,
                    previous_title,
                    previous_title_redacted,
                );
            return err;
        };
        if (provisional_title_applied) self.allocator.free(previous_title);
        job_context.access = access.take();
        access_live = false;
        _ = view.runtime.worker_references.fetchAdd(1, .acq_rel);
        run.worker_reference_held.store(true, .release);
        self.executor.enqueue(.{
            .identity = run,
            .context = job_context,
            .execute_fn = executeRunJob,
            .cancel_fn = cancelRunJob,
        }) catch |err| {
            publishAutomaticTitleFallback(run);
            releaseWorkerReference(view, run);
            cancelPreparedRunOrPanic(job_context.sessionAccess(), run_id);
            prepared = false;
            job_context.destroy();
            job_context_owned = false;
            _ = commitTerminal(
                run,
                .interrupted,
                .interrupted,
                .queue_capacity_failure,
                .reusable,
                "",
                false,
            );
            run.terminal_observed = true;
            run.event_stream_finalized = true;
            view.runtime.active_operation = .none;
            self.commitTaskStateNoFail();
            record_owned = false;
            self.bumpRevision();
            return err;
        };
        job_context_owned = false;
        prepared = false;
        record_owned = false;
        self.bumpRevision();
        return run_id;
    }

    fn applyPendingTaskModel(
        self: *Workbench,
        task: *TaskView,
        access: *task_agent_session.Access,
    ) Error!void {
        const pending = task.runtime.pending_model orelse return;
        const previous = task.durable.execution_model;
        try access.setModel(pending);
        const replacement = self.copyBounded(
            pending,
            account_contract.Limits.model_id_bytes,
        ) catch |err| {
            if (!restoreTaskModel(access, previous)) return error.TaskClosing;
            return err;
        };
        task.durable.execution_model = replacement;
        self.commitTaskStateIfConfigured() catch |err| {
            const coherent = if (err == error.TaskPersistenceOutcomeUnknown) blk: {
                break :blk false;
            } else restoreTaskModel(access, previous);
            self.freeTracked(task.durable.execution_model);
            task.durable.execution_model = previous;
            if (coherent) task.runtime.pending_model = pending;
            if (!coherent and err != error.TaskPersistenceOutcomeUnknown)
                return error.TaskClosing;
            return err;
        };
        task.runtime.pending_model = null;
        self.freeTracked(previous);
        self.allocator.free(pending);
    }

    /// Attempts to restore the durable model after a failed Product mutation.
    /// The caller closes the Binding if Agent rejects this repair.
    fn restoreTaskModel(
        access: *task_agent_session.Access,
        model: []const u8,
    ) bool {
        access.setModel(model) catch {
            return false;
        };
        return true;
    }

    fn beginTaskSessionDetachAfterModelFailureNoFail(
        self: *Workbench,
        task: *TaskView,
    ) void {
        _ = self.beginTaskSessionDetach(task) catch {
            // A model mutation whose rollback failed must never remain
            // admissible merely because the close worker could not start.
            if (task.runtime.attached()) |attached|
                attached.health = .session_poisoned;
            self.bumpRevision();
        };
    }

    pub fn compactTaskAtBinding(
        self: *Workbench,
        task_id: u64,
        expected_binding_epoch: u64,
    ) Error!u64 {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        self.syncLifecycle();
        try self.requireTaskPersistenceMutation();
        const view = self.findTask(task_id) orelse return error.UnknownTask;
        if (expected_binding_epoch == 0 or
            expected_binding_epoch != view.durable.binding_epoch)
            return error.BindingEpochMismatch;
        if (!self.taskContinuationAvailable(view)) return error.TaskClosing;
        if (hasActiveOperation(view)) return error.TaskBusy;
        if (self.checkpointMutationPending(view)) return error.TaskBusy;
        if (hasUnfinalizedTerminalEvents(view)) return error.TaskBusy;
        if (findEmpty(CompactRecord, view.durable.compacts) == null)
            return error.CompactCapacity;
        const after_run_id = lastFinalizedRunId(view) orelse
            return error.NoSuchRun;
        _ = try taskExecutionInput(view);
        var access = view.runtime.acquireAccess() catch return error.TaskClosing;
        var access_live = true;
        errdefer if (access_live) access.deinit();
        const operation_id = try access.prepareCompact();
        var prepared = true;
        errdefer if (prepared)
            cancelPreparedCompactOrPanic(&access, operation_id);
        const slot = try self.reserveCompactRecord(view, operation_id, after_run_id);
        var record_owned = true;
        errdefer if (record_owned) self.discardCompactRecord(view, slot);
        const compact = &view.durable.compacts[slot].?;
        const job_context = try std.heap.c_allocator.create(CompactJobContext);
        var job_context_owned = true;
        errdefer if (job_context_owned) job_context.destroy();
        job_context.* = .{
            .workbench = self,
            .task = view,
            .compact = compact,
        };
        compact.checkpoint_export_context = .{
            .task_id = view.durable.id,
            .binding_epoch = view.durable.binding_epoch,
            .terminal_kind = .compact,
            .terminal_id = operation_id,
            .last_run_id = after_run_id,
            .last_compact_id = operation_id,
            .model = view.durable.execution_model,
        };
        const previous_active_operation = view.runtime.active_operation;
        const previous_task_recent_order = view.durable.recent_order;
        const previous_next_task_recent_order = self.next_task_recent_order;
        view.runtime.active_operation = .{ .compact = operation_id };
        self.touchTask(view);
        self.commitTaskStateIfConfigured() catch |err| {
            view.runtime.active_operation = previous_active_operation;
            view.durable.recent_order = previous_task_recent_order;
            self.next_task_recent_order = previous_next_task_recent_order;
            return err;
        };
        job_context.access = access.take();
        access_live = false;
        _ = view.runtime.worker_references.fetchAdd(1, .acq_rel);
        compact.worker_reference_held.store(true, .release);
        self.executor.enqueue(.{
            .identity = compact,
            .context = job_context,
            .execute_fn = executeCompactJob,
            .cancel_fn = cancelCompactJob,
        }) catch |err| {
            releaseCompactWorkerReference(view, compact);
            cancelPreparedCompactOrPanic(job_context.sessionAccess(), operation_id);
            prepared = false;
            job_context.destroy();
            job_context_owned = false;
            _ = commitCompactProductTerminal(
                compact,
                .interrupted,
                .resource_limit,
                .reusable,
                .{},
                0,
                0,
                "",
                false,
            );
            compact.terminal_observed = true;
            view.runtime.active_operation = .none;
            self.commitTaskStateNoFail();
            record_owned = false;
            self.bumpRevision();
            return err;
        };
        job_context_owned = false;
        prepared = false;
        record_owned = false;
        self.bumpRevision();
        return operation_id;
    }

    pub fn cancelCompact(
        self: *Workbench,
        task_id: u64,
        operation_id: u64,
    ) Error!void {
        self.syncLifecycle();
        const view = self.findTask(task_id) orelse return error.UnknownTask;
        const active_id = switch (view.runtime.active_operation) {
            .compact => |id| id,
            .none, .run, .restore => return error.NoSuchCompact,
        };
        if (operation_id == 0 or operation_id != active_id)
            return error.NoSuchCompact;
        const compact = findCompact(view.durable.compacts, operation_id) orelse
            return error.NoSuchCompact;
        _ = self.cancelCompactRecord(view, compact, .user_cancel);
    }

    fn cancelCompactRecord(
        self: *Workbench,
        view: *TaskView,
        compact: *CompactRecord,
        interruption: lifecycle.ExternalInterruption,
    ) CompactTerminationDispatch {
        if (compactTerminalPayload(compact) != null) {
            self.syncLifecycle();
            return .already_terminal;
        }
        const pending = pendingInterruption(interruption);
        const prior = compact.pending_interruption.cmpxchgStrong(
            .none,
            pending,
            .acq_rel,
            .acquire,
        );
        if (compactTerminalPayload(compact) != null) {
            self.syncLifecycle();
            return .already_terminal;
        }
        if (self.executor.cancel(compact)) {
            self.touchTask(view);
            self.syncLifecycle();
            self.commitTaskStateNoFail();
            return .queued_aborted;
        } else {
            var access = view.runtime.acquireAccess() catch {
                self.syncLifecycle();
                return .session_closing;
            };
            defer access.deinit();
            access.requestCompactCancellation(
                compact.id,
                pendingExternalInterruption(compact),
            ) catch |err| switch (err) {
                error.NoSuchCompact, error.SessionClosing => {
                    self.syncLifecycle();
                    return if (err == error.NoSuchCompact)
                        .already_terminal
                    else
                        .session_closing;
                },
            };
        }
        self.touchTask(view);
        self.commitTaskStateNoFail();
        self.bumpRevision();
        return if (prior == null) .requested else .already_requested;
    }

    pub fn taskExecutionIdentity(
        self: *Workbench,
        task_id: u64,
    ) Error!ExecutionIdentity {
        const task = self.findTask(task_id) orelse return error.UnknownTask;
        return .{
            .generation = task.durable.execution_generation,
            .provider = task.durable.execution_provider,
            .model = task.durable.execution_model,
        };
    }

    pub fn runExecutionIdentity(
        self: *Workbench,
        task_id: u64,
        run_id: u64,
    ) Error!ExecutionIdentity {
        const task = self.findTask(task_id) orelse return error.UnknownTask;
        const run = findRun(task.durable.runs, run_id) orelse
            return error.NoSuchRun;
        return .{
            .generation = run.execution_generation,
            .provider = run.execution_provider,
            .model = run.execution_model,
        };
    }

    /// Lifecycle tests use this read-only counter to verify ownership rollback
    /// without exposing projection accounting through the Renderer contract.
    pub fn projectionBytesForTest(self: *const Workbench) usize {
        return self.projection_bytes;
    }

    pub fn cancel(self: *Workbench, task_id: u64, run_id: u64) Error!void {
        self.syncLifecycle();
        const view = self.findTask(task_id) orelse return error.UnknownTask;
        const run = findRun(view.durable.runs, run_id) orelse return error.NoSuchRun;
        if (terminalPayload(run) != null) return;
        var access = view.runtime.acquireAccess() catch return error.TaskClosing;
        defer access.deinit();
        const record = self.prepareCancelledUiRecord(
            &access,
            run_id,
            run.redaction_secret,
        );
        const dispatch = requestRunTermination(run, .user_cancel);
        if (self.executor.cancel(run)) {
            run.terminal_observed = true;
            if (record) |value| self.pushUiRecord(view, value);
            view.runtime.cancel_requested = false;
            self.touchTask(view);
            self.commitTaskStateNoFail();
            self.bumpRevision();
            return;
        }
        const stopping = switch (dispatch) {
            .pending, .requested, .already_requested => true,
            .already_finishing, .already_terminal, .stale_run, .session_closing => false,
        };
        if (!stopping) {
            self.syncLifecycle();
            return;
        }
        if (record) |value| self.pushUiRecord(view, value);
        view.runtime.cancel_requested = true;
        _ = setActivePhase(run, .stopping);
        self.touchTask(view);
        self.commitTaskStateNoFail();
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
        try self.requireTaskPersistenceMutation();
        const view = self.findTask(task_id) orelse return error.UnknownTask;
        const run = findRun(view.durable.runs, run_id) orelse return error.NoSuchRun;
        var access = view.runtime.acquireAccess() catch return error.TaskClosing;
        defer access.deinit();
        const record = self.prepareUiRecord(
            &access,
            run_id,
            request_id,
            response,
            run.redaction_secret,
        );
        const history_slot = view.durable.ui_history_next;
        const previous_history_record = view.durable.ui_history[history_slot];
        const previous_history_next = view.durable.ui_history_next;
        const previous_history_count = view.durable.ui_history_count;
        const previous_pending_request_id = view.runtime.pending_ui_request_id;
        const previous_pending_order = view.runtime.pending_ui_order;
        const previous_activity_order = run.next_activity_order;
        const previous_task_recent_order = view.durable.recent_order;
        const previous_next_task_recent_order = self.next_task_recent_order;
        self.pushUiRecord(view, record);
        self.touchTask(view);
        self.commitTaskStateIfConfigured() catch |err| {
            view.durable.ui_history[history_slot] = previous_history_record;
            view.durable.ui_history_next = previous_history_next;
            view.durable.ui_history_count = previous_history_count;
            view.runtime.pending_ui_request_id = previous_pending_request_id;
            view.runtime.pending_ui_order = previous_pending_order;
            run.next_activity_order = previous_activity_order;
            view.durable.recent_order = previous_task_recent_order;
            self.next_task_recent_order = previous_next_task_recent_order;
            return err;
        };
        const response_result = access.respondPermission(
            run_id,
            request_id,
            agentPermissionChoice(response.permission),
        );
        response_result catch |err| {
            view.durable.ui_history[history_slot] = previous_history_record;
            view.durable.ui_history_next = previous_history_next;
            view.durable.ui_history_count = previous_history_count;
            view.runtime.pending_ui_request_id = previous_pending_request_id;
            view.runtime.pending_ui_order = previous_pending_order;
            run.next_activity_order = previous_activity_order;
            view.durable.recent_order = previous_task_recent_order;
            self.next_task_recent_order = previous_next_task_recent_order;
            self.commitTaskStateNoFail();
            return err;
        };
        self.bumpRevision();
    }

    fn detachTaskSession(self: *Workbench, task_id: u64) Error!void {
        self.syncLifecycle();
        const view = self.findTask(task_id) orelse return error.UnknownTask;
        if (try self.beginTaskSessionDetach(view)) self.bumpRevision();
    }

    /// Starts or retries the attachment-owned Session release without
    /// recursively synchronizing Workbench lifecycle. Callers that publish
    /// outside `syncLifecycle` are responsible for bumping the revision.
    fn beginTaskSessionDetach(self: *Workbench, view: *TaskView) Error!bool {
        if (!hasActiveOperation(view) and self.checkpointMutationPending(view)) {
            cancelTaskCheckpoints(view);
            return error.TaskBusy;
        }
        if (view.runtime.close_thread != null) return error.CloseInProgress;
        const retrying_closing_session = view.runtime.close_failed and
            view.runtime.hasClosingSession();
        if (view.runtime.live() == null) return false;
        const prior_health = if (view.runtime.attached()) |attached|
            attached.health
        else
            task_runtime.AttachedHealth.available;
        if (switch (view.runtime.active_operation) {
            .compact => true,
            .none, .run, .restore => false,
        }) {
            const compact_id = switch (view.runtime.active_operation) {
                .compact => |id| id,
                .none, .run, .restore => unreachable,
            };
            const compact = findCompact(view.durable.compacts, compact_id) orelse
                return error.NoSuchCompact;
            _ = self.cancelCompactRecord(view, compact, .session_close);
        }
        var observation_access = view.runtime.acquireAccess() catch null;
        defer if (observation_access) |*access| access.deinit();
        const cancelled_ui = if (view.runtime.pending_ui_request_id != 0 and
            observation_access != null)
            self.prepareCancelledUiRecord(
                &observation_access.?,
                view.runtime.active_run_id,
                if (findRun(view.durable.runs, view.runtime.active_run_id)) |run|
                    run.redaction_secret
                else if (view.runtime.execution()) |execution|
                    execution.input().api_key
                else
                    &.{},
            )
        else
            null;
        if (findRun(view.durable.runs, view.runtime.active_run_id)) |run| {
            const dispatch = requestRunTermination(run, .session_close);
            if (self.executor.cancel(run)) {
                run.terminal_observed = true;
            } else consumeLifecycleTermination(dispatch, run.id);
        }
        if (!retrying_closing_session)
            std.debug.assert(view.runtime.beginClosing());
        const binding = view.runtime.closingWorkerBinding() orelse unreachable;
        view.runtime.cancel_requested = switch (view.runtime.active_operation) {
            .run => true,
            .none, .compact, .restore => false,
        };
        if (findRun(view.durable.runs, view.runtime.active_run_id)) |run| {
            if (!isTerminalPhase(runPhase(run))) _ = setActivePhase(run, .stopping);
        }
        view.runtime.close_failed = false;
        view.runtime.close_completion.store(.running, .release);
        view.runtime.close_thread = std.Thread.spawn(.{}, closeWorker, .{
            &view.runtime.close_completion,
            binding,
            self.change_notifier,
        }) catch |err| {
            view.runtime.close_completion.store(.none, .release);
            if (retrying_closing_session)
                view.runtime.close_failed = true
            else
                view.runtime.restoreCloseFailure(prior_health);
            return err;
        };
        if (cancelled_ui) |record|
            self.pushUiRecord(view, record);
        self.touchTask(view);
        self.commitTaskStateNoFail();
        return true;
    }

    pub fn renameTask(self: *Workbench, task_id: u64, title: []const u8) Error!void {
        self.syncLifecycle();
        try self.requireTaskPersistenceMutation();
        const view = self.findTask(task_id) orelse return error.UnknownTask;
        if (view.deletion == .deleting) return error.TaskBusy;
        const trimmed = std.mem.trim(u8, title, " \t\r\n");
        if (trimmed.len == 0 or trimmed.len > self.limits.max_task_title_bytes or
            !std.unicode.utf8ValidateSlice(trimmed))
            return error.InvalidTaskTitle;
        for (trimmed) |byte| if (byte < 0x20) return error.InvalidTaskTitle;
        const previous_title = view.durable.title;
        const previous_redacted = view.durable.title_redacted;
        const previous_recent_order = view.durable.recent_order;
        const previous_next_recent_order = self.next_task_recent_order;
        self.projection_bytes -= previous_title.len;
        const projected = self.copyProjected(
            trimmed,
            self.limits.max_task_title_bytes,
            if (view.runtime.execution()) |execution| execution.input().api_key else &.{},
        ) catch |err| {
            self.projection_bytes += previous_title.len;
            return err;
        };
        view.durable.title = projected.value;
        view.durable.title_redacted = projected.redacted;
        self.touchTask(view);
        self.commitTaskStateIfConfigured() catch |err| {
            self.freeTracked(view.durable.title);
            view.durable.title = previous_title;
            self.projection_bytes += previous_title.len;
            view.durable.title_redacted = previous_redacted;
            view.durable.recent_order = previous_recent_order;
            self.next_task_recent_order = previous_next_recent_order;
            return err;
        };
        self.allocator.free(previous_title);
        self.markAutomaticTitleUserOverride(view);
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
        try self.requireTaskPersistenceMutation();
        const view = self.findTask(task_id) orelse return error.UnknownTask;
        if (view.deletion == .deleting or taskLifecycle(view) == .closing or
            hasActiveOperation(view)) return error.TaskBusy;
        if (view.durable.archived == archived) return;
        const previous_recent_order = view.durable.recent_order;
        const previous_next_recent_order = self.next_task_recent_order;
        const previous_deletion = view.deletion;
        view.durable.archived = archived;
        if (!archived and view.deletion == .failed) view.deletion = .idle;
        self.touchTask(view);
        self.commitTaskStateIfConfigured() catch |err| {
            view.durable.archived = !archived;
            view.deletion = previous_deletion;
            view.durable.recent_order = previous_recent_order;
            self.next_task_recent_order = previous_next_recent_order;
            return err;
        };
        self.bumpRevision();
    }

    pub fn deleteTask(self: *Workbench, task_id: u64) Error!void {
        self.syncLifecycle();
        try self.requireTaskPersistenceMutation();
        const index = self.findTaskIndex(task_id) orelse return error.UnknownTask;
        const view = &(self.tasks[index] orelse unreachable);
        if (!view.durable.archived) return error.TaskNotArchived;
        if (view.deletion == .deleting) return;
        view.deletion = .deleting;
        _ = self.advanceTaskDeletion(index) catch |err| {
            if (self.tasks[index]) |*retained|
                retained.deletion = .failed;
            self.bumpRevision();
            return err;
        };
        self.bumpRevision();
    }

    /// Advances one accepted deletion intent as far as current owner facts
    /// permit. Waiting is not an error: later lifecycle synchronization calls
    /// this function again after checkpoint, worker, event, or Session state
    /// changes. Only an explicit retry changes `.failed` back to `.deleting`.
    fn advanceTaskDeletion(self: *Workbench, index: usize) Error!bool {
        const view = &(self.tasks[index] orelse return error.UnknownTask);
        if (view.deletion == .deleting) std.debug.assert(view.durable.archived);
        const session: task_deletion.Session = if (view.runtime.hasAttachedSession())
            .attached
        else if (view.runtime.hasClosingSession())
            if (view.runtime.close_failed) .retryable_close_failure else .closing
        else
            .detached;
        return switch (task_deletion.decide(view.deletion, .{
            .checkpoint_pending = self.checkpointMutationPending(view),
            .close_operation_running = view.runtime.close_completion.load(.acquire) == .running or
                view.runtime.close_thread != null,
            .unfinalized_terminal_events = hasUnfinalizedTerminalEvents(view),
            .session = session,
            .worker_references = view.runtime.worker_references.load(.acquire),
        })) {
            .wait => false,
            .cancel_checkpoint => cancel: {
                cancelTaskCheckpoints(view);
                break :cancel false;
            },
            .release_session => try self.beginTaskSessionDetach(view),
            .commit_record_deletion => commit: {
                try self.finalizeTaskDeletion(index);
                break :commit true;
            },
        };
    }

    fn finalizeTaskDeletion(self: *Workbench, index: usize) Error!void {
        const view = &(self.tasks[index] orelse return error.UnknownTask);
        std.debug.assert(view.durable.archived);
        std.debug.assert(view.deletion == .deleting);
        std.debug.assert(!view.runtime.hasAttachedSession());
        std.debug.assert(!view.runtime.hasClosingSession());
        std.debug.assert(view.runtime.worker_references.load(.acquire) == 0);
        std.debug.assert(!hasUnfinalizedTerminalEvents(view));
        std.debug.assert(!self.checkpointMutationPending(view));
        const workspace_id = view.durable.workspace_id;
        const release_automatic_workspace = if (self.findWorkspace(workspace_id)) |workspace|
            workspace.kind == .automatic
        else
            false;
        var removed_task = view.*;
        self.tasks[index] = null;
        var removed_workspace_index: ?usize = null;
        var removed_workspace: WorkspaceView = undefined;
        if (release_automatic_workspace) {
            for (self.workspaces, 0..) |*entry, workspace_index| {
                const workspace = &(entry.* orelse continue);
                if (workspace.id != workspace_id) continue;
                removed_workspace = workspace.*;
                entry.* = null;
                removed_workspace_index = workspace_index;
                break;
            }
        }
        self.commitTaskStateIfConfigured() catch |err| {
            self.tasks[index] = removed_task;
            if (removed_workspace_index) |workspace_index|
                self.workspaces[workspace_index] = removed_workspace;
            return err;
        };
        if (self.checkpoint_store) |store| store.deleteTask(removed_task.durable.id);
        self.deinitTaskView(&removed_task);
        if (removed_workspace_index != null)
            self.deinitWorkspaceView(&removed_workspace);
    }

    fn advanceRequestedTaskDeletionsNoFail(self: *Workbench) bool {
        var changed = false;
        for (self.tasks, 0..) |*entry, index| {
            const view = &(entry.* orelse continue);
            if (view.deletion != .deleting) continue;
            const advanced = self.advanceTaskDeletion(index) catch {
                // The accepted deletion intent cannot manufacture a durable
                // success. Leave the archived Task intact and allow an
                // explicit retry after persistence recovers.
                if (self.tasks[index]) |*retained|
                    retained.deletion = .failed;
                changed = true;
                continue;
            };
            changed = advanced or changed;
        }
        return changed;
    }

    pub fn currentRevision(self: *Workbench) u64 {
        self.syncLifecycle();
        return self.revision;
    }

    pub fn checkpointStoreHealth(self: *const Workbench) checkpoint_store.Health {
        return self.checkpoint_store_health.load(.acquire);
    }

    /// Reconciles worker-owned lifecycle state into the main-thread product
    /// projection. It never allocates, so an effects wake cannot fail merely
    /// while publishing a terminal state.
    pub fn syncLifecycle(self: *Workbench) void {
        var changed = self.commitCatalogJobsNoFail();
        changed = self.commitMcpRefreshJobNoFail() or changed;
        changed = self.syncMcpHealthNoFail() or changed;
        var durable_changed = false;
        var mcp_refresh_needed = false;
        for (self.tasks) |*entry| {
            const view = &(entry.* orelse continue);
            const recovery_commit = self.commitRecoveryJobNoFail(view);
            changed = recovery_commit.changed or changed;
            durable_changed = recovery_commit.durable_changed or durable_changed;
            if (self.commitAutomaticTitlesNoFail(view)) {
                changed = true;
                durable_changed = true;
            }
            mcp_refresh_needed = recovery_commit.mcp_refresh_needed or mcp_refresh_needed;
            const close_completion = view.runtime.close_completion.load(.acquire);
            // Session close may finish after Agent execution but before the
            // main thread has drained callbacks already enqueued for the Run.
            // Keep the Task in `closing` until those events and the immutable
            // terminal result become product-visible together.
            if (close_completion != .none and close_completion != .running and
                !hasUnfinalizedTerminalEvents(view))
            {
                view.runtime.close_thread.?.join();
                view.runtime.close_thread = null;
                std.debug.assert(view.runtime.hasClosingSession());
                view.runtime.close_completion.store(.none, .release);
                switch (close_completion) {
                    .closed => {
                        std.debug.assert(
                            view.runtime.closingWorkerBinding().?.state() == .released,
                        );
                        var live = view.runtime.detach(.released);
                        self.releaseExecutionValueNoFail(view, &live.execution);
                        if (live.pinned_catalog) |*snapshot| {
                            self.projection_bytes -= snapshot.projected_bytes;
                            snapshot.deinit();
                        }
                        view.runtime.close_failed = false;
                    },
                    .failed_reusable, .failed_poisoned, .failed_closing => {
                        view.runtime.close_failed = true;
                        if (view.deletion == .deleting)
                            view.deletion = .failed;
                        switch (close_completion) {
                            .failed_reusable => view.runtime.restoreCloseFailure(.available),
                            .failed_poisoned => view.runtime.restoreCloseFailure(.session_poisoned),
                            .failed_closing => {},
                            else => unreachable,
                        }
                    },
                    .none, .running => unreachable,
                }
                view.runtime.cancel_requested = false;
                changed = true;
            }
            // A pending UI request can only exist while a Run worker still
            // owns its Task reference. Avoid touching an idle attachment when
            // there is no Agent-to-Workbench handoff to observe.
            var observation_access = if (view.runtime.worker_references.load(.acquire) != 0 and
                view.runtime.active_run_id != 0)
                view.runtime.acquireAccess() catch null
            else
                null;
            defer if (observation_access) |*access| access.deinit();
            const pending = if (observation_access) |*access|
                access.pendingUiObservation()
            else
                null;
            const pending_request_id = if (pending) |value| value.request_id else 0;
            if (view.runtime.pending_ui_request_id != pending_request_id) {
                view.runtime.pending_ui_request_id = pending_request_id;
                view.runtime.pending_ui_order = 0;
                if (pending) |observation| {
                    if (findRun(view.durable.runs, observation.run_id)) |pending_run|
                        view.runtime.pending_ui_order = takeActivityOrder(pending_run);
                }
                changed = true;
            }
            if (switch (view.runtime.active_operation) {
                .compact => true,
                .none, .run, .restore => false,
            }) {
                const operation_id = switch (view.runtime.active_operation) {
                    .compact => |id| id,
                    .none, .run, .restore => unreachable,
                };
                const compact = findCompact(view.durable.compacts, operation_id) orelse {
                    view.runtime.active_operation = .none;
                    changed = true;
                    continue;
                };
                if (compactTerminalPayload(compact)) |terminal| {
                    if (!compact.terminal_observed) {
                        foldTerminalDisposition(
                            view,
                            terminal.session_disposition_at_completion,
                        );
                        compact.terminal_observed = true;
                    }
                    view.runtime.active_operation = .none;
                    changed = true;
                    durable_changed = true;
                }
                continue;
            }
            const run = findRun(view.durable.runs, view.runtime.active_run_id) orelse continue;
            if (productTerminalFacts(run)) |terminal| {
                var terminal_durable_changed = false;
                view.runtime.cancel_requested = false;
                if (switch (view.runtime.active_operation) {
                    .run => |id| id == run.id,
                    .none, .compact, .restore => false,
                }) {
                    view.runtime.active_operation = .none;
                    changed = true;
                    terminal_durable_changed = true;
                }
                if (!run.terminal_observed) {
                    foldTerminalDisposition(view, terminal.session_disposition_at_completion);
                    run.terminal_observed = true;
                    changed = true;
                    terminal_durable_changed = true;
                }
                durable_changed = durable_changed or terminal_durable_changed;
                continue;
            }
            const next_phase: RunPhase = if (view.runtime.cancel_requested)
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
        if (self.finalizeWorkspaceRemovalsNoFail()) {
            changed = true;
            durable_changed = true;
        }
        if (self.reconcileScheduledTaskBindingsNoFail()) changed = true;
        if (self.reconcileScheduledTaskCompletionsNoFail()) changed = true;
        if (durable_changed) self.commitTaskStateNoFail();
        for (self.tasks) |*entry| {
            const view = &(entry.* orelse continue);
            if (self.commitCheckpointPostprocessesNoFail(view)) changed = true;
        }
        if (self.advanceRequestedTaskDeletionsNoFail()) changed = true;
        if (changed) self.bumpRevision();
        if (mcp_refresh_needed) self.recoverExpiredMcpCatalogNoFail();
    }

    const RecoveryCommit = struct {
        changed: bool = false,
        durable_changed: bool = false,
        mcp_refresh_needed: bool = false,
    };

    fn commitRecoveryJobNoFail(
        self: *Workbench,
        task: *TaskView,
    ) RecoveryCommit {
        const job = task.runtime.restore_job orelse return .{};
        if (!job.completionReady()) return .{};
        const operation_matches = switch (task.runtime.active_operation) {
            .restore => |attempt| attempt.id == job.attempt.attempt_id,
            .none, .run, .compact => false,
        };
        var durable_changed = false;
        var mcp_refresh_needed = false;
        if (job.takeCandidate()) |candidate_value| {
            var candidate = candidate_value;
            const workspace = self.findWorkspace(task.durable.workspace_id);
            const record_matches = if (task.durable.checkpoint) |record|
                checkpointIdentityEqual(record.blob, job.attempt.checkpoint.blob)
            else
                false;
            const commit_allowed = operation_matches and
                !self.shutting_down and
                !task.durable.archived and
                task.runtime.attachment == .detached and
                task.durable.binding_epoch == job.attempt.binding_epoch and
                record_matches and
                self.recoveryExecutionExact(task) and
                self.recoveryAuthorityStable(workspace) and
                optionalU64Equal(
                    mcp_policy.recoveryGeneration(if (self.mcp) |*mcp| mcp else null, self.mcp_refresh_job != null),
                    job.attempt.mcp_catalog_generation,
                ) and
                candidate.pinned_catalog.projected_bytes <=
                    self.limits.max_projection_bytes - self.projection_bytes;
            if (commit_allowed) {
                self.projection_bytes += candidate.pinned_catalog.projected_bytes;
                task.runtime.last_restore_permission = .{
                    .restored_rules = candidate.report.restored_permission_rules,
                    .invalidated_rules = candidate.report.invalidated_permission_rules,
                };
                task.runtime.attachment = .{ .attached = .{
                    .binding = candidate.takeBinding(),
                    .execution = candidate.takeExecution(),
                    .pinned_catalog = candidate.takeCatalog(),
                } };
                task.runtime.last_restore_failure = null;
            } else if (!candidate.discard()) {
                self.recovery_poisoned = true;
                task.runtime.last_restore_failure = .candidate_cleanup_failed;
            }
        } else if (job.failure()) |failure| {
            task.runtime.last_restore_failure = failure;
            mcp_refresh_needed = failure == .mcp_not_refreshed and
                optionalU64Equal(
                    mcp_policy.recoveryGeneration(if (self.mcp) |*mcp| mcp else null, self.mcp_refresh_job != null),
                    job.attempt.mcp_catalog_generation,
                );
            switch (failure) {
                .checkpoint_missing => {
                    task.durable.checkpoint_anchor = .blob_missing;
                    durable_changed = true;
                },
                .checkpoint_mismatch => {
                    task.durable.checkpoint_anchor = .blob_mismatch;
                    durable_changed = true;
                },
                .checkpoint_io => {
                    // A transient blob read failure is an attempt fact; the
                    // durable anchor stays valid and recovery stays retryable.
                    task.durable.checkpoint_attempt = .io_failed;
                    durable_changed = true;
                },
                .candidate_cleanup_failed => self.recovery_poisoned = true,
                else => {},
            }
        }
        task.runtime.restore_job = null;
        task.runtime.active_operation = .none;
        const references = task.runtime.worker_references.fetchSub(1, .release);
        std.debug.assert(references != 0);
        job.deinit();
        return .{
            .changed = true,
            .durable_changed = durable_changed,
            .mcp_refresh_needed = mcp_refresh_needed,
        };
    }

    fn commitCheckpointPostprocessesNoFail(
        self: *Workbench,
        task: *TaskView,
    ) bool {
        var changed = false;
        for (task.durable.runs) |*entry| {
            const run = &(entry.* orelse continue);
            if (!run.event_stream_finalized) continue;
            if (!self.commitCheckpointPostprocessNoFail(task, &run.checkpoint)) continue;
            if (run.checkpoint.state.load(.acquire) == .settled and
                run.worker_reference_held.load(.acquire))
                releaseWorkerReference(task, run);
            changed = true;
        }
        for (task.durable.compacts) |*entry| {
            const compact = &(entry.* orelse continue);
            if (!compact.terminal_observed) continue;
            if (!self.commitCheckpointPostprocessNoFail(task, &compact.checkpoint)) continue;
            if (compact.checkpoint.state.load(.acquire) == .settled)
                releaseCompactWorkerReference(task, compact);
            changed = true;
        }
        return changed;
    }

    fn commitCheckpointPostprocessNoFail(
        self: *Workbench,
        task: *TaskView,
        postprocess: *CheckpointPostprocess,
    ) bool {
        switch (postprocess.state.load(.acquire)) {
            .none, .exporting, .settled => return false,
            .failure_ready => {
                const attempt = postprocess.payload.failure;
                const previous = task.durable.checkpoint_attempt;
                task.durable.checkpoint_attempt = attempt;
                self.commitTaskStateIfConfigured() catch {
                    task.durable.checkpoint_attempt = previous;
                };
                postprocess.payload = .none;
                postprocess.state.store(.settled, .release);
                return true;
            },
            .candidate_ready => {
                const candidate = &postprocess.payload.candidate;
                const history_commit_started = std.Io.Timestamp.now(self.io, .awake);
                self.commitTaskStateWithCheckpoint(.{
                    .task_id = task.durable.id,
                    .record = &candidate.record,
                    .anchor = .available,
                }) catch |err| {
                    if (err == error.TaskPersistenceOutcomeUnknown) {
                        task.durable.checkpoint_attempt = .outcome_unknown;
                        postprocess.state.store(.store_outcome_unknown, .release);
                        return true;
                    }
                    candidate.record.deinit(self.allocator);
                    postprocess.payload = .none;
                    postprocess.state.store(.settled, .release);
                    return true;
                };
                const history_commit_finished = std.Io.Timestamp.now(self.io, .awake);
                if (builtin.mode == .Debug) std.log.info(
                    "checkpoint.commit task_id={d} terminal_kind={s} terminal_id={d} byte_size={d} chunk_count={d} export_duration_ns={d} history_commit_duration_ns={d}",
                    .{
                        task.durable.id,
                        @tagName(candidate.record.anchor.terminal),
                        candidate.record.anchor.terminal.id(),
                        candidate.record.blob.byte_size,
                        candidate.metrics.chunk_count,
                        candidate.metrics.export_duration_ns,
                        history_commit_started.durationTo(history_commit_finished).nanoseconds,
                    },
                );
                const old_identity = if (task.durable.checkpoint) |old| old.blob else null;
                if (task.durable.checkpoint) |*old|
                    old.deinit(self.allocator);
                task.durable.checkpoint = candidate.record;
                candidate.record = undefined;
                task.durable.checkpoint_anchor = .available;
                task.durable.checkpoint_attempt = .none;
                postprocess.payload = .none;
                postprocess.state.store(.settled, .release);
                if (old_identity) |identity|
                    if (self.checkpoint_store) |store| store.delete(identity);
                return true;
            },
            .store_outcome_unknown => {
                if (task.durable.checkpoint_attempt == .outcome_unknown)
                    return false;
                task.durable.checkpoint_attempt = .outcome_unknown;
                return true;
            },
        }
    }

    /// Consumes the canonical Agent event stream and owns the complete product
    /// terminal-publication barrier. This operation is main-loop-thread only.
    /// It remains valid after Executor and Agent Runtime shutdown, does not
    /// depend on Executor liveness, and must run before Agent Runtime deinit.
    pub fn drainAgentEvents(self: *Workbench) Error!void {
        var first_projection_error: ?Error = null;
        self.drainAgentEventPass(&first_projection_error);
        // Terminal publication happens after the synchronous AgentCore Run
        // returns, so its acquire observes all callback event enqueues. Drain
        // once more after that observation before exposing product terminal
        // state and the final assistant suffix; otherwise a queued callback
        // could lose the race to lifecycle publication or a snapshot.
        self.markTerminalRunsBeforeEventDrain();
        self.drainAgentEventPass(&first_projection_error);
        self.finalizeMarkedTerminalRunsAfterEventDrain();
        if (first_projection_error) |err| return err;
    }

    fn drainAgentEventPass(
        self: *Workbench,
        first_projection_error: *?Error,
    ) void {
        while (self.agent_runtime.takeEvent()) |value| {
            var envelope = value;
            defer envelope.deinit();
            self.applyEvent(&envelope) catch |err| {
                if (first_projection_error.* == null)
                    first_projection_error.* = err;
                self.recordEventProjectionFailure(
                    envelope.session_id,
                    envelope.run_id,
                );
                self.agent_runtime.requestRunTermination(
                    envelope.session_id,
                    envelope.run_id,
                    .{ .event_pump_failure = .consumer_rejected },
                ) catch {};
            };
        }
    }

    pub fn applyEvent(self: *Workbench, envelope: *const lifecycle.OwnedCoreEvent) Error!void {
        const task = self.findTaskByRouteId(envelope.session_id) orelse return error.UnknownTask;
        const outcome = task_model.applyEvent(
            task,
            envelope,
            self.taskEventProjection(),
        ) catch |err| return @errorCast(err);
        switch (outcome) {
            .unknown, .unchanged => {},
            .late_terminal => {
                // A late event cannot change a published product terminal, and
                // is not by itself proof of an AgentCore contract violation.
                self.late_terminal_event_count +|= 1;
                if (builtin.mode == .Debug) std.log.warn(
                    "workbench.late_terminal_event task_id={d} run_id={d} count={d}",
                    .{ task.durable.id, envelope.run_id, self.late_terminal_event_count },
                );
            },
            .applied => |application| {
                if (application.durable_boundary) self.commitTaskStateNoFail();
                self.bumpRevision();
            },
        }
    }

    /// Records canonical event loss independently of Agent execution state.
    /// A termination request may arrive after Agent terminal publication, so
    /// it cannot be the only owner of this product failure fact.
    fn recordEventProjectionFailure(
        self: *Workbench,
        route_id: u64,
        run_id: u64,
    ) void {
        const task = self.findTaskByRouteId(route_id) orelse return;
        const run = findRun(task.durable.runs, run_id) orelse return;
        if (!task_model.recordEventProjectionFailure(run)) return;
        self.touchTask(task);
        self.commitTaskStateNoFail();
        self.bumpRevision();
    }

    /// Marks terminal Runs before Workbench performs one more complete Agent
    /// event-pump drain. The acquire in `terminalPayload` observes every
    /// callback enqueue that happened before Run completion.
    fn markTerminalRunsBeforeEventDrain(self: *Workbench) void {
        for (self.tasks) |*task_entry| {
            const task = &(task_entry.* orelse continue);
            _ = task_model.markTerminalRunsBeforeEventDrain(task);
        }
    }

    fn syncMcpHealthNoFail(self: *Workbench) bool {
        const mcp = if (self.mcp) |*value| value else return false;
        if (mcp.committed) return false;
        mcp.committed = true;
        return true;
    }

    pub fn inspectMcpDesiredConfiguration(
        self: *const Workbench,
    ) ?mcp_configuration.ManagementInspection {
        const mcp = if (self.mcp) |*value| value else return null;
        const management = if (mcp.management) |*value| value else return null;
        return management.inspect();
    }

    /// Host-only copy used to construct an isolated connection-test Runtime.
    /// The bytes never cross Bridge and contain no resolved credential values.
    pub fn writeMcpDesiredConfiguration(
        self: *const Workbench,
        expected_generation: u64,
        output: []u8,
    ) Error![]const u8 {
        const mcp = if (self.mcp) |*value| value else return error.McpManagementUnavailable;
        const management = if (mcp.management) |*value| value else return error.McpManagementUnavailable;
        const inspection = management.inspect();
        if (inspection.health != .ready or
            inspection.desired_generation != expected_generation)
            return error.McpManagementUnavailable;
        const registry = management.desiredRegistry() orelse
            return error.McpManagementUnavailable;
        return mcp_configuration.encode(
            output,
            registry,
            management.limits,
        ) catch return error.McpManagementUnavailable;
    }

    pub fn beginMcpConnectionTest(
        self: *Workbench,
        server_id: []const u8,
    ) Error!void {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        const mcp = if (self.mcp) |*value| value else return error.McpManagementUnavailable;
        if (mcp.configuration_apply_state == .applying)
            return error.CatalogLoading;
        if (mcp.connection_test) |test_state|
            if (test_state.state == .testing) return error.CatalogLoading;
        const management = if (mcp.management) |*value| value else return error.McpManagementUnavailable;
        const registry = management.desiredRegistry() orelse
            return error.McpManagementUnavailable;
        if (findMcpServer(registry.servers, server_id) == null)
            return error.McpManagementUnavailable;
        mcp.connection_test = McpConnectionTest.init(server_id) orelse
            return error.McpManagementUnavailable;
        self.bumpRevision();
    }

    pub fn beginMcpConfigurationApply(
        self: *Workbench,
        expected_generation: u64,
    ) Error!void {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        const mcp = if (self.mcp) |*value| value else return error.McpManagementUnavailable;
        if (mcp.configuration_apply_state == .applying or
            self.mcp_refresh_job != null or
            mcp.authorization_operation != null)
            return error.CatalogLoading;
        const management = if (mcp.management) |*value| value else return error.McpManagementUnavailable;
        const inspection = management.inspect();
        if (inspection.health != .ready or
            inspection.desired_generation != expected_generation)
            return error.McpManagementUnavailable;
        const registry = management.desiredRegistry() orelse
            return error.McpManagementUnavailable;
        if (registry.oauth_operation != null) return error.CatalogLoading;
        self.mcp_refresh_timer.cancelCurrent();
        mcp.configuration_apply_state = .applying;
        mcp_policy.blockAdmission(mcp, .refreshing);
        self.bumpRevision();
    }

    /// Installs the exact Runtime preparation and authority produced by one
    /// successful declarative AgentCore apply. Every pointer remains owned by
    /// the caller when the generation no longer matches.
    pub fn completeMcpConfigurationApply(
        self: *Workbench,
        expected_generation: u64,
        preparation: *mcp_configuration.Preparation,
        manifest: *mcp_configuration.RuntimeManifest,
        activation: ?*lifecycle.McpActivation,
        selection: ?*lifecycle.McpSelection,
        activation_failed: bool,
    ) bool {
        const mcp = if (self.mcp) |*value| value else return false;
        if (mcp.configuration_apply_state != .applying) return false;
        const management = if (mcp.management) |*value| value else return false;
        const inspection = management.inspect();
        if (inspection.health != .ready or
            inspection.desired_generation != expected_generation or
            preparation.generation() != expected_generation)
            return false;

        if (mcp.activation) |old| old.deinit();
        mcp.activation = activation;
        mcp.activation_failed = activation_failed;
        mcp.preparation.deinit();
        mcp.preparation = preparation.take();
        management.installRuntimeManifest(manifest);
        mcp.configuration_apply_state = .idle;
        // A successful apply already performs official activation/catalog
        // discovery, so it satisfies refresh requests accumulated while the
        // apply operation owned the Runtime.
        mcp.refresh_pending = false;
        mcp.refresh_pending_blocks_admission = false;
        if (activation_failed) {
            if (selection) |value| value.deinit();
            mcp_policy.blockAdmission(mcp, .activation_unavailable);
        } else {
            mcp_policy.replaceAdmission(mcp, .{ .ready = .{
                .selection = selection,
                .catalog_generation = if (activation) |value|
                    value.catalogGeneration()
                else
                    null,
            } });
        }
        mcp.connection_test = null;
        self.updateMcpRefreshDeadlineNoFail();
        self.rearmMcpRefreshTimerNoFail();
        self.bumpRevision();
        return true;
    }

    pub fn failMcpConfigurationApply(
        self: *Workbench,
        expected_generation: u64,
    ) void {
        const mcp = if (self.mcp) |*value| value else return;
        if (mcp.configuration_apply_state != .applying) return;
        const management = if (mcp.management) |*value| value else return;
        if (management.inspect().desired_generation != expected_generation)
            return;
        mcp.configuration_apply_state = .failed;
        mcp_policy.blockAdmissionForCurrentState(mcp);
        self.rearmMcpRefreshTimerNoFail();
        self.bumpRevision();
    }

    pub fn completeMcpConnectionTest(
        self: *Workbench,
        server_id: []const u8,
        outcome: McpConnectionTestOutcome,
        tool_count: u32,
        issue_count: u32,
    ) void {
        const mcp = if (self.mcp) |*value| value else return;
        const test_state = if (mcp.connection_test) |*value| value else return;
        if (test_state.state != .testing or
            !std.mem.eql(u8, test_state.serverId(), server_id)) return;
        test_state.state = switch (outcome) {
            .connected => .connected,
            .failed => .failed,
        };
        test_state.tool_count = tool_count;
        test_state.issue_count = issue_count;
        self.bumpRevision();
    }

    pub fn mcpAuthorizationOperation(
        self: *const Workbench,
    ) ?McpAuthorizationOperationView {
        return mcp_policy.authorizationOperation(
            if (self.mcp) |*mcp| mcp else null,
        );
    }

    pub fn mcpServerOperationBusy(
        self: *const Workbench,
        server_id: []const u8,
    ) bool {
        const mcp = if (self.mcp) |*value| value else return false;
        return mcp_policy.serverOperationBusy(mcp, server_id);
    }

    pub fn requireMcpOauthReauthorization(
        self: *Workbench,
        failure: McpRuntimeAuthorizationFailure,
    ) Error!McpRuntimeAuthorizationFailureOutcome {
        if (self.shutting_down) return .rejected;
        const mcp = if (self.mcp) |*value| value else return .rejected;
        if (self.mcp_refresh_job != null) return .rejected;
        if (mcp.authorization_operation) |operation|
            if (std.mem.eql(u8, operation.server_id, failure.server_id))
                return .rejected;
        const management = if (mcp.management) |*value| value else return .rejected;
        if (!failure.challenge_scopes_complete)
            return error.McpOauthScopeCapacity;
        if (!mcp_configuration.validOauthScopeSet(
            failure.challenge_scopes,
            management.limits,
        )) return error.McpOauthScopeCapacity;
        if (management.inspect().health != .ready) return .rejected;
        const registry = management.desiredRegistry() orelse return .rejected;
        if (registry.oauth_operation) |operation|
            if (std.mem.eql(u8, operation.server_id, failure.server_id))
                return .rejected;
        const server = findMcpServer(registry.servers, failure.server_id) orelse
            return .stale;
        const oauth = server.auth.oauth orelse return .stale;
        const consent = oauth.consent orelse return .stale;
        if (consent.epoch != failure.consent_epoch) return .stale;
        const scope_step_up = mcp_policy.scopeSetAddsRequirement(
            consent.scopes,
            failure.challenge_scopes,
        );
        if (std.mem.eql(u8, oauth.status, "reauth_required")) {
            var pending = if (failure.challenge_scopes.len != 0)
                try mcp_policy.preparePendingReauthorization(
                    self.allocator,
                    mcp,
                    server.id,
                    consent.epoch,
                    failure.challenge_scopes,
                    management.limits.max_oauth_scopes,
                )
            else
                null;
            if (pending) |*replacement| {
                mcp_policy.installPendingReauthorization(mcp, replacement);
                self.bumpRevision();
            }
            return .applied;
        }
        const grant = oauth.grant orelse return .stale;
        if (!std.mem.eql(u8, oauth.status, "ready") or
            grant.consent_epoch != consent.epoch or
            failure.token_revision > grant.token_revision or
            (!scope_step_up and failure.token_revision != grant.token_revision))
            return .stale;
        var pending = if (failure.challenge_scopes.len != 0)
            try mcp_policy.preparePendingReauthorization(
                self.allocator,
                mcp,
                server.id,
                consent.epoch,
                failure.challenge_scopes,
                management.limits.max_oauth_scopes,
            )
        else
            null;
        var pending_owned = pending != null;
        defer if (pending_owned) pending.?.deinit();
        var preparation = try management.prepareRequireOauthReauthorization(
            registry.generation,
            .{
                .server_id = server.id,
                .consent_epoch = consent.epoch,
                .token_revision = grant.token_revision,
            },
        );
        const result: McpRuntimeAuthorizationFailureOutcome = switch (try self.commitMcpMutation(mcp, &preparation)) {
            .saved, .saved_recovery_required => .applied,
            .indeterminate => .persistence_outcome_unknown,
            .rejected => .rejected,
            .unchanged, .stale_generation => unreachable,
        };
        if (result == .rejected)
            self.blockMcpAdmissionAfterRuntimeAuthFailure();
        if (result != .rejected) if (pending) |*replacement| {
            mcp_policy.installPendingReauthorization(mcp, replacement);
            pending_owned = false;
        };
        return result;
    }

    pub fn blockMcpAdmissionAfterRuntimeAuthFailure(self: *Workbench) void {
        const mcp = if (self.mcp) |*value| value else return;
        mcp.runtime_auth_failure_blocked = true;
        switch (mcp.admission) {
            .blocked => |reason| if (reason == .runtime_authorization_failure) return,
            .ready => {},
        }
        mcp_policy.blockAdmission(mcp, .runtime_authorization_failure);
        self.bumpRevision();
    }

    pub fn beginMcpAuthorization(
        self: *Workbench,
        expected_generation: u64,
        server_id: []const u8,
    ) Error!?McpAuthorizationStart {
        if (self.shutting_down) return null;
        const mcp = if (self.mcp) |*value| value else return null;
        if (self.mcp_refresh_job != null or
            mcp.authorization_operation != null or
            mcp.configuration_apply_state == .applying)
            return null;
        const management = if (mcp.management) |*value| value else return null;
        if (!mcp_policy.expectedGenerationMatches(management, expected_generation) or
            management.inspect().health != .ready)
            return null;
        const registry = management.desiredRegistry() orelse return null;
        if (registry.oauth_operation != null) return null;
        const server = findMcpServer(registry.servers, server_id) orelse return null;
        const oauth = server.auth.oauth orelse return null;
        if (server.connection_approval == null or
            mcp_configuration.serverProblem(server, management.limits) != null or
            !std.mem.eql(u8, server.transport.kind, "streamable_http") or
            !std.mem.eql(u8, server.auth.kind, "oauth") or
            !(std.mem.eql(u8, oauth.status, "client_registration_required") or
                std.mem.eql(u8, oauth.status, "consent_required") or
                std.mem.eql(u8, oauth.status, "awaiting_tokens") or
                std.mem.eql(u8, oauth.status, "reauth_required")))
            return null;
        if (oauth.registration.client_id != null) {
            const method = oauth.registration.token_endpoint_auth_method orelse return null;
            if (!std.mem.eql(u8, method, "none") and
                oauth.registration.client_secret_ref == null)
                return null;
        }

        var entropy: [16]u8 = undefined;
        std.Io.randomSecure(self.io, &entropy) catch return null;
        const hex = std.fmt.bytesToHex(entropy, .lower);
        var operation_storage: [25]u8 = undefined;
        const operation_id = std.fmt.bufPrint(
            &operation_storage,
            "mcp-auth-{s}",
            .{hex[0..16]},
        ) catch unreachable;

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const owned = arena.allocator();
        const owned_operation_id = try owned.dupe(u8, operation_id);
        const owned_server_id = try owned.dupe(u8, server.id);
        const owned_endpoint = try owned.dupe(u8, server.transport.url orelse return null);
        const owned_registration_kind = try owned.dupe(u8, oauth.registration.kind);
        const owned_client_id = if (oauth.registration.client_id) |client_id|
            try owned.dupe(u8, client_id)
        else
            null;
        const owned_auth_method = if (oauth.registration.token_endpoint_auth_method) |method|
            try owned.dupe(u8, method)
        else
            null;
        const consent_scopes = if (oauth.consent) |consent|
            consent.scopes
        else
            &.{};
        const pending_scopes = if (oauth.consent) |consent|
            mcp_policy.pendingReauthorizationScopes(mcp, server.id, consent.epoch)
        else
            &.{};
        const owned_additional_scopes = try ownMcpScopeUnion(
            owned,
            consent_scopes,
            pending_scopes,
            management.limits.max_oauth_scopes,
        );
        const result: McpAuthorizationStart = .{
            .arena = arena,
            .operation_id = owned_operation_id,
            .server_id = owned_server_id,
            .endpoint = owned_endpoint,
            .registration_kind = owned_registration_kind,
            .client_id = owned_client_id,
            .token_endpoint_auth_method = owned_auth_method,
            .additional_scopes = owned_additional_scopes,
        };
        const operation_server_id = try self.allocator.dupe(u8, server.id);
        errdefer self.allocator.free(operation_server_id);
        const operation_identity = try self.allocator.dupe(u8, operation_id);
        const operation: McpAuthorizationOperation = .{
            .phase = .discovering,
            .server_id = operation_server_id,
            .operation_id = operation_identity,
        };
        self.mcp_refresh_timer.cancelCurrent();
        mcp.authorization_operation = operation;
        self.bumpRevision();
        return result;
    }

    pub fn advanceMcpAuthorization(
        self: *Workbench,
        operation_id: []const u8,
        phase: McpAuthorizationPhase,
    ) bool {
        if (self.shutting_down) return false;
        const mcp = if (self.mcp) |*value| value else return false;
        const operation = if (mcp.authorization_operation) |*value| value else return false;
        if (!std.mem.eql(u8, operation.operation_id, operation_id) or
            !mcp_policy.validAuthorizationTransition(operation.phase, phase))
            return false;
        operation.phase = phase;
        self.bumpRevision();
        return true;
    }

    pub fn finishMcpAuthorization(
        self: *Workbench,
        operation_id: []const u8,
    ) bool {
        const mcp = if (self.mcp) |*value| value else return false;
        const operation = if (mcp.authorization_operation) |*value| value else return false;
        if (!std.mem.eql(u8, operation.operation_id, operation_id)) return false;
        operation.deinit(self.allocator);
        mcp.authorization_operation = null;
        self.rearmMcpRefreshTimerNoFail();
        self.bumpRevision();
        return true;
    }

    /// Writes the exact public configuration covered by connection approval.
    /// This is a Host-only confirmation surface: it may include the complete
    /// endpoint or command, and therefore must never be used for a snapshot or
    /// Bridge response.
    pub fn writeMcpConnectionApprovalDetails(
        self: *const Workbench,
        expected_generation: u64,
        server_id: []const u8,
        output: []u8,
    ) ![]const u8 {
        const mcp = if (self.mcp) |*value| value else return error.McpManagementUnavailable;
        if (self.mcp_refresh_job != null or mcp_policy.serverMutationBusy(mcp, server_id))
            return error.McpManagementUnavailable;
        const management = if (mcp.management) |*value| value else return error.McpManagementUnavailable;
        if (management.inspect().health != .ready or
            !mcp_policy.expectedGenerationMatches(management, expected_generation))
            return error.McpManagementUnavailable;
        const registry = management.desiredRegistry() orelse return error.McpManagementUnavailable;
        const server = findMcpServer(registry.servers, server_id) orelse
            return error.McpManagementUnavailable;
        if (mcp_configuration.serverProblem(server, management.limits)) |problem|
            if (problem != .invalid_connection_approval)
                return error.McpManagementUnavailable;
        if (registry.oauth_operation) |operation|
            if (std.mem.eql(u8, operation.server_id, server_id))
                return error.McpManagementUnavailable;
        var writer = std.Io.Writer.fixed(output);
        try writeQuotedField(&writer, "Name", server.display_name);
        try writeQuotedField(&writer, "Protocol policy", server.negotiation);
        try writer.print("Timeout: {d} ms\n", .{server.timeout_ms});
        try writeQuotedField(&writer, "Authentication", server.auth.kind);
        if (!std.mem.eql(u8, server.transport.kind, "streamable_http")) {
            try writer.writeAll("Transport: STDIO\n");
            try writeQuotedField(&writer, "Executable", server.transport.command.?);
            try writer.writeAll("Arguments:\n");
            for (server.transport.arguments) |argument|
                try writeQuotedListItem(&writer, argument.literal.?);
            try writeQuotedField(
                &writer,
                "Working directory",
                server.transport.cwd orelse "(none)",
            );
            try writer.writeAll("Environment names:\n");
            for (server.transport.environment) |slot|
                try writeQuotedListItem(&writer, slot.name);
        } else {
            try writer.writeAll("Transport: Streamable HTTP\n");
            try writeQuotedField(&writer, "Endpoint", server.transport.url.?);
            try writer.writeAll("Header names:\n");
            for (server.transport.headers) |slot|
                try writeQuotedListItem(&writer, slot.name);
            if (server.auth.oauth) |oauth| {
                try writeQuotedField(
                    &writer,
                    "OAuth registration",
                    oauth.registration.kind,
                );
                if (oauth.registration.client_id) |client_id|
                    try writeQuotedField(&writer, "OAuth client ID", client_id);
            }
        }
        return writer.buffered();
    }

    /// Validates a Host-only secure capture target against the canonical
    /// desired registry before any secret-entry surface is shown. The prompt
    /// contains only escaped canonical values; Renderer-provided names never
    /// become trusted dialog text.
    pub fn writeMcpSecretCapturePrompt(
        self: *const Workbench,
        expected_generation: u64,
        server_id: []const u8,
        target: McpSecretCaptureTarget,
        output: []u8,
    ) ![]const u8 {
        const mcp = if (self.mcp) |*value| value else return error.McpManagementUnavailable;
        if (self.mcp_refresh_job != null or mcp_policy.serverMutationBusy(mcp, server_id))
            return error.McpManagementUnavailable;
        const management = if (mcp.management) |*value| value else return error.McpManagementUnavailable;
        if (management.inspect().health != .ready or
            !mcp_policy.expectedGenerationMatches(management, expected_generation))
            return error.McpManagementUnavailable;
        const registry = management.desiredRegistry() orelse return error.McpManagementUnavailable;
        const server = findMcpServer(registry.servers, server_id) orelse
            return error.McpManagementUnavailable;
        if (server.connection_approval == null or
            mcp_configuration.serverProblem(server, management.limits) != null)
            return error.McpManagementUnavailable;
        var writer = std.Io.Writer.fixed(output);
        try writeQuotedField(&writer, "MCP server", server.display_name);
        switch (target) {
            .stdio_environment => |requested_name| {
                if (!std.mem.eql(u8, server.auth.kind, "static") or
                    !std.mem.eql(u8, server.transport.kind, "stdio"))
                    return error.McpManagementUnavailable;
                for (server.transport.environment) |slot| {
                    if (!std.ascii.eqlIgnoreCase(slot.name, requested_name)) continue;
                    try writeQuotedField(&writer, "Environment variable", slot.name);
                    return writer.buffered();
                }
                return error.McpManagementUnavailable;
            },
            .http_header => |requested_name| {
                if (!std.mem.eql(u8, server.auth.kind, "static") or
                    !std.mem.eql(u8, server.transport.kind, "streamable_http"))
                    return error.McpManagementUnavailable;
                for (server.transport.headers) |slot| {
                    if (!std.ascii.eqlIgnoreCase(slot.name, requested_name)) continue;
                    try writeQuotedField(&writer, "HTTP header", slot.name);
                    return writer.buffered();
                }
                return error.McpManagementUnavailable;
            },
            .oauth_client_secret => {
                if (registry.oauth_operation != null) return error.McpManagementUnavailable;
                const oauth = server.auth.oauth orelse return error.McpManagementUnavailable;
                const method = oauth.registration.token_endpoint_auth_method orelse
                    return error.McpManagementUnavailable;
                if (!std.mem.eql(u8, oauth.registration.kind, "pre_registered") or
                    std.mem.eql(u8, method, "none"))
                    return error.McpManagementUnavailable;
                try writeQuotedField(
                    &writer,
                    "OAuth client ID",
                    oauth.registration.client_id orelse return error.McpManagementUnavailable,
                );
                return writer.buffered();
            },
        }
    }

    /// Binds metadata-validated consent to the current approved server and
    /// returns the exact client identity used to construct the authorization
    /// URL. Dynamic registration already committed these facts; a
    /// pre-registered client commits them here as one ordinary mutation.
    pub fn authorizeMcpOauth(
        self: *Workbench,
        plan: McpOauthAuthorizationPlan,
    ) Error!McpOauthAuthorizationOutcome {
        if (self.shutting_down or plan.attempt_id == 0) return .rejected;
        const mcp = if (self.mcp) |*value| value else return .rejected;
        if (self.mcp_refresh_job != null or mcp.configuration_apply_state == .applying)
            return .rejected;
        if (!mcp_policy.authorizationAt(
            mcp,
            plan.server_id,
            &.{ .awaiting_consent, .registering },
        )) return .rejected;
        const management = if (mcp.management) |*value| value else return .rejected;
        if (management.inspect().health != .ready) return .rejected;
        const before = management.desiredRegistry() orelse return .rejected;
        if (before.oauth_operation != null) return .rejected;
        const before_server = findMcpServer(before.servers, plan.server_id) orelse
            return .rejected;
        const before_oauth = before_server.auth.oauth orelse return .rejected;

        const consent_already_bound = if (before_oauth.consent) |consent|
            std.mem.eql(u8, before_oauth.status, "awaiting_tokens") and
                std.mem.eql(u8, consent.issuer, plan.issuer) and
                std.mem.eql(u8, consent.resource, plan.resource) and
                std.mem.eql(u8, consent.redirect_uri, plan.redirect_uri) and
                textSetsEqual(consent.scopes, plan.scopes)
        else
            false;
        if (!consent_already_bound) {
            var preparation = try management.prepareOauthConsent(
                before.generation,
                .{
                    .server_id = plan.server_id,
                    .resource = plan.resource,
                    .issuer = plan.issuer,
                    .scopes = plan.scopes,
                    .redirect_uri = plan.redirect_uri,
                },
            );
            const outcome = try self.commitMcpMutation(mcp, &preparation);
            switch (outcome) {
                .saved, .saved_recovery_required => {},
                .indeterminate => return .persistence_outcome_unknown,
                .unchanged, .stale_generation, .rejected => return .rejected,
            }
        }

        const current = management.desiredRegistry() orelse return .rejected;
        const server = findMcpServer(current.servers, plan.server_id) orelse
            return .rejected;
        const oauth = server.auth.oauth orelse return .rejected;
        const consent = oauth.consent orelse return .rejected;
        const client_id = oauth.registration.client_id orelse return .rejected;
        if (!std.mem.eql(u8, oauth.status, "awaiting_tokens") or
            !std.mem.eql(u8, consent.issuer, plan.issuer) or
            !std.mem.eql(u8, consent.resource, plan.resource) or
            !std.mem.eql(u8, consent.redirect_uri, plan.redirect_uri) or
            !textSetsEqual(consent.scopes, plan.scopes))
            return .rejected;
        return .{ .ready = .{
            .attempt_id = plan.attempt_id,
            .server_id = server.id,
            .issuer = consent.issuer,
            .resource = consent.resource,
            .scopes = consent.scopes,
            .redirect_uri = consent.redirect_uri,
            .client_id = client_id,
        } };
    }

    pub fn beginMcpOauthDynamicRegistration(
        self: *Workbench,
        consent: mcp_configuration.OauthConsentInput,
    ) Error!McpOauthOperationBeginOutcome {
        if (self.shutting_down) return .rejected;
        const mcp = if (self.mcp) |*value| value else return .rejected;
        if (self.mcp_refresh_job != null) return .rejected;
        if (!mcp_policy.authorizationAt(
            mcp,
            consent.server_id,
            &.{.awaiting_consent},
        )) return .rejected;
        const management = if (mcp.management) |*value| value else return .rejected;
        const desired = management.desiredRegistry() orelse return .rejected;
        var preparation = switch (try management.prepareBeginDynamicRegistration(
            desired.generation,
            .{ .consent = consent },
        )) {
            .rejected => return .rejected,
            .prepared => |prepared| prepared,
        };
        return self.commitMcpOauthOperationBegin(mcp, &preparation);
    }

    pub fn completeMcpOauthDynamicRegistration(
        self: *Workbench,
        input: mcp_configuration.CompleteDynamicRegistrationInput,
    ) Error!mcp_configuration.ManagementOutcome {
        if (self.shutting_down) {
            if (input.client_secret) |secret| std.crypto.secureZero(u8, secret);
            return .rejected;
        }
        const mcp = if (self.mcp) |*value| value else {
            if (input.client_secret) |secret| std.crypto.secureZero(u8, secret);
            return .rejected;
        };
        if (self.mcp_refresh_job != null) {
            if (input.client_secret) |secret| std.crypto.secureZero(u8, secret);
            return .rejected;
        }
        if (!mcp_policy.authorizationAt(mcp, input.server_id, &.{.registering})) {
            if (input.client_secret) |secret| std.crypto.secureZero(u8, secret);
            return .rejected;
        }
        const management = if (mcp.management) |*value| value else {
            if (input.client_secret) |secret| std.crypto.secureZero(u8, secret);
            return .rejected;
        };
        var preparation = try management.prepareCompleteDynamicRegistration(input);
        const outcome = try self.commitMcpMutation(mcp, &preparation);
        switch (outcome) {
            .saved, .saved_recovery_required => self.rearmMcpRefreshTimerNoFail(),
            else => {},
        }
        return outcome;
    }

    pub fn beginMcpOauthCodeExchange(
        self: *Workbench,
        server_id: []const u8,
    ) Error!McpOauthCodeExchangeBeginOutcome {
        if (self.shutting_down) return .rejected;
        const mcp = if (self.mcp) |*value| value else return .rejected;
        if (self.mcp_refresh_job != null or mcp.configuration_apply_state == .applying)
            return .rejected;
        if (!mcp_policy.authorizationAt(mcp, server_id, &.{.awaiting_browser}))
            return .rejected;
        const management = if (mcp.management) |*value| value else return .rejected;
        const desired = management.desiredRegistry() orelse return .rejected;
        var preparation = switch (try management.prepareBeginCodeExchange(
            desired.generation,
            .{ .server_id = server_id },
        )) {
            .rejected => return .rejected,
            .prepared => |prepared| prepared,
        };
        const outcome = try self.commitMcpOauthOperationBegin(mcp, &preparation);
        const handle = switch (outcome) {
            .started => |value| value,
            .rejected => return .rejected,
            .persistence_outcome_unknown => return .persistence_outcome_unknown,
        };
        const current = management.desiredRegistry() orelse return .rejected;
        const server = findMcpServer(current.servers, server_id) orelse return .rejected;
        const oauth = server.auth.oauth orelse return .rejected;
        const consent = oauth.consent orelse return .rejected;
        return .{ .started = .{
            .operation = handle,
            .issuer = consent.issuer,
            .client_id = oauth.registration.client_id orelse return .rejected,
            .token_endpoint_auth_method = oauth.registration.token_endpoint_auth_method orelse
                return .rejected,
            .client_secret_ref = oauth.registration.client_secret_ref,
            .resource = consent.resource,
            .redirect_uri = consent.redirect_uri,
        } };
    }

    pub fn completeMcpOauthCodeExchange(
        self: *Workbench,
        input: mcp_configuration.CompleteCodeExchangeInput,
    ) Error!mcp_configuration.ManagementOutcome {
        if (self.shutting_down) {
            std.crypto.secureZero(u8, input.access_token);
            if (input.refresh_token) |secret| std.crypto.secureZero(u8, secret);
            return .rejected;
        }
        const mcp = if (self.mcp) |*value| value else {
            std.crypto.secureZero(u8, input.access_token);
            if (input.refresh_token) |secret| std.crypto.secureZero(u8, secret);
            return .rejected;
        };
        if (self.mcp_refresh_job != null) {
            std.crypto.secureZero(u8, input.access_token);
            if (input.refresh_token) |secret| std.crypto.secureZero(u8, secret);
            return .rejected;
        }
        if (!mcp_policy.authorizationAt(mcp, input.server_id, &.{.exchanging})) {
            std.crypto.secureZero(u8, input.access_token);
            if (input.refresh_token) |secret| std.crypto.secureZero(u8, secret);
            return .rejected;
        }
        const management = if (mcp.management) |*value| value else {
            std.crypto.secureZero(u8, input.access_token);
            if (input.refresh_token) |secret| std.crypto.secureZero(u8, secret);
            return .rejected;
        };
        var preparation = try management.prepareCompleteCodeExchange(input);
        const outcome = try self.commitMcpMutation(mcp, &preparation);
        switch (outcome) {
            .saved, .saved_recovery_required => self.rearmMcpRefreshTimerNoFail(),
            else => {},
        }
        return outcome;
    }

    fn commitMcpOauthOperationBegin(
        self: *Workbench,
        mcp: *McpProductState,
        preparation: *mcp_configuration.PreparedOauthOperationState,
    ) Error!McpOauthOperationBeginOutcome {
        defer preparation.deinit();
        var reduced = try self.mcpAdmissionForTarget(mcp, preparation.target());
        var reduced_owned = true;
        defer if (reduced_owned) reduced.deinit();
        if (reduced != .ready) return .rejected;
        const management = &mcp.management.?;
        const outcome = try management.commitPreparedOauthOperationState(preparation);
        switch (outcome) {
            .saved => {
                self.mcp_refresh_timer.cancelCurrent();
                mcp_policy.installCommittedDesiredState(mcp, management, reduced);
                reduced_owned = false;
                self.bumpRevision();
                const registry = management.desiredRegistry() orelse return .rejected;
                const operation = registry.oauth_operation orelse return .rejected;
                return .{ .started = .{
                    .id = operation.id,
                    .server_id = operation.server_id,
                } };
            },
            .indeterminate => {
                self.mcp_refresh_timer.cancelCurrent();
                mcp_policy.blockAdmission(mcp, .persistence_outcome_unknown);
                self.bumpRevision();
                return .persistence_outcome_unknown;
            },
            .rejected => return .rejected,
            .unchanged, .stale_generation, .saved_recovery_required => unreachable,
        }
    }

    /// Borrowed until the next Workbench mutation. Application stores only
    /// the due time in its one-shot timer and asks again when it fires.
    pub fn nextMcpOauthExpiry(self: *const Workbench) ?McpOauthExpiry {
        if (self.shutting_down) return null;
        const mcp = if (self.mcp) |*value| value else return null;
        return mcp_policy.nextOauthExpiry(mcp);
    }

    /// Begins the global OAuth refresh operation as one Workbench short
    /// transaction. Every fallible allocation, including the reduced
    /// Admission selection and the detached network binding, completes before
    /// the marker is persisted. A successful marker commit is followed only
    /// by the no-fail authority swap.
    pub fn beginMcpOauthRefresh(
        self: *Workbench,
        server_id: []const u8,
    ) Error!McpOauthRefreshBeginOutcome {
        if (self.shutting_down) return .rejected;
        self.syncLifecycle();
        const mcp = if (self.mcp) |*value| value else return .rejected;
        if (!mcp.committed or self.mcp_refresh_job != null or
            mcp.configuration_apply_state == .applying or
            mcp.authorization_operation != null)
            return .rejected;
        const management = if (mcp.management) |*value| value else return .rejected;
        const inspection = management.inspect();
        if (inspection.health != .ready or inspection.runtime_alignment != .current)
            return .rejected;
        if (mcp.activation_failed) return .rejected;
        const activation = mcp.activation orelse return .rejected;
        var runtime_loaded = false;
        for (activation.serverHealth()) |server| {
            if (!std.mem.eql(u8, server.id, server_id)) continue;
            runtime_loaded = true;
            break;
        }
        if (!runtime_loaded) return .rejected;
        const desired = management.desiredRegistry() orelse return .rejected;
        var preparation = switch (try management.prepareBeginRefresh(
            desired.generation,
            .{ .server_id = server_id },
        )) {
            .rejected => return .rejected,
            .prepared => |prepared| prepared,
        };
        defer preparation.deinit();
        var reduced = try self.mcpAdmissionForTarget(mcp, preparation.target());
        var reduced_owned = true;
        defer if (reduced_owned) reduced.deinit();
        if (reduced != .ready) return .rejected;
        var binding = try mcp_policy.buildOauthRefreshBinding(
            self.allocator,
            preparation.target(),
        );
        var binding_owned = true;
        defer if (binding_owned) binding.deinit();
        const outcome = try management.commitPreparedOauthOperationState(&preparation);
        switch (outcome) {
            .saved => {
                self.mcp_refresh_timer.cancelCurrent();
                mcp_policy.installCommittedDesiredState(mcp, management, reduced);
                reduced_owned = false;
                binding_owned = false;
                self.bumpRevision();
                return .{ .started = binding };
            },
            .indeterminate => {
                self.mcp_refresh_timer.cancelCurrent();
                mcp_policy.blockAdmission(mcp, .persistence_outcome_unknown);
                self.bumpRevision();
                return .persistence_outcome_unknown;
            },
            .rejected => return .rejected,
            .unchanged, .stale_generation, .saved_recovery_required => unreachable,
        }
    }

    pub fn completeMcpOauthRefresh(
        self: *Workbench,
        input: mcp_configuration.CompleteRefreshInput,
        runtime_commit: McpOauthRuntimeCommit,
    ) Error!mcp_configuration.ManagementOutcome {
        if (self.shutting_down) {
            std.crypto.secureZero(u8, input.access_token);
            if (input.refresh_token) |secret| std.crypto.secureZero(u8, secret);
            return .rejected;
        }
        const mcp = if (self.mcp) |*value| value else {
            std.crypto.secureZero(u8, input.access_token);
            if (input.refresh_token) |secret| std.crypto.secureZero(u8, secret);
            return .rejected;
        };
        if (self.mcp_refresh_job != null) {
            std.crypto.secureZero(u8, input.access_token);
            if (input.refresh_token) |secret| std.crypto.secureZero(u8, secret);
            return .rejected;
        }
        const management = if (mcp.management) |*value| value else {
            std.crypto.secureZero(u8, input.access_token);
            if (input.refresh_token) |secret| std.crypto.secureZero(u8, secret);
            return .rejected;
        };
        var preparation = try management.prepareCompleteRefresh(input);
        switch (preparation) {
            .unchanged, .rejected => return .rejected,
            .prepared => |*mutation| {
                defer mutation.deinit();
                var candidate = try self.mcpAdmissionForTarget(mcp, mutation.target());
                var candidate_owned = true;
                defer if (candidate_owned) candidate.deinit();
                if (candidate != .ready) return .rejected;
                const outcome = try management.commitPreparedMutation(mutation);
                const reported_outcome = if (outcome == .saved_recovery_required and
                    management.inspect().health == .outcome_unknown)
                    mcp_configuration.ManagementOutcome.indeterminate
                else
                    outcome;
                switch (reported_outcome) {
                    .saved, .saved_recovery_required => {
                        runtime_commit.commit();
                        mcp_policy.installCommittedDesiredState(mcp, management, candidate);
                        candidate_owned = false;
                        self.rearmMcpRefreshTimerNoFail();
                        self.bumpRevision();
                    },
                    .indeterminate => {
                        mcp_policy.blockAdmission(mcp, .persistence_outcome_unknown);
                        self.bumpRevision();
                    },
                    .rejected => if (management.inspect().health != .ready) {
                        mcp_policy.blockAdmissionForCurrentState(mcp);
                        self.bumpRevision();
                    },
                    .unchanged, .stale_generation => unreachable,
                }
                return reported_outcome;
            },
        }
    }

    pub fn clearMcpOauthOperation(
        self: *Workbench,
        operation_id: []const u8,
    ) Error!mcp_configuration.ManagementOutcome {
        if (self.shutting_down) return .rejected;
        const mcp = if (self.mcp) |*value| value else return .rejected;
        if (self.mcp_refresh_job != null) return .rejected;
        const management = if (mcp.management) |*value| value else return .rejected;
        var preparation = switch (try management.prepareClearOauthOperation(operation_id)) {
            .rejected => return .rejected,
            .prepared => |prepared| prepared,
        };
        defer preparation.deinit();
        var candidate = try self.mcpAdmissionForTarget(mcp, preparation.target());
        var candidate_owned = true;
        defer if (candidate_owned) candidate.deinit();
        const outcome = try management.commitPreparedOauthOperationState(&preparation);
        switch (outcome) {
            .saved => {
                mcp_policy.installCommittedDesiredState(mcp, management, candidate);
                candidate_owned = false;
                self.rearmMcpRefreshTimerNoFail();
                self.bumpRevision();
            },
            .indeterminate => {
                mcp_policy.blockAdmission(mcp, .persistence_outcome_unknown);
                self.bumpRevision();
            },
            .rejected => {},
            .unchanged, .stale_generation, .saved_recovery_required => unreachable,
        }
        return outcome;
    }

    pub fn recoverMcpOauthOperation(
        self: *Workbench,
        operation_id: []const u8,
    ) Error!mcp_configuration.ManagementOutcome {
        if (self.shutting_down) return .rejected;
        const mcp = if (self.mcp) |*value| value else return .rejected;
        if (self.mcp_refresh_job != null) return .rejected;
        const management = if (mcp.management) |*value| value else return .rejected;
        var preparation = try management.prepareOauthOperationRecovery(operation_id);
        const outcome = try self.commitMcpMutation(mcp, &preparation);
        switch (outcome) {
            .saved, .saved_recovery_required => self.rearmMcpRefreshTimerNoFail(),
            else => {},
        }
        return outcome;
    }

    pub fn createMcpHttpServer(
        self: *Workbench,
        expected_generation: u64,
        input: mcp_configuration.CreateHttpServerInput,
    ) Error!mcp_configuration.ManagementOutcome {
        if (self.shutting_down) return .rejected;
        const mcp = if (self.mcp) |*value| value else return .rejected;
        if (self.mcp_refresh_job != null) return .rejected;
        const management = if (mcp.management) |*value| value else return .rejected;
        if (!mcp_policy.expectedGenerationMatches(management, expected_generation))
            return .stale_generation;
        var preparation = try management.prepareCreateHttpServer(expected_generation, input);
        return try self.commitMcpMutation(mcp, &preparation);
    }

    pub fn createMcpOauthHttpServer(
        self: *Workbench,
        expected_generation: u64,
        input: mcp_configuration.CreateOauthHttpServerInput,
    ) Error!mcp_configuration.ManagementOutcome {
        if (self.shutting_down) return .rejected;
        const mcp = if (self.mcp) |*value| value else return .rejected;
        if (self.mcp_refresh_job != null) return .rejected;
        const management = if (mcp.management) |*value| value else return .rejected;
        if (!mcp_policy.expectedGenerationMatches(management, expected_generation))
            return .stale_generation;
        var preparation = try management.prepareCreateOauthHttpServer(
            expected_generation,
            input,
        );
        return try self.commitMcpMutation(mcp, &preparation);
    }

    pub fn createMcpStdioServer(
        self: *Workbench,
        expected_generation: u64,
        input: mcp_configuration.CreateStdioServerInput,
    ) Error!mcp_configuration.ManagementOutcome {
        if (self.shutting_down) return .rejected;
        const mcp = if (self.mcp) |*value| value else return .rejected;
        if (self.mcp_refresh_job != null) return .rejected;
        const management = if (mcp.management) |*value| value else return .rejected;
        if (!mcp_policy.expectedGenerationMatches(management, expected_generation))
            return .stale_generation;
        var preparation = try management.prepareCreateStdioServer(expected_generation, input);
        return try self.commitMcpMutation(mcp, &preparation);
    }

    pub fn updateMcpHttpConnection(
        self: *Workbench,
        expected_generation: u64,
        input: mcp_configuration.UpdateHttpConnectionInput,
    ) Error!mcp_configuration.ManagementOutcome {
        if (self.shutting_down) return .rejected;
        const mcp = if (self.mcp) |*value| value else return .rejected;
        if (self.mcp_refresh_job != null) return .rejected;
        if (mcp_policy.serverMutationBusy(mcp, input.server_id)) return .rejected;
        const management = if (mcp.management) |*value| value else return .rejected;
        if (!mcp_policy.expectedGenerationMatches(management, expected_generation))
            return .stale_generation;
        var preparation = try management.prepareUpdateHttpConnection(expected_generation, input);
        return try self.commitMcpMutation(mcp, &preparation);
    }

    pub fn updateMcpOauthHttpConnection(
        self: *Workbench,
        expected_generation: u64,
        input: mcp_configuration.UpdateOauthHttpConnectionInput,
    ) Error!mcp_configuration.ManagementOutcome {
        if (self.shutting_down) return .rejected;
        const mcp = if (self.mcp) |*value| value else return .rejected;
        if (self.mcp_refresh_job != null) return .rejected;
        if (mcp_policy.serverMutationBusy(mcp, input.server_id)) return .rejected;
        const management = if (mcp.management) |*value| value else return .rejected;
        if (!mcp_policy.expectedGenerationMatches(management, expected_generation))
            return .stale_generation;
        var preparation = try management.prepareUpdateOauthHttpConnection(
            expected_generation,
            input,
        );
        return try self.commitMcpMutation(mcp, &preparation);
    }

    pub fn updateMcpStdioConnection(
        self: *Workbench,
        expected_generation: u64,
        input: mcp_configuration.UpdateStdioConnectionInput,
    ) Error!mcp_configuration.ManagementOutcome {
        if (self.shutting_down) return .rejected;
        const mcp = if (self.mcp) |*value| value else return .rejected;
        if (self.mcp_refresh_job != null) return .rejected;
        if (mcp_policy.serverMutationBusy(mcp, input.server_id)) return .rejected;
        const management = if (mcp.management) |*value| value else return .rejected;
        if (!mcp_policy.expectedGenerationMatches(management, expected_generation))
            return .stale_generation;
        var preparation = try management.prepareUpdateStdioConnection(expected_generation, input);
        return try self.commitMcpMutation(mcp, &preparation);
    }

    /// Host-only secure capture boundary. Renderer/Bridge commands must not
    /// construct this input because it contains credential material.
    pub fn captureMcpStaticSecret(
        self: *Workbench,
        expected_generation: u64,
        input: mcp_configuration.CaptureStaticSecretInput,
    ) Error!mcp_configuration.ManagementOutcome {
        defer std.crypto.secureZero(u8, input.secret);
        if (self.shutting_down) return .rejected;
        const mcp = if (self.mcp) |*value| value else return .rejected;
        if (self.mcp_refresh_job != null) return .rejected;
        if (mcp_policy.serverMutationBusy(mcp, input.server_id)) return .rejected;
        const management = if (mcp.management) |*value| value else return .rejected;
        if (!mcp_policy.expectedGenerationMatches(management, expected_generation))
            return .stale_generation;
        var preparation = try management.prepareCaptureStaticSecret(expected_generation, input);
        return try self.commitMcpMutation(mcp, &preparation);
    }

    /// Host-only secure capture boundary for a pre-registered OAuth client.
    /// Like static capture, this consumes and zeroes `secret` on every path.
    pub fn captureMcpOauthClientSecret(
        self: *Workbench,
        expected_generation: u64,
        input: mcp_configuration.CaptureOauthClientSecretInput,
    ) Error!mcp_configuration.ManagementOutcome {
        defer std.crypto.secureZero(u8, input.secret);
        if (self.shutting_down) return .rejected;
        const mcp = if (self.mcp) |*value| value else return .rejected;
        if (self.mcp_refresh_job != null) return .rejected;
        if (mcp_policy.serverMutationBusy(mcp, input.server_id)) return .rejected;
        const management = if (mcp.management) |*value| value else return .rejected;
        if (!mcp_policy.expectedGenerationMatches(management, expected_generation))
            return .stale_generation;
        var preparation = try management.prepareCaptureOauthClientSecret(
            expected_generation,
            input,
        );
        return try self.commitMcpMutation(mcp, &preparation);
    }

    pub fn renameMcpServer(
        self: *Workbench,
        expected_generation: u64,
        input: mcp_configuration.RenameServerInput,
    ) Error!mcp_configuration.ManagementOutcome {
        if (self.shutting_down) return .rejected;
        const mcp = if (self.mcp) |*value| value else return .rejected;
        if (self.mcp_refresh_job != null) return .rejected;
        if (mcp_policy.serverMutationBusy(mcp, input.server_id)) return .rejected;
        const management = if (mcp.management) |*value| value else return .rejected;
        if (!mcp_policy.expectedGenerationMatches(management, expected_generation))
            return .stale_generation;
        var preparation = try management.prepareRenameServer(expected_generation, input);
        return try self.commitMcpMutation(mcp, &preparation);
    }

    pub fn approveMcpConnection(
        self: *Workbench,
        expected_generation: u64,
        input: mcp_configuration.ApproveConnectionInput,
    ) Error!mcp_configuration.ManagementOutcome {
        if (self.shutting_down) return .rejected;
        const mcp = if (self.mcp) |*value| value else return .rejected;
        if (self.mcp_refresh_job != null) return .rejected;
        if (mcp_policy.serverMutationBusy(mcp, input.server_id)) return .rejected;
        const management = if (mcp.management) |*value| value else return .rejected;
        if (!mcp_policy.expectedGenerationMatches(management, expected_generation))
            return .stale_generation;
        var preparation = try management.prepareApproveConnection(
            expected_generation,
            input,
        );
        return try self.commitMcpMutation(mcp, &preparation);
    }

    pub fn setMcpServerEnabled(
        self: *Workbench,
        expected_generation: u64,
        input: mcp_configuration.SetServerEnabledInput,
    ) Error!mcp_configuration.ManagementOutcome {
        if (self.shutting_down) return .rejected;
        const mcp = if (self.mcp) |*value| value else return .rejected;
        if (self.mcp_refresh_job != null) return .rejected;
        if (mcp_policy.serverMutationBusy(mcp, input.server_id)) return .rejected;
        const management = if (mcp.management) |*value| value else return .rejected;
        if (!mcp_policy.expectedGenerationMatches(management, expected_generation))
            return .stale_generation;
        var preparation = try management.prepareSetServerEnabled(expected_generation, input);
        return try self.commitMcpMutation(mcp, &preparation);
    }

    pub fn setMcpAllowedTools(
        self: *Workbench,
        expected_generation: u64,
        input: mcp_configuration.SetAllowedToolsInput,
    ) Error!mcp_configuration.ManagementOutcome {
        if (self.shutting_down) return .rejected;
        const mcp = if (self.mcp) |*value| value else return .rejected;
        if (self.mcp_refresh_job != null) return .rejected;
        if (mcp_policy.serverMutationBusy(mcp, input.server_id)) return .rejected;
        const management = if (mcp.management) |*value| value else return .rejected;
        if (!mcp_policy.expectedGenerationMatches(management, expected_generation))
            return .stale_generation;
        var preparation = try management.prepareSetAllowedTools(expected_generation, input);
        return try self.commitMcpMutation(mcp, &preparation);
    }

    pub fn removeMcpServer(
        self: *Workbench,
        expected_generation: u64,
        server_id: []const u8,
    ) Error!mcp_configuration.ManagementOutcome {
        if (self.shutting_down) return .rejected;
        const mcp = if (self.mcp) |*value| value else return .rejected;
        if (self.mcp_refresh_job != null) return .rejected;
        if (mcp_policy.serverMutationBusy(mcp, server_id)) return .rejected;
        const management = if (mcp.management) |*value| value else return .rejected;
        if (!mcp_policy.expectedGenerationMatches(management, expected_generation))
            return .stale_generation;
        var preparation = try management.prepareRemoveServer(expected_generation, server_id);
        return try self.commitMcpMutation(mcp, &preparation);
    }

    fn commitMcpMutation(
        self: *Workbench,
        mcp: *McpProductState,
        preparation: *mcp_configuration.MutationPreparation,
    ) Error!mcp_configuration.ManagementOutcome {
        if (mcp.configuration_apply_state == .applying) return .rejected;
        switch (preparation.*) {
            .unchanged => return .unchanged,
            .rejected => return .rejected,
            .prepared => |*mutation| {
                defer mutation.deinit();
                var candidate = try self.mcpAdmissionForTarget(mcp, mutation.target());
                var candidate_owned = true;
                defer if (candidate_owned) candidate.deinit();
                const management = &mcp.management.?;
                const outcome = try management.commitPreparedMutation(mutation);
                const reported_outcome = if (outcome == .saved_recovery_required and
                    management.inspect().health == .outcome_unknown)
                    mcp_configuration.ManagementOutcome.indeterminate
                else
                    outcome;
                var changed = false;
                switch (reported_outcome) {
                    .saved, .saved_recovery_required => {
                        mcp_policy.installCommittedDesiredState(mcp, management, candidate);
                        mcp.connection_test = null;
                        candidate_owned = false;
                        changed = true;
                    },
                    .indeterminate => {
                        mcp.connection_test = null;
                        mcp_policy.blockAdmission(mcp, .persistence_outcome_unknown);
                        changed = true;
                    },
                    .rejected => if (management.inspect().health != .ready) {
                        mcp_policy.blockAdmissionForCurrentState(mcp);
                        changed = true;
                    },
                    .unchanged, .stale_generation => unreachable,
                }
                if (changed) self.bumpRevision();
                return reported_outcome;
            },
        }
    }

    fn mcpAdmissionForTarget(
        self: *Workbench,
        mcp: *McpProductState,
        target: mcp_configuration.RegistryWire,
    ) Error!McpAdmissionAuthority {
        if (mcp.runtime_auth_failure_blocked)
            return .{ .blocked = .runtime_authorization_failure };
        const management = &mcp.management.?;
        return switch (management.runtimeAlignmentFor(target)) {
            .restart_required => .{ .blocked = .pending_restart },
            .unknown => .{ .blocked = .alignment_unknown },
            .current => current: {
                if (mcp.activation_failed)
                    break :current .{ .blocked = .activation_unavailable };
                const activation = mcp.activation orelse break :current .{ .ready = .{
                    .selection = null,
                    .catalog_generation = null,
                } };
                const health = activation.serverHealth();
                const allowlists = try self.allocator.alloc(
                    lifecycle.McpServerAllowlist,
                    health.len,
                );
                defer self.allocator.free(allowlists);
                for (health, allowlists) |server, *allowlist| {
                    const desired = findMcpServer(target.servers, server.id) orelse
                        return error.McpCatalogBindingMismatch;
                    allowlist.* = .{
                        .id = server.id,
                        .tools = mcp_policy.serverToolsForAdmission(target, desired),
                    };
                }
                break :current .{ .ready = .{
                    .selection = try self.agent_runtime.createMcpAdmissionSelection(
                        activation,
                        allowlists,
                    ),
                    .catalog_generation = activation.catalogGeneration(),
                } };
            },
        };
    }

    fn recoverExpiredMcpCatalogNoFail(self: *Workbench) void {
        if (self.shutting_down) return;
        _ = self.requestMcpCatalogRefresh(true) catch {
            if (self.mcp) |*mcp| {
                if (self.mcp_refresh_job == null and !mcp.refresh_pending)
                    mcp_policy.blockAdmissionForCurrentState(mcp);
                self.bumpRevision();
            }
        };
    }

    fn updateMcpRefreshDeadlineNoFail(self: *Workbench) void {
        const mcp = if (self.mcp) |*value| value else return;
        mcp.refresh_deadline_ms = null;
        const activation = mcp.activation orelse return;
        mcp.refresh_deadline_ms = mcpRefreshDeadlineMs(
            activation.catalogServers(),
            self.mcp_refresh_timer.now(),
        );
    }

    fn rearmMcpRefreshTimerNoFail(self: *Workbench) void {
        self.mcp_refresh_timer.cancelCurrent();
        if (self.shutting_down) return;
        const pending = if (self.mcp) |*mcp| mcp.refresh_pending else false;
        if (pending) {
            const started = self.startPendingMcpCatalogRefresh() catch return;
            if (started) return;
            if (self.mcp) |*mcp| if (mcp.refresh_pending) return;
        }
        if (!self.mcp_refresh_timer.enabled) return;
        const deadline_ms = deadline: {
            const mcp = if (self.mcp) |*value| value else return;
            if (!mcp.committed or
                self.mcp_refresh_job != null or
                mcp.configuration_apply_state == .applying or
                mcp.authorization_operation != null or
                mcp.runtime_auth_failure_blocked or
                mcp.activation_failed)
                return;
            const management = if (mcp.management) |*value| value else return;
            const inspection = management.inspect();
            if (inspection.health != .ready or inspection.runtime_alignment != .current)
                return;
            const desired = management.desiredRegistry() orelse return;
            if (desired.oauth_operation != null) return;
            break :deadline mcp.refresh_deadline_ms orelse return;
        };
        const now_ms = self.mcp_refresh_timer.now() orelse return;
        if (deadline_ms <= now_ms) {
            _ = self.requestMcpCatalogRefresh(true) catch {};
            return;
        }
        _ = self.mcp_refresh_timer.armAt(deadline_ms);
    }

    fn createRecoveryMcpAuthority(self: *Workbench) Error!RecoveryMcpAuthority {
        const mcp = if (self.mcp) |*value| value else return .{
            .selection = null,
            .catalog_generation = null,
        };
        if (!mcp.committed or self.mcp_refresh_job != null or
            mcp.refresh_pending_blocks_admission or
            mcp.authorization_operation != null or
            mcp.runtime_auth_failure_blocked)
            return error.RecoveryUnavailable;
        const ready = switch (mcp.admission) {
            .ready => |value| value,
            .blocked => return error.RecoveryUnavailable,
        };
        const activation = mcp.activation orelse {
            if (ready.catalog_generation != null) return error.RecoveryUnavailable;
            return .{ .selection = null, .catalog_generation = null };
        };
        if (ready.catalog_generation == null or
            ready.catalog_generation.? != activation.catalogGeneration())
            return error.RecoveryUnavailable;
        const registry = if (mcp.management) |*management|
            management.desiredRegistry() orelse return error.RecoveryUnavailable
        else if (mcp.preparation.registry) |registry|
            registry.value
        else
            return error.RecoveryUnavailable;
        const health = activation.serverHealth();
        const allowlists = try self.allocator.alloc(
            lifecycle.McpServerAllowlist,
            health.len,
        );
        defer self.allocator.free(allowlists);
        for (health, allowlists) |server, *allowlist| {
            const desired = findMcpServer(registry.servers, server.id) orelse
                return error.RecoveryUnavailable;
            allowlist.* = .{
                .id = server.id,
                .tools = mcp_policy.serverToolsForAdmission(registry, desired),
            };
        }
        return .{
            .selection = self.agent_runtime.createMcpAdmissionSelection(
                activation,
                allowlists,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.RecoveryUnavailable,
            },
            .catalog_generation = activation.catalogGeneration(),
        };
    }

    fn mcpViewContainsSensitive(context: *const anyopaque, value: []const u8) bool {
        const self: *const Workbench = @ptrCast(@alignCast(context));
        return self.containsKnownCredential(value);
    }

    fn writeMcpViewJson(
        context: *const anyopaque,
        writer: *std.Io.Writer,
        value: []const u8,
    ) mcp_view.Error!void {
        const self: *const Workbench = @ptrCast(@alignCast(context));
        self.projectedJsonValueWithKnownCredentials(writer, value) catch
            return error.SnapshotTooLarge;
    }

    fn writeMcpProjection(
        self: *Workbench,
        writer: *std.Io.Writer,
    ) Error!void {
        mcp_view.writeProjection(writer, .{
            .state = if (self.mcp) |*mcp| mcp else null,
            .refresh_job_active = self.mcp_refresh_job != null,
            .text = .{
                .context = self,
                .contains_sensitive_fn = mcpViewContainsSensitive,
                .write_json_fn = writeMcpViewJson,
            },
        }) catch return error.SnapshotTooLarge;
    }

    /// Commits the final assistant suffix only after Workbench has drained the
    /// Agent event pump following `markTerminalRunsBeforeEventDrain`.
    /// Any later event for the Run is rejected by `applyEvent`.
    pub fn finalizeMarkedTerminalRunsAfterEventDrain(self: *Workbench) void {
        var changed = false;
        for (self.tasks) |*task_entry| {
            const task = &(task_entry.* orelse continue);
            if (!task_model.finalizeMarkedTerminalRunsAfterEventDrain(task)) continue;
            changed = true;
            self.touchTask(task);
        }
        if (changed) {
            self.commitTaskStateNoFail();
            self.bumpRevision();
        }
    }

    pub fn writeSnapshot(self: *Workbench, output: []u8) Error![]const u8 {
        self.syncLifecycle();
        var writer = std.Io.Writer.fixed(output);
        const schedule_persistence_ready =
            self.schedule_persistence_health == .ready;
        const task_persistence_ready = self.task_persistence_health.operational();
        const background_schedule_wake = self.schedule_background_available;
        const mcp_management = if (self.mcp) |*mcp|
            mcp.committed and mcp.management != null
        else
            false;
        const mcp_host_capabilities = if (self.mcp) |*mcp|
            if (mcp_management) mcp.host_capabilities else McpHostCapabilities{}
        else
            McpHostCapabilities{};
        writer.print("{{\"revision\":\"{d}\",\"capabilities\":{{\"taskHistoryPersistence\":{},\"taskHistoryPersistenceHealth\":\"{s}\",\"conversationRecovery\":true,\"executionRebind\":false,\"structuredPlan\":false,\"typedOutputs\":false,\"typedFileChanges\":false,\"persistentWorkspacePermissions\":false,\"automaticWorkspaces\":{},\"scheduledTasks\":{},\"scheduledTaskPersistence\":{},\"scheduledTaskPersistenceHealth\":\"{s}\",\"backgroundScheduleWake\":{},\"localSkillManagement\":{},\"skillManagementHealth\":\"{s}\",\"modelConnectionManagement\":{},\"modelConnectionSecretCapture\":{},\"modelConnectionTest\":{},\"mcpManagement\":{},\"mcpConnectionApproval\":{},\"mcpSecretCapture\":{},\"mcpOAuth\":{}}},\"account\":", .{
            self.revision,
            task_persistence_ready,
            @tagName(self.task_persistence_health),
            self.automatic_workspaces != null,
            self.schedule_timer.enabled and schedule_persistence_ready and
                background_schedule_wake,
            schedule_persistence_ready,
            @tagName(self.schedule_persistence_health),
            background_schedule_wake,
            self.skill_management_health == .ready,
            @tagName(self.skill_management_health),
            self.model_connection_capabilities.management,
            self.model_connection_capabilities.secret_capture,
            self.model_connection_capabilities.connection_test,
            mcp_management,
            mcp_host_capabilities.connection_approval,
            mcp_host_capabilities.secret_capture,
            mcp_host_capabilities.oauth,
        }) catch
            return error.SnapshotTooLarge;
        try self.writeAccount(&writer);
        writer.writeAll(",\"skillCatalog\":") catch
            return error.SnapshotTooLarge;
        try self.writeCatalogProjection(
            &writer,
            catalogProjection(
                self.skill_catalog_slot.availability(self.skill_catalog_job != null),
                self.skill_catalog_slot.snapshotConst(),
            ),
        );
        writer.writeAll(",\"skillManagement\":") catch
            return error.SnapshotTooLarge;
        try self.writeSkillManagement(&writer);
        writer.writeAll(",\"mcp\":") catch return error.SnapshotTooLarge;
        try self.writeMcpProjection(&writer);
        writer.writeAll(",\"workspaces\":[") catch return error.SnapshotTooLarge;
        var workspace_count: usize = 0;
        for (self.workspaces) |*entry| {
            const workspace = &(entry.* orelse continue);
            if (workspace.kind == .manual and !workspace.visible) continue;
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
        writer.print(
            ",\"execution\":{{\"generation\":\"{d}\",\"provider\":\"{s}\",\"model\":",
            .{ item.execution_generation, @tagName(item.execution_provider) },
        ) catch return error.SnapshotTooLarge;
        try self.projectedJsonValueWithKnownCredentials(
            writer,
            item.execution_model,
        );
        writer.writeAll("},\"input\":{\"kind\":\"text\",\"text\":") catch
            return error.SnapshotTooLarge;
        try self.projectedJsonValueWithKnownCredentials(writer, item.input.value);
        writer.print(",\"redacted\":{}}}", .{item.input.redacted}) catch
            return error.SnapshotTooLarge;
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
            "{{\"state\":\"{s}\",\"catalogState\":\"{s}\",\"executionSource\":\"{s}\",\"canCancel\":{},\"accountId\":",
            .{
                @tagName(view.state),
                @tagName(view.catalog_state),
                @tagName(view.execution_source),
                view.can_cancel,
            },
        ) catch return error.SnapshotTooLarge;
        try self.projectedJsonValue(writer, view.account_id);
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
        writer.writeAll(",\"modelConnections\":[") catch
            return error.SnapshotTooLarge;
        for (view.model_connections, 0..) |connection, index| {
            if (index != 0) writer.writeByte(',') catch
                return error.SnapshotTooLarge;
            writer.writeAll("{\"id\":") catch return error.SnapshotTooLarge;
            try self.projectedJsonValue(writer, connection.id);
            writer.writeAll(",\"displayName\":") catch return error.SnapshotTooLarge;
            try self.projectedJsonValue(writer, connection.display_name);
            writer.print(",\"protocol\":\"{s}\",\"normalizedBaseUrl\":", .{
                @tagName(connection.protocol),
            }) catch return error.SnapshotTooLarge;
            try self.projectedJsonValue(writer, connection.normalized_base_url);
            writer.print(",\"state\":\"{s}\",\"testStatus\":\"{s}\",\"credentialStatus\":\"{s}\",\"enabled\":{},\"connectionGeneration\":\"{d}\",\"selectedModel\":", .{
                @tagName(connection.state),
                @tagName(connection.test_status),
                @tagName(connection.credential_status),
                connection.enabled,
                connection.connection_generation,
            }) catch return error.SnapshotTooLarge;
            try self.projectedJsonValue(writer, connection.selected_model);
            writer.writeAll(",\"models\":[") catch return error.SnapshotTooLarge;
            for (connection.models, 0..) |model, model_index| {
                if (model_index != 0) writer.writeByte(',') catch
                    return error.SnapshotTooLarge;
                writer.writeAll("{\"id\":") catch return error.SnapshotTooLarge;
                try self.projectedJsonValue(writer, model.id);
                writer.writeAll(",\"displayName\":") catch return error.SnapshotTooLarge;
                try self.projectedJsonValue(writer, model.display_name);
                writer.writeByte('}') catch return error.SnapshotTooLarge;
            }
            writer.writeAll("]}") catch return error.SnapshotTooLarge;
        }
        writer.writeAll("],\"selectedModelConnectionId\":") catch
            return error.SnapshotTooLarge;
        try self.projectedJsonValue(writer, view.selected_model_connection_id);
        writer.writeAll(",\"canCreateTask\":") catch
            return error.SnapshotTooLarge;
        writer.print(
            "{},\"errorCode\":\"{s}\",\"safeDiagnostic\":",
            .{ view.can_create_task, @tagName(view.error_code) },
        ) catch return error.SnapshotTooLarge;
        try self.projectedJsonValue(writer, view.safe_diagnostic);
        writer.print(
            ",\"catalogGeneration\":\"{d}\",\"metaskExecutionGeneration\":\"{d}\",\"executionGeneration\":\"{d}\"}}",
            .{
                view.catalog_generation,
                view.metask_execution_generation,
                view.execution_generation,
            },
        ) catch return error.SnapshotTooLarge;
    }

    fn writeWorkspace(
        self: *Workbench,
        writer: *std.Io.Writer,
        workspace: *const WorkspaceView,
    ) Error!void {
        const signals = self.workspaceSignals(workspace.id);
        writer.print("{{\"id\":\"{d}\",\"epoch\":\"{d}\",\"kind\":\"{s}\",\"displayName\":", .{
            workspace.id,
            workspace.epoch,
            @tagName(workspace.kind),
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
                workspace.catalog_slot.availability(workspace.catalog_job != null),
                workspace.catalog_slot.snapshotConst(),
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
        self.mcp_refresh_timer.cancelCurrent();
        self.markSkillCatalogUnavailable();
        for (self.tasks) |*entry| {
            const task = &(entry.* orelse continue);
            if (task.runtime.close_thread) |thread| {
                thread.join();
                task.runtime.close_thread = null;
            }
            self.deinitTaskView(task);
            entry.* = null;
        }
        self.allocator.free(self.tasks);
        for (self.task_failures.items) |failure| self.allocator.free(failure.reason);
        self.task_failures.deinit(self.allocator);
        for (self.workspaces) |*entry| {
            const workspace = &(entry.* orelse continue);
            self.deinitWorkspaceView(workspace);
        }
        self.allocator.free(self.workspaces);
        self.scheduled_tasks.deinit();
        if (self.skill_transactions) |*transactions| transactions.deinit();
        if (self.skill_inventory) |*inventory| inventory.deinit();
        self.skill_enablement.deinit();
        if (self.automatic_workspaces) |*store| store.deinit();
        if (self.skill_staging_root) |root| self.allocator.free(root);
        if (self.canonical_user_home) |home| self.allocator.free(home);
        if (self.mcp) |*mcp| mcp.deinit();
        self.execution.deinit();
        if (self.custom_execution_binding) |*binding| binding.deinit();
        self.account.deinit();
        std.debug.assert(self.projection_bytes == 0);
        self.executor.deinit();
        self.* = undefined;
    }

    pub fn shutdownExecutor(self: *Workbench) void {
        if (self.executor_shutdown) return;
        self.shutting_down = true;
        if (self.mcp) |*mcp| {
            mcp_policy.blockAdmission(mcp, .shutting_down);
            if (mcp.activation) |activation| activation.deinit();
            mcp.activation = null;
            mcp.activation_failed = true;
        }
        self.schedule_timer.cancelCurrent();
        self.mcp_refresh_timer.cancelCurrent();
        for (self.tasks) |*entry| {
            const view = &(entry.* orelse continue);
            cancelTaskCheckpoints(view);
            cancelTaskAutomaticTitles(view);
            if (view.runtime.worker_references.load(.acquire) == 0) continue;
            if (view.runtime.active_operation == .restore) {
                const job = view.runtime.restore_job orelse continue;
                job.requestCancellation();
                _ = self.executor.cancel(job);
                continue;
            }
            switch (view.runtime.active_operation) {
                .none => {},
                .restore => unreachable,
                .compact => |operation_id| {
                    const compact = findCompact(view.durable.compacts, operation_id) orelse
                        continue;
                    _ = self.cancelCompactRecord(
                        view,
                        compact,
                        .app_shutdown,
                    );
                },
                .run => |run_id| {
                    const run = findRun(view.durable.runs, run_id) orelse continue;
                    if (isTerminalPhase(runPhase(run))) continue;
                    const dispatch = requestRunTermination(run, .app_shutdown);
                    if (self.executor.cancel(run)) {
                        run.terminal_observed = true;
                    } else {
                        consumeLifecycleTermination(dispatch, run.id);
                    }
                },
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
        self.settleCheckpointTransactionsForShutdown();
        self.commitTaskStateNoFail();
    }

    /// Records the Application-owned Runtime shutdown fact and permanently
    /// invalidates every remaining Task Session Binding. Application calls
    /// this only after Runtime.shutdown succeeds and the final lifecycle sync.
    pub fn relinquishAgentSessionsAfterRuntimeShutdown(self: *Workbench) void {
        std.debug.assert(self.executor_shutdown);
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

    pub fn abandonAgentSessionsForRuntimeDeinit(self: *Workbench) void {
        std.debug.assert(self.executor_shutdown);
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

    fn settleCheckpointTransactionsForShutdown(self: *Workbench) void {
        for (self.tasks) |*entry| {
            const task = &(entry.* orelse continue);
            for (task.durable.runs) |*run_entry| {
                const run = &(run_entry.* orelse continue);
                self.settleCheckpointPostprocessForShutdown(&run.checkpoint);
                if (run.worker_reference_held.load(.acquire))
                    releaseWorkerReference(task, run);
            }
            for (task.durable.compacts) |*compact_entry| {
                const compact = &(compact_entry.* orelse continue);
                self.settleCheckpointPostprocessForShutdown(&compact.checkpoint);
                releaseCompactWorkerReference(task, compact);
            }
        }
    }

    fn settleCheckpointPostprocessForShutdown(
        self: *Workbench,
        postprocess: *CheckpointPostprocess,
    ) void {
        switch (postprocess.payload) {
            .candidate => |*candidate| candidate.record.deinit(self.allocator),
            .store_outcome_unknown => |*candidate| candidate.record.deinit(self.allocator),
            .none, .failure => {},
        }
        postprocess.payload = .none;
        postprocess.state.store(.settled, .release);
    }

    fn taskViewContainsSensitive(context: *const anyopaque, value: []const u8) bool {
        const self: *const Workbench = @ptrCast(@alignCast(context));
        return self.containsKnownCredential(value);
    }

    fn writeTaskViewJson(
        context: *const anyopaque,
        writer: *std.Io.Writer,
        value: []const u8,
    ) task_view.Error!void {
        const self: *const Workbench = @ptrCast(@alignCast(context));
        self.projectedJsonValueWithKnownCredentials(writer, value) catch
            return error.SnapshotTooLarge;
    }

    fn taskTextProjection(self: *const Workbench) task_view.TextProjection {
        return .{
            .context = self,
            .contains_sensitive_fn = taskViewContainsSensitive,
            .write_json_fn = writeTaskViewJson,
        };
    }

    fn writeTaskCatalogProjection(
        context: *const anyopaque,
        writer: *std.Io.Writer,
        catalog: CatalogProjection,
    ) task_view.Error!void {
        const self: *Workbench = @ptrCast(@alignCast(@constCast(context)));
        self.writeCatalogProjection(writer, catalog) catch
            return error.SnapshotTooLarge;
    }

    fn writeTaskPendingUiProjection(
        context: *anyopaque,
        writer: *std.Io.Writer,
        task: *const TaskView,
        text: task_view.TextProjection,
    ) task_view.Error!void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        self.writePendingUi(writer, task, text) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.SnapshotTooLarge => error.SnapshotTooLarge,
            else => error.InvalidUiResponse,
        };
    }

    fn writeTask(self: *Workbench, writer: *std.Io.Writer, task: *TaskView) Error!void {
        task_view.writeProjection(writer, .{
            .task = task,
            .recovery = self.taskRecoveryProjection(task),
            .shutting_down = self.shutting_down,
            .text = self.taskTextProjection(),
            .catalog = .{
                .context = self,
                .write_fn = writeTaskCatalogProjection,
            },
            .pending_ui = .{
                .context = self,
                .write_fn = writeTaskPendingUiProjection,
            },
        }) catch |err| return @errorCast(err);
    }

    fn writeCatalogProjection(
        self: *Workbench,
        writer: *std.Io.Writer,
        catalog: CatalogProjection,
    ) Error!void {
        const available = catalog.availability == .ready or
            catalog.availability == .degraded;
        std.debug.assert(available == (catalog.selection_revision != null));
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
        writer.writeAll(",\"selectionRevision\":") catch return error.SnapshotTooLarge;
        switch (catalog.availability) {
            .ready, .degraded => writer.print(
                "\"{d}\"",
                .{catalog.selection_revision.?},
            ) catch return error.SnapshotTooLarge,
            .uninitialized, .loading, .unavailable => writer.writeAll("null") catch return error.SnapshotTooLarge,
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
            writer.print("],\"maxValues\":{d},\"enabled\":{}}}", .{
                skill.max_values,
                skill.enabled,
            }) catch
                return error.SnapshotTooLarge;
        }
        writer.writeAll("],\"issues\":[") catch return error.SnapshotTooLarge;
        for (catalog.issues, 0..) |issue, index| {
            if (index != 0) writer.writeByte(',') catch
                return error.SnapshotTooLarge;
            writer.print("{{\"code\":\"{s}\",\"invocationName\":", .{
                @tagName(issue.code),
            }) catch return error.SnapshotTooLarge;
            if (issue.skill_policy_key) |name|
                try self.projectedJsonValueWithKnownCredentials(writer, name)
            else
                writer.writeAll("null") catch return error.SnapshotTooLarge;
            writer.writeByte('}') catch return error.SnapshotTooLarge;
        }
        writer.writeAll("]}") catch return error.SnapshotTooLarge;
    }

    fn writeSkillManagement(
        self: *Workbench,
        writer: *std.Io.Writer,
    ) Error!void {
        writer.print("{{\"availability\":\"{s}\",\"enablementAvailability\":\"{s}\",\"assets\":[", .{
            @tagName(self.skill_management_health),
            @tagName(self.skill_enablement_health),
        }) catch return error.SnapshotTooLarge;
        const inventory = self.skillInventory();
        var count: usize = 0;
        for (inventory.items()) |asset| {
            if (count != 0) writer.writeByte(',') catch
                return error.SnapshotTooLarge;
            count += 1;
            try self.writeManagedSkillAsset(writer, asset);
        }
        const catalog = self.skill_catalog_slot.snapshotConst();
        if (catalog) |snapshot| for (snapshot.skills) |skill| {
            if (inventoryHasInvocationInScope(
                inventory,
                .personal,
                skill.invocation_name,
            )) continue;
            if (count != 0) writer.writeByte(',') catch
                return error.SnapshotTooLarge;
            count += 1;
            try self.writeExternalSkillAsset(writer, skill, .personal);
        };
        for (self.workspaces) |*entry| {
            const workspace = &(entry.* orelse continue);
            if (workspace.kind != .manual or !workspace.visible or
                workspace.authorization != .available)
                continue;
            const workspace_catalog = workspace.catalog_slot.snapshotConst() orelse
                continue;
            const scope: skill_management_impl.Scope = .{ .project = .{
                .workspace_id = workspace.id,
                .workspace_epoch = workspace.epoch,
            } };
            for (workspace_catalog.skills) |skill| {
                if (inventoryHasInvocationInScope(
                    inventory,
                    scope,
                    skill.invocation_name,
                )) continue;
                if (count != 0) writer.writeByte(',') catch
                    return error.SnapshotTooLarge;
                count += 1;
                try self.writeExternalSkillAsset(writer, skill, scope);
            }
        }
        writer.writeAll("]}") catch return error.SnapshotTooLarge;
    }

    fn writeManagedSkillAsset(
        self: *Workbench,
        writer: *std.Io.Writer,
        asset: skill_management_impl.Asset,
    ) Error!void {
        const id_hex = std.fmt.bytesToHex(asset.install_id, .lower);
        const skill = self.findCatalogSkillForScope(asset.scope, asset.target_entry);
        writer.writeAll("{\"installId\":") catch return error.SnapshotTooLarge;
        jsonValue(writer, &id_hex) catch return error.SnapshotTooLarge;
        writer.print(",\"sourceKind\":\"{s}\",\"scope\":", .{@tagName(asset.source_kind)}) catch
            return error.SnapshotTooLarge;
        try writeSkillScope(writer, asset.scope);
        writer.print(",\"managementState\":\"{s}\",\"skillId\":", .{@tagName(asset.state)}) catch
            return error.SnapshotTooLarge;
        if (skill) |value|
            try self.projectedJsonValueWithKnownCredentials(writer, value.skill_id)
        else
            writer.writeAll("null") catch return error.SnapshotTooLarge;
        writer.writeAll(",\"invocationName\":") catch return error.SnapshotTooLarge;
        try self.projectedJsonValueWithKnownCredentials(
            writer,
            if (skill) |value| value.invocation_name else asset.target_entry,
        );
        writer.writeAll(",\"displayName\":") catch return error.SnapshotTooLarge;
        try self.projectedJsonValueWithKnownCredentials(
            writer,
            if (skill) |value| value.display_name else asset.target_entry,
        );
        writer.writeAll(",\"description\":") catch return error.SnapshotTooLarge;
        try self.projectedJsonValueWithKnownCredentials(
            writer,
            if (skill) |value| value.description else "",
        );
        try self.writeSkillAssetTail(
            writer,
            if (skill) |value| value.argument_names else &.{},
            if (skill) |value| value.max_values else 0,
            asset.state != .externally_managed and asset.state == .ready and
                asset.recovery == null,
            asset.state == .pending_verification,
            asset.scope,
            asset.target_entry,
        );
    }

    fn writeExternalSkillAsset(
        self: *Workbench,
        writer: *std.Io.Writer,
        skill: SkillProjection,
        scope: skill_management_impl.Scope,
    ) Error!void {
        writer.writeAll("{\"installId\":null,\"sourceKind\":\"external\",\"scope\":") catch
            return error.SnapshotTooLarge;
        try writeSkillScope(writer, scope);
        writer.writeAll(",\"managementState\":\"externally_managed\",\"skillId\":") catch
            return error.SnapshotTooLarge;
        try self.projectedJsonValueWithKnownCredentials(writer, skill.skill_id);
        writer.writeAll(",\"invocationName\":") catch return error.SnapshotTooLarge;
        try self.projectedJsonValueWithKnownCredentials(writer, skill.invocation_name);
        writer.writeAll(",\"displayName\":") catch return error.SnapshotTooLarge;
        try self.projectedJsonValueWithKnownCredentials(writer, skill.display_name);
        writer.writeAll(",\"description\":") catch return error.SnapshotTooLarge;
        try self.projectedJsonValueWithKnownCredentials(writer, skill.description);
        try self.writeSkillAssetTail(
            writer,
            skill.argument_names,
            skill.max_values,
            false,
            false,
            scope,
            skill.invocation_name,
        );
    }

    fn writeSkillAssetTail(
        self: *Workbench,
        writer: *std.Io.Writer,
        argument_names: []const []const u8,
        max_values: u32,
        manageable: bool,
        pending: bool,
        scope: skill_management_impl.Scope,
        invocation_name: []const u8,
    ) Error!void {
        const runtime_skill = self.findCatalogSkillForScope(scope, invocation_name);
        writer.writeAll(",\"skillPolicyKey\":") catch return error.SnapshotTooLarge;
        if (runtime_skill) |skill|
            try self.projectedJsonValueWithKnownCredentials(writer, skill.skill_policy_key)
        else
            writer.writeAll("null") catch return error.SnapshotTooLarge;
        writer.writeAll(",\"argumentNames\":[") catch return error.SnapshotTooLarge;
        for (argument_names, 0..) |name, index| {
            if (index != 0) writer.writeByte(',') catch
                return error.SnapshotTooLarge;
            try self.projectedJsonValueWithKnownCredentials(writer, name);
        }
        const catalog_available = switch (scope) {
            .personal => self.skill_catalog_slot.snapshotConst() != null,
            .project => |project| available: {
                const workspace = self.findWorkspace(project.workspace_id) orelse
                    break :available false;
                break :available workspace.epoch == project.workspace_epoch and
                    workspace.catalog_slot.snapshotConst() != null;
            },
        };
        const enablement_available = self.skill_enablement_health == .ready and
            catalog_available;
        const selection_revision = if (enablement_available)
            if (self.catalogForSkillScope(scope)) |snapshot|
                snapshot.selection_revision
            else
                null
        else
            null;
        const can_set_enabled = enablement_available and
            runtime_skill != null and selection_revision != null;
        writer.print("],\"maxValues\":{d},\"canExport\":{},\"canReimport\":{},\"canUninstall\":{},\"canRetry\":{},\"enabled\":", .{
            max_values,
            manageable,
            manageable,
            manageable or pending,
            pending,
        }) catch return error.SnapshotTooLarge;
        if (runtime_skill) |skill| {
            if (enablement_available)
                writer.print("{}", .{skill.enabled}) catch return error.SnapshotTooLarge
            else
                writer.writeAll("null") catch return error.SnapshotTooLarge;
        } else writer.writeAll("null") catch return error.SnapshotTooLarge;
        writer.writeAll(",\"enablementState\":") catch return error.SnapshotTooLarge;
        if (runtime_skill) |skill| {
            if (enablement_available) switch (scope) {
                .personal => jsonValue(
                    writer,
                    if (skill.enabled) "enabled" else "disabled",
                ) catch return error.SnapshotTooLarge,
                .project => |project| jsonValue(
                    writer,
                    @tagName(self.skill_enablement.workspaceOverride(.{
                        .workspace_id = project.workspace_id,
                        .workspace_epoch = project.workspace_epoch,
                    }, skill.skill_policy_key)),
                ) catch return error.SnapshotTooLarge,
            } else writer.writeAll("null") catch return error.SnapshotTooLarge;
        } else writer.writeAll("null") catch return error.SnapshotTooLarge;
        writer.print(",\"canSetEnabled\":{},\"selectionRevision\":", .{can_set_enabled}) catch
            return error.SnapshotTooLarge;
        if (selection_revision) |revision|
            writer.print("\"{d}\"", .{revision}) catch return error.SnapshotTooLarge
        else
            writer.writeAll("null") catch return error.SnapshotTooLarge;
        writer.writeAll(",\"issueCodes\":[") catch return error.SnapshotTooLarge;
        if (self.catalogForSkillScope(scope)) |snapshot| {
            var issue_count: usize = 0;
            for (snapshot.issues) |issue| {
                const issue_name = issue.skill_policy_key orelse continue;
                if (!std.mem.eql(u8, issue_name, invocation_name)) continue;
                if (issue_count != 0) writer.writeByte(',') catch
                    return error.SnapshotTooLarge;
                issue_count += 1;
                jsonValue(writer, @tagName(issue.code)) catch
                    return error.SnapshotTooLarge;
            }
        }
        writer.writeAll("]}") catch return error.SnapshotTooLarge;
    }

    fn skillInventory(self: *const Workbench) *const skill_management_impl.Inventory {
        if (self.skill_transactions) |*transactions| return &transactions.inventory;
        return &(self.skill_inventory orelse unreachable);
    }

    fn findCatalogSkillForScope(
        self: *const Workbench,
        scope: skill_management_impl.Scope,
        invocation_name: []const u8,
    ) ?SkillProjection {
        const snapshot = self.catalogForSkillScope(scope) orelse return null;
        for (snapshot.skills) |skill|
            if (std.mem.eql(u8, skill.invocation_name, invocation_name)) return skill;
        return null;
    }

    fn catalogForSkillScope(
        self: *const Workbench,
        scope: skill_management_impl.Scope,
    ) ?*const CatalogSnapshot {
        return switch (scope) {
            .personal => self.skill_catalog_slot.snapshotConst(),
            .project => |project| catalog: {
                for (self.workspaces) |*entry| {
                    const workspace = &(entry.* orelse continue);
                    if (workspace.id == project.workspace_id and
                        workspace.epoch == project.workspace_epoch)
                        break :catalog workspace.catalog_slot.snapshotConst();
                }
                break :catalog null;
            },
        };
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
            if (issue.skill_policy_key) |name|
                if (self.containsKnownCredential(name)) return true;
        return false;
    }

    fn writePendingUi(
        self: *Workbench,
        writer: *std.Io.Writer,
        view: *const TaskView,
        text: task_view.TextProjection,
    ) Error!void {
        if (view.runtime.pending_ui_request_id == 0) {
            writer.writeAll("null") catch return error.SnapshotTooLarge;
            return;
        }
        var access = @constCast(&view.runtime).acquireAccess() catch {
            writer.writeAll("null") catch return error.SnapshotTooLarge;
            return;
        };
        defer access.deinit();
        var pending = access.copyPendingUiRequest(self.allocator) catch |err| switch (err) {
            error.NoPendingUiRequest, error.StaleUiResponse => {
                writer.writeAll("null") catch return error.SnapshotTooLarge;
                return;
            },
            else => return err,
        };
        defer pending.deinit();
        var parsed = lifecycle.decodePermissionRequest(self.allocator, pending.json) catch return error.InvalidUiResponse;
        defer parsed.deinit();
        // The synchronous callback may publish between lifecycle reconciliation
        // and serialization. Omit that just-arrived request from this snapshot;
        // its notification drives the next revision instead of failing the
        // whole product snapshot on a benign observation race.
        if (view.runtime.pending_ui_request_id != pending.request_id or view.runtime.pending_ui_order == 0) {
            writer.writeAll("null") catch return error.SnapshotTooLarge;
            return;
        }
        if (findRun(view.durable.runs, pending.run_id) == null)
            return error.InvalidUiResponse;
        task_view.writePendingUi(
            writer,
            text,
            pending.request_id,
            pending.run_id,
            view.runtime.pending_ui_order,
            parsed.value(),
        ) catch |err| return @errorCast(err);
    }

    fn deinitFileReference(self: *Workbench, reference: *FileReferenceView) void {
        self.freeTracked(reference.id);
        self.freeTracked(reference.title);
        self.freeTracked(reference.display_path);
        self.freeTracked(reference.kind);
        self.freeTracked(reference.locator);
        reference.* = undefined;
    }

    fn taskEventProjection(self: *Workbench) task_model.EventProjection {
        return .{
            .context = self,
            .max_assistant_message_bytes = self.limits.max_assistant_message_bytes,
            .max_tool_field_bytes = self.limits.max_tool_field_bytes,
            .append_assistant_fn = appendTaskEventAssistant,
            .replace_text_fn = replaceTaskEventText,
            .find_or_create_tool_fn = findOrCreateTaskEventTool,
            .replace_file_references_fn = replaceTaskEventFileReferences,
        };
    }

    fn appendTaskEventAssistant(
        context: *anyopaque,
        target: *TrackedText,
        suffix: []const u8,
        max: usize,
        credential: []const u8,
    ) task_model.EventProjectionError!bool {
        const self: *Workbench = @ptrCast(@alignCast(context));
        self.appendTrackedText(target, suffix, max) catch |err|
            return @errorCast(err);
        return self.redactTrackedText(target, credential);
    }

    fn replaceTaskEventText(
        context: *anyopaque,
        target: *[]u8,
        value: []const u8,
        max: usize,
        credential: []const u8,
    ) task_model.EventProjectionError!task_model.TextProjectionResult {
        const self: *Workbench = @ptrCast(@alignCast(context));
        const result = self.replaceTrackedProjected(
            target,
            value,
            max,
            credential,
        ) catch |err| return @errorCast(err);
        return .{ .truncated = result.truncated, .redacted = result.redacted };
    }

    fn findOrCreateTaskEventTool(
        context: *anyopaque,
        run: *RunRecord,
        id: []const u8,
        name: []const u8,
        input: []const u8,
    ) task_model.EventProjectionError!*ToolView {
        const self: *Workbench = @ptrCast(@alignCast(context));
        return self.findOrCreateTool(run, id, name, input) catch |err|
            return @errorCast(err);
    }

    fn replaceTaskEventFileReferences(
        context: *anyopaque,
        tool: *ToolView,
        envelope: *const lifecycle.OwnedCoreEvent,
        credential: []const u8,
        task_id: u64,
        run_generation: u64,
    ) task_model.EventProjectionError!void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        const event = switch (envelope.event.value) {
            .unknown => unreachable,
            .known => |known| known,
        };
        const result = switch (event) {
            .tool_result => |value| value,
            else => unreachable,
        };
        const file_refs = if (comptime @hasField(@TypeOf(result), "file_refs"))
            result.file_refs
        else
            null;
        self.replaceFileReferences(
            tool,
            file_refs,
            credential,
            task_id,
            run_generation,
        ) catch |err| return @errorCast(err);
    }

    fn clearFileReferences(self: *Workbench, tool: *ToolView) void {
        if (tool.file_refs) |refs| {
            for (refs) |*entry| {
                if (entry.*) |*reference| self.deinitFileReference(reference);
                entry.* = null;
            }
        }
    }

    fn deinitToolView(self: *Workbench, tool: *ToolView) void {
        self.freeTracked(tool.id);
        self.freeTracked(tool.name);
        self.freeTracked(tool.input);
        self.freeTracked(tool.progress);
        self.freeTracked(tool.content);
        self.clearFileReferences(tool);
        if (tool.file_refs) |refs| self.allocator.free(refs);
        tool.* = undefined;
    }

    fn replaceFileReferences(
        self: *Workbench,
        tool: *ToolView,
        refs: anytype,
        credential: []const u8,
        task_id: u64,
        run_generation: u64,
    ) Error!void {
        self.clearFileReferences(tool);
        const values = refs orelse return;
        if (values.len > self.limits.max_file_refs_per_tool)
            return error.ToolCapacity;
        if (tool.file_refs == null) {
            const refs_storage = try self.allocator.alloc(?FileReferenceView, self.limits.max_file_refs_per_tool);
            @memset(refs_storage, null);
            tool.file_refs = refs_storage;
        }
        errdefer self.clearFileReferences(tool);
        for (values, 0..) |reference, index| {
            var locator_kind: FileReferenceLocatorKind = undefined;
            var locator_value: []const u8 = undefined;
            switch (reference.locator) {
                .workspace_path => |value| {
                    locator_kind = .workspace_path;
                    locator_value = value;
                },
                .absolute_path => |value| {
                    locator_kind = .absolute_path;
                    locator_value = value;
                },
                .uri => |value| {
                    locator_kind = .uri;
                    locator_value = value;
                },
            }
            if (locator_value.len > self.limits.max_file_ref_field_bytes or
                reference.title.len > self.limits.max_file_ref_field_bytes or
                reference.kind.len > self.limits.max_file_ref_field_bytes)
                return error.ToolCapacity;
            var id_storage: [96]u8 = undefined;
            const id = formatFileReferenceId(
                &id_storage,
                task_id,
                run_generation,
                tool.order,
                index + 1,
            );
            var owned = FileReferenceView{
                .id = try self.copyBounded(id, id.len),
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
            errdefer self.deinitFileReference(&owned);
            const title_projection = try self.copyProjected(
                reference.title,
                self.limits.max_file_ref_field_bytes,
                credential,
            );
            owned.title = title_projection.value;
            const display_source = if (locator_kind == .workspace_path)
                locator_value
            else if (reference.title.len != 0)
                reference.title
            else
                "file";
            const display_projection = try self.copyProjected(
                display_source,
                self.limits.max_file_ref_field_bytes,
                credential,
            );
            owned.display_path = display_projection.value;
            const kind_projection = try self.copyProjected(
                reference.kind,
                self.limits.max_file_ref_field_bytes,
                credential,
            );
            owned.kind = kind_projection.value;
            owned.locator = try self.copyBounded(locator_value, self.limits.max_file_ref_field_bytes);
            tool.file_refs.?[index] = owned;
            owned = undefined;
            tool.redacted = tool.redacted or title_projection.redacted or
                display_projection.redacted or kind_projection.redacted;
        }
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
        errdefer self.freeTracked(content);
        const file_refs = try self.allocator.alloc(?FileReferenceView, self.limits.max_file_refs_per_tool);
        errdefer self.allocator.free(file_refs);
        @memset(file_refs, null);
        run.tools[slot] = .{
            .route_digest = route_digest,
            .id = owned_id,
            .order = takeActivityOrder(run),
            .name = owned_name,
            .input = owned_input,
            .progress = progress,
            .content = content,
            .file_refs = file_refs,
            .state = .running,
            .input_truncated = input_projection.truncated,
            .redacted = name_projection.redacted or
                input_projection.redacted,
        };
        return &run.tools[slot].?;
    }

    fn taskContinuationAvailable(self: *Workbench, task: *const TaskView) bool {
        return !self.shutting_down and
            taskLifecycle(task) == .open and
            continuationAvailable(self.taskContinuation(task));
    }

    fn taskContinuation(
        self: *Workbench,
        task: *const TaskView,
    ) ContinuationCapability {
        return self.taskRecoveryProjection(task).continuation;
    }

    fn taskRecoveryProjection(
        self: *Workbench,
        task: *const TaskView,
    ) task_recovery.Projection {
        const checkpoint = task.durable.checkpoint;
        const workspace = self.findWorkspace(task.durable.workspace_id);
        const checkpoint_binding_valid = if (checkpoint) |record| binding: {
            if (record.blob.generation == 0) break :binding false;
            record.validateBinding(
                task.durable.id,
                task.durable.binding_epoch,
            ) catch break :binding false;
            break :binding true;
        } else false;
        const checkpoint_history_current = if (checkpoint) |record|
            checkpointMatchesCurrentHistory(task, record)
        else
            false;
        const workspace_authorized = if (workspace) |value|
            value.visible and value.authorization == .available and
                value.epoch == task.durable.workspace_epoch and
                std.mem.eql(u8, value.canonical_root, task.durable.workspace_root)
        else
            false;
        return task_recovery.project(.{
            .archived = task.durable.archived,
            .attachment = if (task.deletion == .deleting)
                .closing
            else
                recoveryAttachment(task.runtime.attachment),
            .operation = recoveryOperation(task.runtime.active_operation),
            .task_persistence_ready = self.task_persistence_health.operational(),
            .checkpoint_store_ready = self.checkpoint_store != null and
                self.checkpoint_store_health.load(.acquire) == .ready,
            .checkpoint_available = checkpoint != null and
                task.durable.checkpoint_anchor == .available,
            .checkpoint_binding_valid = checkpoint_binding_valid,
            .checkpoint_history_current = checkpoint_history_current,
            .execution_exact = self.recoveryExecutionExact(task),
            .workspace_authorized = workspace_authorized,
            .runtime_admission_available = self.agent_runtime.restoreAdmissionAvailable(),
            .authority_stable = !self.recovery_poisoned and
                self.recoveryAuthorityStable(workspace),
            .recovery_failed = task.runtime.last_restore_failure != null,
        });
    }

    fn recoveryExecutionExact(self: *const Workbench, task: *const TaskView) bool {
        if (self.execution_replacement != .none or
            !self.execution.ready() or
            task.durable.execution_generation != self.execution.generation or
            task.durable.execution_provider != self.execution.provider.?)
            return false;
        if (self.custom_execution_binding) |binding|
            return std.mem.eql(u8, binding.model_id, self.execution.model()) and
                std.mem.eql(u8, task.durable.execution_model, binding.model_id);
        return self.account.account_can_create_task and
            self.account.catalog_state == .ready and
            self.account.execution_generation == self.execution.generation and
            self.accountHasModel(task.durable.execution_model);
    }

    fn accountHasModel(self: *const Workbench, model: []const u8) bool {
        for (self.account.model_views[0..self.account.model_count]) |candidate|
            if (std.mem.eql(u8, candidate.id, model)) return true;
        return false;
    }

    fn recoveryAuthorityStable(
        self: *const Workbench,
        workspace: ?*const WorkspaceView,
    ) bool {
        if (self.shutting_down or self.canonical_user_home == null or
            self.skill_reconciliation != null)
            return false;
        const value = workspace orelse return false;
        if (value.catalog_job != null or value.catalog_slot.snapshotConst() == null)
            return false;
        const mcp = if (self.mcp) |*state| state else return true;
        if (!mcp.committed or self.mcp_refresh_job != null or
            mcp.refresh_pending_blocks_admission or
            mcp.authorization_operation != null or
            mcp.runtime_auth_failure_blocked)
            return false;
        return mcp.admission == .ready;
    }

    fn taskExecutionInput(
        task: *const TaskView,
    ) Error!account_contract.ExecutionConfigInput {
        const execution = task.runtime.executionConst() orelse return error.ExecutionUnavailable;
        const input = execution.input();
        if (input.execution_generation != task.durable.execution_generation or
            accountProvider(input.target.provider_kind) != task.durable.execution_provider)
            return error.ExecutionGenerationMismatch;
        return input;
    }

    fn canCreateTask(self: *const Workbench) bool {
        return !self.shutting_down and
            self.execution_replacement == .none and
            self.execution.ready() and
            if (self.custom_execution_binding != null)
                true
            else
                self.account.account_can_create_task and
                    self.account.catalog_state == .ready and
                    self.account.execution_generation == self.execution.generation;
    }

    fn validExecutionGeneration(self: *const Workbench, generation: u64) bool {
        return generation != 0 and generation == self.execution.generation and
            (self.custom_execution_binding != null or
                generation == self.account.execution_generation);
    }

    fn admissionModel(self: *const Workbench) []const u8 {
        return if (self.custom_execution_binding != null)
            self.execution.model()
        else
            self.account.selected_model.view();
    }

    fn scheduledTaskDefinition(
        self: *Workbench,
        input: ScheduledTaskDefinitionInput,
    ) Error!scheduled_tasks_impl.Definition {
        if (!self.canCreateTask()) return error.ExecutionUnavailable;
        if (!self.validExecutionGeneration(input.expected_execution_generation))
            return error.ExecutionGenerationMismatch;
        const title = std.mem.trim(u8, input.title, " \t\r\n");
        if (title.len == 0 or title.len > self.limits.max_task_title_bytes or
            !std.unicode.utf8ValidateSlice(title))
            return error.InvalidTaskTitle;
        for (title) |byte| if (byte < 0x20) return error.InvalidTaskTitle;
        if (self.automatic_workspaces == null)
            return error.WorkspaceUnavailable;
        try input.recurrence.validate();
        const scheduled_input = std.mem.trim(u8, input.input, " \t\r\n");
        if (scheduled_input.len == 0 or
            scheduled_input.len > self.limits.max_user_message_bytes or
            !std.unicode.utf8ValidateSlice(scheduled_input))
            return error.InvalidScheduledTaskInput;
        return .{
            .title = title,
            .execution_generation = self.execution.generation,
            .execution_provider = scheduledProvider(self.execution.provider.?),
            .execution_model = self.admissionModel(),
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
                if (hasActiveOperation(task)) {
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
        const task_id = self.createTaskForWorkspace(
            .automatic,
            claimed_item.execution_generation,
            null,
            null,
        ) catch |err| {
            self.finalizeScheduledTaskClaimRejected(
                id,
                planned_at_unix_seconds,
                source,
                scheduledFailure(err),
                0,
            );
            return err;
        };
        self.renameTask(task_id, claimed_item.title) catch |err| {
            self.finalizeScheduledTaskClaimRejected(
                id,
                planned_at_unix_seconds,
                source,
                .task_start_failed,
                task_id,
            );
            return err;
        };
        const task = self.findTask(task_id) orelse unreachable;
        const run_input: TaskRunInput = .{
            .text = claimed_item.input.borrowed(),
        };
        _ = self.runTaskAtBinding(task_id, task.durable.binding_epoch, run_input) catch |err| {
            self.finalizeScheduledTaskClaimRejected(
                id,
                planned_at_unix_seconds,
                source,
                scheduledFailure(err),
                task_id,
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
        task_id: u64,
    ) void {
        var candidate = self.scheduled_tasks.clone(self.allocator) catch return;
        var candidate_owned = true;
        defer if (candidate_owned) candidate.deinit();
        candidate.finalizeClaimRejected(
            candidate.find(id) orelse return,
            planned_at_unix_seconds,
            source,
            reason,
            task_id,
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
                const terminal = lastTerminalFacts(task.durable.runs) orelse continue;
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
                    !std.mem.eql(u8, item.execution_model, self.admissionModel()))
                    break :binding .execution_changed;
                if (self.automatic_workspaces == null)
                    break :binding .workspace_unavailable;
                break :binding null;
            };
            if (reason) |failure| {
                store.markNeedsAttention(item, failure);
                changed = true;
            }
        }
        return changed;
    }

    fn taskPersistenceLimits(self: *const Workbench) task_persistence.Limits {
        return .{
            .max_workspaces = self.workspaces.len,
            .max_tasks = self.limits.max_tasks,
            .max_runs_per_task = self.limits.max_runs_per_task,
            .max_compacts_per_task = self.limits.max_compacts_per_task,
            .max_tools_per_run = self.limits.max_tools_per_run,
            .max_file_refs_per_tool = self.limits.max_file_refs_per_tool,
            .max_ui_history_per_task = self.limits.max_ui_history_per_task,
            .max_workspace_bytes = self.limits.max_workspace_bytes,
            .max_task_title_bytes = self.limits.max_task_title_bytes,
            .max_user_message_bytes = self.limits.max_user_message_bytes,
            .max_assistant_message_bytes = self.limits.max_assistant_message_bytes,
            .max_tool_field_bytes = self.limits.max_tool_field_bytes,
            .max_file_ref_field_bytes = self.limits.max_file_ref_field_bytes,
            .max_execution_model_bytes = account_contract.Limits.model_id_bytes,
            .max_terminal_diagnostic_bytes = self.limits.max_terminal_diagnostic_bytes,
        };
    }

    fn taskRestoreProjection(self: *Workbench) task_persistence.RestoreProjection {
        return .{
            .context = self,
            .allocator = self.allocator,
            .limits = self.taskPersistenceLimits(),
            .copy_fn = copyRestoredTaskText,
            .alloc_fn = allocRestoredTaskText,
            .append_text_fn = appendRestoredTaskText,
            .free_fn = freeRestoredTaskText,
            .free_text_fn = freeRestoredTrackedText,
        };
    }

    fn copyRestoredTaskText(
        context: *anyopaque,
        value: []const u8,
        max: usize,
    ) task_persistence.ProjectionError![]u8 {
        const self: *Workbench = @ptrCast(@alignCast(context));
        return self.copyBounded(value, max) catch |err| return @errorCast(err);
    }

    fn allocRestoredTaskText(
        context: *anyopaque,
        capacity: usize,
    ) task_persistence.ProjectionError![]u8 {
        const self: *Workbench = @ptrCast(@alignCast(context));
        return self.allocTrackedCapacity(capacity) catch |err| return @errorCast(err);
    }

    fn appendRestoredTaskText(
        context: *anyopaque,
        target: *TrackedText,
        suffix: []const u8,
        max: usize,
    ) task_persistence.ProjectionError!void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        self.appendTrackedText(target, suffix, max) catch |err|
            return @errorCast(err);
    }

    fn freeRestoredTaskText(context: *anyopaque, value: []u8) void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        self.freeTracked(value);
    }

    fn freeRestoredTrackedText(context: *anyopaque, target: *TrackedText) void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        self.freeTrackedText(target);
    }

    fn restoreTaskState(self: *Workbench, bytes: []const u8) Error!void {
        std.debug.assert(countPresent(WorkspaceView, self.workspaces) == 0);
        std.debug.assert(countPresent(TaskView, self.tasks) == 0);
        var recovered = try task_persistence.decodeRecovering(
            self.allocator,
            bytes,
            self.taskPersistenceLimits(),
        );
        defer recovered.deinit();
        for (recovered.value.failures) |failure|
            try self.recordTaskFailure(failure.task_id, failure.recent_order, failure.reason);
        var restored_workspace_count: usize = 0;
        for (recovered.value.workspaces) |workspace| {
            const restored = self.restoreWorkspace(workspace) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    recovered.dropped_workspaces += 1;
                    continue;
                },
            };
            self.workspaces[restored_workspace_count] = restored;
            restored_workspace_count += 1;
        }
        var restored_task_count: usize = 0;
        for (recovered.value.tasks) |task| {
            const restored = task_persistence.restoreTask(
                self.taskRestoreProjection(),
                task,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    recovered.dropped_tasks += 1;
                    try self.recordTaskFailure(task.id, task.recent_order, "task_restore");
                    continue;
                },
            };
            self.tasks[restored_task_count] = restored;
            if (self.findWorkspace(task.workspace_id)) |workspace| {
                if (workspace.kind == .automatic) workspace.automatic_task_id = task.id;
            }
            restored_task_count += 1;
        }
        for (self.workspaces) |*entry| {
            const workspace = &(entry.* orelse continue);
            if (workspace.kind != .automatic) continue;
            var owned_task_count: usize = 0;
            for (self.tasks) |task_entry| {
                if (task_entry) |task| {
                    if (task.durable.workspace_id == workspace.id) {
                        owned_task_count += 1;
                    }
                }
            }
            if (owned_task_count == 1) continue;
            self.deinitWorkspaceView(workspace);
            entry.* = null;
            recovered.dropped_workspaces += 1;
        }
        self.next_workspace_id = recovered.value.next_workspace_id;
        self.next_workspace_recent_order = recovered.value.next_workspace_recent_order;
        self.next_task_id = recovered.value.next_task_id;
        self.next_task_recent_order = recovered.value.next_task_recent_order;
        if (recovered.degraded or recovered.dropped_workspaces != 0 or recovered.dropped_tasks != 0)
            self.task_persistence_health = .degraded;
    }

    fn recordTaskFailure(
        self: *Workbench,
        task_id: u64,
        recent_order: u64,
        reason: []const u8,
    ) Error!void {
        if (task_id == 0 or reason.len == 0 or reason.len > task_persistence.max_failure_reason_bytes)
            return error.TaskStoreCorrupt;
        for (self.task_failures.items) |failure|
            if (failure.task_id == task_id and std.mem.eql(u8, failure.reason, reason)) return;
        const owned_reason = try self.allocator.dupe(u8, reason);
        errdefer self.allocator.free(owned_reason);
        try self.task_failures.append(self.allocator, .{
            .task_id = task_id,
            .recent_order = recent_order,
            .reason = owned_reason,
        });
    }

    fn restoreWorkspace(
        self: *Workbench,
        wire: task_persistence.WorkspaceWire,
    ) Error!WorkspaceView {
        const canonical_root = try self.copyBounded(
            wire.canonical_root,
            self.limits.max_workspace_bytes,
        );
        errdefer self.freeTracked(canonical_root);
        const projected_root = try self.copyBounded(
            wire.canonical_root,
            self.limits.max_workspace_bytes,
        );
        errdefer self.freeTracked(projected_root);
        const display_name = try self.copyBounded(
            wire.display_name,
            self.limits.max_workspace_bytes,
        );
        errdefer self.freeTracked(display_name);
        const trust_root = try self.copyBounded(
            wire.canonical_root,
            self.limits.max_workspace_bytes,
        );
        errdefer self.freeTracked(trust_root);
        const kind = task_persistence.parseEnum(WorkspaceKind, wire.kind) orelse
            return error.InvalidWorkspace;
        return .{
            .id = wire.id,
            .kind = kind,
            .epoch = wire.epoch,
            .canonical_root = canonical_root,
            .projected_root_storage = projected_root,
            .projected_root_len = projected_root.len,
            .display_name_storage = display_name,
            .display_name_len = display_name.len,
            .trust = .{ .temporary = trust_root },
            .authorization = if (kind == .automatic) .available else .reauthorization_required,
            .visible = wire.visible,
            .recent_order = wire.recent_order,
        };
    }

    fn reconcileCheckpointStoreNoFail(self: *Workbench) void {
        if (self.task_persistence_health != .ready or
            self.checkpoint_store_health.load(.acquire) != .ready)
            return;
        const store = self.checkpoint_store orelse return;
        for (self.tasks) |*entry| {
            const task = &(entry.* orelse continue);
            const record = task.durable.checkpoint orelse continue;
            store.verify(record.blob) catch |err| {
                const health: CheckpointAnchor = switch (err) {
                    error.BlobMissing => .blob_missing,
                    error.BlobMismatch => .blob_mismatch,
                    else => {
                        self.checkpoint_store_health.store(.unavailable, .release);
                        return;
                    },
                };
                var removed = task.durable.checkpoint.?;
                const previous_anchor = task.durable.checkpoint_anchor;
                task.durable.checkpoint = null;
                task.durable.checkpoint_anchor = health;
                self.commitTaskState() catch {
                    task.durable.checkpoint = removed;
                    task.durable.checkpoint_anchor = previous_anchor;
                    return;
                };
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
            self.checkpoint_store_health.store(.unavailable, .release);
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
            self.checkpoint_store_health.store(
                if (err == error.PersistenceOutcomeUnknown)
                    .outcome_unknown
                else
                    .unavailable,
                .release,
            );
        };
    }

    fn clearRestoredTaskStateNoFail(self: *Workbench) void {
        for (self.tasks) |*entry| {
            const task = &(entry.* orelse continue);
            self.deinitTaskView(task);
            entry.* = null;
        }
        for (self.workspaces) |*entry| {
            const workspace = &(entry.* orelse continue);
            self.deinitWorkspaceView(workspace);
            entry.* = null;
        }
        self.next_workspace_id = 1;
        self.next_workspace_recent_order = 1;
        self.next_task_id = 1;
        self.next_task_recent_order = 1;
    }

    const CheckpointPersistenceOverride = task_persistence.CheckpointPersistenceOverride;

    fn buildTaskStateWire(self: *Workbench) Error!task_persistence.TaskStateWireScratch {
        return self.buildTaskStateWireWithCheckpoint(null);
    }

    fn buildTaskStateWireWithCheckpoint(
        self: *Workbench,
        checkpoint_override: ?CheckpointPersistenceOverride,
    ) Error!task_persistence.TaskStateWireScratch {
        const workspace_count = countPresent(WorkspaceView, self.workspaces);
        const task_count = countPresent(TaskView, self.tasks);
        const workspaces = try self.allocator.alloc(
            task_persistence.WorkspaceWire,
            workspace_count,
        );
        errdefer self.allocator.free(workspaces);
        var workspace_index: usize = 0;
        for (self.workspaces) |entry| {
            const workspace = entry orelse continue;
            workspaces[workspace_index] = .{
                .id = workspace.id,
                .epoch = workspace.epoch,
                .kind = @tagName(workspace.kind),
                .canonical_root = workspace.canonical_root,
                .display_name = workspace.display_name_storage[0..workspace.display_name_len],
                .visible = workspace.visible,
                .recent_order = workspace.recent_order,
            };
            workspace_index += 1;
        }

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
            self.task_failures.items.len,
        );
        errdefer self.allocator.free(failures);
        for (self.task_failures.items, failures) |failure, *target| target.* = .{
            .task_id = failure.task_id,
            .recent_order = failure.recent_order,
            .reason = failure.reason,
        };
        return .{
            .allocator = self.allocator,
            .allocated_workspaces = workspaces,
            .allocated_tasks = tasks,
            .allocated_failures = failures,
            .state = .{
                .next_workspace_id = self.next_workspace_id,
                .next_workspace_recent_order = self.next_workspace_recent_order,
                .next_task_id = self.next_task_id,
                .next_task_recent_order = self.next_task_recent_order,
                .workspaces = workspaces[0..workspace_index],
                .tasks = tasks[0..task_index],
                .failures = failures,
            },
        };
    }

    fn requireTaskPersistenceMutation(self: *const Workbench) Error!void {
        return switch (self.task_persistence_health) {
            .ready => {},
            .degraded => {},
            // Unit-level Workbench users may deliberately omit persistence.
            // Production startup converts every store initialization/read
            // failure into a typed non-ready health instead.
            .unavailable => if (self.task_persistence.restore_failed)
                error.TaskPersistenceUnavailable
            else {},
            .outcome_unknown => error.TaskPersistenceOutcomeUnknown,
            .read_failed, .corrupt, .write_failed => error.TaskPersistenceUnavailable,
        };
    }

    fn commitTaskStateIfConfigured(self: *Workbench) Error!void {
        if (self.task_persistence_health == .unavailable and
            !self.task_persistence.enabled and
            !self.task_persistence.restore_failed)
            return;
        return self.commitTaskState();
    }

    fn commitTaskStateNoFail(self: *Workbench) void {
        self.commitTaskStateIfConfigured() catch |err| switch (err) {
            error.TaskPersistenceOutcomeUnknown,
            error.TaskPersistenceUnavailable,
            error.TaskPersistenceFailed,
            => {},
            else => {
                if (self.task_persistence_health.operational()) {
                    self.task_persistence_health = .write_failed;
                    self.bumpRevision();
                }
            },
        };
    }

    fn markTaskPersistenceWriteFailed(self: *Workbench) void {
        if (self.task_persistence_health == .write_failed) return;
        self.task_persistence_health = .write_failed;
        self.bumpRevision();
    }

    fn commitTaskState(self: *Workbench) Error!void {
        return self.commitTaskStateWithCheckpoint(null);
    }

    fn commitTaskStateWithCheckpoint(
        self: *Workbench,
        checkpoint_override: ?CheckpointPersistenceOverride,
    ) Error!void {
        switch (self.task_persistence_health) {
            .ready => {},
            .degraded => {},
            .outcome_unknown => return error.TaskPersistenceOutcomeUnknown,
            .read_failed, .corrupt, .write_failed => return error.TaskPersistenceUnavailable,
            .unavailable => return error.TaskPersistenceUnavailable,
        }
        var scratch = self.buildTaskStateWireWithCheckpoint(checkpoint_override) catch {
            self.markTaskPersistenceWriteFailed();
            return error.TaskPersistenceFailed;
        };
        defer scratch.deinit();
        const output = self.allocator.alloc(u8, task_persistence.max_store_bytes) catch {
            self.markTaskPersistenceWriteFailed();
            return error.TaskPersistenceFailed;
        };
        defer self.allocator.free(output);
        const bytes = task_persistence.encode(output, scratch.state) catch {
            self.markTaskPersistenceWriteFailed();
            return error.TaskPersistenceFailed;
        };
        if (self.containsKnownCredential(bytes)) {
            self.markTaskPersistenceWriteFailed();
            return error.TaskPersistenceFailed;
        }
        switch (self.task_persistence.commit(bytes)) {
            .committed => {},
            .failed => {
                self.markTaskPersistenceWriteFailed();
                return error.TaskPersistenceFailed;
            },
            .outcome_unknown => {
                self.task_persistence_health = .outcome_unknown;
                self.bumpRevision();
                return error.TaskPersistenceOutcomeUnknown;
            },
        }
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

    /// Product projections may contain a credential that became known only
    /// after those facts were recorded. Every Task-owned secret release must
    /// pass through this function so the final live copy scrubs all retained
    /// projections before secure-zero makes the credential unavailable.
    fn releaseExecutionValueNoFail(
        self: *Workbench,
        task: *TaskView,
        execution: *OwnedTaskExecution,
    ) void {
        const credential = execution.input().api_key;
        self.redactAllProductProjectionsNoFail(credential);
        for (task.durable.runs) |*run_entry| {
            const run = &(run_entry.* orelse continue);
            run.redaction_secret = &.{};
        }
        for (task.durable.compacts) |*compact_entry| {
            const compact = &(compact_entry.* orelse continue);
            compact.redaction_secret = &.{};
        }
        execution.deinit();
    }

    fn upsertWorkspace(
        self: *Workbench,
        input: TaskCreateInput,
    ) Error!WorkspaceUpsert {
        if (!std.fs.path.isAbsolute(input.workspace_root))
            return error.InvalidWorkspace;
        const canonical = std.Io.Dir.realPathFileAbsoluteAlloc(
            self.io,
            input.workspace_root,
            self.allocator,
        ) catch return error.InvalidWorkspace;
        defer self.allocator.free(canonical);
        if (canonical.len > self.limits.max_workspace_bytes)
            return error.ProjectionCapacity;
        const workspace_stat = std.Io.Dir.cwd().statFile(
            self.io,
            canonical,
            .{},
        ) catch return error.InvalidWorkspace;
        if (workspace_stat.kind != .directory) return error.InvalidWorkspace;
        if (self.automatic_workspaces) |*store|
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
                    self.io,
                    root,
                    self.allocator,
                ) catch return error.InvalidWorkspace;
                canonical_temporary = temporary;
                if (temporary.len > self.limits.max_workspace_bytes)
                    return error.ProjectionCapacity;
                const root_stat = std.Io.Dir.cwd().statFile(
                    self.io,
                    temporary,
                    .{},
                ) catch return error.InvalidWorkspace;
                if (root_stat.kind != .directory) return error.InvalidWorkspace;
                if (!workspacePathWithin(temporary, canonical))
                    return error.WorkspaceNotTrusted;
            },
        }

        if (self.findWorkspaceIndexByRoot(canonical)) |index| {
            const workspace = &self.workspaces[index].?;
            if (workspace.authorization == .removing)
                return error.WorkspaceRemovalInProgress;
            const reauthorizing = !workspace.visible or
                workspace.authorization == .reauthorization_required;
            // Startup deliberately forgets the Host authority while retaining
            // the durable Workspace identity. Confirming that same visible
            // Workspace restores authority without changing its epoch. A
            // hidden Workspace was explicitly removed; reopening it creates a
            // new authority epoch so old Task bindings remain invalid.
            const reopening_removed_workspace = !workspace.visible;
            if (reopening_removed_workspace and workspace.epoch == std.math.maxInt(u64))
                return error.WorkspaceEpochExhausted;
            const next_temporary = if (canonical_temporary) |root|
                try self.copyBounded(root, self.limits.max_workspace_bytes)
            else
                null;
            const previous = ExistingWorkspaceState{
                .trust = workspace.trust,
                .authorization = workspace.authorization,
                .visible = workspace.visible,
                .epoch = workspace.epoch,
                .recent_order = workspace.recent_order,
            };
            workspace.trust = if (next_temporary) |root|
                .{ .temporary = root }
            else
                .explicitly_trusted;
            workspace.authorization = .available;
            workspace.visible = true;
            if (reopening_removed_workspace) workspace.epoch += 1;
            return .{
                .index = index,
                .reauthorizing = reauthorizing,
                .previous = .{ .existing = previous },
            };
        }

        var slot: ?usize = null;
        var replaced: ?WorkspaceView = null;
        for (self.workspaces, 0..) |*entry, index| {
            const workspace = &(entry.* orelse continue);
            if (workspace.kind != .manual or workspace.visible or
                workspace.catalog_job != null or
                self.workspaceHasTasks(workspace.id))
                continue;
            replaced = workspace.*;
            entry.* = null;
            slot = index;
            break;
        }
        var restore_replaced = true;
        errdefer if (restore_replaced) {
            if (slot) |index| self.workspaces[index] = replaced;
        };
        if (slot == null and self.workspaceCount(.manual) >= self.limits.max_workspaces)
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

        const previous_next_workspace_id = self.next_workspace_id;
        const workspace_id = previous_next_workspace_id;
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
        restore_replaced = false;
        return .{
            .index = target,
            .previous = .{ .created = .{
                .next_workspace_id = previous_next_workspace_id,
                .replaced = replaced,
            } },
        };
    }

    fn rollbackWorkspaceUpsert(
        self: *Workbench,
        upsert: WorkspaceUpsert,
    ) void {
        switch (upsert.previous) {
            .existing => |previous| {
                const workspace = &self.workspaces[upsert.index].?;
                if (workspace.trust == .temporary)
                    self.freeTracked(workspace.trust.temporary);
                workspace.trust = previous.trust;
                workspace.authorization = previous.authorization;
                workspace.visible = previous.visible;
                workspace.epoch = previous.epoch;
                workspace.recent_order = previous.recent_order;
            },
            .created => |previous| {
                var workspace = self.workspaces[upsert.index].?;
                self.workspaces[upsert.index] = null;
                self.deinitWorkspaceView(&workspace);
                self.workspaces[upsert.index] = previous.replaced;
                self.next_workspace_id = previous.next_workspace_id;
            },
        }
    }

    fn finishWorkspaceUpsert(
        self: *Workbench,
        upsert: WorkspaceUpsert,
    ) void {
        switch (upsert.previous) {
            .existing => |previous| {
                if (previous.trust == .temporary)
                    self.freeTracked(previous.trust.temporary);
            },
            .created => |previous| if (previous.replaced) |replaced_value| {
                var replaced = replaced_value;
                self.deinitWorkspaceView(&replaced);
            },
        }
        const workspace = &self.workspaces[upsert.index].?;
        if (upsert.reauthorizing) {
            self.markWorkspaceCatalogUnavailable(workspace);
            workspace.catalog_slot = .uninitialized;
            workspace.catalog_reschedule_pending = workspace.catalog_job != null;
        }
        self.redactWorkspaceProjectionNoFail(
            workspace,
            self.execution.credential(),
        );
    }

    fn registerAutomaticWorkspace(
        self: *Workbench,
        canonical_root: []const u8,
    ) Error!*WorkspaceView {
        const store = if (self.automatic_workspaces) |*value| value else return error.WorkspaceUnavailable;
        if (!std.fs.path.isAbsolute(canonical_root) or
            canonical_root.len > self.limits.max_workspace_bytes or
            !std.unicode.utf8ValidateSlice(canonical_root) or
            !store.containsCanonicalPath(canonical_root) or
            self.findWorkspaceByRoot(canonical_root) != null)
            return error.InvalidWorkspace;
        if (self.workspaceCount(.automatic) >= self.limits.max_tasks)
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
            "Automatic workspace",
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
            .kind = .automatic,
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

    fn releaseAutomaticWorkspaceNoFail(
        self: *Workbench,
        workspace_id: u64,
    ) void {
        for (self.workspaces) |*entry| {
            const workspace = &(entry.* orelse continue);
            if (workspace.id != workspace_id) continue;
            std.debug.assert(workspace.kind == .automatic);
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
        task.durable.recent_order = self.takeTaskRecentOrder();
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

    fn findWorkspaceIndexByRoot(
        self: *const Workbench,
        canonical_root: []const u8,
    ) ?usize {
        for (self.workspaces, 0..) |entry, index| if (entry) |workspace|
            if (std.mem.eql(u8, workspace.canonical_root, canonical_root)) return index;
        return null;
    }

    fn workspaceCount(self: *const Workbench, kind: WorkspaceKind) usize {
        var count: usize = 0;
        for (self.workspaces) |entry| if (entry) |workspace|
            if (workspace.kind == kind) {
                count += 1;
            };
        return count;
    }

    fn scheduleCatalogQuery(
        self: *Workbench,
        workspace: *WorkspaceView,
    ) Error!void {
        if (workspace.kind != .manual) return error.CatalogUnavailable;
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
            .identity = job,
            .context = job,
            .execute_fn = executeCatalogJob,
            .cancel_fn = cancelCatalogJob,
        });
        workspace.catalog_request_generation = generation;
        workspace.catalog_job = job;
        workspace.catalog_reschedule_pending = false;
    }

    fn requireSkillMutationAvailable(
        self: *Workbench,
        scope: skill_management_impl.Scope,
    ) Error!void {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        self.syncLifecycle();
        if (self.skill_management_health != .ready or
            self.skill_transactions == null)
            return error.PersistenceFailed;
        if (self.skill_reconciliation != null) return error.TaskBusy;
        switch (scope) {
            .personal => {
                if (self.skill_catalog_job != null) return error.CatalogLoading;
                for (self.tasks) |*entry| {
                    const task = &(entry.* orelse continue);
                    if (hasActiveOperation(task)) return error.TaskBusy;
                }
            },
            .project => |project| {
                const workspace = self.findWorkspace(project.workspace_id) orelse
                    return error.UnknownWorkspace;
                if (workspace.epoch != project.workspace_epoch)
                    return error.WorkspaceEpochMismatch;
                if (workspace.kind != .manual or !workspace.visible or
                    workspace.authorization != .available)
                    return error.WorkspaceUnavailable;
                if (workspace.catalog_job != null) return error.CatalogLoading;
                for (self.tasks) |*entry| {
                    const task = &(entry.* orelse continue);
                    if (task.durable.workspace_id == project.workspace_id and
                        hasActiveOperation(task))
                        return error.TaskBusy;
                }
            },
        }
    }

    fn openSkillRoot(
        self: *Workbench,
        scope: skill_management_impl.Scope,
    ) Error!skill_management_impl.CanonicalRoot {
        const base = switch (scope) {
            .personal => self.canonical_user_home orelse
                return error.WorkspaceUnavailable,
            .project => |project| project_root: {
                const workspace = self.findWorkspace(project.workspace_id) orelse
                    return error.UnknownWorkspace;
                if (workspace.epoch != project.workspace_epoch)
                    return error.WorkspaceEpochMismatch;
                if (workspace.kind != .manual or !workspace.visible or
                    workspace.authorization != .available)
                    return error.WorkspaceUnavailable;
                break :project_root workspace.canonical_root;
            },
        };
        const root_path = try std.fs.path.join(
            self.allocator,
            &.{ base, ".agents", "skills" },
        );
        defer self.allocator.free(root_path);
        return skill_management_impl.CanonicalRoot.open(
            self.io,
            self.allocator,
            scope,
            root_path,
        );
    }

    fn scheduleSkillReconciliation(
        self: *Workbench,
        scope: skill_management_impl.Scope,
    ) Error!void {
        switch (scope) {
            .personal => try self.scheduleSkillCatalogQuery(),
            .project => |project| {
                const workspace = self.findWorkspace(project.workspace_id) orelse
                    return error.UnknownWorkspace;
                if (workspace.epoch != project.workspace_epoch)
                    return error.WorkspaceEpochMismatch;
                try self.scheduleCatalogQuery(workspace);
            },
        }
    }

    fn noteSkillPersistenceFailure(self: *Workbench, err: anyerror) void {
        self.skill_management_health = switch (err) {
            error.PersistenceOutcomeUnknown => .outcome_unknown,
            else => .write_failed,
        };
    }

    fn noteSkillEnablementPersistenceFailure(self: *Workbench, err: anyerror) void {
        self.skill_enablement_health = switch (err) {
            error.PersistenceOutcomeUnknown => .outcome_unknown,
            else => .write_failed,
        };
        if (err == error.PersistenceOutcomeUnknown) {
            self.markSkillCatalogUnavailable();
            for (self.workspaces) |*entry| {
                const workspace = &(entry.* orelse continue);
                if (workspace.kind == .manual)
                    self.markWorkspaceCatalogUnavailable(workspace);
            }
        }
    }

    fn commitSkillEnablementCandidate(
        self: *Workbench,
        candidate: *skill_enablement_impl.Store,
    ) Error!void {
        const file_store = self.skill_enablement_file_store orelse
            return error.PersistenceFailed;
        const output = try self.allocator.alloc(u8, skill_enablement_impl.max_store_bytes);
        defer self.allocator.free(output);
        const bytes = try skill_enablement_impl.encode(output, candidate);
        try file_store.commit(bytes);
        self.skill_enablement.deinit();
        self.skill_enablement = candidate.*;
        candidate.* = undefined;
    }

    fn reconcileSkillEnablementNoFail(self: *Workbench) void {
        if (self.skill_enablement_health != .ready or
            self.skill_enablement_file_store == null)
            return;
        var active: std.ArrayList(skill_enablement_impl.WorkspaceIdentity) = .empty;
        defer active.deinit(self.allocator);
        for (self.workspaces) |entry| if (entry) |workspace| {
            if (workspace.kind == .manual and workspace.visible)
                active.append(self.allocator, .{
                    .workspace_id = workspace.id,
                    .workspace_epoch = workspace.epoch,
                }) catch {
                    self.skill_enablement_health = .write_failed;
                    return;
                };
        };
        var candidate = self.skill_enablement.clone() catch {
            self.skill_enablement_health = .write_failed;
            return;
        };
        var candidate_owned = true;
        defer if (candidate_owned) candidate.deinit();
        if (!candidate.reconcile(active.items)) return;
        self.commitSkillEnablementCandidate(&candidate) catch |err| {
            self.noteSkillEnablementPersistenceFailure(err);
            return;
        };
        candidate_owned = false;
    }

    fn compileCatalogSnapshot(
        self: *Workbench,
        source: lifecycle.CatalogProjection,
        scope: skill_management_impl.Scope,
        available_projection_bytes: usize,
    ) Error!CatalogSnapshot {
        if (self.skill_enablement_health != .ready)
            return error.PersistenceFailed;
        var disabled_skill_policy_keys: std.ArrayList([]const u8) = .empty;
        defer disabled_skill_policy_keys.deinit(self.allocator);
        const selection_revision = switch (scope) {
            .personal => self.skill_enablement.userRevision(),
            .project => |project| self.skill_enablement.revision(.{
                .workspace_id = project.workspace_id,
                .workspace_epoch = project.workspace_epoch,
            }),
        };
        for (source.skills) |skill| {
            const enabled = switch (scope) {
                .personal => self.skill_enablement.isUserEnabled(
                    skill.skill_policy_key,
                ),
                .project => |project| self.skill_enablement.isEnabled(.{
                    .workspace_id = project.workspace_id,
                    .workspace_epoch = project.workspace_epoch,
                }, skill.skill_policy_key),
            };
            if (!enabled) try disabled_skill_policy_keys.append(
                self.allocator,
                skill.skill_policy_key,
            );
        }
        return CatalogSnapshot.init(
            self.allocator,
            source,
            selection_revision,
            disabled_skill_policy_keys.items,
            catalogSnapshotLimits(self.limits),
            available_projection_bytes,
        ) catch |err| switch (err) {
            error.InvalidSelectionRevision => unreachable,
            else => |other| return other,
        };
    }

    fn recompileCatalogSnapshot(
        self: *Workbench,
        snapshot: *const CatalogSnapshot,
        store: *const skill_enablement_impl.Store,
        scope: skill_management_impl.Scope,
    ) Error!CatalogSnapshot {
        var disabled_skill_policy_keys: std.ArrayList([]const u8) = .empty;
        defer disabled_skill_policy_keys.deinit(self.allocator);
        const selection_revision = switch (scope) {
            .personal => store.userRevision(),
            .project => |project| store.revision(.{
                .workspace_id = project.workspace_id,
                .workspace_epoch = project.workspace_epoch,
            }),
        };
        for (snapshot.skills) |skill| {
            const enabled = switch (scope) {
                .personal => store.isUserEnabled(skill.skill_policy_key),
                .project => |project| store.isEnabled(.{
                    .workspace_id = project.workspace_id,
                    .workspace_epoch = project.workspace_epoch,
                }, skill.skill_policy_key),
            };
            if (!enabled) try disabled_skill_policy_keys.append(
                self.allocator,
                skill.skill_policy_key,
            );
        }
        return snapshot.recompile(
            self.allocator,
            selection_revision,
            disabled_skill_policy_keys.items,
            catalogSnapshotLimits(self.limits),
            snapshot.projected_bytes,
        ) catch |err| switch (err) {
            error.InvalidSelectionRevision => unreachable,
            else => |other| return other,
        };
    }

    fn recoverSkillTransactionsForScopeNoFail(
        self: *Workbench,
        scope: skill_management_impl.Scope,
    ) void {
        if (self.skill_management_health != .ready or
            self.skill_transactions == null)
            return;
        var pending: std.ArrayList(skill_management_impl.InstallId) = .empty;
        defer pending.deinit(self.allocator);
        for (self.skillInventory().items()) |asset| {
            if (asset.scope.eql(scope) and asset.recovery != null)
                pending.append(self.allocator, asset.install_id) catch {
                    self.skill_management_health = .write_failed;
                    return;
                };
        }
        if (pending.items.len == 0) return;
        var root = self.openSkillRoot(scope) catch {
            self.skill_management_health = .read_failed;
            return;
        };
        defer root.deinit();
        const now = self.schedule_timer.now() orelse {
            self.skill_management_health = .read_failed;
            return;
        };
        const transactions = &self.skill_transactions.?;
        for (pending.items) |install_id|
            transactions.recover(&root, install_id, now) catch |err| {
                self.noteSkillPersistenceFailure(err);
                return;
            };
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
            .identity = job,
            .context = job,
            .execute_fn = executeCatalogJob,
            .cancel_fn = cancelCatalogJob,
        });
        self.skill_catalog_request_generation = generation;
        self.skill_catalog_job = job;
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
                                const snapshot = self.compileCatalogSnapshot(
                                    acquisition.projection,
                                    .personal,
                                    self.availableCatalogReplacementBytes(
                                        &self.skill_catalog_slot,
                                    ),
                                ) catch {
                                    acquisition.projection.deinit();
                                    self.agent_runtime.releaseSkillCatalog(
                                        acquisition.lease,
                                    ) catch
                                        @panic("Agent rejected the MetaWork Skill catalog lease");
                                    if (self.skill_catalog_slot.snapshotConst() == null)
                                        self.skill_catalog_slot = .unavailable;
                                    self.reconcileSkillCatalogResultNoFail(.personal, null);
                                    job.deinit();
                                    return true;
                                };
                                acquisition.projection.deinit();
                                var old_slot = self.skill_catalog_slot;
                                if (old_slot.snapshotConst()) |old|
                                    self.projection_bytes -= old.projected_bytes;
                                self.projection_bytes += snapshot.projected_bytes;
                                self.skill_catalog_slot = .{ .committed = .{
                                    .lease = .init(acquisition.lease),
                                    .snapshot = snapshot,
                                } };
                                self.reconcileSkillCatalogResultNoFail(
                                    .personal,
                                    self.skill_catalog_slot.snapshotConst(),
                                );
                                if (old_slot == .committed)
                                    old_slot.committed.deinit(self.agent_runtime);
                            } else {
                                acquisition.projection.deinit();
                                self.agent_runtime.releaseSkillCatalog(
                                    acquisition.lease,
                                ) catch
                                    @panic("Agent rejected a stale MetaWork Skill catalog lease");
                            }
                        },
                        .failure => {
                            if (still_current) {
                                if (self.skill_catalog_slot.snapshotConst() == null)
                                    self.skill_catalog_slot = .unavailable;
                                self.reconcileSkillCatalogResultNoFail(
                                    .personal,
                                    null,
                                );
                            }
                        },
                    },
                    .cancelled => {
                        if (still_current) {
                            if (self.skill_catalog_slot.snapshotConst() == null)
                                self.skill_catalog_slot = .unavailable;
                            self.reconcileSkillCatalogResultNoFail(
                                .personal,
                                null,
                            );
                        }
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
                            const snapshot = self.compileCatalogSnapshot(
                                acquisition.projection,
                                .{ .project = .{
                                    .workspace_id = workspace.id,
                                    .workspace_epoch = workspace.epoch,
                                } },
                                self.availableCatalogReplacementBytes(
                                    &workspace.catalog_slot,
                                ),
                            ) catch {
                                acquisition.projection.deinit();
                                self.agent_runtime.releaseSkillCatalog(
                                    acquisition.lease,
                                ) catch
                                    @panic("Agent rejected a Workbench-owned catalog lease");
                                if (workspace.catalog_slot.snapshotConst() == null)
                                    workspace.catalog_slot = .unavailable;
                                self.reconcileSkillCatalogResultNoFail(
                                    .{ .project = .{
                                        .workspace_id = workspace.id,
                                        .workspace_epoch = workspace.epoch,
                                    } },
                                    null,
                                );
                                job.deinit();
                                changed = true;
                                continue;
                            };
                            acquisition.projection.deinit();
                            var old_slot = workspace.catalog_slot;
                            if (old_slot.snapshotConst()) |old|
                                self.projection_bytes -= old.projected_bytes;
                            self.projection_bytes += snapshot.projected_bytes;
                            workspace.catalog_slot = .{ .committed = .{
                                .lease = .init(acquisition.lease),
                                .snapshot = snapshot,
                            } };
                            self.reconcileSkillCatalogResultNoFail(
                                .{ .project = .{
                                    .workspace_id = workspace.id,
                                    .workspace_epoch = workspace.epoch,
                                } },
                                workspace.catalog_slot.snapshotConst(),
                            );
                            if (old_slot == .committed)
                                old_slot.committed.deinit(self.agent_runtime);
                        } else {
                            acquisition.projection.deinit();
                            self.agent_runtime.releaseSkillCatalog(
                                acquisition.lease,
                            ) catch
                                @panic("Agent rejected a stale Workbench catalog lease");
                        }
                    },
                    .failure => {
                        if (still_current) {
                            if (workspace.catalog_slot.snapshotConst() == null)
                                workspace.catalog_slot = .unavailable;
                            self.reconcileSkillCatalogResultNoFail(
                                .{ .project = .{
                                    .workspace_id = workspace.id,
                                    .workspace_epoch = workspace.epoch,
                                } },
                                null,
                            );
                        }
                    },
                },
                .cancelled => {
                    if (current == workspace and
                        workspace.catalog_slot.snapshotConst() == null)
                        workspace.catalog_slot = .unavailable;
                },
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

    fn commitMcpRefreshJobNoFail(self: *Workbench) bool {
        const mcp = if (self.mcp) |*value| value else return false;
        const job = self.mcp_refresh_job orelse return false;
        const state = job.state.load(.acquire);
        if (state == .queued or state == .running) return false;
        self.mcp_refresh_job = null;
        const still_current = !self.shutting_down and
            mcp.refresh_request_generation == job.request_generation;
        switch (state) {
            .completed => switch (job.outcome) {
                .activated => |activated| {
                    if (still_current) {
                        if (mcp.activation) |old| old.deinit();
                        mcp.activation = activated.activation;
                        mcp.activation_failed = false;
                        mcp.refresh_deadline_ms = mcpRefreshDeadlineMs(
                            activated.activation.catalogServers(),
                            job.requested_at_ms,
                        );
                        if (job.build_admission) {
                            mcp_policy.replaceAdmission(mcp, .{ .ready = .{
                                .selection = activated.selection,
                                .catalog_generation = activated.activation.catalogGeneration(),
                            } });
                        } else {
                            mcp_policy.blockAdmissionForCurrentState(mcp);
                        }
                        job.outcome = .empty;
                    }
                },
                .empty => if (still_current) {
                    if (mcp.activation) |old| old.deinit();
                    mcp.activation = null;
                    mcp.activation_failed = false;
                    mcp.refresh_deadline_ms = null;
                    if (job.build_admission)
                        mcp_policy.replaceAdmission(mcp, .{ .ready = .{
                            .selection = null,
                            .catalog_generation = null,
                        } })
                    else
                        mcp_policy.blockAdmissionForCurrentState(mcp);
                },
                .unavailable => if (still_current) {
                    if (mcp.activation) |old| old.deinit();
                    mcp.activation = null;
                    mcp.activation_failed = true;
                    mcp.refresh_deadline_ms = null;
                    mcp_policy.blockAdmission(mcp, .activation_unavailable);
                },
            },
            .cancelled => {},
            .queued, .running => unreachable,
        }
        job.deinit();
        self.rearmMcpRefreshTimerNoFail();
        return true;
    }

    fn reconcileSkillCatalogResultNoFail(
        self: *Workbench,
        scope: skill_management_impl.Scope,
        catalog: ?*const CatalogSnapshot,
    ) void {
        const reconciliation = self.skill_reconciliation orelse return;
        if (!reconciliation.scope.eql(scope)) return;
        self.skill_reconciliation = null;
        const snapshot = catalog orelse return;
        var found = false;
        for (snapshot.skills) |skill| {
            if (std.mem.eql(
                u8,
                skill.invocation_name,
                reconciliation.invocationName(),
            )) {
                found = true;
                break;
            }
        }
        var has_matching_issue = false;
        for (snapshot.issues) |issue| {
            const issue_name = issue.skill_policy_key orelse continue;
            if (std.mem.eql(
                u8,
                issue_name,
                reconciliation.invocationName(),
            )) {
                has_matching_issue = true;
                break;
            }
        }
        const accepted = !has_matching_issue and switch (reconciliation.operation) {
            .install, .replace => found,
            .uninstall => !found,
        };
        var root = self.openSkillRoot(scope) catch return;
        defer root.deinit();
        const transactions = if (self.skill_transactions) |*value| value else return;
        if (accepted) {
            const now = self.schedule_timer.now() orelse return;
            transactions.commitReconciliation(
                &root,
                reconciliation.install_id,
                null,
                now,
            ) catch |err| self.noteSkillPersistenceFailure(err);
        } else {
            transactions.rollbackReconciliation(
                &root,
                reconciliation.install_id,
            ) catch |err| self.noteSkillPersistenceFailure(err);
        }
    }

    fn availableCatalogReplacementBytes(
        self: *const Workbench,
        slot: *const CatalogSlot,
    ) usize {
        std.debug.assert(self.projection_bytes <= self.limits.max_projection_bytes);
        const available = self.limits.max_projection_bytes - self.projection_bytes;
        const reclaimable = if (slot.snapshotConst()) |snapshot|
            snapshot.projected_bytes
        else
            0;
        std.debug.assert(reclaimable <= self.projection_bytes);
        return available + reclaimable;
    }

    fn markSkillCatalogUnavailable(self: *Workbench) void {
        var old_slot = self.skill_catalog_slot;
        if (old_slot.snapshotConst()) |snapshot|
            self.projection_bytes -= snapshot.projected_bytes;
        self.skill_catalog_slot = .unavailable;
        if (old_slot == .committed)
            old_slot.committed.deinit(self.agent_runtime);
    }

    fn markWorkspaceCatalogUnavailable(
        self: *Workbench,
        workspace: *WorkspaceView,
    ) void {
        var old_slot = workspace.catalog_slot;
        if (old_slot.snapshotConst()) |snapshot|
            self.projection_bytes -= snapshot.projected_bytes;
        workspace.catalog_slot = .unavailable;
        if (old_slot == .committed)
            old_slot.committed.deinit(self.agent_runtime);
    }

    fn workspaceHasTasks(self: *const Workbench, workspace_id: u64) bool {
        for (self.tasks) |entry| if (entry) |task|
            if (task.durable.workspace_id == workspace_id) return true;
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
                if (task.durable.workspace_id != workspace.id) continue;
                if (task.runtime.close_failed) {
                    failed = true;
                    break;
                }
                if (task.runtime.hasAttachedSession() or
                    task.runtime.hasClosingSession() or
                    task.runtime.close_thread != null or
                    task.runtime.worker_references.load(.acquire) != 0 or
                    hasActiveOperation(task))
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
            changed = true;
        }
        return changed;
    }

    fn workspaceSignals(self: *const Workbench, workspace_id: u64) WorkspaceSignals {
        var signals: WorkspaceSignals = .{};
        for (self.tasks) |*entry| {
            const task = &(entry.* orelse continue);
            if (task.durable.workspace_id != workspace_id or task.durable.archived) continue;
            if (currentRunPhase(task)) |phase| {
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
            if (lastTerminalFacts(task.durable.runs)) |terminal| switch (terminal.outcome) {
                .failed, .interrupted, .dependency_contract_failure => signals.failed_or_interrupted +|= 1,
                .completed, .stopped, .cancelled => {},
            };
        }
        return signals;
    }

    fn deinitWorkspaceView(self: *Workbench, workspace: *WorkspaceView) void {
        std.debug.assert(workspace.catalog_job == null);
        std.debug.assert(!workspace.catalog_reschedule_pending);
        if (workspace.catalog_slot.snapshotConst()) |snapshot|
            self.projection_bytes -= snapshot.projected_bytes;
        if (workspace.catalog_slot == .committed)
            workspace.catalog_slot.committed.deinit(self.agent_runtime);
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
        item.input.redacted =
            redactFixedWidthNoFail(item.input.value, credential) or
            item.input.redacted;
    }

    fn redactCatalogProjectionsNoFail(
        self: *Workbench,
        credential: []const u8,
    ) void {
        if (self.skill_catalog_slot.snapshot()) |snapshot| {
            if (snapshot.identityContainsCredential(credential)) {
                self.markSkillCatalogUnavailable();
            } else {
                snapshot.redactPresentationNoFail(credential);
            }
        }
        for (self.workspaces) |*entry| {
            const workspace = &(entry.* orelse continue);
            const snapshot = workspace.catalog_slot.snapshot() orelse continue;
            if (snapshot.identityContainsCredential(credential)) {
                self.markWorkspaceCatalogUnavailable(workspace);
            } else {
                snapshot.redactPresentationNoFail(credential);
            }
        }
        for (self.tasks) |*entry| {
            const task = &(entry.* orelse continue);
            const snapshot = task.runtime.pinnedCatalog() orelse continue;
            if (snapshot.identityContainsCredential(credential)) {
                self.projection_bytes -= snapshot.projected_bytes;
                snapshot.deinit();
                task.runtime.live().?.pinned_catalog = null;
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
        task.durable.title_redacted = redactFixedWidthNoFail(task.durable.title, credential) or
            task.durable.title_redacted;
        _ = redactFixedWidthNoFail(task.durable.workspace_root, credential);
        _ = redactFixedWidthNoFail(task.durable.execution_model, credential);
        for (task.durable.runs) |*run_entry| {
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
        for (task.durable.ui_history) |*record_entry| {
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
            if (task.durable.id == task_id) return task;
        return null;
    }

    fn checkpointMutationPending(
        self: *const Workbench,
        task: *const TaskView,
    ) bool {
        return self.checkpoint_store_health.load(.acquire) != .unavailable and
            task.runtime.worker_references.load(.acquire) != 0;
    }

    fn findTaskByRouteId(self: *Workbench, route_id: u64) ?*TaskView {
        if (route_id == 0) return null;
        for (self.tasks) |*entry| if (entry.*) |*task|
            if (task.runtime.routeId() == route_id) return task;
        return null;
    }

    fn findTaskIndex(self: *Workbench, task_id: u64) ?usize {
        if (task_id == 0) return null;
        for (self.tasks, 0..) |entry, index|
            if (entry) |task| if (task.durable.id == task_id) return index;
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
                const pinned = task.runtime.pinnedCatalogConst() orelse
                    return error.CatalogUnavailable;
                if (!std.mem.eql(
                    u8,
                    skill_input.catalog_revision,
                    pinned.revision,
                ))
                    return error.StaleCatalog;
                if (skill_input.selection_revision != pinned.selection_revision)
                    return error.StaleCatalog;
                const skill = pinned.findSkill(skill_input.skill_id) orelse
                    return error.SkillNotFound;
                if (!skill.enabled) return error.SkillUnavailable;
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

    fn automaticTitleCandidate(input: *const RunInputRecord) ?[]const u8 {
        return switch (input.*) {
            .text => |text| firstAutomaticTitleLine(text.value),
            .skill => |skill| blk: {
                const display_name = std.mem.trim(u8, skill.display_name, " \t\r\n");
                if (display_name.len == 0 or !validAutomaticTitleText(display_name))
                    break :blk null;
                break :blk display_name;
            },
        };
    }

    fn automaticTitleCompletionInput(input: *const RunInputRecord) ?[]const u8 {
        const value = switch (input.*) {
            .text => |text| text.value,
            .skill => |skill| skill.display_name,
        };
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (trimmed.len == 0 or !std.unicode.utf8ValidateSlice(trimmed)) return null;
        return trimmed;
    }

    fn firstAutomaticTitleLine(value: []const u8) ?[]const u8 {
        if (value.len == 0 or !std.unicode.utf8ValidateSlice(value)) return null;
        var cursor: usize = 0;
        var in_fence = false;
        while (cursor < value.len) {
            const line_end = std.mem.indexOfScalarPos(u8, value, cursor, '\n') orelse value.len;
            var line = std.mem.trim(u8, value[cursor..line_end], " \t\r");
            const fence = std.mem.startsWith(u8, line, "```") or
                std.mem.startsWith(u8, line, "~~~");
            if (fence) {
                in_fence = !in_fence;
            } else if (!in_fence) {
                while (line.len != 0 and line[0] == '#')
                    line = std.mem.trim(u8, line[1..], " \t");
                if (std.mem.startsWith(u8, line, "- ") or
                    std.mem.startsWith(u8, line, "* ") or
                    std.mem.startsWith(u8, line, "+ "))
                    line = std.mem.trim(u8, line[2..], " \t");
                if (line.len != 0 and validAutomaticTitleText(line)) return line;
            }
            if (line_end == value.len) break;
            cursor = line_end + 1;
        }
        return null;
    }

    fn validAutomaticTitleText(value: []const u8) bool {
        if (value.len == 0) return false;
        for (value) |byte| if (byte < 0x20) return false;
        return true;
    }

    fn generatedAutomaticTitleCandidate(value: []const u8) ?[]const u8 {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (!std.unicode.utf8ValidateSlice(trimmed) or
            !validAutomaticTitleText(trimmed) or
            std.mem.indexOfAny(u8, trimmed, "\r\n") != null)
            return null;
        const bounded = boundAutomaticTitle(trimmed);
        return if (bounded.len == 0) null else bounded;
    }

    fn boundAutomaticTitle(value: []const u8) []const u8 {
        var cursor: usize = 0;
        var codepoints: usize = 0;
        var preferred_boundary: usize = 0;
        while (cursor < value.len and codepoints < automatic_title_max_codepoints) {
            const start = cursor;
            cursor += utf8CodepointLen(value, cursor);
            codepoints += 1;
            if (isAutomaticTitleBoundary(value[start..cursor]))
                preferred_boundary = start;
        }
        if (cursor == value.len) return value;
        const boundary = if (preferred_boundary > 0) preferred_boundary else cursor;
        var bounded = value[0..boundary];
        while (bounded.len != 0 and (bounded[bounded.len - 1] == ' ' or
            bounded[bounded.len - 1] == '\t'))
            bounded = bounded[0 .. bounded.len - 1];
        return bounded;
    }

    fn isAutomaticTitleBoundary(codepoint: []const u8) bool {
        if (codepoint.len == 1) {
            return switch (codepoint[0]) {
                ' ', '\t', ',', '.', ';', ':', '!', '?' => true,
                else => false,
            };
        }
        return std.mem.eql(u8, codepoint, "，") or
            std.mem.eql(u8, codepoint, "。") or
            std.mem.eql(u8, codepoint, "；") or
            std.mem.eql(u8, codepoint, "：") or
            std.mem.eql(u8, codepoint, "！") or
            std.mem.eql(u8, codepoint, "？") or
            std.mem.eql(u8, codepoint, "、");
    }

    fn applyProvisionalTaskTitle(
        self: *Workbench,
        task: *TaskView,
        run: *const RunRecord,
    ) bool {
        if (task.durable.title.len != 0 or run.generation != 1) return false;
        const candidate = automaticTitleCandidate(&run.input) orelse return false;
        const execution = taskExecutionInput(task) catch return false;
        const projected = self.copyProjected(
            boundAutomaticTitle(candidate),
            self.limits.max_task_title_bytes,
            execution.api_key,
        ) catch return false;
        if (projected.value.len == 0) {
            self.freeTracked(projected.value);
            return false;
        }
        const previous_title = task.durable.title;
        self.projection_bytes -= previous_title.len;
        task.durable.title = projected.value;
        task.durable.title_redacted = projected.redacted;
        return true;
    }

    fn rollbackProvisionalTaskTitle(
        self: *Workbench,
        task: *TaskView,
        previous_title: []u8,
        previous_redacted: bool,
    ) void {
        self.freeTracked(task.durable.title);
        task.durable.title = previous_title;
        self.projection_bytes += previous_title.len;
        task.durable.title_redacted = previous_redacted;
    }

    fn markAutomaticTitleUserOverride(_: *Workbench, task: *TaskView) void {
        for (task.durable.runs) |*entry| {
            const run = &(entry.* orelse continue);
            if (!run.automatic_title.provisional_applied) continue;
            switch (run.automatic_title.state.load(.acquire)) {
                .pending, .running, .ready => run.automatic_title.user_overrode = true,
                .none, .settled => {},
            }
        }
    }

    fn commitAutomaticTitlesNoFail(
        self: *Workbench,
        task: *TaskView,
    ) bool {
        var durable_changed = false;
        for (task.durable.runs) |*entry| {
            const run = &(entry.* orelse continue);
            if (run.automatic_title.state.load(.acquire) != .ready) continue;
            const credential = if (run.automatic_title.execution) |*execution|
                execution.input().api_key
            else
                run.redaction_secret;
            const candidate = if (run.automatic_title.generated)
                generatedAutomaticTitleCandidate(
                    run.automatic_title.result[0..run.automatic_title.result_len],
                )
            else
                null;
            const selected = candidate orelse automaticTitleCandidate(&run.input);
            const may_replace = run.generation == 1 and
                !run.automatic_title.user_overrode and
                (task.durable.title.len == 0 or run.automatic_title.provisional_applied);
            const keep_provisional = run.automatic_title.provisional_applied and
                candidate == null;
            if (may_replace and !keep_provisional) {
                if (selected) |value| {
                    const bounded = boundAutomaticTitle(value);
                    const projected = self.copyProjected(
                        bounded,
                        self.limits.max_task_title_bytes,
                        credential,
                    ) catch null;
                    if (projected) |title| {
                        if (title.value.len == 0) {
                            self.freeTracked(title.value);
                        } else if (std.mem.eql(u8, title.value, task.durable.title) and
                            title.redacted == task.durable.title_redacted)
                        {
                            self.freeTracked(title.value);
                        } else {
                            self.freeTracked(task.durable.title);
                            task.durable.title = title.value;
                            task.durable.title_redacted = title.redacted;
                            durable_changed = true;
                        }
                    }
                }
            }
            std.crypto.secureZero(u8, &run.automatic_title.result);
            run.automatic_title.result_len = 0;
            run.automatic_title.generated = false;
            if (run.automatic_title.execution) |*execution| execution.deinit();
            run.automatic_title.execution = null;
            run.automatic_title.state.store(.settled, .release);
        }
        return durable_changed;
    }

    fn prepareAutomaticTitle(
        self: *Workbench,
        task: *const TaskView,
        generation: u64,
        execution: account_contract.ExecutionConfigInput,
    ) AutomaticTitle {
        if (generation != 1 or task.durable.title.len != 0) return .{};
        var result = AutomaticTitle{};
        result.execution = OwnedTaskExecution.clone(
            self.allocator,
            execution.target.provider_kind,
            execution.target.model,
            execution.target.base_url,
            execution.execution_generation,
            execution.api_key,
        ) catch {
            result.state.store(.ready, .release);
            return result;
        };
        result.state.store(.pending, .release);
        return result;
    }

    fn releaseAutomaticTitle(self: *Workbench, title: *AutomaticTitle) void {
        std.debug.assert(title.state.load(.acquire) != .running);
        std.crypto.secureZero(u8, &title.result);
        if (title.execution) |*execution| execution.deinit();
        title.execution = null;
        title.state.store(.settled, .release);
        _ = self;
    }

    test "automatic title fallback extracts text and skill display names" {
        var text_input: RunInputRecord = .{ .text = .{
            .value = @constCast("\n```text\nignored\n```\n### Review the AgentCore lifecycle\nmore detail"),
        } };
        const text_title = automaticTitleCandidate(&text_input) orelse
            return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(
            "Review the AgentCore lifecycle",
            text_title,
        );
        const long_title = boundAutomaticTitle(
            "请分析 AgentCore Conversation 生命周期以及它和 Workbench 的边界并给出迁移建议",
        );
        try std.testing.expectEqualStrings(
            "请分析 AgentCore Conversation",
            long_title,
        );
        try std.testing.expect(
            boundAutomaticTitle("Review this long task title should stop at a word boundary").len <
                "Review this long task title should stop at a word boundary".len,
        );

        var skill_input: RunInputRecord = .{ .skill = .{
            .skill_id = @constCast("skill"),
            .catalog_revision = @constCast("revision"),
            .invocation_name = @constCast("review"),
            .display_name = @constCast("Review workspace"),
            .argument_values = &.{},
        } };
        const skill_title = automaticTitleCandidate(&skill_input) orelse
            return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings("Review workspace", skill_title);

        var empty_skill: RunInputRecord = .{ .skill = .{
            .skill_id = @constCast("skill"),
            .catalog_revision = @constCast("revision"),
            .invocation_name = @constCast("review"),
            .display_name = @constCast(""),
            .argument_values = &.{},
        } };
        try std.testing.expect(automaticTitleCandidate(&empty_skill) == null);
        try std.testing.expectEqualStrings(
            "AgentCore title",
            generatedAutomaticTitleCandidate("  AgentCore title  ").?,
        );
        try std.testing.expect(generatedAutomaticTitleCandidate("line one\nline two") == null);
    }

    test "automatic title allocation failure does not escape the fallback" {
        var workbench = try testWorkbench();
        defer workbench.deinit();

        const remaining = workbench.limits.max_projection_bytes - workbench.projection_bytes;
        const reservation = try workbench.allocTrackedCapacity(remaining);
        defer workbench.freeTracked(reservation);

        const task = &workbench.tasks[0].?;
        const run = &task.durable.runs[0].?;
        run.automatic_title.state.store(.ready, .release);
        try std.testing.expect(!workbench.commitAutomaticTitlesNoFail(task));
        try std.testing.expectEqualStrings("", task.durable.title);
    }

    test "automatic title settlement never overwrites a user title" {
        var workbench = try testWorkbench();
        defer workbench.deinit();

        const task = &workbench.tasks[0].?;
        const run = &task.durable.runs[0].?;
        try workbench.replaceTracked(
            &task.durable.title,
            "Provisional title",
            workbench.limits.max_task_title_bytes,
        );
        run.automatic_title.provisional_applied = true;
        run.automatic_title.state.store(.pending, .release);
        try workbench.replaceTracked(
            &task.durable.title,
            "User title",
            workbench.limits.max_task_title_bytes,
        );
        workbench.markAutomaticTitleUserOverride(task);
        const generated = "Generated title";
        @memcpy(run.automatic_title.result[0..generated.len], generated);
        run.automatic_title.result_len = generated.len;
        run.automatic_title.generated = true;
        run.automatic_title.state.store(.ready, .release);

        try std.testing.expect(!workbench.commitAutomaticTitlesNoFail(task));
        try std.testing.expectEqualStrings("User title", task.durable.title);
        try std.testing.expect(run.automatic_title.user_overrode);
        try std.testing.expectEqual(
            AutomaticTitleState.settled,
            run.automatic_title.state.load(.acquire),
        );
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
        const slot = findEmpty(RunRecord, task.durable.runs) orelse return error.RunCapacity;
        if (task.durable.next_run_generation == std.math.maxInt(u64)) return error.RunGenerationExhausted;
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
        const execution_model = try self.copyBounded(
            task.durable.execution_model,
            account_contract.Limits.model_id_bytes,
        );
        errdefer self.freeTracked(execution_model);
        task.durable.next_run_generation += 1;
        var automatic_title = self.prepareAutomaticTitle(
            task,
            task.durable.next_run_generation,
            execution,
        );
        errdefer self.releaseAutomaticTitle(&automatic_title);
        task.durable.runs[slot] = .{
            .id = 0,
            .generation = task.durable.next_run_generation,
            .execution_generation = task.durable.execution_generation,
            .execution_provider = task.durable.execution_provider,
            .execution_model = execution_model,
            .execution_model_owned = true,
            .input = input_record,
            .tools = tools,
            .status_text = status_text,
            .terminal_diagnostic = terminal_diagnostic,
            .redaction_secret = execution.api_key,
            .automatic_title = automatic_title,
        };
        return slot;
    }

    fn reserveCompactRecord(
        self: *Workbench,
        task: *TaskView,
        operation_id: u64,
        after_run_id: u64,
    ) Error!usize {
        const slot = findEmpty(CompactRecord, task.durable.compacts) orelse
            return error.CompactCapacity;
        const diagnostic = try self.allocTrackedCapacity(
            self.limits.max_terminal_diagnostic_bytes,
        );
        errdefer self.freeTracked(diagnostic);
        const execution = try taskExecutionInput(task);
        task.durable.compacts[slot] = .{
            .id = operation_id,
            .after_run_id = after_run_id,
            .terminal_diagnostic = diagnostic,
            .redaction_secret = execution.api_key,
        };
        return slot;
    }

    fn discardCompactRecord(
        self: *Workbench,
        task: *TaskView,
        slot: usize,
    ) void {
        const compact = &(task.durable.compacts[slot] orelse return);
        self.deinitCompactRecord(compact);
        task.durable.compacts[slot] = null;
    }

    fn deinitCompactRecord(self: *Workbench, compact: *CompactRecord) void {
        std.debug.assert(!compact.worker_reference_held.load(.acquire));
        std.debug.assert(compact.terminal_publication.load(.acquire) != .publishing);
        self.freeTracked(compact.terminal_diagnostic);
        compact.* = undefined;
    }

    fn discardRunRecord(self: *Workbench, task: *TaskView, slot: usize) void {
        const run = &(task.durable.runs[slot] orelse return);
        self.deinitRunRecord(run);
        task.durable.runs[slot] = null;
    }

    fn deinitRunRecord(self: *Workbench, run: *RunRecord) void {
        std.debug.assert(run.automatic_title.state.load(.acquire) != .running);
        self.releaseAutomaticTitle(&run.automatic_title);
        for (run.tools) |*tool_entry| {
            const tool = &(tool_entry.* orelse continue);
            self.deinitToolView(tool);
        }
        self.allocator.free(run.tools);
        self.deinitRunInputRecord(&run.input);
        self.freeTrackedText(&run.assistant);
        if (run.execution_model_owned)
            self.freeTracked(@constCast(run.execution_model));
        self.freeTracked(run.status_text);
        self.freeTracked(run.terminal_diagnostic);
        run.* = undefined;
    }

    fn deinitTaskView(self: *Workbench, task: *TaskView) void {
        std.debug.assert(task.runtime.worker_references.load(.acquire) == 0);
        std.debug.assert(task.runtime.restore_job == null);
        self.releaseTaskAttachmentNoFail(task, .cold_start);
        for (task.durable.runs) |*run_entry| {
            const run = &(run_entry.* orelse continue);
            self.deinitRunRecord(run);
        }
        self.allocator.free(task.durable.runs);
        for (task.durable.compacts) |*compact_entry| {
            const compact = &(compact_entry.* orelse continue);
            self.deinitCompactRecord(compact);
        }
        self.allocator.free(task.durable.compacts);
        self.allocator.free(task.durable.ui_history);
        self.freeTracked(task.durable.execution_model);
        self.freeTracked(task.durable.workspace_root);
        self.freeTracked(task.durable.title);
        if (task.durable.checkpoint) |*checkpoint|
            checkpoint.deinit(self.allocator);
        if (task.runtime.pending_model) |model| self.allocator.free(model);
        task.* = undefined;
    }

    fn releaseTaskAttachmentNoFail(
        self: *Workbench,
        task: *TaskView,
        cause: task_runtime.DetachmentCause,
    ) void {
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
        self.releaseExecutionValueNoFail(task, &live.execution);
        if (live.pinned_catalog) |*snapshot| {
            self.projection_bytes -= snapshot.projected_bytes;
            snapshot.deinit();
        }
    }

    fn copyBounded(self: *Workbench, value: []const u8, max: usize) Error![]u8 {
        if (value.len > max or value.len > self.limits.max_projection_bytes - self.projection_bytes)
            return error.ProjectionCapacity;
        const result = try self.allocator.dupe(u8, value);
        self.projection_bytes += result.len;
        return result;
    }

    fn copyPreviewBounded(self: *Workbench, value: []const u8, max: usize) Error![]u8 {
        if (value.len > max) return error.ProjectionCapacity;
        return self.allocator.dupe(u8, value);
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
            if (task.runtime.execution()) |execution|
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
            if (task.runtime.execution()) |execution| {
                const credential = execution.input().api_key;
                if (credential.len > longest and std.mem.startsWith(u8, value, credential))
                    longest = credential.len;
            }
        }
        return longest;
    }

    fn projectedJsonValueWithKnownCredentials(
        self: *const Workbench,
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

    fn containsKnownSecret(value: []const u8, credential: []const u8) bool {
        return credential.len != 0 and
            std.mem.indexOf(u8, value, credential) != null;
    }

    fn prepareUiRecord(
        self: *Workbench,
        access: *task_agent_session.Access,
        run_id: u64,
        request_id: u64,
        response: UiResponse,
        credential: []const u8,
    ) UiRecord {
        var record = UiRecord{
            .request_id = request_id,
            .run_id = run_id,
            .kind = kindForResponse(response),
            .state = stateForResponse(response),
        };
        var pending = access.copyPendingUiRequest(self.allocator) catch return record;
        defer pending.deinit();
        if (pending.run_id != run_id or pending.request_id != request_id) return record;
        var parsed = lifecycle.decodePermissionRequest(self.allocator, pending.json) catch return record;
        defer parsed.deinit();
        self.fillUiRecord(&record, parsed.value(), credential);
        return record;
    }

    fn prepareCancelledUiRecord(
        self: *Workbench,
        access: *task_agent_session.Access,
        run_id: u64,
        credential: []const u8,
    ) ?UiRecord {
        if (run_id == 0) return null;
        var pending = access.copyPendingUiRequest(self.allocator) catch return null;
        defer pending.deinit();
        if (pending.run_id != run_id) return null;
        var parsed = lifecycle.decodePermissionRequest(self.allocator, pending.json) catch return null;
        defer parsed.deinit();
        var record = UiRecord{
            .request_id = pending.request_id,
            .run_id = run_id,
            .kind = .permission,
            .state = .cancelled,
        };
        self.fillUiRecord(&record, parsed.value(), credential);
        return record;
    }

    fn fillUiRecord(
        _: *Workbench,
        record: *UiRecord,
        permission: lifecycle.PermissionRequest,
        credential: []const u8,
    ) void {
        if (permission.request_id.len <= permission_summary_field_capacity) {
            @memcpy(record.agent_request_id[0..permission.request_id.len], permission.request_id);
            record.agent_request_id_len = permission.request_id.len;
        }
        const result = sanitizeInto(
            &record.detail,
            permission.arguments_json,
            credential,
        );
        record.detail_len = result.len;
        record.detail_truncated = result.truncated;
        record.redacted = result.redacted;
    }

    fn pushUiRecord(_: *Workbench, view: *TaskView, record: UiRecord) void {
        for (view.durable.ui_history) |entry| if (entry) |existing|
            if (existing.request_id == record.request_id) return;
        var stored = record;
        if (stored.permission == null and stored.agent_request_id_len != 0) {
            if (findRun(view.durable.runs, stored.run_id)) |run| {
                if (run.permission_provenance) |summary| {
                    if (std.mem.eql(u8, stored.agent_request_id[0..stored.agent_request_id_len], summary.requestId()))
                        stored.permission = summary;
                }
            }
        }
        if (view.runtime.pending_ui_request_id == stored.request_id and view.runtime.pending_ui_order != 0) {
            stored.order = view.runtime.pending_ui_order;
            view.runtime.pending_ui_request_id = 0;
            view.runtime.pending_ui_order = 0;
        } else {
            const run = findRun(view.durable.runs, stored.run_id) orelse unreachable;
            stored.order = takeActivityOrder(run);
        }
        view.durable.ui_history[view.durable.ui_history_next] = stored;
        view.durable.ui_history_next = (view.durable.ui_history_next + 1) % view.durable.ui_history.len;
        view.durable.ui_history_count = @min(view.durable.ui_history_count + 1, view.durable.ui_history.len);
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
    completion_out: *std.atomic.Value(CloseCompletion),
    binding: *task_agent_session.Binding,
    notifier: ChangeNotifier,
) void {
    const completion: CloseCompletion = close: {
        switch (binding.state()) {
            .owned => switch (binding.closeOutcome(.session_close)) {
                .closed => {},
                .failure => |failure| break :close closeFailureCompletion(
                    failure.session_disposition,
                ),
            },
            // A previous close succeeded but Runtime slot release failed.
            // Retry only that remaining linear obligation.
            .closed => {},
            .released, .relinquished, .moved, .fixture, .abandoned => unreachable,
        }
        binding.releaseClosed() catch
            break :close .failed_closing;
        break :close .closed;
    };
    completion_out.store(completion, .release);
    _ = notifier.notify();
}

const AutomaticTitleWatchdog = struct {
    io: std.Io,
    title: *AutomaticTitle,
    stream: *lifecycle.CompletionStream,
    finished: std.atomic.Value(bool) = .init(false),
    timed_out: std.atomic.Value(bool) = .init(false),

    fn run(self: *AutomaticTitleWatchdog) void {
        var elapsed_ms: u32 = 0;
        while (elapsed_ms < automatic_title_timeout_ms) : (elapsed_ms += automatic_title_watchdog_poll_ms) {
            if (self.finished.load(.acquire)) return;
            if (self.title.cancel_requested.load(.acquire)) {
                _ = self.stream.abort(.user_request) catch return;
                return;
            }
            std.Io.Timeout.sleep(.{ .duration = .{
                .raw = std.Io.Duration.fromMilliseconds(
                    automatic_title_watchdog_poll_ms,
                ),
                .clock = .awake,
            } }, self.io) catch break;
        }
        if (self.finished.load(.acquire)) return;
        if (self.title.cancel_requested.load(.acquire)) {
            _ = self.stream.abort(.user_request) catch return;
            return;
        }
        self.timed_out.store(true, .release);
        _ = self.stream.abort(.timeout) catch return;
    }
};

fn generateAutomaticTitle(workbench: *Workbench, run: *RunRecord) void {
    const claimed = run.automatic_title.state.cmpxchgStrong(
        .pending,
        .running,
        .acq_rel,
        .acquire,
    );
    if (claimed != null) return;
    defer run.automatic_title.state.store(.ready, .release);
    if (run.automatic_title.cancel_requested.load(.acquire)) return;
    const source = Workbench.automaticTitleCompletionInput(&run.input) orelse return;
    const execution = &(run.automatic_title.execution orelse return);
    const config = execution.input();
    const owner = workbench.completion_factory.create(std.heap.c_allocator, .{
        .provider = agentProvider(run.execution_provider),
        .credential = config.api_key,
        .base_url = config.target.base_url,
        .model = config.target.model,
    }) catch return;
    const messages = [_]lifecycle.CompletionMessage{.{
        .role = .user,
        .text = source,
    }};
    const stream = owner.startStream(.{
        .system = automatic_title_system_prompt,
        .messages = &messages,
    }) catch {
        _ = destroyAutomaticTitleCompletion(owner);
        return;
    };
    var watchdog = AutomaticTitleWatchdog{
        .io = workbench.io,
        .title = &run.automatic_title,
        .stream = stream,
    };
    const watchdog_thread = std.Thread.spawn(.{}, AutomaticTitleWatchdog.run, .{&watchdog}) catch {
        _ = destroyAutomaticTitleStream(stream, owner);
        return;
    };

    var output_len: usize = 0;
    var overflow = false;
    var terminal_reason: ?lifecycle.CompletionStopReason = null;
    var stream_failed = false;
    while (terminal_reason == null and !stream_failed) {
        var event = stream.next() catch {
            stream_failed = true;
            break;
        };
        const kind = event.kind;
        const stop_reason = event.stop_reason;
        const payload = event.payload;
        switch (kind) {
            .text => {
                if (payload.len > automatic_title_result_capacity - output_len) {
                    overflow = true;
                } else if (!overflow) {
                    @memcpy(
                        run.automatic_title.result[output_len..][0..payload.len],
                        payload,
                    );
                    output_len += payload.len;
                }
            },
            .done => terminal_reason = stop_reason,
            .thinking, .usage => {},
        }
        event.deinit();
    }
    watchdog.finished.store(true, .release);
    watchdog_thread.join();
    const destroyed = destroyAutomaticTitleStream(stream, owner);
    if (!destroyed or stream_failed or overflow or
        watchdog.timed_out.load(.acquire) or
        run.automatic_title.cancel_requested.load(.acquire) or
        terminal_reason != .end_turn)
        return;
    run.automatic_title.result_len = output_len;
    run.automatic_title.generated = true;
}

fn destroyAutomaticTitleCompletion(owner: *lifecycle.Completion) bool {
    owner.deinit() catch return false;
    return true;
}

fn destroyAutomaticTitleStream(
    stream: *lifecycle.CompletionStream,
    owner: *lifecycle.Completion,
) bool {
    stream.deinit() catch return false;
    return destroyAutomaticTitleCompletion(owner);
}

fn publishAutomaticTitleFallback(run: *RunRecord) void {
    _ = run.automatic_title.state.cmpxchgStrong(
        .pending,
        .ready,
        .acq_rel,
        .acquire,
    );
}

fn executeRunJob(context: *anyopaque) void {
    const job: *RunJobContext = @ptrCast(@alignCast(context));
    defer job.destroy();
    const run = job.run;
    const claimed = run.agent_handoff.cmpxchgStrong(
        .queued,
        .starting,
        .acq_rel,
        .acquire,
    );
    std.debug.assert(claimed == null);
    var agent_run = switch (job.sessionAccess().beginRunOutcome(run.id)) {
        .run => |agent_run| agent_run,
        .failure => |failure| {
            run.agent_handoff.store(.finishing, .release);
            commitBeginFailure(run, failure);
            publishAutomaticTitleFallback(run);
            const notifier = job.workbench.change_notifier;
            releaseWorkerReference(job.task, run);
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
    const checkpoint_eligible = terminal.raw_status_code != null and
        terminal.session_disposition_at_completion == .reusable;
    terminal.deinit();
    agent_run.deinit();
    // The Run capability has finished its Agent operation. Do not retain the
    // Session across best-effort title generation: Task close may start as
    // soon as the terminal fact is visible. Checkpoint export below acquires
    // its own scoped lease, so close either waits for that real Session use or
    // prevents it from starting.
    job.releaseSessionAccess();
    const notifier = job.workbench.change_notifier;
    _ = notifier.notify();
    generateAutomaticTitle(job.workbench, run);
    _ = notifier.notify();
    var checkpoint_access: ?task_agent_session.Access = if (checkpoint_eligible)
        job.task.runtime.acquireAccess() catch null
    else
        null;
    defer if (checkpoint_access) |*access| access.deinit();
    if (!checkpoint_eligible or checkpoint_access == null or
        !postprocessCheckpoint(
            job.workbench,
            &checkpoint_access.?,
            &run.checkpoint,
            run.checkpoint_export_context,
        )) releaseWorkerReference(job.task, run);
    _ = notifier.notify();
}

fn executeCompactJob(context: *anyopaque) void {
    const job: *CompactJobContext = @ptrCast(@alignCast(context));
    defer job.destroy();
    const compact = job.compact;
    compact.agent_handoff.store(.starting, .release);
    _ = job.workbench.change_notifier.notify();
    compact.agent_handoff.store(.running, .release);
    var terminal = job.sessionAccess().executePreparedCompact(compact.id) catch |err| {
        compact.agent_handoff.store(.finishing, .release);
        _ = commitCompactProductTerminal(
            compact,
            .failed,
            if (err == error.SessionClosing)
                .session_close
            else
                .dependency_contract_failure,
            if (err == error.SessionClosing)
                .closing
            else
                .poisoned,
            .{},
            0,
            0,
            "",
            false,
        );
        const notifier = job.workbench.change_notifier;
        releaseCompactWorkerReference(job.task, compact);
        _ = notifier.notify();
        return;
    };
    compact.agent_handoff.store(.finishing, .release);
    commitCompactTerminal(compact, &terminal);
    const checkpoint_eligible = terminal.raw_status_code != null and
        terminal.session_disposition_at_completion == .reusable;
    terminal.deinit();
    const notifier = job.workbench.change_notifier;
    if (!checkpoint_eligible or !postprocessCheckpoint(
        job.workbench,
        job.sessionAccess(),
        &compact.checkpoint,
        compact.checkpoint_export_context,
    )) releaseCompactWorkerReference(job.task, compact);
    _ = notifier.notify();
}

const CheckpointSinkContext = struct {
    writer: *checkpoint_store.Writer,
    cancelled: *std.atomic.Value(bool),

    fn write(
        context: ?*anyopaque,
        bytes: []const u8,
    ) lifecycle.CheckpointSinkWriteResult {
        const self: *CheckpointSinkContext = @ptrCast(@alignCast(
            context orelse return .contract_failed,
        ));
        if (self.cancelled.load(.acquire)) return .cancelled;
        self.writer.write(bytes) catch |err| return switch (err) {
            error.ResourceLimit => .contract_failed,
            error.WriteFailed => .io_failed,
        };
        return .ok;
    }
};

fn postprocessCheckpoint(
    workbench: *Workbench,
    access: *task_agent_session.Access,
    postprocess: *CheckpointPostprocess,
    context: CheckpointExportContext,
) bool {
    if (workbench.checkpoint_store_health.load(.acquire) != .ready)
        return false;
    const store = workbench.checkpoint_store orelse return false;
    postprocess.state.store(.exporting, .release);
    if (postprocess.cancelled.load(.acquire)) {
        publishCheckpointFailure(postprocess, .cancelled);
        return true;
    }
    var writer = store.begin(context.task_id, checkpoint_export_limits.hard_bytes) catch {
        publishCheckpointFailure(postprocess, .io_failed);
        return true;
    };
    defer writer.deinit();
    var sink_context = CheckpointSinkContext{
        .writer = &writer,
        .cancelled = &postprocess.cancelled,
    };
    const started = std.Io.Timestamp.now(workbench.io, .awake);
    var outcome = access.exportCheckpoint(
        checkpoint_export_limits,
        .{ .context = &sink_context, .write_fn = CheckpointSinkContext.write },
        context.last_run_id,
        context.last_compact_id,
        context.model,
    ) catch {
        publishCheckpointFailure(postprocess, .export_failed);
        return true;
    };
    const finished = std.Io.Timestamp.now(workbench.io, .awake);
    const duration_ns: i128 = @intCast(started.durationTo(finished).nanoseconds);
    switch (outcome) {
        .failure => |failure| {
            const attempt = checkpointFailureAttempt(failure);
            outcome.deinit();
            publishCheckpointFailure(postprocess, attempt);
            return true;
        },
        .success => |*success| {
            const chunk_count = success.checkpoint.chunk_count;
            var candidate = CheckpointCandidate{
                .record = takeCheckpointRecord(
                    success,
                    context.task_id,
                    context.terminal_kind,
                    context.terminal_id,
                    context.binding_epoch,
                ),
                .metrics = .{
                    .chunk_count = chunk_count,
                    .export_duration_ns = duration_ns,
                },
            };
            outcome = undefined;
            const identity = writer.commit(
                candidate.record.blob.generation,
                candidate.record.blob.digest,
                candidate.record.blob.byte_size,
            ) catch |err| {
                if (err == error.PersistenceOutcomeUnknown) {
                    workbench.checkpoint_store_health.store(.outcome_unknown, .release);
                    postprocess.payload = .{ .store_outcome_unknown = candidate };
                    postprocess.state.store(.store_outcome_unknown, .release);
                    return true;
                }
                candidate.record.deinit(workbench.allocator);
                publishCheckpointFailure(postprocess, .io_failed);
                return true;
            };
            candidate.record.blob = identity;
            postprocess.payload = .{ .candidate = candidate };
            postprocess.state.store(.candidate_ready, .release);
            return true;
        },
    }
}

fn publishCheckpointFailure(
    postprocess: *CheckpointPostprocess,
    attempt: CheckpointAttempt,
) void {
    postprocess.payload = .{ .failure = attempt };
    postprocess.state.store(.failure_ready, .release);
}

fn takeCheckpointRecord(
    success: *lifecycle.CheckpointSuccess,
    task_id: u64,
    terminal_kind: std.meta.Tag(checkpoint_record.Terminal),
    terminal_id: u64,
    binding_epoch: u64,
) checkpoint_record.Record {
    const description = &success.description;
    if (description.skill_catalog_revision) |value| description.allocator.free(value);
    description.allocator.free(description.mcp_selection_fingerprint);
    const terminal: checkpoint_record.Terminal = switch (terminal_kind) {
        .run => .{ .run = terminal_id },
        .compact => .{ .compact = terminal_id },
    };
    const result = checkpoint_record.Record{
        .blob = .{
            .task_id = task_id,
            .generation = success.checkpoint.generation,
            .byte_size = success.checkpoint.total_bytes,
            .digest = success.checkpoint.digest,
        },
        .session = .{
            .logical_session_id = description.session_id,
            .last_run_id = description.last_run_id,
            .last_compact_id = description.last_compact_id,
            .model = description.model,
        },
        .anchor = .{
            .terminal = terminal,
            .binding_epoch = binding_epoch,
        },
    };
    success.* = undefined;
    return result;
}

fn cancelCompactJob(context: *anyopaque) void {
    const job: *CompactJobContext = @ptrCast(@alignCast(context));
    defer job.destroy();
    const compact = job.compact;
    _ = compact.pending_interruption.cmpxchgStrong(
        .none,
        .app_shutdown,
        .acq_rel,
        .acquire,
    );
    const interruption = pendingExternalInterruption(compact);
    cancelPreparedCompactOrPanic(job.sessionAccess(), compact.id);
    _ = commitCompactProductTerminal(
        compact,
        .aborted,
        compactCauseForInterruption(interruption),
        if (interruption == .user_cancel) .reusable else .closing,
        .{},
        0,
        0,
        "",
        false,
    );
    const notifier = job.workbench.change_notifier;
    releaseCompactWorkerReference(job.task, compact);
    _ = notifier.notify();
}

fn commitCompactTerminal(
    compact: *CompactRecord,
    result: *const lifecycle.CompactTerminalResult,
) void {
    const decision = task_policy.classifyCompactTerminal(result);
    _ = commitCompactProductTerminal(
        compact,
        decision.phase,
        decision.cause,
        result.session_disposition_at_completion,
        .{
            .input_tokens = result.input_tokens,
            .output_tokens = result.output_tokens,
            .cache_read_input_tokens = result.cache_read_input_tokens,
            .cache_creation_input_tokens = result.cache_creation_input_tokens,
        },
        result.before_context_tokens,
        result.after_context_tokens,
        result.diagnostic(),
        result.diagnostic_truncated,
    );
}

fn commitCompactProductTerminal(
    compact: *CompactRecord,
    phase: CompactPhase,
    cause: ?CompactCause,
    session_disposition_at_completion: lifecycle.SessionDisposition,
    usage: UsageView,
    before_context_tokens: u64,
    after_context_tokens: u64,
    diagnostic_bytes: []const u8,
    source_diagnostic_truncated: bool,
) bool {
    std.debug.assert(isTerminalCompactPhase(phase));
    if (compact.terminal_publication.cmpxchgStrong(
        .open,
        .publishing,
        .acq_rel,
        .acquire,
    ) == null) {
        const diagnostic = sanitizeInto(
            compact.terminal_diagnostic,
            diagnostic_bytes,
            compact.redaction_secret,
        );
        compact.terminal_payload = .{
            .phase = phase,
            .cause = cause,
            .before_context_tokens = before_context_tokens,
            .after_context_tokens = after_context_tokens,
            .usage = usage,
            .session_disposition_at_completion = session_disposition_at_completion,
            .diagnostic_len = diagnostic.len,
            .diagnostic_truncated = source_diagnostic_truncated or diagnostic.truncated,
            .diagnostic_redacted = diagnostic.redacted,
        };
        compact.terminal_publication.store(.published, .release);
        return true;
    }
    _ = compactTerminalPayload(compact).?;
    return false;
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

fn executeMcpRefreshJob(context: *anyopaque) void {
    const job: *McpRefreshJob = @ptrCast(@alignCast(context));
    const claimed = job.state.cmpxchgStrong(
        .queued,
        .running,
        .acq_rel,
        .acquire,
    );
    std.debug.assert(claimed == null);
    job.outcome = if (job.runtime.activateMcp()) |outcome|
        switch (outcome) {
            .empty => .empty,
            .activated => |activation| activated: {
                if (activation.takeSelection()) |startup_selection|
                    startup_selection.deinit();
                const selection = if (job.build_admission)
                    job.runtime.createMcpAdmissionSelection(
                        activation,
                        job.allowlists,
                    ) catch {
                        activation.deinit();
                        break :activated .unavailable;
                    }
                else
                    null;
                break :activated .{ .activated = .{
                    .activation = activation,
                    .selection = selection,
                } };
            },
            .unavailable => .unavailable,
        }
    else |_|
        .unavailable;
    job.state.store(.completed, .release);
    _ = job.notifier.notify();
}

fn cancelMcpRefreshJob(context: *anyopaque) void {
    const job: *McpRefreshJob = @ptrCast(@alignCast(context));
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

fn cancelRunJob(context: *anyopaque) void {
    const job: *RunJobContext = @ptrCast(@alignCast(context));
    defer job.destroy();
    const run = job.run;
    _ = run.pending_termination.cmpxchgStrong(
        .none,
        .app_shutdown,
        .acq_rel,
        .acquire,
    );
    const signal = pendingTerminationSignal(run);
    const decision = decisionForSignal(signal);
    const interruption = switch (signal) {
        .interrupted => |value| value,
        else => unreachable,
    };
    cancelPreparedRunOrPanic(job.sessionAccess(), run.id);
    _ = commitTerminal(
        run,
        decision.phase,
        decision.outcome,
        decision.cause,
        switch (interruption) {
            .user_cancel, .timeout => .reusable,
            .session_close, .app_shutdown => .closing,
        },
        "",
        false,
    );
    publishAutomaticTitleFallback(run);
    const notifier = job.workbench.change_notifier;
    releaseWorkerReference(job.task, run);
    _ = notifier.notify();
}

fn cancelPreparedRunOrPanic(
    access: *task_agent_session.Access,
    run_id: u64,
) void {
    access.cancelPreparedRun(run_id) catch |err| std.debug.panic(
        "Executor removed queued Run {d}, but Agent rejected prepared cancellation: {s}",
        .{ run_id, @errorName(err) },
    );
}

fn cancelPreparedCompactOrPanic(
    access: *task_agent_session.Access,
    operation_id: u64,
) void {
    access.cancelPreparedCompact(operation_id) catch |err| std.debug.panic(
        "Executor removed queued compact {d}, but Agent rejected prepared cancellation: {s}",
        .{ operation_id, @errorName(err) },
    );
}

fn releaseWorkerReference(task: *TaskView, run: *RunRecord) void {
    std.debug.assert(run.worker_reference_held.swap(false, .acq_rel));
    const references = &task.runtime.worker_references;
    const previous = references.fetchSub(1, .release);
    std.debug.assert(previous != 0);
}

fn releaseCompactWorkerReference(task: *TaskView, compact: *CompactRecord) void {
    if (!compact.worker_reference_held.swap(false, .acq_rel)) return;
    const previous = task.runtime.worker_references.fetchSub(1, .release);
    std.debug.assert(previous != 0);
}

fn noChangeNotification(_: ?*anyopaque) bool {
    return true;
}

fn agentProvider(provider: Provider) lifecycle.ProviderKind {
    return switch (provider) {
        .anthropic => .anthropic,
        .openai => .openai,
        .gemini => .gemini,
    };
}

fn accountProviderKind(provider: Provider) account_contract.ProviderKind {
    return switch (provider) {
        .anthropic => .anthropic,
        .openai => .openai,
        .gemini => .gemini,
    };
}

fn accountProvider(
    provider: account_contract.ProviderKind,
) Provider {
    return switch (provider) {
        .anthropic => .anthropic,
        .openai => .openai,
        .gemini => .gemini,
    };
}

fn scheduledProvider(provider: Provider) scheduled_tasks_impl.Provider {
    return switch (provider) {
        .anthropic => .anthropic,
        .openai => .openai,
        .gemini => .gemini,
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
        error.TaskCapacity,
        error.WorkspaceCapacity,
        error.RunCapacity,
        error.CompactCapacity,
        error.ExecutorShuttingDown,
        error.QueueFull,
        => .capacity_reached,
        else => .task_start_failed,
    };
}

fn agentPermissionChoice(choice: PermissionChoice) lifecycle.PermissionChoice {
    return switch (choice) {
        .allow_once => .allow_once,
        .allow_session => .allow_session,
        .deny_once => .deny_once,
        .deny_session => .deny_session,
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

fn commitBeginFailure(run: *RunRecord, failure: lifecycle.BeginRunFailure) void {
    const decision = task_policy.classifyBeginFailure(run, failure);
    _ = commitTerminal(
        run,
        decision.phase,
        decision.outcome,
        decision.cause,
        failure.session_disposition,
        "",
        false,
    );
}

fn hasSkillArchiveExtension(path: []const u8) bool {
    const extension = std.fs.path.extension(path);
    return std.ascii.eqlIgnoreCase(extension, ".skill") or
        std.ascii.eqlIgnoreCase(extension, ".zip");
}

fn privateDirectoryPermissions() std.Io.File.Permissions {
    return if (builtin.os.tag == .windows) .default_dir else .fromMode(0o700);
}

fn privateFilePermissions() std.Io.File.Permissions {
    return if (builtin.os.tag == .windows) .default_file else .fromMode(0o600);
}

fn cancelTaskCheckpoints(task: *TaskView) void {
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

fn cancelTaskAutomaticTitles(task: *TaskView) void {
    for (task.durable.runs) |*entry| {
        const run = &(entry.* orelse continue);
        run.automatic_title.cancel_requested.store(true, .release);
        publishAutomaticTitleFallback(run);
    }
}

fn checkpointIdentityEqual(
    left: checkpoint_store.Identity,
    right: checkpoint_store.Identity,
) bool {
    return left.task_id == right.task_id and
        left.generation == right.generation and
        left.byte_size == right.byte_size and
        std.mem.eql(u8, &left.digest, &right.digest);
}

fn optionalU64Equal(left: ?u64, right: ?u64) bool {
    if (left == null or right == null) return left == null and right == null;
    return left.? == right.?;
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

fn kindForResponse(response: UiResponse) UiRecordKind {
    _ = response;
    return .permission;
}

fn stateForResponse(response: UiResponse) UiRecordState {
    return switch (response.permission) {
        .allow_once => .allowed_once,
        .allow_session => .allowed_always,
        .deny_once => .denied,
        .deny_session => .denied_session,
    };
}

fn jsonValue(writer: *std.Io.Writer, value: anytype) !void {
    try std.json.Stringify.value(value, .{ .emit_nonportable_numbers_as_strings = true }, writer);
}

fn findEmpty(comptime T: type, entries: []?T) ?usize {
    for (entries, 0..) |entry, index| if (entry == null) return index;
    return null;
}

fn countPresent(comptime T: type, entries: []const ?T) usize {
    var count: usize = 0;
    for (entries) |entry| if (entry != null) {
        count += 1;
    };
    return count;
}

fn toolRouteDigest(id: []const u8) [tool_route_digest_bytes]u8 {
    var digest: [tool_route_digest_bytes]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(id, &digest, .{});
    return digest;
}

fn findToolByRouteDigest(
    entries: []?ToolView,
    route_digest: [tool_route_digest_bytes]u8,
) ?*ToolView {
    for (entries) |*entry| if (entry.*) |*tool|
        if (std.mem.eql(u8, &tool.route_digest, &route_digest)) return tool;
    return null;
}

fn catalogSnapshotLimits(limits: Limits) catalog_snapshot.Limits {
    return .{
        .max_catalog_skills = limits.max_catalog_skills,
        .max_catalog_issues = limits.max_catalog_issues,
        .max_skill_arguments = limits.max_skill_arguments,
        .max_catalog_projection_bytes = limits.max_catalog_projection_bytes,
    };
}

fn inventoryHasInvocationInScope(
    inventory: *const skill_management_impl.Inventory,
    scope: skill_management_impl.Scope,
    invocation_name: []const u8,
) bool {
    for (inventory.items()) |asset|
        if (asset.scope.eql(scope) and
            std.mem.eql(u8, asset.target_entry, invocation_name)) return true;
    return false;
}

fn writeSkillScope(
    writer: *std.Io.Writer,
    scope: skill_management_impl.Scope,
) Error!void {
    switch (scope) {
        .personal => writer.writeAll(
            "{\"kind\":\"personal\",\"workspaceId\":null,\"workspaceEpoch\":null}",
        ) catch return error.SnapshotTooLarge,
        .project => |project| writer.print(
            "{{\"kind\":\"project\",\"workspaceId\":\"{d}\",\"workspaceEpoch\":\"{d}\"}}",
            .{ project.workspace_id, project.workspace_epoch },
        ) catch return error.SnapshotTooLarge,
    }
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
            mcp_configuration.max_store_bytes,
            json_string_expansion,
        ) catch return null,
    ) catch return null;
    total = std.math.add(
        usize,
        total,
        std.math.mul(
            usize,
            limits.max_scheduled_task_projection_bytes,
            json_string_expansion,
        ) catch return null,
    ) catch return null;
    total = std.math.add(
        usize,
        total,
        std.math.mul(
            usize,
            limits.max_skill_assets,
            skill_asset_snapshot_overhead,
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
            model_connection_snapshot_text_bytes,
            json_string_expansion,
        ) catch return null,
    ) catch return null;
    total = std.math.add(usize, total, model_connection_snapshot_overhead) catch
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
    const compacts = std.math.mul(
        usize,
        limits.max_tasks,
        limits.max_compacts_per_task,
    ) catch return null;
    total = std.math.add(
        usize,
        total,
        std.math.mul(usize, compacts, compact_snapshot_overhead) catch return null,
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
        // Includes the independently bounded MCP safe projection in addition
        // to the ordinary Workbench projection budget.
        .max_snapshot_bytes = 8 * 1024 * 1024,
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
            .state = .authenticated,
            .catalog_state = .ready,
            .account_id = "account-1",
            .display_name = "Metask User",
            .api_keys = &api_keys,
            .models = &models,
            .selected_api_key_id = "key-1",
            .selected_model = "fixture-model",
            .model_catalog_api_key_id = "key-1",
            .can_create_task = true,
            .catalog_generation = 1,
            .metask_execution_generation = 1,
            .execution_generation = 1,
        },
    });
    try account_contract.validateView(workbench.accountView());
    workbench.installExecutionNoFail(&execution);
    workbench.endExecutionReplacementNoFail();
    workbench.finishAccountCommitNoFail();
}

fn testWorkbench() !Workbench {
    test_agent_runtime.io = std.testing.io;
    var workbench = try Workbench.init(
        std.testing.allocator,
        std.testing.io,
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
    workbench.next_workspace_id = 2;
    workbench.next_workspace_recent_order = 2;
    workbench.next_task_id = 4;
    const execution_model = try workbench.copyBounded(
        workbench.execution.model(),
        account_contract.Limits.model_id_bytes,
    );
    const runs = try workbench.allocator.alloc(?RunRecord, workbench.limits.max_runs_per_task);
    @memset(runs, null);
    const compacts = try workbench.allocator.alloc(
        ?CompactRecord,
        workbench.limits.max_compacts_per_task,
    );
    @memset(compacts, null);
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
        .durable = .{
            .id = 3,
            .recent_order = 1,
            .execution_generation = 1,
            .execution_provider = .anthropic,
            .execution_model = execution_model,
            .workspace_id = 1,
            .workspace_root = workspace,
            .title = try workbench.copyBounded("", workbench.limits.max_task_title_bytes),
            .runs = runs,
            .compacts = compacts,
            .next_run_generation = 1,
            .ui_history = ui_history,
        },
        .runtime = .{
            .attachment = .{ .attached = .{
                .binding = task_agent_session.Binding.testFixture(3),
                .execution = task_execution.take(),
                .pinned_catalog = null,
            } },
            .active_run_id = 7,
            .active_operation = .{ .run = 7 },
        },
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

const TestMcpRefreshTimer = struct {
    now_ms: u64 = 100_000,
    armed_at_ms: ?u64 = null,
    cancel_count: usize = 0,

    fn now(context: ?*anyopaque) ?u64 {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        return self.now_ms;
    }

    fn arm(context: ?*anyopaque, deadline_ms: u64) bool {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.armed_at_ms = deadline_ms;
        return true;
    }

    fn cancel(context: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.armed_at_ms = null;
        self.cancel_count += 1;
    }

    fn timer(self: *@This()) McpRefreshTimer {
        return .{
            .context = self,
            .enabled = true,
            .now_monotonic_ms = now,
            .arm_at = arm,
            .cancel = cancel,
        };
    }
};

test "MCP refresh timer rearm preserves the absolute deadline" {
    var timer_probe: TestMcpRefreshTimer = .{};
    const timer = timer_probe.timer();
    try std.testing.expectEqual(@as(?u64, 100_000), timer.now());
    try std.testing.expect(timer.armAt(135_000));
    timer_probe.now_ms = 120_000;
    timer.cancelCurrent();
    try std.testing.expect(timer.armAt(135_000));
    try std.testing.expectEqual(@as(?u64, 135_000), timer_probe.armed_at_ms);
}

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

const TestTaskPersistence = struct {
    storage: []u8,
    len: usize = 0,
    commits: usize = 0,
    result: TaskPersistenceCommit = .committed,

    fn commit(
        context: ?*anyopaque,
        bytes: []const u8,
    ) TaskPersistenceCommit {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.commits += 1;
        if (self.result != .committed) return self.result;
        if (bytes.len > self.storage.len) return .failed;
        @memcpy(self.storage[0..bytes.len], bytes);
        self.len = bytes.len;
        return .committed;
    }

    fn capability(
        self: *@This(),
        restored_bytes: ?[]const u8,
    ) TaskPersistence {
        return .{
            .context = self,
            .enabled = true,
            .restored_bytes = restored_bytes,
            .commit_fn = commit,
        };
    }
};

fn replaceTaskCredentialForTest(
    task: *TaskView,
    credential: []const u8,
) !void {
    const live = task.runtime.live().?;
    live.execution.deinit();
    var replacement = try OwnedTaskExecution.clone(
        std.testing.allocator,
        .anthropic,
        "fixture-model",
        account_contract.metask_anthropic_messages_url,
        task.durable.execution_generation,
        credential,
    );
    live.execution = replacement.take();
    const redaction_secret = live.execution.input().api_key;
    for (task.durable.runs) |*run_entry| {
        if (run_entry.*) |*run| run.redaction_secret = redaction_secret;
    }
}

fn detachTaskForTest(workbench: *Workbench, task: *TaskView) void {
    switch (task.runtime.attachment) {
        .detached => return,
        .attached, .closing => {},
    }
    var live = task.runtime.detach(.cold_start);
    live.execution.deinit();
    if (live.pinned_catalog) |*snapshot| {
        workbench.projection_bytes -= snapshot.projected_bytes;
        snapshot.deinit();
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

fn testPermissionRequest(tool_name: []const u8, arguments_json: []const u8) lifecycle.PermissionRequest {
    return .{
        .type = "permission",
        .request_id = "1111111111111111111111111111111111111111111111111111111111111111",
        .session_id = "000000000000000000000001",
        .run_id = 1,
        .tool_call_id = "tool-1",
        .tool = .{
            .namespace = .builtin,
            .name = tool_name,
            .binding = "0000000000000000000000000000000000000000000000000000000000000000",
        },
        .canonical_arguments_digest = "3333333333333333333333333333333333333333333333333333333333333333",
        .policy_generation = 1,
        .arguments_json = arguments_json,
        .responses = &.{ .deny_once, .allow_once },
        .candidate = null,
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

test "automatic Workspace root is optional and reserved from user registration" {
    test_agent_runtime.io = std.testing.io;
    var unavailable = try Workbench.init(
        std.testing.allocator,
        std.testing.io,
        &test_agent_runtime,
        testLimits(),
        .{},
    );
    try std.testing.expect(!unavailable.automaticWorkspacesAvailable());
    try installTestExecution(&unavailable);
    try std.testing.expectError(
        error.WorkspaceUnavailable,
        unavailable.createTaskForWorkspace(.automatic, 1, null, null),
    );
    unavailable.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var canonical_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const canonical_len = try tmp.dir.realPath(
        std.testing.io,
        &canonical_storage,
    );
    var root = try automatic_workspace_allocator.Root.open(
        std.testing.io,
        std.testing.allocator,
        canonical_storage[0..canonical_len],
    );
    defer root.deinit();
    var workbench = try Workbench.init(
        std.testing.allocator,
        std.testing.io,
        &test_agent_runtime,
        testLimits(),
        .{ .directories = .{ .automatic_workspace_root = &root } },
    );
    defer workbench.deinit();
    try std.testing.expect(workbench.automaticWorkspacesAvailable());
    try std.testing.expectError(
        error.InvalidWorkspace,
        workbench.openWorkspace(.{
            .workspace_root = workbench.automatic_workspaces.?.canonicalRoot(),
            .trust = .explicitly_trusted,
        }),
    );
    var allocation = try workbench.automatic_workspaces.?.allocate();
    defer allocation.deinit();
    try std.testing.expectError(
        error.InvalidWorkspace,
        workbench.openWorkspace(.{
            .workspace_root = allocation.path(),
            .trust = .explicitly_trusted,
        }),
    );
    try std.testing.expect(workbench.automatic_workspaces.?.rollback(&allocation));
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
        std.testing.io,
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
    const root_id = try workbench.openWorkspace(.{
        .workspace_root = root_path,
        .trust = .explicitly_trusted,
    });
    try std.testing.expect(root_id != 0);
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
    try std.testing.expectEqual(WorkspaceAuthorization.available, projections[0].authorization);
    try std.testing.expectEqualStrings("src", projections[0].display_name);
    try std.testing.expect(std.fs.path.isAbsolute(projections[0].canonical_root));

    try workbench.removeWorkspace(root_id);
    try std.testing.expectEqual(@as(u64, 2), try workbench.workspaceEpoch(root_id));
    const remaining = try workbench.copyWorkspaceProjections(&storage);
    try std.testing.expectEqual(@as(usize, 1), remaining.len);

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

    workbench.tasks[0].?.durable.runs[0].?.active_phase = .waiting_ui;
    const attention = workbench.workspaceSignals(1);
    try std.testing.expectEqual(@as(u32, 0), attention.running);
    try std.testing.expectEqual(@as(u32, 1), attention.attention);

    const run = &workbench.tasks[0].?.durable.runs[0].?;
    _ = commitTerminal(run, .failed, .failed, null, .reusable, "", false);
    finalizeTestTerminalEvents(&workbench);
    const failed = try workbench.copyWorkspaceProjections(&storage);
    try std.testing.expectEqual(@as(u32, 1), failed[0].signals.failed_or_interrupted);

    const task_root = workbench.tasks[0].?.durable.workspace_root;
    workbench.releaseTaskAttachmentNoFail(&workbench.tasks[0].?, .cold_start);
    try workbench.removeWorkspace(1);
    try std.testing.expect(workbench.tasks[0] != null);
    try std.testing.expectEqualStrings(task_root, workbench.tasks[0].?.durable.workspace_root);
    const removed = try workbench.copyWorkspaceProjections(&storage);
    try std.testing.expectEqual(@as(usize, 0), removed.len);
    try std.testing.expectError(error.TaskClosing, workbench.runTask(3, .{ .text = "continue" }));
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

test "Restore permission stats are projected as runtime health" {
    var workbench = try testWorkbench();
    defer workbench.deinit();
    workbench.tasks[0].?.runtime.last_restore_permission = .{
        .restored_rules = 2,
        .invalidated_rules = 1,
    };
    var storage: [8192]u8 = undefined;
    const snapshot = try workbench.writeSnapshot(&storage);
    try std.testing.expect(
        std.mem.indexOf(u8, snapshot, "\"restorePermission\":{\"restoredRules\":\"2\",\"invalidatedRules\":\"1\"}") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"permission_provenance\"") == null);
}

test "Task state round trip restores product history without fabricating a Session" {
    const persistence_storage = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(persistence_storage);
    var persistence = TestTaskPersistence{ .storage = persistence_storage };

    {
        var source = try testWorkbench();
        defer source.deinit();
        try source.replaceTracked(
            &source.workspaces[0].?.canonical_root,
            "/tmp/metawork-test",
            source.limits.max_workspace_bytes,
        );
        try source.replaceTracked(
            &source.workspaces[0].?.projected_root_storage,
            "/tmp/metawork-test",
            source.limits.max_workspace_bytes,
        );
        source.workspaces[0].?.projected_root_len = "/tmp/metawork-test".len;
        try source.replaceTracked(
            &source.tasks[0].?.durable.workspace_root,
            "/tmp/metawork-test",
            source.limits.max_workspace_bytes,
        );
        source.next_task_recent_order = 2;
        source.task_persistence = persistence.capability(null);
        source.task_persistence_health = .ready;
        try source.commitTaskState();
        try std.testing.expectEqual(@as(usize, 1), persistence.commits);
        var running_tool = try testEnvelope(
            3,
            7,
            "{\"tool_start\":{\"id\":\"tool-running\",\"name\":\"Bash\",\"input\":\"{}\"}}",
        );
        defer running_tool.deinit();
        try source.applyEvent(&running_tool);
        var tool_result = try testEnvelope(
            3,
            7,
            "{\"tool_result\":{\"id\":\"tool-1\",\"name\":\"Read\",\"input\":\"{}\",\"content\":\"persisted before terminal\",\"is_error\":false,\"elapsed_ms\":1}}",
        );
        defer tool_result.deinit();
        try source.applyEvent(&tool_result);
        try std.testing.expectEqual(@as(usize, 2), persistence.commits);
        try std.testing.expect(persistence.len != 0);
        var verified = try task_persistence.decode(
            std.testing.allocator,
            persistence.storage[0..persistence.len],
            source.taskPersistenceLimits(),
        );
        verified.deinit();
        try std.testing.expect(
            std.mem.indexOf(u8, persistence.storage[0..persistence.len], "SECRET-KEY") == null,
        );

        const terminal_storage = try std.testing.allocator.alloc(u8, 1024 * 1024);
        defer std.testing.allocator.free(terminal_storage);
        var terminal_state = try task_persistence.decode(
            std.testing.allocator,
            persistence.storage[0..persistence.len],
            source.taskPersistenceLimits(),
        );
        defer terminal_state.deinit();
        terminal_state.value.tasks[0].runs[0].phase = "completed";
        terminal_state.value.tasks[0].runs[0].outcome = "completed";
        terminal_state.value.tasks[0].active_operation = null;
        const terminal_bytes = try task_persistence.encode(
            terminal_storage,
            terminal_state.value,
        );
        var terminal_restore = try Workbench.init(
            std.testing.allocator,
            std.testing.io,
            &test_agent_runtime,
            testLimits(),
            .{
                .task_persistence = persistence.capability(terminal_bytes),
            },
        );
        defer terminal_restore.deinit();
        const terminal_task = terminal_restore.findTask(3) orelse
            return error.TestUnexpectedResult;
        const terminal_run = findRun(terminal_task.durable.runs, 7) orelse
            return error.TestUnexpectedResult;
        try std.testing.expectEqual(RunPhase.completed, runPhase(terminal_run));
        for (terminal_run.tools) |*entry| {
            const restored_tool = &(entry.* orelse continue);
            try std.testing.expect(restored_tool.state != .running);
            try std.testing.expect(!std.mem.eql(u8, restored_tool.id, "tool-running"));
        }
    }

    var restored = try Workbench.init(
        std.testing.allocator,
        std.testing.io,
        &test_agent_runtime,
        testLimits(),
        .{
            .task_persistence = persistence.capability(
                persistence.storage[0..persistence.len],
            ),
        },
    );
    defer restored.deinit();
    const task = restored.findTask(3) orelse return error.TestUnexpectedResult;
    try std.testing.expect(!task.runtime.hasAttachedSession());
    try std.testing.expect(task.runtime.executionConst() == null);
    try std.testing.expectEqual(ActiveOperation.none, task.runtime.active_operation);
    try std.testing.expectEqual(
        ContinuationUnavailableReason.checkpoint_unavailable,
        restored.taskContinuation(task).unavailable,
    );
    try std.testing.expectError(
        error.RecoveryUnavailable,
        restored.restoreTaskConversation(3, task.durable.binding_epoch),
    );
    const run = findRun(task.durable.runs, 7) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(RunPhase.interrupted, runPhase(run));
    try std.testing.expectEqual(RunOutcome.interrupted, productTerminalFacts(run).?.outcome);
    const tool = for (run.tools) |*entry| {
        const candidate = &(entry.* orelse continue);
        if (std.mem.eql(u8, candidate.content, "persisted before terminal"))
            break candidate;
    } else return error.TestUnexpectedResult;
    try std.testing.expectEqual(ToolState.completed, tool.state);
    for (run.tools) |*entry| {
        const restored_tool = &(entry.* orelse continue);
        try std.testing.expect(restored_tool.state != .running);
        try std.testing.expect(!std.mem.eql(u8, restored_tool.id, "tool-running"));
    }

    var snapshot_storage: [96 * 1024]u8 = undefined;
    const snapshot = try restored.writeSnapshot(&snapshot_storage);
    try std.testing.expect(
        std.mem.indexOf(u8, snapshot, "\"taskHistoryPersistence\":true") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, snapshot, "\"conversationRecovery\":true") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, snapshot, "\"continuationUnavailableReason\":\"checkpoint_unavailable\"") != null,
    );

    try restored.setTaskArchived(3, true);
    try restored.deleteTask(3);
    var deleted_restore = try Workbench.init(
        std.testing.allocator,
        std.testing.io,
        &test_agent_runtime,
        testLimits(),
        .{
            .task_persistence = persistence.capability(
                persistence.storage[0..persistence.len],
            ),
        },
    );
    defer deleted_restore.deinit();
    try std.testing.expect(deleted_restore.findTask(3) == null);
}

test "one damaged Task record does not poison surviving history" {
    var source = try testWorkbench();
    defer source.deinit();
    var scratch = try source.buildTaskStateWire();
    defer scratch.deinit();
    const mixed_tasks = try std.testing.allocator.alloc(
        task_persistence.TaskWire,
        scratch.state.tasks.len + 1,
    );
    defer std.testing.allocator.free(mixed_tasks);
    mixed_tasks[0] = scratch.state.tasks[0];
    mixed_tasks[1] = scratch.state.tasks[0];
    mixed_tasks[1].id = 0;
    var mixed_state = scratch.state;
    mixed_state.tasks = mixed_tasks;
    var bytes_storage: [64 * 1024]u8 = undefined;
    const bytes = try task_persistence.encode(&bytes_storage, mixed_state);

    var persistence = TestTaskPersistence{
        .storage = try std.testing.allocator.alloc(u8, task_persistence.max_store_bytes),
    };
    defer std.testing.allocator.free(persistence.storage);
    var restored = try Workbench.init(
        std.testing.allocator,
        std.testing.io,
        &test_agent_runtime,
        testLimits(),
        .{ .task_persistence = persistence.capability(bytes) },
    );
    defer restored.deinit();
    try std.testing.expect(restored.findTask(3) != null);
    try std.testing.expectEqual(TaskPersistenceHealth.degraded, restored.task_persistence_health);
    var snapshot_storage: [96 * 1024]u8 = undefined;
    const snapshot = try restored.writeSnapshot(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(
        u8,
        snapshot,
        "\"taskHistoryPersistence\":true,\"taskHistoryPersistenceHealth\":\"degraded\"",
    ) != null);

    try installTestExecution(&restored);
    try restored.requireTaskPersistenceMutation();
}

test "Automatic Workspace history survives an unavailable allocator" {
    const persistence_storage = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(persistence_storage);
    var persistence = TestTaskPersistence{ .storage = persistence_storage };

    {
        var source = try testWorkbench();
        defer source.deinit();
        const workspace = &source.workspaces[0].?;
        workspace.kind = .automatic;
        workspace.automatic_task_id = 3;
        workspace.visible = false;
        workspace.recent_order = 0;
        source.next_task_recent_order = 2;
        source.task_persistence = persistence.capability(null);
        source.task_persistence_health = .ready;
        try source.commitTaskState();
    }

    var restored = try Workbench.init(
        std.testing.allocator,
        std.testing.io,
        &test_agent_runtime,
        testLimits(),
        .{
            .task_persistence = persistence.capability(
                persistence.storage[0..persistence.len],
            ),
        },
    );
    defer restored.deinit();
    try std.testing.expectEqual(TaskPersistenceHealth.ready, restored.task_persistence_health);
    try std.testing.expect(!restored.automaticWorkspacesAvailable());
    const restored_workspace = restored.findWorkspace(1) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(WorkspaceKind.automatic, restored_workspace.kind);
    var workspace_storage: [1]WorkspaceProjection = undefined;
    const workspaces = try restored.copyWorkspaceProjections(&workspace_storage);
    try std.testing.expectEqual(@as(usize, 1), workspaces.len);
    try std.testing.expectEqual(WorkspaceKind.automatic, workspaces[0].kind);
    try std.testing.expectEqual(WorkspaceAuthorization.available, workspaces[0].authorization);
    const task = restored.findTask(3) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(
        ContinuationUnavailableReason.checkpoint_unavailable,
        restored.taskContinuation(task).unavailable,
    );

    var snapshot_storage: [96 * 1024]u8 = undefined;
    const snapshot = try restored.writeSnapshot(&snapshot_storage);
    try std.testing.expect(
        std.mem.indexOf(u8, snapshot, "\"automaticWorkspaces\":false") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, snapshot, "\"kind\":\"automatic\"") != null,
    );
}

test "Task persistence restore failure blocks product mutations" {
    test_agent_runtime.io = std.testing.io;
    var workbench = try Workbench.init(
        std.testing.allocator,
        std.testing.io,
        &test_agent_runtime,
        testLimits(),
        .{ .task_persistence = .{ .restore_failed = true } },
    );
    defer workbench.deinit();
    try installTestExecution(&workbench);
    try std.testing.expectEqual(TaskPersistenceHealth.read_failed, workbench.task_persistence_health);
    try std.testing.expectError(
        error.TaskPersistenceUnavailable,
        workbench.openWorkspace(.{
            .workspace_root = "/tmp/metawork-test",
            .trust = .explicitly_trusted,
        }),
    );
}

test "Task persistence failure rolls back metadata and closes mutation admission" {
    const persistence_storage = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(persistence_storage);
    var persistence = TestTaskPersistence{
        .storage = persistence_storage,
        .result = .failed,
    };
    var workbench = try testWorkbench();
    defer workbench.deinit();
    workbench.task_persistence = persistence.capability(null);
    workbench.task_persistence_health = .ready;
    const previous_recent_order = workbench.tasks[0].?.durable.recent_order;
    const previous_next_recent_order = workbench.next_task_recent_order;

    try std.testing.expectError(
        error.TaskPersistenceFailed,
        workbench.renameTask(3, "must not publish"),
    );
    try std.testing.expectEqualStrings("", workbench.tasks[0].?.durable.title);
    try std.testing.expectEqual(
        previous_recent_order,
        workbench.tasks[0].?.durable.recent_order,
    );
    try std.testing.expectEqual(previous_next_recent_order, workbench.next_task_recent_order);
    try std.testing.expectEqual(TaskPersistenceHealth.write_failed, workbench.task_persistence_health);
    try std.testing.expectError(
        error.TaskPersistenceUnavailable,
        workbench.setTaskArchived(3, true),
    );
}

test "Task persistence failure rolls back deletion before physical release" {
    const persistence_storage = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(persistence_storage);
    var persistence = TestTaskPersistence{
        .storage = persistence_storage,
        .result = .failed,
    };
    var workbench = try testWorkbench();
    defer workbench.deinit();

    const task = &workbench.tasks[0].?;
    task.runtime.active_run_id = 0;
    const completed = &task.durable.runs[0].?;
    _ = commitTerminal(completed, .completed, .completed, null, .reusable, "", false);
    finalizeTestTerminalEvents(&workbench);
    task.durable.archived = true;
    workbench.releaseTaskAttachmentNoFail(task, .cold_start);
    workbench.task_persistence = persistence.capability(null);
    workbench.task_persistence_health = .ready;
    const tracked_before_delete = workbench.projection_bytes;

    try std.testing.expectError(error.TaskPersistenceFailed, workbench.deleteTask(3));
    try std.testing.expect(workbench.findTask(3) != null);
    try std.testing.expectEqual(tracked_before_delete, workbench.projection_bytes);
    try std.testing.expectEqual(TaskPersistenceHealth.write_failed, workbench.task_persistence_health);
    var snapshot_storage: [128 * 1024]u8 = undefined;
    const snapshot = try workbench.writeSnapshot(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(
        u8,
        snapshot,
        "\"deletionStatus\":\"failed\"",
    ) != null);
}

test "Task persistence failure rolls back Workspace upsert candidates" {
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
    const persistence_storage = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(persistence_storage);
    var persistence = TestTaskPersistence{
        .storage = persistence_storage,
        .result = .failed,
    };

    {
        var workbench = try Workbench.init(
            std.testing.allocator,
            std.testing.io,
            &test_agent_runtime,
            testLimits(),
            .{ .task_persistence = persistence.capability(null) },
        );
        defer workbench.deinit();
        const next_workspace_id = workbench.next_workspace_id;
        const next_recent_order = workbench.next_workspace_recent_order;
        try std.testing.expectError(
            error.TaskPersistenceFailed,
            workbench.openWorkspace(.{
                .workspace_root = root_path,
                .trust = .explicitly_trusted,
            }),
        );
        try std.testing.expectEqual(@as(usize, 0), workbench.workspaceCount(.manual));
        try std.testing.expectEqual(next_workspace_id, workbench.next_workspace_id);
        try std.testing.expectEqual(next_recent_order, workbench.next_workspace_recent_order);
    }

    persistence.result = .committed;
    var workbench = try Workbench.init(
        std.testing.allocator,
        std.testing.io,
        &test_agent_runtime,
        .{ .max_workspaces = 1 },
        .{ .task_persistence = persistence.capability(null) },
    );
    defer workbench.deinit();
    const root_id = try workbench.openWorkspace(.{
        .workspace_root = root_path,
        .trust = .explicitly_trusted,
    });
    try workbench.removeWorkspace(root_id);
    const hidden = workbench.findWorkspace(root_id) orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(!hidden.visible);
    const hidden_epoch = hidden.epoch;
    const next_workspace_id = workbench.next_workspace_id;
    const next_recent_order = workbench.next_workspace_recent_order;
    persistence.result = .failed;
    try std.testing.expectError(
        error.TaskPersistenceFailed,
        workbench.openWorkspace(.{
            .workspace_root = source_path,
            .trust = .explicitly_trusted,
        }),
    );
    const restored_hidden = workbench.findWorkspace(root_id) orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(!restored_hidden.visible);
    try std.testing.expectEqual(hidden_epoch, restored_hidden.epoch);
    try std.testing.expectEqualStrings(root_path, restored_hidden.canonical_root);
    try std.testing.expect(workbench.findWorkspaceByRoot(source_path) == null);
    try std.testing.expectEqual(next_workspace_id, workbench.next_workspace_id);
    try std.testing.expectEqual(next_recent_order, workbench.next_workspace_recent_order);
}

test "Scheduled Task admission is bounded redacted and arms the Workbench clock" {
    var workbench = try testWorkbench();
    defer workbench.deinit();
    var automatic_tmp = std.testing.tmpDir(.{});
    defer automatic_tmp.cleanup();
    var automatic_root_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const automatic_root_len = try automatic_tmp.dir.realPath(
        std.testing.io,
        &automatic_root_storage,
    );
    var automatic_root = try automatic_workspace_allocator.Root.open(
        std.testing.io,
        std.testing.allocator,
        automatic_root_storage[0..automatic_root_len],
    );
    defer automatic_root.deinit();
    var clock: TestScheduleClock = .{ .now = 1_000 };
    var persistence: TestSchedulePersistence = .{};
    workbench.schedule_timer = clock.timer();
    workbench.schedule_persistence = persistence.capability();
    workbench.schedule_persistence_health = .ready;
    try std.testing.expectError(
        error.WorkspaceUnavailable,
        workbench.createScheduledTask(.{
            .title = "Independent review",
            .expected_execution_generation = 1,
            .input = "Review current work",
            .recurrence = .{ .once = .{ .at_unix_seconds = 2_000 } },
        }),
    );
    try std.testing.expectEqual(@as(usize, 0), persistence.commits);
    workbench.automatic_workspaces = automatic_workspace_allocator.Allocator.init(
        &automatic_root,
    );
    const id = try workbench.createScheduledTask(.{
        .title = "Review SECRET-KEY",
        .expected_execution_generation = 1,
        .input = "Inspect SECRET-KEY usage",
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
            item.input.value,
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

test "Scheduled Task execution drift becomes needs attention without blocking Account" {
    var workbench = try testWorkbench();
    defer workbench.deinit();
    var automatic_tmp = std.testing.tmpDir(.{});
    defer automatic_tmp.cleanup();
    var automatic_root_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const automatic_root_len = try automatic_tmp.dir.realPath(
        std.testing.io,
        &automatic_root_storage,
    );
    var automatic_root = try automatic_workspace_allocator.Root.open(
        std.testing.io,
        std.testing.allocator,
        automatic_root_storage[0..automatic_root_len],
    );
    defer automatic_root.deinit();
    var clock: TestScheduleClock = .{ .now = 1_000 };
    var persistence: TestSchedulePersistence = .{};
    workbench.schedule_timer = clock.timer();
    workbench.schedule_persistence = persistence.capability();
    workbench.schedule_persistence_health = .ready;
    workbench.automatic_workspaces = automatic_workspace_allocator.Allocator.init(
        &automatic_root,
    );
    workbench.setScheduleBackgroundAvailableNoFail(true);
    const id = try workbench.createScheduledTask(.{
        .title = "Review current work",
        .expected_execution_generation = 1,
        .input = "Review current work",
        .recurrence = .{ .once = .{ .at_unix_seconds = 2_000 } },
    });
    try std.testing.expectEqual(@as(u64, 2_000), clock.armed_at.?);

    workbench.execution.generation = 2;
    workbench.account.execution_generation = 2;
    try std.testing.expect(workbench.reconcileScheduledTaskBindingsNoFail());

    const item = workbench.scheduled_tasks.find(id).?;
    try std.testing.expect(!item.enabled);
    try std.testing.expectEqual(scheduled_tasks_impl.Health.needs_attention, item.health);
    try std.testing.expectEqual(
        scheduled_tasks_impl.FailureReason.execution_changed,
        item.failure_reason,
    );
    try std.testing.expect(item.next_run_at_unix_seconds == null);
    try std.testing.expect(clock.armed_at == null);
    try std.testing.expectEqual(@as(usize, 2), persistence.commits);
}

test "Skill catalog snapshot reports redaction without exposing credential bytes" {
    var workbench = try testWorkbench();
    defer workbench.deinit();
    const skills = [_]SkillProjection{.{
        .skill_id = "builtin.review",
        .skill_policy_key = "review",
        .invocation_name = "review",
        .provider_id = "agents.directory",
        .source_scope = .workspace,
        .source_instance_id = "agents.workspace.default",
        .contribution_id = "review",
        .content_revision = "review-v1",
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
        .selection_revision = 1,
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

test "Skill catalog slot preserves committed last-good authority" {
    const source_skills = [_]lifecycle.CatalogSkill{.{
        .skill_id = "builtin.review",
        .skill_policy_key = "review",
        .invocation_name = "review",
        .provider_id = "agents.directory",
        .source_scope = .workspace,
        .source_instance_id = "agents.workspace.default",
        .contribution_id = "review",
        .content_revision = "review-v1",
        .display_name = "Review",
        .description = "Review changes",
        .argument_names = &.{"target"},
        .max_values = 1,
    }};
    var snapshot = try CatalogSnapshot.init(
        std.testing.allocator,
        .{
            .revision = "catalog-1",
            .health = .healthy,
            .skills = &source_skills,
            .issues = &.{},
            .storage = undefined,
        },
        1,
        &.{},
        catalogSnapshotLimits(testLimits()),
        testLimits().max_projection_bytes,
    );
    var slot: CatalogSlot = .{ .committed = .{
        .lease = .fixture(),
        .snapshot = snapshot,
    } };
    snapshot = undefined;
    defer slot.committed.snapshot.deinit();

    try std.testing.expectEqual(CatalogAvailability.ready, slot.availability(false));
    try std.testing.expectEqual(CatalogAvailability.ready, slot.availability(true));
    try std.testing.expect(slot.snapshotConst() != null);

    const unavailable: CatalogSlot = .unavailable;
    try std.testing.expectEqual(CatalogAvailability.unavailable, unavailable.availability(false));
    try std.testing.expectEqual(CatalogAvailability.loading, unavailable.availability(true));
}

fn installTestCommittedSkillAuthorities(workbench: *Workbench) !void {
    const source_skills = [_]lifecycle.CatalogSkill{.{
        .skill_id = "builtin.review",
        .skill_policy_key = "review",
        .invocation_name = "review",
        .provider_id = "agents.directory",
        .source_scope = .user,
        .source_instance_id = "agents.user.default",
        .contribution_id = "review",
        .content_revision = "review-v1",
        .display_name = "Review",
        .description = "Review changes",
        .argument_names = &.{"target"},
        .max_values = 1,
    }};
    var personal_catalog = try CatalogSnapshot.init(
        workbench.allocator,
        .{
            .revision = "catalog-1",
            .health = .healthy,
            .skills = &source_skills,
            .issues = &.{},
            .storage = undefined,
        },
        1,
        &.{},
        catalogSnapshotLimits(workbench.limits),
        workbench.limits.max_projection_bytes - workbench.projection_bytes,
    );
    errdefer personal_catalog.deinit();
    var workspace_catalog = try personal_catalog.clone(
        workbench.allocator,
        catalogSnapshotLimits(workbench.limits),
        workbench.limits.max_projection_bytes -
            workbench.projection_bytes -
            personal_catalog.projected_bytes,
    );
    errdefer workspace_catalog.deinit();

    workbench.projection_bytes += personal_catalog.projected_bytes;
    workbench.skill_catalog_slot = .{ .committed = .{
        .lease = .fixture(),
        .snapshot = personal_catalog,
    } };
    workbench.projection_bytes += workspace_catalog.projected_bytes;
    workbench.workspaces[0].?.catalog_slot = .{ .committed = .{
        .lease = .fixture(),
        .snapshot = workspace_catalog,
    } };
}

test "definite Skill enablement persistence failure preserves committed authorities" {
    var workbench = try testWorkbench();
    defer workbench.deinit();
    workbench.skill_enablement_health = .ready;
    try installTestCommittedSkillAuthorities(&workbench);

    workbench.noteSkillEnablementPersistenceFailure(error.WriteFailed);

    try std.testing.expectEqual(SkillEnablementHealth.write_failed, workbench.skill_enablement_health);
    try std.testing.expect(workbench.skill_catalog_slot == .committed);
    try std.testing.expect(workbench.workspaces[0].?.catalog_slot == .committed);
    try std.testing.expectEqualStrings(
        "catalog-1",
        workbench.skill_catalog_slot.snapshotConst().?.revision,
    );
    try std.testing.expectEqualStrings(
        "catalog-1",
        workbench.workspaces[0].?.catalog_slot.snapshotConst().?.revision,
    );
}

test "unknown Skill enablement persistence outcome freezes authorities" {
    var workbench = try testWorkbench();
    defer workbench.deinit();
    workbench.skill_enablement_health = .ready;
    try installTestCommittedSkillAuthorities(&workbench);

    workbench.noteSkillEnablementPersistenceFailure(error.PersistenceOutcomeUnknown);

    try std.testing.expectEqual(SkillEnablementHealth.outcome_unknown, workbench.skill_enablement_health);
    try std.testing.expect(workbench.skill_catalog_slot == .unavailable);
    try std.testing.expect(workbench.workspaces[0].?.catalog_slot == .unavailable);
    try std.testing.expectError(
        error.PersistenceFailed,
        workbench.setSkillEnabled(.{
            .scope = .personal,
            .skill_policy_key = "review",
            .state = .disabled,
            .expected_catalog_revision = "catalog-1",
            .expected_selection_revision = 1,
        }),
    );
}

test "Workspace Skill enablement uses double revision CAS and leaves pinned catalogs unchanged" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var directory_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory_len = try tmp.dir.realPath(std.testing.io, &directory_storage);
    var file_store = try skill_enablement_impl.FileStore.init(
        std.testing.io,
        directory_storage[0..directory_len],
    );
    defer file_store.deinit();

    var workbench = try testWorkbench();
    defer workbench.deinit();
    workbench.skill_enablement_file_store = &file_store;
    workbench.skill_enablement_health = .ready;
    const source_skills = [_]lifecycle.CatalogSkill{.{
        .skill_id = "builtin.review",
        .skill_policy_key = "review",
        .invocation_name = "review",
        .provider_id = "agents.directory",
        .source_scope = .workspace,
        .source_instance_id = "agents.workspace.default",
        .contribution_id = "review",
        .content_revision = "review-v1",
        .display_name = "Review",
        .description = "Review changes",
        .argument_names = &.{"target"},
        .max_values = 1,
    }};
    const workspace_catalog = try CatalogSnapshot.init(
        workbench.allocator,
        .{
            .revision = "catalog-1",
            .health = .healthy,
            .skills = &source_skills,
            .issues = &.{},
            .storage = undefined,
        },
        1,
        &.{},
        catalogSnapshotLimits(workbench.limits),
        workbench.limits.max_projection_bytes - workbench.projection_bytes,
    );
    var pinned = try workspace_catalog.clone(
        workbench.allocator,
        catalogSnapshotLimits(workbench.limits),
        workbench.limits.max_projection_bytes -
            workbench.projection_bytes -
            workspace_catalog.projected_bytes,
    );
    defer pinned.deinit();
    workbench.projection_bytes += workspace_catalog.projected_bytes;
    workbench.workspaces[0].?.catalog_slot = .{ .committed = .{
        .lease = .fixture(),
        .snapshot = workspace_catalog,
    } };

    const next_revision = try workbench.setSkillEnabled(.{
        .scope = .{ .project = .{
            .workspace_id = 1,
            .expected_workspace_epoch = 1,
        } },
        .skill_policy_key = "review",
        .state = .disabled,
        .expected_catalog_revision = "catalog-1",
        .expected_selection_revision = 1,
    });
    try std.testing.expectEqual(@as(u64, 2), next_revision);
    try std.testing.expectEqual(
        @as(u64, 2),
        workbench.workspaces[0].?.catalog_slot.snapshotConst().?.selection_revision,
    );
    try std.testing.expect(!workbench.workspaces[0].?.catalog_slot.snapshotConst().?.skills[0].enabled);
    try std.testing.expectEqual(@as(u64, 1), pinned.selection_revision);
    try std.testing.expect(pinned.skills[0].enabled);
    try std.testing.expectError(
        error.StaleCatalog,
        workbench.setSkillEnabled(.{
            .scope = .{ .project = .{
                .workspace_id = 1,
                .expected_workspace_epoch = 1,
            } },
            .skill_policy_key = "review",
            .state = .enabled,
            .expected_catalog_revision = "catalog-1",
            .expected_selection_revision = 1,
        }),
    );
}

test "User Skill defaults stamp Personal and Workspace catalogs while project overrides stay local" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var directory_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory_len = try tmp.dir.realPath(std.testing.io, &directory_storage);
    var file_store = try skill_enablement_impl.FileStore.init(
        std.testing.io,
        directory_storage[0..directory_len],
    );
    defer file_store.deinit();

    var workbench = try testWorkbench();
    defer workbench.deinit();
    workbench.skill_enablement_file_store = &file_store;
    workbench.skill_enablement_health = .ready;
    const source_skills = [_]lifecycle.CatalogSkill{.{
        .skill_id = "builtin.review",
        .skill_policy_key = "review",
        .invocation_name = "review",
        .provider_id = "agents.directory",
        .source_scope = .workspace,
        .source_instance_id = "agents.workspace.default",
        .contribution_id = "review",
        .content_revision = "review-v1",
        .display_name = "Review",
        .description = "Review changes",
        .argument_names = &.{"target"},
        .max_values = 1,
    }};
    const personal_catalog = try CatalogSnapshot.init(
        workbench.allocator,
        .{
            .revision = "personal-1",
            .health = .healthy,
            .skills = &source_skills,
            .issues = &.{},
            .storage = undefined,
        },
        1,
        &.{},
        catalogSnapshotLimits(workbench.limits),
        workbench.limits.max_projection_bytes - workbench.projection_bytes,
    );
    workbench.projection_bytes += personal_catalog.projected_bytes;
    workbench.skill_catalog_slot = .{ .committed = .{
        .lease = .fixture(),
        .snapshot = personal_catalog,
    } };

    const workspace_catalog = try CatalogSnapshot.init(
        workbench.allocator,
        .{
            .revision = "workspace-1",
            .health = .healthy,
            .skills = &source_skills,
            .issues = &.{},
            .storage = undefined,
        },
        1,
        &.{},
        catalogSnapshotLimits(workbench.limits),
        workbench.limits.max_projection_bytes - workbench.projection_bytes,
    );
    workbench.projection_bytes += workspace_catalog.projected_bytes;
    workbench.workspaces[0].?.catalog_slot = .{ .committed = .{
        .lease = .fixture(),
        .snapshot = workspace_catalog,
    } };

    try std.testing.expectEqual(@as(u64, 2), try workbench.setSkillEnabled(.{
        .scope = .personal,
        .skill_policy_key = "review",
        .state = .disabled,
        .expected_catalog_revision = "personal-1",
        .expected_selection_revision = 1,
    }));
    try std.testing.expectEqual(@as(u64, 2), workbench.skill_catalog_slot.snapshotConst().?.selection_revision);
    try std.testing.expectEqual(@as(u64, 2), workbench.workspaces[0].?.catalog_slot.snapshotConst().?.selection_revision);
    try std.testing.expect(!workbench.skill_catalog_slot.snapshotConst().?.skills[0].enabled);
    try std.testing.expect(!workbench.workspaces[0].?.catalog_slot.snapshotConst().?.skills[0].enabled);

    try std.testing.expectEqual(@as(u64, 3), try workbench.setSkillEnabled(.{
        .scope = .{ .project = .{
            .workspace_id = 1,
            .expected_workspace_epoch = 1,
        } },
        .skill_policy_key = "review",
        .state = .enabled,
        .expected_catalog_revision = "workspace-1",
        .expected_selection_revision = 2,
    }));
    try std.testing.expect(!workbench.skill_catalog_slot.snapshotConst().?.skills[0].enabled);
    try std.testing.expect(workbench.workspaces[0].?.catalog_slot.snapshotConst().?.skills[0].enabled);
    try std.testing.expectEqual(@as(u64, 2), workbench.skill_catalog_slot.snapshotConst().?.selection_revision);
    try std.testing.expectEqual(@as(u64, 3), workbench.workspaces[0].?.catalog_slot.snapshotConst().?.selection_revision);

    try std.testing.expectEqual(@as(u64, 4), try workbench.setSkillEnabled(.{
        .scope = .{ .project = .{
            .workspace_id = 1,
            .expected_workspace_epoch = 1,
        } },
        .skill_policy_key = "review",
        .state = .inherit,
        .expected_catalog_revision = "workspace-1",
        .expected_selection_revision = 3,
    }));
    try std.testing.expect(!workbench.workspaces[0].?.catalog_slot.snapshotConst().?.skills[0].enabled);

    var personal_storage: [1024]u8 = undefined;
    var personal_writer = std.Io.Writer.fixed(&personal_storage);
    try workbench.writeSkillAssetTail(
        &personal_writer,
        &.{"target"},
        1,
        false,
        false,
        .personal,
        "review",
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        personal_writer.buffered(),
        "\"enabled\":false,\"enablementState\":\"disabled\",\"canSetEnabled\":true",
    ) != null);

    var project_storage: [1024]u8 = undefined;
    var project_writer = std.Io.Writer.fixed(&project_storage);
    try workbench.writeSkillAssetTail(
        &project_writer,
        &.{"target"},
        1,
        false,
        false,
        .{ .project = .{ .workspace_id = 1, .workspace_epoch = 1 } },
        "review",
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        project_writer.buffered(),
        "\"enabled\":false,\"enablementState\":\"inherit\",\"canSetEnabled\":true",
    ) != null);
}

test "User Skill mutation does not require every Workspace to have committed authority" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var directory_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory_len = try tmp.dir.realPath(std.testing.io, &directory_storage);
    var file_store = try skill_enablement_impl.FileStore.init(
        std.testing.io,
        directory_storage[0..directory_len],
    );
    defer file_store.deinit();

    var workbench = try testWorkbench();
    defer workbench.deinit();
    workbench.skill_enablement_file_store = &file_store;
    workbench.skill_enablement_health = .ready;
    const source_skills = [_]lifecycle.CatalogSkill{.{
        .skill_id = "builtin.review",
        .skill_policy_key = "review",
        .invocation_name = "review",
        .provider_id = "agents.directory",
        .source_scope = .user,
        .source_instance_id = "agents.user.default",
        .contribution_id = "review",
        .content_revision = "review-v1",
        .display_name = "Review",
        .description = "Review changes",
        .argument_names = &.{"target"},
        .max_values = 1,
    }};
    const personal_catalog = try CatalogSnapshot.init(
        workbench.allocator,
        .{
            .revision = "personal-1",
            .health = .healthy,
            .skills = &source_skills,
            .issues = &.{},
            .storage = undefined,
        },
        1,
        &.{},
        catalogSnapshotLimits(workbench.limits),
        workbench.limits.max_projection_bytes - workbench.projection_bytes,
    );
    workbench.projection_bytes += personal_catalog.projected_bytes;
    workbench.skill_catalog_slot = .{ .committed = .{
        .lease = .fixture(),
        .snapshot = personal_catalog,
    } };

    try std.testing.expectEqual(@as(u64, 2), try workbench.setSkillEnabled(.{
        .scope = .personal,
        .skill_policy_key = "review",
        .state = .disabled,
        .expected_catalog_revision = "personal-1",
        .expected_selection_revision = 1,
    }));
    try std.testing.expectEqual(
        @as(u64, 2),
        workbench.skill_enablement.revision(.{
            .workspace_id = 1,
            .workspace_epoch = 1,
        }),
    );
    try std.testing.expect(workbench.workspaces[0].?.catalog_slot == .uninitialized);
}

test "credential release permanently scrubs catalog and every Skill history field" {
    var workbench = try testWorkbench();
    defer workbench.deinit();
    const source_skills = [_]lifecycle.CatalogSkill{.{
        .skill_id = "builtin.review",
        .skill_policy_key = "review",
        .invocation_name = "review",
        .provider_id = "agents.directory",
        .source_scope = .workspace,
        .source_instance_id = "agents.workspace.default",
        .contribution_id = "review",
        .content_revision = "review-v1",
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
        1,
        &.{},
        catalogSnapshotLimits(workbench.limits),
        workbench.limits.max_projection_bytes - workbench.projection_bytes,
    );
    const task_catalog = try workspace_catalog.clone(
        workbench.allocator,
        catalogSnapshotLimits(workbench.limits),
        workbench.limits.max_projection_bytes -
            workbench.projection_bytes -
            workspace_catalog.projected_bytes,
    );
    workbench.projection_bytes += workspace_catalog.projected_bytes;
    workbench.workspaces[0].?.catalog_slot = .{ .committed = .{
        .lease = .fixture(),
        .snapshot = workspace_catalog,
    } };
    workbench.projection_bytes += task_catalog.projected_bytes;
    const task = &workbench.tasks[0].?;
    task.runtime.attached().?.pinned_catalog = task_catalog;
    const run = &task.durable.runs[0].?;
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
    var detached = task.runtime.detach(.cold_start);
    var detached_execution = detached.execution;
    detached_execution.deinit();
    if (detached.pinned_catalog) |*snapshot| {
        workbench.projection_bytes -= snapshot.projected_bytes;
        snapshot.deinit();
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
    try std.testing.expect(workbench.workspaces[0].?.catalog_slot.snapshotConst().?.redacted);
    try std.testing.expect(task.runtime.pinnedCatalogConst() == null);
}

test "mutation admission rejects stale execution and binding facts" {
    var workbench = try testWorkbench();
    defer workbench.deinit();

    try std.testing.expectError(
        error.ExecutionGenerationMismatch,
        workbench.createTaskInWorkspace(1, 1, 0, null, null),
    );
    try std.testing.expectError(
        error.ExecutionGenerationMismatch,
        workbench.createTaskInWorkspace(1, 1, 2, null, null),
    );
    try std.testing.expectError(
        error.WorkspaceEpochMismatch,
        workbench.createTaskInWorkspace(1, 2, 1, null, null),
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
    try std.testing.expectError(error.TaskNotArchived, workbench.deleteTask(3));
    try std.testing.expectError(error.InvalidTaskTitle, workbench.renameTask(3, "  \n  "));
    try std.testing.expectError(error.InvalidTaskTitle, workbench.renameTask(3, "bad\ttitle"));
    try std.testing.expectError(error.InvalidTaskTitle, workbench.renameTask(3, &.{0xff}));

    try workbench.renameTask(3, "Review release readiness");
    try std.testing.expectEqualStrings("Review release readiness", workbench.tasks[0].?.durable.title);

    workbench.tasks[0].?.runtime.active_run_id = 0;
    const completed = &workbench.tasks[0].?.durable.runs[0].?;
    _ = commitTerminal(completed, .completed, .completed, null, .reusable, "", false);
    finalizeTestTerminalEvents(&workbench);
    try workbench.setTaskArchived(3, true);
    try std.testing.expect(workbench.tasks[0].?.durable.archived);

    workbench.tasks[0].?.runtime.active_operation = .{ .restore = .{ .id = 1 } };
    try std.testing.expectError(error.TaskBusy, workbench.setTaskArchived(3, false));
    workbench.tasks[0].?.runtime.active_operation = .none;
    workbench.tasks[0].?.deletion = .failed;
    try workbench.setTaskArchived(3, false);
    try std.testing.expectEqual(task_deletion.State.idle, workbench.tasks[0].?.deletion);
    try workbench.setTaskArchived(3, true);
    workbench.releaseTaskAttachmentNoFail(&workbench.tasks[0].?, .cold_start);
    workbench.tasks[0].?.runtime.worker_references.store(1, .release);
    try workbench.deleteTask(3);
    try std.testing.expect(workbench.tasks[0] != null);
    try std.testing.expectError(error.TaskBusy, workbench.renameTask(3, "too late"));
    workbench.tasks[0].?.runtime.worker_references.store(0, .release);
    const tracked_before_delete = workbench.projection_bytes;
    _ = workbench.currentRevision();
    try std.testing.expect(workbench.tasks[0] == null);
    try std.testing.expect(workbench.projection_bytes < tracked_before_delete);
    try std.testing.expectError(error.UnknownTask, workbench.renameTask(3, "gone"));
}

test "Run admission reserves a stable generation and rolls back every fallible allocation" {
    var workbench = try testWorkbench();
    defer workbench.deinit();
    const task = &workbench.tasks[0].?;
    const tracked_before = workbench.projection_bytes;
    const generation_before = task.durable.next_run_generation;
    var oversized_prompt: [1025]u8 = undefined;
    @memset(&oversized_prompt, 'x');
    try std.testing.expectError(
        error.ProjectionCapacity,
        workbench.reserveRunRecord(task, .{ .text = &oversized_prompt }),
    );
    try std.testing.expectEqual(tracked_before, workbench.projection_bytes);
    try std.testing.expectEqual(generation_before, task.durable.next_run_generation);

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
    try std.testing.expectEqual(generation_before, task.durable.next_run_generation);

    const slot = try workbench.reserveRunRecord(task, .{ .text = "reserved" });
    const first_generation = task.durable.runs[slot].?.generation;
    try std.testing.expectEqual(
        task.durable.execution_generation,
        task.durable.runs[slot].?.execution_generation,
    );
    try std.testing.expectEqual(
        task.durable.execution_provider,
        task.durable.runs[slot].?.execution_provider,
    );
    try std.testing.expectEqualStrings(
        task.durable.execution_model,
        task.durable.runs[slot].?.execution_model,
    );
    workbench.discardRunRecord(task, slot);
    const reused_slot = try workbench.reserveRunRecord(
        task,
        .{ .text = "reserved again" },
    );
    try std.testing.expectEqual(slot, reused_slot);
    try std.testing.expect(task.durable.runs[reused_slot].?.generation > first_generation);
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
        std.testing.io,
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

test "Workbench publishes a user model connection as an independent execution source" {
    test_agent_runtime.io = std.testing.io;
    var workbench = try Workbench.init(
        std.testing.allocator,
        std.testing.io,
        &test_agent_runtime,
        .{
            .max_tasks = 1,
            .max_runs_per_task = 1,
            .max_tools_per_run = 1,
        },
        .{},
    );
    defer workbench.deinit();
    const models = [_]account_contract.ModelConnectionModelView{.{
        .id = "gpt-5",
        .display_name = "GPT-5",
    }};
    const connections = [_]account_contract.ModelConnectionView{.{
        .id = "connection-1",
        .display_name = "Team OpenAI",
        .protocol = .openai_chat_completions,
        .normalized_base_url = "https://api.openai.com/v1/chat/completions",
        .state = .ready,
        .test_status = .connected,
        .credential_status = .ready,
        .enabled = true,
        .models = &models,
        .selected_model = "gpt-5",
        .connection_generation = 1,
    }};
    workbench.commitAccountFactNoFail(.{
        .kind = .model_connections_changed,
        .view = .{
            .state = .signed_out,
            .catalog_state = .unavailable,
            .model_connections = &connections,
        },
    });
    var execution = try account_contract.OwnedExecutionConfig.initModelConnectionOwned(
        std.testing.allocator,
        .openai,
        try std.testing.allocator.dupe(u8, "gpt-5"),
        try std.testing.allocator.dupe(u8, "https://api.openai.com/v1/chat/completions"),
        1,
        try std.testing.allocator.dupe(u8, "secret-key"),
    );
    errdefer execution.deinit();
    var prepared_binding = try workbench.prepareModelConnectionBinding(
        "connection-1",
        "gpt-5",
    );
    var prepared_binding_owned = true;
    defer if (prepared_binding_owned) prepared_binding.deinit();
    try workbench.beginDefaultExecutionReplacement();
    workbench.installModelConnectionExecutionNoFail(
        &execution,
        &prepared_binding,
    );
    prepared_binding_owned = false;
    workbench.endExecutionReplacementNoFail();
    const view = workbench.accountView();
    try std.testing.expectEqual(account_contract.ExecutionSource.model_connection, view.execution_source);
    try std.testing.expectEqual(account_contract.AccountState.signed_out, view.state);
    try std.testing.expectEqual(account_contract.CatalogState.unavailable, view.catalog_state);
    try std.testing.expect(view.can_create_task);
    try std.testing.expectEqualStrings("", view.selected_model);
    try std.testing.expectEqualStrings("gpt-5", view.model_connections[0].selected_model);
    try std.testing.expectEqualStrings(
        "connection-1",
        view.selected_model_connection_id,
    );
    try std.testing.expect(workbench.modelConnectionExecutionActive("connection-1"));
    try std.testing.expect(!workbench.modelConnectionExecutionActive("connection-2"));
    try account_contract.validateModelConnectionSpec(.{
        .display_name = "Team OpenAI",
        .protocol = .openai_chat_completions,
        .normalized_base_url = "https://api.openai.com/v1/chat/completions",
    });
}

test "Account projection and execution install use preallocated no-fail storage" {
    test_agent_runtime.io = std.testing.io;
    var workbench = try Workbench.init(
        std.testing.allocator,
        std.testing.io,
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
            .state = .authenticated,
            .catalog_state = .ready,
            .account_id = "account-1",
            .display_name = "Metask User",
            .api_keys = &api_keys,
            .models = &models,
            .selected_api_key_id = "key-1",
            .selected_model = "model-1",
            .model_catalog_api_key_id = "key-1",
            .can_create_task = true,
            .catalog_generation = 2,
            .metask_execution_generation = 1,
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

test "identity replacement does not disturb live Task runtime references" {
    var workbench = try testWorkbench();
    defer workbench.deinit();
    try workbench.beginDefaultExecutionReplacement();
    try std.testing.expect(workbench.executionReplacementPending());
    try std.testing.expect(!workbench.accountView().can_create_task);
    workbench.endExecutionReplacementNoFail();
    const task = &workbench.tasks[0].?;
    const route_id = task.runtime.routeId();
    const execution = task.runtime.executionConst().?;
    try workbench.beginExecutionReplacement();
    try std.testing.expect(workbench.executionReplacementPending());
    try std.testing.expectEqual(route_id, task.runtime.routeId());
    try std.testing.expectEqual(execution, task.runtime.executionConst().?);
    workbench.endExecutionReplacementNoFail();

    task.durable.runs[0].?.active_phase = .completed;
    task.runtime.active_run_id = 0;
    task.runtime.worker_references.store(1, .release);
    try workbench.beginExecutionReplacement();
    try std.testing.expect(workbench.executionReplacementPending());
    try std.testing.expectEqual(@as(usize, 1), task.runtime.worker_references.load(.acquire));
    try std.testing.expectEqual(route_id, task.runtime.routeId());
    try std.testing.expectEqual(execution, task.runtime.executionConst().?);
    try std.testing.expectEqual(TaskLifecycle.open, taskLifecycle(task));
    try std.testing.expectEqualStrings("fixture-model", task.durable.execution_model);
    try std.testing.expect(!workbench.accountView().can_create_task);
    workbench.endExecutionReplacementNoFail();
    try std.testing.expect(workbench.accountView().can_create_task);
    task.runtime.worker_references.store(0, .release);
}

test "default replacement preserves Task generation and installs the next admission default" {
    var workbench = try testWorkbench();
    defer workbench.deinit();

    const task = &workbench.tasks[0].?;
    try workbench.replaceTracked(
        &task.durable.title,
        "review future metawork credential",
        workbench.limits.max_task_title_bytes,
    );
    try workbench.replaceTracked(
        &task.durable.runs[0].?.status_text,
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
            .state = .authenticated,
            .catalog_state = .ready,
            .account_id = "account-1",
            .display_name = "Metask User",
            .api_keys = &replacement_api_keys,
            .models = &replacement_models,
            .selected_api_key_id = "key-2",
            .selected_model = "fixture-model-2",
            .model_catalog_api_key_id = "key-2",
            .can_create_task = true,
            .metask_execution_generation = 2,
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
    try std.testing.expectEqualStrings("fixture-model", task.durable.execution_model);
    try std.testing.expect(std.mem.indexOf(u8, task.durable.title, "metawork") == null);
    try std.testing.expect(std.mem.indexOf(u8, task.durable.runs[0].?.status_text, "metawork") == null);
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
    try std.testing.expectEqual(@as(u64, 1), task.durable.runs[slot].?.execution_generation);
    try std.testing.expectEqualStrings(
        "old *** remains private",
        task.durable.runs[slot].?.input.text.value,
    );
    try std.testing.expectEqualStrings("SECRET-KEY", task.durable.runs[slot].?.redaction_secret);

    task.durable.execution_generation = 2;
    try std.testing.expectError(
        error.ExecutionGenerationMismatch,
        Workbench.taskExecutionInput(task),
    );
    try std.testing.expectError(
        error.ExecutionGenerationMismatch,
        workbench.runTask(
            task.durable.id,
            .{ .text = "must reject a mismatched binding" },
        ),
    );
    task.durable.execution_generation = 1;
}

test "Account default model changes do not bump credentials" {
    var workbench = try testWorkbench();
    defer workbench.deinit();

    const api_keys = [_]account_contract.ApiKeyView{.{
        .id = "key-1",
        .name = "Primary",
        .suffix = "1234",
        .provider_kind = .anthropic,
    }};
    const models = [_]account_contract.ModelView{
        .{ .id = "fixture-model", .display_name = "Fixture model" },
        .{ .id = "fixture-model-2", .display_name = "Fixture model 2" },
    };
    workbench.commitAccountFactNoFail(.{
        .kind = .catalog_changed,
        .view = .{
            .state = .authenticated,
            .catalog_state = .ready,
            .account_id = "account-1",
            .display_name = "Metask User",
            .api_keys = &api_keys,
            .models = &models,
            .selected_api_key_id = "key-1",
            .selected_model = "fixture-model-2",
            .model_catalog_api_key_id = "key-1",
            .can_create_task = true,
            .metask_execution_generation = 1,
            .execution_generation = 1,
        },
    });
    workbench.finishAccountCommitNoFail();

    try std.testing.expectEqual(@as(u64, 1), workbench.execution.generation);
    try std.testing.expectEqualStrings(
        "fixture-model-2",
        workbench.accountView().selected_model,
    );
}

test "busy Task model selection keeps only the last runtime pending model" {
    var workbench = try testWorkbench();
    defer workbench.deinit();

    const api_keys = [_]account_contract.ApiKeyView{.{
        .id = "key-1",
        .name = "Primary",
        .suffix = "1234",
        .provider_kind = .anthropic,
    }};
    const models = [_]account_contract.ModelView{
        .{ .id = "fixture-model", .display_name = "Fixture model" },
        .{ .id = "fixture-model-2", .display_name = "Fixture model 2" },
        .{ .id = "fixture-model-3", .display_name = "Fixture model 3" },
    };
    workbench.commitAccountFactNoFail(.{
        .kind = .catalog_changed,
        .view = .{
            .state = .authenticated,
            .catalog_state = .ready,
            .account_id = "account-1",
            .display_name = "Metask User",
            .api_keys = &api_keys,
            .models = &models,
            .selected_api_key_id = "key-1",
            .selected_model = "fixture-model",
            .model_catalog_api_key_id = "key-1",
            .can_create_task = true,
            .catalog_generation = 2,
            .metask_execution_generation = 1,
            .execution_generation = 1,
        },
    });

    const task = &workbench.tasks[0].?;
    const binding_epoch = task.durable.binding_epoch;
    try workbench.selectTaskModel(task.durable.id, "fixture-model", 2, "fixture-model-2");
    try std.testing.expectEqualStrings("fixture-model", task.durable.execution_model);
    try std.testing.expectEqualStrings("fixture-model-2", task.runtime.pending_model.?);
    try std.testing.expectEqual(binding_epoch, task.durable.binding_epoch);
    try std.testing.expectEqual(@as(u64, 1), task.durable.execution_generation);

    try workbench.selectTaskModel(task.durable.id, "fixture-model", 2, "fixture-model-3");
    try std.testing.expectEqualStrings("fixture-model-3", task.runtime.pending_model.?);
    try std.testing.expectEqualStrings("fixture-model", task.durable.execution_model);
    try std.testing.expectError(
        error.TaskModelMismatch,
        workbench.selectTaskModel(task.durable.id, "fixture-model-2", 2, "fixture-model"),
    );
}

test "clearing the admission default preserves active Task execution" {
    var workbench = try testWorkbench();
    defer workbench.deinit();

    const task = &workbench.tasks[0].?;
    const task_execution = try Workbench.taskExecutionInput(task);
    try std.testing.expectEqualStrings("SECRET-KEY", task_execution.api_key);

    try workbench.beginDefaultExecutionReplacement();
    workbench.commitAccountFactNoFail(.{
        .kind = .signed_out,
        .view = .{
            .state = .signed_out,
            .catalog_state = .unavailable,
            .can_create_task = false,
            .execution_generation = 0,
        },
    });
    workbench.clearExecutionNoFail();
    workbench.endExecutionReplacementNoFail();
    workbench.finishAccountCommitNoFail();

    try std.testing.expect(!workbench.execution.ready());
    try std.testing.expect(!workbench.accountView().can_create_task);
    const preserved = try Workbench.taskExecutionInput(task);
    try std.testing.expectEqual(@as(u64, 1), preserved.execution_generation);
    try std.testing.expectEqualStrings("fixture-model", preserved.target.model);
    try std.testing.expectEqualStrings("SECRET-KEY", preserved.api_key);
}

test "released Task credential is permanently scrubbed from every product projection" {
    var workbench = try testWorkbench();
    defer workbench.deinit();
    const task = &workbench.tasks[0].?;
    const run = &task.durable.runs[0].?;

    try workbench.replaceTracked(
        &task.durable.title,
        "title SECRET-KEY",
        workbench.limits.max_task_title_bytes,
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
    task.durable.ui_history[0] = .{
        .request_id = 8,
        .run_id = run.id,
        .kind = .permission,
        .state = .denied,
    };
    @memcpy(task.durable.ui_history[0].?.detail[0.."SECRET-KEY".len], "SECRET-KEY");
    task.durable.ui_history[0].?.detail_len = "SECRET-KEY".len;
    task.durable.ui_history_count = 1;
    const compact_slot = try workbench.reserveCompactRecord(task, 9, run.id);
    const compact = &task.durable.compacts[compact_slot].?;
    try std.testing.expectEqualStrings("SECRET-KEY", compact.redaction_secret);
    try workbench.replaceTracked(
        &task.durable.execution_model,
        "model-SECRET-KEY",
        account_contract.Limits.model_id_bytes,
    );

    run.active_phase = .completed;
    workbench.releaseTaskAttachmentNoFail(task, .cold_start);
    task.runtime.active_run_id = 0;
    try workbench.beginExecutionReplacement();
    try std.testing.expect(task.runtime.executionConst() == null);
    try std.testing.expectEqual(@as(usize, 0), run.redaction_secret.len);
    try std.testing.expectEqual(@as(usize, 0), compact.redaction_secret.len);
    try std.testing.expect(std.mem.indexOf(u8, task.durable.execution_model, "SECRET-KEY") == null);
    var snapshot_storage: [96 * 1024]u8 = undefined;
    const snapshot = try workbench.writeSnapshot(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "SECRET-KEY") == null);
    workbench.endExecutionReplacementNoFail();
}

test "clearing the last default execution scrubs its credential before secure zero" {
    test_agent_runtime.io = std.testing.io;
    var workbench = try Workbench.init(
        std.testing.allocator,
        std.testing.io,
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
    try workbench.beginDefaultExecutionReplacement();
    workbench.commitAccountFactNoFail(.{
        .kind = .signed_out,
        .view = .{
            .state = .signed_out,
            .catalog_state = .unavailable,
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
        &workbench.tasks[0].?.durable.runs[0].?.status_text,
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
        task.durable.runs[slot].?.input.text.value,
    );
    try std.testing.expect(std.unicode.utf8ValidateSlice(
        task.durable.runs[slot].?.input.text.value,
    ));

    var tool_event = try testEnvelope(
        task.runtime.routeId(),
        7,
        "{\"tool_start\":{\"id\":\"tool-1\",\"name\":\"café\",\"input\":\"café\"}}",
    );
    defer tool_event.deinit();
    try workbench.applyEvent(&tool_event);
    const tool = &task.durable.runs[0].?.tools[0].?;
    try std.testing.expectEqualStrings("caf**", tool.name);
    try std.testing.expectEqualStrings("caf**", tool.input);
    try std.testing.expect(std.unicode.utf8ValidateSlice(tool.name));
    try std.testing.expect(std.unicode.utf8ValidateSlice(tool.input));

    const request = testPermissionRequest("café", "café");
    var pending_storage: [4096]u8 = undefined;
    var pending_writer = std.Io.Writer.fixed(&pending_storage);
    try task_view.writePendingUi(
        &pending_writer,
        workbench.taskTextProjection(),
        9,
        7,
        1,
        request,
    );
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
    const task = &workbench.tasks[0].?;
    task.runtime.attached().?.binding = task_agent_session.Binding.testFixture(99);

    var routed = try testEnvelope(99, 7, "{\"text_chunk\":\"routed\"}");
    defer routed.deinit();
    try workbench.applyEvent(&routed);
    try std.testing.expectEqual(@as(u64, 3), workbench.tasks[0].?.durable.id);
    try std.testing.expectEqualStrings(
        "routed",
        workbench.tasks[0].?.durable.runs[0].?.assistant.list.items,
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
    const before = workbench.tasks[0].?.durable.recent_order;

    var text = try testEnvelope(3, 7, "{\"text_chunk\":\"streaming\"}");
    defer text.deinit();
    try workbench.applyEvent(&text);
    try std.testing.expectEqual(before, workbench.tasks[0].?.durable.recent_order);

    var usage = try testEnvelope(
        3,
        7,
        "{\"usage\":{\"input_tokens\":1,\"output_tokens\":1,\"cache_read_input_tokens\":0,\"cache_creation_input_tokens\":0}}",
    );
    defer usage.deinit();
    try workbench.applyEvent(&usage);
    try std.testing.expectEqual(before, workbench.tasks[0].?.durable.recent_order);
}

test "thinking and assistant chunks update distinct safe projections" {
    var workbench = try testWorkbench();
    defer workbench.deinit();
    const task = &workbench.tasks[0].?;
    const run = &task.durable.runs[0].?;
    const route = task.runtime.routeId();

    const revision_before_thinking = workbench.revision;
    var thinking = try testEnvelope(
        route,
        7,
        "{\"thinking_chunk\":\"private-reasoning-marker\"}",
    );
    defer thinking.deinit();
    try workbench.applyEvent(&thinking);
    try std.testing.expectEqualStrings("", run.assistant.list.items);
    try std.testing.expectEqualStrings("Thinking", run.status_text);
    try std.testing.expectEqual(revision_before_thinking + 1, workbench.revision);

    const revision_before_duplicate = workbench.revision;
    var duplicate = try testEnvelope(
        route,
        7,
        "{\"thinking_chunk\":\"more-private-reasoning\"}",
    );
    defer duplicate.deinit();
    try workbench.applyEvent(&duplicate);
    try std.testing.expectEqual(revision_before_duplicate, workbench.revision);

    var assistant = try testEnvelope(
        route,
        7,
        "{\"text_chunk\":\"public response\"}",
    );
    defer assistant.deinit();
    try workbench.applyEvent(&assistant);
    try std.testing.expectEqualStrings("public response", run.assistant.list.items);
    try std.testing.expectEqualStrings("Writing response", run.status_text);

    var snapshot_storage: [96 * 1024]u8 = undefined;
    const snapshot = try workbench.writeSnapshot(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "private-reasoning-marker") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "more-private-reasoning") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "public response") != null);
}

test "AgentCore RunState refines status without owning RunPhase and rejects stale transitions" {
    var workbench = try testWorkbench();
    defer workbench.deinit();
    const task = &workbench.tasks[0].?;
    const route = task.runtime.routeId();

    var starting = try testEnvelope(
        route,
        7,
        "{\"run_state\":{\"run_id\":7,\"transition_seq\":1,\"phase\":\"starting\",\"turn\":0,\"tool_calls\":0,\"in_flight_tools\":[]}}",
    );
    defer starting.deinit();
    const run = &task.durable.runs[0].?;
    run.active_phase = .queued;
    const host_phase = run.active_phase;
    try workbench.applyEvent(&starting);
    try std.testing.expectEqual(lifecycle.RunStatePhase.starting, run.agent_phase.?);
    try std.testing.expectEqual(@as(u64, 1), run.agent_transition_seq.?);
    try std.testing.expectEqual(host_phase, run.active_phase);
    try std.testing.expectEqualStrings("Starting", run.status_text);

    var executing = try testEnvelope(
        route,
        7,
        "{\"run_state\":{\"run_id\":7,\"transition_seq\":2,\"phase\":\"executing_tools\",\"turn\":1,\"tool_calls\":2,\"in_flight_tools\":[{\"tool_call_id\":\"tool-1\",\"name\":\"Read\"},{\"tool_call_id\":\"tool-2\",\"name\":\"Bash\"}]}}",
    );
    defer executing.deinit();
    try workbench.applyEvent(&executing);
    try std.testing.expectEqual(lifecycle.RunStatePhase.executing_tools, run.agent_phase.?);
    try std.testing.expectEqual(@as(u32, 1), run.agent_turn);
    try std.testing.expectEqual(@as(u32, 2), run.agent_tool_calls);
    try std.testing.expectEqual(@as(u32, 2), run.agent_in_flight_tools);
    try std.testing.expectEqualStrings("Executing tools", run.status_text);

    var stale = try testEnvelope(
        route,
        7,
        "{\"run_state\":{\"run_id\":7,\"transition_seq\":1,\"phase\":\"failed\",\"turn\":9,\"tool_calls\":9,\"in_flight_tools\":[]}}",
    );
    defer stale.deinit();
    try workbench.applyEvent(&stale);
    try std.testing.expectEqual(lifecycle.RunStatePhase.executing_tools, run.agent_phase.?);
    try std.testing.expectEqualStrings("Executing tools", run.status_text);

    var cross_run = try testEnvelope(
        route,
        7,
        "{\"run_state\":{\"run_id\":99,\"transition_seq\":3,\"phase\":\"failed\",\"turn\":9,\"tool_calls\":9,\"in_flight_tools\":[]}}",
    );
    defer cross_run.deinit();
    try workbench.applyEvent(&cross_run);
    try std.testing.expect(run.agent_observation_degraded);
    try std.testing.expectEqual(lifecycle.RunStatePhase.executing_tools, run.agent_phase.?);
    try std.testing.expectEqual(host_phase, run.active_phase);
}

test "AgentCore RunState accepts a zero first transition sequence" {
    var workbench = try testWorkbench();
    defer workbench.deinit();
    const task = &workbench.tasks[0].?;
    const route = task.runtime.routeId();
    var first = try testEnvelope(
        route,
        7,
        "{\"run_state\":{\"run_id\":7,\"transition_seq\":0,\"phase\":\"starting\",\"turn\":0,\"tool_calls\":0,\"in_flight_tools\":[]}}",
    );
    defer first.deinit();
    try workbench.applyEvent(&first);
    const run = &task.durable.runs[0].?;
    try std.testing.expectEqual(@as(u64, 0), run.agent_transition_seq.?);
    try std.testing.expectEqual(lifecycle.RunStatePhase.starting, run.agent_phase.?);
}

test "event projection failure routes by Agent Session identity not product Task identity" {
    var workbench = try testWorkbench();
    defer workbench.deinit();
    const task = &workbench.tasks[0].?;
    task.runtime.attached().?.binding = task_agent_session.Binding.testFixture(99);

    workbench.recordEventProjectionFailure(task.durable.id, 7);
    try std.testing.expect(task.durable.runs[0].?.event_projection_failure == null);
    try std.testing.expect(workbench.taskContinuationAvailable(task));

    workbench.recordEventProjectionFailure(task.runtime.routeId(), 7);
    try std.testing.expectEqual(
        EventProjectionFailure.consumer_rejected,
        task.durable.runs[0].?.event_projection_failure.?,
    );
    // The projection failure is a Run-level product fact. Continuation is
    // owned by the Session disposition and stays available.
    try std.testing.expect(workbench.taskContinuationAvailable(task));
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
            .state = .authenticated,
            .catalog_state = .ready,
            .account_id = "account-1",
            .display_name = "Metask User",
            .api_keys = &replacement_api_keys,
            .models = &replacement_models,
            .selected_api_key_id = "key-2",
            .selected_model = "fixture-model-2",
            .model_catalog_api_key_id = "key-2",
            .can_create_task = true,
            .metask_execution_generation = 2,
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
    const run = &workbench.tasks[0].?.durable.runs[0].?;
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

test "compact terminal publication is write-once and outranks late cancellation" {
    var diagnostic_storage: [32]u8 = undefined;
    var compact = CompactRecord{
        .id = 1,
        .after_run_id = 7,
        .terminal_diagnostic = &diagnostic_storage,
    };
    try std.testing.expectEqual(CompactPhase.queued, activeCompactPhase(&compact));
    try std.testing.expect(commitCompactProductTerminal(
        &compact,
        .compacted,
        null,
        .reusable,
        .{ .input_tokens = 5, .output_tokens = 2 },
        100,
        40,
        "terminal diagnostic",
        false,
    ));
    _ = compact.pending_interruption.cmpxchgStrong(
        .none,
        .user_cancel,
        .acq_rel,
        .acquire,
    );
    const terminal = compactTerminalPayload(&compact).?;
    try std.testing.expectEqual(CompactPhase.compacted, terminal.phase);
    try std.testing.expectEqual(@as(?CompactCause, null), terminal.cause);
    try std.testing.expectEqual(@as(u64, 100), terminal.before_context_tokens);
    try std.testing.expectEqual(@as(u64, 40), terminal.after_context_tokens);
    try std.testing.expectEqual(@as(u64, 5), terminal.usage.input_tokens);
    try std.testing.expectEqualStrings(
        "terminal diagnostic",
        compact.terminal_diagnostic[0..terminal.diagnostic_len],
    );
    try std.testing.expect(!commitCompactProductTerminal(
        &compact,
        .aborted,
        .user_cancel,
        .reusable,
        .{},
        0,
        0,
        "late mutation",
        false,
    ));
    try std.testing.expectEqual(CompactPhase.compacted, compactTerminalPayload(&compact).?.phase);
    try std.testing.expectEqual(@as(?CompactCause, null), compactTerminalPayload(&compact).?.cause);
}

test "terminal disposition folds exactly once without reopening a closing Task" {
    var workbench = try testWorkbench();
    defer workbench.deinit();
    const task = &workbench.tasks[0].?;
    defer detachTaskForTest(&workbench, task);

    foldTerminalDisposition(task, .poisoned);
    try std.testing.expectEqual(TaskLifecycle.open, taskLifecycle(task));
    try std.testing.expectEqual(
        ContinuationUnavailableReason.session_poisoned,
        workbench.taskContinuation(task).unavailable,
    );

    try std.testing.expect(task.runtime.beginClosing());
    foldTerminalDisposition(task, .reusable);
    try std.testing.expectEqual(TaskLifecycle.closing, taskLifecycle(task));
    try std.testing.expectEqual(
        ContinuationUnavailableReason.closing,
        workbench.taskContinuation(task).unavailable,
    );
}

test "canonical prompt title and terminal diagnostic never retain the registered credential" {
    var workbench = try testWorkbench();
    defer workbench.deinit();
    const task = &workbench.tasks[0].?;

    try workbench.renameTask(task.durable.id, "Review SECRET-KEY usage");
    try std.testing.expect(std.mem.indexOf(u8, task.durable.title, "SECRET-KEY") == null);
    try std.testing.expect(task.durable.title_redacted);

    const slot = try workbench.reserveRunRecord(
        task,
        .{ .text = "prompt SECRET-KEY payload" },
    );
    const run = &task.durable.runs[slot].?;
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
    task.durable.archived = true;
    workbench.releaseTaskAttachmentNoFail(task, .cold_start);
    task.runtime.active_run_id = 0;
    _ = commitTerminal(
        &task.durable.runs[0].?,
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
    const run = findRun(workbench.tasks[0].?.durable.runs, 7).?;
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
    try std.testing.expectEqual(@as(usize, 1536 * 1024), limits.max_projection_bytes);
    try std.testing.expectEqual(@as(usize, 16), limits.max_runs_per_task);
    const single_pending_budget = limits.max_pending_ui_json_bytes * pending_ui_reencode_expansion + pending_ui_snapshot_overhead;
    try std.testing.expect(worst_case >= single_pending_budget * limits.max_pending_ui_requests);

    var workbench = try testWorkbench();
    defer workbench.deinit();
    const run = findRun(workbench.tasks[0].?.durable.runs, 7).?;
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
            .state = .authenticated,
            .catalog_state = .ready,
            .account_id = &account_id,
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
            .metask_execution_generation = std.math.maxInt(u64),
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
        std.testing.io,
        &test_agent_runtime,
        limits,
        .{},
    );
    defer workbench.deinit();
    try installMaximumAccountProjection(&workbench);

    for (0..limits.max_tasks) |task_index| {
        var root_storage: [64]u8 = undefined;
        const root = try std.fmt.bufPrint(
            &root_storage,
            "/maximum-task-{d}",
            .{task_index + 1},
        );
        workbench.workspaces[task_index] = .{
            .id = @intCast(task_index + 1),
            .canonical_root = try workbench.copyBounded(root, limits.max_workspace_bytes),
            .projected_root_storage = try workbench.copyBounded(root, limits.max_workspace_bytes),
            .projected_root_len = root.len,
            .display_name_storage = try workbench.copyBounded("maximum", limits.max_workspace_bytes),
            .display_name_len = "maximum".len,
            .trust = .explicitly_trusted,
            .recent_order = @intCast(task_index + 1),
        };
        const execution_model = try workbench.copyBounded(
            "fixture-model",
            account_contract.Limits.model_id_bytes,
        );
        const runs = try workbench.allocator.alloc(?RunRecord, limits.max_runs_per_task);
        @memset(runs, null);
        const compacts = try workbench.allocator.alloc(
            ?CompactRecord,
            limits.max_compacts_per_task,
        );
        @memset(compacts, null);
        const ui_history = try workbench.allocator.alloc(?UiRecord, limits.max_ui_history_per_task);
        @memset(ui_history, null);
        for (0..limits.max_runs_per_task) |run_index| {
            const tools = try workbench.allocator.alloc(?ToolView, limits.max_tools_per_run);
            @memset(tools, null);
            for (0..limits.max_tools_per_run) |tool_index| {
                var tool_id_storage: [32]u8 = undefined;
                const tool_id = try std.fmt.bufPrint(
                    &tool_id_storage,
                    "tool-{d}",
                    .{tool_index + 1},
                );
                tools[tool_index] = .{
                    .route_digest = toolRouteDigest(""),
                    .id = try workbench.copyBounded(tool_id, limits.max_tool_field_bytes),
                    .order = @intCast(tool_index + 1),
                    .name = try workbench.copyBounded("tool", limits.max_tool_field_bytes),
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
                        "x",
                        limits.max_user_message_bytes,
                    ),
                } },
                .tools = tools,
                .status_text = try workbench.copyBounded("", limits.max_tool_field_bytes),
                .terminal_publication = .init(.published),
                .terminal_payload = .{
                    .phase = .completed,
                    .outcome = .completed,
                    .cause = null,
                    .session_disposition_at_completion = .reusable,
                },
                .terminal_observed = true,
                .event_stream_finalized = true,
                .terminal_diagnostic = try workbench.allocTrackedCapacity(limits.max_terminal_diagnostic_bytes),
                .next_activity_order = @intCast(
                    limits.max_tools_per_run + limits.max_ui_history_per_task + 1,
                ),
            };
        }
        for (0..limits.max_compacts_per_task) |compact_index| {
            compacts[compact_index] = .{
                .id = @intCast(compact_index + 1),
                .after_run_id = 1,
                .terminal_publication = .init(.published),
                .terminal_payload = .{
                    .phase = .compacted,
                    .cause = null,
                    .before_context_tokens = std.math.maxInt(u64),
                    .after_context_tokens = std.math.maxInt(u64),
                    .usage = .{
                        .input_tokens = std.math.maxInt(u64),
                        .output_tokens = std.math.maxInt(u64),
                        .cache_read_input_tokens = std.math.maxInt(u64),
                        .cache_creation_input_tokens = std.math.maxInt(u64),
                    },
                    .session_disposition_at_completion = .reusable,
                },
                .terminal_diagnostic = try workbench.allocTrackedCapacity(
                    limits.max_terminal_diagnostic_bytes,
                ),
            };
        }
        workbench.tasks[task_index] = .{
            .durable = .{
                .id = @intCast(task_index + 1),
                .recent_order = @intCast(task_index + 1),
                .execution_generation = 1,
                .execution_provider = .anthropic,
                .execution_model = execution_model,
                .workspace_id = @intCast(task_index + 1),
                .workspace_root = try workbench.copyBounded(root, limits.max_workspace_bytes),
                .title = try workbench.copyBounded("", limits.max_task_title_bytes),
                .runs = runs,
                .compacts = compacts,
                .next_run_generation = @intCast(limits.max_runs_per_task),
                .ui_history = ui_history,
            },
            .runtime = .{},
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
            @memset(record.detail[0..], 'x');
            workbench.tasks[task_index].?.durable.ui_history[record_index] = record;
        }
        workbench.tasks[task_index].?.durable.ui_history_count = limits.max_ui_history_per_task;
    }
    workbench.next_workspace_id = @intCast(limits.max_tasks + 1);
    workbench.next_workspace_recent_order = @intCast(limits.max_tasks + 1);
    workbench.next_task_id = @intCast(limits.max_tasks + 1);
    workbench.next_task_recent_order = @intCast(limits.max_tasks + 1);

    const escaped_assistant = try std.testing.allocator.alloc(u8, limits.max_assistant_message_bytes);
    defer std.testing.allocator.free(escaped_assistant);
    @memset(escaped_assistant, 1);
    try workbench.appendTrackedText(
        &workbench.tasks[0].?.durable.runs[0].?.assistant,
        escaped_assistant,
        limits.max_assistant_message_bytes,
    );
    _ = workbench.redactTrackedText(
        &workbench.tasks[0].?.durable.runs[0].?.assistant,
        workbench.tasks[0].?.durable.runs[0].?.redaction_secret,
    );
    const remaining_projection = limits.max_projection_bytes - workbench.projection_bytes;
    const escaped_tool = try std.testing.allocator.alloc(
        u8,
        @min(limits.max_tool_field_bytes, remaining_projection),
    );
    defer std.testing.allocator.free(escaped_tool);
    @memset(escaped_tool, 2);
    try workbench.replaceTracked(
        &workbench.tasks[0].?.durable.runs[0].?.tools[0].?.content,
        escaped_tool,
        limits.max_tool_field_bytes,
    );
    try std.testing.expectEqual(limits.max_projection_bytes, workbench.projection_bytes);

    const storage = try std.testing.allocator.alloc(u8, limits.max_snapshot_bytes);
    defer std.testing.allocator.free(storage);
    const snapshot = try workbench.writeSnapshot(storage);
    try std.testing.expect(snapshot.len <= worstCaseSnapshotBytes(limits).?);
    try std.testing.expect(snapshot.len <= limits.max_snapshot_bytes);

    var task_state = try workbench.buildTaskStateWire();
    defer task_state.deinit();
    const persistence_storage = try std.testing.allocator.alloc(
        u8,
        task_persistence.max_store_bytes,
    );
    defer std.testing.allocator.free(persistence_storage);
    const persisted = try task_persistence.encode(
        persistence_storage,
        task_state.state,
    );
    try std.testing.expect(persisted.len <= task_persistence.max_store_bytes);
    var raw = try task_persistence.decode(
        std.testing.allocator,
        persisted,
        workbench.taskPersistenceLimits(),
    );
    defer raw.deinit();
    for (raw.value.tasks) |task| {
        for (task.ui_history) |record| {
            try std.testing.expect(record.request_id != 0);
            try std.testing.expect(record.run_id != 0);
            try std.testing.expect(record.order != 0);
            try std.testing.expect(std.mem.eql(u8, record.kind, "permission"));
            try std.testing.expect(std.mem.eql(u8, record.state, "allowed_once"));
            try std.testing.expect(record.detail.len <= 512);
            try std.testing.expect(std.unicode.utf8ValidateSlice(record.detail));
            var found = false;
            for (task.runs) |run| if (run.id == record.run_id) {
                found = true;
                break;
            };
            try std.testing.expect(found);
        }
    }
    var decoded = try task_persistence.decode(
        std.testing.allocator,
        persisted,
        workbench.taskPersistenceLimits(),
    );
    decoded.deinit();
}

test "permission UI re-encoding remains inside its concurrent snapshot allowance" {
    const limits = Limits{};
    const payload_len = (limits.max_pending_ui_json_bytes - 1024) / json_string_expansion;
    const payload = try std.testing.allocator.alloc(u8, payload_len);
    defer std.testing.allocator.free(payload);
    @memset(payload, 1);
    const request = lifecycle.PermissionRequest{
        .type = "permission",
        .request_id = "request-1",
        .session_id = "000000000000000000000001",
        .run_id = 1,
        .tool_call_id = "tool-1",
        .tool = .{ .namespace = .builtin, .name = "Bash", .binding = "binding-1" },
        .canonical_arguments_digest = "digest-1",
        .policy_generation = 1,
        .arguments_json = payload,
        .responses = &.{ .deny_once, .allow_once },
        .candidate = null,
    };
    const encoded = try std.json.Stringify.valueAlloc(std.testing.allocator, request, .{});
    defer std.testing.allocator.free(encoded);
    try std.testing.expect(encoded.len <= limits.max_pending_ui_json_bytes);

    const allowance = limits.max_pending_ui_json_bytes * pending_ui_reencode_expansion + pending_ui_snapshot_overhead;
    const storage = try std.testing.allocator.alloc(u8, allowance);
    defer std.testing.allocator.free(storage);
    var writer = std.Io.Writer.fixed(storage);
    var workbench = try testWorkbench();
    defer workbench.deinit();
    try task_view.writePendingUi(
        &writer,
        workbench.taskTextProjection(),
        std.math.maxInt(u64),
        std.math.maxInt(u64),
        std.math.maxInt(u64),
        request,
    );
    try std.testing.expect(writer.buffered().len <= allowance);
}

test "permission pending projection follows responses and candidate scope" {
    var workbench = try testWorkbench();
    defer workbench.deinit();
    const with_candidate = lifecycle.PermissionRequest{
        .type = "permission",
        .request_id = "1111111111111111111111111111111111111111111111111111111111111111",
        .session_id = "000000000000000000000001",
        .run_id = 1,
        .tool_call_id = "tool-1",
        .tool = .{
            .namespace = .builtin,
            .name = "Bash",
            .binding = "0000000000000000000000000000000000000000000000000000000000000000",
        },
        .canonical_arguments_digest = "3333333333333333333333333333333333333333333333333333333333333333",
        .policy_generation = 1,
        .arguments_json = "{}",
        .responses = &.{ .deny_once, .deny_session, .allow_once, .allow_session },
        .candidate = .{
            .rule_id = "2222222222222222222222222222222222222222222222222222222222222222",
            .scope = .exact_arguments,
        },
    };
    var candidate_storage: [4096]u8 = undefined;
    var candidate_writer = std.Io.Writer.fixed(&candidate_storage);
    try task_view.writePendingUi(
        &candidate_writer,
        workbench.taskTextProjection(),
        1,
        1,
        1,
        with_candidate,
    );
    const candidate_json = candidate_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, candidate_json, "allow_session") != null);
    try std.testing.expect(std.mem.indexOf(u8, candidate_json, "deny_session") != null);

    const once_only = testPermissionRequest("Bash", "{}");
    var once_storage: [4096]u8 = undefined;
    var once_writer = std.Io.Writer.fixed(&once_storage);
    try task_view.writePendingUi(
        &once_writer,
        workbench.taskTextProjection(),
        1,
        1,
        1,
        once_only,
    );
    const once_json = once_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, once_json, "allow_session") == null);
    try std.testing.expect(std.mem.indexOf(u8, once_json, "deny_session") == null);
}

test "permission provenance projection keeps typed fields bounded and non-persistent" {
    const value: lifecycle.PermissionProvenance = .{
        .decision = .allow,
        .source = .session_allow,
        .matched_rule_id = "2222222222222222222222222222222222222222222222222222222222222222",
        .session_id = "000000000000000000000001",
        .run_id = 1,
        .tool_call_id = "tool-1",
        .request_id = "1111111111111111111111111111111111111111111111111111111111111111",
        .tool = .{
            .namespace = .builtin,
            .name = "Bash",
            .binding = "0000000000000000000000000000000000000000000000000000000000000000",
        },
        .canonical_arguments_digest = "3333333333333333333333333333333333333333333333333333333333333333",
        .policy_generation = 7,
        .used_session_rule = true,
        .callback_outcome = .answered,
        .response = .allow_session,
    };
    const projected = try task_model.permissionSummary(value);
    try std.testing.expectEqual(lifecycle.PermissionDecision.allow, projected.decision);
    try std.testing.expectEqual(lifecycle.PermissionDecisionSource.session_allow, projected.source);
    try std.testing.expectEqual(@as(u64, 7), projected.policy_generation);
    try std.testing.expect(projected.used_session_rule);
    try std.testing.expectEqualStrings("Bash", projected.toolName());
    try std.testing.expect(!@hasField(task_persistence.RunWire, "permission_provenance"));
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

test "Workbench projects typed AgentCore file references into bounded tool entries" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var workbench = try testWorkbench();
    defer workbench.deinit();

    const encoded = "{\"tool_result\":{\"id\":\"tool-1\",\"name\":\"Read\",\"input\":\"{}\",\"content\":\"ok\",\"is_error\":false,\"elapsed_ms\":1,\"file_refs\":[{\"locator\":{\"workspace_path\":\"src/main.zig\"},\"title\":\"main.zig\",\"kind\":\"read\",\"range\":{\"start\":{\"line\":1,\"column\":1},\"end\":{\"line\":2,\"column\":1}}}]}}";
    var envelope = try testEnvelope(3, 7, encoded);
    defer envelope.deinit();
    try workbench.applyEvent(&envelope);

    var snapshot_storage: [96 * 1024]u8 = undefined;
    const snapshot = try workbench.writeSnapshot(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"fileRefs\":[{\"id\":\"file-3-1-1-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"displayPath\":\"src/main.zig\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"kind\":\"read\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"line\":\"2\"") != null);
}

test "file reference ids use durable task and run identities" {
    var first_storage: [96]u8 = undefined;
    var second_storage: [96]u8 = undefined;
    var other_task_storage: [96]u8 = undefined;
    const first = formatFileReferenceId(&first_storage, 3, 1, 1, 1);
    const second = formatFileReferenceId(&second_storage, 3, 2, 1, 1);
    const other_task = formatFileReferenceId(&other_task_storage, 4, 1, 1, 1);
    try std.testing.expectEqualStrings("file-3-1-1-1", first);
    try std.testing.expect(!std.mem.eql(u8, first, second));
    try std.testing.expect(!std.mem.eql(u8, first, other_task));
}

test "file preview allocation rollback does not touch projection budget" {
    var workbench = try testWorkbench();
    defer workbench.deinit();
    var reference = FileReferenceView{
        .id = @constCast("file-3-1-1-1"),
        .title = @constCast("main.zig"),
        .display_path = @constCast("src/main.zig"),
        .kind = @constCast("read"),
        .locator_kind = .workspace_path,
        .locator = @constCast("src/main.zig"),
    };
    const tracked_before = workbench.projection_bytes;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    const allocator = workbench.allocator;
    workbench.allocator = failing.allocator();
    const bytes = try allocator.dupe(u8, "preview");
    try std.testing.expectError(
        error.OutOfMemory,
        workbench.finishFilePreview(&reference, bytes, false),
    );
    workbench.allocator = allocator;
    allocator.free(bytes);
    try std.testing.expectEqual(tracked_before, workbench.projection_bytes);

    const success_bytes = try allocator.dupe(u8, "preview");
    var preview = try workbench.finishFilePreview(&reference, success_bytes, false);
    defer preview.deinit();
    try std.testing.expectEqual(tracked_before, workbench.projection_bytes);
}

test "truncated file preview keeps a complete UTF-8 prefix" {
    var bytes = [_]u8{ 'a', 0xe4, 0xb8, 0xad, 0xe4, 0xb8 };
    const complete = trimIncompleteUtf8Tail(&bytes);
    try std.testing.expectEqual(@as(usize, 4), complete.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(complete));

    var invalid = [_]u8{ 'a', 0xf5 };
    try std.testing.expectEqual(invalid.len, trimIncompleteUtf8Tail(&invalid).len);
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
    const tool = &workbench.tasks[0].?.durable.runs[0].?.tools[0].?;
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

    const request = testPermissionRequest("Bash", "token=SECRET-KEY");
    var pending_storage: [4096]u8 = undefined;
    var pending_writer = std.Io.Writer.fixed(&pending_storage);
    try task_view.writePendingUi(
        &pending_writer,
        workbench.taskTextProjection(),
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

    const first = &workbench.tasks[0].?.durable.runs[0].?.tools[0].?;
    const second = &workbench.tasks[0].?.durable.runs[0].?.tools[1].?;
    try std.testing.expectEqualStrings("tool-1", first.id);
    try std.testing.expectEqualStrings("tool-2", second.id);
    try std.testing.expectEqualStrings("first progress", first.progress);
    try std.testing.expectEqualStrings("second progress", second.progress);
    try std.testing.expect(!std.mem.eql(u8, &first.route_digest, &second.route_digest));
}

test "assistant credential redaction finalizes ordinary chunks without rescanning history" {
    var workbench = try testWorkbench();
    defer workbench.deinit();
    const assistant = &workbench.tasks[0].?.durable.runs[0].?.assistant;

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
    const run = &workbench.tasks[0].?.durable.runs[0].?;
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
    const late_count_before = workbench.late_terminal_event_count;
    try workbench.applyEvent(&late_event);
    try std.testing.expectEqual(late_count_before + 1, workbench.late_terminal_event_count);
    try std.testing.expectEqual(revision_before_late_event, workbench.revision);
    try std.testing.expect(
        std.mem.indexOf(u8, workbench.tasks[0].?.durable.runs[0].?.assistant.list.items, "late") == null,
    );
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

    const run = &workbench.tasks[0].?.durable.runs[0].?;
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
    // Continuation stays with the Session disposition; the projection loss is
    // a Run-level product fact only.
    try std.testing.expect(continuationAvailable(workbench.taskContinuation(&workbench.tasks[0].?)));

    var snapshot_storage: [96 * 1024]u8 = undefined;
    const snapshot = try workbench.writeSnapshot(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"phase\":\"failed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"lastRunOutcome\":\"failed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"cause\":\"event_pipeline_failure\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"continuationAvailable\":true") != null);
}

test "event drain barrier atomically publishes terminal product state" {
    var workbench = try testWorkbench();
    defer workbench.deinit();
    const run = &workbench.tasks[0].?.durable.runs[0].?;

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
        fn complete(
            binding: *task_agent_session.Binding,
            completion: *std.atomic.Value(CloseCompletion),
        ) void {
            binding.markReleasedForTest();
            completion.store(.closed, .release);
        }
    };

    var workbench = try testWorkbench();
    defer workbench.deinit();
    const task = &workbench.tasks[0].?;
    const run = &task.durable.runs[0].?;
    const route_id = task.runtime.routeId();
    try std.testing.expect(task.runtime.beginClosing());
    task.durable.archived = true;
    task.runtime.close_completion.store(.running, .release);
    task.runtime.close_thread = try std.Thread.spawn(.{}, Harness.complete, .{
        task.runtime.closingWorkerBinding().?,
        &task.runtime.close_completion,
    });
    try std.testing.expect(commitTerminal(
        run,
        .interrupted,
        .interrupted,
        .session_close,
        .closing,
        "",
        false,
    ));

    for (0..10_000) |_| {
        if (task.runtime.close_completion.load(.acquire) == .closed) break;
        std.Thread.yield() catch {};
    }
    try std.testing.expectEqual(
        CloseCompletion.closed,
        task.runtime.close_completion.load(.acquire),
    );

    workbench.syncLifecycle();
    try std.testing.expectEqual(TaskLifecycle.closing, taskLifecycle(task));
    try std.testing.expect(task.runtime.close_thread != null);
    try std.testing.expectEqual(route_id, task.runtime.routeId());
    try workbench.deleteTask(3);

    var queued_event = try testEnvelope(3, 7, "{\"text_chunk\":\"queued before terminal\"}");
    defer queued_event.deinit();
    try workbench.applyEvent(&queued_event);

    finalizeTestTerminalEvents(&workbench);
    try std.testing.expect(workbench.tasks[0] == null);

    var late_event = try testEnvelope(3, 7, "{\"text_chunk\":\"late\"}");
    defer late_event.deinit();
    try std.testing.expectError(error.UnknownTask, workbench.applyEvent(&late_event));
}

test "Runtime shutdown joins a flying close owner before relinquish" {
    const Harness = struct {
        fn close(
            binding: *task_agent_session.Binding,
            completion: *std.atomic.Value(CloseCompletion),
        ) void {
            for (0..128) |_| std.Thread.yield() catch {};
            binding.markClosedForTest();
            completion.store(.failed_closing, .release);
        }
    };

    var workbench = try testWorkbench();
    defer workbench.deinit();
    const task = &workbench.tasks[0].?;
    const route_id = task.runtime.routeId();
    try std.testing.expect(task.runtime.beginClosing());
    task.runtime.close_completion.store(.running, .release);
    task.runtime.close_thread = try std.Thread.spawn(.{}, Harness.close, .{
        task.runtime.closingWorkerBinding().?,
        &task.runtime.close_completion,
    });
    workbench.executor_shutdown = true;

    workbench.relinquishAgentSessionsAfterRuntimeShutdown();

    try std.testing.expect(task.runtime.close_thread == null);
    try std.testing.expect(route_id != 0);
    try std.testing.expectEqual(@as(u64, 0), task.runtime.routeId());
    try std.testing.expectEqual(
        task_agent_session.BindingState.relinquished,
        task.runtime.bindingAfterCloseJoin().?.state(),
    );
    try std.testing.expectError(
        error.SessionClosing,
        task.runtime.acquireAccess(),
    );
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
            .kind = .permission,
            .state = .allowed_once,
        };
        const detail = sanitizeInto(&record.detail, "Continue?", "");
        record.detail_len = detail.len;
        workbench.pushUiRecord(view, record);
    }
    try std.testing.expectEqual(workbench.limits.max_ui_history_per_task, view.durable.ui_history_count);
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

test "MCP runtime OAuth failure durably reauthorizes and preserves scope step-up" {
    const Resolver = struct {
        fn resolve(
            _: ?*anyopaque,
            allocator: std.mem.Allocator,
            locator: []const u8,
        ) mcp_configuration.CredentialResolution {
            const value = allocator.dupe(
                u8,
                if (std.mem.eql(u8, locator, "oauth/access-8"))
                    "access-token"
                else if (std.mem.eql(u8, locator, "oauth/refresh-8"))
                    "refresh-token"
                else
                    return .missing,
            ) catch return .out_of_memory;
            return .{ .value = value };
        }
    };
    const Effects = struct {
        fn commit(_: ?*anyopaque, _: []const u8) mcp_configuration.PersistenceEffect {
            return .committed;
        }
        fn clear(_: ?*anyopaque) mcp_configuration.PersistenceEffect {
            return .committed;
        }
        fn probe(_: ?*anyopaque, _: []const u8) mcp_configuration.CredentialPresence {
            return .present;
        }
        fn create(_: ?*anyopaque, _: []const u8, _: []const u8) bool {
            return true;
        }
        fn delete(_: ?*anyopaque, _: []const u8) bool {
            return true;
        }
    };
    const limits: mcp_configuration.Limits = .{
        .max_servers = 8,
        .max_tools_per_server = 32,
        .max_namespace_bytes = 128,
        .max_credential_locators = 64,
        .max_runtime_secrets_per_server = 128,
        .max_runtime_secret_bytes_per_server = 16 * 1024,
    };
    var server: mcp_configuration.ServerWire = .{
        .id = "oauth",
        .namespace = "oauth",
        .display_name = "OAuth",
        .enabled = true,
        .negotiation = "automatic",
        .timeout_ms = 1000,
        .transport = .{
            .kind = "streamable_http",
            .url = "https://mcp.example.test/mcp",
        },
        .auth = .{ .kind = "oauth", .oauth = .{
            .status = "ready",
            .registration = .{
                .kind = "pre_registered",
                .issuer = "https://auth.example.test",
                .client_id = "client",
                .token_endpoint_auth_method = "none",
                .client_credential_revision = 1,
                .client_secret_ref = null,
            },
            .consent = .{
                .epoch = 3,
                .fingerprint = "pending",
                .resource = "https://mcp.example.test/mcp",
                .issuer = "https://auth.example.test",
                .scopes = &.{"files.read"},
                .redirect_uri = "http://127.0.0.1:49152/auth/callback",
                .client_credential_revision = 1,
            },
            .grant = .{
                .consent_epoch = 3,
                .token_revision = 8,
                .access_token_ref = "oauth/access-8",
                .refresh_token_ref = "oauth/refresh-8",
                .expires_at_unix_ms = null,
            },
        } },
        .connection_approval = null,
        .tools = &.{"files.read"},
    };
    const approval = mcp_configuration.connectionFingerprint(server);
    server.connection_approval = .{ .fingerprint = &approval };
    const consent_fingerprint = mcp_configuration.oauthConsentFingerprint(
        server,
        server.auth.oauth.?.consent.?,
    ).?;
    server.auth.oauth.?.consent.?.fingerprint = &consent_fingerprint;
    var servers = [_]mcp_configuration.ServerWire{server};
    const registry: mcp_configuration.RegistryWire = .{
        .schema_version = 2,
        .generation = 4,
        .oauth_operation = null,
        .servers = &servers,
    };
    var encoded_storage: [mcp_configuration.max_store_bytes]u8 = undefined;
    const encoded = try mcp_configuration.encode(&encoded_storage, registry, limits);
    var preparation = try mcp_configuration.prepare(
        std.testing.allocator,
        encoded,
        true,
        false,
        .{ .available = true, .resolve_fn = Resolver.resolve },
        limits,
    );
    var preparation_owned = true;
    defer if (preparation_owned) preparation.deinit();
    var manifest = (try mcp_configuration.RuntimeManifest.candidate(
        std.testing.allocator,
        &preparation,
    )).?;
    var manifest_owned = true;
    defer if (manifest_owned) manifest.deinit();
    var management = try mcp_configuration.ManagementPort.init(
        std.testing.allocator,
        preparation.registry.?.value,
        .{
            .persistence = .{
                .available = true,
                .commit_journal_fn = Effects.commit,
                .commit_registry_fn = Effects.commit,
                .clear_journal_fn = Effects.clear,
            },
            .credentials = .{
                .available = true,
                .probe_fn = Effects.probe,
                .create_fn = Effects.create,
                .delete_fn = Effects.delete,
            },
            .limits = limits,
            .runtime_manifest = &manifest,
        },
    );
    var management_owned = true;
    defer if (management_owned) management.deinit();
    manifest_owned = false;
    var workbench = try testWorkbench();
    defer workbench.deinit();
    workbench.mcp = .{
        .preparation = preparation.take(),
        .activation = null,
        .activation_failed = false,
        .management = management,
        .admission = .{ .ready = .{
            .selection = null,
            .catalog_generation = null,
        } },
        .host_capabilities = .{ .oauth = true },
        .committed = true,
    };
    management_owned = false;
    preparation_owned = false;

    try std.testing.expectEqual(
        McpRuntimeAuthorizationFailureOutcome.stale,
        try workbench.requireMcpOauthReauthorization(.{
            .server_id = "oauth",
            .consent_epoch = 3,
            .token_revision = 7,
            .challenge_scopes = &.{},
            .challenge_scopes_complete = true,
        }),
    );
    try std.testing.expectEqualStrings(
        "ready",
        workbench.mcp.?.management.?.desiredRegistry().?.servers[0].auth.oauth.?.status,
    );
    try std.testing.expectEqual(
        McpRuntimeAuthorizationFailureOutcome.applied,
        try workbench.requireMcpOauthReauthorization(.{
            .server_id = "oauth",
            .consent_epoch = 3,
            .token_revision = 7,
            .challenge_scopes = &.{"files.write"},
            .challenge_scopes_complete = true,
        }),
    );
    const desired = workbench.mcp.?.management.?.desiredRegistry().?;
    try std.testing.expectEqualStrings(
        "reauth_required",
        desired.servers[0].auth.oauth.?.status,
    );
    try std.testing.expect(desired.servers[0].auth.oauth.?.grant == null);
    try std.testing.expectEqual(
        mcp_configuration.RuntimeAlignment.current,
        workbench.inspectMcpDesiredConfiguration().?.runtime_alignment,
    );
    try std.testing.expect(workbench.mcp.?.admission == .ready);
    try std.testing.expectEqual(
        @as(usize, 1),
        workbench.mcp.?.pending_reauthorizations.items.len,
    );
    try std.testing.expectEqualStrings(
        "oauth",
        workbench.mcp.?.pending_reauthorizations.items[0].server_id,
    );
    var start = (try workbench.beginMcpAuthorization(5, "oauth")).?;
    defer start.deinit();
    try std.testing.expectEqual(@as(usize, 2), start.additional_scopes.len);
    try std.testing.expectEqualStrings("files.read", start.additional_scopes[0]);
    try std.testing.expectEqualStrings("files.write", start.additional_scopes[1]);
    try std.testing.expect(workbench.finishMcpAuthorization(start.operation_id));

    workbench.blockMcpAdmissionAfterRuntimeAuthFailure();
    try std.testing.expectEqual(
        McpAdmissionBlockReason.runtime_authorization_failure,
        workbench.mcp.?.admission.blocked,
    );
    try std.testing.expectEqual(
        mcp_configuration.ManagementOutcome.saved,
        try workbench.renameMcpServer(5, .{
            .server_id = "oauth",
            .display_name = "Renamed OAuth",
        }),
    );
    try std.testing.expectEqual(
        McpAdmissionBlockReason.runtime_authorization_failure,
        workbench.mcp.?.admission.blocked,
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        workbench.mcp.?.pending_reauthorizations.items.len,
    );
    try std.testing.expectEqual(
        mcp_configuration.ManagementOutcome.saved,
        try workbench.removeMcpServer(6, "oauth"),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        workbench.mcp.?.pending_reauthorizations.items.len,
    );
}

test "empty MCP startup commits a proven manageable runtime" {
    const ManagementEffects = struct {
        fn journal(_: ?*anyopaque, _: []const u8) mcp_configuration.PersistenceEffect {
            return .committed;
        }
        fn registry(_: ?*anyopaque, _: []const u8) mcp_configuration.PersistenceEffect {
            return .committed;
        }
        fn clear(_: ?*anyopaque) mcp_configuration.PersistenceEffect {
            return .committed;
        }
        fn probe(_: ?*anyopaque, _: []const u8) mcp_configuration.CredentialPresence {
            return .missing;
        }
        fn create(_: ?*anyopaque, _: []const u8, _: []const u8) bool {
            return true;
        }
        fn delete(_: ?*anyopaque, _: []const u8) bool {
            return true;
        }
        fn fill(_: ?*anyopaque, output: *[16]u8) bool {
            @memset(output, 0xcd);
            return true;
        }
    };
    var preparation = try mcp_configuration.prepare(
        std.testing.allocator,
        null,
        true,
        false,
        .{},
        .{
            .max_servers = 8,
            .max_tools_per_server = 32,
            .max_namespace_bytes = 128,
            .max_credential_locators = 64,
            .max_runtime_secrets_per_server = 128,
            .max_runtime_secret_bytes_per_server = 16 * 1024,
        },
    );
    var preparation_owned = true;
    defer if (preparation_owned) preparation.deinit();
    var runtime_manifest = (try mcp_configuration.RuntimeManifest.candidate(
        std.testing.allocator,
        &preparation,
    )).?;
    var runtime_manifest_owned = true;
    defer if (runtime_manifest_owned) runtime_manifest.deinit();
    test_agent_runtime.io = std.testing.io;
    var workbench = try Workbench.init(
        std.testing.allocator,
        std.testing.io,
        &test_agent_runtime,
        testLimits(),
        .{ .mcp = .{
            .preparation = &preparation,
            .management = .{
                .persistence = .{
                    .available = true,
                    .commit_journal_fn = ManagementEffects.journal,
                    .commit_registry_fn = ManagementEffects.registry,
                    .clear_journal_fn = ManagementEffects.clear,
                },
                .credentials = .{
                    .available = true,
                    .probe_fn = ManagementEffects.probe,
                    .create_fn = ManagementEffects.create,
                    .delete_fn = ManagementEffects.delete,
                },
                .identity_generator = .{
                    .available = true,
                    .fill_fn = ManagementEffects.fill,
                },
                .limits = .{
                    .max_servers = 8,
                    .max_tools_per_server = 32,
                    .max_namespace_bytes = 128,
                    .max_credential_locators = 64,
                    .max_runtime_secrets_per_server = 128,
                    .max_runtime_secret_bytes_per_server = 16 * 1024,
                },
                .runtime_manifest = &runtime_manifest,
            },
        } },
    );
    preparation_owned = false;
    runtime_manifest_owned = false;
    defer workbench.deinit();

    var output: [128 * 1024]u8 = undefined;
    const empty_snapshot = try workbench.writeSnapshot(&output);
    try std.testing.expect(std.mem.indexOf(
        u8,
        empty_snapshot,
        "\"availability\":\"ready\",\"managementHealth\":\"ready\",\"operation\":\"idle\",\"configurationApply\":\"idle\",\"authorizationOperation\":{\"kind\":\"idle\"},\"desiredGeneration\":\"0\",\"runtimeAlignment\":\"current\",\"redacted\":false,\"servers\":[]",
    ) != null);
    try std.testing.expectEqual(
        mcp_configuration.ManagementOutcome.saved,
        try workbench.createMcpHttpServer(0, .{
            .display_name = "Remote",
            .url = "https://mcp.example.test/rpc",
        }),
    );
    const inspection = workbench.inspectMcpDesiredConfiguration().?;
    try std.testing.expectEqual(@as(?u64, 1), inspection.desired_generation);
    try std.testing.expectEqual(
        mcp_configuration.RuntimeAlignment.restart_required,
        inspection.runtime_alignment,
    );
    try std.testing.expectEqual(
        McpAdmissionBlockReason.pending_restart,
        workbench.mcp.?.admission.blocked,
    );
    const created_snapshot = try workbench.writeSnapshot(&output);
    try std.testing.expect(std.mem.indexOf(
        u8,
        created_snapshot,
        "\"desiredGeneration\":\"1\",\"runtimeAlignment\":\"restart_required\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        created_snapshot,
        "\"desiredEnabled\":true,\"runtimeStatus\":\"not_loaded\",\"newTaskAccess\":\"restart_required\"",
    ) != null);
    const server_id = workbench.mcp.?.management.?.desiredRegistry().?.servers[0].id;
    try workbench.beginMcpConnectionTest(server_id);
    const testing_snapshot = try workbench.writeSnapshot(&output);
    try std.testing.expect(std.mem.indexOf(
        u8,
        testing_snapshot,
        "\"connectionTest\":{\"status\":\"testing\",\"toolCount\":0,\"issueCount\":0}",
    ) != null);
    workbench.completeMcpConnectionTest(server_id, .connected, 3, 1);
    const connected_snapshot = try workbench.writeSnapshot(&output);
    try std.testing.expect(std.mem.indexOf(
        u8,
        connected_snapshot,
        "\"connectionTest\":{\"status\":\"connected\",\"toolCount\":3,\"issueCount\":1}",
    ) != null);
    try workbench.beginMcpConfigurationApply(1);
    try std.testing.expectError(error.CatalogLoading, workbench.refreshMcpCatalog());
    try std.testing.expect(workbench.mcp.?.refresh_pending);
    try std.testing.expect(workbench.mcp_refresh_job == null);
    const applying_snapshot = try workbench.writeSnapshot(&output);
    try std.testing.expect(std.mem.indexOf(
        u8,
        applying_snapshot,
        "\"configurationApply\":\"applying\"",
    ) != null);
    try std.testing.expectEqual(
        McpAdmissionBlockReason.refreshing,
        workbench.mcp.?.admission.blocked,
    );
    workbench.failMcpConfigurationApply(1);
    const failed_apply_snapshot = try workbench.writeSnapshot(&output);
    try std.testing.expect(std.mem.indexOf(
        u8,
        failed_apply_snapshot,
        "\"configurationApply\":\"failed\"",
    ) != null);
    try std.testing.expectEqual(
        McpAdmissionBlockReason.refreshing,
        workbench.mcp.?.admission.blocked,
    );
    try std.testing.expect(!workbench.mcp.?.refresh_pending);
    try std.testing.expect(workbench.mcp_refresh_job != null);
}

test "MCP authorization operation owns product phase and durable token boundary" {
    const Effects = struct {
        fn commit(_: ?*anyopaque, _: []const u8) mcp_configuration.PersistenceEffect {
            return .committed;
        }
        fn clear(_: ?*anyopaque) mcp_configuration.PersistenceEffect {
            return .committed;
        }
        fn probe(_: ?*anyopaque, _: []const u8) mcp_configuration.CredentialPresence {
            return .missing;
        }
        fn create(_: ?*anyopaque, _: []const u8, _: []const u8) bool {
            return true;
        }
        fn delete(_: ?*anyopaque, _: []const u8) bool {
            return true;
        }
        fn fill(_: ?*anyopaque, output: *[16]u8) bool {
            @memset(output, 0xab);
            return true;
        }
    };
    const limits: mcp_configuration.Limits = .{
        .max_servers = 8,
        .max_tools_per_server = 32,
        .max_namespace_bytes = 128,
        .max_credential_locators = 64,
        .max_runtime_secrets_per_server = 128,
        .max_runtime_secret_bytes_per_server = 16 * 1024,
    };
    var preparation = try mcp_configuration.prepare(
        std.testing.allocator,
        null,
        true,
        false,
        .{},
        limits,
    );
    var preparation_owned = true;
    defer if (preparation_owned) preparation.deinit();
    var manifest = (try mcp_configuration.RuntimeManifest.candidate(
        std.testing.allocator,
        &preparation,
    )).?;
    var manifest_owned = true;
    defer if (manifest_owned) manifest.deinit();
    var refresh_timer: TestMcpRefreshTimer = .{};
    test_agent_runtime.io = std.testing.io;
    var workbench = try Workbench.init(
        std.testing.allocator,
        std.testing.io,
        &test_agent_runtime,
        testLimits(),
        .{ .mcp_refresh_timer = refresh_timer.timer(), .mcp = .{
            .preparation = &preparation,
            .management = .{
                .persistence = .{
                    .available = true,
                    .commit_journal_fn = Effects.commit,
                    .commit_registry_fn = Effects.commit,
                    .clear_journal_fn = Effects.clear,
                },
                .credentials = .{
                    .available = true,
                    .probe_fn = Effects.probe,
                    .create_fn = Effects.create,
                    .delete_fn = Effects.delete,
                },
                .locator_generator = .{ .available = true, .fill_fn = Effects.fill },
                .identity_generator = .{ .available = true, .fill_fn = Effects.fill },
                .limits = limits,
                .runtime_manifest = &manifest,
            },
        } },
    );
    preparation_owned = false;
    manifest_owned = false;
    defer workbench.deinit();

    try std.testing.expectEqual(
        mcp_configuration.ManagementOutcome.saved,
        try workbench.createMcpOauthHttpServer(0, .{
            .display_name = "Remote OAuth",
            .url = "https://mcp.example.test/mcp",
            .client = .{ .pre_registered = .{ .client_id = "client-1" } },
        }),
    );
    const server_id = workbench.mcp.?.management.?.desiredRegistry().?.servers[0].id;
    var start = (try workbench.beginMcpAuthorization(1, server_id)).?;
    defer start.deinit();
    try std.testing.expectError(error.CatalogLoading, workbench.refreshMcpCatalog());
    try std.testing.expect(workbench.mcp.?.refresh_pending);
    try std.testing.expect(!workbench.mcp.?.refresh_pending_blocks_admission);
    try std.testing.expect(workbench.mcp.?.admission == .ready);
    try std.testing.expectEqual(@as(u64, 1), workbench.mcp.?.refresh_request_generation);
    try std.testing.expect(workbench.mcp_refresh_job == null);
    try std.testing.expectEqual(
        McpAuthorizationPhase.discovering,
        workbench.mcpAuthorizationOperation().?.phase,
    );
    try std.testing.expectEqualStrings(
        "https://mcp.example.test/mcp",
        start.endpoint,
    );
    try std.testing.expectEqual(
        mcp_configuration.ManagementOutcome.rejected,
        try workbench.renameMcpServer(1, .{
            .server_id = server_id,
            .display_name = "Blocked while authorizing",
        }),
    );
    try std.testing.expect(!workbench.advanceMcpAuthorization(
        start.operation_id,
        .exchanging,
    ));
    try std.testing.expect(workbench.advanceMcpAuthorization(
        start.operation_id,
        .awaiting_consent,
    ));

    const authorization = try workbench.authorizeMcpOauth(.{
        .attempt_id = 7,
        .server_id = server_id,
        .issuer = "https://auth.example.test",
        .resource = "https://mcp.example.test/mcp",
        .scopes = &.{ "files.read", "files.write" },
        .redirect_uri = "http://127.0.0.1:49152/auth/callback",
    });
    try std.testing.expect(authorization == .ready);
    try std.testing.expectEqualStrings(
        "client-1",
        authorization.ready.client_id,
    );
    try std.testing.expect(workbench.advanceMcpAuthorization(
        start.operation_id,
        .awaiting_browser,
    ));
    const exchange = try workbench.beginMcpOauthCodeExchange(server_id);
    try std.testing.expect(exchange == .started);
    const durable_id = exchange.started.operation.id;
    try std.testing.expect(workbench.finishMcpAuthorization(start.operation_id));
    try std.testing.expect(workbench.mcpAuthorizationOperation() == null);
    try std.testing.expect(workbench.mcp.?.refresh_pending);
    try std.testing.expect(!workbench.mcp.?.refresh_pending_blocks_admission);
    try std.testing.expect(workbench.mcp_refresh_job == null);
    try std.testing.expectError(error.CatalogLoading, workbench.refreshMcpCatalog());
    try std.testing.expectEqual(@as(u64, 2), workbench.mcp.?.refresh_request_generation);
    try std.testing.expectEqual(
        mcp_configuration.ManagementOutcome.saved,
        try workbench.recoverMcpOauthOperation(durable_id),
    );
    try std.testing.expect(!workbench.mcp.?.refresh_pending);
    try std.testing.expect(workbench.mcp_refresh_job != null);
    try std.testing.expectEqual(
        @as(u64, 2),
        workbench.mcp_refresh_job.?.request_generation,
    );
    const oauth = workbench.mcp.?.management.?.desiredRegistry().?.servers[0].auth.oauth.?;
    try std.testing.expectEqualStrings("reauth_required", oauth.status);
}

test "MCP startup health commits a safe degraded Workbench projection" {
    const ManagementEffects = struct {
        fn journal(_: ?*anyopaque, _: []const u8) mcp_configuration.PersistenceEffect {
            return .committed;
        }
        fn registry(_: ?*anyopaque, _: []const u8) mcp_configuration.PersistenceEffect {
            return .committed;
        }
        fn failRegistry(_: ?*anyopaque, _: []const u8) mcp_configuration.PersistenceEffect {
            return .failed;
        }
        fn clear(_: ?*anyopaque) mcp_configuration.PersistenceEffect {
            return .committed;
        }
        fn unknownClear(_: ?*anyopaque) mcp_configuration.PersistenceEffect {
            return .outcome_unknown;
        }
        fn probe(_: ?*anyopaque, _: []const u8) mcp_configuration.CredentialPresence {
            return .missing;
        }
        fn create(_: ?*anyopaque, _: []const u8, _: []const u8) bool {
            return true;
        }
        fn delete(_: ?*anyopaque, _: []const u8) bool {
            return true;
        }
    };
    const registry =
        \\{"schema_version":1,"generation":9,"servers":[{"id":"local-files","namespace":"files","display_name":"Local files","enabled":true,"negotiation":"automatic","timeout_ms":1000,"transport":{"kind":"stdio","command":"/private/hidden/mcp-server","arguments":[{"literal":"--serve"}],"environment":[]},"tools":["read_file"]},{"id":"disabled","namespace":"disabled","display_name":"Disabled","enabled":false,"negotiation":"automatic","timeout_ms":1000,"transport":{"kind":"streamable_http","url":"https://private.example.test/mcp","headers":[]},"tools":[]},{"id":"broken","namespace":"broken","display_name":"","enabled":false,"negotiation":"automatic","timeout_ms":1000,"transport":{"kind":"streamable_http","url":"https://broken.example.test/mcp","headers":[]},"tools":["",""]}]}
    ;
    var preparation = try mcp_configuration.prepare(
        std.testing.allocator,
        registry,
        true,
        false,
        .{},
        .{
            .max_servers = 8,
            .max_tools_per_server = 32,
            .max_namespace_bytes = 128,
            .max_credential_locators = 64,
            .max_runtime_secrets_per_server = 128,
            .max_runtime_secret_bytes_per_server = 16 * 1024,
        },
    );
    var preparation_owned = true;
    defer if (preparation_owned) preparation.deinit();
    var runtime_manifest = (try mcp_configuration.RuntimeManifest.candidate(
        std.testing.allocator,
        &preparation,
    )).?;
    var runtime_manifest_owned = true;
    defer if (runtime_manifest_owned) runtime_manifest.deinit();
    test_agent_runtime.io = std.testing.io;
    var workbench = try Workbench.init(
        std.testing.allocator,
        std.testing.io,
        &test_agent_runtime,
        testLimits(),
        .{ .mcp = .{
            .preparation = &preparation,
            .activation_failed = true,
            .management = .{
                .persistence = .{
                    .available = true,
                    .commit_journal_fn = ManagementEffects.journal,
                    .commit_registry_fn = ManagementEffects.registry,
                    .clear_journal_fn = ManagementEffects.clear,
                },
                .credentials = .{
                    .available = true,
                    .probe_fn = ManagementEffects.probe,
                    .create_fn = ManagementEffects.create,
                    .delete_fn = ManagementEffects.delete,
                },
                .limits = .{
                    .max_servers = 8,
                    .max_tools_per_server = 32,
                    .max_namespace_bytes = 128,
                    .max_credential_locators = 64,
                    .max_runtime_secrets_per_server = 128,
                    .max_runtime_secret_bytes_per_server = 16 * 1024,
                },
                .runtime_manifest = &runtime_manifest,
            },
        } },
    );
    preparation_owned = false;
    runtime_manifest_owned = false;
    defer workbench.deinit();

    var output: [128 * 1024]u8 = undefined;
    const snapshot = try workbench.writeSnapshot(&output);
    try std.testing.expect(std.mem.indexOf(
        u8,
        snapshot,
        "\"mcpManagement\":true",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        snapshot,
        "\"availability\":\"degraded\",\"managementHealth\":\"ready\",\"operation\":\"idle\",\"configurationApply\":\"idle\",\"authorizationOperation\":{\"kind\":\"idle\"},\"desiredGeneration\":\"9\",\"runtimeAlignment\":\"current\",\"redacted\":true",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        snapshot,
        "\"runtimeStatus\":\"unreachable\"",
    ) == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        snapshot,
        "\"runtimeStatus\":\"disabled\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        snapshot,
        "\"displayName\":\"broken\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        snapshot,
        "\"command\":\"/private/hidden/mcp-server\",\"arguments\":[\"--serve\"],\"cwd\":null",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        snapshot,
        "\"endpoint\":\"https://private.example.test/mcp\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        snapshot,
        "\"connection\":null",
    ) != null);

    const before = workbench.inspectMcpDesiredConfiguration().?;
    try std.testing.expectEqual(@as(?u64, 9), before.desired_generation);
    try std.testing.expectEqual(
        mcp_configuration.RuntimeAlignment.current,
        before.runtime_alignment,
    );
    try std.testing.expectEqual(
        McpAdmissionBlockReason.activation_unavailable,
        workbench.mcp.?.admission.blocked,
    );
    const revision_before_mutation = workbench.revision;
    try std.testing.expectEqual(
        mcp_configuration.ManagementOutcome.saved,
        try workbench.renameMcpServer(9, .{
            .server_id = "local-files",
            .display_name = "Updated local files",
        }),
    );
    try std.testing.expectEqual(revision_before_mutation + 1, workbench.revision);
    const after = workbench.inspectMcpDesiredConfiguration().?;
    try std.testing.expectEqual(@as(?u64, 10), after.desired_generation);
    try std.testing.expectEqual(
        mcp_configuration.RuntimeAlignment.current,
        after.runtime_alignment,
    );
    try std.testing.expectEqual(
        McpAdmissionBlockReason.activation_unavailable,
        workbench.mcp.?.admission.blocked,
    );

    try std.testing.expectEqual(
        mcp_configuration.ManagementOutcome.saved,
        try workbench.approveMcpConnection(10, .{ .server_id = "disabled" }),
    );
    try std.testing.expectEqual(
        mcp_configuration.ManagementOutcome.saved,
        try workbench.setMcpServerEnabled(11, .{
            .server_id = "disabled",
            .enabled = true,
        }),
    );
    try std.testing.expectEqual(
        mcp_configuration.RuntimeAlignment.restart_required,
        workbench.inspectMcpDesiredConfiguration().?.runtime_alignment,
    );
    try std.testing.expectEqual(
        McpAdmissionBlockReason.pending_restart,
        workbench.mcp.?.admission.blocked,
    );
    try std.testing.expectEqual(
        mcp_configuration.ManagementOutcome.saved,
        try workbench.setMcpServerEnabled(12, .{
            .server_id = "disabled",
            .enabled = false,
        }),
    );
    try std.testing.expectEqual(
        mcp_configuration.RuntimeAlignment.current,
        workbench.inspectMcpDesiredConfiguration().?.runtime_alignment,
    );
    try std.testing.expectEqual(
        McpAdmissionBlockReason.activation_unavailable,
        workbench.mcp.?.admission.blocked,
    );
    workbench.mcp.?.management.?.persistence.commit_registry_fn =
        ManagementEffects.failRegistry;
    try std.testing.expectEqual(
        mcp_configuration.ManagementOutcome.rejected,
        try workbench.setMcpServerEnabled(13, .{
            .server_id = "disabled",
            .enabled = true,
        }),
    );
    try std.testing.expectEqual(
        @as(?u64, 13),
        workbench.inspectMcpDesiredConfiguration().?.desired_generation,
    );
    try std.testing.expectEqual(
        McpAdmissionBlockReason.activation_unavailable,
        workbench.mcp.?.admission.blocked,
    );
    workbench.mcp.?.management.?.persistence.commit_registry_fn =
        ManagementEffects.registry;
    workbench.mcp.?.management.?.persistence.clear_journal_fn =
        ManagementEffects.unknownClear;
    try std.testing.expectEqual(
        mcp_configuration.ManagementOutcome.indeterminate,
        try workbench.setMcpServerEnabled(13, .{
            .server_id = "disabled",
            .enabled = true,
        }),
    );
    try std.testing.expectEqual(
        @as(?u64, 14),
        workbench.inspectMcpDesiredConfiguration().?.desired_generation,
    );
    try std.testing.expectEqual(
        McpAdmissionBlockReason.persistence_outcome_unknown,
        workbench.mcp.?.admission.blocked,
    );

    const effective_snapshot = try workbench.writeSnapshot(&output);
    try std.testing.expect(std.mem.indexOf(
        u8,
        effective_snapshot,
        "\"managementHealth\":\"outcome_unknown\",\"operation\":\"idle\",\"configurationApply\":\"idle\",\"authorizationOperation\":{\"kind\":\"idle\"},\"desiredGeneration\":null,\"runtimeAlignment\":\"unknown\",\"redacted\":false,\"servers\":[]",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        effective_snapshot,
        "Updated local files",
    ) == null);

    const blocked_job = try workbench.allocator.create(McpRefreshJob);
    blocked_job.* = .{
        .allocator = workbench.allocator,
        .runtime = workbench.agent_runtime,
        .notifier = .{},
        .request_generation = 1,
        .requested_at_ms = null,
        .arena = std.heap.ArenaAllocator.init(workbench.allocator),
        .allowlists = &.{},
        .build_admission = false,
    };
    workbench.mcp.?.refresh_request_generation = 1;
    workbench.mcp_refresh_job = blocked_job;
    try std.testing.expectError(
        error.CatalogLoading,
        workbench.createTaskInWorkspace(1, 1, 1, null, null),
    );
    workbench.mcp.?.activation_failed = false;
    blocked_job.outcome = .unavailable;
    blocked_job.state.store(.completed, .release);
    workbench.syncLifecycle();
    try std.testing.expect(workbench.mcp_refresh_job == null);
    try std.testing.expect(workbench.mcp.?.activation_failed);
    try std.testing.expectEqual(
        @as(?u64, 14),
        workbench.inspectMcpDesiredConfiguration().?.desired_generation,
    );

    const stale_job = try workbench.allocator.create(McpRefreshJob);
    stale_job.* = .{
        .allocator = workbench.allocator,
        .runtime = workbench.agent_runtime,
        .notifier = .{},
        .request_generation = 2,
        .requested_at_ms = null,
        .arena = std.heap.ArenaAllocator.init(workbench.allocator),
        .allowlists = &.{},
        .build_admission = false,
        .state = .init(.completed),
        .outcome = .unavailable,
    };
    workbench.mcp.?.activation_failed = false;
    workbench.mcp.?.refresh_request_generation = 3;
    workbench.mcp_refresh_job = stale_job;
    workbench.syncLifecycle();
    try std.testing.expect(!workbench.mcp.?.activation_failed);

    const cancelled_job = try workbench.allocator.create(McpRefreshJob);
    cancelled_job.* = .{
        .allocator = workbench.allocator,
        .runtime = workbench.agent_runtime,
        .notifier = .{},
        .request_generation = 4,
        .requested_at_ms = null,
        .arena = std.heap.ArenaAllocator.init(workbench.allocator),
        .allowlists = &.{},
        .build_admission = false,
    };
    workbench.mcp.?.refresh_request_generation = 4;
    workbench.mcp_refresh_job = cancelled_job;
    cancelMcpRefreshJob(cancelled_job);
    workbench.shutting_down = true;
    workbench.syncLifecycle();
    try std.testing.expect(workbench.mcp_refresh_job == null);
}
