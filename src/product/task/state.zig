//! Task-owned aggregate state and product-visible Run/Compact lifecycle facts.
//! Executor jobs, Agent event pumping, persistence effects, revision publication,
//! and root snapshot orchestration remain composition responsibilities; Task
//! subtree derivation and encoding belong to the sibling view kernel.

const std = @import("std");
const builtin = @import("builtin");
const agent = @import("metawork_agent");
const checkpoint_record = @import("product_task_checkpoint_record");
const task_attachment = @import("product_task_attachment");
const task_deletion = @import("product_task_deletion");
const task_recovery = @import("product_task_recovery");

pub const automatic_title_result_capacity: usize = 512;
pub const ui_record_detail_capacity: usize = 512;
pub const permission_summary_field_capacity: usize = 128;
pub const tool_route_digest_bytes = std.crypto.hash.sha2.Sha256.digest_length;
pub const tool_product_id_capacity = "tool-".len + 20;

pub const Provider = enum {
    anthropic,
    openai,
    gemini,
};

pub const ToolState = enum { running, completed, failed };

pub const RunPhase = enum {
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

pub const RunOutcome = enum {
    completed,
    stopped,
    cancelled,
    interrupted,
    failed,
    dependency_contract_failure,
};

pub const CompactPhase = enum(u8) {
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

pub const CompactCause = enum {
    user_cancel,
    session_close,
    app_shutdown,
    resource_limit,
    agent_failure,
    dependency_contract_failure,
};

pub const CompactTerminationDispatch = enum {
    queued_aborted,
    requested,
    already_requested,
    already_terminal,
    session_closing,
};

pub const ActiveOperation = task_attachment.ActiveOperation;

/// Task-owned durable product cause.
pub const RunCause = enum {
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

pub const TaskLifecycle = enum { open, closing };
pub const ContinuationUnavailableReason = task_recovery.UnavailableReason;
pub const ContinuationCapability = task_recovery.Capability;
pub const CloseCompletion = task_attachment.CloseCompletion;

pub const TrackedText = struct {
    list: std.ArrayList(u8) = .empty,
    /// Bytes before this offset are final sanitized output. Bytes at and after
    /// it are the only suffix that can still become a cross-chunk credential.
    committed_len: usize = 0,
};

pub const AssistantOutputKind = enum { final, partial };

const OpenOutputSegment = struct {
    index: u32,
    turn: u32,
    group: u32,
    bytes: u64 = 0,
};

/// A bounded, redaction-safe permission decision summary. It contains no raw
/// arguments or response and may be attached to Run and UI occurrence history.
pub const PermissionSummary = struct {
    decision: agent.PermissionDecision,
    source: agent.PermissionDecisionSource,
    policy_generation: u64,
    used_session_rule: bool,
    callback_outcome: ?agent.PermissionCallbackOutcome,
    tool_namespace: agent.PermissionToolNamespace,
    request_id: [permission_summary_field_capacity]u8 = undefined,
    request_id_len: usize = 0,
    matched_rule_id: [permission_summary_field_capacity]u8 = undefined,
    matched_rule_id_len: usize = 0,
    tool_name: [permission_summary_field_capacity]u8 = undefined,
    tool_name_len: usize = 0,
    tool_binding: [permission_summary_field_capacity]u8 = undefined,
    tool_binding_len: usize = 0,

    pub fn toolName(self: *const PermissionSummary) []const u8 {
        return self.tool_name[0..self.tool_name_len];
    }

    pub fn toolBinding(self: *const PermissionSummary) []const u8 {
        return self.tool_binding[0..self.tool_binding_len];
    }

    pub fn requestId(self: *const PermissionSummary) []const u8 {
        return self.request_id[0..self.request_id_len];
    }

    pub fn matchedRuleId(self: *const PermissionSummary) []const u8 {
        return self.matched_rule_id[0..self.matched_rule_id_len];
    }
};

pub const FileReferencePositionView = struct {
    line: u32,
    column: u32,
};

pub const FileReferenceRangeView = struct {
    start: FileReferencePositionView,
    end: FileReferencePositionView,
};

pub const FileReferenceLocatorKind = enum { workspace_path, absolute_path, uri };

pub const FileReferenceView = struct {
    id: []u8,
    title: []u8,
    display_path: []u8,
    kind: []u8,
    locator_kind: FileReferenceLocatorKind,
    locator: []u8,
    range: ?FileReferenceRangeView = null,
};

pub const ToolView = struct {
    /// One-way correlation key for Agent event correlation. The raw tool ID is
    /// never retained in product history.
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

pub const UsageView = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cache_read_input_tokens: u64 = 0,
    cache_creation_input_tokens: u64 = 0,
};

pub const TerminalPublication = enum(u8) { open, publishing, published };
pub const EventProjectionFailure = enum {
    consumer_rejected,
    dependency_contract_failure,
};
pub const AgentHandoffState = enum(u8) { queued, starting, running, finishing };

pub const RunTerminationDispatch = enum {
    pending,
    requested,
    already_requested,
    already_finishing,
    already_terminal,
    stale_run,
    session_closing,
};

pub const PendingInterruption = enum(u8) {
    none,
    user_cancel,
    timeout,
    session_close,
    app_shutdown,
};

pub const TerminalPayload = struct {
    phase: RunPhase,
    outcome: RunOutcome,
    cause: ?RunCause,
    session_disposition_at_completion: agent.SessionDisposition,
    diagnostic_len: usize = 0,
    diagnostic_truncated: bool = false,
    diagnostic_redacted: bool = false,
};

pub const CompactTerminalPayload = struct {
    phase: CompactPhase,
    cause: ?CompactCause,
    before_context_tokens: u64,
    after_context_tokens: u64,
    usage: UsageView,
    session_disposition_at_completion: agent.SessionDisposition,
    diagnostic_len: usize = 0,
    diagnostic_truncated: bool = false,
    diagnostic_redacted: bool = false,
};

pub const RunInputRecord = union(enum) {
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

/// Immutable checkpoint description facts captured before executor handoff.
/// Workers must not recover them by traversing mutable Task durable history.
pub const CheckpointExportContext = struct {
    task_id: u64,
    binding_epoch: u64,
    terminal_kind: std.meta.Tag(checkpoint_record.Terminal),
    terminal_id: u64,
    last_run_id: u64,
    last_compact_id: u64,
    model: []const u8,
};

pub const AutomaticTitleState = enum(u8) {
    none,
    pending,
    running,
    ready,
    settled,
};

pub const AutomaticTitle = struct {
    state: std.atomic.Value(AutomaticTitleState) = .init(.none),
    cancel_requested: std.atomic.Value(bool) = .init(false),
    provisional_applied: bool = false,
    user_overrode: bool = false,
    generated: bool = false,
    generated_redacted: bool = false,
    result_len: usize = 0,
    result: [automatic_title_result_capacity]u8 = undefined,
};

pub const CheckpointAnchor = enum {
    none,
    available,
    blob_missing,
    blob_mismatch,
};

pub const CheckpointAttempt = enum {
    none,
    export_failed,
    describe_failed,
    cancelled,
    resource_limit,
    io_failed,
    outcome_unknown,
    dependency_contract,
};

pub const CheckpointPostprocessState = enum(u8) {
    none,
    exporting,
    failure_ready,
    candidate_ready,
    store_outcome_unknown,
    settled,
};

pub const CheckpointCandidate = struct {
    record: checkpoint_record.Record,
    metrics: struct {
        chunk_count: u64,
        export_duration_ns: i128,
    },
};

pub const CheckpointPostprocessPayload = union(enum) {
    none,
    failure: CheckpointAttempt,
    candidate: CheckpointCandidate,
    store_outcome_unknown: CheckpointCandidate,
};

pub const CheckpointPostprocess = struct {
    state: std.atomic.Value(CheckpointPostprocessState) = .init(.none),
    cancelled: std.atomic.Value(bool) = .init(false),
    payload: CheckpointPostprocessPayload = .none,
};

pub const RunRecord = struct {
    id: u64,
    generation: u64,
    execution_generation: u64,
    execution_provider: Provider,
    execution_model: []const u8,
    execution_model_owned: bool = false,
    input: RunInputRecord,
    assistant: TrackedText = .{},
    assistant_redacted: bool = false,
    /// Host-only buffers for the currently open segment and a max-token
    /// continuation group. Only a closed commentary/final/partial group is
    /// appended to `assistant` and becomes durable.
    output_segment: TrackedText = .{},
    output_continued: TrackedText = .{},
    open_output_segment: ?OpenOutputSegment = null,
    output_continued_group: ?u32 = null,
    output_retry_group: ?u32 = null,
    next_output_segment_index: u64 = 0,
    output_segment_protocol_seen: bool = false,
    output_segment_redacted: bool = false,
    output_continued_redacted: bool = false,
    /// Product classification over the sanitized canonical assistant text.
    /// Bytes before `assistant_output_start` are aggregated commentary; the
    /// suffix is the final or partial answer.
    assistant_output_kind: ?AssistantOutputKind = null,
    assistant_output_start: ?usize = null,
    active_phase: RunPhase = .queued,
    tools: []?ToolView,
    usage: UsageView = .{},
    status_text: []u8,
    /// Latest monotonic Agent execution observation. These fields are
    /// runtime-only: an interrupted process never persists in-flight state.
    agent_phase: ?agent.RunStatePhase = null,
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
    worker_reference_held: std.atomic.Value(bool) = .init(false),
    agent_handoff: std.atomic.Value(AgentHandoffState) = .init(.queued),
    pending_termination: std.atomic.Value(PendingInterruption) = .init(.none),
    run_control: agent.RunControl = undefined,
    checkpoint_export_context: CheckpointExportContext = undefined,
    checkpoint: CheckpointPostprocess = .{},
    automatic_title: AutomaticTitle = .{},
};

pub const CompactRecord = struct {
    id: u64,
    after_run_id: u64,
    agent_handoff: std.atomic.Value(AgentHandoffState) = .init(.queued),
    pending_interruption: std.atomic.Value(PendingInterruption) = .init(.none),
    terminal_publication: std.atomic.Value(TerminalPublication) = .init(.open),
    terminal_payload: CompactTerminalPayload = undefined,
    terminal_observed: bool = false,
    terminal_diagnostic: []u8,
    redaction_secret: []const u8 = &.{},
    worker_reference_held: std.atomic.Value(bool) = .init(false),
    checkpoint_export_context: CheckpointExportContext = undefined,
    checkpoint: CheckpointPostprocess = .{},
};

pub const UiRecordKind = enum { permission };

pub const UiRecordState = enum {
    allowed_once,
    // Persisted history wire name remains `allowed_always`; the current product
    // choice exposed to users is `allow_session`.
    allowed_always,
    denied,
    denied_session,
    cancelled,
};

pub const UiRecord = struct {
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

    pub fn detailSlice(self: *const UiRecord) []const u8 {
        return self.detail[0..self.detail_len];
    }
};

pub const DurableTaskRecord = struct {
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

pub const RuntimeAttachment = task_attachment.State;

pub const Task = struct {
    durable: DurableTaskRecord,
    runtime: RuntimeAttachment,
    deletion: task_deletion.State = .idle,
};

pub const ProductTerminalFacts = struct {
    phase: RunPhase,
    outcome: RunOutcome,
    cause: ?RunCause,
    session_disposition_at_completion: agent.SessionDisposition,
};

pub fn terminalPayload(run: *const RunRecord) ?*const TerminalPayload {
    while (true) switch (run.terminal_publication.load(.acquire)) {
        .open => return null,
        .publishing => std.atomic.spinLoopHint(),
        .published => return &run.terminal_payload,
    };
}

pub fn productTerminalPayload(run: *const RunRecord) ?*const TerminalPayload {
    if (!run.event_stream_finalized) return null;
    return terminalPayload(run);
}

pub fn productTerminalFacts(run: *const RunRecord) ?ProductTerminalFacts {
    const terminal = productTerminalPayload(run) orelse return null;
    if (run.event_projection_failure) |failure| return switch (failure) {
        .consumer_rejected => .{
            .phase = .failed,
            .outcome = .failed,
            .cause = .event_pipeline_failure,
            .session_disposition_at_completion = terminal.session_disposition_at_completion,
        },
        .dependency_contract_failure => .{
            .phase = .failed,
            .outcome = .dependency_contract_failure,
            .cause = .dependency_contract_failure,
            .session_disposition_at_completion = terminal.session_disposition_at_completion,
        },
    };
    return .{
        .phase = terminal.phase,
        .outcome = terminal.outcome,
        .cause = terminal.cause,
        .session_disposition_at_completion = terminal.session_disposition_at_completion,
    };
}

pub fn runPhase(run: *const RunRecord) RunPhase {
    return if (productTerminalFacts(run)) |terminal| terminal.phase else run.active_phase;
}

pub fn setActivePhase(run: *RunRecord, phase: RunPhase) bool {
    std.debug.assert(!isTerminalPhase(phase));
    if (run.terminal_publication.load(.acquire) != .open) return false;
    run.active_phase = phase;
    return run.terminal_publication.load(.acquire) == .open;
}

pub fn compactTerminalPayload(
    compact: *const CompactRecord,
) ?*const CompactTerminalPayload {
    while (true) switch (compact.terminal_publication.load(.acquire)) {
        .open => return null,
        .publishing => std.atomic.spinLoopHint(),
        .published => return &compact.terminal_payload,
    };
}

pub fn activeCompactPhase(compact: *const CompactRecord) CompactPhase {
    if (compact.pending_interruption.load(.acquire) != .none) return .stopping;
    return switch (compact.agent_handoff.load(.acquire)) {
        .queued, .starting => .queued,
        .running, .finishing => .compacting,
    };
}

pub fn isTerminalPhase(phase: RunPhase) bool {
    return switch (phase) {
        .queued, .running, .waiting_ui, .stopping => false,
        .completed, .stopped, .cancelled, .interrupted, .failed => true,
    };
}

pub fn isTerminalCompactPhase(phase: CompactPhase) bool {
    return switch (phase) {
        .queued, .compacting, .stopping => false,
        .compacted, .no_change, .degraded, .aborted, .interrupted, .failed => true,
    };
}

pub fn findRun(entries: []?RunRecord, run_id: u64) ?*RunRecord {
    if (run_id == 0) return null;
    for (entries) |*entry| if (entry.*) |*run| if (run.id == run_id) return run;
    return null;
}

pub fn findCompact(entries: []?CompactRecord, operation_id: u64) ?*CompactRecord {
    for (entries) |*entry| {
        const compact = &(entry.* orelse continue);
        if (compact.id == operation_id) return compact;
    }
    return null;
}

pub fn hasUnfinalizedTerminalEvents(task: *const Task) bool {
    for (task.durable.runs) |*entry| {
        const run = &(entry.* orelse continue);
        if (!run.event_stream_finalized and terminalPayload(run) != null) return true;
    }
    return false;
}

pub fn markTerminalRunsBeforeEventDrain(task: *Task) bool {
    var changed = false;
    for (task.durable.runs) |*entry| {
        const run = &(entry.* orelse continue);
        if (run.event_stream_finalized or run.terminal_event_drain_marked) continue;
        if (terminalPayload(run) == null) continue;
        run.terminal_event_drain_marked = true;
        changed = true;
    }
    return changed;
}

pub fn finalizeMarkedTerminalRunsAfterEventDrain(task: *Task) bool {
    var changed = false;
    for (task.durable.runs) |*entry| {
        const run = &(entry.* orelse continue);
        if (!run.terminal_event_drain_marked) continue;
        std.debug.assert(terminalPayload(run) != null);
        run.terminal_event_drain_marked = false;
        if (run.open_output_segment != null or
            run.output_continued_group != null or
            run.output_segment.list.items.len != 0 or
            run.output_continued.list.items.len != 0)
        {
            if (run.event_projection_failure == null)
                run.event_projection_failure = .dependency_contract_failure;
            run.open_output_segment = null;
            run.output_continued_group = null;
            run.output_retry_group = null;
            clearTrackedText(&run.output_segment);
            clearTrackedText(&run.output_continued);
            run.output_segment_redacted = false;
            run.output_continued_redacted = false;
        }
        run.output_retry_group = null;
        run.event_stream_finalized = true;
        run.assistant.committed_len = run.assistant.list.items.len;
        changed = true;
    }
    return changed;
}

pub fn recordEventProjectionFailure(run: *RunRecord) bool {
    if (run.event_projection_failure != null) return false;
    run.event_projection_failure = .consumer_rejected;
    return true;
}

pub fn recordDependencyContractFailure(run: *RunRecord) bool {
    if (run.event_projection_failure != null) return false;
    run.event_projection_failure = .dependency_contract_failure;
    return true;
}

pub const EventProjectionError = std.mem.Allocator.Error || error{
    ProjectionCapacity,
    ToolCapacity,
};
pub const EventApplyError = EventProjectionError || error{
    NoSuchRun,
    InvalidOutputSegment,
};

pub const TextProjectionResult = struct {
    truncated: bool,
    redacted: bool,
};

/// Callback-scoped access to the composition-owned bounded projection arena and
/// credential sanitizer. Task state owns event semantics; this capability only
/// performs memory mechanics and never retains Task, Run, or Agent values.
pub const EventProjection = struct {
    context: *anyopaque,
    max_assistant_message_bytes: usize,
    max_tool_field_bytes: usize,
    append_assistant_fn: *const fn (
        context: *anyopaque,
        target: *TrackedText,
        suffix: []const u8,
        max: usize,
        credential: []const u8,
    ) EventProjectionError!bool,
    replace_text_fn: *const fn (
        context: *anyopaque,
        target: *[]u8,
        value: []const u8,
        max: usize,
        credential: []const u8,
    ) EventProjectionError!TextProjectionResult,
    find_or_create_tool_fn: *const fn (
        context: *anyopaque,
        run: *RunRecord,
        id: []const u8,
        name: []const u8,
        input: []const u8,
    ) EventProjectionError!*ToolView,
    replace_file_references_fn: *const fn (
        context: *anyopaque,
        tool: *ToolView,
        envelope: *const agent.OwnedCoreEvent,
        credential: []const u8,
        task_id: u64,
        run_generation: u64,
    ) EventProjectionError!void,

    fn appendAssistant(
        self: EventProjection,
        target: *TrackedText,
        suffix: []const u8,
        credential: []const u8,
    ) EventProjectionError!bool {
        return self.append_assistant_fn(
            self.context,
            target,
            suffix,
            self.max_assistant_message_bytes,
            credential,
        );
    }

    fn replaceText(
        self: EventProjection,
        target: *[]u8,
        value: []const u8,
        credential: []const u8,
    ) EventProjectionError!TextProjectionResult {
        return self.replace_text_fn(
            self.context,
            target,
            value,
            self.max_tool_field_bytes,
            credential,
        );
    }

    fn findOrCreateTool(
        self: EventProjection,
        run: *RunRecord,
        id: []const u8,
        name: []const u8,
        input: []const u8,
    ) EventProjectionError!*ToolView {
        return self.find_or_create_tool_fn(self.context, run, id, name, input);
    }

    fn replaceFileReferences(
        self: EventProjection,
        tool: *ToolView,
        envelope: *const agent.OwnedCoreEvent,
        credential: []const u8,
        task_id: u64,
        run_generation: u64,
    ) EventProjectionError!void {
        return self.replace_file_references_fn(
            self.context,
            tool,
            envelope,
            credential,
            task_id,
            run_generation,
        );
    }
};

pub const EventApplication = union(enum) {
    unknown,
    late_terminal,
    unchanged,
    applied: struct {
        durable_boundary: bool,
    },
};

/// Applies one canonical Agent event to the Task aggregate. Event pumping,
/// late-event diagnostics, durable commit, and revision publication remain at
/// the composition boundary and are selected from the returned outcome.
pub fn applyEvent(
    task: *Task,
    envelope: *const agent.OwnedCoreEvent,
    projection: EventProjection,
) EventApplyError!EventApplication {
    const run = findRun(task.durable.runs, envelope.run_id) orelse
        return error.NoSuchRun;
    if (run.event_stream_finalized) return .late_terminal;
    const event = switch (envelope.event.value) {
        .unknown => return .unknown,
        .known => |known| known,
    };
    var durable_boundary = false;
    switch (event) {
        .thinking_chunk => {
            if (std.mem.eql(u8, run.status_text, "Thinking")) return .unchanged;
            _ = try projection.replaceText(
                &run.status_text,
                "Thinking",
                run.redaction_secret,
            );
        },
        .text_chunk => |text| {
            if (run.output_segment_protocol_seen) {
                const open = &(run.open_output_segment orelse
                    return error.InvalidOutputSegment);
                open.bytes = std.math.add(
                    u64,
                    open.bytes,
                    std.math.cast(u64, text.len) orelse
                        return error.InvalidOutputSegment,
                ) catch return error.InvalidOutputSegment;
                if (try projection.appendAssistant(
                    &run.output_segment,
                    text,
                    run.redaction_secret,
                )) run.output_segment_redacted = true;
            } else if (builtin.is_test) {
                // Legacy fixtures exercise unrelated event behavior without
                // constructing the output framing now guaranteed by the
                // canonical macOS AgentCore artifact.
                if (try projection.appendAssistant(
                    &run.assistant,
                    text,
                    run.redaction_secret,
                )) run.assistant_redacted = true;
            } else return error.InvalidOutputSegment;
            if (!std.mem.eql(u8, run.status_text, "Writing response"))
                _ = try projection.replaceText(
                    &run.status_text,
                    "Writing response",
                    run.redaction_secret,
                );
        },
        .tool_start => |tool_event| {
            const tool = try projection.findOrCreateTool(
                run,
                tool_event.id,
                tool_event.name,
                tool_event.input,
            );
            tool.state = .running;
            _ = try projection.replaceText(
                &run.status_text,
                "Executing tools",
                run.redaction_secret,
            );
        },
        .tool_progress => |progress| {
            const tool = findTool(run.tools, progress.id) orelse
                return error.ToolCapacity;
            const projected = try projection.replaceText(
                &tool.progress,
                progress.text,
                run.redaction_secret,
            );
            tool.progress_truncated = projected.truncated;
            tool.redacted = tool.redacted or projected.redacted;
        },
        .progress => {
            _ = try projection.replaceText(
                &run.status_text,
                "Executing tools",
                run.redaction_secret,
            );
        },
        .tool_result => |result| {
            const tool = try projection.findOrCreateTool(
                run,
                result.id,
                result.name,
                result.input,
            );
            const input = try projection.replaceText(
                &tool.input,
                result.input,
                run.redaction_secret,
            );
            const content = try projection.replaceText(
                &tool.content,
                result.content,
                run.redaction_secret,
            );
            tool.input_truncated = input.truncated;
            tool.content_truncated = content.truncated;
            tool.redacted = tool.redacted or input.redacted or content.redacted;
            tool.is_error = result.is_error;
            tool.elapsed_ms = result.elapsed_ms;
            tool.state = if (result.is_error) .failed else .completed;
            try projection.replaceFileReferences(
                tool,
                envelope,
                run.redaction_secret,
                task.durable.id,
                run.generation,
            );
            durable_boundary = true;
        },
        .usage => |usage| {
            run.usage.input_tokens = try addU64(run.usage.input_tokens, usage.input_tokens);
            run.usage.output_tokens = try addU64(run.usage.output_tokens, usage.output_tokens);
            run.usage.cache_read_input_tokens = try addU64(
                run.usage.cache_read_input_tokens,
                usage.cache_read_input_tokens,
            );
            run.usage.cache_creation_input_tokens = try addU64(
                run.usage.cache_creation_input_tokens,
                usage.cache_creation_input_tokens,
            );
        },
        .context_warning => |warning| {
            _ = try projection.replaceText(
                &run.status_text,
                warning.level,
                run.redaction_secret,
            );
        },
        .auto_compact => {
            _ = try projection.replaceText(
                &run.status_text,
                "Context compacted",
                run.redaction_secret,
            );
        },
        .retry_notice => {
            _ = try projection.replaceText(
                &run.status_text,
                "Retrying provider",
                run.redaction_secret,
            );
        },
        .run_state => |state| {
            if (state.run_id != run.id) {
                run.agent_observation_degraded = true;
                return .unchanged;
            }
            if (run.agent_transition_seq) |last|
                if (state.transition_seq <= last) return .unchanged;
            run.agent_transition_seq = state.transition_seq;
            run.agent_phase = state.phase;
            run.agent_turn = state.turn;
            run.agent_tool_calls = state.tool_calls;
            run.agent_in_flight_tools = std.math.cast(u32, state.in_flight_tools.len) orelse {
                run.agent_observation_degraded = true;
                return .unchanged;
            };
            _ = try projection.replaceText(
                &run.status_text,
                agentRunStateStatus(state.phase),
                run.redaction_secret,
            );
        },
        .permission_provenance => |provenance| {
            const summary = try permissionSummary(provenance);
            run.permission_provenance = summary;
            if (provenance.request_id) |request_id|
                if (findUiRecordByAgentRequestId(
                    task.durable.ui_history,
                    request_id,
                    run.id,
                )) |record| {
                    record.permission = summary;
                    durable_boundary = true;
                };
            const status = switch (provenance.decision) {
                .allow => "Permission allowed",
                .ask => "Permission requested",
                .deny => "Permission denied",
            };
            _ = try projection.replaceText(
                &run.status_text,
                status,
                run.redaction_secret,
            );
        },
        .output_segment_begin => |segment| {
            const continued_group_mismatch = if (run.output_continued_group) |group|
                group != segment.group
            else
                false;
            const retry_group_mismatch = if (run.output_retry_group) |group|
                group != segment.group
            else
                false;
            if (run.open_output_segment != null or
                run.output_segment.list.items.len != 0 or
                run.assistant_output_kind != null or
                run.next_output_segment_index > std.math.maxInt(u32) or
                @as(u64, segment.index) != run.next_output_segment_index or
                segment.turn == 0 or
                continued_group_mismatch or
                retry_group_mismatch)
                return error.InvalidOutputSegment;
            run.output_segment_protocol_seen = true;
            run.open_output_segment = .{
                .index = segment.index,
                .turn = segment.turn,
                .group = segment.group,
            };
        },
        .output_segment_end => |segment| {
            const open = run.open_output_segment orelse
                return error.InvalidOutputSegment;
            if (open.index != segment.index or
                open.turn != segment.turn or
                open.group != segment.group or
                open.bytes != segment.bytes)
                return error.InvalidOutputSegment;
            run.open_output_segment = null;
            run.next_output_segment_index = @as(u64, segment.index) + 1;
            switch (segment.disposition) {
                .discarded => {
                    clearTrackedText(&run.output_segment);
                    run.output_segment_redacted = false;
                    run.output_retry_group = segment.group;
                },
                .continued => {
                    if (run.output_continued_group) |group|
                        if (group != segment.group)
                            return error.InvalidOutputSegment;
                    if (run.output_segment.list.items.len != 0) {
                        run.output_continued_redacted = (try projection.appendAssistant(
                            &run.output_continued,
                            run.output_segment.list.items,
                            run.redaction_secret,
                        )) or run.output_segment_redacted or
                            run.output_continued_redacted;
                    }
                    clearTrackedText(&run.output_segment);
                    run.output_segment_redacted = false;
                    run.output_continued_group = segment.group;
                    run.output_retry_group = null;
                },
                .commentary, .final, .partial => {
                    const output_start = run.assistant.committed_len;
                    if (run.output_continued.list.items.len != 0) {
                        run.assistant_redacted = (try projection.appendAssistant(
                            &run.assistant,
                            run.output_continued.list.items,
                            run.redaction_secret,
                        )) or run.output_continued_redacted or
                            run.assistant_redacted;
                    }
                    if (run.output_segment.list.items.len != 0) {
                        run.assistant_redacted = (try projection.appendAssistant(
                            &run.assistant,
                            run.output_segment.list.items,
                            run.redaction_secret,
                        )) or run.output_segment_redacted or
                            run.assistant_redacted;
                    }
                    clearTrackedText(&run.output_continued);
                    clearTrackedText(&run.output_segment);
                    run.output_continued_group = null;
                    run.output_retry_group = null;
                    run.output_continued_redacted = false;
                    run.output_segment_redacted = false;
                    switch (segment.disposition) {
                        .commentary => {},
                        .final => {
                            run.assistant_output_kind = .final;
                            run.assistant_output_start = output_start;
                        },
                        .partial => {
                            run.assistant_output_kind = .partial;
                            run.assistant_output_start = output_start;
                        },
                        .continued, .discarded => unreachable,
                    }
                    durable_boundary = true;
                },
            }
        },
        .stream_done => {
            _ = try projection.replaceText(
                &run.status_text,
                "Finishing",
                run.redaction_secret,
            );
        },
    }
    return .{ .applied = .{ .durable_boundary = durable_boundary } };
}

fn clearTrackedText(target: *TrackedText) void {
    target.list.clearRetainingCapacity();
    target.committed_len = 0;
}

pub fn permissionSummary(value: agent.PermissionProvenance) EventProjectionError!PermissionSummary {
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

fn findUiRecordByAgentRequestId(
    entries: []?UiRecord,
    request_id: []const u8,
    run_id: u64,
) ?*UiRecord {
    for (entries) |*entry| {
        const record = &(entry.* orelse continue);
        if (record.run_id == run_id and
            std.mem.eql(
                u8,
                record.agent_request_id[0..record.agent_request_id_len],
                request_id,
            )) return record;
    }
    return null;
}

fn toolRouteDigest(id: []const u8) [tool_route_digest_bytes]u8 {
    var digest: [tool_route_digest_bytes]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(id, &digest, .{});
    return digest;
}

fn findTool(entries: []?ToolView, id: []const u8) ?*ToolView {
    const digest = toolRouteDigest(id);
    for (entries) |*entry| if (entry.*) |*tool|
        if (std.mem.eql(u8, &tool.route_digest, &digest)) return tool;
    return null;
}

fn addU64(left: u64, right: u64) EventProjectionError!u64 {
    return std.math.add(u64, left, right) catch error.ProjectionCapacity;
}

fn agentRunStateStatus(phase: agent.RunStatePhase) []const u8 {
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

test "event drain withholds terminal facts and assistant suffix until finalization" {
    var runs = [_]?RunRecord{.{
        .id = 7,
        .generation = 1,
        .execution_generation = 1,
        .execution_provider = .anthropic,
        .execution_model = "model",
        .input = .{ .text = .{ .value = @constCast("prompt") } },
        .tools = &.{},
        .status_text = @constCast("running"),
        .terminal_diagnostic = @constCast(""),
    }};
    var compacts: [0]?CompactRecord = .{};
    var ui_history: [0]?UiRecord = .{};
    var task = Task{
        .durable = .{
            .id = 3,
            .recent_order = 1,
            .execution_generation = 1,
            .execution_provider = .anthropic,
            .execution_model = @constCast("model"),
            .workspace_id = 2,
            .workspace_root = @constCast("root"),
            .title = @constCast("title"),
            .runs = &runs,
            .compacts = &compacts,
            .ui_history = &ui_history,
        },
        .runtime = .{},
    };
    const run = &task.durable.runs[0].?;
    run.assistant.list = .empty;
    try run.assistant.list.appendSlice(std.testing.allocator, "suffix");
    defer run.assistant.list.deinit(std.testing.allocator);
    run.terminal_payload = .{
        .phase = .completed,
        .outcome = .completed,
        .cause = null,
        .session_disposition_at_completion = .reusable,
    };
    run.terminal_publication.store(.published, .release);

    try std.testing.expect(productTerminalFacts(run) == null);
    try std.testing.expect(markTerminalRunsBeforeEventDrain(&task));
    try std.testing.expect(finalizeMarkedTerminalRunsAfterEventDrain(&task));
    try std.testing.expectEqual(@as(usize, 6), run.assistant.committed_len);
    try std.testing.expectEqual(RunOutcome.completed, productTerminalFacts(run).?.outcome);
}

test "event drain fails closed when an output segment remains unresolved" {
    var runs = [_]?RunRecord{.{
        .id = 7,
        .generation = 1,
        .execution_generation = 1,
        .execution_provider = .anthropic,
        .execution_model = "model",
        .input = .{ .text = .{ .value = @constCast("prompt") } },
        .tools = &.{},
        .status_text = @constCast("running"),
        .terminal_diagnostic = @constCast(""),
        .open_output_segment = .{ .index = 0, .turn = 1, .group = 0, .bytes = 5 },
        .output_segment_protocol_seen = true,
    }};
    var compacts: [0]?CompactRecord = .{};
    var ui_history: [0]?UiRecord = .{};
    var task = Task{
        .durable = .{
            .id = 3,
            .recent_order = 1,
            .execution_generation = 1,
            .execution_provider = .anthropic,
            .execution_model = @constCast("model"),
            .workspace_id = 2,
            .workspace_root = @constCast("root"),
            .title = @constCast("title"),
            .runs = &runs,
            .compacts = &compacts,
            .ui_history = &ui_history,
        },
        .runtime = .{},
    };
    const run = &task.durable.runs[0].?;
    try run.output_segment.list.appendSlice(std.testing.allocator, "draft");
    defer run.output_segment.list.deinit(std.testing.allocator);
    run.terminal_payload = .{
        .phase = .completed,
        .outcome = .completed,
        .cause = null,
        .session_disposition_at_completion = .reusable,
    };
    run.terminal_publication.store(.published, .release);

    try std.testing.expect(markTerminalRunsBeforeEventDrain(&task));
    try std.testing.expect(finalizeMarkedTerminalRunsAfterEventDrain(&task));
    try std.testing.expectEqual(
        EventProjectionFailure.dependency_contract_failure,
        run.event_projection_failure.?,
    );
    try std.testing.expectEqual(
        RunOutcome.dependency_contract_failure,
        productTerminalFacts(run).?.outcome,
    );
    try std.testing.expectEqual(@as(usize, 0), run.output_segment.list.items.len);
}
