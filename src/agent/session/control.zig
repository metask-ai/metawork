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
