//! Session execution values that do not retain a Session or Runtime.
//!
//! This module deliberately contains no Session lifecycle handles.  Control
//! blocks, leases, callbacks, and routes remain in session.zig because those
//! values participate directly in Session quiescence and termination.

const std = @import("std");
const sdk = @import("metask_agentcore");

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
/// This is execution control state, not a durable outcome.
pub const TerminationSignal = union(enum) {
    interrupted: ExternalInterruption,
    permission_required,
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
    failure: ?TerminalFailure,
    session_disposition_at_completion: SessionDisposition,
    durable_budget: ?DurableBudgetObservation = null,
    input_counts: ?InputCounts = null,

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
