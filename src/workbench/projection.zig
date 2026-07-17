const std = @import("std");
const sdk = @import("metacodes_agentcore");
const lifecycle = @import("metawork_agentcore");
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
};

pub const Limits = struct {
    max_sessions: usize = 8,
    max_runs_per_session: usize = 16,
    max_tools_per_run: usize = 32,
    max_projection_bytes: usize = 512 * 1024,
    max_workspace_bytes: usize = 16 * 1024,
    max_task_title_bytes: usize = 512,
    max_user_message_bytes: usize = 64 * 1024,
    max_assistant_message_bytes: usize = 256 * 1024,
    max_tool_field_bytes: usize = 256 * 1024,
    max_pending_ui_json_bytes: usize = 256 * 1024,
    max_pending_ui_requests: usize = 4,
    max_ui_history_per_session: usize = 8,
    max_snapshot_bytes: usize = 8 * 1024 * 1024,
};

const json_string_expansion: usize = 6;
const pending_ui_reencode_expansion: usize = 2;
const root_snapshot_overhead: usize = 128;
const session_snapshot_overhead: usize = 512;
const run_snapshot_overhead: usize = 1024;
const tool_snapshot_overhead: usize = 512;
const pending_ui_snapshot_overhead: usize = 8 * 1024;
const ui_record_detail_capacity: usize = 512;
const ui_record_snapshot_overhead: usize = 512;
pub const snapshot_schema_version: u32 = 4;

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

const TaskLifecycle = enum { open, closing, closed };

const CloseResult = enum(u8) { none, running, closed, failed };

const TrackedText = struct {
    list: std.ArrayList(u8) = .empty,
};

const ToolView = struct {
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

const RunView = struct {
    id: u64,
    user: []u8,
    assistant: TrackedText = .{},
    assistant_redacted: bool = false,
    phase: RunPhase = .queued,
    tools: []?ToolView,
    usage: UsageView = .{},
    status_text: []u8,
    outcome: ?lifecycle.RunOutcome = null,
    cause: ?lifecycle.HostCause = null,
    next_activity_order: u64 = 1,
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

const SessionView = struct {
    session: ?*lifecycle.Session,
    id: u64,
    workspace_root: []u8,
    title: []u8,
    archived: bool = false,
    runs: []?RunView,
    ui_history: []?UiRecord,
    ui_history_count: usize = 0,
    ui_history_next: usize = 0,
    pending_ui_request_id: u64 = 0,
    pending_ui_order: u64 = 0,
    state: lifecycle.SessionState = .idle,
    active_run_id: u64 = 0,
    outcome: ?lifecycle.RunOutcome = null,
    cause: ?lifecycle.HostCause = null,
    closing_session: ?*lifecycle.Session = null,
    close_thread: ?std.Thread = null,
    close_result: std.atomic.Value(CloseResult) = .init(.none),
    close_failed: bool = false,
    cancel_requested: bool = false,
};

/// Host-owned product projection. AgentCore protocol is interpreted only
/// through the bundle SDK; the Renderer receives this bounded domain view.
/// All methods currently run on the Native loop thread.
pub const Workbench = struct {
    allocator: std.mem.Allocator,
    host: *lifecycle.Host,
    limits: Limits,
    sessions: []?SessionView,
    projection_bytes: usize = 0,
    revision: u64 = 0,
    known_secret: []u8 = &.{},

    pub fn init(
        allocator: std.mem.Allocator,
        host: *lifecycle.Host,
        limits: Limits,
    ) (std.mem.Allocator.Error || error{ProjectionCapacity})!Workbench {
        if (limits.max_sessions == 0 or limits.max_runs_per_session == 0 or
            limits.max_tools_per_run == 0 or limits.max_projection_bytes == 0 or
            limits.max_workspace_bytes == 0 or
            limits.max_task_title_bytes == 0 or
            limits.max_user_message_bytes == 0 or limits.max_assistant_message_bytes == 0 or
            limits.max_tool_field_bytes == 0 or limits.max_pending_ui_json_bytes == 0 or
            limits.max_pending_ui_requests == 0 or
            limits.max_ui_history_per_session == 0 or
            limits.max_snapshot_bytes == 0 or
            (worstCaseSnapshotBytes(limits) orelse return error.ProjectionCapacity) > limits.max_snapshot_bytes)
            return error.ProjectionCapacity;
        const sessions = try allocator.alloc(?SessionView, limits.max_sessions);
        @memset(sessions, null);
        return .{ .allocator = allocator, .host = host, .limits = limits, .sessions = sessions };
    }

    /// Registers the Host-only provider credential that must never be copied
    /// into the Renderer projection. Call this before opening any Session.
    pub fn setKnownSecret(self: *Workbench, secret: []const u8) std.mem.Allocator.Error!void {
        if (secret.len == 0) {
            if (self.known_secret.len != 0) {
                std.crypto.secureZero(u8, self.known_secret);
                self.allocator.free(self.known_secret);
                self.known_secret = &.{};
            }
            return;
        }
        const next = try self.allocator.dupe(u8, secret);
        if (self.known_secret.len != 0) {
            std.crypto.secureZero(u8, self.known_secret);
            self.allocator.free(self.known_secret);
        }
        self.known_secret = next;
    }

    pub fn createSession(
        self: *Workbench,
        options: lifecycle.SessionOpenOptions,
    ) Error!u64 {
        self.syncLifecycle();
        const slot = findEmpty(SessionView, self.sessions) orelse return error.SessionCapacity;
        const workspace = try self.copyBounded(options.workspace.canonical_root, self.limits.max_workspace_bytes);
        errdefer self.freeTracked(workspace);
        const title = try self.copyBounded("", self.limits.max_task_title_bytes);
        errdefer self.freeTracked(title);
        const runs = try self.allocator.alloc(?RunView, self.limits.max_runs_per_session);
        errdefer self.allocator.free(runs);
        @memset(runs, null);
        const ui_history = try self.allocator.alloc(?UiRecord, self.limits.max_ui_history_per_session);
        errdefer self.allocator.free(ui_history);
        @memset(ui_history, null);
        const session = self.host.createSession(options) catch |err| return err;
        const snapshot = session.snapshot();
        self.sessions[slot] = .{
            .session = session,
            .id = snapshot.session_id,
            .workspace_root = workspace,
            .title = title,
            .runs = runs,
            .ui_history = ui_history,
            .state = snapshot.state,
            .active_run_id = snapshot.active_run_id,
            .outcome = snapshot.last_outcome,
            .cause = snapshot.cause,
        };
        self.bumpRevision();
        return self.sessions[slot].?.id;
    }

    pub fn submit(self: *Workbench, session_id: u64, prompt: []const u8) Error!u64 {
        self.syncLifecycle();
        const view = self.findSession(session_id) orelse return error.UnknownSession;
        const session = view.session orelse return error.SessionClosing;
        const slot = findEmpty(RunView, view.runs) orelse return error.RunCapacity;
        const user = try self.copyBounded(prompt, self.limits.max_user_message_bytes);
        errdefer self.freeTracked(user);
        const status_text = try self.copyBounded("Queued", self.limits.max_tool_field_bytes);
        errdefer self.freeTracked(status_text);
        const tools = try self.allocator.alloc(?ToolView, self.limits.max_tools_per_run);
        errdefer self.allocator.free(tools);
        @memset(tools, null);
        const run_id = session.submit(prompt) catch |err| return err;
        view.runs[slot] = .{
            .id = run_id,
            .user = user,
            .tools = tools,
            .status_text = status_text,
        };
        view.state = .queued;
        view.active_run_id = run_id;
        view.outcome = null;
        view.cause = null;
        view.cancel_requested = false;
        self.bumpRevision();
        return run_id;
    }

    pub fn cancel(self: *Workbench, session_id: u64, run_id: u64) Error!void {
        self.syncLifecycle();
        const view = self.findSession(session_id) orelse return error.UnknownSession;
        const session = view.session orelse
            return error.SessionClosing;
        const record = self.prepareCancelledUiRecord(session, run_id);
        try session.requestCancel(run_id, .user_cancel);
        if (record) |value| self.pushUiRecord(view, value);
        view.cancel_requested = true;
        if (findRun(view.runs, run_id)) |run| run.phase = .stopping;
        self.bumpRevision();
    }

    pub fn respondUi(
        self: *Workbench,
        session_id: u64,
        run_id: u64,
        request_id: u64,
        response: sdk.UiResponse,
    ) Error!void {
        self.syncLifecycle();
        const view = self.findSession(session_id) orelse return error.UnknownSession;
        const session = view.session orelse
            return error.SessionClosing;
        const record = self.prepareUiRecord(session, run_id, request_id, response);
        try session.respondUi(run_id, request_id, response);
        self.pushUiRecord(view, record);
        self.bumpRevision();
    }

    pub fn closeSession(self: *Workbench, session_id: u64) Error!void {
        self.syncLifecycle();
        const view = self.findSession(session_id) orelse return error.UnknownSession;
        if (view.close_result.load(.acquire) == .running) return error.CloseInProgress;
        const session = view.session orelse return;
        const cancelled_ui = self.prepareCancelledUiRecord(session, view.active_run_id);
        view.session = null;
        view.closing_session = session;
        view.state = .closing;
        view.cancel_requested = view.active_run_id != 0;
        if (findRun(view.runs, view.active_run_id)) |run| {
            if (!isTerminalPhase(run.phase)) run.phase = .stopping;
        }
        view.close_failed = false;
        view.close_result.store(.running, .release);
        view.close_thread = std.Thread.spawn(.{}, closeWorker, .{ self.host, view, session }) catch |err| {
            view.close_result.store(.none, .release);
            view.closing_session = null;
            view.session = session;
            view.state = session.snapshot().state;
            return err;
        };
        if (cancelled_ui) |record|
            self.pushUiRecord(view, record);
        self.bumpRevision();
    }

    pub fn renameTask(self: *Workbench, session_id: u64, title: []const u8) Error!void {
        self.syncLifecycle();
        const view = self.findSession(session_id) orelse return error.UnknownSession;
        const trimmed = std.mem.trim(u8, title, " \t\r\n");
        if (trimmed.len == 0 or trimmed.len > self.limits.max_task_title_bytes or
            !std.unicode.utf8ValidateSlice(trimmed))
            return error.InvalidTaskTitle;
        for (trimmed) |byte| if (byte < 0x20) return error.InvalidTaskTitle;
        try self.replaceTracked(&view.title, trimmed, self.limits.max_task_title_bytes);
        self.bumpRevision();
    }

    pub fn setTaskArchived(self: *Workbench, session_id: u64, archived: bool) Error!void {
        self.syncLifecycle();
        const view = self.findSession(session_id) orelse return error.UnknownSession;
        if (view.state == .closing or hasNonTerminalRun(view)) return error.TaskBusy;
        if (view.archived == archived) return;
        view.archived = archived;
        self.bumpRevision();
    }

    pub fn deleteTask(self: *Workbench, session_id: u64) Error!void {
        self.syncLifecycle();
        const index = self.findSessionIndex(session_id) orelse return error.UnknownSession;
        const view = &(self.sessions[index] orelse unreachable);
        if (view.state != .closed or view.close_thread != null or view.session != null)
            return error.TaskNotClosed;
        self.deinitSessionView(view);
        self.sessions[index] = null;
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
        for (self.sessions) |*entry| {
            const view = &(entry.* orelse continue);
            const close_result = view.close_result.load(.acquire);
            if (close_result != .none and close_result != .running) {
                view.close_thread.?.join();
                view.close_thread = null;
                const closing_session = view.closing_session;
                view.closing_session = null;
                view.close_result.store(.none, .release);
                if (close_result == .closed) {
                    view.state = .closed;
                    view.session = null;
                    view.close_failed = false;
                    view.cancel_requested = false;
                } else if (closing_session) |session| {
                    view.session = session;
                    const snapshot = session.snapshot();
                    view.state = snapshot.state;
                    view.active_run_id = snapshot.active_run_id;
                    view.outcome = snapshot.last_outcome;
                    view.cause = snapshot.cause;
                    view.close_failed = true;
                    view.cancel_requested = false;
                }
                changed = true;
            }
            const session = view.session orelse continue;
            const snapshot = session.snapshot();
            const pending_request_id = snapshot.pending_ui_request_id orelse 0;
            if (view.pending_ui_request_id != pending_request_id) {
                view.pending_ui_request_id = pending_request_id;
                view.pending_ui_order = 0;
                if (pending_request_id != 0) {
                    if (findRun(view.runs, snapshot.active_run_id)) |pending_run|
                        view.pending_ui_order = takeActivityOrder(pending_run);
                }
                changed = true;
            }
            if (snapshot.last_outcome != null or snapshot.state == .idle or snapshot.state == .closed)
                view.cancel_requested = false;
            if (view.state != snapshot.state or view.active_run_id != snapshot.active_run_id or
                view.outcome != snapshot.last_outcome or view.cause != snapshot.cause)
            {
                view.state = snapshot.state;
                view.active_run_id = snapshot.active_run_id;
                view.outcome = snapshot.last_outcome;
                view.cause = snapshot.cause;
                changed = true;
            }
            const run = findRun(view.runs, snapshot.active_run_id) orelse continue;
            const next_phase: RunPhase = if (view.cancel_requested and
                snapshot.last_outcome == null and
                snapshot.state != .idle and snapshot.state != .closed)
                .stopping
            else
                phaseFor(snapshot);
            if (run.phase != next_phase or run.outcome != snapshot.last_outcome or run.cause != snapshot.cause) {
                run.phase = next_phase;
                run.outcome = snapshot.last_outcome;
                run.cause = snapshot.cause;
                changed = true;
            }
        }
        if (changed) self.bumpRevision();
    }

    pub fn applyEvent(self: *Workbench, envelope: *const lifecycle.EventEnvelope) Error!void {
        const session = self.findSession(envelope.session_id) orelse return error.UnknownSession;
        const run = findRun(session.runs, envelope.run_id) orelse return error.NoSuchRun;
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
        writer.print("{{\"schemaVersion\":{d},\"revision\":\"{d}\",\"sessions\":[", .{ snapshot_schema_version, self.revision }) catch return error.SnapshotTooLarge;
        var session_count: usize = 0;
        for (self.sessions) |*entry| {
            const session = &(entry.* orelse continue);
            if (session_count != 0) writer.writeByte(',') catch return error.SnapshotTooLarge;
            session_count += 1;
            try self.writeSession(&writer, session);
        }
        writer.writeAll("]}") catch return error.SnapshotTooLarge;
        return writer.buffered();
    }

    pub fn deinit(self: *Workbench) void {
        for (self.sessions) |*entry| {
            const session = &(entry.* orelse continue);
            if (session.close_thread) |thread| thread.join();
            self.deinitSessionView(session);
        }
        self.allocator.free(self.sessions);
        if (self.known_secret.len != 0) {
            std.crypto.secureZero(u8, self.known_secret);
            self.allocator.free(self.known_secret);
        }
        std.debug.assert(self.projection_bytes == 0);
        self.* = undefined;
    }

    fn writeSession(self: *Workbench, writer: *std.Io.Writer, view: *SessionView) Error!void {
        writer.print("{{\"id\":\"{d}\",\"title\":", .{view.id}) catch return error.SnapshotTooLarge;
        try self.projectedJsonValue(writer, view.title);
        writer.writeAll(",\"workspaceRoot\":") catch return error.SnapshotTooLarge;
        try self.projectedJsonValue(writer, view.workspace_root);
        writer.print(",\"lifecycle\":\"{s}\",\"continuationAvailable\":{},\"archived\":{},\"closeFailed\":{},\"currentRunId\":\"{d}\",\"currentRunPhase\":", .{
            @tagName(taskLifecycle(view.state)),
            continuationAvailable(view.state),
            view.archived,
            view.close_failed,
            if (currentRunPhase(view) == null) 0 else view.active_run_id,
        }) catch return error.SnapshotTooLarge;
        if (currentRunPhase(view)) |phase| jsonValue(writer, @tagName(phase)) catch return error.SnapshotTooLarge else writer.writeAll("null") catch return error.SnapshotTooLarge;
        writer.writeAll(",\"lastRunOutcome\":") catch return error.SnapshotTooLarge;
        if (view.outcome) |outcome| jsonValue(writer, @tagName(outcome)) catch return error.SnapshotTooLarge else writer.writeAll("null") catch return error.SnapshotTooLarge;
        writer.writeAll(",\"cause\":") catch return error.SnapshotTooLarge;
        if (view.cause) |cause| jsonValue(writer, @tagName(cause)) catch return error.SnapshotTooLarge else writer.writeAll("null") catch return error.SnapshotTooLarge;
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

    fn writePendingUi(self: *Workbench, writer: *std.Io.Writer, view: *SessionView) Error!void {
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
        var parsed = sdk.decodeUiRequest(self.allocator, pending.json) catch return error.InvalidUiResponse;
        defer parsed.deinit();
        if (view.pending_ui_request_id != pending.request_id or view.pending_ui_order == 0)
            return error.NoSuchRun;
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
        run: *RunView,
        id: []const u8,
        name: []const u8,
        input: []const u8,
    ) Error!*ToolView {
        if (findTool(run.tools, id)) |tool| return tool;
        const slot = findEmpty(ToolView, run.tools) orelse return error.ToolCapacity;
        const owned_id = try self.copyBounded(id, self.limits.max_tool_field_bytes);
        errdefer self.freeTracked(owned_id);
        const owned_name = try self.copyBounded(name, self.limits.max_tool_field_bytes);
        errdefer self.freeTracked(owned_name);
        const input_projection = try self.copyProjected(input, self.limits.max_tool_field_bytes);
        const owned_input = input_projection.value;
        errdefer self.freeTracked(owned_input);
        const progress = try self.copyBounded("", self.limits.max_tool_field_bytes);
        errdefer self.freeTracked(progress);
        const content = try self.copyBounded("", self.limits.max_tool_field_bytes);
        run.tools[slot] = .{
            .id = owned_id,
            .order = takeActivityOrder(run),
            .name = owned_name,
            .input = owned_input,
            .progress = progress,
            .content = content,
            .state = .running,
            .input_truncated = input_projection.truncated,
            .redacted = input_projection.redacted,
        };
        return &run.tools[slot].?;
    }

    fn findSession(self: *Workbench, session_id: u64) ?*SessionView {
        if (session_id == 0) return null;
        for (self.sessions) |*entry| if (entry.*) |*session|
            if (session.id == session_id) return session;
        return null;
    }

    fn findSessionIndex(self: *Workbench, session_id: u64) ?usize {
        if (session_id == 0) return null;
        for (self.sessions, 0..) |entry, index|
            if (entry) |session| if (session.id == session_id) return index;
        return null;
    }

    fn deinitSessionView(self: *Workbench, session: *SessionView) void {
        for (session.runs) |*run_entry| {
            const run = &(run_entry.* orelse continue);
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
        }
        self.allocator.free(session.runs);
        self.allocator.free(session.ui_history);
        self.freeTracked(session.workspace_root);
        self.freeTracked(session.title);
        session.* = undefined;
    }

    fn copyBounded(self: *Workbench, value: []const u8, max: usize) Error![]u8 {
        if (value.len > max or value.len > self.limits.max_projection_bytes - self.projection_bytes)
            return error.ProjectionCapacity;
        const result = try self.allocator.dupe(u8, value);
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
        const result = sanitizeInto(scratch, value, self.known_secret);
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
        const result = sanitizeInto(scratch, value, self.known_secret);
        try self.replaceTracked(target, scratch[0..result.len], max);
        return result;
    }

    fn redactTrackedText(self: *Workbench, target: *TrackedText) bool {
        if (self.known_secret.len == 0 or target.list.items.len < self.known_secret.len) return false;
        var read: usize = 0;
        var write: usize = 0;
        var redacted = false;
        const marker_len = @min(self.known_secret.len, 3);
        while (read < target.list.items.len) {
            if (std.mem.startsWith(u8, target.list.items[read..], self.known_secret)) {
                @memset(target.list.items[write..][0..marker_len], '*');
                write += marker_len;
                read += self.known_secret.len;
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
            if (self.known_secret.len != 0 and std.mem.startsWith(u8, value[index..], self.known_secret)) {
                _ = writer.splatByte('*', @min(self.known_secret.len, 3)) catch return error.SnapshotTooLarge;
                index += self.known_secret.len;
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
        request: sdk.UiRequest,
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

    fn requestContainsSecret(self: *Workbench, request: sdk.UiRequest) bool {
        if (self.known_secret.len == 0) return false;
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
        return self.known_secret.len != 0 and std.mem.indexOf(u8, value, self.known_secret) != null;
    }

    fn writeRun(self: *Workbench, writer: *std.Io.Writer, run: *RunView) Error!void {
        writer.print("{{\"id\":\"{d}\",\"phase\":\"{s}\",\"user\":", .{ run.id, @tagName(run.phase) }) catch return error.SnapshotTooLarge;
        try self.projectedJsonValue(writer, run.user);
        writer.writeAll(",\"assistant\":") catch return error.SnapshotTooLarge;
        try self.projectedJsonValue(writer, run.assistant.list.items);
        writer.print(",\"assistantRedacted\":{},\"status\":", .{run.assistant_redacted}) catch return error.SnapshotTooLarge;
        try self.projectedJsonValue(writer, run.status_text);
        writer.writeAll(",\"outcome\":") catch return error.SnapshotTooLarge;
        if (run.outcome) |outcome| jsonValue(writer, @tagName(outcome)) catch return error.SnapshotTooLarge else writer.writeAll("null") catch return error.SnapshotTooLarge;
        writer.writeAll(",\"cause\":") catch return error.SnapshotTooLarge;
        if (run.cause) |cause| jsonValue(writer, @tagName(cause)) catch return error.SnapshotTooLarge else writer.writeAll("null") catch return error.SnapshotTooLarge;
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
        response: sdk.UiResponse,
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
        var parsed = sdk.decodeUiRequest(self.allocator, pending.json) catch return record;
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
        var parsed = sdk.decodeUiRequest(self.allocator, pending.json) catch return null;
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

    fn fillUiRecord(self: *Workbench, record: *UiRecord, request: sdk.UiRequest) void {
        const value = switch (request) {
            .ask_question => |questions| value: {
                record.item_count = @intCast(@min(questions.len, std.math.maxInt(u32)));
                break :value if (questions.len == 0) "" else questions[0].question;
            },
            .permission => |permission| permission.args,
        };
        const result = sanitizeInto(&record.detail, value, self.known_secret);
        record.detail_len = result.len;
        record.detail_truncated = result.truncated;
        record.redacted = result.redacted;
    }

    fn writeUiHistory(self: *Workbench, writer: *std.Io.Writer, view: *const SessionView) Error!void {
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

    fn pushUiRecord(_: *Workbench, view: *SessionView, record: UiRecord) void {
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
    host: *lifecycle.Host,
    view: *SessionView,
    session: *lifecycle.Session,
) void {
    const result: CloseResult = close: {
        session.close(.session_close) catch break :close .failed;
        host.releaseClosedSession(session) catch break :close .failed;
        break :close .closed;
    };
    view.close_result.store(result, .release);
    _ = host.requestWake();
}

fn phaseFor(snapshot: lifecycle.SessionSnapshot) RunPhase {
    return switch (snapshot.state) {
        .queued => .queued,
        .running => .running,
        .waiting_ui => .waiting_ui,
        .closing => if (snapshot.last_outcome) |outcome| phaseForOutcome(outcome) else .running,
        .idle, .poisoned, .closed => if (snapshot.last_outcome) |outcome| phaseForOutcome(outcome) else .queued,
    };
}

fn phaseForOutcome(outcome: lifecycle.RunOutcome) RunPhase {
    return switch (outcome) {
        .completed => .completed,
        .stopped => .stopped,
        .cancelled => .cancelled,
        .interrupted => .interrupted,
        .failed, .dependency_contract_failure => .failed,
    };
}

fn taskLifecycle(state: lifecycle.SessionState) TaskLifecycle {
    return switch (state) {
        .closing => .closing,
        .closed => .closed,
        .idle, .queued, .running, .waiting_ui, .poisoned => .open,
    };
}

fn currentRunPhase(view: *const SessionView) ?RunPhase {
    return switch (view.state) {
        .queued, .running, .waiting_ui, .closing => if (findRun(view.runs, view.active_run_id)) |run|
            if (isTerminalPhase(run.phase)) null else run.phase
        else
            null,
        .idle, .poisoned, .closed => null,
    };
}

fn continuationAvailable(state: lifecycle.SessionState) bool {
    return switch (state) {
        .idle, .queued, .running, .waiting_ui => true,
        .poisoned, .closing, .closed => false,
    };
}

fn hasNonTerminalRun(view: *const SessionView) bool {
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

fn kindForRequest(request: sdk.UiRequest) UiRecordKind {
    return switch (request) {
        .ask_question => .ask_question,
        .permission => .permission,
    };
}

fn kindForResponse(response: sdk.UiResponse) UiRecordKind {
    return switch (response) {
        .answers => .ask_question,
        .permission => .permission,
    };
}

fn stateForResponse(response: sdk.UiResponse) UiRecordState {
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

fn findRun(entries: []?RunView, run_id: u64) ?*RunView {
    if (run_id == 0) return null;
    for (entries) |*entry| if (entry.*) |*run| if (run.id == run_id) return run;
    return null;
}

fn findTool(entries: []?ToolView, id: []const u8) ?*ToolView {
    for (entries) |*entry| if (entry.*) |*tool|
        if (std.mem.eql(u8, tool.id, id)) return tool;
    return null;
}

fn addU64(left: u64, right: u64) error{ProjectionCapacity}!u64 {
    return std.math.add(u64, left, right) catch error.ProjectionCapacity;
}

fn takeActivityOrder(run: *RunView) u64 {
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
        std.math.mul(usize, limits.max_sessions, session_snapshot_overhead) catch return null,
    ) catch return null;
    const runs = std.math.mul(usize, limits.max_sessions, limits.max_runs_per_session) catch return null;
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
        limits.max_sessions,
        limits.max_ui_history_per_session,
    ) catch return null;
    total = std.math.add(
        usize,
        total,
        std.math.mul(usize, ui_records, ui_record) catch return null,
    ) catch return null;
    return total;
}

fn testWorkbench() !Workbench {
    var workbench = try Workbench.init(std.testing.allocator, undefined, .{
        .max_sessions = 2,
        .max_runs_per_session = 2,
        .max_tools_per_run = 2,
        .max_projection_bytes = 64 * 1024,
        .max_workspace_bytes = 1024,
        .max_user_message_bytes = 1024,
        .max_assistant_message_bytes = 32 * 1024,
        .max_tool_field_bytes = 8 * 1024,
        .max_pending_ui_json_bytes = 64 * 1024,
        .max_pending_ui_requests = 2,
        .max_snapshot_bytes = 1024 * 1024,
    });
    const workspace = try workbench.copyBounded("/tmp/metawork-test", workbench.limits.max_workspace_bytes);
    const runs = try workbench.allocator.alloc(?RunView, workbench.limits.max_runs_per_session);
    @memset(runs, null);
    const ui_history = try workbench.allocator.alloc(?UiRecord, workbench.limits.max_ui_history_per_session);
    @memset(ui_history, null);
    const tools = try workbench.allocator.alloc(?ToolView, workbench.limits.max_tools_per_run);
    @memset(tools, null);
    runs[0] = .{
        .id = 7,
        .user = try workbench.copyBounded("inspect", workbench.limits.max_user_message_bytes),
        .phase = .running,
        .tools = tools,
        .status_text = try workbench.copyBounded("Queued", workbench.limits.max_tool_field_bytes),
    };
    workbench.sessions[0] = .{
        .session = null,
        .id = 3,
        .workspace_root = workspace,
        .title = try workbench.copyBounded("", workbench.limits.max_task_title_bytes),
        .runs = runs,
        .ui_history = ui_history,
        .state = .running,
        .active_run_id = 7,
    };
    return workbench;
}

fn testEnvelope(session_id: u64, run_id: u64, encoded: []const u8) !lifecycle.EventEnvelope {
    const allocator = std.testing.allocator;
    return .{
        .session_id = session_id,
        .run_id = run_id,
        .encoded_bytes = encoded.len,
        .json = try allocator.dupe(u8, encoded),
        .event = try sdk.decodeCoreEvent(allocator, encoded),
        .allocator = allocator,
    };
}

test "Workbench snapshot serializer matches the Renderer v4 contract fixture" {
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
    try std.testing.expectEqualStrings("Review release readiness", workbench.sessions[0].?.title);

    workbench.sessions[0].?.state = .idle;
    workbench.sessions[0].?.active_run_id = 0;
    workbench.sessions[0].?.runs[0].?.phase = .completed;
    try workbench.setTaskArchived(3, true);
    try std.testing.expect(workbench.sessions[0].?.archived);

    workbench.sessions[0].?.state = .closing;
    try std.testing.expectError(error.TaskBusy, workbench.setTaskArchived(3, false));
    workbench.sessions[0].?.state = .closed;
    const tracked_before_delete = workbench.projection_bytes;
    try workbench.deleteTask(3);
    try std.testing.expect(workbench.sessions[0] == null);
    try std.testing.expect(workbench.projection_bytes < tracked_before_delete);
    try std.testing.expectError(error.UnknownSession, workbench.renameTask(3, "gone"));
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
    const run = findRun(workbench.sessions[0].?.runs, 7).?;
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
    try std.testing.expectEqual(@as(usize, 16), limits.max_runs_per_session);
    const single_pending_budget = limits.max_pending_ui_json_bytes * pending_ui_reencode_expansion + pending_ui_snapshot_overhead;
    try std.testing.expect(worst_case >= single_pending_budget * limits.max_pending_ui_requests);

    var workbench = try testWorkbench();
    defer workbench.deinit();
    const run = findRun(workbench.sessions[0].?.runs, 7).?;
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
    var workbench = try Workbench.init(std.testing.allocator, undefined, limits);
    defer workbench.deinit();

    for (0..limits.max_sessions) |session_index| {
        const runs = try workbench.allocator.alloc(?RunView, limits.max_runs_per_session);
        @memset(runs, null);
        const ui_history = try workbench.allocator.alloc(?UiRecord, limits.max_ui_history_per_session);
        @memset(ui_history, null);
        for (0..limits.max_runs_per_session) |run_index| {
            const tools = try workbench.allocator.alloc(?ToolView, limits.max_tools_per_run);
            @memset(tools, null);
            for (0..limits.max_tools_per_run) |tool_index| {
                tools[tool_index] = .{
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
                .user = try workbench.copyBounded("", limits.max_user_message_bytes),
                .tools = tools,
                .status_text = try workbench.copyBounded("", limits.max_tool_field_bytes),
            };
        }
        workbench.sessions[session_index] = .{
            .session = null,
            .id = @intCast(session_index + 1),
            .workspace_root = try workbench.copyBounded("", limits.max_workspace_bytes),
            .title = try workbench.copyBounded("", limits.max_task_title_bytes),
            .runs = runs,
            .ui_history = ui_history,
        };
        for (0..limits.max_ui_history_per_session) |record_index| {
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
            workbench.sessions[session_index].?.ui_history[record_index] = record;
        }
        workbench.sessions[session_index].?.ui_history_count = limits.max_ui_history_per_session;
    }

    const escaped_assistant = try std.testing.allocator.alloc(u8, limits.max_assistant_message_bytes);
    defer std.testing.allocator.free(escaped_assistant);
    @memset(escaped_assistant, 1);
    try workbench.appendTrackedText(
        &workbench.sessions[0].?.runs[0].?.assistant,
        escaped_assistant,
        limits.max_assistant_message_bytes,
    );
    const escaped_tool = try std.testing.allocator.alloc(u8, limits.max_tool_field_bytes);
    defer std.testing.allocator.free(escaped_tool);
    @memset(escaped_tool, 2);
    try workbench.replaceTracked(
        &workbench.sessions[0].?.runs[0].?.tools[0].?.content,
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
    const request = sdk.UiRequest{ .ask_question = &.{.{
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
    try workbench.setKnownSecret("SECRET-KEY");

    const events = [_][]const u8{
        "{\"text_chunk\":\"prefix SECRET-\"}",
        "{\"text_chunk\":\"KEY suffix\"}",
        "{\"tool_start\":{\"id\":\"tool-secret\",\"name\":\"Bash\",\"input\":\"SECRET-KEY\"}}",
        "{\"tool_progress\":{\"id\":\"tool-secret\",\"text\":\"using SECRET-KEY\"}}",
        "{\"tool_result\":{\"id\":\"tool-secret\",\"name\":\"Bash\",\"input\":\"SECRET-KEY\",\"content\":\"SECRET-KEY\",\"is_error\":false,\"elapsed_ms\":1}}",
    };
    for (events) |encoded| {
        var envelope = try testEnvelope(3, 7, encoded);
        defer envelope.deinit();
        try workbench.applyEvent(&envelope);
    }

    const request = sdk.UiRequest{ .permission = .{ .tool = "Bash", .args = "token=SECRET-KEY" } };
    var pending_storage: [4096]u8 = undefined;
    var pending_writer = std.Io.Writer.fixed(&pending_storage);
    try workbench.writePendingUiProjection(&pending_writer, 9, 7, 1, request);

    var snapshot_storage: [96 * 1024]u8 = undefined;
    const snapshot = try workbench.writeSnapshot(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "SECRET-KEY") == null);
    try std.testing.expect(std.mem.indexOf(u8, pending_writer.buffered(), "SECRET-KEY") == null);
    try std.testing.expect(std.mem.indexOf(u8, pending_writer.buffered(), "\"redacted\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "prefix *** suffix") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"assistantRedacted\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"redacted\":true") != null);
}

test "streaming projection escaping is allocation-free JSON with redaction" {
    var workbench = try testWorkbench();
    defer workbench.deinit();
    try workbench.setKnownSecret("SECRET-KEY");

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

    const view = &workbench.sessions[0].?;
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
    try std.testing.expectEqual(workbench.limits.max_ui_history_per_session, view.ui_history_count);
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
    try std.testing.expectError(error.UnknownSession, workbench.applyEvent(&foreign_session));

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

test "lifecycle outcomes map to truthful terminal product phases" {
    const base = lifecycle.SessionSnapshot{
        .session_id = 1,
        .state = .idle,
        .workspace_root = "/tmp",
        .active_run_id = 1,
        .pending_ui_request_id = null,
        .cause = null,
        .last_status = null,
        .last_abort_status = null,
        .last_stop_reason_code = null,
        .last_outcome = .completed,
    };
    try std.testing.expectEqual(RunPhase.completed, phaseFor(base));
    var value = base;
    value.last_outcome = .stopped;
    try std.testing.expectEqual(RunPhase.stopped, phaseFor(value));
    value.last_outcome = .cancelled;
    try std.testing.expectEqual(RunPhase.cancelled, phaseFor(value));
    value.last_outcome = .interrupted;
    try std.testing.expectEqual(RunPhase.interrupted, phaseFor(value));
    value.last_outcome = .dependency_contract_failure;
    try std.testing.expectEqual(RunPhase.failed, phaseFor(value));
}
