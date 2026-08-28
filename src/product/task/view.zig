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

pub const Error = std.mem.Allocator.Error || error{
    SnapshotTooLarge,
    InvalidUiResponse,
};

/// Callback-scoped access to Workbench's global sensitive-text projection.
/// The callbacks expose neither credential bytes nor the composition object.
pub const TextProjection = struct {
    context: *const anyopaque,
    contains_sensitive_fn: *const fn (*const anyopaque, []const u8) bool,
    write_json_fn: *const fn (*const anyopaque, *std.Io.Writer, []const u8) Error!void,

    fn containsSensitive(self: TextProjection, value: []const u8) bool {
        return self.contains_sensitive_fn(self.context, value);
    }

    fn writeJson(
        self: TextProjection,
        writer: *std.Io.Writer,
        value: []const u8,
    ) Error!void {
        return self.write_json_fn(self.context, writer, value);
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

pub const Input = struct {
    task: *const task_state.Task,
    recovery: task_recovery.Projection,
    shutting_down: bool,
    text: TextProjection,
    catalog: CatalogProjection,
    pending_ui: PendingUiProjection,
};

pub fn writeProjection(writer: *std.Io.Writer, input: Input) Error!void {
    const task = input.task;
    writer.print("{{\"id\":\"{d}\",\"recentOrder\":\"{d}\",\"title\":", .{
        task.durable.id,
        task.durable.recent_order,
    }) catch return error.SnapshotTooLarge;
    try input.text.writeJson(writer, task.durable.title);
    writer.print(",\"workspaceId\":\"{d}\",\"binding\":{{\"epoch\":\"{d}\",\"availability\":\"{s}\",\"provider\":\"{s}\",\"model\":", .{
        task.durable.workspace_id,
        task.durable.binding_epoch,
        if (task.runtime.executionConst() == null) "unavailable" else "available",
        @tagName(task.durable.execution_provider),
    }) catch return error.SnapshotTooLarge;
    try input.text.writeJson(writer, task.durable.execution_model);
    writer.print(",\"executionGeneration\":\"{d}\",\"unavailableReason\":", .{task.durable.execution_generation}) catch
        return error.SnapshotTooLarge;
    if (task.runtime.executionConst() == null)
        writer.writeAll("\"runtime_detached\"") catch return error.SnapshotTooLarge
    else
        writer.writeAll("null") catch return error.SnapshotTooLarge;
    writer.writeByte('}') catch return error.SnapshotTooLarge;
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
        if (task_policy.currentRunPhase(task) == null) 0 else task.runtime.active_run_id,
    }) catch return error.SnapshotTooLarge;
    if (task_policy.currentRunPhase(task)) |phase|
        jsonValue(writer, @tagName(phase)) catch return error.SnapshotTooLarge
    else
        writer.writeAll("null") catch return error.SnapshotTooLarge;
    const last_terminal = task_policy.lastTerminalFacts(task.durable.runs);
    writer.writeAll(",\"lastRunOutcome\":") catch return error.SnapshotTooLarge;
    if (last_terminal) |terminal|
        jsonValue(writer, @tagName(terminal.outcome)) catch return error.SnapshotTooLarge
    else
        writer.writeAll("null") catch return error.SnapshotTooLarge;
    writer.writeAll(",\"cause\":") catch return error.SnapshotTooLarge;
    if (last_terminal) |terminal| {
        if (terminal.cause) |cause|
            jsonValue(writer, @tagName(cause)) catch return error.SnapshotTooLarge
        else
            writer.writeAll("null") catch return error.SnapshotTooLarge;
    } else writer.writeAll("null") catch return error.SnapshotTooLarge;
    writer.writeAll(",\"runs\":[") catch return error.SnapshotTooLarge;
    var run_count: usize = 0;
    for (task.durable.runs) |*entry| {
        const run = &(entry.* orelse continue);
        if (run_count != 0) writer.writeByte(',') catch return error.SnapshotTooLarge;
        run_count += 1;
        try writeRun(writer, input.text, run);
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
    try input.pending_ui.write(writer, task, input.text);
    writer.writeAll(",\"uiHistory\":[") catch return error.SnapshotTooLarge;
    try writeUiHistory(writer, input.text, task);
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
    writer.print("{{\"requestId\":\"{d}\",\"runId\":\"{d}\",\"order\":\"{d}\",\"redacted\":{},", .{
        request_id,
        run_id,
        order,
        text.containsSensitive(permission.tool.name) or
            text.containsSensitive(permission.arguments_json),
    }) catch return error.SnapshotTooLarge;
    writer.writeAll("\"kind\":\"permission\",\"tool\":") catch
        return error.SnapshotTooLarge;
    try text.writeJson(writer, permission.tool.name);
    writer.writeAll(",\"args\":") catch return error.SnapshotTooLarge;
    try text.writeJson(writer, permission.arguments_json);
    writer.writeAll(",\"availableChoices\":[") catch return error.SnapshotTooLarge;
    var wrote_choice = false;
    for (permission.responses) |choice| {
        if (choice == .allow_session or choice == .deny_session) {
            if (permission.candidate == null) continue;
        }
        if (wrote_choice) writer.writeByte(',') catch return error.SnapshotTooLarge;
        jsonValue(writer, @tagName(choice)) catch return error.SnapshotTooLarge;
        wrote_choice = true;
    }
    writer.writeAll("]}") catch return error.SnapshotTooLarge;
}

fn writeRun(
    writer: *std.Io.Writer,
    text_projection: TextProjection,
    run: *const task_state.RunRecord,
) Error!void {
    const terminal = task_state.productTerminalFacts(run);
    writer.print("{{\"id\":\"{d}\",\"phase\":\"{s}\",\"input\":", .{
        run.id,
        @tagName(task_state.runPhase(run)),
    }) catch return error.SnapshotTooLarge;
    switch (run.input) {
        .text => |text| {
            writer.writeAll("{\"kind\":\"text\",\"text\":") catch
                return error.SnapshotTooLarge;
            try text_projection.writeJson(writer, text.value);
            writer.print(",\"redacted\":{}}}", .{text.redacted}) catch
                return error.SnapshotTooLarge;
        },
        .skill => |skill| {
            writer.writeAll("{\"kind\":\"skill\",\"skillId\":") catch
                return error.SnapshotTooLarge;
            try text_projection.writeJson(writer, skill.skill_id);
            writer.writeAll(",\"catalogRevision\":") catch
                return error.SnapshotTooLarge;
            try text_projection.writeJson(writer, skill.catalog_revision);
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
    writer.writeAll(",\"assistant\":") catch return error.SnapshotTooLarge;
    try text_projection.writeJson(
        writer,
        run.assistant.list.items[0..run.assistant.committed_len],
    );
    writer.print(",\"assistantRedacted\":{},\"status\":", .{run.assistant_redacted}) catch
        return error.SnapshotTooLarge;
    jsonValue(writer, legacyActivityLabel(run)) catch return error.SnapshotTooLarge;
    writer.writeAll(",\"outcome\":") catch return error.SnapshotTooLarge;
    if (terminal) |value|
        jsonValue(writer, @tagName(value.outcome)) catch return error.SnapshotTooLarge
    else
        writer.writeAll("null") catch return error.SnapshotTooLarge;
    writer.writeAll(",\"cause\":") catch return error.SnapshotTooLarge;
    if (terminal) |value| {
        if (value.cause) |cause|
            jsonValue(writer, @tagName(cause)) catch return error.SnapshotTooLarge
        else
            writer.writeAll("null") catch return error.SnapshotTooLarge;
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
        try text_projection.writeJson(writer, tool.id);
        writer.print(",\"order\":\"{d}\"", .{tool.order}) catch
            return error.SnapshotTooLarge;
        writer.writeAll(",\"name\":") catch return error.SnapshotTooLarge;
        try text_projection.writeJson(writer, tool.name);
        writer.writeAll(",\"input\":") catch return error.SnapshotTooLarge;
        try text_projection.writeJson(writer, tool.input);
        writer.writeAll(",\"progress\":") catch return error.SnapshotTooLarge;
        try text_projection.writeJson(writer, tool.progress);
        writer.writeAll(",\"content\":") catch return error.SnapshotTooLarge;
        try text_projection.writeJson(writer, tool.content);
        writer.print(",\"state\":\"{s}\",\"isError\":{},\"elapsedMs\":\"{d}\",\"inputTruncated\":{},\"progressTruncated\":{},\"contentTruncated\":{},\"redacted\":{},\"fileRefs\":[", .{
            @tagName(tool.state),
            tool.is_error,
            tool.elapsed_ms,
            tool.input_truncated,
            tool.progress_truncated,
            tool.content_truncated,
            tool.redacted,
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
            writer.writeByte('}') catch return error.SnapshotTooLarge;
        };
        writer.writeAll("]}") catch return error.SnapshotTooLarge;
    }
    writer.writeAll("]}") catch return error.SnapshotTooLarge;
}

/// The mutable Product status string has been removed. Until the revision-1
/// snapshot is hard-cut to the typed activity union, keep the existing wire
/// field as a pure projection so this internal Product-state change remains a
/// buildable commit rather than a second source of runtime truth.
fn legacyActivityLabel(run: *const task_state.RunRecord) []const u8 {
    const activity = task_state.currentActivity(run) orelse return switch (task_state.runPhase(run)) {
        .completed => "Completed",
        .stopped, .cancelled => "Stopped",
        .interrupted => "Interrupted",
        .failed => "Failed",
        .queued, .running, .waiting_ui, .stopping => unreachable,
    };
    return switch (activity) {
        .queued => "Queued",
        .starting => "Starting",
        .waiting_model => "Waiting for model",
        .thinking => "Thinking",
        .writing_response => "Writing response",
        .executing_tools => "Executing tools",
        .retrying_provider => "Retrying provider",
        .waiting_user => "Waiting for your input",
        .compacting_context => "Compacting context",
        .finalizing => "Finishing",
        .stopping => "Stopping",
    };
}

fn writeCompact(
    writer: *std.Io.Writer,
    compact: *const task_state.CompactRecord,
) Error!void {
    const terminal = task_state.compactTerminalPayload(compact);
    const phase = if (terminal) |payload|
        payload.phase
    else
        task_state.activeCompactPhase(compact);
    writer.print(
        "{{\"operationId\":\"{d}\",\"afterRunId\":\"{d}\",\"phase\":\"{s}\",\"cause\":",
        .{ compact.id, compact.after_run_id, @tagName(phase) },
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
    return if (task.runtime.pinnedCatalogConst()) |snapshot|
        snapshot.view()
    else
        .{ .availability = .uninitialized };
}

fn jsonValue(writer: *std.Io.Writer, value: anytype) !void {
    try std.json.Stringify.value(
        value,
        .{ .emit_nonportable_numbers_as_strings = true },
        writer,
    );
}
