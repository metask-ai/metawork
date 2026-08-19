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
const skill_package_impl = @import("workbench_skill_package");
const task_persistence = @import("workbench_task_persistence");
const checkpoint_store = @import("workbench_checkpoint_store");
const checkpoint_record = @import("workbench_checkpoint_record");
const catalog_snapshot = @import("workbench_catalog_snapshot");
const owned_task_execution = @import("workbench_owned_task_execution");
const task_runtime = @import("workbench_task_runtime");
const task_recovery = @import("workbench_task_recovery");
const task_recovery_job = @import("workbench_task_recovery_job");
const mcp_configuration = @import("workbench_mcp_configuration");
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
    TaskNotClosed,
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
    TaskRunning,
    TaskSessionInUse,
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
// limit. This is a local fallback only; model-generated metadata will have a
// separate contract when AgentCore exposes that capability.
const automatic_title_max_codepoints: usize = 32;

pub const Provider = enum {
    anthropic,
    openai,
    gemini,
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

const McpAvailability = enum { unavailable, ready, degraded };
const McpRuntimeStatus = enum {
    not_loaded,
    ready,
    disabled,
    needs_authentication,
    @"unreachable",
    invalid_catalog,
};

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

pub const UiResponse = union(enum) {
    answers: []const []const []const u8,
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

pub const SkillEnablementMutation = struct {
    workspace_id: u64,
    expected_workspace_epoch: u64,
    skill_id: []const u8,
    enabled: bool,
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
    builtin_tool_profile: ?lifecycle.BuiltinToolProfile = null,
    directories: AppDirectories = .{},
    schedule_timer: ScheduleTimer = .{},
    schedule_persistence: SchedulePersistence = .{},
    task_persistence: TaskPersistence = .{},
    checkpoint_store: CheckpointStoreConfiguration = .{},
    schedule_notifier: ScheduleNotifier = .{},
    skill_management: SkillManagementConfiguration = .{},
    skill_enablement: SkillEnablementConfiguration = .{},
    model_connections: ModelConnectionCapabilities = .{},
    mcp: McpStartupConfiguration = .{},
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

pub const McpHostCapabilities = struct {
    connection_approval: bool = false,
    secret_capture: bool = false,
    oauth: bool = false,
};

/// Successful Workbench initialization consumes `preparation` and
/// `activation`; failure consumes neither. App clears its optional activation
/// owner only after init returns successfully.
pub const McpStartupConfiguration = struct {
    preparation: ?*mcp_configuration.Preparation = null,
    activation: ?*lifecycle.McpActivation = null,
    activation_failed: bool = false,
    management: ?mcp_configuration.ManagementConfiguration = null,
    host_capabilities: McpHostCapabilities = .{},
};

pub const McpAdmissionBlockReason = enum {
    pending_restart,
    alignment_unknown,
    refreshing,
    activation_unavailable,
    runtime_authorization_failure,
    persistence_outcome_unknown,
    management_recovery_required,
    shutting_down,
};

const McpAdmissionReady = struct {
    selection: ?*lifecycle.McpSelection,
    catalog_generation: ?u64,
};

const McpAdmissionAuthority = union(enum) {
    ready: McpAdmissionReady,
    blocked: McpAdmissionBlockReason,

    fn deinit(self: *McpAdmissionAuthority) void {
        switch (self.*) {
            .ready => |ready| if (ready.selection) |selection| selection.deinit(),
            .blocked => {},
        }
        self.* = undefined;
    }
};

const RecoveryMcpAuthority = struct {
    selection: ?*lifecycle.McpSelection,
    catalog_generation: ?u64,

    fn deinit(self: *RecoveryMcpAuthority) void {
        if (self.selection) |selection| selection.deinit();
        self.* = undefined;
    }
};

pub const McpOauthRefreshBinding = struct {
    arena: std.heap.ArenaAllocator,
    operation_id: []const u8,
    server_id: []const u8,
    endpoint: []const u8,
    resource: []const u8,
    issuer: []const u8,
    scopes: []const []const u8,
    client_id: []const u8,
    token_endpoint_auth_method: []const u8,
    client_secret_ref: ?[]const u8,
    refresh_token_ref: []const u8,
    consent_epoch: u64,
    token_revision: u64,

    pub fn deinit(self: *McpOauthRefreshBinding) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const McpOauthRefreshBeginOutcome = union(enum) {
    started: McpOauthRefreshBinding,
    rejected,
    persistence_outcome_unknown,
};

pub const McpOauthAuthorizationPlan = struct {
    attempt_id: u64,
    server_id: []const u8,
    issuer: []const u8,
    resource: []const u8,
    scopes: []const []const u8,
    redirect_uri: []const u8,
};

pub const McpOauthAuthorizationBinding = struct {
    attempt_id: u64,
    server_id: []const u8,
    issuer: []const u8,
    resource: []const u8,
    scopes: []const []const u8,
    redirect_uri: []const u8,
    client_id: []const u8,
};

pub const McpOauthAuthorizationOutcome = union(enum) {
    ready: McpOauthAuthorizationBinding,
    rejected,
    persistence_outcome_unknown,
};

pub const McpOauthOperationHandle = struct {
    id: []const u8,
    server_id: []const u8,
};

pub const McpOauthCodeExchangeBinding = struct {
    operation: McpOauthOperationHandle,
    issuer: []const u8,
    client_id: []const u8,
    token_endpoint_auth_method: []const u8,
    client_secret_ref: ?[]const u8,
    resource: []const u8,
    redirect_uri: []const u8,
};

pub const McpOauthOperationBeginOutcome = union(enum) {
    started: McpOauthOperationHandle,
    rejected,
    persistence_outcome_unknown,
};

pub const McpOauthCodeExchangeBeginOutcome = union(enum) {
    started: McpOauthCodeExchangeBinding,
    rejected,
    persistence_outcome_unknown,
};

pub const McpOauthExpiry = struct {
    server_id: []const u8,
    expires_at_unix_ms: u64,
};

pub const McpRuntimeAuthorizationFailure = struct {
    server_id: []const u8,
    consent_epoch: u64,
    token_revision: u64,
    challenge_scopes: []const []const u8,
    challenge_scopes_complete: bool,
};

pub const McpRuntimeAuthorizationFailureOutcome = enum {
    applied,
    stale,
    rejected,
    persistence_outcome_unknown,
};

pub const McpAuthorizationPhase = enum {
    discovering,
    awaiting_consent,
    registering,
    awaiting_browser,
    exchanging,
    cancelling,
};

pub const McpConnectionTestOutcome = enum {
    connected,
    failed,
};

const McpConnectionTest = struct {
    server_id_storage: [64]u8 = undefined,
    server_id_len: usize = 0,
    state: enum { testing, connected, failed },
    tool_count: u32 = 0,
    issue_count: u32 = 0,

    fn init(server_id: []const u8) ?McpConnectionTest {
        if (server_id.len == 0 or server_id.len > 64) return null;
        var result: McpConnectionTest = .{ .state = .testing };
        @memcpy(result.server_id_storage[0..server_id.len], server_id);
        result.server_id_len = server_id.len;
        return result;
    }

    fn serverId(self: *const McpConnectionTest) []const u8 {
        return self.server_id_storage[0..self.server_id_len];
    }
};

pub const McpAuthorizationOperationView = struct {
    phase: McpAuthorizationPhase,
    server_id: []const u8,
    operation_id: []const u8,
};

pub const McpAuthorizationStart = struct {
    arena: std.heap.ArenaAllocator,
    operation_id: []const u8,
    server_id: []const u8,
    endpoint: []const u8,
    registration_kind: []const u8,
    client_id: ?[]const u8,
    token_endpoint_auth_method: ?[]const u8,
    additional_scopes: []const []const u8,

    pub fn deinit(self: *McpAuthorizationStart) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const McpSecretCaptureTarget = union(enum) {
    stdio_environment: []const u8,
    http_header: []const u8,
    oauth_client_secret,
};

const McpAuthorizationOperation = struct {
    phase: McpAuthorizationPhase,
    server_id: []u8,
    operation_id: []u8,

    fn deinit(self: *McpAuthorizationOperation, allocator: std.mem.Allocator) void {
        allocator.free(self.server_id);
        allocator.free(self.operation_id);
        self.* = undefined;
    }
};

fn ownMcpScopeUnion(
    allocator: std.mem.Allocator,
    first: []const []const u8,
    second: []const []const u8,
    max_scopes: usize,
) (std.mem.Allocator.Error || error{McpOauthScopeCapacity})![]const []const u8 {
    const scopes = try allocator.alloc([]const u8, max_scopes);
    var count: usize = 0;
    for (first) |scope| {
        if (count == max_scopes) return error.McpOauthScopeCapacity;
        scopes[count] = try allocator.dupe(u8, scope);
        count += 1;
    }
    for (second) |scope| {
        var duplicate = false;
        for (scopes[0..count]) |current| if (std.mem.eql(u8, current, scope)) {
            duplicate = true;
            break;
        };
        if (duplicate) continue;
        if (count == max_scopes) return error.McpOauthScopeCapacity;
        scopes[count] = try allocator.dupe(u8, scope);
        count += 1;
    }
    std.mem.sort([]const u8, scopes[0..count], {}, struct {
        fn lessThan(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.order(u8, left, right) == .lt;
        }
    }.lessThan);
    return scopes[0..count];
}

const McpPendingReauthorization = struct {
    arena: std.heap.ArenaAllocator,
    server_id: []const u8,
    consent_epoch: u64,
    scopes: []const []const u8,

    fn init(
        allocator: std.mem.Allocator,
        server_id: []const u8,
        consent_epoch: u64,
        existing: []const []const u8,
        incoming: []const []const u8,
        max_scopes: usize,
    ) (std.mem.Allocator.Error || error{McpOauthScopeCapacity})!McpPendingReauthorization {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const owned = arena.allocator();
        const scopes = try ownMcpScopeUnion(
            owned,
            existing,
            incoming,
            max_scopes,
        );
        return .{
            .arena = arena,
            .server_id = try owned.dupe(u8, server_id),
            .consent_epoch = consent_epoch,
            .scopes = scopes,
        };
    }

    fn deinit(self: *McpPendingReauthorization) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// A prebuilt Application-owned HTTP snapshot replacement. `commit_fn` must
/// be allocation-free and is invoked exactly after the registry result is
/// known durable but before restored Admission is installed.
pub const McpOauthRuntimeCommit = struct {
    context: *anyopaque,
    commit_fn: *const fn (*anyopaque) void,

    fn commit(self: McpOauthRuntimeCommit) void {
        self.commit_fn(self.context);
    }
};

const McpProductState = struct {
    preparation: mcp_configuration.Preparation,
    activation: ?*lifecycle.McpActivation,
    activation_failed: bool,
    management: ?mcp_configuration.ManagementPort,
    admission: McpAdmissionAuthority,
    refresh_request_generation: u64 = 0,
    refresh_job: ?*McpRefreshJob = null,
    connection_test: ?McpConnectionTest = null,
    authorization_operation: ?McpAuthorizationOperation = null,
    pending_reauthorizations: std.ArrayList(McpPendingReauthorization) = .empty,
    runtime_auth_failure_blocked: bool = false,
    host_capabilities: McpHostCapabilities,
    committed: bool = false,

    fn deinit(self: *McpProductState) void {
        std.debug.assert(self.refresh_job == null);
        if (self.authorization_operation) |*operation|
            operation.deinit(self.preparation.allocator);
        for (self.pending_reauthorizations.items) |*pending| pending.deinit();
        self.pending_reauthorizations.deinit(self.preparation.allocator);
        self.admission.deinit();
        if (self.activation) |activation| activation.deinit();
        if (self.management) |*management| management.deinit();
        self.preparation.deinit();
        self.* = undefined;
    }
};

fn initialMcpAdmission(
    activation: ?*lifecycle.McpActivation,
    activation_failed: bool,
    management: ?*const mcp_configuration.ManagementPort,
) McpAdmissionAuthority {
    if (management) |port| {
        const inspection = port.inspect();
        if (inspection.health == .outcome_unknown) {
            discardActivationSelection(activation);
            return .{ .blocked = .persistence_outcome_unknown };
        }
        if (inspection.health != .ready) {
            discardActivationSelection(activation);
            return .{ .blocked = .management_recovery_required };
        }
        switch (inspection.runtime_alignment) {
            .restart_required => {
                discardActivationSelection(activation);
                return .{ .blocked = .pending_restart };
            },
            .unknown => {
                discardActivationSelection(activation);
                return .{ .blocked = .alignment_unknown };
            },
            .current => {},
        }
    }
    if (activation_failed) {
        discardActivationSelection(activation);
        return .{ .blocked = .activation_unavailable };
    }
    if (activation) |value| return .{ .ready = .{
        .selection = value.takeSelection(),
        .catalog_generation = value.catalogGeneration(),
    } };
    return .{ .ready = .{
        .selection = null,
        .catalog_generation = null,
    } };
}

fn discardActivationSelection(activation: ?*lifecycle.McpActivation) void {
    if (activation) |value|
        if (value.takeSelection()) |selection| selection.deinit();
}

fn findMcpServer(
    servers: []const mcp_configuration.ServerWire,
    id: []const u8,
) ?mcp_configuration.ServerWire {
    for (servers) |server|
        if (std.mem.eql(u8, server.id, id)) return server;
    return null;
}

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

fn validMcpAuthorizationTransition(
    from: McpAuthorizationPhase,
    to: McpAuthorizationPhase,
) bool {
    if (to == .cancelling) return from != .cancelling;
    return switch (from) {
        .discovering => to == .awaiting_consent,
        .awaiting_consent => to == .registering or to == .awaiting_browser,
        .registering => to == .awaiting_browser,
        .awaiting_browser => to == .exchanging,
        .exchanging, .cancelling => false,
    };
}

fn mcpServerMutationBusy(mcp: *const McpProductState, server_id: []const u8) bool {
    if (mcp.connection_test) |test_state|
        if (test_state.state == .testing and
            std.mem.eql(u8, test_state.serverId(), server_id)) return true;
    const operation = mcp.authorization_operation orelse return false;
    return std.mem.eql(u8, operation.server_id, server_id);
}

fn mcpAuthorizationAt(
    mcp: *const McpProductState,
    server_id: []const u8,
    phases: []const McpAuthorizationPhase,
) bool {
    const operation = mcp.authorization_operation orelse return false;
    if (!std.mem.eql(u8, operation.server_id, server_id)) return false;
    for (phases) |phase| if (operation.phase == phase) return true;
    return false;
}

fn mcpPendingReauthorizationIndex(
    mcp: *const McpProductState,
    server_id: []const u8,
) ?usize {
    for (mcp.pending_reauthorizations.items, 0..) |pending, index|
        if (std.mem.eql(u8, pending.server_id, server_id)) return index;
    return null;
}

fn mcpPendingReauthorizationScopes(
    mcp: *const McpProductState,
    server_id: []const u8,
    consent_epoch: u64,
) []const []const u8 {
    const index = mcpPendingReauthorizationIndex(mcp, server_id) orelse
        return &.{};
    const pending = mcp.pending_reauthorizations.items[index];
    return if (pending.consent_epoch == consent_epoch) pending.scopes else &.{};
}

fn mcpScopeSetAddsRequirement(
    approved: []const []const u8,
    challenge: []const []const u8,
) bool {
    for (challenge) |required| {
        var found = false;
        for (approved) |scope| if (std.mem.eql(u8, required, scope)) {
            found = true;
            break;
        };
        if (!found) return true;
    }
    return false;
}

fn prepareMcpPendingReauthorization(
    allocator: std.mem.Allocator,
    mcp: *McpProductState,
    server_id: []const u8,
    consent_epoch: u64,
    scopes: []const []const u8,
    max_scopes: usize,
) (std.mem.Allocator.Error || error{McpOauthScopeCapacity})!?McpPendingReauthorization {
    const existing_index = mcpPendingReauthorizationIndex(mcp, server_id);
    const existing_scopes = if (existing_index) |index|
        if (mcp.pending_reauthorizations.items[index].consent_epoch == consent_epoch)
            mcp.pending_reauthorizations.items[index].scopes
        else
            &.{}
    else
        &.{};
    if (existing_index != null and
        mcp.pending_reauthorizations.items[existing_index.?].consent_epoch == consent_epoch and
        !mcpScopeSetAddsRequirement(existing_scopes, scopes))
        return null;
    if (existing_index == null)
        try mcp.pending_reauthorizations.ensureUnusedCapacity(allocator, 1);
    return try McpPendingReauthorization.init(
        allocator,
        server_id,
        consent_epoch,
        existing_scopes,
        scopes,
        max_scopes,
    );
}

fn installMcpPendingReauthorization(
    mcp: *McpProductState,
    replacement: *McpPendingReauthorization,
) void {
    if (mcpPendingReauthorizationIndex(mcp, replacement.server_id)) |index| {
        mcp.pending_reauthorizations.items[index].deinit();
        mcp.pending_reauthorizations.items[index] = replacement.*;
    } else {
        mcp.pending_reauthorizations.appendAssumeCapacity(replacement.*);
    }
    replacement.* = undefined;
}

fn reconcileMcpPendingReauthorizations(
    mcp: *McpProductState,
    target: mcp_configuration.RegistryWire,
) void {
    var index: usize = 0;
    while (index < mcp.pending_reauthorizations.items.len) {
        const pending = mcp.pending_reauthorizations.items[index];
        const keep = if (findMcpServer(target.servers, pending.server_id)) |server|
            if (server.auth.oauth) |oauth|
                std.mem.eql(u8, oauth.status, "reauth_required") and
                    if (oauth.consent) |consent|
                        consent.epoch == pending.consent_epoch
                    else
                        false
            else
                false
        else
            false;
        if (keep) {
            index += 1;
            continue;
        }
        var removed = mcp.pending_reauthorizations.swapRemove(index);
        removed.deinit();
    }
}

fn mcpServerAdmittedByDesiredState(
    server: mcp_configuration.ServerWire,
) bool {
    if (!server.enabled or server.connection_approval == null) return false;
    if (std.mem.eql(u8, server.auth.kind, "oauth")) {
        const oauth = server.auth.oauth orelse return false;
        return std.mem.eql(u8, oauth.status, "ready") and oauth.grant != null;
    }
    return true;
}

fn mcpServerToolsForAdmission(
    registry: mcp_configuration.RegistryWire,
    server: mcp_configuration.ServerWire,
) []const []const u8 {
    if (registry.oauth_operation) |operation|
        if (std.mem.eql(u8, operation.server_id, server.id)) return &.{};
    if (!mcpServerAdmittedByDesiredState(server)) return &.{};
    return server.tools;
}

fn buildMcpOauthRefreshBinding(
    allocator: std.mem.Allocator,
    registry: mcp_configuration.RegistryWire,
) std.mem.Allocator.Error!McpOauthRefreshBinding {
    const operation = registry.oauth_operation.?;
    const server = findMcpServer(registry.servers, operation.server_id).?;
    const oauth = server.auth.oauth.?;
    const consent = oauth.consent.?;
    const grant = oauth.grant.?;
    const registration = oauth.registration;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const owned = arena.allocator();
    const scopes = try owned.alloc([]const u8, consent.scopes.len);
    for (consent.scopes, scopes) |scope, *owned_scope|
        owned_scope.* = try owned.dupe(u8, scope);
    return .{
        .arena = arena,
        .operation_id = try owned.dupe(u8, operation.id),
        .server_id = try owned.dupe(u8, operation.server_id),
        .endpoint = try owned.dupe(u8, server.transport.url.?),
        .resource = try owned.dupe(u8, consent.resource),
        .issuer = try owned.dupe(u8, consent.issuer),
        .scopes = scopes,
        .client_id = try owned.dupe(u8, registration.client_id.?),
        .token_endpoint_auth_method = try owned.dupe(
            u8,
            registration.token_endpoint_auth_method.?,
        ),
        .client_secret_ref = if (registration.client_secret_ref) |locator|
            try owned.dupe(u8, locator)
        else
            null,
        .refresh_token_ref = try owned.dupe(u8, grant.refresh_token_ref.?),
        .consent_epoch = operation.consent_epoch,
        .token_revision = operation.token_revision.?,
    };
}

fn buildMcpRefreshAllowlists(
    allocator: std.mem.Allocator,
    mcp: *const McpProductState,
    desired: ?mcp_configuration.RegistryWire,
) std.mem.Allocator.Error![]const lifecycle.McpServerAllowlist {
    const startup = if (mcp.preparation.registry) |registry|
        registry.value
    else
        return allocator.alloc(lifecycle.McpServerAllowlist, 0);
    var count: usize = 0;
    for (mcp.preparation.server_states) |state| {
        if (state == .eligible) count += 1;
    }
    const allowlists = try allocator.alloc(lifecycle.McpServerAllowlist, count);
    var write: usize = 0;
    for (startup.servers, mcp.preparation.server_states) |server, state| {
        if (state != .eligible) continue;
        const target = if (desired) |registry|
            findMcpServer(registry.servers, server.id)
        else
            null;
        const tools = if (target) |value| if (value.enabled) value.tools else &.{} else &.{};
        const owned_tools = try allocator.alloc([]const u8, tools.len);
        for (tools, owned_tools) |tool, *owned|
            owned.* = try allocator.dupe(u8, tool);
        allowlists[write] = .{
            .id = try allocator.dupe(u8, server.id),
            .tools = owned_tools,
        };
        write += 1;
    }
    return allowlists;
}

pub const TaskPersistenceCommit = enum {
    committed,
    failed,
    outcome_unknown,
};

pub const TaskPersistence = struct {
    context: ?*anyopaque = null,
    enabled: bool = false,
    restored_bytes: ?[]const u8 = null,
    restore_failed: bool = false,
    commit_fn: *const fn (
        context: ?*anyopaque,
        bytes: []const u8,
    ) TaskPersistenceCommit = unsupportedTaskCommit,

    fn commit(self: TaskPersistence, bytes: []const u8) TaskPersistenceCommit {
        if (!self.enabled) return .failed;
        return self.commit_fn(self.context, bytes);
    }

    fn unsupportedTaskCommit(
        _: ?*anyopaque,
        _: []const u8,
    ) TaskPersistenceCommit {
        return .failed;
    }
};

pub const TaskPersistenceHealth = enum {
    unavailable,
    ready,
    degraded,
    read_failed,
    corrupt,
    write_failed,
    outcome_unknown,
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
const ui_record_detail_capacity: usize = 512;
const ui_record_snapshot_overhead: usize = 1024;
const tool_route_digest_bytes = std.crypto.hash.sha2.Sha256.digest_length;
const tool_product_id_capacity = "tool-".len + 20;
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

const CompactPhase = enum(u8) {
    queued,
    compacting,
    stopping,
    compacted,
    no_change,
    degraded,
    aborted,
    interrupted,
    failed,
};

const CompactCause = enum {
    user_cancel,
    session_close,
    app_shutdown,
    resource_limit,
    agent_failure,
    dependency_contract_failure,
};

const CompactTerminationDispatch = enum {
    queued_aborted,
    requested,
    already_requested,
    already_terminal,
    session_closing,
};

const ActiveOperation = task_runtime.ActiveOperation;

/// Workbench-owned durable product cause.
const RunCause = enum {
    user_cancel,
    timeout,
    session_close,
    app_shutdown,
    event_pipeline_failure,
    queue_capacity_failure,
    ui_pipeline_failure,
    agent_failure,
    stale_catalog,
    skill_not_found,
    invalid_skill_arguments,
    skill_policy_violation,
    skill_unavailable,
    resource_limit,
    dependency_contract_failure,
};

const TaskLifecycle = enum { open, closing, closed };

const ContinuationUnavailableReason = task_recovery.UnavailableReason;
const ContinuationCapability = task_recovery.Capability;

const CloseCompletion = task_runtime.CloseCompletion;

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

const permission_summary_field_capacity: usize = 128;

/// A bounded, redaction-safe permission decision summary. It is copied from
/// AgentCore provenance and may be attached to both the live Run and the
/// existing UI occurrence history. It contains no raw arguments or response.
const PermissionSummary = struct {
    decision: lifecycle.PermissionDecision,
    source: lifecycle.PermissionDecisionSource,
    policy_generation: u64,
    used_session_rule: bool,
    callback_outcome: ?lifecycle.PermissionCallbackOutcome,
    tool_namespace: lifecycle.PermissionToolNamespace,
    request_id: [permission_summary_field_capacity]u8 = undefined,
    request_id_len: usize = 0,
    matched_rule_id: [permission_summary_field_capacity]u8 = undefined,
    matched_rule_id_len: usize = 0,
    tool_name: [permission_summary_field_capacity]u8 = undefined,
    tool_name_len: usize = 0,
    tool_binding: [permission_summary_field_capacity]u8 = undefined,
    tool_binding_len: usize = 0,

    fn toolName(self: *const PermissionSummary) []const u8 {
        return self.tool_name[0..self.tool_name_len];
    }

    fn toolBinding(self: *const PermissionSummary) []const u8 {
        return self.tool_binding[0..self.tool_binding_len];
    }

    fn requestId(self: *const PermissionSummary) []const u8 {
        return self.request_id[0..self.request_id_len];
    }

    fn matchedRuleId(self: *const PermissionSummary) []const u8 {
        return self.matched_rule_id[0..self.matched_rule_id_len];
    }
};

fn permissionSummaryWire(
    permission: *const PermissionSummary,
) task_persistence.PermissionSummaryWire {
    return .{
        .request_id = permission.requestId(),
        .matched_rule_id = permission.matchedRuleId(),
        .tool_namespace = @tagName(permission.tool_namespace),
        .tool_name = permission.toolName(),
        .tool_binding = permission.toolBinding(),
        .decision = @tagName(permission.decision),
        .source = @tagName(permission.source),
        .policy_generation = permission.policy_generation,
        .used_session_rule = permission.used_session_rule,
        .callback_outcome = if (permission.callback_outcome) |outcome| @tagName(outcome) else null,
    };
}

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
    file_refs: ?[]?FileReferenceView = null,
};

pub const FileReferencePositionView = struct {
    line: u32,
    column: u32,
};

pub const FileReferenceRangeView = struct {
    start: FileReferencePositionView,
    end: FileReferencePositionView,
};

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

const FileReferenceLocatorKind = enum { workspace_path, absolute_path, uri };

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
const FileReferenceView = struct {
    id: []u8,
    title: []u8,
    display_path: []u8,
    kind: []u8,
    locator_kind: FileReferenceLocatorKind,
    locator: []u8,
    range: ?FileReferenceRangeView = null,
};

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

const CompactTerminalPayload = struct {
    phase: CompactPhase,
    cause: ?CompactCause,
    before_context_tokens: u64,
    after_context_tokens: u64,
    usage: UsageView,
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

/// Immutable checkpoint description facts captured by the main thread before
/// the operation is enqueued. Executor workers must not derive these values by
/// traversing Task-owned durable records after terminal publication: once the
/// active operation clears, the main thread may admit the next Run or compact.
const CheckpointExportContext = struct {
    task_id: u64,
    binding_epoch: u64,
    terminal_kind: std.meta.Tag(checkpoint_record.Terminal),
    terminal_id: u64,
    last_run_id: u64,
    last_compact_id: u64,
    model: []const u8,
};

const RunRecord = struct {
    id: u64,
    generation: u64,
    execution_generation: u64,
    execution_provider: Provider,
    execution_model: []const u8,
    execution_model_owned: bool = false,
    input: RunInputRecord,
    assistant: TrackedText = .{},
    assistant_redacted: bool = false,
    active_phase: RunPhase = .queued,
    tools: []?ToolView,
    usage: UsageView = .{},
    status_text: []u8,
    /// Latest monotonic AgentCore execution observation. These fields are
    /// runtime-only: an interrupted process never persists in-flight state.
    agent_phase: ?lifecycle.RunStatePhase = null,
    agent_transition_seq: ?u64 = null,
    agent_turn: u32 = 0,
    agent_tool_calls: u32 = 0,
    agent_in_flight_tools: u32 = 0,
    agent_observation_degraded: bool = false,
    permission_provenance: ?PermissionSummary = null,
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
    checkpoint_export_context: CheckpointExportContext = undefined,
    checkpoint: CheckpointPostprocess = .{},
};

const CompactRecord = struct {
    id: u64,
    after_run_id: u64,
    agent_handoff: std.atomic.Value(AgentHandoffState) = .init(.queued),
    pending_interruption: std.atomic.Value(PendingInterruption) = .init(.none),
    terminal_publication: std.atomic.Value(TerminalPublication) = .init(.open),
    terminal_payload: CompactTerminalPayload = undefined,
    terminal_observed: bool = false,
    terminal_diagnostic: []u8,
    redaction_secret: []const u8 = &.{},
    workbench: *Workbench = undefined,
    task: *TaskView = undefined,
    session: *lifecycle.Session = undefined,
    worker_reference_held: std.atomic.Value(bool) = .init(false),
    session_reference_held: std.atomic.Value(bool) = .init(false),
    checkpoint_export_context: CheckpointExportContext = undefined,
    checkpoint: CheckpointPostprocess = .{},
};

const UiRecordKind = enum { ask_question, permission };

const UiRecordState = enum {
    answered,
    allowed_once,
    // Persisted history wire name is retained for existing Task records; the
    // request/response choice exposed to users is now `allow_session`.
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
    agent_request_id: [permission_summary_field_capacity]u8 = undefined,
    agent_request_id_len: usize = 0,
    permission: ?PermissionSummary = null,
    detail: [ui_record_detail_capacity]u8 = undefined,
    detail_len: usize = 0,
    item_count: u32 = 0,
    detail_truncated: bool = false,
    redacted: bool = false,

    fn detailSlice(self: *const UiRecord) []const u8 {
        return self.detail[0..self.detail_len];
    }
};

/// Task-owned product history. Direct Task lifecycle and Session ownership
/// live in `RuntimeAttachment`. Nested Run and Compact records retain live
/// control fields until quiescent; the persistence codec explicitly allowlists
/// only durable, secret-free product facts.
const DurableTaskRecord = struct {
    id: u64,
    recent_order: u64,
    execution_generation: u64,
    execution_provider: Provider,
    execution_model: []u8,
    binding_epoch: u64 = 1,
    workspace_id: u64,
    workspace_epoch: u64 = 1,
    workspace_root: []u8,
    title: []u8,
    title_redacted: bool = false,
    archived: bool = false,
    closed: bool = false,
    runs: []?RunRecord,
    compacts: []?CompactRecord,
    next_run_generation: u64 = 0,
    ui_history: []?UiRecord,
    ui_history_count: usize = 0,
    ui_history_next: usize = 0,
    checkpoint: ?checkpoint_record.Record = null,
    checkpoint_anchor: CheckpointAnchor = .none,
    checkpoint_attempt: CheckpointAttempt = .none,
};

/// Validity of the durable recovery anchor itself. Only facts about the
/// stored record/blob may invalidate it; a failed later export attempt must
/// never demote an existing valid anchor.
const CheckpointAnchor = enum {
    none,
    available,
    blob_missing,
    blob_mismatch,
};

/// Outcome of the most recent checkpoint export/describe/store attempt.
/// This is diagnostic state about the attempt, not about the anchor.
const CheckpointAttempt = enum {
    none,
    export_failed,
    describe_failed,
    cancelled,
    resource_limit,
    io_failed,
    outcome_unknown,
    dependency_contract,
};

const CheckpointPostprocessState = enum(u8) {
    none,
    exporting,
    failure_ready,
    candidate_ready,
    store_outcome_unknown,
    settled,
};

const CheckpointCandidate = struct {
    record: checkpoint_record.Record,
    metrics: struct {
        chunk_count: u64,
        export_duration_ns: i128,
    },
};

const CheckpointPostprocessPayload = union(enum) {
    none,
    failure: CheckpointAttempt,
    candidate: CheckpointCandidate,
    store_outcome_unknown: CheckpointCandidate,
};

const CheckpointPostprocess = struct {
    state: std.atomic.Value(CheckpointPostprocessState) = .init(.none),
    cancelled: std.atomic.Value(bool) = .init(false),
    payload: CheckpointPostprocessPayload = .none,
};

const RuntimeAttachment = task_runtime.State;

const TaskView = struct {
    durable: DurableTaskRecord,
    runtime: RuntimeAttachment,
};

const TaskFailureRecord = struct {
    task_id: u64,
    recent_order: u64,
    reason: []u8,
};

const TaskStateWireScratch = struct {
    allocator: std.mem.Allocator,
    state: task_persistence.StateWire,
    allocated_workspaces: []task_persistence.WorkspaceWire,
    allocated_tasks: []task_persistence.TaskWire,
    allocated_failures: []task_persistence.TaskFailureWire,

    fn deinit(self: *TaskStateWireScratch) void {
        for (self.state.tasks) |task| {
            for (task.runs) |run| {
                if (run.input.argument_values) |values| self.allocator.free(values);
                for (run.tools) |tool| if (tool.file_refs) |references| self.allocator.free(references);
                self.allocator.free(run.tools);
            }
            self.allocator.free(task.runs);
            self.allocator.free(task.compacts);
            self.allocator.free(task.ui_history);
            if (task.checkpoint) |checkpoint|
                self.allocator.free(@constCast(checkpoint.blob.digest));
        }
        self.allocator.free(self.allocated_tasks);
        self.allocator.free(self.allocated_workspaces);
        self.allocator.free(self.allocated_failures);
        self.* = undefined;
    }
};

test "Task aggregate separates Task runtime ownership from product history" {
    try std.testing.expect(@hasField(TaskView, "durable"));
    try std.testing.expect(@hasField(TaskView, "runtime"));
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
        "session",
        "execution",
        "route_id",
        "pinned_catalog",
    }) |field_name| {
        try std.testing.expect(@hasField(task_runtime.LiveAttachment, field_name));
        try std.testing.expect(!@hasField(RuntimeAttachment, field_name));
        try std.testing.expect(!@hasField(DurableTaskRecord, field_name));
    }
    try std.testing.expect(!@hasField(RuntimeAttachment, "lifecycle"));
    try std.testing.expect(!@hasField(RuntimeAttachment, "continuation"));
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
    catalog_availability: CatalogAvailability = .uninitialized,
    catalog_request_generation: u64 = 0,
    catalog_job: ?*CatalogJob = null,
    catalog_reschedule_pending: bool = false,
    catalog_lease: ?*lifecycle.CatalogLease = null,
    catalog: ?CatalogSnapshot = null,
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
    skill_catalog_availability: CatalogAvailability = .uninitialized,
    skill_catalog_request_generation: u64 = 0,
    skill_catalog_job: ?*CatalogJob = null,
    skill_catalog_lease: ?*lifecycle.CatalogLease = null,
    skill_catalog: ?CatalogSnapshot = null,
    execution_replacement: ExecutionReplacementKind = .none,
    custom_execution_binding: ?CustomExecutionBinding = null,
    model_connection_capabilities: ModelConnectionCapabilities,
    mcp: ?McpProductState = null,
    builtin_tool_profile: ?lifecycle.BuiltinToolProfile,
    next_workspace_id: u64 = 1,
    next_workspace_recent_order: u64 = 1,
    next_task_id: u64 = 1,
    next_task_recent_order: u64 = 1,
    next_restore_attempt_id: u64 = 1,
    recovery_poisoned: bool = false,

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
            .max_disabled_skill_ids = limits.max_catalog_skills,
            .max_skill_id_bytes = limits.max_tool_field_bytes,
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
            .builtin_tool_profile = configuration.builtin_tool_profile,
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
        if (self.identityReplacementBlocker()) |blocker|
            return switch (blocker) {
                .running => error.TaskRunning,
                .session => error.TaskSessionInUse,
            };
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

    pub fn setSkillEnabled(
        self: *Workbench,
        mutation: SkillEnablementMutation,
    ) Error!u64 {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        self.syncLifecycle();
        if (self.skill_enablement_health != .ready or
            self.skill_enablement_file_store == null)
            return error.PersistenceFailed;
        const workspace = self.findWorkspace(mutation.workspace_id) orelse
            return error.UnknownWorkspace;
        if (workspace.kind != .manual or !workspace.visible or
            workspace.authorization != .available)
            return error.WorkspaceUnavailable;
        if (mutation.expected_workspace_epoch == 0 or
            mutation.expected_workspace_epoch != workspace.epoch)
            return error.WorkspaceEpochMismatch;
        if (workspace.catalog_availability != .ready and
            workspace.catalog_availability != .degraded)
            return error.CatalogUnavailable;
        const catalog = if (workspace.catalog) |*value| value else return error.CatalogUnavailable;
        if (!std.mem.eql(u8, mutation.expected_catalog_revision, catalog.revision))
            return error.StaleCatalog;
        if (catalog.selection_revision == null or
            mutation.expected_selection_revision != catalog.selection_revision.?)
            return error.StaleCatalog;
        _ = catalog.findSkill(mutation.skill_id) orelse return error.SkillNotFound;
        var candidate = try self.skill_enablement.clone();
        var candidate_owned = true;
        defer if (candidate_owned) candidate.deinit();
        const identity: skill_enablement_impl.WorkspaceIdentity = .{
            .workspace_id = workspace.id,
            .workspace_epoch = workspace.epoch,
        };
        const next_revision = try candidate.applyWorkspace(.{
            .identity = identity,
            .skill_id = mutation.skill_id,
            .state = if (mutation.enabled) .enabled else .disabled,
            .expected_revision = mutation.expected_selection_revision,
        });
        self.commitSkillEnablementCandidate(&candidate) catch |err| {
            self.noteSkillEnablementPersistenceFailure(err);
            return err;
        };
        candidate_owned = false;
        if (!self.applyWorkspaceSkillEnablement(workspace, catalog))
            unreachable;
        self.bumpRevision();
        return next_revision;
    }

    pub fn refreshMcpCatalog(self: *Workbench) Error!void {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        self.syncLifecycle();
        const mcp = if (self.mcp) |*value| value else return error.CatalogUnavailable;
        if (!mcp.committed) return error.CatalogUnavailable;
        switch (mcp.preparation.state) {
            .empty, .available => {},
            .unavailable => return error.CatalogUnavailable,
        }
        if (mcp.refresh_job != null) return error.CatalogLoading;
        const management = if (mcp.management) |*value| value else return error.CatalogUnavailable;
        const inspection = management.inspect();
        if (inspection.health != .ready) return error.McpManagementUnavailable;
        if (mcp.refresh_request_generation == std.math.maxInt(u64))
            return error.CatalogRequestGenerationExhausted;
        const generation = mcp.refresh_request_generation + 1;
        var refresh_arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer refresh_arena.deinit();
        const desired = management.desiredRegistry();
        const alignment = inspection.runtime_alignment;
        const allowlists = try buildMcpRefreshAllowlists(
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
            .arena = refresh_arena,
            .allowlists = allowlists,
            .build_admission = alignment == .current,
        };
        self.blockMcpAdmission(mcp, .refreshing);
        errdefer self.blockMcpAdmission(mcp, .activation_unavailable);
        try self.executor.enqueue(.{
            .context = job,
            .execute_fn = executeMcpRefreshJob,
            .cancel_fn = cancelMcpRefreshJob,
        });
        mcp.refresh_request_generation = generation;
        mcp.refresh_job = job;
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
            catalogSnapshotLimits(self.limits),
            self.limits.max_projection_bytes - self.projection_bytes,
        );
        errdefer replacement.deinit();
        var disabled_skill_ids: std.ArrayList([]const u8) = .empty;
        defer disabled_skill_ids.deinit(self.allocator);
        for (replacement.skills) |skill|
            if (!skill.enabled) try disabled_skill_ids.append(
                self.allocator,
                skill.skill_id,
            );
        const session = task.runtime.session() orelse return error.TaskClosing;
        try session.refreshSkillCatalog(lease, .{
            .disabled_skill_ids = disabled_skill_ids.items,
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
            if (task.durable.workspace_id != workspace_id or task.runtime.session() == null) continue;
            self.closeTask(task.durable.id) catch |err| switch (err) {
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
            if (mcp.refresh_job != null) return error.CatalogLoading;
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
        switch (workspace_view.catalog_availability) {
            .ready, .degraded => {
                const current = workspace_view.catalog orelse
                    return error.CatalogUnavailable;
                if (expected_skill_catalog_revision) |expected|
                    if (!std.mem.eql(u8, expected, current.revision))
                        return error.StaleCatalog;
                if ((expected_skill_catalog_revision == null) !=
                    (expected_skill_selection_revision == null))
                    return error.StaleCatalog;
                if (expected_skill_selection_revision) |expected|
                    if (current.selection_revision == null or
                        expected != current.selection_revision.?)
                        return error.StaleCatalog;
                pinned_catalog = try current.clone(
                    self.allocator,
                    catalogSnapshotLimits(self.limits),
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
        if (expected_skill_catalog_revision == null and
            expected_skill_selection_revision != null)
            return error.StaleCatalog;
        var disabled_skill_ids: std.ArrayList([]const u8) = .empty;
        defer disabled_skill_ids.deinit(self.allocator);
        if (pinned_catalog) |*snapshot| for (snapshot.skills) |skill|
            if (!skill.enabled) try disabled_skill_ids.append(
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
        const route = self.agent_runtime.createSessionRoute(.{
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
            .skill_selection = if (catalog_lease != null) .{
                .disabled_skill_ids = disabled_skill_ids.items,
            } else null,
            .mcp_selection = self.mcpSelectionForNewTask(),
            .allowed_tools = if (self.builtin_tool_profile) |profile|
                lifecycle.builtinToolsForProfile(profile)
            else
                &lifecycle.desktop_builtin_tools,
        }) catch |err| switch (err) {
            error.SessionCapacity => return error.TaskCapacity,
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
                    .session = route.session,
                    .execution = task_execution.take(),
                    .route_id = route.id,
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
            switch (live.session.closeOutcome(.session_close)) {
                .closed => self.agent_runtime.releaseClosedSession(route.session) catch
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
        const current_catalog = workspace.catalog orelse
            return error.RecoveryUnavailable;
        var disabled_skill_ids: std.ArrayList([]const u8) = .empty;
        defer disabled_skill_ids.deinit(self.allocator);
        for (current_catalog.skills) |skill|
            if (!self.skill_enablement.isEnabled(skill_identity, skill.skill_id))
                try disabled_skill_ids.append(self.allocator, skill.skill_id);
        var skill_selection = try task_recovery_job.OwnedSkillSelection.init(
            self.allocator,
            self.skill_enablement.revision(skill_identity),
            disabled_skill_ids.items,
        );
        var skill_selection_live = true;
        errdefer if (skill_selection_live) skill_selection.deinit();
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
                .skill_selection = skill_selection,
                .execution = execution.take(),
                .model = target_model,
                .provider = agentProvider(task.durable.execution_provider),
                .builtin_tool_profile = self.builtin_tool_profile,
                .mcp_selection = mcp.selection,
                .mcp_catalog_generation = mcp.catalog_generation,
            },
        };
        checkpoint_copy_live = false;
        workspace_copy_live = false;
        skill_selection_live = false;
        mcp.selection = null;
        task.runtime.active_operation = .{ .restore = .{ .id = attempt_id } };
        task.runtime.restore_job = job;
        task.runtime.last_restore_failure = null;
        _ = task.runtime.worker_references.fetchAdd(1, .acq_rel);
        self.executor.enqueue(.{
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
        const session = task.runtime.session() orelse return error.TaskClosing;
        try session.setModel(model);
        const replacement = self.copyBounded(
            model,
            account_contract.Limits.model_id_bytes,
        ) catch |err| {
            _ = self.restoreTaskModelOrDetach(task, session, expected_model);
            return err;
        };
        const previous = task.durable.execution_model;
        task.durable.execution_model = replacement;
        self.commitTaskStateIfConfigured() catch |err| {
            // Keep the durable binding and live Session coherent if the
            // persistence commit fails after AgentCore accepted the change.
            if (err == error.TaskPersistenceOutcomeUnknown)
                self.releaseTaskAttachmentNoFail(task, .cold_start)
            else
                _ = self.restoreTaskModelOrDetach(task, session, expected_model);
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
        const session = view.runtime.session() orelse return error.TaskClosing;
        try self.applyPendingTaskModel(view, session);
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
                if (pinned.selection_revision == null or
                    skill_input.selection_revision != pinned.selection_revision.?)
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
        const run_id = try session.prepareRun(agent_input);
        var prepared = true;
        errdefer if (prepared) cancelPreparedRunOrPanic(session, run_id);
        const slot = try self.reserveRunRecord(view, input);
        var record_owned = true;
        errdefer if (record_owned) self.discardRunRecord(view, slot);
        const run = &view.durable.runs[slot].?;
        run.id = run_id;
        run.workbench = self;
        run.task = view;
        run.session = session;
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
        const automatic_title_applied = self.applyAutomaticTaskTitle(view, run);
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
            if (automatic_title_applied)
                self.rollbackAutomaticTaskTitle(
                    view,
                    previous_title,
                    previous_title_redacted,
                );
            return err;
        };
        if (automatic_title_applied) self.allocator.free(previous_title);
        _ = view.runtime.worker_references.fetchAdd(1, .acq_rel);
        run.worker_reference_held.store(true, .release);
        self.executor.enqueue(.{
            .context = run,
            .execute_fn = executeRunJob,
            .cancel_fn = cancelRunJobForShutdown,
        }) catch |err| {
            releaseWorkerReference(run);
            cancelPreparedRunOrPanic(session, run_id);
            prepared = false;
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
        prepared = false;
        record_owned = false;
        self.bumpRevision();
        return run_id;
    }

    fn applyPendingTaskModel(
        self: *Workbench,
        task: *TaskView,
        session: *lifecycle.Session,
    ) Error!void {
        const pending = task.runtime.pending_model orelse return;
        const previous = task.durable.execution_model;
        try session.setModel(pending);
        const replacement = self.copyBounded(
            pending,
            account_contract.Limits.model_id_bytes,
        ) catch |err| {
            _ = self.restoreTaskModelOrDetach(task, session, previous);
            return err;
        };
        task.durable.execution_model = replacement;
        self.commitTaskStateIfConfigured() catch |err| {
            const coherent = if (err == error.TaskPersistenceOutcomeUnknown) blk: {
                self.releaseTaskAttachmentNoFail(task, .cold_start);
                break :blk false;
            } else self.restoreTaskModelOrDetach(task, session, previous);
            self.freeTracked(task.durable.execution_model);
            task.durable.execution_model = previous;
            if (coherent) task.runtime.pending_model = pending;
            return err;
        };
        task.runtime.pending_model = null;
        self.freeTracked(previous);
        self.allocator.free(pending);
    }

    /// If AgentCore cannot return to the durable model after a failed model
    /// mutation, detach the Session so no caller can continue with an
    /// ambiguous model binding. The Task remains recoverable only through its
    /// normal persisted checkpoint path.
    fn restoreTaskModelOrDetach(
        self: *Workbench,
        task: *TaskView,
        session: *lifecycle.Session,
        model: []const u8,
    ) bool {
        session.setModel(model) catch {
            self.releaseTaskAttachmentNoFail(task, .cold_start);
            return false;
        };
        return true;
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
        const session = view.runtime.session() orelse return error.TaskClosing;
        const operation_id = try session.prepareCompact();
        var prepared = true;
        errdefer if (prepared)
            cancelPreparedCompactOrPanic(session, operation_id);
        const slot = try self.reserveCompactRecord(view, operation_id, after_run_id);
        var record_owned = true;
        errdefer if (record_owned) self.discardCompactRecord(view, slot);
        const compact = &view.durable.compacts[slot].?;
        compact.workbench = self;
        compact.task = view;
        compact.session = session;
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
        if (!session.retainReference()) {
            cancelPreparedCompactOrPanic(session, operation_id);
            prepared = false;
            _ = commitCompactProductTerminal(
                compact,
                .interrupted,
                .session_close,
                .closing,
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
            return error.TaskClosing;
        }
        compact.session_reference_held.store(true, .release);
        _ = view.runtime.worker_references.fetchAdd(1, .acq_rel);
        compact.worker_reference_held.store(true, .release);
        self.executor.enqueue(.{
            .context = compact,
            .execute_fn = executeCompactJob,
            .cancel_fn = cancelCompactJobForShutdown,
        }) catch |err| {
            releaseCompactReferences(compact);
            cancelPreparedCompactOrPanic(session, operation_id);
            prepared = false;
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
            cancelPreparedCompactOrPanic(compact.session, compact.id);
            _ = commitCompactProductTerminal(
                compact,
                .aborted,
                compactCauseForInterruption(pendingExternalInterruption(compact)),
                if (pendingExternalInterruption(compact) == .user_cancel)
                    .reusable
                else
                    .closing,
                .{},
                0,
                0,
                "",
                false,
            );
            releaseCompactReferences(compact);
            self.touchTask(view);
            self.syncLifecycle();
            self.commitTaskStateNoFail();
            return .queued_aborted;
        } else {
            compact.session.requestCompactCancellation(
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
        const session = view.runtime.session() orelse
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
            view.runtime.cancel_requested = false;
            self.touchTask(view);
            self.commitTaskStateNoFail();
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
        const session = view.runtime.session() orelse
            return error.TaskClosing;
        const answer_count = switch (response) {
            .answers => |answers| answers.len,
            .permission => 0,
        };
        const answer_buffer = try self.allocator.alloc(lifecycle.Answer, answer_count);
        defer self.allocator.free(answer_buffer);
        const record = self.prepareUiRecord(
            session,
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
        const response_result = switch (response) {
            .answers => |answers| session.respondAnswers(
                run_id,
                request_id,
                agentAnswers(answers, answer_buffer),
            ),
            .permission => |choice| session.respondPermission(
                run_id,
                request_id,
                agentPermissionChoice(choice),
            ),
        };
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

    pub fn closeTask(self: *Workbench, task_id: u64) Error!void {
        self.syncLifecycle();
        const view = self.findTask(task_id) orelse return error.UnknownTask;
        if (!hasActiveOperation(view) and self.checkpointMutationPending(view)) {
            cancelTaskCheckpoints(view);
            return error.TaskBusy;
        }
        if (view.runtime.close_completion.load(.acquire) == .running) return error.CloseInProgress;
        const retrying_closing_session = view.runtime.close_failed and
            view.runtime.closingSession() != null;
        const session = view.runtime.session() orelse
            view.runtime.closingSession() orelse {
            if (view.durable.closed) return;
            switch (view.runtime.attachment) {
                .detached => {},
                .attached, .closing => return,
            }
            try self.requireTaskPersistenceMutation();
            const previous_recent_order = view.durable.recent_order;
            const previous_next_recent_order = self.next_task_recent_order;
            view.durable.closed = true;
            view.runtime.attachment = .{ .detached = .closed };
            self.touchTask(view);
            self.commitTaskStateIfConfigured() catch |err| {
                view.durable.closed = false;
                view.runtime.attachment = .{ .detached = .cold_start };
                view.durable.recent_order = previous_recent_order;
                self.next_task_recent_order = previous_next_recent_order;
                return err;
            };
            self.bumpRevision();
            return;
        };
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
        const cancelled_ui = if (view.runtime.pending_ui_request_id != 0)
            self.prepareCancelledUiRecord(
                session,
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
            if (self.executor.cancel(run)) {
                cancelPreparedRunOrPanic(session, view.runtime.active_run_id);
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
        if (!retrying_closing_session)
            std.debug.assert(view.runtime.beginClosing());
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
            self.agent_runtime,
            view,
            session,
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
        self.bumpRevision();
    }

    pub fn renameTask(self: *Workbench, task_id: u64, title: []const u8) Error!void {
        self.syncLifecycle();
        try self.requireTaskPersistenceMutation();
        const view = self.findTask(task_id) orelse return error.UnknownTask;
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
        if (taskLifecycle(view) == .closing or hasActiveOperation(view)) return error.TaskBusy;
        if (view.durable.archived == archived) return;
        const previous_recent_order = view.durable.recent_order;
        const previous_next_recent_order = self.next_task_recent_order;
        view.durable.archived = archived;
        self.touchTask(view);
        self.commitTaskStateIfConfigured() catch |err| {
            view.durable.archived = !archived;
            view.durable.recent_order = previous_recent_order;
            self.next_task_recent_order = previous_next_recent_order;
            return err;
        };
        self.bumpRevision();
    }

    pub fn deleteTask(self: *Workbench, task_id: u64) Error!void {
        const pending = self.findTask(task_id) orelse return error.UnknownTask;
        if (self.checkpointMutationPending(pending)) {
            cancelTaskCheckpoints(pending);
            return error.TaskBusy;
        }
        self.syncLifecycle();
        try self.requireTaskPersistenceMutation();
        const index = self.findTaskIndex(task_id) orelse return error.UnknownTask;
        const view = &(self.tasks[index] orelse unreachable);
        if (taskLifecycle(view) != .closed or view.runtime.close_thread != null or
            view.runtime.session() != null)
            return error.TaskNotClosed;
        // A closed Task must not release Run storage while the composition
        // root still owes that Run its final event-pump drain. This is
        // normally implied by close publication in `syncLifecycle`; keep the
        // explicit guard here because deletion is the destructive boundary.
        if (hasUnfinalizedTerminalEvents(view)) return error.TaskBusy;
        if (view.runtime.worker_references.load(.acquire) != 0)
            return error.TaskBusy;
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
        if (self.checkpoint_store) |store| store.deleteTask(task_id);
        self.deinitTaskView(&removed_task);
        if (removed_workspace_index != null)
            self.deinitWorkspaceView(&removed_workspace);
        self.bumpRevision();
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
        for (self.tasks) |*entry| {
            const view = &(entry.* orelse continue);
            const recovery_commit = self.commitRecoveryJobNoFail(view);
            changed = recovery_commit.changed or changed;
            durable_changed = recovery_commit.durable_changed or durable_changed;
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
                std.debug.assert(view.runtime.closingSession() != null);
                view.runtime.close_completion.store(.none, .release);
                switch (close_completion) {
                    .closed => {
                        var live = view.runtime.detach(.closed);
                        self.releaseExecutionValueNoFail(view, &live.execution);
                        if (live.pinned_catalog) |*snapshot| {
                            self.projection_bytes -= snapshot.projected_bytes;
                            snapshot.deinit();
                        }
                        view.runtime.close_failed = false;
                        if (!view.durable.closed) {
                            view.durable.closed = true;
                            durable_changed = true;
                        }
                    },
                    .failed_reusable, .failed_poisoned, .failed_closing => {
                        view.runtime.close_failed = true;
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
            const session = if (view.runtime.worker_references.load(.acquire) != 0 and
                view.runtime.active_run_id != 0)
                view.runtime.session()
            else
                null;
            const pending = if (session) |value| value.pendingUiObservation() else null;
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
        if (changed) self.bumpRevision();
    }

    const RecoveryCommit = struct {
        changed: bool = false,
        durable_changed: bool = false,
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
        if (job.takeCandidate()) |candidate_value| {
            var candidate = candidate_value;
            const workspace = self.findWorkspace(task.durable.workspace_id);
            const record_matches = if (task.durable.checkpoint) |record|
                checkpointIdentityEqual(record.blob, job.attempt.checkpoint.blob)
            else
                false;
            const commit_allowed = operation_matches and
                !self.shutting_down and
                !task.durable.closed and
                !task.durable.archived and
                task.runtime.attachment == .detached and
                task.durable.binding_epoch == job.attempt.binding_epoch and
                record_matches and
                self.recoveryExecutionExact(task) and
                self.recoveryAuthorityStable(workspace) and
                optionalU64Equal(
                    self.recoveryMcpGeneration(),
                    job.attempt.mcp_catalog_generation,
                ) and
                candidate.pinned_catalog.projected_bytes <=
                    self.limits.max_projection_bytes - self.projection_bytes;
            if (commit_allowed) {
                self.projection_bytes += candidate.pinned_catalog.projected_bytes;
                task.runtime.last_restore_permission = .{
                    .restored_rules = candidate.route.report.restored_permission_rules,
                    .invalidated_rules = candidate.route.report.invalidated_permission_rules,
                };
                task.runtime.attachment = .{ .attached = .{
                    .session = candidate.route.session,
                    .execution = candidate.takeExecution(),
                    .route_id = candidate.route.id,
                    .pinned_catalog = candidate.takeCatalog(),
                } };
                task.runtime.last_restore_failure = null;
            } else if (!candidate.discard()) {
                self.recovery_poisoned = true;
                task.runtime.last_restore_failure = .candidate_cleanup_failed;
            }
        } else if (job.failure()) |failure| {
            task.runtime.last_restore_failure = failure;
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
        return .{ .changed = true, .durable_changed = durable_changed };
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
                releaseWorkerReference(run);
            changed = true;
        }
        for (task.durable.compacts) |*entry| {
            const compact = &(entry.* orelse continue);
            if (!compact.terminal_observed) continue;
            if (!self.commitCheckpointPostprocessNoFail(task, &compact.checkpoint)) continue;
            if (compact.checkpoint.state.load(.acquire) == .settled)
                releaseCompactWorkerReference(compact);
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
        const run = findRun(task.durable.runs, envelope.run_id) orelse return error.NoSuchRun;
        if (run.event_stream_finalized) {
            // A late event cannot change a published product terminal, and it
            // is not by itself proof of an AgentCore contract violation. Drop
            // it and keep a bounded runtime-only count as diagnostic evidence;
            // Session poisoning stays owned by the real Session disposition.
            self.late_terminal_event_count +|= 1;
            if (builtin.mode == .Debug) std.log.warn(
                "workbench.late_terminal_event task_id={d} run_id={d} count={d}",
                .{ task.durable.id, envelope.run_id, self.late_terminal_event_count },
            );
            return;
        }
        const event = switch (envelope.event.value) {
            .unknown => return,
            .known => |known| known,
        };
        var durable_boundary = false;
        switch (event) {
            .thinking_chunk => {
                // AgentCore owns the private reasoning bytes. Workbench only
                // projects the safe activity distinction and never appends the
                // payload to Assistant history.
                if (std.mem.eql(u8, run.status_text, "Thinking")) return;
                _ = try self.replaceTrackedProjected(
                    &run.status_text,
                    "Thinking",
                    self.limits.max_tool_field_bytes,
                    run.redaction_secret,
                );
            },
            .text_chunk => |text| {
                try self.appendTrackedText(&run.assistant, text, self.limits.max_assistant_message_bytes);
                if (self.redactTrackedText(&run.assistant, run.redaction_secret))
                    run.assistant_redacted = true;
                if (!std.mem.eql(u8, run.status_text, "Writing response"))
                    _ = try self.replaceTrackedProjected(
                        &run.status_text,
                        "Writing response",
                        self.limits.max_tool_field_bytes,
                        run.redaction_secret,
                    );
            },
            .tool_start => |tool| {
                const view = try self.findOrCreateTool(run, tool.id, tool.name, tool.input);
                view.state = .running;
                _ = try self.replaceTrackedProjected(&run.status_text, "Executing tools", self.limits.max_tool_field_bytes, run.redaction_secret);
            },
            .tool_progress => |progress| {
                const tool = findTool(run.tools, progress.id) orelse return error.ToolCapacity;
                const projected = try self.replaceTrackedProjected(&tool.progress, progress.text, self.limits.max_tool_field_bytes, run.redaction_secret);
                tool.progress_truncated = projected.truncated;
                tool.redacted = tool.redacted or projected.redacted;
            },
            .progress => _ = try self.replaceTrackedProjected(&run.status_text, "Executing tools", self.limits.max_tool_field_bytes, run.redaction_secret),
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
                const file_refs = if (comptime @hasField(@TypeOf(result), "file_refs"))
                    result.file_refs
                else
                    null;
                try self.replaceFileReferences(
                    tool,
                    file_refs,
                    run.redaction_secret,
                    task.durable.id,
                    run.generation,
                );
                durable_boundary = true;
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
            .run_state => |state| {
                if (state.run_id != run.id) {
                    run.agent_observation_degraded = true;
                    return;
                }
                if (run.agent_transition_seq) |last| {
                    if (state.transition_seq <= last) return;
                }
                run.agent_transition_seq = state.transition_seq;
                run.agent_phase = state.phase;
                run.agent_turn = state.turn;
                run.agent_tool_calls = state.tool_calls;
                run.agent_in_flight_tools = std.math.cast(u32, state.in_flight_tools.len) orelse {
                    run.agent_observation_degraded = true;
                    return;
                };
                _ = try self.replaceTrackedProjected(
                    &run.status_text,
                    agentRunStateStatus(state.phase),
                    self.limits.max_tool_field_bytes,
                    run.redaction_secret,
                );
            },
            .permission_provenance => |provenance| {
                const summary = try permissionSummary(provenance);
                run.permission_provenance = summary;
                if (provenance.request_id) |request_id|
                    if (findUiRecordByAgentRequestId(task.durable.ui_history, request_id, run.id)) |record| {
                        record.permission = summary;
                        self.commitTaskStateNoFail();
                    };
                const status = switch (provenance.decision) {
                    .allow => "Permission allowed",
                    .ask => "Permission requested",
                    .deny => "Permission denied",
                };
                _ = try self.replaceTrackedProjected(
                    &run.status_text,
                    status,
                    self.limits.max_tool_field_bytes,
                    run.redaction_secret,
                );
            },
            .stream_done => _ = try self.replaceTrackedProjected(&run.status_text, "Finishing", self.limits.max_tool_field_bytes, run.redaction_secret),
        }
        if (durable_boundary) self.commitTaskStateNoFail();
        self.bumpRevision();
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
        if (run.event_projection_failure != null) return;
        run.event_projection_failure = .consumer_rejected;
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
            for (task.durable.runs) |*run_entry| {
                const run = &(run_entry.* orelse continue);
                if (run.event_stream_finalized or run.terminal_event_drain_marked)
                    continue;
                if (terminalPayload(run) != null)
                    run.terminal_event_drain_marked = true;
            }
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
        const mcp = if (self.mcp) |*value| value else return null;
        const operation = mcp.authorization_operation orelse return null;
        return .{
            .phase = operation.phase,
            .server_id = operation.server_id,
            .operation_id = operation.operation_id,
        };
    }

    pub fn mcpServerOperationBusy(
        self: *const Workbench,
        server_id: []const u8,
    ) bool {
        const mcp = if (self.mcp) |*value| value else return false;
        if (mcpServerMutationBusy(mcp, server_id)) return true;
        const management = if (mcp.management) |*value| value else return false;
        const registry = management.desiredRegistry() orelse return false;
        const operation = registry.oauth_operation orelse return false;
        return std.mem.eql(u8, operation.server_id, server_id);
    }

    pub fn requireMcpOauthReauthorization(
        self: *Workbench,
        failure: McpRuntimeAuthorizationFailure,
    ) Error!McpRuntimeAuthorizationFailureOutcome {
        if (self.shutting_down) return .rejected;
        const mcp = if (self.mcp) |*value| value else return .rejected;
        if (mcp.refresh_job != null) return .rejected;
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
        const scope_step_up = mcpScopeSetAddsRequirement(
            consent.scopes,
            failure.challenge_scopes,
        );
        if (std.mem.eql(u8, oauth.status, "reauth_required")) {
            var pending = if (failure.challenge_scopes.len != 0)
                try prepareMcpPendingReauthorization(
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
                installMcpPendingReauthorization(mcp, replacement);
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
            try prepareMcpPendingReauthorization(
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
            installMcpPendingReauthorization(mcp, replacement);
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
        self.blockMcpAdmission(mcp, .runtime_authorization_failure);
        self.bumpRevision();
    }

    pub fn beginMcpAuthorization(
        self: *Workbench,
        expected_generation: u64,
        server_id: []const u8,
    ) Error!?McpAuthorizationStart {
        if (self.shutting_down) return null;
        const mcp = if (self.mcp) |*value| value else return null;
        if (mcp.refresh_job != null or mcp.authorization_operation != null)
            return null;
        const management = if (mcp.management) |*value| value else return null;
        if (!mcpExpectedGenerationMatches(management, expected_generation) or
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
            mcpPendingReauthorizationScopes(mcp, server.id, consent.epoch)
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
            !validMcpAuthorizationTransition(operation.phase, phase))
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
        if (mcp.refresh_job != null or mcpServerMutationBusy(mcp, server_id))
            return error.McpManagementUnavailable;
        const management = if (mcp.management) |*value| value else return error.McpManagementUnavailable;
        if (management.inspect().health != .ready or
            !mcpExpectedGenerationMatches(management, expected_generation))
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
        if (mcp.refresh_job != null or mcpServerMutationBusy(mcp, server_id))
            return error.McpManagementUnavailable;
        const management = if (mcp.management) |*value| value else return error.McpManagementUnavailable;
        if (management.inspect().health != .ready or
            !mcpExpectedGenerationMatches(management, expected_generation))
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
        if (mcp.refresh_job != null) return .rejected;
        if (!mcpAuthorizationAt(
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
        if (mcp.refresh_job != null) return .rejected;
        if (!mcpAuthorizationAt(
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
        if (mcp.refresh_job != null) {
            if (input.client_secret) |secret| std.crypto.secureZero(u8, secret);
            return .rejected;
        }
        if (!mcpAuthorizationAt(mcp, input.server_id, &.{.registering})) {
            if (input.client_secret) |secret| std.crypto.secureZero(u8, secret);
            return .rejected;
        }
        const management = if (mcp.management) |*value| value else {
            if (input.client_secret) |secret| std.crypto.secureZero(u8, secret);
            return .rejected;
        };
        var preparation = try management.prepareCompleteDynamicRegistration(input);
        return self.commitMcpMutation(mcp, &preparation);
    }

    pub fn beginMcpOauthCodeExchange(
        self: *Workbench,
        server_id: []const u8,
    ) Error!McpOauthCodeExchangeBeginOutcome {
        if (self.shutting_down) return .rejected;
        const mcp = if (self.mcp) |*value| value else return .rejected;
        if (mcp.refresh_job != null) return .rejected;
        if (!mcpAuthorizationAt(mcp, server_id, &.{.awaiting_browser}))
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
        if (mcp.refresh_job != null) {
            std.crypto.secureZero(u8, input.access_token);
            if (input.refresh_token) |secret| std.crypto.secureZero(u8, secret);
            return .rejected;
        }
        if (!mcpAuthorizationAt(mcp, input.server_id, &.{.exchanging})) {
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
        return self.commitMcpMutation(mcp, &preparation);
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
                self.installMcpCommittedDesiredState(mcp, management, reduced);
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
                self.blockMcpAdmission(mcp, .persistence_outcome_unknown);
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
        if (mcp.authorization_operation != null) return null;
        const management = if (mcp.management) |*value| value else return null;
        if (management.inspect().health != .ready) return null;
        const registry = management.desiredRegistry() orelse return null;
        if (registry.oauth_operation != null) return null;
        var earliest: ?McpOauthExpiry = null;
        for (registry.servers) |server| {
            if (!mcpServerAdmittedByDesiredState(server)) continue;
            const oauth = server.auth.oauth orelse continue;
            const grant = oauth.grant orelse continue;
            if (grant.refresh_token_ref == null) continue;
            const expires_at = grant.expires_at_unix_ms orelse continue;
            if (earliest == null or expires_at < earliest.?.expires_at_unix_ms)
                earliest = .{
                    .server_id = server.id,
                    .expires_at_unix_ms = expires_at,
                };
        }
        return earliest;
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
        if (!mcp.committed or mcp.refresh_job != null or
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
        var binding = try buildMcpOauthRefreshBinding(
            self.allocator,
            preparation.target(),
        );
        var binding_owned = true;
        defer if (binding_owned) binding.deinit();
        const outcome = try management.commitPreparedOauthOperationState(&preparation);
        switch (outcome) {
            .saved => {
                self.installMcpCommittedDesiredState(mcp, management, reduced);
                reduced_owned = false;
                binding_owned = false;
                self.bumpRevision();
                return .{ .started = binding };
            },
            .indeterminate => {
                self.blockMcpAdmission(mcp, .persistence_outcome_unknown);
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
        if (mcp.refresh_job != null) {
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
                        self.installMcpCommittedDesiredState(mcp, management, candidate);
                        candidate_owned = false;
                        self.bumpRevision();
                    },
                    .indeterminate => {
                        self.blockMcpAdmission(mcp, .persistence_outcome_unknown);
                        self.bumpRevision();
                    },
                    .rejected => if (management.inspect().health != .ready) {
                        self.blockMcpAdmissionForCurrentState(mcp);
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
        if (mcp.refresh_job != null) return .rejected;
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
                self.installMcpCommittedDesiredState(mcp, management, candidate);
                candidate_owned = false;
                self.bumpRevision();
            },
            .indeterminate => {
                self.blockMcpAdmission(mcp, .persistence_outcome_unknown);
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
        if (mcp.refresh_job != null) return .rejected;
        const management = if (mcp.management) |*value| value else return .rejected;
        var preparation = try management.prepareOauthOperationRecovery(operation_id);
        return try self.commitMcpMutation(mcp, &preparation);
    }

    pub fn createMcpHttpServer(
        self: *Workbench,
        expected_generation: u64,
        input: mcp_configuration.CreateHttpServerInput,
    ) Error!mcp_configuration.ManagementOutcome {
        if (self.shutting_down) return .rejected;
        const mcp = if (self.mcp) |*value| value else return .rejected;
        if (mcp.refresh_job != null) return .rejected;
        const management = if (mcp.management) |*value| value else return .rejected;
        if (!mcpExpectedGenerationMatches(management, expected_generation))
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
        if (mcp.refresh_job != null) return .rejected;
        const management = if (mcp.management) |*value| value else return .rejected;
        if (!mcpExpectedGenerationMatches(management, expected_generation))
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
        if (mcp.refresh_job != null) return .rejected;
        const management = if (mcp.management) |*value| value else return .rejected;
        if (!mcpExpectedGenerationMatches(management, expected_generation))
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
        if (mcp.refresh_job != null) return .rejected;
        if (mcpServerMutationBusy(mcp, input.server_id)) return .rejected;
        const management = if (mcp.management) |*value| value else return .rejected;
        if (!mcpExpectedGenerationMatches(management, expected_generation))
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
        if (mcp.refresh_job != null) return .rejected;
        if (mcpServerMutationBusy(mcp, input.server_id)) return .rejected;
        const management = if (mcp.management) |*value| value else return .rejected;
        if (!mcpExpectedGenerationMatches(management, expected_generation))
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
        if (mcp.refresh_job != null) return .rejected;
        if (mcpServerMutationBusy(mcp, input.server_id)) return .rejected;
        const management = if (mcp.management) |*value| value else return .rejected;
        if (!mcpExpectedGenerationMatches(management, expected_generation))
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
        if (mcp.refresh_job != null) return .rejected;
        if (mcpServerMutationBusy(mcp, input.server_id)) return .rejected;
        const management = if (mcp.management) |*value| value else return .rejected;
        if (!mcpExpectedGenerationMatches(management, expected_generation))
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
        if (mcp.refresh_job != null) return .rejected;
        if (mcpServerMutationBusy(mcp, input.server_id)) return .rejected;
        const management = if (mcp.management) |*value| value else return .rejected;
        if (!mcpExpectedGenerationMatches(management, expected_generation))
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
        if (mcp.refresh_job != null) return .rejected;
        if (mcpServerMutationBusy(mcp, input.server_id)) return .rejected;
        const management = if (mcp.management) |*value| value else return .rejected;
        if (!mcpExpectedGenerationMatches(management, expected_generation))
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
        if (mcp.refresh_job != null) return .rejected;
        if (mcpServerMutationBusy(mcp, input.server_id)) return .rejected;
        const management = if (mcp.management) |*value| value else return .rejected;
        if (!mcpExpectedGenerationMatches(management, expected_generation))
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
        if (mcp.refresh_job != null) return .rejected;
        if (mcpServerMutationBusy(mcp, input.server_id)) return .rejected;
        const management = if (mcp.management) |*value| value else return .rejected;
        if (!mcpExpectedGenerationMatches(management, expected_generation))
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
        if (mcp.refresh_job != null) return .rejected;
        if (mcpServerMutationBusy(mcp, input.server_id)) return .rejected;
        const management = if (mcp.management) |*value| value else return .rejected;
        if (!mcpExpectedGenerationMatches(management, expected_generation))
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
        if (mcp.refresh_job != null) return .rejected;
        if (mcpServerMutationBusy(mcp, server_id)) return .rejected;
        const management = if (mcp.management) |*value| value else return .rejected;
        if (!mcpExpectedGenerationMatches(management, expected_generation))
            return .stale_generation;
        var preparation = try management.prepareRemoveServer(expected_generation, server_id);
        return try self.commitMcpMutation(mcp, &preparation);
    }

    fn commitMcpMutation(
        self: *Workbench,
        mcp: *McpProductState,
        preparation: *mcp_configuration.MutationPreparation,
    ) Error!mcp_configuration.ManagementOutcome {
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
                        self.installMcpCommittedDesiredState(mcp, management, candidate);
                        mcp.connection_test = null;
                        candidate_owned = false;
                        changed = true;
                    },
                    .indeterminate => {
                        mcp.connection_test = null;
                        self.blockMcpAdmission(mcp, .persistence_outcome_unknown);
                        changed = true;
                    },
                    .rejected => if (management.inspect().health != .ready) {
                        self.blockMcpAdmissionForCurrentState(mcp);
                        changed = true;
                    },
                    .unchanged, .stale_generation => unreachable,
                }
                if (changed) self.bumpRevision();
                return reported_outcome;
            },
        }
    }

    fn mcpExpectedGenerationMatches(
        management: *const mcp_configuration.ManagementPort,
        expected_generation: u64,
    ) bool {
        const inspection = management.inspect();
        if (inspection.health == .outcome_unknown) return true;
        if (inspection.desired_generation) |generation|
            return expected_generation == generation;
        if (inspection.health == .ready) return expected_generation == 0;
        return true;
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
                        .tools = mcpServerToolsForAdmission(target, desired),
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

    fn replaceMcpAdmission(
        self: *Workbench,
        mcp: *McpProductState,
        replacement: McpAdmissionAuthority,
    ) void {
        _ = self;
        var installed = replacement;
        if (mcp.runtime_auth_failure_blocked and installed == .ready) {
            installed.deinit();
            installed = .{ .blocked = .runtime_authorization_failure };
        }
        mcp.admission.deinit();
        mcp.admission = installed;
    }

    fn installMcpCommittedDesiredState(
        self: *Workbench,
        mcp: *McpProductState,
        management: *const mcp_configuration.ManagementPort,
        admission: McpAdmissionAuthority,
    ) void {
        reconcileMcpPendingReauthorizations(
            mcp,
            management.desiredRegistry() orelse unreachable,
        );
        self.replaceMcpAdmission(mcp, admission);
    }

    fn blockMcpAdmission(
        self: *Workbench,
        mcp: *McpProductState,
        reason: McpAdmissionBlockReason,
    ) void {
        self.replaceMcpAdmission(mcp, .{ .blocked = reason });
    }

    fn mcpSelectionForNewTask(self: *const Workbench) ?*const lifecycle.McpSelection {
        const mcp = if (self.mcp) |*value| value else return null;
        if (!mcp.committed) return null;
        return switch (mcp.admission) {
            .ready => |ready| ready.selection,
            .blocked => null,
        };
    }

    fn createRecoveryMcpAuthority(self: *Workbench) Error!RecoveryMcpAuthority {
        const mcp = if (self.mcp) |*value| value else return .{
            .selection = null,
            .catalog_generation = null,
        };
        if (!mcp.committed or mcp.refresh_job != null or
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
                .tools = mcpServerToolsForAdmission(registry, desired),
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

    fn recoveryMcpGeneration(self: *const Workbench) ?u64 {
        const mcp = if (self.mcp) |*value| value else return null;
        if (!mcp.committed or mcp.refresh_job != null or
            mcp.authorization_operation != null or
            mcp.runtime_auth_failure_blocked)
            return null;
        return switch (mcp.admission) {
            .ready => |ready| ready.catalog_generation,
            .blocked => null,
        };
    }

    fn mcpAvailability(self: *const Workbench) McpAvailability {
        const mcp = if (self.mcp) |*value| value else return .unavailable;
        if (!mcp.committed) return .unavailable;
        switch (mcp.preparation.state) {
            .empty => return .ready,
            .available => {},
            .unavailable => return .unavailable,
        }
        const registry = mcp.preparation.registry orelse return .unavailable;
        for (registry.value.servers, mcp.preparation.server_states) |server, state| {
            const status = self.mcpRuntimeServerStatus(mcp, server.id, state);
            if (status == .needs_authentication or status == .@"unreachable" or
                status == .invalid_catalog)
                return .degraded;
        }
        return .ready;
    }

    fn mcpRuntimeServerStatus(
        self: *const Workbench,
        mcp: *const McpProductState,
        server_id: []const u8,
        preparation: mcp_configuration.ServerPreparationState,
    ) McpRuntimeStatus {
        _ = self;
        return switch (preparation) {
            .disabled => .disabled,
            .unapproved, .needs_authentication, .reauth_required => .needs_authentication,
            .invalid_catalog => .invalid_catalog,
            .eligible => status: {
                if (mcp.activation_failed) break :status .@"unreachable";
                const activation = mcp.activation orelse break :status .@"unreachable";
                for (activation.serverHealth()) |health| {
                    if (!std.mem.eql(u8, health.id, server_id)) continue;
                    break :status switch (health.state) {
                        .ready => .ready,
                        .degraded => .invalid_catalog,
                        .unavailable => .@"unreachable",
                    };
                }
                break :status .@"unreachable";
            },
        };
    }

    fn mcpDesiredServerRuntimeStatus(
        self: *const Workbench,
        mcp: *const McpProductState,
        server_id: []const u8,
    ) McpRuntimeStatus {
        const startup = mcp.preparation.registry orelse return .not_loaded;
        for (startup.value.servers, mcp.preparation.server_states) |server, state|
            if (std.mem.eql(u8, server.id, server_id))
                return self.mcpRuntimeServerStatus(mcp, server_id, state);
        return .not_loaded;
    }

    fn mcpToolSelectedForNewTask(
        mcp: *const McpProductState,
        server_id: []const u8,
        tool_name: []const u8,
    ) bool {
        const ready = switch (mcp.admission) {
            .ready => |value| value,
            .blocked => return false,
        };
        const selection = ready.selection orelse return false;
        for (selection.selectedTools()) |tool|
            if (std.mem.eql(u8, tool.server_id, server_id) and
                std.mem.eql(u8, tool.name, tool_name)) return true;
        return false;
    }

    fn mcpServerHasNewTaskAccess(
        mcp: *const McpProductState,
        server_id: []const u8,
    ) bool {
        const ready = switch (mcp.admission) {
            .ready => |value| value,
            .blocked => return false,
        };
        const selection = ready.selection orelse return false;
        for (selection.selectedTools()) |tool|
            if (std.mem.eql(u8, tool.server_id, server_id)) return true;
        return false;
    }

    fn mcpNewTaskAccess(
        mcp: *const McpProductState,
        server_id: []const u8,
    ) []const u8 {
        return switch (mcp.admission) {
            .ready => if (mcpServerHasNewTaskAccess(mcp, server_id))
                "available"
            else
                "not_allowed",
            .blocked => |reason| switch (reason) {
                .pending_restart => "restart_required",
                else => "unavailable",
            },
        };
    }

    fn desiredAllowsTool(server: mcp_configuration.ServerWire, name: []const u8) bool {
        for (server.tools) |tool| if (std.mem.eql(u8, tool, name)) return true;
        return false;
    }

    fn mcpToolAlreadyPublished(
        tools: []const []const u8,
        index: usize,
    ) bool {
        for (tools[0..index]) |previous|
            if (std.mem.eql(u8, previous, tools[index])) return true;
        return false;
    }

    fn activationServerForId(
        activation: *const lifecycle.McpActivation,
        server_id: []const u8,
    ) ?lifecycle.McpActivationServer {
        for (activation.serverHealth()) |server|
            if (std.mem.eql(u8, server.id, server_id)) return server;
        return null;
    }

    fn mcpConnectionContainsKnownCredential(
        self: *const Workbench,
        server: mcp_configuration.ServerWire,
    ) bool {
        if (server.transport.command) |command|
            if (self.containsKnownCredential(command)) return true;
        for (server.transport.arguments) |argument|
            if (argument.literal) |literal|
                if (self.containsKnownCredential(literal)) return true;
        if (server.transport.cwd) |cwd|
            if (self.containsKnownCredential(cwd)) return true;
        for (server.transport.environment) |slot|
            if (self.containsKnownCredential(slot.name)) return true;
        if (server.transport.url) |url|
            if (self.containsKnownCredential(url)) return true;
        for (server.transport.headers) |slot|
            if (self.containsKnownCredential(slot.name)) return true;
        if (server.auth.oauth) |oauth|
            if (oauth.registration.client_id) |client_id|
                if (self.containsKnownCredential(client_id)) return true;
        return false;
    }

    fn mcpProjectionRedacted(
        self: *const Workbench,
        mcp: *const McpProductState,
        registry: ?mcp_configuration.RegistryWire,
    ) bool {
        const desired = registry orelse return false;
        for (desired.servers) |server| {
            if (!mcp_configuration.publishableProductText(server.display_name) or
                self.containsKnownCredential(server.id) or
                self.containsKnownCredential(server.namespace) or
                self.containsKnownCredential(server.display_name)) return true;
            if (self.mcpConnectionContainsKnownCredential(server)) return true;
            for (server.tools) |tool|
                if (!mcp_configuration.publishableProductText(tool) or
                    self.containsKnownCredential(tool)) return true;
            const activation_server = if (mcp.activation) |activation|
                activationServerForId(activation, server.id)
            else
                null;
            if (mcp.activation) |activation| if (activation_server) |bound|
                for (activation.catalogTools()) |tool|
                    if (std.mem.eql(u8, &tool.binding_identity, &bound.binding_identity) and
                        (!mcp_configuration.publishableProductText(tool.name) or
                            self.containsKnownCredential(tool.name))) return true;
        }
        return false;
    }

    fn mcpSecretSlotReady(
        management: *const mcp_configuration.ManagementPort,
        slot: mcp_configuration.SecretSlotWire,
    ) bool {
        const locator = slot.credential_ref orelse return false;
        return management.credentialPresence(locator) == .present;
    }

    fn mcpStaticSecretsReady(
        management: *const mcp_configuration.ManagementPort,
        server: mcp_configuration.ServerWire,
    ) bool {
        const slots = if (std.mem.eql(u8, server.transport.kind, "stdio"))
            server.transport.environment
        else
            server.transport.headers;
        if (slots.len == 0) return false;
        for (slots) |slot| if (!mcpSecretSlotReady(management, slot)) return false;
        return true;
    }

    fn mcpAuthorizationStatus(
        mcp: *const McpProductState,
        management: *const mcp_configuration.ManagementPort,
        server: mcp_configuration.ServerWire,
    ) []const u8 {
        if (std.mem.eql(u8, server.auth.kind, "none")) return "not_required";
        if (std.mem.eql(u8, server.auth.kind, "static")) {
            if (mcpStaticSecretsReady(management, server)) return "ready";
            return if (mcp.host_capabilities.secret_capture)
                "missing_static_secret"
            else
                "capability_unavailable";
        }
        if (mcpAuthorizationAt(mcp, server.id, &.{
            .discovering,
            .awaiting_consent,
            .registering,
            .awaiting_browser,
            .exchanging,
            .cancelling,
        })) return "authorizing";
        const oauth = server.auth.oauth orelse return "capability_unavailable";
        if (std.mem.eql(u8, oauth.status, "ready") and oauth.grant != null)
            return "ready";
        if (std.mem.eql(u8, oauth.status, "reauth_required"))
            return "reauth_required";
        if (std.mem.eql(u8, oauth.registration.kind, "pre_registered")) {
            const method = oauth.registration.token_endpoint_auth_method orelse
                return "capability_unavailable";
            if (!std.mem.eql(u8, method, "none")) {
                const locator = oauth.registration.client_secret_ref orelse
                    return if (mcp.host_capabilities.secret_capture)
                        "missing_oauth_client_secret"
                    else
                        "capability_unavailable";
                if (management.credentialPresence(locator) != .present)
                    return if (mcp.host_capabilities.secret_capture)
                        "missing_oauth_client_secret"
                    else
                        "capability_unavailable";
            }
        }
        if (!mcp.host_capabilities.oauth) return "capability_unavailable";
        if (std.mem.eql(u8, oauth.status, "client_registration_required"))
            return "client_registration_required";
        return "consent_required";
    }

    fn writeMcpSecretSlots(
        self: *Workbench,
        writer: *std.Io.Writer,
        management: *const mcp_configuration.ManagementPort,
        slots: []const mcp_configuration.SecretSlotWire,
    ) Error!void {
        writer.writeByte('[') catch return error.SnapshotTooLarge;
        for (slots, 0..) |slot, index| {
            if (index != 0) writer.writeByte(',') catch return error.SnapshotTooLarge;
            writer.writeAll("{\"name\":") catch return error.SnapshotTooLarge;
            try self.projectedJsonValueWithKnownCredentials(writer, slot.name);
            writer.print(",\"status\":\"{s}\"}}", .{
                if (mcpSecretSlotReady(management, slot)) "set" else "missing",
            }) catch return error.SnapshotTooLarge;
        }
        writer.writeByte(']') catch return error.SnapshotTooLarge;
    }

    fn writeMcpConnection(
        self: *Workbench,
        writer: *std.Io.Writer,
        management: *const mcp_configuration.ManagementPort,
        server: mcp_configuration.ServerWire,
        connection_safe: bool,
        projected_auth_mode: []const u8,
    ) Error!void {
        if (!connection_safe) {
            writer.writeAll("null") catch return error.SnapshotTooLarge;
            return;
        }
        if (!std.mem.eql(u8, server.transport.kind, "streamable_http")) {
            writer.writeAll("{\"kind\":\"stdio\",\"command\":") catch
                return error.SnapshotTooLarge;
            try self.projectedJsonValueWithKnownCredentials(
                writer,
                server.transport.command orelse "",
            );
            writer.writeAll(",\"arguments\":[") catch return error.SnapshotTooLarge;
            for (server.transport.arguments, 0..) |argument, index| {
                if (index != 0) writer.writeByte(',') catch return error.SnapshotTooLarge;
                try self.projectedJsonValueWithKnownCredentials(
                    writer,
                    argument.literal orelse "",
                );
            }
            writer.writeAll("],\"cwd\":") catch return error.SnapshotTooLarge;
            if (server.transport.cwd) |cwd|
                try self.projectedJsonValueWithKnownCredentials(writer, cwd)
            else
                writer.writeAll("null") catch return error.SnapshotTooLarge;
            writer.writeAll(",\"environment\":") catch return error.SnapshotTooLarge;
            try self.writeMcpSecretSlots(
                writer,
                management,
                server.transport.environment,
            );
            writer.writeByte('}') catch return error.SnapshotTooLarge;
            return;
        }
        writer.writeAll("{\"kind\":\"streamable_http\",\"endpoint\":") catch
            return error.SnapshotTooLarge;
        try self.projectedJsonValueWithKnownCredentials(
            writer,
            server.transport.url orelse "",
        );
        writer.writeAll(",\"headers\":") catch return error.SnapshotTooLarge;
        try self.writeMcpSecretSlots(writer, management, server.transport.headers);
        const oauth = if (std.mem.eql(u8, projected_auth_mode, "oauth"))
            server.auth.oauth
        else
            null;
        writer.print(",\"registrationKind\":\"{s}\",\"clientId\":", .{
            if (oauth) |value| if (std.mem.eql(u8, value.registration.kind, "dynamic_registration"))
                "automatic"
            else
                "pre_registered" else "none",
        }) catch return error.SnapshotTooLarge;
        if (oauth) |value| {
            if (std.mem.eql(u8, value.registration.kind, "pre_registered"))
                try self.projectedJsonValueWithKnownCredentials(
                    writer,
                    value.registration.client_id orelse "",
                )
            else
                writer.writeAll("null") catch return error.SnapshotTooLarge;
        } else writer.writeAll("null") catch return error.SnapshotTooLarge;
        writer.writeAll(",\"tokenEndpointAuthMethod\":") catch
            return error.SnapshotTooLarge;
        if (oauth) |value| if (value.registration.token_endpoint_auth_method) |method|
            try self.projectedJsonValueWithKnownCredentials(writer, method)
        else
            writer.writeAll("null") catch return error.SnapshotTooLarge else writer.writeAll("null") catch return error.SnapshotTooLarge;
        writer.print(",\"clientSecretStatus\":\"{s}\"}}", .{
            if (oauth) |value| if (value.registration.token_endpoint_auth_method) |method|
                if (std.mem.eql(u8, method, "none"))
                    "not_required"
                else if (value.registration.client_secret_ref) |locator|
                    if (management.credentialPresence(locator) == .present) "set" else "missing"
                else
                    "missing"
            else
                "not_required" else "not_required",
        }) catch return error.SnapshotTooLarge;
    }

    fn writeMcpAuthorizationOperation(
        writer: *std.Io.Writer,
        mcp: *const McpProductState,
        registry: ?mcp_configuration.RegistryWire,
    ) Error!void {
        if (mcp.authorization_operation) |operation| {
            writer.print("{{\"kind\":\"{s}\",\"serverId\":", .{@tagName(operation.phase)}) catch
                return error.SnapshotTooLarge;
            std.json.Stringify.value(operation.server_id, .{}, writer) catch
                return error.SnapshotTooLarge;
            writer.writeAll(",\"operationId\":") catch return error.SnapshotTooLarge;
            std.json.Stringify.value(operation.operation_id, .{}, writer) catch
                return error.SnapshotTooLarge;
            writer.writeByte('}') catch return error.SnapshotTooLarge;
            return;
        }
        if (registry) |desired| if (desired.oauth_operation) |operation| {
            const phase = if (std.mem.eql(u8, operation.kind, "refresh"))
                "refreshing"
            else if (std.mem.eql(u8, operation.kind, "dynamic_registration"))
                "registering"
            else
                "exchanging";
            writer.print("{{\"kind\":\"{s}\",\"serverId\":", .{phase}) catch
                return error.SnapshotTooLarge;
            std.json.Stringify.value(operation.server_id, .{}, writer) catch
                return error.SnapshotTooLarge;
            writer.writeAll(",\"operationId\":") catch return error.SnapshotTooLarge;
            std.json.Stringify.value(operation.id, .{}, writer) catch
                return error.SnapshotTooLarge;
            writer.writeByte('}') catch return error.SnapshotTooLarge;
            return;
        };
        writer.writeAll("{\"kind\":\"idle\"}") catch return error.SnapshotTooLarge;
    }

    fn writeMcpTool(
        self: *Workbench,
        writer: *std.Io.Writer,
        mcp: *const McpProductState,
        server: mcp_configuration.ServerWire,
        name: []const u8,
        discovered: bool,
    ) Error!void {
        writer.writeAll("{\"name\":") catch return error.SnapshotTooLarge;
        try self.projectedJsonValueWithKnownCredentials(writer, name);
        writer.print(",\"discovered\":{},\"desiredAllowed\":{},\"availableToNewTasks\":{}}}", .{
            discovered,
            desiredAllowsTool(server, name),
            mcpToolSelectedForNewTask(mcp, server.id, name),
        }) catch return error.SnapshotTooLarge;
    }

    fn writeMcpProjection(
        self: *Workbench,
        writer: *std.Io.Writer,
    ) Error!void {
        const mcp = if (self.mcp) |*value| value else {
            writer.writeAll("{\"availability\":\"unavailable\",\"managementHealth\":\"unavailable\",\"operation\":\"idle\",\"authorizationOperation\":{\"kind\":\"idle\"},\"desiredGeneration\":null,\"runtimeAlignment\":\"unknown\",\"redacted\":false,\"servers\":[]}") catch
                return error.SnapshotTooLarge;
            return;
        };
        const management = if (mcp.management) |*value| value else {
            writer.writeAll("{\"availability\":\"unavailable\",\"managementHealth\":\"unavailable\",\"operation\":\"idle\",\"authorizationOperation\":{\"kind\":\"idle\"},\"desiredGeneration\":null,\"runtimeAlignment\":\"unknown\",\"redacted\":false,\"servers\":[]}") catch
                return error.SnapshotTooLarge;
            return;
        };
        const inspection = management.inspect();
        const trusted = inspection.health != .outcome_unknown and
            (inspection.desired_generation != null or inspection.health == .ready);
        const registry = if (trusted) management.desiredRegistry() else null;
        const projection_redacted = self.mcpProjectionRedacted(mcp, registry);
        writer.print("{{\"availability\":\"{s}\",\"managementHealth\":\"{s}\",\"operation\":\"{s}\",\"authorizationOperation\":", .{
            @tagName(self.mcpAvailability()),
            @tagName(inspection.health),
            if (mcp.refresh_job != null) "refreshing" else "idle",
        }) catch return error.SnapshotTooLarge;
        try writeMcpAuthorizationOperation(writer, mcp, registry);
        writer.writeAll(",\"desiredGeneration\":") catch return error.SnapshotTooLarge;
        if (trusted) writer.print("\"{d}\"", .{inspection.desired_generation orelse 0}) catch
            return error.SnapshotTooLarge else writer.writeAll("null") catch return error.SnapshotTooLarge;
        writer.print(",\"runtimeAlignment\":\"{s}\",\"redacted\":{},\"servers\":[", .{
            if (trusted) @tagName(inspection.runtime_alignment) else "unknown",
            projection_redacted,
        }) catch return error.SnapshotTooLarge;
        const servers = if (registry) |value| value.servers else &.{};
        for (servers, 0..) |server, index| {
            if (index != 0) writer.writeByte(',') catch return error.SnapshotTooLarge;
            const status = self.mcpDesiredServerRuntimeStatus(mcp, server.id);
            const problem = mcp_configuration.serverProblem(server, management.limits);
            const connection_safe = !self.mcpConnectionContainsKnownCredential(server) and
                (problem == null or problem.? == .invalid_connection_approval);
            const projected_auth_mode = if (connection_safe and
                (std.mem.eql(u8, server.auth.kind, "none") or
                    std.mem.eql(u8, server.auth.kind, "static") or
                    (std.mem.eql(u8, server.auth.kind, "oauth") and
                        std.mem.eql(u8, server.transport.kind, "streamable_http"))))
                server.auth.kind
            else
                "none";
            writer.writeAll("{\"id\":") catch return error.SnapshotTooLarge;
            try self.projectedJsonValueWithKnownCredentials(writer, server.id);
            writer.writeAll(",\"displayName\":") catch return error.SnapshotTooLarge;
            try self.projectedJsonValueWithKnownCredentials(
                writer,
                if (mcp_configuration.publishableProductText(server.display_name))
                    server.display_name
                else
                    server.id,
            );
            writer.writeAll(",\"namespace\":") catch return error.SnapshotTooLarge;
            try self.projectedJsonValueWithKnownCredentials(writer, server.namespace);
            writer.print(",\"transport\":\"{s}\",\"authMode\":\"{s}\",\"negotiation\":\"{s}\",\"timeoutMs\":{d},\"connection\":", .{
                if (std.mem.eql(u8, server.transport.kind, "streamable_http"))
                    "streamable_http"
                else
                    "stdio",
                projected_auth_mode,
                if (connection_safe) server.negotiation else "automatic",
                if (connection_safe) server.timeout_ms else 1,
            }) catch return error.SnapshotTooLarge;
            try self.writeMcpConnection(
                writer,
                management,
                server,
                connection_safe,
                projected_auth_mode,
            );
            writer.print(",\"approvalStatus\":\"{s}\",\"authorizationStatus\":\"{s}\",\"desiredEnabled\":{},\"runtimeStatus\":\"{s}\",\"newTaskAccess\":\"{s}\",\"safeDiagnostic\":", .{
                if (!connection_safe or server.connection_approval == null)
                    "unapproved"
                else
                    "approved",
                if (connection_safe)
                    mcpAuthorizationStatus(mcp, management, server)
                else
                    "not_required",
                server.enabled,
                @tagName(status),
                mcpNewTaskAccess(mcp, server.id),
            }) catch return error.SnapshotTooLarge;
            try self.projectedJsonValueWithKnownCredentials(writer, switch (status) {
                .not_loaded, .ready, .disabled => "",
                .needs_authentication => "Credential is unavailable",
                .@"unreachable" => "Server is unavailable",
                .invalid_catalog => "Configuration or catalog is invalid",
            });
            const connection_test = if (mcp.connection_test) |test_state|
                if (std.mem.eql(u8, test_state.serverId(), server.id)) test_state else null
            else
                null;
            if (connection_test) |test_state|
                writer.print(",\"connectionTest\":{{\"status\":\"{s}\",\"toolCount\":{d},\"issueCount\":{d}}}", .{
                    @tagName(test_state.state),
                    test_state.tool_count,
                    test_state.issue_count,
                }) catch return error.SnapshotTooLarge
            else
                writer.writeAll(",\"connectionTest\":{\"status\":\"untested\",\"toolCount\":0,\"issueCount\":0}") catch
                    return error.SnapshotTooLarge;
            writer.writeAll(",\"tools\":[") catch return error.SnapshotTooLarge;
            var tool_count: usize = 0;
            const activation_server = if (mcp.activation) |activation|
                activationServerForId(activation, server.id)
            else
                null;
            for (server.tools, 0..) |tool, desired_index| {
                if (!mcp_configuration.publishableProductText(tool) or
                    mcpToolAlreadyPublished(server.tools, desired_index)) continue;
                if (tool_count != 0) writer.writeByte(',') catch return error.SnapshotTooLarge;
                tool_count += 1;
                var discovered = false;
                if (mcp.activation) |activation| if (activation_server) |bound|
                    for (activation.catalogTools()) |catalog_tool|
                        if (std.mem.eql(u8, &catalog_tool.binding_identity, &bound.binding_identity) and
                            std.mem.eql(u8, catalog_tool.name, tool))
                        {
                            discovered = true;
                            break;
                        };
                try self.writeMcpTool(writer, mcp, server, tool, discovered);
            }
            if (mcp.activation) |activation| if (activation_server) |bound|
                for (activation.catalogTools()) |tool| {
                    if (!std.mem.eql(u8, &tool.binding_identity, &bound.binding_identity) or
                        !mcp_configuration.publishableProductText(tool.name) or
                        desiredAllowsTool(server, tool.name)) continue;
                    if (tool_count != 0) writer.writeByte(',') catch return error.SnapshotTooLarge;
                    tool_count += 1;
                    try self.writeMcpTool(writer, mcp, server, tool.name, true);
                };
            writer.writeAll("]}") catch return error.SnapshotTooLarge;
        }
        writer.writeAll("]}") catch return error.SnapshotTooLarge;
    }

    /// Commits the final assistant suffix only after Workbench has drained the
    /// Agent event pump following `markTerminalRunsBeforeEventDrain`.
    /// Any later event for the Run is rejected by `applyEvent`.
    pub fn finalizeMarkedTerminalRunsAfterEventDrain(self: *Workbench) void {
        var changed = false;
        for (self.tasks) |*task_entry| {
            const task = &(task_entry.* orelse continue);
            for (task.durable.runs) |*run_entry| {
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
        const task_persistence_ready = taskPersistenceOperational(self.task_persistence_health);
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
                self.skill_catalog_availability,
                if (self.skill_catalog) |*snapshot| snapshot else null,
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
            if (task.runtime.close_thread) |thread| thread.join();
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
            self.blockMcpAdmission(mcp, .shutting_down);
            if (mcp.activation) |activation| activation.deinit();
            mcp.activation = null;
            mcp.activation_failed = true;
        }
        self.schedule_timer.cancelCurrent();
        for (self.tasks) |*entry| {
            const view = &(entry.* orelse continue);
            cancelTaskCheckpoints(view);
            if (view.runtime.worker_references.load(.acquire) == 0) continue;
            if (view.runtime.active_operation == .restore) {
                const job = view.runtime.restore_job orelse continue;
                job.requestCancellation();
                _ = self.executor.cancel(job);
                continue;
            }
            const session = view.runtime.session() orelse continue;
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

    fn settleCheckpointTransactionsForShutdown(self: *Workbench) void {
        for (self.tasks) |*entry| {
            const task = &(entry.* orelse continue);
            for (task.durable.runs) |*run_entry| {
                const run = &(run_entry.* orelse continue);
                self.settleCheckpointPostprocessForShutdown(&run.checkpoint);
                if (run.worker_reference_held.load(.acquire))
                    releaseWorkerReference(run);
            }
            for (task.durable.compacts) |*compact_entry| {
                const compact = &(compact_entry.* orelse continue);
                self.settleCheckpointPostprocessForShutdown(&compact.checkpoint);
                releaseCompactReferences(compact);
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

    fn writeTask(self: *Workbench, writer: *std.Io.Writer, view: *TaskView) Error!void {
        writer.print("{{\"id\":\"{d}\",\"recentOrder\":\"{d}\",\"title\":", .{
            view.durable.id,
            view.durable.recent_order,
        }) catch return error.SnapshotTooLarge;
        try self.projectedJsonValueWithKnownCredentials(writer, view.durable.title);
        writer.print(",\"workspaceId\":\"{d}\",\"binding\":{{\"epoch\":\"{d}\",\"availability\":\"{s}\",\"provider\":\"{s}\",\"model\":", .{
            view.durable.workspace_id,
            view.durable.binding_epoch,
            if (view.runtime.executionConst() == null) "unavailable" else "available",
            @tagName(view.durable.execution_provider),
        }) catch return error.SnapshotTooLarge;
        try self.projectedJsonValueWithKnownCredentials(writer, view.durable.execution_model);
        writer.print(",\"executionGeneration\":\"{d}\",\"unavailableReason\":", .{view.durable.execution_generation}) catch
            return error.SnapshotTooLarge;
        if (view.runtime.executionConst() == null)
            writer.writeAll("\"runtime_detached\"") catch return error.SnapshotTooLarge
        else
            writer.writeAll("null") catch return error.SnapshotTooLarge;
        writer.writeByte('}') catch return error.SnapshotTooLarge;
        writer.writeAll(",\"skillCatalog\":") catch
            return error.SnapshotTooLarge;
        try self.writeCatalogProjection(
            writer,
            taskCatalogProjection(view),
        );
        const recovery = self.taskRecoveryProjection(view);
        writer.print(",\"lifecycle\":\"{s}\",\"continuationAvailable\":{},\"continuationUnavailableReason\":", .{
            @tagName(taskLifecycle(view)),
            !self.shutting_down and taskLifecycle(view) == .open and
                continuationAvailable(recovery.continuation),
        }) catch return error.SnapshotTooLarge;
        switch (recovery.continuation) {
            .available => writer.writeAll("null") catch return error.SnapshotTooLarge,
            .unavailable => |reason| jsonValue(writer, @tagName(reason)) catch
                return error.SnapshotTooLarge,
        }
        writer.print(",\"continuationRecoveryAvailable\":{},\"archived\":{},\"closeFailed\":{}", .{
            recovery.recovery_available,
            view.durable.archived,
            view.runtime.close_failed,
        }) catch return error.SnapshotTooLarge;
        writer.writeAll(",\"restorePermission\":") catch return error.SnapshotTooLarge;
        if (view.runtime.last_restore_permission) |summary| {
            writer.print("{{\"restoredRules\":\"{d}\",\"invalidatedRules\":\"{d}\"}}", .{
                summary.restored_rules,
                summary.invalidated_rules,
            }) catch return error.SnapshotTooLarge;
        } else writer.writeAll("null") catch return error.SnapshotTooLarge;
        writer.writeAll(",\"activeOperation\":") catch return error.SnapshotTooLarge;
        switch (view.runtime.active_operation) {
            .none => writer.writeAll("null") catch return error.SnapshotTooLarge,
            .run => |id| writer.print("{{\"kind\":\"run\",\"id\":\"{d}\"}}", .{id}) catch
                return error.SnapshotTooLarge,
            .compact => |id| writer.print("{{\"kind\":\"compact\",\"id\":\"{d}\"}}", .{id}) catch
                return error.SnapshotTooLarge,
            .restore => |attempt| writer.print(
                "{{\"kind\":\"restore\",\"id\":\"{d}\"}}",
                .{attempt.id},
            ) catch return error.SnapshotTooLarge,
        }
        writer.print(",\"currentRunId\":\"{d}\",\"currentRunPhase\":", .{
            if (currentRunPhase(view) == null) 0 else view.runtime.active_run_id,
        }) catch return error.SnapshotTooLarge;
        if (currentRunPhase(view)) |phase| jsonValue(writer, @tagName(phase)) catch return error.SnapshotTooLarge else writer.writeAll("null") catch return error.SnapshotTooLarge;
        const last_terminal = lastTerminalFacts(view.durable.runs);
        writer.writeAll(",\"lastRunOutcome\":") catch return error.SnapshotTooLarge;
        if (last_terminal) |terminal| jsonValue(writer, @tagName(terminal.outcome)) catch return error.SnapshotTooLarge else writer.writeAll("null") catch return error.SnapshotTooLarge;
        writer.writeAll(",\"cause\":") catch return error.SnapshotTooLarge;
        if (last_terminal) |terminal| {
            if (terminal.cause) |cause| jsonValue(writer, @tagName(cause)) catch return error.SnapshotTooLarge else writer.writeAll("null") catch return error.SnapshotTooLarge;
        } else writer.writeAll("null") catch return error.SnapshotTooLarge;
        writer.writeAll(",\"runs\":[") catch return error.SnapshotTooLarge;
        var run_count: usize = 0;
        for (view.durable.runs) |*entry| {
            const run = &(entry.* orelse continue);
            if (run_count != 0) writer.writeByte(',') catch return error.SnapshotTooLarge;
            run_count += 1;
            try self.writeRun(writer, run);
        }
        writer.writeAll("],\"compacts\":[") catch return error.SnapshotTooLarge;
        var compact_count: usize = 0;
        for (view.durable.compacts) |*entry| {
            const compact = &(entry.* orelse continue);
            if (compact_count != 0) writer.writeByte(',') catch
                return error.SnapshotTooLarge;
            compact_count += 1;
            try self.writeCompact(writer, compact);
        }
        writer.writeAll("],\"pendingUi\":") catch return error.SnapshotTooLarge;
        try self.writePendingUi(writer, view);
        writer.writeAll(",\"uiHistory\":[") catch return error.SnapshotTooLarge;
        try self.writeUiHistory(writer, view);
        writer.writeByte(']') catch return error.SnapshotTooLarge;
        writer.writeByte('}') catch return error.SnapshotTooLarge;
    }

    fn writeCompact(
        self: *Workbench,
        writer: *std.Io.Writer,
        compact: *const CompactRecord,
    ) Error!void {
        _ = self;
        const terminal = compactTerminalPayload(compact);
        const phase = if (terminal) |payload|
            payload.phase
        else
            activeCompactPhase(compact);
        writer.print(
            "{{\"operationId\":\"{d}\",\"afterRunId\":\"{d}\",\"phase\":\"{s}\",\"cause\":",
            .{ compact.id, compact.after_run_id, @tagName(phase) },
        ) catch return error.SnapshotTooLarge;
        if (if (terminal) |payload| payload.cause else null) |cause|
            jsonValue(writer, @tagName(cause)) catch return error.SnapshotTooLarge
        else
            writer.writeAll("null") catch return error.SnapshotTooLarge;
        const before_context_tokens = if (terminal) |payload|
            payload.before_context_tokens
        else
            0;
        const after_context_tokens = if (terminal) |payload|
            payload.after_context_tokens
        else
            0;
        const usage = if (terminal) |payload| payload.usage else UsageView{};
        writer.print(
            ",\"beforeContextTokens\":\"{d}\",\"afterContextTokens\":\"{d}\",\"usage\":{{\"input\":\"{d}\",\"output\":\"{d}\",\"cacheRead\":\"{d}\",\"cacheCreation\":\"{d}\"}}}}",
            .{
                before_context_tokens,
                after_context_tokens,
                usage.input_tokens,
                usage.output_tokens,
                usage.cache_read_input_tokens,
                usage.cache_creation_input_tokens,
            },
        ) catch return error.SnapshotTooLarge;
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
        writer.writeAll(",\"selectionRevision\":") catch return error.SnapshotTooLarge;
        if (catalog.selection_revision) |selection_revision|
            writer.print("\"{d}\"", .{selection_revision}) catch
                return error.SnapshotTooLarge
        else
            writer.writeAll("null") catch return error.SnapshotTooLarge;
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
            if (issue.invocation_name) |name|
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
        const catalog = if (self.skill_catalog) |*snapshot| snapshot else null;
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
            const workspace_catalog = if (workspace.catalog) |*snapshot|
                snapshot
            else
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
        writer.writeAll(",\"argumentNames\":[") catch return error.SnapshotTooLarge;
        for (argument_names, 0..) |name, index| {
            if (index != 0) writer.writeByte(',') catch
                return error.SnapshotTooLarge;
            try self.projectedJsonValueWithKnownCredentials(writer, name);
        }
        const runtime_skill = self.findCatalogSkillForScope(scope, invocation_name);
        const project_enablement = switch (scope) {
            .personal => false,
            .project => true,
        };
        const selection_revision = if (project_enablement and
            self.skill_enablement_health == .ready)
            if (self.catalogForSkillScope(scope)) |snapshot|
                snapshot.selection_revision
            else
                null
        else
            null;
        const can_set_enabled = project_enablement and
            self.skill_enablement_health == .ready and
            runtime_skill != null and selection_revision != null;
        writer.print("],\"maxValues\":{d},\"canExport\":{},\"canReimport\":{},\"canUninstall\":{},\"canRetry\":{},\"enabled\":", .{
            max_values,
            manageable,
            manageable,
            manageable or pending,
            pending,
        }) catch return error.SnapshotTooLarge;
        if (runtime_skill) |skill| {
            if (project_enablement and self.skill_enablement_health == .ready)
                writer.print("{}", .{skill.enabled}) catch return error.SnapshotTooLarge
            else
                writer.writeAll("null") catch return error.SnapshotTooLarge;
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
                const issue_name = issue.invocation_name orelse continue;
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
            .personal => if (self.skill_catalog) |*value| value else null,
            .project => |project| catalog: {
                for (self.workspaces) |*entry| {
                    const workspace = &(entry.* orelse continue);
                    if (workspace.id == project.workspace_id and
                        workspace.epoch == project.workspace_epoch)
                        break :catalog if (workspace.catalog) |*value| value else null;
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
            if (issue.invocation_name) |name|
                if (self.containsKnownCredential(name)) return true;
        return false;
    }

    fn writePendingUi(self: *Workbench, writer: *std.Io.Writer, view: *TaskView) Error!void {
        if (view.runtime.pending_ui_request_id == 0) {
            writer.writeAll("null") catch return error.SnapshotTooLarge;
            return;
        }
        const session = view.runtime.session() orelse {
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
        if (view.runtime.pending_ui_request_id != pending.request_id or view.runtime.pending_ui_order == 0) {
            writer.writeAll("null") catch return error.SnapshotTooLarge;
            return;
        }
        if (findRun(view.durable.runs, pending.run_id) == null)
            return error.InvalidUiResponse;
        try self.writePendingUiProjection(
            writer,
            pending.request_id,
            pending.run_id,
            view.runtime.pending_ui_order,
            parsed.value,
        );
    }

    fn deinitFileReference(self: *Workbench, reference: *FileReferenceView) void {
        self.freeTracked(reference.id);
        self.freeTracked(reference.title);
        self.freeTracked(reference.display_path);
        self.freeTracked(reference.kind);
        self.freeTracked(reference.locator);
        reference.* = undefined;
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
            .closed = task.durable.closed,
            .archived = task.durable.archived,
            .attachment = recoveryAttachment(task.runtime.attachment),
            .operation = recoveryOperation(task.runtime.active_operation),
            .task_persistence_ready = taskPersistenceOperational(self.task_persistence_health),
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
        if (value.catalog_availability != .ready or value.catalog_job != null or
            value.catalog == null)
            return false;
        const mcp = if (self.mcp) |*state| state else return true;
        if (!mcp.committed or mcp.refresh_job != null or
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
            .max_ui_history_per_task = self.limits.max_ui_history_per_task,
            .max_workspace_bytes = self.limits.max_workspace_bytes,
            .max_task_title_bytes = self.limits.max_task_title_bytes,
            .max_user_message_bytes = self.limits.max_user_message_bytes,
            .max_assistant_message_bytes = self.limits.max_assistant_message_bytes,
            .max_tool_field_bytes = self.limits.max_tool_field_bytes,
            .max_file_ref_field_bytes = self.limits.max_file_ref_field_bytes,
            .max_terminal_diagnostic_bytes = self.limits.max_terminal_diagnostic_bytes,
        };
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
            const restored = self.restoreTask(task) catch |err| switch (err) {
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
        const kind = parsePersistedEnum(WorkspaceKind, wire.kind) orelse
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

    fn restoreTask(self: *Workbench, wire: task_persistence.TaskWire) Error!TaskView {
        const checkpoint_anchor = parsePersistedEnum(CheckpointAnchor, wire.checkpoint_anchor) orelse
            return error.TaskStoreCorrupt;
        const checkpoint_attempt = parsePersistedEnum(CheckpointAttempt, wire.checkpoint_attempt) orelse
            return error.TaskStoreCorrupt;
        var checkpoint = if (wire.checkpoint) |value|
            try self.restoreCheckpointRecord(wire.id, value)
        else
            null;
        errdefer if (checkpoint) |*value| value.deinit(self.allocator);
        if ((checkpoint == null and checkpoint_anchor == .available) or
            (checkpoint != null and checkpoint_anchor == .none))
            return error.TaskStoreCorrupt;
        if (checkpoint) |value| {
            value.validateBinding(wire.id, wire.binding.epoch) catch
                return error.TaskStoreCorrupt;
            const terminal_found = switch (value.anchor.terminal) {
                .run => |terminal_id| blk: {
                    for (wire.runs) |run| {
                        if (run.id != terminal_id) continue;
                        // A checkpoint records the model used to create its
                        // historical Session state. Keep that fact coherent
                        // with the terminal Run, while deliberately not
                        // comparing either value with the Task's current
                        // model binding.
                        break :blk persistedTerminalRunPhase(run.phase) and
                            std.mem.eql(u8, run.execution_model, value.session.model);
                    }
                    break :blk false;
                },
                .compact => |terminal_id| blk: {
                    for (wire.compacts) |compact| if (compact.id == terminal_id)
                        break :blk persistedTerminalCompactPhase(compact.phase);
                    break :blk false;
                },
            };
            if (!terminal_found) return error.TaskStoreCorrupt;
        }
        const execution_provider = parsePersistedEnum(Provider, wire.binding.provider) orelse
            return error.TaskStoreCorrupt;
        const execution_model = try self.copyBounded(
            wire.binding.model,
            account_contract.Limits.model_id_bytes,
        );
        errdefer self.freeTracked(execution_model);
        const workspace_root = try self.copyBounded(
            wire.workspace_root,
            self.limits.max_workspace_bytes,
        );
        errdefer self.freeTracked(workspace_root);
        const title = try self.copyBounded(wire.title, self.limits.max_task_title_bytes);
        errdefer self.freeTracked(title);

        const runs = try self.allocator.alloc(?RunRecord, self.limits.max_runs_per_task);
        errdefer self.allocator.free(runs);
        @memset(runs, null);
        var restored_runs: usize = 0;
        errdefer for (runs[0..restored_runs]) |*entry| {
            const run = &(entry.* orelse continue);
            self.deinitRunRecord(run);
        };
        for (wire.runs, 0..) |run, index| {
            runs[index] = try self.restoreRun(run);
            restored_runs += 1;
        }

        const compacts = try self.allocator.alloc(
            ?CompactRecord,
            self.limits.max_compacts_per_task,
        );
        errdefer self.allocator.free(compacts);
        @memset(compacts, null);
        var restored_compacts: usize = 0;
        errdefer for (compacts[0..restored_compacts]) |*entry| {
            const compact = &(entry.* orelse continue);
            self.deinitCompactRecord(compact);
        };
        for (wire.compacts, 0..) |compact, index| {
            compacts[index] = try self.restoreCompact(compact);
            restored_compacts += 1;
        }

        const ui_history = try self.allocator.alloc(
            ?UiRecord,
            self.limits.max_ui_history_per_task,
        );
        errdefer self.allocator.free(ui_history);
        @memset(ui_history, null);
        for (wire.ui_history, 0..) |record, index|
            ui_history[index] = restoreUiRecord(record);
        return .{
            .durable = .{
                .id = wire.id,
                .recent_order = wire.recent_order,
                .execution_generation = wire.binding.execution_generation,
                .execution_provider = execution_provider,
                .execution_model = execution_model,
                .binding_epoch = wire.binding.epoch,
                .workspace_id = wire.workspace_id,
                .workspace_epoch = wire.workspace_epoch,
                .workspace_root = workspace_root,
                .title = title,
                .title_redacted = wire.title_redacted,
                .archived = wire.archived,
                .closed = wire.closed,
                .runs = runs,
                .compacts = compacts,
                .next_run_generation = wire.next_run_generation,
                .ui_history = ui_history,
                .ui_history_count = wire.ui_history.len,
                .ui_history_next = wire.ui_history.len % ui_history.len,
                .checkpoint = checkpoint,
                .checkpoint_anchor = checkpoint_anchor,
                .checkpoint_attempt = checkpoint_attempt,
            },
            .runtime = .{
                .attachment = .{ .detached = if (wire.closed) .closed else .cold_start },
            },
        };
    }

    fn restoreCheckpointRecord(
        self: *Workbench,
        task_id: u64,
        wire: task_persistence.CheckpointWire,
    ) Error!checkpoint_record.Record {
        var digest: [checkpoint_store.digest_bytes]u8 = undefined;
        if (wire.blob.digest.len != digest.len * 2) return error.TaskStoreCorrupt;
        _ = std.fmt.hexToBytes(&digest, wire.blob.digest) catch return error.TaskStoreCorrupt;
        const canonical_digest = std.fmt.bytesToHex(digest, .lower);
        if (!std.mem.eql(u8, &canonical_digest, wire.blob.digest)) return error.TaskStoreCorrupt;
        if (wire.blob.byte_size == 0 or
            wire.session.logical_session_id.len == 0 or
            wire.session.logical_session_id.len > 4096 or
            wire.session.model.len == 0 or
            wire.session.model.len > account_contract.Limits.model_id_bytes or
            wire.anchor.binding_epoch == 0 or
            wire.anchor.terminal.id == 0)
            return error.TaskStoreCorrupt;
        const logical_session_id = try self.allocator.dupe(
            u8,
            wire.session.logical_session_id,
        );
        errdefer self.allocator.free(logical_session_id);
        const model = try self.allocator.dupe(u8, wire.session.model);
        errdefer self.allocator.free(model);
        const terminal: checkpoint_record.Terminal = if (std.mem.eql(
            u8,
            wire.anchor.terminal.kind,
            "run",
        ))
            .{ .run = wire.anchor.terminal.id }
        else if (std.mem.eql(u8, wire.anchor.terminal.kind, "compact"))
            .{ .compact = wire.anchor.terminal.id }
        else
            return error.TaskStoreCorrupt;
        return .{
            .blob = .{
                .task_id = task_id,
                .generation = wire.blob.generation,
                .byte_size = wire.blob.byte_size,
                .digest = digest,
            },
            .session = .{
                .logical_session_id = logical_session_id,
                .last_run_id = wire.session.last_run_id,
                .last_compact_id = wire.session.last_compact_id,
                .model = model,
            },
            .anchor = .{
                .terminal = terminal,
                .binding_epoch = wire.anchor.binding_epoch,
            },
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

    fn restoreRun(
        self: *Workbench,
        wire: task_persistence.RunWire,
    ) Error!RunRecord {
        var input = try self.restoreRunInput(wire.input);
        errdefer self.deinitRunInputRecord(&input);
        var assistant: TrackedText = .{};
        errdefer if (assistant.list.capacity != 0) self.freeTrackedText(&assistant);
        try self.appendTrackedText(
            &assistant,
            wire.assistant,
            self.limits.max_assistant_message_bytes,
        );
        assistant.committed_len = assistant.list.items.len;
        const interrupted = !persistedTerminalRunPhase(wire.phase);
        const status_text = try self.copyBounded(
            if (interrupted) "Interrupted" else wire.status,
            self.limits.max_tool_field_bytes,
        );
        errdefer self.freeTracked(status_text);
        const diagnostic = try self.allocTrackedCapacity(
            self.limits.max_terminal_diagnostic_bytes,
        );
        errdefer self.freeTracked(diagnostic);
        @memcpy(diagnostic[0..wire.diagnostic.len], wire.diagnostic);
        const tools = try self.allocator.alloc(?ToolView, self.limits.max_tools_per_run);
        errdefer self.allocator.free(tools);
        @memset(tools, null);
        var restored_tools: usize = 0;
        errdefer for (tools[0..restored_tools]) |*entry| {
            const tool = &(entry.* orelse continue);
            self.deinitToolView(tool);
        };
        for (wire.tools) |tool| {
            if (std.mem.eql(u8, tool.state, "running"))
                continue;
            tools[restored_tools] = try self.restoreTool(tool);
            restored_tools += 1;
        }
        const phase: RunPhase = if (interrupted)
            .interrupted
        else
            parsePersistedEnum(RunPhase, wire.phase) orelse return error.TaskStoreCorrupt;
        const outcome: RunOutcome = if (interrupted)
            .interrupted
        else
            parsePersistedEnum(RunOutcome, wire.outcome orelse return error.TaskStoreCorrupt) orelse
                return error.TaskStoreCorrupt;
        const cause: ?RunCause = if (interrupted or wire.cause == null)
            null
        else
            parsePersistedEnum(RunCause, wire.cause.?) orelse return error.TaskStoreCorrupt;
        const execution_model = try self.copyBounded(
            wire.execution_model,
            account_contract.Limits.model_id_bytes,
        );
        errdefer self.freeTracked(execution_model);
        return .{
            .id = wire.id,
            .generation = wire.generation,
            .execution_generation = wire.execution_generation,
            .execution_provider = parsePersistedEnum(Provider, wire.execution_provider) orelse
                return error.TaskStoreCorrupt,
            .execution_model = execution_model,
            .execution_model_owned = true,
            .input = input,
            .assistant = assistant,
            .assistant_redacted = wire.assistant_redacted,
            .active_phase = .queued,
            .tools = tools,
            .usage = usageFromWire(wire.usage),
            .status_text = status_text,
            .terminal_publication = .init(.published),
            .terminal_payload = .{
                .phase = phase,
                .outcome = outcome,
                .cause = cause,
                .session_disposition_at_completion = .reusable,
                .diagnostic_len = wire.diagnostic.len,
                .diagnostic_truncated = wire.diagnostic_truncated,
                .diagnostic_redacted = wire.diagnostic_redacted,
            },
            .terminal_observed = true,
            .event_stream_finalized = true,
            .event_projection_failure = if (wire.event_projection_failure)
                .consumer_rejected
            else
                null,
            .terminal_diagnostic = diagnostic,
            .next_activity_order = wire.next_activity_order,
        };
    }

    fn restoreRunInput(
        self: *Workbench,
        wire: task_persistence.RunInputWire,
    ) Error!RunInputRecord {
        if (std.mem.eql(u8, wire.kind, "text")) return .{ .text = .{
            .value = try self.copyBounded(
                wire.text orelse return error.TaskStoreCorrupt,
                self.limits.max_user_message_bytes,
            ),
            .redacted = wire.redacted,
        } };
        const values_wire = wire.argument_values orelse return error.TaskStoreCorrupt;
        const values = try self.allocator.alloc([]u8, values_wire.len);
        errdefer self.allocator.free(values);
        var initialized: usize = 0;
        errdefer for (values[0..initialized]) |value| self.freeTracked(value);
        for (values_wire, values) |value, *target| {
            target.* = try self.copyBounded(value, self.limits.max_user_message_bytes);
            initialized += 1;
        }
        const skill_id = try self.copyBounded(
            wire.skill_id orelse return error.TaskStoreCorrupt,
            self.limits.max_tool_field_bytes,
        );
        errdefer self.freeTracked(skill_id);
        const catalog_revision = try self.copyBounded(
            wire.catalog_revision orelse return error.TaskStoreCorrupt,
            self.limits.max_tool_field_bytes,
        );
        errdefer self.freeTracked(catalog_revision);
        const invocation_name = try self.copyBounded(
            wire.invocation_name orelse return error.TaskStoreCorrupt,
            self.limits.max_tool_field_bytes,
        );
        errdefer self.freeTracked(invocation_name);
        const display_name = try self.copyBounded(
            wire.display_name orelse return error.TaskStoreCorrupt,
            self.limits.max_tool_field_bytes,
        );
        errdefer self.freeTracked(display_name);
        return .{ .skill = .{
            .skill_id = skill_id,
            .catalog_revision = catalog_revision,
            .invocation_name = invocation_name,
            .display_name = display_name,
            .argument_values = values,
            .redacted = wire.redacted,
        } };
    }

    fn restoreTool(self: *Workbench, wire: task_persistence.ToolWire) Error!ToolView {
        const id = try self.copyBounded(wire.id, self.limits.max_tool_field_bytes);
        errdefer self.freeTracked(id);
        const name = try self.copyBounded(wire.name, self.limits.max_tool_field_bytes);
        errdefer self.freeTracked(name);
        const input = try self.copyBounded(wire.input, self.limits.max_tool_field_bytes);
        errdefer self.freeTracked(input);
        const progress = try self.copyBounded(wire.progress, self.limits.max_tool_field_bytes);
        errdefer self.freeTracked(progress);
        const content = try self.copyBounded(wire.content, self.limits.max_tool_field_bytes);
        errdefer self.freeTracked(content);
        const state = parsePersistedEnum(ToolState, wire.state) orelse return error.TaskStoreCorrupt;
        const file_refs = try self.allocator.alloc(?FileReferenceView, self.limits.max_file_refs_per_tool);
        errdefer {
            for (file_refs) |*entry| if (entry.*) |*reference| self.deinitFileReference(reference);
            self.allocator.free(file_refs);
        }
        @memset(file_refs, null);
        if (wire.file_refs) |references| {
            if (references.len > self.limits.max_file_refs_per_tool) return error.TaskStoreCorrupt;
            for (references, 0..) |reference, index| {
                file_refs[index] = try self.restoreFileReference(reference);
            }
        }
        return .{
            .route_digest = [_]u8{0} ** tool_route_digest_bytes,
            .id = id,
            .order = wire.order,
            .name = name,
            .input = input,
            .progress = progress,
            .content = content,
            .file_refs = file_refs,
            .state = state,
            .is_error = wire.is_error,
            .elapsed_ms = wire.elapsed_ms,
            .input_truncated = wire.input_truncated,
            .progress_truncated = wire.progress_truncated,
            .content_truncated = wire.content_truncated,
            .redacted = wire.redacted,
        };
    }

    fn restoreFileReference(
        self: *Workbench,
        wire: task_persistence.FileReferenceWire,
    ) Error!FileReferenceView {
        const locator_kind = parsePersistedEnum(FileReferenceLocatorKind, wire.locator_kind) orelse
            return error.TaskStoreCorrupt;
        var reference = FileReferenceView{
            .id = undefined,
            .title = undefined,
            .display_path = undefined,
            .kind = undefined,
            .locator_kind = locator_kind,
            .locator = undefined,
            .range = if (wire.range) |range| .{
                .start = .{ .line = range.start.line, .column = range.start.column },
                .end = .{ .line = range.end.line, .column = range.end.column },
            } else null,
        };
        reference.id = try self.copyBounded(wire.id, self.limits.max_file_ref_field_bytes);
        errdefer self.freeTracked(reference.id);
        reference.title = try self.copyBounded(wire.title, self.limits.max_file_ref_field_bytes);
        errdefer self.freeTracked(reference.title);
        reference.display_path = try self.copyBounded(wire.display_path, self.limits.max_file_ref_field_bytes);
        errdefer self.freeTracked(reference.display_path);
        reference.kind = try self.copyBounded(wire.kind, self.limits.max_file_ref_field_bytes);
        errdefer self.freeTracked(reference.kind);
        reference.locator = try self.copyBounded(wire.locator, self.limits.max_file_ref_field_bytes);
        return reference;
    }

    fn restoreCompact(
        self: *Workbench,
        wire: task_persistence.CompactWire,
    ) Error!CompactRecord {
        const interrupted = !persistedTerminalCompactPhase(wire.phase);
        const diagnostic = try self.allocTrackedCapacity(
            self.limits.max_terminal_diagnostic_bytes,
        );
        errdefer self.freeTracked(diagnostic);
        @memcpy(diagnostic[0..wire.diagnostic.len], wire.diagnostic);
        return .{
            .id = wire.id,
            .after_run_id = wire.after_run_id,
            .terminal_publication = .init(.published),
            .terminal_payload = .{
                .phase = if (interrupted)
                    .interrupted
                else
                    parsePersistedEnum(CompactPhase, wire.phase) orelse
                        return error.TaskStoreCorrupt,
                .cause = if (interrupted or wire.cause == null)
                    null
                else
                    parsePersistedEnum(CompactCause, wire.cause.?) orelse
                        return error.TaskStoreCorrupt,
                .before_context_tokens = wire.before_context_tokens,
                .after_context_tokens = wire.after_context_tokens,
                .usage = usageFromWire(wire.usage),
                .session_disposition_at_completion = .reusable,
                .diagnostic_len = wire.diagnostic.len,
                .diagnostic_truncated = wire.diagnostic_truncated,
                .diagnostic_redacted = wire.diagnostic_redacted,
            },
            .terminal_observed = true,
            .terminal_diagnostic = diagnostic,
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

    const CheckpointPersistenceOverride = struct {
        task_id: u64,
        record: *const checkpoint_record.Record,
        anchor: CheckpointAnchor,
    };

    fn buildTaskStateWire(self: *Workbench) Error!TaskStateWireScratch {
        return self.buildTaskStateWireWithCheckpoint(null);
    }

    fn buildTaskStateWireWithCheckpoint(
        self: *Workbench,
        checkpoint_override: ?CheckpointPersistenceOverride,
    ) Error!TaskStateWireScratch {
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
        errdefer {
            for (tasks[0..task_index]) |task| {
                for (task.runs) |run| {
                    if (run.input.argument_values) |values| self.allocator.free(values);
                    for (run.tools) |tool| if (tool.file_refs) |references| self.allocator.free(references);
                    self.allocator.free(run.tools);
                }
                self.allocator.free(task.runs);
                self.allocator.free(task.compacts);
                self.allocator.free(task.ui_history);
                if (task.checkpoint) |checkpoint|
                    self.allocator.free(@constCast(checkpoint.blob.digest));
            }
        }
        for (self.tasks) |*entry| {
            const task = &(entry.* orelse continue);
            tasks[task_index] = try self.taskWireWithCheckpoint(task, checkpoint_override);
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

    fn taskWireWithCheckpoint(
        self: *Workbench,
        task: *TaskView,
        checkpoint_override: ?CheckpointPersistenceOverride,
    ) Error!task_persistence.TaskWire {
        const checkpoint: ?*const checkpoint_record.Record = if (checkpoint_override) |override|
            if (override.task_id == task.durable.id)
                override.record
            else if (task.durable.checkpoint) |*value| value else null
        else if (task.durable.checkpoint) |*value| value else null;
        const override_applies = if (checkpoint_override) |override|
            override.task_id == task.durable.id
        else
            false;
        const checkpoint_anchor = if (override_applies)
            checkpoint_override.?.anchor
        else
            task.durable.checkpoint_anchor;
        const checkpoint_attempt = if (override_applies)
            CheckpointAttempt.none
        else
            task.durable.checkpoint_attempt;
        const checkpoint_digest = if (checkpoint) |value| blk: {
            const digest = try self.allocator.alloc(u8, checkpoint_store.digest_bytes * 2);
            const encoded = std.fmt.bytesToHex(value.blob.digest, .lower);
            @memcpy(digest, &encoded);
            break :blk digest;
        } else null;
        errdefer if (checkpoint_digest) |digest| self.allocator.free(digest);
        const run_count = countPresent(RunRecord, task.durable.runs);
        const runs = try self.allocator.alloc(task_persistence.RunWire, run_count);
        errdefer self.allocator.free(runs);
        var run_index: usize = 0;
        errdefer for (runs[0..run_index]) |run| {
            if (run.input.argument_values) |values| self.allocator.free(values);
            for (run.tools) |tool| if (tool.file_refs) |references| self.allocator.free(references);
            self.allocator.free(run.tools);
        };
        for (task.durable.runs) |*entry| {
            const run = &(entry.* orelse continue);
            runs[run_index] = try self.runWire(run);
            run_index += 1;
        }

        const compact_count = countPresent(CompactRecord, task.durable.compacts);
        const compacts = try self.allocator.alloc(
            task_persistence.CompactWire,
            compact_count,
        );
        errdefer self.allocator.free(compacts);
        var compact_index: usize = 0;
        for (task.durable.compacts) |*entry| {
            const compact = &(entry.* orelse continue);
            const terminal = compactTerminalPayload(compact);
            const phase = if (terminal) |payload| payload.phase else activeCompactPhase(compact);
            const diagnostic = if (terminal) |payload|
                compact.terminal_diagnostic[0..payload.diagnostic_len]
            else
                "";
            compacts[compact_index] = .{
                .id = compact.id,
                .after_run_id = compact.after_run_id,
                .phase = @tagName(phase),
                .cause = if (terminal) |payload|
                    if (payload.cause) |cause| @tagName(cause) else null
                else
                    null,
                .before_context_tokens = if (terminal) |payload| payload.before_context_tokens else 0,
                .after_context_tokens = if (terminal) |payload| payload.after_context_tokens else 0,
                .usage = usageWire(if (terminal) |payload| payload.usage else .{}),
                .diagnostic = diagnostic,
                .diagnostic_truncated = if (terminal) |payload| payload.diagnostic_truncated else false,
                .diagnostic_redacted = if (terminal) |payload| payload.diagnostic_redacted else false,
            };
            compact_index += 1;
        }

        const ui_history = try self.allocator.alloc(
            task_persistence.UiRecordWire,
            task.durable.ui_history_count,
        );
        errdefer self.allocator.free(ui_history);
        const ui_start = if (task.durable.ui_history_count == task.durable.ui_history.len)
            task.durable.ui_history_next
        else
            0;
        for (ui_history, 0..) |*target, offset| {
            const index = (ui_start + offset) % task.durable.ui_history.len;
            const record = &(task.durable.ui_history[index] orelse unreachable);
            target.* = .{
                .request_id = record.request_id,
                .run_id = record.run_id,
                .order = record.order,
                .kind = @tagName(record.kind),
                .state = @tagName(record.state),
                .detail = record.detailSlice(),
                .item_count = record.item_count,
                .detail_truncated = record.detail_truncated,
                .redacted = record.redacted,
                .agent_request_id = record.agent_request_id[0..record.agent_request_id_len],
                .permission = if (record.permission) |*permission| permissionSummaryWire(permission) else null,
            };
        }
        return .{
            .id = task.durable.id,
            .recent_order = task.durable.recent_order,
            .workspace_id = task.durable.workspace_id,
            .workspace_epoch = task.durable.workspace_epoch,
            .workspace_root = task.durable.workspace_root,
            .title = task.durable.title,
            .title_redacted = task.durable.title_redacted,
            .archived = task.durable.archived,
            .closed = task.durable.closed,
            .binding = .{
                .epoch = task.durable.binding_epoch,
                .execution_generation = task.durable.execution_generation,
                .provider = @tagName(task.durable.execution_provider),
                .model = task.durable.execution_model,
            },
            .next_run_generation = task.durable.next_run_generation,
            .active_operation = switch (task.runtime.active_operation) {
                .none => null,
                .run => |id| .{ .kind = "run", .id = id },
                .compact => |id| .{ .kind = "compact", .id = id },
                .restore => null,
            },
            .runs = runs,
            .compacts = compacts,
            .ui_history = ui_history,
            .checkpoint = if (checkpoint) |value| .{
                .blob = .{
                    .generation = value.blob.generation,
                    .byte_size = value.blob.byte_size,
                    .digest = checkpoint_digest.?,
                },
                .session = .{
                    .logical_session_id = value.session.logical_session_id,
                    .last_run_id = value.session.last_run_id,
                    .last_compact_id = value.session.last_compact_id,
                    .model = value.session.model,
                },
                .anchor = .{
                    .terminal = .{
                        .kind = @tagName(value.anchor.terminal),
                        .id = value.anchor.terminal.id(),
                    },
                    .binding_epoch = value.anchor.binding_epoch,
                },
            } else null,
            .checkpoint_anchor = @tagName(checkpoint_anchor),
            .checkpoint_attempt = @tagName(checkpoint_attempt),
        };
    }

    fn runWire(self: *Workbench, run: *RunRecord) Error!task_persistence.RunWire {
        const tool_count = countPresent(ToolView, run.tools);
        const tools = try self.allocator.alloc(task_persistence.ToolWire, tool_count);
        errdefer self.allocator.free(tools);
        var tool_index: usize = 0;
        for (run.tools) |entry| {
            const tool = entry orelse continue;
            const file_ref_count = if (tool.file_refs) |references| countPresent(FileReferenceView, references) else 0;
            const file_refs = if (file_ref_count != 0) try self.allocator.alloc(task_persistence.FileReferenceWire, file_ref_count) else null;
            errdefer if (file_refs) |references| self.allocator.free(references);
            if (file_refs) |references| {
                var file_ref_index: usize = 0;
                for (tool.file_refs.?) |reference_entry| {
                    const reference = reference_entry orelse continue;
                    references[file_ref_index] = .{
                        .id = reference.id,
                        .title = reference.title,
                        .display_path = reference.display_path,
                        .kind = reference.kind,
                        .locator_kind = @tagName(reference.locator_kind),
                        .locator = reference.locator,
                        .range = if (reference.range) |range| .{
                            .start = .{ .line = range.start.line, .column = range.start.column },
                            .end = .{ .line = range.end.line, .column = range.end.column },
                        } else null,
                    };
                    file_ref_index += 1;
                }
            }
            tools[tool_index] = .{
                .id = tool.id,
                .order = tool.order,
                .name = tool.name,
                .input = tool.input,
                .progress = tool.progress,
                .content = tool.content,
                .state = @tagName(tool.state),
                .is_error = tool.is_error,
                .elapsed_ms = tool.elapsed_ms,
                .input_truncated = tool.input_truncated,
                .progress_truncated = tool.progress_truncated,
                .content_truncated = tool.content_truncated,
                .redacted = tool.redacted,
                .file_refs = file_refs,
            };
            tool_index += 1;
        }
        var argument_values: ?[][]const u8 = null;
        errdefer if (argument_values) |values| self.allocator.free(values);
        const input: task_persistence.RunInputWire = switch (run.input) {
            .text => |text| .{
                .kind = "text",
                .text = text.value,
                .skill_id = null,
                .catalog_revision = null,
                .invocation_name = null,
                .display_name = null,
                .argument_values = null,
                .redacted = text.redacted,
            },
            .skill => |skill| input: {
                const values = try self.allocator.alloc([]const u8, skill.argument_values.len);
                for (values, skill.argument_values) |*target, value| target.* = value;
                argument_values = values;
                break :input .{
                    .kind = "skill",
                    .text = null,
                    .skill_id = skill.skill_id,
                    .catalog_revision = skill.catalog_revision,
                    .invocation_name = skill.invocation_name,
                    .display_name = skill.display_name,
                    .argument_values = values,
                    .redacted = skill.redacted,
                };
            },
        };
        const terminal = productTerminalFacts(run);
        const terminal_payload = if (terminal != null) terminalPayload(run) else null;
        return .{
            .id = run.id,
            .generation = run.generation,
            .execution_generation = run.execution_generation,
            .execution_provider = @tagName(run.execution_provider),
            .execution_model = run.execution_model,
            .input = input,
            .assistant = run.assistant.list.items[0..run.assistant.committed_len],
            .assistant_redacted = run.assistant_redacted,
            .phase = @tagName(runPhase(run)),
            .outcome = if (terminal) |value| @tagName(value.outcome) else null,
            .cause = if (terminal) |value|
                if (value.cause) |cause| @tagName(cause) else null
            else
                null,
            .status = run.status_text,
            .usage = usageWire(run.usage),
            .tools = tools,
            .diagnostic = if (terminal_payload) |payload|
                run.terminal_diagnostic[0..payload.diagnostic_len]
            else
                "",
            .diagnostic_truncated = if (terminal_payload) |payload| payload.diagnostic_truncated else false,
            .diagnostic_redacted = if (terminal_payload) |payload| payload.diagnostic_redacted else false,
            .event_projection_failure = run.event_projection_failure != null,
            .next_activity_order = run.next_activity_order,
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

    fn taskPersistenceOperational(health: TaskPersistenceHealth) bool {
        return health == .ready or health == .degraded;
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
                if (taskPersistenceOperational(self.task_persistence_health)) {
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

    const IdentityReplacementBlocker = enum { running, session };

    fn identityReplacementBlocker(
        self: *const Workbench,
    ) ?IdentityReplacementBlocker {
        for (self.tasks) |*entry| {
            const task = &(entry.* orelse continue);
            if (hasActiveOperation(task) or
                task.runtime.worker_references.load(.acquire) != 0)
                return .running;
            if (task.runtime.session() != null or
                task.runtime.closingSession() != null or
                task.runtime.close_thread != null or
                task.runtime.executionConst() != null)
                return .session;
        }
        return null;
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
            workspace.catalog_availability = .uninitialized;
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
            .context = job,
            .execute_fn = executeCatalogJob,
            .cancel_fn = cancelCatalogJob,
        });
        workspace.catalog_request_generation = generation;
        workspace.catalog_job = job;
        workspace.catalog_reschedule_pending = false;
        workspace.catalog_availability = .loading;
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
        for (self.workspaces) |*entry| {
            const workspace = &(entry.* orelse continue);
            if (workspace.kind == .manual)
                workspace.catalog_availability = .unavailable;
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

    fn applyWorkspaceSkillEnablement(
        self: *Workbench,
        workspace: *const WorkspaceView,
        snapshot: *CatalogSnapshot,
    ) bool {
        if (self.skill_enablement_health != .ready) return false;
        const identity: skill_enablement_impl.WorkspaceIdentity = .{
            .workspace_id = workspace.id,
            .workspace_epoch = workspace.epoch,
        };
        snapshot.selection_revision = self.skill_enablement.revision(identity);
        for (snapshot.skills) |*skill|
            skill.enabled = self.skill_enablement.isEnabled(identity, skill.skill_id);
        return true;
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
                                    catalogSnapshotLimits(self.limits),
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
                                self.reconcileSkillCatalogResultNoFail(
                                    .personal,
                                    &self.skill_catalog.?,
                                );
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
                            if (still_current) {
                                self.skill_catalog_availability = .unavailable;
                                self.reconcileSkillCatalogResultNoFail(
                                    .personal,
                                    null,
                                );
                            }
                        },
                    },
                    .cancelled => {
                        if (still_current) {
                            self.skill_catalog_availability = .unavailable;
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
                            const snapshot = CatalogSnapshot.init(
                                self.allocator,
                                acquisition.projection,
                                catalogSnapshotLimits(self.limits),
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
                            workspace.catalog_availability = if (self.applyWorkspaceSkillEnablement(
                                workspace,
                                &workspace.catalog.?,
                            )) switch (snapshot.health) {
                                .healthy => .ready,
                                .degraded => .degraded,
                            } else .unavailable;
                            self.reconcileSkillCatalogResultNoFail(
                                .{ .project = .{
                                    .workspace_id = workspace.id,
                                    .workspace_epoch = workspace.epoch,
                                } },
                                &workspace.catalog.?,
                            );
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
                        if (still_current) {
                            workspace.catalog_availability = .unavailable;
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

    fn commitMcpRefreshJobNoFail(self: *Workbench) bool {
        const mcp = if (self.mcp) |*value| value else return false;
        const job = mcp.refresh_job orelse return false;
        const state = job.state.load(.acquire);
        if (state == .queued or state == .running) return false;
        mcp.refresh_job = null;
        const still_current = !self.shutting_down and
            mcp.refresh_request_generation == job.request_generation;
        switch (state) {
            .completed => switch (job.outcome) {
                .activated => |activated| {
                    if (still_current) {
                        if (mcp.activation) |old| old.deinit();
                        mcp.activation = activated.activation;
                        mcp.activation_failed = false;
                        if (job.build_admission) {
                            self.replaceMcpAdmission(mcp, .{ .ready = .{
                                .selection = activated.selection,
                                .catalog_generation = activated.activation.catalogGeneration(),
                            } });
                        } else {
                            self.blockMcpAdmissionForCurrentState(mcp);
                        }
                        job.outcome = .empty;
                    }
                },
                .empty => if (still_current) {
                    if (mcp.activation) |old| old.deinit();
                    mcp.activation = null;
                    mcp.activation_failed = false;
                    if (job.build_admission)
                        self.replaceMcpAdmission(mcp, .{ .ready = .{
                            .selection = null,
                            .catalog_generation = null,
                        } })
                    else
                        self.blockMcpAdmissionForCurrentState(mcp);
                },
                .unavailable => if (still_current) {
                    if (mcp.activation) |old| old.deinit();
                    mcp.activation = null;
                    mcp.activation_failed = true;
                    self.blockMcpAdmission(mcp, .activation_unavailable);
                },
            },
            .cancelled => {},
            .queued, .running => unreachable,
        }
        job.deinit();
        return true;
    }

    fn blockMcpAdmissionForCurrentState(
        self: *Workbench,
        mcp: *McpProductState,
    ) void {
        const inspection = if (mcp.management) |*management| management.inspect() else null;
        if (inspection) |value| {
            if (value.health == .outcome_unknown) {
                self.blockMcpAdmission(mcp, .persistence_outcome_unknown);
                return;
            }
            if (value.health != .ready) {
                self.blockMcpAdmission(mcp, .management_recovery_required);
                return;
            }
        }
        const alignment = if (inspection) |value|
            value.runtime_alignment
        else
            mcp_configuration.RuntimeAlignment.unknown;
        self.blockMcpAdmission(mcp, switch (alignment) {
            .current => .activation_unavailable,
            .restart_required => .pending_restart,
            .unknown => .alignment_unknown,
        });
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
            const issue_name = issue.invocation_name orelse continue;
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
                if (task.runtime.session() != null or task.runtime.closingSession() != null or
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
        item.input.redacted =
            redactFixedWidthNoFail(item.input.value, credential) or
            item.input.redacted;
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
                if (pinned.selection_revision == null or
                    skill_input.selection_revision != pinned.selection_revision.?)
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

    fn applyAutomaticTaskTitle(
        self: *Workbench,
        task: *TaskView,
        run: *const RunRecord,
    ) bool {
        // This gate must run before writing the fallback. Existing Task and
        // scheduled-task titles are product facts, not candidates for auto naming.
        if (task.durable.title.len != 0 or run.generation != 1) return false;
        const candidate = automaticTitleCandidate(&run.input) orelse return false;
        const bounded_candidate = boundAutomaticTitle(candidate);
        const execution = taskExecutionInput(task) catch return false;
        const projected = self.copyProjected(
            bounded_candidate,
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

    fn rollbackAutomaticTaskTitle(
        self: *Workbench,
        task: *TaskView,
        previous_title: []u8,
        previous_redacted: bool,
    ) void {
        const current_title = task.durable.title;
        self.freeTracked(current_title);
        task.durable.title = previous_title;
        self.projection_bytes += previous_title.len;
        task.durable.title_redacted = previous_redacted;
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
    }

    test "automatic title allocation failure does not escape the fallback" {
        var workbench = try testWorkbench();
        defer workbench.deinit();

        const remaining = workbench.limits.max_projection_bytes - workbench.projection_bytes;
        const reservation = try workbench.allocTrackedCapacity(remaining);
        defer workbench.freeTracked(reservation);

        const task = &workbench.tasks[0].?;
        const run = &task.durable.runs[0].?;
        try std.testing.expect(!workbench.applyAutomaticTaskTitle(task, run));
        try std.testing.expectEqualStrings("", task.durable.title);
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
            .workbench = undefined,
            .task = undefined,
            .session = undefined,
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
        std.debug.assert(!compact.session_reference_held.load(.acquire));
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
        self.releaseTaskAttachmentNoFail(task, if (task.durable.closed) .closed else .cold_start);
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

    fn permissionSummary(value: lifecycle.PermissionProvenance) Error!PermissionSummary {
        if (value.tool.name.len > permission_summary_field_capacity or
            value.tool.binding.len > permission_summary_field_capacity or
            (if (value.request_id) |request_id| request_id.len else 0) > permission_summary_field_capacity or
            (if (value.matched_rule_id) |rule_id| rule_id.len else 0) > permission_summary_field_capacity)
            return error.ProjectionCapacity;
        var summary = PermissionSummary{
            .decision = value.decision,
            .source = value.source,
            .policy_generation = value.policy_generation,
            .used_session_rule = value.used_session_rule,
            .callback_outcome = value.callback_outcome,
            .tool_namespace = value.tool.namespace,
        };
        if (value.request_id) |request_id| {
            @memcpy(summary.request_id[0..request_id.len], request_id);
            summary.request_id_len = request_id.len;
        }
        if (value.matched_rule_id) |rule_id| {
            @memcpy(summary.matched_rule_id[0..rule_id.len], rule_id);
            summary.matched_rule_id_len = rule_id.len;
        }
        @memcpy(summary.tool_name[0..value.tool.name.len], value.tool.name);
        summary.tool_name_len = value.tool.name.len;
        @memcpy(summary.tool_binding[0..value.tool.binding.len], value.tool.binding);
        summary.tool_binding_len = value.tool.binding.len;
        return summary;
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
                try self.projectedJsonValueWithKnownCredentials(writer, permission.tool.name);
                writer.writeAll(",\"args\":") catch return error.SnapshotTooLarge;
                try self.projectedJsonValueWithKnownCredentials(writer, permission.arguments_json);
                writer.writeAll(",\"availableChoices\":[") catch return error.SnapshotTooLarge;
                var wrote_choice = false;
                for (permission.responses) |choice| {
                    if (choice == .allow_session or choice == .deny_session) {
                        if (permission.candidate == null) continue;
                    }
                    if (wrote_choice) writer.writeByte(',') catch return error.SnapshotTooLarge;
                    jsonValue(writer, @tagName(choice)) catch return error.SnapshotTooLarge;
                    wrote_choice = true;
                }
                writer.writeByte(']') catch return error.SnapshotTooLarge;
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
            .permission => |permission| self.containsKnownCredential(permission.tool.name) or
                self.containsKnownCredential(permission.arguments_json),
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
            writer.print(",\"state\":\"{s}\",\"isError\":{},\"elapsedMs\":\"{d}\",\"inputTruncated\":{},\"progressTruncated\":{},\"contentTruncated\":{},\"redacted\":{},\"fileRefs\":[", .{
                @tagName(tool.state),
                tool.is_error,
                tool.elapsed_ms,
                tool.input_truncated,
                tool.progress_truncated,
                tool.content_truncated,
                tool.redacted,
            }) catch return error.SnapshotTooLarge;
            var file_ref_count: usize = 0;
            if (tool.file_refs) |refs| for (refs) |*file_ref_entry| {
                const reference = file_ref_entry.* orelse continue;
                if (file_ref_count != 0) writer.writeByte(',') catch return error.SnapshotTooLarge;
                file_ref_count += 1;
                writer.writeAll("{\"id\":") catch return error.SnapshotTooLarge;
                try self.projectedJsonValueWithKnownCredentials(writer, reference.id);
                writer.writeAll(",\"title\":") catch return error.SnapshotTooLarge;
                try self.projectedJsonValueWithKnownCredentials(writer, reference.title);
                writer.writeAll(",\"displayPath\":") catch return error.SnapshotTooLarge;
                try self.projectedJsonValueWithKnownCredentials(writer, reference.display_path);
                writer.writeAll(",\"kind\":") catch return error.SnapshotTooLarge;
                try self.projectedJsonValueWithKnownCredentials(writer, reference.kind);
                writer.writeAll(",\"range\":") catch return error.SnapshotTooLarge;
                if (reference.range) |range| {
                    writer.print("{{\"start\":{{\"line\":\"{d}\",\"column\":\"{d}\"}},\"end\":{{\"line\":\"{d}\",\"column\":\"{d}\"}}}}", .{
                        range.start.line,
                        range.start.column,
                        range.end.line,
                        range.end.column,
                    }) catch return error.SnapshotTooLarge;
                } else writer.writeAll("null") catch return error.SnapshotTooLarge;
                writer.writeByte('}') catch return error.SnapshotTooLarge;
            };
            writer.writeAll("]}") catch return error.SnapshotTooLarge;
        }
        writer.writeAll("]}") catch return error.SnapshotTooLarge;
    }

    fn prepareUiRecord(
        self: *Workbench,
        session: *lifecycle.Session,
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
            .permission => |permission| permission.arguments_json,
        };
        switch (request) {
            .permission => |permission| {
                if (permission.request_id.len <= permission_summary_field_capacity) {
                    @memcpy(record.agent_request_id[0..permission.request_id.len], permission.request_id);
                    record.agent_request_id_len = permission.request_id.len;
                }
            },
            .ask_question => {},
        }
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
        const start = if (view.durable.ui_history_count == view.durable.ui_history.len) view.durable.ui_history_next else 0;
        for (0..view.durable.ui_history_count) |offset| {
            if (offset != 0) writer.writeByte(',') catch return error.SnapshotTooLarge;
            const index = (start + offset) % view.durable.ui_history.len;
            const record = &(view.durable.ui_history[index] orelse unreachable);
            writer.print("{{\"requestId\":\"{d}\",\"runId\":\"{d}\",\"order\":\"{d}\",\"kind\":\"{s}\",\"state\":\"{s}\",\"detail\":", .{
                record.request_id,
                record.run_id,
                record.order,
                @tagName(record.kind),
                @tagName(record.state),
            }) catch return error.SnapshotTooLarge;
            try self.projectedJsonValueWithKnownCredentials(writer, record.detailSlice());
            writer.print(",\"itemCount\":{d},\"detailTruncated\":{},\"redacted\":{},\"agentRequestId\":", .{
                record.item_count,
                record.detail_truncated,
                record.redacted,
            }) catch return error.SnapshotTooLarge;
            try self.projectedJsonValueWithKnownCredentials(
                writer,
                record.agent_request_id[0..record.agent_request_id_len],
            );
            writer.writeAll(",\"permission\":") catch return error.SnapshotTooLarge;
            if (record.permission) |permission| {
                writer.writeAll("{\"requestId\":") catch return error.SnapshotTooLarge;
                jsonValue(writer, permission.requestId()) catch return error.SnapshotTooLarge;
                writer.writeAll(",\"matchedRuleId\":") catch return error.SnapshotTooLarge;
                jsonValue(writer, permission.matchedRuleId()) catch return error.SnapshotTooLarge;
                writer.writeAll(",\"toolNamespace\":") catch return error.SnapshotTooLarge;
                jsonValue(writer, @tagName(permission.tool_namespace)) catch return error.SnapshotTooLarge;
                writer.writeAll(",\"toolName\":") catch return error.SnapshotTooLarge;
                jsonValue(writer, permission.toolName()) catch return error.SnapshotTooLarge;
                writer.writeAll(",\"toolBinding\":") catch return error.SnapshotTooLarge;
                jsonValue(writer, permission.toolBinding()) catch return error.SnapshotTooLarge;
                writer.writeAll(",\"decision\":") catch return error.SnapshotTooLarge;
                jsonValue(writer, @tagName(permission.decision)) catch return error.SnapshotTooLarge;
                writer.writeAll(",\"source\":") catch return error.SnapshotTooLarge;
                jsonValue(writer, @tagName(permission.source)) catch return error.SnapshotTooLarge;
                writer.print(",\"policyGeneration\":\"{d}\",\"usedSessionRule\":{},\"callbackOutcome\":", .{
                    permission.policy_generation,
                    permission.used_session_rule,
                }) catch return error.SnapshotTooLarge;
                if (permission.callback_outcome) |outcome|
                    jsonValue(writer, @tagName(outcome)) catch return error.SnapshotTooLarge
                else
                    writer.writeAll("null") catch return error.SnapshotTooLarge;
                writer.writeByte('}') catch return error.SnapshotTooLarge;
            } else writer.writeAll("null") catch return error.SnapshotTooLarge;
            writer.writeByte('}') catch return error.SnapshotTooLarge;
        }
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
    view.runtime.close_completion.store(completion, .release);
    _ = notifier.notify();
}

fn agentRunStateStatus(phase: lifecycle.RunStatePhase) []const u8 {
    return switch (phase) {
        .starting => "Starting",
        .generating => "Generating response",
        .executing_tools => "Executing tools",
        .waiting_ui => "Waiting for your input",
        .retrying => "Retrying provider",
        .compacting => "Compacting context",
        .finalizing => "Finishing",
        .completed => "Completed",
        .failed => "Failed",
        .aborted => "Stopped",
        .poisoned => "Session unavailable",
    };
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
    const checkpoint_eligible = terminal.raw_status_code != null and
        terminal.session_disposition_at_completion == .reusable;
    terminal.deinit();
    agent_run.deinit();
    const notifier = run.workbench.change_notifier;
    if (!checkpoint_eligible or !postprocessCheckpoint(
        run.workbench,
        run.session,
        &run.checkpoint,
        run.checkpoint_export_context,
    )) releaseWorkerReference(run);
    _ = notifier.notify();
}

fn executeCompactJob(context: *anyopaque) void {
    const compact: *CompactRecord = @ptrCast(@alignCast(context));
    compact.agent_handoff.store(.starting, .release);
    _ = compact.workbench.change_notifier.notify();
    compact.agent_handoff.store(.running, .release);
    var terminal = compact.session.executePreparedCompact(compact.id) catch |err| {
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
        const notifier = compact.workbench.change_notifier;
        releaseCompactReferences(compact);
        _ = notifier.notify();
        return;
    };
    compact.agent_handoff.store(.finishing, .release);
    commitCompactTerminal(compact, &terminal);
    const checkpoint_eligible = terminal.raw_status_code != null and
        terminal.session_disposition_at_completion == .reusable;
    terminal.deinit();
    const notifier = compact.workbench.change_notifier;
    releaseCompactSessionReference(compact);
    if (!checkpoint_eligible or !postprocessCheckpoint(
        compact.workbench,
        compact.session,
        &compact.checkpoint,
        compact.checkpoint_export_context,
    )) releaseCompactWorkerReference(compact);
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
    session: *lifecycle.Session,
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
    var outcome = session.exportCheckpoint(
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

fn checkpointFailureAttempt(failure: lifecycle.CheckpointFailure) CheckpointAttempt {
    return switch (failure.reason) {
        .cancelled => .cancelled,
        .resource_limit => .resource_limit,
        .io_failed => .io_failed,
        .dependency_contract => .dependency_contract,
        else => if (failure.stage == .describe) .describe_failed else .export_failed,
    };
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

fn cancelCompactJobForShutdown(context: *anyopaque) void {
    const compact: *CompactRecord = @ptrCast(@alignCast(context));
    _ = compact.pending_interruption.cmpxchgStrong(
        .none,
        .app_shutdown,
        .acq_rel,
        .acquire,
    );
    cancelPreparedCompactOrPanic(compact.session, compact.id);
    _ = commitCompactProductTerminal(
        compact,
        .aborted,
        compactCauseForInterruption(pendingExternalInterruption(compact)),
        .closing,
        .{},
        0,
        0,
        "",
        false,
    );
    const notifier = compact.workbench.change_notifier;
    releaseCompactReferences(compact);
    _ = notifier.notify();
}

fn commitCompactTerminal(
    compact: *CompactRecord,
    result: *const lifecycle.CompactTerminalResult,
) void {
    var cause: ?CompactCause = null;
    const phase: CompactPhase = if (result.failure == .dependency_contract) failure: {
        cause = .dependency_contract_failure;
        break :failure .failed;
    } else if (result.failure == .abi_status) failure: {
        cause = if (result.abi_status == .resource_limit)
            .resource_limit
        else
            .agent_failure;
        break :failure .failed;
    } else if (result.outcome) |outcome| switch (outcome) {
        .compacted => .compacted,
        .no_change => .no_change,
        .degraded => .degraded,
        .aborted => aborted: {
            cause = if (result.interruption) |interruption|
                compactCauseForInterruption(interruption)
            else
                .agent_failure;
            break :aborted .aborted;
        },
    } else missing: {
        cause = .dependency_contract_failure;
        break :missing .failed;
    };
    _ = commitCompactProductTerminal(
        compact,
        phase,
        cause,
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

fn cancelPreparedCompactOrPanic(
    session: *lifecycle.Session,
    operation_id: u64,
) void {
    session.cancelPreparedCompact(operation_id) catch |err| std.debug.panic(
        "Executor removed queued compact {d}, but Agent rejected prepared cancellation: {s}",
        .{ operation_id, @errorName(err) },
    );
}

fn releaseWorkerReference(run: *RunRecord) void {
    std.debug.assert(run.worker_reference_held.swap(false, .acq_rel));
    const references = &run.task.runtime.worker_references;
    const previous = references.fetchSub(1, .release);
    std.debug.assert(previous != 0);
}

fn releaseCompactReferences(compact: *CompactRecord) void {
    releaseCompactSessionReference(compact);
    releaseCompactWorkerReference(compact);
}

fn releaseCompactSessionReference(compact: *CompactRecord) void {
    if (compact.session_reference_held.swap(false, .acq_rel))
        compact.session.releaseReference();
}

fn releaseCompactWorkerReference(compact: *CompactRecord) void {
    if (!compact.worker_reference_held.swap(false, .acq_rel)) return;
    const previous = compact.task.runtime.worker_references.fetchSub(1, .release);
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

fn agentAnswers(
    answers: []const []const []const u8,
    answer_buffer: []lifecycle.Answer,
) []const lifecycle.Answer {
    std.debug.assert(answer_buffer.len == answers.len);
    for (answers, answer_buffer) |values, *answer|
        answer.* = .{ .values = values };
    return answer_buffer;
}

fn agentPermissionChoice(choice: PermissionChoice) lifecycle.PermissionChoice {
    return switch (choice) {
        .allow_once => .allow_once,
        .allow_session => .allow_session,
        .deny_once => .deny_once,
        .deny_session => .deny_session,
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
                .resource_limit, .checkpoint_budget_required => .resource_limit,
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
            .cause = if (result.termination_signal) |signal| causeForSignal(signal) else .agent_failure,
        },
        .checkpoint_budget_exhausted, .checkpoint_resource_limit => .{
            .phase = .stopped,
            .outcome = .stopped,
            .cause = .resource_limit,
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
    const run = findRun(view.durable.runs, view.runtime.active_run_id) orelse return null;
    const phase = runPhase(run);
    return if (isTerminalPhase(phase)) null else phase;
}

fn hasActiveOperation(view: *const TaskView) bool {
    return switch (view.runtime.active_operation) {
        .none => false,
        .run => |id| if (findRun(view.durable.runs, id)) |run|
            !isTerminalPhase(runPhase(run))
        else
            false,
        .compact => |id| if (findCompact(view.durable.compacts, id)) |compact|
            compactTerminalPayload(compact) == null
        else
            false,
        .restore => true,
    };
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

fn lastFinalizedRunId(view: *const TaskView) ?u64 {
    var latest: u64 = 0;
    for (view.durable.runs) |*entry| {
        const run = &(entry.* orelse continue);
        if (!run.event_stream_finalized or productTerminalFacts(run) == null) continue;
        latest = @max(latest, run.id);
    }
    return if (latest == 0) null else latest;
}

fn latestCompactId(view: *const TaskView) u64 {
    var latest: u64 = 0;
    for (view.durable.compacts) |*entry| {
        const compact = &(entry.* orelse continue);
        if (compactTerminalPayload(compact) == null) continue;
        latest = @max(latest, compact.id);
    }
    return latest;
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

fn isTerminalCompactPhase(phase: CompactPhase) bool {
    return switch (phase) {
        .queued, .compacting, .stopping => false,
        .compacted, .no_change, .degraded, .aborted, .interrupted, .failed => true,
    };
}

fn compactTerminalPayload(
    compact: *const CompactRecord,
) ?*const CompactTerminalPayload {
    while (true) switch (compact.terminal_publication.load(.acquire)) {
        .open => return null,
        .publishing => std.atomic.spinLoopHint(),
        .published => return &compact.terminal_payload,
    };
}

fn activeCompactPhase(compact: *const CompactRecord) CompactPhase {
    if (compact.pending_interruption.load(.acquire) != .none) return .stopping;
    return switch (compact.agent_handoff.load(.acquire)) {
        .queued, .starting => .queued,
        .running, .finishing => .compacting,
    };
}

fn pendingExternalInterruption(
    compact: *const CompactRecord,
) lifecycle.ExternalInterruption {
    return switch (compact.pending_interruption.load(.acquire)) {
        .none => unreachable,
        .user_cancel => .user_cancel,
        .timeout => .timeout,
        .session_close => .session_close,
        .app_shutdown => .app_shutdown,
    };
}

fn compactCauseForInterruption(
    interruption: lifecycle.ExternalInterruption,
) CompactCause {
    return switch (interruption) {
        .user_cancel, .timeout => .user_cancel,
        .session_close => .session_close,
        .app_shutdown => .app_shutdown,
    };
}

fn continuationAvailable(capability: ContinuationCapability) bool {
    return switch (capability) {
        .available => true,
        .unavailable => false,
    };
}

fn taskLifecycle(task: *const TaskView) TaskLifecycle {
    if (task.durable.closed) return .closed;
    return switch (task.runtime.attachment) {
        .closing => .closing,
        .detached, .attached => .open,
    };
}

fn recoveryAttachment(attachment: task_runtime.Attachment) task_recovery.Attachment {
    return switch (attachment) {
        .detached => .detached,
        .closing => .closing,
        .attached => |attached| switch (attached.health) {
            .available => .attached_available,
            .session_poisoned => .attached_session_poisoned,
        },
    };
}

fn recoveryOperation(operation: ActiveOperation) task_recovery.Operation {
    return switch (operation) {
        .none => .none,
        .run => .run,
        .compact => .compact,
        .restore => .restore,
    };
}

fn checkpointMatchesCurrentHistory(
    task: *const TaskView,
    record: checkpoint_record.Record,
) bool {
    if (record.session.last_run_id != (lastFinalizedRunId(task) orelse 0) or
        record.session.last_compact_id != latestCompactId(task))
        return false;
    return switch (record.anchor.terminal) {
        .run => |id| id == record.session.last_run_id,
        .compact => |id| id == record.session.last_compact_id,
    };
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

fn foldTerminalDisposition(
    task: *TaskView,
    disposition: lifecycle.SessionDisposition,
) void {
    const attached = task.runtime.attached() orelse return;
    switch (disposition) {
        .reusable => attached.health = .available,
        .poisoned => attached.health = .session_poisoned,
        .closing => std.debug.assert(task.runtime.beginClosing()),
    }
}

fn hasUnfinalizedTerminalEvents(view: *const TaskView) bool {
    for (view.durable.runs) |*entry| {
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

fn kindForResponse(response: UiResponse) UiRecordKind {
    return switch (response) {
        .answers => .ask_question,
        .permission => .permission,
    };
}

fn stateForResponse(response: UiResponse) UiRecordState {
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

fn countPresent(comptime T: type, entries: []const ?T) usize {
    var count: usize = 0;
    for (entries) |entry| if (entry != null) {
        count += 1;
    };
    return count;
}

fn usageWire(usage: UsageView) task_persistence.UsageWire {
    return .{
        .input_tokens = usage.input_tokens,
        .output_tokens = usage.output_tokens,
        .cache_read_input_tokens = usage.cache_read_input_tokens,
        .cache_creation_input_tokens = usage.cache_creation_input_tokens,
    };
}

fn usageFromWire(usage: task_persistence.UsageWire) UsageView {
    return .{
        .input_tokens = usage.input_tokens,
        .output_tokens = usage.output_tokens,
        .cache_read_input_tokens = usage.cache_read_input_tokens,
        .cache_creation_input_tokens = usage.cache_creation_input_tokens,
    };
}

fn restoreUiRecord(wire: task_persistence.UiRecordWire) UiRecord {
    var result: UiRecord = .{
        .request_id = wire.request_id,
        .run_id = wire.run_id,
        .order = wire.order,
        .kind = parsePersistedEnum(UiRecordKind, wire.kind) orelse unreachable,
        .state = parsePersistedEnum(UiRecordState, wire.state) orelse unreachable,
        .item_count = wire.item_count,
        .detail_truncated = wire.detail_truncated,
        .redacted = wire.redacted,
    };
    @memcpy(result.agent_request_id[0..wire.agent_request_id.len], wire.agent_request_id);
    result.agent_request_id_len = wire.agent_request_id.len;
    if (wire.permission) |permission| {
        var summary = PermissionSummary{
            .decision = parsePersistedEnum(lifecycle.PermissionDecision, permission.decision) orelse unreachable,
            .source = parsePersistedEnum(lifecycle.PermissionDecisionSource, permission.source) orelse unreachable,
            .policy_generation = permission.policy_generation,
            .used_session_rule = permission.used_session_rule,
            .callback_outcome = if (permission.callback_outcome) |outcome|
                parsePersistedEnum(lifecycle.PermissionCallbackOutcome, outcome) orelse unreachable
            else
                null,
            .tool_namespace = parsePersistedEnum(lifecycle.PermissionToolNamespace, permission.tool_namespace) orelse unreachable,
        };
        @memcpy(summary.request_id[0..permission.request_id.len], permission.request_id);
        summary.request_id_len = permission.request_id.len;
        @memcpy(summary.matched_rule_id[0..permission.matched_rule_id.len], permission.matched_rule_id);
        summary.matched_rule_id_len = permission.matched_rule_id.len;
        @memcpy(summary.tool_name[0..permission.tool_name.len], permission.tool_name);
        summary.tool_name_len = permission.tool_name.len;
        @memcpy(summary.tool_binding[0..permission.tool_binding.len], permission.tool_binding);
        summary.tool_binding_len = permission.tool_binding.len;
        result.permission = summary;
    }
    @memcpy(result.detail[0..wire.detail.len], wire.detail);
    result.detail_len = wire.detail.len;
    return result;
}

fn parsePersistedEnum(comptime T: type, value: []const u8) ?T {
    return std.meta.stringToEnum(T, value);
}

fn persistedTerminalRunPhase(value: []const u8) bool {
    const phase = parsePersistedEnum(RunPhase, value) orelse return false;
    return isTerminalPhase(phase);
}

fn persistedTerminalCompactPhase(value: []const u8) bool {
    const phase = parsePersistedEnum(CompactPhase, value) orelse return false;
    return isTerminalCompactPhase(phase);
}

fn findRun(entries: []?RunRecord, run_id: u64) ?*RunRecord {
    if (run_id == 0) return null;
    for (entries) |*entry| if (entry.*) |*run| if (run.id == run_id) return run;
    return null;
}

fn findUiRecordByAgentRequestId(
    entries: []?UiRecord,
    request_id: []const u8,
    run_id: u64,
) ?*UiRecord {
    for (entries) |*entry| {
        const record = &(entry.* orelse continue);
        if (record.run_id == run_id and
            std.mem.eql(u8, record.agent_request_id[0..record.agent_request_id_len], request_id))
            return record;
    }
    return null;
}

fn findCompact(
    entries: []?CompactRecord,
    operation_id: u64,
) ?*CompactRecord {
    for (entries) |*entry| {
        const compact = &(entry.* orelse continue);
        if (compact.id == operation_id) return compact;
    }
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

fn taskCatalogProjection(task: *const TaskView) CatalogProjection {
    return if (task.runtime.pinnedCatalogConst()) |snapshot|
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
var test_task_session: lifecycle.Session = undefined;

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
                .session = &test_task_session,
                .execution = task_execution.take(),
                .route_id = 3,
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

fn testPermissionRequest(tool_name: []const u8, arguments_json: []const u8) lifecycle.UiRequest {
    return .{ .permission = .{
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
    } };
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
    try std.testing.expect(task.runtime.session() == null);
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

    try restored.closeTask(3);
    try std.testing.expectEqual(TaskLifecycle.closed, taskLifecycle(restored.findTask(3).?));
    try std.testing.expect(restored.findTask(3).?.durable.closed);

    var closed_restore = try Workbench.init(
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
    defer closed_restore.deinit();
    const closed_task = closed_restore.findTask(3) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(TaskLifecycle.closed, taskLifecycle(closed_task));
    try std.testing.expectEqual(
        ContinuationUnavailableReason.closed,
        closed_restore.taskContinuation(closed_task).unavailable,
    );

    try closed_restore.deleteTask(3);
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
    task.durable.closed = true;
    workbench.releaseTaskAttachmentNoFail(task, .closed);
    workbench.task_persistence = persistence.capability(null);
    workbench.task_persistence_health = .ready;
    const tracked_before_delete = workbench.projection_bytes;

    try std.testing.expectError(error.TaskPersistenceFailed, workbench.deleteTask(3));
    try std.testing.expect(workbench.findTask(3) != null);
    try std.testing.expectEqual(tracked_before_delete, workbench.projection_bytes);
    try std.testing.expectEqual(TaskPersistenceHealth.write_failed, workbench.task_persistence_health);
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
        .invocation_name = "review",
        .display_name = "Review",
        .description = "Review changes",
        .argument_names = &.{"target"},
        .max_values = 1,
    }};
    var workspace_catalog = try CatalogSnapshot.init(
        workbench.allocator,
        .{
            .revision = "catalog-1",
            .health = .healthy,
            .skills = &source_skills,
            .issues = &.{},
            .storage = undefined,
        },
        catalogSnapshotLimits(workbench.limits),
        workbench.limits.max_projection_bytes - workbench.projection_bytes,
    );
    workspace_catalog.applyEnablement(1, &.{});
    var pinned = try workspace_catalog.clone(
        workbench.allocator,
        catalogSnapshotLimits(workbench.limits),
        workbench.limits.max_projection_bytes -
            workbench.projection_bytes -
            workspace_catalog.projected_bytes,
    );
    defer pinned.deinit();
    workbench.projection_bytes += workspace_catalog.projected_bytes;
    workbench.workspaces[0].?.catalog = workspace_catalog;
    workbench.workspaces[0].?.catalog_availability = .ready;

    const next_revision = try workbench.setSkillEnabled(.{
        .workspace_id = 1,
        .expected_workspace_epoch = 1,
        .skill_id = "builtin.review",
        .enabled = false,
        .expected_catalog_revision = "catalog-1",
        .expected_selection_revision = 1,
    });
    try std.testing.expectEqual(@as(u64, 2), next_revision);
    try std.testing.expectEqual(@as(?u64, 2), workbench.workspaces[0].?.catalog.?.selection_revision);
    try std.testing.expect(!workbench.workspaces[0].?.catalog.?.skills[0].enabled);
    try std.testing.expectEqual(@as(?u64, 1), pinned.selection_revision);
    try std.testing.expect(pinned.skills[0].enabled);
    try std.testing.expectError(
        error.StaleCatalog,
        workbench.setSkillEnabled(.{
            .workspace_id = 1,
            .expected_workspace_epoch = 1,
            .skill_id = "builtin.review",
            .enabled = true,
            .expected_catalog_revision = "catalog-1",
            .expected_selection_revision = 1,
        }),
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
    workbench.workspaces[0].?.catalog = workspace_catalog;
    workbench.workspaces[0].?.catalog_availability = .ready;
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
    try std.testing.expect(workbench.workspaces[0].?.catalog.?.redacted);
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
    try std.testing.expectError(error.TaskNotClosed, workbench.deleteTask(3));
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
    workbench.tasks[0].?.durable.closed = true;
    workbench.releaseTaskAttachmentNoFail(&workbench.tasks[0].?, .closed);
    workbench.tasks[0].?.runtime.worker_references.store(1, .release);
    try std.testing.expectError(error.TaskBusy, workbench.deleteTask(3));
    try std.testing.expect(workbench.tasks[0] != null);
    workbench.tasks[0].?.runtime.worker_references.store(0, .release);
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

test "execution replacement gate rejects runtime references and admits durable history" {
    var workbench = try testWorkbench();
    defer workbench.deinit();
    try workbench.beginDefaultExecutionReplacement();
    try std.testing.expect(workbench.executionReplacementPending());
    try std.testing.expect(!workbench.accountView().can_create_task);
    workbench.endExecutionReplacementNoFail();
    try std.testing.expectError(
        error.TaskRunning,
        workbench.beginExecutionReplacement(),
    );
    try std.testing.expect(!workbench.executionReplacementPending());
    const task = &workbench.tasks[0].?;
    task.durable.runs[0].?.active_phase = .completed;
    task.runtime.active_run_id = 0;
    task.runtime.worker_references.store(1, .release);
    try std.testing.expectError(
        error.TaskRunning,
        workbench.beginExecutionReplacement(),
    );
    task.runtime.worker_references.store(0, .release);
    try std.testing.expectEqual(
        Workbench.IdentityReplacementBlocker.session,
        workbench.identityReplacementBlocker().?,
    );
    var detached = task.runtime.detach(.cold_start);
    detached.execution.deinit();
    try workbench.beginExecutionReplacement();
    try std.testing.expect(workbench.executionReplacementPending());
    try std.testing.expect(task.runtime.executionConst() == null);
    try std.testing.expectEqual(TaskLifecycle.open, taskLifecycle(task));
    try std.testing.expect(!task.durable.closed);
    try std.testing.expectEqualStrings("fixture-model", task.durable.execution_model);
    try std.testing.expect(!workbench.accountView().can_create_task);
    workbench.endExecutionReplacementNoFail();
    try std.testing.expect(workbench.accountView().can_create_task);
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
    task.durable.closed = true;
    workbench.releaseTaskAttachmentNoFail(task, .closed);
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
    const task = &workbench.tasks[0].?;
    task.runtime.attached().?.route_id = 99;

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
    task.runtime.attached().?.route_id = 99;

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

    task.durable.closed = true;
    foldTerminalDisposition(task, .reusable);
    try std.testing.expectEqual(TaskLifecycle.closed, taskLifecycle(task));
    try std.testing.expectEqual(
        ContinuationUnavailableReason.closed,
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

    terminal.abi_status = .checkpoint_budget_required;
    terminal.raw_status_code = @intFromEnum(lifecycle.Status.checkpoint_budget_required);
    terminal.stop_reason = null;
    terminal.raw_stop_reason_code = null;
    terminal.failure = .abi_status;
    try std.testing.expectEqual(
        TerminalDecision{ .phase = .failed, .outcome = .failed, .cause = .resource_limit },
        classifyAgentTerminal(&terminal),
    );

    terminal.abi_status = .ok;
    terminal.raw_status_code = @intFromEnum(lifecycle.Status.ok);
    terminal.stop_reason = .checkpoint_budget_exhausted;
    terminal.raw_stop_reason_code = @intFromEnum(lifecycle.StopReason.checkpoint_budget_exhausted);
    terminal.failure = null;
    try std.testing.expectEqual(
        TerminalDecision{ .phase = .stopped, .outcome = .stopped, .cause = .resource_limit },
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

    terminal.failure = null;
    terminal.stop_reason = .api_error;
    terminal.raw_stop_reason_code = @intFromEnum(lifecycle.StopReason.api_error);
    terminal.termination_signal = null;
    try std.testing.expectEqual(
        TerminalDecision{ .phase = .failed, .outcome = .failed, .cause = .agent_failure },
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
    task.durable.closed = true;
    workbench.releaseTaskAttachmentNoFail(task, .closed);
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

test "permission pending projection follows responses and candidate scope" {
    var workbench = try testWorkbench();
    defer workbench.deinit();
    const with_candidate = lifecycle.UiRequest{ .permission = .{
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
    } };
    var candidate_storage: [4096]u8 = undefined;
    var candidate_writer = std.Io.Writer.fixed(&candidate_storage);
    try workbench.writePendingUiProjection(
        &candidate_writer,
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
    try workbench.writePendingUiProjection(&once_writer, 1, 1, 1, once_only);
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
    const projected = try Workbench.permissionSummary(value);
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
        fn complete() void {}
    };

    var workbench = try testWorkbench();
    defer workbench.deinit();
    const task = &workbench.tasks[0].?;
    const run = &task.durable.runs[0].?;
    try std.testing.expect(task.runtime.beginClosing());
    task.runtime.close_thread = try std.Thread.spawn(.{}, Harness.complete, .{});
    task.runtime.close_completion.store(.closed, .release);
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
    try std.testing.expectEqual(TaskLifecycle.closing, taskLifecycle(task));
    try std.testing.expect(task.runtime.close_thread != null);
    try std.testing.expectError(error.TaskNotClosed, workbench.deleteTask(3));

    var queued_event = try testEnvelope(3, 7, "{\"text_chunk\":\"queued before terminal\"}");
    defer queued_event.deinit();
    try workbench.applyEvent(&queued_event);

    finalizeTestTerminalEvents(&workbench);
    try std.testing.expectEqual(TaskLifecycle.closed, taskLifecycle(task));
    try std.testing.expect(task.runtime.close_thread == null);

    var late_event = try testEnvelope(3, 7, "{\"text_chunk\":\"late\"}");
    defer late_event.deinit();
    try std.testing.expectError(error.UnknownTask, workbench.applyEvent(&late_event));
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

test "Workbench outcomes map to truthful terminal product phases" {
    try std.testing.expectEqual(RunPhase.completed, phaseForOutcome(.completed));
    try std.testing.expectEqual(RunPhase.stopped, phaseForOutcome(.stopped));
    try std.testing.expectEqual(RunPhase.cancelled, phaseForOutcome(.cancelled));
    try std.testing.expectEqual(RunPhase.interrupted, phaseForOutcome(.interrupted));
    try std.testing.expectEqual(RunPhase.failed, phaseForOutcome(.dependency_contract_failure));
}

test "OAuth operation remains excluded from every rebuilt Admission target" {
    var oauth_server: mcp_configuration.ServerWire = .{
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
            .consent = null,
            .grant = .{
                .consent_epoch = 3,
                .token_revision = 8,
                .access_token_ref = "oauth/access-8",
                .refresh_token_ref = "oauth/refresh-8",
                .expires_at_unix_ms = 1000,
            },
        } },
        .connection_approval = .{ .fingerprint = "approved" },
        .tools = &.{ "read", "write" },
    };
    const other: mcp_configuration.ServerWire = .{
        .id = "other",
        .namespace = "other",
        .display_name = "Other",
        .enabled = true,
        .negotiation = "automatic",
        .timeout_ms = 1000,
        .transport = .{ .kind = "stdio", .command = "tool" },
        .auth = .{ .kind = "none", .oauth = null },
        .connection_approval = .{ .fingerprint = "approved" },
        .tools = &.{"other.read"},
    };
    var servers = [_]mcp_configuration.ServerWire{ oauth_server, other };
    var registry: mcp_configuration.RegistryWire = .{
        .schema_version = 2,
        .generation = 7,
        .oauth_operation = .{
            .id = "refresh-1",
            .kind = "refresh",
            .server_id = "oauth",
            .connection_fingerprint = "approved",
            .consent_fingerprint = "consent",
            .consent_epoch = 3,
            .token_revision = 8,
        },
        .servers = &servers,
    };
    try std.testing.expectEqual(
        @as(usize, 0),
        mcpServerToolsForAdmission(registry, oauth_server).len,
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        mcpServerToolsForAdmission(registry, other).len,
    );
    registry.oauth_operation = null;
    try std.testing.expectEqual(
        @as(usize, 2),
        mcpServerToolsForAdmission(registry, oauth_server).len,
    );
    var oauth = oauth_server.auth.oauth.?;
    oauth.status = "reauth_required";
    oauth.grant = null;
    oauth_server.auth.oauth = oauth;
    try std.testing.expectEqual(
        @as(usize, 0),
        mcpServerToolsForAdmission(registry, oauth_server).len,
    );
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
        "\"availability\":\"ready\",\"managementHealth\":\"ready\",\"operation\":\"idle\",\"authorizationOperation\":{\"kind\":\"idle\"},\"desiredGeneration\":\"0\",\"runtimeAlignment\":\"current\",\"redacted\":false,\"servers\":[]",
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
    try std.testing.expectEqual(
        mcp_configuration.ManagementOutcome.saved,
        try workbench.recoverMcpOauthOperation(durable_id),
    );
    const oauth = workbench.mcp.?.management.?.desiredRegistry().?.servers[0].auth.oauth.?;
    try std.testing.expectEqualStrings("reauth_required", oauth.status);
    try std.testing.expect(workbench.finishMcpAuthorization(start.operation_id));
    try std.testing.expect(workbench.mcpAuthorizationOperation() == null);
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
        "\"availability\":\"degraded\",\"managementHealth\":\"ready\",\"operation\":\"idle\",\"authorizationOperation\":{\"kind\":\"idle\"},\"desiredGeneration\":\"9\",\"runtimeAlignment\":\"current\",\"redacted\":true",
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
        "\"managementHealth\":\"outcome_unknown\",\"operation\":\"idle\",\"authorizationOperation\":{\"kind\":\"idle\"},\"desiredGeneration\":null,\"runtimeAlignment\":\"unknown\",\"redacted\":false,\"servers\":[]",
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
        .arena = std.heap.ArenaAllocator.init(workbench.allocator),
        .allowlists = &.{},
        .build_admission = false,
    };
    workbench.mcp.?.refresh_request_generation = 1;
    workbench.mcp.?.refresh_job = blocked_job;
    try std.testing.expectError(
        error.CatalogLoading,
        workbench.createTaskInWorkspace(1, 1, 1, null, null),
    );
    workbench.mcp.?.activation_failed = false;
    blocked_job.outcome = .unavailable;
    blocked_job.state.store(.completed, .release);
    workbench.syncLifecycle();
    try std.testing.expect(workbench.mcp.?.refresh_job == null);
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
        .arena = std.heap.ArenaAllocator.init(workbench.allocator),
        .allowlists = &.{},
        .build_admission = false,
        .state = .init(.completed),
        .outcome = .unavailable,
    };
    workbench.mcp.?.activation_failed = false;
    workbench.mcp.?.refresh_request_generation = 3;
    workbench.mcp.?.refresh_job = stale_job;
    workbench.syncLifecycle();
    try std.testing.expect(!workbench.mcp.?.activation_failed);

    const cancelled_job = try workbench.allocator.create(McpRefreshJob);
    cancelled_job.* = .{
        .allocator = workbench.allocator,
        .runtime = workbench.agent_runtime,
        .notifier = .{},
        .request_generation = 4,
        .arena = std.heap.ArenaAllocator.init(workbench.allocator),
        .allowlists = &.{},
        .build_admission = false,
    };
    workbench.mcp.?.refresh_request_generation = 4;
    workbench.mcp.?.refresh_job = cancelled_job;
    cancelMcpRefreshJob(cancelled_job);
    workbench.shutting_down = true;
    workbench.syncLifecycle();
    try std.testing.expect(workbench.mcp.?.refresh_job == null);
}
