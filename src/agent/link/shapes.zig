//! The explicit wire shapes for the payload types the structural codec
//! refuses.
//!
//! Each one is a plain-data mirror that `payload.zig` can carry, plus the
//! conversion in whichever direction is meaningful without the other half's
//! context. A mirror is never a second source of truth: every field it
//! has, it has because the original has it, and `requireStructural` on the
//! mirror plus a round-trip test is what keeps the two from drifting.
//!
//! Three obstruction classes are handled here, because they need nothing from
//! the far side:
//!
//!   * an embedded error set becomes the number `error_code.zig` assigns it,
//!     so a link problem can never be mistaken for one of the port's own
//!     failures;
//!   * an owner that holds bytes through an allocator sends the bytes and
//!     keeps the ownership, so the receiving side owns its own copy;
//!   * a fixed-width digest or an optional slice rides as data.
//!
//! The remaining two classes -- a borrowed handle and a context pointer --
//! need an id a table resolves or a descriptor the far side acts on, so they
//! arrive with the handle tables rather than here.

const std = @import("std");
const contract = @import("agent_contract");
const error_code = @import("error_code.zig");
const payload = @import("payload.zig");
const checkpoint = @import("agent_checkpoint");
const handle_table = @import("handle_table.zig");

const control = contract.control;
const surface = contract.surface;

// ---------------------------------------------------------------------------
// An embedded error set becomes its registered number
// ---------------------------------------------------------------------------

/// `surface.CloseOutcome` with its error set replaced by the wire number.
pub const CloseOutcome = union(enum) {
    closed,
    failure: struct {
        error_code: u16,
        session_disposition: control.SessionDisposition,
    },

    pub fn from(value: surface.CloseOutcome) CloseOutcome {
        return switch (value) {
            .closed => .closed,
            .failure => |failure| .{ .failure = .{
                .error_code = error_code.encode(failure.err),
                .session_disposition = failure.session_disposition,
            } },
        };
    }

    /// `null` when the peer sent a number this build does not register, which
    /// is a protocol violation and never a generic failure.
    pub fn into(self: CloseOutcome) ?surface.CloseOutcome {
        return switch (self) {
            .closed => .closed,
            .failure => |failure| .{ .failure = .{
                .err = error_code.decodeContract(failure.error_code) orelse return null,
                .session_disposition = failure.session_disposition,
            } },
        };
    }
};

/// `surface.BeginRunFailure` with the same substitution.
pub const BeginRunFailure = struct {
    error_code: u16,
    session_disposition: control.SessionDisposition,

    pub fn from(value: surface.BeginRunFailure) BeginRunFailure {
        return .{
            .error_code = error_code.encode(value.err),
            .session_disposition = value.session_disposition,
        };
    }

    pub fn into(self: BeginRunFailure) ?surface.BeginRunFailure {
        return .{
            .err = error_code.decodeContract(self.error_code) orelse return null,
            .session_disposition = self.session_disposition,
        };
    }
};

// ---------------------------------------------------------------------------
// An owner sends its bytes and keeps its ownership
// ---------------------------------------------------------------------------

/// `control.CallbackRejection` with its one open value closed.
///
/// The original is documented as holding only fixed enums and counts, and
/// almost does -- except `failure: ?anyerror`, which can be any error in the
/// program rather than one of the port's. A diagnostic must not name the wrong
/// error, so an error the registry does not cover crosses as "present but
/// unnamed" instead of as some other error's number.
pub const CallbackRejection = struct {
    boundary: control.CallbackRejection.Boundary,
    reason: control.CallbackRejection.Reason,
    event: ?control.CoreEventKind,
    /// The registered number, when the registry names this error.
    failure_code: ?u16,
    /// An error was recorded that this build's registry does not name.
    failure_unnamed: bool,
    encoded_bytes: ?u64,
    host_run_id: u64,
    observed_run_id: ?u64,
    session_handle_matches: ?bool,
    session_identity_matches: ?bool,
    state: control.SessionState,
    input_adoption: ?InputAdoption,

    pub const InputAdoption = struct { id: u64, sequence: u32, turn: u32 };

    pub fn from(value: control.CallbackRejection) CallbackRejection {
        var failure_code: ?u16 = null;
        var failure_unnamed = false;
        if (value.failure) |err| {
            if (registered(err)) |code| failure_code = code else failure_unnamed = true;
        }
        return .{
            .boundary = value.boundary,
            .reason = value.reason,
            .event = value.event,
            .failure_code = failure_code,
            .failure_unnamed = failure_unnamed,
            .encoded_bytes = if (value.encoded_bytes) |bytes| @intCast(bytes) else null,
            .host_run_id = value.host_run_id,
            .observed_run_id = value.observed_run_id,
            .session_handle_matches = value.session_handle_matches,
            .session_identity_matches = value.session_identity_matches,
            .state = value.state,
            .input_adoption = if (value.input_adoption) |adoption| .{
                .id = adoption.id,
                .sequence = adoption.sequence,
                .turn = adoption.turn,
            } else null,
        };
    }

    /// An error the peer recorded but this build does not name.
    ///
    /// Declared here rather than taken from the registry, because its whole
    /// job is to name nothing else: the mirror's rule is that a diagnostic
    /// must not name the wrong cause, and reading "present but unnamed" back
    /// as some registered error would do exactly that. `null` would be worse
    /// still -- it says no failure was recorded, when one was.
    pub const unnamed_failure: anyerror = error.AgentFailureNotNamedByThisBuild;

    pub fn into(self: CallbackRejection) control.CallbackRejection {
        return .{
            .boundary = self.boundary,
            .reason = self.reason,
            .event = self.event,
            .failure = if (self.failure_unnamed)
                unnamed_failure
            else if (self.failure_code) |code|
                error_code.decode(code) orelse unnamed_failure
            else
                null,
            .encoded_bytes = if (self.encoded_bytes) |bytes| @intCast(bytes) else null,
            .host_run_id = self.host_run_id,
            .observed_run_id = self.observed_run_id,
            .session_handle_matches = self.session_handle_matches,
            .session_identity_matches = self.session_identity_matches,
            .state = self.state,
            .input_adoption = if (self.input_adoption) |adoption| .{
                .id = adoption.id,
                .sequence = adoption.sequence,
                .turn = adoption.turn,
            } else null,
        };
    }
};

fn registered(err: anyerror) ?u16 {
    @setEvalBranchQuota(error_code.entries.len * 64);
    inline for (error_code.entries) |entry| {
        if (err == @field(anyerror, entry.name)) return entry.code;
    }
    if (err == error.OutOfMemory) return error_code.out_of_memory_code;
    return null;
}

/// `control.TerminalResult` without its allocator. The diagnostic travels as
/// the bytes it actually holds rather than as its backing storage, so the
/// receiving side allocates its own and the truncation flag keeps its meaning.
pub const TerminalResult = struct {
    diagnostic: []const u8,
    diagnostic_truncated: bool,
    abi_status: ?contract.Status,
    raw_status_code: ?u32,
    stop_reason: ?contract.StopReason,
    raw_stop_reason_code: ?u32,
    abort_status: ?contract.Status,
    raw_abort_status_code: ?u32,
    termination_signal: ?control.TerminationSignal,
    file_changes_lost: bool,
    event_delivery_lost: bool,
    receipts: control.TerminalReceipts,
    failure: ?control.TerminalFailure,
    session_disposition_at_completion: control.SessionDisposition,
    durable_budget: ?control.DurableBudgetObservation,
    input_counts: ?control.InputCounts,
    first_callback_rejection: ?CallbackRejection,
    first_host_failure: ?control.HostFailure,
    controlled_callback_close: ?control.ExternalInterruption,
    model_error: ?control.ModelError,

    pub fn from(value: *const control.TerminalResult) TerminalResult {
        return .{
            .diagnostic = value.diagnostic_storage[0..value.diagnostic_len],
            .diagnostic_truncated = value.diagnostic_truncated,
            .abi_status = value.abi_status,
            .raw_status_code = value.raw_status_code,
            .stop_reason = value.stop_reason,
            .raw_stop_reason_code = value.raw_stop_reason_code,
            .abort_status = value.abort_status,
            .raw_abort_status_code = value.raw_abort_status_code,
            .termination_signal = value.termination_signal,
            .file_changes_lost = value.file_changes_lost,
            .event_delivery_lost = value.event_delivery_lost,
            .receipts = value.receipts,
            .failure = value.failure,
            .session_disposition_at_completion = value.session_disposition_at_completion,
            .durable_budget = value.durable_budget,
            .input_counts = value.input_counts,
            .first_callback_rejection = if (value.first_callback_rejection) |rejection|
                CallbackRejection.from(rejection)
            else
                null,
            .first_host_failure = value.first_host_failure,
            .controlled_callback_close = value.controlled_callback_close,
            .model_error = value.model_error,
        };
    }

    /// The diagnostic's bytes copied into this half's own storage, which
    /// `control.TerminalResult.deinit` then frees through the `allocator`
    /// field set here. The truncation flag keeps its meaning because the
    /// bytes it describes are the same bytes.
    pub fn into(
        self: TerminalResult,
        allocator: std.mem.Allocator,
    ) std.mem.Allocator.Error!control.TerminalResult {
        const storage = try allocator.dupe(u8, self.diagnostic);
        return .{
            .allocator = allocator,
            .diagnostic_storage = storage,
            .diagnostic_len = storage.len,
            .diagnostic_truncated = self.diagnostic_truncated,
            .abi_status = self.abi_status,
            .raw_status_code = self.raw_status_code,
            .stop_reason = self.stop_reason,
            .raw_stop_reason_code = self.raw_stop_reason_code,
            .abort_status = self.abort_status,
            .raw_abort_status_code = self.raw_abort_status_code,
            .termination_signal = self.termination_signal,
            .file_changes_lost = self.file_changes_lost,
            .event_delivery_lost = self.event_delivery_lost,
            .receipts = self.receipts,
            .failure = self.failure,
            .session_disposition_at_completion = self.session_disposition_at_completion,
            .durable_budget = self.durable_budget,
            .input_counts = self.input_counts,
            .first_callback_rejection = if (self.first_callback_rejection) |rejection|
                rejection.into()
            else
                null,
            .first_host_failure = self.first_host_failure,
            .controlled_callback_close = self.controlled_callback_close,
            .model_error = self.model_error,
        };
    }
};

/// `control.CompactTerminalResult` with the same treatment.
pub const CompactTerminalResult = struct {
    diagnostic: []const u8,
    diagnostic_truncated: bool,
    abi_status: ?contract.Status,
    raw_status_code: ?u32,
    abort_status: ?contract.Status,
    raw_abort_status_code: ?u32,
    outcome: ?control.CompactOutcome,
    before_context_tokens: u64,
    after_context_tokens: u64,
    input_tokens: u64,
    output_tokens: u64,
    cache_read_input_tokens: u64,
    cache_creation_input_tokens: u64,
    interruption: ?control.ExternalInterruption,
    failure: ?control.TerminalFailure,
    session_disposition_at_completion: control.SessionDisposition,

    pub fn from(value: *const control.CompactTerminalResult) CompactTerminalResult {
        return .{
            .diagnostic = value.diagnostic_storage[0..value.diagnostic_len],
            .diagnostic_truncated = value.diagnostic_truncated,
            .abi_status = value.abi_status,
            .raw_status_code = value.raw_status_code,
            .abort_status = value.abort_status,
            .raw_abort_status_code = value.raw_abort_status_code,
            .outcome = value.outcome,
            .before_context_tokens = value.before_context_tokens,
            .after_context_tokens = value.after_context_tokens,
            .input_tokens = value.input_tokens,
            .output_tokens = value.output_tokens,
            .cache_read_input_tokens = value.cache_read_input_tokens,
            .cache_creation_input_tokens = value.cache_creation_input_tokens,
            .interruption = value.interruption,
            .failure = value.failure,
            .session_disposition_at_completion = value.session_disposition_at_completion,
        };
    }

    pub fn into(
        self: CompactTerminalResult,
        allocator: std.mem.Allocator,
    ) std.mem.Allocator.Error!control.CompactTerminalResult {
        const storage = try allocator.dupe(u8, self.diagnostic);
        return .{
            .allocator = allocator,
            .diagnostic_storage = storage,
            .diagnostic_len = storage.len,
            .diagnostic_truncated = self.diagnostic_truncated,
            .abi_status = self.abi_status,
            .raw_status_code = self.raw_status_code,
            .abort_status = self.abort_status,
            .raw_abort_status_code = self.raw_abort_status_code,
            .outcome = self.outcome,
            .before_context_tokens = self.before_context_tokens,
            .after_context_tokens = self.after_context_tokens,
            .input_tokens = self.input_tokens,
            .output_tokens = self.output_tokens,
            .cache_read_input_tokens = self.cache_read_input_tokens,
            .cache_creation_input_tokens = self.cache_creation_input_tokens,
            .interruption = self.interruption,
            .failure = self.failure,
            .session_disposition_at_completion = self.session_disposition_at_completion,
        };
    }
};

/// `checkpoint.Description` without its allocator. The blob itself never
/// crosses -- only what the record needs in order to name it.
pub const CheckpointDescription = struct {
    session_id: []const u8,
    origin: checkpoint.LogicalSessionOrigin,
    lifecycle: checkpoint.SessionLifecycle,
    registered: bool,
    last_run_id: u64,
    last_compact_id: u64,
    checkpoint_generation: u64,
    permission_mode: @FieldType(checkpoint.Description, "permission_mode"),
    policy_generation: u64,
    catalog_generation: u64,
    model: []const u8,
    message_count: u64,
    compact_boundary: u64,
    skill_catalog_revision: ?[]const u8,
    mcp_selection_fingerprint: []const u8,
    budget_hard_bytes: u64,
    budget_soft_bytes: u64,
    durable_usage_bytes: u64,
    available_bytes: u64,
    // The seven below were missing, and building the direction that reads a
    // mirror *back* is what found it. Outbound, a mirror that is a subset of
    // its original compiles and sends less than the caller had in process --
    // the generic reader walks the mirror's fields, so a field that is not
    // there is not a question anyone is asked. Inbound there is no value to
    // put in them at all, which is the same loss made visible.
    //
    // `mirror_completeness` below is the check, so the next field added to a
    // `checkpoint.Description` is named by the compiler instead.
    compaction_recommended: bool,
    budget_outcome: checkpoint.DurableBudgetOutcome,
    required_bytes: u64,
    restore_health: checkpoint.RestoreHealth,
    invalidated_skill_authority: u32,
    invalidated_permission_rules: u32,
    invalidated_mcp_bindings: u32,

    /// Allocated here, freed by `checkpoint.Description.deinit` through the
    /// `allocator` field this sets: the caller's half owns its own copy and
    /// Product frees it exactly as it does in process.
    pub fn into(
        self: CheckpointDescription,
        allocator: std.mem.Allocator,
    ) std.mem.Allocator.Error!checkpoint.Description {
        const session_id = try allocator.dupe(u8, self.session_id);
        errdefer allocator.free(session_id);
        const model = try allocator.dupe(u8, self.model);
        errdefer allocator.free(model);
        const revision: ?[]u8 = if (self.skill_catalog_revision) |value|
            try allocator.dupe(u8, value)
        else
            null;
        errdefer if (revision) |value| allocator.free(value);
        const fingerprint = try allocator.dupe(u8, self.mcp_selection_fingerprint);

        return .{
            .allocator = allocator,
            .session_id = session_id,
            .origin = self.origin,
            .lifecycle = self.lifecycle,
            .registered = self.registered,
            .last_run_id = self.last_run_id,
            .last_compact_id = self.last_compact_id,
            .checkpoint_generation = self.checkpoint_generation,
            .permission_mode = self.permission_mode,
            .policy_generation = self.policy_generation,
            .catalog_generation = self.catalog_generation,
            .model = model,
            .message_count = self.message_count,
            .compact_boundary = self.compact_boundary,
            .skill_catalog_revision = revision,
            .mcp_selection_fingerprint = fingerprint,
            .budget_hard_bytes = self.budget_hard_bytes,
            .budget_soft_bytes = self.budget_soft_bytes,
            .durable_usage_bytes = self.durable_usage_bytes,
            .available_bytes = self.available_bytes,
            .compaction_recommended = self.compaction_recommended,
            .budget_outcome = self.budget_outcome,
            .required_bytes = self.required_bytes,
            .restore_health = self.restore_health,
            .invalidated_skill_authority = self.invalidated_skill_authority,
            .invalidated_permission_rules = self.invalidated_permission_rules,
            .invalidated_mcp_bindings = self.invalidated_mcp_bindings,
        };
    }
};

/// `checkpoint.Outcome`: the export's identity and the description, or the
/// typed failure.
pub const CheckpointOutcome = union(enum) {
    success: struct {
        checkpoint: checkpoint.Export,
        /// Where the bytes are. Plain data already, so it crosses as it is.
        placement: checkpoint.Placement,
        description: CheckpointDescription,
    },
    failure: checkpoint.Failure,

    pub fn into(
        self: CheckpointOutcome,
        allocator: std.mem.Allocator,
    ) std.mem.Allocator.Error!checkpoint.Outcome {
        return switch (self) {
            .success => |success| .{ .success = .{
                .checkpoint = success.checkpoint,
                .placement = success.placement,
                .description = try success.description.into(allocator),
            } },
            .failure => |failure| .{ .failure = failure },
        };
    }
};

/// `surface.PendingUiRequest` without its allocator.
pub const PendingUiRequest = struct {
    session_id: u64,
    run_id: u64,
    request_id: u64,
    input_adopted_count: u32,
    json: []const u8,

    pub fn from(value: *const surface.PendingUiRequest) PendingUiRequest {
        return .{
            .session_id = value.session_id,
            .run_id = value.run_id,
            .request_id = value.request_id,
            .input_adopted_count = value.input_adopted_count,
            .json = value.json,
        };
    }

    pub fn into(
        self: PendingUiRequest,
        allocator: std.mem.Allocator,
    ) std.mem.Allocator.Error!surface.PendingUiRequest {
        return .{
            .session_id = self.session_id,
            .run_id = self.run_id,
            .request_id = self.request_id,
            .input_adopted_count = self.input_adopted_count,
            .json = try allocator.dupe(u8, self.json),
            .allocator = allocator,
        };
    }
};

// ---------------------------------------------------------------------------
// A borrowed handle becomes an id the far side's table resolves
// ---------------------------------------------------------------------------

/// `surface.SessionOpenOptions` with its two borrowed handles named by id.
///
/// The skill catalog lease and the MCP selection both live in the execution
/// half, issued by an earlier call and handed straight back here. Nothing else
/// in the options is a capability, so everything else is itself.
pub const SessionOpenOptions = struct {
    /// Product's own identity for the Session. Plain data, and the reason it
    /// crosses is in `surface.SessionOpenOptions`: a checkpoint the execution
    /// half stages without being asked still has to be a record Product can
    /// accept.
    task_id: u64,
    binding_epoch: u64,
    model_binding: model_binding_type,
    permission_mode: control.PermissionMode,
    shell_policy: control.ShellPolicy,
    permission_interaction: surface.PermissionInteraction,
    workspace: surface.WorkspaceInput,
    canonical_user_home: []const u8,
    workspace_epoch: []const u8,
    /// Absent as `Id.none`, not as an optional: a zero id is already invalid
    /// by construction, so an `?Id` would be a second way to say the same
    /// thing and a decoder would have to be told which one it is reading.
    skill_catalog: handle_table.Id,
    skill_policy: ?surface.SkillPolicyInput,
    /// A selection is plain data, so it crosses as a copy the receiving
    /// Runtime checks exactly as it checks one of its own.
    mcp_selection: ?contract.mcp.catalog.SelectionWire,
    operation_id_floor: surface.OperationIdFloor,
};

const model_binding_type = @FieldType(surface.SessionOpenOptions, "model_binding");

comptime {
    // Every shape in this file is one the wire can actually carry. Without
    // this, a mirror could pick up a field that is itself unshippable and the
    // failure would surface at the first call instead of the build.
    payload.requireStructural(CloseOutcome);
    payload.requireStructural(CallbackRejection);
    payload.requireStructural(BeginRunFailure);
    payload.requireStructural(TerminalResult);
    payload.requireStructural(CompactTerminalResult);
    payload.requireStructural(CheckpointDescription);
    payload.requireStructural(CheckpointOutcome);
    payload.requireStructural(PendingUiRequest);
    payload.requireStructural(SessionOpenOptions);
}

/// Asserts that a mirror and its original describe the same thing, in both
/// directions: every mirror field names a field of the original unless it is
/// listed as reshaped, and every field of the original is on the mirror
/// unless it is listed as left behind.
///
/// The second direction was missing, and its absence cost real data: the
/// mirror for `checkpoint.Description` was a seven-field subset of it. That
/// is invisible on the way out, because the generic reader walks the
/// *mirror's* fields -- a field that is not there is not a question anyone is
/// asked -- and it was only building the direction that reads a mirror back
/// that made it show, as seven fields with no value to put in them.
fn mirrors(comptime Mirror: type, comptime Origin: type, comptime decided: Decided) void {
    comptime {
        @setEvalBranchQuota(100_000);
        for (@typeInfo(Mirror).@"struct".fields) |field| {
            for (decided.reshaped) |name| {
                if (std.mem.eql(u8, name, field.name)) break;
            } else if (!@hasField(Origin, field.name)) @compileError(
                @typeName(Mirror) ++ "." ++ field.name ++ " does not name a field of " ++
                    @typeName(Origin) ++ ", and is not listed as reshaped",
            );
        }
        for (@typeInfo(Origin).@"struct".fields) |field| {
            for (decided.left_behind) |name| {
                if (std.mem.eql(u8, name, field.name)) break;
            } else if (!@hasField(Mirror, field.name)) @compileError(
                @typeName(Origin) ++ "." ++ field.name ++ " is on neither " ++
                    @typeName(Mirror) ++ " nor its `left_behind` list, so it would simply " ++
                    "not cross. Carry it, or say here why it must not and what the " ++
                    "receiving side has instead",
            );
        }
    }
}

const Decided = struct {
    /// Mirror fields that name no field of the original because this file
    /// reshapes them -- an error set into a number, storage into its bytes.
    reshaped: []const []const u8 = &.{},
    /// Fields of the original that do not cross, each for a stated reason.
    left_behind: []const []const u8 = &.{},
};

/// Storage a value owns through an allocator. Its *contents* cross; the
/// ownership does not, and the receiving side owns its own copy.
const owned_storage: []const []const u8 = &.{ "allocator", "diagnostic_storage", "diagnostic_len" };

comptime {
    mirrors(TerminalResult, control.TerminalResult, .{
        .reshaped = &.{"diagnostic"},
        .left_behind = owned_storage,
    });
    mirrors(CompactTerminalResult, control.CompactTerminalResult, .{
        .reshaped = &.{"diagnostic"},
        .left_behind = owned_storage,
    });
    mirrors(PendingUiRequest, surface.PendingUiRequest, .{
        .left_behind = &.{"allocator"},
    });
    mirrors(CheckpointDescription, checkpoint.Description, .{
        .left_behind = &.{"allocator"},
    });
    mirrors(BeginRunFailure, surface.BeginRunFailure, .{
        .reshaped = &.{"error_code"},
        // The error itself crosses as its registered number.
        .left_behind = &.{"err"},
    });
    mirrors(SessionOpenOptions, surface.SessionOpenOptions, .{});
    mirrors(CallbackRejection, control.CallbackRejection, .{
        .reshaped = &.{ "failure_code", "failure_unnamed" },
        // Any error in the program, so it crosses as its number when the
        // registry names it and as "present but unnamed" when it does not.
        .left_behind = &.{"failure"},
    });
}

const testing = std.testing;

test "an outcome's error survives as its registered number" {
    const failed: surface.CloseOutcome = .{ .failure = .{
        .err = error.SessionPoisoned,
        .session_disposition = .poisoned,
    } };
    const wire = CloseOutcome.from(failed);
    const back = wire.into() orelse return error.UnknownCode;
    try testing.expectEqual(@as(anyerror, error.SessionPoisoned), back.failure.err);
    try testing.expectEqual(contract.SessionDisposition.poisoned, back.failure.session_disposition);
    try testing.expectEqual(CloseOutcome.closed, CloseOutcome.from(.closed));
    try testing.expectEqual(surface.CloseOutcome.closed, (@as(CloseOutcome, .closed)).into().?);

    const begin = BeginRunFailure.from(.{
        .err = error.SessionNotIdle,
        .session_disposition = .reusable,
    });
    try testing.expectEqual(@as(anyerror, error.SessionNotIdle), (begin.into().?).err);
}

test "a number this build does not register is refused, not approximated" {
    const unknown: CloseOutcome = .{ .failure = .{
        .error_code = std.math.maxInt(u16),
        .session_disposition = .reusable,
    } };
    try testing.expect(unknown.into() == null);
    const begin: BeginRunFailure = .{
        .error_code = 0,
        .session_disposition = .reusable,
    };
    try testing.expect(begin.into() == null);
}

test "every shape round-trips through the structural codec" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const outcome: CloseOutcome = .{ .failure = .{
        .error_code = error_code.encode(error.SessionClosing),
        .session_disposition = .closing,
    } };
    const outcome_bytes = try payload.encodeAlloc(CloseOutcome, allocator, outcome);
    const outcome_back = try payload.decodeExact(CloseOutcome, allocator, outcome_bytes);
    try testing.expectEqual(outcome.failure.error_code, outcome_back.failure.error_code);

    const pending: PendingUiRequest = .{
        .session_id = 3,
        .run_id = 4,
        .request_id = 5,
        .input_adopted_count = 6,
        .json = "{\"permission\":{}}",
    };
    const pending_bytes = try payload.encodeAlloc(PendingUiRequest, allocator, pending);
    const pending_back = try payload.decodeExact(PendingUiRequest, allocator, pending_bytes);
    try testing.expectEqualStrings(pending.json, pending_back.json);
    try testing.expectEqual(pending.request_id, pending_back.request_id);

    const terminal: TerminalResult = .{
        .diagnostic = "core said no",
        .diagnostic_truncated = true,
        .abi_status = null,
        .raw_status_code = 7,
        .stop_reason = null,
        .raw_stop_reason_code = null,
        .abort_status = null,
        .raw_abort_status_code = null,
        .termination_signal = null,
        .file_changes_lost = false,
        .event_delivery_lost = true,
        .receipts = .{},
        .failure = null,
        .session_disposition_at_completion = .reusable,
        .durable_budget = null,
        .input_counts = null,
        .first_callback_rejection = null,
        .first_host_failure = null,
        .controlled_callback_close = null,
        .model_error = null,
    };
    const terminal_bytes = try payload.encodeAlloc(TerminalResult, allocator, terminal);
    const terminal_back = try payload.decodeExact(TerminalResult, allocator, terminal_bytes);
    try testing.expectEqualStrings(terminal.diagnostic, terminal_back.diagnostic);
    try testing.expectEqual(true, terminal_back.event_delivery_lost);
    try testing.expectEqual(@as(?u32, 7), terminal_back.raw_status_code);
}

test "a terminal result's diagnostic travels as its bytes, not its storage" {
    // The original holds a buffer and a used length; the mirror holds exactly
    // the used bytes, so a receiver cannot read past them.
    var storage: [32]u8 = @splat('x');
    @memcpy(storage[0..5], "short");
    const original: control.TerminalResult = .{
        .allocator = testing.allocator,
        .diagnostic_storage = &storage,
        .diagnostic_len = 5,
        .diagnostic_truncated = false,
        .abi_status = null,
        .raw_status_code = null,
        .stop_reason = null,
        .raw_stop_reason_code = null,
        .abort_status = null,
        .raw_abort_status_code = null,
        .termination_signal = null,
        .failure = null,
        .session_disposition_at_completion = .reusable,
    };
    const wire = TerminalResult.from(&original);
    try testing.expectEqualStrings("short", wire.diagnostic);
    try testing.expectEqual(@as(usize, 5), wire.diagnostic.len);
}
