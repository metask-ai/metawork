//! MetaWork Agent Runtime over the bundle-owned typed SDK and ABI v1.
//! Core callbacks validate through the SDK, retain only Agent-owned data, and
//! feed a bounded sink. No callback calls WebView or registers desktop tools.

const std = @import("std");
const sdk = @import("metask_agentcore");
const wire = sdk.types;
const event_pump = @import("event_pump");
const catalog = @import("agent_catalog");

pub const OwnedCoreEvent = event_pump.OwnedCoreEvent;
pub const Status = sdk.Status;
pub const StopReason = sdk.StopReason;
pub const UiRequest = sdk.UiRequest;
pub const UiResponse = sdk.UiResponse;
pub const Answer = sdk.protocol.Answer;
pub const PermissionChoice = sdk.protocol.PermissionChoice;
pub const ParsedUiRequest = sdk.ParsedUiRequest;
pub const CatalogHealth = catalog.Health;
pub const CatalogIssueCode = catalog.IssueCode;
pub const CatalogIssue = catalog.Issue;
pub const CatalogSkill = catalog.Skill;
pub const CatalogProjection = catalog.Projection;
pub const CatalogLease = catalog.Lease;
pub const CatalogAcquisition = catalog.Acquisition;
pub const CatalogQuery = catalog.Query;

pub fn decodeUiRequest(
    allocator: std.mem.Allocator,
    encoded: []const u8,
) sdk.DecodeError!ParsedUiRequest {
    return sdk.decodeUiRequest(allocator, encoded);
}

pub fn decodeCoreEvent(
    allocator: std.mem.Allocator,
    encoded: []const u8,
) sdk.DecodeError!sdk.ParsedCoreEvent {
    return sdk.decodeCoreEvent(allocator, encoded);
}

const default_builtin_tools = [_][]const u8{ "Read", "Bash", "Edit", "AskUserQuestion" };

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
        .bypass => wire.PERMISSION_BYPASS,
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

    pub fn diagnostic(self: *const TerminalResult) []const u8 {
        return self.diagnostic_storage[0..self.diagnostic_len];
    }

    pub fn deinit(self: *TerminalResult) void {
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
    bypass,
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
    allowed_tools: []const []const u8 = &default_builtin_tools,
};

pub const Limits = struct {
    max_sessions: usize,
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
    SessionIdExhausted,
    NoSuchRun,
    NoPendingUiRequest,
    StaleUiResponse,
    InvalidUiResponse,
    StateNotReached,
    SessionDestroyFailed,
    RuntimeDestroyFailed,
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
    shutting_down: std.atomic.Value(bool) = .init(false),
    shutdown_running: bool = false,
    shutdown_complete: bool = false,
    last_shutdown_error: ?Error = null,
    active_catalog_calls: usize = 0,
    active_catalog_leases: usize = 0,
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
        _ = std.math.mul(usize, limits.event_capacity, limits.max_event_bytes) catch
            return error.InvalidLimits;
        const self = try allocator.create(Runtime);
        errdefer allocator.destroy(self);
        const sessions = try allocator.alloc(?*Session, limits.max_sessions);
        errdefer allocator.free(sessions);
        @memset(sessions, null);
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
        var builtin_views: [default_builtin_tools.len]wire.BytesViewV1 = undefined;
        for (default_builtin_tools, 0..) |name, index|
            builtin_views[index] = sdk.bytesView(name);
        runtime_config.builtin_tools = &builtin_views;
        runtime_config.builtin_tool_count = builtin_views.len;
        runtime_config.host_tools = null;
        runtime_config.host_tool_count = 0;
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

    pub fn createSession(
        self: *Runtime,
        options: SessionOpenOptions,
    ) (Error || std.mem.Allocator.Error)!*Session {
        return (try self.createSessionRoute(options)).session;
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
        var slot: ?usize = null;
        for (self.sessions, 0..) |entry, index| {
            if (entry == null) {
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
        var config = std.mem.zeroes(wire.SessionConfigV1);
        config.struct_size = @sizeOf(wire.SessionConfigV1);
        config.provider_kind_code = providerKindCode(options.provider);
        config.permission_mode_code = permissionModeCode(options.permission_mode);
        config.shell_policy_code = shellPolicyCode(options.shell_policy);
        config.api_key = sdk.bytesView(secret);
        config.model = sdk.bytesView(options.model);
        config.base_url = sdk.bytesView(options.base_url);
        config.workspace_root = sdk.bytesView(workspace_root);
        config.workspace_home = sdk.bytesView(workspace_home);
        const skill_selection = allSkillsEnabledSelection();
        config.skill_catalog = if (options.skill_catalog) |lease|
            catalog.rawHandle(lease)
        else
            null;
        config.skill_selection = if (options.skill_catalog != null)
            &skill_selection
        else
            null;
        config.permission_rules = null;
        const allowed_views = try self.allocator.alloc(wire.BytesViewV1, options.allowed_tools.len);
        defer self.allocator.free(allowed_views);
        for (options.allowed_tools, 0..) |name, index|
            allowed_views[index] = sdk.bytesView(name);
        config.allowed_tools = if (allowed_views.len == 0) null else allowed_views.ptr;
        config.allowed_tool_count = allowed_views.len;

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
        while (self.active_catalog_calls != 0)
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
        for (self.sessions) |entry| {
            if (entry) |session| {
                session.deinit();
                self.allocator.destroy(session);
            }
        }
        self.events.deinit();
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
                .idle, .running, .waiting_ui, .queued => error.NoSuchRun,
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
            .queued, .running, .waiting_ui => return error.SessionNotIdle,
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
        if (!isSkillUpdateStatus(status)) return self.failSkillUpdateContract();
        return switch (status) {
            .ok => {},
            .busy => error.SessionNotIdle,
            .invalid_state => {
                self.state = .poisoned;
                return error.SessionPoisoned;
            },
            else => error.CatalogRefreshFailed,
        };
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

    pub fn respondUi(
        self: *Session,
        run_id: u64,
        request_id: u64,
        response: sdk.UiResponse,
    ) (Error || std.mem.Allocator.Error)!void {
        self.lock();
        defer self.unlock();
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
        const should_abort_now = self.core_call_in_progress and !self.run_done and
            self.abort_calls_in_progress == 0 and self.raw_abort_status_code == null;
        if (should_abort_now) self.abort_calls_in_progress += 1;
        const run_id = self.active_run_id;
        self.state = .closing;
        const signal: TerminationSignal = .{ .interrupted = interruption };
        if (!self.run_done) setTerminationSignalLocked(self, signal);
        wakeUiLocked(self);
        if (!self.run_done and !self.run_started) self.finishPreparedRunLocked();
        self.broadcast();
        self.unlock();

        if (should_abort_now) self.abortRun(run_id, signal);

        self.lock();
        while (!self.run_done and !self.run_started) self.wait();
        const should_abort_late = !should_abort_now and self.core_call_in_progress and
            !self.run_done and self.abort_calls_in_progress == 0 and
            self.raw_abort_status_code == null;
        if (should_abort_late) self.abort_calls_in_progress += 1;
        self.unlock();
        if (should_abort_late) self.abortRun(run_id, signal);

        self.lock();
        while (!self.run_done) self.wait();
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
        if (!diagnostic_valid) {
            self.dependency_contract_failure = true;
            failure = .dependency_contract;
            self.state = .poisoned;
        } else if (typed_status) |known_status| {
            const poisons_session = runStatusPoisonsSession(known_status);
            if (poisons_session == null) {
                self.dependency_contract_failure = true;
                failure = .dependency_contract;
                self.state = .poisoned;
            }
            if (!self.dependency_contract_failure and known_status == .ok) {
                if (result.struct_size != @sizeOf(wire.RunResultV1) or !allZero(&result.reserved)) {
                    self.dependency_contract_failure = true;
                    failure = .dependency_contract;
                    self.state = .poisoned;
                } else {
                    raw_stop_reason_code = result.stop_reason_code;
                    if (sdk.StopReason.fromCode(result.stop_reason_code)) |reason| {
                        stop_reason = reason;
                    } else |_| {
                        self.dependency_contract_failure = true;
                        failure = .dependency_contract;
                        self.state = .poisoned;
                    }
                }
            } else if (!self.dependency_contract_failure) {
                if (known_status == .callback_failed and self.termination_signal == null)
                    setTerminationSignalLocked(self, .{ .callback_failure = .event });
                failure = .abi_status;
                if (poisons_session.?) self.state = .poisoned;
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
        const terminal = self.takeTerminalResultLocked(null, null, null, null, null);
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
        };
    }

    fn dispositionLocked(self: *const Session) SessionDisposition {
        return switch (self.state) {
            .poisoned => .poisoned,
            .closing, .closed => .closing,
            .idle, .queued, .running, .waiting_ui => .reusable,
        };
    }

    fn deinit(self: *Session) void {
        std.debug.assert(self.state == .closed);
        std.debug.assert(self.active_refs == 0);
        std.debug.assert(self.active_callback_refs == 0);
        self.control_block.deinit();
        self.agent_runtime.allocator.destroy(self.control_block);
        if (self.run_input) |*input|
            input.deinit(self.agent_runtime.allocator);
        if (self.terminal_diagnostic) |buffer| self.agent_runtime.allocator.free(buffer);
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
        var parsed = sdk.decodeCoreEvent(self.agent_runtime.allocator, encoded) catch {
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
        _ = self.retainCoreCallback(raw_run) orelse return wire.UI_FATAL;
        defer self.releaseCoreCallback();

        const encoded_request = sdk.borrowedBytes(request_json) catch {
            self.recordTerminationSignal(.{ .callback_failure = .ui });
            return wire.UI_FATAL;
        };
        if (encoded_request.len > self.agent_runtime.max_ui_request_bytes) {
            self.recordTerminationSignal(.{ .event_pump_failure = .event_too_large });
            return wire.UI_FATAL;
        }
        var parsed = sdk.decodeUiRequest(self.agent_runtime.allocator, encoded_request) catch {
            self.recordTerminationSignal(.{ .callback_failure = .ui });
            return wire.UI_FATAL;
        };
        defer parsed.deinit();
        const owned_request = self.agent_runtime.allocator.dupe(u8, encoded_request) catch {
            self.recordTerminationSignal(.{ .event_pump_failure = .allocation });
            return wire.UI_FATAL;
        };

        self.lock();
        if (!self.coreIdentityHealthyLocked()) {
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
                .poisoned, .closing, .closed => {},
                .running, .waiting_ui => unreachable,
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

fn isSkillUpdateStatus(status: sdk.Status) bool {
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
        => false,
    };
}

fn runStatusPoisonsSession(status: sdk.Status) ?bool {
    return switch (status) {
        .out_of_memory,
        .invalid_state,
        .core_error,
        .callback_failed,
        .internal_error,
        => true,
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
        => false,
        .too_late,
        .skill_catalog_invalid,
        .stale_compact,
        => null,
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
        => false,
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
