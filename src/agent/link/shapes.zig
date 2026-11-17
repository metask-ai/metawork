//! The explicit wire shapes for the payload types the structural codec
//! refuses.
//!
//! `crossings.zig` records which types owe a shape and why; this is where the
//! shapes live. Each one is a plain-data mirror that `payload.zig` can carry,
//! plus the conversion in whichever direction is meaningful without the other
//! half's context. A mirror is never a second source of truth: every field it
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

const control = contract.control;
const surface = contract.surface;

/// An id standing in for an object that stays on the far side. Zero is never
/// a live handle, so a decoded zero is a protocol violation rather than a
/// null object.
pub const HandleId = struct {
    value: u64,

    pub const none: HandleId = .{ .value = 0 };

    pub fn valid(self: HandleId) bool {
        return self.value != 0;
    }
};

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
};

/// `checkpoint.Outcome`: the export's identity and the description, or the
/// typed failure. The bytes stayed on the far side's disk.
pub const CheckpointOutcome = union(enum) {
    success: struct {
        checkpoint: checkpoint.Export,
        description: CheckpointDescription,
    },
    failure: checkpoint.Failure,
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
};

comptime {
    // Every shape in this file is one the wire can actually carry. Without
    // this, a mirror could pick up a field that is itself unshippable and the
    // failure would surface at the first call instead of the build.
    payload.requireStructural(HandleId);
    payload.requireStructural(CloseOutcome);
    payload.requireStructural(CallbackRejection);
    payload.requireStructural(BeginRunFailure);
    payload.requireStructural(TerminalResult);
    payload.requireStructural(CompactTerminalResult);
    payload.requireStructural(CheckpointDescription);
    payload.requireStructural(CheckpointOutcome);
    payload.requireStructural(PendingUiRequest);
}

/// Asserts that a mirror and its original describe the same thing: every
/// mirror field must exist on the original, under the same name, except the
/// ones this file deliberately reshapes. A field added to the original is not
/// caught here -- `crossings.zig` catches that by re-classifying the type --
/// but a mirror field that no longer corresponds to anything is.
fn mirrors(comptime Mirror: type, comptime Origin: type, comptime reshaped: []const []const u8) void {
    comptime {
        for (@typeInfo(Mirror).@"struct".fields) |field| {
            for (reshaped) |name| {
                if (std.mem.eql(u8, name, field.name)) break;
            } else if (!@hasField(Origin, field.name)) @compileError(
                @typeName(Mirror) ++ "." ++ field.name ++ " does not name a field of " ++
                    @typeName(Origin) ++ ", and is not listed as reshaped",
            );
        }
    }
}

comptime {
    mirrors(TerminalResult, control.TerminalResult, &.{"diagnostic"});
    mirrors(CompactTerminalResult, control.CompactTerminalResult, &.{"diagnostic"});
    mirrors(PendingUiRequest, surface.PendingUiRequest, &.{});
    mirrors(CheckpointDescription, checkpoint.Description, &.{});
    mirrors(BeginRunFailure, surface.BeginRunFailure, &.{"error_code"});
}

const testing = std.testing;

test "a handle id of zero is never a live handle" {
    try testing.expect(!HandleId.none.valid());
    try testing.expect((HandleId{ .value = 1 }).valid());
}

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
