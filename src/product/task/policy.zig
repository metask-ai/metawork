//! Effect-free Product Task lifecycle, terminal, interruption, and recovery policy.
//! This module owns no executor, Agent Runtime, persistence effect, revision,
//! projection buffer, or snapshot writer.

const std = @import("std");
const agent = @import("metawork_agent");
const task_state = @import("product_task_state");
const task_attachment = @import("product_task_attachment");
const task_recovery = @import("product_task_recovery");
const checkpoint_record = @import("product_task_checkpoint_record");

const automatic_title_max_codepoints: usize = 32;

pub fn automaticTitleCandidate(input: *const task_state.RunInputRecord) ?[]const u8 {
    return switch (input.*) {
        .text => |text| firstAutomaticTitleLine(text.value),
        .multimodal => |multimodal| if (multimodal.text) |text|
            firstAutomaticTitleLine(text)
        else if (multimodal.attachments.len != 0)
            firstAutomaticTitleLine(multimodal.attachments[0].display_name)
        else
            null,
        .skill => |skill| blk: {
            const display_name = std.mem.trim(u8, skill.display_name, " \t\r\n");
            if (display_name.len == 0 or !validAutomaticTitleText(display_name))
                break :blk null;
            break :blk display_name;
        },
    };
}

pub fn automaticTitleCompletionInput(input: *const task_state.RunInputRecord) ?[]const u8 {
    const value = switch (input.*) {
        .text => |text| text.value,
        .multimodal => |multimodal| multimodal.text orelse
            if (multimodal.attachments.len != 0)
                multimodal.attachments[0].display_name
            else
                "",
        .skill => |skill| skill.display_name,
    };
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0 or !std.unicode.utf8ValidateSlice(trimmed)) return null;
    return trimmed;
}

fn firstAutomaticTitleLine(value: []const u8) ?[]const u8 {
    if (value.len == 0 or !std.unicode.utf8ValidateSlice(value)) return null;
    var cursor: usize = 0;
    var in_fence = false;
    while (cursor < value.len) {
        const line_end = std.mem.indexOfScalarPos(u8, value, cursor, '\n') orelse value.len;
        var line = std.mem.trim(u8, value[cursor..line_end], " \t\r");
        const fence = std.mem.startsWith(u8, line, "```") or
            std.mem.startsWith(u8, line, "~~~");
        if (fence) {
            in_fence = !in_fence;
        } else if (!in_fence) {
            while (line.len != 0 and line[0] == '#')
                line = std.mem.trim(u8, line[1..], " \t");
            if (std.mem.startsWith(u8, line, "- ") or
                std.mem.startsWith(u8, line, "* ") or
                std.mem.startsWith(u8, line, "+ "))
                line = std.mem.trim(u8, line[2..], " \t");
            if (line.len != 0 and validAutomaticTitleText(line)) return line;
        }
        if (line_end == value.len) break;
        cursor = line_end + 1;
    }
    return null;
}

fn validAutomaticTitleText(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |byte| if (byte < 0x20) return false;
    return true;
}

pub fn generatedAutomaticTitleCandidate(value: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (!std.unicode.utf8ValidateSlice(trimmed) or
        !validAutomaticTitleText(trimmed) or
        std.mem.indexOfAny(u8, trimmed, "\r\n") != null)
        return null;
    const bounded = boundAutomaticTitle(trimmed);
    return if (bounded.len == 0) null else bounded;
}

pub fn boundAutomaticTitle(value: []const u8) []const u8 {
    var cursor: usize = 0;
    var codepoints: usize = 0;
    var preferred_boundary: usize = 0;
    while (cursor < value.len and codepoints < automatic_title_max_codepoints) {
        const start = cursor;
        cursor += std.unicode.utf8ByteSequenceLength(value[cursor]) catch unreachable;
        codepoints += 1;
        if (isAutomaticTitleBoundary(value[start..cursor]))
            preferred_boundary = start;
    }
    if (cursor == value.len) return value;
    const boundary = if (preferred_boundary > 0) preferred_boundary else cursor;
    var bounded = value[0..boundary];
    while (bounded.len != 0 and (bounded[bounded.len - 1] == ' ' or
        bounded[bounded.len - 1] == '\t'))
        bounded = bounded[0 .. bounded.len - 1];
    return bounded;
}

fn isAutomaticTitleBoundary(codepoint: []const u8) bool {
    if (codepoint.len == 1) return switch (codepoint[0]) {
        ' ', '\t', ',', '.', ';', ':', '!', '?' => true,
        else => false,
    };
    return std.mem.eql(u8, codepoint, "，") or
        std.mem.eql(u8, codepoint, "。") or
        std.mem.eql(u8, codepoint, "；") or
        std.mem.eql(u8, codepoint, "：") or
        std.mem.eql(u8, codepoint, "！") or
        std.mem.eql(u8, codepoint, "？") or
        std.mem.eql(u8, codepoint, "、");
}

pub const TerminalDecision = struct {
    phase: task_state.RunPhase,
    outcome: task_state.RunOutcome,
    cause: ?task_state.RunCause,
};

pub const CompactTerminalDecision = struct {
    phase: task_state.CompactPhase,
    cause: ?task_state.CompactCause,
};

pub fn pendingInterruption(
    interruption: agent.ExternalInterruption,
) task_state.PendingInterruption {
    return switch (interruption) {
        .user_cancel => .user_cancel,
        .session_close => .session_close,
        .app_shutdown => .app_shutdown,
        .timeout => .timeout,
    };
}

pub fn pendingTerminationSignal(
    run: *const task_state.RunRecord,
) agent.TerminationSignal {
    return .{ .interrupted = switch (run.pending_termination.load(.acquire)) {
        .none => unreachable,
        .user_cancel => .user_cancel,
        .timeout => .timeout,
        .session_close => .session_close,
        .app_shutdown => .app_shutdown,
    } };
}

pub fn pendingExternalInterruption(
    compact: *const task_state.CompactRecord,
) agent.ExternalInterruption {
    return switch (compact.pending_interruption.load(.acquire)) {
        .none => unreachable,
        .user_cancel => .user_cancel,
        .timeout => .timeout,
        .session_close => .session_close,
        .app_shutdown => .app_shutdown,
    };
}

pub fn compactCauseForInterruption(
    interruption: agent.ExternalInterruption,
) task_state.CompactCause {
    return switch (interruption) {
        .user_cancel, .timeout => .user_cancel,
        .session_close => .session_close,
        .app_shutdown => .app_shutdown,
    };
}

pub fn closeFailureCompletion(
    disposition: agent.SessionDisposition,
) task_state.CloseCompletion {
    return switch (disposition) {
        .reusable => .failed_reusable,
        .poisoned => .failed_poisoned,
        .closing => .failed_closing,
    };
}

pub fn phaseForOutcome(outcome: task_state.RunOutcome) task_state.RunPhase {
    return switch (outcome) {
        .completed => .completed,
        .stopped => .stopped,
        .cancelled => .cancelled,
        .interrupted => .interrupted,
        .failed, .dependency_contract_failure => .failed,
    };
}

pub fn classifyAgentTerminal(
    result: *const agent.TerminalResult,
) TerminalDecision {
    if (result.failure == .dependency_contract) return .{
        .phase = .failed,
        .outcome = .dependency_contract_failure,
        .cause = .dependency_contract_failure,
    };
    if (result.termination_signal) |signal| switch (signal) {
        .permission_required => return decisionForSignal(signal),
        else => {},
    };
    if (result.failure == .abi_status) return .{
        .phase = .failed,
        .outcome = .failed,
        .cause = if (result.termination_signal) |signal|
            causeForSignal(signal)
        else if (result.abi_status) |status|
            switch (status) {
                .stale_catalog => .stale_catalog,
                .skill_not_found => .skill_not_found,
                .invalid_skill_arguments => .invalid_skill_arguments,
                .skill_policy_violation => .skill_policy_violation,
                .skill_unavailable => .skill_unavailable,
                .resource_limit, .checkpoint_budget_required => .resource_limit,
                .image_input_unsupported => .image_input_unsupported,
                else => null,
            }
        else
            null,
    };
    if (result.stop_reason) |reason| return switch (reason) {
        .end_turn => .{ .phase = .completed, .outcome = .completed, .cause = null },
        .max_turns, .tool_loop => .{ .phase = .stopped, .outcome = .stopped, .cause = null },
        .aborted => decisionForSignal(result.termination_signal),
        .tool_error => .{
            .phase = .failed,
            .outcome = .failed,
            .cause = if (result.termination_signal) |signal|
                causeForSignal(signal)
            else
                .tool_failure,
        },
        .api_error => .{
            .phase = .failed,
            .outcome = .failed,
            .cause = if (result.termination_signal) |signal|
                causeForSignal(signal)
            else
                .provider_failure,
        },
        .checkpoint_budget_exhausted, .checkpoint_resource_limit => .{
            .phase = .stopped,
            .outcome = .stopped,
            .cause = .resource_limit,
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

pub fn classifyCompactTerminal(
    result: *const agent.CompactTerminalResult,
) CompactTerminalDecision {
    if (result.failure == .dependency_contract) return .{
        .phase = .failed,
        .cause = .dependency_contract_failure,
    };
    if (result.failure == .abi_status) return .{
        .phase = .failed,
        .cause = if (result.abi_status == .resource_limit)
            .resource_limit
        else
            .agent_failure,
    };
    if (result.outcome) |outcome| return switch (outcome) {
        .compacted => .{ .phase = .compacted, .cause = null },
        .no_change => .{ .phase = .no_change, .cause = null },
        .degraded => .{ .phase = .degraded, .cause = null },
        .aborted => .{
            .phase = .aborted,
            .cause = if (result.interruption) |interruption|
                compactCauseForInterruption(interruption)
            else
                .agent_failure,
        },
    };
    return .{ .phase = .failed, .cause = .dependency_contract_failure };
}

pub fn decisionForSignal(signal: ?agent.TerminationSignal) TerminalDecision {
    const value = signal orelse
        return .{ .phase = .failed, .outcome = .failed, .cause = null };
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
        .permission_required => .{
            .phase = .stopped,
            .outcome = .stopped,
            .cause = .permission_required,
        },
        .callback_failure,
        .event_pump_failure,
        .event_consumer_notification_failure,
        => .{ .phase = .failed, .outcome = .failed, .cause = causeForSignal(value) },
    };
}

pub fn causeForSignal(signal: agent.TerminationSignal) task_state.RunCause {
    return switch (signal) {
        .interrupted => |interruption| switch (interruption) {
            .user_cancel => .user_cancel,
            .timeout => .timeout,
            .session_close => .session_close,
            .app_shutdown => .app_shutdown,
        },
        .permission_required => .permission_required,
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

pub fn classifyBeginFailure(
    run: *const task_state.RunRecord,
    failure: agent.BeginRunFailure,
) TerminalDecision {
    if (run.pending_termination.load(.acquire) != .none)
        return decisionForSignal(pendingTerminationSignal(run));
    if (failure.err == error.SessionClosing) return .{
        .phase = .interrupted,
        .outcome = .interrupted,
        .cause = .session_close,
    };
    return .{
        .phase = .failed,
        .outcome = .dependency_contract_failure,
        .cause = .dependency_contract_failure,
    };
}

pub fn checkpointFailureAttempt(
    failure: agent.CheckpointFailure,
) task_state.CheckpointAttempt {
    return switch (failure.reason) {
        .cancelled => .cancelled,
        .resource_limit => .resource_limit,
        .io_failed => .io_failed,
        .dependency_contract => .dependency_contract,
        else => if (failure.stage == .describe) .describe_failed else .export_failed,
    };
}

pub fn lastTerminalFacts(
    runs: []?task_state.RunRecord,
) ?task_state.ProductTerminalFacts {
    var latest: ?*const task_state.RunRecord = null;
    for (runs) |*entry| {
        const run = &(entry.* orelse continue);
        if (latest == null or run.id > latest.?.id) latest = run;
    }
    return if (latest) |run| task_state.productTerminalFacts(run) else null;
}

pub fn latestTerminalRun(
    runs: []?task_state.RunRecord,
) ?*const task_state.RunRecord {
    var latest: ?*const task_state.RunRecord = null;
    for (runs) |*entry| {
        const run = &(entry.* orelse continue);
        if (task_state.productTerminalFacts(run) == null) continue;
        if (latest == null or run.id > latest.?.id) latest = run;
    }
    return latest;
}

pub fn unreadCompletionRunId(task: *const task_state.Task) ?u64 {
    if (task.durable.archived) return null;
    const run = latestTerminalRun(task.durable.runs) orelse return null;
    const terminal = task_state.productTerminalFacts(run) orelse unreachable;
    if (terminal.outcome != .completed or
        task.durable.completion_seen_run_id == run.id)
        return null;
    return run.id;
}

pub fn currentRunProjection(
    task: *const task_state.Task,
) ?task_state.RunProjectionFacts {
    const run = task_state.findRun(
        task.durable.runs,
        task.runtime.active_run_id,
    ) orelse return null;
    const projection = task_state.runProjectionFacts(run);
    return if (task_state.isTerminalPhase(projection.phase)) null else projection;
}

pub fn currentRunPhase(task: *const task_state.Task) ?task_state.RunPhase {
    const projection = currentRunProjection(task) orelse return null;
    return projection.phase;
}

pub fn hasActiveOperation(task: *const task_state.Task) bool {
    return switch (task.runtime.active_operation) {
        .none => false,
        .run => |id| if (task_state.findRun(task.durable.runs, id)) |run|
            !task_state.isTerminalPhase(task_state.runPhase(run))
        else
            false,
        .compact => |id| if (task_state.findCompact(task.durable.compacts, id)) |compact|
            !task_state.isTerminalCompactPhase(
                task_state.compactProjectionFacts(compact).phase,
            )
        else
            false,
        .restore => true,
    };
}

pub fn runHistoryHighWater(task: *const task_state.Task) u64 {
    var latest: u64 = 0;
    for (task.durable.runs) |*entry| {
        const run = &(entry.* orelse continue);
        latest = @max(latest, run.id);
    }
    return latest;
}

pub fn compactHistoryHighWater(task: *const task_state.Task) u64 {
    var latest: u64 = 0;
    for (task.durable.compacts) |*entry| {
        const compact = &(entry.* orelse continue);
        latest = @max(latest, compact.id);
    }
    return latest;
}

pub fn maxCoveredRunId(task: *const task_state.Task) u64 {
    var latest: u64 = 0;
    for (task.durable.runs) |*entry| {
        const run = &(entry.* orelse continue);
        if (run.coverage == .covered) latest = @max(latest, run.id);
    }
    return latest;
}

pub fn maxCoveredCompactId(task: *const task_state.Task) u64 {
    var latest: u64 = 0;
    for (task.durable.compacts) |*entry| {
        const compact = &(entry.* orelse continue);
        if (compact.coverage == .covered) latest = @max(latest, compact.id);
    }
    return latest;
}

pub fn hasPendingConversationCoverage(task: *const task_state.Task) bool {
    for (task.durable.runs) |*entry| {
        const run = &(entry.* orelse continue);
        if (run.coverage == .pending) return true;
    }
    for (task.durable.compacts) |*entry| {
        const compact = &(entry.* orelse continue);
        if (compact.coverage == .pending) return true;
    }
    return false;
}

pub fn lastConversationRunId(task: *const task_state.Task) ?u64 {
    var latest: u64 = 0;
    for (task.durable.runs) |*entry| {
        const run = &(entry.* orelse continue);
        if (run.coverage == .excluded or
            !run.event_stream_finalized or
            task_state.productTerminalFacts(run) == null)
            continue;
        latest = @max(latest, run.id);
    }
    return if (latest == 0) null else latest;
}

pub fn lastConversationCompactId(task: *const task_state.Task) u64 {
    var latest: u64 = 0;
    for (task.durable.compacts) |*entry| {
        const compact = &(entry.* orelse continue);
        if (compact.coverage == .excluded or
            task_state.compactProjectionFacts(compact).terminal == null)
            continue;
        latest = @max(latest, compact.id);
    }
    return latest;
}

pub fn continuationAvailable(capability: task_state.ContinuationCapability) bool {
    return switch (capability) {
        .available => true,
        .unavailable => false,
    };
}

pub fn taskLifecycle(task: *const task_state.Task) task_state.TaskLifecycle {
    if (task.deletion == .deleting or task.runtime.close_requested) return .closing;
    return switch (task.runtime.attachment) {
        .closing => .closing,
        .detached, .attached => .open,
    };
}

pub fn recoveryAttachment(
    attachment: task_attachment.Attachment,
) task_recovery.Attachment {
    return switch (attachment) {
        .detached => .detached,
        .closing => .closing,
        .attached => |attached| switch (attached.health) {
            .available => .attached_available,
            .session_poisoned => .attached_session_poisoned,
        },
    };
}

pub fn recoveryOperation(
    operation: task_state.ActiveOperation,
) task_recovery.Operation {
    return switch (operation) {
        .none => .none,
        .run => .run,
        .compact => .compact,
        .restore => .restore,
    };
}

pub fn checkpointMatchesCurrentHistory(
    task: *const task_state.Task,
    record: checkpoint_record.Record,
) bool {
    if (hasPendingConversationCoverage(task) or
        record.session.last_run_id != maxCoveredRunId(task) or
        record.session.last_compact_id != maxCoveredCompactId(task))
        return false;
    return switch (record.anchor.terminal) {
        .run => |id| id == record.session.last_run_id and
            if (task_state.findRun(task.durable.runs, id)) |run|
                run.coverage == .covered and
                    run.event_stream_finalized and
                    task_state.productTerminalFacts(run) != null
            else
                false,
        .compact => |id| id == record.session.last_compact_id and
            if (task_state.findCompact(task.durable.compacts, id)) |compact|
                compact.coverage == .covered and
                    task_state.compactProjectionFacts(compact).terminal != null
            else
                false,
    };
}

pub fn foldTerminalDisposition(
    task: *task_state.Task,
    disposition: agent.SessionDisposition,
) void {
    const attached = task.runtime.attached() orelse return;
    switch (disposition) {
        .reusable => attached.health = .available,
        .poisoned => attached.health = .session_poisoned,
        .closing => std.debug.assert(task.runtime.beginClosing()),
    }
}

test "Agent terminal facts map into Product Task outcomes" {
    var terminal = agent.TerminalResult{
        .allocator = std.testing.allocator,
        .diagnostic_storage = &.{},
        .diagnostic_len = 0,
        .diagnostic_truncated = false,
        .abi_status = .ok,
        .raw_status_code = @intFromEnum(agent.Status.ok),
        .stop_reason = .end_turn,
        .raw_stop_reason_code = @intFromEnum(agent.StopReason.end_turn),
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

    terminal.termination_signal = .permission_required;
    try std.testing.expectEqual(
        TerminalDecision{
            .phase = .stopped,
            .outcome = .stopped,
            .cause = .permission_required,
        },
        classifyAgentTerminal(&terminal),
    );
    terminal.termination_signal = null;

    terminal.abi_status = .callback_failed;
    terminal.raw_status_code = @intFromEnum(agent.Status.callback_failed);
    terminal.stop_reason = null;
    terminal.raw_stop_reason_code = null;
    terminal.failure = .abi_status;
    terminal.termination_signal = .permission_required;
    try std.testing.expectEqual(
        TerminalDecision{
            .phase = .stopped,
            .outcome = .stopped,
            .cause = .permission_required,
        },
        classifyAgentTerminal(&terminal),
    );
    terminal.termination_signal = null;

    terminal.abi_status = .checkpoint_budget_required;
    terminal.raw_status_code = @intFromEnum(agent.Status.checkpoint_budget_required);
    terminal.stop_reason = null;
    terminal.raw_stop_reason_code = null;
    terminal.failure = .abi_status;
    try std.testing.expectEqual(
        TerminalDecision{ .phase = .failed, .outcome = .failed, .cause = .resource_limit },
        classifyAgentTerminal(&terminal),
    );

    terminal.abi_status = .image_input_unsupported;
    terminal.raw_status_code = @intFromEnum(agent.Status.image_input_unsupported);
    try std.testing.expectEqual(
        TerminalDecision{
            .phase = .failed,
            .outcome = .failed,
            .cause = .image_input_unsupported,
        },
        classifyAgentTerminal(&terminal),
    );

    terminal.abi_status = .ok;
    terminal.raw_status_code = @intFromEnum(agent.Status.ok);
    terminal.stop_reason = .checkpoint_budget_exhausted;
    terminal.raw_stop_reason_code = @intFromEnum(agent.StopReason.checkpoint_budget_exhausted);
    terminal.failure = null;
    try std.testing.expectEqual(
        TerminalDecision{ .phase = .stopped, .outcome = .stopped, .cause = .resource_limit },
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

    terminal.termination_signal = .permission_required;
    try std.testing.expectEqual(
        TerminalDecision{
            .phase = .stopped,
            .outcome = .stopped,
            .cause = .permission_required,
        },
        classifyAgentTerminal(&terminal),
    );

    terminal.raw_status_code = @intFromEnum(agent.Status.callback_failed);
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

    terminal.failure = null;
    terminal.stop_reason = .api_error;
    terminal.raw_stop_reason_code = @intFromEnum(agent.StopReason.api_error);
    terminal.termination_signal = null;
    try std.testing.expectEqual(
        TerminalDecision{ .phase = .failed, .outcome = .failed, .cause = .provider_failure },
        classifyAgentTerminal(&terminal),
    );

    terminal.termination_signal = .{ .interrupted = .timeout };
    try std.testing.expectEqual(
        TerminalDecision{ .phase = .failed, .outcome = .failed, .cause = .timeout },
        classifyAgentTerminal(&terminal),
    );

    terminal.stop_reason = .tool_error;
    terminal.raw_stop_reason_code = @intFromEnum(agent.StopReason.tool_error);
    terminal.termination_signal = null;
    try std.testing.expectEqual(
        TerminalDecision{ .phase = .failed, .outcome = .failed, .cause = .tool_failure },
        classifyAgentTerminal(&terminal),
    );
}

test "Compact terminal and interruption facts map into Product Task outcomes" {
    var terminal = agent.CompactTerminalResult{
        .allocator = std.testing.allocator,
        .diagnostic_storage = &.{},
        .diagnostic_len = 0,
        .diagnostic_truncated = false,
        .abi_status = .ok,
        .raw_status_code = @intFromEnum(agent.Status.ok),
        .abort_status = null,
        .raw_abort_status_code = null,
        .outcome = .compacted,
        .before_context_tokens = 0,
        .after_context_tokens = 0,
        .input_tokens = 0,
        .output_tokens = 0,
        .cache_read_input_tokens = 0,
        .cache_creation_input_tokens = 0,
        .interruption = null,
        .failure = null,
        .session_disposition_at_completion = .reusable,
    };
    try std.testing.expectEqual(
        CompactTerminalDecision{ .phase = .compacted, .cause = null },
        classifyCompactTerminal(&terminal),
    );

    terminal.outcome = .aborted;
    terminal.interruption = .app_shutdown;
    try std.testing.expectEqual(
        CompactTerminalDecision{ .phase = .aborted, .cause = .app_shutdown },
        classifyCompactTerminal(&terminal),
    );

    terminal.outcome = null;
    terminal.interruption = null;
    terminal.abi_status = .resource_limit;
    terminal.failure = .abi_status;
    try std.testing.expectEqual(
        CompactTerminalDecision{ .phase = .failed, .cause = .resource_limit },
        classifyCompactTerminal(&terminal),
    );

    terminal.abi_status = null;
    terminal.failure = .dependency_contract;
    try std.testing.expectEqual(
        CompactTerminalDecision{ .phase = .failed, .cause = .dependency_contract_failure },
        classifyCompactTerminal(&terminal),
    );
}

test "Run outcome phases remain truthful" {
    try std.testing.expectEqual(task_state.RunPhase.completed, phaseForOutcome(.completed));
    try std.testing.expectEqual(task_state.RunPhase.stopped, phaseForOutcome(.stopped));
    try std.testing.expectEqual(task_state.RunPhase.cancelled, phaseForOutcome(.cancelled));
    try std.testing.expectEqual(task_state.RunPhase.interrupted, phaseForOutcome(.interrupted));
    try std.testing.expectEqual(task_state.RunPhase.failed, phaseForOutcome(.dependency_contract_failure));
}

test "unobserved Compact terminal remains active and stays outside Conversation frontier" {
    var runs: [0]?task_state.RunRecord = .{};
    var compacts = [_]?task_state.CompactRecord{.{
        .id = 11,
        .after_run_id = 7,
        .agent_handoff = .init(.running),
        .terminal_publication = .init(.published),
        .terminal_payload = .{
            .phase = .compacted,
            .cause = null,
            .before_context_tokens = 100,
            .after_context_tokens = 40,
            .usage = .{},
            .session_disposition_at_completion = .reusable,
        },
        .terminal_diagnostic = @constCast(""),
    }};
    var ui_history: [0]?task_state.UiRecord = .{};
    var task = task_state.Task{
        .durable = .{
            .id = 3,
            .recent_order = 1,
            .execution_generation = 1,
            .execution_protocol = .anthropic_messages,
            .execution_model = @constCast("model"),
            .permission_profile = .approval_required,
            .permission_interaction = .interactive,
            .workspace_id = 2,
            .workspace_root = @constCast("root"),
            .title = @constCast("title"),
            .runs = &runs,
            .compacts = &compacts,
            .ui_history = &ui_history,
        },
        .runtime = .{ .active_operation = .{ .compact = 11 } },
    };

    try std.testing.expect(hasActiveOperation(&task));
    try std.testing.expectEqual(@as(u64, 11), compactHistoryHighWater(&task));
    try std.testing.expectEqual(@as(u64, 0), lastConversationCompactId(&task));

    task.durable.compacts[0].?.terminal_observed = true;
    try std.testing.expect(!hasActiveOperation(&task));
    try std.testing.expectEqual(@as(u64, 11), lastConversationCompactId(&task));
}

fn terminalRun(id: u64, coverage: task_state.ConversationCoverage) task_state.RunRecord {
    return .{
        .id = id,
        .coverage = coverage,
        .generation = id,
        .execution_generation = 1,
        .execution_protocol = .anthropic_messages,
        .execution_model = @constCast("model"),
        .permission_profile = .approval_required,
        .permission_interaction = .interactive,
        .input = .{ .text = .{ .value = @constCast("input") } },
        .commentary_ends = @constCast(&[_]u64{}),
        .tools = @constCast(&[_]?task_state.ToolView{}),
        .terminal_publication = .init(.published),
        .terminal_payload = .{
            .phase = .completed,
            .outcome = .completed,
            .cause = null,
            .session_disposition_at_completion = .reusable,
        },
        .terminal_observed = true,
        .event_stream_finalized = true,
        .terminal_diagnostic = @constCast(""),
    };
}

test "checkpoint matches covered frontier and permits only excluded Product tail" {
    var runs = [_]?task_state.RunRecord{
        terminalRun(1, .covered),
        terminalRun(3, .excluded),
    };
    var compacts: [0]?task_state.CompactRecord = .{};
    var ui_history: [0]?task_state.UiRecord = .{};
    var task = task_state.Task{
        .durable = .{
            .id = 3,
            .recent_order = 1,
            .execution_generation = 1,
            .execution_protocol = .anthropic_messages,
            .execution_model = @constCast("model"),
            .permission_profile = .approval_required,
            .permission_interaction = .interactive,
            .workspace_id = 2,
            .workspace_root = @constCast("root"),
            .title = @constCast("title"),
            .runs = &runs,
            .compacts = &compacts,
            .ui_history = &ui_history,
        },
        .runtime = .{},
    };
    const record: checkpoint_record.Record = .{
        .blob = .{
            .task_id = 3,
            .generation = 1,
            .digest = [_]u8{0x5a} ** 32,
            .byte_size = 1,
        },
        .session = .{
            .logical_session_id = @constCast("logical-session"),
            .last_run_id = 1,
            .last_compact_id = 0,
            .model = @constCast("model"),
        },
        .anchor = .{ .terminal = .{ .run = 1 }, .binding_epoch = 1 },
    };

    try std.testing.expectEqual(@as(u64, 3), runHistoryHighWater(&task));
    try std.testing.expectEqual(@as(u64, 1), maxCoveredRunId(&task));
    try std.testing.expectEqual(@as(?u64, 1), lastConversationRunId(&task));
    try std.testing.expect(checkpointMatchesCurrentHistory(&task, record));

    // A later covered Run may never be accepted by weakening exact equality
    // to `checkpoint <= history`.
    task.durable.runs[1].?.coverage = .covered;
    try std.testing.expect(!checkpointMatchesCurrentHistory(&task, record));

    task.durable.runs[1].?.coverage = .pending;
    try std.testing.expect(hasPendingConversationCoverage(&task));
    try std.testing.expect(!checkpointMatchesCurrentHistory(&task, record));

    task.durable.runs[1].?.coverage = .excluded;
    task.durable.runs[0].?.coverage = .excluded;
    try std.testing.expect(!checkpointMatchesCurrentHistory(&task, record));
}
