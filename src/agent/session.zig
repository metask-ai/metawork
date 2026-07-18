//! MetaWork Agent Runtime over the bundle-owned typed SDK and ABI v1.
//! Core callbacks validate through the SDK, retain only Agent-owned data, and
//! feed a bounded sink. No callback calls WebView or registers desktop tools.

const std = @import("std");
const sdk = @import("metacodes_agentcore");
const wire = sdk.types;
const event_pump = @import("event_pump");

pub const EventEnvelope = event_pump.EventEnvelope;

const default_builtin_tools = [_][]const u8{ "Read", "Bash", "Edit", "AskUserQuestion" };

pub const SessionState = enum {
    idle,
    queued,
    running,
    waiting_ui,
    poisoned,
    closing,
    closed,
};

pub const HostCause = enum {
    user_cancel,
    timeout,
    session_close,
    host_shutdown,
    event_pipeline_failure,
    queue_capacity_failure,
    ui_pipeline_failure,
    dependency_contract_failure,
};

pub const RunOutcome = enum {
    completed,
    stopped,
    cancelled,
    interrupted,
    failed,
    dependency_contract_failure,
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
        cause: HostCause,
    ) TerminationRequestResult {
        std.debug.assert(!self.released);
        return self.block.session.requestControlledTermination(
            self.run_id,
            self.generation,
            cause,
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

    pub fn execute(self: *Run) void {
        std.debug.assert(!self.executed);
        self.executed = true;
        self.session.executeBegunRun(self.run_id, self.generation);
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

pub const SessionOpenOptions = struct {
    provider_kind_code: u32,
    permission_mode_code: u32,
    shell_policy_code: u32,
    credential: []const u8,
    model: []const u8,
    base_url: []const u8 = "",
    workspace: WorkspaceInput,
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
    ui_request_timeout: std.Io.Duration = .fromSeconds(30),
    event_ready_notifier: ?EventReadyNotifier = null,
};

pub const SessionSnapshot = struct {
    session_id: u64,
    state: SessionState,
    workspace_root: []const u8,
    active_run_id: u64,
    pending_ui_request_id: ?u64,
    cause: ?HostCause,
    last_status: ?u32,
    last_abort_status: ?u32,
    last_stop_reason_code: ?u32,
    last_outcome: ?RunOutcome,
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
    HostShuttingDown,
    SessionCapacity,
    UnknownSession,
    SessionNotClosed,
    CoreCallFailed,
    QueueFull,
    SessionNotIdle,
    SessionPoisoned,
    SessionClosing,
    PromptTooLarge,
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
    ui_request_timeout: std.Io.Duration,
    event_ready_notifier: ?EventReadyNotifier,
    events: event_pump.EventPump,
    sessions_mutex: std.Io.Mutex = .init,
    shutdown_condition: std.Io.Condition = .init,
    sessions: []?*Session,
    shutting_down: std.atomic.Value(bool) = .init(false),
    shutdown_running: bool = false,
    shutdown_complete: bool = false,
    last_shutdown_error: ?Error = null,
    next_session_id: u64 = 0,

    /// `raw_api` is borrowed for the Agent Runtime lifetime. Bundle discovery tables
    /// are static; injected test tables must provide the same lifetime.
    pub fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
        raw_api: *const wire.ApiV1,
        limits: Limits,
    ) (Error || std.mem.Allocator.Error || error{UnsupportedAbi})!*Runtime {
        if (limits.max_sessions == 0 or limits.max_prompt_bytes == 0 or limits.event_capacity == 0 or
            limits.event_bytes == 0 or limits.per_session_event_capacity == 0 or
            limits.per_session_event_bytes == 0 or limits.max_event_bytes == 0 or
            limits.event_enqueue_timeout.nanoseconds <= 0 or limits.max_ui_request_bytes == 0 or
            limits.max_ui_response_bytes == 0 or limits.ui_request_timeout.nanoseconds <= 0)
            return error.InvalidLimits;
        _ = std.math.mul(usize, limits.event_capacity, limits.max_event_bytes) catch
            return error.InvalidLimits;
        const api = try sdk.Api.validate(raw_api);
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
            .ui_request_timeout = limits.ui_request_timeout,
            .event_ready_notifier = limits.event_ready_notifier,
            .events = events,
            .sessions = sessions,
        };
        return self;
    }

    pub fn createSession(
        self: *Runtime,
        options: SessionOpenOptions,
    ) (Error || std.mem.Allocator.Error)!*Session {
        try validateWorkspace(options.workspace);
        if (options.credential.len == 0 or options.model.len == 0)
            return error.CoreCallFailed;

        self.sessions_mutex.lockUncancelable(self.io);
        defer self.sessions_mutex.unlock(self.io);
        if (self.shutting_down.load(.acquire)) return error.HostShuttingDown;
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
        session.* = .{
            .agent_runtime = self,
            .id = session_id,
            .workspace_root = workspace_root,
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
        config.provider_kind_code = options.provider_kind_code;
        config.permission_mode_code = options.permission_mode_code;
        config.shell_policy_code = options.shell_policy_code;
        config.api_key = sdk.bytesView(secret);
        config.model = sdk.bytesView(options.model);
        config.base_url = sdk.bytesView(options.base_url);
        config.workspace_root = sdk.bytesView(workspace_root);
        config.workspace_home = sdk.bytesView(workspace_root);
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
        return session;
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
        const sessions = self.sessions;
        self.sessions_mutex.unlock(self.io);

        var first_error: ?Error = null;
        for (sessions) |entry| {
            if (entry) |session| {
                session.close(.host_shutdown) catch |err| if (first_error == null) {
                    first_error = err;
                };
            }
        }
        if (first_error != null) return self.finishShutdown(first_error);

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
        if (self.shutting_down.load(.acquire)) return error.HostShuttingDown;

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

    pub fn takeEvent(self: *Runtime) ?EventEnvelope {
        return self.events.takeFair();
    }

    fn notifyEventConsumer(self: *Runtime) EventReadyNotification {
        const notifier = self.event_ready_notifier orelse return .scheduled;
        return notifier.notify();
    }

    pub fn requestWake(self: *Runtime) bool {
        return self.notifyEventConsumer() != .unavailable;
    }

    pub fn failRun(self: *Runtime, session_id: u64, run_id: u64, cause: HostCause) Error!void {
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
        return session.requestCancel(run_id, cause);
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

pub const Session = struct {
    agent_runtime: *Runtime,
    id: u64,
    raw: ?*wire.SessionHandle = null,
    workspace_root: []u8,
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
    run_done: bool = true,
    prompt: ?[]u8 = null,
    cause: ?HostCause = null,
    last_status: ?u32 = null,
    last_abort_status: ?u32 = null,
    last_stop_reason_code: ?u32 = null,
    last_outcome: ?RunOutcome = null,
    cancel_requested: bool = false,
    active_refs: usize = 0,
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
    pub fn prepareRun(self: *Session, prompt: []const u8) (Error || std.mem.Allocator.Error)!u64 {
        if (prompt.len > self.agent_runtime.max_prompt_bytes) return error.PromptTooLarge;
        const owned_prompt = try self.agent_runtime.allocator.dupe(u8, prompt);
        errdefer self.agent_runtime.allocator.free(owned_prompt);
        self.lock();
        if (self.agent_runtime.shutting_down.load(.acquire)) {
            self.unlock();
            return error.HostShuttingDown;
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
        self.next_run_id += 1;
        self.next_run_generation += 1;
        const run_id = self.next_run_id;
        self.active_run_id = run_id;
        self.active_run_generation = self.next_run_generation;
        self.run_started = false;
        self.core_call_in_progress = false;
        self.run_done = false;
        self.prompt = owned_prompt;
        self.cause = null;
        self.last_status = null;
        self.last_abort_status = null;
        self.last_stop_reason_code = null;
        self.last_outcome = null;
        self.cancel_requested = false;
        self.state = .queued;
        self.unlock();
        return run_id;
    }

    /// Installs the generation-checked termination control and transfers
    /// execution ownership from Workbench to Agent. A successful call must be
    /// followed by exactly one `Run.execute` and `Run.deinit`.
    pub fn beginRun(self: *Session, run_id: u64) Error!Run {
        self.lock();
        if (run_id == 0 or run_id != self.active_run_id) {
            self.unlock();
            return error.NoSuchRun;
        }
        if (self.state != .queued) {
            const begin_error: Error = switch (self.state) {
                .poisoned => error.SessionPoisoned,
                .closing, .closed => error.SessionClosing,
                .idle, .running, .waiting_ui, .queued => error.NoSuchRun,
            };
            if ((self.state == .closing or self.state == .closed) and !self.run_done and
                !self.run_started)
                self.finishBeforeCoreCallLocked();
            self.unlock();
            return begin_error;
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
        return .{
            .session = self,
            .run_id = run_id,
            .generation = generation,
            .base_lease = .{
                .block = self.control_block,
                .run_id = run_id,
                .generation = generation,
            },
        };
    }

    /// Transitional compatibility entry point for isolated contract probes.
    /// Product code must use `beginRun` so it can publish `RunControl` before
    /// entering the synchronous ABI call.
    pub fn executePreparedRun(self: *Session) void {
        self.lock();
        const run_id = self.active_run_id;
        self.unlock();
        var run = self.beginRun(run_id) catch return;
        defer run.deinit();
        run.execute();
    }

    pub fn cancelPreparedRun(self: *Session, run_id: u64, cause: HostCause) Error!void {
        self.lock();
        if (run_id == 0 or run_id != self.active_run_id or self.state != .queued) {
            self.unlock();
            return error.NoSuchRun;
        }
        self.cancel_requested = true;
        setCauseLocked(self, cause);
        self.unlock();
        self.finishCancelledQueuedRun();
    }

    pub fn requestCancel(self: *Session, run_id: u64, cause: HostCause) Error!void {
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
        setCauseLocked(self, cause);
        wakeUiLocked(self);
        const was_queued = self.state == .queued;
        self.unlock();

        if (was_queued) {
            self.lock();
            while (!self.run_done and !self.run_started) self.wait();
            const should_abort = self.core_call_in_progress and !self.run_done;
            self.unlock();
            if (should_abort) self.abortRun(run_id, cause);
            return;
        }
        self.lock();
        const should_abort = self.core_call_in_progress and !self.run_done;
        self.unlock();
        if (should_abort) self.abortRun(run_id, cause);
    }

    fn requestControlledTermination(
        self: *Session,
        run_id: u64,
        generation: u64,
        cause: HostCause,
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
        setCauseLocked(self, cause);
        wakeUiLocked(self);
        const should_abort = self.core_call_in_progress;
        self.unlock();
        if (should_abort) self.abortRun(run_id, cause);
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
            .cause = self.cause,
            .last_status = self.last_status,
            .last_abort_status = self.last_abort_status,
            .last_stop_reason_code = self.last_stop_reason_code,
            .last_outcome = self.last_outcome,
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

    pub fn recordCause(self: *Session, cause: HostCause) void {
        self.lock();
        defer self.unlock();
        setCauseLocked(self, cause);
    }

    pub fn close(self: *Session, cause: HostCause) Error!void {
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
        const should_abort_now = self.core_call_in_progress and !self.run_done;
        const run_id = self.active_run_id;
        self.state = .closing;
        setCauseLocked(self, cause);
        wakeUiLocked(self);
        self.broadcast();
        self.unlock();

        if (should_abort_now) self.abortRun(run_id, cause);

        self.lock();
        while (!self.run_done and !self.run_started) self.wait();
        const should_abort_late = !should_abort_now and self.core_call_in_progress and !self.run_done;
        self.unlock();
        if (should_abort_late) self.abortRun(run_id, cause);

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

    fn destroyRawSession(self: *Session) Error!void {
        var diagnostic = emptyOwnedBytes();
        const status = self.agent_runtime.api.sessionDestroy()(self.raw, &diagnostic);
        releaseOwned(self.agent_runtime.api, &diagnostic);
        const typed_status = sdk.Status.fromCode(status) catch null;
        self.lock();
        self.close_finished = true;
        if (typed_status == .ok) {
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

    fn executeBegunRun(self: *Session, run_id: u64, generation: u64) void {
        self.lock();
        std.debug.assert(run_id == self.active_run_id);
        std.debug.assert(generation == self.active_run_generation);
        std.debug.assert(self.run_started and !self.run_done);
        if (self.cancel_requested or self.state == .closing) {
            self.finishBeforeCoreCallLocked();
            self.unlock();
            _ = self.agent_runtime.notifyEventConsumer();
            return;
        }
        self.core_call_in_progress = true;
        const prompt = self.prompt.?;
        self.unlock();

        var options = std.mem.zeroes(wire.RunOptionsV1);
        options.struct_size = @sizeOf(wire.RunOptionsV1);
        options.max_turns = 16;
        // A successful Core call must still populate and validate the complete
        // fixed-layout result. Zero initialization makes a missing write fail
        // deterministically on `struct_size` instead of exposing undefined data.
        var result = std.mem.zeroes(wire.RunResultV1);
        var diagnostic = emptyOwnedBytes();
        const status = self.agent_runtime.api.sessionRun()(
            self.raw,
            run_id,
            sdk.bytesView(prompt),
            &options,
            &result,
            &diagnostic,
        );
        const typed_status = sdk.Status.fromCode(status) catch null;
        releaseOwned(self.agent_runtime.api, &diagnostic);

        self.lock();
        self.core_call_in_progress = false;
        self.agent_runtime.allocator.free(prompt);
        self.prompt = null;
        self.last_status = status;
        if (typed_status) |known_status| {
            if (known_status == .ok) {
                if (result.struct_size != @sizeOf(wire.RunResultV1) or !allZero(&result.reserved)) {
                    setCauseLocked(self, .dependency_contract_failure);
                    self.last_outcome = .dependency_contract_failure;
                    self.state = .poisoned;
                } else {
                    self.last_stop_reason_code = result.stop_reason_code;
                    if (sdk.StopReason.fromCode(result.stop_reason_code)) |reason| {
                        self.last_outcome = applyStopReasonLocked(self, reason);
                    } else |_| {
                        setCauseLocked(self, .dependency_contract_failure);
                        self.last_outcome = .dependency_contract_failure;
                        self.state = .poisoned;
                    }
                }
            } else {
                if (known_status == .callback_failed and self.cause == null)
                    setCauseLocked(self, .event_pipeline_failure);
                self.last_outcome = .failed;
                if (statusPoisonsSession(known_status)) self.state = .poisoned;
            }
        } else {
            setCauseLocked(self, .dependency_contract_failure);
            self.last_outcome = .dependency_contract_failure;
            self.state = .poisoned;
        }
        self.run_started = false;
        self.run_done = true;
        if (self.state != .closing and self.state != .poisoned) self.state = .idle;
        self.broadcast();
        self.unlock();
        _ = self.agent_runtime.notifyEventConsumer();
    }

    fn finishBeforeCoreCallLocked(self: *Session) void {
        std.debug.assert(!self.core_call_in_progress);
        if (self.prompt) |prompt| {
            self.agent_runtime.allocator.free(prompt);
            self.prompt = null;
        }
        self.last_outcome = abortedOutcome(self.cause);
        self.run_started = false;
        self.run_done = true;
        if (self.state != .closing and self.state != .poisoned) self.state = .idle;
        self.broadcast();
    }

    fn abortRun(self: *Session, run_id: u64, cause: HostCause) void {
        var diagnostic = emptyOwnedBytes();
        const status = self.agent_runtime.api.sessionAbort()(
            self.raw,
            run_id,
            abortReason(cause),
            &diagnostic,
        );
        releaseOwned(self.agent_runtime.api, &diagnostic);
        self.lock();
        if (self.active_run_id == run_id) {
            self.last_abort_status = status;
            if (sdk.Status.fromCode(status)) |_| {} else |_| {
                setCauseLocked(self, .dependency_contract_failure);
            }
        }
        self.unlock();
    }

    fn finishCancelledQueuedRun(self: *Session) void {
        self.lock();
        self.finishBeforeCoreCallLocked();
        self.unlock();
    }

    fn deinit(self: *Session) void {
        std.debug.assert(self.state == .closed);
        std.debug.assert(self.active_refs == 0);
        self.control_block.deinit();
        self.agent_runtime.allocator.destroy(self.control_block);
        if (self.prompt) |prompt| self.agent_runtime.allocator.free(prompt);
        if (self.ui_request_json) |json| self.agent_runtime.allocator.free(json);
        if (self.ui_response_json) |json| self.agent_runtime.allocator.free(json);
        self.agent_runtime.allocator.free(self.workspace_root);
    }

    fn onEvent(
        context: ?*anyopaque,
        handle: ?*wire.SessionHandle,
        run_id: u64,
        event_json: wire.BytesViewV1,
    ) callconv(.c) u32 {
        const self: *Session = @ptrCast(@alignCast(context orelse return wire.CALLBACK_FATAL));
        if (!self.retainCoreCallback(handle, run_id)) return wire.CALLBACK_FATAL;
        defer self.releaseReference();
        const encoded = sdk.borrowedBytes(event_json) catch {
            self.recordCause(.event_pipeline_failure);
            return wire.CALLBACK_FATAL;
        };
        if (encoded.len > self.agent_runtime.max_event_bytes) {
            self.recordCause(.queue_capacity_failure);
            return wire.CALLBACK_FATAL;
        }
        var parsed = sdk.decodeCoreEvent(self.agent_runtime.allocator, encoded) catch {
            self.recordCause(.event_pipeline_failure);
            return wire.CALLBACK_FATAL;
        };
        switch (parsed.value) {
            .known => {},
            .unknown => {
                parsed.deinit();
                return wire.CALLBACK_CONTINUE;
            },
        }
        const owned_json = self.agent_runtime.allocator.dupe(u8, encoded) catch {
            parsed.deinit();
            self.recordCause(.event_pipeline_failure);
            return wire.CALLBACK_FATAL;
        };
        var envelope = EventEnvelope{
            .session_id = self.id,
            .run_id = run_id,
            .encoded_bytes = encoded.len,
            .json = owned_json,
            .event = parsed,
            .allocator = self.agent_runtime.allocator,
        };
        self.agent_runtime.events.enqueueWithDeadline(envelope, self.agent_runtime.event_enqueue_timeout) catch |err| {
            envelope.deinit();
            self.recordCause(switch (err) {
                error.EventTooLarge,
                error.InvalidIdentity,
                error.GlobalCapacity,
                error.SessionCapacity,
                error.SessionSlotCapacity,
                error.SequenceExhausted,
                error.InvalidLimits,
                error.DeadlineExceeded,
                => .queue_capacity_failure,
            });
            return wire.CALLBACK_FATAL;
        };
        if (self.agent_runtime.notifyEventConsumer() == .unavailable) {
            self.recordCause(.event_pipeline_failure);
            return wire.CALLBACK_FATAL;
        }
        return wire.CALLBACK_CONTINUE;
    }

    fn onUiRequest(
        context: ?*anyopaque,
        handle: ?*wire.SessionHandle,
        request_json: wire.BytesViewV1,
        out_response: ?*wire.OwnedBytesV1,
    ) callconv(.c) u32 {
        if (out_response) |out| out.* = emptyOwnedBytes();
        const self: *Session = @ptrCast(@alignCast(context orelse return wire.UI_FATAL));
        const output = out_response orelse {
            self.recordCause(.ui_pipeline_failure);
            return wire.UI_FATAL;
        };
        if (!self.retainCoreCallback(handle, null)) return wire.UI_FATAL;
        defer self.releaseReference();

        const encoded_request = sdk.borrowedBytes(request_json) catch {
            self.recordCause(.ui_pipeline_failure);
            return wire.UI_FATAL;
        };
        if (encoded_request.len > self.agent_runtime.max_ui_request_bytes) {
            self.recordCause(.queue_capacity_failure);
            return wire.UI_FATAL;
        }
        var parsed = sdk.decodeUiRequest(self.agent_runtime.allocator, encoded_request) catch {
            self.recordCause(.ui_pipeline_failure);
            return wire.UI_FATAL;
        };
        defer parsed.deinit();
        const owned_request = self.agent_runtime.allocator.dupe(u8, encoded_request) catch {
            self.recordCause(.ui_pipeline_failure);
            return wire.UI_FATAL;
        };

        self.lock();
        if (self.state != .running or self.ui_active) {
            setCauseLocked(self, .ui_pipeline_failure);
            self.unlock();
            self.agent_runtime.allocator.free(owned_request);
            return wire.UI_FATAL;
        }
        if (self.ui_request_id == std.math.maxInt(u64)) {
            setCauseLocked(self, .dependency_contract_failure);
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

        if (self.agent_runtime.notifyEventConsumer() == .unavailable) {
            self.lock();
            setCauseLocked(self, .event_pipeline_failure);
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
        const answered = self.ui_answered and self.cause == null and self.state != .closing;
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
                self.recordCause(.ui_pipeline_failure);
                return wire.UI_FATAL;
            };
            output.* = .{ .ptr = bytes.ptr, .len = bytes.len };
            return wire.UI_ANSWERED;
        }
        if (response) |bytes| self.agent_runtime.allocator.free(bytes);
        return wire.UI_UNAVAILABLE;
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
        handle: ?*wire.SessionHandle,
        run_id: ?u64,
    ) bool {
        self.lock();
        defer self.unlock();
        if (self.state == .closing or self.state == .closed or handle != self.raw)
            return false;
        if (run_id) |id| {
            if (!self.run_started or id != self.active_run_id) return false;
        }
        self.active_refs += 1;
        return true;
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

fn setCauseLocked(self: *Session, cause: HostCause) void {
    if (self.cause == null) self.cause = cause;
}

fn isRunProgressState(state: SessionState) bool {
    return state == .queued or state == .running or state == .waiting_ui;
}

fn applyStopReasonLocked(self: *Session, reason: sdk.StopReason) RunOutcome {
    return switch (reason) {
        .end_turn => .completed,
        .max_turns, .tool_loop => .stopped,
        .aborted => abortedOutcome(self.cause),
        .tool_error, .api_error => .failed,
    };
}

fn statusPoisonsSession(status: sdk.Status) bool {
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
        .too_late,
        .resource_limit,
        => false,
    };
}

fn abortedOutcome(cause: ?HostCause) RunOutcome {
    const value = cause orelse return .failed;
    return switch (value) {
        .user_cancel, .timeout => .cancelled,
        .session_close, .host_shutdown => .interrupted,
        .event_pipeline_failure,
        .queue_capacity_failure,
        .ui_pipeline_failure,
        .dependency_contract_failure,
        => .failed,
    };
}

fn allZero(values: []const u64) bool {
    for (values) |value| if (value != 0) return false;
    return true;
}

fn abortReason(cause: HostCause) u32 {
    return if (cause == .timeout) wire.ABORT_TIMEOUT else wire.ABORT_USER_REQUEST;
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
