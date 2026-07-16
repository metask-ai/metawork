const std = @import("std");
const sdk = @import("metacodes_agentcore");
const lifecycle = @import("host_lifecycle");
const contract_fixture = @import("workbench_contract_fixture");

pub const Error = lifecycle.Error || std.mem.Allocator.Error || std.Thread.SpawnError || error{
    ProjectionCapacity,
    RunCapacity,
    ToolCapacity,
    SnapshotTooLarge,
    CloseInProgress,
};

pub const Limits = struct {
    max_sessions: usize = 8,
    max_runs_per_session: usize = 16,
    max_tools_per_run: usize = 32,
    max_projection_bytes: usize = 512 * 1024,
    max_workspace_bytes: usize = 16 * 1024,
    max_user_message_bytes: usize = 64 * 1024,
    max_assistant_message_bytes: usize = 256 * 1024,
    max_tool_field_bytes: usize = 256 * 1024,
    max_pending_ui_json_bytes: usize = 256 * 1024,
    max_pending_ui_requests: usize = 4,
    max_snapshot_bytes: usize = 8 * 1024 * 1024,
};

const json_string_expansion: usize = 6;
const pending_ui_reencode_expansion: usize = 2;
const root_snapshot_overhead: usize = 128;
const session_snapshot_overhead: usize = 512;
const run_snapshot_overhead: usize = 1024;
const tool_snapshot_overhead: usize = 512;
const pending_ui_snapshot_overhead: usize = 8 * 1024;
pub const snapshot_schema_version: u32 = 1;

const ToolState = enum { running, completed, failed };
const RunPhase = enum {
    queued,
    running,
    waiting_ui,
    completed,
    stopped,
    cancelled,
    interrupted,
    failed,
};

const CloseResult = enum(u8) { none, running, closed, failed };

const TrackedText = struct {
    list: std.ArrayList(u8) = .empty,
};

const ToolView = struct {
    id: []u8,
    name: []u8,
    input: []u8,
    progress: []u8,
    content: []u8,
    state: ToolState,
    is_error: bool = false,
    elapsed_ms: u64 = 0,
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
    phase: RunPhase = .queued,
    tools: []?ToolView,
    usage: UsageView = .{},
    status_text: []u8,
    outcome: ?lifecycle.RunOutcome = null,
    cause: ?lifecycle.HostCause = null,
};

const SessionView = struct {
    session: ?*lifecycle.Session,
    id: u64,
    workspace_root: []u8,
    runs: []?RunView,
    state: lifecycle.SessionState = .idle,
    active_run_id: u64 = 0,
    outcome: ?lifecycle.RunOutcome = null,
    cause: ?lifecycle.HostCause = null,
    closing_session: ?*lifecycle.Session = null,
    close_thread: ?std.Thread = null,
    close_result: std.atomic.Value(CloseResult) = .init(.none),
    close_failed: bool = false,
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

    pub fn init(
        allocator: std.mem.Allocator,
        host: *lifecycle.Host,
        limits: Limits,
    ) (std.mem.Allocator.Error || error{ProjectionCapacity})!Workbench {
        if (limits.max_sessions == 0 or limits.max_runs_per_session == 0 or
            limits.max_tools_per_run == 0 or limits.max_projection_bytes == 0 or
            limits.max_workspace_bytes == 0 or
            limits.max_user_message_bytes == 0 or limits.max_assistant_message_bytes == 0 or
            limits.max_tool_field_bytes == 0 or limits.max_pending_ui_json_bytes == 0 or
            limits.max_pending_ui_requests == 0 or
            limits.max_snapshot_bytes == 0 or
            (worstCaseSnapshotBytes(limits) orelse return error.ProjectionCapacity) > limits.max_snapshot_bytes)
            return error.ProjectionCapacity;
        const sessions = try allocator.alloc(?SessionView, limits.max_sessions);
        @memset(sessions, null);
        return .{ .allocator = allocator, .host = host, .limits = limits, .sessions = sessions };
    }

    pub fn createSession(
        self: *Workbench,
        options: lifecycle.SessionOpenOptions,
    ) Error!u64 {
        self.syncLifecycle();
        const slot = findEmpty(SessionView, self.sessions) orelse self.findReusableClosed() orelse
            return error.SessionCapacity;
        if (self.sessions[slot]) |*prior| {
            self.deinitSessionView(prior);
            self.sessions[slot] = null;
        }
        const workspace = try self.copyBounded(options.workspace.canonical_root, self.limits.max_workspace_bytes);
        errdefer self.freeTracked(workspace);
        const runs = try self.allocator.alloc(?RunView, self.limits.max_runs_per_session);
        errdefer self.allocator.free(runs);
        @memset(runs, null);
        const session = self.host.createSession(options) catch |err| return err;
        const snapshot = session.snapshot();
        self.sessions[slot] = .{
            .session = session,
            .id = snapshot.session_id,
            .workspace_root = workspace,
            .runs = runs,
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
        self.bumpRevision();
        return run_id;
    }

    pub fn cancel(self: *Workbench, session_id: u64, run_id: u64) Error!void {
        self.syncLifecycle();
        const session = (self.findSession(session_id) orelse return error.UnknownSession).session orelse
            return error.SessionClosing;
        try session.requestCancel(run_id, .user_cancel);
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
        const session = (self.findSession(session_id) orelse return error.UnknownSession).session orelse
            return error.SessionClosing;
        try session.respondUi(run_id, request_id, response);
        self.bumpRevision();
    }

    pub fn closeSession(self: *Workbench, session_id: u64) Error!void {
        self.syncLifecycle();
        const view = self.findSession(session_id) orelse return error.UnknownSession;
        if (view.close_result.load(.acquire) == .running) return error.CloseInProgress;
        const session = view.session orelse return;
        view.session = null;
        view.closing_session = session;
        view.state = .closing;
        view.close_failed = false;
        view.close_result.store(.running, .release);
        view.close_thread = std.Thread.spawn(.{}, closeWorker, .{ self.host, view, session }) catch |err| {
            view.close_result.store(.none, .release);
            view.closing_session = null;
            view.session = session;
            view.state = session.snapshot().state;
            return err;
        };
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
                } else if (closing_session) |session| {
                    view.session = session;
                    const snapshot = session.snapshot();
                    view.state = snapshot.state;
                    view.active_run_id = snapshot.active_run_id;
                    view.outcome = snapshot.last_outcome;
                    view.cause = snapshot.cause;
                    view.close_failed = true;
                }
                changed = true;
            }
            const session = view.session orelse continue;
            const snapshot = session.snapshot();
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
            const next_phase = phaseFor(snapshot);
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
        switch (envelope.event.value) {
            .text_chunk => |text| try self.appendTrackedText(&run.assistant, text, self.limits.max_assistant_message_bytes),
            .stream_begin => {
                run.phase = .running;
                try self.replaceTracked(&run.status_text, "Generating", self.limits.max_tool_field_bytes);
            },
            .tool_start => |tool| {
                const view = try self.findOrCreateTool(run, tool.id, tool.name, tool.input);
                view.state = .running;
                try self.replaceTracked(&run.status_text, tool.name, self.limits.max_tool_field_bytes);
            },
            .set_current_tool => |tool| try self.replaceTracked(&run.status_text, tool.name, self.limits.max_tool_field_bytes),
            .tool_progress => |progress| {
                const tool = findTool(run.tools, progress.id) orelse return error.ToolCapacity;
                try self.replaceTracked(&tool.progress, progress.text, self.limits.max_tool_field_bytes);
            },
            .progress => |progress| try self.replaceTracked(&run.status_text, progress.tool_name, self.limits.max_tool_field_bytes),
            .clear_current_tool => try self.replaceTracked(&run.status_text, "Running", self.limits.max_tool_field_bytes),
            .tool_result => |result| {
                const tool = try self.findOrCreateTool(run, result.id, result.name, result.input);
                try self.replaceTracked(&tool.content, result.content, self.limits.max_tool_field_bytes);
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
            .context_warning => |warning| try self.replaceTracked(&run.status_text, warning.level, self.limits.max_tool_field_bytes),
            .auto_compact => try self.replaceTracked(&run.status_text, "Context compacted", self.limits.max_tool_field_bytes),
            .retry_notice => try self.replaceTracked(&run.status_text, "Retrying provider", self.limits.max_tool_field_bytes),
            .stream_done => try self.replaceTracked(&run.status_text, "Finishing", self.limits.max_tool_field_bytes),
            .diag_turn_begin,
            .diag_turn_end,
            .diag_breaker_tripped,
            .diag_cache_break,
            .diag_continuation,
            .diag_run_end,
            => {},
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
        std.debug.assert(self.projection_bytes == 0);
        self.* = undefined;
    }

    fn writeSession(self: *Workbench, writer: *std.Io.Writer, view: *SessionView) Error!void {
        writer.print("{{\"id\":\"{d}\",\"workspaceRoot\":", .{view.id}) catch return error.SnapshotTooLarge;
        jsonValue(writer, view.workspace_root) catch return error.SnapshotTooLarge;
        writer.print(",\"state\":\"{s}\",\"closeFailed\":{},\"activeRunId\":\"{d}\",\"outcome\":", .{ @tagName(view.state), view.close_failed, view.active_run_id }) catch return error.SnapshotTooLarge;
        if (view.outcome) |outcome| jsonValue(writer, @tagName(outcome)) catch return error.SnapshotTooLarge else writer.writeAll("null") catch return error.SnapshotTooLarge;
        writer.writeAll(",\"cause\":") catch return error.SnapshotTooLarge;
        if (view.cause) |cause| jsonValue(writer, @tagName(cause)) catch return error.SnapshotTooLarge else writer.writeAll("null") catch return error.SnapshotTooLarge;
        writer.writeAll(",\"runs\":[") catch return error.SnapshotTooLarge;
        var run_count: usize = 0;
        for (view.runs) |*entry| {
            const run = &(entry.* orelse continue);
            if (run_count != 0) writer.writeByte(',') catch return error.SnapshotTooLarge;
            run_count += 1;
            try writeRun(writer, run);
        }
        writer.writeAll("],\"pendingUi\":") catch return error.SnapshotTooLarge;
        try self.writePendingUi(writer, view);
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
        try writePendingUiProjection(writer, pending.request_id, pending.run_id, parsed.value);
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
        const owned_input = try self.copyBounded(input, self.limits.max_tool_field_bytes);
        errdefer self.freeTracked(owned_input);
        const progress = try self.copyBounded("", self.limits.max_tool_field_bytes);
        errdefer self.freeTracked(progress);
        const content = try self.copyBounded("", self.limits.max_tool_field_bytes);
        run.tools[slot] = .{
            .id = owned_id,
            .name = owned_name,
            .input = owned_input,
            .progress = progress,
            .content = content,
            .state = .running,
        };
        return &run.tools[slot].?;
    }

    fn findSession(self: *Workbench, session_id: u64) ?*SessionView {
        if (session_id == 0) return null;
        for (self.sessions) |*entry| if (entry.*) |*session|
            if (session.id == session_id) return session;
        return null;
    }

    fn findReusableClosed(self: *Workbench) ?usize {
        for (self.sessions, 0..) |entry, index| {
            const session = entry orelse continue;
            if (session.state == .closed and session.close_thread == null) return index;
        }
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
        self.freeTracked(session.workspace_root);
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

fn writePendingUiProjection(
    writer: *std.Io.Writer,
    request_id: u64,
    run_id: u64,
    request: sdk.UiRequest,
) Error!void {
    writer.print("{{\"requestId\":\"{d}\",\"runId\":\"{d}\",", .{ request_id, run_id }) catch return error.SnapshotTooLarge;
    switch (request) {
        .ask_question => |questions| {
            writer.writeAll("\"kind\":\"ask_question\",\"questions\":") catch return error.SnapshotTooLarge;
            jsonValue(writer, questions) catch return error.SnapshotTooLarge;
        },
        .permission => |permission| {
            writer.writeAll("\"kind\":\"permission\",\"tool\":") catch return error.SnapshotTooLarge;
            jsonValue(writer, permission.tool) catch return error.SnapshotTooLarge;
            writer.writeAll(",\"args\":") catch return error.SnapshotTooLarge;
            jsonValue(writer, permission.args) catch return error.SnapshotTooLarge;
        },
        .plan_approval => |plan| {
            writer.writeAll("\"kind\":\"plan_approval\",\"plan\":") catch return error.SnapshotTooLarge;
            jsonValue(writer, plan.plan_md) catch return error.SnapshotTooLarge;
        },
        .custom => |custom| {
            writer.writeAll("\"kind\":\"custom\",\"customKind\":") catch return error.SnapshotTooLarge;
            jsonValue(writer, custom.kind) catch return error.SnapshotTooLarge;
            writer.writeAll(",\"payload\":") catch return error.SnapshotTooLarge;
            jsonValue(writer, custom.payload_json) catch return error.SnapshotTooLarge;
        },
    }
    writer.writeByte('}') catch return error.SnapshotTooLarge;
}

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
        .idle, .closed => if (snapshot.last_outcome) |outcome| phaseForOutcome(outcome) else .queued,
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

fn writeRun(writer: *std.Io.Writer, run: *RunView) Error!void {
    writer.print("{{\"id\":\"{d}\",\"phase\":\"{s}\",\"user\":", .{ run.id, @tagName(run.phase) }) catch return error.SnapshotTooLarge;
    jsonValue(writer, run.user) catch return error.SnapshotTooLarge;
    writer.writeAll(",\"assistant\":") catch return error.SnapshotTooLarge;
    jsonValue(writer, run.assistant.list.items) catch return error.SnapshotTooLarge;
    writer.writeAll(",\"status\":") catch return error.SnapshotTooLarge;
    jsonValue(writer, run.status_text) catch return error.SnapshotTooLarge;
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
        jsonValue(writer, tool.id) catch return error.SnapshotTooLarge;
        writer.writeAll(",\"name\":") catch return error.SnapshotTooLarge;
        jsonValue(writer, tool.name) catch return error.SnapshotTooLarge;
        writer.writeAll(",\"input\":") catch return error.SnapshotTooLarge;
        jsonValue(writer, tool.input) catch return error.SnapshotTooLarge;
        writer.writeAll(",\"progress\":") catch return error.SnapshotTooLarge;
        jsonValue(writer, tool.progress) catch return error.SnapshotTooLarge;
        writer.writeAll(",\"content\":") catch return error.SnapshotTooLarge;
        jsonValue(writer, tool.content) catch return error.SnapshotTooLarge;
        writer.print(",\"state\":\"{s}\",\"isError\":{},\"elapsedMs\":\"{d}\"}}", .{ @tagName(tool.state), tool.is_error, tool.elapsed_ms }) catch return error.SnapshotTooLarge;
    }
    writer.writeAll("]}") catch return error.SnapshotTooLarge;
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
    const tools = try workbench.allocator.alloc(?ToolView, workbench.limits.max_tools_per_run);
    @memset(tools, null);
    runs[0] = .{
        .id = 7,
        .user = try workbench.copyBounded("inspect", workbench.limits.max_user_message_bytes),
        .tools = tools,
        .status_text = try workbench.copyBounded("Queued", workbench.limits.max_tool_field_bytes),
    };
    workbench.sessions[0] = .{
        .session = null,
        .id = 3,
        .workspace_root = workspace,
        .runs = runs,
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

test "Workbench snapshot serializer matches the Renderer v1 contract fixture" {
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
        for (0..limits.max_runs_per_session) |run_index| {
            const tools = try workbench.allocator.alloc(?ToolView, limits.max_tools_per_run);
            @memset(tools, null);
            for (0..limits.max_tools_per_run) |tool_index| {
                tools[tool_index] = .{
                    .id = try workbench.copyBounded("", limits.max_tool_field_bytes),
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
            .runs = runs,
        };
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
    const request = sdk.UiRequest{ .custom = .{ .kind = "custom", .payload_json = payload } };
    const encoded = try std.json.Stringify.valueAlloc(std.testing.allocator, request, .{});
    defer std.testing.allocator.free(encoded);
    try std.testing.expect(encoded.len <= limits.max_pending_ui_json_bytes);

    const allowance = limits.max_pending_ui_json_bytes * pending_ui_reencode_expansion + pending_ui_snapshot_overhead;
    const storage = try std.testing.allocator.alloc(u8, allowance);
    defer std.testing.allocator.free(storage);
    var writer = std.Io.Writer.fixed(storage);
    try writePendingUiProjection(
        &writer,
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
        "{\"stream_begin\":{}}",
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
