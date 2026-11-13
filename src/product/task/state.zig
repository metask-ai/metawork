//! Task-owned aggregate state and product-visible Run/Compact lifecycle facts.
//! Executor jobs, Agent event pumping, persistence effects, revision publication,
//! and root snapshot orchestration remain composition responsibilities; Task
//! subtree derivation and encoding belong to the sibling view kernel.

const std = @import("std");
const agent = @import("metawork_agent");
const models_contract = @import("metawork_product_models_contract");
const checkpoint_record = @import("product_task_checkpoint_record");
const task_attachment = @import("product_task_attachment");
const task_deletion = @import("product_task_deletion");
const task_recovery = @import("product_task_recovery");
const worker_lease = @import("product_task_worker_lease");
const execution_credentials = @import("product_task_execution_binding").credential;

pub const automatic_title_result_capacity: usize = 512;
pub const ui_record_detail_capacity: usize = 512;
pub const permission_summary_field_capacity: usize = 128;
pub const tool_route_digest_bytes = agent.tool_route_digest_bytes;
pub const tool_product_id_capacity = "tool-".len + 20;
pub const file_change_route_digest_bytes = std.crypto.hash.sha2.Sha256.digest_length;
pub const file_change_product_id_capacity = "change-".len + (20 * 3) + 2;
pub const max_displayable_unix_ms: u64 = 8_640_000_000_000_000;

pub const Protocol = models_contract.Protocol;

/// Product-owned execution permission policy. These values deliberately do
/// not mirror every AgentCore PermissionMode: only profiles whose end-to-end
/// behavior MetaWork has admitted belong here.
pub const PermissionProfile = enum {
    approval_required,
    full_access,
};

/// User-facing approval choice, distinct from the Core execution profile.
pub const ApprovalMode = enum {
    manual,
    auto_review,
    full_access,

    pub fn profile(self: ApprovalMode) PermissionProfile {
        return if (self == .full_access) .full_access else .approval_required;
    }

    pub fn fromFacts(profile_value: PermissionProfile, reviewed: bool) ApprovalMode {
        return if (profile_value == .full_access) .full_access else if (reviewed) .auto_review else .manual;
    }
};

/// Whether an uncovered permission may suspend this Task for a local user
/// decision. The fact is immutable for the Task lifetime.
pub const PermissionInteraction = enum {
    interactive,
    noninteractive,
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

/// Mutable Run lifecycle before the write-once terminal publication. Terminal
/// phases are derived exclusively from `ProductTerminalFacts` and therefore
/// cannot be stored here.
pub const ActiveRunPhase = enum {
    queued,
    running,
    waiting_ui,
    stopping,
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
    event_payload_too_large,
    queue_capacity_failure,
    ui_pipeline_failure,
    permission_required,
    agent_failure,
    provider_failure,
    tool_failure,
    image_input_unsupported,
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

pub const ContextPressureSeverity = enum { warning, critical };

pub const ContextPressureObservation = struct {
    source_run_id: u64,
    current_tokens: u64,
    warning_threshold: u64,
    auto_compact_threshold: u64,
    blocking_limit: u64,
    severity: ContextPressureSeverity,
};

pub const AutoCompactObservation = struct {
    source_run_id: u64,
    dropped: u32,
    kept: u32,
    before_tokens: u64,
    after_tokens: u64,
};

/// Runtime-only facts for the currently attached Conversation. They survive
/// across Runs that reuse the same Session, but never cross attachment or
/// process boundaries and are not part of Task history persistence.
pub const ConversationObservation = struct {
    pressure: ?ContextPressureObservation = null,
    last_auto_compact: ?AutoCompactObservation = null,
};

pub const RetryObservation = struct {
    attempt: ?u32 = null,
    max: ?u32 = null,
    delay_ms: ?u64 = null,
};

pub const RunActivity = union(enum) {
    queued,
    starting,
    /// Stable wire name for the coarse model-processing phase.
    waiting_model,
    /// Recent model activity within the current generating scope.
    thinking,
    writing_response,
    executing_tools: struct { in_flight: ?u32 = null },
    retrying_provider: RetryObservation,
    waiting_user,
    compacting_context,
    finalizing,
    stopping,
};

const ModelActivity = enum { none, thinking, writing };

/// First local processing failure with bounded, payload-free event details.
pub const EventRejection = struct {
    event: ?agent.CoreEventKind,
    failure: EventApplyError,
    observed_segment: ?struct { index: u32, turn: u32, group: u32, bytes: u64 = 0 },
    text_bytes: ?usize,
    input_adoption: ?struct { id: u64, sequence: u32, turn: u32 },
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
    canonical_arguments_digest: [permission_summary_field_capacity]u8 = undefined,
    canonical_arguments_digest_len: usize = 0,

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

    pub fn canonicalArgumentsDigest(self: *const PermissionSummary) []const u8 {
        return self.canonical_arguments_digest[0..self.canonical_arguments_digest_len];
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

pub const PresentationAnchor = struct {
    after_output_count: u32,
    presentation_order: u64,
};

pub const FileReferenceView = struct {
    presentation_anchor: ?PresentationAnchor = null,
    generated_image: bool = false,
    generated_video: bool = false,
    id: []u8,
    title: []u8,
    display_path: []u8,
    kind: []u8,
    locator_kind: FileReferenceLocatorKind,
    locator: []u8,
    range: ?FileReferenceRangeView = null,

    pub fn generated(self: FileReferenceView) bool {
        return self.generated_image or self.generated_video;
    }
};

pub const GeneratedMedia = enum { image, video };

pub const FileChangeObservation = enum {
    collecting,
    complete,
    incomplete,
};

pub const FileChangeKind = enum {
    created,
    modified,
    deleted,
    moved,
};

pub const FileChangeStatus = enum {
    applied,
    partial,
};

pub const FileChangeArtifact = struct {
    run_generation: u64,
    change_order: u64,
    digest: [std.crypto.hash.sha2.Sha256.digest_length]u8,
    byte_size: u64,
};

pub const FileChangeView = struct {
    /// One-way correlation key over Agent event id plus record index. Raw Tool
    /// and event ids never enter Product history.
    route_digest: [file_change_route_digest_bytes]u8,
    id: []u8,
    order: u64,
    kind: FileChangeKind,
    status: FileChangeStatus,
    display_path: []u8,
    from_display_path: ?[]u8 = null,
    before_bytes: u64,
    after_bytes: u64,
    artifact: ?FileChangeArtifact = null,
    diff_complete: bool,
    redacted: bool = false,
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
    /// Runtime accounting; cold restoration derives this from trusted images.
    receipt_metadata: bool = false,
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

/// Owned safe observation, separate from the decision about the Run outcome.
pub const RunModelError = struct {
    pub const Source = models_contract.Source;
    detail: agent.ModelError,
    source: ?Source = null,
    host_redacted: bool = false,
    host_truncated: bool = false,
};

pub const TerminalPayload = struct {
    /// Applied by the main thread only when the terminal event drain completes.
    exclude_on_product_terminal: bool,
    phase: RunPhase,
    outcome: RunOutcome,
    cause: ?RunCause,
    session_disposition_at_completion: agent.SessionDisposition,
    diagnostic_len: usize = 0,
    diagnostic_truncated: bool = false,
    diagnostic_redacted: bool = false,
    model_error: ?*RunModelError = null,
    event_delivery_lost: bool = false,
};

pub const CompactTerminalPayload = struct {
    /// Applied by the main thread only when it observes this terminal fact.
    exclude_on_product_terminal: bool,
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
    multimodal: struct {
        text: ?[]u8,
        attachments: []AttachmentRecord,
        redacted: bool = false,
    },
};

pub const MultimodalAttachment = struct {
    resource_id: u64 = 0,
    kind: AttachmentKind,
    format: ?AttachmentFormat,
    display_name: []const u8,
    bytes: []const u8,
    reference: []const u8 = &.{},
    size_bytes: ?u64 = null,
    source_format: ?AttachmentFormat = null,
    workspace_reference_path: ?[]const u8 = null,
};

/// Borrowed command input. An accepted submission owns its slices separately.
pub const RunInput = union(enum) {
    text: []const u8,
    skill: struct {
        skill_id: []const u8,
        catalog_revision: []const u8,
        selection_revision: u64,
        argument_values: []const []const u8,
    },
    multimodal: struct { text: []const u8, attachments: []const MultimodalAttachment },
};

pub const Submission = struct {
    presentation_order: ?u64 = null,
    operation_id: [64]u8 = @splat(0),
    operation_id_len: u8,
    received_at_unix_ms: ?u64 = null,
    anchor_run_id: ?u64 = null,
    after_output_count: u32 = 0,

    pub fn operationId(self: *const Submission) []const u8 {
        return self.operation_id[0..self.operation_id_len];
    }
};

/// One owned execution buffer; never serialized or reconstructed from history.
pub const SkillSelection = struct {
    policy_key: []const u8,
    argument_shape: [32]u8,
};

pub const OwnedRunInput = struct {
    input: RunInput,
    bytes: []u8,
    arguments: []([]const u8) = &.{},
    attachments: []MultimodalAttachment = &.{},
    skill_selection: ?SkillSelection = null,

    pub fn clone(allocator: std.mem.Allocator, input: RunInput, budget: usize) error{ OutOfMemory, ProjectionCapacity }!OwnedRunInput {
        return cloneSelected(allocator, input, budget, null);
    }

    pub fn cloneSelected(allocator: std.mem.Allocator, input: RunInput, budget: usize, selection: ?SkillSelection) error{ OutOfMemory, ProjectionCapacity }!OwnedRunInput {
        var length: usize = 0;
        switch (input) {
            .text => |text| length = text.len,
            .skill => |skill| {
                length = std.math.add(usize, skill.skill_id.len, skill.catalog_revision.len) catch return error.ProjectionCapacity;
                for (skill.argument_values) |value| length = std.math.add(usize, length, value.len) catch return error.ProjectionCapacity;
            },
            .multimodal => |media| {
                length = media.text.len;
                for (media.attachments) |part| {
                    for ([_][]const u8{ part.display_name, part.bytes, part.reference, part.workspace_reference_path orelse "" }) |value|
                        length = std.math.add(usize, length, value.len) catch return error.ProjectionCapacity;
                }
            },
        }
        if (selection) |skill| length = std.math.add(usize, length, skill.policy_key.len) catch return error.ProjectionCapacity;
        if (length > budget) return error.ProjectionCapacity;
        const bytes = try allocator.alloc(u8, length);
        errdefer allocator.free(bytes);
        const arguments = try allocator.alloc([]const u8, if (input == .skill) input.skill.argument_values.len else 0);
        errdefer allocator.free(arguments);
        const attachments = try allocator.alloc(MultimodalAttachment, if (input == .multimodal) input.multimodal.attachments.len else 0);
        var offset: usize = 0;
        const owned: RunInput = switch (input) {
            .text => |text| .{ .text = copy(bytes, &offset, text) },
            .skill => |skill| blk: {
                const id = copy(bytes, &offset, skill.skill_id);
                const revision = copy(bytes, &offset, skill.catalog_revision);
                for (arguments, skill.argument_values) |*target, value| target.* = copy(bytes, &offset, value);
                break :blk .{ .skill = .{ .skill_id = id, .catalog_revision = revision, .selection_revision = skill.selection_revision, .argument_values = arguments } };
            },
            .multimodal => |media| blk: {
                const text = copy(bytes, &offset, media.text);
                for (attachments, media.attachments) |*target, part| {
                    target.* = part;
                    target.display_name = copy(bytes, &offset, part.display_name);
                    target.bytes = copy(bytes, &offset, part.bytes);
                    target.reference = copy(bytes, &offset, part.reference);
                    if (part.workspace_reference_path) |path|
                        target.workspace_reference_path = copy(bytes, &offset, path);
                }
                break :blk .{ .multimodal = .{ .text = text, .attachments = attachments } };
            },
        };
        return .{
            .input = owned,
            .bytes = bytes,
            .arguments = arguments,
            .attachments = attachments,
            .skill_selection = if (selection) |skill| .{
                .policy_key = copy(bytes, &offset, skill.policy_key),
                .argument_shape = skill.argument_shape,
            } else null,
        };
    }

    fn copy(bytes: []u8, offset: *usize, value: []const u8) []const u8 {
        const result = bytes[offset.*..][0..value.len];
        @memcpy(result, value);
        offset.* += value.len;
        return result;
    }

    pub fn deinit(self: *OwnedRunInput, allocator: std.mem.Allocator) void {
        std.crypto.secureZero(u8, self.bytes);
        allocator.free(self.bytes);
        allocator.free(self.arguments);
        allocator.free(self.attachments);
        self.* = undefined;
    }
};

pub const InputSubmission = struct {
    submission: Submission,
    input: RunInputRecord,
    payload: ?OwnedRunInput,
    retry_payload: ?OwnedRunInput = null,
    retried_as: ?Submission = null,
    force_new_run: bool = false,
    state: enum { waiting, failed, cancelled, interrupted } = .waiting,
    /// Only the stable reason of a failed submission is written to history.
    reason: ?SendInputReason = null,
    blocking_task_id: ?u64 = null,
    /// A required preparation is attempted once for this accepted message.
    preparation_attempted: bool = false,
};

// Fixed message metadata is charged to the shared projection budget. Its
// sixfold JSON allowance covers identities and adoption structure even when
// redaction leaves the safe text empty.
pub const additional_input_projection_bytes: usize = 224;

pub const AdditionalInputState = enum { pending, adopted, unadopted, unknown, transferred };

/// Safe history fields plus separately owned, runtime-only execution text.
pub const AdditionalInput = struct {
    id: u64,
    /// Reading position at submission, independent of Core adoption order.
    after_output_count: u32,
    operation_id: [64]u8 = @splat(0),
    operation_id_len: u8,
    text: []u8,
    redacted: bool,
    sequence: ?u32 = null,
    adopted_turn: ?u32 = null,
    order: ?u64 = null,
    state: AdditionalInputState = .pending,
    transferred_to_run_id: ?u64 = null,
    /// Execution-only owned text; never serialized or reconstructed from history.
    raw_text: ?[]u8 = null,
    /// Cancellation belongs to this accepted input, not later sends in the Run.
    continuation_cancel_reason: ?SendInputReason = null,
    submission: ?Submission = null,

    pub fn operationId(self: *const AdditionalInput) []const u8 {
        return self.operation_id[0..self.operation_id_len];
    }
};

pub const SendInputReason = enum {
    session_releasing,
    session_capacity,
    session_close_failed,
    binding_changed,
    binding_unavailable,
    models_catalog_loading,
    models_catalog_failed,
    metask_authorization_required,
    session_poisoned,
    checkpoint_unavailable,
    execution_rebind_required,
    task_unavailable,
    task_busy,
    workspace_unavailable,
    workspace_changed,
    workspace_removing,
    catalog_loading,
    catalog_unavailable,
    stale_catalog,
    skill_not_found,
    skill_unavailable,
    invalid_skill_arguments,
    missing_instruction,
    unsupported_input,
    unsupported_attachment,
    capacity_reached,
    shutting_down,
    run_changed,
    run_not_ready,
    run_stopping,
    too_late,
    invalid_input,
    resource_limit,
    checkpoint_budget_required,
    admission_failed,
    continuation_cancelled,
    approval_mode_change,
    combined_input_too_large,
    checkpoint_failed,
    schedule_failed,
};

pub const SendInputResult = struct {
    task_id: u64,
    operation_id: [64]u8 = @splat(0),
    operation_id_len: u8,
    outcome: enum { started, submitted, rejected, unknown } = .rejected,
    run_id: ?u64 = null,
    input_id: ?u64 = null,
    sequence: ?u32 = null,
    reason: ?SendInputReason = null,

    pub fn operationId(self: *const SendInputResult) []const u8 {
        return self.operation_id[0..self.operation_id_len];
    }
};

pub const InputAcceptance = struct {
    task_id: u64,
    operation_id: [64]u8 = @splat(0),
    operation_id_len: u8,
    outcome: enum { accepted, rejected } = .rejected,
    reason: ?SendInputReason = null,

    pub fn operationId(self: *const InputAcceptance) []const u8 {
        return self.operation_id[0..self.operation_id_len];
    }
};

pub const AttachmentKind = enum { image, file };
pub const AttachmentFormat = enum { png, jpeg, webp };
pub const AttachmentRecord = struct {
    /// Runtime-only ownership correlation with the attachment aggregate.
    resource_id: u64 = 0,
    kind: AttachmentKind,
    format: ?AttachmentFormat,
    display_name: []u8,
    size_bytes: u64,
    redacted: bool = false,
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
};

pub const CheckpointPostprocess = struct {
    state: std.atomic.Value(CheckpointPostprocessState) = .init(.none),
    cancelled: std.atomic.Value(bool) = .init(false),
    payload: CheckpointPostprocessPayload = .none,
    /// Later than the immutable execution terminal; published with readiness.
    session_disposition: ?agent.SessionDisposition = null,
    binding_epoch: u64 = 0,
    lease: ?worker_lease.WorkerLease = null,
};

/// Whether this durable Product operation is present in the recoverable
/// AgentCore Conversation represented by the latest committed checkpoint.
pub const ConversationCoverage = enum {
    /// The live attachment may still advance a checkpoint over this operation.
    pending,
    /// A committed checkpoint is known to contain this operation.
    covered,
    /// This operation remains visible in Product history but is not part of
    /// the Conversation restored from the latest committed checkpoint.
    excluded,
};

/// Ephemeral Run authority. The output context is Application-owned; it is
/// released only after the worker and canonical event stream are quiescent.
/// Candidate credential is also the Product projection scrub copy.
pub const OwnedImageExecution = struct {
    candidate: models_contract.OwnedMediaCandidate,
    transport: agent.CompletionTransport,
    output: agent.ImageGenerationOutput,
    output_owner: *anyopaque,
    release_output_fn: *const fn (*anyopaque) void,
    authorization: MediaCredentials = .{},

    pub fn enableCredentialRenewal(self: *OwnedImageExecution, allocator: std.mem.Allocator, io: std.Io, generation: u64) std.mem.Allocator.Error!void {
        try self.authorization.enable(allocator, io, self.candidate.input().bearer, generation);
    }

    pub fn input(self: *const OwnedImageExecution) agent.ImageGenerationRunInput {
        const candidate = self.candidate.input();
        return .{ .binding = .{
            .endpoint = candidate.endpoint,
            .source = candidate.selection.source_id,
            .model = candidate.selection.model_id,
            .credential = candidate.bearer,
            .credential_reader = self.authorization.reader(),
            .output = self.output,
        }, .transport = self.transport };
    }

    pub fn deinit(self: *OwnedImageExecution) void {
        self.release_output_fn(self.output_owner);
        self.authorization.deinit();
        self.candidate.deinit();
        self.* = undefined;
    }
};

pub const MediaCredentials = struct {
    generation: u64 = 0,
    source: ?*execution_credentials.Source = null,
    versions: std.ArrayList([]u8) = .empty,

    pub fn enable(self: *MediaCredentials, allocator: std.mem.Allocator, io: std.Io, bearer: []const u8, generation: u64) std.mem.Allocator.Error!void {
        std.debug.assert(self.source == null and generation != 0);
        self.source = try execution_credentials.Source.create(allocator, io, bearer);
        self.generation = generation;
    }

    fn reader(self: *const MediaCredentials) ?agent.ImageGenerationCredentialReader {
        return if (self.source) |source| .{ .context = source, .read_fn = readCredential } else null;
    }

    fn deinit(self: *MediaCredentials) void {
        if (self.source) |source| {
            for (self.versions.items) |value| {
                std.crypto.secureZero(u8, value);
                source.allocator.free(value);
            }
            self.versions.deinit(source.allocator);
            source.release();
        }
    }

    fn readCredential(context: *anyopaque, buffer: []u8) ?usize {
        const source: *execution_credentials.Source = @ptrCast(@alignCast(context));
        return (source.copyInto(buffer) catch return null).len;
    }
};

pub const OutputRecord = struct {
    id: [16]u8,
    /// Owned projection bytes; a redacted locator is never usable or persisted.
    locator: []u8,
    size_bytes: u64,
    sha256: [32]u8,
    redacted: bool = false,
};

pub const OwnedFileDelivery = struct {
    input: agent.FileDeliveryInput,
    release_fn: *const fn (*anyopaque) void,

    pub fn deinit(self: *OwnedFileDelivery) void {
        self.release_fn(self.input.context);
        self.* = undefined;
    }
};

pub const OwnedVideoExecution = struct {
    candidate: models_contract.OwnedMediaCandidate,
    transport: agent.CompletionTransport,
    output: agent.VideoGenerationOutput,
    release_output_fn: *const fn (*anyopaque) void,
    authorization: MediaCredentials = .{},

    pub fn input(self: *const OwnedVideoExecution) ?agent.VideoGenerationRunInput {
        const candidate = self.candidate.input();
        return .{
            .endpoint = candidate.endpoint,
            .source = candidate.selection.source_id,
            .model = candidate.selection.model_id,
            .credential = self.authorization.reader() orelse return null,
            .transport = self.transport,
            .output = self.output,
        };
    }

    pub fn deinit(self: *OwnedVideoExecution) void {
        self.release_output_fn(self.output.context);
        self.authorization.deinit();
        self.candidate.deinit();
        self.* = undefined;
    }
};

/// Worker control and title production exist only while a Run owns execution.
/// History restoration deliberately never allocates this structure.
pub const RunExecution = struct {
    run_control: agent.RunControl = undefined,
    checkpoint_export_context: CheckpointExportContext = undefined,
    automatic_title: AutomaticTitle = .{},
    /// Worker writes before terminal publication; the main loop consumes the
    /// bounded trusted tail before finalization, without borrowing Agent state.
    terminal_receipts: agent.TerminalReceipts = .{},
};

pub const RunRecord = struct {
    execution: ?*RunExecution = null,
    /// Projection invalidation only; never persisted or supplied to AgentCore.
    projection_content_version: u64 = 1,
    /// Never encoded in history or reconstructed from a checkpoint.
    image_execution: ?OwnedImageExecution = null,
    video_execution: ?OwnedVideoExecution = null,
    file_delivery: ?OwnedFileDelivery = null,

    /// Runtime-only monotonic admission time. Never restored from history.
    admitted_at_ms: ?u64 = null,
    /// Durable elapsed time frozen from the monotonic Run clock when Product
    /// first exposes the Run as terminal. Active Runs derive their current
    /// elapsed time from `admitted_at_ms`; older history and unavailable
    /// clocks stay null rather than receiving a reconstructed duration.
    elapsed_ms: ?u64 = null,
    /// Durable wall-clock observation captured when Product accepts the Run
    /// input. Older history and unavailable clocks stay null rather than
    /// receiving a reconstructed time.
    submitted_at_unix_ms: ?u64 = null,
    /// Durable wall-clock observation captured exactly once when Product
    /// exposes the Run as terminal. Older history and unavailable clocks stay
    /// null rather than receiving a reconstructed time.
    finished_at_unix_ms: ?u64 = null,
    id: u64,
    coverage: ConversationCoverage = .pending,
    generation: u64,
    execution_generation: u64,
    execution_protocol: Protocol,
    execution_model: []const u8,
    execution_model_owned: bool = false,
    permission_profile: PermissionProfile,
    permission_interaction: PermissionInteraction,
    input: RunInputRecord,
    submission: ?Submission = null,
    /// Actual safe history entries; active admission reserves the input capacity.
    additional_inputs: []?AdditionalInput = &.{},
    input_continuation_pending: bool = false,
    input_continuation_cancelled: bool = false,
    input_stop_requested: bool = false,
    input_continuation_attempted: bool = false,
    input_continuation_schedule_gate: bool = false,
    input_continuation_binding_epoch: u64 = 0,
    input_continuation_failure: ?SendInputReason = null,
    next_input_id: u64 = 1,
    /// Worker writes before publishing terminal; readers require that publication.
    completed_input_counts: ?agent.InputCounts = null,
    assistant: TrackedText = .{},
    assistant_redacted: bool = false,
    /// Cumulative byte ends for each non-empty, closed commentary group in
    /// `assistant`. The backing storage is reserved with the Run; only the
    /// prefix through `commentary_count` is meaningful.
    commentary_ends: []u64,
    commentary_count: usize = 0,
    /// Host-only buffers for the currently open segment and a max-token
    /// continuation group. Only a closed commentary/final/partial group is
    /// appended to `assistant` and becomes durable.
    output_segment: TrackedText = .{},
    output_continued: TrackedText = .{},
    output_segment_open: bool = false,
    output_continued_group: ?u32 = null,
    output_segment_redacted: bool = false,
    output_continued_redacted: bool = false,
    output_segment_incomplete: bool = false,
    output_continued_incomplete: bool = false,
    /// Product classification over the sanitized canonical assistant text.
    /// Commentary boundaries partition bytes before `assistant_output_start`;
    /// the suffix is the final or partial answer.
    assistant_output_kind: ?AssistantOutputKind = null,
    assistant_output_start: ?usize = null,
    active_phase: ActiveRunPhase = .queued,
    tools: []?ToolView,
    usage: UsageView = .{},
    /// Details enrich the Core retry phase; notices never establish a phase.
    retry_observation: RetryObservation = .{},
    /// Latest monotonic Agent execution observation. These fields are
    /// runtime-only: an interrupted process never persists in-flight state.
    agent_phase: ?agent.RunStatePhase = null,
    agent_transition_seq: ?u64 = null,
    agent_turn: u32 = 0,
    agent_tool_calls: u32 = 0,
    agent_in_flight_tools: u32 = 0,
    agent_observation_degraded: bool = false,
    /// Distinct from diagnostics about optional context/retry details.
    core_activity_degraded: bool = false,
    model_activity: ModelActivity = .none,
    permission_provenance: ?PermissionSummary = null,
    /// Null is reserved for history written before typed File Changes existed.
    file_change_observation: ?FileChangeObservation = null,
    file_changes: []?FileChangeView = &.{},
    outputs: [agent.max_file_deliveries_per_run]?OutputRecord = @splat(null),
    file_changes_known_loss: bool = false,
    pending_file_change_artifacts: u32 = 0,
    terminal_publication: std.atomic.Value(TerminalPublication) = .init(.open),
    terminal_payload: TerminalPayload = undefined,
    terminal_observed: bool = false,
    terminal_event_drain_marked: bool = false,
    event_stream_finalized: bool = false,
    event_projection_failure: ?EventProjectionFailure = null,
    /// Host failure is distinct from a bounded recording gap; the derived
    /// terminal outcome/cause uses the existing history contract.
    event_pipeline_failed: bool = false,
    first_event_rejection: ?EventRejection = null,
    event_rejection_reported: bool = false,
    terminal_diagnostic: []u8,
    /// Reserved before execution; publication only copies into this owned value.
    /// Restored history allocates it only when a model error is present.
    model_error_storage: ?*RunModelError = null,
    model_error_source: ?models_contract.Source = null,
    initial_credentials: [3][]const u8 = @splat(&.{}),
    /// Main-thread view of every version that may still reach this operation.
    /// Workers use initialRedactionSecrets and their owned request copies;
    /// mutable publication always crosses the main-thread sanitizer again.
    credential_views: std.ArrayList([]const u8) = .empty,
    next_activity_order: u64 = 1,
    agent_handoff: std.atomic.Value(AgentHandoffState) = .init(.queued),
    pending_termination: std.atomic.Value(PendingInterruption) = .init(.none),
    checkpoint: CheckpointPostprocess = .{},

    /// Main-thread observable changes only. Zero is a permanent exhausted
    /// identity, never an ABA restart; the projection writer fails closed.
    pub fn noteProjectionChange(self: *RunRecord) void {
        if (self.projection_content_version != 0)
            self.projection_content_version = std.math.add(u64, self.projection_content_version, 1) catch 0;
    }

    pub fn initialRedactionSecrets(self: *const RunRecord) [3][]const u8 {
        return self.initial_credentials;
    }

    pub fn initialCredentialViews(self: *const RunRecord) []const []const u8 {
        return self.initial_credentials[0..if (self.initial_credentials[2].len == 0) 2 else 3];
    }

    pub fn redactionSecrets(self: *const RunRecord) []const []const u8 {
        return if (self.credential_views.items.len != 0) self.credential_views.items else self.initialCredentialViews();
    }

    pub fn provisionalRedacted(self: *const RunRecord) bool {
        return self.output_continued_redacted or self.output_segment_redacted;
    }

    /// Counts canonical output slots, including empty classified slots and
    /// redaction placeholders. Pending unframed text reserves its slot even
    /// while a credential-sensitive suffix is withheld.
    pub fn outputPartCount(self: *const RunRecord) u32 {
        const tail = self.assistant_output_kind != null or
            self.output_continued.committed_len != 0 or
            self.output_segment.committed_len != 0 or self.provisionalRedacted() or
            (!self.output_segment_open and self.output_segment.list.items.len != 0);
        return @intCast(self.commentary_count + @intFromBool(tail));
    }
};

pub const CompactRecord = struct {
    id: u64,
    coverage: ConversationCoverage = .pending,
    after_run_id: u64,
    agent_handoff: std.atomic.Value(AgentHandoffState) = .init(.queued),
    pending_interruption: std.atomic.Value(PendingInterruption) = .init(.none),
    terminal_publication: std.atomic.Value(TerminalPublication) = .init(.open),
    terminal_payload: CompactTerminalPayload = undefined,
    terminal_observed: bool = false,
    event_drain_marked: bool = false,
    event_stream_finalized: bool = false,
    terminal_diagnostic: []u8,
    redaction_secret: []const u8 = &.{},
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
    pub const Review = task_attachment.PermissionReviewState.Audit;
    pub const ReviewOutcome = task_attachment.PermissionReviewState.Outcome;
    pub const ReviewCause = task_attachment.PermissionReviewState.Cause;
    request_id: u64,
    run_id: u64,
    order: u64 = 0,
    kind: UiRecordKind,
    state: UiRecordState,
    answered_by: ?enum { user, reviewer } = null,
    review: ?Review = null,
    review_reason: [ui_record_detail_capacity]u8 = undefined,
    review_reason_len: usize = 0,
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

    pub fn reviewReason(self: *const UiRecord) ?[]const u8 {
        return if (self.review_reason_len == 0) null else self.review_reason[0..self.review_reason_len];
    }
};

/// Owned, secret-free intent for the next Run; independent of the installed
/// execution and every historical Run. Absence preserves an unknown legacy
/// source instead of inventing a binding from today's global default.
pub const ModelIntent = struct {
    source_id: []u8,
    model_id: []u8,
    revision: u64,

    pub fn valid(model: models_contract.ModelRef, revision: u64) bool {
        if (revision == 0 or !model.valid()) return false;
        for ([_][]const u8{ model.source_id, model.model_id }) |value| {
            for (value) |byte| if (std.ascii.isControl(byte)) return false;
        }
        return true;
    }

    pub fn init(allocator: std.mem.Allocator, model: models_contract.ModelRef, revision: u64) (std.mem.Allocator.Error || error{InvalidModelIntent})!ModelIntent {
        if (!valid(model, revision)) return error.InvalidModelIntent;
        const source_id = try allocator.dupe(u8, model.source_id);
        errdefer allocator.free(source_id);
        return .{ .source_id = source_id, .model_id = try allocator.dupe(u8, model.model_id), .revision = revision };
    }

    pub fn modelRef(self: *const ModelIntent) models_contract.ModelRef {
        return .{ .source_id = self.source_id, .model_id = self.model_id };
    }

    pub fn deinit(self: *ModelIntent, allocator: std.mem.Allocator) void {
        allocator.free(self.source_id);
        allocator.free(self.model_id);
        self.* = undefined;
    }
};

test "Task model intent owns independent bounded identity and revision" {
    var source = "source-one".*;
    var model = "model-one".*;
    var intent = try ModelIntent.init(std.testing.allocator, .{ .source_id = &source, .model_id = &model }, 3);
    defer intent.deinit(std.testing.allocator);
    source[0] = 'X';
    model[0] = 'X';
    try std.testing.expectEqualStrings("source-one", intent.modelRef().source_id);
    try std.testing.expectEqualStrings("model-one", intent.modelRef().model_id);
    try std.testing.expectEqual(@as(u64, 3), intent.revision);
    const Checks = struct {
        fn create(allocator: std.mem.Allocator) !void {
            var owned = try ModelIntent.init(allocator, .{ .source_id = "source", .model_id = "model" }, 1);
            defer owned.deinit(allocator);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Checks.create, .{});
}

pub const DurableTaskRecord = struct {
    next_presentation_order: u64 = 1,

    id: u64,
    recent_order: u64,
    completion_seen_run_id: u64 = 0,
    execution_generation: u64,
    execution_protocol: Protocol,
    execution_model: []u8,
    model_intent: ?ModelIntent = null,
    permission_profile: PermissionProfile,
    permission_interaction: PermissionInteraction,
    binding_epoch: u64 = 1,
    approval_revision: u64 = 1,
    /// Persisted current Task delegation; Run authority is captured separately.
    permission_review_delegated: bool = false,
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
    pub fn takePresentationOrder(self: *DurableTaskRecord) error{ProjectionCapacity}!u64 {
        if (self.next_presentation_order == 0 or self.next_presentation_order == std.math.maxInt(u64)) return error.ProjectionCapacity;
        const order = self.next_presentation_order;
        self.next_presentation_order += 1;
        return order;
    }
};

pub const RuntimeAttachment = task_attachment.State;

pub const ApprovalFailureReason = @import("product_task_view_contract").ApprovalFailureReason;

pub const ApprovalRecoveryWait = union(enum) {
    session_close: u64,
    mcp_apply,
};

pub const ApprovalChange = struct {
    revision: u64,
    target: ApprovalMode,
    phase: enum {
        waiting,
        baseline_export,
        baseline_commit,
        mutation_export,
        mode_commit,
        recovering,
        outcome_unknown,
    } = .waiting,
    baseline_confirmed: bool = false,
    recovery_attempt_id: ?u64 = null,
    recovery_wait: ?struct { binding_epoch: u64, reason: ApprovalRecoveryWait } = null,
    unknown_history: ?struct { token: [32]u8, mode_commit: bool } = null,
    candidate: ?checkpoint_record.Record = null,
    failure: ?ApprovalFailureReason = null,
};

pub const ApprovalResult = struct {
    revision: u64,
    outcome: @import("product_task_view_contract").ApprovalOutcome,
    reason: ?ApprovalFailureReason = null,
};

pub const Task = struct {
    durable: DurableTaskRecord,
    runtime: RuntimeAttachment,
    /// One synchronous model-intent history overlay may own this Task at a time.
    model_intent_prepared: bool = false,
    /// Main-thread observation used to refresh action projections on worker wakes.
    observed_live_workers: bool = false,
    /// A bounded correlation receipt, never a deferred input.
    send_input_result: ?SendInputResult = null,
    input_submissions: std.ArrayList(InputSubmission) = .empty,
    conversation_observation: ConversationObservation = .{},
    /// Runtime-only first catalog binding; never persisted or used for recovery eligibility.
    initial_catalog_preparation: enum { uninitialized, loading, unavailable } = .uninitialized,
    /// Automatic creation can validate a personal selection before the Task has
    /// a workspace catalog. This version pair is only for first input acceptance.
    initial_personal_catalog: ?struct { revision: []u8, selection_revision: u64 } = null,
    /// One query ticket for the next Run, including a queued input or public
    /// run retry. No payload or lease is owned by this preparation marker.
    skill_preparation: ?struct { generation: u64, binding_epoch: u64 } = null,
    skills_unavailable: bool = false,
    approval_change: ?ApprovalChange = null,
    approval_result: ?ApprovalResult = null,
    /// One recovery step may retire its candidate plus the three finishRecovery
    /// records. Further checkpoint transitions wait for this batch to enqueue.
    pending_checkpoint_retirements: [4]?@FieldType(checkpoint_record.Record, "blob") = @splat(null),
    deletion: task_deletion.State = .idle,
    /// Original history frame of a Task restored by ignoring unknown fields.
    /// Such a Task is read-only and commits write this frame back unchanged.
    read_only_history: ?ReadOnlyHistory = null,

    pub const ReadOnlyHistory = struct {
        recent_order: u64,
        payload: []u8,
    };

    pub fn permissionReviewPhase(self: *const Task) task_attachment.PermissionReviewState.Phase {
        if (ApprovalMode.fromFacts(self.durable.permission_profile, self.durable.permission_review_delegated) != .auto_review) return .idle;
        return self.runtime.permission_review.phaseForRequest(self.runtime.active_run_id, self.runtime.pending_ui_request_id);
    }
};

/// A prepared Run may already appear in a history candidate while acceptance
/// still owns its input. Publish only the execution's copy of that message.
pub fn submissionHasExecution(task: *const Task, operation_id: []const u8) bool {
    for (task.durable.runs) |entry| if (entry) |run| {
        if (run.submission) |submission| if (std.mem.eql(u8, operation_id, submission.operationId())) return true;
        for (run.additional_inputs) |additional| if (additional) |record| {
            if (std.mem.eql(u8, operation_id, record.operationId())) return true;
        };
    };
    return false;
}

pub const ProductTerminalFacts = struct {
    phase: RunPhase,
    outcome: RunOutcome,
    cause: ?RunCause,
    diagnostic_disposition: TerminalDiagnosticDisposition,
    session_disposition_at_completion: agent.SessionDisposition,
};

pub const TerminalDiagnosticDisposition = enum {
    absent,
    withheld,
};

pub const RunProjectionFacts = struct {
    phase: RunPhase,
    activity: ?RunActivity,
    terminal: ?ProductTerminalFacts,
};

pub fn runElapsedMs(run: *const RunRecord, now_ms: ?u64) ?u64 {
    if (runProjectionFacts(run).terminal != null) return run.elapsed_ms;
    return sampledRunElapsedMs(run, now_ms);
}

pub fn freezeRunElapsedMs(run: *RunRecord, now_ms: ?u64) void {
    if (run.elapsed_ms != null) return;
    run.elapsed_ms = sampledRunElapsedMs(run, now_ms);
}

fn sampledRunElapsedMs(run: *const RunRecord, now_ms: ?u64) ?u64 {
    const started = run.admitted_at_ms orelse return null;
    const now = now_ms orelse return null;
    if (now < started) return null;
    return now - started;
}

pub const CompactProjectionFacts = struct {
    phase: CompactPhase,
    terminal: ?*const CompactTerminalPayload,
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
    const diagnostic_disposition: TerminalDiagnosticDisposition = if (terminal.diagnostic_len == 0 and
        !terminal.diagnostic_truncated and
        !terminal.diagnostic_redacted) .absent else .withheld;
    if (run.event_projection_failure == .dependency_contract_failure) return .{
        .phase = .failed,
        .outcome = .dependency_contract_failure,
        .cause = .dependency_contract_failure,
        .diagnostic_disposition = diagnostic_disposition,
        .session_disposition_at_completion = terminal.session_disposition_at_completion,
    };
    if (run.event_pipeline_failed) return .{
        .phase = .failed,
        .outcome = .failed,
        .cause = .event_pipeline_failure,
        .diagnostic_disposition = diagnostic_disposition,
        .session_disposition_at_completion = terminal.session_disposition_at_completion,
    };
    return .{
        .phase = terminal.phase,
        .outcome = terminal.outcome,
        .cause = terminal.cause,
        .diagnostic_disposition = diagnostic_disposition,
        .session_disposition_at_completion = terminal.session_disposition_at_completion,
    };
}

/// Called only after event drain and all file-change writes have settled.
/// Completion describes the observation stream, not whether the Run succeeded.
pub fn finalizedFileChangeObservation(run: *const RunRecord) FileChangeObservation {
    std.debug.assert(run.event_stream_finalized and run.pending_file_change_artifacts == 0);
    if (run.file_change_observation == .incomplete or run.file_changes_known_loss)
        return .incomplete;
    const terminal = productTerminalFacts(run).?;
    for (run.tools) |entry| {
        const tool = entry orelse continue;
        if (tool.state == .running) return .incomplete;
    }
    const intact = if (terminal.cause) |cause| switch (cause) {
        .provider_failure,
        .tool_failure,
        .image_input_unsupported,
        .stale_catalog,
        .skill_not_found,
        .invalid_skill_arguments,
        .skill_policy_violation,
        .skill_unavailable,
        => true,
        .resource_limit => terminal.phase == .stopped,
        .user_cancel,
        .timeout,
        .session_close,
        .app_shutdown,
        .permission_required,
        .event_pipeline_failure,
        .event_payload_too_large,
        .queue_capacity_failure,
        .ui_pipeline_failure,
        .agent_failure,
        .dependency_contract_failure,
        => false,
    } else terminal.phase == .completed or terminal.phase == .stopped;
    return if (intact) .complete else .incomplete;
}

pub fn runProjectionFacts(run: *const RunRecord) RunProjectionFacts {
    if (productTerminalFacts(run)) |terminal| return .{
        .phase = terminal.phase,
        .activity = null,
        .terminal = terminal,
    };
    if (terminalPayload(run) != null) return .{
        .phase = .running,
        .activity = .finalizing,
        .terminal = null,
    };
    return switch (run.active_phase) {
        .queued => .{ .phase = .queued, .activity = .queued, .terminal = null },
        .running => .{ .phase = .running, .activity = runningActivity(run), .terminal = null },
        .waiting_ui => .{ .phase = .waiting_ui, .activity = .waiting_user, .terminal = null },
        .stopping => .{ .phase = .stopping, .activity = .stopping, .terminal = null },
    };
}

pub fn runPhase(run: *const RunRecord) RunPhase {
    return runProjectionFacts(run).phase;
}

pub fn currentActivity(run: *const RunRecord) ?RunActivity {
    return runProjectionFacts(run).activity;
}

fn runningActivity(run: *const RunRecord) RunActivity {
    // Check confidence before consulting retained validation history.
    if (run.core_activity_degraded) return modelActivity(run);
    const phase = run.agent_phase orelse
        return if (run.assistant_output_kind != null) .finalizing else .starting;
    return switch (phase) {
        .starting => .starting,
        .generating => if (run.assistant_output_kind != null) .finalizing else modelActivity(run),
        .executing_tools => .{ .executing_tools = .{
            .in_flight = if (run.agent_in_flight_tools == 0) null else run.agent_in_flight_tools,
        } },
        .waiting_ui => .waiting_user,
        .retrying => .{ .retrying_provider = run.retry_observation },
        .compacting => .compacting_context,
        .finalizing, .completed, .failed, .aborted, .poisoned => .finalizing,
    };
}

fn modelActivity(run: *const RunRecord) RunActivity {
    return switch (run.model_activity) {
        .none => .waiting_model,
        .thinking => .thinking,
        .writing => .writing_response,
    };
}

fn observeModelActivity(run: *RunRecord, observation: ModelActivity) EventApplication {
    if (run.active_phase != .running or terminalPayload(run) != null or
        (!run.core_activity_degraded and run.agent_phase != .generating)) return .unchanged;
    const previous = currentActivity(run);
    run.model_activity = observation;
    return activityChange(run, previous);
}

fn activityChange(run: *const RunRecord, previous: ?RunActivity) EventApplication {
    return if (std.meta.eql(previous, currentActivity(run))) .unchanged else .{ .applied = .{ .durable_boundary = false } };
}

fn degradeCoreActivity(run: *RunRecord) EventApplication {
    const previous = currentActivity(run);
    run.agent_observation_degraded = true;
    run.core_activity_degraded = true;
    run.model_activity = .none;
    run.retry_observation = .{};
    // Keep the accepted identity/sequence/phase for all subsequent validation.
    return activityChange(run, previous);
}

fn checkCoreToolCount(run: *RunRecord) void {
    if (run.agent_phase == null or run.core_activity_degraded or
        run.event_projection_failure == .consumer_rejected) return;
    var running: usize = 0;
    for (run.tools) |entry| if (entry) |tool| {
        if (tool.state == .running) running += 1;
    };
    // Core emits the snapshot first. Compare only after the matching raw
    // start/result has updated its record, never at snapshot arrival.
    if (running != run.agent_in_flight_tools) _ = degradeCoreActivity(run);
}

pub fn setActivePhase(run: *RunRecord, phase: ActiveRunPhase) bool {
    if (run.terminal_publication.load(.acquire) != .open) return false;
    if (run.active_phase != phase) run.noteProjectionChange();
    if (phase != .running) run.model_activity = .none;
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

/// Compact terminal publication belongs to the worker. It becomes a Product
/// fact only after the main thread folds the terminal disposition and marks
/// the record observed in the same lifecycle reconciliation step.
pub fn compactProjectionFacts(compact: *const CompactRecord) CompactProjectionFacts {
    if (!compact.terminal_observed) return .{
        .phase = activeCompactPhase(compact),
        .terminal = null,
    };
    const terminal = compactTerminalPayload(compact) orelse unreachable;
    return .{
        .phase = terminal.phase,
        .terminal = terminal,
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
        const terminal = terminalPayload(run) orelse continue;
        if (terminal.event_delivery_lost) _ = recordEventProjectionFailure(run);
        run.model_activity = .none;
        run.terminal_event_drain_marked = true;
        changed = true;
    }
    return changed;
}

pub fn finalizeMarkedTerminalRunsAfterEventDrain(
    task: *Task,
    finished_at_ms: ?u64,
    finished_at_unix_ms: ?u64,
) bool {
    var changed = false;
    for (task.durable.runs) |*entry| {
        const run = &(entry.* orelse continue);
        if (!run.terminal_event_drain_marked) continue;
        std.debug.assert(terminalPayload(run) != null);
        if (run.execution) |execution| if (!execution.terminal_receipts.isEmpty()) continue;
        run.terminal_event_drain_marked = false;
        if (run.output_segment_open or
            run.output_continued_group != null or
            run.output_segment.list.items.len != 0 or
            run.output_continued.list.items.len != 0)
        {
            run.output_segment_open = false;
            run.output_continued_group = null;
            clearTrackedText(&run.output_segment);
            clearTrackedText(&run.output_continued);
            run.output_segment_redacted = false;
            run.output_continued_redacted = false;
        }
        freezeRunElapsedMs(run, finished_at_ms);
        if (terminalPayload(run).?.exclude_on_product_terminal and run.coverage == .pending)
            run.coverage = .excluded;
        run.noteProjectionChange();
        run.event_stream_finalized = true;
        if (run.finished_at_unix_ms == null)
            run.finished_at_unix_ms = if (finished_at_unix_ms) |value|
                if (value > 0 and value <= max_displayable_unix_ms) value else null
            else
                null;
        run.assistant.committed_len = run.assistant.list.items.len;
        if (run.assistant_output_start == null and run.commentary_count != 0) {
            std.debug.assert(run.commentary_ends.len >= run.commentary_count);
            run.commentary_ends[run.commentary_count - 1] =
                @intCast(run.assistant.committed_len);
        }
        if (run.file_change_observation == .collecting and
            run.pending_file_change_artifacts == 0)
        {
            run.file_change_observation = finalizedFileChangeObservation(run);
        }
        changed = true;
    }
    return changed;
}

pub fn recordEventProjectionFailure(run: *RunRecord) bool {
    if (run.event_projection_failure != null) return false;
    run.noteProjectionChange();
    run.event_projection_failure = .consumer_rejected;
    return true;
}

pub fn recordEventPipelineFailure(run: *RunRecord) bool {
    if (run.event_pipeline_failed) return false;
    run.noteProjectionChange();
    run.event_pipeline_failed = true;
    _ = recordEventProjectionFailure(run);
    return true;
}

pub const EventProjectionError = std.mem.Allocator.Error || error{
    ProjectionCapacity,
    ToolCapacity,
    InvalidDeliveryReceipt,
};
pub const EventApplyError = EventProjectionError || error{
    NoSuchRun,
    InvalidInputRecord,
    InvalidUsage,
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
    retain_generated_media_fn: *const fn (*anyopaque, *RunRecord, []const u8, []const u8, u64, GeneratedMedia) EventProjectionError!*ToolView,
    record_output_fn: ?*const fn (*anyopaque, *RunRecord, *const agent.FileDeliveryReceipt) EventProjectionError!void = null,
    max_assistant_message_bytes: usize,
    max_commentary_segments_per_run: usize,
    max_tool_field_bytes: usize,
    append_assistant_fn: *const fn (
        context: *anyopaque,
        target: *TrackedText,
        suffix: []const u8,
        max: usize,
        credential: []const u8,
    ) EventProjectionError!bool,
    append_group_fn: *const fn (
        context: *anyopaque,
        target: *TrackedText,
        first: []const u8,
        second: []const u8,
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
    record_file_changes_fn: *const fn (
        context: *anyopaque,
        run: *RunRecord,
        envelope: *const agent.OwnedCoreEvent,
        task_id: u64,
        workspace_root: []const u8,
    ) bool,

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

    /// Atomically appends an already-owned output group. The callback performs
    /// every fallible reserve before mutating `target`; Product state only
    /// clears the source buffers after this operation succeeds.
    fn appendGroup(
        self: EventProjection,
        target: *TrackedText,
        first: []const u8,
        second: []const u8,
        credential: []const u8,
    ) EventProjectionError!bool {
        return self.append_group_fn(
            self.context,
            target,
            first,
            second,
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

    fn recordFileChanges(
        self: EventProjection,
        run: *RunRecord,
        envelope: *const agent.OwnedCoreEvent,
        task_id: u64,
        workspace_root: []const u8,
    ) bool {
        return self.record_file_changes_fn(
            self.context,
            run,
            envelope,
            task_id,
            workspace_root,
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

fn outputBytes(run: *const RunRecord) EventProjectionError!usize {
    var total = std.math.add(
        usize,
        run.assistant.list.items.len,
        run.output_continued.list.items.len,
    ) catch return error.ProjectionCapacity;
    total = std.math.add(
        usize,
        total,
        run.output_segment.list.items.len,
    ) catch return error.ProjectionCapacity;
    return total;
}

/// Finalizes only retained bytes. Capacity failures never become Core violations.
fn commitPendingOutput(projection: EventProjection, run: *RunRecord, kind: enum { commentary, partial }, continued_only: bool) EventProjectionError!void {
    defer {
        clearTrackedText(&run.output_continued);
        run.output_continued_group = null;
        run.output_continued_redacted = false;
        run.output_continued_incomplete = false;
        if (!continued_only) {
            clearTrackedText(&run.output_segment);
            run.output_segment_redacted = false;
            run.output_segment_incomplete = false;
        }
    }
    const first = run.output_continued.list.items;
    const second: []const u8 = if (continued_only) &.{} else run.output_segment.list.items;
    if (run.output_continued_incomplete or (!continued_only and run.output_segment_incomplete)) _ = recordEventProjectionFailure(run);
    if (first.len == 0 and second.len == 0) return;
    if (kind == .commentary and (run.commentary_count >= projection.max_commentary_segments_per_run or run.commentary_count >= run.commentary_ends.len)) {
        _ = recordEventProjectionFailure(run);
        return;
    }
    const start = run.assistant.committed_len;
    const redacted = projection.appendGroup(&run.assistant, first, second, run.initial_credentials[0]) catch |err| {
        _ = recordEventProjectionFailure(run);
        if (err == error.ProjectionCapacity) return;
        return err;
    };
    // The sanitizer examined the whole closed part. A held prefix cannot
    // continue into the next product part; no raw suffix crosses that boundary.
    run.assistant.committed_len = run.assistant.list.items.len;
    run.assistant_redacted = run.assistant_redacted or redacted or run.output_continued_redacted or (!continued_only and run.output_segment_redacted);
    switch (kind) {
        .commentary => {
            run.commentary_ends[run.commentary_count] = @intCast(run.assistant.committed_len);
            run.commentary_count += 1;
        },
        .partial => {
            run.assistant_output_start = start;
            run.assistant_output_kind = .partial;
        },
    }
}

pub fn finishRetainedOutput(run: *RunRecord, projection: EventProjection) EventProjectionError!void {
    if (!run.output_segment_open and run.output_segment.list.items.len != 0)
        try commitPendingOutput(projection, run, .commentary, false);
    if (run.output_continued.list.items.len != 0 or run.output_segment.list.items.len != 0)
        try commitPendingOutput(projection, run, .partial, false);
}

fn appendNewOutput(
    projection: EventProjection,
    run: *RunRecord,
    target: *TrackedText,
    suffix: []const u8,
) EventProjectionError!bool {
    const used = try outputBytes(run);
    if (used > projection.max_assistant_message_bytes or
        suffix.len > projection.max_assistant_message_bytes - used)
        return error.ProjectionCapacity;
    return projection.appendAssistant(target, suffix, run.initial_credentials[0]);
}

/// Product history retains an image-read receipt, while Core keeps the full
/// multimodal result for the model. This grants no file/preview authority.
fn imageReadSummary(name: []const u8, is_error: bool, content: []const u8) ?[]const u8 {
    if (is_error or !std.mem.eql(u8, name, "Read")) return null;
    var scratch: [2048]u8 = undefined;
    var memory = std.heap.FixedBufferAllocator.init(&scratch);
    const value = std.json.parseFromSliceLeaky(struct {
        type: []const u8,
        media_type: []const u8,
        data: []const u8,
    }, memory.allocator(), content, .{ .allocate = .alloc_if_needed }) catch return null;
    if (!std.mem.eql(u8, value.type, "image") or value.data.len == 0) return null;
    const size = std.base64.standard.Decoder.calcSizeForSlice(value.data) catch return null;
    if (size > agent.multimodal_input_limits.max_image_raw_bytes) return null;
    const unpadded = std.mem.trimEnd(u8, value.data, "=");
    for (unpadded) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '+' and byte != '/') return null;
    inline for (.{ "png", "jpeg", "gif", "webp" }) |format| {
        if (std.mem.eql(u8, value.media_type, "image/" ++ format)) return "[Image read: image/" ++ format ++ "]";
    }
    return null;
}

test "image Read projection accepts the canonical full payload with fixed scratch and rejects unrelated content" {
    const prefix = "{\"type\":\"image\",\"media_type\":\"image/png\",\"data\":\"";
    const data_len = std.base64.standard.Encoder.calcSize(agent.multimodal_input_limits.max_image_raw_bytes);
    const content = try std.testing.allocator.alloc(u8, prefix.len + data_len + 2);
    defer std.testing.allocator.free(content);
    @memcpy(content[0..prefix.len], prefix);
    @memset(content[prefix.len..][0..data_len], 'A');
    @memcpy(content[content.len - 2 ..], "\"}");
    try std.testing.expectEqualStrings("[Image read: image/png]", imageReadSummary("Read", false, content).?);
    try std.testing.expect(imageReadSummary("Bash", false, content) == null);
    try std.testing.expect(imageReadSummary("Read", true, content) == null);
    content[prefix.len] = '!';
    try std.testing.expect(imageReadSummary("Read", false, content) == null);
    try std.testing.expect(imageReadSummary("Read", false, "{\"type\":\"image\",\"media_type\":\"image/png\",\"data\":\"AAAA\",\"unknown\":true}") == null);
    try std.testing.expect(imageReadSummary("Read", false, "ordinary text") == null);
}

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
    errdefer |failure| {
        if (failure != error.ProjectionCapacity and failure != error.ToolCapacity and
            run.first_event_rejection == null)
        {
            const known = switch (envelope.event.value) {
                .known => |event| event,
                .unknown => null,
            };
            run.first_event_rejection = .{
                .event = if (known) |event| std.meta.activeTag(event) else null,
                .failure = failure,
                .observed_segment = if (known) |event| switch (event) {
                    .output_segment_begin => |segment| .{ .index = segment.index, .turn = segment.turn, .group = segment.group },
                    .output_segment_end => |segment| .{ .index = segment.index, .turn = segment.turn, .group = segment.group, .bytes = segment.bytes },
                    else => null,
                } else null,
                .text_bytes = if (known) |event| switch (event) {
                    .text_chunk => |text| text.len,
                    else => null,
                } else null,
                .input_adoption = if (known) |event| switch (event) {
                    .input_adopted => |value| .{ .id = value.input_id, .sequence = value.sequence, .turn = value.turn },
                    else => null,
                } else null,
            };
        }
    }
    const event = switch (envelope.event.value) {
        .unknown => return if (envelope.delivered_file != null) error.InvalidDeliveryReceipt else .unknown,
        .known => |known| known,
    };
    if (envelope.delivered_file != null and event != .tool_result) return error.InvalidDeliveryReceipt;
    // The persisted output model has one classified response. Additional
    // legal Core output is a recording gap, never a second response/boundary.
    if (run.assistant_output_kind != null) switch (event) {
        .text_chunk, .output_segment_begin, .output_segment_end => {
            _ = recordEventProjectionFailure(run);
            return .{ .applied = .{ .durable_boundary = false } };
        },
        else => {},
    };
    var durable_boundary = false;
    switch (event) {
        .prompt_manifest, .model_error, .thinking_discarded => return .unchanged,
        .goal_updated => return .unknown,
        .input_adopted => |input| {
            var found = false;
            for (run.additional_inputs) |*entry| if (entry.*) |*record| {
                if (record.id != input.input_id) continue;
                if (record.adopted_turn != null or input.sequence == 0 or input.turn == 0 or
                    (record.sequence != null and record.sequence.? != input.sequence) or
                    run.next_activity_order == std.math.maxInt(u64)) return error.InvalidInputRecord;
                record.sequence = input.sequence;
                record.adopted_turn = input.turn;
                record.state = .adopted;
                record.order = run.next_activity_order;
                run.next_activity_order += 1;
                found = true;
                break;
            };
            if (!found) return error.InvalidInputRecord;
            durable_boundary = true;
        },
        .thinking_chunk => |text| return if (text.len == 0) .unchanged else observeModelActivity(run, .thinking),
        .text_chunk => |text| {
            if (run.output_segment_open) {
                if (!run.output_segment_incomplete and !run.output_continued_incomplete) {
                    const redacted = appendNewOutput(projection, run, &run.output_segment, text) catch |err| switch (err) {
                        error.ProjectionCapacity => lost: {
                            run.output_segment_incomplete = true;
                            break :lost false;
                        },
                        else => {
                            run.output_segment_incomplete = true;
                            return @as(EventApplyError!EventApplication, err);
                        },
                    };
                    run.output_segment_redacted = run.output_segment_redacted or redacted;
                }
            } else {
                if (run.output_continued_group != null) try commitPendingOutput(projection, run, .commentary, true);
                if (text.len != 0 and (run.commentary_count >= projection.max_commentary_segments_per_run or run.commentary_count >= run.commentary_ends.len)) return error.ProjectionCapacity;
                const redacted = appendNewOutput(projection, run, &run.output_segment, text) catch |err| {
                    run.output_segment_incomplete = true;
                    return @as(EventApplyError!EventApplication, err);
                };
                run.output_segment_redacted = run.output_segment_redacted or redacted;
            }
            if (text.len != 0) _ = observeModelActivity(run, .writing);
        },
        .tool_start => |tool_event| {
            const tool = try projection.findOrCreateTool(
                run,
                tool_event.id,
                tool_event.name,
                tool_event.input,
            );
            tool.state = .running;
            checkCoreToolCount(run);
        },
        .tool_progress => |progress| {
            const tool = findTool(run.tools, progress.id) orelse
                return error.ToolCapacity;
            const projected = try projection.replaceText(
                &tool.progress,
                progress.text,
                run.initial_credentials[0],
            );
            tool.progress_truncated = projected.truncated;
            tool.redacted = tool.redacted or projected.redacted;
        },
        // Core also emits progress before model requests. Generic notices must
        // not replace typed activity or in-flight counts.
        .progress => return .unchanged,
        .tool_result => |result| {
            if (envelope.delivered_file != null and
                (result.is_error or !std.mem.eql(u8, result.name, agent.FileDeliveryReceipt.tool_name)))
                return error.InvalidDeliveryReceipt;
            if (envelope.delivered_file) |*receipt| {
                const record = projection.record_output_fn orelse return error.InvalidDeliveryReceipt;
                try record(projection.context, run, receipt);
            }
            projectToolResultDetails(task.durable.id, run, envelope, projection) catch |failure| switch (failure) {
                error.ProjectionCapacity, error.ToolCapacity => _ = recordEventProjectionFailure(run),
                else => return @as(EventApplyError!EventApplication, failure),
            };
            checkCoreToolCount(run);
            durable_boundary = true;
        },
        .file_changes => {
            if (!projection.recordFileChanges(
                run,
                envelope,
                task.durable.id,
                task.durable.workspace_root,
            )) return .unchanged;
            durable_boundary = true;
        },
        .usage => |usage| {
            const input = try addU64(run.usage.input_tokens, usage.input_tokens);
            const output = try addU64(run.usage.output_tokens, usage.output_tokens);
            const cache_read = try addU64(run.usage.cache_read_input_tokens, usage.cache_read_input_tokens);
            const cache_creation = try addU64(run.usage.cache_creation_input_tokens, usage.cache_creation_input_tokens);
            run.usage = .{ .input_tokens = input, .output_tokens = output, .cache_read_input_tokens = cache_read, .cache_creation_input_tokens = cache_creation };
        },
        .context_warning => |warning| {
            if (!validContextWarning(warning)) {
                run.agent_observation_degraded = true;
                return .unchanged;
            }
            task.conversation_observation.pressure = .{
                .source_run_id = run.id,
                .current_tokens = warning.current_tokens,
                .warning_threshold = warning.warning_threshold,
                .auto_compact_threshold = warning.auto_compact_threshold,
                .blocking_limit = warning.blocking_limit,
                .severity = if (warning.current_tokens >= warning.auto_compact_threshold)
                    .critical
                else
                    .warning,
            };
        },
        .auto_compact => |compact| {
            if (!validAutoCompact(compact)) {
                run.agent_observation_degraded = true;
                return .unchanged;
            }
            task.conversation_observation.pressure = null;
            task.conversation_observation.last_auto_compact = .{
                .source_run_id = run.id,
                .dropped = compact.dropped,
                .kept = compact.kept,
                .before_tokens = compact.before_tokens,
                .after_tokens = compact.after_tokens,
            };
        },
        .retry_notice => |retry| {
            if (terminalPayload(run) != null or run.core_activity_degraded or run.agent_phase != .retrying) {
                run.agent_observation_degraded = true;
                return .unchanged;
            }
            const details_valid = retry.attempt != 0 and retry.max != 0 and
                retry.attempt <= retry.max;
            if (!details_valid) run.agent_observation_degraded = true;
            const details: RetryObservation = if (details_valid) .{
                .attempt = retry.attempt,
                .max = retry.max,
                .delay_ms = retry.delay_ms,
            } else .{};
            if (std.meta.eql(run.retry_observation, details)) return .unchanged;
            run.retry_observation = details;
        },
        .run_state => |state| {
            if (state.run_id != run.id) {
                return degradeCoreActivity(run);
            }
            if (run.agent_transition_seq) |last|
                if (state.transition_seq <= last) return .unchanged;
            if (!validRunStateTransition(run.agent_phase, state.phase)) {
                return degradeCoreActivity(run);
            }
            const in_flight = std.math.cast(u32, state.in_flight_tools.len) orelse {
                return degradeCoreActivity(run);
            };
            if (run.core_activity_degraded or state.phase != .generating or
                run.agent_phase != .generating or run.agent_turn != state.turn)
                run.model_activity = .none;
            if (state.phase != .retrying or run.agent_phase != .retrying or run.agent_turn != state.turn)
                run.retry_observation = .{};
            run.agent_transition_seq = state.transition_seq;
            run.agent_phase = state.phase;
            run.agent_turn = state.turn;
            run.agent_tool_calls = state.tool_calls;
            run.agent_in_flight_tools = in_flight;
            run.core_activity_degraded = false;
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
        },
        .output_segment_begin => |segment| {
            if (!run.output_segment_open and run.output_segment.list.items.len != 0)
                try commitPendingOutput(projection, run, .commentary, false);
            if (run.output_continued_group != null and run.output_continued_group.? != segment.group)
                try commitPendingOutput(projection, run, .commentary, true);
            if (run.output_segment_incomplete) _ = recordEventProjectionFailure(run);
            run.output_segment_incomplete = false;
            run.output_segment_open = true;
            run.model_activity = .none;
        },
        .output_segment_end => |segment| {
            if (!run.output_segment_open) {
                _ = recordEventProjectionFailure(run);
                clearTrackedText(&run.output_segment);
                run.output_segment_redacted = false;
                run.output_segment_incomplete = false;
                return .{ .applied = .{ .durable_boundary = true } };
            }
            var retention_failure: ?EventProjectionError = null;
            defer run.output_segment_open = false;
            switch (segment.disposition) {
                .discarded => {
                    clearTrackedText(&run.output_segment);
                    run.output_segment_redacted = false;
                    run.output_segment_incomplete = false;
                },
                .continued => {
                    if (run.output_segment.list.items.len != 0 and !run.output_continued_incomplete) {
                        run.output_continued_redacted = (projection.appendGroup(
                            &run.output_continued,
                            run.output_segment.list.items,
                            &.{},
                            run.initial_credentials[0],
                        ) catch |err| switch (err) {
                            error.ProjectionCapacity => lost: {
                                run.output_continued_incomplete = true;
                                break :lost false;
                            },
                            else => failed: {
                                retention_failure = err;
                                run.output_continued_incomplete = true;
                                break :failed false;
                            },
                        }) or run.output_segment_redacted or run.output_continued_redacted;
                    }
                    clearTrackedText(&run.output_segment);
                    run.output_segment_redacted = false;
                    run.output_continued_incomplete = run.output_continued_incomplete or run.output_segment_incomplete;
                    run.output_segment_incomplete = false;
                    run.output_continued_group = segment.group;
                },
                .commentary, .final, .partial => {
                    const output_start = run.assistant.committed_len;
                    const group_non_empty = run.output_continued.list.items.len != 0 or
                        run.output_segment.list.items.len != 0;
                    if (segment.disposition == .commentary and group_non_empty and
                        (run.commentary_count >= projection.max_commentary_segments_per_run or
                            run.commentary_count >= run.commentary_ends.len))
                    {
                        _ = recordEventProjectionFailure(run);
                        clearTrackedText(&run.output_continued);
                        clearTrackedText(&run.output_segment);
                        run.output_continued_group = null;
                        run.output_continued_redacted = false;
                        run.output_segment_redacted = false;
                        run.output_continued_incomplete = false;
                        run.output_segment_incomplete = false;
                        durable_boundary = true;
                        return .{ .applied = .{ .durable_boundary = durable_boundary } };
                    }
                    var incomplete = run.output_continued_incomplete or run.output_segment_incomplete;
                    run.assistant_redacted = (projection.appendGroup(
                        &run.assistant,
                        run.output_continued.list.items,
                        run.output_segment.list.items,
                        run.initial_credentials[0],
                    ) catch |err| switch (err) {
                        error.ProjectionCapacity => lost: {
                            incomplete = true;
                            break :lost false;
                        },
                        else => failed: {
                            retention_failure = err;
                            incomplete = true;
                            break :failed false;
                        },
                    }) or run.output_continued_redacted or run.output_segment_redacted or run.assistant_redacted;
                    if (incomplete) _ = recordEventProjectionFailure(run);
                    run.output_segment_incomplete = false;
                    run.output_continued_incomplete = false;
                    clearTrackedText(&run.output_continued);
                    clearTrackedText(&run.output_segment);
                    run.output_continued_group = null;
                    run.output_continued_redacted = false;
                    run.output_segment_redacted = false;
                    switch (segment.disposition) {
                        .commentary => {
                            if (group_non_empty) {
                                std.debug.assert(run.commentary_count < run.commentary_ends.len);
                                run.commentary_ends[run.commentary_count] =
                                    @intCast(run.assistant.committed_len);
                                run.commentary_count += 1;
                            }
                        },
                        .final => {
                            run.assistant_output_kind = if (incomplete) .partial else .final;
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
            if (retention_failure) |failure| return @as(EventApplyError!EventApplication, failure);
        },
        .stream_done => {
            const previous = currentActivity(run);
            run.model_activity = .none;
            return activityChange(run, previous);
        },
    }
    return .{ .applied = .{ .durable_boundary = durable_boundary } };
}

// Trusted receipts are accepted by applyEvent before these optional details.
// A detail capacity gap must still publish and persist this tool_result.
fn projectToolResultDetails(task_id: u64, run: *RunRecord, envelope: *const agent.OwnedCoreEvent, projection: EventProjection) EventProjectionError!void {
    const result = envelope.event.value.known.tool_result;
    const tool = if (envelope.generated_image_path) |path|
        try projection.retain_generated_media_fn(projection.context, run, result.id, path, task_id, .image)
    else if (envelope.generated_video_path) |path|
        try projection.retain_generated_media_fn(projection.context, run, result.id, path, task_id, .video)
    else
        try projection.findOrCreateTool(run, result.id, result.name, result.input);
    tool.is_error = result.is_error;
    tool.elapsed_ms = result.elapsed_ms;
    tool.state = if (result.is_error) .failed else .completed;
    const input = try projection.replaceText(
        &tool.input,
        result.input,
        run.initial_credentials[0],
    );
    tool.input_truncated = input.truncated;
    tool.redacted = tool.redacted or input.redacted;
    const content = try projection.replaceText(
        &tool.content,
        imageReadSummary(result.name, result.is_error, result.content) orelse result.content,
        run.initial_credentials[0],
    );
    tool.content_truncated = content.truncated;
    tool.redacted = tool.redacted or content.redacted;
    if (!tool.receipt_metadata)
        try projection.replaceFileReferences(tool, envelope, run.initial_credentials[0], task_id, run.generation);
}

fn clearTrackedText(target: *TrackedText) void {
    target.list.clearRetainingCapacity();
    target.committed_len = 0;
}

pub fn permissionSummary(value: agent.PermissionProvenance) EventProjectionError!PermissionSummary {
    if (value.tool.name.len > permission_summary_field_capacity or
        value.tool.binding.len > permission_summary_field_capacity or
        value.canonical_arguments_digest.len > permission_summary_field_capacity or
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
    @memcpy(
        summary.canonical_arguments_digest[0..value.canonical_arguments_digest.len],
        value.canonical_arguments_digest,
    );
    summary.canonical_arguments_digest_len = value.canonical_arguments_digest.len;
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

const toolRouteDigest = agent.toolRouteDigest;

fn findTool(entries: []?ToolView, id: []const u8) ?*ToolView {
    const digest = toolRouteDigest(id);
    for (entries) |*entry| if (entry.*) |*tool|
        if (std.mem.eql(u8, &tool.route_digest, &digest)) return tool;
    return null;
}

fn addU64(left: u64, right: u64) EventApplyError!u64 {
    return std.math.add(u64, left, right) catch error.InvalidUsage;
}

fn validContextWarning(warning: anytype) bool {
    return warning.warning_threshold != 0 and
        warning.warning_threshold <= warning.auto_compact_threshold and
        warning.auto_compact_threshold <= warning.blocking_limit and
        warning.current_tokens >= warning.warning_threshold;
}

fn validAutoCompact(compact: anytype) bool {
    return (compact.before_tokens == 0 and compact.after_tokens == 0) or
        (compact.before_tokens != 0 and
            compact.after_tokens <= compact.before_tokens);
}

fn validRunStateTransition(
    previous: ?agent.RunStatePhase,
    next: agent.RunStatePhase,
) bool {
    const current = previous orelse return true;
    return switch (current) {
        .completed, .failed, .aborted, .poisoned => false,
        .finalizing => switch (next) {
            .finalizing, .completed, .failed, .aborted, .poisoned => true,
            else => false,
        },
        else => next != .starting or current == .starting,
    };
}

test "compact projection withholds worker terminal until main-thread observation" {
    var compact = CompactRecord{
        .id = 9,
        .after_run_id = 7,
        .terminal_diagnostic = @constCast(""),
    };
    compact.agent_handoff.store(.running, .release);
    compact.terminal_payload = .{
        .exclude_on_product_terminal = false,
        .phase = .compacted,
        .cause = null,
        .before_context_tokens = 120,
        .after_context_tokens = 40,
        .usage = .{ .input_tokens = 3, .output_tokens = 5 },
        .session_disposition_at_completion = .reusable,
    };
    compact.terminal_publication.store(.published, .release);

    const before_observation = compactProjectionFacts(&compact);
    try std.testing.expectEqual(CompactPhase.compacting, before_observation.phase);
    try std.testing.expect(before_observation.terminal == null);

    compact.pending_interruption.store(.user_cancel, .release);
    try std.testing.expectEqual(
        CompactPhase.stopping,
        compactProjectionFacts(&compact).phase,
    );

    compact.terminal_observed = true;
    const observed = compactProjectionFacts(&compact);
    try std.testing.expectEqual(CompactPhase.compacted, observed.phase);
    try std.testing.expectEqual(@as(u64, 120), observed.terminal.?.before_context_tokens);
}

test "input reading anchors reserve unframed slots without exposing held suffixes" {
    var ends = [_]u64{ 0, 0 };
    var run: RunRecord = .{
        .id = 1,
        .generation = 1,
        .execution_generation = 1,
        .execution_protocol = .anthropic_messages,
        .execution_model = "model",
        .permission_profile = .approval_required,
        .permission_interaction = .interactive,
        .input = .{ .text = .{ .value = @constCast("prompt") } },
        .commentary_ends = &ends,
        .tools = &.{},
        .terminal_diagnostic = @constCast(""),
    };
    defer run.output_segment.list.deinit(std.testing.allocator);
    try run.output_segment.list.appendSlice(std.testing.allocator, "held credential prefix");
    try std.testing.expectEqual(@as(u32, 1), run.outputPartCount());
    run.commentary_count = 2; // Sanitized empty groups still own their slots.
    try std.testing.expectEqual(@as(u32, 3), run.outputPartCount());
    run.output_segment.committed_len = 4;
    try std.testing.expectEqual(@as(u32, 3), run.outputPartCount());
    run.output_segment.committed_len = 0;
    run.output_segment_redacted = true;
    try std.testing.expectEqual(@as(u32, 3), run.outputPartCount());
    run.output_segment_redacted = false;
    run.output_continued_redacted = true;
    try std.testing.expectEqual(@as(u32, 3), run.outputPartCount());
    run.output_continued_redacted = false;
    run.assistant_output_kind = .partial; // Even an empty classified tail.
    try std.testing.expectEqual(@as(u32, 3), run.outputPartCount());
}

test "event drain withholds terminal facts and assistant suffix until finalization" {
    var commentary_ends: [0]u64 = .{};
    var runs = [_]?RunRecord{.{
        .id = 7,
        .generation = 1,
        .execution_generation = 1,
        .execution_protocol = .anthropic_messages,
        .execution_model = "model",
        .permission_profile = .approval_required,
        .permission_interaction = .interactive,
        .input = .{ .text = .{ .value = @constCast("prompt") } },
        .commentary_ends = &commentary_ends,
        .active_phase = .running,
        .tools = &.{},
        .terminal_diagnostic = @constCast(""),
    }};
    var compacts: [0]?CompactRecord = .{};
    var ui_history: [0]?UiRecord = .{};
    var task = Task{
        .durable = .{
            .id = 3,
            .recent_order = 1,
            .execution_generation = 1,
            .execution_protocol = .anthropic_messages,
            .execution_model = @constCast("model"),
            .permission_profile = .approval_required,
            .permission_interaction = .interactive,
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
    run.admitted_at_ms = 200;
    run.assistant.list = .empty;
    try run.assistant.list.appendSlice(std.testing.allocator, "suffix");
    defer run.assistant.list.deinit(std.testing.allocator);
    run.terminal_payload = .{
        .exclude_on_product_terminal = false,
        .phase = .completed,
        .outcome = .completed,
        .cause = null,
        .session_disposition_at_completion = .reusable,
    };
    run.terminal_publication.store(.published, .release);

    run.model_activity = .thinking;
    for ([_]ActiveRunPhase{ .running, .queued, .waiting_ui, .stopping }) |phase| {
        run.active_phase = phase;
        const projection = runProjectionFacts(run);
        try std.testing.expectEqual(RunPhase.running, projection.phase);
        try std.testing.expectEqual(RunActivity.finalizing, projection.activity.?);
        try std.testing.expect(projection.terminal == null);
    }
    try std.testing.expect(markTerminalRunsBeforeEventDrain(&task));
    try std.testing.expectEqual(ModelActivity.none, run.model_activity);
    try std.testing.expect(finalizeMarkedTerminalRunsAfterEventDrain(
        &task,
        900,
        1_000,
    ));
    try std.testing.expectEqual(@as(?u64, 700), run.elapsed_ms);
    try std.testing.expectEqual(@as(?u64, 700), runElapsedMs(run, 5_000));
    try std.testing.expectEqual(@as(?u64, 1_000), run.finished_at_unix_ms);
    try std.testing.expectEqual(@as(usize, 6), run.assistant.committed_len);
    const terminal_projection = runProjectionFacts(run);
    try std.testing.expectEqual(RunPhase.completed, terminal_projection.phase);
    try std.testing.expectEqual(RunOutcome.completed, terminal_projection.terminal.?.outcome);
    try std.testing.expectEqual(
        TerminalDiagnosticDisposition.absent,
        terminal_projection.terminal.?.diagnostic_disposition,
    );
    try std.testing.expect(terminal_projection.activity == null);

    run.terminal_payload.diagnostic_len = 1;
    try std.testing.expectEqual(
        TerminalDiagnosticDisposition.withheld,
        productTerminalFacts(run).?.diagnostic_disposition,
    );
    run.terminal_payload.diagnostic_len = 0;
    run.terminal_payload.diagnostic_truncated = true;
    try std.testing.expectEqual(
        TerminalDiagnosticDisposition.withheld,
        productTerminalFacts(run).?.diagnostic_disposition,
    );
    run.terminal_payload.diagnostic_truncated = false;
    run.terminal_payload.diagnostic_redacted = true;
    try std.testing.expectEqual(
        TerminalDiagnosticDisposition.withheld,
        productTerminalFacts(run).?.diagnostic_disposition,
    );
}

test "event drain applies Conversation exclusion even after queued cancellation was observed" {
    for ([_]bool{ false, true }) |exclude| {
        var runs = [_]?RunRecord{.{
            .id = 7,
            .generation = 1,
            .execution_generation = 1,
            .execution_protocol = .anthropic_messages,
            .execution_model = "model",
            .permission_profile = .approval_required,
            .permission_interaction = .interactive,
            .input = .{ .text = .{ .value = @constCast("prompt") } },
            .commentary_ends = &.{},
            .tools = &.{},
            .terminal_diagnostic = @constCast(""),
            .terminal_observed = true,
            .terminal_payload = .{
                .exclude_on_product_terminal = exclude,
                .phase = .cancelled,
                .outcome = .cancelled,
                .cause = .user_cancel,
                .session_disposition_at_completion = .reusable,
            },
            .terminal_publication = .init(.published),
        }};
        var task = Task{
            .durable = .{
                .id = 3,
                .recent_order = 1,
                .execution_generation = 1,
                .execution_protocol = .anthropic_messages,
                .execution_model = @constCast("model"),
                .permission_profile = .approval_required,
                .permission_interaction = .interactive,
                .workspace_id = 2,
                .workspace_root = @constCast("root"),
                .title = @constCast("title"),
                .runs = &runs,
                .compacts = &.{},
                .ui_history = &.{},
            },
            .runtime = .{},
        };
        const run = &runs[0].?;
        try std.testing.expectEqual(ConversationCoverage.pending, run.coverage);
        try std.testing.expect(productTerminalFacts(run) == null);
        try std.testing.expect(markTerminalRunsBeforeEventDrain(&task));
        try std.testing.expectEqual(ConversationCoverage.pending, run.coverage);
        try std.testing.expect(finalizeMarkedTerminalRunsAfterEventDrain(&task, null, null));
        try std.testing.expectEqual(
            if (exclude) ConversationCoverage.excluded else ConversationCoverage.pending,
            run.coverage,
        );
        try std.testing.expectEqual(RunPhase.cancelled, runPhase(run));
        try std.testing.expect(!markTerminalRunsBeforeEventDrain(&task));
        try std.testing.expect(!finalizeMarkedTerminalRunsAfterEventDrain(&task, null, null));
        try std.testing.expectEqual(
            if (exclude) ConversationCoverage.excluded else ConversationCoverage.pending,
            run.coverage,
        );
    }
}

test "event drain advances the final commentary boundary with the committed suffix" {
    var commentary_ends = [_]u64{3};
    var runs = [_]?RunRecord{.{
        .id = 7,
        .generation = 1,
        .execution_generation = 1,
        .execution_protocol = .anthropic_messages,
        .execution_model = "model",
        .permission_profile = .approval_required,
        .permission_interaction = .interactive,
        .input = .{ .text = .{ .value = @constCast("prompt") } },
        .commentary_ends = &commentary_ends,
        .commentary_count = 1,
        .active_phase = .running,
        .tools = &.{},
        .terminal_diagnostic = @constCast(""),
    }};
    var compacts: [0]?CompactRecord = .{};
    var ui_history: [0]?UiRecord = .{};
    var task = Task{
        .durable = .{
            .id = 3,
            .recent_order = 1,
            .execution_generation = 1,
            .execution_protocol = .anthropic_messages,
            .execution_model = @constCast("model"),
            .permission_profile = .approval_required,
            .permission_interaction = .interactive,
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
    try run.assistant.list.appendSlice(std.testing.allocator, "prefix-tail");
    defer run.assistant.list.deinit(std.testing.allocator);
    run.assistant.committed_len = 3;
    run.terminal_payload = .{
        .exclude_on_product_terminal = false,
        .phase = .completed,
        .outcome = .completed,
        .cause = null,
        .session_disposition_at_completion = .reusable,
    };
    run.terminal_publication.store(.published, .release);

    try std.testing.expect(markTerminalRunsBeforeEventDrain(&task));
    try std.testing.expect(finalizeMarkedTerminalRunsAfterEventDrain(
        &task,
        null,
        null,
    ));
    try std.testing.expectEqual(@as(usize, "prefix-tail".len), run.assistant.committed_len);
    try std.testing.expectEqual(
        @as(u64, "prefix-tail".len),
        run.commentary_ends[run.commentary_count - 1],
    );
}

test "event drain does not infer Core protocol faults from local retained state" {
    for ([_]bool{ false, true }) |local_gap| {
        var commentary_ends: [0]u64 = .{};
        var runs = [_]?RunRecord{.{
            .id = 7,
            .generation = 1,
            .execution_generation = 1,
            .execution_protocol = .anthropic_messages,
            .execution_model = "model",
            .permission_profile = .approval_required,
            .permission_interaction = .interactive,
            .input = .{ .text = .{ .value = @constCast("prompt") } },
            .commentary_ends = &commentary_ends,
            .tools = &.{},
            .terminal_diagnostic = @constCast(""),
            .output_segment_open = true,
        }};
        var compacts: [0]?CompactRecord = .{};
        var ui_history: [0]?UiRecord = .{};
        var task = Task{
            .durable = .{
                .id = 3,
                .recent_order = 1,
                .execution_generation = 1,
                .execution_protocol = .anthropic_messages,
                .execution_model = @constCast("model"),
                .permission_profile = .approval_required,
                .permission_interaction = .interactive,
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
            .exclude_on_product_terminal = false,
            .phase = .completed,
            .outcome = .completed,
            .cause = null,
            .session_disposition_at_completion = .reusable,
        };
        run.terminal_payload.event_delivery_lost = local_gap;
        run.terminal_publication.store(.published, .release);

        try std.testing.expect(markTerminalRunsBeforeEventDrain(&task));
        try std.testing.expect(finalizeMarkedTerminalRunsAfterEventDrain(
            &task,
            null,
            null,
        ));
        try std.testing.expectEqual(if (local_gap) @as(?EventProjectionFailure, .consumer_rejected) else null, run.event_projection_failure);
        try std.testing.expectEqual(RunOutcome.completed, productTerminalFacts(run).?.outcome);
        try std.testing.expectEqual(@as(usize, 0), run.output_segment.list.items.len);
        try std.testing.expect(run.first_event_rejection == null);
    }
}
