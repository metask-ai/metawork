const std = @import("std");
const builtin = @import("builtin");
const lifecycle = @import("metawork_agent");
const account_contract = @import("metawork_account_contract");
const models_contract = @import("metawork_product_models_contract");
const models_ports = @import("product_models_ports");
const models_aggregate = @import("metawork_product_models");
const account_projection = @import("product_control_account_projection");
const execution_state = @import("product_control_execution_state");
const executor_impl = @import("product_control_executor");
const file_preview = @import("product_control_file_preview");
const permission_job = @import("permission_job.zig");
const agent_protocol = @import("product_agent_protocol_adapter");
const attachment_staging = @import("product_control_attachment_staging");
const file_change_io = @import("product_control_file_change_io");
const product_attachment = @import("metawork_product_attachment");
const product_workspace = @import("metawork_product_workspace");
const product_schedule = @import("metawork_product_schedule");
const skill_ports = @import("metawork_product_skill").ports;
const skill_runtime = @import("metawork_product_skill").runtime;
const product_task = @import("metawork_product_task");
const task_persistence = product_task.history;
const TaskPersistenceCommit = task_persistence.Commit;
const TaskPersistence = task_persistence.Capability;
const TaskPersistenceHealth = task_persistence.Health;
const checkpoint_store = product_task.checkpoint_store;
const file_change_store = product_task.file_change_store;
const catalog_snapshot = @import("metawork_product_skill").catalog;
const task_runtime = product_task;
const task_testing = product_task.testing;
const task_test_execution_binding = if (builtin.is_test) task_testing.execution_binding_module else struct {};
const task_test_agent_session = if (builtin.is_test) task_testing.agent_session_module else struct {};
const task_test_attachment = if (builtin.is_test) task_testing.attachment_module else struct {};
const task_test_deletion = if (builtin.is_test) task_testing.deletion_module else struct {};
const task_test_state = if (builtin.is_test) task_testing.state_module else struct {};
const task_test_policy = if (builtin.is_test) task_testing.policy_module else struct {};
const task_test_execution = if (builtin.is_test) task_testing.execution_module else struct {};
const task_test_view = if (builtin.is_test) task_testing.view_module else struct {};
const product_mcp = @import("metawork_product_mcp");
const control_ports = @import("metawork_product_control_ports");
const mcp_configuration = product_mcp.contract;
const mcp_ports = product_mcp;
const mcp_runtime = product_mcp;
const mcp_testing = product_mcp.testing;
const contract_fixture = @import("product_control_contract_fixture");
const build_options = @import("build_options");
const view_cache = @import("view_cache.zig");
const view_plan = @import("view_plan.zig");
pub const projection_step_bytes = view_plan.max_step_bytes;
pub const SnapshotRead = struct { id: u64, bytes: usize, scratch_bytes: usize = 0 };

pub const TaskMcpAuthorityAtCreation = product_task.McpAuthorityAtCreation;

pub const SendInputResult = product_task.InputAcceptance;
pub const SendInputReason = task_runtime.SendInputReason;
pub const InputTarget = union(enum) { idle: ?u64, run: u64 };
pub const ViewRequest = @import("view_request.zig").Request;
pub const ViewReceiptQuery = @import("view_request.zig").ReceiptQuery;

pub const Error = view_plan.Error || view_cache.Error || task_runtime.RunError || task_runtime.Runtime.ApprovalError || attachment_staging.Error || lifecycle.Error || product_attachment.Error || product_schedule.Error || skill_runtime.MutationError || skill_runtime.EnablementError || skill_runtime.EnablementFileStoreError || task_persistence.Error || std.mem.Allocator.Error || std.Thread.SpawnError || error{
    ProjectionCapacity,
    RunCapacity,
    CompactCapacity,
    ToolCapacity,
    InvalidOutputSegment,
    InvalidInputAdoption,
    SnapshotTooLarge,
    CloseInProgress,
    TaskBusy,
    TaskNotArchived,
    TaskReadOnly,
    InvalidTaskTitle,
    InvalidScheduledTaskInput,
    ScheduleTimerUnavailable,
    ScheduledTaskPersistenceUnavailable,
    ScheduledTaskPersistenceFailed,
    ScheduledTaskPersistenceOutcomeUnknown,
    TaskPersistenceUnavailable,
    TaskPersistenceFailed,
    TaskPersistenceOutcomeUnknown,
    BindingEpochExhausted,
    RunGenerationExhausted,
    ExecutorShuttingDown,
    TaskCapacity,
    TaskIdentityExhausted,
    UiRequestIdentityCollision,
    WorkspaceCapacity,
    WorkspaceIdentityExhausted,
    WorkspaceIdentityUntrusted,
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
    AutomaticWorkspaceRootGenerationMismatch,
    AutomaticWorkspaceRootPersistenceUnavailable,
    AutomaticWorkspaceRootPersistenceFailed,
    AutomaticWorkspaceRootPersistenceOutcomeUnknown,
    WorkspaceRemovalInProgress,
    WorkspaceEpochMismatch,
    WorkspaceEpochExhausted,
    CatalogLoading,
    CatalogUnavailable,
    McpManagementUnavailable,
    McpOauthScopeCapacity,
    CatalogRequestGenerationExhausted,
    StaleCatalog,
    ModelSelectionChanged,
    SkillNotFound,
    SkillUnavailable,
    InvalidSkillArguments,
    MissingInstruction,
    RecoveryUnavailable,
    RestoreAttemptExhausted,
    UnsupportedBuiltinProfile,
    UnsupportedPermissionProfile,
    AutomaticWorkspaceUnsupported,
};

const default_attachment_file_bytes: usize = 100_000_000;
const default_attachment_count: usize = 8;

pub fn sendInputRejection(err: anyerror) task_runtime.SendInputReason {
    return switch (err) {
        error.RunChanged => .run_changed,
        error.RunNotReady => .run_not_ready,
        error.InvalidInput => .invalid_input,
        error.RunStopping => .run_stopping,
        error.UnsupportedInput => .unsupported_input,
        error.BindingEpochMismatch => .binding_changed,
        error.ExecutionUnavailable, error.ExecutionGenerationMismatch => .binding_unavailable,
        error.UnknownTask, error.TaskClosing => .task_unavailable,
        error.TaskBusy => .task_busy,
        error.UnknownWorkspace, error.WorkspaceUnavailable, error.WorkspaceIdentityUntrusted => .workspace_unavailable,
        error.WorkspaceEpochMismatch => .workspace_changed,
        error.WorkspaceRemovalInProgress => .workspace_removing,
        error.CatalogLoading => .catalog_loading,
        error.CatalogUnavailable => .catalog_unavailable,
        error.StaleCatalog => .stale_catalog,
        error.SkillNotFound => .skill_not_found,
        error.SkillUnavailable => .skill_unavailable,
        error.InvalidSkillArguments => .invalid_skill_arguments,
        error.MissingInstruction => .missing_instruction,
        error.RunCapacity, error.RunGenerationExhausted, error.QueueFull, error.ProjectionCapacity, error.OutOfMemory => .capacity_reached,
        error.ExecutorShuttingDown => .shutting_down,
        else => .admission_failed,
    };
}

pub const Limits = struct {
    worker_count: usize = 4,
    queue_capacity: usize = 16,
    max_tasks: usize = 50,
    max_workspaces: usize = 16,
    max_scheduled_tasks: usize = 16,
    max_skill_assets: usize = 256,
    max_runs_per_task: usize = 16,
    max_pending_inputs_per_task: usize = 64,
    max_compacts_per_task: usize = 16,
    max_tools_per_run: usize = 32,
    max_commentary_segments_per_run: usize = 256,
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
    max_user_message_bytes: usize = 256 * 1024,
    max_attachments_per_draft: usize = default_attachment_count,
    max_attachment_display_name_bytes: usize = 512,
    max_attachment_file_bytes: usize = default_attachment_file_bytes,
    max_staged_attachment_bytes: usize = default_attachment_count * default_attachment_file_bytes,
    max_assistant_message_bytes: usize = 256 * 1024,
    max_tool_field_bytes: usize = 256 * 1024,
    max_file_refs_per_tool: usize = 32,
    max_file_ref_field_bytes: usize = 8192,
    max_file_changes_per_run: usize = 256,
    max_file_change_field_bytes: usize = 4096,
    max_file_change_diff_bytes: usize = 256 * 1024,
    max_file_preview_bytes: usize = 256 * 1024,
    max_file_preview_line_bytes: usize = 8192,
    max_file_preview_lines: usize = 5000,
    max_pending_ui_json_bytes: usize = 256 * 1024,
    max_pending_ui_requests: usize = 4,
    max_ui_history_per_task: usize = 8,
    max_terminal_diagnostic_bytes: usize = 512,
    max_snapshot_bytes: usize = 64 * 1024 * 1024,
};

// Single Runtime-owned production source. Agent validates these product
// limits against the official ABI ceilings at the dependency boundary.
const checkpoint_export_limits: lifecycle.CheckpointLimits = .{
    .hard_bytes = 64 * 1024 * 1024,
    .max_section_bytes = 16 * 1024 * 1024,
    // Core Read stores the complete image JSON as one checkpoint string.
    .max_string_bytes = std.base64.standard.Encoder.calcSize(lifecycle.multimodal_input_limits.max_image_raw_bytes) + 64 * 1024,
    .max_messages = 4096,
    .max_blocks_per_message = 256,
    .chunk_bytes = 256 * 1024,
};

pub const Protocol = product_task.Protocol;
pub const PermissionProfile = product_task.PermissionProfile;
pub const ApprovalMode = product_task.ApprovalMode;
pub const PermissionInteraction = product_task.PermissionInteraction;
// Flipped only when every admitted profile is complete across manual and
// Scheduled Task execution. Bridge mutations and snapshot publication consume
// this same gate so a hidden capability cannot remain callable.
pub const permission_profiles_available = true;

pub const TaskWorkspaceTrust = union(enum) {
    explicitly_trusted,
    temporary: []const u8,
};

pub const TaskCreateInput = struct {
    workspace_root: []const u8,
    trust: TaskWorkspaceTrust,
    approval_mode: ?ApprovalMode = null,
};

pub const TaskPermissionRequest = union(enum) {
    interactive: ?ApprovalMode,
    noninteractive: PermissionProfile,
};

pub const TaskWorkspaceRequest = union(enum) {
    manual: struct {
        workspace_id: u64,
        expected_epoch: u64,
    },
    automatic,
};

pub const AttachmentFileStore = product_attachment.FileStore;
pub const AttachmentArchiveTool = product_attachment.ArchiveTool;
pub const AttachmentImagePreparation = product_attachment.ImagePreparation;
pub const max_attachment_preview_pixels = product_attachment.max_image_preview_pixels;
pub const max_attachment_preview_bytes = product_attachment.max_image_preview_bytes;

pub const AttachmentAcceptance = struct {
    context: ?*anyopaque = null,
    accept_fn: *const fn (?*anyopaque) void = ignoreAttachmentAcceptance,

    fn accept(self: AttachmentAcceptance) void {
        self.accept_fn(self.context);
    }
};

fn ignoreAttachmentAcceptance(_: ?*anyopaque) void {}

const AttachmentRunAcceptanceContext = struct {
    borrow: *product_attachment.Borrow,
    external: AttachmentAcceptance,
};

pub const TaskRunInput = union(enum) {
    text: []const u8,
    skill: struct {
        skill_id: []const u8,
        catalog_revision: []const u8,
        selection_revision: u64,
        argument_values: []const []const u8,
    },
    multimodal: struct {
        text: []const u8,
        attachment_ids: []const u64,
        acceptance: AttachmentAcceptance = .{},
    },
};

pub const TaskModelSelectionInput = struct {
    expected_selection_revision: u64,
    target: models_contract.ModelRef,
    expected_source_generation: u64,
    expected_catalog_generation: u64,
};

pub const NewTaskModelSelectionInput = struct {
    target: models_contract.ModelRef,
    expected_source_generation: u64,
    expected_catalog_generation: u64,
};

pub const ScheduledTaskRecurrence = product_schedule.Recurrence;

pub const ScheduledTaskBindingInput = struct {
    model_ref: models_contract.ModelRef,
    source_generation: u64,
    selection_revision: u64,
    protocol: models_contract.Protocol,
};

pub const ScheduledTaskDefinitionInput = struct {
    title: []const u8,
    binding: ScheduledTaskBindingInput,
    input: []const u8,
    recurrence: ScheduledTaskRecurrence,
    permission_profile: PermissionProfile,
};

pub const WorkspaceAuthorization = product_workspace.Authorization;
pub const WorkspaceKind = product_workspace.Kind;
pub const WorkspaceRemovalFailure = product_workspace.RemovalFailure;
pub const WorkspaceSignals = product_workspace.Signals;

/// Borrowed, bounded Host-owned Workspace projection.
pub const WorkspaceProjection = product_workspace.Projection;

pub const CatalogAvailability = catalog_snapshot.CatalogAvailability;

pub const SkillProjection = catalog_snapshot.SkillProjection;
pub const CatalogIssueProjection = catalog_snapshot.CatalogIssueProjection;
pub const CatalogProjection = catalog_snapshot.CatalogProjection;
pub const SkillSourceBrand = @import("metawork_product_skill").sources.Brand;
pub const NewTaskAdmissionView = execution_state.NewTaskAdmissionView;

pub const ExecutionIdentity = struct {
    generation: u64,
    protocol: Protocol,
    model: []const u8,
};

pub const AutomationExecutionInput = struct {
    protocol: models_contract.Protocol,
    credential: []const u8,
    model: []const u8,
    base_url: []const u8,
};

pub const PermissionChoice = task_runtime.PermissionChoice;
pub const UiResponse = task_runtime.UiResponse;

pub const AppDirectories = struct {
    canonical_user_home: ?[]const u8 = null,
    automatic_workspace_system_root: ?[]const u8 = null,
    automatic_workspace_configuration_store: ?*product_workspace.AutomaticRootConfigurationFileStore = null,
    testing_automatic_workspace_root: ?*product_workspace.AutomaticRoot = null,
};

pub const AutomaticWorkspaceRootConfigurationView = struct {
    generation: u64,
    mode: ?product_workspace.AutomaticRootConfigurationMode,
    canonical_root: ?[]const u8,
    health: product_workspace.AutomaticRootConfigurationHealth,
    can_choose: bool,
    can_reset: bool,
    can_retry: bool,
};

pub const SkillManagementHealth = skill_runtime.ManagementHealth;
pub const SkillManagementConfiguration = skill_runtime.ManagementConfiguration;
pub const SkillEnablementHealth = skill_runtime.EnablementHealth;
pub const SkillEnablementConfiguration = skill_runtime.EnablementConfiguration;
pub const SkillEnablementScope = skill_runtime.EnablementScope;
pub const SkillEnablementState = skill_runtime.EnablementState;
pub const SkillEnablementMutation = skill_runtime.EnablementMutation;
pub const SkillInstallInput = skill_runtime.InstallInput;
pub const SkillMutationResult = skill_runtime.MutationResult;
pub const SkillExportResult = skill_runtime.ExportResult;
pub const SkillImportPreview = skill_runtime.Preview;

pub const Configuration = struct {
    run_clock: task_runtime.RunClock = .{},
    change_notifier: ChangeNotifier = .{},
    directories: AppDirectories = .{},
    schedule_timer: ScheduleTimer = .{},
    mcp_refresh_timer: McpRefreshTimer = .{},
    schedule_persistence: SchedulePersistence = .{},
    task_persistence: TaskPersistence = .{},
    checkpoint_store: CheckpointStoreConfiguration = .{},
    file_change_store: FileChangeStoreConfiguration = .{},
    attachment_store: ?*product_attachment.FileStore = null,
    attachment_images: product_attachment.ImagePreparation = .{},
    attachment_archive_tool: ?AttachmentArchiveTool = null,
    schedule_notifier: ScheduleNotifier = .{},
    skill_management: SkillManagementConfiguration = .{},
    skill_enablement: SkillEnablementConfiguration = .{},
    skill_sources: skill_runtime.SourceConfiguration = .{},
    builtin_skill_root: ?[]const u8 = null,
    custom_providers: CustomProviderCapabilities = .{},
    mcp: McpStartupConfiguration = .{},
    completion_factory: CompletionFactory = .{},
};

pub const CompletionFactory = struct {
    context: ?*anyopaque = null,
    create_fn: ?*const fn (
        ?*anyopaque,
        std.mem.Allocator,
        lifecycle.ModelBinding,
    ) anyerror!*lifecycle.Completion = null,

    fn create(
        self: CompletionFactory,
        allocator: std.mem.Allocator,
        binding: lifecycle.ModelBinding,
    ) anyerror!*lifecycle.Completion {
        if (self.create_fn) |create_fn|
            return create_fn(self.context, allocator, binding);
        return error.CompletionUnavailable;
    }
};

pub const CustomProviderCapabilities = struct {
    management: bool = false,
    secret_capture: bool = false,
    model_test: bool = false,
};

pub const CheckpointStoreConfiguration = struct {
    file_store: ?*checkpoint_store.FileStore = null,
    open_failed: bool = false,
};

pub const FileChangeStoreConfiguration = struct {
    file_store: ?*file_change_store.FileStore = null,
};

pub const McpHostCapabilities = mcp_runtime.McpHostCapabilities;
pub const McpStartupConfiguration = mcp_runtime.McpStartupConfiguration;
pub const McpAdmissionBlockReason = mcp_runtime.McpAdmissionBlockReason;
pub const McpOauthRefreshBinding = mcp_runtime.McpOauthRefreshBinding;
pub const McpOauthRefreshBeginOutcome = mcp_runtime.McpOauthRefreshBeginOutcome;
pub const McpOauthAuthorizationPlan = mcp_runtime.McpOauthAuthorizationPlan;
pub const McpOauthAuthorizationBinding = mcp_runtime.McpOauthAuthorizationBinding;
pub const McpOauthAuthorizationOutcome = mcp_runtime.McpOauthAuthorizationOutcome;
pub const McpOauthOperationHandle = mcp_runtime.McpOauthOperationHandle;
pub const McpOauthCodeExchangeBinding = mcp_runtime.McpOauthCodeExchangeBinding;
pub const McpOauthOperationBeginOutcome = mcp_runtime.McpOauthOperationBeginOutcome;
pub const McpOauthCodeExchangeBeginOutcome = mcp_runtime.McpOauthCodeExchangeBeginOutcome;
pub const McpOauthExpiry = mcp_runtime.McpOauthExpiry;
pub const McpRuntimeAuthorizationFailure = mcp_runtime.McpRuntimeAuthorizationFailure;
pub const McpRuntimeAuthorizationFailureOutcome = mcp_runtime.McpRuntimeAuthorizationFailureOutcome;
pub const McpAuthorizationPhase = mcp_runtime.McpAuthorizationPhase;
pub const McpConnectionTestOutcome = mcp_runtime.McpConnectionTestOutcome;
pub const McpConfigurationApplyState = mcp_runtime.McpConfigurationApplyState;
pub const McpAuthorizationOperationView = mcp_runtime.McpAuthorizationOperationView;
pub const McpAuthorizationStart = mcp_runtime.McpAuthorizationStart;
pub const McpSecretCaptureTarget = mcp_runtime.McpSecretCaptureTarget;
pub const McpOauthRuntimeCommit = mcp_runtime.McpOauthRuntimeCommit;
pub const McpRefreshTimer = mcp_runtime.McpRefreshTimer;

pub const SchedulePersistenceCommit = product_schedule.PersistenceCommit;
pub const SchedulePersistence = product_schedule.Persistence;
pub const SchedulePersistenceHealth = product_schedule.PersistenceHealth;

pub const PersistenceRecoveryOutcome = enum {
    recovered,
    stale_revision,
    not_required,
    unavailable,
    failed,
    outcome_unknown,
    shutting_down,
};
pub const ScheduleNotificationKind = product_schedule.NotificationKind;
pub const ScheduleNotification = product_schedule.Notification;
pub const ScheduleNotifier = product_schedule.Notifier;

const json_string_expansion: usize = 6;
// A pending request's raw JSON already contains the escaped arguments string.
// The snapshot publishes a strict subset of that request; fixed identity and
// choice fields are covered by pending_ui_snapshot_overhead below.
const pending_ui_reencode_expansion: usize = 1;
const root_snapshot_overhead: usize = 1024;
const account_snapshot_text_bytes: usize =
    account_contract.Limits.account_id_bytes +
    account_contract.Limits.display_name_bytes +
    4 * account_contract.Limits.safe_diagnostic_bytes +
    12 * account_contract.Limits.decimal_bytes +
    (2 + account_contract.Limits.usage_history_days) *
        account_contract.Limits.calendar_date_bytes +
    account_contract.Limits.usage_history_days * 6 *
        account_contract.Limits.decimal_bytes;
const custom_provider_snapshot_text_bytes: usize =
    models_contract.Limits.custom_provider_entries *
    (models_contract.Limits.instance_id_bytes +
        models_contract.Limits.display_name_bytes +
        models_contract.Limits.base_url_bytes +
        models_contract.Limits.model_id_bytes +
        models_contract.Limits.custom_provider_model_entries *
            (models_contract.Limits.model_id_bytes +
                models_contract.Limits.model_display_name_bytes));
const account_snapshot_overhead: usize = 1024 +
    account_contract.Limits.usage_history_days * 192;
const model_metadata_snapshot_bytes: usize = 1024;
const custom_provider_snapshot_overhead: usize = 1024 +
    models_contract.Limits.custom_provider_entries * 256;
const workspace_snapshot_overhead: usize = 512;
const task_snapshot_overhead: usize = 1024;
const scheduled_task_snapshot_overhead: usize = 1024;
const skill_snapshot_structure = skill_runtime.Runtime.snapshotStructureBounds();
const skill_asset_snapshot_overhead = skill_snapshot_structure.asset;
const skill_source_settings_snapshot_bytes: usize = 1024;
const skill_source_discovery_snapshot_bytes: usize = 1024;
const run_snapshot_overhead: usize = 1024;
const commentary_segment_snapshot_overhead: usize = 3;
const compact_snapshot_overhead: usize = 512;
const catalog_snapshot_overhead: usize = 256;
const catalog_skill_snapshot_overhead = skill_snapshot_structure.catalog_skill;
const catalog_argument_snapshot_overhead = skill_snapshot_structure.argument;
const catalog_issue_snapshot_overhead: usize = 128;
const tool_snapshot_overhead: usize = 512;
const tool_min_projection_bytes: usize = "tool-1".len + 1;
// writeFileChanges emits at most this much non-projected JSON per collection
// and record. The global projection allowance below already pays six bytes for
// every retained text byte, so the record allowance only adds structure after
// removing that deliberate overestimate for the canonical ASCII product id.
const file_change_collection_snapshot_overhead: usize = 64;
const file_change_record_snapshot_overhead: usize = 251;
const file_change_min_display_path_bytes: usize = 1;
const file_change_id_min_bytes: usize = "change-1-1-1".len;
const file_change_id_next_bytes: usize = file_change_id_min_bytes + 1;
const file_change_id_remaining_bytes: usize = file_change_id_next_bytes + 1;
const one_digit_positive_values: usize = 9;
const two_digit_positive_values: usize = 90;
const file_change_min_id_capacity: usize =
    one_digit_positive_values * one_digit_positive_values * one_digit_positive_values;
const file_change_next_id_capacity: usize =
    3 * two_digit_positive_values * one_digit_positive_values * one_digit_positive_values;
const pending_ui_snapshot_overhead: usize = 8 * 1024;
const ui_record_detail_capacity = if (builtin.is_test) task_test_state.ui_record_detail_capacity else 0;
const ui_record_snapshot_overhead: usize = 1024;
const tool_route_digest_bytes = if (builtin.is_test) task_test_state.tool_route_digest_bytes else 0;
const ToolState = if (builtin.is_test) task_test_state.ToolState else void;
const RunPhase = if (builtin.is_test) task_test_state.RunPhase else void;
const RunOutcome = product_task.RunOutcome;
const CompactPhase = if (builtin.is_test) task_test_state.CompactPhase else void;
const CompactCause = if (builtin.is_test) task_test_state.CompactCause else void;
const ActiveOperation = if (builtin.is_test) task_test_state.ActiveOperation else void;
const RunCause = if (builtin.is_test) task_test_state.RunCause else void;
const TaskLifecycle = if (builtin.is_test) task_test_state.TaskLifecycle else void;
const ContinuationUnavailableReason = if (builtin.is_test) task_test_state.ContinuationUnavailableReason else void;
const CloseCompletion = if (builtin.is_test) task_test_state.CloseCompletion else void;

pub const ChangeNotifier = struct {
    context: ?*anyopaque = null,
    wake: *const fn (?*anyopaque) bool = noChangeNotification,

    fn notify(self: ChangeNotifier) bool {
        return self.wake(self.context);
    }
};

const TaskWorkspaceOrderContext = struct {
    workspace: *product_workspace.Runtime,
    preparation: *product_workspace.OrderPreparation,
};

const PreparedTaskCreate = struct {
    task: task_runtime.PreparedCreate,
    order: product_workspace.OrderPreparation,

    fn id(self: *const PreparedTaskCreate) u64 {
        return self.task.id();
    }

    fn complete(self: *PreparedTaskCreate, control: *Runtime) u64 {
        const task_id = self.task.complete();
        if (self.order.isActive()) control.workspace.commitOrder(&self.order);
        return task_id;
    }

    fn rollback(self: *PreparedTaskCreate, control: *Runtime) void {
        self.task.rollback();
        if (self.order.isActive()) control.workspace.rollbackOrder(&self.order);
    }
};

const PreparedAutomaticBinding = struct {
    workspace: product_workspace.PreparedAutomaticWorkspace,

    fn id(self: *const PreparedAutomaticBinding) u64 {
        return self.workspace.id();
    }

    fn facts(self: *const PreparedAutomaticBinding, control: *const Runtime) product_workspace.Facts {
        return control.workspace.preparedAutomaticFacts(&self.workspace);
    }

    fn complete(self: *PreparedAutomaticBinding, control: *Runtime) void {
        control.workspace.completeAutomatic(&self.workspace);
    }

    fn rollback(self: *PreparedAutomaticBinding, control: *Runtime) void {
        control.unregisterPreparedAutomaticSkillNoFail(self.id());
        _ = control.workspace.rollbackPreparedAutomatic(
            &self.workspace,
            control.workspaceStorage(),
        );
    }

    fn abandon(self: *PreparedAutomaticBinding, control: *Runtime) void {
        control.unregisterPreparedAutomaticSkillNoFail(self.id());
        control.workspace.abandonPreparedAutomatic(
            &self.workspace,
            control.workspaceStorage(),
        );
    }
};

const PreparedScheduledAdmission = struct {
    control: *Runtime,
    workspace: PreparedAutomaticBinding,
    task: PreparedTaskCreate,
    run: task_runtime.PreparedRun,
    active: bool = true,

    fn taskId(self: *const PreparedScheduledAdmission) u64 {
        return self.task.id();
    }

    fn rollback(self: *PreparedScheduledAdmission) void {
        std.debug.assert(self.active);
        self.run.rollback();
        self.task.rollback(self.control);
        self.workspace.rollback(self.control);
        self.active = false;
    }

    fn abandon(self: *PreparedScheduledAdmission) void {
        std.debug.assert(self.active);
        self.run.rollback();
        self.task.rollback(self.control);
        self.workspace.abandon(self.control);
        self.active = false;
    }

    fn submit(
        self: *PreparedScheduledAdmission,
    ) error{ ExecutorShuttingDown, QueueFull }!u64 {
        std.debug.assert(self.active);
        const task_id = self.task.complete(self.control);
        self.workspace.complete(self.control);
        self.active = false;
        _ = try self.run.submit();
        return task_id;
    }
};

fn copyWorkspaceStorage(
    context: *anyopaque,
    value: []const u8,
    max: usize,
) product_workspace.StorageError![]u8 {
    const self: *Runtime = @ptrCast(@alignCast(context));
    return self.copyBounded(value, max) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ProjectionCapacity => error.ProjectionCapacity,
        else => unreachable,
    };
}

fn projectWorkspaceStorage(
    context: *anyopaque,
    value: []const u8,
    max: usize,
    sensitive: []const u8,
) product_workspace.StorageError!product_workspace.ProjectedText {
    const self: *Runtime = @ptrCast(@alignCast(context));
    const projected = self.copyProjected(value, max, sensitive) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ProjectionCapacity => return error.ProjectionCapacity,
        else => unreachable,
    };
    return .{ .value = projected.value, .redacted = projected.redacted };
}

fn freeWorkspaceStorage(context: *anyopaque, value: []u8) void {
    const self: *Runtime = @ptrCast(@alignCast(context));
    self.freeTracked(value);
}

fn redactWorkspaceStorage(
    _: *anyopaque,
    storage: []u8,
    projected_len: *usize,
    credential: []const u8,
) bool {
    return redactWorkspaceBytesNoFail(storage, projected_len, credential);
}

fn automaticWorkspaceContains(context: *const anyopaque, path: []const u8) bool {
    const self: *const Runtime = @ptrCast(@alignCast(context));
    return self.workspace.automaticRootContains(path);
}

fn hiddenWorkspaceReusable(context: *const anyopaque, workspace_id: u64) bool {
    const self: *const Runtime = @ptrCast(@alignCast(context));
    return !self.task_runtime.workspaceHasTasks(workspace_id) and
        !self.skill.hasWorkspaceJob(workspace_id) and
        self.skill.workspaceRetirementAllowed(workspace_id);
}

fn enqueueSkillJob(
    context: *anyopaque,
    job: skill_ports.Job,
) error{ ExecutorShuttingDown, QueueFull }!void {
    const executor: *executor_impl.Executor = @ptrCast(@alignCast(context));
    return executor.enqueue(.{
        .identity = job.identity,
        .context = job.context,
        .execute_fn = job.execute_fn,
        .cancel_fn = job.cancel_fn,
    });
}

fn cancelSkillJob(context: *anyopaque, identity: *anyopaque) bool {
    const executor: *executor_impl.Executor = @ptrCast(@alignCast(context));
    return executor.cancel(identity);
}

fn enqueueFilePreviewJob(
    context: *anyopaque,
    job: file_preview.ExecutorJob,
) error{ ExecutorShuttingDown, QueueFull }!void {
    const executor: *executor_impl.Executor = @ptrCast(@alignCast(context));
    return executor.enqueue(.{
        .identity = job.identity,
        .context = job.context,
        .execute_fn = job.execute_fn,
        .cancel_fn = job.cancel_fn,
    });
}

fn filePreviewExecutor(executor: *executor_impl.Executor) file_preview.Executor {
    return .{
        .context = executor,
        .enqueue_fn = enqueueFilePreviewJob,
    };
}

fn enqueueAttachmentStagingJob(
    context: *anyopaque,
    job: attachment_staging.ExecutorJob,
) error{ ExecutorShuttingDown, QueueFull }!void {
    const executor: *executor_impl.Executor = @ptrCast(@alignCast(context));
    return executor.enqueue(.{
        .identity = job.identity,
        .context = job.context,
        .execute_fn = job.execute_fn,
        .cancel_fn = job.cancel_fn,
    });
}

fn attachmentStagingExecutor(executor: *executor_impl.Executor) attachment_staging.Executor {
    return .{ .context = executor, .enqueue_fn = enqueueAttachmentStagingJob };
}

fn enqueueFileChangeJob(
    context: *anyopaque,
    job: file_change_io.ExecutorJob,
) error{ ExecutorShuttingDown, QueueFull }!void {
    const executor: *executor_impl.Executor = @ptrCast(@alignCast(context));
    return executor.enqueue(.{
        .identity = job.identity,
        .context = job.context,
        .execute_fn = job.execute_fn,
        .cancel_fn = job.cancel_fn,
    });
}

fn fileChangeExecutor(executor: *executor_impl.Executor) file_change_io.Executor {
    return .{ .context = executor, .enqueue_fn = enqueueFileChangeJob };
}

fn enqueueMcpJob(
    context: *anyopaque,
    job: mcp_ports.Job,
) error{ ExecutorShuttingDown, QueueFull }!void {
    const executor: *executor_impl.Executor = @ptrCast(@alignCast(context));
    return executor.enqueue(.{
        .identity = job.identity,
        .context = job.context,
        .execute_fn = job.execute_fn,
        .cancel_fn = job.cancel_fn,
    });
}

fn cancelMcpJob(context: *anyopaque, identity: *anyopaque) bool {
    const executor: *executor_impl.Executor = @ptrCast(@alignCast(context));
    return executor.cancel(identity);
}

fn activateMcpCatalog(context: *anyopaque) mcp_ports.CatalogError!lifecycle.McpActivationOutcome {
    const runtime: *lifecycle.Runtime = @ptrCast(@alignCast(context));
    return runtime.activateMcp();
}

fn createMcpAdmissionSelection(
    context: *anyopaque,
    activation: *const lifecycle.McpActivation,
    allowlists: []const lifecycle.McpServerAllowlist,
) mcp_ports.CatalogError!?*lifecycle.McpSelection {
    const runtime: *lifecycle.Runtime = @ptrCast(@alignCast(context));
    return runtime.createMcpAdmissionSelection(activation, allowlists);
}

fn prepareMcpRestoreSelection(context: *anyopaque, original: *const lifecycle.McpRestoreSelection, activation: *const lifecycle.McpActivation, ceiling: []const lifecycle.McpActivationTool) mcp_ports.CatalogError!*lifecycle.McpSelection {
    const runtime: *lifecycle.Runtime = @ptrCast(@alignCast(context));
    return runtime.prepareMcpRestoreSelection(original, activation, ceiling);
}

fn mcpExecutorPort(executor: *executor_impl.Executor) mcp_ports.Executor {
    return .{
        .context = executor,
        .enqueue_fn = enqueueMcpJob,
        .cancel_fn = cancelMcpJob,
    };
}

fn mcpCatalogPort(runtime: *lifecycle.Runtime) mcp_ports.Catalog {
    return .{
        .context = runtime,
        .activate_fn = activateMcpCatalog,
        .create_admission_selection_fn = createMcpAdmissionSelection,
        .prepare_restore_selection_fn = prepareMcpRestoreSelection,
    };
}

fn mcpNotifierPort(notifier: ChangeNotifier) mcp_ports.Notifier {
    return .{
        .context = notifier.context,
        .notify_fn = notifier.wake,
    };
}

fn mcpTimerPort(timer: McpRefreshTimer) mcp_ports.Timer {
    return .{
        .enabled = timer.enabled,
        .context = timer.context,
        .now_fn = timer.now_monotonic_ms,
        .arm_at_fn = timer.arm_at,
        .cancel_fn = timer.cancel,
    };
}

fn productMcpPorts(
    executor: *executor_impl.Executor,
    runtime: *lifecycle.Runtime,
    timer: McpRefreshTimer,
    notifier: ChangeNotifier,
) mcp_ports.Ports {
    return .{
        .executor = mcpExecutorPort(executor),
        .catalog = mcpCatalogPort(runtime),
        .timer = mcpTimerPort(timer),
        .notifier = mcpNotifierPort(notifier),
    };
}

fn querySkillCatalog(
    context: *anyopaque,
    input: lifecycle.CatalogQuery,
) anyerror!lifecycle.CatalogAcquisition {
    const runtime: *lifecycle.Runtime = @ptrCast(@alignCast(context));
    return runtime.querySkillCatalog(input);
}

fn releaseSkillCatalog(context: *anyopaque, lease: *lifecycle.CatalogLease) void {
    const runtime: *lifecycle.Runtime = @ptrCast(@alignCast(context));
    runtime.releaseSkillCatalog(lease) catch
        @panic("Agent rejected a Product Skill catalog lease");
}

fn productSkillPorts(
    executor: *executor_impl.Executor,
    runtime: *lifecycle.Runtime,
    notifier: ChangeNotifier,
) skill_ports.Ports {
    return .{
        .executor = .{
            .context = executor,
            .enqueue_fn = enqueueSkillJob,
            .cancel_fn = cancelSkillJob,
        },
        .catalog = .{
            .context = runtime,
            .query_fn = querySkillCatalog,
            .release_fn = releaseSkillCatalog,
        },
        .notifier = .{
            .context = notifier.context,
            .notify_fn = notifier.wake,
        },
    };
}

pub const ScheduleTimer = product_schedule.Timer;

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

/// Runtime owns product impact policy; Bridge supplies transport facts only.
/// Current Renderer transport failures never terminate an Agent Run.
pub fn decideTransportFailure(report: TransportFailureReport) TransportFailureDecision {
    std.debug.assert((report.session_id == 0) == (report.run_id == 0));
    return switch (report.stage) {
        .ingress_validation, .command_dispatch => .reject_command,
        .revision_delivery, .snapshot_transport => .retry,
        .response_delivery, .connection_generation => .detach_renderer,
    };
}

const TrackedText = if (builtin.is_test) task_test_state.TrackedText else void;
const permission_summary_field_capacity = if (builtin.is_test) task_test_state.permission_summary_field_capacity else 0;
const ToolView = if (builtin.is_test) task_test_state.ToolView else void;
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

pub const FilePreviewState = file_preview.State;

/// Callback-scoped safe projection. `content` has already passed current
/// authority and known-credential redaction and must not be retained by the
/// sink after `complete_fn` returns.
pub const FilePreviewResult = struct {
    image_png: []const u8 = &.{},
    completion_id: u64,
    state: FilePreviewState,
    content: []const u8,
    truncated: bool,
    redacted: bool,
};

pub const FilePreviewSink = struct {
    context: *anyopaque,
    complete_fn: *const fn (*anyopaque, FilePreviewResult) void,
};

pub const AttachmentStagingRejection = attachment_staging.Rejection;
pub const AttachmentStagingResult = union(enum) {
    accepted,
    cancelled,
    ready: []const product_attachment.Descriptor,
    rejected: AttachmentStagingRejection,
};
pub const AttachmentStagingSink = struct {
    context: *anyopaque,
    complete_fn: *const fn (*anyopaque, u64, AttachmentStagingResult) void,
};

pub const FileChangeDiffReason = enum {
    not_recorded,
    capacity,
    missing,
    corrupt,
};

pub const FileChangeDiffResult = union(enum) {
    ready: struct {
        completion_id: u64,
        content: []const u8,
        complete: bool,
        redacted: bool,
    },
    unavailable: struct {
        completion_id: u64,
        reason: FileChangeDiffReason,
    },
};

pub const FileChangeDiffSink = struct {
    context: *anyopaque,
    complete_fn: *const fn (*anyopaque, FileChangeDiffResult) void,
};

fn discardFileChangeDiffCompletion(_: *anyopaque, _: FileChangeDiffResult) void {}

pub const FileChangeDiffAdmission = union(enum) {
    queued,
    immediate: FileChangeDiffReason,
};

const UsageView = if (builtin.is_test) task_test_state.UsageView else void;
const EventProjectionFailure = if (builtin.is_test) task_test_state.EventProjectionFailure else void;
const RunTerminationDispatch = if (builtin.is_test) task_test_state.RunTerminationDispatch else void;
const RunInputRecord = if (builtin.is_test) task_test_state.RunInputRecord else void;
const TestRunRecord = if (builtin.is_test) task_test_state.RunRecord else void;
const AutomaticTitleState = if (builtin.is_test) task_test_state.AutomaticTitleState else void;
const TestCompactRecord = if (builtin.is_test) task_test_state.CompactRecord else void;

const UiRecordKind = if (builtin.is_test) task_test_state.UiRecordKind else void;
const UiRecordState = if (builtin.is_test) task_test_state.UiRecordState else void;
const UiRecord = if (builtin.is_test) task_test_state.UiRecord else void;
const DurableTaskRecord = if (builtin.is_test) task_test_state.DurableTaskRecord else void;
const RuntimeAttachment = if (builtin.is_test) task_test_state.RuntimeAttachment else void;
const TestTask = if (builtin.is_test) task_test_state.Task else void;
const terminalPayload = if (builtin.is_test) task_test_state.terminalPayload else void;
const productTerminalFacts = if (builtin.is_test) task_test_state.productTerminalFacts else void;
const runPhase = if (builtin.is_test) task_test_state.runPhase else void;
const setActivePhase = if (builtin.is_test) task_test_state.setActivePhase else void;
const compactTerminalPayload = if (builtin.is_test) task_test_state.compactTerminalPayload else void;
const activeCompactPhase = if (builtin.is_test) task_test_state.activeCompactPhase else void;
const isTerminalPhase = if (builtin.is_test) task_test_state.isTerminalPhase else void;
const findRun = if (builtin.is_test) task_test_state.findRun else void;
const pendingInterruption = if (builtin.is_test) task_test_policy.pendingInterruption else void;
const pendingTerminationSignal = if (builtin.is_test) task_test_policy.pendingTerminationSignal else void;
const closeFailureCompletion = if (builtin.is_test) task_test_policy.closeFailureCompletion else void;
const classifyAgentTerminal = if (builtin.is_test) task_test_policy.classifyAgentTerminal else void;
const hasActiveOperation = if (builtin.is_test) task_test_policy.hasActiveOperation else void;
const continuationAvailable = if (builtin.is_test) task_test_policy.continuationAvailable else void;
const automaticTitleCandidate = if (builtin.is_test) task_test_policy.automaticTitleCandidate else void;
const generatedAutomaticTitleCandidate = if (builtin.is_test) task_test_policy.generatedAutomaticTitleCandidate else void;
const boundAutomaticTitle = if (builtin.is_test) task_test_policy.boundAutomaticTitle else void;
const taskLifecycle = if (builtin.is_test) task_test_policy.taskLifecycle else void;
const foldTerminalDisposition = if (builtin.is_test) task_test_policy.foldTerminalDisposition else void;

const TaskFailureRecord = task_runtime.FailureRecord;

test "Task aggregate separates Task runtime ownership from product history" {
    try std.testing.expect(@hasField(TestTask, "durable"));
    try std.testing.expect(@hasField(TestTask, "runtime"));
    try std.testing.expect(@hasField(TestTask, "deletion"));
    inline for (&.{
        "attachment",
        "worker_leases",
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
        try std.testing.expect(@hasField(task_test_attachment.LiveAttachment, field_name));
        try std.testing.expect(!@hasField(RuntimeAttachment, field_name));
        try std.testing.expect(!@hasField(DurableTaskRecord, field_name));
    }
    try std.testing.expect(!@hasField(task_test_attachment.LiveAttachment, "session"));
    try std.testing.expect(!@hasField(task_test_attachment.LiveAttachment, "route_id"));
    try std.testing.expect(@hasField(task_test_attachment.ClosingAttachment, "route_id"));
    try std.testing.expect(@hasField(task_test_attachment.ClosingAttachment, "worker_binding"));
    try std.testing.expect(!@hasField(RuntimeAttachment, "lifecycle"));
    try std.testing.expect(!@hasField(RuntimeAttachment, "continuation"));
    try std.testing.expect(!@hasField(RuntimeAttachment, "deletion"));
    try std.testing.expect(!@hasField(DurableTaskRecord, "deletion"));
    inline for (&.{
        "id",
        "workspace_id",
        "binding_epoch",
        "completion_seen_run_id",
        "title",
        "runs",
        "compacts",
        "ui_history",
    }) |field_name| {
        try std.testing.expect(@hasField(DurableTaskRecord, field_name));
        try std.testing.expect(!@hasField(RuntimeAttachment, field_name));
    }
}

const OwnedTaskExecution = if (builtin.is_test) task_test_execution_binding.OwnedTaskExecution else void;

const CatalogSnapshot = catalog_snapshot.Snapshot;

const McpRefreshTestJob = if (builtin.is_test) mcp_testing.RefreshJob else struct {};

pub const PreparedCustomProviderBinding =
    execution_state.PreparedCustomProviderBinding;

// Exists only for one Host read preparation. No credential or borrowed
// execution pointer enters encoded caches, Bridge storage or worker work items.
const ProjectionCredentials = struct {
    allocator: std.mem.Allocator,
    values: std.ArrayList([]const u8) = .empty,

    fn add(self: *ProjectionCredentials, value: []const u8) std.mem.Allocator.Error!void {
        if (value.len == 0) return;
        for (self.values.items) |known| if (std.mem.eql(u8, known, value)) return;
        const owned = try self.allocator.dupe(u8, value);
        errdefer {
            std.crypto.secureZero(u8, owned);
            self.allocator.free(owned);
        }
        try self.values.append(self.allocator, owned);
    }

    fn visit(context: *anyopaque, value: []const u8) std.mem.Allocator.Error!void {
        const self: *ProjectionCredentials = @ptrCast(@alignCast(context));
        try self.add(value);
    }

    fn deinit(self: *ProjectionCredentials) void {
        for (self.values.items) |value| {
            std.crypto.secureZero(u8, @constCast(value));
            self.allocator.free(value);
        }
        self.values.deinit(self.allocator);
    }
};

const ViewPreparation = struct {
    const Block = struct { key: view_cache.Key, start: usize, end: usize, known: u64, version: u64 = 0, current: bool = true };
    const Tool = struct { source: ?product_task.OwnedToolProjection, child: *view_plan.Plan, state: product_task.OwnedToolProjection.State = .{} };
    credentials: ?ProjectionCredentials = null,
    tools: std.ArrayList(Tool) = .empty,
    raw_bytes: usize = 0,
    tool_limit: usize = 0,
    next_tool: usize = 0,
    blocks: [7]Block = undefined,
    next_block: usize = 0,
    versions: view_cache.Versions = .{},
    reused: [7]bool = @splat(false),
    known_epoch: u64 = 0,
    scratch_bytes: usize = 0,
    tail: view_plan.Plan = .{},
    ready: bool = false,

    fn clear(self: *ViewPreparation, allocator: std.mem.Allocator) void {
        for (self.tools.items) |*tool| if (tool.source) |*source| source.deinit(allocator);
        self.tools.deinit(allocator);
        if (self.credentials) |*credentials| credentials.deinit();
        self.tail.clear(allocator);
        self.* = .{};
    }
};

pub const Runtime = struct {
    run_clock: task_runtime.RunClock,
    allocator: std.mem.Allocator,
    io: std.Io,
    agent_runtime: *lifecycle.Runtime,
    limits: Limits,
    workspace: product_workspace.Runtime,
    automatic_root_configuration: product_workspace.AutomaticRootConfigurationRuntime,
    automatic_workspace_system_root: ?[]u8,
    automatic_workspace_configuration_store: ?*product_workspace.AutomaticRootConfigurationFileStore,
    attachments: product_attachment.Runtime,
    task_runtime: task_runtime.Runtime,
    task_persistence: TaskPersistence,
    task_persistence_health: TaskPersistenceHealth,
    approval_syncing: bool = false,
    // Deferred lifecycle facts share the approval writer; unknown keeps its
    // exact candidate until an explicit readback decides the canonical record.
    approval_history_dirty: bool = false,
    approval_history_unknown: ?[]u8 = null,
    pending_model_intent: ?task_runtime.PreparedModelIntent = null,
    /// Bounded diagnostic count of canonical Agent events that arrived after
    /// their Run's terminal drain was finalized. Runtime-only evidence for
    /// the Stop-barrier investigation; never persisted or published.
    checkpoint_store: ?*checkpoint_store.FileStore,
    checkpoint_store_health: std.atomic.Value(checkpoint_store.Health),
    schedule: product_schedule.Runtime,
    skill: skill_runtime.Runtime,
    change_notifier: ChangeNotifier,
    executor: *executor_impl.Executor,
    approval_executor: *executor_impl.Executor,
    attachment_executor: *executor_impl.Executor,
    attachment_lane: *attachment_staging.Lane,
    attachment_io: ?struct { completion_id: u64, product_id: u64, cancel_requested: bool = false, file_index: usize = 0, offset: usize = 0, count: usize = 0 } = null,
    preview_executor: *executor_impl.Executor,
    preview_lane: *file_preview.Lane,
    file_change_store: ?*file_change_store.FileStore,
    file_change_executor: ?*executor_impl.Executor,
    file_change_lane: ?*file_change_io.Lane,
    shutting_down: bool = false,
    advancing_task_inputs: bool = false,
    executor_shutdown: bool = false,
    attachment_executor_shutdown: bool = false,
    preview_executor_shutdown: bool = false,
    file_change_executor_shutdown: bool = false,
    projection_bytes: usize = 0,
    revision: u64 = 0,
    projection_security_epoch: u64 = 1,
    encoded_views: view_cache.Cache = .{},
    view_read: view_plan.Plan = .{},
    view_preparation: ViewPreparation = .{},
    capture_view: ?*view_plan.Plan = null,
    view_step_timing: if (builtin.is_test) struct { encode_ns: i96 = 0, cache_copy_ns: i96 = 0 } else void = if (builtin.is_test) .{} else {},
    next_view_read_id: u64 = 0,
    view_blocks: [7]?struct { key: view_cache.Key, version: u64, start: usize, end: usize } = @splat(null),
    projection_history_epoch: u64 = 1,
    view_credentials: ?[]const []const u8 = null,
    default_approval_mode: ApprovalMode = .auto_review,
    account_projection: account_projection.Projection,
    execution_state: execution_state.State,
    custom_providers: models_aggregate.Runtime,
    canonical_user_home: ?[]u8,
    custom_provider_capabilities: CustomProviderCapabilities,
    completion_factory: CompletionFactory,
    image_run_preparation: ?control_ports.ImageRunPreparation = null,
    permission_jobs: [permission_job.capacity]?*permission_job.Job = @splat(null),
    mcp: ?mcp_runtime.Runtime = null,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        agent_runtime: *lifecycle.Runtime,
        limits: Limits,
        configuration: Configuration,
    ) Error!Runtime {
        if (limits.worker_count == 0 or limits.queue_capacity == 0 or
            limits.max_tasks == 0 or limits.max_workspaces == 0 or
            limits.max_scheduled_tasks == 0 or
            limits.max_skill_assets == 0 or
            limits.max_pending_inputs_per_task == 0 or limits.max_pending_inputs_per_task > 64 or
            limits.max_runs_per_task == 0 or
            limits.max_compacts_per_task == 0 or
            limits.max_tools_per_run == 0 or
            limits.max_commentary_segments_per_run == 0 or
            limits.max_projection_bytes == 0 or
            limits.max_workspace_bytes == 0 or
            limits.max_catalog_projection_bytes == 0 or
            limits.max_scheduled_task_projection_bytes == 0 or
            limits.max_catalog_skills == 0 or
            limits.max_catalog_issues == 0 or
            limits.max_skill_arguments == 0 or
            limits.max_task_title_bytes == 0 or
            limits.max_attachments_per_draft == 0 or
            limits.max_attachments_per_draft >= lifecycle.multimodal_input_limits.max_parts or
            limits.max_attachment_display_name_bytes == 0 or
            limits.max_attachment_file_bytes == 0 or
            limits.max_staged_attachment_bytes == 0 or
            limits.max_user_message_bytes == 0 or limits.max_assistant_message_bytes == 0 or
            limits.max_tool_field_bytes == 0 or limits.max_pending_ui_json_bytes == 0 or
            limits.max_file_changes_per_run == 0 or
            limits.max_file_change_field_bytes == 0 or
            limits.max_file_change_diff_bytes == 0 or
            limits.max_pending_ui_requests == 0 or
            limits.max_ui_history_per_task == 0 or
            limits.max_terminal_diagnostic_bytes == 0 or
            limits.max_snapshot_bytes == 0 or
            (worstCaseSnapshotBytes(limits) orelse return error.ProjectionCapacity) > limits.max_snapshot_bytes)
            return error.ProjectionCapacity;
        var account_projection_state = try account_projection.Projection.init(allocator);
        errdefer account_projection_state.deinit();
        var execution_state_state = try execution_state.State.init(allocator);
        errdefer execution_state_state.deinit();
        var custom_providers = models_aggregate.Runtime.init(
            allocator,
            io,
            std.Thread.getCurrentId(),
        );
        errdefer custom_providers.deinit();
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
        const automatic_workspace_system_root = if (configuration.directories.automatic_workspace_system_root) |root| copy: {
            if (root.len == 0 or
                !std.fs.path.isAbsolute(root) or
                !std.unicode.utf8ValidateSlice(root) or
                std.mem.indexOfScalar(u8, root, 0) != null or
                root.len > product_workspace.automatic_root_configuration.max_root_bytes)
                return error.InvalidWorkspace;
            break :copy try allocator.dupe(u8, root);
        } else null;
        errdefer if (automatic_workspace_system_root) |root| allocator.free(root);
        if (configuration.directories.testing_automatic_workspace_root != null and
            (automatic_workspace_system_root != null or
                configuration.directories.automatic_workspace_configuration_store != null))
            return error.InvalidWorkspace;
        var automatic_root_configuration = if (configuration.directories.testing_automatic_workspace_root) |root|
            product_workspace.AutomaticRootConfigurationRuntime{
                .allocator = allocator,
                .configuration = try product_workspace.AutomaticRootConfiguration.custom(
                    allocator,
                    root.canonicalPath(),
                ),
                .health = .ready,
            }
        else
            try product_workspace.AutomaticRootConfigurationRuntime.bootstrap(
                allocator,
                configuration.directories.automatic_workspace_configuration_store,
            );
        errdefer automatic_root_configuration.deinit();
        var opened_automatic_root: ?product_workspace.AutomaticRoot = null;
        errdefer if (opened_automatic_root) |*root| root.deinit();
        const automatic_root_capability = if (configuration.directories.testing_automatic_workspace_root) |root|
            root
        else opened: {
            const effective_root = automatic_root_configuration.effectiveRoot(
                automatic_workspace_system_root,
            ) orelse {
                if (automatic_root_configuration.configuration != null and
                    (automatic_root_configuration.health == .ready or
                        automatic_root_configuration.health == .write_failed))
                    automatic_root_configuration.health = .path_unavailable;
                break :opened null;
            };
            const mode = automatic_root_configuration.configuration.?.mode;
            opened_automatic_root = switch (mode) {
                .system_default => product_workspace.AutomaticRoot.open(
                    io,
                    allocator,
                    effective_root,
                ),
                .custom => product_workspace.AutomaticRoot.openExisting(
                    io,
                    allocator,
                    effective_root,
                ),
            } catch {
                automatic_root_configuration.health = .path_unavailable;
                break :opened null;
            };
            if (mode == .custom and !product_workspace.automaticPathEqual(
                effective_root,
                opened_automatic_root.?.canonicalPath(),
            )) {
                opened_automatic_root.?.deinit();
                opened_automatic_root = null;
                automatic_root_configuration.health = .path_unavailable;
                break :opened null;
            }
            break :opened &opened_automatic_root.?;
        };
        const workspace_capacity = workspaceRecordCapacity(limits) orelse
            return error.ProjectionCapacity;
        var workspace = try product_workspace.Runtime.init(
            allocator,
            io,
            limits.max_workspaces,
            limits.max_tasks,
            limits.max_workspace_bytes,
            automatic_root_capability,
        );
        errdefer workspace.deinitEmpty();
        var attachments = try product_attachment.Runtime.init(allocator, .{
            .max_files = limits.max_attachments_per_draft,
            .max_display_name_bytes = limits.max_attachment_display_name_bytes,
            .max_file_bytes = limits.max_attachment_file_bytes,
            .max_staged_bytes = limits.max_staged_attachment_bytes,
        }, configuration.attachment_store, configuration.attachment_images, configuration.attachment_archive_tool);
        errdefer attachments.deinit();
        var product_tasks = try task_runtime.Runtime.init(allocator, limits.max_tasks);
        errdefer product_tasks.deinitStorage();
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
        var schedule = try product_schedule.Runtime.init(allocator, .{
            .max_items = limits.max_scheduled_tasks,
            .max_projection_bytes = limits.max_scheduled_task_projection_bytes,
        }, .{
            .timer = configuration.schedule_timer,
            .persistence = configuration.schedule_persistence,
            .notifier = configuration.schedule_notifier,
        });
        errdefer schedule.deinit();
        const executor = executor_impl.Executor.create(io, allocator, .{
            .worker_count = limits.worker_count,
            .queue_capacity = limits.queue_capacity,
        }) catch |err| switch (err) {
            error.InvalidLimits => unreachable,
            else => return err,
        };
        var executor_owned = true;
        errdefer if (executor_owned) executor.deinit();
        // Approval metadata must make progress while every Run worker is
        // waiting for a permission that the metadata transaction delegates.
        const approval_executor = try executor_impl.Executor.create(io, allocator, .{
            .worker_count = 1,
            .queue_capacity = product_task.approval_capacity,
        });
        var approval_executor_owned = true;
        errdefer if (approval_executor_owned) approval_executor.deinit();
        const preview_executor = executor_impl.Executor.create(io, allocator, .{
            .worker_count = file_preview.worker_count,
            .queue_capacity = file_preview.max_in_flight,
        }) catch |err| switch (err) {
            error.InvalidLimits => unreachable,
            else => return err,
        };
        var preview_executor_owned = true;
        errdefer if (preview_executor_owned) preview_executor.deinit();
        const attachment_executor = executor_impl.Executor.create(io, allocator, .{
            .worker_count = attachment_staging.worker_count,
            .queue_capacity = attachment_staging.max_in_flight,
        }) catch |err| switch (err) {
            error.InvalidLimits => unreachable,
            else => return err,
        };
        var attachment_executor_owned = true;
        errdefer if (attachment_executor_owned) attachment_executor.deinit();
        const attachment_lane = try attachment_staging.Lane.create(io, allocator, .{
            .context = configuration.change_notifier.context,
            .wake_fn = configuration.change_notifier.wake,
        }, attachmentStagingExecutor(attachment_executor));
        var attachment_lane_owned = true;
        errdefer if (attachment_lane_owned) {
            attachment_lane.stopAdmission();
            attachment_executor.shutdown();
            while (attachment_lane.take()) |taken| attachment_lane.release(taken);
            attachment_lane.deinit();
        };
        const preview_lane = try file_preview.Lane.create(io, allocator, .{
            .context = configuration.change_notifier.context,
            .wake_fn = configuration.change_notifier.wake,
        }, filePreviewExecutor(preview_executor));
        var preview_lane_owned = true;
        errdefer if (preview_lane_owned) {
            preview_lane.stopAdmission();
            preview_executor.shutdown();
            preview_lane.deinit();
        };
        var file_change_executor_value: ?*executor_impl.Executor = null;
        var file_change_lane_value: ?*file_change_io.Lane = null;
        var file_change_lane_owned = false;
        errdefer if (file_change_lane_owned) {
            if (file_change_lane_value) |lane| lane.stopAdmission();
            file_change_executor_value.?.shutdown();
            if (file_change_lane_value) |lane| lane.deinit();
            file_change_executor_value.?.deinit();
        };
        if (configuration.file_change_store.file_store) |store| {
            const file_executor = executor_impl.Executor.create(io, allocator, .{
                .worker_count = 1,
                .queue_capacity = file_change_io.max_in_flight,
            }) catch |err| switch (err) {
                error.InvalidLimits => unreachable,
                else => return err,
            };
            file_change_executor_value = file_executor;
            file_change_lane_owned = true;
            file_change_lane_value = try file_change_io.Lane.create(
                io,
                allocator,
                store,
                .{
                    .context = configuration.change_notifier.context,
                    .wake_fn = configuration.change_notifier.wake,
                },
                fileChangeExecutor(file_executor),
            );
        }
        var configured_skill_ports = productSkillPorts(executor, agent_runtime, configuration.change_notifier);
        configured_skill_ports.source_roots.builtin_root = configuration.builtin_skill_root;
        var skill = try skill_runtime.Runtime.init(
            io,
            allocator,
            configured_skill_ports,
            .{
                .state = .{
                    .management = configuration.skill_management,
                    .enablement = configuration.skill_enablement,
                    .sources = configuration.skill_sources,
                },
                .max_workspaces = workspace_capacity,
                .canonical_user_home = canonical_user_home,
            },
            .{
                .max_assets = limits.max_skill_assets,
                .max_workspaces = limits.max_workspaces,
                .max_policy_keys = limits.max_catalog_skills,
                .max_policy_key_bytes = limits.max_tool_field_bytes,
            },
        );
        var skill_owned = true;
        errdefer if (skill_owned) skill.deinit();
        var mcp_startup = try mcp_runtime.Startup.prepare(allocator, configuration.mcp);
        errdefer if (mcp_startup) |*startup| startup.deinit();
        var control: Runtime = .{
            .allocator = allocator,
            .io = io,
            .agent_runtime = agent_runtime,
            .limits = limits,
            .workspace = workspace,
            .automatic_root_configuration = automatic_root_configuration,
            .automatic_workspace_system_root = automatic_workspace_system_root,
            .automatic_workspace_configuration_store = configuration.directories.automatic_workspace_configuration_store,
            .attachments = attachments,
            .task_runtime = product_tasks,
            .task_persistence = configuration.task_persistence,
            .task_persistence_health = task_persistence_health,
            .checkpoint_store = configuration.checkpoint_store.file_store,
            .checkpoint_store_health = .init(checkpoint_store_health),
            .schedule = schedule,
            .skill = skill,
            .change_notifier = configuration.change_notifier,
            .run_clock = configuration.run_clock,
            .executor = executor,
            .approval_executor = approval_executor,
            .attachment_executor = attachment_executor,
            .attachment_lane = attachment_lane,
            .preview_executor = preview_executor,
            .preview_lane = preview_lane,
            .file_change_store = configuration.file_change_store.file_store,
            .file_change_executor = file_change_executor_value,
            .file_change_lane = file_change_lane_value,
            .account_projection = account_projection_state,
            .execution_state = execution_state_state,
            .custom_providers = custom_providers,
            .canonical_user_home = canonical_user_home,
            .custom_provider_capabilities = configuration.custom_providers,
            .completion_factory = configuration.completion_factory,
        };
        skill_owned = false;
        executor_owned = false;
        approval_executor_owned = false;
        attachment_executor_owned = false;
        attachment_lane_owned = false;
        preview_executor_owned = false;
        if ((control.task_persistence_health == .ready or
            control.task_persistence_health == .degraded) and
            configuration.task_persistence.restored_bytes != null)
        {
            control.restoreTaskState(
                configuration.task_persistence.restored_bytes.?,
            ) catch |err| {
                control.clearRestoredTaskStateNoFail();
                switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => control.task_persistence_health = .corrupt,
                }
            };
        }
        if (control.workspace.automaticRootPath()) |root| {
            control.workspace.validateAutomaticRootCandidate(root) catch {
                control.workspace.disableAutomaticRoot();
                control.automatic_root_configuration.health = .path_unavailable;
            };
        }
        control.reconcileCheckpointStoreNoFail();
        control.cleanupFileChangeStoreNoFail();
        // Skill records name Workspace ids; the allocator must never hand out
        // an id they still claim, whatever history survived.
        control.workspace.reserveIdentity(control.skill.maxWorkspaceId());
        _ = control.schedule.recoverInterruptedNoFail(
            control.scheduleRedaction(),
        );
        if (control.schedule.takeChanged()) control.bumpRevision();
        control.recoverSkillTransactionsForScopeNoFail(.personal);
        control.skill.ensurePersonalCatalog(control.skillProjectionBudget());
        // This is the last ownership move in init: no later operation may fail.
        // The first health observation is committed before App exposes Bridge
        // ingress or loads the Renderer window.
        if (mcp_startup) |*startup| {
            control.mcp = startup.takeRuntime(
                productMcpPorts(
                    executor,
                    agent_runtime,
                    configuration.mcp_refresh_timer,
                    configuration.change_notifier,
                ),
            );
            mcp_startup = null;
            _ = control.syncMcpHealthNoFail();
            control.updateMcpRefreshDeadlineNoFail();
            control.rearmMcpRefreshTimerNoFail();
        }
        preview_lane_owned = false;
        file_change_lane_owned = false;
        return control;
    }

    fn workspaceStorage(self: *Runtime) product_workspace.Storage {
        return .{
            .context = self,
            .copy_fn = copyWorkspaceStorage,
            .project_fn = projectWorkspaceStorage,
            .free_fn = freeWorkspaceStorage,
            .redact_fn = redactWorkspaceStorage,
        };
    }

    pub const FilePreviewAdmission = union(enum) {
        queued,
        immediate: FilePreviewState,
    };

    pub fn prepareAttachmentAdd(self: *Runtime) Error!u64 {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        if (self.attachment_io != null) return error.InputBusy;
        return self.attachments.beginPreparing();
    }
    pub fn cancelAttachmentPreparation(self: *Runtime, id: u64) bool {
        return self.attachments.cancelPreparing(id);
    }
    pub fn beginAttachmentStaging(self: *Runtime, completion_id: u64, path_count: usize, paths: []const u8) Error!void {
        const id = try self.prepareAttachmentAdd();
        return self.beginPreparedAttachmentStaging(completion_id, id, path_count, paths);
    }
    pub fn beginPreparedAttachmentStaging(self: *Runtime, completion_id: u64, id: u64, path_count: usize, paths: []const u8) Error!void {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        if (self.attachment_io != null) return error.InputBusy;
        if (self.attachments.preparing != id) return error.StaleTransfer;
        errdefer _ = self.attachments.cancelPreparing(id);
        try self.attachment_lane.begin(.{ .completion_id = completion_id, .path_count = path_count, .paths = paths, .limits = self.attachments.limits, .file_store = self.attachments.file_store orelse return error.StagingCapacity });
        self.attachment_io = .{ .completion_id = completion_id, .product_id = id };
    }
    pub fn beginPreparedAttachmentBytes(self: *Runtime, completion_id: u64, id: u64, files: []const product_attachment.ReceiveFile) Error!void {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        if (self.attachment_io != null) return error.InputBusy;
        if (self.attachments.preparing != id) return error.StaleTransfer;
        errdefer _ = self.attachments.cancelPreparing(id);
        try self.attachments.reservePrepared(id, files);
        errdefer _ = self.attachments.cancelReceive(id);
        var storage: [lifecycle.multimodal_input_limits.max_parts]product_attachment.store.File = undefined;
        const targets = try self.attachments.writeFiles(id, &storage);
        try self.attachment_lane.beginFiles(completion_id, self.attachments.file_store.?, .initialized, targets, 0, &.{});
        self.attachment_io = .{ .completion_id = completion_id, .product_id = id };
    }
    pub fn appendAttachmentBytes(self: *Runtime, completion_id: u64, id: u64, index: usize, offset: usize, bytes: []const u8) Error!void {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        if (self.attachment_io != null) return error.InputBusy;
        const target = try self.attachments.writeTarget(id, index, offset, bytes.len);
        try self.attachment_lane.beginFiles(completion_id, self.attachments.file_store.?, .written, &.{target}, offset, bytes);
        self.attachment_io = .{ .completion_id = completion_id, .product_id = id, .file_index = index, .offset = offset, .count = bytes.len };
    }
    pub fn finishAttachmentBytes(self: *Runtime, completion_id: u64, id: u64) Error!void {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        if (self.attachment_io != null) return error.InputBusy;
        try self.attachments.validateComplete(id);
        var storage: [lifecycle.multimodal_input_limits.max_parts]product_attachment.store.File = undefined;
        const targets = try self.attachments.writeFiles(id, &storage);
        try self.attachment_lane.beginFiles(completion_id, self.attachments.file_store.?, .validated, targets, 0, &.{});
        self.attachment_io = .{ .completion_id = completion_id, .product_id = id };
    }

    pub fn cancelAttachmentStaging(self: *Runtime, completion_id: u64) bool {
        const op = if (self.attachment_io) |*value| value else return false;
        if (op.completion_id != completion_id) return false;
        op.cancel_requested = true;
        self.attachment_lane.cancel(completion_id);
        return true;
    }
    pub fn drainAttachmentStagingCompletions(self: *Runtime, sink: AttachmentStagingSink) void {
        while (self.attachment_lane.take()) |taken| {
            var transferred = false;
            defer if (!transferred) self.attachment_lane.release(taken);
            const raw = taken.completion;
            const op = self.attachment_io orelse continue;
            if (op.completion_id != raw.completion_id) continue;
            if (op.cancel_requested or raw.cancelled or raw.rejection != null) {
                self.attachment_io = null;
                _ = self.attachments.cancelPreparing(op.product_id);
                _ = self.attachments.cancelReceiveChecked(op.product_id) catch {
                    self.completeAttachmentJob(taken, &transferred, sink, op.completion_id, .{ .rejected = .cleanup_failed });
                    continue;
                };
                self.completeAttachmentJob(taken, &transferred, sink, op.completion_id, if (op.cancel_requested or raw.cancelled) .cancelled else .{ .rejected = raw.rejection.? });
                continue;
            }
            if (raw.phase == .probed) {
                self.attachments.reservePrepared(op.product_id, raw.files) catch |err| {
                    self.attachment_io = null;
                    self.completeAttachmentJob(taken, &transferred, sink, op.completion_id, .{ .rejected = attachment_staging.reject(err) });
                    continue;
                };
                var file_storage: [lifecycle.multimodal_input_limits.max_parts]product_attachment.store.File = undefined;
                const files = self.attachments.writeFiles(op.product_id, &file_storage) catch unreachable;
                self.attachment_lane.continueCopy(taken, files) catch |err| {
                    self.attachment_io = null;
                    _ = self.attachments.cancelReceiveChecked(op.product_id) catch {
                        self.completeAttachmentJob(taken, &transferred, sink, op.completion_id, .{ .rejected = .cleanup_failed });
                        continue;
                    };
                    self.completeAttachmentJob(taken, &transferred, sink, op.completion_id, .{ .rejected = attachment_staging.reject(err) });
                    continue;
                };
                transferred = true;
                continue;
            }
            self.attachment_io = null;
            if (raw.phase == .initialized) {
                self.completeAttachmentJob(taken, &transferred, sink, op.completion_id, .accepted);
                continue;
            }
            if (raw.phase == .written) {
                self.attachments.acknowledgeWrite(op.product_id, op.file_index, op.offset, op.count) catch |err| {
                    self.completeAttachmentJob(taken, &transferred, sink, op.completion_id, .{ .rejected = attachment_staging.reject(err) });
                    continue;
                };
                self.completeAttachmentJob(taken, &transferred, sink, op.completion_id, .accepted);
                continue;
            }
            if (raw.phase == .copied) {
                self.attachments.acknowledgeCopied(op.product_id) catch unreachable;
                self.attachment_io = op;
                self.attachment_lane.continueValidation(taken) catch |err| {
                    self.attachment_io = null;
                    _ = self.attachments.cancelReceiveChecked(op.product_id) catch {
                        self.completeAttachmentJob(taken, &transferred, sink, op.completion_id, .{ .rejected = .cleanup_failed });
                        continue;
                    };
                    self.completeAttachmentJob(taken, &transferred, sink, op.completion_id, .{ .rejected = attachment_staging.reject(err) });
                    continue;
                };
                transferred = true;
                continue;
            }
            var descriptors: [lifecycle.multimodal_input_limits.max_parts]product_attachment.Descriptor = undefined;
            const ready = (if (raw.phase == .validated) self.attachments.finishValidated(op.product_id, &descriptors) else self.attachments.finishReceive(op.product_id, &descriptors)) catch |err| {
                _ = self.attachments.cancelReceiveChecked(op.product_id) catch {
                    self.completeAttachmentJob(taken, &transferred, sink, op.completion_id, .{ .rejected = .cleanup_failed });
                    continue;
                };
                self.completeAttachmentJob(taken, &transferred, sink, op.completion_id, .{ .rejected = attachment_staging.reject(err) });
                continue;
            };
            self.completeAttachmentJob(taken, &transferred, sink, op.completion_id, .{ .ready = ready });
        }
    }

    fn completeAttachmentJob(self: *Runtime, taken: attachment_staging.Taken, released: *bool, sink: AttachmentStagingSink, completion_id: u64, result: AttachmentStagingResult) void {
        self.attachment_lane.release(taken);
        released.* = true;
        sink.complete_fn(sink.context, completion_id, result);
    }

    /// Performs only bounded identity/authority work on the main thread and
    /// submits immutable Host-only input to the preview lane. File I/O never
    /// occurs in this call.
    pub fn beginFilePreview(
        self: *Runtime,
        completion_id: u64,
        task_id: u64,
        run_id: u64,
        reference_id: []const u8,
    ) FilePreviewAdmission {
        if (self.shutting_down or self.preview_executor_shutdown)
            return .{ .immediate = .failed };
        const reference = self.task_runtime.fileReference(
            task_id,
            run_id,
            reference_id,
        ) orelse return .{ .immediate = .missing };
        if (!self.filePreviewWorkspaceAuthorized(reference))
            return .{ .immediate = .restricted };
        if (reference.locator_kind == .uri)
            return .{ .immediate = .unsupported };

        var relative_storage: [4096]u8 = undefined;
        const relative = switch (reference.locator_kind) {
            .workspace_path => reference.locator,
            .absolute_path => absoluteReferenceRelativePath(
                reference.workspace_root,
                reference.locator,
                &relative_storage,
            ) orelse return .{ .immediate = .restricted },
            .uri => unreachable,
        };
        if (relative.len == 0 or relative.len > relative_storage.len)
            return .{ .immediate = .restricted };

        self.preview_lane.begin(.{
            .completion_id = completion_id,
            .task_id = task_id,
            .run_id = run_id,
            .workspace_id = reference.workspace_id,
            .workspace_epoch = reference.workspace_epoch,
            .reference_id = reference.id,
            .workspace_root = reference.workspace_root,
            .relative_path = relative,
            .max_bytes = self.limits.max_file_preview_bytes,
            .max_lines = self.limits.max_file_preview_lines,
            .max_line_bytes = self.limits.max_file_preview_line_bytes,
        }) catch return .{ .immediate = .failed };
        return .queued;
    }

    /// Drains worker-owned raw completions on the main thread. Current Task,
    /// Run, reference and Workspace authority are checked again before any
    /// bytes are projected. Raw buffers remain inside Runtime and are
    /// securely erased immediately after the callback returns.
    pub fn drainFilePreviewCompletions(
        self: *Runtime,
        sink: FilePreviewSink,
    ) void {
        while (self.preview_lane.take()) |taken| {
            defer self.preview_lane.release(taken);
            const raw = taken.completion;
            var state = raw.state;
            var truncated = false;
            var redacted = false;
            var safe_buffer: []u8 = &.{};
            var image_png: []const u8 = &.{};
            var safe_content: []const u8 = &.{};
            defer if (safe_buffer.len != 0) {
                std.crypto.secureZero(u8, safe_buffer);
                self.allocator.free(safe_buffer);
            };

            const reference = self.task_runtime.fileReference(
                raw.task_id,
                raw.run_id,
                raw.reference_id,
            );
            if (reference == null) {
                state = .missing;
            } else if (reference.?.workspace_id != raw.workspace_id or
                reference.?.workspace_epoch != raw.workspace_epoch or
                !std.mem.eql(u8, reference.?.workspace_root, raw.workspace_root) or
                !self.filePreviewWorkspaceAuthorized(reference.?))
            {
                state = .restricted;
            } else if (state == .ready and raw.image) {
                if (self.containsKnownCredential(raw.content)) {
                    state = .restricted;
                } else if (self.attachments.images.prepare_fn) |prepare| {
                    if (prepare(self.attachments.images.context, self.allocator, raw.content, file_preview.max_image_preview_bytes)) |prepared| {
                        safe_buffer = prepared;
                        if (safe_buffer.len == 0 or safe_buffer.len > file_preview.max_image_preview_bytes) {
                            state = .unsupported;
                        } else if (self.containsKnownCredential(safe_buffer)) {
                            state = .restricted;
                        } else {
                            image_png = safe_buffer;
                        }
                    } else |_| state = .failed;
                } else state = .unsupported;
            } else if (state == .ready) {
                const cutoff = self.filePreviewCredentialSafeCutoff(
                    raw.content,
                    raw.truncated,
                );
                truncated = raw.truncated or cutoff < raw.content.len;
                redacted = cutoff < raw.content.len;
                if (cutoff != 0) {
                    safe_buffer = self.allocator.alloc(u8, cutoff) catch {
                        state = .failed;
                        sink.complete_fn(sink.context, .{
                            .completion_id = raw.completion_id,
                            .state = state,
                            .content = "",
                            .truncated = false,
                            .redacted = false,
                        });
                        continue;
                    };
                    const projected = self.sanitizeFilePreviewInto(
                        safe_buffer,
                        raw.content[0..cutoff],
                    );
                    safe_content = safe_buffer[0..projected.len];
                    redacted = projected.redacted or redacted;
                }
            }

            if (state != .ready) {
                safe_content = &.{};
                truncated = false;
                redacted = false;
            }
            sink.complete_fn(sink.context, .{
                .completion_id = raw.completion_id,
                .state = state,
                .content = safe_content,
                .image_png = image_png,
                .truncated = truncated,
                .redacted = redacted,
            });
        }
    }

    fn enqueueFileChangeDiff(
        raw_context: *anyopaque,
        task_id: u64,
        run_generation: u64,
        change_order: u64,
        content: []const u8,
    ) task_runtime.FileChangeDiffAdmission {
        const self: *Runtime = @ptrCast(@alignCast(raw_context));
        const lane = self.file_change_lane orelse return .unavailable;
        if (self.shutting_down or self.file_change_executor_shutdown or
            content.len == 0 or content.len > self.limits.max_file_change_diff_bytes or
            !std.unicode.utf8ValidateSlice(content))
            return .unavailable;
        var safe = self.allocator.alloc(u8, content.len) catch return .unavailable;
        const projected = self.sanitizeFilePreviewInto(safe, content);
        if (projected.len != safe.len) {
            safe = self.allocator.realloc(safe, projected.len) catch {
                std.crypto.secureZero(u8, safe);
                self.allocator.free(safe);
                return .unavailable;
            };
        }
        lane.beginWrite(.{
            .task_id = task_id,
            .run_generation = run_generation,
            .change_order = change_order,
            .content = safe,
            .redacted = projected.redacted,
            .max_bytes = self.limits.max_file_change_diff_bytes,
        }) catch {
            std.crypto.secureZero(u8, safe);
            self.allocator.free(safe);
            return .unavailable;
        };
        return .{ .queued = .{ .redacted = projected.redacted } };
    }

    pub fn beginFileChangeDiff(
        self: *Runtime,
        completion_id: u64,
        task_id: u64,
        run_id: u64,
        file_change_id: []const u8,
    ) FileChangeDiffAdmission {
        if (self.shutting_down or self.file_change_executor_shutdown)
            return .{ .immediate = .capacity };
        const lane = self.file_change_lane orelse
            return .{ .immediate = .not_recorded };
        const reference = self.task_runtime.fileChangeArtifact(
            task_id,
            run_id,
            file_change_id,
        ) orelse return .{ .immediate = .not_recorded };
        lane.beginRead(.{
            .completion_id = completion_id,
            .identity = .{
                .task_id = task_id,
                .run_generation = reference.artifact.run_generation,
                .change_order = reference.artifact.change_order,
                .digest = reference.artifact.digest,
                .byte_size = reference.artifact.byte_size,
            },
            .max_bytes = self.limits.max_file_change_diff_bytes,
            .complete = reference.diff_complete,
            .redacted = reference.redacted,
        }) catch return .{ .immediate = .capacity };
        return .queued;
    }

    pub fn drainFileChangeCompletions(
        self: *Runtime,
        sink: FileChangeDiffSink,
    ) void {
        const lane = self.file_change_lane orelse return;
        while (lane.take()) |taken| {
            defer lane.release(taken);
            switch (taken.completion) {
                .write => |write| {
                    const retained = self.task_runtime.completeFileChangeArtifact(
                        write.task_id,
                        write.run_generation,
                        write.change_order,
                        if (write.identity) |identity| .{
                            .run_generation = identity.run_generation,
                            .change_order = identity.change_order,
                            .digest = identity.digest,
                            .byte_size = identity.byte_size,
                        } else null,
                        write.redacted,
                    );
                    if (retained) {
                        self.commitTaskStateNoFail();
                        self.bumpRevision();
                    } else if (write.identity) |identity| {
                        if (self.file_change_store) |store| store.delete(
                            identity,
                            self.limits.max_file_change_diff_bytes,
                        );
                    }
                },
                .read => |read| {
                    if (!self.task_runtime.ownsFileChangeArtifact(.{
                        .run_generation = read.identity.run_generation,
                        .change_order = read.identity.change_order,
                        .digest = read.identity.digest,
                        .byte_size = read.identity.byte_size,
                    }, read.identity.task_id)) {
                        sink.complete_fn(sink.context, .{ .unavailable = .{
                            .completion_id = read.completion_id,
                            .reason = .not_recorded,
                        } });
                        continue;
                    }
                    switch (read.state) {
                        .ready => {
                            // Artifacts are sanitized when written, but a
                            // credential can become known after that durable
                            // boundary. The lane owns this mutable buffer
                            // through the synchronous sink call and securely
                            // zeros it on release, so scrub the temporary copy
                            // again against every credential that is live now.
                            const content = read.content;
                            const read_redacted = self.redactWithKnownCredentialsNoFail(
                                content,
                            );
                            sink.complete_fn(sink.context, .{ .ready = .{
                                .completion_id = read.completion_id,
                                .content = content,
                                .complete = read.complete,
                                .redacted = read.redacted or read_redacted,
                            } });
                        },
                        .missing => sink.complete_fn(sink.context, .{ .unavailable = .{
                            .completion_id = read.completion_id,
                            .reason = .missing,
                        } }),
                        .corrupt => sink.complete_fn(sink.context, .{ .unavailable = .{
                            .completion_id = read.completion_id,
                            .reason = .corrupt,
                        } }),
                        .failed => sink.complete_fn(sink.context, .{ .unavailable = .{
                            .completion_id = read.completion_id,
                            .reason = .capacity,
                        } }),
                    }
                },
            }
        }
    }

    fn filePreviewWorkspaceAuthorized(
        self: *const Runtime,
        reference: task_runtime.FileReference,
    ) bool {
        return self.workspace.filePreviewAuthorized(
            reference.workspace_id,
            reference.workspace_epoch,
            reference.workspace_root,
        );
    }

    const PreviewProjection = struct {
        len: usize,
        redacted: bool,
    };

    fn sanitizeFilePreviewInto(
        self: *const Runtime,
        output: []u8,
        value: []const u8,
    ) PreviewProjection {
        var read: usize = 0;
        var write: usize = 0;
        var redacted = false;
        while (read < value.len) {
            if (self.knownCredentialEndAtCodepoint(value, read)) |redaction_end| {
                const marker_len = @min(redaction_end - read, 3);
                @memset(output[write..][0..marker_len], '*');
                write += marker_len;
                read = redaction_end;
                redacted = true;
                continue;
            }
            const codepoint_len = utf8CodepointLen(value, read);
            @memcpy(output[write..][0..codepoint_len], value[read..][0..codepoint_len]);
            write += codepoint_len;
            read += codepoint_len;
        }
        return .{ .len = write, .redacted = redacted };
    }

    fn filePreviewCredentialSafeCutoff(
        self: *const Runtime,
        value: []const u8,
        truncated: bool,
    ) usize {
        if (!truncated or value.len == 0) return value.len;
        var index = value.len - @min(
            value.len,
            models_contract.Limits.credential_bytes - 1,
        );
        while (index < value.len and value[index] & 0xc0 == 0x80) index += 1;
        while (index < value.len) {
            if (self.knownCredentialMayContinueAtCodepoint(value, index))
                return index;
            index += utf8CodepointLen(value, index);
        }
        return value.len;
    }

    fn knownCredentialMayContinueAtCodepoint(
        self: *const Runtime,
        value: []const u8,
        codepoint_start: usize,
    ) bool {
        const current = self.execution_state.credential();
        if (credentialMayContinueAtCodepoint(value, codepoint_start, current))
            return true;
        const codepoint_len = utf8CodepointLen(value, codepoint_start);
        for (0..codepoint_len) |offset| {
            if (self.task_runtime.executionCredentialMayContinue(
                value[codepoint_start + offset ..],
            )) return true;
        }
        return false;
    }

    pub fn setScheduleBackgroundAvailableNoFail(
        self: *Runtime,
        available: bool,
    ) void {
        _ = self.schedule.setBackgroundAvailable(
            available,
            self.scheduleExecutionBinding(),
            self.scheduleRedaction(),
        );
        self.publishScheduleChangesNoFail();
    }

    pub fn previewSkillDirectory(
        self: *Runtime,
        absolute_path: []const u8,
    ) Error!skill_runtime.Preview {
        return self.skill.previewDirectory(absolute_path);
    }
    pub fn previewSkillArchive(
        self: *Runtime,
        absolute_path: []const u8,
    ) Error!skill_runtime.Preview {
        return self.skill.previewArchive(absolute_path);
    }
    pub fn installSkillDirectory(
        self: *Runtime,
        absolute_path: []const u8,
        input: SkillInstallInput,
    ) Error!SkillMutationResult {
        try self.requireSkillMutationAuthority(input.scope);
        const previous_health = self.skill.managementHealth();
        const result = self.skill.installDirectory(
            absolute_path,
            input,
            self.schedule.now(),
        ) catch |err| {
            self.publishSkillManagementChanges(previous_health);
            return err;
        };
        _ = self.skill.takeManagementChanged();
        self.bumpRevision();
        return result;
    }

    pub fn installSkillArchive(
        self: *Runtime,
        absolute_path: []const u8,
        input: SkillInstallInput,
    ) Error!SkillMutationResult {
        try self.requireSkillMutationAuthority(input.scope);
        const previous_health = self.skill.managementHealth();
        const result = self.skill.installArchive(
            absolute_path,
            input,
            self.schedule.now(),
        ) catch |err| {
            self.publishSkillManagementChanges(previous_health);
            return err;
        };
        _ = self.skill.takeManagementChanged();
        self.bumpRevision();
        return result;
    }

    pub fn reimportSkillDirectory(
        self: *Runtime,
        install_id: skill_runtime.InstallId,
        absolute_path: []const u8,
        expected_invocation_name: []const u8,
        expected_content_hash: skill_runtime.ContentHash,
    ) Error!SkillMutationResult {
        const scope = try self.skill.assetScope(install_id);
        try self.requireSkillMutationAuthority(scope);
        const previous_health = self.skill.managementHealth();
        const result = self.skill.reimportDirectory(
            install_id,
            absolute_path,
            expected_invocation_name,
            expected_content_hash,
        ) catch |err| {
            self.publishSkillManagementChanges(previous_health);
            return err;
        };
        _ = self.skill.takeManagementChanged();
        self.bumpRevision();
        return result;
    }

    pub fn reimportSkillArchive(
        self: *Runtime,
        install_id: skill_runtime.InstallId,
        absolute_path: []const u8,
        expected_invocation_name: []const u8,
        expected_content_hash: skill_runtime.ContentHash,
    ) Error!SkillMutationResult {
        const scope = try self.skill.assetScope(install_id);
        try self.requireSkillMutationAuthority(scope);
        const previous_health = self.skill.managementHealth();
        const result = self.skill.reimportArchive(
            install_id,
            absolute_path,
            expected_invocation_name,
            expected_content_hash,
        ) catch |err| {
            self.publishSkillManagementChanges(previous_health);
            return err;
        };
        _ = self.skill.takeManagementChanged();
        self.bumpRevision();
        return result;
    }

    pub fn uninstallSkill(
        self: *Runtime,
        install_id: skill_runtime.InstallId,
    ) Error!SkillMutationResult {
        const scope = try self.skill.assetScope(install_id);
        try self.requireSkillMutationAuthority(scope);
        const previous_health = self.skill.managementHealth();
        const result = self.skill.uninstall(
            install_id,
            self.schedule.now(),
        ) catch |err| {
            self.publishSkillManagementChanges(previous_health);
            return err;
        };
        _ = self.skill.takeManagementChanged();
        self.bumpRevision();
        return result;
    }

    pub fn retrySkillVerification(
        self: *Runtime,
        install_id: skill_runtime.InstallId,
    ) Error!SkillMutationResult {
        const scope = try self.skill.assetScope(install_id);
        try self.requireSkillMutationAuthority(scope);
        const previous_health = self.skill.managementHealth();
        const result = self.skill.retryVerification(install_id, self.schedule.now()) catch |err| {
            self.publishSkillManagementChanges(previous_health);
            return err;
        };
        _ = self.skill.takeManagementChanged();
        self.bumpRevision();
        return result;
    }

    fn publishSkillManagementChanges(
        self: *Runtime,
        previous_health: skill_runtime.ManagementHealth,
    ) void {
        const changed = self.skill.takeManagementChanged();
        if (changed or self.skill.managementHealth() != previous_health)
            self.bumpRevision();
    }
    pub fn readSkillDefinition(
        self: *Runtime,
        install_id: skill_runtime.InstallId,
    ) Error!skill_runtime.Preview {
        try self.requireSkillAssetAuthority(try self.skill.assetScope(install_id));
        return self.skill.readDefinition(install_id);
    }
    pub fn exportSkill(
        self: *Runtime,
        install_id: skill_runtime.InstallId,
        absolute_destination: []const u8,
    ) Error!SkillExportResult {
        try self.requireSkillAssetAuthority(try self.skill.assetScope(install_id));
        return self.skill.exportPackage(install_id, absolute_destination);
    }
    pub fn automaticWorkspacesAvailable(self: *const Runtime) bool {
        return self.workspace.automaticRootAvailable() and
            self.skill.identitySourceTrusted();
    }

    pub fn automaticWorkspaceRootConfiguration(
        self: *const Runtime,
    ) AutomaticWorkspaceRootConfigurationView {
        const configuration = self.automatic_root_configuration.configuration;
        const canonical_root = switch (self.automatic_root_configuration.health) {
            .ready => self.workspace.automaticRootPath(),
            .path_unavailable, .write_failed => self.automatic_root_configuration.committedRoot(
                self.automatic_workspace_system_root,
            ),
            .persistence_unavailable,
            .read_failed,
            .corrupt,
            .outcome_unknown,
            => null,
        };
        const mode: ?product_workspace.AutomaticRootConfigurationMode = if (canonical_root != null)
            if (configuration) |value| value.mode else null
        else
            null;
        const store_available = self.automatic_workspace_configuration_store != null and
            !self.shutting_down;
        return .{
            .generation = self.automatic_root_configuration.generation,
            .mode = mode,
            .canonical_root = canonical_root,
            .health = self.automatic_root_configuration.health,
            .can_choose = store_available,
            .can_reset = store_available and
                self.automatic_workspace_system_root != null and
                (configuration == null or
                    configuration.?.mode != .system_default or
                    self.automatic_root_configuration.health != .ready),
            .can_retry = !self.shutting_down and
                self.automatic_root_configuration.health == .path_unavailable and
                canonical_root != null,
        };
    }

    pub fn chooseAutomaticWorkspaceRoot(
        self: *Runtime,
        expected_generation: u64,
        canonical_root: []const u8,
    ) Error!void {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        try self.requireAutomaticRootGeneration(expected_generation);
        var configuration = product_workspace.AutomaticRootConfiguration.custom(
            self.allocator,
            canonical_root,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidWorkspace,
        };
        defer configuration.deinit();
        try self.installAutomaticWorkspaceRoot(&configuration, canonical_root, false);
    }

    pub fn resetAutomaticWorkspaceRoot(
        self: *Runtime,
        expected_generation: u64,
    ) Error!void {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        try self.requireAutomaticRootGeneration(expected_generation);
        const root = self.automatic_workspace_system_root orelse
            return error.WorkspaceUnavailable;
        var configuration = product_workspace.AutomaticRootConfiguration.systemDefault(
            self.allocator,
        );
        defer configuration.deinit();
        try self.installAutomaticWorkspaceRoot(&configuration, root, true);
    }

    pub fn retryAutomaticWorkspaceRoot(
        self: *Runtime,
        expected_generation: u64,
    ) Error!void {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        try self.requireAutomaticRootGeneration(expected_generation);
        if (self.automatic_root_configuration.health != .path_unavailable)
            return error.WorkspaceUnavailable;
        const root_path = self.automatic_root_configuration.committedRoot(
            self.automatic_workspace_system_root,
        ) orelse return error.WorkspaceUnavailable;
        const mode = self.automatic_root_configuration.configuration.?.mode;
        var root = switch (mode) {
            .system_default => product_workspace.AutomaticRoot.open(
                self.io,
                self.allocator,
                root_path,
            ),
            .custom => product_workspace.AutomaticRoot.openExisting(
                self.io,
                self.allocator,
                root_path,
            ),
        } catch return error.WorkspaceUnavailable;
        defer root.deinit();
        if (mode == .custom and !product_workspace.automaticPathEqual(
            root_path,
            root.canonicalPath(),
        )) return error.InvalidWorkspace;
        try self.workspace.validateAutomaticRootCandidate(root.canonicalPath());
        self.workspace.replaceAutomaticRoot(&root);
        self.automatic_root_configuration.health = .ready;
        self.automatic_root_configuration.advanceGeneration();
        self.bumpRevision();
    }

    fn requireAutomaticRootGeneration(
        self: *const Runtime,
        expected_generation: u64,
    ) Error!void {
        if (expected_generation == 0 or
            expected_generation != self.automatic_root_configuration.generation)
            return error.AutomaticWorkspaceRootGenerationMismatch;
    }

    fn installAutomaticWorkspaceRoot(
        self: *Runtime,
        configuration: *const product_workspace.AutomaticRootConfiguration,
        candidate_path: []const u8,
        create: bool,
    ) Error!void {
        const store = self.automatic_workspace_configuration_store orelse
            return error.AutomaticWorkspaceRootPersistenceUnavailable;
        var root = if (create)
            product_workspace.AutomaticRoot.open(
                self.io,
                self.allocator,
                candidate_path,
            ) catch return error.WorkspaceUnavailable
        else
            product_workspace.AutomaticRoot.openExisting(
                self.io,
                self.allocator,
                candidate_path,
            ) catch return error.WorkspaceUnavailable;
        defer root.deinit();
        if (!product_workspace.automaticPathEqual(
            candidate_path,
            root.canonicalPath(),
        )) return error.InvalidWorkspace;
        try self.workspace.validateAutomaticRootCandidate(root.canonicalPath());
        var encoded_storage: [product_workspace.automatic_root_configuration.max_store_bytes]u8 = undefined;
        const encoded = product_workspace.automatic_root_configuration.encode(
            &encoded_storage,
            configuration,
        ) catch return error.InvalidWorkspace;
        var replacement = try configuration.clone();
        var replacement_owned = true;
        defer if (replacement_owned) replacement.deinit();
        const recovering = self.automatic_root_configuration.recovery_required;
        if (recovering)
            store.recover(encoded) catch |err| return self.failAutomaticRootPersistence(err)
        else
            store.commit(encoded) catch |err| return self.failAutomaticRootPersistence(err);

        if (self.automatic_root_configuration.configuration) |*current| current.deinit();
        self.automatic_root_configuration.configuration = replacement;
        replacement_owned = false;
        self.automatic_root_configuration.health = .ready;
        self.automatic_root_configuration.recovery_required = false;
        self.workspace.replaceAutomaticRoot(&root);
        self.automatic_root_configuration.advanceGeneration();
        self.bumpRevision();
    }

    fn failAutomaticRootPersistence(
        self: *Runtime,
        err: product_workspace.automatic_root_configuration.FileStoreError,
    ) Error {
        switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.PersistenceOutcomeUnknown => {
                self.workspace.disableAutomaticRoot();
                self.automatic_root_configuration.health = .outcome_unknown;
                self.automatic_root_configuration.recovery_required = true;
                self.bumpRevision();
                return error.AutomaticWorkspaceRootPersistenceOutcomeUnknown;
            },
            else => {
                if (!self.automatic_root_configuration.recovery_required) {
                    switch (self.automatic_root_configuration.health) {
                        .ready => {
                            self.automatic_root_configuration.health = .write_failed;
                            self.bumpRevision();
                        },
                        .write_failed,
                        .path_unavailable,
                        .persistence_unavailable,
                        .read_failed,
                        .corrupt,
                        .outcome_unknown,
                        => {},
                    }
                }
                return error.AutomaticWorkspaceRootPersistenceFailed;
            },
        }
    }

    pub fn stageAttachments(
        self: *Runtime,
        candidates: []const product_attachment.Candidate,
        output: []product_attachment.Descriptor,
    ) Error![]const product_attachment.Descriptor {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        return self.attachments.stageBatch(candidates, output);
    }

    pub fn attachmentWriterActive(self: *const Runtime) bool {
        return self.attachment_io != null;
    }
    pub fn attachmentCleanupPending(self: *const Runtime, batch_id: ?u64, attachment_id: ?u64) bool {
        return self.attachments.hasCleanupDebt(batch_id, attachment_id);
    }
    pub fn releaseAttachmentChecked(self: *Runtime, id: u64) Error!bool {
        return self.attachments.releaseChecked(id);
    }

    pub fn cancelAttachmentReceiveChecked(self: *Runtime, id: u64) Error!bool {
        return self.attachments.cancelReceiveChecked(id);
    }

    pub fn releaseAttachment(self: *Runtime, id: u64) bool {
        return self.attachments.release(id);
    }

    pub fn beginAttachmentReceive(self: *Runtime, files: []const product_attachment.ReceiveFile) Error!u64 {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        return self.attachments.beginReceive(files);
    }

    pub fn appendAttachmentReceive(self: *Runtime, id: u64, file_index: usize, offset: usize, bytes: []const u8) Error!void {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        return self.attachments.appendReceive(id, file_index, offset, bytes);
    }

    pub fn finishAttachmentReceive(self: *Runtime, id: u64, output: []product_attachment.Descriptor) Error![]const product_attachment.Descriptor {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        return self.attachments.finishReceive(id, output);
    }

    pub fn cancelAttachmentReceive(self: *Runtime, id: u64) bool {
        return self.attachments.cancelReceive(id);
    }

    const ScheduleCredentialRedaction = struct {
        owner: *Runtime,

        pub fn apply(
            self: ScheduleCredentialRedaction,
            credential: []const u8,
        ) Error!void {
            _ = try self.owner.schedule.prepareCredentialRedaction(
                credential,
                self.owner.scheduleRedaction(),
            );
        }
    };

    fn executionProjectionRedaction(
        self: *Runtime,
    ) execution_state.ProjectionRedaction {
        return .{
            .context = self,
            .apply_fn = redactExecutionProjection,
        };
    }

    fn redactExecutionProjection(
        context: *anyopaque,
        credential: []const u8,
    ) void {
        const self: *Runtime = @ptrCast(@alignCast(context));
        self.redactAllProductProjectionsNoFail(credential);
    }

    pub fn commitAccountFactNoFail(
        self: *Runtime,
        fact: account_contract.AccountFact,
    ) void {
        self.account_projection.commitNoFail(fact);
    }

    pub fn commitAccountChangeNoFail(
        self: *Runtime,
        commit: control_ports.AccountCommit,
    ) void {
        commit.assertValid();
        self.commitAccountFactNoFail(commit.fact);
        self.finishAccountCommitNoFail();
    }

    pub fn installExecutionNoFail(
        self: *Runtime,
        execution: *models_contract.OwnedConfig,
    ) void {
        self.invalidateProjectionSecurity();
        self.execution_state.installMetaskNoFail(
            execution,
            execution.input().execution_generation,
            self.executionProjectionRedaction(),
        );
    }

    /// Installs a Host-resolved user Custom Provider execution without
    /// pretending that it is a Metask OAuth account/catalog. The active
    /// execution still uses the same Runtime-owned secret and generation
    /// machinery as the built-in path.
    pub fn prepareCustomProviderBinding(
        self: *Runtime,
        provider_id: []const u8,
        model_id: []const u8,
    ) std.mem.Allocator.Error!PreparedCustomProviderBinding {
        return PreparedCustomProviderBinding.init(
            self.allocator,
            provider_id,
            model_id,
        );
    }

    pub fn installCustomProviderExecutionNoFail(
        self: *Runtime,
        execution: *models_contract.OwnedConfig,
        prepared_binding: *PreparedCustomProviderBinding,
    ) void {
        self.invalidateProjectionSecurity();
        self.execution_state.installCustomProviderNoFail(
            execution,
            prepared_binding,
            self.executionProjectionRedaction(),
        );
    }

    pub fn clearExecutionNoFail(self: *Runtime) void {
        self.invalidateProjectionSecurity();
        self.execution_state.clearNoFail(self.executionProjectionRedaction());
    }

    /// Durably removes every credential that the candidate execution could
    /// expose from Schedule projections before the execution becomes live.
    /// Account and Product Control are separate saga owners: failure leaves
    /// the old execution installed while the committed Account fact closes
    /// admission through the generation mismatch.
    pub fn prepareExecutionInstall(
        self: *Runtime,
        input: models_contract.ConfigInput,
    ) Error!void {
        defer self.publishScheduleChangesNoFail();
        try self.execution_state.prepareInstall(
            input,
            ScheduleCredentialRedaction{ .owner = self },
        );
    }

    /// Durably scrubs the execution being released before its final owned
    /// credential can be cleared and secure-zeroed.
    pub fn prepareExecutionClear(self: *Runtime) Error!void {
        defer self.publishScheduleChangesNoFail();
        try self.execution_state.prepareClear(
            ScheduleCredentialRedaction{ .owner = self },
        );
    }

    pub fn finishAccountCommitNoFail(self: *Runtime) void {
        self.finishDefaultExecutionCommitNoFail();
    }

    fn finishDefaultExecutionCommitNoFail(self: *Runtime) void {
        if (self.canCreateTask()) {
            _ = self.schedule.refreshBindingNoFail(
                self.scheduleExecutionBinding(),
                self.scheduleRedaction(),
            );
            _ = self.schedule.rearmNoFail(
                self.scheduleExecutionBinding(),
                self.scheduleRedaction(),
            );
        } else {
            self.schedule.cancelTimer();
        }
        _ = self.schedule.takeChanged();
        self.bumpRevision();
    }

    pub fn accountView(self: *Runtime) account_contract.AccountView {
        return self.account_projection.view();
    }

    pub fn newTaskAdmissionView(self: *Runtime) execution_state.NewTaskAdmissionView {
        return .{
            .available = self.canCreateTask(),
            .reason = self.execution_state.availabilityError(),
            .active_model_ref = self.execution_state.activeModelRef(),
            .active_generation = self.execution_state.generation(),
            .active_selection_revision = self.execution_state.activeSelectionRevision(),
            .state = self.execution_state.availability(),
        };
    }

    pub fn modelsView(self: *Runtime) models_contract.ModelsView {
        return self.custom_providers.view();
    }

    pub fn startCustomProviders(
        self: *Runtime,
        absolute_directory: []const u8,
        vault: models_ports.CredentialVault,
    ) models_aggregate.StartError!void {
        try self.custom_providers.start(absolute_directory, vault);
        self.reconcileModelsDefaultNoFail(false, false);
        self.finishExecutionCommitNoFail();
    }

    pub fn startCustomProvidersUnavailable(self: *Runtime) void {
        self.custom_providers.startUnavailable();
    }

    pub fn stopCustomProviders(self: *Runtime) void {
        self.custom_providers.stop();
    }

    /// Hard-resets the Models canonical store after an explicit user
    /// confirmation. The snapshot revision is the Product CAS boundary;
    /// Models itself owns the canonical file and credential scrub.
    pub fn resetModelsStore(
        self: *Runtime,
        expected_revision: u64,
    ) models_contract.CommandResult {
        if (self.shutting_down)
            return .rejected(.operation_in_progress);
        if (expected_revision != self.revision)
            return .rejected(.generation_mismatch);
        if (self.executionReplacementPending())
            return .rejected(.operation_in_progress);
        if (self.modelsView().persistence_health != .recovery_required)
            return .rejected(.persistence_unavailable);
        const result = self.custom_providers.resetStore();
        if (!result.accepted) return result;
        self.reconcileModelsDefaultNoFail(false, false);
        self.finishExecutionCommitNoFail();
        return result;
    }

    pub fn selectModelsDefault(
        self: *Runtime,
        command: models_contract.SelectDefaultCommand,
    ) models_contract.CommandResult {
        if (self.shutting_down)
            return .rejected(.operation_in_progress);
        if (self.executionReplacementPending())
            return .rejected(.operation_in_progress);
        const result = self.custom_providers.selectDefault(command);
        if (result.accepted) {
            self.reconcileModelsDefaultNoFail(false, false);
            self.finishExecutionCommitNoFail();
        }
        return result;
    }

    pub fn configureMetaskSelection(
        self: *Runtime,
        command: models_contract.ConfigureMetaskSelectionCommand,
    ) models_contract.CommandResult {
        if (self.shutting_down)
            return .rejected(.operation_in_progress);
        if (self.executionReplacementPending())
            return .rejected(.operation_in_progress);
        const result = self.custom_providers.configureMetaskSelection(command);
        if (result.accepted) {
            self.reconcileModelsDefaultNoFail(false, false);
            self.finishExecutionCommitNoFail();
        }
        return result;
    }

    pub fn submitCustomProviderCommand(
        self: *Runtime,
        command: models_contract.CustomProviderCommand,
    ) models_contract.CommandResult {
        if (command == .test_model)
            return .rejected(.test_unavailable);
        const result = self.custom_providers.submitCommand(command);
        if (result.accepted) {
            self.reconcileModelsDefaultNoFail(true, false);
            self.finishExecutionCommitNoFail();
        }
        return result;
    }

    pub fn beginCustomProviderProbe(
        self: *Runtime,
        command: models_contract.CustomModelTestCommand,
    ) models_contract.Preparation {
        const execution_generation = self.nextExecutionGeneration(
            self.executionGeneration(),
        ) catch return .{ .rejected = .local_resource_exhausted };
        var candidate = self.custom_providers.resolveProbeCandidate(command) catch
            return .{ .rejected = .test_unavailable };
        defer candidate.deinit();
        var execution = candidate.intoConfig(execution_generation) catch
            return .{ .rejected = .test_unavailable };
        const result = self.custom_providers.submitCommand(.{
            .test_model = command,
        });
        if (!result.accepted) {
            execution.deinit();
            return .{ .rejected = result.error_code.? };
        }
        self.finishExecutionCommitNoFail();
        return .{ .ready = execution };
    }

    pub fn completeCustomModelTest(
        self: *Runtime,
        command: models_contract.CustomModelTestCommand,
        succeeded: bool,
    ) models_contract.CommandResult {
        const result = self.custom_providers.completeTest(command, succeeded);
        if (result.accepted) {
            self.reconcileModelsDefaultNoFail(true, false);
            self.finishExecutionCommitNoFail();
        }
        return result;
    }

    pub fn prepareMetaskCatalogRefresh(
        self: *Runtime,
        principal_ref: []const u8,
        authorization_generation: u64,
    ) models_contract.CatalogRefreshPrepareResult {
        return self.custom_providers.prepareMetaskCatalogRefresh(
            principal_ref,
            authorization_generation,
        );
    }

    pub fn completeMetaskCatalogRefresh(
        self: *Runtime,
        attempt_id: u64,
        authorization_generation: u64,
        completion: *models_ports.OwnedCatalogCompletion,
    ) models_contract.ModelsError {
        const result = self.custom_providers.completeMetaskCatalogRefresh(
            attempt_id,
            authorization_generation,
            completion,
        );
        if (result == .none)
            self.reconcileModelsDefaultNoFail(true, false);
        self.finishExecutionCommitNoFail();
        return result;
    }

    pub fn failMetaskCatalogRefresh(
        self: *Runtime,
        attempt_id: u64,
        authorization_generation: u64,
        error_code: models_contract.ModelsError,
        safe_diagnostic: []const u8,
    ) void {
        self.custom_providers.failMetaskCatalogRefresh(
            attempt_id,
            authorization_generation,
            error_code,
            safe_diagnostic,
        );
        self.finishExecutionCommitNoFail();
    }

    pub fn setMetaskAuthorizationUnavailable(self: *Runtime) void {
        self.custom_providers.setMetaskAuthorizationUnavailable();
        self.reconcileModelsDefaultNoFail(false, true);
        self.finishExecutionCommitNoFail();
    }

    pub fn createCustomProviderWithCredential(
        self: *Runtime,
        secret: []const u8,
        spec: models_contract.CustomProviderSpec,
    ) models_contract.CommandResult {
        const result = self.custom_providers.createWithCredential(
            secret,
            spec,
        );
        if (result.accepted) self.finishExecutionCommitNoFail();
        return result;
    }

    pub fn createBuiltinProviderWithCredential(
        self: *Runtime,
        secret: []const u8,
        provider_id: models_contract.BuiltinProviderId,
        base_url: []const u8,
    ) models_contract.CommandResult {
        const result = self.custom_providers.createBuiltinWithCredential(
            secret,
            provider_id,
            base_url,
        );
        if (result.accepted) self.finishExecutionCommitNoFail();
        return result;
    }

    pub fn updateBuiltinProviderBaseUrl(
        self: *Runtime,
        selection: models_contract.CustomProviderSelectionCommand,
        base_url: []const u8,
    ) models_contract.CommandResult {
        const result = self.custom_providers.updateBuiltinBaseUrl(selection, base_url);
        if (result.accepted) {
            self.reconcileModelsDefaultNoFail(false, false);
            self.finishExecutionCommitNoFail();
        }
        return result;
    }

    pub fn replaceCustomProviderCredential(
        self: *Runtime,
        secret: []const u8,
        selection: models_contract.CustomProviderSelectionCommand,
    ) models_contract.CommandResult {
        const result = self.custom_providers.replaceCredential(secret, selection);
        // The fail-closed first phase may revoke stale readiness even when the
        // subsequent credential write or final commit fails.
        self.reconcileModelsDefaultNoFail(false, false);
        self.finishExecutionCommitNoFail();
        return result;
    }

    pub fn clearCustomProviderDefault(self: *Runtime) models_contract.CommandResult {
        const result = self.custom_providers.clearDefault();
        if (result.accepted) {
            self.reconcileModelsDefaultNoFail(false, false);
            self.finishExecutionCommitNoFail();
        }
        return result;
    }

    pub fn nextExecutionGeneration(self: *Runtime, current: u64) !u64 {
        return self.custom_providers.nextGeneration(current);
    }

    fn reconcileModelsDefaultNoFail(
        self: *Runtime,
        refresh_aligned: bool,
        clear_unresolvable: bool,
    ) void {
        const desired = self.custom_providers.defaultAuthority() orelse {
            if (self.execution_state.hasRecordedDefaultAuthority())
                self.clearRecordedModelsDefaultNoFail();
            return;
        };
        const default_aligned = self.execution_state.defaultAuthorityMatches(desired);
        const execution_authority_aligned = self.execution_state.executionAuthorityMatches(desired);
        if (default_aligned and !refresh_aligned and !clear_unresolvable) return;

        var candidate = (self.custom_providers.resolveDefault() catch {
            if (clear_unresolvable and
                self.execution_state.hasRecordedDefaultAuthority() and
                self.execution_state.activeSource() == .metask)
                self.clearRecordedModelsDefaultNoFail()
            else
                self.execution_state.recordAvailabilityErrorNoFail(.invalid_candidate);
            return;
        }) orelse {
            if (clear_unresolvable and
                self.execution_state.hasRecordedDefaultAuthority() and
                self.execution_state.activeSource() == .metask)
                self.clearRecordedModelsDefaultNoFail()
            else
                self.execution_state.recordAvailabilityErrorNoFail(.invalid_candidate);
            return;
        };
        defer candidate.deinit();
        const candidate_input = candidate.input();
        if (candidate.source != desired.source or
            candidate_input.source_generation != desired.source_generation or
            candidate_input.target.protocol != desired.protocol or
            !std.mem.eql(
                u8,
                candidate_input.target.model,
                desired.selection.model_id,
            ))
        {
            self.execution_state.recordAvailabilityErrorNoFail(.invalid_candidate);
            return;
        }

        const installed = self.execution_state.executionInput();
        const image_declarations_aligned = installed != null and models_contract.sameImageCapabilities(installed.?.target.image_capabilities, candidate_input.target.image_capabilities);
        const execution_generation = if (execution_authority_aligned and image_declarations_aligned)
            self.executionGeneration()
        else
            self.nextExecutionGeneration(self.executionGeneration()) catch {
                self.execution_state.recordAvailabilityErrorNoFail(.resource_exhausted);
                return;
            };
        var execution = candidate.intoConfig(execution_generation) catch {
            self.execution_state.recordAvailabilityErrorNoFail(.invalid_candidate);
            return;
        };
        defer execution.deinit();
        var prepared_binding: ?PreparedCustomProviderBinding = if (desired.source == .custom_provider)
            self.prepareCustomProviderBinding(
                desired.selection.source_id,
                desired.selection.model_id,
            ) catch {
                self.execution_state.recordAvailabilityErrorNoFail(.resource_exhausted);
                return;
            }
        else
            null;
        defer if (prepared_binding) |*binding| binding.deinit();

        if (self.executionReplacementPending()) {
            self.execution_state.recordAvailabilityErrorNoFail(.invalid_candidate);
            return;
        }
        self.beginDefaultExecutionReplacement() catch {
            self.execution_state.recordAvailabilityErrorNoFail(.invalid_candidate);
            return;
        };
        var replacement_started = true;
        defer if (replacement_started) self.endExecutionReplacementNoFail();
        self.execution_state.prepareInstall(
            execution.input(),
            ScheduleCredentialRedaction{ .owner = self },
        ) catch |err| {
            self.execution_state.rejectReplacementNoFail(metaskStageError(err));
            return;
        };
        self.invalidateProjectionSecurity();
        switch (desired.source) {
            .metask => self.execution_state.installMetaskNoFail(
                &execution,
                desired.source_generation,
                self.executionProjectionRedaction(),
            ),
            .custom_provider => self.execution_state.installCustomProviderNoFail(
                &execution,
                &prepared_binding.?,
                self.executionProjectionRedaction(),
            ),
        }
        self.execution_state.recordDefaultAuthorityNoFail(desired);
        prepared_binding = null;
        replacement_started = false;
        self.endExecutionReplacementNoFail();
    }

    fn clearRecordedModelsDefaultNoFail(self: *Runtime) void {
        if (!self.execution_state.hasRecordedDefaultAuthority()) return;
        if (self.executionReplacementPending()) {
            self.execution_state.recordAvailabilityErrorNoFail(.invalid_candidate);
            return;
        }
        self.beginDefaultExecutionReplacement() catch {
            self.execution_state.recordAvailabilityErrorNoFail(.invalid_candidate);
            return;
        };
        var replacement_started = true;
        defer if (replacement_started) self.endExecutionReplacementNoFail();
        self.execution_state.prepareClear(
            ScheduleCredentialRedaction{ .owner = self },
        ) catch |err| {
            self.execution_state.rejectReplacementNoFail(metaskStageError(err));
            return;
        };
        self.clearExecutionNoFail();
        replacement_started = false;
        self.endExecutionReplacementNoFail();
    }

    pub fn finishExecutionCommitNoFail(self: *Runtime) void {
        self.finishDefaultExecutionCommitNoFail();
    }

    pub fn customProviderExecutionActive(
        self: *const Runtime,
        provider_id: []const u8,
    ) bool {
        return self.execution_state.customProviderActive(provider_id);
    }

    pub fn customProviderExecutionSelected(self: *const Runtime) bool {
        return self.execution_state.customProviderSelected();
    }

    pub fn executionGeneration(self: *const Runtime) u64 {
        return self.execution_state.generation();
    }

    /// Automation composes its fixture through the same Models authority and
    /// Product reconciliation path as a user-created Custom Provider. Release
    /// builds reject this Application-only bootstrap before observing input.
    pub fn installAutomationExecution(
        self: *Runtime,
        input: AutomationExecutionInput,
    ) Error!void {
        if (!build_options.automation)
            return error.InvalidAutomationExecution;
        var view = self.modelsView();
        if (view.custom_providers.len > 1)
            return error.InvalidAutomationExecution;

        if (view.custom_providers.len == 0) {
            if (!self.createCustomProviderWithCredential(
                input.credential,
                .{
                    .display_name = "Automation fixture",
                    .protocol = input.protocol,
                    .normalized_base_url = input.base_url,
                },
            ).accepted) return error.InvalidAutomationExecution;
            view = self.modelsView();
            if (view.custom_providers.len != 1)
                return error.InvalidAutomationExecution;
            const provider = view.custom_providers[0];
            if (!self.submitCustomProviderCommand(.{ .add_custom_model = .{
                .source_id = provider.id,
                .expected_provider_revision = provider.provider_revision,
                .expected_catalog_generation = provider.catalog_generation,
                .model = .{
                    .id = input.model,
                    .display_name = input.model,
                },
            } }).accepted) return error.InvalidAutomationExecution;
        } else {
            const restored = view.custom_providers[0];
            if (restored.credential_status != .missing or
                !std.mem.eql(u8, restored.display_name, "Automation fixture") or
                restored.protocol != input.protocol or
                !std.mem.eql(u8, restored.normalized_base_url, input.base_url) or
                restored.models.len != 1 or
                !std.mem.eql(u8, restored.models[0].id, input.model) or
                !self.replaceCustomProviderCredential(input.credential, .{
                    .source_id = restored.id,
                    .expected_provider_revision = restored.provider_revision,
                }).accepted) return error.InvalidAutomationExecution;
        }

        view = self.modelsView();
        if (view.custom_providers.len != 1)
            return error.InvalidAutomationExecution;
        const created = view.custom_providers[0];
        if (created.models.len != 1 or
            !std.mem.eql(u8, created.models[0].id, input.model))
            return error.InvalidAutomationExecution;
        // Every accepted Models command swaps the committed Registry. Keep the
        // connection identity owned across those commits instead of borrowing
        // it from a view that the first probe commit invalidates.
        const provider_id = try self.allocator.dupe(u8, created.id);
        defer self.allocator.free(provider_id);
        const probe_command: models_contract.CustomModelTestCommand = .{
            .model = .{ .source_id = provider_id, .model_id = input.model },
            .expected_provider_revision = created.provider_revision,
            .expected_source_generation = created.source_generation,
            .expected_catalog_generation = created.catalog_generation,
        };
        var probe = switch (self.beginCustomProviderProbe(probe_command)) {
            .ready => |execution| execution,
            .rejected => return error.InvalidAutomationExecution,
        };
        // The vertical provides the endpoint; it does not perform a second
        // network probe during Application bootstrap. Releasing this owned
        // config before completion preserves the normal probe ownership shape.
        probe.deinit();
        if (!self.completeCustomModelTest(probe_command, true).accepted)
            return error.InvalidAutomationExecution;

        view = self.modelsView();
        if (view.custom_providers.len != 1)
            return error.InvalidAutomationExecution;
        const ready = view.custom_providers[0];
        if (!self.selectModelsDefault(.{
            .selection = .{ .source_id = provider_id, .model_id = input.model },
            .expected_selection_revision = view.selection_revision,
            .expected_source_generation = ready.source_generation,
            .expected_catalog_generation = ready.catalog_generation,
        }).accepted) return error.InvalidAutomationExecution;

        const default_authority = self.custom_providers.defaultAuthority() orelse
            return error.InvalidAutomationExecution;
        if (default_authority.source != .custom_provider or
            default_authority.source_generation == 0 or
            default_authority.selection_revision == 0 or
            !self.customProviderExecutionActive(provider_id) or
            !self.canCreateTask()) return error.InvalidAutomationExecution;
    }

    pub fn beginExecutionReplacement(self: *Runtime) Error!void {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        self.syncLifecycle();
        // Identity replacement changes only Account-owned admission defaults.
        // Live Tasks keep their owned ExecutionConfig until their own runtime
        // lifecycle releases it, so their references cannot block this gate.
        try self.execution_state.beginIdentityReplacement();
    }

    pub fn beginDefaultExecutionReplacement(self: *Runtime) Error!void {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        self.syncLifecycle();
        try self.execution_state.beginDefaultReplacement();
    }

    pub fn endExecutionReplacementNoFail(self: *Runtime) void {
        self.execution_state.endReplacementNoFail();
    }

    pub fn executionReplacementPending(self: *const Runtime) bool {
        return self.execution_state.replacementPending();
    }

    pub fn identityReplacementPending(self: *const Runtime) bool {
        return self.execution_state.identityReplacementPending();
    }

    pub fn defaultExecutionReplacementPending(self: *const Runtime) bool {
        return self.execution_state.defaultReplacementPending();
    }

    /// Registers or reauthorizes a manually selected Workspace.
    pub fn openWorkspace(
        self: *Runtime,
        input: TaskCreateInput,
    ) Error!u64 {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        self.syncLifecycle();
        return self.openWorkspaceInternal(input);
    }

    fn openWorkspaceInternal(
        self: *Runtime,
        input: TaskCreateInput,
    ) Error!u64 {
        var preparation = try self.workspace.prepareOpen(
            input.workspace_root,
            switch (input.trust) {
                .explicitly_trusted => .explicitly_trusted,
                .temporary => |root| .{ .temporary = root },
            },
            self.execution_state.credential(),
            self.workspaceStorage(),
            .{
                .context = self,
                .automatic_contains_fn = automaticWorkspaceContains,
                .reusable_fn = hiddenWorkspaceReusable,
                .allocation_allowed = self.skill.identitySourceTrusted(),
            },
        );
        errdefer if (preparation.isActive())
            self.workspace.rollbackOpen(&preparation, self.workspaceStorage());
        const workspace = self.workspace.preparedFacts(&preparation);
        const skill_root = try self.allocator.dupe(u8, workspace.canonical_root);
        var skill_root_owned = true;
        defer if (skill_root_owned) self.allocator.free(skill_root);
        self.commitTaskStateBestEffort() catch |err| {
            self.workspace.rollbackOpen(&preparation, self.workspaceStorage());
            return err;
        };
        if (self.workspace.commitOpen(&preparation, self.workspaceStorage())) |displaced_id| {
            std.debug.assert(self.skill.unregisterWorkspace(
                displaced_id,
                self.skillProjectionBudget(),
            ));
            // The id has left the registry for good; its Skill provenance and
            // policy retire with it. Files under the old root are untouched.
            _ = self.skill.retireWorkspace(displaced_id, self.skillProjectionBudget());
        }
        self.skill.registerWorkspaceOwned(.{
            .id = workspace.id,
            .epoch = workspace.epoch,
            .catalog_authorized = workspaceSkillCatalogAuthorized(workspace),
            .personal_only = workspace.kind == .automatic,
            .canonical_root = skill_root,
        }, self.skillProjectionBudget());
        skill_root_owned = false;
        self.workspace.redactNoFail(
            self.execution_state.credential(),
            self.workspaceStorage(),
        );
        self.recoverSkillTransactionsForScopeNoFail(.{ .project = .{
            .workspace_id = workspace.id,
            .workspace_epoch = workspace.epoch,
        } });
        self.skill.ensureWorkspaceCatalog(
            workspace.id,
            workspace.epoch,
            self.skillProjectionBudget(),
        ) catch unreachable;
        self.bumpRevision();
        return workspace.id;
    }

    fn workspaceSkillCatalogAuthorized(workspace: product_workspace.Facts) bool {
        return workspace.kind == .manual and workspace.visible and workspace.authorization == .available;
    }

    fn skillBudgetAvailable(context: *anyopaque, reclaimable: usize) usize {
        const self: *Runtime = @ptrCast(@alignCast(context));
        std.debug.assert(self.projection_bytes <= self.limits.max_projection_bytes);
        std.debug.assert(reclaimable <= self.projection_bytes);
        return self.limits.max_projection_bytes - self.projection_bytes + reclaimable;
    }

    fn skillBudgetReplace(context: *anyopaque, old: usize, new: usize) void {
        const self: *Runtime = @ptrCast(@alignCast(context));
        std.debug.assert(old <= self.projection_bytes);
        const retained = self.projection_bytes - old;
        std.debug.assert(new <= self.limits.max_projection_bytes - retained);
        self.projection_bytes = retained + new;
    }

    fn skillProjectionBudget(self: *Runtime) skill_runtime.ProjectionBudget {
        return .{
            .context = self,
            .available_fn = skillBudgetAvailable,
            .replace_fn = skillBudgetReplace,
        };
    }

    fn syncSkillCatalogsNoFail(self: *Runtime) bool {
        return self.skill.sync(
            self.skillProjectionBudget(),
            catalogSnapshotLimits(self.limits),
            self.schedule.now(),
        );
    }

    /// Runs only after Task/Session publication; prepared Schedule workspaces
    /// never acquire a catalog or a job and keep required durable admission.
    fn syncInitialAutomaticCatalogsNoFail(self: *Runtime) bool {
        if (self.shutting_down) return false;
        var changed = false;
        for (0..self.workspace.slotCount()) |index| {
            const workspace = self.workspace.factsAt(index) orelse continue;
            if (workspace.kind != .automatic or workspace.automatic_task_id == 0) continue;
            const task_id = workspace.automatic_task_id;
            const projection = self.task_runtime.catalogProjection(task_id) orelse continue;
            if (self.task_runtime.initialCatalogNeeded(task_id)) {
                self.task_runtime.markInitialCatalog(task_id, true);
                changed = true;
                if (self.canonical_user_home == null or workspace.authorization != .available) {
                    self.task_runtime.markInitialCatalog(task_id, false);
                    continue;
                }
                self.skill.setWorkspaceCatalogAuthorized(workspace.id, workspace.epoch, true, self.skillProjectionBudget()) catch {
                    self.task_runtime.markInitialCatalog(task_id, false);
                    continue;
                };
                self.skill.ensureWorkspaceCatalog(workspace.id, workspace.epoch, self.skillProjectionBudget()) catch {
                    self.task_runtime.markInitialCatalog(task_id, false);
                    continue;
                };
            } else if (projection.availability != .loading) continue;
            const authority = self.skill.workspaceCatalogAuthority(workspace.id, workspace.epoch) catch {
                self.task_runtime.markInitialCatalog(task_id, false);
                changed = true;
                continue;
            };
            switch (authority) {
                .loading => {},
                .ready, .degraded => {
                    const binding_epoch = self.task_runtime.taskBindingEpoch(task_id) orelse continue;
                    // The public refresh transaction consumes the same binding
                    // identity, but sync must not recursively invoke lifecycle.
                    self.installTaskCatalog(task_id, binding_epoch) catch {
                        self.task_runtime.markInitialCatalog(task_id, false);
                    };
                    changed = true;
                },
                .uninitialized, .unavailable => {
                    self.task_runtime.markInitialCatalog(task_id, false);
                    changed = true;
                },
            }
        }
        return changed;
    }

    pub fn workspaceCatalog(
        self: *const Runtime,
        workspace_id: u64,
    ) Error!CatalogProjection {
        const workspace = self.workspace.binding(workspace_id) orelse
            return error.UnknownWorkspace;
        return self.skill.workspaceCatalogProjection(workspace.id, workspace.epoch);
    }

    pub fn skillCatalog(self: *const Runtime) CatalogProjection {
        return self.skill.personalCatalogProjection();
    }

    pub fn refreshSkillCatalog(self: *Runtime) Error!void {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        self.syncLifecycle();
        try self.skill.refreshPersonal();
        self.bumpRevision();
    }

    pub fn setSkillSourceEnabled(self: *Runtime, brand: SkillSourceBrand, enabled: bool, expected_revision: u64) skill_runtime.SourceSettingsResult {
        self.syncLifecycle();
        const result = self.skill.setSourceEnabled(brand, enabled, expected_revision, self.skillProjectionBudget());
        if (result.changed) {
            _ = self.syncSkillCatalogsNoFail();
            self.bumpRevision();
        }
        return result;
    }

    pub fn recoverSkillSourceSettings(self: *Runtime, action: skill_runtime.SourceRecoveryAction, expected_token: u64) skill_runtime.SourceSettingsResult {
        self.syncLifecycle();
        const result = self.skill.recoverSourceSettings(action, expected_token, self.skillProjectionBudget());
        if (result.changed) {
            _ = self.syncSkillCatalogsNoFail();
            self.bumpRevision();
        }
        return result;
    }

    pub fn setSkillEnabled(
        self: *Runtime,
        mutation: SkillEnablementMutation,
    ) Error!u64 {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        self.syncLifecycle();
        switch (mutation.scope) {
            .personal => {},
            .project => |project| {
                const workspace = self.workspace.facts(project.workspace_id) orelse
                    return error.UnknownWorkspace;
                if (workspace.kind != .manual or !workspace.visible or
                    workspace.authorization != .available)
                    return error.WorkspaceUnavailable;
                if (project.expected_workspace_epoch == 0 or
                    project.expected_workspace_epoch != workspace.epoch)
                    return error.WorkspaceEpochMismatch;
            },
        }
        const previous_health = self.skill.enablementHealth();
        const next_revision = self.skill.setEnabled(
            mutation,
            self.skillProjectionBudget(),
            catalogSnapshotLimits(self.limits),
        ) catch |err| {
            if (self.skill.enablementHealth() != previous_health) self.bumpRevision();
            return err;
        };
        if (next_revision != mutation.expected_selection_revision or
            self.skill.enablementHealth() != previous_health)
            self.bumpRevision();
        return next_revision;
    }
    pub fn refreshMcpCatalog(self: *Runtime) Error!void {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        self.syncLifecycle();
        const runtime = if (self.mcp) |*value| value else return error.CatalogUnavailable;
        const started = runtime.requestRefresh(false) catch |err| return @errorCast(err);
        self.bumpRevision();
        if (!started) return error.CatalogLoading;
    }

    /// Native one-shot timer ingress. Refresh work is always enqueued on the
    /// bounded Runtime executor; the main thread never performs catalog I/O.
    pub fn onMcpRefreshTimer(self: *Runtime) void {
        if (self.shutting_down) return;
        self.syncLifecycle();
        if (self.mcp) |*runtime|
            if (runtime.onRefreshTimer()) self.bumpRevision();
    }

    pub fn taskCatalog(
        self: *const Runtime,
        task_id: u64,
    ) Error!CatalogProjection {
        return self.task_runtime.catalogProjection(task_id) orelse error.UnknownTask;
    }

    pub fn refreshWorkspaceCatalog(
        self: *Runtime,
        workspace_id: u64,
        expected_workspace_epoch: u64,
    ) Error!void {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        self.syncLifecycle();
        const workspace = self.workspace.facts(workspace_id) orelse
            return error.UnknownWorkspace;
        if (workspace.epoch != expected_workspace_epoch)
            return error.WorkspaceEpochMismatch;
        if ((workspace.kind == .manual and !workspace.visible) or workspace.authorization != .available)
            return error.WorkspaceUnavailable;
        if (workspace.kind == .automatic and (self.task_runtime.taskPermissionInteraction(workspace.automatic_task_id) != .interactive or
            !self.task_runtime.continuationAvailable(workspace.automatic_task_id, self.taskRuntimeProjectionEffects())))
            return error.WorkspaceUnavailable;
        try self.skill.refreshWorkspace(workspace.id, workspace.epoch);
        self.bumpRevision();
    }

    pub fn refreshTaskCatalog(
        self: *Runtime,
        task_id: u64,
        expected_binding_epoch: u64,
    ) Error!void {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        self.syncLifecycle();
        try self.installTaskCatalog(task_id, expected_binding_epoch);
    }

    fn installTaskCatalog(self: *Runtime, task_id: u64, expected_binding_epoch: u64) Error!void {
        const facts = try self.task_runtime.catalogRefreshFacts(
            task_id,
            expected_binding_epoch,
        );
        const workspace = self.workspace.facts(facts.workspace_id) orelse
            return error.WorkspaceUnavailable;
        if (!self.skill.enablementTrusted())
            return error.RecoveryUnavailable;
        if (workspace.epoch != facts.workspace_epoch)
            return error.WorkspaceEpochMismatch;
        const authority = switch (try self.skill.workspaceCatalogAuthority(
            workspace.id,
            workspace.epoch,
        )) {
            .ready, .degraded => |value| value,
            .loading => return error.CatalogLoading,
            .uninitialized, .unavailable => return error.CatalogUnavailable,
        };
        const current = authority.snapshot;
        const lease = authority.lease;
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
        const replacement_bytes = replacement.projected_bytes;
        const old_bytes = try self.task_runtime.installCatalogRefresh(
            task_id,
            expected_binding_epoch,
            lease,
            granted_skill_ids.items,
            &replacement,
        );
        self.projection_bytes -= old_bytes;
        self.projection_bytes += replacement_bytes;
        self.bumpRevision();
    }

    pub fn workspaceEpoch(self: *const Runtime, workspace_id: u64) Error!u64 {
        const workspace = self.workspace.facts(workspace_id) orelse
            return error.UnknownWorkspace;
        return workspace.epoch;
    }

    pub fn workspaceKind(
        self: *const Runtime,
        workspace_id: u64,
    ) Error!WorkspaceKind {
        const workspace = self.workspace.facts(workspace_id) orelse
            return error.UnknownWorkspace;
        return workspace.kind;
    }

    pub fn taskWorkspaceId(self: *const Runtime, task_id: u64) Error!u64 {
        return self.task_runtime.taskWorkspaceId(task_id) orelse error.UnknownTask;
    }

    pub fn taskPermissionProfile(self: *const Runtime, task_id: u64) Error!PermissionProfile {
        return self.task_runtime.taskPermissionProfile(task_id) orelse error.UnknownTask;
    }

    pub fn taskPermissionInteraction(
        self: *const Runtime,
        task_id: u64,
    ) Error!PermissionInteraction {
        return self.task_runtime.taskPermissionInteraction(task_id) orelse error.UnknownTask;
    }

    /// Copies the canonical Workspace projection without allocating. Hidden
    /// Manual Workspaces that are no longer registered remain omitted;
    /// Automatic Workspaces stay projected so
    /// their Task routes remain addressable. Aggregate signals are computed
    /// from canonical Task state.
    pub fn copyWorkspaceProjections(
        self: *const Runtime,
        output: []WorkspaceProjection,
    ) Error![]const WorkspaceProjection {
        return product_workspace.copyProjections(
            &self.workspace,
            output,
            self.workspaceViewProvider(),
        );
    }

    /// Removes a Workspace from navigation, makes future Run admission fail
    /// closed, and starts closing every live Task Session in that Workspace.
    /// Task history and files remain owned by their original systems.
    pub fn removeWorkspace(
        self: *Runtime,
        workspace_id: u64,
    ) Error!void {
        const workspace = self.workspace.facts(workspace_id) orelse
            return error.UnknownWorkspace;
        return self.removeWorkspaceAtEpoch(workspace_id, workspace.epoch);
    }

    pub fn removeWorkspaceAtEpoch(
        self: *Runtime,
        workspace_id: u64,
        expected_workspace_epoch: u64,
    ) Error!void {
        const mcp_refresh_needed = self.syncLifecycleFacts();
        defer if (mcp_refresh_needed) self.recoverExpiredMcpCatalogNoFail();
        var preparation = try self.workspace.prepareRemoval(
            workspace_id,
            expected_workspace_epoch,
        );
        errdefer if (preparation.isActive()) self.workspace.rollbackRemoval(&preparation);
        const workspace = self.workspace.preparedRemovalFacts(&preparation);
        const skill_root = try self.allocator.dupe(u8, workspace.canonical_root);
        var skill_root_owned = true;
        defer if (skill_root_owned) self.allocator.free(skill_root);
        self.commitTaskStateBestEffort() catch |err| {
            self.workspace.rollbackRemoval(&preparation);
            return err;
        };
        self.workspace.commitRemoval(&preparation);
        self.skill.registerWorkspaceOwned(.{
            .id = workspace.id,
            .epoch = workspace.epoch,
            .catalog_authorized = workspaceSkillCatalogAuthorized(workspace),
            .personal_only = workspace.kind == .automatic,
            .canonical_root = skill_root,
        }, self.skillProjectionBudget());
        skill_root_owned = false;
        self.bumpRevision();
        defer self.reapTaskInputResources();
        if (!self.task_runtime.releaseWorkspaceSessions(workspace_id, .{
            .context = self,
            .release_fn = releaseTaskRuntimeSession,
        })) {
            self.workspace.failRemovalStart(workspace_id);
            const restored = self.workspace.facts(workspace_id) orelse unreachable;
            self.skill.setWorkspaceCatalogAuthorized(restored.id, restored.epoch, workspaceSkillCatalogAuthorized(restored), self.skillProjectionBudget()) catch unreachable;
            self.commitTaskStateNoFail();
            self.bumpRevision();
            return error.TaskClosing;
        }
        if (self.finalizeWorkspaceRemovalsNoFail()) {
            self.commitTaskStateNoFail();
            self.bumpRevision();
        }
    }

    pub fn createTask(
        self: *Runtime,
        input: TaskCreateInput,
    ) Error!u64 {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        self.syncLifecycle();
        if (self.executionReplacementPending())
            return error.ExecutionInUse;
        if (!self.canCreateTask())
            return error.ExecutionUnavailable;
        if (!self.task_runtime.hasCapacity()) return error.TaskCapacity;
        const workspace_id = try self.openWorkspaceInternal(input);
        return self.createTaskInWorkspaceInternal(
            workspace_id,
            (self.workspace.facts(workspace_id) orelse return error.UnknownWorkspace).epoch,
            self.execution_state.generation(),
            self.execution_state.activeSelectionRevision(),
            null,
            null,
            null,
            .{ .interactive = input.approval_mode },
            false,
        );
    }

    pub fn createTaskInWorkspace(
        self: *Runtime,
        workspace_id: u64,
        expected_workspace_epoch: u64,
        expected_execution_generation: u64,
        expected_selection_revision: u64,
        model_selection: ?NewTaskModelSelectionInput,
        expected_skill_catalog_revision: ?[]const u8,
        expected_skill_selection_revision: ?u64,
        permission: TaskPermissionRequest,
    ) Error!u64 {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        self.syncLifecycle();
        return self.createTaskInWorkspaceInternal(
            workspace_id,
            expected_workspace_epoch,
            expected_execution_generation,
            expected_selection_revision,
            model_selection,
            expected_skill_catalog_revision,
            expected_skill_selection_revision,
            permission,
            false,
        );
    }

    pub fn createTaskForWorkspace(
        self: *Runtime,
        request: TaskWorkspaceRequest,
        expected_execution_generation: u64,
        expected_selection_revision: u64,
        model_selection: ?NewTaskModelSelectionInput,
        expected_skill_catalog_revision: ?[]const u8,
        expected_skill_selection_revision: ?u64,
        permission: TaskPermissionRequest,
    ) Error!u64 {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        self.syncLifecycle();
        return switch (request) {
            .manual => |manual| self.createTaskInWorkspaceInternal(
                manual.workspace_id,
                manual.expected_epoch,
                expected_execution_generation,
                expected_selection_revision,
                model_selection,
                expected_skill_catalog_revision,
                expected_skill_selection_revision,
                permission,
                false,
            ),
            .automatic => self.createAutomaticTask(
                expected_execution_generation,
                expected_selection_revision,
                model_selection,
                expected_skill_catalog_revision,
                expected_skill_selection_revision,
                permission,
            ),
        };
    }

    fn createTaskInWorkspaceInternal(
        self: *Runtime,
        workspace_id: u64,
        expected_workspace_epoch: u64,
        expected_execution_generation: u64,
        expected_selection_revision: u64,
        model_selection: ?NewTaskModelSelectionInput,
        expected_skill_catalog_revision: ?[]const u8,
        expected_skill_selection_revision: ?u64,
        permission: TaskPermissionRequest,
        allow_unowned_automatic: bool,
    ) Error!u64 {
        const remembered_mode: ?ApprovalMode = switch (permission) {
            .interactive => |mode| mode orelse self.default_approval_mode,
            .noninteractive => null,
        };
        const previous_default_mode = self.default_approval_mode;
        var prepared = try self.prepareTaskInWorkspaceInternal(
            workspace_id,
            expected_workspace_epoch,
            expected_execution_generation,
            expected_selection_revision,
            model_selection,
            expected_skill_catalog_revision,
            expected_skill_selection_revision,
            permission,
            allow_unowned_automatic,
        );
        if (remembered_mode) |mode| self.default_approval_mode = mode;
        self.commitTaskStateBestEffort() catch |err| {
            self.default_approval_mode = previous_default_mode;
            prepared.rollback(self);
            return err;
        };
        const task_id = prepared.complete(self);
        self.bumpRevision();
        return task_id;
    }

    fn prepareTaskInWorkspaceInternal(
        self: *Runtime,
        workspace_id: u64,
        expected_workspace_epoch: u64,
        expected_execution_generation: u64,
        expected_selection_revision: u64,
        model_selection: ?NewTaskModelSelectionInput,
        expected_skill_catalog_revision: ?[]const u8,
        expected_skill_selection_revision: ?u64,
        permission: TaskPermissionRequest,
        allow_unowned_automatic: bool,
    ) Error!PreparedTaskCreate {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        try self.validateNewTaskModelAdmission(expected_execution_generation, expected_selection_revision, model_selection);
        const workspace_view = try self.workspace.taskCreateAuthority(
            workspace_id,
            expected_workspace_epoch,
            allow_unowned_automatic,
        );
        var pinned_catalog: ?CatalogSnapshot = null;
        errdefer if (pinned_catalog) |*snapshot| {
            self.projection_bytes -= snapshot.projected_bytes;
            snapshot.deinit();
        };
        var catalog_lease: ?*lifecycle.CatalogLease = null;
        switch (try self.skill.workspaceCatalogAuthority(
            workspace_view.id,
            workspace_view.epoch,
        )) {
            .ready, .degraded => |authority| {
                const current = authority.snapshot;
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
                catalog_lease = authority.lease;
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
        var explicit_execution: ?models_contract.OwnedConfig = null;
        defer if (explicit_execution) |*execution| execution.deinit();
        const execution_input = if (model_selection) |selection| selected: {
            var source = (self.custom_providers.resolveModel(selection.target, selection.expected_source_generation, selection.expected_catalog_generation) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.ExecutionUnavailable,
            }) orelse return error.ModelSelectionChanged;
            defer source.deinit();
            const generation = self.nextExecutionGeneration(self.executionGeneration()) catch return error.ExecutionUnavailable;
            explicit_execution = source.intoConfig(generation) catch return error.ExecutionUnavailable;
            break :selected explicit_execution.?.input();
        } else self.execution_state.executionInput().?;
        const permission_profile: PermissionProfile = switch (permission) {
            .interactive => |mode| (mode orelse self.default_approval_mode).profile(),
            .noninteractive => |profile| profile,
        };
        const permission_interaction: PermissionInteraction = switch (permission) {
            .interactive => .interactive,
            .noninteractive => .noninteractive,
        };
        var order_preparation = if (workspace_view.kind == .manual)
            try self.workspace.prepareOrder(workspace_view.id)
        else
            product_workspace.OrderPreparation.inactive();
        errdefer if (order_preparation.isActive())
            self.workspace.rollbackOrder(&order_preparation);
        var order_context = TaskWorkspaceOrderContext{
            .workspace = &self.workspace,
            .preparation = &order_preparation,
        };
        var mcp_selection = if (self.mcp) |*mcp|
            mcp.selectionForNewTask()
        else
            null;
        var mcp_authority: product_task.McpAuthorityAtCreation = if (self.mcp) |*mcp|
            if (mcp.newTaskAuthorityReady())
                if (mcp_selection == null) .ready_without_selection else .ready_with_selection
            else
                .unavailable
        else
            .unavailable;
        var task_input: task_runtime.CreateTaskInput = .{
            .agent_runtime = self.agent_runtime,
            .execution = execution_input,
            .protocol = execution_input.target.protocol,
            .model = execution_input.target.model,
            .model_ref = if (model_selection) |selection| selection.target else self.execution_state.activeModelRef(),
            .source_generation = if (model_selection) |selection| selection.expected_source_generation else self.execution_state.activeSourceGeneration(),
            .permission_profile = permission_profile,
            .permission_review_delegated = switch (permission) {
                .interactive => |mode| (mode orelse self.default_approval_mode) == .auto_review,
                .noninteractive => false,
            },
            .permission_interaction = permission_interaction,
            .workspace_id = workspace_id,
            .workspace_epoch = workspace_view.epoch,
            .workspace_root = workspace_view.canonical_root,
            .workspace_trust = switch (workspace_view.trust) {
                .explicitly_trusted => .explicitly_trusted,
                .temporary => |root| .{ .temporary = root },
            },
            .canonical_user_home = self.canonical_user_home orelse "",
            .skill_catalog = catalog_lease,
            .granted_skill_ids = granted_skill_ids.items,
            .mcp_selection = mcp_selection,
            .mcp_authority = mcp_authority,
            .pinned_catalog = &pinned_catalog,
            .max_workspace_bytes = self.limits.max_workspace_bytes,
            .max_title_bytes = self.limits.max_task_title_bytes,
            .max_model_id_bytes = models_contract.Limits.model_id_bytes,
            .max_runs = self.limits.max_runs_per_task,
            .max_compacts = self.limits.max_compacts_per_task,
            .max_ui_history = self.limits.max_ui_history_per_task,
            .workspace_order = .{
                .context = &order_context,
                .manual = workspace_view.kind == .manual,
                .recent_order = order_preparation.recentOrder(),
                .apply_fn = applyTaskWorkspaceOrder,
                .rollback_fn = rollbackTaskWorkspaceOrder,
            },
            .text = self.taskRuntimeTextProjection(),
            .release = self.taskRuntimeReleaseEffects(),
        };
        const prepared = self.task_runtime.openTask(task_input) catch |err| switch (err) {
            error.SessionCapacity => return error.TaskCapacity,
            error.McpNotRefreshed => retry: {
                self.recoverExpiredMcpCatalogNoFail();
                mcp_selection = null;
                mcp_authority = .unavailable;
                task_input.mcp_selection = mcp_selection;
                task_input.mcp_authority = mcp_authority;
                break :retry self.task_runtime.openTask(task_input) catch |retry_err| switch (retry_err) {
                    error.SessionCapacity => return error.TaskCapacity,
                    else => return retry_err,
                };
            },
            else => return err,
        };
        return .{ .task = prepared, .order = order_preparation };
    }

    fn createAutomaticTask(
        self: *Runtime,
        expected_execution_generation: u64,
        expected_selection_revision: u64,
        model_selection: ?NewTaskModelSelectionInput,
        expected_skill_catalog_revision: ?[]const u8,
        expected_skill_selection_revision: ?u64,
        permission: TaskPermissionRequest,
    ) Error!u64 {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        try self.validateNewTaskModelAdmission(expected_execution_generation, expected_selection_revision, model_selection);
        if (expected_skill_catalog_revision != null or
            expected_skill_selection_revision != null)
            return error.CatalogUnavailable;
        if (!self.task_runtime.hasCapacity()) return error.TaskCapacity;
        if (!self.workspace.automaticCapacityAvailable())
            return error.WorkspaceCapacity;
        var automatic = try self.prepareAutomaticWorkspace();
        errdefer if (automatic.workspace.isActive()) automatic.rollback(self);
        const workspace = automatic.facts(self);
        const task_id = try self.createTaskInWorkspaceInternal(
            workspace.id,
            workspace.epoch,
            expected_execution_generation,
            expected_selection_revision,
            model_selection,
            null,
            null,
            permission,
            true,
        );
        self.workspace.setAutomaticOwner(workspace.id, task_id);
        automatic.complete(self);
        _ = self.syncInitialAutomaticCatalogsNoFail();
        return task_id;
    }

    fn prepareScheduledAdmission(
        self: *Runtime,
        input: product_schedule.TaskLaunch,
    ) Error!PreparedScheduledAdmission {
        if (!self.task_runtime.hasCapacity()) return error.TaskCapacity;
        if (!self.workspace.automaticCapacityAvailable())
            return error.WorkspaceCapacity;
        var automatic = try self.prepareAutomaticWorkspace();
        var automatic_live = true;
        errdefer if (automatic_live) automatic.rollback(self);
        const workspace = automatic.facts(self);
        var task = try self.prepareTaskInWorkspaceInternal(
            workspace.id,
            workspace.epoch,
            self.execution_state.generation(),
            self.execution_state.activeSelectionRevision(),
            null,
            null,
            null,
            .{ .noninteractive = taskProfileFromSchedule(input.permission_profile) },
            true,
        );
        var task_live = true;
        errdefer if (task_live) task.rollback(self);
        self.workspace.setAutomaticOwner(workspace.id, task.id());
        try self.task_runtime.renameTask(
            task.id(),
            input.title,
            self.limits.max_task_title_bytes,
            self.taskRuntimeTextProjection(),
        );
        const binding_epoch = self.task_runtime.taskBindingEpoch(task.id()) orelse
            unreachable;
        var model_target = try self.resolveTaskRunModel(task.id());
        defer if (model_target) |*target| target.deinit();
        var run_effects = self.taskRuntimeOperationEffects();
        const image_workspace = try self.workspace.taskRunAuthority(workspace.id, workspace.epoch);
        var image = self.prepareRunImage(image_workspace);
        defer if (image) |*value| value.deinit();
        run_effects.image_execution = &image;
        run_effects.model_target = if (model_target) |*target| target.input() else null;
        var run = try self.task_runtime.startRun(
            task.id(),
            binding_epoch,
            .{ .text = input.input },
            .{
                .context = self,
                .manual = false,
                .recent_order = 0,
                .apply_fn = ignoreTaskWorkspaceOrder,
                .rollback_fn = ignoreTaskWorkspaceOrder,
            },
            run_effects,
        );
        errdefer run.rollback();
        task_live = false;
        automatic_live = false;
        return .{
            .control = self,
            .workspace = automatic,
            .task = task,
            .run = run,
        };
    }

    fn prepareTaskRestoreFilters(self: *Runtime, task_id: u64, original: *const lifecycle.SessionRestoreInputs) Error!struct { skill: ?*lifecycle.SkillRestoreInputs, mcp: ?*lifecycle.McpSelection, mcp_catalog_generation: ?u64 } {
        const task = self.task_runtime.find(task_id) orelse return error.UnknownTask;
        var skill: ?*lifecycle.SkillRestoreInputs = null;
        errdefer if (skill) |value| value.deinit() catch {};
        if (original.skill) |captured| {
            const pinned = task.runtime.pinnedCatalogConst() orelse retained: {
                break :retained if (task.runtime.restore_catalog) |*snapshot| snapshot else return error.CatalogUnavailable;
            };
            const ids = try self.skill.restoreCeiling(task.durable.workspace_id, task.durable.workspace_epoch, pinned.view());
            defer self.skill.allocator.free(ids);
            skill = try captured.narrow(.{ .granted_skill_ids = ids });
        }
        if (original.mcp) |captured| {
            const mcp = if (self.mcp) |*value| value else return error.RecoveryUnavailable;
            var authority = try mcp.restoreAuthority(captured);
            const selection = authority.selection;
            authority.selection = null;
            const generation = authority.catalog_generation;
            authority.deinit();
            return .{ .skill = skill, .mcp = selection, .mcp_catalog_generation = generation };
        }
        return .{ .skill = skill, .mcp = null, .mcp_catalog_generation = null };
    }

    fn sameRestoreFilters(capabilities: *const task_runtime.RestoreCapabilities, current: anytype) bool {
        if (capabilities.mcp_catalog_generation != current.mcp_catalog_generation) return false;
        const before_ids = if (capabilities.skill) |value| value.borrow().policy.granted_skill_ids else &.{};
        const after_ids = if (current.skill) |value| value.borrow().policy.granted_skill_ids else &.{};
        if (before_ids.len != after_ids.len) return false;
        for (before_ids, after_ids) |before, after| if (!std.mem.eql(u8, before, after)) return false;
        const before_tools = if (capabilities.mcp) |value| value.selectedTools() else &.{};
        const after_tools = if (current.mcp) |value| value.selectedTools() else &.{};
        if (before_tools.len != after_tools.len) return false;
        for (before_tools, after_tools) |before, after|
            if (!std.mem.eql(u8, before.server_id, after.server_id) or !std.mem.eql(u8, before.name, after.name)) return false;
        return true;
    }

    fn modelRestoreCapabilitiesExact(self: *Runtime, task_id: u64) bool {
        const task = self.task_runtime.find(task_id) orelse return false;
        const job = task.runtime.restore_job orelse return false;
        const rebind = if (job.rebind) |*value| value else return false;
        if (task.durable.approval_revision != rebind.approval_revision) return false;
        const capabilities = if (rebind.capabilities) |*value| value else return true;
        const current = self.prepareTaskRestoreFilters(task_id, &capabilities.original) catch return false;
        defer if (current.skill) |value| value.deinit() catch {};
        defer if (current.mcp) |value| value.deinit();
        return sameRestoreFilters(capabilities, current);
    }

    fn refreshModelRestoreCapabilities(context: *anyopaque, task_id: u64) bool {
        const self: *Runtime = @ptrCast(@alignCast(context));
        const task = self.task_runtime.find(task_id) orelse return false;
        const job = task.runtime.restore_job orelse return false;
        const rebind = if (job.rebind) |*value| value else return false;
        const capabilities = if (rebind.capabilities) |*value| value else return true;
        const current = self.prepareTaskRestoreFilters(task_id, &capabilities.original) catch return false;
        if (capabilities.skill) |value| value.deinit() catch {
            capabilities.skill = null;
            if (current.skill) |replacement| replacement.deinit() catch {};
            if (current.mcp) |replacement| replacement.deinit();
            return false;
        };
        if (capabilities.mcp) |value| value.deinit();
        capabilities.skill = current.skill;
        capabilities.mcp = current.mcp;
        capabilities.mcp_catalog_generation = current.mcp_catalog_generation;
        return true;
    }

    fn beginTaskModelRebind(self: *Runtime, task_id: u64, expected_binding_epoch: u64, target: *const models_contract.OwnedSourceCandidate) Error!u64 {
        const task = self.task_runtime.find(task_id) orelse return error.UnknownTask;
        if (task.runtime.active_operation != .none or task.runtime.worker_leases.hasLive()) return error.RestoreBusy;
        const attached = task.runtime.hasAttachedSession();
        if (task.durable.archived or task.read_only_history != null) return error.RecoveryUnavailable;
        if (!attached) _ = try self.task_runtime.recoveryStartFacts(task_id, expected_binding_epoch, self.taskRuntimeRecoveryAdmissionEffects());
        if (attached and (!self.task_persistence_health.operational() or self.checkpoint_store == null or self.checkpoint_store_health.load(.acquire) != .ready))
            return error.RecoveryUnavailable;
        const workspace = try self.workspace.taskRunAuthority(task.durable.workspace_id, task.durable.workspace_epoch);
        const binding = self.workspace.recoveryBinding(workspace.id) orelse return error.RecoveryUnavailable;
        const home = self.canonical_user_home orelse return error.RecoveryUnavailable;
        const intent = task.durable.model_intent orelse return error.RecoveryUnavailable;
        const authority = self.taskModelIntentAuthority(task_id) orelse return error.ExecutionUnavailable;
        self.learnProjectionCredential(target.input().api_key);
        var capabilities: ?task_runtime.RestoreCapabilities = null;
        defer if (capabilities) |*value| value.deinit() catch {};
        if (attached) {
            var access = try task.runtime.acquireAccess();
            defer access.deinit();
            var original = try access.captureRestoreInputs();
            var original_owned = true;
            defer if (original_owned) original.deinit() catch {};
            const filters = try self.prepareTaskRestoreFilters(task_id, &original);
            capabilities = .{ .original = original, .skill = filters.skill, .mcp = filters.mcp, .mcp_catalog_generation = filters.mcp_catalog_generation };
            original_owned = false;
        }
        const execution = target.input();
        // A cold restore may reuse an already resolved immutable connection.
        // Only exact full authority permits reuse; an absent or unrelated
        // global default still resolves independently and gets a new identity.
        const active = self.execution_state.executionInput();
        const same_connection = !attached and active != null and self.execution_state.activeSourceGeneration() == execution.source_generation and
            models_contract.sameImageCapabilities(active.?.target.image_capabilities, execution.target.image_capabilities) and
            active.?.target.protocol == execution.target.protocol and std.mem.eql(u8, active.?.target.provider_id, execution.target.provider_id) and
            std.mem.eql(u8, active.?.target.base_url, execution.target.base_url) and std.mem.eql(u8, active.?.api_key, execution.api_key);
        const generation = if (same_connection) active.?.execution_generation else self.nextExecutionGeneration(@max(self.executionGeneration(), task.durable.execution_generation)) catch return error.ExecutionUnavailable;
        const config: models_contract.ConfigInput = .{ .execution_generation = generation, .target = execution.target, .api_key = execution.api_key };
        const attempt = try self.task_runtime.startRecovery(task_id, .{
            .expected_binding_epoch = expected_binding_epoch,
            .workspace_id = workspace.id,
            .workspace_epoch = task.durable.workspace_epoch,
            .workspace_root = binding.canonical_root,
            .canonical_user_home = home,
            .workspace_trust = switch (binding.trust) {
                .explicitly_trusted => .explicitly_trusted,
                .temporary => .temporary,
            },
            .workspace_kind = switch (binding.kind) {
                .manual => .manual,
                .automatic => .automatic,
            },
            .execution = config,
            .source_generation = execution.source_generation,
            .agent_runtime = self.agent_runtime,
            .checkpoint_store = self.checkpoint_store,
            .checkpoint_store_health = &self.checkpoint_store_health,
            .checkpoint_limits = checkpoint_export_limits,
            .notifier = .{ .context = self.change_notifier.context, .notify_fn = self.change_notifier.wake },
            .executor = .{ .context = self, .enqueue_fn = enqueueTaskRuntimeExecutor, .cancel_fn = cancelTaskRuntimeExecutor },
            .rebind = .{ .source_id = intent.source_id, .selection_revision = intent.revision, .catalog_generation = authority.catalog_generation, .capabilities = if (attached) &capabilities else null, .text = self.taskRuntimeTextProjection() },
        });
        self.bumpRevision();
        return attempt;
    }

    /// Admits an explicit attachment reconstruction. Success means only that
    /// the bounded recovery attempt was enqueued; the canonical Snapshot owns
    /// publication of the eventual result.
    pub fn restoreTaskConversation(
        self: *Runtime,
        task_id: u64,
        expected_binding_epoch: u64,
    ) Error!u64 {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        if (self.task_runtime.findConst(task_id)) |task| if (task.model_intent_prepared) return error.TaskPersistenceOutcomeUnknown;
        self.syncLifecycle();
        if (self.task_runtime.findConst(task_id)) |task| {
            if (task.runtime.active_operation != .none) return error.RecoveryUnavailable;
            var target = try self.resolveTaskRunModel(task_id);
            defer if (target) |*value| value.deinit();
            if (target) |*value| if (task.runtime.attachment == .detached or
                (task.runtime.hasAttachedSession() and !task.runtime.executionConst().?.matchesSource(value.input())))
                return self.beginTaskModelRebind(task_id, expected_binding_epoch, value);
        }
        self.syncLifecycle();
        const facts = try self.task_runtime.recoveryStartFacts(
            task_id,
            expected_binding_epoch,
            self.taskRuntimeRecoveryAdmissionEffects(),
        );
        const workspace = self.workspace.recoveryBinding(facts.workspace_id) orelse unreachable;
        const canonical_user_home = self.canonical_user_home orelse unreachable;
        const execution = self.execution_state.executionInput().?;
        const workspace_trust: task_runtime.RecoveryWorkspaceTrust = switch (workspace.trust) {
            .explicitly_trusted => .explicitly_trusted,
            .temporary => .temporary,
        };
        const attempt_id = try self.task_runtime.startRecovery(task_id, .{
            .expected_binding_epoch = expected_binding_epoch,
            .workspace_id = workspace.id,
            .workspace_epoch = workspace.epoch,
            .workspace_root = workspace.canonical_root,
            .canonical_user_home = canonical_user_home,
            .workspace_trust = workspace_trust,
            .workspace_kind = switch (workspace.kind) {
                .manual => .manual,
                .automatic => .automatic,
            },
            .execution = execution,
            .source_generation = self.execution_state.activeSourceGeneration(),
            .agent_runtime = self.agent_runtime,
            .checkpoint_store = self.checkpoint_store,
            .checkpoint_limits = checkpoint_export_limits,
            .notifier = .{
                .context = self.change_notifier.context,
                .notify_fn = self.change_notifier.wake,
            },
            .executor = .{
                .context = self,
                .enqueue_fn = enqueueTaskRuntimeExecutor,
                .cancel_fn = cancelTaskRuntimeExecutor,
            },
        });
        self.bumpRevision();
        return attempt_id;
    }

    pub fn setApprovalMode(self: *Runtime, task_id: u64, target: product_task.ApprovalMode, expected_binding_epoch: u64, expected_revision: u64) Error!u64 {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        const mcp_refresh_needed = self.syncLifecycleFacts();
        defer if (mcp_refresh_needed) self.recoverExpiredMcpCatalogNoFail();
        const revision = try self.task_runtime.beginApprovalChange(task_id, expected_binding_epoch, expected_revision, target, self.taskRuntimeRecoveryAdmissionEffects());
        const task = self.task_runtime.find(task_id).?;
        if (task.approval_change == null) return revision;
        if (task.durable.permission_profile != target.profile() and task.runtime.active_operation == .run) {
            _ = self.task_runtime.cancelRun(task_id, task.runtime.active_operation.run, self.taskRuntimeOperationEffects()) catch {
                self.failApprovalChange(task_id, .cancelled, false);
                self.bumpRevision();
                return revision;
            };
            self.approval_history_dirty = true;
        }
        // Invalidation happened at admission, before any queued reviewer result
        // could be accepted. Cancellation never waits for that independent job.
        self.syncPermissionReviews();
        self.bumpRevision();
        _ = self.syncApprovalChanges();
        return revision;
    }

    fn approvalExecutor(self: *Runtime) product_task.ApprovalExecutor {
        return .{ .context = self, .enqueue_fn = enqueueApprovalRuntimeExecutor, .cancel_fn = cancelApprovalRuntimeExecutor };
    }

    fn cancelApprovalRuntimeExecutor(context: *anyopaque, identity: *anyopaque) bool {
        const self: *Runtime = @ptrCast(@alignCast(context));
        return self.approval_executor.cancel(identity);
    }

    fn enqueueApprovalRuntimeExecutor(context: *anyopaque, identity: *anyopaque, job_context: *anyopaque, execute_fn: *const fn (*anyopaque) void, cancel_fn: *const fn (*anyopaque) void) error{ ExecutorShuttingDown, QueueFull }!void {
        const self: *Runtime = @ptrCast(@alignCast(context));
        return self.approval_executor.enqueue(.{ .identity = identity, .context = job_context, .execute_fn = execute_fn, .cancel_fn = cancel_fn });
    }

    fn approvalNotifier(self: *Runtime) product_task.ApprovalNotifier {
        return .{ .context = self.change_notifier.context, .notify_fn = self.change_notifier.wake };
    }

    fn approvalHistoryBlocked(self: *const Runtime) bool {
        return self.approval_history_unknown != null or self.task_runtime.approvalHistoryBlocked();
    }

    fn encodeApprovalCandidate(self: *Runtime, task_id: u64) Error![]u8 {
        const prepared = try self.task_runtime.prepareApprovalCommit(task_id);
        defer prepared.rollback();
        return self.encodeTaskHistoryCandidate(if (prepared.checkpoint) |record|
            .{ .task_id = task_id, .record = record, .anchor = .available }
        else
            null);
    }

    fn encodeTaskHistoryCandidate(self: *Runtime, checkpoint: ?CheckpointPersistenceOverride) Error![]u8 {
        var scratch = try self.buildTaskStateWireWithCheckpoint(checkpoint);
        defer scratch.deinit();
        const output = try self.allocator.alloc(u8, task_persistence.max_store_bytes);
        defer self.allocator.free(output);
        const bytes = try task_persistence.encodePreserving(output, scratch.state, scratch.preserved, self.taskPersistenceLimits());
        if (self.containsKnownCredential(bytes)) return error.TaskStoreEncodeFailed;
        return self.allocator.dupe(u8, bytes);
    }

    fn queueApprovalProjection(self: *Runtime, resolve_only: bool) !void {
        const bytes = if (resolve_only)
            try self.allocator.dupe(u8, self.approval_history_unknown orelse return error.TaskBusy)
        else
            try self.encodeTaskHistoryCandidate(null);
        errdefer self.allocator.free(bytes);
        try self.task_runtime.queueApprovalProjection(bytes, self.task_persistence, resolve_only, self.approvalExecutor(), self.approvalNotifier());
        if (!resolve_only) self.approval_history_dirty = false;
    }

    fn failApprovalChange(self: *Runtime, task_id: u64, reason: task_runtime.ApprovalFailureReason, restore_required: bool) void {
        const task = self.task_runtime.find(task_id) orelse return;
        const change = task.approval_change orelse return;
        const rejected = if (change.candidate) |record| record.blob else null;
        const canonical = if (task.durable.checkpoint) |record| record.blob else null;
        self.task_runtime.failApprovalChange(task_id, reason, restore_required);
        // Callers have proved a rejection, including an explicit unknown
        // readback of the old canonical frame. Never retire the recovery point
        // still named by that frame, or infer rejection from an unknown result.
        if (!self.shutting_down) if (rejected) |identity| {
            if (canonical) |old| if (std.meta.eql(old, identity)) return;
            if (self.checkpoint_store) |store|
                self.task_runtime.queueApprovalRetirement(store, identity, self.approvalExecutor(), self.approvalNotifier()) catch {};
        };
    }

    fn beginApprovalRecovery(self: *Runtime, task_id: u64) bool {
        const task = self.task_runtime.find(task_id) orelse return false;
        var change = task.approval_change orelse return false;
        task.approval_change = null;
        defer {
            task.approval_change = change;
            task.approval_change.?.binding_epoch = task.durable.binding_epoch;
        }
        change.recovery_attempt_id = self.restoreTaskConversation(task_id, task.durable.binding_epoch) catch return false;
        return true;
    }

    fn syncApprovalChanges(self: *Runtime) bool {
        if (self.approval_syncing) return false;
        self.approval_syncing = true;
        defer self.approval_syncing = false;
        var changed = false;
        var history_confirmed = false;
        // Reap every completed worker before admitting another store write.
        for (&self.task_runtime.approval_jobs) |*entry| {
            const slot = entry.* orelse continue;
            if (!slot.job.completionReady()) continue;
            const task_id = slot.task_id;
            if (task_id == 0) {
                if (slot.job.work == .history) {
                    const resolve_only = slot.job.work.history.resolve_only;
                    switch (slot.job.outcome) {
                        .history => |result| switch (result) {
                            .committed, .failed => {
                                if (resolve_only) {
                                    if (self.pending_model_intent) |*intent| {
                                        if (result == .committed) intent.complete() else intent.rollback();
                                        self.pending_model_intent = null;
                                    }
                                    self.allocator.free(self.approval_history_unknown.?);
                                    self.approval_history_unknown = null;
                                    self.approval_history_dirty = true;
                                }
                                if (resolve_only or result == .committed)
                                    self.task_persistence_health = .ready
                                else {
                                    self.approval_history_dirty = true;
                                    self.markTaskPersistenceWriteFailed();
                                }
                            },
                            .outcome_unknown => {
                                if (!resolve_only) {
                                    std.debug.assert(self.approval_history_unknown == null);
                                    self.approval_history_unknown = slot.job.takeHistory().?;
                                }
                                self.approval_history_dirty = true;
                                self.task_persistence_health = .outcome_unknown;
                            },
                        },
                        .none, .failure, .checkpoint, .retired => if (!resolve_only) {
                            self.approval_history_dirty = true;
                            if (!self.shutting_down) self.markTaskPersistenceWriteFailed();
                        },
                    }
                    changed = true;
                }
                slot.job.deinit();
                entry.* = null;
                continue;
            }
            const task = self.task_runtime.find(task_id) orelse unreachable;
            if (slot.restore_attempt_id) |attempt_id| {
                const restore = task.runtime.restore_job orelse unreachable;
                std.debug.assert(restore.attempt.attempt_id == attempt_id);
                const resolve_only = slot.job.work.history.resolve_only;
                switch (slot.job.outcome) {
                    .history => |outcome| {
                        restore.binding_commit = switch (outcome) {
                            .committed => .committed,
                            .failed => .failed,
                            .outcome_unknown => .outcome_unknown,
                        };
                        switch (outcome) {
                            .committed, .failed => {
                                if (restore.unknown_history) |bytes| self.allocator.free(bytes);
                                restore.unknown_history = null;
                                task.runtime.last_restore_failure = if (outcome == .failed) .binding_persistence_failed else null;
                                if (outcome == .committed or resolve_only)
                                    self.task_persistence_health = .ready
                                else
                                    self.markTaskPersistenceWriteFailed();
                            },
                            .outcome_unknown => {
                                if (!resolve_only) restore.unknown_history = slot.job.takeHistory().?;
                                self.task_persistence_health = .outcome_unknown;
                                task.runtime.last_restore_failure = .binding_persistence_unknown;
                            },
                        }
                    },
                    .none, .failure, .checkpoint, .retired => if (!resolve_only) {
                        restore.binding_commit = .failed;
                        const cancelled = slot.job.outcome == .failure and slot.job.outcome.failure.reason == .cancelled;
                        if (cancelled) task.runtime.last_restore_failure = .cancelled;
                        if (!cancelled and !self.shutting_down) self.markTaskPersistenceWriteFailed();
                    },
                }
                slot.job.deinit();
                entry.* = null;
                changed = true;
                continue;
            }
            const change = task.approval_change.?;
            const mode_commit = if (change.phase == .outcome_unknown) if (change.unknown_history) |history| history.mode_commit else false else change.phase == .mode_commit;
            const phase = change.phase;
            const outcome = slot.job.outcome;
            const unknown_bytes = if (outcome == .history and outcome.history == .outcome_unknown and !slot.job.work.history.resolve_only)
                slot.job.takeHistory()
            else
                null;
            const record = slot.job.takeCheckpoint();
            slot.job.deinit();
            entry.* = null;
            changed = true;
            switch (outcome) {
                .checkpoint => self.task_runtime.recordApprovalCheckpoint(task_id, record.?),
                .history => |result| switch (result) {
                    .committed => {
                        self.task_runtime.resumeApprovalConfirmation(task_id) catch {
                            self.task_runtime.markApprovalUnknown(task_id, null);
                            continue;
                        };
                        const retired = self.task_runtime.acceptApprovalCommit(task_id) catch {
                            self.task_runtime.markApprovalUnknown(task_id, null);
                            continue;
                        };
                        history_confirmed = true;
                        // Canonical mode is installed and admission is reopened
                        // before a separate worker retires the superseded blob.
                        self.bumpRevision();
                        if (!self.shutting_down) if (retired) |identity| if (self.checkpoint_store) |store| {
                            self.task_runtime.queueApprovalRetirement(store, identity, self.approvalExecutor(), self.approvalNotifier()) catch {};
                        };
                    },
                    .failed => {
                        if (phase == .outcome_unknown) history_confirmed = true;
                        self.failApprovalChange(task_id, .persistence_failed, mode_commit and task.approval_change.?.candidate != null);
                    },
                    .outcome_unknown => {
                        self.task_persistence_health = .outcome_unknown;
                        self.task_runtime.markApprovalUnknown(task_id, unknown_bytes);
                    },
                },
                .failure => |failure| if (phase == .outcome_unknown)
                    self.task_runtime.markApprovalUnknown(task_id, null)
                else
                    self.failApprovalChange(task_id, failure.reason, failure.restore_required or (phase == .mode_commit and task.approval_change.?.candidate != null)),
                .none, .retired => if (phase == .outcome_unknown)
                    self.task_runtime.markApprovalUnknown(task_id, null)
                else
                    self.failApprovalChange(task_id, .dependency_contract, phase == .mutation_export),
            }
        }
        if (history_confirmed) self.task_persistence_health = .ready;
        if (self.shutting_down) for (self.task_runtime.tasks) |entry| if (entry) |task| if (task.runtime.restore_job) |restore| {
            if (restore.binding_commit != .outcome_unknown) continue;
            // No readback is implied by shutdown. Retain the canonical witness
            // barrier while allowing the candidate Session and lease to close.
            std.debug.assert(self.approval_history_unknown == null);
            self.approval_history_unknown = restore.unknown_history;
            restore.unknown_history = null;
            restore.binding_commit = .failed;
        };
        for (self.task_runtime.tasks) |*entry| {
            const task = &(entry.* orelse continue);
            const change = task.approval_change orelse continue;
            if (self.task_runtime.approvalJobFor(task.durable.id)) continue;
            if (self.shutting_down) continue;
            switch (change.phase) {
                .waiting => {
                    if (change.recovery_attempt_id != null and task.runtime.close_failed and task.runtime.close_thread == null) {
                        self.task_runtime.failApprovalRecovery(task.durable.id);
                        changed = true;
                        continue;
                    }
                    if (!task.runtime.hasAttachedSession()) {
                        if (task.runtime.active_operation != .none or task.runtime.hasClosingSession() or task.runtime.close_thread != null) continue;
                        if (change.recovery_attempt_id != null) {
                            self.failApprovalChange(task.durable.id, .recovery_failed, false);
                        } else if (!self.beginApprovalRecovery(task.durable.id))
                            self.failApprovalChange(task.durable.id, .recovery_failed, false);
                        changed = true;
                        continue;
                    }
                    if (task.durable.permission_profile == change.target.profile()) {
                        task.approval_change.?.phase = .mode_commit;
                        changed = true;
                    } else {
                        if (!self.task_runtime.approvalCoreIdle(task.durable.id)) continue;
                        const resources = self.taskRuntimeOperationEffects().worker.checkpoint;
                        self.task_runtime.queueApprovalCheckpoint(task.durable.id, change.baseline_confirmed, resources, self.approvalExecutor(), self.approvalNotifier()) catch {
                            self.failApprovalChange(task.durable.id, .checkpoint_failed, false);
                        };
                        changed = true;
                    }
                },
                .baseline_commit, .mode_commit => {
                    if (self.approvalHistoryBlocked()) continue;
                    const bytes = self.encodeApprovalCandidate(task.durable.id) catch {
                        self.failApprovalChange(task.durable.id, .persistence_failed, change.phase == .mode_commit and change.candidate != null);
                        changed = true;
                        continue;
                    };
                    self.task_runtime.queueApprovalHistory(task.durable.id, bytes, self.task_persistence, self.approvalExecutor(), self.approvalNotifier()) catch {
                        self.allocator.free(bytes);
                        self.failApprovalChange(task.durable.id, .persistence_failed, change.phase == .mode_commit and change.candidate != null);
                    };
                    changed = true;
                },
                .recovering => {
                    if (task.runtime.close_failed and task.runtime.close_thread == null) {
                        self.task_runtime.failApprovalRecovery(task.durable.id);
                        changed = true;
                        continue;
                    }
                    if (task.runtime.hasAttachedSession()) {
                        if (change.recovery_attempt_id != null and task.runtime.active_operation == .none) {
                            self.failApprovalChange(task.durable.id, change.failure orelse .mode_update_failed, false);
                        } else {
                            _ = self.task_runtime.beginDetach(task.durable.id, self.taskRuntimeOperationEffects()) catch |err| switch (err) {
                                error.CloseInProgress => {},
                                else => self.task_runtime.failApprovalRecovery(task.durable.id),
                            };
                        }
                        changed = true;
                    } else if (task.runtime.active_operation == .none and !task.runtime.hasClosingSession() and task.runtime.close_thread == null) {
                        if (change.recovery_attempt_id != null) {
                            self.failApprovalChange(task.durable.id, .recovery_failed, false);
                        } else if (!self.beginApprovalRecovery(task.durable.id))
                            self.failApprovalChange(task.durable.id, .recovery_failed, false);
                        changed = true;
                    }
                },
                .baseline_export, .mutation_export, .outcome_unknown => {},
            }
        }
        if (self.approval_history_dirty and !self.shutting_down and
            self.task_persistence_health.operational() and !self.approvalHistoryBlocked())
        {
            self.queueApprovalProjection(false) catch |err| switch (err) {
                error.QueueFull, error.TaskBusy => {},
                else => self.markTaskPersistenceWriteFailed(),
            };
        }
        if (changed) self.bumpRevision();
        return changed;
    }

    pub fn runTask(
        self: *Runtime,
        task_id: u64,
        input: TaskRunInput,
    ) Error!u64 {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        self.syncLifecycle();
        if (self.task_runtime.inputAction(task_id) != .none) return error.TaskBusy;
        const binding_epoch = self.task_runtime.taskBindingEpoch(task_id) orelse
            return error.UnknownTask;
        return self.admitTaskRun(task_id, binding_epoch, input);
    }

    pub fn sendInput(self: *Runtime, operation_id: []const u8, task_id: u64, input: TaskRunInput) Error!SendInputResult {
        if (self.containsKnownCredential(operation_id) or operation_id.len == 0 or operation_id.len > 64) return error.InvalidInput;
        const mcp_refresh_needed = self.syncLifecycleFacts();
        defer if (mcp_refresh_needed) self.recoverExpiredMcpCatalogNoFail();
        var result: SendInputResult = .{ .task_id = task_id, .operation_id_len = @intCast(operation_id.len) };
        self.reapTaskInputResources();
        @memcpy(result.operation_id[0..operation_id.len], operation_id);
        self.receiveTaskInput(task_id, operation_id, input) catch |err| {
            result.reason = sendInputRejection(err);
            return result;
        };
        result.outcome = .accepted;
        self.advanceTaskInputs();
        self.commitTaskStateNoFail();
        self.bumpRevision();
        return result;
    }

    fn receiveTaskInput(self: *Runtime, task_id: u64, operation_id: []const u8, input: TaskRunInput) Error!void {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        const task = self.task_runtime.find(task_id) orelse return error.UnknownTask;
        _ = try self.workspace.taskRunAuthority(task.durable.workspace_id, task.durable.workspace_epoch);
        var staged: StagedTaskInput = .{};
        defer if (staged.borrow) |*borrow| borrow.rollback();
        const task_input = try self.borrowTaskInput(task_id, input, &staged);
        _ = try self.task_runtime.receiveInput(task_id, operation_id, task_input, self.taskRuntimeOperationEffects());
        if (staged.borrow) |*borrow| {
            borrow.retainForTask();
            staged.external.accept();
        }
    }

    pub fn stopTask(self: *Runtime, task_id: u64) Error!void {
        _ = self.syncLifecycleFacts();
        const task = self.task_runtime.find(task_id) orelse return error.UnknownTask;
        if (task.read_only_history != null or task.durable.archived or task.deletion != .idle) return error.TaskClosing;
        _ = self.task_runtime.stopInputs(task_id);
        switch (task.runtime.active_operation) {
            .run => |id| _ = try self.task_runtime.cancelRun(task_id, id, self.taskRuntimeOperationEffects()),
            .compact => |id| _ = try self.task_runtime.cancelCompact(task_id, id, .user_cancel, self.taskRuntimeOperationEffects()),
            .restore => self.task_runtime.cancelInputPreparation(task_id, self.taskRuntimeOperationEffects()),
            .none => {},
        }
        self.reapTaskInputResources();
        self.commitTaskStateNoFail();
        self.bumpRevision();
    }

    /// Test-only immediate Run targeting observes Core receipt semantics. The
    /// product Composer always uses Task acceptance through sendInput.
    pub fn testSendInput(self: *Runtime, operation_id: []const u8, task_id: u64, binding_epoch: u64, target: InputTarget, input: TaskRunInput) Error!task_runtime.SendInputResult {
        if (!builtin.is_test) @compileError("immediate input targeting is a lifecycle test seam");
        if (self.containsKnownCredential(operation_id)) return error.InvalidInput;
        const mcp_refresh_needed = self.syncLifecycleFacts();
        defer if (mcp_refresh_needed) self.recoverExpiredMcpCatalogNoFail();
        const result = try self.task_runtime.beginSendInputOperation(task_id, operation_id);
        defer {
            self.syncLifecycle();
            self.commitTaskStateNoFail();
            self.bumpRevision();
        }
        self.admitInput(task_id, binding_epoch, target, input) catch |err| {
            result.reason = sendInputRejection(err);
        };
        return result.*;
    }

    pub fn writeSendInputResult(self: *const Runtime, writer: *std.Io.Writer, result: SendInputResult) Error!void {
        try product_task.writeInputAcceptance(writer, self.taskTextProjection(), result);
    }

    fn admitInput(self: *Runtime, task_id: u64, binding_epoch: u64, target: InputTarget, input: TaskRunInput) Error!void {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        const task = self.task_runtime.find(task_id) orelse return error.UnknownTask;
        if (task.durable.binding_epoch != binding_epoch) return error.BindingEpochMismatch;
        const result = &task.send_input_result.?;
        switch (target) {
            .idle => |expected_last_run| {
                var previous: u64 = 0;
                for (task.durable.runs) |entry| if (entry) |run| {
                    previous = @max(previous, run.id);
                };
                if (previous != (expected_last_run orelse 0)) return error.RunChanged;
                if (task.runtime.active_operation != .none) return error.TaskBusy;
                const id = self.admitTaskRun(task_id, binding_epoch, input) catch |err| recover: {
                    // An admitted Run still owns executor failure. Do not report
                    // a reversible input refusal after its acceptance boundary.
                    for (task.durable.runs) |entry| if (entry) |run| if (run.id > previous) break :recover run.id;
                    return err;
                };
                result.outcome = .started;
                result.run_id = id;
            },
            .run => |id| {
                if (input != .text) return error.UnsupportedInput;
                const workspace_id = self.task_runtime.taskWorkspaceId(task_id) orelse return error.UnknownTask;
                const epoch = self.task_runtime.taskWorkspaceEpoch(task_id) orelse return error.UnknownTask;
                _ = try self.workspace.taskRunAuthority(workspace_id, epoch);
                try self.task_runtime.submitInput(task_id, binding_epoch, id, input.text, self.taskRuntimeOperationEffects());
            },
        }
    }

    pub fn taskBindingEpoch(self: *const Runtime, task_id: u64) Error!u64 {
        return self.task_runtime.taskBindingEpoch(task_id) orelse error.UnknownTask;
    }

    pub fn taskMcpAuthority(
        self: *const Runtime,
        task_id: u64,
    ) Error!product_task.McpAuthorityAtCreation {
        return self.task_runtime.taskMcpAuthority(task_id) orelse error.UnknownTask;
    }

    pub fn testRestoreCancellationRequested(
        self: *Runtime,
        task_id: u64,
    ) bool {
        std.debug.assert(builtin.is_test);
        return self.task_runtime.testRestoreCancellationRequested(task_id);
    }

    pub fn testLateTerminalEventCount(self: *const Runtime) u64 {
        std.debug.assert(builtin.is_test);
        return self.task_runtime.testLateTerminalEventCount();
    }

    /// Commits only the next-Run intent. Installed execution and the active
    /// Run retain their own authority until a later execution admission.
    pub fn selectTaskModel(
        self: *Runtime,
        task_id: u64,
        input: TaskModelSelectionInput,
    ) Error!u64 {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        self.syncLifecycle();
        if (input.target.source_id.len == 0 or
            input.target.model_id.len == 0 or
            input.target.source_id.len > models_contract.Limits.provider_id_bytes or
            input.target.model_id.len > models_contract.Limits.model_id_bytes or
            input.expected_source_generation == 0 or
            input.expected_catalog_generation == 0 or
            !std.unicode.utf8ValidateSlice(input.target.source_id) or
            !std.unicode.utf8ValidateSlice(input.target.model_id) or
            self.containsKnownCredential(input.target.source_id) or
            self.containsKnownCredential(input.target.model_id))
            return error.InvalidTaskModel;
        if (!self.newTaskModelSelectionAuthorized(.{
            .target = input.target,
            .expected_source_generation = input.expected_source_generation,
            .expected_catalog_generation = input.expected_catalog_generation,
        }))
            return error.StaleCatalog;
        if (self.approvalHistoryBlocked() or self.task_runtime.approvalHistoryWorkerActive()) return error.TaskBusy;
        for (self.task_runtime.tasks) |entry| if (entry) |task| if (task.approval_change != null) return error.TaskBusy;
        var prepared = try self.task_runtime.prepareModelIntent(task_id, input.expected_selection_revision, input.target);
        defer if (prepared.active) prepared.rollback();
        const revision = prepared.task.durable.model_intent.?.revision;
        if (self.task_persistence.enabled or self.task_persistence.restore_failed) {
            switch (self.task_persistence_health) {
                .ready, .degraded, .write_failed => {},
                else => return error.TaskPersistenceUnavailable,
            }
            const bytes = try self.encodeTaskHistoryCandidate(null);
            var bytes_owned = true;
            defer if (bytes_owned) self.allocator.free(bytes);
            switch (self.task_persistence.commitConfirmed(bytes)) {
                .committed => self.task_persistence_health = .ready,
                .failed => {
                    self.markTaskPersistenceWriteFailed();
                    return error.TaskPersistenceFailed;
                },
                .outcome_unknown => {
                    self.approval_history_unknown = bytes;
                    bytes_owned = false;
                    self.pending_model_intent = prepared;
                    prepared.active = false;
                    self.approval_history_dirty = true;
                    self.task_persistence_health = .outcome_unknown;
                    self.bumpRevision();
                    return error.TaskPersistenceOutcomeUnknown;
                },
            }
        }
        prepared.complete();
        self.bumpRevision();
        return revision;
    }

    /// Close admission before any Application shutdown drain can reconcile.
    pub fn beginShutdown(self: *Runtime) void {
        self.cancelSnapshot();
        self.shutting_down = true;
        for (self.task_runtime.tasks) |entry| if (entry) |task| {
            _ = self.task_runtime.cancelWaitingInputs(task.durable.id, .shutting_down);
        };
        self.reapTaskInputResources();
    }

    pub fn runTaskAtBinding(
        self: *Runtime,
        task_id: u64,
        expected_binding_epoch: u64,
        input: TaskRunInput,
    ) Error!u64 {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        self.syncLifecycle();
        if (self.task_runtime.inputAction(task_id) != .none) return error.TaskBusy;
        return self.admitTaskRun(task_id, expected_binding_epoch, input);
    }

    fn admitTaskRun(self: *Runtime, task_id: u64, expected_binding_epoch: u64, input: TaskRunInput) Error!u64 {
        return self.admitTaskRunWithSource(task_id, expected_binding_epoch, input, null);
    }

    const StagedTaskInput = struct {
        parts: [lifecycle.multimodal_input_limits.max_parts]product_attachment.BorrowedPart = undefined,
        indices: [lifecycle.multimodal_input_limits.max_parts]usize = undefined,
        items: [lifecycle.multimodal_input_limits.max_parts]task_runtime.MultimodalAttachment = undefined,
        borrow: ?product_attachment.Borrow = null,
        external: AttachmentAcceptance = .{},
    };

    fn borrowTaskInput(self: *Runtime, task_id: u64, input: TaskRunInput, staged: *StagedTaskInput) Error!task_runtime.RunInput {
        return switch (input) {
            .text => |text| .{ .text = text },
            .skill => |skill| .{ .skill = .{
                .skill_id = skill.skill_id,
                .catalog_revision = skill.catalog_revision,
                .selection_revision = skill.selection_revision,
                .argument_values = skill.argument_values,
            } },
            .multimodal => |multimodal| input: {
                staged.external = multimodal.acceptance;
                if (multimodal.attachment_ids.len == 0 or
                    multimodal.attachment_ids.len > self.limits.max_attachments_per_draft)
                    return error.TooManyFiles;
                staged.borrow = try self.attachments.borrow(
                    multimodal.attachment_ids,
                    &staged.parts,
                    &staged.indices,
                    task_id,
                );
                for (staged.parts[0..multimodal.attachment_ids.len], 0..) |part, index| {
                    const descriptor = self.attachments.descriptorFor(part.attachmentId()) orelse unreachable;
                    staged.items[index] = switch (part) {
                        .image => |image| .{
                            .resource_id = image.id,
                            .kind = .image,
                            .format = switch (image.format) {
                                .png => .png,
                                .jpeg => .jpeg,
                                .webp => .webp,
                            },
                            .display_name = descriptor.display_name,
                            .bytes = image.bytes,
                            .reference = image.reference,
                            .size_bytes = descriptor.size_bytes,
                            .source_format = switch (descriptor.format.?) {
                                .png => .png,
                                .jpeg => .jpeg,
                                .webp => .webp,
                            },
                        },
                        .text => |text| .{
                            .resource_id = text.id,
                            .kind = .file,
                            .format = null,
                            .display_name = descriptor.display_name,
                            .bytes = text.bytes,
                            .size_bytes = descriptor.size_bytes,
                        },
                    };
                }
                break :input .{ .multimodal = .{
                    .text = multimodal.text,
                    .attachments = staged.items[0..multimodal.attachment_ids.len],
                } };
            },
        };
    }

    fn admitTaskRunWithSource(self: *Runtime, task_id: u64, expected_binding_epoch: u64, input: TaskRunInput, source: ?u64) Error!u64 {
        return self.admitTaskRunInternal(task_id, expected_binding_epoch, .{ .command = input }, source);
    }

    const AdmissionInput = union(enum) { command: TaskRunInput, queued: usize };

    fn admitTaskRunInternal(self: *Runtime, task_id: u64, expected_binding_epoch: u64, input: AdmissionInput, source: ?u64) Error!u64 {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        if (self.task_runtime.inputContinuation(task_id) != null) return error.TaskBusy;
        const binding_epoch = self.task_runtime.taskBindingEpoch(task_id) orelse
            return error.UnknownTask;
        if (expected_binding_epoch == 0 or expected_binding_epoch != binding_epoch)
            return error.BindingEpochMismatch;
        const current_task = self.task_runtime.findConst(task_id).?;
        if (current_task.durable.archived or current_task.read_only_history != null or current_task.deletion != .idle or
            current_task.runtime.close_failed or current_task.runtime.close_requested or current_task.runtime.hasClosingSession()) return error.TaskClosing;
        if (current_task.runtime.attachedConst()) |attached| if (attached.health != .available) return error.TaskClosing;
        if (current_task.runtime.attachedConst()) |attached| if (attached.health == .available and !current_task.runtime.close_failed)
            try self.task_runtime.validateExecutionBinding(task_id);
        var model_target = try self.resolveTaskRunModel(task_id);
        defer if (model_target) |*target| target.deinit();
        if (model_target) |*target| {
            const task = self.task_runtime.findConst(task_id).?;
            if (task.runtime.executionConst()) |installed| if (!installed.matchesSource(target.input())) {
                if (input == .queued and !self.task_runtime.beginInputPreparation(task_id, input.queued))
                    return error.ExecutionUnavailable;
                _ = try self.beginTaskModelRebind(task_id, binding_epoch, target);
                return error.RestoreBusy;
            };
        }
        if (!self.task_runtime.continuationAvailable(
            task_id,
            self.taskRuntimeProjectionEffects(),
        )) return error.TaskClosing;
        const workspace_id = self.task_runtime.taskWorkspaceId(task_id) orelse
            return error.UnknownTask;
        const task_workspace_epoch = self.task_runtime.taskWorkspaceEpoch(task_id) orelse
            return error.UnknownTask;
        const workspace = try self.workspace.taskRunAuthority(
            workspace_id,
            task_workspace_epoch,
        );
        if ((self.task_runtime.catalogProjection(task_id) orelse return error.UnknownTask).availability == .loading)
            return error.CatalogLoading;
        var staged: StagedTaskInput = .{};
        var acceptance_context: AttachmentRunAcceptanceContext = undefined;
        defer if (staged.borrow) |*borrow| borrow.rollback();
        const task_input = switch (input) {
            .command => |command| blk: {
                const value = try self.borrowTaskInput(task_id, command, &staged);
                if (value == .multimodal) for (staged.items[0..value.multimodal.attachments.len]) |*item| {
                    item.resource_id = 0;
                };
                break :blk value;
            },
            .queued => |index| (self.task_runtime.pendingInput(task_id, index) orelse return error.InvalidInput).payload.?.input,
        };
        var order_preparation = if (workspace.kind == .manual)
            try self.workspace.prepareOrder(workspace.id)
        else
            product_workspace.OrderPreparation.inactive();
        errdefer if (order_preparation.isActive())
            self.workspace.rollbackOrder(&order_preparation);
        var order_context = TaskWorkspaceOrderContext{
            .workspace = &self.workspace,
            .preparation = &order_preparation,
        };
        var operation_effects = self.taskRuntimeOperationEffects();
        var image = self.prepareRunImage(workspace);
        defer if (image) |*value| value.deinit();
        operation_effects.image_execution = &image;
        operation_effects.model_target = if (model_target) |*target| target.input() else null;
        if (staged.borrow != null) {
            acceptance_context = .{
                .borrow = &staged.borrow.?,
                .external = staged.external,
            };
            operation_effects.run_acceptance = .{
                .context = &acceptance_context,
                .accept_fn = consumeAttachmentBorrow,
                .irreversible = true,
            };
        }
        const workspace_effect: task_runtime.WorkspaceOrderEffect = .{
            .context = &order_context,
            .manual = workspace.kind == .manual,
            .recent_order = order_preparation.recentOrder(),
            .apply_fn = applyTaskWorkspaceOrder,
            .rollback_fn = rollbackTaskWorkspaceOrder,
        };
        var prepared = if (input == .queued)
            try self.task_runtime.startWaitingRun(task_id, input.queued, workspace_effect, operation_effects)
        else if (source) |id|
            try self.task_runtime.startInputContinuation(task_id, expected_binding_epoch, id, task_input, workspace_effect, operation_effects)
        else
            try self.task_runtime.startRun(task_id, expected_binding_epoch, task_input, workspace_effect, operation_effects);
        if (source) |id| self.task_runtime.markInputTransferred(task_id, id, prepared.id());
        self.commitTaskStateBestEffort() catch |err| {
            if (source) |id| self.task_runtime.markInputTransferred(task_id, id, null);
            prepared.rollback();
            return err;
        };
        const run_id = prepared.submit() catch |err| {
            self.commitTaskStateNoFail();
            if (order_preparation.isActive())
                self.workspace.commitOrder(&order_preparation);
            self.bumpRevision();
            if (operation_effects.run_acceptance.irreversible or source != null)
                return prepared.id();
            return err;
        };
        if (order_preparation.isActive())
            self.workspace.commitOrder(&order_preparation);
        self.bumpRevision();
        return run_id;
    }

    pub fn compactTaskAtBinding(
        self: *Runtime,
        task_id: u64,
        expected_binding_epoch: u64,
    ) Error!u64 {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        self.syncLifecycle();
        const binding_epoch = self.task_runtime.taskBindingEpoch(task_id) orelse
            return error.UnknownTask;
        if (expected_binding_epoch == 0 or expected_binding_epoch != binding_epoch)
            return error.BindingEpochMismatch;
        if (!self.task_runtime.continuationAvailable(
            task_id,
            self.taskRuntimeProjectionEffects(),
        )) return error.TaskClosing;
        var prepared = try self.task_runtime.startCompact(
            task_id,
            expected_binding_epoch,
            self.taskRuntimeOperationEffects(),
        );
        self.commitTaskStateBestEffort() catch |err| {
            prepared.rollback();
            return err;
        };
        const operation_id = prepared.submit() catch {
            self.commitTaskStateNoFail();
            self.bumpRevision();
            return prepared.id();
        };
        self.bumpRevision();
        return operation_id;
    }

    pub fn cancelCompact(
        self: *Runtime,
        task_id: u64,
        operation_id: u64,
    ) Error!void {
        self.syncLifecycle();
        _ = try self.task_runtime.cancelCompact(
            task_id,
            operation_id,
            .user_cancel,
            self.taskRuntimeOperationEffects(),
        );
        self.commitTaskStateNoFail();
        self.syncLifecycle();
        self.bumpRevision();
    }

    pub fn taskExecutionIdentity(
        self: *Runtime,
        task_id: u64,
    ) Error!ExecutionIdentity {
        const value = self.task_runtime.taskExecutionIdentity(task_id) orelse
            return error.UnknownTask;
        return .{ .generation = value.generation, .protocol = value.protocol, .model = value.model };
    }

    pub fn runExecutionIdentity(
        self: *Runtime,
        task_id: u64,
        run_id: u64,
    ) Error!ExecutionIdentity {
        if (self.task_runtime.taskExecutionIdentity(task_id) == null)
            return error.UnknownTask;
        const value = self.task_runtime.runExecutionIdentity(task_id, run_id) orelse
            return error.NoSuchRun;
        return .{ .generation = value.generation, .protocol = value.protocol, .model = value.model };
    }

    /// Lifecycle tests use this read-only counter to verify ownership rollback
    /// without exposing projection accounting through the Renderer contract.
    pub fn projectionBytesForTest(self: *const Runtime) usize {
        return self.projection_bytes;
    }

    pub fn cancel(self: *Runtime, task_id: u64, run_id: u64) Error!void {
        const mcp_refresh_needed = self.syncLifecycleFacts();
        defer if (mcp_refresh_needed) self.recoverExpiredMcpCatalogNoFail();
        if (try self.task_runtime.cancelRun(
            task_id,
            run_id,
            self.taskRuntimeOperationEffects(),
        )) {
            self.commitTaskStateNoFail();
            self.bumpRevision();
        }
        self.syncLifecycle();
    }

    pub fn respondUi(
        self: *Runtime,
        task_id: u64,
        run_id: u64,
        request_id: u64,
        response: UiResponse,
    ) Error!void {
        // An entered manual command arbitrates before queued review results.
        // Task validates the exact pending request/choice before invalidation.
        const mcp_refresh_needed = self.syncLifecycleFacts();
        defer if (mcp_refresh_needed) self.recoverExpiredMcpCatalogNoFail();
        var prepared = self.task_runtime.respondUi(
            task_id,
            run_id,
            request_id,
            response,
        ) catch |err| {
            if (err == error.UiRequestIdentityCollision) {
                self.commitTaskStateNoFail();
                self.bumpRevision();
                self.syncLifecycle();
            }
            return err;
        };
        self.commitTaskStateBestEffort() catch |err| {
            prepared.rollback();
            return err;
        };
        prepared.deliver() catch |err| {
            self.commitTaskStateNoFail();
            return err;
        };
        self.bumpRevision();
    }

    fn detachTaskSession(self: *Runtime, task_id: u64) Error!void {
        const mcp_refresh_needed = self.syncLifecycleFacts();
        defer if (mcp_refresh_needed) self.recoverExpiredMcpCatalogNoFail();
        if (try self.task_runtime.beginDetach(
            task_id,
            self.taskRuntimeOperationEffects(),
        )) {
            self.commitTaskStateNoFail();
            self.bumpRevision();
        }
    }

    pub fn renameTask(self: *Runtime, task_id: u64, title: []const u8) Error!void {
        self.syncLifecycle();
        try self.task_runtime.renameTask(
            task_id,
            title,
            self.limits.max_task_title_bytes,
            self.taskRuntimeTextProjection(),
        );
        self.commitTaskStateNoFail();
        self.bumpRevision();
    }

    pub fn createScheduledTask(
        self: *Runtime,
        input: ScheduledTaskDefinitionInput,
    ) Error!u64 {
        defer self.publishScheduleChangesNoFail();
        if (self.shutting_down) return error.ExecutorShuttingDown;
        self.syncLifecycle();
        const definition = try self.scheduledTaskDefinition(input);
        const id = try self.schedule.create(
            definition,
            self.scheduleExecutionBinding(),
            self.scheduleRedaction(),
        );
        return id;
    }

    pub fn updateScheduledTask(
        self: *Runtime,
        id: u64,
        expected_epoch: u64,
        input: ScheduledTaskDefinitionInput,
    ) Error!void {
        defer self.publishScheduleChangesNoFail();
        if (self.shutting_down) return error.ExecutorShuttingDown;
        self.syncLifecycle();
        const definition = try self.scheduledTaskDefinition(input);
        try self.schedule.update(
            id,
            expected_epoch,
            definition,
            self.scheduleExecutionBinding(),
            self.scheduleRedaction(),
        );
    }

    pub fn setScheduledTaskEnabled(
        self: *Runtime,
        id: u64,
        expected_epoch: u64,
        enabled: bool,
    ) Error!void {
        defer self.publishScheduleChangesNoFail();
        if (self.shutting_down) return error.ExecutorShuttingDown;
        self.syncLifecycle();
        try self.schedule.setEnabled(
            id,
            expected_epoch,
            enabled,
            self.scheduleExecutionBinding(),
            self.scheduleRedaction(),
        );
    }

    pub fn deleteScheduledTask(
        self: *Runtime,
        id: u64,
        expected_epoch: u64,
    ) Error!void {
        defer self.publishScheduleChangesNoFail();
        self.syncLifecycle();
        try self.schedule.delete(
            id,
            expected_epoch,
            self.scheduleExecutionBinding(),
            self.scheduleRedaction(),
        );
    }

    pub fn scheduledTaskEpoch(
        self: *Runtime,
        id: u64,
    ) Error!u64 {
        return self.schedule.epoch(id);
    }

    pub fn runScheduledTaskNow(
        self: *Runtime,
        id: u64,
        expected_epoch: u64,
    ) Error!u64 {
        defer self.publishScheduleChangesNoFail();
        if (self.shutting_down) return error.ExecutorShuttingDown;
        self.syncLifecycle();
        return self.schedule.runNow(
            id,
            expected_epoch,
            self.scheduleRedaction(),
            self.scheduleTaskEffects(),
        ) catch |err| switch (err) {
            error.PreviousTaskActive => error.TaskBusy,
            else => return @errorCast(err),
        };
    }

    pub fn onScheduledTaskTimer(self: *Runtime) void {
        defer self.publishScheduleChangesNoFail();
        if (self.shutting_down) return;
        self.syncLifecycle();
        self.schedule.onTimer(
            self.scheduleExecutionBinding(),
            self.scheduleRedaction(),
            self.scheduleTaskEffects(),
        );
    }

    pub fn setTaskArchived(self: *Runtime, task_id: u64, archived: bool) Error!void {
        const mcp_refresh_needed = self.syncLifecycleFacts();
        defer if (mcp_refresh_needed) self.recoverExpiredMcpCatalogNoFail();
        if (try self.task_runtime.setArchived(task_id, archived)) {
            self.reapTaskInputResources();
            self.commitTaskStateNoFail();
            self.bumpRevision();
        }
    }

    pub fn markTaskCompletionSeen(
        self: *Runtime,
        task_id: u64,
        run_id: u64,
    ) bool {
        if (self.shutting_down) return false;
        self.syncLifecycle();
        const marked = self.task_runtime.markCompletionSeen(task_id, run_id);
        if (marked) self.bumpRevision();
        return marked;
    }

    pub fn deleteTask(self: *Runtime, task_id: u64) Error!void {
        const mcp_refresh_needed = self.syncLifecycleFacts();
        defer if (mcp_refresh_needed) self.recoverExpiredMcpCatalogNoFail();
        const requested = try self.task_runtime.requestDeletion(task_id);
        self.reapTaskInputResources();
        if (self.task_runtime.taskWorkspaceId(task_id)) |id| {
            if (self.workspace.facts(id)) |workspace| {
                if (workspace.kind == .automatic)
                    self.skill.setWorkspaceCatalogAuthorized(id, workspace.epoch, false, self.skillProjectionBudget()) catch unreachable;
            }
        }

        const deletion = self.task_runtime.syncDeletions(
            self.checkpoint_store_health.load(.acquire) != .unavailable,
            self.taskRuntimeDeletionEffects(),
        );
        if (requested or deletion.changed) self.bumpRevision();
        if (deletion.failed_task_id == task_id) {
            if (deletion.failed_commit == .outcome_unknown)
                return error.TaskPersistenceOutcomeUnknown;
            return error.TaskPersistenceFailed;
        }
    }

    pub fn currentRevision(self: *const Runtime) u64 {
        return self.revision;
    }

    pub fn taskHistoryRecoveryAvailable(self: *const Runtime) bool {
        if (!self.task_persistence.enabled) return false;
        if (self.task_runtime.approvalHistoryWorkerActive()) return false;
        return switch (self.task_persistence_health) {
            .read_failed, .corrupt, .write_failed, .outcome_unknown => true,
            .unavailable, .ready, .degraded => false,
        };
    }

    pub fn scheduledTaskRecoveryAvailable(self: *const Runtime) bool {
        return self.schedule.persistenceRecoveryAvailable();
    }

    pub fn recoverTaskHistory(
        self: *Runtime,
        expected_revision: u64,
    ) PersistenceRecoveryOutcome {
        self.syncLifecycle();
        if (self.shutting_down) return .shutting_down;
        if (expected_revision != self.revision) return .stale_revision;
        // An approval candidate owns the indeterminate history transaction.
        // Resolve it on the bounded executor; never quarantine or rewrite it.
        if (self.approval_history_unknown != null) {
            self.queueApprovalProjection(true) catch return .unavailable;
            self.bumpRevision();
            return .outcome_unknown;
        }
        if (self.approval_history_dirty and !self.approvalHistoryBlocked() and self.task_persistence_health == .write_failed) {
            self.queueApprovalProjection(false) catch return .unavailable;
            self.bumpRevision();
            return .outcome_unknown;
        }
        if (self.approvalHistoryBlocked()) {
            for (self.task_runtime.tasks) |entry| if (entry) |task| if (task.runtime.restore_job) |restore| {
                if (restore.binding_commit != .outcome_unknown) continue;
                const bytes = self.allocator.dupe(u8, restore.unknown_history orelse return .unavailable) catch return .unavailable;
                self.task_runtime.queueRecoveryHistory(task.durable.id, bytes, self.task_persistence, true, self.approvalExecutor(), self.approvalNotifier()) catch {
                    self.allocator.free(bytes);
                    return .unavailable;
                };
                self.bumpRevision();
                return .outcome_unknown;
            };
            for (self.task_runtime.tasks) |entry| if (entry) |task| if (task.approval_change) |change| {
                if (change.phase != .outcome_unknown) continue;
                self.task_runtime.queueApprovalResolution(task.durable.id, self.task_persistence, self.approvalExecutor(), self.approvalNotifier()) catch return .unavailable;
                self.bumpRevision();
                return .outcome_unknown;
            };
            return .unavailable;
        }
        if (!self.taskHistoryRecoveryAvailable()) return switch (self.task_persistence_health) {
            .ready, .degraded => .not_required,
            else => .unavailable,
        };
        var scratch = self.buildTaskStateWire() catch return .failed;
        defer scratch.deinit();
        const output = self.allocator.alloc(u8, task_persistence.max_store_bytes) catch
            return .failed;
        defer self.allocator.free(output);
        const bytes = task_persistence.encodePreserving(
            output,
            scratch.state,
            scratch.preserved,
            self.taskPersistenceLimits(),
        ) catch
            return .failed;
        if (self.containsKnownCredential(bytes)) return .failed;
        return switch (self.task_persistence.recover(bytes)) {
            .committed => recovered: {
                self.task_persistence_health = .ready;
                self.approval_history_dirty = false;
                self.bumpRevision();
                break :recovered .recovered;
            },
            .failed => .failed,
            .outcome_unknown => unknown: {
                self.task_persistence_health = .outcome_unknown;
                self.bumpRevision();
                break :unknown .outcome_unknown;
            },
        };
    }

    pub fn recoverScheduledTaskStore(
        self: *Runtime,
        expected_revision: u64,
    ) PersistenceRecoveryOutcome {
        defer self.publishScheduleChangesNoFail();
        self.syncLifecycle();
        if (self.shutting_down) return .shutting_down;
        if (expected_revision != self.revision) return .stale_revision;
        if (!self.scheduledTaskRecoveryAvailable()) return switch (self.schedule.persistenceHealth()) {
            .ready => .not_required,
            else => .unavailable,
        };
        return switch (self.schedule.recoverPersistence(self.scheduleRedaction())) {
            .recovered => recovered: {
                self.reconcileModelsDefaultNoFail(false, false);
                self.finishDefaultExecutionCommitNoFail();
                break :recovered .recovered;
            },
            .unavailable => .unavailable,
            .failed => .failed,
            .outcome_unknown => .outcome_unknown,
        };
    }

    pub fn defaultPermissionProfile(self: *const Runtime) PermissionProfile {
        return self.default_approval_mode.profile();
    }

    pub fn defaultApprovalMode(self: *const Runtime) ApprovalMode {
        return self.default_approval_mode;
    }

    pub fn taskApprovalMode(self: *Runtime, task_id: u64) Error!ApprovalMode {
        return self.task_runtime.taskApprovalMode(task_id) orelse error.UnknownTask;
    }

    fn permissionReviewAuthorized(self: *Runtime, identity: task_runtime.PermissionReviewIdentity) bool {
        if (self.shutting_down or !self.task_runtime.permissionReviewCurrent(identity)) return false;
        const workspace_id = self.task_runtime.taskWorkspaceId(identity.task_id) orelse return false;
        const workspace = self.workspace.facts(workspace_id) orelse return false;
        return workspace.epoch == identity.workspace_epoch and workspace.authorization == .available;
    }

    fn syncPermissionReviews(self: *Runtime) void {
        for (&self.permission_jobs) |*slot| {
            const job = slot.* orelse continue;
            if (!self.permissionReviewAuthorized(job.prepared.identity)) job.cancel();
            if (!job.done.load(.acquire)) continue;
            job.thread.?.join();
            job.thread = null;
            if (!job.cancellation.isRequested() and self.permissionReviewAuthorized(job.prepared.identity)) {
                // A credential may have become known while the review ran.
                switch (job.outcome) {
                    .suggestion => |*suggestion| _ = self.redactWithKnownCredentialsNoFail(suggestion.reason.bytes[0..suggestion.reason.len]),
                    .failure => {},
                }
                _ = self.task_runtime.acceptPermissionReview(job.prepared.identity, job.outcome, .{
                    .context = self,
                    .commit_fn = commitPermissionReviewCandidate,
                    .text = self.taskRuntimeTextProjection(),
                }) catch false;
            }
            _ = self.task_runtime.finishPermissionReview(job.prepared.identity);
            job.deinit();
            slot.* = null;
            self.bumpRevision();
        }
        if (self.shutting_down) return;
        while (true) {
            const deadline = std.Io.Clock.Timestamp.now(self.io, .awake).addDuration(.{
                .raw = std.Io.Duration.fromMilliseconds(permission_job.timeout_ms),
                .clock = .awake,
            });
            var prepared = self.task_runtime.prepareNextPermissionReview(self.taskRuntimeTextProjection()) orelse break;
            var vacant: ?*?*permission_job.Job = null;
            for (&self.permission_jobs) |*slot| if (slot.* == null) {
                vacant = slot;
                break;
            };
            // MCP has no trusted secret-field projection in the current SDK.
            // Do not send opaque MCP arguments to another model by guessing.
            if (vacant == null or prepared.tool_namespace != .builtin or
                !self.permissionReviewAuthorized(prepared.identity))
            {
                _ = self.task_runtime.finishPermissionReview(prepared.identity);
                prepared.deinit();
                self.bumpRevision();
                continue;
            }
            self.startPermissionReview(prepared, deadline, vacant.?) catch {
                _ = self.task_runtime.finishPermissionReview(prepared.identity);
                self.bumpRevision();
            };
        }
    }

    fn startPermissionReview(self: *Runtime, value: task_runtime.PreparedPermissionReview, deadline: std.Io.Clock.Timestamp, slot: *?*permission_job.Job) !void {
        var prepared = value;
        errdefer prepared.deinit();
        for ([_][]const u8{ prepared.input.user_intent, prepared.input.context, prepared.input.request.tool_name, prepared.input.request.working_directory }) |field|
            _ = self.redactWithKnownCredentialsNoFail(@constCast(field));
        var scanner = std.json.Scanner.initCompleteInput(self.allocator, prepared.input.request.arguments_json);
        defer scanner.deinit();
        while (try scanner.next() != .end_of_document) if (scanner.stackHeight() > 64) return error.ReviewInputLimit;
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, prepared.input.request.arguments_json, .{ .duplicate_field_behavior = .@"error", .parse_numbers = false });
        defer {
            clearPermissionArguments(&parsed.value);
            parsed.deinit();
        }
        try self.scrubPermissionArguments(&parsed.value);
        const arguments = try self.allocator.alloc(u8, 16 * 1024);
        errdefer {
            std.crypto.secureZero(u8, arguments);
            self.allocator.free(arguments);
        }
        var writer = std.Io.Writer.fixed(arguments);
        try std.json.Stringify.value(parsed.value, .{}, &writer);
        prepared.input.request.arguments_json = writer.buffered();
        const config = prepared.execution.input();
        const owner = try self.completion_factory.create(self.allocator, .{
            .target = .{ .provider_id = config.target.provider_id, .protocol = agent_protocol.toAgent(config.target.protocol), .base_url = config.target.base_url, .model = config.target.model },
            .credential = config.api_key,
        });
        errdefer owner.deinit();
        const job = try self.allocator.create(permission_job.Job);
        errdefer self.allocator.destroy(job);
        job.* = .{ .allocator = self.allocator, .io = self.io, .prepared = prepared, .arguments = arguments, .owner = owner, .cancellation = owner.newCancellation(), .deadline = deadline, .notify_context = self.change_notifier.context, .notify_fn = self.change_notifier.wake };
        try job.start();
        slot.* = job;
        self.bumpRevision();
    }

    fn scrubPermissionArguments(self: *Runtime, value: *std.json.Value) !void {
        switch (value.*) {
            .string => |string| _ = self.redactWithKnownCredentialsNoFail(@constCast(string)),
            .number_string => |number| if (self.containsKnownCredential(number)) {
                return error.SensitiveArgumentNumber;
            },
            .array => |*array| for (array.items) |*item| try self.scrubPermissionArguments(item),
            .object => |*object| {
                var iterator = object.iterator();
                while (iterator.next()) |entry| {
                    if (self.containsKnownCredential(entry.key_ptr.*)) return error.SensitiveArgumentKey;
                    try self.scrubPermissionArguments(entry.value_ptr);
                }
            },
            else => {},
        }
    }

    fn clearPermissionArguments(value: *std.json.Value) void {
        switch (value.*) {
            .string, .number_string => |string| std.crypto.secureZero(u8, @constCast(string)),
            .array => |*array| for (array.items) |*item| clearPermissionArguments(item),
            .object => |*object| {
                var iterator = object.iterator();
                while (iterator.next()) |entry| {
                    std.crypto.secureZero(u8, @constCast(entry.key_ptr.*));
                    clearPermissionArguments(entry.value_ptr);
                }
            },
            else => {},
        }
    }

    fn commitPermissionReviewCandidate(context: *anyopaque) task_runtime.DurableCommit {
        const self: *Runtime = @ptrCast(@alignCast(context));
        self.commitTaskState() catch |err| return switch (err) {
            error.TaskPersistenceOutcomeUnknown => .outcome_unknown,
            else => .failed,
        };
        return .committed;
    }

    fn shutdownPermissionReviews(self: *Runtime) void {
        for (self.permission_jobs) |entry| if (entry) |job| job.cancel();
        for (&self.permission_jobs) |*slot| if (slot.*) |job| {
            _ = self.task_runtime.finishPermissionReview(job.prepared.identity);
            job.deinit();
            slot.* = null;
        };
    }

    pub fn checkpointStoreHealth(self: *const Runtime) checkpoint_store.Health {
        return self.checkpoint_store_health.load(.acquire);
    }

    /// Reconciles worker-owned lifecycle state into the main-thread product
    /// projection, then schedules/reaps independently owned permission reviews.
    pub fn syncLifecycle(self: *Runtime) void {
        const mcp_refresh_needed = self.syncLifecycleFacts();
        self.advanceTaskInputs();
        self.syncPermissionReviews();
        if (mcp_refresh_needed) self.recoverExpiredMcpCatalogNoFail();
    }

    /// Lifecycle facts alone never accept or start a reviewer decision. The
    /// manual-response entry point uses this before Task's acceptance boundary.
    fn syncLifecycleFacts(self: *Runtime) bool {
        var changed = self.syncSkillCatalogsNoFail();
        changed = self.commitMcpRefreshJobNoFail() or changed;
        changed = self.syncMcpHealthNoFail() or changed;
        const task_sync = self.task_runtime.reconcileLifecycle(.{
            .max_title_bytes = self.limits.max_task_title_bytes,
            .text = self.taskRuntimeTextProjection(),
            .recovery = self.taskRuntimeRecoveryEffects(),
            .release = self.taskRuntimeReleaseEffects(),
            .checkpoint = self.taskRuntimeCheckpointEffects(),
            .notifier = .{
                .context = self.change_notifier.context,
                .notify_fn = self.change_notifier.wake,
            },
        });
        changed = task_sync.changed or changed;
        changed = self.syncInitialAutomaticCatalogsNoFail() or changed;
        changed = self.syncApprovalChanges() or changed;
        var durable_changed = task_sync.durable_changed;
        if (self.finalizeWorkspaceRemovalsNoFail()) {
            changed = true;
            durable_changed = true;
        }
        for (self.task_runtime.tasks) |entry| if (entry) |task| {
            if (self.task_runtime.inputContinuation(task.durable.id)) |source| {
                if (self.schedule.hasPendingSubmittedOccurrence(task.durable.id))
                    source.input_continuation_schedule_gate = true;
            }
        };
        if (self.schedule.reconcileNoFail(
            self.scheduleExecutionBinding(),
            self.scheduleRedaction(),
            self.scheduleTaskEffects(),
        )) changed = true;
        for (self.task_runtime.tasks) |entry| if (entry) |task| {
            if (self.task_runtime.inputContinuation(task.durable.id)) |source| {
                if (!source.input_continuation_schedule_gate) continue;
                const pending = self.schedule.hasPendingSubmittedOccurrence(task.durable.id);
                if (self.schedule.persistenceHealth() != .ready or
                    (pending and self.schedule.completion_confirmation_failed_task == task.durable.id))
                {
                    changed = self.task_runtime.cancelInputContinuation(task.durable.id, source.id, .schedule_failed) or changed;
                } else if (!pending) source.input_continuation_schedule_gate = false;
            }
        };
        if (self.schedule.takeChanged()) changed = true;
        if (durable_changed) self.commitTaskStateNoFail();
        if (self.task_runtime.syncDeletions(
            self.checkpoint_store_health.load(.acquire) != .unavailable,
            self.taskRuntimeDeletionEffects(),
        ).changed) changed = true;
        if (changed) self.bumpRevision();
        return task_sync.mcp_refresh_needed;
    }

    fn advanceTaskInputs(self: *Runtime) void {
        if (self.advancing_task_inputs) return;
        self.advancing_task_inputs = true;
        defer self.advancing_task_inputs = false;
        defer self.reapTaskInputResources();
        for (self.task_runtime.tasks) |*entry| {
            const task = &(entry.* orelse continue);
            if (self.shutting_down) {
                _ = self.task_runtime.cancelWaitingInputs(task.durable.id, .shutting_down);
                _ = self.task_runtime.cancelInputContinuation(task.durable.id, null, .shutting_down);
                continue;
            }
            for (0..self.limits.max_pending_inputs_per_task + 1) |_| {
                switch (self.task_runtime.inputAction(task.durable.id)) {
                    .none, .wait => break,
                    .fail => |action| {
                        self.task_runtime.failWaitingInput(task.durable.id, action.index, action.reason);
                        self.bumpRevision();
                    },
                    .continuation => {
                        if (!self.advanceInputContinuation(task.durable.id)) break;
                    },
                    .submit => |action| {
                        _ = self.workspace.taskRunAuthority(task.durable.workspace_id, task.durable.workspace_epoch) catch |err| {
                            self.task_runtime.failWaitingInput(task.durable.id, action.index, sendInputRejection(err));
                            self.bumpRevision();
                            continue;
                        };
                        const receipt = self.task_runtime.submitWaitingInput(task.durable.id, action.index, action.run_id, self.taskRuntimeOperationEffects()) catch |err| {
                            switch (err) {
                                error.TaskBusy, error.RunChanged, error.RunStopping, error.RunNotReady => break,
                                else => self.task_runtime.failWaitingInput(task.durable.id, action.index, sendInputRejection(err)),
                            }
                            self.bumpRevision();
                            continue;
                        };
                        self.bumpRevision();
                        if (receipt.outcome == .rejected) break;
                    },
                    .start => |index| {
                        if (!self.startWaitingInput(task.durable.id, index)) break;
                    },
                }
            }
        }
    }

    fn reapTaskInputResources(self: *Runtime) void {
        for (self.task_runtime.tasks) |entry| if (entry) |task| {
            while (self.task_runtime.takeInputResourceAction(task.durable.id)) |action| {
                self.attachments.settleTaskInput(action.resource_id, task.durable.id, action.keep_original) catch |err| switch (err) {
                    error.CleanupFailed => self.bumpRevision(),
                    else => @panic("Task attachment ownership invariant violated"),
                };
            }
        };
    }

    fn startWaitingInput(self: *Runtime, task_id: u64, index: usize) bool {
        const task = self.task_runtime.find(task_id) orelse return false;
        if (task.model_intent_prepared or task.approval_change != null or self.approvalHistoryBlocked()) return false;
        if (!self.task_runtime.continuationAvailable(task_id, self.taskRuntimeProjectionEffects())) {
            const capability = self.task_runtime.continuationProjection(task_id, self.taskRuntimeProjectionEffects());
            if (capability != null and capability.? == .unavailable and (capability.?.unavailable == .session_recovery_required or capability.?.unavailable == .session_recovery_failed) and self.task_runtime.beginInputPreparation(task_id, index)) {
                _ = self.restoreTaskConversation(task_id, task.durable.binding_epoch) catch |err| {
                    self.task_runtime.failWaitingInput(task_id, index, sendInputRejection(err));
                    self.bumpRevision();
                    return true;
                };
                return false;
            }
            self.task_runtime.failWaitingInput(task_id, index, .binding_unavailable);
            self.bumpRevision();
            return true;
        }
        var previous: u64 = 0;
        for (task.durable.runs) |entry| if (entry) |run| {
            previous = @max(previous, run.id);
        };
        const id = self.admitTaskRunInternal(task_id, task.durable.binding_epoch, .{ .queued = index }, null) catch |err| {
            for (task.durable.runs) |entry| if (entry) |run| if (run.id > previous) {
                self.task_runtime.finishWaitingInput(task_id, index, run.id, null, self.taskRuntimeReleaseEffects());
                self.bumpRevision();
                return true;
            };
            switch (err) {
                error.TaskBusy, error.CatalogLoading, error.RestoreBusy, error.TaskPersistenceOutcomeUnknown => return false,
                else => self.task_runtime.failWaitingInput(task_id, index, sendInputRejection(err)),
            }
            self.bumpRevision();
            return true;
        };
        self.task_runtime.finishWaitingInput(task_id, index, id, null, self.taskRuntimeReleaseEffects());
        self.bumpRevision();
        return true;
    }

    fn advanceInputContinuation(self: *Runtime, task_id: u64) bool {
        switch (self.task_runtime.prepareInputContinuation(task_id, self.limits.max_user_message_bytes)) {
            .wait => return false,
            .ended => {
                self.bumpRevision();
                return true;
            },
            .ready => |batch| {
                defer {
                    std.crypto.secureZero(u8, batch.text);
                    self.allocator.free(batch.text);
                }
                _ = self.admitTaskRunWithSource(task_id, batch.binding_epoch, .{ .text = batch.text }, batch.source_id) catch |err| {
                    self.task_runtime.finishInputContinuation(task_id, batch.source_id, sendInputRejection(err));
                    self.bumpRevision();
                    return true;
                };
                self.task_runtime.finishInputContinuation(task_id, batch.source_id, null);
                self.bumpRevision();
                return true;
            },
        }
    }

    /// Consumes the canonical Agent event stream and owns the complete product
    /// terminal-publication barrier. This operation is main-loop-thread only.
    /// It remains valid after Executor and Agent Runtime shutdown, does not
    /// depend on Executor liveness, and must run before Agent Runtime deinit.
    pub fn drainAgentEvents(self: *Runtime) Error!void {
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
        // Agent readiness is a Product lifecycle wake, not a Renderer wake.
        // Reconcile even when no Renderer is connected so background Runs can
        // request termination and Schedules can consume their terminal facts.
        self.syncLifecycle();
        if (first_projection_error) |err| return err;
    }

    fn drainAgentEventPass(
        self: *Runtime,
        first_projection_error: *?Error,
    ) void {
        while (self.agent_runtime.takeEvent()) |value| {
            var envelope = value;
            defer envelope.deinit();
            self.applyEvent(&envelope) catch |err| {
                if (first_projection_error.* == null)
                    first_projection_error.* = err;
                if (err == error.InvalidOutputSegment or err == error.InvalidInputAdoption)
                    self.recordDependencyContractFailure(
                        envelope.session_id,
                        envelope.run_id,
                    )
                else
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

    pub fn applyEvent(self: *Runtime, envelope: *const lifecycle.OwnedCoreEvent) Error!void {
        const outcome = self.task_runtime.applyEvent(
            envelope,
            .{
                .text = self.taskRuntimeTextProjection(),
                .file_change_diff = .{
                    .context = self,
                    .enqueue_fn = enqueueFileChangeDiff,
                },
                .max_assistant_message_bytes = self.limits.max_assistant_message_bytes,
                .max_commentary_segments_per_run = self.limits.max_commentary_segments_per_run,
                .max_tool_field_bytes = self.limits.max_tool_field_bytes,
                .max_file_refs_per_tool = self.limits.max_file_refs_per_tool,
                .max_file_ref_field_bytes = self.limits.max_file_ref_field_bytes,
                .max_file_changes_per_run = self.limits.max_file_changes_per_run,
                .max_file_change_field_bytes = self.limits.max_file_change_field_bytes,
                .max_file_change_diff_bytes = self.limits.max_file_change_diff_bytes,
            },
        ) catch |err| return @errorCast(err);
        switch (outcome) {
            .unknown, .unchanged => {},
            .late_terminal => |late| {
                // A late event cannot change a published product terminal, and
                // is not by itself proof of an AgentCore contract violation.
                if (builtin.mode == .Debug) std.log.warn(
                    "control.late_terminal_event task_id={d} run_id={d} count={d}",
                    .{ late.task_id, envelope.run_id, late.count },
                );
            },
            .applied => |application| {
                if (application.durable_boundary) self.commitTaskStateNoFail();
                self.encoded_views.invalidateEvent(application.task_id, envelope.run_id);
                if (!self.view_preparation.ready and self.view_read.id != 0) for (&self.view_preparation.blocks) |*block| {
                    switch (block.key.kind) {
                        .workspaces, .taskIndex => block.current = false,
                        .taskPage => if (block.key.task_id == application.task_id) {
                            block.current = false;
                        },
                        .historyPage => if (block.key.task_id == application.task_id and envelope.run_id < block.key.cursor) {
                            block.current = false;
                        },
                        else => {},
                    }
                };
                if (self.revision != std.math.maxInt(u64)) self.revision += 1;
            },
        }
    }

    /// Records canonical event loss independently of Agent execution state.
    /// A termination request may arrive after Agent terminal publication, so
    /// it cannot be the only owner of this product failure fact.
    fn recordEventProjectionFailure(
        self: *Runtime,
        route_id: u64,
        run_id: u64,
    ) void {
        if (!self.task_runtime.recordEventProjectionFailure(route_id, run_id)) return;
        self.commitTaskStateNoFail();
        self.bumpRevision();
    }

    fn recordDependencyContractFailure(
        self: *Runtime,
        route_id: u64,
        run_id: u64,
    ) void {
        if (!self.task_runtime.recordDependencyContractFailure(route_id, run_id)) return;
        self.commitTaskStateNoFail();
        self.bumpRevision();
    }

    /// Marks terminal Runs before Runtime performs one more complete Agent
    /// event-pump drain. The acquire in `terminalPayload` observes every
    /// callback enqueue that happened before Run completion.
    fn markTerminalRunsBeforeEventDrain(self: *Runtime) void {
        _ = self.task_runtime.markTerminalRunsBeforeEventDrain();
    }

    fn syncMcpHealthNoFail(self: *Runtime) bool {
        const runtime = if (self.mcp) |*value| value else return false;
        return runtime.syncInitialHealth();
    }
    fn publishMcpRuntimeChanges(self: *Runtime) void {
        const runtime = if (self.mcp) |*value| value else return;
        if (runtime.takeChanged()) self.bumpRevision();
    }

    pub fn inspectMcpDesiredConfiguration(
        self: *const Runtime,
    ) ?mcp_configuration.ManagementInspection {
        const runtime = if (self.mcp) |*value| value else return null;
        return runtime.inspectDesiredConfiguration();
    }

    /// Host-only copy used to construct an isolated custom-model probe Runtime.
    /// The bytes never cross Bridge and contain no resolved credential values.
    pub fn writeMcpDesiredConfiguration(
        self: *const Runtime,
        expected_generation: u64,
        output: []u8,
    ) Error![]const u8 {
        const runtime = if (self.mcp) |*value| value else return error.McpManagementUnavailable;
        return runtime.writeDesiredConfiguration(expected_generation, output) catch |err|
            return @errorCast(err);
    }

    pub fn beginMcpConnectionTest(
        self: *Runtime,
        server_id: []const u8,
    ) Error!void {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        const runtime = if (self.mcp) |*value| value else return error.McpManagementUnavailable;
        _ = runtime.beginConnectionTest(server_id) catch |err| return @errorCast(err);
        self.bumpRevision();
    }

    pub fn beginMcpConfigurationApply(
        self: *Runtime,
        expected_generation: u64,
    ) Error!void {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        const runtime = if (self.mcp) |*value| value else return error.McpManagementUnavailable;
        _ = runtime.beginConfigurationApply(expected_generation) catch |err|
            return @errorCast(err);
        self.bumpRevision();
    }

    /// Installs the exact Runtime preparation and authority produced by one
    /// successful declarative AgentCore apply. Every pointer remains owned by
    /// the caller when the generation no longer matches.
    pub fn completeMcpConfigurationApply(
        self: *Runtime,
        expected_generation: u64,
        preparation: *mcp_configuration.Preparation,
        manifest: *mcp_configuration.RuntimeManifest,
        activation: ?*lifecycle.McpActivation,
        selection: ?*lifecycle.McpSelection,
        activation_failed: bool,
    ) bool {
        const runtime = if (self.mcp) |*value| value else return false;
        if (!runtime.completeConfigurationApply(
            expected_generation,
            preparation,
            manifest,
            activation,
            selection,
            activation_failed,
        )) return false;
        self.bumpRevision();
        return true;
    }

    pub fn failMcpConfigurationApply(
        self: *Runtime,
        expected_generation: u64,
    ) void {
        const runtime = if (self.mcp) |*value| value else return;
        if (runtime.failConfigurationApply(expected_generation)) self.bumpRevision();
    }

    pub fn completeMcpConnectionTest(
        self: *Runtime,
        server_id: []const u8,
        outcome: McpConnectionTestOutcome,
        tool_count: u32,
        issue_count: u32,
    ) void {
        const runtime = if (self.mcp) |*value| value else return;
        if (runtime.completeConnectionTest(
            server_id,
            outcome,
            tool_count,
            issue_count,
        )) self.bumpRevision();
    }

    pub fn mcpAuthorizationOperation(
        self: *const Runtime,
    ) ?McpAuthorizationOperationView {
        const runtime = if (self.mcp) |*value| value else return null;
        return runtime.authorizationOperation();
    }

    pub fn mcpServerOperationBusy(
        self: *const Runtime,
        server_id: []const u8,
    ) bool {
        const runtime = if (self.mcp) |*value| value else return false;
        return runtime.serverOperationBusy(server_id);
    }

    pub fn requireMcpOauthReauthorization(
        self: *Runtime,
        failure: McpRuntimeAuthorizationFailure,
    ) Error!McpRuntimeAuthorizationFailureOutcome {
        const runtime = if (self.mcp) |*value| value else return .rejected;
        defer self.publishMcpRuntimeChanges();
        return runtime.requireOauthReauthorization(failure) catch |err| return @errorCast(err);
    }

    pub fn beginMcpAuthorization(
        self: *Runtime,
        expected_generation: u64,
        server_id: []const u8,
    ) Error!?McpAuthorizationStart {
        if (self.shutting_down) return null;
        const runtime = if (self.mcp) |*value| value else return null;
        if (!runtime.canBeginAuthorization(expected_generation, server_id)) return null;
        var entropy: [16]u8 = undefined;
        std.Io.randomSecure(self.io, &entropy) catch return null;
        const hex = std.fmt.bytesToHex(entropy, .lower);
        var operation_storage: [25]u8 = undefined;
        const operation_id = std.fmt.bufPrint(
            &operation_storage,
            "mcp-auth-{s}",
            .{hex[0..16]},
        ) catch unreachable;
        defer self.publishMcpRuntimeChanges();
        return runtime.beginAuthorization(
            expected_generation,
            server_id,
            operation_id,
        ) catch |err| return @errorCast(err);
    }

    pub fn advanceMcpAuthorization(
        self: *Runtime,
        operation_id: []const u8,
        phase: McpAuthorizationPhase,
    ) bool {
        const runtime = if (self.mcp) |*value| value else return false;
        defer self.publishMcpRuntimeChanges();
        return runtime.advanceAuthorization(operation_id, phase);
    }

    pub fn finishMcpAuthorization(
        self: *Runtime,
        operation_id: []const u8,
    ) bool {
        const runtime = if (self.mcp) |*value| value else return false;
        defer self.publishMcpRuntimeChanges();
        return runtime.finishAuthorization(operation_id);
    }
    /// Host-only rendering delegates canonical validation and formatting to the
    /// Product MCP aggregate; bytes never enter the Renderer snapshot path.
    pub fn writeMcpConnectionApprovalDetails(
        self: *const Runtime,
        expected_generation: u64,
        server_id: []const u8,
        output: []u8,
    ) ![]const u8 {
        const runtime = if (self.mcp) |*value| value else return error.McpManagementUnavailable;
        return runtime.writeConnectionApprovalDetails(
            expected_generation,
            server_id,
            output,
        );
    }

    pub fn validateMcpSecretCapture(
        self: *const Runtime,
        expected_generation: u64,
        server_id: []const u8,
        target: McpSecretCaptureTarget,
    ) !void {
        const runtime = if (self.mcp) |*value| value else return error.McpManagementUnavailable;
        return runtime.validateSecretCapture(
            expected_generation,
            server_id,
            target,
        );
    }
    /// Binds metadata-validated consent to the current approved server and
    /// returns the exact client identity used to construct the authorization
    /// URL. Dynamic registration already committed these facts; a
    /// pre-registered client commits them here as one ordinary mutation.
    /// Binds metadata-validated consent to the current approved server and
    /// returns the exact client identity used by the Application coordinator.
    pub fn authorizeMcpOauth(
        self: *Runtime,
        plan: McpOauthAuthorizationPlan,
    ) Error!McpOauthAuthorizationOutcome {
        const runtime = if (self.mcp) |*value| value else return .rejected;
        defer self.publishMcpRuntimeChanges();
        return runtime.authorizeOauth(plan) catch |err| return @errorCast(err);
    }

    pub fn beginMcpOauthDynamicRegistration(
        self: *Runtime,
        consent: mcp_configuration.OauthConsentInput,
    ) Error!McpOauthOperationBeginOutcome {
        const runtime = if (self.mcp) |*value| value else return .rejected;
        defer self.publishMcpRuntimeChanges();
        return runtime.beginOauthDynamicRegistration(consent) catch |err| return @errorCast(err);
    }

    pub fn completeMcpOauthDynamicRegistration(
        self: *Runtime,
        input: mcp_configuration.CompleteDynamicRegistrationInput,
    ) Error!mcp_configuration.ManagementOutcome {
        const runtime = if (self.mcp) |*value| value else {
            if (input.client_secret) |secret| std.crypto.secureZero(u8, secret);
            return .rejected;
        };
        defer self.publishMcpRuntimeChanges();
        return runtime.completeOauthDynamicRegistration(input) catch |err| return @errorCast(err);
    }

    pub fn beginMcpOauthCodeExchange(
        self: *Runtime,
        server_id: []const u8,
    ) Error!McpOauthCodeExchangeBeginOutcome {
        const runtime = if (self.mcp) |*value| value else return .rejected;
        defer self.publishMcpRuntimeChanges();
        return runtime.beginOauthCodeExchange(server_id) catch |err| return @errorCast(err);
    }

    pub fn completeMcpOauthCodeExchange(
        self: *Runtime,
        input: mcp_configuration.CompleteCodeExchangeInput,
    ) Error!mcp_configuration.ManagementOutcome {
        const runtime = if (self.mcp) |*value| value else {
            std.crypto.secureZero(u8, input.access_token);
            if (input.refresh_token) |secret| std.crypto.secureZero(u8, secret);
            return .rejected;
        };
        defer self.publishMcpRuntimeChanges();
        return runtime.completeOauthCodeExchange(input) catch |err| return @errorCast(err);
    }

    /// Borrowed until the next Product MCP mutation. Application stores only
    /// the due time in its one-shot timer and asks again when it fires.
    pub fn nextMcpOauthExpiry(self: *const Runtime) ?McpOauthExpiry {
        const runtime = if (self.mcp) |*value| value else return null;
        return runtime.nextOauthExpiry();
    }

    pub fn beginMcpOauthRefresh(
        self: *Runtime,
        server_id: []const u8,
    ) Error!McpOauthRefreshBeginOutcome {
        self.syncLifecycle();
        const runtime = if (self.mcp) |*value| value else return .rejected;
        defer self.publishMcpRuntimeChanges();
        return runtime.beginOauthRefresh(server_id) catch |err| return @errorCast(err);
    }

    pub fn completeMcpOauthRefresh(
        self: *Runtime,
        input: mcp_configuration.CompleteRefreshInput,
        runtime_commit: McpOauthRuntimeCommit,
    ) Error!mcp_configuration.ManagementOutcome {
        const runtime = if (self.mcp) |*value| value else {
            std.crypto.secureZero(u8, input.access_token);
            if (input.refresh_token) |secret| std.crypto.secureZero(u8, secret);
            return .rejected;
        };
        defer self.publishMcpRuntimeChanges();
        return runtime.completeOauthRefresh(input, runtime_commit) catch |err| return @errorCast(err);
    }

    pub fn clearMcpOauthOperation(
        self: *Runtime,
        operation_id: []const u8,
    ) Error!mcp_configuration.ManagementOutcome {
        const runtime = if (self.mcp) |*value| value else return .rejected;
        defer self.publishMcpRuntimeChanges();
        return runtime.clearOauthOperation(operation_id) catch |err| return @errorCast(err);
    }

    pub fn recoverMcpOauthOperation(
        self: *Runtime,
        operation_id: []const u8,
    ) Error!mcp_configuration.ManagementOutcome {
        const runtime = if (self.mcp) |*value| value else return .rejected;
        defer self.publishMcpRuntimeChanges();
        return runtime.recoverOauthOperation(operation_id) catch |err| return @errorCast(err);
    }
    pub fn createMcpHttpServer(
        self: *Runtime,
        expected_generation: u64,
        input: mcp_configuration.CreateHttpServerInput,
    ) Error!mcp_configuration.ManagementOutcome {
        const runtime = if (self.mcp) |*value| value else return .rejected;
        defer self.publishMcpRuntimeChanges();
        return runtime.createHttpServer(expected_generation, input) catch |err| return @errorCast(err);
    }

    pub fn createMcpOauthHttpServer(
        self: *Runtime,
        expected_generation: u64,
        input: mcp_configuration.CreateOauthHttpServerInput,
    ) Error!mcp_configuration.ManagementOutcome {
        const runtime = if (self.mcp) |*value| value else return .rejected;
        defer self.publishMcpRuntimeChanges();
        return runtime.createOauthHttpServer(expected_generation, input) catch |err| return @errorCast(err);
    }

    pub fn createMcpStdioServer(
        self: *Runtime,
        expected_generation: u64,
        input: mcp_configuration.CreateStdioServerInput,
    ) Error!mcp_configuration.ManagementOutcome {
        const runtime = if (self.mcp) |*value| value else return .rejected;
        defer self.publishMcpRuntimeChanges();
        return runtime.createStdioServer(expected_generation, input) catch |err| return @errorCast(err);
    }

    pub fn updateMcpHttpConnection(
        self: *Runtime,
        expected_generation: u64,
        input: mcp_configuration.UpdateHttpConnectionInput,
    ) Error!mcp_configuration.ManagementOutcome {
        const runtime = if (self.mcp) |*value| value else return .rejected;
        defer self.publishMcpRuntimeChanges();
        return runtime.updateHttpConnection(expected_generation, input) catch |err| return @errorCast(err);
    }

    pub fn updateMcpOauthHttpConnection(
        self: *Runtime,
        expected_generation: u64,
        input: mcp_configuration.UpdateOauthHttpConnectionInput,
    ) Error!mcp_configuration.ManagementOutcome {
        const runtime = if (self.mcp) |*value| value else return .rejected;
        defer self.publishMcpRuntimeChanges();
        return runtime.updateOauthHttpConnection(expected_generation, input) catch |err| return @errorCast(err);
    }

    pub fn updateMcpStdioConnection(
        self: *Runtime,
        expected_generation: u64,
        input: mcp_configuration.UpdateStdioConnectionInput,
    ) Error!mcp_configuration.ManagementOutcome {
        const runtime = if (self.mcp) |*value| value else return .rejected;
        defer self.publishMcpRuntimeChanges();
        return runtime.updateStdioConnection(expected_generation, input) catch |err| return @errorCast(err);
    }

    /// Accepts the Host-owned copy of a manually entered secret forwarded by
    /// Bridge. Product validates and persists it through the credential transaction;
    /// the mutable input is consumed and zeroed on every path, including rejection.
    pub fn captureMcpStaticSecret(
        self: *Runtime,
        expected_generation: u64,
        input: mcp_configuration.CaptureStaticSecretInput,
    ) Error!mcp_configuration.ManagementOutcome {
        const runtime = if (self.mcp) |*value| value else {
            std.crypto.secureZero(u8, input.secret);
            return .rejected;
        };
        defer self.publishMcpRuntimeChanges();
        return runtime.captureStaticSecret(expected_generation, input) catch |err| return @errorCast(err);
    }

    /// The same owned-copy boundary for a manually entered, pre-registered OAuth
    /// client secret; automatically acquired OAuth credentials do not use Bridge.
    pub fn captureMcpOauthClientSecret(
        self: *Runtime,
        expected_generation: u64,
        input: mcp_configuration.CaptureOauthClientSecretInput,
    ) Error!mcp_configuration.ManagementOutcome {
        const runtime = if (self.mcp) |*value| value else {
            std.crypto.secureZero(u8, input.secret);
            return .rejected;
        };
        defer self.publishMcpRuntimeChanges();
        return runtime.captureOauthClientSecret(expected_generation, input) catch |err| return @errorCast(err);
    }

    pub fn renameMcpServer(
        self: *Runtime,
        expected_generation: u64,
        input: mcp_configuration.RenameServerInput,
    ) Error!mcp_configuration.ManagementOutcome {
        const runtime = if (self.mcp) |*value| value else return .rejected;
        defer self.publishMcpRuntimeChanges();
        return runtime.renameServer(expected_generation, input) catch |err| return @errorCast(err);
    }

    pub fn approveMcpConnection(
        self: *Runtime,
        expected_generation: u64,
        input: mcp_configuration.ApproveConnectionInput,
    ) Error!mcp_configuration.ManagementOutcome {
        const runtime = if (self.mcp) |*value| value else return .rejected;
        defer self.publishMcpRuntimeChanges();
        return runtime.approveConnection(expected_generation, input) catch |err| return @errorCast(err);
    }

    pub fn setMcpServerEnabled(
        self: *Runtime,
        expected_generation: u64,
        input: mcp_configuration.SetServerEnabledInput,
    ) Error!mcp_configuration.ManagementOutcome {
        const runtime = if (self.mcp) |*value| value else return .rejected;
        defer self.publishMcpRuntimeChanges();
        return runtime.setServerEnabled(expected_generation, input) catch |err| return @errorCast(err);
    }

    pub fn setMcpAllowedTools(
        self: *Runtime,
        expected_generation: u64,
        input: mcp_configuration.SetAllowedToolsInput,
    ) Error!mcp_configuration.ManagementOutcome {
        const runtime = if (self.mcp) |*value| value else return .rejected;
        defer self.publishMcpRuntimeChanges();
        return runtime.setAllowedTools(expected_generation, input) catch |err| return @errorCast(err);
    }

    pub fn removeMcpServer(
        self: *Runtime,
        expected_generation: u64,
        server_id: []const u8,
    ) Error!mcp_configuration.ManagementOutcome {
        const runtime = if (self.mcp) |*value| value else return .rejected;
        defer self.publishMcpRuntimeChanges();
        return runtime.removeServer(expected_generation, server_id) catch |err| return @errorCast(err);
    }
    fn recoverExpiredMcpCatalogNoFail(self: *Runtime) void {
        if (self.shutting_down) return;
        if (self.mcp) |*runtime|
            if (runtime.recoverExpiredCatalog()) self.bumpRevision();
    }

    fn updateMcpRefreshDeadlineNoFail(self: *Runtime) void {
        if (self.mcp) |*runtime| runtime.updateRefreshDeadline();
    }

    fn rearmMcpRefreshTimerNoFail(self: *Runtime) void {
        if (self.mcp) |*runtime| runtime.rearmRefreshTimer();
    }

    fn mcpViewContainsSensitive(context: *const anyopaque, value: []const u8) bool {
        const self: *const Runtime = @ptrCast(@alignCast(context));
        return self.containsKnownCredential(value);
    }

    fn writeMcpViewJson(
        context: *const anyopaque,
        writer: *std.Io.Writer,
        value: []const u8,
    ) mcp_runtime.ViewError!void {
        const self: *const Runtime = @ptrCast(@alignCast(context));
        self.projectedJsonValueWithKnownCredentials(writer, value) catch
            return error.SnapshotTooLarge;
    }

    fn writeMcpProjection(
        self: *Runtime,
        writer: *std.Io.Writer,
    ) Error!void {
        mcp_runtime.writeProjection(
            if (self.mcp) |*runtime| runtime else null,
            writer,
            .{
                .context = self,
                .contains_sensitive_fn = mcpViewContainsSensitive,
                .write_json_fn = writeMcpViewJson,
            },
        ) catch return error.SnapshotTooLarge;
    }

    /// Commits the final assistant suffix only after Runtime has drained the
    /// Agent event pump following `markTerminalRunsBeforeEventDrain`.
    /// Any later event for the Run is rejected by `applyEvent`.
    pub fn finalizeMarkedTerminalRunsAfterEventDrain(self: *Runtime) void {
        const finished_at_ms = self.run_clock.now();
        const finished_at_unix_ms = self.run_clock.nowUnixMs();
        const changed = self.task_runtime.finalizeMarkedTerminalRunsAfterEventDrain(
            finished_at_ms,
            finished_at_unix_ms,
        );
        if (changed) {
            self.commitTaskStateNoFail();
            self.bumpRevision();
        }
    }

    // Aggregate fixtures support existing domain tests; production has only the scoped writeSnapshot.
    pub const writeAggregateFixture = if (builtin.is_test) TestSupport.writeAggregateFixture else {};
    pub const writeViewFixture = if (builtin.is_test) TestSupport.writeViewFixture else {};

    fn writeLiveContextFields(self: *Runtime, writer: *std.Io.Writer, include_revision: bool) Error!void {
        const schedule_persistence_ready =
            self.schedule.persistenceHealth() == .ready;
        const task_persistence_ready = self.task_persistence_health.operational();
        const background_schedule_wake = self.schedule.backgroundAvailable();
        const attachments_available = self.attachments.file_store != null and self.attachments.images.prepare_fn != null;
        const mcp_capabilities = if (self.mcp) |*runtime|
            runtime.capabilities()
        else
            mcp_runtime.Capabilities{ .management = false, .host = .{} };
        writer.writeByte('{') catch return error.SnapshotTooLarge;
        if (include_revision) writer.print("\"revision\":\"{d}\",", .{self.revision}) catch return error.SnapshotTooLarge;
        writer.print("\"capabilities\":{{\"taskHistoryPersistence\":{},\"taskHistoryPersistenceHealth\":\"{s}\",\"taskHistoryRecoveryAvailable\":{},\"retainedTaskHistoryCount\":\"{d}\",\"conversationRecovery\":true,\"executionRebind\":true,\"structuredPlan\":false,\"typedOutputs\":false,\"typedFileChanges\":true,\"persistentWorkspacePermissions\":false,\"permissionProfiles\":{},\"automaticWorkspaces\":{},\"scheduledTasks\":{},\"scheduledTaskPersistence\":{},\"scheduledTaskPersistenceHealth\":\"{s}\",\"scheduledTaskRecoveryAvailable\":{},\"backgroundScheduleWake\":{},\"localSkillManagement\":{},\"skillManagementHealth\":\"{s}\",\"customProviderManagement\":{},\"customProviderSecretCapture\":{},\"customModelTest\":{},\"mcpManagement\":{},\"mcpConnectionApproval\":{},\"mcpSecretCapture\":{},\"mcpSecretMaxBytes\":{d},\"mcpOAuth\":{},\"attachments\":{{\"enabled\":{},\"imageFormats\":{s},\"maxFiles\":\"{d}\",\"maxFileBytes\":\"{d}\",\"maxStagedBytes\":\"{d}\"}}}},\"permissions\":{{\"availableProfiles\":", .{
            task_persistence_ready,
            @tagName(self.task_persistence_health),
            self.taskHistoryRecoveryAvailable(),
            self.task_runtime.retainedTaskCount(),
            permission_profiles_available,
            self.automaticWorkspacesAvailable(),
            self.schedule.timerEnabled() and schedule_persistence_ready and
                background_schedule_wake,
            schedule_persistence_ready,
            @tagName(self.schedule.persistenceHealth()),
            self.scheduledTaskRecoveryAvailable(),
            background_schedule_wake,
            self.skill.managementHealth() == .ready,
            @tagName(self.skill.managementHealth()),
            self.custom_provider_capabilities.management,
            self.custom_provider_capabilities.secret_capture,
            self.custom_provider_capabilities.model_test,
            mcp_capabilities.management,
            mcp_capabilities.host.connection_approval,
            mcp_capabilities.host.secret_capture,
            mcp_capabilities.secret_max_bytes,
            mcp_capabilities.host.oauth,
            attachments_available,
            if (attachments_available) "[\"png\",\"jpeg\",\"webp\"]" else "[]",
            self.limits.max_attachments_per_draft,
            self.limits.max_attachment_file_bytes,
            self.limits.max_staged_attachment_bytes,
        }) catch
            return error.SnapshotTooLarge;
        if (permission_profiles_available)
            writer.writeAll("[\"approval_required\",\"full_access\"]") catch
                return error.SnapshotTooLarge
        else
            writer.writeAll("[]") catch return error.SnapshotTooLarge;
        writer.print(",\"defaultProfile\":\"{s}\",\"availableModes\":[\"manual\",\"auto_review\",\"full_access\"],\"defaultMode\":\"{s}\"}},\"account\":", .{
            @tagName(self.default_approval_mode.profile()),
            @tagName(self.default_approval_mode),
        }) catch return error.SnapshotTooLarge;
        try self.writeAccount(writer);
        writer.writeAll(",\"models\":") catch return error.SnapshotTooLarge;
        try self.writeModels(writer);
        writer.writeAll(",\"newTaskAdmission\":") catch return error.SnapshotTooLarge;
        try self.writeNewTaskAdmission(writer);
        writer.writeAll(",\"automaticWorkspaceRoot\":") catch
            return error.SnapshotTooLarge;
        try self.writeAutomaticWorkspaceRootConfiguration(writer);
        writer.writeAll(",\"skillCatalog\":") catch
            return error.SnapshotTooLarge;
        try skill_runtime.Runtime.writeCatalogProjection(
            writer,
            self.skillTextProjection(),
            self.skill.personalCatalogProjection(),
        );
    }

    pub fn writeSnapshot(self: *Runtime, output: []u8, request: ViewRequest) (Error || error{InvalidViewRequest})!SnapshotRead {
        if (builtin.is_test) self.view_step_timing = .{};
        self.cancelSnapshot();
        errdefer self.cancelSnapshot();
        try request.validate();
        if (self.projection_security_epoch == 0 or self.projection_history_epoch == 0) return error.InvalidViewRequest;
        std.debug.assert(self.view_credentials == null and self.capture_view == null);
        self.next_view_read_id = std.math.add(u64, self.next_view_read_id, 1) catch return error.ViewVersionExhausted;
        self.view_read.id = self.next_view_read_id;
        self.view_read.security_epoch = self.projection_security_epoch;
        self.capture_view = &self.view_read;
        defer self.capture_view = null;
        self.view_preparation.credentials = .{ .allocator = self.allocator };
        const credentials = &self.view_preparation.credentials.?;
        try credentials.add(self.execution_state.credential());
        try self.task_runtime.visitExecutionCredentials(credentials, ProjectionCredentials.visit);
        self.view_credentials = credentials.values.items;
        defer self.view_credentials = null;
        self.view_preparation.known_epoch = request.known_epoch;
        self.view_preparation.tool_limit = self.limits.max_tools_per_run * request.run_limit * @as(usize, if (request.before_run_id == null) 1 else 2);
        for (request.receipts) |query| if (self.containsKnownCredential(query.operation_id)) return error.InvalidViewRequest;
        var writer = std.Io.Writer.fixed(output);
        writer.print("{{\"revision\":\"{d}\",\"securityEpoch\":\"{d}\",\"historyEpoch\":\"{d}\",\"scope\":{{\"taskId\":", .{ self.revision, self.projection_security_epoch, self.projection_history_epoch }) catch return error.SnapshotTooLarge;
        if (request.task_id) |id| writer.print("\"{d}\"", .{id}) catch return error.SnapshotTooLarge else writer.writeAll("null") catch return error.SnapshotTooLarge;
        writer.writeAll(",\"beforeRunId\":") catch return error.SnapshotTooLarge;
        if (request.before_run_id) |id| writer.print("\"{d}\"", .{id}) catch return error.SnapshotTooLarge else writer.writeAll("null") catch return error.SnapshotTooLarge;
        writer.print(",\"runLimit\":{d},\"management\":\"{s}\",\"search\":{},\"receipts\":", .{ request.run_limit, @tagName(request.management), request.search }) catch return error.SnapshotTooLarge;
        try self.writeViewReceipts(&writer, request.receipts, false);
        writer.writeByte('}') catch return error.SnapshotTooLarge;
        // Time-dependent execution fields are sampled even without a new CoreEvent.
        if (request.task_id) |id| if (self.task_runtime.taskHasActiveOperation(id)) {
            self.encoded_views.invalidate(.taskPage);
        };
        inline for (std.meta.fields(view_cache.Kind)) |field| {
            const kind: view_cache.Kind = @enumFromInt(field.value);
            const key = viewKey(request, kind);
            writer.writeAll(",\"" ++ field.name ++ "\":") catch return error.SnapshotTooLarge;
            const start = writer.end;
            var version: u64 = 0;
            if (self.encoded_views.get(key)) |entry| {
                version = entry.version;
                if (request.known_epoch == self.projection_security_epoch and @field(request.known_versions, field.name) == version) {
                    writer.writeAll("null") catch return error.SnapshotTooLarge;
                    self.view_preparation.reused[field.value] = true;
                } else writer.writeAll(entry.bytes) catch return error.SnapshotTooLarge;
            } else try self.writeViewBlock(&writer, request, kind);
            self.view_preparation.blocks[field.value] = .{ .key = key, .start = start, .end = writer.end, .known = @field(request.known_versions, field.name), .version = version };
            @field(self.view_preparation.versions, field.name) = version;
        }
        try self.view_read.capture(self.allocator, writer.buffered());
        self.view_preparation.scratch_bytes = writer.end;
        // Freeze receipt observations now too; only version/reuse metadata is
        // appended later, without consulting mutable Product facts again.
        var tail_storage: [16 * 1024]u8 = undefined;
        var tail_writer = std.Io.Writer.fixed(&tail_storage);
        self.view_preparation.tail.id = self.view_read.id;
        self.view_preparation.tail.security_epoch = self.projection_security_epoch;
        self.capture_view = &self.view_preparation.tail;
        tail_writer.writeAll(",\"receipts\":") catch return error.SnapshotTooLarge;
        try self.writeViewReceipts(&tail_writer, request.receipts, true);
        tail_writer.writeByte('}') catch return error.SnapshotTooLarge;
        try self.view_preparation.tail.seal(self.allocator, self.limits.max_snapshot_bytes, tail_writer.buffered());
        // Pure cache hits have no preparation work and preserve the fast path.
        const all_cached = for (self.view_preparation.blocks) |block| {
            if (block.version == 0) break false;
        } else true;
        if (all_cached) {
            try self.finishSnapshotPreparation();
        }
        return self.snapshotReadStatus();
    }

    fn snapshotReadStatus(self: *const Runtime) SnapshotRead {
        return .{ .id = self.view_read.id, .bytes = if (self.view_preparation.ready) self.view_read.total else 0, .scratch_bytes = self.view_preparation.scratch_bytes };
    }

    /// Each continuation performs bounded formatter stages, one block comparison,
    /// or final metadata assembly. It never advances execution or samples new facts.
    pub fn continueSnapshot(self: *Runtime, read_id: u64, output: []u8) Error!SnapshotRead {
        if (read_id == 0 or read_id != self.view_read.id or self.view_read.security_epoch != self.projection_security_epoch or @intFromPtr(output.ptr) != self.view_read.storage_identity) return error.StaleSnapshot;
        if (self.view_preparation.ready) return self.snapshotReadStatus();
        errdefer self.cancelSnapshot();
        std.debug.assert(self.capture_view == null and self.view_credentials == null);
        self.view_credentials = self.view_preparation.credentials.?.values.items;
        defer self.view_credentials = null;
        if (self.view_preparation.next_tool < self.view_preparation.tools.items.len) {
            var stages: usize = 0;
            var charged: usize = 0;
            var finished: usize = 0;
            while (self.view_preparation.next_tool < self.view_preparation.tools.items.len and finished < 4) {
                const work = &self.view_preparation.tools.items[self.view_preparation.next_tool];
                self.capture_view = work.child;
                defer self.capture_view = null;
                const size = work.source.?.ownedBytes();
                if (stages != 0 and size > 32 * 1024 -| charged) break;
                const first_string = work.child.strings.items.len;
                var writer = std.Io.Writer.fixed(output);
                try work.source.?.writeStage(&writer, self.taskTextProjection(), &work.state);
                for (work.child.strings.items[first_string..]) |*item| item.at += work.child.skeleton.len;
                try work.child.appendSkeleton(self.allocator, self.limits.max_snapshot_bytes, writer.buffered());
                self.view_preparation.scratch_bytes = @max(self.view_preparation.scratch_bytes, writer.end);
                if (work.state.stage == .done) {
                    try work.child.finalize(self.limits.max_snapshot_bytes);
                    work.source.?.deinit(self.allocator);
                    work.source = null;
                    self.view_preparation.raw_bytes -= size;
                    self.view_preparation.next_tool += 1;
                    finished += 1;
                }
                stages += 1;
                charged += size;
            }
            return self.snapshotReadStatus();
        }
        // Cached metadata is already frozen. Skip these constant-size slots;
        // each invoke is reserved for actual preparation rather than empty turns.
        while (self.view_preparation.next_block < self.view_preparation.blocks.len and self.view_preparation.blocks[self.view_preparation.next_block].version != 0) self.view_preparation.next_block += 1;
        if (self.view_preparation.next_block < self.view_preparation.blocks.len) {
            const index = self.view_preparation.next_block;
            const block = &self.view_preparation.blocks[index];
            if (block.version == 0) {
                const source = try self.view_read.sourceRange(self.allocator, self.limits.max_snapshot_bytes, block.start, block.end);
                defer {
                    std.crypto.secureZero(u8, source);
                    self.allocator.free(source);
                }
                block.version = try self.encoded_views.frozenSource(self.allocator, self.limits.max_snapshot_bytes, block.key, source, block.current);
                var replacement: ?[]const u8 = null;
                if (self.view_preparation.known_epoch == self.projection_security_epoch and block.known == block.version) {
                    replacement = "null";
                    self.view_preparation.reused[index] = true;
                } else if (self.encoded_views.get(block.key)) |entry| {
                    if (entry.version == block.version) replacement = entry.bytes;
                }
                if (replacement) |value| {
                    const delta = try self.view_read.replaceSpan(self.allocator, self.limits.max_snapshot_bytes, block.start, block.end, value);
                    block.end = block.start + value.len;
                    for (self.view_preparation.blocks[index + 1 ..]) |*later| {
                        later.start = @intCast(@as(isize, @intCast(later.start)) + delta);
                        later.end = @intCast(@as(isize, @intCast(later.end)) + delta);
                    }
                } else if (block.current) {
                    self.view_blocks[index] = .{ .key = block.key, .version = block.version, .start = try self.view_read.encodedPosition(block.start), .end = try self.view_read.encodedPosition(block.end) };
                }
            }
            inline for (std.meta.fields(view_cache.Kind)) |field| if (index == field.value) {
                @field(self.view_preparation.versions, field.name) = block.version;
            };
            self.view_preparation.next_block += 1;
            return self.snapshotReadStatus();
        }
        try self.finishSnapshotPreparation();
        return self.snapshotReadStatus();
    }

    fn finishSnapshotPreparation(self: *Runtime) Error!void {
        var metadata: [2048]u8 = undefined;
        var writer = std.Io.Writer.fixed(&metadata);
        writer.writeAll(",\"blockVersions\":{") catch return error.SnapshotTooLarge;
        inline for (std.meta.fields(view_cache.Versions), 0..) |field, index| {
            if (index != 0) writer.writeByte(',') catch return error.SnapshotTooLarge;
            writer.print("\"" ++ field.name ++ "\":\"{d}\"", .{@field(self.view_preparation.versions, field.name)}) catch return error.SnapshotTooLarge;
        }
        writer.writeAll("},\"reusedBlocks\":[") catch return error.SnapshotTooLarge;
        var first = true;
        inline for (std.meta.fields(view_cache.Kind)) |field| if (self.view_preparation.reused[field.value]) {
            if (!first) writer.writeByte(',') catch return error.SnapshotTooLarge;
            writer.writeAll("\"" ++ field.name ++ "\"") catch return error.SnapshotTooLarge;
            first = false;
        };
        writer.writeByte(']') catch return error.SnapshotTooLarge;
        const child = try self.view_read.appendChild(self.allocator, &writer);
        self.view_read.strings.items[self.view_read.strings.items.len - 1].at += self.view_read.skeleton.len;
        child.* = self.view_preparation.tail;
        self.view_preparation.tail = .{};
        try self.view_read.appendSkeleton(self.allocator, self.limits.max_snapshot_bytes, writer.buffered());
        try self.view_read.finalize(self.limits.max_snapshot_bytes);
        if (self.view_preparation.credentials) |*credentials| credentials.deinit();
        self.view_preparation.credentials = null;
        self.view_preparation.tools.deinit(self.allocator);
        self.view_preparation.tools = .empty;
        self.view_preparation.ready = true;
    }

    fn captureToolProjection(context: *const anyopaque, writer: *std.Io.Writer, tool: *const product_task.ToolProjection) product_task.ProjectionError!void {
        const self: *Runtime = @ptrCast(@alignCast(@constCast(context)));
        if (self.view_preparation.tools.items.len >= self.view_preparation.tool_limit) return error.SnapshotTooLarge;
        const owned = self.view_read.ownedBytes() + self.view_preparation.raw_bytes;
        var source = try product_task.OwnedToolProjection.capture(self.allocator, tool, self.limits.max_snapshot_bytes -| owned);
        errdefer source.deinit(self.allocator);
        const child = self.view_read.appendChild(self.allocator, writer) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.SnapshotTooLarge,
        };
        const size = source.ownedBytes();
        try self.view_preparation.tools.append(self.allocator, .{ .source = source, .child = child });
        self.view_preparation.raw_bytes += size;
    }

    pub fn cancelSnapshot(self: *Runtime) void {
        self.view_preparation.clear(self.allocator);
        self.view_read.clear(self.allocator);
        self.view_blocks = @splat(null);
    }

    pub fn writeSnapshotRange(self: *Runtime, read_id: u64, output: []u8, offset: usize, length: usize) Error!void {
        if (read_id == 0 or read_id != self.view_read.id or self.view_read.security_epoch != self.projection_security_epoch or @intFromPtr(output.ptr) != self.view_read.storage_identity) return error.StaleSnapshot;
        if (!self.view_preparation.ready or length == 0 or length > projection_step_bytes or offset > self.view_read.produced or offset > self.view_read.total or length > self.view_read.total - offset or output.len < self.view_read.total) return error.InvalidOffset;
        errdefer self.cancelSnapshot();
        const encode_start = if (builtin.is_test) std.Io.Timestamp.now(self.io, .awake) else {};
        const end = offset + length;
        if (end > self.view_read.produced) _ = try self.view_read.writeNext(output[self.view_read.produced..end]);
        const cache_start = if (builtin.is_test) std.Io.Timestamp.now(self.io, .awake) else {};
        if (builtin.is_test) self.view_step_timing.encode_ns = encode_start.durationTo(cache_start).nanoseconds;
        for (&self.view_blocks) |*maybe| if (maybe.*) |block| {
            if (block.end <= self.view_read.produced) {
                try self.encoded_views.installEncoded(self.allocator, self.limits.max_snapshot_bytes, block.key, block.version, output[block.start..block.end]);
                maybe.* = null;
            }
        };
        if (self.view_read.produced == self.view_read.total and self.view_read.skeleton.len != 0) self.view_read.releasePayload(self.allocator);
        if (builtin.is_test) self.view_step_timing.cache_copy_ns = cache_start.durationTo(std.Io.Timestamp.now(self.io, .awake)).nanoseconds;
    }

    fn viewKey(request: ViewRequest, kind: view_cache.Kind) view_cache.Key {
        return switch (kind) {
            .taskPage => .{ .kind = kind, .task_id = request.task_id orelse 0, .limit = request.run_limit },
            .historyPage => .{ .kind = kind, .task_id = request.task_id orelse 0, .cursor = request.before_run_id orelse 0, .limit = request.run_limit },
            .management => .{ .kind = kind, .management = @intFromEnum(request.management) },
            .searchIndex => .{ .kind = kind, .limit = @intFromBool(request.search) },
            else => .{ .kind = kind },
        };
    }

    fn writeViewBlock(self: *Runtime, writer: *std.Io.Writer, request: ViewRequest, kind: view_cache.Kind) (Error || error{InvalidViewRequest})!void {
        switch (kind) {
            .context => {
                try self.writeLiveContextFields(writer, false);
                writer.writeByte('}') catch return error.SnapshotTooLarge;
            },
            .workspaces => product_workspace.writeProjectionList(writer, &self.workspace, self.workspaceViewProvider()) catch return error.SnapshotTooLarge,
            .taskIndex => {
                writer.writeByte('[') catch return error.SnapshotTooLarge;
                try self.task_runtime.writeSummaryList(writer, self.taskRuntimeProjectionEffects().text);
                writer.writeByte(']') catch return error.SnapshotTooLarge;
            },
            .taskPage => {
                if (request.task_id) |id| try self.task_runtime.writeProjectionPage(writer, self.taskRuntimeProjectionEffects(), id, null, request.run_limit) else writer.writeAll("null") catch return error.SnapshotTooLarge;
            },
            .historyPage => {
                if (request.before_run_id) |cursor| try self.task_runtime.writeHistoryPage(writer, self.taskRuntimeProjectionEffects(), request.task_id.?, cursor, request.run_limit) else writer.writeAll("null") catch return error.SnapshotTooLarge;
            },
            .management => {
                writer.print("{{\"kind\":\"{s}\",\"value\":", .{@tagName(request.management)}) catch return error.SnapshotTooLarge;
                switch (request.management) {
                    .none => writer.writeAll("null") catch return error.SnapshotTooLarge,
                    .skills => try self.writeSkillManagement(writer),
                    .mcp => try self.writeMcpProjection(writer),
                    .schedules => self.schedule.writeProjection(writer, .{ .context = self, .write_json_fn = writeScheduleViewJson }) catch return error.SnapshotTooLarge,
                }
                writer.writeByte('}') catch return error.SnapshotTooLarge;
            },
            .searchIndex => {
                if (request.search) {
                    writer.writeByte('[') catch return error.SnapshotTooLarge;
                    try self.task_runtime.writeSearchProjection(writer, self.taskRuntimeProjectionEffects().text);
                    writer.writeByte(']') catch return error.SnapshotTooLarge;
                } else writer.writeAll("null") catch return error.SnapshotTooLarge;
            },
        }
    }

    fn writeViewReceipts(self: *const Runtime, writer: *std.Io.Writer, queries: []const ViewReceiptQuery, results: bool) Error!void {
        writer.writeByte('[') catch return error.SnapshotTooLarge;
        for (queries, 0..) |query, index| {
            if (index != 0) writer.writeByte(',') catch return error.SnapshotTooLarge;
            writer.print("{{\"taskId\":\"{d}\",\"operationId\":", .{query.task_id}) catch return error.SnapshotTooLarge;
            try self.projectedJsonValueWithKnownCredentials(writer, query.operation_id);
            if (results) writer.print(",\"observed\":{}", .{self.task_runtime.hasInputReceipt(query.task_id, query.operation_id)}) catch return error.SnapshotTooLarge;
            writer.writeByte('}') catch return error.SnapshotTooLarge;
        }
        writer.writeByte(']') catch return error.SnapshotTooLarge;
    }

    fn writeAutomaticWorkspaceRootConfiguration(
        self: *const Runtime,
        writer: *std.Io.Writer,
    ) Error!void {
        const view = self.automaticWorkspaceRootConfiguration();
        const redacted = if (view.canonical_root) |root|
            self.containsKnownCredential(root)
        else
            false;
        writer.print(
            "{{\"generation\":\"{d}\",\"mode\":",
            .{view.generation},
        ) catch return error.SnapshotTooLarge;
        if (view.mode) |mode|
            writer.print("\"{s}\"", .{@tagName(mode)}) catch
                return error.SnapshotTooLarge
        else
            writer.writeAll("null") catch return error.SnapshotTooLarge;
        writer.writeAll(",\"canonicalRoot\":") catch
            return error.SnapshotTooLarge;
        if (view.canonical_root) |root|
            try self.projectedJsonValueWithKnownCredentials(writer, root)
        else
            writer.writeAll("null") catch return error.SnapshotTooLarge;
        writer.print(",\"health\":\"{s}\",\"redacted\":{},\"canChoose\":{},\"canReset\":{},\"canRetry\":{}}}", .{
            @tagName(view.health),
            redacted,
            view.can_choose,
            view.can_reset,
            view.can_retry,
        }) catch return error.SnapshotTooLarge;
    }

    fn writeScheduleViewJson(
        context: *const anyopaque,
        writer: *std.Io.Writer,
        value: []const u8,
    ) product_schedule.ViewError!void {
        const self: *const Runtime = @ptrCast(@alignCast(context));
        self.projectedJsonValueWithKnownCredentials(writer, value) catch
            return error.SnapshotTooLarge;
    }

    fn writeModelMetadata(writer: *std.Io.Writer, metadata: models_contract.ModelMetadata) Error!void {
        var input_buffer: [20]u8 = undefined;
        var output_buffer: [20]u8 = undefined;
        const input: ?[]const u8 = if (metadata.max_input_tokens) |limit|
            std.fmt.bufPrint(&input_buffer, "{d}", .{limit}) catch unreachable
        else
            null;
        const output: ?[]const u8 = if (metadata.max_output_tokens) |limit|
            std.fmt.bufPrint(&output_buffer, "{d}", .{limit}) catch unreachable
        else
            null;
        const caps = metadata.capabilities;
        std.json.Stringify.value(.{
            .maxInputTokens = input,
            .maxOutputTokens = output,
            .capabilities = .{
                .textInput = caps.text_input,
                .audioInput = caps.audio_input,
                .videoInput = caps.video_input,
                .output = caps.output,
                .imageInput = caps.image_input,
                .pdfInput = caps.pdf_input,
                .batch = caps.batch,
                .citations = caps.citations,
                .codeExecution = caps.code_execution,
                .structuredOutputs = caps.structured_outputs,
                .thinking = caps.thinking,
                .effort = caps.effort,
                .contextManagement = .{
                    .supported = caps.context_management.supported,
                    .clearThinking20251015 = caps.context_management.clear_thinking_20251015,
                    .clearToolUses20250919 = caps.context_management.clear_tool_uses_20250919,
                    .compact20260112 = caps.context_management.compact_20260112,
                },
            },
        }, .{}, writer) catch return error.SnapshotTooLarge;
    }

    fn writeAccount(
        self: *Runtime,
        writer: *std.Io.Writer,
    ) Error!void {
        const view = self.accountView();
        writer.print(
            "{{\"state\":\"{s}\",\"canCancel\":{},\"accountId\":",
            .{
                @tagName(view.state),
                view.can_cancel,
            },
        ) catch return error.SnapshotTooLarge;
        try self.projectedJsonValue(writer, view.account_id);
        writer.writeAll(",\"displayName\":") catch
            return error.SnapshotTooLarge;
        try self.projectedJsonValue(writer, view.display_name);
        writer.writeAll(",\"emailHint\":") catch
            return error.SnapshotTooLarge;
        try self.projectedJsonValue(writer, view.email_hint);
        writer.writeAll(",\"phoneHint\":") catch
            return error.SnapshotTooLarge;
        try self.projectedJsonValue(writer, view.phone_hint);
        writer.writeAll(",\"concurrencyLimit\":") catch
            return error.SnapshotTooLarge;
        if (view.concurrency_limit) |limit|
            writer.print("{d}", .{limit}) catch return error.SnapshotTooLarge
        else
            writer.writeAll("null") catch return error.SnapshotTooLarge;
        writer.print(",\"errorCode\":\"{s}\",\"safeDiagnostic\":", .{
            @tagName(view.error_code),
        }) catch return error.SnapshotTooLarge;
        try self.projectedJsonValue(writer, view.safe_diagnostic);
        const summary = view.summary;
        writer.print(",\"summary\":{{\"operation\":\"{s}\",\"usageEligibility\":\"{s}\",\"wallet\":{{\"availability\":\"{s}\",\"balanceU\":", .{
            @tagName(summary.operation),
            @tagName(summary.usage_eligibility),
            @tagName(summary.wallet.availability),
        }) catch return error.SnapshotTooLarge;
        try writeNullableProjectedJsonValue(self, writer, summary.wallet.balance_u);
        writer.writeAll(",\"syncedAt\":") catch return error.SnapshotTooLarge;
        try writeNullableProjectedJsonValue(self, writer, summary.wallet.synced_at_unix_ms);
        writer.print(",\"errorCode\":\"{s}\",\"safeDiagnostic\":", .{@tagName(summary.wallet.error_code)}) catch
            return error.SnapshotTooLarge;
        try self.projectedJsonValue(writer, summary.wallet.safe_diagnostic);
        writer.print("}},\"usage\":{{\"availability\":\"{s}\",\"today\":", .{@tagName(summary.usage.availability)}) catch
            return error.SnapshotTooLarge;
        if (summary.usage.today) |today| {
            writer.writeAll("{\"inputTokens\":") catch return error.SnapshotTooLarge;
            try self.projectedJsonValue(writer, today.input_tokens);
            writer.writeAll(",\"outputTokens\":") catch return error.SnapshotTooLarge;
            try self.projectedJsonValue(writer, today.output_tokens);
            writer.writeAll(",\"cacheCreationTokens\":") catch return error.SnapshotTooLarge;
            try self.projectedJsonValue(writer, today.cache_creation_tokens);
            writer.writeAll(",\"cacheReadTokens\":") catch return error.SnapshotTooLarge;
            try self.projectedJsonValue(writer, today.cache_read_tokens);
            writer.writeAll(",\"totalTokens\":") catch return error.SnapshotTooLarge;
            try self.projectedJsonValue(writer, today.total_tokens);
            writer.writeAll(",\"actualCostU\":") catch return error.SnapshotTooLarge;
            try self.projectedJsonValue(writer, today.actual_cost_u);
            writer.writeByte('}') catch return error.SnapshotTooLarge;
        } else writer.writeAll("null") catch return error.SnapshotTooLarge;
        writer.writeAll(",\"total\":") catch return error.SnapshotTooLarge;
        if (summary.usage.total) |total| {
            writer.writeAll("{\"totalTokens\":") catch return error.SnapshotTooLarge;
            try self.projectedJsonValue(writer, total.total_tokens);
            writer.writeAll(",\"actualCostU\":") catch return error.SnapshotTooLarge;
            try self.projectedJsonValue(writer, total.actual_cost_u);
            writer.writeByte('}') catch return error.SnapshotTooLarge;
        } else writer.writeAll("null") catch return error.SnapshotTooLarge;
        writer.writeAll(",\"syncedAt\":") catch return error.SnapshotTooLarge;
        try writeNullableProjectedJsonValue(self, writer, summary.usage.synced_at_unix_ms);
        writer.print(",\"errorCode\":\"{s}\",\"safeDiagnostic\":", .{@tagName(summary.usage.error_code)}) catch
            return error.SnapshotTooLarge;
        try self.projectedJsonValue(writer, summary.usage.safe_diagnostic);
        writer.print("}},\"history\":{{\"availability\":\"{s}\",\"startDate\":", .{@tagName(summary.history.availability)}) catch
            return error.SnapshotTooLarge;
        try writeNullableProjectedJsonValue(self, writer, summary.history.start_date);
        writer.writeAll(",\"endDate\":") catch return error.SnapshotTooLarge;
        try writeNullableProjectedJsonValue(self, writer, summary.history.end_date);
        writer.writeAll(",\"days\":[") catch return error.SnapshotTooLarge;
        for (summary.history.days, 0..) |day, index| {
            if (index != 0) writer.writeByte(',') catch return error.SnapshotTooLarge;
            writer.writeAll("{\"date\":") catch return error.SnapshotTooLarge;
            try self.projectedJsonValue(writer, day.date);
            writer.writeAll(",\"inputTokens\":") catch return error.SnapshotTooLarge;
            try self.projectedJsonValue(writer, day.input_tokens);
            writer.writeAll(",\"outputTokens\":") catch return error.SnapshotTooLarge;
            try self.projectedJsonValue(writer, day.output_tokens);
            writer.writeAll(",\"cacheCreationTokens\":") catch return error.SnapshotTooLarge;
            try self.projectedJsonValue(writer, day.cache_creation_tokens);
            writer.writeAll(",\"cacheReadTokens\":") catch return error.SnapshotTooLarge;
            try self.projectedJsonValue(writer, day.cache_read_tokens);
            writer.writeAll(",\"totalTokens\":") catch return error.SnapshotTooLarge;
            try self.projectedJsonValue(writer, day.total_tokens);
            writer.writeAll(",\"actualCostU\":") catch return error.SnapshotTooLarge;
            try self.projectedJsonValue(writer, day.actual_cost_u);
            writer.writeByte('}') catch return error.SnapshotTooLarge;
        }
        writer.writeAll("],\"syncedAt\":") catch return error.SnapshotTooLarge;
        try writeNullableProjectedJsonValue(self, writer, summary.history.synced_at_unix_ms);
        writer.print(",\"errorCode\":\"{s}\",\"safeDiagnostic\":", .{@tagName(summary.history.error_code)}) catch
            return error.SnapshotTooLarge;
        try self.projectedJsonValue(writer, summary.history.safe_diagnostic);
        writer.writeAll("}}}") catch return error.SnapshotTooLarge;
    }

    fn writeNullableProjectedJsonValue(
        self: *Runtime,
        writer: *std.Io.Writer,
        value: []const u8,
    ) Error!void {
        if (value.len == 0) {
            writer.writeAll("null") catch return error.SnapshotTooLarge;
        } else {
            try self.projectedJsonValue(writer, value);
        }
    }

    fn writeModels(self: *Runtime, writer: *std.Io.Writer) Error!void {
        const view = self.modelsView();
        writer.print(
            "{{\"availability\":\"{s}\",\"persistenceHealth\":\"{s}\",\"providers\":[",
            .{ @tagName(view.availability), @tagName(view.persistence_health) },
        ) catch return error.SnapshotTooLarge;
        for (view.providers, 0..) |provider, provider_index| {
            if (provider_index != 0) writer.writeByte(',') catch
                return error.SnapshotTooLarge;
            writer.writeAll("{\"id\":") catch return error.SnapshotTooLarge;
            try self.projectedJsonValue(writer, provider.id);
            writer.writeAll(",\"displayName\":") catch return error.SnapshotTooLarge;
            try self.projectedJsonValue(writer, provider.display_name);
            writer.print(",\"recommended\":{},\"catalogState\":\"{s}\",\"principalRef\":", .{
                provider.recommended,
                @tagName(provider.catalog_state),
            }) catch return error.SnapshotTooLarge;
            try self.projectedJsonValue(writer, provider.principal_ref);
            writer.writeAll(",\"models\":") catch return error.SnapshotTooLarge;
            try self.writeCatalogModels(writer, provider.models);
            writer.print(",\"catalogGeneration\":\"{d}\",\"sourceGeneration\":\"{d}\",\"errorCode\":\"{s}\",\"safeDiagnostic\":", .{
                provider.catalog_generation,
                provider.source_generation,
                @tagName(provider.error_code),
            }) catch return error.SnapshotTooLarge;
            try self.projectedJsonValue(writer, provider.safe_diagnostic);
            writer.writeByte('}') catch return error.SnapshotTooLarge;
        }
        writer.writeAll("],\"metaskSelection\":") catch return error.SnapshotTooLarge;
        try self.writeOptionalModelRef(writer, view.metask_selection);
        writer.print(",\"metaskSelectionRevision\":\"{d}\",\"defaultSelection\":", .{
            view.metask_selection_revision,
        }) catch return error.SnapshotTooLarge;
        try self.writeOptionalModelRef(writer, view.default_selection);
        writer.print(",\"selectionRevision\":\"{d}\",\"operation\":\"{s}\",\"errorCode\":\"{s}\",\"builtinProviderPresets\":[", .{
            view.selection_revision,
            @tagName(view.operation),
            @tagName(view.error_code),
        }) catch return error.SnapshotTooLarge;
        for (view.builtin_provider_presets, 0..) |preset, index| {
            if (index != 0) writer.writeByte(',') catch
                return error.SnapshotTooLarge;
            writer.print("{{\"id\":\"{s}\",\"displayName\":", .{@tagName(preset.id)}) catch
                return error.SnapshotTooLarge;
            try self.projectedJsonValue(writer, preset.display_name);
            writer.print(",\"protocol\":\"{s}\",\"defaultBaseUrl\":", .{@tagName(preset.protocol)}) catch
                return error.SnapshotTooLarge;
            try self.projectedJsonValue(writer, preset.default_base_url);
            writer.writeAll(",\"apiKeyUrl\":") catch return error.SnapshotTooLarge;
            try self.projectedJsonValue(writer, preset.api_key_url);
            writer.writeAll(",\"documentationUrl\":") catch return error.SnapshotTooLarge;
            try self.projectedJsonValue(writer, preset.documentation_url);
            writer.writeByte('}') catch return error.SnapshotTooLarge;
        }
        writer.writeAll("],\"customProviders\":[") catch return error.SnapshotTooLarge;
        try self.writeCustomProviders(writer, view.custom_providers);
        writer.writeAll("]}") catch return error.SnapshotTooLarge;
    }

    fn writeOptionalModelRef(
        self: *Runtime,
        writer: *std.Io.Writer,
        value: ?models_contract.ModelRef,
    ) Error!void {
        if (value) |model_ref| {
            writer.writeAll("{\"sourceId\":") catch return error.SnapshotTooLarge;
            try self.projectedJsonValue(writer, model_ref.source_id);
            writer.writeAll(",\"modelId\":") catch return error.SnapshotTooLarge;
            try self.projectedJsonValue(writer, model_ref.model_id);
            writer.writeByte('}') catch return error.SnapshotTooLarge;
        } else writer.writeAll("null") catch return error.SnapshotTooLarge;
    }

    fn writeCatalogModels(self: *Runtime, writer: *std.Io.Writer, models: []const models_contract.ModelView) Error!void {
        writer.writeByte('[') catch return error.SnapshotTooLarge;
        for (models, 0..) |model, index| {
            if (index != 0) writer.writeByte(',') catch return error.SnapshotTooLarge;
            writer.writeAll("{\"id\":") catch return error.SnapshotTooLarge;
            try self.projectedJsonValue(writer, model.id);
            writer.writeAll(",\"displayName\":") catch return error.SnapshotTooLarge;
            try self.projectedJsonValue(writer, model.display_name);
            writer.writeAll(",\"metadata\":") catch return error.SnapshotTooLarge;
            try writeModelMetadata(writer, model.metadata);
            writer.print(",\"metadataProvenance\":\"{s}\"}}", .{@tagName(model.metadata_provenance)}) catch return error.SnapshotTooLarge;
        }
        writer.writeByte(']') catch return error.SnapshotTooLarge;
    }

    fn writeCustomProviders(
        self: *Runtime,
        writer: *std.Io.Writer,
        providers: []const models_contract.CustomProviderView,
    ) Error!void {
        for (providers, 0..) |provider, index| {
            if (index != 0) writer.writeByte(',') catch return error.SnapshotTooLarge;
            writer.writeAll("{\"id\":") catch return error.SnapshotTooLarge;
            try self.projectedJsonValue(writer, provider.id);
            writer.writeAll(",\"builtinProviderId\":") catch return error.SnapshotTooLarge;
            if (provider.builtin_provider_id) |provider_id|
                writer.print("\"{s}\"", .{@tagName(provider_id)}) catch
                    return error.SnapshotTooLarge
            else
                writer.writeAll("null") catch return error.SnapshotTooLarge;
            writer.writeAll(",\"displayName\":") catch return error.SnapshotTooLarge;
            try self.projectedJsonValue(writer, provider.display_name);
            writer.print(",\"protocol\":\"{s}\",\"normalizedBaseUrl\":", .{@tagName(provider.protocol)}) catch
                return error.SnapshotTooLarge;
            try self.projectedJsonValue(writer, provider.normalized_base_url);
            writer.print(",\"state\":\"{s}\",\"credentialStatus\":\"{s}\",\"enabled\":{},\"providerRevision\":\"{d}\",\"sourceGeneration\":\"{d}\",\"catalogGeneration\":\"{d}\",\"models\":[", .{
                @tagName(provider.state),
                @tagName(provider.credential_status),
                provider.enabled,
                provider.provider_revision,
                provider.source_generation,
                provider.catalog_generation,
            }) catch return error.SnapshotTooLarge;
            for (provider.models, 0..) |model, model_index| {
                if (model_index != 0) writer.writeByte(',') catch return error.SnapshotTooLarge;
                writer.writeAll("{\"id\":") catch return error.SnapshotTooLarge;
                try self.projectedJsonValue(writer, model.id);
                writer.writeAll(",\"displayName\":") catch return error.SnapshotTooLarge;
                try self.projectedJsonValue(writer, model.display_name);
                writer.writeAll(",\"metadata\":") catch return error.SnapshotTooLarge;
                try writeModelMetadata(writer, model.metadata);
                writer.print(",\"metadataProvenance\":\"{s}\",\"testStatus\":\"{s}\",\"ready\":{}", .{
                    @tagName(model.metadata_provenance),
                    @tagName(model.test_status),
                    model.ready,
                }) catch return error.SnapshotTooLarge;
                writer.writeByte('}') catch return error.SnapshotTooLarge;
            }
            writer.writeAll("]}") catch return error.SnapshotTooLarge;
        }
    }

    fn writeNewTaskAdmission(
        self: *Runtime,
        writer: *std.Io.Writer,
    ) Error!void {
        const view = self.newTaskAdmissionView();
        writer.print("{{\"available\":{},\"reason\":\"{s}\",\"activeModelRef\":", .{
            view.available,
            @tagName(view.reason),
        }) catch
            return error.SnapshotTooLarge;
        try self.writeOptionalModelRef(writer, view.active_model_ref);
        writer.print(",\"activeGeneration\":\"{d}\",\"activeSelectionRevision\":\"{d}\",\"state\":\"{s}\"}}", .{
            view.active_generation,
            view.active_selection_revision,
            @tagName(view.state),
        }) catch return error.SnapshotTooLarge;
    }

    fn workspaceViewSignals(
        context: *const anyopaque,
        workspace_id: u64,
    ) WorkspaceSignals {
        const self: *const Runtime = @ptrCast(@alignCast(context));
        const facts = self.task_runtime.workspaceSignals(workspace_id);
        return .{
            .running = facts.running,
            .attention = facts.attention,
            .failed_or_interrupted = facts.failed_or_interrupted,
        };
    }

    fn workspaceViewContainsSensitive(
        context: *const anyopaque,
        value: []const u8,
    ) bool {
        const self: *const Runtime = @ptrCast(@alignCast(context));
        return self.containsKnownCredential(value);
    }

    fn workspaceViewWriteJson(
        context: *const anyopaque,
        writer: *std.Io.Writer,
        value: []const u8,
    ) product_workspace.ViewError!void {
        const self: *const Runtime = @ptrCast(@alignCast(context));
        self.projectedJsonValueWithKnownCredentials(writer, value) catch
            return error.SnapshotTooLarge;
    }

    fn workspaceViewWriteCatalog(
        context: *const anyopaque,
        writer: *std.Io.Writer,
        workspace_id: u64,
        workspace_epoch: u64,
    ) product_workspace.ViewError!void {
        const self: *const Runtime = @ptrCast(@alignCast(context));
        const workspace = self.workspace.facts(workspace_id) orelse unreachable;
        std.debug.assert(workspace.epoch == workspace_epoch);
        const projection = self.skill.workspaceCatalogProjection(workspace_id, workspace_epoch) catch unreachable;
        skill_runtime.Runtime.writeCatalogProjection(
            writer,
            self.skillTextProjection(),
            projection,
        ) catch return error.SnapshotTooLarge;
    }

    fn workspaceViewProvider(self: *const Runtime) product_workspace.ViewProvider {
        return .{
            .context = self,
            .signals_fn = workspaceViewSignals,
            .contains_sensitive_fn = workspaceViewContainsSensitive,
            .write_json_fn = workspaceViewWriteJson,
            .write_catalog_fn = workspaceViewWriteCatalog,
            .write_skill_source_discovery_fn = workspaceViewWriteSourceDiscovery,
        };
    }

    fn workspaceViewWriteSourceDiscovery(context: *const anyopaque, writer: *std.Io.Writer, id: u64, epoch: u64) product_workspace.ViewError!void {
        const self: *const Runtime = @ptrCast(@alignCast(context));
        return self.skill.writeWorkspaceSourceDiscovery(writer, id, epoch);
    }

    pub fn deinit(self: *Runtime) void {
        self.shutdownExecutor();
        self.cancelSnapshot();
        self.encoded_views.clear(self.allocator);
        if (self.pending_model_intent) |*intent| intent.rollback();
        self.pending_model_intent = null;
        self.task_runtime.deinitTasks(self.taskRuntimeReleaseEffects());
        self.task_runtime.deinitStorage();
        if (self.approval_history_unknown) |bytes| self.allocator.free(bytes);
        self.attachments.deinit();
        for (0..self.workspace.slotCount()) |index| {
            const workspace = self.workspace.factsAt(index) orelse continue;
            std.debug.assert(self.skill.unregisterWorkspace(
                workspace.id,
                self.skillProjectionBudget(),
            ));
        }
        self.workspace.deinit(self.workspaceStorage());
        self.automatic_root_configuration.deinit();
        if (self.automatic_workspace_system_root) |root| self.allocator.free(root);
        self.schedule.deinit();
        self.skill.deinit();
        if (self.canonical_user_home) |home| self.allocator.free(home);
        if (self.mcp) |*mcp| mcp.deinit();
        self.custom_providers.deinit();
        self.execution_state.deinit();
        self.account_projection.deinit();
        std.debug.assert(self.projection_bytes == 0);
        self.executor.deinit();
        self.approval_executor.deinit();
        self.preview_lane.deinit();
        self.preview_executor.deinit();
        self.attachment_lane.deinit();
        self.attachment_executor.deinit();
        if (self.file_change_lane) |lane| lane.deinit();
        if (self.file_change_executor) |executor| executor.deinit();
        self.* = undefined;
    }

    pub fn stopFilePreviewAdmission(self: *Runtime) void {
        self.preview_lane.stopAdmission();
    }

    pub fn shutdownFilePreviewExecutor(self: *Runtime) void {
        if (self.preview_executor_shutdown) return;
        self.preview_lane.stopAdmission();
        self.preview_executor.shutdown();
        self.preview_executor_shutdown = true;
    }

    pub fn shutdownAttachmentStagingExecutor(self: *Runtime) void {
        if (self.attachment_executor_shutdown) return;
        self.attachment_lane.stopAdmission();
        self.attachment_executor.shutdown();
        while (self.attachment_lane.take()) |taken| self.attachment_lane.release(taken);
        if (self.attachment_io) |op| {
            _ = self.attachments.cancelPreparing(op.product_id);
            _ = self.attachments.cancelReceiveChecked(op.product_id) catch {
                std.log.err("attachment cleanup incomplete at shutdown", .{});
            };
            self.attachment_io = null;
        }
        self.attachment_executor_shutdown = true;
    }

    pub fn shutdownFileChangeExecutor(self: *Runtime) void {
        if (self.file_change_executor_shutdown) return;
        if (self.file_change_lane) |lane| lane.stopAdmission();
        if (self.file_change_executor) |executor| executor.shutdown();
        self.file_change_executor_shutdown = true;
    }

    pub fn shutdownExecutor(self: *Runtime) void {
        self.beginShutdown();
        self.shutdownPermissionReviews();
        self.shutdownAttachmentStagingExecutor();
        self.shutdownFilePreviewExecutor();
        self.shutdownFileChangeExecutor();
        self.drainFileChangeCompletions(.{
            .context = self,
            .complete_fn = discardFileChangeDiffCompletion,
        });
        if (self.executor_shutdown) return;
        self.shutting_down = true;
        if (self.attachments.receiving) |receive| _ = self.attachments.cancelReceive(receive.id);
        if (self.mcp) |*runtime| runtime.beginShutdown();
        self.schedule.cancelTimer();
        self.skill.beginShutdown();
        self.task_runtime.prepareShutdown(.{
            .context = self,
            .cancel_fn = cancelTaskRuntimeExecutor,
        }, .{
            .context = self,
            .cancel_fn = cancelApprovalRuntimeExecutor,
        });
        self.executor.shutdown();
        self.approval_executor.shutdown();
        self.executor_shutdown = true;
        // Adopt confirmed history and release approval leases after join,
        // before the final event/checkpoint barrier. No new work is admitted.
        _ = self.syncApprovalChanges();
        self.skill.finishShutdownAfterExecutorJoin(
            self.skillProjectionBudget(),
            catalogSnapshotLimits(self.limits),
        );
        if (self.mcp) |*runtime| runtime.finishShutdownAfterExecutorJoin();
        // The joined Run may have published its terminal and checkpoint only
        // after the last UI-loop drain. Finish the canonical event barrier
        // before settling checkpoint transactions.
        self.drainAgentEvents() catch {};
        self.settleCheckpointTransactionsForShutdown();
        self.task_runtime.excludePendingConversationTailAfterShutdown();
        self.commitTaskStateNoFail();
    }

    /// Records the Application-owned Runtime shutdown fact and permanently
    /// invalidates every remaining Task Session Binding. Application calls
    /// this only after Runtime.shutdown succeeds and the final lifecycle sync.
    pub fn relinquishAgentSessionsAfterRuntimeShutdown(self: *Runtime) void {
        std.debug.assert(self.executor_shutdown);
        self.task_runtime.relinquishSessionsAfterRuntimeShutdown();
    }

    pub fn abandonAgentSessionsForRuntimeDeinit(self: *Runtime) void {
        std.debug.assert(self.executor_shutdown);
        self.task_runtime.abandonSessionsForRuntimeDeinit();
    }

    fn settleCheckpointTransactionsForShutdown(self: *Runtime) void {
        self.task_runtime.settleCheckpointTransactionsForShutdown();
    }

    fn taskViewContainsSensitive(context: *const anyopaque, value: []const u8) bool {
        const self: *const Runtime = @ptrCast(@alignCast(context));
        return self.containsKnownCredential(value);
    }

    fn writeTaskViewJson(
        context: *const anyopaque,
        writer: *std.Io.Writer,
        value: []const u8,
    ) product_task.ProjectionError!void {
        const self: *const Runtime = @ptrCast(@alignCast(context));
        self.projectedJsonValueWithKnownCredentials(writer, value) catch
            return error.SnapshotTooLarge;
    }

    fn writeTaskViewJsonParts(
        context: *const anyopaque,
        writer: *std.Io.Writer,
        first: []const u8,
        second: []const u8,
    ) product_task.ProjectionError!bool {
        const self: *const Runtime = @ptrCast(@alignCast(context));
        const total = std.math.add(usize, first.len, second.len) catch
            return error.SnapshotTooLarge;
        const joined = self.allocator.alloc(u8, total) catch
            return error.OutOfMemory;
        defer {
            std.crypto.secureZero(u8, joined);
            self.allocator.free(joined);
        }
        @memcpy(joined[0..first.len], first);
        @memcpy(joined[first.len..], second);
        const redacted = self.containsKnownCredential(joined);
        self.projectedJsonValueWithKnownCredentials(writer, joined) catch
            return error.SnapshotTooLarge;
        return redacted;
    }

    fn writeTaskViewJsonOutput(
        context: *const anyopaque,
        writer: *std.Io.Writer,
        value: []const u8,
        commentary_ends: []const u64,
    ) product_task.ProjectionError!bool {
        const self: *const Runtime = @ptrCast(@alignCast(context));
        // A clean output already is the sanitized source. Preserve its segment
        // boundaries directly instead of allocating and copying the whole Run.
        if (!self.containsKnownCredential(value)) {
            writer.writeByte('[') catch return error.SnapshotTooLarge;
            var previous: usize = 0;
            for (commentary_ends, 0..) |raw, index| {
                const boundary = std.math.cast(usize, raw) orelse return error.SnapshotTooLarge;
                if (boundary < previous or boundary > value.len or (boundary < value.len and (value[boundary] & 0xc0) == 0x80)) return error.SnapshotTooLarge;
                if (index != 0) writer.writeByte(',') catch return error.SnapshotTooLarge;
                self.projectedJsonValueWithKnownCredentials(writer, value[previous..boundary]) catch return error.SnapshotTooLarge;
                previous = boundary;
            }
            writer.writeAll("],\"response\":") catch return error.SnapshotTooLarge;
            self.projectedJsonValueWithKnownCredentials(writer, value[previous..]) catch return error.SnapshotTooLarge;
            return false;
        }
        const projected = self.allocator.alloc(u8, value.len) catch
            return error.OutOfMemory;
        defer {
            std.crypto.secureZero(u8, projected);
            self.allocator.free(projected);
        }
        const projected_ends = self.allocator.alloc(usize, commentary_ends.len) catch
            return error.OutOfMemory;
        defer self.allocator.free(projected_ends);
        var read: usize = 0;
        var write: usize = 0;
        var boundary_index: usize = 0;
        var redacted = false;
        while (read < value.len) {
            while (boundary_index < commentary_ends.len) {
                const boundary = std.math.cast(usize, commentary_ends[boundary_index]) orelse
                    return error.SnapshotTooLarge;
                if (boundary != read) break;
                projected_ends[boundary_index] = write;
                boundary_index += 1;
            }
            if (self.knownCredentialEndAtCodepoint(value, read)) |redaction_end| {
                const marker_len = @min(redaction_end - read, 3);
                @memset(projected[write..][0..marker_len], '*');
                write += marker_len;
                while (boundary_index < commentary_ends.len) {
                    const boundary = std.math.cast(usize, commentary_ends[boundary_index]) orelse
                        return error.SnapshotTooLarge;
                    if (boundary > redaction_end) break;
                    if (boundary <= read) return error.SnapshotTooLarge;
                    projected_ends[boundary_index] = write;
                    boundary_index += 1;
                }
                read = redaction_end;
                redacted = true;
                continue;
            }
            const codepoint_len = utf8CodepointLen(value, read);
            @memcpy(
                projected[write..][0..codepoint_len],
                value[read..][0..codepoint_len],
            );
            write += codepoint_len;
            read += codepoint_len;
        }
        while (boundary_index < commentary_ends.len) {
            const boundary = std.math.cast(usize, commentary_ends[boundary_index]) orelse
                return error.SnapshotTooLarge;
            if (boundary != read) return error.SnapshotTooLarge;
            projected_ends[boundary_index] = write;
            boundary_index += 1;
        }
        writer.writeByte('[') catch return error.SnapshotTooLarge;
        var previous: usize = 0;
        for (projected_ends, 0..) |boundary, index| {
            if (boundary < previous or boundary > write)
                return error.SnapshotTooLarge;
            if (index != 0) writer.writeByte(',') catch return error.SnapshotTooLarge;
            self.projectedJsonValueWithKnownCredentials(
                writer,
                projected[previous..boundary],
            ) catch return error.SnapshotTooLarge;
            previous = boundary;
        }
        writer.writeAll("],\"response\":") catch return error.SnapshotTooLarge;
        self.projectedJsonValueWithKnownCredentials(
            writer,
            projected[previous..write],
        ) catch return error.SnapshotTooLarge;
        return redacted;
    }

    fn taskTextProjection(self: *const Runtime) product_task.ProjectionText {
        return .{
            .context = self,
            .contains_sensitive_fn = taskViewContainsSensitive,
            .write_json_fn = writeTaskViewJson,
            .write_json_output_fn = writeTaskViewJsonOutput,
            .capture_tool_fn = if (self.capture_view == &self.view_read) captureToolProjection else null,
            .write_json_parts_fn = writeTaskViewJsonParts,
        };
    }

    fn taskProjectionAuthority(
        context: *anyopaque,
        query: task_runtime.ProjectionAuthorityQuery,
    ) task_runtime.ProjectionAuthority {
        const self: *Runtime = @ptrCast(@alignCast(context));
        return self.observeTaskRecoveryAuthority(query);
    }

    fn taskRecoveryAdmissionAuthority(
        context: *anyopaque,
        query: task_runtime.ProjectionAuthorityQuery,
    ) task_runtime.ProjectionAuthority {
        const self: *Runtime = @ptrCast(@alignCast(context));
        return self.observeTaskRecoveryAuthority(query);
    }

    fn observeTaskRecoveryAuthority(
        self: *Runtime,
        query: task_runtime.ProjectionAuthorityQuery,
    ) task_runtime.ProjectionAuthority {
        const workspace = self.workspace.recoveryAuthority(
            query.workspace_id,
            query.workspace_epoch,
            query.workspace_root,
            query.task_id,
        );
        const task = self.task_runtime.findConst(query.task_id);
        const model_rebind_required = self.taskModelNeedsRebind(query.task_id);
        const releasing_route_id: ?u64 = if (task != null and model_rebind_required and task.?.runtime.attachedConst() != null and
            task.?.runtime.attachedConst().?.health == .available)
            task.?.runtime.attachedConst().?.binding.routeId()
        else
            null;
        const execution_available = if (task != null and task.?.durable.model_intent != null) intent: {
            const authority = self.taskModelIntentAuthority(query.task_id) orelse break :intent false;
            break :intent self.custom_providers.sourceModelProtocol(task.?.durable.model_intent.?.modelRef(), authority.source_generation, authority.catalog_generation) != null;
        } else self.modelsDefaultCurrent() and
            self.execution_state.supportsTaskExecution(
                query.execution_protocol,
                query.execution_model,
                self.metaskBindingCurrent(),
                self.custom_providers.metaskModelAvailable(
                    null,
                    query.execution_protocol,
                    query.execution_model,
                ),
            );
        return .{
            .shutting_down = self.shutting_down,
            .task_persistence_ready = self.task_persistence_health.operational(),
            .checkpoint_store_ready = self.checkpoint_store != null and
                self.checkpoint_store_health.load(.acquire) == .ready,
            .execution_admission = if (execution_available) .available else .unavailable,
            .workspace_identity_exact = workspace.identity_exact,
            .automatic_owner_exact = workspace.automatic_owner_exact,
            .runtime_admission = if (self.shutting_down)
                .shutting_down
            else if (self.agent_runtime.restoreAdmissionAvailable(releasing_route_id))
                .available
            else
                .unavailable,
            .authority_stable = !self.shutting_down and
                self.canonical_user_home != null and workspace.exists,
            .model_selection_availability = self.taskModelSelectionAvailability(query),
            .model_rebind_required = model_rebind_required,
        };
    }

    fn taskModelSelectionAvailability(self: *Runtime, query: task_runtime.ProjectionAuthorityQuery) product_task.ModelSelectionAvailability {
        if (self.shutting_down) return .task_unavailable;
        const task = self.task_runtime.findConst(query.task_id) orelse return .task_unavailable;
        if (task.read_only_history != null or task.durable.archived or task.deletion != .idle or task.runtime.close_requested)
            return .task_unavailable;
        const models = self.modelsView();
        if (models.availability != .ready) return .catalog_unavailable;
        for (models.custom_providers) |provider| {
            if (provider.enabled and provider.credential_status == .ready)
                for (provider.models) |model| {
                    if (model.ready) return .available;
                };
        }
        var loading = false;
        for (models.providers) |provider| switch (provider.catalog_state) {
            .ready => {
                if (provider.models.len != 0) return .available;
            },
            .loading, .choosing => loading = true,
            else => {},
        };
        return if (loading) .catalog_loading else .catalog_unavailable;
    }

    fn taskModelNeedsRebind(self: *Runtime, task_id: u64) bool {
        const task = self.task_runtime.findConst(task_id) orelse return false;
        const intent = task.durable.model_intent orelse return false;
        const installed = task.runtime.executionConst() orelse return false;
        if (installed.model_intent_revision == intent.revision) return false;
        const authority = self.taskModelIntentAuthority(task_id) orelse return false;
        const protocol = self.custom_providers.sourceModelProtocol(intent.modelRef(), authority.source_generation, authority.catalog_generation) orelse return false;
        const provider_matches = if (std.mem.eql(u8, intent.source_id, models_contract.metask_source_id))
            std.mem.eql(u8, installed.provider_id, "metask")
        else
            std.mem.startsWith(u8, installed.provider_id, "custom_provider:") and std.mem.eql(u8, installed.provider_id["custom_provider:".len..], intent.source_id);
        return installed.source_generation != authority.source_generation or installed.protocol != protocol or !provider_matches;
    }

    fn taskModelIntentAuthority(self: *Runtime, task_id: u64) ?task_runtime.ModelIntentAuthority {
        const task = self.task_runtime.findConst(task_id) orelse return null;
        const intent = task.durable.model_intent orelse return null;
        // Account identity replacement revokes new Metask credential use.
        // Independent Custom Providers do not inherit that Account gate.
        if (std.mem.eql(u8, intent.source_id, models_contract.metask_source_id) and self.execution_state.identityReplacementPending()) return null;
        const models = self.modelsView();
        for (models.providers) |provider| if (std.mem.eql(u8, provider.id, intent.source_id))
            return .{ .source_id = intent.source_id, .selection_revision = intent.revision, .source_generation = provider.source_generation, .catalog_generation = provider.catalog_generation };
        for (models.custom_providers) |provider| if (std.mem.eql(u8, provider.id, intent.source_id))
            return .{ .source_id = intent.source_id, .selection_revision = intent.revision, .source_generation = provider.source_generation, .catalog_generation = provider.catalog_generation };
        return null;
    }

    fn resolveTaskRunModel(self: *Runtime, task_id: u64) Error!?models_contract.OwnedSourceCandidate {
        const task = self.task_runtime.findConst(task_id) orelse return error.UnknownTask;
        if (task.model_intent_prepared) return error.TaskPersistenceOutcomeUnknown;
        const intent = task.durable.model_intent orelse return null;
        if (task.runtime.executionConst()) |installed|
            if (installed.model_intent_revision == intent.revision) return null;
        const authority = self.taskModelIntentAuthority(task_id) orelse return error.ExecutionUnavailable;
        return (self.custom_providers.resolveModel(intent.modelRef(), authority.source_generation, authority.catalog_generation) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.ExecutionUnavailable,
        }) orelse return error.ExecutionUnavailable;
    }

    fn writeTaskCatalogProjection(
        context: *const anyopaque,
        writer: *std.Io.Writer,
        catalog: CatalogProjection,
    ) product_task.ProjectionError!void {
        const self: *Runtime = @ptrCast(@alignCast(@constCast(context)));
        skill_runtime.Runtime.writeCatalogProjection(
            writer,
            self.skillTextProjection(),
            catalog,
        ) catch return error.SnapshotTooLarge;
    }

    fn taskRuntimeProjectionEffects(self: *Runtime) task_runtime.ProjectionEffects {
        return .{
            .now_ms = self.run_clock.now(),
            .max_pending_inputs_per_task = self.limits.max_pending_inputs_per_task,
            .context = self,
            .authority_fn = taskProjectionAuthority,
            .text = self.taskTextProjection(),
            .catalog = .{
                .context = self,
                .write_fn = writeTaskCatalogProjection,
            },
            .max_pending_ui_json_bytes = self.limits.max_pending_ui_json_bytes,
        };
    }

    fn taskRuntimeRecoveryAdmissionEffects(
        self: *Runtime,
    ) task_runtime.RecoveryAdmissionEffects {
        return .{
            .context = self,
            .authority_fn = taskRecoveryAdmissionAuthority,
        };
    }

    fn skillViewContainsSensitive(
        context: *const anyopaque,
        value: []const u8,
    ) bool {
        const self: *const Runtime = @ptrCast(@alignCast(context));
        return self.containsKnownCredential(value);
    }

    fn writeSkillViewJson(
        context: *const anyopaque,
        writer: *std.Io.Writer,
        value: []const u8,
    ) skill_runtime.ViewError!void {
        const self: *const Runtime = @ptrCast(@alignCast(context));
        self.projectedJsonValueWithKnownCredentials(writer, value) catch
            return error.SnapshotTooLarge;
    }

    fn skillTextProjection(self: *const Runtime) skill_runtime.TextProjection {
        return .{
            .context = self,
            .contains_sensitive_fn = skillViewContainsSensitive,
            .write_json_fn = writeSkillViewJson,
        };
    }

    fn skillWorkspaceCatalog(
        context: *const anyopaque,
        index: usize,
    ) ?skill_runtime.ScopedCatalog {
        const self: *const Runtime = @ptrCast(@alignCast(context));
        const workspace = self.workspace.availableManualBindingAt(index) orelse
            return null;
        return self.skill.scopedWorkspaceCatalog(workspace.id, workspace.epoch);
    }

    fn writeSkillManagement(
        self: *Runtime,
        writer: *std.Io.Writer,
    ) Error!void {
        self.skill.writeManagementProjection(
            writer,
            self.skillTextProjection(),
            .{
                .context = self,
                .slot_count = self.workspace.slotCount(),
                .get_fn = skillWorkspaceCatalog,
            },
            .{ .context = self, .available_fn = skillRetryAvailable },
        ) catch return error.SnapshotTooLarge;
    }

    fn canCreateTask(self: *const Runtime) bool {
        // A new Task allocates an Automatic Workspace id; that is refused while
        // the Skill stores that name ids could not be read, and the admission
        // view says so before any command is sent.
        return !self.shutting_down and self.modelsDefaultCurrent() and
            self.skill.identitySourceTrusted();
    }

    fn cloneCurrentTaskExecution(
        self: *const Runtime,
        allocator: std.mem.Allocator,
    ) std.mem.Allocator.Error!OwnedTaskExecution {
        const input = self.execution_state.executionInput().?;
        return OwnedTaskExecution.clone(
            allocator,
            input,
        );
    }

    fn validNewTaskAdmission(
        self: *const Runtime,
        generation: u64,
        selection_revision: u64,
    ) bool {
        return selection_revision != 0 and
            selection_revision == self.execution_state.activeSelectionRevision() and
            generation != 0 and
            generation == self.execution_state.generation() and
            self.modelsDefaultCurrent();
    }

    fn newTaskModelSelectionAuthorized(
        self: *Runtime,
        selection: NewTaskModelSelectionInput,
    ) bool {
        if (selection.target.source_id.len == 0 or
            selection.target.model_id.len == 0 or
            selection.target.source_id.len > models_contract.Limits.provider_id_bytes or
            selection.target.model_id.len > models_contract.Limits.model_id_bytes or
            selection.expected_source_generation == 0 or
            selection.expected_catalog_generation == 0 or
            !std.unicode.utf8ValidateSlice(selection.target.source_id) or
            !std.unicode.utf8ValidateSlice(selection.target.model_id))
            return false;
        return self.custom_providers.sourceModelProtocol(
            selection.target,
            selection.expected_source_generation,
            selection.expected_catalog_generation,
        ) != null;
    }

    fn validateNewTaskModelAdmission(self: *Runtime, expected_execution_generation: u64, expected_selection_revision: u64, selection: ?NewTaskModelSelectionInput) Error!void {
        if (selection) |explicit| {
            if (!self.newTaskModelSelectionAuthorized(explicit)) return error.ModelSelectionChanged;
        } else {
            if (self.executionReplacementPending()) return error.ExecutionInUse;
            if (!self.canCreateTask()) return error.ExecutionUnavailable;
            if (!self.validNewTaskAdmission(expected_execution_generation, expected_selection_revision))
                return error.ExecutionGenerationMismatch;
        }
    }

    fn modelsDefaultCurrent(self: *const Runtime) bool {
        // Product Control records alignment only after consuming an exact
        // Models authority. Consumer admission and recovery read that local
        // fact; worker threads never call back into the main-thread Models
        // aggregate.
        return self.execution_state.ready() and
            !self.execution_state.replacementPending() and
            self.execution_state.hasRecordedDefaultAuthority() and
            self.execution_state.availabilityError() == .none;
    }

    fn metaskBindingCurrent(self: *const Runtime) bool {
        return self.execution_state.activeSource() == .metask and
            self.modelsDefaultCurrent();
    }

    fn scheduleExecutionBinding(self: *const Runtime) product_schedule.ExecutionBinding {
        return .{
            .available = self.canCreateTask(),
            .model_ref = self.execution_state.activeModelRef(),
            .source_generation = self.execution_state.activeSourceGeneration(),
            .selection_revision = self.execution_state.activeSelectionRevision(),
            .protocol = self.execution_state.protocol(),
            .automatic_workspace_available = self.automaticWorkspacesAvailable(),
        };
    }

    fn scheduleTaskEffects(self: *Runtime) product_schedule.TaskEffects {
        return .{
            .context = self,
            .has_active_fn = scheduleTaskHasActive,
            .launch_fn = scheduleTaskLaunch,
            .observe_fn = scheduleTaskObservation,
        };
    }

    fn scheduleTaskHasActive(context: *anyopaque, task_id: u64) bool {
        const self: *Runtime = @ptrCast(@alignCast(context));
        return self.task_runtime.taskHasActiveOperation(task_id);
    }

    fn scheduleTaskLaunch(
        context: *anyopaque,
        input: product_schedule.TaskLaunch,
    ) product_schedule.TaskLaunchOutcome {
        const self: *Runtime = @ptrCast(@alignCast(context));
        self.validateScheduledBinding(.{
            .model_ref = input.model_ref,
            .source_generation = input.source_generation,
            .selection_revision = input.selection_revision,
            .protocol = input.protocol,
        }) catch |err| return .{ .rejected = .{
            .cause = err,
            .reason = scheduledFailure(err),
            .task_id = 0,
        } };
        var prepared = self.prepareScheduledAdmission(input) catch |err| return .{ .rejected = .{
            .cause = err,
            .reason = scheduledFailure(err),
            .task_id = 0,
        } };
        const task_id = prepared.taskId();
        switch (self.commitPreparedScheduleCandidate()) {
            .committed => {},
            .failed => {
                prepared.rollback();
                return .{ .rejected = .{
                    .cause = error.TaskPersistenceFailed,
                    .reason = .task_start_failed,
                    .task_id = 0,
                } };
            },
            .outcome_unknown => {
                // The canonical replace may already reference this automatic
                // directory. Roll back only the in-memory candidate and
                // preserve the physical root until recovery proves its fate.
                prepared.abandon();
                return .{ .rejected = .{
                    .cause = error.TaskPersistenceOutcomeUnknown,
                    .reason = .task_start_failed,
                    .task_id = 0,
                } };
            },
        }
        _ = prepared.submit() catch |err| {
            self.commitTaskStateNoFail();
            self.bumpRevision();
            return .{ .rejected = .{
                .cause = err,
                .reason = scheduledFailure(err),
                .task_id = task_id,
            } };
        };
        self.bumpRevision();
        return .{ .submitted = task_id };
    }

    fn scheduleTaskObservation(
        context: *anyopaque,
        task_id: u64,
    ) product_schedule.TaskObservation {
        const self: *Runtime = @ptrCast(@alignCast(context));
        if (self.task_runtime.findConst(task_id) == null) return .unavailable;
        const terminal = self.task_runtime.lastTerminalSummary(task_id) orelse
            return .pending;
        return .{ .terminal = .{
            .outcome = scheduledTaskOutcome(terminal.outcome),
            .permission_required = terminal.permission_required,
        } };
    }

    fn scheduleRedaction(self: *Runtime) product_schedule.Redaction {
        return .{
            .context = self,
            .redact_fn = redactScheduleProjection,
            .contains_fn = scheduleProjectionContainsCredential,
        };
    }

    fn redactScheduleProjection(
        context: *anyopaque,
        projection: product_schedule.MutableProjection,
        additional_credential: []const u8,
    ) bool {
        const self: *Runtime = @ptrCast(@alignCast(context));
        var changed = false;
        const current_credential = self.execution_state.credential();
        if (current_credential.len != 0) {
            const title_changed = redactFixedWidthNoFail(
                projection.title,
                current_credential,
            );
            const model_changed = redactFixedWidthNoFail(
                projection.binding_model,
                current_credential,
            );
            const input_changed = redactFixedWidthNoFail(
                projection.input,
                current_credential,
            );
            projection.title_redacted.* =
                projection.title_redacted.* or title_changed;
            projection.input_redacted.* =
                projection.input_redacted.* or input_changed;
            changed = title_changed or model_changed or input_changed;
        }
        const title_changed = self.task_runtime.redactWithExecutionCredentialsNoFail(
            projection.title,
            redactFixedWidthNoFail,
        );
        const model_changed = self.task_runtime.redactWithExecutionCredentialsNoFail(
            projection.binding_model,
            redactFixedWidthNoFail,
        );
        const input_changed = self.task_runtime.redactWithExecutionCredentialsNoFail(
            projection.input,
            redactFixedWidthNoFail,
        );
        projection.title_redacted.* = projection.title_redacted.* or title_changed;
        projection.input_redacted.* = projection.input_redacted.* or input_changed;
        changed = changed or title_changed or model_changed or input_changed;
        if (additional_credential.len != 0) {
            const additional_title_changed = redactFixedWidthNoFail(
                projection.title,
                additional_credential,
            );
            const additional_model_changed = redactFixedWidthNoFail(
                projection.binding_model,
                additional_credential,
            );
            const additional_input_changed = redactFixedWidthNoFail(
                projection.input,
                additional_credential,
            );
            projection.title_redacted.* = projection.title_redacted.* or
                additional_title_changed;
            projection.input_redacted.* = projection.input_redacted.* or
                additional_input_changed;
            changed = changed or additional_title_changed or
                additional_model_changed or additional_input_changed;
        }
        return changed;
    }

    fn scheduleProjectionContainsCredential(
        context: *anyopaque,
        bytes: []const u8,
    ) bool {
        const self: *Runtime = @ptrCast(@alignCast(context));
        return self.containsKnownCredential(bytes);
    }

    fn scheduledTaskDefinition(
        self: *Runtime,
        input: ScheduledTaskDefinitionInput,
    ) Error!product_schedule.Definition {
        try self.validateScheduledBinding(input.binding);
        const title = std.mem.trim(u8, input.title, " \t\r\n");
        if (title.len == 0 or title.len > self.limits.max_task_title_bytes or
            !std.unicode.utf8ValidateSlice(title))
            return error.InvalidTaskTitle;
        for (title) |byte| if (byte < 0x20) return error.InvalidTaskTitle;
        if (!self.workspace.automaticRootAvailable())
            return error.WorkspaceUnavailable;
        try input.recurrence.validate();
        const scheduled_input = std.mem.trim(u8, input.input, " \t\r\n");
        if (scheduled_input.len == 0 or
            scheduled_input.len > self.limits.max_user_message_bytes or
            !std.unicode.utf8ValidateSlice(scheduled_input))
            return error.InvalidScheduledTaskInput;
        return .{
            .title = title,
            .binding = .{
                .model_ref = input.binding.model_ref,
                .source_generation = input.binding.source_generation,
                .selection_revision = input.binding.selection_revision,
                .protocol = input.binding.protocol,
            },
            .permission_profile = scheduledPermissionProfile(
                input.permission_profile,
            ),
            .input = scheduled_input,
            .recurrence = input.recurrence,
        };
    }

    fn validateScheduledBinding(
        self: *Runtime,
        expected: ScheduledTaskBindingInput,
    ) Error!void {
        if (!self.canCreateTask() or expected.source_generation == 0 or
            expected.selection_revision == 0)
            return error.ExecutionUnavailable;
        const authority = self.custom_providers.defaultAuthority() orelse
            return error.ExecutionUnavailable;
        if (!sameModelRef(authority.selection, expected.model_ref) or
            authority.source_generation != expected.source_generation or
            authority.selection_revision != expected.selection_revision or
            authority.protocol != expected.protocol or
            !self.execution_state.defaultAuthorityMatches(authority) or
            !self.custom_providers.defaultResolvable())
            return error.ExecutionGenerationMismatch;
        var candidate = (self.custom_providers.resolveDefault() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.ExecutionUnavailable,
        }) orelse return error.ExecutionUnavailable;
        defer candidate.deinit();
        const resolved = candidate.input();
        if (!std.mem.eql(u8, resolved.target.provider_id, expected.model_ref.source_id) or
            !std.mem.eql(u8, resolved.target.model, expected.model_ref.model_id) or
            resolved.target.protocol != expected.protocol or
            resolved.source_generation != expected.source_generation)
            return error.ExecutionGenerationMismatch;
    }

    fn taskPersistenceLimits(self: *const Runtime) task_persistence.Limits {
        return .{
            .max_workspaces = self.workspace.slotCount(),
            .max_tasks = self.limits.max_tasks,
            .max_runs_per_task = self.limits.max_runs_per_task,
            .max_pending_inputs_per_task = self.limits.max_pending_inputs_per_task,
            .max_compacts_per_task = self.limits.max_compacts_per_task,
            .max_tools_per_run = self.limits.max_tools_per_run,
            .max_commentary_segments_per_run = self.limits.max_commentary_segments_per_run,
            .max_file_refs_per_tool = self.limits.max_file_refs_per_tool,
            .max_file_changes_per_run = self.limits.max_file_changes_per_run,
            .max_ui_history_per_task = self.limits.max_ui_history_per_task,
            .max_workspace_bytes = self.limits.max_workspace_bytes,
            .max_task_title_bytes = self.limits.max_task_title_bytes,
            .max_user_message_bytes = self.limits.max_user_message_bytes,
            .max_attachments_per_run = self.limits.max_attachments_per_draft,
            .max_assistant_message_bytes = self.limits.max_assistant_message_bytes,
            .max_tool_field_bytes = self.limits.max_tool_field_bytes,
            .max_file_ref_field_bytes = self.limits.max_file_ref_field_bytes,
            .max_file_change_field_bytes = self.limits.max_file_change_field_bytes,
            .max_file_change_diff_bytes = self.limits.max_file_change_diff_bytes,
            .max_execution_model_bytes = models_contract.Limits.model_id_bytes,
            .max_terminal_diagnostic_bytes = self.limits.max_terminal_diagnostic_bytes,
        };
    }

    fn taskRestoreProjection(self: *Runtime) task_persistence.RestoreProjection {
        return .{
            .context = self,
            .allocator = self.allocator,
            .limits = self.taskPersistenceLimits(),
            .copy_fn = copyRestoredTaskText,
            .alloc_fn = allocRestoredTaskText,
            .append_text_fn = appendRestoredTaskText,
            .free_fn = freeRestoredTaskText,
            .free_text_fn = freeRestoredTrackedText,
            .reserve_bytes_fn = reserveTaskRuntimeBytes,
            .release_bytes_fn = releaseTaskRuntimeBytes,
        };
    }

    fn copyRestoredTaskText(
        context: *anyopaque,
        value: []const u8,
        max: usize,
    ) task_persistence.ProjectionError![]u8 {
        const self: *Runtime = @ptrCast(@alignCast(context));
        return self.copyBounded(value, max) catch |err| return @errorCast(err);
    }

    fn allocRestoredTaskText(
        context: *anyopaque,
        capacity: usize,
    ) task_persistence.ProjectionError![]u8 {
        const self: *Runtime = @ptrCast(@alignCast(context));
        return self.allocTrackedCapacity(capacity) catch |err| return @errorCast(err);
    }

    fn appendRestoredTaskText(
        context: *anyopaque,
        target: *task_persistence.RestoreText,
        suffix: []const u8,
        max: usize,
    ) task_persistence.ProjectionError!void {
        const self: *Runtime = @ptrCast(@alignCast(context));
        self.appendTrackedText(target, suffix, max) catch |err|
            return @errorCast(err);
    }

    fn freeRestoredTaskText(context: *anyopaque, value: []u8) void {
        const self: *Runtime = @ptrCast(@alignCast(context));
        self.freeTracked(value);
    }

    fn freeRestoredTrackedText(
        context: *anyopaque,
        target: *task_persistence.RestoreText,
    ) void {
        const self: *Runtime = @ptrCast(@alignCast(context));
        self.freeTrackedText(target);
    }

    fn restoreTaskState(self: *Runtime, bytes: []const u8) Error!void {
        std.debug.assert(self.workspace.historyCount() == 0);
        std.debug.assert(self.task_runtime.taskCount() == 0);
        var recovered = try task_persistence.decodeRecovering(
            self.allocator,
            bytes,
            self.taskPersistenceLimits(),
        );
        defer recovered.deinit();
        // Defaults are a preference, not history; an unreadable value falls
        // back instead of discarding every restorable record.
        const default_profile = task_persistence.parseEnum(PermissionProfile, recovered.value.default_permission_profile) orelse profile: {
            recovered.degraded = true;
            break :profile PermissionProfile.approval_required;
        };
        self.default_approval_mode = if (recovered.value.default_approval_mode) |mode|
            task_persistence.parseEnum(ApprovalMode, mode) orelse mode: {
                recovered.degraded = true;
                break :mode ApprovalMode.fromFacts(default_profile, false);
            }
        else
            ApprovalMode.fromFacts(default_profile, false);
        for (recovered.value.failures) |failure|
            try self.recordTaskFailure(failure.task_id, failure.recent_order, failure.reason);
        for (recovered.preserved.retained) |record|
            try self.task_runtime.retainRecord(record);
        for (recovered.value.workspaces, recovered.workspace_frames) |workspace, frame| {
            const skill_root = try self.allocator.dupe(u8, workspace.canonical_root);
            var skill_root_owned = true;
            defer if (skill_root_owned) self.allocator.free(skill_root);
            const kind = task_persistence.parseEnum(WorkspaceKind, workspace.kind) orelse {
                recovered.dropped_workspaces += 1;
                try self.task_runtime.retainRecord(frame);
                continue;
            };
            self.workspace.restore(.{
                .id = workspace.id,
                .epoch = workspace.epoch,
                .kind = kind,
                .canonical_root = workspace.canonical_root,
                .display_name = workspace.display_name,
                .visible = workspace.visible,
                .recent_order = workspace.recent_order,
            }, self.workspaceStorage()) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    recovered.dropped_workspaces += 1;
                    try self.task_runtime.retainRecord(frame);
                    continue;
                },
            };
            const restored = self.workspace.facts(workspace.id) orelse unreachable;
            self.skill.registerWorkspaceOwned(.{
                .id = restored.id,
                .epoch = restored.epoch,
                .catalog_authorized = workspaceSkillCatalogAuthorized(restored),
                .personal_only = restored.kind == .automatic,
                .canonical_root = skill_root,
            }, self.skillProjectionBudget());
            skill_root_owned = false;
        }
        recovered.dropped_tasks += try self.task_runtime.restoreTasks(
            recovered.value.tasks,
            recovered.task_frames,
            recovered.preserved.read_only_tasks,
            self.taskRestoreProjection(),
        );
        for (recovered.value.tasks) |task|
            if (self.task_runtime.taskWorkspaceId(task.id) != null)
                self.workspace.setAutomaticOwnerFromRestore(task.workspace_id, task.id);
        for (0..self.workspace.slotCount()) |index| {
            const workspace = self.workspace.automaticBindingAt(index) orelse continue;
            if (self.task_runtime.taskCountInWorkspace(workspace.id) == 1) continue;
            // The owner Task was retained, so its automatic scope is too.
            for (recovered.value.workspaces, recovered.workspace_frames) |value, frame| {
                if (value.id == workspace.id) {
                    try self.task_runtime.retainRecord(frame);
                    break;
                }
            }
            std.debug.assert(self.skill.unregisterWorkspace(
                workspace.id,
                self.skillProjectionBudget(),
            ));
            self.workspace.removeAt(index, self.workspaceStorage());
            recovered.dropped_workspaces += 1;
        }
        self.workspace.restoreIdentity(
            recovered.value.next_workspace_id,
            recovered.value.next_workspace_recent_order,
        );
        self.task_runtime.restoreIdentityState(
            recovered.value.next_task_id,
            recovered.value.next_task_recent_order,
        );
        if (recovered.degraded or recovered.dropped_workspaces != 0 or recovered.dropped_tasks != 0)
            self.task_persistence_health = .degraded;
    }

    fn recordTaskFailure(
        self: *Runtime,
        task_id: u64,
        recent_order: u64,
        reason: []const u8,
    ) Error!void {
        return self.task_runtime.recordFailure(task_id, recent_order, reason);
    }

    fn reconcileCheckpointStoreNoFail(self: *Runtime) void {
        if (self.task_persistence_health != .ready or
            self.checkpoint_store_health.load(.acquire) != .ready)
            return;
        const store = self.checkpoint_store orelse return;
        self.task_runtime.reconcileCheckpointStoreNoFail(
            store,
            &self.checkpoint_store_health,
            self.taskRuntimeCheckpointEffects(),
        );
    }

    fn cleanupFileChangeStoreNoFail(self: *Runtime) void {
        if (self.task_persistence_health != .ready) return;
        const store = self.file_change_store orelse return;
        self.task_runtime.cleanupFileChangeStoreNoFail(
            store,
            self.limits.max_file_change_diff_bytes,
        );
    }

    fn clearRestoredTaskStateNoFail(self: *Runtime) void {
        // A replacement of history objects can reuse persisted identities and
        // fresh runtime content versions. Ordinary commands never change this.
        self.projection_history_epoch = std.math.add(u64, self.projection_history_epoch, 1) catch 0;
        self.task_runtime.deinitTasks(self.taskRuntimeReleaseEffects());
        for (0..self.workspace.slotCount()) |index| {
            const workspace = self.workspace.factsAt(index) orelse continue;
            std.debug.assert(self.skill.unregisterWorkspace(
                workspace.id,
                self.skillProjectionBudget(),
            ));
        }
        self.workspace.reset(self.workspaceStorage());
        self.task_runtime.clearRetained();
        self.task_runtime.resetIdentity();
    }

    const CheckpointPersistenceOverride = task_persistence.CheckpointPersistenceOverride;

    fn buildTaskStateWire(self: *Runtime) Error!task_persistence.TaskStateWireScratch {
        return self.buildTaskStateWireWithCheckpoint(null);
    }

    fn buildTaskStateWireWithCheckpoint(
        self: *Runtime,
        checkpoint_override: ?CheckpointPersistenceOverride,
    ) Error!task_persistence.TaskStateWireScratch {
        const workspace_count = self.workspace.historyCount();
        const workspaces = try self.allocator.alloc(
            task_persistence.WorkspaceWire,
            workspace_count,
        );
        errdefer self.allocator.free(workspaces);
        var workspace_index: usize = 0;
        for (0..self.workspace.slotCount()) |index| {
            const workspace = self.workspace.historyAt(index) orelse continue;
            workspaces[workspace_index] = .{
                .id = workspace.id,
                .epoch = workspace.epoch,
                .kind = @tagName(workspace.kind),
                .canonical_root = workspace.canonical_root,
                .display_name = workspace.display_name,
                .visible = workspace.visible,
                .recent_order = workspace.recent_order,
            };
            workspace_index += 1;
        }

        const identity = self.workspace.identity();
        const task_frames = try self.task_runtime.projectHistory(checkpoint_override);
        return .{
            .allocator = self.allocator,
            .allocated_workspaces = workspaces,
            .allocated_tasks = task_frames.tasks,
            .allocated_failures = task_frames.failures,
            .allocated_read_only_tasks = task_frames.read_only_tasks,
            .preserved = .{
                .read_only_tasks = task_frames.read_only_tasks,
                .retained = task_frames.retained,
            },
            .state = .{
                .default_permission_profile = @tagName(self.default_approval_mode.profile()),
                .default_approval_mode = @tagName(self.default_approval_mode),
                .next_workspace_id = identity.next_id,
                .next_workspace_recent_order = identity.next_recent_order,
                .next_task_id = task_frames.next_task_id,
                .next_task_recent_order = task_frames.next_recent_order,
                .workspaces = workspaces[0..workspace_index],
                .tasks = task_frames.tasks,
                .failures = task_frames.failures,
            },
        };
    }

    fn projectTaskRuntimeText(
        context: *anyopaque,
        value: []const u8,
        max: usize,
        sensitive: []const []const u8,
        reclaimable: usize,
    ) (std.mem.Allocator.Error || error{ProjectionCapacity})!task_runtime.ProjectedText {
        const self: *Runtime = @ptrCast(@alignCast(context));
        std.debug.assert(reclaimable <= self.projection_bytes);
        self.projection_bytes -= reclaimable;
        const projected = self.copyProjectedSecrets(value, max, sensitive) catch |err|
            return restore: {
                self.projection_bytes += reclaimable;
                break :restore switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => error.ProjectionCapacity,
                };
            };
        return .{
            .value = projected.value,
            .truncated = projected.truncated,
            .redacted = projected.redacted,
        };
    }

    fn freeTaskRuntimeText(context: *anyopaque, value: []u8) void {
        const self: *Runtime = @ptrCast(@alignCast(context));
        self.freeTracked(value);
    }

    fn discardPreviousTaskRuntimeText(context: *anyopaque, value: []u8) void {
        const self: *Runtime = @ptrCast(@alignCast(context));
        self.allocator.free(value);
    }

    fn restorePreviousTaskRuntimeText(context: *anyopaque, bytes: usize) void {
        const self: *Runtime = @ptrCast(@alignCast(context));
        self.projection_bytes += bytes;
    }

    fn allocateTaskRuntimeCapacity(
        context: *anyopaque,
        capacity: usize,
    ) (std.mem.Allocator.Error || error{ProjectionCapacity})![]u8 {
        const self: *Runtime = @ptrCast(@alignCast(context));
        return self.allocTrackedCapacity(capacity) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.ProjectionCapacity,
        };
    }

    fn reserveTaskRuntimeBytes(context: *anyopaque, bytes: usize) error{ProjectionCapacity}!void {
        const self: *Runtime = @ptrCast(@alignCast(context));
        if (bytes > self.limits.max_projection_bytes - self.projection_bytes)
            return error.ProjectionCapacity;
        self.projection_bytes += bytes;
    }

    fn releaseTaskRuntimeBytes(context: *anyopaque, bytes: usize) void {
        const self: *Runtime = @ptrCast(@alignCast(context));
        std.debug.assert(bytes <= self.projection_bytes);
        self.projection_bytes -= bytes;
    }

    fn taskRuntimeTextProjection(self: *Runtime) task_runtime.TextProjection {
        return .{
            .context = self,
            .project_fn = projectTaskRuntimeText,
            .discard_candidate_fn = freeTaskRuntimeText,
            .discard_previous_fn = discardPreviousTaskRuntimeText,
            .restore_previous_fn = restorePreviousTaskRuntimeText,
            .allocate_capacity_fn = allocateTaskRuntimeCapacity,
            .reserve_bytes_fn = reserveTaskRuntimeBytes,
            .release_bytes_fn = releaseTaskRuntimeBytes,
        };
    }

    fn commitTaskRuntimeCandidate(context: *anyopaque) task_runtime.DurableCommit {
        const self: *Runtime = @ptrCast(@alignCast(context));
        self.commitTaskStateIfConfigured() catch |err| return switch (err) {
            error.TaskPersistenceOutcomeUnknown => .outcome_unknown,
            else => .failed,
        };
        return .committed;
    }

    fn commitPreparedScheduleCandidate(self: *Runtime) task_runtime.DurableCommit {
        self.commitTaskState() catch |err| return switch (err) {
            error.TaskPersistenceOutcomeUnknown => .outcome_unknown,
            else => .failed,
        };
        return .committed;
    }

    fn commitTaskRuntimeCheckpoint(
        context: *anyopaque,
        checkpoint_override: ?task_persistence.CheckpointPersistenceOverride,
    ) task_runtime.DurableCommit {
        const self: *Runtime = @ptrCast(@alignCast(context));
        self.commitTaskStateWithCheckpoint(checkpoint_override) catch |err| return switch (err) {
            error.TaskPersistenceOutcomeUnknown => .outcome_unknown,
            else => .failed,
        };
        return .committed;
    }

    fn deleteTaskRuntimeCheckpoint(
        context: *anyopaque,
        identity: checkpoint_store.Identity,
    ) void {
        const self: *Runtime = @ptrCast(@alignCast(context));
        if (self.checkpoint_store) |store| store.delete(identity);
    }

    fn taskRuntimeCheckpointEffects(self: *Runtime) task_runtime.CheckpointEffects {
        return .{
            .context = self,
            .commit_fn = commitTaskRuntimeCheckpoint,
            .delete_fn = deleteTaskRuntimeCheckpoint,
        };
    }

    fn releaseTaskRuntimeSession(
        context: *anyopaque,
        task_id: u64,
    ) task_runtime.SessionReleaseOutcome {
        const self: *Runtime = @ptrCast(@alignCast(context));
        const started = self.task_runtime.beginDetach(
            task_id,
            self.taskRuntimeOperationEffects(),
        ) catch return .failed;
        return if (started) .started else .unchanged;
    }

    fn commitTaskRuntimeWithoutTask(
        context: *anyopaque,
        workspace_id: u64,
    ) task_runtime.DurableCommit {
        const self: *Runtime = @ptrCast(@alignCast(context));
        var removed_workspace = self.workspace.takeAutomatic(workspace_id);
        const outcome = commitTaskRuntimeCandidate(context);
        switch (outcome) {
            .committed => if (removed_workspace) |*removed| {
                std.debug.assert(self.skill.unregisterWorkspace(
                    workspace_id,
                    self.skillProjectionBudget(),
                ));
                self.workspace.commitAutomaticRemoval(
                    removed,
                    self.workspaceStorage(),
                );
            },
            .failed, .outcome_unknown => {
                if (removed_workspace) |*removed|
                    self.workspace.rollbackAutomatic(removed);
            },
        }
        return outcome;
    }

    fn deleteTaskRuntimeCheckpointTask(context: *anyopaque, task_id: u64) void {
        const self: *Runtime = @ptrCast(@alignCast(context));
        if (self.checkpoint_store) |store| store.deleteTask(task_id);
    }

    fn deleteTaskRuntimeFileChanges(context: *anyopaque, task_id: u64) void {
        const self: *Runtime = @ptrCast(@alignCast(context));
        if (self.file_change_store) |store| store.deleteTask(task_id);
    }

    fn deleteTaskRuntimeAttachments(context: *anyopaque, task_id: u64) void {
        const self: *Runtime = @ptrCast(@alignCast(context));
        if (self.attachments.file_store) |store| store.deleteTask(task_id);
    }

    fn taskResourcesQuiescent(context: *anyopaque, task_id: u64, workspace_id: u64) bool {
        const self: *Runtime = @ptrCast(@alignCast(context));
        const workspace = self.workspace.facts(workspace_id) orelse return false;
        return (workspace.kind != .automatic or !self.skill.hasWorkspaceJob(workspace_id)) and
            (if (self.file_change_lane) |lane| !lane.hasTaskJob(task_id) else true);
    }

    fn taskRuntimeDeletionEffects(self: *Runtime) task_runtime.DeletionEffects {
        return .{
            .context = self,
            .release_session_fn = releaseTaskRuntimeSession,
            .commit_without_task_fn = commitTaskRuntimeWithoutTask,
            .resources_quiescent_fn = taskResourcesQuiescent,
            .delete_checkpoint_task_fn = deleteTaskRuntimeCheckpointTask,
            .delete_file_change_task_fn = deleteTaskRuntimeFileChanges,
            .delete_attachment_task_fn = deleteTaskRuntimeAttachments,
            .release = self.taskRuntimeReleaseEffects(),
        };
    }

    fn cancelTaskRuntimeExecutor(context: *anyopaque, identity: *anyopaque) bool {
        const self: *Runtime = @ptrCast(@alignCast(context));
        return self.executor.cancel(identity);
    }

    fn enqueueTaskRuntimeExecutor(
        context: *anyopaque,
        identity: *anyopaque,
        job_context: *anyopaque,
        execute_fn: *const fn (*anyopaque) void,
        cancel_fn: *const fn (*anyopaque) void,
    ) error{ ExecutorShuttingDown, QueueFull }!void {
        const self: *Runtime = @ptrCast(@alignCast(context));
        return self.executor.enqueue(.{
            .identity = identity,
            .context = job_context,
            .execute_fn = execute_fn,
            .cancel_fn = cancel_fn,
        });
    }

    fn applyTaskWorkspaceOrder(context: *anyopaque, recent_order: u64) void {
        const value: *TaskWorkspaceOrderContext = @ptrCast(@alignCast(context));
        std.debug.assert(value.preparation.recentOrder() == recent_order);
        value.workspace.applyOrder(value.preparation);
    }

    fn rollbackTaskWorkspaceOrder(context: *anyopaque, recent_order: u64) void {
        const value: *TaskWorkspaceOrderContext = @ptrCast(@alignCast(context));
        std.debug.assert(value.preparation.recentOrder() == recent_order);
        value.workspace.rollbackOrder(value.preparation);
    }

    fn ignoreTaskWorkspaceOrder(_: *anyopaque, _: u64) void {}

    fn consumeAttachmentBorrow(context: ?*anyopaque) void {
        const acceptance: *AttachmentRunAcceptanceContext = @ptrCast(@alignCast(context.?));
        acceptance.borrow.consume();
        acceptance.external.accept();
    }

    fn taskRuntimeOperationEffects(self: *Runtime) task_runtime.OperationEffects {
        return .{
            .run_clock = self.run_clock,
            .text = self.taskRuntimeTextProjection(),
            .release = self.taskRuntimeReleaseEffects(),
            .executor = .{
                .context = self,
                .enqueue_fn = enqueueTaskRuntimeExecutor,
                .cancel_fn = cancelTaskRuntimeExecutor,
            },
            .worker = .{
                .notifier = .{
                    .context = self.change_notifier.context,
                    .notify_fn = self.change_notifier.wake,
                },
                .completion_factory = .{
                    .context = self.completion_factory.context,
                    .create_fn = self.completion_factory.create_fn,
                },
                .checkpoint = .{
                    .allocator = self.allocator,
                    .io = self.io,
                    .store = self.checkpoint_store,
                    .store_health = &self.checkpoint_store_health,
                    .limits = checkpoint_export_limits,
                },
            },
            .limits = .{
                .max_user_message_bytes = self.limits.max_user_message_bytes,
                .max_pending_inputs_per_task = self.limits.max_pending_inputs_per_task,
                .max_catalog_projection_bytes = self.limits.max_catalog_projection_bytes,
                .max_tool_field_bytes = self.limits.max_tool_field_bytes,
                .max_terminal_diagnostic_bytes = self.limits.max_terminal_diagnostic_bytes,
                .max_tools_per_run = self.limits.max_tools_per_run,
                .max_file_changes_per_run = self.limits.max_file_changes_per_run,
                .max_commentary_segments_per_run = self.limits.max_commentary_segments_per_run,
                .max_skill_arguments = self.limits.max_skill_arguments,
                .max_task_title_bytes = self.limits.max_task_title_bytes,
                .max_model_id_bytes = models_contract.Limits.model_id_bytes,
            },
        };
    }

    fn redactTaskRuntimeProducts(context: *anyopaque, credential: []const u8) void {
        const self: *Runtime = @ptrCast(@alignCast(context));
        self.retireProjectionCredential(credential);
    }

    fn releaseTaskRuntimeProjectionBytes(context: *anyopaque, bytes: usize) void {
        const self: *Runtime = @ptrCast(@alignCast(context));
        std.debug.assert(bytes <= self.projection_bytes);
        self.projection_bytes -= bytes;
    }

    fn taskRuntimeReleaseEffects(self: *Runtime) task_runtime.ReleaseEffects {
        return .{
            .context = self,
            .redact_all_fn = redactTaskRuntimeProducts,
            .release_projection_bytes_fn = releaseTaskRuntimeProjectionBytes,
        };
    }

    fn taskRuntimeRecoveryAuthority(
        context: *anyopaque,
        query: task_runtime.RecoveryAuthorityQuery,
    ) task_runtime.RecoveryExternalAuthority {
        const self: *Runtime = @ptrCast(@alignCast(context));
        const workspace = self.workspace.recoveryAuthority(
            query.workspace_id,
            query.workspace_epoch,
            null,
            query.task_id,
        );
        const model_intent_exact = if (query.model_intent) |authority| exact: {
            const task = self.task_runtime.findConst(query.task_id) orelse break :exact false;
            const intent = task.durable.model_intent orelse break :exact false;
            const current = self.taskModelIntentAuthority(query.task_id) orelse break :exact false;
            if (task.model_intent_prepared or intent.revision != authority.selection_revision or !std.mem.eql(u8, intent.source_id, authority.source_id) or
                !std.mem.eql(u8, intent.model_id, query.task_model) or current.source_generation != authority.source_generation or
                current.catalog_generation != authority.catalog_generation) break :exact false;
            break :exact self.custom_providers.sourceModelProtocol(intent.modelRef(), authority.source_generation, authority.catalog_generation) == query.protocol and
                self.modelRestoreCapabilitiesExact(query.task_id);
        } else if (query.original_restore) self.modelRestoreCapabilitiesExact(query.task_id) else false;
        const execution_exact = if (query.model_intent != null or query.original_restore) model_intent_exact else self.modelsDefaultCurrent() and
            self.execution_state.recoveryAuthorityExact(
                query.target_execution_generation,
                query.protocol,
                query.task_model,
                self.metaskBindingCurrent(),
                // A Task restore consumes Product Control's already-recorded
                // source authority. A later provider catalog refresh must not
                // let Models retroactively veto a consumer-owned binding.
                true,
            );
        return .{
            .workspace_root = workspace.canonical_root,
            .workspace_kind = switch (workspace.kind) {
                .manual => .manual,
                .automatic => .automatic,
            },
            .target_execution_generation = if (query.model_intent != null or query.original_restore) query.target_execution_generation else if (self.execution_state.ready())
                self.execution_state.generation()
            else
                0,
            .shutting_down = self.shutting_down,
            .workspace_authority_exact = workspace.identity_exact,
            .automatic_owner_exact = workspace.automatic_owner_exact,
            .target_execution_authority_exact = execution_exact,
        };
    }

    fn queueTaskRuntimeBinding(context: *anyopaque, task_id: u64) !?task_runtime.DurableCommit {
        const self: *Runtime = @ptrCast(@alignCast(context));
        if (self.task_persistence_health == .unavailable and !self.task_persistence.enabled and !self.task_persistence.restore_failed)
            return .committed;
        if (!self.task_persistence_health.operational()) return .failed;
        if (self.approvalHistoryBlocked()) return error.TaskBusy;
        const bytes = try self.encodeTaskHistoryCandidate(null);
        errdefer self.allocator.free(bytes);
        try self.task_runtime.queueRecoveryHistory(task_id, bytes, self.task_persistence, false, self.approvalExecutor(), self.approvalNotifier());
        self.task_runtime.find(task_id).?.runtime.restore_job.?.binding_commit = .pending;
        return null;
    }

    fn taskRuntimeRecoveryEffects(self: *Runtime) task_runtime.RecoveryEffects {
        return .{
            .context = self,
            .authority_fn = taskRuntimeRecoveryAuthority,
            .queue_binding_fn = queueTaskRuntimeBinding,
            .executor = .{ .context = self, .enqueue_fn = enqueueTaskRuntimeExecutor, .cancel_fn = cancelTaskRuntimeExecutor },
            .refresh_capabilities_fn = refreshModelRestoreCapabilities,
            .retire_checkpoint_fn = retireRecoveryCheckpoint,
        };
    }

    fn retireRecoveryCheckpoint(context: *anyopaque, identity: checkpoint_store.Identity) void {
        const self: *Runtime = @ptrCast(@alignCast(context));
        if (self.shutting_down) return;
        if (self.checkpoint_store) |store|
            self.task_runtime.queueApprovalRetirement(store, identity, self.approvalExecutor(), self.approvalNotifier()) catch {};
    }

    fn commitTaskStateIfConfigured(self: *Runtime) Error!void {
        if (self.task_persistence_health == .unavailable and
            !self.task_persistence.enabled and
            !self.task_persistence.restore_failed)
            return;
        return self.commitTaskState();
    }

    fn commitTaskStateBestEffort(self: *Runtime) Error!void {
        self.commitTaskStateIfConfigured() catch |err| return switch (err) {
            error.TaskBusy => {},
            error.TaskPersistenceOutcomeUnknown,
            error.TaskPersistenceUnavailable,
            error.TaskPersistenceFailed,
            => {},
            else => err,
        };
    }

    fn commitTaskStateNoFail(self: *Runtime) void {
        self.commitTaskStateIfConfigured() catch |err| switch (err) {
            error.TaskBusy => {},
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

    fn markTaskPersistenceWriteFailed(self: *Runtime) void {
        if (self.task_persistence_health == .write_failed) return;
        self.task_persistence_health = .write_failed;
        self.bumpRevision();
    }

    fn commitTaskState(self: *Runtime) Error!void {
        return self.commitTaskStateWithCheckpoint(null);
    }

    fn commitTaskStateWithCheckpoint(
        self: *Runtime,
        checkpoint_override: ?CheckpointPersistenceOverride,
    ) Error!void {
        // During an approval transaction, ordinary lifecycle facts join the
        // existing bounded history writer. Even a gap between its jobs must
        // not turn cancel/terminal reconciliation into synchronous disk I/O.
        for (self.task_runtime.tasks) |entry| if (entry) |task| if (task.approval_change != null) {
            self.approval_history_dirty = true;
            return error.TaskBusy;
        };
        if (self.approvalHistoryBlocked()) {
            self.approval_history_dirty = true;
            return error.TaskBusy;
        }
        switch (self.task_persistence_health) {
            .ready, .degraded, .write_failed, .outcome_unknown => {},
            .read_failed, .corrupt, .unavailable => return error.TaskPersistenceUnavailable,
        }
        var scratch = self.buildTaskStateWireWithCheckpoint(checkpoint_override) catch |err| {
            self.markTaskPersistenceWriteFailed();
            return err;
        };
        defer scratch.deinit();
        const persistence_limits = self.taskPersistenceLimits();
        if (task_persistence.validateCandidate(&scratch.state, persistence_limits)) |failure| {
            if (!builtin.is_test) std.log.err(
                "Task history invariant rejected scope={s} entity_id={d} code={s}",
                .{ @tagName(failure.scope), failure.entity_id, @tagName(failure.code) },
            );
            if (builtin.mode == .Debug and !builtin.is_test)
                std.debug.assert(false);
            self.markTaskPersistenceWriteFailed();
            return error.TaskStoreEncodeFailed;
        }
        const output = self.allocator.alloc(u8, task_persistence.max_store_bytes) catch |err| {
            self.markTaskPersistenceWriteFailed();
            return err;
        };
        defer self.allocator.free(output);
        const bytes = task_persistence.encodePreserving(output, scratch.state, scratch.preserved, persistence_limits) catch |err| {
            self.markTaskPersistenceWriteFailed();
            return err;
        };
        if (self.containsKnownCredential(bytes)) {
            self.markTaskPersistenceWriteFailed();
            return error.TaskStoreEncodeFailed;
        }
        switch (self.task_persistence.commit(bytes)) {
            .committed => {
                self.approval_history_dirty = false;
                if (self.task_persistence_health != .ready) {
                    self.task_persistence_health = .ready;
                    self.bumpRevision();
                }
            },
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

    /// Product projections may contain a credential that became known only
    /// after those facts were recorded. Every Task-owned secret release must
    /// pass through this function so the final live copy scrubs all retained
    /// projections before secure-zero makes the credential unavailable.
    fn prepareAutomaticWorkspace(self: *Runtime) Error!PreparedAutomaticBinding {
        var preparation = self.workspace.prepareAutomatic(
            self.execution_state.credential(),
            self.workspaceStorage(),
            self.skill.identitySourceTrusted(),
        ) catch |err| {
            if (err == error.WorkspaceUnavailable and
                self.workspace.automaticRootAvailable())
            {
                self.workspace.disableAutomaticRoot();
                self.automatic_root_configuration.health = .path_unavailable;
                self.bumpRevision();
            }
            return err;
        };
        errdefer if (preparation.isActive()) {
            _ = self.workspace.rollbackPreparedAutomatic(
                &preparation,
                self.workspaceStorage(),
            );
        };
        const workspace = self.workspace.preparedAutomaticFacts(&preparation);
        const skill_root = try self.allocator.dupe(u8, workspace.canonical_root);
        errdefer self.allocator.free(skill_root);
        self.skill.registerWorkspaceOwned(.{
            .id = workspace.id,
            .epoch = workspace.epoch,
            .catalog_authorized = workspaceSkillCatalogAuthorized(workspace),
            .personal_only = workspace.kind == .automatic,
            .canonical_root = skill_root,
        }, self.skillProjectionBudget());
        return .{ .workspace = preparation };
    }

    fn unregisterPreparedAutomaticSkillNoFail(
        self: *Runtime,
        workspace_id: u64,
    ) void {
        const workspace = self.workspace.facts(workspace_id) orelse unreachable;
        std.debug.assert(workspace.kind == .automatic);
        std.debug.assert(!self.workspaceHasTasks(workspace_id));
        std.debug.assert(!self.skill.hasWorkspaceJob(workspace_id));
        std.debug.assert(self.skill.unregisterWorkspace(
            workspace_id,
            self.skillProjectionBudget(),
        ));
    }

    fn releaseAutomaticWorkspaceNoFail(
        self: *Runtime,
        workspace_id: u64,
    ) void {
        const workspace = self.workspace.facts(workspace_id) orelse unreachable;
        std.debug.assert(workspace.kind == .automatic);
        std.debug.assert(!self.workspaceHasTasks(workspace_id));
        std.debug.assert(!self.skill.hasWorkspaceJob(workspace_id));
        std.debug.assert(self.skill.unregisterWorkspace(
            workspace_id,
            self.skillProjectionBudget(),
        ));
        self.workspace.releaseAutomatic(workspace_id, self.workspaceStorage());
    }
    fn requireSkillMutationAuthority(
        self: *Runtime,
        scope: skill_runtime.ManagementScope,
    ) Error!void {
        self.syncLifecycle();
        return self.checkSkillMutationAuthority(scope);
    }

    fn skillRetryAvailable(context: *const anyopaque, install_id: skill_runtime.InstallId) bool {
        const self: *const Runtime = @ptrCast(@alignCast(context));
        if (!self.skill.retryAvailable(install_id)) return false;
        self.checkSkillMutationAuthority(self.skill.assetScope(install_id) catch return false) catch return false;
        return true;
    }

    fn checkSkillMutationAuthority(self: *const Runtime, scope: skill_runtime.ManagementScope) Error!void {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        switch (scope) {
            .personal => {
                if (self.task_runtime.hasActiveOperation(null)) return error.TaskBusy;
            },
            .project => |project| {
                const workspace = self.workspace.facts(project.workspace_id) orelse
                    return error.UnknownWorkspace;
                if (workspace.epoch != project.workspace_epoch)
                    return error.WorkspaceEpochMismatch;
                if (workspace.kind != .manual or !workspace.visible or
                    workspace.authorization != .available)
                    return error.WorkspaceUnavailable;
                if (self.task_runtime.hasActiveOperation(project.workspace_id))
                    return error.TaskBusy;
            },
        }
    }

    fn requireSkillAssetAuthority(
        self: *Runtime,
        scope: skill_runtime.ManagementScope,
    ) Error!void {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        switch (scope) {
            .personal => if (self.canonical_user_home == null)
                return error.WorkspaceUnavailable,
            .project => |project| {
                const workspace = self.workspace.facts(project.workspace_id) orelse
                    return error.UnknownWorkspace;
                if (workspace.epoch != project.workspace_epoch)
                    return error.WorkspaceEpochMismatch;
                if (workspace.kind != .manual or !workspace.visible or
                    workspace.authorization != .available)
                    return error.WorkspaceUnavailable;
            },
        }
    }

    fn recoverSkillTransactionsForScopeNoFail(
        self: *Runtime,
        scope: skill_runtime.ManagementScope,
    ) void {
        self.checkSkillMutationAuthority(scope) catch return;
        const previous_health = self.skill.managementHealth();
        self.skill.recoverTransactionsForScopeNoFail(
            scope,
            self.schedule.now(),
        );
        self.publishSkillManagementChanges(previous_health);
    }

    fn commitMcpRefreshJobNoFail(self: *Runtime) bool {
        const runtime = if (self.mcp) |*value| value else return false;
        return runtime.syncRefreshJob();
    }

    fn workspaceHasTasks(self: *const Runtime, workspace_id: u64) bool {
        return self.task_runtime.workspaceHasTasks(workspace_id);
    }

    /// Completes the second phase of Workspace removal only after every Task
    /// Session in that Workspace has reached a stable terminal owner state.
    /// A close failure restores admission so the user can retry explicitly.
    fn finalizeWorkspaceRemovalsNoFail(self: *Runtime) bool {
        var changed = false;
        for (0..self.workspace.slotCount()) |index| {
            const workspace = self.workspace.factsAt(index) orelse continue;
            if (!workspace.visible or workspace.authorization != .removing) continue;
            const state: product_workspace.RemovalState = switch (self.task_runtime.workspaceRemovalState(workspace.id)) {
                .close_failed => .close_failed,
                .pending => .pending,
                .ready => .ready,
            };
            if (self.workspace.applyRemovalState(workspace.id, state)) {
                const updated = self.workspace.facts(workspace.id) orelse unreachable;
                self.skill.setWorkspaceCatalogAuthorized(updated.id, updated.epoch, workspaceSkillCatalogAuthorized(updated), self.skillProjectionBudget()) catch unreachable;
                changed = true;
            }
        }
        return changed;
    }

    fn redactWorkspaceProjectionsNoFail(
        self: *Runtime,
        credential: []const u8,
    ) void {
        self.workspace.redactNoFail(credential, self.workspaceStorage());
    }

    fn retainsProjectionCredential(self: *const Runtime, credential: []const u8, releasing: ?[*]const u8) bool {
        if (credential.len == 0) return false;
        const installed = self.execution_state.credential();
        if ((releasing == null or installed.ptr != releasing.?) and std.mem.eql(u8, installed, credential)) return true;
        return self.task_runtime.retainsCredential(credential, releasing);
    }

    fn learnProjectionCredential(self: *Runtime, credential: []const u8) void {
        if (credential.len == 0) return;
        if (!self.retainsProjectionCredential(credential, null)) self.invalidateProjectionSecurity();
        self.redactAllProductProjectionsNoFail(credential);
    }

    fn retireProjectionCredential(self: *Runtime, credential: []const u8) void {
        if (credential.len == 0) return;
        // All aliases into the retiring owner disappear together. Other owned
        // copies of the exact value still protect the same projection boundary.
        if (!self.retainsProjectionCredential(credential, credential.ptr)) self.invalidateProjectionSecurity();
        self.redactAllProductProjectionsNoFail(credential);
    }

    fn invalidateProjectionSecurity(self: *Runtime) void {
        self.cancelSnapshot();
        self.encoded_views.clear(self.allocator);
        if (self.projection_security_epoch != 0)
            self.projection_security_epoch = std.math.add(u64, self.projection_security_epoch, 1) catch 0;
        // Security revocation must be published even if the surrounding command
        // subsequently rejects without a normal product revision or completion.
        _ = self.change_notifier.notify();
    }

    /// Scrubbing is required at every acquisition/release; it is not itself a
    /// change of security authority and must not revoke unrelated UI state.
    fn redactAllProductProjectionsNoFail(self: *Runtime, credential: []const u8) void {
        if (credential.len == 0) return;
        self.redactWorkspaceProjectionsNoFail(credential);
        self.redactCatalogProjectionsNoFail(credential);
        _ = self.schedule.redactInMemoryNoFail(
            credential,
            self.scheduleRedaction(),
        );
        self.task_runtime.redactProjectionsNoFail(credential, .{
            .context = self,
            .redact_fn = redactFixedWidthNoFail,
            .release_projection_bytes_fn = releaseTaskRuntimeProjectionBytes,
        });
    }

    fn redactCatalogProjectionsNoFail(
        self: *Runtime,
        credential: []const u8,
    ) void {
        self.skill.redactCatalogsNoFail(
            credential,
            self.skillProjectionBudget(),
        );
    }

    fn checkpointMutationPending(
        self: *const Runtime,
        task: *const TestTask,
    ) bool {
        return self.checkpoint_store_health.load(.acquire) != .unavailable and
            task.runtime.worker_leases.hasLive();
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
            "请分析 AgentCore Conversation 生命周期以及它和 Runtime 的边界并给出迁移建议",
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
        var control = try testRuntime();
        defer control.deinit();

        const remaining = control.limits.max_projection_bytes - control.projection_bytes;
        const reservation = try control.allocTrackedCapacity(remaining);
        defer control.freeTracked(reservation);

        const task = &control.task_runtime.tasks[0].?;
        const run = &task.durable.runs[0].?;
        run.automatic_title.state.store(.ready, .release);
        const sync = control.task_runtime.syncAutomaticTitles(
            control.limits.max_task_title_bytes,
            control.taskRuntimeTextProjection(),
        );
        try std.testing.expect(!sync.durable_changed);
        try std.testing.expectEqualStrings("", task.durable.title);
    }

    test "automatic title settlement never overwrites a user title" {
        var control = try testRuntime();
        defer control.deinit();

        const task = &control.task_runtime.tasks[0].?;
        const run = &task.durable.runs[0].?;
        try control.replaceTracked(
            &task.durable.title,
            "Provisional title",
            control.limits.max_task_title_bytes,
        );
        run.automatic_title.provisional_applied = true;
        run.automatic_title.state.store(.pending, .release);
        try control.renameTask(task.durable.id, "User title");
        const generated = "Generated title";
        @memcpy(run.automatic_title.result[0..generated.len], generated);
        run.automatic_title.result_len = generated.len;
        run.automatic_title.generated = true;
        run.automatic_title.state.store(.ready, .release);

        const sync = control.task_runtime.syncAutomaticTitles(
            control.limits.max_task_title_bytes,
            control.taskRuntimeTextProjection(),
        );
        try std.testing.expect(!sync.durable_changed);
        try std.testing.expectEqualStrings("User title", task.durable.title);
        try std.testing.expect(run.automatic_title.user_overrode);
        try std.testing.expectEqual(
            AutomaticTitleState.settled,
            run.automatic_title.state.load(.acquire),
        );
    }

    fn reserveRunRecord(
        self: *Runtime,
        task: *TestTask,
        input: TaskRunInput,
    ) Error!usize {
        const runtime_input: task_runtime.RunInput = switch (input) {
            .text => |text| .{ .text = text },
            .skill => |skill| .{ .skill = .{
                .skill_id = skill.skill_id,
                .catalog_revision = skill.catalog_revision,
                .selection_revision = skill.selection_revision,
                .argument_values = skill.argument_values,
            } },
            .multimodal => return error.InvalidRunInput,
        };
        return self.task_runtime.testReserveRun(
            task.durable.id,
            runtime_input,
            self.taskRuntimeOperationEffects(),
        );
    }

    fn discardRunRecord(self: *Runtime, task: *TestTask, slot: usize) void {
        self.task_runtime.testDiscardRun(
            task.durable.id,
            slot,
            self.taskRuntimeReleaseEffects(),
        );
    }

    fn reserveCompactRecord(
        self: *Runtime,
        task: *TestTask,
        operation_id: u64,
        after_run_id: u64,
    ) Error!usize {
        return self.task_runtime.testReserveCompact(
            task.durable.id,
            operation_id,
            after_run_id,
            self.taskRuntimeOperationEffects(),
        );
    }

    fn discardCompactRecord(self: *Runtime, task: *TestTask, slot: usize) void {
        self.task_runtime.testDiscardCompact(
            task.durable.id,
            slot,
            self.taskRuntimeReleaseEffects(),
        );
    }

    fn releaseTaskAttachmentNoFail(
        self: *Runtime,
        task: *TestTask,
        cause: task_test_attachment.DetachmentCause,
    ) void {
        self.task_runtime.testReleaseAttachment(
            task.durable.id,
            cause,
            self.taskRuntimeReleaseEffects(),
        );
    }

    fn copyBounded(self: *Runtime, value: []const u8, max: usize) Error![]u8 {
        if (value.len > max or value.len > self.limits.max_projection_bytes - self.projection_bytes)
            return error.ProjectionCapacity;
        const result = try self.allocator.dupe(u8, value);
        self.projection_bytes += result.len;
        return result;
    }

    fn copyPreviewBounded(self: *Runtime, value: []const u8, max: usize) Error![]u8 {
        if (value.len > max) return error.ProjectionCapacity;
        return self.allocator.dupe(u8, value);
    }

    fn allocTrackedCapacity(self: *Runtime, capacity: usize) Error![]u8 {
        if (capacity > self.limits.max_projection_bytes - self.projection_bytes)
            return error.ProjectionCapacity;
        const result = try self.allocator.alloc(u8, capacity);
        self.projection_bytes += result.len;
        return result;
    }

    fn appendTrackedText(self: *Runtime, target: *task_persistence.RestoreText, suffix: []const u8, max: usize) Error!void {
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
        self: *Runtime,
        value: []const u8,
        max: usize,
        credential: []const u8,
    ) Error!ProjectedCopy {
        return self.copyProjectedSecrets(value, max, &.{credential});
    }

    fn copyProjectedSecrets(
        self: *Runtime,
        value: []const u8,
        max: usize,
        credentials: []const []const u8,
    ) Error!ProjectedCopy {
        const capacity = @min(value.len, max);
        const scratch = try self.allocator.alloc(u8, capacity);
        defer self.allocator.free(scratch);
        const result = sanitizeInto(
            scratch,
            value,
            credentials,
        );
        return .{
            .value = try self.copyBounded(scratch[0..result.len], max),
            .truncated = result.truncated,
            .redacted = result.redacted,
        };
    }

    fn replaceTrackedProjected(
        self: *Runtime,
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
            &.{credential},
        );
        try self.replaceTracked(target, scratch[0..result.len], max);
        return result;
    }

    fn redactTrackedText(
        _: *Runtime,
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

    fn projectedJsonValue(self: *Runtime, writer: *std.Io.Writer, value: []const u8) Error!void {
        return self.projectedJsonValueWithKnownCredentials(writer, value);
    }

    fn containsKnownCredential(self: *const Runtime, value: []const u8) bool {
        if (self.view_credentials) |credentials| {
            for (credentials) |known| if (std.mem.indexOf(u8, value, known) != null) return true;
            return false;
        }
        const current = self.execution_state.credential();
        if (containsKnownSecret(value, current)) return true;
        return self.task_runtime.containsExecutionCredential(value);
    }

    fn redactWithKnownCredentialsNoFail(
        self: *const Runtime,
        value: []u8,
    ) bool {
        var changed = redactFixedWidthNoFail(
            value,
            self.execution_state.credential(),
        );
        changed = self.task_runtime.redactWithExecutionCredentialsNoFail(
            value,
            redactFixedWidthNoFail,
        ) or changed;
        return changed;
    }

    fn matchedKnownCredentialLen(
        self: *const Runtime,
        value: []const u8,
    ) usize {
        var longest: usize = 0;
        if (self.view_credentials) |credentials| {
            for (credentials) |known| if (known.len > longest and std.mem.startsWith(u8, value, known)) {
                longest = known.len;
            };
            return longest;
        }
        const current = self.execution_state.credential();
        if (current.len != 0 and std.mem.startsWith(u8, value, current))
            longest = current.len;
        longest = @max(longest, self.task_runtime.matchedExecutionCredentialPrefix(value));
        return longest;
    }

    fn projectedJsonValueWithKnownCredentials(
        self: *const Runtime,
        writer: *std.Io.Writer,
        value: []const u8,
    ) Error!void {
        if (self.capture_view) |plan| {
            const start = plan.text.items.len;
            const contains = for (self.view_credentials.?) |known| {
                if (std.mem.indexOf(u8, value, known) != null) break true;
            } else false;
            if (!contains) try plan.appendText(self.allocator, self.limits.max_snapshot_bytes, value) else {
                var index: usize = 0;
                var copied: usize = 0;
                while (index < value.len) {
                    if (self.knownCredentialEndAtCodepoint(value, index)) |end| {
                        try plan.appendText(self.allocator, self.limits.max_snapshot_bytes, value[copied..index]);
                        try plan.appendText(self.allocator, self.limits.max_snapshot_bytes, "***"[0..@min(end - index, 3)]);
                        index = end;
                        copied = end;
                    } else index += utf8CodepointLen(value, index);
                }
                try plan.appendText(self.allocator, self.limits.max_snapshot_bytes, value[copied..]);
            }
            try plan.commitString(self.allocator, writer, start);
            return;
        }
        if (self.view_credentials) |credentials| {
            const contains = for (credentials) |known| {
                if (std.mem.indexOf(u8, value, known) != null) break true;
            } else false;
            if (!contains) {
                std.json.Stringify.value(value, .{}, writer) catch return error.SnapshotTooLarge;
                return;
            }
        }
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
        self: *const Runtime,
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
        _: *Runtime,
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
        self: *Runtime,
        access: *task_test_agent_session.Access,
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
        self: *Runtime,
        access: *task_test_agent_session.Access,
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
        _: *Runtime,
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
            &.{credential},
        );
        record.detail_len = result.len;
        record.detail_truncated = result.truncated;
        record.redacted = result.redacted;
    }

    fn pushUiRecord(_: *Runtime, view: *TestTask, record: UiRecord) void {
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

    fn freeTrackedText(self: *Runtime, target: *task_persistence.RestoreText) void {
        self.projection_bytes -= target.list.capacity;
        target.list.deinit(self.allocator);
        target.* = undefined;
    }

    fn replaceTracked(self: *Runtime, target: *[]u8, value: []const u8, max: usize) Error!void {
        if (value.len > max or value.len > self.limits.max_projection_bytes - (self.projection_bytes - target.len))
            return error.ProjectionCapacity;
        const next = try self.allocator.dupe(u8, value);
        self.projection_bytes = self.projection_bytes - target.len + next.len;
        self.allocator.free(target.*);
        target.* = next;
    }

    fn freeTracked(self: *Runtime, value: []u8) void {
        self.projection_bytes -= value.len;
        self.allocator.free(value);
    }

    pub fn accountCommitSink(self: *Runtime) control_ports.AccountCommitSink {
        return .{
            .context = self,
            .commit_fn = controlCommitAccountChange,
        };
    }

    pub fn setImageRunPreparation(self: *Runtime, preparation: ?control_ports.ImageRunPreparation) void {
        self.image_run_preparation = preparation;
    }

    fn prepareRunImage(self: *Runtime, workspace: product_workspace.TaskAuthority) ?product_task.OwnedImageExecution {
        const preparation = self.image_run_preparation orelse return null;
        const image = preparation.prepare(workspace) orelse return null;
        // Scrub facts written before this newly acquired credential was known.
        self.learnProjectionCredential(image.candidate.input().bearer);
        return image;
    }

    pub fn modelsManagement(self: *Runtime) control_ports.ModelsManagement {
        return .{
            .context = self,
            .prepare_image_candidate_fn = controlPrepareImageCandidate,
            .start_custom_providers_fn = controlStartCustomProviders,
            .start_custom_providers_unavailable_fn = controlStartCustomProvidersUnavailable,
            .stop_custom_providers_fn = controlStopCustomProviders,
            .reset_model_store_fn = controlResetModelStore,
            .create_custom_provider_fn = controlCreateCustomProvider,
            .create_builtin_provider_fn = controlCreateBuiltinProvider,
            .update_builtin_provider_base_url_fn = controlUpdateBuiltinProviderBaseUrl,
            .replace_custom_provider_credential_fn = controlReplaceCustomProviderCredential,
            .submit_custom_provider_fn = controlSubmitCustomProvider,
            .begin_custom_provider_probe_fn = controlBeginCustomProviderProbe,
            .complete_custom_model_test_fn = controlCompleteCustomModelTest,
            .prepare_metask_catalog_refresh_fn = controlPrepareMetaskCatalogRefresh,
            .complete_metask_catalog_refresh_fn = controlCompleteMetaskCatalogRefresh,
            .fail_metask_catalog_refresh_fn = controlFailMetaskCatalogRefresh,
            .metask_authorization_unavailable_fn = controlMetaskAuthorizationUnavailable,
        };
    }

    pub fn agentEventConsumer(self: *Runtime) control_ports.AgentEventConsumer {
        return .{ .context = self, .drain_fn = controlDrainAgentEvents };
    }

    pub fn mcpManagementPort(self: *Runtime) control_ports.McpManagementPort {
        return .{
            .context = self,
            .inspect_fn = controlMcpInspect,
            .write_desired_fn = controlMcpWriteDesired,
            .begin_connection_test_fn = controlMcpBeginConnectionTest,
            .complete_connection_test_fn = controlMcpCompleteConnectionTest,
            .begin_apply_fn = controlMcpBeginApply,
            .complete_apply_fn = controlMcpCompleteApply,
            .fail_apply_fn = controlMcpFailApply,
            .authorization_operation_fn = controlMcpAuthorizationOperation,
            .begin_authorization_fn = controlMcpBeginAuthorization,
            .advance_authorization_fn = controlMcpAdvanceAuthorization,
            .finish_authorization_fn = controlMcpFinishAuthorization,
            .write_approval_fn = controlMcpWriteApproval,
            .approve_connection_fn = controlMcpApproveConnection,
            .validate_secret_capture_fn = controlMcpValidateSecretCapture,
            .capture_static_secret_fn = controlMcpCaptureStaticSecret,
            .capture_oauth_client_secret_fn = controlMcpCaptureOauthClientSecret,
            .begin_dynamic_registration_fn = controlMcpBeginDynamicRegistration,
            .complete_dynamic_registration_fn = controlMcpCompleteDynamicRegistration,
            .begin_code_exchange_fn = controlMcpBeginCodeExchange,
            .complete_code_exchange_fn = controlMcpCompleteCodeExchange,
            .authorize_oauth_fn = controlMcpAuthorizeOauth,
            .clear_oauth_operation_fn = controlMcpClearOauthOperation,
            .recover_oauth_operation_fn = controlMcpRecoverOauthOperation,
        };
    }

    pub fn mcpOauthPort(self: *Runtime) control_ports.McpOauthPort {
        return .{
            .context = self,
            .next_expiry_fn = controlMcpNextOauthExpiry,
            .begin_refresh_fn = controlMcpBeginOauthRefresh,
            .complete_refresh_fn = controlMcpCompleteOauthRefresh,
            .require_reauthorization_fn = controlMcpRequireReauthorization,
            .clear_operation_fn = controlMcpClearOauthOperation,
            .recover_operation_fn = controlMcpRecoverOauthOperation,
        };
    }

    pub fn scheduleHost(self: *Runtime) control_ports.ScheduleHost {
        return .{
            .context = self,
            .set_background_available_fn = controlSetScheduleBackgroundAvailable,
        };
    }

    fn publishScheduleChangesNoFail(self: *Runtime) void {
        if (self.schedule.takeChanged()) self.bumpRevision();
    }

    fn bumpRevision(self: *Runtime) void {
        self.encoded_views.invalidateAll();
        if (self.view_read.id != 0) for (&self.view_preparation.blocks) |*block| {
            block.current = false;
        };
        if (self.revision != std.math.maxInt(u64)) self.revision += 1;
    }

    pub fn projectionSecurityEpoch(self: *const Runtime) u64 {
        return self.projection_security_epoch;
    }
};

pub const TestSupport = if (builtin.is_test) struct {
    pub const maximumFixture = maximumProjectionFixture;
    pub fn maximumToolFixture() !Runtime {
        return maximumProjectionFixtureWithTools(true, .{});
    }
    pub fn maximumSmallFixture() !Runtime {
        return maximumProjectionFixtureWithTools(true, .{ .max_tasks = 1, .max_runs_per_task = 1 });
    }
    pub fn installResultFixture(control: *Runtime, sparse: bool) !void {
        const first = &control.task_runtime.tasks[0].?.durable.runs[0].?;
        control.projection_bytes -= first.assistant.list.capacity;
        first.assistant.list.deinit(control.allocator);
        first.assistant = .{};
        first.commentary_count = 0;
        try control.replaceTracked(&first.tools[0].?.content, "", control.limits.max_tool_field_bytes);
        const stdout = try control.allocator.alloc(u8, if (sparse) 65_000 else 640);
        defer control.allocator.free(stdout);
        @memset(stdout, '\n');
        const result = try std.json.Stringify.valueAlloc(control.allocator, .{
            .schema_version = "metacodes.bash-result.v2",
            .stdout = stdout,
            .stdout_encoding = "utf-8",
            .stdout_capture_complete = true,
            .stdout_truncated = false,
            .stderr = "",
            .stderr_encoding = "utf-8",
            .stderr_capture_complete = true,
            .stderr_truncated = false,
            .exit_code = @as(i32, 0),
        }, .{});
        defer control.allocator.free(result);
        const large_input = if (sparse) try std.json.Stringify.valueAlloc(control.allocator, .{ .command = stdout }, .{}) else null;
        defer if (large_input) |value| control.allocator.free(value);
        for (control.task_runtime.tasks[0].?.durable.runs) |*entry| if (entry.*) |*run| {
            if (!sparse and run.id > 4 and run.id < 13) continue;
            for (run.tools, 0..) |*tool_entry, index| {
                if (sparse and index >= 5) break;
                if (tool_entry.*) |*tool| {
                    try control.replaceTracked(&tool.content, result, control.limits.max_tool_field_bytes);
                    if (large_input) |value| {
                        try control.replaceTracked(&tool.input, value, control.limits.max_tool_field_bytes);
                        tool.state = .failed;
                        tool.is_error = true;
                    }
                }
            }
        };
        const remaining = control.limits.max_projection_bytes - control.projection_bytes;
        const padding = try control.allocator.alloc(u8, remaining);
        defer control.allocator.free(padding);
        @memset(padding, 1);
        // Fill the shared budget while respecting each individual field cap.
        const assistant_bytes = @min(remaining, control.limits.max_assistant_message_bytes);
        first.assistant.list = .{ .items = try control.allocTrackedCapacity(assistant_bytes), .capacity = assistant_bytes };
        @memcpy(first.assistant.list.items, padding[0..assistant_bytes]);
        first.assistant.committed_len = assistant_bytes;
        first.commentary_count = @intFromBool(assistant_bytes != 0);
        if (assistant_bytes != 0) first.commentary_ends[0] = assistant_bytes;
        if (remaining > assistant_bytes) try control.replaceTracked(&first.tools[0].?.progress, padding[assistant_bytes..], control.limits.max_tool_field_bytes);
        try std.testing.expectEqual(control.limits.max_projection_bytes, control.projection_bytes);
    }
    pub fn validatePersistedFixture(control: *Runtime) !void {
        var state = try control.buildTaskStateWire();
        defer state.deinit();
        const output = try control.allocator.alloc(u8, task_persistence.max_store_bytes);
        defer control.allocator.free(output);
        _ = try task_persistence.encode(output, state.state, control.taskPersistenceLimits());
    }
    pub fn writeViewFixture(self: *Runtime, output: []u8, request: ViewRequest) ![]const u8 {
        var read = try self.writeSnapshot(output, request);
        while (read.bytes == 0) read = try self.continueSnapshot(read.id, output);
        var offset: usize = 0;
        while (offset < read.bytes) : (offset += projection_step_bytes) try self.writeSnapshotRange(read.id, output, offset, @min(projection_step_bytes, read.bytes - offset));
        return output[0..read.bytes];
    }
    pub fn writeAggregateFixture(self: *Runtime, output: []u8) Error![]const u8 {
        var writer = std.Io.Writer.fixed(output);
        try self.writeLiveContextFields(&writer, true);
        writer.writeAll(",\"skillManagement\":") catch
            return error.SnapshotTooLarge;
        try self.writeSkillManagement(&writer);
        writer.writeAll(",\"mcp\":") catch return error.SnapshotTooLarge;
        try self.writeMcpProjection(&writer);
        writer.writeAll(",\"workspaces\":") catch return error.SnapshotTooLarge;
        product_workspace.writeProjectionList(
            &writer,
            &self.workspace,
            self.workspaceViewProvider(),
        ) catch return error.SnapshotTooLarge;
        writer.writeAll(",\"scheduledTasks\":") catch return error.SnapshotTooLarge;
        self.schedule.writeProjection(&writer, .{
            .context = self,
            .write_json_fn = Runtime.writeScheduleViewJson,
        }) catch return error.SnapshotTooLarge;
        writer.writeAll(",\"tasks\":[") catch
            return error.SnapshotTooLarge;
        self.task_runtime.writeProjectionList(
            &writer,
            self.taskRuntimeProjectionEffects(),
        ) catch |err| return @errorCast(err);
        writer.writeAll("]}") catch return error.SnapshotTooLarge;
        return writer.buffered();
    }

    pub fn retryTaskSessionClose(control: *Runtime, task_id: u64) !bool {
        return control.task_runtime.beginDetach(task_id, control.taskRuntimeOperationEffects());
    }

    /// Exercises the writer while a test deliberately holds lifecycle reconciliation.
    pub fn commitTaskHistory(control: *Runtime) Error!void {
        return control.commitTaskStateIfConfigured();
    }

    pub fn taskPermissionReviewText(control: *Runtime) task_runtime.TextProjection {
        return control.taskRuntimeTextProjection();
    }

    pub fn scheduledBinding(control: *Runtime) ScheduledTaskBindingInput {
        const authority = control.custom_providers.defaultAuthority() orelse
            unreachable;
        return .{
            .model_ref = authority.selection,
            .source_generation = authority.source_generation,
            .selection_revision = authority.selection_revision,
            .protocol = authority.protocol,
        };
    }

    pub fn replaceMetaskCatalog(
        control: *Runtime,
        models: []const models_contract.ModelView,
        selected_model: []const u8,
    ) !void {
        const current = control.modelsView();
        const provider = if (current.providers.len == 0) null else current.providers[0];
        const source_generation = if (provider) |value|
            if (value.source_generation == 0) control.executionGeneration() else value.source_generation
        else
            control.executionGeneration();
        const metask_revision = if (current.metask_selection_revision == std.math.maxInt(u64))
            return error.InvalidExecutionGeneration
        else
            current.metask_selection_revision + 1;
        const default_revision = if (current.selection_revision == std.math.maxInt(u64))
            return error.InvalidExecutionGeneration
        else
            current.selection_revision + 1;
        const catalog_generation = if (provider) |value|
            if (value.catalog_generation == std.math.maxInt(u64))
                return error.InvalidExecutionGeneration
            else
                value.catalog_generation + 1
        else
            1;
        try models_aggregate.TestSupport.installMetaskDefault(
            &control.custom_providers,
            "account-1",
            "fixture-secret",
            models,
            selected_model,
            source_generation,
            metask_revision,
            default_revision,
            catalog_generation,
        );
        control.execution_state.recordDefaultAuthorityNoFail(
            control.custom_providers.defaultAuthority().?,
        );
        control.finishExecutionCommitNoFail();
    }

    pub fn installMetaskExecution(control: *Runtime, generation: u64) !void {
        return installMetaskExecutionWithCredential(control, generation, "SECRET-KEY");
    }

    pub fn installMetaskExecutionWithCredential(
        control: *Runtime,
        generation: u64,
        credential: []const u8,
    ) !void {
        if (generation == 0 or generation > std.math.maxInt(u64) - 3)
            return error.InvalidExecutionGeneration;
        try prepareMetaskDefault(control, generation);
        var execution = try models_contract.OwnedConfig.initOwned(
            std.testing.allocator,
            .metask,
            .anthropic_messages,
            try std.testing.allocator.dupe(u8, "fixture-model"),
            try std.testing.allocator.dupe(
                u8,
                models_contract.metask_anthropic_messages_url,
            ),
            generation,
            try std.testing.allocator.dupe(u8, credential),
            "",
        );
        errdefer execution.deinit();
        var source = (try control.custom_providers.resolveDefault()).?;
        defer source.deinit();
        execution.image_capabilities = source.image_capabilities.take();
        try control.beginExecutionReplacement();
        errdefer control.endExecutionReplacementNoFail();
        try control.prepareExecutionInstall(execution.input());
        control.installExecutionNoFail(&execution);
        control.execution_state.recordDefaultAuthorityNoFail(
            control.custom_providers.defaultAuthority().?,
        );
        control.endExecutionReplacementNoFail();
        control.finishExecutionCommitNoFail();
    }

    pub fn prepareMetaskDefault(control: *Runtime, generation: u64) !void {
        if (generation == 0 or generation > std.math.maxInt(u64) - 3)
            return error.InvalidExecutionGeneration;
        const models = [_]models_contract.ModelView{.{
            .id = "fixture-model",
            .display_name = "Fixture model",
            .metadata = .{
                .max_input_tokens = 1_048_576,
                .max_output_tokens = 64_000,
                .capabilities = .{
                    .image_input = false,
                    .pdf_input = false,
                    .batch = false,
                    .citations = false,
                    .code_execution = false,
                    .structured_outputs = true,
                    .thinking = .{
                        .supported = true,
                        .adaptive = false,
                        .enabled = true,
                    },
                    .effort = .{
                        .supported = false,
                        .low = false,
                        .medium = false,
                        .high = false,
                        .max = false,
                    },
                    .context_management = .{
                        .supported = true,
                        .clear_thinking_20251015 = false,
                        .clear_tool_uses_20250919 = false,
                        .compact_20260112 = true,
                    },
                },
            },
        }};
        try models_aggregate.TestSupport.installMetaskDefault(
            &control.custom_providers,
            "account-1",
            "fixture-secret",
            &models,
            "fixture-model",
            generation,
            generation + 1,
            generation + 2,
            generation + 3,
        );
        control.commitAccountFactNoFail(.{
            .kind = .session_changed,
            .view = .{
                .state = .authenticated,
                .account_id = "account-1",
                .display_name = "Fixture User",
                .email_hint = "f***@example.com",
                .phone_hint = "138****8000",
                .concurrency_limit = 5,
            },
        });
    }
} else struct {};

fn controlOwner(context: *anyopaque) *Runtime {
    return @ptrCast(@alignCast(context));
}

fn controlCommitAccountChange(
    context: *anyopaque,
    commit: control_ports.AccountCommit,
) void {
    controlOwner(context).commitAccountChangeNoFail(commit);
}
fn controlStartCustomProviders(context: *anyopaque, directory: []const u8, vault: models_ports.CredentialVault) anyerror!void {
    try controlOwner(context).startCustomProviders(directory, vault);
}
fn controlStartCustomProvidersUnavailable(context: *anyopaque) void {
    controlOwner(context).startCustomProvidersUnavailable();
}
fn controlStopCustomProviders(context: *anyopaque) void {
    controlOwner(context).stopCustomProviders();
}
fn controlResetModelStore(context: *anyopaque, expected_revision: u64) models_contract.CommandResult {
    return controlOwner(context).resetModelsStore(expected_revision);
}
fn controlPrepareImageCandidate(context: *anyopaque, input: models_contract.ImagePreparationInput) models_contract.ImagePreparation {
    return controlOwner(context).custom_providers.prepareImageCandidate(input);
}
fn controlCreateCustomProvider(context: *anyopaque, secret: []const u8, spec: models_contract.CustomProviderSpec) models_contract.CommandResult {
    return controlOwner(context).createCustomProviderWithCredential(secret, spec);
}
fn controlCreateBuiltinProvider(context: *anyopaque, secret: []const u8, provider_id: models_contract.BuiltinProviderId, base_url: []const u8) models_contract.CommandResult {
    return controlOwner(context).createBuiltinProviderWithCredential(secret, provider_id, base_url);
}
fn controlUpdateBuiltinProviderBaseUrl(context: *anyopaque, selection: models_contract.CustomProviderSelectionCommand, base_url: []const u8) models_contract.CommandResult {
    return controlOwner(context).updateBuiltinProviderBaseUrl(selection, base_url);
}
fn controlReplaceCustomProviderCredential(context: *anyopaque, secret: []const u8, selection: models_contract.CustomProviderSelectionCommand) models_contract.CommandResult {
    return controlOwner(context).replaceCustomProviderCredential(secret, selection);
}
fn controlSubmitCustomProvider(context: *anyopaque, command: models_contract.CustomProviderCommand) models_contract.CommandResult {
    return controlOwner(context).submitCustomProviderCommand(command);
}
fn controlBeginCustomProviderProbe(context: *anyopaque, command: models_contract.CustomModelTestCommand) models_contract.Preparation {
    return controlOwner(context).beginCustomProviderProbe(command);
}
fn controlCompleteCustomModelTest(context: *anyopaque, command: models_contract.CustomModelTestCommand, succeeded: bool) models_contract.CommandResult {
    return controlOwner(context).completeCustomModelTest(command, succeeded);
}
fn controlPrepareMetaskCatalogRefresh(context: *anyopaque, principal_ref: []const u8, authorization_generation: u64) models_contract.CatalogRefreshPrepareResult {
    return controlOwner(context).prepareMetaskCatalogRefresh(principal_ref, authorization_generation);
}
fn controlCompleteMetaskCatalogRefresh(context: *anyopaque, attempt_id: u64, authorization_generation: u64, completion: *models_ports.OwnedCatalogCompletion) models_contract.ModelsError {
    return controlOwner(context).completeMetaskCatalogRefresh(attempt_id, authorization_generation, completion);
}
fn controlFailMetaskCatalogRefresh(context: *anyopaque, attempt_id: u64, authorization_generation: u64, error_code: models_contract.ModelsError, safe_diagnostic: []const u8) void {
    controlOwner(context).failMetaskCatalogRefresh(attempt_id, authorization_generation, error_code, safe_diagnostic);
}
fn controlMetaskAuthorizationUnavailable(context: *anyopaque) void {
    controlOwner(context).setMetaskAuthorizationUnavailable();
}
fn controlDrainAgentEvents(context: *anyopaque) anyerror!void {
    return controlOwner(context).drainAgentEvents();
}

fn controlMcpInspect(context: *anyopaque) ?mcp_configuration.ManagementInspection {
    return controlOwner(context).inspectMcpDesiredConfiguration();
}
fn controlMcpWriteDesired(context: *anyopaque, generation: u64, output: []u8) anyerror![]const u8 {
    return controlOwner(context).writeMcpDesiredConfiguration(generation, output);
}
fn controlMcpBeginConnectionTest(context: *anyopaque, server_id: []const u8) anyerror!void {
    return controlOwner(context).beginMcpConnectionTest(server_id);
}
fn controlMcpCompleteConnectionTest(context: *anyopaque, server_id: []const u8, outcome: McpConnectionTestOutcome, tools: u32, issues: u32) void {
    controlOwner(context).completeMcpConnectionTest(server_id, outcome, tools, issues);
}
fn controlMcpBeginApply(context: *anyopaque, generation: u64) anyerror!void {
    return controlOwner(context).beginMcpConfigurationApply(generation);
}
fn controlMcpCompleteApply(context: *anyopaque, generation: u64, preparation: *mcp_configuration.Preparation, manifest: *mcp_configuration.RuntimeManifest, activation: ?*lifecycle.McpActivation, selection: ?*lifecycle.McpSelection, activation_failed: bool) bool {
    return controlOwner(context).completeMcpConfigurationApply(generation, preparation, manifest, activation, selection, activation_failed);
}
fn controlMcpFailApply(context: *anyopaque, generation: u64) void {
    controlOwner(context).failMcpConfigurationApply(generation);
}
fn controlMcpAuthorizationOperation(context: *anyopaque) ?McpAuthorizationOperationView {
    return controlOwner(context).mcpAuthorizationOperation();
}
fn controlMcpBeginAuthorization(context: *anyopaque, generation: u64, server_id: []const u8) anyerror!?McpAuthorizationStart {
    return controlOwner(context).beginMcpAuthorization(generation, server_id);
}
fn controlMcpAdvanceAuthorization(context: *anyopaque, operation_id: []const u8, phase: McpAuthorizationPhase) bool {
    return controlOwner(context).advanceMcpAuthorization(operation_id, phase);
}
fn controlMcpFinishAuthorization(context: *anyopaque, operation_id: []const u8) bool {
    return controlOwner(context).finishMcpAuthorization(operation_id);
}
fn controlMcpWriteApproval(context: *anyopaque, generation: u64, server_id: []const u8, output: []u8) anyerror![]const u8 {
    return controlOwner(context).writeMcpConnectionApprovalDetails(generation, server_id, output);
}
fn controlMcpApproveConnection(context: *anyopaque, generation: u64, input: mcp_configuration.ApproveConnectionInput) anyerror!mcp_configuration.ManagementOutcome {
    return controlOwner(context).approveMcpConnection(generation, input);
}
fn controlMcpValidateSecretCapture(context: *anyopaque, generation: u64, server_id: []const u8, target: McpSecretCaptureTarget) anyerror!void {
    return controlOwner(context).validateMcpSecretCapture(generation, server_id, target);
}
fn controlMcpCaptureStaticSecret(context: *anyopaque, generation: u64, input: mcp_configuration.CaptureStaticSecretInput) anyerror!mcp_configuration.ManagementOutcome {
    return controlOwner(context).captureMcpStaticSecret(generation, input);
}
fn controlMcpCaptureOauthClientSecret(context: *anyopaque, generation: u64, input: mcp_configuration.CaptureOauthClientSecretInput) anyerror!mcp_configuration.ManagementOutcome {
    return controlOwner(context).captureMcpOauthClientSecret(generation, input);
}
fn controlMcpBeginDynamicRegistration(context: *anyopaque, input: mcp_configuration.OauthConsentInput) anyerror!McpOauthOperationBeginOutcome {
    return controlOwner(context).beginMcpOauthDynamicRegistration(input);
}
fn controlMcpCompleteDynamicRegistration(context: *anyopaque, input: mcp_configuration.CompleteDynamicRegistrationInput) anyerror!mcp_configuration.ManagementOutcome {
    return controlOwner(context).completeMcpOauthDynamicRegistration(input);
}
fn controlMcpBeginCodeExchange(context: *anyopaque, server_id: []const u8) anyerror!McpOauthCodeExchangeBeginOutcome {
    return controlOwner(context).beginMcpOauthCodeExchange(server_id);
}
fn controlMcpCompleteCodeExchange(context: *anyopaque, input: mcp_configuration.CompleteCodeExchangeInput) anyerror!mcp_configuration.ManagementOutcome {
    return controlOwner(context).completeMcpOauthCodeExchange(input);
}
fn controlMcpAuthorizeOauth(context: *anyopaque, plan: McpOauthAuthorizationPlan) anyerror!McpOauthAuthorizationOutcome {
    return controlOwner(context).authorizeMcpOauth(plan);
}
fn controlMcpClearOauthOperation(context: *anyopaque, operation_id: []const u8) anyerror!mcp_configuration.ManagementOutcome {
    return controlOwner(context).clearMcpOauthOperation(operation_id);
}
fn controlMcpRecoverOauthOperation(context: *anyopaque, operation_id: []const u8) anyerror!mcp_configuration.ManagementOutcome {
    return controlOwner(context).recoverMcpOauthOperation(operation_id);
}

fn controlMcpNextOauthExpiry(context: *anyopaque) ?McpOauthExpiry {
    return controlOwner(context).nextMcpOauthExpiry();
}
fn controlMcpBeginOauthRefresh(context: *anyopaque, server_id: []const u8) anyerror!McpOauthRefreshBeginOutcome {
    return controlOwner(context).beginMcpOauthRefresh(server_id);
}
fn controlMcpCompleteOauthRefresh(context: *anyopaque, input: mcp_configuration.CompleteRefreshInput, commit: McpOauthRuntimeCommit) anyerror!mcp_configuration.ManagementOutcome {
    return controlOwner(context).completeMcpOauthRefresh(input, commit);
}
fn controlMcpRequireReauthorization(context: *anyopaque, failure: McpRuntimeAuthorizationFailure) anyerror!McpRuntimeAuthorizationFailureOutcome {
    return controlOwner(context).requireMcpOauthReauthorization(failure);
}

fn controlSetScheduleBackgroundAvailable(context: *anyopaque, available: bool) void {
    controlOwner(context).setScheduleBackgroundAvailableNoFail(available);
}

fn closeWorker(
    completion_out: *std.atomic.Value(CloseCompletion),
    binding: *task_test_agent_session.Binding,
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

const publishAutomaticTitleFallback = if (builtin.is_test) task_test_execution.publishAutomaticTitleFallback else void;
const cancelPreparedRunOrPanic = taskWorkerCancelPreparedRun;
const cancelPreparedCompactOrPanic = taskWorkerCancelPreparedCompact;
fn taskWorkerCancelPreparedRun(
    access: *task_test_agent_session.Access,
    run_id: u64,
) void {
    access.cancelPreparedRun(run_id) catch |err| std.debug.panic(
        "Executor removed queued Run {d}, but Agent rejected prepared cancellation: {s}",
        .{ run_id, @errorName(err) },
    );
}

fn taskWorkerCancelPreparedCompact(
    access: *task_test_agent_session.Access,
    operation_id: u64,
) void {
    access.cancelPreparedCompact(operation_id) catch |err| std.debug.panic(
        "Executor removed queued compact {d}, but Agent rejected prepared cancellation: {s}",
        .{ operation_id, @errorName(err) },
    );
}

fn commitCompactProductTerminal(
    compact: *TestCompactRecord,
    phase: CompactPhase,
    cause: ?CompactCause,
    session_disposition: lifecycle.SessionDisposition,
    usage: UsageView,
    before_context_tokens: u64,
    after_context_tokens: u64,
    diagnostic: []const u8,
    source_diagnostic_truncated: bool,
) bool {
    return task_test_execution.commitCompactProductTerminal(
        .{ .project_fn = projectTaskWorkerText },
        compact,
        phase,
        cause,
        session_disposition,
        usage,
        before_context_tokens,
        after_context_tokens,
        diagnostic,
        source_diagnostic_truncated,
        false,
    );
}

fn requestRunTermination(
    run: *TestRunRecord,
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

fn noChangeNotification(_: ?*anyopaque) bool {
    return true;
}

fn scheduledPermissionProfile(
    profile: PermissionProfile,
) product_schedule.PermissionProfile {
    return switch (profile) {
        .approval_required => .approval_required,
        .full_access => .full_access,
    };
}

fn taskProfileFromSchedule(
    profile: product_schedule.PermissionProfile,
) PermissionProfile {
    return switch (profile) {
        .approval_required => .approval_required,
        .full_access => .full_access,
    };
}

fn metaskStageError(err: anyerror) execution_state.AdmissionReason {
    return switch (err) {
        error.ScheduledTaskPersistenceUnavailable => .schedule_persistence_unavailable,
        error.ScheduledTaskPersistenceFailed => .schedule_persistence_failed,
        error.ScheduledTaskPersistenceOutcomeUnknown => .schedule_persistence_outcome_unknown,
        error.OutOfMemory => .resource_exhausted,
        else => .invalid_candidate,
    };
}

fn scheduledTaskOutcome(
    outcome: RunOutcome,
) product_schedule.TaskOutcome {
    return switch (outcome) {
        .completed => .completed,
        .stopped => .stopped,
        .cancelled => .cancelled,
        .interrupted => .interrupted,
        .failed => .failed,
        .dependency_contract_failure => .dependency_contract_failure,
    };
}

fn scheduledFailure(err: anyerror) product_schedule.FailureReason {
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

fn sameModelRef(
    left: models_contract.ModelRef,
    right: models_contract.ModelRef,
) bool {
    return std.mem.eql(u8, left.source_id, right.source_id) and
        std.mem.eql(u8, left.model_id, right.model_id);
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
    run: *TestRunRecord,
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
            &run.redactionSecrets(),
        );
        run.terminal_payload = .{
            .exclude_on_product_terminal = false,
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

fn commitAgentTerminal(run: *TestRunRecord, result: *const lifecycle.TerminalResult) bool {
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

fn commitBeginFailure(run: *TestRunRecord, failure: lifecycle.BeginRunFailure) void {
    const decision = task_test_policy.classifyBeginFailure(run, failure);
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

fn cancelTaskCheckpoints(task: *TestTask) void {
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

test "approval checkpoint restores before the first Run independently of the Task model and rejects a future approval anchor" {
    var source = try testRuntime();
    defer source.deinit();
    var scratch = try source.buildTaskStateWire();
    defer scratch.deinit();
    var first = scratch.state.tasks[0];
    first.runs = &.{};
    first.next_run_generation = 0;
    first.active_operation = null;
    first.approval_revision = 2;
    first.permission_profile = "full_access";
    first.checkpoint_anchor = "available";
    first.checkpoint = .{
        .blob = .{ .generation = 0, .byte_size = 123, .digest = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" },
        .session = .{ .logical_session_id = "session-before-first-run", .last_run_id = 0, .last_compact_id = 0, .model = first.binding.model },
        .anchor = .{ .terminal = .{ .kind = "approval", .id = 2 }, .binding_epoch = first.binding.epoch },
    };
    var tasks = [_]task_persistence.TaskWire{first};
    var state = scratch.state;
    state.tasks = &tasks;
    const storage = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(storage);
    var history = TestTaskPersistence{ .storage = storage };
    // A later Task model selection may be installed before the next Run
    // checkpoint. The approval checkpoint keeps its own model expectation.
    const Case = struct { anchor_revision: u64, checkpoint_model: []const u8 };
    for ([_]Case{
        .{ .anchor_revision = 2, .checkpoint_model = first.binding.model },
        .{ .anchor_revision = 2, .checkpoint_model = "model-before-selection" },
        .{ .anchor_revision = 3, .checkpoint_model = first.binding.model },
    }) |case| {
        tasks[0].checkpoint.?.anchor.terminal.id = case.anchor_revision;
        tasks[0].checkpoint.?.session.model = case.checkpoint_model;
        var output: [128 * 1024]u8 = undefined;
        const bytes = try task_persistence.encode(&output, state, source.taskPersistenceLimits());
        var restored = try Runtime.init(std.testing.allocator, std.testing.io, &test_agent_runtime, testLimits(), .{
            .task_persistence = history.capability(bytes),
        });
        defer restored.deinit();
        if (case.anchor_revision == 2) {
            const task = restored.task_runtime.find(3) orelse return error.TestUnexpectedResult;
            try std.testing.expect(restored.task_persistence_health != .degraded);
            try std.testing.expectEqual(@as(u64, 2), task.durable.approval_revision);
            try std.testing.expectEqual(.full_access, task.durable.permission_profile);
            try std.testing.expectEqual(@as(u64, 0), task.durable.next_run_generation);
            try std.testing.expectEqualStrings(first.binding.model, task.durable.execution_model);
            const record = task.durable.checkpoint orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(@as(u64, 0), record.session.last_run_id);
            try std.testing.expectEqual(@as(u64, 2), record.anchor.terminal.approval);
            try std.testing.expectEqualStrings(case.checkpoint_model, record.session.model);
            try std.testing.expectEqualStrings("session-before-first-run", record.session.logical_session_id);
            try std.testing.expect(task_test_policy.checkpointMatchesCurrentHistory(task, record));
        } else {
            try std.testing.expect(restored.task_runtime.find(3) == null);
            try std.testing.expectEqual(.degraded, restored.task_persistence_health);
        }
    }
}

fn cancelTaskAutomaticTitles(task: *TestTask) void {
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

fn sanitizeInto(destination: []u8, value: []const u8, secrets: []const []const u8) SanitizeResult {
    var read: usize = 0;
    var write: usize = 0;
    var redacted = false;
    while (read < value.len) {
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

fn projectTaskWorkerText(
    destination: []u8,
    value: []const u8,
    secrets: []const []const u8,
) if (builtin.is_test) task_test_execution.Projection else void {
    const projected = sanitizeInto(destination, value, secrets);
    return .{
        .len = projected.len,
        .truncated = projected.truncated,
        .redacted = projected.redacted,
    };
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

fn takeActivityOrder(run: *TestRunRecord) u64 {
    const result = run.next_activity_order;
    std.debug.assert(result != std.math.maxInt(u64));
    run.next_activity_order += 1;
    return result;
}

fn workspaceRecordCapacity(limits: Limits) ?usize {
    return std.math.add(usize, limits.max_workspaces, limits.max_tasks) catch
        null;
}

fn accountFileChangeSnapshotTier(
    total: *usize,
    remaining_slots: *usize,
    remaining_projection: *usize,
    tier_capacity: usize,
    id_bytes: usize,
) bool {
    const projected_bytes = std.math.add(
        usize,
        id_bytes,
        file_change_min_display_path_bytes,
    ) catch return false;
    const count = @min(
        remaining_slots.*,
        @min(tier_capacity, remaining_projection.* / projected_bytes),
    );
    const id_escape_overestimate = std.math.mul(
        usize,
        id_bytes,
        json_string_expansion - 1,
    ) catch return false;
    if (id_escape_overestimate > file_change_record_snapshot_overhead)
        return false;
    total.* = std.math.add(
        usize,
        total.*,
        std.math.mul(
            usize,
            count,
            file_change_record_snapshot_overhead - id_escape_overestimate,
        ) catch return false,
    ) catch return false;
    remaining_slots.* -= count;
    remaining_projection.* -= count * projected_bytes;
    return true;
}

fn fileChangeSnapshotAdditionalBytes(limits: Limits) ?usize {
    const runs = std.math.mul(
        usize,
        limits.max_tasks,
        limits.max_runs_per_task,
    ) catch return null;
    var remaining_slots = std.math.mul(
        usize,
        runs,
        limits.max_file_changes_per_run,
    ) catch return null;
    const tools = std.math.mul(
        usize,
        runs,
        limits.max_tools_per_run,
    ) catch return null;
    const tool_projection_floor = std.math.mul(
        usize,
        tools,
        tool_min_projection_bytes,
    ) catch return null;
    // The structural bound below already reserves 512 bytes for every Tool.
    // A present Tool necessarily retains at least `tool-1` and a non-empty
    // name. If a Tool slot is absent, its 512-byte structural reservation is
    // larger than the File Change structure that those seven released text
    // bytes could admit, so retaining the floor is still conservative.
    var remaining_projection = limits.max_projection_bytes -|
        @min(limits.max_projection_bytes, tool_projection_floor);
    var total = std.math.mul(
        usize,
        runs,
        file_change_collection_snapshot_overhead,
    ) catch return null;

    // File change ids are exactly change-{task}-{generation}-{order}. Across
    // all live records only 9^3 ids can use three one-digit components, and
    // only 3*90*9^2 more can have exactly one two-digit component. All other
    // ids are at least two bytes longer than the absolute minimum. Restore
    // validates the same canonical identity before admitting persisted state.
    if (!accountFileChangeSnapshotTier(
        &total,
        &remaining_slots,
        &remaining_projection,
        file_change_min_id_capacity,
        file_change_id_min_bytes,
    )) return null;
    if (!accountFileChangeSnapshotTier(
        &total,
        &remaining_slots,
        &remaining_projection,
        file_change_next_id_capacity,
        file_change_id_next_bytes,
    )) return null;
    if (!accountFileChangeSnapshotTier(
        &total,
        &remaining_slots,
        &remaining_projection,
        remaining_slots,
        file_change_id_remaining_bytes,
    )) return null;
    return total;
}

// Management can show every managed install AND every unassociated runtime
// winner. Catalog fields are serialized again in these rows; source settings
// and root checks are additional bounded structure, never Task catalog data.
fn skillManagementAdditionalSnapshotBytes(limits: Limits) ?usize {
    const scopes = std.math.add(usize, limits.max_workspaces, 1) catch return null;
    const catalog_text = std.math.mul(usize, scopes, limits.max_catalog_projection_bytes) catch return null;
    const text = std.math.mul(usize, @min(catalog_text, limits.max_projection_bytes), json_string_expansion) catch return null;
    const arguments = std.math.mul(usize, limits.max_skill_arguments, catalog_argument_snapshot_overhead) catch return null;
    const asset_structure = std.math.add(usize, skill_asset_snapshot_overhead, arguments) catch return null;
    const rows = std.math.mul(usize, scopes, limits.max_catalog_skills) catch return null;
    const structure = std.math.mul(usize, rows, asset_structure) catch return null;
    // Each exact source/invocation issue associates with at most one asset in
    // its context; the catalog's issue array itself is budgeted separately.
    const issues = std.math.mul(usize, scopes, limits.max_catalog_issues) catch return null;
    const issue_codes = std.math.mul(usize, issues, 32) catch return null;
    const discovery = std.math.mul(usize, scopes, skill_source_discovery_snapshot_bytes) catch return null;
    // An unmatched managed install uses its untracked inventory target entry
    // for both invocationName and displayName, independently of catalog text.
    const target_text_per_asset = skill_snapshot_structure.managed_target_text;
    const target_text = std.math.mul(usize, limits.max_skill_assets, target_text_per_asset) catch return null;
    var total = std.math.add(usize, text, structure) catch return null;
    total = std.math.add(usize, total, target_text) catch return null;
    total = std.math.add(usize, total, issue_codes) catch return null;
    total = std.math.add(usize, total, discovery) catch return null;
    return std.math.add(usize, total, skill_source_settings_snapshot_bytes) catch return null;
}

fn worstCaseSnapshotBytes(limits: Limits) ?usize {
    // The 6x bound also covers raw + readable Bash text: readable fields are
    // emitted only from valid JSON. Its raw re-encoding and selected decoded
    // strings each fit 3x source bytes (including the "***" redaction marker).
    // JSON control escapes already occupy bytes in that source; they cannot
    // independently incur another 6x expansion in the decoded representation.
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
    total = std.math.add(usize, total, skillManagementAdditionalSnapshotBytes(limits) orelse return null) catch return null;
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
            custom_provider_snapshot_text_bytes,
            json_string_expansion,
        ) catch return null,
    ) catch return null;
    total = std.math.add(usize, total, custom_provider_snapshot_overhead) catch
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
    total = std.math.add(
        usize,
        total,
        fileChangeSnapshotAdditionalBytes(limits) orelse return null,
    ) catch return null;
    const commentary_segments = std.math.mul(
        usize,
        runs,
        limits.max_commentary_segments_per_run,
    ) catch return null;
    total = std.math.add(
        usize,
        total,
        std.math.mul(
            usize,
            commentary_segments,
            commentary_segment_snapshot_overhead,
        ) catch return null,
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
        .max_file_changes_per_run = 2,
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
        // to the ordinary Runtime projection budget.
        .max_snapshot_bytes = 8 * 1024 * 1024,
    };
}

fn testTaskPersistenceLimits() task_persistence.Limits {
    const limits = testLimits();
    return .{
        .max_workspaces = limits.max_workspaces,
        .max_tasks = limits.max_tasks,
        .max_runs_per_task = limits.max_runs_per_task,
        .max_compacts_per_task = limits.max_compacts_per_task,
        .max_tools_per_run = limits.max_tools_per_run,
        .max_commentary_segments_per_run = limits.max_commentary_segments_per_run,
        .max_file_refs_per_tool = limits.max_file_refs_per_tool,
        .max_file_changes_per_run = limits.max_file_changes_per_run,
        .max_ui_history_per_task = limits.max_ui_history_per_task,
        .max_workspace_bytes = limits.max_workspace_bytes,
        .max_task_title_bytes = limits.max_task_title_bytes,
        .max_user_message_bytes = limits.max_user_message_bytes,
        .max_attachments_per_run = limits.max_attachments_per_draft,
        .max_assistant_message_bytes = limits.max_assistant_message_bytes,
        .max_tool_field_bytes = limits.max_tool_field_bytes,
        .max_file_ref_field_bytes = limits.max_file_ref_field_bytes,
        .max_file_change_field_bytes = limits.max_file_change_field_bytes,
        .max_file_change_diff_bytes = limits.max_file_change_diff_bytes,
        .max_execution_model_bytes = models_contract.Limits.model_id_bytes,
        .max_terminal_diagnostic_bytes = limits.max_terminal_diagnostic_bytes,
    };
}

fn installTestExecution(control: *Runtime) !void {
    try TestSupport.installMetaskExecution(control, 1);
}

fn testRuntime() !Runtime {
    return testRuntimeWith(.{});
}

test "non-Skill executor completion wakes queued source recovery without a Skill completion" {
    const Harness = struct {
        wakes: std.atomic.Value(usize) = .init(0),
        queries: std.atomic.Value(usize) = .init(0),
        fn wake(context: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            _ = self.wakes.fetchAdd(1, .release);
            return true;
        }
        fn query(context: *anyopaque, _: lifecycle.CatalogQuery) anyerror!lifecycle.CatalogAcquisition {
            const self: *@This() = @ptrCast(@alignCast(context));
            _ = self.queries.fetchAdd(1, .release);
            return error.CatalogUnavailable;
        }
    };
    const Blocker = struct {
        harness: *Harness,
        entered: std.atomic.Value(bool) = .init(false),
        released: std.atomic.Value(bool) = .init(false),
        fn execute(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.entered.store(true, .release);
            while (!self.released.load(.acquire)) std.Thread.yield() catch {};
            _ = Harness.wake(self.harness);
        }
        fn cancel(_: *anyopaque) void {}
        fn job(self: *@This()) executor_impl.Job {
            return .{ .identity = self, .context = self, .execute_fn = execute, .cancel_fn = cancel };
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);
    var store: @import("metawork_product_skill").sources.FileStore = .{ .io = std.testing.io, .dir = tmp.dir };
    try store.commit(.{});
    var harness: Harness = .{};
    var first: Blocker = .{ .harness = &harness };
    var second: Blocker = .{ .harness = &harness };
    var limits = testLimits();
    limits.worker_count = 1;
    limits.queue_capacity = 1;
    test_agent_runtime.io = std.testing.io;
    var control = try Runtime.init(std.testing.allocator, std.testing.io, &test_agent_runtime, limits, .{
        .directories = .{ .canonical_user_home = home },
        .change_notifier = .{ .context = &harness, .wake = Harness.wake },
        .skill_sources = .{ .file_store = &store, .restored = .read_failed },
    });
    defer {
        first.released.store(true, .release);
        second.released.store(true, .release);
        control.deinit();
    }
    control.skill.ports.catalog.context = &harness;
    control.skill.ports.catalog.query_fn = Harness.query;
    try control.executor.enqueue(first.job());
    while (!first.entered.load(.acquire)) std.Thread.yield() catch {};
    try control.executor.enqueue(second.job());
    const recovered = control.recoverSkillSourceSettings(.reread, control.skill.sourceSettings().recovery_token.?);
    try std.testing.expect(recovered.applied);
    try std.testing.expect(control.skill.personalSourceDiscovery().?.checking);
    try std.testing.expectEqual(@as(usize, 0), harness.queries.load(.acquire));
    const wakes = harness.wakes.load(.acquire);
    first.released.store(true, .release);
    while (!second.entered.load(.acquire)) std.Thread.yield() catch {};
    try std.testing.expect(harness.wakes.load(.acquire) > wakes);
    control.syncLifecycle();
    second.released.store(true, .release);
    while (harness.wakes.load(.acquire) < wakes + 3) std.Thread.yield() catch {};
    control.syncLifecycle();
    try std.testing.expectEqual(@as(usize, 1), harness.queries.load(.acquire));
    try std.testing.expect(!control.skill.personalSourceDiscovery().?.checking);
    // A non-QueueFull query failure is not retried on unrelated future wakes.
    control.syncLifecycle();
    try std.testing.expectEqual(@as(usize, 1), harness.queries.load(.acquire));
}

fn testTaskModelSelectionInput(
    control: *Runtime,
    expected_revision: u64,
    target_model: []const u8,
) TaskModelSelectionInput {
    const models = control.modelsView();
    return .{
        .expected_selection_revision = expected_revision,
        .target = .{
            .source_id = models.metask_selection.?.source_id,
            .model_id = target_model,
        },
        .expected_source_generation = models.providers[0].source_generation,
        .expected_catalog_generation = models.providers[0].catalog_generation,
    };
}

fn testRuntimeWith(configuration: Configuration) !Runtime {
    return testRuntimeWithLimits(testLimits(), configuration);
}

fn testRuntimeWithLimits(limits: Limits, configuration: Configuration) !Runtime {
    test_agent_runtime.io = std.testing.io;
    // This fixture models a known default source configuration. Source-store
    // recovery tests supply their own Runtime and explicit restore evidence.
    var fixture_configuration = configuration;
    fixture_configuration.skill_sources = .{ .restored = .{ .loaded = .{ .ready = .{} } } };
    var control = try Runtime.init(
        std.testing.allocator,
        std.testing.io,
        &test_agent_runtime,
        limits,
        fixture_configuration,
    );
    try installTestExecution(&control);
    var task_execution = try control.cloneCurrentTaskExecution(control.allocator);
    errdefer task_execution.deinit();
    control.revision = 0;
    const workspace = try control.copyBounded("/tmp/metawork-test", control.limits.max_workspace_bytes);
    product_workspace.testing.installOwned(&control.workspace, 0, .{
        .id = 1,
        .canonical_root = try control.copyBounded(
            "/tmp/metawork-test",
            control.limits.max_workspace_bytes,
        ),
        .projected_root_storage = try control.copyBounded(
            "/tmp/metawork-test",
            control.limits.max_workspace_bytes,
        ),
        .projected_root_len = "/tmp/metawork-test".len,
        .display_name_storage = try control.copyBounded(
            "metawork-test",
            control.limits.max_workspace_bytes,
        ),
        .display_name_len = "metawork-test".len,
        .recent_order = 1,
    });
    control.skill.registerWorkspaceOwned(.{
        .id = 1,
        .epoch = 1,
        .catalog_authorized = true,
        .canonical_root = try control.allocator.dupe(u8, "/tmp/metawork-test"),
    }, control.skillProjectionBudget());
    product_workspace.testing.setIdentity(&control.workspace, 2, 2);
    control.task_runtime.next_task_id = 4;
    control.task_runtime.next_recent_order = 2;
    const execution_model = try control.copyBounded(
        control.execution_state.model(),
        models_contract.Limits.model_id_bytes,
    );
    const runs = try control.allocator.alloc(?TestRunRecord, control.limits.max_runs_per_task);
    @memset(runs, null);
    const compacts = try control.allocator.alloc(
        ?TestCompactRecord,
        control.limits.max_compacts_per_task,
    );
    @memset(compacts, null);
    const ui_history = try control.allocator.alloc(?UiRecord, control.limits.max_ui_history_per_task);
    @memset(ui_history, null);
    const tools = try control.allocator.alloc(?ToolView, control.limits.max_tools_per_run);
    @memset(tools, null);
    const file_changes = try control.allocator.alloc(
        ?task_test_state.FileChangeView,
        control.limits.max_file_changes_per_run,
    );
    @memset(file_changes, null);
    const commentary_ends = try control.allocator.alloc(
        u64,
        control.limits.max_commentary_segments_per_run,
    );
    runs[0] = .{
        .id = 7,
        .generation = 1,
        .execution_generation = 1,
        .execution_protocol = .anthropic_messages,
        .execution_model = execution_model,
        .permission_profile = .approval_required,
        .permission_interaction = .interactive,
        .input = .{ .text = .{
            .value = try control.copyBounded(
                "inspect",
                control.limits.max_user_message_bytes,
            ),
        } },
        .commentary_ends = commentary_ends,
        .active_phase = .running,
        // Projection-only fixture: no live Agent control lease exists.
        .agent_handoff = .init(.finishing),
        .tools = tools,
        .file_change_observation = .collecting,
        .file_changes = file_changes,
        .terminal_diagnostic = try control.allocTrackedCapacity(control.limits.max_terminal_diagnostic_bytes),
        .redaction_secret = control.execution_state.credential(),
    };
    control.task_runtime.tasks[0] = .{
        .durable = .{
            .id = 3,
            .recent_order = 1,
            .execution_generation = 1,
            .execution_protocol = .anthropic_messages,
            .execution_model = execution_model,
            .permission_profile = .approval_required,
            .permission_interaction = .interactive,
            .workspace_id = 1,
            .workspace_root = workspace,
            .title = try control.copyBounded("", control.limits.max_task_title_bytes),
            .runs = runs,
            .compacts = compacts,
            .next_run_generation = 1,
            .ui_history = ui_history,
        },
        .runtime = .{
            .attachment = .{ .attached = .{
                .binding = task_test_agent_session.Binding.testFixture(3),
                .execution = task_execution.take(),
                .pinned_catalog = null,
            } },
            .active_run_id = 7,
            .active_operation = .{ .run = 7 },
        },
    };
    return control;
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
    recoveries: usize = 0,
    result: SchedulePersistenceCommit = .committed,
    storage: ?[]u8 = null,
    len: usize = 0,

    fn commit(
        context: ?*anyopaque,
        bytes: []const u8,
    ) SchedulePersistenceCommit {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        std.debug.assert(bytes.len != 0);
        self.commits += 1;
        if (self.result == .committed) {
            if (self.storage) |storage| {
                if (bytes.len > storage.len) return .failed;
                @memcpy(storage[0..bytes.len], bytes);
                self.len = bytes.len;
            }
        }
        return self.result;
    }

    fn capability(self: *@This()) SchedulePersistence {
        return .{
            .context = self,
            .enabled = true,
            .commit_fn = commit,
            .recover_fn = recover,
        };
    }

    fn recover(
        context: ?*anyopaque,
        bytes: []const u8,
    ) SchedulePersistenceCommit {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.recoveries += 1;
        return commit(context, bytes);
    }
};

const TestTaskPersistence = struct {
    storage: []u8,
    len: usize = 0,
    commits: usize = 0,
    recoveries: usize = 0,
    resolutions: usize = 0,
    resolution_result: TaskPersistenceCommit = .outcome_unknown,
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
            .confirmed_commit_fn = commit,
            .resolve_commit_fn = resolve,
            .recover_fn = recover,
        };
    }

    fn resolve(context: ?*anyopaque, _: []const u8) TaskPersistenceCommit {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.resolutions += 1;
        return self.resolution_result;
    }

    fn recover(
        context: ?*anyopaque,
        bytes: []const u8,
    ) TaskPersistenceCommit {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.recoveries += 1;
        return commit(context, bytes);
    }
};

fn replaceTaskCredentialForTest(
    task: *TestTask,
    credential: []const u8,
) !void {
    const live = task.runtime.live().?;
    live.execution.deinit();
    var replacement = try OwnedTaskExecution.clone(std.testing.allocator, .{
        .target = .{
            .provider_id = models_contract.metask_source_id,
            .protocol = .anthropic_messages,
            .model = "fixture-model",
            .base_url = models_contract.metask_anthropic_messages_url,
        },
        .execution_generation = task.durable.execution_generation,
        .api_key = credential,
    });
    live.execution = replacement.take();
    const redaction_secret = live.execution.input().api_key;
    for (task.durable.runs) |*run_entry| {
        if (run_entry.*) |*run| run.redaction_secret = redaction_secret;
    }
}

fn detachTaskForTest(control: *Runtime, task: *TestTask) void {
    switch (task.runtime.attachment) {
        .detached => return,
        .attached, .closing => {},
    }
    var live = task.runtime.detach(.cold_start);
    live.execution.deinit();
    if (live.pinned_catalog) |*snapshot| {
        control.projection_bytes -= snapshot.projected_bytes;
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

fn finalizeTestTerminalEvents(control: *Runtime) void {
    control.markTerminalRunsBeforeEventDrain();
    control.finalizeMarkedTerminalRunsAfterEventDrain();
    control.syncLifecycle();
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
    var unavailable = try Runtime.init(
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
        unavailable.createTaskForWorkspace(
            .automatic,
            1,
            unavailable.newTaskAdmissionView().active_selection_revision,
            null,
            null,
            null,
            .{ .interactive = null },
        ),
    );
    unavailable.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var canonical_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const canonical_len = try tmp.dir.realPath(
        std.testing.io,
        &canonical_storage,
    );
    var root = try product_workspace.AutomaticRoot.open(
        std.testing.io,
        std.testing.allocator,
        canonical_storage[0..canonical_len],
    );
    defer root.deinit();
    var control = try Runtime.init(
        std.testing.allocator,
        std.testing.io,
        &test_agent_runtime,
        testLimits(),
        .{ .directories = .{ .testing_automatic_workspace_root = &root } },
    );
    defer control.deinit();
    try std.testing.expect(control.automaticWorkspacesAvailable());
    try std.testing.expectError(
        error.InvalidWorkspace,
        control.openWorkspace(.{
            .workspace_root = control.workspace.automaticRootPath().?,
            .trust = .explicitly_trusted,
        }),
    );
    var automatic = try control.prepareAutomaticWorkspace();
    const automatic_facts = automatic.facts(&control);
    try std.testing.expectError(
        error.InvalidWorkspace,
        control.openWorkspace(.{
            .workspace_root = automatic_facts.canonical_root,
            .trust = .explicitly_trusted,
        }),
    );
    automatic.rollback(&control);
}

test "automatic Workspace root configuration swaps only future allocations and fails closed on uncertain persistence" {
    test_agent_runtime.io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "default", .default_dir);
    try tmp.dir.createDir(std.testing.io, "custom", .default_dir);
    var default_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var custom_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const default_len = try tmp.dir.realPathFile(
        std.testing.io,
        "default",
        &default_storage,
    );
    const custom_len = try tmp.dir.realPathFile(
        std.testing.io,
        "custom",
        &custom_storage,
    );
    const default_root = default_storage[0..default_len];
    const custom_root = custom_storage[0..custom_len];
    var store: product_workspace.AutomaticRootConfigurationFileStore = .{
        .io = std.testing.io,
        .dir = tmp.dir,
    };
    var control = try Runtime.init(
        std.testing.allocator,
        std.testing.io,
        &test_agent_runtime,
        testLimits(),
        .{ .directories = .{
            .automatic_workspace_system_root = default_root,
            .automatic_workspace_configuration_store = &store,
        } },
    );
    defer control.deinit();
    const initial = control.automaticWorkspaceRootConfiguration();
    try std.testing.expectEqual(@as(u64, 1), initial.generation);
    try std.testing.expectEqual(
        product_workspace.AutomaticRootConfigurationMode.system_default,
        initial.mode.?,
    );
    try std.testing.expectEqualStrings(default_root, initial.canonical_root.?);

    var first = try control.prepareAutomaticWorkspace();
    const first_path = try std.testing.allocator.dupe(
        u8,
        first.facts(&control).canonical_root,
    );
    defer std.testing.allocator.free(first_path);
    first.complete(&control);

    try control.chooseAutomaticWorkspaceRoot(initial.generation, custom_root);
    const custom_view = control.automaticWorkspaceRootConfiguration();
    try std.testing.expectEqual(
        product_workspace.AutomaticRootConfigurationMode.custom,
        custom_view.mode.?,
    );
    try std.testing.expectEqualStrings(custom_root, custom_view.canonical_root.?);
    try std.testing.expect(custom_view.generation != initial.generation);
    try std.testing.expectError(
        error.AutomaticWorkspaceRootGenerationMismatch,
        control.resetAutomaticWorkspaceRoot(initial.generation),
    );

    var second = try control.prepareAutomaticWorkspace();
    const second_path = second.facts(&control).canonical_root;
    try std.testing.expect(product_workspace.automaticPathStrictlyWithin(
        custom_root,
        second_path,
    ));
    try std.testing.expect(product_workspace.automaticPathStrictlyWithin(
        default_root,
        first_path,
    ));
    second.complete(&control);

    product_workspace.automatic_root_configuration.testing.setCommitFault(
        &store,
        .write_failed,
    );
    try std.testing.expectError(
        error.AutomaticWorkspaceRootPersistenceFailed,
        control.resetAutomaticWorkspaceRoot(custom_view.generation),
    );
    const failed = control.automaticWorkspaceRootConfiguration();
    try std.testing.expectEqual(
        product_workspace.AutomaticRootConfigurationHealth.write_failed,
        failed.health,
    );
    try std.testing.expectEqualStrings(custom_root, failed.canonical_root.?);
    try std.testing.expect(control.automaticWorkspacesAvailable());

    product_workspace.automatic_root_configuration.testing.setCommitFault(
        &store,
        .outcome_unknown_after_install,
    );
    try std.testing.expectError(
        error.AutomaticWorkspaceRootPersistenceOutcomeUnknown,
        control.resetAutomaticWorkspaceRoot(failed.generation),
    );
    const uncertain = control.automaticWorkspaceRootConfiguration();
    try std.testing.expectEqual(
        product_workspace.AutomaticRootConfigurationHealth.outcome_unknown,
        uncertain.health,
    );
    try std.testing.expect(uncertain.mode == null);
    try std.testing.expect(uncertain.canonical_root == null);
    try std.testing.expect(!control.automaticWorkspacesAvailable());
    var uncertain_snapshot_storage: [96 * 1024]u8 = undefined;
    const uncertain_snapshot = try control.writeAggregateFixture(&uncertain_snapshot_storage);
    try std.testing.expect(std.mem.indexOf(
        u8,
        uncertain_snapshot,
        "\"mode\":null,\"canonicalRoot\":null,\"health\":\"outcome_unknown\"",
    ) != null);

    product_workspace.automatic_root_configuration.testing.setCommitFault(
        &store,
        .none,
    );
    product_workspace.automatic_root_configuration.testing.setRecoveryFault(
        &store,
        .install_failed,
    );
    try std.testing.expectError(
        error.AutomaticWorkspaceRootPersistenceFailed,
        control.resetAutomaticWorkspaceRoot(uncertain.generation),
    );
    try std.testing.expectEqual(
        product_workspace.AutomaticRootConfigurationHealth.outcome_unknown,
        control.automaticWorkspaceRootConfiguration().health,
    );
    try std.testing.expect(control.automaticWorkspaceRootConfiguration().mode == null);
    try std.testing.expect(control.automaticWorkspaceRootConfiguration().canonical_root == null);
    product_workspace.automatic_root_configuration.testing.setRecoveryFault(
        &store,
        .none,
    );
    try control.resetAutomaticWorkspaceRoot(uncertain.generation);
    const recovered = control.automaticWorkspaceRootConfiguration();
    try std.testing.expectEqual(
        product_workspace.AutomaticRootConfigurationHealth.ready,
        recovered.health,
    );
    try std.testing.expectEqualStrings(default_root, recovered.canonical_root.?);
    try std.testing.expect(control.automaticWorkspacesAvailable());

    control.workspace.disableAutomaticRoot();
    control.automatic_root_configuration.health = .path_unavailable;
    product_workspace.automatic_root_configuration.testing.setCommitFault(
        &store,
        .write_failed,
    );
    try std.testing.expectError(
        error.AutomaticWorkspaceRootPersistenceFailed,
        control.chooseAutomaticWorkspaceRoot(recovered.generation, custom_root),
    );
    const unavailable_after_write_failure = control.automaticWorkspaceRootConfiguration();
    try std.testing.expectEqual(
        product_workspace.AutomaticRootConfigurationHealth.path_unavailable,
        unavailable_after_write_failure.health,
    );
    try std.testing.expectEqual(
        product_workspace.AutomaticRootConfigurationMode.system_default,
        unavailable_after_write_failure.mode.?,
    );
    try std.testing.expectEqualStrings(
        default_root,
        unavailable_after_write_failure.canonical_root.?,
    );
    product_workspace.automatic_root_configuration.testing.setCommitFault(
        &store,
        .none,
    );
    try control.retryAutomaticWorkspaceRoot(recovered.generation);
    const retried = control.automaticWorkspaceRootConfiguration();
    try std.testing.expectEqual(
        product_workspace.AutomaticRootConfigurationHealth.ready,
        retried.health,
    );
    try std.testing.expectEqualStrings(default_root, retried.canonical_root.?);
}

test "automatic Workspace root bootstrap restores a committed custom root" {
    test_agent_runtime.io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "default", .default_dir);
    try tmp.dir.createDir(std.testing.io, "custom", .default_dir);
    var default_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var custom_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const default_len = try tmp.dir.realPathFile(std.testing.io, "default", &default_storage);
    const custom_len = try tmp.dir.realPathFile(std.testing.io, "custom", &custom_storage);
    var store: product_workspace.AutomaticRootConfigurationFileStore = .{
        .io = std.testing.io,
        .dir = tmp.dir,
    };
    var configuration = try product_workspace.AutomaticRootConfiguration.custom(
        std.testing.allocator,
        custom_storage[0..custom_len],
    );
    defer configuration.deinit();
    var encoded_storage: [product_workspace.automatic_root_configuration.max_store_bytes]u8 = undefined;
    try store.commit(try product_workspace.automatic_root_configuration.encode(
        &encoded_storage,
        &configuration,
    ));

    var control = try Runtime.init(
        std.testing.allocator,
        std.testing.io,
        &test_agent_runtime,
        testLimits(),
        .{ .directories = .{
            .automatic_workspace_system_root = default_storage[0..default_len],
            .automatic_workspace_configuration_store = &store,
        } },
    );
    defer control.deinit();
    const view = control.automaticWorkspaceRootConfiguration();
    try std.testing.expectEqual(
        product_workspace.AutomaticRootConfigurationMode.custom,
        view.mode.?,
    );
    try std.testing.expectEqualStrings(custom_storage[0..custom_len], view.canonical_root.?);
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
    var control = try Runtime.init(
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
    defer control.deinit();

    try std.testing.expectError(
        error.InvalidWorkspace,
        control.openWorkspace(.{
            .workspace_root = ".",
            .trust = .explicitly_trusted,
        }),
    );
    const root_id = try control.openWorkspace(.{
        .workspace_root = root_path,
        .trust = .explicitly_trusted,
    });
    try std.testing.expect(root_id != 0);
    try std.testing.expect(control.task_runtime.tasks[0] == null);

    const source_id = try control.openWorkspace(.{
        .workspace_root = source_path,
        .trust = .{ .temporary = root_path },
    });
    try std.testing.expect(source_id != root_id);

    var storage: [2]WorkspaceProjection = undefined;
    const projections = try control.copyWorkspaceProjections(&storage);
    try std.testing.expectEqual(@as(usize, 2), projections.len);
    try std.testing.expectEqual(source_id, projections[0].id);
    try std.testing.expectEqual(WorkspaceAuthorization.available, projections[0].authorization);
    try std.testing.expectEqualStrings("src", projections[0].display_name);
    try std.testing.expect(std.fs.path.isAbsolute(projections[0].canonical_root));

    try control.removeWorkspace(root_id);
    try std.testing.expectEqual(@as(u64, 2), try control.workspaceEpoch(root_id));
    const remaining = try control.copyWorkspaceProjections(&storage);
    try std.testing.expectEqual(@as(usize, 1), remaining.len);

    const restored_id = try control.openWorkspace(.{
        .workspace_root = root_path,
        .trust = .explicitly_trusted,
    });
    try std.testing.expectEqual(root_id, restored_id);
    const restored = try control.copyWorkspaceProjections(&storage);
    try std.testing.expectEqual(root_id, restored[0].id);
    try std.testing.expectEqual(@as(u64, 3), restored[0].epoch);
    try std.testing.expectEqual(WorkspaceAuthorization.available, restored[0].authorization);

    var no_space: [0]WorkspaceProjection = .{};
    try std.testing.expectError(
        error.WorkspaceCapacity,
        control.copyWorkspaceProjections(&no_space),
    );
    try std.testing.expectError(
        error.WorkspaceCapacity,
        control.openWorkspace(.{
            .workspace_root = tests_path,
            .trust = .{ .temporary = root_path },
        }),
    );
}

test "Workspace upsert unknown outcome stays usable and heals on retry" {
    test_agent_runtime.io = std.testing.io;
    const root_path = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(root_path);
    const persistence_storage = try std.testing.allocator.alloc(
        u8,
        task_persistence.max_store_bytes,
    );
    defer std.testing.allocator.free(persistence_storage);
    var persistence = TestTaskPersistence{
        .storage = persistence_storage,
        .result = .outcome_unknown,
    };
    var control = try Runtime.init(
        std.testing.allocator,
        std.testing.io,
        &test_agent_runtime,
        testLimits(),
        .{ .task_persistence = persistence.capability(null) },
    );
    defer control.deinit();
    _ = try control.openWorkspace(.{
        .workspace_root = root_path,
        .trust = .explicitly_trusted,
    });
    try std.testing.expectEqual(@as(usize, 1), control.workspace.count(.manual));
    try std.testing.expectEqual(
        TaskPersistenceHealth.outcome_unknown,
        control.task_persistence_health,
    );
    persistence.result = .committed;
    _ = try control.openWorkspace(.{
        .workspace_root = root_path,
        .trust = .explicitly_trusted,
    });
    try std.testing.expectEqual(TaskPersistenceHealth.ready, control.task_persistence_health);
}

test "hidden Workspace record with Task history cannot be reused" {
    var control = try testRuntime();
    defer control.deinit();
    control.limits.max_workspaces = 1;
    product_workspace.testing.setManualLimit(&control.workspace, 1);

    const task = &control.task_runtime.tasks[0].?;
    const run = &task.durable.runs[0].?;
    _ = commitTerminal(run, .completed, .completed, null, .reusable, "", false);
    finalizeTestTerminalEvents(&control);
    control.releaseTaskAttachmentNoFail(task, .cold_start);
    try control.removeWorkspace(1);
    try std.testing.expect(!(control.workspace.facts(1) orelse
        return error.TestUnexpectedResult).visible);

    const replacement_root = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(replacement_root);
    try std.testing.expectError(
        error.WorkspaceCapacity,
        control.openWorkspace(.{
            .workspace_root = replacement_root,
            .trust = .explicitly_trusted,
        }),
    );
    try std.testing.expect(control.workspace.findByRoot(replacement_root) == null);
    try std.testing.expect(control.workspace.facts(1) != null);
}

test "File Preview Workspace authority requires exact identity epoch and root" {
    var control = try testRuntime();
    defer control.deinit();
    const exact: task_runtime.FileReference = .{
        .workspace_id = 1,
        .workspace_epoch = 1,
        .workspace_root = "/tmp/metawork-test",
        .id = "ref-1",
        .title = "fixture",
        .display_path = "fixture.txt",
        .kind = "file",
        .locator_kind = .workspace_path,
        .locator = "fixture.txt",
        .range = null,
    };
    try std.testing.expect(control.filePreviewWorkspaceAuthorized(exact));

    var stale_id = exact;
    stale_id.workspace_id = 2;
    try std.testing.expect(!control.filePreviewWorkspaceAuthorized(stale_id));
    var stale_epoch = exact;
    stale_epoch.workspace_epoch = 2;
    try std.testing.expect(!control.filePreviewWorkspaceAuthorized(stale_epoch));
    var stale_root = exact;
    stale_root.workspace_root = "/tmp/other";
    try std.testing.expect(!control.filePreviewWorkspaceAuthorized(stale_root));
    product_workspace.testing.setAuthorization(
        &control.workspace,
        1,
        .removing,
    );
    try std.testing.expect(!control.filePreviewWorkspaceAuthorized(exact));
}

test "Workspace projection derives aggregate Task signals and removal preserves history" {
    var control = try testRuntime();
    defer control.deinit();
    var storage: [2]WorkspaceProjection = undefined;

    const running = try control.copyWorkspaceProjections(&storage);
    try std.testing.expectEqual(@as(u32, 1), running[0].signals.running);
    try std.testing.expectEqual(@as(u32, 0), running[0].signals.attention);

    control.task_runtime.tasks[0].?.durable.runs[0].?.active_phase = .waiting_ui;
    const attention = Runtime.workspaceViewSignals(&control, 1);
    try std.testing.expectEqual(@as(u32, 0), attention.running);
    try std.testing.expectEqual(@as(u32, 1), attention.attention);

    const run = &control.task_runtime.tasks[0].?.durable.runs[0].?;
    _ = commitTerminal(run, .failed, .failed, null, .reusable, "", false);
    finalizeTestTerminalEvents(&control);
    const failed = try control.copyWorkspaceProjections(&storage);
    try std.testing.expectEqual(@as(u32, 1), failed[0].signals.failed_or_interrupted);

    const task_root = control.task_runtime.tasks[0].?.durable.workspace_root;
    control.releaseTaskAttachmentNoFail(&control.task_runtime.tasks[0].?, .cold_start);
    try control.removeWorkspace(1);
    try std.testing.expect(control.task_runtime.tasks[0] != null);
    try std.testing.expectEqualStrings(task_root, control.task_runtime.tasks[0].?.durable.workspace_root);
    const removed = try control.copyWorkspaceProjections(&storage);
    try std.testing.expectEqual(@as(usize, 0), removed.len);
    try std.testing.expectError(error.TaskClosing, control.runTask(3, .{ .text = "continue" }));
}

fn testAttachmentPreview(_: ?*anyopaque, allocator: std.mem.Allocator, bytes: []const u8, _: usize) anyerror![]u8 {
    return allocator.dupe(u8, bytes);
}

test "Automatic Workspace snapshot exposes unavailable Skill authority with no query authorization" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buffer);
    var store = try AttachmentFileStore.init(std.testing.io, std.testing.allocator, path_buffer[0..path_len]);
    defer store.deinit();
    var control = try testRuntime();
    defer control.deinit();
    control.attachments.file_store = &store;
    control.attachments.images.prepare_fn = testAttachmentPreview;
    product_workspace.testing.makeAutomatic(&control.workspace, 1, 3);
    try control.skill.setWorkspaceCatalogAuthorized(1, 1, false, control.skillProjectionBudget());

    var fixture = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, contract_fixture.snapshot, .{});
    defer fixture.deinit();
    const workspace = &fixture.value.object.getPtr("workspaces").?.array.items[0];
    workspace.object.getPtr("kind").?.* = .{ .string = "automatic" };
    workspace.object.getPtr("recentOrder").?.* = .{ .string = "0" };
    workspace.object.getPtr("skillCatalog").?.object.getPtr("availability").?.* = .{ .string = "unavailable" };
    const expected = try std.json.Stringify.valueAlloc(std.testing.allocator, fixture.value, .{});
    defer std.testing.allocator.free(expected);
    var storage: [8192]u8 = undefined;
    try std.testing.expectEqualStrings(expected, try control.writeAggregateFixture(&storage));
}

test "Product Control snapshot serializer matches the Renderer contract fixture" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buffer);
    var store = try AttachmentFileStore.init(std.testing.io, std.testing.allocator, path_buffer[0..path_len]);
    defer store.deinit();
    var control = try testRuntime();
    defer control.deinit();
    control.attachments.file_store = &store;
    control.attachments.images.prepare_fn = testAttachmentPreview;

    try std.testing.expectEqual(
        CatalogAvailability.uninitialized,
        (try control.taskCatalog(3)).availability,
    );
    var storage: [8192]u8 = undefined;
    const snapshot = try control.writeAggregateFixture(&storage);
    const fixture = std.mem.trimEnd(
        u8,
        contract_fixture.snapshot,
        "\r\n",
    );
    try std.testing.expectEqualStrings(fixture, snapshot);
    var view_storage: [16 * 1024]u8 = undefined;
    const view = try control.writeViewFixture(&view_storage, .{ .task_id = 3, .management = .skills });
    try std.testing.expectEqualStrings(std.mem.trimEnd(u8, contract_fixture.product_view, "\r\n"), view);

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

test "Product Control snapshot serializer keeps model intent independent of installed execution" {
    var control = try testRuntime();
    defer control.deinit();
    const task = control.task_runtime.find(3).?;
    task.durable.model_intent = try task_test_state.ModelIntent.init(std.testing.allocator, .{
        .source_id = "another-provider",
        .model_id = "next-model",
    }, 9);
    var storage: [16 * 1024]u8 = undefined;
    const snapshot = try control.writeAggregateFixture(&storage);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, snapshot, .{});
    defer parsed.deinit();
    const projected = parsed.value.object.get("tasks").?.array.items[0].object;
    const intent = projected.get("modelIntent").?.object;
    const model = intent.get("modelRef").?.object;
    try std.testing.expectEqualStrings("another-provider", model.get("sourceId").?.string);
    try std.testing.expectEqualStrings("next-model", model.get("modelId").?.string);
    try std.testing.expectEqualStrings("9", intent.get("selectionRevision").?.string);
    const binding = projected.get("binding").?.object;
    try std.testing.expectEqualStrings("fixture-model", binding.get("model").?.string);
    try std.testing.expectEqualStrings("1", binding.get("executionGeneration").?.string);
    const run = projected.get("runs").?.array.items[0].object.get("execution").?.object;
    try std.testing.expectEqualStrings("fixture-model", run.get("model").?.string);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "SECRET-KEY") == null);
}

test "Product Control snapshot serializer preserves complete Account summary history" {
    var control = try testRuntime();
    defer control.deinit();
    const history_days = [_]account_contract.UsageHistoryDayView{.{
        .date = "2026-09-15",
        .input_tokens = "1",
        .output_tokens = "2",
        .cache_creation_tokens = "3",
        .cache_read_tokens = "4",
        .total_tokens = "10",
        .actual_cost_u = "0.25",
    }};
    control.commitAccountFactNoFail(.{
        .kind = .summary_changed,
        .view = .{
            .state = .authenticated,
            .account_id = "account-1",
            .display_name = "Fixture User",
            .email_hint = "f***@example.com",
            .phone_hint = "138****8000",
            .concurrency_limit = 5,
            .summary = .{
                .usage_eligibility = .enabled,
                .wallet = .{
                    .availability = .ready,
                    .balance_u = "-1.25",
                    .synced_at_unix_ms = "1720000000000",
                },
                .usage = .{
                    .availability = .ready,
                    .today = .{
                        .input_tokens = "10",
                        .output_tokens = "20",
                        .cache_creation_tokens = "3",
                        .cache_read_tokens = "4",
                        .total_tokens = "37",
                        .actual_cost_u = "0.125",
                    },
                    .total = .{ .total_tokens = "300", .actual_cost_u = "2.5" },
                    .synced_at_unix_ms = "1720000000000",
                },
                .history = .{
                    .availability = .ready,
                    .start_date = "2025-09-15",
                    .end_date = "2026-09-15",
                    .days = &history_days,
                    .synced_at_unix_ms = "1720000000000",
                },
            },
        },
    });
    var storage: [16 * 1024]u8 = undefined;
    const snapshot = try control.writeAggregateFixture(&storage);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, snapshot, .{});
    defer parsed.deinit();
    const summary = parsed.value.object.get("account").?.object.get("summary").?.object;
    const wallet = summary.get("wallet").?.object;
    const usage = summary.get("usage").?.object;
    const history = summary.get("history").?.object;
    try std.testing.expectEqualStrings("-1.25", wallet.get("balanceU").?.string);
    try std.testing.expectEqualStrings("37", usage.get("today").?.object.get("totalTokens").?.string);
    try std.testing.expectEqualStrings("2.5", usage.get("total").?.object.get("actualCostU").?.string);
    try std.testing.expectEqualStrings("2025-09-15", history.get("startDate").?.string);
    try std.testing.expectEqualStrings("10", history.get("days").?.array.items[0].object.get("totalTokens").?.string);
}

test "Task completion receipt is identity-bound idempotent and order-neutral" {
    var control = try testRuntime();
    defer control.deinit();

    const task = &control.task_runtime.tasks[0].?;
    const run = &task.durable.runs[0].?;
    _ = commitTerminal(run, .completed, .completed, null, .reusable, "", false);
    finalizeTestTerminalEvents(&control);

    try std.testing.expectEqual(@as(?u64, 7), task_test_policy.unreadCompletionRunId(task));
    const recent_order = task.durable.recent_order;
    const revision = control.currentRevision();
    try std.testing.expect(!control.markTaskCompletionSeen(3, 6));
    try std.testing.expectEqual(revision, control.currentRevision());
    try std.testing.expect(control.markTaskCompletionSeen(3, 7));
    try std.testing.expectEqual(revision + 1, control.currentRevision());
    try std.testing.expectEqual(recent_order, task.durable.recent_order);
    try std.testing.expectEqual(@as(?u64, null), task_test_policy.unreadCompletionRunId(task));
    try std.testing.expect(!control.markTaskCompletionSeen(3, 7));
    try std.testing.expectEqual(revision + 1, control.currentRevision());

    run.id = 8;
    try std.testing.expectEqual(@as(?u64, 8), task_test_policy.unreadCompletionRunId(task));
    try std.testing.expect(!control.markTaskCompletionSeen(3, 7));
    try std.testing.expect(control.markTaskCompletionSeen(3, 8));
    task.durable.completion_seen_run_id = 0;
    run.terminal_payload.phase = .failed;
    run.terminal_payload.outcome = .failed;
    try std.testing.expectEqual(@as(?u64, null), task_test_policy.unreadCompletionRunId(task));
    try std.testing.expect(!control.markTaskCompletionSeen(3, 8));
    run.terminal_payload.phase = .completed;
    run.terminal_payload.outcome = .completed;
    try control.setTaskArchived(3, true);
    try std.testing.expectEqual(@as(u64, 8), task.durable.completion_seen_run_id);
    try std.testing.expectEqual(@as(?u64, null), task_test_policy.unreadCompletionRunId(task));
    task.durable.completion_seen_run_id = 0;
    try std.testing.expect(!control.markTaskCompletionSeen(3, 8));
}

test "Restore permission stats are projected as runtime health" {
    var control = try testRuntime();
    defer control.deinit();
    control.task_runtime.tasks[0].?.runtime.last_restore_permission = .{
        .restored_rules = 2,
        .invalidated_rules = 1,
    };
    var storage: [8192]u8 = undefined;
    const snapshot = try control.writeAggregateFixture(&storage);
    try std.testing.expect(
        std.mem.indexOf(u8, snapshot, "\"restorePermission\":{\"restoredRules\":\"2\",\"invalidatedRules\":\"1\"}") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"permission_provenance\"") == null);
}

test "a Task saved by a newer build restores read-only and commits keep its frame" {
    const persistence_storage = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(persistence_storage);
    var persistence = TestTaskPersistence{ .storage = persistence_storage };
    {
        var source = try testRuntime();
        defer source.deinit();
        try source.replaceTracked(
            &source.task_runtime.tasks[0].?.durable.workspace_root,
            "/tmp/metawork-test",
            source.limits.max_workspace_bytes,
        );
        source.task_runtime.next_recent_order = 2;
        source.task_persistence = persistence.capability(null);
        source.task_persistence_health = .ready;
        try source.commitTaskState();
    }
    const newer_storage = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(newer_storage);
    const newer = try task_persistence.testing.addTaskField(
        newer_storage,
        persistence.storage[0..persistence.len],
        "\"newer_field\":1",
    );

    var restored = try Runtime.init(
        std.testing.allocator,
        std.testing.io,
        &test_agent_runtime,
        testLimits(),
        .{ .task_persistence = persistence.capability(newer) },
    );
    defer restored.deinit();
    try std.testing.expectEqual(TaskPersistenceHealth.degraded, restored.task_persistence_health);
    const task = restored.task_runtime.find(3) orelse return error.TestUnexpectedResult;
    try std.testing.expect(task.read_only_history != null);
    try std.testing.expectError(error.TaskReadOnly, restored.renameTask(3, "renamed"));
    try std.testing.expectError(error.TaskReadOnly, restored.setTaskArchived(3, true));
    try std.testing.expectError(error.TaskReadOnly, restored.deleteTask(3));

    const commits = persistence.commits;
    try restored.commitTaskState();
    try std.testing.expectEqual(commits + 1, persistence.commits);
    try std.testing.expect(std.mem.indexOf(
        u8,
        persistence.storage[0..persistence.len],
        "\"newer_field\":1",
    ) != null);
}

test "Task state round trip restores product history without fabricating a Session" {
    const persistence_storage = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(persistence_storage);
    var persistence = TestTaskPersistence{ .storage = persistence_storage };
    const source_history_storage = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(source_history_storage);
    var source_history_len: usize = 0;

    {
        var source = try testRuntime();
        defer source.deinit();
        try source.replaceTracked(
            &source.task_runtime.tasks[0].?.durable.workspace_root,
            "/tmp/metawork-test",
            source.limits.max_workspace_bytes,
        );
        source.task_runtime.next_recent_order = 2;
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
        var file_changes = try testEnvelope(
            3,
            7,
            "{\"file_changes\":{\"id\":\"tool-restore\",\"name\":\"Edit\",\"changes\":[{\"locator\":{\"workspace_path\":\"src/restored.zig\"},\"kind\":\"modified\",\"status\":\"applied\",\"tool\":\"Edit\",\"tool_use_id\":\"tool-restore\",\"agent_depth\":0,\"before_bytes\":1,\"after_bytes\":2,\"diff_complete\":true}],\"overflow\":false,\"lost\":false}}",
        );
        defer file_changes.deinit();
        try source.applyEvent(&file_changes);
        try std.testing.expectEqual(@as(usize, 3), persistence.commits);
        const persisted_run = &source.task_runtime.tasks[0].?.durable.runs[0].?;
        persisted_run.assistant_output_kind = .final;
        persisted_run.assistant_output_start = 0;
        try source.commitTaskState();
        try std.testing.expectEqual(@as(usize, 4), persistence.commits);
        try std.testing.expect(persistence.len != 0);
        var verified = try task_persistence.decode(
            std.testing.allocator,
            persistence.storage[0..persistence.len],
            source.taskPersistenceLimits(),
        );
        try std.testing.expectEqualStrings(
            "final",
            verified.value.tasks[0].runs[0].assistant_output_kind.?,
        );
        try std.testing.expectEqual(
            @as(?u64, 0),
            verified.value.tasks[0].runs[0].assistant_output_start,
        );
        try std.testing.expectEqual(null, verified.value.tasks[0].runs[0].event_projection_failure);
        verified.deinit();
        try std.testing.expect(
            std.mem.indexOf(u8, persistence.storage[0..persistence.len], "SECRET-KEY") == null,
        );
        @memcpy(
            source_history_storage[0..persistence.len],
            persistence.storage[0..persistence.len],
        );
        source_history_len = persistence.len;

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
        terminal_state.value.tasks[0].runs[0].file_change_observation = "complete";
        terminal_state.value.tasks[0].active_operation = null;
        terminal_state.value.tasks[0].completion_seen_run_id = null;
        var pending_compacts = [_]task_persistence.CompactWire{.{
            .id = 9,
            .coverage = "pending",
            .after_run_id = 7,
            .phase = "compacted",
            .cause = null,
            .before_context_tokens = 10,
            .after_context_tokens = 5,
            .usage = .{
                .input_tokens = 0,
                .output_tokens = 0,
                .cache_read_input_tokens = 0,
                .cache_creation_input_tokens = 0,
            },
            .diagnostic = "",
            .diagnostic_truncated = false,
            .diagnostic_redacted = false,
        }};
        terminal_state.value.tasks[0].compacts = &pending_compacts;
        const terminal_bytes = try task_persistence.encode(
            terminal_storage,
            terminal_state.value,
            source.taskPersistenceLimits(),
        );
        const terminal_restore = try std.testing.allocator.create(Runtime);
        defer std.testing.allocator.destroy(terminal_restore);
        terminal_restore.* = try Runtime.init(
            std.testing.allocator,
            std.testing.io,
            &test_agent_runtime,
            testLimits(),
            .{
                .task_persistence = persistence.capability(terminal_bytes),
            },
        );
        defer terminal_restore.deinit();
        const terminal_task = terminal_restore.task_runtime.find(3) orelse
            return error.TestUnexpectedResult;
        const terminal_run = findRun(terminal_task.durable.runs, 7) orelse
            return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(u64, 7), terminal_task.durable.completion_seen_run_id);
        try std.testing.expectEqual(@as(?u64, null), task_test_policy.unreadCompletionRunId(terminal_task));
        try std.testing.expectEqual(RunPhase.completed, runPhase(terminal_run));
        try std.testing.expectEqual(
            task_test_state.ConversationCoverage.excluded,
            terminal_run.coverage,
        );
        const terminal_compact = task_test_state.findCompact(
            terminal_task.durable.compacts,
            9,
        ) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(
            task_test_state.CompactPhase.compacted,
            task_test_state.compactProjectionFacts(terminal_compact).phase,
        );
        try std.testing.expectEqual(
            task_test_state.ConversationCoverage.excluded,
            terminal_compact.coverage,
        );
        try std.testing.expectEqual(task_test_state.AssistantOutputKind.final, terminal_run.assistant_output_kind.?);
        try std.testing.expectEqual(@as(?usize, 0), terminal_run.assistant_output_start);
        try std.testing.expectEqual(
            null,
            terminal_run.event_projection_failure,
        );
        for (terminal_run.tools) |*entry| {
            const restored_tool = &(entry.* orelse continue);
            try std.testing.expect(restored_tool.state != .running);
            try std.testing.expect(!std.mem.eql(u8, restored_tool.id, "tool-running"));
        }

        const failed_storage = try std.testing.allocator.alloc(u8, 1024 * 1024);
        defer std.testing.allocator.free(failed_storage);
        terminal_state.value.tasks[0].runs[0].event_projection_failure =
            "dependency_contract_failure";
        const failed_bytes = try task_persistence.encode(
            failed_storage,
            terminal_state.value,
            source.taskPersistenceLimits(),
        );
        const failed_restore = try std.testing.allocator.create(Runtime);
        defer std.testing.allocator.destroy(failed_restore);
        failed_restore.* = try Runtime.init(
            std.testing.allocator,
            std.testing.io,
            &test_agent_runtime,
            testLimits(),
            .{
                .task_persistence = persistence.capability(failed_bytes),
            },
        );
        defer failed_restore.deinit();
        const failed_task = failed_restore.task_runtime.find(3) orelse
            return error.TestUnexpectedResult;
        const failed_run = findRun(failed_task.durable.runs, 7) orelse
            return error.TestUnexpectedResult;
        try std.testing.expectEqual(RunPhase.failed, runPhase(failed_run));
        try std.testing.expectEqual(
            task_test_state.EventProjectionFailure.dependency_contract_failure,
            failed_run.event_projection_failure.?,
        );

        const interrupted_compact_storage = try std.testing.allocator.alloc(u8, 1024 * 1024);
        defer std.testing.allocator.free(interrupted_compact_storage);
        pending_compacts[0].phase = "compacting";
        terminal_state.value.tasks[0].active_operation = .{ .kind = "compact", .id = 9 };
        const interrupted_compact_bytes = try task_persistence.encode(
            interrupted_compact_storage,
            terminal_state.value,
            source.taskPersistenceLimits(),
        );
        const interrupted_compact_restore = try std.testing.allocator.create(Runtime);
        defer std.testing.allocator.destroy(interrupted_compact_restore);
        interrupted_compact_restore.* = try Runtime.init(
            std.testing.allocator,
            std.testing.io,
            &test_agent_runtime,
            testLimits(),
            .{
                .task_persistence = persistence.capability(interrupted_compact_bytes),
            },
        );
        defer interrupted_compact_restore.deinit();
        const restored_compact_task = interrupted_compact_restore.task_runtime.find(3) orelse
            return error.TestUnexpectedResult;
        const interrupted_compact = task_test_state.findCompact(
            restored_compact_task.durable.compacts,
            9,
        ) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(
            task_test_state.CompactPhase.interrupted,
            task_test_state.compactProjectionFacts(interrupted_compact).phase,
        );
        try std.testing.expectEqual(
            task_test_state.ConversationCoverage.excluded,
            interrupted_compact.coverage,
        );
        try std.testing.expectEqual(
            ActiveOperation.none,
            restored_compact_task.runtime.active_operation,
        );
    }

    const source_history = source_history_storage[0..source_history_len];
    {
        const legacy_storage = try std.testing.allocator.alloc(u8, 1024 * 1024);
        defer std.testing.allocator.free(legacy_storage);
        var legacy_state = try task_persistence.decode(
            std.testing.allocator,
            source_history,
            testTaskPersistenceLimits(),
        );
        defer legacy_state.deinit();
        const previous_observation = legacy_state.value.tasks[0].runs[0].file_change_observation;
        const previous_changes = legacy_state.value.tasks[0].runs[0].file_changes;
        legacy_state.value.tasks[0].runs[0].file_change_observation = null;
        legacy_state.value.tasks[0].runs[0].file_changes = null;
        const legacy_bytes = try task_persistence.encode(
            legacy_storage,
            legacy_state.value,
            testTaskPersistenceLimits(),
        );
        legacy_state.value.tasks[0].runs[0].file_change_observation = previous_observation;
        legacy_state.value.tasks[0].runs[0].file_changes = previous_changes;
        const legacy_restore = try std.testing.allocator.create(Runtime);
        defer std.testing.allocator.destroy(legacy_restore);
        legacy_restore.* = try Runtime.init(
            std.testing.allocator,
            std.testing.io,
            &test_agent_runtime,
            testLimits(),
            .{ .task_persistence = persistence.capability(legacy_bytes) },
        );
        defer legacy_restore.deinit();
        const legacy_task = legacy_restore.task_runtime.find(3) orelse
            return error.TestUnexpectedResult;
        const legacy_run = findRun(legacy_task.durable.runs, 7) orelse
            return error.TestUnexpectedResult;
        try std.testing.expect(legacy_run.file_change_observation == null);
        for (legacy_run.file_changes) |change| try std.testing.expect(change == null);
    }

    const restored = try std.testing.allocator.create(Runtime);
    defer std.testing.allocator.destroy(restored);
    restored.* = try Runtime.init(
        std.testing.allocator,
        std.testing.io,
        &test_agent_runtime,
        testLimits(),
        .{
            .task_persistence = persistence.capability(
                source_history,
            ),
        },
    );
    defer restored.deinit();
    const task = restored.task_runtime.find(3) orelse return error.TestUnexpectedResult;
    try std.testing.expect(!task.runtime.hasAttachedSession());
    try std.testing.expect(task.runtime.executionConst() == null);
    try std.testing.expectEqual(ActiveOperation.none, task.runtime.active_operation);
    try std.testing.expectEqual(
        ContinuationUnavailableReason.execution_rebind_required,
        restored.task_runtime.continuationProjection(
            task.durable.id,
            restored.taskRuntimeProjectionEffects(),
        ).?.unavailable,
    );
    try std.testing.expectError(
        error.RecoveryUnavailable,
        restored.restoreTaskConversation(3, task.durable.binding_epoch),
    );
    const run = findRun(task.durable.runs, 7) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(RunPhase.interrupted, runPhase(run));
    try std.testing.expectEqual(
        task_test_state.ConversationCoverage.excluded,
        run.coverage,
    );
    try std.testing.expectEqual(RunOutcome.interrupted, productTerminalFacts(run).?.outcome);
    try std.testing.expectEqual(
        task_test_state.FileChangeObservation.incomplete,
        run.file_change_observation.?,
    );
    try std.testing.expect(run.file_changes_known_loss);
    try std.testing.expectEqual(task_test_state.AssistantOutputKind.final, run.assistant_output_kind.?);
    try std.testing.expectEqual(@as(?usize, 0), run.assistant_output_start);
    try std.testing.expectEqual(null, run.event_projection_failure);
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

    const snapshot_storage = try std.testing.allocator.alloc(u8, 96 * 1024);
    defer std.testing.allocator.free(snapshot_storage);
    const snapshot = try restored.writeAggregateFixture(snapshot_storage);
    try std.testing.expect(
        std.mem.indexOf(u8, snapshot, "\"taskHistoryPersistence\":true") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, snapshot, "\"conversationRecovery\":true") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, snapshot, "\"continuationUnavailableReason\":\"execution_rebind_required\"") != null,
    );

    try restored.setTaskArchived(3, true);
    try restored.deleteTask(3);
    var deleted_restore = try Runtime.init(
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
    try std.testing.expect(deleted_restore.task_runtime.find(3) == null);
}

test "clean shutdown persists an acknowledged completion without an eager commit" {
    const persistence_storage = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(persistence_storage);
    var persistence = TestTaskPersistence{ .storage = persistence_storage };

    {
        var source = try testRuntime();
        defer source.deinit();
        source.task_persistence = persistence.capability(null);
        source.task_persistence_health = .ready;
        const run = &source.task_runtime.tasks[0].?.durable.runs[0].?;
        _ = commitTerminal(run, .completed, .completed, null, .reusable, "", false);
        finalizeTestTerminalEvents(&source);
        const commits_before_mark = persistence.commits;
        try std.testing.expect(source.markTaskCompletionSeen(3, 7));
        try std.testing.expectEqual(commits_before_mark, persistence.commits);
        source.shutdownExecutor();
        try std.testing.expectEqual(commits_before_mark + 1, persistence.commits);
    }

    var restored = try Runtime.init(
        std.testing.allocator,
        std.testing.io,
        &test_agent_runtime,
        testLimits(),
        .{ .task_persistence = persistence.capability(
            persistence.storage[0..persistence.len],
        ) },
    );
    defer restored.deinit();
    const task = restored.task_runtime.find(3) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 7), task.durable.completion_seen_run_id);
    try std.testing.expectEqual(@as(?u64, null), task_test_policy.unreadCompletionRunId(task));
}

test "one damaged Task record does not poison surviving history" {
    var source = try testRuntime();
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
    const bytes = try task_persistence.testing.encodeUnchecked(&bytes_storage, mixed_state);

    var persistence = TestTaskPersistence{
        .storage = try std.testing.allocator.alloc(u8, task_persistence.max_store_bytes),
    };
    defer std.testing.allocator.free(persistence.storage);
    var restored = try Runtime.init(
        std.testing.allocator,
        std.testing.io,
        &test_agent_runtime,
        testLimits(),
        .{ .task_persistence = persistence.capability(bytes) },
    );
    defer restored.deinit();
    try std.testing.expect(restored.task_runtime.find(3) != null);
    try std.testing.expectEqual(TaskPersistenceHealth.degraded, restored.task_persistence_health);
    var snapshot_storage: [96 * 1024]u8 = undefined;
    const snapshot = try restored.writeAggregateFixture(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(
        u8,
        snapshot,
        "\"taskHistoryPersistence\":true,\"taskHistoryPersistenceHealth\":\"degraded\"",
    ) != null);

    try installTestExecution(&restored);
    try restored.renameTask(3, "Recovered history");
    try std.testing.expectEqual(TaskPersistenceHealth.ready, restored.task_persistence_health);
}

test "Automatic Workspace history survives an unavailable allocator" {
    const persistence_storage = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(persistence_storage);
    var persistence = TestTaskPersistence{ .storage = persistence_storage };

    {
        var source = try testRuntime();
        defer source.deinit();
        product_workspace.testing.makeAutomatic(&source.workspace, 1, 3);
        source.task_runtime.next_recent_order = 2;
        source.task_persistence = persistence.capability(null);
        source.task_persistence_health = .ready;
        try source.commitTaskState();
    }

    var restored = try Runtime.init(
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
    const restored_workspace = restored.workspace.facts(1) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(WorkspaceKind.automatic, restored_workspace.kind);
    var workspace_storage: [1]WorkspaceProjection = undefined;
    const workspaces = try restored.copyWorkspaceProjections(&workspace_storage);
    try std.testing.expectEqual(@as(usize, 1), workspaces.len);
    try std.testing.expectEqual(WorkspaceKind.automatic, workspaces[0].kind);
    try std.testing.expectEqual(WorkspaceAuthorization.available, workspaces[0].authorization);
    const task = restored.task_runtime.find(3) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(
        ContinuationUnavailableReason.execution_rebind_required,
        restored.task_runtime.continuationProjection(
            task.durable.id,
            restored.taskRuntimeProjectionEffects(),
        ).?.unavailable,
    );

    var snapshot_storage: [96 * 1024]u8 = undefined;
    const snapshot = try restored.writeAggregateFixture(&snapshot_storage);
    try std.testing.expect(
        std.mem.indexOf(u8, snapshot, "\"automaticWorkspaces\":false") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, snapshot, "\"kind\":\"automatic\"") != null,
    );
}

test "Task persistence restore failure remains diagnostic while product mutations continue" {
    test_agent_runtime.io = std.testing.io;
    const root_path = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(root_path);
    var control = try Runtime.init(
        std.testing.allocator,
        std.testing.io,
        &test_agent_runtime,
        testLimits(),
        .{ .task_persistence = .{ .restore_failed = true } },
    );
    defer control.deinit();
    try installTestExecution(&control);
    try std.testing.expectEqual(TaskPersistenceHealth.read_failed, control.task_persistence_health);
    _ = try control.openWorkspace(.{
        .workspace_root = root_path,
        .trust = .explicitly_trusted,
    });
    try std.testing.expectEqual(TaskPersistenceHealth.read_failed, control.task_persistence_health);
}

test "explicit Task history recovery is revision bound and preserves live Product state" {
    const persistence_storage = try std.testing.allocator.alloc(
        u8,
        task_persistence.max_store_bytes,
    );
    defer std.testing.allocator.free(persistence_storage);
    var persistence = TestTaskPersistence{
        .storage = persistence_storage,
        .result = .outcome_unknown,
    };
    var control = try testRuntime();
    defer control.deinit();
    control.task_persistence = persistence.capability(null);
    control.task_persistence_health = .corrupt;
    const title_before = control.task_runtime.tasks[0].?.durable.title;
    const revision = control.currentRevision();

    try std.testing.expect(control.canCreateTask());
    try std.testing.expect(control.taskHistoryRecoveryAvailable());
    try std.testing.expectEqual(
        PersistenceRecoveryOutcome.stale_revision,
        control.recoverTaskHistory(revision + 1),
    );
    try std.testing.expectEqual(@as(usize, 0), persistence.recoveries);
    try std.testing.expectEqual(
        PersistenceRecoveryOutcome.outcome_unknown,
        control.recoverTaskHistory(revision),
    );
    try std.testing.expectEqual(TaskPersistenceHealth.outcome_unknown, control.task_persistence_health);
    try std.testing.expectEqualStrings(title_before, control.task_runtime.tasks[0].?.durable.title);
    try std.testing.expect(control.canCreateTask());
    try std.testing.expect(control.taskHistoryRecoveryAvailable());

    persistence.result = .committed;
    try std.testing.expectEqual(
        PersistenceRecoveryOutcome.recovered,
        control.recoverTaskHistory(control.currentRevision()),
    );
    try std.testing.expectEqual(TaskPersistenceHealth.ready, control.task_persistence_health);
    try std.testing.expectEqual(@as(usize, 2), persistence.recoveries);
    try std.testing.expectEqualStrings(title_before, control.task_runtime.tasks[0].?.durable.title);
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            persistence.storage[0..persistence.len],
            "SECRET-KEY",
        ) == null,
    );
}

test "Task persistence failure publishes metadata and retries the next save" {
    const persistence_storage = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(persistence_storage);
    var persistence = TestTaskPersistence{
        .storage = persistence_storage,
        .result = .failed,
    };
    var control = try testRuntime();
    defer control.deinit();
    control.task_persistence = persistence.capability(null);
    control.task_persistence_health = .ready;
    try control.renameTask(3, "published in memory");
    try std.testing.expectEqualStrings(
        "published in memory",
        control.task_runtime.tasks[0].?.durable.title,
    );
    try std.testing.expectEqual(TaskPersistenceHealth.write_failed, control.task_persistence_health);
    persistence.result = .committed;
    try control.renameTask(3, "saved on retry");
    try std.testing.expectEqualStrings("saved on retry", control.task_runtime.tasks[0].?.durable.title);
    try std.testing.expectEqual(TaskPersistenceHealth.ready, control.task_persistence_health);
}

test "Task invariant rejection preserves the last good persistence candidate" {
    const persistence_storage = try std.testing.allocator.alloc(
        u8,
        task_persistence.max_store_bytes,
    );
    defer std.testing.allocator.free(persistence_storage);
    var persistence = TestTaskPersistence{ .storage = persistence_storage };
    var control = try testRuntime();
    defer control.deinit();
    control.task_persistence = persistence.capability(null);
    control.task_persistence_health = .ready;

    try control.commitTaskState();
    const committed_len = persistence.len;
    const committed = try std.testing.allocator.dupe(
        u8,
        persistence.storage[0..committed_len],
    );
    defer std.testing.allocator.free(committed);
    const committed_count = persistence.commits;

    control.task_runtime.next_recent_order = 1;
    try std.testing.expectError(
        error.TaskStoreEncodeFailed,
        control.commitTaskState(),
    );
    try std.testing.expectEqual(committed_count, persistence.commits);
    try std.testing.expectEqual(committed_len, persistence.len);
    try std.testing.expectEqualSlices(
        u8,
        committed,
        persistence.storage[0..persistence.len],
    );
    try std.testing.expectEqual(
        TaskPersistenceHealth.write_failed,
        control.task_persistence_health,
    );
}

test "Task persistence failure rolls back deletion before physical release" {
    const persistence_storage = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(persistence_storage);
    var persistence = TestTaskPersistence{
        .storage = persistence_storage,
        .result = .failed,
    };
    var control = try testRuntime();
    defer control.deinit();

    const task = &control.task_runtime.tasks[0].?;
    task.runtime.active_run_id = 0;
    const completed = &task.durable.runs[0].?;
    _ = commitTerminal(completed, .completed, .completed, null, .reusable, "", false);
    finalizeTestTerminalEvents(&control);
    task.durable.archived = true;
    control.releaseTaskAttachmentNoFail(task, .cold_start);
    control.task_persistence = persistence.capability(null);
    control.task_persistence_health = .ready;
    const tracked_before_delete = control.projection_bytes;

    try std.testing.expectError(error.TaskPersistenceFailed, control.deleteTask(3));
    try std.testing.expect(control.task_runtime.find(3) != null);
    try std.testing.expectEqual(tracked_before_delete, control.projection_bytes);
    try std.testing.expectEqual(TaskPersistenceHealth.write_failed, control.task_persistence_health);
    var snapshot_storage: [128 * 1024]u8 = undefined;
    const snapshot = try control.writeAggregateFixture(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(
        u8,
        snapshot,
        "\"deletionStatus\":\"failed\"",
    ) != null);
    persistence.result = .committed;
    try control.deleteTask(3);
    try std.testing.expect(control.task_runtime.find(3) == null);
    try std.testing.expectEqual(TaskPersistenceHealth.ready, control.task_persistence_health);
}

test "Task persistence failure keeps Workspace state and retries later" {
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

    var control = try Runtime.init(
        std.testing.allocator,
        std.testing.io,
        &test_agent_runtime,
        testLimits(),
        .{ .task_persistence = persistence.capability(null) },
    );
    defer control.deinit();
    const root_id = try control.openWorkspace(.{
        .workspace_root = root_path,
        .trust = .explicitly_trusted,
    });
    try std.testing.expect(control.workspace.facts(root_id) != null);
    try std.testing.expectEqual(TaskPersistenceHealth.write_failed, control.task_persistence_health);
    persistence.result = .committed;
    const source_id = try control.openWorkspace(.{
        .workspace_root = source_path,
        .trust = .explicitly_trusted,
    });
    try std.testing.expect(control.workspace.facts(source_id) != null);
    try std.testing.expectEqual(TaskPersistenceHealth.ready, control.task_persistence_health);
}

test "explicit Schedule recovery is revision bound and reopens only its Product store" {
    const persistence_storage = try std.testing.allocator.alloc(
        u8,
        product_schedule.testing.max_store_bytes,
    );
    defer std.testing.allocator.free(persistence_storage);
    var persistence: TestSchedulePersistence = .{
        .storage = persistence_storage,
    };
    var control = try testRuntime();
    defer control.deinit();
    product_schedule.testing.configure(
        &control.schedule,
        .{},
        persistence.capability(),
        .corrupt,
    );
    defer product_schedule.testing.configure(
        &control.schedule,
        .{},
        .{},
        .unavailable,
    );
    const revision = control.currentRevision();

    try std.testing.expect(control.scheduledTaskRecoveryAvailable());
    try std.testing.expectEqual(
        PersistenceRecoveryOutcome.stale_revision,
        control.recoverScheduledTaskStore(revision + 1),
    );
    try std.testing.expectEqual(@as(usize, 0), persistence.recoveries);
    try std.testing.expectEqual(
        PersistenceRecoveryOutcome.recovered,
        control.recoverScheduledTaskStore(revision),
    );
    try std.testing.expectEqual(SchedulePersistenceHealth.ready, control.schedule.persistenceHealth());
    try std.testing.expectEqual(@as(usize, 1), persistence.recoveries);
    try std.testing.expectEqual(TaskPersistenceHealth.unavailable, control.task_persistence_health);
}

test "Product Control snapshot serializer keeps durable Metask intent after authorization loss" {
    var control = try testRuntime();
    defer control.deinit();
    const task_id = control.task_runtime.tasks[0].?.durable.id;
    const before = control.modelsView();
    const metask_selection = before.metask_selection orelse
        return error.TestUnexpectedResult;
    const default_selection = before.default_selection orelse
        return error.TestUnexpectedResult;
    const binding_epoch = try control.taskBindingEpoch(task_id);

    control.commitAccountFactNoFail(.{
        .kind = .signed_out,
        .view = .{ .state = .signed_out },
    });
    control.finishAccountCommitNoFail();
    control.setMetaskAuthorizationUnavailable();

    try std.testing.expectEqual(account_contract.AccountState.signed_out, control.accountView().state);
    const after = control.modelsView();
    try std.testing.expectEqual(
        models_contract.CatalogState.needs_authentication,
        after.providers[0].catalog_state,
    );
    try std.testing.expectEqual(@as(usize, 0), after.providers[0].models.len);
    try std.testing.expectEqualStrings(
        metask_selection.model_id,
        after.metask_selection.?.model_id,
    );
    try std.testing.expectEqualStrings(
        default_selection.model_id,
        after.default_selection.?.model_id,
    );
    try std.testing.expect(!control.canCreateTask());
    try std.testing.expectEqual(binding_epoch, try control.taskBindingEpoch(task_id));

    var models_storage: [4096]u8 = undefined;
    var models_writer = std.Io.Writer.fixed(&models_storage);
    try control.writeModels(&models_writer);
    const models_fixture = std.mem.trimEnd(
        u8,
        contract_fixture.models_unavailable,
        "\r\n",
    );
    try std.testing.expectEqualStrings(models_fixture, models_writer.buffered());
}

test "Scheduled Task admission is bounded redacted and arms the Runtime clock" {
    var control = try testRuntime();
    defer control.deinit();
    var automatic_tmp = std.testing.tmpDir(.{});
    defer automatic_tmp.cleanup();
    var automatic_root_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const automatic_root_len = try automatic_tmp.dir.realPath(
        std.testing.io,
        &automatic_root_storage,
    );
    var automatic_root = try product_workspace.AutomaticRoot.open(
        std.testing.io,
        std.testing.allocator,
        automatic_root_storage[0..automatic_root_len],
    );
    defer automatic_root.deinit();
    var clock: TestScheduleClock = .{ .now = 1_000 };
    const persistence_storage = try std.testing.allocator.alloc(
        u8,
        product_schedule.testing.max_store_bytes,
    );
    defer std.testing.allocator.free(persistence_storage);
    var persistence: TestSchedulePersistence = .{
        .storage = persistence_storage,
    };
    product_schedule.testing.configure(
        &control.schedule,
        clock.timer(),
        persistence.capability(),
        .ready,
    );
    defer {
        product_schedule.testing.configure(
            &control.schedule,
            .{},
            .{},
            .unavailable,
        );
    }
    try std.testing.expectError(
        error.WorkspaceUnavailable,
        control.createScheduledTask(.{
            .title = "Independent review",
            .binding = TestSupport.scheduledBinding(&control),
            .permission_profile = .approval_required,
            .input = "Review current work",
            .recurrence = .{ .once = .{ .at_unix_seconds = 2_000 } },
        }),
    );
    try std.testing.expectEqual(@as(usize, 0), persistence.commits);
    product_workspace.testing.installAutomaticRoot(
        &control.workspace,
        &automatic_root,
    );
    const id = try control.createScheduledTask(.{
        .title = "Review SECRET-KEY",
        .binding = TestSupport.scheduledBinding(&control),
        .permission_profile = .full_access,
        .input = "Inspect SECRET-KEY usage",
        .recurrence = .{ .interval = .{
            .start_at_unix_seconds = 2_000,
            .every_seconds = 300,
        } },
    });
    try std.testing.expect(clock.armed_at == null);
    control.setScheduleBackgroundAvailableNoFail(true);
    try std.testing.expectEqual(@as(u64, 2_000), clock.armed_at.?);
    try std.testing.expectEqual(@as(usize, 1), persistence.commits);
    const item = product_schedule.testing.item(&control.schedule, id).?;
    try std.testing.expect(item.title_redacted);
    try std.testing.expect(
        std.mem.indexOf(u8, item.title, "SECRET-KEY") == null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            item.input,
            "SECRET-KEY",
        ) == null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            persistence_storage[0..persistence.len],
            "SECRET-KEY",
        ) == null,
    );
    const storage = try std.testing.allocator.alloc(
        u8,
        control.limits.max_snapshot_bytes,
    );
    defer std.testing.allocator.free(storage);
    const snapshot = try control.writeAggregateFixture(storage);
    try std.testing.expect(
        std.mem.indexOf(u8, snapshot, "\"scheduledTasks\":[{") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, snapshot, "SECRET-KEY") == null,
    );
    try control.setScheduledTaskEnabled(id, item.epoch, false);
    try std.testing.expectEqual(@as(usize, 2), persistence.commits);
    try std.testing.expect(clock.armed_at == null);
    try std.testing.expectEqual(
        product_schedule.Health.paused,
        product_schedule.testing.item(&control.schedule, id).?.health,
    );
    const committed_epoch = product_schedule.testing.item(&control.schedule, id).?.epoch;
    persistence.result = .failed;
    const revision_before_failure = control.revision;
    try std.testing.expectError(
        error.ScheduledTaskPersistenceFailed,
        control.deleteScheduledTask(id, committed_epoch),
    );
    try std.testing.expectEqual(revision_before_failure + 1, control.revision);
    try std.testing.expect(product_schedule.testing.item(&control.schedule, id) != null);
    try std.testing.expectEqual(
        committed_epoch,
        product_schedule.testing.item(&control.schedule, id).?.epoch,
    );
    try std.testing.expectEqual(
        SchedulePersistenceHealth.write_failed,
        control.schedule.persistenceHealth(),
    );
}

test "execution replacement durably scrubs Schedule before ownership transfer" {
    var control = try testRuntime();
    defer control.deinit();
    try replaceTaskCredentialForTest(
        &control.task_runtime.tasks[0].?,
        "TASK-SECRET",
    );
    var automatic_tmp = std.testing.tmpDir(.{});
    defer automatic_tmp.cleanup();
    var automatic_root_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const automatic_root_len = try automatic_tmp.dir.realPath(
        std.testing.io,
        &automatic_root_storage,
    );
    var automatic_root = try product_workspace.AutomaticRoot.open(
        std.testing.io,
        std.testing.allocator,
        automatic_root_storage[0..automatic_root_len],
    );
    defer automatic_root.deinit();
    var clock: TestScheduleClock = .{ .now = 1_000 };
    const persistence_storage = try std.testing.allocator.alloc(
        u8,
        product_schedule.testing.max_store_bytes,
    );
    defer std.testing.allocator.free(persistence_storage);
    var persistence: TestSchedulePersistence = .{
        .storage = persistence_storage,
    };
    product_schedule.testing.configure(
        &control.schedule,
        clock.timer(),
        persistence.capability(),
        .ready,
    );
    defer {
        product_schedule.testing.configure(
            &control.schedule,
            .{},
            .{},
            .unavailable,
        );
    }
    product_workspace.testing.installAutomaticRoot(
        &control.workspace,
        &automatic_root,
    );

    const id = try control.createScheduledTask(.{
        .title = "Use NEXT-SECRET and TASK-SECRET",
        .binding = TestSupport.scheduledBinding(&control),
        .permission_profile = .approval_required,
        .input = "Review NEXT-SECRET with TASK-SECRET",
        .recurrence = .{ .once = .{ .at_unix_seconds = 2_000 } },
    });
    try std.testing.expect(std.mem.indexOf(
        u8,
        persistence_storage[0..persistence.len],
        "TASK-SECRET",
    ) == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        persistence_storage[0..persistence.len],
        "NEXT-SECRET",
    ) != null);

    var replacement = try models_contract.OwnedConfig.initOwned(
        std.testing.allocator,
        .metask,
        .anthropic_messages,
        try std.testing.allocator.dupe(u8, "fixture-model"),
        try std.testing.allocator.dupe(
            u8,
            models_contract.metask_anthropic_messages_url,
        ),
        2,
        try std.testing.allocator.dupe(u8, "NEXT-SECRET"),
        "",
    );
    errdefer replacement.deinit();
    try TestSupport.prepareMetaskDefault(&control, 2);
    try control.beginDefaultExecutionReplacement();
    try control.prepareExecutionInstall(replacement.input());
    try std.testing.expect(persistence.commits >= 2);
    try std.testing.expect(std.mem.indexOf(
        u8,
        persistence_storage[0..persistence.len],
        "NEXT-SECRET",
    ) == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        product_schedule.testing.item(&control.schedule, id).?.input,
        "NEXT-SECRET",
    ) == null);
    control.installExecutionNoFail(&replacement);
    control.execution_state.recordDefaultAuthorityNoFail(
        control.custom_providers.defaultAuthority().?,
    );
    control.endExecutionReplacementNoFail();
    control.finishAccountCommitNoFail();
    try std.testing.expectEqual(@as(u64, 2), control.execution_state.generation());

    const blocked_id = try control.createScheduledTask(.{
        .title = "Use BLOCKED-SECRET",
        .binding = TestSupport.scheduledBinding(&control),
        .permission_profile = .approval_required,
        .input = "Review BLOCKED-SECRET",
        .recurrence = .{ .once = .{ .at_unix_seconds = 3_000 } },
    });
    var blocked = try models_contract.OwnedConfig.initOwned(
        std.testing.allocator,
        .metask,
        .anthropic_messages,
        try std.testing.allocator.dupe(u8, "fixture-model"),
        try std.testing.allocator.dupe(
            u8,
            models_contract.metask_anthropic_messages_url,
        ),
        3,
        try std.testing.allocator.dupe(u8, "BLOCKED-SECRET"),
        "",
    );
    var blocked_owned = true;
    defer if (blocked_owned) blocked.deinit();
    try TestSupport.prepareMetaskDefault(&control, 3);
    persistence.result = .failed;
    try control.beginDefaultExecutionReplacement();
    try std.testing.expectError(
        error.ScheduledTaskPersistenceFailed,
        control.prepareExecutionInstall(blocked.input()),
    );
    control.execution_state.rejectReplacementNoFail(
        .schedule_persistence_failed,
    );
    try std.testing.expectEqual(@as(u64, 2), control.execution_state.generation());
    try std.testing.expect(std.mem.indexOf(
        u8,
        product_schedule.testing.item(&control.schedule, blocked_id).?.input,
        "BLOCKED-SECRET",
    ) != null);
    control.endExecutionReplacementNoFail();
    control.finishAccountCommitNoFail();
    try std.testing.expect(!control.canCreateTask());
    try std.testing.expectEqual(
        SchedulePersistenceHealth.write_failed,
        control.schedule.persistenceHealth(),
    );

    blocked.deinit();
    blocked_owned = false;
    persistence.result = .committed;
    product_schedule.testing.setPersistenceHealth(&control.schedule, .ready);
    product_schedule.testing.overwriteInputPrefix(
        &control.schedule,
        id,
        "NEXT-SECRET",
    );
    try control.beginDefaultExecutionReplacement();
    control.commitAccountFactNoFail(.{
        .kind = .signed_out,
        .view = .{ .state = .signed_out },
    });
    control.setMetaskAuthorizationUnavailable();
    try control.prepareExecutionClear();
    try std.testing.expect(std.mem.indexOf(
        u8,
        persistence_storage[0..persistence.len],
        "NEXT-SECRET",
    ) == null);
    control.clearExecutionNoFail();
    control.endExecutionReplacementNoFail();
    control.finishAccountCommitNoFail();
    try std.testing.expect(!control.execution_state.ready());
}

test "Scheduled Task ignores Product binding generation drift for stable source authority" {
    var control = try testRuntime();
    defer control.deinit();
    var automatic_tmp = std.testing.tmpDir(.{});
    defer automatic_tmp.cleanup();
    var automatic_root_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const automatic_root_len = try automatic_tmp.dir.realPath(
        std.testing.io,
        &automatic_root_storage,
    );
    var automatic_root = try product_workspace.AutomaticRoot.open(
        std.testing.io,
        std.testing.allocator,
        automatic_root_storage[0..automatic_root_len],
    );
    defer automatic_root.deinit();
    var clock: TestScheduleClock = .{ .now = 1_000 };
    var persistence: TestSchedulePersistence = .{};
    product_schedule.testing.configure(
        &control.schedule,
        clock.timer(),
        persistence.capability(),
        .ready,
    );
    product_workspace.testing.installAutomaticRoot(
        &control.workspace,
        &automatic_root,
    );
    control.setScheduleBackgroundAvailableNoFail(true);
    const id = try control.createScheduledTask(.{
        .title = "Review current work",
        .binding = TestSupport.scheduledBinding(&control),
        .permission_profile = .approval_required,
        .input = "Review current work",
        .recurrence = .{ .once = .{ .at_unix_seconds = 2_000 } },
    });
    try std.testing.expectEqual(@as(u64, 2_000), clock.armed_at.?);

    execution_state.testing.setGeneration(&control.execution_state, 2);
    try std.testing.expect(!control.schedule.refreshBindingNoFail(
        control.scheduleExecutionBinding(),
        control.scheduleRedaction(),
    ));

    const item = product_schedule.testing.item(&control.schedule, id).?;
    try std.testing.expect(item.enabled);
    try std.testing.expectEqual(product_schedule.Health.ready, item.health);
    try std.testing.expect(item.failure_reason == null);
    try std.testing.expectEqual(@as(u64, 2_000), item.next_run_at_unix_seconds.?);
    try std.testing.expectEqual(@as(u64, 2_000), clock.armed_at.?);
    try std.testing.expectEqual(@as(usize, 1), persistence.commits);
}

test "Skill catalog snapshot reports redaction without exposing credential bytes" {
    var control = try testRuntime();
    defer control.deinit();
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
    try skill_runtime.Runtime.writeCatalogProjection(&writer, control.skillTextProjection(), .{
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

test "unreadable Skill stores forbid every Workspace allocation until a strict reload proves the ids in use" {
    test_agent_runtime.io = std.testing.io;
    var directory_b = std.testing.tmpDir(.{});
    defer directory_b.cleanup();
    var directory_store = std.testing.tmpDir(.{});
    defer directory_store.cleanup();
    var b_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const b_path = b_buffer[0..try directory_b.dir.realPath(std.testing.io, &b_buffer)];
    var store_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const store_path = store_buffer[0..try directory_store.dir.realPath(std.testing.io, &store_buffer)];
    // A Skill store already names Workspace id 1, whatever history survives.
    var inventory = skill_runtime.testing.ManagementInventory.init(std.testing.allocator, .{});
    defer inventory.deinit();
    const install_id: skill_runtime.InstallId = @splat(7);
    _ = try inventory.add(.{
        .install_id = install_id,
        .source_kind = .local_directory,
        .scope = .{ .project = .{ .workspace_id = 1, .workspace_epoch = 1 } },
        .target_entry = "review",
        .content_hash = @splat('a'),
        .installed_at_unix_seconds = 1,
    });
    var asset_buffer: [8192]u8 = undefined;
    var asset_file: skill_runtime.testing.ManagementFileStore = .{ .io = std.testing.io, .dir = directory_store.dir };
    try asset_file.commit(try skill_runtime.testing.encodeManagement(&asset_buffer, &inventory));
    {
        // Lost history plus an unreadable Skill store: no id can be proven free,
        // so neither a Manual nor an Automatic Workspace may be allocated.
        var replacement = try Runtime.init(std.testing.allocator, std.testing.io, &test_agent_runtime, testLimits(), .{
            .skill_management = .{ .file_store = &asset_file, .staging_root = store_path, .restore_failed = true },
        });
        defer replacement.deinit();
        try std.testing.expectEqual(SkillManagementHealth.read_failed, replacement.skill.managementHealth());
        try std.testing.expect(!replacement.skill.identitySourceTrusted());
        try std.testing.expectError(error.WorkspaceIdentityUntrusted, replacement.openWorkspace(.{ .workspace_root = b_path, .trust = .explicitly_trusted }));
        try std.testing.expectError(error.WorkspaceIdentityUntrusted, replacement.prepareAutomaticWorkspace());
        try std.testing.expectEqual(@as(usize, 0), replacement.workspace.count(.manual));
    }
    // A strict reload of the same store lifts the ban; the allocator now starts
    // above every id the store names, and the orphaned record stays inert.
    const canonical_assets = (try asset_file.loadAlloc(std.testing.allocator)).?;
    defer std.testing.allocator.free(canonical_assets);
    var restored = try Runtime.init(std.testing.allocator, std.testing.io, &test_agent_runtime, testLimits(), .{
        .skill_management = .{ .file_store = &asset_file, .staging_root = store_path, .restored_bytes = canonical_assets },
    });
    defer restored.deinit();
    try std.testing.expect(restored.skill.identitySourceTrusted());
    try std.testing.expectEqual(@as(u64, 2), try restored.openWorkspace(.{ .workspace_root = b_path, .trust = .explicitly_trusted }));
    try std.testing.expectError(error.UnknownWorkspace, restored.uninstallSkill(install_id));
}

test "Skill management health failure advances Product revision exactly once" {
    var control = try testRuntime();
    defer control.deinit();
    const previous_health = control.skill.managementHealth();
    const before_failure = control.revision;
    control.skill.testSetManagementHealth(.outcome_unknown);
    control.publishSkillManagementChanges(previous_health);
    try std.testing.expectEqual(before_failure + 1, control.revision);
    try std.testing.expectEqual(
        SkillManagementHealth.outcome_unknown,
        control.skill.managementHealth(),
    );

    const before_rejection = control.revision;
    control.publishSkillManagementChanges(.outcome_unknown);
    try std.testing.expectEqual(before_rejection, control.revision);
}

test "Skill recovery phase changes publish without a health change and match the wire fixture" {
    var control = try testRuntime();
    defer control.deinit();
    control.skill.testSetManagementHealth(.ready);
    const before = control.revision;
    try control.skill.testAddRecoveryAsset();
    control.publishSkillManagementChanges(.ready);
    try std.testing.expectEqual(before + 1, control.revision);
    control.publishSkillManagementChanges(.ready);
    try std.testing.expectEqual(before + 1, control.revision);
    var buffer: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try control.writeSkillManagement(&writer);
    var projection = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, writer.buffered(), .{});
    defer projection.deinit();
    const encoded = try std.json.Stringify.valueAlloc(std.testing.allocator, projection.value.object.get("assets").?.array.items[0], .{});
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings(std.mem.trim(u8, contract_fixture.skill_recovery_required, "\r\n"), encoded);
}

fn installTestCommittedSkillAuthorities(control: *Runtime) !void {
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
        control.allocator,
        .{
            .revision = "catalog-1",
            .health = .healthy,
            .skills = &source_skills,
            .issues = &.{},
            .storage = undefined,
        },
        1,
        &.{},
        catalogSnapshotLimits(control.limits),
        control.limits.max_projection_bytes - control.projection_bytes,
    );
    errdefer personal_catalog.deinit();
    var workspace_catalog = try personal_catalog.clone(
        control.allocator,
        catalogSnapshotLimits(control.limits),
        control.limits.max_projection_bytes -
            control.projection_bytes -
            personal_catalog.projected_bytes,
    );
    errdefer workspace_catalog.deinit();

    control.skill.testInstallPersonalSnapshot(
        personal_catalog,
        control.skillProjectionBudget(),
    );
    personal_catalog = undefined;
    try control.skill.testInstallWorkspaceSnapshot(
        1,
        1,
        workspace_catalog,
        control.skillProjectionBudget(),
    );
    workspace_catalog = undefined;
}

fn testWorkspaceSkillProjection(control: *Runtime) CatalogProjection {
    return control.skill.workspaceCatalogProjection(1, 1) catch unreachable;
}

test "definite Skill enablement persistence failure preserves committed authorities" {
    var control = try testRuntime();
    defer control.deinit();
    try installTestCommittedSkillAuthorities(&control);

    control.skill.testNoteEnablementPersistenceFailure(
        error.WriteFailed,
        control.skillProjectionBudget(),
    );

    try std.testing.expectEqual(SkillEnablementHealth.write_failed, control.skill.enablementHealth());
    try std.testing.expectEqual(
        CatalogAvailability.ready,
        control.skill.personalCatalogProjection().availability,
    );
    try std.testing.expectEqual(
        CatalogAvailability.ready,
        testWorkspaceSkillProjection(&control).availability,
    );
    try std.testing.expectEqualStrings(
        "catalog-1",
        control.skill.personalCatalogProjection().revision,
    );
    try std.testing.expectEqualStrings(
        "catalog-1",
        testWorkspaceSkillProjection(&control).revision,
    );
}

test "unknown Skill enablement persistence outcome freezes authorities" {
    var control = try testRuntime();
    defer control.deinit();
    try installTestCommittedSkillAuthorities(&control);

    control.skill.testNoteEnablementPersistenceFailure(
        error.PersistenceOutcomeUnknown,
        control.skillProjectionBudget(),
    );

    try std.testing.expectEqual(SkillEnablementHealth.outcome_unknown, control.skill.enablementHealth());
    try std.testing.expectEqual(
        CatalogAvailability.unavailable,
        control.skill.personalCatalogProjection().availability,
    );
    try std.testing.expectEqual(
        CatalogAvailability.unavailable,
        testWorkspaceSkillProjection(&control).availability,
    );
    try std.testing.expectError(
        error.PersistenceFailed,
        control.setSkillEnabled(.{
            .scope = .personal,
            .skill_policy_key = "review",
            .state = .disabled,
            .expected_catalog_revision = "catalog-1",
            .expected_selection_revision = 1,
        }),
    );
}

test "Skill enablement retries a definite file write failure without discarding committed policy" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var directory_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory_len = try tmp.dir.realPath(std.testing.io, &directory_storage);
    var file_store = try skill_runtime.EnablementFileStore.init(std.testing.io, directory_storage[0..directory_len]);
    defer file_store.deinit();
    var control = try testRuntime();
    defer control.deinit();
    control.skill.testSetEnablementPersistence(&file_store);
    try installTestCommittedSkillAuthorities(&control);

    // A directory at the canonical file name makes atomic rename fail before
    // publication on every platform, without a production fault-injection port.
    try tmp.dir.createDir(std.testing.io, "skill-enablement.json", .default_dir);
    const disable: SkillEnablementMutation = .{
        .scope = .personal,
        .skill_policy_key = "review",
        .state = .disabled,
        .expected_catalog_revision = "catalog-1",
        .expected_selection_revision = 1,
    };
    const before_failure = control.revision;
    try std.testing.expectError(error.WriteFailed, control.setSkillEnabled(disable));
    try std.testing.expectEqual(before_failure + 1, control.revision);
    try std.testing.expectEqual(SkillEnablementHealth.write_failed, control.skill.enablementHealth());
    try std.testing.expect(control.skill.personalCatalogProjection().skills[0].enabled);
    try std.testing.expect(testWorkspaceSkillProjection(&control).skills[0].enabled);
    var no_op = disable;
    no_op.state = .enabled;
    try std.testing.expectEqual(@as(u64, 1), try control.setSkillEnabled(no_op));
    try std.testing.expectEqual(SkillEnablementHealth.write_failed, control.skill.enablementHealth());
    try std.testing.expectEqual(before_failure + 1, control.revision);
    try std.testing.expectError(error.WriteFailed, control.setSkillEnabled(disable));
    try std.testing.expectEqual(before_failure + 1, control.revision);

    try tmp.dir.deleteDir(std.testing.io, "skill-enablement.json");
    try std.testing.expectEqual(@as(u64, 2), try control.setSkillEnabled(disable));
    try std.testing.expectEqual(SkillEnablementHealth.ready, control.skill.enablementHealth());
    try std.testing.expect(!control.skill.personalCatalogProjection().skills[0].enabled);
    try std.testing.expect(!testWorkspaceSkillProjection(&control).skills[0].enabled);
    const saved = (try file_store.loadAlloc(std.testing.allocator)).?;
    defer std.testing.allocator.free(saved);
    try std.testing.expect(std.mem.indexOf(u8, saved, "review") != null);
}

test "Workspace Skill enablement uses double revision CAS and leaves pinned catalogs unchanged" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var directory_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory_len = try tmp.dir.realPath(std.testing.io, &directory_storage);
    var file_store = try skill_runtime.EnablementFileStore.init(
        std.testing.io,
        directory_storage[0..directory_len],
    );
    defer file_store.deinit();

    var control = try testRuntime();
    defer control.deinit();
    control.skill.testSetEnablementPersistence(&file_store);
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
    var workspace_catalog = try CatalogSnapshot.init(
        control.allocator,
        .{
            .revision = "catalog-1",
            .health = .healthy,
            .skills = &source_skills,
            .issues = &.{},
            .storage = undefined,
        },
        1,
        &.{},
        catalogSnapshotLimits(control.limits),
        control.limits.max_projection_bytes - control.projection_bytes,
    );
    var pinned = try workspace_catalog.clone(
        control.allocator,
        catalogSnapshotLimits(control.limits),
        control.limits.max_projection_bytes -
            control.projection_bytes -
            workspace_catalog.projected_bytes,
    );
    defer pinned.deinit();
    try control.skill.testInstallWorkspaceSnapshot(
        1,
        1,
        workspace_catalog,
        control.skillProjectionBudget(),
    );
    workspace_catalog = undefined;

    const next_revision = try control.setSkillEnabled(.{
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
        testWorkspaceSkillProjection(&control).selection_revision.?,
    );
    try std.testing.expect(!testWorkspaceSkillProjection(&control).skills[0].enabled);
    try std.testing.expectEqual(@as(u64, 1), pinned.selection_revision);
    try std.testing.expect(pinned.skills[0].enabled);
    try std.testing.expectError(
        error.StaleCatalog,
        control.setSkillEnabled(.{
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
    var file_store = try skill_runtime.EnablementFileStore.init(
        std.testing.io,
        directory_storage[0..directory_len],
    );
    defer file_store.deinit();

    var control = try testRuntime();
    defer control.deinit();
    control.skill.testSetEnablementPersistence(&file_store);
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
    var personal_catalog = try CatalogSnapshot.init(
        control.allocator,
        .{
            .revision = "personal-1",
            .health = .healthy,
            .skills = &source_skills,
            .issues = &.{},
            .storage = undefined,
        },
        1,
        &.{},
        catalogSnapshotLimits(control.limits),
        control.limits.max_projection_bytes - control.projection_bytes,
    );
    control.skill.testInstallPersonalSnapshot(
        personal_catalog,
        control.skillProjectionBudget(),
    );
    personal_catalog = undefined;

    var workspace_catalog = try CatalogSnapshot.init(
        control.allocator,
        .{
            .revision = "workspace-1",
            .health = .healthy,
            .skills = &source_skills,
            .issues = &.{},
            .storage = undefined,
        },
        1,
        &.{},
        catalogSnapshotLimits(control.limits),
        control.limits.max_projection_bytes - control.projection_bytes,
    );
    try control.skill.testInstallWorkspaceSnapshot(
        1,
        1,
        workspace_catalog,
        control.skillProjectionBudget(),
    );
    workspace_catalog = undefined;

    try std.testing.expectEqual(@as(u64, 2), try control.setSkillEnabled(.{
        .scope = .personal,
        .skill_policy_key = "review",
        .state = .disabled,
        .expected_catalog_revision = "personal-1",
        .expected_selection_revision = 1,
    }));
    try std.testing.expectEqual(@as(u64, 2), control.skill.personalCatalogProjection().selection_revision.?);
    try std.testing.expectEqual(@as(u64, 2), testWorkspaceSkillProjection(&control).selection_revision.?);
    try std.testing.expect(!control.skill.personalCatalogProjection().skills[0].enabled);
    try std.testing.expect(!testWorkspaceSkillProjection(&control).skills[0].enabled);

    try std.testing.expectEqual(@as(u64, 3), try control.setSkillEnabled(.{
        .scope = .{ .project = .{
            .workspace_id = 1,
            .expected_workspace_epoch = 1,
        } },
        .skill_policy_key = "review",
        .state = .enabled,
        .expected_catalog_revision = "workspace-1",
        .expected_selection_revision = 2,
    }));
    try std.testing.expect(!control.skill.personalCatalogProjection().skills[0].enabled);
    try std.testing.expect(testWorkspaceSkillProjection(&control).skills[0].enabled);
    try std.testing.expectEqual(@as(u64, 2), control.skill.personalCatalogProjection().selection_revision.?);
    try std.testing.expectEqual(@as(u64, 3), testWorkspaceSkillProjection(&control).selection_revision.?);

    try std.testing.expectEqual(@as(u64, 4), try control.setSkillEnabled(.{
        .scope = .{ .project = .{
            .workspace_id = 1,
            .expected_workspace_epoch = 1,
        } },
        .skill_policy_key = "review",
        .state = .inherit,
        .expected_catalog_revision = "workspace-1",
        .expected_selection_revision = 3,
    }));
    try std.testing.expect(!testWorkspaceSkillProjection(&control).skills[0].enabled);

    var management_storage: [8192]u8 = undefined;
    var management_writer = std.Io.Writer.fixed(&management_storage);
    try control.writeSkillManagement(&management_writer);
    const management_projection = management_writer.buffered();
    try std.testing.expect(std.mem.indexOf(
        u8,
        management_projection,
        "\"enabled\":false,\"enablementState\":\"disabled\",\"canSetEnabled\":true",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        management_projection,
        "\"enabled\":false,\"enablementState\":\"inherit\",\"canSetEnabled\":true",
    ) != null);
}

test "User Skill mutation does not require every Workspace to have committed authority" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var directory_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory_len = try tmp.dir.realPath(std.testing.io, &directory_storage);
    var file_store = try skill_runtime.EnablementFileStore.init(
        std.testing.io,
        directory_storage[0..directory_len],
    );
    defer file_store.deinit();

    var control = try testRuntime();
    defer control.deinit();
    control.skill.testSetEnablementPersistence(&file_store);
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
        control.allocator,
        .{
            .revision = "personal-1",
            .health = .healthy,
            .skills = &source_skills,
            .issues = &.{},
            .storage = undefined,
        },
        1,
        &.{},
        catalogSnapshotLimits(control.limits),
        control.limits.max_projection_bytes - control.projection_bytes,
    );
    control.skill.testInstallPersonalSnapshot(
        personal_catalog,
        control.skillProjectionBudget(),
    );
    personal_catalog = undefined;

    try std.testing.expectEqual(@as(u64, 2), try control.setSkillEnabled(.{
        .scope = .personal,
        .skill_policy_key = "review",
        .state = .disabled,
        .expected_catalog_revision = "personal-1",
        .expected_selection_revision = 1,
    }));
    try std.testing.expectEqual(
        @as(u64, 2),
        control.skill.enablementRevision(.{ .project = .{
            .workspace_id = 1,
            .workspace_epoch = 1,
        } }),
    );
    try std.testing.expectEqual(
        CatalogAvailability.uninitialized,
        testWorkspaceSkillProjection(&control).availability,
    );
}

test "credential release permanently scrubs catalog and every Skill history field" {
    var control = try testRuntime();
    defer control.deinit();
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
    var workspace_catalog = try CatalogSnapshot.init(
        control.allocator,
        .{
            .revision = "safe-revision",
            .health = .healthy,
            .skills = &source_skills,
            .issues = &.{},
            .storage = undefined,
        },
        1,
        &.{},
        catalogSnapshotLimits(control.limits),
        control.limits.max_projection_bytes - control.projection_bytes,
    );
    const task_catalog = try workspace_catalog.clone(
        control.allocator,
        catalogSnapshotLimits(control.limits),
        control.limits.max_projection_bytes -
            control.projection_bytes -
            workspace_catalog.projected_bytes,
    );
    try control.skill.testInstallWorkspaceSnapshot(
        1,
        1,
        workspace_catalog,
        control.skillProjectionBudget(),
    );
    workspace_catalog = undefined;
    control.projection_bytes += task_catalog.projected_bytes;
    const task = &control.task_runtime.tasks[0].?;
    task.runtime.attached().?.pinned_catalog = task_catalog;
    const run = &task.durable.runs[0].?;
    const history_input: RunInputRecord = history: {
        const skill_id = try control.copyBounded(
            "history-SECRET-KEY",
            control.limits.max_catalog_projection_bytes,
        );
        errdefer control.freeTracked(skill_id);
        const revision = try control.copyBounded(
            "revision-SECRET-KEY",
            control.limits.max_catalog_projection_bytes,
        );
        errdefer control.freeTracked(revision);
        const invocation = try control.copyBounded(
            "review-SECRET-KEY",
            control.limits.max_catalog_projection_bytes,
        );
        errdefer control.freeTracked(invocation);
        const display = try control.copyBounded(
            "Review SECRET-KEY",
            control.limits.max_catalog_projection_bytes,
        );
        errdefer control.freeTracked(display);
        const values = try control.allocator.alloc([]u8, 1);
        errdefer control.allocator.free(values);
        values[0] = try control.copyBounded(
            "SECRET-KEY target",
            control.limits.max_user_message_bytes,
        );
        errdefer control.freeTracked(values[0]);
        break :history .{ .skill = .{
            .skill_id = skill_id,
            .catalog_revision = revision,
            .invocation_name = invocation,
            .display_name = display,
            .argument_values = values,
        } };
    };
    control.task_runtime.testDeinitRunInput(
        &run.input,
        control.taskRuntimeReleaseEffects(),
    );
    run.input = history_input;

    control.redactAllProductProjectionsNoFail("SECRET-KEY");
    execution_state.testing.clearExecutionNoFail(&control.execution_state);
    var detached = task.runtime.detach(.cold_start);
    var detached_execution = detached.execution;
    detached_execution.deinit();
    if (detached.pinned_catalog) |*snapshot| {
        control.projection_bytes -= snapshot.projected_bytes;
        snapshot.deinit();
    }
    run.redaction_secret = &.{};

    var storage: [16 * 1024]u8 = undefined;
    const snapshot = try control.writeAggregateFixture(&storage);
    try std.testing.expect(
        std.mem.indexOf(u8, snapshot, "SECRET-KEY") == null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, snapshot, "\"redacted\":true") != null,
    );
    try std.testing.expect(testWorkspaceSkillProjection(&control).redacted);
    try std.testing.expect(task.runtime.pinnedCatalogConst() == null);
}

test "mutation admission rejects stale execution and binding facts" {
    var control = try testRuntime();
    defer control.deinit();

    try std.testing.expectError(
        error.ExecutionGenerationMismatch,
        control.createTaskInWorkspace(
            1,
            1,
            0,
            control.newTaskAdmissionView().active_selection_revision,
            null,
            null,
            null,
            .{ .interactive = null },
        ),
    );
    try std.testing.expectError(
        error.ExecutionGenerationMismatch,
        control.createTaskInWorkspace(
            1,
            1,
            2,
            control.newTaskAdmissionView().active_selection_revision,
            null,
            null,
            null,
            .{ .interactive = null },
        ),
    );
    try std.testing.expectError(
        error.WorkspaceEpochMismatch,
        control.createTaskInWorkspace(
            1,
            2,
            1,
            control.newTaskAdmissionView().active_selection_revision,
            null,
            null,
            null,
            .{ .interactive = null },
        ),
    );
    try std.testing.expectError(
        error.BindingEpochMismatch,
        control.runTaskAtBinding(3, 2, .{ .text = "stale continuation" }),
    );
}

test "Product view reads preserve Task deletion lifecycle guards and projection accounting" {
    var control = try testRuntime();
    defer control.deinit();

    try std.testing.expectError(error.TaskBusy, control.setTaskArchived(3, true));
    try std.testing.expectError(error.TaskNotArchived, control.deleteTask(3));
    try std.testing.expectError(error.InvalidTaskTitle, control.renameTask(3, "  \n  "));
    try std.testing.expectError(error.InvalidTaskTitle, control.renameTask(3, "bad\ttitle"));
    try std.testing.expectError(error.InvalidTaskTitle, control.renameTask(3, &.{0xff}));

    try control.renameTask(3, "Review release readiness");
    try std.testing.expectEqualStrings("Review release readiness", control.task_runtime.tasks[0].?.durable.title);

    control.task_runtime.tasks[0].?.runtime.active_run_id = 0;
    const completed = &control.task_runtime.tasks[0].?.durable.runs[0].?;
    _ = commitTerminal(completed, .completed, .completed, null, .reusable, "", false);
    finalizeTestTerminalEvents(&control);
    try control.setTaskArchived(3, true);
    try std.testing.expect(control.task_runtime.tasks[0].?.durable.archived);

    control.task_runtime.tasks[0].?.runtime.active_operation = .{ .restore = .{ .id = 1 } };
    try std.testing.expectError(error.TaskBusy, control.setTaskArchived(3, false));
    control.task_runtime.tasks[0].?.runtime.active_operation = .none;
    control.task_runtime.tasks[0].?.deletion = .failed;
    try control.setTaskArchived(3, false);
    try std.testing.expectEqual(task_test_deletion.State.idle, control.task_runtime.tasks[0].?.deletion);
    try control.setTaskArchived(3, true);
    control.releaseTaskAttachmentNoFail(&control.task_runtime.tasks[0].?, .cold_start);
    var deletion_lease = try control.task_runtime.tasks[0].?.runtime.worker_leases.acquire();
    try control.deleteTask(3);
    try std.testing.expect(control.task_runtime.tasks[0] != null);
    try std.testing.expectError(error.TaskBusy, control.renameTask(3, "too late"));
    deletion_lease.deinit();
    const tracked_before_delete = control.projection_bytes;
    _ = control.currentRevision();
    try std.testing.expect(control.task_runtime.tasks[0] != null);
    control.syncLifecycle();
    try std.testing.expect(control.task_runtime.tasks[0] == null);
    try std.testing.expect(control.projection_bytes < tracked_before_delete);
    try std.testing.expectError(error.UnknownTask, control.renameTask(3, "gone"));
}

test "Run admission reserves a stable generation and rolls back every fallible allocation" {
    var control = try testRuntime();
    defer control.deinit();
    const task = &control.task_runtime.tasks[0].?;
    const tracked_before = control.projection_bytes;
    const generation_before = task.durable.next_run_generation;
    var oversized_prompt: [1025]u8 = undefined;
    @memset(&oversized_prompt, 'x');
    try std.testing.expectError(
        error.ProjectionCapacity,
        control.reserveRunRecord(task, .{ .text = &oversized_prompt }),
    );
    try std.testing.expectEqual(tracked_before, control.projection_bytes);
    try std.testing.expectEqual(generation_before, task.durable.next_run_generation);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const allocator = control.allocator;
    control.allocator = failing.allocator();
    defer control.allocator = allocator;
    try std.testing.expectError(
        error.OutOfMemory,
        control.reserveRunRecord(task, .{ .text = "will fail" }),
    );
    control.allocator = allocator;
    try std.testing.expectEqual(tracked_before, control.projection_bytes);
    try std.testing.expectEqual(generation_before, task.durable.next_run_generation);

    const Clock = struct {
        fn now(context: ?*anyopaque) ?u64 {
            const value: *u64 = @ptrCast(@alignCast(context.?));
            return value.*;
        }
    };
    var submitted_at_unix_ms: u64 = 1_789_436_300_000;
    control.run_clock = .{
        .context = &submitted_at_unix_ms,
        .now_unix_ms_fn = Clock.now,
    };
    const slot = try control.reserveRunRecord(task, .{ .text = "reserved" });
    const first_generation = task.durable.runs[slot].?.generation;
    try std.testing.expectEqual(
        @as(?u64, submitted_at_unix_ms),
        task.durable.runs[slot].?.submitted_at_unix_ms,
    );
    try std.testing.expectEqual(
        task.durable.execution_generation,
        task.durable.runs[slot].?.execution_generation,
    );
    try std.testing.expectEqual(
        task.durable.execution_protocol,
        task.durable.runs[slot].?.execution_protocol,
    );
    try std.testing.expectEqualStrings(
        task.durable.execution_model,
        task.durable.runs[slot].?.execution_model,
    );
    control.discardRunRecord(task, slot);
    const reused_slot = try control.reserveRunRecord(
        task,
        .{ .text = "reserved again" },
    );
    try std.testing.expectEqual(slot, reused_slot);
    try std.testing.expect(task.durable.runs[reused_slot].?.generation > first_generation);
    try std.testing.expectError(
        error.RunCapacity,
        control.reserveRunRecord(task, .{ .text = "overflow" }),
    );
    control.discardRunRecord(task, reused_slot);
}

test "Runtime starts without execution and fails Task admission closed" {
    test_agent_runtime.io = std.testing.io;
    var control = try Runtime.init(
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
    defer control.deinit();
    try std.testing.expectError(
        error.ExecutionUnavailable,
        control.createTask(.{
            .workspace_root = "/tmp",
            .trust = .{ .temporary = "/tmp" },
        }),
    );
    try std.testing.expectEqual(@as(u64, 0), control.currentRevision());
}

test "Runtime publishes a user custom provider as an independent execution source" {
    test_agent_runtime.io = std.testing.io;
    var control = try Runtime.init(
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
    defer control.deinit();
    var execution = try models_contract.OwnedConfig.initOwned(
        std.testing.allocator,
        .custom_provider,
        .openai_chat_completions,
        try std.testing.allocator.dupe(u8, "gpt-5"),
        try std.testing.allocator.dupe(u8, "https://api.openai.com/v1/chat/completions"),
        1,
        try std.testing.allocator.dupe(u8, "secret-key"),
        "fixture-provider",
    );
    errdefer execution.deinit();
    var prepared_binding = try control.prepareCustomProviderBinding(
        "provider-1",
        "gpt-5",
    );
    var prepared_binding_owned = true;
    defer if (prepared_binding_owned) prepared_binding.deinit();
    try control.beginDefaultExecutionReplacement();
    try control.prepareExecutionInstall(execution.input());
    control.installCustomProviderExecutionNoFail(
        &execution,
        &prepared_binding,
    );
    prepared_binding_owned = false;
    control.endExecutionReplacementNoFail();
    const view = control.accountView();
    try std.testing.expectEqual(models_contract.Source.custom_provider, control.execution_state.activeSource().?);
    try std.testing.expectEqual(account_contract.AccountState.checking, view.state);
    // An active execution installed without a Models desired selection cannot
    // authorize new Task admission by itself.
    try std.testing.expect(!control.canCreateTask());
    try std.testing.expectEqualStrings(
        "provider-1",
        control.execution_state.selectedCustomProviderId(),
    );
    try std.testing.expect(control.customProviderExecutionActive("provider-1"));
    try std.testing.expect(!control.customProviderExecutionActive("connection-2"));
    try models_contract.validateCustomProviderSpec(.{
        .display_name = "Team OpenAI",
        .protocol = .openai_chat_completions,
        .normalized_base_url = "https://api.openai.com/v1/chat/completions",
    });
}

const TestCustomProviderVault = struct {
    const slot = "custom-provider-00000000000000000000000000000001";

    secret: [models_contract.Limits.credential_bytes]u8 = undefined,
    secret_len: usize = 0,
    present: bool = false,
    write_fails: bool = false,
    read_fails: bool = false,

    fn port(self: *@This()) models_ports.CredentialVault {
        return .{
            .context = self,
            .generate_slot_fn = generate,
            .store_fn = store,
            .get_fn = get,
            .delete_fn = delete,
        };
    }

    fn generate(
        _: *anyopaque,
        output: *[models_ports.credential_slot_bytes]u8,
    ) anyerror!void {
        @memcpy(output, slot);
    }

    fn store(
        context: *anyopaque,
        _: []const u8,
        secret: []const u8,
    ) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (self.write_fails) return error.WriteFailed;
        if (secret.len > self.secret.len) return error.WriteFailed;
        @memcpy(self.secret[0..secret.len], secret);
        self.secret_len = secret.len;
        self.present = true;
    }

    fn get(
        context: *anyopaque,
        _: []const u8,
        output: []u8,
    ) anyerror!?[]const u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (self.read_fails) return error.ReadFailed;
        if (!self.present) return null;
        if (self.secret_len > output.len) return error.ReadFailed;
        @memcpy(output[0..self.secret_len], self.secret[0..self.secret_len]);
        return output[0..self.secret_len];
    }

    fn delete(context: *anyopaque, _: []const u8) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        std.crypto.secureZero(u8, self.secret[0..self.secret_len]);
        self.secret_len = 0;
        self.present = false;
    }
};

test "automation installs one ordinary Custom Provider without publishing its credential" {
    if (!build_options.automation) return error.SkipZigTest;
    test_agent_runtime.io = std.testing.io;
    var control = try Runtime.init(
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
    defer control.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var directory_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory_len = try tmp.dir.realPath(std.testing.io, &directory_storage);
    var vault: TestCustomProviderVault = .{};
    try control.startCustomProviders(
        directory_storage[0..directory_len],
        vault.port(),
    );
    defer control.stopCustomProviders();

    const fixture: AutomationExecutionInput = .{
        .protocol = .anthropic_messages,
        .credential = "AUTOMATION-FIXTURE-SECRET",
        .model = "automation-model",
        .base_url = "http://127.0.0.1:43123/v1/messages",
    };
    try control.installAutomationExecution(fixture);

    const view = control.modelsView();
    try std.testing.expectEqual(@as(usize, 1), view.custom_providers.len);
    const provider = view.custom_providers[0];
    try std.testing.expectEqual(models_contract.CustomProviderState.ready, provider.state);
    try std.testing.expectEqual(models_contract.CustomModelTestStatus.connected, provider.models[0].test_status);
    try std.testing.expect(provider.models[0].ready);
    try std.testing.expectEqualStrings(fixture.model, provider.models[0].id);
    try std.testing.expectEqualStrings(fixture.base_url, provider.normalized_base_url);
    try std.testing.expectEqualStrings(provider.id, view.default_selection.?.source_id);
    try std.testing.expectEqualStrings(fixture.model, view.default_selection.?.model_id);
    const authority = control.custom_providers.defaultAuthority().?;
    try std.testing.expectEqual(models_contract.Source.custom_provider, authority.source);
    try std.testing.expect(authority.source_generation != 0);
    try std.testing.expect(authority.selection_revision != 0);
    try std.testing.expect(control.customProviderExecutionActive(provider.id));
    try std.testing.expect(control.newTaskAdmissionView().available);
    try std.testing.expect(control.executionGeneration() != 0);

    var snapshot_storage: [256 * 1024]u8 = undefined;
    const snapshot = try control.writeAggregateFixture(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, fixture.credential) == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "metask:automation-key") == null);

    const generation = control.executionGeneration();
    try std.testing.expectError(
        error.InvalidAutomationExecution,
        control.installAutomationExecution(fixture),
    );
    try std.testing.expectEqual(@as(usize, 1), control.modelsView().custom_providers.len);
    try std.testing.expectEqual(generation, control.executionGeneration());
    try std.testing.expectEqualStrings(fixture.credential, vault.secret[0..vault.secret_len]);
}

test "production rejects automation execution before observing fixture input" {
    if (build_options.automation) return error.SkipZigTest;
    test_agent_runtime.io = std.testing.io;
    var control = try Runtime.init(
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
    defer control.deinit();
    try std.testing.expectError(
        error.InvalidAutomationExecution,
        control.installAutomationExecution(.{
            .protocol = .anthropic_messages,
            .credential = "must-not-be-observed",
            .model = "must-not-be-observed",
            .base_url = "must-not-be-observed",
        }),
    );
    try std.testing.expectEqual(@as(u64, 0), control.executionGeneration());
    try std.testing.expectEqual(@as(usize, 0), control.modelsView().custom_providers.len);
}

test "automation cold restore rehydrates the persisted connection through credential replacement" {
    if (!build_options.automation) return error.SkipZigTest;
    test_agent_runtime.io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var directory_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory_len = try tmp.dir.realPath(std.testing.io, &directory_storage);
    const directory = directory_storage[0..directory_len];
    const fixture: AutomationExecutionInput = .{
        .protocol = .anthropic_messages,
        .credential = "AUTOMATION-RESTORE-SECRET",
        .model = "automation-restore-model",
        .base_url = "http://127.0.0.1:43124/v1/messages",
    };

    {
        var first = try Runtime.init(
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
        defer first.deinit();
        var first_vault: TestCustomProviderVault = .{};
        try first.startCustomProviders(directory, first_vault.port());
        defer first.stopCustomProviders();
        try first.installAutomationExecution(fixture);
    }

    {
        var restored = try Runtime.init(
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
        defer restored.deinit();
        var restored_vault: TestCustomProviderVault = .{};
        try restored.startCustomProviders(directory, restored_vault.port());
        defer restored.stopCustomProviders();
        try std.testing.expectEqual(
            models_contract.CustomProviderCredentialStatus.missing,
            restored.modelsView().custom_providers[0].credential_status,
        );

        try restored.installAutomationExecution(fixture);
        const view = restored.modelsView();
        try std.testing.expectEqual(@as(usize, 1), view.custom_providers.len);
        try std.testing.expectEqual(models_contract.CustomProviderState.ready, view.custom_providers[0].state);
        try std.testing.expect(view.default_selection != null);
        try std.testing.expect(restored.newTaskAdmissionView().available);
        try std.testing.expectEqualStrings(
            fixture.credential,
            restored_vault.secret[0..restored_vault.secret_len],
        );
    }
}

fn createReadyTestCustomProvider(
    control: *Runtime,
) !models_contract.CustomProviderSelectionCommand {
    try std.testing.expect(control.createCustomProviderWithCredential(
        "provider-secret",
        .{
            .display_name = "OpenAI",
            .protocol = .openai_responses,
            .normalized_base_url = "https://api.openai.com/v1/responses",
        },
    ).accepted);
    var view = control.custom_providers.views()[0];
    try std.testing.expect(control.submitCustomProviderCommand(.{
        .add_custom_model = .{
            .source_id = view.id,
            .expected_provider_revision = view.provider_revision,
            .expected_catalog_generation = view.catalog_generation,
            .model = .{ .id = "gpt-5", .display_name = "GPT-5" },
        },
    }).accepted);
    view = control.custom_providers.views()[0];
    const selection: models_contract.CustomProviderSelectionCommand = .{
        .source_id = TestCustomProviderVault.slot,
        .expected_provider_revision = view.provider_revision,
    };
    const probe_command: models_contract.CustomModelTestCommand = .{
        .model = .{ .source_id = selection.source_id, .model_id = "gpt-5" },
        .expected_provider_revision = selection.expected_provider_revision,
        .expected_source_generation = view.source_generation,
        .expected_catalog_generation = view.catalog_generation,
    };
    var probe = switch (control.beginCustomProviderProbe(.{
        .model = probe_command.model,
        .expected_provider_revision = probe_command.expected_provider_revision,
        .expected_source_generation = probe_command.expected_source_generation,
        .expected_catalog_generation = probe_command.expected_catalog_generation,
    })) {
        .ready => |execution| execution,
        .rejected => return error.TestUnexpectedResult,
    };
    defer probe.deinit();
    try std.testing.expect(control.completeCustomModelTest(probe_command, true).accepted);
    return selection;
}

test "Product Control atomically manages and installs a Custom Provider default" {
    test_agent_runtime.io = std.testing.io;
    var control = try Runtime.init(
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
    defer control.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var directory_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory_len = try tmp.dir.realPath(std.testing.io, &directory_storage);
    var vault: TestCustomProviderVault = .{};
    try control.startCustomProviders(
        directory_storage[0..directory_len],
        vault.port(),
    );
    defer control.stopCustomProviders();

    const selection = try createReadyTestCustomProvider(&control);
    const ready_connection = control.modelsView().custom_providers[0];
    try std.testing.expect(control.selectModelsDefault(.{
        .selection = .{ .source_id = selection.source_id, .model_id = "gpt-5" },
        .expected_selection_revision = control.modelsView().selection_revision,
        .expected_source_generation = ready_connection.source_generation,
        .expected_catalog_generation = ready_connection.catalog_generation,
    }).accepted);

    try std.testing.expectEqual(
        models_contract.Source.custom_provider,
        control.execution_state.activeSource().?,
    );
    try std.testing.expectEqualStrings(
        TestCustomProviderVault.slot,
        control.execution_state.selectedCustomProviderId(),
    );
    const rejected = control.submitCustomProviderCommand(.{ .update = .{
        .selection = selection,
        .spec = .{
            .display_name = "Renamed",
            .protocol = .openai_responses,
            .normalized_base_url = "https://api.openai.com/v1/responses",
        },
    } });
    // Models commits desired configuration without querying active consumers;
    // existing Tasks keep their owned binding while Product Control reconciles
    // the next admission default independently.
    try std.testing.expect(rejected.accepted);

    try control.beginDefaultExecutionReplacement();
    try control.prepareExecutionClear();
    control.clearExecutionNoFail();
    control.endExecutionReplacementNoFail();
    control.finishExecutionCommitNoFail();
    control.stopCustomProviders();
    try control.startCustomProviders(
        directory_storage[0..directory_len],
        vault.port(),
    );
    try std.testing.expectEqual(
        models_contract.Source.custom_provider,
        control.execution_state.activeSource().?,
    );
    try std.testing.expectEqualStrings(
        TestCustomProviderVault.slot,
        control.execution_state.selectedCustomProviderId(),
    );
}

test "credential replacement revokes Product Control admission after every durable revoke" {
    for ([_]bool{ false, true }) |vault_write_fails| {
        test_agent_runtime.io = std.testing.io;
        var control = try Runtime.init(
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
        defer control.deinit();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var directory_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const directory_len = try tmp.dir.realPath(std.testing.io, &directory_storage);
        var vault: TestCustomProviderVault = .{};
        try control.startCustomProviders(
            directory_storage[0..directory_len],
            vault.port(),
        );
        defer control.stopCustomProviders();

        const selection = try createReadyTestCustomProvider(&control);
        const ready_connection = control.modelsView().custom_providers[0];
        try std.testing.expect(control.selectModelsDefault(.{
            .selection = .{ .source_id = selection.source_id, .model_id = "gpt-5" },
            .expected_selection_revision = control.modelsView().selection_revision,
            .expected_source_generation = ready_connection.source_generation,
            .expected_catalog_generation = ready_connection.catalog_generation,
        }).accepted);
        try std.testing.expect(control.canCreateTask());
        try std.testing.expect(control.newTaskAdmissionView().active_selection_revision != 0);

        vault.write_fails = vault_write_fails;
        const result = control.replaceCustomProviderCredential("next-secret", selection);
        if (vault_write_fails) {
            try std.testing.expect(!result.accepted);
            try std.testing.expectEqual(
                models_contract.ManagementError.credential_write_failed,
                result.error_code.?,
            );
        } else {
            try std.testing.expect(result.accepted);
        }

        try std.testing.expect(control.modelsView().default_selection == null);
        const admission = control.newTaskAdmissionView();
        try std.testing.expect(!admission.available);
        try std.testing.expect(admission.active_model_ref == null);
        try std.testing.expectEqual(@as(u64, 0), admission.active_generation);
        try std.testing.expectEqual(@as(u64, 0), admission.active_selection_revision);
        try std.testing.expectError(
            error.ExecutionUnavailable,
            control.createTask(.{
                .workspace_root = "/tmp",
                .trust = .{ .temporary = "/tmp" },
            }),
        );
    }
}

test "Account authorization loss leaves a custom Models default available" {
    test_agent_runtime.io = std.testing.io;
    var control = try Runtime.init(
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
    defer control.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var directory_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory_len = try tmp.dir.realPath(std.testing.io, &directory_storage);
    var vault: TestCustomProviderVault = .{};
    try control.startCustomProviders(
        directory_storage[0..directory_len],
        vault.port(),
    );
    defer control.stopCustomProviders();

    const connection = try createReadyTestCustomProvider(&control);
    const ready_connection = control.modelsView().custom_providers[0];
    try std.testing.expect(control.selectModelsDefault(.{
        .selection = .{ .source_id = connection.source_id, .model_id = "gpt-5" },
        .expected_selection_revision = control.modelsView().selection_revision,
        .expected_source_generation = ready_connection.source_generation,
        .expected_catalog_generation = ready_connection.catalog_generation,
    }).accepted);

    control.commitAccountFactNoFail(.{
        .kind = .signed_out,
        .view = .{ .state = .signed_out },
    });
    control.finishAccountCommitNoFail();
    control.setMetaskAuthorizationUnavailable();

    try std.testing.expectEqual(
        models_contract.CatalogState.needs_authentication,
        control.modelsView().providers[0].catalog_state,
    );
    try std.testing.expectEqualStrings(
        TestCustomProviderVault.slot,
        control.modelsView().default_selection.?.source_id,
    );
    try std.testing.expectEqual(
        models_contract.Source.custom_provider,
        control.execution_state.activeSource().?,
    );
    try std.testing.expect(control.canCreateTask());
}

test "Account identity and Models execution publish through separate projections" {
    test_agent_runtime.io = std.testing.io;
    var control = try Runtime.init(
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
    defer control.deinit();
    try TestSupport.installMetaskExecution(&control, 1);

    const account = control.accountView();
    try std.testing.expectEqual(account_contract.AccountState.authenticated, account.state);
    try std.testing.expectEqualStrings("account-1", account.account_id);
    const models = control.modelsView();
    try std.testing.expectEqual(models_contract.CatalogState.ready, models.providers[0].catalog_state);
    try std.testing.expectEqualStrings("fixture-model", models.metask_selection.?.model_id);
    try std.testing.expect(control.newTaskAdmissionView().available);
}

test "explicit Metask default activation restores admission from an empty global default" {
    test_agent_runtime.io = std.testing.io;
    var control = try Runtime.init(
        std.testing.allocator,
        std.testing.io,
        &test_agent_runtime,
        testLimits(),
        .{},
    );
    defer control.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var directory_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory_len = try tmp.dir.realPath(std.testing.io, &directory_storage);
    var vault: TestCustomProviderVault = .{};
    try control.startCustomProviders(
        directory_storage[0..directory_len],
        vault.port(),
    );
    defer control.stopCustomProviders();
    try TestSupport.installMetaskExecution(&control, 1);

    try std.testing.expect(control.custom_providers.clearDefault().accepted);
    control.reconcileModelsDefaultNoFail(false, false);
    control.finishExecutionCommitNoFail();
    try std.testing.expect(control.modelsView().default_selection == null);
    try std.testing.expect(!control.newTaskAdmissionView().available);

    const view = control.modelsView();
    const provider = view.providers[0];
    const selection = view.metask_selection orelse return error.TestUnexpectedResult;
    try std.testing.expect(control.selectModelsDefault(.{
        .selection = selection,
        .expected_selection_revision = view.selection_revision,
        .expected_source_generation = provider.source_generation,
        .expected_catalog_generation = provider.catalog_generation,
    }).accepted);
    try std.testing.expect(control.modelsView().default_selection != null);
    try std.testing.expect(control.newTaskAdmissionView().available);
    try std.testing.expect(control.newTaskAdmissionView().active_generation != 0);
}

test "Product Control non-destructively recovers Models admission without touching task state" {
    var control = try testRuntime();
    defer control.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var directory_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory_len = try tmp.dir.realPath(std.testing.io, &directory_storage);
    var vault: TestCustomProviderVault = .{};
    // `testRuntime` installs a transient Models catalog to seed the live
    // Task binding. Stop that owner before starting the persistence-backed
    // Models instance; the Task keeps its own execution copy.
    control.stopCustomProviders();
    try control.startCustomProviders(directory_storage[0..directory_len], vault.port());
    defer control.stopCustomProviders();
    const selection = try createReadyTestCustomProvider(&control);
    const connection = control.modelsView().custom_providers[0];
    try std.testing.expect(control.selectModelsDefault(.{
        .selection = .{ .source_id = selection.source_id, .model_id = "gpt-5" },
        .expected_selection_revision = control.modelsView().selection_revision,
        .expected_source_generation = connection.source_generation,
        .expected_catalog_generation = connection.catalog_generation,
    }).accepted);
    try std.testing.expect(control.canCreateTask());
    const task_route = control.task_runtime.tasks[0].?.runtime.routeId();
    const task_execution = control.task_runtime.tasks[0].?.runtime.executionConst().?;
    const task_model = control.task_runtime.tasks[0].?.durable.execution_model;
    const task_run_id = control.task_runtime.tasks[0].?.durable.runs[0].?.id;
    const revision = control.currentRevision();
    try std.testing.expectEqual(
        models_contract.ManagementError.generation_mismatch,
        control.resetModelsStore(revision - 1).error_code.?,
    );
    try std.testing.expectEqual(
        models_contract.ManagementError.persistence_unavailable,
        control.resetModelsStore(revision).error_code.?,
    );
    try std.testing.expect(vault.present);
    try std.testing.expect(control.canCreateTask());

    control.custom_providers.store_healthy = false;
    try std.testing.expectEqual(
        models_contract.PersistenceHealth.recovery_required,
        control.modelsView().persistence_health,
    );
    var snapshot_storage: [96 * 1024]u8 = undefined;
    const recovery_snapshot = try control.writeAggregateFixture(&snapshot_storage);
    try std.testing.expect(
        std.mem.indexOf(u8, recovery_snapshot, "\"persistenceHealth\":\"recovery_required\"") != null,
    );
    try std.testing.expect(control.resetModelsStore(revision).accepted);
    try std.testing.expectEqual(@as(usize, 1), control.modelsView().custom_providers.len);
    try std.testing.expect(control.modelsView().default_selection != null);
    try std.testing.expect(control.newTaskAdmissionView().available);
    try std.testing.expect(vault.present);
    try std.testing.expectEqual(task_route, control.task_runtime.tasks[0].?.runtime.routeId());
    try std.testing.expectEqual(task_execution, control.task_runtime.tasks[0].?.runtime.executionConst().?);
    try std.testing.expectEqualStrings(task_model, control.task_runtime.tasks[0].?.durable.execution_model);
    try std.testing.expectEqual(task_run_id, control.task_runtime.tasks[0].?.durable.runs[0].?.id);
}

test "identity replacement does not disturb live Task runtime references" {
    var control = try testRuntime();
    defer control.deinit();
    try control.beginDefaultExecutionReplacement();
    try std.testing.expect(control.executionReplacementPending());
    try std.testing.expect(!control.canCreateTask());
    control.endExecutionReplacementNoFail();
    const task = &control.task_runtime.tasks[0].?;
    const route_id = task.runtime.routeId();
    const execution = task.runtime.executionConst().?;
    try control.beginExecutionReplacement();
    try std.testing.expect(control.executionReplacementPending());
    try std.testing.expectEqual(route_id, task.runtime.routeId());
    try std.testing.expectEqual(execution, task.runtime.executionConst().?);
    control.endExecutionReplacementNoFail();

    const run = &task.durable.runs[0].?;
    try std.testing.expect(commitTerminal(
        run,
        .completed,
        .completed,
        null,
        .reusable,
        "",
        false,
    ));
    run.event_stream_finalized = true;
    task.runtime.active_run_id = 0;
    var replacement_lease = try task.runtime.worker_leases.acquire();
    try control.beginExecutionReplacement();
    try std.testing.expect(control.executionReplacementPending());
    try std.testing.expectEqual(@as(usize, 1), task.runtime.worker_leases.liveCount());
    try std.testing.expectEqual(route_id, task.runtime.routeId());
    try std.testing.expectEqual(execution, task.runtime.executionConst().?);
    try std.testing.expectEqual(TaskLifecycle.open, taskLifecycle(task));
    try std.testing.expectEqualStrings("fixture-model", task.durable.execution_model);
    try std.testing.expect(!control.canCreateTask());
    control.endExecutionReplacementNoFail();
    try std.testing.expect(control.canCreateTask());
    replacement_lease.deinit();
}

test "default replacement preserves Task generation and installs the next admission default" {
    var control = try testRuntime();
    defer control.deinit();

    const task = &control.task_runtime.tasks[0].?;
    try control.replaceTracked(
        &task.durable.title,
        "review future metawork credential",
        control.limits.max_task_title_bytes,
    );
    const old_input = try control.task_runtime.testExecutionInput(task.durable.id);
    try std.testing.expectEqual(@as(u64, 1), old_input.execution_generation);
    try std.testing.expectEqualStrings("SECRET-KEY", old_input.api_key);

    var replacement = try models_contract.OwnedConfig.initOwned(
        std.testing.allocator,
        .metask,
        .anthropic_messages,
        try std.testing.allocator.dupe(u8, "fixture-model-2"),
        try std.testing.allocator.dupe(
            u8,
            models_contract.metask_anthropic_messages_url,
        ),
        2,
        try std.testing.allocator.dupe(u8, "metawork"),
        "",
    );
    errdefer replacement.deinit();
    const replacement_models = [_]models_contract.ModelView{.{
        .id = "fixture-model-2",
        .display_name = "Fixture model 2",
    }};
    try control.beginDefaultExecutionReplacement();
    try std.testing.expect(control.task_runtime.continuationAvailable(
        task.durable.id,
        control.taskRuntimeProjectionEffects(),
    ));
    try std.testing.expectEqual(
        @as(u64, 1),
        (try control.task_runtime.testExecutionInput(task.durable.id)).execution_generation,
    );
    try std.testing.expect(!control.canCreateTask());
    try models_aggregate.TestSupport.installMetaskDefault(
        &control.custom_providers,
        "account-1",
        "metawork",
        &replacement_models,
        "fixture-model-2",
        2,
        5,
        6,
        7,
    );
    try control.prepareExecutionInstall(replacement.input());
    control.installExecutionNoFail(&replacement);
    control.execution_state.recordDefaultAuthorityNoFail(
        control.custom_providers.defaultAuthority().?,
    );
    control.endExecutionReplacementNoFail();
    control.finishExecutionCommitNoFail();

    const preserved = try control.task_runtime.testExecutionInput(task.durable.id);
    try std.testing.expectEqual(@as(u64, 1), preserved.execution_generation);
    try std.testing.expectEqualStrings("fixture-model", preserved.target.model);
    try std.testing.expectEqualStrings("SECRET-KEY", preserved.api_key);
    try std.testing.expectEqual(@as(u64, 2), control.execution_state.generation());
    try std.testing.expectEqualStrings("fixture-model-2", control.execution_state.model());
    try std.testing.expectEqualStrings("fixture-model", task.durable.execution_model);
    _ = try control.selectTaskModel(task.durable.id, testTaskModelSelectionInput(&control, 0, "fixture-model-2"));
    try std.testing.expectEqualStrings("fixture-model", task.durable.execution_model);
    try std.testing.expect(task.durable.model_intent != null);
    try std.testing.expect(std.mem.indexOf(u8, task.durable.title, "metawork") == null);
    var scrubbed_snapshot_storage: [96 * 1024]u8 = undefined;
    const scrubbed_snapshot = try control.writeAggregateFixture(&scrubbed_snapshot_storage);
    try std.testing.expect(std.mem.indexOf(u8, scrubbed_snapshot, "metawork") == null);
    var workspace_storage: [2]WorkspaceProjection = undefined;
    const workspace_projection = try control.copyWorkspaceProjections(&workspace_storage);
    try std.testing.expect(workspace_projection[0].canonical_root.len != 0);
    try std.testing.expect(std.mem.indexOf(
        u8,
        workspace_projection[0].canonical_root,
        "metawork",
    ) == null);

    var next_task_execution = try control.cloneCurrentTaskExecution(std.testing.allocator);
    defer next_task_execution.deinit();
    try std.testing.expectEqual(
        @as(u64, 2),
        next_task_execution.input().execution_generation,
    );

    const slot = try control.reserveRunRecord(
        task,
        .{ .text = "old SECRET-KEY remains private" },
    );
    defer control.discardRunRecord(task, slot);
    try std.testing.expectEqual(@as(u64, 1), task.durable.runs[slot].?.execution_generation);
    try std.testing.expectEqualStrings(
        "old *** remains private",
        task.durable.runs[slot].?.input.text.value,
    );
    try std.testing.expectEqualStrings("SECRET-KEY", task.durable.runs[slot].?.redaction_secret);

    task.durable.execution_generation = 2;
    try std.testing.expectError(
        error.ExecutionGenerationMismatch,
        control.task_runtime.testExecutionInput(task.durable.id),
    );
    try std.testing.expectError(
        error.ExecutionGenerationMismatch,
        control.runTask(
            task.durable.id,
            .{ .text = "must reject a mismatched binding" },
        ),
    );
    task.durable.execution_generation = 1;
}

test "busy Task model selection commits the last intent without changing installed execution" {
    var control = try testRuntime();
    defer control.deinit();

    const models = [_]models_contract.ModelView{
        .{ .id = "fixture-model", .display_name = "Fixture model" },
        .{ .id = "fixture-model-2", .display_name = "Fixture model 2" },
        .{ .id = "fixture-model-3", .display_name = "Fixture model 3" },
    };
    try TestSupport.replaceMetaskCatalog(&control, &models, "fixture-model");
    const task = &control.task_runtime.tasks[0].?;
    const binding_epoch = task.durable.binding_epoch;
    var cross_source = testTaskModelSelectionInput(
        &control,
        0,
        "fixture-model-2",
    );
    cross_source.target.source_id = "provider-1";
    try std.testing.expectError(
        error.StaleCatalog,
        control.selectTaskModel(task.durable.id, cross_source),
    );
    _ = try control.selectTaskModel(
        task.durable.id,
        testTaskModelSelectionInput(
            &control,
            0,
            "fixture-model-2",
        ),
    );
    try std.testing.expectEqualStrings("fixture-model", task.durable.execution_model);
    try std.testing.expectEqualStrings("fixture-model-2", task.durable.model_intent.?.model_id);
    try std.testing.expectEqual(binding_epoch, task.durable.binding_epoch);
    try std.testing.expectEqual(@as(u64, 1), task.durable.execution_generation);

    _ = try control.selectTaskModel(
        task.durable.id,
        testTaskModelSelectionInput(
            &control,
            1,
            "fixture-model-3",
        ),
    );
    try std.testing.expectEqualStrings("fixture-model-3", task.durable.model_intent.?.model_id);
    try std.testing.expectEqualStrings("fixture-model", task.durable.execution_model);
    try std.testing.expectError(
        error.TaskModelMismatch,
        control.selectTaskModel(
            task.durable.id,
            testTaskModelSelectionInput(
                &control,
                0,
                "fixture-model",
            ),
        ),
    );
}

test "same-source default model change preserves execution generation and advances admission revision" {
    var control = try testRuntime();
    defer control.deinit();

    const models = [_]models_contract.ModelView{
        .{ .id = "fixture-model", .display_name = "Fixture model", .metadata = .{ .capabilities = .{ .image_input = false } } },
        .{ .id = "fixture-model-2", .display_name = "Fixture model 2" },
    };
    try TestSupport.replaceMetaskCatalog(&control, &models, "fixture-model");
    const before = control.newTaskAdmissionView();
    const initial_view = control.modelsView();
    const initial_provider = initial_view.providers[0];
    try models_aggregate.TestSupport.installMetaskDefault(
        &control.custom_providers,
        "account-1",
        "fixture-secret",
        &models,
        "fixture-model-2",
        initial_provider.source_generation,
        initial_view.metask_selection_revision + 1,
        initial_view.selection_revision + 1,
        initial_provider.catalog_generation + 1,
    );
    control.reconcileModelsDefaultNoFail(false, false);
    control.finishExecutionCommitNoFail();
    const view = control.modelsView();
    const provider = view.providers[0];

    const after = control.newTaskAdmissionView();
    try std.testing.expectEqual(before.active_generation, after.active_generation);
    try std.testing.expect(after.active_selection_revision != before.active_selection_revision);
    try std.testing.expectEqualStrings("fixture-model-2", after.active_model_ref.?.model_id);
    try std.testing.expect(!control.validNewTaskAdmission(
        before.active_generation,
        before.active_selection_revision,
    ));
    try std.testing.expect(control.validNewTaskAdmission(
        after.active_generation,
        after.active_selection_revision,
    ));
    try std.testing.expectError(
        error.ExecutionGenerationMismatch,
        control.createTaskInWorkspace(
            1,
            1,
            before.active_generation,
            before.active_selection_revision,
            null,
            null,
            null,
            .{ .interactive = null },
        ),
    );
    const task = &control.task_runtime.tasks[0].?;
    try std.testing.expectEqualStrings("fixture-model", task.durable.execution_model);
    try std.testing.expect(control.newTaskModelSelectionAuthorized(.{
        .target = .{ .source_id = after.active_model_ref.?.source_id, .model_id = "fixture-model-2" },
        .expected_source_generation = provider.source_generation,
        .expected_catalog_generation = provider.catalog_generation,
    }));

    try models_aggregate.TestSupport.installMetaskDefault(
        &control.custom_providers,
        "account-1",
        "fixture-secret",
        &models,
        "fixture-model",
        provider.source_generation,
        view.metask_selection_revision + 1,
        view.selection_revision + 1,
        provider.catalog_generation + 1,
    );
    control.reconcileModelsDefaultNoFail(false, false);
    control.finishExecutionCommitNoFail();
    const reverted = control.newTaskAdmissionView();
    try std.testing.expectEqual(before.active_generation, reverted.active_generation);
    try std.testing.expect(reverted.active_selection_revision != after.active_selection_revision);
    try std.testing.expectEqualStrings("fixture-model", reverted.active_model_ref.?.model_id);
}

test "Product Control publishes Task model selection availability from cross-owner authority" {
    var control = try testRuntime();
    defer control.deinit();

    const task = &control.task_runtime.tasks[0].?;
    var query: task_runtime.ProjectionAuthorityQuery = .{
        .task_id = task.durable.id,
        .workspace_id = task.durable.workspace_id,
        .workspace_epoch = task.durable.workspace_epoch,
        .workspace_root = task.durable.workspace_root,
        .execution_generation = task.durable.execution_generation,
        .execution_protocol = task.durable.execution_protocol,
        .execution_model = task.durable.execution_model,
        .runtime_attached = true,
    };
    try std.testing.expectEqual(
        product_task.ModelSelectionAvailability.available,
        control.taskModelSelectionAvailability(query),
    );

    const refresh = control.prepareMetaskCatalogRefresh("account-1", 17);
    const preparation = switch (refresh) {
        .ready => |value| value,
        .rejected => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(
        product_task.ModelSelectionAvailability.catalog_loading,
        control.taskModelSelectionAvailability(query),
    );
    control.failMetaskCatalogRefresh(
        preparation.attempt_id,
        preparation.authorization_generation,
        .catalog_unavailable,
        "fixture unavailable",
    );
    try std.testing.expectEqual(
        product_task.ModelSelectionAvailability.catalog_unavailable,
        control.taskModelSelectionAvailability(query),
    );

    const ready_models = [_]models_contract.ModelView{.{ .id = "fixture-model", .display_name = "Fixture model" }};
    try TestSupport.replaceMetaskCatalog(&control, &ready_models, "fixture-model");
    try control.beginDefaultExecutionReplacement();
    try std.testing.expectEqual(
        product_task.ModelSelectionAvailability.available,
        control.taskModelSelectionAvailability(query),
    );
    control.endExecutionReplacementNoFail();

    query.runtime_attached = false;
    try std.testing.expectEqual(
        product_task.ModelSelectionAvailability.available,
        control.taskModelSelectionAvailability(query),
    );
    query.runtime_attached = true;
    query.execution_generation += 1;
    try std.testing.expectEqual(
        product_task.ModelSelectionAvailability.available,
        control.taskModelSelectionAvailability(query),
    );
    query.execution_generation -= 1;

    var binding = try PreparedCustomProviderBinding.init(
        std.testing.allocator,
        "provider-1",
        "fixture-model",
    );
    execution_state.testing.installCustomProviderBinding(
        &control.execution_state,
        &binding,
    );
    try std.testing.expectEqual(
        product_task.ModelSelectionAvailability.available,
        control.taskModelSelectionAvailability(query),
    );
    task.durable.archived = true;
    try std.testing.expectEqual(product_task.ModelSelectionAvailability.task_unavailable, control.taskModelSelectionAvailability(query));
    task.durable.archived = false;
    task.runtime.close_requested = true;
    try std.testing.expectEqual(product_task.ModelSelectionAvailability.task_unavailable, control.taskModelSelectionAvailability(query));
    task.runtime.close_requested = false;
    control.shutting_down = true;
    try std.testing.expectEqual(product_task.ModelSelectionAvailability.task_unavailable, control.taskModelSelectionAvailability(query));
    control.shutting_down = false;
}

test "Task model selection unknown commit resolves the original candidate before admitting another intent" {
    for ([_]TaskPersistenceCommit{ .committed, .failed }) |resolution| {
        const storage = try std.testing.allocator.alloc(u8, task_persistence.max_store_bytes);
        defer std.testing.allocator.free(storage);
        var history = TestTaskPersistence{ .storage = storage };
        var control = try testRuntimeWith(.{ .task_persistence = history.capability(null) });
        defer control.deinit();
        const models = [_]models_contract.ModelView{
            .{ .id = "fixture-model", .display_name = "Fixture model" },
            .{ .id = "fixture-model-2", .display_name = "Fixture model 2" },
        };
        try TestSupport.replaceMetaskCatalog(&control, &models, "fixture-model");
        const task = control.task_runtime.find(3).?;
        history.result = .outcome_unknown;
        try std.testing.expectError(error.TaskPersistenceOutcomeUnknown, control.selectTaskModel(3, testTaskModelSelectionInput(&control, 0, "fixture-model-2")));
        try std.testing.expect(task.model_intent_prepared);
        try std.testing.expectEqualStrings("fixture-model", task.durable.execution_model);
        const witness = control.approval_history_unknown.?;
        const digest = std.crypto.hash.sha2.Sha256.hash;
        var original_digest: [32]u8 = undefined;
        digest(witness, &original_digest, .{});
        try std.testing.expectError(error.TaskBusy, control.selectTaskModel(3, testTaskModelSelectionInput(&control, 1, "fixture-model")));
        try std.testing.expectError(error.TaskPersistenceOutcomeUnknown, control.runTask(3, .{ .text = "must not use an unconfirmed selection" }));
        try control.renameTask(3, "later title");
        try std.testing.expectEqual(witness.ptr, control.approval_history_unknown.?.ptr);
        var retained_digest: [32]u8 = undefined;
        digest(control.approval_history_unknown.?, &retained_digest, .{});
        try std.testing.expectEqualSlices(u8, &original_digest, &retained_digest);
        var snapshot_bytes: [16 * 1024]u8 = undefined;
        try std.testing.expect(std.mem.indexOf(u8, try control.writeAggregateFixture(&snapshot_bytes), "\"state\":\"outcome_unknown\"") != null);
        history.result = .committed;
        history.resolution_result = resolution;
        try std.testing.expectEqual(PersistenceRecoveryOutcome.outcome_unknown, control.recoverTaskHistory(control.currentRevision()));
        var settled = false;
        for (0..100_000) |_| {
            control.syncLifecycle();
            if (control.pending_model_intent == null) {
                settled = true;
                break;
            }
            std.Thread.yield() catch {};
        }
        try std.testing.expect(settled);
        try std.testing.expect(history.resolutions > 0);
        try std.testing.expect(!task.model_intent_prepared);
        try std.testing.expectEqualStrings("fixture-model", task.durable.execution_model);
        if (resolution == .committed) {
            try std.testing.expectEqualStrings("fixture-model-2", task.durable.model_intent.?.model_id);
            try std.testing.expectEqual(@as(u64, 1), task.durable.model_intent.?.revision);
        } else try std.testing.expect(task.durable.model_intent == null);
    }
}

test "Task model installed intent does not borrow a catalog refresh as new execution authority" {
    var control = try testRuntime();
    defer control.deinit();
    const task = control.task_runtime.find(3).?;
    _ = try control.selectTaskModel(3, testTaskModelSelectionInput(&control, 0, "fixture-model"));
    task.runtime.execution().?.model_intent_revision = task.durable.model_intent.?.revision;
    const refresh = control.prepareMetaskCatalogRefresh("account-1", 17);
    const preparation = switch (refresh) {
        .ready => |value| value,
        .rejected => return error.TestUnexpectedResult,
    };
    control.failMetaskCatalogRefresh(preparation.attempt_id, preparation.authorization_generation, .catalog_unavailable, "unavailable catalog");
    try std.testing.expect((try control.resolveTaskRunModel(3)) == null);
    try std.testing.expectEqualStrings("fixture-model", task.durable.execution_model);
    // An uninstalled/newly selected revision still needs exact current source
    // authority; a matching model name alone cannot establish that proof.
    task.runtime.execution().?.model_intent_revision = 0;
    try std.testing.expectError(error.ExecutionUnavailable, control.resolveTaskRunModel(3));
}

test "Task model selection does not depend on the global Custom Provider binding" {
    var control = try testRuntime();
    defer control.deinit();
    var binding = try PreparedCustomProviderBinding.init(std.testing.allocator, "provider-1", "fixture-model");
    execution_state.testing.installCustomProviderBinding(&control.execution_state, &binding);
    const task = &control.task_runtime.tasks[0].?;
    _ = try control.selectTaskModel(task.durable.id, testTaskModelSelectionInput(&control, 0, "fixture-model"));
    try std.testing.expectEqualStrings("metask", task.durable.model_intent.?.source_id);
    try std.testing.expectEqual(@as(u64, 1), task.durable.model_intent.?.revision);
}

test "clearing the admission default preserves active Task execution" {
    var control = try testRuntime();
    defer control.deinit();

    const task = &control.task_runtime.tasks[0].?;
    const task_execution = try control.task_runtime.testExecutionInput(task.durable.id);
    try std.testing.expectEqualStrings("SECRET-KEY", task_execution.api_key);

    control.commitAccountFactNoFail(.{
        .kind = .signed_out,
        .view = .{ .state = .signed_out },
    });
    control.finishAccountCommitNoFail();
    control.setMetaskAuthorizationUnavailable();

    try std.testing.expect(!control.execution_state.ready());
    try std.testing.expect(!control.newTaskAdmissionView().available);
    const preserved = try control.task_runtime.testExecutionInput(task.durable.id);
    try std.testing.expectEqual(@as(u64, 1), preserved.execution_generation);
    try std.testing.expectEqualStrings("fixture-model", preserved.target.model);
    try std.testing.expectEqualStrings("SECRET-KEY", preserved.api_key);
}

test "released Task credential is permanently scrubbed from every product projection" {
    var control = try testRuntime();
    defer control.deinit();
    const task = &control.task_runtime.tasks[0].?;
    const run = &task.durable.runs[0].?;

    try control.replaceTracked(
        &task.durable.title,
        "title SECRET-KEY",
        control.limits.max_task_title_bytes,
    );
    try control.replaceTracked(
        &run.input.text.value,
        "prompt SECRET-KEY",
        control.limits.max_user_message_bytes,
    );
    try control.appendTrackedText(
        &run.assistant,
        "answer SECRET-KEY",
        control.limits.max_assistant_message_bytes,
    );
    try control.appendTrackedText(
        &run.output_segment,
        "segment SECRET-KEY",
        control.limits.max_assistant_message_bytes,
    );
    try control.appendTrackedText(
        &run.output_continued,
        "continued SECRET-KEY",
        control.limits.max_assistant_message_bytes,
    );
    run.tools[0] = .{
        .route_digest = toolRouteDigest("SECRET-KEY"),
        .id = try control.copyBounded("id SECRET-KEY", control.limits.max_tool_field_bytes),
        .order = 1,
        .name = try control.copyBounded("name SECRET-KEY", control.limits.max_tool_field_bytes),
        .input = try control.copyBounded("input SECRET-KEY", control.limits.max_tool_field_bytes),
        .progress = try control.copyBounded("progress SECRET-KEY", control.limits.max_tool_field_bytes),
        .content = try control.copyBounded("content SECRET-KEY", control.limits.max_tool_field_bytes),
        .state = .completed,
    };
    const file_refs = try control.allocator.alloc(?task_test_state.FileReferenceView, 1);
    file_refs[0] = .{
        .id = try control.copyBounded("ref SECRET-KEY", control.limits.max_tool_field_bytes),
        .title = try control.copyBounded("title SECRET-KEY", control.limits.max_tool_field_bytes),
        .display_path = try control.copyBounded("path SECRET-KEY", control.limits.max_tool_field_bytes),
        .kind = try control.copyBounded("kind SECRET-KEY", control.limits.max_tool_field_bytes),
        .locator_kind = .workspace_path,
        .locator = try control.copyBounded("src/SECRET-KEY.zig", control.limits.max_tool_field_bytes),
    };
    run.tools[0].?.file_refs = file_refs;
    run.file_changes[0] = .{
        .route_digest = [_]u8{0x7a} ** task_test_state.file_change_route_digest_bytes,
        .id = try control.copyBounded("change SECRET-KEY", control.limits.max_tool_field_bytes),
        .order = 2,
        .kind = .moved,
        .status = .applied,
        .display_path = try control.copyBounded("to SECRET-KEY", control.limits.max_tool_field_bytes),
        .from_display_path = try control.copyBounded("from SECRET-KEY", control.limits.max_tool_field_bytes),
        .before_bytes = 1,
        .after_bytes = 2,
        .diff_complete = true,
    };
    run.automatic_title.state.store(.ready, .release);
    @memcpy(
        run.automatic_title.result[0.."automatic SECRET-KEY".len],
        "automatic SECRET-KEY",
    );
    run.automatic_title.result_len = "automatic SECRET-KEY".len;
    run.automatic_title.generated = true;
    product_workspace.testing.overwriteProjectedRoot(
        &control.workspace,
        1,
        "SECRET-KEY",
    );
    task.durable.ui_history[0] = .{
        .request_id = 8,
        .run_id = run.id,
        .kind = .permission,
        .state = .denied,
    };
    @memcpy(task.durable.ui_history[0].?.detail[0.."SECRET-KEY".len], "SECRET-KEY");
    task.durable.ui_history[0].?.detail_len = "SECRET-KEY".len;
    @memcpy(
        task.durable.ui_history[0].?.agent_request_id[0.."request SECRET-KEY".len],
        "request SECRET-KEY",
    );
    task.durable.ui_history[0].?.agent_request_id_len = "request SECRET-KEY".len;
    task.durable.ui_history_count = 1;
    const compact_slot = try control.reserveCompactRecord(task, 9, run.id);
    const compact = &task.durable.compacts[compact_slot].?;
    try std.testing.expectEqualStrings("SECRET-KEY", compact.redaction_secret);
    try control.replaceTracked(
        &task.durable.execution_model,
        "model-SECRET-KEY",
        models_contract.Limits.model_id_bytes,
    );

    try std.testing.expect(commitTerminal(
        run,
        .completed,
        .completed,
        null,
        .reusable,
        "",
        false,
    ));
    @memcpy(run.terminal_diagnostic[0.."run SECRET-KEY".len], "run SECRET-KEY");
    @constCast(terminalPayload(run).?).diagnostic_len = "run SECRET-KEY".len;
    try std.testing.expect(commitCompactProductTerminal(
        compact,
        .compacted,
        null,
        .reusable,
        .{},
        1,
        1,
        "",
        false,
    ));
    @memcpy(
        compact.terminal_diagnostic[0.."compact SECRET-KEY".len],
        "compact SECRET-KEY",
    );
    @constCast(compactTerminalPayload(compact).?).diagnostic_len =
        "compact SECRET-KEY".len;
    control.redactAllProductProjectionsNoFail("SECRET-KEY");
    try std.testing.expect(run.automatic_title.generated_redacted);
    try std.testing.expect(std.mem.indexOf(
        u8,
        run.automatic_title.result[0..run.automatic_title.result_len],
        "SECRET-KEY",
    ) == null);
    run.event_stream_finalized = true;
    control.releaseTaskAttachmentNoFail(task, .cold_start);
    task.runtime.active_run_id = 0;
    try control.beginExecutionReplacement();
    try std.testing.expect(task.runtime.executionConst() == null);
    try std.testing.expectEqual(@as(usize, 0), run.redaction_secret.len);
    try std.testing.expectEqual(@as(usize, 0), compact.redaction_secret.len);
    try std.testing.expect(std.mem.indexOf(u8, task.durable.execution_model, "SECRET-KEY") == null);
    try std.testing.expect(std.mem.indexOf(u8, run.output_segment.list.items, "SECRET-KEY") == null);
    try std.testing.expect(std.mem.indexOf(u8, run.output_continued.list.items, "SECRET-KEY") == null);
    const scrubbed_ref = run.tools[0].?.file_refs.?[0].?;
    try std.testing.expect(std.mem.indexOf(u8, scrubbed_ref.locator, "SECRET-KEY") == null);
    try std.testing.expect(run.tools[0].?.redacted);
    try std.testing.expect(std.mem.indexOf(u8, run.file_changes[0].?.display_path, "SECRET-KEY") == null);
    try std.testing.expect(run.file_changes[0].?.redacted);
    try std.testing.expect(terminalPayload(run).?.diagnostic_redacted);
    try std.testing.expect(compactTerminalPayload(compact).?.diagnostic_redacted);
    try std.testing.expect(task.durable.ui_history[0].?.redacted);
    var snapshot_storage: [96 * 1024]u8 = undefined;
    const snapshot = try control.writeAggregateFixture(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "SECRET-KEY") == null);
    try std.testing.expect(
        std.mem.indexOf(u8, snapshot, "\"diagnosticDisposition\":\"withheld\"") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, snapshot, "\"lastRunOutcome\"") == null,
    );
    control.endExecutionReplacementNoFail();
}

test "clearing the last default execution scrubs its credential before secure zero" {
    test_agent_runtime.io = std.testing.io;
    var control = try Runtime.init(
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
    defer control.deinit();
    try installTestExecution(&control);
    product_workspace.testing.installOwned(&control.workspace, 0, .{
        .id = 1,
        .canonical_root = try control.copyBounded("/tmp", control.limits.max_workspace_bytes),
        .projected_root_storage = try control.copyBounded(
            "path-SECRET-KEY",
            control.limits.max_workspace_bytes,
        ),
        .projected_root_len = "path-SECRET-KEY".len,
        .display_name_storage = try control.copyBounded(
            "SECRET-KEY",
            control.limits.max_workspace_bytes,
        ),
        .display_name_len = "SECRET-KEY".len,
        .recent_order = 1,
    });
    control.skill.registerWorkspaceOwned(.{
        .id = 1,
        .epoch = 1,
        .catalog_authorized = true,
        .canonical_root = try control.allocator.dupe(u8, "/tmp"),
    }, control.skillProjectionBudget());
    try control.beginDefaultExecutionReplacement();
    control.commitAccountFactNoFail(.{
        .kind = .signed_out,
        .view = .{ .state = .signed_out },
    });
    try control.prepareExecutionClear();
    control.clearExecutionNoFail();
    control.endExecutionReplacementNoFail();
    control.finishAccountCommitNoFail();

    try std.testing.expectEqual(@as(usize, 0), control.execution_state.credential().len);
    var snapshot_storage: [96 * 1024]u8 = undefined;
    const snapshot = try control.writeAggregateFixture(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "SECRET-KEY") == null);
}

test "known credential matching chooses the longest overlapping secret" {
    var control = try testRuntime();
    defer control.deinit();
    execution_state.testing.setCredentialBytes(
        &control.execution_state,
        "SECRET",
    );

    try std.testing.expectEqual(
        @as(usize, "SECRET-KEY".len),
        control.matchedKnownCredentialLen("SECRET-KEY suffix"),
    );
    try control.replaceTracked(
        &control.task_runtime.tasks[0].?.durable.title,
        "SECRET-KEY suffix",
        control.limits.max_task_title_bytes,
    );
    var snapshot_storage: [96 * 1024]u8 = undefined;
    const snapshot = try control.writeAggregateFixture(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "SECRET-KEY") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "***-KEY") == null);
}

test "Product view security epoch invalidates learned and retiring credentials" {
    var control = try testRuntime();
    defer control.deinit();
    const epoch = control.projectionSecurityEpoch();
    control.learnProjectionCredential("future-credential");
    try std.testing.expectEqual(epoch + 1, control.projectionSecurityEpoch());
    control.redactAllProductProjectionsNoFail("");
    try std.testing.expectEqual(epoch + 1, control.projectionSecurityEpoch());
    var storage: [96 * 1024]u8 = undefined;
    const view = try control.writeViewFixture(&storage, .{});
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, view, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(control.projectionSecurityEpoch(), try std.fmt.parseInt(u64, parsed.value.object.get("securityEpoch").?.string, 10));
    control.projection_security_epoch = std.math.maxInt(u64);
    control.retireProjectionCredential("retiring-credential");
    try std.testing.expectEqual(@as(u64, 0), control.projectionSecurityEpoch());
    try std.testing.expectError(error.InvalidViewRequest, control.writeViewFixture(&storage, .{}));
}

test "opaque credential redaction preserves UTF-8 projection validity" {
    var control = try testRuntime();
    defer control.deinit();
    execution_state.testing.setCredentialBytes(
        &control.execution_state,
        &[_]u8{0xa9},
    );

    var output: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    try control.projectedJsonValueWithKnownCredentials(&writer, "café");
    try std.testing.expectEqualStrings("\"caf**\"", writer.buffered());
    try std.testing.expect(std.unicode.utf8ValidateSlice(writer.buffered()));

    var fixed = "café".*;
    try std.testing.expect(redactFixedWidthNoFail(&fixed, &.{0xa9}));
    try std.testing.expectEqualStrings("caf**", &fixed);
    try std.testing.expect(std.unicode.utf8ValidateSlice(&fixed));
}

test "opaque credential redaction is UTF-8 safe across product inputs and assistant chunks" {
    var control = try testRuntime();
    defer control.deinit();
    const task = &control.task_runtime.tasks[0].?;
    try replaceTaskCredentialForTest(task, &.{0xa9});

    const slot = try control.reserveRunRecord(task, .{ .text = "café" });
    defer control.discardRunRecord(task, slot);
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
    try control.applyEvent(&tool_event);
    const tool = &task.durable.runs[0].?.tools[0].?;
    try std.testing.expectEqualStrings("caf**", tool.name);
    try std.testing.expectEqualStrings("caf**", tool.input);
    try std.testing.expect(std.unicode.utf8ValidateSlice(tool.name));
    try std.testing.expect(std.unicode.utf8ValidateSlice(tool.input));

    const request = testPermissionRequest("café", "café");
    var pending_storage: [4096]u8 = undefined;
    var pending_writer = std.Io.Writer.fixed(&pending_storage);
    try task_test_view.writePendingUi(
        &pending_writer,
        control.taskTextProjection(),
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
    try std.testing.expect(control.redactTrackedText(&assistant, &.{0xa9}));
    try std.testing.expectEqualStrings("caf**", assistant.list.items);
    try std.testing.expect(std.unicode.utf8ValidateSlice(assistant.list.items));
}

test "assistant redaction withholds a UTF-8 codepoint across credential chunks" {
    var control = try testRuntime();
    defer control.deinit();
    var assistant = TrackedText{};
    defer assistant.list.deinit(std.testing.allocator);
    const credential = [_]u8{ 0xa9, 'X' };

    try assistant.list.appendSlice(std.testing.allocator, "é");
    try std.testing.expect(!control.redactTrackedText(&assistant, &credential));
    try std.testing.expectEqual(@as(usize, 0), assistant.committed_len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(assistant.list.items));

    try assistant.list.appendSlice(std.testing.allocator, "X tail");
    try std.testing.expect(control.redactTrackedText(&assistant, &credential));
    try std.testing.expectEqualStrings("*** tail", assistant.list.items);
    try std.testing.expectEqual(assistant.list.items.len, assistant.committed_len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(assistant.list.items));
}

test "product Task identity is independent from Agent Session route identity" {
    var control = try testRuntime();
    defer control.deinit();
    const task = &control.task_runtime.tasks[0].?;
    task.runtime.attached().?.binding = task_test_agent_session.Binding.testFixture(99);

    var routed = try testEnvelope(99, 7, "{\"text_chunk\":\"routed\"}");
    defer routed.deinit();
    try control.applyEvent(&routed);
    try std.testing.expectEqual(@as(u64, 3), control.task_runtime.tasks[0].?.durable.id);
    try std.testing.expectEqualStrings(
        "routed",
        control.task_runtime.tasks[0].?.durable.runs[0].?.assistant.list.items,
    );

    var product_id_is_not_route = try testEnvelope(3, 7, "{\"text_chunk\":\"wrong\"}");
    defer product_id_is_not_route.deinit();
    try std.testing.expectError(
        error.UnknownTask,
        control.applyEvent(&product_id_is_not_route),
    );
}

test "streaming Run events do not reorder Task navigation" {
    var control = try testRuntime();
    defer control.deinit();
    const before = control.task_runtime.tasks[0].?.durable.recent_order;

    var text = try testEnvelope(3, 7, "{\"text_chunk\":\"streaming\"}");
    defer text.deinit();
    try control.applyEvent(&text);
    try std.testing.expectEqual(before, control.task_runtime.tasks[0].?.durable.recent_order);

    var usage = try testEnvelope(
        3,
        7,
        "{\"usage\":{\"input_tokens\":1,\"output_tokens\":1,\"cache_read_input_tokens\":0,\"cache_creation_input_tokens\":0}}",
    );
    defer usage.deinit();
    try control.applyEvent(&usage);
    try std.testing.expectEqual(before, control.task_runtime.tasks[0].?.durable.recent_order);
}

test "Run elapsed projection samples an injected clock without publishing revisions" {
    var control = try testRuntime();
    defer control.deinit();
    const Clock = struct {
        fn now(context: ?*anyopaque) ?u64 {
            const value: *u64 = @ptrCast(@alignCast(context.?));
            return value.*;
        }
    };
    var now: u64 = 1250;
    control.run_clock = .{ .context = &now, .now_ms_fn = Clock.now };
    const run = &control.task_runtime.tasks[0].?.durable.runs[0].?;
    run.admitted_at_ms = 1000;
    var storage: [96 * 1024]u8 = undefined;
    for ([_]task_test_state.ActiveRunPhase{ .queued, .running, .waiting_ui, .stopping }) |phase| {
        run.active_phase = phase;
        try std.testing.expectEqual(@as(?u64, 250), task_test_state.runElapsedMs(run, now));
    }
    const first = try control.writeAggregateFixture(&storage);
    try std.testing.expect(std.mem.indexOf(u8, first, "\"elapsedMs\":\"250\"") != null);
    const revision = control.revision;
    now = 135000;
    const second = try control.writeAggregateFixture(&storage);
    try std.testing.expect(std.mem.indexOf(u8, second, "\"elapsedMs\":\"134000\"") != null);
    try std.testing.expectEqual(revision, control.revision);
    try std.testing.expectEqual(@as(?u64, null), task_test_state.runElapsedMs(run, 999));
    try std.testing.expectEqual(@as(?u64, null), task_test_state.runElapsedMs(run, null));
    run.terminal_payload = .{ .exclude_on_product_terminal = false, .phase = .completed, .outcome = .completed, .cause = null, .session_disposition_at_completion = .reusable };
    run.terminal_publication.store(.published, .release);
    try std.testing.expectEqual(@as(?u64, 134000), task_test_state.runElapsedMs(run, now));
    run.terminal_observed = true;
    task_test_state.freezeRunElapsedMs(run, now);
    run.event_stream_finalized = true;
    try std.testing.expectEqual(@as(?u64, 134000), task_test_state.runElapsedMs(run, now));
    now = 200000;
    try std.testing.expectEqual(@as(?u64, 134000), task_test_state.runElapsedMs(run, now));
    run.admitted_at_ms = null;
    try std.testing.expectEqual(@as(?u64, 134000), task_test_state.runElapsedMs(run, now));
}

test "thinking and assistant chunks update distinct safe projections" {
    var control = try testRuntime();
    defer control.deinit();
    const task = &control.task_runtime.tasks[0].?;
    const run = &task.durable.runs[0].?;
    const route = task.runtime.routeId();

    const revision_before_thinking = control.revision;
    var thinking = try testEnvelope(
        route,
        7,
        "{\"thinking_chunk\":\"private-reasoning-marker\"}",
    );
    defer thinking.deinit();
    try control.applyEvent(&thinking);
    try std.testing.expectEqualStrings("", run.assistant.list.items);
    try std.testing.expectEqual(task_test_state.RunActivity.thinking, run.observed_activity);
    try std.testing.expectEqual(revision_before_thinking + 1, control.revision);

    const revision_before_duplicate = control.revision;
    var duplicate = try testEnvelope(
        route,
        7,
        "{\"thinking_chunk\":\"more-private-reasoning\"}",
    );
    defer duplicate.deinit();
    try control.applyEvent(&duplicate);
    try std.testing.expectEqual(revision_before_duplicate, control.revision);

    var assistant = try testEnvelope(
        route,
        7,
        "{\"text_chunk\":\"public response\"}",
    );
    defer assistant.deinit();
    try control.applyEvent(&assistant);
    try std.testing.expectEqualStrings("public response", run.assistant.list.items);
    try std.testing.expectEqual(
        task_test_state.RunActivity.writing_response,
        run.observed_activity,
    );

    var snapshot_storage: [96 * 1024]u8 = undefined;
    const snapshot = try control.writeAggregateFixture(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "private-reasoning-marker") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "more-private-reasoning") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "public response") != null);
}

test "output segments commit commentary and a continued final while discarding rollback" {
    var control = try testRuntime();
    defer control.deinit();
    const task = &control.task_runtime.tasks[0].?;
    const run = &task.durable.runs[0].?;
    const route = task.runtime.routeId();
    const events = [_][]const u8{
        "{\"output_segment_begin\":{\"index\":0,\"turn\":1,\"group\":0}}",
        "{\"text_chunk\":\"look \"}",
        "{\"output_segment_end\":{\"index\":0,\"turn\":1,\"group\":0,\"disposition\":\"commentary\",\"bytes\":5}}",
        "{\"output_segment_begin\":{\"index\":1,\"turn\":2,\"group\":1}}",
        "{\"text_chunk\":\"again \"}",
        "{\"output_segment_end\":{\"index\":1,\"turn\":2,\"group\":1,\"disposition\":\"commentary\",\"bytes\":6}}",
        "{\"output_segment_begin\":{\"index\":2,\"turn\":3,\"group\":2}}",
        "{\"text_chunk\":\"half \"}",
        "{\"output_segment_end\":{\"index\":2,\"turn\":3,\"group\":2,\"disposition\":\"continued\",\"bytes\":5}}",
        "{\"output_segment_begin\":{\"index\":3,\"turn\":3,\"group\":2}}",
        "{\"text_chunk\":\"discarded\"}",
        "{\"output_segment_end\":{\"index\":3,\"turn\":3,\"group\":2,\"disposition\":\"discarded\",\"bytes\":9}}",
        "{\"output_segment_begin\":{\"index\":4,\"turn\":3,\"group\":2}}",
        "{\"text_chunk\":\"done\"}",
        "{\"output_segment_end\":{\"index\":4,\"turn\":3,\"group\":2,\"disposition\":\"final\",\"bytes\":4}}",
    };
    const expected_slots = [_]u32{ 0, 1, 1, 1, 2, 2, 2, 3, 3, 3, 3, 3, 3, 3, 3 };
    for (events, expected_slots) |encoded, slots| {
        var envelope = try testEnvelope(route, 7, encoded);
        defer envelope.deinit();
        try control.applyEvent(&envelope);
        // continued and an in-group discard retain the same safe tail slot.
        try std.testing.expectEqual(slots, run.outputPartCount());
    }

    try std.testing.expectEqualStrings("look again half done", run.assistant.list.items);
    try std.testing.expectEqualSlices(u64, &.{ 5, 11 }, run.commentary_ends[0..run.commentary_count]);
    try std.testing.expectEqual(
        task_test_state.AssistantOutputKind.final,
        run.assistant_output_kind.?,
    );
    try std.testing.expectEqual(@as(usize, 11), run.assistant_output_start.?);
    try std.testing.expect(run.open_output_segment == null);
    try std.testing.expect(run.output_continued_group == null);
    try std.testing.expectEqual(@as(u64, 5), run.next_output_segment_index);
    try std.testing.expect(std.mem.indexOf(u8, run.assistant.list.items, "discarded") == null);
    var snapshot_storage: [96 * 1024]u8 = undefined;
    const snapshot = try control.writeAggregateFixture(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(
        u8,
        snapshot,
        "\"output\":{\"commentary\":[\"look \",\"again \"],\"response\":\"half done\",\"responseKind\":\"final\",\"provisional\":\"\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        snapshot,
        "\"activity\":{\"kind\":\"finalizing\"}",
    ) != null);
}

test "output segment byte mismatch fails the dependency protocol" {
    var control = try testRuntime();
    defer control.deinit();
    const task = &control.task_runtime.tasks[0].?;
    const route = task.runtime.routeId();

    var begin = try testEnvelope(
        route,
        7,
        "{\"output_segment_begin\":{\"index\":0,\"turn\":1,\"group\":0}}",
    );
    defer begin.deinit();
    try control.applyEvent(&begin);
    var text_event = try testEnvelope(route, 7, "{\"text_chunk\":\"ok\"}");
    defer text_event.deinit();
    try control.applyEvent(&text_event);
    var invalid_end = try testEnvelope(
        route,
        7,
        "{\"output_segment_end\":{\"index\":0,\"turn\":1,\"group\":0,\"disposition\":\"final\",\"bytes\":1}}",
    );
    defer invalid_end.deinit();
    try std.testing.expectError(
        error.InvalidOutputSegment,
        control.applyEvent(&invalid_end),
    );
}

test "commentary boundary capacity fails before canonical output mutation" {
    var control = try testRuntime();
    defer control.deinit();
    control.limits.max_commentary_segments_per_run = 1;
    const task = &control.task_runtime.tasks[0].?;
    const run = &task.durable.runs[0].?;
    const route = task.runtime.routeId();
    const accepted = [_][]const u8{
        "{\"output_segment_begin\":{\"index\":0,\"turn\":1,\"group\":0}}",
        "{\"text_chunk\":\"first\"}",
        "{\"output_segment_end\":{\"index\":0,\"turn\":1,\"group\":0,\"disposition\":\"commentary\",\"bytes\":5}}",
        "{\"output_segment_begin\":{\"index\":1,\"turn\":2,\"group\":1}}",
        "{\"text_chunk\":\"second\"}",
    };
    for (accepted) |encoded| {
        var envelope = try testEnvelope(route, run.id, encoded);
        defer envelope.deinit();
        try control.applyEvent(&envelope);
    }
    var close = try testEnvelope(
        route,
        run.id,
        "{\"output_segment_end\":{\"index\":1,\"turn\":2,\"group\":1,\"disposition\":\"commentary\",\"bytes\":6}}",
    );
    defer close.deinit();
    try std.testing.expectError(error.ProjectionCapacity, control.applyEvent(&close));
    try std.testing.expectEqualStrings("first", run.assistant.list.items);
    try std.testing.expectEqualSlices(u64, &.{5}, run.commentary_ends[0..run.commentary_count]);
    try std.testing.expectEqualStrings("second", run.output_segment.list.items);
    try std.testing.expect(run.open_output_segment != null);
}

test "output segment close is atomic when the destination reserve fails" {
    var control = try testRuntime();
    defer control.deinit();
    const task = &control.task_runtime.tasks[0].?;
    const run = &task.durable.runs[0].?;
    const route = task.runtime.routeId();

    var begin = try testEnvelope(
        route,
        run.id,
        "{\"output_segment_begin\":{\"index\":0,\"turn\":1,\"group\":0}}",
    );
    defer begin.deinit();
    try control.applyEvent(&begin);
    var text_event = try testEnvelope(route, run.id, "{\"text_chunk\":\"answer\"}");
    defer text_event.deinit();
    try control.applyEvent(&text_event);

    control.limits.max_projection_bytes = control.projection_bytes;
    var end = try testEnvelope(
        route,
        run.id,
        "{\"output_segment_end\":{\"index\":0,\"turn\":1,\"group\":0,\"disposition\":\"final\",\"bytes\":6}}",
    );
    defer end.deinit();
    try std.testing.expectError(error.ProjectionCapacity, control.applyEvent(&end));
    try std.testing.expect(run.open_output_segment != null);
    try std.testing.expectEqual(@as(u64, 0), run.next_output_segment_index);
    try std.testing.expectEqualStrings("answer", run.output_segment.list.items);
    try std.testing.expectEqualStrings("", run.assistant.list.items);
    try std.testing.expect(run.assistant_output_kind == null);
}

test "assistant output budget is aggregate across committed and open segments" {
    var control = try testRuntime();
    defer control.deinit();
    const task = &control.task_runtime.tasks[0].?;
    const run = &task.durable.runs[0].?;
    const route = task.runtime.routeId();
    control.limits.max_assistant_message_bytes = 8;

    const first = [_][]const u8{
        "{\"output_segment_begin\":{\"index\":0,\"turn\":1,\"group\":0}}",
        "{\"text_chunk\":\"four\"}",
        "{\"output_segment_end\":{\"index\":0,\"turn\":1,\"group\":0,\"disposition\":\"commentary\",\"bytes\":4}}",
        "{\"output_segment_begin\":{\"index\":1,\"turn\":2,\"group\":1}}",
    };
    for (first) |encoded| {
        var envelope = try testEnvelope(route, run.id, encoded);
        defer envelope.deinit();
        try control.applyEvent(&envelope);
    }
    var overflow = try testEnvelope(route, run.id, "{\"text_chunk\":\"five!\"}");
    defer overflow.deinit();
    try std.testing.expectError(error.ProjectionCapacity, control.applyEvent(&overflow));
    try std.testing.expectEqualStrings("four", run.assistant.list.items);
    try std.testing.expectEqualStrings("", run.output_segment.list.items);
    try std.testing.expect(run.open_output_segment != null);
    try std.testing.expectEqual(@as(u64, 0), run.open_output_segment.?.bytes);
}

test "partial output stays provisional until the segment is classified" {
    var control = try testRuntime();
    defer control.deinit();
    const task = &control.task_runtime.tasks[0].?;
    const run = &task.durable.runs[0].?;
    const route = task.runtime.routeId();

    var begin = try testEnvelope(
        route,
        7,
        "{\"output_segment_begin\":{\"index\":0,\"turn\":1,\"group\":0}}",
    );
    defer begin.deinit();
    try control.applyEvent(&begin);
    var text_event = try testEnvelope(route, 7, "{\"text_chunk\":\"unfinished\"}");
    defer text_event.deinit();
    try control.applyEvent(&text_event);
    try std.testing.expectEqualStrings("", run.assistant.list.items);
    try std.testing.expectEqualStrings("unfinished", run.output_segment.list.items);
    var provisional_storage: [96 * 1024]u8 = undefined;
    const provisional_snapshot = try control.writeAggregateFixture(&provisional_storage);
    try std.testing.expect(std.mem.indexOf(
        u8,
        provisional_snapshot,
        "\"response\":\"\",\"responseKind\":null,\"provisional\":\"unfinished\"",
    ) != null);

    var end = try testEnvelope(
        route,
        7,
        "{\"output_segment_end\":{\"index\":0,\"turn\":1,\"group\":0,\"disposition\":\"partial\",\"bytes\":10}}",
    );
    defer end.deinit();
    try control.applyEvent(&end);
    try std.testing.expectEqualStrings("unfinished", run.assistant.list.items);
    try std.testing.expectEqual(
        task_test_state.AssistantOutputKind.partial,
        run.assistant_output_kind.?,
    );
    try std.testing.expectEqual(@as(usize, 0), run.assistant_output_start.?);
    var classified_storage: [96 * 1024]u8 = undefined;
    const classified_snapshot = try control.writeAggregateFixture(&classified_storage);
    try std.testing.expect(std.mem.indexOf(
        u8,
        classified_snapshot,
        "\"response\":\"unfinished\",\"responseKind\":\"partial\",\"provisional\":\"\"",
    ) != null);
}

test "provisional output exposes only credential-safe committed bytes" {
    var control = try testRuntime();
    defer control.deinit();
    const task = &control.task_runtime.tasks[0].?;
    const run = &task.durable.runs[0].?;
    const route = task.runtime.routeId();

    var begin = try testEnvelope(
        route,
        run.id,
        "{\"output_segment_begin\":{\"index\":0,\"turn\":1,\"group\":0}}",
    );
    defer begin.deinit();
    try control.applyEvent(&begin);
    var prefix = try testEnvelope(route, run.id, "{\"text_chunk\":\"SECRET-\"}");
    defer prefix.deinit();
    try control.applyEvent(&prefix);
    var prefix_storage: [96 * 1024]u8 = undefined;
    const prefix_snapshot = try control.writeAggregateFixture(&prefix_storage);
    try std.testing.expect(std.mem.indexOf(u8, prefix_snapshot, "SECRET-") == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        prefix_snapshot,
        "\"provisional\":\"\"",
    ) != null);

    var suffix = try testEnvelope(route, run.id, "{\"text_chunk\":\"KEY\"}");
    defer suffix.deinit();
    try control.applyEvent(&suffix);
    var redacted_storage: [96 * 1024]u8 = undefined;
    const redacted_snapshot = try control.writeAggregateFixture(&redacted_storage);
    try std.testing.expect(std.mem.indexOf(u8, redacted_snapshot, "SECRET-KEY") == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        redacted_snapshot,
        "\"provisional\":\"***\",\"redacted\":false,\"provisionalRedacted\":true",
    ) != null);
}

test "output partition redacts a known credential across commentary boundaries" {
    var control = try testRuntime();
    defer control.deinit();
    const task = &control.task_runtime.tasks[0].?;
    const run = &task.durable.runs[0].?;
    const route = task.runtime.routeId();
    run.redaction_secret = &.{};

    const events = [_][]const u8{
        "{\"output_segment_begin\":{\"index\":0,\"turn\":1,\"group\":0}}",
        "{\"text_chunk\":\"SECRET-\"}",
        "{\"output_segment_end\":{\"index\":0,\"turn\":1,\"group\":0,\"disposition\":\"commentary\",\"bytes\":7}}",
        "{\"output_segment_begin\":{\"index\":1,\"turn\":2,\"group\":1}}",
        "{\"text_chunk\":\"KEY\"}",
        "{\"output_segment_end\":{\"index\":1,\"turn\":2,\"group\":1,\"disposition\":\"commentary\",\"bytes\":3}}",
        "{\"output_segment_begin\":{\"index\":2,\"turn\":3,\"group\":2}}",
        "{\"text_chunk\":\"done\"}",
        "{\"output_segment_end\":{\"index\":2,\"turn\":3,\"group\":2,\"disposition\":\"final\",\"bytes\":4}}",
    };
    for (events) |encoded| {
        var envelope = try testEnvelope(route, run.id, encoded);
        defer envelope.deinit();
        try control.applyEvent(&envelope);
    }
    try std.testing.expectEqualStrings("SECRET-KEYdone", run.assistant.list.items);
    var storage: [96 * 1024]u8 = undefined;
    const snapshot = try control.writeAggregateFixture(&storage);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "SECRET-KEY") == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        snapshot,
        "\"output\":{\"commentary\":[\"***\",\"\"],\"response\":\"done\",\"responseKind\":\"final\",\"provisional\":\"\",\"redacted\":true",
    ) != null);
}

test "event projection preserves commentary groups split by its credential suffix" {
    var control = try testRuntime();
    defer control.deinit();
    const task = &control.task_runtime.tasks[0].?;
    const run = &task.durable.runs[0].?;
    const route = task.runtime.routeId();
    const events = [_][]const u8{
        "{\"output_segment_begin\":{\"index\":0,\"turn\":1,\"group\":0}}",
        "{\"text_chunk\":\"SECRET-\"}",
        "{\"output_segment_end\":{\"index\":0,\"turn\":1,\"group\":0,\"disposition\":\"commentary\",\"bytes\":7}}",
        "{\"output_segment_begin\":{\"index\":1,\"turn\":2,\"group\":1}}",
        "{\"text_chunk\":\"KEY\"}",
        "{\"output_segment_end\":{\"index\":1,\"turn\":2,\"group\":1,\"disposition\":\"commentary\",\"bytes\":3}}",
        "{\"output_segment_begin\":{\"index\":2,\"turn\":3,\"group\":2}}",
        "{\"text_chunk\":\"done\"}",
        "{\"output_segment_end\":{\"index\":2,\"turn\":3,\"group\":2,\"disposition\":\"final\",\"bytes\":4}}",
    };
    for (events) |encoded| {
        var envelope = try testEnvelope(route, run.id, encoded);
        defer envelope.deinit();
        try control.applyEvent(&envelope);
    }
    try std.testing.expectEqualStrings("***done", run.assistant.list.items);
    try std.testing.expectEqualSlices(u64, &.{ 0, 3 }, run.commentary_ends[0..run.commentary_count]);
    try std.testing.expectEqual(@as(?usize, 3), run.assistant_output_start);
    var storage: [96 * 1024]u8 = undefined;
    const snapshot = try control.writeAggregateFixture(&storage);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "SECRET-KEY") == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        snapshot,
        "\"output\":{\"commentary\":[\"\",\"***\"],\"response\":\"done\"",
    ) != null);
}

test "discarded output requires an in-group retry without committing bytes" {
    var control = try testRuntime();
    defer control.deinit();
    const task = &control.task_runtime.tasks[0].?;
    const run = &task.durable.runs[0].?;
    const route = task.runtime.routeId();
    const events = [_][]const u8{
        "{\"output_segment_begin\":{\"index\":0,\"turn\":1,\"group\":4}}",
        "{\"text_chunk\":\"rolled back\"}",
        "{\"output_segment_end\":{\"index\":0,\"turn\":1,\"group\":4,\"disposition\":\"discarded\",\"bytes\":11}}",
    };
    const expected_slots = [_]u32{ 0, 1, 0 };
    for (events, expected_slots) |encoded, slots| {
        var envelope = try testEnvelope(route, 7, encoded);
        defer envelope.deinit();
        try control.applyEvent(&envelope);
        try std.testing.expectEqual(slots, run.outputPartCount());
    }
    try std.testing.expectEqualStrings("", run.assistant.list.items);

    var wrong_group = try testEnvelope(
        route,
        7,
        "{\"output_segment_begin\":{\"index\":1,\"turn\":1,\"group\":5}}",
    );
    defer wrong_group.deinit();
    try std.testing.expectError(
        error.InvalidOutputSegment,
        control.applyEvent(&wrong_group),
    );
}

test "AgentCore RunState refines typed activity without owning RunPhase and rejects stale transitions" {
    var control = try testRuntime();
    defer control.deinit();
    const task = &control.task_runtime.tasks[0].?;
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
    try control.applyEvent(&starting);
    try std.testing.expectEqual(lifecycle.RunStatePhase.starting, run.agent_phase.?);
    try std.testing.expectEqual(@as(u64, 1), run.agent_transition_seq.?);
    try std.testing.expectEqual(host_phase, run.active_phase);
    try std.testing.expectEqual(task_test_state.RunActivity.starting, run.observed_activity);

    var executing = try testEnvelope(
        route,
        7,
        "{\"run_state\":{\"run_id\":7,\"transition_seq\":2,\"phase\":\"executing_tools\",\"turn\":1,\"tool_calls\":2,\"in_flight_tools\":[{\"tool_call_id\":\"tool-1\",\"name\":\"Read\"},{\"tool_call_id\":\"tool-2\",\"name\":\"Bash\"}]}}",
    );
    defer executing.deinit();
    try control.applyEvent(&executing);
    try std.testing.expectEqual(lifecycle.RunStatePhase.executing_tools, run.agent_phase.?);
    try std.testing.expectEqual(@as(u32, 1), run.agent_turn);
    try std.testing.expectEqual(@as(u32, 2), run.agent_tool_calls);
    try std.testing.expectEqual(@as(u32, 2), run.agent_in_flight_tools);
    try std.testing.expectEqual(
        @as(?u32, 2),
        run.observed_activity.executing_tools.in_flight,
    );

    var stale = try testEnvelope(
        route,
        7,
        "{\"run_state\":{\"run_id\":7,\"transition_seq\":1,\"phase\":\"failed\",\"turn\":9,\"tool_calls\":9,\"in_flight_tools\":[]}}",
    );
    defer stale.deinit();
    try control.applyEvent(&stale);
    try std.testing.expectEqual(lifecycle.RunStatePhase.executing_tools, run.agent_phase.?);
    try std.testing.expectEqual(
        @as(?u32, 2),
        run.observed_activity.executing_tools.in_flight,
    );

    var cross_run = try testEnvelope(
        route,
        7,
        "{\"run_state\":{\"run_id\":99,\"transition_seq\":3,\"phase\":\"failed\",\"turn\":9,\"tool_calls\":9,\"in_flight_tools\":[]}}",
    );
    defer cross_run.deinit();
    try control.applyEvent(&cross_run);
    try std.testing.expect(run.agent_observation_degraded);
    try std.testing.expectEqual(lifecycle.RunStatePhase.executing_tools, run.agent_phase.?);
    try std.testing.expectEqual(host_phase, run.active_phase);
}

test "protocol retry is replaced by the next forward activity" {
    var control = try testRuntime();
    defer control.deinit();
    const task = &control.task_runtime.tasks[0].?;
    const run = &task.durable.runs[0].?;
    const route = task.runtime.routeId();

    var retry = try testEnvelope(
        route,
        run.id,
        "{\"retry_notice\":{\"attempt\":2,\"max\":3,\"delay_ms\":250}}",
    );
    defer retry.deinit();
    try control.applyEvent(&retry);
    try std.testing.expectEqual(
        @as(?u32, 2),
        run.observed_activity.retrying_provider.attempt,
    );
    try std.testing.expectEqual(
        @as(?u64, 250),
        run.observed_activity.retrying_provider.delay_ms,
    );

    var generating = try testEnvelope(
        route,
        run.id,
        "{\"run_state\":{\"run_id\":7,\"transition_seq\":1,\"phase\":\"generating\",\"turn\":1,\"tool_calls\":0,\"in_flight_tools\":[]}}",
    );
    defer generating.deinit();
    try control.applyEvent(&generating);
    try std.testing.expectEqual(
        task_test_state.RunActivity.waiting_model,
        run.observed_activity,
    );
}

test "Conversation context observation survives Runs and clears with attachment" {
    var control = try testRuntime();
    defer control.deinit();
    const task = &control.task_runtime.tasks[0].?;
    const run = &task.durable.runs[0].?;
    const route = task.runtime.routeId();

    var warning = try testEnvelope(
        route,
        run.id,
        "{\"context_warning\":{\"current_tokens\":90,\"warning_threshold\":80,\"auto_compact_threshold\":100,\"blocking_limit\":120,\"level\":\"warning\"}}",
    );
    defer warning.deinit();
    try control.applyEvent(&warning);
    try std.testing.expectEqual(
        task_test_state.ContextPressureSeverity.warning,
        task.conversation_observation.pressure.?.severity,
    );
    try std.testing.expectEqual(
        run.id,
        task.conversation_observation.pressure.?.source_run_id,
    );

    var compacting = try testEnvelope(
        route,
        run.id,
        "{\"run_state\":{\"run_id\":7,\"transition_seq\":1,\"phase\":\"compacting\",\"turn\":1,\"tool_calls\":0,\"in_flight_tools\":[]}}",
    );
    defer compacting.deinit();
    try control.applyEvent(&compacting);
    var compacted = try testEnvelope(
        route,
        run.id,
        "{\"auto_compact\":{\"dropped\":4,\"kept\":8,\"before_tokens\":110,\"after_tokens\":70}}",
    );
    defer compacted.deinit();
    try control.applyEvent(&compacted);
    try std.testing.expect(task.conversation_observation.pressure == null);
    try std.testing.expectEqual(
        @as(u64, 70),
        task.conversation_observation.last_auto_compact.?.after_tokens,
    );
    try std.testing.expectEqual(
        task_test_state.RunActivity.waiting_model,
        run.observed_activity,
    );
    var context_storage: [96 * 1024]u8 = undefined;
    const context_snapshot = try control.writeAggregateFixture(&context_storage);
    try std.testing.expect(std.mem.indexOf(
        u8,
        context_snapshot,
        "\"context\":{\"pressure\":null,\"lastAutoCompact\":{\"sourceRunId\":\"7\",\"dropped\":\"4\",\"kept\":\"8\",\"beforeTokens\":\"110\",\"afterTokens\":\"70\"}}",
    ) != null);

    control.releaseTaskAttachmentNoFail(task, .cold_start);
    try std.testing.expect(task.conversation_observation.pressure == null);
    try std.testing.expect(task.conversation_observation.last_auto_compact == null);
}

test "AgentCore RunState accepts a zero first transition sequence" {
    var control = try testRuntime();
    defer control.deinit();
    const task = &control.task_runtime.tasks[0].?;
    const route = task.runtime.routeId();
    var first = try testEnvelope(
        route,
        7,
        "{\"run_state\":{\"run_id\":7,\"transition_seq\":0,\"phase\":\"starting\",\"turn\":0,\"tool_calls\":0,\"in_flight_tools\":[]}}",
    );
    defer first.deinit();
    try control.applyEvent(&first);
    const run = &task.durable.runs[0].?;
    try std.testing.expectEqual(@as(u64, 0), run.agent_transition_seq.?);
    try std.testing.expectEqual(lifecycle.RunStatePhase.starting, run.agent_phase.?);
}

test "event projection failure routes by Agent Session identity not product Task identity" {
    var control = try testRuntime();
    defer control.deinit();
    const task = &control.task_runtime.tasks[0].?;
    task.runtime.attached().?.binding = task_test_agent_session.Binding.testFixture(99);

    control.recordEventProjectionFailure(task.durable.id, 7);
    try std.testing.expect(task.durable.runs[0].?.event_projection_failure == null);
    try std.testing.expect(control.task_runtime.continuationAvailable(
        task.durable.id,
        control.taskRuntimeProjectionEffects(),
    ));

    control.recordEventProjectionFailure(task.runtime.routeId(), 7);
    try std.testing.expectEqual(
        EventProjectionFailure.consumer_rejected,
        task.durable.runs[0].?.event_projection_failure.?,
    );
    // The projection failure is a Run-level product fact. Continuation is
    // owned by the Session disposition and stays available.
    try std.testing.expect(control.task_runtime.continuationAvailable(
        task.durable.id,
        control.taskRuntimeProjectionEffects(),
    ));
}

test "Runtime shutdown releases current and Task-owned execution generations" {
    var control = try testRuntime();
    try TestSupport.prepareMetaskDefault(&control, 2);
    try control.beginDefaultExecutionReplacement();
    var replacement = try models_contract.OwnedConfig.initOwned(
        std.testing.allocator,
        .metask,
        .anthropic_messages,
        try std.testing.allocator.dupe(u8, "fixture-model-2"),
        try std.testing.allocator.dupe(
            u8,
            models_contract.metask_anthropic_messages_url,
        ),
        2,
        try std.testing.allocator.dupe(u8, "SECRET-KEY-2"),
        "",
    );
    errdefer replacement.deinit();
    try control.prepareExecutionInstall(replacement.input());
    control.installExecutionNoFail(&replacement);
    control.endExecutionReplacementNoFail();
    control.deinit();
}

test "terminal publication is allocation-free write-once bounded history" {
    var control = try testRuntime();
    defer control.deinit();
    defer detachTaskForTest(&control, &control.task_runtime.tasks[0].?);
    const run = &control.task_runtime.tasks[0].?.durable.runs[0].?;
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
    var compact = TestCompactRecord{
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
    var control = try testRuntime();
    defer control.deinit();
    const task = &control.task_runtime.tasks[0].?;
    defer detachTaskForTest(&control, task);

    foldTerminalDisposition(task, .poisoned);
    try std.testing.expectEqual(TaskLifecycle.open, taskLifecycle(task));
    try std.testing.expectEqual(
        ContinuationUnavailableReason.session_poisoned,
        control.task_runtime.continuationProjection(
            task.durable.id,
            control.taskRuntimeProjectionEffects(),
        ).?.unavailable,
    );

    try std.testing.expect(task.runtime.beginClosing());
    foldTerminalDisposition(task, .reusable);
    try std.testing.expectEqual(TaskLifecycle.closing, taskLifecycle(task));
    try std.testing.expectEqual(
        ContinuationUnavailableReason.closing,
        control.task_runtime.continuationProjection(
            task.durable.id,
            control.taskRuntimeProjectionEffects(),
        ).?.unavailable,
    );
}

test "poisoned Session close preserves ownership until successful release" {
    const Harness = struct {
        fn complete(
            binding: *task_test_agent_session.Binding,
            completion: *std.atomic.Value(CloseCompletion),
            result: CloseCompletion,
        ) void {
            if (result == .closed) binding.markReleasedForTest();
            completion.store(result, .release);
        }
    };
    const cases = [_]struct {
        completion: CloseCompletion,
        expected_health: ?task_test_attachment.AttachedHealth,
        discarding_restore: bool = false,
    }{
        .{ .completion = .closed, .expected_health = null },
        .{ .completion = .failed_reusable, .expected_health = .available },
        .{ .completion = .failed_reusable, .expected_health = .session_poisoned, .discarding_restore = true },
        .{ .completion = .failed_poisoned, .expected_health = .session_poisoned },
        .{ .completion = .failed_closing, .expected_health = null },
    };

    for (cases) |case| {
        var control = try testRuntime();
        defer control.deinit();
        const task = &control.task_runtime.tasks[0].?;
        defer detachTaskForTest(&control, task);
        task.runtime.active_operation = .none;
        task.runtime.discarding_restore = case.discarding_restore;
        task.runtime.active_run_id = 0;
        const route_id = task.runtime.routeId();
        foldTerminalDisposition(task, .poisoned);
        try std.testing.expect(control.task_runtime.requestPoisonedSessionCloses());
        try std.testing.expect(task.runtime.close_requested);

        // The close worker is simulated here so each typed completion can be
        // checked independently without teaching the fixture Binding to own a
        // second close implementation.
        task.runtime.close_requested = false;
        try std.testing.expect(task.runtime.beginClosing());
        task.runtime.close_completion.store(.running, .release);
        task.runtime.close_thread = try std.Thread.spawn(.{}, Harness.complete, .{
            task.runtime.closingWorkerBinding().?,
            &task.runtime.close_completion,
            case.completion,
        });
        for (0..10_000) |_| {
            if (task.runtime.close_completion.load(.acquire) == case.completion) break;
            std.Thread.yield() catch {};
        }
        try std.testing.expectEqual(
            case.completion,
            task.runtime.close_completion.load(.acquire),
        );

        control.syncLifecycle();
        try std.testing.expect(task.runtime.close_thread == null);
        switch (case.completion) {
            .closed => {
                try std.testing.expect(task.runtime.live() == null);
                try std.testing.expectEqual(@as(u64, 0), task.runtime.routeId());
                try std.testing.expectEqual(
                    task_test_state.ConversationCoverage.excluded,
                    task.durable.runs[0].?.coverage,
                );
                try std.testing.expect(!task.runtime.close_failed);
            },
            .failed_reusable, .failed_poisoned => {
                const attached = task.runtime.attachedConst().?;
                try std.testing.expectEqual(case.expected_health.?, attached.health);
                try std.testing.expectEqual(route_id, task.runtime.routeId());
                try std.testing.expect(task.runtime.executionConst() != null);
                try std.testing.expect(task.runtime.close_failed);
                try std.testing.expectEqual(
                    task_test_state.ConversationCoverage.pending,
                    task.durable.runs[0].?.coverage,
                );
                try std.testing.expect(!control.task_runtime.requestPoisonedSessionCloses());
                try std.testing.expect(!task.runtime.close_requested);
            },
            .failed_closing => {
                try std.testing.expect(task.runtime.hasClosingSession());
                try std.testing.expectEqual(route_id, task.runtime.routeId());
                try std.testing.expect(task.runtime.executionConst() != null);
                try std.testing.expect(task.runtime.close_failed);
                try std.testing.expectEqual(TaskLifecycle.closing, taskLifecycle(task));
                try std.testing.expectEqual(
                    task_test_state.ConversationCoverage.pending,
                    task.durable.runs[0].?.coverage,
                );
            },
            .none, .running => unreachable,
        }
    }
}

test "approval unknown commit is resolved explicitly without retrying or quarantining the write" {
    const Catalog = struct {
        fn query(_: *anyopaque, _: lifecycle.CatalogQuery) anyerror!lifecycle.CatalogAcquisition {
            return error.CatalogUnavailable;
        }
    };
    const HeldExecutor = struct {
        queued_context: ?*anyopaque = null,
        cancel_callback: ?*const fn (*anyopaque) void = null,
        fn enqueue(context: *anyopaque, _: *anyopaque, job_context: *anyopaque, _: *const fn (*anyopaque) void, cancel_fn: *const fn (*anyopaque) void) error{ ExecutorShuttingDown, QueueFull }!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.queued_context = job_context;
            self.cancel_callback = cancel_fn;
        }
        fn cancel(context: *anyopaque, _: *anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            const job_context = self.queued_context orelse return false;
            self.cancel_callback.?(job_context);
            self.queued_context = null;
            return true;
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);
    const storage = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(storage);
    for ([_]TaskPersistenceCommit{ .committed, .failed }) |final| {
        var history = TestTaskPersistence{ .storage = storage };
        var control = try testRuntimeWith(.{ .task_persistence = history.capability(null) });
        defer control.deinit();
        control.canonical_user_home = try control.allocator.dupe(u8, home);
        control.skill.ports.catalog.query_fn = Catalog.query;
        const task = control.task_runtime.find(3).?;
        _ = commitTerminal(&task.durable.runs[0].?, .completed, .completed, null, .reusable, "", false);
        finalizeTestTerminalEvents(&control);
        _ = try control.setApprovalMode(3, .auto_review, task.durable.binding_epoch, 1);
        history.result = .outcome_unknown;
        for (0..2000) |_| {
            control.syncLifecycle();
            if (task.approval_change.?.phase == .outcome_unknown) break;
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        }
        try std.testing.expectEqual(.outcome_unknown, task.approval_change.?.phase);
        try std.testing.expect(task.approval_change.?.unknown_history != null);
        const retained = task.approval_change.?.unknown_history.?.bytes;
        const writes = history.commits;
        for (0..10) |_| control.syncLifecycle();
        try std.testing.expectEqual(@as(usize, 0), history.resolutions);
        try std.testing.expectEqual(writes, history.commits);
        // Cancelling a queued readback cannot decide the original write or
        // release its evidence. The executor has accepted but not run it.
        var held: HeldExecutor = .{};
        try control.task_runtime.queueApprovalResolution(3, history.capability(null), .{ .context = &held, .enqueue_fn = HeldExecutor.enqueue, .cancel_fn = HeldExecutor.cancel }, control.approvalNotifier());
        try std.testing.expect(HeldExecutor.cancel(&held, &held));
        control.syncLifecycle();
        try std.testing.expectEqual(retained.ptr, task.approval_change.?.unknown_history.?.bytes.ptr);
        try std.testing.expectEqual(.outcome_unknown, task.approval_change.?.phase);
        try std.testing.expectEqual(@as(usize, 0), history.resolutions);
        try std.testing.expect(!task.runtime.worker_leases.hasLive());
        // First explicit read remains indeterminate; the same candidate stays
        // owned and the ordinary recovery writer is never called.
        try std.testing.expectEqual(.outcome_unknown, control.recoverTaskHistory(control.currentRevision()));
        for (0..2000) |_| {
            const pending = pending: {
                for (control.task_runtime.approval_jobs) |entry| if (entry) |slot| {
                    if (slot.task_id == 3) break :pending slot.job;
                };
                break :pending null;
            };
            if (pending == null) break;
            control.syncLifecycle();
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        }
        try std.testing.expectEqual(@as(usize, 1), history.resolutions);
        try std.testing.expectEqual(retained.ptr, task.approval_change.?.unknown_history.?.bytes.ptr);
        try std.testing.expect(control.task_runtime.approvalHistoryBlocked());
        try std.testing.expectEqual(writes, history.commits);
        history.resolution_result = final;
        history.result = .committed;
        try std.testing.expectEqual(.outcome_unknown, control.recoverTaskHistory(control.currentRevision()));
        for (0..2000) |_| {
            control.syncLifecycle();
            if (task.approval_change == null) break;
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        }
        try std.testing.expect(task.approval_change == null);
        try std.testing.expectEqual(@as(usize, 2), history.resolutions);
        try std.testing.expectEqual(@as(usize, 0), history.recoveries);
        try std.testing.expectEqual(.ready, control.task_persistence_health);
        try std.testing.expect(!control.task_runtime.approvalHistoryBlocked());
        try std.testing.expectEqual(final == .committed, task.durable.permission_review_delegated);
        try std.testing.expectEqual(@as(u64, if (final == .committed) 2 else 1), task.durable.approval_revision);
        try std.testing.expectEqual(@as(@TypeOf(task.approval_result.?.outcome), if (final == .committed) .completed else .failed), task.approval_result.?.outcome);
        try std.testing.expect(!task.runtime.worker_leases.hasLive());
    }
}

test "canonical prompt title and terminal diagnostic never retain the registered credential" {
    var control = try testRuntime();
    defer control.deinit();
    const task = &control.task_runtime.tasks[0].?;

    try control.renameTask(task.durable.id, "Review SECRET-KEY usage");
    try std.testing.expect(std.mem.indexOf(u8, task.durable.title, "SECRET-KEY") == null);
    try std.testing.expect(task.durable.title_redacted);

    const slot = try control.reserveRunRecord(
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
    var control = try testRuntime();
    defer control.deinit();
    const task = &control.task_runtime.tasks[0].?;
    product_workspace.testing.overwriteProjectedRoot(
        &control.workspace,
        1,
        "SECRET-KEY",
    );
    task.durable.archived = true;
    control.releaseTaskAttachmentNoFail(task, .cold_start);
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
    finalizeTestTerminalEvents(&control);

    try control.deleteTask(3);
    try std.testing.expect(control.task_runtime.tasks[0] == null);
    const workspace_projection = product_workspace.testing.projectedRoot(
        &control.workspace,
        1,
    );
    try std.testing.expect(workspace_projection.redacted);
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            workspace_projection.value,
            "SECRET-KEY",
        ) == null,
    );
}

test "Runtime projection preserves text bytes with bounded geometric growth" {
    var control = try testRuntime();
    defer control.deinit();

    const chunk = "0123456789abcdef";
    for (0..2048) |_| {
        var envelope = try testEnvelope(3, 7, "{\"text_chunk\":\"0123456789abcdef\"}");
        defer envelope.deinit();
        try control.applyEvent(&envelope);
    }
    const run = findRun(control.task_runtime.tasks[0].?.durable.runs, 7).?;
    try std.testing.expectEqual(@as(usize, chunk.len * 2048), run.assistant.list.items.len);
    for (0..2048) |index|
        try std.testing.expectEqualStrings(chunk, run.assistant.list.items[index * chunk.len ..][0..chunk.len]);
    var overflow = try testEnvelope(3, 7, "{\"text_chunk\":\"x\"}");
    defer overflow.deinit();
    try std.testing.expectError(error.ProjectionCapacity, control.applyEvent(&overflow));
    try std.testing.expect(run.assistant.list.capacity <= control.limits.max_assistant_message_bytes);
    try std.testing.expect(control.projection_bytes <= control.limits.max_projection_bytes);
}

test "Runtime snapshot budget includes JSON escaping and structural overhead" {
    const limits = Limits{};
    const worst_case = worstCaseSnapshotBytes(limits).?;
    try std.testing.expect(worst_case <= limits.max_snapshot_bytes);
    try std.testing.expect(worst_case > 1024 * 1024);
    const additional_skill_bytes = skillManagementAdditionalSnapshotBytes(limits).?;
    try std.testing.expect(additional_skill_bytes >= (limits.max_workspaces + 1) * limits.max_catalog_skills * skill_asset_snapshot_overhead);
    try std.testing.expect(additional_skill_bytes >= @min((limits.max_workspaces + 1) * limits.max_catalog_projection_bytes, limits.max_projection_bytes) * json_string_expansion);
    var exhausted_skill_limits = limits;
    exhausted_skill_limits.max_workspaces = std.math.maxInt(usize);
    try std.testing.expectEqual(@as(?usize, null), skillManagementAdditionalSnapshotBytes(exhausted_skill_limits));
    try std.testing.expectEqual(@as(usize, 1536 * 1024), limits.max_projection_bytes);
    try std.testing.expectEqual(@as(usize, 16), limits.max_runs_per_task);
    const file_change_budget = fileChangeSnapshotAdditionalBytes(limits).?;
    try std.testing.expect(file_change_budget >
        limits.max_tasks * limits.max_runs_per_task *
            file_change_collection_snapshot_overhead);
    try std.testing.expect(worst_case >= file_change_budget);
    const single_pending_budget = limits.max_pending_ui_json_bytes * pending_ui_reencode_expansion + pending_ui_snapshot_overhead;
    try std.testing.expect(worst_case >= single_pending_budget * limits.max_pending_ui_requests);

    var control = try testRuntime();
    defer control.deinit();
    const run = findRun(control.task_runtime.tasks[0].?.durable.runs, 7).?;
    const remaining = @min(
        control.limits.max_assistant_message_bytes,
        control.limits.max_projection_bytes - control.projection_bytes,
    );
    const controls = try std.testing.allocator.alloc(u8, remaining);
    defer std.testing.allocator.free(controls);
    @memset(controls, 1);
    try control.appendTrackedText(&run.assistant, controls, control.limits.max_assistant_message_bytes);
    _ = control.redactTrackedText(&run.assistant, run.redaction_secret);
    run.commentary_count = 1;
    run.commentary_ends[0] = @intCast(run.assistant.committed_len);

    const snapshot_storage = try std.testing.allocator.alloc(u8, control.limits.max_snapshot_bytes);
    defer std.testing.allocator.free(snapshot_storage);
    const snapshot = try control.writeAggregateFixture(snapshot_storage);
    try std.testing.expect(snapshot.len > controls.len * 5);
}

test "production pending UI concurrency fits the snapshot store with file changes" {
    var limits = Limits{};
    limits.max_pending_ui_requests = 16;
    try std.testing.expect(worstCaseSnapshotBytes(limits).? <= limits.max_snapshot_bytes);
}

fn installMaximumAccountProjection(control: *Runtime) !void {
    const account_id: [account_contract.Limits.account_id_bytes]u8 =
        @splat('a');
    const display_name: [account_contract.Limits.display_name_bytes]u8 =
        @splat('d');
    const email_hint: [account_contract.Limits.email_hint_bytes]u8 =
        @splat('e');
    const phone_hint: [account_contract.Limits.phone_hint_bytes]u8 =
        @splat('1');
    const diagnostic: [account_contract.Limits.safe_diagnostic_bytes]u8 =
        @splat('x');
    control.commitAccountFactNoFail(.{
        .kind = .session_changed,
        .view = .{
            .state = .authenticated,
            .account_id = &account_id,
            .display_name = &display_name,
            .email_hint = &email_hint,
            .phone_hint = &phone_hint,
            .concurrency_limit = std.math.maxInt(u32),
            .error_code = .invalid_state,
            .safe_diagnostic = &diagnostic,
        },
    });
    control.finishAccountCommitNoFail();
}

fn maximumProjectionFixture() !Runtime {
    return maximumProjectionFixtureWithTools(false, .{});
}

fn maximumProjectionFixtureWithTools(tool_inputs: bool, limits: Limits) !Runtime {
    test_agent_runtime.io = std.testing.io;
    var control = try Runtime.init(
        std.testing.allocator,
        std.testing.io,
        &test_agent_runtime,
        limits,
        .{},
    );
    errdefer control.deinit();
    try installMaximumAccountProjection(&control);

    for (0..limits.max_tasks) |task_index| {
        var root_storage: [64]u8 = undefined;
        const root = try std.fmt.bufPrint(
            &root_storage,
            "/maximum-task-{d}",
            .{task_index + 1},
        );
        product_workspace.testing.installOwned(&control.workspace, task_index, .{
            .id = @intCast(task_index + 1),
            .kind = if (task_index < limits.max_workspaces) .manual else .automatic,
            .automatic_task_id = if (task_index < limits.max_workspaces) 0 else @intCast(task_index + 1),
            .visible = task_index < limits.max_workspaces,
            .canonical_root = try control.copyBounded(root, limits.max_workspace_bytes),
            .projected_root_storage = try control.copyBounded(root, limits.max_workspace_bytes),
            .projected_root_len = root.len,
            .display_name_storage = try control.copyBounded("maximum", limits.max_workspace_bytes),
            .display_name_len = "maximum".len,
            .recent_order = if (task_index < limits.max_workspaces) @intCast(task_index + 1) else 0,
        });
        control.skill.registerWorkspaceOwned(.{
            .id = @intCast(task_index + 1),
            .epoch = 1,
            .catalog_authorized = true,
            .canonical_root = try control.allocator.dupe(u8, root),
        }, control.skillProjectionBudget());
        const execution_model = try control.copyBounded(
            "fixture-model",
            models_contract.Limits.model_id_bytes,
        );
        const runs = try control.allocator.alloc(?TestRunRecord, limits.max_runs_per_task);
        @memset(runs, null);
        const compacts = try control.allocator.alloc(
            ?TestCompactRecord,
            limits.max_compacts_per_task,
        );
        @memset(compacts, null);
        const ui_history = try control.allocator.alloc(?UiRecord, limits.max_ui_history_per_task);
        @memset(ui_history, null);
        for (0..limits.max_runs_per_task) |run_index| {
            const tools = try control.allocator.alloc(?ToolView, limits.max_tools_per_run);
            @memset(tools, null);
            const file_changes = try control.allocator.alloc(
                ?task_test_state.FileChangeView,
                limits.max_file_changes_per_run,
            );
            @memset(file_changes, null);
            const commentary_ends = try control.allocator.alloc(
                u64,
                limits.max_commentary_segments_per_run,
            );
            for (0..limits.max_tools_per_run) |tool_index| {
                var tool_id_storage: [32]u8 = undefined;
                const tool_id = try std.fmt.bufPrint(
                    &tool_id_storage,
                    "tool-{d}",
                    .{tool_index + 1},
                );
                tools[tool_index] = .{
                    .route_digest = toolRouteDigest(""),
                    .id = try control.copyBounded(tool_id, limits.max_tool_field_bytes),
                    .order = @intCast(tool_index + 1),
                    .name = try control.copyBounded(if (tool_inputs and task_index == 0) "Bash" else "tool", limits.max_tool_field_bytes),
                    .input = try control.copyBounded(if (tool_inputs and task_index == 0) "{\"command\":\"echo\"}" else "", limits.max_tool_field_bytes),
                    .progress = try control.copyBounded("", limits.max_tool_field_bytes),
                    .content = try control.copyBounded("", limits.max_tool_field_bytes),
                    .state = .completed,
                    .elapsed_ms = std.math.maxInt(u64),
                };
            }
            const change_order = limits.max_tools_per_run +
                limits.max_ui_history_per_task + 1;
            var change_id_storage: [task_test_state.file_change_product_id_capacity]u8 = undefined;
            const change_id = try std.fmt.bufPrint(
                &change_id_storage,
                "change-{d}-{d}-{d}",
                .{ task_index + 1, run_index + 1, change_order },
            );
            file_changes[0] = .{
                .route_digest = [_]u8{0} ** task_test_state.file_change_route_digest_bytes,
                .id = try control.copyBounded(
                    change_id,
                    limits.max_file_change_field_bytes,
                ),
                .order = @intCast(change_order),
                .kind = .modified,
                .status = .applied,
                .display_path = try control.copyBounded(
                    "maximum.zig",
                    limits.max_file_change_field_bytes,
                ),
                .before_bytes = std.math.maxInt(u64),
                .after_bytes = std.math.maxInt(u64),
                .diff_complete = false,
                .redacted = false,
            };
            runs[run_index] = .{
                .id = @intCast(run_index + 1),
                .generation = @intCast(run_index + 1),
                .execution_generation = 1,
                .execution_protocol = .anthropic_messages,
                .execution_model = execution_model,
                .permission_profile = .approval_required,
                .permission_interaction = .interactive,
                .input = .{ .text = .{
                    .value = try control.copyBounded(
                        "x",
                        limits.max_user_message_bytes,
                    ),
                } },
                .commentary_ends = commentary_ends,
                .tools = tools,
                .file_change_observation = .complete,
                .file_changes = file_changes,
                .terminal_publication = .init(.published),
                .terminal_payload = .{
                    .exclude_on_product_terminal = false,
                    .phase = .completed,
                    .outcome = .completed,
                    .cause = null,
                    .session_disposition_at_completion = .reusable,
                },
                .terminal_observed = true,
                .event_stream_finalized = true,
                .terminal_diagnostic = try control.allocTrackedCapacity(limits.max_terminal_diagnostic_bytes),
                .next_activity_order = @intCast(change_order + 1),
            };
        }
        for (0..limits.max_compacts_per_task) |compact_index| {
            compacts[compact_index] = .{
                .id = @intCast(compact_index + 1),
                .after_run_id = 1,
                .terminal_publication = .init(.published),
                .terminal_payload = .{
                    .exclude_on_product_terminal = false,
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
                .terminal_observed = true,
                .terminal_diagnostic = try control.allocTrackedCapacity(
                    limits.max_terminal_diagnostic_bytes,
                ),
            };
        }
        control.task_runtime.tasks[task_index] = .{
            .durable = .{
                .id = @intCast(task_index + 1),
                .recent_order = @intCast(task_index + 1),
                .execution_generation = 1,
                .execution_protocol = .anthropic_messages,
                .execution_model = execution_model,
                .permission_profile = .approval_required,
                .permission_interaction = .interactive,
                .workspace_id = @intCast(task_index + 1),
                .workspace_root = try control.copyBounded(root, limits.max_workspace_bytes),
                .title = try control.copyBounded("", limits.max_task_title_bytes),
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
            control.task_runtime.tasks[task_index].?.durable.ui_history[record_index] = record;
        }
        control.task_runtime.tasks[task_index].?.durable.ui_history_count = limits.max_ui_history_per_task;
    }
    product_workspace.testing.setIdentity(
        &control.workspace,
        @intCast(limits.max_tasks + 1),
        @intCast(limits.max_tasks + 1),
    );
    control.task_runtime.next_task_id = @intCast(limits.max_tasks + 1);
    control.task_runtime.next_recent_order = @intCast(limits.max_tasks + 1);

    const escaped_assistant = try std.testing.allocator.alloc(u8, limits.max_assistant_message_bytes);
    defer std.testing.allocator.free(escaped_assistant);
    @memset(escaped_assistant, 1);
    try control.appendTrackedText(
        &control.task_runtime.tasks[0].?.durable.runs[0].?.assistant,
        escaped_assistant,
        limits.max_assistant_message_bytes,
    );
    _ = control.redactTrackedText(
        &control.task_runtime.tasks[0].?.durable.runs[0].?.assistant,
        control.task_runtime.tasks[0].?.durable.runs[0].?.redaction_secret,
    );
    control.task_runtime.tasks[0].?.durable.runs[0].?.commentary_count = 1;
    control.task_runtime.tasks[0].?.durable.runs[0].?.commentary_ends[0] = @intCast(
        control.task_runtime.tasks[0].?.durable.runs[0].?.assistant.committed_len,
    );
    const remaining_projection = limits.max_projection_bytes - control.projection_bytes;
    const escaped_tool = try std.testing.allocator.alloc(
        u8,
        @min(limits.max_tool_field_bytes, remaining_projection),
    );
    defer std.testing.allocator.free(escaped_tool);
    @memset(escaped_tool, 2);
    try control.replaceTracked(
        &control.task_runtime.tasks[0].?.durable.runs[0].?.tools[0].?.content,
        escaped_tool,
        limits.max_tool_field_bytes,
    );
    if (limits.max_tasks == (Limits{}).max_tasks) try std.testing.expectEqual(limits.max_projection_bytes, control.projection_bytes);

    return control;
}

test "default snapshot budget contains the maximum structural projection" {
    const limits = Limits{};
    var control = try maximumProjectionFixture();
    defer control.deinit();
    const storage = try std.testing.allocator.alloc(u8, limits.max_snapshot_bytes);
    defer std.testing.allocator.free(storage);
    const snapshot = try control.writeAggregateFixture(storage);
    try std.testing.expect(snapshot.len <= worstCaseSnapshotBytes(limits).?);
    try std.testing.expect(snapshot.len <= limits.max_snapshot_bytes);

    var task_state = try control.buildTaskStateWire();
    defer task_state.deinit();
    const persistence_storage = try std.testing.allocator.alloc(
        u8,
        task_persistence.max_store_bytes,
    );
    defer std.testing.allocator.free(persistence_storage);
    const persisted = try task_persistence.encode(
        persistence_storage,
        task_state.state,
        control.taskPersistenceLimits(),
    );
    try std.testing.expect(persisted.len <= task_persistence.max_store_bytes);
    var raw = try task_persistence.decode(
        std.testing.allocator,
        persisted,
        control.taskPersistenceLimits(),
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
        control.taskPersistenceLimits(),
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
    var control = try testRuntime();
    defer control.deinit();
    try task_test_view.writePendingUi(
        &writer,
        control.taskTextProjection(),
        std.math.maxInt(u64),
        std.math.maxInt(u64),
        std.math.maxInt(u64),
        request,
    );
    try std.testing.expect(writer.buffered().len <= allowance);
}

test "permission pending projection follows responses and candidate scope" {
    var control = try testRuntime();
    defer control.deinit();
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
            .target = null,
        },
    };
    var candidate_storage: [4096]u8 = undefined;
    var candidate_writer = std.Io.Writer.fixed(&candidate_storage);
    try task_test_view.writePendingUi(
        &candidate_writer,
        control.taskTextProjection(),
        1,
        1,
        1,
        with_candidate,
    );
    const candidate_json = candidate_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, candidate_json, "allow_session") != null);
    try std.testing.expect(std.mem.indexOf(u8, candidate_json, "deny_session") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        candidate_json,
        "\"toolNamespace\":\"builtin\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        candidate_json,
        "\"toolBinding\":\"0000000000000000000000000000000000000000000000000000000000000000\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        candidate_json,
        "\"policyGeneration\":\"1\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        candidate_json,
        "\"canonicalArgumentsDigest\":\"3333333333333333333333333333333333333333333333333333333333333333\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        candidate_json,
        "\"candidate\":{\"ruleId\":\"2222222222222222222222222222222222222222222222222222222222222222\",\"scope\":\"exact_arguments\"}",
    ) != null);

    var file_request = with_candidate;
    file_request.tool.name = "Write";
    file_request.candidate.?.scope = .file_target;
    file_request.candidate.?.target = "C:/work/output.txt";
    var file_storage: [4096]u8 = undefined;
    var file_writer = std.Io.Writer.fixed(&file_storage);
    try task_test_view.writePendingUi(&file_writer, control.taskTextProjection(), 1, 7, 1, file_request);
    try std.testing.expectEqualStrings(std.mem.trim(u8, contract_fixture.permission_file_target, "\r\n"), file_writer.buffered());
    try std.testing.expect(std.mem.indexOf(u8, file_writer.buffered(), "\"scope\":\"file_target\",\"target\":\"C:/work/output.txt\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, file_writer.buffered(), "allow_session") != null);

    file_request.candidate.?.target = "C:/work/SECRET-KEY/output.txt";
    var private_storage: [4096]u8 = undefined;
    var private_writer = std.Io.Writer.fixed(&private_storage);
    try task_test_view.writePendingUi(&private_writer, control.taskTextProjection(), 1, 1, 1, file_request);
    const private_json = private_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, private_json, "SECRET-KEY") == null);
    try std.testing.expect(std.mem.indexOf(u8, private_json, "allow_session") == null);
    try std.testing.expect(std.mem.indexOf(u8, private_json, "deny_session") == null);
    try std.testing.expect(std.mem.indexOf(u8, private_json, "\"candidate\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, private_json, "\"redacted\":true") != null);

    const once_only = testPermissionRequest("Bash", "{}");
    var once_storage: [4096]u8 = undefined;
    var once_writer = std.Io.Writer.fixed(&once_storage);
    try task_test_view.writePendingUi(
        &once_writer,
        control.taskTextProjection(),
        1,
        1,
        1,
        once_only,
    );
    const once_json = once_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, once_json, "allow_session") == null);
    try std.testing.expect(std.mem.indexOf(u8, once_json, "deny_session") == null);
    try std.testing.expect(std.mem.indexOf(u8, once_json, "\"candidate\":null") != null);
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
    const projected = try task_test_state.permissionSummary(value);
    try std.testing.expectEqual(lifecycle.PermissionDecision.allow, projected.decision);
    try std.testing.expectEqual(lifecycle.PermissionDecisionSource.session_allow, projected.source);
    try std.testing.expectEqual(@as(u64, 7), projected.policy_generation);
    try std.testing.expect(projected.used_session_rule);
    try std.testing.expectEqualStrings("Bash", projected.toolName());
    try std.testing.expectEqualStrings(
        value.canonical_arguments_digest,
        projected.canonicalArgumentsDigest(),
    );
    try std.testing.expect(!@hasField(task_persistence.RunWire, "permission_provenance"));
}

test "Bash presentation interprets only bounded known evidence and sanitizes decoded text" {
    const cases = [_]struct {
        version: []const u8 = "metacodes.bash-result.v2",
        encoding: []const u8 = "utf-8",
        content_truncated: bool = false,
        input_truncated: bool = false,
        name: []const u8 = "Bash",
        supported: bool = true,
        stdout: []const u8 = "",
        raw: ?[]const u8 = null,
    }{
        .{},
        .{ .version = "future", .supported = false },
        .{ .encoding = "base64", .supported = false },
        .{ .content_truncated = true, .supported = false },
        .{ .input_truncated = true },
        .{ .name = "Read", .supported = false },
        .{ .stdout = "control\x01\n\r\t\\\" 界 SECRET-KEY" },
        .{ .raw = "{broken", .supported = false },
        .{ .raw = "{\"schema_version\":\"metacodes.bash-result.v2\"}", .supported = false },
    };
    for (cases) |case| {
        var control = try testRuntime();
        defer control.deinit();
        const content = try std.json.Stringify.valueAlloc(std.testing.allocator, .{
            .schema_version = case.version,
            .stdout = case.stdout,
            .stderr = "partial warning",
            .stdout_encoding = case.encoding,
            .stderr_encoding = "utf-8",
            .stdout_capture_complete = true,
            .stderr_capture_complete = false,
            .stdout_truncated = false,
            .stderr_truncated = false,
            .exit_code = @as(i32, 2),
            .unknown_metadata = "ignored",
        }, .{});
        defer std.testing.allocator.free(content);
        const event = try std.json.Stringify.valueAlloc(std.testing.allocator, .{ .tool_result = .{
            .id = "bash-presentation",
            .name = case.name,
            .input = "{\"command\":\"echo \\u0053ECRET-KEY\",\"description\":\"Inspect workspace\"}",
            .content = case.raw orelse content,
            .is_error = true,
            .elapsed_ms = @as(u64, 12),
        } }, .{});
        defer std.testing.allocator.free(event);
        var envelope = try testEnvelope(3, 7, event);
        defer envelope.deinit();
        try control.applyEvent(&envelope);
        const tool = &control.task_runtime.tasks[0].?.durable.runs[0].?.tools[0].?;
        tool.input_truncated = case.input_truncated;
        tool.content_truncated = case.content_truncated;
        var storage: [96 * 1024]u8 = undefined;
        const snapshot = try control.writeViewFixture(&storage, .{ .task_id = 3 });
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, snapshot, .{});
        defer parsed.deinit();
        const projected = parsed.value.object.get("taskPage").?.object.get("task").?.object.get("runs").?.array.items[0].object.get("tools").?.array.items[0];
        const bash = projected.object.get("bash").?;
        const tool_json = try std.json.Stringify.valueAlloc(std.testing.allocator, projected, .{});
        defer std.testing.allocator.free(tool_json);
        try std.testing.expect(tool_json.len <= tool_snapshot_overhead +
            json_string_expansion * (tool.id.len + tool.name.len + tool.input.len + tool.progress.len + tool.content.len));
        if (!std.mem.eql(u8, case.name, "Bash")) {
            try std.testing.expect(bash == .null);
            continue;
        }
        if (case.input_truncated) {
            try std.testing.expect(bash.object.get("command").? == .null);
        } else {
            const command = bash.object.get("command").?.string;
            try std.testing.expect(std.mem.indexOf(u8, command, "SECRET-KEY") == null);
            try std.testing.expect(projected.object.get("redacted").?.bool);
            try std.testing.expectEqualStrings("***", projected.object.get("input").?.string);
            try std.testing.expectEqualStrings("***", projected.object.get("content").?.string);
            try std.testing.expectEqualStrings("Inspect workspace", bash.object.get("description").?.string);
        }
        const result = bash.object.get("result").?;
        if (case.supported) {
            try std.testing.expectEqual(@as(i64, 2), result.object.get("exitCode").?.integer);
            if (case.stdout.len == 0) try std.testing.expectEqualStrings("", result.object.get("stdout").?.string);
            try std.testing.expect(!result.object.get("stdoutIncomplete").?.bool);
            try std.testing.expect(result.object.get("stderrIncomplete").?.bool);
        } else try std.testing.expect(result == .null);
        try std.testing.expectEqualStrings("failed", projected.object.get("state").?.string);
    }
}

test "built-in Tool presentation projects readable parameters and failures" {
    var limits = testLimits();
    limits.max_tools_per_run = 4;
    limits.max_projection_bytes = 128 * 1024;
    var control = try testRuntimeWithLimits(limits, .{});
    defer control.deinit();

    const events = [_][]const u8{
        "{\"tool_result\":{\"id\":\"read-1\",\"name\":\"Read\",\"input\":\"{\\\"file_path\\\":\\\"/workspace/main.ts\\\",\\\"offset\\\":12,\\\"limit\\\":3}\",\"content\":\"12\\tconst value = true;\",\"is_error\":false,\"elapsed_ms\":1}}",
        "{\"tool_result\":{\"id\":\"search-1\",\"name\":\"WebSearch\",\"input\":\"{\\\"query\\\":\\\"release notes\\\"}\",\"content\":\"provider wrapper\",\"is_error\":false,\"elapsed_ms\":3}}",
        "{\"tool_result\":{\"id\":\"fetch-1\",\"name\":\"WebFetch\",\"input\":\"{\\\"url\\\":\\\"https://example.com\\\",\\\"prompt\\\":\\\"Find limits\\\"}\",\"content\":\"{\\\"url\\\":\\\"https://example.com\\\",\\\"bytes\\\":12,\\\"content\\\":\\\"hello world\\\"}\",\"is_error\":false,\"elapsed_ms\":4}}",
        "{\"tool_result\":{\"id\":\"edit-1\",\"name\":\"Edit\",\"input\":\"{\\\"file_path\\\":\\\"/workspace/main.ts\\\"}\",\"content\":\"{\\\"error\\\":{\\\"detail\\\":\\\"Original text not found\\\"}}\",\"is_error\":true,\"elapsed_ms\":5}}",
    };
    for (events) |encoded| {
        var envelope = try testEnvelope(3, 7, encoded);
        defer envelope.deinit();
        try control.applyEvent(&envelope);
    }

    var storage: [128 * 1024]u8 = undefined;
    const snapshot = try control.writeAggregateFixture(&storage);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, snapshot, .{});
    defer parsed.deinit();
    const tools = parsed.value.object.get("tasks").?.array.items[0].object.get("runs").?.array.items[0].object.get("tools").?.array.items;
    try std.testing.expectEqual(@as(usize, events.len), tools.len);
    try std.testing.expectEqualStrings("read", tools[0].object.get("presentation").?.object.get("kind").?.string);
    try std.testing.expectEqualStrings("12", tools[0].object.get("presentation").?.object.get("offset").?.string);
    try std.testing.expectEqualStrings("web_search", tools[1].object.get("presentation").?.object.get("kind").?.string);
    try std.testing.expectEqualStrings("release notes", tools[1].object.get("presentation").?.object.get("query").?.string);
    const fetch = tools[2].object.get("presentation").?.object;
    try std.testing.expectEqualStrings("web_fetch", fetch.get("kind").?.string);
    try std.testing.expectEqualStrings("hello world", fetch.get("result").?.object.get("content").?.string);
    try std.testing.expectEqualStrings("edit", tools[3].object.get("presentation").?.object.get("kind").?.string);
    try std.testing.expectEqualStrings("Original text not found", tools[3].object.get("errorDetail").?.string);
}

test "Runtime projects tools and full-width usage without parsing protocol in Renderer" {
    var control = try testRuntime();
    defer control.deinit();

    const events = [_][]const u8{
        "{\"tool_start\":{\"id\":\"tool-1\",\"name\":\"Bash\",\"input\":\"{\\\"command\\\":\\\"printf ok\\\"}\"}}",
        "{\"tool_progress\":{\"id\":\"tool-1\",\"text\":\"running\"}}",
        "{\"tool_result\":{\"id\":\"tool-1\",\"name\":\"Bash\",\"input\":\"{}\",\"content\":\"stdout\\nexit 0\",\"is_error\":false,\"elapsed_ms\":18446744073709551615}}",
        "{\"usage\":{\"input_tokens\":18446744073709551615,\"output_tokens\":0,\"cache_read_input_tokens\":0,\"cache_creation_input_tokens\":0}}",
    };
    for (events) |encoded| {
        var envelope = try testEnvelope(3, 7, encoded);
        defer envelope.deinit();
        try control.applyEvent(&envelope);
    }

    var snapshot_storage: [96 * 1024]u8 = undefined;
    const snapshot = try control.writeAggregateFixture(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"name\":\"Bash\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "stdout\\nexit 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"elapsedMs\":\"18446744073709551615\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"input\":\"18446744073709551615\"") != null);
}

test "Runtime projects typed AgentCore file references into bounded tool entries" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var control = try testRuntime();
    defer control.deinit();

    const encoded = "{\"tool_result\":{\"id\":\"tool-1\",\"name\":\"Read\",\"input\":\"{}\",\"content\":\"ok\",\"is_error\":false,\"elapsed_ms\":1,\"file_refs\":[{\"locator\":{\"workspace_path\":\"src/main.zig\"},\"title\":\"main.zig\",\"kind\":\"read\",\"range\":{\"start\":{\"line\":1,\"column\":1},\"end\":{\"line\":2,\"column\":1}}}]}}";
    var envelope = try testEnvelope(3, 7, encoded);
    defer envelope.deinit();
    try control.applyEvent(&envelope);

    var snapshot_storage: [96 * 1024]u8 = undefined;
    const snapshot = try control.writeAggregateFixture(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"fileRefs\":[{\"id\":\"file-3-1-1-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"displayPath\":\"src/main.zig\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"kind\":\"read\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"range\":") == null);
    try std.testing.expect(control.task_runtime.fileReference(
        3,
        7,
        "file-3-1-1-1",
    ) != null);
    try std.testing.expect(control.task_runtime.fileReference(
        4,
        7,
        "file-3-1-1-1",
    ) == null);
    try std.testing.expect(control.task_runtime.fileReference(
        3,
        8,
        "file-3-1-1-1",
    ) == null);
}

test "Runtime projects typed file changes without turning loss into Run failure" {
    var control = try testRuntime();
    defer control.deinit();

    const modified =
        "{\"file_changes\":{\"id\":\"tool-1\",\"name\":\"Edit\",\"changes\":[{\"locator\":{\"workspace_path\":\"src/main.zig\"},\"kind\":\"modified\",\"status\":\"applied\",\"tool\":\"Edit\",\"tool_use_id\":\"tool-1\",\"agent_depth\":0,\"before_bytes\":3,\"after_bytes\":4,\"diff_complete\":true}],\"overflow\":false,\"lost\":false}}";
    var envelope = try testEnvelope(3, 7, modified);
    defer envelope.deinit();
    try control.applyEvent(&envelope);
    // Replayed callback identity is idempotent.
    try control.applyEvent(&envelope);

    const run = &control.task_runtime.tasks[0].?.durable.runs[0].?;
    const change = &run.file_changes[0].?;
    try std.testing.expectEqual(task_test_state.FileChangeObservation.collecting, run.file_change_observation.?);
    try std.testing.expectEqual(task_test_state.FileChangeKind.modified, change.kind);
    try std.testing.expectEqual(task_test_state.FileChangeStatus.applied, change.status);
    try std.testing.expectEqualStrings("src/main.zig", change.display_path);
    try std.testing.expectEqual(@as(u64, 3), change.before_bytes);
    try std.testing.expectEqual(@as(u64, 4), change.after_bytes);
    try std.testing.expect(run.file_changes[1] == null);

    const invalid_and_lost =
        "{\"file_changes\":{\"id\":\"tool-2\",\"name\":\"Edit\",\"changes\":[{\"locator\":{\"uri\":\"file:///outside\"},\"kind\":\"modified\",\"status\":\"partial\",\"tool\":\"Edit\",\"tool_use_id\":\"tool-2\",\"agent_depth\":2,\"before_bytes\":4,\"after_bytes\":5,\"diff_complete\":false}],\"overflow\":true,\"lost\":false}}";
    var lost_envelope = try testEnvelope(3, 7, invalid_and_lost);
    defer lost_envelope.deinit();
    try control.applyEvent(&lost_envelope);
    try std.testing.expectEqual(task_test_state.FileChangeObservation.incomplete, run.file_change_observation.?);
    try std.testing.expect(run.file_changes[1] == null);
    try std.testing.expect(run.event_projection_failure == null);
}

test "Runtime preserves the complete visible file change protocol matrix" {
    var limits = testLimits();
    limits.max_file_changes_per_run = 8;
    var control = try testRuntimeWithLimits(limits, .{});
    defer control.deinit();

    const encoded =
        "{\"file_changes\":{\"id\":\"tool-matrix\",\"name\":\"Edit\",\"changes\":[" ++
        "{\"locator\":{\"workspace_path\":\"src/new.zig\"},\"kind\":\"created\",\"status\":\"applied\",\"tool\":\"Write\",\"tool_use_id\":\"tool-matrix\",\"agent_depth\":1,\"before_bytes\":0,\"after_bytes\":10,\"diff_complete\":true}," ++
        "{\"locator\":{\"workspace_path\":\"src/repeat.zig\"},\"kind\":\"modified\",\"status\":\"applied\",\"tool\":\"Edit\",\"tool_use_id\":\"tool-matrix\",\"agent_depth\":2,\"before_bytes\":10,\"after_bytes\":11,\"diff_complete\":true}," ++
        "{\"locator\":{\"workspace_path\":\"src/repeat.zig\"},\"kind\":\"modified\",\"status\":\"partial\",\"tool\":\"Edit\",\"tool_use_id\":\"tool-matrix\",\"agent_depth\":3,\"before_bytes\":11,\"after_bytes\":12,\"diff_complete\":false}," ++
        "{\"locator\":{\"workspace_path\":\"src/old.zig\"},\"kind\":\"deleted\",\"status\":\"applied\",\"tool\":\"Delete\",\"tool_use_id\":\"tool-matrix\",\"agent_depth\":4,\"before_bytes\":9,\"after_bytes\":0,\"diff_complete\":true}," ++
        "{\"locator\":{\"workspace_path\":\"src/to.zig\"},\"from_locator\":{\"workspace_path\":\"src/from.zig\"},\"kind\":\"moved\",\"status\":\"partial\",\"tool\":\"Move\",\"tool_use_id\":\"tool-matrix\",\"agent_depth\":5,\"before_bytes\":7,\"after_bytes\":7,\"diff_complete\":true}" ++
        "],\"overflow\":true,\"lost\":true}}";
    var envelope = try testEnvelope(3, 7, encoded);
    defer envelope.deinit();
    try control.applyEvent(&envelope);
    try control.applyEvent(&envelope);

    const run = &control.task_runtime.tasks[0].?.durable.runs[0].?;
    try std.testing.expectEqual(
        task_test_state.FileChangeObservation.incomplete,
        run.file_change_observation.?,
    );
    const expected_kinds = [_]task_test_state.FileChangeKind{
        .created,
        .modified,
        .modified,
        .deleted,
        .moved,
    };
    for (expected_kinds, 0..) |kind, index| {
        const change = &run.file_changes[index].?;
        try std.testing.expectEqual(kind, change.kind);
        try std.testing.expectEqual(@as(u64, index + 1), change.order);
    }
    try std.testing.expect(run.file_changes[5] == null);
    try std.testing.expectEqualStrings(
        "src/repeat.zig",
        run.file_changes[1].?.display_path,
    );
    try std.testing.expectEqualStrings(
        "src/repeat.zig",
        run.file_changes[2].?.display_path,
    );
    try std.testing.expectEqual(
        task_test_state.FileChangeStatus.partial,
        run.file_changes[2].?.status,
    );
    try std.testing.expect(!run.file_changes[2].?.diff_complete);
    try std.testing.expectEqualStrings(
        "src/from.zig",
        run.file_changes[4].?.from_display_path.?,
    );
    try std.testing.expectEqualStrings(
        "src/to.zig",
        run.file_changes[4].?.display_path,
    );
}

test "Runtime explicitly ignores non-visible file change statuses without loss" {
    var control = try testRuntime();
    defer control.deinit();

    const encoded =
        "{\"file_changes\":{\"id\":\"tool-hidden\",\"name\":\"Edit\",\"changes\":[" ++
        "{\"locator\":{\"workspace_path\":\"src/a.zig\"},\"kind\":\"modified\",\"status\":\"no_change\",\"tool\":\"Edit\",\"tool_use_id\":\"tool-hidden\",\"agent_depth\":1,\"before_bytes\":1,\"after_bytes\":1,\"diff_complete\":true}," ++
        "{\"locator\":{\"workspace_path\":\"src/b.zig\"},\"kind\":\"created\",\"status\":\"failed\",\"tool\":\"Write\",\"tool_use_id\":\"tool-hidden\",\"agent_depth\":2,\"before_bytes\":0,\"after_bytes\":0,\"diff_complete\":true}," ++
        "{\"locator\":{\"workspace_path\":\"src/c.zig\"},\"kind\":\"deleted\",\"status\":\"rejected\",\"tool\":\"Delete\",\"tool_use_id\":\"tool-hidden\",\"agent_depth\":3,\"before_bytes\":1,\"after_bytes\":1,\"diff_complete\":true}" ++
        "],\"overflow\":false,\"lost\":false}}";
    var envelope = try testEnvelope(3, 7, encoded);
    defer envelope.deinit();
    try control.applyEvent(&envelope);

    const run = &control.task_runtime.tasks[0].?.durable.runs[0].?;
    try std.testing.expectEqual(
        task_test_state.FileChangeObservation.collecting,
        run.file_change_observation.?,
    );
    try std.testing.expect(!run.file_changes_known_loss);
    try std.testing.expect(run.file_changes[0] == null);
}

test "Runtime degrades file change record path and diff capacity without rejecting the Run" {
    {
        var limits = testLimits();
        limits.max_file_change_field_bytes = 8;
        var control = try testRuntimeWithLimits(limits, .{});
        defer control.deinit();
        const encoded =
            "{\"file_changes\":{\"id\":\"tool-path\",\"name\":\"Edit\",\"changes\":[{\"locator\":{\"workspace_path\":\"src/a-long-name.zig\"},\"kind\":\"modified\",\"status\":\"applied\",\"tool\":\"Edit\",\"tool_use_id\":\"tool-path\",\"agent_depth\":0,\"before_bytes\":1,\"after_bytes\":2,\"diff_complete\":true}],\"overflow\":false,\"lost\":false}}";
        var envelope = try testEnvelope(3, 7, encoded);
        defer envelope.deinit();
        try control.applyEvent(&envelope);
        const run = &control.task_runtime.tasks[0].?.durable.runs[0].?;
        try std.testing.expectEqual(
            task_test_state.FileChangeObservation.incomplete,
            run.file_change_observation.?,
        );
        try std.testing.expect(run.file_changes[0] == null);
        try std.testing.expect(run.event_projection_failure == null);
        control.task_runtime.tasks[0].?.runtime.active_run_id = 0;
        _ = commitTerminal(run, .completed, .completed, null, .reusable, "", false);
        finalizeTestTerminalEvents(&control);
        try std.testing.expectEqual(task_test_state.RunOutcome.completed, run.terminal_payload.outcome);
    }

    {
        var control = try testRuntime();
        defer control.deinit();
        const encoded =
            "{\"file_changes\":{\"id\":\"tool-records\",\"name\":\"Edit\",\"changes\":[" ++
            "{\"locator\":{\"workspace_path\":\"a\"},\"kind\":\"created\",\"status\":\"applied\",\"tool\":\"Write\",\"tool_use_id\":\"tool-records\",\"agent_depth\":0,\"before_bytes\":0,\"after_bytes\":1,\"diff_complete\":true}," ++
            "{\"locator\":{\"workspace_path\":\"b\"},\"kind\":\"modified\",\"status\":\"applied\",\"tool\":\"Edit\",\"tool_use_id\":\"tool-records\",\"agent_depth\":0,\"before_bytes\":1,\"after_bytes\":2,\"diff_complete\":true}," ++
            "{\"locator\":{\"workspace_path\":\"c\"},\"kind\":\"deleted\",\"status\":\"applied\",\"tool\":\"Delete\",\"tool_use_id\":\"tool-records\",\"agent_depth\":0,\"before_bytes\":1,\"after_bytes\":0,\"diff_complete\":true}" ++
            "],\"overflow\":false,\"lost\":false}}";
        var envelope = try testEnvelope(3, 7, encoded);
        defer envelope.deinit();
        try control.applyEvent(&envelope);
        const run = &control.task_runtime.tasks[0].?.durable.runs[0].?;
        try std.testing.expect(run.file_changes[0] != null);
        try std.testing.expect(run.file_changes[1] != null);
        try std.testing.expectEqual(
            task_test_state.FileChangeObservation.incomplete,
            run.file_change_observation.?,
        );
        try std.testing.expect(run.event_projection_failure == null);
    }

    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var root_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const root_len = try tmp.dir.realPath(std.testing.io, &root_storage);
        var store = try file_change_store.FileStore.init(
            std.testing.io,
            root_storage[0..root_len],
        );
        defer store.deinit();
        var limits = testLimits();
        limits.max_file_change_diff_bytes = 8;
        var control = try testRuntimeWithLimits(limits, .{
            .file_change_store = .{ .file_store = &store },
        });
        defer control.deinit();
        const encoded =
            "{\"file_changes\":{\"id\":\"tool-diff-limit\",\"name\":\"Edit\",\"changes\":[{\"locator\":{\"workspace_path\":\"a\"},\"kind\":\"modified\",\"status\":\"applied\",\"tool\":\"Edit\",\"tool_use_id\":\"tool-diff-limit\",\"agent_depth\":0,\"before_bytes\":1,\"after_bytes\":2,\"unified_diff\":\"123456789\",\"diff_complete\":false}],\"overflow\":false,\"lost\":false}}";
        var envelope = try testEnvelope(3, 7, encoded);
        defer envelope.deinit();
        try control.applyEvent(&envelope);
        const run = &control.task_runtime.tasks[0].?.durable.runs[0].?;
        try std.testing.expect(run.file_changes[0] != null);
        try std.testing.expect(run.file_changes[0].?.artifact == null);
        try std.testing.expectEqual(
            task_test_state.FileChangeObservation.incomplete,
            run.file_change_observation.?,
        );
        try std.testing.expect(run.event_projection_failure == null);
    }
}

test "Runtime accepts only file change locators inside the owning workspace" {
    var limits = testLimits();
    limits.max_file_changes_per_run = 5;
    var control = try testRuntimeWithLimits(limits, .{});
    defer control.deinit();
    const workspace_root = if (builtin.os.tag == .windows)
        "C:\\workspace"
    else
        "/workspace";
    try control.replaceTracked(
        &control.task_runtime.tasks[0].?.durable.workspace_root,
        workspace_root,
        control.limits.max_workspace_bytes,
    );
    const encoded = if (builtin.os.tag == .windows)
        "{\"file_changes\":{\"id\":\"tool-paths\",\"name\":\"Edit\",\"changes\":[" ++
            "{\"locator\":{\"workspace_path\":\"src\\\\a.zig\"},\"kind\":\"modified\",\"status\":\"applied\",\"tool\":\"Edit\",\"tool_use_id\":\"tool-paths\",\"agent_depth\":0,\"before_bytes\":1,\"after_bytes\":2,\"diff_complete\":true}," ++
            "{\"locator\":{\"workspace_path\":\"..\\\\escape.zig\"},\"kind\":\"modified\",\"status\":\"applied\",\"tool\":\"Edit\",\"tool_use_id\":\"tool-paths\",\"agent_depth\":0,\"before_bytes\":1,\"after_bytes\":2,\"diff_complete\":true}," ++
            "{\"locator\":{\"absolute_path\":\"C:\\\\workspace\\\\src\\\\b.zig\"},\"kind\":\"created\",\"status\":\"applied\",\"tool\":\"Write\",\"tool_use_id\":\"tool-paths\",\"agent_depth\":0,\"before_bytes\":0,\"after_bytes\":1,\"diff_complete\":true}," ++
            "{\"locator\":{\"absolute_path\":\"C:\\\\workspace-evil\\\\c.zig\"},\"kind\":\"created\",\"status\":\"applied\",\"tool\":\"Write\",\"tool_use_id\":\"tool-paths\",\"agent_depth\":0,\"before_bytes\":0,\"after_bytes\":1,\"diff_complete\":true}," ++
            "{\"locator\":{\"uri\":\"file:///workspace/d.zig\"},\"kind\":\"modified\",\"status\":\"applied\",\"tool\":\"Edit\",\"tool_use_id\":\"tool-paths\",\"agent_depth\":0,\"before_bytes\":1,\"after_bytes\":2,\"diff_complete\":true}" ++
            "],\"overflow\":false,\"lost\":false}}"
    else
        "{\"file_changes\":{\"id\":\"tool-paths\",\"name\":\"Edit\",\"changes\":[" ++
            "{\"locator\":{\"workspace_path\":\"src/a.zig\"},\"kind\":\"modified\",\"status\":\"applied\",\"tool\":\"Edit\",\"tool_use_id\":\"tool-paths\",\"agent_depth\":0,\"before_bytes\":1,\"after_bytes\":2,\"diff_complete\":true}," ++
            "{\"locator\":{\"workspace_path\":\"../escape.zig\"},\"kind\":\"modified\",\"status\":\"applied\",\"tool\":\"Edit\",\"tool_use_id\":\"tool-paths\",\"agent_depth\":0,\"before_bytes\":1,\"after_bytes\":2,\"diff_complete\":true}," ++
            "{\"locator\":{\"absolute_path\":\"/workspace/src/b.zig\"},\"kind\":\"created\",\"status\":\"applied\",\"tool\":\"Write\",\"tool_use_id\":\"tool-paths\",\"agent_depth\":0,\"before_bytes\":0,\"after_bytes\":1,\"diff_complete\":true}," ++
            "{\"locator\":{\"absolute_path\":\"/workspace-evil/c.zig\"},\"kind\":\"created\",\"status\":\"applied\",\"tool\":\"Write\",\"tool_use_id\":\"tool-paths\",\"agent_depth\":0,\"before_bytes\":0,\"after_bytes\":1,\"diff_complete\":true}," ++
            "{\"locator\":{\"uri\":\"file:///workspace/d.zig\"},\"kind\":\"modified\",\"status\":\"applied\",\"tool\":\"Edit\",\"tool_use_id\":\"tool-paths\",\"agent_depth\":0,\"before_bytes\":1,\"after_bytes\":2,\"diff_complete\":true}" ++
            "],\"overflow\":false,\"lost\":false}}";
    var envelope = try testEnvelope(3, 7, encoded);
    defer envelope.deinit();
    try control.applyEvent(&envelope);

    const run = &control.task_runtime.tasks[0].?.durable.runs[0].?;
    try std.testing.expectEqualStrings("src/a.zig", run.file_changes[0].?.display_path);
    try std.testing.expectEqualStrings("src/b.zig", run.file_changes[1].?.display_path);
    try std.testing.expect(run.file_changes[2] == null);
    try std.testing.expectEqual(
        task_test_state.FileChangeObservation.incomplete,
        run.file_change_observation.?,
    );
    try std.testing.expect(run.event_projection_failure == null);
}

test "Runtime degrades saturated file change artifact admission without dropping metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_storage);
    var store = try file_change_store.FileStore.init(
        std.testing.io,
        root_storage[0..root_len],
    );
    defer store.deinit();
    var limits = testLimits();
    limits.max_file_changes_per_run = file_change_io.max_in_flight + 1;
    var control = try testRuntimeWithLimits(limits, .{
        .file_change_store = .{ .file_store = &store },
    });
    defer control.deinit();

    var encoded_storage: [32 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&encoded_storage);
    try writer.writeAll(
        "{\"file_changes\":{\"id\":\"tool-artifact-capacity\",\"name\":\"Edit\",\"changes\":[",
    );
    for (0..file_change_io.max_in_flight + 1) |index| {
        if (index != 0) try writer.writeByte(',');
        try writer.print(
            "{{\"locator\":{{\"workspace_path\":\"src/{d}.zig\"}},\"kind\":\"modified\",\"status\":\"applied\",\"tool\":\"Edit\",\"tool_use_id\":\"tool-artifact-capacity\",\"agent_depth\":0,\"before_bytes\":1,\"after_bytes\":2,\"unified_diff\":\"diff-{d}\",\"diff_complete\":true}}",
            .{ index, index },
        );
    }
    try writer.writeAll("],\"overflow\":false,\"lost\":false}}");
    var envelope = try testEnvelope(3, 7, writer.buffered());
    defer envelope.deinit();
    try control.applyEvent(&envelope);

    const run = &control.task_runtime.tasks[0].?.durable.runs[0].?;
    try std.testing.expectEqual(
        @as(u32, file_change_io.max_in_flight),
        run.pending_file_change_artifacts,
    );
    try std.testing.expect(run.file_changes[file_change_io.max_in_flight] != null);
    try std.testing.expect(run.file_changes[file_change_io.max_in_flight].?.artifact == null);
    try std.testing.expectEqual(
        task_test_state.FileChangeObservation.incomplete,
        run.file_change_observation.?,
    );
    try std.testing.expect(run.event_projection_failure == null);

    control.shutdownFileChangeExecutor();
    control.drainFileChangeCompletions(.{
        .context = &control,
        .complete_fn = discardFileChangeDiffCompletion,
    });
    try std.testing.expectEqual(@as(u32, 0), run.pending_file_change_artifacts);
    try std.testing.expectEqual(
        task_test_state.FileChangeObservation.incomplete,
        run.file_change_observation.?,
    );
}

test "Runtime stores credential-safe file change diffs outside task history" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_storage);
    var store = try file_change_store.FileStore.init(
        std.testing.io,
        root_storage[0..root_len],
    );
    defer store.deinit();
    var control = try testRuntimeWith(.{
        .file_change_store = .{ .file_store = &store },
    });
    defer control.deinit();

    const encoded =
        "{\"file_changes\":{\"id\":\"tool-diff\",\"name\":\"Edit\",\"changes\":[{\"locator\":{\"workspace_path\":\"src/main.zig\"},\"kind\":\"modified\",\"status\":\"applied\",\"tool\":\"Edit\",\"tool_use_id\":\"tool-diff\",\"agent_depth\":0,\"before_bytes\":3,\"after_bytes\":4,\"unified_diff\":\"@@ -1 +1 @@\\n-old\\n+SECRET-KEY\\n\",\"diff_complete\":true}],\"overflow\":false,\"lost\":false}}";
    var envelope = try testEnvelope(3, 7, encoded);
    defer envelope.deinit();
    try control.applyEvent(&envelope);

    const run = &control.task_runtime.tasks[0].?.durable.runs[0].?;
    try std.testing.expectEqual(@as(u32, 1), run.pending_file_change_artifacts);
    for (0..1_000) |_| {
        control.drainFileChangeCompletions(.{
            .context = &control,
            .complete_fn = discardFileChangeDiffCompletion,
        });
        if (run.pending_file_change_artifacts == 0) break;
        std.testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expectEqual(@as(u32, 0), run.pending_file_change_artifacts);
    const change = &run.file_changes[0].?;
    const artifact = change.artifact orelse return error.TestUnexpectedResult;
    try std.testing.expect(change.redacted);
    const restored = try store.readAlloc(
        std.testing.allocator,
        .{
            .task_id = 3,
            .run_generation = artifact.run_generation,
            .change_order = artifact.change_order,
            .digest = artifact.digest,
            .byte_size = artifact.byte_size,
        },
        control.limits.max_file_change_diff_bytes,
    );
    defer std.testing.allocator.free(restored);
    try std.testing.expect(std.mem.indexOf(u8, restored, "SECRET-KEY") == null);

    const Capture = struct {
        calls: usize = 0,
        content: [1024]u8 = undefined,
        content_len: usize = 0,
        complete: bool = false,
        redacted: bool = false,
        unavailable: ?FileChangeDiffReason = null,

        fn receive(context: *anyopaque, result: FileChangeDiffResult) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            switch (result) {
                .ready => |ready| {
                    std.debug.assert(ready.content.len <= self.content.len);
                    @memcpy(self.content[0..ready.content.len], ready.content);
                    self.content_len = ready.content.len;
                    self.complete = ready.complete;
                    self.redacted = ready.redacted;
                },
                .unavailable => |unavailable| self.unavailable = unavailable.reason,
            }
        }
    };
    var capture = Capture{};
    switch (control.beginFileChangeDiff(9, 3, 7, change.id)) {
        .queued => {},
        .immediate => return error.TestUnexpectedResult,
    }
    for (0..1_000) |_| {
        control.drainFileChangeCompletions(.{
            .context = &capture,
            .complete_fn = Capture.receive,
        });
        if (capture.calls != 0) break;
        std.testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expect(capture.unavailable == null);
    try std.testing.expect(capture.complete);
    try std.testing.expect(capture.redacted);
    try std.testing.expect(std.mem.indexOf(
        u8,
        capture.content[0..capture.content_len],
        "SECRET-KEY",
    ) == null);

    var snapshot_storage: [96 * 1024]u8 = undefined;
    const snapshot = try control.writeAggregateFixture(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"diffAvailable\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "SECRET-KEY") == null);

    const stored_identity: file_change_store.Identity = .{
        .task_id = 3,
        .run_generation = artifact.run_generation,
        .change_order = artifact.change_order,
        .digest = artifact.digest,
        .byte_size = artifact.byte_size,
    };
    store.delete(stored_identity, control.limits.max_file_change_diff_bytes);
    capture = .{};
    switch (control.beginFileChangeDiff(10, 3, 7, change.id)) {
        .queued => {},
        .immediate => return error.TestUnexpectedResult,
    }
    for (0..1_000) |_| {
        control.drainFileChangeCompletions(.{
            .context = &capture,
            .complete_fn = Capture.receive,
        });
        if (capture.calls != 0) break;
        std.testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expectEqual(FileChangeDiffReason.missing, capture.unavailable.?);

    var task_dir = try store.root.openDir(std.testing.io, "3", .{
        .follow_symlinks = false,
    });
    defer task_dir.close(std.testing.io);
    var blob_name_storage: [160]u8 = undefined;
    const digest_hex = std.fmt.bytesToHex(stored_identity.digest, .lower);
    const blob_name = try std.fmt.bufPrint(&blob_name_storage, "{d}-{d}-{s}.diff", .{
        stored_identity.run_generation,
        stored_identity.change_order,
        digest_hex,
    });
    var corrupt = try task_dir.createFile(std.testing.io, blob_name, .{
        .exclusive = true,
        .resolve_beneath = true,
    });
    var corrupt_storage = [_]u8{'x'} ** 1024;
    try corrupt.writeStreamingAll(
        std.testing.io,
        corrupt_storage[0..@intCast(stored_identity.byte_size)],
    );
    try corrupt.sync(std.testing.io);
    corrupt.close(std.testing.io);
    capture = .{};
    switch (control.beginFileChangeDiff(11, 3, 7, change.id)) {
        .queued => {},
        .immediate => return error.TestUnexpectedResult,
    }
    for (0..1_000) |_| {
        control.drainFileChangeCompletions(.{
            .context = &capture,
            .complete_fn = Capture.receive,
        });
        if (capture.calls != 0) break;
        std.testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expectEqual(FileChangeDiffReason.corrupt, capture.unavailable.?);

    capture = .{};
    switch (control.beginFileChangeDiff(12, 3, 7, change.id)) {
        .queued => {},
        .immediate => return error.TestUnexpectedResult,
    }
    change.artifact = null;
    for (0..1_000) |_| {
        control.drainFileChangeCompletions(.{
            .context = &capture,
            .complete_fn = Capture.receive,
        });
        if (capture.calls != 0) break;
        std.testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqual(FileChangeDiffReason.not_recorded, capture.unavailable.?);
}

test "Runtime re-scrubs file change diffs with credentials learned after write" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_storage);
    var store = try file_change_store.FileStore.init(
        std.testing.io,
        root_storage[0..root_len],
    );
    defer store.deinit();
    var control = try testRuntimeWith(.{
        .file_change_store = .{ .file_store = &store },
    });
    defer control.deinit();

    const late_credential = "LATE-CREDENTIAL";
    const encoded =
        "{\"file_changes\":{\"id\":\"tool-late-diff\",\"name\":\"Edit\",\"changes\":[{\"locator\":{\"workspace_path\":\"src/main.zig\"},\"kind\":\"modified\",\"status\":\"applied\",\"tool\":\"Edit\",\"tool_use_id\":\"tool-late-diff\",\"agent_depth\":0,\"before_bytes\":3,\"after_bytes\":4,\"unified_diff\":\"@@ -1 +1 @@\\n-old\\n+前缀LATE-CREDENTIAL后缀\\n\",\"diff_complete\":true}],\"overflow\":false,\"lost\":false}}";
    var envelope = try testEnvelope(3, 7, encoded);
    defer envelope.deinit();
    try control.applyEvent(&envelope);

    const run = &control.task_runtime.tasks[0].?.durable.runs[0].?;
    for (0..1_000) |_| {
        control.drainFileChangeCompletions(.{
            .context = &control,
            .complete_fn = discardFileChangeDiffCompletion,
        });
        if (run.pending_file_change_artifacts == 0) break;
        std.testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expectEqual(@as(u32, 0), run.pending_file_change_artifacts);
    const change = &run.file_changes[0].?;
    try std.testing.expect(!change.redacted);
    const artifact = change.artifact orelse return error.TestUnexpectedResult;
    const identity: file_change_store.Identity = .{
        .task_id = 3,
        .run_generation = artifact.run_generation,
        .change_order = artifact.change_order,
        .digest = artifact.digest,
        .byte_size = artifact.byte_size,
    };
    const stored = try store.readAlloc(
        std.testing.allocator,
        identity,
        control.limits.max_file_change_diff_bytes,
    );
    defer std.testing.allocator.free(stored);
    try std.testing.expect(std.mem.indexOf(u8, stored, late_credential) != null);

    // This mirrors a later credential installation. The immutable artifact is
    // intentionally left untouched; the read boundary must protect it using
    // the complete set of credentials that is live at read time.
    execution_state.testing.setCredentialBytes(
        &control.execution_state,
        late_credential,
    );
    control.redactAllProductProjectionsNoFail(late_credential);

    const Capture = struct {
        calls: usize = 0,
        content: [1024]u8 = undefined,
        content_len: usize = 0,
        redacted: bool = false,

        fn receive(context: *anyopaque, result: FileChangeDiffResult) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            switch (result) {
                .ready => |ready| {
                    std.debug.assert(ready.content.len <= self.content.len);
                    @memcpy(self.content[0..ready.content.len], ready.content);
                    self.content_len = ready.content.len;
                    self.redacted = ready.redacted;
                },
                .unavailable => unreachable,
            }
        }
    };
    var capture = Capture{};
    switch (control.beginFileChangeDiff(21, 3, 7, change.id)) {
        .queued => {},
        .immediate => return error.TestUnexpectedResult,
    }
    for (0..1_000) |_| {
        control.drainFileChangeCompletions(.{
            .context = &capture,
            .complete_fn = Capture.receive,
        });
        if (capture.calls != 0) break;
        std.testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    const safe = capture.content[0..capture.content_len];
    try std.testing.expect(capture.redacted);
    try std.testing.expect(std.unicode.utf8ValidateSlice(safe));
    try std.testing.expect(std.mem.indexOf(u8, safe, late_credential) == null);
    try std.testing.expect(std.mem.indexOf(u8, safe, "前缀") != null);
    try std.testing.expect(std.mem.indexOf(u8, safe, "后缀") != null);

    var snapshot_storage: [96 * 1024]u8 = undefined;
    const snapshot = try control.writeAggregateFixture(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, late_credential) == null);
}

test "Runtime cleans file change orphans only from healthy task history" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_storage);
    var store = try file_change_store.FileStore.init(
        std.testing.io,
        root_storage[0..root_len],
    );
    defer store.deinit();

    const orphan = try store.put(44, 1, 1, "orphan", 1024);
    var history_storage: [256 * 1024]u8 = undefined;
    var history = TestTaskPersistence{ .storage = &history_storage };
    var healthy = try testRuntimeWith(.{
        .task_persistence = history.capability(null),
        .file_change_store = .{ .file_store = &store },
    });
    healthy.deinit();
    try std.testing.expectError(
        error.BlobMissing,
        store.readAlloc(std.testing.allocator, orphan, 1024),
    );

    const preserved = try store.put(45, 1, 1, "preserved", 1024);
    var unavailable = try testRuntimeWith(.{
        .file_change_store = .{ .file_store = &store },
    });
    unavailable.deinit();
    const restored = try store.readAlloc(std.testing.allocator, preserved, 1024);
    defer std.testing.allocator.free(restored);
    try std.testing.expectEqualStrings("preserved", restored);
}

test "Task deletion waits for FileChange workers before removing retained artifacts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_storage);
    var store = try file_change_store.FileStore.init(
        std.testing.io,
        root_storage[0..root_len],
    );
    defer store.deinit();
    var control = try testRuntimeWith(.{
        .file_change_store = .{ .file_store = &store },
    });
    defer control.deinit();

    const diff = "@@ -1 +1 @@\n-old\n+new\n";
    const encoded =
        "{\"file_changes\":{\"id\":\"tool-delete\",\"name\":\"Edit\",\"changes\":[{\"locator\":{\"workspace_path\":\"src/main.zig\"},\"kind\":\"modified\",\"status\":\"applied\",\"tool\":\"Edit\",\"tool_use_id\":\"tool-delete\",\"agent_depth\":0,\"before_bytes\":3,\"after_bytes\":4,\"unified_diff\":\"@@ -1 +1 @@\\n-old\\n+new\\n\",\"diff_complete\":true}],\"overflow\":false,\"lost\":false}}";
    var envelope = try testEnvelope(3, 7, encoded);
    defer envelope.deinit();
    try control.applyEvent(&envelope);

    const task = &control.task_runtime.tasks[0].?;
    const run = &task.durable.runs[0].?;
    const change_order = run.file_changes[0].?.order;
    var digest: [file_change_store.digest_bytes]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(diff, &digest, .{});
    const expected: file_change_store.Identity = .{
        .task_id = 3,
        .run_generation = run.generation,
        .change_order = change_order,
        .digest = digest,
        .byte_size = diff.len,
    };

    task.runtime.active_run_id = 0;
    _ = commitTerminal(
        run,
        .completed,
        .completed,
        null,
        .reusable,
        "",
        false,
    );
    finalizeTestTerminalEvents(&control);
    try control.setTaskArchived(3, true);
    control.releaseTaskAttachmentNoFail(task, .cold_start);
    try control.deleteTask(3);
    try std.testing.expect(control.task_runtime.tasks[0] != null);
    try std.testing.expectEqual(@as(@TypeOf(control.task_runtime.tasks[0].?.deletion), .deleting), control.task_runtime.tasks[0].?.deletion);

    control.shutdownFileChangeExecutor();
    control.drainFileChangeCompletions(.{
        .context = &control,
        .complete_fn = discardFileChangeDiffCompletion,
    });
    control.syncLifecycle();
    try std.testing.expect(control.task_runtime.tasks[0] == null);
    try std.testing.expectError(
        error.BlobMissing,
        store.readAlloc(
            std.testing.allocator,
            expected,
            control.limits.max_file_change_diff_bytes,
        ),
    );
}

test "completed terminal drain closes collecting file change observation" {
    var control = try testRuntime();
    defer control.deinit();
    const Clock = struct {
        monotonic_ms: u64,
        unix_ms: u64,

        fn now(context: ?*anyopaque) ?u64 {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            return self.monotonic_ms;
        }

        fn nowUnix(context: ?*anyopaque) ?u64 {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            return self.unix_ms;
        }
    };
    var clock = Clock{
        .monotonic_ms = 13_000,
        .unix_ms = 1_789_436_313_000,
    };
    control.run_clock = .{
        .context = &clock,
        .now_ms_fn = Clock.now,
        .now_unix_ms_fn = Clock.nowUnix,
    };
    const run = &control.task_runtime.tasks[0].?.durable.runs[0].?;
    run.admitted_at_ms = 1_000;
    try std.testing.expectEqual(task_test_state.FileChangeObservation.collecting, run.file_change_observation.?);
    try std.testing.expect(commitTerminal(
        run,
        .completed,
        .completed,
        null,
        .reusable,
        "",
        false,
    ));
    control.markTerminalRunsBeforeEventDrain();
    control.finalizeMarkedTerminalRunsAfterEventDrain();
    try std.testing.expectEqual(task_test_state.FileChangeObservation.complete, run.file_change_observation.?);
    try std.testing.expectEqual(@as(?u64, 12_000), run.elapsed_ms);
    try std.testing.expectEqual(@as(?u64, clock.unix_ms), run.finished_at_unix_ms);
    var storage: [96 * 1024]u8 = undefined;
    const snapshot = try control.writeAggregateFixture(&storage);
    try std.testing.expect(std.mem.indexOf(
        u8,
        snapshot,
        "\"elapsedMs\":\"12000\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        snapshot,
        "\"finishedAtUnixMs\":\"1789436313000\"",
    ) != null);
}

test "terminal persistence degrades pending file change observation without mutating the live Run" {
    var control = try testRuntime();
    defer control.deinit();
    const run = &control.task_runtime.tasks[0].?.durable.runs[0].?;
    run.pending_file_change_artifacts = 1;
    try std.testing.expect(commitTerminal(
        run,
        .completed,
        .completed,
        null,
        .reusable,
        "",
        false,
    ));
    control.markTerminalRunsBeforeEventDrain();
    control.finalizeMarkedTerminalRunsAfterEventDrain();
    control.task_runtime.tasks[0].?.runtime.active_operation = .none;
    try std.testing.expectEqual(
        task_test_state.FileChangeObservation.collecting,
        run.file_change_observation.?,
    );

    var scratch = try control.buildTaskStateWire();
    defer scratch.deinit();
    try std.testing.expectEqualStrings(
        "incomplete",
        scratch.state.tasks[0].runs[0].file_change_observation.?,
    );

    const storage = try std.testing.allocator.alloc(u8, task_persistence.max_store_bytes);
    defer std.testing.allocator.free(storage);
    const encoded = try task_persistence.encode(
        storage,
        scratch.state,
        testTaskPersistenceLimits(),
    );
    var decoded = try task_persistence.decode(
        std.testing.allocator,
        encoded,
        testTaskPersistenceLimits(),
    );
    defer decoded.deinit();
    try std.testing.expectEqual(@as(usize, 1), decoded.value.tasks.len);
    try std.testing.expectEqualStrings(
        "incomplete",
        decoded.value.tasks[0].runs[0].file_change_observation.?,
    );
    try std.testing.expectEqual(
        task_test_state.FileChangeObservation.collecting,
        run.file_change_observation.?,
    );
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

test "file preview redaction protects credentials that cross a truncation boundary" {
    var control = try testRuntime();
    defer control.deinit();
    const boundary_value = "visible SECRET-";
    const cutoff = control.filePreviewCredentialSafeCutoff(
        boundary_value,
        true,
    );
    try std.testing.expectEqualStrings("visible ", boundary_value[0..cutoff]);

    var output: [64]u8 = undefined;
    const projected = control.sanitizeFilePreviewInto(
        &output,
        "visible SECRET-KEY suffix",
    );
    try std.testing.expect(projected.redacted);
    try std.testing.expectEqualStrings(
        "visible *** suffix",
        output[0..projected.len],
    );
}

test "known Host credentials are removed from assistant, tool, and UI projections" {
    var control = try testRuntime();
    defer control.deinit();
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
        try control.applyEvent(&envelope);
    }
    const tool = &control.task_runtime.tasks[0].?.durable.runs[0].?.tools[0].?;
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
    try task_test_view.writePendingUi(
        &pending_writer,
        control.taskTextProjection(),
        9,
        7,
        1,
        request,
    );

    var snapshot_storage: [96 * 1024]u8 = undefined;
    const snapshot = try control.writeAggregateFixture(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "SECRET-KEY") == null);
    try std.testing.expect(std.mem.indexOf(u8, pending_writer.buffered(), "SECRET-KEY") == null);
    try std.testing.expect(std.mem.indexOf(u8, pending_writer.buffered(), "\"redacted\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "prefix *** suffix") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"id\":\"tool-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"name\":\"Bash ***\"") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        snapshot,
        "\"redacted\":true,\"provisionalRedacted\":false",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"redacted\":true") != null);
}

test "Runtime product tool identities remain unique after raw ID redaction" {
    var control = try testRuntime();
    defer control.deinit();
    const events = [_][]const u8{
        "{\"tool_start\":{\"id\":\"SECRET-KEY\",\"name\":\"Read\",\"input\":\"first\"}}",
        "{\"tool_start\":{\"id\":\"***\",\"name\":\"Bash\",\"input\":\"second\"}}",
        "{\"tool_progress\":{\"id\":\"SECRET-KEY\",\"text\":\"first progress\"}}",
        "{\"tool_progress\":{\"id\":\"***\",\"text\":\"second progress\"}}",
    };
    for (events) |encoded| {
        var envelope = try testEnvelope(3, 7, encoded);
        defer envelope.deinit();
        try control.applyEvent(&envelope);
    }

    const first = &control.task_runtime.tasks[0].?.durable.runs[0].?.tools[0].?;
    const second = &control.task_runtime.tasks[0].?.durable.runs[0].?.tools[1].?;
    try std.testing.expectEqualStrings("tool-1", first.id);
    try std.testing.expectEqualStrings("tool-2", second.id);
    try std.testing.expectEqualStrings("first progress", first.progress);
    try std.testing.expectEqualStrings("second progress", second.progress);
    try std.testing.expect(!std.mem.eql(u8, &first.route_digest, &second.route_digest));
}

test "assistant credential redaction finalizes ordinary chunks without rescanning history" {
    var control = try testRuntime();
    defer control.deinit();
    const assistant = &control.task_runtime.tasks[0].?.durable.runs[0].?.assistant;

    for (0..4096) |_| {
        try control.appendTrackedText(assistant, "x", control.limits.max_assistant_message_bytes);
        try std.testing.expect(!control.redactTrackedText(assistant, control.execution_state.credential()));
        try std.testing.expectEqual(assistant.list.items.len, assistant.committed_len);
    }
    try std.testing.expectEqual(@as(usize, 4096), assistant.list.items.len);

    try control.appendTrackedText(assistant, "SECRET-", control.limits.max_assistant_message_bytes);
    try std.testing.expect(!control.redactTrackedText(assistant, control.execution_state.credential()));
    try std.testing.expectEqual(assistant.list.items.len - "SECRET-".len, assistant.committed_len);
    const run = &control.task_runtime.tasks[0].?.durable.runs[0].?;
    run.commentary_count = 1;
    run.commentary_ends[0] = @intCast(assistant.committed_len);

    var pending_snapshot_storage: [96 * 1024]u8 = undefined;
    const pending_snapshot = try control.writeAggregateFixture(&pending_snapshot_storage);
    try std.testing.expect(std.mem.indexOf(u8, pending_snapshot, "SECRET-") == null);

    try control.appendTrackedText(assistant, "KEY", control.limits.max_assistant_message_bytes);
    try std.testing.expect(control.redactTrackedText(assistant, control.execution_state.credential()));
    try std.testing.expectEqual(assistant.list.items.len, assistant.committed_len);
    try std.testing.expect(std.mem.endsWith(u8, assistant.list.items, "***"));
    run.commentary_ends[0] = @intCast(assistant.committed_len);

    try control.appendTrackedText(assistant, " tail SECRET-", control.limits.max_assistant_message_bytes);
    try std.testing.expect(!control.redactTrackedText(assistant, control.execution_state.credential()));
    run.commentary_ends[0] = @intCast(assistant.committed_len);
    try std.testing.expect(commitTerminal(
        run,
        .completed,
        .completed,
        null,
        .reusable,
        "",
        false,
    ));
    control.markTerminalRunsBeforeEventDrain();
    var terminal_pending_storage: [96 * 1024]u8 = undefined;
    const terminal_pending = try control.writeAggregateFixture(&terminal_pending_storage);
    try std.testing.expect(std.mem.indexOf(u8, terminal_pending, "tail SECRET-") == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        terminal_pending,
        "\"currentRunPhase\":\"running\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        terminal_pending,
        "\"activity\":{\"kind\":\"finalizing\"}",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        terminal_pending,
        "\"pendingUi\":null",
    ) != null);
    const revision_before_finalization = control.revision;
    control.finalizeMarkedTerminalRunsAfterEventDrain();
    try std.testing.expectEqual(assistant.list.items.len, assistant.committed_len);
    try std.testing.expectEqual(
        @as(u64, @intCast(assistant.committed_len)),
        run.commentary_ends[0],
    );
    try std.testing.expectEqual(
        @as(@TypeOf(control.task_runtime.tasks[0].?.runtime.active_operation), .none),
        control.task_runtime.tasks[0].?.runtime.active_operation,
    );
    try std.testing.expectEqual(revision_before_finalization + 1, control.revision);

    var terminal_snapshot_storage: [96 * 1024]u8 = undefined;
    const terminal_snapshot = try control.writeAggregateFixture(&terminal_snapshot_storage);
    try std.testing.expect(std.mem.indexOf(u8, terminal_snapshot, "tail SECRET-") != null);

    var late_event = try testEnvelope(3, 7, "{\"text_chunk\":\"late\"}");
    defer late_event.deinit();
    const revision_before_late_event = control.revision;
    const late_count_before = control.task_runtime.late_terminal_event_count;
    try control.applyEvent(&late_event);
    try std.testing.expectEqual(late_count_before + 1, control.task_runtime.late_terminal_event_count);
    try std.testing.expectEqual(revision_before_late_event, control.revision);
    try std.testing.expect(
        std.mem.indexOf(u8, control.task_runtime.tasks[0].?.durable.runs[0].?.assistant.list.items, "late") == null,
    );
}

test "projection failure after Agent terminal becomes a product failure" {
    var control = try testRuntime();
    defer control.deinit();
    const events = [_][]const u8{
        "{\"tool_start\":{\"id\":\"first\",\"name\":\"Read\",\"input\":\"one\"}}",
        "{\"tool_start\":{\"id\":\"second\",\"name\":\"Bash\",\"input\":\"two\"}}",
    };
    for (events) |encoded| {
        var envelope = try testEnvelope(3, 7, encoded);
        defer envelope.deinit();
        try control.applyEvent(&envelope);
    }

    const run = &control.task_runtime.tasks[0].?.durable.runs[0].?;
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
    try std.testing.expectError(error.ToolCapacity, control.applyEvent(&overflow));
    control.recordEventProjectionFailure(3, 7);
    finalizeTestTerminalEvents(&control);

    // Agent completion remains immutable; only Runtime product facts report
    // that the canonical event stream could not be represented completely.
    try std.testing.expectEqual(RunOutcome.completed, terminalPayload(run).?.outcome);
    const product = productTerminalFacts(run).?;
    try std.testing.expectEqual(RunOutcome.failed, product.outcome);
    try std.testing.expectEqual(RunCause.event_pipeline_failure, product.cause.?);
    // Continuation stays with the Session disposition; the projection loss is
    // a Run-level product fact only.
    try std.testing.expect(control.task_runtime.continuationAvailable(
        control.task_runtime.tasks[0].?.durable.id,
        control.taskRuntimeProjectionEffects(),
    ));

    var snapshot_storage: [96 * 1024]u8 = undefined;
    const snapshot = try control.writeAggregateFixture(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"phase\":\"failed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"terminal\":{\"outcome\":\"failed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"cause\":\"event_pipeline_failure\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"continuationAvailable\":true") != null);
}

test "event capacity causes serialize to the shared Renderer fixture" {
    const cases = try std.json.parseFromSlice([]const struct { outcome: []const u8, cause: []const u8, diagnosticDisposition: []const u8 }, std.testing.allocator, @embedFile("event_failure.fixture"), .{});
    defer cases.deinit();
    for (cases.value) |expected| {
        var control = try testRuntime();
        defer control.deinit();
        const run = &control.task_runtime.tasks[0].?.durable.runs[0].?;
        try std.testing.expect(commitTerminal(run, .failed, .failed, std.meta.stringToEnum(RunCause, expected.cause).?, .reusable, "", false));
        control.markTerminalRunsBeforeEventDrain();
        control.finalizeMarkedTerminalRunsAfterEventDrain();
        detachTaskForTest(&control, &control.task_runtime.tasks[0].?);
        var storage: [96 * 1024]u8 = undefined;
        const snapshot = try control.writeAggregateFixture(&storage);
        const decoded = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, snapshot, .{});
        defer decoded.deinit();
        const terminal = decoded.value.object.get("tasks").?.array.items[0].object.get("runs").?.array.items[0].object.get("terminal").?.object;
        try std.testing.expectEqualStrings(expected.outcome, terminal.get("outcome").?.string);
        try std.testing.expectEqualStrings(expected.cause, terminal.get("cause").?.string);
        try std.testing.expectEqualStrings(expected.diagnosticDisposition, terminal.get("diagnosticDisposition").?.string);
    }
}

test "event drain barrier atomically publishes terminal product state" {
    var control = try testRuntime();
    defer control.deinit();
    const run = &control.task_runtime.tasks[0].?.durable.runs[0].?;

    try control.appendTrackedText(
        &run.assistant,
        "final assistant suffix",
        control.limits.max_assistant_message_bytes,
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

    try std.testing.expectError(error.TaskBusy, control.setTaskArchived(3, true));
    var pending_storage: [96 * 1024]u8 = undefined;
    const pending = try control.writeAggregateFixture(&pending_storage);
    try std.testing.expect(std.mem.indexOf(u8, pending, "\"phase\":\"running\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, pending, "\"terminal\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, pending, "\"lastRunOutcome\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, pending, "\"continuationAvailable\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, pending, "final assistant suffix") == null);

    const revision_before_finalization = control.revision;
    control.markTerminalRunsBeforeEventDrain();
    control.finalizeMarkedTerminalRunsAfterEventDrain();
    try std.testing.expect(control.revision > revision_before_finalization);
    run.commentary_count = 1;
    run.commentary_ends[0] = @intCast(run.assistant.committed_len);

    // This test owns a fixture Binding that deliberately cannot exercise the
    // asynchronous Agent Session close path. Detach before snapshot lifecycle
    // reconciliation so the terminal-publication assertion stays scoped to
    // its event-drain barrier instead of starting a fake close worker.
    detachTaskForTest(&control, &control.task_runtime.tasks[0].?);

    var terminal_storage: [96 * 1024]u8 = undefined;
    const terminal = try control.writeAggregateFixture(&terminal_storage);
    try std.testing.expect(std.mem.indexOf(u8, terminal, "\"phase\":\"failed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, terminal, "\"terminal\":{\"outcome\":\"failed\",\"cause\":\"timeout\",\"diagnosticDisposition\":\"absent\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, terminal, "\"continuationAvailable\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, terminal, "final assistant suffix") != null);
}

test "close and delete wait for terminal event drain" {
    const Harness = struct {
        fn complete(
            binding: *task_test_agent_session.Binding,
            completion: *std.atomic.Value(CloseCompletion),
        ) void {
            binding.markReleasedForTest();
            completion.store(.closed, .release);
        }
    };

    var control = try testRuntime();
    defer control.deinit();
    const task = &control.task_runtime.tasks[0].?;
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

    control.syncLifecycle();
    try std.testing.expectEqual(TaskLifecycle.closing, taskLifecycle(task));
    try std.testing.expect(task.runtime.close_thread != null);
    try std.testing.expectEqual(route_id, task.runtime.routeId());
    try control.deleteTask(3);

    var queued_event = try testEnvelope(3, 7, "{\"text_chunk\":\"queued before terminal\"}");
    defer queued_event.deinit();
    try control.applyEvent(&queued_event);

    finalizeTestTerminalEvents(&control);
    try std.testing.expect(control.task_runtime.tasks[0] == null);

    var late_event = try testEnvelope(3, 7, "{\"text_chunk\":\"late\"}");
    defer late_event.deinit();
    try std.testing.expectError(error.UnknownTask, control.applyEvent(&late_event));
}

test "Runtime shutdown joins a flying close owner before relinquish" {
    const Harness = struct {
        fn close(
            binding: *task_test_agent_session.Binding,
            completion: *std.atomic.Value(CloseCompletion),
        ) void {
            for (0..128) |_| std.Thread.yield() catch {};
            binding.markClosedForTest();
            completion.store(.failed_closing, .release);
        }
    };

    var control = try testRuntime();
    defer control.deinit();
    const task = &control.task_runtime.tasks[0].?;
    const route_id = task.runtime.routeId();
    try std.testing.expect(task.runtime.beginClosing());
    task.runtime.close_completion.store(.running, .release);
    task.runtime.close_thread = try std.Thread.spawn(.{}, Harness.close, .{
        task.runtime.closingWorkerBinding().?,
        &task.runtime.close_completion,
    });
    control.executor_shutdown = true;

    control.relinquishAgentSessionsAfterRuntimeShutdown();

    try std.testing.expect(task.runtime.close_thread == null);
    try std.testing.expect(route_id != 0);
    try std.testing.expectEqual(@as(u64, 0), task.runtime.routeId());
    try std.testing.expectEqual(
        task_test_agent_session.BindingState.relinquished,
        task.runtime.bindingAfterCloseJoin().?.state(),
    );
    try std.testing.expectError(
        error.SessionClosing,
        task.runtime.acquireAccess(),
    );
}

test "streaming projection escaping is allocation-free JSON with redaction" {
    var control = try testRuntime();
    defer control.deinit();
    var storage: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try control.projectedJsonValue(&writer, "quote\" slash\\ control\x01 line\n 界 SECRET-KEY");
    try std.testing.expectEqualStrings(
        "\"quote\\\" slash\\\\ control\\u0001 line\\n 界 ***\"",
        writer.buffered(),
    );
}

test "tool projection truncates on UTF-8 boundaries and records bounded UI history" {
    var control = try testRuntime();
    defer control.deinit();

    const long = try std.testing.allocator.alloc(u8, control.limits.max_tool_field_bytes + 4);
    defer std.testing.allocator.free(long);
    @memset(long, 'x');
    @memcpy(long[long.len - 3 ..], "界");
    const projected = try control.copyProjected(
        long,
        control.limits.max_tool_field_bytes,
        control.execution_state.credential(),
    );
    defer control.freeTracked(projected.value);
    try std.testing.expect(projected.truncated);
    try std.testing.expect(std.unicode.utf8ValidateSlice(projected.value));

    const view = &control.task_runtime.tasks[0].?;
    for (1..11) |request_id| {
        var record = UiRecord{
            .request_id = request_id,
            .run_id = 7,
            .kind = .permission,
            .state = .allowed_once,
        };
        const detail = sanitizeInto(&record.detail, "Continue?", &.{});
        record.detail_len = detail.len;
        control.pushUiRecord(view, record);
    }
    try std.testing.expectEqual(control.limits.max_ui_history_per_task, view.durable.ui_history_count);
    var storage: [96 * 1024]u8 = undefined;
    const snapshot = try control.writeAggregateFixture(&storage);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"requestId\":\"1\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"requestId\":\"3\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"requestId\":\"10\"") != null);
}

test "Runtime rejects cross-session routes and usage overflow" {
    var control = try testRuntime();
    defer control.deinit();

    var foreign_session = try testEnvelope(4, 7, "{\"text_chunk\":\"wrong\"}");
    defer foreign_session.deinit();
    try std.testing.expectError(error.UnknownTask, control.applyEvent(&foreign_session));

    var foreign_run = try testEnvelope(3, 8, "{\"text_chunk\":\"wrong\"}");
    defer foreign_run.deinit();
    try std.testing.expectError(error.NoSuchRun, control.applyEvent(&foreign_run));

    var maximum = try testEnvelope(3, 7, "{\"usage\":{\"input_tokens\":18446744073709551615}}");
    defer maximum.deinit();
    try control.applyEvent(&maximum);
    var overflow = try testEnvelope(3, 7, "{\"usage\":{\"input_tokens\":1}}");
    defer overflow.deinit();
    try std.testing.expectError(error.ProjectionCapacity, control.applyEvent(&overflow));
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
        .max_oauth_scopes = 2,
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

    var incomplete_server = server;
    incomplete_server.id = "incomplete";
    incomplete_server.namespace = "incomplete";
    incomplete_server.display_name = "Incomplete challenge";
    incomplete_server.transport.url = "https://mcp.example.test/incomplete";
    incomplete_server.auth.oauth.?.consent.?.resource = "https://mcp.example.test/incomplete";
    incomplete_server.auth.oauth.?.grant.?.access_token_ref = "oauth/access-8";
    incomplete_server.auth.oauth.?.grant.?.refresh_token_ref = "oauth/refresh-8";
    const incomplete_approval = mcp_configuration.connectionFingerprint(incomplete_server);
    incomplete_server.connection_approval = .{ .fingerprint = &incomplete_approval };
    const incomplete_consent_fingerprint = mcp_configuration.oauthConsentFingerprint(
        incomplete_server,
        incomplete_server.auth.oauth.?.consent.?,
    ).?;
    incomplete_server.auth.oauth.?.consent.?.fingerprint = &incomplete_consent_fingerprint;

    var oversized_server = server;
    oversized_server.id = "oversized";
    oversized_server.namespace = "oversized";
    oversized_server.display_name = "Oversized challenge";
    oversized_server.transport.url = "https://mcp.example.test/oversized";
    oversized_server.auth.oauth.?.consent.?.resource = "https://mcp.example.test/oversized";
    oversized_server.auth.oauth.?.grant.?.access_token_ref = "oauth/access-8";
    oversized_server.auth.oauth.?.grant.?.refresh_token_ref = "oauth/refresh-8";
    const oversized_approval = mcp_configuration.connectionFingerprint(oversized_server);
    oversized_server.connection_approval = .{ .fingerprint = &oversized_approval };
    const oversized_consent_fingerprint = mcp_configuration.oauthConsentFingerprint(
        oversized_server,
        oversized_server.auth.oauth.?.consent.?,
    ).?;
    oversized_server.auth.oauth.?.consent.?.fingerprint = &oversized_consent_fingerprint;

    var servers = [_]mcp_configuration.ServerWire{
        server,
        incomplete_server,
        oversized_server,
    };
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
    var control = try testRuntime();
    defer control.deinit();
    std.debug.assert(control.mcp == null);
    control.mcp = mcp_testing.init(
        control.allocator,
        productMcpPorts(
            control.executor,
            control.agent_runtime,
            .{},
            .{},
        ),
        .{
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
        },
    );
    management_owned = false;
    preparation_owned = false;

    try std.testing.expectEqual(
        McpRuntimeAuthorizationFailureOutcome.stale,
        try control.requireMcpOauthReauthorization(.{
            .server_id = "oauth",
            .consent_epoch = 3,
            .token_revision = 7,
            .challenge_scopes = &.{},
            .challenge_scopes_complete = true,
        }),
    );
    try std.testing.expectEqualStrings(
        "ready",
        mcp_testing.state(&control.mcp.?).management.?.desiredRegistry().?.servers[0].auth.oauth.?.status,
    );
    try std.testing.expectEqual(
        McpRuntimeAuthorizationFailureOutcome.applied,
        try control.requireMcpOauthReauthorization(.{
            .server_id = "oauth",
            .consent_epoch = 3,
            .token_revision = 7,
            .challenge_scopes = &.{"files.write"},
            .challenge_scopes_complete = true,
        }),
    );
    const desired = mcp_testing.state(&control.mcp.?).management.?.desiredRegistry().?;
    try std.testing.expectEqualStrings(
        "reauth_required",
        desired.servers[0].auth.oauth.?.status,
    );
    try std.testing.expect(desired.servers[0].auth.oauth.?.grant == null);
    try std.testing.expectEqual(
        mcp_configuration.RuntimeAlignment.current,
        control.inspectMcpDesiredConfiguration().?.runtime_alignment,
    );
    try std.testing.expect(mcp_testing.state(&control.mcp.?).admission == .ready);
    try std.testing.expectEqual(
        @as(usize, 1),
        mcp_testing.state(&control.mcp.?).pending_reauthorizations.items.len,
    );
    try std.testing.expectEqualStrings(
        "oauth",
        mcp_testing.state(&control.mcp.?).pending_reauthorizations.items[0].server_id,
    );
    var start = (try control.beginMcpAuthorization(5, "oauth")).?;
    defer start.deinit();
    try std.testing.expectEqual(@as(usize, 2), start.additional_scopes.len);
    try std.testing.expectEqualStrings("files.read", start.additional_scopes[0]);
    try std.testing.expectEqualStrings("files.write", start.additional_scopes[1]);
    try std.testing.expect(control.finishMcpAuthorization(start.operation_id));

    try std.testing.expectEqual(
        mcp_configuration.ManagementOutcome.saved,
        try control.renameMcpServer(5, .{
            .server_id = "oauth",
            .display_name = "Renamed OAuth",
        }),
    );
    try std.testing.expect(mcp_testing.state(&control.mcp.?).admission == .ready);
    try std.testing.expectEqual(
        @as(usize, 1),
        mcp_testing.state(&control.mcp.?).pending_reauthorizations.items.len,
    );
    try std.testing.expectEqual(
        mcp_configuration.ManagementOutcome.saved,
        try control.removeMcpServer(6, "oauth"),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        mcp_testing.state(&control.mcp.?).pending_reauthorizations.items.len,
    );

    try std.testing.expectEqual(
        McpRuntimeAuthorizationFailureOutcome.applied,
        try control.requireMcpOauthReauthorization(.{
            .server_id = "incomplete",
            .consent_epoch = 3,
            .token_revision = 8,
            .challenge_scopes = &.{"files.write"},
            .challenge_scopes_complete = false,
        }),
    );
    const oversized_scopes = [_][]const u8{
        "files.admin",
        "files.read",
        "files.write",
    };
    try std.testing.expectEqual(
        McpRuntimeAuthorizationFailureOutcome.applied,
        try control.requireMcpOauthReauthorization(.{
            .server_id = "oversized",
            .consent_epoch = 3,
            .token_revision = 8,
            .challenge_scopes = &oversized_scopes,
            .challenge_scopes_complete = true,
        }),
    );
    const sanitized_desired = mcp_testing.state(&control.mcp.?).management.?.desiredRegistry().?;
    for (sanitized_desired.servers) |sanitized_server| {
        try std.testing.expectEqualStrings(
            "reauth_required",
            sanitized_server.auth.oauth.?.status,
        );
        try std.testing.expect(sanitized_server.auth.oauth.?.grant == null);
    }
    try std.testing.expectEqual(
        @as(usize, 0),
        mcp_testing.state(&control.mcp.?).pending_reauthorizations.items.len,
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
    var control = try Runtime.init(
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
    defer control.deinit();

    var output: [128 * 1024]u8 = undefined;
    const empty_snapshot = try control.writeAggregateFixture(&output);
    try std.testing.expect(std.mem.indexOf(
        u8,
        empty_snapshot,
        "\"availability\":\"ready\",\"managementHealth\":\"ready\",\"operation\":\"idle\",\"configurationApply\":\"idle\",\"authorizationOperation\":{\"kind\":\"idle\"},\"desiredGeneration\":\"0\",\"runtimeAlignment\":\"current\",\"redacted\":false,\"servers\":[]",
    ) != null);
    try std.testing.expectEqual(
        mcp_configuration.ManagementOutcome.saved,
        try control.createMcpHttpServer(0, .{
            .display_name = "Remote",
            .url = "https://mcp.example.test/rpc",
        }),
    );
    const inspection = control.inspectMcpDesiredConfiguration().?;
    try std.testing.expectEqual(@as(?u64, 1), inspection.desired_generation);
    try std.testing.expectEqual(
        mcp_configuration.RuntimeAlignment.restart_required,
        inspection.runtime_alignment,
    );
    try std.testing.expectEqual(
        McpAdmissionBlockReason.pending_restart,
        mcp_testing.state(&control.mcp.?).admission.blocked,
    );
    const created_snapshot = try control.writeAggregateFixture(&output);
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
    const server_id = mcp_testing.state(&control.mcp.?).management.?.desiredRegistry().?.servers[0].id;
    try control.beginMcpConnectionTest(server_id);
    const testing_snapshot = try control.writeAggregateFixture(&output);
    try std.testing.expect(std.mem.indexOf(
        u8,
        testing_snapshot,
        "\"connectionTest\":{\"status\":\"testing\",\"toolCount\":0,\"issueCount\":0}",
    ) != null);
    control.completeMcpConnectionTest(server_id, .connected, 3, 1);
    const connected_snapshot = try control.writeAggregateFixture(&output);
    try std.testing.expect(std.mem.indexOf(
        u8,
        connected_snapshot,
        "\"connectionTest\":{\"status\":\"connected\",\"toolCount\":3,\"issueCount\":1}",
    ) != null);
    try control.beginMcpConfigurationApply(1);
    try std.testing.expectError(error.CatalogLoading, control.refreshMcpCatalog());
    try std.testing.expect(mcp_testing.state(&control.mcp.?).refresh_pending);
    try std.testing.expect(!control.mcp.?.hasRefreshJob());
    const applying_snapshot = try control.writeAggregateFixture(&output);
    try std.testing.expect(std.mem.indexOf(
        u8,
        applying_snapshot,
        "\"configurationApply\":\"applying\"",
    ) != null);
    try std.testing.expectEqual(
        McpAdmissionBlockReason.refreshing,
        mcp_testing.state(&control.mcp.?).admission.blocked,
    );
    control.failMcpConfigurationApply(1);
    const failed_apply_snapshot = try control.writeAggregateFixture(&output);
    try std.testing.expect(std.mem.indexOf(
        u8,
        failed_apply_snapshot,
        "\"configurationApply\":\"failed\"",
    ) != null);
    try std.testing.expectEqual(
        McpAdmissionBlockReason.refreshing,
        mcp_testing.state(&control.mcp.?).admission.blocked,
    );
    try std.testing.expect(!mcp_testing.state(&control.mcp.?).refresh_pending);
    try std.testing.expect(control.mcp.?.hasRefreshJob());
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
    var control = try Runtime.init(
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
    defer control.deinit();

    try std.testing.expectEqual(
        mcp_configuration.ManagementOutcome.saved,
        try control.createMcpOauthHttpServer(0, .{
            .display_name = "Remote OAuth",
            .url = "https://mcp.example.test/mcp",
            .client = .{ .pre_registered = .{ .client_id = "client-1" } },
        }),
    );
    const server_id = mcp_testing.state(&control.mcp.?).management.?.desiredRegistry().?.servers[0].id;
    var start = (try control.beginMcpAuthorization(1, server_id)).?;
    defer start.deinit();
    try std.testing.expect(mcp_testing.state(&control.mcp.?).admission == .ready);
    try std.testing.expect(!control.mcp.?.hasRefreshJob());
    try std.testing.expectEqual(
        McpAuthorizationPhase.discovering,
        control.mcpAuthorizationOperation().?.phase,
    );
    try std.testing.expectEqualStrings(
        "https://mcp.example.test/mcp",
        start.endpoint,
    );
    try std.testing.expectEqual(
        mcp_configuration.ManagementOutcome.rejected,
        try control.renameMcpServer(1, .{
            .server_id = server_id,
            .display_name = "Blocked while authorizing",
        }),
    );
    try std.testing.expect(!control.advanceMcpAuthorization(
        start.operation_id,
        .exchanging,
    ));
    try std.testing.expect(control.advanceMcpAuthorization(
        start.operation_id,
        .awaiting_consent,
    ));

    const authorization = try control.authorizeMcpOauth(.{
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
    try std.testing.expect(control.advanceMcpAuthorization(
        start.operation_id,
        .awaiting_browser,
    ));
    const exchange = try control.beginMcpOauthCodeExchange(server_id);
    try std.testing.expect(exchange == .started);
    const durable_id = exchange.started.operation.id;
    try std.testing.expect(control.finishMcpAuthorization(start.operation_id));
    try std.testing.expect(control.mcpAuthorizationOperation() == null);
    try std.testing.expect(!control.mcp.?.hasRefreshJob());
    try std.testing.expectEqual(
        mcp_configuration.ManagementOutcome.saved,
        try control.recoverMcpOauthOperation(durable_id),
    );
    try std.testing.expect(!mcp_testing.state(&control.mcp.?).refresh_pending);
    try std.testing.expect(!control.mcp.?.hasRefreshJob());
    const oauth = mcp_testing.state(&control.mcp.?).management.?.desiredRegistry().?.servers[0].auth.oauth.?;
    try std.testing.expectEqualStrings("reauth_required", oauth.status);
}

test "MCP startup health commits a safe degraded Runtime projection" {
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
    var control = try Runtime.init(
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
    defer control.deinit();

    var output: [128 * 1024]u8 = undefined;
    const snapshot = try control.writeAggregateFixture(&output);
    try std.testing.expect(std.mem.indexOf(
        u8,
        snapshot,
        "\"mcpManagement\":true",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        snapshot,
        "\"mcpSecretMaxBytes\":16384",
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

    const before = control.inspectMcpDesiredConfiguration().?;
    try std.testing.expectEqual(@as(?u64, 9), before.desired_generation);
    try std.testing.expectEqual(
        mcp_configuration.RuntimeAlignment.current,
        before.runtime_alignment,
    );
    try std.testing.expectEqual(
        McpAdmissionBlockReason.activation_unavailable,
        mcp_testing.state(&control.mcp.?).admission.blocked,
    );
    const revision_before_mutation = control.revision;
    try std.testing.expectEqual(
        mcp_configuration.ManagementOutcome.saved,
        try control.renameMcpServer(9, .{
            .server_id = "local-files",
            .display_name = "Updated local files",
        }),
    );
    try std.testing.expectEqual(revision_before_mutation + 1, control.revision);
    const after = control.inspectMcpDesiredConfiguration().?;
    try std.testing.expectEqual(@as(?u64, 10), after.desired_generation);
    try std.testing.expectEqual(
        mcp_configuration.RuntimeAlignment.current,
        after.runtime_alignment,
    );
    try std.testing.expectEqual(
        McpAdmissionBlockReason.activation_unavailable,
        mcp_testing.state(&control.mcp.?).admission.blocked,
    );

    try std.testing.expectEqual(
        mcp_configuration.ManagementOutcome.saved,
        try control.approveMcpConnection(10, .{ .server_id = "disabled" }),
    );
    try std.testing.expectEqual(
        mcp_configuration.ManagementOutcome.saved,
        try control.setMcpServerEnabled(11, .{
            .server_id = "disabled",
            .enabled = true,
        }),
    );
    try std.testing.expectEqual(
        mcp_configuration.RuntimeAlignment.restart_required,
        control.inspectMcpDesiredConfiguration().?.runtime_alignment,
    );
    try std.testing.expectEqual(
        McpAdmissionBlockReason.pending_restart,
        mcp_testing.state(&control.mcp.?).admission.blocked,
    );
    try std.testing.expectEqual(
        mcp_configuration.ManagementOutcome.saved,
        try control.setMcpServerEnabled(12, .{
            .server_id = "disabled",
            .enabled = false,
        }),
    );
    try std.testing.expectEqual(
        mcp_configuration.RuntimeAlignment.current,
        control.inspectMcpDesiredConfiguration().?.runtime_alignment,
    );
    try std.testing.expectEqual(
        McpAdmissionBlockReason.activation_unavailable,
        mcp_testing.state(&control.mcp.?).admission.blocked,
    );
    mcp_testing.state(&control.mcp.?).management.?.persistence.commit_registry_fn =
        ManagementEffects.failRegistry;
    try std.testing.expectEqual(
        mcp_configuration.ManagementOutcome.rejected,
        try control.setMcpServerEnabled(13, .{
            .server_id = "disabled",
            .enabled = true,
        }),
    );
    try std.testing.expectEqual(
        @as(?u64, 13),
        control.inspectMcpDesiredConfiguration().?.desired_generation,
    );
    try std.testing.expectEqual(
        McpAdmissionBlockReason.activation_unavailable,
        mcp_testing.state(&control.mcp.?).admission.blocked,
    );
    mcp_testing.state(&control.mcp.?).management.?.persistence.commit_registry_fn =
        ManagementEffects.registry;
    mcp_testing.state(&control.mcp.?).management.?.persistence.clear_journal_fn =
        ManagementEffects.unknownClear;
    try std.testing.expectEqual(
        mcp_configuration.ManagementOutcome.indeterminate,
        try control.setMcpServerEnabled(13, .{
            .server_id = "disabled",
            .enabled = true,
        }),
    );
    try std.testing.expectEqual(
        @as(?u64, 14),
        control.inspectMcpDesiredConfiguration().?.desired_generation,
    );
    try std.testing.expectEqual(
        McpAdmissionBlockReason.persistence_outcome_unknown,
        mcp_testing.state(&control.mcp.?).admission.blocked,
    );

    const effective_snapshot = try control.writeAggregateFixture(&output);
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

    const blocked_job = try control.allocator.create(McpRefreshTestJob);
    blocked_job.* = .{
        .allocator = control.allocator,
        .catalog = mcpCatalogPort(control.agent_runtime),
        .notifier = mcpNotifierPort(.{}),
        .request_generation = 1,
        .requested_at_ms = null,
        .arena = std.heap.ArenaAllocator.init(control.allocator),
        .allowlists = &.{},
        .build_admission = false,
    };
    mcp_testing.state(&control.mcp.?).refresh_request_generation = 1;
    mcp_testing.installRefreshJob(&control.mcp.?, blocked_job);
    try std.testing.expectError(
        error.ExecutionUnavailable,
        control.createTaskInWorkspace(
            1,
            1,
            1,
            control.newTaskAdmissionView().active_selection_revision,
            null,
            null,
            null,
            .{ .interactive = null },
        ),
    );
    mcp_testing.state(&control.mcp.?).activation_failed = false;
    blocked_job.outcome = .unavailable;
    blocked_job.state.store(.completed, .release);
    control.syncLifecycle();
    try std.testing.expect(!control.mcp.?.hasRefreshJob());
    try std.testing.expect(mcp_testing.state(&control.mcp.?).activation_failed);
    try std.testing.expectEqual(
        @as(?u64, 14),
        control.inspectMcpDesiredConfiguration().?.desired_generation,
    );

    const stale_job = try control.allocator.create(McpRefreshTestJob);
    stale_job.* = .{
        .allocator = control.allocator,
        .catalog = mcpCatalogPort(control.agent_runtime),
        .notifier = mcpNotifierPort(.{}),
        .request_generation = 2,
        .requested_at_ms = null,
        .arena = std.heap.ArenaAllocator.init(control.allocator),
        .allowlists = &.{},
        .build_admission = false,
        .state = .init(.completed),
        .outcome = .unavailable,
    };
    mcp_testing.state(&control.mcp.?).activation_failed = false;
    mcp_testing.state(&control.mcp.?).refresh_request_generation = 3;
    mcp_testing.installRefreshJob(&control.mcp.?, stale_job);
    control.syncLifecycle();
    try std.testing.expect(!mcp_testing.state(&control.mcp.?).activation_failed);

    const cancelled_job = try control.allocator.create(McpRefreshTestJob);
    cancelled_job.* = .{
        .allocator = control.allocator,
        .catalog = mcpCatalogPort(control.agent_runtime),
        .notifier = mcpNotifierPort(.{}),
        .request_generation = 4,
        .requested_at_ms = null,
        .arena = std.heap.ArenaAllocator.init(control.allocator),
        .allowlists = &.{},
        .build_admission = false,
    };
    mcp_testing.state(&control.mcp.?).refresh_request_generation = 4;
    mcp_testing.installRefreshJob(&control.mcp.?, cancelled_job);
    McpRefreshTestJob.cancel(cancelled_job);
    control.shutting_down = true;
    control.syncLifecycle();
    try std.testing.expect(!control.mcp.?.hasRefreshJob());
}

test "approval shutdown settles joined history outcomes before releasing Task resources" {
    const Catalog = struct {
        fn query(_: *anyopaque, _: lifecycle.CatalogQuery) anyerror!lifecycle.CatalogAcquisition {
            return error.CatalogUnavailable;
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);
    const storage = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(storage);
    for ([_]TaskPersistenceCommit{ .committed, .failed, .outcome_unknown }) |result| {
        var history = TestTaskPersistence{ .storage = storage };
        var control = try testRuntimeWith(.{
            .task_persistence = history.capability(null),
        });
        defer control.deinit();
        control.canonical_user_home = try control.allocator.dupe(u8, home);
        control.skill.ports.catalog.query_fn = Catalog.query;
        const task = control.task_runtime.find(3).?;
        const run_id = task.runtime.active_run_id;
        // This fixture Run has no live Agent RunControl. Settle it before
        // admission, so lifecycle reconciliation cannot accept the history
        // result that this test deliberately leaves for shutdown to reap.
        _ = commitTerminal(&task.durable.runs[0].?, .completed, .completed, null, .reusable, "", false);
        finalizeTestTerminalEvents(&control);
        // Configure the outcome before enqueue; do not race the worker's
        // read of its capability by changing this field after admission.
        history.result = result;
        const revision = try control.setApprovalMode(3, .auto_review, task.durable.binding_epoch, 1);
        try std.testing.expectEqual(@as(u64, 2), revision);
        try std.testing.expectEqual(run_id, task.runtime.active_run_id);
        // Observed admission stops at mode_commit with no queued job. Assert
        // that exact precondition before advancing the single enqueue step;
        // this synchronization cannot reap an existing completion.
        try std.testing.expectEqual(.mode_commit, task.approval_change.?.phase);
        for (control.task_runtime.approval_jobs) |entry| try std.testing.expect(entry == null);
        _ = control.syncApprovalChanges();
        const pending = pending: {
            for (control.task_runtime.approval_jobs) |entry| if (entry) |slot| {
                if (slot.task_id == 3) break :pending slot.job;
            };
            return error.TestUnexpectedResult;
        };
        for (0..2000) |_| {
            if (pending.completionReady()) break;
            std.testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
        }
        try std.testing.expect(pending.completionReady());
        try std.testing.expectEqual(result, pending.outcome.history);
        try std.testing.expectEqual(.mode_commit, task.approval_change.?.phase);
        try std.testing.expect(!task.durable.permission_review_delegated);
        try std.testing.expectEqual(@as(u64, 1), task.durable.approval_revision);
        // Deliberately skip UI-loop publication and let shutdown reap it.
        control.shutdownExecutor();
        for (control.task_runtime.approval_jobs) |entry| try std.testing.expect(entry == null);
        try std.testing.expect(!task.runtime.worker_leases.hasLive());
        switch (result) {
            .committed => {
                try std.testing.expect(task.durable.permission_review_delegated);
                try std.testing.expectEqual(@as(u64, 2), task.durable.approval_revision);
                try std.testing.expect(task.approval_change == null);
                try std.testing.expectEqual(.completed, task.approval_result.?.outcome);
            },
            .failed => {
                try std.testing.expect(!task.durable.permission_review_delegated);
                try std.testing.expectEqual(@as(u64, 1), task.durable.approval_revision);
                try std.testing.expectEqual(.failed, task.approval_result.?.outcome);
            },
            .outcome_unknown => {
                try std.testing.expect(!task.durable.permission_review_delegated);
                try std.testing.expectEqual(.outcome_unknown, task.approval_change.?.phase);
                try std.testing.expect(control.task_runtime.approvalHistoryBlocked());
                try std.testing.expectEqual(.outcome_unknown, control.task_persistence_health);
            },
        }
    }
}

test "approval projection writes deferred facts off-thread and unknown readback retains its candidate" {
    const Harness = struct {
        storage: []u8,
        main_thread: std.Thread.Id,
        len: usize = 0,
        main_commits: usize = 0,
        worker_commits: usize = 0,
        resolutions: usize = 0,
        recoveries: usize = 0,
        resolution_result: TaskPersistenceCommit = .outcome_unknown,
        projection_result: TaskPersistenceCommit = .outcome_unknown,
        entered: std.atomic.Value(bool) = .init(false),
        released: std.atomic.Value(bool) = .init(false),
        fn save(context: ?*anyopaque, bytes: []const u8) TaskPersistenceCommit {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (std.Thread.getCurrentId() == self.main_thread) {
                self.main_commits += 1;
            } else {
                self.worker_commits += 1;
                if (self.worker_commits == 1) {
                    self.entered.store(true, .release);
                    while (!self.released.load(.acquire)) std.Thread.yield() catch {};
                }
                // The mode commit succeeds; its deferred projection is unknown.
                if (self.worker_commits == 2) return self.projection_result;
            }
            if (bytes.len > self.storage.len) return .failed;
            @memcpy(self.storage[0..bytes.len], bytes);
            self.len = bytes.len;
            return .committed;
        }
        fn resolve(context: ?*anyopaque, bytes: []const u8) TaskPersistenceCommit {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            std.debug.assert(std.Thread.getCurrentId() != self.main_thread);
            self.resolutions += 1;
            if (self.resolution_result == .committed) {
                @memcpy(self.storage[0..bytes.len], bytes);
                self.len = bytes.len;
            }
            return self.resolution_result;
        }
        fn recover(context: ?*anyopaque, _: []const u8) TaskPersistenceCommit {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.recoveries += 1;
            return .failed;
        }
        fn capability(self: *@This()) TaskPersistence {
            return .{ .context = self, .enabled = true, .commit_fn = save, .confirmed_commit_fn = save, .resolve_commit_fn = resolve, .recover_fn = recover };
        }
        fn query(_: *anyopaque, _: lifecycle.CatalogQuery) anyerror!lifecycle.CatalogAcquisition {
            return error.CatalogUnavailable;
        }
    };
    const HeldExecutor = struct {
        job: ?*anyopaque = null,
        cancel_callback: ?*const fn (*anyopaque) void = null,
        fn enqueue(context: *anyopaque, _: *anyopaque, job: *anyopaque, _: *const fn (*anyopaque) void, cancel_fn: *const fn (*anyopaque) void) error{ ExecutorShuttingDown, QueueFull }!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.job = job;
            self.cancel_callback = cancel_fn;
        }
        fn cancel(context: *anyopaque, _: *anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.cancel_callback.?(self.job.?);
            self.job = null;
            return true;
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);
    const storage = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(storage);
    const cases = [_]struct { projection: TaskPersistenceCommit, resolved: TaskPersistenceCommit }{
        .{ .projection = .outcome_unknown, .resolved = .committed },
        .{ .projection = .outcome_unknown, .resolved = .failed },
        .{ .projection = .failed, .resolved = .failed },
    };
    for (cases) |case| {
        var history = Harness{ .storage = storage, .main_thread = std.Thread.getCurrentId(), .projection_result = case.projection };
        var control = try testRuntimeWith(.{ .task_persistence = history.capability() });
        defer control.deinit();
        defer history.released.store(true, .release);
        control.canonical_user_home = try control.allocator.dupe(u8, home);
        control.skill.ports.catalog.query_fn = Harness.query;
        const task = control.task_runtime.find(3).?;
        _ = commitTerminal(&task.durable.runs[0].?, .completed, .completed, null, .reusable, "", false);
        finalizeTestTerminalEvents(&control);
        control.commitTaskStateNoFail();
        const main_commits = history.main_commits;
        _ = try control.setApprovalMode(3, .auto_review, task.durable.binding_epoch, 1);
        control.syncLifecycle();
        for (0..2000) |_| {
            if (history.entered.load(.acquire)) break;
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        }
        try std.testing.expect(history.entered.load(.acquire));
        try control.renameTask(3, "renamed while mode writer is held");
        try std.testing.expect(control.approval_history_dirty);
        try std.testing.expectEqual(main_commits, history.main_commits);
        history.released.store(true, .release);
        for (0..2000) |_| {
            control.syncLifecycle();
            if (control.approval_history_unknown != null or control.task_persistence_health == .write_failed) break;
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        }
        if (case.projection == .failed) {
            try std.testing.expect(control.approval_history_unknown == null);
            try std.testing.expect(control.approval_history_dirty);
            try std.testing.expectEqual(.write_failed, control.task_persistence_health);
            try std.testing.expectEqual(.completed, task.approval_result.?.outcome);
            try std.testing.expectEqual(@as(u64, 2), task.durable.approval_revision);
            for (0..10) |_| control.syncLifecycle();
            try std.testing.expectEqual(@as(usize, 2), history.worker_commits);
            // Only an explicit recovery may retry this definite write failure.
            try std.testing.expectEqual(.outcome_unknown, control.recoverTaskHistory(control.currentRevision()));
            try std.testing.expect(!control.taskHistoryRecoveryAvailable());
            for (0..2000) |_| {
                control.syncLifecycle();
                if (!control.approvalHistoryBlocked()) break;
                try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
            }
            try std.testing.expectEqual(.ready, control.task_persistence_health);
            try std.testing.expect(!control.approval_history_dirty);
            try std.testing.expectEqual(@as(usize, 3), history.worker_commits);
            try std.testing.expectEqual(@as(usize, 0), history.resolutions);
            try std.testing.expectEqual(@as(usize, 0), history.recoveries);
            try std.testing.expectEqual(main_commits, history.main_commits);
            var canonical = try task_persistence.decode(std.testing.allocator, history.storage[0..history.len], control.taskPersistenceLimits());
            defer canonical.deinit();
            try std.testing.expectEqualStrings("renamed while mode writer is held", canonical.value.tasks[0].title);
            try std.testing.expectEqual(@as(u64, 2), canonical.value.tasks[0].approval_revision);
            try std.testing.expect(canonical.value.tasks[0].permission_review_delegated);
            continue;
        }
        const retained = control.approval_history_unknown orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(.outcome_unknown, control.task_persistence_health);
        try std.testing.expect(task.approval_change == null);
        try std.testing.expectEqual(.completed, task.approval_result.?.outcome);
        try std.testing.expectEqual(@as(u64, 2), task.durable.approval_revision);
        try std.testing.expect(task.durable.permission_review_delegated);
        var candidate = try task_persistence.decode(std.testing.allocator, retained, control.taskPersistenceLimits());
        defer candidate.deinit();
        try std.testing.expectEqualStrings("renamed while mode writer is held", candidate.value.tasks[0].title);
        try control.renameTask(3, "latest title while projection is unknown");
        for (0..10) |_| control.syncLifecycle();
        try std.testing.expectEqual(@as(usize, 2), history.worker_commits);
        try std.testing.expectEqual(main_commits, history.main_commits);
        try std.testing.expectEqual(@as(usize, 0), history.resolutions);
        try std.testing.expectEqual(@as(usize, 0), history.recoveries);

        // Queued cancellation releases only the read job's duplicate packet.
        var held = HeldExecutor{};
        const copy = try control.allocator.dupe(u8, retained);
        try control.task_runtime.queueApprovalProjection(copy, history.capability(), true, .{ .context = &held, .enqueue_fn = HeldExecutor.enqueue, .cancel_fn = HeldExecutor.cancel }, control.approvalNotifier());
        try std.testing.expect(HeldExecutor.cancel(&held, &held));
        control.syncLifecycle();
        try std.testing.expectEqual(retained.ptr, control.approval_history_unknown.?.ptr);
        try std.testing.expectEqual(.outcome_unknown, control.task_persistence_health);
        try std.testing.expect(!control.task_runtime.approval_cleanup_leases.hasLive());
        try std.testing.expectEqual(@as(usize, 0), history.resolutions);
        try std.testing.expectEqual(.outcome_unknown, control.recoverTaskHistory(control.currentRevision()));
        for (0..2000) |_| {
            control.syncLifecycle();
            if (!control.task_runtime.approvalHistoryWorkerActive()) break;
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        }
        try std.testing.expectEqual(@as(usize, 1), history.resolutions);
        try std.testing.expectEqual(retained.ptr, control.approval_history_unknown.?.ptr);
        try std.testing.expectEqual(@as(usize, 2), history.worker_commits);
        history.resolution_result = case.resolved;
        try std.testing.expectEqual(.outcome_unknown, control.recoverTaskHistory(control.currentRevision()));
        for (0..2000) |_| {
            control.syncLifecycle();
            if (!control.approvalHistoryBlocked() and !control.approval_history_dirty) break;
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        }
        try std.testing.expect(control.approval_history_unknown == null);
        try std.testing.expect(!control.approvalHistoryBlocked());
        try std.testing.expect(!control.approval_history_dirty);
        try std.testing.expectEqual(.ready, control.task_persistence_health);
        try std.testing.expectEqual(@as(usize, 2), history.resolutions);
        try std.testing.expectEqual(@as(usize, 3), history.worker_commits);
        try std.testing.expectEqual(main_commits, history.main_commits);
        try std.testing.expectEqual(@as(usize, 0), history.recoveries);
        var canonical = try task_persistence.decode(std.testing.allocator, history.storage[0..history.len], control.taskPersistenceLimits());
        defer canonical.deinit();
        try std.testing.expectEqualStrings("latest title while projection is unknown", canonical.value.tasks[0].title);
        try std.testing.expectEqual(@as(u64, 2), canonical.value.tasks[0].approval_revision);
        try std.testing.expect(canonical.value.tasks[0].permission_review_delegated);
        try std.testing.expect(!control.task_runtime.approval_cleanup_leases.hasLive());
    }
}

test "authoritative empty catalog closes new default admission and preserves Task execution" {
    var control = try testRuntime();
    defer control.deinit();
    const task_id = control.task_runtime.tasks[0].?.durable.id;
    const old_admission = control.newTaskAdmissionView();
    try std.testing.expect(old_admission.available);
    try std.testing.expectEqual(models_contract.ModelsError.none, try models_aggregate.TestSupport.refreshMetaskCatalog(&control.custom_providers, "account-1", &.{}));
    control.reconcileModelsDefaultNoFail(true, false);
    control.finishExecutionCommitNoFail();
    try std.testing.expect(!control.newTaskAdmissionView().available);
    try std.testing.expect(!control.validNewTaskAdmission(old_admission.active_generation, old_admission.active_selection_revision));
    try std.testing.expect(!control.scheduleExecutionBinding().available);
    try std.testing.expectError(error.ExecutionUnavailable, control.createTask(.{
        .workspace_root = "/must-not-be-opened",
        .trust = .explicitly_trusted,
    }));
    const pinned = try control.task_runtime.testExecutionInput(task_id);
    try std.testing.expectEqualStrings("fixture-model", pinned.target.model);
    try std.testing.expectEqualStrings("SECRET-KEY", pinned.api_key);
    try std.testing.expectEqual(old_admission.active_generation, pinned.execution_generation);
    try std.testing.expectEqual(@as(@TypeOf(control.accountView().state), .authenticated), control.accountView().state);
}

test "complete model metadata Host projection matches the Renderer fixture" {
    const metadata: models_contract.ModelMetadata = .{
        .max_input_tokens = 1000000,
        .max_output_tokens = 131072,
        .capabilities = .{
            .text_input = true,
            .image_input = true,
            .pdf_input = true,
            .audio_input = true,
            .video_input = true,
            .output = .{ .text = true, .image = true, .audio = true, .video = true, .embedding = true },
            .batch = false,
            .citations = false,
            .code_execution = false,
            .structured_outputs = true,
            .thinking = .{ .supported = true, .adaptive = false, .enabled = true },
            .effort = .{ .supported = false, .low = false, .medium = false, .high = false, .max = false },
            .context_management = .{ .supported = false, .clear_thinking_20251015 = false, .clear_tool_uses_20250919 = false, .compact_20260112 = false },
        },
    };
    var storage: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try Runtime.writeModelMetadata(&writer, metadata);
    try std.testing.expectEqualStrings(std.mem.trimEnd(u8, contract_fixture.model_metadata, "\r\n"), writer.buffered());
}

test "Product Control snapshot serializer omits image formats when attachments are unavailable" {
    var limits = testLimits();
    limits.max_attachments_per_draft = 2;
    limits.max_attachment_file_bytes = 1024;
    limits.max_staged_attachment_bytes = 2048;
    var control = try testRuntimeWithLimits(limits, .{});
    defer control.deinit();
    var storage: [8192]u8 = undefined;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, try control.writeAggregateFixture(&storage), .{});
    defer parsed.deinit();
    const capability = parsed.value.object.get("capabilities").?.object.get("attachments").?;
    const encoded = try std.json.Stringify.valueAlloc(std.testing.allocator, capability, .{});
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings(std.mem.trim(u8, contract_fixture.attachments_unavailable, "\r\n"), encoded);
}

test "active input wire identity borrows stable Run memory until history encoding completes" {
    var control = try testRuntime();
    defer control.deinit();
    const run = &control.task_runtime.tasks[0].?.durable.runs[0].?;
    const operation_id = "stable-operation";
    run.additional_inputs[0] = .{ .id = 1, .after_output_count = 0, .operation_id_len = operation_id.len, .text = try control.copyBounded("constraint", control.limits.max_user_message_bytes), .sequence = 1, .redacted = false };
    @memcpy(run.additional_inputs[0].?.operation_id[0..operation_id.len], operation_id);
    try Runtime.reserveTaskRuntimeBytes(&control, task_test_state.additional_input_projection_bytes);
    var scratch = try control.buildTaskStateWireWithCheckpoint(null);
    defer scratch.deinit();
    const projected = scratch.state.tasks[0].runs[0].additional_inputs[0];
    try std.testing.expectEqual(run.additional_inputs[0].?.operationId().ptr, projected.operation_id.ptr);
    try std.testing.expectEqualStrings(operation_id, projected.operation_id);
}

test "complete model metadata image refresh changes default generation while existing Task stays frozen" {
    var control = try testRuntime();
    defer control.deinit();
    const task_id = control.task_runtime.tasks[0].?.durable.id;
    const old_execution = control.execution_state.executionInput().?;
    const generation = old_execution.execution_generation;
    const old_capabilities = (try control.task_runtime.testExecutionInput(task_id)).target.image_capabilities;
    try std.testing.expectEqual(@as(usize, 1), old_capabilities.len);
    try std.testing.expect(!old_capabilities[0].supported);
    const current = control.modelsView();
    const models = [_]models_contract.ModelView{.{ .id = "fixture-model", .display_name = "Fixture model", .metadata = .{ .capabilities = .{ .image_input = true } } }};
    try models_aggregate.TestSupport.installMetaskDefault(
        &control.custom_providers,
        "account-1",
        "SECRET-KEY",
        &models,
        "fixture-model",
        control.execution_state.activeSourceGeneration(),
        current.metask_selection_revision + 1,
        current.selection_revision + 1,
        current.providers[0].catalog_generation + 1,
    );
    control.reconcileModelsDefaultNoFail(true, false);
    const refreshed = control.execution_state.executionInput().?;
    try std.testing.expect(refreshed.execution_generation > generation);
    try std.testing.expect(refreshed.target.image_capabilities[0].supported);
    const pinned = try control.task_runtime.testExecutionInput(task_id);
    try std.testing.expectEqual(generation, pinned.execution_generation);
    try std.testing.expect(!pinned.target.image_capabilities[0].supported);
}

test "Product view cached delivery confirms versions without rebuilding stable blocks" {
    var control = try testRuntime();
    defer control.deinit();
    var storage: [96 * 1024]u8 = undefined;
    const first = try control.writeViewFixture(&storage, .{ .task_id = 3 });
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, first, .{});
    defer parsed.deinit();
    var versions: view_cache.Versions = .{};
    inline for (std.meta.fields(view_cache.Versions)) |field| {
        @field(versions, field.name) = try std.fmt.parseInt(u64, parsed.value.object.get("blockVersions").?.object.get(field.name).?.string, 10);
    }
    const request: ViewRequest = .{ .task_id = 3, .known_epoch = control.projectionSecurityEpoch(), .known_versions = versions };
    const second = try control.writeViewFixture(&storage, request);
    var confirmed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, second, .{});
    defer confirmed.deinit();
    try std.testing.expectEqual(@as(usize, 7), confirmed.value.object.get("reusedBlocks").?.array.items.len);
    inline for (std.meta.fields(view_cache.Versions)) |field| try std.testing.expect(confirmed.value.object.get(field.name).? == .null);
    const sequence = control.encoded_views.sequence;
    control.encoded_views.invalidateEvent(999, 999);
    _ = try control.writeViewFixture(&storage, request);
    try std.testing.expectEqual(sequence, control.encoded_views.sequence);
    control.learnProjectionCredential("revoked-cache-secret");
    try std.testing.expectEqual(@as(usize, 0), control.encoded_views.bytes);
    const secured = try control.writeViewFixture(&storage, request);
    var secured_view = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, secured, .{});
    defer secured_view.deinit();
    try std.testing.expectEqual(@as(usize, 0), secured_view.value.object.get("reusedBlocks").?.array.items.len);
    try std.testing.expect(secured_view.value.object.get("context").? == .object);
}

test "Product view credential matcher preserves UTF-8 and clears its owned scan set after reads" {
    var control = try testRuntime();
    defer control.deinit();
    execution_state.testing.setCredentialBytes(&control.execution_state, &.{0xa9});
    try control.replaceTracked(&control.task_runtime.tasks[0].?.durable.title, "caf\xc3\xa9 SECRET-KEY", control.limits.max_task_title_bytes);
    var storage: [96 * 1024]u8 = undefined;
    const bytes = try control.writeViewFixture(&storage, .{ .task_id = 3 });
    try std.testing.expect(std.unicode.utf8ValidateSlice(bytes));
    try std.testing.expect(std.mem.indexOf(u8, bytes, "SECRET-KEY") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "caf** ***") != null);
    try std.testing.expect(control.view_credentials == null);
    var short: [1]u8 = undefined;
    try std.testing.expectError(error.SnapshotTooLarge, control.writeViewFixture(&short, .{}));
    try std.testing.expect(control.view_credentials == null);
}

test "Product view frozen read survives business updates and rejects replaced revoked and shutdown handles" {
    var control = try testRuntime();
    defer control.deinit();
    var expected_storage: [96 * 1024]u8 = undefined;
    const expected = try control.writeViewFixture(&expected_storage, .{ .task_id = 3 });
    var output: [96 * 1024]u8 = undefined;
    var read = try control.writeSnapshot(&output, .{ .task_id = 3 });
    while (read.bytes == 0) read = try control.continueSnapshot(read.id, &output);
    try std.testing.expectEqual(@as(usize, 0), control.view_read.produced);
    try std.testing.expectError(error.InvalidOffset, control.writeSnapshotRange(read.id, &output, 1, 1));
    try control.writeSnapshotRange(read.id, &output, 0, 64);
    var unrelated_storage: [96 * 1024]u8 = undefined;
    try std.testing.expectError(error.StaleSnapshot, control.writeSnapshotRange(read.id, &unrelated_storage, 64, 64));
    var first: [64]u8 = undefined;
    @memcpy(&first, output[0..64]);
    try control.replaceTracked(&control.task_runtime.tasks[0].?.durable.title, "new committed title", control.limits.max_task_title_bytes);
    control.bumpRevision();
    try control.writeSnapshotRange(read.id, &output, 0, 64);
    try std.testing.expectEqualSlices(u8, &first, output[0..64]);
    try std.testing.expectEqual(@as(usize, 64), control.view_read.produced);
    var offset: usize = 64;
    while (offset < read.bytes) : (offset += 64) try control.writeSnapshotRange(read.id, &output, offset, @min(@as(usize, 64), read.bytes - offset));
    try std.testing.expectEqualStrings(expected, output[0..read.bytes]);
    const next = try control.writeSnapshot(&output, .{ .task_id = 3 });
    try std.testing.expect(next.id != read.id);
    try std.testing.expectError(error.StaleSnapshot, control.writeSnapshotRange(read.id, &output, 0, 1));
    control.learnProjectionCredential("newly-learned-secret");
    try std.testing.expectError(error.StaleSnapshot, control.writeSnapshotRange(next.id, &output, 0, 1));
    const last = try control.writeSnapshot(&output, .{});
    control.beginShutdown();
    try std.testing.expectError(error.StaleSnapshot, control.writeSnapshotRange(last.id, &output, 0, 1));
    try std.testing.expectEqual(@as(usize, 0), control.view_read.skeleton.len);
    try std.testing.expectEqual(@as(usize, 0), control.view_read.text.items.len);
}

test "Product view duplicate credential ownership preserves reads while exact new values revoke and wake" {
    const Host = struct {
        wakes: std.atomic.Value(usize) = .init(0),
        fn wake(context: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            _ = self.wakes.fetchAdd(1, .monotonic);
            return true;
        }
    };
    var host: Host = .{};
    var control = try testRuntimeWith(.{ .change_notifier = .{ .context = &host, .wake = Host.wake } });
    defer control.deinit();
    var output: [96 * 1024]u8 = undefined;
    _ = try control.writeViewFixture(&output, .{ .task_id = 3 });
    var read = try control.writeSnapshot(&output, .{ .task_id = 3 });
    while (read.bytes == 0) read = try control.continueSnapshot(read.id, &output);
    const epoch = control.projectionSecurityEpoch();
    const wakes = host.wakes.load(.monotonic);
    const duplicate = try control.allocator.dupe(u8, control.execution_state.credential());
    defer control.allocator.free(duplicate);
    control.learnProjectionCredential(duplicate);
    control.retireProjectionCredential(duplicate);
    control.redactAllProductProjectionsNoFail(duplicate);
    try std.testing.expectEqual(epoch, control.projectionSecurityEpoch());
    try std.testing.expectEqual(wakes, host.wakes.load(.monotonic));
    try control.writeSnapshotRange(read.id, &output, 0, 64);
    // A substring of a known credential is a different value, not a known owner.
    control.learnProjectionCredential("SECRET");
    try std.testing.expectEqual(epoch + 1, control.projectionSecurityEpoch());
    try std.testing.expectEqual(wakes + 1, host.wakes.load(.monotonic));
    try std.testing.expectError(error.StaleSnapshot, control.writeSnapshotRange(read.id, &output, 0, 64));
    const next = try control.writeSnapshot(&output, .{});
    // The Task retains a different owned copy of SECRET-KEY. Retiring the
    // installed copy preserves the set; retiring the remaining Task copy does not.
    control.retireProjectionCredential(control.execution_state.credential());
    try std.testing.expectEqual(epoch + 1, control.projectionSecurityEpoch());
    execution_state.testing.setCredentialBytes(&control.execution_state, "GLOBAL");
    const task_credential = (try control.task_runtime.testExecutionInput(3)).api_key;
    control.retireProjectionCredential(task_credential);
    try std.testing.expectEqual(epoch + 2, control.projectionSecurityEpoch());
    try std.testing.expectEqual(wakes + 2, host.wakes.load(.monotonic));
    try std.testing.expectError(error.StaleSnapshot, control.writeSnapshotRange(next.id, &output, 0, 64));
}

test "Product view history versions ignore unrelated revisions and observe terminal artifact completion" {
    var control = try maximumProjectionFixture();
    defer control.deinit();
    const epoch = control.projection_history_epoch;
    const run = &control.task_runtime.tasks[0].?.durable.runs[0].?;
    const unrelated = control.task_runtime.tasks[1].?.durable.runs[0].?.projection_content_version;
    const version = run.projection_content_version;
    control.bumpRevision(); // Account, Schedule or other Task header changes.
    try std.testing.expectEqual(epoch, control.projection_history_epoch);
    try std.testing.expectEqual(version, run.projection_content_version);
    run.pending_file_change_artifacts = 1;
    const change = run.file_changes[0].?;
    try std.testing.expect(control.task_runtime.completeFileChangeArtifact(1, run.generation, change.order, null, false));
    control.bumpRevision();
    try std.testing.expect(run.projection_content_version > version);
    try std.testing.expectEqual(unrelated, control.task_runtime.tasks[1].?.durable.runs[0].?.projection_content_version);
    try std.testing.expectEqual(epoch, control.projection_history_epoch);
    const output = try std.testing.allocator.alloc(u8, control.limits.max_snapshot_bytes);
    defer std.testing.allocator.free(output);
    const bytes = try control.writeViewFixture(output, .{ .task_id = 1, .before_run_id = 5 });
    var decoded = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
    defer decoded.deinit();
    const observed = decoded.value.object.get("taskPage").?.object.get("runManifest").?.array.items[0].object.get("contentVersion").?.string;
    try std.testing.expectEqual(run.projection_content_version, try std.fmt.parseInt(u64, observed, 10));
    try std.testing.expectEqual(task_test_state.FileChangeObservation.incomplete, run.file_change_observation.?);
}

test "Product view preparation owns frozen tools and cannot clean a changed cache" {
    var control = try testRuntime();
    defer control.deinit();
    var event = try testEnvelope(3, 7, "{\"tool_result\":{\"id\":\"prepared\",\"name\":\"Bash\",\"input\":\"{\\\"command\\\":\\\"echo original\\\"}\",\"content\":\"old result\",\"is_error\":false,\"elapsed_ms\":1}}");
    defer event.deinit();
    try control.applyEvent(&event);
    var output: [96 * 1024]u8 = undefined;
    var read = try control.writeSnapshot(&output, .{ .task_id = 3 });
    try std.testing.expectEqual(@as(usize, 0), read.bytes);
    try std.testing.expectEqual(@as(usize, 1), control.view_preparation.tools.items.len);
    try std.testing.expect(control.view_preparation.credentials != null);
    try std.testing.expectError(error.InvalidOffset, control.writeSnapshotRange(read.id, &output, 0, 1));
    const tool = &control.task_runtime.tasks[0].?.durable.runs[0].?.tools[0].?;
    try control.replaceTracked(&tool.content, "new result", control.limits.max_tool_field_bytes);
    control.bumpRevision();
    while (read.bytes == 0) read = try control.continueSnapshot(read.id, &output);
    try std.testing.expect(control.view_preparation.credentials == null);
    try std.testing.expectEqual(@as(usize, 0), control.view_preparation.tools.items.len);
    var offset: usize = 0;
    while (offset < read.bytes) : (offset += 31) try control.writeSnapshotRange(read.id, &output, offset, @min(@as(usize, 31), read.bytes - offset));
    try std.testing.expect(std.mem.indexOf(u8, output[0..read.bytes], "old result") != null);
    try std.testing.expect(std.mem.indexOf(u8, output[0..read.bytes], "new result") == null);
    try std.testing.expect(control.encoded_views.get(Runtime.viewKey(.{ .task_id = 3 }, .taskPage)) == null);
    const current = try control.writeViewFixture(&output, .{ .task_id = 3 });
    try std.testing.expect(std.mem.indexOf(u8, current, "new result") != null);
    control.encoded_views.invalidateAll();
    read = try control.writeSnapshot(&output, .{ .task_id = 3 });
    try std.testing.expectEqual(@as(usize, 0), read.bytes);
    control.learnProjectionCredential("new preparation boundary");
    try std.testing.expectError(error.StaleSnapshot, control.continueSnapshot(read.id, &output));
    try std.testing.expect(control.view_preparation.credentials == null);
    try std.testing.expectEqual(@as(usize, 0), control.view_preparation.tools.items.len);
}

test "Product view failed formatter stage releases partially prepared source and credentials" {
    var control = try testRuntimeWithLimits(.{}, .{});
    defer control.deinit();
    var event = try testEnvelope(3, 7, "{\"tool_result\":{\"id\":\"partial\",\"name\":\"Bash\",\"input\":\"{}\",\"content\":\"result\",\"is_error\":false,\"elapsed_ms\":1}}");
    defer event.deinit();
    try control.applyEvent(&event);
    const command = try std.testing.allocator.alloc(u8, 20_000);
    defer std.testing.allocator.free(command);
    @memset(command, '\n');
    const input = try std.json.Stringify.valueAlloc(std.testing.allocator, .{ .command = command }, .{});
    defer std.testing.allocator.free(input);
    try control.replaceTracked(&control.task_runtime.tasks[0].?.durable.runs[0].?.tools[0].?.input, input, control.limits.max_tool_field_bytes);
    var output: [96 * 1024]u8 = undefined;
    var read = try control.writeSnapshot(&output, .{ .task_id = 3 });
    read = try control.continueSnapshot(read.id, &output);
    try std.testing.expectEqual(@as(usize, 0), read.bytes);
    try std.testing.expect(control.view_preparation.tools.items[0].state.stage == .bash_input);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const original_allocator = control.allocator;
    control.allocator = failing.allocator();
    defer control.allocator = original_allocator;
    try std.testing.expectError(error.SnapshotTooLarge, control.continueSnapshot(read.id, &output));
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(@as(u64, 0), control.view_read.id);
    try std.testing.expect(control.view_preparation.credentials == null);
    try std.testing.expectEqual(@as(usize, 0), control.view_preparation.tools.items.len);
}
