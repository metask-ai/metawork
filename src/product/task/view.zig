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

pub const ModelSelectionAvailability = enum {
    available,
    catalog_loading,
    catalog_unavailable,
    execution_replacing,
    runtime_detached,
    unsupported_source,
    authority_changed,
};

/// Callback-scoped access to Workbench's global sensitive-text projection.
/// The callbacks expose neither credential bytes nor the composition object.
pub const TextProjection = struct {
    context: *const anyopaque,
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

    fn writeJson(
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

pub const Input = struct {
    now_ms: ?u64 = null,
    task: *const task_state.Task,
    recovery: task_recovery.Projection,
    model_selection_availability: ModelSelectionAvailability,
    shutting_down: bool,
    text: TextProjection,
    catalog: CatalogProjection,
    pending_ui: PendingUiProjection,
};

pub fn writeProjection(writer: *std.Io.Writer, input: Input) Error!void {
    const task = input.task;
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
    writer.print(",\"workspaceId\":\"{d}\",\"permissionProfile\":\"{s}\",\"binding\":{{\"epoch\":\"{d}\",\"availability\":\"{s}\",\"protocol\":\"{s}\",\"model\":", .{
        task.durable.workspace_id,
        @tagName(task.durable.permission_profile),
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
    for (task.durable.runs) |*entry| {
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
    writer.print("{{\"requestId\":\"{d}\",\"runId\":\"{d}\",\"order\":\"{d}\",\"redacted\":{},", .{
        request_id,
        run_id,
        order,
        text.containsSensitive(permission.tool.name) or
            text.containsSensitive(permission.arguments_json),
    }) catch return error.SnapshotTooLarge;
    writer.print("\"kind\":\"permission\",\"toolNamespace\":\"{s}\",\"tool\":", .{
        @tagName(permission.tool.namespace),
    }) catch
        return error.SnapshotTooLarge;
    try text.writeJson(writer, permission.tool.name);
    writer.writeAll(",\"toolBinding\":") catch return error.SnapshotTooLarge;
    try text.writeJson(writer, permission.tool.binding);
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
    writer.print("],\"policyGeneration\":\"{d}\",\"canonicalArgumentsDigest\":", .{
        permission.policy_generation,
    }) catch return error.SnapshotTooLarge;
    try text.writeJson(writer, permission.canonical_arguments_digest);
    writer.writeAll(",\"candidate\":") catch return error.SnapshotTooLarge;
    if (permission.candidate) |candidate| {
        writer.writeAll("{\"ruleId\":") catch return error.SnapshotTooLarge;
        try text.writeJson(writer, candidate.rule_id);
        writer.print(",\"scope\":\"{s}\"}}", .{@tagName(candidate.scope)}) catch
            return error.SnapshotTooLarge;
    } else writer.writeAll("null") catch return error.SnapshotTooLarge;
    writer.writeByte('}') catch return error.SnapshotTooLarge;
}

fn writeRun(
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
    switch (run.input) {
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
    try writeRunOutput(writer, text_projection, run);
    writer.writeAll(",\"activity\":") catch return error.SnapshotTooLarge;
    try writeRunActivity(writer, projection.activity);
    writer.writeAll(",\"terminal\":") catch return error.SnapshotTooLarge;
    if (terminal) |value| {
        writer.print("{{\"outcome\":\"{s}\",\"cause\":", .{@tagName(value.outcome)}) catch
            return error.SnapshotTooLarge;
        if (value.cause) |cause|
            jsonValue(writer, @tagName(cause)) catch return error.SnapshotTooLarge
        else
            writer.writeAll("null") catch return error.SnapshotTooLarge;
        writer.print(",\"diagnosticDisposition\":\"{s}\"}}", .{@tagName(value.diagnostic_disposition)}) catch
            return error.SnapshotTooLarge;
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
        var presentation_redacted = try writeBashPresentation(writer, text_projection, tool);
        presentation_redacted = (try writeToolPresentation(writer, text_projection, tool)) or presentation_redacted;
        presentation_redacted = (try writeToolErrorDetail(writer, text_projection, tool)) or presentation_redacted;
        writer.writeAll(",\"input\":") catch return error.SnapshotTooLarge;
        // Decoding can reveal a credential hidden behind JSON escapes. Do not
        // expose its reconstructible raw representation in secondary details.
        try text_projection.writeJson(writer, if (presentation_redacted) "***" else tool.input);
        writer.writeAll(",\"progress\":") catch return error.SnapshotTooLarge;
        try text_projection.writeJson(writer, tool.progress);
        writer.writeAll(",\"content\":") catch return error.SnapshotTooLarge;
        try text_projection.writeJson(writer, if (presentation_redacted) "***" else tool.content);
        writer.print(",\"state\":\"{s}\",\"isError\":{},\"elapsedMs\":\"{d}\",\"inputTruncated\":{},\"progressTruncated\":{},\"contentTruncated\":{},\"redacted\":{},\"fileRefs\":[", .{
            @tagName(tool.state),
            tool.is_error,
            tool.elapsed_ms,
            tool.input_truncated,
            tool.progress_truncated,
            tool.content_truncated,
            tool.redacted or presentation_redacted,
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
    writer.writeAll("],\"fileChanges\":") catch return error.SnapshotTooLarge;
    try writeFileChanges(writer, text_projection, run);
    writer.writeByte('}') catch return error.SnapshotTooLarge;
}

const BashInput = struct {
    command: []const u8,
    description: ?[]const u8 = null,
};

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

fn writeBashPresentation(
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
    defer std.crypto.secureZero(u8, &scratch);
    var allocator = std.heap.FixedBufferAllocator.init(&scratch);
    const options = std.json.ParseOptions{ .ignore_unknown_fields = true, .allocate = .alloc_if_needed };
    var redacted = false;
    writer.writeAll("{\"command\":") catch return error.SnapshotTooLarge;
    const input = if (!tool.input_truncated and tool.input.len <= scratch.len)
        std.json.parseFromSlice(BashInput, allocator.allocator(), tool.input, options) catch null
    else
        null;
    if (input) |parsed| {
        defer parsed.deinit();
        redacted = text.containsSensitive(parsed.value.command);
        try text.writeJson(writer, parsed.value.command);
        writer.writeAll(",\"description\":") catch return error.SnapshotTooLarge;
        if (parsed.value.description) |description| {
            redacted = redacted or text.containsSensitive(description);
            try text.writeJson(writer, description);
        } else writer.writeAll("null") catch return error.SnapshotTooLarge;
    } else writer.writeAll("null,\"description\":null") catch return error.SnapshotTooLarge;
    allocator.reset();
    writer.writeAll(",\"result\":") catch return error.SnapshotTooLarge;
    const result = if (tool.state != .running and !tool.content_truncated and tool.content.len <= scratch.len)
        std.json.parseFromSlice(BashResult, allocator.allocator(), tool.content, options) catch null
    else
        null;
    if (result) |parsed| {
        defer parsed.deinit();
        const value = parsed.value;
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
) Error!bool {
    writer.writeAll(",\"presentation\":") catch return error.SnapshotTooLarge;
    if (tool.input_truncated or tool.input.len > 128 * 1024) {
        writer.writeAll("null") catch return error.SnapshotTooLarge;
        return false;
    }

    var scratch: [128 * 1024]u8 = undefined;
    defer std.crypto.secureZero(u8, &scratch);
    var allocator = std.heap.FixedBufferAllocator.init(&scratch);
    const options = std.json.ParseOptions{ .ignore_unknown_fields = true, .allocate = .alloc_if_needed };
    var redacted = false;

    if (std.mem.eql(u8, tool.name, "Read")) {
        const parsed = std.json.parseFromSlice(ReadInput, allocator.allocator(), tool.input, options) catch {
            writer.writeAll("null") catch return error.SnapshotTooLarge;
            return false;
        };
        defer parsed.deinit();
        const value = parsed.value;
        redacted = text.containsSensitive(value.file_path);
        writer.writeAll("{\"kind\":\"read\",\"target\":") catch return error.SnapshotTooLarge;
        try text.writeJson(writer, value.file_path);
        try writeOptionalWireNumber(writer, "offset", value.offset);
        try writeOptionalWireNumber(writer, "limit", value.limit);
        writer.writeByte('}') catch return error.SnapshotTooLarge;
        return redacted;
    }
    if (std.mem.eql(u8, tool.name, "Write") or std.mem.eql(u8, tool.name, "Edit")) {
        const parsed = std.json.parseFromSlice(FileMutationInput, allocator.allocator(), tool.input, options) catch {
            writer.writeAll("null") catch return error.SnapshotTooLarge;
            return false;
        };
        defer parsed.deinit();
        const value = parsed.value;
        redacted = text.containsSensitive(value.file_path);
        writer.writeAll(if (std.mem.eql(u8, tool.name, "Write"))
            "{\"kind\":\"write\",\"target\":"
        else
            "{\"kind\":\"edit\",\"target\":") catch return error.SnapshotTooLarge;
        try text.writeJson(writer, value.file_path);
        writer.writeByte('}') catch return error.SnapshotTooLarge;
        return redacted;
    }
    if (std.mem.eql(u8, tool.name, "Glob")) {
        const parsed = std.json.parseFromSlice(GlobInput, allocator.allocator(), tool.input, options) catch {
            writer.writeAll("null") catch return error.SnapshotTooLarge;
            return false;
        };
        defer parsed.deinit();
        const value = parsed.value;
        redacted = text.containsSensitive(value.pattern) or
            if (value.path) |path| text.containsSensitive(path) else false;
        writer.writeAll("{\"kind\":\"glob\",\"pattern\":") catch return error.SnapshotTooLarge;
        try text.writeJson(writer, value.pattern);
        try writeOptionalProjectedText(writer, text, "scope", value.path);
        writer.writeByte('}') catch return error.SnapshotTooLarge;
        return redacted;
    }
    if (std.mem.eql(u8, tool.name, "Grep")) {
        const parsed = std.json.parseFromSlice(GrepInput, allocator.allocator(), tool.input, options) catch {
            writer.writeAll("null") catch return error.SnapshotTooLarge;
            return false;
        };
        defer parsed.deinit();
        const value = parsed.value;
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
    if (std.mem.eql(u8, tool.name, "BashOutput")) {
        const parsed = std.json.parseFromSlice(BackgroundJobInput, allocator.allocator(), tool.input, options) catch {
            writer.writeAll("null") catch return error.SnapshotTooLarge;
            return false;
        };
        defer parsed.deinit();
        const value = parsed.value;
        redacted = text.containsSensitive(value.job_id);
        writer.writeAll("{\"kind\":\"bash_output\",\"jobId\":") catch return error.SnapshotTooLarge;
        try text.writeJson(writer, value.job_id);
        writer.writeAll(",\"result\":") catch return error.SnapshotTooLarge;
        allocator.reset();
        const result = if (tool.state != .running and !tool.content_truncated and tool.content.len <= scratch.len)
            std.json.parseFromSlice(BashOutputResult, allocator.allocator(), tool.content, options) catch null
        else
            null;
        if (result) |decoded| {
            defer decoded.deinit();
            const result_value = decoded.value;
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
    if (std.mem.eql(u8, tool.name, "KillShell")) {
        const parsed = std.json.parseFromSlice(BackgroundJobInput, allocator.allocator(), tool.input, options) catch {
            writer.writeAll("null") catch return error.SnapshotTooLarge;
            return false;
        };
        defer parsed.deinit();
        const value = parsed.value;
        redacted = text.containsSensitive(value.job_id);
        writer.writeAll("{\"kind\":\"kill_shell\",\"jobId\":") catch return error.SnapshotTooLarge;
        try text.writeJson(writer, value.job_id);
        writer.writeByte('}') catch return error.SnapshotTooLarge;
        return redacted;
    }
    if (std.mem.eql(u8, tool.name, "WebSearch")) {
        const parsed = std.json.parseFromSlice(WebSearchInput, allocator.allocator(), tool.input, options) catch {
            writer.writeAll("null") catch return error.SnapshotTooLarge;
            return false;
        };
        defer parsed.deinit();
        const value = parsed.value;
        redacted = text.containsSensitive(value.query);
        writer.writeAll("{\"kind\":\"web_search\",\"query\":") catch return error.SnapshotTooLarge;
        try text.writeJson(writer, value.query);
        writer.writeByte('}') catch return error.SnapshotTooLarge;
        return redacted;
    }
    if (std.mem.eql(u8, tool.name, "WebFetch")) {
        const parsed = std.json.parseFromSlice(WebFetchInput, allocator.allocator(), tool.input, options) catch {
            writer.writeAll("null") catch return error.SnapshotTooLarge;
            return false;
        };
        defer parsed.deinit();
        const value = parsed.value;
        redacted = text.containsSensitive(value.url) or
            if (value.prompt) |prompt| text.containsSensitive(prompt) else false;
        writer.writeAll("{\"kind\":\"web_fetch\",\"url\":") catch return error.SnapshotTooLarge;
        try text.writeJson(writer, value.url);
        try writeOptionalProjectedText(writer, text, "prompt", value.prompt);
        writer.writeAll(",\"result\":") catch return error.SnapshotTooLarge;
        allocator.reset();
        const result = if (tool.state != .running and !tool.content_truncated and tool.content.len <= scratch.len)
            std.json.parseFromSlice(WebFetchResult, allocator.allocator(), tool.content, options) catch null
        else
            null;
        if (result) |decoded| {
            defer decoded.deinit();
            const result_value = decoded.value;
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

    writer.writeAll("null") catch return error.SnapshotTooLarge;
    return false;
}

fn writeToolErrorDetail(
    writer: *std.Io.Writer,
    text: TextProjection,
    tool: *const task_state.ToolView,
) Error!bool {
    writer.writeAll(",\"errorDetail\":") catch return error.SnapshotTooLarge;
    if (tool.state != .failed or tool.content_truncated or tool.content.len > 128 * 1024) {
        writer.writeAll("null") catch return error.SnapshotTooLarge;
        return false;
    }
    var scratch: [128 * 1024]u8 = undefined;
    defer std.crypto.secureZero(u8, &scratch);
    var allocator = std.heap.FixedBufferAllocator.init(&scratch);
    const parsed = std.json.parseFromSlice(
        ToolErrorEnvelope,
        allocator.allocator(),
        tool.content,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_if_needed },
    ) catch {
        writer.writeAll("null") catch return error.SnapshotTooLarge;
        return false;
    };
    defer parsed.deinit();
    const detail = parsed.value.@"error".detail;
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
        run.output_continued_redacted or run.output_segment_redacted or
            provisional_redacted,
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
