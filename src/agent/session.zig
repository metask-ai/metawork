//! MetaWork Agent Runtime over the bundle-owned typed SDK and ABI v1.
//! Core callbacks validate through the SDK, retain only Agent-owned data, and
//! feed a bounded sink. No callback calls WebView or registers desktop tools.

const std = @import("std");
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
const session_wire = @import("session/wire.zig");
const capabilities = @import("capabilities.zig");
const session_binding = @import("session/binding.zig");
// Intentional same-module cycle: Runtime owns the runtime lifecycle while
// Session remains the composition root for the Session-bound domain object.
const session_runtime = @import("session/runtime.zig");

pub const OwnedCoreEvent = event_pump.OwnedCoreEvent;
pub const Status = sdk.Status;
pub const StopReason = sdk.StopReason;
const UiRequest = sdk.UiRequest;
pub const PermissionChoice = sdk.protocol.PermissionChoice;
pub const PermissionDecision = sdk.protocol.PermissionDecision;
pub const PermissionDecisionSource = sdk.protocol.PermissionDecisionSource;
pub const PermissionCallbackOutcome = sdk.protocol.PermissionCallbackOutcome;
pub const PermissionProvenance = sdk.protocol.PermissionProvenance;
pub const PermissionToolNamespace = sdk.protocol.PermissionToolNamespace;
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
pub const McpCatalogProjection = mcp_catalog.Projection;
pub const McpCatalogServer = mcp_catalog.Server;
pub const McpCatalogTool = mcp_catalog.Tool;
pub const McpCatalogIssue = mcp_catalog.Issue;
pub const McpSelection = mcp_catalog.Selection;
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
pub const CompactOutcome = session_control.CompactOutcome;
pub const CompactTerminalResult = session_control.CompactTerminalResult;
pub const TerminationRequestResult = session_control.TerminationRequestResult;
pub const EventReadyNotification = session_control.EventReadyNotification;
pub const EventReadyNotifier = session_control.EventReadyNotifier;
pub const ProviderKind = session_control.ProviderKind;
pub const PermissionMode = session_control.PermissionMode;
pub const ShellPolicy = session_control.ShellPolicy;

pub const PermissionRequest = sdk.PermissionRequest;
pub const ParsedPermissionRequest = session_wire.ParsedPermissionRequest;
pub const decodePermissionRequest = session_wire.decodePermissionRequest;
const decodeUiRequest = session_wire.decodeUiRequest;
pub const decodeCoreEvent = session_wire.decodeCoreEvent;
const providerKindCode = session_wire.providerKindCode;
const permissionModeCode = session_wire.permissionModeCode;
const shellPolicyCode = session_wire.shellPolicyCode;
pub const RunControl = session_binding.RunControl;
pub const RunControlLease = session_binding.RunControlLease;
const SessionControlBlock = session_binding.SessionControlBlock;
pub const Runtime = session_runtime.Runtime;

pub const McpActivationUnavailableReason = enum {
    refresh_failed,
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

pub const RunInput = union(enum) {
    text: []const u8,
    skill: struct {
        skill_id: []const u8,
        catalog_revision: []const u8,
        argument_values: []const []const u8,
    },
};

const OwnedRunInput = union(enum) {
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
    ) (Error || std.mem.Allocator.Error)!OwnedRunInput {
        return switch (input) {
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

pub const SessionOpenOptions = struct {
    provider: ProviderKind,
    permission_mode: PermissionMode,
    shell_policy: ShellPolicy,
    credential: []const u8,
    model: []const u8,
    base_url: []const u8 = "",
    workspace: WorkspaceInput,
    canonical_user_home: []const u8 = "",
    workspace_epoch: []const u8 = "",
    skill_catalog: ?*CatalogLease = null,
    skill_policy: ?SkillPolicyInput = null,
    mcp_selection: ?*const McpSelection = null,
};

pub const SkillPolicyInput = struct {
    granted_skill_ids: []const []const u8 = &.{},
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

pub const Limits = struct {
    max_sessions: usize,
    /// Consumed exactly once during successful Agent Runtime construction.
    /// Build this input before Runtime init so attributable MCP preparation
    /// failures can select the ordinary empty Runtime path.
    mcp_input: ?*McpRuntimeInput = null,
    max_prompt_bytes: usize = 1024 * 1024,
    event_capacity: usize = 512,
    event_bytes: usize = 8 * 1024 * 1024,
    per_session_event_capacity: usize = 128,
    per_session_event_bytes: usize = 2 * 1024 * 1024,
    control_reserved_capacity: usize = 64,
    control_reserved_bytes: usize = 2 * 1024 * 1024,
    per_session_control_reserved_capacity: usize = 16,
    per_session_control_reserved_bytes: usize = 512 * 1024,
    max_event_bytes: usize = 512 * 1024,
    event_enqueue_timeout: std.Io.Duration = .fromMilliseconds(100),
    max_ui_request_bytes: usize = 256 * 1024,
    max_ui_response_bytes: usize = 256 * 1024,
    max_terminal_diagnostic_bytes: usize = 512,
    event_ready_notifier: ?EventReadyNotifier = null,
    event_ready_retry_interval: std.Io.Duration = .fromMilliseconds(5),
    event_ready_timeout: std.Io.Duration = .fromMilliseconds(50),
};

pub const SessionSnapshot = struct {
    session_id: u64,
    state: SessionState,
    workspace_root: []const u8,
    active_run_id: u64,
    active_compact_id: u64,
    pending_ui_request_id: ?u64,
};

pub const PendingUiRequest = struct {
    session_id: u64,
    run_id: u64,
    request_id: u64,
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
    InvalidMcpCatalogDescriptor,
    McpCatalogResourceLimit,
    McpCatalogGenerationMismatch,
    McpCatalogBindingMismatch,
    InvalidMcpSelection,
    StaleMcpSelection,
    McpRefreshInProgress,
    McpConfigurationApplyFailed,
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
    QueueFull,
    SessionNotIdle,
    SessionPoisoned,
    SessionClosing,
    InvalidRunInput,
    RunInputTooLarge,
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
    id: u64,
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
    run_done: bool = true,
    run_input: ?OwnedRunInput = null,
    terminal_diagnostic: ?[]u8 = null,
    terminal_diagnostic_len: usize = 0,
    terminal_diagnostic_truncated: bool = false,
    termination_signal: ?TerminationSignal = null,
    abort_status: ?sdk.Status = null,
    raw_abort_status_code: ?u32 = null,
    dependency_contract_failure: bool = false,
    core_session_identity: CoreSessionIdentity = .unbound,
    cancel_requested: bool = false,
    active_refs: usize = 0,
    active_callback_refs: usize = 0,
    ui_active: bool = false,
    ui_request_id: u64 = 0,
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

    /// Prepares an Agent Run after Workbench admission. Workbench owns queueing
    /// and must call exactly one of `beginRun` or `cancelPreparedRun`.
    pub fn prepareRun(
        self: *Session,
        input: RunInput,
    ) (Error || std.mem.Allocator.Error)!u64 {
        var owned_input = try OwnedRunInput.init(
            self.agent_runtime.allocator,
            input,
            self.agent_runtime.max_prompt_bytes,
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
        self.termination_signal = null;
        self.abort_status = null;
        self.raw_abort_status_code = null;
        self.dependency_contract_failure = false;
        self.cancel_requested = false;
        self.state = .queued;
        self.unlock();
        return run_id;
    }

    /// Installs the generation-checked termination control and transfers
    /// execution ownership from Workbench to Agent. A successful call must be
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

    /// Reserves the Session's single operation slot for a Workbench-owned
    /// manual compact. Workbench must either execute or cancel the reservation.
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

    /// Called only by a Workbench executor worker after successful admission.
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
            !catalog.matches(
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
        self.lock();
        defer self.unlock();
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
            .ok => {},
            .busy => error.SessionNotIdle,
            else => error.CatalogRefreshFailed,
        };
    }

    /// Rebinds the model of this Session while it is idle. AgentCore rejects
    /// the same operation while a Run is active; Workbench uses that busy
    /// result to keep model changes out of the in-flight Run path.
    pub fn setModel(self: *Session, model: []const u8) Error!void {
        if (model.len == 0 or !std.unicode.utf8ValidateSlice(model))
            return error.CoreCallFailed;
        self.lock();
        defer self.unlock();
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
    ) Error!void {
        return self.agent_runtime.updateSessionMcpSelection(self, selection);
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
        const should_abort = !was_queued and self.core_call_in_progress and !self.run_done;
        if (should_abort) self.abort_calls_in_progress += 1;
        self.unlock();

        if (was_queued) {
            _ = self.agent_runtime.notifyEventConsumer();
            return;
        }
        if (should_abort) self.abortRun(run_id, signal);
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
        const should_abort = self.core_call_in_progress;
        if (should_abort) self.abort_calls_in_progress += 1;
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

    pub const PendingUiObservation = struct {
        run_id: u64,
        request_id: u64,
    };

    /// Bounded execution observation used by Workbench projection. This does
    /// not expose Session lifecycle or product identity.
    pub fn pendingUiObservation(self: *Session) ?PendingUiObservation {
        self.lock();
        defer self.unlock();
        if (!self.ui_active) return null;
        return .{ .run_id = self.active_run_id, .request_id = self.ui_request_id };
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
    /// duration of each callback; filesystem commit remains a Workbench fact.
    pub fn exportCheckpoint(
        self: *Session,
        limits: CheckpointLimits,
        sink: CheckpointSink,
        expected_last_run_id: u64,
        expected_last_compact_id: u64,
        expected_model: []const u8,
    ) Error!CheckpointOutcome {
        try checkpoint.validateLimits(limits);
        if (expected_model.len == 0 or !std.unicode.utf8ValidateSlice(expected_model))
            return error.InvalidLimits;

        self.lock();
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
        self.active_refs += 1;
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
        std.debug.assert(self.active_refs > 0);
        self.active_refs -= 1;
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
        if (self.active_refs == 0) self.broadcast();
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
        const should_abort_now = self.core_call_in_progress and !operation_done and
            self.abort_calls_in_progress == 0 and
            (if (compact_active)
                self.raw_compact_abort_status_code == null
            else
                self.raw_abort_status_code == null);
        if (should_abort_now) self.abort_calls_in_progress += 1;
        const run_id = self.active_run_id;
        const compact_id = self.active_compact_id;
        self.state = .closing;
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
            wakeUiLocked(self);
            if (!self.run_done and !self.run_started) self.finishPreparedRunLocked();
        }
        self.broadcast();
        self.unlock();

        if (should_abort_now) {
            if (compact_active) self.abortCompact(compact_id) else self.abortRun(run_id, signal);
        }

        self.lock();
        while (if (compact_active)
            (!self.compact_done and !self.compact_started)
        else
            (!self.run_done and !self.run_started)) self.wait();
        const should_abort_late = !should_abort_now and self.core_call_in_progress and
            !(if (compact_active) self.compact_done else self.run_done) and
            self.abort_calls_in_progress == 0 and
            (if (compact_active)
                self.raw_compact_abort_status_code == null
            else
                self.raw_abort_status_code == null);
        if (should_abort_late) self.abort_calls_in_progress += 1;
        self.unlock();
        if (should_abort_late) {
            if (compact_active) self.abortCompact(compact_id) else self.abortRun(run_id, signal);
        }

        self.lock();
        while (!(if (compact_active) self.compact_done else self.run_done)) self.wait();
        while (self.abort_calls_in_progress != 0) self.wait();
        while (self.active_refs != 0) self.wait();
        self.unlock();

        // Never wait for Agent control references while holding a Workbench or
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
        self.core_call_in_progress = true;
        const input = &self.run_input.?;
        self.unlock();

        var options = std.mem.zeroes(wire.RunOptionsV1);
        options.struct_size = @sizeOf(wire.RunOptionsV1);
        options.max_turns = 16;
        // A successful Core call must still populate and validate the complete
        // fixed-layout result. Zero initialization makes a missing write fail
        // deterministically on `struct_size` instead of exposing undefined data.
        var result = std.mem.zeroes(wire.RunResultV1);
        var diagnostic = emptyOwnedBytes();
        const status = switch (input.*) {
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
        if (self.active_callback_refs != 0) {
            self.failCoreIdentityLocked();
            while (self.active_callback_refs != 0) self.wait();
        }
        while (self.abort_calls_in_progress != 0) self.wait();
        var completed_input = self.run_input.?;
        self.run_input = null;
        completed_input.deinit(self.agent_runtime.allocator);
        var stop_reason: ?sdk.StopReason = null;
        var raw_stop_reason_code: ?u32 = null;
        var failure: ?TerminalFailure = null;
        var durable_budget: ?DurableBudgetObservation = null;
        if (!diagnostic_valid) {
            self.dependency_contract_failure = true;
            failure = .dependency_contract;
            self.state = .poisoned;
        } else if (typed_status) |known_status| {
            const disposition = runStatusDisposition(known_status);
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
                    if (known_status == .callback_failed and self.termination_signal == null)
                        setTerminationSignalLocked(self, .{ .callback_failure = .event });
                    failure = .abi_status;
                    if (disposition.? == .poisoned) self.state = .poisoned;
                }
            }
        } else {
            self.dependency_contract_failure = true;
            failure = .dependency_contract;
            self.state = .poisoned;
        }
        if (self.dependency_contract_failure) {
            failure = .dependency_contract;
            self.state = .poisoned;
        }
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
        self.run_started = false;
        self.run_done = true;
        if (self.state != .closing and self.state != .poisoned) self.state = .idle;
        const terminal = self.takeTerminalResultLocked(null, null, null, null, null, null);
        self.broadcast();
        return terminal;
    }

    fn abortRun(self: *Session, run_id: u64, signal: TerminationSignal) void {
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
            self.raw_abort_status_code = status;
            self.abort_status = sdk.Status.fromCode(status) catch null;
            if (self.abort_status == null or !isAbortStatus(self.abort_status.?))
                self.dependency_contract_failure = true;
        }
        self.abort_calls_in_progress -= 1;
        self.broadcast();
        self.unlock();
    }

    fn finishPreparedRunLocked(self: *Session) void {
        std.debug.assert(!self.run_started and !self.core_call_in_progress);
        if (self.run_input) |*input| {
            input.deinit(self.agent_runtime.allocator);
            self.run_input = null;
        }
        if (self.terminal_diagnostic) |buffer| {
            self.agent_runtime.allocator.free(buffer);
            self.terminal_diagnostic = null;
        }
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
            .failure = if (self.dependency_contract_failure)
                .dependency_contract
            else
                failure,
            .session_disposition_at_completion = self.dispositionLocked(),
            .durable_budget = durable_budget,
        };
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
        self.control_block.deinit();
        self.agent_runtime.allocator.destroy(self.control_block);
        if (self.run_input) |*input|
            input.deinit(self.agent_runtime.allocator);
        if (self.terminal_diagnostic) |buffer| self.agent_runtime.allocator.free(buffer);
        if (self.compact_terminal_diagnostic) |buffer|
            self.agent_runtime.allocator.free(buffer);
        if (self.ui_request_json) |json| self.agent_runtime.allocator.free(json);
        if (self.ui_response_json) |json| self.agent_runtime.allocator.free(json);
        self.agent_runtime.allocator.free(self.workspace_root);
        self.agent_runtime.allocator.free(self.workspace_home);
        self.agent_runtime.allocator.free(self.workspace_epoch);
    }

    pub fn onEvent(
        context: ?*anyopaque,
        raw_run: ?*const wire.RunContextV1,
        event_json: wire.BytesViewV1,
    ) callconv(.c) u32 {
        const self: *Session = @ptrCast(@alignCast(context orelse return wire.EVENT_FATAL));
        const run_id = self.retainCoreCallback(raw_run) orelse return wire.EVENT_FATAL;
        defer self.releaseCoreCallback();
        const encoded = sdk.borrowedBytes(event_json) catch {
            self.recordTerminationSignal(.{ .event_pump_failure = .invalid_event });
            return wire.EVENT_FATAL;
        };
        if (encoded.len > self.agent_runtime.max_event_bytes) {
            self.recordTerminationSignal(.{ .event_pump_failure = .event_too_large });
            return wire.EVENT_FATAL;
        }
        var parsed = decodeCoreEvent(self.agent_runtime.allocator, encoded) catch {
            self.recordTerminationSignal(.{ .event_pump_failure = .invalid_event });
            return wire.EVENT_FATAL;
        };
        switch (parsed.value) {
            .known => {},
            .unknown => {
                parsed.deinit();
                return wire.EVENT_CONTINUE;
            },
        }
        const owned_json = self.agent_runtime.allocator.dupe(u8, encoded) catch {
            parsed.deinit();
            self.recordTerminationSignal(.{ .event_pump_failure = .allocation });
            return wire.EVENT_FATAL;
        };
        var envelope = OwnedCoreEvent{
            .session_id = self.id,
            .run_id = run_id,
            .encoded_bytes = encoded.len,
            .json = owned_json,
            .event = parsed,
            .allocator = self.agent_runtime.allocator,
        };
        self.agent_runtime.events.enqueueWithDeadline(envelope, self.agent_runtime.event_enqueue_timeout) catch |err| {
            envelope.deinit();
            self.recordTerminationSignal(.{ .event_pump_failure = switch (err) {
                error.EventTooLarge => .event_too_large,
                error.InvalidIdentity,
                error.InvalidLimits,
                => .invalid_event,
                error.GlobalCapacity,
                error.SessionCapacity,
                error.SessionSlotCapacity,
                error.SequenceExhausted,
                error.DeadlineExceeded,
                => .capacity,
            } });
            return wire.EVENT_FATAL;
        };
        const notification_failed = self.agent_runtime.notifyEventConsumer() == .unavailable;
        if (notification_failed) {
            self.recordTerminationSignal(.{
                .event_consumer_notification_failure = .unavailable,
            });
            return wire.EVENT_FATAL;
        }
        return wire.EVENT_CONTINUE;
    }

    pub fn onUiRequest(
        context: ?*anyopaque,
        raw_run: ?*const wire.RunContextV1,
        request_json: wire.BytesViewV1,
        out_response: ?*wire.OwnedBytesV1,
    ) callconv(.c) u32 {
        if (out_response) |out| out.* = emptyOwnedBytes();
        const self: *Session = @ptrCast(@alignCast(context orelse return wire.UI_FATAL));
        const output = out_response orelse {
            self.recordTerminationSignal(.{ .callback_failure = .ui });
            return wire.UI_FATAL;
        };
        const callback_run_id = self.retainCoreCallback(raw_run) orelse return wire.UI_FATAL;
        defer self.releaseCoreCallback();

        const encoded_request = sdk.borrowedBytes(request_json) catch {
            self.recordTerminationSignal(.{ .callback_failure = .ui });
            return wire.UI_FATAL;
        };
        if (encoded_request.len > self.agent_runtime.max_ui_request_bytes) {
            self.recordTerminationSignal(.{ .event_pump_failure = .event_too_large });
            return wire.UI_FATAL;
        }
        var parsed = decodeUiRequest(self.agent_runtime.allocator, encoded_request) catch {
            self.recordTerminationSignal(.{ .callback_failure = .ui });
            return wire.UI_FATAL;
        };
        defer parsed.deinit();
        if (!capabilities.allowsUiRequest(parsed.value)) {
            self.recordTerminationSignal(.{ .callback_failure = .ui });
            return wire.UI_FATAL;
        }
        const owned_request = self.agent_runtime.allocator.dupe(u8, encoded_request) catch {
            self.recordTerminationSignal(.{ .event_pump_failure = .allocation });
            return wire.UI_FATAL;
        };

        self.lock();
        if (!self.coreIdentityHealthyLocked() or
            !self.uiRequestIdentityMatchesLocked(parsed.value, callback_run_id))
        {
            self.failCoreIdentityLocked();
            self.unlock();
            self.agent_runtime.allocator.free(owned_request);
            return wire.UI_FATAL;
        }
        if (self.state != .running or self.ui_active) {
            setTerminationSignalLocked(self, .{ .callback_failure = .ui });
            self.unlock();
            self.agent_runtime.allocator.free(owned_request);
            return wire.UI_FATAL;
        }
        if (self.ui_request_id == std.math.maxInt(u64)) {
            self.dependency_contract_failure = true;
            self.unlock();
            self.agent_runtime.allocator.free(owned_request);
            return wire.UI_FATAL;
        }
        self.ui_request_id += 1;
        self.ui_active = true;
        self.ui_answered = false;
        std.debug.assert(self.ui_request_json == null);
        std.debug.assert(self.ui_request_value == null);
        std.debug.assert(self.ui_response_json == null);
        self.ui_request_json = owned_request;
        self.ui_request_value = &parsed.value;
        self.state = .waiting_ui;
        self.broadcast();
        self.unlock();

        const notification_failed = self.agent_runtime.notifyEventConsumer() == .unavailable;
        if (notification_failed) {
            self.lock();
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

    fn retainCoreCallback(
        self: *Session,
        raw_run: ?*const wire.RunContextV1,
    ) ?u64 {
        const run = sdk.validateRunContext(raw_run) catch {
            self.rejectInvalidCoreIdentity();
            return null;
        };
        self.lock();
        defer self.unlock();
        if (self.state == .closing or self.state == .closed) return null;
        if (self.raw == null or run.session != self.raw.? or
            !self.run_started or !self.core_call_in_progress or
            run.run_id != self.active_run_id)
        {
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

fn setTerminationSignalLocked(self: *Session, signal: TerminationSignal) void {
    if (self.termination_signal == null) self.termination_signal = signal;
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
        => null,
    };
}

fn runStatusDisposition(status: sdk.Status) ?SessionStatusDisposition {
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
        .callback_failure,
        .event_pump_failure,
        .event_consumer_notification_failure,
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
    _ = session_wire;
    _ = session_control;
    _ = session_binding;
    _ = session_runtime;
}
