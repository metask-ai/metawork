//! MetaWork Agent Runtime over the bundle-owned typed SDK and ABI v1.
//! Core callbacks validate through the SDK, retain only Agent-owned data, and
//! feed a bounded sink. No callback calls WebView or registers desktop tools.

const std = @import("std");
const multimodal = @import("session/multimodal.zig");
const builtin = @import("builtin");
const sdk = @import("metask_agentcore");
const wire = sdk.types;
const event_pump = @import("event_pump");
const catalog = @import("agent_catalog");
const mcp_runtime = @import("agent_mcp_runtime");
const mcp_catalog = @import("agent_mcp_catalog");
const checkpoint = @import("agent_checkpoint");
const checkpoint_restore = @import("agent_checkpoint_restore");
const session_control = @import("session/control.zig");
const session_model_error = @import("session/model_error.zig");
const core_identity = @import("agentcore_identity");
const session_wire = @import("session/wire.zig");
const capabilities = @import("capabilities.zig");
const session_binding = @import("session/binding.zig");
const model_binding = @import("agent_model_binding");
const ModelBinding = model_binding.ModelBinding;
// Intentional same-module cycle: Runtime owns the runtime lifecycle while
// Session remains the composition root for the Session-bound domain object.
const session_runtime = @import("session/runtime.zig");
const image_generation = @import("image_generation.zig");
const generate_image = @import("generate_image.zig");
const deliver_file = @import("agent_file_delivery");
const mcp_install = @import("mcp_install.zig");
const image_http = @import("agent_http_transport");

pub const ImageGenerationTestOptions = struct {
    transport: image_http.Transport,
    limits: image_generation.Limits = .{},
};
pub const ImageGenerationTestBinding = image_generation.BindingInput;
pub const ImageGenerationOutput = image_generation.Output;
pub const ImageGenerationOutputResult = image_generation.OutputResult;
pub const ImageGenerationOutputFailure = image_generation.OutputFailure;
pub const ImageGenerationCancellation = image_http.Cancellation;
pub const ImageGenerationReceipt = image_generation.Receipt;
pub const ImageGenerationFormat = image_generation.Format;
pub const ImageGenerationLimits = image_generation.Limits;
pub const image_generation_limits = image_generation.production_limits;
/// Binding bytes are borrowed only through preparation. Effect contexts remain
/// borrowed through Run quiescence and are retained by the Host execution owner.
pub const ImageGenerationRunInput = struct {
    binding: image_generation.BindingInput,
    transport: image_http.Transport,
};
pub const ImageGenerationCredentialReader = image_generation.CredentialReader;

const RunImage = struct {
    binding: image_generation.OwnedBinding,
    transport: image_http.Transport,

    fn deinit(self: *RunImage, allocator: std.mem.Allocator) void {
        self.binding.deinit(allocator);
        self.* = undefined;
    }
};

pub const OwnedCoreEvent = event_pump.OwnedCoreEvent;
pub const FileDeliveryReceipt = deliver_file.Receipt;
pub const McpInstallRequest = mcp_install.InstallRequest;
pub const McpParsedInstallRequest = mcp_install.ParsedInstallRequest;
pub const parseMcpInstallRequest = mcp_install.parseInstallRequest;
pub const McpInstallationInput = mcp_install.Input;
pub const McpInstallationRequest = mcp_install.OwnedRequest;
pub const McpInstallationResult = mcp_install.Result;
pub const max_mcp_installation_bytes = mcp_install.max_bytes;
pub const FileDeliveryInput = deliver_file.Input;
pub const FileDeliveryInspection = deliver_file.Inspection;
pub const max_file_deliveries_per_run = deliver_file.max_receipts_per_run;
pub const MultimodalInputLimits = multimodal.InputLimits;
pub const multimodal_input_limits = multimodal.input_limits;
pub const Status = sdk.Status;
pub const StopReason = sdk.StopReason;
pub const HostFailure = session_control.HostFailure;
pub const TerminationEffect = session_control.TerminationEffect;
const UiRequest = sdk.UiRequest;
pub const PermissionChoice = sdk.protocol.PermissionChoice;
pub const PermissionDecision = sdk.protocol.PermissionDecision;
pub const PermissionDecisionSource = sdk.protocol.PermissionDecisionSource;
pub const PermissionCallbackOutcome = sdk.protocol.PermissionCallbackOutcome;
pub const PermissionProvenance = sdk.protocol.PermissionProvenance;
pub const PermissionToolNamespace = sdk.protocol.PermissionToolNamespace;

/// Trusted effects for the fixed Host tool, independent of model arguments.
/// A same-named MCP or built-in tool does not inherit this description.
pub fn hostToolPermissionContext(namespace: PermissionToolNamespace, name: []const u8) ?[]const u8 {
    if (namespace != .host) return null;
    if (std.mem.eql(u8, name, generate_image.name)) return generate_image.description;
    if (std.mem.eql(u8, name, deliver_file.name)) return deliver_file.description;
    if (std.mem.eql(u8, name, mcp_install.name)) return mcp_install.description;
    return null;
}
pub const RunState = sdk.protocol.RunState;
pub const RunStatePhase = sdk.protocol.RunStatePhase;
pub const CatalogHealth = catalog.Health;
pub const CatalogIssueCode = catalog.IssueCode;
pub const CatalogIssueKind = catalog.IssueKind;
pub const CatalogResourceReason = catalog.ResourceReason;
pub const CatalogSourceScope = catalog.SourceScope;
pub const CatalogIssue = catalog.Issue;
pub const CatalogSkill = catalog.Skill;
pub const CatalogProjection = catalog.Projection;
pub const CatalogLease = catalog.Lease;
pub const CatalogAcquisition = catalog.Acquisition;
pub const CatalogQuery = catalog.Query;
pub const CatalogSourceLifetime = catalog.SourceLifetime;
pub const CatalogSource = catalog.Source;
pub const CatalogQueryTarget = catalog.QueryTarget;
pub const McpCatalogProjection = mcp_catalog.Projection;
pub const McpCatalogServer = mcp_catalog.Server;
pub const McpCatalogTool = mcp_catalog.Tool;
pub const McpCatalogIssue = mcp_catalog.Issue;
pub const McpSelection = mcp_catalog.Selection;
pub const McpRestoreSelection = mcp_catalog.RestoreSelection;
pub const McpSelector = mcp_catalog.Selector;
pub const McpServerAllowlist = mcp_catalog.ServerAllowlist;
pub const McpActivation = mcp_catalog.Activation;
pub const McpActivationState = mcp_catalog.ActivationState;
pub const McpActivationServer = mcp_catalog.ActivationServer;
pub const McpActivationTool = mcp_catalog.ActivationTool;
pub const McpActivationServerState = mcp_catalog.ActivationServerState;
pub const McpRuntimeInput = mcp_runtime.Input;
pub const McpServerInput = mcp_runtime.ServerInput;
pub const McpTransportKind = mcp_runtime.TransportKind;
pub const McpNegotiationPolicy = mcp_runtime.NegotiationPolicy;
pub const mcpBindingIdentity = mcp_runtime.bindingIdentity;

pub const SessionState = session_control.SessionState;
pub const ExternalInterruption = session_control.ExternalInterruption;
pub const CallbackFailure = session_control.CallbackFailure;
pub const EventPumpFailure = session_control.EventPumpFailure;
pub const EventConsumerNotificationFailure = session_control.EventConsumerNotificationFailure;
pub const TerminationSignal = session_control.TerminationSignal;
pub const TerminalFailure = session_control.TerminalFailure;
pub const SessionDisposition = session_control.SessionDisposition;
pub const DurableBudgetObservation = session_control.DurableBudgetObservation;
pub const TerminalResult = session_control.TerminalResult;
pub const TerminalReceipts = session_control.TerminalReceipts;
pub const tool_route_digest_bytes = session_control.tool_route_digest_bytes;
pub const toolRouteDigest = session_control.toolRouteDigest;
pub const ModelError = session_control.ModelError;
pub const CallbackRejection = session_control.CallbackRejection;
pub const CoreEventKind = session_control.CoreEventKind;
pub const core_manifest_sha256 = core_identity.manifest_sha256;
pub const InputCounts = session_control.InputCounts;
pub const InputObservation = session_control.InputObservation;
pub const InputRejection = session_control.InputRejection;
pub const InputSubmission = session_control.InputSubmission;
pub const max_submitted_inputs: usize = @intCast(wire.MAX_SUBMITTED_INPUTS_V1);
pub const max_submitted_input_bytes: usize = @intCast(wire.MAX_SUBMITTED_INPUT_BYTES_V1);
pub const CompactOutcome = session_control.CompactOutcome;
pub const CompactTerminalResult = session_control.CompactTerminalResult;
pub const TerminationRequestResult = session_control.TerminationRequestResult;
pub const EventReadyNotification = session_control.EventReadyNotification;
pub const EventReadyNotifier = session_control.EventReadyNotifier;
pub const Protocol = @import("agent_protocol").Protocol;
pub const PermissionMode = session_control.PermissionMode;
pub const ShellPolicy = session_control.ShellPolicy;

pub const PermissionModeUpdate = struct {
    changed: bool,
    policy_generation: u64,
};

pub const PermissionInteraction = enum {
    interactive,
    noninteractive,
};

pub const PermissionRequest = sdk.PermissionRequest;
pub const ParsedPermissionRequest = session_wire.ParsedPermissionRequest;
pub const decodePermissionRequest = session_wire.decodePermissionRequest;
const decodeUiRequest = session_wire.decodeUiRequest;
pub const decodeCoreEvent = session_wire.decodeCoreEvent;
const permissionModeCode = session_wire.permissionModeCode;
const shellPolicyCode = session_wire.shellPolicyCode;
pub const RunControl = session_binding.RunControl;
pub const RunControlLease = session_binding.RunControlLease;
const SessionControlBlock = session_binding.SessionControlBlock;
pub const Runtime = session_runtime.Runtime;

pub const McpActivationUnavailableReason = enum {
    refresh_failed,
    refresh_rejected,
    invalid_catalog,
    resource_limit,
    generation_mismatch,
    binding_mismatch,
    invalid_selection,
};

pub const McpActivationOutcome = union(enum) {
    empty,
    activated: *McpActivation,
    unavailable: McpActivationUnavailableReason,
};

pub const McpConfigurationApplyOutcome = enum {
    applied,
    superseded,
    rejected,
};

pub const CheckpointLimits = checkpoint.Limits;
pub const CheckpointSink = checkpoint.Sink;
pub const CheckpointSinkWriteResult = checkpoint.SinkWriteResult;
pub const CheckpointOutcome = checkpoint.Outcome;
pub const CheckpointSuccess = checkpoint.Success;
pub const CheckpointFailure = checkpoint.Failure;
pub const CheckpointFailureReason = checkpoint.FailureReason;
pub const CheckpointDescription = checkpoint.Description;
pub const CheckpointLogicalSessionOrigin = checkpoint.LogicalSessionOrigin;
pub const CheckpointSessionLifecycle = checkpoint.SessionLifecycle;
pub const CheckpointDurableBudgetOutcome = checkpoint.DurableBudgetOutcome;
pub const CheckpointRestoreHealth = checkpoint.RestoreHealth;
pub const CheckpointSource = checkpoint_restore.Source;
pub const CheckpointSourceReadResult = checkpoint_restore.SourceReadResult;
pub const CheckpointRestoreExpectation = checkpoint_restore.Expectation;
pub const CheckpointRestoreReport = checkpoint_restore.Report;

pub const SessionRoute = struct {
    id: u64,
    session: *Session,
};

pub const BeginRunFailure = struct {
    err: Error,
    session_disposition: SessionDisposition,
};

pub const BeginRunOutcome = union(enum) {
    run: Run,
    failure: BeginRunFailure,
};

pub const CloseOutcome = union(enum) {
    closed,
    failure: struct {
        err: Error,
        session_disposition: SessionDisposition,
    },
};

/// The unique execution owner returned by `Session.beginRun`. This is a linear
/// value and must execute and deinitialize exactly once.
pub const Run = struct {
    session: *Session,
    run_id: u64,
    generation: u64,
    base_lease: RunControlLease,
    executed: bool = false,

    pub fn control(self: *const Run) RunControl {
        return .{
            .block = self.base_lease.block,
            .run_id = self.run_id,
            .generation = self.generation,
        };
    }

    pub fn execute(self: *Run) TerminalResult {
        std.debug.assert(!self.executed);
        self.executed = true;
        return self.session.executeBegunRun(self.run_id, self.generation);
    }

    pub fn deinit(self: *Run) void {
        std.debug.assert(self.executed);
        self.base_lease.deinit();
        self.* = undefined;
    }
};

pub const WorkspaceTrust = union(enum) {
    temporary: []const u8,
    explicitly_trusted,
};

pub const WorkspaceInput = struct {
    canonical_root: []const u8,
    trust: WorkspaceTrust,
};

pub const InputPart = multimodal.InputPart;
pub const ImageFormat = multimodal.ImageFormat;

pub const RunInput = union(enum) {
    /// Ordered borrowed blocks, copied/encoded before prepareRun returns.
    multimodal: []const InputPart,
    text: []const u8,
    skill: struct {
        skill_id: []const u8,
        catalog_revision: []const u8,
        argument_values: []const []const u8,
    },
};

const OwnedRunInput = union(enum) {
    multimodal: multimodal.OwnedInput,
    text: []u8,
    skill: struct {
        skill_id: []u8,
        catalog_revision: []u8,
        argument_values: [][]const u8,
        encoding_scratch: []u8,
    },

    fn init(
        allocator: std.mem.Allocator,
        input: RunInput,
        max_input_bytes: usize,
        input_budget: *multimodal.Budget,
    ) (Error || std.mem.Allocator.Error)!OwnedRunInput {
        return switch (input) {
            .multimodal => |parts| .{ .multimodal = try multimodal.OwnedInput.init(allocator, parts, max_input_bytes, input_budget) },
            .text => |text| {
                if (text.len > max_input_bytes) return error.RunInputTooLarge;
                if (!std.unicode.utf8ValidateSlice(text))
                    return error.InvalidRunInput;
                return .{ .text = try allocator.dupe(u8, text) };
            },
            .skill => |skill| {
                if (skill.skill_id.len == 0 or skill.catalog_revision.len == 0 or
                    !std.unicode.utf8ValidateSlice(skill.skill_id) or
                    !std.unicode.utf8ValidateSlice(skill.catalog_revision) or
                    skill.argument_values.len > sdk.protocol.MAX_SKILL_ARGUMENT_VALUES_V1)
                    return error.InvalidRunInput;
                var total = std.math.add(
                    usize,
                    skill.skill_id.len,
                    skill.catalog_revision.len,
                ) catch return error.RunInputTooLarge;
                for (skill.argument_values) |value| {
                    if (!std.unicode.utf8ValidateSlice(value))
                        return error.InvalidRunInput;
                    total = std.math.add(usize, total, value.len) catch
                        return error.RunInputTooLarge;
                    if (total > max_input_bytes) return error.RunInputTooLarge;
                }

                const skill_id = try allocator.dupe(u8, skill.skill_id);
                errdefer allocator.free(skill_id);
                const revision = try allocator.dupe(
                    u8,
                    skill.catalog_revision,
                );
                errdefer allocator.free(revision);
                const values = try allocator.alloc(
                    []const u8,
                    skill.argument_values.len,
                );
                errdefer allocator.free(values);
                var initialized: usize = 0;
                errdefer for (values[0..initialized]) |value|
                    allocator.free(value);
                for (skill.argument_values, values) |value, *copy| {
                    copy.* = try allocator.dupe(u8, value);
                    initialized += 1;
                }
                const scratch = try allocator.alloc(
                    u8,
                    sdk.protocol.MAX_SKILL_ARGUMENT_JSON_BYTES_V1,
                );
                errdefer {
                    secureZero(scratch);
                    allocator.free(scratch);
                }
                var fixed = std.heap.FixedBufferAllocator.init(scratch);
                const encoded = sdk.encodeSkillArguments(
                    fixed.allocator(),
                    values,
                ) catch |err| switch (err) {
                    error.InvalidArguments => return error.InvalidRunInput,
                    error.ResourceLimit => return error.RunInputTooLarge,
                    error.OutOfMemory => return error.RunInputTooLarge,
                };
                fixed.allocator().free(encoded);
                secureZero(scratch);
                return .{ .skill = .{
                    .skill_id = skill_id,
                    .catalog_revision = revision,
                    .argument_values = values,
                    .encoding_scratch = scratch,
                } };
            },
        };
    }

    fn deinit(self: *OwnedRunInput, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .multimodal => |*parts| parts.deinit(allocator),
            .text => |text| allocator.free(text),
            .skill => |skill| {
                allocator.free(skill.skill_id);
                allocator.free(skill.catalog_revision);
                for (skill.argument_values) |value| allocator.free(value);
                allocator.free(skill.argument_values);
                secureZero(skill.encoding_scratch);
                allocator.free(skill.encoding_scratch);
            },
        }
        self.* = undefined;
    }
};

pub const OperationIdFloor = struct {
    last_run_id: u64 = 0,
    last_compact_id: u64 = 0,
    last_ui_request_id: u64 = 0,
};

pub const SessionOpenOptions = struct {
    model_binding: ModelBinding,
    permission_mode: PermissionMode,
    shell_policy: ShellPolicy,
    permission_interaction: PermissionInteraction = .interactive,
    workspace: WorkspaceInput,
    canonical_user_home: []const u8 = "",
    workspace_epoch: []const u8 = "",
    skill_catalog: ?*CatalogLease = null,
    skill_policy: ?SkillPolicyInput = null,
    mcp_selection: ?*const McpSelection = null,
    /// Product history may contain operations intentionally excluded from the
    /// Conversation checkpoint. They still consume public operation ids.
    operation_id_floor: OperationIdFloor = .{},
};

pub const SkillPolicyInput = struct {
    granted_skill_ids: []const []const u8 = &.{},
};

/// The handle and exact default-deny grant set remain in the Agent owner.
/// A captured copy shares the original immutable catalog lease, not a query
/// of today's global catalog. Each copy must be consumed by deinit.
pub const SkillRestoreInputs = opaque {
    pub fn init(runtime: *Runtime, lease: *CatalogLease, policy: SkillPolicyInput) (Error || std.mem.Allocator.Error)!*SkillRestoreInputs {
        if (!catalog.belongsTo(lease, runtime)) return error.CatalogBindingMismatch;
        const storage = try runtime.allocator.create(SkillRestoreStorage);
        errdefer runtime.allocator.destroy(storage);
        storage.* = .{ .runtime = runtime, .lease = lease, .arena = std.heap.ArenaAllocator.init(runtime.allocator), .ids = &.{} };
        errdefer storage.arena.deinit();
        const allocator = storage.arena.allocator();
        const ids = try allocator.alloc([]const u8, policy.granted_skill_ids.len);
        for (policy.granted_skill_ids, ids) |id, *target| target.* = try allocator.dupe(u8, id);
        storage.ids = ids;
        try catalog.retain(lease);
        return @ptrCast(storage);
    }

    pub fn borrow(self: *const SkillRestoreInputs) struct { catalog: *CatalogLease, policy: SkillPolicyInput } {
        const storage: *const SkillRestoreStorage = @ptrCast(@alignCast(self));
        return .{ .catalog = storage.lease, .policy = .{ .granted_skill_ids = storage.ids } };
    }

    pub fn clone(self: *const SkillRestoreInputs) (Error || std.mem.Allocator.Error)!*SkillRestoreInputs {
        const storage: *const SkillRestoreStorage = @ptrCast(@alignCast(self));
        return init(storage.runtime, storage.lease, .{ .granted_skill_ids = storage.ids });
    }

    /// A current Host policy may revoke original grants, never add a grant or
    /// replace the original catalog with a broader one.
    pub fn narrow(self: *const SkillRestoreInputs, ceiling: SkillPolicyInput) (Error || std.mem.Allocator.Error)!*SkillRestoreInputs {
        const storage: *const SkillRestoreStorage = @ptrCast(@alignCast(self));
        const ids = try storage.runtime.allocator.alloc([]const u8, storage.ids.len);
        defer storage.runtime.allocator.free(ids);
        var count: usize = 0;
        for (storage.ids) |id| {
            const allowed = for (ceiling.granted_skill_ids) |candidate| {
                if (std.mem.eql(u8, id, candidate)) break true;
            } else false;
            if (allowed) {
                ids[count] = id;
                count += 1;
            }
        }
        return init(storage.runtime, storage.lease, .{ .granted_skill_ids = ids[0..count] });
    }

    /// Consumes this copy even if the final Core catalog release fails.
    pub fn deinit(self: *SkillRestoreInputs) Error!void {
        const storage: *SkillRestoreStorage = @ptrCast(@alignCast(self));
        const allocator = storage.runtime.allocator;
        defer allocator.destroy(storage);
        defer storage.arena.deinit();
        try storage.runtime.releaseSkillCatalog(storage.lease);
    }
};

const SkillRestoreStorage = struct {
    runtime: *Runtime,
    lease: *CatalogLease,
    arena: std.heap.ArenaAllocator,
    ids: []const []const u8,
};

pub const SessionRestoreInputs = struct {
    skill: ?*SkillRestoreInputs,
    mcp: ?*McpRestoreSelection,
    permission_mode: PermissionMode,
    shell_policy: ShellPolicy,
    permission_interaction: PermissionInteraction,

    pub fn deinit(self: *SessionRestoreInputs) Error!void {
        defer self.* = undefined;
        if (self.mcp) |selection| selection.deinit();
        if (self.skill) |inputs| try inputs.deinit();
    }
};

pub const SessionRestoreOptions = struct {
    session: SessionOpenOptions,
    checkpoint_limits: CheckpointLimits,
    source: CheckpointSource,
    expectation: CheckpointRestoreExpectation,
};

pub const SessionRestoreRoute = struct {
    id: u64,
    session: *Session,
    report: CheckpointRestoreReport,
};

const default_event_limits: event_pump.Limits = .{ .session_slots = 1 };
pub const Limits = struct {
    max_sessions: usize,
    /// Consumed exactly once during successful Agent Runtime construction.
    /// Build this input before Runtime init so attributable MCP preparation
    /// failures can select the ordinary empty Runtime path.
    mcp_input: ?*McpRuntimeInput = null,
    max_prompt_bytes: usize = 1024 * 1024,
    /// Runtime-wide owned parts and encoded bytes, including concurrent prepareRun calls.
    max_multimodal_input_bytes: usize = 64 * 1024 * 1024,
    event_capacity: usize = 512,
    event_bytes: usize = default_event_limits.global_bytes,
    per_session_event_capacity: usize = 128,
    per_session_event_bytes: usize = default_event_limits.per_session_bytes,
    control_reserved_capacity: usize = 64,
    control_reserved_bytes: usize = 2 * 1024 * 1024,
    per_session_control_reserved_capacity: usize = 16,
    per_session_control_reserved_bytes: usize = 512 * 1024,
    max_event_bytes: usize = default_event_limits.max_event_bytes,
    max_ui_request_bytes: usize = 256 * 1024,
    max_ui_response_bytes: usize = 256 * 1024,
    max_terminal_diagnostic_bytes: usize = 512,
    event_ready_notifier: ?EventReadyNotifier = null,
};

pub const SessionSnapshot = struct {
    session_id: u64,
    state: SessionState,
    workspace_root: []const u8,
    active_run_id: u64,
    active_compact_id: u64,
    pending_ui_request_id: ?u64,
    input: InputObservation = .{},
};

pub const PendingUiRequest = struct {
    session_id: u64,
    run_id: u64,
    request_id: u64,
    input_adopted_count: u32 = 0,
    json: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *PendingUiRequest) void {
        self.allocator.free(self.json);
        self.* = undefined;
    }
};

pub const Error = error{
    InvalidLimits,
    InvalidWorkspace,
    WorkspaceNotTrusted,
    InvalidCatalogQuery,
    InvalidCatalogDescriptor,
    DuplicateCatalogIdentity,
    SkillCatalogInvalid,
    SkillCatalogIncomplete,
    CatalogResourceLimit,
    CatalogReleaseFailed,
    CatalogLeasesOutstanding,
    CatalogBindingMismatch,
    InvalidSkillPolicy,
    CatalogRefreshFailed,
    McpRefreshFailed,
    McpRefreshRejected,
    InvalidMcpCatalogDescriptor,
    McpCatalogResourceLimit,
    McpCatalogGenerationMismatch,
    McpCatalogBindingMismatch,
    InvalidMcpSelection,
    StaleMcpSelection,
    McpRestoreSourceChanged,
    McpRefreshInProgress,
    McpConfigurationApplyFailed,
    McpConfigurationApplyUncertain,
    McpConfigurationApplyLimit,
    McpNotRefreshed,
    McpCheckpointBudgetRequired,
    McpSelectionUpdateFailed,
    McpRuntimeIdentityExhausted,
    RuntimeShuttingDown,
    SessionCapacity,
    UnknownSession,
    SessionNotClosed,
    CoreCallFailed,
    PermissionModeUpdateFailed,
    PermissionModeBudgetRequired,
    QueueFull,
    SessionNotIdle,
    SessionPoisoned,
    SessionClosing,
    InvalidRunInput,
    InvalidCredential,
    CredentialUpdateFailed,
    CredentialUpdateResourceLimit,
    CredentialUpdateContract,
    RunInputTooLarge,
    RunInputBudgetExceeded,
    RunIdExhausted,
    RunGenerationExhausted,
    CompactIdExhausted,
    SessionIdExhausted,
    NoSuchRun,
    NoSuchCompact,
    NoPendingUiRequest,
    StaleUiResponse,
    InvalidUiResponse,
    StateNotReached,
    SessionDestroyFailed,
    RuntimeDestroyFailed,
    RestoreInvalid,
    RestoreBusy,
    RestoreFailed,
    RestoreCancelled,
    RestoreIoFailed,
    RestoreContractFailed,
    CheckpointCorrupt,
    CheckpointUnsupported,
    CheckpointIncompatible,
    LogicalSessionConflict,
};

const max_core_session_id_bytes: usize = @intCast(wire.MAX_SESSION_ID_BYTES_V1);

pub const CoreSessionIdentity = union(enum) {
    unbound,
    bound: struct {
        len: usize,
        bytes: [max_core_session_id_bytes]u8,
    },
    failed,
};

pub const Session = struct {
    agent_runtime: *Runtime,
    image_fixture_binding: ?image_generation.OwnedBinding = null,
    run_image: ?RunImage = null,
    image_sends: usize = 0,
    image_receipts: [image_generation.production_limits.sends_per_run]?image_generation.Receipt = @splat(null),
    matched_image_receipts: [image_generation.production_limits.sends_per_run]?[tool_route_digest_bytes]u8 = @splat(null),
    image_calls: [image_generation.max_active_calls]?*image_generation.Call = @splat(null),
    run_delivery: ?FileDeliveryInput = null,
    run_mcp_installation: ?McpInstallationInput = null,
    delivery_attempts: usize = 0,
    delivery_receipts: [deliver_file.max_receipts_per_run]?FileDeliveryReceipt = @splat(null),
    matched_delivery_receipts: [deliver_file.max_receipts_per_run]bool = @splat(false),
    delivery_calls: [deliver_file.max_active_calls]?*std.atomic.Value(bool) = @splat(null),
    id: u64,
    provider_id: []u8,
    protocol: Protocol,
    raw: ?*wire.SessionHandle = null,
    workspace_root: []u8,
    workspace_home: []u8,
    workspace_epoch: []u8,
    control_block: *SessionControlBlock,
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    state: SessionState = .idle,
    next_run_id: u64 = 0,
    next_run_generation: u64 = 0,
    active_run_id: u64 = 0,
    active_run_generation: u64 = 0,
    next_compact_id: u64 = 0,
    active_compact_id: u64 = 0,
    compact_started: bool = false,
    compact_done: bool = true,
    compact_cancel_requested: bool = false,
    compact_interruption: ?ExternalInterruption = null,
    compact_abort_status: ?sdk.Status = null,
    raw_compact_abort_status_code: ?u32 = null,
    compact_terminal_diagnostic: ?[]u8 = null,
    compact_terminal_diagnostic_len: usize = 0,
    compact_terminal_diagnostic_truncated: bool = false,
    run_started: bool = false,
    core_call_in_progress: bool = false,
    abort_calls_in_progress: usize = 0,
    credential_updates_in_progress: usize = 0,
    input_calls_in_progress: usize = 0,
    input_ready: bool = false,
    input_window_started: bool = false,
    submitted_inputs: session_control.SubmittedInputs = .{},
    input_counts: ?InputCounts = null,
    run_done: bool = true,
    run_input: ?OwnedRunInput = null,
    terminal_diagnostic: ?[]u8 = null,
    terminal_diagnostic_len: usize = 0,
    terminal_diagnostic_truncated: bool = false,
    model_error: ?ModelError = null,
    output_segment: ?struct { index: u32, turn: u32, group: u32, bytes: u64 = 0 } = null,
    last_output_index: ?u32 = null,
    terminal_phase: ?RunStatePhase = null,
    callback_fatal_observed: bool = false,
    termination_signal: ?TerminationSignal = null,
    first_callback_rejection: ?CallbackRejection = null,
    first_host_failure: ?HostFailure = null,
    controlled_callback_close: ?ExternalInterruption = null,
    close_interruption: ExternalInterruption = .session_close,
    abort_status: ?sdk.Status = null,
    raw_abort_status_code: ?u32 = null,
    abort_retry_pending: bool = false,
    abort_retried_after_start: bool = false,
    dependency_contract_failure: bool = false,
    file_changes_lost: std.atomic.Value(bool) = .init(false),
    event_delivery_stopped: std.atomic.Value(bool) = .init(false),
    event_delivery_lost: std.atomic.Value(bool) = .init(false),
    permission_interaction: PermissionInteraction = .interactive,
    shell_policy: ShellPolicy = .disabled,
    permission_stop_requested: bool = false,
    skill_restore_inputs: ?*SkillRestoreInputs = null,
    mcp_restore_selection: ?*McpRestoreSelection = null,
    core_session_identity: CoreSessionIdentity = .unbound,
    cancel_requested: bool = false,
    active_refs: usize = 0,
    active_callback_refs: usize = 0,
    ui_active: bool = false,
    ui_request_id: u64 = 0,
    ui_input_adopted_count: u32 = 0,
    ui_answered: bool = false,
    ui_request_json: ?[]u8 = null,
    ui_request_value: ?*const sdk.UiRequest = null,
    ui_response_json: ?[]u8 = null,
    close_finished: bool = false,
    close_failed: bool = false,

    pub fn lock(self: *Session) void {
        self.mutex.lockUncancelable(self.agent_runtime.io);
    }

    pub fn unlock(self: *Session) void {
        self.mutex.unlock(self.agent_runtime.io);
    }

    fn wait(self: *Session) void {
        self.condition.waitUncancelable(self.agent_runtime.io, &self.mutex);
    }

    pub fn broadcast(self: *Session) void {
        self.condition.broadcast(self.agent_runtime.io);
    }

    /// Prepares an Agent Run after caller-owned admission. The caller owns queueing
    /// and must call exactly one of `beginRun` or `cancelPreparedRun`.
    pub fn prepareRun(
        self: *Session,
        input: RunInput,
    ) (Error || std.mem.Allocator.Error)!u64 {
        var image: ?RunImage = image: {
            self.lock();
            defer self.unlock();
            const fixture = if (self.image_fixture_binding) |*value| value else break :image null;
            break :image .{
                .binding = fixture.clone(self.agent_runtime.allocator) catch |err|
                    return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidRunInput,
                .transport = self.agent_runtime.image_test.?.transport,
            };
        };
        defer if (image) |*value| value.deinit(self.agent_runtime.allocator);
        return self.prepareRunOwnedTools(input, &image, null, null);
    }

    /// Freeze one Host-resolved image configuration with the Run. A null input
    /// explicitly means unavailable; no Session fixture/default is consulted.
    pub fn prepareRunWithTools(
        self: *Session,
        input: RunInput,
        image_input: ?ImageGenerationRunInput,
        delivery_input: ?FileDeliveryInput,
        mcp_input: ?McpInstallationInput,
    ) (Error || std.mem.Allocator.Error)!u64 {
        var image: ?RunImage = if (image_input) |value| .{
            .binding = image_generation.OwnedBinding.init(self.agent_runtime.allocator, value.binding) catch |err|
                return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidRunInput,
            .transport = value.transport,
        } else null;
        defer if (image) |*value| value.deinit(self.agent_runtime.allocator);
        return self.prepareRunOwnedTools(input, &image, delivery_input, mcp_input);
    }

    fn prepareRunOwnedTools(self: *Session, input: RunInput, image: *?RunImage, delivery: ?FileDeliveryInput, mcp_input: ?McpInstallationInput) (Error || std.mem.Allocator.Error)!u64 {
        var owned_input = try OwnedRunInput.init(
            self.agent_runtime.allocator,
            input,
            self.agent_runtime.max_prompt_bytes,
            &self.agent_runtime.multimodal_input_budget,
        );
        errdefer owned_input.deinit(self.agent_runtime.allocator);
        const terminal_diagnostic = try self.agent_runtime.allocator.alloc(
            u8,
            self.agent_runtime.max_terminal_diagnostic_bytes,
        );
        errdefer self.agent_runtime.allocator.free(terminal_diagnostic);
        self.lock();
        if (self.agent_runtime.shutting_down.load(.acquire)) {
            self.unlock();
            return error.RuntimeShuttingDown;
        }
        if (self.state == .closing or self.state == .closed) {
            self.unlock();
            return error.SessionClosing;
        }
        if (self.state == .poisoned) {
            self.unlock();
            return error.SessionPoisoned;
        }
        if (self.state != .idle) {
            self.unlock();
            return error.SessionNotIdle;
        }
        if (self.next_run_id == std.math.maxInt(u64)) {
            self.unlock();
            return error.RunIdExhausted;
        }
        if (self.next_run_generation == std.math.maxInt(u64)) {
            self.unlock();
            return error.RunGenerationExhausted;
        }
        // An idle Session must have completely quiesced the previous Run. Do
        // not reset these fields here: that would hide an unmatched abort or
        // an incomplete terminal transition.
        std.debug.assert(self.run_done);
        std.debug.assert(!self.run_started);
        std.debug.assert(!self.core_call_in_progress);
        std.debug.assert(self.abort_calls_in_progress == 0);
        std.debug.assert(self.input_calls_in_progress == 0);
        for (self.image_calls) |call| std.debug.assert(call == null);
        for (self.delivery_calls) |call| std.debug.assert(call == null);
        std.debug.assert(self.run_delivery == null);
        std.debug.assert(self.run_image == null);
        self.run_image = image.*;
        image.* = null;
        self.image_sends = 0;
        @memset(&self.image_receipts, null);
        @memset(&self.matched_image_receipts, null);
        self.run_delivery = delivery;
        self.run_mcp_installation = mcp_input;
        self.delivery_attempts = 0;
        @memset(&self.delivery_receipts, null);
        @memset(&self.matched_delivery_receipts, false);
        self.input_ready = false;
        self.input_window_started = false;
        self.submitted_inputs = .{};
        self.input_counts = null;
        self.next_run_id += 1;
        self.next_run_generation += 1;
        const run_id = self.next_run_id;
        self.active_run_id = run_id;
        self.active_run_generation = self.next_run_generation;
        self.run_started = false;
        self.core_call_in_progress = false;
        self.run_done = false;
        self.run_input = owned_input;
        self.terminal_diagnostic = terminal_diagnostic;
        self.terminal_diagnostic_len = 0;
        self.terminal_diagnostic_truncated = false;
        self.model_error = null;
        self.output_segment = null;
        self.last_output_index = null;
        self.terminal_phase = null;
        self.callback_fatal_observed = false;
        self.termination_signal = null;
        self.first_callback_rejection = null;
        self.first_host_failure = null;
        self.controlled_callback_close = null;
        self.abort_status = null;
        self.raw_abort_status_code = null;
        self.abort_retry_pending = false;
        self.abort_retried_after_start = false;
        self.dependency_contract_failure = false;
        self.file_changes_lost.store(false, .release);
        self.event_delivery_stopped.store(false, .release);
        self.event_delivery_lost.store(false, .release);
        self.permission_stop_requested = false;
        self.cancel_requested = false;
        self.state = .queued;
        self.unlock();
        return run_id;
    }

    /// Installs the generation-checked termination control and transfers
    /// execution ownership from the caller to Agent. A successful call must be
    /// followed by exactly one `Run.execute` and `Run.deinit`.
    pub fn beginRun(self: *Session, run_id: u64) Error!Run {
        return switch (self.beginRunOutcome(run_id)) {
            .run => |run| run,
            .failure => |failure| failure.err,
        };
    }

    /// Typed worker handoff. Failure and disposition are captured under the
    /// same Session lock, before a concurrent close can destroy the Session.
    pub fn beginRunOutcome(self: *Session, run_id: u64) BeginRunOutcome {
        self.lock();
        if (run_id == 0 or run_id != self.active_run_id) {
            const failure = BeginRunFailure{
                .err = error.NoSuchRun,
                .session_disposition = self.dispositionLocked(),
            };
            self.unlock();
            return .{ .failure = failure };
        }
        if (self.state != .queued) {
            const begin_error: Error = switch (self.state) {
                .poisoned => error.SessionPoisoned,
                .closing, .closed => error.SessionClosing,
                .idle, .running, .waiting_ui, .queued, .compact_queued, .compacting, .checkpointing => error.NoSuchRun,
            };
            if ((self.state == .closing or self.state == .closed) and !self.run_done and
                !self.run_started)
                self.finishPreparedRunLocked();
            const failure = BeginRunFailure{
                .err = begin_error,
                .session_disposition = self.dispositionLocked(),
            };
            self.unlock();
            return .{ .failure = failure };
        }
        const generation = self.active_run_generation;
        std.debug.assert(generation != 0);
        const retained = self.control_block.tryRetain();
        std.debug.assert(retained);
        self.state = .running;
        self.run_started = true;
        self.core_call_in_progress = false;
        self.broadcast();
        self.unlock();
        _ = self.agent_runtime.notifyEventConsumer();
        return .{ .run = .{
            .session = self,
            .run_id = run_id,
            .generation = generation,
            .base_lease = .{
                .block = self.control_block,
                .run_id = run_id,
                .generation = generation,
            },
        } };
    }

    pub fn cancelPreparedRun(self: *Session, run_id: u64) Error!void {
        self.lock();
        if (run_id == 0 or run_id != self.active_run_id or self.state != .queued) {
            self.unlock();
            return error.NoSuchRun;
        }
        self.finishPreparedRunLocked();
        self.unlock();
        _ = self.agent_runtime.notifyEventConsumer();
    }

    /// Reserves the Session's single operation slot for a caller-owned manual
    /// compact. The caller must either execute or cancel the reservation.
    pub fn prepareCompact(self: *Session) (Error || std.mem.Allocator.Error)!u64 {
        const diagnostic = try self.agent_runtime.allocator.alloc(
            u8,
            self.agent_runtime.max_terminal_diagnostic_bytes,
        );
        errdefer self.agent_runtime.allocator.free(diagnostic);
        self.lock();
        defer self.unlock();
        if (self.agent_runtime.shutting_down.load(.acquire))
            return error.RuntimeShuttingDown;
        if (self.credential_updates_in_progress != 0) return error.SessionNotIdle;
        switch (self.state) {
            .idle => {},
            .poisoned => return error.SessionPoisoned,
            .closing, .closed => return error.SessionClosing,
            .queued, .running, .waiting_ui, .compact_queued, .compacting, .checkpointing => return error.SessionNotIdle,
        }
        if (self.next_compact_id == std.math.maxInt(u64))
            return error.CompactIdExhausted;
        std.debug.assert(self.run_done);
        std.debug.assert(self.compact_done);
        std.debug.assert(!self.core_call_in_progress);
        std.debug.assert(self.abort_calls_in_progress == 0);
        self.next_compact_id += 1;
        self.active_compact_id = self.next_compact_id;
        self.compact_started = false;
        self.compact_done = false;
        self.compact_cancel_requested = false;
        self.compact_interruption = null;
        self.compact_abort_status = null;
        self.raw_compact_abort_status_code = null;
        self.compact_terminal_diagnostic = diagnostic;
        self.compact_terminal_diagnostic_len = 0;
        self.compact_terminal_diagnostic_truncated = false;
        self.dependency_contract_failure = false;
        self.state = .compact_queued;
        return self.active_compact_id;
    }

    pub fn cancelPreparedCompact(self: *Session, operation_id: u64) Error!void {
        self.lock();
        defer self.unlock();
        if (operation_id == 0 or operation_id != self.active_compact_id or
            self.state != .compact_queued)
            return error.NoSuchCompact;
        self.finishPreparedCompactLocked();
    }

    /// Called only by an executor worker after successful caller admission.
    pub fn executePreparedCompact(
        self: *Session,
        operation_id: u64,
    ) Error!CompactTerminalResult {
        self.lock();
        if (operation_id == 0 or operation_id != self.active_compact_id or
            self.state != .compact_queued)
        {
            self.unlock();
            return error.NoSuchCompact;
        }
        self.state = .compacting;
        self.compact_started = true;
        self.broadcast();
        if (self.compact_cancel_requested) {
            const terminal = self.finishCompactBeforeCoreCallLocked();
            self.unlock();
            return terminal;
        }
        self.core_call_in_progress = true;
        self.unlock();

        var result = std.mem.zeroes(wire.CompactResultV1);
        var diagnostic = emptyOwnedBytes();
        const status_code = self.agent_runtime.api.sessionControl().compact()(
            self.raw,
            operation_id,
            &result,
            &diagnostic,
        );
        const typed_status = sdk.Status.fromCode(status_code) catch null;
        const diagnostic_valid = self.copyCompactDiagnostic(diagnostic);
        releaseOwned(self.agent_runtime.api, &diagnostic);

        self.lock();
        self.core_call_in_progress = false;
        while (self.abort_calls_in_progress != 0) self.wait();
        var failure: ?TerminalFailure = null;
        var outcome: ?CompactOutcome = null;
        if (!diagnostic_valid) {
            self.dependency_contract_failure = true;
        } else if (typed_status) |status| {
            const disposition = compactStatusDisposition(status);
            if (disposition == null) {
                self.dependency_contract_failure = true;
            } else if (status == .ok) {
                if (result.struct_size != @sizeOf(wire.CompactResultV1) or
                    !allZero(&result.reserved))
                {
                    self.dependency_contract_failure = true;
                } else {
                    outcome = compactOutcome(result.outcome_code) catch invalid: {
                        self.dependency_contract_failure = true;
                        break :invalid null;
                    };
                }
            } else {
                failure = .abi_status;
                if (disposition.? == .poisoned) self.state = .poisoned;
            }
        } else {
            self.dependency_contract_failure = true;
        }
        if (self.compact_abort_status == .ok and
            (typed_status == null or typed_status.? != .ok or outcome != .aborted))
        {
            self.dependency_contract_failure = true;
        }
        if (self.dependency_contract_failure) {
            failure = .dependency_contract;
            self.state = .poisoned;
        }
        self.compact_started = false;
        self.compact_done = true;
        if (self.state != .closing and self.state != .poisoned) self.state = .idle;
        const terminal = self.takeCompactTerminalResultLocked(
            typed_status,
            status_code,
            outcome,
            if (outcome == null) null else &result,
            failure,
        );
        self.broadcast();
        self.unlock();
        return terminal;
    }

    pub fn requestCompactCancellation(
        self: *Session,
        operation_id: u64,
        interruption: ExternalInterruption,
    ) error{ NoSuchCompact, SessionClosing }!void {
        self.lock();
        if (operation_id == 0 or operation_id != self.active_compact_id or
            self.compact_done)
        {
            self.unlock();
            return error.NoSuchCompact;
        }
        if (self.state == .closing or self.state == .closed) {
            self.unlock();
            return error.SessionClosing;
        }
        if (self.compact_cancel_requested) {
            self.unlock();
            return;
        }
        self.compact_cancel_requested = true;
        self.compact_interruption = interruption;
        const should_abort = self.state == .compacting and self.core_call_in_progress;
        if (should_abort) self.abort_calls_in_progress += 1;
        self.unlock();
        if (should_abort) self.abortCompact(operation_id);
    }

    /// Rebinds the Session's internal immutable Skill snapshot. The caller
    /// serializes lease borrowing with replacement/release and may call this
    /// only while the Session is idle.
    pub fn refreshSkillCatalog(
        self: *Session,
        lease: *CatalogLease,
        skill_policy: SkillPolicyInput,
    ) (Error || std.mem.Allocator.Error)!void {
        if (!catalog.belongsTo(lease, self.agent_runtime) or
            !catalog.matchesSession(
                lease,
                self.workspace_root,
                self.workspace_home,
                self.workspace_epoch,
            ))
            return error.CatalogBindingMismatch;
        const policy_views = try self.agent_runtime.allocator.alloc(
            wire.BytesViewV1,
            skill_policy.granted_skill_ids.len,
        );
        defer self.agent_runtime.allocator.free(policy_views);
        const policy = session_wire.skillPolicy(
            skill_policy.granted_skill_ids,
            policy_views,
        ) catch return error.InvalidSkillPolicy;
        const replacement = try SkillRestoreInputs.init(self.agent_runtime, lease, skill_policy);
        var replacement_owned = true;
        defer if (replacement_owned) replacement.deinit() catch unreachable;
        self.lock();
        var locked = true;
        defer if (locked) self.unlock();
        if (self.credential_updates_in_progress != 0) return error.SessionNotIdle;
        if (self.agent_runtime.shutting_down.load(.acquire))
            return error.RuntimeShuttingDown;
        switch (self.state) {
            .idle => {},
            .queued, .running, .waiting_ui, .compact_queued, .compacting, .checkpointing => return error.SessionNotIdle,
            .poisoned => return error.SessionPoisoned,
            .closing, .closed => return error.SessionClosing,
        }
        var diagnostic = emptyOwnedBytes();
        const status_code = self.agent_runtime.api.skill().bindPolicy()(
            self.raw,
            catalog.rawHandle(lease),
            &policy,
            &diagnostic,
        );
        releaseOwned(self.agent_runtime.api, &diagnostic);
        const status = sdk.Status.fromCode(status_code) catch
            return self.failSkillUpdateContract();
        const disposition = skillUpdateStatusDisposition(status) orelse
            return self.failSkillUpdateContract();
        if (disposition == .poisoned) {
            self.state = .poisoned;
            return error.SessionPoisoned;
        }
        return switch (status) {
            .ok => {
                const previous = self.skill_restore_inputs;
                self.skill_restore_inputs = replacement;
                replacement_owned = false;
                self.unlock();
                locked = false;
                if (previous) |inputs| inputs.deinit() catch {
                    self.lock();
                    self.dependency_contract_failure = true;
                    self.state = .poisoned;
                    self.unlock();
                    return error.SessionPoisoned;
                };
            },
            .busy => error.SessionNotIdle,
            else => error.CatalogRefreshFailed,
        };
    }

    /// Withdraws Skill grants after a failed fresh query. The original catalog
    /// remains an owned snapshot; it is never presented as a fresh empty one.
    pub fn clearSkillPolicy(self: *Session) (Error || std.mem.Allocator.Error)!void {
        self.lock();
        const installed = self.skill_restore_inputs orelse {
            self.unlock();
            return;
        };
        if (installed.borrow().policy.granted_skill_ids.len == 0) {
            self.unlock();
            return;
        }
        const inputs = installed.clone() catch |err| {
            self.unlock();
            return err;
        };
        self.unlock();
        const result = self.refreshSkillCatalog(inputs.borrow().catalog, .{ .granted_skill_ids = &.{} });
        inputs.deinit() catch {
            self.lock();
            defer self.unlock();
            return self.failSkillUpdateContract();
        };
        return result;
    }

    pub fn skillPolicyMatches(self: *Session, lease: *CatalogLease, policy: SkillPolicyInput) bool {
        self.lock();
        defer self.unlock();
        const inputs = self.skill_restore_inputs orelse return false;
        const installed = inputs.borrow();
        if (installed.catalog != lease or installed.policy.granted_skill_ids.len != policy.granted_skill_ids.len) return false;
        for (installed.policy.granted_skill_ids, policy.granted_skill_ids) |old, current|
            if (!std.mem.eql(u8, old, current)) return false;
        return true;
    }

    /// Rebinds the model of this Session while it is idle. AgentCore rejects
    /// the same operation while a Run is active; the caller uses that busy
    /// result to keep model changes out of the in-flight Run path.
    pub fn setModel(self: *Session, model: []const u8) Error!void {
        model_binding.validateModel(model) catch
            return error.CoreCallFailed;
        self.lock();
        defer self.unlock();
        if (self.credential_updates_in_progress != 0) return error.SessionNotIdle;
        if (self.agent_runtime.shutting_down.load(.acquire))
            return error.RuntimeShuttingDown;
        switch (self.state) {
            .idle => {},
            .queued, .running, .waiting_ui, .compact_queued, .compacting, .checkpointing => return error.SessionNotIdle,
            .poisoned => return error.SessionPoisoned,
            .closing, .closed => return error.SessionClosing,
        }
        var diagnostic = emptyOwnedBytes();
        const status_code = self.agent_runtime.api.sessionControl().setModel()(
            self.raw,
            sdk.bytesView(model),
            &diagnostic,
        );
        releaseOwned(self.agent_runtime.api, &diagnostic);
        const status = sdk.Status.fromCode(status_code) catch
            return self.failModelUpdateContract();
        return switch (status) {
            .ok => {},
            .busy => error.SessionNotIdle,
            .invalid_argument => error.CoreCallFailed,
            .invalid_state => self.failModelUpdateContract(),
            else => error.CoreCallFailed,
        };
    }

    /// Core reads the current credential when sending a request. Retaining
    /// this Session protects the raw handle without serializing with a Run.
    pub fn updateCredential(self: *Session, credential: []const u8) Error!void {
        if (credential.len == 0 or credential.len > model_binding.max_credential_bytes)
            return error.InvalidCredential;
        for (credential) |byte| if (byte < 0x21 or byte > 0x7e) return error.InvalidCredential;
        if (!self.retainReference()) return error.SessionClosing;
        defer self.releaseReference();
        self.lock();
        const refusal: ?Error = if (self.agent_runtime.shutting_down.load(.acquire))
            error.RuntimeShuttingDown
        else switch (self.state) {
            .idle, .queued, .running, .waiting_ui => null,
            .compact_queued, .compacting, .checkpointing => error.SessionNotIdle,
            .poisoned => error.SessionPoisoned,
            .closing, .closed => error.SessionClosing,
        };
        if (refusal == null) self.credential_updates_in_progress += 1;
        self.unlock();
        if (refusal) |err| return err;
        defer {
            self.lock();
            self.credential_updates_in_progress -= 1;
            self.broadcast();
            self.unlock();
        }
        var diagnostic = emptyOwnedBytes();
        const code = self.agent_runtime.api.session().updateCredential()(self.raw, sdk.bytesView(credential), &diagnostic);
        releaseOwned(self.agent_runtime.api, &diagnostic);
        const status = sdk.Status.fromCode(code) catch return self.failCredentialUpdateContract();
        return switch (status) {
            .ok => {},
            .invalid_argument, .out_of_memory => error.CredentialUpdateFailed,
            .resource_limit => error.CredentialUpdateResourceLimit,
            else => self.failCredentialUpdateContract(),
        };
    }

    fn failCredentialUpdateContract(self: *Session) Error {
        self.lock();
        self.dependency_contract_failure = true;
        const active = !self.run_done;
        const run_id = self.active_run_id;
        const generation = self.active_run_generation;
        if (!active and self.state != .closing and self.state != .closed) self.state = .poisoned;
        self.broadcast();
        self.unlock();
        if (active) _ = self.requestControlledTermination(run_id, generation, .{ .credential_update_failure = .dependency_contract });
        return error.CredentialUpdateContract;
    }

    /// Product owns persistence; this changes only idle Core authority.
    pub fn updatePermissionMode(self: *Session, expected: PermissionMode, target: PermissionMode) Error!PermissionModeUpdate {
        self.lock();
        defer self.unlock();
        if (self.agent_runtime.shutting_down.load(.acquire)) return error.RuntimeShuttingDown;
        switch (self.state) {
            .idle => {},
            .poisoned => return error.SessionPoisoned,
            .closing, .closed => return error.SessionClosing,
            else => return error.SessionNotIdle,
        }
        if (self.core_call_in_progress or self.active_callback_refs != 0 or self.abort_calls_in_progress != 0 or self.credential_updates_in_progress != 0)
            return error.SessionNotIdle;
        const before = try self.permissionObservationLocked();
        if (before.mode != expected) return self.failPermissionModeContract();
        var diagnostic = emptyOwnedBytes();
        const code = self.agent_runtime.api.sessionControl().updatePermissionMode()(self.raw, permissionModeCode(target), &diagnostic);
        releaseOwned(self.agent_runtime.api, &diagnostic);
        const status = sdk.Status.fromCode(code) catch return self.failPermissionModeContract();
        switch (status) {
            .ok => {},
            .busy => return error.SessionNotIdle,
            .invalid_argument, .out_of_memory, .resource_limit => return error.PermissionModeUpdateFailed,
            .checkpoint_budget_required => return error.PermissionModeBudgetRequired,
            .invalid_state, .core_error => return self.poisonPermissionModeUpdate(),
            else => return self.failPermissionModeContract(),
        }
        // A failure after OK must close admission: Product restores its old
        // confirmed checkpoint instead of reversing a grant-revoking change.
        const after = self.permissionObservationLocked() catch return self.poisonPermissionModeUpdate();
        const changed = expected != target;
        const generation = if (changed)
            std.math.add(u64, before.policy_generation, 1) catch return self.failPermissionModeContract()
        else
            before.policy_generation;
        if (after.mode != target or after.policy_generation != generation)
            return self.failPermissionModeContract();
        return .{ .changed = changed, .policy_generation = after.policy_generation };
    }

    const PermissionObservation = struct { mode: PermissionMode, policy_generation: u64 };

    fn permissionObservationLocked(self: *Session) Error!PermissionObservation {
        var encoded = emptyOwnedBytes();
        defer releaseOwned(self.agent_runtime.api, &encoded);
        var diagnostic = emptyOwnedBytes();
        defer releaseOwned(self.agent_runtime.api, &diagnostic);
        const code = self.agent_runtime.api.sessionControl().describe()(self.raw, &encoded, &diagnostic);
        const status = sdk.Status.fromCode(code) catch return self.failPermissionModeContract();
        if (status != .ok) {
            if (encoded.ptr != null or encoded.len != 0) return self.failPermissionModeContract();
            return switch (status) {
                .busy => error.SessionNotIdle,
                .invalid_argument, .resource_limit => error.PermissionModeUpdateFailed,
                .out_of_memory, .core_error, .invalid_state => self.poisonPermissionModeUpdate(),
                else => self.failPermissionModeContract(),
            };
        }
        const bytes = sdk.borrowedBytes(.{ .ptr = encoded.ptr, .len = encoded.len }) catch return self.failPermissionModeContract();
        var parsed = sdk.decodeSessionDescription(self.agent_runtime.allocator, bytes) catch |err| {
            if (err == error.OutOfMemory) return error.PermissionModeUpdateFailed;
            return self.failPermissionModeContract();
        };
        defer parsed.deinit();
        const value = parsed.value;
        if (value.lifecycle != .idle or !value.registered or value.session_id.len == 0 or value.session_id.len > max_core_session_id_bytes)
            return self.failPermissionModeContract();
        switch (self.core_session_identity) {
            .unbound => {
                var identity = CoreSessionIdentity{ .bound = .{ .len = value.session_id.len, .bytes = [_]u8{0} ** max_core_session_id_bytes } };
                @memcpy(identity.bound.bytes[0..value.session_id.len], value.session_id);
                self.core_session_identity = identity;
            },
            .bound => |identity| if (!std.mem.eql(u8, identity.bytes[0..identity.len], value.session_id)) return self.failPermissionModeContract(),
            .failed => return self.failPermissionModeContract(),
        }
        return .{ .mode = switch (value.permission_mode) {
            .default => .default,
            .accept_edits => .accept_edits,
            .auto => .auto,
            .dont_ask => .dont_ask,
            .full_access => .full_access,
        }, .policy_generation = value.policy_generation };
    }

    fn poisonPermissionModeUpdate(self: *Session) Error {
        self.state = .poisoned;
        self.broadcast();
        return error.PermissionModeUpdateFailed;
    }

    fn failPermissionModeContract(self: *Session) Error {
        self.dependency_contract_failure = true;
        return self.poisonPermissionModeUpdate();
    }

    fn failModelUpdateContract(self: *Session) Error {
        self.dependency_contract_failure = true;
        self.state = .poisoned;
        self.broadcast();
        return error.CoreCallFailed;
    }

    /// Applies a complete replacement of this idle Session's MCP authority.
    pub fn updateMcpSelection(
        self: *Session,
        selection: ?*const McpSelection,
    ) (Error || std.mem.Allocator.Error)!void {
        return self.agent_runtime.updateSessionMcpSelection(self, selection);
    }

    /// Owns the Session's original selectors and connection provenance after
    /// close/release. It contains no SDK handle or permission grants.
    pub fn captureRestoreInputs(self: *Session) (Error || std.mem.Allocator.Error)!SessionRestoreInputs {
        self.lock();
        defer self.unlock();
        if (self.credential_updates_in_progress != 0) return error.SessionNotIdle;
        if (self.agent_runtime.shutting_down.load(.acquire)) return error.RuntimeShuttingDown;
        switch (self.state) {
            .idle => {},
            .poisoned => return error.SessionPoisoned,
            .closing, .closed => return error.SessionClosing,
            else => return error.SessionNotIdle,
        }
        const permission = try self.permissionObservationLocked();
        const skill = if (self.skill_restore_inputs) |inputs| try inputs.clone() else null;
        // This clone cannot own the last lease while the Session is locked.
        errdefer if (skill) |inputs| inputs.deinit() catch unreachable;
        return .{
            .skill = skill,
            .mcp = if (self.mcp_restore_selection) |selection| try selection.clone(self.agent_runtime.allocator) else null,
            .permission_mode = permission.mode,
            .shell_policy = self.shell_policy,
            .permission_interaction = self.permission_interaction,
        };
    }

    pub fn failMcpUpdateContractLocked(self: *Session) Error {
        self.dependency_contract_failure = true;
        self.state = .poisoned;
        self.broadcast();
        return error.McpSelectionUpdateFailed;
    }

    fn failSkillUpdateContract(self: *Session) Error {
        self.dependency_contract_failure = true;
        self.state = .poisoned;
        self.broadcast();
        return error.CatalogRefreshFailed;
    }

    pub fn requestTermination(
        self: *Session,
        run_id: u64,
        signal: TerminationSignal,
    ) Error!void {
        self.lock();
        if (self.state == .closing or self.state == .closed) {
            self.unlock();
            return error.SessionClosing;
        }
        if (self.state == .poisoned) {
            self.unlock();
            return error.SessionPoisoned;
        }
        if (run_id == 0 or run_id != self.active_run_id) {
            self.unlock();
            return error.NoSuchRun;
        }
        if (!self.run_done) recordHostFailureLocked(self, signal);
        if (self.cancel_requested) {
            self.unlock();
            return;
        }
        if (self.state == .idle) {
            self.unlock();
            return error.NoSuchRun;
        }
        self.cancel_requested = true;
        setTerminationSignalLocked(self, signal);
        wakeUiLocked(self);
        const was_queued = self.state == .queued;
        const should_abort = !was_queued and self.registerRunAbortLocked(false);
        self.unlock();

        if (was_queued) {
            _ = self.agent_runtime.notifyEventConsumer();
            return;
        }
        if (should_abort) self.abortRun(run_id, signal);
    }

    /// Fails the active Run when Product observes a UI request identity that
    /// contradicts its durable history. The dependency-contract failure owns
    /// the terminal result; waking and aborting the callback only make the
    /// already-invalid Run converge promptly.
    pub fn failUiRequestIdentityContract(self: *Session, run_id: u64) Error!void {
        self.lock();
        if (self.state == .closing or self.state == .closed) {
            self.unlock();
            return error.SessionClosing;
        }
        if (self.state == .poisoned) {
            self.unlock();
            return error.SessionPoisoned;
        }
        if (run_id == 0 or run_id != self.active_run_id or self.run_done or
            self.state == .idle)
        {
            self.unlock();
            return error.NoSuchRun;
        }
        self.dependency_contract_failure = true;
        self.recordCallbackRejectionLocked(.{ .boundary = .ui_admission, .reason = .identity_mismatch });
        setTerminationSignalLocked(self, .{ .callback_failure = .ui });
        wakeUiLocked(self);
        const was_queued = self.state == .queued;
        const should_abort = !was_queued and self.registerRunAbortLocked(false);
        self.cancel_requested = true;
        self.unlock();

        if (was_queued) {
            _ = self.agent_runtime.notifyEventConsumer();
            return;
        }
        if (should_abort) self.abortRun(run_id, .{ .callback_failure = .ui });
    }

    fn inputObservationLocked(self: *const Session) InputObservation {
        return .{
            .ready = self.input_ready and self.core_call_in_progress and !self.run_done and
                !self.cancel_requested and !self.dependency_contract_failure and
                (self.state == .running or self.state == .waiting_ui),
            .accepted = self.submitted_inputs.accepted,
            .adopted = self.submitted_inputs.adopted,
            .submitting = self.input_calls_in_progress != 0,
        };
    }

    pub fn controlledInputObservation(self: *Session, run_id: u64, generation: u64) InputObservation {
        self.lock();
        defer self.unlock();
        if (run_id != self.active_run_id or generation != self.active_run_generation) return .{};
        return self.inputObservationLocked();
    }

    pub fn submitControlledInput(self: *Session, run_id: u64, generation: u64, input_id: u64, text: []const u8) InputSubmission {
        self.lock();
        if (run_id != self.active_run_id or generation != self.active_run_generation) {
            self.unlock();
            return .{ .rejected = .stale_run };
        }
        if (self.cancel_requested or self.state == .closing) {
            self.unlock();
            return .{ .rejected = .stopping };
        }
        if (!self.inputObservationLocked().ready) {
            self.unlock();
            return .{ .rejected = if (self.run_done) .too_late else .not_ready };
        }
        if (self.run_input == null or self.run_input.? == .skill) {
            self.unlock();
            return .{ .rejected = .unsupported_input };
        }
        if (text.len > self.agent_runtime.max_prompt_bytes or
            std.mem.trim(u8, text, " \t\r\n").len == 0 or !std.unicode.utf8ValidateSlice(text))
        {
            self.unlock();
            return .{ .rejected = .invalid_input };
        }
        const slot = self.submitted_inputs.register(input_id) catch |err| {
            self.unlock();
            return .{ .rejected = if (err == error.ResourceLimit) .resource_limit else .invalid_input };
        };
        self.input_calls_in_progress += 1;
        self.unlock();

        var receipt = std.mem.zeroes(wire.InputReceiptV1);
        var diagnostic = emptyOwnedBytes();
        const raw_status = self.agent_runtime.api.session().submitInput(
            self.raw,
            run_id,
            input_id,
            sdk.bytesView(text),
            &receipt,
            &diagnostic,
        );
        const valid_diagnostic = sdk.borrowedBytes(.{ .ptr = diagnostic.ptr, .len = diagnostic.len }) catch null;
        const diagnostic_valid = if (valid_diagnostic) |bytes| std.unicode.utf8ValidateSlice(bytes) else false;
        releaseOwned(self.agent_runtime.api, &diagnostic);
        const status = sdk.Status.fromCode(raw_status) catch null;

        self.lock();
        var outcome: InputSubmission = .unknown;
        if (diagnostic_valid) if (status) |known| {
            if (known == .ok) {
                if (receipt.struct_size == @sizeOf(wire.InputReceiptV1) and allZero(&receipt.reserved) and
                    self.submitted_inputs.receipt(slot, receipt.sequence)) outcome = .{ .accepted = receipt.sequence };
            } else {
                const rejection: ?InputRejection = switch (known) {
                    .invalid_argument => .invalid_input,
                    .resource_limit => .resource_limit,
                    .checkpoint_budget_required => .checkpoint_budget_required,
                    .stale_run => .stale_run,
                    .too_late => .too_late,
                    .invalid_state => .unavailable,
                    else => null,
                };
                if (rejection) |reason| if (self.submitted_inputs.refuse(slot)) {
                    outcome = .{ .rejected = reason };
                };
            }
        };
        if (outcome == .unknown) self.dependency_contract_failure = true;
        self.input_calls_in_progress -= 1;
        self.broadcast();
        self.unlock();
        if (outcome == .unknown) _ = self.requestControlledTermination(run_id, generation, .{ .callback_failure = .event });
        return outcome;
    }

    pub fn requestControlledTermination(
        self: *Session,
        run_id: u64,
        generation: u64,
        signal: TerminationSignal,
    ) TerminationRequestResult {
        self.lock();
        if (run_id != self.active_run_id or generation != self.active_run_generation) {
            self.unlock();
            return .stale_run;
        }
        if (self.run_done) {
            self.unlock();
            return .already_terminal;
        }
        recordHostFailureLocked(self, signal);
        if (self.state == .closing or self.state == .closed) {
            self.unlock();
            return .session_closing;
        }
        if (self.cancel_requested) {
            self.unlock();
            return .already_requested;
        }
        self.cancel_requested = true;
        setTerminationSignalLocked(self, signal);
        wakeUiLocked(self);
        const should_abort = self.registerRunAbortLocked(false);
        self.unlock();
        if (should_abort) self.abortRun(run_id, signal);
        return .requested;
    }

    pub fn respondPermission(
        self: *Session,
        run_id: u64,
        request_id: u64,
        choice: PermissionChoice,
    ) (Error || std.mem.Allocator.Error)!void {
        self.lock();
        defer self.unlock();
        const request = try self.pendingUiRequestLocked(run_id, request_id);
        const permission_request = switch (request.*) {
            .permission => |permission| permission,
            else => return error.InvalidUiResponse,
        };
        const rule_id = switch (choice) {
            .allow_once, .deny_once => null,
            .allow_session, .deny_session => session_rule: {
                const candidate = permission_request.candidate orelse
                    return error.InvalidUiResponse;
                break :session_rule candidate.rule_id;
            },
        };
        try self.encodeUiResponseLocked(request, .{ .permission = .{
            .permission = choice,
            .request_id = permission_request.request_id,
            .policy_generation = permission_request.policy_generation,
            .rule_id = rule_id,
        } });
    }

    fn pendingUiRequestLocked(
        self: *Session,
        run_id: u64,
        request_id: u64,
    ) Error!*const sdk.UiRequest {
        if (self.state == .closing or self.state == .closed) return error.SessionClosing;
        if (!self.ui_active) {
            if (self.ui_request_id != 0 and run_id == self.active_run_id and
                request_id == self.ui_request_id)
                return error.StaleUiResponse;
            return error.NoPendingUiRequest;
        }
        if (run_id != self.active_run_id or request_id != self.ui_request_id or self.ui_answered)
            return error.StaleUiResponse;
        const request = self.ui_request_value orelse return error.NoPendingUiRequest;
        return request;
    }

    fn encodeUiResponseLocked(
        self: *Session,
        request: *const sdk.UiRequest,
        response: sdk.UiResponse,
    ) (Error || std.mem.Allocator.Error)!void {
        const scratch = try self.agent_runtime.allocator.alloc(u8, self.agent_runtime.max_ui_response_bytes);
        defer self.agent_runtime.allocator.free(scratch);
        var fixed = std.heap.FixedBufferAllocator.init(scratch);
        const bounded = sdk.encodeUiResponse(fixed.allocator(), request.*, response) catch |err| switch (err) {
            error.OutOfMemory => return error.InvalidUiResponse,
            error.MismatchedResponse, error.InvalidResponse => return error.InvalidUiResponse,
        };
        const encoded = try self.agent_runtime.allocator.dupe(u8, bounded);
        std.debug.assert(self.ui_response_json == null);
        self.ui_response_json = encoded;
        self.ui_answered = true;
        self.ui_active = false;
        self.broadcast();
    }

    pub fn pendingUiRequest(self: *Session) ?u64 {
        self.lock();
        defer self.unlock();
        return if (self.ui_active) self.ui_request_id else null;
    }

    pub fn permissionStopRequest(self: *Session) ?u64 {
        self.lock();
        defer self.unlock();
        if (!self.permission_stop_requested or self.run_done) return null;
        return self.active_run_id;
    }

    pub const PendingUiObservation = struct {
        run_id: u64,
        request_id: u64,
        input_adopted_count: u32 = 0,
    };

    /// Bounded execution observation that exposes neither Session lifecycle nor
    /// external owner identity.
    pub fn pendingUiObservation(self: *Session) ?PendingUiObservation {
        self.lock();
        defer self.unlock();
        if (!self.ui_active) return null;
        return .{ .run_id = self.active_run_id, .request_id = self.ui_request_id, .input_adopted_count = self.ui_input_adopted_count };
    }

    pub fn copyPendingUiRequest(
        self: *Session,
        allocator: std.mem.Allocator,
    ) (Error || std.mem.Allocator.Error)!PendingUiRequest {
        self.lock();
        defer self.unlock();
        const json = self.ui_request_json orelse return error.NoPendingUiRequest;
        if (!self.ui_active) return error.StaleUiResponse;
        return .{
            .session_id = self.id,
            .run_id = self.active_run_id,
            .request_id = self.ui_request_id,
            .input_adopted_count = self.ui_input_adopted_count,
            .json = try allocator.dupe(u8, json),
            .allocator = allocator,
        };
    }

    pub fn waitForState(self: *Session, wanted: SessionState) Error!void {
        self.lock();
        defer self.unlock();
        while (self.state != wanted and self.state != .closed and !self.close_failed and
            !(self.run_done and isRunProgressState(wanted)))
            self.wait();
        if (self.state == wanted) return;
        if (self.close_failed) return error.SessionDestroyFailed;
        if (self.run_done and isRunProgressState(wanted)) return error.StateNotReached;
        return error.SessionClosing;
    }

    pub fn waitRun(self: *Session, run_id: u64) Error!void {
        self.lock();
        defer self.unlock();
        if (run_id != self.active_run_id and !(self.run_done and run_id == self.next_run_id))
            return error.NoSuchRun;
        while (!self.run_done) self.wait();
    }

    pub fn snapshot(self: *Session) SessionSnapshot {
        self.lock();
        defer self.unlock();
        return .{
            .session_id = self.id,
            .state = self.state,
            .workspace_root = self.workspace_root,
            .active_run_id = self.active_run_id,
            .active_compact_id = self.active_compact_id,
            .pending_ui_request_id = if (self.ui_active) self.ui_request_id else null,
            .input = self.inputObservationLocked(),
        };
    }

    pub fn retainReference(self: *Session) bool {
        self.lock();
        defer self.unlock();
        if (self.state == .closing or self.state == .closed) return false;
        self.active_refs += 1;
        return true;
    }

    /// Runs the complete export -> describe Agent operation while holding the
    /// Session's single-operation lane. The sink owns bytes only for the
    /// duration of each callback; filesystem commit remains an external fact.
    pub fn exportCheckpoint(
        self: *Session,
        limits: CheckpointLimits,
        sink: CheckpointSink,
        expected_last_run_id: u64,
        expected_last_compact_id: u64,
        expected_model: []const u8,
    ) Error!CheckpointOutcome {
        try checkpoint.validateLimits(limits);
        model_binding.validateModel(expected_model) catch
            return error.InvalidLimits;

        if (!self.retainReference()) return error.SessionClosing;
        defer self.releaseReference();
        self.lock();
        // A Run can finish while its credential update is still returning.
        // Keep its checkpoint work pending until that update leaves the lane.
        while (self.credential_updates_in_progress != 0 and self.state == .idle and
            !self.agent_runtime.shutting_down.load(.acquire)) self.wait();
        if (self.agent_runtime.shutting_down.load(.acquire)) {
            self.unlock();
            return error.RuntimeShuttingDown;
        }
        switch (self.state) {
            .idle => {},
            .poisoned => {
                self.unlock();
                return error.SessionPoisoned;
            },
            .closing, .closed => {
                self.unlock();
                return error.SessionClosing;
            },
            .queued,
            .running,
            .waiting_ui,
            .compact_queued,
            .compacting,
            .checkpointing,
            => {
                self.unlock();
                return error.SessionNotIdle;
            },
        }
        const raw_session = self.raw orelse {
            self.unlock();
            return error.SessionClosing;
        };
        self.state = .checkpointing;
        self.unlock();

        var outcome = checkpoint.create(
            self.agent_runtime.allocator,
            self.agent_runtime.api,
            raw_session,
            limits,
            sink,
            expected_last_run_id,
            expected_last_compact_id,
            expected_model,
        );

        self.lock();
        if (outcome == .success) {
            const logical_id = outcome.success.description.session_id;
            const identity_matches = switch (self.core_session_identity) {
                .unbound => bind: {
                    if (logical_id.len == 0 or logical_id.len > max_core_session_id_bytes) break :bind false;
                    var binding = CoreSessionIdentity{ .bound = .{
                        .len = logical_id.len,
                        .bytes = [_]u8{0} ** max_core_session_id_bytes,
                    } };
                    @memcpy(binding.bound.bytes[0..logical_id.len], logical_id);
                    self.core_session_identity = binding;
                    break :bind true;
                },
                .bound => |binding| std.mem.eql(
                    u8,
                    binding.bytes[0..binding.len],
                    logical_id,
                ),
                .failed => false,
            };
            if (!identity_matches) {
                outcome.deinit();
                outcome = .{ .failure = .{
                    .stage = .describe,
                    .reason = .dependency_contract,
                    .disposition = .poisoned,
                } };
            }
        }
        switch (outcome) {
            .success => {},
            .failure => |failure| if (failure.disposition == .poisoned) {
                if (failure.reason == .dependency_contract)
                    self.dependency_contract_failure = true;
                if (self.state != .closing and self.state != .closed)
                    self.state = .poisoned;
            },
        }
        if (self.state == .checkpointing) self.state = .idle;
        self.unlock();
        return outcome;
    }

    pub fn releaseReference(self: *Session) void {
        self.lock();
        defer self.unlock();
        std.debug.assert(self.active_refs > 0);
        self.active_refs -= 1;
        if (self.active_refs == 0) self.broadcast();
    }

    pub fn recordTerminationSignal(self: *Session, signal: TerminationSignal) void {
        self.lock();
        defer self.unlock();
        if (!self.run_done) setTerminationSignalLocked(self, signal);
    }

    pub fn stopEventDelivery(self: *Session) void {
        self.lock();
        self.event_delivery_stopped.store(true, .release);
        const callbacks = self.active_callback_refs != 0;
        self.unlock();
        // A new callback sees the sticky state before waiting. Only existing
        // callback owners can already be asleep on the queue condition.
        if (callbacks) self.agent_runtime.events.stopWaiting(&self.event_delivery_stopped);
    }

    pub fn close(self: *Session, interruption: ExternalInterruption) Error!void {
        self.lock();
        if (self.state == .closed) {
            self.unlock();
            return;
        }
        if (self.state == .closing) {
            while (!self.close_finished) self.wait();
            if (!self.close_failed) {
                self.unlock();
                return;
            }
            self.close_finished = false;
            self.close_failed = false;
            self.unlock();
            return self.destroyRawSession();
        }
        self.control_block.disableNewLeases();
        const compact_active = self.state == .compact_queued or self.state == .compacting;
        const operation_done = if (compact_active) self.compact_done else self.run_done;
        var should_abort_now = compact_active and self.core_call_in_progress and !operation_done and
            self.abort_calls_in_progress == 0 and
            self.raw_compact_abort_status_code == null;
        if (should_abort_now) self.abort_calls_in_progress += 1;
        const run_id = self.active_run_id;
        const compact_id = self.active_compact_id;
        self.close_interruption = interruption;
        self.state = .closing;
        self.event_delivery_stopped.store(true, .release);
        const signal: TerminationSignal = .{ .interrupted = interruption };
        if (compact_active) {
            if (!self.compact_done) {
                self.compact_cancel_requested = true;
                if (self.compact_interruption == null)
                    self.compact_interruption = interruption;
            }
            if (!self.compact_done and !self.compact_started)
                self.finishPreparedCompactLocked();
        } else {
            if (!self.run_done) setTerminationSignalLocked(self, signal);
            if (self.ui_active) self.controlled_callback_close = interruption;
            wakeUiLocked(self);
            if (!self.run_done and !self.run_started) self.finishPreparedRunLocked();
            should_abort_now = self.registerRunAbortLocked(false);
        }
        self.broadcast();
        self.unlock();

        // Closing admission first prevents a concurrent prepare from resetting
        // the sticky exit state between installation and the callback join.
        self.stopEventDelivery();

        if (should_abort_now) {
            if (compact_active) self.abortCompact(compact_id) else self.abortRun(run_id, signal);
        }

        self.lock();
        while (if (compact_active)
            (!self.compact_done and !self.compact_started)
        else
            (!self.run_done and !self.run_started)) self.wait();
        const should_abort_late = if (!compact_active)
            !should_abort_now and self.registerRunAbortLocked(false)
        else
            !should_abort_now and self.core_call_in_progress and !self.compact_done and
                self.abort_calls_in_progress == 0 and
                self.raw_compact_abort_status_code == null;
        if (compact_active and should_abort_late) self.abort_calls_in_progress += 1;
        self.unlock();
        if (should_abort_late) {
            if (compact_active) self.abortCompact(compact_id) else self.abortRun(run_id, signal);
        }

        self.lock();
        while (!(if (compact_active) self.compact_done else self.run_done)) self.wait();
        while (self.abort_calls_in_progress != 0) self.wait();
        while (self.active_refs != 0) self.wait();
        self.unlock();

        // Never wait for Agent control references while holding a caller-owned or
        // Session lock. A worker may need both to publish terminal completion
        // and release the execution base lease.
        self.control_block.waitForLeaseQuiescence();

        return self.destroyRawSession();
    }

    pub fn closeOutcome(
        self: *Session,
        interruption: ExternalInterruption,
    ) CloseOutcome {
        self.close(interruption) catch |err| {
            self.lock();
            defer self.unlock();
            return .{ .failure = .{
                .err = err,
                .session_disposition = self.dispositionLocked(),
            } };
        };
        return .closed;
    }

    fn destroyRawSession(self: *Session) Error!void {
        self.lock();
        const skill = self.skill_restore_inputs;
        self.skill_restore_inputs = null;
        self.unlock();
        if (skill) |inputs| inputs.deinit() catch |err| {
            self.lock();
            self.close_finished = true;
            self.close_failed = true;
            self.broadcast();
            self.unlock();
            return err;
        };
        var diagnostic = emptyOwnedBytes();
        const status = self.agent_runtime.api.session().destroy()(self.raw, &diagnostic);
        releaseOwned(self.agent_runtime.api, &diagnostic);
        const typed_status = sdk.Status.fromCode(status) catch null;
        self.lock();
        self.close_finished = true;
        if (typed_status == null or !isSessionDestroyStatus(typed_status.?)) {
            self.dependency_contract_failure = true;
            self.close_failed = true;
        } else if (typed_status == .ok) {
            self.raw = null;
            self.state = .closed;
            self.close_failed = false;
        } else {
            self.close_failed = true;
        }
        self.broadcast();
        const failed = self.close_failed;
        self.unlock();
        if (failed) return error.SessionDestroyFailed;
    }

    fn executeBegunRun(self: *Session, run_id: u64, generation: u64) TerminalResult {
        self.lock();
        std.debug.assert(run_id == self.active_run_id);
        std.debug.assert(generation == self.active_run_generation);
        std.debug.assert(self.run_started and !self.run_done);
        if (self.cancel_requested or self.state == .closing) {
            const terminal = self.finishBeforeCoreCallLocked();
            self.unlock();
            _ = self.agent_runtime.notifyEventConsumer();
            return terminal;
        }
        const input = &self.run_input.?;
        const has_images = input.* == .multimodal and input.multimodal.has_images;

        var options = std.mem.zeroes(wire.RunOptionsV1);
        options.struct_size = @sizeOf(wire.RunOptionsV1);
        options.max_turns = wire.MAX_TURNS_V1;
        // Core samples the process date and timezone at Run admission.
        // Skill Runs carry no date block under the same SYSTEM policy.
        options.time_context_code = wire.TIME_CONTEXT_SYSTEM;
        self.core_call_in_progress = true;
        self.unlock();
        // A successful Core call must still populate and validate the complete
        // fixed-layout result. Zero initialization makes a missing write fail
        // deterministically on `struct_size` instead of exposing undefined data.
        var result = std.mem.zeroes(wire.RunResultV1);
        var diagnostic = emptyOwnedBytes();
        const status = switch (input.*) {
            .multimodal => |parts| self.agent_runtime.api.session().runMultimodal(
                self.raw,
                run_id,
                parts.parts,
                &options,
                &result,
                &diagnostic,
            ),
            .text => |text| self.agent_runtime.api.session().runText(
                self.raw,
                run_id,
                sdk.bytesView(text),
                &options,
                &result,
                &diagnostic,
            ),
            .skill => |skill| skill_run: {
                var fixed = std.heap.FixedBufferAllocator.init(
                    skill.encoding_scratch,
                );
                const arguments_json = sdk.encodeSkillArguments(
                    fixed.allocator(),
                    skill.argument_values,
                ) catch unreachable;
                break :skill_run self.agent_runtime.api.session().runSkill(
                    self.raw,
                    run_id,
                    sdk.bytesView(skill.skill_id),
                    sdk.bytesView(skill.catalog_revision),
                    sdk.bytesView(arguments_json),
                    &options,
                    &result,
                    &diagnostic,
                );
            },
        };
        const typed_status = sdk.Status.fromCode(status) catch null;
        const diagnostic_valid = self.copyTerminalDiagnostic(diagnostic);
        releaseOwned(self.agent_runtime.api, &diagnostic);

        self.lock();
        self.core_call_in_progress = false;
        self.input_ready = false;
        while (self.input_calls_in_progress != 0) self.wait();
        if (self.active_callback_refs != 0) {
            self.recordCallbackRejectionLocked(.{ .boundary = .core_return, .reason = .callbacks_in_flight });
            self.failCoreIdentityLocked();
            while (self.active_callback_refs != 0) self.wait();
        }
        while (self.abort_calls_in_progress != 0) self.wait();
        const closing = self.state == .closing;
        var completed_input = self.run_input.?;
        self.run_input = null;
        completed_input.deinit(self.agent_runtime.allocator);
        self.clearRunToolsLocked();
        var stop_reason: ?sdk.StopReason = null;
        var raw_stop_reason_code: ?u32 = null;
        var failure: ?TerminalFailure = null;
        var durable_budget: ?DurableBudgetObservation = null;
        if (!diagnostic_valid) {
            self.dependency_contract_failure = true;
            failure = .dependency_contract;
            self.state = .poisoned;
        } else if (typed_status) |known_status| {
            // Core reports a callback failure, but the failed boundary may be
            // unrouteable (for example an invalid Host tool context).
            if (known_status == .callback_failed and !self.dependency_contract_failure and
                self.first_host_failure == null and self.controlled_callback_close == null)
                setTerminationSignalLocked(self, .{ .callback_failure = .event });

            // Counts are defined on every known status, including failed Runs.
            if (!self.submitted_inputs.reconcile(result.input_accepted_count, result.input_adopted_count)) {
                self.dependency_contract_failure = true;
                failure = .dependency_contract;
                self.state = .poisoned;
            }
            const disposition = runStatusDisposition(known_status, has_images);
            if (disposition == null) {
                self.dependency_contract_failure = true;
                failure = .dependency_contract;
                self.state = .poisoned;
            }
            if (!self.dependency_contract_failure and known_status == .ok) {
                if (result.struct_size != @sizeOf(wire.RunResultV1) or
                    !allZero(&result.reserved) or
                    !runCheckpointFieldsValid(result))
                {
                    self.dependency_contract_failure = true;
                    failure = .dependency_contract;
                    self.state = .poisoned;
                } else {
                    durable_budget = .{
                        .durable_usage_bytes = result.durable_usage_bytes,
                        .required_checkpoint_bytes = result.required_checkpoint_bytes,
                    };
                    raw_stop_reason_code = result.stop_reason_code;
                    if (sdk.StopReason.fromCode(result.stop_reason_code)) |reason| {
                        if (runCheckpointOutcomeMatchesStop(result.checkpoint_outcome_code, reason)) {
                            stop_reason = reason;
                        } else {
                            self.dependency_contract_failure = true;
                            failure = .dependency_contract;
                            self.state = .poisoned;
                        }
                    } else |_| {
                        self.dependency_contract_failure = true;
                        failure = .dependency_contract;
                        self.state = .poisoned;
                    }
                }
            } else if (!self.dependency_contract_failure) {
                if (known_status == .checkpoint_budget_required and
                    (result.struct_size != @sizeOf(wire.RunResultV1) or
                        !runCheckpointFieldsValid(result) or
                        result.checkpoint_outcome_code != wire.RUN_CHECKPOINT_BUDGET_REQUIRED))
                {
                    self.dependency_contract_failure = true;
                    failure = .dependency_contract;
                    self.state = .poisoned;
                } else {
                    if (known_status == .checkpoint_budget_required) durable_budget = .{
                        .durable_usage_bytes = result.durable_usage_bytes,
                        .required_checkpoint_bytes = result.required_checkpoint_bytes,
                    };
                    failure = .abi_status;
                    if (disposition.? == .poisoned) self.state = .poisoned;
                }
            }
        } else {
            self.dependency_contract_failure = true;
            failure = .dependency_contract;
            self.state = .poisoned;
        }
        if (!self.dependency_contract_failure and typed_status == .ok and
            (self.callback_fatal_observed or self.output_segment != null or self.terminal_phase == null or
                self.terminal_phase == .poisoned or
                (stop_reason == .aborted and self.terminal_phase != .aborted)))
        {
            self.recordCallbackRejectionLocked(.{ .boundary = .core_return, .reason = if (self.callback_fatal_observed) .fatal_returned_ok else .invalid_terminal });
            self.failCoreIdentityLocked();
        }
        if (!self.dependency_contract_failure and self.state != .closing) {
            if (self.terminal_phase == .poisoned or
                (self.input_window_started and typed_status != .ok and self.terminal_phase == null))
            {
                self.state = .poisoned;
            } else if (self.input_window_started and self.terminal_phase == .failed and typed_status != .ok and
                self.state != .poisoned)
            {
                self.confirmRunDispositionLocked();
            }
        }
        // Reconcile while this Run still owns admission, before the common
        // dependency-failure/disposition epilogue can return the Session idle.
        if (!self.dependency_contract_failure and typed_status == .ok and stop_reason != null and
            ((stop_reason.? == .api_error) != (self.model_error != null)))
        {
            self.recordCallbackRejectionLocked(.{
                .boundary = .core_return,
                .reason = if (self.model_error == null) .missing_model_error else .unexpected_model_error,
                .event = .model_error,
            });
            self.failCoreIdentityLocked();
        }
        if (self.dependency_contract_failure) {
            failure = .dependency_contract;
            self.state = .poisoned;
        } else {
            self.input_counts = .{ .accepted = result.input_accepted_count, .adopted = result.input_adopted_count };
        }
        if (closing) self.state = .closing;
        self.run_started = false;
        self.run_done = true;
        if (self.state != .closing and self.state != .poisoned) self.state = .idle;
        const terminal = self.takeTerminalResultLocked(
            typed_status,
            status,
            stop_reason,
            raw_stop_reason_code,
            failure,
            durable_budget,
        );
        self.broadcast();
        self.unlock();
        _ = self.agent_runtime.notifyEventConsumer();
        return terminal;
    }

    fn finishBeforeCoreCallLocked(self: *Session) TerminalResult {
        std.debug.assert(!self.core_call_in_progress);
        if (self.run_input) |*input| {
            input.deinit(self.agent_runtime.allocator);
            self.run_input = null;
        }
        self.clearRunToolsLocked();
        self.run_started = false;
        self.run_done = true;
        if (self.state != .closing and self.state != .poisoned) self.state = .idle;
        if (self.dependency_contract_failure and self.state != .closing) self.state = .poisoned;
        const terminal = self.takeTerminalResultLocked(null, null, null, null, if (self.dependency_contract_failure) .dependency_contract else null, null);
        self.broadcast();
        return terminal;
    }

    /// Register the first delivery, or one retry at the Core admission edge.
    /// Core calls and queue waits must happen after releasing the Session lock.
    fn registerRunAbortLocked(self: *Session, after_start: bool) bool {
        if (self.run_done or !self.core_call_in_progress or
            self.termination_signal == null or self.abort_status == .ok) return false;
        if (after_start) {
            if (self.abort_retried_after_start) return false;
            if (self.abort_calls_in_progress != 0) {
                self.abort_retry_pending = true;
                return false;
            }
            self.abort_retried_after_start = true;
            self.abort_retry_pending = false;
        } else if (self.abort_calls_in_progress != 0 or self.raw_abort_status_code != null) {
            return false;
        }
        self.abort_calls_in_progress += 1;
        return true;
    }

    fn abortRun(self: *Session, run_id: u64, signal: TerminationSignal) void {
        while (true) {
            var diagnostic = emptyOwnedBytes();
            const status = self.agent_runtime.api.session().abort()(
                self.raw,
                run_id,
                abortReason(signal),
                &diagnostic,
            );
            releaseOwned(self.agent_runtime.api, &diagnostic);
            self.lock();
            std.debug.assert(self.abort_calls_in_progress != 0);
            if (self.active_run_id == run_id) {
                const known = sdk.Status.fromCode(status) catch null;
                if (known == null or !isAbortStatus(known.?))
                    self.dependency_contract_failure = true;
                // Acceptance is monotonic, even if another path reports late.
                if (self.abort_status != .ok) {
                    self.raw_abort_status_code = status;
                    self.abort_status = known;
                }
            }
            self.abort_calls_in_progress -= 1;
            const retry = self.active_run_id == run_id and
                self.abort_retry_pending and self.input_window_started and
                self.registerRunAbortLocked(true);
            self.broadcast();
            self.unlock();
            if (!retry) return;
        }
    }

    fn finishPreparedRunLocked(self: *Session) void {
        std.debug.assert(!self.run_started and !self.core_call_in_progress);
        if (self.run_input) |*input| {
            input.deinit(self.agent_runtime.allocator);
            self.run_input = null;
        }
        self.clearRunToolsLocked();
        if (self.terminal_diagnostic) |buffer| {
            self.agent_runtime.allocator.free(buffer);
            self.terminal_diagnostic = null;
        }
        self.model_error = null;
        self.terminal_phase = null;
        self.callback_fatal_observed = false;
        self.run_done = true;
        if (self.state != .closing and self.state != .poisoned) self.state = .idle;
        self.broadcast();
    }

    fn finishPreparedCompactLocked(self: *Session) void {
        std.debug.assert(!self.compact_started and !self.core_call_in_progress);
        if (self.compact_terminal_diagnostic) |buffer| {
            self.agent_runtime.allocator.free(buffer);
            self.compact_terminal_diagnostic = null;
        }
        self.compact_done = true;
        if (self.state != .closing and self.state != .poisoned) self.state = .idle;
        self.broadcast();
    }

    fn finishCompactBeforeCoreCallLocked(self: *Session) CompactTerminalResult {
        std.debug.assert(!self.core_call_in_progress);
        self.compact_started = false;
        self.compact_done = true;
        if (self.state != .closing and self.state != .poisoned) self.state = .idle;
        const terminal = self.takeCompactTerminalResultLocked(
            null,
            null,
            .aborted,
            null,
            null,
        );
        self.broadcast();
        return terminal;
    }

    fn abortCompact(self: *Session, operation_id: u64) void {
        var diagnostic = emptyOwnedBytes();
        const status_code = self.agent_runtime.api.sessionControl().abortCompact()(
            self.raw,
            operation_id,
            &diagnostic,
        );
        releaseOwned(self.agent_runtime.api, &diagnostic);
        self.lock();
        std.debug.assert(self.abort_calls_in_progress != 0);
        if (self.active_compact_id == operation_id) {
            self.raw_compact_abort_status_code = status_code;
            self.compact_abort_status = sdk.Status.fromCode(status_code) catch null;
            if (self.compact_abort_status == null or
                !isCompactAbortStatus(self.compact_abort_status.?))
                self.dependency_contract_failure = true;
        }
        self.abort_calls_in_progress -= 1;
        self.broadcast();
        self.unlock();
    }

    fn copyCompactDiagnostic(self: *Session, diagnostic: wire.OwnedBytesV1) bool {
        const bytes = sdk.borrowedBytes(.{
            .ptr = diagnostic.ptr,
            .len = diagnostic.len,
        }) catch return false;
        const storage = self.compact_terminal_diagnostic orelse unreachable;
        const len = @min(bytes.len, storage.len);
        @memcpy(storage[0..len], bytes[0..len]);
        self.compact_terminal_diagnostic_len = len;
        self.compact_terminal_diagnostic_truncated = bytes.len != len;
        return true;
    }

    fn takeCompactTerminalResultLocked(
        self: *Session,
        abi_status: ?sdk.Status,
        raw_status_code: ?u32,
        outcome: ?CompactOutcome,
        result: ?*const wire.CompactResultV1,
        failure: ?TerminalFailure,
    ) CompactTerminalResult {
        const storage = self.compact_terminal_diagnostic orelse unreachable;
        self.compact_terminal_diagnostic = null;
        return .{
            .allocator = self.agent_runtime.allocator,
            .diagnostic_storage = storage,
            .diagnostic_len = self.compact_terminal_diagnostic_len,
            .diagnostic_truncated = self.compact_terminal_diagnostic_truncated,
            .abi_status = abi_status,
            .raw_status_code = raw_status_code,
            .abort_status = self.compact_abort_status,
            .raw_abort_status_code = self.raw_compact_abort_status_code,
            .outcome = outcome,
            .before_context_tokens = if (result) |value| value.before_context_tokens else 0,
            .after_context_tokens = if (result) |value| value.after_context_tokens else 0,
            .input_tokens = if (result) |value| value.input_tokens else 0,
            .output_tokens = if (result) |value| value.output_tokens else 0,
            .cache_read_input_tokens = if (result) |value| value.cache_read_input_tokens else 0,
            .cache_creation_input_tokens = if (result) |value| value.cache_creation_input_tokens else 0,
            .interruption = self.compact_interruption,
            .failure = if (self.dependency_contract_failure)
                .dependency_contract
            else
                failure,
            .session_disposition_at_completion = self.dispositionLocked(),
        };
    }

    fn copyTerminalDiagnostic(self: *Session, diagnostic: wire.OwnedBytesV1) bool {
        const bytes = sdk.borrowedBytes(.{ .ptr = diagnostic.ptr, .len = diagnostic.len }) catch
            return false;
        const storage = self.terminal_diagnostic orelse unreachable;
        const len = @min(bytes.len, storage.len);
        @memcpy(storage[0..len], bytes[0..len]);
        self.terminal_diagnostic_len = len;
        self.terminal_diagnostic_truncated = bytes.len != len;
        return true;
    }

    fn takeTerminalResultLocked(
        self: *Session,
        abi_status: ?sdk.Status,
        raw_status_code: ?u32,
        stop_reason: ?sdk.StopReason,
        raw_stop_reason_code: ?u32,
        failure: ?TerminalFailure,
        durable_budget: ?DurableBudgetObservation,
    ) TerminalResult {
        const storage = self.terminal_diagnostic orelse unreachable;
        self.terminal_diagnostic = null;
        const final_failure: ?TerminalFailure = if (self.dependency_contract_failure) .dependency_contract else failure;
        const observed_model_error = self.model_error;
        self.model_error = null;
        self.terminal_phase = null;
        self.callback_fatal_observed = false;
        return .{
            .allocator = self.agent_runtime.allocator,
            .diagnostic_storage = storage,
            .diagnostic_len = self.terminal_diagnostic_len,
            .diagnostic_truncated = self.terminal_diagnostic_truncated,
            .abi_status = abi_status,
            .raw_status_code = raw_status_code,
            .stop_reason = stop_reason,
            .raw_stop_reason_code = raw_stop_reason_code,
            .abort_status = self.abort_status,
            .raw_abort_status_code = self.raw_abort_status_code,
            .termination_signal = self.termination_signal,
            .first_callback_rejection = self.first_callback_rejection,
            .first_host_failure = self.first_host_failure,
            .controlled_callback_close = self.controlled_callback_close,
            .file_changes_lost = self.file_changes_lost.load(.acquire),
            .event_delivery_lost = self.event_delivery_lost.load(.acquire),
            .receipts = self.takeTerminalReceiptsLocked(),
            .failure = final_failure,
            .model_error = if (final_failure == .dependency_contract) null else observed_model_error,
            .session_disposition_at_completion = self.dispositionLocked(),
            .durable_budget = durable_budget,
            .input_counts = if (self.dependency_contract_failure) null else self.input_counts,
        };
    }

    /// Only admitted + failed + statically reusable errors need confirmation.
    /// Background jobs can make describe BUSY; retain the static disposition.
    // Deliberate read-only exception to unlocked Core effects: describe does
    // not invoke Host callbacks. The Run still owns its operation slot; keeping
    // the mutex here excludes credential mutation and close through confirmation.
    fn confirmRunDispositionLocked(self: *Session) void {
        var encoded = emptyOwnedBytes();
        defer releaseOwned(self.agent_runtime.api, &encoded);
        var diagnostic = emptyOwnedBytes();
        defer releaseOwned(self.agent_runtime.api, &diagnostic);
        const code = self.agent_runtime.api.sessionControl().describe()(self.raw, &encoded, &diagnostic);
        if (code == wire.STATUS_BUSY and encoded.ptr == null and encoded.len == 0) {
            std.log.debug("agent.run_health_confirmation session_id={d} run_id={d} result=busy_unconfirmed", .{ self.id, self.active_run_id });
            return;
        }
        if (code != wire.STATUS_OK) {
            self.state = .poisoned;
            return;
        }
        const bytes = sdk.borrowedBytes(.{ .ptr = encoded.ptr, .len = encoded.len }) catch {
            self.state = .poisoned;
            return;
        };
        var parsed = sdk.decodeSessionDescription(self.agent_runtime.allocator, bytes) catch {
            self.state = .poisoned;
            return;
        };
        defer parsed.deinit();
        const value = parsed.value;
        const matches = switch (self.core_session_identity) {
            .bound => |identity| std.mem.eql(u8, identity.bytes[0..identity.len], value.session_id),
            .unbound, .failed => false,
        };
        if (!value.registered or !matches or value.lifecycle != .idle) self.state = .poisoned;
    }

    fn dispositionLocked(self: *const Session) SessionDisposition {
        return switch (self.state) {
            .poisoned => .poisoned,
            .closing, .closed => .closing,
            .idle, .queued, .running, .waiting_ui, .compact_queued, .compacting, .checkpointing => .reusable,
        };
    }

    pub fn deinit(self: *Session) void {
        std.debug.assert(self.state == .closed);
        std.debug.assert(self.active_refs == 0);
        std.debug.assert(self.active_callback_refs == 0);
        std.debug.assert(self.compact_done);
        std.debug.assert(self.skill_restore_inputs == null);
        std.debug.assert(self.run_image == null);
        if (self.image_fixture_binding) |*binding| binding.deinit(self.agent_runtime.allocator);
        self.control_block.deinit();
        self.agent_runtime.allocator.destroy(self.control_block);
        if (self.run_input) |*input|
            input.deinit(self.agent_runtime.allocator);
        if (self.terminal_diagnostic) |buffer| self.agent_runtime.allocator.free(buffer);
        if (self.compact_terminal_diagnostic) |buffer|
            self.agent_runtime.allocator.free(buffer);
        if (self.ui_request_json) |json| self.agent_runtime.allocator.free(json);
        if (self.ui_response_json) |json| self.agent_runtime.allocator.free(json);
        self.agent_runtime.allocator.free(self.provider_id);
        self.agent_runtime.allocator.free(self.workspace_root);
        self.agent_runtime.allocator.free(self.workspace_home);
        self.agent_runtime.allocator.free(self.workspace_epoch);
        if (self.mcp_restore_selection) |selection| selection.deinit();
    }

    pub fn configureImageGenerationForTesting(self: *Session, input: ?ImageGenerationTestBinding) !void {
        if (self.agent_runtime.image_test == null) return error.InvalidLimits;
        var owned: ?image_generation.OwnedBinding = if (input) |binding|
            try image_generation.OwnedBinding.initForTesting(self.agent_runtime.allocator, binding)
        else
            null;
        errdefer if (owned) |*binding| binding.deinit(self.agent_runtime.allocator);
        self.lock();
        defer self.unlock();
        if (self.state != .idle) return error.SessionNotIdle;
        if (self.image_fixture_binding) |*binding| binding.deinit(self.agent_runtime.allocator);
        self.image_fixture_binding = owned;
    }

    fn clearRunToolsLocked(self: *Session) void {
        for (self.image_calls) |call| std.debug.assert(call == null);
        for (self.delivery_calls) |call| std.debug.assert(call == null);
        if (self.run_image) |*image| image.deinit(self.agent_runtime.allocator);
        self.run_image = null;
        self.run_delivery = null;
        self.run_mcp_installation = null;
    }

    fn imageLimits(self: *const Session) image_generation.Limits {
        return if (self.agent_runtime.image_test) |options| options.limits else image_generation.production_limits;
    }

    fn retainHostCallback(runtime: *Runtime, raw_run: ?*const wire.RunContextV1) ?*Session {
        const identity = sdk.validateRunContext(raw_run) catch return null;
        runtime.sessions_mutex.lockUncancelable(runtime.io);
        var retained: ?*Session = null;
        for (runtime.sessions) |entry| {
            const candidate = entry orelse continue;
            candidate.lock();
            const matches = candidate.raw != null and candidate.raw.? == identity.session;
            candidate.unlock();
            if (matches) {
                if (candidate.retainCoreCallback(raw_run, true) != null) retained = candidate;
                break;
            }
        }
        runtime.sessions_mutex.unlock(runtime.io);
        return retained;
    }

    fn rejectClosingHostCallback(self: *Session) bool {
        self.lock();
        defer self.unlock();
        if (self.state != .closing) return false;
        self.callback_fatal_observed = true;
        self.controlled_callback_close = self.close_interruption;
        return true;
    }

    fn failHostCallback(self: *Session) u32 {
        self.lock();
        defer self.unlock();
        self.callback_fatal_observed = true;
        self.recordCallbackRejectionLocked(.{ .boundary = .host_tool, .reason = .invalid_response });
        setTerminationSignalLocked(self, .{ .callback_failure = .event });
        return wire.HOST_FATAL;
    }

    pub fn executeImage(context: ?*anyopaque, raw_run: ?*const wire.RunContextV1, arguments: wire.BytesViewV1, out: ?*wire.OwnedBytesV1) callconv(.c) u32 {
        const runtime: *Runtime = @ptrCast(@alignCast(context orelse return wire.HOST_FATAL));
        if (out) |result_out| result_out.* = emptyOwnedBytes();
        const self = retainHostCallback(runtime, raw_run) orelse return wire.HOST_FATAL;
        defer self.releaseCoreCallback();
        const result_out = out orelse return self.failHostCallback();
        if (self.rejectClosingHostCallback()) return wire.HOST_FATAL;
        // Keep working and result capacity in one reservation through publication.
        // Allocate the owned result before sending or committing anything.
        const limits = self.imageLimits();
        if (!runtime.image_budget.acquire(limits.workingBytes()))
            return staticImageFailure(runtime, result_out, image_capacity_result);
        var reserved = limits.workingBytes();
        defer runtime.image_budget.release(reserved);
        const allocation_len = @sizeOf(ImageResultHeader) + limits.result_bytes;
        const allocation = runtime.allocator.alloc(u8, allocation_len) catch
            return staticImageFailure(runtime, result_out, image_capacity_result);
        var transferred = false;
        defer if (!transferred) runtime.allocator.free(allocation);
        const outcome = self.performImage(arguments);
        const encoded = generate_image.result(allocation[@sizeOf(ImageResultHeader)..], outcome) catch
            return staticImageFailure(runtime, result_out, image_unknown_result);
        if (outcome == .saved) {
            self.lock();
            defer self.unlock();
            for (&self.image_receipts) |*slot| if (slot.* == null) {
                slot.* = outcome.saved;
                break;
            };
        }
        reserved -= allocation_len;
        transferred = true;
        std.mem.bytesAsValue(ImageResultHeader, allocation[0..@sizeOf(ImageResultHeader)]).* = .{ .allocation_len = allocation_len };
        result_out.* = .{ .ptr = @constCast(encoded.ptr), .len = encoded.len };
        _ = runtime.image_results_created.fetchAdd(1, .monotonic);
        return if (outcome == .saved) wire.HOST_OK else wire.HOST_FAILED;
    }

    const ImageResultHeader = image_generation.ResultHeader;
    const image_capacity_result = "{\"status\":\"capacity\"}";
    const image_unknown_result = "{\"status\":\"outcome_unknown\"}";

    fn staticImageFailure(runtime: *Runtime, output: *wire.OwnedBytesV1, bytes: []const u8) u32 {
        output.* = .{ .ptr = @constCast(bytes.ptr), .len = bytes.len };
        _ = runtime.image_results_created.fetchAdd(1, .monotonic);
        return wire.HOST_FAILED;
    }

    pub fn releaseImageResult(context: ?*anyopaque, out: ?*wire.OwnedBytesV1) callconv(.c) void {
        const runtime: *Runtime = @ptrCast(@alignCast(context orelse return));
        const result_out = out orelse return;
        const ptr = result_out.ptr orelse return;
        if (ptr == image_capacity_result.ptr or ptr == image_unknown_result.ptr) {
            _ = runtime.image_results_released.fetchAdd(1, .monotonic);
            result_out.* = emptyOwnedBytes();
            return;
        }
        const allocation_ptr = ptr - @sizeOf(ImageResultHeader);
        const header = std.mem.bytesAsValue(ImageResultHeader, allocation_ptr[0..@sizeOf(ImageResultHeader)]).*;
        runtime.allocator.free(allocation_ptr[0..header.allocation_len]);
        runtime.image_budget.release(header.allocation_len);
        _ = runtime.image_results_released.fetchAdd(1, .monotonic);
        result_out.* = emptyOwnedBytes();
    }

    fn performImage(self: *Session, arguments: wire.BytesViewV1) image_generation.Outcome {
        const runtime = self.agent_runtime;
        const limits = self.imageLimits();
        if (arguments.len > limits.prompt_bytes * 6 + 64) return .{ .failed = .invalid_arguments };
        const bytes = sdk.borrowedBytes(arguments) catch return .{ .failed = .invalid_arguments };
        const prompt = generate_image.prompt(runtime.allocator, bytes, limits.prompt_bytes) catch return .{ .failed = .invalid_arguments };
        defer runtime.allocator.free(prompt);
        self.lock();
        if (self.state == .closing or self.state == .closed or self.termination_signal != null) {
            self.unlock();
            return .{ .failed = .cancelled };
        }
        const image = if (self.run_image) |*value| value else {
            self.unlock();
            return .{ .failed = .unavailable };
        };
        const transport = image.transport;
        var call: image_generation.Call = .{
            .cancellation = image_http.Cancellation.init(transport),
            .deadline_ns = std.Io.Timestamp.now(runtime.io, .awake).nanoseconds + @as(i96, limits.timeout_ms) * std.time.ns_per_ms,
            .io = runtime.io,
        };
        var slot: ?usize = null;
        for (self.image_calls, 0..) |active, i| if (active == null) {
            slot = i;
            break;
        };
        if (slot == null or self.image_sends >= limits.sends_per_run) {
            self.unlock();
            return .{ .failed = .capacity };
        }
        self.image_calls[slot.?] = &call;
        self.image_sends += 1;
        self.unlock();
        defer {
            self.lock();
            self.image_calls[slot.?] = null;
            if (!call.sent) self.image_sends -= 1;
            self.unlock();
        }
        const watchdog = std.Thread.spawn(.{}, image_generation.Call.watchdog, .{&call}) catch return .{ .failed = .capacity };
        defer {
            call.finished.store(true, .release);
            watchdog.join();
        }
        return image_generation.perform(runtime.allocator, transport, &image.binding, prompt, limits, &call);
    }

    const McpResultHeader = struct { allocation_len: usize };
    const mcp_busy_result = "{\"status\":\"busy\"}";
    pub fn executeMcpInstallation(context: ?*anyopaque, raw_run: ?*const wire.RunContextV1, arguments: wire.BytesViewV1, out: ?*wire.OwnedBytesV1) callconv(.c) u32 {
        const runtime: *Runtime = @ptrCast(@alignCast(context orelse return wire.HOST_FATAL));
        if (out) |result_out| result_out.* = emptyOwnedBytes();
        const self = retainHostCallback(runtime, raw_run) orelse return wire.HOST_FATAL;
        defer self.releaseCoreCallback();
        const result_out = out orelse return self.failHostCallback();
        if (self.rejectClosingHostCallback()) return wire.HOST_FATAL;
        const previous = runtime.mcp_results_outstanding.fetchAdd(1, .acq_rel);
        if (previous >= runtime.sessions.len * 8) {
            _ = runtime.mcp_results_outstanding.fetchSub(1, .acq_rel);
            result_out.* = .{ .ptr = @constCast(mcp_busy_result.ptr), .len = mcp_busy_result.len };
            return wire.HOST_FAILED;
        }
        var transferred = false;
        defer if (!transferred) {
            _ = runtime.mcp_results_outstanding.fetchSub(1, .acq_rel);
        };
        const allocation = runtime.allocator.alloc(u8, @sizeOf(McpResultHeader) + mcp_install.result_bytes) catch {
            result_out.* = .{ .ptr = @constCast(mcp_busy_result.ptr), .len = mcp_busy_result.len };
            return wire.HOST_FAILED;
        };
        defer if (!transferred) runtime.allocator.free(allocation);
        const outcome = self.performMcpInstallation(arguments);
        const encoded = mcp_install.result(allocation[@sizeOf(McpResultHeader)..], outcome) catch return self.failHostCallback();
        std.mem.bytesAsValue(McpResultHeader, allocation[0..@sizeOf(McpResultHeader)]).* = .{ .allocation_len = allocation.len };
        result_out.* = .{ .ptr = @constCast(encoded.ptr), .len = encoded.len };
        transferred = true;
        return if (outcome == .submitted) wire.HOST_OK else wire.HOST_FAILED;
    }
    pub fn releaseMcpInstallationResult(context: ?*anyopaque, out: ?*wire.OwnedBytesV1) callconv(.c) void {
        const runtime: *Runtime = @ptrCast(@alignCast(context orelse return));
        const result_out = out orelse return;
        const ptr = result_out.ptr orelse return;
        if (ptr != mcp_busy_result.ptr) {
            const base = ptr - @sizeOf(McpResultHeader);
            const header = std.mem.bytesAsValue(McpResultHeader, base[0..@sizeOf(McpResultHeader)]).*;
            runtime.allocator.free(base[0..header.allocation_len]);
            std.debug.assert(runtime.mcp_results_outstanding.fetchSub(1, .acq_rel) > 0);
        }
        result_out.* = emptyOwnedBytes();
    }
    fn performMcpInstallation(self: *Session, arguments: wire.BytesViewV1) mcp_install.Result {
        const bytes = sdk.borrowedBytes(arguments) catch return .invalid_arguments;
        self.lock();
        const input = self.run_mcp_installation;
        const run_id = self.active_run_id;
        const generation = self.active_run_generation;
        const cancelled = self.state == .closing or self.state == .closed or self.termination_signal != null;
        self.unlock();
        if (cancelled) return .cancelled;
        const capability = input orelse return .unavailable;
        var draft = mcp_install.decode(capability.allocator, bytes) catch |err| return if (err == error.OutOfMemory) .unavailable else .invalid_arguments;
        var moved = false;
        defer if (!moved) draft.deinit();
        self.lock();
        if (self.active_run_id != run_id or self.active_run_generation != generation or self.termination_signal != null or self.state == .closing or self.state == .closed) {
            self.unlock();
            return .cancelled;
        }
        const result = capability.try_put_fn(capability.context, capability.task_id, run_id, generation, draft);
        self.unlock();
        if (result == .submitted) {
            moved = true;
            capability.wake_fn(capability.context);
        }
        return result;
    }

    const DeliveryResultHeader = struct { allocation_len: usize };
    const delivery_capacity_result = "{\"status\":\"capacity\"}";

    pub fn executeDelivery(context: ?*anyopaque, raw_run: ?*const wire.RunContextV1, arguments: wire.BytesViewV1, out: ?*wire.OwnedBytesV1) callconv(.c) u32 {
        const runtime: *Runtime = @ptrCast(@alignCast(context orelse return wire.HOST_FATAL));
        if (out) |result_out| result_out.* = emptyOwnedBytes();
        const self = retainHostCallback(runtime, raw_run) orelse return wire.HOST_FATAL;
        defer self.releaseCoreCallback();
        const result_out = out orelse return self.failHostCallback();
        if (self.rejectClosingHostCallback()) return wire.HOST_FATAL;
        const previous = runtime.delivery_results_outstanding.fetchAdd(1, .acq_rel);
        if (previous >= runtime.sessions.len * deliver_file.max_receipts_per_run) {
            _ = runtime.delivery_results_outstanding.fetchSub(1, .acq_rel);
            result_out.* = .{ .ptr = @constCast(delivery_capacity_result.ptr), .len = delivery_capacity_result.len };
            return wire.HOST_FAILED;
        }
        var transferred = false;
        defer if (!transferred) {
            _ = runtime.delivery_results_outstanding.fetchSub(1, .acq_rel);
        };
        const allocation_len = @sizeOf(DeliveryResultHeader) + deliver_file.result_bytes;
        const allocation = runtime.allocator.alloc(u8, allocation_len) catch {
            result_out.* = .{ .ptr = @constCast(delivery_capacity_result.ptr), .len = delivery_capacity_result.len };
            return wire.HOST_FAILED;
        };
        defer if (!transferred) runtime.allocator.free(allocation);
        const outcome = self.performDelivery(arguments);
        const encoded = deliver_file.result(allocation[@sizeOf(DeliveryResultHeader)..], outcome) catch return self.failHostCallback();
        std.mem.bytesAsValue(DeliveryResultHeader, allocation[0..@sizeOf(DeliveryResultHeader)]).* = .{ .allocation_len = allocation_len };
        result_out.* = .{ .ptr = @constCast(encoded.ptr), .len = encoded.len };
        transferred = true;
        return if (outcome == .verified) wire.HOST_OK else wire.HOST_FAILED;
    }

    pub fn releaseDeliveryResult(context: ?*anyopaque, out: ?*wire.OwnedBytesV1) callconv(.c) void {
        const runtime: *Runtime = @ptrCast(@alignCast(context orelse return));
        const result_out = out orelse return;
        const ptr = result_out.ptr orelse return;
        if (ptr != delivery_capacity_result.ptr) {
            const base = ptr - @sizeOf(DeliveryResultHeader);
            const header = std.mem.bytesAsValue(DeliveryResultHeader, base[0..@sizeOf(DeliveryResultHeader)]).*;
            runtime.allocator.free(base[0..header.allocation_len]);
            std.debug.assert(runtime.delivery_results_outstanding.fetchSub(1, .acq_rel) > 0);
        }
        result_out.* = emptyOwnedBytes();
    }

    fn performDelivery(self: *Session, arguments: wire.BytesViewV1) deliver_file.Outcome {
        const runtime = self.agent_runtime;
        const bytes = sdk.borrowedBytes(arguments) catch return .{ .failed = .invalid_arguments };
        const path = deliver_file.pathArgument(runtime.allocator, bytes) catch |err|
            return .{ .failed = if (err == error.OutOfMemory) .capacity else .invalid_arguments };
        defer runtime.allocator.free(path);
        self.lock();
        if (self.state == .closing or self.state == .closed or self.termination_signal != null) {
            self.unlock();
            return .{ .failed = .cancelled };
        }
        const input = self.run_delivery orelse {
            self.unlock();
            return .{ .failed = .unavailable };
        };
        var cancelled = std.atomic.Value(bool).init(false);
        var slot: ?usize = null;
        for (self.delivery_calls, 0..) |call, index| if (call == null) {
            slot = index;
            break;
        };
        if (slot == null or self.delivery_attempts >= deliver_file.max_receipts_per_run) {
            self.unlock();
            return .{ .failed = .capacity };
        }
        self.delivery_calls[slot.?] = &cancelled;
        self.delivery_attempts += 1;
        self.unlock();
        defer {
            self.lock();
            self.delivery_calls[slot.?] = null;
            self.unlock();
        }
        var id: [16]u8 = undefined;
        std.Io.randomSecure(runtime.io, &id) catch return .{ .failed = .read_failed };
        if (std.mem.allEqual(u8, &id, 0)) return .{ .failed = .read_failed };
        const inspected = input.inspect_fn(input.context, path, &cancelled);
        self.lock();
        defer self.unlock();
        if (cancelled.load(.acquire) or self.termination_signal != null) return .{ .failed = .cancelled };
        const checked = switch (inspected) {
            .failed => |failure| return .{ .failed = failure },
            .verified => |value| value,
        };
        const receipt = FileDeliveryReceipt.init(id, path, checked.size_bytes, checked.sha256) catch return .{ .failed = .invalid_arguments };
        for (&self.delivery_receipts) |*entry| if (entry.* == null) {
            entry.* = receipt;
            return .{ .verified = receipt };
        };
        return .{ .failed = .capacity };
    }

    const MatchedDelivery = struct { slot: usize, receipt: FileDeliveryReceipt };
    const MatchedImage = struct { slot: usize, path: []u8 };

    fn matchDeliveredFile(self: *Session, event: sdk.DecodedCoreEvent) ?MatchedDelivery {
        const result = switch (event) {
            .known => |value| switch (value) {
                .tool_result => |value_result| value_result,
                else => return null,
            },
            .unknown => return null,
        };
        if (result.is_error or !std.mem.eql(u8, result.name, deliver_file.name)) return null;
        self.lock();
        defer self.unlock();
        for (self.delivery_receipts, 0..) |entry, index| {
            if (self.matched_delivery_receipts[index]) continue;
            const receipt = entry orelse continue;
            var buffer: [deliver_file.result_bytes]u8 = undefined;
            const expected = deliver_file.result(&buffer, .{ .verified = receipt }) catch unreachable;
            if (!std.mem.eql(u8, expected, result.content)) continue;
            self.matched_delivery_receipts[index] = true;
            return .{ .slot = index, .receipt = receipt };
        }
        return null;
    }

    fn matchGeneratedImage(self: *Session, event: sdk.DecodedCoreEvent) !?MatchedImage {
        const result = switch (event) {
            .known => |value| switch (value) {
                .tool_result => |result| result,
                else => return null,
            },
            .unknown => return null,
        };
        if (result.is_error or !std.mem.eql(u8, result.name, generate_image.name)) return null;
        self.lock();
        defer self.unlock();
        for (self.image_receipts, 0..) |slot, index| {
            if (self.matched_image_receipts[index] != null) continue;
            const receipt = slot orelse continue;
            var buffer: [4096]u8 = undefined;
            const expected = generate_image.result(&buffer, .{ .saved = receipt }) catch unreachable;
            if (!std.mem.eql(u8, result.content, expected)) continue;
            self.matched_image_receipts[index] = toolRouteDigest(result.id);
            const path = try self.agent_runtime.allocator.dupe(u8, receipt.pathView());
            return .{ .slot = index, .path = path };
        }
        return null;
    }

    fn acknowledgeReceipts(self: *Session, delivery: ?usize, image: ?usize) void {
        self.lock();
        defer self.unlock();
        if (delivery) |index| {
            std.debug.assert(self.matched_delivery_receipts[index]);
            self.delivery_receipts[index] = null;
            self.matched_delivery_receipts[index] = false;
        }
        if (image) |index| {
            std.debug.assert(self.matched_image_receipts[index] != null);
            self.image_receipts[index] = null;
            self.matched_image_receipts[index] = null;
        }
    }

    fn takeTerminalReceiptsLocked(self: *Session) TerminalReceipts {
        var receipts: TerminalReceipts = .{};
        for (&self.delivery_receipts, 0..) |*entry, index| {
            if (!self.matched_delivery_receipts[index]) continue;
            receipts.delivered_files[index] = entry.*;
            entry.* = null;
            self.matched_delivery_receipts[index] = false;
        }
        for (&self.image_receipts, 0..) |*entry, index| {
            const digest = self.matched_image_receipts[index] orelse continue;
            receipts.generated_images[index] = .{ .tool_route_digest = digest, .receipt = entry.*.? };
            entry.* = null;
            self.matched_image_receipts[index] = null;
        }
        return receipts;
    }

    pub fn onEvent(context: ?*anyopaque, raw_run: ?*const wire.RunContextV1, event_json: wire.BytesViewV1) callconv(.c) u32 {
        const self: *Session = @ptrCast(@alignCast(context orelse return wire.EVENT_FATAL));
        const run_id = self.retainCoreCallback(raw_run, true) orelse {
            recordFatalReply(context);
            return wire.EVENT_FATAL;
        };
        defer self.releaseCoreCallback();
        const reply = self.handleEvent(run_id, event_json);
        if (reply == wire.EVENT_FATAL) recordFatalReply(context);
        return reply;
    }

    pub fn onUiRequest(context: ?*anyopaque, raw_run: ?*const wire.RunContextV1, request_json: wire.BytesViewV1, out_response: ?*wire.OwnedBytesV1) callconv(.c) u32 {
        if (out_response) |out| out.* = emptyOwnedBytes();
        const self: *Session = @ptrCast(@alignCast(context orelse return wire.UI_FATAL));
        const run_id = self.retainCoreCallback(raw_run, true) orelse {
            recordFatalReply(context);
            return wire.UI_FATAL;
        };
        defer self.releaseCoreCallback();
        const reply = self.handleUiRequest(run_id, request_json, out_response);
        if (reply == wire.UI_FATAL) recordFatalReply(context);
        return reply;
    }

    fn recordFatalReply(context: ?*anyopaque) void {
        const self: *Session = @ptrCast(@alignCast(context orelse return));
        self.lock();
        defer self.unlock();
        if (!self.run_done) self.callback_fatal_observed = true;
    }

    fn handleEvent(self: *Session, run_id: u64, event_json: wire.BytesViewV1) u32 {
        const encoded = sdk.borrowedBytes(event_json) catch {
            self.recordCallbackRejection(.{ .boundary = .event_decode, .reason = .invalid_bytes });
            self.recordTerminationSignal(.{ .event_pump_failure = .invalid_event });
            return wire.EVENT_FATAL;
        };
        if (encoded.len > self.agent_runtime.max_event_bytes) {
            if (session_wire.classifyDegradableCoreEvent(encoded) == .file_changes) {
                self.file_changes_lost.store(true, .release);
                return wire.EVENT_CONTINUE;
            }
            self.recordTerminationSignal(.{ .event_pump_failure = .event_too_large });
            self.recordCallbackRejection(.{ .boundary = .event_decode, .reason = .oversized, .encoded_bytes = encoded.len });
            return wire.EVENT_FATAL;
        }
        var parsed = decodeCoreEvent(self.agent_runtime.allocator, encoded) catch |err| {
            if (err == error.OutOfMemory and
                session_wire.classifyDegradableCoreEvent(encoded) == .file_changes)
            {
                self.file_changes_lost.store(true, .release);
                return wire.EVENT_CONTINUE;
            }
            self.recordTerminationSignal(.{ .event_pump_failure = .invalid_event });
            self.recordCallbackRejection(.{ .boundary = .event_decode, .reason = .decode_failed, .failure = err, .encoded_bytes = encoded.len });
            return wire.EVENT_FATAL;
        };
        switch (parsed.value) {
            .known => {},
            .unknown => {
                parsed.deinit();
                return wire.EVENT_CONTINUE;
            },
        }
        if (parsed.value.known == .model_error) {
            self.lock();
            const accepted = self.captureModelErrorLocked(parsed.value.known.model_error, run_id, encoded.len);
            self.unlock();
            parsed.deinit();
            return if (accepted) wire.EVENT_CONTINUE else wire.EVENT_FATAL;
        }
        self.lock();
        var input_event_valid = true;
        var abort_after_start = false;
        var abort_signal: ?TerminationSignal = null;
        switch (parsed.value.known) {
            .run_state => |state| {
                if (state.run_id != run_id) {
                    input_event_valid = false;
                } else switch (state.phase) {
                    .starting => {
                        if (self.input_window_started or state.transition_seq != 1) {
                            input_event_valid = false;
                        } else {
                            self.input_window_started = true;
                            self.input_ready = self.run_input != null and self.run_input.? != .skill;
                            abort_after_start = self.registerRunAbortLocked(true);
                            abort_signal = self.termination_signal;
                        }
                    },
                    .finalizing => self.input_ready = false,
                    .completed, .failed, .aborted, .poisoned => {
                        self.input_ready = false;
                        if (self.terminal_phase != null) {
                            input_event_valid = false;
                        } else self.terminal_phase = state.phase;
                    },
                    else => {},
                }
            },
            .output_segment_begin => |segment| {
                if (self.output_segment != null or (self.last_output_index != null and segment.index <= self.last_output_index.?)) {
                    input_event_valid = false;
                } else {
                    self.output_segment = .{ .index = segment.index, .turn = segment.turn, .group = segment.group };
                    self.last_output_index = segment.index;
                }
            },
            .text_chunk => |text| if (self.output_segment) |*open| {
                open.bytes = std.math.add(u64, open.bytes, text.len) catch overflow: {
                    input_event_valid = false;
                    break :overflow open.bytes;
                };
            },
            .output_segment_end => |segment| {
                if (self.output_segment) |open| {
                    input_event_valid = open.index == segment.index and open.turn == segment.turn and open.group == segment.group and open.bytes == segment.bytes;
                    if (input_event_valid) self.output_segment = null;
                } else input_event_valid = false;
            },
            .input_adopted => |input| input_event_valid = self.submitted_inputs.adopt(input.input_id, input.sequence, input.turn),
            else => {},
        }
        if (!input_event_valid) {
            const output_event = switch (parsed.value.known) {
                .output_segment_begin, .output_segment_end, .text_chunk => true,
                else => false,
            };
            self.recordCallbackRejectionLocked(.{ .boundary = if (output_event) .output_event else .input_event, .reason = if (output_event) .invalid_output_segment else .invalid_input_transition, .event = std.meta.activeTag(parsed.value.known), .encoded_bytes = encoded.len, .input_adoption = switch (parsed.value.known) {
                .input_adopted => |value| .{ .id = value.input_id, .sequence = value.sequence, .turn = value.turn },
                else => null,
            }, .observed_run_id = switch (parsed.value.known) {
                .run_state => |value| value.run_id,
                else => null,
            } });
            self.failCoreIdentityLocked();
        }
        self.unlock();
        if (!input_event_valid) {
            parsed.deinit();
            return wire.EVENT_FATAL;
        }
        // Close can stop the queue before starting arrives. Deliver cancellation
        // before enqueueWaiting can return ConsumerStopped.
        if (abort_after_start) self.abortRun(run_id, abort_signal.?);
        const is_file_changes = switch (parsed.value) {
            .unknown => false,
            .known => |known| std.meta.activeTag(known) == .file_changes,
        };
        const owned_json = self.agent_runtime.allocator.dupe(u8, encoded) catch {
            const kind = std.meta.activeTag(parsed.value.known);
            parsed.deinit();
            if (is_file_changes) {
                self.file_changes_lost.store(true, .release);
                return wire.EVENT_CONTINUE;
            }
            self.recordTerminationSignal(.{ .event_pump_failure = .allocation });
            self.recordCallbackRejection(.{ .boundary = .event_copy, .reason = .allocation, .event = kind, .encoded_bytes = encoded.len });
            return wire.EVENT_FATAL;
        };
        const generated_image = self.matchGeneratedImage(parsed.value) catch {
            self.recordCallbackRejection(.{ .boundary = .event_copy, .reason = .allocation, .event = std.meta.activeTag(parsed.value.known), .encoded_bytes = encoded.len });
            self.agent_runtime.allocator.free(owned_json);
            parsed.deinit();
            self.recordTerminationSignal(.{ .event_pump_failure = .allocation });
            return wire.EVENT_FATAL;
        };
        const delivered_file = self.matchDeliveredFile(parsed.value);
        var envelope = OwnedCoreEvent{
            .generated_image_path = if (generated_image) |image| image.path else null,
            .delivered_file = if (delivered_file) |delivery| delivery.receipt else null,
            .session_id = self.id,
            .run_id = run_id,
            .encoded_bytes = encoded.len,
            .json = owned_json,
            .event = parsed,
            .allocator = self.agent_runtime.allocator,
        };
        const event_kind = std.meta.activeTag(parsed.value.known);
        const admission: event_pump.Error!void = self.agent_runtime.events.enqueueWaiting(envelope, &self.event_delivery_stopped);
        admission catch |err| {
            envelope.deinit();
            if (err == error.ConsumerStopped) {
                self.event_delivery_lost.store(true, .release);
                if (is_file_changes) self.file_changes_lost.store(true, .release);
                return wire.EVENT_CONTINUE;
            }
            if (is_file_changes and err == error.EventTooLarge) {
                self.file_changes_lost.store(true, .release);
                return wire.EVENT_CONTINUE;
            }
            self.recordTerminationSignal(.{ .event_pump_failure = switch (err) {
                error.EventTooLarge => .event_too_large,
                error.InvalidIdentity,
                error.InvalidLimits,
                => .invalid_event,
                error.GlobalCapacity,
                error.SessionCapacity,
                error.SessionSlotCapacity,
                error.SequenceExhausted,
                => .capacity,
                error.ConsumerStopped => unreachable,
            } });
            self.recordCallbackRejection(.{ .boundary = .event_pump, .reason = .queue_rejected, .event = event_kind, .failure = err, .encoded_bytes = encoded.len });
            return wire.EVENT_FATAL;
        };
        // The consumer may already have released the envelope. Only captured
        // slot identities are used after successful ownership transfer.
        self.acknowledgeReceipts(if (delivered_file) |delivery| delivery.slot else null, if (generated_image) |image| image.slot else null);
        const notification_failed = self.agent_runtime.notifyEventConsumer() == .unavailable;
        if (notification_failed) {
            self.stopEventDelivery();
            // Matching abort is explicitly allowed from a Core callback.
            // A close already in progress owns its own abort and join.
            self.requestTermination(run_id, .{ .interrupted = .session_close }) catch {};
        }
        return wire.EVENT_CONTINUE;
    }

    fn handleUiRequest(self: *Session, callback_run_id: u64, request_json: wire.BytesViewV1, out_response: ?*wire.OwnedBytesV1) u32 {
        const output = out_response orelse {
            self.recordCallbackRejection(.{ .boundary = .ui_response, .reason = .invalid_response });
            self.recordTerminationSignal(.{ .callback_failure = .ui });
            return wire.UI_FATAL;
        };
        const encoded_request = sdk.borrowedBytes(request_json) catch {
            self.recordCallbackRejection(.{ .boundary = .ui_decode, .reason = .invalid_bytes });
            self.recordTerminationSignal(.{ .callback_failure = .ui });
            return wire.UI_FATAL;
        };
        if (encoded_request.len > self.agent_runtime.max_ui_request_bytes) {
            self.recordCallbackRejection(.{ .boundary = .ui_decode, .reason = .oversized, .encoded_bytes = encoded_request.len });
            self.recordTerminationSignal(.{ .event_pump_failure = .event_too_large });
            return wire.UI_FATAL;
        }
        var parsed = decodeUiRequest(self.agent_runtime.allocator, encoded_request) catch |err| {
            self.recordCallbackRejection(.{ .boundary = .ui_decode, .reason = .decode_failed, .failure = err, .encoded_bytes = encoded_request.len });
            self.recordTerminationSignal(.{ .callback_failure = .ui });
            return wire.UI_FATAL;
        };
        defer parsed.deinit();
        if (!capabilities.allowsUiRequest(parsed.value)) {
            self.recordCallbackRejection(.{ .boundary = .ui_admission, .reason = .unsupported_request, .encoded_bytes = encoded_request.len });
            self.recordTerminationSignal(.{ .callback_failure = .ui });
            return wire.UI_FATAL;
        }
        const owned_request = if (self.permission_interaction == .interactive)
            self.agent_runtime.allocator.dupe(u8, encoded_request) catch {
                self.recordCallbackRejection(.{ .boundary = .ui_admission, .reason = .allocation, .encoded_bytes = encoded_request.len });
                self.recordTerminationSignal(.{ .event_pump_failure = .allocation });
                return wire.UI_FATAL;
            }
        else
            null;

        self.lock();
        if (!self.coreIdentityHealthyLocked() or
            !self.uiRequestIdentityMatchesLocked(parsed.value, callback_run_id))
        {
            self.recordCallbackRejectionLocked(.{ .boundary = .ui_admission, .reason = .identity_mismatch, .encoded_bytes = encoded_request.len });
            self.failCoreIdentityLocked();
            self.unlock();
            if (owned_request) |bytes| self.agent_runtime.allocator.free(bytes);
            return wire.UI_FATAL;
        }
        if (self.state == .closing) {
            self.controlled_callback_close = self.close_interruption;
            self.unlock();
            if (owned_request) |bytes| self.agent_runtime.allocator.free(bytes);
            return wire.UI_FATAL;
        }
        if (self.state != .running or self.ui_active) {
            self.recordCallbackRejectionLocked(.{ .boundary = .ui_admission, .reason = .invalid_state, .encoded_bytes = encoded_request.len });
            setTerminationSignalLocked(self, .{ .callback_failure = .ui });
            self.unlock();
            if (owned_request) |bytes| self.agent_runtime.allocator.free(bytes);
            return wire.UI_FATAL;
        }
        if (self.permission_interaction == .noninteractive) {
            setTerminationSignalLocked(self, .permission_required);
            self.permission_stop_requested = true;
            self.broadcast();
            self.unlock();
            const unavailable = self.agent_runtime.notifyEventConsumer() == .unavailable;
            if (unavailable)
                self.recordCallbackRejection(.{ .boundary = .notifier, .reason = .consumer_unavailable, .encoded_bytes = encoded_request.len });
            return if (unavailable) wire.UI_FATAL else wire.UI_UNAVAILABLE;
        }
        if (self.ui_request_id == std.math.maxInt(u64)) {
            self.recordCallbackRejectionLocked(.{ .boundary = .ui_admission, .reason = .counter_exhausted, .encoded_bytes = encoded_request.len });
            self.dependency_contract_failure = true;
            self.unlock();
            self.agent_runtime.allocator.free(owned_request.?);
            return wire.UI_FATAL;
        }
        self.ui_request_id += 1;
        self.ui_input_adopted_count = self.submitted_inputs.adopted;
        self.ui_active = true;
        self.ui_answered = false;
        std.debug.assert(self.ui_request_json == null);
        std.debug.assert(self.ui_request_value == null);
        std.debug.assert(self.ui_response_json == null);
        self.ui_request_json = owned_request.?;
        self.ui_request_value = &parsed.value;
        self.state = .waiting_ui;
        self.broadcast();
        self.unlock();

        const notification_failed = self.agent_runtime.notifyEventConsumer() == .unavailable;
        if (notification_failed) {
            self.lock();
            self.recordCallbackRejectionLocked(.{ .boundary = .notifier, .reason = .consumer_unavailable, .encoded_bytes = encoded_request.len });
            setTerminationSignalLocked(self, .{
                .event_consumer_notification_failure = .unavailable,
            });
            self.ui_active = false;
            if (self.state == .waiting_ui) self.state = .running;
            self.broadcast();
            self.unlock();
        }

        // The wait is indefinite by contract: a UI request ends only through
        // an answer, cancellation, close, or Runtime shutdown — every one of
        // those paths wakes this loop (wakeUiLocked / respond paths). A
        // human decision must never be expired by the Host.
        self.lock();
        while (self.ui_active and self.state == .waiting_ui)
            self.wait();
        if (self.state == .waiting_ui) self.state = .running;
        const identity_healthy = self.coreIdentityHealthyLocked();
        const answered = self.ui_answered and identity_healthy and
            self.termination_signal == null and self.state != .closing;
        const response = self.ui_response_json;
        self.ui_response_json = null;
        const request_copy = self.ui_request_json.?;
        self.ui_request_json = null;
        self.ui_request_value = null;
        self.broadcast();
        self.unlock();

        self.agent_runtime.allocator.free(request_copy);
        _ = self.agent_runtime.notifyEventConsumer();

        if (answered) {
            const bytes = response orelse {
                self.recordCallbackRejection(.{ .boundary = .ui_response, .reason = .invalid_response });
                self.recordTerminationSignal(.{ .callback_failure = .ui });
                return wire.UI_FATAL;
            };
            output.* = .{ .ptr = bytes.ptr, .len = bytes.len };
            return wire.UI_ANSWERED;
        }
        if (response) |bytes| self.agent_runtime.allocator.free(bytes);
        return if (notification_failed or !identity_healthy)
            wire.UI_FATAL
        else
            wire.UI_UNAVAILABLE;
    }

    pub fn releaseUiResponse(context: ?*anyopaque, out: ?*wire.OwnedBytesV1) callconv(.c) void {
        const self: *Session = @ptrCast(@alignCast(context orelse return));
        const value = out orelse return;
        const len = std.math.cast(usize, value.len) orelse return;
        const ptr = value.ptr orelse {
            value.* = emptyOwnedBytes();
            return;
        };
        self.agent_runtime.allocator.free(ptr[0..len]);
        value.* = emptyOwnedBytes();
    }

    fn captureModelErrorLocked(self: *Session, value: ModelError.View, run_id: u64, encoded_bytes: usize) bool {
        const rejection: CallbackRejection.Reason = if (value.run_id != run_id)
            .identity_mismatch
        else if (self.terminal_phase != null)
            .model_error_after_terminal
        else if (self.model_error != null)
            .duplicate_model_error
        else capture: {
            self.model_error = ModelError.init(value) catch break :capture .invalid_model_error;
            return true;
        };
        self.recordCallbackRejectionLocked(.{
            .boundary = .model_error,
            .reason = rejection,
            .event = .model_error,
            .observed_run_id = value.run_id,
            .encoded_bytes = encoded_bytes,
        });
        self.failCoreIdentityLocked();
        return false;
    }

    fn retainCoreCallback(
        self: *Session,
        raw_run: ?*const wire.RunContextV1,
        allow_closing: bool,
    ) ?u64 {
        const run = sdk.validateRunContext(raw_run) catch {
            self.recordCallbackRejection(.{ .boundary = .admission, .reason = .invalid_context });
            self.rejectInvalidCoreIdentity();
            return null;
        };
        self.lock();
        defer self.unlock();
        if (self.state == .closed or (self.state == .closing and !allow_closing)) return null;
        if (self.raw == null or run.session != self.raw.? or
            !self.run_started or !self.core_call_in_progress or
            run.run_id != self.active_run_id)
        {
            self.recordCallbackRejectionLocked(.{ .boundary = .admission, .reason = .identity_mismatch, .observed_run_id = run.run_id, .session_handle_matches = self.raw != null and run.session == self.raw.? });
            self.failCoreIdentityLocked();
            return null;
        }
        switch (self.core_session_identity) {
            .unbound => {
                var binding = CoreSessionIdentity{ .bound = .{
                    .len = run.session_id.len,
                    .bytes = [_]u8{0} ** max_core_session_id_bytes,
                } };
                @memcpy(
                    binding.bound.bytes[0..run.session_id.len],
                    run.session_id,
                );
                self.core_session_identity = binding;
            },
            .bound => |binding| {
                if (!std.mem.eql(
                    u8,
                    binding.bytes[0..binding.len],
                    run.session_id,
                )) {
                    self.recordCallbackRejectionLocked(.{ .boundary = .admission, .reason = .identity_mismatch, .observed_run_id = run.run_id, .session_handle_matches = true, .session_identity_matches = false });
                    self.failCoreIdentityLocked();
                    return null;
                }
            },
            .failed => return null,
        }
        self.active_refs += 1;
        self.active_callback_refs += 1;
        return run.run_id;
    }

    fn recordCallbackRejection(self: *Session, rejection: CallbackRejection) void {
        self.lock();
        defer self.unlock();
        self.recordCallbackRejectionLocked(rejection);
    }

    fn recordCallbackRejectionLocked(self: *Session, rejection: CallbackRejection) void {
        if (!self.run_done and self.first_callback_rejection == null) {
            var observation = rejection;
            observation.host_run_id = self.active_run_id;
            observation.state = self.state;
            self.first_callback_rejection = observation;
        }
    }

    fn releaseCoreCallback(self: *Session) void {
        self.lock();
        defer self.unlock();
        std.debug.assert(self.active_refs > 0);
        std.debug.assert(self.active_callback_refs > 0);
        self.active_refs -= 1;
        self.active_callback_refs -= 1;
        if (self.active_refs == 0 or self.active_callback_refs == 0) self.broadcast();
    }

    fn coreIdentityHealthyLocked(self: *const Session) bool {
        if (self.dependency_contract_failure) return false;
        return switch (self.core_session_identity) {
            .bound => true,
            .unbound, .failed => false,
        };
    }

    fn uiRequestIdentityMatchesLocked(
        self: *const Session,
        request: sdk.UiRequest,
        run_id: u64,
    ) bool {
        return switch (request) {
            .ask_question => false,
            .permission => |permission| permission.run_id == run_id and
                switch (self.core_session_identity) {
                    .bound => |binding| std.mem.eql(
                        u8,
                        binding.bytes[0..binding.len],
                        permission.session_id,
                    ),
                    .unbound, .failed => false,
                },
        };
    }

    fn rejectInvalidCoreIdentity(self: *Session) void {
        self.lock();
        defer self.unlock();
        if (self.state == .closing or self.state == .closed) return;
        self.failCoreIdentityLocked();
    }

    fn failCoreIdentityLocked(self: *Session) void {
        self.core_session_identity = .failed;
        self.dependency_contract_failure = true;
        if (!self.run_started) {
            switch (self.state) {
                .idle => self.state = .poisoned,
                .queued => {
                    self.state = .poisoned;
                    self.finishPreparedRunLocked();
                },
                .compact_queued => {
                    self.state = .poisoned;
                    self.finishPreparedCompactLocked();
                },
                .poisoned, .closing, .closed => {},
                .checkpointing => self.state = .poisoned,
                .running, .waiting_ui, .compacting => unreachable,
            }
        }
        if (self.ui_active) {
            self.ui_active = false;
            if (self.state == .waiting_ui) self.state = .running;
        }
        self.broadcast();
    }
};

fn recordHostFailureLocked(self: *Session, signal: TerminationSignal) void {
    if (self.first_host_failure == null)
        self.first_host_failure = HostFailure.fromSignal(signal);
}

fn setTerminationSignalLocked(self: *Session, signal: TerminationSignal) void {
    recordHostFailureLocked(self, signal);
    if (self.termination_signal == null) self.termination_signal = signal;
    for (self.image_calls) |call| if (call) |active| active.cancellation.request();
    for (self.delivery_calls) |call| if (call) |active| active.store(true, .release);
}

fn isRunProgressState(state: SessionState) bool {
    return state == .queued or state == .running or state == .waiting_ui;
}

fn compactOutcome(code: u32) error{UnknownCompactOutcome}!CompactOutcome {
    return switch (code) {
        wire.COMPACT_COMPACTED => .compacted,
        wire.COMPACT_NO_CHANGE => .no_change,
        wire.COMPACT_DEGRADED => .degraded,
        wire.COMPACT_ABORTED => .aborted,
        else => error.UnknownCompactOutcome,
    };
}

pub const SessionStatusDisposition = enum {
    reusable,
    poisoned,
};

fn compactStatusDisposition(status: sdk.Status) ?SessionStatusDisposition {
    return switch (status) {
        .out_of_memory, .invalid_state, .core_error, .internal_error => .poisoned,
        .ok,
        .invalid_argument,
        .busy,
        .resource_limit,
        .stale_compact,
        .checkpoint_budget_required,
        => .reusable,
        .stale_run,
        .too_late,
        .callback_failed,
        .skill_catalog_invalid,
        .stale_catalog,
        .skill_not_found,
        .invalid_skill_arguments,
        .skill_policy_violation,
        .skill_unavailable,
        .checkpoint_corrupt,
        .checkpoint_unsupported,
        .checkpoint_incompatible,
        .checkpoint_io,
        .logical_session_conflict,
        .mcp_not_refreshed,
        .invalid_mcp_selection,
        .skill_catalog_incomplete,
        .image_input_unsupported,
        .image_input_capability_unknown,
        .goal_conflict,
        => null,
    };
}

fn isCompactAbortStatus(status: sdk.Status) bool {
    return switch (status) {
        .ok, .invalid_argument, .too_late, .invalid_state, .stale_compact => true,
        .out_of_memory,
        .busy,
        .stale_run,
        .core_error,
        .callback_failed,
        .internal_error,
        .resource_limit,
        .skill_catalog_invalid,
        .stale_catalog,
        .skill_not_found,
        .invalid_skill_arguments,
        .skill_policy_violation,
        .skill_unavailable,
        .checkpoint_budget_required,
        .checkpoint_corrupt,
        .checkpoint_unsupported,
        .checkpoint_incompatible,
        .checkpoint_io,
        .logical_session_conflict,
        .mcp_not_refreshed,
        .invalid_mcp_selection,
        .skill_catalog_incomplete,
        .image_input_unsupported,
        .image_input_capability_unknown,
        .goal_conflict,
        => false,
    };
}

fn skillUpdateStatusDisposition(status: sdk.Status) ?SessionStatusDisposition {
    return switch (status) {
        .ok,
        .invalid_argument,
        .out_of_memory,
        .busy,
        .core_error,
        .resource_limit,
        .skill_unavailable,
        .checkpoint_budget_required,
        => .reusable,
        .invalid_state => .poisoned,
        .stale_run,
        .too_late,
        .callback_failed,
        .internal_error,
        .skill_catalog_invalid,
        .stale_catalog,
        .skill_not_found,
        .invalid_skill_arguments,
        .skill_policy_violation,
        .stale_compact,
        .checkpoint_corrupt,
        .checkpoint_unsupported,
        .checkpoint_incompatible,
        .checkpoint_io,
        .logical_session_conflict,
        .mcp_not_refreshed,
        .invalid_mcp_selection,
        .skill_catalog_incomplete,
        .image_input_unsupported,
        .image_input_capability_unknown,
        .goal_conflict,
        => null,
    };
}

fn runStatusDisposition(status: sdk.Status, has_images: bool) ?SessionStatusDisposition {
    if (status == .image_input_unsupported or status == .image_input_capability_unknown)
        return if (has_images) .reusable else null;
    return switch (status) {
        .out_of_memory,
        .invalid_state,
        .core_error,
        .callback_failed,
        .internal_error,
        => .poisoned,
        .ok,
        .invalid_argument,
        .busy,
        .stale_run,
        .resource_limit,
        .stale_catalog,
        .skill_not_found,
        .invalid_skill_arguments,
        .skill_policy_violation,
        .skill_unavailable,
        .checkpoint_budget_required,
        => .reusable,
        .too_late,
        .skill_catalog_invalid,
        .stale_compact,
        .checkpoint_corrupt,
        .checkpoint_unsupported,
        .checkpoint_incompatible,
        .checkpoint_io,
        .logical_session_conflict,
        .mcp_not_refreshed,
        .invalid_mcp_selection,
        .skill_catalog_incomplete,
        .image_input_unsupported,
        .image_input_capability_unknown,
        .goal_conflict,
        => null,
    };
}

fn runCheckpointFieldsValid(result: wire.RunResultV1) bool {
    if (result.result_flags & ~wire.RUN_RESULT_COMPACTION_RECOMMENDED != 0)
        return false;
    return switch (result.checkpoint_outcome_code) {
        wire.RUN_CHECKPOINT_NONE,
        wire.RUN_CHECKPOINT_BUDGET_REQUIRED,
        wire.RUN_CHECKPOINT_BUDGET_EXHAUSTED,
        wire.RUN_CHECKPOINT_RESOURCE_LIMIT,
        => true,
        else => false,
    };
}

fn runCheckpointOutcomeMatchesStop(outcome: u32, stop_reason: sdk.StopReason) bool {
    return switch (stop_reason) {
        .checkpoint_budget_exhausted => outcome == wire.RUN_CHECKPOINT_BUDGET_EXHAUSTED,
        .checkpoint_resource_limit => outcome == wire.RUN_CHECKPOINT_RESOURCE_LIMIT,
        else => outcome == wire.RUN_CHECKPOINT_NONE,
    };
}

fn isAbortStatus(status: sdk.Status) bool {
    return switch (status) {
        .ok,
        .invalid_argument,
        .out_of_memory,
        .busy,
        .stale_run,
        .too_late,
        .invalid_state,
        .core_error,
        .internal_error,
        .resource_limit,
        .skill_unavailable,
        => true,
        .callback_failed,
        .skill_catalog_invalid,
        .stale_catalog,
        .skill_not_found,
        .invalid_skill_arguments,
        .skill_policy_violation,
        .stale_compact,
        .checkpoint_budget_required,
        .checkpoint_corrupt,
        .checkpoint_unsupported,
        .checkpoint_incompatible,
        .checkpoint_io,
        .logical_session_conflict,
        .mcp_not_refreshed,
        .invalid_mcp_selection,
        .skill_catalog_incomplete,
        .image_input_unsupported,
        .image_input_capability_unknown,
        .goal_conflict,
        => false,
    };
}

fn isSessionDestroyStatus(status: sdk.Status) bool {
    return switch (status) {
        .ok,
        .invalid_argument,
        .out_of_memory,
        .busy,
        .invalid_state,
        .core_error,
        .resource_limit,
        .skill_unavailable,
        => true,
        .stale_run,
        .too_late,
        .callback_failed,
        .internal_error,
        .skill_catalog_invalid,
        .stale_catalog,
        .skill_not_found,
        .invalid_skill_arguments,
        .skill_policy_violation,
        .stale_compact,
        .checkpoint_budget_required,
        .checkpoint_corrupt,
        .checkpoint_unsupported,
        .checkpoint_incompatible,
        .checkpoint_io,
        .logical_session_conflict,
        .mcp_not_refreshed,
        .invalid_mcp_selection,
        .skill_catalog_incomplete,
        .image_input_unsupported,
        .image_input_capability_unknown,
        .goal_conflict,
        => false,
    };
}

pub fn mcpUpdateStatusDisposition(status: sdk.Status) ?SessionStatusDisposition {
    return switch (status) {
        .ok,
        .out_of_memory,
        .busy,
        .core_error,
        .resource_limit,
        .mcp_not_refreshed,
        .invalid_mcp_selection,
        .checkpoint_budget_required,
        => .reusable,
        .invalid_state => .poisoned,
        .invalid_argument,
        .stale_catalog,
        .stale_run,
        .too_late,
        .callback_failed,
        .internal_error,
        .skill_catalog_invalid,
        .skill_not_found,
        .invalid_skill_arguments,
        .skill_policy_violation,
        .skill_unavailable,
        .stale_compact,
        .checkpoint_corrupt,
        .checkpoint_unsupported,
        .checkpoint_incompatible,
        .checkpoint_io,
        .logical_session_conflict,
        .skill_catalog_incomplete,
        .image_input_unsupported,
        .image_input_capability_unknown,
        .goal_conflict,
        => null,
    };
}

fn allZero(values: []const u64) bool {
    for (values) |value| if (value != 0) return false;
    return true;
}

fn abortReason(signal: TerminationSignal) u32 {
    return switch (signal) {
        .interrupted => |interruption| if (interruption == .timeout)
            wire.ABORT_TIMEOUT
        else
            wire.ABORT_USER_REQUEST,
        .permission_required,
        .callback_failure,
        .event_pump_failure,
        .event_consumer_notification_failure,
        .credential_update_failure,
        => wire.ABORT_USER_REQUEST,
    };
}

fn wakeUiLocked(self: *Session) void {
    if (self.ui_active) {
        self.ui_active = false;
        self.broadcast();
    }
}

fn secureZero(bytes: []u8) void {
    std.crypto.secureZero(u8, bytes);
}

fn emptyOwnedBytes() wire.OwnedBytesV1 {
    return .{ .ptr = null, .len = 0 };
}

fn releaseOwned(api: sdk.Api, buffer: *wire.OwnedBytesV1) void {
    if (buffer.ptr != null or buffer.len != 0) api.bufferRelease()(buffer);
}

test {
    _ = image_generation;
    _ = generate_image;
    _ = multimodal;
    _ = session_wire;
    _ = session_control;
    _ = session_model_error;
    _ = session_binding;
    _ = session_runtime;
}

test "generated image attestation requires one matching committed Host receipt" {
    // Exercise the matching boundary with only its allocator, mutex and receipt storage.
    var runtime: Runtime = undefined;
    runtime.io = std.testing.io;
    runtime.allocator = std.testing.allocator;
    var session: Session = undefined;
    session.agent_runtime = &runtime;
    session.mutex = .init;
    session.image_receipts = @splat(null);
    session.matched_image_receipts = @splat(null);
    const receipt = try image_generation.Receipt.init("generated-images/real.jpg", 123, .jpeg);
    var buffer: [4096]u8 = undefined;
    const content = try generate_image.result(&buffer, .{ .saved = receipt });
    var event: sdk.DecodedCoreEvent = .{ .known = .{ .tool_result = .{ .id = "call", .name = generate_image.name, .input = "{}", .content = content, .is_error = false } } };
    try std.testing.expect((try session.matchGeneratedImage(event)) == null);
    session.image_receipts[0] = receipt;
    event.known.tool_result.name = "Read";
    try std.testing.expect((try session.matchGeneratedImage(event)) == null);
    event.known.tool_result.name = generate_image.name;
    event.known.tool_result.is_error = true;
    try std.testing.expect((try session.matchGeneratedImage(event)) == null);
    event.known.tool_result.is_error = false;
    event.known.tool_result.content = "{\"status\":\"saved\",\"path\":\"generated-images/forged.jpg\"}";
    try std.testing.expect((try session.matchGeneratedImage(event)) == null);
    event.known.tool_result.content = content;
    const matched = (try session.matchGeneratedImage(event)).?;
    const path = matched.path;
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings(receipt.pathView(), path);
    try std.testing.expect((try session.matchGeneratedImage(event)) == null);
    try std.testing.expect(session.image_receipts[0] != null);
    session.image_receipts[1] = try image_generation.Receipt.init("generated-images/unmatched.jpg", 9, .jpeg);
    const tail = session.takeTerminalReceiptsLocked();
    try std.testing.expectEqualSlices(u8, &toolRouteDigest("call"), &tail.generated_images[0].?.tool_route_digest);
    try std.testing.expectEqualStrings(receipt.pathView(), tail.generated_images[0].?.receipt.pathView());
    try std.testing.expect(tail.generated_images[1] == null);
    try std.testing.expect(session.takeTerminalReceiptsLocked().isEmpty());
    try std.testing.expect(session.image_receipts[1] != null);
}

test "delivery attestation claims only the exact successful Host receipt once" {
    var runtime: Runtime = undefined;
    runtime.io = std.testing.io;
    var session: Session = undefined;
    session.agent_runtime = &runtime;
    session.mutex = .init;
    session.delivery_receipts = @splat(null);
    session.matched_delivery_receipts = @splat(false);
    const receipt = try FileDeliveryReceipt.init(@splat(1), "outputs/final.docx", 123, @splat(2));
    var buffer: [deliver_file.result_bytes]u8 = undefined;
    const content = try deliver_file.result(&buffer, .{ .verified = receipt });
    var event: sdk.DecodedCoreEvent = .{ .known = .{ .tool_result = .{ .id = "call", .name = deliver_file.name, .input = "{}", .content = content, .is_error = false } } };
    try std.testing.expect(session.matchDeliveredFile(event) == null);
    session.delivery_receipts[0] = receipt;
    event.known.tool_result.name = "Read";
    try std.testing.expect(session.matchDeliveredFile(event) == null);
    event.known.tool_result.name = deliver_file.name;
    event.known.tool_result.is_error = true;
    try std.testing.expect(session.matchDeliveredFile(event) == null);
    event.known.tool_result.is_error = false;
    event.known.tool_result.content = "forged receipt";
    try std.testing.expect(session.matchDeliveredFile(event) == null);
    event.known.tool_result.content = content;
    try std.testing.expectEqualStrings(receipt.pathView(), session.matchDeliveredFile(event).?.receipt.pathView());
    try std.testing.expect(session.matchDeliveredFile(event) == null);
    try std.testing.expect(session.delivery_receipts[0] != null);
    session.delivery_receipts[1] = try FileDeliveryReceipt.init(@splat(3), "outputs/unmatched.docx", 9, @splat(4));
    const tail = session.takeTerminalReceiptsLocked();
    try std.testing.expectEqualStrings(receipt.pathView(), tail.delivered_files[0].?.pathView());
    try std.testing.expect(tail.delivered_files[1] == null);
    try std.testing.expect(session.takeTerminalReceiptsLocked().isEmpty());
    try std.testing.expect(session.delivery_receipts[1] != null);
}
