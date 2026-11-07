//! Session execution values that do not retain a Session or Runtime.
//!
//! This module deliberately contains no Session lifecycle handles.  Control
//! blocks, leases, callbacks, and routes remain in session.zig because those
//! values participate directly in Session quiescence and termination.

const std = @import("std");
const sdk = @import("metask_agentcore");
pub const ModelError = @import("model_error.zig").ModelError;

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

pub const CredentialUpdateFailure = enum { rejected, resource_limit, dependency_contract };

/// The single mutable, first-writer-wins termination latch for an active Run.
/// This is execution control state, not a durable outcome.
pub const TerminationSignal = union(enum) {
    interrupted: ExternalInterruption,
    permission_required,
    callback_failure: CallbackFailure,
    event_pump_failure: EventPumpFailure,
    event_consumer_notification_failure: EventConsumerNotificationFailure,
    credential_update_failure: CredentialUpdateFailure,
};

/// A real Host failure, independent of the first control request.
pub const HostFailure = union(enum) {
    callback_failure: CallbackFailure,
    event_pump_failure: EventPumpFailure,
    event_consumer_notification_failure: EventConsumerNotificationFailure,
    credential_update_failure: CredentialUpdateFailure,

    pub fn fromSignal(signal: TerminationSignal) ?HostFailure {
        return switch (signal) {
            .interrupted, .permission_required => null,
            .callback_failure => |reason| .{ .callback_failure = reason },
            .event_pump_failure => |reason| .{ .event_pump_failure = reason },
            .event_consumer_notification_failure => |reason| .{ .event_consumer_notification_failure = reason },
            .credential_update_failure => |reason| .{ .credential_update_failure = reason },
        };
    }

    pub fn asSignal(self: HostFailure) TerminationSignal {
        return switch (self) {
            .callback_failure => |reason| .{ .callback_failure = reason },
            .event_pump_failure => |reason| .{ .event_pump_failure = reason },
            .event_consumer_notification_failure => |reason| .{ .event_consumer_notification_failure = reason },
            .credential_update_failure => |reason| .{ .credential_update_failure = reason },
        };
    }
};

pub const TerminationEffect = enum {
    not_requested,
    prevented_core_call,
    aborted,
    controlled_close,
    not_aborted,
    unknown,
};

pub const TerminalFailure = enum {
    abi_status,
    dependency_contract,
};

/// First observation under this Session's mutex, not a global causal ordering.
/// Contains only fixed enums and counts; callback payloads never enter it.
pub const CallbackRejection = struct {
    pub const Boundary = enum { admission, event_decode, input_event, model_error, event_copy, event_pump, notifier, ui_decode, ui_admission, ui_response, core_return };
    pub const Reason = enum { invalid_context, identity_mismatch, invalid_state, counter_exhausted, invalid_bytes, decode_failed, oversized, allocation, queue_rejected, consumer_unavailable, unsupported_request, invalid_input_transition, callbacks_in_flight, invalid_response, invalid_model_error, duplicate_model_error, model_error_after_terminal, missing_model_error, unexpected_model_error, invalid_terminal, fatal_returned_ok };
    boundary: Boundary,
    reason: Reason,
    event: ?CoreEventKind = null,
    failure: ?anyerror = null,
    encoded_bytes: ?usize = null,
    host_run_id: u64 = 0,
    observed_run_id: ?u64 = null,
    session_handle_matches: ?bool = null,
    session_identity_matches: ?bool = null,
    state: SessionState = .idle,
    input_adoption: ?struct { id: u64, sequence: u32, turn: u32 } = null,
};
pub const CoreEventKind = std.meta.Tag(sdk.CoreEvent);

pub const SessionDisposition = enum {
    reusable,
    poisoned,
    closing,
};

pub const DurableBudgetObservation = struct {
    durable_usage_bytes: u64,
    required_checkpoint_bytes: u64,
};

pub const InputCounts = struct {
    accepted: u32,
    adopted: u32,
};

pub const InputObservation = struct {
    ready: bool = false,
    accepted: u32 = 0,
    adopted: u32 = 0,
    submitting: bool = false,

    pub fn blocksAutomaticAllow(self: InputObservation) bool {
        return self.submitting or self.accepted > self.adopted;
    }
};

pub const InputRejection = enum {
    stale_run,
    not_ready,
    stopping,
    unsupported_input,
    invalid_input,
    resource_limit,
    checkpoint_budget_required,
    too_late,
    unavailable,
};

pub const InputSubmission = union(enum) {
    accepted: u32,
    rejected: InputRejection,
    /// A dependency contract failure cannot be reported as a refusal.
    unknown,
};

/// Correlation facts only. No text is retained or scheduled by this ledger.
/// All access is protected by the owning Session mutex.
pub const SubmittedInputs = struct {
    const Entry = struct {
        id: u64,
        sequence: ?u32 = null,
        accepted: bool = false,
    };
    entries: [sdk.types.MAX_SUBMITTED_INPUTS_V1]?Entry = @splat(null),
    accepted: u32 = 0,
    adopted: u32 = 0,

    pub fn register(self: *SubmittedInputs, id: u64) error{ InvalidInput, ResourceLimit }!usize {
        if (id == 0) return error.InvalidInput;
        for (self.entries) |entry| if (entry) |e| {
            if (e.id == id) return error.InvalidInput;
        };
        for (&self.entries, 0..) |*entry, i| if (entry.* == null) {
            entry.* = .{ .id = id };
            return i;
        };
        return error.ResourceLimit;
    }

    pub fn receipt(self: *SubmittedInputs, slot: usize, sequence: u32) bool {
        const entry = &self.entries[slot].?;
        if (sequence == 0 or sequence > self.entries.len or entry.accepted) return false;
        if (entry.sequence) |observed| if (observed != sequence) return false;
        for (self.entries, 0..) |other, i| if (other) |e| {
            if (i != slot and e.sequence == sequence) return false;
        };
        entry.sequence = sequence;
        entry.accepted = true;
        self.accepted += 1;
        return true;
    }

    pub fn refuse(self: *SubmittedInputs, slot: usize) bool {
        if (self.entries[slot].?.sequence != null) return false;
        self.entries[slot] = null;
        return true;
    }

    pub fn adopt(self: *SubmittedInputs, id: u64, sequence: u32, turn: u32) bool {
        if (turn == 0 or sequence != self.adopted + 1) return false;
        for (&self.entries) |*entry| if (entry.*) |*e| {
            if (e.id != id) continue;
            if (e.sequence) |receipt_sequence| if (receipt_sequence != sequence) return false;
            for (self.entries) |other| if (other) |o| {
                if (o.id != id and o.sequence == sequence) return false;
            };
            e.sequence = sequence;
            self.adopted = sequence;
            return true;
        };
        return false;
    }

    pub fn reconcile(self: *const SubmittedInputs, accepted: u32, adopted: u32) bool {
        if (accepted != self.accepted or adopted > accepted or adopted < self.adopted) return false;
        for (1..@as(usize, accepted) + 1) |sequence| {
            var found = false;
            for (self.entries) |entry| if (entry) |e| {
                if (e.accepted and e.sequence == @as(u32, @intCast(sequence))) found = true;
            };
            if (!found) return false;
        }
        return true;
    }
};

pub const tool_route_digest_bytes = std.crypto.hash.sha2.Sha256.digest_length;
pub fn toolRouteDigest(id: []const u8) [tool_route_digest_bytes]u8 {
    var digest: [tool_route_digest_bytes]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(id, &digest, .{});
    return digest;
}

/// Only exact successful tool-result matches may enter this bounded tail.
/// A route digest retains tool identity without copying raw tool text.
pub const TerminalReceipts = struct {
    const delivery = @import("agent_file_delivery");
    const images = @import("../image_generation.zig");
    pub const GeneratedImage = struct {
        tool_route_digest: [tool_route_digest_bytes]u8,
        receipt: images.Receipt,
    };
    delivered_files: [delivery.max_receipts_per_run]?delivery.Receipt = @splat(null),
    generated_images: [images.production_limits.sends_per_run]?GeneratedImage = @splat(null),

    pub fn isEmpty(self: *const TerminalReceipts) bool {
        for (self.delivered_files) |entry| if (entry != null) return false;
        for (self.generated_images) |entry| if (entry != null) return false;
        return true;
    }
};

/// Immutable Agent-owned facts for exactly one begun Run. The caller must copy
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
    /// Supplemental typed file-change observations were dropped locally.
    /// This fact never changes the Agent terminal outcome.
    file_changes_lost: bool = false,
    /// Validated events omitted after the consumer stopped, not a Core failure.
    event_delivery_lost: bool = false,
    receipts: TerminalReceipts = .{},
    failure: ?TerminalFailure,
    session_disposition_at_completion: SessionDisposition,
    durable_budget: ?DurableBudgetObservation = null,
    input_counts: ?InputCounts = null,
    first_callback_rejection: ?CallbackRejection = null,
    first_host_failure: ?HostFailure = null,
    controlled_ui_close: ?ExternalInterruption = null,
    /// Validated supplemental observation; only OK + api_error makes it the
    /// explanation of the Run's model failure. Dependency failures suppress it.
    model_error: ?ModelError = null,

    pub fn coreWasInvoked(self: *const TerminalResult) bool {
        return self.raw_status_code != null;
    }

    pub fn terminationEffect(self: *const TerminalResult) TerminationEffect {
        if (self.failure == .dependency_contract) return .unknown;
        if (self.controlled_ui_close != null) return .controlled_close;
        if (self.termination_signal == null) return .not_requested;
        if (self.raw_status_code == null) return .prevented_core_call;
        if (self.abi_status == .ok and self.stop_reason == .aborted) return .aborted;
        if (self.abi_status == .ok) return .not_aborted;
        return .unknown;
    }

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

    pub fn coreWasInvoked(self: *const CompactTerminalResult) bool {
        return self.raw_status_code != null;
    }

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
