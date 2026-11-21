//! The Session's product-facing surface: the inputs, options, limits and
//! outcomes a caller names to open, restore, run and close a Session.
//!
//! Everything here is plain data. A value that retains a live Session or
//! Runtime belongs in `port.zig`, which states that boundary, or in the
//! implementation itself. Keeping these declarations out of the
//! implementation is what lets a caller name them without the AgentCore
//! archive; `contract.zig` states the rule.

const std = @import("std");
const sdk = @import("metask_agentcore");
const wire = sdk.types;
const control = @import("control.zig");
const multimodal = @import("multimodal.zig");
const image_generation = @import("../image_generation.zig");
const image_http = @import("agent_http_transport");
const catalog = @import("agent_catalog");
const mcp_catalog = @import("agent_mcp_catalog");
const checkpoint = @import("agent_checkpoint");
const checkpoint_restore = @import("agent_checkpoint_restore");
const model_binding = @import("agent_model_binding");

const ModelBinding = model_binding.ModelBinding;
const PermissionMode = control.PermissionMode;
const ShellPolicy = control.ShellPolicy;
const SessionState = control.SessionState;
const SessionDisposition = control.SessionDisposition;
const InputObservation = control.InputObservation;
const InputPart = multimodal.InputPart;
const CatalogLease = catalog.Lease;
const McpSelection = mcp_catalog.Selection;
const McpActivation = mcp_catalog.Activation;
const CheckpointLimits = checkpoint.Limits;
const CheckpointSource = checkpoint_restore.Source;
const CheckpointRestoreExpectation = checkpoint_restore.Expectation;

pub const ImageGenerationTestOptions = struct {
    transport: image_http.Transport,
    limits: image_generation.Limits = .{},
};
/// Binding bytes are borrowed only through preparation. Effect contexts remain
/// borrowed through Run quiescence and are retained by the Host execution owner.
pub const ImageGenerationRunInput = struct {
    binding: image_generation.BindingInput,
    transport: image_http.Transport,
};
/// Extra same-turn re-issues this Host grants a Run whose accepted stream
/// failed without an answer after it showed output: a stall, a stream that
/// ended before its stop report, or a dropped connection. It never covers a
/// server-declared error or a local decode failure, and it is additional to
/// the one re-issue every request already has of its own while it started no
/// tool call. Two matches the reference implementation's headless value; each
/// spend re-bills that request's whole input, so the Host stays deliberately
/// low until there is evidence about how often drops arrive consecutively.
pub const stream_retry_budget: u32 = 2;
pub const max_submitted_inputs: usize = @intCast(wire.MAX_SUBMITTED_INPUTS_V1);
pub const max_submitted_input_bytes: usize = @intCast(wire.MAX_SUBMITTED_INPUT_BYTES_V1);
pub const Protocol = @import("agent_protocol").Protocol;
pub const PermissionModeUpdate = struct {
    changed: bool,
    policy_generation: u64,
};

/// What `describe` reports about the Conversation: the numbering every rewind
/// position is expressed in.
///
/// Positions are 1-based over the full history, the compacted prefix
/// included, and a plain turn occupies two of them: the user message, then
/// the assistant reply. A caller about to submit a Run input therefore names
/// that input's own position as `message_count + 1` -- and must read this
/// again before the next submission rather than counting its own records,
/// because tool results and runtime text occupy positions too.
///
/// Measured against the real Core: a compaction leaves `message_count`
/// unchanged and only raises `compact_boundary`, so a position recorded once
/// stays valid for as long as its message is above the boundary.
pub const ConversationBounds = struct {
    message_count: u64,
    /// Positions at or below this have been summarized away. The invariant
    /// `compact_boundary <= message_count` is Core's, not ours.
    compact_boundary: u64,
};

/// Why a rewind was refused. Each of these means something different to the
/// caller, so none of them may be collapsed into one failure.
pub const RewindRefusal = enum {
    /// The position is zero: nothing names message zero.
    invalid_position,
    /// The position is past the end of the Conversation. Reaching this means
    /// the recorded position and Core's history disagree -- a restore from an
    /// older checkpoint, say -- not that the user asked for anything invalid.
    out_of_range,
    /// The position is at or below `compact_boundary`: its message was
    /// summarized away and can no longer be named. This one is by design and
    /// is the only refusal a caller may present to the user as such.
    compacted,
    /// The position names a message that is not a user message. A caller that
    /// records `message_count + 1` at submission can only reach this by
    /// having mapped a position wrongly, so it means *our* bug, and must stay
    /// reportable as one instead of being shown as an unsupported operation.
    not_user_message,
};

pub const RewindOutcome = union(enum) {
    /// Core dropped the named user message and everything after it. Only the
    /// Conversation changed: files and other effects of the dropped turns
    /// stay, which is the one thing a caller's confirmation step has to say.
    rewound,
    /// The Conversation already ends before the named position, so there was
    /// nothing to drop and Core was not called. A Run whose input never
    /// reached Core leaves its recorded position exactly here.
    unchanged,
    refused: struct {
        refusal: RewindRefusal,
        /// Where the refusal was decided. `host` is this Host's own check
        /// against the `describe` it just took; `core` means Core refused a
        /// position that check had admitted, so the two readings of the same
        /// history disagree -- as much our bug as `not_user_message` is.
        source: enum { host, core },
    },
};

pub const PermissionInteraction = enum {
    interactive,
    noninteractive,
};

pub const McpActivationUnavailableReason = enum {
    refresh_failed,
    refresh_rejected,
    invalid_catalog,
    resource_limit,
    generation_mismatch,
    binding_mismatch,
    invalid_selection,
};

pub const McpConfigurationApplyOutcome = enum {
    applied,
    superseded,
    rejected,
};

pub const McpActivationOutcome = union(enum) {
    empty,
    activated: *McpActivation,
    unavailable: McpActivationUnavailableReason,
};

pub const BeginRunFailure = struct {
    err: Error,
    session_disposition: SessionDisposition,
};

pub const CloseOutcome = union(enum) {
    closed,
    failure: struct {
        err: Error,
        session_disposition: SessionDisposition,
    },

    /// A close that could not reach the Session is a failure, never a close:
    /// `closed` would tell the caller its Session is gone when it may still
    /// be running.
    pub const link_unreachable: std.meta.Tag(@This()) = .failure;
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
    /// Ordered borrowed blocks, copied/encoded before prepareRun returns.
    multimodal: []const InputPart,
    text: []const u8,
    skill: struct {
        skill_id: []const u8,
        catalog_revision: []const u8,
        argument_values: []const []const u8,
    },
};

pub const OperationIdFloor = struct {
    last_run_id: u64 = 0,
    last_compact_id: u64 = 0,
    last_ui_request_id: u64 = 0,
};

pub const SessionOpenOptions = struct {
    /// Which Task this Session belongs to, and at which binding epoch.
    ///
    /// Product's own identity for the Session, given once at creation and
    /// restore and held for the Session's life. Neither is derivable here:
    /// the Agent names Sessions by its own route id, and a checkpoint's
    /// `logical_session_id` is AgentCore's and exists only once a checkpoint
    /// does.
    ///
    /// They are carried because a checkpoint the Agent stages *without being
    /// asked* -- after the caller is gone -- still has to be a record Product
    /// can accept, and `src/product/task/state.zig`'s
    /// `CheckpointExportContext` needs both. An export the caller asked for
    /// could carry them per call; one nobody asked for cannot, so they belong
    /// to the Session.
    ///
    /// Neither has a default on purpose. A zero would make a staged record
    /// with `binding_epoch = 0` indistinguishable from a real one, which is
    /// the acceptance path's one way to go wrong quietly -- so every caller
    /// says which Task it is opening a Session for, and the compiler asks.
    task_id: u64,
    binding_epoch: u64,
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

pub const SessionRestoreOptions = struct {
    session: SessionOpenOptions,
    checkpoint_limits: CheckpointLimits,
    source: CheckpointSource,
    expectation: CheckpointRestoreExpectation,
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
    RewindFailed,
    /// The half that performs this call cannot be reached.
    ///
    /// No other member means it. Reusing one would assert something false --
    /// `SessionClosing` would tell the caller its Session is winding down,
    /// `CoreCallFailed` that Core was reached and failed -- and a caller
    /// acting on either would be acting on a fact nobody established. The
    /// execution link numbers this in `error_code.zig`; in process nothing
    /// produces it, because in process there is no other half to lose.
    DependencyUnreachable,
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
