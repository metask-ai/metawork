//! Pure Workbench-owned Product Task snapshot derivation.
//! This module borrows Task state plus callback-scoped text, catalog, and
//! pending-UI projectors. It owns no allocator, credential, Session, worker,
//! durable effect, revision, or root snapshot orchestration.

const std = @import("std");
const agent = @import("metawork_agent");
const product_skill = @import("metawork_product_skill");
const task_state = @import("product_task_state");
const task_policy = @import("product_task_policy");
const task_recovery = @import("product_task_recovery");
const view_contract = @import("product_task_view_contract");

pub const Error = std.mem.Allocator.Error || error{
    SnapshotTooLarge,
    InvalidUiResponse,
};

const max_permission_presentation_input_bytes: usize = 128 * 1024;
pub const max_permission_presentation_bytes: usize = 4 * 1024;

// Borrowed parser scratch with the same FixedBufferAllocator behavior. Keep
// the high-water mark across free, shrink and reset so every formerly owned
// byte is scrubbed, without touching the unused part of each 128 KiB buffer.
const JsonScratch = struct {
    fixed: std.heap.FixedBufferAllocator,
    used: usize = 0,

    fn init(bytes: []u8) JsonScratch {
        return .{ .fixed = .init(bytes) };
    }
    fn allocator(self: *JsonScratch) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn reset(self: *JsonScratch) void {
        self.fixed.reset();
    }
    fn clear(self: *JsonScratch) void {
        std.crypto.secureZero(u8, self.fixed.buffer[0..self.used]);
        self.fixed.reset();
        self.used = 0;
    }
    fn alloc(context: *anyopaque, size: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *JsonScratch = @ptrCast(@alignCast(context));
        const result = std.heap.FixedBufferAllocator.alloc(&self.fixed, size, alignment, ra);
        self.used = @max(self.used, self.fixed.end_index);
        return result;
    }
    fn resize(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, size: usize, ra: usize) bool {
        const self: *JsonScratch = @ptrCast(@alignCast(context));
        const result = std.heap.FixedBufferAllocator.resize(&self.fixed, bytes, alignment, size, ra);
        self.used = @max(self.used, self.fixed.end_index);
        return result;
    }
    fn remap(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, size: usize, ra: usize) ?[*]u8 {
        return if (resize(context, bytes, alignment, size, ra)) bytes.ptr else null;
    }
    fn free(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *JsonScratch = @ptrCast(@alignCast(context));
        std.heap.FixedBufferAllocator.free(&self.fixed, bytes, alignment, ra);
    }
};

test "Product view JSON scratch scrubs freed shrunk remapped reset and failed-parse allocations" {
    var bytes: [4096]u8 = @splat(0xa5);
    var scratch = JsonScratch.init(&bytes);
    defer scratch.clear();
    const allocator = scratch.allocator();
    const first = try allocator.alloc(u8, 32);
    @memset(first, 's');
    try std.testing.expect(allocator.resize(first, 8));
    allocator.free(@as([]u8, first[0..8]));
    scratch.reset();
    const second = try allocator.alloc(u8, 4);
    @memset(second, 't');
    const expanded = allocator.remap(second, 48);
    try std.testing.expect(expanded != null);
    @memset(expanded.?, 'u');
    allocator.free(expanded.?);
    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, bytes.len + 1));
    scratch.clear();
    try std.testing.expectEqualSlices(u8, &(@as([48]u8, @splat(0))), bytes[0..48]);
    try std.testing.expectEqual(@as(u8, 0xa5), bytes[48]);

    // A failed parser may already have decoded sensitive text and freed its
    // arena. The high-water mark must survive that implicit deallocation.
    try std.testing.expectError(error.UnexpectedEndOfInput, std.json.parseFromSlice(
        struct { value: []const u8 },
        allocator,
        "{\"value\":\"sensitive\\ntext\"",
        .{},
    ));
    const used = scratch.used;
    try std.testing.expect(used > 0);
    scratch.clear();
    for (bytes[0..used]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

pub const ModelSelectionAvailability = enum {
    available,
    catalog_loading,
    catalog_unavailable,
    task_unavailable,
};

/// Callback-scoped access to Workbench's global sensitive-text projection.
/// The callbacks expose neither credential bytes nor the composition object.
pub const TextProjection = struct {
    context: *const anyopaque,
    capture_tool_fn: ?*const fn (*const anyopaque, *std.Io.Writer, *const ToolProjection) Error!void = null,
    contains_sensitive_fn: *const fn (*const anyopaque, []const u8) bool,
    write_json_fn: *const fn (*const anyopaque, *std.Io.Writer, []const u8) Error!void,
    write_json_output_fn: *const fn (
        *const anyopaque,
        *std.Io.Writer,
        []const u8,
        []const u64,
    ) Error!bool,
    write_json_parts_fn: *const fn (
        *const anyopaque,
        *std.Io.Writer,
        []const u8,
        []const u8,
    ) Error!bool,

    fn containsSensitive(self: TextProjection, value: []const u8) bool {
        return self.contains_sensitive_fn(self.context, value);
    }

    pub fn writeJson(
        self: TextProjection,
        writer: *std.Io.Writer,
        value: []const u8,
    ) Error!void {
        return self.write_json_fn(self.context, writer, value);
    }

    fn writeJsonParts(
        self: TextProjection,
        writer: *std.Io.Writer,
        first: []const u8,
        second: []const u8,
    ) Error!bool {
        return self.write_json_parts_fn(self.context, writer, first, second);
    }

    fn writeJsonOutput(
        self: TextProjection,
        writer: *std.Io.Writer,
        value: []const u8,
        commentary_ends: []const u64,
    ) Error!bool {
        return self.write_json_output_fn(
            self.context,
            writer,
            value,
            commentary_ends,
        );
    }
};

/// Callback-scoped reuse of the canonical Product Skill catalog projection.
pub const CatalogProjection = struct {
    context: *const anyopaque,
    write_fn: *const fn (
        *const anyopaque,
        *std.Io.Writer,
        product_skill.catalog.CatalogProjection,
    ) Error!void,

    fn write(
        self: CatalogProjection,
        writer: *std.Io.Writer,
        catalog: product_skill.catalog.CatalogProjection,
    ) Error!void {
        return self.write_fn(self.context, writer, catalog);
    }
};

/// Session observation stays in Workbench. This callback writes either the
/// currently observed request or `null`; it is never retained by Task View.
pub const PendingUiProjection = struct {
    context: *anyopaque,
    write_fn: *const fn (
        *anyopaque,
        *std.Io.Writer,
        *const task_state.Task,
        TextProjection,
    ) Error!void,

    fn write(
        self: PendingUiProjection,
        writer: *std.Io.Writer,
        task: *const task_state.Task,
        text: TextProjection,
    ) Error!void {
        return self.write_fn(self.context, writer, task, text);
    }
};

pub const ActionBlocker = enum {
    busy,
    closing,
    deleting,
    history_read_only,
    no_history,
    unavailable,
};

pub const Input = struct {
    now_ms: ?u64 = null,
    task: *const task_state.Task,
    recovery: task_recovery.Projection,
    model_selection_availability: ModelSelectionAvailability,
    available_approval_modes: []const task_state.ApprovalMode = &.{},
    shutting_down: bool,
    input_acceptance_reason: ?task_state.SendInputReason = null,
    model_input_blocker: ?task_state.SendInputReason = null,
    session_close_retry_available: bool = false,
    compact_blocker: ?ActionBlocker,
    text: TextProjection,
    catalog: CatalogProjection,
    pending_ui: PendingUiProjection,
    /// A consumer page is an explicit slice of this Task's stable Run order.
    /// The Task header and its authority are independent of loaded history.
    run_start: usize = 0,
    run_end: usize = std.math.maxInt(usize),
};

/// Navigation facts deliberately contain no Run text, Tool data, catalog,
/// pending input, or execution configuration. Inspecting terminal headers is
/// bounded by the Task's retained Run slots and never visits their payloads.
pub fn writeSummary(writer: *std.Io.Writer, task: *const task_state.Task, text: TextProjection, archive_blocker: ?ActionBlocker, delete_blocker: ?ActionBlocker) Error!void {
    writer.print("{{\"id\":\"{d}\",\"recentOrder\":\"{d}\",\"title\":", .{ task.durable.id, task.durable.recent_order }) catch return error.SnapshotTooLarge;
    try text.writeJson(writer, task.durable.title);
    try writeNavigationSignal(writer, task);
    try writeActionBlocker(writer, "archiveBlocker", archive_blocker);
    try writeActionBlocker(writer, "deleteBlocker", delete_blocker);
    writer.print(",\"workspaceId\":\"{d}\",\"archived\":{},\"lifecycle\":\"{s}\",\"deletionStatus\":\"{s}\",\"historyReadOnly\":{},\"permissionReviewState\":\"{s}\",\"currentRunPhase\":", .{
        task.durable.workspace_id, task.durable.archived, @tagName(task_policy.taskLifecycle(task)), @tagName(task.deletion), task.read_only_history != null, @tagName(task.permissionReviewPhase()),
    }) catch return error.SnapshotTooLarge;
    if (task_policy.currentRunProjection(task)) |current| {
        jsonValue(writer, @tagName(current.phase)) catch return error.SnapshotTooLarge;
    } else writer.writeAll("null") catch return error.SnapshotTooLarge;
    writer.writeAll(",\"activeOperation\":") catch return error.SnapshotTooLarge;
    switch (task.runtime.active_operation) {
        .none => writer.writeAll("null") catch return error.SnapshotTooLarge,
        .run => |id| writer.print("{{\"kind\":\"run\",\"id\":\"{d}\"}}", .{id}) catch return error.SnapshotTooLarge,
        .compact => |id| writer.print("{{\"kind\":\"compact\",\"id\":\"{d}\"}}", .{id}) catch return error.SnapshotTooLarge,
        .restore => |attempt| writer.print("{{\"kind\":\"restore\",\"id\":\"{d}\"}}", .{attempt.id}) catch return error.SnapshotTooLarge,
    }
    writer.writeAll(",\"activeCompactPhase\":") catch return error.SnapshotTooLarge;
    const active_compact = if (task.runtime.active_operation == .compact) task.runtime.active_operation.compact else null;
    var active_phase: ?task_state.CompactPhase = null;
    var last_phase: ?task_state.CompactPhase = null;
    for (task.durable.compacts) |entry| if (entry) |*compact| {
        last_phase = task_state.compactProjectionFacts(compact).phase;
        if (active_compact == compact.id) active_phase = last_phase;
    };
    if (active_phase) |phase| jsonValue(writer, @tagName(phase)) catch return error.SnapshotTooLarge else writer.writeAll("null") catch return error.SnapshotTooLarge;
    writer.writeAll(",\"lastCompactPhase\":") catch return error.SnapshotTooLarge;
    if (last_phase) |phase| jsonValue(writer, @tagName(phase)) catch return error.SnapshotTooLarge else writer.writeAll("null") catch return error.SnapshotTooLarge;
    writer.writeAll(",\"latestTerminal\":") catch return error.SnapshotTooLarge;
    const latest_terminal = if (task_policy.latestTerminalRun(task.durable.runs)) |run| task_state.productTerminalFacts(run) else null;
    if (latest_terminal) |terminal| {
        writer.print("{{\"outcome\":\"{s}\",\"cause\":", .{@tagName(terminal.outcome)}) catch return error.SnapshotTooLarge;
        if (terminal.cause) |cause| jsonValue(writer, @tagName(cause)) catch return error.SnapshotTooLarge else writer.writeAll("null") catch return error.SnapshotTooLarge;
        writer.writeByte('}') catch return error.SnapshotTooLarge;
    } else writer.writeAll("null") catch return error.SnapshotTooLarge;
    writer.writeAll(",\"unreadCompletionRunId\":") catch return error.SnapshotTooLarge;
    if (task_policy.unreadCompletionRunId(task)) |id| writer.print("\"{d}\"", .{id}) catch return error.SnapshotTooLarge else writer.writeAll("null") catch return error.SnapshotTooLarge;
    writer.writeByte('}') catch return error.SnapshotTooLarge;
}

fn writeActionBlocker(writer: *std.Io.Writer, comptime field: []const u8, blocker: ?ActionBlocker) Error!void {
    writer.writeAll(",\"" ++ field ++ "\":") catch return error.SnapshotTooLarge;
    if (blocker) |reason| {
        jsonValue(writer, @tagName(reason)) catch return error.SnapshotTooLarge;
    } else writer.writeAll("null") catch return error.SnapshotTooLarge;
}

fn writeNavigationSignal(writer: *std.Io.Writer, task: *const task_state.Task) Error!void {
    writer.writeAll(",\"signal\":") catch return error.SnapshotTooLarge;
    if (task_policy.navigationSignal(task)) |signal|
        jsonValue(writer, @tagName(signal)) catch return error.SnapshotTooLarge
    else
        writer.writeAll("null") catch return error.SnapshotTooLarge;
}

fn writeModelError(writer: *std.Io.Writer, text: TextProjection, observation: ?*const task_state.RunModelError) Error!void {
    const detail = observation orelse {
        writer.writeAll("null") catch return error.SnapshotTooLarge;
        return;
    };
    const value = detail.detail.view();
    var redacted = detail.host_redacted or text.containsSensitive(value.message);
    writer.print("{{\"agentRunId\":\"{d}\",\"category\":\"{s}\",\"message\":", .{ value.run_id, @tagName(value.category) }) catch return error.SnapshotTooLarge;
    try text.writeJson(writer, value.message);
    inline for (.{ .{ "code", "code" }, .{ "type", "type" }, .{ "request_id", "requestId" } }) |field| {
        writer.writeAll(",\"" ++ field[1] ++ "\":") catch return error.SnapshotTooLarge;
        if (@field(value, field[0])) |content| {
            redacted = redacted or text.containsSensitive(content);
            try text.writeJson(writer, content);
        } else writer.writeAll("null") catch return error.SnapshotTooLarge;
    }
    writer.writeAll(",\"httpStatus\":") catch return error.SnapshotTooLarge;
    if (value.http_status) |status| writer.print("{d}", .{status}) catch return error.SnapshotTooLarge else writer.writeAll("null") catch return error.SnapshotTooLarge;
    writer.print(",\"retry\":\"{s}\",\"retryAfterMs\":", .{@tagName(value.retry)}) catch return error.SnapshotTooLarge;
    if (value.retry_after_ms) |delay| writer.print("\"{d}\"", .{delay}) catch return error.SnapshotTooLarge else writer.writeAll("null") catch return error.SnapshotTooLarge;
    writer.print(",\"attempts\":\"{d}\",\"truncated\":{},\"hostRedacted\":{},\"hostTruncated\":{},\"source\":", .{ value.attempts, value.truncated, redacted, detail.host_truncated }) catch return error.SnapshotTooLarge;
    if (detail.source) |source| jsonValue(writer, @tagName(source)) catch return error.SnapshotTooLarge else writer.writeAll("null") catch return error.SnapshotTooLarge;
    writer.writeByte('}') catch return error.SnapshotTooLarge;
}

fn safeInputForPreparation(text: TextProjection, input: task_state.RunInputRecord) bool {
    return switch (input) {
        .text => |value| !value.redacted and !text.containsSensitive(value.value),
        .multimodal => |value| blk: {
            if (value.redacted) break :blk false;
            if (value.text) |content| {
                if (text.containsSensitive(content)) break :blk false;
            }
            for (value.attachments) |attachment| {
                if (attachment.redacted or text.containsSensitive(attachment.display_name)) break :blk false;
            }
            break :blk true;
        },
        .skill => |value| blk: {
            if (value.redacted or text.containsSensitive(value.skill_id) or
                text.containsSensitive(value.catalog_revision) or text.containsSensitive(value.invocation_name) or
                text.containsSensitive(value.display_name)) break :blk false;
            for (value.argument_values) |argument| {
                if (text.containsSensitive(argument)) break :blk false;
            }
            break :blk true;
        },
    };
}

fn writeTerminal(writer: *std.Io.Writer, text: TextProjection, run: *const task_state.RunRecord, terminal: task_state.ProductTerminalFacts) Error!void {
    writer.print("{{\"outcome\":\"{s}\",\"cause\":", .{@tagName(terminal.outcome)}) catch return error.SnapshotTooLarge;
    if (terminal.cause) |cause| jsonValue(writer, @tagName(cause)) catch return error.SnapshotTooLarge else writer.writeAll("null") catch return error.SnapshotTooLarge;
    writer.print(",\"diagnosticDisposition\":\"{s}\",\"modelError\":", .{@tagName(terminal.diagnostic_disposition)}) catch return error.SnapshotTooLarge;
    const detail = task_state.terminalPayload(run).?.model_error;
    try writeModelError(writer, text, detail);
    const feedback = task_policy.runFeedback(terminal.outcome, terminal.cause, detail);
    writer.print(",\"recordingIncomplete\":{},\"feedback\":{{\"guidance\":\"{s}\",\"reason\":", .{
        run.event_projection_failure != null, @tagName(feedback.guidance),
    }) catch return error.SnapshotTooLarge;
    if (feedback.reason) |reason| jsonValue(writer, @tagName(reason)) catch return error.SnapshotTooLarge else writer.writeAll("null") catch return error.SnapshotTooLarge;
    writer.print(",\"offerInputPreparation\":{}}}}}", .{
        feedback.offer_input_preparation and safeInputForPreparation(text, run.input),
    }) catch return error.SnapshotTooLarge;
}

pub fn writeRunManifest(writer: *std.Io.Writer, text: TextProjection, task: *const task_state.Task) Error!void {
    writer.writeByte('[') catch return error.SnapshotTooLarge;
    var count: usize = 0;
    for (task.durable.runs) |*entry| {
        const run = &(entry.* orelse continue);
        if (count != 0) writer.writeByte(',') catch return error.SnapshotTooLarge;
        count += 1;
        const facts = task_state.runProjectionFacts(run);
        if (run.projection_content_version == 0) return error.SnapshotTooLarge;
        writer.print("{{\"id\":\"{d}\",\"contentVersion\":\"{d}\",\"phase\":\"{s}\",\"permissionProfile\":\"{s}\",\"permissionInteraction\":\"{s}\",\"terminal\":", .{ run.id, run.projection_content_version, @tagName(facts.phase), @tagName(run.permission_profile), @tagName(run.permission_interaction) }) catch return error.SnapshotTooLarge;
        if (facts.terminal) |terminal| {
            try writeTerminal(writer, text, run, terminal);
        } else writer.writeAll("null") catch return error.SnapshotTooLarge;
        writer.writeByte('}') catch return error.SnapshotTooLarge;
    }
    writer.writeByte(']') catch return error.SnapshotTooLarge;
}

pub fn writeProjection(writer: *std.Io.Writer, input: Input) Error!void {
    const task = input.task;
    const approval_mode = task_state.ApprovalMode.fromFacts(task.durable.permission_profile, task.durable.permission_review_delegated);
    const review_phase = task.permissionReviewPhase();
    const current_run_projection = task_policy.currentRunProjection(task);
    const current_run_phase = if (current_run_projection) |projection|
        projection.phase
    else
        null;
    writer.print("{{\"id\":\"{d}\",\"recentOrder\":\"{d}\",\"title\":", .{
        task.durable.id,
        task.durable.recent_order,
    }) catch return error.SnapshotTooLarge;
    try input.text.writeJson(writer, task.durable.title);
    try writeNavigationSignal(writer, task);
    try writeActionBlocker(writer, "compactBlocker", input.compact_blocker);
    writer.print(",\"approvalRevision\":\"{d}\",\"availableApprovalModes\":[", .{task.durable.approval_revision}) catch return error.SnapshotTooLarge;
    for (input.available_approval_modes, 0..) |mode, index| {
        if (index != 0) writer.writeByte(',') catch return error.SnapshotTooLarge;
        jsonValue(writer, @tagName(mode)) catch return error.SnapshotTooLarge;
    }
    writer.writeAll("],\"approvalChange\":") catch return error.SnapshotTooLarge;
    if (task.approval_change) |change| {
        const phase: []const u8 = switch (change.phase) {
            .recovering => "recovering",
            .outcome_unknown => "outcome_unknown",
            else => "pending",
        };
        writer.print("{{\"revision\":\"{d}\",\"targetMode\":\"{s}\",\"state\":\"{s}\"}}", .{ change.revision, @tagName(change.target), phase }) catch return error.SnapshotTooLarge;
    } else writer.writeAll("null") catch return error.SnapshotTooLarge;
    writer.writeAll(",\"approvalResult\":") catch return error.SnapshotTooLarge;
    if (task.approval_result) |result| {
        const wire = view_contract.ApprovalResult{
            .revision = .{ .value = result.revision },
            .outcome = result.outcome,
            .reason = result.reason,
        };
        std.json.Stringify.value(wire, .{}, writer) catch return error.SnapshotTooLarge;
    } else writer.writeAll("null") catch return error.SnapshotTooLarge;
    writer.writeAll(",\"inputReady\":") catch return error.SnapshotTooLarge;
    writer.writeAll(if (inputReady(task)) "true" else "false") catch return error.SnapshotTooLarge;
    writer.writeAll(",\"inputAcceptance\":{\"available\":") catch return error.SnapshotTooLarge;
    writer.writeAll(if (input.input_acceptance_reason == null) "true" else "false") catch return error.SnapshotTooLarge;
    writer.writeAll(",\"reason\":") catch return error.SnapshotTooLarge;
    if (input.input_acceptance_reason) |reason| jsonValue(writer, @tagName(reason)) catch return error.SnapshotTooLarge else writer.writeAll("null") catch return error.SnapshotTooLarge;
    writer.writeByte('}') catch return error.SnapshotTooLarge;
    if (input.model_input_blocker) |reason| {
        writer.writeAll(",\"modelInputBlocker\":") catch return error.SnapshotTooLarge;
        jsonValue(writer, @tagName(reason)) catch return error.SnapshotTooLarge;
    }
    if (input.session_close_retry_available)
        writer.writeAll(",\"sessionCloseRetryAvailable\":true") catch return error.SnapshotTooLarge;
    writer.writeAll(",\"inputSubmissions\":[") catch return error.SnapshotTooLarge;
    var first_submission = true;
    for (task.input_submissions.items) |record| {
        if (task_state.submissionHasExecution(task, record.submission.operationId())) continue;
        if (!first_submission) writer.writeByte(',') catch return error.SnapshotTooLarge;
        first_submission = false;
        writer.writeAll("{\"submission\":") catch return error.SnapshotTooLarge;
        try writeSubmission(writer, input.text, record.submission);
        writer.writeAll(",\"input\":") catch return error.SnapshotTooLarge;
        try writeInput(writer, input.text, record.input, null);
        writer.print(",\"state\":\"{s}\",\"reason\":", .{@tagName(record.state)}) catch return error.SnapshotTooLarge;
        if (record.reason) |reason| jsonValue(writer, @tagName(reason)) catch return error.SnapshotTooLarge else writer.writeAll("null") catch return error.SnapshotTooLarge;
        if (record.retry_payload != null and !task.durable.archived and task.read_only_history == null and task.deletion == .idle and !input.shutting_down)
            writer.writeAll(",\"retryAvailable\":true") catch return error.SnapshotTooLarge;
        if (record.blocking_task_id) |id| {
            std.debug.assert(record.state == .failed and record.reason == .session_close_failed and id != 0);
            writer.print(",\"blockingTaskId\":\"{d}\"", .{id}) catch return error.SnapshotTooLarge;
        }
        writer.writeByte('}') catch return error.SnapshotTooLarge;
    }
    writer.writeByte(']') catch return error.SnapshotTooLarge;
    writer.print(",\"workspaceId\":\"{d}\",\"permissionProfile\":\"{s}\",\"approvalMode\":\"{s}\",\"permissionReviewState\":\"{s}\",\"binding\":{{\"epoch\":\"{d}\",\"availability\":\"{s}\",\"protocol\":\"{s}\",\"model\":", .{
        task.durable.workspace_id,
        @tagName(task.durable.permission_profile),
        @tagName(approval_mode),
        @tagName(review_phase),
        task.durable.binding_epoch,
        if (task.runtime.executionConst() == null) "unavailable" else "available",
        @tagName(task.durable.execution_protocol),
    }) catch return error.SnapshotTooLarge;
    try input.text.writeJson(writer, task.durable.execution_model);
    writer.print(",\"executionGeneration\":\"{d}\",\"unavailableReason\":", .{task.durable.execution_generation}) catch
        return error.SnapshotTooLarge;
    if (task.runtime.executionConst() == null)
        writer.writeAll("\"runtime_detached\"") catch return error.SnapshotTooLarge
    else
        writer.writeAll("null") catch return error.SnapshotTooLarge;
    writer.writeByte('}') catch return error.SnapshotTooLarge;
    writer.writeAll(",\"permissionReviewExplanation\":") catch return error.SnapshotTooLarge;
    if (review_phase == .needs_user) {
        const review = &task.runtime.permission_review;
        writer.print("{{\"cause\":\"{s}\",\"reason\":", .{@tagName(review.cause)}) catch return error.SnapshotTooLarge;
        if (review.reason_len > 0) try input.text.writeJson(writer, review.reason[0..review.reason_len]) else writer.writeAll("null") catch return error.SnapshotTooLarge;
        writer.writeByte('}') catch return error.SnapshotTooLarge;
    } else writer.writeAll("null") catch return error.SnapshotTooLarge;
    writer.writeAll(",\"modelIntent\":") catch return error.SnapshotTooLarge;
    if (task.durable.model_intent) |intent| {
        writer.writeAll("{\"modelRef\":{\"sourceId\":") catch return error.SnapshotTooLarge;
        try input.text.writeJson(writer, intent.source_id);
        writer.writeAll(",\"modelId\":") catch return error.SnapshotTooLarge;
        try input.text.writeJson(writer, intent.model_id);
        writer.print("}},\"selectionRevision\":\"{d}\",\"state\":\"{s}\"}}", .{ intent.revision, if (task.model_intent_prepared) "outcome_unknown" else "committed" }) catch return error.SnapshotTooLarge;
    } else writer.writeAll("null") catch return error.SnapshotTooLarge;
    writer.print(",\"modelSelectionAvailability\":\"{s}\"", .{
        @tagName(input.model_selection_availability),
    }) catch return error.SnapshotTooLarge;
    writer.writeAll(",\"mcpAuthority\":") catch return error.SnapshotTooLarge;
    switch (task.runtime.mcp_authority_at_creation) {
        .ready_with_selection => writer.writeAll(
            "{\"kind\":\"ready\",\"selection\":\"selected\"}",
        ) catch return error.SnapshotTooLarge,
        .ready_without_selection => writer.writeAll(
            "{\"kind\":\"ready\",\"selection\":\"none\"}",
        ) catch return error.SnapshotTooLarge,
        .unavailable => writer.writeAll(
            "{\"kind\":\"unavailable\",\"selection\":null}",
        ) catch return error.SnapshotTooLarge,
    }
    writer.writeAll(",\"skillCatalog\":") catch return error.SnapshotTooLarge;
    try input.catalog.write(writer, catalogProjection(task));
    writer.print(",\"lifecycle\":\"{s}\",\"deletionStatus\":\"{s}\",\"continuationAvailable\":{},\"continuationUnavailableReason\":", .{
        @tagName(task_policy.taskLifecycle(task)),
        @tagName(task.deletion),
        !input.shutting_down and task_policy.taskLifecycle(task) == .open and
            task_policy.continuationAvailable(input.recovery.continuation),
    }) catch return error.SnapshotTooLarge;
    switch (input.recovery.continuation) {
        .available => writer.writeAll("null") catch return error.SnapshotTooLarge,
        .unavailable => |reason| jsonValue(writer, @tagName(reason)) catch
            return error.SnapshotTooLarge,
    }
    writer.print(",\"continuationRecoveryAvailable\":{},\"archived\":{}", .{
        input.recovery.recovery_available,
        task.durable.archived,
    }) catch return error.SnapshotTooLarge;
    writer.writeAll(",\"unreadCompletionRunId\":") catch return error.SnapshotTooLarge;
    if (task_policy.unreadCompletionRunId(task)) |run_id|
        writer.print("\"{d}\"", .{run_id}) catch return error.SnapshotTooLarge
    else
        writer.writeAll("null") catch return error.SnapshotTooLarge;
    writer.writeAll(",\"restorePermission\":") catch return error.SnapshotTooLarge;
    if (task.runtime.last_restore_permission) |summary| {
        writer.print("{{\"restoredRules\":\"{d}\",\"invalidatedRules\":\"{d}\"}}", .{
            summary.restored_rules,
            summary.invalidated_rules,
        }) catch return error.SnapshotTooLarge;
    } else writer.writeAll("null") catch return error.SnapshotTooLarge;
    writer.writeAll(",\"activeOperation\":") catch return error.SnapshotTooLarge;
    switch (task.runtime.active_operation) {
        .none => writer.writeAll("null") catch return error.SnapshotTooLarge,
        .run => |id| writer.print("{{\"kind\":\"run\",\"id\":\"{d}\"}}", .{id}) catch
            return error.SnapshotTooLarge,
        .compact => |id| writer.print("{{\"kind\":\"compact\",\"id\":\"{d}\"}}", .{id}) catch
            return error.SnapshotTooLarge,
        .restore => |attempt| writer.print(
            "{{\"kind\":\"restore\",\"id\":\"{d}\"}}",
            .{attempt.id},
        ) catch return error.SnapshotTooLarge,
    }
    writer.print(",\"currentRunId\":\"{d}\",\"currentRunPhase\":", .{
        if (current_run_phase == null) 0 else task.runtime.active_run_id,
    }) catch return error.SnapshotTooLarge;
    if (current_run_phase) |phase|
        jsonValue(writer, @tagName(phase)) catch return error.SnapshotTooLarge
    else
        writer.writeAll("null") catch return error.SnapshotTooLarge;
    writer.writeAll(",\"context\":") catch return error.SnapshotTooLarge;
    try writeConversationContext(writer, task.conversation_observation);
    writer.writeAll(",\"runs\":[") catch return error.SnapshotTooLarge;
    var run_count: usize = 0;
    for (task.durable.runs, 0..) |*entry, run_index| {
        if (run_index < input.run_start or run_index >= input.run_end) continue;
        const run = &(entry.* orelse continue);
        if (run_count != 0) writer.writeByte(',') catch return error.SnapshotTooLarge;
        run_count += 1;
        const projection = if (current_run_projection) |current|
            if (run.id == task.runtime.active_run_id)
                current
            else
                task_state.runProjectionFacts(run)
        else
            task_state.runProjectionFacts(run);
        try writeRun(writer, input.text, run, projection, input.now_ms);
    }
    writer.writeAll("],\"compacts\":[") catch return error.SnapshotTooLarge;
    var compact_count: usize = 0;
    for (task.durable.compacts) |*entry| {
        const compact = &(entry.* orelse continue);
        if (compact_count != 0) writer.writeByte(',') catch
            return error.SnapshotTooLarge;
        compact_count += 1;
        try writeCompact(writer, compact);
    }
    writer.writeAll("],\"pendingUi\":") catch return error.SnapshotTooLarge;
    if (current_run_phase == .waiting_ui)
        try input.pending_ui.write(writer, task, input.text)
    else
        writer.writeAll("null") catch return error.SnapshotTooLarge;
    writer.writeAll(",\"uiHistory\":[") catch return error.SnapshotTooLarge;
    try writeUiHistory(writer, input.text, task);
    writer.writeAll("]}") catch return error.SnapshotTooLarge;
}

fn writeFileChanges(
    writer: *std.Io.Writer,
    text: TextProjection,
    run: *const task_state.RunRecord,
) Error!void {
    const observation = run.file_change_observation orelse {
        writer.writeAll("null") catch return error.SnapshotTooLarge;
        return;
    };
    writer.print("{{\"observation\":\"{s}\",\"changes\":[", .{@tagName(observation)}) catch
        return error.SnapshotTooLarge;
    var count: usize = 0;
    for (run.file_changes) |*entry| {
        const change = &(entry.* orelse continue);
        if (count != 0) writer.writeByte(',') catch return error.SnapshotTooLarge;
        count += 1;
        writer.writeAll("{\"id\":") catch return error.SnapshotTooLarge;
        try text.writeJson(writer, change.id);
        writer.print(",\"order\":\"{d}\",\"kind\":\"{s}\",\"status\":\"{s}\",\"displayPath\":", .{
            change.order,
            @tagName(change.kind),
            @tagName(change.status),
        }) catch return error.SnapshotTooLarge;
        try text.writeJson(writer, change.display_path);
        writer.writeAll(",\"fromDisplayPath\":") catch return error.SnapshotTooLarge;
        if (change.from_display_path) |path|
            try text.writeJson(writer, path)
        else
            writer.writeAll("null") catch return error.SnapshotTooLarge;
        writer.print(",\"beforeBytes\":\"{d}\",\"afterBytes\":\"{d}\",\"diffAvailable\":{},\"diffComplete\":{},\"redacted\":{}}}", .{
            change.before_bytes,
            change.after_bytes,
            change.artifact != null,
            change.diff_complete,
            change.redacted,
        }) catch return error.SnapshotTooLarge;
    }
    writer.writeAll("]}") catch return error.SnapshotTooLarge;
}

pub fn writePendingUi(
    writer: *std.Io.Writer,
    text: TextProjection,
    request_id: u64,
    run_id: u64,
    order: u64,
    permission: agent.PermissionRequest,
) Error!void {
    const candidate_target = if (permission.candidate) |candidate| candidate.target else null;
    const target_sensitive = if (candidate_target) |target| text.containsSensitive(target) else false;
    const visible_candidate = if (target_sensitive) null else permission.candidate;
    var presentation_scratch: [max_permission_presentation_input_bytes]u8 = undefined;
    var presentation_allocator = JsonScratch.init(&presentation_scratch);
    defer presentation_allocator.clear();
    const parsed_presentation = permissionPresentation(permission, presentation_allocator.allocator());
    const presentation_redacted = if (parsed_presentation) |value|
        text.containsSensitive(value.target) or (if (value.description) |description| text.containsSensitive(description) else false)
    else
        false;
    const presentation = if (parsed_presentation) |value|
        if (permissionPresentationFits(value)) parsed_presentation else null
    else
        null;
    writer.print("{{\"requestId\":\"{d}\",\"runId\":\"{d}\",\"order\":\"{d}\",\"redacted\":{},", .{
        request_id,
        run_id,
        order,
        text.containsSensitive(permission.tool.name) or
            text.containsSensitive(permission.arguments_json) or target_sensitive or presentation_redacted,
    }) catch return error.SnapshotTooLarge;
    writer.print("\"kind\":\"permission\",\"toolNamespace\":\"{s}\",\"tool\":", .{
        @tagName(permission.tool.namespace),
    }) catch
        return error.SnapshotTooLarge;
    try text.writeJson(writer, permission.tool.name);
    writer.writeAll(",\"toolBinding\":") catch return error.SnapshotTooLarge;
    try text.writeJson(writer, permission.tool.binding);
    writer.writeAll(",\"args\":") catch return error.SnapshotTooLarge;
    try text.writeJson(writer, if (presentation_redacted) "***" else permission.arguments_json);
    writer.writeAll(",\"presentation\":") catch return error.SnapshotTooLarge;
    try writePermissionPresentation(writer, text, presentation);
    writer.writeAll(",\"availableChoices\":[") catch return error.SnapshotTooLarge;
    var wrote_choice = false;
    for (permission.responses) |choice| {
        if (choice == .allow_session or choice == .deny_session) {
            if (visible_candidate == null) continue;
        }
        if (wrote_choice) writer.writeByte(',') catch return error.SnapshotTooLarge;
        jsonValue(writer, @tagName(choice)) catch return error.SnapshotTooLarge;
        wrote_choice = true;
    }
    writer.print("],\"policyGeneration\":\"{d}\",\"canonicalArgumentsDigest\":", .{
        permission.policy_generation,
    }) catch return error.SnapshotTooLarge;
    try text.writeJson(writer, permission.canonical_arguments_digest);
    writer.writeAll(",\"candidate\":") catch return error.SnapshotTooLarge;
    if (visible_candidate) |candidate| {
        writer.writeAll("{\"ruleId\":") catch return error.SnapshotTooLarge;
        try text.writeJson(writer, candidate.rule_id);
        writer.print(",\"scope\":\"{s}\"", .{@tagName(candidate.scope)}) catch
            return error.SnapshotTooLarge;
        if (candidate.target) |target| {
            writer.writeAll(",\"target\":") catch return error.SnapshotTooLarge;
            try text.writeJson(writer, target);
        }
        writer.writeByte('}') catch return error.SnapshotTooLarge;
    } else writer.writeAll("null") catch return error.SnapshotTooLarge;
    writer.writeByte('}') catch return error.SnapshotTooLarge;
}

pub fn writeInput(writer: *std.Io.Writer, text_projection: TextProjection, input: task_state.RunInputRecord, selection_revision: ?u64) Error!void {
    switch (input) {
        .text => |text| {
            writer.writeAll("{\"kind\":\"text\",\"text\":") catch
                return error.SnapshotTooLarge;
            try text_projection.writeJson(writer, text.value);
            writer.print(",\"redacted\":{}}}", .{text.redacted}) catch
                return error.SnapshotTooLarge;
        },
        .multimodal => |multimodal| {
            writer.writeAll("{\"kind\":\"multimodal\",\"text\":") catch
                return error.SnapshotTooLarge;
            if (multimodal.text) |text|
                try text_projection.writeJson(writer, text)
            else
                writer.writeAll("null") catch return error.SnapshotTooLarge;
            writer.writeAll(",\"attachments\":[") catch return error.SnapshotTooLarge;
            for (multimodal.attachments, 0..) |item, index| {
                if (index != 0) writer.writeByte(',') catch return error.SnapshotTooLarge;
                writer.print("{{\"kind\":\"{s}\"", .{@tagName(item.kind)}) catch
                    return error.SnapshotTooLarge;
                if (item.format) |format| writer.print(",\"format\":\"{s}\"", .{@tagName(format)}) catch
                    return error.SnapshotTooLarge;
                writer.writeAll(",\"displayName\":") catch return error.SnapshotTooLarge;
                try text_projection.writeJson(writer, item.display_name);
                writer.print(",\"sizeBytes\":\"{d}\",\"redacted\":{}}}", .{
                    item.size_bytes,
                    item.redacted,
                }) catch return error.SnapshotTooLarge;
            }
            writer.print("],\"redacted\":{}}}", .{multimodal.redacted}) catch
                return error.SnapshotTooLarge;
        },
        .skill => |skill| {
            writer.writeAll("{\"kind\":\"skill\",\"skillId\":") catch
                return error.SnapshotTooLarge;
            try text_projection.writeJson(writer, skill.skill_id);
            writer.writeAll(",\"catalogRevision\":") catch
                return error.SnapshotTooLarge;
            try text_projection.writeJson(writer, skill.catalog_revision);
            if (selection_revision) |revision| writer.print(",\"selectionRevision\":\"{d}\"", .{revision}) catch return error.SnapshotTooLarge;
            writer.writeAll(",\"invocationName\":") catch
                return error.SnapshotTooLarge;
            try text_projection.writeJson(writer, skill.invocation_name);
            writer.writeAll(",\"displayName\":") catch
                return error.SnapshotTooLarge;
            try text_projection.writeJson(writer, skill.display_name);
            writer.writeAll(",\"argumentValues\":[") catch
                return error.SnapshotTooLarge;
            for (skill.argument_values, 0..) |value, index| {
                if (index != 0) writer.writeByte(',') catch
                    return error.SnapshotTooLarge;
                try text_projection.writeJson(writer, value);
            }
            writer.print("],\"redacted\":{}}}", .{skill.redacted}) catch
                return error.SnapshotTooLarge;
        },
    }
}

fn inputReady(task: *const task_state.Task) bool {
    const id = switch (task.runtime.active_operation) {
        .run => |id| id,
        else => return false,
    };
    const run = task_state.findRun(task.durable.runs, id) orelse return false;
    if (run.input == .skill or task_state.terminalPayload(run) != null or
        task.runtime.cancel_requested or task.approval_change != null or
        run.pending_termination.load(.acquire) != .none or
        run.agent_handoff.load(.acquire) != .running) return false;
    var lease = run.execution.?.run_control.tryAcquireLease() orelse return false;
    defer lease.deinit();
    return lease.inputObservation().ready;
}

fn writeInputId(writer: *std.Io.Writer, id: ?u64) Error!void {
    if (id) |value| writer.print("\"{d}\"", .{value}) catch return error.SnapshotTooLarge else writer.writeAll("null") catch return error.SnapshotTooLarge;
}

fn writeSubmission(writer: *std.Io.Writer, text: TextProjection, submission: ?task_state.Submission) Error!void {
    const record = submission orelse {
        writer.writeAll("null") catch return error.SnapshotTooLarge;
        return;
    };
    writer.writeAll("{\"operationId\":") catch return error.SnapshotTooLarge;
    try text.writeJson(writer, record.operationId());
    writer.writeAll(",\"receivedAtUnixMs\":") catch return error.SnapshotTooLarge;
    try writeInputId(writer, record.received_at_unix_ms);
    writer.writeAll(",\"anchorRunId\":") catch return error.SnapshotTooLarge;
    try writeInputId(writer, record.anchor_run_id);
    writer.print(",\"afterOutputCount\":{d},\"presentationOrder\":", .{record.after_output_count}) catch return error.SnapshotTooLarge;
    try writeInputId(writer, record.presentation_order);
    writer.writeByte('}') catch return error.SnapshotTooLarge;
}

pub fn writeSendInputResult(writer: *std.Io.Writer, text: TextProjection, result: task_state.SendInputResult) Error!void {
    writer.print("{{\"taskId\":\"{d}\",\"operationId\":", .{result.task_id}) catch return error.SnapshotTooLarge;
    try text.writeJson(writer, result.operationId());
    writer.print(",\"outcome\":\"{s}\",\"runId\":", .{@tagName(result.outcome)}) catch return error.SnapshotTooLarge;
    try writeInputId(writer, result.run_id);
    writer.writeAll(",\"inputId\":") catch return error.SnapshotTooLarge;
    try writeInputId(writer, result.input_id);
    writer.writeAll(",\"sequence\":") catch return error.SnapshotTooLarge;
    if (result.sequence) |sequence| writer.print("{d}", .{sequence}) catch return error.SnapshotTooLarge else writer.writeAll("null") catch return error.SnapshotTooLarge;
    writer.writeAll(",\"reason\":") catch return error.SnapshotTooLarge;
    if (result.reason) |reason| jsonValue(writer, @tagName(reason)) catch return error.SnapshotTooLarge else writer.writeAll("null") catch return error.SnapshotTooLarge;
    writer.writeByte('}') catch return error.SnapshotTooLarge;
}

pub fn writeInputAcceptance(writer: *std.Io.Writer, text: TextProjection, result: task_state.InputAcceptance) Error!void {
    writer.print("{{\"taskId\":\"{d}\",\"operationId\":", .{result.task_id}) catch return error.SnapshotTooLarge;
    try text.writeJson(writer, result.operationId());
    writer.print(",\"outcome\":\"{s}\",\"reason\":", .{@tagName(result.outcome)}) catch return error.SnapshotTooLarge;
    if (result.reason) |reason| jsonValue(writer, @tagName(reason)) catch return error.SnapshotTooLarge else writer.writeAll("null") catch return error.SnapshotTooLarge;
    writer.writeByte('}') catch return error.SnapshotTooLarge;
}

pub fn writeRun(
    writer: *std.Io.Writer,
    text_projection: TextProjection,
    run: *const task_state.RunRecord,
    projection: task_state.RunProjectionFacts,
    now_ms: ?u64,
) Error!void {
    const terminal = projection.terminal;
    writer.print("{{\"id\":\"{d}\",\"conversationCoverage\":\"{s}\",\"phase\":\"{s}\",\"permissionProfile\":\"{s}\",\"permissionInteraction\":\"{s}\",\"execution\":{{\"generation\":\"{d}\",\"protocol\":\"{s}\",\"model\":", .{
        run.id,
        if (run.coverage == .excluded) "excluded" else "included",
        @tagName(projection.phase),
        @tagName(run.permission_profile),
        @tagName(run.permission_interaction),
        run.execution_generation,
        @tagName(run.execution_protocol),
    }) catch return error.SnapshotTooLarge;
    try text_projection.writeJson(writer, run.execution_model);
    writer.writeAll("},\"elapsedMs\":") catch return error.SnapshotTooLarge;
    if (task_state.runElapsedMs(run, now_ms)) |elapsed|
        writer.print("\"{d}\"", .{elapsed}) catch return error.SnapshotTooLarge
    else
        writer.writeAll("null") catch return error.SnapshotTooLarge;
    writer.writeAll(",\"submittedAtUnixMs\":") catch return error.SnapshotTooLarge;
    if (run.submitted_at_unix_ms) |submitted_at|
        writer.print("\"{d}\"", .{submitted_at}) catch return error.SnapshotTooLarge
    else
        writer.writeAll("null") catch return error.SnapshotTooLarge;
    writer.writeAll(",\"finishedAtUnixMs\":") catch return error.SnapshotTooLarge;
    if (terminal != null and run.finished_at_unix_ms != null)
        writer.print("\"{d}\"", .{run.finished_at_unix_ms.?}) catch return error.SnapshotTooLarge
    else
        writer.writeAll("null") catch return error.SnapshotTooLarge;
    writer.writeAll(",\"input\":") catch return error.SnapshotTooLarge;
    try writeInput(writer, text_projection, run.input, null);
    writer.writeAll(",\"submission\":") catch return error.SnapshotTooLarge;
    try writeSubmission(writer, text_projection, run.submission);
    writer.writeAll(",\"additionalInputs\":[") catch return error.SnapshotTooLarge;
    var first_input = true;
    for (run.additional_inputs) |entry| if (entry) |record| {
        if (!first_input) writer.writeByte(',') catch return error.SnapshotTooLarge;
        first_input = false;
        writer.print("{{\"id\":\"{d}\",\"operationId\":", .{record.id}) catch return error.SnapshotTooLarge;
        try text_projection.writeJson(writer, record.operationId());
        writer.writeAll(",\"text\":") catch return error.SnapshotTooLarge;
        try text_projection.writeJson(writer, record.text);
        const continuing = run.input_continuation_pending and record.state == .unadopted and record.raw_text != null;
        writer.print(",\"redacted\":{},\"afterOutputCount\":{d},\"state\":\"{s}\",\"sequence\":", .{ record.redacted, record.after_output_count, if (continuing) "continuing" else @tagName(record.state) }) catch return error.SnapshotTooLarge;
        if (record.sequence) |sequence| writer.print("{d}", .{sequence}) catch return error.SnapshotTooLarge else writer.writeAll("null") catch return error.SnapshotTooLarge;
        writer.writeAll(",\"adoptedTurn\":") catch return error.SnapshotTooLarge;
        if (record.adopted_turn) |turn| writer.print("{d}", .{turn}) catch return error.SnapshotTooLarge else writer.writeAll("null") catch return error.SnapshotTooLarge;
        writer.writeAll(",\"order\":") catch return error.SnapshotTooLarge;
        try writeInputId(writer, record.order);
        writer.writeAll(",\"transferredToRunId\":") catch return error.SnapshotTooLarge;
        try writeInputId(writer, record.transferred_to_run_id);
        writer.writeAll(",\"continuationReason\":") catch return error.SnapshotTooLarge;
        const continuation_reason = record.continuation_cancel_reason orelse run.input_continuation_failure;
        if (record.state == .unadopted and continuation_reason != null)
            jsonValue(writer, @tagName(continuation_reason.?)) catch return error.SnapshotTooLarge
        else
            writer.writeAll("null") catch return error.SnapshotTooLarge;
        writer.writeAll(",\"submission\":") catch return error.SnapshotTooLarge;
        try writeSubmission(writer, text_projection, record.submission);
        writer.writeByte('}') catch return error.SnapshotTooLarge;
    };
    writer.writeByte(']') catch return error.SnapshotTooLarge;
    try writeRunOutput(writer, text_projection, run);
    writer.writeAll(",\"activity\":") catch return error.SnapshotTooLarge;
    try writeRunActivity(writer, projection.activity);
    writer.writeAll(",\"terminal\":") catch return error.SnapshotTooLarge;
    if (terminal) |value| {
        try writeTerminal(writer, text_projection, run, value);
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
        if (text_projection.capture_tool_fn) |capture| {
            try capture(text_projection.context, writer, tool);
        } else try writeToolProjection(writer, text_projection, tool);
    }
    writer.writeAll("],\"fileChanges\":") catch return error.SnapshotTooLarge;
    try writeFileChanges(writer, text_projection, run);
    writer.writeAll(",\"outputs\":[") catch return error.SnapshotTooLarge;
    var first_output = true;
    for (run.outputs) |entry| if (entry) |output| {
        if (!first_output) writer.writeByte(',') catch return error.SnapshotTooLarge;
        first_output = false;
        const hidden = output.redacted or text_projection.containsSensitive(output.locator);
        writer.print("{{\"id\":\"{s}\",\"displayPath\":", .{std.fmt.bytesToHex(output.id, .lower)}) catch return error.SnapshotTooLarge;
        try text_projection.writeJson(writer, if (hidden) "" else output.locator);
        writer.print(",\"sizeBytes\":\"{d}\",\"redacted\":{}}}", .{ output.size_bytes, hidden }) catch return error.SnapshotTooLarge;
    };
    writer.writeByte(']') catch return error.SnapshotTooLarge;
    writer.writeByte('}') catch return error.SnapshotTooLarge;
}

/// Callback-scoped immutable Tool facts; no Session or execution capability.
pub const ToolProjection = task_state.ToolView;

pub const ToolStage = enum { identity, bash_input, bash_result, presentation_input, presentation_result, error_detail, details, done };
pub const ToolWritingState = struct { stage: ToolStage = .identity, redacted: bool = false, presentation_open: bool = false };

pub fn writeToolProjection(writer: *std.Io.Writer, text_projection: TextProjection, tool: *const ToolProjection) Error!void {
    var state: ToolWritingState = .{};
    while (state.stage != .done) try writeToolStage(writer, text_projection, tool, &state);
}

fn writeToolStage(writer: *std.Io.Writer, text_projection: TextProjection, tool: *const ToolProjection, state: *ToolWritingState) Error!void {
    switch (state.stage) {
        .identity => {
            writer.writeAll("{\"id\":") catch return error.SnapshotTooLarge;
            try text_projection.writeJson(writer, tool.id);
            writer.print(",\"order\":\"{d}\"", .{tool.order}) catch
                return error.SnapshotTooLarge;
            writer.writeAll(",\"name\":") catch return error.SnapshotTooLarge;
            try text_projection.writeJson(writer, tool.name);
        },
        .bash_input => state.redacted = (try writeBashInput(writer, text_projection, tool)) or state.redacted,
        .bash_result => state.redacted = (try writeBashResult(writer, text_projection, tool)) or state.redacted,
        .presentation_input => state.redacted = (try writeToolPresentation(writer, text_projection, tool, &state.presentation_open)) or state.redacted,
        .presentation_result => if (state.presentation_open) {
            state.redacted = (try writeToolPresentationResult(writer, text_projection, tool)) or state.redacted;
        },
        .error_detail => state.redacted = (try writeToolErrorDetail(writer, text_projection, tool)) or state.redacted,
        .details => {
            writer.writeAll(",\"input\":") catch return error.SnapshotTooLarge;
            // Decoding can reveal a credential hidden behind JSON escapes. Do not
            // expose its reconstructible raw representation in secondary details.
            try text_projection.writeJson(writer, if (state.redacted) "***" else tool.input);
            writer.writeAll(",\"progress\":") catch return error.SnapshotTooLarge;
            try text_projection.writeJson(writer, tool.progress);
            writer.writeAll(",\"content\":") catch return error.SnapshotTooLarge;
            try text_projection.writeJson(writer, if (state.redacted) "***" else tool.content);
            writer.print(",\"state\":\"{s}\",\"isError\":{},\"elapsedMs\":\"{d}\",\"inputTruncated\":{},\"progressTruncated\":{},\"contentTruncated\":{},\"redacted\":{},\"fileRefs\":[", .{
                @tagName(tool.state),
                tool.is_error,
                tool.elapsed_ms,
                tool.input_truncated,
                tool.progress_truncated,
                tool.content_truncated,
                tool.redacted or state.redacted,
            }) catch return error.SnapshotTooLarge;
            var file_ref_count: usize = 0;
            if (tool.file_refs) |refs| for (refs) |*file_ref_entry| {
                const reference = file_ref_entry.* orelse continue;
                if (file_ref_count != 0) writer.writeByte(',') catch
                    return error.SnapshotTooLarge;
                file_ref_count += 1;
                writer.writeAll("{\"id\":") catch return error.SnapshotTooLarge;
                try text_projection.writeJson(writer, reference.id);
                writer.writeAll(",\"title\":") catch return error.SnapshotTooLarge;
                try text_projection.writeJson(writer, reference.title);
                writer.writeAll(",\"displayPath\":") catch return error.SnapshotTooLarge;
                try text_projection.writeJson(writer, reference.display_path);
                if (reference.generated()) {
                    writer.writeAll(if (reference.generated_video) ",\"generatedVideo\":true,\"presentationAnchor\":" else ",\"generatedImage\":true,\"presentationAnchor\":") catch return error.SnapshotTooLarge;
                    if (reference.presentation_anchor) |anchor| {
                        writer.print("{{\"afterOutputCount\":{d},\"presentationOrder\":\"{d}\"}}", .{ anchor.after_output_count, anchor.presentation_order }) catch return error.SnapshotTooLarge;
                    } else writer.writeAll("null") catch return error.SnapshotTooLarge;
                }
                writer.writeByte('}') catch return error.SnapshotTooLarge;
            };
            writer.writeAll("]}") catch return error.SnapshotTooLarge;
        },
        .done => return,
    }
    state.stage = @enumFromInt(@intFromEnum(state.stage) + 1);
}

/// Host-only temporary source for a single bounded preparation step. Raw JSON
/// can contain escaped sensitive text, so this source is never a delivery/cache
/// payload or a worker input. The canonical formatter sanitizes before sealing.
pub const OwnedToolProjection = struct {
    storage: []u8,
    references: ?[]?task_state.FileReferenceView,
    value: ToolProjection,

    pub fn capture(allocator: std.mem.Allocator, tool: *const ToolProjection, budget: usize) Error!OwnedToolProjection {
        var size = tool.id.len + tool.name.len + tool.input.len + tool.progress.len + tool.content.len;
        if (tool.file_refs) |refs| for (refs) |entry| if (entry) |ref| {
            size += ref.id.len + ref.title.len + ref.display_path.len;
        };
        const ref_bytes = if (tool.file_refs) |refs| refs.len * @sizeOf(?task_state.FileReferenceView) else 0;
        if (size > budget or ref_bytes > budget - size) return error.SnapshotTooLarge;
        const storage = try allocator.alloc(u8, size);
        errdefer {
            std.crypto.secureZero(u8, storage);
            allocator.free(storage);
        }
        const references = if (tool.file_refs) |refs| try allocator.alloc(?task_state.FileReferenceView, refs.len) else null;
        errdefer if (references) |refs| allocator.free(refs);
        var offset: usize = 0;
        var value = tool.*;
        inline for (.{ "id", "name", "input", "progress", "content" }) |field| @field(value, field) = copy(storage, &offset, @field(tool, field));
        if (references) |refs| for (tool.file_refs.?, refs) |entry, *target| {
            target.* = if (entry) |ref| .{
                .id = copy(storage, &offset, ref.id),
                .title = copy(storage, &offset, ref.title),
                .display_path = copy(storage, &offset, ref.display_path),
                .kind = &.{},
                .locator_kind = .workspace_path,
                .locator = &.{},
                .generated_image = ref.generated_image,
                .generated_video = ref.generated_video,
                .presentation_anchor = ref.presentation_anchor,
            } else null;
        };
        value.file_refs = references;
        value.route_digest = @splat(0);
        return .{ .storage = storage, .references = references, .value = value };
    }
    fn copy(storage: []u8, offset: *usize, source: []const u8) []u8 {
        const result = storage[offset.*..][0..source.len];
        @memcpy(result, source);
        offset.* += source.len;
        return result;
    }
    pub fn ownedBytes(self: *const OwnedToolProjection) usize {
        return self.storage.len + if (self.references) |refs| refs.len * @sizeOf(?task_state.FileReferenceView) else 0;
    }
    pub fn deinit(self: *OwnedToolProjection, allocator: std.mem.Allocator) void {
        std.crypto.secureZero(u8, self.storage);
        allocator.free(self.storage);
        if (self.references) |refs| allocator.free(refs);
        self.* = undefined;
    }
    pub const State = ToolWritingState;
    pub fn writeStage(self: *const OwnedToolProjection, writer: *std.Io.Writer, text: TextProjection, state: *State) Error!void {
        try writeToolStage(writer, text, &self.value, state);
    }
};

const BashInput = struct {
    command: []const u8,
    description: ?[]const u8 = null,
};

/// Only declared built-in argument shapes produce operation facts. Shell text
/// and Agent descriptions are never classified into effects or safety labels.
const PermissionPresentation = struct {
    kind: enum { command, read, write, edit, web_fetch },
    target: []const u8,
    description: ?[]const u8 = null,
};

fn permissionPresentation(permission: agent.PermissionRequest, allocator: std.mem.Allocator) ?PermissionPresentation {
    const kind = std.meta.stringToEnum(enum { Bash, Read, Write, Edit, WebFetch }, permission.tool.name);
    if (permission.tool.namespace != .builtin or kind == null or permission.arguments_json.len > max_permission_presentation_input_bytes) {
        return null;
    }
    const options = std.json.ParseOptions{ .ignore_unknown_fields = true, .allocate = .alloc_if_needed, .duplicate_field_behavior = .@"error" };
    if (kind.? == .Bash) {
        const parsed = std.json.parseFromSliceLeaky(BashInput, allocator, permission.arguments_json, options) catch return null;
        return .{ .kind = .command, .target = parsed.command, .description = parsed.description };
    }
    if (kind.? == .WebFetch) {
        const parsed = std.json.parseFromSliceLeaky(WebFetchInput, allocator, permission.arguments_json, options) catch return null;
        return .{ .kind = .web_fetch, .target = parsed.url };
    }
    const parsed = std.json.parseFromSliceLeaky(FileMutationInput, allocator, permission.arguments_json, options) catch return null;
    return .{ .kind = switch (kind.?) {
        .Read => .read,
        .Write => .write,
        .Edit => .edit,
        else => unreachable,
    }, .target = parsed.file_path };
}

fn writePermissionPresentation(writer: *std.Io.Writer, text: TextProjection, presentation: ?PermissionPresentation) Error!void {
    const value = presentation orelse {
        writer.writeAll("null") catch return error.SnapshotTooLarge;
        return;
    };
    writer.print("{{\"kind\":\"{s}\",\"{s}\":", .{ @tagName(value.kind), if (value.kind == .command) "command" else "target" }) catch return error.SnapshotTooLarge;
    try text.writeJson(writer, value.target);
    if (value.kind == .command) {
        writer.writeAll(",\"description\":") catch return error.SnapshotTooLarge;
        try writeOptionalProjectedValue(writer, text, value.description);
    }
    writer.writeByte('}') catch return error.SnapshotTooLarge;
}

fn permissionPresentationFits(value: PermissionPresentation) bool {
    // A size preflight must use the standard encoder directly. Calling the
    // deferred text projector with a temporary writer corrupts string offsets.
    // Reserve the fixed kind/key spelling; redaction can only shorten strings.
    var storage: [max_permission_presentation_bytes - 128]u8 = undefined;
    defer std.crypto.secureZero(u8, &storage);
    var writer = std.Io.Writer.fixed(&storage);
    std.json.Stringify.value(.{ .target = value.target, .description = value.description }, .{}, &writer) catch return false;
    return true;
}

fn writeOptionalProjectedValue(writer: *std.Io.Writer, text: TextProjection, value: ?[]const u8) Error!void {
    if (value) |present| try text.writeJson(writer, present) else writer.writeAll("null") catch return error.SnapshotTooLarge;
}

const ReadInput = struct {
    file_path: []const u8,
    offset: ?u64 = null,
    limit: ?u64 = null,
};

const FileMutationInput = struct {
    file_path: []const u8,
};

const GlobInput = struct {
    pattern: []const u8,
    path: ?[]const u8 = null,
};

const GrepInput = struct {
    pattern: []const u8,
    path: ?[]const u8 = null,
    glob: ?[]const u8 = null,
};

const BackgroundJobInput = struct {
    job_id: []const u8,
};

const BashOutputResult = struct {
    status: []const u8,
    stdout: []const u8 = "",
    stderr: []const u8 = "",
    stdout_truncated: bool = false,
    stderr_truncated: bool = false,

    fn supported(self: BashOutputResult) bool {
        return std.mem.eql(u8, self.status, "running") or
            std.mem.eql(u8, self.status, "exited") or
            std.mem.eql(u8, self.status, "killed");
    }
};

const WebSearchInput = struct {
    query: []const u8,
};

const WebFetchInput = struct {
    url: []const u8,
    prompt: ?[]const u8 = null,
};

const WebFetchResult = struct {
    url: []const u8,
    content: []const u8,
    bytes: ?u64 = null,
};

const ToolErrorEnvelope = struct {
    @"error": struct {
        detail: []const u8,
    },
};

// Only this exact, foreground result envelope is interpreted. Other tool
// results (including background jobs) retain their existing raw detail view.
const BashResult = struct {
    schema_version: []const u8,
    stdout: []const u8,
    stdout_encoding: []const u8,
    stdout_capture_complete: bool,
    stdout_truncated: bool,
    stderr: []const u8,
    stderr_encoding: []const u8,
    stderr_capture_complete: bool,
    stderr_truncated: bool,
    exit_code: i32,

    fn supported(self: BashResult) bool {
        return std.mem.eql(u8, self.schema_version, "metacodes.bash-result.v2") and
            std.mem.eql(u8, self.stdout_encoding, "utf-8") and
            std.mem.eql(u8, self.stderr_encoding, "utf-8");
    }
};

fn writeBashInput(
    writer: *std.Io.Writer,
    text: TextProjection,
    tool: *const task_state.ToolView,
) Error!bool {
    writer.writeAll(",\"bash\":") catch return error.SnapshotTooLarge;
    if (!std.mem.eql(u8, tool.name, "Bash")) {
        writer.writeAll("null") catch return error.SnapshotTooLarge;
        return false;
    }
    // Parsing is bounded independently of raw evidence retention. The scanner
    // borrows unescaped strings and uses this scratch only when decoding needs
    // storage. Exhaustion is an unavailable presentation, never a Run failure.
    var scratch: [128 * 1024]u8 = undefined;
    var allocator = JsonScratch.init(&scratch);
    defer allocator.clear();
    const options = std.json.ParseOptions{ .ignore_unknown_fields = true, .allocate = .alloc_if_needed };
    var redacted = false;
    writer.writeAll("{\"command\":") catch return error.SnapshotTooLarge;
    const input = if (!tool.input_truncated and tool.input.len != 0 and tool.input.len <= scratch.len)
        std.json.parseFromSliceLeaky(BashInput, allocator.allocator(), tool.input, options) catch null
    else
        null;
    if (input) |parsed| {
        redacted = text.containsSensitive(parsed.command);
        try text.writeJson(writer, parsed.command);
        writer.writeAll(",\"description\":") catch return error.SnapshotTooLarge;
        if (parsed.description) |description| {
            redacted = redacted or text.containsSensitive(description);
            try text.writeJson(writer, description);
        } else writer.writeAll("null") catch return error.SnapshotTooLarge;
    } else writer.writeAll("null,\"description\":null") catch return error.SnapshotTooLarge;
    return redacted;
}

fn writeBashResult(writer: *std.Io.Writer, text: TextProjection, tool: *const task_state.ToolView) Error!bool {
    if (!std.mem.eql(u8, tool.name, "Bash")) return false;
    var scratch: [128 * 1024]u8 = undefined;
    var allocator = JsonScratch.init(&scratch);
    defer allocator.clear();
    const options = std.json.ParseOptions{ .ignore_unknown_fields = true, .allocate = .alloc_if_needed };
    var redacted = false;
    writer.writeAll(",\"result\":") catch return error.SnapshotTooLarge;
    const result = if (tool.state != .running and !tool.content_truncated and tool.content.len != 0 and tool.content.len <= scratch.len)
        std.json.parseFromSliceLeaky(BashResult, allocator.allocator(), tool.content, options) catch null
    else
        null;
    if (result) |parsed| {
        const value = parsed;
        if (value.supported()) {
            redacted = redacted or text.containsSensitive(value.stdout) or text.containsSensitive(value.stderr);
            writer.print("{{\"exitCode\":{d},\"stdout\":", .{value.exit_code}) catch return error.SnapshotTooLarge;
            try text.writeJson(writer, value.stdout);
            writer.writeAll(",\"stderr\":") catch return error.SnapshotTooLarge;
            try text.writeJson(writer, value.stderr);
            writer.print(",\"stdoutIncomplete\":{},\"stderrIncomplete\":{}}}", .{
                value.stdout_truncated or !value.stdout_capture_complete,
                value.stderr_truncated or !value.stderr_capture_complete,
            }) catch return error.SnapshotTooLarge;
        } else writer.writeAll("null") catch return error.SnapshotTooLarge;
    } else writer.writeAll("null") catch return error.SnapshotTooLarge;
    writer.writeByte('}') catch return error.SnapshotTooLarge;
    return redacted;
}

fn writeToolPresentation(
    writer: *std.Io.Writer,
    text: TextProjection,
    tool: *const task_state.ToolView,
    pending_result: *bool,
) Error!bool {
    writer.writeAll(",\"presentation\":") catch return error.SnapshotTooLarge;
    if (tool.input_truncated or tool.input.len == 0 or tool.input.len > 128 * 1024) {
        writer.writeAll("null") catch return error.SnapshotTooLarge;
        return false;
    }

    // Bash has its own presentation; unsupported tools must not initialize
    // the generic parser scratch merely to return a null presentation.
    const kind = std.meta.stringToEnum(enum { Read, Write, Edit, Glob, Grep, BashOutput, KillShell, WebSearch, WebFetch }, tool.name) orelse {
        writer.writeAll("null") catch return error.SnapshotTooLarge;
        return false;
    };
    var scratch: [128 * 1024]u8 = undefined;
    var allocator = JsonScratch.init(&scratch);
    defer allocator.clear();
    const options = std.json.ParseOptions{ .ignore_unknown_fields = true, .allocate = .alloc_if_needed };
    var redacted = false;

    if (kind == .Read) {
        const parsed = std.json.parseFromSliceLeaky(ReadInput, allocator.allocator(), tool.input, options) catch {
            writer.writeAll("null") catch return error.SnapshotTooLarge;
            return false;
        };
        const value = parsed;
        redacted = text.containsSensitive(value.file_path);
        writer.writeAll("{\"kind\":\"read\",\"target\":") catch return error.SnapshotTooLarge;
        try text.writeJson(writer, value.file_path);
        try writeOptionalWireNumber(writer, "offset", value.offset);
        try writeOptionalWireNumber(writer, "limit", value.limit);
        writer.writeByte('}') catch return error.SnapshotTooLarge;
        return redacted;
    }
    if (kind == .Write or kind == .Edit) {
        const parsed = std.json.parseFromSliceLeaky(FileMutationInput, allocator.allocator(), tool.input, options) catch {
            writer.writeAll("null") catch return error.SnapshotTooLarge;
            return false;
        };
        const value = parsed;
        redacted = text.containsSensitive(value.file_path);
        writer.writeAll(if (kind == .Write)
            "{\"kind\":\"write\",\"target\":"
        else
            "{\"kind\":\"edit\",\"target\":") catch return error.SnapshotTooLarge;
        try text.writeJson(writer, value.file_path);
        writer.writeByte('}') catch return error.SnapshotTooLarge;
        return redacted;
    }
    if (kind == .Glob) {
        const parsed = std.json.parseFromSliceLeaky(GlobInput, allocator.allocator(), tool.input, options) catch {
            writer.writeAll("null") catch return error.SnapshotTooLarge;
            return false;
        };
        const value = parsed;
        redacted = text.containsSensitive(value.pattern) or
            if (value.path) |path| text.containsSensitive(path) else false;
        writer.writeAll("{\"kind\":\"glob\",\"pattern\":") catch return error.SnapshotTooLarge;
        try text.writeJson(writer, value.pattern);
        try writeOptionalProjectedText(writer, text, "scope", value.path);
        writer.writeByte('}') catch return error.SnapshotTooLarge;
        return redacted;
    }
    if (kind == .Grep) {
        const parsed = std.json.parseFromSliceLeaky(GrepInput, allocator.allocator(), tool.input, options) catch {
            writer.writeAll("null") catch return error.SnapshotTooLarge;
            return false;
        };
        const value = parsed;
        redacted = text.containsSensitive(value.pattern) or
            (if (value.path) |path| text.containsSensitive(path) else false) or
            (if (value.glob) |glob| text.containsSensitive(glob) else false);
        writer.writeAll("{\"kind\":\"grep\",\"pattern\":") catch return error.SnapshotTooLarge;
        try text.writeJson(writer, value.pattern);
        try writeOptionalProjectedText(writer, text, "scope", value.path);
        try writeOptionalProjectedText(writer, text, "include", value.glob);
        writer.writeByte('}') catch return error.SnapshotTooLarge;
        return redacted;
    }
    if (kind == .BashOutput) {
        const parsed = std.json.parseFromSliceLeaky(BackgroundJobInput, allocator.allocator(), tool.input, options) catch {
            writer.writeAll("null") catch return error.SnapshotTooLarge;
            return false;
        };
        const value = parsed;
        redacted = text.containsSensitive(value.job_id);
        writer.writeAll("{\"kind\":\"bash_output\",\"jobId\":") catch return error.SnapshotTooLarge;
        try text.writeJson(writer, value.job_id);
        writer.writeAll(",\"result\":") catch return error.SnapshotTooLarge;
        pending_result.* = true;
        return redacted;
    }
    if (kind == .KillShell) {
        const parsed = std.json.parseFromSliceLeaky(BackgroundJobInput, allocator.allocator(), tool.input, options) catch {
            writer.writeAll("null") catch return error.SnapshotTooLarge;
            return false;
        };
        const value = parsed;
        redacted = text.containsSensitive(value.job_id);
        writer.writeAll("{\"kind\":\"kill_shell\",\"jobId\":") catch return error.SnapshotTooLarge;
        try text.writeJson(writer, value.job_id);
        writer.writeByte('}') catch return error.SnapshotTooLarge;
        return redacted;
    }
    if (kind == .WebSearch) {
        const parsed = std.json.parseFromSliceLeaky(WebSearchInput, allocator.allocator(), tool.input, options) catch {
            writer.writeAll("null") catch return error.SnapshotTooLarge;
            return false;
        };
        const value = parsed;
        redacted = text.containsSensitive(value.query);
        writer.writeAll("{\"kind\":\"web_search\",\"query\":") catch return error.SnapshotTooLarge;
        try text.writeJson(writer, value.query);
        writer.writeByte('}') catch return error.SnapshotTooLarge;
        return redacted;
    }
    if (kind == .WebFetch) {
        const parsed = std.json.parseFromSliceLeaky(WebFetchInput, allocator.allocator(), tool.input, options) catch {
            writer.writeAll("null") catch return error.SnapshotTooLarge;
            return false;
        };
        const value = parsed;
        redacted = text.containsSensitive(value.url) or
            if (value.prompt) |prompt| text.containsSensitive(prompt) else false;
        writer.writeAll("{\"kind\":\"web_fetch\",\"url\":") catch return error.SnapshotTooLarge;
        try text.writeJson(writer, value.url);
        try writeOptionalProjectedText(writer, text, "prompt", value.prompt);
        writer.writeAll(",\"result\":") catch return error.SnapshotTooLarge;
        pending_result.* = true;
        return redacted;
    }

    writer.writeAll("null") catch return error.SnapshotTooLarge;
    return false;
}

fn writeToolPresentationResult(writer: *std.Io.Writer, text: TextProjection, tool: *const task_state.ToolView) Error!bool {
    var scratch: [128 * 1024]u8 = undefined;
    var allocator = JsonScratch.init(&scratch);
    defer allocator.clear();
    const options = std.json.ParseOptions{ .ignore_unknown_fields = true, .allocate = .alloc_if_needed };
    var redacted = false;
    if (std.mem.eql(u8, tool.name, "BashOutput")) {
        const result = if (tool.state != .running and !tool.content_truncated and tool.content.len != 0 and tool.content.len <= scratch.len)
            std.json.parseFromSliceLeaky(BashOutputResult, allocator.allocator(), tool.content, options) catch null
        else
            null;
        if (result) |decoded| {
            const result_value = decoded;
            if (result_value.supported()) {
                redacted = redacted or text.containsSensitive(result_value.stdout) or
                    text.containsSensitive(result_value.stderr);
                writer.writeAll("{\"status\":") catch return error.SnapshotTooLarge;
                try text.writeJson(writer, result_value.status);
                writer.writeAll(",\"stdout\":") catch return error.SnapshotTooLarge;
                try text.writeJson(writer, result_value.stdout);
                writer.writeAll(",\"stderr\":") catch return error.SnapshotTooLarge;
                try text.writeJson(writer, result_value.stderr);
                writer.print(",\"stdoutIncomplete\":{},\"stderrIncomplete\":{}}}", .{
                    result_value.stdout_truncated,
                    result_value.stderr_truncated,
                }) catch return error.SnapshotTooLarge;
            } else writer.writeAll("null") catch return error.SnapshotTooLarge;
        } else writer.writeAll("null") catch return error.SnapshotTooLarge;
        writer.writeByte('}') catch return error.SnapshotTooLarge;
        return redacted;
    }
    if (std.mem.eql(u8, tool.name, "WebFetch")) {
        const result = if (tool.state != .running and !tool.content_truncated and tool.content.len != 0 and tool.content.len <= scratch.len)
            std.json.parseFromSliceLeaky(WebFetchResult, allocator.allocator(), tool.content, options) catch null
        else
            null;
        if (result) |decoded| {
            const result_value = decoded;
            redacted = redacted or text.containsSensitive(result_value.url) or
                text.containsSensitive(result_value.content);
            writer.writeAll("{\"url\":") catch return error.SnapshotTooLarge;
            try text.writeJson(writer, result_value.url);
            try writeOptionalWireNumber(writer, "bytes", result_value.bytes);
            writer.writeAll(",\"content\":") catch return error.SnapshotTooLarge;
            try text.writeJson(writer, result_value.content);
            writer.writeByte('}') catch return error.SnapshotTooLarge;
        } else writer.writeAll("null") catch return error.SnapshotTooLarge;
        writer.writeByte('}') catch return error.SnapshotTooLarge;
        return redacted;
    }
    unreachable;
}

fn writeToolErrorDetail(
    writer: *std.Io.Writer,
    text: TextProjection,
    tool: *const task_state.ToolView,
) Error!bool {
    writer.writeAll(",\"errorDetail\":") catch return error.SnapshotTooLarge;
    if (tool.state != .failed or tool.content_truncated or tool.content.len == 0 or tool.content.len > 128 * 1024) {
        writer.writeAll("null") catch return error.SnapshotTooLarge;
        return false;
    }
    var scratch: [128 * 1024]u8 = undefined;
    var allocator = JsonScratch.init(&scratch);
    defer allocator.clear();
    const parsed = std.json.parseFromSliceLeaky(
        ToolErrorEnvelope,
        allocator.allocator(),
        tool.content,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_if_needed },
    ) catch {
        writer.writeAll("null") catch return error.SnapshotTooLarge;
        return false;
    };
    const detail = parsed.@"error".detail;
    try text.writeJson(writer, detail);
    return text.containsSensitive(detail);
}

fn writeOptionalProjectedText(
    writer: *std.Io.Writer,
    text: TextProjection,
    comptime name: []const u8,
    value: ?[]const u8,
) Error!void {
    writer.writeAll(",\"" ++ name ++ "\":") catch return error.SnapshotTooLarge;
    if (value) |present| try text.writeJson(writer, present) else writer.writeAll("null") catch return error.SnapshotTooLarge;
}

fn writeOptionalWireNumber(
    writer: *std.Io.Writer,
    comptime name: []const u8,
    value: ?u64,
) Error!void {
    writer.writeAll(",\"" ++ name ++ "\":") catch return error.SnapshotTooLarge;
    if (value) |present| writer.print("\"{d}\"", .{present}) catch
        return error.SnapshotTooLarge else writer.writeAll("null") catch return error.SnapshotTooLarge;
}

fn writeRunOutput(
    writer: *std.Io.Writer,
    text: TextProjection,
    run: *const task_state.RunRecord,
) Error!void {
    const committed = run.assistant.list.items[0..run.assistant.committed_len];
    const response_start = run.assistant_output_start orelse committed.len;
    std.debug.assert(response_start <= committed.len);
    std.debug.assert((run.assistant_output_kind == null) ==
        (run.assistant_output_start == null));
    if (run.commentary_count > run.commentary_ends.len)
        return error.SnapshotTooLarge;
    const commentary_ends = run.commentary_ends[0..run.commentary_count];
    const commentary_end = if (commentary_ends.len != 0)
        @as(usize, @intCast(commentary_ends[commentary_ends.len - 1]))
    else
        0;
    if (commentary_end != response_start) return error.SnapshotTooLarge;
    writer.writeAll(",\"output\":{\"commentary\":") catch
        return error.SnapshotTooLarge;
    const output_redacted = try text.writeJsonOutput(
        writer,
        committed,
        commentary_ends,
    );
    writer.writeAll(",\"responseKind\":") catch return error.SnapshotTooLarge;
    if (run.assistant_output_kind) |kind|
        jsonValue(writer, @tagName(kind)) catch return error.SnapshotTooLarge
    else
        writer.writeAll("null") catch return error.SnapshotTooLarge;
    writer.writeAll(",\"provisional\":") catch return error.SnapshotTooLarge;
    const provisional_redacted = try text.writeJsonParts(
        writer,
        run.output_continued.list.items[0..run.output_continued.committed_len],
        run.output_segment.list.items[0..run.output_segment.committed_len],
    );
    writer.print(",\"redacted\":{},\"provisionalRedacted\":{}}}", .{
        run.assistant_redacted or output_redacted,
        run.provisionalRedacted() or provisional_redacted,
    }) catch return error.SnapshotTooLarge;
}

fn writeRunActivity(
    writer: *std.Io.Writer,
    activity: ?task_state.RunActivity,
) Error!void {
    const value = activity orelse {
        writer.writeAll("null") catch return error.SnapshotTooLarge;
        return;
    };
    switch (value) {
        .executing_tools => |tools| {
            writer.writeAll("{\"kind\":\"executing_tools\",\"inFlight\":") catch
                return error.SnapshotTooLarge;
            if (tools.in_flight) |count|
                writer.print("\"{d}\"", .{count}) catch return error.SnapshotTooLarge
            else
                writer.writeAll("null") catch return error.SnapshotTooLarge;
            writer.writeByte('}') catch return error.SnapshotTooLarge;
        },
        .retrying_provider => |retry| {
            writer.writeAll("{\"kind\":\"retrying_provider\",\"attempt\":") catch
                return error.SnapshotTooLarge;
            try writeOptionalInteger(writer, retry.attempt);
            writer.writeAll(",\"max\":") catch return error.SnapshotTooLarge;
            try writeOptionalInteger(writer, retry.max);
            writer.writeAll(",\"delayMs\":") catch return error.SnapshotTooLarge;
            try writeOptionalInteger(writer, retry.delay_ms);
            writer.writeByte('}') catch return error.SnapshotTooLarge;
        },
        else => writer.print("{{\"kind\":\"{s}\"}}", .{@tagName(value)}) catch
            return error.SnapshotTooLarge,
    }
}

fn writeConversationContext(
    writer: *std.Io.Writer,
    observation: task_state.ConversationObservation,
) Error!void {
    writer.writeAll("{\"pressure\":") catch return error.SnapshotTooLarge;
    if (observation.pressure) |pressure| {
        writer.print("{{\"sourceRunId\":\"{d}\",\"currentTokens\":\"{d}\",\"warningThreshold\":\"{d}\",\"autoCompactThreshold\":\"{d}\",\"blockingLimit\":\"{d}\",\"severity\":\"{s}\"}}", .{
            pressure.source_run_id,
            pressure.current_tokens,
            pressure.warning_threshold,
            pressure.auto_compact_threshold,
            pressure.blocking_limit,
            @tagName(pressure.severity),
        }) catch return error.SnapshotTooLarge;
    } else writer.writeAll("null") catch return error.SnapshotTooLarge;
    writer.writeAll(",\"lastAutoCompact\":") catch return error.SnapshotTooLarge;
    if (observation.last_auto_compact) |compact| {
        writer.print("{{\"sourceRunId\":\"{d}\",\"dropped\":\"{d}\",\"kept\":\"{d}\",\"beforeTokens\":\"{d}\",\"afterTokens\":\"{d}\"}}", .{
            compact.source_run_id,
            compact.dropped,
            compact.kept,
            compact.before_tokens,
            compact.after_tokens,
        }) catch return error.SnapshotTooLarge;
    } else writer.writeAll("null") catch return error.SnapshotTooLarge;
    writer.writeByte('}') catch return error.SnapshotTooLarge;
}

fn writeOptionalInteger(writer: *std.Io.Writer, value: anytype) Error!void {
    if (value) |number|
        writer.print("\"{d}\"", .{number}) catch return error.SnapshotTooLarge
    else
        writer.writeAll("null") catch return error.SnapshotTooLarge;
}

fn writeCompact(
    writer: *std.Io.Writer,
    compact: *const task_state.CompactRecord,
) Error!void {
    const projection = task_state.compactProjectionFacts(compact);
    const terminal = projection.terminal;
    writer.print(
        "{{\"operationId\":\"{d}\",\"afterRunId\":\"{d}\",\"conversationCoverage\":\"{s}\",\"phase\":\"{s}\",\"cause\":",
        .{
            compact.id,
            compact.after_run_id,
            if (compact.coverage == .excluded) "excluded" else "included",
            @tagName(projection.phase),
        },
    ) catch return error.SnapshotTooLarge;
    if (if (terminal) |payload| payload.cause else null) |cause|
        jsonValue(writer, @tagName(cause)) catch return error.SnapshotTooLarge
    else
        writer.writeAll("null") catch return error.SnapshotTooLarge;
    const before_context_tokens = if (terminal) |payload|
        payload.before_context_tokens
    else
        0;
    const after_context_tokens = if (terminal) |payload|
        payload.after_context_tokens
    else
        0;
    const usage = if (terminal) |payload| payload.usage else task_state.UsageView{};
    writer.print(
        ",\"beforeContextTokens\":\"{d}\",\"afterContextTokens\":\"{d}\",\"usage\":{{\"input\":\"{d}\",\"output\":\"{d}\",\"cacheRead\":\"{d}\",\"cacheCreation\":\"{d}\"}}}}",
        .{
            before_context_tokens,
            after_context_tokens,
            usage.input_tokens,
            usage.output_tokens,
            usage.cache_read_input_tokens,
            usage.cache_creation_input_tokens,
        },
    ) catch return error.SnapshotTooLarge;
}

fn writeUiHistory(
    writer: *std.Io.Writer,
    text: TextProjection,
    task: *const task_state.Task,
) Error!void {
    const history = task.durable.ui_history;
    const start = if (task.durable.ui_history_count == history.len)
        task.durable.ui_history_next
    else
        0;
    for (0..task.durable.ui_history_count) |offset| {
        if (offset != 0) writer.writeByte(',') catch return error.SnapshotTooLarge;
        const index = (start + offset) % history.len;
        const record = &(history[index] orelse unreachable);
        writer.print("{{\"requestId\":\"{d}\",\"runId\":\"{d}\",\"order\":\"{d}\",\"kind\":\"{s}\",\"state\":\"{s}\",\"detail\":", .{
            record.request_id,
            record.run_id,
            record.order,
            @tagName(record.kind),
            @tagName(record.state),
        }) catch return error.SnapshotTooLarge;
        try text.writeJson(writer, record.detailSlice());
        writer.writeAll(",\"answeredBy\":") catch return error.SnapshotTooLarge;
        if (record.answered_by) |source| jsonValue(writer, @tagName(source)) catch return error.SnapshotTooLarge else writer.writeAll("null") catch return error.SnapshotTooLarge;
        writer.writeAll(",\"reviewReason\":") catch return error.SnapshotTooLarge;
        if (record.review_reason_len != 0) try text.writeJson(writer, record.review_reason[0..record.review_reason_len]) else writer.writeAll("null") catch return error.SnapshotTooLarge;
        writer.writeAll(",\"review\":") catch return error.SnapshotTooLarge;
        if (record.review) |*review| {
            writer.print("{{\"outcome\":\"{s}\",\"cause\":", .{@tagName(review.outcome)}) catch return error.SnapshotTooLarge;
            if (review.cause) |cause| jsonValue(writer, @tagName(cause)) catch return error.SnapshotTooLarge else writer.writeAll("null") catch return error.SnapshotTooLarge;
            writer.writeAll(",\"reason\":") catch return error.SnapshotTooLarge;
            if (review.reasonText()) |reason| try text.writeJson(writer, reason) else writer.writeAll("null") catch return error.SnapshotTooLarge;
            writer.writeByte('}') catch return error.SnapshotTooLarge;
        } else writer.writeAll("null") catch return error.SnapshotTooLarge;
        writer.print(",\"itemCount\":{d},\"detailTruncated\":{},\"redacted\":{},\"agentRequestId\":", .{
            record.item_count,
            record.detail_truncated,
            record.redacted,
        }) catch return error.SnapshotTooLarge;
        try text.writeJson(
            writer,
            record.agent_request_id[0..record.agent_request_id_len],
        );
        writer.writeAll(",\"permission\":") catch return error.SnapshotTooLarge;
        if (record.permission) |permission| {
            writer.writeAll("{\"requestId\":") catch return error.SnapshotTooLarge;
            jsonValue(writer, permission.requestId()) catch return error.SnapshotTooLarge;
            writer.writeAll(",\"matchedRuleId\":") catch return error.SnapshotTooLarge;
            jsonValue(writer, permission.matchedRuleId()) catch return error.SnapshotTooLarge;
            writer.writeAll(",\"toolNamespace\":") catch return error.SnapshotTooLarge;
            jsonValue(writer, @tagName(permission.tool_namespace)) catch return error.SnapshotTooLarge;
            writer.writeAll(",\"toolName\":") catch return error.SnapshotTooLarge;
            jsonValue(writer, permission.toolName()) catch return error.SnapshotTooLarge;
            writer.writeAll(",\"toolBinding\":") catch return error.SnapshotTooLarge;
            jsonValue(writer, permission.toolBinding()) catch return error.SnapshotTooLarge;
            writer.writeAll(",\"canonicalArgumentsDigest\":") catch return error.SnapshotTooLarge;
            jsonValue(writer, permission.canonicalArgumentsDigest()) catch return error.SnapshotTooLarge;
            writer.writeAll(",\"decision\":") catch return error.SnapshotTooLarge;
            jsonValue(writer, @tagName(permission.decision)) catch return error.SnapshotTooLarge;
            writer.writeAll(",\"source\":") catch return error.SnapshotTooLarge;
            jsonValue(writer, @tagName(permission.source)) catch return error.SnapshotTooLarge;
            writer.print(",\"policyGeneration\":\"{d}\",\"usedSessionRule\":{},\"callbackOutcome\":", .{
                permission.policy_generation,
                permission.used_session_rule,
            }) catch return error.SnapshotTooLarge;
            if (permission.callback_outcome) |outcome|
                jsonValue(writer, @tagName(outcome)) catch return error.SnapshotTooLarge
            else
                writer.writeAll("null") catch return error.SnapshotTooLarge;
            writer.writeByte('}') catch return error.SnapshotTooLarge;
        } else writer.writeAll("null") catch return error.SnapshotTooLarge;
        writer.writeByte('}') catch return error.SnapshotTooLarge;
    }
}

pub fn catalogProjection(task: *const task_state.Task) product_skill.catalog.CatalogProjection {
    if (task.skills_unavailable) return .{ .availability = .unavailable };
    return if (task.runtime.pinnedCatalogConst()) |snapshot|
        snapshot.view()
    else
        .{ .availability = switch (task.initial_catalog_preparation) {
            .uninitialized => .uninitialized,
            .loading => .loading,
            .unavailable => .unavailable,
        } };
}

fn jsonValue(writer: *std.Io.Writer, value: anytype) !void {
    try std.json.Stringify.value(
        value,
        .{ .emit_nonportable_numbers_as_strings = true },
        writer,
    );
}

test "approval result wire keeps nullable reason and exact revision without allocation" {
    var storage: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try std.json.Stringify.value(view_contract.ApprovalResult{
        .revision = .{ .value = std.math.maxInt(u64) },
        .outcome = .completed,
        .reason = null,
    }, .{}, &writer);
    try std.testing.expectEqualStrings("{\"revision\":\"18446744073709551615\",\"outcome\":\"completed\",\"reason\":null}", writer.buffered());
}

test "interrupted Compact serializer matches the independent Renderer fixture" {
    var diagnostic: [0]u8 = .{};
    const compact = task_state.CompactRecord{
        .id = std.math.maxInt(u64),
        .coverage = .excluded,
        .after_run_id = 7,
        .terminal_publication = .init(.published),
        .terminal_observed = true,
        .terminal_diagnostic = &diagnostic,
        .terminal_payload = .{
            .exclude_on_product_terminal = false,
            .phase = .interrupted,
            .cause = null,
            .before_context_tokens = 100,
            .after_context_tokens = 40,
            .usage = .{ .input_tokens = 5, .output_tokens = 2 },
            .session_disposition_at_completion = .reusable,
        },
    };
    var storage: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try writeCompact(&writer, &compact);
    try std.testing.expectEqualStrings(std.mem.trim(u8, @import("task_view_fixture").interrupted_compact, "\r\n"), writer.buffered());
    writer = std.Io.Writer.fixed(storage[0..8]);
    try std.testing.expectError(error.SnapshotTooLarge, writeCompact(&writer, &compact));
}

test "Product view owned Tool preparation copies facts and releases every allocation failure" {
    const Harness = struct {
        fn capture(allocator: std.mem.Allocator) !void {
            var input = [_]u8{ 'o', 'l', 'd' };
            var refs = [_]?task_state.FileReferenceView{.{ .id = @constCast("ref"), .title = @constCast("title"), .display_path = @constCast("path"), .kind = @constCast("file"), .locator_kind = .workspace_path, .locator = @constCast("private") }};
            const tool: ToolProjection = .{ .route_digest = @splat(7), .id = @constCast("tool"), .order = 1, .name = @constCast("Bash"), .input = &input, .progress = @constCast(""), .content = @constCast("result"), .state = .completed, .file_refs = &refs };
            var owned = try OwnedToolProjection.capture(allocator, &tool, 1024);
            defer owned.deinit(allocator);
            @memset(&input, 'x');
            refs[0] = null;
            try std.testing.expectEqualStrings("old", owned.value.input);
            try std.testing.expectEqualStrings("path", owned.value.file_refs.?[0].?.display_path);
            try std.testing.expectEqualStrings("", owned.value.file_refs.?[0].?.locator);
            try std.testing.expectError(error.SnapshotTooLarge, OwnedToolProjection.capture(allocator, &tool, 1));
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Harness.capture, .{});
}
