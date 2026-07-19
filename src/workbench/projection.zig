const std = @import("std");
const lifecycle = @import("metawork_agent");
const executor_impl = @import("workbench_executor");
const contract_fixture = @import("workbench_contract_fixture");

pub const Error = lifecycle.Error || std.mem.Allocator.Error || std.Thread.SpawnError || error{
    ProjectionCapacity,
    RunCapacity,
    ToolCapacity,
    SnapshotTooLarge,
    CloseInProgress,
    TaskBusy,
    TaskNotClosed,
    InvalidTaskTitle,
    RunGenerationExhausted,
    ExecutorShuttingDown,
    TaskCapacity,
    UnknownTask,
    TaskClosing,
    InvalidExecutionDefaults,
    InvalidWorkspace,
};

pub const Limits = struct {
    worker_count: usize = 4,
    queue_capacity: usize = 16,
    max_tasks: usize = 8,
    max_runs_per_task: usize = 16,
    max_tools_per_run: usize = 32,
    max_projection_bytes: usize = 512 * 1024,
    max_workspace_bytes: usize = 16 * 1024,
    max_task_title_bytes: usize = 512,
    max_user_message_bytes: usize = 64 * 1024,
    max_assistant_message_bytes: usize = 256 * 1024,
    max_tool_field_bytes: usize = 256 * 1024,
    max_pending_ui_json_bytes: usize = 256 * 1024,
    max_pending_ui_requests: usize = 4,
    max_ui_history_per_task: usize = 8,
    max_terminal_diagnostic_bytes: usize = 512,
    max_snapshot_bytes: usize = 8 * 1024 * 1024,
};

pub const Provider = enum {
    anthropic,
    openai,
    gemini,
};

pub const ExecutionDefaults = struct {
    provider: Provider,
    credential: []const u8,
    model: []const u8,
    base_url: []const u8 = "",
};

pub const TaskWorkspaceTrust = union(enum) {
    explicitly_trusted,
    temporary: []const u8,
};

pub const TaskCreateInput = struct {
    workspace_root: []const u8,
    trust: TaskWorkspaceTrust,
};

pub const PermissionChoice = enum {
    allow_once,
    allow_always,
    deny_once,
    deny_tool_session,
};

pub const UiResponse = union(enum) {
    answers: []const []const u8,
    permission: PermissionChoice,
};

pub const Configuration = struct {
    execution: ExecutionDefaults,
    change_notifier: ChangeNotifier = .{},
};

const json_string_expansion: usize = 6;
const pending_ui_reencode_expansion: usize = 2;
const root_snapshot_overhead: usize = 128;
const task_snapshot_overhead: usize = 512;
const run_snapshot_overhead: usize = 1024;
const tool_snapshot_overhead: usize = 512;
const pending_ui_snapshot_overhead: usize = 8 * 1024;
const ui_record_detail_capacity: usize = 512;
const ui_record_snapshot_overhead: usize = 512;
const tool_route_digest_bytes = std.crypto.hash.sha2.Sha256.digest_length;
pub const snapshot_schema_version: u32 = 5;

const ToolState = enum { running, completed, failed };
const RunPhase = enum {
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

const RunOutcome = enum {
    completed,
    stopped,
    cancelled,
    interrupted,
    failed,
    dependency_contract_failure,
};

/// Workbench-owned durable product cause.
const RunCause = enum {
    user_cancel,
    timeout,
    session_close,
    app_shutdown,
    event_pipeline_failure,
    queue_capacity_failure,
    ui_pipeline_failure,
    dependency_contract_failure,
};

const TaskLifecycle = enum { open, closing, closed };

const ContinuationUnavailableReason = enum {
    session_poisoned,
    closing,
    closed,
};

const ContinuationCapability = union(enum) {
    available,
    unavailable: ContinuationUnavailableReason,
};

const CloseCompletion = enum(u8) {
    none,
    running,
    closed,
    failed_reusable,
    failed_poisoned,
    failed_closing,
};

pub const ChangeNotifier = struct {
    context: ?*anyopaque = null,
    wake: *const fn (?*anyopaque) bool = noChangeNotification,

    fn notify(self: ChangeNotifier) bool {
        return self.wake(self.context);
    }
};

pub const TransportFailureStage = enum {
    ingress_validation,
    command_dispatch,
    response_delivery,
    revision_delivery,
    snapshot_transport,
    connection_generation,
    agent_event_delivery,
    detached_retention_expired,
};

pub const TransportFailureReport = struct {
    stage: TransportFailureStage,
    session_id: u64 = 0,
    run_id: u64 = 0,
};

pub const TransportFailureDecision = enum {
    reject_command,
    retry,
    detach_renderer,
    retain_for_reconnect,
    discard_transport_payload,
    request_run_termination,
};

/// Workbench owns product impact policy; Bridge supplies transport facts only.
/// Current Renderer transport failures never terminate an Agent Run.
pub fn decideTransportFailure(report: TransportFailureReport) TransportFailureDecision {
    std.debug.assert((report.session_id == 0) == (report.run_id == 0));
    return switch (report.stage) {
        .ingress_validation, .command_dispatch => .reject_command,
        .revision_delivery, .snapshot_transport => .retry,
        .response_delivery, .connection_generation => .detach_renderer,
        .agent_event_delivery => .retain_for_reconnect,
        .detached_retention_expired => .discard_transport_payload,
    };
}

const TrackedText = struct {
    list: std.ArrayList(u8) = .empty,
};

const ToolView = struct {
    /// One-way correlation key for SDK tool events. The raw AgentCore tool ID
    /// is not retained in Workbench product history.
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
};

const UsageView = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cache_read_input_tokens: u64 = 0,
    cache_creation_input_tokens: u64 = 0,
};

const TerminalPublication = enum(u8) { open, publishing, published };
const AgentHandoffState = enum(u8) { queued, starting, running, finishing };
const RunTerminationDispatch = enum {
    pending,
    requested,
    already_requested,
    already_finishing,
    already_terminal,
    stale_run,
    session_closing,
};

const PendingInterruption = enum(u8) {
    none,
    user_cancel,
    timeout,
    session_close,
    app_shutdown,
};

const TerminalPayload = struct {
    phase: RunPhase,
    outcome: RunOutcome,
    cause: ?RunCause,
    session_disposition_at_completion: lifecycle.SessionDisposition,
    diagnostic_len: usize = 0,
    diagnostic_truncated: bool = false,
    diagnostic_redacted: bool = false,
};

const RunRecord = struct {
    id: u64,
    generation: u64,
    user: []u8,
    user_redacted: bool = false,
    assistant: TrackedText = .{},
    assistant_redacted: bool = false,
    active_phase: RunPhase = .queued,
    tools: []?ToolView,
    usage: UsageView = .{},
    status_text: []u8,
    terminal_publication: std.atomic.Value(TerminalPublication) = .init(.open),
    terminal_payload: TerminalPayload = undefined,
    terminal_observed: bool = false,
    terminal_diagnostic: []u8,
    redaction_secret: []const u8 = &.{},
    next_activity_order: u64 = 1,
    workbench: *Workbench = undefined,
    task: *TaskView = undefined,
    session: *lifecycle.Session = undefined,
    worker_reference_held: std.atomic.Value(bool) = .init(false),
    agent_handoff: std.atomic.Value(AgentHandoffState) = .init(.queued),
    pending_termination: std.atomic.Value(PendingInterruption) = .init(.none),
    run_control: lifecycle.RunControl = undefined,
};

const UiRecordKind = enum { ask_question, permission };

const UiRecordState = enum {
    answered,
    allowed_once,
    allowed_always,
    denied,
    denied_session,
    cancelled,
};

const UiRecord = struct {
    request_id: u64,
    run_id: u64,
    order: u64 = 0,
    kind: UiRecordKind,
    state: UiRecordState,
    detail: [ui_record_detail_capacity]u8 = undefined,
    detail_len: usize = 0,
    item_count: u32 = 0,
    detail_truncated: bool = false,
    redacted: bool = false,

    fn detailSlice(self: *const UiRecord) []const u8 {
        return self.detail[0..self.detail_len];
    }
};

const TaskView = struct {
    session: ?*lifecycle.Session,
    id: u64,
    workspace_root: []u8,
    title: []u8,
    title_redacted: bool = false,
    archived: bool = false,
    runs: []?RunRecord,
    next_run_generation: u64 = 0,
    run_references: std.atomic.Value(usize) = .init(0),
    delete_pending: bool = false,
    ui_history: []?UiRecord,
    ui_history_count: usize = 0,
    ui_history_next: usize = 0,
    pending_ui_request_id: u64 = 0,
    pending_ui_order: u64 = 0,
    lifecycle: TaskLifecycle = .open,
    continuation: ContinuationCapability = .available,
    active_run_id: u64 = 0,
    closing_session: ?*lifecycle.Session = null,
    close_thread: ?std.Thread = null,
    close_completion: std.atomic.Value(CloseCompletion) = .init(.none),
    close_failed: bool = false,
    cancel_requested: bool = false,
};

/// Stable worker reference to an admitted Run record. This value is a lease:
/// it must not be copied, and `release` must be called exactly once.
pub const RunRef = struct {
    workbench: *Workbench,
    task: *TaskView,
    record: *RunRecord,
    task_id: u64,
    run_id: u64,
    generation: u64,
    released: bool = false,

    pub fn isCurrent(self: *const RunRef) bool {
        return !self.released and self.task.id == self.task_id and
            self.record.id == self.run_id and self.record.generation == self.generation;
    }

    pub fn release(self: *RunRef) void {
        std.debug.assert(!self.released);
        std.debug.assert(self.isCurrent());
        self.released = true;
        const references = &self.task.run_references;
        const workbench = self.workbench;
        const previous = references.fetchSub(1, .release);
        std.debug.assert(previous != 0);
        if (previous == 1) _ = workbench.change_notifier.notify();
    }
};

/// Workbench-owned product projection. AgentCore protocol is interpreted only
/// through the bundle SDK; the Renderer receives this bounded domain view.
/// All methods currently run on the Native loop thread.
pub const Workbench = struct {
    allocator: std.mem.Allocator,
    agent_runtime: *lifecycle.Runtime,
    limits: Limits,
    tasks: []?TaskView,
    change_notifier: ChangeNotifier,
    executor: *executor_impl.Executor,
    shutting_down: bool = false,
    executor_shutdown: bool = false,
    projection_bytes: usize = 0,
    revision: u64 = 0,
    credential: []u8,
    model: []u8,
    base_url: []u8,
    provider: Provider,

    pub fn init(
        allocator: std.mem.Allocator,
        agent_runtime: *lifecycle.Runtime,
        limits: Limits,
        configuration: Configuration,
    ) Error!Workbench {
        if (limits.worker_count == 0 or limits.queue_capacity == 0 or
            limits.max_tasks == 0 or limits.max_runs_per_task == 0 or
            limits.max_tools_per_run == 0 or limits.max_projection_bytes == 0 or
            limits.max_workspace_bytes == 0 or
            limits.max_task_title_bytes == 0 or
            limits.max_user_message_bytes == 0 or limits.max_assistant_message_bytes == 0 or
            limits.max_tool_field_bytes == 0 or limits.max_pending_ui_json_bytes == 0 or
            limits.max_pending_ui_requests == 0 or
            limits.max_ui_history_per_task == 0 or
            limits.max_terminal_diagnostic_bytes == 0 or
            limits.max_snapshot_bytes == 0 or
            (worstCaseSnapshotBytes(limits) orelse return error.ProjectionCapacity) > limits.max_snapshot_bytes)
            return error.ProjectionCapacity;
        const credential = try allocator.dupe(u8, configuration.execution.credential);
        errdefer {
            std.crypto.secureZero(u8, credential);
            allocator.free(credential);
        }
        const model = try allocator.dupe(u8, configuration.execution.model);
        errdefer allocator.free(model);
        const base_url = try allocator.dupe(u8, configuration.execution.base_url);
        errdefer allocator.free(base_url);
        const tasks = try allocator.alloc(?TaskView, limits.max_tasks);
        errdefer allocator.free(tasks);
        @memset(tasks, null);
        const executor = executor_impl.Executor.create(agent_runtime.io, allocator, .{
            .worker_count = limits.worker_count,
            .queue_capacity = limits.queue_capacity,
        }) catch |err| switch (err) {
            error.InvalidLimits => unreachable,
            else => return err,
        };
        return .{
            .allocator = allocator,
            .agent_runtime = agent_runtime,
            .limits = limits,
            .tasks = tasks,
            .change_notifier = configuration.change_notifier,
            .executor = executor,
            .credential = credential,
            .model = model,
            .base_url = base_url,
            .provider = configuration.execution.provider,
        };
    }

    pub fn createTask(
        self: *Workbench,
        input: TaskCreateInput,
    ) Error!u64 {
        self.syncLifecycle();
        if (self.credential.len == 0 or self.model.len == 0)
            return error.InvalidExecutionDefaults;
        const slot = findEmpty(TaskView, self.tasks) orelse return error.TaskCapacity;
        const canonical = std.Io.Dir.realPathFileAbsoluteAlloc(
            self.agent_runtime.io,
            input.workspace_root,
            self.allocator,
        ) catch return error.InvalidWorkspace;
        defer self.allocator.free(canonical);
        const workspace_stat = std.Io.Dir.cwd().statFile(
            self.agent_runtime.io,
            canonical,
            .{},
        ) catch return error.InvalidWorkspace;
        if (workspace_stat.kind != .directory) return error.InvalidWorkspace;
        var temporary_root: ?[:0]u8 = null;
        defer if (temporary_root) |root| self.allocator.free(root);
        const workspace_trust: lifecycle.WorkspaceTrust = switch (input.trust) {
            .explicitly_trusted => .explicitly_trusted,
            .temporary => |root| temporary: {
                const canonical_root = std.Io.Dir.realPathFileAbsoluteAlloc(
                    self.agent_runtime.io,
                    root,
                    self.allocator,
                ) catch return error.InvalidWorkspace;
                temporary_root = canonical_root;
                const root_stat = std.Io.Dir.cwd().statFile(
                    self.agent_runtime.io,
                    canonical_root,
                    .{},
                ) catch return error.InvalidWorkspace;
                if (root_stat.kind != .directory) return error.InvalidWorkspace;
                break :temporary .{ .temporary = canonical_root };
            },
        };
        const workspace = try self.copyBounded(canonical, self.limits.max_workspace_bytes);
        errdefer self.freeTracked(workspace);
        const title = try self.copyBounded("", self.limits.max_task_title_bytes);
        errdefer self.freeTracked(title);
        const runs = try self.allocator.alloc(?RunRecord, self.limits.max_runs_per_task);
        errdefer self.allocator.free(runs);
        @memset(runs, null);
        const ui_history = try self.allocator.alloc(?UiRecord, self.limits.max_ui_history_per_task);
        errdefer self.allocator.free(ui_history);
        @memset(ui_history, null);
        const route = self.agent_runtime.createSessionRoute(.{
            .provider = agentProvider(self.provider),
            .permission_mode = .default,
            .shell_policy = .unrestricted,
            .credential = self.credential,
            .model = self.model,
            .base_url = self.base_url,
            .workspace = .{
                .canonical_root = canonical,
                .trust = workspace_trust,
            },
        }) catch |err| switch (err) {
            error.SessionCapacity => return error.TaskCapacity,
            else => return err,
        };
        self.tasks[slot] = .{
            .session = route.session,
            .id = route.id,
            .workspace_root = workspace,
            .title = title,
            .runs = runs,
            .ui_history = ui_history,
        };
        self.bumpRevision();
        return self.tasks[slot].?.id;
    }

    pub fn runTask(self: *Workbench, task_id: u64, prompt: []const u8) Error!u64 {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        self.syncLifecycle();
        const view = self.findTask(task_id) orelse return error.UnknownTask;
        if (!self.taskContinuationAvailable(view)) return error.TaskClosing;
        if (hasNonTerminalRun(view)) return error.TaskBusy;
        const session = view.session orelse return error.TaskClosing;
        const run_id = try session.prepareRun(prompt);
        errdefer cancelPreparedRunOrPanic(session, run_id);
        const slot = try self.reserveRunRecord(view, prompt);
        errdefer self.discardRunRecord(view, slot);
        const run = &view.runs[slot].?;
        run.id = run_id;
        run.workbench = self;
        run.task = view;
        run.session = session;
        _ = view.run_references.fetchAdd(1, .acq_rel);
        run.worker_reference_held.store(true, .release);
        self.executor.enqueue(.{
            .context = run,
            .execute_fn = executeRunJob,
            .cancel_fn = cancelRunJobForShutdown,
        }) catch |err| {
            releaseWorkerReference(run);
            return err;
        };
        view.active_run_id = run_id;
        view.cancel_requested = false;
        self.bumpRevision();
        return run_id;
    }

    pub fn acquireRunRef(self: *Workbench, task_id: u64, run_id: u64) Error!RunRef {
        const task = self.findTask(task_id) orelse return error.UnknownTask;
        if (task.delete_pending) return error.UnknownTask;
        const record = findRun(task.runs, run_id) orelse return error.NoSuchRun;
        _ = task.run_references.fetchAdd(1, .acq_rel);
        return .{
            .workbench = self,
            .task = task,
            .record = record,
            .task_id = task_id,
            .run_id = run_id,
            .generation = record.generation,
        };
    }

    pub fn cancel(self: *Workbench, task_id: u64, run_id: u64) Error!void {
        self.syncLifecycle();
        const view = self.findTask(task_id) orelse return error.UnknownTask;
        const run = findRun(view.runs, run_id) orelse return error.NoSuchRun;
        if (terminalPayload(run) != null) return;
        const session = view.session orelse
            return error.TaskClosing;
        const record = self.prepareCancelledUiRecord(session, run_id);
        if (self.executor.cancel(run)) {
            cancelPreparedRunOrPanic(session, run_id);
            releaseWorkerReference(run);
            _ = commitTerminal(
                run,
                .cancelled,
                .cancelled,
                .user_cancel,
                .reusable,
                "",
                false,
            );
            run.terminal_observed = true;
            if (record) |value| self.pushUiRecord(view, value);
            view.cancel_requested = false;
            self.bumpRevision();
            return;
        }
        const dispatch = requestRunTermination(run, .user_cancel);
        const stopping = switch (dispatch) {
            .pending, .requested, .already_requested => true,
            .already_finishing, .already_terminal, .stale_run, .session_closing => false,
        };
        if (!stopping) {
            self.syncLifecycle();
            return;
        }
        if (record) |value| self.pushUiRecord(view, value);
        view.cancel_requested = true;
        _ = setActivePhase(run, .stopping);
        self.bumpRevision();
    }

    pub fn respondUi(
        self: *Workbench,
        task_id: u64,
        run_id: u64,
        request_id: u64,
        response: UiResponse,
    ) Error!void {
        self.syncLifecycle();
        const view = self.findTask(task_id) orelse return error.UnknownTask;
        const session = view.session orelse
            return error.TaskClosing;
        const agent_response = agentUiResponse(response);
        const record = self.prepareUiRecord(session, run_id, request_id, agent_response);
        try session.respondUi(run_id, request_id, agent_response);
        self.pushUiRecord(view, record);
        self.bumpRevision();
    }

    pub fn closeTask(self: *Workbench, task_id: u64) Error!void {
        self.syncLifecycle();
        const view = self.findTask(task_id) orelse return error.UnknownTask;
        if (view.close_completion.load(.acquire) == .running) return error.CloseInProgress;
        const session = view.session orelse return;
        const prior_lifecycle = view.lifecycle;
        const prior_continuation = view.continuation;
        const cancelled_ui = self.prepareCancelledUiRecord(session, view.active_run_id);
        if (findRun(view.runs, view.active_run_id)) |run| {
            if (self.executor.cancel(run)) {
                cancelPreparedRunOrPanic(session, view.active_run_id);
                releaseWorkerReference(run);
                _ = commitTerminal(
                    run,
                    .interrupted,
                    .interrupted,
                    .session_close,
                    .closing,
                    "",
                    false,
                );
                run.terminal_observed = true;
            } else consumeLifecycleTermination(
                requestRunTermination(run, .session_close),
                run.id,
            );
        }
        view.session = null;
        view.closing_session = session;
        view.lifecycle = .closing;
        view.continuation = .{ .unavailable = .closing };
        view.cancel_requested = view.active_run_id != 0;
        if (findRun(view.runs, view.active_run_id)) |run| {
            if (!isTerminalPhase(runPhase(run))) _ = setActivePhase(run, .stopping);
        }
        view.close_failed = false;
        view.close_completion.store(.running, .release);
        view.close_thread = std.Thread.spawn(.{}, closeWorker, .{ self.agent_runtime, view, session }) catch |err| {
            view.close_completion.store(.none, .release);
            view.closing_session = null;
            view.session = session;
            view.lifecycle = prior_lifecycle;
            view.continuation = prior_continuation;
            return err;
        };
        if (cancelled_ui) |record|
            self.pushUiRecord(view, record);
        self.bumpRevision();
    }

    pub fn renameTask(self: *Workbench, task_id: u64, title: []const u8) Error!void {
        self.syncLifecycle();
        const view = self.findTask(task_id) orelse return error.UnknownTask;
        const trimmed = std.mem.trim(u8, title, " \t\r\n");
        if (trimmed.len == 0 or trimmed.len > self.limits.max_task_title_bytes or
            !std.unicode.utf8ValidateSlice(trimmed))
            return error.InvalidTaskTitle;
        for (trimmed) |byte| if (byte < 0x20) return error.InvalidTaskTitle;
        const projected = try self.replaceTrackedProjected(
            &view.title,
            trimmed,
            self.limits.max_task_title_bytes,
        );
        view.title_redacted = projected.redacted;
        self.bumpRevision();
    }

    pub fn setTaskArchived(self: *Workbench, task_id: u64, archived: bool) Error!void {
        self.syncLifecycle();
        const view = self.findTask(task_id) orelse return error.UnknownTask;
        if (view.lifecycle == .closing or hasNonTerminalRun(view)) return error.TaskBusy;
        if (view.archived == archived) return;
        view.archived = archived;
        self.bumpRevision();
    }

    pub fn deleteTask(self: *Workbench, task_id: u64) Error!void {
        self.syncLifecycle();
        const index = self.findTaskIndex(task_id) orelse return error.UnknownTask;
        const view = &(self.tasks[index] orelse unreachable);
        if (view.lifecycle != .closed or view.close_thread != null or view.session != null)
            return error.TaskNotClosed;
        if (view.run_references.load(.acquire) != 0) {
            if (!view.delete_pending) {
                view.delete_pending = true;
                self.bumpRevision();
            }
            return;
        }
        self.deinitTaskView(view);
        self.tasks[index] = null;
        self.bumpRevision();
    }

    pub fn currentRevision(self: *Workbench) u64 {
        self.syncLifecycle();
        return self.revision;
    }

    /// Reconciles worker-owned lifecycle state into the main-thread product
    /// projection. It never allocates, so an effects wake cannot fail merely
    /// while publishing a terminal state.
    pub fn syncLifecycle(self: *Workbench) void {
        var changed = false;
        for (self.tasks) |*entry| {
            const view = &(entry.* orelse continue);
            if (view.delete_pending and view.lifecycle == .closed and view.close_thread == null and
                view.session == null and view.run_references.load(.acquire) == 0)
            {
                self.deinitTaskView(view);
                entry.* = null;
                changed = true;
                continue;
            }
            const close_completion = view.close_completion.load(.acquire);
            if (close_completion != .none and close_completion != .running) {
                view.close_thread.?.join();
                view.close_thread = null;
                const closing_session = view.closing_session;
                view.closing_session = null;
                view.close_completion.store(.none, .release);
                switch (close_completion) {
                    .closed => {
                        view.lifecycle = .closed;
                        view.continuation = .{ .unavailable = .closed };
                        view.session = null;
                        view.close_failed = false;
                    },
                    .failed_reusable, .failed_poisoned, .failed_closing => {
                        view.session = closing_session;
                        view.close_failed = true;
                        switch (close_completion) {
                            .failed_reusable => {
                                view.lifecycle = .open;
                                view.continuation = .available;
                            },
                            .failed_poisoned => {
                                view.lifecycle = .open;
                                view.continuation = .{ .unavailable = .session_poisoned };
                            },
                            .failed_closing => {
                                view.lifecycle = .closing;
                                view.continuation = .{ .unavailable = .closing };
                            },
                            else => unreachable,
                        }
                    },
                    .none, .running => unreachable,
                }
                view.cancel_requested = false;
                changed = true;
            }
            const session = view.session;
            const pending = if (session) |value| value.pendingUiObservation() else null;
            const pending_request_id = if (pending) |value| value.request_id else 0;
            if (view.pending_ui_request_id != pending_request_id) {
                view.pending_ui_request_id = pending_request_id;
                view.pending_ui_order = 0;
                if (pending) |observation| {
                    if (findRun(view.runs, observation.run_id)) |pending_run|
                        view.pending_ui_order = takeActivityOrder(pending_run);
                }
                changed = true;
            }
            const run = findRun(view.runs, view.active_run_id) orelse continue;
            if (terminalPayload(run)) |terminal| {
                view.cancel_requested = false;
                if (!run.terminal_observed) {
                    foldTerminalDisposition(view, terminal.session_disposition_at_completion);
                    run.terminal_observed = true;
                    changed = true;
                }
                continue;
            }
            const next_phase: RunPhase = if (view.cancel_requested)
                .stopping
            else if (pending != null)
                .waiting_ui
            else switch (run.agent_handoff.load(.acquire)) {
                .queued, .starting => .queued,
                .running, .finishing => .running,
            };
            if (runPhase(run) != next_phase and setActivePhase(run, next_phase))
                changed = true;
        }
        if (changed) self.bumpRevision();
    }

    pub fn applyEvent(self: *Workbench, envelope: *const lifecycle.OwnedCoreEvent) Error!void {
        const task = self.findTask(envelope.session_id) orelse return error.UnknownTask;
        const run = findRun(task.runs, envelope.run_id) orelse return error.NoSuchRun;
        const event = switch (envelope.event.value) {
            .unknown => return,
            .known => |known| known,
        };
        switch (event) {
            .text_chunk => |text| {
                try self.appendTrackedText(&run.assistant, text, self.limits.max_assistant_message_bytes);
                if (self.redactTrackedText(&run.assistant)) run.assistant_redacted = true;
            },
            .tool_start => |tool| {
                const view = try self.findOrCreateTool(run, tool.id, tool.name, tool.input);
                view.state = .running;
                _ = try self.replaceTrackedProjected(&run.status_text, tool.name, self.limits.max_tool_field_bytes);
            },
            .tool_progress => |progress| {
                const tool = findTool(run.tools, progress.id) orelse return error.ToolCapacity;
                const projected = try self.replaceTrackedProjected(&tool.progress, progress.text, self.limits.max_tool_field_bytes);
                tool.progress_truncated = projected.truncated;
                tool.redacted = tool.redacted or projected.redacted;
            },
            .progress => |progress| _ = try self.replaceTrackedProjected(&run.status_text, progress.tool_name, self.limits.max_tool_field_bytes),
            .tool_result => |result| {
                const tool = try self.findOrCreateTool(run, result.id, result.name, result.input);
                const input = try self.replaceTrackedProjected(&tool.input, result.input, self.limits.max_tool_field_bytes);
                const content = try self.replaceTrackedProjected(&tool.content, result.content, self.limits.max_tool_field_bytes);
                tool.input_truncated = input.truncated;
                tool.content_truncated = content.truncated;
                tool.redacted = tool.redacted or input.redacted or content.redacted;
                tool.is_error = result.is_error;
                tool.elapsed_ms = result.elapsed_ms;
                tool.state = if (result.is_error) .failed else .completed;
            },
            .usage => |usage| {
                run.usage.input_tokens = try addU64(run.usage.input_tokens, usage.input_tokens);
                run.usage.output_tokens = try addU64(run.usage.output_tokens, usage.output_tokens);
                run.usage.cache_read_input_tokens = try addU64(run.usage.cache_read_input_tokens, usage.cache_read_input_tokens);
                run.usage.cache_creation_input_tokens = try addU64(run.usage.cache_creation_input_tokens, usage.cache_creation_input_tokens);
            },
            .context_warning => |warning| _ = try self.replaceTrackedProjected(&run.status_text, warning.level, self.limits.max_tool_field_bytes),
            .auto_compact => _ = try self.replaceTrackedProjected(&run.status_text, "Context compacted", self.limits.max_tool_field_bytes),
            .retry_notice => _ = try self.replaceTrackedProjected(&run.status_text, "Retrying provider", self.limits.max_tool_field_bytes),
            .stream_done => _ = try self.replaceTrackedProjected(&run.status_text, "Finishing", self.limits.max_tool_field_bytes),
        }
        self.bumpRevision();
    }

    pub fn writeSnapshot(self: *Workbench, output: []u8) Error![]const u8 {
        self.syncLifecycle();
        var writer = std.Io.Writer.fixed(output);
        writer.print("{{\"schemaVersion\":{d},\"revision\":\"{d}\",\"tasks\":[", .{ snapshot_schema_version, self.revision }) catch return error.SnapshotTooLarge;
        var task_count: usize = 0;
        for (self.tasks) |*entry| {
            const task = &(entry.* orelse continue);
            if (task_count != 0) writer.writeByte(',') catch return error.SnapshotTooLarge;
            task_count += 1;
            try self.writeTask(&writer, task);
        }
        writer.writeAll("]}") catch return error.SnapshotTooLarge;
        return writer.buffered();
    }

    pub fn deinit(self: *Workbench) void {
        self.shutdownExecutor();
        for (self.tasks) |*entry| {
            const task = &(entry.* orelse continue);
            if (task.close_thread) |thread| thread.join();
            self.deinitTaskView(task);
        }
        self.allocator.free(self.tasks);
        std.crypto.secureZero(u8, self.credential);
        self.allocator.free(self.credential);
        self.allocator.free(self.model);
        self.allocator.free(self.base_url);
        std.debug.assert(self.projection_bytes == 0);
        self.executor.deinit();
        self.* = undefined;
    }

    pub fn shutdownExecutor(self: *Workbench) void {
        if (self.executor_shutdown) return;
        self.shutting_down = true;
        for (self.tasks) |*entry| {
            const view = &(entry.* orelse continue);
            const session = view.session orelse continue;
            const run = findRun(view.runs, view.active_run_id) orelse continue;
            if (isTerminalPhase(runPhase(run))) continue;
            if (self.executor.cancel(run)) {
                cancelPreparedRunOrPanic(session, run.id);
                releaseWorkerReference(run);
                _ = commitTerminal(
                    run,
                    .interrupted,
                    .interrupted,
                    .app_shutdown,
                    .closing,
                    "",
                    false,
                );
                run.terminal_observed = true;
            } else {
                consumeLifecycleTermination(
                    requestRunTermination(run, .app_shutdown),
                    run.id,
                );
            }
        }
        self.executor.shutdown();
        self.executor_shutdown = true;
        self.syncLifecycle();
    }

    fn writeTask(self: *Workbench, writer: *std.Io.Writer, view: *TaskView) Error!void {
        writer.print("{{\"id\":\"{d}\",\"title\":", .{view.id}) catch return error.SnapshotTooLarge;
        try self.projectedJsonValue(writer, view.title);
        writer.writeAll(",\"workspaceRoot\":") catch return error.SnapshotTooLarge;
        try self.projectedJsonValue(writer, view.workspace_root);
        writer.print(",\"lifecycle\":\"{s}\",\"continuationAvailable\":{},\"archived\":{},\"closeFailed\":{},\"currentRunId\":\"{d}\",\"currentRunPhase\":", .{
            @tagName(view.lifecycle),
            self.taskContinuationAvailable(view),
            view.archived,
            view.close_failed,
            if (currentRunPhase(view) == null) 0 else view.active_run_id,
        }) catch return error.SnapshotTooLarge;
        if (currentRunPhase(view)) |phase| jsonValue(writer, @tagName(phase)) catch return error.SnapshotTooLarge else writer.writeAll("null") catch return error.SnapshotTooLarge;
        const last_terminal = lastTerminalPayload(view.runs);
        writer.writeAll(",\"lastRunOutcome\":") catch return error.SnapshotTooLarge;
        if (last_terminal) |terminal| jsonValue(writer, @tagName(terminal.outcome)) catch return error.SnapshotTooLarge else writer.writeAll("null") catch return error.SnapshotTooLarge;
        writer.writeAll(",\"cause\":") catch return error.SnapshotTooLarge;
        if (last_terminal) |terminal| {
            if (terminal.cause) |cause| jsonValue(writer, @tagName(cause)) catch return error.SnapshotTooLarge else writer.writeAll("null") catch return error.SnapshotTooLarge;
        } else writer.writeAll("null") catch return error.SnapshotTooLarge;
        writer.writeAll(",\"runs\":[") catch return error.SnapshotTooLarge;
        var run_count: usize = 0;
        for (view.runs) |*entry| {
            const run = &(entry.* orelse continue);
            if (run_count != 0) writer.writeByte(',') catch return error.SnapshotTooLarge;
            run_count += 1;
            try self.writeRun(writer, run);
        }
        writer.writeAll("],\"pendingUi\":") catch return error.SnapshotTooLarge;
        try self.writePendingUi(writer, view);
        writer.writeAll(",\"uiHistory\":[") catch return error.SnapshotTooLarge;
        try self.writeUiHistory(writer, view);
        writer.writeByte(']') catch return error.SnapshotTooLarge;
        writer.writeByte('}') catch return error.SnapshotTooLarge;
    }

    fn writePendingUi(self: *Workbench, writer: *std.Io.Writer, view: *TaskView) Error!void {
        const session = view.session orelse {
            writer.writeAll("null") catch return error.SnapshotTooLarge;
            return;
        };
        var pending = session.copyPendingUiRequest(self.allocator) catch |err| switch (err) {
            error.NoPendingUiRequest, error.StaleUiResponse => {
                writer.writeAll("null") catch return error.SnapshotTooLarge;
                return;
            },
            else => return err,
        };
        defer pending.deinit();
        var parsed = lifecycle.decodeUiRequest(self.allocator, pending.json) catch return error.InvalidUiResponse;
        defer parsed.deinit();
        // The synchronous callback may publish between lifecycle reconciliation
        // and serialization. Omit that just-arrived request from this snapshot;
        // its notification drives the next revision instead of failing the
        // whole product snapshot on a benign observation race.
        if (view.pending_ui_request_id != pending.request_id or view.pending_ui_order == 0) {
            writer.writeAll("null") catch return error.SnapshotTooLarge;
            return;
        }
        try self.writePendingUiProjection(
            writer,
            pending.request_id,
            pending.run_id,
            view.pending_ui_order,
            parsed.value,
        );
    }

    fn findOrCreateTool(
        self: *Workbench,
        run: *RunRecord,
        id: []const u8,
        name: []const u8,
        input: []const u8,
    ) Error!*ToolView {
        const route_digest = toolRouteDigest(id);
        if (findToolByRouteDigest(run.tools, route_digest)) |tool| return tool;
        const slot = findEmpty(ToolView, run.tools) orelse return error.ToolCapacity;
        const id_projection = try self.copyProjected(id, self.limits.max_tool_field_bytes);
        const owned_id = id_projection.value;
        errdefer self.freeTracked(owned_id);
        const name_projection = try self.copyProjected(name, self.limits.max_tool_field_bytes);
        const owned_name = name_projection.value;
        errdefer self.freeTracked(owned_name);
        const input_projection = try self.copyProjected(input, self.limits.max_tool_field_bytes);
        const owned_input = input_projection.value;
        errdefer self.freeTracked(owned_input);
        const progress = try self.copyBounded("", self.limits.max_tool_field_bytes);
        errdefer self.freeTracked(progress);
        const content = try self.copyBounded("", self.limits.max_tool_field_bytes);
        run.tools[slot] = .{
            .route_digest = route_digest,
            .id = owned_id,
            .order = takeActivityOrder(run),
            .name = owned_name,
            .input = owned_input,
            .progress = progress,
            .content = content,
            .state = .running,
            .input_truncated = input_projection.truncated,
            .redacted = id_projection.redacted or
                name_projection.redacted or
                input_projection.redacted,
        };
        return &run.tools[slot].?;
    }

    fn taskContinuationAvailable(self: *const Workbench, task: *const TaskView) bool {
        return !self.shutting_down and
            task.lifecycle == .open and
            continuationAvailable(task.continuation);
    }

    fn findTask(self: *Workbench, task_id: u64) ?*TaskView {
        if (task_id == 0) return null;
        for (self.tasks) |*entry| if (entry.*) |*task|
            if (task.id == task_id) return task;
        return null;
    }

    fn findTaskIndex(self: *Workbench, task_id: u64) ?usize {
        if (task_id == 0) return null;
        for (self.tasks, 0..) |entry, index|
            if (entry) |task| if (task.id == task_id) return index;
        return null;
    }

    fn reserveRunRecord(self: *Workbench, task: *TaskView, prompt: []const u8) Error!usize {
        const slot = findEmpty(RunRecord, task.runs) orelse return error.RunCapacity;
        if (task.next_run_generation == std.math.maxInt(u64)) return error.RunGenerationExhausted;
        if (prompt.len > self.limits.max_user_message_bytes)
            return error.ProjectionCapacity;
        const user_projection = try self.copyProjected(prompt, self.limits.max_user_message_bytes);
        const user = user_projection.value;
        errdefer self.freeTracked(user);
        const status_text = try self.copyBounded("Queued", self.limits.max_tool_field_bytes);
        errdefer self.freeTracked(status_text);
        const tools = try self.allocator.alloc(?ToolView, self.limits.max_tools_per_run);
        errdefer self.allocator.free(tools);
        @memset(tools, null);
        const terminal_diagnostic = try self.allocTrackedCapacity(self.limits.max_terminal_diagnostic_bytes);
        errdefer self.freeTracked(terminal_diagnostic);
        task.next_run_generation += 1;
        task.runs[slot] = .{
            .id = 0,
            .generation = task.next_run_generation,
            .user = user,
            .user_redacted = user_projection.redacted,
            .tools = tools,
            .status_text = status_text,
            .terminal_diagnostic = terminal_diagnostic,
            .redaction_secret = self.credential,
            .workbench = undefined,
            .task = undefined,
            .session = undefined,
        };
        return slot;
    }

    fn discardRunRecord(self: *Workbench, task: *TaskView, slot: usize) void {
        const run = &(task.runs[slot] orelse return);
        self.deinitRunRecord(run);
        task.runs[slot] = null;
    }

    fn deinitRunRecord(self: *Workbench, run: *RunRecord) void {
        for (run.tools) |*tool_entry| {
            const tool = &(tool_entry.* orelse continue);
            self.freeTracked(tool.id);
            self.freeTracked(tool.name);
            self.freeTracked(tool.input);
            self.freeTracked(tool.progress);
            self.freeTracked(tool.content);
        }
        self.allocator.free(run.tools);
        self.freeTracked(run.user);
        self.freeTrackedText(&run.assistant);
        self.freeTracked(run.status_text);
        self.freeTracked(run.terminal_diagnostic);
        run.* = undefined;
    }

    fn deinitTaskView(self: *Workbench, task: *TaskView) void {
        std.debug.assert(task.run_references.load(.acquire) == 0);
        for (task.runs) |*run_entry| {
            const run = &(run_entry.* orelse continue);
            self.deinitRunRecord(run);
        }
        self.allocator.free(task.runs);
        self.allocator.free(task.ui_history);
        self.freeTracked(task.workspace_root);
        self.freeTracked(task.title);
        task.* = undefined;
    }

    fn copyBounded(self: *Workbench, value: []const u8, max: usize) Error![]u8 {
        if (value.len > max or value.len > self.limits.max_projection_bytes - self.projection_bytes)
            return error.ProjectionCapacity;
        const result = try self.allocator.dupe(u8, value);
        self.projection_bytes += result.len;
        return result;
    }

    fn allocTrackedCapacity(self: *Workbench, capacity: usize) Error![]u8 {
        if (capacity > self.limits.max_projection_bytes - self.projection_bytes)
            return error.ProjectionCapacity;
        const result = try self.allocator.alloc(u8, capacity);
        self.projection_bytes += result.len;
        return result;
    }

    fn appendTrackedText(self: *Workbench, target: *TrackedText, suffix: []const u8, max: usize) Error!void {
        if (suffix.len > max - target.list.items.len) return error.ProjectionCapacity;
        const needed = target.list.items.len + suffix.len;
        if (needed > target.list.capacity) {
            const growth = @max(@as(usize, 1024), target.list.capacity / 2);
            const desired = @min(max, @max(needed, target.list.capacity + growth));
            const added_capacity = desired - target.list.capacity;
            if (added_capacity > self.limits.max_projection_bytes - self.projection_bytes)
                return error.ProjectionCapacity;
            try target.list.ensureTotalCapacityPrecise(self.allocator, desired);
            self.projection_bytes += added_capacity;
        }
        target.list.appendSliceAssumeCapacity(suffix);
    }

    const ProjectedCopy = struct {
        value: []u8,
        truncated: bool,
        redacted: bool,
    };

    fn copyProjected(self: *Workbench, value: []const u8, max: usize) Error!ProjectedCopy {
        const capacity = @min(value.len, max);
        const scratch = try self.allocator.alloc(u8, capacity);
        defer self.allocator.free(scratch);
        const result = sanitizeInto(scratch, value, self.credential);
        return .{
            .value = try self.copyBounded(scratch[0..result.len], max),
            .truncated = result.truncated,
            .redacted = result.redacted,
        };
    }

    fn replaceTrackedProjected(self: *Workbench, target: *[]u8, value: []const u8, max: usize) Error!SanitizeResult {
        const capacity = @min(value.len, max);
        const scratch = try self.allocator.alloc(u8, capacity);
        defer self.allocator.free(scratch);
        const result = sanitizeInto(scratch, value, self.credential);
        try self.replaceTracked(target, scratch[0..result.len], max);
        return result;
    }

    fn redactTrackedText(self: *Workbench, target: *TrackedText) bool {
        if (self.credential.len == 0 or target.list.items.len < self.credential.len) return false;
        var read: usize = 0;
        var write: usize = 0;
        var redacted = false;
        const marker_len = @min(self.credential.len, 3);
        while (read < target.list.items.len) {
            if (std.mem.startsWith(u8, target.list.items[read..], self.credential)) {
                @memset(target.list.items[write..][0..marker_len], '*');
                write += marker_len;
                read += self.credential.len;
                redacted = true;
            } else {
                target.list.items[write] = target.list.items[read];
                write += 1;
                read += 1;
            }
        }
        target.list.items.len = write;
        return redacted;
    }

    fn projectedJsonValue(self: *Workbench, writer: *std.Io.Writer, value: []const u8) Error!void {
        const hex = "0123456789abcdef";
        writer.writeByte('"') catch return error.SnapshotTooLarge;
        var index: usize = 0;
        while (index < value.len) {
            if (self.credential.len != 0 and std.mem.startsWith(u8, value[index..], self.credential)) {
                _ = writer.splatByte('*', @min(self.credential.len, 3)) catch return error.SnapshotTooLarge;
                index += self.credential.len;
                continue;
            }
            const byte = value[index];
            switch (byte) {
                '"' => writer.writeAll("\\\"") catch return error.SnapshotTooLarge,
                '\\' => writer.writeAll("\\\\") catch return error.SnapshotTooLarge,
                0x08 => writer.writeAll("\\b") catch return error.SnapshotTooLarge,
                0x0c => writer.writeAll("\\f") catch return error.SnapshotTooLarge,
                '\n' => writer.writeAll("\\n") catch return error.SnapshotTooLarge,
                '\r' => writer.writeAll("\\r") catch return error.SnapshotTooLarge,
                '\t' => writer.writeAll("\\t") catch return error.SnapshotTooLarge,
                0x00...0x07, 0x0b, 0x0e...0x1f => {
                    writer.writeAll("\\u00") catch return error.SnapshotTooLarge;
                    writer.writeByte(hex[byte >> 4]) catch return error.SnapshotTooLarge;
                    writer.writeByte(hex[byte & 0x0f]) catch return error.SnapshotTooLarge;
                },
                else => writer.writeByte(byte) catch return error.SnapshotTooLarge,
            }
            index += 1;
        }
        writer.writeByte('"') catch return error.SnapshotTooLarge;
    }

    fn writePendingUiProjection(
        self: *Workbench,
        writer: *std.Io.Writer,
        request_id: u64,
        run_id: u64,
        order: u64,
        request: lifecycle.UiRequest,
    ) Error!void {
        writer.print("{{\"requestId\":\"{d}\",\"runId\":\"{d}\",\"order\":\"{d}\",\"redacted\":{},", .{
            request_id,
            run_id,
            order,
            self.requestContainsSecret(request),
        }) catch return error.SnapshotTooLarge;
        switch (request) {
            .ask_question => |questions| {
                writer.writeAll("\"kind\":\"ask_question\",\"questions\":[") catch return error.SnapshotTooLarge;
                for (questions, 0..) |question, question_index| {
                    if (question_index != 0) writer.writeByte(',') catch return error.SnapshotTooLarge;
                    writer.writeAll("{\"question\":") catch return error.SnapshotTooLarge;
                    try self.projectedJsonValue(writer, question.question);
                    writer.writeAll(",\"header\":") catch return error.SnapshotTooLarge;
                    try self.projectedJsonValue(writer, question.header);
                    writer.print(",\"multi\":{},\"options\":[", .{question.multi}) catch return error.SnapshotTooLarge;
                    for (question.options, 0..) |option, option_index| {
                        if (option_index != 0) writer.writeByte(',') catch return error.SnapshotTooLarge;
                        writer.writeAll("{\"label\":") catch return error.SnapshotTooLarge;
                        try self.projectedJsonValue(writer, option.label);
                        writer.writeAll(",\"description\":") catch return error.SnapshotTooLarge;
                        try self.projectedJsonValue(writer, option.description);
                        writer.writeAll(",\"preview\":") catch return error.SnapshotTooLarge;
                        try self.projectedJsonValue(writer, option.preview);
                        writer.writeByte('}') catch return error.SnapshotTooLarge;
                    }
                    writer.writeAll("]}") catch return error.SnapshotTooLarge;
                }
                writer.writeByte(']') catch return error.SnapshotTooLarge;
            },
            .permission => |permission| {
                writer.writeAll("\"kind\":\"permission\",\"tool\":") catch return error.SnapshotTooLarge;
                try self.projectedJsonValue(writer, permission.tool);
                writer.writeAll(",\"args\":") catch return error.SnapshotTooLarge;
                try self.projectedJsonValue(writer, permission.args);
            },
        }
        writer.writeByte('}') catch return error.SnapshotTooLarge;
    }

    fn requestContainsSecret(self: *Workbench, request: lifecycle.UiRequest) bool {
        if (self.credential.len == 0) return false;
        return switch (request) {
            .ask_question => |questions| questions_block: {
                for (questions) |question| {
                    if (self.containsKnownSecret(question.question) or self.containsKnownSecret(question.header))
                        break :questions_block true;
                    for (question.options) |option|
                        if (self.containsKnownSecret(option.label) or
                            self.containsKnownSecret(option.description) or
                            self.containsKnownSecret(option.preview))
                            break :questions_block true;
                }
                break :questions_block false;
            },
            .permission => |permission| self.containsKnownSecret(permission.tool) or
                self.containsKnownSecret(permission.args),
        };
    }

    fn containsKnownSecret(self: *Workbench, value: []const u8) bool {
        return self.credential.len != 0 and std.mem.indexOf(u8, value, self.credential) != null;
    }

    fn writeRun(self: *Workbench, writer: *std.Io.Writer, run: *RunRecord) Error!void {
        const terminal = terminalPayload(run);
        writer.print("{{\"id\":\"{d}\",\"phase\":\"{s}\",\"user\":", .{ run.id, @tagName(runPhase(run)) }) catch return error.SnapshotTooLarge;
        try self.projectedJsonValue(writer, run.user);
        writer.writeAll(",\"assistant\":") catch return error.SnapshotTooLarge;
        try self.projectedJsonValue(writer, run.assistant.list.items);
        writer.print(",\"assistantRedacted\":{},\"status\":", .{run.assistant_redacted}) catch return error.SnapshotTooLarge;
        try self.projectedJsonValue(writer, run.status_text);
        writer.writeAll(",\"outcome\":") catch return error.SnapshotTooLarge;
        if (terminal) |value| jsonValue(writer, @tagName(value.outcome)) catch return error.SnapshotTooLarge else writer.writeAll("null") catch return error.SnapshotTooLarge;
        writer.writeAll(",\"cause\":") catch return error.SnapshotTooLarge;
        if (terminal) |value| {
            if (value.cause) |cause| jsonValue(writer, @tagName(cause)) catch return error.SnapshotTooLarge else writer.writeAll("null") catch return error.SnapshotTooLarge;
        } else writer.writeAll("null") catch return error.SnapshotTooLarge;
        writer.print(",\"usage\":{{\"input\":\"{d}\",\"output\":\"{d}\",\"cacheRead\":\"{d}\",\"cacheCreation\":\"{d}\"}},\"tools\":[", .{
            run.usage.input_tokens,
            run.usage.output_tokens,
            run.usage.cache_read_input_tokens,
            run.usage.cache_creation_input_tokens,
        }) catch return error.SnapshotTooLarge;
        var tool_count: usize = 0;
        for (run.tools) |*entry| {
            const tool = &(entry.* orelse continue);
            if (tool_count != 0) writer.writeByte(',') catch return error.SnapshotTooLarge;
            tool_count += 1;
            writer.writeAll("{\"id\":") catch return error.SnapshotTooLarge;
            try self.projectedJsonValue(writer, tool.id);
            writer.print(",\"order\":\"{d}\"", .{tool.order}) catch return error.SnapshotTooLarge;
            writer.writeAll(",\"name\":") catch return error.SnapshotTooLarge;
            try self.projectedJsonValue(writer, tool.name);
            writer.writeAll(",\"input\":") catch return error.SnapshotTooLarge;
            try self.projectedJsonValue(writer, tool.input);
            writer.writeAll(",\"progress\":") catch return error.SnapshotTooLarge;
            try self.projectedJsonValue(writer, tool.progress);
            writer.writeAll(",\"content\":") catch return error.SnapshotTooLarge;
            try self.projectedJsonValue(writer, tool.content);
            writer.print(",\"state\":\"{s}\",\"isError\":{},\"elapsedMs\":\"{d}\",\"inputTruncated\":{},\"progressTruncated\":{},\"contentTruncated\":{},\"redacted\":{}}}", .{
                @tagName(tool.state),
                tool.is_error,
                tool.elapsed_ms,
                tool.input_truncated,
                tool.progress_truncated,
                tool.content_truncated,
                tool.redacted,
            }) catch return error.SnapshotTooLarge;
        }
        writer.writeAll("]}") catch return error.SnapshotTooLarge;
    }

    fn prepareUiRecord(
        self: *Workbench,
        session: *lifecycle.Session,
        run_id: u64,
        request_id: u64,
        response: lifecycle.UiResponse,
    ) UiRecord {
        var record = UiRecord{
            .request_id = request_id,
            .run_id = run_id,
            .kind = kindForResponse(response),
            .state = stateForResponse(response),
        };
        var pending = session.copyPendingUiRequest(self.allocator) catch return record;
        defer pending.deinit();
        if (pending.run_id != run_id or pending.request_id != request_id) return record;
        var parsed = lifecycle.decodeUiRequest(self.allocator, pending.json) catch return record;
        defer parsed.deinit();
        record.kind = kindForRequest(parsed.value);
        self.fillUiRecord(&record, parsed.value);
        return record;
    }

    fn prepareCancelledUiRecord(
        self: *Workbench,
        session: *lifecycle.Session,
        run_id: u64,
    ) ?UiRecord {
        if (run_id == 0) return null;
        var pending = session.copyPendingUiRequest(self.allocator) catch return null;
        defer pending.deinit();
        if (pending.run_id != run_id) return null;
        var parsed = lifecycle.decodeUiRequest(self.allocator, pending.json) catch return null;
        defer parsed.deinit();
        var record = UiRecord{
            .request_id = pending.request_id,
            .run_id = run_id,
            .kind = kindForRequest(parsed.value),
            .state = .cancelled,
        };
        self.fillUiRecord(&record, parsed.value);
        return record;
    }

    fn fillUiRecord(self: *Workbench, record: *UiRecord, request: lifecycle.UiRequest) void {
        const value = switch (request) {
            .ask_question => |questions| value: {
                record.item_count = @intCast(@min(questions.len, std.math.maxInt(u32)));
                break :value if (questions.len == 0) "" else questions[0].question;
            },
            .permission => |permission| permission.args,
        };
        const result = sanitizeInto(&record.detail, value, self.credential);
        record.detail_len = result.len;
        record.detail_truncated = result.truncated;
        record.redacted = result.redacted;
    }

    fn writeUiHistory(self: *Workbench, writer: *std.Io.Writer, view: *const TaskView) Error!void {
        const start = if (view.ui_history_count == view.ui_history.len) view.ui_history_next else 0;
        for (0..view.ui_history_count) |offset| {
            if (offset != 0) writer.writeByte(',') catch return error.SnapshotTooLarge;
            const index = (start + offset) % view.ui_history.len;
            const record = &(view.ui_history[index] orelse unreachable);
            writer.print("{{\"requestId\":\"{d}\",\"runId\":\"{d}\",\"order\":\"{d}\",\"kind\":\"{s}\",\"state\":\"{s}\",\"detail\":", .{
                record.request_id,
                record.run_id,
                record.order,
                @tagName(record.kind),
                @tagName(record.state),
            }) catch return error.SnapshotTooLarge;
            try self.projectedJsonValue(writer, record.detailSlice());
            writer.print(",\"itemCount\":{d},\"detailTruncated\":{},\"redacted\":{}}}", .{
                record.item_count,
                record.detail_truncated,
                record.redacted,
            }) catch return error.SnapshotTooLarge;
        }
    }

    fn pushUiRecord(_: *Workbench, view: *TaskView, record: UiRecord) void {
        for (view.ui_history) |entry| if (entry) |existing|
            if (existing.request_id == record.request_id) return;
        var stored = record;
        if (view.pending_ui_request_id == stored.request_id and view.pending_ui_order != 0) {
            stored.order = view.pending_ui_order;
            view.pending_ui_request_id = 0;
            view.pending_ui_order = 0;
        } else {
            const run = findRun(view.runs, stored.run_id) orelse unreachable;
            stored.order = takeActivityOrder(run);
        }
        view.ui_history[view.ui_history_next] = stored;
        view.ui_history_next = (view.ui_history_next + 1) % view.ui_history.len;
        view.ui_history_count = @min(view.ui_history_count + 1, view.ui_history.len);
    }

    fn freeTrackedText(self: *Workbench, target: *TrackedText) void {
        self.projection_bytes -= target.list.capacity;
        target.list.deinit(self.allocator);
        target.* = undefined;
    }

    fn replaceTracked(self: *Workbench, target: *[]u8, value: []const u8, max: usize) Error!void {
        if (value.len > max or value.len > self.limits.max_projection_bytes - (self.projection_bytes - target.len))
            return error.ProjectionCapacity;
        const next = try self.allocator.dupe(u8, value);
        self.projection_bytes = self.projection_bytes - target.len + next.len;
        self.allocator.free(target.*);
        target.* = next;
    }

    fn freeTracked(self: *Workbench, value: []u8) void {
        self.projection_bytes -= value.len;
        self.allocator.free(value);
    }

    fn bumpRevision(self: *Workbench) void {
        if (self.revision != std.math.maxInt(u64)) self.revision += 1;
    }
};

fn closeWorker(
    agent_runtime: *lifecycle.Runtime,
    view: *TaskView,
    session: *lifecycle.Session,
) void {
    const completion: CloseCompletion = close: {
        switch (session.closeOutcome(.session_close)) {
            .closed => {},
            .failure => |failure| break :close closeFailureCompletion(
                failure.session_disposition,
            ),
        }
        agent_runtime.releaseClosedSession(session) catch
            break :close .failed_closing;
        break :close .closed;
    };
    view.close_completion.store(completion, .release);
    _ = agent_runtime.requestWake();
}

fn executeRunJob(context: *anyopaque) void {
    const run: *RunRecord = @ptrCast(@alignCast(context));
    const claimed = run.agent_handoff.cmpxchgStrong(
        .queued,
        .starting,
        .acq_rel,
        .acquire,
    );
    std.debug.assert(claimed == null);
    var agent_run = switch (run.session.beginRunOutcome(run.id)) {
        .run => |agent_run| agent_run,
        .failure => |failure| {
            run.agent_handoff.store(.finishing, .release);
            commitBeginFailure(run, failure);
            const notifier = run.workbench.change_notifier;
            releaseWorkerReference(run);
            _ = notifier.notify();
            return;
        },
    };
    run.run_control = agent_run.control();
    run.agent_handoff.store(.running, .release);
    if (run.pending_termination.load(.acquire) != .none) {
        if (run.run_control.tryAcquireLease()) |lease_value| {
            var lease = lease_value;
            const result = lease.requestTermination(pendingTerminationSignal(run));
            lease.deinit();
            if (result == .stale_run) std.debug.panic(
                "newly published RunControl for Run {d} was already stale",
                .{run.id},
            );
        }
    }
    var terminal = agent_run.execute();
    run.agent_handoff.store(.finishing, .release);
    _ = commitAgentTerminal(run, &terminal);
    terminal.deinit();
    agent_run.deinit();
    const notifier = run.workbench.change_notifier;
    releaseWorkerReference(run);
    _ = notifier.notify();
}

fn requestRunTermination(
    run: *RunRecord,
    interruption: lifecycle.ExternalInterruption,
) RunTerminationDispatch {
    const pending = pendingInterruption(interruption);
    _ = run.pending_termination.cmpxchgStrong(.none, pending, .acq_rel, .acquire);
    switch (run.agent_handoff.load(.acquire)) {
        .queued, .starting => return .pending,
        .finishing => return .already_finishing,
        .running => {},
    }
    const lease_value = run.run_control.tryAcquireLease() orelse return .already_finishing;
    var lease = lease_value;
    defer lease.deinit();
    return switch (lease.requestTermination(pendingTerminationSignal(run))) {
        .requested => .requested,
        .already_requested => .already_requested,
        .already_terminal => .already_terminal,
        .stale_run => .stale_run,
        .session_closing => .session_closing,
    };
}

fn consumeLifecycleTermination(dispatch: RunTerminationDispatch, run_id: u64) void {
    switch (dispatch) {
        .pending,
        .requested,
        .already_requested,
        .already_finishing,
        .already_terminal,
        .session_closing,
        => {},
        .stale_run => std.debug.panic(
            "active lifecycle Run {d} published a stale RunControl",
            .{run_id},
        ),
    }
}

fn pendingInterruption(interruption: lifecycle.ExternalInterruption) PendingInterruption {
    return switch (interruption) {
        .user_cancel => .user_cancel,
        .session_close => .session_close,
        .app_shutdown => .app_shutdown,
        .timeout => .timeout,
    };
}

fn pendingTerminationSignal(run: *const RunRecord) lifecycle.TerminationSignal {
    return .{ .interrupted = switch (run.pending_termination.load(.acquire)) {
        .none => unreachable,
        .user_cancel => .user_cancel,
        .timeout => .timeout,
        .session_close => .session_close,
        .app_shutdown => .app_shutdown,
    } };
}

fn cancelRunJobForShutdown(context: *anyopaque) void {
    const run: *RunRecord = @ptrCast(@alignCast(context));
    cancelPreparedRunOrPanic(run.session, run.id);
    _ = commitTerminal(
        run,
        .interrupted,
        .interrupted,
        .app_shutdown,
        .closing,
        "",
        false,
    );
    const notifier = run.workbench.change_notifier;
    releaseWorkerReference(run);
    _ = notifier.notify();
}

fn cancelPreparedRunOrPanic(
    session: *lifecycle.Session,
    run_id: u64,
) void {
    session.cancelPreparedRun(run_id) catch |err| std.debug.panic(
        "Executor removed queued Run {d}, but Agent rejected prepared cancellation: {s}",
        .{ run_id, @errorName(err) },
    );
}

fn releaseWorkerReference(run: *RunRecord) void {
    std.debug.assert(run.worker_reference_held.swap(false, .acq_rel));
    const references = &run.task.run_references;
    const previous = references.fetchSub(1, .release);
    std.debug.assert(previous != 0);
}

fn noChangeNotification(_: ?*anyopaque) bool {
    return true;
}

fn closeFailureCompletion(
    disposition: lifecycle.SessionDisposition,
) CloseCompletion {
    return switch (disposition) {
        .reusable => .failed_reusable,
        .poisoned => .failed_poisoned,
        .closing => .failed_closing,
    };
}

fn agentProvider(provider: Provider) lifecycle.ProviderKind {
    return switch (provider) {
        .anthropic => .anthropic,
        .openai => .openai,
        .gemini => .gemini,
    };
}

fn agentUiResponse(response: UiResponse) lifecycle.UiResponse {
    return switch (response) {
        .answers => |answers| .{ .answers = answers },
        .permission => |choice| .{ .permission = switch (choice) {
            .allow_once => .allow_once,
            .allow_always => .allow_always,
            .deny_once => .deny_once,
            .deny_tool_session => .deny_tool_session,
        } },
    };
}

fn phaseForOutcome(outcome: RunOutcome) RunPhase {
    return switch (outcome) {
        .completed => .completed,
        .stopped => .stopped,
        .cancelled => .cancelled,
        .interrupted => .interrupted,
        .failed, .dependency_contract_failure => .failed,
    };
}

fn commitTerminal(
    run: *RunRecord,
    phase: RunPhase,
    outcome: RunOutcome,
    cause: ?RunCause,
    session_disposition_at_completion: lifecycle.SessionDisposition,
    diagnostic: []const u8,
    source_diagnostic_truncated: bool,
) bool {
    std.debug.assert(isTerminalPhase(phase));
    if (run.terminal_publication.cmpxchgStrong(.open, .publishing, .acq_rel, .acquire) == null) {
        const diagnostic_projection = sanitizeInto(
            run.terminal_diagnostic,
            diagnostic,
            run.redaction_secret,
        );
        run.terminal_payload = .{
            .phase = phase,
            .outcome = outcome,
            .cause = cause,
            .session_disposition_at_completion = session_disposition_at_completion,
            .diagnostic_len = diagnostic_projection.len,
            .diagnostic_truncated = source_diagnostic_truncated or diagnostic_projection.truncated,
            .diagnostic_redacted = diagnostic_projection.redacted,
        };
        run.terminal_publication.store(.published, .release);
        return true;
    }
    _ = terminalPayload(run).?;
    return false;
}

const TerminalDecision = struct {
    phase: RunPhase,
    outcome: RunOutcome,
    cause: ?RunCause,
};

fn commitAgentTerminal(run: *RunRecord, result: *const lifecycle.TerminalResult) bool {
    const decision = classifyAgentTerminal(result);
    return commitTerminal(
        run,
        decision.phase,
        decision.outcome,
        decision.cause,
        result.session_disposition_at_completion,
        result.diagnostic(),
        result.diagnostic_truncated,
    );
}

fn classifyAgentTerminal(result: *const lifecycle.TerminalResult) TerminalDecision {
    if (result.failure == .dependency_contract) return .{
        .phase = .failed,
        .outcome = .dependency_contract_failure,
        .cause = .dependency_contract_failure,
    };
    if (result.failure == .abi_status) return .{
        .phase = .failed,
        .outcome = .failed,
        .cause = if (result.termination_signal) |signal| causeForSignal(signal) else null,
    };
    if (result.stop_reason) |reason| return switch (reason) {
        .end_turn => .{ .phase = .completed, .outcome = .completed, .cause = null },
        .max_turns, .tool_loop => .{ .phase = .stopped, .outcome = .stopped, .cause = null },
        .aborted => decisionForSignal(result.termination_signal),
        .tool_error, .api_error => .{
            .phase = .failed,
            .outcome = .failed,
            .cause = if (result.termination_signal) |signal| causeForSignal(signal) else null,
        },
    };
    if (result.termination_signal != null and result.raw_status_code == null)
        return decisionForSignal(result.termination_signal);
    return .{
        .phase = .failed,
        .outcome = .dependency_contract_failure,
        .cause = .dependency_contract_failure,
    };
}

fn decisionForSignal(signal: ?lifecycle.TerminationSignal) TerminalDecision {
    const value = signal orelse return .{ .phase = .failed, .outcome = .failed, .cause = null };
    return switch (value) {
        .interrupted => |interruption| switch (interruption) {
            .user_cancel, .timeout => .{
                .phase = .cancelled,
                .outcome = .cancelled,
                .cause = causeForSignal(value),
            },
            .session_close, .app_shutdown => .{
                .phase = .interrupted,
                .outcome = .interrupted,
                .cause = causeForSignal(value),
            },
        },
        .callback_failure,
        .event_pump_failure,
        .event_consumer_notification_failure,
        => .{ .phase = .failed, .outcome = .failed, .cause = causeForSignal(value) },
    };
}

fn causeForSignal(signal: lifecycle.TerminationSignal) RunCause {
    return switch (signal) {
        .interrupted => |interruption| switch (interruption) {
            .user_cancel => .user_cancel,
            .timeout => .timeout,
            .session_close => .session_close,
            .app_shutdown => .app_shutdown,
        },
        .callback_failure => |failure| switch (failure) {
            .event => .event_pipeline_failure,
            .ui => .ui_pipeline_failure,
        },
        .event_pump_failure => |failure| switch (failure) {
            .event_too_large, .capacity => .queue_capacity_failure,
            .invalid_event, .allocation, .consumer_rejected => .event_pipeline_failure,
        },
        .event_consumer_notification_failure => .event_pipeline_failure,
    };
}

fn commitBeginFailure(run: *RunRecord, failure: lifecycle.BeginRunFailure) void {
    const pending = run.pending_termination.load(.acquire);
    if (pending != .none) {
        const decision = decisionForSignal(pendingTerminationSignal(run));
        _ = commitTerminal(
            run,
            decision.phase,
            decision.outcome,
            decision.cause,
            failure.session_disposition,
            "",
            false,
        );
        return;
    }
    if (failure.err == error.SessionClosing) {
        _ = commitTerminal(
            run,
            .interrupted,
            .interrupted,
            .session_close,
            failure.session_disposition,
            "",
            false,
        );
        return;
    }
    _ = commitTerminal(
        run,
        .failed,
        .dependency_contract_failure,
        .dependency_contract_failure,
        failure.session_disposition,
        "",
        false,
    );
}

fn terminalPayload(run: *const RunRecord) ?*const TerminalPayload {
    while (true) switch (run.terminal_publication.load(.acquire)) {
        .open => return null,
        .publishing => std.atomic.spinLoopHint(),
        .published => return &run.terminal_payload,
    };
}

fn runPhase(run: *const RunRecord) RunPhase {
    return if (terminalPayload(run)) |terminal| terminal.phase else run.active_phase;
}

fn setActivePhase(run: *RunRecord, phase: RunPhase) bool {
    std.debug.assert(!isTerminalPhase(phase));
    // Terminal publication is owned by a worker and may win after the caller's
    // observation. `active_phase` is irrelevant once the write-once terminal
    // payload is published, so a late phase write is harmless; an assertion
    // here would turn a legal completion race into a process crash.
    if (run.terminal_publication.load(.acquire) != .open) return false;
    run.active_phase = phase;
    return run.terminal_publication.load(.acquire) == .open;
}

fn lastTerminalPayload(runs: []?RunRecord) ?*const TerminalPayload {
    var latest: ?*const RunRecord = null;
    for (runs) |*entry| {
        const run = &(entry.* orelse continue);
        if (latest == null or run.id > latest.?.id) latest = run;
    }
    return if (latest) |run| terminalPayload(run) else null;
}

fn currentRunPhase(view: *const TaskView) ?RunPhase {
    const run = findRun(view.runs, view.active_run_id) orelse return null;
    const phase = runPhase(run);
    return if (isTerminalPhase(phase)) null else phase;
}

fn continuationAvailable(capability: ContinuationCapability) bool {
    return switch (capability) {
        .available => true,
        .unavailable => false,
    };
}

fn foldTerminalDisposition(
    task: *TaskView,
    disposition: lifecycle.SessionDisposition,
) void {
    if (task.lifecycle != .open) return;
    switch (disposition) {
        .reusable => task.continuation = .available,
        .poisoned => task.continuation = .{ .unavailable = .session_poisoned },
        .closing => {
            task.lifecycle = .closing;
            task.continuation = .{ .unavailable = .closing };
        },
    }
}

fn hasNonTerminalRun(view: *const TaskView) bool {
    if (currentRunPhase(view)) |phase| return !isTerminalPhase(phase);
    return false;
}

fn isTerminalPhase(phase: RunPhase) bool {
    return switch (phase) {
        .queued, .running, .waiting_ui, .stopping => false,
        .completed, .stopped, .cancelled, .interrupted, .failed => true,
    };
}

const SanitizeResult = struct {
    len: usize,
    truncated: bool,
    redacted: bool,
};

fn sanitizeInto(destination: []u8, value: []const u8, secret: []const u8) SanitizeResult {
    var read: usize = 0;
    var write: usize = 0;
    var redacted = false;
    while (read < value.len) {
        if (secret.len != 0 and std.mem.startsWith(u8, value[read..], secret)) {
            const marker_len = @min(secret.len, 3);
            if (marker_len > destination.len - write) break;
            @memset(destination[write..][0..marker_len], '*');
            write += marker_len;
            read += secret.len;
            redacted = true;
            continue;
        }
        const sequence_len: usize = std.unicode.utf8ByteSequenceLength(value[read]) catch 1;
        if (sequence_len > value.len - read or sequence_len > destination.len - write) break;
        @memcpy(destination[write..][0..sequence_len], value[read..][0..sequence_len]);
        write += sequence_len;
        read += sequence_len;
    }
    return .{ .len = write, .truncated = read != value.len, .redacted = redacted };
}

fn kindForRequest(request: lifecycle.UiRequest) UiRecordKind {
    return switch (request) {
        .ask_question => .ask_question,
        .permission => .permission,
    };
}

fn kindForResponse(response: lifecycle.UiResponse) UiRecordKind {
    return switch (response) {
        .answers => .ask_question,
        .permission => .permission,
    };
}

fn stateForResponse(response: lifecycle.UiResponse) UiRecordState {
    return switch (response) {
        .answers => .answered,
        .permission => |permission| switch (permission) {
            .allow_once => .allowed_once,
            .allow_always => .allowed_always,
            .deny_once => .denied,
            .deny_tool_session => .denied_session,
        },
    };
}

fn jsonValue(writer: *std.Io.Writer, value: anytype) !void {
    try std.json.Stringify.value(value, .{ .emit_nonportable_numbers_as_strings = true }, writer);
}

fn findEmpty(comptime T: type, entries: []?T) ?usize {
    for (entries, 0..) |entry, index| if (entry == null) return index;
    return null;
}

fn findRun(entries: []?RunRecord, run_id: u64) ?*RunRecord {
    if (run_id == 0) return null;
    for (entries) |*entry| if (entry.*) |*run| if (run.id == run_id) return run;
    return null;
}

fn toolRouteDigest(id: []const u8) [tool_route_digest_bytes]u8 {
    var digest: [tool_route_digest_bytes]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(id, &digest, .{});
    return digest;
}

fn findTool(entries: []?ToolView, id: []const u8) ?*ToolView {
    return findToolByRouteDigest(entries, toolRouteDigest(id));
}

fn findToolByRouteDigest(
    entries: []?ToolView,
    route_digest: [tool_route_digest_bytes]u8,
) ?*ToolView {
    for (entries) |*entry| if (entry.*) |*tool|
        if (std.mem.eql(u8, &tool.route_digest, &route_digest)) return tool;
    return null;
}

fn addU64(left: u64, right: u64) error{ProjectionCapacity}!u64 {
    return std.math.add(u64, left, right) catch error.ProjectionCapacity;
}

fn takeActivityOrder(run: *RunRecord) u64 {
    const result = run.next_activity_order;
    std.debug.assert(result != std.math.maxInt(u64));
    run.next_activity_order += 1;
    return result;
}

fn worstCaseSnapshotBytes(limits: Limits) ?usize {
    var total = std.math.mul(usize, limits.max_projection_bytes, json_string_expansion) catch return null;
    total = std.math.add(usize, total, root_snapshot_overhead) catch return null;
    total = std.math.add(
        usize,
        total,
        std.math.mul(usize, limits.max_tasks, task_snapshot_overhead) catch return null,
    ) catch return null;
    const runs = std.math.mul(usize, limits.max_tasks, limits.max_runs_per_task) catch return null;
    total = std.math.add(
        usize,
        total,
        std.math.mul(usize, runs, run_snapshot_overhead) catch return null,
    ) catch return null;
    const tools = std.math.mul(usize, runs, limits.max_tools_per_run) catch return null;
    total = std.math.add(
        usize,
        total,
        std.math.mul(usize, tools, tool_snapshot_overhead) catch return null,
    ) catch return null;
    const pending_ui_payload = std.math.mul(
        usize,
        limits.max_pending_ui_json_bytes,
        pending_ui_reencode_expansion,
    ) catch return null;
    const pending_ui = std.math.add(
        usize,
        pending_ui_payload,
        pending_ui_snapshot_overhead,
    ) catch return null;
    total = std.math.add(
        usize,
        total,
        std.math.mul(usize, limits.max_pending_ui_requests, pending_ui) catch return null,
    ) catch return null;
    const ui_record = std.math.add(
        usize,
        std.math.mul(usize, ui_record_detail_capacity, json_string_expansion) catch return null,
        ui_record_snapshot_overhead,
    ) catch return null;
    const ui_records = std.math.mul(
        usize,
        limits.max_tasks,
        limits.max_ui_history_per_task,
    ) catch return null;
    total = std.math.add(
        usize,
        total,
        std.math.mul(usize, ui_records, ui_record) catch return null,
    ) catch return null;
    return total;
}

var test_agent_runtime: lifecycle.Runtime = undefined;
const test_execution_defaults = ExecutionDefaults{
    .provider = .anthropic,
    .credential = "SECRET-KEY",
    .model = "fixture-model",
};

fn testWorkbench() !Workbench {
    test_agent_runtime.io = std.testing.io;
    var workbench = try Workbench.init(std.testing.allocator, &test_agent_runtime, .{
        .max_tasks = 2,
        .max_runs_per_task = 2,
        .max_tools_per_run = 2,
        .max_projection_bytes = 64 * 1024,
        .max_workspace_bytes = 1024,
        .max_user_message_bytes = 1024,
        .max_assistant_message_bytes = 32 * 1024,
        .max_tool_field_bytes = 8 * 1024,
        .max_pending_ui_json_bytes = 64 * 1024,
        .max_pending_ui_requests = 2,
        .max_snapshot_bytes = 1024 * 1024,
    }, .{ .execution = test_execution_defaults });
    const workspace = try workbench.copyBounded("/tmp/metawork-test", workbench.limits.max_workspace_bytes);
    const runs = try workbench.allocator.alloc(?RunRecord, workbench.limits.max_runs_per_task);
    @memset(runs, null);
    const ui_history = try workbench.allocator.alloc(?UiRecord, workbench.limits.max_ui_history_per_task);
    @memset(ui_history, null);
    const tools = try workbench.allocator.alloc(?ToolView, workbench.limits.max_tools_per_run);
    @memset(tools, null);
    runs[0] = .{
        .id = 7,
        .generation = 1,
        .user = try workbench.copyBounded("inspect", workbench.limits.max_user_message_bytes),
        .active_phase = .running,
        .agent_handoff = .init(.running),
        .tools = tools,
        .status_text = try workbench.copyBounded("Queued", workbench.limits.max_tool_field_bytes),
        .terminal_diagnostic = try workbench.allocTrackedCapacity(workbench.limits.max_terminal_diagnostic_bytes),
    };
    workbench.tasks[0] = .{
        .session = null,
        .id = 3,
        .workspace_root = workspace,
        .title = try workbench.copyBounded("", workbench.limits.max_task_title_bytes),
        .runs = runs,
        .next_run_generation = 1,
        .ui_history = ui_history,
        .active_run_id = 7,
    };
    return workbench;
}

fn testEnvelope(session_id: u64, run_id: u64, encoded: []const u8) !lifecycle.OwnedCoreEvent {
    const allocator = std.testing.allocator;
    return .{
        .session_id = session_id,
        .run_id = run_id,
        .encoded_bytes = encoded.len,
        .json = try allocator.dupe(u8, encoded),
        .event = try lifecycle.decodeCoreEvent(allocator, encoded),
        .allocator = allocator,
    };
}

test "Workbench snapshot serializer matches the Renderer v5 contract fixture" {
    var workbench = try testWorkbench();
    defer workbench.deinit();

    var storage: [4096]u8 = undefined;
    const snapshot = try workbench.writeSnapshot(&storage);
    const fixture = std.mem.trimEnd(
        u8,
        contract_fixture.snapshot,
        "\r\n",
    );
    try std.testing.expectEqualStrings(fixture, snapshot);
}

test "Task metadata mutations preserve lifecycle guards and projection accounting" {
    var workbench = try testWorkbench();
    defer workbench.deinit();

    try std.testing.expectError(error.TaskBusy, workbench.setTaskArchived(3, true));
    try std.testing.expectError(error.TaskNotClosed, workbench.deleteTask(3));
    try std.testing.expectError(error.InvalidTaskTitle, workbench.renameTask(3, "  \n  "));
    try std.testing.expectError(error.InvalidTaskTitle, workbench.renameTask(3, "bad\ttitle"));
    try std.testing.expectError(error.InvalidTaskTitle, workbench.renameTask(3, &.{0xff}));

    try workbench.renameTask(3, "Review release readiness");
    try std.testing.expectEqualStrings("Review release readiness", workbench.tasks[0].?.title);

    workbench.tasks[0].?.active_run_id = 0;
    const completed = &workbench.tasks[0].?.runs[0].?;
    _ = commitTerminal(completed, .completed, .completed, null, .reusable, "", false);
    try workbench.setTaskArchived(3, true);
    try std.testing.expect(workbench.tasks[0].?.archived);

    workbench.tasks[0].?.lifecycle = .closing;
    workbench.tasks[0].?.continuation = .{ .unavailable = .closing };
    try std.testing.expectError(error.TaskBusy, workbench.setTaskArchived(3, false));
    workbench.tasks[0].?.lifecycle = .closed;
    workbench.tasks[0].?.continuation = .{ .unavailable = .closed };
    const tracked_before_delete = workbench.projection_bytes;
    try workbench.deleteTask(3);
    try std.testing.expect(workbench.tasks[0] == null);
    try std.testing.expect(workbench.projection_bytes < tracked_before_delete);
    try std.testing.expectError(error.UnknownTask, workbench.renameTask(3, "gone"));
}

test "Run admission reserves a stable generation and rolls back every fallible allocation" {
    var workbench = try testWorkbench();
    defer workbench.deinit();
    const task = &workbench.tasks[0].?;
    const tracked_before = workbench.projection_bytes;
    const generation_before = task.next_run_generation;
    var oversized_prompt: [1025]u8 = undefined;
    @memset(&oversized_prompt, 'x');
    try std.testing.expectError(
        error.ProjectionCapacity,
        workbench.reserveRunRecord(task, &oversized_prompt),
    );
    try std.testing.expectEqual(tracked_before, workbench.projection_bytes);
    try std.testing.expectEqual(generation_before, task.next_run_generation);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const allocator = workbench.allocator;
    workbench.allocator = failing.allocator();
    defer workbench.allocator = allocator;
    try std.testing.expectError(error.OutOfMemory, workbench.reserveRunRecord(task, "will fail"));
    workbench.allocator = allocator;
    try std.testing.expectEqual(tracked_before, workbench.projection_bytes);
    try std.testing.expectEqual(generation_before, task.next_run_generation);

    const slot = try workbench.reserveRunRecord(task, "reserved");
    const first_generation = task.runs[slot].?.generation;
    workbench.discardRunRecord(task, slot);
    const reused_slot = try workbench.reserveRunRecord(task, "reserved again");
    try std.testing.expectEqual(slot, reused_slot);
    try std.testing.expect(task.runs[reused_slot].?.generation > first_generation);
    try std.testing.expectError(error.RunCapacity, workbench.reserveRunRecord(task, "overflow"));
    workbench.discardRunRecord(task, reused_slot);
}

test "missing process defaults fail Task admission without blocking Workbench startup" {
    test_agent_runtime.io = std.testing.io;
    var workbench = try Workbench.init(
        std.testing.allocator,
        &test_agent_runtime,
        .{
            .max_tasks = 1,
            .max_runs_per_task = 1,
            .max_tools_per_run = 1,
        },
        .{ .execution = .{
            .provider = .anthropic,
            .credential = "",
            .model = "",
        } },
    );
    defer workbench.deinit();
    try std.testing.expectError(
        error.InvalidExecutionDefaults,
        workbench.createTask(.{
            .workspace_root = "/tmp",
            .trust = .{ .temporary = "/tmp" },
        }),
    );
    try std.testing.expectEqual(@as(u64, 0), workbench.currentRevision());
}

test "terminal publication is allocation-free write-once bounded history" {
    var workbench = try testWorkbench();
    defer workbench.deinit();
    const run = &workbench.tasks[0].?.runs[0].?;
    const diagnostic = try std.testing.allocator.alloc(u8, run.terminal_diagnostic.len + 17);
    defer std.testing.allocator.free(diagnostic);
    @memset(diagnostic, 'x');

    try std.testing.expect(commitTerminal(
        run,
        .failed,
        .failed,
        .event_pipeline_failure,
        .poisoned,
        diagnostic,
        false,
    ));
    const terminal = terminalPayload(run).?;
    try std.testing.expectEqual(RunPhase.failed, terminal.phase);
    try std.testing.expectEqual(RunOutcome.failed, terminal.outcome);
    try std.testing.expectEqual(@as(?RunCause, .event_pipeline_failure), terminal.cause);
    try std.testing.expectEqual(run.terminal_diagnostic.len, terminal.diagnostic_len);
    try std.testing.expect(terminal.diagnostic_truncated);
    try std.testing.expectEqualSlices(u8, diagnostic[0..run.terminal_diagnostic.len], run.terminal_diagnostic);
    try std.testing.expect(!commitTerminal(
        run,
        .failed,
        .failed,
        .event_pipeline_failure,
        .reusable,
        diagnostic,
        false,
    ));
    try std.testing.expect(!commitTerminal(
        run,
        .interrupted,
        .interrupted,
        .session_close,
        .closing,
        "late mutation",
        false,
    ));
    try std.testing.expect(!setActivePhase(run, .stopping));
    try std.testing.expectEqual(RunOutcome.failed, terminalPayload(run).?.outcome);
    try std.testing.expectEqual(@as(?RunCause, .event_pipeline_failure), terminalPayload(run).?.cause);
}

test "terminal disposition folds exactly once without reopening a closing Task" {
    var workbench = try testWorkbench();
    defer workbench.deinit();
    const task = &workbench.tasks[0].?;

    task.continuation = .available;
    foldTerminalDisposition(task, .poisoned);
    try std.testing.expectEqual(TaskLifecycle.open, task.lifecycle);
    try std.testing.expectEqual(
        ContinuationUnavailableReason.session_poisoned,
        task.continuation.unavailable,
    );

    task.lifecycle = .closing;
    task.continuation = .{ .unavailable = .closing };
    foldTerminalDisposition(task, .reusable);
    try std.testing.expectEqual(TaskLifecycle.closing, task.lifecycle);
    try std.testing.expectEqual(
        ContinuationUnavailableReason.closing,
        task.continuation.unavailable,
    );

    task.lifecycle = .closed;
    task.continuation = .{ .unavailable = .closed };
    foldTerminalDisposition(task, .reusable);
    try std.testing.expectEqual(TaskLifecycle.closed, task.lifecycle);
    try std.testing.expectEqual(
        ContinuationUnavailableReason.closed,
        task.continuation.unavailable,
    );
}

test "canonical prompt title and terminal diagnostic never retain the registered credential" {
    var workbench = try testWorkbench();
    defer workbench.deinit();
    const task = &workbench.tasks[0].?;

    try workbench.renameTask(task.id, "Review SECRET-KEY usage");
    try std.testing.expect(std.mem.indexOf(u8, task.title, "SECRET-KEY") == null);
    try std.testing.expect(task.title_redacted);

    const slot = try workbench.reserveRunRecord(task, "prompt SECRET-KEY payload");
    const run = &task.runs[slot].?;
    try std.testing.expect(std.mem.indexOf(u8, run.user, "SECRET-KEY") == null);
    try std.testing.expect(run.user_redacted);
    try std.testing.expect(commitTerminal(
        run,
        .failed,
        .failed,
        .dependency_contract_failure,
        .poisoned,
        "diagnostic SECRET-KEY payload",
        false,
    ));
    const terminal = terminalPayload(run).?;
    try std.testing.expect(terminal.diagnostic_redacted);
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            run.terminal_diagnostic[0..terminal.diagnostic_len],
            "SECRET-KEY",
        ) == null,
    );
}

test "Agent terminal facts map once into Workbench product outcomes" {
    var terminal = lifecycle.TerminalResult{
        .allocator = std.testing.allocator,
        .diagnostic_storage = &.{},
        .diagnostic_len = 0,
        .diagnostic_truncated = false,
        .abi_status = .ok,
        .raw_status_code = @intFromEnum(lifecycle.Status.ok),
        .stop_reason = .end_turn,
        .raw_stop_reason_code = @intFromEnum(lifecycle.StopReason.end_turn),
        .abort_status = null,
        .raw_abort_status_code = null,
        .termination_signal = null,
        .failure = null,
        .session_disposition_at_completion = .reusable,
    };
    try std.testing.expectEqual(
        TerminalDecision{ .phase = .completed, .outcome = .completed, .cause = null },
        classifyAgentTerminal(&terminal),
    );

    terminal.abi_status = null;
    terminal.raw_status_code = null;
    terminal.stop_reason = null;
    terminal.raw_stop_reason_code = null;
    terminal.termination_signal = .{ .interrupted = .user_cancel };
    try std.testing.expectEqual(
        TerminalDecision{ .phase = .cancelled, .outcome = .cancelled, .cause = .user_cancel },
        classifyAgentTerminal(&terminal),
    );

    terminal.raw_status_code = @intFromEnum(lifecycle.Status.callback_failed);
    terminal.failure = .abi_status;
    terminal.termination_signal = .{ .callback_failure = .ui };
    try std.testing.expectEqual(
        TerminalDecision{ .phase = .failed, .outcome = .failed, .cause = .ui_pipeline_failure },
        classifyAgentTerminal(&terminal),
    );

    terminal.failure = .dependency_contract;
    try std.testing.expectEqual(
        TerminalDecision{
            .phase = .failed,
            .outcome = .dependency_contract_failure,
            .cause = .dependency_contract_failure,
        },
        classifyAgentTerminal(&terminal),
    );
}

test "Renderer transport failures never own Agent Run termination" {
    const cases = [_]struct {
        stage: TransportFailureStage,
        decision: TransportFailureDecision,
    }{
        .{ .stage = .ingress_validation, .decision = .reject_command },
        .{ .stage = .command_dispatch, .decision = .reject_command },
        .{ .stage = .response_delivery, .decision = .detach_renderer },
        .{ .stage = .revision_delivery, .decision = .retry },
        .{ .stage = .snapshot_transport, .decision = .retry },
        .{ .stage = .connection_generation, .decision = .detach_renderer },
        .{ .stage = .agent_event_delivery, .decision = .retain_for_reconnect },
        .{ .stage = .detached_retention_expired, .decision = .discard_transport_payload },
    };
    for (cases) |case| {
        const decision = decideTransportFailure(.{ .stage = case.stage });
        try std.testing.expectEqual(case.decision, decision);
        try std.testing.expect(decision != .request_run_termination);
    }
}

test "delete waits for RunRef quiescence and stale generations fail validation" {
    const Harness = struct {
        fn wake(context: ?*anyopaque) bool {
            const count: *usize = @ptrCast(@alignCast(context.?));
            count.* += 1;
            return true;
        }
    };
    var workbench = try testWorkbench();
    defer workbench.deinit();
    var wake_count: usize = 0;
    workbench.change_notifier = .{ .context = &wake_count, .wake = Harness.wake };
    const task = &workbench.tasks[0].?;
    task.lifecycle = .closed;
    task.continuation = .{ .unavailable = .closed };
    task.active_run_id = 0;
    _ = commitTerminal(
        &task.runs[0].?,
        .completed,
        .completed,
        null,
        .reusable,
        "",
        false,
    );

    var run_ref = try workbench.acquireRunRef(3, 7);
    try std.testing.expect(run_ref.isCurrent());
    run_ref.record.generation += 1;
    try std.testing.expect(!run_ref.isCurrent());
    run_ref.record.generation = run_ref.generation;

    try workbench.deleteTask(3);
    try std.testing.expect(task.delete_pending);
    try std.testing.expect(workbench.tasks[0] != null);
    run_ref.release();
    try std.testing.expectEqual(@as(usize, 1), wake_count);
    workbench.syncLifecycle();
    try std.testing.expect(workbench.tasks[0] == null);
}

test "Workbench projection preserves text bytes with bounded geometric growth" {
    var workbench = try testWorkbench();
    defer workbench.deinit();

    const chunk = "0123456789abcdef";
    for (0..2048) |_| {
        var envelope = try testEnvelope(3, 7, "{\"text_chunk\":\"0123456789abcdef\"}");
        defer envelope.deinit();
        try workbench.applyEvent(&envelope);
    }
    const run = findRun(workbench.tasks[0].?.runs, 7).?;
    try std.testing.expectEqual(@as(usize, chunk.len * 2048), run.assistant.list.items.len);
    for (0..2048) |index|
        try std.testing.expectEqualStrings(chunk, run.assistant.list.items[index * chunk.len ..][0..chunk.len]);
    var overflow = try testEnvelope(3, 7, "{\"text_chunk\":\"x\"}");
    defer overflow.deinit();
    try std.testing.expectError(error.ProjectionCapacity, workbench.applyEvent(&overflow));
    try std.testing.expect(run.assistant.list.capacity <= workbench.limits.max_assistant_message_bytes);
    try std.testing.expect(workbench.projection_bytes <= workbench.limits.max_projection_bytes);
}

test "Workbench snapshot budget includes JSON escaping and structural overhead" {
    const limits = Limits{};
    const worst_case = worstCaseSnapshotBytes(limits).?;
    try std.testing.expect(worst_case <= limits.max_snapshot_bytes);
    try std.testing.expect(worst_case > 1024 * 1024);
    try std.testing.expectEqual(@as(usize, 512 * 1024), limits.max_projection_bytes);
    try std.testing.expectEqual(@as(usize, 16), limits.max_runs_per_task);
    const single_pending_budget = limits.max_pending_ui_json_bytes * pending_ui_reencode_expansion + pending_ui_snapshot_overhead;
    try std.testing.expect(worst_case >= single_pending_budget * limits.max_pending_ui_requests);

    var workbench = try testWorkbench();
    defer workbench.deinit();
    const run = findRun(workbench.tasks[0].?.runs, 7).?;
    const remaining = @min(
        workbench.limits.max_assistant_message_bytes,
        workbench.limits.max_projection_bytes - workbench.projection_bytes,
    );
    const controls = try std.testing.allocator.alloc(u8, remaining);
    defer std.testing.allocator.free(controls);
    @memset(controls, 1);
    try workbench.appendTrackedText(&run.assistant, controls, workbench.limits.max_assistant_message_bytes);

    const snapshot_storage = try std.testing.allocator.alloc(u8, workbench.limits.max_snapshot_bytes);
    defer std.testing.allocator.free(snapshot_storage);
    const snapshot = try workbench.writeSnapshot(snapshot_storage);
    try std.testing.expect(snapshot.len > controls.len * 5);
}

test "default snapshot budget contains the maximum structural projection" {
    const limits = Limits{};
    test_agent_runtime.io = std.testing.io;
    var workbench = try Workbench.init(
        std.testing.allocator,
        &test_agent_runtime,
        limits,
        .{ .execution = test_execution_defaults },
    );
    defer workbench.deinit();

    for (0..limits.max_tasks) |task_index| {
        const runs = try workbench.allocator.alloc(?RunRecord, limits.max_runs_per_task);
        @memset(runs, null);
        const ui_history = try workbench.allocator.alloc(?UiRecord, limits.max_ui_history_per_task);
        @memset(ui_history, null);
        for (0..limits.max_runs_per_task) |run_index| {
            const tools = try workbench.allocator.alloc(?ToolView, limits.max_tools_per_run);
            @memset(tools, null);
            for (0..limits.max_tools_per_run) |tool_index| {
                tools[tool_index] = .{
                    .route_digest = toolRouteDigest(""),
                    .id = try workbench.copyBounded("", limits.max_tool_field_bytes),
                    .order = @intCast(tool_index + 1),
                    .name = try workbench.copyBounded("", limits.max_tool_field_bytes),
                    .input = try workbench.copyBounded("", limits.max_tool_field_bytes),
                    .progress = try workbench.copyBounded("", limits.max_tool_field_bytes),
                    .content = try workbench.copyBounded("", limits.max_tool_field_bytes),
                    .state = .completed,
                    .elapsed_ms = std.math.maxInt(u64),
                };
            }
            runs[run_index] = .{
                .id = @intCast(run_index + 1),
                .generation = @intCast(run_index + 1),
                .user = try workbench.copyBounded("", limits.max_user_message_bytes),
                .tools = tools,
                .status_text = try workbench.copyBounded("", limits.max_tool_field_bytes),
                .terminal_diagnostic = try workbench.allocTrackedCapacity(limits.max_terminal_diagnostic_bytes),
            };
        }
        workbench.tasks[task_index] = .{
            .session = null,
            .id = @intCast(task_index + 1),
            .workspace_root = try workbench.copyBounded("", limits.max_workspace_bytes),
            .title = try workbench.copyBounded("", limits.max_task_title_bytes),
            .runs = runs,
            .next_run_generation = @intCast(limits.max_runs_per_task),
            .ui_history = ui_history,
        };
        for (0..limits.max_ui_history_per_task) |record_index| {
            var record = UiRecord{
                .request_id = @intCast(record_index + 1),
                .run_id = 1,
                .order = @intCast(limits.max_tools_per_run + record_index + 1),
                .kind = .permission,
                .state = .allowed_once,
                .detail_len = ui_record_detail_capacity,
                .detail_truncated = true,
            };
            @memset(&record.detail, 3);
            workbench.tasks[task_index].?.ui_history[record_index] = record;
        }
        workbench.tasks[task_index].?.ui_history_count = limits.max_ui_history_per_task;
    }

    const escaped_assistant = try std.testing.allocator.alloc(u8, limits.max_assistant_message_bytes);
    defer std.testing.allocator.free(escaped_assistant);
    @memset(escaped_assistant, 1);
    try workbench.appendTrackedText(
        &workbench.tasks[0].?.runs[0].?.assistant,
        escaped_assistant,
        limits.max_assistant_message_bytes,
    );
    const remaining_projection = limits.max_projection_bytes - workbench.projection_bytes;
    const escaped_tool = try std.testing.allocator.alloc(
        u8,
        @min(limits.max_tool_field_bytes, remaining_projection),
    );
    defer std.testing.allocator.free(escaped_tool);
    @memset(escaped_tool, 2);
    try workbench.replaceTracked(
        &workbench.tasks[0].?.runs[0].?.tools[0].?.content,
        escaped_tool,
        limits.max_tool_field_bytes,
    );
    try std.testing.expectEqual(limits.max_projection_bytes, workbench.projection_bytes);

    const storage = try std.testing.allocator.alloc(u8, limits.max_snapshot_bytes);
    defer std.testing.allocator.free(storage);
    const snapshot = try workbench.writeSnapshot(storage);
    try std.testing.expect(snapshot.len <= worstCaseSnapshotBytes(limits).?);
    try std.testing.expect(snapshot.len <= limits.max_snapshot_bytes);
}

test "pending UI re-encoding remains inside its concurrent snapshot allowance" {
    const limits = Limits{};
    const payload_len = (limits.max_pending_ui_json_bytes - 256) / json_string_expansion;
    const payload = try std.testing.allocator.alloc(u8, payload_len);
    defer std.testing.allocator.free(payload);
    @memset(payload, 1);
    const request = lifecycle.UiRequest{ .ask_question = &.{.{
        .question = payload,
        .header = "Large request",
        .multi = false,
        .options = &.{},
    }} };
    const encoded = try std.json.Stringify.valueAlloc(std.testing.allocator, request, .{});
    defer std.testing.allocator.free(encoded);
    try std.testing.expect(encoded.len <= limits.max_pending_ui_json_bytes);

    const allowance = limits.max_pending_ui_json_bytes * pending_ui_reencode_expansion + pending_ui_snapshot_overhead;
    const storage = try std.testing.allocator.alloc(u8, allowance);
    defer std.testing.allocator.free(storage);
    var writer = std.Io.Writer.fixed(storage);
    var workbench = try testWorkbench();
    defer workbench.deinit();
    try workbench.writePendingUiProjection(
        &writer,
        std.math.maxInt(u64),
        std.math.maxInt(u64),
        std.math.maxInt(u64),
        request,
    );
    try std.testing.expect(writer.buffered().len <= allowance);
}

test "Workbench projects tools and full-width usage without parsing protocol in Renderer" {
    var workbench = try testWorkbench();
    defer workbench.deinit();

    const events = [_][]const u8{
        "{\"tool_start\":{\"id\":\"tool-1\",\"name\":\"Bash\",\"input\":\"{\\\"command\\\":\\\"printf ok\\\"}\"}}",
        "{\"tool_progress\":{\"id\":\"tool-1\",\"text\":\"running\"}}",
        "{\"tool_result\":{\"id\":\"tool-1\",\"name\":\"Bash\",\"input\":\"{}\",\"content\":\"stdout\\nexit 0\",\"is_error\":false,\"elapsed_ms\":18446744073709551615}}",
        "{\"usage\":{\"input_tokens\":18446744073709551615,\"output_tokens\":0,\"cache_read_input_tokens\":0,\"cache_creation_input_tokens\":0}}",
    };
    for (events) |encoded| {
        var envelope = try testEnvelope(3, 7, encoded);
        defer envelope.deinit();
        try workbench.applyEvent(&envelope);
    }

    var snapshot_storage: [96 * 1024]u8 = undefined;
    const snapshot = try workbench.writeSnapshot(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"name\":\"Bash\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "stdout\\nexit 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"elapsedMs\":\"18446744073709551615\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"input\":\"18446744073709551615\"") != null);
}

test "known Host credentials are removed from assistant, tool, and UI projections" {
    var workbench = try testWorkbench();
    defer workbench.deinit();
    const events = [_][]const u8{
        "{\"text_chunk\":\"prefix SECRET-\"}",
        "{\"text_chunk\":\"KEY suffix\"}",
        "{\"tool_start\":{\"id\":\"tool-SECRET-KEY\",\"name\":\"Bash SECRET-KEY\",\"input\":\"SECRET-KEY\"}}",
        "{\"tool_progress\":{\"id\":\"tool-SECRET-KEY\",\"text\":\"using SECRET-KEY\"}}",
        "{\"tool_result\":{\"id\":\"tool-SECRET-KEY\",\"name\":\"Bash SECRET-KEY\",\"input\":\"SECRET-KEY\",\"content\":\"SECRET-KEY\",\"is_error\":false,\"elapsed_ms\":1}}",
    };
    for (events) |encoded| {
        var envelope = try testEnvelope(3, 7, encoded);
        defer envelope.deinit();
        try workbench.applyEvent(&envelope);
    }
    const tool = &workbench.tasks[0].?.runs[0].?.tools[0].?;
    for ([_][]const u8{
        tool.id,
        tool.name,
        tool.input,
        tool.progress,
        tool.content,
    }) |canonical_text|
        try std.testing.expect(std.mem.indexOf(u8, canonical_text, "SECRET-KEY") == null);
    try std.testing.expect(tool.redacted);
    try std.testing.expectEqual(ToolState.completed, tool.state);

    const request = lifecycle.UiRequest{ .permission = .{ .tool = "Bash", .args = "token=SECRET-KEY" } };
    var pending_storage: [4096]u8 = undefined;
    var pending_writer = std.Io.Writer.fixed(&pending_storage);
    try workbench.writePendingUiProjection(&pending_writer, 9, 7, 1, request);

    var snapshot_storage: [96 * 1024]u8 = undefined;
    const snapshot = try workbench.writeSnapshot(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "SECRET-KEY") == null);
    try std.testing.expect(std.mem.indexOf(u8, pending_writer.buffered(), "SECRET-KEY") == null);
    try std.testing.expect(std.mem.indexOf(u8, pending_writer.buffered(), "\"redacted\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "prefix *** suffix") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"id\":\"tool-***\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"name\":\"Bash ***\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"assistantRedacted\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"redacted\":true") != null);
}

test "streaming projection escaping is allocation-free JSON with redaction" {
    var workbench = try testWorkbench();
    defer workbench.deinit();
    var storage: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try workbench.projectedJsonValue(&writer, "quote\" slash\\ control\x01 line\n 界 SECRET-KEY");
    try std.testing.expectEqualStrings(
        "\"quote\\\" slash\\\\ control\\u0001 line\\n 界 ***\"",
        writer.buffered(),
    );
}

test "tool projection truncates on UTF-8 boundaries and records bounded UI history" {
    var workbench = try testWorkbench();
    defer workbench.deinit();

    const long = try std.testing.allocator.alloc(u8, workbench.limits.max_tool_field_bytes + 4);
    defer std.testing.allocator.free(long);
    @memset(long, 'x');
    @memcpy(long[long.len - 3 ..], "界");
    const projected = try workbench.copyProjected(long, workbench.limits.max_tool_field_bytes);
    defer workbench.freeTracked(projected.value);
    try std.testing.expect(projected.truncated);
    try std.testing.expect(std.unicode.utf8ValidateSlice(projected.value));

    const view = &workbench.tasks[0].?;
    for (1..11) |request_id| {
        var record = UiRecord{
            .request_id = request_id,
            .run_id = 7,
            .kind = .ask_question,
            .state = .answered,
        };
        const detail = sanitizeInto(&record.detail, "Continue?", "");
        record.detail_len = detail.len;
        workbench.pushUiRecord(view, record);
    }
    try std.testing.expectEqual(workbench.limits.max_ui_history_per_task, view.ui_history_count);
    var storage: [96 * 1024]u8 = undefined;
    const snapshot = try workbench.writeSnapshot(&storage);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"requestId\":\"1\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"requestId\":\"3\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"requestId\":\"10\"") != null);
}

test "Workbench rejects cross-session routes and usage overflow" {
    var workbench = try testWorkbench();
    defer workbench.deinit();

    var foreign_session = try testEnvelope(4, 7, "{\"text_chunk\":\"wrong\"}");
    defer foreign_session.deinit();
    try std.testing.expectError(error.UnknownTask, workbench.applyEvent(&foreign_session));

    var foreign_run = try testEnvelope(3, 8, "{\"text_chunk\":\"wrong\"}");
    defer foreign_run.deinit();
    try std.testing.expectError(error.NoSuchRun, workbench.applyEvent(&foreign_run));

    var maximum = try testEnvelope(3, 7, "{\"usage\":{\"input_tokens\":18446744073709551615}}");
    defer maximum.deinit();
    try workbench.applyEvent(&maximum);
    var overflow = try testEnvelope(3, 7, "{\"usage\":{\"input_tokens\":1}}");
    defer overflow.deinit();
    try std.testing.expectError(error.ProjectionCapacity, workbench.applyEvent(&overflow));
}

test "Workbench outcomes map to truthful terminal product phases" {
    try std.testing.expectEqual(RunPhase.completed, phaseForOutcome(.completed));
    try std.testing.expectEqual(RunPhase.stopped, phaseForOutcome(.stopped));
    try std.testing.expectEqual(RunPhase.cancelled, phaseForOutcome(.cancelled));
    try std.testing.expectEqual(RunPhase.interrupted, phaseForOutcome(.interrupted));
    try std.testing.expectEqual(RunPhase.failed, phaseForOutcome(.dependency_contract_failure));
}
