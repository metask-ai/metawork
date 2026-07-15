//! Gate 2 lifecycle foundation for an injected bundle-owned `ApiV1` table.
//! This module deliberately does not decode AgentCore events or encode UI
//! responses. Until the typed SDK and bounded event sink exist, events fail
//! closed and UI responses remain unavailable. It is not the formal Host.

const std = @import("std");
const sdk = @import("metacodes_agentcore");
const wire = sdk.types;

pub const SessionState = enum {
    idle,
    queued,
    running,
    waiting_ui,
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
    bridge_pipeline_failure,
};

pub const WorkspaceTrust = union(enum) {
    temporary: []const u8,
    explicitly_trusted,
};

pub const WorkspaceInput = struct {
    canonical_root: []const u8,
    trust: WorkspaceTrust,
};

pub const SessionOpenOptions = struct {
    provider_kind_code: u32,
    permission_mode_code: u32,
    shell_policy_code: u32,
    credential: []const u8,
    model: []const u8,
    base_url: []const u8 = "",
    workspace: WorkspaceInput,
};

pub const Limits = struct {
    worker_count: usize,
    queue_capacity: usize,
    max_sessions: usize,
    max_prompt_bytes: usize = 1024 * 1024,
};

pub const SessionSnapshot = struct {
    state: SessionState,
    workspace_root: []const u8,
    active_run_id: u64,
    pending_ui_request_id: ?u64,
    cause: ?HostCause,
    last_status: ?u32,
    last_abort_status: ?u32,
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
    SessionClosing,
    PromptTooLarge,
    RunIdExhausted,
    NoSuchRun,
    NoPendingUiRequest,
    StaleUiResponse,
    SessionDestroyFailed,
    RuntimeDestroyFailed,
};

pub const Host = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    api: sdk.Api,
    runtime: ?*wire.RuntimeHandle,
    max_prompt_bytes: usize,
    executor: Executor,
    sessions_mutex: std.Io.Mutex = .init,
    shutdown_condition: std.Io.Condition = .init,
    sessions: []?*Session,
    shutting_down: std.atomic.Value(bool) = .init(false),
    shutdown_running: bool = false,
    shutdown_complete: bool = false,
    last_shutdown_error: ?Error = null,

    /// `raw_api` is borrowed for the Host lifetime. Bundle discovery tables
    /// are static; injected test tables must provide the same lifetime.
    pub fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
        raw_api: *const wire.ApiV1,
        limits: Limits,
    ) (Error || std.mem.Allocator.Error || std.Thread.SpawnError || error{UnsupportedAbi})!*Host {
        if (limits.worker_count == 0 or limits.queue_capacity == 0 or limits.max_sessions == 0 or
            limits.max_prompt_bytes == 0)
            return error.InvalidLimits;
        const api = try sdk.Api.validate(raw_api);
        const self = try allocator.create(Host);
        errdefer allocator.destroy(self);
        const sessions = try allocator.alloc(?*Session, limits.max_sessions);
        errdefer allocator.free(sessions);
        @memset(sessions, null);

        var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
        runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
        var diagnostic = emptyOwnedBytes();
        var runtime: ?*wire.RuntimeHandle = null;
        const status = api.runtimeCreate()(&runtime_config, &runtime, &diagnostic);
        defer releaseOwned(api, &diagnostic);
        if (status != wire.STATUS_OK or runtime == null) return error.CoreCallFailed;
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
            .executor = undefined,
            .sessions = sessions,
        };
        try self.executor.init(io, allocator, limits.worker_count, limits.queue_capacity);
        return self;
    }

    pub fn createSession(
        self: *Host,
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

        const session = try self.allocator.create(Session);
        errdefer self.allocator.destroy(session);
        const workspace_root = try self.allocator.dupe(u8, options.workspace.canonical_root);
        errdefer self.allocator.free(workspace_root);
        session.* = .{
            .host = self,
            .workspace_root = workspace_root,
        };

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
        if (status != wire.STATUS_OK or raw_session == null) {
            return error.CoreCallFailed;
        }
        session.raw = raw_session;
        self.sessions[session_slot] = session;
        return session;
    }

    pub fn shutdown(self: *Host) Error!void {
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

        self.executor.shutdown();

        if (self.runtime != null) {
            var diagnostic = emptyOwnedBytes();
            const status = self.api.runtimeDestroy()(self.runtime, &diagnostic);
            releaseOwned(self.api, &diagnostic);
            if (status == wire.STATUS_OK) {
                self.runtime = null;
            } else {
                first_error = error.RuntimeDestroyFailed;
            }
        }

        return self.finishShutdown(first_error);
    }

    pub fn releaseClosedSession(self: *Host, session: *Session) Error!void {
        // Successful release transfers the last owner reference to Host and
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
        std.debug.assert(session.callback_refs == 0);
        session.unlock();

        self.sessions[session_slot] = null;
        session.deinit();
        self.allocator.destroy(session);
    }

    fn finishShutdown(self: *Host, result: ?Error) Error!void {
        self.sessions_mutex.lockUncancelable(self.io);
        self.shutdown_running = false;
        self.shutdown_complete = result == null;
        self.last_shutdown_error = result;
        self.shutdown_condition.broadcast(self.io);
        self.sessions_mutex.unlock(self.io);
        if (result) |err| return err;
    }

    pub fn deinit(self: *Host) void {
        std.debug.assert(self.shutdown_complete);
        for (self.sessions) |entry| {
            if (entry) |session| {
                session.deinit();
                self.allocator.destroy(session);
            }
        }
        self.allocator.free(self.sessions);
        const allocator = self.allocator;
        allocator.destroy(self);
    }
};

pub const Session = struct {
    host: *Host,
    raw: ?*wire.SessionHandle = null,
    workspace_root: []u8,
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    state: SessionState = .idle,
    next_run_id: u64 = 0,
    active_run_id: u64 = 0,
    run_started: bool = false,
    run_done: bool = true,
    prompt: ?[]u8 = null,
    cause: ?HostCause = null,
    last_status: ?u32 = null,
    last_abort_status: ?u32 = null,
    cancel_requested: bool = false,
    callback_refs: usize = 0,
    ui_active: bool = false,
    ui_request_id: u64 = 0,
    ui_answered: bool = false,
    close_finished: bool = false,
    close_failed: bool = false,

    fn lock(self: *Session) void {
        self.mutex.lockUncancelable(self.host.io);
    }

    fn unlock(self: *Session) void {
        self.mutex.unlock(self.host.io);
    }

    fn wait(self: *Session) void {
        self.condition.waitUncancelable(self.host.io, &self.mutex);
    }

    fn broadcast(self: *Session) void {
        self.condition.broadcast(self.host.io);
    }

    pub fn submit(self: *Session, prompt: []const u8) (Error || std.mem.Allocator.Error)!u64 {
        if (prompt.len > self.host.max_prompt_bytes) return error.PromptTooLarge;
        const owned_prompt = try self.host.allocator.dupe(u8, prompt);
        errdefer self.host.allocator.free(owned_prompt);
        self.lock();
        if (self.host.shutting_down.load(.acquire)) {
            self.unlock();
            return error.HostShuttingDown;
        }
        if (self.state == .closing or self.state == .closed) {
            self.unlock();
            return error.SessionClosing;
        }
        if (self.state != .idle) {
            self.unlock();
            return error.SessionNotIdle;
        }
        if (self.next_run_id == std.math.maxInt(u64)) {
            self.unlock();
            return error.RunIdExhausted;
        }
        self.next_run_id += 1;
        const run_id = self.next_run_id;
        self.active_run_id = run_id;
        self.run_started = false;
        self.run_done = false;
        self.prompt = owned_prompt;
        self.cause = null;
        self.last_status = null;
        self.last_abort_status = null;
        self.cancel_requested = false;
        self.state = .queued;
        self.host.executor.enqueue(self) catch |err| {
            self.state = .idle;
            self.active_run_id = 0;
            self.run_done = true;
            self.prompt = null;
            self.unlock();
            return err;
        };
        self.unlock();
        return run_id;
    }

    pub fn requestCancel(self: *Session, run_id: u64, cause: HostCause) Error!void {
        self.lock();
        if (self.state == .closing or self.state == .closed) {
            self.unlock();
            return error.SessionClosing;
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

        if (was_queued and self.host.executor.cancel(self)) {
            self.finishCancelledQueuedRun();
            return;
        }
        if (was_queued) {
            self.lock();
            while (!self.run_done and !self.run_started) self.wait();
            const should_abort = self.run_started and !self.run_done;
            self.unlock();
            if (should_abort) self.abortRun(run_id, cause);
            return;
        }
        self.abortRun(run_id, cause);
    }

    pub fn respondUi(self: *Session, run_id: u64, request_id: u64) Error!void {
        self.lock();
        defer self.unlock();
        if (self.state == .closing or self.state == .closed) return error.SessionClosing;
        if (!self.ui_active) return error.NoPendingUiRequest;
        if (run_id != self.active_run_id or request_id != self.ui_request_id or self.ui_answered)
            return error.StaleUiResponse;
        self.ui_answered = true;
        self.ui_active = false;
        self.broadcast();
    }

    pub fn pendingUiRequest(self: *Session) ?u64 {
        self.lock();
        defer self.unlock();
        return if (self.ui_active) self.ui_request_id else null;
    }

    pub fn waitForState(self: *Session, wanted: SessionState) Error!void {
        self.lock();
        defer self.unlock();
        while (self.state != wanted and self.state != .closed and !self.close_failed)
            self.wait();
        if (self.state == wanted) return;
        if (self.close_failed) return error.SessionDestroyFailed;
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
            .state = self.state,
            .workspace_root = self.workspace_root,
            .active_run_id = self.active_run_id,
            .pending_ui_request_id = if (self.ui_active) self.ui_request_id else null,
            .cause = self.cause,
            .last_status = self.last_status,
            .last_abort_status = self.last_abort_status,
        };
    }

    pub fn retainCallback(self: *Session) bool {
        self.lock();
        defer self.unlock();
        if (self.state == .closing or self.state == .closed) return false;
        self.callback_refs += 1;
        return true;
    }

    pub fn releaseCallback(self: *Session) void {
        self.lock();
        defer self.unlock();
        std.debug.assert(self.callback_refs > 0);
        self.callback_refs -= 1;
        if (self.callback_refs == 0) self.broadcast();
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
        const was_queued = self.state == .queued;
        const should_abort_now = self.run_started and !self.run_done;
        const run_id = self.active_run_id;
        self.state = .closing;
        setCauseLocked(self, cause);
        wakeUiLocked(self);
        self.broadcast();
        self.unlock();

        const cancelled_queued = was_queued and self.host.executor.cancel(self);
        if (cancelled_queued) self.finishCancelledQueuedRun();
        if (should_abort_now) self.abortRun(run_id, cause);

        self.lock();
        while (!self.run_done and !self.run_started) self.wait();
        const should_abort_late = !should_abort_now and self.run_started and !self.run_done;
        self.unlock();
        if (should_abort_late) self.abortRun(run_id, cause);

        self.lock();
        while (!self.run_done) self.wait();
        while (self.callback_refs != 0) self.wait();
        self.unlock();

        return self.destroyRawSession();
    }

    fn destroyRawSession(self: *Session) Error!void {
        var diagnostic = emptyOwnedBytes();
        const status = self.host.api.sessionDestroy()(self.raw, &diagnostic);
        releaseOwned(self.host.api, &diagnostic);
        self.lock();
        self.close_finished = true;
        if (status == wire.STATUS_OK) {
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

    fn executeRun(self: *Session) void {
        self.lock();
        if (self.state != .queued) {
            self.run_done = true;
            if (self.prompt) |prompt| {
                self.host.allocator.free(prompt);
                self.prompt = null;
            }
            self.broadcast();
            self.unlock();
            return;
        }
        self.state = .running;
        self.run_started = true;
        const run_id = self.active_run_id;
        const prompt = self.prompt.?;
        self.broadcast();
        self.unlock();

        var options = std.mem.zeroes(wire.RunOptionsV1);
        options.struct_size = @sizeOf(wire.RunOptionsV1);
        options.max_turns = 16;
        var result: wire.RunResultV1 = undefined;
        var diagnostic = emptyOwnedBytes();
        const status = self.host.api.sessionRun()(
            self.raw,
            run_id,
            sdk.bytesView(prompt),
            &options,
            &result,
            &diagnostic,
        );
        releaseOwned(self.host.api, &diagnostic);

        self.lock();
        self.host.allocator.free(prompt);
        self.prompt = null;
        self.last_status = status;
        if (status == wire.STATUS_CALLBACK_FAILED)
            setCauseLocked(self, .event_pipeline_failure);
        self.run_started = false;
        self.run_done = true;
        if (self.state != .closing) self.state = .idle;
        self.broadcast();
        self.unlock();
    }

    fn abortRun(self: *Session, run_id: u64, cause: HostCause) void {
        var diagnostic = emptyOwnedBytes();
        const status = self.host.api.sessionAbort()(
            self.raw,
            run_id,
            abortReason(cause),
            &diagnostic,
        );
        releaseOwned(self.host.api, &diagnostic);
        self.lock();
        if (self.active_run_id == run_id) self.last_abort_status = status;
        self.unlock();
    }

    fn finishCancelledQueuedRun(self: *Session) void {
        self.lock();
        if (self.prompt) |prompt| {
            self.host.allocator.free(prompt);
            self.prompt = null;
        }
        self.run_done = true;
        if (self.state != .closing) self.state = .idle;
        self.broadcast();
        self.unlock();
    }

    fn deinit(self: *Session) void {
        std.debug.assert(self.state == .closed);
        std.debug.assert(self.callback_refs == 0);
        if (self.prompt) |prompt| self.host.allocator.free(prompt);
        self.host.allocator.free(self.workspace_root);
    }

    fn onEvent(
        context: ?*anyopaque,
        handle: ?*wire.SessionHandle,
        run_id: u64,
        _: wire.BytesViewV1,
    ) callconv(.c) u32 {
        const self: *Session = @ptrCast(@alignCast(context orelse return wire.CALLBACK_FATAL));
        if (!self.retainCoreCallback(handle, run_id)) return wire.CALLBACK_FATAL;
        defer self.releaseCallback();
        self.recordCause(.event_pipeline_failure);
        return wire.CALLBACK_FATAL;
    }

    fn onUiRequest(
        context: ?*anyopaque,
        handle: ?*wire.SessionHandle,
        _: wire.BytesViewV1,
        out_response: ?*wire.OwnedBytesV1,
    ) callconv(.c) u32 {
        if (out_response) |out| out.* = emptyOwnedBytes();
        const self: *Session = @ptrCast(@alignCast(context orelse return wire.UI_FATAL));
        if (!self.retainCoreCallback(handle, null)) return wire.UI_FATAL;
        defer self.releaseCallback();

        self.lock();
        if (self.state != .running or self.ui_active) {
            self.unlock();
            return wire.UI_FATAL;
        }
        if (self.ui_request_id == std.math.maxInt(u64)) {
            self.unlock();
            return wire.UI_FATAL;
        }
        self.ui_request_id += 1;
        self.ui_active = true;
        self.ui_answered = false;
        self.state = .waiting_ui;
        self.broadcast();
        while (self.ui_active and self.state == .waiting_ui)
            self.wait();
        if (self.state == .waiting_ui) self.state = .running;
        const answered = self.ui_answered;
        self.broadcast();
        self.unlock();

        // Gate 2 intentionally does not encode UiResponse JSON. A successful
        // wake proves lifecycle only; Gate 3 must provide the real encoder.
        _ = answered;
        return wire.UI_UNAVAILABLE;
    }

    fn releaseUiResponse(_: ?*anyopaque, out: ?*wire.OwnedBytesV1) callconv(.c) void {
        if (out) |value| value.* = emptyOwnedBytes();
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
        self.callback_refs += 1;
        return true;
    }
};

const Executor = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    queue: []?*Session,
    queued: usize = 0,
    workers: []std.Thread,
    stopping: bool = false,
    joined: bool = false,

    fn init(
        self: *Executor,
        io: std.Io,
        allocator: std.mem.Allocator,
        worker_count: usize,
        queue_capacity: usize,
    ) (std.mem.Allocator.Error || std.Thread.SpawnError)!void {
        const queue = try allocator.alloc(?*Session, queue_capacity);
        errdefer allocator.free(queue);
        @memset(queue, null);
        const workers = try allocator.alloc(std.Thread, worker_count);
        errdefer allocator.free(workers);
        self.* = .{
            .io = io,
            .allocator = allocator,
            .queue = queue,
            .workers = workers,
        };
        var started: usize = 0;
        errdefer {
            self.lock();
            self.stopping = true;
            self.broadcast();
            self.unlock();
            for (self.workers[0..started]) |thread| thread.join();
        }
        for (self.workers) |*worker| {
            worker.* = try std.Thread.spawn(.{}, workerMain, .{self});
            started += 1;
        }
    }

    fn enqueue(self: *Executor, session: *Session) Error!void {
        self.lock();
        defer self.unlock();
        if (self.stopping) return error.HostShuttingDown;
        if (self.queued == self.queue.len) return error.QueueFull;
        for (self.queue) |*entry| {
            if (entry.* == null) {
                entry.* = session;
                self.queued += 1;
                self.signal();
                return;
            }
        }
        unreachable;
    }

    fn cancel(self: *Executor, session: *Session) bool {
        self.lock();
        defer self.unlock();
        for (self.queue) |*entry| {
            if (entry.* == session) {
                entry.* = null;
                self.queued -= 1;
                return true;
            }
        }
        return false;
    }

    fn shutdown(self: *Executor) void {
        self.lock();
        if (self.joined) {
            self.unlock();
            return;
        }
        self.stopping = true;
        self.broadcast();
        self.unlock();
        for (self.workers) |thread| thread.join();
        self.lock();
        self.joined = true;
        self.unlock();
        self.allocator.free(self.workers);
        self.allocator.free(self.queue);
    }

    fn workerMain(self: *Executor) void {
        while (true) {
            self.lock();
            while (self.queued == 0 and !self.stopping)
                self.wait();
            if (self.stopping and self.queued == 0) {
                self.unlock();
                return;
            }
            var session: ?*Session = null;
            for (self.queue) |*entry| {
                if (entry.*) |queued_session| {
                    session = queued_session;
                    entry.* = null;
                    self.queued -= 1;
                    break;
                }
            }
            self.unlock();
            session.?.executeRun();
        }
    }

    fn lock(self: *Executor) void {
        self.mutex.lockUncancelable(self.io);
    }

    fn unlock(self: *Executor) void {
        self.mutex.unlock(self.io);
    }

    fn wait(self: *Executor) void {
        self.condition.waitUncancelable(self.io, &self.mutex);
    }

    fn signal(self: *Executor) void {
        self.condition.signal(self.io);
    }

    fn broadcast(self: *Executor) void {
        self.condition.broadcast(self.io);
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
