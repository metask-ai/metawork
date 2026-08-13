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

var next_mcp_owner_id: std.atomic.Value(u64) = .init(1);

pub const OwnedCoreEvent = event_pump.OwnedCoreEvent;
pub const Status = sdk.Status;
pub const StopReason = sdk.StopReason;
pub const UiRequest = sdk.UiRequest;
pub const Answer = sdk.protocol.Answer;
pub const PermissionChoice = sdk.protocol.PermissionChoice;
pub const PermissionDecision = sdk.protocol.PermissionDecision;
pub const PermissionDecisionSource = sdk.protocol.PermissionDecisionSource;
pub const PermissionCallbackOutcome = sdk.protocol.PermissionCallbackOutcome;
pub const PermissionProvenance = sdk.protocol.PermissionProvenance;
pub const PermissionToolNamespace = sdk.protocol.PermissionToolNamespace;
pub const RunState = sdk.protocol.RunState;
pub const RunStatePhase = sdk.protocol.RunStatePhase;
pub const ParsedUiRequest = sdk.ParsedUiRequest;
pub const CatalogHealth = catalog.Health;
pub const CatalogIssueCode = catalog.IssueCode;
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

const McpRefreshLease = struct {
    raw_runtime: *wire.RuntimeHandle,
    expected_servers: []const mcp_runtime.ExpectedServer,
    registry_generation: ?u64,
};

pub fn decodeUiRequest(
    allocator: std.mem.Allocator,
    encoded: []const u8,
) sdk.DecodeError!ParsedUiRequest {
    if (!std.unicode.utf8ValidateSlice(encoded)) return error.MalformedJson;
    var parsed = try sdk.decodeUiRequest(allocator, encoded);
    errdefer parsed.deinit();
    if (!uiRequestTextValid(parsed.value)) return error.InvalidPayload;
    return parsed;
}

pub fn decodeCoreEvent(
    allocator: std.mem.Allocator,
    encoded: []const u8,
) sdk.DecodeError!sdk.ParsedCoreEvent {
    if (!std.unicode.utf8ValidateSlice(encoded)) return error.MalformedJson;
    var parsed = try sdk.decodeCoreEvent(allocator, encoded);
    errdefer parsed.deinit();
    if (!coreEventTextValid(parsed.value)) return error.InvalidPayload;
    return parsed;
}

fn coreEventTextValid(event: sdk.DecodedCoreEvent) bool {
    return switch (event) {
        .unknown => |unknown| validUtf8(&.{ unknown.tag, unknown.payload_json }),
        .known => |known| switch (known) {
            .text_chunk => |text| std.unicode.utf8ValidateSlice(text),
            .tool_start => |tool| validUtf8(&.{ tool.id, tool.name, tool.input }),
            .tool_progress => |progress| validUtf8(&.{ progress.id, progress.text }),
            .progress => |progress| validUtf8(&.{ progress.tool_name, progress.tool_input }),
            .tool_result => |result| validUtf8(&.{ result.id, result.name, result.input, result.content }),
            .usage, .retry_notice, .stream_done => true,
            .run_state => |state| {
                if (state.run_id == 0) return false;
                for (state.in_flight_tools) |tool|
                    if (!validUtf8(&.{ tool.tool_call_id, tool.name })) return false;
                return true;
            },
            .context_warning => |warning| std.unicode.utf8ValidateSlice(warning.level),
            .auto_compact => |compact| std.unicode.utf8ValidateSlice(compact.cause),
            .permission_provenance => |value| validUtf8(&.{
                value.matched_rule_id orelse "",
                value.session_id,
                value.tool_call_id,
                value.request_id orelse "",
                value.tool.name,
                value.tool.binding,
                value.canonical_arguments_digest,
            }),
        },
    };
}

fn uiRequestTextValid(request: sdk.UiRequest) bool {
    return switch (request) {
        .ask_question => |questions| questions: {
            for (questions) |question| {
                if (!validUtf8(&.{ question.question, question.header })) break :questions false;
                for (question.options) |option|
                    if (!validUtf8(&.{ option.label, option.description, option.preview }))
                        break :questions false;
            }
            break :questions true;
        },
        .permission => |permission| validUtf8(&.{
            permission.type,
            permission.request_id,
            permission.session_id,
            permission.tool_call_id,
            permission.tool.name,
            permission.tool.binding,
            permission.canonical_arguments_digest,
            permission.arguments_json,
            if (permission.candidate) |candidate| candidate.rule_id else "",
        }),
    };
}

fn validUtf8(values: []const []const u8) bool {
    for (values) |value|
        if (!std.unicode.utf8ValidateSlice(value)) return false;
    return true;
}

test "AgentCore JSON callbacks reject invalid UTF-8 at the ownership boundary" {
    const invalid_event =
        "{\"tool_result\":{\"id\":\"tool-1\",\"name\":\"Bash\",\"input\":\"{}\",\"content\":[203],\"is_error\":false,\"elapsed_ms\":1}}";
    try std.testing.expectError(
        error.InvalidPayload,
        decodeCoreEvent(std.testing.allocator, invalid_event),
    );

    const invalid_ui =
        "{\"ask_question\":[{\"question\":[203],\"header\":\"Choice\",\"multi\":false,\"options\":[]}]}";
    try std.testing.expectError(
        error.InvalidPayload,
        decodeUiRequest(std.testing.allocator, invalid_ui),
    );
}

pub const BuiltinToolProfile = enum {
    full,
    local,
    network,
};

pub const default_builtin_tools = [_][]const u8{ "Read", "Bash", "Edit", "AskUserQuestion" };
pub const windows_builtin_tools = [_][]const u8{
    "Read",
    "Write",
    "Edit",
    "Glob",
    "Grep",
    "Bash",
    "BashOutput",
    "KillShell",
    "AskUserQuestion",
    "WebSearch",
    "WebFetch",
};
pub const local_builtin_tools = [_][]const u8{
    "Read",
    "Write",
    "Edit",
    "Glob",
    "Grep",
    "Bash",
    "BashOutput",
    "KillShell",
    "AskUserQuestion",
};
pub const network_builtin_tools = [_][]const u8{ "WebSearch", "WebFetch" };

pub const registered_builtin_tools = if (builtin.os.tag == .windows)
    windows_builtin_tools
else
    default_builtin_tools;

pub fn builtinToolsForProfile(profile: BuiltinToolProfile) []const []const u8 {
    return switch (profile) {
        .full => if (builtin.os.tag == .windows)
            &windows_builtin_tools
        else
            &default_builtin_tools,
        .local => &local_builtin_tools,
        .network => &network_builtin_tools,
    };
}

test "Windows built-in profiles cover the verified name set without overlap" {
    const local = builtinToolsForProfile(.local);
    const network = builtinToolsForProfile(.network);
    try std.testing.expectEqual(windows_builtin_tools.len, local.len + network.len);
    for (local) |name| {
        for (network) |other| try std.testing.expect(!std.mem.eql(u8, name, other));
    }
    for (windows_builtin_tools) |name| {
        var found = false;
        for (local) |candidate| {
            if (std.mem.eql(u8, name, candidate)) found = true;
        }
        for (network) |candidate| {
            if (std.mem.eql(u8, name, candidate)) found = true;
        }
        try std.testing.expect(found);
    }
}

fn providerKindCode(value: ProviderKind) u32 {
    return switch (value) {
        .anthropic => wire.PROVIDER_ANTHROPIC,
        .openai => wire.PROVIDER_OPENAI,
        .gemini => wire.PROVIDER_GEMINI,
    };
}

fn permissionModeCode(value: PermissionMode) u32 {
    return switch (value) {
        .default => wire.PERMISSION_DEFAULT,
        .accept_edits => wire.PERMISSION_ACCEPT_EDITS,
        .auto => wire.PERMISSION_AUTO,
        .dont_ask => wire.PERMISSION_DONT_ASK,
        .full_access => wire.PERMISSION_FULL_ACCESS,
    };
}

fn shellPolicyCode(value: ShellPolicy) u32 {
    return switch (value) {
        .disabled => wire.SHELL_DISABLED,
        .sandboxed => wire.SHELL_SANDBOXED,
        .unrestricted => wire.SHELL_UNRESTRICTED,
    };
}

fn allSkillsEnabledSelection() wire.SkillSelectionV1 {
    return .{
        .struct_size = @sizeOf(wire.SkillSelectionV1),
        .default_state_code = wire.SKILL_SELECTION_ENABLED,
        .exception_skill_ids = null,
        .exception_skill_id_count = 0,
        .reserved = [_]u64{0} ** 4,
    };
}

pub const SessionState = enum {
    idle,
    queued,
    running,
    waiting_ui,
    compact_queued,
    compacting,
    checkpointing,
    poisoned,
    closing,
    closed,
};

pub const ExternalInterruption = enum {
    user_cancel,
    timeout,
    session_close,
    app_shutdown,
};

pub const CallbackFailure = enum {
    event,
    ui,
};

pub const EventPumpFailure = enum {
    invalid_event,
    event_too_large,
    capacity,
    allocation,
    consumer_rejected,
};

pub const EventConsumerNotificationFailure = enum {
    unavailable,
};

/// The single mutable, first-writer-wins termination latch for an active Run.
/// This is execution control state, not a durable product outcome.
pub const TerminationSignal = union(enum) {
    interrupted: ExternalInterruption,
    callback_failure: CallbackFailure,
    event_pump_failure: EventPumpFailure,
    event_consumer_notification_failure: EventConsumerNotificationFailure,
};

pub const TerminalFailure = enum {
    abi_status,
    dependency_contract,
};

pub const SessionDisposition = enum {
    reusable,
    poisoned,
    closing,
};

pub const DurableBudgetObservation = struct {
    durable_usage_bytes: u64,
    required_checkpoint_bytes: u64,
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

/// Immutable Agent-owned facts for exactly one begun Run. Workbench must copy
/// the bounded diagnostic into its admission-reserved Run record, then deinit
/// this value. `session_disposition_at_completion` is a completion-time
/// snapshot, never live Session state.
pub const TerminalResult = struct {
    allocator: std.mem.Allocator,
    diagnostic_storage: []u8,
    diagnostic_len: usize,
    diagnostic_truncated: bool,
    abi_status: ?sdk.Status,
    raw_status_code: ?u32,
    stop_reason: ?sdk.StopReason,
    raw_stop_reason_code: ?u32,
    abort_status: ?sdk.Status,
    raw_abort_status_code: ?u32,
    termination_signal: ?TerminationSignal,
    failure: ?TerminalFailure,
    session_disposition_at_completion: SessionDisposition,
    durable_budget: ?DurableBudgetObservation = null,

    pub fn diagnostic(self: *const TerminalResult) []const u8 {
        return self.diagnostic_storage[0..self.diagnostic_len];
    }

    pub fn deinit(self: *TerminalResult) void {
        self.allocator.free(self.diagnostic_storage);
        self.* = undefined;
    }
};

pub const CompactOutcome = enum {
    compacted,
    no_change,
    degraded,
    aborted,
};

/// Immutable Agent-owned facts for one admitted manual compact. Context token
/// values are estimates; usage fields are the operation's provider deltas.
pub const CompactTerminalResult = struct {
    allocator: std.mem.Allocator,
    diagnostic_storage: []u8,
    diagnostic_len: usize,
    diagnostic_truncated: bool,
    abi_status: ?sdk.Status,
    raw_status_code: ?u32,
    abort_status: ?sdk.Status,
    raw_abort_status_code: ?u32,
    outcome: ?CompactOutcome,
    before_context_tokens: u64,
    after_context_tokens: u64,
    input_tokens: u64,
    output_tokens: u64,
    cache_read_input_tokens: u64,
    cache_creation_input_tokens: u64,
    interruption: ?ExternalInterruption,
    failure: ?TerminalFailure,
    session_disposition_at_completion: SessionDisposition,

    pub fn diagnostic(self: *const CompactTerminalResult) []const u8 {
        return self.diagnostic_storage[0..self.diagnostic_len];
    }

    pub fn deinit(self: *CompactTerminalResult) void {
        self.allocator.free(self.diagnostic_storage);
        self.* = undefined;
    }
};

pub const TerminationRequestResult = enum {
    requested,
    already_requested,
    already_terminal,
    stale_run,
    session_closing,
};

const control_closed_bit = @as(usize, 1) << (@bitSizeOf(usize) - 1);
const control_reference_mask = control_closed_bit - 1;

const SessionControlBlock = struct {
    session: *Session,
    lifetime: std.atomic.Value(usize) = .init(1),
    wait_mutex: std.Io.Mutex = .init,
    wait_condition: std.Io.Condition = .init,

    fn tryRetain(self: *SessionControlBlock) bool {
        var current = self.lifetime.load(.acquire);
        while (current & control_closed_bit == 0) {
            const references = current & control_reference_mask;
            if (references == control_reference_mask) return false;
            if (self.lifetime.cmpxchgWeak(
                current,
                current + 1,
                .acq_rel,
                .acquire,
            )) |observed| {
                current = observed;
            } else return true;
        }
        return false;
    }

    fn release(self: *SessionControlBlock) void {
        self.wait_mutex.lockUncancelable(self.session.agent_runtime.io);
        const previous = self.lifetime.fetchSub(1, .acq_rel);
        std.debug.assert(previous & control_reference_mask > 1);
        self.wait_condition.broadcast(self.session.agent_runtime.io);
        self.wait_mutex.unlock(self.session.agent_runtime.io);
    }

    fn disableNewLeases(self: *SessionControlBlock) void {
        _ = self.lifetime.fetchOr(control_closed_bit, .acq_rel);
    }

    fn waitForLeaseQuiescence(self: *SessionControlBlock) void {
        self.wait_mutex.lockUncancelable(self.session.agent_runtime.io);
        defer self.wait_mutex.unlock(self.session.agent_runtime.io);
        while (self.lifetime.load(.acquire) & control_reference_mask != 1)
            self.wait_condition.waitUncancelable(
                self.session.agent_runtime.io,
                &self.wait_mutex,
            );
    }

    fn deinit(self: *SessionControlBlock) void {
        const lifetime = self.lifetime.load(.acquire);
        std.debug.assert(lifetime & control_closed_bit != 0);
        std.debug.assert(lifetime & control_reference_mask == 1);
    }
};

pub const RunControl = struct {
    block: *SessionControlBlock,
    run_id: u64,
    generation: u64,

    pub fn tryAcquireLease(self: RunControl) ?RunControlLease {
        if (!self.block.tryRetain()) return null;
        return .{
            .block = self.block,
            .run_id = self.run_id,
            .generation = self.generation,
        };
    }
};

/// A retained Agent control reference. This is a linear value: callers must
/// not copy it and must call `deinit` exactly once.
pub const RunControlLease = struct {
    block: *SessionControlBlock,
    run_id: u64,
    generation: u64,
    released: bool = false,

    pub fn requestTermination(
        self: *const RunControlLease,
        signal: TerminationSignal,
    ) TerminationRequestResult {
        std.debug.assert(!self.released);
        return self.block.session.requestControlledTermination(
            self.run_id,
            self.generation,
            signal,
        );
    }

    pub fn deinit(self: *RunControlLease) void {
        std.debug.assert(!self.released);
        self.released = true;
        self.block.release();
    }
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

pub const EventReadyNotification = enum {
    scheduled,
    already_pending,
    unavailable,
};

pub const EventReadyNotifier = struct {
    context: ?*anyopaque,
    notify_fn: *const fn (?*anyopaque) EventReadyNotification,

    pub fn notify(self: EventReadyNotifier) EventReadyNotification {
        return self.notify_fn(self.context);
    }

    pub fn notifyWithRetry(
        self: EventReadyNotifier,
        io: std.Io,
        retry_interval: std.Io.Duration,
        timeout: std.Io.Duration,
    ) EventReadyNotification {
        std.debug.assert(retry_interval.nanoseconds > 0);
        std.debug.assert(timeout.nanoseconds > 0);
        var waited: i96 = 0;
        while (true) {
            const result = self.notify();
            if (result != .unavailable) return result;
            if (waited >= timeout.nanoseconds) return .unavailable;
            const sleep_ns = @min(retry_interval.nanoseconds, timeout.nanoseconds - waited);
            io.sleep(.fromNanoseconds(sleep_ns), .awake) catch return .unavailable;
            waited += sleep_ns;
        }
    }
};

test "EventReadyNotifier preserves scheduled, coalesced, and unavailable outcomes" {
    const Harness = struct {
        result: EventReadyNotification,

        fn notify(context: ?*anyopaque) EventReadyNotification {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            return self.result;
        }
    };
    var harness = Harness{ .result = .scheduled };
    const notifier = EventReadyNotifier{ .context = &harness, .notify_fn = Harness.notify };
    inline for (.{
        EventReadyNotification.scheduled,
        EventReadyNotification.already_pending,
        EventReadyNotification.unavailable,
    }) |result| {
        harness.result = result;
        try std.testing.expectEqual(result, notifier.notify());
    }
}

test "EventReadyNotifier retries unavailable without losing terminal outcomes" {
    const Harness = struct {
        unavailable_before_success: usize,
        calls: usize = 0,

        fn notify(context: ?*anyopaque) EventReadyNotification {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            if (self.calls <= self.unavailable_before_success) return .unavailable;
            return .already_pending;
        }
    };
    var recovering = Harness{ .unavailable_before_success = 2 };
    const recovering_notifier = EventReadyNotifier{
        .context = &recovering,
        .notify_fn = Harness.notify,
    };
    try std.testing.expectEqual(
        EventReadyNotification.already_pending,
        recovering_notifier.notifyWithRetry(
            std.testing.io,
            .fromNanoseconds(1),
            .fromNanoseconds(3),
        ),
    );
    try std.testing.expectEqual(@as(usize, 3), recovering.calls);

    var unavailable = Harness{ .unavailable_before_success = std.math.maxInt(usize) };
    const unavailable_notifier = EventReadyNotifier{
        .context = &unavailable,
        .notify_fn = Harness.notify,
    };
    try std.testing.expectEqual(
        EventReadyNotification.unavailable,
        unavailable_notifier.notifyWithRetry(
            std.testing.io,
            .fromNanoseconds(1),
            .fromNanoseconds(2),
        ),
    );
    try std.testing.expectEqual(@as(usize, 3), unavailable.calls);
}

pub const ProviderKind = enum {
    anthropic,
    openai,
    gemini,
};

pub const PermissionMode = enum {
    default,
    accept_edits,
    auto,
    dont_ask,
    full_access,
};

pub const ShellPolicy = enum {
    disabled,
    sandboxed,
    unrestricted,
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
    mcp_selection: ?*const McpSelection = null,
    allowed_tools: []const []const u8 = &default_builtin_tools,
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
    ui_request_timeout: std.Io.Duration = .fromSeconds(30),
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
    CatalogResourceLimit,
    CatalogReleaseFailed,
    CatalogLeasesOutstanding,
    CatalogBindingMismatch,
    CatalogRefreshFailed,
    McpRefreshFailed,
    InvalidMcpCatalogDescriptor,
    McpCatalogResourceLimit,
    McpCatalogGenerationMismatch,
    McpCatalogBindingMismatch,
    InvalidMcpSelection,
    StaleMcpSelection,
    McpRefreshInProgress,
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

pub const Runtime = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    api: sdk.Api,
    runtime: ?*wire.RuntimeHandle,
    max_prompt_bytes: usize,
    max_event_bytes: usize,
    event_enqueue_timeout: std.Io.Duration,
    max_ui_request_bytes: usize,
    max_ui_response_bytes: usize,
    max_terminal_diagnostic_bytes: usize,
    ui_request_timeout: std.Io.Duration,
    event_ready_notifier: ?EventReadyNotifier,
    event_ready_retry_interval: std.Io.Duration,
    event_ready_timeout: std.Io.Duration,
    events: event_pump.EventPump,
    sessions_mutex: std.Io.Mutex = .init,
    shutdown_condition: std.Io.Condition = .init,
    sessions: []?*Session,
    session_reservations: []bool,
    shutting_down: std.atomic.Value(bool) = .init(false),
    shutdown_running: bool = false,
    shutdown_complete: bool = false,
    last_shutdown_error: ?Error = null,
    active_catalog_calls: usize = 0,
    active_catalog_leases: usize = 0,
    active_mcp_calls: usize = 0,
    active_restore_calls: usize = 0,
    mcp_refresh_running: bool = false,
    mcp_catalog_generation: ?u64 = null,
    mcp_registry_generation: ?u64,
    mcp_owner_id: u64,
    mcp_servers: mcp_runtime.Servers,
    next_session_id: u64 = 0,

    pub fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
        limits: Limits,
    ) (Error || std.mem.Allocator.Error || error{UnsupportedAbi})!*Runtime {
        return initWithValidatedApi(io, allocator, try sdk.Api.discover(), limits);
    }

    /// Test-only injection boundary. `raw_api` is borrowed for the Agent
    /// Runtime lifetime and must outlive the Runtime.
    pub fn initWithApi(
        io: std.Io,
        allocator: std.mem.Allocator,
        raw_api: *const wire.ApiV1,
        limits: Limits,
    ) (Error || std.mem.Allocator.Error || error{UnsupportedAbi})!*Runtime {
        return initWithValidatedApi(io, allocator, try sdk.Api.validate(raw_api), limits);
    }

    fn initWithValidatedApi(
        io: std.Io,
        allocator: std.mem.Allocator,
        api: sdk.Api,
        limits: Limits,
    ) (Error || std.mem.Allocator.Error)!*Runtime {
        if (limits.max_sessions == 0 or limits.max_prompt_bytes == 0 or limits.event_capacity == 0 or
            limits.event_bytes == 0 or limits.per_session_event_capacity == 0 or
            limits.per_session_event_bytes == 0 or limits.max_event_bytes == 0 or
            limits.event_enqueue_timeout.nanoseconds <= 0 or limits.max_ui_request_bytes == 0 or
            limits.max_ui_response_bytes == 0 or limits.max_terminal_diagnostic_bytes == 0 or
            limits.ui_request_timeout.nanoseconds <= 0 or
            limits.event_ready_retry_interval.nanoseconds <= 0 or
            limits.event_ready_timeout.nanoseconds <= 0 or
            limits.event_ready_retry_interval.nanoseconds > limits.event_ready_timeout.nanoseconds)
            return error.InvalidLimits;
        const mcp_owner_id = try allocateMcpOwnerId();
        _ = std.math.mul(usize, limits.event_capacity, limits.max_event_bytes) catch
            return error.InvalidLimits;
        const self = try allocator.create(Runtime);
        errdefer allocator.destroy(self);
        const sessions = try allocator.alloc(?*Session, limits.max_sessions);
        errdefer allocator.free(sessions);
        @memset(sessions, null);
        const session_reservations = try allocator.alloc(bool, limits.max_sessions);
        errdefer allocator.free(session_reservations);
        @memset(session_reservations, false);
        var events = try event_pump.EventPump.init(
            io,
            allocator,
            .{
                .max_event_bytes = limits.max_event_bytes,
                .global_count = limits.event_capacity,
                .global_bytes = limits.event_bytes,
                .global_control_reserved_count = limits.control_reserved_capacity,
                .global_control_reserved_bytes = limits.control_reserved_bytes,
                .per_session_count = limits.per_session_event_capacity,
                .per_session_bytes = limits.per_session_event_bytes,
                .per_session_control_reserved_count = limits.per_session_control_reserved_capacity,
                .per_session_control_reserved_bytes = limits.per_session_control_reserved_bytes,
                .session_slots = limits.max_sessions,
            },
        );
        errdefer events.deinit();

        var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
        runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
        var builtin_views: [registered_builtin_tools.len]wire.BytesViewV1 = undefined;
        for (registered_builtin_tools, 0..) |name, index|
            builtin_views[index] = sdk.bytesView(name);
        runtime_config.builtin_tools = &builtin_views;
        runtime_config.builtin_tool_count = builtin_views.len;
        runtime_config.host_tools = null;
        runtime_config.host_tool_count = 0;
        const mcp_registry_generation = if (limits.mcp_input) |input|
            input.generation
        else
            null;
        var mcp_servers = if (limits.mcp_input) |input|
            input.take() catch return error.InvalidLimits
        else
            mcp_runtime.Servers.init(allocator, &.{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidConfig => return error.InvalidLimits,
            };
        errdefer mcp_servers.deinit();
        mcp_servers.attach(&runtime_config);
        var diagnostic = emptyOwnedBytes();
        var runtime: ?*wire.RuntimeHandle = null;
        const status = api.runtimeCreate()(&runtime_config, &runtime, &diagnostic);
        defer releaseOwned(api, &diagnostic);
        const typed_status = sdk.Status.fromCode(status) catch return error.CoreCallFailed;
        if (typed_status != .ok or runtime == null) return error.CoreCallFailed;
        errdefer {
            var destroy_diagnostic = emptyOwnedBytes();
            _ = api.runtimeDestroy()(runtime, &destroy_diagnostic);
            releaseOwned(api, &destroy_diagnostic);
        }

        self.* = .{
            .io = io,
            .allocator = allocator,
            .api = api,
            .runtime = runtime,
            .max_prompt_bytes = limits.max_prompt_bytes,
            .max_event_bytes = limits.max_event_bytes,
            .event_enqueue_timeout = limits.event_enqueue_timeout,
            .max_ui_request_bytes = limits.max_ui_request_bytes,
            .max_ui_response_bytes = limits.max_ui_response_bytes,
            .max_terminal_diagnostic_bytes = limits.max_terminal_diagnostic_bytes,
            .ui_request_timeout = limits.ui_request_timeout,
            .event_ready_notifier = limits.event_ready_notifier,
            .event_ready_retry_interval = limits.event_ready_retry_interval,
            .event_ready_timeout = limits.event_ready_timeout,
            .events = events,
            .sessions = sessions,
            .session_reservations = session_reservations,
            .mcp_owner_id = mcp_owner_id,
            .mcp_registry_generation = mcp_registry_generation,
            .mcp_servers = mcp_servers,
        };
        return self;
    }

    /// Performs one synchronous AgentCore discovery call. Workbench decides
    /// where this blocking operation runs and owns the returned projection and
    /// opaque lease as two independent linear values.
    pub fn querySkillCatalog(
        self: *Runtime,
        input: CatalogQuery,
    ) (Error || std.mem.Allocator.Error)!CatalogAcquisition {
        try validateCanonicalDirectory(self.io, self.allocator, input.workspace_root);
        try validateCanonicalDirectory(
            self.io,
            self.allocator,
            input.canonical_user_home,
        );

        self.sessions_mutex.lockUncancelable(self.io);
        if (self.shutting_down.load(.acquire)) {
            self.sessions_mutex.unlock(self.io);
            return error.RuntimeShuttingDown;
        }
        const raw_runtime = self.runtime orelse {
            self.sessions_mutex.unlock(self.io);
            return error.RuntimeShuttingDown;
        };
        self.active_catalog_calls += 1;
        self.sessions_mutex.unlock(self.io);

        var acquisition = catalog.query(
            self.allocator,
            self.api,
            raw_runtime,
            self,
            input,
        ) catch |err| {
            self.finishCatalogCall();
            return err;
        };

        self.sessions_mutex.lockUncancelable(self.io);
        std.debug.assert(self.active_catalog_calls > 0);
        self.active_catalog_calls -= 1;
        self.active_catalog_leases += 1;
        const reject = self.shutting_down.load(.acquire);
        self.shutdown_condition.broadcast(self.io);
        self.sessions_mutex.unlock(self.io);
        if (reject) {
            acquisition.projection.deinit();
            try self.releaseSkillCatalog(acquisition.lease);
            return error.RuntimeShuttingDown;
        }
        return acquisition;
    }

    /// Consumes one opaque Host catalog handle. The AgentCore release function
    /// is called exactly once even if it reports failure.
    pub fn releaseSkillCatalog(
        self: *Runtime,
        lease: *CatalogLease,
    ) Error!void {
        if (!catalog.belongsTo(lease, self))
            return error.CatalogBindingMismatch;
        self.sessions_mutex.lockUncancelable(self.io);
        if (self.runtime == null or self.active_catalog_leases == 0) {
            self.sessions_mutex.unlock(self.io);
            return error.CatalogBindingMismatch;
        }
        self.active_catalog_calls += 1;
        self.sessions_mutex.unlock(self.io);

        var release_error: ?Error = null;
        catalog.release(lease) catch |err| {
            release_error = err;
        };
        self.sessions_mutex.lockUncancelable(self.io);
        std.debug.assert(self.active_catalog_calls > 0);
        std.debug.assert(self.active_catalog_leases > 0);
        self.active_catalog_calls -= 1;
        self.active_catalog_leases -= 1;
        self.shutdown_condition.broadcast(self.io);
        self.sessions_mutex.unlock(self.io);
        if (release_error) |err| return err;
    }

    fn finishCatalogCall(self: *Runtime) void {
        self.sessions_mutex.lockUncancelable(self.io);
        std.debug.assert(self.active_catalog_calls > 0);
        self.active_catalog_calls -= 1;
        self.shutdown_condition.broadcast(self.io);
        self.sessions_mutex.unlock(self.io);
    }

    /// Refreshes and describes the immutable AgentCore MCP catalog in one
    /// serialized Runtime operation. Only the official SDK decoder sees the
    /// raw descriptor; callers receive the reduced MetaWork-owned projection.
    pub fn refreshMcpCatalog(
        self: *Runtime,
    ) (Error || std.mem.Allocator.Error)!*McpCatalogProjection {
        const projection = try self.performMcpRefresh(try self.beginMcpRefresh());
        self.completeMcpRefresh(mcp_catalog.projectionGeneration(projection)) catch |err| {
            projection.deinit();
            return err;
        };
        return projection;
    }

    fn beginMcpRefresh(self: *Runtime) Error!McpRefreshLease {
        self.sessions_mutex.lockUncancelable(self.io);
        if (self.shutting_down.load(.acquire)) {
            self.sessions_mutex.unlock(self.io);
            return error.RuntimeShuttingDown;
        }
        if (self.mcp_refresh_running) {
            self.sessions_mutex.unlock(self.io);
            return error.McpRefreshInProgress;
        }
        const raw_runtime = self.runtime orelse {
            self.sessions_mutex.unlock(self.io);
            return error.RuntimeShuttingDown;
        };
        const expected_servers = self.mcp_servers.expectedServers();
        // Refresh is an authority fence. Old selections become stale before
        // any transport or AgentCore call, and remain stale on every failure.
        self.mcp_catalog_generation = null;
        self.mcp_refresh_running = true;
        self.active_mcp_calls += 1;
        self.sessions_mutex.unlock(self.io);
        return .{
            .raw_runtime = raw_runtime,
            .expected_servers = expected_servers,
            .registry_generation = self.mcp_registry_generation,
        };
    }

    fn performMcpRefresh(
        self: *Runtime,
        lease: McpRefreshLease,
    ) (Error || std.mem.Allocator.Error)!*McpCatalogProjection {
        const projection = mcp_catalog.refresh(
            self.allocator,
            self.api,
            lease.raw_runtime,
            self.mcp_owner_id,
            lease.expected_servers,
        ) catch |err| {
            self.finishMcpCall();
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return mapMcpCatalogError(err);
        };
        return projection;
    }

    fn completeMcpRefresh(self: *Runtime, generation: u64) Error!void {
        self.sessions_mutex.lockUncancelable(self.io);
        std.debug.assert(self.active_mcp_calls > 0);
        std.debug.assert(self.mcp_refresh_running);
        self.active_mcp_calls -= 1;
        self.mcp_refresh_running = false;
        const reject = self.shutting_down.load(.acquire);
        if (!reject)
            self.mcp_catalog_generation = generation;
        self.shutdown_condition.broadcast(self.io);
        self.sessions_mutex.unlock(self.io);
        if (reject) return error.RuntimeShuttingDown;
    }

    /// Builds one complete catalog/allowlist authority generation. Expected
    /// post-Runtime MCP failures become an unavailable outcome; Runtime and
    /// ordinary Session creation remain usable with a null selection.
    pub fn activateMcp(
        self: *Runtime,
    ) (Error || std.mem.Allocator.Error)!McpActivationOutcome {
        const lease = try self.beginMcpRefresh();
        if (lease.expected_servers.len == 0) {
            self.finishMcpCall();
            return .empty;
        }
        const projection = self.performMcpRefresh(lease) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.RuntimeShuttingDown,
            error.McpRefreshInProgress,
            => return err,
            else => return .{ .unavailable = mcpActivationUnavailableReason(err) },
        };
        const durable_generation = lease.registry_generation orelse {
            projection.deinit();
            self.finishMcpCall();
            return error.McpCatalogBindingMismatch;
        };
        const activation = mcp_catalog.createActivation(
            self.allocator,
            durable_generation,
            self.mcp_owner_id,
            projection,
            lease.expected_servers,
        ) catch |err| {
            projection.deinit();
            self.finishMcpCall();
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => .{ .unavailable = mcpActivationUnavailableReason(
                    mapMcpCatalogError(err),
                ) },
            };
        };
        self.completeMcpRefresh(activation.catalogGeneration()) catch |err| {
            activation.deinit();
            return err;
        };
        return .{ .activated = activation };
    }

    pub fn createMcpSelection(
        self: *Runtime,
        projection: *const McpCatalogProjection,
        selectors: []const McpSelector,
    ) (Error || std.mem.Allocator.Error)!*McpSelection {
        self.sessions_mutex.lockUncancelable(self.io);
        defer self.sessions_mutex.unlock(self.io);
        if (self.shutting_down.load(.acquire))
            return error.RuntimeShuttingDown;
        if (self.mcp_refresh_running) return error.McpRefreshInProgress;
        if (!mcp_catalog.projectionBelongsTo(
            projection,
            self.mcp_owner_id,
        )) return error.McpCatalogBindingMismatch;
        if (self.mcp_catalog_generation == null or
            self.mcp_catalog_generation.? != mcp_catalog.projectionGeneration(projection))
            return error.StaleMcpSelection;
        return mcp_catalog.createSelection(
            self.allocator,
            self.mcp_owner_id,
            projection,
            selectors,
        ) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return mapMcpCatalogError(err);
        };
    }

    pub fn createMcpAdmissionSelection(
        self: *Runtime,
        activation: *const McpActivation,
        allowlists: []const McpServerAllowlist,
    ) (Error || std.mem.Allocator.Error)!?*McpSelection {
        self.sessions_mutex.lockUncancelable(self.io);
        defer self.sessions_mutex.unlock(self.io);
        if (self.shutting_down.load(.acquire))
            return error.RuntimeShuttingDown;
        if (self.mcp_refresh_running) return error.McpRefreshInProgress;
        if (self.mcp_catalog_generation == null or
            self.mcp_catalog_generation.? != activation.catalogGeneration())
            return error.StaleMcpSelection;
        return mcp_catalog.createSelectionForActivation(
            self.allocator,
            self.mcp_owner_id,
            activation,
            allowlists,
        ) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return mapMcpCatalogError(err);
        };
    }

    /// Replaces one idle Session's complete MCP authority view. Holding the
    /// Runtime mutex across the synchronous ABI call prevents a catalog
    /// refresh, shutdown, or Session release from changing the validated
    /// Runtime generation while AgentCore copies the selection.
    fn updateSessionMcpSelection(
        self: *Runtime,
        session: *Session,
        selection: ?*const McpSelection,
    ) Error!void {
        self.sessions_mutex.lockUncancelable(self.io);
        defer self.sessions_mutex.unlock(self.io);
        if (self.shutting_down.load(.acquire))
            return error.RuntimeShuttingDown;
        if (self.mcp_refresh_running) return error.McpRefreshInProgress;

        var found = false;
        for (self.sessions) |entry| if (entry == session) {
            found = true;
            break;
        };
        if (!found) return error.UnknownSession;
        if (selection) |value| {
            if (!mcp_catalog.belongsTo(value, self.mcp_owner_id))
                return error.McpCatalogBindingMismatch;
            if (self.mcp_catalog_generation == null or
                mcp_catalog.selectionGeneration(value) != self.mcp_catalog_generation.?)
                return error.StaleMcpSelection;
        }

        session.lock();
        defer session.unlock();
        switch (session.state) {
            .idle => {},
            .queued, .running, .waiting_ui, .compact_queued, .compacting, .checkpointing => return error.SessionNotIdle,
            .poisoned => return error.SessionPoisoned,
            .closing, .closed => return error.SessionClosing,
        }
        std.debug.assert(session.run_done);
        std.debug.assert(session.compact_done);
        std.debug.assert(!session.core_call_in_progress);
        std.debug.assert(session.abort_calls_in_progress == 0);

        const raw_selection = mcp_catalog.rawSelectionReplacement(selection);
        var diagnostic = emptyOwnedBytes();
        const status_code = self.api.sessionUpdateMcp()(
            session.raw,
            &raw_selection,
            &diagnostic,
        );
        releaseOwned(self.api, &diagnostic);
        const status = sdk.Status.fromCode(status_code) catch
            return session.failMcpUpdateContractLocked();
        const disposition = mcpUpdateStatusDisposition(status) orelse
            return session.failMcpUpdateContractLocked();
        if (disposition == .poisoned) {
            session.state = .poisoned;
            session.broadcast();
            return error.SessionPoisoned;
        }
        return switch (status) {
            .ok => {},
            .busy => error.SessionNotIdle,
            .mcp_not_refreshed => error.McpNotRefreshed,
            .invalid_mcp_selection => error.InvalidMcpSelection,
            .checkpoint_budget_required => error.McpCheckpointBudgetRequired,
            .out_of_memory, .core_error, .resource_limit => error.McpSelectionUpdateFailed,
            else => unreachable,
        };
    }

    fn finishMcpCall(self: *Runtime) void {
        self.sessions_mutex.lockUncancelable(self.io);
        std.debug.assert(self.active_mcp_calls > 0);
        std.debug.assert(self.mcp_refresh_running);
        self.active_mcp_calls -= 1;
        self.mcp_refresh_running = false;
        self.shutdown_condition.broadcast(self.io);
        self.sessions_mutex.unlock(self.io);
    }

    pub fn createSession(
        self: *Runtime,
        options: SessionOpenOptions,
    ) (Error || std.mem.Allocator.Error)!*Session {
        return (try self.createSessionRoute(options)).session;
    }

    /// Lightweight observation used only to project recovery eligibility.
    /// restoreSessionRoute revalidates under the same mutex and remains the
    /// admission linearization point.
    pub fn restoreAdmissionAvailable(self: *Runtime) bool {
        self.sessions_mutex.lockUncancelable(self.io);
        defer self.sessions_mutex.unlock(self.io);
        if (self.shutting_down.load(.acquire) or
            self.runtime == null or
            self.mcp_refresh_running)
            return false;
        for (self.sessions, self.session_reservations) |entry, reserved|
            if (entry == null and !reserved) return true;
        return false;
    }

    /// Creates one Agent Session and returns its canonical routing identity in
    /// the same operation. Product owners must not reconstruct this identity
    /// from a live Session snapshot.
    pub fn createSessionRoute(
        self: *Runtime,
        options: SessionOpenOptions,
    ) (Error || std.mem.Allocator.Error)!SessionRoute {
        try validateWorkspace(options.workspace);
        if (options.credential.len == 0 or options.model.len == 0)
            return error.CoreCallFailed;
        if (options.canonical_user_home.len != 0)
            try validateCanonicalDirectory(
                self.io,
                self.allocator,
                options.canonical_user_home,
            );
        if (options.skill_catalog) |lease| {
            if (!catalog.belongsTo(lease, self) or
                !catalog.matches(
                    lease,
                    options.workspace.canonical_root,
                    options.canonical_user_home,
                    options.workspace_epoch,
                ))
                return error.CatalogBindingMismatch;
        }

        self.sessions_mutex.lockUncancelable(self.io);
        defer self.sessions_mutex.unlock(self.io);
        if (self.shutting_down.load(.acquire)) return error.RuntimeShuttingDown;
        if (self.mcp_refresh_running) return error.McpRefreshInProgress;
        if (options.mcp_selection) |selection| {
            if (!mcp_catalog.belongsTo(selection, self.mcp_owner_id))
                return error.McpCatalogBindingMismatch;
            if (self.mcp_catalog_generation == null or
                mcp_catalog.selectionGeneration(selection) != self.mcp_catalog_generation.?)
                return error.StaleMcpSelection;
        }
        var slot: ?usize = null;
        for (self.sessions, self.session_reservations, 0..) |entry, reserved, index| {
            if (entry == null and !reserved) {
                slot = index;
                break;
            }
        }
        const session_slot = slot orelse return error.SessionCapacity;
        if (self.next_session_id == std.math.maxInt(u64)) return error.SessionIdExhausted;
        self.next_session_id += 1;
        const session_id = self.next_session_id;

        const session = try self.allocator.create(Session);
        errdefer self.allocator.destroy(session);
        const control_block = try self.allocator.create(SessionControlBlock);
        errdefer self.allocator.destroy(control_block);
        const workspace_root = try self.allocator.dupe(u8, options.workspace.canonical_root);
        errdefer self.allocator.free(workspace_root);
        const workspace_home = try self.allocator.dupe(
            u8,
            options.canonical_user_home,
        );
        errdefer self.allocator.free(workspace_home);
        const workspace_epoch = try self.allocator.dupe(
            u8,
            options.workspace_epoch,
        );
        errdefer self.allocator.free(workspace_epoch);
        session.* = .{
            .agent_runtime = self,
            .id = session_id,
            .workspace_root = workspace_root,
            .workspace_home = workspace_home,
            .workspace_epoch = workspace_epoch,
            .control_block = control_block,
        };
        control_block.* = .{ .session = session };

        const secret = try self.allocator.dupe(u8, options.credential);
        defer {
            secureZero(secret);
            self.allocator.free(secret);
        }
        var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
        callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
        callbacks.ctx = session;
        callbacks.on_event = Session.onEvent;
        callbacks.on_ui_request = Session.onUiRequest;
        callbacks.release_response = Session.releaseUiResponse;
        var host_config = std.mem.zeroes(wire.SessionHostConfigV1);
        host_config.struct_size = @sizeOf(wire.SessionHostConfigV1);
        host_config.provider_kind_code = providerKindCode(options.provider);
        host_config.permission_mode_code = permissionModeCode(options.permission_mode);
        host_config.shell_policy_code = shellPolicyCode(options.shell_policy);
        host_config.api_key = sdk.bytesView(secret);
        host_config.base_url = sdk.bytesView(options.base_url);
        host_config.workspace_root = sdk.bytesView(workspace_root);
        host_config.workspace_home = sdk.bytesView(workspace_home);
        const skill_selection = allSkillsEnabledSelection();
        host_config.skill_catalog = if (options.skill_catalog) |lease|
            catalog.rawHandle(lease)
        else
            null;
        host_config.skill_selection = if (options.skill_catalog != null)
            &skill_selection
        else
            null;
        host_config.permission_rules = null;
        const raw_mcp_selection = if (options.mcp_selection != null)
            mcp_catalog.rawSelectionReplacement(options.mcp_selection)
        else
            undefined;
        host_config.mcp_selection = if (options.mcp_selection != null)
            &raw_mcp_selection
        else
            null;
        host_config.durable_budget = null;
        const allowed_views = try self.allocator.alloc(wire.BytesViewV1, options.allowed_tools.len);
        defer self.allocator.free(allowed_views);
        for (options.allowed_tools, 0..) |name, index|
            allowed_views[index] = sdk.bytesView(name);
        host_config.allowed_tools = if (allowed_views.len == 0) null else allowed_views.ptr;
        host_config.allowed_tool_count = allowed_views.len;
        var config = std.mem.zeroes(wire.SessionCreateConfigV1);
        config.struct_size = @sizeOf(wire.SessionCreateConfigV1);
        config.host = &host_config;
        config.model = sdk.bytesView(options.model);

        var diagnostic = emptyOwnedBytes();
        var raw_session: ?*wire.SessionHandle = null;
        const status = self.api.sessionCreate()(
            self.runtime,
            &config,
            &callbacks,
            &raw_session,
            &diagnostic,
        );
        defer releaseOwned(self.api, &diagnostic);
        const typed_status = sdk.Status.fromCode(status) catch return error.CoreCallFailed;
        if (typed_status != .ok or raw_session == null) {
            return error.CoreCallFailed;
        }
        session.raw = raw_session;
        self.sessions[session_slot] = session;
        return .{ .id = session_id, .session = session };
    }

    /// Restores one Session without holding `sessions_mutex` across the
    /// streaming AgentCore call. The reservation and in-flight fence keep the
    /// route slot and Runtime handle valid until the candidate is either
    /// installed or destroyed.
    pub fn restoreSessionRoute(
        self: *Runtime,
        options: SessionRestoreOptions,
    ) (Error || std.mem.Allocator.Error)!SessionRestoreRoute {
        const session_options = options.session;
        try validateWorkspace(session_options.workspace);
        try checkpoint.validateLimits(options.checkpoint_limits);
        if (session_options.credential.len == 0 or
            session_options.model.len == 0 or
            !std.mem.eql(u8, session_options.model, options.expectation.model) or
            options.expectation.logical_session_id.len == 0 or
            options.expectation.logical_session_id.len > max_core_session_id_bytes or
            options.expectation.checkpoint_generation == 0)
            return error.RestoreInvalid;
        if (session_options.canonical_user_home.len != 0)
            try validateCanonicalDirectory(
                self.io,
                self.allocator,
                session_options.canonical_user_home,
            );
        if (session_options.skill_catalog) |lease| {
            if (!catalog.belongsTo(lease, self) or
                !catalog.matches(
                    lease,
                    session_options.workspace.canonical_root,
                    session_options.canonical_user_home,
                    session_options.workspace_epoch,
                ))
                return error.CatalogBindingMismatch;
        }

        const session = try self.allocator.create(Session);
        var session_installed = false;
        defer if (!session_installed) self.allocator.destroy(session);
        const control_block = try self.allocator.create(SessionControlBlock);
        var control_installed = false;
        defer if (!control_installed) self.allocator.destroy(control_block);
        const workspace_root = try self.allocator.dupe(
            u8,
            session_options.workspace.canonical_root,
        );
        var workspace_root_installed = false;
        defer if (!workspace_root_installed) self.allocator.free(workspace_root);
        const workspace_home = try self.allocator.dupe(
            u8,
            session_options.canonical_user_home,
        );
        var workspace_home_installed = false;
        defer if (!workspace_home_installed) self.allocator.free(workspace_home);
        const workspace_epoch = try self.allocator.dupe(
            u8,
            session_options.workspace_epoch,
        );
        var workspace_epoch_installed = false;
        defer if (!workspace_epoch_installed) self.allocator.free(workspace_epoch);
        const secret = try self.allocator.dupe(u8, session_options.credential);
        defer {
            secureZero(secret);
            self.allocator.free(secret);
        }
        const allowed_views = try self.allocator.alloc(
            wire.BytesViewV1,
            session_options.allowed_tools.len,
        );
        defer self.allocator.free(allowed_views);
        for (session_options.allowed_tools, 0..) |name, index|
            allowed_views[index] = sdk.bytesView(name);

        self.sessions_mutex.lockUncancelable(self.io);
        if (self.shutting_down.load(.acquire)) {
            self.sessions_mutex.unlock(self.io);
            return error.RuntimeShuttingDown;
        }
        const raw_runtime = self.runtime orelse {
            self.sessions_mutex.unlock(self.io);
            return error.RuntimeShuttingDown;
        };
        if (self.mcp_refresh_running) {
            self.sessions_mutex.unlock(self.io);
            return error.McpRefreshInProgress;
        }
        if (session_options.mcp_selection) |selection| {
            if (!mcp_catalog.belongsTo(selection, self.mcp_owner_id)) {
                self.sessions_mutex.unlock(self.io);
                return error.McpCatalogBindingMismatch;
            }
            if (self.mcp_catalog_generation == null or
                mcp_catalog.selectionGeneration(selection) != self.mcp_catalog_generation.?)
            {
                self.sessions_mutex.unlock(self.io);
                return error.StaleMcpSelection;
            }
        }
        var slot: ?usize = null;
        for (self.sessions, self.session_reservations, 0..) |entry, reserved, index| {
            if (entry == null and !reserved) {
                slot = index;
                break;
            }
        }
        const session_slot = slot orelse {
            self.sessions_mutex.unlock(self.io);
            return error.SessionCapacity;
        };
        if (self.next_session_id == std.math.maxInt(u64)) {
            self.sessions_mutex.unlock(self.io);
            return error.SessionIdExhausted;
        }
        self.next_session_id += 1;
        const route_id = self.next_session_id;
        self.session_reservations[session_slot] = true;
        self.active_restore_calls += 1;
        self.sessions_mutex.unlock(self.io);

        var identity = CoreSessionIdentity{ .bound = .{
            .len = options.expectation.logical_session_id.len,
            .bytes = [_]u8{0} ** max_core_session_id_bytes,
        } };
        @memcpy(
            identity.bound.bytes[0..options.expectation.logical_session_id.len],
            options.expectation.logical_session_id,
        );
        session.* = .{
            .agent_runtime = self,
            .id = route_id,
            .workspace_root = workspace_root,
            .workspace_home = workspace_home,
            .workspace_epoch = workspace_epoch,
            .control_block = control_block,
            .next_run_id = options.expectation.last_run_id,
            .next_compact_id = options.expectation.last_compact_id,
            .core_session_identity = identity,
        };
        control_block.* = .{ .session = session };

        var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
        callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
        callbacks.ctx = session;
        callbacks.on_event = Session.onEvent;
        callbacks.on_ui_request = Session.onUiRequest;
        callbacks.release_response = Session.releaseUiResponse;
        var host_config = std.mem.zeroes(wire.SessionHostConfigV1);
        host_config.struct_size = @sizeOf(wire.SessionHostConfigV1);
        host_config.provider_kind_code = providerKindCode(session_options.provider);
        host_config.permission_mode_code = permissionModeCode(session_options.permission_mode);
        host_config.shell_policy_code = shellPolicyCode(session_options.shell_policy);
        host_config.api_key = sdk.bytesView(secret);
        host_config.base_url = sdk.bytesView(session_options.base_url);
        host_config.workspace_root = sdk.bytesView(workspace_root);
        host_config.workspace_home = sdk.bytesView(workspace_home);
        const skill_selection = allSkillsEnabledSelection();
        host_config.skill_catalog = if (session_options.skill_catalog) |lease|
            catalog.rawHandle(lease)
        else
            null;
        host_config.skill_selection = if (session_options.skill_catalog != null)
            &skill_selection
        else
            null;
        host_config.permission_rules = null;
        const raw_mcp_selection = if (session_options.mcp_selection != null)
            mcp_catalog.rawSelectionReplacement(session_options.mcp_selection)
        else
            undefined;
        host_config.mcp_selection = if (session_options.mcp_selection != null)
            &raw_mcp_selection
        else
            null;
        host_config.durable_budget = null;
        host_config.allowed_tools = if (allowed_views.len == 0) null else allowed_views.ptr;
        host_config.allowed_tool_count = allowed_views.len;

        const outcome = checkpoint_restore.restore(
            self.allocator,
            self.api,
            raw_runtime,
            &host_config,
            &callbacks,
            options.checkpoint_limits,
            options.source,
            options.expectation,
        );
        switch (outcome) {
            .failure => |failure| {
                if (failure.retained_candidate) |candidate| {
                    self.retainFailedRestoreCandidate(session_slot, session, candidate);
                    session_installed = true;
                    control_installed = true;
                    workspace_root_installed = true;
                    workspace_home_installed = true;
                    workspace_epoch_installed = true;
                } else {
                    self.finishRestoreReservation(session_slot);
                }
                return mapRestoreFailure(failure);
            },
            .success => {},
        }
        var success = outcome.success;
        var metadata_live = true;
        defer if (metadata_live) success.deinitMetadata();

        self.sessions_mutex.lockUncancelable(self.io);
        std.debug.assert(self.active_restore_calls > 0);
        std.debug.assert(self.session_reservations[session_slot]);
        std.debug.assert(self.sessions[session_slot] == null);
        const reject = self.shutting_down.load(.acquire) or self.runtime != raw_runtime;
        if (!reject) {
            session.raw = success.raw_session;
            self.sessions[session_slot] = session;
            self.session_reservations[session_slot] = false;
            self.active_restore_calls -= 1;
            self.shutdown_condition.broadcast(self.io);
            self.sessions_mutex.unlock(self.io);
            const report = success.report;
            success.deinitMetadata();
            metadata_live = false;
            session_installed = true;
            control_installed = true;
            workspace_root_installed = true;
            workspace_home_installed = true;
            workspace_epoch_installed = true;
            return .{ .id = route_id, .session = session, .report = report };
        }
        self.sessions_mutex.unlock(self.io);

        const destroyed = checkpoint_restore.destroyCandidate(self.api, success.raw_session);
        if (!destroyed) {
            // A non-OK destroy status keeps the handle valid. Install the
            // poisoned candidate so Runtime.shutdown owns the final retry.
            self.retainFailedRestoreCandidate(session_slot, session, success.raw_session);
            session_installed = true;
            control_installed = true;
            workspace_root_installed = true;
            workspace_home_installed = true;
            workspace_epoch_installed = true;
        } else {
            self.finishRestoreReservation(session_slot);
        }
        return error.RuntimeShuttingDown;
    }

    fn retainFailedRestoreCandidate(
        self: *Runtime,
        session_slot: usize,
        session: *Session,
        candidate: *wire.SessionHandle,
    ) void {
        self.sessions_mutex.lockUncancelable(self.io);
        std.debug.assert(self.active_restore_calls > 0);
        std.debug.assert(self.session_reservations[session_slot]);
        std.debug.assert(self.sessions[session_slot] == null);
        session.raw = candidate;
        session.state = .poisoned;
        self.sessions[session_slot] = session;
        self.session_reservations[session_slot] = false;
        self.active_restore_calls -= 1;
        self.shutdown_condition.broadcast(self.io);
        self.sessions_mutex.unlock(self.io);
    }

    fn finishRestoreReservation(self: *Runtime, session_slot: usize) void {
        self.sessions_mutex.lockUncancelable(self.io);
        std.debug.assert(self.active_restore_calls > 0);
        std.debug.assert(self.session_reservations[session_slot]);
        std.debug.assert(self.sessions[session_slot] == null);
        self.session_reservations[session_slot] = false;
        self.active_restore_calls -= 1;
        self.shutdown_condition.broadcast(self.io);
        self.sessions_mutex.unlock(self.io);
    }

    pub fn shutdown(self: *Runtime) Error!void {
        self.sessions_mutex.lockUncancelable(self.io);
        var waited = false;
        while (self.shutdown_running) {
            waited = true;
            self.shutdown_condition.waitUncancelable(self.io, &self.sessions_mutex);
        }
        if (self.shutdown_complete) {
            self.sessions_mutex.unlock(self.io);
            return;
        }
        if (waited) {
            const prior_error = self.last_shutdown_error;
            self.sessions_mutex.unlock(self.io);
            if (prior_error) |err| return err;
            return;
        }
        self.shutdown_running = true;
        self.last_shutdown_error = null;
        self.shutting_down.store(true, .release);
        while (self.active_catalog_calls != 0 or self.active_mcp_calls != 0 or
            self.active_restore_calls != 0)
            self.shutdown_condition.waitUncancelable(
                self.io,
                &self.sessions_mutex,
            );
        const sessions = self.sessions;
        self.sessions_mutex.unlock(self.io);

        var first_error: ?Error = null;
        for (sessions) |entry| {
            if (entry) |session| {
                session.close(.app_shutdown) catch |err| if (first_error == null) {
                    first_error = err;
                };
            }
        }
        if (first_error != null) return self.finishShutdown(first_error);

        self.sessions_mutex.lockUncancelable(self.io);
        const outstanding_catalogs = self.active_catalog_leases;
        self.sessions_mutex.unlock(self.io);
        if (outstanding_catalogs != 0)
            return self.finishShutdown(error.CatalogLeasesOutstanding);

        if (self.runtime != null) {
            var diagnostic = emptyOwnedBytes();
            const status = self.api.runtimeDestroy()(self.runtime, &diagnostic);
            releaseOwned(self.api, &diagnostic);
            const typed_status = sdk.Status.fromCode(status) catch null;
            if (typed_status == .ok) {
                self.runtime = null;
            } else {
                first_error = error.RuntimeDestroyFailed;
            }
        }

        return self.finishShutdown(first_error);
    }

    pub fn releaseClosedSession(self: *Runtime, session: *Session) Error!void {
        // Successful release transfers the last owner reference to Runtime and
        // invalidates `session`; callers must quiesce their own references.
        self.sessions_mutex.lockUncancelable(self.io);
        defer self.sessions_mutex.unlock(self.io);
        if (self.shutting_down.load(.acquire)) return error.RuntimeShuttingDown;

        var slot: ?usize = null;
        for (self.sessions, 0..) |entry, index| {
            if (entry == session) {
                slot = index;
                break;
            }
        }
        const session_slot = slot orelse return error.UnknownSession;
        session.lock();
        if (session.state != .closed) {
            session.unlock();
            return error.SessionNotClosed;
        }
        std.debug.assert(session.active_refs == 0);
        session.unlock();

        self.sessions[session_slot] = null;
        session.deinit();
        self.allocator.destroy(session);
    }

    pub fn takeEvent(self: *Runtime) ?OwnedCoreEvent {
        return self.events.takeFair();
    }

    fn notifyEventConsumer(self: *Runtime) EventReadyNotification {
        const notifier = self.event_ready_notifier orelse return .scheduled;
        return notifier.notifyWithRetry(
            self.io,
            self.event_ready_retry_interval,
            self.event_ready_timeout,
        );
    }

    pub fn requestWake(self: *Runtime) bool {
        return self.notifyEventConsumer() != .unavailable;
    }

    pub fn requestRunTermination(
        self: *Runtime,
        session_id: u64,
        run_id: u64,
        signal: TerminationSignal,
    ) Error!void {
        self.sessions_mutex.lockUncancelable(self.io);
        var retained: ?*Session = null;
        var found = false;
        for (self.sessions) |entry| {
            const session = entry orelse continue;
            if (session.id != session_id) continue;
            found = true;
            if (session.retainReference()) retained = session;
            break;
        }
        self.sessions_mutex.unlock(self.io);
        const session = retained orelse return if (found) error.SessionClosing else error.UnknownSession;
        defer session.releaseReference();
        return session.requestTermination(run_id, signal);
    }

    fn finishShutdown(self: *Runtime, result: ?Error) Error!void {
        self.sessions_mutex.lockUncancelable(self.io);
        self.shutdown_running = false;
        self.shutdown_complete = result == null;
        self.last_shutdown_error = result;
        self.shutdown_condition.broadcast(self.io);
        self.sessions_mutex.unlock(self.io);
        if (result) |err| return err;
    }

    pub fn deinit(self: *Runtime) void {
        std.debug.assert(self.shutdown_complete);
        std.debug.assert(self.active_catalog_calls == 0);
        std.debug.assert(self.active_catalog_leases == 0);
        std.debug.assert(self.active_mcp_calls == 0);
        std.debug.assert(self.active_restore_calls == 0);
        for (self.session_reservations) |reserved| std.debug.assert(!reserved);
        for (self.sessions) |entry| {
            if (entry) |session| {
                session.deinit();
                self.allocator.destroy(session);
            }
        }
        self.events.deinit();
        self.mcp_servers.deinit();
        self.allocator.free(self.session_reservations);
        self.allocator.free(self.sessions);
        const allocator = self.allocator;
        allocator.destroy(self);
    }
};

const max_core_session_id_bytes: usize = @intCast(wire.MAX_SESSION_ID_BYTES_V1);

const CoreSessionIdentity = union(enum) {
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

    fn lock(self: *Session) void {
        self.mutex.lockUncancelable(self.agent_runtime.io);
    }

    fn unlock(self: *Session) void {
        self.mutex.unlock(self.agent_runtime.io);
    }

    fn wait(self: *Session) void {
        self.condition.waitUncancelable(self.agent_runtime.io, &self.mutex);
    }

    fn broadcast(self: *Session) void {
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
        const status_code = self.agent_runtime.api.sessionCompact()(
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
    ) Error!void {
        if (!catalog.belongsTo(lease, self.agent_runtime) or
            !catalog.matches(
                lease,
                self.workspace_root,
                self.workspace_home,
                self.workspace_epoch,
            ))
            return error.CatalogBindingMismatch;
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
        const selection = allSkillsEnabledSelection();
        var diagnostic = emptyOwnedBytes();
        const status_code = self.agent_runtime.api.sessionUpdateSkills()(
            self.raw,
            catalog.rawHandle(lease),
            &selection,
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

    /// Applies a complete replacement of this idle Session's MCP authority.
    pub fn updateMcpSelection(
        self: *Session,
        selection: ?*const McpSelection,
    ) Error!void {
        return self.agent_runtime.updateSessionMcpSelection(self, selection);
    }

    fn failMcpUpdateContractLocked(self: *Session) Error {
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

    fn requestControlledTermination(
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

    pub fn respondAnswers(
        self: *Session,
        run_id: u64,
        request_id: u64,
        answers: []const Answer,
    ) (Error || std.mem.Allocator.Error)!void {
        self.lock();
        defer self.unlock();
        const request = try self.pendingUiRequestLocked(run_id, request_id);
        try self.encodeUiResponseLocked(request, .{ .answers = answers });
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
        const status = self.agent_runtime.api.sessionDestroy()(self.raw, &diagnostic);
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
            .text => |text| self.agent_runtime.api.sessionRunText(
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
                break :skill_run self.agent_runtime.api.sessionRunSkill(
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
        const status = self.agent_runtime.api.sessionAbort()(
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
        const status_code = self.agent_runtime.api.sessionAbortCompact()(
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

    fn deinit(self: *Session) void {
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

    fn onEvent(
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

    fn onUiRequest(
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
        const request_id = self.ui_request_id;
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

        var timer = self.agent_runtime.io.async(expireUiRequest, .{ self, request_id });
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

        timer.cancel(self.agent_runtime.io) catch |err| switch (err) {
            error.Canceled => {},
        };
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

    fn expireUiRequest(self: *Session, request_id: u64) std.Io.Cancelable!void {
        try self.agent_runtime.io.sleep(self.agent_runtime.ui_request_timeout, .awake);
        self.lock();
        var expired = false;
        if (self.ui_active and self.ui_request_id == request_id) {
            self.ui_active = false;
            if (self.state == .waiting_ui) self.state = .running;
            self.broadcast();
            expired = true;
        }
        self.unlock();
        if (expired) _ = self.agent_runtime.notifyEventConsumer();
    }

    fn releaseUiResponse(context: ?*anyopaque, out: ?*wire.OwnedBytesV1) callconv(.c) void {
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
            .ask_question => true,
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

fn validateWorkspace(input: WorkspaceInput) Error!void {
    if (!isCanonicalAbsolutePath(input.canonical_root)) return error.InvalidWorkspace;
    switch (input.trust) {
        .explicitly_trusted => {},
        .temporary => |canonical_temp_root| {
            if (!isCanonicalAbsolutePath(canonical_temp_root) or
                !pathWithin(canonical_temp_root, input.canonical_root))
                return error.WorkspaceNotTrusted;
        },
    }
}

fn validateCanonicalDirectory(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
) Error!void {
    if (!isCanonicalAbsolutePath(path) or
        !std.unicode.utf8ValidateSlice(path))
        return error.InvalidCatalogQuery;
    const canonical = std.Io.Dir.realPathFileAbsoluteAlloc(
        io,
        path,
        allocator,
    ) catch return error.InvalidCatalogQuery;
    defer allocator.free(canonical);
    if (!std.mem.eql(u8, canonical, path))
        return error.InvalidCatalogQuery;
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch
        return error.InvalidCatalogQuery;
    if (stat.kind != .directory) return error.InvalidCatalogQuery;
}

fn isCanonicalAbsolutePath(path: []const u8) bool {
    if (!std.fs.path.isAbsolute(path)) return false;
    if (path.len == 1) return path[0] == std.fs.path.sep;
    if (path.len > 1 and path[path.len - 1] == std.fs.path.sep) return false;
    var components = std.mem.splitScalar(u8, path[1..], std.fs.path.sep);
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or
            std.mem.eql(u8, component, "..")) return false;
    }
    return true;
}

fn pathWithin(parent: []const u8, child: []const u8) bool {
    if (std.mem.eql(u8, parent, child)) return true;
    if (!std.mem.startsWith(u8, child, parent)) return false;
    if (parent.len == 1 and parent[0] == std.fs.path.sep) return true;
    return child.len > parent.len and child[parent.len] == std.fs.path.sep;
}

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

const SessionStatusDisposition = enum {
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
        => false,
    };
}

fn mcpUpdateStatusDisposition(status: sdk.Status) ?SessionStatusDisposition {
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
        => null,
    };
}

fn allZero(values: []const u64) bool {
    for (values) |value| if (value != 0) return false;
    return true;
}

fn mapRestoreFailure(failure: checkpoint_restore.Failure) Error {
    return switch (failure.reason) {
        .invalid_argument => error.RestoreInvalid,
        .busy => error.RestoreBusy,
        .checkpoint_corrupt => error.CheckpointCorrupt,
        .checkpoint_unsupported => error.CheckpointUnsupported,
        .checkpoint_incompatible => error.CheckpointIncompatible,
        .logical_session_conflict => error.LogicalSessionConflict,
        .cancelled => error.RestoreCancelled,
        .io_failed => error.RestoreIoFailed,
        .dependency_contract => error.RestoreContractFailed,
        .out_of_memory,
        .resource_limit,
        .core_error,
        .invalid_state,
        .host_out_of_memory,
        => error.RestoreFailed,
    };
}

fn mapMcpCatalogError(err: anyerror) Error {
    return switch (err) {
        error.RefreshFailed, error.DescribeFailed => error.McpRefreshFailed,
        error.InvalidCatalogDescriptor => error.InvalidMcpCatalogDescriptor,
        error.CatalogResourceLimit => error.McpCatalogResourceLimit,
        error.CatalogGenerationMismatch => error.McpCatalogGenerationMismatch,
        error.CatalogBindingMismatch => error.McpCatalogBindingMismatch,
        error.DuplicateCatalogIdentity => error.InvalidMcpCatalogDescriptor,
        error.InvalidSelection => error.InvalidMcpSelection,
        error.StaleSelection => error.StaleMcpSelection,
        else => error.McpRefreshFailed,
    };
}

fn mcpActivationUnavailableReason(err: anyerror) McpActivationUnavailableReason {
    return switch (err) {
        error.McpRefreshFailed => .refresh_failed,
        error.InvalidMcpCatalogDescriptor => .invalid_catalog,
        error.McpCatalogResourceLimit => .resource_limit,
        error.McpCatalogGenerationMismatch => .generation_mismatch,
        error.McpCatalogBindingMismatch => .binding_mismatch,
        error.InvalidMcpSelection, error.StaleMcpSelection => .invalid_selection,
        else => .refresh_failed,
    };
}

fn allocateMcpOwnerId() Error!u64 {
    var current = next_mcp_owner_id.load(.acquire);
    while (current != std.math.maxInt(u64)) {
        if (next_mcp_owner_id.cmpxchgWeak(
            current,
            current + 1,
            .acq_rel,
            .acquire,
        )) |observed| {
            current = observed;
        } else return current;
    }
    return error.McpRuntimeIdentityExhausted;
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
